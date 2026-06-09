{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum -- PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.VectorStore.Sqlite;

{ Portable IVectorStore backend over the dynamically-loaded sqlite3 binding +
  sqlite-vec (vec0) + FTS5. Used by the FPC build (and any build that prefers a
  FireDAC-free path). }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

interface

uses
{$IFDEF FPC}
  SysUtils, Classes, Generics.Collections,
{$ELSE}
  System.SysUtils, System.Classes, System.Generics.Collections,
{$ENDIF}
  LocalVector.Sqlite3, LocalVector.VectorStore;

type
  TSqliteVectorStore = class(TInterfacedObject, IVectorStore)
  private
    FDb: PSQLite3;
    FDim: Integer;
    FModel: string;
    function MetaGet(const AKey: string): string;
    procedure MetaSet(const AKey, AValue: string);
    function TableExists(const AName: string): Boolean;
    procedure RunVecQuery(const ABlob: TBytes; ALimit: Integer;
      AIds: TList<Int64>; ADist: TDictionary<Int64, Double>);
    procedure RunFtsQuery(const AMatch: string; ALimit: Integer; AIds: TList<Int64>);
    function FetchHit(AId: Int64; AScore, ADist: Double): TSearchHit;
  public
    procedure OpenStore(const ADbPath, AVecExtPath: string);
    procedure InitSchema(ADim: Integer; const AModel: string);
    function MetaModel: string;
    function MetaDim: Integer;
    procedure BeginBatch;
    procedure CommitBatch;
    function AddChunk(const ASource: string; AChunkIndex: Integer;
      const AText: string; const AEmbedding: TArray<Single>): Int64;
    function Search(const AQueryText: string; const AQueryEmbedding: TArray<Single>;
      AMode: TSearchMode; AK: Integer): TSearchHits;
    procedure CloseStore;
  end;

implementation

procedure TSqliteVectorStore.OpenStore(const ADbPath, AVecExtPath: string);
begin
  if not LoadSqlite3 then
    raise ESQLiteError.Create('Could not load the sqlite3 library.');
  FDb := sqlite_open(ADbPath);
  // SQLite appends the platform suffix (.so/.dll/.dylib) itself, so strip it.
  sqlite_load_extension(FDb, ChangeFileExt(AVecExtPath, ''), 'sqlite3_vec_init');
end;

function TSqliteVectorStore.MetaGet(const AKey: string): string;
var
  st: PSQLite3Stmt;
begin
  Result := '';
  st := sqlite_prepare(FDb, 'SELECT value FROM meta WHERE key=?');
  try
    sqlite_bind_text(st, 1, AKey);
    if sqlite_step(st) = SQLITE_ROW then
      Result := sqlite_column_text(st, 0);
  finally
    sqlite_finalize(st);
  end;
end;

procedure TSqliteVectorStore.MetaSet(const AKey, AValue: string);
var
  st: PSQLite3Stmt;
begin
  st := sqlite_prepare(FDb, 'INSERT OR REPLACE INTO meta(key,value) VALUES(?,?)');
  try
    sqlite_bind_text(st, 1, AKey);
    sqlite_bind_text(st, 2, AValue);
    sqlite_step(st);
  finally
    sqlite_finalize(st);
  end;
end;

function TSqliteVectorStore.TableExists(const AName: string): Boolean;
var
  st: PSQLite3Stmt;
begin
  st := sqlite_prepare(FDb,
    'SELECT 1 FROM sqlite_master WHERE type IN (''table'',''view'') AND name=?');
  try
    sqlite_bind_text(st, 1, AName);
    Result := sqlite_step(st) = SQLITE_ROW;
  finally
    sqlite_finalize(st);
  end;
end;

procedure TSqliteVectorStore.InitSchema(ADim: Integer; const AModel: string);
var
  ExistingDim, ExistingModel: string;
begin
  sqlite_exec(FDb, 'CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)');

  if TableExists('chunks') then
  begin
    ExistingDim := MetaGet('dim');
    ExistingModel := MetaGet('model');
    if (ADim > 0) and (ExistingDim <> '') and (StrToIntDef(ExistingDim, -1) <> ADim) then
      raise ESQLiteError.CreateFmt(
        'Database was built with %s (dim %s); cannot mix with %s (dim %d).',
        [ExistingModel, ExistingDim, AModel, ADim]);
    FDim := StrToIntDef(ExistingDim, ADim);
    FModel := ExistingModel;
    Exit;
  end;

  if ADim <= 0 then
    raise ESQLiteError.Create('Database has no index yet (run "index" first).');

  FDim := ADim;
  FModel := AModel;
  sqlite_exec(FDb,
    'CREATE TABLE chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'source TEXT, chunk_index INTEGER, text TEXT)');
  sqlite_exec(FDb, 'CREATE VIRTUAL TABLE chunks_fts USING fts5(text)');
  sqlite_exec(FDb, Format(
    'CREATE VIRTUAL TABLE chunks_vec USING vec0(embedding float[%d])', [ADim]));
  MetaSet('model', AModel);
  MetaSet('dim', IntToStr(ADim));
end;

function TSqliteVectorStore.MetaModel: string;
begin
  Result := FModel;
end;

function TSqliteVectorStore.MetaDim: Integer;
begin
  Result := FDim;
end;

procedure TSqliteVectorStore.BeginBatch;
begin
  sqlite_exec(FDb, 'BEGIN');
end;

procedure TSqliteVectorStore.CommitBatch;
begin
  sqlite_exec(FDb, 'COMMIT');
end;

function TSqliteVectorStore.AddChunk(const ASource: string; AChunkIndex: Integer;
  const AText: string; const AEmbedding: TArray<Single>): Int64;
var
  st: PSQLite3Stmt;
  Blob: TBytes;
begin
  st := sqlite_prepare(FDb,
    'INSERT INTO chunks(source, chunk_index, text) VALUES(?,?,?)');
  try
    sqlite_bind_text(st, 1, ASource);
    sqlite_bind_int64(st, 2, AChunkIndex);
    sqlite_bind_text(st, 3, AText);
    sqlite_step(st);
  finally
    sqlite_finalize(st);
  end;
  Result := sqlite_last_insert_rowid(FDb);

  st := sqlite_prepare(FDb, 'INSERT INTO chunks_fts(rowid, text) VALUES(?,?)');
  try
    sqlite_bind_int64(st, 1, Result);
    sqlite_bind_text(st, 2, AText);
    sqlite_step(st);
  finally
    sqlite_finalize(st);
  end;

  Blob := VectorToBytes(AEmbedding);
  st := sqlite_prepare(FDb, 'INSERT INTO chunks_vec(rowid, embedding) VALUES(?,?)');
  try
    sqlite_bind_int64(st, 1, Result);
    if Length(Blob) > 0 then
      sqlite_bind_blob(st, 2, Blob[0], Length(Blob));
    sqlite_step(st);
  finally
    sqlite_finalize(st);
  end;
end;

procedure TSqliteVectorStore.RunVecQuery(const ABlob: TBytes; ALimit: Integer;
  AIds: TList<Int64>; ADist: TDictionary<Int64, Double>);
var
  st: PSQLite3Stmt;
  Id: Int64;
begin
  st := sqlite_prepare(FDb, Format(
    'SELECT rowid, distance FROM chunks_vec WHERE embedding MATCH ? ' +
    'ORDER BY distance LIMIT %d', [ALimit]));
  try
    if Length(ABlob) > 0 then
      sqlite_bind_blob(st, 1, ABlob[0], Length(ABlob));
    while sqlite_step(st) = SQLITE_ROW do
    begin
      Id := sqlite_column_int64(st, 0);
      AIds.Add(Id);
      ADist.AddOrSetValue(Id, sqlite_column_double(st, 1));
    end;
  finally
    sqlite_finalize(st);
  end;
end;

procedure TSqliteVectorStore.RunFtsQuery(const AMatch: string; ALimit: Integer;
  AIds: TList<Int64>);
var
  st: PSQLite3Stmt;
begin
  if Trim(AMatch) = '' then
    Exit;
  st := sqlite_prepare(FDb, Format(
    'SELECT rowid FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY rank LIMIT %d',
    [ALimit]));
  try
    sqlite_bind_text(st, 1, AMatch);
    while sqlite_step(st) = SQLITE_ROW do
      AIds.Add(sqlite_column_int64(st, 0));
  finally
    sqlite_finalize(st);
  end;
end;

function TSqliteVectorStore.FetchHit(AId: Int64; AScore, ADist: Double): TSearchHit;
var
  st: PSQLite3Stmt;
begin
  Result.Id := AId;
  Result.Score := AScore;
  Result.VecDistance := ADist;
  Result.Source := '';
  Result.ChunkIndex := 0;
  Result.Text := '';
  st := sqlite_prepare(FDb, 'SELECT source, chunk_index, text FROM chunks WHERE id=?');
  try
    sqlite_bind_int64(st, 1, AId);
    if sqlite_step(st) = SQLITE_ROW then
    begin
      Result.Source := sqlite_column_text(st, 0);
      Result.ChunkIndex := sqlite_column_int64(st, 1);
      Result.Text := sqlite_column_text(st, 2);
    end;
  finally
    sqlite_finalize(st);
  end;
end;

function TSqliteVectorStore.Search(const AQueryText: string;
  const AQueryEmbedding: TArray<Single>; AMode: TSearchMode; AK: Integer): TSearchHits;
var
  Pool, I: Integer;
  VecIds, FtsIds: TList<Int64>;
  VecDist: TDictionary<Int64, Double>;
  Blob: TBytes;
  Fused: TArray<TIdScore>;
  D: Double;
  Hits: TList<TSearchHit>;
begin
  Pool := AK * 4;
  if Pool < 32 then Pool := 32;

  VecIds := TList<Int64>.Create;
  FtsIds := TList<Int64>.Create;
  VecDist := TDictionary<Int64, Double>.Create;
  Hits := TList<TSearchHit>.Create;
  try
    if AMode in [smHybrid, smVector] then
    begin
      Blob := VectorToBytes(AQueryEmbedding);
      RunVecQuery(Blob, Pool, VecIds, VecDist);
    end;
    if AMode in [smHybrid, smKeyword] then
      RunFtsQuery(BuildFtsQuery(AQueryText), Pool, FtsIds);

    case AMode of
      smVector:
        for I := 0 to VecIds.Count - 1 do
        begin
          if I >= AK then Break;
          D := VecDist[VecIds[I]];
          Hits.Add(FetchHit(VecIds[I], 1.0 / (1.0 + D), D));
        end;
      smKeyword:
        for I := 0 to FtsIds.Count - 1 do
        begin
          if I >= AK then Break;
          Hits.Add(FetchHit(FtsIds[I], 1.0 / (60 + I + 1), -1));
        end;
      smHybrid:
        begin
          Fused := FuseRRF(VecIds.ToArray, FtsIds.ToArray, AK, 60);
          for I := 0 to High(Fused) do
          begin
            if VecDist.TryGetValue(Fused[I].Id, D) then
              Hits.Add(FetchHit(Fused[I].Id, Fused[I].Score, D))
            else
              Hits.Add(FetchHit(Fused[I].Id, Fused[I].Score, -1));
          end;
        end;
    end;
    Result := Hits.ToArray;
  finally
    VecIds.Free;
    FtsIds.Free;
    VecDist.Free;
    Hits.Free;
  end;
end;

procedure TSqliteVectorStore.CloseStore;
begin
  if FDb <> nil then
  begin
    sqlite_close(FDb);
    FDb := nil;
  end;
end;

end.
