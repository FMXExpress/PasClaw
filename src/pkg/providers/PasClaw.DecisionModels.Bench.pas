(*
  PasClaw.DecisionModels.Bench - the arithmetic of `pasclaw decision-model bench`.

  A rerank set is JSONL, one question per line (bench/decision-models/README.md):

    {"id": "q00", "query": "...", "candidates": [{"id": "...", "text": "..."}],
     "relevant": [3], "bm25_rank": 4}

  candidates are in the first stage's order; relevant are the indices of
  the candidates that answer the query. Bring your own set in this shape
  to benchmark on your own data.

  A system's run over the set is a list of per-question outcomes: where
  the first relevant candidate landed in its order, how long it took,
  what it cost, and whether it failed. A failed call counts with the
  first-stage order -- that is what the point does when a rerank fails
  in production -- so an unreliable backend pays for its failures in
  the metric rather than dropping them.

  The verdict is on MRR (mean reciprocal rank of the first relevant
  candidate), and it takes two things: the candidate's MRR beats the
  baseline's by at least the margin, AND the gain is not noise -- the
  5th percentile of a paired bootstrap of the per-question gain is above
  zero. The second half is there because the first can be carried by one
  or two questions: on the first live run Gemini Decision 1 beat a chat
  reranker by 0.021 MRR while each was better on 5 and 4 questions, a coin
  flip. Hit@1 / Hit@3, latency and tokens are reported beside it, not
  voted on.
*)
unit PasClaw.DecisionModels.Bench;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TRerankCase = record
    Id, Query: string;
    DocIds, Docs: array of string;
    Relevant: array of Integer;
  end;
  TRerankCases = array of TRerankCase;

  TRankStats = record
    Name: string;
    N, Hit1, Hit3, Errors: Integer;
    SumRR: Double;
    { TArray, not `array of`: dcc64 treats two `array of Int64`
      declarations as different types (E2008 on Copy into a local). }
    LatMs: TArray<Int64>;
    InTok, OutTok: Int64;
  end;

{ Load a rerank set. False with Err (naming the line) on a malformed one. }
function LoadRerankSet(const Path: string; out Cases: TRerankCases;
  out SHA256Hex, Err: string): Boolean;

{ 1-based position of the first relevant index in Order; Length(Order)+1
  when none is there. }
function FirstRelevantRank(const Order, Relevant: array of Integer): Integer;

procedure InitStats(var S: TRankStats; const Name: string);
procedure AddOutcome(var S: TRankStats; const Order, Relevant: array of Integer;
  ElapsedMs: Int64; Failed: Boolean; InTok, OutTok: Int64);

function StatsMRR(const S: TRankStats): Double;
function StatsHit1(const S: TRankStats): Double;
function StatsHit3(const S: TRankStats): Double;
{ Latency percentile, P in 0..1, nearest-rank. 0 with no samples. }
function StatsPercentileMs(const S: TRankStats; P: Double): Int64;
{ One system's numbers as a JSON object (for the bench record). }
function StatsToJSON(const S: TRankStats): string;

{ The 5th-percentile (Quantile 0.05) mean of Diffs over Resamples paired
  bootstrap resamples, with a fixed-seed generator so a run is
  reproducible. 0 for no diffs. }
function PairedBootstrapLow(const Diffs: array of Double; Resamples: Integer;
  Seed: Cardinal; Quantile: Double): Double;

{ Pass: the candidate's MRR beats the baseline's by Margin, and the
  bootstrap lower bound of the per-question gain is above zero. }
function RerankVerdict(CandidateMRR, BaselineMRR, Margin, GainLow: Double): Boolean;

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Crypto.HMAC;

function LoadRerankSet(const Path: string; out Cases: TRerankCases;
  out SHA256Hex, Err: string): Boolean;
var
  Body, Line: string;
  Lines: TStringList;
  i, j, k: Integer;
  O, C: TJsonObject;
  Arr: TJsonArray;
  Cs: TRerankCase;
begin
  Result := False;
  Cases := nil;
  SHA256Hex := '';
  Err := '';
  if not FileExists(Path) then
  begin
    Err := Path + ' does not exist';
    Exit;
  end;
  Body := ReadFileText(Path);
  SHA256Hex := BytesToHexLower(SHA256Bytes(StringToBytes(Body)));
  Lines := TStringList.Create;
  try
    Lines.Text := Body;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Trim(Lines[i]);
      if Line = '' then Continue;
      O := nil;
      try
        O := TJsonObject.Parse(Line);
      except
        O := nil;
      end;
      if O = nil then
      begin
        Err := Format('line %d is not a JSON object', [i + 1]);
        Exit;
      end;
      try
        Cs := Default(TRerankCase);
        Cs.Id := O.GetStr('id', IntToStr(i + 1));
        Cs.Query := O.GetStr('query', '');
        if Trim(Cs.Query) = '' then
        begin
          Err := Format('line %d has no query', [i + 1]);
          Exit;
        end;
        Arr := O.ChildArray('candidates');
        if (Arr = nil) or (Arr.Count < 2) then
        begin
          if Arr <> nil then Arr.Free;
          Err := Format('line %d needs at least two candidates', [i + 1]);
          Exit;
        end;
        try
          SetLength(Cs.Docs, Arr.Count);
          SetLength(Cs.DocIds, Arr.Count);
          for j := 0 to Arr.Count - 1 do
          begin
            C := Arr.ItemObject(j);
            if C <> nil then
            try
              Cs.Docs[j] := C.GetStr('text', '');
              Cs.DocIds[j] := C.GetStr('id', IntToStr(j));
            finally
              C.Free;
            end
            else
            begin
              Cs.Docs[j] := Arr.ItemStr(j, '');
              Cs.DocIds[j] := IntToStr(j);
            end;
          end;
        finally
          Arr.Free;
        end;
        Arr := O.ChildArray('relevant');
        if Arr <> nil then
        try
          for j := 0 to Arr.Count - 1 do
          begin
            k := Integer(Arr.ItemInt(j, -1));
            if (k < 0) or (k > High(Cs.Docs)) then
            begin
              Err := Format('line %d: relevant index %d is not a candidate', [i + 1, k]);
              Exit;
            end;
            SetLength(Cs.Relevant, Length(Cs.Relevant) + 1);
            Cs.Relevant[High(Cs.Relevant)] := k;
          end;
        finally
          Arr.Free;
        end;
        if Length(Cs.Relevant) = 0 then
        begin
          Err := Format('line %d has no relevant candidate', [i + 1]);
          Exit;
        end;
        SetLength(Cases, Length(Cases) + 1);
        Cases[High(Cases)] := Cs;
      finally
        O.Free;
      end;
    end;
  finally
    Lines.Free;
  end;
  if Length(Cases) = 0 then
  begin
    Err := Path + ' has no questions';
    Exit;
  end;
  Result := True;
end;

function FirstRelevantRank(const Order, Relevant: array of Integer): Integer;
var
  i, j: Integer;
begin
  for i := 0 to High(Order) do
    for j := 0 to High(Relevant) do
      if Order[i] = Relevant[j] then
        Exit(i + 1);
  Result := Length(Order) + 1;
end;

procedure InitStats(var S: TRankStats; const Name: string);
begin
  S := Default(TRankStats);
  S.Name := Name;
end;

procedure AddOutcome(var S: TRankStats; const Order, Relevant: array of Integer;
  ElapsedMs: Int64; Failed: Boolean; InTok, OutTok: Int64);
var
  R: Integer;
begin
  Inc(S.N);
  R := FirstRelevantRank(Order, Relevant);
  if R = 1 then Inc(S.Hit1);
  if R <= 3 then Inc(S.Hit3);
  if R <= Length(Order) then S.SumRR := S.SumRR + 1.0 / R;
  if Failed then Inc(S.Errors);
  SetLength(S.LatMs, Length(S.LatMs) + 1);
  S.LatMs[High(S.LatMs)] := ElapsedMs;
  S.InTok := S.InTok + InTok;
  S.OutTok := S.OutTok + OutTok;
end;

function StatsMRR(const S: TRankStats): Double;
begin
  if S.N = 0 then Result := 0 else Result := S.SumRR / S.N;
end;

function StatsHit1(const S: TRankStats): Double;
begin
  if S.N = 0 then Result := 0 else Result := S.Hit1 / S.N;
end;

function StatsHit3(const S: TRankStats): Double;
begin
  if S.N = 0 then Result := 0 else Result := S.Hit3 / S.N;
end;

function StatsPercentileMs(const S: TRankStats; P: Double): Int64;
var
  A: TArray<Int64>;
  i, j, Idx: Integer;
  T: Int64;
begin
  Result := 0;
  if Length(S.LatMs) = 0 then Exit;
  A := Copy(S.LatMs);
  for i := 1 to High(A) do
  begin
    T := A[i];
    j := i - 1;
    while (j >= 0) and (A[j] > T) do
    begin
      A[j + 1] := A[j];
      Dec(j);
    end;
    A[j + 1] := T;
  end;
  { nearest rank: ceil(P * n), 1-based }
  Idx := Trunc(P * Length(A) + 0.999999) - 1;
  if Idx < 0 then Idx := 0;
  if Idx > High(A) then Idx := High(A);
  Result := A[Idx];
end;

function StatsToJSON(const S: TRankStats): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('name', S.Name);
    O.PutInt('n', S.N);
    O.PutFloat('mrr', StatsMRR(S));
    O.PutFloat('hit1', StatsHit1(S));
    O.PutFloat('hit3', StatsHit3(S));
    O.PutInt('errors', S.Errors);
    O.PutInt('p50_ms', StatsPercentileMs(S, 0.5));
    O.PutInt('p95_ms', StatsPercentileMs(S, 0.95));
    O.PutInt('input_tokens', S.InTok);
    O.PutInt('output_tokens', S.OutTok);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function PairedBootstrapLow(const Diffs: array of Double; Resamples: Integer;
  Seed: Cardinal; Quantile: Double): Double;
var
  Means: array of Double;
  r, i, j, n, Idx: Integer;
  Sum, T: Double;
  State: Cardinal;
begin
  Result := 0;
  n := Length(Diffs);
  if (n = 0) or (Resamples <= 0) then Exit;
  SetLength(Means, Resamples);
  State := Seed;
  for r := 0 to Resamples - 1 do
  begin
    Sum := 0;
    for i := 0 to n - 1 do
    begin
      { xorshift32: the same stream on every platform and compiler }
      State := State xor (State shl 13);
      State := State xor (State shr 17);
      State := State xor (State shl 5);
      Idx := Integer(State mod Cardinal(n));
      Sum := Sum + Diffs[Idx];
    end;
    Means[r] := Sum / n;
  end;
  for i := 1 to High(Means) do
  begin
    T := Means[i];
    j := i - 1;
    while (j >= 0) and (Means[j] > T) do
    begin
      Means[j + 1] := Means[j];
      Dec(j);
    end;
    Means[j + 1] := T;
  end;
  Idx := Trunc(Quantile * Resamples);
  if Idx < 0 then Idx := 0;
  if Idx > High(Means) then Idx := High(Means);
  Result := Means[Idx];
end;

function RerankVerdict(CandidateMRR, BaselineMRR, Margin, GainLow: Double): Boolean;
begin
  { A tiny epsilon so "beat by exactly the margin" is a pass, not lost to
    floating-point noise. }
  Result := (CandidateMRR + 1e-9 >= BaselineMRR + Margin) and (GainLow > 0);
end;

end.
