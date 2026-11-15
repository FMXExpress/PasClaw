(*
  PasClaw.Memory.Rerank.Decision - rerank with a decision model.

  One request per rerank: the query is the shared input, and each
  candidate is one `score` question -- "how well does this passage answer
  the question?" on a four-level scale -- with the passage in the
  question. The candidates are ordered by the probability-weighted level.
  Nothing is generated and nothing is parsed out of prose: the reply is
  a probability per level per passage.

  Whether this beats the reranker a point would otherwise use is not
  assumed anywhere: /v1/rerank calls it only when PasClaw.DecisionModels.Gate
  says a `pasclaw decision-model bench rerank` run showed it does.
*)
unit PasClaw.Memory.Rerank.Decision;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Intf,
  PasClaw.DecisionModels;

const
  DECISION_RERANK_DOC_CAP = 800;   { characters of each candidate sent }

{ Rank ADocs against AQuery with backend B. Order is every doc index, most
  relevant first; Scores the matching relevance in 0..1 (the weighted
  level over the top level). False with Err when the call fails -- the
  caller keeps its own order. }
function DecisionRerank(const B: TDecisionBackend; const AQuery: string;
  const ADocs: array of string; out Order: TArray<Integer>;
  out Scores: TArray<Single>; out InputTokens, ElapsedMs: Int64;
  out Err: string): Boolean;

{ The name of the reranker a /v1/rerank request gets without a decision
  model -- what a bench records as its baseline and what the gate is
  asked about, so the two always agree: `llm:<provider>/<model>` (Model
  empty = the provider's default) or `local:<reranker model id>`. }
function RerankBaselineName(UseLocal: Boolean; const Prov: ILLMProvider;
  const Model, HomeDir: string): string;

{ The questions DecisionRerank asks, for tests. }
function DecisionRerankQuestions(const ADocs: array of string): TDecisionQuestions;

implementation

uses
  PasClaw.Utils,
  PasClaw.Memory.Rerank.Serve;

function RerankBaselineName(UseLocal: Boolean; const Prov: ILLMProvider;
  const Model, HomeDir: string): string;
var
  Id: string;
begin
  if UseLocal then
  begin
    Id := '';
    LocalRerankModelInfo(HomeDir, Id);
    Result := 'local:' + Id;
  end
  else if not Assigned(Prov) then
    Result := 'llm:'
  else if Model <> '' then
    Result := 'llm:' + Prov.GetName + '/' + Model
  else
    Result := 'llm:' + Prov.GetName + '/' + Prov.GetDefaultModel;
end;

const
  Levels: array[0..3] of string = (
    'does not help answer the question',
    'on the topic but does not answer the question',
    'partly answers the question',
    'directly answers the question');

function DecisionRerankQuestions(const ADocs: array of string): TDecisionQuestions;
var
  i: Integer;
  Doc: string;
begin
  SetLength(Result, Length(ADocs));
  for i := 0 to High(ADocs) do
  begin
    { Utf8SafeTruncate, not Copy: under FPC a string is bytes, and a cut
      through a multi-byte character makes the request body invalid UTF-8,
      which the vendor refuses outright (the first live bench lost two
      questions to it). }
    Doc := Utf8SafeTruncate(ADocs[i], DECISION_RERANK_DOC_CAP);
    Result[i] := ScoreQuestion('p' + IntToStr(i),
      'How well does this passage answer the question?' + #10#10 +
      'Passage:' + #10 + Doc,
      Levels);
  end;
end;

function DecisionRerank(const B: TDecisionBackend; const AQuery: string;
  const ADocs: array of string; out Order: TArray<Integer>;
  out Scores: TArray<Single>; out InputTokens, ElapsedMs: Int64;
  out Err: string): Boolean;
var
  Qs: TDecisionQuestions;
  R: TDecisionResult;
  V: array of Double;
  i, j, T: Integer;
begin
  Result := False;
  Order := nil;
  Scores := nil;
  InputTokens := 0;
  ElapsedMs := 0;
  Err := '';
  if Length(ADocs) = 0 then
  begin
    Err := 'no documents';
    Exit;
  end;
  Qs := DecisionRerankQuestions(ADocs);
  R := Decide(B, 'Question: ' + AQuery, Qs);
  ElapsedMs := R.ElapsedMs;
  InputTokens := R.InputTokens;
  if not R.Ok then
  begin
    Err := R.Error;
    Exit;
  end;
  SetLength(V, Length(ADocs));
  SetLength(Order, Length(ADocs));
  for i := 0 to High(ADocs) do
  begin
    V[i] := R.Answers[i].Value;
    Order[i] := i;
  end;
  { Stable insertion sort, highest first: ties keep the caller's order. }
  for i := 1 to High(Order) do
  begin
    T := Order[i];
    j := i - 1;
    while (j >= 0) and (V[Order[j]] < V[T]) do
    begin
      Order[j + 1] := Order[j];
      Dec(j);
    end;
    Order[j + 1] := T;
  end;
  SetLength(Scores, Length(Order));
  for i := 0 to High(Order) do
    Scores[i] := V[Order[i]] / High(Levels);
  Result := True;
end;

end.
