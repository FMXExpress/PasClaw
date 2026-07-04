(*
  PasClaw.Memory.Rerank.Serve - process-global loader + gate for the local
  ONNX cross-encoder reranker, mirroring PasClaw.Memory.Facts.Embed.

  Backs the gateway's /v1/rerank endpoint (and the optional retrieval
  rerank stage). Everything is best-effort and gated:
    - LocalRerankAvailable returns False (and the endpoint 503s / the
      retrieval stage stays off) when the runtime / model / vocab aren't
      provisioned. A host without `pasclaw memory provision --rerank`
      simply gets no reranker -- never an error.
    - The loaded TReranker is process-global and guarded by a critical
      section: reranks run from concurrent gateway worker threads, and
      the ORT session is not assumed thread-safe, so calls are serialised.
    - GTried latches a failed load so we don't re-probe the filesystem /
      runtime on every request; the artifacts-missing case is cleared once
      the files appear (same recovery Facts.Embed does for /v1/embeddings).

  The configured model key defaults to DEFAULT_RERANKER and can be
  overridden via SetLocalRerankModel (called from config apply).
*)
unit PasClaw.Memory.Rerank.Serve;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{$IFDEF FPC}
uses SysUtils;
{$ELSE}
uses System.SysUtils;
{$ENDIF}

{ Choose the reranker model (registry key, e.g. 'ms-marco-minilm' or
  'bge-reranker-base'). Empty resets to the default. Takes effect on the
  next load; if a different model is already loaded it is dropped so the
  new one loads on the next call. }
procedure SetLocalRerankModel(const AKey: string);

{ True when the local ONNX reranker is loadable for HomeDir (model + vocab
  + runtime provisioned). }
function LocalRerankAvailable(const HomeDir: string): Boolean;

{ Active reranker model id (registry key). False when not provisioned. }
function LocalRerankModelInfo(const HomeDir: string; out ModelId: string): Boolean;

{ Score Documents against Query with the local cross-encoder and return the
  indices ordered by relevance descending, with their 0..1 scores (Order[k]
  is the original document index at rank k; Scores[k] its score). False
  (graceful) when the reranker isn't provisioned or scoring fails. Serialised
  internally, so it's safe from concurrent gateway worker threads. }
function LocalRerank(const HomeDir, Query: string; const Documents: array of string;
  out Order: TArray<Integer>; out Scores: TArray<Single>): Boolean;

implementation

uses
  {$IFDEF FPC}SyncObjs,{$ELSE}System.SyncObjs,{$ENDIF}
  LocalVector.Models,
  LocalVector.OrtProvision,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Memory.Rerank;

var
  GLock:  TCriticalSection;
  GRank:  TReranker = nil;
  GSpec:  TModelSpec;
  GKey:   string = DEFAULT_RERANKER;
  GReady: Boolean = False;
  GTried: Boolean = False;
  { True when the latched failure was specifically "artifacts not on disk"
    (vs a genuine load failure) -- lets LocalRerankAvailable clear the latch
    and retry once after provisioning writes the model. }
  GTriedWithoutArtifacts: Boolean = False;

function RerankModelDir(const HomeDir: string; const Spec: TModelSpec): string;
begin
  { Mirror PasClaw.Memory.Facts.Embed's cache layout exactly. }
  Result := JoinPath(JoinPath(JoinPath(JoinPath(HomeDir, 'cache'),
                     'localvector'), 'models'), Spec.SubDir);
end;

function RerankArtifactsExist(const HomeDir: string): Boolean;
var
  Spec: TModelSpec;
  ModelDir: string;
begin
  Result := False;
  if not FindRerankerSpec(GKey, Spec) then Exit;
  ModelDir := RerankModelDir(HomeDir, Spec);
  Result := FileExists(JoinPath(ModelDir, 'model.onnx'))
        and FileExists(JoinPath(ModelDir, 'vocab.txt'));
end;

procedure SetLocalRerankModel(const AKey: string);
var
  NewKey: string;
begin
  NewKey := Trim(AKey);
  if NewKey = '' then NewKey := DEFAULT_RERANKER;
  GLock.Acquire;
  try
    if SameText(NewKey, GKey) then Exit;
    GKey := NewKey;
    { Drop any loaded model so the new key loads on next use, and clear the
      latch so the swap is actually attempted. }
    FreeAndNil(GRank);
    GReady := False;
    GTried := False;
    GTriedWithoutArtifacts := False;
  finally
    GLock.Release;
  end;
end;

{ Load the reranker for HomeDir if not already loaded. Latched. Caller holds
  no lock -- this acquires GLock itself. }
function EnsureLoaded(const HomeDir: string): Boolean;
var
  Cache, ModelDir, ModelP, VocabP: string;
begin
  GLock.Acquire;
  try
    if GReady then Exit(True);
    if GTried then Exit(False);
    GTried := True;

    if not FindRerankerSpec(GKey, GSpec) then
    begin
      LogDebug('rerank-serve: unknown reranker model "%s" -- reranker off', [GKey]);
      Exit(False);
    end;

    Cache    := JoinPath(JoinPath(HomeDir, 'cache'), 'localvector');
    ModelDir := RerankModelDir(HomeDir, GSpec);
    ModelP   := JoinPath(ModelDir, 'model.onnx');
    VocabP   := JoinPath(ModelDir, 'vocab.txt');
    if not FileExists(ModelP) then
    begin
      LogDebug('rerank-serve: model not found at %s -- reranker off', [ModelP]);
      GTriedWithoutArtifacts := True;
      Exit(False);
    end;
    if not FileExists(VocabP) then
    begin
      LogDebug('rerank-serve: vocab not found at %s -- reranker off', [VocabP]);
      GTriedWithoutArtifacts := True;
      Exit(False);
    end;

    GTriedWithoutArtifacts := False;
    try
      EnsureOnnxRuntime(Cache, {AAllowDownload=} False, {AVerbose=} False);
      GRank := TReranker.Create(ModelP, VocabP, GSpec.DoLowerCase,
                                GSpec.NeedsTokenTypeIds);
      GReady := True;
      LogDebug('rerank-serve: enabled (model=%s)', [GSpec.Key]);
      Result := True;
    except
      on E: Exception do
      begin
        LogDebug('rerank-serve: unavailable (%s) -- reranker off', [E.Message]);
        FreeAndNil(GRank);
        GReady := False;
        Result := False;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

function LocalRerankAvailable(const HomeDir: string): Boolean;
begin
  Result := EnsureLoaded(HomeDir);
  if Result then Exit;
  { If the latched failure was "artifacts missing" AND they now exist, clear
    the latch and try once more so a gateway started before provisioning
    recovers in-process (same trick as LocalEmbedAvailable). A genuine load
    failure is not retried. }
  GLock.Acquire;
  try
    if GReady then Exit(True);
    if not (GTriedWithoutArtifacts and RerankArtifactsExist(HomeDir)) then
      Exit(False);
    GTried := False;
  finally
    GLock.Release;
  end;
  Result := EnsureLoaded(HomeDir);
end;

function LocalRerankModelInfo(const HomeDir: string; out ModelId: string): Boolean;
begin
  ModelId := '';
  if not EnsureLoaded(HomeDir) then Exit(False);
  { GSpec is set once under GLock during load and not mutated after. }
  ModelId := GSpec.Key;
  Result  := True;
end;

function LocalRerank(const HomeDir, Query: string; const Documents: array of string;
  out Order: TArray<Integer>; out Scores: TArray<Single>): Boolean;
var
  Hits: TRerankHits;
  I: Integer;
begin
  Result := False;
  Order  := nil;
  Scores := nil;
  if Length(Documents) = 0 then Exit;
  if not EnsureLoaded(HomeDir) then Exit;
  GLock.Acquire;
  try
    if not GReady then Exit;
    try
      Hits := GRank.Rerank(Query, Documents);
    except
      on E: Exception do
      begin
        LogWarn('rerank-serve: rerank failed (%s)', [E.Message]);
        Exit;
      end;
    end;
  finally
    GLock.Release;
  end;
  SetLength(Order,  Length(Hits));
  SetLength(Scores, Length(Hits));
  for I := 0 to High(Hits) do
  begin
    Order[I]  := Hits[I].Index;
    Scores[I] := Hits[I].Score;
  end;
  Result := True;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  FreeAndNil(GRank);
  GLock.Free;

end.
