{
  PasClaw.Stream.Reliability - production-grade polish for the serve /
  gateway OpenAI-compat surface. Mirrors the UltraCode-Shim layer:

    1. Empty-turn auto-retry. Some upstream models / proxies (notably
       on the OpenAI-compat side: certain Together / OpenRouter route
       hiccups, MoonShot K2 brownouts, DeepSeek R1 thinking-token
       overflow) hand back a perfectly-shaped response whose
       Content is empty AND ToolCalls is empty AND FinishReason is
       "stop". The model said nothing. The provider returned 200.
       The end user sees the agent fall silent mid-turn. Auto-retry
       up to N times with exponential backoff catches the transient
       cases and stops short of pounding on a true silent backend.

    2. Idle-timeout kill for hung streams. ChatStream calls that
       stop emitting chunks for longer than IdleTimeoutMs are
       declared dead: the wrapper returns a synthetic empty
       response with FinishReason='timeout' to the caller while a
       background thread continues to drain the provider until its
       own Indy ReadTimeout retires the socket. Without this an
       upstream that opens the stream then never writes will wedge
       the gateway worker until the Indy connect/read timeout
       (typically tens of seconds, sometimes more on chained
       proxies).

    3. Tool-call repair. Strict OpenAI-compat backends -- DeepSeek,
       MiniMax-class endpoints, anything tightly validating the
       tool_call / tool_result pairing -- return HTTP 400 when an
       assistant turn carries N tool_calls but the follow-up
       messages contain fewer matched tool_result entries.
       Real-world cause: parallel tool dispatch where the client
       cancelled one of the calls, or a previous turn aborted
       between tool_use and tool_result. RepairOrphanedToolCalls
       walks the message history, finds every assistant
       tool_call.Id that lacks a paired mrTool entry following it,
       and synthesizes a stub mrTool result so the next request
       validates.

  All three knobs come from TConfig.StreamReliability; default values
  match the UltraCode-Shim shipping config (2 attempts, 750ms base
  backoff, 150s idle timeout). Operators tune via config.json or via
  the well-known env vars UC_EMPTY_RETRY_ATTEMPTS,
  UC_EMPTY_RETRY_BACKOFF_MS, UC_STREAM_IDLE_TIMEOUT_SEC.
}
unit PasClaw.Stream.Reliability;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TStreamReliabilityConfig = record
    { Max attempts when the provider returns an empty turn
      (Content='' AND ToolCalls=[] AND FinishReason='stop'). 0
      disables retry (single attempt, surface the empty response
      verbatim). Default 2. }
    EmptyRetryAttempts:    Integer;
    { Base backoff in milliseconds between retry attempts. Doubles
      each subsequent attempt (capped). Default 750. }
    EmptyRetryBackoffMs:   Integer;
    { Max idle window in milliseconds for ChatStream. If no chunk
      arrives within this window the stream is declared timed out
      and a synthetic empty response is returned. 0 disables the
      watcher entirely. Default 150_000 (150s). }
    StreamIdleTimeoutMs:   Integer;
    { When True, RepairOrphanedToolCalls runs at the gateway
      boundary to synthesize stub tool_result messages for
      assistant tool_call ids that have no matched tool_result.
      Default True. }
    ToolCallRepairEnabled: Boolean;
  end;

function DefaultStreamReliabilityConfig: TStreamReliabilityConfig;

{ Override defaults with env-var values when set. Recognised vars:
    UC_EMPTY_RETRY_ATTEMPTS     -- integer
    UC_EMPTY_RETRY_BACKOFF_MS   -- integer (milliseconds)
    UC_STREAM_IDLE_TIMEOUT_SEC  -- integer (seconds)
    UC_TOOL_CALL_REPAIR         -- 0/1/false/true
  Unset / malformed values fall through to the supplied Defaults. }
function LoadStreamReliabilityFromEnv(
  const Defaults: TStreamReliabilityConfig): TStreamReliabilityConfig;

{ The empty-turn shape: provider returned 2xx with no text, no tool
  calls, and a non-error finish_reason. This is the surface symptom
  of an upstream brownout. }
function IsEmptyTurn(const R: TLLMResponse): Boolean;

{ Drop-in wrapper around Provider.Chat that retries empty turns.
  All other failure modes (HTTP errors, exceptions) are passed
  through verbatim -- the tool-loop's fallback walk and OnError
  hooks handle those. Empty-turn retries do NOT attempt fallbacks;
  the primary provider gets every retry attempt. }
function ChatWithEmptyRetry(Provider: ILLMProvider;
                            const Messages: array of TMessage;
                            const Tools:    array of TToolDefinition;
                            const Model:    string;
                            const Options:  TChatOptions;
                            const Cfg:      TStreamReliabilityConfig): TLLMResponse;

{ Drop-in wrapper around Provider.ChatStream with idle-timeout and
  empty-turn retry. The wrapper runs ChatStream on a worker thread
  and watches the OnChunk timestamp from the calling thread; if no
  chunk arrives within Cfg.StreamIdleTimeoutMs the wrapper returns
  a synthetic empty response with FinishReason='timeout'.

  Worker-thread cleanup: when the watcher fires the wrapper sets a
  cancellation flag on the job. Any further chunks the worker
  receives are dropped on the floor (the user's OnChunk is not
  invoked). The worker continues until Provider.ChatStream returns
  -- typically when the underlying Indy ReadTimeout retires the
  socket -- at which point the job frees itself. No leaked sockets,
  no leaked threads.

  Empty-turn retry semantics for streams: only fires when the
  stream completed with ZERO chunks AND an empty TLLMResponse. If
  any chunks reached the user callback, we cannot retry without
  duplicate output downstream; the empty response (if any) is
  surfaced as-is. }
function ChatStreamWithReliability(Provider: ILLMProvider;
                                    const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback;
                                    const Cfg: TStreamReliabilityConfig): TLLMResponse;

{ Walk Msgs and synthesize stub mrTool messages for every assistant
  tool_call.Id that has no matched mrTool with ToolCallId equal to
  it. Stubs are inserted immediately after the assistant turn that
  emitted the orphaned call.

  Returns the number of stubs that were synthesized; callers can
  log a warning when > 0 so operators see when their client is
  shipping malformed histories. }
function RepairOrphanedToolCalls(var Msgs: TMessageArray): Integer;

implementation

uses
  DateUtils,
  PasClaw.Logger;

function DefaultStreamReliabilityConfig: TStreamReliabilityConfig;
begin
  Result.EmptyRetryAttempts    := 2;
  Result.EmptyRetryBackoffMs   := 750;
  Result.StreamIdleTimeoutMs   := 150 * 1000;
  Result.ToolCallRepairEnabled := True;
end;

function ParseIntEnv(const Name: string; Default_: Integer): Integer;
var
  S: string;
  V: Integer;
begin
  Result := Default_;
  S := GetEnvironmentVariable(Name);
  if S = '' then Exit;
  if TryStrToInt(Trim(S), V) and (V >= 0) then Result := V;
end;

function ParseBoolEnv(const Name: string; Default_: Boolean): Boolean;
var
  S: string;
begin
  Result := Default_;
  S := LowerCase(Trim(GetEnvironmentVariable(Name)));
  if S = '' then Exit;
  if (S = '1') or (S = 'true')  or (S = 'yes') or (S = 'on')  then Result := True
  else if (S = '0') or (S = 'false') or (S = 'no')  or (S = 'off') then Result := False;
end;

function LoadStreamReliabilityFromEnv(
  const Defaults: TStreamReliabilityConfig): TStreamReliabilityConfig;
var
  IdleSec: Integer;
begin
  Result := Defaults;
  Result.EmptyRetryAttempts  := ParseIntEnv('UC_EMPTY_RETRY_ATTEMPTS',
                                            Defaults.EmptyRetryAttempts);
  Result.EmptyRetryBackoffMs := ParseIntEnv('UC_EMPTY_RETRY_BACKOFF_MS',
                                            Defaults.EmptyRetryBackoffMs);
  IdleSec := ParseIntEnv('UC_STREAM_IDLE_TIMEOUT_SEC',
                         Defaults.StreamIdleTimeoutMs div 1000);
  Result.StreamIdleTimeoutMs := IdleSec * 1000;
  Result.ToolCallRepairEnabled := ParseBoolEnv('UC_TOOL_CALL_REPAIR',
                                                Defaults.ToolCallRepairEnabled);
end;

function IsEmptyTurn(const R: TLLMResponse): Boolean;
begin
  Result := (R.Content = '')
        and (Length(R.ToolCalls) = 0)
        and ((R.FinishReason = 'stop') or (R.FinishReason = '') or
             (R.FinishReason = 'end_turn'));
end;

function ChatWithEmptyRetry(Provider: ILLMProvider;
                            const Messages: array of TMessage;
                            const Tools:    array of TToolDefinition;
                            const Model:    string;
                            const Options:  TChatOptions;
                            const Cfg:      TStreamReliabilityConfig): TLLMResponse;
var
  Attempt: Integer;
  Backoff: Integer;
begin
  if Provider = nil then
  begin
    Result := Default(TLLMResponse);
    Result.StatusCode := -1;
    Exit;
  end;

  Result := Provider.Chat(Messages, Tools, Model, Options);
  if Cfg.EmptyRetryAttempts <= 0 then Exit;

  { Only retry the empty-turn shape. Any non-2xx, non-empty, or
    tool-call response is the caller's to handle. }
  Attempt := 0;
  Backoff := Cfg.EmptyRetryBackoffMs;
  if Backoff < 50 then Backoff := 50;
  while (Attempt < Cfg.EmptyRetryAttempts) and
        (Result.StatusCode >= 200) and (Result.StatusCode < 300) and
        IsEmptyTurn(Result) do
  begin
    Inc(Attempt);
    LogWarn('stream-reliability: empty turn from %s/%s, retry %d/%d after %dms',
            [Provider.GetName, Model, Attempt, Cfg.EmptyRetryAttempts, Backoff]);
    Sleep(Backoff);
    Result := Provider.Chat(Messages, Tools, Model, Options);
    Backoff := Backoff * 2;
    if Backoff > 16000 then Backoff := 16000;
  end;
end;

type
  TStreamJob = class(TThread)
  private
    FProvider:    ILLMProvider;
    FMessages:    TMessageArray;
    FTools:       TToolDefinitionArray;
    FModel:       string;
    FOptions:     TChatOptions;
    FUserOnChunk: TStreamCallback;
    FLock:        TCriticalSection;
    FLastChunkAt: TDateTime;
    FChunkCount:  Integer;
    FCancelled:   Boolean;
    FResp:        TLLMResponse;
    FExceptionMsg: string;
    procedure InternalOnChunk(const C: TStreamChunk);
  protected
    procedure Execute; override;
  public
    Done: TEvent;
    constructor Create(AProvider: ILLMProvider;
                       const AMessages: array of TMessage;
                       const ATools: array of TToolDefinition;
                       const AModel: string;
                       const AOptions: TChatOptions;
                       AUserOnChunk: TStreamCallback);
    destructor Destroy; override;
    procedure Cancel;
    procedure Detach;
    function  GetLastChunkAt: TDateTime;
    function  GetChunkCount: Integer;
    function  GetResp: TLLMResponse;
    function  GetExceptionMsg: string;
  end;

constructor TStreamJob.Create(AProvider: ILLMProvider;
                              const AMessages: array of TMessage;
                              const ATools: array of TToolDefinition;
                              const AModel: string;
                              const AOptions: TChatOptions;
                              AUserOnChunk: TStreamCallback);
var
  i: Integer;
begin
  inherited Create(True);  { suspended; caller Start's after construction }
  { FreeOnTerminate stays False on the happy path so the wrapper can
    safely read FResp + Free the job after Done signals. The timeout
    branch flips it to True before walking away (Detach), turning the
    job into a self-cleaning orphan that finishes draining the
    provider stream in the background. }
  FreeOnTerminate := False;
  FProvider    := AProvider;
  FModel       := AModel;
  FOptions     := AOptions;
  FUserOnChunk := AUserOnChunk;
  SetLength(FMessages, Length(AMessages));
  for i := 0 to High(AMessages) do FMessages[i] := AMessages[i];
  SetLength(FTools, Length(ATools));
  for i := 0 to High(ATools) do FTools[i] := ATools[i];
  FLock        := TCriticalSection.Create;
  FLastChunkAt := Now;
  FChunkCount  := 0;
  FCancelled   := False;
  Done         := TEvent.Create(nil, True, False, '');
end;

destructor TStreamJob.Destroy;
begin
  FLock.Free;
  Done.Free;
  inherited;
end;

procedure TStreamJob.Cancel;
begin
  FLock.Enter;
  try
    FCancelled := True;
  finally
    FLock.Leave;
  end;
end;

procedure TStreamJob.Detach;
{ Hand ownership of the job to the runtime: from here the worker
  will self-free when its Execute returns. The wrapper invokes this
  right before walking away on the timeout path so the still-running
  worker doesn't leak. Caller must not touch the job after Detach. }
begin
  FreeOnTerminate := True;
end;

procedure TStreamJob.InternalOnChunk(const C: TStreamChunk);
var
  FireUser: Boolean;
  Cb: TStreamCallback;
begin
  FLock.Enter;
  try
    FLastChunkAt := Now;
    Inc(FChunkCount);
    FireUser := (not FCancelled) and Assigned(FUserOnChunk);
    Cb := FUserOnChunk;
  finally
    FLock.Leave;
  end;
  if FireUser then
  begin
    { User OnChunk may write to a torn-down connection; swallow any
      exception so the worker can still drain the provider stream
      cleanly. Without this the provider would see its own callback
      raise, often classify it as a hard error, and we'd lose the
      finish_reason on the final response. }
    try
      Cb(C);
    except
      on E: Exception do
        LogDebug('stream-reliability: user OnChunk raised %s: %s',
                 [E.ClassName, E.Message]);
    end;
  end;
end;

procedure TStreamJob.Execute;
begin
  try
    FResp := FProvider.ChatStream(FMessages, FTools, FModel, FOptions,
                                   InternalOnChunk);
  except
    on E: Exception do
    begin
      FExceptionMsg := E.ClassName + ': ' + E.Message;
      FResp := Default(TLLMResponse);
      FResp.StatusCode := -1;
    end;
  end;
  Done.SetEvent;
end;

function TStreamJob.GetLastChunkAt: TDateTime;
begin
  FLock.Enter;
  try
    Result := FLastChunkAt;
  finally
    FLock.Leave;
  end;
end;

function TStreamJob.GetChunkCount: Integer;
begin
  FLock.Enter;
  try
    Result := FChunkCount;
  finally
    FLock.Leave;
  end;
end;

function TStreamJob.GetResp: TLLMResponse;
begin
  Result := FResp;
end;

function TStreamJob.GetExceptionMsg: string;
begin
  Result := FExceptionMsg;
end;

function RunOneStream(Provider: ILLMProvider;
                      const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions;
                      OnChunk: TStreamCallback;
                      IdleTimeoutMs: Integer;
                      out ChunkCount: Integer;
                      out TimedOut: Boolean): TLLMResponse;
const
  PollMs = 500;
var
  Job: TStreamJob;
  IdleMs: Integer;
  WaitRes: TWaitResult;
begin
  TimedOut   := False;
  ChunkCount := 0;
  if IdleTimeoutMs <= 0 then
  begin
    { Watcher disabled -- pass through directly. Avoids the worker-
      thread overhead for callers that don't want kill semantics. }
    Result := Provider.ChatStream(Messages, Tools, Model, Options, OnChunk);
    Exit;
  end;

  Job := TStreamJob.Create(Provider, Messages, Tools, Model, Options, OnChunk);
  Job.Start;
  try
    while True do
    begin
      WaitRes := Job.Done.WaitFor(PollMs);
      if WaitRes = wrSignaled then
      begin
        Result     := Job.GetResp;
        ChunkCount := Job.GetChunkCount;
        if Job.GetExceptionMsg <> '' then
          LogWarn('stream-reliability: ChatStream raised: %s',
                  [Job.GetExceptionMsg]);
        { Worker has signalled Done as its last act in Execute --
          waiting on the OS thread handle here ensures Execute has
          fully unwound before we free the object. Without the
          WaitFor the worker can still be in its post-Execute
          cleanup when we Free below, producing an AV. }
        Job.WaitFor;
        Job.Free;
        Job := nil;
        Exit;
      end;
      IdleMs := MilliSecondsBetween(Now, Job.GetLastChunkAt);
      if IdleMs >= IdleTimeoutMs then
      begin
        Job.Cancel;
        ChunkCount := Job.GetChunkCount;
        TimedOut   := True;
        LogWarn('stream-reliability: ChatStream idle >%dms (chunks=%d) -- declaring timeout, draining in background',
                [IdleMs, ChunkCount]);
        Result := Default(TLLMResponse);
        Result.FinishReason := 'timeout';
        Result.StatusCode   := -1;
        { Detach hands the job to FreeOnTerminate cleanup: it stays
          alive draining the provider stream until Indy's ReadTimeout
          retires the socket, then self-frees. No leaked sockets,
          no leaked threads. }
        Job.Detach;
        Job := nil;
        Exit;
      end;
    end;
  except
    { On unexpected wrapper-side exception, cancel + detach the job
      so the orphaned worker stops calling back into the (possibly
      freed) user OnChunk, and re-raise. Job self-frees when its
      Execute returns. }
    if Job <> nil then
    begin
      Job.Cancel;
      Job.Detach;
    end;
    raise;
  end;
end;

function ChatStreamWithReliability(Provider: ILLMProvider;
                                    const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback;
                                    const Cfg: TStreamReliabilityConfig): TLLMResponse;
var
  Attempt, Backoff, ChunkCount: Integer;
  TimedOut: Boolean;
begin
  if Provider = nil then
  begin
    Result := Default(TLLMResponse);
    Result.StatusCode := -1;
    Exit;
  end;

  Result := RunOneStream(Provider, Messages, Tools, Model, Options,
                          OnChunk, Cfg.StreamIdleTimeoutMs,
                          ChunkCount, TimedOut);

  if (Cfg.EmptyRetryAttempts <= 0) or TimedOut then Exit;

  { Empty-turn retry only fires when the stream produced no chunks
    AND landed on the empty shape. If chunks reached the user
    callback, retrying would duplicate output downstream -- skip. }
  Attempt := 0;
  Backoff := Cfg.EmptyRetryBackoffMs;
  if Backoff < 50 then Backoff := 50;
  while (Attempt < Cfg.EmptyRetryAttempts) and
        (ChunkCount = 0) and
        (Result.StatusCode >= 200) and (Result.StatusCode < 300) and
        IsEmptyTurn(Result) do
  begin
    Inc(Attempt);
    LogWarn('stream-reliability: empty stream from %s/%s, retry %d/%d after %dms',
            [Provider.GetName, Model, Attempt, Cfg.EmptyRetryAttempts, Backoff]);
    Sleep(Backoff);
    Result := RunOneStream(Provider, Messages, Tools, Model, Options,
                            OnChunk, Cfg.StreamIdleTimeoutMs,
                            ChunkCount, TimedOut);
    if TimedOut then Exit;
    Backoff := Backoff * 2;
    if Backoff > 16000 then Backoff := 16000;
  end;
end;

function HasMatchingToolResult(const Msgs: TMessageArray;
                                StartAfter: Integer;
                                const ToolCallId: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if ToolCallId = '' then Exit;
  for i := StartAfter + 1 to High(Msgs) do
    if (Msgs[i].Role = mrTool) and (Msgs[i].ToolCallId = ToolCallId) then
      Exit(True);
end;

function InsertStubAt(var Msgs: TMessageArray; InsertAt: Integer;
                      const ToolCallId, FuncName: string): Integer;
{ Insert a stub mrTool message at InsertAt. Returns 1 (one stub
  added) so the caller can roll up the count. The insertion shifts
  every subsequent index by one; callers walking the array re-read
  Length(Msgs) and adjust their loop variables accordingly. }
var
  i: Integer;
  Stub: TMessage;
begin
  Stub := Default(TMessage);
  Stub.Role       := mrTool;
  Stub.ToolCallId := ToolCallId;
  Stub.Name       := FuncName;
  Stub.Content    := '[tool result missing -- repaired by gateway]';
  SetLength(Msgs, Length(Msgs) + 1);
  for i := High(Msgs) downto InsertAt + 1 do
    Msgs[i] := Msgs[i - 1];
  Msgs[InsertAt] := Stub;
  Result := 1;
end;

function RepairOrphanedToolCalls(var Msgs: TMessageArray): Integer;
var
  i, j, InsertAt: Integer;
  Asst: TMessage;
  Tc: TToolCall;
begin
  Result := 0;
  i := 0;
  while i <= High(Msgs) do
  begin
    if Msgs[i].Role = mrAssistant then
    begin
      Asst := Msgs[i];
      InsertAt := i + 1;
      for j := 0 to High(Asst.ToolCalls) do
      begin
        Tc := Asst.ToolCalls[j];
        if Tc.Id = '' then Continue;
        if not HasMatchingToolResult(Msgs, i, Tc.Id) then
        begin
          Inc(Result, InsertStubAt(Msgs, InsertAt, Tc.Id, Tc.Func.Name));
          Inc(InsertAt);
        end;
      end;
      { Advance past the assistant + any stubs we just inserted. }
      i := InsertAt;
    end
    else
      Inc(i);
  end;
  if Result > 0 then
    LogWarn('stream-reliability: tool-call repair synthesized %d stub result(s)',
            [Result]);
end;

end.
