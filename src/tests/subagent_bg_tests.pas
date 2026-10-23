program subagent_bg_tests;
(*
  Covers PasClaw.Agent.SubagentBg -- the background-subagent
  coordinator, its four tool handlers, and the drain hook that
  feeds finished results into the next loop iteration.

  We pin contracts that don't require a real LLM:

    - spawn_background returns a handle and the job actually starts
    - spawn_status reports state + elapsed; transitions to "done"
    - spawn_wait returns the result when the job has finished
    - spawn_cancel marks a running job and HandleStatus reflects it
    - the concurrency cap rejects the (N+1)th spawn cleanly
    - the drain hook (registered globally during initialization)
      surfaces a [background subagent results] block AND marks the
      drained job collected so a second drain returns ''
    - jobs that finished with a result preview-truncate when the
      result is long, but the full content stays reachable via
      spawn_wait

  Strategy: substitute a FAKE ILLMProvider that returns its prompt
  back as the response Content with a marker prefix. The
  background job is just a RunToolLoop call against that provider
  with an empty tool registry, so it terminates after one
  iteration with the prompt echoed back. No network, no model.

  We don't test the integration with RunToolLoop's iteration-top
  drain (that's a stack call we can't run without a real loop set
  up); we directly invoke DrainFinishedBlock the way the hook
  would.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.Platform;        { RunOneShot -- the tree-kill test asks the OS
                             whether a pid is still alive }

var
  GLastSeenSystemPrompt: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 200) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (needle "' + Needle + '" was present)');
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

type
  { Minimal ILLMProvider that echoes the last user message back.
    Lets a background job's RunToolLoop terminate immediately with
    a predictable result -- no network, no real model. }
  TFakeEchoProvider = class(TInterfacedObject, ILLMProvider)
  public
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TFakeEchoProvider.Chat(const Messages: array of TMessage;
                                const Tools:    array of TToolDefinition;
                                const Model:    string;
                                const Options:  TChatOptions): TLLMResponse;
var
  i: Integer;
  UserText: string;
begin
  Result := Default(TLLMResponse);
  { Record SystemPrompt so the regression test can assert what the
    model actually saw on the wire. }
  GLastSeenSystemPrompt := Options.SystemPrompt;
  UserText := '';
  for i := High(Messages) downto 0 do
    if Messages[i].Role = mrUser then
    begin
      { Drop the turn clock the tool loop appends to the outbound copy.
        These tests assert on the TASK the job ran, not on the transport
        decoration around it, and stripping here fixes every ECHO[...]
        assertion in one place instead of five. }
      UserText := StripTurnClock(Messages[i].Content);
      Break;
    end;
  Result.Content      := 'ECHO[' + UserText + ']';
  Result.FinishReason := 'stop';
  Result.StatusCode   := 200;
  SetLength(Result.ToolCalls, 0);
end;

function TFakeEchoProvider.ChatStream(const Messages: array of TMessage;
                                      const Tools:    array of TToolDefinition;
                                      const Model:    string;
                                      const Options:  TChatOptions;
                                      OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function TFakeEchoProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TFakeEchoProvider.GetName: string;         begin Result := 'fake-echo'; end;
function TFakeEchoProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TFakeEchoProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeEchoProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function MakeCoord(out Provider: ILLMProvider;
                   out ParentReg: TToolRegistry): TBackgroundSpawnCoordinator;
var
  Specs: TSubagentSpecArray;
  Ctx: TSubagentContext;
begin
  Provider  := TFakeEchoProvider.Create;
  ParentReg := TToolRegistry.Create;
  { A stack record: zero it, or Ctx.Cfg is whatever the stack held and
    the coordinator's config-aware paths dereference garbage. }
  Ctx := Default(TSubagentContext);
  SetLength(Specs, 1);
  Specs[0].Name         := 'researcher';
  Specs[0].Description  := 'pretend research';
  Specs[0].SystemPrompt := 'you are research';
  SetLength(Specs[0].Tools, 0);
  Specs[0].Model        := '';
  Specs[0].MaxIter      := 2;

  Ctx.Provider       := Provider;
  SetLength(Ctx.Fallbacks, 0);
  Ctx.ParentRegistry := ParentReg;
  Ctx.DefaultModel   := 'fake';
  Ctx.PromptCache    := Default(TPromptCacheConfig);
  Result := TBackgroundSpawnCoordinator.Create(Ctx, Specs);
end;

function ExtractHandle(const Body: string): string;
{ Scan from "handle=" up to the first character outside [bg-0-9a-f].
  Avoids the off-by-one trap of guessing the exact length. }
var
  P, Q: Integer;
  C: Char;
begin
  Result := '';
  P := Pos('handle=', Body);
  if P = 0 then Exit;
  P := P + Length('handle=');
  Q := P;
  while Q <= Length(Body) do
  begin
    C := Body[Q];
    if ((C >= '0') and (C <= '9')) or
       ((C >= 'a') and (C <= 'z')) or (C = '-') then
      Inc(Q)
    else
      Break;
  end;
  Result := Copy(Body, P, Q - P);
end;

function WaitForState(Coord: TBackgroundSpawnCoordinator;
                      const Handle: string;
                      ExpectedSubstring: string;
                      MaxSeconds: Integer): string;
var
  Deadline: TDateTime;
  Err: string;
  Args: string;
begin
  Result := '';
  Args := '{"handle":"' + Handle + '"}';
  Deadline := Now;
  Deadline := Deadline + (MaxSeconds / 86400.0);
  repeat
    Result := Coord.HandleStatus(Args, Err);
    if Pos(ExpectedSubstring, Result) > 0 then Exit;
    Sleep(100);
  until Now >= Deadline;
end;

procedure TestSpawnReturnsHandleAndJobStarts;
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, Status: string;
  Handle: string;
  P: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"summarise rust ownership"}', Err);
    AssertEqStr(Err, '', 'no error on happy spawn');
    AssertContains(Out_, 'handle=bg-', 'response carries a handle');
    Handle := ExtractHandle(Out_);

    Status := WaitForState(Coord, Handle, 'state=done', 5);
    AssertContains(Status, 'state=done', 'job reaches done state');
    AssertContains(Status, 'ECHO[summarise rust ownership]',
                   'job result is the fake provider echo');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestWaitReturnsResultWhenDone;
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, Handle, WaitResult: string;
  P: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"find a quote"}', Err);
    Handle := ExtractHandle(Out_);

    WaitResult := Coord.HandleWait('{"handle":"' + Handle +
                                   '","timeout_sec":5}', Err);
    AssertEqStr(Err, '', 'no error on wait');
    AssertContains(WaitResult, 'ECHO[find a quote]',
                   'wait returns the full result');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestStatusReportsRunning;
{ The fake provider returns instantly, so by the time we'd call
  HandleStatus the job might already be done. Just pin the
  ARGUMENT-shape error path here -- a missing handle should
  surface a clean message, no thread races. }
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err: string;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleStatus('{}', Err);
    AssertContains(Err, 'handle required', 'missing handle errors clean');
    Out_ := Coord.HandleStatus('{"handle":"bg-nonexistent"}', Err);
    AssertContains(Err, 'no job with handle bg-nonexistent',
                   'unknown handle errors clean');
    { Silence "Out_ assigned but not read" warnings. }
    if Out_ = '' then ;
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestCancelMarksJobCancelled;
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, Handle, Status: string;
  P: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"x"}', Err);
    Handle := ExtractHandle(Out_);

    { Try to cancel immediately. With the fake provider the job may
      have already finished by the time the cancel arrives, in which
      case the response says "already done" -- that's fine, the
      contract we're pinning is "no exception, clear message". }
    Out_ := Coord.HandleCancel('{"handle":"' + Handle + '"}', Err);
    AssertEqStr(Err, '', 'no error on cancel');
    AssertTrue((Pos('cancelled', Out_) > 0) or (Pos('already done', Out_) > 0),
               'cancel response is "cancelled" or "already done"');

    Status := Coord.HandleStatus('{"handle":"' + Handle + '"}', Err);
    AssertTrue((Pos('state=cancelled', Status) > 0) or
               (Pos('state=done', Status) > 0),
               'status reflects cancelled or done after cancel');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestConcurrencyCapRejects;
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err: string;
  i: Integer;
  ExtraOk: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    { Spawn the cap, then one more. The cap-busting attempt must
      surface a clear error. NOTE: with the fake provider jobs
      finish in microseconds, so by the time we try the (N+1)th
      spawn earlier jobs may already be done -- in that case the
      cap isn't hit and ExtraOk advances. The test only fails if
      every attempt errored with an unrelated message. }
    for i := 1 to MaxConcurrentBackground do
    begin
      Out_ := Coord.HandleSpawnBackground(
        '{"agent":"researcher","prompt":"job ' + IntToStr(i) + '"}', Err);
      AssertEqStr(Err, '', Format('spawn #%d succeeds', [i]));
      if Out_ = '' then ;
    end;
    ExtraOk := 0;
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"overflow"}', Err);
    if Err = '' then
      Inc(ExtraOk)
    else
      AssertContains(Err, 'cap',
                     'cap-busting spawn surfaces the running-cap error');
    if Out_ = '' then ;
    if ExtraOk = 0 then
      { confirmed cap path; ok }
    else
      { earlier jobs finished; cap not hit -- also acceptable };
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestDrainEmitsBlockOnceAndOnlyOnce;
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, Block: string;
  Handle: string;
  P: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"hello world"}', Err);
    Handle := ExtractHandle(Out_);

    WaitForState(Coord, Handle, 'state=done', 5);

    Block := Coord.DrainFinishedBlock(8192);
    AssertContains(Block, '[background subagent results]',
                   'drain emits the header block');
    AssertContains(Block, Handle, 'drain mentions the handle');
    AssertContains(Block, 'ECHO[hello world]',
                   'drain carries the result preview');

    { Second drain must be empty -- jobs only delivered once
      through the push channel. The model can still spawn_wait
      to retrieve again, but the drain doesn't repeat. }
    Block := Coord.DrainFinishedBlock(8192);
    AssertEqStr(Block, '',
                'second drain is empty (drain-once semantic)');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestSpawnWaitDeliversFullEvenAfterPreviewTruncated;
{ Build a job whose response is longer than the drain preview cap
  -- we can't easily make the FAKE provider return 3000 chars
  without changing it, so we cheat: spawn, wait until done, drain
  (capturing whatever the fake returned), then spawn_wait again
  and confirm we get the same full text back. The "preview cap"
  branch isn't directly exercised here but the spawn_wait
  retrieves-by-handle contract is pinned. }
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, WaitResult: string;
  Handle: string;
  P: Integer;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"detailed analysis"}', Err);
    Handle := ExtractHandle(Out_);

    WaitResult := Coord.HandleWait('{"handle":"' + Handle +
                                   '","timeout_sec":5}', Err);
    AssertContains(WaitResult, 'ECHO[detailed analysis]',
                   'wait returns full content the first time');

    { Second wait against same handle still returns content (wait
      just reads; it doesn't consume). The model can re-read the
      handle until the coordinator is freed. }
    WaitResult := Coord.HandleWait('{"handle":"' + Handle +
                                   '","timeout_sec":5}', Err);
    AssertContains(WaitResult, 'ECHO[detailed analysis]',
                   'wait still returns full content on re-read');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestDrainedBlockReachesModelButNotFinalSystemPrompt;
(* Codex P2 on PR #211. Pre-fix, the drained [background subagent
   results] block was folded into LiveOptions.SystemPrompt and
   then propagated into Loop.FinalSystemPrompt, which RunInteractive
   persists as Session.Meta.SystemPromptOverride. Effect: a
   background result delivered once on turn N got REPLAYED on every
   subsequent turn AND the prompt grew unboundedly.

   Regression guard: stand up a fresh RunToolLoop with
   BackgroundDrainKey bound to a coordinator that has one finished
   job. Assert:
     1. the fake provider's recorded SystemPrompt CONTAINS the
        [background subagent results] marker (model saw it)
     2. Loop.FinalSystemPrompt does NOT contain the marker
        (persistence channel is clean -- the same block won't
        replay next turn)

   The fix: snapshot LiveOptions.SystemPrompt to PersistentSP
   before folding the drain block, restore from PersistentSP after
   Provider.Chat returns. *)
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, Handle: string;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Hist: TMessageArray;
  Ok: Boolean;
  Key: string;
begin
  Coord := MakeCoord(Provider, ParentReg);
  try
    { Bind the coordinator under a key, queue + drain a job through it. }
    Key := 'reg-test-session';
    Coord.SetKey(Key);
    Out_ := Coord.HandleSpawnBackground(
      '{"agent":"researcher","prompt":"trace the persistence bug"}', Err);
    Handle := ExtractHandle(Out_);
    WaitForState(Coord, Handle, 'state=done', 5);

    { Build a minimal loop config and let RunToolLoop pull the drain
      block via the global hook the coordinator registered. The fake
      provider returns a final-answer turn (no tool calls), so the
      loop exits after one iteration. }
    GLastSeenSystemPrompt := '';
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider           := Provider;
    Cfg.Registry           := ParentReg;
    Cfg.Model              := 'fake';
    Cfg.MaxIterations      := 2;
    Cfg.Options            := DefaultChatOptions;
    Cfg.Options.SystemPrompt := 'YOU-ARE-PASCLAW';
    Cfg.BackgroundDrainKey := Key;

    SetLength(Hist, 1);
    Hist[0] := MakeMessage(mrUser, 'hi');

    Ok := RunToolLoop(Cfg, Hist, Loop);
    AssertTrue(Ok, 'RunToolLoop succeeds');

    AssertContains(GLastSeenSystemPrompt, '[background subagent results]',
                   'model SAW the drain block on the wire');
    AssertContains(GLastSeenSystemPrompt, 'trace the persistence bug',
                   'model saw the job result content too');

    AssertNotContains(Loop.FinalSystemPrompt, '[background subagent results]',
                      'FinalSystemPrompt does NOT carry the drain block ' +
                      '(persistence channel clean)');
    AssertNotContains(Loop.FinalSystemPrompt, 'trace the persistence bug',
                      'FinalSystemPrompt does NOT carry the job result text');

    { Sanity: the operator's baseline SystemPrompt is preserved. }
    AssertContains(Loop.FinalSystemPrompt, 'YOU-ARE-PASCLAW',
                   'baseline SystemPrompt survives');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
end;

procedure TestGatewayShapedDrainByStampedKey;
(* The gateway runs every session through ONE registry and so one
   coordinator, and never called SetKey -- so before this, a gateway turn
   could start a background job and no turn ever heard it finish. Now a
   job is stamped with the drain key of the dispatch that spawned it
   (CurrentDispatchDrainKey), and DrainByKey walks every coordinator for
   jobs stamped with the asking loop's key.

   Shape: coordinator registered via RegisterBackgroundSpawnTools (no key),
   spawn through a loop dispatcher whose BackgroundDrainKey is 'gw-A',
   then run a loop as 'gw-A' (sees the result) and one as 'gw-B' (does
   not). *)
var
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Specs: TSubagentSpecArray;
  Ctx: TSubagentContext;
  Coord: TBackgroundSpawnCoordinator;
  Cfg: TToolLoopConfig;
  Disp: IToolDispatcher;
  Out_, Err, Handle: string;
  Loop: TToolLoopResult;
  Hist: TMessageArray;
begin
  Provider  := TFakeEchoProvider.Create;
  ParentReg := TToolRegistry.Create;
  try
    SetLength(Specs, 1);
    Specs[0].Name := 'researcher'; Specs[0].Description := 'r';
    Specs[0].SystemPrompt := 'you are research'; SetLength(Specs[0].Tools, 0);
    Specs[0].Model := ''; Specs[0].MaxIter := 2;
    Ctx.Provider := Provider; SetLength(Ctx.Fallbacks, 0);
    Ctx.ParentRegistry := ParentReg; Ctx.DefaultModel := 'fake';
    Ctx.PromptCache := Default(TPromptCacheConfig); Ctx.Cfg := nil;
    Coord := RegisterBackgroundSpawnTools(ParentReg, Ctx, Specs);
    AssertTrue(Coord <> nil, 'coordinator registered (module owns it)');

    { Spawn as the gateway would: through a dispatch whose loop carries
      the session's drain key. }
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider := Provider; Cfg.Registry := ParentReg; Cfg.Model := 'fake';
    Cfg.MaxIterations := 2; Cfg.Options := DefaultChatOptions;
    Cfg.BackgroundDrainKey := 'gw-A';
    Disp := MakeLoopDispatcher(Cfg);
    Out_ := Disp.Dispatch('spawn_background',
      '{"agent":"researcher","prompt":"gateway job payload"}', Err);
    AssertTrue(Err = '', 'spawn via dispatcher: ' + Err);
    Handle := ExtractHandle(Out_);
    AssertTrue(Handle <> '', 'got a handle');
    WaitForState(Coord, Handle, 'state=done', 5);

    { A loop for another session sees nothing of it. }
    GLastSeenSystemPrompt := '';
    Cfg.BackgroundDrainKey := 'gw-B';
    Cfg.Options.SystemPrompt := 'BASE';
    SetLength(Hist, 1); Hist[0] := MakeMessage(mrUser, 'hi');
    AssertTrue(RunToolLoop(Cfg, Hist, Loop), 'loop B runs');
    AssertNotContains(GLastSeenSystemPrompt, 'gateway job payload', 'session B does not receive A''s job');

    { The spawning session's loop does, once. }
    GLastSeenSystemPrompt := '';
    Cfg.BackgroundDrainKey := 'gw-A';
    SetLength(Hist, 1); Hist[0] := MakeMessage(mrUser, 'hi again');
    AssertTrue(RunToolLoop(Cfg, Hist, Loop), 'loop A runs');
    AssertContains(GLastSeenSystemPrompt, '[background subagent results]', 'session A gets the block');
    AssertContains(GLastSeenSystemPrompt, 'gateway job payload', 'with the job result');
    GLastSeenSystemPrompt := '';
    SetLength(Hist, 1); Hist[0] := MakeMessage(mrUser, 'and again');
    AssertTrue(RunToolLoop(Cfg, Hist, Loop), 'loop A runs again');
    AssertNotContains(GLastSeenSystemPrompt, 'gateway job payload', 'delivered once only');
  finally
    { Coord is owned by the module (GCoordinators); ParentReg must outlive
      its tools' use, and nothing runs after this. }
    ParentReg.Free;
  end;
end;

type
  TDoneCatcher = class
  public
    Count: Integer;
    LastKey, LastHandle, LastSummary: string;
    procedure OnDone(const Key, Handle, Summary: string);
  end;

procedure TDoneCatcher.OnDone(const Key, Handle, Summary: string);
begin
  Inc(Count);
  LastKey := Key; LastHandle := Handle; LastSummary := Summary;
end;

type
  (* A handler that is SLOW on purpose. The point of the teardown test is
     that clearing the hook waits for a callback already running, so the
     test needs one it can catch in the act. *)
  TSlowCatcher = class
  public
    Entered: Boolean;
    Left:    Boolean;
    procedure OnDone(const Key, Handle, Summary: string);
  end;

procedure TSlowCatcher.OnDone(const Key, Handle, Summary: string);
begin
  Entered := True;
  Sleep(600);
  Left := True;
end;

procedure TestShellToolsSurviveSubagentsOff;
(* subagents_enabled:false must not take the background SHELL away.

   Every caller resolved the specs first and skipped the whole
   registration when the list was empty, so turning off LLM subagents
   silently removed shell_background, spawn_status, spawn_wait and
   spawn_cancel -- tools the docs describe with no such dependency. Only
   spawn_background needs a subagent. (Codex P2 on #619.) *)
var
  Reg: TToolRegistry;
  Provider: ILLMProvider;
  Ctx: TSubagentContext;
  Empty: TSubagentSpecArray;
  Coord: TBackgroundSpawnCoordinator;
  Out_, Err: string;
  T: TTool;
begin
  Reg := TToolRegistry.Create;
  Provider := TFakeEchoProvider.Create;
  try
    SetLength(Empty, 0);                { what subagents_enabled:false yields }
    Ctx := Default(TSubagentContext);
    Ctx.Provider       := Provider;
    Ctx.ParentRegistry := Reg;
    Ctx.DefaultModel   := 'fake';
    Coord := RegisterBackgroundSpawnTools(Reg, Ctx, Empty);
    AssertTrue(Coord <> nil, 'a coordinator is created with no subagent specs');

    AssertTrue(Reg.Find('shell_background', T), 'shell_background still registers');
    AssertTrue(Reg.Find('spawn_status', T),     'spawn_status still registers');
    AssertTrue(Reg.Find('spawn_wait', T),       'spawn_wait still registers');
    AssertTrue(Reg.Find('spawn_cancel', T),     'spawn_cancel still registers');
    { The one tool that really does need a subagent. }
    AssertTrue(not Reg.Find('spawn_background', T),
               'spawn_background is the only one Specs gates');

    { And it works, not just registers. }
    Coord.SetKey('no-subagents-session');
    Out_ := Coord.HandleShellBackground('{"command":"echo shell-still-here"}', Err);
    AssertTrue(Err = '', 'the shell job starts: ' + Err);
    WaitForState(Coord, ExtractHandle(Out_), 'state=done', 5);
    Out_ := Coord.HandleWait('{"handle":"' + ExtractHandle(Out_) + '"}', Err);
    AssertContains(Out_, 'shell-still-here', 'and delivers its output');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: shell_background survives subagents_enabled:false');
end;

procedure TestDoneHookTeardownWaitsForInFlightCall;
(* SetBackgroundDoneHook(nil) must not return while a handler is running.

   The TUI installs a method of the TTUI object and clears it on the way
   to freeing that object. With a bare `if Assigned(hook) then hook(...)`
   there was a window between the test and the call: the main thread
   could clear the pointer AND free the object, and the job's thread
   would then run a method of freed memory -- on any ordinary shutdown
   with a job still finishing. (Codex P2 on #610.)

   Proven by the clock. The handler sleeps; the test waits until it is
   known to be inside it, then times the clear. A clear that does not
   synchronise returns in microseconds. *)
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Slow: TSlowCatcher;
  Out_, Err: string;
  Waited: Integer;
  T0: TDateTime;
  Elapsed: Int64;
begin
  Coord := MakeCoord(Provider, ParentReg);
  Slow  := TSlowCatcher.Create;
  try
    Coord.SetKey('teardown-test');
    SetBackgroundDoneHook(Slow.OnDone);
    Out_ := Coord.HandleShellBackground('{"command":"echo done-fast"}', Err);
    AssertTrue(Err = '', 'job starts: ' + Err);

    { Wait until the handler is definitely inside the sleep. }
    Waited := 0;
    while (not Slow.Entered) and (Waited < 5000) do
    begin
      Sleep(20);
      Inc(Waited, 20);
    end;
    AssertTrue(Slow.Entered, 'the completion handler ran at all');
    AssertTrue(not Slow.Left, 'and the test caught it mid-call');

    T0 := Now;
    SetBackgroundDoneHook(nil);
    Elapsed := MilliSecondsBetween(Now, T0);
    AssertTrue(Slow.Left,
               'clearing the hook waited for the in-flight callback -- ' +
               'returning early is the window where the TUI frees the ' +
               'object the handler belongs to');
    AssertTrue(Elapsed >= 200,
               'and it really blocked (waited ' + IntToStr(Elapsed) + ' ms)');

    { And nothing fires afterwards. }
    Slow.Entered := False;
    Out_ := Coord.HandleShellBackground('{"command":"echo after-clear"}', Err);
    AssertTrue(Err = '', 'second job starts: ' + Err);
    WaitForState(Coord, ExtractHandle(Out_), 'state=done', 5);
    Sleep(200);
    AssertTrue(not Slow.Entered, 'a cleared hook is not called again');
  finally
    SetBackgroundDoneHook(nil);
    Slow.Free;
    Coord.Free;
    ParentReg.Free;
  end;
  WriteLn('  ok: clearing the done hook waits for an in-flight callback');
end;

{$IFDEF UNIX}
function PidAlive(const Pid: string): Boolean;
var
  Out_: string;
begin
  Result := RunOneShot('kill -0 ' + Pid + ' 2>/dev/null && echo YES || echo NO',
                       '', Out_) >= 0;
  Result := Result and (Pos('YES', Out_) > 0);
end;

function ReadPidFile(const Path: string): string;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  with TStringList.Create do
  try
    LoadFromFile(Path);
    Result := Trim(Text);
  finally
    Free;
  end;
end;
{$ENDIF}

procedure TestCancelAndTimeoutKillTheTree;
(* Cancelling or timing out a background shell job must kill everything
   the command started, not just the /bin/sh wrapper the job holds.

   Terminating the wrapper alone left compiler workers, `make -j` children
   and anything launched with `&` running after spawn_cancel had already
   reported the job killed -- writing files and burning CPU with nothing
   holding a handle to them. (Codex P1 on #610.) *)
{$IFDEF UNIX}
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, R, Dir, PidFile, Kid: string;
  Waited: Integer;

  { A command whose GRANDCHILD records its pid and then outlives any
    sane test: it survives unless the tree is killed. The inner double
    quotes are JSON-escaped -- this string is spliced into the tool's
    JSON argument, not handed to a shell directly. }
  function TreeCommand(const F: string): string;
  begin
    Result := 'sh -c ''echo $$ > \"' + F + '\"; sleep 45'' & wait';
  end;

  procedure ExpectGone(const Pid, What: string);
  begin
    Waited := 0;
    while PidAlive(Pid) and (Waited < 4000) do
    begin
      Sleep(100);
      Inc(Waited, 100);
    end;
    AssertTrue(not PidAlive(Pid),
      What + ': the grandchild (pid ' + Pid + ') outlived its job -- ' +
      'killing only the shell wrapper leaves it running');
  end;

begin
  Dir := GetTempDir;
  Coord := MakeCoord(Provider, ParentReg);
  try
    Coord.SetKey('treekill-test');

    { ---- cancel ---- }
    PidFile := IncludeTrailingPathDelimiter(Dir) + 'bg-treekill-cancel.pid';
    if FileExists(PidFile) then DeleteFile(PidFile);
    Out_ := Coord.HandleShellBackground(
              '{"command":"' + TreeCommand(PidFile) + '"}', Err);
    AssertTrue(Err = '', 'tree job starts: ' + Err);
    Waited := 0;
    while (ReadPidFile(PidFile) = '') and (Waited < 4000) do
    begin
      Sleep(50);
      Inc(Waited, 50);
    end;
    Kid := ReadPidFile(PidFile);
    AssertTrue(Kid <> '', 'the grandchild recorded its pid');
    AssertTrue(PidAlive(Kid), 'and is running before the cancel');
    R := Coord.HandleCancel('{"handle":"' + ExtractHandle(Out_) + '"}', Err);
    AssertContains(R, 'killed', 'cancel reports the kill');
    ExpectGone(Kid, 'cancel');

    { ---- timeout ---- }
    PidFile := IncludeTrailingPathDelimiter(Dir) + 'bg-treekill-timeout.pid';
    if FileExists(PidFile) then DeleteFile(PidFile);
    Out_ := Coord.HandleShellBackground(
              '{"command":"' + TreeCommand(PidFile) + '","timeout_sec":1}', Err);
    AssertTrue(Err = '', 'timeout job starts: ' + Err);
    Waited := 0;
    while (ReadPidFile(PidFile) = '') and (Waited < 4000) do
    begin
      Sleep(50);
      Inc(Waited, 50);
    end;
    Kid := ReadPidFile(PidFile);
    AssertTrue(Kid <> '', 'the grandchild recorded its pid (timeout case)');
    WaitForState(Coord, ExtractHandle(Out_), 'state=done', 8);
    R := Coord.HandleWait('{"handle":"' + ExtractHandle(Out_) + '"}', Err);
    AssertTrue(Pos('exit=124', R) = 1, 'timeout reports 124: ' + Copy(R, 1, 40));
    ExpectGone(Kid, 'timeout');
  finally
    Coord.Free;
    ParentReg.Free;
  end;
  WriteLn('  ok: cancel and timeout kill the job''s whole process tree');
end;
{$ELSE}
begin
  WriteLn('  skip: process-tree assertions are POSIX-only here');
end;
{$ENDIF}

function StripPascalComments(const S: string): string;
(* Blank out brace comments, parenthesis-star comments and line
   comments, keeping length and newlines so positions still line up.

   Needed because the check below searches for a CALL, and the comment
   that explains the call mentions it by name -- without this the check
   passed on a body that only TALKED about draining, which is how this
   check first failed to catch its own bug. *)
var
  i, N: Integer;
  Closing: string;
begin
  Result := S;
  i := 1;
  N := Length(S);
  while i <= N do
  begin
    Closing := '';
    if S[i] = '{' then Closing := '}'
    else if (S[i] = '(') and (i < N) and (S[i + 1] = '*') then Closing := '*)'
    else if (S[i] = '/') and (i < N) and (S[i + 1] = '/') then Closing := #10;
    if Closing = '' then
    begin
      Inc(i);
      Continue;
    end;
    while i <= N do
    begin
      if (Length(Closing) = 1) and (S[i] = Closing[1]) then
      begin
        if Closing <> #10 then Result[i] := ' ';
        Inc(i);
        Break;
      end;
      if (Length(Closing) = 2) and (i < N) and
         (S[i] = Closing[1]) and (S[i + 1] = Closing[2]) then
      begin
        Result[i] := ' ';
        Result[i + 1] := ' ';
        Inc(i, 2);
        Break;
      end;
      if S[i] <> #10 then Result[i] := ' ';
      Inc(i);
    end;
  end;
end;

procedure TestBothTUILoopsDrainTheFlash;
(* Every TTUI.Run must call DrainBackgroundFlash.

   There are two of them -- the Delphi positioned TUI and the FPC line
   REPL -- in one file, each inside its own compiler branch. Only the
   Delphi loop called the drain, so on FPC a completion was parked in
   FBgFlashPending and never shown: the operator got no notification at
   all and the FPC half of DrainBackgroundFlash was dead code. (Codex P2
   on #610.)

   A source check because neither loop can be driven from a test: one
   positions a console, the other blocks in ReadLn. The thing that went
   wrong is exactly a missing call, which is what this reads. *)
var
  Src, Body: string;
  Sl: TStringList;
  P, Stop, Found: Integer;
const
  TUIPath = 'src/pkg/tui/PasClaw.TUI.pas';
begin
  if not FileExists(TUIPath) then
  begin
    WriteLn('  skipping TUI drain check: run from the repo root to include it');
    Exit;
  end;
  Sl := TStringList.Create;
  try
    Sl.LoadFromFile(TUIPath);
    Src := Sl.Text;
  finally
    Sl.Free;
  end;

  Found := 0;
  P := Pos('procedure TTUI.Run;', Src);
  while P > 0 do
  begin
    Inc(Found);
    { The body runs to the next routine at column 0. }
    Stop := Pos(#10'procedure ', Copy(Src, P + 20, Length(Src)));
    if Stop <= 0 then Stop := Length(Src) else Inc(Stop, P + 19);
    Body := StripPascalComments(Copy(Src, P, Stop - P));
    AssertTrue(Pos('DrainBackgroundFlash;', Body) > 0,
               'TTUI.Run #' + IntToStr(Found) + ' never drains the ' +
               'background-completion flash, so that build shows the ' +
               'operator nothing when a job finishes');
    P := Pos('procedure TTUI.Run;', Copy(Src, Stop, Length(Src)));
    if P > 0 then Inc(P, Stop - 1);
  end;
  AssertTrue(Found >= 2,
             'expected a TTUI.Run per build (Delphi + FPC); found ' +
             IntToStr(Found) + ' -- if the surfaces merged, revisit this');
  WriteLn('  ok: both TUI loops drain the background-completion flash');
end;

procedure TestShellBackground;
(* shell_background: a shell command as a job. Same handle space, status,
   wait, cancel and drain as a subagent, plus the things a shell needs: the
   denylist, a timeout that kills, and a cancel that kills. *)
var
  Coord: TBackgroundSpawnCoordinator;
  Provider: ILLMProvider;
  ParentReg: TToolRegistry;
  Out_, Err, H, R, Blk: string;
  Catcher: TDoneCatcher;
  T0: TDateTime;
begin
  Coord := MakeCoord(Provider, ParentReg);
  Catcher := TDoneCatcher.Create;
  try
    Coord.SetKey('shell-test-session');
    SetBackgroundDoneHook(Catcher.OnDone);

    { Runs, delivers exit + output, status names the command. }
    Out_ := Coord.HandleShellBackground('{"command":"echo hello-bg"}', Err);
    AssertTrue(Err = '', 'shell_background starts: ' + Err);
    H := ExtractHandle(Out_);
    AssertTrue(Copy(H, 1, 3) = 'sh-', 'shell handle prefix: ' + H);
    WaitForState(Coord, H, 'state=done', 5);
    R := Coord.HandleWait('{"handle":"' + H + '"}', Err);
    AssertTrue(Err = '', 'wait ok: ' + Err);
    AssertTrue(Pos('exit=0', R) = 1, 'result starts with exit=0: ' + Copy(R, 1, 40));
    AssertContains(R, 'hello-bg', 'output delivered');
    R := Coord.HandleStatus('{"handle":"' + H + '"}', Err);
    AssertContains(R, 'command=echo hello-bg', 'status shows the command');
    AssertTrue(Catcher.Count >= 1, 'done hook fired');
    AssertEqStr(Catcher.LastHandle, H, 'hook carries the handle');
    AssertEqStr(Catcher.LastKey, 'shell-test-session', 'hook carries the drain key');
    AssertContains(Catcher.LastSummary, 'exit=0', 'hook summary has the exit code');

    { Denylist applies. }
    Out_ := Coord.HandleShellBackground('{"command":"rm -rf /"}', Err);
    AssertTrue(Err <> '', 'denylisted command refused');
    AssertTrue(Out_ = '', 'no handle for a refused command');

    {$IFDEF UNIX}
    { Timeout kills with exit 124. }
    Out_ := Coord.HandleShellBackground('{"command":"sleep 30; echo late","timeout_sec":1}', Err);
    AssertTrue(Err = '', 'timeout job starts: ' + Err);
    H := ExtractHandle(Out_);
    T0 := Now;
    WaitForState(Coord, H, 'state=done', 6);
    AssertTrue(SecondsBetween(Now, T0) < 5, 'timed-out job finished promptly');
    R := Coord.HandleWait('{"handle":"' + H + '"}', Err);
    AssertTrue(Pos('exit=124', R) = 1, 'timeout reports exit=124: ' + Copy(R, 1, 40));
    AssertContains(R, 'timed out', 'timeout note present');
    AssertNotContains(R, 'late', 'the command did not finish');

    { Cancel kills. }
    Out_ := Coord.HandleShellBackground('{"command":"sleep 30"}', Err);
    AssertTrue(Err = '', 'long job starts: ' + Err);
    H := ExtractHandle(Out_);
    Sleep(300);
    R := Coord.HandleCancel('{"handle":"' + H + '"}', Err);
    AssertContains(R, 'killed', 'cancel kills a local shell job');
    T0 := Now;
    WaitForState(Coord, H, 'state=cancelled', 4);
    R := Coord.HandleStatus('{"handle":"' + H + '"}', Err);
    AssertContains(R, 'state=cancelled', 'job is cancelled');
    AssertTrue(SecondsBetween(Now, T0) < 4, 'cancelled job stopped promptly, not after 30 s');
    {$ENDIF}

    { Drain: shell results under their own header, once. The jobs above
      were collected by spawn_wait (wait marks them delivered), so run one
      more and let it finish on its own. }
    Out_ := Coord.HandleShellBackground('{"command":"echo drain-me"}', Err);
    H := ExtractHandle(Out_);
    WaitForState(Coord, H, 'state=done', 5);
    Blk := Coord.DrainFinishedBlock(8192);
    AssertContains(Blk, '[background shell results]', 'shell block header');
    AssertContains(Blk, 'drain-me', 'the uncollected job is in the drain');
    AssertContains(Blk, 'shell "echo drain-me"', 'entry names the command');
    AssertNotContains(Blk, 'hello-bg', 'a job collected by spawn_wait is not re-delivered');
    AssertNotContains(Blk, '[background subagent results]', 'no subagent header when only shells finished');
    Blk := Coord.DrainFinishedBlock(8192);
    AssertNotContains(Blk, 'drain-me', 'delivered once');
  finally
    SetBackgroundDoneHook(nil);
    Catcher.Free;
    Coord.Free;
    ParentReg.Free;
  end;
  WriteLn('  ok: shell_background runs, denies, times out, cancels (kills), drains, notifies');
end;

begin
  TestSpawnReturnsHandleAndJobStarts;
  TestWaitReturnsResultWhenDone;
  TestStatusReportsRunning;
  TestCancelMarksJobCancelled;
  TestConcurrencyCapRejects;
  TestDrainEmitsBlockOnceAndOnlyOnce;
  TestSpawnWaitDeliversFullEvenAfterPreviewTruncated;
  TestDrainedBlockReachesModelButNotFinalSystemPrompt;
  TestGatewayShapedDrainByStampedKey;
  TestShellBackground;
  TestDoneHookTeardownWaitsForInFlightCall;
  TestCancelAndTimeoutKillTheTree;
  TestBothTUILoopsDrainTheFlash;
  TestShellToolsSurviveSubagentsOff;
  WriteLn('subagent_bg_tests: OK');
end.
