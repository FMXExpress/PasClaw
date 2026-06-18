(*
  PasClaw.Memory.Index - SQLite + FTS5 keyword index over the workspace
  memory directory.

  PasClaw's memory model follows openclaw: durable notes live as
  Markdown files (MEMORY.md, workspace/memory/YYYY-MM-DD.md). This unit
  builds a derived FTS5 index over those files so the model can search
  past memories with BM25 ranking via the memory_search tool. Files
  remain the source of truth; the DB is a lazy-rebuilt cache.

  Lifecycle:
    1. NewMemoryIndex returns an IMemoryIndex with no resources held.
    2. Open(DbPath) opens (or creates) the SQLite file and ensures the
       schema. Returns False and logs a warning if libsqlite3 can't be
       loaded; memory_search then degrades to "index unavailable".
    3. SyncDir walks the directory's *.md files, compares mtimes against
       the memory_files table, and reindexes whatever changed. Files
       that disappeared from disk are dropped from the index. Called at
       the start of every Search.
    4. Search runs an FTS5 MATCH query and returns up to K hits, each
       with the source path, a snippet around the matched term, and the
       BM25 score (smaller = better).
    5. Close releases the connection. Destructor calls Close.

  Cross-target split:
    - {$IFDEF FPC}: TSQLite3Connection + TSQLQuery from sqldb. Needs
      fcl-db at build time; libsqlite3 at runtime.
    - {$ELSE}: FireDAC's TFDConnection + TFDQuery. Needs FireDAC at
      build time (ships with Delphi); sqlite3.dll at runtime.

  Schema:
    memory_files(rowid INTEGER PK, path TEXT UNIQUE, mtime INTEGER,
                 indexed_at INTEGER)
    memory_fts USING fts5(path UNINDEXED, content,
                          tokenize='porter unicode61')

    Each indexed file is one FTS5 row, sharing rowid with memory_files.
    The reindex path deletes the file row in memory_files (CASCADE-like
    via explicit DELETE on memory_fts first) and re-inserts. Avoids
    rowid-sync drift across updates.
*)
unit PasClaw.Memory.Index;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TMemoryHit = record
    Path:    string;
    Snippet: string;
    Score:   Double;
  end;
  TMemoryHitArray = array of TMemoryHit;

  IMemoryIndex = interface
    ['{6A4B9F2C-3D1E-4A50-9C8B-7F1A2D3E4B91}']
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    procedure SyncDir(const Dir: string);
    function  Search(const Query: string; K: Integer): TMemoryHitArray;
  end;

function NewMemoryIndex: IMemoryIndex;

const
  (* Token budget for the FTS5 snippet() window. 64 is FTS5's hard
     ceiling; 60 leaves a sliver of slack for the «...» highlight
     markup. The historical width of 24 routinely clipped the actual
     answer line out of the returned snippet (LOCOMO bench: snippet
     R@10 ≈ 0.75 with width=24 vs 1.0 with width=60). Exposed in the
     interface so PasClaw.KB.Index can pin its kb_search snippets to
     the same width. *)
  FTS5_SNIPPET_TOKENS = 60;

(* Turn a natural-language query into an FTS5-safe MATCH expression
   (OR-ed quoted tokens; ASCII punctuation stripped; UTF-8 token
   bytes preserved). Exposed so PasClaw.Session.Search can reuse the
   exact same query normalisation rather than re-deriving it -- the
   two indexes must treat "what did we discuss?" identically or
   operators get confusingly different hit sets from memory_search
   vs session_search. Returns '' for all-separator input (caller
   early-exits). *)
function SanitizeFtsQuery(const Raw: string): string;

implementation

uses
  DateUtils,
  {$IFDEF FPC}
  sqldb, sqlite3conn,
  {$ELSE}
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Stan.Def,
  FireDAC.Stan.Async, FireDAC.Stan.Param, FireDAC.DApt,
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Logger;

function SanitizeFtsQuery(const Raw: string): string;
(* Turn a natural-language query string into an FTS5-safe MATCH
   expression. FTS5 treats unquoted ASCII punctuation (?, +, :, /,
   unbalanced quotes, etc.) as syntax, so a conversational query like
   "what did we discuss?" or a code token like "C++", "foo/bar", or
   "skill_<name>" raises a parse error that bubbles up as "no matches"
   even when the indexed content is right there.

   Strategy: split the input on every non-token byte and reassemble as
   OR-ed quoted phrases. Bytes >= $80 are treated as token bytes so
   UTF-8 multi-byte sequences survive intact (the porter unicode61
   tokenizer FTS5 was created with will fold them properly at index
   time). The empty-string result signals the caller to early-exit.

   OR over AND: natural-language queries include filler words
   ("what", "did", "we") that won't appear in terse notes. AND would
   require every token to match and silently return zero hits the
   moment any filler is missing. OR returns matches as soon as ANY
   token lands, and BM25 ranks documents that match more tokens
   higher -- so the top-K results are still the most relevant ones,
   and "what did we discuss authentication?" still finds the note
   that mentions "discussed authentication tokens".

   Examples (arrow is the produced MATCH expression):
     what did we discuss?  ->  "what" OR "did" OR "we" OR "discuss"
     C++                   ->  "C"
     foo/bar baz           ->  "foo" OR "bar" OR "baz"
     authentication        ->  "authentication"
     ?!?                   ->  (empty -- all-separator input)
*)

  function IsTokenByte(B: Byte): Boolean;
  begin
    Result := ((B >= Ord('a')) and (B <= Ord('z'))) or
              ((B >= Ord('A')) and (B <= Ord('Z'))) or
              ((B >= Ord('0')) and (B <= Ord('9'))) or
              (B = Ord('_')) or
              (B >= $80);
  end;

var
  i: Integer;
  Cur: string;
  Tokens: TStringList;
begin
  Result := '';
  if Trim(Raw) = '' then Exit;

  Tokens := TStringList.Create;
  try
    Cur := '';
    for i := 1 to Length(Raw) do
    begin
      if IsTokenByte(Byte(Raw[i])) then
        Cur := Cur + Raw[i]
      else if Cur <> '' then
      begin
        Tokens.Add(Cur);
        Cur := '';
      end;
    end;
    if Cur <> '' then Tokens.Add(Cur);

    for i := 0 to Tokens.Count - 1 do
    begin
      if Result <> '' then Result := Result + ' OR ';
      Result := Result + '"' + Tokens[i] + '"';
    end;
  finally
    Tokens.Free;
  end;
end;

type
  TMemoryIndexImpl = class(TInterfacedObject, IMemoryIndex)
  private
    {$IFDEF FPC}
    FConn:  TSQLite3Connection;
    FTx:    TSQLTransaction;
    {$ELSE}
    FConn:  TFDConnection;
    {$ENDIF}
    FOpen:  Boolean;
    procedure ExecSQL(const SQL: string);
    procedure EnsureSchema;
    function  FileMtime(const Path: string): Int64;
    function  IndexedMtime(const Path: string; out Mtime: Int64): Boolean;
    procedure ReindexFile(const Path: string; Mtime: Int64);
    procedure DropMissingFiles(const KnownPaths: TStringList);
  public
    destructor Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    procedure SyncDir(const Dir: string);
    function  Search(const Query: string; K: Integer): TMemoryHitArray;
  end;

function NewMemoryIndex: IMemoryIndex;
begin
  Result := TMemoryIndexImpl.Create;
end;

destructor TMemoryIndexImpl.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TMemoryIndexImpl.ExecSQL(const SQL: string);
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

procedure TMemoryIndexImpl.EnsureSchema;
begin
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS memory_files (' +
    '  rowid INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  path TEXT UNIQUE NOT NULL,' +
    '  mtime INTEGER NOT NULL,' +
    '  indexed_at INTEGER NOT NULL)');
  ExecSQL(
    'CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(' +
    '  path UNINDEXED, content,' +
    '  tokenize=''porter unicode61'')');
end;

function TMemoryIndexImpl.Open(const DbPath: string): Boolean;
begin
  Result := False;
  if FOpen then Exit(True);

  try
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
    LogDebug('memory.index: opened %s', [DbPath]);
  except
    on E: Exception do
    begin
      LogWarn('memory.index: failed to open %s (%s) -- memory_search disabled',
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

procedure TMemoryIndexImpl.Close;
begin
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
      LogWarn('memory.index: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TMemoryIndexImpl.FileMtime(const Path: string): Int64;
var
  Dt: TDateTime;
begin
  Result := 0;
  { Modern FileAge overload (FPC 3.0+ and Delphi for years) returns
    the mtime as a TDateTime via the out parameter and signals
    success/failure via Boolean. The legacy `FileAge(s): Integer`
    form is deprecated on dcc64 (W1000) because it returns a
    DOS-format integer that needs FileDateToDateTime. Same value
    either way; this form just skips the conversion. }
  if not FileAge(Path, Dt) then Exit;
  Result := DateTimeToUnix(Dt, False);
end;

function TMemoryIndexImpl.IndexedMtime(const Path: string; out Mtime: Int64): Boolean;
{$IFDEF FPC}
var
  Q: TSQLQuery;
begin
  Result := False;
  Mtime  := 0;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text := 'SELECT mtime FROM memory_files WHERE path = :p';
    Q.Params.ParamByName('p').AsString := Path;
    Q.Open;
    if not Q.EOF then
    begin
      Mtime  := Q.Fields[0].AsLargeInt;
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
begin
  Result := False;
  Mtime  := 0;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'SELECT mtime FROM memory_files WHERE path = :p';
    Q.ParamByName('p').AsString := Path;
    Q.Open;
    if not Q.Eof then
    begin
      Mtime  := Q.Fields[0].AsLargeInt;
      Result := True;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

procedure TMemoryIndexImpl.ReindexFile(const Path: string; Mtime: Int64);
var
  Content: string;
  Now_:    Int64;
{$IFDEF FPC}
  Q: TSQLQuery;
{$ELSE}
  Q: TFDQuery;
{$ENDIF}
begin
  try
    Content := ReadFileText(Path);
  except
    on E: Exception do
    begin
      LogWarn('memory.index: read %s failed (%s) -- skipping', [Path, E.Message]);
      Exit;
    end;
  end;
  Now_ := DateTimeToUnix(Now, False);

  { Delete existing rows for this path so we don't accumulate
    duplicates on rewrite. memory_fts rowid is linked to
    memory_files.rowid via the explicit INSERT below. }
  {$IFDEF FPC}
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text :=
      'DELETE FROM memory_fts WHERE rowid IN (SELECT rowid FROM memory_files WHERE path = :p)';
    Q.Params.ParamByName('p').AsString := Path;
    Q.ExecSQL;

    Q.SQL.Text := 'DELETE FROM memory_files WHERE path = :p';
    Q.Params.ParamByName('p').AsString := Path;
    Q.ExecSQL;

    Q.SQL.Text :=
      'INSERT INTO memory_files (path, mtime, indexed_at) VALUES (:p, :m, :i)';
    Q.Params.ParamByName('p').AsString    := Path;
    Q.Params.ParamByName('m').AsLargeInt  := Mtime;
    Q.Params.ParamByName('i').AsLargeInt  := Now_;
    Q.ExecSQL;

    Q.SQL.Text :=
      'INSERT INTO memory_fts (rowid, path, content) ' +
      'VALUES ((SELECT rowid FROM memory_files WHERE path = :p), :p, :c)';
    Q.Params.ParamByName('p').AsString := Path;
    Q.Params.ParamByName('c').AsString := Content;
    Q.ExecSQL;

    FTx.CommitRetaining;
  finally
    Q.Free;
  end;
  {$ELSE}
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'DELETE FROM memory_fts WHERE rowid IN (SELECT rowid FROM memory_files WHERE path = :p)';
    Q.ParamByName('p').AsString := Path;
    Q.ExecSQL;

    Q.SQL.Text := 'DELETE FROM memory_files WHERE path = :p';
    Q.ParamByName('p').AsString := Path;
    Q.ExecSQL;

    Q.SQL.Text :=
      'INSERT INTO memory_files (path, mtime, indexed_at) VALUES (:p, :m, :i)';
    Q.ParamByName('p').AsString   := Path;
    Q.ParamByName('m').AsLargeInt := Mtime;
    Q.ParamByName('i').AsLargeInt := Now_;
    Q.ExecSQL;

    Q.SQL.Text :=
      'INSERT INTO memory_fts (rowid, path, content) ' +
      'VALUES ((SELECT rowid FROM memory_files WHERE path = :p), :p, :c)';
    Q.ParamByName('p').AsString := Path;
    Q.ParamByName('c').AsString := Content;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
  {$ENDIF}
end;

procedure TMemoryIndexImpl.DropMissingFiles(const KnownPaths: TStringList);
{$IFDEF FPC}
var
  Q:      TSQLQuery;
  Stale:  TStringList;
  Path:   string;
begin
  Stale := TStringList.Create;
  try
    Q := TSQLQuery.Create(nil);
    try
      Q.Database := FConn;
      Q.SQL.Text := 'SELECT path FROM memory_files';
      Q.Open;
      while not Q.EOF do
      begin
        Path := Q.Fields[0].AsString;
        if KnownPaths.IndexOf(Path) < 0 then
          Stale.Add(Path);
        Q.Next;
      end;
      Q.Close;

      for Path in Stale do
      begin
        Q.SQL.Text :=
          'DELETE FROM memory_fts WHERE rowid IN (SELECT rowid FROM memory_files WHERE path = :p)';
        Q.Params.ParamByName('p').AsString := Path;
        Q.ExecSQL;
        Q.SQL.Text := 'DELETE FROM memory_files WHERE path = :p';
        Q.Params.ParamByName('p').AsString := Path;
        Q.ExecSQL;
        LogDebug('memory.index: dropped stale %s', [Path]);
      end;
      if Stale.Count > 0 then FTx.CommitRetaining;
    finally
      Q.Free;
    end;
  finally
    Stale.Free;
  end;
end;
{$ELSE}
var
  Q:     TFDQuery;
  Stale: TStringList;
  Path:  string;
begin
  Stale := TStringList.Create;
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'SELECT path FROM memory_files';
      Q.Open;
      while not Q.Eof do
      begin
        Path := Q.Fields[0].AsString;
        if KnownPaths.IndexOf(Path) < 0 then
          Stale.Add(Path);
        Q.Next;
      end;
      Q.Close;

      for Path in Stale do
      begin
        Q.SQL.Text :=
          'DELETE FROM memory_fts WHERE rowid IN (SELECT rowid FROM memory_files WHERE path = :p)';
        Q.ParamByName('p').AsString := Path;
        Q.ExecSQL;
        Q.SQL.Text := 'DELETE FROM memory_files WHERE path = :p';
        Q.ParamByName('p').AsString := Path;
        Q.ExecSQL;
        LogDebug('memory.index: dropped stale %s', [Path]);
      end;
    finally
      Q.Free;
    end;
  finally
    Stale.Free;
  end;
end;
{$ENDIF}

procedure TMemoryIndexImpl.SyncDir(const Dir: string);
var
  Sr:     TSearchRec;
  Path:   string;
  Mtime:  Int64;
  Idx:    Int64;
  Found:  Boolean;
  Known:  TStringList;
  MemoryMd: string;
begin
  if not FOpen then Exit;

  Known := TStringList.Create;
  try
    Known.Sorted := False;

    { workspace/memory/MEMORY.md -- durable note, top-of-tree. }
    MemoryMd := JoinPath(Dir, 'MEMORY.md');
    if FileExists(MemoryMd) then Known.Add(MemoryMd);

    { workspace/memory/*.md -- daily notes and ad-hoc files. }
    if FindFirst(JoinPath(Dir, '*.md'), faAnyFile, Sr) = 0 then
    try
      repeat
        if (Sr.Attr and faDirectory) <> 0 then Continue;
        if SameText(Sr.Name, 'MEMORY.md') then Continue;
        Path := JoinPath(Dir, Sr.Name);
        Known.Add(Path);
      until FindNext(Sr) <> 0;
    finally
      FindClose(Sr);
    end;

    for Path in Known do
    begin
      Mtime := FileMtime(Path);
      if Mtime = 0 then Continue;
      Found := IndexedMtime(Path, Idx);
      if (not Found) or (Idx < Mtime) then
        ReindexFile(Path, Mtime);
    end;

    DropMissingFiles(Known);
  finally
    Known.Free;
  end;
end;

function TMemoryIndexImpl.Search(const Query: string; K: Integer): TMemoryHitArray;
{$IFDEF FPC}
var
  Q:         TSQLQuery;
  N:         Integer;
  Sanitized: string;
begin
  SetLength(Result, 0);
  if not FOpen then Exit;
  Sanitized := SanitizeFtsQuery(Query);
  if Sanitized = '' then Exit;
  if K <= 0 then K := 5;

  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text :=
      'SELECT path, snippet(memory_fts, 1, ''«'', ''»'', ''…'', ' +
      IntToStr(FTS5_SNIPPET_TOKENS) + '), bm25(memory_fts) ' +
      'FROM memory_fts WHERE memory_fts MATCH :q ' +
      'ORDER BY bm25(memory_fts) LIMIT :k';
    Q.Params.ParamByName('q').AsString := Sanitized;
    Q.Params.ParamByName('k').AsInteger := K;
    try
      Q.Open;
    except
      on E: Exception do
      begin
        LogWarn('memory.index: search %s failed (%s)', [Query, E.Message]);
        Exit;
      end;
    end;
    N := 0;
    while (not Q.EOF) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Path    := Q.Fields[0].AsString;
      Result[N].Snippet := Q.Fields[1].AsString;
      Result[N].Score   := Q.Fields[2].AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ELSE}
var
  Q:         TFDQuery;
  N:         Integer;
  Sanitized: string;
begin
  SetLength(Result, 0);
  if not FOpen then Exit;
  Sanitized := SanitizeFtsQuery(Query);
  if Sanitized = '' then Exit;
  if K <= 0 then K := 5;

  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text :=
      'SELECT path, snippet(memory_fts, 1, ''«'', ''»'', ''…'', ' +
      IntToStr(FTS5_SNIPPET_TOKENS) + '), bm25(memory_fts) ' +
      'FROM memory_fts WHERE memory_fts MATCH :q ' +
      'ORDER BY bm25(memory_fts) LIMIT :k';
    Q.ParamByName('q').AsString  := Sanitized;
    Q.ParamByName('k').AsInteger := K;
    try
      Q.Open;
    except
      on E: Exception do
      begin
        LogWarn('memory.index: search %s failed (%s)', [Query, E.Message]);
        Exit;
      end;
    end;
    N := 0;
    while (not Q.Eof) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Path    := Q.Fields[0].AsString;
      Result[N].Snippet := Q.Fields[1].AsString;
      Result[N].Score   := Q.Fields[2].AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

end.
