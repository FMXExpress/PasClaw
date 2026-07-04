(*
  PasClaw.Memory.Provision - background provisioning of the local memory /
  reranking runtime, driven from the web UI's Memory dialog (and reusable by
  the CLI).

  Downloading the ONNX embedder (~90 MB) and a reranker (~280 MB+) takes far
  longer than an HTTP request, so provisioning runs on a worker thread and the
  gateway polls a process-global status record. Only one job runs at a time.

  The actual work reuses the same primitives the CLI `pasclaw memory provision`
  uses: LocalVector.VecProvision (sqlite-vec), LocalVector.OrtProvision (ONNX
  Runtime), and LocalVector.Downloader (model.onnx + vocab/tokenizer).
*)
unit PasClaw.Memory.Provision;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{$IFDEF FPC}
uses SysUtils, Classes, SyncObjs;
{$ELSE}
uses System.SysUtils, System.Classes, System.SyncObjs;
{$ENDIF}

type
  TMemProvPhase = (mpIdle, mpRunning, mpDone, mpError);

  TMemProvStatus = record
    Phase: TMemProvPhase;
    Step:  string;    { human label of the current/last step }
    Error: string;    { set when Phase = mpError }
  end;

{ Start a provisioning job for HomeDir. AEmbed pulls sqlite-vec + ONNX Runtime +
  the default embedding model; ARerank pulls the reranker named ARerankModel
  (empty = the default reranker). Returns False (and does nothing) when a job is
  already running. Non-blocking -- the work happens on a worker thread. }
function MemProvStart(const HomeDir: string; AEmbed, ARerank: Boolean;
  const ARerankModel: string): Boolean;

{ Current job status (thread-safe snapshot). }
function MemProvGet: TMemProvStatus;

{ True while a job is running. }
function MemProvActive: Boolean;

{ ---- provisioned-state probes (no side effects) ---- }
function EmbedArtifactsPresent(const HomeDir: string): Boolean;
function RerankArtifactsPresent(const HomeDir, ARerankModel: string): Boolean;
function VecExtPresent(const HomeDir: string): Boolean;
function OrtLoadable(const HomeDir: string): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.Logger,
  LocalVector.Models,
  LocalVector.Downloader,
  LocalVector.VecProvision,
  LocalVector.OrtProvision,
  PasClaw.Memory.OrtPosix,
  PasClaw.Memory.Rerank;

var
  GLock:   TCriticalSection;
  GStatus: TMemProvStatus;

{ ---- paths ---- }

function CacheDir(const HomeDir: string): string;
begin
  Result := JoinPath(JoinPath(HomeDir, 'cache'), 'localvector');
end;

function ModelDirFor(const HomeDir, SubDir: string): string;
begin
  Result := JoinPath(JoinPath(CacheDir(HomeDir), 'models'), SubDir);
end;

{ ---- probes ---- }

function EmbedArtifactsPresent(const HomeDir: string): Boolean;
var Spec: TModelSpec; D: string;
begin
  Result := False;
  if not FindModelSpec(DEFAULT_MODEL, Spec) then Exit;
  D := ModelDirFor(HomeDir, Spec.SubDir);
  Result := FileExists(JoinPath(D, 'model.onnx')) and FileExists(JoinPath(D, 'vocab.txt'));
end;

function RerankArtifactsPresent(const HomeDir, ARerankModel: string): Boolean;
var Spec: TModelSpec; D, K: string;
begin
  Result := False;
  K := Trim(ARerankModel);
  if K = '' then K := DEFAULT_RERANKER;
  if not FindRerankerSpec(K, Spec) then Exit;
  D := ModelDirFor(HomeDir, Spec.SubDir);
  Result := FileExists(JoinPath(D, 'model.onnx')) and FileExists(JoinPath(D, 'vocab.txt'));
end;

function VecExtPresent(const HomeDir: string): Boolean;
var C: string;
begin
  C := CacheDir(HomeDir);
  { EnsureVec0 with AAllowDownload=False just returns the path if present. }
  Result := FileExists(JoinPath(C, 'vec0.so'))
         or FileExists(JoinPath(C, 'vec0.dll'))
         or FileExists(JoinPath(C, 'vec0.dylib'));
end;

function OrtLoadable(const HomeDir: string): Boolean;
begin
  Result := False;
  try
    Result := EnsureOnnxRuntime(CacheDir(HomeDir), {AAllowDownload=} False, {AVerbose=} False);
  except
    on E: Exception do Result := False;
  end;
end;

{ ---- status helpers ---- }

procedure SetStatus(APhase: TMemProvPhase; const AStep, AError: string);
begin
  GLock.Acquire;
  try
    GStatus.Phase := APhase;
    if AStep  <> '' then GStatus.Step  := AStep;
    GStatus.Error := AError;
  finally
    GLock.Release;
  end;
end;

function MemProvGet: TMemProvStatus;
begin
  GLock.Acquire;
  try
    Result := GStatus;
  finally
    GLock.Release;
  end;
end;

function MemProvActive: Boolean;
begin
  Result := MemProvGet.Phase = mpRunning;
end;

{ ---- worker ---- }

type
  TMemProvThread = class(TThread)
  private
    FHome, FRerankModel: string;
    FEmbed, FRerank: Boolean;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHome: string; AEmbed, ARerank: Boolean;
      const ARerankModel: string);
  end;

constructor TMemProvThread.Create(const AHome: string; AEmbed, ARerank: Boolean;
  const ARerankModel: string);
begin
  FHome := AHome; FEmbed := AEmbed; FRerank := ARerank; FRerankModel := ARerankModel;
  FreeOnTerminate := True;
  inherited Create({CreateSuspended=} False);
end;

procedure DownloadModel(const AHome: string; const ASpec: TModelSpec; const AStep: string);
var Dir: string; D: TModelDownloader;
begin
  SetStatus(mpRunning, AStep, '');
  Dir := ModelDirFor(AHome, ASpec.SubDir);
  ForceDirectories(Dir);
  D := TModelDownloader.Create(ASpec, Dir, {AVerbose=} False);
  try
    D.EnsureFiles;
    if not (FileExists(D.ModelPath) and FileExists(D.VocabPath)) then
      raise Exception.CreateFmt('%s: files missing after download', [ASpec.DisplayName]);
  finally
    D.Free;
  end;
end;

procedure TMemProvThread.Execute;
var
  Spec: TModelSpec;
  Cache, K, OrtMsg: string;
begin
  OrtMsg := '';
  try
    Cache := CacheDir(FHome);
    ForceDirectories(Cache);

    { The ONNX Runtime is needed by BOTH the embedder and the reranker, so
      provision it whenever either was requested. On Windows the vendored
      auto-download runs inside EnsureOnnxRuntime; on Linux/macOS that download
      is unavailable, so fetch the release tarball via EnsurePosixOrt (the same
      path the CLI uses) -- otherwise the models download but nothing can load
      them, and the job must NOT report a clean success. }
    if FEmbed or FRerank then
    begin
      SetStatus(mpRunning, 'ONNX Runtime', '');
      if not OrtLoadable(FHome) then
      begin
        {$IFNDEF MSWINDOWS}
        EnsurePosixOrt(Cache, OrtMsg);
        {$ENDIF}
        try EnsureOnnxRuntime(Cache, {AAllowDownload=} True, {AVerbose=} False); except on E: Exception do
          LogWarn('mem-provision: ort: %s', [E.Message]); end;
      end;
    end;

    if FEmbed then
    begin
      SetStatus(mpRunning, 'sqlite-vec extension', '');
      try EnsureVec0(Cache, {AAllowDownload=} True, {AVerbose=} False); except on E: Exception do
        LogWarn('mem-provision: vec0: %s', [E.Message]); end;

      if FindModelSpec(DEFAULT_MODEL, Spec) then
        DownloadModel(FHome, Spec, 'embedding model (' + Spec.DisplayName + ')')
      else
        raise Exception.Create('default embedding model not registered');
    end;

    if FRerank then
    begin
      K := Trim(FRerankModel);
      if K = '' then K := DEFAULT_RERANKER;
      if FindRerankerSpec(K, Spec) then
        DownloadModel(FHome, Spec, 'reranker model (' + Spec.DisplayName + ')')
      else
        raise Exception.CreateFmt('unknown reranker model "%s"', [K]);
    end;

    { Honest final state: models are on disk, but if the ONNX Runtime still
      isn't loadable they can't be used yet -- say so instead of a bare "done". }
    if not OrtLoadable(FHome) then
      SetStatus(mpDone, 'models downloaded, but ONNX Runtime is not loadable -- '
        + 'install it (Debian: apt install libonnxruntime-dev; macOS: brew install onnxruntime)', '')
    else
      SetStatus(mpDone, 'done', '');
    LogInfo('mem-provision: completed (embed=%s rerank=%s ort=%s)',
      [BoolToStr(FEmbed, True), BoolToStr(FRerank, True), BoolToStr(OrtLoadable(FHome), True)]);
  except
    on E: Exception do
    begin
      SetStatus(mpError, '', E.Message);
      LogWarn('mem-provision: failed: %s', [E.Message]);
    end;
  end;
end;

function MemProvStart(const HomeDir: string; AEmbed, ARerank: Boolean;
  const ARerankModel: string): Boolean;
begin
  Result := False;
  if not (AEmbed or ARerank) then Exit;
  GLock.Acquire;
  try
    if GStatus.Phase = mpRunning then Exit;   { one job at a time }
    GStatus.Phase := mpRunning;
    GStatus.Step  := 'starting';
    GStatus.Error := '';
  finally
    GLock.Release;
  end;
  TMemProvThread.Create(HomeDir, AEmbed, ARerank, ARerankModel);
  Result := True;
end;

initialization
  GLock := TCriticalSection.Create;
  GStatus.Phase := mpIdle;

finalization
  GLock.Free;

end.
