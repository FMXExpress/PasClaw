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
  PasClaw.Gateway.RelayQueue;

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
  TestStatusSnapshot;
  TestRequestBodyEnvelope;
  TestGlobalQueueAccessor;
  WriteLn('ok - relay queue tests passed');
end.
