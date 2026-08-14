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
    TCompactOptions         tuning knobs (token threshold, retention
                             budget, recent-turn floor, summariser
                             budget, memory-flush callback).
    NeedsCompact            cheap token-count check; tool loop calls
                             each iteration before the LLM round.
    CompactMessages         does the work; signature explained below.
    IsContextOverflowError  classifies a provider error as "the
                             context window overflowed", so the loop
                             can compact reactively and retry.

  The summary is a ROLLING RECORD, not a chain:
    The first compaction appends a "[Conversation summary so far]"
    block to the system prompt. Every later compaction REPLACES that
    block -- and feeds the old summary to the summariser as the head
    of its input, so the new block folds the old record and the newer
    turns into one. Without both halves of that, repeat compactions
    appended block after block into a prompt the trigger never
    counted: the second summary described only the turns since the
    first, the stack grew without bound, and nothing ever noticed.
    NeedsCompact takes the system prompt for the same reason -- a
    summary that has moved in there still occupies context.

  Retention is a token budget, not a message count:
    RetainBudgetTokens decides the cut -- walk back from the newest
    message until the budget is spent. A fixed count keeps 200 tokens
    or 200K depending on what the messages are; a tail of fat tool
    results used to survive compaction nearly whole, which meant
    compacting could fail to shrink anything. KeepRecentTurns remains
    as a FLOOR (never keep fewer than N messages), so one giant tool
    result cannot reduce the tail to nothing.

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
    RetainBudgetTokens  20_000   (recent history kept verbatim)
    KeepRecentTurns     8        (floor: never keep fewer messages)
    SummaryBudget       800      (tokens; the summariser is told to
                                  stay under this)
  All four are configurable via the "compaction" block in config.json;
  these are the values used when the block is absent.
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
    ThresholdTokens:    Integer;
    RetainBudgetTokens: Integer;
    KeepRecentTurns:    Integer;
    SummaryBudget:      Integer;
    OnBefore:           TCompactBeforeCallback;
  end;

function DefaultCompactOptions: TCompactOptions;

(* True iff the combined message bodies PLUS the system prompt
   estimate above ThresholdTokens. Cheap -- uses the existing
   4-chars-per-token heuristic from PasClaw.Tokenizer. The system
   prompt counts because compaction itself grows it: the summary
   lives there, and a trigger that cannot see the summary would let
   repeat compactions accumulate context it never measures. Returns
   False unconditionally if Threshold <= 0 so a misconfigured
   threshold disables the feature instead of compacting on every
   call. *)
function NeedsCompact(const Messages: array of TMessage;
                      const SystemPrompt: string;
                      Threshold: Integer): Boolean;

(* True when a provider response says the CONTEXT WINDOW overflowed --
   the request was too big, as opposed to failed. Matched on the error
   text because every provider words it differently (Anthropic:
   "prompt is too long", OpenAI: "context_length_exceeded", Gemini:
   "input token count ... exceeds"); the status code only gates the
   check, since a 2xx cannot be an overflow. Conservative on purpose:
   a false negative is today's behaviour (the error surfaces), a
   false positive spends a pointless summary call. The tool loop uses
   this to compact reactively and retry once -- the safety net for
   the estimator above running low on token-dense content. *)
function IsContextOverflowError(StatusCode: Integer;
                                const ErrText: string): Boolean;

(* Returns a compacted message list AND updates Options.SystemPrompt
   to carry the summary + caller's preserved system instructions.
   Logic:
     1. If too few messages to slice OR provider is nil, return
        Messages verbatim and leave Options untouched.
     2. Extract every leading mrSystem message; concatenate their
        bodies for the SystemPrompt rebuild later.
     3. Split any existing "[Conversation summary so far]" block off
        Options.SystemPrompt -- the base is rebuilt on, the old
        summary becomes the head of the summariser's input.
     4. Pick the cut on the NON-system portion: keep the newest
        messages that fit RetainBudgetTokens, with KeepRecentTurns as
        a floor. Walk the cut forward over any leading mrTool
        messages in the tail so a tool_call/tool_result pair is
        never split.
     5. Cap the prefix at SUMMARY_INPUT_CAP_TOKENS by dropping
        oldest messages until under cap -- prevents the summariser
        from inheriting the same context-overflow we're trying to
        prevent. The old summary is not subject to the cap; it is
        the record of everything already dropped once.
     6. Fire OnBefore (if set) with the full original list so the
        memory subsystem can persist anything important before we
        drop it.
     7. Call Provider.Chat with a single summary-instruction
        message; on failure return verbatim with a log warn.
     8. Build the new Options.SystemPrompt:
          [base prompt, old summary block removed]
          [caller's leading mrSystem messages, verbatim]
          [Conversation summary so far]
          [summary text]
        Empty sections are skipped.
     9. Result Messages = preserved tail only -- no mrSystem
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

  { The block CompactMessages owns inside Options.SystemPrompt. It is
    always the LAST section (rebuilds append it last, and nothing else
    writes below it), which is what lets SplitSummaryBlock treat
    everything after the marker as the summary. }
  SummaryMarker = '[Conversation summary so far]';

function DefaultCompactOptions: TCompactOptions;
begin
  Result.ThresholdTokens    := 80000;
  Result.RetainBudgetTokens := 20000;
  Result.KeepRecentTurns    := 8;
  Result.SummaryBudget      := 800;
  Result.OnBefore           := nil;
end;

function NeedsCompact(const Messages: array of TMessage;
                      const SystemPrompt: string;
                      Threshold: Integer): Boolean;
var
  i, Total: Integer;
begin
  Result := False;
  if Threshold <= 0 then Exit;
  Total := EstimateTokens(SystemPrompt);
  if Total >= Threshold then Exit(True);
  for i := 0 to High(Messages) do
  begin
    Total := Total + EstimateTokens(Messages[i].Content) + 4;   { envelope }
    if Total >= Threshold then Exit(True);
  end;
end;

function IsContextOverflowError(StatusCode: Integer;
                                const ErrText: string): Boolean;
var
  T: string;
begin
  Result := False;
  { A success cannot be an overflow, whatever the body says. }
  if (StatusCode >= 200) and (StatusCode < 300) then Exit;
  T := LowerCase(ErrText);
  if T = '' then Exit;
  { One phrase per known provider wording, plus the generic forms.
    Substrings, not JSON fields: the text arrives as an error body,
    an exception message, or a provider's own prose, and all three
    reach here flattened. }
  Result :=
    (Pos('prompt is too long', T) > 0) or                { Anthropic }
    (Pos('context_length_exceeded', T) > 0) or           { OpenAI }
    (Pos('maximum context length', T) > 0) or            { OpenAI prose }
    (Pos('exceeds the maximum number of tokens', T) > 0) or  { Gemini }
    (Pos('input token count', T) > 0) and (Pos('exceed', T) > 0) or
    (Pos('context window', T) > 0) and (Pos('exceed', T) > 0) or
    (Pos('too many tokens', T) > 0);
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

(* The summariser's instruction.

   Sectioned rather than free-form: under a tight budget a flat note
   sheds whatever the model deems least interesting, and what it deems
   least interesting is usually the open questions. Named sections make
   the omission visible -- an empty "Open questions" is a statement, a
   note that never mentions them is a gap. The framing is a handoff
   briefing: the next reader is the same agent, minutes later, with no
   other record of this part of the conversation.

   PrevSummary is the ROLLING RECORD -- the block a previous compaction
   wrote, which the caller has just cut out of the system prompt. It
   goes first, as record rather than transcript, and the instruction is
   to fold, not to append: the output must be one record, under one
   budget, covering both. *)
function BuildSummaryPrompt(const PrevSummary: string;
                             const Slice: array of TMessage;
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
    'Update the running record of this conversation -- a handoff ' +
    'briefing from this stretch of work to the next. Write these ' +
    'sections, each as terse prose or short bullets:' + sLineBreak +
    'Goal: what the user is trying to get done.' + sLineBreak +
    'Progress: what has been produced or settled so far.' + sLineBreak +
    'Key decisions: choices made and the constraint behind each.' + sLineBreak +
    'Errors encountered: what failed and what the fix was.' + sLineBreak +
    'Open questions: anything raised and not yet resolved.' + sLineBreak +
    'Preserve key user facts and preferences, and code paths or ' +
    'symbols referenced. Drop small talk, redundant restatements, and ' +
    'tool output that has been superseded. Stay under ' +
    IntToStr(Budget) + ' tokens total. Write the record, nothing else.';
  if Trim(PrevSummary) <> '' then
    Result := Result + sLineBreak + sLineBreak +
      '--- the record so far (fold it in; do not repeat it verbatim) ---' +
      sLineBreak + sLineBreak + Trim(PrevSummary);
  Result := Result + sLineBreak + sLineBreak +
    '--- newer conversation to fold in ---' + sLineBreak + sLineBreak +
    Lines;
end;

(* Split an existing summary block off a system prompt.

   Base gets everything before the marker (trailing whitespace
   trimmed), PrevSummary the text after it. When the marker is absent
   the whole prompt is Base and PrevSummary is '' -- the first
   compaction. This is the other half of the rolling record: without
   it, every compaction APPENDED a block after the last one, the
   second summary only described the turns since the first, and the
   prompt grew without bound in a place the trigger never measured. *)
procedure SplitSummaryBlock(const SystemPrompt: string;
                              out Base, PrevSummary: string);
var
  P: Integer;
begin
  P := Pos(SummaryMarker, SystemPrompt);
  if P = 0 then
  begin
    Base := SystemPrompt;
    PrevSummary := '';
    Exit;
  end;
  Base := TrimRight(Copy(SystemPrompt, 1, P - 1));
  PrevSummary := Trim(Copy(SystemPrompt, P + Length(SummaryMarker), MaxInt));
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
  KeepLen, Cut, BudgetCut, TailTokens, i, OutIdx: Integer;
  LeadingSystems, Body, Prefix, CappedPrefix: TMessageArray;
  OneCall: array of TMessage;
  EmptyTools: array of TToolDefinition;
  CallOptions: TChatOptions;
  Resp: TLLMResponse;
  Summary, NewSystem, CallerSystemText, BasePrompt, PrevSummary: string;
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

  { The cut: the token budget decides, the message count is a floor.

    Walk back from the newest message accumulating estimated tokens;
    the first message that would blow RetainBudgetTokens is where the
    tail ends. A fixed count cannot do this job -- eight one-liners
    and eight 30K tool results are both "8 messages", and keeping the
    latter verbatim meant compaction could fire and shrink nothing,
    then fire again on a body too short to slice. The floor pulls the
    other way: however fat the tail, at least KeepLen messages
    survive, so the model always sees some literal recent turns. }
  Cut := Length(Body) - KeepLen;
  if Opts.RetainBudgetTokens > 0 then
  begin
    BudgetCut := Length(Body);
    TailTokens := 0;
    for i := High(Body) downto 0 do
    begin
      TailTokens := TailTokens + EstimateTokens(Body[i].Content) + 4;
      if TailTokens > Opts.RetainBudgetTokens then Break;
      BudgetCut := i;
    end;
    { A small tail moves the cut earlier (keep more); a fat tail
      would move it later, and the floor holds it where it is. }
    if BudgetCut < Cut then Cut := BudgetCut;
  end;
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

  { The old summary block comes OUT of the prompt and INTO the
    summariser's input. Split before the call so a failure below
    leaves Options untouched -- BasePrompt/PrevSummary are locals
    until the rebuild. }
  SplitSummaryBlock(Options.SystemPrompt, BasePrompt, PrevSummary);

  SetLength(OneCall, 1);
  OneCall[0] := MakeMessage(mrUser,
                            BuildSummaryPrompt(PrevSummary, CappedPrefix,
                                               Opts.SummaryBudget));

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
      [base prompt -- the old summary block already split off]
      [caller's leading mrSystem messages, verbatim]
      [Conversation summary so far] block, exactly ONE
    The caller's policy is preserved BIT-FOR-BIT, never run through
    the summariser. Building on BasePrompt rather than the raw
    prompt is what makes the summary a rolling record: the previous
    block was removed above and its content folded into Summary, so
    repeat compactions converge instead of stacking blocks. }
  CallerSystemText := JoinSystemBodies(LeadingSystems);
  NewSystem := Trim(BasePrompt);
  if CallerSystemText <> '' then
  begin
    if NewSystem <> '' then NewSystem := NewSystem + sLineBreak + sLineBreak;
    NewSystem := NewSystem + CallerSystemText;
  end;
  if NewSystem <> '' then NewSystem := NewSystem + sLineBreak + sLineBreak;
  NewSystem := NewSystem + SummaryMarker + sLineBreak + Summary;
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
