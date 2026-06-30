{
  PasClaw.Tools.ToolLoop - the core agent loop. Repeatedly calls the LLM
  with the running message history; if the response contains tool_calls,
  dispatches each through the registry, appends the tool result as a tool
  message, and continues. Mirrors pkg/tools/toolloop.go.
}
unit PasClaw.Tools.ToolLoop;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry,
  PasClaw.Agent.Compact,
  PasClaw.Agent.Hooks,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Steering,
  PasClaw.Identity,
  PasClaw.Stream.Reliability,
  PasClaw.Config;   { TConfig + SetActiveConfig for the per-dispatch override }

type
  TToolLoopConfig = record
    Provider:      ILLMProvider;
    Registry:      TToolRegistry;
    Model:         string;
    MaxIterations: Integer;
    Options:       TChatOptions;
    OnText:        procedure(const S: string) of object;   { streaming-ish stdout }
    OnToolCall:    procedure(const Name, ArgsJSON: string) of object;
    OnToolResult:  procedure(const Name, ResultText, Err: string) of object;
    (* Compaction: when the running history exceeds Compact.ThresholdTokens,
       slice off the older portion, summarise it via Provider.Chat, and
       replace it with a single system message before the next round.
       CompactEnabled gates the whole thing -- default off; the
       command-layer enables it from Cfg.Compaction. CompactOpts is the
       full options struct (threshold, recent-turn count, summary budget,
       and the OnBefore memory-flush hook). *)
    CompactEnabled: Boolean;
    CompactOpts:    TCompactOptions;
    (* Parallel tool dispatch. When True, RunToolLoop partitions each
       round's tool calls into batches: consecutive tcReadOnly calls
       (see PasClaw.Tools.Types.TToolCategory) form one parallel batch
       and run on dedicated worker threads; each tcMutating call is a
       batch of one and runs serially. When False, every call runs
       serially in array order -- same as the pre-parallel behaviour.
       Default False on the record (zero-init); the CLI and the
       built-in components flip it on explicitly. *)
    Parallel:       Boolean;
    (* Provider fallback chain. When the primary Provider returns a
       retryable error (StatusCode = 0 / -1 / 408 / 429 / 5xx),
       RunToolLoop walks Fallbacks in order, calling Chat on each
       until one succeeds (StatusCode 2xx) or all fail. Empty
       array -- same as the old behaviour, primary failure surfaces
       directly. Callers populate from TConfig.Fallbacks by
       resolving each name through NewProviderFromConfig (see
       PasClaw.Providers.Factory.ResolveFallbacks). The named
       TLLMProviderArray type -- not an inline `array of ILLMProvider`
       -- is required because dcc64 enforces strict named-type matching
       on dynamic-array assignments. *)
    Fallbacks:      TLLMProviderArray;
    (* Optional per-fallback model override, parallel to Fallbacks by
       index. When FallbackModels[i] is non-empty it is the model used
       for Fallbacks[i] instead of that provider's GetDefaultModel; an
       empty entry (or an index past the end of this array) falls through
       to the GetDefaultModel -> Cfg.Model behaviour. Left empty by most
       callers -- the catalog GetDefaultModel path is correct out of the
       box. The auto-router populates [0] with the caller's pre-route
       model when it prepends the original primary, so a routing-fooled
       turn retries the primary with the model the caller actually
       requested (--model / TUI picker / request model) rather than the
       primary's catalog default. *)
    FallbackModels: TStringArray;
    (* Hook callbacks for observe / veto / transform / steer. See
       PasClaw.Agent.Hooks for the TPasClawHook base class and the
       four virtuals embedders override (BeforeTurn, BeforeToolCall,
       AfterToolResult, OnError). Hooks fire on the main thread in
       array order even when tool dispatch is parallel -- same
       ordering guarantees the legacy OnToolCall / OnToolResult
       events have. RunToolLoop doesn't own the hooks; caller
       lifetime applies. *)
    Hooks:          TPasClawHookArray;
    (* Canonical sender identity for the turn. Channels populate this
       from the inbound payload (Slack user id, Matrix MXID, Telegram
       message.from.id, email From, etc.); the CLI sets cli:<$USER>.
       Default zero record means "unknown / not propagated" --
       surfaces as '(unknown)' in logs. The allowlist gate
       (PasClaw.Identity.IsAllowedSender) runs at the CHANNEL
       boundary BEFORE RunToolLoop; by the time the loop is called,
       the operator has already approved this sender. RunToolLoop
       copies Identity onto every registered TPasClawHook before
       dispatching so hook subclasses can read `Self.Identity` to
       gate per-tool / per-turn behaviour. *)
    Identity:       TIdentity;
    (* Mid-loop steering: the queue key for PasClaw.Agent.Steering.
       When non-empty, RunToolLoop drains the queue at iteration top
       and folds pending messages into history as mrSystem turns
       ("[user steering]: ..."), so the LLM's next round-trip sees
       the user's course-correction without aborting the loop or
       discarding tool results so far. Empty key = steering disabled
       (CLI / cron one-shot paths don't bother).
       Cmd.Agent sets this to Session.Meta.Id (always present since
       PR #117); channels can set their own per-conversation key
       when wiring concurrent polling. *)
    SteeringKey:    string;
    (* Background-subagent drain key. Symmetric with SteeringKey:
       PasClaw.Agent.SubagentBg registers itself in a key->coordinator
       map under THIS string; at each iteration top RunToolLoop calls
       GBackgroundDrainHook(BackgroundDrainKey) and folds any
       finished-and-not-yet-delivered results into the system prompt
       so the model sees them automatically. Empty key = no
       background subagents installed for this session. Cmd.Agent
       sets this to Session.Meta.Id, same as SteeringKey. *)
    BackgroundDrainKey: string;
    (* Tool output truncation cap in bytes. When > 0, RunToolLoop
       runs each tool's ResultText through StashAndMaybeTruncate
       (PasClaw.Tools.OutputCache) before appending it to history:
       results exceeding the cap get replaced with a head + tail
       snippet and a handle the model can dereference via the
       `tool_output_get` tool. 0 (default) leaves output verbatim --
       same as the pre-PR behaviour. Callers wanting the savings
       set this to ~8192 and register the OutputCache tool on the
       same registry. *)
    ToolOutputCap:  Integer;
    (* Stream-reliability knobs. When EmptyRetryAttempts > 0 the
       loop's primary Provider.Chat goes through ChatWithEmptyRetry,
       which retries empty-turn responses (Content='' + no tool
       calls + finish_reason='stop') up to N times with exponential
       backoff. Fallback-walk semantics are unchanged -- the retry
       fires on the primary provider only, BEFORE the fallback walk
       sees the response. Zero attempts (default record value)
       means single-shot behaviour, same as pre-PR. The other
       fields (StreamIdleTimeoutMs, ToolCallRepairEnabled) don't
       apply to the synchronous tool loop -- they're surfaced by
       gateway / channel paths that drive ChatStream directly. *)
    StreamReliability: TStreamReliabilityConfig;
    (* Plan / Build mode (PR #290). pmBuild (zero / default) preserves
       the historical full-access behaviour; pmPlan refuses any tool
       whose Category = tcMutating at dispatch time with a clear
       "switch to build mode" message in the tool result. The CLI / TUI
       set this per-process; the gateway sets it per-request from the
       JSON body's "mode" field. The system prompt also gets a "PLAN
       MODE" addendum when pmPlan -- see PasClaw.Agent.Prompt. *)
    Mode: TPasClawMode;
    (* Optional in-memory config published to tool handlers for this run.
       When non-nil, DispatchOneToolCall sets it as the thread-scoped active
       config around each tool call, so tools that would otherwise LoadConfig
       from disk (web_search, send_message, memory, kb) honour it via
       LoadEffectiveConfig. Set by TPasClawAgent (its FConfig) so a
       code-configured / no-disk embed reaches the tools; nil for the CLI,
       TUI, and bare gateway, which keep the LoadConfig disk hot-reload. *)
    ActiveConfig: TConfig;
  end;

  TToolLoopResult = record
    Content:     string;
    Iterations:  Integer;
    LastResp:    TLLMResponse;
    (* Aggregate usage across every provider call this loop made.
       LastResp only carries the final iteration's usage; a multi-tool
       turn that runs 4 provider calls would otherwise hide the cache
       reads / writes / token counts from the first 3 calls. Callers
       surfacing per-turn metrics (CLI /status, gateway response usage
       block) should read TotalUsage, not LastResp.Usage. Codex P2 on
       PR #118. *)
    TotalUsage:  TUsageInfo;
    (* How many tool results were diverted into the OutputCache during
       this loop, plus the total bytes saved (sum of original sizes
       minus the in-context replacement sizes). Surfaced by the TUI's
       /stats overlay so the operator can see the savings; zero when
       Cfg.ToolOutputCap = 0. *)
    Truncations:        Integer;
    TruncatedBytesSaved: Int64;
    (* Aggregate count of tool calls dispatched across the loop's
       iterations. Lets callers persisting per-session stats
       attribute "how chatty was this turn" without re-walking the
       message history. Zero on a single-shot response that needed
       no tool use. *)
    ToolCallsDispatched: Int64;
    (* The final history at the moment RunToolLoop returns, with all
       in-flight compactions applied. Interactive callers (Cmd.Agent's
       RunInteractive, the TUI) read this back into their own message
       array so the NEXT turn starts from the compacted state instead
       of re-summarising the original transcript on every prompt
       (Codex PR #87 P2). Includes assistant + tool messages produced
       during the loop; leading mrSystem entries that compaction lifted
       into Options.SystemPrompt are NOT in this list. *)
    FinalMessages:    TMessageArray;
    FinalSystemPrompt: string;
    (* Set True when the loop stopped because it reached Cfg.MaxIterations
       while the model still wanted to call tools -- i.e. the task is most
       likely UNFINISHED, not a clean stop. Callers surface a "stopped at
       the limit -- reply to continue" notice (FormatMaxIterNotice) instead
       of presenting the partial output as a completed answer. *)
    HitMaxIterations: Boolean;
    (* Distinct tool names from the final (never-fed-back) model response
       when HitMaxIterations -- the "what it was doing when it stopped"
       detail for the notice. Empty otherwise. *)
    PendingToolNames: TArray<string>;
  end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;

{ The textual result of a finished loop. Loop.Content is the final assistant
  text, but it is EMPTY when the loop ended on a tool-call round or hit
  MaxIterations without a closing text turn -- which makes a subagent's
  spawn_wait return a bare "(no output)" even though the job ran. Fall back to
  the last non-empty assistant text in history, then to a clear note explaining
  there was no final answer (so callers never surface emptiness as success). }
function LoopResultText(const Loop: TToolLoopResult): string;

{ Build the operator-facing "stopped at the tool-iteration limit" notice
  from a finished loop result, or '' when the loop did NOT hit the cap (so
  callers can append it unconditionally). MaxIter is the configured cap;
  HowToRaise is a surface-specific hint for lifting it (e.g.
  '--max-iter on `pasclaw serve`', or '' to omit that clause).

  Resumable says whether THIS caller carries conversation history forward:
    True  (interactive CLI, session-backed TUI, gateway clients that resend
          the message array) -> "reply continue to resume from here".
    False (one-shot CLI without --session, the line-based TUI that rebuilds
          the history from the current input each turn) -> there is nothing
          to resume into, so the notice tells the user to raise the cap and
          re-run instead of promising a continue that would start fresh. }
function FormatMaxIterNotice(const Loop: TToolLoopResult; MaxIter: Integer;
                            const HowToRaise: string; Resumable: Boolean): string;

type
  (* Late-bound hook so PasClaw.Tools.ToolLoop doesn't have to
     `uses` PasClaw.Agent.SubagentBg (which itself calls
     RunToolLoop -- a circular dep). The background-subagent unit
     assigns this in its initialization. Returns a formatted
     "[background subagent results]" block when one or more jobs
     bound to Key have finished since the last drain, '' otherwise.
     MaxChars bounds the total block size. *)
  TBackgroundDrainFn = function(const Key: string; MaxChars: Integer): string;

var
  GBackgroundDrainHook: TBackgroundDrainFn = nil;

implementation

uses
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Hashline,
  PasClaw.Tools.Types,
  PasClaw.Tools.OutputCache,
  PasClaw.Condense.JSON,
  PasClaw.Promptware,       { injection scan on tool results -- chokepoint 1 }
  PasClaw.Otel;             (* agent.turn / chat / execute_tool spans.
                               All helpers are no-ops when OTel is
                               disabled, so the wiring costs ~5 ns per
                               call in the default-off shape. *)

type
  { Per-call work unit. The same record is filled in by a worker thread
    (parallel) or by an inline call (serial), then read by the main
    loop to append the tool_result to history. Workers never touch the
    history array directly -- race-free by construction. }
  TToolCallDispatch = record
    Call:       TToolCall;
    ResultText: string;
    Err:        string;
    { Set True when a BeforeToolCall hook short-circuited the tool;
      ResultText holds the synthetic answer. Workers check this and
      skip dispatch -- the synthetic result is what gets appended to
      history. }
    Cancelled:  Boolean;
  end;
  PToolCallDispatch = ^TToolCallDispatch;

  { Worker thread that runs one tool call's PreflightToolCall +
    Registry.RunTool + hashline retry logic, writes the result back
    into a TToolCallDispatch slot, exits. FreeOnTerminate is False --
    the main thread WaitFor's then Free's each worker in array order. }
  TToolCallWorker = class(TThread)
  private
    FCfg:  TToolLoopConfig;
    FSlot: PToolCallDispatch;
  protected
    procedure Execute; override;
  public
    constructor Create(const ACfg: TToolLoopConfig; ASlot: PToolCallDispatch);
  end;

  TToolBatch      = array of Integer;        { indices into Resp.ToolCalls }
  TToolBatchArray = array of TToolBatch;

{ Provider error classes worth retrying on a fallback: network/TLS
  errors (StatusCode <= 0 -- provider couldn't talk to the upstream),
  request-timeout (408), rate-limit (429), and any 5xx. Anything
  else (4xx auth / invalid request) is a configuration bug the
  fallback wouldn't fix. }
function IsRetryableStatus(Status: Integer): Boolean;
begin
  Result := (Status <= 0) or (Status = 408) or (Status = 429) or
            ((Status >= 500) and (Status < 600));
end;

function IsPatchFormatError(const Err: string): Boolean;
var
  L: string;
begin
  L := LowerCase(Err);
  Result := (Pos('patch parse:', L) > 0) or
            (Pos('patch preflight:', L) > 0) or
            (Pos('unsupported inline payload token', L) > 0);
end;

function NormalizePatchForCompare(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if (C <> #13) and (C <> #10) and (C <> #9) and (C <> ' ') then
      Result[i] := C
    else
      Result[i] := #0;
  end;
  Result := StringReplace(Result, #0, '', [rfReplaceAll]);
end;

function CanonicalizeHashlinePatch(const Patch: string;
                                   out Canonical: string;
                                   out HasUnsupportedTokens: Boolean): Boolean;
var
  Sections: THLSectionArray;
  ParseErr: string;
  i, j: Integer;
  E: THLEdit;
  Sb: TStringBuilder;
begin
  Canonical := '';
  HasUnsupportedTokens := False;
  if not ParseHashlinePatch(Patch, Sections, ParseErr) then Exit(False);
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Sections) do
    begin
      if i > 0 then Sb.Append(#10);
      if Sections[i].HasFileHash then
        Sb.Append(FormatHashlineHeader(Sections[i].Path, Sections[i].FileHash))
      else
        Sb.Append(HL_FILE_PREFIX + Sections[i].Path);
      Sb.Append(#10);
      for j := 0 to High(Sections[i].Edits) do
      begin
        E := Sections[i].Edits[j];
        Sb.Append(IntToStr(E.Anchor.LineNum)).Append(HL_LINE_BODY_SEP).Append(#10);
        case E.PayloadKind of
          hpkReplace: Sb.Append(HL_PAYLOAD_REPLACE);
          hpkAbove:   Sb.Append(HL_PAYLOAD_ABOVE);
          hpkBelow:   Sb.Append(HL_PAYLOAD_BELOW);
        else
          HasUnsupportedTokens := True;
          Sb.Append(HL_PAYLOAD_REPLACE);
        end;
        Sb.Append(E.Text).Append(#10);
      end;
    end;
    Canonical := Sb.ToString;
  finally
    Sb.Free;
  end;
  Result := True;
end;

function PreflightToolCall(const Name, ArgsJSON: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Patch, VErr: string;
begin
  Result := True;
  Err := '';
  if Name <> 'fs_edit_hashline' then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then
  begin
    Err := 'invalid JSON arguments for fs_edit_hashline';
    Exit(False);
  end;
  try
    Patch := Obj.GetStr('patch', '');
  finally
    Obj.Free;
  end;
  if Patch = '' then Exit;
  if not ValidateHashlinePatchGrammar(Patch, VErr) then
  begin
    Err := 'patch preflight: ' + VErr + ' (remediation: regenerate patch with ¶path#hash header, anchor line like "N:" or "N-M:", then payload lines prefixed by |/↑/↓ only)';
    Exit(False);
  end;
end;

function MakeAssistantWithToolCalls(const Content: string;
                                    const Calls: array of TToolCall): TMessage;
var
  i: Integer;
begin
  Result.Role       := mrAssistant;
  Result.Content    := Content;
  Result.Name       := '';
  Result.ToolCallId := '';
  SetLength(Result.ToolCalls, Length(Calls));
  for i := 0 to High(Calls) do Result.ToolCalls[i] := Calls[i];
end;

function MakeToolResult(const ToolCallId, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := ToolCallId;
end;

{ Run one tool call: PreflightToolCall → Registry.RunTool → fs_edit_hashline
  retry on format errors. Writes ResultText / Err into the dispatch slot.
  Pure with respect to shared state (uses per-call HTTP clients, reads
  the registry's name table read-only, calls thread-safe LogWarn), so it
  is safe to call from a worker thread alongside other DispatchOneToolCall
  invocations against different ToolCall inputs. Callers fire
  OnToolCall / OnToolResult on the main thread before / after; we
  deliberately don't invoke them in here to keep the worker stateless
  with respect to the embedder's event-handler thread affinity. }
procedure DispatchOneToolCall(const Cfg: TToolLoopConfig;
                               var D: TToolCallDispatch);
var
  RetryArgs, Patch, CanonicalPatch, N1, N2: string;
  ArgsObj: TJsonObject;
  HasUnsup: Boolean;
  PlanTool: TTool;
begin
  { Publish this run's config to the dispatching thread (loop thread for
    serial/mutating tools, worker thread for parallel read-only ones) so any
    tool that calls LoadEffectiveConfig (web_search / send_message / memory /
    kb) honours it. nil => LoadEffectiveConfig falls back to disk LoadConfig.
    Cleared in the finally so it never lingers past this call. }
  SetActiveConfig(Cfg.ActiveConfig);
  try
  D.Err        := '';
  D.ResultText := '';
  RetryArgs    := D.Call.Func.Arguments;
  (* Plan mode dispatch gate (PR #290). Before any preflight or registry
     lookup, refuse mutating tools when Cfg.Mode = pmPlan. The refusal
     becomes the tool result the model sees, so the model can plan
     around the missing capability or report it to the operator. We
     look up the tool to read its Category; an unknown name falls
     through to the existing "no such tool" handling so plan mode
     doesn't change the unknown-tool error message. *)
  if (Cfg.Mode = pmPlan) and (Cfg.Registry <> nil)
     and Cfg.Registry.Find(D.Call.Func.Name, PlanTool)
     and (PlanTool.Category = tcMutating) then
  begin
    { Plan-mode refusal lands in ResultText (Err left empty) so the
      descriptive guidance reaches the model verbatim. If we set Err
      the loop would wrap the message as "ERROR: <Err>" and the
      helpful "switch to build mode" hint would never reach the
      model. The dispatch never actually ran the tool, so this is
      not an error condition from the loop's perspective. }
    D.ResultText := PlanModeRefusal(D.Call.Func.Name);
    Exit;
  end;
  if not PreflightToolCall(D.Call.Func.Name, RetryArgs, D.Err) then
    D.ResultText := ''
  else if Cfg.Registry <> nil then
    D.ResultText := Cfg.Registry.RunTool(D.Call.Func.Name, RetryArgs, D.Err)
  else
    D.Err := 'no tool registry';

  if (D.Call.Func.Name = 'fs_edit_hashline') and IsPatchFormatError(D.Err) then
  begin
    LogWarn('tool-retry attempt=1 strategy=raw_hashline normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
      [Length(NormalizePatchForCompare(RetryArgs)), BoolToStr(False, True)]);
    ArgsObj := TJsonObject.Parse(RetryArgs);
    Patch := '';
    if ArgsObj <> nil then
    begin
      try
        Patch := ArgsObj.GetStr('patch', '');
      finally
        ArgsObj.Free;
      end;
    end;
    if (Patch <> '') and CanonicalizeHashlinePatch(Patch, CanonicalPatch, HasUnsup) then
    begin
      ArgsObj := TJsonObject.Create;
      try
        ArgsObj.PutStr('patch', CanonicalPatch);
        RetryArgs := ArgsObj.ToJSON;
      finally
        ArgsObj.Free;
      end;
      N1 := NormalizePatchForCompare(Patch);
      N2 := NormalizePatchForCompare(CanonicalPatch);
      LogWarn('tool-retry attempt=2 strategy=strict_hashline_formatter normalized_patch_len=%d has_unsupported_tokens=%s class=format_error',
        [Length(N2), BoolToStr(HasUnsup, True)]);
      D.Err := '';
      if not PreflightToolCall(D.Call.Func.Name, RetryArgs, D.Err) then
        D.ResultText := ''
      else if Cfg.Registry <> nil then
        D.ResultText := Cfg.Registry.RunTool(D.Call.Func.Name, RetryArgs, D.Err)
      else
        D.Err := 'no tool registry';
      if IsPatchFormatError(D.Err) and (N1 = N2) then
        D.Err := 'format_error: deterministic fallback exhausted; two consecutive retries had equivalent normalized patch content. ' +
                 'Regenerate patch intent or use safer apply-patch/unified-diff edit path.';
    end
    else
      D.Err := 'format_error: unable to canonicalize patch for deterministic retry; regenerate patch intent or use safer apply-patch/unified-diff edit path. original=' + D.Err;
  end;
  finally
    SetActiveConfig(nil);
  end;
end;

constructor TToolCallWorker.Create(const ACfg: TToolLoopConfig;
                                    ASlot: PToolCallDispatch);
begin
  inherited Create(True);  { suspended; main thread calls Start after all workers in the batch are constructed }
  FreeOnTerminate := False;
  FCfg  := ACfg;
  FSlot := ASlot;
end;

procedure TToolCallWorker.Execute;
begin
  { Skip dispatch entirely when a BeforeToolCall hook already
    short-circuited this call. The slot's ResultText holds the
    hook's synthetic reply; nothing else for the worker to do. }
  if FSlot^.Cancelled then Exit;
  try
    DispatchOneToolCall(FCfg, FSlot^);
  except
    on E: Exception do
    begin
      FSlot^.ResultText := '';
      FSlot^.Err        := 'worker exception: ' + E.ClassName + ': ' + E.Message;
    end;
  end;
end;

{ Partition a round's tool calls into batches that are safe to run in
  parallel within each batch. Read-only tools (Category = tcReadOnly)
  coalesce into one batch; each mutating tool is its own batch of one.
  Tools not found in the registry are treated as tcMutating (safe
  default -- applies to skill / MCP tools and to any handler that
  forgot to set the Category field). Order is preserved across
  batches, so the agent loop appends tool_results in the same order
  the model emitted tool_use blocks.

  Calls is declared as an open array rather than `TToolCallArray`
  because the source is `TLLMResponse.ToolCalls`, which the providers
  record as an inline `array of TToolCall` -- Delphi 12 dcc64 enforces
  strict named-type matching on dynamic-array parameters and rejects
  the bare-array → TToolCallArray pass-through with E2010. FPC happens
  to accept it either way, but the open-array form compiles cleanly
  under both. }

{ Collect every mrSystem entry's content from Hist (in array order),
  return them concatenated with blank-line separators. Read-only --
  does NOT modify Hist.

  Used by the steering fold so an embedder's in-history system
  policy is visible through LiveOptions.SystemPrompt (which the
  provider builders DO ship) when steering makes that slot non-empty.
  An earlier draft drained Hist destructively, but that made the
  policy unrecoverable if a BeforeTurn hook later reset
  SystemPrompt to '' for ephemeral-steering semantics (Codex P2 on
  PR #114). Keeping mrSystem in Hist means: when SystemPrompt is
  set, the provider drops in-history mrSystem (using the consolidated
  SystemPrompt); when SystemPrompt is empty, the provider includes
  the in-history mrSystem (so the policy still ships). Either way
  the policy reaches the model.

  Caller responsibility: read CopyHistorySystem ONLY when
  LiveOptions.SystemPrompt is empty. Once SystemPrompt has the
  policy embedded (after the first fold), subsequent folds should
  append steering without re-reading Hist to avoid duplicating the
  policy text. }
function CopyHistorySystem(const Hist: TMessageArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Hist) do
    if Hist[i].Role = mrSystem then
    begin
      if Result <> '' then Result := Result + sLineBreak + sLineBreak;
      Result := Result + Hist[i].Content;
    end;
end;

function PartitionToolBatches(const Calls: array of TToolCall;
                              Reg: TToolRegistry): TToolBatchArray;
var
  i: Integer;
  IsRO: Boolean;
  T: TTool;
  Cur: TToolBatch;

  procedure FlushCur;
  begin
    if Length(Cur) > 0 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Cur;
      SetLength(Cur, 0);
    end;
  end;

begin
  SetLength(Result, 0);
  SetLength(Cur, 0);
  for i := 0 to High(Calls) do
  begin
    IsRO := False;
    if (Reg <> nil) and Reg.Find(Calls[i].Func.Name, T) and (T.Category = tcReadOnly) then
      IsRO := True;
    if IsRO then
    begin
      SetLength(Cur, Length(Cur) + 1);
      Cur[High(Cur)] := i;
    end
    else
    begin
      { Flush the in-flight read-only batch (if any), then emit a
        batch-of-one for the mutating call. }
      FlushCur;
      SetLength(Cur, 1);
      Cur[0] := i;
      FlushCur;
    end;
  end;
  FlushCur;
end;

function CollectToolNames(const Calls: array of TToolCall): TArray<string>;
{ Distinct tool names in first-seen order. Small N (a single model turn's
  tool calls), so a linear dedupe is fine. }
var
  i, j: Integer;
  Nm: string;
  Seen: Boolean;
begin
  SetLength(Result, 0);
  for i := 0 to High(Calls) do
  begin
    Nm := Calls[i].Func.Name;
    if Nm = '' then Continue;
    Seen := False;
    for j := 0 to High(Result) do
      if Result[j] = Nm then begin Seen := True; Break; end;
    if Seen then Continue;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Nm;
  end;
end;

function LoopResultText(const Loop: TToolLoopResult): string;
var
  i: Integer;
begin
  Result := Loop.Content;
  if Trim(Result) <> '' then Exit;
  { Loop ended without a closing text turn (last round was a tool call, or it
    hit MaxIterations). Recover the last assistant text from history. }
  for i := High(Loop.FinalMessages) downto Low(Loop.FinalMessages) do
    if (Loop.FinalMessages[i].Role = mrAssistant)
       and (Trim(Loop.FinalMessages[i].Content) <> '') then
      Exit(Loop.FinalMessages[i].Content);
  { Genuinely no text at all -- explain rather than return ''. }
  if Loop.HitMaxIterations then
    Result := Format('(no final answer: hit the %d-iteration limit after %d tool call(s) -- raise max_iterations or narrow the task)',
                     [Loop.Iterations, Integer(Loop.ToolCallsDispatched)])
  else
    Result := Format('(no final answer: ended after %d iteration(s) and %d tool call(s) without producing text)',
                     [Loop.Iterations, Integer(Loop.ToolCallsDispatched)]);
end;

function FormatMaxIterNotice(const Loop: TToolLoopResult; MaxIter: Integer;
  const HowToRaise: string; Resumable: Boolean): string;
var
  Names: string;
  i: Integer;
begin
  Result := '';
  if not Loop.HitMaxIterations then Exit;
  Names := '';
  for i := 0 to High(Loop.PendingToolNames) do
  begin
    if Names <> '' then Names := Names + ', ';
    Names := Names + Loop.PendingToolNames[i];
  end;
  Result := Format(
    '[stopped: hit the tool-call limit of %d iteration(s) while still ' +
    'working -- this task is probably unfinished]', [MaxIter]);
  if Names <> '' then
    Result := Result + sLineBreak +
      'It was mid-way through: ' + Names + '.';
  if Resumable then
  begin
    { History carries over -- a follow-up turn resumes from here. }
    Result := Result + sLineBreak +
      'Reply "continue" to resume from here (the conversation carries over)';
    if HowToRaise <> '' then
      Result := Result + ', or raise the limit (' + HowToRaise + ')';
    Result := Result + '.';
  end
  else
  begin
    { Stateless caller: there is nothing to "continue" into -- a fresh
      request would start over without the tool history -- so point the
      user at raising the cap and re-running. }
    Result := Result + sLineBreak + 'This turn does not carry over -- ';
    if HowToRaise <> '' then
      Result := Result + 'raise the limit (' + HowToRaise + ') and re-run to finish.'
    else
      Result := Result + 'raise the iteration limit and re-run to finish.';
  end;
end;

function RunToolLoop(const Cfg: TToolLoopConfig;
                     var Messages: array of TMessage;
                     out Loop: TToolLoopResult): Boolean;
const
  { Per-iteration steering cap. Picoclaw and nanobot both bound this
    around 4-5 to keep a runaway pusher from growing Hist unbounded.
    Drained messages beyond the cap are logged + dropped. }
  MaxSteeringPerTurn = 4;
var
  Iter, i, bi, j, fbi, sti: Integer;
  Tools: TToolDefinitionArray;
  FallbackModel: string;
  Resp: TLLMResponse;
  Hist: TMessageArray;
  LiveOptions: TChatOptions;
  Dispatches: array of TToolCallDispatch;
  Batches: TToolBatchArray;
  Batch: TToolBatch;
  Workers: array of TToolCallWorker;
  Steering, BatchSteering, HistSystem, LastProviderErrText, BgBlock, PersistentSP: string;
  Steers: TSteeringMessageArray;
  InContext: string;       { tool output cap (#PR new): in-context
                             body that lands in Hist after the
                             optional StashAndMaybeTruncate pass }
  OrigBody:  string;       { snapshot of the raw tool result before
                             reversible condensation, so the original
                             can be stashed for tool_output_get }
  OrigLen:   Integer;
  Truncated: Boolean;
  TurnSpan, ChatSpan, ToolSpan: TOtelSpan;
begin
  Loop.Content    := '';
  Loop.Iterations := 0;
  Loop.TotalUsage := Default(TUsageInfo);
  Loop.Truncations         := 0;
  Loop.TruncatedBytesSaved := 0;
  Loop.ToolCallsDispatched := 0;

  if Cfg.Provider = nil then Exit(False);

  { openclaw.agent.turn span (tier-1 instrumentation point). Wraps
    the whole tool loop -- everything below up to the final
    Result := True / Result := False flows through this span.
    Pascal's Exit cleanly traverses try/finally, so every
    Exit(True) / Exit(False) deeper in the loop still finishes
    the span. TurnSpan is nil when OTel is off; all Set/Finish
    helpers tolerate nil. }
  TurnSpan := StartSpan('openclaw.agent.turn', oskInternal, '');
  try
    SetAttrStr(TurnSpan, 'gen_ai.request.model',  Cfg.Model);
    SetAttrStr(TurnSpan, 'gen_ai.operation.name', 'chat');
    SetAttrInt(TurnSpan, 'openclaw.max_iterations', Cfg.MaxIterations);
    if Cfg.Provider <> nil then
      SetAttrStr(TurnSpan, 'gen_ai.provider.name', Cfg.Provider.GetName);

  { Annotate the log stream once per turn with the canonical sender
    id (picoclaw parity -- pkg/identity). Hooks and post-hoc audit
    tooling can grep for `identity=` to attribute actions. Empty
    canonical id means CLI / cron / embedder use without a
    populated TIdentity -- we skip the log line to keep noise low. }
  if CanonicalOf(Cfg.Identity) <> '' then
    LogDebug('toolloop start identity=%s', [FormatIdentity(Cfg.Identity)]);

  { Copy input messages to a growable history. }
  SetLength(Hist, Length(Messages));
  for i := 0 to High(Messages) do Hist[i] := Messages[i];

  { Local mutable copy of Cfg.Options so compaction can fold the
    summary into LiveOptions.SystemPrompt without touching the
    caller's const Cfg. The provider call uses LiveOptions, not
    Cfg.Options, from here on. }
  LiveOptions := Cfg.Options;

  if Cfg.Registry <> nil then
    Tools := Cfg.Registry.ToProviderDefs
  else
    SetLength(Tools, 0);

  Iter := 0;
  { When progressive disclosure is on (PasClaw.MCP.Disclosure), the
    model can call tool_search mid-loop to reveal deferred tools.
    Reveal mutates the registry's FRevealed set; the next
    ToProviderDefs call will then include the newly-revealed tools.
    We re-snapshot Tools inside the iter loop (just before each
    provider call) so a reveal at iter N becomes visible at iter
    N+1. Cheap -- ToProviderDefs is an array copy under one CS. }
  { Stamp the per-turn identity onto every registered hook so
    override implementations can read `Self.Identity` from any of
    the BeforeTurn / BeforeToolCall / AfterToolResult / OnError
    virtuals -- the alternative (threading TIdentity through every
    hook signature) would break every existing TPasClawHook
    subclass. Codex P2 on PR #119. Identity is per-loop, not
    per-iteration, so set once before the loop. }
  for i := 0 to High(Cfg.Hooks) do
    if Cfg.Hooks[i] <> nil then
      Cfg.Hooks[i].Identity := Cfg.Identity;
  while Iter < Cfg.MaxIterations do
  begin
    Inc(Iter);
    LogDebug('toolloop iteration %d / %d', [Iter, Cfg.MaxIterations]);

    { Pre-call compaction. NeedsCompact is a cheap token estimate;
      only when it trips do we pay for a summariser round.
      CompactMessages may rewrite Hist AND modify
      LiveOptions.SystemPrompt -- the summary folds into the system
      prompt because both OpenAI and Anthropic builders silently
      drop in-message mrSystem entries when SystemPrompt is set
      (Codex PR #87 P1). Returns verbatim on summariser failure,
      so a broken summary can never wipe live context.

      Moved BEFORE the ephemeral drains (steering / bg) so
      compaction's persistent rebuild of SystemPrompt happens on a
      clean baseline. The ephemeral folds below get snapshot-and-
      restored around the provider call so they don't pollute
      Loop.FinalSystemPrompt (which Cmd.Agent persists across
      turns). Codex P2 on PR #211. }
    if Cfg.CompactEnabled and
       NeedsCompact(Hist, Cfg.CompactOpts.ThresholdTokens) then
      Hist := CompactMessages(Cfg.Provider, Cfg.Model, Hist,
                               LiveOptions, Cfg.CompactOpts);

    { Snapshot the persistent SystemPrompt so we can restore it
      after Provider.Chat -- everything compaction did above is
      meant to survive into Loop.FinalSystemPrompt; everything the
      ephemeral drains do below is one-turn-only. }
    PersistentSP := LiveOptions.SystemPrompt;

    { Mid-loop steering: drain any user follow-ups that arrived
      while we were busy (CLI `pasclaw steer <id> "..."`, channels
      with concurrent polling) and fold each into LiveOptions.
      SystemPrompt as a "[user steering received mid-turn]" addendum
      so the next provider call's `system` field carries them.

      We CANNOT append mrSystem to Hist here -- the OpenAI builder
      (PasClaw.Providers.OpenAI.pas:148-151) and Anthropic
      (PasClaw.Providers.Anthropic.pas:170-172) and Gemini all skip
      in-history mrSystem entries when Options.SystemPrompt is
      already populated (which it is on the CLI path,
      BuildLoopConfig always sets it). The drain would then
      permanently consume the queue without the model ever seeing
      the correction. Folding into SystemPrompt is the same channel
      compaction uses for the same reason. (Codex P1 on PR #120.)

      Cap at MaxSteeringPerTurn so a runaway pusher can't grow the
      system prompt unbounded; the cap matches nanobot's
      _MAX_INJECTIONS_PER_TURN sanity bound. Cache breakpoint
      invalidates for the steering turn -- acceptable cost. }
    { Background-subagent drain. Same channel as steering -- fold
      into LiveOptions.SystemPrompt because providers skip in-
      history mrSystem when SystemPrompt is set. Folded BEFORE
      steering so a user steering message that mentions the result
      arrives logically after the result the model sees. Late-bound
      hook to break the circular dep; assigned by
      PasClaw.Agent.SubagentBg.initialization.

      Drained results are EPHEMERAL: they go to this provider call
      only, then LiveOptions.SystemPrompt is restored to
      PersistentSP just before the next iteration. The
      drain-once contract inside the coordinator (FCollected) is
      no longer the only line of defence -- Codex P2 on PR #211. }
    if (Cfg.BackgroundDrainKey <> '') and Assigned(GBackgroundDrainHook) then
    begin
      BgBlock := GBackgroundDrainHook(Cfg.BackgroundDrainKey, 8192);
      if BgBlock <> '' then
      begin
        if LiveOptions.SystemPrompt <> '' then
          LiveOptions.SystemPrompt := LiveOptions.SystemPrompt + sLineBreak + sLineBreak;
        LiveOptions.SystemPrompt := LiveOptions.SystemPrompt + BgBlock;
      end;
    end;

    if Cfg.SteeringKey <> '' then
    begin
      Steers := DrainSteering(Cfg.SteeringKey, MaxSteeringPerTurn);
      if Length(Steers) > 0 then
      begin
        if LiveOptions.SystemPrompt <> '' then
          LiveOptions.SystemPrompt := LiveOptions.SystemPrompt + sLineBreak + sLineBreak;
        LiveOptions.SystemPrompt := LiveOptions.SystemPrompt +
          '[user steering received mid-turn]';
        for sti := 0 to High(Steers) do
        begin
          LogDebug('steering[%s] injecting: %s',
                   [Cfg.SteeringKey, Copy(Steers[sti].Text, 1, 80)]);
          LiveOptions.SystemPrompt := LiveOptions.SystemPrompt +
            sLineBreak + '- ' + Steers[sti].Text;
        end;
      end;
    end;

    { Fire BeforeTurn hooks. Embedder can mutate Hist (e.g. inject
      a system note based on out-of-band state) or set
      ContinueTurn := False to abort the loop gracefully with
      whatever content was last accumulated. }
    if (Length(Cfg.Hooks) > 0) and (not HooksBeforeTurn(Cfg.Hooks, Hist)) then
    begin
      Loop.Content    := Resp.Content;   { last response, possibly empty }
      Loop.Iterations := Iter;
      Loop.FinalMessages    := Hist;
      Loop.FinalSystemPrompt := LiveOptions.SystemPrompt;
      Exit(True);
    end;

    { Wrapping Cfg.Provider.Chat in try/except: most provider
      implementations classify network / TLS / parse failures
      themselves and return StatusCode := -1, but an unexpected
      exception (out-of-memory in CollapseSSE, malformed JSON the
      builder doesn't catch, Indy raising EIdSocketError on a
      torn-down TLS handshake) used to propagate out and bypass
      the OnError hook entirely. Now any raised exception turns
      into a synthetic -1 response -- the fallback walk continues
      and the post-walk HooksOnError check fires with the
      diagnostic text out-of-band. (Codex P2 on PR #113.)

      Diagnostic text goes into LastProviderErrText (local),
      NOT into Resp.Content. If we stashed exception text in
      Resp.Content, the outer "no tool calls, exit cleanly" path
      would surface it as Loop.Content -- i.e. as the assistant's
      reply to the user, leaking internal parser / socket / TLS
      details through to the caller. Hook embedders that want the
      diagnostic still get it via OnError. (Codex P2 on PR #114.) }
    LastProviderErrText := '';
    { Refresh the per-request tools array. tool_search reveals MCP
      tools by mutating the registry; the next provider call needs
      the updated def list so a newly-revealed schema is callable
      without waiting a full user turn. ToProviderDefs holds the
      registry CS for the duration of one array copy, which is
      microseconds even for fat MCP catalogs. }
    if Cfg.Registry <> nil then
      Tools := Cfg.Registry.ToProviderDefs;

    { gen_ai chat span (tier-2 instrumentation). Wraps the actual
      provider request -- naming follows openclaw / Langfuse so
      backend dashboards recognise the span shape. Token counts
      are stamped on success; status flips to error on a non-2xx
      StatusCode or an exception. }
    ChatSpan := StartSpan('chat ' + Cfg.Model, oskClient, '');
    try
      SetAttrStr(ChatSpan, 'gen_ai.operation.name', 'chat');
      SetAttrStr(ChatSpan, 'gen_ai.request.model',  Cfg.Model);
      SetAttrStr(ChatSpan, 'gen_ai.provider.name',  Cfg.Provider.GetName);
      SetAttrInt(ChatSpan, 'openclaw.turn.iteration', Iter);
      try
        { Empty-turn auto-retry. When StreamReliability.EmptyRetryAttempts
          is 0 (default record zero, the legacy shape) ChatWithEmptyRetry
          is a one-shot call -- identical to the pre-PR behaviour. }
        Resp := ChatWithEmptyRetry(Cfg.Provider, Hist, Tools, Cfg.Model,
                                    LiveOptions, Cfg.StreamReliability);
      except
        on E: Exception do
        begin
          LogWarn('provider Chat raised: %s: %s', [E.ClassName, E.Message]);
          Resp := Default(TLLMResponse);
          Resp.StatusCode := -1;
          LastProviderErrText := Cfg.Provider.GetName + ': '
                                 + E.ClassName + ': ' + E.Message;
          SetStatus(ChatSpan, oscError, E.ClassName + ': ' + E.Message);
        end;
      end;
    finally
      SetAttrInt(ChatSpan, 'http.response.status_code',  Resp.StatusCode);
      SetAttrInt(ChatSpan, 'gen_ai.usage.input_tokens',  Resp.Usage.InputTokens);
      SetAttrInt(ChatSpan, 'gen_ai.usage.output_tokens', Resp.Usage.OutputTokens);
      if Resp.FinishReason <> '' then
        SetAttrStr(ChatSpan, 'gen_ai.response.finish_reason', Resp.FinishReason);
      if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
        SetStatus(ChatSpan, oscOk, '')
      else if ChatSpan <> nil then
        SetStatus(ChatSpan, oscError,
                  'provider status ' + IntToStr(Resp.StatusCode));
      FinishSpan(ChatSpan);
    end;
    { Provider fallback. Retryable conditions: HTTP 408 / 429 / 5xx,
      and StatusCode <= 0 (network / TLS / pre-HTTP failure that the
      provider couldn't classify). Walk Cfg.Fallbacks in order until
      one returns a 2xx.

      Model selection per fallback: ask the fallback's own
      GetDefaultModel -- anthropic-only model names ("claude-opus-4-7")
      passed verbatim to an OpenAI fallback would fail at the remote
      API and trigger the next fallback even when the chain was
      otherwise healthy. A non-empty Cfg.FallbackModels[fbi] overrides
      this entirely -- that is how the auto-router preserves the caller's
      explicitly requested model when it prepends the original primary as
      Fallbacks[0]. Otherwise we only fall back to Cfg.Model when the
      fallback explicitly returns '' for its GetDefaultModel. }
    if IsRetryableStatus(Resp.StatusCode) and (Length(Cfg.Fallbacks) > 0) then
    begin
      LogWarn('provider primary returned status=%d, walking %d fallback(s)',
              [Resp.StatusCode, Length(Cfg.Fallbacks)]);
      for fbi := 0 to High(Cfg.Fallbacks) do
      begin
        if Cfg.Fallbacks[fbi] = nil then Continue;
        if (fbi <= High(Cfg.FallbackModels)) and (Cfg.FallbackModels[fbi] <> '') then
          FallbackModel := Cfg.FallbackModels[fbi]
        else
        begin
          FallbackModel := Cfg.Fallbacks[fbi].GetDefaultModel;
          if FallbackModel = '' then FallbackModel := Cfg.Model;
        end;
        LogDebug('fallback %d: trying %s with model=%s',
                 [fbi, Cfg.Fallbacks[fbi].GetName, FallbackModel]);
        try
          Resp := Cfg.Fallbacks[fbi].Chat(Hist, Tools, FallbackModel, LiveOptions);
          { Successful call clears the diagnostic -- only the LAST failed
            attempt's text should surface to hooks. }
          LastProviderErrText := '';
        except
          on E: Exception do
          begin
            LogWarn('fallback %s Chat raised: %s: %s',
                    [Cfg.Fallbacks[fbi].GetName, E.ClassName, E.Message]);
            Resp := Default(TLLMResponse);
            Resp.StatusCode := -1;
            LastProviderErrText := Cfg.Fallbacks[fbi].GetName + ': '
                                   + E.ClassName + ': ' + E.Message;
          end;
        end;
        if not IsRetryableStatus(Resp.StatusCode) then
        begin
          LogWarn('fallback hit: %s status=%d',
                  [Cfg.Fallbacks[fbi].GetName, Resp.StatusCode]);
          Break;
        end;
      end;
    end;
    { Restore SystemPrompt to its pre-drain state so the next
      iteration -- and Loop.FinalSystemPrompt, which Cmd.Agent
      persists as Session.Meta.SystemPromptOverride -- carry only
      the compaction-stable baseline, not the ephemeral bg drain or
      steering folds. Codex P2 on PR #211: without this, a
      [background subagent results] block delivered once on turn N
      would get baked into the persisted SystemPrompt and replayed
      on turns N+1, N+2, etc., causing unbounded prompt growth and
      stale result repetition. }
    LiveOptions.SystemPrompt := PersistentSP;

    Loop.LastResp := Resp;
    { Roll up usage across every provider call in this loop (incl.
      successful fallbacks). Per-iteration cache writes and reads
      from intermediate tool-using turns would otherwise be lost
      when /status / FormatTokenLine read only LastResp. Codex P2
      on PR #118. }
    Inc(Loop.TotalUsage.InputTokens,        Resp.Usage.InputTokens);
    Inc(Loop.TotalUsage.OutputTokens,       Resp.Usage.OutputTokens);
    Inc(Loop.TotalUsage.CacheReadTokens,    Resp.Usage.CacheReadTokens);
    Inc(Loop.TotalUsage.CacheCreatedTokens, Resp.Usage.CacheCreatedTokens);

    { Provider failure surfaces to hooks. After the fallback walk
      above, fire OnError(hsProviderCall) whenever the final status
      isn't a 2xx -- including non-positive codes (StatusCode <= 0)
      which the HTTP helper uses to flag pre-HTTP failures: DNS
      lookup miss, TLS handshake refusal, socket reset, no
      OpenSSL IO handler. Earlier this guard required StatusCode > 0
      and silently skipped exactly those cases -- the ones an audit
      / alerting hook most wants to see. (Codex P2 on PR #111.) }
    if (Length(Cfg.Hooks) > 0) and
       ((Resp.StatusCode < 200) or (Resp.StatusCode >= 300)) then
    begin
      { Diagnostic preference order:
          1. LastProviderErrText  -- exception text we caught above.
                                    Highest priority because we know
                                    it's our own structured failure
                                    and won't leak into Loop.Content.
          2. Resp.Content         -- typically the provider's error
                                    JSON body on a non-2xx HTTP
                                    response. Useful telemetry; we
                                    don't filter it because the
                                    provider returned it deliberately.
          3. Just status=%d       -- nothing else available. }
      if LastProviderErrText <> '' then
        HooksOnError(Cfg.Hooks, hsProviderCall,
                      Format('provider returned status=%d: %s',
                             [Resp.StatusCode, LastProviderErrText]))
      else if Resp.Content <> '' then
        HooksOnError(Cfg.Hooks, hsProviderCall,
                      Format('provider returned status=%d: %s',
                             [Resp.StatusCode, Resp.Content]))
      else
        HooksOnError(Cfg.Hooks, hsProviderCall,
                      Format('provider returned status=%d', [Resp.StatusCode]));
    end;

    { Stream the text part to the caller now so they can show progress. }
    if Assigned(Cfg.OnText) and (Resp.Content <> '') then
      Cfg.OnText(Resp.Content);

    if Length(Resp.ToolCalls) = 0 then
    begin
      Loop.Content    := Resp.Content;
      Loop.Iterations := Iter;
      Loop.FinalMessages    := Hist;
      Loop.FinalSystemPrompt := LiveOptions.SystemPrompt;
      Exit(True);
    end;

    { Append the assistant turn (text + tool calls) and dispatch each call. }
    SetLength(Hist, Length(Hist) + 1);
    Hist[High(Hist)] := MakeAssistantWithToolCalls(Resp.Content, Resp.ToolCalls);

    { Allocate one dispatch slot per tool call upfront so workers can hold
      a pointer to a slot without worrying about array reallocation. }
    SetLength(Dispatches, Length(Resp.ToolCalls));
    Inc(Loop.ToolCallsDispatched, Length(Resp.ToolCalls));
    for i := 0 to High(Resp.ToolCalls) do
    begin
      Dispatches[i].Call       := Resp.ToolCalls[i];
      Dispatches[i].ResultText := '';
      Dispatches[i].Err        := '';
      Dispatches[i].Cancelled  := False;
    end;

    { Partition into batches: read-only calls fan out concurrently
      within a batch when Cfg.Parallel is on; mutating calls each
      get a batch of one and stay serial. Order across batches is
      preserved, so tool_results land in Hist in the same order the
      model emitted them. }
    Batches := PartitionToolBatches(Resp.ToolCalls, Cfg.Registry);

    for bi := 0 to High(Batches) do
    begin
      Batch := Batches[bi];

      { Phase 1: fire OnToolCall + BeforeToolCall hooks for every
        call in the batch on the main thread, in array order, before
        any worker starts. Embedders rely on OnToolCall firing
        before its matching OnToolResult and on the announcements
        appearing in the same order the model produced the tool_use
        blocks. A BeforeToolCall hook that sets Cancel := True marks
        the slot Cancelled -- workers + serial path both skip
        dispatch, and the synthetic result becomes the tool_result. }
      for j := 0 to High(Batch) do
      begin
        if Assigned(Cfg.OnToolCall) then
          Cfg.OnToolCall(Dispatches[Batch[j]].Call.Func.Name,
                          Dispatches[Batch[j]].Call.Func.Arguments);
        if Length(Cfg.Hooks) > 0 then
          HooksBeforeToolCall(Cfg.Hooks, Dispatches[Batch[j]].Call,
                               Dispatches[Batch[j]].Cancelled,
                               Dispatches[Batch[j]].ResultText);
      end;

      if Cfg.Parallel and (Length(Batch) > 1) then
      begin
        { Parallel batch: spawn one TThread per call, suspended; Start
          all in array order; WaitFor all in array order; Free each
          worker after WaitFor. Cancelled slots short-circuit inside
          the worker's Execute -- see TToolCallWorker.Execute. }
        SetLength(Workers, Length(Batch));
        for j := 0 to High(Batch) do
          Workers[j] := TToolCallWorker.Create(Cfg, @Dispatches[Batch[j]]);
        for j := 0 to High(Workers) do
          Workers[j].Start;
        for j := 0 to High(Workers) do
        begin
          Workers[j].WaitFor;
          Workers[j].Free;
        end;
        SetLength(Workers, 0);
      end
      else
      begin
        { Serial batch (or Parallel disabled): just run inline on the
          main thread. Same DispatchOneToolCall the workers use, so
          fs_edit_hashline retry semantics are identical. Skip
          cancelled slots -- synthetic result already in ResultText.

          execute_tool span (tier-3 instrumentation). Parent is the
          enclosing agent.turn span via the threadvar stack. Tool
          spans only emit on the serial path -- parallel-worker
          dispatch doesn't share the parent's threadvar context yet;
          a follow-up PR threads the W3C traceparent through workers. }
        for j := 0 to High(Batch) do
          if not Dispatches[Batch[j]].Cancelled then
          begin
            ToolSpan := StartSpan('execute_tool ' +
                                  Dispatches[Batch[j]].Call.Func.Name,
                                  oskInternal, '');
            try
              SetAttrStr(ToolSpan, 'openclaw.tool.name',
                         Dispatches[Batch[j]].Call.Func.Name);
              SetAttrStr(ToolSpan, 'openclaw.tool.call_id',
                         Dispatches[Batch[j]].Call.Id);
              DispatchOneToolCall(Cfg, Dispatches[Batch[j]]);
              if Dispatches[Batch[j]].Err <> '' then
                SetStatus(ToolSpan, oscError, Dispatches[Batch[j]].Err)
              else
                SetStatus(ToolSpan, oscOk, '');
              SetAttrInt(ToolSpan, 'openclaw.tool.result_bytes',
                         Length(Dispatches[Batch[j]].ResultText));
            finally
              FinishSpan(ToolSpan);
            end;
          end;
      end;

      { Phase 2: fire AfterToolResult hooks + OnToolResult event +
        append tool_result messages on the main thread, in array
        order, AFTER the whole batch has joined. AfterToolResult
        hooks can rewrite ResultText/ErrMsg AND contribute steering
        notes that get concatenated and appended as a system
        message after the tool_result batch lands. }
      BatchSteering := '';
      for j := 0 to High(Batch) do
      begin
        if Length(Cfg.Hooks) > 0 then
        begin
          Steering := HooksAfterToolResult(Cfg.Hooks,
                                            Dispatches[Batch[j]].Call,
                                            Dispatches[Batch[j]].ResultText,
                                            Dispatches[Batch[j]].Err);
          if Steering <> '' then
          begin
            if BatchSteering <> '' then BatchSteering := BatchSteering + sLineBreak + sLineBreak;
            BatchSteering := BatchSteering + Steering;
          end;
        end;
        if Assigned(Cfg.OnToolResult) then
          Cfg.OnToolResult(Dispatches[Batch[j]].Call.Func.Name,
                           Dispatches[Batch[j]].ResultText,
                           Dispatches[Batch[j]].Err);
        { Tool failure surfaces to hooks. Fires whether the handler
          raised (worker caught it into Err) or PreflightToolCall
          rejected the args. Hooks see Stage = hsDuringToolCall.
          (Codex P2 on PR #110.) }
        if (Length(Cfg.Hooks) > 0) and (Dispatches[Batch[j]].Err <> '') then
          HooksOnError(Cfg.Hooks, hsDuringToolCall,
                        Format('tool "%s": %s',
                               [Dispatches[Batch[j]].Call.Func.Name,
                                Dispatches[Batch[j]].Err]));
        SetLength(Hist, Length(Hist) + 1);
        if Dispatches[Batch[j]].Err <> '' then
          Hist[High(Hist)] := MakeToolResult(Dispatches[Batch[j]].Call.Id,
                                              'ERROR: ' + Dispatches[Batch[j]].Err)
        else
        begin
          { JSON-aware condensation, gated on the reversible-condensation
            switch (Codex PR #289 P1). When CondenseReversibleEnabled
            is False the stash footer no-ops, but MaybeCondenseJSON was
            still rewriting a 200 KB JSON tool result into a structural
            summary -- and without the footer the model lost any way
            to retrieve the original bytes. Skip the condenser
            entirely so "off" means the raw JSON reaches the model,
            not condensed-without-recovery.

            When the switch IS on: a tool that returned a 200 KB
            JSON array of mostly-repetitive rows collapses to a
            structural summary (first N + "...K more items" + last 1)
            the model can still reason about, which is usually small
            enough to skip the byte-budget truncate below entirely.
            No-op when the body doesn't parse as JSON or when
            condensation wouldn't shrink it. See PasClaw.Condense.JSON.

            Reversible condensation (CCR, headroom-inspired): when
            MaybeCondenseJSON actually shrinks the body, stash the
            original under a handle so the model can call
            tool_output_get to retrieve it. The model defaults to the
            structural view; the escape hatch is one tool call away. }
          if CondenseReversibleEnabled then
          begin
            OrigBody := Dispatches[Batch[j]].ResultText;
            Dispatches[Batch[j]].ResultText :=
              MaybeCondenseJSON(OrigBody);
            Dispatches[Batch[j]].ResultText :=
              AttachReversibleStashFooter(OrigBody,
                                          Dispatches[Batch[j]].ResultText);
          end;

          { Promptware chokepoint 1 of 3: tool output is the widest
            door for indirect prompt injection (fetched pages, read
            files, MCP responses). A pattern hit prepends a warning
            banner -- annotate, never block; see PasClaw.Promptware.
            Runs after condensation (scan the bytes the model will
            actually see) and before the byte-cap below (so the
            banner survives truncation's head slice). }
          Dispatches[Batch[j]].ResultText :=
            MaybeFlagPromptware(Dispatches[Batch[j]].ResultText,
                                'tool output (' +
                                Dispatches[Batch[j]].Call.Func.Name + ')');

          { Cap large successful tool outputs (errors stay verbatim --
            they're already short and the head/tail split would just
            obscure the actual failure). The handle goes into the
            in-context replacement; the full bytes live in the
            process-lifetime OutputCache for tool_output_get to
            dereference. Cap = 0 disables (legacy behaviour). }
          if (Cfg.ToolOutputCap > 0)
             and (Length(Dispatches[Batch[j]].ResultText) > Cfg.ToolOutputCap) then
          begin
            OrigLen := Length(Dispatches[Batch[j]].ResultText);
            InContext := StashAndMaybeTruncate(Dispatches[Batch[j]].ResultText,
                                               Cfg.ToolOutputCap, Truncated);
            if Truncated then
            begin
              Inc(Loop.Truncations);
              Inc(Loop.TruncatedBytesSaved, OrigLen - Length(InContext));
            end;
            Hist[High(Hist)] := MakeToolResult(Dispatches[Batch[j]].Call.Id, InContext);
          end
          else
            Hist[High(Hist)] := MakeToolResult(Dispatches[Batch[j]].Call.Id,
                                                Dispatches[Batch[j]].ResultText);
        end;
      end;

      { Phase 3: if any hook contributed a steering note, fold it
        into LiveOptions.SystemPrompt so the next iteration's LLM
        round-trip sees it.

        WHY THE SYSTEM PROMPT, NOT mrSystem IN HISTORY:
          The PasClaw.Providers.OpenAI / Anthropic / Gemini builders
          explicitly DROP in-history mrSystem entries whenever the
          ChatOptions.SystemPrompt slot is non-empty -- they ship one
          consolidated system prompt via that slot, not via the
          messages array, so an mrSystem appended to Hist gets
          silently dropped on the next provider call. TPasClawAgent.
          ChatHistory always populates Cfg.Options.SystemPrompt via
          BuildSystemPrompt, so the default component path always
          hits this case. Routing steering through SystemPrompt
          keeps it visible on every provider. (Codex P1 on PR #110.)

          Side effect: steering accumulates across iterations, which
          is the picoclaw semantic -- each new tool result can add
          context that the model carries through to the end of the
          loop. If an embedder wants ephemeral per-batch steering
          they can reset SystemPrompt in BeforeTurn. }
      if BatchSteering <> '' then
      begin
        { Copy any mrSystem messages from Hist into SystemPrompt
          when (and only when) SystemPrompt is currently empty.
          Reasoning:

            * SystemPrompt empty + mrSystem in Hist: provider
              builders ship the mrSystem entries as the system
              prompt. We want our steering to ride along with the
              policy, so we copy the policy text into SystemPrompt
              first, then append steering. After this call,
              SystemPrompt is non-empty and the provider builders
              drop in-history mrSystem on the next round (using
              SystemPrompt instead). The Hist mrSystem entries
              stay PUT -- non-destructive copy -- so if a BeforeTurn
              hook later resets SystemPrompt to '' for the
              ephemeral-steering pattern, the policy is still
              available in Hist and ships again via the in-history
              channel. (Codex P2 on PR #114.)

            * SystemPrompt non-empty: it already contains the
              policy (folded on the first pass) plus prior steering.
              Just append the new steering. Re-reading Hist here
              would duplicate the policy text on every fold.

          Either way the policy reaches the model. }
        if (LiveOptions.SystemPrompt = '') then
        begin
          HistSystem := CopyHistorySystem(Hist);
          if HistSystem <> '' then
            LiveOptions.SystemPrompt := HistSystem;
        end;
        if LiveOptions.SystemPrompt <> '' then
          LiveOptions.SystemPrompt := LiveOptions.SystemPrompt
                                      + sLineBreak + sLineBreak
                                      + BatchSteering
        else
          LiveOptions.SystemPrompt := BatchSteering;
      end;
    end;
  end;

  { Max iterations exhausted; return whatever we last got. The loop only
    reaches here with Resp still carrying tool calls (a tool-less response
    Exit(True)s above), so this is the "ran out of room mid-task" stop --
    flag it and capture what it was doing so callers can offer a continue. }
  Loop.Content    := Resp.Content;
  Loop.Iterations := Iter;
  Loop.FinalMessages    := Hist;
  Loop.FinalSystemPrompt := LiveOptions.SystemPrompt;
  Loop.HitMaxIterations := Length(Resp.ToolCalls) > 0;
  if Loop.HitMaxIterations then
    Loop.PendingToolNames := CollectToolNames(Resp.ToolCalls);
  Result := True;
  finally
    { Roll the final per-turn telemetry into the span before
      flushing. Iterations + total token usage are the two
      numbers anyone looking at a trace will want first; the
      provider already has per-call counters on each chat span. }
    SetAttrInt(TurnSpan, 'openclaw.iterations', Loop.Iterations);
    SetAttrInt(TurnSpan, 'gen_ai.usage.input_tokens',  Loop.TotalUsage.InputTokens);
    SetAttrInt(TurnSpan, 'gen_ai.usage.output_tokens', Loop.TotalUsage.OutputTokens);
    if not Result then SetStatus(TurnSpan, oscError, 'agent turn returned false');
    FinishSpan(TurnSpan);
  end;
end;

end.
