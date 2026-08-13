(*
  PasClaw.Tools.SessionSearch - registers the session_search and
  session_read tools.

  session_search lets the model search the text of EVERY saved session,
  not just the current conversation. Backed by PasClaw.Session.Search's
  FTS5 index over $PASCLAW_HOME/workspace/sessions/*.json. Returns
  session id + title + snippet + bm25 score; the model can then
  suggest the operator resume that session (`pasclaw resume <id>`)
  or surface the recalled fact directly.

  session_read is the second half of the loop: given a session id from
  session_search, pull that conversation's messages into the current
  context (optionally filtered by a substring, windowed by start/count,
  each message capped). Together they make past sessions usable as
  extra context windows: search -> read, the same grep -> read pattern
  the model already knows from files.

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
  PasClaw.Workspaces,
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Tools.Types,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
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
  Result := JoinPath(GetHome, ActiveWorkspaceName + '/sessions');
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

{ Truncate S to at most MaxBytes WITHOUT splitting a UTF-8 sequence: back the
  cut off while the first excluded byte is a continuation byte (10xxxxxx), so
  the result stays valid UTF-8 (a mid-character cut would corrupt the tool
  output and can be rejected downstream in provider-request JSON). }
function Utf8SafeTruncate(const S: string; MaxBytes: Integer): string;
var
  n: Integer;
begin
  if Length(S) <= MaxBytes then Exit(S);
  n := MaxBytes;
  while (n > 0) and ((Byte(S[n + 1]) and $C0) = $80) do Dec(n);
  Result := Copy(S, 1, n);
end;

function Tool_SessionRead(const ArgsJSON: string; out ErrMsg: string): string;
const
  DefaultCount = 20;
  MaxCount     = 100;
  DefaultChars = 1500;
  MaxChars     = 8000;
var
  Id, Query, QueryLC, Body, RoleStr: string;
  Start, Count, CapChars, i, j, Shown, Matched, ConvIdx: Integer;
  S: TSession;
  Lines: TStringList;
  Idx:  array of Integer;  { message indexes surviving the role/query filter }
  Ords: array of Integer;  { each survivor's ORIGINAL conversation ordinal }
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'session_id', Id) then
  begin
    ErrMsg := 'missing required argument: session_id (find ids with session_search)';
    Exit;
  end;
  if not IsSafeSessionId(Id) then
  begin
    ErrMsg := 'invalid session id: ' + Id;
    Exit;
  end;
  ParseStringArg(ArgsJSON, 'query', Query);   { optional }
  QueryLC := LowerCase(Query);
  Start := ParseIntArg(ArgsJSON, 'start', 1);
  if Start < 1 then Start := 1;
  Count := ParseIntArg(ArgsJSON, 'count', DefaultCount);
  if Count < 1        then Count := 1;
  if Count > MaxCount then Count := MaxCount;
  CapChars := ParseIntArg(ArgsJSON, 'max_chars', DefaultChars);
  if CapChars < 100      then CapChars := 100;
  if CapChars > MaxChars then CapChars := MaxChars;

  S := TSession.Create(Id);
  try
    if not S.MetaExists then
    begin
      ErrMsg := 'no such session: ' + Id + ' -- find ids with session_search';
      Exit;
    end;

    { Filter pass: skip system turns (compacted prompt blobs, not
      conversation), apply the optional substring query over content. Each
      survivor keeps its ORIGINAL conversation ordinal (position among all
      non-system turns) in Ords, so the displayed [N] numbering is stable
      across calls regardless of query filters. }
    SetLength(Idx, 0);
    SetLength(Ords, 0);
    ConvIdx := 0;
    for i := 0 to High(S.Messages) do
    begin
      if S.Messages[i].Role = mrSystem then Continue;
      Inc(ConvIdx);
      if (QueryLC <> '') and
         (Pos(QueryLC, LowerCase(S.Messages[i].Content)) = 0) then Continue;
      SetLength(Idx, Length(Idx) + 1);
      Idx[High(Idx)] := i;
      SetLength(Ords, Length(Ords) + 1);
      Ords[High(Ords)] := ConvIdx;
    end;
    Matched := Length(Idx);
    if Matched = 0 then
    begin
      if Query <> '' then
        Exit(Format('(session %s has no messages containing "%s")', [Id, Query]))
      else
        Exit(Format('(session %s has no conversation messages)', [Id]));
    end;

    Lines := TStringList.Create;
    try
      if Query <> '' then
        RoleStr := ' matching "' + Query + '"'   { reuse the local as a suffix }
      else
        RoleStr := '';
      Lines.Add(Format('session %s  "%s"  (%s, %d message(s)%s)',
        [S.Meta.Id, S.Meta.Title, S.Meta.Model, Matched, RoleStr]));
      Lines.Add('');
      Shown := 0;
      for j := Start - 1 to Matched - 1 do
      begin
        if Shown >= Count then Break;
        i := Idx[j];
        RoleStr := MsgRoleToString(S.Messages[i].Role);
        Body := S.Messages[i].Content;
        { An assistant tool-call turn often has empty content -- surface the
          call itself so the transcript stays readable. }
        if (Body = '') and (Length(S.Messages[i].ToolCalls) > 0) then
          Body := '(tool call: ' + S.Messages[i].ToolCalls[0].Func.Name + ')';
        if Length(Body) > CapChars then
          Body := Utf8SafeTruncate(Body, CapChars) + '...[truncated]';
        Lines.Add(Format('[%d] %s: %s', [Ords[j], RoleStr, Body]));
        Inc(Shown);
      end;
      if Start - 1 + Shown < Matched then
        Lines.Add(Format('(showing %d-%d of %d -- call again with start=%d for more)',
          [Start, Start - 1 + Shown, Matched, Start + Shown]));
      Result := Lines.Text;
    finally
      Lines.Free;
    end;
  finally
    S.Free;
  end;

  LogDebug('session_read id=%s start=%d count=%d matched=%d',
           [Id, Start, Count, Matched]);
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
    'command to reopen that session. To actually READ a matched ' +
    'conversation, follow up with session_read on its session-id.';
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

  T.Name        := 'session_read';
  T.Description :=
    'Read the messages of a PAST saved session by id -- your other context ' +
    'windows. Use after session_search points at a conversation ("check the ' +
    'session where we set up the deploy"): pass its session_id to pull the ' +
    'actual exchange into this context. Optional "query" filters to messages ' +
    'containing a substring; "start"/"count" page through long sessions ' +
    '(message numbering is stable across calls). System turns are skipped; ' +
    'long messages are truncated to max_chars.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"session_id":{"type":"string","description":"Session id from session_search (e.g. 20260601T134215-a3f4c2e1)."},' +
    '"query":{"type":"string","description":"Only return messages containing this substring (case-insensitive)."},' +
    '"start":{"type":"integer","minimum":1,"description":"1-based first message to return (default 1)."},' +
    '"count":{"type":"integer","minimum":1,"maximum":100,"description":"Max messages to return (default 20)."},' +
    '"max_chars":{"type":"integer","minimum":100,"maximum":8000,"description":"Per-message content cap (default 1500)."}' +
    '},"required":["session_id"]}';
  T.Handler     := Tool_SessionRead;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;  { reads one JSON file }
  R.Register(T);
end;

end.
