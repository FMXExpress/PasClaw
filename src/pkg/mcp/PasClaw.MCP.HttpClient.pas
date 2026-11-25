(*
  PasClaw.MCP.HttpClient - MCP over Streamable HTTP transport. The protocol
  (version negotiation, multi-round requests, tasks, elicitation) lives in
  PasClaw.MCP.Client; this unit is the POST.

  Each request is a single POST to the configured URL with the JSON-RPC
  envelope. The server answers with either

    * Content-Type: application/json  -> one JSON-RPC response
    * Content-Type: text/event-stream -> SSE events: request-scoped
      notifications (progress, log messages), then the response. We read
      the events and keep the one that answers our request id.

  Two eras, decided by the first request (see PasClaw.MCP.Client):

    2026-07-28 (modern) -- no session. Every POST carries
      MCP-Protocol-Version: 2026-07-28 (matching _meta), Mcp-Method,
      Mcp-Name for tools/call / resources/read / prompts/get / tasks/*, and
      an Mcp-Param-<Name> header per x-mcp-header argument of the tool
      being called. A tool whose x-mcp-header annotations break the rules
      is left out of tools/list, as the spec requires.

    up to 2025-11-25 (legacy) -- `initialize` handshake. The server may
      issue an Mcp-Session-Id, echoed on every later request; from
      2025-06-18 on, MCP-Protocol-Version carries the negotiated revision.
      Legacy servers can also send requests (elicitation/create) inside an
      SSE response and wait for our answer as a separate POST. Our HTTP
      layer reads a response whole, so it cannot answer mid-stream; the
      client therefore declares no elicitation capability on HTTP legacy
      connections (servers then must not ask). Modern elicitation arrives
      in the result itself and works over HTTP like over stdio.

  Auth tokens come from the configured `args` slot in the MCP server entry,
  shaped as "--header Authorization: Bearer ..." or just "Bearer ...", or
  from the OAuth token store (`pasclaw mcp auth <name>`).

  Spec: https://modelcontextprotocol.io/specification/2026-07-28/basic/transports/streamable-http
*)
unit PasClaw.MCP.HttpClient;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.MCP.Types,
  PasClaw.MCP.Client;

type
  TMCPHttpClient = class(TMCPProtocolClient)
  private
    FURL, FAuth: string;
    { Streamable-HTTP session id (legacy era only) -- issued by the server
      in the `Mcp-Session-Id` response header on `initialize`, and required
      back on every subsequent request per the MCP 2025-03-26 spec.
      Replicate's server returns 400 "Mcp-Session-Id header is required"
      if we don't echo it on tools/list etc. Never sent in modern mode. }
    FSessionId: string;
    { tool name -> its inputSchema, for the tools that carry x-mcp-header
      annotations. Guarded: tool calls may run on several threads. }
    FHeaderTools: TStringList;
    FHeaderLock: TCriticalSection;
    FHeadersKnown: Boolean;
    function ResolveAuth: string;
    procedure LearnTool(const Tool: TMCPTool);
    function ParamHeadersOf(const ParamsJSON: string): TArray<string>;
  protected
    procedure ResetTransportSession; override;
    function Exchange(const Method, ParamsJSON: string; Id, TimeoutMs: Integer;
                      Modern: Boolean): TMCPWireReply; override;
    procedure Notify(const Method, ParamsJSON: string); override;
    function AcceptListedTool(const Tool: TMCPTool): Boolean; override;
    function RecoverHeaderMismatch: Boolean; override;
  public
    constructor Create(const Name, URL, AuthHeader: string);
    destructor Destroy; override;
    procedure SetKnownTools(const Tools: TMCPToolArray); override;
  end;

{ The JSON-RPC message in an SSE body that answers request Id (a matching
  "id"); failing that, the last message with a result or error; a body that
  is not SSE comes back unchanged. Exposed for the unit test. }
function SSEResponseFor(const Body: string; Id: Integer): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.MCP.Headers,
  PasClaw.MCP.OAuth;

constructor TMCPHttpClient.Create(const Name, URL, AuthHeader: string);
begin
  inherited Create(Name);
  FURL    := URL;
  FAuth   := AuthHeader;
  { Unsorted: Values[] := on a sorted list raises when the name exists. }
  FHeaderTools := TStringList.Create;
  FHeaderLock := TCriticalSection.Create;
  FHeadersKnown := False;
  FCallTimeoutMs := 60000;
  FListTimeoutMs := 10000;
end;

destructor TMCPHttpClient.Destroy;
begin
  FHeaderTools.Free;
  FHeaderLock.Free;
  inherited Destroy;
end;

function SSEResponseFor(const Body: string; Id: Integer): string;
{ An SSE body is events separated by blank lines; an event's data is its
  `data:` lines joined with newlines. Joining every data line of the whole
  body into one string -- what this did before -- turns
  "progress notification, then response" into two concatenated objects
  that parse as nothing. }
var
  L: TStringList;
  i: Integer;
  Line, Data, Fallback: string;
  HaveData: Boolean;

  function Consider(const Msg: string): Boolean;
  var
    O: TJsonObject;
  begin
    Result := False;
    O := JsonTryParse(Msg);
    if O = nil then Exit;
    try
      if O.Has('method') then Exit;            { notification or server request }
      if not (O.Has('result') or O.Has('error')) then Exit;
      Fallback := Msg;
      Result := O.GetInt('id', -1) = Id;
    finally
      O.Free;
    end;
  end;

begin
  Result := Body;
  { A JSON reply is an object; an event stream starts with a field name
    (data:, event:, id:, retry:) or a ':' comment. Deciding on whether
    "data:" occurs anywhere took a JSON reply carrying a data: URI (an icon
    in serverInfo) for an event stream and lost it. }
  if (Trim(Body) = '') or (Trim(Body)[1] = '{') or (Pos('data:', Body) = 0) then Exit;
  Fallback := '';
  L := TStringList.Create;
  try
    L.Text := Body;
    Data := '';
    HaveData := False;
    for i := 0 to L.Count do
    begin
      if i < L.Count then Line := L[i] else Line := '';
      if Trim(Line) = '' then
      begin
        if HaveData and Consider(Data) then
        begin
          Result := Data;
          Exit;
        end;
        Data := '';
        HaveData := False;
        Continue;
      end;
      if Copy(Line, 1, 5) = 'data:' then
      begin
        Line := Copy(Line, 6, MaxInt);
        if (Line <> '') and (Line[1] = ' ') then Line := Copy(Line, 2, MaxInt);
        if HaveData then Data := Data + #10 + Line else Data := Line;
        HaveData := True;
      end;
      { event:, id:, retry: and ":" comments carry nothing we need }
    end;
    if Fallback <> '' then Result := Fallback else Result := '';
  finally
    L.Free;
  end;
end;

function PostMCP(const URL, Body: string; const Headers: THeaderPairs;
                 TimeoutSeconds: Integer): THTTPResult;
begin
  { Streamable HTTP requires one Accept naming both JSON and SSE (some
    servers answer 406 otherwise). PostJSON pins Accept to
    application/json, and a second Accept added as a custom header goes
    out as a duplicate, so post through PostRaw, which takes the Accept
    value itself. }
  Result := PostRaw(URL, 'application/json', Body, Headers, TimeoutSeconds, '',
                    'application/json, text/event-stream');
end;

function LooksLikeJsonRpcReply(const S: string): Boolean;
{ True when S parses as a JSON object carrying a JSON-RPC reply shape
  (result / error / jsonrpc). Used to salvage a streamed reply when the
  HTTP layer reports a bad/zero status but the body actually arrived, and
  to tell a modern server's 4xx JSON-RPC error from a legacy server's. }
var
  O: TJsonObject;
begin
  Result := False;
  if Trim(S) = '' then Exit;
  O := JsonTryParse(S);
  if O = nil then Exit;
  try
    Result := O.Has('result') or O.Has('error') or O.Has('jsonrpc');
  finally
    O.Free;
  end;
end;

function LookupHeader(const Headers: THeaderPairs; const Name: string): string;
{ Case-insensitive header lookup. HTTP header names are
  case-insensitive per RFC 7230 §3.2, and Indy + TNetHTTPClient
  surface them with whatever case the wire used (Replicate sends
  "Mcp-Session-Id"; other servers may send "mcp-session-id"). }
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Headers) do
    if SameText(Headers[i].Name, Name) then
    begin
      Result := Headers[i].Value;
      Exit;
    end;
end;

function TMCPHttpClient.ResolveAuth: string;
var
  AccessToken: string;
begin
  if FAuth <> '' then
  begin
    Result := FAuth;
    Exit;
  end;
  { Catalog/onboard installs of OAuth servers leave FAuth empty and
    defer to the on-disk token store under <home>/oauth/<name>.json.
    A successful `pasclaw mcp auth <name>` populates it; an absent
    file just means we send no Authorization header and let the
    server's 401 surface as the usual "auth required" error. }
  AccessToken := GetAccessToken(FName);
  if AccessToken = '' then
    Result := ''
  else
    Result := 'Bearer ' + AccessToken;
end;

procedure TMCPHttpClient.ResetTransportSession;
begin
  FSessionId := '';
end;

procedure TMCPHttpClient.LearnTool(const Tool: TMCPTool);
begin
  if Pos('x-mcp-header', Tool.Schema) = 0 then Exit;
  FHeaderLock.Acquire;
  try
    FHeaderTools.Values[Tool.Name] := Tool.Schema;
  finally
    FHeaderLock.Release;
  end;
end;

procedure TMCPHttpClient.SetKnownTools(const Tools: TMCPToolArray);
var
  i: Integer;
begin
  for i := 0 to High(Tools) do LearnTool(Tools[i]);
  FHeadersKnown := True;
end;

function TMCPHttpClient.AcceptListedTool(const Tool: TMCPTool): Boolean;
var
  Specs: TMCPParamHeaderArray;
  Err: string;
begin
  Result := inherited AcceptListedTool(Tool);
  if not Result then Exit;
  if not ExtractParamHeaders(Tool.Schema, Specs, Err) then
  begin
    LogWarn('mcp-http[%s] leaving out tool %s: %s', [FName, Tool.Name, Err]);
    Exit(False);
  end;
  LearnTool(Tool);
  FHeadersKnown := True;
end;

function TMCPHttpClient.RecoverHeaderMismatch: Boolean;
var
  Tools: TMCPToolArray;
  Err: string;
begin
  { The spec's recovery for HeaderMismatch: the tool's inputSchema may
    have changed, so re-read it and retry once. }
  FHeaderLock.Acquire;
  try
    FHeaderTools.Clear;
  finally
    FHeaderLock.Release;
  end;
  Result := ListTools(Tools, Err);
end;

function TMCPHttpClient.ParamHeadersOf(const ParamsJSON: string): TArray<string>;
var
  P: TJsonObject;
  Tool, Schema, Err: string;
  Specs: TMCPParamHeaderArray;
  H: TMCPHeaderArray;
  i: Integer;
begin
  SetLength(Result, 0);
  P := JsonTryParse(ParamsJSON);
  if P = nil then Exit;
  try
    Tool := P.GetStr('name', '');
    FHeaderLock.Acquire;
    try
      Schema := FHeaderTools.Values[Tool];
    finally
      FHeaderLock.Release;
    end;
    if Schema = '' then Exit;
    if not ExtractParamHeaders(Schema, Specs, Err) then Exit;
    H := ParamHeadersFor(Specs, P.GetRaw('arguments', '{}'));
    SetLength(Result, Length(H) * 2);
    for i := 0 to High(H) do
    begin
      Result[i * 2] := H[i].Name;
      Result[i * 2 + 1] := H[i].Value;
    end;
  finally
    P.Free;
  end;
end;

function TMCPHttpClient.Exchange(const Method, ParamsJSON: string; Id, TimeoutMs: Integer;
                                 Modern: Boolean): TMCPWireReply;
var
  Req: TJsonObject;
  Body, EffectiveAuth, RefreshErr, Got, Name, Negotiated: string;
  Headers: THeaderPairs;
  Resp: THTTPResult;
  TimeoutSeconds: Integer;
  Params: TArray<string>;
  Tools: TMCPToolArray;

  procedure Add(const N, V: string);
  begin
    SetLength(Headers, Length(Headers) + 1);
    Headers[High(Headers)] := MakeHeader(N, V);
  end;

  procedure BuildHeaders;
  var
    j: Integer;
  begin
    SetLength(Headers, 0);
    if EffectiveAuth <> '' then Add('Authorization', EffectiveAuth);
    if Modern then
    begin
      { The body's _meta says 2026-07-28; the header must say the same or
        the server rejects the request (HeaderMismatch). }
      Add('MCP-Protocol-Version', MCPProtocolModern);
      Add('Mcp-Method', Method);
      Name := McpNameFor(Method, ParamsJSON);
      if Name <> '' then Add('Mcp-Name', EncodeMcpHeaderValue(Name));
      for j := 0 to (Length(Params) div 2) - 1 do
        Add(Params[j * 2], Params[j * 2 + 1]);
    end
    else
    begin
      if FSessionId <> '' then Add('Mcp-Session-Id', FSessionId);
      { 2025-06-18 made the negotiated revision a header on every request
        after initialize; older revisions did not define it. }
      Negotiated := FInfo.ProtocolVersion;
      if (Method <> 'initialize') and (Negotiated >= '2025-06-18') then
        Add('MCP-Protocol-Version', Negotiated);
    end;
  end;

begin
  Result.Body := '';
  Result.HttpStatus := 0;
  Result.Err := '';
  Result.TimedOut := False;
  { Exchange takes MILLISECONDS (the client contract); PostJSON takes
    SECONDS. Round up, at least 1s. Passing raw ms as seconds once gave a
    streamable-HTTP server that holds the socket open an ~8h read
    timeout. }
  TimeoutSeconds := (TimeoutMs + 999) div 1000;
  if TimeoutSeconds < 1 then TimeoutSeconds := 1;

  Req := TJsonObject.Create;
  try
    Req.PutStr('jsonrpc', JSONRPCVersion);
    Req.PutInt('id', Id);
    Req.PutStr('method', Method);
    if ParamsJSON <> '' then Req.PutRaw('params', ParamsJSON);
    Body := Req.ToJSON;
  finally
    Req.Free;
  end;

  SetLength(Params, 0);
  if Modern and (Method = 'tools/call') then
  begin
    { A tool the bridge took from its cache was never listed by this
      client: learn the schemas once so x-mcp-header arguments get their
      headers. }
    if not FHeadersKnown then
    begin
      FHeadersKnown := True;
      ListTools(Tools, RefreshErr);
    end;
    Params := ParamHeadersOf(ParamsJSON);
  end;

  EffectiveAuth := ResolveAuth;
  BuildHeaders;
  Resp := PostMCP(FURL, Body, Headers, TimeoutSeconds);

  { OAuth refresh-and-retry: a 401 against a server we have stored
    tokens for usually means the access token expired between our
    last-checked expiry and now. Try one silent refresh, then retry
    the request. If refresh fails (or this isn't an OAuth server),
    surface the original failure. }
  if (Resp.StatusCode = 401) and (FAuth = '') and HasStoredTokens(FName) then
  begin
    if ForceRefresh(FName, RefreshErr) then
    begin
      EffectiveAuth := ResolveAuth;
      if EffectiveAuth <> '' then
      begin
        BuildHeaders;
        Resp := PostMCP(FURL, Body, Headers, TimeoutSeconds);
      end;
    end
    else
      LogWarn('mcp-http[%s] 401 + refresh failed: %s', [FName, RefreshErr]);
  end;

  Result.HttpStatus := Resp.StatusCode;
  Got := SSEResponseFor(Resp.Body, Id);

  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    { A JSON-RPC body is the answer whatever the status: a modern server
      sends its errors (unsupported version, unknown method, header
      mismatch) with 400/404, and the caller tells eras apart by that
      body. It also salvages a streamed reply: Streamable-HTTP servers
      (Replicate among them) send the response as one SSE event and then
      hold or abruptly close the connection; the HTTP layer raises on that
      and reports status 0 although the response arrived intact. }
    if LooksLikeJsonRpcReply(Got) then
    begin
      if (not Modern) and (FSessionId = '') then
        FSessionId := LookupHeader(Resp.RespHeaders, 'Mcp-Session-Id');
      Result.Body := Got;
      Exit;
    end;
    LogDebug('mcp-http[%s] %s status=%d body=%s',
             [FName, Method, Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    if Resp.StatusCode = 401 then
      Result.Err := Format('HTTP 401 unauthorized (run `pasclaw mcp auth %s` ' +
                           'if this server uses OAuth)', [FName])
    else if Resp.StatusCode > 0 then
      Result.Err := Format('HTTP %d %s', [Resp.StatusCode, Copy(Trim(Resp.Body), 1, 160)])
    else if Resp.ErrorMsg <> '' then
      Result.Err := Resp.ErrorMsg
    else
      Result.Err := 'no HTTP response';
    if (Resp.StatusCode <= 0) and (Pos('timed out', LowerCase(Resp.ErrorMsg)) > 0) then
      Result.TimedOut := True;
    Exit;
  end;
  { Legacy Streamable HTTP: latch the session id the server issued
    (initialize sets it; we echo it on every later request). A modern
    exchange has no session and ignores any id a server sends. }
  if (not Modern) and (FSessionId = '') then
    FSessionId := LookupHeader(Resp.RespHeaders, 'Mcp-Session-Id');
  if Trim(Got) = '' then
  begin
    Result.Err := Format('HTTP %d with an empty body', [Resp.StatusCode]);
    Exit;
  end;
  Result.Body := Got;
end;

procedure TMCPHttpClient.Notify(const Method, ParamsJSON: string);
var
  N: TJsonObject;
  Headers: THeaderPairs;
  Auth, Body: string;
  Resp: THTTPResult;
  Cnt: Integer;
begin
  N := TJsonObject.Create;
  try
    N.PutStr('jsonrpc', JSONRPCVersion);
    N.PutStr('method', Method);
    if ParamsJSON <> '' then N.PutRaw('params', ParamsJSON);
    Body := N.ToJSON;
  finally
    N.Free;
  end;
  { Only legacy connections notify (notifications/initialized), so this
    carries the legacy headers. }
  Auth := ResolveAuth;
  Cnt := 0;
  SetLength(Headers, 3);
  if Auth <> '' then begin Headers[Cnt] := MakeHeader('Authorization', Auth); Inc(Cnt); end;
  if FSessionId <> '' then begin Headers[Cnt] := MakeHeader('Mcp-Session-Id', FSessionId); Inc(Cnt); end;
  if FInfo.ProtocolVersion >= '2025-06-18' then
  begin
    Headers[Cnt] := MakeHeader('MCP-Protocol-Version', FInfo.ProtocolVersion);
    Inc(Cnt);
  end;
  SetLength(Headers, Cnt);
  Resp := PostMCP(FURL, Body, Headers, 10);
  if (Resp.StatusCode <> 0) and ((Resp.StatusCode < 200) or (Resp.StatusCode >= 300)) then
    LogDebug('mcp-http[%s] %s -> HTTP %d', [FName, Method, Resp.StatusCode]);
end;

end.
