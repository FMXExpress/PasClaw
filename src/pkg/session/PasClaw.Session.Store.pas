(*
  PasClaw.Session.Store -- durable conversation sessions.

  Today `pasclaw agent` keeps its message history in process memory; a
  Ctrl-C / `/quit` / crash drops the whole conversation. Openclaw's
  /new / /reset / resume commands and nanobot's durable sessions
  treat each conversation as a persistent object you can come back to.

  Storage layout: one JSON file per session under
  $PASCLAW_HOME/workspace/sessions/<id>.json. The JSON carries
  everything RunToolLoop needs to continue the conversation --
  message history (user / assistant / tool with their tool_call
  pairings preserved), the compacted SystemPrompt override that
  PasClaw.Agent.Compact emits, the last provider/model the
  conversation ran against, an embedder-visible title, and
  created/updated timestamps for listing.

  ID shape: timestamp-prefix + 8 random hex chars (e.g.
  "20260601T134215-a3f4c2e1"). Sorts chronologically; readable by
  humans; collision-safe enough for a personal-agent home directory.

  Usage from Cmd.Agent.RunInteractive:

      Session := TSession.Create(A.Session);   { '' → new id }
      if Session.MetaExists then
        Session.Load(Session.Meta.Id)
      else
        Session.Save;                          { commit metadata }
      ... feed Session.Messages to the loop ...
      Session.Messages := Loop.FinalMessages;
      Session.Meta.SystemPromptOverride := Loop.FinalSystemPrompt;
      Session.Touch;
      Session.Save;

  Other call sites (cmd session list / show / delete, the gateway's
  read-only /v1/sessions endpoint) use ListSessions / SessionPath /
  DeleteSession without instantiating the class.
*)
unit PasClaw.Session.Store;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.JSON;

type
  (* Per-session working-state snapshot. Tracked across turns so a
     resumed session (after Ctrl-C, after compaction, after a fresh
     `pasclaw agent --session <id>`) picks up with structured
     context the conversation transcript may have lost.

       EditedFiles  most recently touched paths via fs_write /
                    fs_edit_hashline (deduped, last MAX_EDITED
                    entries kept, newest first).
       LastShell    most recent shell_exec command string, capped
                    at WORKING_STATE_CMD_CAP chars.
       LastError    most recent tool-call error surfaced into the
                    transcript.
       Updated      unix-seconds timestamp of the last update so
                    operators can tell when the snapshot last
                    moved.

     Persisted under the 'working_state' object inside session
     JSON. Empty defaults: no fields emitted unless populated, so
     pre-existing session files round-trip without bloat. *)
  { Named alias so PushEditedFile (and any future caller that
    builds the array fresh) can assign back into the record's
    field without dcc64 raising E2008 "Incompatible types" on the
    anonymous `array of string` vs the field's anonymous type.
    Same pattern PasClaw uses elsewhere for TLLMProviderArray /
    TSubagentSpecArray / TStringArray. }
  TEditedFilesArray = array of string;

  TWorkingState = record
    EditedFiles: TEditedFilesArray;
    LastShell:   string;
    LastError:   string;
    Updated:     Int64;
  end;

  (* Persisted per-session usage counters. Populated turn-by-turn by
     the tool loop callers when Cfg.StatsCollectionEnabled is True,
     so /v1/stats can aggregate across sessions without re-parsing
     the message log every refresh.

     Flag-off path leaves every field at zero -- no on-disk diff
     versus the pre-feature schema, so old sessions and stats-off
     sessions round-trip identically.

     The fields chosen mirror what the TUI /stats overlay shows:
     usage tokens (in / out / cache_w / cache_r), iteration count,
     total tool calls, and OutputCache truncation savings. Per-tool
     call counts would be nice but require a string-keyed map in
     JSON which is more bookkeeping than it earns in v1 -- the
     aggregate ToolCalls is enough for "is the agent looping?". *)
  TSessionStats = record
    InputTokens:          Int64;
    OutputTokens:         Int64;
    CacheReadTokens:      Int64;
    CacheCreatedTokens:   Int64;
    Turns:                Int64;
    ToolCalls:            Int64;
    TruncationBytesSaved: Int64;
  end;

  TSessionMeta = record
    Id:                   string;     { 20260601T134215-a3f4c2e1 }
    CreatedAt:            Int64;      { unix seconds, UTC }
    UpdatedAt:            Int64;
    Title:                string;     { auto-derived from first user turn if empty }
    Model:                string;     { last model used }
    Provider:             string;     { last provider name }
    SystemPromptOverride: string;     { compacted system prompt across turns }
    WorkingState:         TWorkingState;
    Stats:                TSessionStats;
  end;
  TSessionMetaArray = array of TSessionMeta;

  TSession = class
  private
    FExists: Boolean;
  public
    Meta:     TSessionMeta;
    Messages: TMessageArray;
    { Create a session handle. When AId is empty, generates a new id
      and leaves FExists False -- caller decides whether to persist
      via Save. When AId is non-empty, attempts to load the file;
      MetaExists reflects whether the load found anything. }
    constructor Create(const AId: string = '');
    function MetaExists: Boolean;
    procedure Save;
    procedure Load(const AId: string);
    { Refresh UpdatedAt to now. Doesn't write -- caller decides when. }
    procedure Touch;
    { Empty Messages, keep Meta (id/title/etc.). Caller decides whether
      to persist. Doesn't reset SystemPromptOverride -- embedders that
      want a hard reset should set it to '' explicitly. }
    procedure ClearMessages;
    { Derive a title from the first mrUser message when Meta.Title is
      empty. Idempotent -- does nothing when Title is already set or
      Messages has no user turn. }
    procedure AutoTitle;
  end;

(* Parse a chat-style request body --
   {"messages":[{"role","content"},...], "title"?, "model"?} -- into a
   message array, with any title/model overrides returned via the out
   params. Roles map through MsgRoleFromString (user/assistant/tool/
   system). Returns an empty array when "messages" is absent or empty;
   raises EArgumentException on invalid JSON so the caller can map it to
   a 400. Used by the gateway's /v1/sessions writer (POST/PUT) and the
   web UI's session persistence; exposed here so it's unit-testable
   without binding an HTTP listener. *)
function ChatBodyToMessages(const Body: string;
                            out Title, Model: string): TMessageArray;

(* True when a transcript carries structure beyond plain user/assistant
   text -- system or tool turns, or assistant turns with tool_calls (ids,
   provider signatures). Such a session was produced by the agent loop /
   TUI; a surface that only models user/assistant turns (the web UI)
   must not overwrite it from its flattened view, or terminal resume for
   tool-using conversations breaks. Exposed so the gateway's /v1/sessions
   PUT can refuse (409) and the web UI fork instead. *)
function SessionHasRichTurns(const Msgs: TMessageArray): Boolean;

function NewSessionId: string;
{ True when Id is a safe filename component for a session file -- see
  IsSafeSessionId in the implementation for the exact rules. Exposed
  so CLI callers (cmd/session, cmd/agent) can surface a clear error
  before invoking Save/Load/Delete with a hostile id. }
function IsSafeSessionId(const Id: string): Boolean;
function SessionsDir: string;
{ Returns '' when Id fails IsSafeSessionId, otherwise the absolute
  path of the session file. Callers MUST handle the empty-string
  case (treat as "no session named X"). }
function SessionPath(const Id: string): string;

(* List on-disk sessions. By default skips synthetic "gateway
   bucket" sessions (ids prefixed with `_gateway_`) -- those exist
   only to aggregate stateless gateway-endpoint stats and would
   otherwise clutter the TUI session pane, `pasclaw session list`,
   and `pasclaw learn`'s pattern miner with empty pseudo-sessions
   the operator never created. Callers that DO want them (the
   gateway's /v1/stats aggregator) pass IncludeBuckets=True. *)
function ListSessions(IncludeBuckets: Boolean = False): TSessionMetaArray;

(* Predicate: True iff Id matches the gateway's bucket-session
   naming convention. Centralised here so the TUI / Cmd.Session
   list filtering, the /v1/stats aggregator (which opts back in),
   and any future consumer share one rule. The current rule is
   "starts with `_gateway_`"; tightening this is a one-liner if
   we ever need other prefixed-id session conventions. *)
function IsGatewayBucketSessionId(const Id: string): Boolean;

function DeleteSession(const Id: string): Boolean;

(* Sort a TSessionMetaArray in place, newest-first by UpdatedAt with
   CreatedAt and Id as deterministic tiebreakers. Exposed for tests
   that pin the ordering; ListSessions calls this internally so
   every surface that reads session metadata (TUI session pane,
   `pasclaw session list`) sees freshest-at-top. *)
procedure SortSessionsNewestFirst(var Sessions: TSessionMetaArray);

(* Exposed for tests: TToolCall <-> JSON conversion used by TSession.
   Round-trip preserves Id, Kind, Func.Name, Func.Arguments, and
   (when non-empty) Gemini 3+'s ProviderSignature. *)
function ToolCallToJSON(const TC: TToolCall): TJsonObject;
procedure ToolCallFromJSON(const Obj: TJsonObject; out TC: TToolCall);

(* Walks a turn's final message history and refreshes Meta.WorkingState
   from fs_write/fs_edit_hashline paths (EditedFiles), shell_exec
   commands (LastShell), and tool errors ('ERROR:' prefix in tool
   results, LastError). Idempotent: re-running with the same Hist
   yields the same state. Callers invoke this after a successful
   tool loop -- TUI from ApplyLoopResultTo, Cmd.Agent from
   PersistSession's nearest equivalent -- so a /quit-then-resume
   sees structured context the transcript may have lost. *)
procedure UpdateWorkingStateAfterTurn(var Meta: TSessionMeta;
                                      const Hist: TMessageArray);

(* Format the working state as a system-prompt prefix block the
   next turn can prepend so the model picks up where it left off.
   Returns '' when no fields are populated -- callers concat
   unconditionally and rely on the empty-string short-circuit. *)
function FormatWorkingStateBlock(const Meta: TSessionMeta): string;

(* Accumulate a turn's usage / tool-call / truncation deltas into the
   session's persistent stats. Caller checks Cfg.StatsCollectionEnabled
   before invoking -- this helper assumes the flag is on and just
   does the arithmetic. Turns is incremented by 1; everything else
   is added as-is. *)
procedure AccumulateTurnStats(var Meta: TSessionMeta;
                              InputTokens, OutputTokens,
                              CacheReadTokens, CacheCreatedTokens: Int64;
                              ToolCallsDelta, TruncationBytesDelta: Int64);

implementation

uses
  DateUtils,
  {$IFDEF MSWINDOWS}
  { Lets dcc64 inline SysUtils.RenameFile (used by Save's atomic
    write) -- without this it falls back to a regular call and emits
    H2443. Mirrors the pattern used in PasClaw.CliUI / PasClaw.Crypto.Random. }
  {$IFDEF FPC}Windows,{$ELSE}Winapi.Windows,{$ENDIF}
  {$ENDIF}
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger;

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

function ChatBodyToMessages(const Body: string;
                            out Title, Model: string): TMessageArray;
var
  Req, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  B, Role, Content: string;
begin
  SetLength(Result, 0);
  Title := '';
  Model := '';
  B := Trim(Body);
  if B = '' then B := '{}';
  { TJsonObject.Parse raises (EPasClawJSON) on malformed input and can
    also return nil; normalise both into EArgumentException so the
    gateway handler maps a bad body to 400 instead of leaking a 500. }
  try
    Req := TJsonObject.Parse(B);
  except
    on E: Exception do
      raise EArgumentException.Create('invalid json body: ' + E.Message);
  end;
  if Req = nil then
    raise EArgumentException.Create('invalid json body');
  try
    Title := Req.GetStr('title', '');
    Model := Req.GetStr('model', '');
    Arr := Req.ChildArray('messages');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        MsgObj := Arr.ItemObject(i);     { detached copy -- free per item }
        if MsgObj = nil then Continue;
        try
          Role    := MsgObj.GetStr('role',    'user');
          Content := MsgObj.GetStr('content', '');
        finally
          MsgObj.Free;
        end;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := MakeMessage(MsgRoleFromString(Role), Content);
      end;
    finally
      Arr.Free;
    end;
  finally
    Req.Free;
  end;
end;

function SessionHasRichTurns(const Msgs: TMessageArray): Boolean;
var
  i: Integer;
begin
  Result := True;
  for i := 0 to High(Msgs) do
    if (Msgs[i].Role = mrSystem) or (Msgs[i].Role = mrTool) or
       ((Msgs[i].Role = mrAssistant) and (Length(Msgs[i].ToolCalls) > 0)) then
      Exit;
  Result := False;
end;

function NewSessionId: string;
var
  Stamp: string;
  Rand: string;
  i: Integer;
begin
  Stamp := FormatDateTime('yyyymmdd"T"hhnnss', Now);
  Rand := '';
  for i := 1 to 8 do
    Rand := Rand + IntToHex(Random(16), 1);
  Result := Stamp + '-' + LowerCase(Rand);
end;

{ A session id becomes a filename under workspace/sessions/, so we
  refuse anything that could escape the directory (`..`, `/`, `\`,
  NULs, leading `.`) or surprise the FS (overlong names). Allowed
  charset is the superset of NewSessionId's output plus the things a
  human is likely to want for hand-picked ids (`-`, `_`, `.` mid-name)
  -- Codex P1 on PR #117. Keep this strict; widening the charset
  later is easy, narrowing it after files exist on disk is not. }
function IsSafeSessionId(const Id: string): Boolean;
var
  i: Integer;
  C: Char;
begin
  Result := False;
  if Id = '' then Exit;
  if Length(Id) > 128 then Exit;
  if (Id = '.') or (Id = '..') then Exit;
  if Id[1] = '.' then Exit;
  for i := 1 to Length(Id) do
  begin
    C := Id[i];
    if not (((C >= 'a') and (C <= 'z'))
         or ((C >= 'A') and (C <= 'Z'))
         or ((C >= '0') and (C <= '9'))
         or (C = '-') or (C = '_') or (C = '.')) then
      Exit;
  end;
  Result := True;
end;

function SessionsDir: string;
begin
  Result := JoinPath(GetHome, 'workspace/sessions');
end;

function SessionPath(const Id: string): string;
begin
  if not IsSafeSessionId(Id) then Exit('');
  Result := JoinPath(SessionsDir, Id + '.json');
end;

procedure EnsureSessionsDir;
begin
  if not DirectoryExists(SessionsDir) then
    ForceDirectories(SessionsDir);
end;

function ToolCallToJSON(const TC: TToolCall): TJsonObject;
var
  Func: TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',   TC.Id);
  Result.PutStr('type', TC.Kind);
  Func := TJsonObject.Create;
  Func.PutStr('name',      TC.Func.Name);
  Func.PutStr('arguments', TC.Func.Arguments);
  Result.PutObject('function', Func);
  { Persist Gemini 3+'s thoughtSignature so a session saved mid-loop
    survives /quit + resume. Without this the resumed assistant turn
    drops the signature and Gemini's next request 400s with
    "Function call is missing a thought_signature". Omitted from
    JSON when empty -- that's the common case (other providers / older
    Gemini) and keeps stock session files tidy. Codex P2 on PR #154. }
  if TC.ProviderSignature <> '' then
    Result.PutStr('provider_signature', TC.ProviderSignature);
end;

procedure ToolCallFromJSON(const Obj: TJsonObject; out TC: TToolCall);
var
  Func: TJsonObject;
begin
  TC.Id   := Obj.GetStr('id',   '');
  TC.Kind := Obj.GetStr('type', 'function');
  TC.ProviderSignature := Obj.GetStr('provider_signature', '');
  TC.Func.Name      := '';
  TC.Func.Arguments := '';
  Func := Obj.ChildObject('function');
  if Func <> nil then
  try
    TC.Func.Name      := Func.GetStr('name',      '');
    TC.Func.Arguments := Func.GetStr('arguments', '');
  finally
    Func.Free;
  end;
end;

function MessageToJSON(const M: TMessage): TJsonObject;
var
  Arr: TJsonArray;
  TCO: TJsonObject;
  i: Integer;
begin
  Result := TJsonObject.Create;
  Result.PutStr('role',    MsgRoleToString(M.Role));
  Result.PutStr('content', M.Content);
  if M.Name <> ''       then Result.PutStr('name',         M.Name);
  if M.ToolCallId <> '' then Result.PutStr('tool_call_id', M.ToolCallId);
  if Length(M.ToolCalls) > 0 then
  begin
    Arr := TJsonArray.Create;
    for i := 0 to High(M.ToolCalls) do
    begin
      TCO := ToolCallToJSON(M.ToolCalls[i]);
      Arr.AddObject(TCO);
    end;
    Result.PutArray('tool_calls', Arr);
  end;
end;

procedure MessageFromJSON(const Obj: TJsonObject; out M: TMessage);
var
  Arr: TJsonArray;
  TCO: TJsonObject;
  i: Integer;
begin
  M.Role       := MsgRoleFromString(Obj.GetStr('role', 'user'));
  M.Content    := Obj.GetStr('content',      '');
  M.Name       := Obj.GetStr('name',         '');
  M.ToolCallId := Obj.GetStr('tool_call_id', '');
  SetLength(M.ToolCalls, 0);
  Arr := Obj.ChildArray('tool_calls');
  if Arr <> nil then
  try
    SetLength(M.ToolCalls, Arr.Count);
    for i := 0 to Arr.Count - 1 do
    begin
      TCO := Arr.ItemObject(i);
      if TCO = nil then Continue;
      try
        ToolCallFromJSON(TCO, M.ToolCalls[i]);
      finally
        TCO.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

constructor TSession.Create(const AId: string);
begin
  inherited Create;
  if AId = '' then
  begin
    Meta.Id        := NewSessionId;
    Meta.CreatedAt := NowUnix;
    Meta.UpdatedAt := Meta.CreatedAt;
    FExists := False;
    SetLength(Messages, 0);
  end
  else
    Load(AId);
end;

function TSession.MetaExists: Boolean;
begin
  Result := FExists;
end;

const
  WORKING_STATE_MAX_EDITED = 8;       { ring-buffer cap for EditedFiles }
  WORKING_STATE_CMD_CAP    = 200;     { LastShell truncation }

procedure WriteWorkingStateJSON(MetaObj: TJsonObject;
                                const W: TWorkingState);
{ Serialize Meta.WorkingState into a nested object on MetaObj. No
  object is added when every field is empty so a pre-feature
  session file's JSON shape stays untouched after a no-op save. }
var
  Obj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  if (Length(W.EditedFiles) = 0) and
     (W.LastShell = '') and
     (W.LastError = '') and
     (W.Updated = 0) then
    Exit;
  Obj := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    try
      for i := 0 to High(W.EditedFiles) do Arr.AddStr(W.EditedFiles[i]);
      Obj.PutArray('edited_files', Arr);
    except
      Arr.Free; raise;
    end;
    Obj.PutStr('last_shell', W.LastShell);
    Obj.PutStr('last_error', W.LastError);
    Obj.PutInt('updated_at', W.Updated);
    MetaObj.PutObject('working_state', Obj);
  except
    Obj.Free; raise;
  end;
end;

procedure ReadWorkingStateJSON(MetaObj: TJsonObject;
                               var W: TWorkingState);
var
  Obj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  W := Default(TWorkingState);
  Obj := MetaObj.ChildObject('working_state');
  if Obj = nil then Exit;
  try
    Arr := Obj.ChildArray('edited_files');
    if Arr <> nil then
    try
      SetLength(W.EditedFiles, Arr.Count);
      for i := 0 to Arr.Count - 1 do
        W.EditedFiles[i] := Arr.ItemStr(i, '');
    finally
      Arr.Free;
    end;
    W.LastShell := Obj.GetStr('last_shell', '');
    W.LastError := Obj.GetStr('last_error', '');
    W.Updated   := Obj.GetInt('updated_at',  0);
  finally
    Obj.Free;
  end;
end;

procedure WriteSessionStatsJSON(MetaObj: TJsonObject;
                                const S: TSessionStats);
{ Persist the stats record into the session meta JSON. Skips the
  block entirely when every counter is zero so a stats-off session
  produces byte-identical output to the pre-feature schema -- no
  diff to review, no migration concern. }
var
  Obj: TJsonObject;
begin
  if (S.InputTokens = 0) and (S.OutputTokens = 0) and
     (S.CacheReadTokens = 0) and (S.CacheCreatedTokens = 0) and
     (S.Turns = 0) and (S.ToolCalls = 0) and
     (S.TruncationBytesSaved = 0) then
    Exit;
  Obj := TJsonObject.Create;
  try
    Obj.PutInt('input_tokens',           S.InputTokens);
    Obj.PutInt('output_tokens',          S.OutputTokens);
    Obj.PutInt('cache_read_tokens',      S.CacheReadTokens);
    Obj.PutInt('cache_created_tokens',   S.CacheCreatedTokens);
    Obj.PutInt('turns',                  S.Turns);
    Obj.PutInt('tool_calls',             S.ToolCalls);
    Obj.PutInt('truncation_bytes_saved', S.TruncationBytesSaved);
    MetaObj.PutObject('stats', Obj);
  except
    Obj.Free; raise;
  end;
end;

procedure ReadSessionStatsJSON(MetaObj: TJsonObject; var S: TSessionStats);
var
  Obj: TJsonObject;
begin
  S := Default(TSessionStats);
  Obj := MetaObj.ChildObject('stats');
  if Obj = nil then Exit;
  try
    S.InputTokens          := Obj.GetInt('input_tokens',           0);
    S.OutputTokens         := Obj.GetInt('output_tokens',          0);
    S.CacheReadTokens      := Obj.GetInt('cache_read_tokens',      0);
    S.CacheCreatedTokens   := Obj.GetInt('cache_created_tokens',   0);
    S.Turns                := Obj.GetInt('turns',                  0);
    S.ToolCalls            := Obj.GetInt('tool_calls',             0);
    S.TruncationBytesSaved := Obj.GetInt('truncation_bytes_saved', 0);
  finally
    Obj.Free;
  end;
end;

function ParseFsArg(const ArgsJSON, Field: string): string;
{ Extract a string argument from a tool call's JSON args. Used to
  pull `path` out of fs_write / fs_edit_hashline calls and
  `command` (or fall back to a snippet of the full JSON) out of
  shell_exec. Returns '' on parse failure -- caller treats that
  as "skip this call" rather than crashing the loop. }
var
  Obj: TJsonObject;
begin
  Result := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    try
      Obj := TJsonObject.Parse(ArgsJSON);
    except
      Exit;
    end;
    if Obj = nil then Exit;
    try
      Result := Obj.GetStr(Field, '');
    finally
      Obj.Free;
    end;
  except
    Result := '';
  end;
end;

procedure PushEditedFile(var W: TWorkingState; const Path: string);
{ Move-to-front a path: dedupe by exact match, drop the oldest if
  we'd exceed WORKING_STATE_MAX_EDITED. Keeps the array newest-
  first so the formatted block reads chronologically backward. }
var
  i: Integer;
  Tmp: TEditedFilesArray;     { named-type alias so the W.EditedFiles
                                assignment below doesn't trip dcc64's
                                strict-array E2008. }
begin
  if Path = '' then Exit;
  SetLength(Tmp, 1);
  Tmp[0] := Path;
  for i := 0 to High(W.EditedFiles) do
    if W.EditedFiles[i] <> Path then
    begin
      SetLength(Tmp, Length(Tmp) + 1);
      Tmp[High(Tmp)] := W.EditedFiles[i];
      if Length(Tmp) >= WORKING_STATE_MAX_EDITED then Break;
    end;
  W.EditedFiles := Tmp;
end;

procedure UpdateWorkingStateAfterTurn(var Meta: TSessionMeta;
                                      const Hist: TMessageArray);
var
  i, k: Integer;
  Call: TToolCall;
  Path, Cmd, Body: string;
  Changed: Boolean;
begin
  Changed := False;

  { Pass 1: assistant turns drive EditedFiles / LastShell from
    tool_calls. fs_write + fs_edit_hashline both carry a `path`
    arg; shell_exec carries `command`. Anything else is ignored
    for working-state purposes -- the model is free to call them
    without polluting the cross-turn snapshot. }
  for i := 0 to High(Hist) do
  begin
    if Hist[i].Role <> mrAssistant then Continue;
    for k := 0 to High(Hist[i].ToolCalls) do
    begin
      Call := Hist[i].ToolCalls[k];
      if (Call.Func.Name = 'write_file') or
         (Call.Func.Name = 'append_file') or
         (Call.Func.Name = 'edit_file') or
         (Call.Func.Name = 'fs_write') or          { back-compat aliases }
         (Call.Func.Name = 'fs_edit_hashline') then
      begin
        Path := ParseFsArg(Call.Func.Arguments, 'path');
        if Path <> '' then
        begin
          PushEditedFile(Meta.WorkingState, Path);
          Changed := True;
        end;
      end
      else if Call.Func.Name = 'shell_exec' then
      begin
        Cmd := ParseFsArg(Call.Func.Arguments, 'command');
        if Cmd <> '' then
        begin
          if Length(Cmd) > WORKING_STATE_CMD_CAP then
            Cmd := Copy(Cmd, 1, WORKING_STATE_CMD_CAP) + '...';
          Meta.WorkingState.LastShell := Cmd;
          Changed := True;
        end;
      end;
    end;
  end;

  { Pass 2: tool messages prefixed with 'ERROR:' carry the most
    recent tool-side failure. The transcript usually shows them
    inline but a compaction pass may drop them; LastError keeps
    the most recent one visible to the resumed turn. }
  for i := 0 to High(Hist) do
  begin
    if Hist[i].Role <> mrTool then Continue;
    Body := Hist[i].Content;
    if (Length(Body) >= 6) and (Copy(Body, 1, 6) = 'ERROR:') then
    begin
      Meta.WorkingState.LastError := Trim(Copy(Body, 7, MaxInt));
      Changed := True;
    end;
  end;

  if Changed then Meta.WorkingState.Updated := NowUnix;
end;

procedure AccumulateTurnStats(var Meta: TSessionMeta;
                              InputTokens, OutputTokens,
                              CacheReadTokens, CacheCreatedTokens: Int64;
                              ToolCallsDelta, TruncationBytesDelta: Int64);
begin
  Inc(Meta.Stats.InputTokens,          InputTokens);
  Inc(Meta.Stats.OutputTokens,         OutputTokens);
  Inc(Meta.Stats.CacheReadTokens,      CacheReadTokens);
  Inc(Meta.Stats.CacheCreatedTokens,   CacheCreatedTokens);
  Inc(Meta.Stats.Turns,                1);
  Inc(Meta.Stats.ToolCalls,            ToolCallsDelta);
  Inc(Meta.Stats.TruncationBytesSaved, TruncationBytesDelta);
end;

function FormatWorkingStateBlock(const Meta: TSessionMeta): string;
var
  i: Integer;
  Edited, Sep: string;
begin
  Result := '';
  if (Length(Meta.WorkingState.EditedFiles) = 0) and
     (Meta.WorkingState.LastShell = '') and
     (Meta.WorkingState.LastError = '') then
    Exit;

  Result := '## Working state from prior turns' + sLineBreak;

  if Length(Meta.WorkingState.EditedFiles) > 0 then
  begin
    Edited := '';
    for i := 0 to High(Meta.WorkingState.EditedFiles) do
    begin
      if Edited = '' then Sep := '' else Sep := ', ';
      Edited := Edited + Sep + Meta.WorkingState.EditedFiles[i];
    end;
    Result := Result + 'Recently edited: ' + Edited + sLineBreak;
  end;
  if Meta.WorkingState.LastShell <> '' then
    Result := Result + 'Last shell: ' + Meta.WorkingState.LastShell + sLineBreak;
  if Meta.WorkingState.LastError <> '' then
    Result := Result + 'Last tool error: ' + Meta.WorkingState.LastError + sLineBreak;
end;

procedure TSession.Save;
var
  Root, MetaObj, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  S: TStringList;
  Path, TmpPath: string;
begin
  Path := SessionPath(Meta.Id);
  if Path = '' then
    raise EArgumentException.CreateFmt('Session.Save: unsafe id %s', [Meta.Id]);
  EnsureSessionsDir;
  Root := TJsonObject.Create;
  try
    MetaObj := TJsonObject.Create;
    MetaObj.PutStr('id',                     Meta.Id);
    MetaObj.PutInt('created_at',             Meta.CreatedAt);
    MetaObj.PutInt('updated_at',             Meta.UpdatedAt);
    MetaObj.PutStr('title',                  Meta.Title);
    MetaObj.PutStr('model',                  Meta.Model);
    MetaObj.PutStr('provider',               Meta.Provider);
    MetaObj.PutStr('system_prompt_override', Meta.SystemPromptOverride);
    WriteWorkingStateJSON(MetaObj, Meta.WorkingState);
    WriteSessionStatsJSON(MetaObj, Meta.Stats);
    Root.PutObject('meta', MetaObj);

    Arr := TJsonArray.Create;
    for i := 0 to High(Messages) do
    begin
      MsgObj := MessageToJSON(Messages[i]);
      Arr.AddObject(MsgObj);   { takes ownership; sets MsgObj := nil }
    end;
    Root.PutArray('messages', Arr);

    { Atomic write: tmp file + rename. A crash partway through
      SaveToFile would otherwise leave a half-written JSON that Load
      can't parse, defeating the "your conversation survives Ctrl-C"
      promise. POSIX rename(2) is atomic and overwrites; Windows
      MoveFile requires the destination not exist -- delete first.
      Codex P2 on PR #117. }
    TmpPath := Path + '.tmp';
    S := TStringList.Create;
    try
      S.Text := Root.ToJSON;
      S.SaveToFile(TmpPath);
    finally
      S.Free;
    end;
    {$IFDEF MSWINDOWS}
    if FileExists(Path) then SysUtils.DeleteFile(Path);
    {$ENDIF}
    if not RenameFile(TmpPath, Path) then
    begin
      SysUtils.DeleteFile(TmpPath);
      raise Exception.CreateFmt('Session.Save: rename %s -> %s failed', [TmpPath, Path]);
    end;
    FExists := True;
  finally
    Root.Free;
  end;
end;

procedure TSession.Load(const AId: string);
var
  Path: string;
  S: TStringList;
  Root, MetaObj, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  FExists := False;
  SetLength(Messages, 0);
  Meta := Default(TSessionMeta);
  Meta.Id := AId;
  Path := SessionPath(AId);
  if Path = '' then Exit;          { unsafe id -- treat as not found }
  if not FileExists(Path) then Exit;

  S := TStringList.Create;
  try
    S.LoadFromFile(Path);
    Root := TJsonObject.Parse(S.Text);
    if Root = nil then Exit;
    try
      MetaObj := Root.ChildObject('meta');
      if MetaObj <> nil then
      try
        Meta.Id                   := MetaObj.GetStr('id',                     AId);
        Meta.CreatedAt            := MetaObj.GetInt('created_at',             0);
        Meta.UpdatedAt            := MetaObj.GetInt('updated_at',             0);
        Meta.Title                := MetaObj.GetStr('title',                  '');
        Meta.Model                := MetaObj.GetStr('model',                  '');
        Meta.Provider             := MetaObj.GetStr('provider',               '');
        Meta.SystemPromptOverride := MetaObj.GetStr('system_prompt_override', '');
        ReadWorkingStateJSON(MetaObj, Meta.WorkingState);
        ReadSessionStatsJSON (MetaObj, Meta.Stats);
      finally
        MetaObj.Free;
      end;
      Arr := Root.ChildArray('messages');
      if Arr <> nil then
      try
        SetLength(Messages, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          MsgObj := Arr.ItemObject(i);
          if MsgObj = nil then Continue;
          try
            MessageFromJSON(MsgObj, Messages[i]);
          finally
            MsgObj.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
      FExists := True;
    finally
      Root.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TSession.Touch;
begin
  Meta.UpdatedAt := NowUnix;
end;

procedure TSession.ClearMessages;
begin
  SetLength(Messages, 0);
end;

procedure TSession.AutoTitle;
var
  i: Integer;
  Line: string;
const
  MaxTitleLen = 72;
begin
  if Trim(Meta.Title) <> '' then Exit;
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrUser then
    begin
      Line := Trim(Messages[i].Content);
      if Length(Line) > MaxTitleLen then
        Line := Copy(Line, 1, MaxTitleLen - 1) + '…';
      Meta.Title := Line;
      Exit;
    end;
end;

procedure SortSessionsNewestFirst(var Sessions: TSessionMetaArray);
{ Insertion sort, in-place, newest-first by UpdatedAt with
  CreatedAt and Id as secondary keys for stable tie-breaking.
  Insertion sort over an N-of-dozens array is plenty fast and
  keeps the implementation self-contained (no Generics.Defaults). }
var
  i, j: Integer;
  Pivot: TSessionMeta;

  function NewerThan(const A, B: TSessionMeta): Boolean;
  begin
    if A.UpdatedAt <> B.UpdatedAt then Exit(A.UpdatedAt > B.UpdatedAt);
    if A.CreatedAt <> B.CreatedAt then Exit(A.CreatedAt > B.CreatedAt);
    Result := A.Id > B.Id;
  end;

begin
  for i := 1 to High(Sessions) do
  begin
    Pivot := Sessions[i];
    j := i - 1;
    while (j >= 0) and NewerThan(Pivot, Sessions[j]) do
    begin
      Sessions[j + 1] := Sessions[j];
      Dec(j);
    end;
    Sessions[j + 1] := Pivot;
  end;
end;

function IsGatewayBucketSessionId(const Id: string): Boolean;
const
  Prefix = '_gateway_';
begin
  Result := (Length(Id) > Length(Prefix)) and
            (Copy(Id, 1, Length(Prefix)) = Prefix);
end;

function ListSessions(IncludeBuckets: Boolean = False): TSessionMetaArray;
var
  SR: TSearchRec;
  Pattern, Id: string;
  TmpSess: TSession;
begin
  SetLength(Result, 0);
  Pattern := JoinPath(SessionsDir, '*.json');
  if FindFirst(Pattern, faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Id := ChangeFileExt(SR.Name, '');
      { Skip stray files (.tmp leftovers from a crashed Save, or
        anything a human dropped in here) -- only ids that round-trip
        through IsSafeSessionId are real sessions. }
      if not IsSafeSessionId(Id) then Continue;
      { Hide gateway bucket sessions from the TUI session pane and
        the `pasclaw session list` / `pasclaw learn` paths -- they
        are stats-only synthetic sessions, never carry messages,
        and would otherwise pollute the operator's session view
        with one entry per stateless gateway endpoint. The /v1/
        stats aggregator opts back in via IncludeBuckets=True. }
      if (not IncludeBuckets) and IsGatewayBucketSessionId(Id) then Continue;
      { Load only the meta; this is wasteful but the sessions tree is
        typically small (10s to low 100s) and ListSessions runs from
        an interactive command. If it grows: write a "headers only"
        Load. }
      TmpSess := TSession.Create(Id);
      try
        if TmpSess.MetaExists then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := TmpSess.Meta;
        end;
      finally
        TmpSess.Free;
      end;
    until FindNext(SR) <> 0;
  finally
    { Fully-qualified to disambiguate from Winapi.Windows.FindClose
      (which takes a Handle, not a TSearchRec) -- the impl uses now
      pulls Winapi.Windows in for the RenameFile inline expansion,
      and Delphi's name lookup picks the last-in-uses wins. }
    SysUtils.FindClose(SR);
  end;

  { Sort newest-first by UpdatedAt so the TUI session pane and the
    CLI `pasclaw session list` both surface the freshest session at
    the top -- which is almost always the one the operator wants to
    resume. Insertion sort: the list is small (10s to low 100s of
    sessions in practice) so the O(N^2) cost is irrelevant. Ties on
    UpdatedAt fall back to CreatedAt, then Id, so the order is
    deterministic even for sessions created and saved in the same
    second (e.g., the cron-side mass-spawn case). }
  SortSessionsNewestFirst(Result);
end;

function DeleteSession(const Id: string): Boolean;
var
  Path: string;
begin
  Result := False;
  Path := SessionPath(Id);
  if Path = '' then Exit;                 { unsafe id }
  if not FileExists(Path) then Exit;
  { SysUtils.DeleteFile takes a string; Winapi.Windows.DeleteFile
    takes a PWideChar. Same shadowing as FindClose above. }
  Result := SysUtils.DeleteFile(Path);
  if Result then
    LogInfo('session %s deleted', [Id]);
end;

initialization
  Randomize;

end.
