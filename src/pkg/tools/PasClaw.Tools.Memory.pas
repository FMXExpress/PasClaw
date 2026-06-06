(*
  PasClaw.Tools.Memory - registers the memory_search tool.

  Workflow (openclaw-style):
    - The model writes durable notes by editing MEMORY.md or a daily
      file workspace/memory/YYYY-MM-DD.md with the existing fs_write
      tool. There is intentionally NO memory_add tool — files are the
      source of truth, the index follows.
    - memory_search opens the lazy FTS5 index over workspace/memory/,
      syncs it against the current files (rebuilding rows for any file
      whose mtime moved), and runs an FTS5 MATCH against the user's
      query. Returns up to K hits as
        path | bm25 score | highlighted snippet
      one per line, smallest score first.

  The DB lives at <home>/workspace/memory/.index.db. Missing / corrupt
  / unloadable libsqlite3 degrades to "memory_search: index
  unavailable" — the rest of the agent continues to function.
*)
unit PasClaw.Tools.Memory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterMemoryTools(R: TToolRegistry);

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Memory.Index,
  PasClaw.Memory.Vector;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseIntArg(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function MemoryDir: string;
begin
  Result := JoinPath(GetHome, 'workspace/memory');
end;

function IndexDbPath: string;
begin
  Result := JoinPath(MemoryDir, '.index.db');
end;

function Tool_MemorySearch(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultK = 5;
  MaxK     = 25;
var
  Query: string;
  K, i:  Integer;
  Idx:   IMemoryIndex;
  Hits:  TMemoryHitArray;
  Lines: TStringList;
  Dir:   string;
  Cfg:   TConfig;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'query', Query) then
  begin
    ErrMsg := 'missing required argument: query';
    Exit;
  end;
  K := ParseIntArg(ArgsJSON, 'k', DefaultK);
  if K < 1   then K := 1;
  if K > MaxK then K := MaxK;

  Dir := MemoryDir;
  if not DirectoryExists(Dir) then
    Exit('(no memory directory yet — write to ' + JoinPath(Dir, 'MEMORY.md') +
         ' first)');

  { Backend selection — try the hybrid FTS+vector backend first when
    the operator opted in via `pasclaw onboard` / `vector_search_enabled`
    (default True). On any "not provisioned yet" failure (missing
    sqlite-vec, missing ONNX Runtime, missing embedding model) Open()
    returns False quietly and we fall through to NewMemoryIndex, which
    is the FTS5-only path PasClaw has shipped since memory_search
    landed. Operators on stock builds without the runtime artifacts
    on disk get the same behaviour they did before: keyword search.

    Separate DB filenames (.index.db vs .index.db.vec) so flipping
    vector_search_enabled on/off doesn't cross-talk between the two
    schemas in one file. Both backends live alongside each other on
    disk; only one is opened per call. The vector DB file is created
    on first SyncDir after provisioning lands; until then it doesn't
    exist and isn't touched. }
  Cfg := LoadConfig;
  try
    if Cfg.VectorSearchEnabled then
    begin
      Idx := NewVectorMemoryIndex;
      if not Idx.Open(IndexDbPath + '.vec') then
        Idx := nil;  { releases the interface; falls through to FTS }
    end;
  finally
    Cfg.Free;
  end;

  if Idx = nil then
  begin
    Idx := NewMemoryIndex;
    if not Idx.Open(IndexDbPath) then
    begin
      Idx := nil;
      ErrMsg := 'memory index unavailable (libsqlite3 missing or unreadable)';
      Exit;
    end;
  end;

  try
    Idx.SyncDir(Dir);
    Hits := Idx.Search(Query, K);
  finally
    Idx := nil;  { IInterface release closes the DB }
  end;

  if Length(Hits) = 0 then
    Exit(Format('(no matches for %s in %s)', [Query, Dir]));

  Lines := TStringList.Create;
  try
    Lines.Add(Format('%d match(es) for %s:', [Length(Hits), Query]));
    Lines.Add('');
    for i := 0 to High(Hits) do
    begin
      Lines.Add(Format('%s  (bm25=%.3f)', [Hits[i].Path, Hits[i].Score]));
      Lines.Add('  ' + Hits[i].Snippet);
      if i < High(Hits) then Lines.Add('');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;

  LogDebug('memory_search query=%s k=%d hits=%d', [Query, K, Length(Hits)]);
end;

procedure RegisterMemoryTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'memory_search';
  T.Description :=
    'Search the workspace memory directory (MEMORY.md + workspace/memory/*.md) ' +
    'with SQLite FTS5 BM25 ranking. Use this before answering questions about ' +
    'prior conversations, the user''s preferences, or project facts you might ' +
    'have written down on an earlier turn. Returns up to k matches as path + ' +
    'snippet + score (smaller score = stronger match).';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"FTS5 query string. Supports plain words, AND/OR/NOT, ' +
                '\"phrase\" quoting, and prefix^ matching."},' +
    '"k":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 5)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_MemorySearch;
  T.IsCore      := True;
  T.Category    := tcReadOnly;  { SQLite SELECT only }
  R.Register(T);
end;

end.
