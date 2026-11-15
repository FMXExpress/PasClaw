program decision_models_tests;
(*
  PasClaw.DecisionModels and PasClaw.DecisionModels.Gate, no network.

    - DecisionURL for both wire formats, with and without the version
      path already on the base, trailing slashes
    - BuildDecisionBody: google says `input`, systemone says `state`;
      criteria shapes per kind and per vendor; the default model
    - ParseDecisionResponse on a response captured from the live Gemini
      Decision 1 API (noul + choice + score), and the ways a response
      can be wrong: a missing answer, the wrong kind, no probabilities,
      not JSON
    - Top is computed from the probabilities, never the vendor's
      `confidence` (the fixture's score answer has a vendor confidence
      that differs from nothing we use; the test pins Top to the max
      probability)
    - ResolveDecisionBackend: a Google backend borrows a Gemini
      provider's key and base, a systemone backend takes only the key;
      unknown kind, unknown provider, no key
    - DecisionGate: nothing selected; selected but never benchmarked; a
      failing run; a passing run against llm opens the gate for llm and
      not for local; a run for another model does not count; a newer run
      replaces the older one; require_bench off opens it without a run
    - config: decisions loads, saves, round-trips; api_key is masked by
      MaskConfigSecretsJSON and restored by name on a save

  PASCLAW_HOME must be a scratch dir (the Makefile target arranges it).
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Math,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.DecisionModels,
  PasClaw.DecisionModels.Gate,
  PasClaw.DecisionModels.Bench,
  PasClaw.Memory.Rerank.Decision;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;
procedure AssertNear(Got, Want: Double; const Msg: string);
begin if Abs(Got - Want) > 1e-6 then Fail_(Format('%s (got %.9f, want %.9f)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 400)); end;
procedure AssertLacks(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) > 0 then Fail_(Msg + ' -- did not expect "' + Needle + '" in: ' + Copy(Hay, 1, 400)); end;
procedure Ok(const Msg: string); begin WriteLn('  ok: ' + Msg); end;

const
  { POST /v1beta/decisions, gemini-decision-1, 2026-11-14: the three
    questions Questions3 builds, on a one-line rename request. }
  LiveResponse =
    '{"answers":{"is_code_change":{"confidence":0.985963953010753,"noul":0.985963953010753,"type":"noul"},' +
    '"difficulty":{"confidence":0.9431281677916588,"choice":"trivial","probabilities":{"hard":0.004272833688555002,' +
    '"moderate":0.052598998519786236,"trivial":0.9431281677916588},"type":"choice"},"risk":{"confidence":0.46562374049673666,' +
    '"score":0.6794361548897918,"probabilities":{"0":0.46562374049673666,"2":0.14505989538652858,"1":0.3893163641167347},' +
    '"legend":{"2":"high risk","1":"some risk","0":"no risk"},"type":"score"}},"usage":{"total_tokens":260,' +
    '"total_input_tokens":260,"input_tokens_by_modality":[{"modality":"text","tokens":260}],"total_output_tokens":0}}';

function Questions3: TDecisionQuestions;
begin
  SetLength(Result, 3);
  Result[0] := NoulQuestion('is_code_change', 'Does the user ask for a change to source code?');
  Result[1] := ChoiceQuestion('difficulty', 'How much work is this request for a coding agent?',
    ['trivial', 'moderate', 'hard'],
    ['a one-line or rename-level change', 'a small feature or fix across a few places',
     'design work, many files, or debugging an unknown cause']);
  Result[2] := ScoreQuestion('risk', 'How risky is it to let a cheap model do this unattended?',
    ['no risk', 'some risk', 'high risk']);
end;

function Backend(K: TDecisionBackendKind; const Base: string): TDecisionBackend;
begin
  Result := Default(TDecisionBackend);
  Result.Name := 'b';
  Result.Kind := K;
  Result.APIBase := Base;
  Result.APIKey := 'k';
end;

procedure TestURLs;
begin
  AssertEqStr(DecisionURL(Backend(dbGoogle, '')),
    'https://generativelanguage.googleapis.com/v1beta/decisions', 'google default');
  AssertEqStr(DecisionURL(Backend(dbGoogle, 'https://generativelanguage.googleapis.com/')),
    'https://generativelanguage.googleapis.com/v1beta/decisions', 'google, trailing slash');
  AssertEqStr(DecisionURL(Backend(dbGoogle, 'https://proxy.example/google/v1beta')),
    'https://proxy.example/google/v1beta/decisions', 'google, base already has /v1beta');
  AssertEqStr(DecisionURL(Backend(dbSystemOne, '')),
    'https://api.typesafe.ai/v1/systemone', 'systemone default');
  AssertEqStr(DecisionURL(Backend(dbSystemOne, 'http://gpu-box:8080')),
    'http://gpu-box:8080/v1/systemone', 'systemone, OpenJev on a host');
  AssertEqStr(DecisionURL(Backend(dbSystemOne, 'http://gpu-box:8080/v1/')),
    'http://gpu-box:8080/v1/systemone', 'systemone, base already has /v1');
  Ok('URLs for both wire formats, with or without the version path on the base');
end;

procedure TestBodies;
var
  Qs: TDecisionQuestions;
  G, S: string;
  O, QM, Q, C: TJsonObject;
  A: TJsonArray;
begin
  Qs := Questions3;
  Qs[0].TrueDesc := 'yes, code';
  Qs[0].FalseDesc := 'no code';
  G := BuildDecisionBody(Backend(dbGoogle, ''), 'User: rename cnt', Qs);
  S := BuildDecisionBody(Backend(dbSystemOne, ''), 'User: rename cnt', Qs);

  O := TJsonObject.Parse(G);
  try
    AssertEqStr(O.GetStr('model', ''), 'gemini-decision-1', 'google default model');
    AssertEqStr(O.GetStr('input', ''), 'User: rename cnt', 'google sends input');
    AssertTrue(not O.Has('state'), 'google does not send state');
    QM := O.ChildObject('questions');
    try
      Q := QM.ChildObject('is_code_change');
      try
        AssertEqStr(Q.GetStr('type', ''), 'noul', 'noul type');
        C := Q.ChildObject('criteria');
        try
          AssertEqStr(C.GetStr('true_description', ''), 'yes, code', 'google noul criteria');
        finally C.Free; end;
      finally Q.Free; end;
      Q := QM.ChildObject('difficulty');
      try
        C := Q.ChildObject('criteria');
        try
          AssertEqStr(C.GetStr('moderate', ''), 'a small feature or fix across a few places',
            'choice criteria map option -> description');
        finally C.Free; end;
      finally Q.Free; end;
      Q := QM.ChildObject('risk');
      try
        A := Q.ChildArray('criteria');
        try
          AssertTrue((A <> nil) and (A.Count = 3) and (A.ItemStr(0) = 'no risk'),
            'score criteria are the levels, lowest first');
        finally A.Free; end;
      finally Q.Free; end;
    finally QM.Free; end;
  finally O.Free; end;

  O := TJsonObject.Parse(S);
  try
    AssertEqStr(O.GetStr('model', ''), 'jev-latest', 'systemone default model');
    AssertEqStr(O.GetStr('state', ''), 'User: rename cnt', 'systemone sends state');
    AssertTrue(not O.Has('input'), 'systemone does not send input');
    QM := O.ChildObject('questions');
    try
      Q := QM.ChildObject('is_code_change');
      try
        C := Q.ChildObject('criteria');
        try
          AssertEqStr(C.GetStr('true', ''), 'yes, code', 'systemone noul criteria are true/false');
          AssertEqStr(C.GetStr('false', ''), 'no code', 'both of them');
        finally C.Free; end;
      finally Q.Free; end;
    finally QM.Free; end;
  finally O.Free; end;
  AssertLacks(S, 'true_description', 'systemone does not get google''s noul field names');
  Ok('request bodies: input vs state, criteria per kind and vendor, default models');
end;

procedure TestParseLive;
var
  Qs: TDecisionQuestions;
  A: TDecisionAnswers;
  Tok: Int64;
  Err: string;
begin
  Qs := Questions3;
  AssertTrue(ParseDecisionResponse(LiveResponse, Qs, A, Tok, Err), 'live response parses: ' + Err);
  AssertTrue(Length(A) = 3, 'three answers');
  AssertTrue(Tok = 260, 'input tokens from usage');
  { noul }
  AssertEqStr(A[0].Key, 'is_code_change', 'answers come back in question order');
  AssertNear(A[0].Value, 0.985963953010753, 'noul value is P(yes)');
  AssertNear(A[0].Probs[1], 0.985963953010753, 'noul Probs[1] = P(yes)');
  AssertNear(A[0].Top, 0.985963953010753, 'noul Top = max(p, 1-p)');
  { choice: probabilities in the question's option order }
  AssertEqStr(A[1].Choice, 'trivial', 'choice picks the most likely option');
  AssertNear(A[1].Probs[0], 0.9431281677916588, 'choice Probs[0] is trivial');
  AssertNear(A[1].Probs[2], 0.004272833688555002, 'choice Probs[2] is hard');
  AssertNear(A[1].Top, 0.9431281677916588, 'choice Top');
  { score: probability-weighted level, Top = the most likely level }
  AssertNear(A[2].Value, 0*0.46562374049673666 + 1*0.3893163641167347 + 2*0.14505989538652858,
    'score value is the probability-weighted level');
  AssertTrue(Abs(A[2].Value - 0.6794361548897918) < 1e-4, 'and agrees with the vendor''s score');
  AssertNear(A[2].Top, 0.46562374049673666, 'score Top is the most likely level''s probability');
  Ok('a live Gemini Decision 1 response: noul, choice and score answers, usage');

  { Vendors disagree on what `confidence` means, so Top must come from the
    probabilities. The live fixture's score confidence happens to equal
    its top probability; give it a different one and Top must not move. }
  AssertTrue(ParseDecisionResponse(StringReplace(LiveResponse, '"confidence":0.46562374049673666',
    '"confidence":0.123', []), Qs, A, Tok, Err), 'variant parses: ' + Err);
  AssertNear(A[2].Top, 0.46562374049673666, 'Top ignores the vendor''s confidence');
  Ok('Top is the top probability, whatever the vendor calls confidence');

  { The same questions with the noul answer for a different key: the
    response is short an answer. }
  AssertTrue(not ParseDecisionResponse(StringReplace(LiveResponse, '"is_code_change"', '"other"', []),
    Qs, A, Tok, Err), 'a missing answer fails');
  AssertContains(Err, 'is_code_change', 'and names the question');
  AssertTrue(not ParseDecisionResponse(StringReplace(LiveResponse, '"type":"choice"', '"type":"score"', []),
    Qs, A, Tok, Err), 'an answer of the wrong kind fails');
  AssertTrue(not ParseDecisionResponse(StringReplace(LiveResponse, '"probabilities":{"hard"', '"probs":{"hard"', []),
    Qs, A, Tok, Err), 'a choice with no probabilities fails');
  AssertTrue(not ParseDecisionResponse('<html>', Qs, A, Tok, Err), 'not JSON fails');
  AssertTrue(not ParseDecisionResponse('{"error":{"code":400}}', Qs, A, Tok, Err), 'no answers fails');
  Ok('a response short an answer, of the wrong kind, without probabilities, or not JSON is an error');
end;

function Cfg(const JSON: string): TConfig;
begin
  Result := TConfig.Create;
  Result.FromJSON(JSON);
end;

procedure TestResolve;
var
  C: TConfig;
  B: TDecisionBackend;
  Err: string;
begin
  C := Cfg('{"providers":[{"name":"gem","kind":"gemini","api_base":"https://g.example","api_key":"gk"}],' +
           '"decision_models":{"backends":[' +
           '{"name":"gd","kind":"google","provider":"gem"},' +
           '{"name":"oj","kind":"systemone","provider":"gem","api_base":"http://gpu:8080","model":"openjev-latest"},' +
           '{"name":"bad","kind":"telepathy","api_key":"x"},' +
           '{"name":"nokey","kind":"google"},' +
           '{"name":"ghost","kind":"google","provider":"nope"}]}}');
  try
    AssertTrue(ResolveDecisionBackend(C, 'gd', B, Err), 'gd resolves: ' + Err);
    AssertEqStr(B.APIKey, 'gk', 'google backend borrows the provider''s key');
    AssertEqStr(B.APIBase, 'https://g.example', 'and its base');
    AssertEqStr(B.Model, 'gemini-decision-1', 'and gets the default model');
    AssertTrue(ResolveDecisionBackend(C, 'oj', B, Err), 'oj resolves: ' + Err);
    AssertEqStr(B.APIBase, 'http://gpu:8080', 'systemone keeps its own base');
    AssertEqStr(B.Model, 'openjev-latest', 'and its model');
    AssertTrue(not ResolveDecisionBackend(C, 'bad', B, Err), 'unknown kind');
    AssertContains(Err, 'telepathy', 'names the kind');
    AssertTrue(not ResolveDecisionBackend(C, 'nokey', B, Err), 'no key');
    AssertContains(Err, 'api_key', 'says so');
    AssertTrue(not ResolveDecisionBackend(C, 'ghost', B, Err), 'unknown provider');
    AssertTrue(not ResolveDecisionBackend(C, 'absent', B, Err), 'unknown backend');
  finally
    C.Free;
  end;
  Ok('backends resolve from config, borrowing a provider; bad kind / no key / unknown names fail');
end;

function Run(const Backend_, Model, BaselineKind: string; Cand, Base: Double; Pass: Boolean): TDecisionBenchRecord;
begin
  Result := Default(TDecisionBenchRecord);
  Result.Point := 'rerank';
  Result.Backend := Backend_;
  Result.Kind := 'google';
  Result.Model := Model;
  Result.BaselineKind := BaselineKind;
  Result.Baseline := BaselineKind + ':test';
  Result.N := 60;
  Result.Metric := 'mrr';
  Result.CandidateValue := Cand;
  Result.BaselineValue := Base;
  Result.Margin := 0.02;
  Result.Pass := Pass;
  Result.At := '2026-11-14T00:00:00Z';
  Result.DetailJSON := '{"hit1":0.5}';
end;

procedure TestGate;
var
  C: TConfig;
  B: TDecisionBackend;
  Why, Err: string;
  Runs: TDecisionBenchRecords;
begin
  DeleteFile(DecisionBenchPath('rerank'));
  C := Cfg('{"decision_models":{"backends":[{"name":"gd","kind":"google","api_key":"k"}]}}');
  try
    AssertTrue(not DecisionGate(C, 'rerank', 'llm:test', B, Why), 'nothing selected: shut');
    AssertContains(Why, 'no decision backend selected', 'says nothing is selected');
  finally C.Free; end;

  C := Cfg('{"decision_models":{"backends":[{"name":"gd","kind":"google","api_key":"k"}],"points":{"rerank":"gd"}}}');
  try
    AssertTrue(not DecisionGate(C, 'rerank', 'llm:test', B, Why), 'selected, never benchmarked: shut');
    AssertContains(Why, 'pasclaw decision-model bench rerank', 'says how to open it');

    AssertTrue(SaveDecisionBenchRecord(Run('gd', 'gemini-decision-1', 'llm', 0.80, 0.79, False), Err), Err);
    AssertTrue(not DecisionGate(C, 'rerank', 'llm:test', B, Why), 'a failing run: shut');
    AssertContains(Why, 'did not beat', 'says it did not beat the baseline');

    AssertTrue(SaveDecisionBenchRecord(Run('gd', 'gemini-decision-1', 'llm', 0.90, 0.79, True), Err), Err);
    Runs := LoadDecisionBenchRecords('rerank');
    AssertTrue(Length(Runs) = 1, 'the newer run replaced the older one for the same backend, model, baseline');
    AssertTrue(Runs[0].DetailJSON <> '', 'detail survives the round trip');
    AssertTrue(DecisionGate(C, 'rerank', 'llm:test', B, Why), 'a passing run against llm:test: open for it. ' + Why);
    AssertEqStr(B.Name, 'gd', 'and hands back the backend');
    AssertTrue(not DecisionGate(C, 'rerank', 'local:test', B, Why), 'but not for local: it never beat that');
    AssertTrue(not DecisionGate(C, 'rerank', 'llm:bigger-model', B, Why),
      'nor for another chat model: a win over one model says nothing about another');

    AssertTrue(SaveDecisionBenchRecord(Run('gd', 'gemini-decision-2', 'local', 0.95, 0.70, True), Err), Err);
    AssertTrue(Length(LoadDecisionBenchRecords('rerank')) = 2, 'a run for another model is kept beside it');
    AssertTrue(not DecisionGate(C, 'rerank', 'local:test', B, Why),
      'a pass for another model does not open the gate for this one');
  finally C.Free; end;

  C := Cfg('{"decision_models":{"backends":[{"name":"gd","kind":"google","api_key":"k"}],' +
           '"points":{"rerank":"gd"},"require_bench":false}}');
  try
    AssertTrue(DecisionGate(C, 'rerank', 'local:test', B, Why), 'require_bench off: open without a run');
    AssertContains(Why, 'require_bench is off', 'and says why');
  finally C.Free; end;

  WriteFileText(DecisionBenchPath('rerank'), '{not json');
  C := Cfg('{"decision_models":{"backends":[{"name":"gd","kind":"google","api_key":"k"}],"points":{"rerank":"gd"}}}');
  try
    AssertTrue(not DecisionGate(C, 'rerank', 'llm:test', B, Why), 'a damaged record file reads as no runs');
  finally C.Free; end;
  Ok('the gate: shut until a passing run against this exact baseline, for this model');
end;

procedure TestConfig;
var
  C, C2: TConfig;
  J, Masked, Restored: string;
begin
  C := Cfg('{"decision_models":{"backends":[{"name":"gd","kind":"google","provider":"gem"},' +
           '{"name":"oj","kind":"systemone","api_base":"http://gpu:8080","api_key":"secret-oj","model":"openjev-latest"}],' +
           '"points":{"rerank":"gd","Router":"oj"},"require_bench":false}}');
  try
    AssertTrue(Length(C.DecisionModels.Backends) = 2, 'two backends');
    AssertTrue(Length(C.DecisionModels.Points) = 2, 'two points');
    AssertEqStr(DecisionPointBackendName(C, 'router'), 'oj', 'point names are case-insensitive');
    AssertTrue(not C.DecisionModels.RequireBench, 'require_bench read');
    J := C.ToJSON;
    C2 := Cfg(J);
    try
      AssertTrue(Length(C2.DecisionModels.Backends) = 2, 'backends survive a save');
      AssertEqStr(C2.DecisionModels.Backends[1].APIKey, 'secret-oj', 'with their key');
      AssertEqStr(C2.DecisionModels.Backends[0].Provider, 'gem', 'and provider');
      AssertEqStr(DecisionPointBackendName(C2, 'rerank'), 'gd', 'points survive a save');
      AssertTrue(not C2.DecisionModels.RequireBench, 'require_bench survives a save');
    finally C2.Free; end;
  finally C.Free; end;

  C := TConfig.Create;
  try
    AssertTrue(C.DecisionModels.RequireBench, 'require_bench defaults on');
    AssertLacks(C.ToJSON, '"decision_models"', 'an untouched config writes no decisions block');
  finally C.Free; end;

  { The operator's `decisions` block (Needs you: channel, answer_from) is a
    different feature with the neighbouring name; both must survive a load
    and a save side by side. }
  C := Cfg('{"decisions":{"channel":"ops","answer_from":["telegram:1"]},' +
           '"decision_models":{"backends":[{"name":"gd","kind":"google","api_key":"k"}],"points":{"rerank":"gd"}}}');
  try
    C2 := Cfg(C.ToJSON);
    try
      AssertEqStr(C2.DecisionsChannel, 'ops', 'the operator decisions channel survives beside decision_models');
      AssertTrue((Length(C2.DecisionsAnswerFrom) = 1) and (C2.DecisionsAnswerFrom[0] = 'telegram:1'),
        'and its answer_from');
      AssertEqStr(DecisionPointBackendName(C2, 'rerank'), 'gd', 'and decision_models survives beside it');
    finally C2.Free; end;
  finally C.Free; end;

  Masked := MaskConfigSecretsJSON(J);
  AssertLacks(Masked, 'secret-oj', 'the key is masked');
  AssertContains(Masked, 'http://gpu:8080', 'and nothing else is');
  Restored := RestoreMaskedConfigSecrets(Masked, J);
  AssertContains(Restored, 'secret-oj', 'a save that kept the mask gets the key back, matched by name');
  Ok('config: decisions loads, saves and round-trips; its api_key is masked and restored');
end;

{ The first live bench lost two questions to a request body Google
  refused as invalid JSON: an 800-byte cut through a multi-byte character. }
procedure TestRerankQuestionsUTF8;
var
  Doc: string;
  Qs: TDecisionQuestions;
  i: Integer;
begin
  Doc := StringOfChar('a', DECISION_RERANK_DOC_CAP - 1) + #$E2#$80#$94 + ' tail';  { an em dash across the cap }
  Qs := DecisionRerankQuestions([Doc, 'short ' + #$E2#$86#$92 + ' arrow']);
  for i := 0 to High(Qs) do
    AssertTrue(BytesAreValidUTF8(BytesOf(Qs[i].Instructions)),
      'rerank question ' + IntToStr(i) + ' is valid UTF-8');
  AssertTrue(BytesAreValidUTF8(BytesOf(BuildDecisionBody(Backend(dbGoogle, ''), 'Question: q', Qs))),
    'and so is the request body');
  AssertLacks(Qs[0].Instructions, ' tail', 'the passage is still cut at the cap');
  Ok('rerank questions cut passages on a character boundary: the body stays valid UTF-8');
end;

{ The verdict needs the margin AND a paired lower bound above zero. The
  first live run's per-question gains (decision model vs a chat reranker,
  60 questions: better on 5, worse on 4, 51 ties) cleared the margin --
  0.021 MRR -- and are exactly the case the lower bound is for. }
procedure TestVerdict;
var
  Live, AllWin: array of Double;
  i: Integer;
  Low, Mean: Double;
begin
  SetLength(Live, 60);
  for i := 0 to 59 do Live[i] := 0;
  Live[0] := 1/3 - 1/2;  Live[1] := 1 - 1/2;  Live[2] := 1 - 1/2;  Live[3] := 1 - 1/2;
  Live[4] := 1 - 1/2;    Live[5] := 1/2 - 1;  Live[6] := 1/3 - 1;  Live[7] := 1/3 - 1/2;
  Live[8] := 1 - 1/4;
  Mean := 0;
  for i := 0 to 59 do Mean := Mean + Live[i];
  Mean := Mean / 60;
  AssertTrue(Mean >= 0.02, 'premise: the live gains clear the 0.02 margin');
  Low := PairedBootstrapLow(Live, 2000, 20261115, 0.05);
  AssertTrue(Low <= 0, Format('a 5-4 split is not evidence: lower bound %.3f must be <= 0', [Low]));
  AssertTrue(not RerankVerdict(0.950, 0.929, 0.02, Low), 'so the verdict is NOT PASSED despite the margin');
  AssertTrue(PairedBootstrapLow(Live, 2000, 20261115, 0.05) = Low, 'and the bootstrap is reproducible');

  SetLength(AllWin, 60);
  for i := 0 to 59 do if i < 12 then AllWin[i] := 0.5 else AllWin[i] := 0;
  Low := PairedBootstrapLow(AllWin, 2000, 20261115, 0.05);
  AssertTrue(Low > 0, Format('better on 12, worse on none: lower bound %.3f > 0', [Low]));
  AssertTrue(RerankVerdict(0.95, 0.85, 0.02, Low), 'passes');
  AssertTrue(not RerankVerdict(0.86, 0.85, 0.02, Low), 'but not under the margin');
  AssertTrue(PairedBootstrapLow([], 2000, 1, 0.05) = 0, 'no questions: 0, no pass');
  Ok('verdict: the margin and a paired bootstrap lower bound above zero -- a 5-4 split does not pass');
end;

begin
  TestURLs;
  TestVerdict;
  TestRerankQuestionsUTF8;
  TestBodies;
  TestParseLive;
  TestResolve;
  TestGate;
  TestConfig;
  WriteLn('decision_models_tests: OK');
end.
