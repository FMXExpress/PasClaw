(*
  PasClaw.Session.Search - SQLite + FTS5 keyword index over saved
  session transcripts.

  The gap hermes-agent's `session_search` fills: today the model can
  only see the CURRENT conversation. Anything from a prior session
  (a decision made last week, a command that worked, the user's
  stated preference three chats ago) is invisible unless the
  operator manually resumes that session. This unit indexes the
  text of every saved session so the model can search across all
  of them -- "have we set up the deploy script before?" finds the
  session where it happened.

  Source of truth stays the session JSON files under
  $PASCLAW_HOME/workspace/sessions/. This DB is a derived,
  lazily-rebuilt cache, same contract as PasClaw.Memory.Index.

  What gets indexed: per session, the concatenated text of every
  user / assistant / tool message (Content fields), prefixed with
  the session title. Tool-call argument JSON and metadata are NOT
  indexed -- they're noise for a "what did we talk about" search
  and would dilute BM25 ranking. The session id + title come back
  with each hit so the model (or operator) can resume the right
  one.

  Reuses PasClaw.Memory.Index.SanitizeFtsQuery for query
  normalisation so session_search and memory_search treat the same
  query string identically.

  Cross-target split mirrors PasClaw.Memory.Index exactly:
    - {$IFDEF FPC}: TSQLite3Connection + TSQLQuery (sqldb).
    - {$ELSE}: FireDAC TFDConnection + TFDQuery.

  Schema:
    session_files(rowid PK, id TEXT UNIQUE, mtime INTEGER, indexed_at INTEGER)
    session_fts USING fts5(id UNINDEXED, title UNINDEXED, content,
                           tokenize='porter unicode61')
*)
unit PasClaw.Session.Search;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TSessionHit = record
    Id:      string;    { session id, so the operator can resume it }
    Title:   string;    { human-readable session title }
    Snippet: string;    { FTS5 snippet around the match }
    Score:   Double;    { bm25; smaller = better }
  end;
  TSessionHitArray = array of TSessionHit;

  ISessionSearchIndex = interface
    ['{B2E7C1A4-5F3D-4E62-9A1C-8D4F2B6E3A57}']
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    procedure Sync;     { walk the sessions dir, reindex changed transcripts }
    function  Search(const Query: string; K: Integer): TSessionHitArray;
  end;

function NewSessionSearchIndex: ISessionSearchIndex;

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
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Memory.Index;   { for SanitizeFtsQuery }

type
  TSessionSearchImpl = class(TInterfacedObject, ISessionSearchIndex)
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
    function  IndexedMtime(const Id: string; out Mtime: Int64): Boolean;
    procedure ReindexSession(const Meta: TSessionMeta);
    procedure DropMissing(const KnownIds: TStringList);
  public
    destructor Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    procedure Sync;
    function  Search(const Query: string; K: Integer): TSessionHitArray;
  end;

function NewSessionSearchIndex: ISessionSearchIndex;
begin
  Result := TSessionSearchImpl.Create;
end;

destructor TSessionSearchImpl.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TSessionSearchImpl.ExecSQL(const SQL: string);
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

procedure TSessionSearchImpl.EnsureSchema;
begin
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS session_files (' +
    '  rowid INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  id TEXT UNIQUE NOT NULL,' +
    '  mtime INTEGER NOT NULL,' +
    '  indexed_at INTEGER NOT NULL)');
  ExecSQL(
    'CREATE VIRTUAL TABLE IF NOT EXISTS session_fts USING fts5(' +
    '  id UNINDEXED, title UNINDEXED, content,' +
    '  tokenize=''porter unicode61'')');
end;

function TSessionSearchImpl.Open(const DbPath: string): Boolean;
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
    LogDebug('session.search: opened %s', [DbPath]);
  except
    on E: Exception do
    begin
      LogWarn('session.search: failed to open %s (%s) -- session_search disabled',
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

procedure TSessionSearchImpl.Close;
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
      LogWarn('session.search: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TSessionSearchImpl.IndexedMtime(const Id: string; out Mtime: Int64): Boolean;
{$IFDEF FPC}
var
  Q: TSQLQuery;
begin
  Result := False;
  Mtime  := 0;
  Q := TSQLQuery.Create(nil);
  try
    Q.Database := FConn;
    Q.SQL.Text := 'SELECT mtime FROM session_files WHERE id = :p';
    Q.Params.ParamByName('p').AsString := Id;
    Q.Open;
    if not Q.EOF then begin Mtime := Q.Fields[0].AsLargeInt; Result := True; end;
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
    Q.SQL.Text := 'SELECT mtime FROM session_files WHERE id = :p';
    Q.ParamByName('p').AsString := Id;
    Q.Open;
    if not Q.Eof then begin Mtime := Q.Fields[0].AsLargeInt; Result := True; end;
    Q.Close;
  finally
    Q.Free;
  end;
end;
{$ENDIF}

function ExtractSessionText(const Sess: TSession): string;
{ Concatenate the human-meaningful text of a session into one
  blob for FTS indexing: title + every message's Content. Tool-call
  JSON args and message metadata are skipped -- they're search
  noise. Newline-separated so the FTS5 snippet function has clean
  boundaries to window around. }
var
  Sl: TStringList;
  i: Integer;
begin
  Sl := TStringList.Create;
  try
    if Sess.Meta.Title <> '' then Sl.Add(Sess.Meta.Title);
    for i := 0 to High(Sess.Messages) do
      if Trim(Sess.Messages[i].Content) <> '' then
        Sl.Add(Sess.Messages[i].Content);
    Result := Sl.Text;
  finally
    Sl.Free;
  end;
end;

procedure TSessionSearchImpl.ReindexSession(const Meta: TSessionMeta);
var
  Sess: TSession;
  Content: string;
  Now_: Int64;
{$IFDEF FPC}
  Q: TSQLQuery;
{$ELSE}
  Q: TFDQuery;
{$ENDIF}
begin
  Sess := TSession.Create(Meta.Id);
  try
    if not Sess.MetaExists then Exit;
    Content := ExtractSessionText(Sess);
    Now_ := DateTimeToUnix(Now, False);

    {$IFDEF FPC}
    Q := TSQLQuery.Create(nil);
    try
      Q.Database := FConn;
      Q.SQL.Text :=
        'DELETE FROM session_fts WHERE rowid IN (SELECT rowid FROM session_files WHERE id = :p)';
      Q.Params.ParamByName('p').AsString := Meta.Id;
      Q.ExecSQL;

      Q.SQL.Text := 'DELETE FROM session_files WHERE id = :p';
      Q.Params.ParamByName('p').AsString := Meta.Id;
      Q.ExecSQL;

      Q.SQL.Text :=
        'INSERT INTO session_files (id, mtime, indexed_at) VALUES (:p, :m, :i)';
      Q.Params.ParamByName('p').AsString   := Meta.Id;
      Q.Params.ParamByName('m').AsLargeInt := Meta.UpdatedAt;
      Q.Params.ParamByName('i').AsLargeInt := Now_;
      Q.ExecSQL;

      Q.SQL.Text :=
        'INSERT INTO session_fts (rowid, id, title, content) ' +
        'VALUES ((SELECT rowid FROM session_files WHERE id = :p), :p, :t, :c)';
      Q.Params.ParamByName('p').AsString := Meta.Id;
      Q.Params.ParamByName('t').AsString := Meta.Title;
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
        'DELETE FROM session_fts WHERE rowid IN (SELECT rowid FROM session_files WHERE id = :p)';
      Q.ParamByName('p').AsString := Meta.Id;
      Q.ExecSQL;

      Q.SQL.Text := 'DELETE FROM session_files WHERE id = :p';
      Q.ParamByName('p').AsString := Meta.Id;
      Q.ExecSQL;

      Q.SQL.Text :=
        'INSERT INTO session_files (id, mtime, indexed_at) VALUES (:p, :m, :i)';
      Q.ParamByName('p').AsString   := Meta.Id;
      Q.ParamByName('m').AsLargeInt := Meta.UpdatedAt;
      Q.ParamByName('i').AsLargeInt := Now_;
      Q.ExecSQL;

      Q.SQL.Text :=
        'INSERT INTO session_fts (rowid, id, title, content) ' +
        'VALUES ((SELECT rowid FROM session_files WHERE id = :p), :p, :t, :c)';
      Q.ParamByName('p').AsString := Meta.Id;
      Q.ParamByName('t').AsString := Meta.Title;
      Q.ParamByName('c').AsString := Content;
      Q.ExecSQL;
    finally
      Q.Free;
    end;
    {$ENDIF}
  finally
    Sess.Free;
  end;
end;

procedure TSessionSearchImpl.DropMissing(const KnownIds: TStringList);
{$IFDEF FPC}
var
  Q: TSQLQuery;
  Stale: TStringList;
  Id: string;
begin
  Stale := TStringList.Create;
  try
    Q := TSQLQuery.Create(nil);
    try
      Q.Database := FConn;
      Q.SQL.Text := 'SELECT id FROM session_files';
      Q.Open;
      while not Q.EOF do
      begin
        Id := Q.Fields[0].AsString;
        if KnownIds.IndexOf(Id) < 0 then Stale.Add(Id);
        Q.Next;
      end;
      Q.Close;
      for Id in Stale do
      begin
        Q.SQL.Text :=
          'DELETE FROM session_fts WHERE rowid IN (SELECT rowid FROM session_files WHERE id = :p)';
        Q.Params.ParamByName('p').AsString := Id;
        Q.ExecSQL;
        Q.SQL.Text := 'DELETE FROM session_files WHERE id = :p';
        Q.Params.ParamByName('p').AsString := Id;
        Q.ExecSQL;
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
  Q: TFDQuery;
  Stale: TStringList;
  Id: string;
begin
  Stale := TStringList.Create;
  try
    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConn;
      Q.SQL.Text := 'SELECT id FROM session_files';
      Q.Open;
      while not Q.Eof do
      begin
        Id := Q.Fields[0].AsString;
        if KnownIds.IndexOf(Id) < 0 then Stale.Add(Id);
        Q.Next;
      end;
      Q.Close;
      for Id in Stale do
      begin
        Q.SQL.Text :=
          'DELETE FROM session_fts WHERE rowid IN (SELECT rowid FROM session_files WHERE id = :p)';
        Q.ParamByName('p').AsString := Id;
        Q.ExecSQL;
        Q.SQL.Text := 'DELETE FROM session_files WHERE id = :p';
        Q.ParamByName('p').AsString := Id;
        Q.ExecSQL;
      end;
    finally
      Q.Free;
    end;
  finally
    Stale.Free;
  end;
end;
{$ENDIF}

procedure TSessionSearchImpl.Sync;
var
  Sessions: TSessionMetaArray;
  Known: TStringList;
  i: Integer;
  Idx: Int64;
  Found: Boolean;
begin
  if not FOpen then Exit;
  { Default ListSessions hides gateway stat buckets -- good, those
    are empty pseudo-sessions with nothing worth searching. }
  Sessions := ListSessions;
  Known := TStringList.Create;
  try
    for i := 0 to High(Sessions) do
    begin
      Known.Add(Sessions[i].Id);
      Found := IndexedMtime(Sessions[i].Id, Idx);
      { Reindex when new or when the transcript moved (UpdatedAt
        advanced past what we last indexed). }
      if (not Found) or (Idx < Sessions[i].UpdatedAt) then
        ReindexSession(Sessions[i]);
    end;
    DropMissing(Known);
  finally
    Known.Free;
  end;
end;

function TSessionSearchImpl.Search(const Query: string; K: Integer): TSessionHitArray;
{$IFDEF FPC}
var
  Q: TSQLQuery;
  N: Integer;
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
      'SELECT id, title, snippet(session_fts, 2, ''['', '']'', ''...'', 12) AS snip, ' +
      '       bm25(session_fts) AS score ' +
      'FROM session_fts WHERE session_fts MATCH :q ' +
      'ORDER BY score LIMIT :k';
    Q.Params.ParamByName('q').AsString  := Sanitized;
    Q.Params.ParamByName('k').AsInteger := K;
    Q.Open;
    N := 0;
    while (not Q.EOF) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Id      := Q.FieldByName('id').AsString;
      Result[N].Title   := Q.FieldByName('title').AsString;
      Result[N].Snippet := Q.FieldByName('snip').AsString;
      Result[N].Score   := Q.FieldByName('score').AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  except
    on E: Exception do
      LogWarn('session.search: query failed (%s)', [E.Message]);
  end;
  Q.Free;
end;
{$ELSE}
var
  Q: TFDQuery;
  N: Integer;
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
      'SELECT id, title, snippet(session_fts, 2, ''['', '']'', ''...'', 12) AS snip, ' +
      '       bm25(session_fts) AS score ' +
      'FROM session_fts WHERE session_fts MATCH :q ' +
      'ORDER BY score LIMIT :k';
    Q.ParamByName('q').AsString  := Sanitized;
    Q.ParamByName('k').AsInteger := K;
    Q.Open;
    N := 0;
    while (not Q.Eof) and (N < K) do
    begin
      SetLength(Result, N + 1);
      Result[N].Id      := Q.FieldByName('id').AsString;
      Result[N].Title   := Q.FieldByName('title').AsString;
      Result[N].Snippet := Q.FieldByName('snip').AsString;
      Result[N].Score   := Q.FieldByName('score').AsFloat;
      Inc(N);
      Q.Next;
    end;
    Q.Close;
  except
    on E: Exception do
      LogWarn('session.search: query failed (%s)', [E.Message]);
  end;
  Q.Free;
end;
{$ENDIF}

end.
