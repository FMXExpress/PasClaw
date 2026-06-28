(*
  PasClaw.KB.Index - the knowledgebase ("Big RAG") document index.

  Separate from conversation memory (the PasClaw.Memory units) by design: memory
  answers "what did we decide earlier", the KB answers "what do my
  reference documents say". Mixing the two degrades both retrieval
  intents, so the KB gets its own database (workspace/kb.db), its own
  registry of document sources, and its own agent tools (kb_search /
  kb_get in PasClaw.Tools.KB).

  Model:
    - `pasclaw kb add <file-or-dir>` registers a SOURCE (absolute path)
      in kb_sources. Documents are indexed IN PLACE — never copied.
    - Sync walks every source, picks up supported text/markdown/source
      files (see KB_EXTENSIONS), chunks them (KBChunkDocument), and
      maintains an FTS5 index incrementally by mtime. Files that
      disappeared are dropped.
    - Search runs FTS5 BM25 over chunks. When the localvector runtime
      is provisioned (sqlite-vec + ONNX Runtime + embedding model — the
      exact same artifacts memory_search uses, gated by the same
      vector_search_enabled config flag) a vector sidecar (kb.db.vec)
      is kept alongside and Search routes through the hybrid
      FTS+vec store with RRF fusion instead.
    - GetChunks returns a window of chunks around a hit so the model
      can pull more context after a search ("kb_get").

  The FTS5 chunk store in kb.db is always the source of truth; the
  vector sidecar is a derived ranking structure, rebuilt when the chunk
  population changes (IVectorStore has no per-source delete, so the
  rebuild is wholesale — acceptable because sync is an explicit CLI
  action, not a per-query hot path).

  Anything that can fail at runtime (no libsqlite3, no vector
  provisioning) degrades: Open returns False, vector falls back to
  FTS-only — same philosophy as memory_search.
*)
unit PasClaw.KB.Index;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TKBHit = record
    Path:    string;
    ChunkNo: Integer;
    Snippet: string;
    Score:   Double;
  end;
  TKBHitArray = array of TKBHit;

  TKBSource = record
    Root:    string;
    AddedAt: Int64;
    Files:   Integer;
    Chunks:  Integer;
  end;
  TKBSourceArray = array of TKBSource;

  TKBStats = record
    Sources: Integer;
    Files:   Integer;
    Chunks:  Integer;
    { True when the vector runtime artifacts are on disk AND
      vector_search_enabled is set — i.e. Search would attempt the
      hybrid backend. Presence check only; nothing is loaded. }
    VectorReady: Boolean;
  end;

  IKBIndex = interface
    ['{0E7C51D2-8B4A-4F3E-9D26-5A1C7F8E2B40}']
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    function  AddSource(const Root: string; out Err: string): Boolean;
    function  RemoveSource(const Root: string; out Err: string): Boolean;
    function  GetSources: TKBSourceArray;
    { Walk all sources; (re)index added/changed files, drop vanished
      ones. Returns how many files were (re)indexed and how many chunks
      they produced. Cheap when nothing changed (mtime comparisons). }
    procedure Sync(out FilesIndexed, ChunksIndexed: Integer);
    function  Search(const Query: string; K: Integer): TKBHitArray;
    { Chunks [ChunkNo-Window .. ChunkNo+Window] of Path, concatenated
      with "--- path#cN ---" headers. '' when the path/chunk is
      unknown. }
    function  GetChunks(const Path: string; ChunkNo, Window: Integer): string;
    function  Stats: TKBStats;
  end;

function NewKBIndex: IKBIndex;

{ <home>/workspace/kb.db — nested JoinPath, not a 'workspace/kb.db'
  literal, for the same Windows mixed-separator reason documented in
  PasClaw.Memory.Vector.CacheDir. }
function DefaultKBDbPath: string;

(* ---- pure helpers, exposed for tests ---------------------------------- *)

{ Paragraph-accumulating chunker. Splits on blank lines, packs
  paragraphs into chunks of ~KB_CHUNK_TARGET bytes (hard cap
  KB_CHUNK_MAX, oversized paragraphs split at line — then byte —
  boundaries without breaking UTF-8 sequences). Returns no empties. }
function KBChunkDocument(const Text: string): TArray<string>;

{ True when the file extension is in the supported text/source set. }
function KBExtSupported(const Path: string): Boolean;

{ Cheap binary sniff: a NUL byte in the head means "not text, skip". }
function KBLooksBinary(const Head: string): Boolean;

{ Minimal HTML-to-text: drops <script>/<style> blocks, strips tags,
  decodes the half-dozen entities that matter for retrieval. }
function KBStripHtml(const Html: string): string;

const
  KB_CHUNK_TARGET = 1600;
  KB_CHUNK_MAX    = 3200;
  { Files larger than this are skipped (with a log line) — a converted
    book lands well under it; anything bigger is usually a data dump
    that would swamp the index. Bumped from 4 MB to 30 MB to admit
    large PDFs (textbooks, scanned-and-OCR'd whitepapers); plain-text
    sources at this size are still uncommon, and the chunker handles
    them fine. }
  KB_MAX_FILE_BYTES = 30 * 1024 * 1024;

implementation

uses
  DateUtils, StrUtils,
  {$IFDEF FPC}
  sqldb, sqlite3conn,
  {$ELSE}
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Stan.Def,
  FireDAC.Stan.Async, FireDAC.Stan.Param, FireDAC.DApt,
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Memory.Index,        { SanitizeFtsQuery, FTS5_SNIPPET_TOKENS }
  PasClaw.KB.PDF,              { ExtractPDFText for .pdf ingest }
  LocalVector.VectorStore,
  LocalVector.Embedder,
  LocalVector.Tokenizer,
  LocalVector.Models,
  LocalVector.OrtProvision;

const
  { Extensions indexed by Sync. Lowercase, with dot. Plain-text reads;
    .html/.htm additionally pass through KBStripHtml; .pdf is routed
    through PasClaw.KB.PDF (native FlateDecode + /ToUnicode parser, no
    external tools). Image-only / scanned PDFs without an embedded
    text layer fall out of ingest with a "no extractable text" warning. }
  KB_EXTENSIONS: array[0..39] of string = (
    '.md', '.markdown', '.txt', '.text', '.rst', '.adoc', '.org',
    '.pas', '.pp', '.inc', '.dpr', '.lpr',
    '.c', '.h', '.cc', '.cpp', '.hpp', '.cs', '.java', '.go', '.rs',
    '.js', '.ts', '.py', '.rb', '.php', '.swift', '.kt', '.sql',
    '.sh', '.bat', '.ps1',
    '.json', '.yaml', '.yml', '.toml', '.ini', '.csv',
    '.html',
    '.pdf');

function DefaultKBDbPath: string;
begin
  Result := JoinPath(JoinPath(GetHome, 'workspace'), 'kb.db');
end;

(* ======================= pure helpers ================================ *)

function KBExtSupported(const Path: string): Boolean;
var
  Ext: string;
  i:   Integer;
begin
  Ext := LowerCase(ExtractFileExt(Path));
  if Ext = '.htm' then Ext := '.html';
  for i := Low(KB_EXTENSIONS) to High(KB_EXTENSIONS) do
    if Ext = KB_EXTENSIONS[i] then Exit(True);
  Result := False;
end;

function KBLooksBinary(const Head: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to Length(Head) do
    if Head[i] = #0 then Exit(True);
  Result := False;
end;

function KBStripHtml(const Html: string): string;

  { Delete every block between StartTag and EndTag (case-insensitive),
    e.g. <script ...> ... </script>. }
  function DropBlocks(const S, TagName: string): string;
  var
    L, Lo: string;
    A, B:  Integer;
  begin
    Result := S;
    Lo := LowerCase(Result);
    L  := '<' + TagName;
    A  := Pos(L, Lo);
    while A > 0 do
    begin
      B := Pos('</' + TagName, Lo);
      if (B = 0) or (B < A) then
        { Unclosed block — drop to end of input; better to lose tail
          markup than index a megabyte of JavaScript. }
        B := Length(Result) + 1
      else
      begin
        B := PosEx('>', Lo, B);
        if B = 0 then B := Length(Result) + 1;
      end;
      Delete(Result, A, B - A + 1);
      Lo := LowerCase(Result);
      A  := Pos(L, Lo);
    end;
  end;

var
  S:       string;
  i, Tag:  Integer;
  Out_:    TStringBuilder;
begin
  S := DropBlocks(Html, 'script');
  S := DropBlocks(S, 'style');

  Out_ := TStringBuilder.Create;
  try
    Tag := 0;
    for i := 1 to Length(S) do
    begin
      if S[i] = '<' then Inc(Tag)
      else if S[i] = '>' then begin if Tag > 0 then Dec(Tag); Out_.Append(' '); end
      else if Tag = 0 then Out_.Append(S[i]);
    end;
    Result := Out_.ToString;
  finally
    Out_.Free;
  end;

  Result := StringReplace(Result, '&nbsp;', ' ',  [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '&amp;',  '&',  [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '&lt;',   '<',  [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '&gt;',   '>',  [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '&quot;', '"',  [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '&#39;',  '''', [rfReplaceAll, rfIgnoreCase]);
end;

procedure AppendChunk(var Arr: TArray<string>; const S: string);
var
  T: string;
begin
  T := Trim(S);
  if T = '' then Exit;
  SetLength(Arr, Length(Arr) + 1);
  Arr[High(Arr)] := T;
end;

function KBChunkDocument(const Text: string): TArray<string>;

  { Split an oversized paragraph at line boundaries, hard-slicing any
    single line longer than KB_CHUNK_MAX without cutting a UTF-8
    sequence in half (back up over continuation bytes). }
  procedure SplitBig(var Arr: TArray<string>; const Para: string);
  var
    Lines: TStringList;
    Acc, L: string;
    i, Len: Integer;
  begin
    Lines := TStringList.Create;
    try
      Lines.Text := Para;
      Acc := '';
      for i := 0 to Lines.Count - 1 do
      begin
        L := Lines[i];
        while Length(L) > KB_CHUNK_MAX do
        begin
          Len := KB_CHUNK_MAX;
          { Don't split inside a UTF-8 multi-byte sequence: byte values
            $80..$BF are continuation bytes. }
          while (Len > 1) and ((Byte(L[Len + 1]) and $C0) = $80) do Dec(Len);
          AppendChunk(Arr, Acc);
          Acc := '';
          AppendChunk(Arr, Copy(L, 1, Len));
          L := Copy(L, Len + 1, MaxInt);
        end;
        if (Acc <> '') and (Length(Acc) + Length(L) + 1 > KB_CHUNK_MAX) then
        begin
          AppendChunk(Arr, Acc);
          Acc := '';
        end;
        if Acc = '' then Acc := L else Acc := Acc + #10 + L;
      end;
      AppendChunk(Arr, Acc);
    finally
      Lines.Free;
    end;
  end;

var
  Norm, Para, Acc: string;
  Paras: TStringList;
  i, P, Start: Integer;
begin
  SetLength(Result, 0);
  Norm := StringReplace(Text, #13#10, #10, [rfReplaceAll]);
  Norm := StringReplace(Norm, #13, #10, [rfReplaceAll]);
  if Trim(Norm) = '' then Exit;

  { Split into paragraphs on blank lines (a run of \n where the line
    between is empty/whitespace). }
  Paras := TStringList.Create;
  try
    Start := 1;
    P := 1;
    while P <= Length(Norm) do
    begin
      if (Norm[P] = #10) then
      begin
        { Look ahead: is the next line blank? }
        i := P + 1;
        while (i <= Length(Norm)) and ((Norm[i] = ' ') or (Norm[i] = #9)) do Inc(i);
        if (i <= Length(Norm)) and (Norm[i] = #10) then
        begin
          Paras.Add(Copy(Norm, Start, P - Start));
          { Skip the whole blank run. }
          while (i <= Length(Norm)) and
                ((Norm[i] = #10) or (Norm[i] = ' ') or (Norm[i] = #9)) do Inc(i);
          Start := i;
          P := i;
          Continue;
        end;
      end;
      Inc(P);
    end;
    if Start <= Length(Norm) then
      Paras.Add(Copy(Norm, Start, MaxInt));

    Acc := '';
    for i := 0 to Paras.Count - 1 do
    begin
      Para := Trim(Paras[i]);
      if Para = '' then Continue;
      if Length(Para) > KB_CHUNK_MAX then
      begin
        AppendChunk(Result, Acc);
        Acc := '';
        SplitBig(Result, Para);
        Continue;
      end;
      if (Acc <> '') and (Length(Acc) + Length(Para) + 2 > KB_CHUNK_TARGET) then
      begin
        AppendChunk(Result, Acc);
        Acc := '';
      end;
      if Acc = '' then Acc := Para else Acc := Acc + #10#10 + Para;
    end;
    AppendChunk(Result, Acc);
  finally
    Paras.Free;
  end;
end;

(* ======================= index implementation ======================== *)

type
  TKBIndexImpl = class(TInterfacedObject, IKBIndex)
  private
    {$IFDEF FPC}
    FConn: TSQLite3Connection;
    FTx:   TSQLTransaction;
    {$ELSE}
    FConn: TFDConnection;
    {$ENDIF}
    FOpen:   Boolean;
    FDbPath: string;
    { Vector sidecar (lazy). Mirrors PasClaw.Memory.Vector: every
      missing artifact degrades to FTS-only silently. }
    FVecTried: Boolean;
    FStore:     IVectorStore;
    FEmbedder:  TEmbedder;
    FTokenizer: TBertTokenizer;
    FModelSpec: TModelSpec;
    procedure ExecSQL(const SQL: string);
    procedure ExecP(const SQL: string;
                    const SN: array of string; const SV: array of string;
                    const INames: array of string; const IV: array of Int64);
    function  QueryI64(const SQL: string;
                       const SN: array of string; const SV: array of string;
                       out Val: Int64): Boolean;
    function  QueryStrings(const SQL: string;
                           const SN: array of string; const SV: array of string): TStringList;
    procedure EnsureSchema;
    procedure ReindexFile(const Path, Root: string; Mtime: Int64;
                          var ChunksIndexed: Integer);
    procedure DropFile(const Path: string);
    procedure CollectFiles(const Root: string; Known: TStringList);
    function  VecSidecarPath: string;
    function  TryEnsureVector: Boolean;
    procedure RebuildVectorSidecar;
    function  EmbedText(const T: string): TArray<Single>;
    function  ChunkCount: Int64;
    procedure SetMeta(const Key, Val: string);
    function  GetMetaI64(const Key: string; out Val: Int64): Boolean;
    function  VectorInSync: Boolean;
  public
    constructor Create;
    destructor  Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    function  AddSource(const Root: string; out Err: string): Boolean;
    function  RemoveSource(const Root: string; out Err: string): Boolean;
    function  GetSources: TKBSourceArray;
    procedure Sync(out FilesIndexed, ChunksIndexed: Integer);
    function  Search(const Query: string; K: Integer): TKBHitArray;
    function  GetChunks(const Path: string; ChunkNo, Window: Integer): string;
    function  Stats: TKBStats;
  end;

function NewKBIndex: IKBIndex;
begin
  Result := TKBIndexImpl.Create;
end;

{ Artifact presence — same paths PasClaw.Memory.Vector resolves. Kept
  in sync manually; both read <home>/cache/localvector/. }
function VectorArtifactsPresent(const Spec: TModelSpec): Boolean;
var
  CacheDir, ExtPath, ModelDir: string;
begin
  CacheDir := JoinPath(JoinPath(GetHome, 'cache'), 'localvector');
  {$IFDEF MSWINDOWS}
  ExtPath := JoinPath(CacheDir, 'vec0.dll');
  {$ELSE}
    {$IFDEF DARWIN}
    ExtPath := JoinPath(CacheDir, 'vec0.dylib');
    {$ELSE}
    ExtPath := JoinPath(CacheDir, 'vec0.so');
    {$ENDIF}
  {$ENDIF}
  ModelDir := JoinPath(JoinPath(CacheDir, 'models'), Spec.SubDir);
  Result := FileExists(ExtPath) and
            FileExists(JoinPath(ModelDir, 'model.onnx')) and
            FileExists(JoinPath(ModelDir, 'vocab.txt'));
end;

constructor TKBIndexImpl.Create;
begin
  inherited Create;
  if not FindModelSpec(DEFAULT_MODEL, FModelSpec) then
    raise Exception.CreateFmt(
      'localvector default model "%s" not in registry', [DEFAULT_MODEL]);
end;

destructor TKBIndexImpl.Destroy;
begin
  Close;
  FEmbedder.Free;
  FTokenizer.Free;
  inherited;
end;

procedure TKBIndexImpl.ExecSQL(const SQL: string);
{$IFDEF FPC}
begin
  FConn.ExecuteDirect(SQL);
  FTx.CommitRetaining;
end;
{$ELSE}
begin
  FConn.ExecSQL(SQL);
end;
{$ENDIF}

procedure TKBIndexImpl.ExecP(const SQL: string;
                             const SN: array of string; const SV: array of string;
                             const INames: array of string; const IV: array of Int64);
{$IFDEF FPC}
var
  Q: TSQLQuery;
  i: Integer;
begin
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.Params.ParamByName(SN[i]).AsString := SV[i];
    for i := 0 to High(INames) do Q.Params.ParamByName(INames[i]).AsLargeInt := IV[i];
    Q.ExecSQL;
    FTx.CommitRetaining;
  finally
    Q.Free;
  end;
end;
{$ELSE}
var
  Q: TFDQuery;
  i: Integer;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.ParamByName(SN[i]).AsString := SV[i];
    for i := 0 to High(INames) do Q.ParamByName(INames[i]).AsLargeInt := IV[i];
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

function TKBIndexImpl.QueryI64(const SQL: string;
                               const SN: array of string; const SV: array of string;
                               out Val: Int64): Boolean;
{$IFDEF FPC}
var
  Q: TSQLQuery;
  i: Integer;
begin
  Result := False;
  Val := 0;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.Params.ParamByName(SN[i]).AsString := SV[i];
    Q.Open;
    if not Q.EOF then
    begin
      Val := Q.Fields[0].AsLargeInt;
      Result := True;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ELSE}
var
  Q: TFDQuery;
  i: Integer;
begin
  Result := False;
  Val := 0;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.ParamByName(SN[i]).AsString := SV[i];
    Q.Open;
    if not Q.Eof then
    begin
      Val := Q.Fields[0].AsLargeInt;
      Result := True;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

function TKBIndexImpl.QueryStrings(const SQL: string;
                                   const SN: array of string; const SV: array of string): TStringList;
{$IFDEF FPC}
var
  Q: TSQLQuery;
  i: Integer;
begin
  Result := TStringList.Create;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.Params.ParamByName(SN[i]).AsString := SV[i];
    Q.Open;
    while not Q.EOF do
    begin
      Result.Add(Q.Fields[0].AsString);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ELSE}
var
  Q: TFDQuery;
  i: Integer;
begin
  Result := TStringList.Create;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := SQL;
    for i := 0 to High(SN) do Q.ParamByName(SN[i]).AsString := SV[i];
    Q.Open;
    while not Q.Eof do
    begin
      Result.Add(Q.Fields[0].AsString);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

procedure TKBIndexImpl.EnsureSchema;
begin
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS kb_sources (' +
    '  root TEXT PRIMARY KEY,' +
    '  added_at INTEGER NOT NULL)');
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS kb_files (' +
    '  path TEXT PRIMARY KEY,' +
    '  root TEXT NOT NULL,' +
    '  mtime INTEGER NOT NULL,' +
    '  nchunks INTEGER NOT NULL)');
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS kb_chunks (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  path TEXT NOT NULL,' +
    '  chunk_no INTEGER NOT NULL,' +
    '  body TEXT NOT NULL,' +
    '  UNIQUE(path, chunk_no))');
  ExecSQL(
    'CREATE VIRTUAL TABLE IF NOT EXISTS kb_fts USING fts5(' +
    '  path UNINDEXED, chunk_no UNINDEXED, body,' +
    '  tokenize=''porter unicode61'')');
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS kb_meta (' +
    '  key TEXT PRIMARY KEY, val TEXT NOT NULL)');
end;

function TKBIndexImpl.Open(const DbPath: string): Boolean;
begin
  Result := False;
  if FOpen then Exit(True);
  FDbPath := DbPath;
  try
    EnsureDir(ExtractFileDir(DbPath));
    {$IFDEF FPC}
    FConn := TSQLite3Connection.Create(nil);
    FTx   := TSQLTransaction.Create(nil);
    FConn.DatabaseName := DbPath;
    FConn.Transaction  := FTx;
    FTx.Database       := FConn;
    FConn.Open;
    FTx.StartTransaction;
    {$ELSE}
    FConn := TFDConnection.Create(nil);
    FConn.DriverName := 'SQLite';
    FConn.Params.Values['Database'] := DbPath;
    FConn.LoginPrompt := False;
    FConn.Connected := True;
    {$ENDIF}
    EnsureSchema;
    FOpen := True;
    Result := True;
    LogDebug('kb.index: opened %s', [DbPath]);
  except
    on E: Exception do
    begin
      LogWarn('kb.index: failed to open %s (%s) — knowledgebase disabled',
              [DbPath, E.Message]);
      {$IFDEF FPC}
      FreeAndNil(FTx);
      FreeAndNil(FConn);
      {$ELSE}
      FreeAndNil(FConn);
      {$ENDIF}
      FOpen := False;
    end;
  end;
end;

procedure TKBIndexImpl.Close;
begin
  if FStore <> nil then
  begin
    try FStore.CloseStore; except end;
    FStore := nil;
  end;
  if not FOpen then Exit;
  try
    {$IFDEF FPC}
    if (FTx <> nil) and FTx.Active then FTx.Commit;
    if (FConn <> nil) and FConn.Connected then FConn.Close;
    FreeAndNil(FTx);
    FreeAndNil(FConn);
    {$ELSE}
    if (FConn <> nil) and FConn.Connected then FConn.Connected := False;
    FreeAndNil(FConn);
    {$ENDIF}
  except
    on E: Exception do
      LogWarn('kb.index: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TKBIndexImpl.AddSource(const Root: string; out Err: string): Boolean;
var
  Abs: string;
  Dummy: Int64;
begin
  Result := False;
  Err := '';
  if not FOpen then begin Err := 'knowledgebase database not open'; Exit; end;
  Abs := ExpandFileName(Root);
  if not (FileExists(Abs) or DirectoryExists(Abs)) then
  begin
    Err := 'no such file or directory: ' + Abs;
    Exit;
  end;
  if FileExists(Abs) and not KBExtSupported(Abs) then
  begin
    Err := 'unsupported file type: ' + ExtractFileExt(Abs) +
           ' (text/markdown/source only — convert PDFs to text first)';
    Exit;
  end;
  if QueryI64('SELECT 1 FROM kb_sources WHERE root = :r', ['r'], [Abs], Dummy) then
  begin
    Err := 'already registered: ' + Abs;
    Exit;
  end;
  ExecP('INSERT INTO kb_sources (root, added_at) VALUES (:r, :t)',
        ['r'], [Abs], ['t'], [DateTimeToUnix(Now, False)]);
  Result := True;
end;

function TKBIndexImpl.RemoveSource(const Root: string; out Err: string): Boolean;
var
  Abs: string;
  Dummy: Int64;
  Paths: TStringList;
  i: Integer;
begin
  Result := False;
  Err := '';
  if not FOpen then begin Err := 'knowledgebase database not open'; Exit; end;
  Abs := ExpandFileName(Root);
  if not QueryI64('SELECT 1 FROM kb_sources WHERE root = :r', ['r'], [Abs], Dummy) then
  begin
    Err := 'not a registered source: ' + Abs;
    Exit;
  end;
  Paths := QueryStrings('SELECT path FROM kb_files WHERE root = :r', ['r'], [Abs]);
  try
    for i := 0 to Paths.Count - 1 do
      DropFile(Paths[i]);
  finally
    Paths.Free;
  end;
  ExecP('DELETE FROM kb_sources WHERE root = :r', ['r'], [Abs], [], []);
  Result := True;
end;

function TKBIndexImpl.GetSources: TKBSourceArray;
var
  Roots: TStringList;
  i: Integer;
  V: Int64;
begin
  SetLength(Result, 0);
  if not FOpen then Exit;
  Roots := QueryStrings('SELECT root FROM kb_sources ORDER BY root', [], []);
  try
    SetLength(Result, Roots.Count);
    for i := 0 to Roots.Count - 1 do
    begin
      Result[i].Root := Roots[i];
      if QueryI64('SELECT added_at FROM kb_sources WHERE root = :r',
                  ['r'], [Roots[i]], V) then Result[i].AddedAt := V;
      { nchunks > 0: rows with 0 chunks are skip markers (oversized /
        binary files tracked only so sync doesn't re-read them), not
        retrievable documents. }
      if QueryI64('SELECT COUNT(*) FROM kb_files WHERE nchunks > 0 AND root = :r',
                  ['r'], [Roots[i]], V) then Result[i].Files := V;
      if QueryI64('SELECT COUNT(*) FROM kb_chunks WHERE path IN ' +
                  '(SELECT path FROM kb_files WHERE root = :r)',
                  ['r'], [Roots[i]], V) then Result[i].Chunks := V;
    end;
  finally
    Roots.Free;
  end;
end;

procedure TKBIndexImpl.CollectFiles(const Root: string; Known: TStringList);

  procedure Walk(const Dir: string);
  var
    Rec: TSearchRec;
    Sub: string;
  begin
    if FindFirst(JoinPath(Dir, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        { Dot-dirs (.git, .svn, ...) and node_modules are never useful
          knowledge and routinely explode the file count. }
        if (Rec.Attr and faDirectory) <> 0 then
        begin
          if (Rec.Name <> '') and (Rec.Name[1] = '.') then Continue;
          if SameText(Rec.Name, 'node_modules') then Continue;
          Walk(JoinPath(Dir, Rec.Name));
          Continue;
        end;
        Sub := JoinPath(Dir, Rec.Name);
        if KBExtSupported(Sub) then Known.Add(Sub);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
  end;

begin
  if FileExists(Root) then
  begin
    if KBExtSupported(Root) then Known.Add(Root);
  end
  else if DirectoryExists(Root) then
    Walk(Root);
end;

procedure TKBIndexImpl.DropFile(const Path: string);
begin
  ExecP('DELETE FROM kb_fts WHERE rowid IN ' +
        '(SELECT id FROM kb_chunks WHERE path = :p)', ['p'], [Path], [], []);
  ExecP('DELETE FROM kb_chunks WHERE path = :p', ['p'], [Path], [], []);
  ExecP('DELETE FROM kb_files  WHERE path = :p', ['p'], [Path], [], []);
end;

procedure TKBIndexImpl.ReindexFile(const Path, Root: string; Mtime: Int64;
                                   var ChunksIndexed: Integer);
{ Called only for files that are new or whose mtime advanced — so
  whatever rows are currently indexed for Path are stale by
  definition. Every early-out below must therefore DropFile first, or
  searches keep serving the previous version of a file that is now
  unindexable (Codex P2 on PR #214: file grew past the size cap).

  Deterministic skips (oversized, binary) additionally record a
  kb_files row with nchunks=0: the mtime gate in Sync then stops
  re-reading the same unindexable file on every pass. Transient
  failures (unreadable) record nothing so the next sync retries. }

  function FileSizeOf(const P: string): Int64;
  var
    Sr: TSearchRec;
  begin
    Result := 0;
    if FindFirst(P, faAnyFile, Sr) = 0 then
    begin
      Result := Sr.Size;
      FindClose(Sr);
    end;
  end;

  procedure RecordSkipped;
  begin
    ExecP('INSERT INTO kb_files (path, root, mtime, nchunks) VALUES (:p, :r, :m, 0)',
          ['p', 'r'], [Path, Root], ['m'], [Mtime]);
  end;

var
  Body, Ext, PdfErr: string;
  Chunks: TArray<string>;
  j: Integer;
begin
  { Size gate BEFORE reading: rejecting a 100 MB dump shouldn't cost
    reading 100 MB every sync. }
  if FileSizeOf(Path) > KB_MAX_FILE_BYTES then
  begin
    LogWarn('kb.index: %s is %d bytes (> %d) — skipping',
            [Path, FileSizeOf(Path), KB_MAX_FILE_BYTES]);
    DropFile(Path);
    RecordSkipped;
    Exit;
  end;

  Ext := LowerCase(ExtractFileExt(Path));

  { PDF branch: native parser owns the read (it needs raw bytes, not
    text) and skips the binary-sniff (PDFs always have NUL bytes). An
    image-only PDF returns Body='' with PdfErr set; we log and record
    as skipped so Sync doesn't re-attempt it every cycle. }
  if Ext = '.pdf' then
  begin
    if not ExtractPDFText(Path, Body, PdfErr) then
    begin
      LogWarn('kb.index: pdf %s — %s', [Path, PdfErr]);
      DropFile(Path);
      RecordSkipped;
      Exit;
    end;
  end
  else
  begin
    try
      Body := ReadFileText(Path);
    except
      on E: Exception do
      begin
        LogWarn('kb.index: read %s failed (%s) — skipping', [Path, E.Message]);
        DropFile(Path);
        Exit;
      end;
    end;
    if KBLooksBinary(Copy(Body, 1, 4096)) then
    begin
      LogDebug('kb.index: %s looks binary — skipping', [Path]);
      DropFile(Path);
      RecordSkipped;
      Exit;
    end;

    if (Ext = '.html') or (Ext = '.htm') then
      Body := KBStripHtml(Body);
  end;

  Chunks := KBChunkDocument(Body);

  DropFile(Path);
  ExecP('INSERT INTO kb_files (path, root, mtime, nchunks) VALUES (:p, :r, :m, :n)',
        ['p', 'r'], [Path, Root], ['m', 'n'], [Mtime, Length(Chunks)]);
  for j := 0 to High(Chunks) do
  begin
    ExecP('INSERT INTO kb_chunks (path, chunk_no, body) VALUES (:p, :n, :b)',
          ['p', 'b'], [Path, Chunks[j]], ['n'], [j]);
    ExecP('INSERT INTO kb_fts (rowid, path, chunk_no, body) VALUES (' +
          '(SELECT id FROM kb_chunks WHERE path = :p AND chunk_no = :n), :p, :n, :b)',
          ['p', 'b'], [Path, Chunks[j]], ['n'], [j]);
  end;
  Inc(ChunksIndexed, Length(Chunks));
end;

procedure TKBIndexImpl.Sync(out FilesIndexed, ChunksIndexed: Integer);
var
  Roots, Known, Indexed: TStringList;
  RootOf: TStringList;            { parallel to Known: owning root }
  i: Integer;
  Mtime, Idx: Int64;
  Dt: TDateTime;
  Changed: Boolean;
begin
  FilesIndexed  := 0;
  ChunksIndexed := 0;
  if not FOpen then Exit;
  Changed := False;

  Roots  := QueryStrings('SELECT root FROM kb_sources ORDER BY root', [], []);
  Known  := TStringList.Create;
  RootOf := TStringList.Create;
  try
    for i := 0 to Roots.Count - 1 do
    begin
      Known.Clear;
      CollectFiles(Roots[i], Known);
      RootOf.AddStrings(Known);   { just to keep all-known across roots }
      { (re)index new/changed files under this root }
      while Known.Count > 0 do
      begin
        if FileAge(Known[0], Dt) then
        begin
          Mtime := DateTimeToUnix(Dt, False);
          if (not QueryI64('SELECT mtime FROM kb_files WHERE path = :p',
                           ['p'], [Known[0]], Idx)) or (Idx < Mtime) then
          begin
            ReindexFile(Known[0], Roots[i], Mtime, ChunksIndexed);
            Inc(FilesIndexed);
            Changed := True;
          end;
        end;
        Known.Delete(0);
      end;
    end;

    { Drop rows whose file vanished (or whose extension support was
      removed). RootOf holds every path seen this pass across all
      sources. }
    Indexed := QueryStrings('SELECT path FROM kb_files', [], []);
    try
      for i := 0 to Indexed.Count - 1 do
        if RootOf.IndexOf(Indexed[i]) < 0 then
        begin
          DropFile(Indexed[i]);
          Changed := True;
        end;
    finally
      Indexed.Free;
    end;
  finally
    Roots.Free;
    Known.Free;
    RootOf.Free;
  end;

  { Vector sidecar follows the chunk population. Rebuilt wholesale on
    any change — IVectorStore has no per-source delete, and sync is an
    explicit operator action where a few extra seconds of embedding is
    acceptable. ALSO rebuilt when the sidecar is missing or stale even
    though no file changed: the operator may have provisioned the
    vector runtime AFTER the corpus was indexed, and without this the
    new sidecar would stay empty forever (Codex P1 on PR #214). The
    ChunkCount>0 guard keeps an empty corpus from loading the ONNX
    model on every sync just to rebuild nothing. No-op when the vector
    runtime isn't provisioned (TryEnsureVector is the gate). }
  if (ChunkCount > 0) and (Changed or not VectorInSync) and TryEnsureVector then
    RebuildVectorSidecar;
end;

function TKBIndexImpl.VecSidecarPath: string;
begin
  Result := FDbPath + '.vec';
end;

function TKBIndexImpl.EmbedText(const T: string): TArray<Single>;
var
  TokenIds: TArray<Int64>;
const
  MAX_SEQ_LEN = 256;  { same bound PasClaw.Memory.Vector uses }
begin
  TokenIds := FTokenizer.Encode(UnicodeString(T), MAX_SEQ_LEN);
  Result := FEmbedder.Embed(TokenIds, FModelSpec.Pooling,
                            FModelSpec.NeedsTokenTypeIds,
                            {ANormalize=} True,
                            {AVerbose=}  False);
end;

function TKBIndexImpl.TryEnsureVector: Boolean;
var
  Cfg: TConfig;
  CacheDir, ExtPath: string;
begin
  if FStore <> nil then Exit(True);
  if FVecTried then Exit(False);
  FVecTried := True;
  Result := False;

  Cfg := LoadEffectiveConfig;
  try
    if not Cfg.VectorSearchEnabled then Exit;
  finally
    Cfg.Free;
  end;
  if not VectorArtifactsPresent(FModelSpec) then
  begin
    LogDebug('kb.index: vector runtime not provisioned — FTS5-only ' +
             '(run `pasclaw memory provision`)', []);
    Exit;
  end;

  CacheDir := JoinPath(JoinPath(GetHome, 'cache'), 'localvector');
  {$IFDEF MSWINDOWS}
  ExtPath := JoinPath(CacheDir, 'vec0.dll');
  {$ELSE}
    {$IFDEF DARWIN}
    ExtPath := JoinPath(CacheDir, 'vec0.dylib');
    {$ELSE}
    ExtPath := JoinPath(CacheDir, 'vec0.so');
    {$ENDIF}
  {$ENDIF}
  try
    EnsureOnnxRuntime(CacheDir, {AAllowDownload=} False, {AVerbose=} False);
    FTokenizer := TBertTokenizer.Create(
      JoinPath(JoinPath(JoinPath(CacheDir, 'models'), FModelSpec.SubDir), 'vocab.txt'),
      FModelSpec.DoLowerCase);
    FEmbedder := TEmbedder.Create(
      JoinPath(JoinPath(JoinPath(CacheDir, 'models'), FModelSpec.SubDir), 'model.onnx'));
    FEmbedder.Load({AVerbose=} False);
    FStore := CreateVectorStore;
    FStore.OpenStore(VecSidecarPath, ExtPath);
    FStore.InitSchema(FModelSpec.Dim, FModelSpec.Key);
    Result := True;
    LogDebug('kb.index: vector sidecar active (%s, dim=%d)',
             [FModelSpec.Key, FModelSpec.Dim]);
  except
    on E: Exception do
    begin
      LogDebug('kb.index: vector init failed (%s) — FTS5-only', [E.Message]);
      if FStore <> nil then begin try FStore.CloseStore; except end; FStore := nil; end;
      FreeAndNil(FEmbedder);
      FreeAndNil(FTokenizer);
    end;
  end;
end;

function TKBIndexImpl.ChunkCount: Int64;
begin
  if not QueryI64('SELECT COUNT(*) FROM kb_chunks', [], [], Result) then
    Result := 0;
end;

procedure TKBIndexImpl.SetMeta(const Key, Val: string);
begin
  ExecP('INSERT OR REPLACE INTO kb_meta (key, val) VALUES (:k, :v)',
        ['k', 'v'], [Key, Val], [], []);
end;

function TKBIndexImpl.GetMetaI64(const Key: string; out Val: Int64): Boolean;
begin
  Result := QueryI64('SELECT CAST(val AS INTEGER) FROM kb_meta WHERE key = :k',
                     ['k'], [Key], Val);
end;

function TKBIndexImpl.VectorInSync: Boolean;
{ True iff the vector sidecar exists on disk AND its recorded chunk
  population matches kb_chunks. The 'vec_chunks' meta row is written
  only by a fully successful RebuildVectorSidecar (it is poisoned to -1
  while a rebuild is in flight), so a missing/half-built/stale sidecar
  always reads as out of sync. Gates both Search's vector path (an
  out-of-sync sidecar would silently hide documents — Codex P1 on
  PR #214) and Sync's rebuild decision. }
var
  Recorded: Int64;
begin
  Result := FileExists(VecSidecarPath) and
            GetMetaI64('vec_chunks', Recorded) and
            (Recorded = ChunkCount);
end;

procedure TKBIndexImpl.RebuildVectorSidecar;
var
  Rows: TStringList;
  i, T1, T2: Integer;
  Line, Path, Body: string;
  ChunkNo: Integer;
  Emb: TArray<Single>;
begin
  if FStore = nil then Exit;
  { Poison the sync marker first: if this rebuild dies mid-flight the
    sidecar must read as out-of-sync (-1 can never equal a COUNT), so
    Search keeps using FTS instead of the half-built store. The real
    count is recorded only after a clean CommitBatch. }
  SetMeta('vec_chunks', '-1');
  { Recreate the sidecar from scratch: close, delete the file, reopen.
    The chunk store in kb.db is the source of truth. }
  try FStore.CloseStore; except end;
  FStore := nil;
  if FileExists(VecSidecarPath) then DeleteFile(VecSidecarPath);
  FVecTried := False;
  if not TryEnsureVector then Exit;

  { Tab-encoded triple per row: path<TAB>chunk_no<TAB>body. Paths and
    chunk numbers cannot contain TABs; the body may, so split only the
    first two. }
  Rows := QueryStrings(
    'SELECT path || char(9) || chunk_no || char(9) || body ' +
    'FROM kb_chunks ORDER BY path, chunk_no', [], []);
  try
    FStore.BeginBatch;
    try
      for i := 0 to Rows.Count - 1 do
      begin
        Line := Rows[i];
        T1 := Pos(#9, Line);
        if T1 = 0 then Continue;
        T2 := PosEx(#9, Line, T1 + 1);
        if T2 = 0 then Continue;
        Path    := Copy(Line, 1, T1 - 1);
        ChunkNo := StrToIntDef(Copy(Line, T1 + 1, T2 - T1 - 1), 0);
        Body    := Copy(Line, T2 + 1, MaxInt);
        try
          Emb := EmbedText(Body);
          FStore.AddChunk(Path, ChunkNo, Body, Emb);
        except
          on E: Exception do
            LogDebug('kb.index: embed failed for %s#c%d — %s',
                     [Path, ChunkNo, E.Message]);
        end;
      end;
      FStore.CommitBatch;
      SetMeta('vec_chunks', IntToStr(Rows.Count));
      LogDebug('kb.index: vector sidecar rebuilt (%d chunks)', [Rows.Count]);
    except
      on E: Exception do
      begin
        { Meta stays at the -1 poison: the sidecar reads out-of-sync
          and the next Sync retries the rebuild. }
        LogWarn('kb.index: vector rebuild failed mid-batch — %s', [E.Message]);
        try FStore.CommitBatch; except end;
      end;
    end;
  finally
    Rows.Free;
  end;
end;

function TKBIndexImpl.Search(const Query: string; K: Integer): TKBHitArray;
var
  Emb: TArray<Single>;
  VHits: TSearchHits;
  i: Integer;
  Sanitized: string;
{$IFDEF FPC}
  Q: TSQLQuery;
{$ELSE}
  Q: TFDQuery;
{$ENDIF}
  N: Integer;
begin
  SetLength(Result, 0);
  if not FOpen then Exit;
  if K <= 0 then K := 5;

  { Hybrid path when provisioned AND the sidecar matches the chunk
    store: the sidecar's internal FTS+vec RRF fusion ranks; chunk text
    comes back as the snippet (same trade PasClaw.Memory.Vector makes).

    VectorInSync must gate BEFORE TryEnsureVector: an out-of-sync or
    not-yet-built sidecar (vector provisioned after the last sync)
    would otherwise be created empty right here and silently hide
    every document (Codex P1 on PR #214). Until the operator runs
    `pasclaw kb sync`, queries stay on the always-correct FTS path —
    the rebuild itself belongs in Sync, Search must stay cheap. }
  if VectorInSync and TryEnsureVector then
  begin
    try
      Emb := EmbedText(Query);
      VHits := FStore.Search(Query, Emb, smHybrid, K);
      SetLength(Result, Length(VHits));
      for i := 0 to High(VHits) do
      begin
        Result[i].Path    := VHits[i].Source;
        Result[i].ChunkNo := VHits[i].ChunkIndex;
        Result[i].Snippet := VHits[i].Text;
        Result[i].Score   := VHits[i].Score;
      end;
      Exit;
    except
      on E: Exception do
        LogDebug('kb.index: vector search failed (%s) — FTS5 fallback',
                 [E.Message]);
    end;
  end;

  Sanitized := SanitizeFtsQuery(Query);
  if Sanitized = '' then Exit;

  {$IFDEF FPC}
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text :=
      'SELECT path, chunk_no, snippet(kb_fts, 2, ''«'', ''»'', ''…'', ' +
      IntToStr(FTS5_SNIPPET_TOKENS) + '), bm25(kb_fts) ' +
      'FROM kb_fts WHERE kb_fts MATCH :q ORDER BY bm25(kb_fts) LIMIT :k';
    Q.Params.ParamByName('q').AsString  := Sanitized;
    Q.Params.ParamByName('k').AsInteger := K;
    try
      Q.Open;
    except
      on E: Exception do
      begin
        LogWarn('kb.index: search %s failed (%s)', [Query, E.Message]);
        Exit;
      end;
    end;
    N := 0;
    while (not Q.EOF) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Path    := Q.Fields[0].AsString;
      Result[N].ChunkNo := Q.Fields[1].AsInteger;
      Result[N].Snippet := Q.Fields[2].AsString;
      Result[N].Score   := Q.Fields[3].AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
  {$ELSE}
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT path, chunk_no, snippet(kb_fts, 2, ''«'', ''»'', ''…'', ' +
      IntToStr(FTS5_SNIPPET_TOKENS) + '), bm25(kb_fts) ' +
      'FROM kb_fts WHERE kb_fts MATCH :q ORDER BY bm25(kb_fts) LIMIT :k';
    Q.ParamByName('q').AsString  := Sanitized;
    Q.ParamByName('k').AsInteger := K;
    try
      Q.Open;
    except
      on E: Exception do
      begin
        LogWarn('kb.index: search %s failed (%s)', [Query, E.Message]);
        Exit;
      end;
    end;
    N := 0;
    while (not Q.Eof) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Path    := Q.Fields[0].AsString;
      Result[N].ChunkNo := Q.Fields[1].AsInteger;
      Result[N].Snippet := Q.Fields[2].AsString;
      Result[N].Score   := Q.Fields[3].AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
  {$ENDIF}
end;

function TKBIndexImpl.GetChunks(const Path: string; ChunkNo, Window: Integer): string;
var
  Lo, Hi: Integer;
  Sb: TStringBuilder;
{$IFDEF FPC}
  Q: TSQLQuery;
{$ELSE}
  Q: TFDQuery;
{$ENDIF}
begin
  Result := '';
  if not FOpen then Exit;
  if Window < 0 then Window := 0;
  Lo := ChunkNo - Window;
  if Lo < 0 then Lo := 0;
  Hi := ChunkNo + Window;

  Sb := TStringBuilder.Create;
  try
    {$IFDEF FPC}
    Q := TSQLQuery.Create(nil);
    try
      Q.Database := FConn;
      Q.SQL.Text :=
        'SELECT chunk_no, body FROM kb_chunks ' +
        'WHERE path = :p AND chunk_no BETWEEN :a AND :b ORDER BY chunk_no';
      Q.Params.ParamByName('p').AsString  := Path;
      Q.Params.ParamByName('a').AsInteger := Lo;
      Q.Params.ParamByName('b').AsInteger := Hi;
      Q.Open;
      while not Q.EOF do
      begin
        if Sb.Length > 0 then Sb.Append(#10#10);
        Sb.Append(Format('--- %s#c%d ---', [Path, Q.Fields[0].AsInteger]));
        Sb.Append(#10);
        Sb.Append(Q.Fields[1].AsString);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;
    {$ELSE}
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text :=
        'SELECT chunk_no, body FROM kb_chunks ' +
        'WHERE path = :p AND chunk_no BETWEEN :a AND :b ORDER BY chunk_no';
      Q.ParamByName('p').AsString  := Path;
      Q.ParamByName('a').AsInteger := Lo;
      Q.ParamByName('b').AsInteger := Hi;
      Q.Open;
      while not Q.Eof do
      begin
        if Sb.Length > 0 then Sb.Append(#10#10);
        Sb.Append(Format('--- %s#c%d ---', [Path, Q.Fields[0].AsInteger]));
        Sb.Append(#10);
        Sb.Append(Q.Fields[1].AsString);
        Q.Next;
      end;
      Q.Close;
    finally
      Q.Free;
    end;
    {$ENDIF}
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

function TKBIndexImpl.Stats: TKBStats;
var
  V: Int64;
  Cfg: TConfig;
begin
  Result.Sources := 0;
  Result.Files   := 0;
  Result.Chunks  := 0;
  Result.VectorReady := False;
  if not FOpen then Exit;
  if QueryI64('SELECT COUNT(*) FROM kb_sources', [], [], V) then Result.Sources := V;
  { nchunks > 0 — skip markers aren't documents; see GetSources. }
  if QueryI64('SELECT COUNT(*) FROM kb_files WHERE nchunks > 0', [], [], V) then
    Result.Files := V;
  if QueryI64('SELECT COUNT(*) FROM kb_chunks',  [], [], V) then Result.Chunks  := V;
  Cfg := LoadEffectiveConfig;
  try
    Result.VectorReady := Cfg.VectorSearchEnabled and
                          VectorArtifactsPresent(FModelSpec);
  finally
    Cfg.Free;
  end;
end;

end.
