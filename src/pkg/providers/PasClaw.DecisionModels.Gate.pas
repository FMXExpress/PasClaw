(*
  PasClaw.DecisionModels.Gate - when a decision point may use a decision backend.

  Selecting a backend for a point (decision_models.points.rerank = "gemini") is
  a request, not a switch. A decision model is only worth calling where it
  does better than what the point does without it, and that is an
  empirical question about this point, this model and this data -- the
  vendors do not even agree on what their `confidence` means. So with
  decision_models.require_bench (the default) a point uses its backend only when
  `pasclaw decision-model bench <point>` has recorded a run in which that backend,
  at that model, beat the exact implementation the request would otherwise
  get -- `llm:gemini/gemini-3.5-flash-lite`, `local:ms-marco-minilm`. A win
  over a small chat model says nothing about a large one, and nothing at
  all about the local cross-encoder; change the reranker's model and the
  gate shuts until the bench is run against the new one.

  Records live in <home>/decision-models/bench/<point>.json, one per
  backend + model + baseline, newest replacing older. A failing run is
  recorded too: it is the answer to "why isn't this on?".
*)
unit PasClaw.DecisionModels.Gate;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.DecisionModels;

type
  TDecisionBenchRecord = record
    Point:         string;
    Backend:       string;   { backend name from config }
    Kind:          string;   { google | systemone }
    Model:         string;
    BaselineKind:  string;   { what the point does without it: llm | local }
    Baseline:      string;   { exactly which: llm:gemini/gemini-3.5-flash-lite }
    Dataset:       string;
    DatasetSHA256: string;
    N:             Integer;
    Metric:        string;   { the one the verdict is on, e.g. mrr }
    BaselineValue, CandidateValue, Margin: Double;
    Pass:          Boolean;
    At:            string;   { ISO-8601 UTC }
    DetailJSON:    string;   { every metric, as the bench reported them }
  end;
  TDecisionBenchRecords = array of TDecisionBenchRecord;

{ The backend named Name, with api_base / api_key / model filled from its
  provider entry and the kind's defaults. False with Err when there is no
  such backend, its kind is unknown, or it has no key. }
function ResolveDecisionBackend(const Cfg: TConfig; const Name: string;
  out B: TDecisionBackend; out Err: string): Boolean;

{ The backend name selected for Point, or ''. }
function DecisionPointBackendName(const Cfg: TConfig; const Point: string): string;

function DecisionBenchPath(const Point: string): string;
function LoadDecisionBenchRecords(const Point: string): TDecisionBenchRecords;
{ Store R, replacing a record with the same backend, model and baseline. }
function SaveDecisionBenchRecord(const R: TDecisionBenchRecord; out Err: string): Boolean;

{ The gate. True when Point has a backend selected that resolves, and
  either decision_models.require_bench is off or the latest run of that
  backend and model against Baseline (the exact name the bench records,
  e.g. llm:gemini/gemini-3.5-flash-lite) passed. Why says which, either
  way, in one line. }
function DecisionGate(const Cfg: TConfig; const Point, Baseline: string;
  out B: TDecisionBackend; out Why: string): Boolean;

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Utils;

function FindBackendCfg(const Cfg: TConfig; const Name: string;
  out BC: TDecisionModelBackendConfig): Boolean;
var
  i: Integer;
begin
  Result := False;
  BC := Default(TDecisionModelBackendConfig);
  for i := 0 to High(Cfg.DecisionModels.Backends) do
    if SameText(Cfg.DecisionModels.Backends[i].Name, Name) then
    begin
      BC := Cfg.DecisionModels.Backends[i];
      Exit(True);
    end;
end;

function ResolveDecisionBackend(const Cfg: TConfig; const Name: string;
  out B: TDecisionBackend; out Err: string): Boolean;
var
  BC: TDecisionModelBackendConfig;
  i: Integer;
  Found: Boolean;
begin
  Result := False;
  B := Default(TDecisionBackend);
  Err := '';
  if not FindBackendCfg(Cfg, Name, BC) then
  begin
    Err := 'no decision backend named "' + Name + '" in decision_models.backends';
    Exit;
  end;
  B.Name := BC.Name;
  if not TryParseDecisionBackendKind(BC.Kind, B.Kind) then
  begin
    Err := 'decision backend "' + Name + '" has kind "' + BC.Kind +
           '"; use "google" or "systemone"';
    Exit;
  end;
  if BC.Provider <> '' then
  begin
    Found := False;
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, BC.Provider) then
      begin
        Found := True;
        B.APIKey := Cfg.Providers[i].APIKey;
        { A provider's api_base is for its chat API; it is the right host
          only for a Google backend borrowing a Gemini provider. }
        if B.Kind = dbGoogle then B.APIBase := Cfg.Providers[i].APIBase;
        Break;
      end;
    if not Found then
    begin
      Err := 'decision backend "' + Name + '" names provider "' + BC.Provider +
             '", which is not in providers';
      Exit;
    end;
  end;
  if BC.APIBase <> '' then B.APIBase := BC.APIBase;
  if BC.APIKey <> '' then B.APIKey := BC.APIKey;
  if Trim(B.APIBase) = '' then B.APIBase := DefaultDecisionAPIBase(B.Kind);
  B.Model := BC.Model;
  if Trim(B.Model) = '' then B.Model := DefaultDecisionModel(B.Kind);
  B.TimeoutSec := 60;
  if Trim(B.APIKey) = '' then
  begin
    Err := 'decision backend "' + Name + '" has no api_key (set one, or a provider to take it from)';
    Exit;
  end;
  Result := True;
end;

function DecisionPointBackendName(const Cfg: TConfig; const Point: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Cfg.DecisionModels.Points) do
    if SameText(Cfg.DecisionModels.Points[i].Point, Point) then
      Exit(Cfg.DecisionModels.Points[i].Backend);
end;

function SafePoint(const Point: string): string;
var
  i: Integer;
begin
  Result := LowerCase(Point);
  for i := 1 to Length(Result) do
    if not (Result[i] in ['a'..'z', '0'..'9', '-', '_']) then Result[i] := '_';
  if Result = '' then Result := '_';
end;

function DecisionBenchPath(const Point: string): string;
begin
  Result := JoinPath(JoinPath(JoinPath(GetHome, 'decision-models'), 'bench'),
                     SafePoint(Point) + '.json');
end;

function RecordFromJSON(O: TJsonObject): TDecisionBenchRecord;
var
  D: TJsonObject;
begin
  Result := Default(TDecisionBenchRecord);
  Result.Point         := O.GetStr('point', '');
  Result.Backend       := O.GetStr('backend', '');
  Result.Kind          := O.GetStr('kind', '');
  Result.Model         := O.GetStr('model', '');
  Result.BaselineKind  := O.GetStr('baseline_kind', '');
  Result.Baseline      := O.GetStr('baseline', '');
  Result.Dataset       := O.GetStr('dataset', '');
  Result.DatasetSHA256 := O.GetStr('dataset_sha256', '');
  Result.N             := Integer(O.GetInt('n', 0));
  Result.Metric        := O.GetStr('metric', '');
  Result.BaselineValue := O.GetFloat('baseline_value', 0);
  Result.CandidateValue:= O.GetFloat('candidate_value', 0);
  Result.Margin        := O.GetFloat('margin', 0);
  Result.Pass          := O.GetBool('pass', False);
  Result.At            := O.GetStr('at', '');
  D := O.ChildObject('detail');
  if D <> nil then
  try
    Result.DetailJSON := D.ToJSON;
  finally
    D.Free;
  end;
end;

function RecordToJSON(const R: TDecisionBenchRecord): TJsonObject;
var
  D: TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('point', R.Point);
  Result.PutStr('backend', R.Backend);
  Result.PutStr('kind', R.Kind);
  Result.PutStr('model', R.Model);
  Result.PutStr('baseline_kind', R.BaselineKind);
  Result.PutStr('baseline', R.Baseline);
  Result.PutStr('dataset', R.Dataset);
  Result.PutStr('dataset_sha256', R.DatasetSHA256);
  Result.PutInt('n', R.N);
  Result.PutStr('metric', R.Metric);
  Result.PutFloat('baseline_value', R.BaselineValue);
  Result.PutFloat('candidate_value', R.CandidateValue);
  Result.PutFloat('margin', R.Margin);
  Result.PutBool('pass', R.Pass);
  Result.PutStr('at', R.At);
  if R.DetailJSON <> '' then
  begin
    D := nil;
    try
      D := TJsonObject.Parse(R.DetailJSON);
    except
      D := nil;
    end;
    if D <> nil then Result.PutObject('detail', D);
  end;
end;

function LoadDecisionBenchRecords(const Point: string): TDecisionBenchRecords;
var
  Path, Body: string;
  Root, It: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Result := nil;
  Path := DecisionBenchPath(Point);
  if not FileExists(Path) then Exit;
  Body := ReadFileText(Path);
  Root := nil;
  try
    Root := TJsonObject.Parse(Body);
  except
    Root := nil;   { a damaged file reads as "no runs": the gate stays shut }
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('runs');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        It := Arr.ItemObject(i);
        if It = nil then Continue;
        try
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := RecordFromJSON(It);
        finally
          It.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

function SameRun(const A, B: TDecisionBenchRecord): Boolean;
begin
  Result := SameText(A.Backend, B.Backend) and (A.Model = B.Model) and
            (A.Baseline = B.Baseline);
end;

function SaveDecisionBenchRecord(const R: TDecisionBenchRecord; out Err: string): Boolean;
var
  Old: TDecisionBenchRecords;
  Root, It: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  Path: string;
begin
  Result := False;
  Err := '';
  Old := LoadDecisionBenchRecords(R.Point);
  Root := TJsonObject.Create;
  try
    Root.PutStr('point', R.Point);
    Arr := TJsonArray.Create;
    for i := 0 to High(Old) do
      if not SameRun(Old[i], R) then
      begin
        It := RecordToJSON(Old[i]);
        Arr.AddObject(It);
      end;
    It := RecordToJSON(R);
    Arr.AddObject(It);
    Root.PutArray('runs', Arr);
    Path := DecisionBenchPath(R.Point);
    try
      ForceDirectories(ExtractFileDir(Path));
      { A gateway reads this on every rerank: write beside it and move it
        into place, so a reader never sees half a file. (A reader that
        did would read no runs -- the gate shut, the safe side.) }
      WriteFileText(Path + '.tmp', Root.ToJSON);
      if FileExists(Path) then DeleteFile(Path);
      if not RenameFile(Path + '.tmp', Path) then
        raise Exception.Create('rename failed');
      Result := True;
    except
      on E: Exception do Err := 'could not write ' + Path + ': ' + E.Message;
    end;
  finally
    Root.Free;
  end;
end;

function FmtNum(V: Double): string;
begin
  Result := FormatFloat('0.000', V);
end;

function DecisionGate(const Cfg: TConfig; const Point, Baseline: string;
  out B: TDecisionBackend; out Why: string): Boolean;
var
  Name, Err: string;
  Runs: TDecisionBenchRecords;
  i, Latest: Integer;
begin
  Result := False;
  B := Default(TDecisionBackend);
  Name := DecisionPointBackendName(Cfg, Point);
  if Name = '' then
  begin
    Why := 'no decision backend selected for ' + Point;
    Exit;
  end;
  if not ResolveDecisionBackend(Cfg, Name, B, Err) then
  begin
    Why := Err;
    Exit;
  end;
  if not Cfg.DecisionModels.RequireBench then
  begin
    Why := Point + ' uses ' + Name + ' (' + B.Model + '): decision_models.require_bench is off';
    Exit(True);
  end;
  Runs := LoadDecisionBenchRecords(Point);
  Latest := -1;
  for i := 0 to High(Runs) do
    if SameText(Runs[i].Backend, Name) and (Runs[i].Model = B.Model) and
       (Runs[i].Baseline = Baseline) then
      Latest := i;
  if Latest < 0 then
  begin
    Why := Point + ' stays on ' + Baseline + ': ' + Name + ' (' + B.Model +
           ') has not been benchmarked against it -- run `pasclaw decision-model bench ' +
           Point + '`';
    Exit;
  end;
  if not Runs[Latest].Pass then
  begin
    Why := Point + ' stays on ' + Baseline + ': ' + Name + ' (' + B.Model +
           ') did not beat ' + Runs[Latest].Baseline + ' (' + Runs[Latest].Metric + ' ' +
           FmtNum(Runs[Latest].CandidateValue) + ' vs ' + FmtNum(Runs[Latest].BaselineValue) +
           ', needs +' + FmtNum(Runs[Latest].Margin) + ', ' + Runs[Latest].At + ')';
    Exit;
  end;
  Why := Point + ' uses ' + Name + ' (' + B.Model + '): beat ' + Runs[Latest].Baseline +
         ' (' + Runs[Latest].Metric + ' ' + FmtNum(Runs[Latest].CandidateValue) + ' vs ' +
         FmtNum(Runs[Latest].BaselineValue) + ', n=' + IntToStr(Runs[Latest].N) + ', ' +
         Runs[Latest].At + ')';
  Result := True;
end;

end.
