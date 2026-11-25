(*
  PasClaw.MCP.Elicit - who answers when an MCP server asks the user for
  something (MCP "elicitation").

  A server asks in one of two ways, and both end up here:

    - 2026-07-28 (modern): the result of tools/call is an InputRequiredResult
      whose inputRequests carry `elicitation/create` requests; the client
      answers them by retrying the call with inputResponses. The tasks
      extension surfaces the same requests from tasks/get.
    - 2025-06-18 .. 2025-11-25 (legacy): the server sends its own
      `elicitation/create` JSON-RPC request while the tools/call is in
      flight, and the client answers it like any request.

  Two modes. Form mode asks for a flat object of primitive fields (string,
  number, integer, boolean, enum, multi-select enum). URL mode asks the user
  to go to a URL themselves -- PasClaw never opens or fetches it.

  Who answers depends on where the tool call came from, so the handler is
  per thread, not per process: the tool loop publishes its configured
  handler (TToolLoopConfig.Elicitor) on the thread that dispatches each
  tool call, the same way it publishes the sandbox workspace. The REPLs
  (`pasclaw agent` interactive, the FPC `pasclaw tui`) configure the
  console handler; the gateway, one-shot runs, subagents, ACP and the
  workflow engine configure none, and a request that reaches a thread with
  no handler is declined with a note telling the model what was asked (and,
  in URL mode, the URL to hand to the user).

  The process handler is separate and only decides what a legacy
  `initialize` advertises: that handshake happens once, on a background
  loader thread, before any tool loop exists.
*)
unit PasClaw.MCP.Elicit;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TMCPElicitMode = (emForm, emURL);

  TMCPElicitRequest = record
    Server:     string;   { configured MCP server name -- the user must see who asks }
    Mode:       TMCPElicitMode;
    Message:    string;
    URL:        string;   { URL mode }
    SchemaJSON: string;   (* form mode: requestedSchema, an empty object when absent *)
  end;

  TMCPElicitAction = (eaAccept, eaDecline, eaCancel);

  TMCPElicitResponse = record
    Action:      TMCPElicitAction;
    ContentJSON: string;   { form-mode accept: the submitted object; '' otherwise }
    { Set only when nobody could answer (no handler on this thread, or the
      handler cannot do this mode): what the model should be told. }
    Note:        string;
  end;

  TMCPElicitationHandler = class
  public
    function CanForm: Boolean; virtual;
    function CanURL: Boolean; virtual;
    function Elicit(const Req: TMCPElicitRequest): TMCPElicitResponse; virtual; abstract;
  end;

  (* The terminal answers: one prompt per form field, typed per the
     schema, then a review step; URL mode shows the full URL and its host
     and waits for the user to say they are done. Prompts are serialised
     with the permission asks (BeginInteractiveAsk), since parallel tool
     calls would otherwise read the same stdin. ReadAnswer / Show are
     virtual so a test can drive the dialogue without a terminal. *)
  TMCPConsoleElicitationHandler = class(TMCPElicitationHandler)
  protected
    function ReadAnswer(out Line: string): Boolean; virtual;
    procedure Show(const S: string; NewLine: Boolean = True); virtual;
    function AskForm(const Req: TMCPElicitRequest): TMCPElicitResponse;
    function AskURL(const Req: TMCPElicitRequest): TMCPElicitResponse;
  public
    function Elicit(const Req: TMCPElicitRequest): TMCPElicitResponse; override;
  end;

{ Process-wide handler: only decides what a legacy `initialize` advertises.
  Not owned. }
procedure SetMCPProcessElicitationHandler(H: TMCPElicitationHandler);
function  MCPProcessElicitationHandler: TMCPElicitationHandler;

{ The handler for tool calls made on this thread; nil = nobody to ask.
  Not owned. The tool loop sets and restores it around each dispatch. }
procedure SetThreadMCPElicitationHandler(H: TMCPElicitationHandler);
function  ThreadMCPElicitationHandler: TMCPElicitationHandler;

{ The shared console handler instance (owned by this unit). }
function ConsoleElicitationHandler: TMCPElicitationHandler;

{ Answer Req through H, or decline with a note when H is nil or cannot do
  the requested mode. }
function RunElicitation(H: TMCPElicitationHandler;
                        const Req: TMCPElicitRequest): TMCPElicitResponse;

{ Parse `elicitation/create` params. A missing mode is form mode. False
  (with Err) for a URL request without a url or a mode we do not know. }
function ElicitRequestFromParams(const Server, ParamsJSON: string;
                                 out Req: TMCPElicitRequest;
                                 out Err: string): Boolean;
(* The ElicitResult object: {"action":..., "content":{...}}. *)
function ElicitResponseToJSON(const R: TMCPElicitResponse): string;
function ElicitActionName(A: TMCPElicitAction): string;
(* The `elicitation` capability object H can honour ('' = none):
   {"form":{},"url":{}} or a subset. *)
function ElicitCapabilityJSON(H: TMCPElicitationHandler): string;
{ What the model is told when nobody could answer Req. }
function UnattendedElicitNote(const Req: TMCPElicitRequest): string;

{ Form helpers, pure so a test can pin them.

  ParseFormAnswer turns what the user typed into the JSON value for one
  field per its schema: integer/number/boolean parsing, enum and oneOf
  matching (by value, title or 1-based index), multi-select lists
  (comma-separated), and the length / range / item-count limits. }
function ParseFormAnswer(const PropSchemaJSON, Input: string;
                         out ValueJSON, Err: string): Boolean;
{ One-line prompt label for a field: name, type, choices, limits, default. }
function DescribeFormField(const Name, PropSchemaJSON: string;
                           Required: Boolean): string;
{ Lower-cased host of a URL ('' when there is none). }
function URLHost(const URL: string): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.CliUI,
  PasClaw.Permissions;   { BeginInteractiveAsk -- one prompt at a time on the terminal }

var
  GProcessHandler: TMCPElicitationHandler = nil;
  GConsole: TMCPConsoleElicitationHandler = nil;

threadvar
  GThreadHandler: TMCPElicitationHandler;

{ ---------------------------------------------------------- handlers }

function TMCPElicitationHandler.CanForm: Boolean;
begin
  Result := True;
end;

function TMCPElicitationHandler.CanURL: Boolean;
begin
  Result := True;
end;

procedure SetMCPProcessElicitationHandler(H: TMCPElicitationHandler);
begin
  GProcessHandler := H;
end;

function MCPProcessElicitationHandler: TMCPElicitationHandler;
begin
  Result := GProcessHandler;
end;

procedure SetThreadMCPElicitationHandler(H: TMCPElicitationHandler);
begin
  GThreadHandler := H;
end;

function ThreadMCPElicitationHandler: TMCPElicitationHandler;
begin
  Result := GThreadHandler;
end;

function ConsoleElicitationHandler: TMCPElicitationHandler;
begin
  Result := GConsole;
end;

function ElicitActionName(A: TMCPElicitAction): string;
begin
  case A of
    eaAccept:  Result := 'accept';
    eaDecline: Result := 'decline';
  else
    Result := 'cancel';
  end;
end;

function ElicitResponseToJSON(const R: TMCPElicitResponse): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('action', ElicitActionName(R.Action));
    { content only accompanies a form-mode accept }
    if (R.Action = eaAccept) and (R.ContentJSON <> '') then
      O.PutRaw('content', R.ContentJSON);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function ElicitCapabilityJSON(H: TMCPElicitationHandler): string;
var
  O, M: TJsonObject;
begin
  Result := '';
  if H = nil then Exit;
  if not (H.CanForm or H.CanURL) then Exit;
  O := TJsonObject.Create;
  try
    if H.CanForm then begin M := TJsonObject.Create; O.PutObject('form', M); end;
    if H.CanURL  then begin M := TJsonObject.Create; O.PutObject('url',  M); end;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function URLHost(const URL: string): string;
var
  P: Integer;
  Rest: string;
begin
  Result := '';
  P := Pos('://', URL);
  if P = 0 then Exit;
  Rest := Copy(URL, P + 3, MaxInt);
  P := Pos('/', Rest);
  if P > 0 then Rest := Copy(Rest, 1, P - 1);
  P := Pos('?', Rest);
  if P > 0 then Rest := Copy(Rest, 1, P - 1);
  P := Pos('#', Rest);
  if P > 0 then Rest := Copy(Rest, 1, P - 1);
  P := Pos('@', Rest);                      { drop userinfo: it is not the host }
  if P > 0 then Rest := Copy(Rest, P + 1, MaxInt);
  if (Rest <> '') and (Rest[1] = '[') then  { IPv6 literal }
  begin
    P := Pos(']', Rest);
    if P > 0 then Rest := Copy(Rest, 1, P);
  end
  else
  begin
    P := Pos(':', Rest);
    if P > 0 then Rest := Copy(Rest, 1, P - 1);
  end;
  Result := LowerCase(Rest);
end;

function FieldNames(const SchemaJSON: string): string;
var
  S, Props: TJsonObject;
  K: TStringList;
  i: Integer;
begin
  Result := '';
  S := JsonTryParse(SchemaJSON);
  if S = nil then Exit;
  try
    Props := S.ChildObject('properties');
    if Props = nil then Exit;
    try
      K := Props.Keys;
      try
        for i := 0 to K.Count - 1 do
        begin
          if Result <> '' then Result := Result + ', ';
          Result := Result + K[i];
        end;
      finally
        K.Free;
      end;
    finally
      Props.Free;
    end;
  finally
    S.Free;
  end;
end;

function UnattendedElicitNote(const Req: TMCPElicitRequest): string;
var
  Fields: string;
begin
  if Req.Mode = emURL then
    Result := Format('MCP server "%s" needs the user to open this URL: %s -- %s ' +
      'PasClaw cannot show it to anyone here (no interactive user in this ' +
      'context), so it declined. Give the URL to the user; once they have ' +
      'finished there, call the tool again.',
      [Req.Server, Req.URL, Req.Message])
  else
  begin
    Fields := FieldNames(Req.SchemaJSON);
    if Fields <> '' then Fields := ' (fields: ' + Fields + ')';
    Result := Format('MCP server "%s" asked the user for input%s: %s -- ' +
      'nobody can answer here (no interactive user in this context), so ' +
      'PasClaw declined. Ask the user for this information, or call the tool ' +
      'from an interactive session.',
      [Req.Server, Fields, Req.Message]);
  end;
end;

function RunElicitation(H: TMCPElicitationHandler;
                        const Req: TMCPElicitRequest): TMCPElicitResponse;
begin
  Result.Action := eaDecline;
  Result.ContentJSON := '';
  Result.Note := '';
  if (H = nil) or ((Req.Mode = emForm) and not H.CanForm)
     or ((Req.Mode = emURL) and not H.CanURL) then
  begin
    Result.Note := UnattendedElicitNote(Req);
    Exit;
  end;
  Result := H.Elicit(Req);
end;

function ElicitRequestFromParams(const Server, ParamsJSON: string;
                                 out Req: TMCPElicitRequest;
                                 out Err: string): Boolean;
var
  P: TJsonObject;
  Mode: string;
begin
  Result := False;
  Err := '';
  Req.Server := Server;
  Req.Mode := emForm;
  Req.Message := '';
  Req.URL := '';
  Req.SchemaJSON := '{}';
  P := JsonTryParse(ParamsJSON);
  if P = nil then
  begin
    Err := 'elicitation/create without params';
    Exit;
  end;
  try
    Mode := P.GetStr('mode', 'form');
    Req.Message := P.GetStr('message', '');
    if Mode = 'url' then
    begin
      Req.Mode := emURL;
      Req.URL := P.GetStr('url', '');
      if Req.URL = '' then
      begin
        Err := 'URL-mode elicitation without a url';
        Exit;
      end;
    end
    else if Mode = 'form' then
      Req.SchemaJSON := P.GetRaw('requestedSchema', '{}')
    else
    begin
      Err := 'unknown elicitation mode "' + Mode + '"';
      Exit;
    end;
  finally
    P.Free;
  end;
  Result := True;
end;

{ ------------------------------------------------------- form fields }

function CharCount(const S: string): Integer;
{$IFDEF FPC}
var
  i: Integer;
begin
  { FPC strings here are UTF-8 bytes; count the bytes that start a
    character so minLength / maxLength mean characters, as JSON Schema
    does. }
  Result := 0;
  for i := 1 to Length(S) do
    if (Ord(S[i]) and $C0) <> $80 then Inc(Result);
end;
{$ELSE}
begin
  Result := Length(S);
end;
{$ENDIF}

function JsonNumberText(V: Double): string;
var
  Fmt: TFormatSettings;
begin
  { '.' whatever the locale: this is JSON, not display text }
  Fmt := FormatSettings;
  Fmt.DecimalSeparator := '.';
  Result := FloatToStr(V, Fmt);
end;

function TryParseNumber(const S: string; out V: Double): Boolean;
var
  Fmt: TFormatSettings;
begin
  Fmt := FormatSettings;
  Fmt.DecimalSeparator := '.';
  Fmt.ThousandSeparator := #0;
  Result := TryStrToFloat(Trim(S), V, Fmt);
end;

{ The choices of an enum-like schema: Values[i] is what is sent, Titles[i]
  what is shown. Reads `enum` (+ the 2025-06-18 `enumNames`) and the
  titled `oneOf` / `anyOf` lists of const + title pairs. }
procedure ReadChoices(Schema: TJsonObject; out Values, Titles: TStringList);
var
  Arr, Names: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Key: string;
begin
  Values := TStringList.Create;
  Titles := TStringList.Create;
  Arr := Schema.ChildArray('enum');
  if Arr <> nil then
  try
    Names := Schema.ChildArray('enumNames');
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Values.Add(Arr.ItemStr(i, ''));
        if (Names <> nil) and (i < Names.Count) and (Names.ItemStr(i, '') <> '') then
          Titles.Add(Names.ItemStr(i, ''))
        else
          Titles.Add(Arr.ItemStr(i, ''));
      end;
    finally
      Names.Free;
    end;
    Exit;
  finally
    Arr.Free;
  end;
  if Schema.Has('oneOf') then Key := 'oneOf' else Key := 'anyOf';
  Arr := Schema.ChildArray(Key);
  if Arr = nil then Exit;
  try
    for i := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(i);
      if Item = nil then Continue;
      try
        Values.Add(Item.GetStr('const', ''));
        Titles.Add(Item.GetStr('title', Item.GetStr('const', '')));
      finally
        Item.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

function MatchChoice(Values, Titles: TStringList; const Input: string;
                     out Value: string): Boolean;
var
  i, N: Integer;
  S: string;
begin
  Result := False;
  Value := '';
  S := Trim(Input);
  for i := 0 to Values.Count - 1 do
    if (Values[i] = S) or (Titles[i] = S) then
    begin
      Value := Values[i];
      Exit(True);
    end;
  for i := 0 to Values.Count - 1 do
    if SameText(Values[i], S) or SameText(Titles[i], S) then
    begin
      Value := Values[i];
      Exit(True);
    end;
  if TryStrToInt(S, N) and (N >= 1) and (N <= Values.Count) then
  begin
    Value := Values[N - 1];
    Result := True;
  end;
end;

function ChoiceList(Values, Titles: TStringList): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Values.Count - 1 do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + IntToStr(i + 1) + ') ' + Titles[i];
  end;
end;

function CheckStringFormat(const Fmt, S: string; out Err: string): Boolean;
begin
  Result := True;
  Err := '';
  if Fmt = 'email' then
    Result := (Pos('@', S) > 1) and (Pos('.', Copy(S, Pos('@', S), MaxInt)) > 2)
  else if Fmt = 'uri' then
    Result := Pos(':', S) > 1
  else if Fmt = 'date' then
    Result := (Length(S) = 10) and (S[5] = '-') and (S[8] = '-')
  else if Fmt = 'date-time' then
    Result := (Length(S) >= 19) and (S[5] = '-') and (S[8] = '-') and
              ((S[11] = 'T') or (S[11] = 't') or (S[11] = ' '));
  if not Result then
    Err := 'expected ' + Fmt + ' format';
end;

function ParseFormAnswer(const PropSchemaJSON, Input: string;
                         out ValueJSON, Err: string): Boolean;
var
  Schema, Items: TJsonObject;
  Values, Titles: TStringList;
  Kind, V, Part, Rest: string;
  N: Int64;
  F: Double;
  P, Count: Integer;
  Arr: TJsonArray;
  L: Boolean;
begin
  Result := False;
  ValueJSON := '';
  Err := '';
  Schema := JsonTryParse(PropSchemaJSON);
  if Schema = nil then Schema := TJsonObject.Create;
  try
    Kind := Schema.GetStr('type', 'string');

    if Kind = 'boolean' then
    begin
      V := LowerCase(Trim(Input));
      if (V = 'y') or (V = 'yes') or (V = 'true') or (V = '1') or (V = 'on') then
        ValueJSON := 'true'
      else if (V = 'n') or (V = 'no') or (V = 'false') or (V = '0') or (V = 'off') then
        ValueJSON := 'false'
      else
      begin
        Err := 'answer yes or no';
        Exit;
      end;
      Exit(True);
    end;

    if (Kind = 'integer') or (Kind = 'number') then
    begin
      if Kind = 'integer' then
      begin
        if not TryStrToInt64(Trim(Input), N) then
        begin
          Err := 'expected a whole number';
          Exit;
        end;
        F := N;
        V := IntToStr(N);
      end
      else
      begin
        if not TryParseNumber(Input, F) then
        begin
          Err := 'expected a number';
          Exit;
        end;
        V := JsonNumberText(F);
      end;
      if Schema.Has('minimum') and (F < Schema.GetFloat('minimum', 0)) then
      begin
        Err := 'must be at least ' + JsonNumberText(Schema.GetFloat('minimum', 0));
        Exit;
      end;
      if Schema.Has('maximum') and (F > Schema.GetFloat('maximum', 0)) then
      begin
        Err := 'must be at most ' + JsonNumberText(Schema.GetFloat('maximum', 0));
        Exit;
      end;
      ValueJSON := V;
      Exit(True);
    end;

    if Kind = 'array' then
    begin
      Items := Schema.ChildObject('items');
      if Items = nil then Items := TJsonObject.Create;
      try
        ReadChoices(Items, Values, Titles);
      finally
        Items.Free;
      end;
      Arr := TJsonArray.Create;
      try
        Count := 0;
        Rest := Input;
        while Trim(Rest) <> '' do
        begin
          P := Pos(',', Rest);
          if P > 0 then
          begin
            Part := Trim(Copy(Rest, 1, P - 1));
            Rest := Copy(Rest, P + 1, MaxInt);
          end
          else
          begin
            Part := Trim(Rest);
            Rest := '';
          end;
          if Part = '' then Continue;
          if Values.Count > 0 then
          begin
            if not MatchChoice(Values, Titles, Part, V) then
            begin
              Err := '"' + Part + '" is not one of: ' + ChoiceList(Values, Titles);
              Exit;
            end;
          end
          else
            V := Part;
          Arr.AddStr(V);
          Inc(Count);
        end;
        if Schema.Has('minItems') and (Count < Schema.GetInt('minItems', 0)) then
        begin
          Err := Format('choose at least %d', [Schema.GetInt('minItems', 0)]);
          Exit;
        end;
        if Schema.Has('maxItems') and (Count > Schema.GetInt('maxItems', 0)) then
        begin
          Err := Format('choose at most %d', [Schema.GetInt('maxItems', 0)]);
          Exit;
        end;
        ValueJSON := Arr.ToJSON;
      finally
        Arr.Free;
        Values.Free;
        Titles.Free;
      end;
      Exit(True);
    end;

    { string, single-select enum, or a type we do not know (sent as text) }
    ReadChoices(Schema, Values, Titles);
    try
      if Values.Count > 0 then
      begin
        if not MatchChoice(Values, Titles, Input, V) then
        begin
          Err := 'choose one of: ' + ChoiceList(Values, Titles);
          Exit;
        end;
        ValueJSON := '"' + JsonEscape(V) + '"';
        Exit(True);
      end;
    finally
      Values.Free;
      Titles.Free;
    end;
    V := Input;
    if Schema.Has('minLength') and (CharCount(V) < Schema.GetInt('minLength', 0)) then
    begin
      Err := Format('at least %d characters', [Schema.GetInt('minLength', 0)]);
      Exit;
    end;
    if Schema.Has('maxLength') and (CharCount(V) > Schema.GetInt('maxLength', 0)) then
    begin
      Err := Format('at most %d characters', [Schema.GetInt('maxLength', 0)]);
      Exit;
    end;
    L := CheckStringFormat(Schema.GetStr('format', ''), V, Err);
    if not L then Exit;
    ValueJSON := '"' + JsonEscape(V) + '"';
    Result := True;
  finally
    Schema.Free;
  end;
end;

function DescribeFormField(const Name, PropSchemaJSON: string;
                           Required: Boolean): string;
var
  Schema, Items: TJsonObject;
  Values, Titles: TStringList;
  Kind, Info, Title, Desc: string;
begin
  Schema := JsonTryParse(PropSchemaJSON);
  if Schema = nil then Schema := TJsonObject.Create;
  try
    Kind := Schema.GetStr('type', 'string');
    Title := Schema.GetStr('title', '');
    Desc := Schema.GetStr('description', '');
    Info := '';
    if Kind = 'array' then
    begin
      Items := Schema.ChildObject('items');
      if Items = nil then Items := TJsonObject.Create;
      try
        ReadChoices(Items, Values, Titles);
      finally
        Items.Free;
      end;
      try
        Info := 'any of: ' + ChoiceList(Values, Titles) + '; comma-separated';
      finally
        Values.Free;
        Titles.Free;
      end;
    end
    else
    begin
      ReadChoices(Schema, Values, Titles);
      try
        if Values.Count > 0 then
          Info := 'one of: ' + ChoiceList(Values, Titles)
        else if Kind = 'boolean' then
          Info := 'yes/no'
        else
        begin
          Info := Kind;
          if Schema.Has('format') then Info := Info + ', ' + Schema.GetStr('format', '');
          if Schema.Has('minimum') then
            Info := Info + ', min ' + JsonNumberText(Schema.GetFloat('minimum', 0));
          if Schema.Has('maximum') then
            Info := Info + ', max ' + JsonNumberText(Schema.GetFloat('maximum', 0));
        end;
      finally
        Values.Free;
        Titles.Free;
      end;
    end;
    if Required then Info := Info + ', required' else Info := Info + ', optional';
    Result := Name;
    if (Title <> '') and (Title <> Name) then Result := Result + ' "' + Title + '"';
    Result := Result + ' (' + Info + ')';
    if Desc <> '' then Result := Result + ' - ' + Desc;
    if Schema.Has('default') then
      Result := Result + ' [default ' + Schema.GetRaw('default', '') + ']';
  finally
    Schema.Free;
  end;
end;

{ ---------------------------------------------------- console dialogue }

function TMCPConsoleElicitationHandler.ReadAnswer(out Line: string): Boolean;
begin
  Line := '';
  if EOF(Input) then Exit(False);
  ReadLn(Input, Line);
  Result := True;
end;

procedure TMCPConsoleElicitationHandler.Show(const S: string; NewLine: Boolean);
begin
  if NewLine then PrintLn(S) else Print(S);
end;

function TMCPConsoleElicitationHandler.Elicit(const Req: TMCPElicitRequest): TMCPElicitResponse;
begin
  BeginInteractiveAsk;
  try
    if Req.Mode = emURL then Result := AskURL(Req)
    else Result := AskForm(Req);
  finally
    EndInteractiveAsk;
  end;
end;

function TMCPConsoleElicitationHandler.AskURL(const Req: TMCPElicitRequest): TMCPElicitResponse;
var
  Host, Line: string;
begin
  Result.Action := eaCancel;
  Result.ContentJSON := '';
  Result.Note := '';
  Host := URLHost(Req.URL);
  Show('');
  Show(Ansi.Bold + 'MCP server "' + Req.Server + '" asks you to open a link' + Ansi.Reset);
  if Req.Message <> '' then Show('  ' + Req.Message);
  Show('  URL:  ' + Req.URL);
  Show('  host: ' + Ansi.Bold + Host + Ansi.Reset);
  { Punycode can make a look-alike host read as a familiar one. }
  if Pos('xn--', Host) > 0 then
    Show(Ansi.Yellow + '  warning: the host is punycode-encoded; check it is the site you expect' + Ansi.Reset);
  Show(Ansi.Dim + '  PasClaw does not open or fetch this link. Open it yourself, finish there, then answer.' + Ansi.Reset);
  Show('  [d]one / [n]o, decline / [c]ancel > ', False);
  if not ReadAnswer(Line) then Exit;
  Line := LowerCase(Trim(Line));
  if (Line = 'd') or (Line = 'done') or (Line = 'y') or (Line = 'yes') then
    Result.Action := eaAccept
  else if (Line = 'n') or (Line = 'no') or (Line = 'decline') then
    Result.Action := eaDecline;
end;

function TMCPConsoleElicitationHandler.AskForm(const Req: TMCPElicitRequest): TMCPElicitResponse;
const
  MaxTries = 5;
  MaxEdits = 3;
var
  Schema, Props, Prop: TJsonObject;
  ReqArr: TJsonArray;
  Keys, Required: TStringList;
  Content: TJsonObject;
  i, Tries, Edits: Integer;
  PropJSON, Line, ValueJSON, Err: string;
  IsRequired, Done: Boolean;
begin
  Result.Action := eaCancel;
  Result.ContentJSON := '';
  Result.Note := '';
  Show('');
  Show(Ansi.Bold + 'MCP server "' + Req.Server + '" asks for input' + Ansi.Reset);
  if Req.Message <> '' then Show('  ' + Req.Message);

  Schema := JsonTryParse(Req.SchemaJSON);
  if Schema = nil then Schema := TJsonObject.Create;
  Required := TStringList.Create;
  Keys := nil;
  Props := nil;
  Content := nil;
  try
    ReqArr := Schema.ChildArray('required');
    if ReqArr <> nil then
    try
      for i := 0 to ReqArr.Count - 1 do Required.Add(ReqArr.ItemStr(i, ''));
    finally
      ReqArr.Free;
    end;
    Props := Schema.ChildObject('properties');
    if Props <> nil then Keys := Props.Keys else Keys := TStringList.Create;
    if Keys.Count > 0 then
      Show(Ansi.Dim + '  Enter keeps the default or skips an optional field; ' +
           '/decline or /cancel stops.' + Ansi.Reset);

    Edits := 0;
    repeat
      FreeAndNil(Content);
      Content := TJsonObject.Create;
      for i := 0 to Keys.Count - 1 do
      begin
        Prop := Props.ChildObject(Keys[i]);
        if Prop = nil then Continue;
        try
          PropJSON := Prop.ToJSON;
        finally
          Prop.Free;
        end;
        IsRequired := Required.IndexOf(Keys[i]) >= 0;
        Tries := 0;
        Done := False;
        while not Done do
        begin
          Show('  ' + DescribeFormField(Keys[i], PropJSON, IsRequired) + ': ', False);
          if not ReadAnswer(Line) then Exit;       { stdin closed: cancel }
          Line := Trim(Line);
          if Line = '/cancel' then Exit;
          if Line = '/decline' then
          begin
            Result.Action := eaDecline;
            Exit;
          end;
          if Line = '' then
          begin
            Prop := JsonTryParse(PropJSON);
            try
              if (Prop <> nil) and Prop.Has('default') then
              begin
                Content.PutRaw(Keys[i], Prop.GetRaw('default', 'null'));
                Done := True;
              end
              else if not IsRequired then
                Done := True
              else
                Show(Ansi.Yellow + '    this field is required' + Ansi.Reset);
            finally
              Prop.Free;
            end;
          end
          else if ParseFormAnswer(PropJSON, Line, ValueJSON, Err) then
          begin
            Content.PutRaw(Keys[i], ValueJSON);
            Done := True;
          end
          else
            Show(Ansi.Yellow + '    ' + Err + Ansi.Reset);
          if not Done then
          begin
            Inc(Tries);
            if Tries >= MaxTries then Exit;     { cancel rather than loop forever }
          end;
        end;
      end;

      { Review before anything is sent. }
      Show('  ' + Ansi.Dim + 'to send: ' + Ansi.Reset + Content.ToJSON);
      Show('  send this to "' + Req.Server + '"? [y]es / [e]dit / [n]o, decline / [c]ancel > ', False);
      if not ReadAnswer(Line) then Exit;
      Line := LowerCase(Trim(Line));
      if (Line = 'y') or (Line = 'yes') then
      begin
        Result.Action := eaAccept;
        Result.ContentJSON := Content.ToJSON;
        Exit;
      end;
      if (Line = 'n') or (Line = 'no') or (Line = 'decline') then
      begin
        Result.Action := eaDecline;
        Exit;
      end;
      if not ((Line = 'e') or (Line = 'edit')) then Exit;   { cancel }
      Inc(Edits);
    until Edits > MaxEdits;
  finally
    Content.Free;
    Keys.Free;
    Props.Free;
    Required.Free;
    Schema.Free;
  end;
end;

initialization
  GConsole := TMCPConsoleElicitationHandler.Create;

finalization
  FreeAndNil(GConsole);

end.
