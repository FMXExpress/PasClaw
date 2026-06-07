{
  Vendored from FMXExpress/localvector (MIT licensed; LICENSE preserved
  alongside this file). Upstream commit: 0f00eece553da47e83169ddc8d72965c0dc40bcc.
  https://github.com/FMXExpress/localvector

  Modifications kept to a minimum — PasClaw uses these units verbatim
  as the in-tree implementation of the hybrid FTS5+vector memory backend
  (PasClaw.Memory.Vector). Diff against upstream for change tracking.
}

unit LocalVector.VectorStore.FireDAC;

{ FireDAC IVectorStore backend (Delphi). The default Delphi build uses this;
  define LV_PORTABLE_SQLITE to use the portable sqlite3 backend instead.

  sqlite-vec loading follows the documented FireDAC recipe:
    * a dynamic SQLite driver link bound to an external, extension-enabled
      sqlite3.dll  (FireDAC's bundled SQLite has load_extension disabled);
    * connection parameter Extensions=True;
    * SELECT load_extension('vec0.dll', 'sqlite3_vec_init').
  Deploy sqlite3.dll (with extension support) + vec0.dll next to the exe. }

{$IFDEF FPC}{$mode delphi}{$H+}{$ENDIF}

{ PasClaw modification: stub on Delphi Linux64.

  FireDAC.Phys.SQLiteWrapper.Stat (the static SQLite link) ships only
  for Windows / macOS / mobile in RAD Studio — Linux64 has no static
  build, only the dynamic libsqlite3.so path. PasClaw.dpr already
  routes around this constraint (PR #135 added the {$IFNDEF LINUX}
  guard there); we extend the same routing here so registering this
  unit in PasClaw.dproj doesn't break the Delphi Linux64 build.

  On Linux64 we compile to an empty unit and let
  LocalVector.VectorStore force LV_PORTABLE_SQLITE on — the factory
  then routes through the portable backend (dynamic libsqlite3.so),
  which Linux64 supports fine.

  Codex P1 on PR #167. }
{$IF DEFINED(LINUX) AND NOT DEFINED(FPC)}
interface
implementation
end.
{$IFEND}

interface

{$IFNDEF FPC}

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  Data.DB, FireDAC.Stan.Intf, FireDAC.Stan.Def, FireDAC.Stan.Async,
  FireDAC.Stan.Param, FireDAC.Phys, FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteWrapper.Stat,   // statically link SQLite (no external DLL/bitness)
  FireDAC.ConsoleUI.Wait,            // console wait handler (avoids UI factory error)
  FireDAC.DApt, FireDAC.Comp.Client,
  LocalVector.VectorStore;

type
  TFireDACVectorStore = class(TInterfacedObject, IVectorStore)
  private
    FConn: TFDConnection;
    FDim: Integer;
    FModel: string;
    function ScalarStr(const ASql, AParam: string): string;
    function TableExists(const AName: string): Boolean;
    function MetaGet(const AKey: string): string;
    procedure MetaSet(const AKey, AValue: string);
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

{$ENDIF}

implementation

{$IFNDEF FPC}

{ Bind a TBytes blob to a FireDAC param. (TFDParam.AsBytes is an indexed Byte
  property, so a whole array can't be assigned to it; use a stream.) }
procedure BindBlobParam(AParam: TFDParam; const ABytes: TBytes);
var
  MS: TBytesStream;
begin
  MS := TBytesStream.Create(ABytes);
  try
    AParam.LoadFromStream(MS, ftBlob);
  finally
    MS.Free;
  end;
end;

procedure TFireDACVectorStore.OpenStore(const ADbPath, AVecExtPath: string);
begin
  // SQLite is statically linked (FireDAC.Phys.SQLiteWrapper.Stat), so it matches
  // the exe bitness with no external sqlite3.dll. Extensions=True enables
  // load_extension so the vec0 extension can be loaded below.
  FConn := TFDConnection.Create(nil);
  FConn.LoginPrompt := False;
  FConn.Params.DriverID := 'SQLite';
  FConn.Params.Database := ADbPath;
  FConn.Params.Add('Extensions=True');   // enables sqlite3 load_extension
  FConn.Connected := True;

  // load_extension is a SELECT-style function, so use ExecSQLScalar (ExecSQL
  // rejects result-set commands). SQLite appends the platform suffix itself.
  FConn.ExecSQLScalar('SELECT load_extension(' + QuotedStr(ChangeFileExt(AVecExtPath, '')) +
    ', ' + QuotedStr('sqlite3_vec_init') + ')');
end;

function TFireDACVectorStore.ScalarStr(const ASql, AParam: string): string;
var
  Q: TFDQuery;
begin
  Result := '';
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := ASql;
    if AParam <> '' then
      Q.Params[0].AsString := AParam;
    Q.Open;
    if not Q.Eof then
      Result := Q.Fields[0].AsString;
  finally
    Q.Free;
  end;
end;

function TFireDACVectorStore.TableExists(const AName: string): Boolean;
begin
  Result := ScalarStr(
    'SELECT 1 FROM sqlite_master WHERE type IN (''table'',''view'') AND name=:n',
    AName) <> '';
end;

function TFireDACVectorStore.MetaGet(const AKey: string): string;
begin
  Result := ScalarStr('SELECT value FROM meta WHERE key=:k', AKey);
end;

procedure TFireDACVectorStore.MetaSet(const AKey, AValue: string);
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'INSERT OR REPLACE INTO meta(key,value) VALUES(:k,:v)';
    Q.ParamByName('k').AsString := AKey;
    Q.ParamByName('v').AsString := AValue;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TFireDACVectorStore.InitSchema(ADim: Integer; const AModel: string);
var
  ExistingDim, ExistingModel: string;
begin
  FConn.ExecSQL('CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)');
  if TableExists('chunks') then
  begin
    ExistingDim := MetaGet('dim');
    ExistingModel := MetaGet('model');
    if (ADim > 0) and (ExistingDim <> '') and (StrToIntDef(ExistingDim, -1) <> ADim) then
      raise Exception.CreateFmt(
        'Database was built with %s (dim %s); cannot mix with %s (dim %d).',
        [ExistingModel, ExistingDim, AModel, ADim]);
    FDim := StrToIntDef(ExistingDim, ADim);
    FModel := ExistingModel;
    Exit;
  end;
  if ADim <= 0 then
    raise Exception.Create('Database has no index yet (run "index" first).');
  FDim := ADim;
  FModel := AModel;
  FConn.ExecSQL('CREATE TABLE chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, ' +
    'source TEXT, chunk_index INTEGER, text TEXT)');
  FConn.ExecSQL('CREATE VIRTUAL TABLE chunks_fts USING fts5(text)');
  FConn.ExecSQL(Format(
    'CREATE VIRTUAL TABLE chunks_vec USING vec0(embedding float[%d])', [ADim]));
  MetaSet('model', AModel);
  MetaSet('dim', IntToStr(ADim));
end;

function TFireDACVectorStore.MetaModel: string;
begin
  Result := FModel;
end;

function TFireDACVectorStore.MetaDim: Integer;
begin
  Result := FDim;
end;

procedure TFireDACVectorStore.BeginBatch;
begin
  FConn.StartTransaction;
end;

procedure TFireDACVectorStore.CommitBatch;
begin
  FConn.Commit;
end;

function TFireDACVectorStore.AddChunk(const ASource: string; AChunkIndex: Integer;
  const AText: string; const AEmbedding: TArray<Single>): Int64;
var
  Q: TFDQuery;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'INSERT INTO chunks(source, chunk_index, text) VALUES(:s,:i,:t)';
    Q.ParamByName('s').AsString := ASource;
    Q.ParamByName('i').AsInteger := AChunkIndex;
    Q.ParamByName('t').AsString := AText;
    Q.ExecSQL;
    Result := StrToInt64Def(ScalarStr('SELECT last_insert_rowid()', ''), 0);

    Q.SQL.Text := 'INSERT INTO chunks_fts(rowid, text) VALUES(:r,:t)';
    Q.ParamByName('r').AsLargeInt := Result;
    Q.ParamByName('t').AsString := AText;
    Q.ExecSQL;

    Q.SQL.Text := 'INSERT INTO chunks_vec(rowid, embedding) VALUES(:r,:e)';
    Q.ParamByName('r').AsLargeInt := Result;
    BindBlobParam(Q.ParamByName('e'), VectorToBytes(AEmbedding));
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TFireDACVectorStore.RunVecQuery(const ABlob: TBytes; ALimit: Integer;
  AIds: TList<Int64>; ADist: TDictionary<Int64, Double>);
var
  Q: TFDQuery;
  Id: Int64;
begin
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := Format('SELECT rowid, distance FROM chunks_vec ' +
      'WHERE embedding MATCH :e ORDER BY distance LIMIT %d', [ALimit]);
    BindBlobParam(Q.ParamByName('e'), ABlob);
    Q.Open;
    while not Q.Eof do
    begin
      Id := Q.Fields[0].AsLargeInt;
      AIds.Add(Id);
      ADist.AddOrSetValue(Id, Q.Fields[1].AsFloat);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

procedure TFireDACVectorStore.RunFtsQuery(const AMatch: string; ALimit: Integer;
  AIds: TList<Int64>);
var
  Q: TFDQuery;
begin
  if Trim(AMatch) = '' then
    Exit;
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := Format('SELECT rowid FROM chunks_fts ' +
      'WHERE chunks_fts MATCH :m ORDER BY rank LIMIT %d', [ALimit]);
    Q.ParamByName('m').AsString := AMatch;
    Q.Open;
    while not Q.Eof do
    begin
      AIds.Add(Q.Fields[0].AsLargeInt);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TFireDACVectorStore.FetchHit(AId: Int64; AScore, ADist: Double): TSearchHit;
var
  Q: TFDQuery;
begin
  Result.Id := AId;
  Result.Score := AScore;
  Result.VecDistance := ADist;
  Result.Source := '';
  Result.ChunkIndex := 0;
  Result.Text := '';
  Q := TFDQuery.Create(nil);
  try
    Q.Connection := FConn;
    Q.SQL.Text := 'SELECT source, chunk_index, text FROM chunks WHERE id=:i';
    Q.ParamByName('i').AsLargeInt := AId;
    Q.Open;
    if not Q.Eof then
    begin
      Result.Source := Q.Fields[0].AsString;
      Result.ChunkIndex := Q.Fields[1].AsInteger;
      Result.Text := Q.Fields[2].AsString;
    end;
  finally
    Q.Free;
  end;
end;

function TFireDACVectorStore.Search(const AQueryText: string;
  const AQueryEmbedding: TArray<Single>; AMode: TSearchMode; AK: Integer): TSearchHits;
var
  Pool, I: Integer;
  VecIds, FtsIds: TList<Int64>;
  VecDist: TDictionary<Int64, Double>;
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
      RunVecQuery(VectorToBytes(AQueryEmbedding), Pool, VecIds, VecDist);
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
            if VecDist.TryGetValue(Fused[I].Id, D) then
              Hits.Add(FetchHit(Fused[I].Id, Fused[I].Score, D))
            else
              Hits.Add(FetchHit(Fused[I].Id, Fused[I].Score, -1));
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

procedure TFireDACVectorStore.CloseStore;
begin
  if Assigned(FConn) then
  begin
    FConn.Connected := False;
    FreeAndNil(FConn);
  end;
end;

{$ENDIF}

end.
