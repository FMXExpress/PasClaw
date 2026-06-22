(*
  PasClaw.Gateway.RelayQueue - thread-safe queue of pending inference
  requests for the relay provider pattern.

  Architecture
  ============

  Inverts PasClaw's normal "agent loop calls out to an LLM provider"
  flow. Instead, external worker apps (a WebGPU browser tab, a phone
  with llama.cpp, a desktop with mlc-llm, ...) connect INBOUND to
  PasClaw's gateway via SSE, advertise the models they can serve, pull
  requests off this queue, run inference on their own hardware, and
  POST results back. The gateway's poll / respond endpoints
  (PasClaw.Gateway.Relay, separate unit) own the HTTP surface; this
  unit owns the in-process synchronisation.

  Lifecycle of one request
  =========================

    1. TRelayProvider.Chat() builds a TRelayRequest, calls
       TRelayQueue.Enqueue, blocks on the request's Done event.
    2. A worker is waiting in DequeueForWorker() (which blocks until
       a request matching the worker's capabilities is available).
       The dequeue function pops the request, assigns the worker id
       on it, and returns.
    3. The gateway's SSE handler serialises the request to JSON,
       writes it as a data: event on the worker's open SSE stream.
    4. Worker runs inference, POSTs the response to
       /v1/relay/respond/<id>.
    5. The gateway calls Respond(id, resp) on the queue, which
       signals the request's Done event and the agent loop unblocks.

  Worker disconnect handling
  ==========================

  If a worker drops mid-request (SSE connection closed, crashed tab,
  network drop), the gateway handler calls OnWorkerDisconnect(id),
  which scans for requests assigned to that worker, returns them to
  the head of the queue, and clears the assigned-worker tag. The
  next polling worker can pick them up. Bounded by per-request
  attempt count -- after MaxAttempts retries, the request gives up
  and signals failure to the waiting Chat() caller.

  Concurrency model
  =================

  One TCriticalSection guards all mutable state. Worker waiters use
  a TEvent that the dequeue function signals whenever a new request
  arrives OR worker capabilities change (so an "I can serve foo"
  worker reconnect wakes up any request waiting on the foo model).

  The TRelayRequest.Done event lives in the request itself so the
  inference-side caller can wait without holding the queue lock.

  Capabilities
  ============

  Workers connect with X-Relay-Capabilities: model1,model2,... -- a
  comma-separated list of model ids they can serve. Each model id is
  matched EXACTLY (case-insensitive) against the request's Model
  field. Glob / semver matching is V2; V1 expects operators to use
  canonical names that line up.

  Model handle naming convention: prefer the same name the model
  catalog uses (e.g. "Llama-3.2-3B-Instruct-q4f16_1-MLC" for WebLLM,
  "llama-3.2-3b-instruct-q4_K_M" for llama.cpp). Worker capabilities
  are a strings array, not a structured type, so operators can use
  whatever naming convention their inference backend already follows.
*)
unit PasClaw.Gateway.RelayQueue;

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
  PasClaw.Providers.Types;

const
  { Maximum attempts per request before signalling failure. A worker
    crash + automatic requeue counts as one attempt; the next polling
    worker gets attempt 2. After this many retries we give up. Bounds
    the case where every available worker is broken in the same way --
    don't loop forever. }
  RelayMaxAttempts = 3;

  { Default per-Chat() wait timeout in milliseconds. The TRelayProvider
    blocks here waiting for a worker to dequeue + respond. 5 minutes
    is generous for slow workers (CPU-side llama.cpp on a phone) but
    short enough that a hung agent loop surfaces visibly rather than
    waiting forever. }
  RelayDefaultWaitTimeoutMs = 5 * 60 * 1000;

  { Default per-worker timeout for "you grabbed this request, finish
    it." If the worker doesn't POST a response within this window
    after dequeue, the request is requeued and made available to
    other workers. Distinct from RelayDefaultWaitTimeoutMs (the
    per-Chat caller timeout) -- this catches workers that grab work
    and then get stuck. }
  RelayWorkerResponseTimeoutMs = 3 * 60 * 1000;

type
  {$IFNDEF FPC}
  { Delphi's RTL doesn't declare TStringArray (FPC's SysUtils does);
    declare it locally so the cross-compiler signatures below resolve.
    Same pattern PasClaw.Tools.Registry + PasClaw.Tools.Shell.Filters
    use for the same gap. dcc64 E2003 / E2005 errors at every signature
    that references TStringArray cascade until this is in scope. }
  TStringArray = array of string;
  {$ENDIF}

  TRelayRequestId = string;
  TRelayWorkerId  = string;

  { Stringly-typed because the worker side is HTTP and the gateway
    just relays whatever the worker sent us. The provider materialises
    these back into TLLMResponse fields on receive.

    ToolCalls -- structured worker output for agent flows (Codex P2 on
    PR #318). The V1 doc claimed "tool calls are text-parsed from the
    model reply" but there was no parser; relay-backed agent flows
    silently stalled after the first tool call. V1.1: accept a
    `tool_calls` array in the worker's response JSON with the same
    OpenAI shape (id / type / function.name / function.arguments) and
    pass it through DecodeResponse into TLLMResponse.ToolCalls. Workers
    that emit only text get text-only chat (no tool dispatch) -- the
    same limitation the V1 doc warns about for "smaller local models
    without strong tool support." Modern inference libraries (WebLLM,
    llama.cpp via grammar, mlc-llm) all emit structured tool calls. }
  TRelayResponse = record
    Content:      string;
    FinishReason: string;
    UsageInput:   Integer;
    UsageOutput:  Integer;
    ToolCalls:    array of TToolCall;
    ErrMsg:       string;       { non-empty when the worker reported a failure }
  end;

  { One pending request. Owned by TRelayProvider's Chat() call --
    the queue stores a reference; releasing the request after
    Done.WaitFor returns is the caller's responsibility. }
  TRelayRequest = class
  private
    FId:             TRelayRequestId;
    FModel:          string;
    FSessionId:      string;        { Options.CacheKey from the provider -- empty
                                      in one-shot turns, non-empty for sessioned
                                      conversations. Used by the queue's
                                      sticky-routing pass to keep multi-turn
                                      sessions warm on the same worker for
                                      KV-cache locality. }
    FBodyJSON:       string;       { serialised messages+tools+options for the worker }
    FEnqueuedAt:     TDateTime;
    FAssignedWorker: TRelayWorkerId;
    FAssignedAt:     TDateTime;     { 0 when not assigned }
    FAttempts:       Integer;
    FDone:           TEvent;
    FResponse:       TRelayResponse;
    FResponseValid:  Boolean;
  public
    { Overloaded rather than a single ctor with `const ASessionId: string =
      ''` -- dcc64 rejects calls that supply the optional 4th arg with
      E2034 "Too many actual parameters" when the default sits behind a
      `const string` parameter. FPC accepts both forms; we just pick the
      overload shape that compiles on both. The 3-arg overload delegates
      to the 4-arg form with an empty session id. }
    constructor Create(const AId, AModel, ABodyJSON: string); overload;
    constructor Create(const AId, AModel, ABodyJSON: string;
                       const ASessionId: string); overload;
    destructor  Destroy; override;
    property Id:             TRelayRequestId  read FId;
    property Model:          string           read FModel;
    property SessionId:      string           read FSessionId;
    property BodyJSON:       string           read FBodyJSON;
    property EnqueuedAt:     TDateTime        read FEnqueuedAt;
    property AssignedWorker: TRelayWorkerId   read FAssignedWorker;
    property Attempts:       Integer          read FAttempts;
    property Done:           TEvent           read FDone;
    property Response:       TRelayResponse   read FResponse;
    property ResponseValid:  Boolean          read FResponseValid;
  end;

  { Per-connected-worker registration. The queue uses these to filter
    requests by capability and to look up which worker holds a given
    in-flight request. }
  TRelayWorker = class
  private
    FId:            TRelayWorkerId;
    FCapabilities:  TStringArray;   { advertised model ids -- stored as
                                      the worker reported them so
                                      /v1/models can surface the exact
                                      casing engines downstream
                                      (WebLLM's model_id is case-
                                      sensitive: Qwen2.5-Coder-7B-...).
                                      CanServe normalises both sides
                                      at compare time. Codex P2 review
                                      on PR #335. }
    FConnectedAt:   TDateTime;
    FLastSeen:      TDateTime;
    FRequestsSeen:  Int64;
  public
    constructor Create(const AId: TRelayWorkerId;
                       const ACapabilities: TStringArray);
    destructor  Destroy; override;
    function CanServe(const Model: string): Boolean;
    procedure Touch;  { sets FLastSeen := Now }
    property Id:           TRelayWorkerId read FId;
    property Capabilities: TStringArray   read FCapabilities;
    property ConnectedAt:  TDateTime      read FConnectedAt;
    property LastSeen:     TDateTime      read FLastSeen;
    property RequestsSeen: Int64          read FRequestsSeen;
  end;

  TRelayWorkerArray = array of TRelayWorker;

  { Status snapshot returned by GetStatus. Read-only point-in-time
    view for the /v1/relay/status endpoint and the TUI panel. }
  TRelayQueueStatus = record
    PendingRequests:   Integer;
    InflightRequests:  Integer;
    ConnectedWorkers:  Integer;
    TotalEnqueued:     Int64;
    TotalCompleted:    Int64;
    TotalFailed:       Int64;
  end;

  TRelayQueue = class
  private
    FLock:        TCriticalSection;
    FNewWork:     TEvent;            { signalled on enqueue + on worker connect }
    FPending:     TList;              { FIFO queue of TRelayRequest (unassigned) }
    FInflight:    TList;              { TRelayRequest currently assigned to a worker }
    FWorkers:     TList;              { TRelayWorker }
    FStats:       TRelayQueueStatus;
    { Sticky-routing map: session_id -> last worker id that served a
      request from this session. PopMatchingRequestLocked makes a
      first pass scanning for "any pending request whose session is
      pinned to THIS worker" before falling back to FCFS. Keeps a
      multi-turn session's KV cache warm on the same worker (5-10x
      speedup on turn 2+ with long contexts: typical PasClaw case
      with MEMORY.md + AGENTS.md + PLAN.md all loaded). Strings.Values
      semantics: Names[i] = session_id, ValueFromIndex(i) = worker_id.

      Cleanup: when a worker unregisters, we drop entries pointing at
      it so a brand-new worker connecting under the same name doesn't
      inherit stale stickiness. Bounded by # of active sessions x
      session lifetime; in-memory single-process for V1. }
    FSessionToWorker: TStringList;
    function  FindWorker(const WorkerId: TRelayWorkerId): TRelayWorker;
    function  PopMatchingRequestLocked(const W: TRelayWorker): TRelayRequest;
    function  FindInflightByIdLocked(const Id: TRelayRequestId): TRelayRequest;
    procedure RequeueLocked(R: TRelayRequest);
  public
    constructor Create;
    destructor  Destroy; override;

    { Worker side -- HTTP poll handler calls these. }
    procedure RegisterWorker(const WorkerId: TRelayWorkerId;
                              const Capabilities: TStringArray);
    procedure UnregisterWorker(const WorkerId: TRelayWorkerId);
    function  DequeueForWorker(const WorkerId: TRelayWorkerId;
                                TimeoutMs: Integer): TRelayRequest;

    { Worker side -- HTTP respond handler calls this. }
    procedure Respond(const Id: TRelayRequestId; const Resp: TRelayResponse);

    { Provider side -- TRelayProvider.Chat() calls these. }
    procedure Enqueue(R: TRelayRequest);
    { Drop a request from FPending or FInflight if still present, under
      lock. Idempotent; safe to call on a request that was already
      consumed via Respond (returns False). The provider's Chat()
      must call Cancel BEFORE Free on any timeout / abort path so the
      queue doesn't keep a dangling pointer past the request's
      lifetime (Codex P1 on PR #318). Returns True when the request
      was found and removed; False otherwise (already consumed or
      never enqueued). }
    function  Cancel(const Id: TRelayRequestId): Boolean;

    { Operator surface. }
    function  GetStatus: TRelayQueueStatus;
    function  GetConnectedWorkers: TRelayWorkerArray;

    { Sweep called periodically (timer, every few seconds) to find
      in-flight requests whose assigned worker has gone silent past
      RelayWorkerResponseTimeoutMs and requeue them. Idempotent --
      safe to call from a watchdog thread. }
    procedure SweepStaleInflight;
  end;

{ Mint a fresh request id. Format: "req_<14-char-ULID-ish>".
  Sortable (timestamp prefix) + uniqueness via CreateGUID's entropy. }
function NewRelayRequestId: TRelayRequestId;

{ Process-wide queue accessor.

  The gateway server creates a TRelayQueue at startup and registers it
  via SetGlobalRelayQueue. TRelayProvider.Chat() looks it up via
  GetGlobalRelayQueue. When the queue isn't set (no gateway running,
  or relay disabled), Chat() short-circuits with a clear error rather
  than blocking forever.

  Single-process design only -- if a future PasClaw embeds two gateway
  instances in one process, the second would clobber the first. We
  don't support that case; one TRelayQueue per process is the
  invariant. }
procedure SetGlobalRelayQueue(Q: TRelayQueue);
function  GetGlobalRelayQueue: TRelayQueue;

implementation

uses
  PasClaw.Logger;

var
  GGlobalQueue: TRelayQueue = nil;
  GGlobalQueueLock: TCriticalSection = nil;

procedure SetGlobalRelayQueue(Q: TRelayQueue);
begin
  if GGlobalQueueLock = nil then
    GGlobalQueueLock := TCriticalSection.Create;
  GGlobalQueueLock.Acquire;
  try
    GGlobalQueue := Q;
  finally
    GGlobalQueueLock.Release;
  end;
end;

function GetGlobalRelayQueue: TRelayQueue;
begin
  if GGlobalQueueLock = nil then Exit(nil);
  GGlobalQueueLock.Acquire;
  try
    Result := GGlobalQueue;
  finally
    GGlobalQueueLock.Release;
  end;
end;

function NewRelayRequestId: TRelayRequestId;
var
  G: TGUID;
  Hex: string;
begin
  if CreateGUID(G) <> 0 then
    raise Exception.Create('relay: CreateGUID failed');
  Hex := GUIDToString(G);
  Hex := StringReplace(Hex, '{', '', [rfReplaceAll]);
  Hex := StringReplace(Hex, '}', '', [rfReplaceAll]);
  Hex := StringReplace(Hex, '-', '', [rfReplaceAll]);
  { Prepend a timestamp prefix so logs of request ids show creation
    order at a glance. Hex of seconds-since-epoch, 8 chars. }
  Result := 'req_' + IntToHex(Round((Now - EncodeDate(1970, 1, 1)) * 86400), 8) +
            '_' + Copy(Hex, 1, 12);
end;

{ ----- TRelayRequest ----- }

constructor TRelayRequest.Create(const AId, AModel, ABodyJSON: string);
begin
  Create(AId, AModel, ABodyJSON, '');
end;

constructor TRelayRequest.Create(const AId, AModel, ABodyJSON: string;
                                  const ASessionId: string);
begin
  inherited Create;
  FId             := AId;
  FModel          := AModel;
  FSessionId      := ASessionId;
  FBodyJSON       := ABodyJSON;
  FEnqueuedAt     := Now;
  FAssignedWorker := '';
  FAssignedAt     := 0;
  FAttempts       := 0;
  FDone           := TEvent.Create(nil, {ManualReset=}True,
                                    {InitialState=}False, '');
  FResponseValid  := False;
end;

destructor TRelayRequest.Destroy;
begin
  FDone.Free;
  inherited;
end;

{ ----- TRelayWorker ----- }

constructor TRelayWorker.Create(const AId: TRelayWorkerId;
                                 const ACapabilities: TStringArray);
var
  i: Integer;
begin
  inherited Create;
  FId           := AId;
  SetLength(FCapabilities, Length(ACapabilities));
  for i := 0 to High(ACapabilities) do
    FCapabilities[i] := Trim(ACapabilities[i]);
  FConnectedAt  := Now;
  FLastSeen     := FConnectedAt;
  FRequestsSeen := 0;
end;

destructor TRelayWorker.Destroy;
begin
  inherited;
end;

function TRelayWorker.CanServe(const Model: string): Boolean;
var
  Target: string;
  i: Integer;
begin
  Target := LowerCase(Trim(Model));
  { V1 dispatch semantics: empty on EITHER side counts as a match.

      Empty request model    -- caller said "any worker will do"
                                (the common case: agent loop didn't
                                pick a specific model, or operator
                                selected `relay` in onboarding
                                without knowing which model the
                                worker would advertise).

      Empty worker caps      -- worker said "I'll serve anything"
                                (the "set up a worker first, decide
                                what model to advertise later" case;
                                also wraps minimal worker scripts
                                that don't bother with X-Relay-
                                Capabilities at all).

      Both non-empty         -- strict case-insensitive exact match
                                required. The web UI's explicit
                                "send THIS request to a worker
                                serving Llama 3.2 3B" flow lands
                                here.

    The strict-match-when-both-non-empty rule is what the operator
    actually wants: they only pin a model when they care enough to
    type it in. The empty-on-either-side wildcard handles the
    onboarding case where neither side has committed to a model id
    yet. }
  if (Target = '') or (Length(FCapabilities) = 0) then Exit(True);
  for i := 0 to High(FCapabilities) do
    (* FCapabilities is now stored as advertised (original casing
       preserved for /v1/models); normalise both sides here so the
       compare stays case-insensitive without sacrificing the
       exact-id surface elsewhere. Codex P2 review on PR #335. *)
    if LowerCase(Trim(FCapabilities[i])) = Target then Exit(True);
  Result := False;
end;

procedure TRelayWorker.Touch;
begin
  FLastSeen := Now;
end;

{ ----- TRelayQueue ----- }

constructor TRelayQueue.Create;
begin
  inherited;
  FLock     := TCriticalSection.Create;
  FSessionToWorker := TStringList.Create;
  FSessionToWorker.CaseSensitive := True;     { session ids are opaque tokens; preserve case }
  { Manual-reset: SetEvent unblocks ALL waiters, not just one. Codex
    P1 on PR #318: a single auto-reset event woke an arbitrary
    blocked worker who may not have matched the request's
    capabilities, leaving the actually-capable worker blocked. With
    manual-reset broadcasting + Reset-when-empty (under lock, inside
    DequeueForWorker after PopMatching returns nil), every blocked
    worker re-evaluates on each enqueue; whichever matches takes the
    work, the rest go back to sleep cleanly. The Reset-under-lock +
    SetEvent-under-lock ordering means no lost-wakeup race: a wake
    happens iff the queue had pending work at any time after the
    waiter committed to wait. }
  FNewWork  := TEvent.Create(nil, {ManualReset=}True,
                              {InitialState=}False, '');
  FPending  := TList.Create;
  FInflight := TList.Create;
  FWorkers  := TList.Create;
  FillChar(FStats, SizeOf(FStats), 0);
end;

destructor TRelayQueue.Destroy;
var
  i: Integer;
begin
  { Signal anything still waiting in DequeueForWorker so it can exit
    cleanly. The TEvent + the thread's own Terminated check are the
    contract; we don't try to drain. }
  if FNewWork <> nil then FNewWork.SetEvent;

  for i := 0 to FPending.Count - 1 do
    TRelayRequest(FPending[i]).Free;
  FPending.Free;

  for i := 0 to FInflight.Count - 1 do
    TRelayRequest(FInflight[i]).Free;
  FInflight.Free;

  for i := 0 to FWorkers.Count - 1 do
    TRelayWorker(FWorkers[i]).Free;
  FWorkers.Free;

  FSessionToWorker.Free;
  FNewWork.Free;
  FLock.Free;
  inherited;
end;

function TRelayQueue.FindWorker(const WorkerId: TRelayWorkerId): TRelayWorker;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FWorkers.Count - 1 do
    if TRelayWorker(FWorkers[i]).Id = WorkerId then
      Exit(TRelayWorker(FWorkers[i]));
end;

function TRelayQueue.PopMatchingRequestLocked(const W: TRelayWorker): TRelayRequest;

  procedure TakeRequestAtLocked(Idx: Integer; Req: TRelayRequest);
  { Shared body for both passes -- moves a request out of FPending into
    FInflight, marks worker assignment + counters, and (when the
    request carries a session id) refreshes the sticky map so the
    same worker preferentially gets the session's next turn. }
  begin
    FPending.Delete(Idx);
    Inc(Req.FAttempts);
    Req.FAssignedWorker := W.Id;
    Req.FAssignedAt     := Now;
    FInflight.Add(Req);
    Inc(W.FRequestsSeen);
    W.Touch;
    Inc(FStats.InflightRequests);
    Dec(FStats.PendingRequests);
    if Req.SessionId <> '' then
      FSessionToWorker.Values[Req.SessionId] := W.Id;
  end;

var
  i: Integer;
  R: TRelayRequest;
  Stuck: string;
begin
  Result := nil;

  { Pass 1: sticky -- "is any pending request from a session pinned to
    THIS worker still waiting?" If so, prefer it. KV-cache locality
    win: the model's working state for this session is already hot in
    the worker's GPU memory. }
  for i := 0 to FPending.Count - 1 do
  begin
    R := TRelayRequest(FPending[i]);
    if R.SessionId = '' then Continue;
    Stuck := FSessionToWorker.Values[R.SessionId];
    if (Stuck = W.Id) and W.CanServe(R.Model) then
    begin
      TakeRequestAtLocked(i, R);
      Exit(R);
    end;
  end;

  { Pass 2: FCFS fallback. Skip requests whose session is pinned to a
    DIFFERENT currently-connected worker -- that worker just hasn't
    polled yet, and stealing the request would re-pin the session on
    every cold-cache turn 2+, defeating sticky routing entirely
    (Codex P2 on PR #321). Take only when the pinned worker has
    actually disconnected from the registry, so the session falls
    back rather than starving on a ghost. Requests with no sticky
    entry (one-shot or first-turn-in-session) are taken as before. }
  for i := 0 to FPending.Count - 1 do
  begin
    R := TRelayRequest(FPending[i]);
    if not W.CanServe(R.Model) then Continue;
    if R.SessionId <> '' then
    begin
      Stuck := FSessionToWorker.Values[R.SessionId];
      if (Stuck <> '') and (Stuck <> W.Id) and (FindWorker(Stuck) <> nil) then
        Continue;
    end;
    TakeRequestAtLocked(i, R);
    Exit(R);
  end;
end;

function TRelayQueue.FindInflightByIdLocked(const Id: TRelayRequestId): TRelayRequest;
var
  i: Integer;
begin
  Result := nil;
  for i := 0 to FInflight.Count - 1 do
    if TRelayRequest(FInflight[i]).Id = Id then
      Exit(TRelayRequest(FInflight[i]));
end;

procedure TRelayQueue.RequeueLocked(R: TRelayRequest);
var
  i: Integer;
begin
  { Remove from inflight if present. }
  for i := 0 to FInflight.Count - 1 do
    if FInflight[i] = R then
    begin
      FInflight.Delete(i);
      Dec(FStats.InflightRequests);
      Break;
    end;
  R.FAssignedWorker := '';
  R.FAssignedAt     := 0;
  if R.FAttempts >= RelayMaxAttempts then
  begin
    { Give up -- signal failure to the waiting caller. }
    R.FResponse.ErrMsg := Format('relay: gave up after %d attempts',
                                  [R.FAttempts]);
    R.FResponseValid   := True;
    R.FDone.SetEvent;
    Inc(FStats.TotalFailed);
    Exit;
  end;
  { Push to head of pending so the retry doesn't starve behind newer
    work -- the original caller is already waiting. }
  FPending.Insert(0, R);
  Inc(FStats.PendingRequests);
  FNewWork.SetEvent;
end;

procedure TRelayQueue.RegisterWorker(const WorkerId: TRelayWorkerId;
                                      const Capabilities: TStringArray);
var
  Existing: TRelayWorker;
begin
  FLock.Acquire;
  try
    Existing := FindWorker(WorkerId);
    if Existing <> nil then
    begin
      { Re-registration -- update capabilities + touch. Operator may
        have reloaded the worker page with a different model. }
      Existing.FCapabilities := Capabilities;
      Existing.Touch;
    end
    else
    begin
      FWorkers.Add(TRelayWorker.Create(WorkerId, Capabilities));
    end;
    { A new worker may unblock requests that the existing workers
      couldn't serve. Wake all blocked dequeuers so the new worker (or
      any worker that's been re-evaluating) sees the pending queue. }
    if FPending.Count > 0 then
      FNewWork.SetEvent;
  finally
    FLock.Release;
  end;
  LogInfo('relay: worker %s registered (caps=%d)',
          [WorkerId, Length(Capabilities)]);
end;

procedure TRelayQueue.UnregisterWorker(const WorkerId: TRelayWorkerId);
var
  i: Integer;
  W: TRelayWorker;
  Inflight: TRelayRequest;
begin
  FLock.Acquire;
  try
    W := FindWorker(WorkerId);
    if W = nil then Exit;
    { Requeue any inflight requests assigned to this worker. }
    i := 0;
    while i < FInflight.Count do
    begin
      Inflight := TRelayRequest(FInflight[i]);
      if Inflight.AssignedWorker = WorkerId then
      begin
        RequeueLocked(Inflight);
        { RequeueLocked mutated FInflight; don't Inc(i). }
      end
      else
        Inc(i);
    end;
    { Drop sticky entries pointing at this worker so a future worker
      connecting under the same id doesn't inherit stale stickiness
      from a previous incarnation, and so the map doesn't grow
      unbounded across long-running gateways. Sessions whose preferred
      worker is gone will fall back to FCFS on the next turn, which
      may re-stick them to whoever picks up the work. }
    for i := FSessionToWorker.Count - 1 downto 0 do
      if FSessionToWorker.ValueFromIndex[i] = WorkerId then
        FSessionToWorker.Delete(i);
    { Drop the worker registration. }
    FWorkers.Remove(W);
    W.Free;
  finally
    FLock.Release;
  end;
  LogInfo('relay: worker %s unregistered', [WorkerId]);
end;

function TRelayQueue.DequeueForWorker(const WorkerId: TRelayWorkerId;
                                       TimeoutMs: Integer): TRelayRequest;
var
  W: TRelayWorker;
  R: TRelayRequest;
  Deadline: TDateTime;
  Now_: TDateTime;
  Remaining: Integer;
begin
  Result := nil;
  Deadline := Now + (TimeoutMs / (24 * 60 * 60 * 1000));
  repeat
    FLock.Acquire;
    try
      W := FindWorker(WorkerId);
      if W = nil then
      begin
        LogWarn('relay: dequeue from unregistered worker %s', [WorkerId]);
        Exit(nil);
      end;
      W.Touch;
      R := PopMatchingRequestLocked(W);
      if R <> nil then Exit(R);
      { No matching pending work for THIS worker. Reset the broadcast
        event ONLY when the queue has no pending work AT ALL -- if
        there's a pending request this worker can't serve (capability
        mismatch), some OTHER worker might be able to, and we mustn't
        starve their wakeup. The Reset + SetEvent serialise on FLock
        so there's no lost-wakeup race: any Enqueue that happens after
        we Reset must wait for our lock release, then will SetEvent. }
      if FPending.Count = 0 then
        FNewWork.ResetEvent;
    finally
      FLock.Release;
    end;
    Now_ := Now;
    if Now_ >= Deadline then Exit(nil);
    Remaining := Round((Deadline - Now_) * 24 * 60 * 60 * 1000);
    if Remaining <= 0 then Exit(nil);
    FNewWork.WaitFor(Cardinal(Remaining));
  until False;
end;

procedure TRelayQueue.Respond(const Id: TRelayRequestId;
                               const Resp: TRelayResponse);
var
  R: TRelayRequest;
begin
  FLock.Acquire;
  try
    R := FindInflightByIdLocked(Id);
    if R = nil then
    begin
      { Late or duplicate -- the waiter already gave up, or a second
        worker submitted after the first won. Drop silently. }
      LogWarn('relay: respond for unknown id %s (late?)', [Id]);
      Exit;
    end;
    FInflight.Remove(R);
    Dec(FStats.InflightRequests);
    R.FResponse      := Resp;
    R.FResponseValid := True;
    if Resp.ErrMsg = '' then
      Inc(FStats.TotalCompleted)
    else
      Inc(FStats.TotalFailed);
  finally
    FLock.Release;
  end;
  { Signal AFTER releasing the queue lock so the unblocked caller
    isn't forced to re-acquire on the wake side. }
  R.FDone.SetEvent;
end;

function TRelayQueue.Cancel(const Id: TRelayRequestId): Boolean;
{ Drop a request from FPending or FInflight under the lock. Idempotent.

  Codex P1 on PR #318: TRelayProvider.Chat() used to free the request
  in its finally block on every exit path. On the timeout / abort path
  the request was still in FPending or FInflight, so the queue kept a
  dangling pointer past Free -- a later Respond() or queue destruction
  would dereference / re-free freed memory.

  Provider now calls Cancel BEFORE Free on every non-success exit:
  Cancel removes the entry from whichever list owns it, decrements the
  matching stat counter, and returns True so the provider knows the
  pointer is still safe to free. False return = the request was
  already consumed (Respond arrived between WaitFor wake and Cancel)
  and the queue already cleaned up; the provider must not Free a
  request the queue already disposed of in that case -- the queue
  doesn't own the memory, so it doesn't free it either, but Respond's
  prior signal means the request is no longer reachable from FPending
  / FInflight. The provider Frees iff Cancel returned True; iff
  Cancel returned False, the response path already ran and the
  ResponseValid flag tells the caller a real response is sitting
  there. }
var
  i: Integer;
  R: TRelayRequest;
begin
  Result := False;
  FLock.Acquire;
  try
    for i := 0 to FPending.Count - 1 do
    begin
      R := TRelayRequest(FPending[i]);
      if R.Id = Id then
      begin
        FPending.Delete(i);
        Dec(FStats.PendingRequests);
        if FPending.Count = 0 then FNewWork.ResetEvent;
        Exit(True);
      end;
    end;
    for i := 0 to FInflight.Count - 1 do
    begin
      R := TRelayRequest(FInflight[i]);
      if R.Id = Id then
      begin
        FInflight.Delete(i);
        Dec(FStats.InflightRequests);
        Exit(True);
      end;
    end;
  finally
    FLock.Release;
  end;
end;

procedure TRelayQueue.Enqueue(R: TRelayRequest);
begin
  FLock.Acquire;
  try
    FPending.Add(R);
    Inc(FStats.PendingRequests);
    Inc(FStats.TotalEnqueued);
    { Manual-reset broadcast wake (Codex P1 on PR #318): SetEvent
      unblocks every waiter in DequeueForWorker. Each waiter re-checks
      under the lock; whichever's CanServe matches takes the work, the
      rest see no match, Reset the event (if queue is now empty), and
      go back to sleep. }
    FNewWork.SetEvent;
  finally
    FLock.Release;
  end;
end;

function TRelayQueue.GetStatus: TRelayQueueStatus;
begin
  FLock.Acquire;
  try
    Result := FStats;
    Result.ConnectedWorkers := FWorkers.Count;
  finally
    FLock.Release;
  end;
end;

function TRelayQueue.GetConnectedWorkers: TRelayWorkerArray;
var
  i: Integer;
begin
  FLock.Acquire;
  try
    SetLength(Result, FWorkers.Count);
    for i := 0 to FWorkers.Count - 1 do
      Result[i] := TRelayWorker(FWorkers[i]);
  finally
    FLock.Release;
  end;
end;

procedure TRelayQueue.SweepStaleInflight;
var
  i: Integer;
  R: TRelayRequest;
  Cutoff: TDateTime;
begin
  Cutoff := Now - (RelayWorkerResponseTimeoutMs / (24 * 60 * 60 * 1000));
  FLock.Acquire;
  try
    i := 0;
    while i < FInflight.Count do
    begin
      R := TRelayRequest(FInflight[i]);
      if (R.FAssignedAt > 0) and (R.FAssignedAt < Cutoff) then
      begin
        LogWarn('relay: sweeping stale inflight %s (worker %s, ' +
                'attempt %d)', [R.Id, R.AssignedWorker, R.Attempts]);
        RequeueLocked(R);
        { RequeueLocked mutated FInflight; don't Inc(i). }
      end
      else
        Inc(i);
    end;
  finally
    FLock.Release;
  end;
end;

initialization
finalization
  if GGlobalQueueLock <> nil then
  begin
    GGlobalQueueLock.Free;
    GGlobalQueueLock := nil;
  end;
end.
