(*
  PasClaw.Providers.Relay - the "pull-worker" LLM provider.

  Inverts the usual provider direction. Instead of making outbound
  HTTP calls to a hosted LLM API, this provider PUSHES requests into
  PasClaw's in-process relay queue
  (PasClaw.Gateway.RelayQueue). External worker apps -- a WebGPU
  browser tab, a phone running mlc-llm, a desktop running llama.cpp,
  anything that speaks HTTP+SSE -- connect INBOUND to the gateway,
  pull requests off the queue, run inference on their own hardware,
  and POST results back.

  Why
  ===

  Three real-world flows this unblocks:
    1. Use a laptop's WebGPU for inference without exposing ports.
       The browser tab connects outbound to PasClaw; PasClaw never
       needs to reach the laptop.
    2. Cog/Replicate-hosted PasClaw served by an inference worker on
       a phone in your pocket. Cog never calls a paid LLM API.
    3. Share a home GPU across multiple devices in the family. Each
       device runs its own PasClaw; one home server runs the queue.

  See `docs/providers-relay.md` for the wire protocol.

  V1 scope
  ========

  - Non-streaming only. Worker returns one POST with the full
    completion. Streaming back through PasClaw needs per-request
    SSE channels (V2).
  - Tool calls are TEXT-PARSED from the model reply. The worker
    serves raw text; PasClaw's existing tool-call extraction (already
    used for some text-completion fallbacks) picks them out. Smaller
    local models without strong tool support get text-only chat.
    Structured tool calls from workers that support them (V2).
  - Capability matching is EXACT case-insensitive string match on
    the model id. Glob / semver matching is V2.
  - Single-process. One TRelayQueue, one set of workers, one provider.

  Catalog row
  ===========

    Kind:         relay
    DisplayName:  Relay (Pull-Worker)
    Family:       pfRelay (new TProtocolFamily value)
    DefaultBase:  '' (no URL -- the queue is in-process)
    DefaultModel: '' (whatever the connected workers can serve)
    Auth:         asNone (workers authenticate to /v1/relay/poll
                  with the same gateway token PasClaw's other
                  endpoints use; the provider doesn't auth)

  Notes for callers
  ==================

  Chat() blocks until a worker picks up the request and responds, or
  the configured timeout elapses. Default timeout is
  RelayDefaultWaitTimeoutMs (5 minutes) -- override via the provider's
  WaitTimeoutMs property. The agent loop's fallback chain handles a
  relay timeout the same way it handles any other provider failure
  (HTTP 5xx-ish): walks the configured fallback providers.

  No workers connected = wait for one. The Chat() call blocks for the
  full timeout if no worker ever appears. Surface this in the TUI /
  /v1/relay/status so operators can spot it before the timeout
  expires.
*)
unit PasClaw.Providers.Relay;

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
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Gateway.RelayQueue;

type
  TRelayProvider = class(TInterfacedObject, ILLMProvider)
  private
    FDefaultModel:  string;
    FDisplayName:   string;
    FWaitTimeoutMs: Integer;
    function BuildRequestJSON(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions;
                              const RequestId: string): string;
    function DecodeResponse(const R: TRelayResponse;
                            const RequestedModel: string): TLLMResponse;
  public
    constructor Create(const ADefaultModel: string;
                       const ADisplayName: string = 'relay';
                       AWaitTimeoutMs: Integer = 0);
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    { Override the per-Chat timeout. 0 = use RelayDefaultWaitTimeoutMs. }
    property WaitTimeoutMs: Integer read FWaitTimeoutMs write FWaitTimeoutMs;
  end;

{ Helper exposed for tests + the gateway's poll-side serialiser. Wraps
  PasClaw.JSON to build the on-the-wire envelope a worker sees. Pure;
  no provider state. }
function BuildRelayRequestBody(const Messages: array of TMessage;
                               const Tools:    array of TToolDefinition;
                               const Model:    string;
                               const Options:  TChatOptions;
                               const RequestId: string): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger;

function BuildRelayRequestBody(const Messages: array of TMessage;
                               const Tools:    array of TToolDefinition;
                               const Model:    string;
                               const Options:  TChatOptions;
                               const RequestId: string): string;
var
  Root, MsgObj, ToolObj, OptsObj, TCObj, FnObj: TJsonObject;
  MsgArr, ToolArr, TCArr: TJsonArray;
  i, j: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('id',    RequestId);
    Root.PutStr('model', Model);
    { session_id: opaque conversation identifier, empty for one-shot
      turns. The gateway's queue uses this for sticky routing (keep
      multi-turn sessions on the same worker for KV-cache locality);
      workers can read it for their own cache reuse. Only emit when
      non-empty so workers don't see a noisy 'session_id: ""' field. }
    if Options.CacheKey <> '' then
      Root.PutStr('session_id', Options.CacheKey);

    (* messages: full conversation. The worker is stateless -- it
       sees the entire history on every call.

       Tool-call metadata MUST round-trip. A multi-turn relayed
       session that fires a tool call has assistant messages carrying
       ToolCalls and tool-result messages carrying ToolCallId / Name
       -- provider request builders (OpenAI, Anthropic, Gemini)
       require these to thread the call/result pair. Dropping them on
       the worker wire (as the original V1 did) made the second turn
       after any tool call fail with "missing tool_call_id" or stall
       silently. Emit the OpenAI-shape envelope so workers that
       forward through any OpenAI-compatible (and Anthropic/Gemini
       via their adapters) provider get a valid request shape:

         - assistant with tool calls: role="assistant", content, and
           a tool_calls array of objects each with id, type, and a
           function sub-object holding name and arguments.
         - tool result: role="tool", tool_call_id, name (the tool
           name), and content (the tool's output as a string).
         - named system/user message (rare): adds a top-level name
           field alongside role / content.

       Codex P1 review on PR #323. *)
    MsgArr := TJsonArray.Create;
    for i := 0 to High(Messages) do
    begin
      MsgObj := TJsonObject.Create;
      MsgObj.PutStr('role',    MsgRoleToString(Messages[i].Role));
      MsgObj.PutStr('content', Messages[i].Content);
      if Messages[i].Name <> '' then
        MsgObj.PutStr('name', Messages[i].Name);
      if Messages[i].ToolCallId <> '' then
        MsgObj.PutStr('tool_call_id', Messages[i].ToolCallId);
      if Length(Messages[i].ToolCalls) > 0 then
      begin
        TCArr := TJsonArray.Create;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          TCObj := TJsonObject.Create;
          TCObj.PutStr('id',   Messages[i].ToolCalls[j].Id);
          TCObj.PutStr('type', Messages[i].ToolCalls[j].Kind);
          FnObj := TJsonObject.Create;
          FnObj.PutStr('name',      Messages[i].ToolCalls[j].Func.Name);
          FnObj.PutStr('arguments', Messages[i].ToolCalls[j].Func.Arguments);
          TCObj.PutObject('function', FnObj);
          TCArr.AddObject(TCObj);
        end;
        MsgObj.PutArray('tool_calls', TCArr);
      end;
      MsgArr.AddObject(MsgObj);
    end;
    Root.PutArray('messages', MsgArr);

    (* tools: shipped as objects with name / description / parameters
       so a worker that supports tool calling can use them. Workers
       without tool support emit tool calls as text and PasClaw's
       tool-call text extractor handles them. *)
    ToolArr := TJsonArray.Create;
    for i := 0 to High(Tools) do
    begin
      ToolObj := TJsonObject.Create;
      ToolObj.PutStr('name',        Tools[i].Name);
      ToolObj.PutStr('description', Tools[i].Description);
      { Schema is already JSON; emit verbatim by writing it as a raw
        string under the parameters key. Worker parses to get the
        schema. }
      ToolObj.PutStr('parameters', Tools[i].Schema);
      ToolArr.AddObject(ToolObj);
    end;
    Root.PutArray('tools', ToolArr);

    { options: subset of TChatOptions the worker needs. Temperature
      and max_tokens are the universal ones; system_prompt as a
      convenience for workers that have an OpenAI-shaped chat
      interface. Anything else stays in TChatOptions on the PasClaw
      side -- workers don't see it. }
    OptsObj := TJsonObject.Create;
    OptsObj.PutInt ('max_tokens',  Options.MaxTokens);
    if Options.Temperature > 0 then
      OptsObj.PutStr('temperature', FloatToStr(Options.Temperature));
    if Options.SystemPrompt <> '' then
      OptsObj.PutStr('system_prompt', Options.SystemPrompt);
    Root.PutObject('options', OptsObj);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

constructor TRelayProvider.Create(const ADefaultModel: string;
                                   const ADisplayName: string;
                                   AWaitTimeoutMs: Integer);
begin
  inherited Create;
  FDefaultModel  := ADefaultModel;
  FDisplayName   := ADisplayName;
  if AWaitTimeoutMs > 0 then
    FWaitTimeoutMs := AWaitTimeoutMs
  else
    FWaitTimeoutMs := RelayDefaultWaitTimeoutMs;
end;

function TRelayProvider.BuildRequestJSON(const Messages: array of TMessage;
                                          const Tools:    array of TToolDefinition;
                                          const Model:    string;
                                          const Options:  TChatOptions;
                                          const RequestId: string): string;
begin
  Result := BuildRelayRequestBody(Messages, Tools, Model, Options, RequestId);
end;

function TRelayProvider.DecodeResponse(const R: TRelayResponse;
                                        const RequestedModel: string): TLLMResponse;
var
  i: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Content      := R.Content;
  Result.FinishReason := R.FinishReason;
  Result.Usage.InputTokens  := R.UsageInput;
  Result.Usage.OutputTokens := R.UsageOutput;
  Result.Model        := RequestedModel;
  { Codex P2 on PR #318: copy structured tool calls into TLLMResponse
    so RunToolLoop dispatches them. V1 doc claimed "tool calls are
    text-parsed from the model reply" but no parser existed; relay-
    backed agent flows silently stalled after the first tool call.
    Workers using inference libraries that emit structured tool calls
    (WebLLM, llama.cpp grammar mode, mlc-llm, etc.) put them in the
    `tool_calls` array of the response JSON; HandleRelayRespond
    parses them into TRelayResponse.ToolCalls; here we forward.
    Workers that only emit text are unchanged -- they get text-only
    chat through the relay, same as before this fix. }
  SetLength(Result.ToolCalls, Length(R.ToolCalls));
  for i := 0 to High(R.ToolCalls) do
    Result.ToolCalls[i] := R.ToolCalls[i];
  if R.ErrMsg <> '' then
  begin
    { Match the convention other providers use: StatusCode -1 means
      pre-HTTP failure (network / TLS / etc.). The fallback walker
      treats this as retryable. }
    Result.StatusCode := -1;
    { Surface the error text in Content so logs / a verbose CLI run
      shows what happened. The empty-reply fallback in the gateway's
      stream-reliability shim won't kick in here -- a -1 status code
      short-circuits to fallback walk. }
    if Result.Content = '' then
      Result.Content := '[relay error: ' + R.ErrMsg + ']';
  end
  else
    Result.StatusCode := 200;
end;

function TRelayProvider.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Q:       TRelayQueue;
  Req:     TRelayRequest;
  ReqId:   string;
  Body:    string;
  EffMod:  string;
  Sig:     TWaitResult;
begin
  FillChar(Result, SizeOf(Result), 0);
  Q := GetGlobalRelayQueue;
  if Q = nil then
  begin
    Result.StatusCode := -1;
    Result.Content    := '[relay error: no gateway running -- relay queue not initialised. ' +
                         'Start `pasclaw gateway` or run with --gateway-port to enable.]';
    LogWarn('relay: Chat() called with no global queue');
    Exit;
  end;

  if Model <> '' then EffMod := Model else EffMod := FDefaultModel;
  ReqId := NewRelayRequestId;
  Body  := BuildRelayRequestBody(Messages, Tools, EffMod, Options, ReqId);

  { Pass Options.CacheKey (the conversation/session id PasClaw threads
    through the agent loop) as the sticky-routing key. Empty for one-
    shot turns (no session) -- in which case the queue just FCFS-
    dispatches. Non-empty for sessioned conversations -- in which
    case the queue keeps subsequent turns on the same worker for
    KV-cache locality. The session id is opaque to the worker; we
    also include it in the request envelope (see BuildRelayRequestBody)
    so workers that can do their own KV cache reuse have a key to
    work with. }
  Req := TRelayRequest.Create(ReqId, EffMod, Body, Options.CacheKey);
  Q.Enqueue(Req);
  LogInfo('relay: enqueued %s (model=%s, %d messages, %d tools)',
          [ReqId, EffMod, Length(Messages), Length(Tools)]);
  try
    Sig := Req.Done.WaitFor(Cardinal(FWaitTimeoutMs));
    case Sig of
      wrSignaled:
        if Req.ResponseValid then
          Result := DecodeResponse(Req.Response, EffMod)
        else
        begin
          Result.StatusCode := -1;
          Result.Content    := '[relay error: signalled without response (queue shutdown?)]';
          LogWarn('relay: %s signalled without ResponseValid', [ReqId]);
        end;
      wrTimeout:
        begin
          Result.StatusCode := -1;
          Result.Content    := Format('[relay error: timed out after %d ms waiting for a worker. ' +
                                       'Check /v1/relay/status for connected workers and their ' +
                                       'capabilities.]', [FWaitTimeoutMs]);
          LogWarn('relay: %s timed out after %d ms', [ReqId, FWaitTimeoutMs]);
        end;
    else
      Result.StatusCode := -1;
      Result.Content    := '[relay error: wait failed]';
      LogWarn('relay: %s wait failed (%d)', [ReqId, Ord(Sig)]);
    end;
  finally
    { Codex P1 on PR #318: the original code freed Req in finally
      without checking whether the queue still held a reference. On
      every non-success exit (timeout, abort, wait failure) the
      request was still in FPending or FInflight, and freeing here
      left the queue with a dangling pointer that a later worker
      Respond or queue Destroy would dereference.

      Cancel returns True iff it actually pulled the request out of a
      queue list -- we own the memory in that case and must Free.
      Cancel returns False iff the request was already consumed by a
      Respond that arrived between WaitFor wake and this Cancel call
      -- which means the response decode above already ran on
      Req.Response (snapshot taken before any race), and the request
      is no longer reachable from queue state, so we still own the
      memory and still Free here. Either way Cancel guarantees the
      queue no longer holds a pointer; either way we Free. The
      Cancel-then-always-Free idiom is the simplest correct shape. }
    Q.Cancel(ReqId);
    Req.Free;
  end;
end;

function TRelayProvider.ChatStream(const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
var
  Final: TLLMResponse;
  Chunk: TStreamChunk;
begin
  { V1: no real streaming. Fall through to the blocking Chat() then
    emit ONE synthesised text chunk + a done chunk so callers using
    the streaming surface still get the body. Streaming back through
    the relay needs per-request SSE channels worker -> gateway ->
    agent loop, which is a V2 feature. }
  Final := Chat(Messages, Tools, Model, Options);
  if Assigned(OnChunk) then
  begin
    FillChar(Chunk, SizeOf(Chunk), 0);
    Chunk.Kind := 'text';
    Chunk.Text := Final.Content;
    OnChunk(Chunk);

    FillChar(Chunk, SizeOf(Chunk), 0);
    Chunk.Kind  := 'usage';
    Chunk.Usage := Final.Usage;
    OnChunk(Chunk);

    FillChar(Chunk, SizeOf(Chunk), 0);
    Chunk.Kind := 'done';
    OnChunk(Chunk);
  end;
  Result := Final;
end;

function TRelayProvider.GetDefaultModel: string;
begin
  Result := FDefaultModel;
end;

function TRelayProvider.GetName: string;
begin
  Result := FDisplayName;
end;

function TRelayProvider.SupportsThinking: Boolean;
begin
  Result := False;
end;

function TRelayProvider.SupportsNativeSearch: Boolean;
begin
  Result := False;
end;

function TRelayProvider.SupportsStreaming: Boolean;
{ Returns False because V1's "streaming" is a fake -- ChatStream just
  emits one chunk with the whole reply. Returning False lets the
  caller take its non-streaming path explicitly. }
begin
  Result := False;
end;

end.
