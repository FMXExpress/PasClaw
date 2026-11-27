program advisor_tests;
(*
  The advisor (PasClaw.Agent.Advisor) and the tool loop's turn accessor it
  reads the conversation through (CurrentDispatchHistory / BumpTurnCounter).

  Coverage:
    - config: the "advisor" block parses, keeps its defaults when keys are
      missing, and round-trips through ToJSON / FromJSON; a stock config
      writes provider and model (so the web UI's Settings form shows them)
      but not the two limits;
    - --advisor / /advisor specs: provider:model splits only on a
      configured provider name, model ids keep their own colons, and an
      empty model is refused; ParseAdvisorFlags reads the two flags;
    - the tool is listed exactly while an advisor model is set: absent with
      none, present with one, gone after /advisor off, back after on, and
      a new model from /advisor provider:model; --no-advisor wins;
    - it is read-only and not serial-only, so calls batch in parallel;
    - the transcript: roles and tool names, system messages left out, the
      oldest part cut with a note saying how much, the user's latest
      message kept, one long result cut in the middle, and never a split
      UTF-8 character;
    - the request: one user message, the transcript first, the question last;
    - the turn accessor, through a real RunToolLoop with parallel dispatch:
      each call sees the history up to its own assistant message, parallel
      calls count once each, the next loop starts again at 1, and outside a
      loop -- or through the script dispatcher -- there is no turn;
    - the cap, through the real handler: with max_calls_per_turn 1 the
      second call in a turn is refused before any provider is asked (the
      first goes to a provider that is not there);
    - subagents: a '*' tool list (the general-purpose subagent) inherits the
      advisor, a configured list gets it by naming it, and with no advisor
      set they have none;
    - the stats bucket id is a hidden, safe, collision-resistant session id.

  The live request to an advisor model is in advisor_e2e.py, against a fake
  provider; nothing here touches the network beyond one refused connect.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}   { the loop's parallel batch runs worker threads }
  SysUtils, Classes, SyncObjs,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Agent.Mode,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Session.Store,
  PasClaw.Agent.Subagent,   { BuildFilteredRegistry -- what a subagent inherits }
  PasClaw.Agent.Advisor;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Failures); end;
end;

function Has(const S, Sub: string): Boolean;
begin
  Result := Pos(Sub, S) > 0;
end;

function ToolListed(Reg: TToolRegistry; const Name: string): Boolean;
var
  Defs: TToolDefinitionArray;
  i: Integer;
begin
  Defs := Reg.ToProviderDefs;
  for i := 0 to High(Defs) do
    if Defs[i].Name = Name then Exit(True);
  Result := False;
end;

function Call(const Id, Name, Args: string): TToolCall;
begin
  Result := Default(TToolCall);
  Result.Id := Id;
  Result.Kind := 'function';
  Result.Func.Name := Name;
  Result.Func.Arguments := Args;
end;

function AsstCalls(const Content: string; const Calls: array of TToolCall): TMessage;
var
  i: Integer;
begin
  Result := MakeMessage(mrAssistant, Content);
  SetLength(Result.ToolCalls, Length(Calls));
  for i := 0 to High(Calls) do Result.ToolCalls[i] := Calls[i];
end;

function ToolResult(const Id, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := Id;
end;

procedure Push(var H: TMessageArray; const M: TMessage);
begin
  SetLength(H, Length(H) + 1);
  H[High(H)] := M;
end;

function ValidUtf8(const S: string): Boolean;
var
  B: TBytes;
  i: Integer;
begin
  SetLength(B, Length(S));
  for i := 1 to Length(S) do B[i - 1] := Byte(S[i]);
  Result := BytesAreValidUTF8(B);
end;

function NewCfg: TConfig;
begin
  Result := TConfig.Create;
  SetLength(Result.Providers, 2);
  Result.Providers[0].Name := 'main';
  Result.Providers[0].Kind := 'openai';
  Result.Providers[0].APIKey := 'sk-test';
  Result.Providers[1].Name := 'adv';
  Result.Providers[1].Kind := 'openai';
  Result.Providers[1].APIKey := 'sk-test';
  { Nothing listens on port 1: a call that gets as far as the provider
    fails at once with a refused connect. }
  Result.Providers[1].APIBase := 'http://127.0.0.1:1';
  Result.DefaultProvider := 'main';
  Result.StatsCollectionEnabled := False;
end;

{ ------------------------------------------------------------------ config }

procedure TestConfig;
var
  C, D: TConfig;
  J: string;
begin
  WriteLn('config');
  C := TConfig.Create;
  try
    Check((C.Advisor.Model = '') and (C.Advisor.Provider = ''), 'default: no advisor');
    Check((C.Advisor.MaxCallsPerTurn = 3) and (C.Advisor.MaxContextChars = 60000),
          'default limits 3 calls, 60000 characters');
    J := C.ToJSON;
    Check(Has(J, '"advisor"') and Has(J, '"model"'), 'stock config writes the advisor block');
    Check(not Has(J, 'max_calls_per_turn') and not Has(J, 'max_context_chars'),
          'stock config does not pin the default limits');
    C.FromJSON('{"advisor":{"model":"m1"}}');
    Check((C.Advisor.Model = 'm1') and (C.Advisor.Provider = '') and
          (C.Advisor.MaxCallsPerTurn = 3), 'partial block keeps the other defaults');
    C.FromJSON('{"advisor":{"provider":"adv","model":"m2","max_calls_per_turn":5,' +
               '"max_context_chars":9000}}');
    J := C.ToJSON;
    D := TConfig.Create;
    try
      D.FromJSON(J);
      Check((D.Advisor.Provider = 'adv') and (D.Advisor.Model = 'm2') and
            (D.Advisor.MaxCallsPerTurn = 5) and (D.Advisor.MaxContextChars = 9000),
            'round-trip keeps provider, model and both limits');
    finally
      D.Free;
    end;
  finally
    C.Free;
  end;
end;

{ ------------------------------------------------------------------- specs }

procedure TestSpecs;
var
  P, M, Spec, Err: string;
  Off: Boolean;
begin
  WriteLn('specs and flags');
  Check(SplitAdvisorSpec('adv:m1', ['main', 'adv'], P, M) and (P = 'adv') and (M = 'm1'),
        'provider:model splits on a configured provider');
  Check(SplitAdvisorSpec('ADV:m1', ['main', 'adv'], P, M) and (P = 'adv'),
        'provider match ignores case and returns the configured spelling');
  Check(SplitAdvisorSpec('llama3:8b', ['main', 'adv'], P, M) and (P = '') and (M = 'llama3:8b'),
        'a model id with its own colon stays whole');
  Check(SplitAdvisorSpec('adv:org/model:free', ['adv'], P, M) and (P = 'adv') and
        (M = 'org/model:free'), 'only the first colon splits');
  Check(SplitAdvisorSpec('m1', ['adv'], P, M) and (P = '') and (M = 'm1'), 'bare model');
  Check(not SplitAdvisorSpec('adv:', ['adv'], P, M), 'provider with no model is refused');
  Check(not SplitAdvisorSpec('  ', ['adv'], P, M), 'empty spec is refused');

  Check(ParseAdvisorFlags(['--port', '1', '--advisor', 'adv:x', '--no-advisor'], Spec, Off, Err)
        and (Spec = 'adv:x') and Off, 'ParseAdvisorFlags reads both flags among others');
  Check(not ParseAdvisorFlags(['--advisor'], Spec, Off, Err) and Has(Err, '--advisor needs a model'),
        '--advisor with no value is refused');
  Check(not ParseAdvisorFlags(['--advisor', '--no-mcp'], Spec, Off, Err),
        '--advisor followed by another flag is refused');
end;

{ ---------------------------------------------------------- presence, /advisor }

procedure TestPresence;
var
  Cfg: TConfig;
  Reg: TToolRegistry;
  T: TTool;
  S: TAdvisorSettings;
  Err, Out_: string;
  Calls: array[0..2] of TToolCall;
  Batches: TToolBatchArray;
begin
  WriteLn('tool presence and /advisor');
  Cfg := NewCfg;
  Reg := TToolRegistry.Create;
  try
    ResetAdvisor;
    RegisterAdvisorTool(Reg, Cfg);
    Check(not ToolListed(Reg, 'advisor') and not Reg.Find('advisor', T),
          'no advisor model: the tool is absent');
    Check(Has(AdvisorStatus, 'off -- no model set'), 'status says why it is off');

    Cfg.Advisor.Provider := 'adv';
    Cfg.Advisor.Model := 'm1';
    Check(ApplyAdvisorFlags(Cfg, '', False, Err), 'seed from config');
    Check(ToolListed(Reg, 'advisor'), 'advisor.model set: the tool is listed');
    Check(Reg.Find('advisor', T) and (T.Category = tcReadOnly) and not T.SerialOnly,
          'read-only and not serial-only (plan mode and parallel batches)');
    Calls[0] := Call('a', 'advisor', '{}');
    Calls[1] := Call('b', 'advisor', '{}');
    Calls[2] := Call('c', 'advisor', '{}');
    Batches := PartitionToolBatches(Calls, Reg);
    Check((Length(Batches) = 1) and (Length(Batches[0]) = 3), 'three calls share one parallel batch');
    Check(Has(AdvisorStatus, 'm1 on adv (from config.json)'), 'status names model, provider, source');

    Out_ := AdvisorCommand('off');
    Check(Has(Out_, 'off for this session') and not ToolListed(Reg, 'advisor'),
          '/advisor off: the tool leaves the list');
    Check(Has(AdvisorCommand(''), '/advisor on brings back m1'), 'bare /advisor shows the status');
    AdvisorCommand('on');
    Check(ToolListed(Reg, 'advisor') and (EffectiveAdvisor.Model = 'm1'), '/advisor on restores config');
    Out_ := AdvisorCommand('main:m2');
    S := EffectiveAdvisor;
    Check((S.Provider = 'main') and (S.Model = 'm2') and (S.Source = 'this session') and
          ToolListed(Reg, 'advisor'), '/advisor provider:model switches for the session');
    Out_ := AdvisorCommand('m3');
    S := EffectiveAdvisor;
    Check((S.Provider = 'main') and (S.Model = 'm3'), '/advisor model keeps the provider in use');
    Check(Has(AdvisorCommand('adv:'), 'names no model') and (EffectiveAdvisor.Model = 'm3'),
          '/advisor provider: is refused and changes nothing');

    Check(ApplyAdvisorFlags(Cfg, '', True, Err) and not ToolListed(Reg, 'advisor'),
          '--no-advisor wins over config (and clears /advisor)');
    Check(Has(AdvisorStatus, '--no-advisor'), 'status says --no-advisor');
    Check(ApplyAdvisorFlags(Cfg, 'flagged', False, Err), '--advisor model');
    S := EffectiveAdvisor;
    Check((S.Provider = 'adv') and (S.Model = 'flagged') and (S.Source = '--advisor'),
          '--advisor <model> keeps advisor.provider from config');
    Check(not ApplyAdvisorFlags(Cfg, 'adv:', False, Err) and Has(Err, 'names no model'),
          '--advisor provider: is refused');

    Cfg.Advisor.MaxCallsPerTurn := 0;
    Cfg.Advisor.MaxContextChars := -5;
    ApplyAdvisorFlags(Cfg, '', False, Err);
    S := EffectiveAdvisor;
    Check((S.MaxCallsPerTurn = 3) and (S.MaxContextChars = 60000), 'zero or negative limits mean the defaults');
    Check(Has(Reg.ToProviderDefs[High(Reg.ToProviderDefs)].Description, 'At most 3 call(s)'),
          'the description states the cap');
  finally
    Reg.Free;
    Cfg.Free;
    ResetAdvisor;
  end;
end;

{ -------------------------------------------------------------- transcript }

procedure TestTranscript;
var
  H: TMessageArray;
  T, Big, Accented: string;
  i: Integer;
  Msgs: TMessageArray;
begin
  WriteLn('transcript');
  H := nil;
  Check(BuildAdvisorTranscript(H, 60000) = '(the conversation has no messages yet)', 'empty history');

  Push(H, MakeMessage(mrSystem, 'SECRET SYSTEM PROMPT'));
  Push(H, MakeMessage(mrUser, 'fix the build'));
  Push(H, AsstCalls('looking', [Call('c1', 'read_file', '{"path":"a.pas"}')]));
  Push(H, ToolResult('c1', 'unit a; end.'));
  Push(H, AsstCalls('', [Call('c2', 'advisor', '{"question":"ok?"}')]));
  T := BuildAdvisorTranscript(H, 60000);
  Check(Has(T, '[user]' + sLineBreak + 'fix the build'), 'user text under [user]');
  Check(Has(T, '[assistant]' + sLineBreak + 'looking'), 'assistant text under [assistant]');
  Check(Has(T, '[assistant called read_file] {"path":"a.pas"}'), 'tool call with its arguments');
  Check(Has(T, '[result of read_file]' + sLineBreak + 'unit a; end.'), 'tool result named by its call');
  Check(Has(T, '[assistant called advisor]'), 'the current advisor call is in it');
  Check(not Has(T, 'SECRET SYSTEM PROMPT'), 'system messages are left out');
  Check(not Has(T, 'cut to fit'), 'no cut note when it fits');

  { Forty exchanges of ~1000 characters into a 6000 budget. }
  H := nil;
  for i := 1 to 40 do
  begin
    Push(H, MakeMessage(mrUser, Format('question %d ', [i]) + StringOfChar('q', 1000)));
    Push(H, MakeMessage(mrAssistant, Format('answer %d ', [i]) + StringOfChar('a', 1000)));
  end;
  T := BuildAdvisorTranscript(H, 6000);
  Check(Length(T) <= 6000 + 300, Format('kept within the budget (%d characters)', [Length(T)]));
  Check(Has(T, '[the start of the conversation is cut to fit:') and Has(T, 'of 80 messages'),
        'a note says how many messages were cut');
  Check(Has(T, 'answer 40 ') and not Has(T, 'question 1 '), 'the newest part is kept, the oldest cut');

  { The user's task followed by a long run of tool traffic: the task stays. }
  H := nil;
  Push(H, MakeMessage(mrUser, 'THE TASK: port the parser'));
  for i := 1 to 30 do
  begin
    Push(H, AsstCalls('', [Call('t' + IntToStr(i), 'shell_exec', '{"command":"make"}')]));
    Push(H, ToolResult('t' + IntToStr(i), Format('build %d ', [i]) + StringOfChar('x', 1000)));
  end;
  T := BuildAdvisorTranscript(H, 6000);
  Check(Has(T, '[user, latest message -- kept though it falls in the cut part]') and
        Has(T, 'THE TASK: port the parser'), 'the user''s latest message is kept');
  Check(Has(T, 'build 30 ') and not Has(T, 'build 1 '), 'with the newest tool traffic after it');
  Check(Length(T) <= 6000 + 400, Format('still within the budget (%d characters)', [Length(T)]));

  { One enormous result: head and tail, middle cut. }
  H := nil;
  Push(H, MakeMessage(mrUser, 'go'));
  Big := 'HEAD-MARK' + StringOfChar('m', 50000) + 'TAIL-MARK';
  Push(H, AsstCalls('', [Call('r', 'read_file', '{}')]));
  Push(H, ToolResult('r', Big));
  T := BuildAdvisorTranscript(H, 8000);
  Check(Has(T, 'HEAD-MARK') and Has(T, 'TAIL-MARK') and Has(T, 'characters cut ...]'),
        'a long result keeps head and tail');
  Check(Length(T) < 8000, 'and fits');

  { Multi-byte text cut at both ends of the middle and at the budget. }
  H := nil;
  Accented := '';
  for i := 1 to 15000 do Accented := Accented + #$C3#$A9;            { e-acute, as bytes }
  Push(H, MakeMessage(mrUser, 'x' + Accented));
  Push(H, AsstCalls(#$C3#$A7 + Accented, [Call('u', 'read_file', '{}')]));
  Push(H, ToolResult('u', #$C3#$BC + Accented + 'y'));
  { Twelve budgets, so the head cuts land on both halves of a two-byte
    character; the one-byte prefix and suffix above do the same for the
    tail cuts, whose length does not change with the budget. }
  Big := '';
  for i := 7000 to 7011 do
  begin
    T := BuildAdvisorTranscript(H, i);
    if not ValidUtf8(T) then Big := Big + IntToStr(i) + ' ';
  end;
  Check(Big = '', 'never splits a UTF-8 character (bad budgets: ' + Big + ')');

  Msgs := BuildAdvisorMessages('THE TRANSCRIPT', 'Is B better?');
  Check((Length(Msgs) = 1) and (Msgs[0].Role = mrUser), 'one user message');
  Check(Has(Msgs[0].Content, '<transcript>' + sLineBreak + 'THE TRANSCRIPT' + sLineBreak + '</transcript>'),
        'the transcript, delimited');
  Check(Copy(Msgs[0].Content, Length(Msgs[0].Content) - 11, 12) = 'Is B better?',
        'the question comes last');
end;

{ ------------------------------------------------------ the turn accessor }

type
  { Round 1: three probe calls; round 2: one more; then a final answer.
    Every call to Chat counts as a round. }
  TProbeProvider = class(TInterfacedObject, ILLMProvider)
  private
    FRound: Integer;
    FCallName: string;
    FRounds: Integer;      { rounds of one call after the first }
  public
    LastToolResults: TArray<string>;
    constructor Create(const CallName: string; FirstRoundCalls, LaterRounds: Integer);
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
  private
    FFirst: Integer;
  end;

constructor TProbeProvider.Create(const CallName: string; FirstRoundCalls, LaterRounds: Integer);
begin
  inherited Create;
  FCallName := CallName;
  FFirst := FirstRoundCalls;
  FRounds := LaterRounds;
end;

function TProbeProvider.GetDefaultModel: string; begin Result := 'probe'; end;
function TProbeProvider.GetName: string;         begin Result := 'probe'; end;
function TProbeProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TProbeProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TProbeProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TProbeProvider.Chat(const Messages: array of TMessage;
                             const Tools: array of TToolDefinition;
                             const Model: string;
                             const Options: TChatOptions): TLLMResponse;
var
  i, n: Integer;
begin
  Inc(FRound);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  SetLength(LastToolResults, 0);
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrTool then
    begin
      SetLength(LastToolResults, Length(LastToolResults) + 1);
      LastToolResults[High(LastToolResults)] := Messages[i].Content;
    end;
  if FRound = 1 then n := FFirst
  else if FRound <= FRounds + 1 then n := 1
  else n := 0;
  if n = 0 then
  begin
    Result.Content := 'done';
    Result.FinishReason := 'stop';
    Exit;
  end;
  SetLength(Result.ToolCalls, n);
  for i := 0 to n - 1 do
    Result.ToolCalls[i] := Call(Format('r%dc%d', [FRound, i]), FCallName,
                                '{"question":"round ' + IntToStr(FRound) + '"}');
  Result.FinishReason := 'tool_calls';
end;

function TProbeProvider.ChatStream(const Messages: array of TMessage;
                                   const Tools: array of TToolDefinition;
                                   const Model: string;
                                   const Options: TChatOptions;
                                   OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

var
  GSeenLock: TCriticalSection;
  GSeen: TStringList;      { one line per probe call: "count=<n> hist=<len> last=<tool names>" }

function Tool_Probe(const ArgsJSON: string; out ErrMsg: string): string;
var
  H: TMessageArray;
  Got: Boolean;
  N, i: Integer;
  Last: string;
begin
  ErrMsg := '';
  Got := CurrentDispatchHistory(H);
  N := BumpTurnCounter('probe');
  Last := '';
  if Got and (Length(H) > 0) then
    for i := 0 to High(H[High(H)].ToolCalls) do
      Last := Last + H[High(H)].ToolCalls[i].Func.Name + ',';
  GSeenLock.Acquire;
  try
    GSeen.Add(Format('got=%s count=%d hist=%d last=%s',
                     [BoolToStr(Got, True), N, Length(H), Last]));
  finally
    GSeenLock.Release;
  end;
  { A little wait, so the three workers of a parallel batch overlap. }
  Sleep(20);
  Result := 'n=' + IntToStr(N);
end;

function RegisterProbe: TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  T := Default(TTool);
  T.Name := 'probe';
  T.Description := 'probe';
  T.Schema := '{"type":"object","properties":{}}';
  T.Handler := Tool_Probe;
  T.Category := tcReadOnly;
  Result.Register(T);
end;

function RunLoop(Reg: TToolRegistry; P: ILLMProvider; ActiveCfg: TConfig;
                 out Loop: TToolLoopResult): Boolean;
var
  Cfg: TToolLoopConfig;
  Msgs: array of TMessage;
begin
  Cfg := Default(TToolLoopConfig);
  Cfg.Provider := P;
  Cfg.Registry := Reg;
  Cfg.Model := 'probe';
  Cfg.MaxIterations := 6;
  Cfg.Options := DefaultChatOptions;
  Cfg.Parallel := True;
  Cfg.DisableProgressLedger := True;
  Cfg.Mode := pmBuild;
  Cfg.ActiveConfig := ActiveCfg;
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'probe the turn');
  Result := RunToolLoop(Cfg, Msgs, Loop);
end;

procedure TestTurnAccessor;
var
  Reg: TToolRegistry;
  P: TProbeProvider;
  PI_: ILLMProvider;
  Loop: TToolLoopResult;
  H: TMessageArray;
  Counts: string;
  i: Integer;
  Cfg: TToolLoopConfig;
  Disp: IToolDispatcher;
  Err: string;
begin
  WriteLn('turn accessor');
  Check(not CurrentDispatchHistory(H) and (Length(H) = 0), 'outside a loop: no history');
  Check(BumpTurnCounter('probe') = 0, 'outside a loop: no counter');

  Reg := RegisterProbe;
  try
    GSeen.Clear;
    P := TProbeProvider.Create('probe', 3, 1);
    PI_ := P;
    Check(RunLoop(Reg, PI_, nil, Loop), 'loop ran');
    Check(GSeen.Count = 4, Format('four probe calls (%d)', [GSeen.Count]));
    Counts := '';
    for i := 0 to GSeen.Count - 1 do Counts := Counts + GSeen[i] + '; ';
    Check(Has(Counts, 'count=1 ') and Has(Counts, 'count=2 ') and Has(Counts, 'count=3 ') and
          Has(Counts, 'count=4 '), 'three parallel calls count 1..3, the next round 4: ' + Counts);
    Check(Has(Counts, 'got=True count=1 hist=2 last=probe,probe,probe,') or
          Has(Counts, 'got=True count=2 hist=2 last=probe,probe,probe,') or
          Has(Counts, 'got=True count=3 hist=2 last=probe,probe,probe,'),
          'round 1 sees the user message and its own assistant turn');
    Check(Has(Counts, 'got=True count=4 hist=6 last=probe,'),
          'round 2 sees round 1''s results and its own assistant turn');

    GSeen.Clear;
    P := TProbeProvider.Create('probe', 1, 0);
    PI_ := P;
    RunLoop(Reg, PI_, nil, Loop);
    Check((GSeen.Count = 1) and Has(GSeen[0], 'count=1 '), 'the next loop counts from 1 again');

    { The script RPC / workflow dispatcher has no turn. }
    GSeen.Clear;
    Cfg := Default(TToolLoopConfig);
    Cfg.Registry := Reg;
    Disp := MakeLoopDispatcher(Cfg);
    Disp.Dispatch('probe', '{}', Err);
    Check((GSeen.Count = 1) and Has(GSeen[0], 'got=False count=0'),
          'through the script dispatcher: no history, no counter');
  finally
    Reg.Free;
  end;
end;

{ ------------------------------------------------------- the handler's cap }

procedure TestHandlerCap;
var
  Cfg: TConfig;
  Reg: TToolRegistry;
  P: TProbeProvider;
  PI_: ILLMProvider;
  Loop: TToolLoopResult;
  Err, Out_: string;
begin
  WriteLn('handler');
  Cfg := NewCfg;
  Reg := TToolRegistry.Create;
  try
    ResetAdvisor;
    Cfg.Advisor.Provider := 'adv';
    Cfg.Advisor.Model := 'm1';
    Cfg.Advisor.MaxCallsPerTurn := 1;
    ApplyAdvisorFlags(Cfg, '', False, Err);
    RegisterAdvisorTool(Reg, nil);

    Out_ := Reg.RunTool('advisor', '{"question":"is this right?"}', Err);
    Check((Out_ = '') and Has(Err, 'works only as a direct tool call'),
          'called outside an agent turn: refused, it has no conversation');
    Out_ := Reg.RunTool('advisor', '{}', Err);
    Check(Has(Err, '"question" is required'), 'a call without a question is refused');

    { Two rounds of one advisor call each, cap 1. The first reaches the
      provider (nothing listens there); the second must be refused before. }
    P := TProbeProvider.Create('advisor', 1, 1);
    PI_ := P;
    Check(RunLoop(Reg, PI_, Cfg, Loop), 'loop ran');
    Check(Length(P.LastToolResults) = 2, Format('two results reached the model (%d)',
                                                [Length(P.LastToolResults)]));
    if Length(P.LastToolResults) = 2 then
    begin
      Check(Has(P.LastToolResults[0], 'ERROR: advisor: adv did not answer'),
            'first call: asked the advisor''s provider -- ' + P.LastToolResults[0]);
      Check(Has(P.LastToolResults[1], 'ERROR: advisor: limit reached') and
            Has(P.LastToolResults[1], 'consulted 1 time(s) this turn') and
            Has(P.LastToolResults[1], 'max_calls_per_turn'),
            'second call: refused by the cap -- ' + P.LastToolResults[1]);
    end;
  finally
    Reg.Free;
    Cfg.Free;
    ResetAdvisor;
  end;
end;

{ ---------------------------------------------------------------- subagents }

procedure TestSubagents;
var
  Cfg: TConfig;
  Reg, Child: TToolRegistry;
  Err: string;
begin
  WriteLn('subagents');
  Cfg := NewCfg;
  Reg := TToolRegistry.Create;
  try
    ResetAdvisor;
    Cfg.Advisor.Model := 'm1';
    ApplyAdvisorFlags(Cfg, '', False, Err);
    RegisterAdvisorTool(Reg, nil);
    { The built-in general-purpose subagent's tool list is '*'. }
    Child := BuildFilteredRegistry(Reg, ['*']);
    try
      Check(ToolListed(Child, 'advisor'), 'a "*" subagent inherits the advisor');
    finally
      Child.Free;
    end;
    Child := BuildFilteredRegistry(Reg, ['advisor']);
    try
      Check(ToolListed(Child, 'advisor'), 'a configured subagent gets it by naming it');
    finally
      Child.Free;
    end;
    ApplyAdvisorFlags(Cfg, '', True, Err);
    Child := BuildFilteredRegistry(Reg, ['*']);
    try
      Check(not ToolListed(Child, 'advisor'), 'with no advisor set, subagents have none either');
    finally
      Child.Free;
    end;
  finally
    Reg.Free;
    Cfg.Free;
    ResetAdvisor;
  end;
end;

{ ------------------------------------------------------------- stats bucket }

procedure TestBucketId;
var
  A, B: string;
begin
  WriteLn('stats bucket');
  A := AdvisorStatsBucketId('openai', 'gpt-x');
  Check(Copy(A, 1, Length('_gateway_advisor_openai-gpt-x-')) = '_gateway_advisor_openai-gpt-x-',
        'readable prefix: ' + A);
  Check(IsGatewayBucketSessionId(A), 'hidden from session lists, cleared by a stats reset');
  Check(IsSafeSessionId(A) and IsSafeSessionId(AdvisorStatsBucketId('p', StringOfChar('m', 300))),
        'a safe session id, even for a very long model name');
  Check(AdvisorStatsBucketId('a/b', 'c') <> AdvisorStatsBucketId('a:b', 'c'), 'lossy names still differ');
  Check(AdvisorStatsBucketId('a', 'bc') <> AdvisorStatsBucketId('ab', 'c'), 'provider/model boundary counts');
  Check(A = AdvisorStatsBucketId('openai', 'gpt-x'), 'stable');
  B := AdvisorStatsBucketId('openai', 'gpt-y');
  Check(A <> B, 'one bucket per model');
end;

begin
  GSeenLock := TCriticalSection.Create;
  GSeen := TStringList.Create;
  try
    TestConfig;
    TestSpecs;
    TestPresence;
    TestTranscript;
    TestTurnAccessor;
    TestHandlerCap;
    TestSubagents;
    TestBucketId;
  finally
    GSeen.Free;
    GSeenLock.Free;
  end;
  if Failures > 0 then
  begin
    WriteLn(Format('advisor_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('advisor_tests: all passed');
end.
