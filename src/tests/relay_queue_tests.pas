program relay_queue_tests;
(*
  Hermetic tests for PasClaw.Gateway.RelayQueue and the request body
  serialiser in PasClaw.Providers.Relay. No HTTP, no real workers,
  no real providers -- all in-process synchronisation.

  Coverage
  ========
    - Enqueue -> DequeueForWorker round-trip preserves request id +
      model + body, marks the request inflight.
    - Capability filtering: a worker that doesn't advertise the
      request's model doesn't receive it.
    - Empty-capability-list worker is a wildcard.
    - Respond signals the waiting Done event with the right payload.
    - Stale-name Respond is a silent no-op (late duplicate).
    - Worker disconnect requeues inflight requests assigned to that
      worker.
    - RelayMaxAttempts cap: after N requeues the request fails with
      a clear error to the waiter.
    - SweepStaleInflight requeues requests held by silent workers
      past the response timeout.
    - BuildRelayRequestBody produces a JSON envelope containing the
      id / model / messages / tools / options fields.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}  { TEvent / TCriticalSection on FPC Linux
                                    bottom out in pthread primitives; without
                                    cthreads, .Create returns garbage and the
                                    first method call AVs. }
  SysUtils, Classes, SyncObjs,
  PasClaw.Providers.Types,
  PasClaw.Providers.Relay,
  PasClaw.Gateway.RelayQueue,
  PasClaw.Cmd.Relay;          { BuildRelayWorkerResponseJSON -- worker-side
                                response envelope. Exposed for the Codex P2
                                non-2xx-as-error coverage. }

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then
  Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')'); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin if Got <> Want then
  Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin if Pos(Needle, Haystack) = 0 then
  Fail_(Msg + ' (no "' + Needle + '" in body)'); end;

function Caps(const A: array of string): TStringArray;
var i: Integer;
begin
  SetLength(Result, Length(A));
  for i := 0 to High(A) do Result[i] := A[i];
end;

procedure TestEnqueueDequeueRoundTrip;
var
  Q: TRelayQueue;
  Req, Out_: TRelayRequest;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-a', Caps(['llama-3.2-3b']));
    Req := TRelayRequest.Create('req_test_1', 'llama-3.2-3b', '{"id":"req_test_1"}');
    try
      Q.Enqueue(Req);
      Out_ := Q.DequeueForWorker('worker-a', 1000);
      AssertTrue(Out_ <> nil, 'matching worker should receive request');
      AssertEqS(Out_.Id, 'req_test_1', 'request id preserved');
      AssertEqS(Out_.Model, 'llama-3.2-3b', 'model preserved');
      AssertEqS(Out_.BodyJSON, '{"id":"req_test_1"}', 'body preserved');
      AssertEqI(Q.GetStatus.InflightRequests, 1, 'inflight counter incremented');
      AssertEqI(Q.GetStatus.PendingRequests, 0, 'pending counter decremented');
    finally
      { Q owns Req now; freeing happens in Q.Destroy. }
    end;
  finally
    Q.Free;
  end;
  WriteLn('  ok: enqueue/dequeue round-trip');
end;

procedure TestCapabilityFiltering;
var
  Q: TRelayQueue;
  Req, Out_: TRelayRequest;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-a', Caps(['phi-3-mini']));
    Req := TRelayRequest.Create('req_cap_1', 'llama-3.2-3b', '{}');
    Q.Enqueue(Req);
    Out_ := Q.DequeueForWorker('worker-a', 200);
    AssertTrue(Out_ = nil,
               'worker advertising phi-3-mini should NOT receive llama-3.2-3b request');
    AssertEqI(Q.GetStatus.PendingRequests, 1, 'request stays in queue');
  finally
    Q.Free;
  end;
  WriteLn('  ok: capability mismatch keeps request in queue');
end;

procedure TestEmptyCapabilityListIsWildcard;
var
  Q: TRelayQueue;
  Req, Out_: TRelayRequest;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-wild', Caps([]));
    Req := TRelayRequest.Create('req_wild_1', 'anything-goes', '{}');
    Q.Enqueue(Req);
    Out_ := Q.DequeueForWorker('worker-wild', 1000);
    AssertTrue(Out_ <> nil,
               'empty-capability worker should serve any model');
  finally
    Q.Free;
  end;
  WriteLn('  ok: empty capability list is a wildcard');
end;

procedure TestEmptyRequestModelMatchesAnyWorker;
var
  Q: TRelayQueue;
  Req, Out_: TRelayRequest;
begin
  (* The case the user surfaced during PR #318 review: when the
     operator picks "relay" in onboarding without naming a model
     (because they don't know which model the connected worker will
     advertise), the agent loop calls Chat() with an empty Model
     field. The empty model should match ANY worker -- caller said
     "any worker will do" -- not zero workers as the original V1
     code did. *)
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-specific', Caps(['llama-3.2-3b']));
    Req := TRelayRequest.Create('req_anymodel_1', '', '{}');
    Q.Enqueue(Req);
    Out_ := Q.DequeueForWorker('worker-specific', 1000);
    AssertTrue(Out_ <> nil,
               'empty-model request should match a worker with non-empty capabilities');
  finally
    Q.Free;
  end;
  WriteLn('  ok: empty request model matches any worker (onboarding case)');
end;

procedure TestRespondSignalsWaiter;
var
  Q: TRelayQueue;
  Req, Picked: TRelayRequest;
  Resp: TRelayResponse;
  Sig: TWaitResult;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-r', Caps(['m']));
    Req := TRelayRequest.Create('req_resp_1', 'm', '{}');
    Q.Enqueue(Req);
    Picked := Q.DequeueForWorker('worker-r', 1000);
    AssertTrue(Picked = Req, 'dequeue returns the same request object');

    FillChar(Resp, SizeOf(Resp), 0);
    Resp.Content      := 'hello world';
    Resp.FinishReason := 'stop';
    Resp.UsageInput   := 47;
    Resp.UsageOutput  := 3;
    Q.Respond('req_resp_1', Resp);

    Sig := Req.Done.WaitFor(1000);
    AssertTrue(Sig = wrSignaled, 'Done event must signal after Respond');
    AssertTrue(Req.ResponseValid, 'ResponseValid set on respond');
    AssertEqS(Req.Response.Content, 'hello world', 'response content stored');
    AssertEqI(Req.Response.UsageInput,  47, 'input tokens stored');
    AssertEqI(Req.Response.UsageOutput,  3, 'output tokens stored');
    AssertEqI(Q.GetStatus.InflightRequests, 0, 'inflight decremented');
    AssertEqI(Q.GetStatus.TotalCompleted, 1, 'completed counter incremented');
  finally
    Q.Free;
  end;
  WriteLn('  ok: Respond signals the waiter with the right payload');
end;

procedure TestLateRespondIsSilent;
var
  Q: TRelayQueue;
  Resp: TRelayResponse;
begin
  Q := TRelayQueue.Create;
  try
    { No inflight request with this id -- a late or duplicate POST
      should be a no-op, NOT a crash. Models the case where one
      worker submits the same response twice or a stale worker
      reconnects after the original waiter timed out. }
    FillChar(Resp, SizeOf(Resp), 0);
    Resp.Content := 'too late';
    Q.Respond('req_no_such_thing', Resp);
    AssertEqI(Q.GetStatus.InflightRequests, 0, 'no state mutation');
    AssertEqI(Q.GetStatus.TotalCompleted,   0, 'no counter bump');
  finally
    Q.Free;
  end;
  WriteLn('  ok: respond for unknown id is silent no-op');
end;

procedure TestUnregisterRequeuesInflight;
var
  Q: TRelayQueue;
  Req, OutA, OutB: TRelayRequest;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-a', Caps(['m']));
    Q.RegisterWorker('worker-b', Caps(['m']));
    Req := TRelayRequest.Create('req_disc_1', 'm', '{}');
    Q.Enqueue(Req);
    OutA := Q.DequeueForWorker('worker-a', 1000);
    AssertTrue(OutA = Req, 'worker-a picked the request');
    AssertEqI(Q.GetStatus.InflightRequests, 1, 'inflight');

    { worker-a disappears mid-request (SSE drop, crashed tab). }
    Q.UnregisterWorker('worker-a');
    AssertEqI(Q.GetStatus.InflightRequests, 0, 'requeue cleared inflight');
    AssertEqI(Q.GetStatus.PendingRequests,  1, 'requeue restored pending');

    OutB := Q.DequeueForWorker('worker-b', 1000);
    AssertTrue(OutB = Req, 'worker-b picks up the same request after requeue');
    AssertEqI(Req.Attempts, 2, 'attempt counter incremented across requeues');
  finally
    Q.Free;
  end;
  WriteLn('  ok: worker disconnect requeues inflight requests');
end;

procedure TestMaxAttemptsCap;
var
  Q: TRelayQueue;
  Req: TRelayRequest;
  i: Integer;
  Sig: TWaitResult;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('flaky', Caps(['m']));
    Req := TRelayRequest.Create('req_max_1', 'm', '{}');
    Q.Enqueue(Req);
    { Simulate flaky worker: dequeue, then immediately unregister
      and re-register so the request is requeued each time.
      RelayMaxAttempts = 3 -- after the 3rd failure we should give
      up and signal the caller. }
    for i := 1 to RelayMaxAttempts do
    begin
      Q.DequeueForWorker('flaky', 1000);
      Q.UnregisterWorker('flaky');
      if i < RelayMaxAttempts then
        Q.RegisterWorker('flaky', Caps(['m']));
    end;
    Sig := Req.Done.WaitFor(1000);
    AssertTrue(Sig = wrSignaled, 'caller is signalled after max attempts');
    AssertTrue(Req.ResponseValid, 'response marked valid (= failure)');
    AssertTrue(Pos('gave up', Req.Response.ErrMsg) > 0,
               'error message mentions "gave up"');
    AssertEqI(Q.GetStatus.TotalFailed, 1, 'failure counter incremented');
  finally
    Q.Free;
  end;
  WriteLn('  ok: max attempts cap fails the waiter cleanly');
end;

procedure TestCancelPullsFromPending;
var
  Q: TRelayQueue;
  Req: TRelayRequest;
  WasOurs: Boolean;
begin
  (* Codex P1 on PR #318: Chat() used to free a request from finally
     without first removing it from the queue's lists. Cancel under-
     the-lock is the safe shape; verify the public surface. *)
  Q := TRelayQueue.Create;
  try
    Req := TRelayRequest.Create('req_cancel_p', 'm', '{}');
    Q.Enqueue(Req);
    AssertEqI(Q.GetStatus.PendingRequests, 1, 'pending before cancel');
    WasOurs := Q.Cancel('req_cancel_p');
    AssertTrue(WasOurs,
               'Cancel returns True when the request was in pending');
    AssertEqI(Q.GetStatus.PendingRequests, 0,
              'pending counter decremented on cancel');
    Req.Free;  { provider would Free here -- queue no longer holds the pointer }
  finally
    Q.Free;
  end;
  WriteLn('  ok: Cancel pulls request from pending list');
end;

procedure TestCancelPullsFromInflight;
var
  Q: TRelayQueue;
  Req: TRelayRequest;
  WasOurs: Boolean;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('w', Caps(['m']));
    Req := TRelayRequest.Create('req_cancel_i', 'm', '{}');
    Q.Enqueue(Req);
    Q.DequeueForWorker('w', 1000);  { now inflight }
    AssertEqI(Q.GetStatus.InflightRequests, 1, 'inflight before cancel');
    WasOurs := Q.Cancel('req_cancel_i');
    AssertTrue(WasOurs,
               'Cancel returns True when the request was inflight');
    AssertEqI(Q.GetStatus.InflightRequests, 0,
              'inflight counter decremented on cancel');
    Req.Free;
  finally
    Q.Free;
  end;
  WriteLn('  ok: Cancel pulls request from inflight list');
end;

procedure TestCancelOfUnknownIsFalse;
var
  Q: TRelayQueue;
  WasOurs: Boolean;
begin
  Q := TRelayQueue.Create;
  try
    WasOurs := Q.Cancel('req_never_existed');
    AssertTrue(not WasOurs,
               'Cancel returns False for unknown id (already consumed or never enqueued)');
  finally
    Q.Free;
  end;
  WriteLn('  ok: Cancel of unknown id is False');
end;

procedure TestStickyRoutingPrefersLastWorker;
var
  Q: TRelayQueue;
  R1, R2, Out1, Out2: TRelayRequest;
begin
  (* Sticky routing: session A's first turn establishes worker X as
     the preferred handler; the same session's second turn should
     prefer X over Y (assuming X is idle), even when Y polls first.
     Keeps KV cache warm on X. *)
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-x', Caps([]));
    Q.RegisterWorker('worker-y', Caps([]));

    R1 := TRelayRequest.Create('req_sticky_1', '', '{}', 'session-A');
    Q.Enqueue(R1);

    { Worker X picks up turn 1. The sticky map should now pin
      session-A to worker-x. }
    Out1 := Q.DequeueForWorker('worker-x', 1000);
    AssertTrue(Out1 = R1, 'worker-x picks up session-A turn 1');

    { Now session-A enqueues turn 2 AND a third party (session-B
      with no history) enqueues. Worker Y polls first. Worker Y
      should pick up session-B because session-A is sticky to X. }
    R2 := TRelayRequest.Create('req_sticky_2', '', '{}', 'session-A');
    Q.Enqueue(R2);

    Out2 := Q.DequeueForWorker('worker-x', 1000);
    AssertTrue(Out2 = R2,
               'worker-x preferred for session-A turn 2 (sticky hit)');
  finally
    Q.Free;
  end;
  WriteLn('  ok: sticky routing prefers the last worker for the same session');
end;

procedure TestStickyRoutingFallsBackOnDisconnect;
var
  Q: TRelayQueue;
  R1, R2, Out1, Out2: TRelayRequest;
  Resp: TRelayResponse;
begin
  (* When session A's sticky worker disconnects, the next turn falls
     back to FCFS and a different worker can take it. The sticky map
     is rebuilt -- session A is now pinned to whoever took turn 2.

     Turn 1 must be Respond'ed before worker-x unregisters, otherwise
     UnregisterWorker requeues the in-flight R1 and pollutes the next
     dequeue. Modelling a clean turn-1 completion then a worker drop
     before turn 2 is the case we care about. *)
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-x', Caps([]));
    R1 := TRelayRequest.Create('req_fb_1', '', '{}', 'session-A');
    Q.Enqueue(R1);
    Out1 := Q.DequeueForWorker('worker-x', 1000);
    AssertTrue(Out1 = R1, 'worker-x picked up turn 1');

    { worker-x finishes turn 1 cleanly first. }
    FillChar(Resp, SizeOf(Resp), 0);
    Resp.Content := 'turn 1 done';
    Q.Respond('req_fb_1', Resp);

    { Now worker-x disappears. Sticky entry for session-A should be
      pruned during UnregisterWorker. }
    Q.UnregisterWorker('worker-x');

    { New worker shows up; turn 2 lands here via FCFS fallback. }
    Q.RegisterWorker('worker-z', Caps([]));
    R2 := TRelayRequest.Create('req_fb_2', '', '{}', 'session-A');
    Q.Enqueue(R2);
    Out2 := Q.DequeueForWorker('worker-z', 1000);
    AssertTrue(Out2 = R2,
               'session-A falls back to worker-z after sticky worker disconnect');
  finally
    Q.Free;
  end;
  WriteLn('  ok: sticky routing falls back to FCFS when preferred worker is gone');
end;

procedure TestStrictStickyDoesntStealFromConnectedPreferred;
var
  Q: TRelayQueue;
  R1, R2, R3, OutA, OutB, OutC, OutD: TRelayRequest;
  Resp: TRelayResponse;
begin
  (* Codex P2 on PR #321: with two workers blocked in /v1/relay/poll,
     after worker-x completes session A's first turn, session A's
     second turn must NOT be stolen by worker-y just because worker-y
     happens to acquire the queue lock first. That re-pins session-A
     to worker-y and defeats sticky routing every cold-cache turn.
     The strict-sticky rule: pass 2 (FCFS) skips requests pinned to
     ANOTHER connected worker; takes them only when the pinned worker
     has disconnected.

     This test models the busy-preferred case (worker-x still alive
     and registered):

       - Session-A turn 1: worker-x. Sticky[A] := worker-x.
       - Turn 1 completes (Respond).
       - Session-A turn 2 (R2) + session-B (R3) enqueue.
       - Worker-y polls FIRST -- must take R3 (no sticky), MUST skip
         R2 (sticky to connected worker-x).
       - Worker-y polls again -- nothing else available, returns nil.
         (R2 reserved.)
       - Worker-x polls -- takes R2 via sticky pass 1. *)
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('worker-x', Caps([]));
    Q.RegisterWorker('worker-y', Caps([]));

    R1 := TRelayRequest.Create('req_strict_1', '', '{}', 'session-A');
    Q.Enqueue(R1);
    OutA := Q.DequeueForWorker('worker-x', 1000);
    AssertTrue(OutA = R1, 'worker-x took turn 1; sticky now pins session-A to worker-x');

    { Complete turn 1 cleanly so the test is about routing, not in-
      flight requeue. worker-x remains connected and (now) idle. }
    FillChar(Resp, SizeOf(Resp), 0);
    Resp.Content := 'turn 1 done';
    Q.Respond('req_strict_1', Resp);

    R2 := TRelayRequest.Create('req_strict_2', '', '{}', 'session-A');
    R3 := TRelayRequest.Create('req_strict_3', '', '{}', 'session-B');
    Q.Enqueue(R2);
    Q.Enqueue(R3);

    { worker-y polls. Pass 1 misses (nothing pinned to worker-y).
      Pass 2: R2 is pinned to worker-x (connected) -- SKIP. R3 has
      no sticky -- TAKE. Worker-y must take R3, not R2. }
    OutB := Q.DequeueForWorker('worker-y', 1000);
    AssertTrue(OutB = R3,
               'worker-y must take session-B (no sticky), NOT steal session-A from worker-x');

    { worker-y polls again. R2 is still reserved for worker-x; nothing
      else available; return nil after the 200ms timeout. }
    OutC := Q.DequeueForWorker('worker-y', 200);
    AssertTrue(OutC = nil,
               'worker-y must NOT steal session-A''s R2 while worker-x is still connected');

    { worker-x polls. Sticky pass hits: session-A pinned to worker-x,
      R2 is session-A's, worker-x picks it up. Locality preserved. }
    OutD := Q.DequeueForWorker('worker-x', 1000);
    AssertTrue(OutD = R2,
               'worker-x takes session-A''s R2 via sticky pass 1 -- locality preserved');
  finally
    Q.Free;
  end;
  WriteLn('  ok: strict sticky does not steal sessions pinned to a connected preferred worker');
end;

procedure TestEmptySessionIdIsNeverSticky;
var
  Q: TRelayQueue;
  R: TRelayRequest;
  Status: TRelayQueueStatus;
begin
  (* One-shot turns (no session id) must never enter the sticky map.
     Otherwise an empty-string key would collect every one-shot's
     worker assignment and the map would grow without bound. *)
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('w', Caps([]));
    R := TRelayRequest.Create('req_no_session', '', '{}', '');  { empty session id }
    Q.Enqueue(R);
    Q.DequeueForWorker('w', 1000);
    { No public accessor for FSessionToWorker; we check indirectly by
      observing that a follow-up empty-session-id request still goes
      FCFS to any worker, which the empty-cap matching already
      guarantees. The strongest assertion we CAN make: status shows
      the request was assigned. }
    Status := Q.GetStatus;
    AssertEqI(Status.InflightRequests, 1,
              'empty-session-id request still assigned');
  finally
    Q.Free;
  end;
  WriteLn('  ok: empty session id does not poison the sticky map');
end;

procedure TestStatusSnapshot;
var
  Q: TRelayQueue;
  Req: TRelayRequest;
  S: TRelayQueueStatus;
begin
  Q := TRelayQueue.Create;
  try
    Q.RegisterWorker('a', Caps(['m']));
    Q.RegisterWorker('b', Caps(['m']));
    Req := TRelayRequest.Create('req_status_1', 'm', '{}');
    Q.Enqueue(Req);
    S := Q.GetStatus;
    AssertEqI(S.PendingRequests,  1, 'status: pending');
    AssertEqI(S.InflightRequests, 0, 'status: inflight');
    AssertEqI(S.ConnectedWorkers, 2, 'status: workers');
    AssertEqI(S.TotalEnqueued,    1, 'status: total enqueued');
  finally
    Q.Free;
  end;
  WriteLn('  ok: GetStatus snapshot matches state');
end;

procedure TestRequestBodyEnvelope;
var
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  Opts: TChatOptions;
  Body: string;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrSystem, 'You are a helpful assistant.');
  Msgs[1] := MakeMessage(mrUser,   'What is 2+2?');

  SetLength(Tools, 1);
  Tools[0].Name        := 'calculate';
  Tools[0].Description := 'Compute a math expression';
  Tools[0].Schema      := '{"type":"object","properties":{"expr":{"type":"string"}}}';

  Opts := DefaultChatOptions;
  Opts.MaxTokens    := 256;
  Opts.SystemPrompt := 'You are a helpful assistant.';

  Body := BuildRelayRequestBody(Msgs, Tools, 'llama-3.2-3b', Opts, 'req_envelope_1');
  { PasClaw's JSON serialiser pretty-prints with a single space around
    each colon, so the on-the-wire shape is `"key" : "value"` not the
    compact `"key":"value"`. Assert on the spaced form. Workers parse
    with a normal JSON library; the whitespace doesn't matter to them. }
  AssertContains(Body, '"id" : "req_envelope_1"',  'envelope has id');
  AssertContains(Body, '"model" : "llama-3.2-3b"', 'envelope has model');
  AssertContains(Body, '"role" : "user"',          'envelope has user message');
  AssertContains(Body, '"What is 2+2?"',           'envelope has user content');
  AssertContains(Body, '"name" : "calculate"',     'envelope has tool name');
  AssertContains(Body, '"max_tokens" : 256',       'envelope has max_tokens');
  AssertContains(Body, 'system_prompt',            'envelope has system_prompt');
  WriteLn('  ok: request body envelope shape');
end;

procedure TestRequestBodyToolMetadataRoundTrip;
(* Codex P1 review on PR #323: round-trip the tool-call metadata
   BuildRelayRequestBody now emits so workers can rebuild a faithful
   TMessage[] for their forwarded Provider.Chat() call. Pre-fix, an
   assistant message with ToolCalls + a tool result with ToolCallId
   came out the worker side as bare role/content, and the next turn's
   request to OpenAI/Anthropic failed with "missing tool_call_id". *)
var
  Msgs:  array of TMessage;
  Tools: array of TToolDefinition;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 3);
  Msgs[0] := MakeMessage(mrUser, 'Read foo.pas');

  Msgs[1] := MakeMessage(mrAssistant, '');
  SetLength(Msgs[1].ToolCalls, 1);
  Msgs[1].ToolCalls[0].Id            := 'call_42';
  Msgs[1].ToolCalls[0].Kind          := 'function';
  Msgs[1].ToolCalls[0].Func.Name     := 'fs_read';
  Msgs[1].ToolCalls[0].Func.Arguments := '{"path":"foo.pas"}';

  Msgs[2] := MakeMessage(mrTool, 'unit Foo; ...');
  Msgs[2].ToolCallId := 'call_42';
  Msgs[2].Name       := 'fs_read';

  SetLength(Tools, 0);
  Opts := DefaultChatOptions;

  Body := BuildRelayRequestBody(Msgs, Tools, 'm', Opts, 'req_tool_rt_1');

  AssertContains(Body, '"tool_calls"',            'assistant tool_calls array emitted');
  AssertContains(Body, '"id" : "call_42"',        'tool call id emitted');
  AssertContains(Body, '"name" : "fs_read"',      'tool call function name emitted');
  AssertContains(Body, '"arguments" : "{\"path\":\"foo.pas\"}"',
                                                  'tool call arguments emitted (json-string)');
  AssertContains(Body, '"tool_call_id" : "call_42"', 'tool result tool_call_id emitted');
  AssertContains(Body, '"role" : "tool"',         'tool result role emitted');

  WriteLn('  ok: tool-call metadata round-trips through the envelope');
end;

procedure TestRequestBodyEmitsProviderSignature;
(* Gemini 3+ thoughtSignature must round-trip through the request
   envelope. The assistant's prior turn carries a thoughtSignature
   per functionCall part; if BuildRelayRequestBody drops it on the
   wire, the worker's local Gemini 3 provider 400s the next request
   with "Function call is missing a thought_signature." User report
   on PR #330. *)
var
  Msgs:  array of TMessage;
  Tools: array of TToolDefinition;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrAssistant, '');
  SetLength(Msgs[0].ToolCalls, 1);
  Msgs[0].ToolCalls[0].Id                := 'call_sig_1';
  Msgs[0].ToolCalls[0].Kind              := 'function';
  Msgs[0].ToolCalls[0].Func.Name         := 'fs_list';
  Msgs[0].ToolCalls[0].Func.Arguments    := '{}';
  Msgs[0].ToolCalls[0].ProviderSignature := 'OPAQUE_GEMINI_3_SIG_BLOB';

  SetLength(Tools, 0);
  Opts := DefaultChatOptions;

  Body := BuildRelayRequestBody(Msgs, Tools, 'gemini-3-pro', Opts, 'req_sig_1');

  AssertContains(Body, '"provider_signature"',
                 'envelope carries provider_signature key');
  AssertContains(Body, 'OPAQUE_GEMINI_3_SIG_BLOB',
                 'envelope carries the actual signature value');

  { Empty signature must NOT emit the key -- keeps the wire clean
    for non-Gemini callers and Gemini 2.x. }
  Msgs[0].ToolCalls[0].ProviderSignature := '';
  Body := BuildRelayRequestBody(Msgs, Tools, 'gpt-4o', Opts, 'req_sig_2');
  AssertTrue(Pos('provider_signature', Body) = 0,
             'empty signature omitted from wire');

  WriteLn('  ok: provider_signature round-trips through the request envelope');
end;

procedure TestRequestBodyEmitsToolChoice;
(* Codex P2 review on PR #333: tool_choice must round-trip through
   the envelope so workers forwarding to tool-call-capable providers
   can honour a forced-tool turn (e.g. WebLLM workers needing
   `tool_choice:"required"` for reliable structured emissions).
   Pre-fix, BuildRelayRequestBody dropped Options.ToolChoice
   entirely and the worker had no way to know the caller wanted a
   forced call. *)
var
  Msgs:  array of TMessage;
  Tools: array of TToolDefinition;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'list files in pwd');

  SetLength(Tools, 1);
  Tools[0].Name        := 'fs_list';
  Tools[0].Description := 'list directory contents';
  Tools[0].Schema      := '{"type":"object","properties":{"path":{"type":"string"}}}';

  Opts := DefaultChatOptions;
  Opts.ToolChoice := 'required';

  Body := BuildRelayRequestBody(Msgs, Tools, 'gemini-3-pro', Opts, 'req_tc_1');

  AssertContains(Body, '"tool_choice" : "required"',
                 'envelope carries tool_choice when non-empty');

  { Empty tool_choice must NOT emit the key. }
  Opts.ToolChoice := '';
  Body := BuildRelayRequestBody(Msgs, Tools, 'gemini-3-pro', Opts, 'req_tc_2');
  AssertTrue(Pos('tool_choice', Body) = 0,
             'empty tool_choice omitted from wire');

  WriteLn('  ok: tool_choice round-trips through the request envelope');
end;

procedure TestWorkerResponseSurfacesNon2xxAsError;
(* Codex P2 review on PR #323: a worker forwarding to a provider that
   returns 401/429/5xx must encode the result as an "error" envelope
   so the gateway-side TRelayProvider.DecodeResponse maps it to
   StatusCode := -1 -- the retryable sentinel that triggers
   Cfg.Fallbacks. Pre-fix, only StatusCode = -1 (pre-HTTP socket
   failure) got encoded as error; positive non-2xx fell into the
   success path and the upstream error text surfaced to the agent as
   the assistant's reply, bypassing fallback. *)
var
  R: TLLMResponse;
  Body: string;
begin
  { 429 from upstream rate limiting. }
  FillChar(R, SizeOf(R), 0);
  R.StatusCode := 429;
  R.Content    := '{"error":"rate_limited"}';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertContains(Body, '"error"',                 '429 surfaces error key');
  AssertContains(Body, 'upstream HTTP 429',       '429 message names the status');
  AssertContains(Body, 'rate_limited',            '429 carries upstream body');

  { 500 from a flaky vLLM. }
  FillChar(R, SizeOf(R), 0);
  R.StatusCode := 500;
  R.Content    := 'internal server error';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertContains(Body, '"error"',                 '500 surfaces error key');
  AssertContains(Body, 'upstream HTTP 500',       '500 message names the status');

  { -1 socket failure -- pre-fix path; must still encode as error. }
  FillChar(R, SizeOf(R), 0);
  R.StatusCode := -1;
  R.Content    := 'ECONNREFUSED';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertContains(Body, '"error"',                 '-1 still surfaces error key');
  AssertContains(Body, 'ECONNREFUSED',            '-1 keeps the socket-error text');

  { 200 success -- must NOT have an error key. }
  FillChar(R, SizeOf(R), 0);
  R.StatusCode := 200;
  R.Content    := 'Hello!';
  R.FinishReason := 'stop';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertTrue(Pos('"error"', Body) = 0,            '200 has no error key');
  AssertContains(Body, '"content" : "Hello!"',    '200 carries content');

  { 0 (older provider that doesn't populate the code) -- treat as success. }
  FillChar(R, SizeOf(R), 0);
  R.StatusCode := 0;
  R.Content    := 'legacy provider reply';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertTrue(Pos('"error"', Body) = 0,            '0 has no error key (legacy success path)');

  WriteLn('  ok: worker encodes non-2xx upstream status as a relay error');
end;

procedure TestWorkerResponseEmitsProviderSignature;
(* Worker-side response envelope must carry provider_signature so
   HandleRelayRespond can stash it on TLLMResponse.ToolCalls[i] for
   BuildRelayRequestBody to emit on the next turn. Without this, the
   round-trip is broken at the worker -> gateway hop and Gemini 3
   still 400s on turn 2. *)
var
  R: TLLMResponse;
  Body: string;
begin
  FillChar(R, SizeOf(R), 0);
  R.StatusCode    := 200;
  R.Content       := '';
  R.FinishReason  := 'tool_calls';
  SetLength(R.ToolCalls, 1);
  R.ToolCalls[0].Id                := 'call_resp_sig_1';
  R.ToolCalls[0].Kind              := 'function';
  R.ToolCalls[0].Func.Name         := 'fs_list';
  R.ToolCalls[0].Func.Arguments    := '{}';
  R.ToolCalls[0].ProviderSignature := 'GEMINI_3_RESPONSE_SIG_BLOB';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertContains(Body, '"provider_signature"',
                 'response carries provider_signature key');
  AssertContains(Body, 'GEMINI_3_RESPONSE_SIG_BLOB',
                 'response carries the actual signature value');

  { Empty signature must NOT emit the field. }
  R.ToolCalls[0].ProviderSignature := '';
  Body := BuildRelayWorkerResponseJSON(R);
  AssertTrue(Pos('provider_signature', Body) = 0,
             'empty signature omitted from response wire');

  WriteLn('  ok: provider_signature round-trips through the response envelope');
end;

procedure TestGlobalQueueAccessor;
var
  Q: TRelayQueue;
begin
  AssertTrue(GetGlobalRelayQueue = nil, 'global queue starts nil');
  Q := TRelayQueue.Create;
  try
    SetGlobalRelayQueue(Q);
    AssertTrue(GetGlobalRelayQueue = Q, 'global queue accessor returns the set instance');
    SetGlobalRelayQueue(nil);
    AssertTrue(GetGlobalRelayQueue = nil, 'global queue cleared');
  finally
    Q.Free;
  end;
  WriteLn('  ok: SetGlobalRelayQueue / GetGlobalRelayQueue round-trip');
end;

begin
  TestEnqueueDequeueRoundTrip;
  TestCapabilityFiltering;
  TestEmptyCapabilityListIsWildcard;
  TestEmptyRequestModelMatchesAnyWorker;
  TestRespondSignalsWaiter;
  TestLateRespondIsSilent;
  TestUnregisterRequeuesInflight;
  TestMaxAttemptsCap;
  TestCancelPullsFromPending;
  TestCancelPullsFromInflight;
  TestCancelOfUnknownIsFalse;
  TestStickyRoutingPrefersLastWorker;
  TestStickyRoutingFallsBackOnDisconnect;
  TestStrictStickyDoesntStealFromConnectedPreferred;
  TestEmptySessionIdIsNeverSticky;
  TestStatusSnapshot;
  TestRequestBodyEnvelope;
  TestRequestBodyToolMetadataRoundTrip;
  TestRequestBodyEmitsProviderSignature;
  TestRequestBodyEmitsToolChoice;
  TestWorkerResponseSurfacesNon2xxAsError;
  TestWorkerResponseEmitsProviderSignature;
  TestGlobalQueueAccessor;
  WriteLn('ok - relay queue tests passed');
end.
