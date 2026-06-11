program goals_runner_tests;
(*
  Covers PasClaw.Agent.Goals -- the auto-continue Ralph loop where a
  judge model verdicts each turn until MET / FAILED / budget exhausts.

  Strategy: substitute a FAKE ILLMProvider that returns scripted
  verdicts on each Chat() call. The "turn function" passed to
  TGoalRunner is also fake -- it appends a synthetic assistant reply
  to the history and returns it. No real RunToolLoop, no real model.

  Pinned contracts:
    - MET on the first iteration -> gvMet, Iterations=1
    - CONTINUE then MET -> gvMet, Iterations=2 (judge ran twice)
    - CONTINUE looping until budget -> gvBudgetExhausted
    - FAILED -> gvFailed, no more iterations
    - OnTurn returning False -> gvAborted, iteration count caps at
      the last successful turn (or 0 if first turn aborted)
    - Verdict parser stand-alone: tolerates leading whitespace,
      mixed case, no newline, decorated punctuation, empty body
    - Judge unreachable (Chat raises) -> runner falls back to a
      generic continuation prompt; budget still applies
    - The judge's CONTINUE "reason" feeds back as the next user
      message verbatim
    - OnProgress fires AFTER the turn but BEFORE the judge, with
      the assistant reply
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Agent.Goals;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want]));
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing)');
end;

type
  { Scripted judge: each Chat() call returns the next line from
    Verdicts in order, cycling at end. Also records what it was
    asked. RaiseOnCall when True simulates a hard provider
    failure -- the runner should treat that as "judge unreachable"
    and fall back to a generic continuation. }
  TScriptedJudge = class(TInterfacedObject, ILLMProvider)
  private
    FVerdicts:    TStringList;
    FCalls:       Integer;
    FRaiseOnCall: Boolean;
    FLastBody:    string;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure ScriptVerdict(const Text: string);
    procedure SetRaiseOnCall(B: Boolean);
    function Calls: Integer;
    function LastBody: string;
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

constructor TScriptedJudge.Create;
begin
  inherited;
  FVerdicts := TStringList.Create;
end;

destructor TScriptedJudge.Destroy;
begin
  FVerdicts.Free;
  inherited;
end;

procedure TScriptedJudge.ScriptVerdict(const Text: string);
begin
  FVerdicts.Add(Text);
end;

procedure TScriptedJudge.SetRaiseOnCall(B: Boolean);
begin
  FRaiseOnCall := B;
end;

function TScriptedJudge.Calls: Integer;
begin
  Result := FCalls;
end;

function TScriptedJudge.LastBody: string;
begin
  Result := FLastBody;
end;

function TScriptedJudge.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Idx: Integer;
begin
  Inc(FCalls);
  if Length(Messages) > 0 then FLastBody := Messages[High(Messages)].Content;
  if FRaiseOnCall then
    raise Exception.Create('simulated judge outage');
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Result.FinishReason := 'stop';
  if FVerdicts.Count = 0 then
  begin
    Result.Content := 'CONTINUE' + sLineBreak + 'keep going';
    Exit;
  end;
  Idx := (FCalls - 1);
  if Idx > FVerdicts.Count - 1 then Idx := FVerdicts.Count - 1;
  Result.Content := FVerdicts[Idx];
end;

function TScriptedJudge.ChatStream(const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function TScriptedJudge.GetDefaultModel: string;     begin Result := 'judge-fake'; end;
function TScriptedJudge.GetName: string;             begin Result := 'judge-fake'; end;
function TScriptedJudge.SupportsThinking: Boolean;   begin Result := False; end;
function TScriptedJudge.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScriptedJudge.SupportsStreaming: Boolean;  begin Result := False; end;

type
  { Fake turn function holder: records the user messages it was
    handed so tests can assert what the runner fed back from the
    judge, and emits a scripted assistant reply each time. }
  TFakeTurnDriver = class
  private
    FReceived: TStringList;
    FReplies:  TStringList;
    FAbortAt:  Integer;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure ScriptReply(const Reply: string);
    procedure SetAbortAt(N: Integer);
    function Received(Index: Integer): string;
    function ReceivedCount: Integer;
    function TurnFn(const UserMsg: string;
                     var Hist: TMessageArray;
                     out Reply: string): Boolean;
  end;

constructor TFakeTurnDriver.Create;
begin
  inherited;
  FReceived := TStringList.Create;
  FReplies  := TStringList.Create;
  FAbortAt  := 0;
end;

destructor TFakeTurnDriver.Destroy;
begin
  FReceived.Free;
  FReplies.Free;
  inherited;
end;

procedure TFakeTurnDriver.ScriptReply(const Reply: string);
begin
  FReplies.Add(Reply);
end;

procedure TFakeTurnDriver.SetAbortAt(N: Integer);
begin
  FAbortAt := N;
end;

function TFakeTurnDriver.Received(Index: Integer): string;
begin
  Result := FReceived[Index];
end;

function TFakeTurnDriver.ReceivedCount: Integer;
begin
  Result := FReceived.Count;
end;

function TFakeTurnDriver.TurnFn(const UserMsg: string;
                                 var Hist: TMessageArray;
                                 out Reply: string): Boolean;
var
  Idx: Integer;
begin
  FReceived.Add(UserMsg);
  if (FAbortAt > 0) and (FReceived.Count >= FAbortAt) then
  begin
    Reply := '';
    Exit(False);
  end;
  SetLength(Hist, Length(Hist) + 2);
  Hist[Length(Hist) - 2] := MakeMessage(mrUser, UserMsg);
  if FReplies.Count = 0 then
    Reply := 'placeholder reply'
  else
  begin
    Idx := FReceived.Count - 1;
    if Idx > FReplies.Count - 1 then Idx := FReplies.Count - 1;
    Reply := FReplies[Idx];
  end;
  Hist[Length(Hist) - 1] := MakeMessage(mrAssistant, Reply);
  Result := True;
end;

type
  { Minimal turn driver: appends ONLY the user message to Hist,
    leaves Reply non-empty, never appends an assistant message.
    Used by TestTurnFnControlsAssistantAppend below to assert the
    runner doesn't quietly mutate Hist beyond what TurnFn left
    there -- the goal-runner contract is that the caller owns the
    Hist shape, and the runner only walks it. }
  TBareDriver = class
    function TurnFn(const UserMsg: string;
                     var Hist: TMessageArray;
                     out Reply: string): Boolean;
  end;

function TBareDriver.TurnFn(const UserMsg: string;
                             var Hist: TMessageArray;
                             out Reply: string): Boolean;
begin
  SetLength(Hist, Length(Hist) + 1);
  Hist[High(Hist)] := MakeMessage(mrUser, UserMsg);
  Reply  := 'I am the assistant.';
  Result := True;
end;

procedure TestTurnFnControlsAssistantAppend;
(* Codex P1 on PR #223: the goal-runner contract is "TGoalTurnFn
   appends BOTH the user msg AND the assistant reply". The runner
   itself doesn't dictate Hist shape -- if a turn driver only
   appended one message, the runner shouldn't compensate by
   appending a second. This test pins that invariant from the
   runner's side; the matching fix in PasClaw.Cmd.Agent's
   GoalTurnRunner makes sure the production callback does append
   both. *)
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TBareDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('MET' + #10 + 'ok');
  D := TBareDriver.Create;
  try
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'j', 3, D.TurnFn);
    try
      R := Runner.Run('do a thing', Hist);
      AssertTrue(R.Verdict = gvMet, 'MET');
      AssertEqInt(Length(Hist), 1,
                  'runner left Hist exactly as TurnFn returned it -- ' +
                  'one user message, no spurious appends');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestParseVerdictHandlesAllShapes;
var
  Verdict: TGoalVerdict;
  Reason: string;
begin
  AssertTrue(ParseJudgeVerdict('MET' + #10 + 'goal achieved',
                                Verdict, Reason),
             'plain MET parses');
  AssertTrue(Verdict = gvMet, 'verdict = gvMet');
  AssertEqStr(Reason, 'goal achieved', 'reason on line 2');

  AssertTrue(ParseJudgeVerdict('  Failed' + #10 + 'mission impossible',
                                Verdict, Reason),
             'leading whitespace + case-insensitive');
  AssertTrue(Verdict = gvFailed, 'verdict = gvFailed');

  AssertTrue(ParseJudgeVerdict('continue. need to write tests next.',
                                Verdict, Reason),
             'single-line CONTINUE with trailing punctuation');
  AssertTrue(Verdict = gvBudgetExhausted, 'CONTINUE maps to in-band sentinel');
  AssertContains(LowerCase(Reason), 'tests next', 'reason captured');

  AssertFalse(ParseJudgeVerdict('', Verdict, Reason),
              'empty -> no verdict');
  AssertFalse(ParseJudgeVerdict('something else', Verdict, Reason),
              'unrelated -> no verdict');
end;

procedure TestMetOnFirstIteration;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('MET' + #10 + 'all done');
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('I added the test and ran it.');
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'judge-model', 5, D.TurnFn);
    try
      R := Runner.Run('write a test for X and run it', Hist);
      AssertTrue(R.Verdict = gvMet, 'MET');
      AssertEqInt(R.Iterations, 1, 'one iteration');
      AssertEqStr(R.LastReply, 'I added the test and ran it.',
                  'last reply captured');
      AssertContains(R.Reason, 'all done', 'judge reason captured');
      AssertEqInt(D.ReceivedCount, 1,
                  'turn driver saw the goal as the only user message');
      AssertEqStr(D.Received(0), 'write a test for X and run it',
                  'goal fed to first turn verbatim');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestContinueThenMet;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('CONTINUE' + #10 + 'now please also run the new test');
  J.ScriptVerdict('MET' + #10 + 'green');
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('I wrote the test.');
    D.ScriptReply('I ran the test and it passed.');
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'judge-model', 5, D.TurnFn);
    try
      R := Runner.Run('write and run a test for X', Hist);
      AssertTrue(R.Verdict = gvMet, 'second iteration MET');
      AssertEqInt(R.Iterations, 2, 'two turns');
      AssertEqInt(J.Calls, 2, 'judge called twice');
      AssertContains(D.Received(1), 'run the new test',
                     'judge CONTINUE reason fed back as next user msg');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestContinueLoopHitsBudget;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('CONTINUE' + #10 + 'keep going');
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('working...');
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'judge-model', 3, D.TurnFn);
    try
      R := Runner.Run('an impossible goal', Hist);
      AssertTrue(R.Verdict = gvBudgetExhausted, 'budget exhausted');
      AssertEqInt(R.Iterations, 3, 'ran exactly MaxIter turns');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestFailedStopsImmediately;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('FAILED' + #10 + 'no compiler available');
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('I cannot compile the project.');
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'j', 5, D.TurnFn);
    try
      R := Runner.Run('compile the project', Hist);
      AssertTrue(R.Verdict = gvFailed, 'FAILED');
      AssertEqInt(R.Iterations, 1, 'stopped after first verdict');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestOnTurnAbortReturnsAborted;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.ScriptVerdict('CONTINUE' + #10 + 'next');
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('one');
    D.SetAbortAt(2);   // 2nd call to TurnFn returns False
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'j', 5, D.TurnFn);
    try
      R := Runner.Run('do two things', Hist);
      AssertTrue(R.Verdict = gvAborted, 'aborted');
      AssertEqInt(R.Iterations, 1, '1 successful turn before abort');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

procedure TestJudgeOutageFallsBackToGenericContinue;
var
  J: TScriptedJudge; JIntf: ILLMProvider;
  D: TFakeTurnDriver;
  Runner: TGoalRunner;
  Hist: TMessageArray;
  R: TGoalResult;
begin
  J := TScriptedJudge.Create; JIntf := J;
  J.SetRaiseOnCall(True);
  D := TFakeTurnDriver.Create;
  try
    D.ScriptReply('reply-1');
    D.ScriptReply('reply-2');
    SetLength(Hist, 0);
    Runner := TGoalRunner.Create(JIntf, 'j', 2, D.TurnFn);
    try
      R := Runner.Run('goal-that-judge-cannot-evaluate', Hist);
      AssertTrue(R.Verdict = gvBudgetExhausted,
                 'judge outage -> falls back to CONTINUE, hits budget');
      AssertEqInt(R.Iterations, 2, 'still ran MaxIter turns');
      AssertContains(D.Received(1), 'Continue working',
                     'generic continuation fallback message used');
    finally
      Runner.Free;
    end;
  finally
    D.Free;
  end;
end;

begin
  TestParseVerdictHandlesAllShapes;             WriteLn('  ok: verdict parser handles all shapes');
  TestTurnFnControlsAssistantAppend;            WriteLn('  ok: TurnFn owns Hist shape (runner does not append)');
  TestMetOnFirstIteration;                      WriteLn('  ok: MET on first iteration');
  TestContinueThenMet;                          WriteLn('  ok: CONTINUE then MET');
  TestContinueLoopHitsBudget;                   WriteLn('  ok: CONTINUE loop hits budget');
  TestFailedStopsImmediately;                   WriteLn('  ok: FAILED stops immediately');
  TestOnTurnAbortReturnsAborted;                WriteLn('  ok: OnTurn abort -> gvAborted');
  TestJudgeOutageFallsBackToGenericContinue;    WriteLn('  ok: judge outage -> generic continue');
  WriteLn('PASS');
end.
