(*
  PasClaw.Agent.Compact - conversation-history compaction.

  When the tool loop's running history grows past a token budget, the
  next provider call risks overflowing the model's context window --
  rejected outright (Anthropic / OpenAI 400) or burning quota for
  diminishing returns. Compaction replaces the older portion of the
  history with a summarised system note, keeping the most recent N
  turns verbatim so the model still sees fresh context.

  Picoclaw does this; we left a stub in the Phase A memory PR notes.

  Shape:
    TCompactOptions     tuning knobs (token threshold, recent-turn
                         count, summariser budget, memory-flush
                         callback).
    NeedsCompact        cheap token-count check; tool loop calls
                         each iteration before the LLM round.
    CompactMessages     does the work; signature explained below.

  Why the summary lives in Options.SystemPrompt, not as an mrSystem
  message (PR #87 Codex P1):
    The OpenAI request builder skips every mrSystem history item
    when Options.SystemPrompt is non-empty. The Anthropic builder
    always drops system-role history after preferring
    Options.SystemPrompt. If we stored the summary as
    mrSystem in the returned messages, both default-path providers
    would silently throw it away after compaction -- the model
    would see only the recent tail with no record of what came
    before. So CompactMessages takes Options as var and folds the
    summary INTO Options.SystemPrompt where both builders honour
    it.

  Caller-supplied system messages (PR #87 Codex P1):
    For /v1/chat/completions, the gateway intentionally leaves
    Options.SystemPrompt empty when the caller's request already
    contains a leading mrSystem message -- Messages[0] is then
    the authoritative system policy. If we summarised that policy
    along with the rest of the prefix, the summariser could
    distort, omit, or be influenced by untrusted user turns mixed
    into the same call. CompactMessages now extracts every leading
    mrSystem message FIRST, joins their bodies verbatim into the
    new SystemPrompt, and only summarises the remaining (non-
    system) turns.

  Tool-call boundary safety (PR #87 Codex P2):
    A single assistant turn can carry N tool_calls followed by N
    tool_result messages. If KeepRecentTurns lands the cut in the
    middle of that group, the tail starts with an orphaned
    tool_result -- Anthropic and OpenAI 400 with "no matching
    tool_use" and Gemini can't resolve the function name. The
    cut walks BACKWARD past any leading mrTool messages in the
    tail until the boundary lands on a clean turn.

  Summariser input cap (PR #87 Codex P2):
    The summariser call is itself subject to the model's context
    limit. If a single tool result (e.g. a 200 KB fs_read body)
    already overflows that limit, naively shipping the full
    prefix to summarise just reproduces the same error. The
    summariser input is capped at SUMMARY_INPUT_CAP_TOKENS;
    oldest messages above the cap are dropped before
    summarisation (they're the least relevant by recency
    anyway).

  Defaults match what most Claude / GPT-4 deployments tolerate:
    ThresholdTokens     80_000   (compact well before the 100/200K cap)
    KeepRecentTurns     8        (last 4 user+assistant pairs)
    SummaryBudget       800      (tokens; the summariser is told to
                                  stay under this)
*)
unit PasClaw.Agent.Compact;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  TCompactBeforeCallback = procedure(const Messages: array of TMessage) of object;

  TCompactOptions = record
    ThresholdTokens: Integer;
    KeepRecentTurns: Integer;
    SummaryBudget:   Integer;
    OnBefore:        TCompactBeforeCallback;
  end;

function DefaultCompactOptions: TCompactOptions;

(* True iff the combined message bodies estimate above
   ThresholdTokens. Cheap -- uses the existing 4-chars-per-token
   heuristic from PasClaw.Tokenizer. Returns False unconditionally
   if Threshold <= 0 so a misconfigured threshold disables the
   feature instead of compacting on every call. *)
function NeedsCompact(const Messages: array of TMessage;
                      Threshold: Integer): Boolean;

(* Returns a compacted message list AND updates Options.SystemPrompt
   to carry the summary + caller's preserved system instructions.
   Logic:
     1. If too few messages to slice OR provider is nil, return
        Messages verbatim and leave Options untouched.
     2. Extract every leading mrSystem message; concatenate their
        bodies for the SystemPrompt rebuild later.
     3. Pick the cut on the NON-system portion: keep the last
        KeepRecentTurns. Walk the cut backward over any leading
        mrTool messages in the tail so a tool_call/tool_result
        pair is never split.
     4. Cap the prefix at SUMMARY_INPUT_CAP_TOKENS by dropping
        oldest messages until under cap -- prevents the summariser
        from inheriting the same context-overflow we're trying to
        prevent.
     5. Fire OnBefore (if set) with the full original list so the
        memory subsystem can persist anything important before we
        drop it.
     6. Call Provider.Chat with a single summary-instruction
        message; on failure return verbatim with a log warn.
     7. Build the new Options.SystemPrompt:
          [original Options.SystemPrompt]
          [caller's leading mrSystem messages, verbatim]
          [Conversation summary so far]
          [summary text]
        Empty sections are skipped.
     8. Result Messages = preserved tail only -- no mrSystem
        entries (they all moved into Options.SystemPrompt).
*)
function CompactMessages(Provider: ILLMProvider; const Model: string;
                         const Messages: array of TMessage;
                         var Options: TChatOptions;
                         const Opts: TCompactOptions): TMessageArray;

implementation

uses
  PasClaw.Tokenizer,
  PasClaw.Logger;

const
  (* Hard cap on the summariser's input -- well below most model
     context limits, so even when the conversation that triggered
     compaction was itself oversized (one giant fs_read result), the
     summariser call still fits. *)
  SUMMARY_INPUT_CAP_TOKENS = 60000;

function DefaultCompactOptions: TCompactOptions;
begin
  Result.ThresholdTokens := 80000;
  Result.KeepRecentTurns := 8;
  Result.SummaryBudget   := 800;
  Result.OnBefore        := nil;
end;

function NeedsCompact(const Messages: array of TMessage;
                      Threshold: Integer): Boolean;
var
  i, Total: Integer;
begin
  Result := False;
  if Threshold <= 0 then Exit;
  Total := 0;
  for i := 0 to High(Messages) do
  begin
    Total := Total + EstimateTokens(Messages[i].Content) + 4;   { envelope }
    if Total >= Threshold then Exit(True);
  end;
end;

function FormatRole(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool';
  else           Result := 'user';
  end;
end;

function BuildSummaryPrompt(const Slice: array of TMessage;
                             Budget: Integer): string;
var
  i: Integer;
  Lines: string;
begin
  Lines := '';
  for i := 0 to High(Slice) do
  begin
    Lines := Lines + '[' + FormatRole(Slice[i].Role) + ']' + sLineBreak;
    Lines := Lines + Trim(Slice[i].Content) + sLineBreak + sLineBreak;
  end;
  Result :=
    'Summarise the conversation below into a concise running record. ' +
    'Preserve: key user facts and preferences, decisions made, code ' +
    'paths or symbols referenced, errors encountered, and open questions. ' +
    'Drop: small talk, redundant restatements, tool output that has been ' +
    'superseded. Stay under ' + IntToStr(Budget) + ' tokens. Write as a ' +
    'compact note, not a dialogue.' + sLineBreak + sLineBreak +
    '--- conversation ---' + sLineBreak + sLineBreak +
    Lines;
end;

(* Returns the slice of NonSystem starting at the cut where every
   mrTool message at the front of the tail has been pulled back into
   the prefix. Guarantees the resulting tail's first message is NOT
   mrTool, so no tool_result lands without its assistant tool_call. *)
function ShiftCutPastToolResults(const NonSystem: array of TMessage;
                                  InitialCut: Integer): Integer;
begin
  Result := InitialCut;
  if Result < 0 then Result := 0;
  if Result > Length(NonSystem) then Result := Length(NonSystem);
  while (Result < Length(NonSystem)) and (NonSystem[Result].Role = mrTool) do
    Inc(Result);
  { Inc past tool_results means the prefix grew, the tail shrank.
    Net effect: assistant tool_call + all its tool_results stay
    together in the prefix (and get summarised together) or in the
    tail (and survive verbatim) -- never split. }
end;

(* Drop oldest messages from Prefix until the estimated token total
   fits SUMMARY_INPUT_CAP_TOKENS. The oldest messages are the
   least relevant by recency, so trimming them is preferable to
   sending an oversized summariser call. *)
function CapPrefix(const Prefix: array of TMessage): TMessageArray;
var
  Total, Drop, i: Integer;
begin
  Total := 0;
  for i := 0 to High(Prefix) do
    Total := Total + EstimateTokens(Prefix[i].Content) + 4;
  Drop := 0;
  while (Total > SUMMARY_INPUT_CAP_TOKENS) and (Drop < Length(Prefix)) do
  begin
    Total := Total - (EstimateTokens(Prefix[Drop].Content) + 4);
    Inc(Drop);
  end;
  if Drop > 0 then
    LogWarn('compact: prefix ~%d tokens; dropping %d oldest msgs to fit summariser cap %d',
            [Total + Drop * 4, Drop, SUMMARY_INPUT_CAP_TOKENS]);
  SetLength(Result, Length(Prefix) - Drop);
  for i := 0 to High(Result) do
    Result[i] := Prefix[Drop + i];
end;

procedure SplitSystemFromBody(const Messages: array of TMessage;
                                out LeadingSystems: TMessageArray;
                                out Body: TMessageArray);
var
  LeadCount, i: Integer;
begin
  LeadCount := 0;
  while (LeadCount < Length(Messages)) and (Messages[LeadCount].Role = mrSystem) do
    Inc(LeadCount);
  SetLength(LeadingSystems, LeadCount);
  for i := 0 to LeadCount - 1 do LeadingSystems[i] := Messages[i];
  SetLength(Body, Length(Messages) - LeadCount);
  for i := 0 to High(Body) do Body[i] := Messages[LeadCount + i];
end;

function JoinSystemBodies(const Systems: array of TMessage): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Systems) do
  begin
    if Result <> '' then Result := Result + sLineBreak + sLineBreak;
    Result := Result + Trim(Systems[i].Content);
  end;
end;

function ReturnVerbatim(const Messages: array of TMessage): TMessageArray;
var
  i: Integer;
begin
  SetLength(Result, Length(Messages));
  for i := 0 to High(Messages) do Result[i] := Messages[i];
end;

function CompactMessages(Provider: ILLMProvider; const Model: string;
                         const Messages: array of TMessage;
                         var Options: TChatOptions;
                         const Opts: TCompactOptions): TMessageArray;
var
  KeepLen, Cut, i, OutIdx: Integer;
  LeadingSystems, Body, Prefix, CappedPrefix: TMessageArray;
  OneCall: array of TMessage;
  EmptyTools: array of TToolDefinition;
  CallOptions: TChatOptions;
  Resp: TLLMResponse;
  Summary, NewSystem, CallerSystemText: string;
begin
  Result := nil;
  KeepLen := Opts.KeepRecentTurns;
  if KeepLen < 0 then KeepLen := 0;

  if Provider = nil then
  begin
    LogWarn('compact: no provider -- skipping compaction, returning verbatim', []);
    Exit(ReturnVerbatim(Messages));
  end;

  SplitSystemFromBody(Messages, LeadingSystems, Body);

  if Length(Body) <= KeepLen + 1 then
  begin
    { Nothing meaningful in the non-system body to compact. }
    Exit(ReturnVerbatim(Messages));
  end;

  if Assigned(Opts.OnBefore) then
  try
    Opts.OnBefore(Messages);
  except
    on E: Exception do
      LogWarn('compact: OnBefore raised %s: %s -- continuing', [E.ClassName, E.Message]);
  end;

  Cut := Length(Body) - KeepLen;
  Cut := ShiftCutPastToolResults(Body, Cut);
  if Cut <= 0 then
  begin
    { After tool-boundary adjustment we have nothing to summarise --
      the whole body is a single tool-exchange group. Return
      verbatim; trying to split it would orphan tool results. }
    LogDebug('compact: cut shifted to 0 (single tool-call group covers full body) -- verbatim', []);
    Exit(ReturnVerbatim(Messages));
  end;

  SetLength(Prefix, Cut);
  for i := 0 to Cut - 1 do Prefix[i] := Body[i];
  CappedPrefix := CapPrefix(Prefix);
  if Length(CappedPrefix) = 0 then
  begin
    { Prefix entirely dropped to fit the cap -- nothing to summarise. }
    LogWarn('compact: prefix capped to empty; returning verbatim', []);
    Exit(ReturnVerbatim(Messages));
  end;

  SetLength(OneCall, 1);
  OneCall[0] := MakeMessage(mrUser,
                            BuildSummaryPrompt(CappedPrefix, Opts.SummaryBudget));

  CallOptions := DefaultChatOptions;
  { Inherit cache policy from the caller's Options -- caller already
    applied Cfg.PromptCache; the summariser call should follow the
    same policy. (Codex P2 on PR #118: don't unconditionally cache
    just because DefaultChatOptions does.) }
  CallOptions.CacheEnabled := Options.CacheEnabled;
  CallOptions.CacheTTL     := Options.CacheTTL;
  CallOptions.MaxTokens := Opts.SummaryBudget * 2;   { allow some slack }
  if CallOptions.MaxTokens < 1024 then CallOptions.MaxTokens := 1024;

  SetLength(EmptyTools, 0);
  try
    Resp := Provider.Chat(OneCall, EmptyTools, Model, CallOptions);
  except
    on E: Exception do
    begin
      LogWarn('compact: summary call raised %s: %s -- returning verbatim',
              [E.ClassName, E.Message]);
      Exit(ReturnVerbatim(Messages));
    end;
  end;

  Summary := Trim(Resp.Content);
  if Summary = '' then
  begin
    LogWarn('compact: empty summary -- returning verbatim', []);
    Exit(ReturnVerbatim(Messages));
  end;

  { Rebuild Options.SystemPrompt. The summary goes in here, NOT as
    a returned mrSystem message, because the OpenAI / Anthropic
    request builders silently drop in-message mrSystem entries
    when Options.SystemPrompt is set (Codex P1). Sections, joined
    by blank lines, skipped when empty:
      [original Options.SystemPrompt]
      [caller's leading mrSystem messages, verbatim]
      [Conversation summary so far] block
    The caller's policy is preserved BIT-FOR-BIT, never run through
    the summariser. }
  CallerSystemText := JoinSystemBodies(LeadingSystems);
  NewSystem := Trim(Options.SystemPrompt);
  if CallerSystemText <> '' then
  begin
    if NewSystem <> '' then NewSystem := NewSystem + sLineBreak + sLineBreak;
    NewSystem := NewSystem + CallerSystemText;
  end;
  if NewSystem <> '' then NewSystem := NewSystem + sLineBreak + sLineBreak;
  NewSystem := NewSystem + '[Conversation summary so far]' + sLineBreak + Summary;
  Options.SystemPrompt := NewSystem;

  { New body = preserved tail only (no system messages -- they live
    in Options.SystemPrompt now). }
  SetLength(Result, Length(Body) - Cut);
  OutIdx := 0;
  for i := Cut to High(Body) do
  begin
    Result[OutIdx] := Body[i];
    Inc(OutIdx);
  end;

  LogInfo('compact: %d msgs (incl %d system) → 0 system + %d tail msgs; ' +
          'summary ~%d tokens folded into SystemPrompt',
          [Length(Messages), Length(LeadingSystems), Length(Result),
           EstimateTokens(Summary)]);
end;

end.
