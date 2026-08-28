(*
  PasClaw.Agents - durable, addressable agents, and the mailbox they
  reach each other through.

  The problem this solves
  =======================

  Subagents (PasClaw.Agent.Subagent / .SubagentBg) are a CALL: the
  parent spawns a specialist, the specialist answers, it is gone. That
  is right for "ask the researcher and use the answer in this turn" and
  wrong for a standing organisation -- a lead that exists tomorrow, a
  project lead you can message on Thursday about what it did on Monday.
  Background jobs make it explicit: they "live and die with the
  session", and the child registry deliberately withholds `spawn` so
  they cannot delegate onward.

  An agent here is the other shape: a NAME, a role, and a session that
  outlives the process. It is not a thread -- it is a manifest on disk
  plus a conversation on disk, so `pasclaw` can restart underneath it
  and the agent is still there, still knowing what it was doing.

    workspace/agents/<name>/agent.json      the manifest
    workspace/agents/<name>/messages.jsonl  what it was told, append-only
    sessions/agent-<name>.json              its conversation (ordinary session)

  Deliberately three files, not one store: the session is a REAL
  session, so `pasclaw resume`, the Library window, session export and
  the append-only transcript record all work on an agent with no
  special-casing anywhere.

  Addressing and delivery
  =======================

  AgentSend is the whole point of Phase 2. Two paths, one call:

    the target is mid-turn  -> the message lands in its STEERING queue
                               and it sees it between tool iterations,
                               without waiting for the turn to end
    the target is idle      -> the same queue holds it, and the next
                               turn drains it as its first input

  That is one mechanism because steering already IS a durable
  append-only queue with a directory mutex and stale-lock recovery
  (PasClaw.Agent.Steering) -- writing a second one would be writing the
  same file format with fewer tests behind it. What differs between the
  two cases is only what we can HONESTLY tell the sender, which is why
  AgentSend reports which happened rather than saying "sent" both times.

  Liveness is read from the session's own turn lock: held means a turn
  is running. TryEnter/Leave rather than a flag, because the lock is
  already the truth -- a flag would be a second copy of it that can
  disagree.

  messages.jsonl is the accountability half. The steering queue is
  CONSUMED on drain, so without a record "who told whom what" survives
  only inside whichever transcript happened to fold it in. A standing
  organisation needs to be able to answer that question later, so every
  send is appended here before it is delivered -- and the append is what
  is checked, since a message we failed to record but did deliver is
  worse than one we recorded and failed to deliver.
*)
unit PasClaw.Agents;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  { PasClaw.Utils for TStringArray, which SetAgentsPaused returns.
    In the INTERFACE, and it has to be: FPC's own SysUtils declares a
    TStringArray, so an interface that named the type without saying
    where it came from compiled here and failed under dcc64, which has
    no such type. PasClaw.Utils is the one place the tree defines it --
    aliasing the RTL type on FPC, declaring it on Delphi -- so naming
    it is what makes the two compilers agree. Utils is bottom-level;
    there is no cycle to worry about. }
  SysUtils, Classes, SyncObjs,
  PasClaw.Utils;

type
  TAgentInfo = record
    Name:    string;   { the slug -- also the directory name }
    Title:   string;   { human label, e.g. "Payments tech lead" }
    Role:    string;   { free text folded into its system prompt }
    Model:   string;   { '' = inherit whatever the runner is using }
    Parent:  string;   { the agent it reports to; '' = top level }
    Created: string;
    Updated: string;
    Exists:  Boolean;
    (* Run state. Written by the runner, read by everyone else --
       including the supervisor, which is the only reason it is on disk
       rather than in memory: a process that died mid-run must leave
       behind the fact that it was running, or nothing can tell the
       difference between "working" and "gone". *)
    RunState: string;  { 'idle' | 'running' | 'done' | 'failed' }
    RunStart: string;  { ISO-8601 UTC, when the current/last run began }
    RunEnd:   string;  { '' while running }
    RunNote:  string;  { the last reply's opening, or the error }
  end;
  TAgentInfoArray = array of TAgentInfo;

  (* One line of messages.jsonl. From is an agent name, or a free label
     for anything that is not an agent ('operator', 'cron', ...) -- the
     record should say who spoke even when it was not one of us. *)
  TAgentMessage = record
    At:       string;   { ISO-8601 UTC }
    From:     string;
    Text:     string;
    Delivered: string;  { 'mid-turn' | 'queued' | 'failed' }
  end;
  TAgentMessageArray = array of TAgentMessage;

{ Where agents live. Created on demand. }
function AgentsDir: string;

{ The session an agent's conversation lives in: 'agent-<name>'. A real
  session id, so every session-shaped tool in the tree works on it. }
function AgentSessionId(const Name: string): string;

{ Slug rules match projects: lowercase, [a-z0-9-], bounded, never a
  traversal. '' when nothing usable survives. }
function AgentSlug(const S: string): string;

function ListAgents: TAgentInfoArray;
function GetAgent(const Name: string; out Info: TAgentInfo): Boolean;

(* Create or update. Name may be a title -- it is slugged. Creating is
   idempotent on the slug (the manifest is rewritten), which is the same
   contract CreateProject has and for the same reason: an agent
   re-running its own setup step must not fail the job.

   Returns the slug written, or '' with Err set. *)
function SaveAgent(const Info: TAgentInfo; out Err: string): string;

{ Remove the manifest and the message record. The SESSION is left
  alone: a conversation is not garbage because the role that held it
  was retired, and deleting it here would be a surprise for
  `pasclaw resume`. }
function DeleteAgent(const Name: string; out Err: string): Boolean;

{ True while a turn is running on this agent's session. Read from the
  session turn lock, so it cannot disagree with reality. }
function AgentIsBusy(const Name: string): Boolean;

(* Deliver Text to an agent. Records it, then queues it.

   Delivered comes back as 'mid-turn' when the target was running (it
   will see the message between tool iterations) or 'queued' when it was
   idle (its next turn drains it first). False with Err set when the
   agent does not exist or the record could not be written. *)
function AgentSend(const ToName, FromWho, Text: string;
  out Delivered: string; out Err: string): Boolean;

{ The message record, newest last. Limit 0 = all. }
function AgentMessages(const Name: string; Limit: Integer): TAgentMessageArray;

{ How many messages are queued but not yet seen by the agent. }
function AgentPending(const Name: string): Integer;

{ ---- run state (Phase 3) ---- }

(* Record that a run began / ended. Written to the manifest so it
   survives the process: a supervisor starting up after a crash must be
   able to see that an agent was left mid-run, which is exactly the
   state nothing in memory can tell it about. *)
procedure MarkAgentRunStarted(const Name: string);
procedure MarkAgentRunFinished(const Name, State, Note: string);

(* Minutes since the agent's last run ENDED, or since it started when it
   is still running. -1 when it has never run.

   The supervisor's whole question in one number. Uses the manifest's
   timestamps rather than a file mtime because a manifest rewrite for an
   unrelated field would otherwise read as activity. *)
function AgentIdleMinutes(const Name: string): Integer;

{ ---- supervision (Phase 4) ---- }

type
  TAgentVerdict = record
    Name:   string;
    State:  string;   { what the manifest says }
    Minutes: Integer; { how long it has been in that state }
    Action: string;   { 'ok' | 'stalled' | 'restart' }
    Why:    string;   { human-readable, and what the parent is told }
  end;
  TAgentVerdictArray = array of TAgentVerdict;

(* Look at every agent and say what should happen to it. PURE: reads
   state, decides, and reports -- it starts nothing.

   Separated from acting so the decision is testable without a provider,
   a thread, or a gateway, and so the same verdicts can drive an
   operator's "what would you do" view as drive the actual sweep.

   StallMinutes: a run still marked `running` after this long is
   presumed dead -- the process that owned it is gone, because a live
   run updates nothing but also never ends. IdleMinutes: an agent that
   has not run in this long is nudged. Either 0 disables that half. *)
(* ------------------------------------------------------- the brake -- *)

(* Is this workspace's agent system paused?

   Paused means NO NEW TURNS START -- the team tick starts nothing, the
   run route refuses, `team up` seeds without kicking off, and
   supervision restarts nothing -- and TURNS ALREADY RUNNING END, at
   their next safe boundary. The gateway hands the tool loop a cancel
   hook that reads this flag, and the loop asks it before a provider
   call and after a tool batch has fully joined: the two points where
   the turn is in one piece. A turn is never cut between a file write
   and the board update that belongs with it, which is the
   half-finished state an operator hitting stop is trying to avoid.

   On disk, so a gateway restart does not quietly resume a system the
   operator stopped -- the failure that would matter most. *)
function AgentsPaused: Boolean;
function AgentsPausedNote: string;

(* Pause or resume. When pausing, Told comes back naming every agent
   that was mid-turn, so the caller can say who is being stopped rather
   than claiming everything halted the instant the flag was set --
   those turns end at their next boundary, which is soon but not now. *)
function SetAgentsPaused(Paused: Boolean; const Note: string;
                         out Told: TStringArray; out Err: string): Boolean;

function SuperviseAgents(StallMinutes, IdleMinutes: Integer): TAgentVerdictArray;

{ Tell an agent's parent what happened to it. No-op (False) when the
  agent has no parent -- a top-level agent answers to the operator, and
  inventing a recipient would be worse than silence. }
function NotifyParent(const Name, Text: string): Boolean;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Desktop.Events,   { PublishAgent -- the roster does not poll }
  PasClaw.Logger,
  PasClaw.Workspaces,
  PasClaw.Agent.Steering,
  PasClaw.Session.Store;

const
  MaxAgentName = 64;
  MaxMessage   = 16 * 1024;   { a message, not a document }

function AgentsDir: string;
begin
  Result := WorkspaceSubdir('agents');
end;

function AgentSlug(const S: string): string;
var
  I: Integer;
  C: Char;
  Last: Char;
begin
  Result := '';
  Last := '-';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C >= 'A') and (C <= 'Z') then C := Chr(Ord(C) + 32);
    if ((C >= 'a') and (C <= 'z')) or ((C >= '0') and (C <= '9')) then
    begin
      Result := Result + C;
      Last := C;
    end
    else if Last <> '-' then
    begin
      Result := Result + '-';
      Last := '-';
    end;
    if Length(Result) >= MaxAgentName then Break;
  end;
  while (Result <> '') and (Result[Length(Result)] = '-') do
    Delete(Result, Length(Result), 1);
end;

function AgentSessionId(const Name: string): string;
var
  Slug: string;
begin
  Result := '';
  Slug := AgentSlug(Name);
  if Slug = '' then Exit;
  Result := 'agent-' + Slug;
end;

function AgentDir(const Name: string): string;
var
  Slug: string;
begin
  Result := '';
  Slug := AgentSlug(Name);
  if Slug = '' then Exit;
  Result := JoinPath(AgentsDir, Slug);
end;

function ManifestPath(const Name: string): string;
var
  D: string;
begin
  Result := '';
  D := AgentDir(Name);
  if D = '' then Exit;
  Result := JoinPath(D, 'agent.json');
end;

function MessagesPath(const Name: string): string;
var
  D: string;
begin
  Result := '';
  D := AgentDir(Name);
  if D = '' then Exit;
  Result := JoinPath(D, 'messages.jsonl');
end;

function GetAgent(const Name: string; out Info: TAgentInfo): Boolean;
var
  Path: string;
  Obj: TJsonObject;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Name := ''; Info.Title := ''; Info.Role := '';
  Info.Model := ''; Info.Parent := ''; Info.Created := ''; Info.Updated := '';
  Path := ManifestPath(Name);
  if (Path = '') or not FileExists(Path) then Exit;
  try
    Obj := TJsonObject.Parse(ReadFileText(Path));
  except
    { A manifest we cannot parse reads as "no such agent" rather than
      taking down whatever asked. }
    Exit;
  end;
  try
    Info.Name    := AgentSlug(Name);
    Info.Title   := Obj.GetStr('title',  Info.Name);
    Info.Role    := Obj.GetStr('role',   '');
    Info.Model   := Obj.GetStr('model',  '');
    Info.Parent  := Obj.GetStr('parent', '');
    Info.Created := Obj.GetStr('created', '');
    Info.Updated := Obj.GetStr('updated', '');
    Info.RunState := Obj.GetStr('run_state', 'idle');
    Info.RunStart := Obj.GetStr('run_start', '');
    Info.RunEnd   := Obj.GetStr('run_end', '');
    Info.RunNote  := Obj.GetStr('run_note', '');
    Info.Exists  := True;
  finally
    Obj.Free;
  end;
  Result := True;
end;

function ListAgents: TAgentInfoArray;
var
  Rec: TSearchRec;
  Root: string;
  Info: TAgentInfo;
begin
  SetLength(Result, 0);
  Root := AgentsDir;
  if not DirectoryExists(Root) then Exit;
  if FindFirst(JoinPath(Root, '*'), faDirectory, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        if (Rec.Attr and faDirectory) = 0 then Continue;
        if not GetAgent(Rec.Name, Info) then Continue;
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := Info;
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
end;

function SaveAgent(const Info: TAgentInfo; out Err: string): string;
var
  Slug, Dir, Path, Created: string;
  Obj: TJsonObject;
  Prior: TAgentInfo;
begin
  Err := '';
  Result := '';
  Slug := AgentSlug(Info.Name);
  if Slug = '' then
  begin
    Err := 'not a usable agent name: ' + Info.Name;
    Exit;
  end;
  { An agent that reports to itself is a loop nobody meant to write. A
    deeper cycle is possible and is NOT checked here -- the delivery
    path does not walk parents, so a cycle costs an odd org chart
    rather than a hang. }
  if (Info.Parent <> '') and (AgentSlug(Info.Parent) = Slug) then
  begin
    Err := 'an agent cannot report to itself';
    Exit;
  end;
  Dir := JoinPath(AgentsDir, Slug);
  if not EnsureDir(Dir) then
  begin
    Err := 'could not create ' + Dir;
    Exit;
  end;

  { Created is written once and preserved across updates -- an agent's
    age is part of what it is. }
  Created := NowIsoUtc;
  if GetAgent(Slug, Prior) and (Prior.Created <> '') then
    Created := Prior.Created;

  Path := JoinPath(Dir, 'agent.json');
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name',  Slug);
    Obj.PutStr('title', Trim(Info.Title));
    Obj.PutStr('role',  Info.Role);
    if Info.Model  <> '' then Obj.PutStr('model',  Info.Model);
    if Info.Parent <> '' then Obj.PutStr('parent', AgentSlug(Info.Parent));
    Obj.PutStr('created', Created);
    Obj.PutStr('updated', NowIsoUtc);
    Obj.PutStr('session', 'agent-' + Slug);
    (* Run state is the RUNNER's to write, so an ordinary edit -- a role
       reworded, a parent reassigned -- must carry it through rather
       than resetting an agent that is working to 'idle'. Taken from the
       caller when they supplied one (the runner does), otherwise from
       what is already on disk. *)
    if Info.RunState <> '' then
    begin
      Obj.PutStr('run_state', Info.RunState);
      Obj.PutStr('run_start', Info.RunStart);
      Obj.PutStr('run_end',   Info.RunEnd);
      Obj.PutStr('run_note',  Info.RunNote);
    end
    else if Prior.Exists and (Prior.RunState <> '') then
    begin
      Obj.PutStr('run_state', Prior.RunState);
      Obj.PutStr('run_start', Prior.RunStart);
      Obj.PutStr('run_end',   Prior.RunEnd);
      Obj.PutStr('run_note',  Prior.RunNote);
    end;
    try
      WriteFileText(Path, Obj.ToJSON);
    except
      on E: Exception do
      begin
        Err := 'could not write the manifest: ' + E.Message;
        Exit;
      end;
    end;
  finally
    Obj.Free;
  end;
  LogInfo('agents: saved %s', [Slug]);
  Result := Slug;
end;

function DeleteAgent(const Name: string; out Err: string): Boolean;
var
  Dir, Path: string;
begin
  Err := '';
  Result := False;
  Dir := AgentDir(Name);
  if Dir = '' then
  begin
    Err := 'not a usable agent name: ' + Name;
    Exit;
  end;
  if not DirectoryExists(Dir) then
  begin
    Err := 'no such agent: ' + Name;
    Exit;
  end;
  { Anything still queued is undeliverable once the manifest is gone --
    drop it rather than leaving it to be folded into some future
    conversation that reuses the name. }
  ClearSteering(AgentSessionId(Name));
  Path := JoinPath(Dir, 'agent.json');
  if FileExists(Path) then DeleteFile(Path);
  Path := JoinPath(Dir, 'messages.jsonl');
  if FileExists(Path) then DeleteFile(Path);
  RemoveDir(Dir);
  LogInfo('agents: deleted %s', [AgentSlug(Name)]);
  Result := True;
end;

function AgentIsBusy(const Name: string): Boolean;
var
  Lock: TCriticalSection;
  Sid: string;
begin
  Result := False;
  Sid := AgentSessionId(Name);
  if Sid = '' then Exit;
  Lock := SessionTurnLock(Sid);
  if Lock = nil then Exit;
  { Held by someone else = a turn is running. TryEnter answers without
    waiting; release immediately if we got it, since we only asked. }
  if Lock.TryEnter then
  begin
    Lock.Leave;
    Exit(False);
  end;
  Result := True;
end;

{ One JSONL line. Written with the same all-or-nothing append the
  session record uses: a torn line is a corrupt record, and a record
  nobody can parse is worse than a missing one. }
function AppendMessage(const Name: string; const Msg: TAgentMessage): Boolean;
var
  Path, Line: string;
  Obj: TJsonObject;
  Strm: TFileStream;
  Bytes: TBytes;
begin
  Result := False;
  Path := MessagesPath(Name);
  if Path = '' then Exit;
  if not EnsureDir(ExtractFileDir(Path)) then Exit;
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('at',   Msg.At);
    Obj.PutStr('from', Msg.From);
    Obj.PutStr('text', Msg.Text);
    Obj.PutStr('delivered', Msg.Delivered);
    Line := Obj.ToJSON + #10;
  finally
    Obj.Free;
  end;
  Bytes := TEncoding.UTF8.GetBytes(Line);
  try
    if FileExists(Path) then
      Strm := TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite)
    else
      Strm := TFileStream.Create(Path, fmCreate or fmShareDenyWrite);
    try
      Strm.Seek(0, soFromEnd);
      if Length(Bytes) > 0 then
        Strm.WriteBuffer(Bytes[0], Length(Bytes));
    finally
      Strm.Free;
    end;
  except
    on E: Exception do
    begin
      LogWarn('agents: could not record a message for %s: %s',
              [Name, E.Message]);
      Exit;
    end;
  end;
  Result := True;
end;

function AgentSend(const ToName, FromWho, Text: string;
  out Delivered: string; out Err: string): Boolean;
var
  Info: TAgentInfo;
  Msg: TAgentMessage;
  Body, Sid: string;
begin
  Delivered := '';
  Err := '';
  Result := False;

  Body := Trim(Text);
  if Body = '' then
  begin
    Err := 'nothing to send';
    Exit;
  end;
  if Length(Body) > MaxMessage then
    Body := Copy(Body, 1, MaxMessage) + #10 + '[truncated]';
  if not GetAgent(ToName, Info) then
  begin
    Err := 'no such agent: ' + ToName;
    Exit;
  end;
  Sid := AgentSessionId(ToName);

  { Decide the wording BEFORE queueing: once the message is in the
    queue a running turn may drain it at any moment, and reading
    busyness afterwards would describe a race rather than what
    happened. }
  if AgentIsBusy(ToName) then Delivered := 'mid-turn' else Delivered := 'queued';

  Msg.At        := NowIsoUtc;
  Msg.From      := Trim(FromWho);
  if Msg.From = '' then Msg.From := 'operator';
  Msg.Text      := Body;
  Msg.Delivered := Delivered;

  { Record first. A message we delivered but cannot account for is the
    worse failure of the two -- the whole point of the record is that
    "who told whom what" survives the queue being consumed. }
  if not AppendMessage(Info.Name, Msg) then
  begin
    Err := 'could not record the message';
    Delivered := 'failed';
    Exit;
  end;

  { The envelope names the sender. Steering folds the raw text in as a
    system note, and an unattributed instruction arriving mid-turn is
    exactly the shape a prompt injection wants. }
  if not PushSteering(Sid, 'Message from ' + Msg.From + ': ' + Body) then
  begin
    Err := 'could not queue the message for ' + Info.Name;
    Delivered := 'failed';
    Exit;
  end;
  LogInfo('agents: %s -> %s (%s)', [Msg.From, Info.Name, Delivered]);
  (* Tell the screens. The roster and the agent-chat window subscribe to
     this event and deliberately do not poll, so without it a message
     from another agent, a supervisor, or an HTTP client changed the
     record and the pending count while every open desktop kept showing
     the old numbers until some unrelated run happened to fire an event.

     Published HERE rather than at each call site because every sender
     -- the tool, the HTTP route, NotifyParent -- funnels through this
     one function, and a chokepoint cannot be forgotten by the next
     caller someone adds. *)
  PublishAgent(Info.Name);
  Result := True;
end;

function AgentMessages(const Name: string; Limit: Integer): TAgentMessageArray;
var
  Path: string;
  Lines: TStringList;
  I, Start: Integer;
  Obj: TJsonObject;
  Msg: TAgentMessage;
begin
  SetLength(Result, 0);
  Path := MessagesPath(Name);
  if (Path = '') or not FileExists(Path) then Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      Exit;
    end;
    Start := 0;
    if (Limit > 0) and (Lines.Count > Limit) then Start := Lines.Count - Limit;
    for I := Start to Lines.Count - 1 do
    begin
      if Trim(Lines[I]) = '' then Continue;
      try
        Obj := TJsonObject.Parse(Lines[I]);
      except
        { One unreadable line does not invalidate the rest of the
          record. }
        Continue;
      end;
      try
        Msg.At        := Obj.GetStr('at', '');
        Msg.From      := Obj.GetStr('from', '');
        Msg.Text      := Obj.GetStr('text', '');
        Msg.Delivered := Obj.GetStr('delivered', '');
      finally
        Obj.Free;
      end;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Msg;
    end;
  finally
    Lines.Free;
  end;
end;

function AgentPending(const Name: string): Integer;
var
  Sid: string;
begin
  Result := 0;
  Sid := AgentSessionId(Name);
  if Sid = '' then Exit;
  Result := PendingSteeringCount(Sid);
end;

{ ------------------------------------------------------------ run state -- }

procedure MarkAgentRunStarted(const Name: string);
var
  Info: TAgentInfo;
  Err: string;
begin
  if not GetAgent(Name, Info) then Exit;
  Info.RunState := 'running';
  Info.RunStart := NowIsoUtc;
  Info.RunEnd   := '';
  Info.RunNote  := '';
  SaveAgent(Info, Err);
end;

procedure MarkAgentRunFinished(const Name, State, Note: string);
var
  Info: TAgentInfo;
  Err, Line: string;
begin
  if not GetAgent(Name, Info) then Exit;
  Info.RunState := State;
  Info.RunEnd   := NowIsoUtc;
  { A note is a status line, not a transcript -- the transcript is the
    agent's session, which is where anyone wanting the detail should
    look. }
  Line := Trim(Note);
  if Length(Line) > 240 then Line := Copy(Line, 1, 240) + '...';
  Info.RunNote := Line;
  SaveAgent(Info, Err);
end;

{ ISO-8601 'YYYY-MM-DDTHH:NN:SSZ' -> TDateTime. Returns 0 when the
  string is not one, which callers read as "no timestamp". }
function ParseIsoUtc(const S: string): TDateTime;
var
  Y, M, D, H, N, Sec: Word;
begin
  Result := 0;
  if Length(S) < 19 then Exit;
  try
    Y   := StrToInt(Copy(S,  1, 4));
    M   := StrToInt(Copy(S,  6, 2));
    D   := StrToInt(Copy(S,  9, 2));
    H   := StrToInt(Copy(S, 12, 2));
    N   := StrToInt(Copy(S, 15, 2));
    Sec := StrToInt(Copy(S, 18, 2));
    Result := EncodeDate(Y, M, D) + EncodeTime(H, N, Sec, 0);
  except
    Result := 0;
  end;
end;

function AgentIdleMinutes(const Name: string): Integer;
var
  Info: TAgentInfo;
  Stamp: TDateTime;
  Mins: Double;
begin
  Result := -1;
  if not GetAgent(Name, Info) then Exit;
  if SameText(Info.RunState, 'running') then
    Stamp := ParseIsoUtc(Info.RunStart)
  else
    Stamp := ParseIsoUtc(Info.RunEnd);
  if Stamp = 0 then Exit;
  { Both sides in UTC: the stamps are written as UTC by NowIsoUtc, so
    comparing them against local Now would report the timezone offset as
    idleness -- an agent that ran a minute ago reading as hours stale in
    anywhere but London. Same conversion NowIsoUtc itself uses. }
  {$IFDEF FPC}
  Mins := (LocalTimeToUniversal(Now) - Stamp) * 24 * 60;
  {$ELSE}
  Mins := (TTimeZone.Local.ToUniversalTime(Now) - Stamp) * 24 * 60;
  {$ENDIF}
  if Mins < 0 then Mins := 0;   { clock skew reads as "just now" }
  Result := Trunc(Mins);
end;

{ ---------------------------------------------------------- supervision -- }

function PausePath: string;
begin
  Result := JoinPath(AgentsDir, 'paused.json');
end;

function AgentsPaused: Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  if not FileExists(PausePath) then Exit;
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ReadFileText(PausePath));
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetBool('paused', False);
  finally
    Obj.Free;
  end;
end;

function AgentsPausedNote: string;
var
  Obj: TJsonObject;
begin
  Result := '';
  if not FileExists(PausePath) then Exit;
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ReadFileText(PausePath));
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    if Obj.GetBool('paused', False) then Result := Obj.GetStr('note', '');
  finally
    Obj.Free;
  end;
end;

function SetAgentsPaused(Paused: Boolean; const Note: string;
                         out Told: TStringArray; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Rows: TAgentInfoArray;
  I, N: Integer;
begin
  Result := False;
  Err := '';
  SetLength(Told, 0);
  if not EnsureDir(AgentsDir) then
  begin
    Err := 'could not create ' + AgentsDir;
    Exit;
  end;

  Obj := TJsonObject.Create;
  try
    Obj.PutBool('paused', Paused);
    Obj.PutStr('note', Note);
    Obj.PutStr('at', NowIsoUtc);
    WriteFileText(PausePath, Obj.ToJSON);
  finally
    Obj.Free;
  end;

  if not Paused then Exit(True);

  (* Who is mid-turn, for the operator to see. The flag above is what
     stops them: the gateway hands the tool loop a cancel hook that
     reads it, and every running turn ends at its next safe boundary.

     This used to also push a "wind down" note into each busy agent's
     steering queue, and that has to go, because the cancel hook made
     it a message that can only ever arrive at the wrong time. A turn
     drains its steering queue at the TOP of an iteration, after the
     boundary check -- so once the flag is set, the next boundary
     cancels the turn before the next drain, every time. The note is
     never read by the agent it was written for.

     It is not merely useless, though. It sits in the queue until the
     agent runs again -- which is after the operator resumes -- and the
     resumed turn is then handed "stop, do not start anything new, do
     not pick up another task" as if it were fresh instruction, and
     dutifully stands back down. Reproduced against a live gateway
     before removing it. (Codex P1 on #591.)

     What the note was for is now done better anyway: a cancelled turn
     ends with a notice in its own transcript saying it was stopped,
     where, and what it had already finished, carrying the progress
     ledger. That is what the next turn reads, and it is in the
     conversation rather than in a queue that outlives the pause. *)
  N := 0;
  Rows := ListAgents;
  for I := 0 to High(Rows) do
    if AgentIsBusy(Rows[I].Name) then
    begin
      SetLength(Told, N + 1);
      Told[N] := Rows[I].Name;
      Inc(N);
      PublishAgent(Rows[I].Name);
    end;
  Result := True;
end;

function SuperviseAgents(StallMinutes, IdleMinutes: Integer): TAgentVerdictArray;
var
  Rows: TAgentInfoArray;
  I, Mins: Integer;
  V: TAgentVerdict;
begin
  SetLength(Result, 0);
  Rows := ListAgents;
  for I := 0 to High(Rows) do
  begin
    Mins := AgentIdleMinutes(Rows[I].Name);
    V.Name    := Rows[I].Name;
    V.State   := Rows[I].RunState;
    V.Minutes := Mins;
    V.Action  := 'ok';
    V.Why     := '';

    (* A run marked `running` that is also NOT running.

       This is the only failure a supervisor can actually detect: a live
       turn holds the session's turn lock, so an agent whose manifest
       says `running` while the lock is free is one whose process died
       mid-turn -- nothing else can produce that pair. Checking the lock
       rather than the clock alone is what stops a legitimately long run
       from being declared dead at StallMinutes. *)
    if SameText(Rows[I].RunState, 'running') and (not AgentIsBusy(Rows[I].Name)) then
    begin
      V.Action := 'restart';
      V.Why := 'was left mid-run with no turn in flight -- the process ' +
               'that owned it is gone';
    end
    else if SameText(Rows[I].RunState, 'running') and (StallMinutes > 0) and
            (Mins >= StallMinutes) then
    begin
      { Running, lock held, but for a very long time. Reported, not
        restarted: something IS working, and killing it would lose
        whatever it has done. }
      V.Action := 'stalled';
      V.Why := Format('has been running for %d minute(s)', [Mins]);
    end
    else if SameText(Rows[I].RunState, 'failed') then
    begin
      V.Action := 'restart';
      V.Why := 'last run failed: ' + Rows[I].RunNote;
    end
    else if (IdleMinutes > 0) and (Mins >= IdleMinutes) and
            (not SameText(Rows[I].RunState, 'running')) then
    begin
      V.Action := 'restart';
      V.Why := Format('has not run for %d minute(s)', [Mins]);
    end;

    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := V;
  end;
end;

function NotifyParent(const Name, Text: string): Boolean;
var
  Info: TAgentInfo;
  Delivered, Err: string;
begin
  Result := False;
  if not GetAgent(Name, Info) then Exit;
  if Info.Parent = '' then Exit;
  Result := AgentSend(Info.Parent, Name, Text, Delivered, Err);
end;

end.
