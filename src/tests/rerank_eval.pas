program rerank_eval;
(*
  Retrieval reranking eval -- quantifies the lift the local cross-encoder gives
  over the bi-encoder (embedding cosine) ordering, in MRR and recall@5.

  For each labeled case (a query + candidate docs + which candidates are
  relevant) it produces two rankings of the SAME candidates:
    * baseline  -- sort by embedding cosine (what stage 1 / RRF's vector half
                   effectively does);
    * reranked  -- the cross-encoder's (query, doc) relevance order.
  and reports MRR (mean reciprocal rank of the first relevant hit) and mean
  recall@5 for each, plus the delta. A positive delta is the reranker earning
  its keep.

  This is an OPERATOR tool, not a CI unit test: meaningful numbers need the
  embedding model AND the reranker model provisioned (`pasclaw memory provision
  --rerank`) on a host with a loadable ONNX Runtime. Without them it prints a
  SKIP line and exits 0, so `make test-rerank-eval` stays green everywhere and
  gives the program continuous compile coverage.

  Usage:
    PASCLAW_HOME=/path/to/provisioned/home  rerank_eval
  The built-in dataset is a small, deliberately adversarial set where keyword
  overlap and semantic relevance disagree -- exactly where a cross-encoder is
  supposed to help. Point it at a real corpus by editing BuildCases (or wiring
  a JSONL loader) for a domain-specific read.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Math,
  PasClaw.Config,
  PasClaw.Memory.Facts.Embed,
  PasClaw.Memory.Rerank.Serve;

type
  TEvalCase = record
    Query: string;
    Docs:  TArray<string>;
    Rel:   TArray<Integer>;   { indices into Docs that are relevant }
  end;

function C(const AQuery: string; const ADocs: array of string;
  const ARel: array of Integer): TEvalCase;
var i: Integer;
begin
  Result.Query := AQuery;
  SetLength(Result.Docs, Length(ADocs));
  for i := 0 to High(ADocs) do Result.Docs[i] := ADocs[i];
  SetLength(Result.Rel, Length(ARel));
  for i := 0 to High(ARel) do Result.Rel[i] := ARel[i];
end;

function BuildCases: TArray<TEvalCase>;
begin
  { Deliberately hard cases: each query has strong LEXICAL distractors (docs
    that share the query's keywords but answer a different question) and a
    relevant doc that is semantically right but shares few surface words --
    the regime where surface overlap and true relevance disagree.

    MEASURED (2026-07, these 6 cases, ONNX Runtime provisioned):
      bi-encoder (MiniLM) baseline        MRR 0.778   recall@5 0.833
      ms-marco-MiniLM-L-6  (local ONNX)   MRR 0.639   recall@5 0.417   (regresses)
      ms-marco-MiniLM-L-12 (local ONNX)   MRR 0.611   recall@5 0.417   (regresses)
      bge-reranker-base    (int8, local)  MRR 0.778   recall@5 0.917   (best local)
      jina-reranker-v2     (int8, local)  MRR 0.722   recall@5 0.833   (competitive)
      LLM backend (Gemini 2.5 Flash)      MRR 1.000   recall@5 1.000   (perfect)
    Takeaway: the small ms-marco cross-encoders REWARD query/passage lexical
    overlap, so on these deliberately lexical-vs-semantic cases they rank a
    topical-but-wrong passage above a correctly-phrased answer and lose to the
    bi-encoder -- a bigger L-12 does not fix it. The XLM-RoBERTa bge-reranker
    (SentencePiece tokenizer, LocalVector.SentencePiece) is the strongest LOCAL
    option -- it doesn't regress MRR and lifts recall@5 -- and int8 is
    CPU-practical. jina-reranker-v2-base-multilingual (same SentencePiece path)
    is competitive but edged out bge at int8 here -- on a 6-case set that is
    within noise, and jina rates higher on public benchmarks, so it is offered
    as a peer local option (notably multilingual). The LLM backend
    (PasClaw.Memory.Rerank.LLM) still tops them all by reading query+passages
    together and reasoning. So: 'llm'/'auto' for the best quality;
    bge-reranker / jina-reranker-v2 as the strong offline models; ms-marco as
    the tiny no-frills fallback. Relevant indices below are the docs that, to a
    human, answer the query. }
  Result := TArray<TEvalCase>.Create(
    C('how do I stop being billed every month',
      ['Your subscription renews automatically every month on the billing date.',   { lexical decoy: "billed/month" }
       'We accept every major card for monthly billing and annual billing.',        { lexical decoy }
       'Open Settings, choose your plan, and select End plan to halt renewals.',     { relevant, low overlap }
       'Monthly usage reports are emailed on the first of every month.',             { decoy }
       'Billing history shows each monthly charge for the past two years.',          { decoy }
       'To avoid further charges, turn off auto-renew before the next cycle.',        { relevant, low overlap }
       'Our monthly newsletter covers billing tips and product news.'],              { decoy }
      [2, 5]),

    C('the app is slow to start up',
      ['Startup speed depends on how many extensions load at launch.',              { relevant-ish but generic }
       'The app store rating improved after our latest update.',                    { decoy: "app" }
       'Cold launches are slow because the on-disk cache is rebuilt each time; ' +
         'clear stale plugins to speed the first frame.',                           { relevant, low overlap }
       'Slow-motion video capture starts at 120 frames per second.',               { decoy: "slow/start" }
       'Start your free trial today -- no card required.',                          { decoy: "start" }
       'Disable auto-loading of large workspaces to cut launch time.',             { relevant, low overlap }
       'The startup company raised a slow but steady seed round.'],                 { decoy: "startup/slow" }
      [2, 5]),

    C('I never got the confirmation email',
      ['Check your spam folder -- delivery filters sometimes divert our mail.',      { relevant, low overlap }
       'Confirmation emails are sent within five minutes of signup.',               { lexical decoy }
       'You can change the email address on your confirmed account anytime.',        { decoy }
       'If it still has not arrived, resend it from the account page.',              { relevant, low overlap }
       'We confirmed your email preferences: newsletters are on.',                  { decoy }
       'The confirmation number is printed at the top of every email receipt.',      { decoy }
       'Marketing emails can be turned off without affecting confirmations.'],       { decoy }
      [0, 3]),

    C('reset a forgotten password',
      ['Passwords must be at least 12 characters and include a symbol.',            { lexical decoy }
       'Use the "Forgot password" link on sign-in to receive a recovery link.',      { relevant }
       'We store passwords hashed with bcrypt, never in plaintext.',                { decoy }
       'Hold the power button ten seconds to reset the device to factory state.',    { decoy: "reset" }
       'If you did not request a reset, you can safely ignore that email.',          { decoy: "reset" }
       'An admin can send you a one-time recovery link from the console.',           { relevant, low overlap }
       'Reset your usage limits by upgrading to the pro tier.'],                     { decoy: "reset" }
      [1, 5]),

    C('why does the build fail to link',
      ['A build fails to link when a referenced symbol is declared but never ' +
         'defined -- add the object or library that provides it.',                  { relevant }
       'Nightly builds run on the CI server at 2am UTC.',                           { decoy: "build" }
       'The new office building has a rooftop garden and a link bridge.',            { decoy: "building/link" }
       'Pass the correct -l flags so the linker can find each dependency.',          { relevant, low overlap }
       'Link your account to GitHub to enable build status badges.',                { decoy: "link/build" }
       'Compiler warnings are unrelated to linker errors.',                         { decoy }
       'Faster builds come from caching, not from changing linker flags.'],          { decoy }
      [0, 3]),

    C('can I get a refund for something I already opened',
      ['Unopened items qualify for a full refund within 30 days.',                  { lexical decoy: "refund" }
       'Opened products are eligible only for store credit, not a cash refund.',     { relevant }
       'Refunds are processed to the original card in five business days.',          { decoy }
       'Once a sealed item is opened it can be exchanged but not fully refunded.',   { relevant, low overlap }
       'We opened three new stores this year.',                                     { decoy: "opened" }
       'Gift receipts let the recipient get store credit for any return.',           { decoy }
       'Final-sale items are never refundable, opened or not.'],                    { decoy }
      [1, 3])
  );
end;

function Dot(const A, B: TArray<Single>): Single;
var i: Integer;
begin
  Result := 0;
  for i := 0 to Min(High(A), High(B)) do
    Result := Result + A[i] * B[i];
end;

{ Baseline ranking: candidate indices ordered by embedding cosine descending.
  LocalEmbed returns unit-normalised vectors, so dot product == cosine. }
function BaselineOrder(const HomeDir: string; const ACase: TEvalCase;
  out AOk: Boolean): TArray<Integer>;
var
  QVec, DVec: TArray<Single>;
  Scores: TArray<Single>;
  i, j, ti: Integer;
  tf: Single;
begin
  AOk := False;
  SetLength(Result, Length(ACase.Docs));
  SetLength(Scores, Length(ACase.Docs));
  if not LocalEmbed(HomeDir, ACase.Query, QVec) then Exit;
  for i := 0 to High(ACase.Docs) do
  begin
    if not LocalEmbed(HomeDir, ACase.Docs[i], DVec) then Exit;
    Result[i] := i;
    Scores[i] := Dot(QVec, DVec);
  end;
  { insertion sort by score desc (candidate lists are tiny) }
  for i := 1 to High(Result) do
  begin
    j := i - 1; ti := Result[i]; tf := Scores[i];
    while (j >= 0) and (Scores[j] < tf) do
    begin
      Scores[j + 1] := Scores[j];
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    Scores[j + 1] := tf;
    Result[j + 1] := ti;
  end;
  AOk := True;
end;

function SignedDelta(V: Double): string;
begin
  if V >= 0 then Result := '+' + Format('%.3f', [V])
  else           Result := Format('%.3f', [V]);
end;

function IsRel(const ACase: TEvalCase; AIdx: Integer): Boolean;
var r: Integer;
begin
  Result := False;
  for r in ACase.Rel do
    if r = AIdx then Exit(True);
end;

{ Reciprocal rank of the first relevant hit in the ordered candidate list. }
function RR(const ACase: TEvalCase; const AOrder: TArray<Integer>): Double;
var rank: Integer;
begin
  Result := 0;
  for rank := 0 to High(AOrder) do
    if IsRel(ACase, AOrder[rank]) then
      Exit(1.0 / (rank + 1));
end;

{ Fraction of this case's relevant docs that land in the top 5. }
function Recall5(const ACase: TEvalCase; const AOrder: TArray<Integer>): Double;
var rank, hit, top: Integer;
begin
  if Length(ACase.Rel) = 0 then Exit(0);
  hit := 0;
  top := Min(5, Length(AOrder));
  for rank := 0 to top - 1 do
    if IsRel(ACase, AOrder[rank]) then Inc(hit);
  Result := hit / Length(ACase.Rel);
end;

var
  Home, RerankModelId: string;
  Cfg: TConfig;
  Cases: TArray<TEvalCase>;
  Ci: Integer;
  BaseOrder, RerankOrder: TArray<Integer>;
  RerankScores: TArray<Single>;
  Ok: Boolean;
  MrrBase, MrrRerank, Rec5Base, Rec5Rerank: Double;
  N: Integer;
begin
  Home := GetHome;

  { Apply config so the configured rerank_model (SetLocalRerankModel, via
    ApplyConfigGlobals) is honoured -- lets operators A/B different rerankers
    just by changing rerank_model in config.json. }
  Cfg := LoadConfig;
  Cfg.Free;

  if not LocalEmbedAvailable(Home) then
  begin
    WriteLn('SKIP: embedding model not provisioned -- run `pasclaw memory provision`.');
    WriteLn('rerank_eval: SKIPPED');
    Halt(0);
  end;
  { The eval uses LocalRerank (raw reranker API); it does not depend on the
    rerank_search_enabled toggle, only on the model being provisioned. }
  if not LocalRerankAvailable(Home) then
  begin
    WriteLn('SKIP: reranker model not provisioned -- run `pasclaw memory provision --rerank`.');
    WriteLn('rerank_eval: SKIPPED');
    Halt(0);
  end;

  Cases := BuildCases;
  N := 0;
  MrrBase := 0; MrrRerank := 0; Rec5Base := 0; Rec5Rerank := 0;

  RerankModelId := '';
  LocalRerankModelInfo(Home, RerankModelId);
  WriteLn('Retrieval reranking eval (', Length(Cases), ' cases)');
  WriteLn('  home:     ', Home);
  WriteLn('  reranker: ', RerankModelId);
  WriteLn;
  WriteLn(Format('  %-40s  %8s  %8s', ['query', 'RR base', 'RR rrk']));

  for Ci := 0 to High(Cases) do
  begin
    BaseOrder := BaselineOrder(Home, Cases[Ci], Ok);
    if not Ok then
    begin
      WriteLn('  (embed failed for a doc -- skipping case)');
      Continue;
    end;
    if not LocalRerank(Home, Cases[Ci].Query, Cases[Ci].Docs,
                       RerankOrder, RerankScores) then
    begin
      WriteLn('  (rerank failed -- skipping case)');
      Continue;
    end;

    Inc(N);
    MrrBase    := MrrBase    + RR(Cases[Ci], BaseOrder);
    MrrRerank  := MrrRerank  + RR(Cases[Ci], RerankOrder);
    Rec5Base   := Rec5Base   + Recall5(Cases[Ci], BaseOrder);
    Rec5Rerank := Rec5Rerank + Recall5(Cases[Ci], RerankOrder);

    WriteLn(Format('  %-40s  %8.3f  %8.3f',
      [Copy(Cases[Ci].Query, 1, 40),
       RR(Cases[Ci], BaseOrder), RR(Cases[Ci], RerankOrder)]));
  end;

  if N = 0 then
  begin
    WriteLn('rerank_eval: no cases scored');
    Halt(1);
  end;

  WriteLn;
  { FPC's Format has no '+' flag, so sign the delta by hand. }
  WriteLn(Format('  MRR         base=%.3f  rerank=%.3f  delta=%s',
    [MrrBase / N, MrrRerank / N, SignedDelta((MrrRerank - MrrBase) / N)]));
  WriteLn(Format('  recall@5    base=%.3f  rerank=%.3f  delta=%s',
    [Rec5Base / N, Rec5Rerank / N, SignedDelta((Rec5Rerank - Rec5Base) / N)]));
  WriteLn;
  if MrrRerank >= MrrBase then
    WriteLn('rerank_eval: OK (reranker did not regress MRR)')
  else
    WriteLn('rerank_eval: WARN (reranker regressed MRR on this set)');
end.
