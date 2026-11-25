(*
  PasClaw.MCP.Client - the MCP client protocol, shared by the stdio and the
  Streamable HTTP transports. A transport supplies Exchange (send one
  request, return the response envelope) and Notify; everything else lives
  here, once:

  Version negotiation (2026-07-28 "Versioning and Compatibility").
    1. Probe with `server/discover`, declaring 2026-07-28 in _meta.
       - a DiscoverResult listing 2026-07-28: the server is modern. No
         `initialize`, no session; every later request carries
         _meta.io.modelcontextprotocol/{protocolVersion, clientInfo,
         clientCapabilities}.
       - UnsupportedProtocolVersionError (-32022): modern, but not our
         version. Fall back to `initialize`, offering the newest legacy
         revision the server listed that we speak.
       - any other error, an HTTP 4xx without a modern error body, or no
         answer within the probe timeout: a legacy server. Fall back to
         `initialize`, offering MCPProtocolLegacy (2025-11-25), and accept
         whatever version it answers.
    2. If the probe timed out and `initialize` then fails, the server may be
       a modern one that was still starting: probe once more.
    The result is recorded in ServerInfo (ProtocolVersion, Modern,
    Negotiation) for `pasclaw mcp test`, the gateway's /v1/mcp and the web
    UI.

  Results. A modern result's `resultType` says what it is; one without the
  field (every legacy server) is "complete".

  Multi round-trip requests (MRTR). tools/call may answer `input_required`
  with inputRequests (elicitation/create; sampling and roots are deprecated
  and never offered) and an opaque requestState. The client answers each
  request through the elicitation handler of the calling thread
  (PasClaw.MCP.Elicit) and retries the call -- new JSON-RPC id, same
  params, plus inputResponses and the requestState echoed verbatim. At most
  MCPMaxInputRounds rounds. A request nobody can answer (no interactive user
  on this thread) is not retried: the model gets a note saying what was
  asked, with the URL for URL mode.

  Tasks extension (io.modelcontextprotocol/tasks). Declared on every modern
  request. A tools/call answered with resultType "task" is polled with
  tasks/get at the server's pollIntervalMs until completed, failed or
  cancelled, within the call's timeout (and the task's ttlMs); input the
  task asks for goes through the same handler and back with tasks/update.
  A call that runs out of time cancels the task with tasks/cancel.

  Legacy elicitation. A handshake-era server asks with its own
  `elicitation/create` request while tools/call is in flight; a transport
  that can answer server requests (stdio) hands it to AnswerServerRequest.
  2025-11-25's URLElicitationRequiredError (-32042) on tools/call is
  handled too: show the URLs, retry once after the user is done.
*)
unit PasClaw.MCP.Client;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.MCP.Types;

type
  { One response as a transport received it. }
  TMCPWireReply = record
    Body:       string;    { the JSON-RPC response envelope; '' when none arrived }
    HttpStatus: Integer;   { 0 on stdio }
    Err:        string;    { why there is no envelope }
    TimedOut:   Boolean;
  end;

  TMCPProtocolClient = class(TMCPBaseClient)
  private
    FIdLock: TCriticalSection;
    FNextId: Integer;
    function Probe(TimeoutMs: Integer; out Offer, Why: string;
                   out TimedOut: Boolean): Integer;
    function Initialize(const Offer, Why: string; TimeoutMs: Integer;
                        out ErrMsg: string): Boolean;
    procedure ApplyDiscover(const ResultJSON: string);
    function AnswerInputRequests(const RequestsJSON: string;
                                 ForTask: Boolean;
                                 Answered: TStringList;
                                 out ResponsesJSON, Note: string): Boolean;
    function FollowTask(const CreateJSON: string; DeadlineMs: Int64;
                        out ResultText, ResultJSON, ErrMsg: string): Boolean;
    function HandleURLRequired(const ErrJSON: string; out Note: string): Boolean;
  protected
    FName:          string;
    FModern:        Boolean;
    FCallTimeoutMs: Integer;
    FListTimeoutMs: Integer;
    { Elicitation capability the legacy initialize declared ('' = none). }
    FLegacyElicitCap: string;
    function NextRequestId: Integer;
    { Get the transport ready (spawn the process). Default: nothing to do. }
    function OpenTransport(TimeoutMs: Integer; out ErrMsg: string): Boolean; virtual;
    { Forget per-connection transport state before `initialize` (the HTTP
      session id). }
    procedure ResetTransportSession; virtual;
    { False when the transport died (a stdio server that exited). }
    function TransportAlive: Boolean; virtual;
    { Send one request and wait for its response. Modern says which era the
      request belongs to -- the probe is modern before FModern is set. }
    function Exchange(const Method, ParamsJSON: string; Id, TimeoutMs: Integer;
                      Modern: Boolean): TMCPWireReply; virtual; abstract;
    procedure Notify(const Method, ParamsJSON: string); virtual; abstract;
    { True when the transport can answer a request the server sends while a
      call is in flight -- legacy elicitation/create. stdio yes; HTTP no:
      its response is read whole, so the server would wait on us forever. }
    function CanAnswerServerRequests: Boolean; virtual;
    { A tools/list entry: False leaves it out (HTTP drops a tool whose
      x-mcp-header annotations break the rules). }
    function AcceptListedTool(const Tool: TMCPTool): Boolean; virtual;
    { HeaderMismatch (-32020) on tools/call: refresh what the request
      headers are built from; True to retry once. }
    function RecoverHeaderMismatch: Boolean; virtual;
    { The JSON-RPC response line to a request the server sent us (legacy
      server->client requests; '' = send nothing). }
    function AnswerServerRequest(const RequestJSON: string): string;
    { Params with the modern per-request _meta added (unchanged when not
      Modern). }
    function WithMeta(const ParamsJSON: string; Modern: Boolean): string;
    { One request/response. ErrJSON is the error object when the server
      answered with one. }
    function Call(const Method, ParamsJSON: string; TimeoutMs: Integer;
                  out ResultJSON, ErrMsg, ErrJSON: string;
                  out ErrCode: Integer): Boolean;
  public
    constructor Create(const Name: string);
    destructor Destroy; override;
    function Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean; override;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; override;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; override;
    function CallToolStructured(const ToolName, ArgsJSON: string;
                      out ResultText, ResultJSON, ErrMsg: string): Boolean; override;
    property Name: string read FName;
    { Budget of one tool call, task polling included. }
    property CallTimeoutMs: Integer read FCallTimeoutMs write FCallTimeoutMs;
  end;

{ Legacy revisions we speak, newest first. }
function MCPKnownLegacyVersions: TArray<string>;

{ The first entry of MCPKnownLegacyVersions present in the JSON array
  SupportedJSON ('' when none is). }
function PickLegacyVersion(const SupportedJSON: string): string;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Config,          { FormatVersion -- clientInfo.version }
  PasClaw.MCP.Result,
  PasClaw.MCP.Elicit;

const
  { The probe is a question, not the work: a legacy server that ignores
    unknown requests should not hold the connect for its whole budget. }
  ProbeTimeoutCapMs = 5000;
  { tasks/get cadence when the server names none, and the bounds on what it
    names. }
  DefaultPollMs = 1000;
  MinPollMs     = 10;
  MaxPollMs     = 30000;
  MaxTaskInputRounds = MCPMaxInputRounds;

  ErrHeaderMismatch    = -32020;
  ErrMissingCapability = -32021;
  ErrUnsupportedVersion = -32022;
  ErrURLElicitationRequired = -32042;   { 2025-11-25 only }

  { Probe outcomes. }
  poModern = 0;
  poLegacy = 1;
  poFail   = 2;

threadvar
  { Notes from legacy elicitation/create requests this thread declined
    because nobody could answer: appended to the tool result so the model
    knows what the server asked for. }
  GLegacyNotes: string;

function NowMs: Int64;
begin
  { Wall clock in ms -- DateUtils is the FPC+Delphi-portable route;
    GetTickCount64 is FPC-only. Only ever compared with itself. }
  Result := MilliSecondsBetween(Now, EncodeDate(2000, 1, 1));
end;

function MCPKnownLegacyVersions: TArray<string>;
begin
  SetLength(Result, 4);
  Result[0] := '2025-11-25';
  Result[1] := '2025-06-18';
  Result[2] := '2025-03-26';
  Result[3] := '2024-11-05';
end;

function ArrayContains(Arr: TJsonArray; const S: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if Arr = nil then Exit;
  for i := 0 to Arr.Count - 1 do
    if Arr.ItemStr(i, '') = S then Exit(True);
end;

function PickLegacyVersion(const SupportedJSON: string): string;
var
  Arr: TJsonArray;
  Known: TArray<string>;
  i: Integer;
begin
  Result := '';
  Arr := JsonTryParseArray(SupportedJSON);
  if Arr = nil then Exit;
  try
    Known := MCPKnownLegacyVersions;
    for i := 0 to High(Known) do
      if ArrayContains(Arr, Known[i]) then Exit(Known[i]);
  finally
    Arr.Free;
  end;
end;

function ClientInfoJSON: string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('name', 'pasclaw');
    O.PutStr('version', FormatVersion);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

{ What this thread's calls can do, declared on every modern request: the
  tasks extension always; elicitation only when the thread has someone to
  answer it. }
function ModernClientCapabilitiesJSON: string;
var
  O, Ext, Empty: TJsonObject;
  Cap: string;
begin
  O := TJsonObject.Create;
  try
    Cap := ElicitCapabilityJSON(ThreadMCPElicitationHandler);
    if Cap <> '' then O.PutRaw('elicitation', Cap);
    Ext := TJsonObject.Create;
    Empty := TJsonObject.Create;
    Ext.PutObject(MCPTasksExtension, Empty);
    O.PutObject('extensions', Ext);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

{ ------------------------------------------------------------------ }

constructor TMCPProtocolClient.Create(const Name: string);
begin
  inherited Create;
  FName := Name;
  FIdLock := TCriticalSection.Create;
  FNextId := 1;
  FModern := False;
  FCallTimeoutMs := 30000;
  FListTimeoutMs := 10000;
  FLegacyElicitCap := '';
end;

destructor TMCPProtocolClient.Destroy;
begin
  FIdLock.Free;
  inherited Destroy;
end;

function TMCPProtocolClient.NextRequestId: Integer;
begin
  FIdLock.Acquire;
  try
    Result := FNextId;
    Inc(FNextId);
  finally
    FIdLock.Release;
  end;
end;

function TMCPProtocolClient.OpenTransport(TimeoutMs: Integer; out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  Result := TimeoutMs >= 0;
end;

procedure TMCPProtocolClient.ResetTransportSession;
begin
end;

function TMCPProtocolClient.TransportAlive: Boolean;
begin
  Result := True;
end;

function TMCPProtocolClient.CanAnswerServerRequests: Boolean;
begin
  Result := False;
end;

function TMCPProtocolClient.AcceptListedTool(const Tool: TMCPTool): Boolean;
begin
  Result := Tool.Name <> '';
end;

function TMCPProtocolClient.RecoverHeaderMismatch: Boolean;
begin
  Result := False;
end;

function TMCPProtocolClient.WithMeta(const ParamsJSON: string; Modern: Boolean): string;
var
  P, Meta: TJsonObject;
begin
  if not Modern then Exit(ParamsJSON);
  P := nil;
  if Trim(ParamsJSON) <> '' then P := JsonTryParse(ParamsJSON);
  if P = nil then P := TJsonObject.Create;
  try
    Meta := JsonTryParse(P.GetRaw('_meta', '{}'));
    if Meta = nil then Meta := TJsonObject.Create;
    Meta.PutStr('io.modelcontextprotocol/protocolVersion', MCPProtocolModern);
    Meta.PutRaw('io.modelcontextprotocol/clientInfo', ClientInfoJSON);
    Meta.PutRaw('io.modelcontextprotocol/clientCapabilities', ModernClientCapabilitiesJSON);
    P.PutObject('_meta', Meta);
    Result := P.ToJSON;
  finally
    P.Free;
  end;
end;

function TMCPProtocolClient.Call(const Method, ParamsJSON: string; TimeoutMs: Integer;
  out ResultJSON, ErrMsg, ErrJSON: string; out ErrCode: Integer): Boolean;
var
  Reply: TMCPWireReply;
  Env, E, R: TJsonObject;
begin
  Result := False;
  ResultJSON := '';
  ErrMsg := '';
  ErrJSON := '';
  ErrCode := 0;
  Reply := Exchange(Method, ParamsJSON, NextRequestId, TimeoutMs, FModern);
  if Reply.Body = '' then
  begin
    if Reply.TimedOut then
      ErrMsg := Format('no response to %s within %ds', [Method, (TimeoutMs + 999) div 1000])
    else if Reply.Err <> '' then
      ErrMsg := Method + ': ' + Reply.Err
    else
      ErrMsg := 'no response to ' + Method;
    Exit;
  end;
  Env := JsonTryParse(Reply.Body);
  if Env = nil then
  begin
    ErrMsg := 'unparseable response to ' + Method;
    Exit;
  end;
  try
    E := Env.ChildObject('error');
    if E <> nil then
    try
      ErrCode := E.GetInt('code', 0);
      ErrJSON := E.ToJSON;
      ErrMsg := Format('%s: %s (code %d)', [Method, E.GetStr('message', 'error'), ErrCode]);
      Exit;
    finally
      E.Free;
    end;
    R := Env.ChildObject('result');
    if R = nil then
    begin
      ErrMsg := Method + ': response has no result';
      Exit;
    end;
    try
      ResultJSON := R.ToJSON;
    finally
      R.Free;
    end;
  finally
    Env.Free;
  end;
  Result := True;
end;

{ ------------------------------------------------------ negotiation }

procedure TMCPProtocolClient.ApplyDiscover(const ResultJSON: string);
var
  R, Meta, Info, Caps, Ext: TJsonObject;
begin
  FModern := True;
  FInfo.Modern := True;
  FInfo.ProtocolVersion := MCPProtocolModern;
  FInfo.Negotiation := 'server/discover';
  R := JsonTryParse(ResultJSON);
  if R = nil then Exit;
  try
    Meta := R.ChildObject('_meta');
    if Meta <> nil then
    try
      Info := Meta.ChildObject('io.modelcontextprotocol/serverInfo');
      if Info <> nil then
      try
        FInfo.Name    := Info.GetStr('name', '');
        FInfo.Version := Info.GetStr('version', '');
      finally
        Info.Free;
      end;
    finally
      Meta.Free;
    end;
    Caps := R.ChildObject('capabilities');
    if Caps <> nil then
    try
      FInfo.Caps.Tools     := Caps.Has('tools');
      FInfo.Caps.Resources := Caps.Has('resources');
      FInfo.Caps.Prompts   := Caps.Has('prompts');
      Ext := Caps.ChildObject('extensions');
      if Ext <> nil then
      try
        FInfo.Caps.Tasks := Ext.Has(MCPTasksExtension);
      finally
        Ext.Free;
      end;
    finally
      Caps.Free;
    end;
  finally
    R.Free;
  end;
end;

function TMCPProtocolClient.Probe(TimeoutMs: Integer; out Offer, Why: string;
                                  out TimedOut: Boolean): Integer;
var
  Reply: TMCPWireReply;
  Env, R, E, Data: TJsonObject;
  Vers: TJsonArray;
  List, L: string;
  Code: Integer;
begin
  Offer := MCPProtocolLegacy;
  Why := '';
  Reply := Exchange('server/discover', WithMeta('{}', True), NextRequestId,
                    TimeoutMs, True);
  TimedOut := Reply.TimedOut;
  if Reply.Body = '' then
  begin
    if Reply.TimedOut then
      Why := Format('no answer to server/discover within %dms', [TimeoutMs])
    else
      Why := 'server/discover failed: ' + Reply.Err;
    Exit(poLegacy);
  end;
  Env := JsonTryParse(Reply.Body);
  if Env = nil then
  begin
    Why := 'server/discover answer is not JSON';
    Exit(poLegacy);
  end;
  try
    R := Env.ChildObject('result');
    if R <> nil then
    try
      Vers := R.ChildArray('supportedVersions');
      if Vers = nil then
      begin
        Why := 'server/discover answered without supportedVersions';
        Exit(poLegacy);
      end;
      try
        List := Vers.ToJSON;
        if ArrayContains(Vers, MCPProtocolModern) then
        begin
          ApplyDiscover(R.ToJSON);
          Exit(poModern);
        end;
      finally
        Vers.Free;
      end;
      L := PickLegacyVersion(List);
      if L <> '' then
      begin
        Offer := L;
        Why := 'server supports ' + List;
        Exit(poLegacy);
      end;
      Why := 'no protocol version in common: the server supports ' + List;
      Exit(poFail);
    finally
      R.Free;
    end;

    E := Env.ChildObject('error');
    if E = nil then
    begin
      Why := 'server/discover answer has neither result nor error';
      Exit(poLegacy);
    end;
    try
      Code := E.GetInt('code', 0);
      if Code = ErrUnsupportedVersion then
      begin
        List := '[]';
        Data := E.ChildObject('data');
        if Data <> nil then
        try
          List := Data.GetRaw('supported', '[]');
        finally
          Data.Free;
        end;
        L := PickLegacyVersion(List);
        if L = '' then
        begin
          Why := 'no protocol version in common: the server supports ' + List;
          Exit(poFail);
        end;
        Offer := L;
        Why := 'UnsupportedProtocolVersionError, server supports ' + List;
        Exit(poLegacy);
      end;
      if (Code = ErrHeaderMismatch) or (Code = ErrMissingCapability) then
      begin
        Why := Format('server/discover refused: %s (code %d)', [E.GetStr('message', ''), Code]);
        Exit(poFail);
      end;
      Why := Format('server/discover: %s (code %d)', [E.GetStr('message', ''), Code]);
      if Reply.HttpStatus <> 0 then Why := Why + Format(', HTTP %d', [Reply.HttpStatus]);
      Result := poLegacy;
    finally
      E.Free;
    end;
  finally
    Env.Free;
  end;
end;

function TMCPProtocolClient.Initialize(const Offer, Why: string; TimeoutMs: Integer;
                                       out ErrMsg: string): Boolean;
var
  Params, Caps, R, Info, C: TJsonObject;
  ResJSON, ErrJSON, Cap: string;
  Code: Integer;
begin
  Result := False;
  ErrMsg := '';
  FModern := False;
  FLegacyElicitCap := '';
  { Handshake capabilities are per connection, settled on a loader thread
    before any tool loop runs, so they follow the process handler -- and
    only where the transport can answer the server's elicitation/create. }
  if CanAnswerServerRequests then
    FLegacyElicitCap := ElicitCapabilityJSON(MCPProcessElicitationHandler);
  Params := TJsonObject.Create;
  try
    Params.PutStr('protocolVersion', Offer);
    Caps := TJsonObject.Create;
    if FLegacyElicitCap <> '' then Caps.PutRaw('elicitation', FLegacyElicitCap);
    Params.PutObject('capabilities', Caps);
    Params.PutRaw('clientInfo', ClientInfoJSON);
    ResetTransportSession;
    if not Call('initialize', Params.ToJSON, TimeoutMs, ResJSON, ErrMsg, ErrJSON, Code) then
      Exit;
  finally
    Params.Free;
  end;
  R := JsonTryParse(ResJSON);
  if R = nil then
  begin
    ErrMsg := 'bad initialize response';
    Exit;
  end;
  try
    FInfo.ProtocolVersion := R.GetStr('protocolVersion', '');
    if FInfo.ProtocolVersion = '' then FInfo.ProtocolVersion := Offer;
    FInfo.Modern := False;
    Info := R.ChildObject('serverInfo');
    if Info <> nil then
    try
      FInfo.Name    := Info.GetStr('name', '');
      FInfo.Version := Info.GetStr('version', '');
    finally
      Info.Free;
    end;
    C := R.ChildObject('capabilities');
    if C <> nil then
    try
      FInfo.Caps.Tools     := C.Has('tools');
      FInfo.Caps.Resources := C.Has('resources');
      FInfo.Caps.Prompts   := C.Has('prompts');
    finally
      C.Free;
    end;
  finally
    R.Free;
  end;
  Cap := '';
  if Why <> '' then Cap := ' (probe: ' + Why + ')';
  FInfo.Negotiation := 'initialize' + Cap;
  { No id, no response expected. }
  Notify('notifications/initialized', '');
  Result := True;
end;

function TMCPProtocolClient.Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean;
var
  Offer, Why, Why2, Offer2: string;
  ProbeMs: Integer;
  TimedOut, TimedOut2: Boolean;
  Outcome: Integer;
begin
  Result := False;
  ErrMsg := '';
  FInfo := Default(TMCPServerInfo);
  FModern := False;
  if not OpenTransport(TimeoutMs, ErrMsg) then Exit;
  ProbeMs := TimeoutMs;
  if ProbeMs > ProbeTimeoutCapMs then ProbeMs := ProbeTimeoutCapMs;
  if ProbeMs < 500 then ProbeMs := 500;

  Outcome := Probe(ProbeMs, Offer, Why, TimedOut);
  if Outcome = poModern then
  begin
    LogDebug('mcp[%s] negotiated %s via server/discover', [FName, MCPProtocolModern]);
    Exit(True);
  end;
  if Outcome = poFail then
  begin
    ErrMsg := Why;
    Exit;
  end;
  LogDebug('mcp[%s] falling back to initialize (%s)', [FName, Why]);
  { Some strict legacy servers exit on a request that comes before
    initialize. Start the server again and go straight to the handshake. }
  if not TransportAlive then
  begin
    if not OpenTransport(TimeoutMs, ErrMsg) then Exit;
    Why := Why + '; the server exited on the probe and was restarted';
  end;
  if Initialize(Offer, Why, TimeoutMs, ErrMsg) then
  begin
    LogDebug('mcp[%s] negotiated %s via initialize', [FName, FInfo.ProtocolVersion]);
    Exit(True);
  end;
  { A modern-only server that was still starting when the probe gave up
    rejects initialize; it is answering now, so ask it once more. }
  if TimedOut then
  begin
    Outcome := Probe(ProbeMs, Offer2, Why2, TimedOut2);
    if Outcome = poModern then
    begin
      ErrMsg := '';
      Exit(True);
    end;
  end;
  ErrMsg := ErrMsg + ' (version probe: ' + Why + ')';
end;

{ ------------------------------------------------------------ tools }

function TMCPProtocolClient.ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
const
  MaxPages = 100;
var
  Params, R, ToolObj, Schema: TJsonObject;
  Arr: TJsonArray;
  ResJSON, ErrJSON, Cursor: string;
  Code, i, Pages, N: Integer;
  T: TMCPTool;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Tools, 0);
  Cursor := '';
  Pages := 0;
  repeat
    Params := TJsonObject.Create;
    try
      if Cursor <> '' then Params.PutStr('cursor', Cursor);
      if not Call('tools/list', WithMeta(Params.ToJSON, FModern), FListTimeoutMs,
                  ResJSON, ErrMsg, ErrJSON, Code) then
        Exit;
    finally
      Params.Free;
    end;
    R := JsonTryParse(ResJSON);
    if R = nil then Exit(True);
    try
      Arr := R.ChildArray('tools');
      if Arr <> nil then
      try
        for i := 0 to Arr.Count - 1 do
        begin
          ToolObj := Arr.ItemObject(i);
          if ToolObj = nil then Continue;
          try
            T.Name        := ToolObj.GetStr('name', '');
            T.Description := ToolObj.GetStr('description', '');
            Schema := ToolObj.ChildObject('inputSchema');
            if Schema <> nil then
            try
              T.Schema := Schema.ToJSON;
            finally
              Schema.Free;
            end
            else
              T.Schema := '{"type":"object"}';
            T.Server := FName;
          finally
            ToolObj.Free;
          end;
          if not AcceptListedTool(T) then Continue;
          N := Length(Tools);
          SetLength(Tools, N + 1);
          Tools[N] := T;
        end;
      finally
        Arr.Free;
      end;
      Cursor := R.GetStr('nextCursor', '');
    finally
      R.Free;
    end;
    Inc(Pages);
  until (Cursor = '') or (Pages >= MaxPages);
  Result := True;
end;

function TMCPProtocolClient.CallTool(const ToolName, ArgsJSON: string;
                                     out ResultText, ErrMsg: string): Boolean;
var
  Dummy: string;
begin
  Result := CallToolStructured(ToolName, ArgsJSON, ResultText, Dummy, ErrMsg);
end;

function ResultTypeOf(const ResultJSON: string): string;
var
  R: TJsonObject;
begin
  Result := '';
  R := JsonTryParse(ResultJSON);
  if R = nil then Exit;
  try
    Result := R.GetStr('resultType', '');
  finally
    R.Free;
  end;
end;

function AppendNote(const Text, Note: string): string;
begin
  if Note = '' then Exit(Text);
  if Text = '' then Exit('[pasclaw] ' + Note);
  Result := Text + sLineBreak + sLineBreak + '[pasclaw] ' + Note;
end;

function TakeLegacyNotes: string;
begin
  Result := GLegacyNotes;
  GLegacyNotes := '';
end;

function MissingCapabilityMessage(const Server, Tool, ErrJSON: string): string;
var
  E, Data: TJsonObject;
  Need: string;
begin
  Need := '';
  E := JsonTryParse(ErrJSON);
  if E <> nil then
  try
    Data := E.ChildObject('data');
    if Data <> nil then
    try
      Need := Data.GetRaw('requiredCapabilities', '');
    finally
      Data.Free;
    end;
  finally
    E.Free;
  end;
  if Pos('elicitation', Need) > 0 then
    Result := Format('MCP server "%s" needs to ask the user for input to run %s, ' +
      'and nobody can answer in this context (gateway, one-shot run, subagent). ' +
      'Run it from an interactive session (pasclaw agent or pasclaw tui).',
      [Server, Tool])
  else
    Result := Format('MCP server "%s" requires client capabilities PasClaw did ' +
      'not declare for %s: %s', [Server, Tool, Need]);
end;

function TMCPProtocolClient.AnswerInputRequests(const RequestsJSON: string;
  ForTask: Boolean; Answered: TStringList; out ResponsesJSON, Note: string): Boolean;
var
  Reqs, One, Responses: TJsonObject;
  Keys: TStringList;
  i: Integer;
  Method, Err: string;
  Req: TMCPElicitRequest;
  Resp: TMCPElicitResponse;
begin
  Result := False;
  ResponsesJSON := '';
  Note := '';
  Reqs := JsonTryParse(RequestsJSON);
  if Reqs = nil then Reqs := TJsonObject.Create;
  Responses := TJsonObject.Create;
  Keys := Reqs.Keys;
  try
    for i := 0 to Keys.Count - 1 do
    begin
      { A task repeats outstanding requests on every poll; answer each key
        once. }
      if (Answered <> nil) and (Answered.IndexOf(Keys[i]) >= 0) then Continue;
      One := Reqs.ChildObject(Keys[i]);
      if One = nil then Continue;
      try
        Method := One.GetStr('method', '');
        if Method <> 'elicitation/create' then
        begin
          Note := Format('MCP server "%s" asked for %s, which PasClaw does not ' +
            'offer (sampling and roots are deprecated in MCP 2026-07-28).',
            [FName, Method]);
          Exit;
        end;
        if not ElicitRequestFromParams(FName, One.GetRaw('params', '{}'), Req, Err) then
        begin
          Note := Format('MCP server "%s" sent an elicitation PasClaw cannot use: %s',
                         [FName, Err]);
          Exit;
        end;
      finally
        One.Free;
      end;
      Resp := RunElicitation(ThreadMCPElicitationHandler, Req);
      if Resp.Note <> '' then
      begin
        if Note <> '' then Note := Note + ' ';
        Note := Note + Resp.Note;
        { Nobody to ask. A plain call is not retried -- the model gets the
          note. A task is told "decline" so it is not left waiting. }
        if not ForTask then Exit;
      end;
      Responses.PutRaw(Keys[i], ElicitResponseToJSON(Resp));
      if Answered <> nil then Answered.Add(Keys[i]);
    end;
    ResponsesJSON := Responses.ToJSON;
    Result := True;
  finally
    Keys.Free;
    Responses.Free;
    Reqs.Free;
  end;
end;

function TMCPProtocolClient.HandleURLRequired(const ErrJSON: string; out Note: string): Boolean;
{ 2025-11-25 URLElicitationRequiredError: data.elicitations lists URL-mode
  requests that must be completed before the call can succeed. }
var
  E, Data, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  Req: TMCPElicitRequest;
  Resp: TMCPElicitResponse;
  Err: string;
begin
  Result := False;
  Note := '';
  E := JsonTryParse(ErrJSON);
  if E = nil then Exit;
  try
    Data := E.ChildObject('data');
    if Data = nil then Exit;
    try
      Arr := Data.ChildArray('elicitations');
      if Arr = nil then Exit;
      try
        if Arr.Count = 0 then Exit;
        for i := 0 to Arr.Count - 1 do
        begin
          Item := Arr.ItemObject(i);
          if Item = nil then Continue;
          try
            if not ElicitRequestFromParams(FName, Item.ToJSON, Req, Err) then
            begin
              Note := Err;
              Exit;
            end;
          finally
            Item.Free;
          end;
          Resp := RunElicitation(ThreadMCPElicitationHandler, Req);
          if Resp.Note <> '' then
          begin
            Note := Resp.Note;
            Exit;
          end;
          if Resp.Action <> eaAccept then
          begin
            Note := Format('the user did not complete the step MCP server "%s" ' +
                           'asked for at %s (%s).', [FName, Req.URL, ElicitActionName(Resp.Action)]);
            Exit;
          end;
        end;
      finally
        Arr.Free;
      end;
    finally
      Data.Free;
    end;
  finally
    E.Free;
  end;
  Result := True;
end;

function TMCPProtocolClient.CallToolStructured(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  Params, R: TJsonObject;
  Deadline: Int64;
  Remaining, Code, Rounds: Integer;
  ResJSON, ErrJSON, RT, Responses, State, Note, Notes, Text, ReqsJSON: string;
  HasState, URLRetried, HeaderRetried, OK: Boolean;
  AskStart: Int64;
begin
  Result := False;
  ResultText := '';
  ResultJSON := '';
  ErrMsg := '';
  Deadline := NowMs + FCallTimeoutMs;
  Responses := '';
  State := '';
  HasState := False;
  Rounds := 0;
  Notes := '';
  URLRetried := False;
  HeaderRetried := False;
  TakeLegacyNotes;
  while True do
  begin
    if Deadline - NowMs < 1000 then Remaining := 1000
    else Remaining := Integer(Deadline - NowMs);
    Params := TJsonObject.Create;
    try
      Params.PutStr('name', ToolName);
      if Trim(ArgsJSON) <> '' then Params.PutRaw('arguments', ArgsJSON)
      else Params.PutRaw('arguments', '{}');
      { A retry is the original request plus the answers and the server's
        state, echoed exactly; never a state the server did not send. }
      if Responses <> '' then Params.PutRaw('inputResponses', Responses);
      if HasState then Params.PutStr('requestState', State);
      Result := Call('tools/call', WithMeta(Params.ToJSON, FModern), Remaining,
                     ResJSON, ErrMsg, ErrJSON, Code);
    finally
      Params.Free;
    end;
    Notes := Notes + TakeLegacyNotes;

    if not Result then
    begin
      if (Code = ErrURLElicitationRequired) and not URLRetried then
      begin
        URLRetried := True;
        AskStart := NowMs;
        OK := HandleURLRequired(ErrJSON, Note);
        { the user's time is not the server's: extend the budget by it }
        Deadline := Deadline + (NowMs - AskStart);
        if OK then Continue;
        if Note <> '' then ErrMsg := Note;
      end
      else if (Code = ErrHeaderMismatch) and not HeaderRetried then
      begin
        HeaderRetried := True;
        if RecoverHeaderMismatch then Continue;
      end
      else if Code = ErrMissingCapability then
        ErrMsg := MissingCapabilityMessage(FName, ToolName, ErrJSON);
      ErrMsg := AppendNote(ErrMsg, Notes);
      Exit;
    end;

    RT := ResultTypeOf(ResJSON);
    if (RT = '') or (RT = 'complete') then
    begin
      ResultJSON := ResJSON;
      Result := ParseToolCallResultObject(ResJSON, Text, ErrMsg);
      ResultText := AppendNote(Text, Notes);
      if not Result then ErrMsg := AppendNote(ErrMsg, Notes);
      Exit;
    end;

    if RT = 'input_required' then
    begin
      Inc(Rounds);
      if Rounds > MCPMaxInputRounds then
      begin
        ErrMsg := Format('MCP server "%s" still wanted more input after %d rounds; ' +
                         'gave up on %s.', [FName, MCPMaxInputRounds, ToolName]);
        Exit(False);
      end;
      R := JsonTryParse(ResJSON);
      if R = nil then
      begin
        ErrMsg := 'unparseable input_required result';
        Exit(False);
      end;
      try
        ReqsJSON := R.GetRaw('inputRequests', '');
        HasState := R.Has('requestState');
        State := R.GetStr('requestState', '');
      finally
        R.Free;
      end;
      Responses := '';
      if ReqsJSON <> '' then
      begin
        AskStart := NowMs;
        OK := AnswerInputRequests(ReqsJSON, False, nil, Responses, Note);
        { Time spent answering is the user's, not the server's: it does not
          come out of the call's budget. }
        Deadline := Deadline + (NowMs - AskStart);
        if not OK then
        begin
          ErrMsg := AppendNote('', Note);
          Exit(False);
        end;
      end;
      LogDebug('mcp[%s] %s: input round %d answered, retrying', [FName, ToolName, Rounds]);
      Continue;
    end;

    if RT = 'task' then
    begin
      Result := FollowTask(ResJSON, Deadline, Text, ResultJSON, ErrMsg);
      if Result then ResultText := AppendNote(Text, Notes)
      else ErrMsg := AppendNote(ErrMsg, Notes);
      Exit;
    end;

    ErrMsg := Format('MCP server "%s" answered %s with an unknown resultType "%s"',
                     [FName, ToolName, RT]);
    Exit(False);
  end;
end;

{ ------------------------------------------------------------ tasks }

function TMCPProtocolClient.FollowTask(const CreateJSON: string; DeadlineMs: Int64;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  T, G, Err: TJsonObject;
  TaskId, Status, ResJSON, ErrJSON, Responses, Note, Notes, ReqsJSON, P: string;
  PollMs, Code, Rounds: Integer;
  TtlEnd, Started, AskStart: Int64;
  Answered: TStringList;
  OK: Boolean;

  function TaskParams: string;
  var
    O: TJsonObject;
  begin
    O := TJsonObject.Create;
    try
      O.PutStr('taskId', TaskId);
      Result := O.ToJSON;
    finally
      O.Free;
    end;
  end;

  procedure ReadTiming(O: TJsonObject);
  begin
    if O.Has('pollIntervalMs') then
    begin
      PollMs := O.GetInt('pollIntervalMs', DefaultPollMs);
      if PollMs < MinPollMs then PollMs := MinPollMs;
      if PollMs > MaxPollMs then PollMs := MaxPollMs;
    end;
    { ttlMs counts from creation; null means unlimited. }
    if O.GetRaw('ttlMs', 'null') <> 'null' then
      TtlEnd := Started + O.GetInt('ttlMs', 0)
    else if O.Has('ttlMs') then
      TtlEnd := 0;
  end;

  procedure CancelTask;
  var
    R1, M1, E1: string;
    C1: Integer;
  begin
    Call('tasks/cancel', WithMeta(TaskParams, FModern), 5000, R1, M1, E1, C1);
  end;

begin
  Result := False;
  ResultText := '';
  ResultJSON := '';
  ErrMsg := '';
  Notes := '';
  PollMs := DefaultPollMs;
  TtlEnd := 0;
  Started := NowMs;
  Rounds := 0;
  T := JsonTryParse(CreateJSON);
  if T = nil then
  begin
    ErrMsg := 'unparseable task handle';
    Exit;
  end;
  try
    TaskId := T.GetStr('taskId', '');
    Status := T.GetStr('status', 'working');
    ReadTiming(T);
  finally
    T.Free;
  end;
  if TaskId = '' then
  begin
    ErrMsg := Format('MCP server "%s" returned a task without a taskId', [FName]);
    Exit;
  end;
  LogDebug('mcp[%s] tools/call became task %s (poll %dms)', [FName, TaskId, PollMs]);

  Answered := TStringList.Create;
  try
    while True do
    begin
      { Wait the interval the server asked for, but never past the call's
        budget. }
      if NowMs + PollMs > DeadlineMs then
      begin
        CancelTask;
        ErrMsg := Format('MCP task %s on server "%s" was still %s when the tool ' +
                         'call timed out (%ds); PasClaw cancelled it.',
                         [TaskId, FName, Status, FCallTimeoutMs div 1000]);
        ErrMsg := AppendNote(ErrMsg, Notes);
        Exit;
      end;
      Sleep(PollMs);
      if (TtlEnd > 0) and (NowMs > TtlEnd) then
      begin
        ErrMsg := Format('MCP task %s on server "%s" outlived its ttl without ' +
                         'finishing.', [TaskId, FName]);
        ErrMsg := AppendNote(ErrMsg, Notes);
        Exit;
      end;
      if not Call('tasks/get', WithMeta(TaskParams, FModern),
                  Integer(DeadlineMs - NowMs) + 1000, ResJSON, ErrMsg, ErrJSON, Code) then
      begin
        ErrMsg := AppendNote(ErrMsg, Notes);
        Exit;
      end;
      G := JsonTryParse(ResJSON);
      if G = nil then
      begin
        ErrMsg := 'unparseable tasks/get result';
        Exit;
      end;
      try
        Status := G.GetStr('status', '');
        ReadTiming(G);
        if Status = 'working' then Continue;

        if Status = 'completed' then
        begin
          ResultJSON := G.GetRaw('result', '{}');
          Result := ParseToolCallResultObject(ResultJSON, ResultText, ErrMsg);
          ResultText := AppendNote(ResultText, Notes);
          if not Result then ErrMsg := AppendNote(ErrMsg, Notes);
          Exit;
        end;

        if Status = 'failed' then
        begin
          Err := G.ChildObject('error');
          if Err <> nil then
          try
            ErrMsg := Format('MCP task %s failed: %s (code %d)',
                             [TaskId, Err.GetStr('message', 'error'), Err.GetInt('code', 0)]);
          finally
            Err.Free;
          end
          else
            ErrMsg := Format('MCP task %s failed: %s',
                             [TaskId, G.GetStr('statusMessage', 'no details')]);
          ErrMsg := AppendNote(ErrMsg, Notes);
          Exit;
        end;

        if Status = 'cancelled' then
        begin
          ErrMsg := Format('MCP task %s was cancelled', [TaskId]);
          P := G.GetStr('statusMessage', '');
          if P <> '' then ErrMsg := ErrMsg + ': ' + P;
          ErrMsg := AppendNote(ErrMsg, Notes);
          Exit;
        end;

        if Status = 'input_required' then
        begin
          ReqsJSON := G.GetRaw('inputRequests', '{}');
        end
        else
        begin
          ErrMsg := Format('MCP task %s has an unknown status "%s"', [TaskId, Status]);
          Exit;
        end;
      finally
        G.Free;
      end;

      { input_required: answer the keys not answered yet, with tasks/update.
        The user's answering time does not come out of the call's budget. }
      AskStart := NowMs;
      OK := AnswerInputRequests(ReqsJSON, True, Answered, Responses, Note);
      DeadlineMs := DeadlineMs + (NowMs - AskStart);
      if not OK then
      begin
        CancelTask;
        ErrMsg := AppendNote('', Note);
        Exit;
      end;
      if Note <> '' then
      begin
        if Notes <> '' then Notes := Notes + ' ';
        Notes := Notes + Note;
      end;
      if Responses = '{}' then Continue;   { all seen already: keep polling }
      Inc(Rounds);
      if Rounds > MaxTaskInputRounds then
      begin
        CancelTask;
        ErrMsg := Format('MCP task %s kept asking for input (%d rounds); PasClaw ' +
                         'cancelled it.', [TaskId, MaxTaskInputRounds]);
        ErrMsg := AppendNote(ErrMsg, Notes);
        Exit;
      end;
      G := TJsonObject.Create;
      try
        G.PutStr('taskId', TaskId);
        G.PutRaw('inputResponses', Responses);
        if not Call('tasks/update', WithMeta(G.ToJSON, FModern), 10000,
                    ResJSON, ErrMsg, ErrJSON, Code) then
        begin
          ErrMsg := AppendNote(ErrMsg, Notes);
          Exit;
        end;
      finally
        G.Free;
      end;
    end;
  finally
    Answered.Free;
  end;
end;

{ ------------------------------------------- legacy server requests }

function TMCPProtocolClient.AnswerServerRequest(const RequestJSON: string): string;
var
  O, Out_, E: TJsonObject;
  Method, IdLit, Err: string;
  Req: TMCPElicitRequest;
  Resp: TMCPElicitResponse;
  ModeOk: Boolean;
begin
  Result := '';
  O := JsonTryParse(RequestJSON);
  if O = nil then Exit;
  try
    Method := O.GetStr('method', '');
    IdLit := JsonIdLiteral(O);
    Out_ := TJsonObject.Create;
    try
      Out_.PutStr('jsonrpc', JSONRPCVersion);
      Out_.PutRaw('id', IdLit);
      if Method = 'elicitation/create' then
      begin
        if not ElicitRequestFromParams(FName, O.GetRaw('params', '{}'), Req, Err) then
        begin
          E := TJsonObject.Create;
          E.PutInt('code', -32602);
          E.PutStr('message', Err);
          Out_.PutObject('error', E);
        end
        else
        begin
          { 2025-11-25: a mode the client did not declare is invalid params. }
          if Req.Mode = emURL then ModeOk := Pos('"url"', FLegacyElicitCap) > 0
          else ModeOk := (Pos('"form"', FLegacyElicitCap) > 0) or (FLegacyElicitCap = '{}');
          if not ModeOk then
          begin
            { Asked anyway: the model still hears what the server wanted. }
            if GLegacyNotes <> '' then GLegacyNotes := GLegacyNotes + ' ';
            GLegacyNotes := GLegacyNotes + UnattendedElicitNote(Req);
            E := TJsonObject.Create;
            E.PutInt('code', -32602);
            E.PutStr('message', 'elicitation mode not supported by this client');
            Out_.PutObject('error', E);
          end
          else
          begin
            Resp := RunElicitation(ThreadMCPElicitationHandler, Req);
            if Resp.Note <> '' then
            begin
              if GLegacyNotes <> '' then GLegacyNotes := GLegacyNotes + ' ';
              GLegacyNotes := GLegacyNotes + Resp.Note;
            end;
            Out_.PutRaw('result', ElicitResponseToJSON(Resp));
          end;
        end;
      end
      else if Method = 'ping' then
        Out_.PutRaw('result', '{}')
      else
      begin
        { Never offered: sampling, roots (both deprecated) or anything new. }
        E := TJsonObject.Create;
        E.PutInt('code', -32601);
        E.PutStr('message', 'method not supported by this client: ' + Method);
        Out_.PutObject('error', E);
      end;
      Result := Out_.ToJSON;
    finally
      Out_.Free;
    end;
  finally
    O.Free;
  end;
end;

end.
