(*
  PasClaw.Tools.KB - registers the knowledgebase tools (kb_search, kb_get).

  The knowledgebase is the operator-curated document corpus managed by
  `pasclaw kb add/sync` (PasClaw.Cmd.KB / PasClaw.KB.Index) — reference
  documents, NOT conversation memory (that's memory_search).

  Registration is conditional: when no kb.db exists, or it has no
  registered sources, neither tool is registered — the model never
  sees a knowledgebase it can't use. When sources exist the tool
  description embeds the live corpus size so the model knows the KB
  is worth consulting.

  kb_search returns path#cN citations; kb_get expands a citation into
  the chunk text plus a window of neighbouring chunks, so the model can
  search cheap (snippets) and then pull exactly the context it needs.

  Unlike memory_search there is NO implicit sync on the query path:
  KB corpora can be thousands of chunks and (when the vector runtime
  is provisioned) re-embedding is expensive. `pasclaw kb sync` is the
  explicit refresh; the tool descriptions say so.
*)
unit PasClaw.Tools.KB;

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

procedure RegisterKBTools(R: TToolRegistry);

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.KB.Index;

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

function Tool_KBSearch(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultK = 5;
  MaxK     = 25;
var
  Query: string;
  K, i:  Integer;
  Idx:   IKBIndex;
  Hits:  TKBHitArray;
  Lines: TStringList;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'query', Query) then
  begin
    ErrMsg := 'missing required argument: query';
    Exit;
  end;
  K := ParseIntArg(ArgsJSON, 'k', DefaultK);
  if K < 1    then K := 1;
  if K > MaxK then K := MaxK;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    Idx := nil;
    ErrMsg := 'knowledgebase unavailable (' + SqliteBackendHint + ')';
    Exit;
  end;
  try
    Hits := Idx.Search(Query, K);
  finally
    Idx := nil;  { interface release closes the DB }
  end;

  if Length(Hits) = 0 then
    Exit(Format('(no knowledgebase matches for %s — if documents changed ' +
                'recently the operator may need to run `pasclaw kb sync`)',
                [Query]));

  Lines := TStringList.Create;
  try
    Lines.Add(Format('%d knowledgebase match(es) for %s:', [Length(Hits), Query]));
    Lines.Add('');
    for i := 0 to High(Hits) do
    begin
      Lines.Add(Format('%s#c%d  (score=%.3f)',
                       [Hits[i].Path, Hits[i].ChunkNo, Hits[i].Score]));
      Lines.Add('  ' + Hits[i].Snippet);
      if i < High(Hits) then Lines.Add('');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;

  LogDebug('kb_search query=%s k=%d hits=%d', [Query, K, Length(Hits)]);
end;

function Tool_KBGet(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultWindow = 1;
  MaxWindow     = 5;
var
  Path:    string;
  ChunkNo: Integer;
  Window:  Integer;
  Idx:     IKBIndex;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit;
  end;
  ChunkNo := ParseIntArg(ArgsJSON, 'chunk', -1);
  if ChunkNo < 0 then
  begin
    ErrMsg := 'missing required argument: chunk (the cN number from a kb_search hit)';
    Exit;
  end;
  Window := ParseIntArg(ArgsJSON, 'window', DefaultWindow);
  if Window < 0 then Window := 0;
  if Window > MaxWindow then Window := MaxWindow;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    Idx := nil;
    ErrMsg := 'knowledgebase unavailable (' + SqliteBackendHint + ')';
    Exit;
  end;
  try
    Result := Idx.GetChunks(Path, ChunkNo, Window);
  finally
    Idx := nil;
  end;

  if Result = '' then
    Result := Format('(no chunk %d for %s in the knowledgebase — use the ' +
                     'exact path and cN number from a kb_search result)',
                     [ChunkNo, Path]);
  LogDebug('kb_get path=%s chunk=%d window=%d', [Path, ChunkNo, Window]);
end;

procedure RegisterKBTools(R: TToolRegistry);
var
  T:     TTool;
  Idx:   IKBIndex;
  S:     TKBStats;
  Sized: string;
begin
  if R = nil then Exit;

  { No kb.db on disk → the operator never created a knowledgebase;
    don't register (and don't create the DB as a side effect of tool
    registration). }
  if not FileExists(DefaultKBDbPath) then Exit;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    Idx := nil;
    Exit;
  end;
  try
    S := Idx.Stats;
  finally
    Idx := nil;
  end;
  if S.Sources = 0 then Exit;

  Sized := Format('%d document(s) in %d chunk(s) from %d source(s)',
                  [S.Files, S.Chunks, S.Sources]);

  T.Name        := 'kb_search';
  T.Description :=
    'Search the operator''s knowledgebase — a curated set of reference ' +
    'documents (manuals, books, source code) indexed for retrieval; ' +
    'currently ' + Sized + '. Use it whenever the question may be ' +
    'answered by those documents. Returns up to k hits as path#cN + ' +
    'snippet + score; pass interesting hits to kb_get for full context. ' +
    'The index refreshes only via `pasclaw kb sync`.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"Search query — plain natural language is fine."},' +
    '"k":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 5)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_KBSearch;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);

  T.Name        := 'kb_get';
  T.Description :=
    'Fetch full chunk text from the knowledgebase around a kb_search hit. ' +
    'Give the exact path and cN chunk number from a hit; window controls ' +
    'how many neighbouring chunks are included on each side (default 1).';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"path":{"type":"string","description":"Document path exactly as returned by kb_search."},' +
    '"chunk":{"type":"integer","minimum":0,"description":"Chunk number (the N in #cN)."},' +
    '"window":{"type":"integer","minimum":0,"maximum":5,"description":"Neighbour chunks each side (default 1)."}' +
    '},"required":["path","chunk"]}';
  T.Handler     := Tool_KBGet;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);
end;

end.
