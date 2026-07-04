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
  Result := TArray<TEvalCase>.Create(
    C('how do I cancel my subscription',
      ['To end your plan, open Settings > Billing and choose Cancel plan.',
       'Subscriptions renew automatically each month on your billing date.',
       'Cancel culture has nothing to do with software billing.',
       'Our cancellation policy: you keep access until the period ends.',
       'Upgrade your subscription to unlock more seats.'],
      [0, 3]),

    C('why is my build failing with a linker error',
      ['A linker error usually means a symbol was declared but never defined.',
       'Builds run nightly on the CI server at 2am UTC.',
       'To fix "undefined reference", check you linked the library (-l flag).',
       'The building has three floors and a rooftop garden.',
       'Compiler warnings are not the same as linker errors.'],
      [0, 2]),

    C('reset a forgotten password',
      ['Click "Forgot password" on the sign-in page to get a reset link.',
       'Passwords must be at least 12 characters with a symbol.',
       'We hash passwords with bcrypt and never store them in plaintext.',
       'If you did not request a reset, ignore the email.',
       'Reset the device by holding the power button for 10 seconds.'],
      [0]),

    C('what is the return policy for opened items',
      ['Opened items can be returned within 14 days for store credit.',
       'Return the favor by leaving us a review.',
       'Unopened items get a full refund within 30 days.',
       'Items marked final sale cannot be returned once opened.',
       'Shipping is free on orders over fifty dollars.'],
      [0, 3])
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
  Home: string;
  Cases: TArray<TEvalCase>;
  Ci: Integer;
  BaseOrder, RerankOrder: TArray<Integer>;
  RerankScores: TArray<Single>;
  Ok: Boolean;
  MrrBase, MrrRerank, Rec5Base, Rec5Rerank: Double;
  N: Integer;
begin
  Home := GetHome;

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

  WriteLn('Retrieval reranking eval (', Length(Cases), ' cases)');
  WriteLn('  home: ', Home);
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
  WriteLn(Format('  MRR         base=%.3f  rerank=%.3f  delta=%+.3f',
    [MrrBase / N, MrrRerank / N, (MrrRerank - MrrBase) / N]));
  WriteLn(Format('  recall@5    base=%.3f  rerank=%.3f  delta=%+.3f',
    [Rec5Base / N, Rec5Rerank / N, (Rec5Rerank - Rec5Base) / N]));
  WriteLn;
  if MrrRerank >= MrrBase then
    WriteLn('rerank_eval: OK (reranker did not regress MRR)')
  else
    WriteLn('rerank_eval: WARN (reranker regressed MRR on this set)');
end.
