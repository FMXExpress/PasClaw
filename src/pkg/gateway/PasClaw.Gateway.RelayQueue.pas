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
  TRelayRequestId = string;
  TRelayWorkerId  = string;

  { Stringly-typed because the worker side is HTTP and the gateway
    just relays whatever the worker sent us. The provider materialises
    these back into TLLMResponse fields on receive. }
  TRelayResponse = record
    Content:      string;
    FinishReason: string;
    UsageInput:   Integer;
    UsageOutput:  Integer;
    ErrMsg:       string;       { non-empty when the worker reported a failure }
  end;

  { One pending request. Owned by TRelayProvider's Chat() call --
    the queue stores a reference; releasing the request after
    Done.WaitFor returns is the caller's responsibility. }
  TRelayRequest = class
  private
    FId:             TRelayRequestId;
    FModel:          string;
    FBodyJSON:       string;       { serialised messages+tools+options for the worker }
    FEnqueuedAt:     TDateTime;
    FAssignedWorker: TRelayWorkerId;
    FAssignedAt:     TDateTime;     { 0 when not assigned }
    FAttempts:       Integer;
    FDone:           TEvent;
    FResponse:       TRelayResponse;
    FResponseValid:  Boolean;
  public
    constructor Create(const AId, AModel, ABodyJSON: string);
    destructor  Destroy; override;
    property Id:             TRelayRequestId  read FId;
    property Model:          string           read FModel;
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
    FCapabilities:  TStringArray;   { lowercase model ids }
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
  inherited Create;
  FId             := AId;
  FModel          := AModel;
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
    FCapabilities[i] := LowerCase(Trim(ACapabilities[i]));
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
  { Empty capability list = wildcard. A worker that didn't advertise
    anything will accept any model -- useful for "I'll serve whatever
    you throw at me" workers without explicit capability tracking.
    Operators wanting strict matching should always advertise. }
  if Length(FCapabilities) = 0 then Exit(True);
  for i := 0 to High(FCapabilities) do
    if FCapabilities[i] = Target then Exit(True);
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
  FNewWork  := TEvent.Create(nil, {ManualReset=}False,
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
var
  i: Integer;
  R: TRelayRequest;
begin
  Result := nil;
  for i := 0 to FPending.Count - 1 do
  begin
    R := TRelayRequest(FPending[i]);
    if W.CanServe(R.Model) then
    begin
      FPending.Delete(i);
      Inc(R.FAttempts);
      R.FAssignedWorker := W.Id;
      R.FAssignedAt     := Now;
      FInflight.Add(R);
      Inc(W.FRequestsSeen);
      W.Touch;
      Inc(FStats.InflightRequests);
      Dec(FStats.PendingRequests);
      Exit(R);
    end;
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
    { A new worker may unblock requests waiting on its capabilities --
      poke the wake event so blocked DequeueForWorker callers re-evaluate. }
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
    finally
      FLock.Release;
    end;
    { Nothing to do; wait for new work (or timeout). FNewWork is a
      manual / auto-reset choice -- we use auto-reset (constructor
      passed ManualReset=False) so each SetEvent wakes at most one
      waiter. That avoids a thundering herd when one new request
      arrives but ten workers are blocked. }
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

procedure TRelayQueue.Enqueue(R: TRelayRequest);
begin
  FLock.Acquire;
  try
    FPending.Add(R);
    Inc(FStats.PendingRequests);
    Inc(FStats.TotalEnqueued);
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
