(*
  PasClaw.Agent.Goals - the "Ralph" loop. The operator declares an
  OBJECTIVE; the runner takes over the next N turns:

    1. Append the goal to the running history.
    2. Run one normal tool-loop turn (RunToolLoop with full tools +
       fallbacks).
    3. Show the assistant's reply (caller's OnIter callback).
    4. Hand the goal + the latest reply to a JUDGE provider call --
       a separate Chat() round-trip with a focused system prompt
       that asks for one of three verdicts:

           MET       -- the goal is achieved; stop.
           CONTINUE  -- not yet; suggest the next concrete step.
           FAILED    -- the goal cannot be achieved as stated; stop.

    5. Parse the verdict. On MET / FAILED stop with the reason. On
       CONTINUE, append the judge's suggestion as the NEXT user
       message and loop back to (2).
    6. Cap the loop at MaxIterations. The operator's turn budget is
       the explicit ceiling; the runner never exceeds it even if
       the judge keeps saying CONTINUE.

  Why a separate judge call (instead of asking the assistant
  to self-evaluate at the end of each turn):

    - The assistant is biased toward declaring victory; it just
      did the work. A fresh provider round-trip with no tool
      context, no working state, no compaction summary makes a
      cleaner pass/fail decision.
    - The judge can use a cheaper model. The operator can wire
      Cfg.AutoRouter.EasyProvider / EasyModel as the judge target;
      a one-line "did this meet the goal" call doesn't need the
      same horsepower as the main agent.
    - Future: the judge can be a different VENDOR entirely. Some
      operators want Anthropic doing the work and OpenAI grading
      (or vice versa) as a sanity check against shared blind
      spots.

  This unit is transport-agnostic and does NOT know about TUI or
  Cmd.Agent. Callers (PasClaw.Cmd.Agent's interactive /goal handler,
  the TUI's /goal slash command) wire the agent loop into
  TGoalRunner via the OnTurnFn callback. That callback is the
  point where the caller drives RunToolLoop with whatever full
  config they normally use -- working state prefix, MCP bridge,
  compaction, etc. The Goals unit stays small and stays free of
  Cmd.Agent's import jungle.
*)
unit PasClaw.Agent.Goals;

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
  PasClaw.Providers.Intf;

type
  TGoalVerdict = (
    gvMet,                 // judge said MET; goal achieved
    gvFailed,              // judge said FAILED; explicit non-recoverable
    gvBudgetExhausted,     // ran out of iterations before MET
    gvAborted              // caller's OnTurnFn returned False -- giving up
  );

  TGoalResult = record
    Verdict:    TGoalVerdict;
    Iterations: Integer;
    LastReply:  string;       // the assistant's most recent reply
    JudgeText:  string;       // the judge's verbatim final response
    Reason:     string;       // the judge's free-form "why" extracted
                              // from its final response
  end;

  { Caller-supplied function that runs ONE agent turn for the given
    user message, mutates the running message history (appends the
    user turn + the assistant + tool calls + tool results), and
    returns the assistant's final text reply in Reply.

    The caller owns the Hist array: TGoalRunner reads it back after
    each call to assemble the judge prompt, but never mutates it
    directly. Return False to abort the goal loop (e.g., the user
    pressed Ctrl-C or the underlying RunToolLoop failed); the
    runner returns gvAborted on the next iteration check. }
  TGoalTurnFn = function(const UserMsg: string;
                          var Hist: TMessageArray;
                          out Reply: string): Boolean of object;

  { Optional per-iteration progress hook. Called AFTER the assistant
    reply on each iteration but BEFORE the judge call. Lets the
    caller flush a "iter %d/%d" line + the model's preliminary
    reply to the operator so a long goal loop doesn't sit silent.
    Reply is the assistant's most recent free-form reply. }
  TGoalProgressFn = procedure(IterNo, MaxIter: Integer;
                               const Reply: string) of object;

  TGoalRunner = class
  private
    FProvider:     ILLMProvider;
    FJudgeModel:   string;
    FMaxIter:      Integer;
    FJudgePrompt:  string;
    FOnTurn:       TGoalTurnFn;
    FOnProgress:   TGoalProgressFn;
    function  AskJudge(const Goal, AssistantReply: string;
                        out RawText, Reason: string;
                        out Verdict: TGoalVerdict): Boolean;
  public
    constructor Create(AProvider: ILLMProvider;
                       const AJudgeModel: string;
                       AMaxIter: Integer;
                       AOnTurn: TGoalTurnFn);
    property OnProgress: TGoalProgressFn read FOnProgress write FOnProgress;
    function Run(const Goal: string;
                  var Hist: TMessageArray): TGoalResult;
  end;

const
  DefaultGoalMaxIter = 5;

{ Verdict parser exposed for unit tests. Returns the first verdict
  literal found in S (MET / CONTINUE / FAILED, case-insensitive);
  Reason is everything after the verdict trimmed of newlines.
  Defaults to gvAborted-equivalent of "no verdict found" -- the
  caller decides whether to retry, fail, or escalate.
  ParsedAny is True only when an explicit verdict literal was
  detected. }
function ParseJudgeVerdict(const S: string;
                            out Verdict: TGoalVerdict;
                            out Reason: string): Boolean;

implementation

uses
  StrUtils,
  PasClaw.Logger;

const
  { Built-in judge system prompt. Operators who want a different one
    can subclass TGoalRunner (or, in a follow-up, pass it via a
    constructor param). For v1 the goal is a sensible default that
    keeps the verdict tokens predictable so ParseJudgeVerdict stays
    simple. }
  JudgeSystemPrompt =
    'You are a goal-completion judge. You receive a goal and the ' +
    'assistant''s latest reply. Decide whether the goal is achieved.' + #10 +
    'Respond with EXACTLY one of these tokens on the FIRST line:' + #10 +
    '  MET       -- the assistant''s reply clearly satisfies the goal.' + #10 +
    '  CONTINUE  -- the goal is not yet met; suggest the next concrete step.' + #10 +
    '  FAILED    -- the goal cannot be achieved as stated; further turns will not help.' + #10 +
    'On the SECOND line, provide a one-sentence reason. For CONTINUE, ' +
    'that sentence is the next action the assistant should take and ' +
    'will be fed back to it verbatim.';

function UpperToken(const S: string): string;
{ Trim whitespace from S and return the leading "word" uppercased --
  enough to detect MET / CONTINUE / FAILED at the start of the
  judge's reply even if it adds punctuation. }
var
  i: Integer;
begin
  Result := '';
  i := 1;
  while (i <= Length(S)) and
        ((S[i] = ' ') or (S[i] = #9) or (S[i] = #13) or (S[i] = #10)) do
    Inc(i);
  while (i <= Length(S)) and
        (((S[i] >= 'A') and (S[i] <= 'Z')) or
         ((S[i] >= 'a') and (S[i] <= 'z'))) do
  begin
    Result := Result + S[i];
    Inc(i);
  end;
  Result := UpperCase(Result);
end;

function ParseJudgeVerdict(const S: string;
                            out Verdict: TGoalVerdict;
                            out Reason: string): Boolean;
var
  Token, Rest: string;
  NLPos: Integer;
begin
  Verdict := gvAborted;
  Reason  := '';
  Result  := False;
  Token := UpperToken(S);
  if Token = '' then Exit;
  if Token = 'MET' then
    Verdict := gvMet
  else if Token = 'CONTINUE' then
    Verdict := gvBudgetExhausted    // sentinel; caller overrides on success
  else if Token = 'FAILED' then
    Verdict := gvFailed
  else
    Exit;
  Result := True;

  { Reason is whatever follows the first newline OR what follows
    the verdict token on the same line if no newline exists. Both
    shapes are common in LLM output. }
  NLPos := Pos(#10, S);
  if NLPos > 0 then
    Rest := Trim(Copy(S, NLPos + 1, MaxInt))
  else
  begin
    Rest := Trim(S);
    if (Length(Rest) >= Length(Token)) and
       (UpperCase(Copy(Rest, 1, Length(Token))) = Token) then
      Rest := Trim(Copy(Rest, Length(Token) + 1, MaxInt));
  end;
  Reason := Rest;
end;

constructor TGoalRunner.Create(AProvider: ILLMProvider;
                                const AJudgeModel: string;
                                AMaxIter: Integer;
                                AOnTurn: TGoalTurnFn);
begin
  inherited Create;
  FProvider    := AProvider;
  FJudgeModel  := AJudgeModel;
  if AMaxIter <= 0 then
    FMaxIter := DefaultGoalMaxIter
  else
    FMaxIter := AMaxIter;
  FOnTurn      := AOnTurn;
  FJudgePrompt := JudgeSystemPrompt;
end;

function TGoalRunner.AskJudge(const Goal, AssistantReply: string;
                                out RawText, Reason: string;
                                out Verdict: TGoalVerdict): Boolean;
var
  Opts: TChatOptions;
  Msgs: TMessageArray;
  Tools: TToolDefinitionArray;
  Resp: TLLMResponse;
  ParsedVerdict: TGoalVerdict;
  Body: string;
begin
  Result := False;
  Verdict := gvAborted;
  Reason  := '';
  RawText := '';

  Opts := DefaultChatOptions;
  { PRIVACY: never let provider grounding fire for this call. Gemini's
    google_search is ON by default, and grounding works by having the
    model formulate search queries FROM ITS CONTEXT -- which here is the
    user's own content. Sending that to a search engine is the harm; a
    maintenance pass over text we already hold has no business searching
    the web at all. }
  Opts.DisableServerTools := True;
  Opts.SystemPrompt := FJudgePrompt;
  Opts.MaxTokens    := 256;       // judge replies are short by design

  SetLength(Msgs, 1);
  Body := 'GOAL: ' + Goal + #10#10 +
          'ASSISTANT REPLY: ' + AssistantReply;
  Msgs[0] := MakeMessage(mrUser, Body);

  SetLength(Tools, 0);
  try
    Resp := FProvider.Chat(Msgs, Tools, FJudgeModel, Opts);
  except
    on E: Exception do
    begin
      LogWarn('goals: judge call raised %s: %s', [E.ClassName, E.Message]);
      Exit;
    end;
  end;
  if (Resp.StatusCode <> 0) and
     ((Resp.StatusCode < 200) or (Resp.StatusCode >= 300)) then
  begin
    LogWarn('goals: judge returned status=%d', [Resp.StatusCode]);
    Exit;
  end;
  RawText := Resp.Content;
  if not ParseJudgeVerdict(RawText, ParsedVerdict, Reason) then
  begin
    { Judge produced something but it didn't carry an explicit
      verdict token. Default to CONTINUE so we don't stop prematurely
      -- but cap iterations applies; the runner still bounded. }
    Verdict := gvBudgetExhausted;   // sentinel reused as "treat as CONTINUE"
    Reason  := Trim(RawText);
    Result  := True;
    Exit;
  end;
  Verdict := ParsedVerdict;
  Result := True;
end;

function TGoalRunner.Run(const Goal: string;
                          var Hist: TMessageArray): TGoalResult;
var
  Iter: Integer;
  NextMsg, Reply, JudgeRaw, JudgeReason: string;
  JudgeVerdict: TGoalVerdict;
begin
  Result.Verdict    := gvAborted;
  Result.Iterations := 0;
  Result.LastReply  := '';
  Result.JudgeText  := '';
  Result.Reason     := '';

  if not Assigned(FOnTurn) then Exit;
  NextMsg := Goal;
  for Iter := 1 to FMaxIter do
  begin
    if not FOnTurn(NextMsg, Hist, Reply) then
    begin
      Result.Verdict    := gvAborted;
      Result.Iterations := Iter - 1;
      Exit;
    end;
    Result.Iterations := Iter;
    Result.LastReply  := Reply;

    if Assigned(FOnProgress) then FOnProgress(Iter, FMaxIter, Reply);

    if not AskJudge(Goal, Reply, JudgeRaw, JudgeReason, JudgeVerdict) then
    begin
      { Judge unreachable -- conservative behaviour is to keep
        iterating with a stock "continue" prompt so a flaky judge
        doesn't kill an otherwise-progressing loop. The budget
        still caps the total turns. }
      NextMsg := 'Continue working toward the goal.';
      Continue;
    end;

    Result.JudgeText := JudgeRaw;
    Result.Reason    := JudgeReason;

    if JudgeVerdict = gvMet then
    begin
      Result.Verdict := gvMet;
      Exit;
    end;
    if JudgeVerdict = gvFailed then
    begin
      Result.Verdict := gvFailed;
      Exit;
    end;
    { CONTINUE (or "no explicit verdict" -- both map to gvBudgetExhausted
      as the in-band sentinel from AskJudge). Feed the judge's
      suggested next step back to the assistant. Fall back to a
      generic continuation if the reason came up empty. }
    if Trim(JudgeReason) <> '' then
      NextMsg := JudgeReason
    else
      NextMsg := 'Continue working toward the goal.';
  end;
  { Loop ran to MaxIter without MET/FAILED. }
  Result.Verdict := gvBudgetExhausted;
end;

end.
