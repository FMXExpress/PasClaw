(*
  PasClaw.Agent.SubagentBg -- background subagents: fire-and-continue
  fan-out, Claude Code style.

  The existing `spawn` tool is synchronous: the parent loop blocks
  until the specialist finishes. That's right for "ask the
  researcher and use the answer in this turn", wrong for "kick off
  a 90-second web-research task and keep editing files meanwhile".
  This unit adds the asynchronous sibling:

    spawn_background(agent, prompt) -> handle   returns immediately
    spawn_status(handle)            -> state + elapsed (+ preview)
    spawn_wait(handle, timeout_sec) -> blocks up to timeout, returns
                                       the full result when done
    spawn_cancel(handle)            -> marks the job cancelled

  Completion delivery is PUSH, not poll: when a background job
  finishes, the parent loop's next iteration folds a "[background
  subagent completed]" block into the system prompt -- same channel
  steering and compaction use, for the same reason (providers skip
  in-history mrSystem when Options.SystemPrompt is set). The model
  doesn't have to remember to check; results show up in front of it.
  Folded previews are capped; the model calls spawn_wait(handle) to
  get the full text when the preview was truncated.

  Wiring shape (mirrors how steering reaches the loop):
    - TToolLoopConfig gains BackgroundDrainKey (a string -- managed
      type, so existing callers that don't set it get '' and the
      feature stays inert for them).
    - PasClaw.Tools.ToolLoop exposes GBackgroundDrainHook, a plain
      function pointer this unit assigns at initialization. ToolLoop
      can't `uses` this unit (we call RunToolLoop -- that would be
      circular), so the hook breaks the cycle the same way
      Tools.ToolLoop's other late-bound integrations do.
    - Coordinators self-register in a key -> coordinator map when
      SetKey is called; the hook looks the coordinator up by the
      loop's BackgroundDrainKey and drains finished jobs.

  Lifecycle / threading:
    - One TBgJob = one TThread running RunToolLoop against a
      filtered child registry (the job owns the registry).
    - Job state transitions are guarded by a per-job critical
      section so the coordinator can read/cancel without racing the
      worker thread.
    - Cancel is advisory for a subagent: the loop checks for it at its
      step boundaries (ShouldCancel), so a model call already on the
      wire finishes first; the result is then discarded. A shell job on
      the local backend is killed.
    - Coordinator teardown abandons still-running jobs: they're
      flagged, self-free on completion, and die with the process.
      Their results are lost -- consistent with "background jobs
      live and die with the session".

  Concurrency cap: MaxConcurrentBackground (4). The 5th spawn gets
  a clean error telling the model to wait for or cancel something.

  History: finished jobs stay for spawn_wait, spawn_status and the
  gateway's Background view, at most BackgroundHistoryMax of them per
  coordinator (the oldest go first, those already delivered to the
  model before those that were not). Each job keeps a bounded copy of
  what its subagent said and did (FMessages), which is also what a
  follow-up message (ContinueBackgroundJob) continues from.
*)
unit PasClaw.Agent.SubagentBg;

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
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,      { ILLMProvider -- RegisterSubagentTools param }
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Subagent;

const
  MaxConcurrentBackground = 4;
  { Per-result preview cap inside the loop-top fold. Full results
    come back via spawn_wait; the fold just has to carry enough
    for the model to decide whether it needs the rest. }
  DrainPreviewChars = 2000;
  (* Finished jobs a coordinator keeps. Before this nothing was ever
     dropped: a gateway, which shares one coordinator across every chat
     for its whole life, grew the list -- each job holding its result and
     registry -- without bound. *)
  BackgroundHistoryMax = 50;
  (* The transcript a job keeps of its subagent, for viewing and to
     continue from. A message is cut at BgTranscriptMsgChars (tool-call
     arguments are elided past BgTranscriptArgChars, keeping them valid
     JSON); past BgTranscriptMaxMessages or BgTranscriptMaxChars the
     oldest messages after the first prompt go. 50 jobs at the cap stay
     around 13 MB. *)
  BgTranscriptMaxMessages = 200;
  BgTranscriptMsgChars    = 16384;
  BgTranscriptArgChars    = 4096;
  BgTranscriptMaxChars    = 262144;
  { The shell output kept for viewing: the TAIL, where a build or a test
    run says how it ended. Also the cap on a running job's live tail. }
  BgOutputViewChars = 65536;

type
  TBgJobState = (bjRunning, bjDone, bjFailed, bjCancelled);
  (* A job is a subagent loop or a shell command. Both share the handle
     space, the cap, status / wait / cancel and the drain; a shell job is
     the cheaper thing that was missing: `make test` that takes four
     minutes should not block the turn, and should be killable. *)
  TBgJobKind = (bjkSubagent, bjkShell);

  (* Fired on the job's own thread when it finishes (done or failed; not
     when cancelled). The TUI flashes it; the gateway publishes a desktop
     event from PublishRaw regardless of this hook. Key is the drain key
     (session) the job reports to. *)
  TBackgroundDoneProc = procedure(const Key, Handle, Summary: string) of object;

  TBgJob = class(TThread)
  private
    FStateLock:  TCriticalSection;
    FKind:       TBgJobKind;
    FHandle:     string;
    FAgentName:  string;
    { Shell jobs. FProc is the live process while it runs on the local
      backend (so cancel can kill it); nil otherwise. Under FStateLock. }
    FCommand:    string;
    FWorkDir:    string;
    FTimeoutMs:  Integer;
    FProc:       TObject;
    FExitCode:   Integer;
    FChildReg:   TToolRegistry;      { owned }
    FChildDisc:  TObject;            { owned TMCPDisclosure when the child inherited
                                       deferred MCP tools; nil otherwise }
    FCfg:        TObject;            { ^TToolLoopConfig boxed -- see impl }
    FPrompt:     string;
    FResultText: string;
    FErrMsg:     string;
    { Parent's checkpoint context, captured on the spawning thread so
      this job's file writes snapshot into the parent's session turn.
      Opaque handle -- nil when checkpoints are off. }
    FCheckpointHandle: TObject;
    (* The drain key of the loop that spawned this job -- the session it
       must report back to. Stamped from CurrentDispatchDrainKey on the
       spawning thread, falling back to the coordinator's own key. Matters
       in the gateway, where many sessions share one registry and so one
       coordinator: before this, a gateway turn could start a job and no
       turn ever heard it finish, because nothing set the key at all. *)
    FDrainKey:   string;
    (* The shell session of the turn that spawned this job, captured on
       the spawning thread like the drain key. The job outlives that turn,
       and the docker backend keys its container on the id: read later
       from the process-wide value it would be gone (an empty-session
       refusal) or another session's (that session's container). *)
    FShellSessionId: string;
    FState:      TBgJobState;
    FCollected:  Boolean;            { delivered via drain already }
    FAbandoned:  Boolean;            { coordinator gone; self-free }
    FStartedAt:  TDateTime;
    FFinishedAt: TDateTime;
    { Git branch a subagent works in, '' when none (FWorkDir then holds
      its worktree path; for a shell job FWorkDir is the cwd). }
    FWorktree:   string;
    (* What the subagent said and did, under FStateLock. Built from the
       loop's callbacks while it runs, so a viewer sees progress, then
       replaced by the loop's own final history, which a follow-up
       continues from. Always passed through BoundTranscript. *)
    FMessages:   TMessageArray;
    FTrimmed:    Boolean;            { BoundTranscript dropped or cut something }
    { The loop's system prompt at the end -- a compaction summary lives
      there, so a follow-up must start from it, not the spec's. }
    FFinalSystemPrompt: string;
    { A follow-up job: the conversation it continues (its prompt is the
      new message), and the links both ways. }
    FSeedHistory:   TMessageArray;
    FContinuedFrom: string;
    FContinuedBy:   string;          { the latest follow-up of this job }
    { The tail of a running local shell job's output, so it can be
      watched before it ends. Under FStateLock. }
    FLiveOut:    TBytes;
    { Holders of this job outside the coordinator lock (spawn_wait while it
      polls). Pruning skips a pinned job. Under the coordinator's FLock. }
    FPins:       Integer;
    procedure RunShellJob;
    procedure NotifyDone;
    { RunToolLoop callbacks (the job's own thread) feeding FMessages. }
    procedure LiveAppend(const M: TMessage);
    procedure LiveText(const S: string);
    procedure LiveToolCall(const Name, ArgsJSON: string);
    procedure LiveToolResult(const Name, ResultText, Err: string);
    { ShouldCancel: the loop stops at its next step once a cancel came. }
    function  CancelAsked: Boolean;
  protected
    procedure Execute; override;
  public
    destructor Destroy; override;
  end;

  (* A copy of one job, taken under its locks, for viewers: the gateway's
     /v1/background routes and the `/tasks` command. FinishedAt is 0 until
     the job's thread has ended; a cancelled job whose thread is still
     finishing a model call reads State = 'cancelled' with Stopping set.
     Messages / Output are filled only by GetBackgroundJob. *)
  TBgJobInfo = record
    Handle, Kind, AgentName, Command, Prompt, State, Session: string;
    StartedAt, FinishedAt: TDateTime;
    ElapsedSec: Int64;
    Stopping:   Boolean;
    ResultText, ErrMsg: string;
    ExitCode:   Integer;             { shell, once finished; -1 otherwise }
    Collected:  Boolean;             { its result reached its chat's model }
    Killable:   Boolean;             { a live local process cancel can kill }
    Worktree:   string;
    ContinuedFrom, ContinuedBy: string;
    Messages:   TMessageArray;
    Trimmed:    Boolean;
    Output:     string;              { shell: the output tail }
    OutputTruncated: Boolean;
  end;
  TBgJobInfoArray = array of TBgJobInfo;

  TBgCancelOutcome = (bcoNotFound, bcoKilled, bcoAdvisory, bcoAlreadyFinished);
  TBgContinueOutcome = (bmoStarted, bmoNotFound, bmoEmptyText, bmoNotSubagent,
                        bmoRunning, bmoNoSuchAgent, bmoAtCap);

  TBackgroundSpawnCoordinator = class
  private
    FLock:  TCriticalSection;
    FJobs:  TList;
    FCtx:   TSubagentContext;
    FSpecs: TSubagentSpecArray;
    FKey:   string;
    { Slots promised to a spawn_background that is still creating its
      worktree outside the lock. Counted against MaxJobs like a running
      job, so nothing else can take the slot meanwhile. Under FLock. }
    FReserved: Integer;
    function FindSpec(const N: string; out S: TSubagentSpec): Boolean;
    function FindJob(const Handle: string): TBgJob;
    function RunningCount: Integer;
    function SlotsInUse: Integer;   { RunningCount + FReserved; caller holds FLock }
    function MaxJobs: Integer;
    function NewHandle(const Prefix: string): string;
    { Drop finished jobs past BackgroundHistoryMax. Caller holds FLock. }
    procedure PruneHistory;
    { Copy one job for a viewer. Caller holds FLock. }
    procedure FillInfo(J: TBgJob; WithDetail: Boolean; out Info: TBgJobInfo);
  public
    constructor Create(const ACtx: TSubagentContext;
                       const ASpecs: TSubagentSpecArray);
    destructor Destroy; override;

    { Bind this coordinator to a drain key (the session id). Also
      registers it in the global key->coordinator map the ToolLoop
      hook consults. Call once the session id is known; re-calling
      with a new key moves the registration. }
    procedure SetKey(const Key: string);
    procedure SetContext(const ACtx: TSubagentContext);

    { Tool handlers (TToolHandlerObj signatures). }
    function HandleSpawnBackground(const ArgsJSON: string; out ErrMsg: string): string;
    { shell_background: run a shell command as a job. Same denylist and
      cwd rules as shell_exec; returns an sh-<hex> handle. }
    function HandleShellBackground(const ArgsJSON: string; out ErrMsg: string): string;
    function HandleStatus(const ArgsJSON: string; out ErrMsg: string): string;
    function HandleWait(const ArgsJSON: string; out ErrMsg: string): string;
    function HandleCancel(const ArgsJSON: string; out ErrMsg: string): string;

    { Collect finished-and-not-yet-delivered jobs into a formatted
      block for the loop-top system-prompt fold. Marks them
      delivered (drain-once). Returns '' when nothing is pending.
      MaxChars bounds the total block size. Key filters to jobs whose
      drain key matches; '' means every job (the TUI/CLI shape, one
      session per coordinator). }
    function DrainFinishedBlock(MaxChars: Integer; const Key: string = ''): string;

    { Viewer operations; the global functions below walk every
      coordinator with these. }
    procedure AppendInfos(var Arr: TBgJobInfoArray);
    function  GetInfo(const Handle: string; out Info: TBgJobInfo): Boolean;
    function  CancelJob(const Handle: string; out Msg: string): TBgCancelOutcome;
    function  ContinueJob(const Handle, Text: string;
                          out NewJobHandle, Msg: string): TBgContinueOutcome;
  end;

(* Register spawn_background / spawn_status / spawn_wait /
   spawn_cancel against Reg when Specs is non-empty. Returns the
   coordinator (or nil) -- caller keeps it alive for the registry's
   lifetime and may leak it for the CLI one-shot path (module
   finalization reaps). Call coordinator.SetKey(sessionId) once the
   session id is known, and set LoopCfg.BackgroundDrainKey to the
   same value so completions reach the loop. *)
function RegisterBackgroundSpawnTools(Reg: TToolRegistry;
                                      const Ctx: TSubagentContext;
                                      const Specs: TSubagentSpecArray)
                                      : TBackgroundSpawnCoordinator;

(* A surface that wants to be told when a background job finishes --
   the TUI flashes it in the footer -- installs a handler here.

   Set and cleared ONLY through these two calls, never by assigning the
   variable. SetBackgroundDoneHook takes the same lock the dispatch
   takes, so clearing it waits for a callback that is already running
   and no new one can start afterwards. That matters because the only
   caller clears the hook on its way to freeing the object the handler
   is a method of: `if Assigned(hook) then hook(...)` had a window
   between the test and the call where the main thread could clear the
   pointer AND free the object, and the job's thread would then run a
   method of freed memory during an ordinary TUI shutdown. (Codex P2 on
   #610.)

   Pass nil to remove. The lock lives for the life of the unit, so a
   handler is safe to clear from any thread at any time. *)
procedure SetBackgroundDoneHook(Hook: TBackgroundDoneProc);

{ Call the installed handler, if any, under the same lock. Exposed so
  other producers of background completions can reuse the dispatch
  rather than reading the hook themselves. }
procedure FireBackgroundDone(const Key, Handle, Summary: string);

{ One-call wiring of the synchronous `spawn` + the background spawn tools onto
  Reg, for surfaces that don't track the returned tool/coordinator (serve,
  gateway). Builds the TSubagentContext from Cfg/Provider/Reg, resolves the
  effective specs (built-in general-purpose + any configured; empty when
  subagents are disabled), and registers both. With subagents off only
  `spawn` and `spawn_background` are skipped -- shell_background and the
  handle verbs still register, since they are shell tools. No-op when
  there's no provider/registry. The created tools live for the process (Reg
  dispatches through their method pointers), which is the server lifetime. }
procedure RegisterSubagentTools(Cfg: TConfig; Provider: ILLMProvider;
                                Reg: TToolRegistry; const DefaultModel: string);

(* Background work across the whole process -- every coordinator, so on
   the gateway every chat's jobs, not one session's. What the gateway's
   /v1/background routes and the `/tasks` command show.

   ListBackgroundJobs: running (and still-stopping) jobs first, then the
   rest, newest first within each; no transcripts.
   GetBackgroundJob: one job with its transcript (a subagent) or its
   output tail (a shell job).
   CancelBackgroundJob: spawn_cancel's path. bcoAdvisory means the job was
   marked and will stop by itself (a subagent at its next step, a shell
   job under the docker backend), bcoKilled that a local process was.
   ContinueBackgroundJob: a follow-up message to a finished subagent. A
   new job continues that subagent's conversation with Text, in the same
   chat, workspace and agent; the two are linked (ContinuedFrom /
   ContinuedBy). Refused for a shell job and for a job still running. *)
function ListBackgroundJobs: TBgJobInfoArray;
function GetBackgroundJob(const Handle: string; out Info: TBgJobInfo): Boolean;
function CancelBackgroundJob(const Handle: string; out Msg: string): TBgCancelOutcome;
function ContinueBackgroundJob(const Handle, Text: string;
                               out NewHandle, Msg: string): TBgContinueOutcome;

{ The jobs as a plain-text list, for `/tasks` in `pasclaw agent` and the
  TUI. One line per job, running first; a note when there are none. }
function FormatBackgroundJobsText: string;
{ The same in one line, for the positioned TUI's footer flash. }
function BackgroundJobsSummary: string;

(* Apply the transcript bounds (the BgTranscript constants). Cut messages keep
   their role and structure; dropped ones go from the front, after the
   first message, and never leave a tool result without its call.
   Trimmed is set when anything was cut or dropped. Exposed for tests. *)
function BoundTranscript(const Msgs: TMessageArray; out Trimmed: Boolean): TMessageArray;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Platform,            { TStdioProcess, the output cap, the shell timeout }
  PasClaw.Tools.Sandbox,       { ShellAllowed + cwd rules for shell jobs }
  PasClaw.Shell.Backend,       { non-local backends run shell jobs through Exec }
  PasClaw.Desktop.Events,      { PublishRaw: background_done for the web UI }
  PasClaw.Tools.Worktree,      { EnsureWorktree -- spawn_background(worktree:"<branch>") }
  PasClaw.Providers.Factory,   { ResolveFallbacks for RegisterSubagentTools }
  PasClaw.MCP.Disclosure,      { per-registry tool_search for bg subagents }
  PasClaw.Crypto.Random,
  PasClaw.Checkpoints,
  PasClaw.Utils,               { Utf8SafeTruncate -- transcript and preview cuts }
  PasClaw.Tools.ToolLoop;

type
  { Box for the child TToolLoopConfig so TBgJob can carry it as a
    field without PasClaw.Tools.ToolLoop appearing in our interface
    uses (it's implementation-only here to keep the surface tidy). }
  TLoopCfgBox = class
  public
    Cfg: TToolLoopConfig;
  end;

var
  { key -> coordinator map the ToolLoop drain hook consults. Guarded
    by GMapLock. Coordinators add themselves in SetKey and remove
    themselves in Destroy. }
  GMap:     TStringList = nil;
  GMapLock: TCriticalSection = nil;
  { Coordinators created via RegisterBackgroundSpawnTools, reaped at
    finalization (same ownership shape as ExecuteCode's GRunners). }
  GCoordinators: TList = nil;
  { The completion handler and the lock that makes installing, clearing
    and calling it mutually exclusive. See SetBackgroundDoneHook. }
  GDoneHook:     TBackgroundDoneProc = nil;
  GDoneHookLock: TCriticalSection = nil;

{ Both of these read the lock into a local first. Finalization NILS the
  global without freeing it, so a copy taken a moment earlier stays
  valid -- testing the global and then dereferencing it would be its own
  little race. }
procedure SetBackgroundDoneHook(Hook: TBackgroundDoneProc);
var
  Lk: TCriticalSection;
begin
  Lk := GDoneHookLock;
  if Lk = nil then Exit;   { unit finalised; nothing to install }
  Lk.Enter;
  try
    GDoneHook := Hook;
  finally
    Lk.Leave;
  end;
end;

procedure FireBackgroundDone(const Key, Handle, Summary: string);
var
  Lk: TCriticalSection;
begin
  Lk := GDoneHookLock;
  if Lk = nil then Exit;
  (* Held across the CALL, not just the read. Copying the handler out and
     releasing first would put the window straight back: the copy can be
     invoked after the owner has cleared the hook and freed itself. The
     handler parks a string under its own lock and returns -- holding this
     one across it costs nothing and cannot deadlock back into Set/Fire. *)
  Lk.Enter;
  try
    if Assigned(GDoneHook) then
      try
        GDoneHook(Key, Handle, Summary);
      except
      end;
  finally
    Lk.Leave;
  end;
end;

function RandHex(NBytes: Integer): string;
var
  B: TBytes;
  i: Integer;
const
  HexChars: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');
begin
  B := GetRandomBytes(NBytes);
  SetLength(Result, NBytes * 2);
  for i := 0 to NBytes - 1 do
  begin
    Result[(i * 2) + 1] := HexChars[(B[i] shr 4) and $0F];
    Result[(i * 2) + 2] := HexChars[B[i] and $0F];
  end;
end;

{ ----------------------------- TBgJob ----------------------------- }

function JsonStr(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '"';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    case C of
      '"':  Result := Result + '\"';
      '\': Result := Result + '\\';
      #10:  Result := Result + '\n';
      #13:  Result := Result + '\r';
      #9:   Result := Result + '\t';
    else
      if Ord(C) < 32 then Result := Result + Format('\u%.4x', [Ord(C)])
      else Result := Result + C;
    end;
  end;
  Result := Result + '"';
end;

{ ------------------------- transcript bounds ------------------------- }

function TranscriptMsgSize(const M: TMessage): Integer;
var
  i: Integer;
begin
  Result := Length(M.Content);
  for i := 0 to High(M.ToolCalls) do
    Inc(Result, Length(M.ToolCalls[i].Func.Arguments) + Length(M.ToolCalls[i].Func.Name));
end;

function CutText(const S: string; MaxLen: Integer): string;
begin
  if Length(S) <= MaxLen then Exit(S);
  Result := Utf8SafeTruncate(S, MaxLen) +
            Format(#10'... [cut: %d more characters]', [Length(S) - MaxLen]);
end;

function BoundTranscript(const Msgs: TMessageArray; out Trimmed: Boolean): TMessageArray;
var
  i, j, k, Total, Dropped: Integer;
  Args: string;
begin
  Trimmed := False;
  { Copy, not share: the caller's array keeps changing on its own thread. }
  Result := nil;
  SetLength(Result, Length(Msgs));
  Total := 0;
  for i := 0 to High(Msgs) do
  begin
    Result[i] := Msgs[i];
    if Length(Result[i].Content) > BgTranscriptMsgChars then
    begin
      Result[i].Content := CutText(Result[i].Content, BgTranscriptMsgChars);
      Trimmed := True;
    end;
    if Length(Msgs[i].ToolCalls) > 0 then
    begin
      { A fresh array: the source's would be changed through a shared one. }
      SetLength(Result[i].ToolCalls, 0);
      SetLength(Result[i].ToolCalls, Length(Msgs[i].ToolCalls));
      for j := 0 to High(Msgs[i].ToolCalls) do
      begin
        Result[i].ToolCalls[j] := Msgs[i].ToolCalls[j];
        { Elided, never cut: a follow-up sends these back to the provider,
          which wants valid JSON. }
        Args := Msgs[i].ToolCalls[j].Func.Arguments;
        if Length(Args) > BgTranscriptArgChars then
        begin
          Result[i].ToolCalls[j].Func.Arguments := ElideLargeToolArgs(Args, BgTranscriptArgChars);
          Trimmed := True;
        end;
      end;
    end;
    Inc(Total, TranscriptMsgSize(Result[i]));
  end;
  (* Over a bound: drop Result[1..k-1], keeping the first message (the task
     the subagent was given). Past the point where the bounds hold, keep
     dropping tool results that would otherwise lead the kept part: a
     provider refuses a tool message whose call is gone. One shift at the
     end, so a long history costs one pass, not one per message. *)
  k := 1;
  Dropped := 0;
  while (k <= High(Result)) and
        ((Length(Result) - (k - 1) > BgTranscriptMaxMessages) or
         (Total - Dropped > BgTranscriptMaxChars) or
         ((k > 1) and (Result[k].Role = mrTool))) do
  begin
    Inc(Dropped, TranscriptMsgSize(Result[k]));
    Inc(k);
  end;
  if k > 1 then
  begin
    for i := k to High(Result) do Result[i - k + 1] := Result[i];
    SetLength(Result, Length(Result) - (k - 1));
    Trimmed := True;
  end;
end;

{ ------------------------- job: live transcript ---------------------- }

procedure TBgJob.LiveAppend(const M: TMessage);
var
  N: Integer;
  T: Boolean;
begin
  FStateLock.Enter;
  try
    N := Length(FMessages);
    SetLength(FMessages, N + 1);
    FMessages[N] := M;
    { One pass over at most a few hundred messages, once per model round
      or tool result -- nothing next to the call that produced them. }
    FMessages := BoundTranscript(FMessages, T);
    FTrimmed := FTrimmed or T;
  finally
    FStateLock.Leave;
  end;
end;

procedure TBgJob.LiveText(const S: string);
begin
  LiveAppend(MakeMessage(mrAssistant, S));
end;

procedure TBgJob.LiveToolCall(const Name, ArgsJSON: string);
(* The calls of one round arrive one by one after that round's text, if it
   had any: they join the assistant message of the round, or start one when
   the last message is a tool result (the previous round's) or the prompt.
   No call ids are known here; the final history replaces all of this. *)
var
  N, k: Integer;
  TC: TToolCall;
  M: TMessage;
begin
  TC := Default(TToolCall);
  TC.Kind := 'function';
  TC.Func.Name := Name;
  if Length(ArgsJSON) > BgTranscriptArgChars then
    TC.Func.Arguments := ElideLargeToolArgs(ArgsJSON, BgTranscriptArgChars)
  else
    TC.Func.Arguments := ArgsJSON;
  FStateLock.Enter;
  try
    N := Length(FMessages);
    if (N > 0) and (FMessages[N - 1].Role = mrAssistant) then
    begin
      k := Length(FMessages[N - 1].ToolCalls);
      TC.Id := Format('live-%d-%d', [N - 1, k]);
      SetLength(FMessages[N - 1].ToolCalls, k + 1);
      FMessages[N - 1].ToolCalls[k] := TC;
      Exit;
    end;
  finally
    FStateLock.Leave;
  end;
  M := MakeMessage(mrAssistant, '');
  TC.Id := Format('live-%d-0', [N]);
  SetLength(M.ToolCalls, 1);
  M.ToolCalls[0] := TC;
  LiveAppend(M);
end;

procedure TBgJob.LiveToolResult(const Name, ResultText, Err: string);
var
  M: TMessage;
begin
  if Err <> '' then M := MakeMessage(mrTool, 'error: ' + Err)
  else M := MakeMessage(mrTool, ResultText);
  M.Name := Name;
  LiveAppend(M);
end;

function TBgJob.CancelAsked: Boolean;
begin
  FStateLock.Enter;
  try
    Result := FState = bjCancelled;
  finally
    FStateLock.Leave;
  end;
end;

procedure TBgJob.NotifyDone;
var
  Summary, Kind: string;
  St: TBgJobState;
begin
  FStateLock.Enter;
  try
    St := FState;
    if FKind = bjkShell then
    begin
      Kind := 'shell';
      if St = bjDone then Summary := Format('exit=%d: %s', [FExitCode, Copy(FCommand, 1, 80)])
      else Summary := 'failed: ' + Copy(FCommand, 1, 80);
    end
    else
    begin
      Kind := 'subagent';
      if St = bjDone then Summary := 'done: ' + FAgentName
      else Summary := 'failed: ' + FAgentName;
    end;
  finally
    FStateLock.Leave;
  end;
  if St = bjCancelled then Exit;
  { Web UI: a desktop event; no listeners, no cost. }
  try
    PublishRaw('{"type":"background_done","session":' + JsonStr(FDrainKey) +
               ',"handle":' + JsonStr(FHandle) + ',"kind":"' + Kind +
               '","summary":' + JsonStr(Summary) + '}');
  except
  end;
  { TUI / CLI: whatever they wired. Through the dispatcher, which
    serialises against teardown -- see SetBackgroundDoneHook. }
  FireBackgroundDone(FDrainKey, FHandle, Summary);
end;

procedure TBgJob.RunShellJob;
var
  Backend: IShellBackend;
  P: TStdioProcess;
  Args: TStringList;
  Buf: array[0..4095] of Byte;
  Acc: TMemoryStream;
  N, Total, Code, LiveLen: Integer;
  Out_: string;
  StartT: TDateTime;
  TimedOut, Cancelled, Ok, Spawned: Boolean;
  Bytes: TBytes;

  procedure KillTree;
  (* Kill the job's whole process tree, not just the /bin/sh (or cmd.exe)
     wrapper this job owns.

     Terminating the wrapper alone left everything it had started --
     compiler workers, a `make -j`, anything launched with `&` -- running
     after spawn_cancel had already reported the job killed, still writing
     files and burning CPU with nothing holding a handle to them. Same for
     the timeout and the output cap. (Codex P1 on #610.)

     Codex asked for an isolated process group. There is no portable way
     to get one from here: FPC's TProcess has no POSIX process-group
     option (poNewProcessGroup is Windows-only) and `setsid` is not a
     binary to count on (util-linux ships one, macOS does not).
     TerminateProcessTree walks the real parent links instead -- every
     descendant that has not deliberately re-parented itself -- and on
     Windows is `taskkill /T /F`, which is a true tree kill. Same idiom
     as the timeout in PasClaw.Platform's own one-shot loops. *)
  begin
    TerminateProcessTree(P.ProcessId);
    if P.Running then try P.Terminate; except end;
  end;

begin
  Ok := False;
  TimedOut := False;
  Code := -1;
  Out_ := '';
  Backend := GetActiveShellBackend;
  if (Backend <> nil) and (not SameText(Backend.Name, 'local')) then
  begin
    { A non-local backend (docker) owns the process; there is nothing to
      kill from here, so cancel stays advisory for this job. The timeout
      still applies through the backend's own path. }
    try
      SetShellTimeoutOverrideMs(FTimeoutMs);
      try
        Code := RunOneShotWithEnvViaBackend(FShellSessionId, FCommand, FWorkDir, nil, Out_);
      finally
        SetShellTimeoutOverrideMs(-1);
      end;
      Ok := True;
    except
      on E: Exception do Out_ := E.Message;
    end;
  end
  else
  begin
    P := TStdioProcess.Create;
    Args := TStringList.Create;
    Acc := TMemoryStream.Create;
    try
      {$IFDEF MSWINDOWS}
      Args.Add('/C'); Args.Add(FCommand);
      Spawned := P.Spawn('cmd.exe', Args, {MergeStderr=}True, FWorkDir, nil);
      {$ELSE}
      Args.Add('-c'); Args.Add(FCommand);
      Spawned := P.Spawn('/bin/sh', Args, {MergeStderr=}True, FWorkDir, nil);
      {$ENDIF}
      if not Spawned then
        Out_ := 'failed to spawn the shell'
      else
      begin
        FStateLock.Enter;
        try FProc := P; finally FStateLock.Leave; end;
        StartT := Now;
        Total := 0;
        while True do
        begin
          N := P.ReadAvailable(Buf, SizeOf(Buf));
          if N > 0 then
          begin
            Acc.WriteBuffer(Buf, N);
            Inc(Total, N);
            { The tail a viewer sees while the command runs. }
            FStateLock.Enter;
            try
              LiveLen := Length(FLiveOut);
              SetLength(FLiveOut, LiveLen + N);
              Move(Buf[0], FLiveOut[LiveLen], N);
              if Length(FLiveOut) > BgOutputViewChars then
                FLiveOut := Copy(FLiveOut, Length(FLiveOut) - BgOutputViewChars, BgOutputViewChars);
            finally
              FStateLock.Leave;
            end;
            if Total > OneShotMaxBytes then begin KillTree; Break; end;
          end
          else if not P.Running then Break;
          if (FTimeoutMs > 0) and (Trunc((Now - StartT) * 86400000.0) >= FTimeoutMs) then
          begin
            TimedOut := True;
            KillTree;
            Break;
          end;
          FStateLock.Enter;
          try Cancelled := FState = bjCancelled; finally FStateLock.Leave; end;
          if Cancelled then begin KillTree; Break; end;
        end;
        while P.Running do Sleep(10);
        Code := P.ExitCode;
        if TimedOut then Code := 124;
        if Acc.Size > 0 then
        begin
          SetLength(Bytes, Acc.Size);
          Acc.Position := 0;
          Acc.ReadBuffer(Bytes[0], Acc.Size);
          Out_ := DecodeShellOutputBytes(Bytes, Length(Bytes));
        end;
        if TimedOut then
          Out_ := Out_ + Format(' (timed out after %d s)', [(FTimeoutMs + 999) div 1000]);
        Ok := True;
        FStateLock.Enter;
        try FProc := nil; finally FStateLock.Leave; end;
      end;
    finally
      Acc.Free;
      Args.Free;
      P.Free;
    end;
  end;

  FStateLock.Enter;
  try
    FFinishedAt := Now;
    FExitCode := Code;
    FLiveOut := nil;   { the result below has it all now }
    if FState = bjCancelled then
    begin
      { The cancel path set the state. Nothing delivers a cancelled job's
        result to the model, but what a killed command printed is what
        the operator wants to read in the Background view. }
      if Ok then FResultText := Format('exit=%d'#10'%s', [Code, Out_]);
    end
    else if Ok then
    begin
      FState := bjDone;
      FResultText := Format('exit=%d'#10'%s', [Code, Out_]);
    end
    else
    begin
      FState := bjFailed;
      FErrMsg := Out_;
      if FErrMsg = '' then FErrMsg := 'shell job failed';
    end;
    if FAbandoned then FreeOnTerminate := True;
  finally
    FStateLock.Leave;
  end;
  NotifyDone;
end;

procedure TBgJob.Execute;
var
  Hist: TMessageArray;
  Loop: TToolLoopResult;
  Ok, T: Boolean;
  i: Integer;
begin
  if FKind = bjkShell then
  begin
    RunShellJob;
    Exit;
  end;
  Ok := False;
  Loop := Default(TToolLoopResult);   { read below even when the loop never ran }
  try
    { Run this background loop under the parent's checkpoint session so
      its fs_write / fs_edit snapshots fold into the parent's turn (the
      worker thread starts with no context of its own). No-op when the
      parent had checkpoints off. }
    AdoptCheckpointHandle(FCheckpointHandle);
    { For what runs on this thread outside a dispatch (held-out
      scenarios); dispatches set it from the config themselves. }
    SetThreadShellSessionId(FShellSessionId);
    try
      { A follow-up starts from the conversation it continues. }
      SetLength(Hist, Length(FSeedHistory) + 1);
      for i := 0 to High(FSeedHistory) do Hist[i] := FSeedHistory[i];
      Hist[High(Hist)] := MakeMessage(mrUser, FPrompt);
      FStateLock.Enter;
      try
        FMessages := BoundTranscript(Hist, T);
        FTrimmed := T;
        FSeedHistory := nil;   { held by FMessages and Hist from here }
      finally
        FStateLock.Leave;
      end;
      Ok := RunToolLoop(TLoopCfgBox(FCfg).Cfg, Hist, Loop);
    finally
      { Cleared before the thread ends: Delphi does not finalize a
        string threadvar when its thread exits, so it would leak. }
      SetThreadShellSessionId('');
    end;
  except
    on E: Exception do
    begin
      FStateLock.Enter;
      try
        FErrMsg := E.ClassName + ': ' + E.Message;
      finally
        FStateLock.Leave;
      end;
    end;
  end;

  { A provider that refused or could not be reached ends the loop "ok" with
    its error as the content; that job did not do its task. 0 is a provider
    that never sets the status. }
  if Ok and (Loop.LastResp.StatusCode <> 0) and
     ((Loop.LastResp.StatusCode < 200) or (Loop.LastResp.StatusCode >= 300)) then
  begin
    Ok := False;
    FStateLock.Enter;
    try
      FErrMsg := Format('provider status %d: %s', [Loop.LastResp.StatusCode, Loop.Content]);
    finally
      FStateLock.Leave;
    end;
  end;

  FStateLock.Enter;
  try
    FFinishedAt := Now;
    { The loop's own final history -- real call ids, compaction applied --
      over the live copy, whenever it has one: also for a cancelled or
      failed job, whose transcript shows how far it got. }
    if Length(Loop.FinalMessages) > 0 then
    begin
      Hist := Loop.FinalMessages;
      (* FinalMessages stops one message short: the answer is Loop.Content
         and nowhere in the array (Cmd.Agent appends it the same way before
         saving a session). Without it the view would show no answer and a
         follow-up would continue a conversation the subagent never
         finished. Not for a refusal (that text is an error, not a reply)
         and not twice. *)
      if Ok and (not Loop.Cancelled) and (Trim(Loop.Content) <> '') and
         not ((Hist[High(Hist)].Role = mrAssistant) and
              (Hist[High(Hist)].Content = Loop.Content)) then
      begin
        SetLength(Hist, Length(Hist) + 1);
        Hist[High(Hist)] := MakeMessage(mrAssistant, Loop.Content);
      end;
      FMessages := BoundTranscript(Hist, T);
      FTrimmed := T;
    end;
    FFinalSystemPrompt := Loop.FinalSystemPrompt;
    if FState = bjCancelled then
      { Keep the cancelled marker; result discarded by policy. }
    else if Ok then
    begin
      FState      := bjDone;
      FResultText := LoopResultText(Loop);   { never a bare '' for a done job }
    end
    else
    begin
      FState := bjFailed;
      if FErrMsg = '' then FErrMsg := 'subagent loop failed';
    end;
    { Abandoned by a torn-down coordinator: nobody will ever Free
      us, so self-free on the way out. }
    if FAbandoned then FreeOnTerminate := True;
  finally
    FStateLock.Leave;
  end;
  NotifyDone;
end;

destructor TBgJob.Destroy;
begin
  FChildReg.Free;
  FChildDisc.Free;   { non-primary disclosure bound to FChildReg }
  FCfg.Free;
  FStateLock.Free;
  inherited Destroy;
end;

{ ----------------------- coordinator ------------------------------ }

constructor TBackgroundSpawnCoordinator.Create(const ACtx: TSubagentContext;
                                               const ASpecs: TSubagentSpecArray);
var
  i: Integer;
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FJobs := TList.Create;
  FCtx  := ACtx;
  SetLength(FSpecs, Length(ASpecs));
  for i := 0 to High(ASpecs) do FSpecs[i] := ASpecs[i];
end;

destructor TBackgroundSpawnCoordinator.Destroy;
var
  i: Integer;
  J: TBgJob;
begin
  { Unregister from the drain map first so the hook can't reach a
    half-destroyed coordinator. }
  if (GMapLock <> nil) and (FKey <> '') then
  begin
    GMapLock.Enter;
    try
      i := GMap.IndexOf(FKey);
      if (i >= 0) and (GMap.Objects[i] = Self) then GMap.Delete(i);
    finally
      GMapLock.Leave;
    end;
  end;

  FLock.Enter;
  try
    for i := 0 to FJobs.Count - 1 do
    begin
      J := TBgJob(FJobs[i]);
      J.FStateLock.Enter;
      try
        if J.FState = bjRunning then
        begin
          { Still working: abandon. The job self-frees when its
            Execute completes. Results are lost -- jobs die with
            the session. }
          J.FAbandoned := True;
          J := nil;
        end;
      finally
        if J <> nil then J.FStateLock.Leave
        else TBgJob(FJobs[i]).FStateLock.Leave;
      end;
      if J <> nil then J.Free;   { finished: TThread.Destroy waits trivially }
    end;
    FJobs.Clear;
  finally
    FLock.Leave;
  end;
  FJobs.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TBackgroundSpawnCoordinator.SetKey(const Key: string);
var
  i: Integer;
begin
  GMapLock.Enter;
  try
    { Move the registration if the key changed. }
    if FKey <> '' then
    begin
      i := GMap.IndexOf(FKey);
      if (i >= 0) and (GMap.Objects[i] = Self) then GMap.Delete(i);
    end;
    FKey := Key;
    if FKey <> '' then GMap.AddObject(FKey, Self);
  finally
    GMapLock.Leave;
  end;
end;

procedure TBackgroundSpawnCoordinator.SetContext(const ACtx: TSubagentContext);
begin
  FLock.Enter;
  try
    FCtx := ACtx;
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.FindSpec(const N: string;
                                              out S: TSubagentSpec): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FSpecs) do
    if SameText(FSpecs[i].Name, N) then
    begin
      S := FSpecs[i];
      Exit(True);
    end;
  Result := False;
end;

function TBackgroundSpawnCoordinator.FindJob(const Handle: string): TBgJob;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FJobs.Count - 1 do
    if TBgJob(FJobs[i]).FHandle = Handle then
      Exit(TBgJob(FJobs[i]));
end;

function TBackgroundSpawnCoordinator.RunningCount: Integer;
var
  i: Integer;
  J: TBgJob;
begin
  Result := 0;
  for i := 0 to FJobs.Count - 1 do
  begin
    J := TBgJob(FJobs[i]);
    J.FStateLock.Enter;
    try
      if J.FState = bjRunning then Inc(Result);
    finally
      J.FStateLock.Leave;
    end;
  end;
end;

function TBackgroundSpawnCoordinator.NewHandle(const Prefix: string): string;
{ 6 hex chars. Unique among the jobs kept: with a history to browse and
  follow-ups addressed by handle, two jobs answering to one would be a
  real mix-up. Caller holds FLock. }
begin
  repeat
    Result := Prefix + RandHex(3);
  until FindJob(Result) = nil;
end;

procedure WireJobLoop(Job: TBgJob; Box: TLoopCfgBox);
{ The loop's callbacks that feed the job's live transcript, and the cancel
  check at its step boundaries. Bound to THIS job -- a follow-up copies
  another job's config and must not keep reporting into that one. }
begin
  Box.Cfg.OnText       := Job.LiveText;
  Box.Cfg.OnToolCall   := Job.LiveToolCall;
  Box.Cfg.OnToolResult := Job.LiveToolResult;
  Box.Cfg.ShouldCancel := Job.CancelAsked;
end;

procedure TBackgroundSpawnCoordinator.PruneHistory;
(* Keep at most BackgroundHistoryMax finished jobs: drop the oldest beyond
   that, first among those whose result already reached the model (drained
   or waited for), then the rest. Only a job whose thread has ended (its
   state is final and Free does not wait) and that nobody holds outside
   the lock (spawn_wait) goes. Caller holds FLock. *)
var
  i, Done, Excess, Pass: Integer;
  J: TBgJob;
begin
  Done := 0;
  for i := 0 to FJobs.Count - 1 do
    if TBgJob(FJobs[i]).Finished then Inc(Done);
  Excess := Done - BackgroundHistoryMax;
  for Pass := 0 to 1 do
  begin
    i := 0;
    while (Excess > 0) and (i < FJobs.Count) do
    begin
      J := TBgJob(FJobs[i]);
      if J.Finished and (J.FPins = 0) and ((Pass = 1) or J.FCollected) then
      begin
        FJobs.Delete(i);
        J.Free;
        Dec(Excess);
      end
      else
        Inc(i);
    end;
  end;
end;

function TBackgroundSpawnCoordinator.SlotsInUse: Integer;
begin
  Result := RunningCount + FReserved;
end;

function TBackgroundSpawnCoordinator.MaxJobs: Integer;
begin
  Result := MaxConcurrentBackground;
  if (FCtx.Cfg <> nil) and (FCtx.Cfg.BackgroundJobsMax > 0) then
    Result := FCtx.Cfg.BackgroundJobsMax;
end;

function ParseArgStr(const ArgsJSON, Field: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetStr(Field, '');
  finally
    Obj.Free;
  end;
end;

function ParseArgInt(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
  finally
    Obj.Free;
  end;
end;

function TBackgroundSpawnCoordinator.HandleSpawnBackground(
  const ArgsJSON: string; out ErrMsg: string): string;
var
  AgentName, Prompt, Model: string;
  Worktree, WorkDir, WtErr: string;
  Spec: TSubagentSpec;
  Job: TBgJob;
  Box: TLoopCfgBox;
  MaxIter: Integer;
  SysPrompt, DeferredSec: string;
begin
  Result := '';
  ErrMsg := '';
  AgentName := ParseArgStr(ArgsJSON, 'agent');
  Prompt    := ParseArgStr(ArgsJSON, 'prompt');
  Worktree  := Trim(ParseArgStr(ArgsJSON, 'worktree'));
  if AgentName = '' then begin ErrMsg := 'spawn_background: agent name required'; Exit; end;
  if Prompt    = '' then begin ErrMsg := 'spawn_background: prompt required'; Exit; end;
  if not FindSpec(AgentName, Spec) then
  begin
    ErrMsg := 'spawn_background: no subagent named "' + AgentName + '"';
    Exit;
  end;
  if (Worktree <> '') and (not WorktreeArgEnabled(FCtx.Cfg)) then
  begin
    ErrMsg := WorktreeDisabledRefusal('spawn_background');
    Exit;
  end;

  (* Claim the slot BEFORE touching the repository.

     The worktree used to be created first and the cap checked after, so
     a spawn the cap was always going to refuse still made a branch and a
     checkout on disk, then returned the capacity error. Checking first
     is not enough on its own -- two spawns in one parallel batch would
     both pass and both create -- so the slot is reserved under the lock,
     the (slow, git) worktree is made outside it, and the reservation
     becomes the job or is handed back. (Codex P2 on #612.) *)
  FLock.Enter;
  try
    if SlotsInUse >= MaxJobs then
    begin
      ErrMsg := Format('spawn_background: %d job(s) already running (cap %d) -- ' +
                       'spawn_wait or spawn_cancel one first',
                       [SlotsInUse, MaxJobs]);
      Exit;
    end;
    Inc(FReserved);
  finally
    FLock.Leave;
  end;

  { The worktree is created on the parent's thread, before the job
    exists: a git failure is this call's error, and the path is known
    when the handle is returned. }
  WorkDir := '';
  if Worktree <> '' then
    if not EnsureWorktree(Worktree, WorkDir, WtErr) then
    begin
      FLock.Enter;
      try
        Dec(FReserved);
      finally
        FLock.Leave;
      end;
      ErrMsg := 'spawn_background: ' + WtErr;
      Exit;
    end;

  FLock.Enter;
  try
    Dec(FReserved);   { the reservation becomes this job, below }

    Model := Spec.Model;
    if Model = '' then Model := FCtx.DefaultModel;
    MaxIter := Spec.MaxIter;
    if MaxIter <= 0 then MaxIter := DefaultSubagentMaxIter;

    Job := TBgJob.Create(True);   { suspended }
    Job.FStateLock := TCriticalSection.Create;
    Job.FKind      := bjkSubagent;
    Job.FHandle    := NewHandle('bg-');
    Job.FAgentName := AgentName;
    Job.FPrompt    := Prompt;
    Job.FState     := bjRunning;
    Job.FStartedAt := Now;
    { Capture on THIS (parent) thread -- the worker thread can't see the
      parent's threadvar-scoped context. }
    Job.FCheckpointHandle := CurrentCheckpointHandle;
    Job.FDrainKey := CurrentDispatchDrainKey;
    if Job.FDrainKey = '' then Job.FDrainKey := FKey;
    Job.FShellSessionId := GetCurrentSessionId;
    Job.FChildReg  := BuildFilteredRegistry(FCtx.ParentRegistry, Spec.Tools);
    Box := TLoopCfgBox.Create;
    { Give a child that inherited deferred MCP tools its own registry-bound
      tool_search + "## Deferred Tools" prompt section -- same progressive
      disclosure as the parent. FChildDisc lives as long as the job (freed in
      the job's destructor with FChildReg). }
    SysPrompt := Spec.SystemPrompt;
    if (FCtx.Cfg <> nil) and (Length(Job.FChildReg.DeferredNames) > 0) then
    begin
      Job.FChildDisc := RegisterMCPDisclosureTools(Job.FChildReg, FCtx.Cfg, False);
      DeferredSec := BuildDeferredToolsSection(Job.FChildReg);
      if DeferredSec <> '' then
        SysPrompt := SysPrompt + sLineBreak + sLineBreak + DeferredSec;
    end;
    Box.Cfg.Provider      := FCtx.Provider;
    Box.Cfg.Registry      := Job.FChildReg;
    Box.Cfg.Model         := Model;
    Box.Cfg.MaxIterations := MaxIter;
    Box.Cfg.Parallel      := True;
    Box.Cfg.Fallbacks     := FCtx.Fallbacks;
    Box.Cfg.FallbackModels := FCtx.FallbackModels;
    Box.Cfg.Options       := DefaultChatOptions;
    ApplyPromptCacheConfig(Box.Cfg.Options, FCtx.PromptCache);
    Box.Cfg.Options.SystemPrompt := SysPrompt;
    WireJobLoop(Job, Box);
    { The job's thread has no thread-scoped context of its own, so what
      the parent's dispatch had is copied in: the worktree, else the
      parent's thread workspace ('' when it has none = the process-wide
      one), and its shell session. }
    if WorkDir <> '' then Box.Cfg.Workspace := WorkDir
    else Box.Cfg.Workspace := ThreadSandboxWorkspace;
    Box.Cfg.ShellSessionId := Job.FShellSessionId;
    if WorkDir <> '' then
      Box.Cfg.Options.SystemPrompt := Box.Cfg.Options.SystemPrompt + sLineBreak + sLineBreak +
        'You are working in the git worktree ' + WorkDir + ' (branch ' + Worktree + '). ' +
        'Relative paths and shell commands resolve there. Commit your work on that branch.';
    Job.FCfg := Box;
    Job.FWorkDir  := WorkDir;
    Job.FWorktree := Worktree;
    FJobs.Add(Job);
    PruneHistory;
    LogInfo('subagent bg-spawn: handle=%s name=%s model=%s tools=%d workspace=%s',
            [Job.FHandle, AgentName, Model, Job.FChildReg.Count, WorkDir]);
    Job.Start;

    Result := Format('started background subagent "%s" -- handle=%s. ' +
                     'Its result will be delivered to you automatically when ' +
                     'it completes; you can keep working meanwhile, or call ' +
                     'spawn_status("%s") / spawn_wait("%s") explicitly.',
                     [AgentName, Job.FHandle, Job.FHandle, Job.FHandle]);
    if WorkDir <> '' then
      Result := Result + ' It works in worktree ' + WorkDir + ' (branch ' + Worktree + ').';
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.HandleShellBackground(
  const ArgsJSON: string; out ErrMsg: string): string;
var
  Cmd, Reason, ReqDir, WorkDir: string;
  TimeoutSec: Integer;
  Job: TBgJob;
begin
  Result := '';
  ErrMsg := '';
  Cmd := ParseArgStr(ArgsJSON, 'command');
  if Cmd = '' then begin ErrMsg := 'shell_background: command required'; Exit; end;
  if not ShellAllowed(Cmd, Reason) then begin ErrMsg := Reason; Exit; end;

  { Same cwd rules as shell_exec: the workspace by default; an explicit cwd
    must exist and, under restriction, sit inside the workspace. }
  WorkDir := CurrentWorkspace;
  ReqDir := Trim(ParseArgStr(ArgsJSON, 'cwd'));
  if ReqDir <> '' then
  begin
    ReqDir := ResolveWorkspacePath(ReqDir);
    if not DirectoryExists(ReqDir) then
    begin
      ErrMsg := 'shell_background: cwd does not exist: ' + ReqDir;
      Exit;
    end;
    if RestrictionActive and (not PathInsideDirectory(ReqDir, CurrentWorkspace)) then
    begin
      ErrMsg := 'shell_background: cwd outside the workspace while restrict_to_workspace is on: ' + ReqDir;
      Exit;
    end;
    WorkDir := ReqDir;
  end;
  if (WorkDir <> '') and (not DirectoryExists(WorkDir)) then WorkDir := '';
  TimeoutSec := ParseArgInt(ArgsJSON, 'timeout_sec', 0);

  FLock.Enter;
  try
    if SlotsInUse >= MaxJobs then
    begin
      ErrMsg := Format('shell_background: %d job(s) already running (cap %d) -- ' +
                       'spawn_wait or spawn_cancel one first', [SlotsInUse, MaxJobs]);
      Exit;
    end;
    Job := TBgJob.Create(True);
    Job.FStateLock := TCriticalSection.Create;
    Job.FKind      := bjkShell;
    Job.FHandle    := NewHandle('sh-');
    Job.FAgentName := 'shell';
    Job.FCommand   := Cmd;
    Job.FWorkDir   := WorkDir;
    if TimeoutSec > 0 then Job.FTimeoutMs := TimeoutSec * 1000
    else Job.FTimeoutMs := EffectiveShellTimeoutMs;
    Job.FState     := bjRunning;
    Job.FStartedAt := Now;
    Job.FCheckpointHandle := CurrentCheckpointHandle;
    Job.FDrainKey := CurrentDispatchDrainKey;
    if Job.FDrainKey = '' then Job.FDrainKey := FKey;
    Job.FShellSessionId := GetCurrentSessionId;
    Job.FChildReg := nil;
    Job.FCfg := nil;
    FJobs.Add(Job);
    PruneHistory;
    LogInfo('shell bg: handle=%s cwd=%s timeout=%dms cmd=%s',
            [Job.FHandle, WorkDir, Job.FTimeoutMs, Copy(Cmd, 1, 120)]);
    Job.Start;
    Result := Format('started background shell -- handle=%s. Its output (exit code first) ' +
                     'is delivered to you automatically when it finishes, as a ' +
                     '[background shell results] block; spawn_status("%s"), ' +
                     'spawn_wait("%s") and spawn_cancel("%s") take this handle too, ' +
                     'and cancel kills the process.',
                     [Job.FHandle, Job.FHandle, Job.FHandle, Job.FHandle]);
  finally
    FLock.Leave;
  end;
end;

function StateLabel(S: TBgJobState): string;
begin
  case S of
    bjRunning:   Result := 'running';
    bjDone:      Result := 'done';
    bjFailed:    Result := 'failed';
    bjCancelled: Result := 'cancelled';
  else           Result := 'unknown';
  end;
end;

function TBackgroundSpawnCoordinator.HandleStatus(
  const ArgsJSON: string; out ErrMsg: string): string;
var
  Handle: string;
  Job: TBgJob;
  ElapsedSec: Int64;
begin
  Result := '';
  ErrMsg := '';
  Handle := ParseArgStr(ArgsJSON, 'handle');
  if Handle = '' then begin ErrMsg := 'spawn_status: handle required'; Exit; end;

  FLock.Enter;
  try
    Job := FindJob(Handle);
    if Job = nil then
    begin
      ErrMsg := 'spawn_status: no job with handle ' + Handle;
      Exit;
    end;
    Job.FStateLock.Enter;
    try
      if Job.FState = bjRunning then
        ElapsedSec := SecondsBetween(Now, Job.FStartedAt)
      else
        ElapsedSec := SecondsBetween(Job.FFinishedAt, Job.FStartedAt);
      if Job.FKind = bjkShell then
        Result := Format('handle=%s shell state=%s elapsed=%ds command=%s',
                         [Job.FHandle, StateLabel(Job.FState), ElapsedSec,
                          Copy(Job.FCommand, 1, 120)])
      else
        Result := Format('handle=%s agent=%s state=%s elapsed=%ds',
                         [Job.FHandle, Job.FAgentName,
                          StateLabel(Job.FState), ElapsedSec]);
      if Job.FState = bjDone then
        Result := Result + sLineBreak +
                  'result preview: ' + Copy(Job.FResultText, 1, 400) +
                  sLineBreak + '(spawn_wait for the full result)';
      if Job.FState = bjFailed then
        Result := Result + sLineBreak + 'error: ' + Job.FErrMsg;
    finally
      Job.FStateLock.Leave;
    end;
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.HandleWait(
  const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultTimeout = 30;
  MaxTimeout     = 120;
var
  Handle: string;
  TimeoutSec: Integer;
  Job: TBgJob;
  Deadline: TDateTime;
  St: TBgJobState;
begin
  Result := '';
  ErrMsg := '';
  Handle := ParseArgStr(ArgsJSON, 'handle');
  if Handle = '' then begin ErrMsg := 'spawn_wait: handle required'; Exit; end;
  TimeoutSec := ParseArgInt(ArgsJSON, 'timeout_sec', DefaultTimeout);
  if TimeoutSec < 1 then TimeoutSec := 1;
  if TimeoutSec > MaxTimeout then TimeoutSec := MaxTimeout;

  { Pinned while this polls outside the lock: a job that finishes meanwhile
    must not be pruned and freed under us by another spawn. }
  FLock.Enter;
  try
    Job := FindJob(Handle);
    if Job <> nil then Inc(Job.FPins);
  finally
    FLock.Leave;
  end;
  if Job = nil then
  begin
    ErrMsg := 'spawn_wait: no job with handle ' + Handle;
    Exit;
  end;

  try
    Deadline := IncSecond(Now, TimeoutSec);
    repeat
      Job.FStateLock.Enter;
      try
        St := Job.FState;
        if St <> bjRunning then
        begin
          case St of
            bjDone:
              begin
                Job.FCollected := True;  { full result delivered here;
                                           don't re-deliver via drain }
                Result := Job.FResultText;
              end;
            bjFailed:    ErrMsg := 'spawn_wait: job failed: ' + Job.FErrMsg;
            bjCancelled: ErrMsg := 'spawn_wait: job was cancelled';
          end;
          Exit;
        end;
      finally
        Job.FStateLock.Leave;
      end;
      Sleep(150);
    until Now >= Deadline;

    Result := Format('(still running after %ds -- handle=%s; its result will ' +
                     'be delivered automatically when ready, or spawn_wait again)',
                     [TimeoutSec, Handle]);
  finally
    FLock.Enter;
    try
      Dec(Job.FPins);
    finally
      FLock.Leave;
    end;
  end;
end;

function TBackgroundSpawnCoordinator.HandleCancel(
  const ArgsJSON: string; out ErrMsg: string): string;
var
  Handle: string;
begin
  Result := '';
  ErrMsg := '';
  Handle := ParseArgStr(ArgsJSON, 'handle');
  if Handle = '' then begin ErrMsg := 'spawn_cancel: handle required'; Exit; end;
  if CancelJob(Handle, Result) = bcoNotFound then
  begin
    Result := '';
    ErrMsg := 'spawn_cancel: no job with handle ' + Handle;
  end;
end;

function TBackgroundSpawnCoordinator.CancelJob(const Handle: string;
                                               out Msg: string): TBgCancelOutcome;
var
  Job: TBgJob;
begin
  Msg := '';
  FLock.Enter;
  try
    Job := FindJob(Handle);
    if Job = nil then Exit(bcoNotFound);
    Job.FStateLock.Enter;
    try
      if Job.FState = bjRunning then
      begin
        Job.FState := bjCancelled;
        if (Job.FKind = bjkShell) and (Job.FProc <> nil) then
        begin
          { A shell job on the local backend has a process to kill. The
            job's own thread does the killing: its run loop polls the
            state every few tens of milliseconds and calls Terminate on
            the process it owns. Not from here -- TProcess is not
            thread-safe, and a Terminate racing the owner's Running /
            ReadAvailable is a double reap. }
          Msg := 'job ' + Handle + ' killed';
          Result := bcoKilled;
        end
        else if Job.FKind = bjkShell then
        begin
          { A shell job on a non-local backend: nothing to kill from here;
            the cancelled marker makes the job discard its result. }
          Msg := 'job ' + Handle + ' marked cancelled; its result will be ' +
                 'discarded (the command runs in the shell backend and ' +
                 'is not killed from here)';
          Result := bcoAdvisory;
        end
        else
        begin
          { A subagent: its loop checks at each step boundary (ShouldCancel)
            and stops there, so a model call already on the wire finishes
            first; the cancelled marker makes Execute discard the result. }
          Msg := 'job ' + Handle + ' marked cancelled; it stops at its next ' +
                 'step (a model call already in flight finishes first) and ' +
                 'its result will be discarded';
          Result := bcoAdvisory;
        end;
      end
      else
      begin
        Msg := 'job ' + Handle + ' already ' + StateLabel(Job.FState);
        Result := bcoAlreadyFinished;
      end;
    finally
      Job.FStateLock.Leave;
    end;
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.DrainFinishedBlock(MaxChars: Integer;
                                                        const Key: string): string;
var
  i: Integer;
  Job: TBgJob;
  Block, ShellBlock, Entry, Preview, Who: string;
begin
  Result := '';
  if MaxChars <= 0 then MaxChars := 8192;
  Block := '';
  ShellBlock := '';
  FLock.Enter;
  try
    for i := 0 to FJobs.Count - 1 do
    begin
      Job := TBgJob(FJobs[i]);
      Job.FStateLock.Enter;
      try
        if Job.FCollected or (Job.FState = bjRunning) or
           (Job.FState = bjCancelled) then
          Continue;
        if (Key <> '') and (Job.FDrainKey <> Key) then
          Continue;   { another session's job; its own turn will collect it }
        if Job.FKind = bjkShell then
          Who := 'shell "' + Copy(Job.FCommand, 1, 80) + '"'
        else
          Who := 'agent "' + Job.FAgentName + '"';
        { A follow-up the operator sent from the Background view: the model
          did not start it, so say what it continues. }
        if Job.FContinuedFrom <> '' then
          Who := Who + ', follow-up to ' + Job.FContinuedFrom + ': "' +
                 Utf8SafeTruncate(Job.FPrompt, 200) + '"';
        if Job.FState = bjDone then
        begin
          Preview := Job.FResultText;
          if Length(Preview) > DrainPreviewChars then
            Preview := Copy(Preview, 1, DrainPreviewChars) +
                       Format('... (truncated -- spawn_wait("%s") for the full %d chars)',
                              [Job.FHandle, Length(Job.FResultText)]);
          Entry := Format('- %s (%s) completed:%s%s',
                          [Job.FHandle, Who, sLineBreak, Preview]);
        end
        else  { bjFailed }
          Entry := Format('- %s (%s) FAILED: %s',
                          [Job.FHandle, Who, Job.FErrMsg]);
        if Length(Block) + Length(ShellBlock) + Length(Entry) > MaxChars then Break;
        Job.FCollected := True;
        if Job.FKind = bjkShell then
        begin
          if ShellBlock <> '' then ShellBlock := ShellBlock + sLineBreak;
          ShellBlock := ShellBlock + Entry;
        end
        else
        begin
          if Block <> '' then Block := Block + sLineBreak;
          Block := Block + Entry;
        end;
      finally
        Job.FStateLock.Leave;
      end;
    end;
  finally
    FLock.Leave;
  end;
  if Block <> '' then
    Result := '[background subagent results]' + sLineBreak + Block;
  if ShellBlock <> '' then
  begin
    if Result <> '' then Result := Result + sLineBreak;
    Result := Result + '[background shell results]' + sLineBreak + ShellBlock;
  end;
end;

{ --------------------------- viewers ----------------------------- }

function OutputTail(const S: string; MaxLen: Integer; out Cut: Boolean): string;
{ The last MaxLen characters of S, starting on a character boundary. }
var
  P: Integer;
begin
  Cut := Length(S) > MaxLen;
  if not Cut then Exit(S);
  P := Length(S) - MaxLen + 1;
  {$IFDEF FPC}
  while (P <= Length(S)) and ((Byte(S[P]) and $C0) = $80) do Inc(P);
  {$ELSE}
  if (Ord(S[P]) >= $DC00) and (Ord(S[P]) <= $DFFF) then Inc(P);
  {$ENDIF}
  Result := Copy(S, P, MaxLen);
end;

procedure TBackgroundSpawnCoordinator.FillInfo(J: TBgJob; WithDetail: Boolean;
                                               out Info: TBgJobInfo);
var
  Raw: string;
  B: TBytes;
  i, NL: Integer;
begin
  Info := Default(TBgJobInfo);
  J.FStateLock.Enter;
  try
    Info.Handle    := J.FHandle;
    if J.FKind = bjkShell then Info.Kind := 'shell' else Info.Kind := 'subagent';
    Info.AgentName := J.FAgentName;
    Info.Command   := J.FCommand;
    Info.Prompt    := J.FPrompt;
    Info.State     := StateLabel(J.FState);
    Info.Session   := J.FDrainKey;
    Info.StartedAt := J.FStartedAt;
    Info.FinishedAt := J.FFinishedAt;   { 0 until the thread is done }
    Info.Stopping  := (J.FState = bjCancelled) and (J.FFinishedAt = 0);
    if J.FFinishedAt = 0 then
      Info.ElapsedSec := SecondsBetween(Now, J.FStartedAt)
    else
      Info.ElapsedSec := SecondsBetween(J.FFinishedAt, J.FStartedAt);
    Info.ResultText := J.FResultText;
    Info.ErrMsg     := J.FErrMsg;
    Info.ExitCode   := -1;
    if (J.FKind = bjkShell) and (J.FFinishedAt <> 0) then Info.ExitCode := J.FExitCode;
    Info.Collected  := J.FCollected;
    Info.Killable   := (J.FKind = bjkShell) and (J.FProc <> nil) and (J.FState = bjRunning);
    Info.Worktree   := J.FWorktree;
    Info.ContinuedFrom := J.FContinuedFrom;
    Info.ContinuedBy   := J.FContinuedBy;
    if not WithDetail then Exit;
    if J.FKind = bjkSubagent then
    begin
      { A copy: FMessages goes on changing on the job's thread. }
      Info.Messages := Copy(J.FMessages, 0, Length(J.FMessages));
      Info.Trimmed  := J.FTrimmed;
    end
    else if J.FFinishedAt = 0 then
    begin
      B := Copy(J.FLiveOut, 0, Length(J.FLiveOut));
      { The tail may start inside a character; begin at the next one, or
        the decoder takes the whole tail for a legacy codepage. }
      i := 0;
      while (i < Length(B)) and (i < 3) and ((B[i] and $C0) = $80) do Inc(i);
      if i > 0 then B := Copy(B, i, Length(B) - i);
      if Length(B) > 0 then Info.Output := DecodeShellOutputBytes(B, Length(B));
      Info.OutputTruncated := Length(J.FLiveOut) >= BgOutputViewChars;
    end
    else
    begin
      { The result is "exit=N" then the output; the code is ExitCode. }
      Raw := J.FResultText;
      if Raw = '' then Raw := J.FErrMsg
      else
      begin
        NL := Pos(#10, Raw);
        if (NL > 0) and (Copy(Raw, 1, 5) = 'exit=') then Raw := Copy(Raw, NL + 1, MaxInt);
      end;
      Info.Output := OutputTail(Raw, BgOutputViewChars, Info.OutputTruncated);
    end;
  finally
    J.FStateLock.Leave;
  end;
end;

procedure TBackgroundSpawnCoordinator.AppendInfos(var Arr: TBgJobInfoArray);
var
  i, N: Integer;
begin
  FLock.Enter;
  try
    N := Length(Arr);
    SetLength(Arr, N + FJobs.Count);
    for i := 0 to FJobs.Count - 1 do
      FillInfo(TBgJob(FJobs[i]), False, Arr[N + i]);
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.GetInfo(const Handle: string;
                                             out Info: TBgJobInfo): Boolean;
var
  J: TBgJob;
begin
  FLock.Enter;
  try
    J := FindJob(Handle);
    Result := J <> nil;
    if Result then FillInfo(J, True, Info)
    else Info := Default(TBgJobInfo);
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.ContinueJob(const Handle, Text: string;
  out NewJobHandle, Msg: string): TBgContinueOutcome;
(* A follow-up to a finished subagent: a new job whose history is the old
   job's transcript, whose prompt is Text, and which runs as the old one
   did -- same agent, model, workspace or worktree, shell session,
   checkpoint session and chat (so its result is delivered to that chat's
   next turn, like any job of it). The old job's final system prompt is
   used when it has one: a compaction summary lives there.

   The transcript is the bounded copy (BoundTranscript): what was cut for
   the view is cut for the follow-up too. *)
var
  Old, Job: TBgJob;
  Spec: TSubagentSpec;
  Box: TLoopCfgBox;
  Hist: TMessageArray;
  SysPrompt: string;
  Busy: Boolean;
begin
  NewJobHandle := '';
  Msg := '';
  if Trim(Text) = '' then
  begin
    Msg := 'the message is empty';
    Exit(bmoEmptyText);
  end;
  FLock.Enter;
  try
    Old := FindJob(Handle);
    if Old = nil then
    begin
      Msg := 'no job with handle ' + Handle;
      Exit(bmoNotFound);
    end;
    if Old.FKind <> bjkSubagent then
    begin
      Msg := 'job ' + Handle + ' is a shell command, not a subagent: there is ' +
             'no conversation to continue';
      Exit(bmoNotSubagent);
    end;
    Old.FStateLock.Enter;
    try
      { Still running, or cancelled but still finishing a model call: its
        transcript is not final yet. }
      Busy := Old.FFinishedAt = 0;
      Hist := Copy(Old.FMessages, 0, Length(Old.FMessages));
      SysPrompt := Old.FFinalSystemPrompt;
    finally
      Old.FStateLock.Leave;
    end;
    if Busy then
    begin
      Msg := 'job ' + Handle + ' is still running; message it once it has finished';
      Exit(bmoRunning);
    end;
    if not FindSpec(Old.FAgentName, Spec) then
    begin
      Msg := 'no subagent named "' + Old.FAgentName + '" any more';
      Exit(bmoNoSuchAgent);
    end;
    if SlotsInUse >= MaxJobs then
    begin
      Msg := Format('%d job(s) already running (cap %d); try again when one ' +
                    'has finished', [SlotsInUse, MaxJobs]);
      Exit(bmoAtCap);
    end;

    Job := TBgJob.Create(True);   { suspended }
    Job.FStateLock := TCriticalSection.Create;
    Job.FKind      := bjkSubagent;
    Job.FHandle    := NewHandle('bg-');
    Job.FAgentName := Old.FAgentName;
    Job.FPrompt    := Text;
    Job.FState     := bjRunning;
    Job.FStartedAt := Now;
    Job.FCheckpointHandle := Old.FCheckpointHandle;
    Job.FDrainKey  := Old.FDrainKey;
    Job.FShellSessionId := Old.FShellSessionId;
    Job.FWorkDir   := Old.FWorkDir;
    Job.FWorktree  := Old.FWorktree;
    Job.FSeedHistory := Hist;
    Job.FContinuedFrom := Old.FHandle;
    Job.FChildReg  := BuildFilteredRegistry(FCtx.ParentRegistry, Spec.Tools);
    { The old job's loop settings (model, iterations, fallbacks, prompt
      options, workspace, shell session) on a registry of its own: the old
      job owns its registry and may be pruned while this one runs. }
    Box := TLoopCfgBox.Create;
    Box.Cfg := TLoopCfgBox(Old.FCfg).Cfg;
    Box.Cfg.Registry := Job.FChildReg;
    if (FCtx.Cfg <> nil) and (Length(Job.FChildReg.DeferredNames) > 0) then
      Job.FChildDisc := RegisterMCPDisclosureTools(Job.FChildReg, FCtx.Cfg, False);
    if SysPrompt <> '' then Box.Cfg.Options.SystemPrompt := SysPrompt;
    WireJobLoop(Job, Box);
    Job.FCfg := Box;
    Old.FStateLock.Enter;
    try
      Old.FContinuedBy := Job.FHandle;
    finally
      Old.FStateLock.Leave;
    end;
    FJobs.Add(Job);
    PruneHistory;
    LogInfo('subagent bg-follow-up: handle=%s continues=%s name=%s history=%d',
            [Job.FHandle, Handle, Job.FAgentName, Length(Hist)]);
    NewJobHandle := Job.FHandle;
    Job.Start;
    Result := bmoStarted;
  finally
    FLock.Leave;
  end;
end;

{ Every coordinator, under GMapLock, which the caller holds. The lock keeps
  a key-registered coordinator from being destroyed while it is used
  (Destroy unregisters under it first); the module-owned ones live until
  finalization. Lock order is GMapLock, then a coordinator's FLock --
  nothing takes them the other way round. }
procedure CollectCoordinators(L: TList);
var
  i: Integer;
begin
  for i := 0 to GMap.Count - 1 do
    if L.IndexOf(GMap.Objects[i]) < 0 then L.Add(GMap.Objects[i]);
  if GCoordinators <> nil then
    for i := 0 to GCoordinators.Count - 1 do
      if L.IndexOf(GCoordinators[i]) < 0 then L.Add(GCoordinators[i]);
end;

function JobSortsBefore(const A, B: TBgJobInfo): Boolean;
{ Running (and still-stopping) first, then newest first. }
var
  ALive, BLive: Boolean;
begin
  ALive := A.FinishedAt = 0;
  BLive := B.FinishedAt = 0;
  if ALive <> BLive then Exit(ALive);
  Result := A.StartedAt > B.StartedAt;
end;

function ListBackgroundJobs: TBgJobInfoArray;
var
  L: TList;
  i, j: Integer;
  Tmp: TBgJobInfo;
begin
  Result := nil;
  if GMapLock = nil then Exit;
  L := TList.Create;
  try
    GMapLock.Enter;
    try
      CollectCoordinators(L);
      for i := 0 to L.Count - 1 do
        TBackgroundSpawnCoordinator(L[i]).AppendInfos(Result);
    finally
      GMapLock.Leave;
    end;
  finally
    L.Free;
  end;
  { Insertion sort: a few dozen entries. }
  for i := 1 to High(Result) do
  begin
    Tmp := Result[i];
    j := i - 1;
    while (j >= 0) and JobSortsBefore(Tmp, Result[j]) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Result[j + 1] := Tmp;
  end;
end;

function GetBackgroundJob(const Handle: string; out Info: TBgJobInfo): Boolean;
var
  L: TList;
  i: Integer;
begin
  Result := False;
  Info := Default(TBgJobInfo);
  if (GMapLock = nil) or (Handle = '') then Exit;
  L := TList.Create;
  try
    GMapLock.Enter;
    try
      CollectCoordinators(L);
      for i := 0 to L.Count - 1 do
        if TBackgroundSpawnCoordinator(L[i]).GetInfo(Handle, Info) then Exit(True);
    finally
      GMapLock.Leave;
    end;
  finally
    L.Free;
  end;
end;

function CancelBackgroundJob(const Handle: string; out Msg: string): TBgCancelOutcome;
var
  L: TList;
  i: Integer;
begin
  Result := bcoNotFound;
  Msg := 'no job with handle ' + Handle;
  if (GMapLock = nil) or (Handle = '') then Exit;
  L := TList.Create;
  try
    GMapLock.Enter;
    try
      CollectCoordinators(L);
      for i := 0 to L.Count - 1 do
      begin
        Result := TBackgroundSpawnCoordinator(L[i]).CancelJob(Handle, Msg);
        if Result <> bcoNotFound then Exit;
      end;
      Msg := 'no job with handle ' + Handle;
    finally
      GMapLock.Leave;
    end;
  finally
    L.Free;
  end;
end;

function ContinueBackgroundJob(const Handle, Text: string;
                               out NewHandle, Msg: string): TBgContinueOutcome;
var
  L: TList;
  i: Integer;
begin
  Result := bmoNotFound;
  NewHandle := '';
  Msg := 'no job with handle ' + Handle;
  if (GMapLock = nil) or (Handle = '') then Exit;
  L := TList.Create;
  try
    GMapLock.Enter;
    try
      CollectCoordinators(L);
      for i := 0 to L.Count - 1 do
      begin
        Result := TBackgroundSpawnCoordinator(L[i]).ContinueJob(Handle, Text, NewHandle, Msg);
        if Result <> bmoNotFound then Exit;
      end;
      Msg := 'no job with handle ' + Handle;
    finally
      GMapLock.Leave;
    end;
  finally
    L.Free;
  end;
end;

function FormatBackgroundJobsText: string;
var
  Jobs: TBgJobInfoArray;
  i: Integer;
  What, St: string;
begin
  Jobs := ListBackgroundJobs;
  if Length(Jobs) = 0 then
    Exit('no background jobs -- the model starts them with spawn_background ' +
         '(a subagent) or shell_background (a command)');
  Result := '';
  for i := 0 to High(Jobs) do
  begin
    if Jobs[i].Kind = 'shell' then
      What := 'shell: ' + Utf8SafeTruncate(Jobs[i].Command, 60)
    else
      What := Jobs[i].AgentName + ': ' +
              Utf8SafeTruncate(StringReplace(Jobs[i].Prompt, #10, ' ', [rfReplaceAll]), 60);
    St := Jobs[i].State;
    if Jobs[i].Stopping then St := 'stopping';
    if (Jobs[i].Kind = 'shell') and (Jobs[i].ExitCode >= 0) then
      St := St + Format(' exit=%d', [Jobs[i].ExitCode]);
    if Result <> '' then Result := Result + sLineBreak;
    Result := Result + Format('  %-9s  %-16s %5ds  %s', [Jobs[i].Handle, St,
                              Jobs[i].ElapsedSec, What]);
  end;
end;

function BackgroundJobsSummary: string;
var
  Jobs: TBgJobInfoArray;
  i, Live, Done: Integer;
  Names: string;
begin
  Jobs := ListBackgroundJobs;
  Live := 0;
  Done := 0;
  Names := '';
  for i := 0 to High(Jobs) do
    if Jobs[i].FinishedAt = 0 then
    begin
      Inc(Live);
      if Names <> '' then Names := Names + ', ';
      Names := Names + Jobs[i].Handle + ' ' + Jobs[i].AgentName;
    end
    else
      Inc(Done);
  if Live + Done = 0 then Exit('no background jobs');
  Result := Format('background: %d running, %d finished', [Live, Done]);
  if Names <> '' then Result := Result + ' -- ' + Names;
end;

{ ------------------- drain hook + registration -------------------- }

function DrainByKey(const Key: string; MaxChars: Integer): string;
(* Called at the top of each loop iteration with the loop's
   BackgroundDrainKey. Two shapes of caller:
     - TUI / CLI: one coordinator per process, SetKey(session) called, so
       the map lookup finds it and every job it holds belongs to that
       session.
     - gateway / serve: one coordinator shared by every session, no key
       set. Jobs are stamped with the spawning dispatch's drain key, so
       walk every coordinator and take only the jobs stamped with ours.
   The map path is kept first because it is the cheap one; the walk picks
   up what the map cannot know about. Each job is delivered once either
   way (FCollected). *)
var
  i: Integer;
  Coord: TBackgroundSpawnCoordinator;
  Part: string;
  Coords: TList;
begin
  Result := '';
  if (Key = '') or (GMapLock = nil) then Exit;
  if MaxChars <= 0 then MaxChars := 8192;
  Coords := TList.Create;
  try
    GMapLock.Enter;
    try
      i := GMap.IndexOf(Key);
      if i >= 0 then Coords.Add(GMap.Objects[i]);
      if GCoordinators <> nil then
        for i := 0 to GCoordinators.Count - 1 do
          if Coords.IndexOf(GCoordinators[i]) < 0 then Coords.Add(GCoordinators[i]);
    finally
      GMapLock.Leave;
    end;
    { Drain outside the map lock -- DrainFinishedBlock takes the
      coordinator + job locks and there's no need to serialise map
      lookups behind a potentially slow drain. }
    for i := 0 to Coords.Count - 1 do
    begin
      Coord := TBackgroundSpawnCoordinator(Coords[i]);
      Part := Coord.DrainFinishedBlock(MaxChars - Length(Result), Key);
      if Part = '' then Continue;
      if Result = '' then Result := Part
      else Result := Result + sLineBreak + Part;
      if Length(Result) >= MaxChars then Break;
    end;
  finally
    Coords.Free;
  end;
end;

function RegisterBackgroundSpawnTools(Reg: TToolRegistry;
                                      const Ctx: TSubagentContext;
                                      const Specs: TSubagentSpecArray)
                                      : TBackgroundSpawnCoordinator;
var
  T: TTool;
  Names: string;
  i: Integer;
begin
  Result := nil;
  if Reg = nil then Exit;

  Result := TBackgroundSpawnCoordinator.Create(Ctx, Specs);
  if GCoordinators = nil then GCoordinators := TList.Create;
  GCoordinators.Add(Result);

  Names := '';
  for i := 0 to High(Specs) do
  begin
    if Names <> '' then Names := Names + ', ';
    Names := Names + '"' + Specs[i].Name + '"';
  end;

  (* spawn_background is the only tool here that needs a subagent to
     spawn, so it is the only one Specs gates. shell_background and the
     three handle verbs are shell features that happen to share this
     coordinator's handle space, and gating the whole routine on Specs
     meant subagents_enabled:false silently took the background shell
     away with them -- which the docs describe as a shell tool with no
     such dependency. (Codex P2 on #619.) *)
  if Length(Specs) > 0 then
  begin
    T.Name        := 'spawn_background';
    T.Description := 'Start a subagent in the BACKGROUND and keep working -- ' +
                     'returns a handle immediately instead of blocking like ' +
                     '`spawn` does. The result is delivered to you ' +
                     'automatically when the job finishes (you''ll see a ' +
                     '[background subagent results] block). Use for slow ' +
                     'research / analysis you don''t need before your next ' +
                     'step. Available subagents: ' + Names + '. ' +
                     'Cap: ' + IntToStr(MaxConcurrentBackground) + ' concurrent.';
    { worktree is advertised only when the feature is on -- a property
      the handler would refuse is worse than none. }
    if WorktreeArgEnabled(Ctx.Cfg) then
      T.Schema :=
        '{"type":"object","properties":{' +
        '"agent":{"type":"string","description":"Name of the subagent to spawn."},' +
        '"prompt":{"type":"string","description":"The prompt to hand the subagent."},' +
        '"worktree":{"type":"string","description":"Optional git branch: run the subagent in a worktree for it (created if needed), so parallel jobs edit separate checkouts."}},' +
        '"required":["agent","prompt"]}'
    else
      T.Schema :=
        '{"type":"object","properties":{' +
        '"agent":{"type":"string","description":"Name of the subagent to spawn."},' +
        '"prompt":{"type":"string","description":"The prompt to hand the subagent."}},' +
        '"required":["agent","prompt"]}';
    T.Handler     := nil;
    T.HandlerObj  := Result.HandleSpawnBackground;
    T.IsCore      := True;
    T.Category    := tcMutating;
    Reg.Register(T);
  end;

  T.Name        := 'shell_background';
  T.Description := 'Run a shell command in the BACKGROUND and keep working -- ' +
                   'returns an sh-<hex> handle immediately instead of blocking ' +
                   'like shell_exec. Output (exit code on line 1) is delivered ' +
                   'to you automatically when it finishes, as a [background shell ' +
                   'results] block; spawn_status / spawn_wait / spawn_cancel take ' +
                   'the handle, and cancel kills the process. Same denylist, cwd ' +
                   'rules and default timeout as shell_exec. Use it for builds, ' +
                   'test suites and anything else you do not need before your ' +
                   'next step.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"command":{"type":"string","description":"Shell command to run."},' +
    '"cwd":{"type":"string","description":"Directory to run in. Defaults to the workspace."},' +
    '"timeout_sec":{"type":"integer","description":"Wall-clock limit in seconds; killed with exit=124 on expiry. Default: shell_timeout_sec."}},' +
    '"required":["command"]}';
  T.Handler     := nil;
  T.HandlerObj  := Result.HandleShellBackground;
  T.IsCore      := True;
  T.Category    := tcMutating;
  Reg.Register(T);

  T.Name        := 'spawn_status';
  T.Description := 'Check on a background job started with spawn_background ' +
                   'or shell_background. Returns state (running / done / ' +
                   'failed / cancelled), elapsed seconds, and a result ' +
                   'preview when done.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"handle":{"type":"string","description":"Handle returned by spawn_background."}},' +
    '"required":["handle"]}';
  T.Handler     := nil;
  T.HandlerObj  := Result.HandleStatus;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Reg.Register(T);

  T.Name        := 'spawn_wait';
  T.Description := 'Block until a background job (subagent or shell) finishes ' +
                   '(or timeout_sec elapses, default 30, max 120) and return ' +
                   'its FULL result. Use when you''ve run out of other ' +
                   'work and need the answer now, or when a delivered ' +
                   'preview was truncated.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"handle":{"type":"string","description":"Handle returned by spawn_background."},' +
    '"timeout_sec":{"type":"integer","minimum":1,"maximum":120,' +
                   '"description":"Max seconds to wait (default 30)."}},' +
    '"required":["handle"]}';
  T.Handler     := nil;
  T.HandlerObj  := Result.HandleWait;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Reg.Register(T);

  T.Name        := 'spawn_cancel';
  T.Description := 'Cancel a background job. A shell job is killed. A ' +
                   'subagent stops at its next step (a model call already ' +
                   'in flight finishes first); its result is discarded.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"handle":{"type":"string","description":"Handle returned by spawn_background."}},' +
    '"required":["handle"]}';
  T.Handler     := nil;
  T.HandlerObj  := Result.HandleCancel;
  T.IsCore      := True;
  T.Category    := tcMutating;
  Reg.Register(T);
end;

procedure RegisterSubagentTools(Cfg: TConfig; Provider: ILLMProvider;
                                Reg: TToolRegistry; const DefaultModel: string);
var
  Ctx: TSubagentContext;
  Specs: TSubagentSpecArray;
begin
  if (Reg = nil) or (Provider = nil) then Exit;
  Specs := ResolveSubagentSpecs(Cfg);   { empty when subagents are disabled }
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg, Ctx.FallbackModels);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := DefaultModel;
  Ctx.PromptCache    := Cfg.PromptCache;
  Ctx.Cfg            := Cfg;
  { `spawn` needs a subagent; the background tools include the shell
    ones, which do not -- see the note in RegisterBackgroundSpawnTools. }
  if Length(Specs) > 0 then RegisterSpawnTool(Reg, Ctx, Specs);
  RegisterBackgroundSpawnTools(Reg, Ctx, Specs);
end;

procedure FreeCoordinators;
var
  i: Integer;
begin
  if GCoordinators = nil then Exit;
  for i := 0 to GCoordinators.Count - 1 do
    TBackgroundSpawnCoordinator(GCoordinators[i]).Free;
  GCoordinators.Free;
  GCoordinators := nil;
end;

initialization
  GMap     := TStringList.Create;
  GMapLock := TCriticalSection.Create;
  GDoneHookLock := TCriticalSection.Create;
  GBackgroundDrainHook := DrainByKey;

finalization
  GBackgroundDrainHook := nil;
  SetBackgroundDoneHook(nil);
  FreeCoordinators;
  GMap.Free;
  GMapLock.Free;
  GMapLock := nil;
  { Nil but deliberately NOT freed. A job thread can outlive this unit --
    the TUI hands a slow worker to the OS via FreeOnTerminate -- and
    freeing the lock it may be about to take is the very use-after-free
    this dispatcher exists to prevent. Nil makes Set/Fire bail out
    ("no hook"); leaking one critical section at process exit is
    harmless, and the TUI leaks FToolActivityLock for the same reason. }
  GDoneHook     := nil;
  GDoneHookLock := nil;

end.
