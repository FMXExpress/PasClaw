(*
  PasClaw.Memory.Vector - hybrid FTS5 + sqlite-vec memory_search backend.

  Implements the same IMemoryIndex contract that PasClaw.Memory.Index
  serves over keyword-only FTS5, but routes through the localvector
  units (vendored in src/pkg/memory/localvector/) for the vector half:

    - LocalVector.VectorStore.IVectorStore wraps a SQLite database with
      parallel FTS5 (BM25) and vec0 (sqlite-vec / KNN) tables sharing
      the same row ids.
    - TEmbedder + TBertTokenizer run a sentence-transformer ONNX model
      locally — MiniLM by default, ~90 MB of weights, 384-d output. No
      outbound API calls; embeddings never leave the host.
    - Search fuses the FTS5 and vec0 ranked id lists via Reciprocal
      Rank Fusion before returning hits.

  Open() returns False when any runtime piece is missing (sqlite-vec
  extension, ONNX Runtime DLL, model weights, vocab.txt). The caller —
  PasClaw.Tools.Memory — falls back to the FTS-only NewMemoryIndex on
  False so missing provisioning never breaks memory_search, just
  degrades it. Provisioning itself lives in a future phase.

  Cache layout under PASCLAW_HOME (also where the provisioning phase
  will write the auto-downloaded artifacts):

    <home>/cache/localvector/
      onnxruntime.{so,dll,dylib}   ONNX Runtime — Linux/macOS users
                                   install via system pkg manager
                                   until the auto-downloader extends
                                   beyond win-x64 (LocalVector.OrtProvision
                                   only auto-fetches win-x64 today).
      vec0.{so,dll,dylib}          sqlite-vec extension. Provisioning fetches.
      models/<modelKey>/
        model.onnx                 sentence-transformer weights
        vocab.txt                  BERT WordPiece vocab

  Model selection defaults to MiniLM (DEFAULT_MODEL from
  LocalVector.Models). A config knob can expose the other registered
  models (bge, mxbai) once provisioning lands.
*)
unit PasClaw.Memory.Vector;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Memory.Index;

(* Construct an IMemoryIndex backed by the in-tree localvector hybrid
   store. Open() returns False if any provisioning piece is missing —
   callers should fall back to PasClaw.Memory.Index.NewMemoryIndex on
   False. *)
function NewVectorMemoryIndex: IMemoryIndex;

implementation

uses
  LocalVector.VectorStore,
  LocalVector.Embedder,
  LocalVector.Tokenizer,
  LocalVector.Models,
  LocalVector.OrtProvision,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger;

const
  { Bound the embedder's sequence length so a giant memory file doesn't
    burn seconds per chunk. 256 tokens covers a paragraph comfortably
    and matches localvector's own default. }
  MAX_SEQ_LEN = 256;

  CACHE_SUBDIR = 'cache/localvector';

type
  TVectorMemoryIndex = class(TInterfacedObject, IMemoryIndex)
  private
    FStore:     IVectorStore;
    FEmbedder:  TEmbedder;
    FTokenizer: TBertTokenizer;
    FModelSpec: TModelSpec;
    FOpen:      Boolean;
    function CacheDir: string;
    function VecExtPath: string;
    function ModelOnnxPath: string;
    function VocabPath: string;
    function EmbedText(const T: string): TArray<Single>;
  public
    constructor Create;
    destructor  Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    procedure SyncDir(const Dir: string);
    function  Search(const Query: string; K: Integer): TMemoryHitArray;
  end;

constructor TVectorMemoryIndex.Create;
begin
  inherited Create;
  if not FindModelSpec(DEFAULT_MODEL, FModelSpec) then
    { Should never happen — DEFAULT_MODEL is hard-coded in the registry.
      If localvector ever drops the default we'd want loud failure. }
    raise Exception.CreateFmt(
      'localvector default model "%s" not in registry', [DEFAULT_MODEL]);
end;

destructor TVectorMemoryIndex.Destroy;
begin
  Close;
  FEmbedder.Free;
  FTokenizer.Free;
  inherited;
end;

function TVectorMemoryIndex.CacheDir: string;
begin
  Result := JoinPath(GetHome, CACHE_SUBDIR);
end;

function TVectorMemoryIndex.VecExtPath: string;
{ sqlite-vec extension. SQLite's load_extension takes the path WITHOUT
  the platform suffix and adds the right one (.so / .dll / .dylib),
  but it's clearer to record the actual filename we expect on disk. }
begin
  {$IFDEF MSWINDOWS}
  Result := JoinPath(CacheDir, 'vec0.dll');
  {$ELSE}
    {$IFDEF DARWIN}
    Result := JoinPath(CacheDir, 'vec0.dylib');
    {$ELSE}
    Result := JoinPath(CacheDir, 'vec0.so');
    {$ENDIF}
  {$ENDIF}
end;

function TVectorMemoryIndex.ModelOnnxPath: string;
begin
  Result := JoinPath(JoinPath(JoinPath(CacheDir, 'models'),
                              FModelSpec.SubDir), 'model.onnx');
end;

function TVectorMemoryIndex.VocabPath: string;
begin
  Result := JoinPath(JoinPath(JoinPath(CacheDir, 'models'),
                              FModelSpec.SubDir), 'vocab.txt');
end;

function TVectorMemoryIndex.EmbedText(const T: string): TArray<Single>;
var
  TokenIds: TArray<Int64>;
begin
  TokenIds := FTokenizer.Encode(UnicodeString(T), MAX_SEQ_LEN);
  Result := FEmbedder.Embed(TokenIds, FModelSpec.Pooling,
                            FModelSpec.NeedsTokenTypeIds,
                            {ANormalize=} True,
                            {AVerbose=}  False);
end;

function TVectorMemoryIndex.Open(const DbPath: string): Boolean;
{ Returns False (silently, with one debug-level log line per missing
  piece) rather than raising so PasClaw.Tools.Memory can degrade to
  the FTS-only path without a stack trace landing in the agent
  transcript. Every failure mode here is "operator hasn't provisioned
  the runtime artifacts yet" — expected for now. }
begin
  Result := False;
  if FOpen then Exit(True);
  if not FileExists(VecExtPath) then
  begin
    LogDebug('vector memory: sqlite-vec extension not found at %s — ' +
             'falling back to FTS5-only', [VecExtPath]);
    Exit;
  end;
  if not FileExists(ModelOnnxPath) then
  begin
    LogDebug('vector memory: embedding model not found at %s — ' +
             'falling back to FTS5-only', [ModelOnnxPath]);
    Exit;
  end;
  if not FileExists(VocabPath) then
  begin
    LogDebug('vector memory: tokenizer vocab not found at %s — ' +
             'falling back to FTS5-only', [VocabPath]);
    Exit;
  end;
  try
    { ONNX Runtime: try the cache dir first (where provisioning will
      drop it), then let the system loader try (LD_LIBRARY_PATH /
      system libonnxruntime). AAllowDownload stays False here — the
      agent transcript is the wrong place to surface a multi-hundred-MB
      download.

      EnsureOnnxRuntime raises on every "couldn't find the runtime"
      path, so we sit inside the outer try/except. }
    EnsureOnnxRuntime(CacheDir, {AAllowDownload=} False, {AVerbose=} False);

    FTokenizer := TBertTokenizer.Create(VocabPath, FModelSpec.DoLowerCase);
    FEmbedder  := TEmbedder.Create(ModelOnnxPath);
    FEmbedder.Load({AVerbose=} False);

    FStore := CreateVectorStore;
    FStore.OpenStore(DbPath, VecExtPath);
    FStore.InitSchema(FModelSpec.Dim, FModelSpec.Key);

    FOpen  := True;
    Result := True;
    LogDebug('vector memory: opened %s with model %s (dim=%d)',
             [DbPath, FModelSpec.Key, FModelSpec.Dim]);
  except
    on E: Exception do
    begin
      LogDebug('vector memory open failed: %s — falling back to FTS5-only',
               [E.Message]);
      Close;
      Result := False;
    end;
  end;
end;

procedure TVectorMemoryIndex.Close;
begin
  if FStore <> nil then
  begin
    try FStore.CloseStore; except end;
    FStore := nil;
  end;
  FOpen := False;
end;

procedure InternalFindMdFiles(L: TStringList; const Dir: string);
{ Recursively collect *.md files. Standalone inside this unit —
  PasClaw.Memory.Index doesn't expose its own walker and reusing it
  would tighten the unit-dependency direction we don't want yet. }
var
  Rec: TSearchRec;
  Sub: string;
begin
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
      Sub := JoinPath(Dir, Rec.Name);
      if (Rec.Attr and faDirectory) <> 0 then
        InternalFindMdFiles(L, Sub)
      else if SameText(ExtractFileExt(Rec.Name), '.md') then
        L.Add(Sub);
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;
end;

procedure TVectorMemoryIndex.SyncDir(const Dir: string);
{ Walk *.md files in Dir; chunk, embed, batch-add into the store.

  Phase 2 takes the simple sledgehammer approach — wipe + rebuild on
  every SyncDir. Embedding is slow (MiniLM is ~5 ms/chunk on a modern
  CPU; a memory dir with hundreds of small notes is still well under
  a second) so this is acceptable short-term. A future pass adds an
  mtime-tracked incremental path similar to PasClaw.Memory.Index. }
var
  Files: TStringList;
  i, j: Integer;
  Body: string;
  Chunks: TArray<string>;
  Emb: TArray<Single>;
begin
  if not FOpen then Exit;

  Files := TStringList.Create;
  try
    if DirectoryExists(Dir) then
      InternalFindMdFiles(Files, Dir);

    FStore.BeginBatch;
    try
      for i := 0 to Files.Count - 1 do
      begin
        try
          Body := ReadFileText(Files[i]);
        except
          { Unreadable file — log and skip rather than tear down the
            whole sync (one borked memory note shouldn't break
            search). }
          on E: Exception do
          begin
            LogDebug('vector memory: skipping %s — %s',
                     [Files[i], E.Message]);
            Continue;
          end;
        end;
        Chunks := ChunkText(Body, 'paragraphs');
        for j := 0 to High(Chunks) do
        begin
          try
            Emb := EmbedText(Chunks[j]);
            FStore.AddChunk(Files[i], j, Chunks[j], Emb);
          except
            on E: Exception do
              LogDebug('vector memory: skipping chunk %d of %s — %s',
                       [j, Files[i], E.Message]);
          end;
        end;
      end;
      FStore.CommitBatch;
    except
      on E: Exception do
      begin
        LogDebug('vector memory: SyncDir failed mid-batch — %s', [E.Message]);
        try FStore.CommitBatch; except end;
      end;
    end;
  finally
    Files.Free;
  end;
end;

function TVectorMemoryIndex.Search(const Query: string; K: Integer): TMemoryHitArray;
var
  Emb: TArray<Single>;
  Hits: TSearchHits;
  i: Integer;
begin
  SetLength(Result, 0);
  if not FOpen then Exit;
  try
    Emb := EmbedText(Query);
  except
    on E: Exception do
    begin
      LogDebug('vector memory: query embedding failed — %s', [E.Message]);
      Exit;
    end;
  end;
  Hits := FStore.Search(Query, Emb, smHybrid, K);
  SetLength(Result, Length(Hits));
  for i := 0 to High(Hits) do
  begin
    Result[i].Path    := Hits[i].Source;
    Result[i].Score   := Hits[i].Score;
    { localvector returns the chunk text itself as the "snippet"; that
      gives the model the same kind of context the FTS path's
      bm25-highlighted snippet does without the highlighting markup. }
    Result[i].Snippet := Hits[i].Text;
  end;
end;

function NewVectorMemoryIndex: IMemoryIndex;
begin
  Result := TVectorMemoryIndex.Create;
end;

end.
