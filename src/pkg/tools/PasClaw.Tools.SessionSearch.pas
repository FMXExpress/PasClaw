(*
  PasClaw.Tools.SessionSearch - registers the session_search tool.

  Lets the model search the text of EVERY saved session, not just
  the current conversation. Backed by PasClaw.Session.Search's FTS5
  index over $PASCLAW_HOME/workspace/sessions/*.json. Returns
  session id + title + snippet + bm25 score; the model can then
  suggest the operator resume that session (`pasclaw resume <id>`)
  or surface the recalled fact directly.

  Index DB lives at workspace/sessions/.search.db -- a derived
  cache, rebuilt lazily from the JSON files on each call (Sync
  compares UpdatedAt against the last-indexed mtime, so only
  changed sessions get re-read).

  Degrades the same way memory_search does: if libsqlite3 can't
  load, Open() returns False and the tool reports the index is
  unavailable rather than crashing.
*)
unit PasClaw.Tools.SessionSearch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  PasClaw.Tools.Registry;

procedure RegisterSessionSearchTool(R: TToolRegistry);

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Tools.Types,
  PasClaw.Session.Search;

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

function SessionsDir_: string;
begin
  Result := JoinPath(GetHome, 'workspace/sessions');
end;

function IndexDbPath: string;
begin
  Result := JoinPath(SessionsDir_, '.search.db');
end;

function Tool_SessionSearch(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultK = 5;
  MaxK     = 25;
var
  Query: string;
  K, i:  Integer;
  Idx:   ISessionSearchIndex;
  Hits:  TSessionHitArray;
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

  if not DirectoryExists(SessionsDir_) then
    Exit('(no sessions saved yet -- nothing to search)');

  Idx := NewSessionSearchIndex;
  if not Idx.Open(IndexDbPath) then
  begin
    Idx := nil;
    ErrMsg := 'session index unavailable (libsqlite3 missing or unreadable)';
    Exit;
  end;

  try
    Idx.Sync;
    Hits := Idx.Search(Query, K);
  finally
    Idx := nil;  { IInterface release closes the DB }
  end;

  if Length(Hits) = 0 then
    Exit(Format('(no past sessions match %s)', [Query]));

  Lines := TStringList.Create;
  try
    Lines.Add(Format('%d past session(s) match %s:', [Length(Hits), Query]));
    Lines.Add('');
    for i := 0 to High(Hits) do
    begin
      Lines.Add(Format('%s  "%s"  (bm25=%.3f)',
                       [Hits[i].Id, Hits[i].Title, Hits[i].Score]));
      Lines.Add('  ' + Hits[i].Snippet);
      Lines.Add('  resume with: pasclaw resume ' + Hits[i].Id);
      if i < High(Hits) then Lines.Add('');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;

  LogDebug('session_search query=%s k=%d hits=%d', [Query, K, Length(Hits)]);
end;

procedure RegisterSessionSearchTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'session_search';
  T.Description :=
    'Search the full text of your PAST conversations (saved sessions), not ' +
    'just the current one. Use this when the user refers to something from ' +
    'an earlier chat ("like we set up last week", "the command that worked ' +
    'before", "my deploy preferences") that isn''t in the current context. ' +
    'Returns up to k matches as session-id + title + snippet + score ' +
    '(smaller score = stronger match), each with the `pasclaw resume` ' +
    'command to reopen that session.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"What to look for across past sessions. ' +
                'Plain words; FTS5 BM25 ranked."},' +
    '"k":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 5)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_SessionSearch;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;  { SQLite SELECT only }
  R.Register(T);
end;

end.
