program tool_cancel_tests;
(*
  Cooperative cancellation in RunToolLoop -- the thing that makes an
  operator's "pause" an actual stop.

  Before this, pausing pushed a note into every busy agent's steering
  queue and hoped. That works on an agent that keeps calling tools, and
  does nothing at all for the one case a stop button exists for: a turn
  grinding through its whole iteration budget. Cfg.ShouldCancel is asked
  at two points where the turn's state is consistent, and the loop
  leaves at the next one.

  What is asserted here is that it STOPS -- not merely that a flag comes
  back set. Each cancelling case runs against a provider that never
  answers (every round is another tool call) with a generous iteration
  cap, and counts how many times the provider was actually called. A
  loop that ignored the hook would call it MaxIterations times and come
  back with HitMaxIterations; the control case at the end does exactly
  that, so the difference is pinned rather than assumed.

  No network, no keys: the provider is a small ILLMProvider in this file.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Agent.Mode,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop;

const
  { Deliberately larger than any cancelling case should reach. A stop
    that happened to coincide with the cap would prove nothing. }
  CAP = 12;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want]));
end;

function Has(const Hay, Needle: string): Boolean;
begin Result := Pos(Needle, Hay) > 0; end;

(* ----- A provider that never finishes. Every round asks for the same
   tool again, so the loop only ever stops because something stopped it:
   the cancel hook, or the iteration cap. Counts its calls -- that count
   IS the evidence the loop went no further. ----- *)
type
  TNeverDoneProvider = class(TInterfacedObject, ILLMProvider)
  private
    FCalls: Integer;
  public
    property Calls: Integer read FCalls;
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TNeverDoneProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TNeverDoneProvider.GetName: string;         begin Result := 'fake'; end;
function TNeverDoneProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TNeverDoneProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TNeverDoneProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TNeverDoneProvider.Chat(const Messages: array of TMessage;
                                 const Tools: array of TToolDefinition;
                                 const Model: string;
                                 const Options: TChatOptions): TLLMResponse;
begin
  Inc(FCalls);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Result.Content    := 'thinking';
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0].Id             := 'c' + IntToStr(FCalls);
  Result.ToolCalls[0].Kind           := 'function';
  Result.ToolCalls[0].Func.Name      := 'fake_note';
  Result.ToolCalls[0].Func.Arguments := '{}';
  Result.FinishReason := 'tool_calls';
end;

function TNeverDoneProvider.ChatStream(const Messages: array of TMessage;
                                       const Tools: array of TToolDefinition;
                                       const Model: string;
                                       const Options: TChatOptions;
                                       OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

(* ----- And one that just answers. ----- *)
type
  TAnswersProvider = class(TInterfacedObject, ILLMProvider)
  public
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TAnswersProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TAnswersProvider.GetName: string;         begin Result := 'fake'; end;
function TAnswersProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TAnswersProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TAnswersProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TAnswersProvider.Chat(const Messages: array of TMessage;
                               const Tools: array of TToolDefinition;
                               const Model: string;
                               const Options: TChatOptions): TLLMResponse;
begin
  Result := Default(TLLMResponse);
  Result.StatusCode   := 200;
  Result.Content      := 'all done';
  Result.FinishReason := 'stop';
end;

function TAnswersProvider.ChatStream(const Messages: array of TMessage;
                                     const Tools: array of TToolDefinition;
                                     const Model: string;
                                     const Options: TChatOptions;
                                     OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

(* ----- The operator, scripted. Answers False for the first TripAfter
   asks and True from then on, so a test can place the stop at whichever
   boundary it wants to prove. Counts asks, because "was it even asked"
   is a different failure from "it was asked and ignored". ----- *)
type
  TScriptedBrake = class
  private
    FAsked: Integer;
    FTripAfter: Integer;
  public
    constructor Create(ATripAfter: Integer);
    function Cancel: Boolean;
    property Asked: Integer read FAsked;
  end;

constructor TScriptedBrake.Create(ATripAfter: Integer);
begin
  inherited Create;
  FTripAfter := ATripAfter;
end;

function TScriptedBrake.Cancel: Boolean;
begin
  Result := FAsked >= FTripAfter;
  Inc(FAsked);
end;

var
  GToolRuns: Integer = 0;

function HandleFakeNote(const A: string; out E: string): string;
begin
  E := '';
  Inc(GToolRuns);
  Result := 'noted';
end;

function MakeRegistry: TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  T := Default(TTool);
  T.Name        := 'fake_note';
  T.Description := 'write a note';
  T.Schema      := '{"type":"object"}';
  T.Handler     := HandleFakeNote;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcReadOnly;
  Result.Register(T);
end;

function BaseConfig(Reg: TToolRegistry; Prov: ILLMProvider): TToolLoopConfig;
begin
  Result := Default(TToolLoopConfig);
  Result.Provider      := Prov;
  Result.Registry      := Reg;
  Result.Model         := 'fake';
  Result.MaxIterations := CAP;
  Result.Mode          := pmBuild;
end;

(* Boundary 1: the brake is already on when the turn starts.

   The assertion that matters is Prov.Calls = 0. A loop that checked the
   flag anywhere later would still report Cancelled, and would still
   have spent a provider call to do it. *)
procedure TestCancelBeforeFirstCall;
var
  Reg: TToolRegistry;
  Prov: TNeverDoneProvider;
  IProv: ILLMProvider;
  Brake: TScriptedBrake;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
begin
  Reg := MakeRegistry;
  Prov := TNeverDoneProvider.Create;
  IProv := Prov;
  Brake := TScriptedBrake.Create(0);   { on from the very first ask }
  try
    GToolRuns := 0;
    Cfg := BaseConfig(Reg, IProv);
    Cfg.ShouldCancel := Brake.Cancel;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'start something long');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop),
      'a cancelled loop is a successful call, not a failed one -- the ' +
      'caller still has a transcript to persist');
    AssertTrue(Loop.Cancelled, 'it says it was cancelled');
    AssertTrue(not Loop.HitMaxIterations,
      'and NOT that it ran out of iterations -- those mean opposite ' +
      'things to whoever reads the notice');
    AssertEqS(Loop.CancelledAt, 'before the model call', 'it says where');
    AssertEqI(Prov.Calls, 0, 'the provider was never called');
    AssertEqI(GToolRuns, 0, 'and no tool ran');
    AssertEqI(Loop.Iterations, 0, 'no iteration completed');
    AssertEqI(Brake.Asked, 1, 'asked exactly once, at the one boundary reached');
  finally
    Brake.Free;
    Reg.Free;
  end;
end;

(* Boundary 2: the brake comes on while the first round's tool is
   running. The round finishes -- results land in history -- and the
   loop leaves instead of starting round two.

   This is the case the feature exists for: the expensive thing a
   runaway turn does is start ANOTHER round after its tools come back. *)
procedure TestCancelAfterToolBatch;
var
  Reg: TToolRegistry;
  Prov: TNeverDoneProvider;
  IProv: ILLMProvider;
  Brake: TScriptedBrake;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
  i: Integer;
  SawToolResult: Boolean;
begin
  Reg := MakeRegistry;
  Prov := TNeverDoneProvider.Create;
  IProv := Prov;
  { Ask 0 is boundary 1 of iteration 1 (False -> the round runs); ask 1
    is boundary 2 of that same iteration (True -> stop). }
  Brake := TScriptedBrake.Create(1);
  try
    GToolRuns := 0;
    Cfg := BaseConfig(Reg, IProv);
    Cfg.ShouldCancel := Brake.Cancel;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'start something long');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop succeeds');
    AssertTrue(Loop.Cancelled, 'cancelled');
    AssertTrue(not Loop.HitMaxIterations, 'not a cap stop');
    AssertEqS(Loop.CancelledAt, 'after 1 tool call(s)', 'it says where');
    AssertEqI(Prov.Calls, 1, 'exactly one provider round happened');
    AssertEqI(GToolRuns, 1, 'its tool ran to completion -- not killed mid-way');
    AssertEqI(Loop.Iterations, 1, 'one iteration completed');

    { The point of stopping at a boundary rather than aborting: what the
      turn did is still in the history, so the caller persists real work
      instead of losing it. }
    SawToolResult := False;
    for i := 0 to High(Loop.FinalMessages) do
      if (Loop.FinalMessages[i].Role = mrTool) and
         (Loop.FinalMessages[i].Content = 'noted') then
        SawToolResult := True;
    AssertTrue(SawToolResult,
      'the tool result is in FinalMessages -- a stop must not throw away ' +
      'the work it is stopping');
    AssertTrue(Loop.LedgerSummary <> '',
      'and the progress ledger came back, so a resumed turn does not redo it');
  finally
    Brake.Free;
    Reg.Free;
  end;
end;

(* The control. Same provider, same cap, no hook at all: the loop runs
   the whole budget and reports the cap.

   Without this the cancelling cases above prove nothing -- a loop that
   stopped after one round for some unrelated reason would pass them
   both. *)
procedure TestNoHookRunsToTheCap;
var
  Reg: TToolRegistry;
  Prov: TNeverDoneProvider;
  IProv: ILLMProvider;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
begin
  Reg := MakeRegistry;
  Prov := TNeverDoneProvider.Create;
  IProv := Prov;
  try
    GToolRuns := 0;
    Cfg := BaseConfig(Reg, IProv);
    { ShouldCancel deliberately unassigned. }
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'start something long');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop succeeds');
    AssertTrue(not Loop.Cancelled, 'nothing cancelled it');
    AssertTrue(Loop.HitMaxIterations, 'it hit the cap instead');
    AssertEqI(Prov.Calls, CAP, 'and it burned the whole budget getting there');
    AssertEqI(GToolRuns, CAP, 'running its tool every round');
  finally
    Reg.Free;
  end;
end;

(* A brake that is asked and always says no must cost nothing. *)
procedure TestBrakeSayingNoChangesNothing;
var
  Reg: TToolRegistry;
  Prov: TNeverDoneProvider;
  IProv: ILLMProvider;
  Brake: TScriptedBrake;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
begin
  Reg := MakeRegistry;
  Prov := TNeverDoneProvider.Create;
  IProv := Prov;
  Brake := TScriptedBrake.Create(MaxInt);   { never trips }
  try
    Cfg := BaseConfig(Reg, IProv);
    Cfg.ShouldCancel := Brake.Cancel;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'start something long');

    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'loop succeeds');
    AssertTrue(not Loop.Cancelled, 'a brake that says no does not stop it');
    AssertTrue(Loop.HitMaxIterations, 'it reaches the cap exactly as before');
    AssertEqI(Prov.Calls, CAP, 'full budget spent');
    { Two boundaries an iteration, every iteration. }
    AssertEqI(Brake.Asked, CAP * 2, 'asked at both boundaries of every round');
  finally
    Brake.Free;
    Reg.Free;
  end;
end;

(* The operator-facing notice. Separate from the max-iteration one on
   purpose: telling someone who just hit pause to "raise the limit"
   would send them looking for a problem that is not there. *)
procedure TestNotice;
var
  Loop: TToolLoopResult;
  S: string;
begin
  Loop := Default(TToolLoopResult);
  Loop.Cancelled := False;
  AssertEqS(FormatCancelledNotice(Loop, 'lunch', 'resume'), '',
    'no notice on a loop nobody stopped -- callers append it unconditionally');

  Loop := Default(TToolLoopResult);
  Loop.Cancelled     := True;
  Loop.CancelledAt   := 'after 3 tool call(s)';
  Loop.LedgerSummary := 'wrote app.py';
  S := FormatCancelledNotice(Loop, 'deploying',
                             '`pasclaw team resume`');
  AssertTrue(Has(S, 'stopped by the operator'), 'it says who stopped it');
  AssertTrue(Has(S, 'deploying'),               'and why, when there is a reason');
  AssertTrue(Has(S, 'after 3 tool call(s)'),    'and where it stopped');
  AssertTrue(Has(S, 'wrote app.py'),            'and what was already done');
  AssertTrue(Has(S, 'do NOT redo'),
    'with the instruction that makes the ledger useful on a resume');
  AssertTrue(Has(S, '`pasclaw team resume`'),   'and how to start again');
  AssertTrue(not Has(S, 'limit'),
    'and NOT a word about limits -- this stop was on purpose');

  { A stop with no stated reason still reads as a sentence. }
  Loop := Default(TToolLoopResult);
  Loop.Cancelled   := True;
  Loop.CancelledAt := 'before the model call';
  S := FormatCancelledNotice(Loop, '', '');
  AssertTrue(Has(S, '[stopped by the operator]'), 'no reason, no dangling colon');
  AssertTrue(Has(S, 'before the model call'),     'still says where');
  AssertTrue(not Has(S, 'Pick it up again'),
    'and no resume hint when the caller did not give one');
end;

(* One turn's verdict must not leak into the next one's.

   TToolLoopResult is an `out` parameter, which finalises the managed
   fields and leaves everything else holding whatever the caller's
   variable held -- and callers reuse ONE variable for every turn. The
   loop used to clear its result field by field, and the list did not
   include HitMaxIterations, which nothing on a normal turn clears
   either. So a session where one turn ran out of iterations printed
   "stopped at the tool-call limit -- reply continue" on every turn
   after it, however cleanly they finished.

   Found writing the cancellation cases above: Cancelled came back True
   on a loop nothing had cancelled. The fix clears the whole record, so
   this pins the property rather than the two fields that happened to
   expose it. *)
procedure TestResultDoesNotLeakBetweenTurns;
var
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;    { ONE result, two turns -- the whole point }
  Msgs: array of TMessage;
begin
  Reg := MakeRegistry;
  try
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go');

    { Turn one runs out of road. }
    Cfg := BaseConfig(Reg, TNeverDoneProvider.Create);
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'first turn runs');
    AssertTrue(Loop.HitMaxIterations, 'and hits the cap, as designed');

    { Turn two answers on the first try, through the same variable. }
    Cfg := BaseConfig(Reg, TAnswersProvider.Create);
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go again');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'second turn runs');
    AssertEqS(Loop.Content, 'all done', 'and answers');
    AssertTrue(not Loop.HitMaxIterations,
      'a clean turn does not inherit the last turn''s cap');
    AssertTrue(not Loop.Cancelled, 'nor a stale cancellation');
    AssertEqS(Loop.CancelledAt, '', 'nor where a previous turn stopped');
    AssertEqI(Length(Loop.PendingToolNames), 0,
      'nor what a previous turn was mid-way through');
    AssertEqS(Loop.LedgerSummary, '',
      'nor a previous turn''s work, which on a resume would be told ' +
      '"do NOT redo" about things this turn never did');
  finally
    Reg.Free;
  end;
end;

begin
  TestCancelBeforeFirstCall;
  TestCancelAfterToolBatch;
  TestNoHookRunsToTheCap;
  TestBrakeSayingNoChangesNothing;
  TestResultDoesNotLeakBetweenTurns;
  TestNotice;
  WriteLn('PASS: tool_cancel_tests');
end.
