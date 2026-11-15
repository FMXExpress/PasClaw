(*
  PasClaw.Cmd.DecisionModel -- `pasclaw decision-model`: decision models at decision points.

    pasclaw decision-model status
        Each decision point, the backend selected for it, and whether the
        gate lets it be used -- with the bench result that decided it.
    pasclaw decision-model test <backend>
        One small live call: is the backend reachable, does it answer.
    pasclaw decision-model bench rerank [options]
        Run a labeled rerank set through the reranker /v1/rerank uses
        today (the baseline) and through the decision backend, print both,
        and record the result for the gate. The backend is used at the
        point only when it beat the baseline by the margin.

  Exit codes for bench: 0 the backend passed, 3 it ran and did not pass,
  1 it could not run.
*)
unit PasClaw.Cmd.DecisionModel;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_DecisionModel_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.DecisionModels,
  PasClaw.DecisionModels.Gate,
  PasClaw.DecisionModels.Bench,
  PasClaw.Memory.Rerank.LLM,
  PasClaw.Memory.Rerank.Serve,
  PasClaw.Memory.Rerank.Decision;

const
  DEFAULT_RERANK_SET = 'bench/decision-models/rerank-docs.jsonl';
  DEFAULT_MARGIN     = 0.02;
  { The points that consult the gate, and the implementations each
    would otherwise use. }
  KnownPoints: array[0..0] of string = ('rerank');

procedure Help;
begin
  PrintLn('Usage: pasclaw decision-model <status | test | bench>');
  PrintLn;
  PrintLn('  status                     each decision point, its backend, and whether the');
  PrintLn('                             gate lets it be used (and why)');
  PrintLn('  test <backend>             one small live call to a backend in decision_models.backends');
  PrintLn('  bench rerank [options]     benchmark a backend against the reranker /v1/rerank');
  PrintLn('                             uses today, and record the result for the gate');
  PrintLn;
  PrintLn('bench rerank options:');
  PrintLn('  --backend NAME     the decision backend (default: decision_models.points.rerank)');
  PrintLn('  --dataset PATH     a rerank set, JSONL (default: ' + DEFAULT_RERANK_SET + ')');
  PrintLn('  --baseline KIND    llm | local (default: what /v1/rerank uses -- rerank_backend,');
  PrintLn('                     and for auto, local when provisioned, else llm)');
  PrintLn('  --provider NAME    the chat provider for the llm baseline (default: default_provider)');
  PrintLn('  --model MODEL      its model (default: the provider''s)');
  PrintLn('  --margin M         MRR the backend must gain to pass (default 0.02)');
  PrintLn('  --limit N          only the first N questions (a smoke run; not recorded)');
  PrintLn('  --pace MS          wait MS milliseconds between questions, to stay under a');
  PrintLn('                     free tier''s requests-per-minute (e.g. 4500 for 15/min)');
  PrintLn('  --retries N        retry a rate-limited decision call (after the delay the API');
  PrintLn('                     asks for) or a failed baseline call (after 10 s), up to N');
  PrintLn('                     times (default 4); only the successful attempt is timed');
  PrintLn('  --out FILE         write one line per question with each system''s rank');
  PrintLn('  --no-save          do not record the result');
  PrintLn;
  PrintLn('A backend is used at a point only after a recorded run where it beat that');
  PrintLn('point''s own implementation (decision_models.require_bench, on by default).');
end;

function Pct(V: Double): string;
begin
  Result := FormatFloat('0.0', V * 100) + '%';
end;

function F3(V: Double): string;
begin
  Result := FormatFloat('0.000', V);
end;

function PadR(const S: string; W: Integer): string;
begin
  Result := S;
  while Length(Result) < W do Result := Result + ' ';
end;

function PadL(const S: string; W: Integer): string;
begin
  Result := S;
  while Length(Result) < W do Result := ' ' + Result;
end;

procedure PrintStatsRow(const S: TRankStats; ShowLatency: Boolean);
var
  Lat, Tok: string;
begin
  if ShowLatency then
    Lat := PadL(IntToStr(StatsPercentileMs(S, 0.5)), 6) + PadL(IntToStr(StatsPercentileMs(S, 0.95)), 7)
  else
    Lat := PadL('-', 6) + PadL('-', 7);
  if S.InTok + S.OutTok > 0 then
    Tok := PadL(IntToStr(S.InTok), 9) + PadL(IntToStr(S.OutTok), 8)
  else
    Tok := PadL('-', 9) + PadL('-', 8);
  PrintLn('  ' + PadR(S.Name, 44) + PadL(Pct(StatsHit1(S)), 7) + PadL(Pct(StatsHit3(S)), 8) +
          PadL(F3(StatsMRR(S)), 7) + Lat + Tok + PadL(IntToStr(S.Errors), 5));
end;

{ The reranker /v1/rerank uses without a decision model: rerank_backend
  local -> the local cross-encoder, llm -> the chat model, auto (and
  anything else) -> local when provisioned, else the chat model. The
  bench's default baseline and `status` both ask this, so they agree with
  the gateway. }
function RerankUsesLocal(Cfg: TConfig): Boolean;
var
  B: string;
begin
  B := LowerCase(Trim(Cfg.RerankBackend));
  if B = 'local' then Result := True
  else if B = 'llm' then Result := False
  else Result := LocalRerankAvailable(GetHome);
end;

{ "... Please retry in 7s ..." -> 7000 (+ a second of slack); 10 s when the
  API did not say. }
function RetryDelayMs(const Err: string): Integer;
var
  P, N: Integer;
  Num: string;
begin
  Result := 10000;
  P := Pos('retry in ', LowerCase(Err));
  if P = 0 then Exit;
  P := P + Length('retry in ');
  Num := '';
  while (P <= Length(Err)) and (Err[P] in ['0'..'9']) do
  begin
    Num := Num + Err[P];
    Inc(P);
  end;
  N := StrToIntDef(Num, -1);
  if N >= 0 then Result := (N + 1) * 1000;
end;

function IdentityOrder(N: Integer): TArray<Integer>;
var
  i: Integer;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do Result[i] := i;
end;

function NowISO: string;
begin
  Result := FormatDateTime('yyyy-mm-dd"T"hh:nn:ss"Z"', LocalTimeToUniversal(Now));
end;

function RunBenchRerank(const Argv: array of string; Start: Integer): Integer;
var
  Cfg: TConfig;
  i, Limit, Done, PaceMs, Retries, Attempt, BaseRetries, CandRetries: Integer;
  BackendName, DatasetPath, BaselineKind, ProviderName, ChatModel, OutPath, Err, Sha: string;
  Margin: Double;
  NoSave: Boolean;
  B: TDecisionBackend;
  Prov: ILLMProvider;
  Cases: TRerankCases;
  First, Base, Cand: TRankStats;
  OrderB, OrderC: TArray<Integer>;
  ScoresB, ScoresC: TArray<Single>;
  InTok, OutTok, Elapsed: Int64;
  T0: TDateTime;
  OkB, OkC, Pass: Boolean;
  BaselineName, CandName: string;
  Out_: TStringList;
  Line: TJsonObject;
  Rec: TDecisionBenchRecord;
  Detail: TJsonObject;
begin
  Result := 1;
  BackendName := '';
  DatasetPath := DEFAULT_RERANK_SET;
  BaselineKind := '';
  ProviderName := '';
  ChatModel := '';
  OutPath := '';
  Margin := DEFAULT_MARGIN;
  Limit := 0;
  PaceMs := 0;
  Retries := 4;
  BaseRetries := 0;
  CandRetries := 0;
  NoSave := False;
  i := Start;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '--backend') and (i < High(Argv)) then begin Inc(i); BackendName := Argv[i]; end
    else if (Argv[i] = '--dataset') and (i < High(Argv)) then begin Inc(i); DatasetPath := Argv[i]; end
    else if (Argv[i] = '--baseline') and (i < High(Argv)) then begin Inc(i); BaselineKind := LowerCase(Argv[i]); end
    else if (Argv[i] = '--provider') and (i < High(Argv)) then begin Inc(i); ProviderName := Argv[i]; end
    else if (Argv[i] = '--model') and (i < High(Argv)) then begin Inc(i); ChatModel := Argv[i]; end
    else if (Argv[i] = '--out') and (i < High(Argv)) then begin Inc(i); OutPath := Argv[i]; end
    else if (Argv[i] = '--margin') and (i < High(Argv)) then
    begin
      Inc(i);
      if not TryStrToFloat(Argv[i], Margin) then
      begin
        PrintErr(FormatCLIError('--margin wants a number, got ' + Argv[i], 'pasclaw decision-model bench'));
        Exit(1);
      end;
    end
    else if (Argv[i] = '--limit') and (i < High(Argv)) then begin Inc(i); Limit := StrToIntDef(Argv[i], 0); end
    else if (Argv[i] = '--pace') and (i < High(Argv)) then begin Inc(i); PaceMs := StrToIntDef(Argv[i], 0); end
    else if (Argv[i] = '--retries') and (i < High(Argv)) then begin Inc(i); Retries := StrToIntDef(Argv[i], 4); end
    else if Argv[i] = '--no-save' then NoSave := True
    else
    begin
      PrintErr(FormatCLIError('unknown argument: ' + Argv[i], 'pasclaw decision-model bench rerank'));
      Exit(1);
    end;
    Inc(i);
  end;

  Cfg := LoadConfig;
  Out_ := nil;
  try
    if BackendName = '' then BackendName := DecisionPointBackendName(Cfg, 'rerank');
    if BackendName = '' then
    begin
      PrintErr(FormatCLIError('no backend: pass --backend, or set decision_models.points.rerank',
                              'pasclaw decision-model bench rerank'));
      Exit(1);
    end;
    if not ResolveDecisionBackend(Cfg, BackendName, B, Err) then
    begin
      PrintErr(FormatCLIError(Err, 'pasclaw decision-model bench rerank'));
      Exit(1);
    end;
    if not LoadRerankSet(DatasetPath, Cases, Sha, Err) then
    begin
      PrintErr(FormatCLIError('rerank set: ' + Err, 'pasclaw decision-model bench rerank'));
      Exit(1);
    end;
    if (Limit > 0) and (Limit < Length(Cases)) then SetLength(Cases, Limit);

    if BaselineKind = '' then
      if RerankUsesLocal(Cfg) then BaselineKind := 'local' else BaselineKind := 'llm';
    if BaselineKind = 'llm' then
    begin
      if ProviderName <> '' then
      begin
        if not NewProviderFromConfig(Cfg, ProviderName, Prov, Err) then
        begin
          PrintErr(FormatCLIError('baseline provider: ' + Err, 'pasclaw decision-model bench rerank'));
          Exit(1);
        end;
      end
      else if not NewDefaultProvider(Cfg, Prov, Err) then
      begin
        PrintErr(FormatCLIError('baseline: no chat provider for the llm reranker: ' + Err,
                                'pasclaw decision-model bench rerank'));
        Exit(1);
      end;
      if ChatModel = '' then ChatModel := Prov.GetDefaultModel;
      BaselineName := RerankBaselineName(False, Prov, ChatModel, GetHome);
    end
    else if BaselineKind = 'local' then
    begin
      if not LocalRerankAvailable(GetHome) then
      begin
        PrintErr(FormatCLIError('baseline local: no local reranker provisioned ' +
                                '(`pasclaw memory provision --rerank`)', 'pasclaw decision-model bench rerank'));
        Exit(1);
      end;
      BaselineName := RerankBaselineName(True, nil, '', GetHome);
    end
    else
    begin
      PrintErr(FormatCLIError('--baseline is llm or local, got ' + BaselineKind,
                              'pasclaw decision-model bench rerank'));
      Exit(1);
    end;
    CandName := 'decision:' + B.Name + '/' + B.Model;

    PrintLn('decision-model bench rerank: ' + IntToStr(Length(Cases)) + ' questions from ' + DatasetPath);
    PrintLn('  baseline   ' + BaselineName);
    PrintLn('  candidate  ' + CandName + '  (' + DecisionURL(B) + ')');
    PrintLn;

    InitStats(First, 'first stage (the set''s order)');
    InitStats(Base, BaselineName);
    InitStats(Cand, CandName);
    if OutPath <> '' then Out_ := TStringList.Create;

    for i := 0 to High(Cases) do
    begin
      if (PaceMs > 0) and (i > 0) then Sleep(PaceMs);
      AddOutcome(First, IdentityOrder(Length(Cases[i].Docs)), Cases[i].Relevant, 0, False, 0, 0);

      { Baseline. A failure counts with the first-stage order: that is
        what /v1/rerank's caller is left with. }
      Attempt := 0;
      repeat
        InTok := 0; OutTok := 0;
        T0 := Now;
        if BaselineKind = 'llm' then
          OkB := LLMRerankUsage(Prov, ChatModel, Cases[i].Query, Cases[i].Docs, 0, 0,
                                OrderB, ScoresB, InTok, OutTok)
        else
          OkB := LocalRerank(GetHome, Cases[i].Query, Cases[i].Docs, OrderB, ScoresB);
        Elapsed := MilliSecondsBetween(Now, T0);
        { The llm reranker does not say why it failed; a rate limit is the
          usual reason on a free tier, so wait and ask again. }
        if OkB or (Attempt >= Retries) or (BaselineKind <> 'llm') then Break;
        Inc(Attempt);
        Inc(BaseRetries);
        Sleep(10000);
      until False;
      if not OkB then OrderB := IdentityOrder(Length(Cases[i].Docs));
      AddOutcome(Base, OrderB, Cases[i].Relevant, Elapsed, not OkB, InTok, OutTok);

      Attempt := 0;
      repeat
        OkC := DecisionRerank(B, Cases[i].Query, Cases[i].Docs, OrderC, ScoresC, InTok, Elapsed, Err);
        { Only a rate limit is worth asking again: any other error would
          come back the same. }
        if OkC or (Attempt >= Retries) or (Pos('HTTP 429', Err) <> 1) then Break;
        Inc(Attempt);
        Inc(CandRetries);
        Sleep(RetryDelayMs(Err));
      until False;
      if not OkC then
      begin
        OrderC := IdentityOrder(Length(Cases[i].Docs));
        PrintErr('  ' + Cases[i].Id + ': ' + B.Name + ' failed: ' + Err);
      end;
      AddOutcome(Cand, OrderC, Cases[i].Relevant, Elapsed, not OkC, InTok, 0);

      if Out_ <> nil then
      begin
        Line := TJsonObject.Create;
        try
          Line.PutStr('id', Cases[i].Id);
          Line.PutStr('query', Cases[i].Query);
          Line.PutInt('first_stage_rank', FirstRelevantRank(IdentityOrder(Length(Cases[i].Docs)), Cases[i].Relevant));
          Line.PutInt('baseline_rank', FirstRelevantRank(OrderB, Cases[i].Relevant));
          Line.PutStr('baseline_top', Cases[i].DocIds[OrderB[0]]);
          Line.PutBool('baseline_failed', not OkB);
          Line.PutInt('candidate_rank', FirstRelevantRank(OrderC, Cases[i].Relevant));
          Line.PutStr('candidate_top', Cases[i].DocIds[OrderC[0]]);
          Line.PutBool('candidate_failed', not OkC);
          Out_.Add(Line.ToJSON);
        finally
          Line.Free;
        end;
      end;
      Done := i + 1;
      if (Done mod 10 = 0) or (Done = Length(Cases)) then
        PrintErr(Format('  %d/%d', [Done, Length(Cases)]));
    end;

    PrintLn;
    PrintLn('  ' + PadR('system', 44) + PadL('Hit@1', 7) + PadL('Hit@3', 8) + PadL('MRR', 7) +
            PadL('p50ms', 6) + PadL('p95ms', 7) + PadL('in tok', 9) + PadL('out tok', 8) + PadL('err', 5));
    PrintStatsRow(First, False);
    PrintStatsRow(Base, True);
    PrintStatsRow(Cand, True);
    PrintLn;

    { A failed call counts with the first-stage order. Failures that are a
      quota rather than the reranker make the comparison unfair to
      whichever side hit them -- say so instead of letting it pass quietly. }
    if BaseRetries + CandRetries > 0 then
      PrintLn('  retried: baseline ' + IntToStr(BaseRetries) + ', decision model ' +
              IntToStr(CandRetries) + ' call(s) (rate limits); only successful attempts are timed');
    if Base.Errors > 0 then
      PrintLn('  WARNING: ' + IntToStr(Base.Errors) + ' baseline call(s) failed and count with the ' +
              'first-stage order; if that was a rate limit, rerun with --pace');
    if Cand.Errors > 0 then
      PrintLn('  WARNING: ' + IntToStr(Cand.Errors) + ' decision model call(s) failed and count with ' +
              'the first-stage order');
    Pass := RerankVerdict(StatsMRR(Cand), StatsMRR(Base), Margin);
    if Pass then
      PrintLn('  PASS: ' + CandName + ' beat ' + BaselineName + ' by ' +
              F3(StatsMRR(Cand) - StatsMRR(Base)) + ' MRR (needs +' + F3(Margin) + ')')
    else
      PrintLn('  NOT PASSED: ' + CandName + ' MRR ' + F3(StatsMRR(Cand)) + ' vs ' +
              BaselineName + ' ' + F3(StatsMRR(Base)) + ' (needs +' + F3(Margin) + ')');

    if Out_ <> nil then
    begin
      WriteFileText(OutPath, Out_.Text);
      PrintLn('  per-question ranks: ' + OutPath);
    end;

    if Limit > 0 then
      PrintLn('  --limit run: not recorded')
    else if NoSave then
      PrintLn('  --no-save: not recorded')
    else
    begin
      Rec := Default(TDecisionBenchRecord);
      Rec.Point := 'rerank';
      Rec.Backend := B.Name;
      Rec.Kind := DecisionBackendKindName(B.Kind);
      Rec.Model := B.Model;
      Rec.BaselineKind := BaselineKind;
      Rec.Baseline := BaselineName;
      Rec.Dataset := DatasetPath;
      Rec.DatasetSHA256 := Sha;
      Rec.N := Length(Cases);
      Rec.Metric := 'mrr';
      Rec.BaselineValue := StatsMRR(Base);
      Rec.CandidateValue := StatsMRR(Cand);
      Rec.Margin := Margin;
      Rec.Pass := Pass;
      Rec.At := NowISO;
      Detail := TJsonObject.Create;
      try
        Detail.PutRaw('first_stage', StatsToJSON(First));
        Detail.PutRaw('baseline', StatsToJSON(Base));
        Detail.PutRaw('candidate', StatsToJSON(Cand));
        Detail.PutInt('baseline_retries', BaseRetries);
        Detail.PutInt('candidate_retries', CandRetries);
        Rec.DetailJSON := Detail.ToJSON;
      finally
        Detail.Free;
      end;
      if SaveDecisionBenchRecord(Rec, Err) then
        PrintLn('  recorded: ' + DecisionBenchPath('rerank'))
      else
      begin
        PrintErr(FormatCLIError(Err, 'pasclaw decision-model bench rerank'));
        Exit(1);
      end;
    end;
    if Pass then Result := 0 else Result := 3;
  finally
    Out_.Free;
    Cfg.Free;
  end;
end;

function RunStatus: Integer;
var
  Cfg: TConfig;
  i: Integer;
  Name, Why, Err: string;
  B: TDecisionBackend;
  Open_, UseLocal: Boolean;
  Prov: ILLMProvider;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.DecisionModels.Backends) = 0 then
      PrintLn('No decision backends configured (decision_models.backends in config.json).')
    else
    begin
      PrintLn('Backends:');
      for i := 0 to High(Cfg.DecisionModels.Backends) do
        if ResolveDecisionBackend(Cfg, Cfg.DecisionModels.Backends[i].Name, B, Err) then
          PrintLn('  ' + PadR(B.Name, 20) + PadR(DecisionBackendKindName(B.Kind), 11) +
                  PadR(B.Model, 22) + DecisionURL(B))
        else
          PrintLn('  ' + PadR(Cfg.DecisionModels.Backends[i].Name, 20) + 'unusable: ' + Err);
    end;
    if not Cfg.DecisionModels.RequireBench then
      PrintLn('decision_models.require_bench is off: a selected backend is used without a bench run.');
    PrintLn;
    PrintLn('Decision points:');
    for i := 0 to High(KnownPoints) do
    begin
      Name := DecisionPointBackendName(Cfg, KnownPoints[i]);
      if Name = '' then
      begin
        PrintLn('  ' + PadR(KnownPoints[i], 10) + 'no backend selected');
        Continue;
      end;
      { rerank: the reranker /v1/rerank would use without a decision
        model (rerank_backend auto: local when provisioned, else the
        default provider's chat model) -- the gate is asked about that. }
      UseLocal := RerankUsesLocal(Cfg);
      Prov := nil;
      if not UseLocal then NewDefaultProvider(Cfg, Prov, Err);
      Open_ := DecisionGate(Cfg, KnownPoints[i], RerankBaselineName(UseLocal, Prov, '', GetHome), B, Why);
      if Open_ then PrintLn('  ' + PadR(KnownPoints[i], 10) + 'ON   ' + Why)
      else PrintLn('  ' + PadR(KnownPoints[i], 10) + 'off  ' + Why);
    end;
    for i := 0 to High(Cfg.DecisionModels.Points) do
      if not SameText(Cfg.DecisionModels.Points[i].Point, 'rerank') then
        PrintLn('  ' + PadR(Cfg.DecisionModels.Points[i].Point, 10) +
                'off  no decision point by this name consults the gate yet');
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function RunTest(const Name: string): Integer;
var
  Cfg: TConfig;
  B: TDecisionBackend;
  Err: string;
  Qs: TDecisionQuestions;
  R: TDecisionResult;
begin
  Result := 1;
  Cfg := LoadConfig;
  try
    if not ResolveDecisionBackend(Cfg, Name, B, Err) then
    begin
      PrintErr(FormatCLIError(Err, 'pasclaw decision-model test'));
      Exit;
    end;
    SetLength(Qs, 1);
    Qs[0] := NoulQuestion('greeting', 'Is this message a greeting?');
    R := Decide(B, 'hello there, how are you?', Qs);
    if not R.Ok then
    begin
      PrintErr(FormatCLIError(B.Name + ' (' + DecisionURL(B) + '): ' + R.Error, 'pasclaw decision-model test'));
      Exit;
    end;
    PrintLn(B.Name + ' (' + B.Model + ') answered in ' + IntToStr(R.ElapsedMs) + ' ms, ' +
            IntToStr(R.InputTokens) + ' input tokens:');
    PrintLn('  "hello there, how are you?" is a greeting: P(yes) = ' + F3(R.Answers[0].Value));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_DecisionModel_Run(const Argv: array of string): Integer;
begin
  if (Length(Argv) = 0) or (Argv[0] = '-h') or (Argv[0] = '--help') or (Argv[0] = 'help') then
  begin
    Help;
    if Length(Argv) = 0 then Exit(1) else Exit(0);
  end;
  if Argv[0] = 'status' then Exit(RunStatus);
  if Argv[0] = 'test' then
  begin
    if Length(Argv) < 2 then
    begin
      PrintErr(FormatCLIError('which backend? pasclaw decision-model test <backend>', 'pasclaw decision-model'));
      Exit(1);
    end;
    Exit(RunTest(Argv[1]));
  end;
  if Argv[0] = 'bench' then
  begin
    if (Length(Argv) < 2) or (Argv[1] <> 'rerank') then
    begin
      PrintErr(FormatCLIError('bench what? `rerank` is the decision point with a bench today',
                              'pasclaw decision-model bench'));
      Exit(1);
    end;
    Exit(RunBenchRerank(Argv, 2));
  end;
  PrintErr(FormatCLIError('unknown subcommand: ' + Argv[0], 'pasclaw decision-model'));
  Result := 1;
end;

end.
