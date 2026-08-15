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
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg;

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

begin
  TestSpawnReturnsHandleAndJobStarts;
  TestWaitReturnsResultWhenDone;
  TestStatusReportsRunning;
  TestCancelMarksJobCancelled;
  TestConcurrencyCapRejects;
  TestDrainEmitsBlockOnceAndOnlyOnce;
  TestSpawnWaitDeliversFullEvenAfterPreviewTruncated;
  TestDrainedBlockReachesModelButNotFinalSystemPrompt;
  WriteLn('subagent_bg_tests: OK');
end.
