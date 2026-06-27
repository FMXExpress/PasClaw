(*
  PasClaw.Memory.Facts.Embed - wires the local ONNX embedder into the
  fact store's semantic layer (Phase 4c).

  PasClaw.Memory.Facts exposes an injectable TFactEmbedFn so its
  dedup/search logic stays testable with a fake. This unit provides the
  REAL embedder -- the same MiniLM ONNX path PasClaw.Memory.Vector uses
  for the .md hybrid index -- and registers it via SetFactEmbedder.

  Everything here is best-effort and gated:
    - EnableFactEmbeddings returns False (and leaves the exact + keyword
      tiers untouched) when the runtime / model / vocab aren't
      provisioned. A build or host without `pasclaw memory provision`
      simply gets no semantic layer -- never an error.
    - The loaded tokenizer + session are process-global and guarded by a
      critical section, because embeds run from concurrent gateway worker
      threads and the background auto-distill thread. ORT sessions are
      not assumed thread-safe, so calls are serialised.
    - GTried latches a failed load so we don't re-probe the filesystem /
      runtime on every fact operation.
*)
unit PasClaw.Memory.Facts.Embed;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{ Load + register the ONNX fact embedder for HomeDir's cache. Idempotent
  and safe to call from multiple entrypoints; returns True once semantic
  embeddings are active, False (graceful) when artifacts are missing. }
function EnableFactEmbeddings(const HomeDir: string): Boolean;

implementation

uses
  SysUtils, SyncObjs,
  LocalVector.Embedder,
  LocalVector.Tokenizer,
  LocalVector.Models,
  LocalVector.OrtProvision,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Memory.Facts;

const
  MAX_SEQ_LEN = 256;

var
  GLock:  TCriticalSection;
  GTok:   TBertTokenizer = nil;
  GEmb:   TEmbedder = nil;
  GSpec:  TModelSpec;
  GReady: Boolean = False;
  GTried: Boolean = False;

function DoFactEmbed(const Text: string): TArray<Single>;
{ Registered as the TFactEmbedFn. Serialised; returns [] on any failure
  so callers transparently fall back to keyword/exact. }
var
  TokenIds: TArray<Int64>;
begin
  Result := nil;
  GLock.Acquire;
  try
    if not GReady then Exit;
    try
      TokenIds := GTok.Encode(UnicodeString(Text), MAX_SEQ_LEN);
      Result := GEmb.Embed(TokenIds, GSpec.Pooling, GSpec.NeedsTokenTypeIds,
                           {ANormalize=} True, {AVerbose=} False);
    except
      on E: Exception do
      begin
        LogWarn('fact-embed: embed failed (%s)', [E.Message]);
        Result := nil;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

function EnableFactEmbeddings(const HomeDir: string): Boolean;
var
  Cache, ModelDir, ModelP, VocabP: string;
begin
  GLock.Acquire;
  try
    if GReady then Exit(True);
    { Latch: don't re-probe a known-unprovisioned setup on every call. }
    if GTried then Exit(False);
    GTried := True;

    if not FindModelSpec(DEFAULT_MODEL, GSpec) then Exit(False);

    { Mirror PasClaw.Memory.Vector's cache layout (nested JoinPath so no
      mixed '/' '\' separators sneak in on Windows). }
    Cache    := JoinPath(JoinPath(HomeDir, 'cache'), 'localvector');
    ModelDir := JoinPath(JoinPath(Cache, 'models'), GSpec.SubDir);
    ModelP   := JoinPath(ModelDir, 'model.onnx');
    VocabP   := JoinPath(ModelDir, 'vocab.txt');
    if not FileExists(ModelP) then
    begin
      LogDebug('fact-embed: model not found at %s -- semantic layer off', [ModelP]);
      Exit(False);
    end;
    if not FileExists(VocabP) then
    begin
      LogDebug('fact-embed: vocab not found at %s -- semantic layer off', [VocabP]);
      Exit(False);
    end;

    try
      EnsureOnnxRuntime(Cache, {AAllowDownload=} False, {AVerbose=} False);
      GTok := TBertTokenizer.Create(VocabP, GSpec.DoLowerCase);
      GEmb := TEmbedder.Create(ModelP);
      GEmb.Load({AVerbose=} False);
      GReady := True;
      SetFactEmbedder(@DoFactEmbed);
      LogDebug('fact-embed: enabled (model=%s dim=%d)', [GSpec.Key, GSpec.Dim]);
      Result := True;
    except
      on E: Exception do
      begin
        LogDebug('fact-embed: unavailable (%s) -- semantic dedup/search off',
                 [E.Message]);
        FreeAndNil(GTok);
        FreeAndNil(GEmb);
        GReady := False;
        Result := False;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  SetFactEmbedder(nil);
  FreeAndNil(GEmb);
  FreeAndNil(GTok);
  GLock.Free;

end.
