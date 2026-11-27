program mcp_client_tests;
(*
  The MCP client against MCP 2026-07-28 and the revisions before it.

  Most cases run the real TMCPStdioClient / TMCPHttpClient against
  src/tests/fake_mcp_server.py, which logs every message (and HTTP header)
  it receives, so a case checks what PasClaw actually sent:

    - modern negotiation: server/discover, never initialize; every request
      carries _meta protocolVersion / clientInfo / clientCapabilities; HTTP
      sends MCP-Protocol-Version, Mcp-Method, Mcp-Name (and Mcp-Param-* for
      x-mcp-header arguments) and no session id;
    - legacy fallback: an error to the probe, silence (probe timeout), and
      UnsupportedProtocolVersionError all end in initialize; servers that
      answer 2024-11-05, 2025-06-18 and 2025-11-25 all connect;
    - multi round-trip requests: form and URL elicitation answered by a
      scripted handler and retried with inputResponses + requestState; the
      non-interactive decline (no retry, a note with the URL); the round cap;
    - legacy elicitation/create over stdio;
    - the tasks extension: polling to completion and to failure, and input
      through tasks/update;
    - interop with PasClaw's own server (`pasclaw mcp stdio`).

  The pure helpers are pinned directly: form-answer parsing and the console
  dialogue, x-mcp-header extraction and value encoding, SSE response
  picking, and the OAuth checks (RFC 9207 iss validation, the native DCR
  body, issuer-bound client reuse).

  Environment (set by `make test-mcp-client`):
    FAKE_MCP      path of fake_mcp_server.py
    MCP_PYTHON    python interpreter (default python3)
    MCP_TEST_DIR  scratch directory for the logs
    PASCLAW_BIN   the built pasclaw, for the interop case
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Platform,
  PasClaw.MCP.Types,
  PasClaw.MCP.Client,
  PasClaw.MCP.StdioClient,
  PasClaw.MCP.HttpClient,
  PasClaw.MCP.Elicit,
  PasClaw.MCP.Headers,
  PasClaw.MCP.OAuth,
  PasClaw.Config,
  PasClaw.Tools.Registry,
  PasClaw.MCP.Cache,
  PasClaw.MCP.Bridge;      { ConnectMCPServerList -- a call while connecting }

var
  Failures: Integer = 0;
  FakeMCP, Python, TestDir, PasclawBin: string;
  LogSeq: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

function Has(const Hay, Needle: string): Boolean;
begin
  Result := Pos(Needle, Hay) > 0;
end;

{ ---------------------------------------------------------------- handlers }

type
  { Answers every elicitation the same scripted way and records what it saw. }
  TScripted = class(TMCPElicitationHandler)
  public
    Action:  TMCPElicitAction;
    Content: string;
    Seen:    TStringList;
    DelayMs: Integer;    { a user who takes their time }
    constructor Create(AAction: TMCPElicitAction; const AContent: string);
    destructor Destroy; override;
    function Elicit(const Req: TMCPElicitRequest): TMCPElicitResponse; override;
  end;

constructor TScripted.Create(AAction: TMCPElicitAction; const AContent: string);
begin
  inherited Create;
  Action := AAction;
  Content := AContent;
  Seen := TStringList.Create;
end;

destructor TScripted.Destroy;
begin
  Seen.Free;
  inherited Destroy;
end;

function TScripted.Elicit(const Req: TMCPElicitRequest): TMCPElicitResponse;
begin
  if DelayMs > 0 then Sleep(DelayMs);
  if Req.Mode = emURL then Seen.Add('url ' + Req.Server + ' ' + Req.URL)
  else Seen.Add('form ' + Req.Server + ' ' + Req.Message);
  Result.Action := Action;
  Result.ContentJSON := '';
  if (Req.Mode = emForm) and (Action = eaAccept) then Result.ContentJSON := Content;
  Result.Note := '';
end;

type
  { The console dialogue with scripted keystrokes instead of a terminal. }
  TTypedConsole = class(TMCPConsoleElicitationHandler)
  protected
    function ReadAnswer(out Line: string): Boolean; override;
    procedure Show(const S: string; NewLine: Boolean = True); override;
  public
    Lines: TStringList;
    Shown: string;
    constructor Create(const Typed: array of string);
    destructor Destroy; override;
  end;

constructor TTypedConsole.Create(const Typed: array of string);
var
  i: Integer;
begin
  inherited Create;
  Lines := TStringList.Create;
  for i := 0 to High(Typed) do Lines.Add(Typed[i]);
  Shown := '';
end;

destructor TTypedConsole.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

function TTypedConsole.ReadAnswer(out Line: string): Boolean;
begin
  Line := '';
  Result := Lines.Count > 0;
  if Result then
  begin
    Line := Lines[0];
    Lines.Delete(0);
  end;
end;

procedure TTypedConsole.Show(const S: string; NewLine: Boolean);
begin
  Shown := Shown + S;
  if NewLine then Shown := Shown + #10;
end;

{ ------------------------------------------------------------- the log }

function NewLog(const Tag: string): string;
begin
  Inc(LogSeq);
  Result := IncludeTrailingPathDelimiter(TestDir) + Format('%s-%d.jsonl', [Tag, LogSeq]);
  if FileExists(Result) then DeleteFile(Result);
end;

function ReadLog(const Path: string): TStringList;
begin
  Result := TStringList.Create;
  if FileExists(Path) then Result.LoadFromFile(Path);
end;

{ The Nth (0-based) logged message with this method, as JSON ('' = none). }
function LoggedMsg(const Path, Method: string; Nth: Integer = 0): string;
var
  L: TStringList;
  i, Seen: Integer;
  O, M: TJsonObject;
begin
  Result := '';
  Seen := 0;
  L := ReadLog(Path);
  try
    for i := 0 to L.Count - 1 do
    begin
      O := TJsonObject.Parse(L[i]);
      if O = nil then Continue;
      try
        M := O.ChildObject('msg');
        if M = nil then Continue;
        try
          if M.GetStr('method', '') <> Method then Continue;
          if Seen = Nth then Exit(L[i]);
          Inc(Seen);
        finally
          M.Free;
        end;
      finally
        O.Free;
      end;
    end;
  finally
    L.Free;
  end;
end;

function CountMethod(const Path, Method: string): Integer;
begin
  Result := 0;
  while LoggedMsg(Path, Method, Result) <> '' do Inc(Result);
end;

function LineHeader(const Line, Name: string): string;
var
  O, H: TJsonObject;
begin
  Result := '';
  O := TJsonObject.Parse(Line);
  if O = nil then Exit;
  try
    H := O.ChildObject('headers');
    if H = nil then Exit;
    try
      Result := H.GetStr(LowerCase(Name), '');
    finally
      H.Free;
    end;
  finally
    O.Free;
  end;
end;

function LineHasHeader(const Line, Name: string): Boolean;
var
  O, H: TJsonObject;
begin
  Result := False;
  O := TJsonObject.Parse(Line);
  if O = nil then Exit;
  try
    H := O.ChildObject('headers');
    if H = nil then Exit;
    try
      Result := H.Has(LowerCase(Name));
    finally
      H.Free;
    end;
  finally
    O.Free;
  end;
end;

{ params._meta of a logged message, as JSON ('' = none). }
function LineMeta(const Line: string): string;
var
  O, M, P: TJsonObject;
begin
  Result := '';
  O := TJsonObject.Parse(Line);
  if O = nil then Exit;
  try
    M := O.ChildObject('msg');
    if M = nil then Exit;
    try
      P := M.ChildObject('params');
      if P = nil then Exit;
      try
        Result := P.GetRaw('_meta', '');
      finally
        P.Free;
      end;
    finally
      M.Free;
    end;
  finally
    O.Free;
  end;
end;

function LineParam(const Line, Key: string): string;
var
  O, M, P: TJsonObject;
begin
  Result := '';
  O := TJsonObject.Parse(Line);
  if O = nil then Exit;
  try
    M := O.ChildObject('msg');
    if M = nil then Exit;
    try
      P := M.ChildObject('params');
      if P = nil then Exit;
      try
        Result := P.GetRaw(Key, '');
      finally
        P.Free;
      end;
    finally
      M.Free;
    end;
  finally
    O.Free;
  end;
end;

function LineId(const Line: string): string;
var
  O, M: TJsonObject;
begin
  Result := '';
  O := TJsonObject.Parse(Line);
  if O = nil then Exit;
  try
    M := O.ChildObject('msg');
    if M = nil then Exit;
    try
      Result := M.GetRaw('id', '');
    finally
      M.Free;
    end;
  finally
    O.Free;
  end;
end;

{ ------------------------------------------------------------ servers }

function StdioFake(const Log, Extra: string): TMCPStdioClient;
begin
  Result := TMCPStdioClient.Create('fake', Python,
    '"' + FakeMCP + '" --log "' + Log + '" ' + Extra);
end;

type
  THttpFake = class
    Proc: TStdioProcess;
    URL: string;
    constructor Create(const Log, Extra: string);
    destructor Destroy; override;
  end;

constructor THttpFake.Create(const Log, Extra: string);
var
  Args: TStringList;
  PortFile, S: string;
  i: Integer;
  P: TStringList;
begin
  inherited Create;
  PortFile := Log + '.port';
  if FileExists(PortFile) then DeleteFile(PortFile);
  Args := TStringList.Create;
  try
    Args.Add(FakeMCP);
    Args.Add('--transport');
    Args.Add('http');
    Args.Add('--log');
    Args.Add(Log);
    Args.Add('--port-file');
    Args.Add(PortFile);
    P := TStringList.Create;
    try
      P.Delimiter := ' ';
      P.StrictDelimiter := True;
      P.DelimitedText := Extra;
      for i := 0 to P.Count - 1 do
        if P[i] <> '' then Args.Add(P[i]);
    finally
      P.Free;
    end;
    Proc := TStdioProcess.Create;
    Proc.Spawn(Python, Args);
  finally
    Args.Free;
  end;
  URL := '';
  for i := 1 to 100 do
  begin
    if FileExists(PortFile) then
    begin
      P := TStringList.Create;
      try
        P.LoadFromFile(PortFile);
        S := Trim(P.Text);
      finally
        P.Free;
      end;
      if S <> '' then
      begin
        URL := 'http://127.0.0.1:' + S + '/mcp';
        Break;
      end;
    end;
    Sleep(50);
  end;
end;

destructor THttpFake.Destroy;
begin
  if Proc <> nil then
  begin
    try
      if Proc.Running then Proc.Terminate;
    except
    end;
    Proc.Free;
  end;
  inherited Destroy;
end;

{ ============================================================ pure parts }

procedure TestFormAnswers;
var
  V, E: string;
const
  Age = '{"type":"integer","minimum":18,"maximum":130}';
  Color = '{"type":"string","enum":["red","green","blue"]}';
  Titled = '{"type":"string","oneOf":[{"const":"#f00","title":"Red"},{"const":"#0f0","title":"Green"}]}';
  Tags = '{"type":"array","minItems":1,"maxItems":2,"items":{"type":"string","enum":["a","b","c"]}}';
begin
  Check(ParseFormAnswer(Age, '42', V, E) and (V = '42'), 'form: integer parses');
  Check(not ParseFormAnswer(Age, '4.5', V, E), 'form: integer refuses a fraction');
  Check(not ParseFormAnswer(Age, '12', V, E) and Has(E, 'at least'), 'form: integer below minimum refused');
  Check(ParseFormAnswer('{"type":"number"}', '2.5', V, E) and (V = '2.5'), 'form: number parses with a dot');
  Check(ParseFormAnswer('{"type":"boolean"}', 'Yes', V, E) and (V = 'true'), 'form: yes is true');
  Check(ParseFormAnswer('{"type":"boolean"}', 'n', V, E) and (V = 'false'), 'form: n is false');
  Check(not ParseFormAnswer('{"type":"boolean"}', 'maybe', V, E), 'form: boolean refuses other words');
  Check(ParseFormAnswer(Color, 'green', V, E) and (V = '"green"'), 'form: enum by value');
  Check(ParseFormAnswer(Color, '3', V, E) and (V = '"blue"'), 'form: enum by 1-based index');
  Check(not ParseFormAnswer(Color, 'purple', V, E) and Has(E, 'red'), 'form: enum refuses others and lists choices');
  Check(ParseFormAnswer(Titled, 'Green', V, E) and (V = '"#0f0"'), 'form: titled oneOf sends the const');
  Check(ParseFormAnswer(Tags, 'a, c', V, E) and (StringReplace(V, ' ', '', [rfReplaceAll]) = '["a","c"]'),
        'form: multi-select list');
  Check(not ParseFormAnswer(Tags, 'a,b,c', V, E), 'form: multi-select maxItems');
  Check(not ParseFormAnswer('{"type":"string","minLength":2}', 'x', V, E), 'form: minLength');
  Check(ParseFormAnswer('{"type":"string"}', 'say "hi"', V, E) and (V = '"say \"hi\""'),
        'form: string is JSON-escaped');
  Check(not ParseFormAnswer('{"type":"string","format":"email"}', 'nope', V, E), 'form: email format');
  Check(Has(DescribeFormField('age', Age, True), 'required'), 'form: label says required');
  Check(Has(DescribeFormField('color', Color, False), '1) red'), 'form: label lists choices');
end;

procedure TestConsoleDialogue;
const
  Schema = '{"type":"object","properties":{' +
    '"name":{"type":"string","minLength":2},' +
    '"age":{"type":"integer","minimum":18},' +
    '"color":{"type":"string","enum":["red","green"],"default":"green"},' +
    '"subscribe":{"type":"boolean"}},' +
    '"required":["name","age"]}';
var
  H: TTypedConsole;
  Req: TMCPElicitRequest;
  R: TMCPElicitResponse;
  C: TJsonObject;
begin
  Req.Server := 'shop';
  Req.Mode := emForm;
  Req.Message := 'Who are you?';
  Req.URL := '';
  Req.SchemaJSON := Schema;
  { name: empty (required, re-asked) then "Al"; age: "ten" (re-asked) then 30;
    color: Enter (default); subscribe: Enter (optional, omitted); review: y }
  H := TTypedConsole.Create(['', 'Al', 'ten', '30', '', '', 'y']);
  try
    R := H.Elicit(Req);
    Check(R.Action = eaAccept, 'console form: accepted');
    C := TJsonObject.Parse(R.ContentJSON);
    Check(C <> nil, 'console form: content is an object');
    if C <> nil then
    try
      Check(C.GetStr('name', '') = 'Al', 'console form: name typed as a string');
      Check(C.GetRaw('age', '') = '30', 'console form: age typed as an integer');
      Check(C.GetStr('color', '') = 'green', 'console form: Enter takes the default');
      Check(not C.Has('subscribe'), 'console form: an optional field left empty is omitted');
    finally
      C.Free;
    end;
    Check(Has(H.Shown, 'shop'), 'console form: says which server asks');
    Check(Has(H.Shown, 'required'), 'console form: re-asks an empty required field');
  finally
    H.Free;
  end;
  H := TTypedConsole.Create(['/decline']);
  try
    Check(H.Elicit(Req).Action = eaDecline, 'console form: /decline declines');
  finally
    H.Free;
  end;
  H := TTypedConsole.Create(['Al', '30', '', 'yes', 'n']);
  try
    Check(H.Elicit(Req).Action = eaDecline, 'console form: "no" at review declines');
  finally
    H.Free;
  end;

  Req.Mode := emURL;
  Req.Message := 'Sign in';
  Req.URL := 'https://login.example.com/start?x=1';
  H := TTypedConsole.Create(['d']);
  try
    R := H.Elicit(Req);
    Check(R.Action = eaAccept, 'console url: done is accept');
    Check(Has(H.Shown, 'https://login.example.com/start?x=1'), 'console url: shows the full URL');
    Check(Has(H.Shown, 'login.example.com'), 'console url: shows the host');
    Check(Has(H.Shown, 'does not open'), 'console url: says PasClaw will not open it');
  finally
    H.Free;
  end;
  H := TTypedConsole.Create([]);
  try
    Check(H.Elicit(Req).Action = eaCancel, 'console url: closed stdin cancels');
  finally
    H.Free;
  end;
end;

procedure TestHeaders;
var
  Specs: TMCPParamHeaderArray;
  Err: string;
  H: TMCPHeaderArray;
begin
  Check(EncodeMcpHeaderValue('us-west1') = 'us-west1', 'header: plain ASCII as-is');
  Check(EncodeMcpHeaderValue('Hello, 世界') = '=?base64?SGVsbG8sIOS4lueVjA==?=', 'header: non-ASCII is base64');
  Check(EncodeMcpHeaderValue(' padded ') = '=?base64?IHBhZGRlZCA=?=', 'header: edge blanks are base64');
  Check(EncodeMcpHeaderValue('=?base64?literal?=') = '=?base64?PT9iYXNlNjQ/bGl0ZXJhbD89?=',
        'header: a sentinel-looking value is base64');
  Check(ExtractParamHeaders('{"type":"object","properties":{"region":{"type":"string","x-mcp-header":"Region"},' +
        '"opts":{"type":"object","properties":{"n":{"type":"integer","x-mcp-header":"N"}}}}}', Specs, Err)
        and (Length(Specs) = 2), 'header: nested properties chain is reachable');
  H := ParamHeadersFor(Specs, '{"region":"eu","opts":{"n":7}}');
  Check((Length(H) = 2) and (H[0].Name = 'Mcp-Param-Region') and (H[0].Value = 'eu') and
        (H[1].Value = '7'), 'header: values come from the argument paths');
  H := ParamHeadersFor(Specs, '{"region":null}');
  Check(Length(H) = 0, 'header: null and absent arguments get no header');
  Check(not ExtractParamHeaders('{"type":"object","properties":{"xs":{"type":"array","items":' +
        '{"type":"string","x-mcp-header":"X"}}}}', Specs, Err), 'header: under items is refused');
  Check(not ExtractParamHeaders('{"properties":{"f":{"type":"number","x-mcp-header":"F"}}}', Specs, Err),
        'header: a number property is refused');
  Check(not ExtractParamHeaders('{"properties":{"a":{"type":"string","x-mcp-header":"A"},' +
        '"b":{"type":"string","x-mcp-header":"a"}}}', Specs, Err), 'header: duplicates are refused');
  Check(McpNameFor('tasks/get', '{"taskId":"t1"}') = 't1', 'header: Mcp-Name of tasks/get is the taskId');
end;

procedure TestSSEAndVersions;
var
  Body: string;
begin
  Body := 'event: message'#10'data: {"jsonrpc":"2.0","method":"notifications/progress","params":{}}'#10#10 +
          ': ping'#10#10'data: {"jsonrpc":"2.0","id":7,"result":{"ok":true}}'#10#10;
  Check(Has(SSEResponseFor(Body, 7), '"ok"') and not Has(SSEResponseFor(Body, 7), 'progress'),
        'sse: the response is picked out from behind a notification');
  Body := '{"jsonrpc":"2.0","id":1,"result":{"icon":"data:image/png;base64,AAAA"}}';
  Check(SSEResponseFor(Body, 1) = Body, 'sse: a JSON reply that mentions data: is left alone');
  Check(PickLegacyVersion('["2026-07-28","2025-06-18","2024-11-05"]') = '2025-06-18',
        'versions: the newest legacy revision in common');
  Check(PickLegacyVersion('["1999-01-01"]') = '', 'versions: none in common');
end;


procedure TestOAuthChecks;
var
  Cb: TAuthCallbackParams;
  Code, Err: string;
  Tok: TOAuthTokens;
begin
  Cb.Code := 'abc';
  Cb.State := 's1';
  Cb.Iss := 'https://evil.example';
  Cb.HasIss := True;
  Cb.Error := '';
  Cb.ErrorDescription := '';
  Check(not ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', False, Code, Err),
        'oauth: iss mismatch is rejected');
  Check((Code = '') and Has(Err, 'https://as.example'), 'oauth: no code is handed out on a mismatch');
  Cb.Error := 'access_denied';
  Cb.ErrorDescription := 'click here http://phish';
  ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', False, Code, Err);
  Check(not Has(Err, 'phish'), 'oauth: a mismatched response''s error text is not shown');
  Cb.Error := '';
  Cb.ErrorDescription := '';
  Cb.Iss := 'https://as.example/';
  Check(not ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', False, Code, Err),
        'oauth: no normalisation -- a trailing slash is a different issuer');
  Cb.Iss := 'https://as.example';
  Check(ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', True, Code, Err) and (Code = 'abc'),
        'oauth: matching iss passes');
  Cb.HasIss := False;
  Cb.Iss := '';
  Check(not ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', True, Code, Err),
        'oauth: absent iss is rejected when the server advertises it');
  Check(ValidateAuthorizationResponse(Cb, 's1', 'https://as.example', False, Code, Err),
        'oauth: absent iss passes when the server does not advertise it');
  Check(not ValidateAuthorizationResponse(Cb, 's2', 'https://as.example', False, Code, Err),
        'oauth: state mismatch is rejected');
  { Forgetting a stored registration on invalid_client / unauthorized_client
    takes a response that passed the issuer and state checks: a forged
    request to the loopback callback must not wipe it. }
  Cb.Code := '';
  Cb.Error := 'invalid_client';
  Cb.HasIss := True;
  Cb.Iss := 'https://as.example';
  Cb.State := 's1';
  Check(ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: an authentic invalid_client forgets the reused registration');
  Cb.Error := 'unauthorized_client';
  Check(ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: an authentic unauthorized_client forgets it too');
  Check(not ShouldForgetClient(Cb, 's1', 'https://as.example', True, False),
        'oauth: a fresh registration has nothing to forget');
  Cb.State := 'forged';
  Check(not ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: invalid_client with the wrong state keeps the registration');
  Cb.State := 's1';
  Cb.Iss := 'https://evil.example';
  Check(not ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: invalid_client from another issuer keeps the registration');
  Cb.HasIss := False;
  Cb.Iss := '';
  Check(not ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: invalid_client without the advertised iss keeps the registration');
  Cb.HasIss := True;
  Cb.Iss := 'https://as.example';
  Cb.Error := 'access_denied';
  Check(not ShouldForgetClient(Cb, 's1', 'https://as.example', True, True),
        'oauth: other errors keep the registration');
  Cb.Error := '';
  Check(Has(ClientRegistrationBody('http://127.0.0.1:5/cb'), '"application_type":"native"') or
        Has(ClientRegistrationBody('http://127.0.0.1:5/cb'), '"application_type" : "native"'),
        'oauth: DCR declares a native application');
  Tok := Default(TOAuthTokens);
  Tok.ClientId := 'c1';
  Tok.ClientIssuer := 'https://as.example';
  Tok.ClientRedirectURI := 'http://127.0.0.1:5/cb';
  Tok.ClientRegistration := 'dcr';
  Check(CanReuseClient(Tok, 'https://as.example'), 'oauth: same issuer reuses the registration');
  Check(not CanReuseClient(Tok, 'https://other.example'), 'oauth: another issuer never reuses it');
end;

{ ======================================================= against the fake }

procedure TestModernStdio;
var
  C: TMCPStdioClient;
  Log, Err, Text, Json, Line, Meta: string;
  Tools: TMCPToolArray;
begin
  Log := NewLog('modern');
  C := StdioFake(Log, '--era modern');
  try
    Check(C.Connect(10000, Err), 'modern stdio: connects (' + Err + ')');
    Check(C.ServerInfo.ProtocolVersion = MCPProtocolModern, 'modern stdio: negotiated 2026-07-28');
    Check(C.ServerInfo.Modern and (C.ServerInfo.Negotiation = 'server/discover'),
          'modern stdio: via server/discover');
    Check(C.ServerInfo.Name = 'fake-mcp', 'modern stdio: serverInfo from _meta');
    Check(C.ServerInfo.Caps.Tasks, 'modern stdio: tasks extension seen');
    Check(C.ListTools(Tools, Err) and (Length(Tools) >= 5), 'modern stdio: tools/list');
    Check(C.CallTool('echo', '{"text":"hi"}', Text, Err) and (Text = 'echo:hi'), 'modern stdio: tools/call');
    Check(C.CallToolStructured('plain', '{}', Text, Json, Err) and (Text = 'plain result'),
          'modern stdio: a result without resultType is complete');
  finally
    C.Free;
  end;
  Check(CountMethod(Log, 'initialize') = 0, 'modern stdio: no initialize was sent');
  Check(CountMethod(Log, 'notifications/initialized') = 0, 'modern stdio: no initialized notification');
  Line := LoggedMsg(Log, 'tools/call');
  Meta := LineMeta(Line);
  Check(Has(Meta, '"io.modelcontextprotocol/protocolVersion"') and Has(Meta, '2026-07-28'),
        'modern stdio: tools/call carries the protocol version');
  Check(Has(Meta, 'io.modelcontextprotocol/clientInfo') and Has(Meta, 'pasclaw'),
        'modern stdio: tools/call carries clientInfo');
  Check(Has(Meta, 'io.modelcontextprotocol/clientCapabilities') and Has(Meta, 'io.modelcontextprotocol/tasks'),
        'modern stdio: tools/call carries capabilities incl. the tasks extension');
  Check(not Has(Meta, 'elicitation'), 'modern stdio: no elicitation declared without a handler');
  Check(Has(LineMeta(LoggedMsg(Log, 'tools/list')), '2026-07-28'), 'modern stdio: tools/list carries _meta');
end;

function TestLegacyStdio(const Extra, Want: string; TimeoutMs: Integer; const Tag: string): string;
var
  C: TMCPStdioClient;
  Log, Err, Text: string;
  Tools: TMCPToolArray;
begin
  Log := NewLog('legacy');
  Result := Log;
  C := StdioFake(Log, Extra);
  try
    Check(C.Connect(TimeoutMs, Err), Tag + ': connects (' + Err + ')');
    Check(C.ServerInfo.ProtocolVersion = Want, Tag + ': negotiated ' + Want + ', got ' + C.ServerInfo.ProtocolVersion);
    Check(not C.ServerInfo.Modern, Tag + ': handshake era');
    Check(Has(C.ServerInfo.Negotiation, 'initialize'), Tag + ': via initialize');
    Check(C.ListTools(Tools, Err), Tag + ': tools/list (' + Err + ')');
    Check(C.CallTool('echo', '{"text":"x"}', Text, Err) and (Text = 'echo:x'), Tag + ': tools/call (' + Err + ')');
  finally
    C.Free;
  end;
  Check(CountMethod(Log, 'server/discover') = 1, Tag + ': probed once with server/discover');
  Check(CountMethod(Log, 'initialize') = 1, Tag + ': initialize sent');
  Check(CountMethod(Log, 'notifications/initialized') = 1, Tag + ': initialized notification sent');
  Check(LineMeta(LoggedMsg(Log, 'tools/call')) = '', Tag + ': legacy requests carry no _meta');
end;

procedure TestLegacyFallbacks;
var
  Log, Err: string;
  C: TMCPStdioClient;
begin
  { an error to the probe; the client offers 2025-11-25 and accepts the answer }
  TestLegacyStdio('--era legacy', '2025-11-25', 10000, 'legacy');
  Log := NewLog('offer');
  C := StdioFake(Log, '--era legacy');
  try
    C.Connect(10000, Err);
  finally
    C.Free;
  end;
  Check(LineParam(LoggedMsg(Log, 'initialize'), 'protocolVersion') = '"2025-11-25"',
        'legacy: initialize offers 2025-11-25');
  { older servers that answer with their own revision }
  TestLegacyStdio('--era legacy --legacy-version 2024-11-05', '2024-11-05', 10000, 'legacy 2024-11-05');
  TestLegacyStdio('--era legacy --legacy-version 2025-06-18', '2025-06-18', 10000, 'legacy 2025-06-18');
  TestLegacyStdio('--era legacy --legacy-version 2025-11-25', '2025-11-25', 10000, 'legacy 2025-11-25');
  { a strict server that exits on the probe is started again }
  Log := TestLegacyStdio('--era legacy --exit-on-unknown', '2025-11-25', 10000, 'legacy exits on probe');
  { silence: the probe times out }
  TestLegacyStdio('--era legacy --silent-unknown', '2025-11-25', 1500, 'legacy silent');
  { UnsupportedProtocolVersionError: initialize with the version listed }
  Log := TestLegacyStdio('--era both --discover-unsupported --legacy-version 2025-06-18', '2025-06-18', 10000,
                         'unsupported-version');
  Check(LineParam(LoggedMsg(Log, 'initialize'), 'protocolVersion') = '"2025-06-18"',
        'unsupported-version: initialize offers the version the error listed');
  { a line on stdout that is not JSON is skipped, not fatal }
  Log := NewLog('noisy');
  C := StdioFake(Log, '--era modern --noisy');
  try
    Check(C.Connect(10000, Err) and C.ServerInfo.Modern, 'noisy stdout: still connects (' + Err + ')');
  finally
    C.Free;
  end;
  { dual-era: stays modern }
  Log := NewLog('both');
  C := StdioFake(Log, '--era both');
  try
    Check(C.Connect(10000, Err) and C.ServerInfo.Modern, 'dual-era: modern');
  finally
    C.Free;
  end;
  Check(CountMethod(Log, 'initialize') = 0, 'dual-era: no initialize');
end;

procedure TestMRTR;
var
  C: TMCPStdioClient;
  H: TScripted;
  Log, Err, Text, First, Retry, Meta: string;
begin
  Log := NewLog('mrtr');
  C := StdioFake(Log, '--era modern');
  H := TScripted.Create(eaAccept, '{"name":"Ada","age":36,"color":"blue"}');
  try
    Check(C.Connect(10000, Err), 'mrtr: connects');
    SetThreadMCPElicitationHandler(H);
    Check(C.CallTool('ask_form', '{}', Text, Err), 'mrtr form: call succeeds (' + Err + ')');
    Check(Text = 'ask_form:accept:{"age":36,"color":"blue","name":"Ada"}', 'mrtr form: server got the answers: ' + Text);
    Check((H.Seen.Count = 1) and Has(H.Seen[0], 'Tell me about yourself') and Has(H.Seen[0], 'fake'),
          'mrtr form: the handler saw the request with the server name');
    First := LoggedMsg(Log, 'tools/call', 0);
    Retry := LoggedMsg(Log, 'tools/call', 1);
    Check(LineParam(First, 'inputResponses') = '', 'mrtr form: the first call has no inputResponses');
    Check(Has(LineParam(Retry, 'inputResponses'), '"profile"'), 'mrtr form: the retry carries inputResponses');
    Check(LineParam(Retry, 'requestState') = '"state-ask_form-1"', 'mrtr form: the retry echoes requestState');
    Check(LineId(First) <> LineId(Retry), 'mrtr form: the retry has a new id');
    Meta := LineMeta(First);
    Check(Has(Meta, '"elicitation"') and Has(Meta, '"url"') and Has(Meta, '"form"'),
          'mrtr: elicitation form+url declared when a handler is set');

    Check(C.CallTool('ask_url', '{}', Text, Err) and (Text = 'ask_url:accept:null'), 'mrtr url: accepted: ' + Text + Err);
    Check((H.Seen.Count > 0) and Has(H.Seen[H.Seen.Count - 1], 'https://auth.example.com/connect?flow=42'),
          'mrtr url: handler got the URL');

    Check(not C.CallTool('ask_forever', '{}', Text, Err) and Has(Err, 'rounds'), 'mrtr: rounds are capped: ' + Err);
    Check(CountMethod(Log, 'tools/call') = 4 + MCPMaxInputRounds + 1, 'mrtr: cap counted the calls');

    { nobody to ask: decline, no retry, a note for the model }
    SetThreadMCPElicitationHandler(nil);
    Check(not C.CallTool('ask_url', '{}', Text, Err), 'mrtr decline: url call does not succeed');
    Check(Has(Err, 'https://auth.example.com/connect?flow=42') and Has(Err, 'declined'),
          'mrtr decline: the model gets the URL: ' + Err);
    Check(not Has(LineMeta(LoggedMsg(Log, 'tools/call', CountMethod(Log, 'tools/call') - 1)), 'elicitation'),
          'mrtr decline: no elicitation declared without a handler');
    Check(LineParam(LoggedMsg(Log, 'tools/call', CountMethod(Log, 'tools/call') - 1), 'inputResponses') = '',
          'mrtr decline: not retried');
    Check(not C.CallTool('ask_form', '{}', Text, Err) and Has(Err, 'fields: name, age'),
          'mrtr decline: form note names the fields: ' + Err);
  finally
    SetThreadMCPElicitationHandler(nil);
    C.Free;
    H.Free;
  end;
end;

procedure TestLegacyElicitation;
var
  C: TMCPStdioClient;
  H: TScripted;
  Log, Err, Text: string;
begin
  Log := NewLog('legacy-elicit');
  H := TScripted.Create(eaAccept, '{"name":"Bo","age":50}');
  SetMCPProcessElicitationHandler(H);
  C := StdioFake(Log, '--era legacy');
  try
    Check(C.Connect(10000, Err), 'legacy elicit: connects');
    Check(Has(LineParam(LoggedMsg(Log, 'initialize'), 'capabilities'), 'elicitation'),
          'legacy elicit: initialize declares elicitation');
    SetThreadMCPElicitationHandler(H);
    Check(C.CallTool('ask_form', '{}', Text, Err) and (Text = 'ask_form:accept:{"age":50,"name":"Bo"}'),
          'legacy elicit: form answered over stdio: ' + Text + Err);
    Check(C.CallTool('ask_url', '{}', Text, Err) and (Text = 'ask_url:accept:null'),
          'legacy elicit: url answered: ' + Text + Err);
    SetThreadMCPElicitationHandler(nil);
    Check(C.CallTool('ask_url', '{}', Text, Err), 'legacy elicit unattended: the call completes');
    Check(Has(Text, 'ask_url:decline') and Has(Text, 'https://auth.example.com/connect?flow=42'),
          'legacy elicit unattended: declined, the note carries the URL: ' + Text);
  finally
    SetThreadMCPElicitationHandler(nil);
    SetMCPProcessElicitationHandler(nil);
    C.Free;
    H.Free;
  end;
end;

procedure TestTasks;
var
  C: TMCPStdioClient;
  H: TScripted;
  Log, Err, Text: string;
begin
  Log := NewLog('tasks');
  C := StdioFake(Log, '--era modern');
  H := TScripted.Create(eaAccept, '{"proceed":true}');
  try
    Check(C.Connect(10000, Err), 'tasks: connects');
    Check(C.CallTool('slow_task', '{}', Text, Err) and (Text = 'task done after 3 polls'),
          'tasks: polled to completion: ' + Text + Err);
    Check(CountMethod(Log, 'tasks/get') = 3, 'tasks: three polls');
    Check(Has(LineMeta(LoggedMsg(Log, 'tasks/get')), '2026-07-28'), 'tasks: tasks/get carries _meta');
    Check(not C.CallTool('failing_task', '{}', Text, Err) and Has(Err, 'the job exploded'),
          'tasks: failure surfaces the error: ' + Err);
    SetThreadMCPElicitationHandler(H);
    Check(C.CallTool('input_task', '{}', Text, Err) and (Text = 'input_task:accept:{"proceed":true}'),
          'tasks: input via tasks/update: ' + Text + Err);
    Check(CountMethod(Log, 'tasks/update') = 1, 'tasks: one tasks/update');
    SetThreadMCPElicitationHandler(nil);
    Check(C.CallTool('input_task', '{}', Text, Err) and Has(Text, 'input_task:decline') and Has(Text, 'declined'),
          'tasks: unattended input is declined with a note: ' + Text + Err);
    { the user's answering time is not taken from the call's budget }
    SetThreadMCPElicitationHandler(H);
    H.DelayMs := 1500;
    C.CallTimeoutMs := 1000;
    Check(C.CallTool('input_task', '{}', Text, Err) and Has(Text, 'input_task:accept'),
          'tasks: a slow answer does not time the task out: ' + Text + Err);
    H.DelayMs := 0;
    SetThreadMCPElicitationHandler(nil);
    C.CallTimeoutMs := 120;
    Check(not C.CallTool('slow_task', '{}', Text, Err) and Has(Err, 'timed out'),
          'tasks: the call timeout bounds polling: ' + Err);
    Check(CountMethod(Log, 'tasks/cancel') = 1, 'tasks: a timed-out task is cancelled');
  finally
    SetThreadMCPElicitationHandler(nil);
    C.Free;
    H.Free;
  end;
end;

procedure TestHttpModern;
var
  S: THttpFake;
  C: TMCPHttpClient;
  Log, Err, Text, Line: string;
  Tools: TMCPToolArray;
begin
  Log := NewLog('http-modern');
  S := THttpFake.Create(Log, '--era modern');
  try
    Check(S.URL <> '', 'http modern: fake server listening');
    C := TMCPHttpClient.Create('fakehttp', S.URL, '');
    try
      Check(C.Connect(10000, Err), 'http modern: connects (' + Err + ')');
      Check(C.ServerInfo.Modern and (C.ServerInfo.ProtocolVersion = MCPProtocolModern), 'http modern: 2026-07-28');
      Check(C.ListTools(Tools, Err), 'http modern: tools/list (' + Err + ')');
      Check(C.CallTool('echo', '{"text":"hey"}', Text, Err) and (Text = 'echo:hey'), 'http modern: tools/call ' + Err);
      Check(C.CallTool('regional', '{"region":"eu-west","query":"q"}', Text, Err) and (Text = 'region:eu-west'),
            'http modern: x-mcp-header argument mirrored (' + Err + ')');
      Check(C.CallTool('progress_echo', '{}', Text, Err) and (Text = 'after progress'),
            'http modern: SSE response behind a progress notification (' + Err + ')');
      Check(C.CallTool('slow_task', '{}', Text, Err) and Has(Text, 'task done'), 'http modern: task over HTTP ' + Err);
    finally
      C.Free;
    end;
  finally
    S.Free;
  end;
  Check(CountMethod(Log, 'initialize') = 0, 'http modern: no initialize');
  Line := LoggedMsg(Log, 'tools/call');
  Check(LineHeader(Line, 'Mcp-Method') = 'tools/call', 'http modern: Mcp-Method header');
  Check(LineHeader(Line, 'Mcp-Name') = 'echo', 'http modern: Mcp-Name header');
  Check(LineHeader(Line, 'MCP-Protocol-Version') = MCPProtocolModern, 'http modern: MCP-Protocol-Version header');
  Check(not LineHasHeader(Line, 'Mcp-Session-Id'), 'http modern: no session id');
  Check(Has(LineHeader(Line, 'Accept'), 'application/json') and Has(LineHeader(Line, 'Accept'), 'text/event-stream'),
        'http modern: Accept names JSON and SSE: ' + LineHeader(Line, 'Accept'));
  Check(LineHeader(LoggedMsg(Log, 'server/discover'), 'Mcp-Method') = 'server/discover', 'http modern: probe headers');
  Check(LineHeader(LoggedMsg(Log, 'tools/call', 1), 'Mcp-Param-Region') = 'eu-west', 'http modern: Mcp-Param-Region');
  Check(Has(LineHeader(LoggedMsg(Log, 'tasks/get'), 'Mcp-Name'), 'task-'), 'http modern: tasks/get Mcp-Name is the taskId');
end;

procedure TestHttpLegacy(const Extra, Want, Tag: string);
var
  S: THttpFake;
  C: TMCPHttpClient;
  H: TScripted;
  Log, Err, Text, Line: string;
  Tools: TMCPToolArray;
begin
  Log := NewLog('http-legacy');
  S := THttpFake.Create(Log, Extra);
  H := TScripted.Create(eaAccept, '{}');
  SetMCPProcessElicitationHandler(H);
  try
    C := TMCPHttpClient.Create('fakehttp', S.URL, '');
    try
      Check(C.Connect(10000, Err), Tag + ': connects (' + Err + ')');
      Check(not C.ServerInfo.Modern and (C.ServerInfo.ProtocolVersion = Want),
            Tag + ': negotiated ' + Want + ', got ' + C.ServerInfo.ProtocolVersion);
      Check(C.ListTools(Tools, Err), Tag + ': tools/list (' + Err + ')');
      Check(C.CallTool('echo', '{"text":"x"}', Text, Err) and (Text = 'echo:x'), Tag + ': tools/call ' + Err);
    finally
      C.Free;
    end;
  finally
    SetMCPProcessElicitationHandler(nil);
    H.Free;
    S.Free;
  end;
  Line := LoggedMsg(Log, 'tools/call');
  Check(LineHeader(Line, 'Mcp-Session-Id') = 'sess-123', Tag + ': session id echoed');
  if Want >= '2025-06-18' then
    Check(LineHeader(Line, 'MCP-Protocol-Version') = Want, Tag + ': negotiated version header')
  else
    Check(not LineHasHeader(Line, 'MCP-Protocol-Version'), Tag + ': no version header before 2025-06-18');
  Check(not Has(LineParam(LoggedMsg(Log, 'initialize'), 'capabilities'), 'elicitation'),
        Tag + ': no elicitation declared over HTTP');
end;

procedure TestCallWhileConnectingWaitsForTheConnect;
(* The bridge registers a server's tools from its cache at once and
   connects in the background, so the model can call one before the live
   connect has ended. That call answered "still connecting -- retry in a
   moment" straight away: a one-shot run whose model called an MCP tool in
   its first reply failed whenever the server was slower to start than the
   model was to answer (mcp_client_e2e did, under load). It now waits for
   the connect to settle and then goes through. Here the server takes 1.5 s
   to start and the tool is called the moment it is registered. *)
const
  Srv = 'slowfake-q4';
var
  Cfg: TConfig;
  Reg: TToolRegistry;
  Clients: TMCPClientList;
  Servers: array of TMCPServer;
  Cached: TMCPToolArray;
  Res, Err: string;
  T0: QWord;
begin
  SetLength(Cached, 1);
  Cached[0].Name := 'echo';
  Cached[0].Description := 'echo text';
  Cached[0].Schema := '{"type":"object","properties":{"text":{"type":"string"}}}';
  Cached[0].Server := Srv;
  SaveCachedTools(Srv, Cached);
  SetLength(Servers, 1);
  Servers[0].Name := Srv;
  Servers[0].Cmd := Python;
  Servers[0].Args := '"' + FakeMCP + '" --era modern --start-delay 1.5 --log "' + NewLog('slow') + '"';
  Servers[0].Enabled := True;
  Servers[0].CodeMode := False;
  Cfg := TConfig.Create;
  Reg := TToolRegistry.Create;
  try
    Cfg.MCPProgressiveDisclosure := False;
    Clients := ConnectMCPServerList(Servers, Cfg, Reg);
    try
      T0 := GetTickCount64;
      Res := Reg.RunTool(Srv + '__echo', '{"text":"hi"}', Err);
      Check(Pos('still connecting', Err) = 0,
            'a call while the server connects waits for it: ' + Err);
      Check(Pos('echo:hi', Res) > 0, 'and goes through once it has: ' + Res + ' / ' + Err);
      Check(GetTickCount64 - T0 >= 1000, 'the call waited for the server to start');
    finally
      FreeMCPClients(Clients);
    end;
  finally
    Reg.Free;
    Cfg.Free;
    DeleteFile(CachePath(Srv));
  end;
  WriteLn('  ok: a call while the server connects waits for the connect');
end;

procedure TestInterop;
var
  C: TMCPStdioClient;
  Err, Text: string;
  Tools: TMCPToolArray;
  i: Integer;
  Found: Boolean;
begin
  if (PasclawBin = '') or not FileExists(PasclawBin) then
  begin
    WriteLn('  skip: interop (no PASCLAW_BIN)');
    Exit;
  end;
  C := TMCPStdioClient.Create('pasclaw', PasclawBin, 'mcp stdio');
  try
    Check(C.Connect(20000, Err), 'interop: connects to pasclaw mcp stdio (' + Err + ')');
    Check(C.ServerInfo.Modern and (C.ServerInfo.ProtocolVersion = MCPProtocolModern),
          'interop: pasclaw serves 2026-07-28 to us (' + C.ServerInfo.Negotiation + ')');
    Check(C.ServerInfo.Name = 'pasclaw', 'interop: serverInfo from server/discover');
    Check(C.ListTools(Tools, Err), 'interop: tools/list (' + Err + ')');
    Found := False;
    for i := 0 to High(Tools) do
      if Tools[i].Name = 'memory_search' then Found := True;
    Check(Found, 'interop: memory_search listed');
    Check(C.CallTool('memory_search', '{"query":"interop probe"}', Text, Err), 'interop: tools/call (' + Err + ')');
  finally
    C.Free;
  end;
end;

begin
  FakeMCP := GetEnvironmentVariable('FAKE_MCP');
  Python := GetEnvironmentVariable('MCP_PYTHON');
  if Python = '' then Python := 'python3';
  TestDir := GetEnvironmentVariable('MCP_TEST_DIR');
  if TestDir = '' then TestDir := GetTempDir;
  PasclawBin := GetEnvironmentVariable('PASCLAW_BIN');

  TestFormAnswers;
  TestConsoleDialogue;
  TestHeaders;
  TestSSEAndVersions;
  TestOAuthChecks;

  if (FakeMCP = '') or not FileExists(FakeMCP) then
    WriteLn('  skip: fake-server cases (FAKE_MCP not set)')
  else
  begin
    TestModernStdio;
    TestLegacyFallbacks;
    TestMRTR;
    TestLegacyElicitation;
    TestTasks;
    TestHttpModern;
    TestHttpLegacy('--era legacy', '2025-11-25', 'http legacy');
    TestHttpLegacy('--era legacy --legacy-version 2025-03-26', '2025-03-26', 'http legacy 2025-03-26');
    TestHttpLegacy('--era both --discover-unsupported --legacy-version 2025-06-18', '2025-06-18',
                   'http unsupported-version');
    TestInterop;
    TestCallWhileConnectingWaitsForTheConnect;
  end;

  if Failures = 0 then WriteLn('mcp_client_tests: OK')
  else begin WriteLn('mcp_client_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
