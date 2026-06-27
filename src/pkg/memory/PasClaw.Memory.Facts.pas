(*
  PasClaw.Memory.Facts - Phase 2 persistence for distilled memory.

  Stores the TFact records produced by PasClaw.Memory.Distill in a
  SQLite table (workspace/memory/facts.db). This is the relational
  store + lifecycle bookkeeping; the similarity/dedup side (sqlite-vec
  embeddings, contradiction resolution) is Phase 3 and slots in on top
  of this schema.

  Why SQLite rather than flat .md files: the fact store's core ops are
  metadata queries and in-place updates -- "active facts as of today"
  (WHERE not superseded AND not expired), supersede a contradicted
  fact, expire-sweep -- which SQL does cleanly and a markdown blob does
  not. Auditability (the thing pure-vector stores lose) comes back via
  a future Memory web tab + a markdown export, not by making files the
  source of truth.

  Cross-target split mirrors PasClaw.Memory.Index:
    - {$IFDEF FPC}: TSQLite3Connection + TSQLQuery (sqldb).
    - {$ELSE}:      FireDAC TFDConnection + TFDQuery.

  Schema:
    facts(id INTEGER PK, text, kind, scope, confidence REAL,
          expires TEXT, source_session TEXT, created_at INTEGER,
          superseded INTEGER)

    expires is '' (never) or 'YYYY-MM-DD'. A fact is ACTIVE when
    superseded = 0 and (expires = '' or expires >= today). "today" is
    passed in by the caller so reads stay deterministic/testable.
*)
unit PasClaw.Memory.Facts;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Memory.Distill;   { TFact }

type
  TStoredFact = record
    Id:            Int64;
    Text:          string;
    Kind:          string;
    Scope:         string;
    Confidence:    Double;
    Expires:       string;
    SourceSession: string;
    CreatedAt:     Int64;     { unix seconds }
    Superseded:    Boolean;
  end;
  TStoredFactArray = array of TStoredFact;

  IFactStore = interface
    ['{4C2F9A11-7E3D-4B8A-9F21-2A6D0C5E1B77}']
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    { Insert F; returns the new row id (0 on failure). CreatedAt is set
      to now; Superseded starts false. }
    function  Add(const F: TFact; CreatedAt: Int64): Int64;
    { Facts that are live as of Today ('YYYY-MM-DD'): not superseded and
      not past their expiry. Newest first. }
    function  ActiveFacts(const Today: string): TStoredFactArray;
    { Every fact, including superseded/expired (newest first). }
    function  AllFacts: TStoredFactArray;
    { Mark a fact superseded (kept for history). True if a row changed. }
    function  Supersede(Id: Int64): Boolean;
    { Hard-delete a fact. True if a row was removed. }
    function  Delete(Id: Int64): Boolean;
    { Total rows, including superseded/expired. }
    function  CountAll: Integer;
    { Count of facts ACTIVE as of Today -- identical predicate to
      ActiveFacts(Today), so the two never disagree. }
    function  CountActive(const Today: string): Integer;
  end;

function NewFactStore: IFactStore;

{ Default on-disk location: <home>/workspace/memory/facts.db }
function DefaultFactsDbPath(const HomeDir: string): string;

{ Render facts as a system-prompt block, newest first, until Budget bytes
  are used; a trailing "(+N older fact(s) not shown)" breadcrumb notes any
  omitted. The breadcrumb does NOT point at memory_search -- that tool only
  indexes workspace/memory/*.md, not facts.db, so omitted facts aren't
  reachable that way until facts are wired into retrieval (Phase 4b).
  Wholesale (NOT relevance-sliced). '' when Facts is empty or Budget <= 0.
  Pure -- exposed for testing. }
function FormatFactsBlock(const Facts: TStoredFactArray; Budget: Integer): string;

{ Convenience for the prompt builder: open the default store, read the
  facts active as of Today, and format them within Budget. '' when the
  store is absent/empty or Budget <= 0. }
function ActiveFactsBlock(const HomeDir, Today: string; Budget: Integer): string;

implementation

uses
  {$IFDEF FPC}
  sqldb, sqlite3conn,
  {$ELSE}
  FireDAC.Comp.Client, FireDAC.Phys.SQLite, FireDAC.Stan.Def,
  FireDAC.Stan.Async, FireDAC.Stan.Param, FireDAC.DApt,
  {$ENDIF}
  DateUtils,
  PasClaw.Utils,
  PasClaw.Logger;

function DefaultFactsDbPath(const HomeDir: string): string;
begin
  Result := JoinPath(JoinPath(JoinPath(HomeDir, 'workspace'), 'memory'), 'facts.db');
end;

function FormatFactsBlock(const Facts: TStoredFactArray; Budget: Integer): string;
const
  Header = 'Durable facts (auto-distilled memory):';
var
  i, Used, Omitted: Integer;
  Line, Body: string;
begin
  Result := '';
  if (Length(Facts) = 0) or (Budget <= 0) then Exit;
  Body := '';
  Used := Length(Header);
  Omitted := 0;
  for i := 0 to High(Facts) do
  begin
    if Trim(Facts[i].Text) = '' then Continue;
    Line := '- ' + Facts[i].Text;
    if Facts[i].Expires <> '' then
      Line := Line + ' (until ' + Facts[i].Expires + ')';
    { +1 for the newline this line will cost. Always keep at least one. }
    if (Body <> '') and (Used + Length(Line) + 1 > Budget) then
    begin
      Omitted := Length(Facts) - i;
      Break;
    end;
    if Body <> '' then Body := Body + sLineBreak;
    Body := Body + Line;
    Used := Used + Length(Line) + 1;
  end;
  if Body = '' then Exit;
  Result := Header + sLineBreak + Body;
  if Omitted > 0 then
    { No memory_search hint: it indexes only workspace/memory/*.md, not
      facts.db, so it can't recover these. Just flag the omission;
      raising memory_facts_budget surfaces more. }
    Result := Result + sLineBreak +
      Format('(+%d older fact(s) not shown)', [Omitted]);
end;

function ActiveFactsBlock(const HomeDir, Today: string; Budget: Integer): string;
var
  Store: IFactStore;
begin
  Result := '';
  if Budget <= 0 then Exit;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(HomeDir)) then Exit;
  try
    Result := FormatFactsBlock(Store.ActiveFacts(Today), Budget);
  finally
    Store.Close;
  end;
end;

type
{$IFDEF FPC}
  TQuery = TSQLQuery;
{$ELSE}
  TQuery = TFDQuery;
{$ENDIF}

  TFactStoreImpl = class(TInterfacedObject, IFactStore)
  private
    {$IFDEF FPC}
    FConn: TSQLite3Connection;
    FTx:   TSQLTransaction;
    {$ELSE}
    FConn: TFDConnection;
    {$ENDIF}
    FOpen: Boolean;
    function  NewQuery: TQuery;
    procedure PStr(Q: TQuery; const N, V: string);
    procedure PInt(Q: TQuery; const N: string; V: Int64);
    procedure PFloat(Q: TQuery; const N: string; V: Double);
    procedure Commit;
    procedure ExecSQL(const SQL: string);
    procedure EnsureSchema;
    function  ReadRows(Q: TQuery): TStoredFactArray;
  public
    destructor Destroy; override;
    function  Open(const DbPath: string): Boolean;
    procedure Close;
    function  Add(const F: TFact; CreatedAt: Int64): Int64;
    function  ActiveFacts(const Today: string): TStoredFactArray;
    function  AllFacts: TStoredFactArray;
    function  Supersede(Id: Int64): Boolean;
    function  Delete(Id: Int64): Boolean;
    function  CountAll: Integer;
    function  CountActive(const Today: string): Integer;
  end;

function NewFactStore: IFactStore;
begin
  Result := TFactStoreImpl.Create;
end;

destructor TFactStoreImpl.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TFactStoreImpl.NewQuery: TQuery;
begin
  Result := TQuery.Create(nil);
  {$IFDEF FPC}
  Result.Database := FConn;
  {$ELSE}
  Result.Connection := FConn;
  {$ENDIF}
end;

procedure TFactStoreImpl.PStr(Q: TQuery; const N, V: string);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsString := V;
  {$ELSE}
  Q.ParamByName(N).AsString := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.PInt(Q: TQuery; const N: string; V: Int64);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsLargeInt := V;
  {$ELSE}
  Q.ParamByName(N).AsLargeInt := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.PFloat(Q: TQuery; const N: string; V: Double);
begin
  {$IFDEF FPC}
  Q.Params.ParamByName(N).AsFloat := V;
  {$ELSE}
  Q.ParamByName(N).AsFloat := V;
  {$ENDIF}
end;

procedure TFactStoreImpl.Commit;
begin
  {$IFDEF FPC}
  if (FTx <> nil) and FTx.Active then FTx.CommitRetaining;
  {$ENDIF}
  { FireDAC autocommits each statement by default -- no-op on Delphi. }
end;

procedure TFactStoreImpl.ExecSQL(const SQL: string);
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

procedure TFactStoreImpl.EnsureSchema;
begin
  ExecSQL(
    'CREATE TABLE IF NOT EXISTS facts (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT,' +
    '  text TEXT NOT NULL,' +
    '  kind TEXT NOT NULL,' +
    '  scope TEXT NOT NULL,' +
    '  confidence REAL NOT NULL,' +
    '  expires TEXT NOT NULL DEFAULT '''',' +
    '  source_session TEXT NOT NULL DEFAULT '''',' +
    '  created_at INTEGER NOT NULL,' +
    '  superseded INTEGER NOT NULL DEFAULT 0)');
  { Indexes that match the two hot read paths (active listing + expiry sweep). }
  ExecSQL('CREATE INDEX IF NOT EXISTS idx_facts_active ON facts(superseded, expires)');
end;

function TFactStoreImpl.Open(const DbPath: string): Boolean;
begin
  Result := False;
  if FOpen then Exit(True);
  try
    EnsureDir(ExtractFilePath(DbPath));
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
    LogDebug('memory.facts: opened %s', [DbPath]);
  except
    on E: Exception do
    begin
      LogWarn('memory.facts: failed to open %s (%s) -- fact store disabled',
              [DbPath, E.Message]);
      {$IFDEF FPC}
      FreeAndNil(FTx);
      {$ENDIF}
      FreeAndNil(FConn);
      FOpen := False;
    end;
  end;
end;

procedure TFactStoreImpl.Close;
begin
  if not FOpen then Exit;
  try
    {$IFDEF FPC}
    if (FTx <> nil) and FTx.Active then FTx.Commit;
    if (FConn <> nil) and FConn.Connected then FConn.Close;
    FreeAndNil(FTx);
    {$ELSE}
    if (FConn <> nil) and FConn.Connected then FConn.Connected := False;
    {$ENDIF}
    FreeAndNil(FConn);
  except
    on E: Exception do
      LogWarn('memory.facts: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TFactStoreImpl.Add(const F: TFact; CreatedAt: Int64): Int64;
var
  Q: TQuery;
  TodayStr: string;
begin
  Result := 0;
  if not FOpen then Exit;
  { Exact-text dedup: per-turn auto-distill keeps re-surfacing the same
    wording, so if an ACTIVE fact already has this exact text (case-
    insensitive) return its id instead of inserting a duplicate. Cheap;
    paraphrase/semantic dedup is a later phase.

    Must use the SAME active predicate as ActiveFacts -- skip EXPIRED
    rows too. Otherwise a re-observed fact whose old copy has expired
    would match the stale row and never re-enter active memory. "today"
    is the date this fact is being created (CreatedAt). }
  TodayStr := FormatDateTime('yyyy"-"mm"-"dd', UnixToDateTime(CreatedAt, False));
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT id FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today) ' +
      'AND lower(text) = lower(:t) LIMIT 1';
    PStr(Q, 'today', TodayStr);
    PStr(Q, 't', F.Text);
    Q.Open;
    if not Q.EOF then
    begin
      Result := Q.Fields[0].AsLargeInt;
      Q.Close;
      Exit;
    end;
    Q.Close;
  finally
    Q.Free;
  end;
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'INSERT INTO facts (text, kind, scope, confidence, expires, ' +
      'source_session, created_at, superseded) ' +
      'VALUES (:t, :k, :sc, :cf, :ex, :ss, :ca, 0)';
    PStr  (Q, 't',  F.Text);
    PStr  (Q, 'k',  F.Kind);
    PStr  (Q, 'sc', F.Scope);
    PFloat(Q, 'cf', F.Confidence);
    PStr  (Q, 'ex', F.Expires);
    PStr  (Q, 'ss', F.SourceSession);
    PInt  (Q, 'ca', CreatedAt);
    Q.ExecSQL;
    Commit;
    Q.SQL.Text := 'SELECT last_insert_rowid()';
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsLargeInt;
    Q.Close;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.ReadRows(Q: TQuery): TStoredFactArray;
var
  F: TStoredFact;
begin
  Result := nil;
  Q.Open;
  while not Q.EOF do
  begin
    F.Id            := Q.FieldByName('id').AsLargeInt;
    F.Text          := Q.FieldByName('text').AsString;
    F.Kind          := Q.FieldByName('kind').AsString;
    F.Scope         := Q.FieldByName('scope').AsString;
    F.Confidence    := Q.FieldByName('confidence').AsFloat;
    F.Expires       := Q.FieldByName('expires').AsString;
    F.SourceSession := Q.FieldByName('source_session').AsString;
    F.CreatedAt     := Q.FieldByName('created_at').AsLargeInt;
    F.Superseded    := Q.FieldByName('superseded').AsLargeInt <> 0;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := F;
    Q.Next;
  end;
  Q.Close;
end;

function TFactStoreImpl.ActiveFacts(const Today: string): TStoredFactArray;
var
  Q: TQuery;
begin
  Result := nil;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT * FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today) ' +
      'ORDER BY created_at DESC, id DESC';
    PStr(Q, 'today', Today);
    Result := ReadRows(Q);
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.AllFacts: TStoredFactArray;
var
  Q: TQuery;
begin
  Result := nil;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'SELECT * FROM facts ORDER BY created_at DESC, id DESC';
    Result := ReadRows(Q);
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.Supersede(Id: Int64): Boolean;
var
  Q: TQuery;
begin
  Result := False;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'UPDATE facts SET superseded = 1 WHERE id = :id AND superseded = 0';
    PInt(Q, 'id', Id);
    Q.ExecSQL;
    Result := Q.RowsAffected > 0;
    Commit;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.Delete(Id: Int64): Boolean;
var
  Q: TQuery;
begin
  Result := False;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'DELETE FROM facts WHERE id = :id';
    PInt(Q, 'id', Id);
    Q.ExecSQL;
    Result := Q.RowsAffected > 0;
    Commit;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.CountAll: Integer;
var
  Q: TQuery;
begin
  Result := 0;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text := 'SELECT COUNT(*) FROM facts';
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsInteger;
    Q.Close;
  finally
    Q.Free;
  end;
end;

function TFactStoreImpl.CountActive(const Today: string): Integer;
{ Same predicate as ActiveFacts(Today): not superseded AND not expired.
  Kept in lockstep so Count and the listing can't disagree (the earlier
  Count(False) only filtered superseded and over-counted expired rows). }
var
  Q: TQuery;
begin
  Result := 0;
  if not FOpen then Exit;
  Q := NewQuery;
  try
    Q.SQL.Text :=
      'SELECT COUNT(*) FROM facts WHERE superseded = 0 ' +
      'AND (expires = '''' OR expires >= :today)';
    PStr(Q, 'today', Today);
    Q.Open;
    if not Q.EOF then Result := Q.Fields[0].AsInteger;
    Q.Close;
  finally
    Q.Free;
  end;
end;

end.
