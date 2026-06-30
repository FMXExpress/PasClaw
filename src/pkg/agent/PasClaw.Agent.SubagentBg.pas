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
    - Cancel is advisory: RunToolLoop doesn't poll Terminated, so a
      cancelled job keeps running until its current provider call
      completes; its result is then discarded. Same limitation the
      TUI's bounded-wait teardown has.
    - Coordinator teardown abandons still-running jobs: they're
      flagged, self-free on completion, and die with the process.
      Their results are lost -- consistent with "background jobs
      live and die with the session".

  Concurrency cap: MaxConcurrentBackground (4). The 5th spawn gets
  a clean error telling the model to wait for or cancel something.
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

type
  TBgJobState = (bjRunning, bjDone, bjFailed, bjCancelled);

  TBgJob = class(TThread)
  private
    FStateLock:  TCriticalSection;
    FHandle:     string;
    FAgentName:  string;
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
    FState:      TBgJobState;
    FCollected:  Boolean;            { delivered via drain already }
    FAbandoned:  Boolean;            { coordinator gone; self-free }
    FStartedAt:  TDateTime;
    FFinishedAt: TDateTime;
  protected
    procedure Execute; override;
  public
    destructor Destroy; override;
  end;

  TBackgroundSpawnCoordinator = class
  private
    FLock:  TCriticalSection;
    FJobs:  TList;
    FCtx:   TSubagentContext;
    FSpecs: TSubagentSpecArray;
    FKey:   string;
    function FindSpec(const N: string; out S: TSubagentSpec): Boolean;
    function FindJob(const Handle: string): TBgJob;
    function RunningCount: Integer;
    function NewHandle: string;
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
    function HandleStatus(const ArgsJSON: string; out ErrMsg: string): string;
    function HandleWait(const ArgsJSON: string; out ErrMsg: string): string;
    function HandleCancel(const ArgsJSON: string; out ErrMsg: string): string;

    { Collect finished-and-not-yet-delivered jobs into a formatted
      block for the loop-top system-prompt fold. Marks them
      delivered (drain-once). Returns '' when nothing is pending.
      MaxChars bounds the total block size. }
    function DrainFinishedBlock(MaxChars: Integer): string;
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

{ One-call wiring of the synchronous `spawn` + the background spawn tools onto
  Reg, for surfaces that don't track the returned tool/coordinator (serve,
  gateway). Builds the TSubagentContext from Cfg/Provider/Reg, resolves the
  effective specs (built-in general-purpose + any configured; empty when
  subagents are disabled), and registers both. No-op when subagents are off or
  there's no provider/registry. The created tools live for the process (Reg
  dispatches through their method pointers), which is the server lifetime. }
procedure RegisterSubagentTools(Cfg: TConfig; Provider: ILLMProvider;
                                Reg: TToolRegistry; const DefaultModel: string);

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.Factory,   { ResolveFallbacks for RegisterSubagentTools }
  PasClaw.MCP.Disclosure,      { per-registry tool_search for bg subagents }
  PasClaw.Crypto.Random,
  PasClaw.Checkpoints,
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

procedure TBgJob.Execute;
var
  Hist: TMessageArray;
  Loop: TToolLoopResult;
  Ok: Boolean;
begin
  Ok := False;
  try
    { Run this background loop under the parent's checkpoint session so
      its fs_write / fs_edit snapshots fold into the parent's turn (the
      worker thread starts with no context of its own). No-op when the
      parent had checkpoints off. }
    AdoptCheckpointHandle(FCheckpointHandle);
    SetLength(Hist, 1);
    Hist[0] := MakeMessage(mrUser, FPrompt);
    Ok := RunToolLoop(TLoopCfgBox(FCfg).Cfg, Hist, Loop);
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

  FStateLock.Enter;
  try
    FFinishedAt := Now;
    if FState = bjCancelled then
      { Keep the cancelled marker; result discarded by policy. }
    else if Ok then
    begin
      FState      := bjDone;
      FResultText := Loop.Content;
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

function TBackgroundSpawnCoordinator.NewHandle: string;
begin
  Result := 'bg-' + RandHex(3);   { 6 hex chars; per-session scope }
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
  if AgentName = '' then begin ErrMsg := 'spawn_background: agent name required'; Exit; end;
  if Prompt    = '' then begin ErrMsg := 'spawn_background: prompt required'; Exit; end;
  if not FindSpec(AgentName, Spec) then
  begin
    ErrMsg := 'spawn_background: no subagent named "' + AgentName + '"';
    Exit;
  end;

  FLock.Enter;
  try
    if RunningCount >= MaxConcurrentBackground then
    begin
      ErrMsg := Format('spawn_background: %d job(s) already running (cap %d) -- ' +
                       'spawn_wait or spawn_cancel one first',
                       [RunningCount, MaxConcurrentBackground]);
      Exit;
    end;

    Model := Spec.Model;
    if Model = '' then Model := FCtx.DefaultModel;
    MaxIter := Spec.MaxIter;
    if MaxIter <= 0 then MaxIter := 4;

    Job := TBgJob.Create(True);   { suspended }
    Job.FStateLock := TCriticalSection.Create;
    Job.FHandle    := NewHandle;
    Job.FAgentName := AgentName;
    Job.FPrompt    := Prompt;
    Job.FState     := bjRunning;
    Job.FStartedAt := Now;
    { Capture on THIS (parent) thread -- the worker thread can't see the
      parent's threadvar-scoped context. }
    Job.FCheckpointHandle := CurrentCheckpointHandle;
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
    Box.Cfg.OnText        := nil;
    Box.Cfg.OnToolCall    := nil;
    Box.Cfg.OnToolResult  := nil;
    Job.FCfg := Box;
    FJobs.Add(Job);
    LogInfo('subagent bg-spawn: handle=%s name=%s model=%s tools=%d',
            [Job.FHandle, AgentName, Model, Job.FChildReg.Count]);
    Job.Start;

    Result := Format('started background subagent "%s" -- handle=%s. ' +
                     'Its result will be delivered to you automatically when ' +
                     'it completes; you can keep working meanwhile, or call ' +
                     'spawn_status("%s") / spawn_wait("%s") explicitly.',
                     [AgentName, Job.FHandle, Job.FHandle, Job.FHandle]);
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

  FLock.Enter;
  try
    Job := FindJob(Handle);
  finally
    FLock.Leave;
  end;
  if Job = nil then
  begin
    ErrMsg := 'spawn_wait: no job with handle ' + Handle;
    Exit;
  end;

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
end;

function TBackgroundSpawnCoordinator.HandleCancel(
  const ArgsJSON: string; out ErrMsg: string): string;
var
  Handle: string;
  Job: TBgJob;
begin
  Result := '';
  ErrMsg := '';
  Handle := ParseArgStr(ArgsJSON, 'handle');
  if Handle = '' then begin ErrMsg := 'spawn_cancel: handle required'; Exit; end;

  FLock.Enter;
  try
    Job := FindJob(Handle);
    if Job = nil then
    begin
      ErrMsg := 'spawn_cancel: no job with handle ' + Handle;
      Exit;
    end;
    Job.FStateLock.Enter;
    try
      if Job.FState = bjRunning then
      begin
        Job.FState := bjCancelled;
        { Advisory only: the worker keeps running until its current
          provider call returns; the cancelled marker makes Execute
          discard the result. }
        Result := 'job ' + Handle + ' marked cancelled; its result will be discarded';
      end
      else
        Result := 'job ' + Handle + ' already ' + StateLabel(Job.FState);
    finally
      Job.FStateLock.Leave;
    end;
  finally
    FLock.Leave;
  end;
end;

function TBackgroundSpawnCoordinator.DrainFinishedBlock(MaxChars: Integer): string;
var
  i: Integer;
  Job: TBgJob;
  Block, Entry, Preview: string;
begin
  Result := '';
  if MaxChars <= 0 then MaxChars := 8192;
  Block := '';
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
        if Job.FState = bjDone then
        begin
          Preview := Job.FResultText;
          if Length(Preview) > DrainPreviewChars then
            Preview := Copy(Preview, 1, DrainPreviewChars) +
                       Format('... (truncated -- spawn_wait("%s") for the full %d chars)',
                              [Job.FHandle, Length(Job.FResultText)]);
          Entry := Format('- %s (agent "%s") completed:%s%s',
                          [Job.FHandle, Job.FAgentName, sLineBreak, Preview]);
        end
        else  { bjFailed }
          Entry := Format('- %s (agent "%s") FAILED: %s',
                          [Job.FHandle, Job.FAgentName, Job.FErrMsg]);
        if Length(Block) + Length(Entry) > MaxChars then Break;
        Job.FCollected := True;
        if Block <> '' then Block := Block + sLineBreak;
        Block := Block + Entry;
      finally
        Job.FStateLock.Leave;
      end;
    end;
  finally
    FLock.Leave;
  end;
  if Block <> '' then
    Result := '[background subagent results]' + sLineBreak + Block;
end;

{ ------------------- drain hook + registration -------------------- }

function DrainByKey(const Key: string; MaxChars: Integer): string;
var
  i: Integer;
  Coord: TBackgroundSpawnCoordinator;
begin
  Result := '';
  if (Key = '') or (GMapLock = nil) then Exit;
  GMapLock.Enter;
  try
    i := GMap.IndexOf(Key);
    if i < 0 then Exit;
    Coord := TBackgroundSpawnCoordinator(GMap.Objects[i]);
  finally
    GMapLock.Leave;
  end;
  { Drain outside the map lock -- DrainFinishedBlock takes the
    coordinator + job locks and there's no need to serialise map
    lookups behind a potentially slow drain. The coordinator can't
    be destroyed between lookup and drain in practice (destruction
    happens at session/process teardown, not mid-loop), but a
    multi-tenant embedder pulling registries down mid-flight should
    revisit this. }
  Result := Coord.DrainFinishedBlock(MaxChars);
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
  if (Reg = nil) or (Length(Specs) = 0) then Exit;

  Result := TBackgroundSpawnCoordinator.Create(Ctx, Specs);
  if GCoordinators = nil then GCoordinators := TList.Create;
  GCoordinators.Add(Result);

  Names := '';
  for i := 0 to High(Specs) do
  begin
    if Names <> '' then Names := Names + ', ';
    Names := Names + '"' + Specs[i].Name + '"';
  end;

  T.Name        := 'spawn_background';
  T.Description := 'Start a subagent in the BACKGROUND and keep working -- ' +
                   'returns a handle immediately instead of blocking like ' +
                   '`spawn` does. The result is delivered to you ' +
                   'automatically when the job finishes (you''ll see a ' +
                   '[background subagent results] block). Use for slow ' +
                   'research / analysis you don''t need before your next ' +
                   'step. Available subagents: ' + Names + '. ' +
                   'Cap: ' + IntToStr(MaxConcurrentBackground) + ' concurrent.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"agent":{"type":"string","description":"Name of the subagent to spawn."},' +
    '"prompt":{"type":"string","description":"The prompt to hand the subagent."}},' +
    '"required":["agent","prompt"]}';
  T.Handler     := nil;
  T.HandlerObj  := Result.HandleSpawnBackground;
  T.IsCore      := True;
  T.Category    := tcMutating;
  Reg.Register(T);

  T.Name        := 'spawn_status';
  T.Description := 'Check on a background subagent started with ' +
                   'spawn_background. Returns state (running / done / ' +
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
  T.Description := 'Block until a background subagent finishes (or ' +
                   'timeout_sec elapses, default 30, max 120) and return ' +
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
  T.Description := 'Cancel a background subagent. Advisory: a job mid-' +
                   'provider-call finishes that call first, then its ' +
                   'result is discarded.';
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
  Specs := ResolveSubagentSpecs(Cfg);
  if Length(Specs) = 0 then Exit;   { subagents disabled }
  Ctx.Provider       := Provider;
  Ctx.Fallbacks      := ResolveFallbacks(Cfg, Ctx.FallbackModels);
  Ctx.ParentRegistry := Reg;
  Ctx.DefaultModel   := DefaultModel;
  Ctx.PromptCache    := Cfg.PromptCache;
  Ctx.Cfg            := Cfg;
  RegisterSpawnTool(Reg, Ctx, Specs);
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
  GBackgroundDrainHook := DrainByKey;

finalization
  GBackgroundDrainHook := nil;
  FreeCoordinators;
  GMap.Free;
  GMapLock.Free;
  GMapLock := nil;

end.
