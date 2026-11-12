(*
  PasClaw.ACP -- the agent side of the Agent Client Protocol.

  ACP (agentclientprotocol.com) is how an editor -- Zed, or any other ACP
  client -- drives a coding agent it did not build: it spawns the agent,
  speaks newline-delimited JSON-RPC 2.0 over the child's stdin/stdout, and
  renders what comes back -- the reply, each tool call with its diff, a
  permission prompt, the plan. `pasclaw acp` is PasClaw on that wire.

  This unit is the protocol and nothing else. The agent behind it is a
  TACPHost: the real one (Cmd.Agent) runs PasClaw's tool loop; the tests
  run a scripted one. Everything that is ACP's business lives here --
  framing, the request/response bookkeeping in both directions, sessions,
  cancellation -- and so does the translation of PasClaw's own events into
  ACP's vocabulary:

    the loop's text            -> agent_message_chunk
    a tool call                -> tool_call (kind, title, locations, the
                                  raw arguments), then tool_call_update
                                  with the result -- and, for a file a tool
                                  rewrote, a diff the editor can show
    todo_write's checklist     -> plan
    a permissions "ask" rule   -> session/request_permission, answered in
                                  the editor (once / for this session / no)
    session/cancel             -> the loop's cooperative stop, and the turn
                                  answers stopReason "cancelled"
    PasClaw's modes            -> session modes (build, plan, improve,
                                  space)

  Threads. The reader (one thread, the caller of HandleLine) never blocks
  on a turn: session/prompt starts a thread of its own, so the reader is
  free for what has to get through while a turn runs -- session/cancel,
  and the client's answers to our permission requests. Output from every
  thread goes through one lock, one line per message. Logs go to stderr
  (PasClaw.Logger); stdout carries ACP and nothing else.
*)
unit PasClaw.ACP;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Permissions,      { TAskAnswer }
  PasClaw.Agent.Mode;       { TPasClawMode }

const
  ACPProtocolVersion = 1;

  { JSON-RPC error codes ACP uses. }
  ACPParseError     = -32700;
  ACPInvalidRequest = -32600;
  ACPMethodNotFound = -32601;
  ACPInvalidParams  = -32602;
  ACPInternalError  = -32603;
  ACPNotFound       = -32002;

type
  TACPWriteLn = procedure(const Line: string) of object;

  TACPAgent = class;
  TACPTurn  = class;

  (* One ACP session: a conversation the client opened with session/new or
     session/load. Data is the host's own per-session state; the host owns
     it and frees it in CloseSession. *)
  TACPSession = class
  private
    FRunning:   Boolean;
    FCancel:    Boolean;
    FCallSeq:   Integer;
    FPending:   TList;     { TACPCallSlot -- announced calls awaiting a result }
    FTextSent:  Boolean;   { a message chunk already went out this turn }
  public
    Id:   string;
    Cwd:  string;
    Mode: TPasClawMode;
    Data: TObject;
    constructor Create(const AId: string);
    destructor Destroy; override;
  end;

  TACPTurnOutcome = record
    StopReason: string;   { end_turn | max_tokens | max_turn_requests | refusal | cancelled }
    Error:      string;   { non-empty: the turn failed, answered as an error }
  end;

  (* What the agent behind the protocol must do. Called from the reader
     thread (OpenSession, CloseSession) and from a turn's own thread
     (RunPrompt). *)
  TACPHost = class
  public
    { session/new (Load False) or session/load (Load True). S.Id is set --
      a fresh id for a new session, the requested one for a load -- and so
      are S.Cwd and S.Mode. McpServers is the request's mcpServers array
      (may be nil). A load returns the conversation in History, which the
      protocol replays to the client. False + Err refuses the request;
      NotFound distinguishes "no such session" (ACPNotFound). }
    function OpenSession(S: TACPSession; McpServers: TJsonArray; Load: Boolean;
                         out History: TMessageArray; out NotFound: Boolean;
                         out Err: string): Boolean; virtual; abstract;
    { One prompt turn. PromptText is the prompt's content blocks flattened
      to text (ACPPromptText). Report through Turn while it runs; poll
      Turn.Cancelled at safe points. }
    function RunPrompt(S: TACPSession; const PromptText: string;
                       Turn: TACPTurn): TACPTurnOutcome; virtual; abstract;
    { The process is ending: free S.Data. }
    procedure CloseSession(S: TACPSession); virtual;
  end;

  (* The reporting surface of one turn, handed to TACPHost.RunPrompt. Its
     four event methods match the tool loop's callbacks one for one, so the
     host wires them straight in (OnText, OnToolCall, OnToolResult, OnAsk,
     ShouldCancel). Safe to call from any thread. *)
  TACPTurn = class
  private
    FAgent:   TACPAgent;
    FSession: TACPSession;
  public
    constructor Create(Agent: TACPAgent; Session: TACPSession);
    procedure Text(const S: string);
    { A piece of the reply as the model writes it (TToolLoopConfig.
      OnTextDelta); First marks a round's first piece. }
    procedure TextDelta(const Delta: string; First: Boolean);
    procedure ToolCall(const Name, ArgsJSON: string);
    procedure ToolResult(const Name, ResultText, Err: string);
    function  Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
    function  Cancelled: Boolean;
    { A line the user should see that is not the model's: a stop notice,
      a verification report. Sent as an agent message chunk. }
    procedure Notice(const S: string);
  end;

  TACPAgent = class
  private
    FHost:        TACPHost;
    FWrite:       TACPWriteLn;
    FVersion:     string;
    FLock:        TCriticalSection;   { sessions, pending requests, threads }
    FOutLock:     TCriticalSection;   { one message per line on the wire }
    FInitialized: Boolean;
    FSessions:    TStringList;        { id -> TACPSession, owned }
    FOutgoing:    TList;              { TACPOutgoing -- our requests in flight }
    FNextId:      Int64;
    FThreads:     TList;              { prompt threads, for Shutdown }
    procedure Send(const Line: string);
    procedure Respond(const IdRaw, ResultJSON: string);
    procedure RespondError(const IdRaw: string; Code: Integer;
                           const Msg: string; const DataJSON: string = '');
    procedure HandleRequest(const IdRaw, Method: string; Params: TJsonObject);
    procedure HandleNotification(const Method: string; Params: TJsonObject);
    procedure HandleResponse(Obj: TJsonObject);
    procedure DoInitialize(const IdRaw: string);
    procedure DoNewOrLoad(const IdRaw: string; Params: TJsonObject; Load: Boolean);
    procedure DoPrompt(const IdRaw: string; Params: TJsonObject);
    procedure DoSetMode(const IdRaw: string; Params: TJsonObject);
    procedure DoCancel(Params: TJsonObject);
    function  FindSession(const Id: string): TACPSession;
    procedure ReplayHistory(S: TACPSession; const History: TMessageArray);
    procedure CloseOpenCalls(S: TACPSession);
    procedure ReapThreads(WaitAll: Boolean);
    { Turn support. }
    function  Request(const SessionId, Method, ParamsJSON: string;
                      out ResultJSON: string): Boolean;
    function  NextCallId(S: TACPSession): string;
  public
    (* How long a permission request waits for the editor before it counts
       as a no -- the host sets it from permissions_ask_timeout_sec, the
       limit every other surface's asks run under. The editor is then told
       the prompt is no longer wanted ($/cancel_request), and a late answer
       is ignored. INFINITE until set. *)
    AskTimeoutMs: Cardinal;
    constructor Create(Host: TACPHost; Write: TACPWriteLn; const Version: string);
    destructor Destroy; override;
    { One line from the client. Never blocks on a turn. }
    procedure HandleLine(const Line: string);
    { session/update for S. UpdateJSON is the update object. }
    procedure SessionUpdate(const SessionId, UpdateJSON: string);
    { stdin closed: cancel every turn, wait for them, close the sessions. }
    procedure Shutdown;
  end;

{ ---- the translation, public so the tests can pin it ---- }

{ ACP's ToolKind for a PasClaw tool: read, edit, delete, move, search,
  execute, think, fetch, switch_mode or other. }
function ACPToolKind(const ToolName: string): string;

{ The one-line title a client shows for a call: what it does, to what. }
function ACPToolTitle(const ToolName, ArgsJSON: string): string;

{ todo_write's markdown checklist as ACP plan entries (a JSON array):
  "- [x]" completed, "- [~]" / "- [-]" in progress, "- [ ]" pending. }
function ACPPlanEntries(const Checklist: string): string;

{ A session/prompt's ContentBlock[] flattened to one prompt for the loop:
  text as is, a resource link as a reference, an embedded resource as a
  context block, anything else as a note that it was left out. }
function ACPPromptText(Blocks: TJsonArray): string;

{ The path argument of a file tool, resolved against Cwd. '' when none. }
function ACPToolPath(const ArgsJSON, Cwd: string): string;

{ The session modes PasClaw offers, as an ACP SessionModeState. }
function ACPModesJSON(Current: TPasClawMode): string;

implementation

uses
  PasClaw.Logger,
  PasClaw.Utils,          { ReadFileText, Utf8SafeTruncate }
  PasClaw.Tools.ToolLoop; { StripTurnClock }

const
  { What the client is shown of a tool's result, and the largest file a
    diff is built for. Both are display: the model's own copy of a result
    is untouched. }
  ResultShowBytes = 32 * 1024;
  { A call announced but never given a result: its turn was cancelled with
    a batch half run, or stopped in between. Live and on replay alike. }
  CallNotFinishedText = 'The turn ended before this call finished.';
  DiffMaxBytes    = 1024 * 1024;
  { How every gate words its refusal (PasClaw.Permissions, Agent.Mode). }
  RefusedPrefix   = 'refused: ';

type
  (* A tool call announced to the client and not yet finished. *)
  TACPCallSlot = class
    Id, Name, Args: string;
    Path:    string;    { the file the call names, '' when none }
    Diff:    Boolean;   { an edit tool: the result carries a diff of Path }
    OldText: string;
    Existed: Boolean;   { the file existed before the call }
  end;

  (* One of our requests to the client (session/request_permission). *)
  TACPOutgoing = class
    Id:        Int64;
    SessionId: string;
    Event:     TEvent;
    Done:      Boolean;
    Ok:        Boolean;
    ResultJSON: string;
    constructor Create(AId: Int64; const ASession: string);
    destructor Destroy; override;
  end;

  TACPPromptThread = class(TThread)
  private
    FAgent:   TACPAgent;
    FSession: TACPSession;
    FIdRaw:   string;
    FText:    string;
  protected
    procedure Execute; override;
  public
    constructor Create(Agent: TACPAgent; Session: TACPSession;
                       const IdRaw, Text: string);
  end;

{ ---------------------------------------------------------------- helpers -- }

function Q(const S: string): string;
begin
  Result := '"' + JsonEscape(S) + '"';
end;

function Squash(const S: string; Max: Integer): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if CharInSet(Result[i], [#9, #10, #13]) then Result[i] := ' ';
  Result := Trim(Result);
  if Length(Result) > Max then Result := Utf8SafeTruncate(Result, Max - 3) + '...';
end;

{ A tool call's arguments as an object, or nil when they are not one. Each
  call's arguments are parsed once, here; the caller frees the result. }
function ParseArgsObj(const ArgsJSON: string): TJsonObject;
var
  T: string;
begin
  Result := nil;
  T := Trim(ArgsJSON);
  if (T = '') or (T[1] <> '{') then Exit;
  try
    Result := TJsonObject.Parse(T);
  except
    Result := nil;
  end;
end;

function ArgOf(Args: TJsonObject; const Key: string): string;
begin
  if Args = nil then Result := '' else Result := Args.GetStr(Key, '');
end;

{ rawInput: the arguments as they came when they are an object, else as
  a string. }
function RawInputOf(Args: TJsonObject; const ArgsJSON: string): string;
begin
  if Args <> nil then Result := ArgsJSON else Result := Q(ArgsJSON);
end;

function TextBlock(const S: string): string;
begin
  Result := '{"type":"text","text":' + Q(S) + '}';
end;

function IsAbsolute(const Path: string): Boolean;
begin
  Result := False;
  if Path = '' then Exit;
  {$IFDEF MSWINDOWS}
  Result := ((Length(Path) > 2) and (Path[2] = ':') and CharInSet(Path[3], ['\', '/'])) or
            ((Length(Path) > 1) and CharInSet(Path[1], ['\', '/']) and
             CharInSet(Path[2], ['\', '/']));
  {$ELSE}
  Result := Path[1] = '/';
  {$ENDIF}
end;

function ResolveAgainst(const Path, Cwd: string): string;
begin
  Result := Path;
  if Result = '' then Exit;
  if (not IsAbsolute(Result)) and (Cwd <> '') then
    Result := IncludeTrailingPathDelimiter(Cwd) + Result;
  Result := ExpandFileName(Result);
end;

function FileSize_(const Path: string): Int64;
var
  SR: TSearchRec;
begin
  Result := -1;
  if FindFirst(Path, faAnyFile, SR) = 0 then
  begin
    Result := SR.Size;
    FindClose(SR);
  end;
end;

{ ------------------------------------------------------------ translation -- }

function ACPToolKind(const ToolName: string): string;
var
  N: string;
begin
  N := LowerCase(ToolName);
  if (N = 'read_file') or (N = 'list_dir') or (N = 'code_outline') or
     (N = 'tool_output_get') or (N = 'memory_get') or (N = 'kb_get') or
     (N = 'vault_get') or (N = 'session_read') or (N = 'skills_view') or
     (N = 'skills_list') or (N = 'worktree_list') then
    Result := 'read'
  else if (N = 'write_file') or (N = 'append_file') or (N = 'edit_file') or
          (N = 'apply_patch') or (N = 'plan_write') or (N = 'memory_write') or
          (Pos('fs_write', N) = 1) or (Pos('fs_edit', N) = 1) then
    Result := 'edit'
  else if (Pos('delete', N) > 0) or (Pos('remove', N) > 0) then
    Result := 'delete'
  else if (Pos('move', N) > 0) or (Pos('rename', N) > 0) then
    Result := 'move'
  else if (N = 'grep_files') or (N = 'find_files') or (N = 'tool_search') or
          (Pos('_search', N) > 0) or (N = 'code_catalog') then
    Result := 'search'
  else if (N = 'shell_exec') or (N = 'shell_background') or
          (N = 'execute_code') or (N = 'delphi_build') or (N = 'db_execute') or
          (N = 'db_query') or (Pos('worktree_', N) = 1) then
    Result := 'execute'
  else if (N = 'web_fetch') or (N = 'memory_fetch') then
    Result := 'fetch'
  else if (N = 'todo_write') then
    Result := 'think'
  else
    Result := 'other';
end;

function ToolTitleOf(const ToolName: string; Args: TJsonObject): string;
const
  Keys: array[0..8] of string = ('command', 'path', 'pattern', 'query', 'url',
                                 'symbol', 'name', 'action', 'prompt');
var
  N, V: string;
  i: Integer;
begin
  N := LowerCase(ToolName);
  if (N = 'shell_exec') or (N = 'shell_background') then
  begin
    V := ArgOf(Args, 'command');
    if V <> '' then Exit(Squash(V, 120));
  end
  else if N = 'todo_write' then
    Exit('Update the checklist');
  V := '';
  for i := Low(Keys) to High(Keys) do
  begin
    V := ArgOf(Args, Keys[i]);
    if V <> '' then Break;
  end;
  if      N = 'read_file'   then Result := 'Read'
  else if N = 'write_file'  then Result := 'Write'
  else if N = 'edit_file'   then Result := 'Edit'
  else if N = 'append_file' then Result := 'Append to'
  else if N = 'list_dir'    then Result := 'List'
  else if N = 'grep_files'  then Result := 'Search for'
  else if N = 'find_files'  then Result := 'Find'
  else if N = 'web_fetch'   then Result := 'Fetch'
  else if N = 'apply_patch' then Result := 'Apply a patch'
  else Result := ToolName;
  if (V <> '') and (N <> 'apply_patch') then
    Result := Result + ' ' + Squash(V, 100);
end;

function ACPToolTitle(const ToolName, ArgsJSON: string): string;
var
  Args: TJsonObject;
begin
  Args := ParseArgsObj(ArgsJSON);
  try
    Result := ToolTitleOf(ToolName, Args);
  finally
    Args.Free;
  end;
end;

function ACPPlanEntries(const Checklist: string): string;
var
  Lines: TStringList;
  i: Integer;
  L, Mark, Status, Content: string;
  First: Boolean;
begin
  Result := '[';
  First := True;
  Lines := TStringList.Create;
  try
    Lines.Text := Checklist;
    for i := 0 to Lines.Count - 1 do
    begin
      L := Trim(Lines[i]);
      if (Length(L) < 5) or not CharInSet(L[1], ['-', '*']) then Continue;
      L := TrimLeft(Copy(L, 2, MaxInt));
      if (Length(L) < 3) or (L[1] <> '[') or (L[3] <> ']') then Continue;
      Mark := LowerCase(L[2]);
      Content := Trim(Copy(L, 4, MaxInt));
      if Content = '' then Continue;
      if Mark = 'x' then Status := 'completed'
      else if (Mark = '~') or (Mark = '-') or (Mark = '>') then Status := 'in_progress'
      else Status := 'pending';
      if not First then Result := Result + ',';
      First := False;
      Result := Result + '{"content":' + Q(Content) +
                ',"priority":"medium","status":' + Q(Status) + '}';
    end;
  finally
    Lines.Free;
  end;
  Result := Result + ']';
end;

function ACPPromptText(Blocks: TJsonArray): string;
var
  i: Integer;
  B, R: TJsonObject;
  Kind, Part, Uri: string;
begin
  Result := '';
  if Blocks = nil then Exit;
  for i := 0 to Blocks.Count - 1 do
  begin
    B := Blocks.ItemObject(i);
    if B = nil then Continue;
    Kind := B.GetStr('type', '');
    Part := '';
    if Kind = 'text' then
      Part := B.GetStr('text', '')
    else if Kind = 'resource_link' then
    begin
      Uri := B.GetStr('uri', '');
      Part := '@' + B.GetStr('name', Uri);
      if Uri <> '' then Part := Part + ' (' + Uri + ')';
    end
    else if Kind = 'resource' then
    begin
      R := B.ChildObject('resource');
      if R <> nil then
      begin
        Uri := R.GetStr('uri', '');
        if R.Has('text') then
          Part := '<context uri="' + Uri + '">' + sLineBreak +
                  R.GetStr('text', '') + sLineBreak + '</context>'
        else
          Part := '[' + Uri + ': binary content left out]';
      end;
    end
    else if Kind <> '' then
      Part := '[' + Kind + ' content left out: this agent takes text]';
    if Part = '' then Continue;
    if Result <> '' then Result := Result + sLineBreak;
    Result := Result + Part;
  end;
end;

function ToolPathOf(Args: TJsonObject; const Cwd: string): string;
var
  P: string;
begin
  P := ArgOf(Args, 'path');
  if P = '' then P := ArgOf(Args, 'file');
  Result := ResolveAgainst(P, Cwd);
end;

function ACPToolPath(const ArgsJSON, Cwd: string): string;
var
  Args: TJsonObject;
begin
  Args := ParseArgsObj(ArgsJSON);
  try
    Result := ToolPathOf(Args, Cwd);
  finally
    Args.Free;
  end;
end;

function ACPModesJSON(Current: TPasClawMode): string;
begin
  Result :=
    '{"currentModeId":' + Q(ModeName(Current)) + ',"availableModes":[' +
    '{"id":"build","name":"Build","description":"Full tool access."},' +
    '{"id":"plan","name":"Plan","description":"Read-only: mutating tools ' +
      'refuse; the agent writes a plan."},' +
    '{"id":"improve","name":"Improve","description":"Benchmark, profile, ' +
      'change one thing, re-measure."},' +
    '{"id":"space","name":"Space","description":"Search, plan, assert, ' +
      'code, evaluate: writes unlock after a plan."}]}';
end;

{ ------------------------------------------------------------ TACPSession -- }

constructor TACPSession.Create(const AId: string);
begin
  inherited Create;
  Id := AId;
  FPending := TList.Create;
end;

destructor TACPSession.Destroy;
var
  i: Integer;
begin
  for i := 0 to FPending.Count - 1 do TObject(FPending[i]).Free;
  FPending.Free;
  inherited;
end;

{ --------------------------------------------------------------- TACPHost -- }

procedure TACPHost.CloseSession(S: TACPSession);
begin
  FreeAndNil(S.Data);
end;

{ ----------------------------------------------------------- TACPOutgoing -- }

constructor TACPOutgoing.Create(AId: Int64; const ASession: string);
begin
  inherited Create;
  Id := AId;
  SessionId := ASession;
  Event := TEvent.Create(nil, True, False, '');
end;

destructor TACPOutgoing.Destroy;
begin
  Event.Free;
  inherited;
end;

{ ------------------------------------------------------- TACPPromptThread -- }

constructor TACPPromptThread.Create(Agent: TACPAgent; Session: TACPSession;
  const IdRaw, Text: string);
begin
  FAgent := Agent;
  FSession := Session;
  FIdRaw := IdRaw;
  FText := Text;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TACPPromptThread.Execute;
var
  Turn: TACPTurn;
  Outcome: TACPTurnOutcome;
begin
  Outcome := Default(TACPTurnOutcome);
  Turn := TACPTurn.Create(FAgent, FSession);
  try
    try
      Outcome := FAgent.FHost.RunPrompt(FSession, FText, Turn);
    except
      on E: Exception do
      begin
        Outcome.StopReason := '';
        Outcome.Error := E.Message;
      end;
    end;
    { A cancelled turn answers "cancelled" whatever happened underneath --
      the spec's words, and the only answer a client that pressed stop can
      act on. }
    if Turn.Cancelled then
    begin
      Outcome.StopReason := 'cancelled';
      Outcome.Error := '';
    end;
  finally
    Turn.Free;
  end;
  FAgent.CloseOpenCalls(FSession);
  FAgent.FLock.Enter;
  try
    FSession.FRunning := False;
    FSession.FCancel := False;
  finally
    FAgent.FLock.Leave;
  end;
  if Outcome.Error <> '' then
    FAgent.RespondError(FIdRaw, ACPInternalError, Outcome.Error)
  else
  begin
    if Outcome.StopReason = '' then Outcome.StopReason := 'end_turn';
    FAgent.Respond(FIdRaw, '{"stopReason":' + Q(Outcome.StopReason) + '}');
  end;
end;

{ --------------------------------------------------------------- TACPTurn -- }

constructor TACPTurn.Create(Agent: TACPAgent; Session: TACPSession);
begin
  inherited Create;
  FAgent := Agent;
  FSession := Session;
end;

function TACPTurn.Cancelled: Boolean;
begin
  FAgent.FLock.Enter;
  try
    Result := FSession.FCancel;
  finally
    FAgent.FLock.Leave;
  end;
end;

procedure TACPTurn.Text(const S: string);
var
  Chunk: string;
begin
  if S = '' then Exit;
  Chunk := S;
  { The loop reports each model round's text whole. Two rounds on either
    side of a tool call are two paragraphs, not one run-on sentence. }
  FAgent.FLock.Enter;
  try
    if FSession.FTextSent then Chunk := sLineBreak + sLineBreak + Chunk;
    FSession.FTextSent := True;
  finally
    FAgent.FLock.Leave;
  end;
  FAgent.SessionUpdate(FSession.Id,
    '{"sessionUpdate":"agent_message_chunk","content":' + TextBlock(Chunk) + '}');
end;

procedure TACPTurn.TextDelta(const Delta: string; First: Boolean);
var
  Chunk: string;
begin
  if Delta = '' then Exit;
  Chunk := Delta;
  { A round's first piece opens a paragraph after earlier text, as a
    whole round does in Text. }
  if First then
  begin
    FAgent.FLock.Enter;
    try
      if FSession.FTextSent then Chunk := sLineBreak + sLineBreak + Chunk;
      FSession.FTextSent := True;
    finally
      FAgent.FLock.Leave;
    end;
  end;
  FAgent.SessionUpdate(FSession.Id,
    '{"sessionUpdate":"agent_message_chunk","content":' + TextBlock(Chunk) + '}');
end;

procedure TACPTurn.Notice(const S: string);
begin
  Text(S);
end;

procedure TACPTurn.ToolCall(const Name, ArgsJSON: string);
var
  Slot: TACPCallSlot;
  Kind, Raw, Loc, Title, Plan: string;
  Args: TJsonObject;
begin
  Args := ParseArgsObj(ArgsJSON);
  try
    Title := ToolTitleOf(Name, Args);
    Raw := RawInputOf(Args, ArgsJSON);
    Plan := '';
    if LowerCase(Name) = 'todo_write' then
      Plan := ACPPlanEntries(ArgOf(Args, 'checklist'));
    Slot := TACPCallSlot.Create;
    Slot.Path := ToolPathOf(Args, FSession.Cwd);
  finally
    Args.Free;
  end;
  Slot.Id := FAgent.NextCallId(FSession);
  Slot.Name := Name;
  Slot.Args := ArgsJSON;
  Kind := ACPToolKind(Name);
  Loc := '';
  if Slot.Path <> '' then
    Loc := ',"locations":[{"path":' + Q(Slot.Path) + '}]';
  { For a file a tool is about to rewrite, keep what it says now: the
    result can then carry a diff the editor shows as one. }
  if (Kind = 'edit') and (Slot.Path <> '') then
  begin
    Slot.Existed := FileExists(Slot.Path);
    { Too large to diff: the call still shows, without one. }
    Slot.Diff := (not Slot.Existed) or (FileSize_(Slot.Path) <= DiffMaxBytes);
    if Slot.Existed and Slot.Diff then
      Slot.OldText := ReadFileText(Slot.Path);
  end;
  FAgent.FLock.Enter;
  try
    FSession.FPending.Add(Slot);
  finally
    FAgent.FLock.Leave;
  end;
  FAgent.SessionUpdate(FSession.Id,
    '{"sessionUpdate":"tool_call","toolCallId":' + Q(Slot.Id) +
    ',"title":' + Q(Title) +
    ',"name":' + Q(Name) +
    ',"kind":' + Q(Kind) + ',"status":"in_progress"' + Loc +
    ',"rawInput":' + Raw + '}');
  if Plan <> '' then
    FAgent.SessionUpdate(FSession.Id,
      '{"sessionUpdate":"plan","entries":' + Plan + '}');
end;

procedure TACPTurn.ToolResult(const Name, ResultText, Err: string);
var
  Slot: TACPCallSlot;
  i: Integer;
  Status, Shown, Content, NewText, OldJSON: string;
begin
  Slot := nil;
  FAgent.FLock.Enter;
  try
    { Results come back in the order the calls were announced; the first
      open call of this name is this one. }
    for i := 0 to FSession.FPending.Count - 1 do
      if TACPCallSlot(FSession.FPending[i]).Name = Name then
      begin
        Slot := TACPCallSlot(FSession.FPending[i]);
        FSession.FPending.Delete(i);
        Break;
      end;
  finally
    FAgent.FLock.Leave;
  end;
  if Slot = nil then Exit;
  try
    if Err <> '' then
    begin
      Status := 'failed';
      Shown := Err;
      if ResultText <> '' then Shown := ResultText + sLineBreak + Err;
    end
    else if Copy(ResultText, 1, Length(RefusedPrefix)) = RefusedPrefix then
    begin
      { A gate stopped it -- a permissions rule, a declined ask, plan or
        space mode. The loop hands the refusal back as the result, not as
        an error, so the model reads it; the editor must not show a call
        that never ran as done. }
      Status := 'failed';
      Shown := ResultText;
    end
    else
    begin
      Status := 'completed';
      Shown := ResultText;
    end;
    if Length(Shown) > ResultShowBytes then
      Shown := Utf8SafeTruncate(Shown, ResultShowBytes) + sLineBreak + '[... shortened for display]';
    Content := '{"type":"content","content":' + TextBlock(Shown) + '}';
    if (Err = '') and Slot.Diff and FileExists(Slot.Path) and
       (FileSize_(Slot.Path) <= DiffMaxBytes) then
    begin
      NewText := ReadFileText(Slot.Path);
      if (not Slot.Existed) or (NewText <> Slot.OldText) then
      begin
        if Slot.Existed then OldJSON := Q(Slot.OldText) else OldJSON := 'null';
        Content := '{"type":"diff","path":' + Q(Slot.Path) +
                   ',"oldText":' + OldJSON + ',"newText":' + Q(NewText) + '},' +
                   Content;
      end;
    end;
    FAgent.SessionUpdate(FSession.Id,
      '{"sessionUpdate":"tool_call_update","toolCallId":' + Q(Slot.Id) +
      ',"status":' + Q(Status) + ',"content":[' + Content + ']}');
  finally
    Slot.Free;
  end;
end;

function TACPTurn.Ask(const ToolName, ArgsJSON, Resource, Reason: string): TAskAnswer;
var
  i: Integer;
  Slot: TACPCallSlot;
  CallId, Title, ResultJSON, Outcome, Option: string;
  R, O: TJsonObject;
begin
  Result := aaDeny;
  if Cancelled then Exit;
  { The call this ask is about: announced, not finished, same name and
    arguments. }
  CallId := '';
  FAgent.FLock.Enter;
  try
    for i := 0 to FSession.FPending.Count - 1 do
    begin
      Slot := TACPCallSlot(FSession.FPending[i]);
      if (Slot.Name = ToolName) and (Slot.Args = ArgsJSON) then
      begin
        CallId := Slot.Id;
        Break;
      end;
    end;
  finally
    FAgent.FLock.Leave;
  end;
  if CallId = '' then CallId := FAgent.NextCallId(FSession);
  Title := ACPToolTitle(ToolName, ArgsJSON);
  if Reason <> '' then Title := Title + ' -- ' + Squash(Reason, 120);
  if not FAgent.Request(FSession.Id, 'session/request_permission',
       '{"sessionId":' + Q(FSession.Id) +
       ',"toolCall":{"toolCallId":' + Q(CallId) + ',"title":' + Q(Title) +
       ',"kind":' + Q(ACPToolKind(ToolName)) + ',"status":"pending"},' +
       '"options":[' +
       '{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},' +
       '{"optionId":"allow_session","name":"Allow for this session","kind":"allow_always"},' +
       '{"optionId":"reject_once","name":"Deny","kind":"reject_once"}]}',
       ResultJSON) then
    Exit;
  { Anything but a selected allow is a no: a cancelled outcome, a reject,
    an option we did not offer, a malformed answer. }
  try
    R := TJsonObject.Parse(ResultJSON);
  except
    Exit;
  end;
  try
    O := R.ChildObject('outcome');
    if O = nil then Exit;
    Outcome := O.GetStr('outcome', '');
    Option := O.GetStr('optionId', '');
    if Outcome <> 'selected' then Exit;
    if Option = 'allow_once' then Result := aaAllowOnce
    else if Option = 'allow_session' then Result := aaAllowSession;
  finally
    R.Free;
  end;
end;

{ -------------------------------------------------------------- TACPAgent -- }

constructor TACPAgent.Create(Host: TACPHost; Write: TACPWriteLn;
  const Version: string);
begin
  inherited Create;
  FHost := Host;
  FWrite := Write;
  FVersion := Version;
  FLock := TCriticalSection.Create;
  FOutLock := TCriticalSection.Create;
  FSessions := TStringList.Create;
  FSessions.OwnsObjects := True;
  FOutgoing := TList.Create;
  FThreads := TList.Create;
  AskTimeoutMs := INFINITE;
end;

destructor TACPAgent.Destroy;
var
  i: Integer;
begin
  ReapThreads(True);
  for i := 0 to FOutgoing.Count - 1 do TObject(FOutgoing[i]).Free;
  FOutgoing.Free;
  FThreads.Free;
  FSessions.Free;
  FOutLock.Free;
  FLock.Free;
  inherited;
end;

procedure TACPAgent.Send(const Line: string);
begin
  FOutLock.Enter;
  try
    FWrite(Line);
  finally
    FOutLock.Leave;
  end;
end;

procedure TACPAgent.Respond(const IdRaw, ResultJSON: string);
begin
  Send('{"jsonrpc":"2.0","id":' + IdRaw + ',"result":' + ResultJSON + '}');
end;

procedure TACPAgent.RespondError(const IdRaw: string; Code: Integer;
  const Msg: string; const DataJSON: string);
var
  E: string;
begin
  E := '{"code":' + IntToStr(Code) + ',"message":' + Q(Msg);
  if DataJSON <> '' then E := E + ',"data":' + DataJSON;
  Send('{"jsonrpc":"2.0","id":' + IdRaw + ',"error":' + E + '}}');
end;

procedure TACPAgent.SessionUpdate(const SessionId, UpdateJSON: string);
begin
  Send('{"jsonrpc":"2.0","method":"session/update","params":{"sessionId":' +
       Q(SessionId) + ',"update":' + UpdateJSON + '}}');
end;

function TACPAgent.NextCallId(S: TACPSession): string;
begin
  FLock.Enter;
  try
    Inc(S.FCallSeq);
    Result := 'call_' + IntToStr(S.FCallSeq);
  finally
    FLock.Leave;
  end;
end;

function TACPAgent.FindSession(const Id: string): TACPSession;
var
  i: Integer;
begin
  Result := nil;
  FLock.Enter;
  try
    i := FSessions.IndexOf(Id);
    if i >= 0 then Result := TACPSession(FSessions.Objects[i]);
  finally
    FLock.Leave;
  end;
end;

procedure TACPAgent.HandleLine(const Line: string);
var
  Obj, Params: TJsonObject;
  Method, IdRaw: string;
begin
  if Trim(Line) = '' then Exit;
  try
    Obj := TJsonObject.Parse(Line);
  except
    RespondError('null', ACPParseError, 'not a JSON object');
    Exit;
  end;
  try
    Method := Obj.GetStr('method', '');
    if Method = '' then
    begin
      { No method: the client answering one of our requests. }
      if Obj.Has('id') then HandleResponse(Obj);
      Exit;
    end;
    Params := Obj.ChildObject('params');
    if not Obj.Has('id') then
      HandleNotification(Method, Params)
    else
    begin
      IdRaw := JsonIdLiteral(Obj);
      try
        HandleRequest(IdRaw, Method, Params);
      except
        on E: Exception do
          RespondError(IdRaw, ACPInternalError, E.Message);
      end;
    end;
  finally
    Obj.Free;
  end;
end;

procedure TACPAgent.HandleRequest(const IdRaw, Method: string; Params: TJsonObject);
begin
  if Method = 'initialize' then
  begin
    DoInitialize(IdRaw);
    Exit;
  end;
  if not FInitialized then
  begin
    RespondError(IdRaw, ACPInvalidRequest, 'call initialize first');
    Exit;
  end;
  if Method = 'session/new' then DoNewOrLoad(IdRaw, Params, False)
  else if Method = 'session/load' then DoNewOrLoad(IdRaw, Params, True)
  else if Method = 'session/prompt' then DoPrompt(IdRaw, Params)
  else if Method = 'session/set_mode' then DoSetMode(IdRaw, Params)
  else if Method = 'authenticate' then
    { No authMethods are advertised -- PasClaw's provider keys live in its
      own config -- so there is nothing to authenticate with. }
    RespondError(IdRaw, ACPInvalidParams, 'this agent has no authentication methods')
  else
    RespondError(IdRaw, ACPMethodNotFound, 'method not found: ' + Method);
end;

procedure TACPAgent.HandleNotification(const Method: string; Params: TJsonObject);
begin
  { Unknown notifications are ignored, as the spec asks. }
  if Method = 'session/cancel' then DoCancel(Params);
end;

procedure TACPAgent.HandleResponse(Obj: TJsonObject);
var
  Id: Int64;
  i: Integer;
  P: TACPOutgoing;
  R: TJsonObject;
begin
  Id := Obj.GetInt('id', -1);
  FLock.Enter;
  try
    for i := 0 to FOutgoing.Count - 1 do
    begin
      P := TACPOutgoing(FOutgoing[i]);
      if (P.Id = Id) and not P.Done then
      begin
        P.Done := True;
        P.Ok := Obj.Has('result');
        R := Obj.ChildObject('result');
        if R <> nil then P.ResultJSON := R.ToJSON else P.ResultJSON := '{}';
        P.Event.SetEvent;
        Break;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TACPAgent.DoInitialize(const IdRaw: string);
begin
  { Version 1 is the one PasClaw speaks; a client asking for another gets
    1 back and decides for itself whether to carry on (the spec's rule). }
  FInitialized := True;
  Respond(IdRaw,
    '{"protocolVersion":' + IntToStr(ACPProtocolVersion) + ',' +
    '"agentCapabilities":{"loadSession":true,' +
      '"promptCapabilities":{"image":false,"audio":false,"embeddedContext":true},' +
      '"mcpCapabilities":{"http":false,"sse":false}},' +
    '"agentInfo":{"name":"pasclaw","title":"PasClaw","version":' + Q(FVersion) + '},' +
    '"authMethods":[]}');
end;

procedure TACPAgent.DoNewOrLoad(const IdRaw: string; Params: TJsonObject; Load: Boolean);
var
  S, Existing: TACPSession;
  Cwd, Err, Id: string;
  History: TMessageArray;
  NotFound: Boolean;
begin
  if Params = nil then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'params required');
    Exit;
  end;
  Cwd := Params.GetStr('cwd', '');
  if not IsAbsolute(Cwd) then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'cwd must be an absolute path');
    Exit;
  end;
  if Load then
  begin
    Id := Params.GetStr('sessionId', '');
    if Id = '' then
    begin
      RespondError(IdRaw, ACPInvalidParams, 'sessionId required');
      Exit;
    end;
    Existing := FindSession(Id);
    if (Existing <> nil) and Existing.FRunning then
    begin
      RespondError(IdRaw, ACPInvalidRequest, 'that session has a turn running');
      Exit;
    end;
  end
  else
    Id := '';
  S := TACPSession.Create(Id);
  S.Cwd := ExcludeTrailingPathDelimiter(Cwd);
  S.Mode := pmBuild;
  if not FHost.OpenSession(S, Params.ChildArray('mcpServers'), Load, History,
                           NotFound, Err) then
  begin
    S.Free;
    if NotFound then
      RespondError(IdRaw, ACPNotFound, Err, '{"sessionId":' + Q(Id) + '}')
    else
      RespondError(IdRaw, ACPInternalError, Err);
    Exit;
  end;
  FLock.Enter;
  try
    { A load of a session this process already has replaces it. }
    if FSessions.IndexOf(S.Id) >= 0 then
    begin
      FHost.CloseSession(TACPSession(FSessions.Objects[FSessions.IndexOf(S.Id)]));
      FSessions.Delete(FSessions.IndexOf(S.Id));
    end;
    FSessions.AddObject(S.Id, S);
  finally
    FLock.Leave;
  end;
  if Load then
  begin
    { The whole conversation goes out before the answer -- the client
      rebuilds its view from the replay. }
    ReplayHistory(S, History);
    Respond(IdRaw, '{"modes":' + ACPModesJSON(S.Mode) + '}');
  end
  else
    Respond(IdRaw, '{"sessionId":' + Q(S.Id) + ',"modes":' + ACPModesJSON(S.Mode) + '}');
end;

(* Calls the loop announced but never reported a result for: the turn was
   cancelled with a batch half run, or stopped in between. Each is shown
   as failed before the turn answers, so the editor is not left with a
   spinner, and the session starts its next turn with none pending -- a
   stale entry would take the next same-named call's result. *)
procedure TACPAgent.CloseOpenCalls(S: TACPSession);
var
  Open: TList;
  i: Integer;
  Slot: TACPCallSlot;
begin
  Open := TList.Create;
  try
    FLock.Enter;
    try
      for i := 0 to S.FPending.Count - 1 do Open.Add(S.FPending[i]);
      S.FPending.Clear;
    finally
      FLock.Leave;
    end;
    for i := 0 to Open.Count - 1 do
    begin
      Slot := TACPCallSlot(Open[i]);
      try
        SessionUpdate(S.Id, '{"sessionUpdate":"tool_call_update","toolCallId":' +
          Q(Slot.Id) + ',"status":"failed","content":[{"type":"content","content":' +
          TextBlock(CallNotFinishedText) + '}]}');
      finally
        Slot.Free;
      end;
    end;
  finally
    Open.Free;
  end;
end;

{ How a recorded result was shown live: a refusal from a gate as failed,
  anything else as completed. }
function ReplayResultStatus(const Content: string): string;
begin
  if Copy(Content, 1, Length(RefusedPrefix)) = RefusedPrefix then
    Result := 'failed'
  else
    Result := 'completed';
end;

procedure TACPAgent.ReplayHistory(S: TACPSession; const History: TMessageArray);
var
  i, j, k: Integer;
  M: TMessage;
  Id, Raw, Shown, Txt, Status, Title: string;
  Args: TJsonObject;
  Results: TStringList;   { tool call id -> its result's status }
begin
  (* Each call is announced with the status it ended with, so a client
     never shows a refused call as done first and failed after. Results
     come later in the history than their calls, so they are looked up
     first. *)
  Results := TStringList.Create;
  try
  for i := 0 to High(History) do
    if (History[i].Role = mrTool) and (History[i].ToolCallId <> '') then
      Results.Values[History[i].ToolCallId] := ReplayResultStatus(History[i].Content);
  for i := 0 to High(History) do
  begin
    M := History[i];
    case M.Role of
      mrUser:
        begin
          Txt := StripTurnClock(M.Content);
          if Trim(Txt) <> '' then
            SessionUpdate(S.Id, '{"sessionUpdate":"user_message_chunk","content":' +
                                TextBlock(Txt) + '}');
        end;
      mrAssistant:
        begin
          if Trim(M.Content) <> '' then
            SessionUpdate(S.Id, '{"sessionUpdate":"agent_message_chunk","content":' +
                                TextBlock(M.Content) + '}');
          for j := 0 to High(M.ToolCalls) do
          begin
            Id := M.ToolCalls[j].Id;
            if Id = '' then Id := NextCallId(S);
            Args := ParseArgsObj(M.ToolCalls[j].Func.Arguments);
            try
              Raw := RawInputOf(Args, M.ToolCalls[j].Func.Arguments);
              Title := ToolTitleOf(M.ToolCalls[j].Func.Name, Args);
            finally
              Args.Free;
            end;
            { No id to match (none recorded): completed, as before. A call
              with an id and no result never finished -- shown live as
              failed when its turn ended, so replayed the same way. }
            Status := 'completed';
            k := 0;
            if M.ToolCalls[j].Id <> '' then
            begin
              k := Results.IndexOfName(Id);
              if k >= 0 then Status := Results.ValueFromIndex[k]
              else Status := 'failed';
            end;
            SessionUpdate(S.Id, '{"sessionUpdate":"tool_call","toolCallId":' + Q(Id) +
              ',"title":' + Q(Title) +
              ',"name":' + Q(M.ToolCalls[j].Func.Name) +
              ',"kind":' + Q(ACPToolKind(M.ToolCalls[j].Func.Name)) +
              ',"status":' + Q(Status) + ',"rawInput":' + Raw + '}');
            if (M.ToolCalls[j].Id <> '') and (k < 0) then
              SessionUpdate(S.Id, '{"sessionUpdate":"tool_call_update","toolCallId":' +
                Q(Id) + ',"status":"failed","content":[{"type":"content","content":' +
                TextBlock(CallNotFinishedText) + '}]}');
          end;
        end;
      mrTool:
        if M.ToolCallId <> '' then
        begin
          Shown := M.Content;
          if Length(Shown) > ResultShowBytes then
            Shown := Utf8SafeTruncate(Shown, ResultShowBytes) + sLineBreak +
                     '[... shortened for display]';
          SessionUpdate(S.Id, '{"sessionUpdate":"tool_call_update","toolCallId":' +
            Q(M.ToolCallId) + ',"status":' + Q(ReplayResultStatus(M.Content)) +
            ',"content":[{"type":"content","content":' + TextBlock(Shown) + '}]}');
        end;
    end;
  end;
  finally
    Results.Free;
  end;
end;

procedure TACPAgent.DoPrompt(const IdRaw: string; Params: TJsonObject);
var
  S: TACPSession;
  Text, Id: string;
  T: TACPPromptThread;
  Busy: Boolean;
begin
  if Params = nil then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'params required');
    Exit;
  end;
  Id := Params.GetStr('sessionId', '');
  S := FindSession(Id);
  if S = nil then
  begin
    RespondError(IdRaw, ACPNotFound, 'no such session', '{"sessionId":' + Q(Id) + '}');
    Exit;
  end;
  Text := ACPPromptText(Params.ChildArray('prompt'));
  if Trim(Text) = '' then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'the prompt is empty');
    Exit;
  end;
  FLock.Enter;
  try
    Busy := S.FRunning;
    if not Busy then
    begin
      S.FRunning := True;
      S.FCancel := False;
      S.FTextSent := False;
    end;
  finally
    FLock.Leave;
  end;
  if Busy then
  begin
    RespondError(IdRaw, ACPInvalidRequest, 'a turn is already running on this session');
    Exit;
  end;
  ReapThreads(False);
  T := TACPPromptThread.Create(Self, S, IdRaw, Text);
  FLock.Enter;
  try
    FThreads.Add(T);
  finally
    FLock.Leave;
  end;
end;

procedure TACPAgent.DoSetMode(const IdRaw: string; Params: TJsonObject);
var
  S: TACPSession;
  ModeId: string;
  M: TPasClawMode;
begin
  if Params = nil then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'params required');
    Exit;
  end;
  S := FindSession(Params.GetStr('sessionId', ''));
  if S = nil then
  begin
    RespondError(IdRaw, ACPNotFound, 'no such session',
                 '{"sessionId":' + Q(Params.GetStr('sessionId', '')) + '}');
    Exit;
  end;
  ModeId := Params.GetStr('modeId', '');
  { Only the ids availableModes names -- ParseMode's aliases ("r" for
    research...) are a CLI convenience, not part of the contract. }
  if not ParseMode(ModeId, M) or (ModeName(M) <> ModeId) then
  begin
    RespondError(IdRaw, ACPInvalidParams, 'unknown mode: ' + ModeId);
    Exit;
  end;
  FLock.Enter;
  try
    S.Mode := M;   { takes effect from the next turn }
  finally
    FLock.Leave;
  end;
  Respond(IdRaw, '{}');
end;

procedure TACPAgent.DoCancel(Params: TJsonObject);
var
  S: TACPSession;
  i: Integer;
  P: TACPOutgoing;
begin
  if Params = nil then Exit;
  S := FindSession(Params.GetStr('sessionId', ''));
  if S = nil then Exit;
  FLock.Enter;
  try
    if S.FRunning then S.FCancel := True;
    { A permission request still open for this session will not be
      answered as anything but "cancelled"; do not wait for the client to
      say so. }
    for i := 0 to FOutgoing.Count - 1 do
    begin
      P := TACPOutgoing(FOutgoing[i]);
      if (P.SessionId = S.Id) and not P.Done then
      begin
        P.Done := True;
        P.Ok := True;
        P.ResultJSON := '{"outcome":{"outcome":"cancelled"}}';
        P.Event.SetEvent;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TACPAgent.Request(const SessionId, Method, ParamsJSON: string;
  out ResultJSON: string): Boolean;
var
  P: TACPOutgoing;
  Id: Int64;
  TimedOut: Boolean;
begin
  ResultJSON := '';
  FLock.Enter;
  try
    Inc(FNextId);
    Id := FNextId;
    P := TACPOutgoing.Create(Id, SessionId);
    FOutgoing.Add(P);
  finally
    FLock.Leave;
  end;
  Send('{"jsonrpc":"2.0","id":' + IntToStr(Id) + ',"method":' + Q(Method) +
       ',"params":' + ParamsJSON + '}');
  { Released by the answer, a cancel, the end of input -- or the limit. }
  P.Event.WaitFor(AskTimeoutMs);
  FLock.Enter;
  try
    TimedOut := not P.Done;   { an answer that raced the limit still counts }
    if TimedOut then P.Done := True;
    Result := (not TimedOut) and P.Ok;
    ResultJSON := P.ResultJSON;
    FOutgoing.Remove(P);
  finally
    FLock.Leave;
  end;
  P.Free;
  if TimedOut then
  begin
    LogWarn('acp: no answer to %s within %d s -- taken as no',
            [Method, AskTimeoutMs div 1000]);
    Send('{"jsonrpc":"2.0","method":"$/cancel_request","params":{"requestId":' +
         IntToStr(Id) + '}}');
  end;
end;

procedure TACPAgent.ReapThreads(WaitAll: Boolean);
var
  i: Integer;
  T: TACPPromptThread;
begin
  i := 0;
  while True do
  begin
    FLock.Enter;
    try
      if i >= FThreads.Count then Break;
      T := TACPPromptThread(FThreads[i]);
      if not (WaitAll or T.Finished) then
      begin
        Inc(i);
        Continue;
      end;
      FThreads.Delete(i);
    finally
      FLock.Leave;
    end;
    T.WaitFor;
    T.Free;
  end;
end;

procedure TACPAgent.Shutdown;
var
  i: Integer;
  S: TACPSession;
  P: TACPOutgoing;
begin
  FLock.Enter;
  try
    for i := 0 to FSessions.Count - 1 do
    begin
      S := TACPSession(FSessions.Objects[i]);
      if S.FRunning then S.FCancel := True;
    end;
    for i := 0 to FOutgoing.Count - 1 do
    begin
      P := TACPOutgoing(FOutgoing[i]);
      if not P.Done then
      begin
        P.Done := True;
        P.Ok := False;
        P.Event.SetEvent;
      end;
    end;
  finally
    FLock.Leave;
  end;
  ReapThreads(True);
  FLock.Enter;
  try
    for i := 0 to FSessions.Count - 1 do
      FHost.CloseSession(TACPSession(FSessions.Objects[i]));
    FSessions.Clear;
  finally
    FLock.Leave;
  end;
end;

end.
