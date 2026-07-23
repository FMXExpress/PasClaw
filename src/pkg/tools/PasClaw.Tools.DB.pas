(*
  PasClaw.Tools.DB - the agent-facing database tools:

    db_info      driver, access mode, row cap, redacted connection string
    db_tables    list tables/views
    db_describe  columns of a table (name, type, size, nullable)
    db_query     run a read query (SELECT/WITH/EXPLAIN) with :name params
    db_execute   run a write/DDL statement -- gated by the connection's mode

  Registered alongside skills/workflows at every registry-build site; inert
  until SetDBConfig supplies at least one connection (Phase 2 wires config.json
  at each entry point). The safety model mirrors TMS' FireDAC MCP server:

    - capability by mode: db_execute refuses on a readonly connection; DDL/other
      refuse outside "full". Gating is per-connection (each named connection
      carries its own mode) and enforced at call time.
    - SQL is classified after comments/literals are stripped, so a keyword
      hidden in a comment or string can't smuggle a write past db_query.
    - statement stacking (a second statement after ';') is rejected.
    - values bind as :name parameters -- never string-concatenated.
    - results are capped at the connection's max_rows with a "truncated" flag.
    - db_info redacts the password.
*)
unit PasClaw.Tools.DB;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Tools.Registry,
  PasClaw.DB;

{ Supply the configured connections. Replaces any previous set. Passing an empty
  array leaves the tools registered but inert. }
procedure SetDBConfig(const Conns: array of TDBConn);

{ Parse a JSON array of connection objects (the config.json "database" section)
  and install them. Each object:
    name, driver, database, server, port, user, password, params, mode,
    max_rows, timeout_ms
  Empty/invalid JSON clears the config. Returns how many were installed. This is
  the seam Phase 2 calls at each entry point with Cfg's raw database section. }
function SetDBConfigFromJSON(const ArrayJSON: string): Integer;

{ How many connections are currently configured. }
function DBConnectionCount: Integer;

{ Register db_info / db_tables / db_describe / db_query / db_execute on Reg. }
procedure RegisterDBTools(Reg: TToolRegistry);

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Tools.Types;

var
  GConns: array of TDBConn;

procedure SetDBConfig(const Conns: array of TDBConn);
var i: Integer;
begin
  SetLength(GConns, Length(Conns));
  for i := 0 to High(Conns) do
    GConns[i] := Conns[i];
end;

function DBConnectionCount: Integer;
begin
  Result := Length(GConns);
end;

function SetDBConfigFromJSON(const ArrayJSON: string): Integer;
var
  Arr: TJsonArray;
  O: TJsonObject;
  Conns: array of TDBConn;
  i, n: Integer;
begin
  Result := 0;
  SetLength(GConns, 0);
  if Trim(ArrayJSON) = '' then Exit;
  try Arr := TJsonArray.Parse(ArrayJSON); except Arr := nil; end;
  if Arr = nil then Exit;
  try
    SetLength(Conns, Arr.Count);
    n := 0;
    for i := 0 to Arr.Count - 1 do
    begin
      O := Arr.ItemObject(i);
      if O = nil then Continue;
      { FillChar-free init: assign every field so managed strings stay sane. }
      Conns[n].Name        := O.GetStr('name', '');
      Conns[n].Driver      := O.GetStr('driver', '');
      Conns[n].Database    := O.GetStr('database', '');
      Conns[n].Server      := O.GetStr('server', '');
      Conns[n].Port        := Integer(O.GetInt('port', 0));
      Conns[n].User        := O.GetStr('user', '');
      Conns[n].Password     := O.GetStr('password', '');
      Conns[n].ExtraParams := O.GetStr('params', '');
      Conns[n].Mode        := ParseDBMode(O.GetStr('mode', 'readonly'));
      Conns[n].MaxRows     := Integer(O.GetInt('max_rows', DB_DEFAULT_MAXROWS));
      Conns[n].TimeoutMs   := Integer(O.GetInt('timeout_ms', 0));
      if (Conns[n].Name = '') and (i = 0) then Conns[n].Name := 'default';
      Inc(n);
    end;
    SetLength(Conns, n);
    SetDBConfig(Conns);
    Result := n;
  finally
    Arr.Free;
  end;
end;

{ Select a connection by name (empty => the first/default). Returns False with a
  ready-to-surface message when there are none or the name is unknown. }
function PickConn(const Name: string; out Cfg: TDBConn; out ErrMsg: string): Boolean;
var i: Integer;
begin
  Result := False;
  if Length(GConns) = 0 then
  begin
    ErrMsg := 'no database configured -- add a "database" section to config.json ' +
              '(name, driver, database, mode) and restart';
    Exit;
  end;
  if Trim(Name) = '' then
  begin Cfg := GConns[0]; Exit(True); end;
  for i := 0 to High(GConns) do
    if SameText(GConns[i].Name, Name) then
    begin Cfg := GConns[i]; Exit(True); end;
  ErrMsg := Format('unknown connection "%s" -- configured: ', [Name]);
  for i := 0 to High(GConns) do
  begin
    if i > 0 then ErrMsg := ErrMsg + ', ';
    ErrMsg := ErrMsg + GConns[i].Name;
  end;
end;

{ Parse the shared args: connection name, sql, params-object JSON. }
procedure ParseCommon(const ArgsJSON: string; out ConnName, SQL, ParamsJSON: string);
var
  Args, P: TJsonObject;
begin
  ConnName := ''; SQL := ''; ParamsJSON := '';
  try Args := TJsonObject.Parse(ArgsJSON); except Args := nil; end;
  if Args = nil then Exit;
  try
    ConnName := Args.GetStr('connection', '');
    SQL      := Args.GetStr('sql', '');
    P := Args.ChildObject('params');
    if P <> nil then ParamsJSON := P.ToJSON;
  finally
    Args.Free;
  end;
end;

function ToolDBInfo(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName: string;
  Root: TJsonObject;
begin
  ErrMsg := '';
  ConnName := JsonReadStr(ArgsJSON, 'connection', '');
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');
  Root := TJsonObject.Create;
  try
    Root.PutStr('name', Cfg.Name);
    Root.PutStr('driver', Cfg.Driver);
    Root.PutStr('mode', DBModeName(Cfg.Mode));
    Root.PutInt('max_rows', Cfg.MaxRows);
    Root.PutStr('connection', RedactConnString(Cfg));
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function ToolDBTables(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, Err, ListJSON: string;
  Conn: IDBConnection;
  Root: TJsonObject;
begin
  ErrMsg := '';
  ConnName := JsonReadStr(ArgsJSON, 'connection', '');
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');
  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_tables: ' + Err; Exit(''); end;
  try
    if not Conn.ListTables(ListJSON, Err) then
    begin ErrMsg := 'db_tables: ' + Err; Exit(''); end;
    Root := TJsonObject.Create;
    try
      Root.PutRaw('tables', ListJSON);
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Conn.Close;
  end;
end;

function ToolDBDescribe(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, Table, Err, ColsJSON: string;
  Conn: IDBConnection;
  Root: TJsonObject;
begin
  ErrMsg := '';
  ConnName := JsonReadStr(ArgsJSON, 'connection', '');
  Table    := JsonReadStr(ArgsJSON, 'table', '');
  if Trim(Table) = '' then begin ErrMsg := 'db_describe: "table" is required'; Exit(''); end;
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');
  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_describe: ' + Err; Exit(''); end;
  try
    if not Conn.DescribeTable(Table, ColsJSON, Err) then
    begin ErrMsg := 'db_describe: ' + Err; Exit(''); end;
    Root := TJsonObject.Create;
    try
      Root.PutStr('table', Table);
      Root.PutRaw('columns', ColsJSON);
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Conn.Close;
  end;
end;

function ToolDBQuery(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, SQL, ParamsJSON, Err, RowsJSON, FirstWord: string;
  Conn: IDBConnection;
  Root: TJsonObject;
  Kind: TSQLKind;
  RowCount, MaxRows: Integer;
  Truncated: Boolean;
begin
  ErrMsg := '';
  ParseCommon(ArgsJSON, ConnName, SQL, ParamsJSON);
  if Trim(SQL) = '' then begin ErrMsg := 'db_query: "sql" is required'; Exit(''); end;
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');

  if SQLHasMultipleStatements(SQL) then
  begin ErrMsg := 'db_query: multiple statements are not allowed (one query per call)'; Exit(''); end;
  Kind := ClassifySQL(SQL, FirstWord);
  if Kind <> skReadOnly then
  begin
    ErrMsg := Format('db_query only runs read statements (SELECT/WITH/EXPLAIN); ' +
                     'got %s. Use db_execute for writes.', [FirstWord]);
    Exit('');
  end;

  MaxRows := Integer(JsonReadInt(ArgsJSON, 'max_rows', Cfg.MaxRows));
  if (MaxRows <= 0) or (MaxRows > Cfg.MaxRows) then MaxRows := Cfg.MaxRows;

  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_query: ' + Err; Exit(''); end;
  try
    if not Conn.Query(SQL, ParamsJSON, MaxRows, RowsJSON, RowCount, Truncated, Err) then
    begin ErrMsg := 'db_query: ' + Err; Exit(''); end;
    Root := TJsonObject.Create;
    try
      Root.PutBool('ok', True);
      Root.PutRaw('rows', RowsJSON);
      Root.PutInt('row_count', RowCount);
      Root.PutBool('truncated', Truncated);
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Conn.Close;
  end;
end;

function ToolDBExecute(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, SQL, ParamsJSON, Err, FirstWord: string;
  Conn: IDBConnection;
  Root: TJsonObject;
  Kind: TSQLKind;
  RowsAffected: Integer;
begin
  ErrMsg := '';
  ParseCommon(ArgsJSON, ConnName, SQL, ParamsJSON);
  if Trim(SQL) = '' then begin ErrMsg := 'db_execute: "sql" is required'; Exit(''); end;
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');

  { capability gating, per the connection's mode }
  if Cfg.Mode = dbmReadOnly then
  begin
    ErrMsg := Format('db_execute: connection "%s" is readonly -- no writes permitted', [Cfg.Name]);
    Exit('');
  end;
  if SQLHasMultipleStatements(SQL) then
  begin ErrMsg := 'db_execute: multiple statements are not allowed (one per call)'; Exit(''); end;

  Kind := ClassifySQL(SQL, FirstWord);
  case Kind of
    skReadOnly:
      begin ErrMsg := 'db_execute is for writes; use db_query for ' + FirstWord; Exit(''); end;
    skDML: ;   { allowed in readwrite + full }
    skDDL, skOther:
      if Cfg.Mode <> dbmFull then
      begin
        ErrMsg := Format('db_execute: %s requires "full" mode (connection "%s" is %s)',
                         [FirstWord, Cfg.Name, DBModeName(Cfg.Mode)]);
        Exit('');
      end;
    skEmpty:
      begin ErrMsg := 'db_execute: empty statement'; Exit(''); end;
  end;

  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_execute: ' + Err; Exit(''); end;
  try
    if not Conn.Execute(SQL, ParamsJSON, RowsAffected, Err) then
    begin ErrMsg := 'db_execute: ' + Err; Exit(''); end;
    Root := TJsonObject.Create;
    try
      Root.PutBool('ok', True);
      Root.PutInt('rows_affected', RowsAffected);
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Conn.Close;
  end;
end;

{ ---- Phase 4: DBA layer (schema digest + query-plan / index advisor) ---- }

{ SELECT COUNT(*) for a table via the read path; -1 on any error (view without
  count support, permission, etc.). Table is identifier-validated by the caller. }
function CountRows(Conn: IDBConnection; const Table: string): Int64;
var
  RowsJSON, Err: string;
  RC: Integer;
  Trunc: Boolean;
  Arr: TJsonArray;
  O: TJsonObject;
begin
  Result := -1;
  if not Conn.Query('SELECT COUNT(*) AS n FROM ' + Table, '', 1, RowsJSON, RC, Trunc, Err) then Exit;
  try Arr := TJsonArray.Parse(RowsJSON); except Arr := nil; end;
  if Arr = nil then Exit;
  try
    if Arr.Count > 0 then
    begin
      O := Arr.ItemObject(0);
      if O <> nil then try Result := O.GetInt('n', -1); finally O.Free; end;
    end;
  finally
    Arr.Free;
  end;
end;

{ SQLite plans read-only via "EXPLAIN QUERY PLAN"; other engines use "EXPLAIN". }
function ExplainPrefix(const Driver: string): string;
var D: string;
begin
  D := LowerCase(Trim(Driver));
  if (D = 'sqlite') or (D = 'sqlite3') then Result := 'EXPLAIN QUERY PLAN '
  else Result := 'EXPLAIN ';
end;

{ Pull table names from a SQLite EXPLAIN QUERY PLAN "detail" that is a full table
  SCAN (no index). "SCAN t" => full scan; "SEARCH t USING INDEX" and
  "SCAN t USING COVERING INDEX" are indexed and ignored. Appends to Scans. }
procedure CollectFullScan(const Detail: string; Scans: TStringList);

  { read the identifier at position i (letters/digits/underscore), advancing i }
  function WordAt(var i: Integer): string;
  begin
    Result := '';
    while (i <= Length(Detail)) and (Detail[i] = ' ') do Inc(i);
    while (i <= Length(Detail)) and
          (((Detail[i] >= 'A') and (Detail[i] <= 'Z')) or
           ((Detail[i] >= 'a') and (Detail[i] <= 'z')) or
           ((Detail[i] >= '0') and (Detail[i] <= '9')) or (Detail[i] = '_')) do
    begin Result := Result + Detail[i]; Inc(i); end;
  end;

var U, Tbl: string; p, i: Integer;
begin
  U := UpperCase(Detail);
  p := Pos('SCAN ', U);
  if p = 0 then Exit;
  if Pos('USING', U) > 0 then Exit;   { covering/secondary index -- not a full scan }
  i := p + 5;
  Tbl := WordAt(i);
  { older SQLite says "SCAN TABLE t", newer just "SCAN t" -- skip the keyword }
  if UpperCase(Tbl) = 'TABLE' then Tbl := WordAt(i);
  if (Tbl <> '') and (Scans.IndexOf(Tbl) < 0) then Scans.Add(Tbl);
end;

function ToolDBSchema(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, OneTable, Err, ListJSON, ColsJSON: string;
  WithCounts: Boolean;
  Conn: IDBConnection;
  Root, TblObj: TJsonObject;
  Tables: TJsonArray;
  Names: TStringList;
  ListArr: TJsonArray;
  i, Cap: Integer;
  RC: Int64;
begin
  ErrMsg := '';
  ConnName   := JsonReadStr(ArgsJSON, 'connection', '');
  OneTable   := JsonReadStr(ArgsJSON, 'table', '');
  WithCounts := JsonReadBool(ArgsJSON, 'with_row_counts', True);
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');

  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_schema: ' + Err; Exit(''); end;
  Names := TStringList.Create;
  try
    if Trim(OneTable) <> '' then
      Names.Add(OneTable)
    else
    begin
      if not Conn.ListTables(ListJSON, Err) then
      begin ErrMsg := 'db_schema: ' + Err; Exit(''); end;
      try ListArr := TJsonArray.Parse(ListJSON); except ListArr := nil; end;
      if ListArr <> nil then
      try
        for i := 0 to ListArr.Count - 1 do Names.Add(ListArr.ItemStr(i, ''));
      finally
        ListArr.Free;
      end;
    end;

    Root := TJsonObject.Create;
    try
      Root.PutStr('database', Cfg.Name);
      Root.PutStr('driver', Cfg.Driver);
      Tables := TJsonArray.Create;
      Cap := 200;   { keep the digest bounded for large schemas }
      for i := 0 to Names.Count - 1 do
      begin
        if i >= Cap then Break;
        if Trim(Names[i]) = '' then Continue;
        TblObj := TJsonObject.Create;
        TblObj.PutStr('name', Names[i]);
        if Conn.DescribeTable(Names[i], ColsJSON, Err) then
          TblObj.PutRaw('columns', ColsJSON)
        else
          TblObj.PutRaw('columns', '[]');
        if WithCounts and IsSafeIdentifier(Names[i]) then
        begin
          RC := CountRows(Conn, Names[i]);
          if RC >= 0 then TblObj.PutInt('row_count', RC);
        end;
        Tables.AddObject(TblObj);
      end;
      Root.PutArray('tables', Tables);
      if Names.Count > Cap then
        Root.PutStr('note', Format('showing first %d of %d tables', [Cap, Names.Count]));
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Names.Free;
    Conn.Close;
  end;
end;

function ToolDBExplain(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cfg: TDBConn;
  ConnName, SQL, ParamsJSON, Err, PlanJSON: string;
  Conn: IDBConnection;
  Root, O: TJsonObject;
  Plan: TJsonArray;
  Scans: TStringList;
  ScanArr: TJsonArray;
  RC, i, k: Integer;
  Trunc: Boolean;
  Keys: TStringList;
begin
  ErrMsg := '';
  ParseCommon(ArgsJSON, ConnName, SQL, ParamsJSON);
  if Trim(SQL) = '' then begin ErrMsg := 'db_explain: "sql" is required'; Exit(''); end;
  if not PickConn(ConnName, Cfg, ErrMsg) then Exit('');
  if SQLHasMultipleStatements(SQL) then
  begin ErrMsg := 'db_explain: one statement per call'; Exit(''); end;

  Conn := NewDBConnection;
  if not Conn.Open(Cfg, Err) then begin ErrMsg := 'db_explain: ' + Err; Exit(''); end;
  Scans := TStringList.Create;
  try
    { EXPLAIN / EXPLAIN QUERY PLAN only PLANS -- it never executes the statement,
      so this is read-only regardless of the query's verb. }
    if not Conn.Query(ExplainPrefix(Cfg.Driver) + SQL, ParamsJSON, 500,
                      PlanJSON, RC, Trunc, Err) then
    begin ErrMsg := 'db_explain: ' + Err; Exit(''); end;

    { Heuristic full-scan detection (SQLite plan "detail" strings). Scan every
      string field of every plan row so it's tolerant of column-name shape. }
    try Plan := TJsonArray.Parse(PlanJSON); except Plan := nil; end;
    if Plan <> nil then
    try
      for i := 0 to Plan.Count - 1 do
      begin
        O := Plan.ItemObject(i);
        if O = nil then Continue;
        try
          Keys := O.Keys;
          try
            for k := 0 to Keys.Count - 1 do
              CollectFullScan(O.GetStr(Keys[k], ''), Scans);
          finally
            Keys.Free;
          end;
        finally
          O.Free;
        end;
      end;
    finally
      Plan.Free;
    end;

    Root := TJsonObject.Create;
    try
      Root.PutBool('ok', True);
      Root.PutRaw('plan', PlanJSON);
      ScanArr := TJsonArray.Create;
      for i := 0 to Scans.Count - 1 do ScanArr.AddStr(Scans[i]);
      Root.PutArray('full_scans', ScanArr);
      if Scans.Count > 0 then
        Root.PutStr('hint',
          'full table scan on: ' + Scans.CommaText +
          ' -- consider an index on the WHERE / JOIN / ORDER BY columns for ' +
          'those tables, then re-run db_explain to confirm the plan switches to ' +
          'a SEARCH ... USING INDEX.');
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  finally
    Scans.Free;
    Conn.Close;
  end;
end;

const
  CONN_ARG =
    '"connection":{"type":"string","description":"configured connection name; ' +
    'omit to use the default (first) connection"}';

  INFO_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + '}}';
  TABLES_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + '}}';
  DESCRIBE_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + ',' +
    '"table":{"type":"string","description":"table or view name (optionally schema.table)"}' +
    '},"required":["table"]}';
  QUERY_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + ',' +
    '"sql":{"type":"string","description":"a single read statement (SELECT/WITH/EXPLAIN). ' +
      'Use :name placeholders for values and pass them in params -- never concatenate."},' +
    '"params":{"type":"object","description":"values for :name placeholders, e.g. {\"id\":42}"},' +
    '"max_rows":{"type":"integer","minimum":1,"description":"cap rows returned (<= the connection max)"}' +
    '},"required":["sql"]}';
  EXECUTE_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + ',' +
    '"sql":{"type":"string","description":"a single write statement (INSERT/UPDATE/DELETE); ' +
      'DDL requires a full-mode connection. Use :name placeholders + params."},' +
    '"params":{"type":"object","description":"values for :name placeholders"}' +
    '},"required":["sql"]}';
  SCHEMA_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + ',' +
    '"table":{"type":"string","description":"limit to one table (optionally schema.table); omit for the whole schema"},' +
    '"with_row_counts":{"type":"boolean","description":"include per-table row counts (default true)"}' +
    '}}';
  EXPLAIN_SCHEMA =
    '{"type":"object","properties":{' + CONN_ARG + ',' +
    '"sql":{"type":"string","description":"the query to analyze. It is PLANNED, not run."},' +
    '"params":{"type":"object","description":"values for :name placeholders"}' +
    '},"required":["sql"]}';

procedure Reg1(Reg: TToolRegistry; const AName, ADesc, ASchema: string;
  AHandler: TToolHandler; ACat: TToolCategory);
var T: TTool;
begin
  { Set every field explicitly -- FillChar on a record with managed strings
    corrupts refcounts. }
  T.Name        := AName;
  T.Description := ADesc;
  T.Schema      := ASchema;
  T.Handler     := AHandler;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := ACat;
  T.IsDeferred  := False;
  T.Hidden      := False;
  Reg.Register(T);
end;

procedure RegisterDBTools(Reg: TToolRegistry);
begin
  if Reg = nil then Exit;
  Reg1(Reg, 'db_info',
    'Report the active database: driver, access mode (readonly/readwrite/full), ' +
    'row cap, and a password-redacted connection string. Optional "connection" ' +
    'selects a named connection.',
    INFO_SCHEMA, ToolDBInfo, tcReadOnly);

  Reg1(Reg, 'db_tables',
    'List tables and views in the database.',
    TABLES_SCHEMA, ToolDBTables, tcReadOnly);

  Reg1(Reg, 'db_describe',
    'Describe a table: column names, types, sizes, and nullability.',
    DESCRIBE_SCHEMA, ToolDBDescribe, tcReadOnly);

  Reg1(Reg, 'db_query',
    'Run ONE read query (SELECT/WITH/EXPLAIN) and return rows as JSON. Bind ' +
    'values with :name placeholders and pass them in "params" -- never build ' +
    'SQL by string concatenation. Results are capped; a "truncated" flag ' +
    'signals more rows exist. Writes are rejected here -- use db_execute.',
    QUERY_SCHEMA, ToolDBQuery, tcReadOnly);

  Reg1(Reg, 'db_execute',
    'Run ONE write statement (INSERT/UPDATE/DELETE, or DDL on a full-mode ' +
    'connection) and return the affected row count. Refused on a readonly ' +
    'connection. Bind values with :name placeholders + "params".',
    EXECUTE_SCHEMA, ToolDBExecute, tcMutating);

  Reg1(Reg, 'db_schema',
    'Digest the schema for grounding SQL: every table (or one named table) with ' +
    'its columns (name/type/nullable) and, by default, its row count. Read this ' +
    'before writing queries against an unfamiliar database, and store durable ' +
    'business rules ("MRR = ...", "active = status IN (...)") with the memory ' +
    'tools so they persist across sessions.',
    SCHEMA_SCHEMA, ToolDBSchema, tcReadOnly);

  Reg1(Reg, 'db_explain',
    'Analyze a query WITHOUT running it: returns the engine query plan plus ' +
    '"full_scans" (tables read without an index) and an index hint. Use it to ' +
    'diagnose slow queries and validate that a proposed index is actually used ' +
    '(re-run and confirm the plan switches to SEARCH ... USING INDEX).',
    EXPLAIN_SCHEMA, ToolDBExplain, tcReadOnly);
end;

end.
