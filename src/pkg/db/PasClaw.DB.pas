(*
  PasClaw.DB - engine-agnostic database seam + SQL safety helpers.

  This is the bottom layer that PasClaw.Tools.DB registers as agent tools
  (db_info / db_tables / db_describe / db_query / db_execute). It mirrors the
  design of TMS' FireDAC MCP server but cross-compiler:

    - {$IFDEF FPC}: sqldb's TSQLConnector (+ TSQLTransaction). The connector
      type is selected from config, so the same binary reaches SQLite,
      PostgreSQL, MySQL, Firebird, MSSQL, Oracle and ODBC once the matching
      connector unit is linked (Phase 2). Phase 1 links + tests SQLite only.
    - {$ELSE}: FireDAC's TFDConnection, DriverName selected from config. Phase 1
      links FireDAC.Phys.SQLite.

  The SQL-safety helpers (classification, statement-stacking detection,
  connection-string redaction) live here so they are unit-testable without a
  live connection. Enforcement (readonly/readwrite/full gating) is applied by
  the tool layer on top of ClassifySQL.
*)
unit PasClaw.DB;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

type
  { Access level for a connection, lowest to highest capability. Mirrors TMS'
    -mode= flag. readonly is the safe default: only SELECT / metadata run. }
  TDBMode = (dbmReadOnly, dbmReadWrite, dbmFull);

  { A named connection's config. Passwords are held here but never emitted --
    Info() / RedactConnString redact them. }
  TDBConn = record
    Name:      string;   (* logical name the agent selects via the "connection" arg *)
    Driver:    string;   { canonical: sqlite|postgres|mysql|mssql|firebird|oracle|odbc }
    Database:  string;   { db name or, for sqlite, the file path }
    Server:    string;
    Port:      Integer;
    User:      string;
    Password:  string;
    ExtraParams: string; { engine-specific "k=v;k=v" appended verbatim }
    Mode:      TDBMode;
    MaxRows:   Integer;  { hard cap on rows a single query returns (0 => default) }
    TimeoutMs: Integer;
  end;

  { What a statement does, after comments/literals are stripped. }
  TSQLKind = (
    skEmpty,     { no statement }
    skReadOnly,  { SELECT / WITH / EXPLAIN / SHOW / PRAGMA-read / VALUES }
    skDML,       { INSERT / UPDATE / DELETE / MERGE / REPLACE / UPSERT }
    skDDL,       { CREATE / ALTER / DROP / TRUNCATE / RENAME }
    skOther);    { anything else: ATTACH / VACUUM / GRANT / EXEC / PRAGMA-write ... }

  { The execution seam. One instance wraps one open connection. }
  IDBConnection = interface
    ['{5F3A9C21-8B4E-4D6A-9F17-3C2E7A1B0D44}']
    function  Open(const Cfg: TDBConn; out Err: string): Boolean;
    procedure Close;
    function  IsOpen: Boolean;
    (* Run a read query. ParamsJSON is a flat name->value object whose keys bind
       to :name placeholders (all bound as strings -- see unit notes). Rows
       beyond MaxRows are dropped and Truncated is set. ResultJSON is a JSON
       array of row objects. *)
    function  Query(const SQL, ParamsJSON: string; MaxRows: Integer;
                    out ResultJSON: string; out RowCount: Integer;
                    out Truncated: Boolean; out Err: string): Boolean;
    { Run a write/DDL statement; returns rows affected (-1 if the engine
      doesn't report it). }
    function  Execute(const SQL, ParamsJSON: string; out RowsAffected: Integer;
                      out Err: string): Boolean;
    { Metadata via the driver's own catalog access (no engine-specific SQL). }
    function  ListTables(out ResultJSON, Err: string): Boolean;
    function  DescribeTable(const TableName: string; out ResultJSON, Err: string): Boolean;
  end;

function NewDBConnection: IDBConnection;

{ ---- SQL safety helpers (pure; unit-testable without a connection) ---- }

{ Remove line (-- ...) and block (/* ... */) comments and the contents of
  single- and double-quoted string literals, so classification/stacking checks
  can't be fooled by keywords hidden inside comments or text. }
function StripSQLNoise(const SQL: string): string;

{ Classify the (first) statement. FirstWord returns the leading keyword upper-
  cased. Returns skEmpty for blank input. }
function ClassifySQL(const SQL: string; out FirstWord: string): TSQLKind;

{ True when SQL contains more than one statement (stacking), judged after
  stripping comments/literals so a ';' inside a string doesn't count. A single
  trailing ';' is not stacking. }
function SQLHasMultipleStatements(const SQL: string): Boolean;

{ Passwords/secrets removed; safe to surface to the model. }
function RedactConnString(const Cfg: TDBConn): string;

{ "readonly"|"readwrite"|"full" (case-insensitive) -> mode; default readonly. }
function ParseDBMode(const S: string): TDBMode;
function DBModeName(M: TDBMode): string;

{ True when Ident is a plain SQL identifier (optionally schema-qualified):
  letters/digits/underscore, at most one dot. Used to gate table names that get
  interpolated into "SELECT * FROM <ident> WHERE 1=0" for describe. }
function IsSafeIdentifier(const Ident: string): Boolean;

const
  DB_DEFAULT_MAXROWS = 1000;   { same default cap as TMS' -maxrows }
  DB_CELL_CAP        = 8192;   { per-cell string cap; longer values are truncated }

implementation

uses
  SysUtils, Classes, TypInfo,
  {$IFDEF FPC}
  DB, sqldb, fpjson,
  { Each connector unit self-registers its TSQLConnector type. Linking them all
    keeps one binary multi-engine; the client library (libpq / libmysqlclient /
    libfb / FreeTDS / Oracle OCI / unixODBC) is loaded lazily at connect time,
    so a missing lib only fails that connection -- it doesn't break the build or
    other engines. }
  sqlite3conn, pqconnection, mysql57conn, mysql80conn,
  ibconnection, mssqlconn, odbcconn, oracleconnection,
  {$ELSE}
  Data.DB, System.JSON,
  FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Async,
  FireDAC.Stan.Param, FireDAC.DApt, FireDAC.Phys.SQLite,
  { Extra FireDAC drivers need RAD Studio Enterprise/Architect. Build with
    -dPASCLAW_FIREDAC_FULL to link them; the SQLite driver above is in every
    edition, so the default build stays portable. }
  {$IFDEF PASCLAW_FIREDAC_FULL}
  FireDAC.Phys.PG, FireDAC.Phys.MySQL, FireDAC.Phys.MSSQL,
  FireDAC.Phys.Oracle, FireDAC.Phys.IB, FireDAC.Phys.ODBCBase, FireDAC.Phys.ODBC,
  {$ENDIF}
  {$ENDIF}
  PasClaw.JSON,
  PasClaw.Logger;

{ ------------------------------------------------------------------ }
{ SQL safety helpers                                                  }
{ ------------------------------------------------------------------ }

function StripSQLNoise(const SQL: string): string;
var
  i, n: Integer;
  c, q: Char;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    i := 1; n := Length(SQL);
    while i <= n do
    begin
      c := SQL[i];
      { line comment -- ... EOL }
      if (c = '-') and (i < n) and (SQL[i + 1] = '-') then
      begin
        Inc(i, 2);
        while (i <= n) and (SQL[i] <> #10) and (SQL[i] <> #13) do Inc(i);
        SB.Append(' ');
        Continue;
      end;
      { block comment /* ... */ }
      if (c = '/') and (i < n) and (SQL[i + 1] = '*') then
      begin
        Inc(i, 2);
        while (i < n) and not ((SQL[i] = '*') and (SQL[i + 1] = '/')) do Inc(i);
        Inc(i, 2);   { skip the closing */ (or run off the end) }
        SB.Append(' ');
        Continue;
      end;
      { string literal '...' or "..." -- collapse to a placeholder, honouring
        the SQL-standard doubled-quote escape ('' / "") }
      if (c = '''') or (c = '"') then
      begin
        q := c;
        Inc(i);
        while i <= n do
        begin
          if SQL[i] = q then
          begin
            if (i < n) and (SQL[i + 1] = q) then Inc(i, 2)   { escaped quote }
            else begin Inc(i); Break; end;
          end
          else Inc(i);
        end;
        SB.Append(' '' ''');   { keep a token so "WHERE x=''" still parses shape }
        Continue;
      end;
      SB.Append(c);
      Inc(i);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function LeadingWord(const S: string): string;
var i, a: Integer;
begin
  Result := '';
  i := 1;
  while (i <= Length(S)) and (S[i] <= ' ') do Inc(i);
  { skip a leading '(' that some SELECTs wrap in, and any following space }
  while (i <= Length(S)) and ((S[i] = '(') or (S[i] <= ' ')) do Inc(i);
  a := i;
  while (i <= Length(S)) and
        (((S[i] >= 'A') and (S[i] <= 'Z')) or ((S[i] >= 'a') and (S[i] <= 'z'))) do
    Inc(i);
  Result := UpperCase(Copy(S, a, i - a));
end;

{ Map a single leading verb to its kind. WITH / EXPLAIN are resolved to their
  effective statement before this is called, so they never reach here. }
function KindOfVerb(const V: string): TSQLKind;
begin
  if (V = 'SELECT') or (V = 'VALUES') or (V = 'SHOW')
     or (V = 'DESCRIBE') or (V = 'DESC') then
    Result := skReadOnly
  else if (V = 'INSERT') or (V = 'UPDATE') or (V = 'DELETE')
     or (V = 'MERGE') or (V = 'REPLACE') or (V = 'UPSERT') then
    Result := skDML
  else if (V = 'CREATE') or (V = 'ALTER') or (V = 'DROP')
     or (V = 'TRUNCATE') or (V = 'RENAME') then
    Result := skDDL
  else
    Result := skOther;
end;

{ --- small position scanner over already-cleaned SQL --- }
procedure SkipWS(const S: string; var i: Integer);
begin
  while (i <= Length(S)) and (S[i] <= ' ') do Inc(i);
end;

function ReadWord(const S: string; var i: Integer): string;
var a: Integer;
begin
  SkipWS(S, i);
  a := i;
  while (i <= Length(S)) and
        (((S[i] >= 'A') and (S[i] <= 'Z')) or ((S[i] >= 'a') and (S[i] <= 'z'))) do
    Inc(i);
  Result := UpperCase(Copy(S, a, i - a));
end;

{ i must point at '('; advance past the matching ')'. False if unbalanced.
  Comments/string literals are already stripped, so every paren here is real. }
function SkipParenGroup(const S: string; var i: Integer): Boolean;
var depth, n: Integer;
begin
  Result := False;
  n := Length(S);
  if (i > n) or (S[i] <> '(') then Exit;
  depth := 0;
  while i <= n do
  begin
    if S[i] = '(' then Inc(depth)
    else if S[i] = ')' then
    begin
      Dec(depth);
      if depth = 0 then begin Inc(i); Exit(True); end;
    end;
    Inc(i);
  end;
end;

{ Given cleaned SQL that starts with WITH, return the MAIN statement's verb (the
  statement that follows all CTE definitions). Empty string if the CTE list
  can't be parsed -- the caller then refuses to certify it as read-only. }
function ResolveWithVerb(const Clean: string): string;
var
  i, save: Integer;
  w: string;
begin
  Result := '';
  i := 1;
  if ReadWord(Clean, i) <> 'WITH' then Exit;
  save := i;
  if ReadWord(Clean, i) <> 'RECURSIVE' then i := save;   { optional }
  while True do
  begin
    ReadWord(Clean, i);                 { CTE name }
    SkipWS(Clean, i);
    if (i <= Length(Clean)) and (Clean[i] = '(') then    { optional (col,...) }
      if not SkipParenGroup(Clean, i) then Exit;
    if ReadWord(Clean, i) <> 'AS' then Exit;             { malformed }
    save := i;                                           { optional [NOT] MATERIALIZED }
    w := ReadWord(Clean, i);
    if w = 'NOT' then ReadWord(Clean, i)
    else if w <> 'MATERIALIZED' then i := save;
    SkipWS(Clean, i);
    if (i > Length(Clean)) or (Clean[i] <> '(') then Exit;
    if not SkipParenGroup(Clean, i) then Exit;           { the CTE body }
    SkipWS(Clean, i);
    if (i <= Length(Clean)) and (Clean[i] = ',') then    { another CTE follows }
    begin Inc(i); Continue; end;
    Break;
  end;
  Result := ReadWord(Clean, i);          { the main statement's verb }
end;

{ EXPLAIN by itself only plans and is read-only. But "EXPLAIN ANALYZE <stmt>"
  (PostgreSQL) actually EXECUTES the statement, so its safety is the inner
  statement's. Return the effective verb: EXPLAIN when it's a plain plan, else
  the executed inner verb. }
function ResolveExplainVerb(const Clean: string): string;
var
  i, save: Integer;
  w: string;
  Analyze: Boolean;
begin
  i := 1;
  if ReadWord(Clean, i) <> 'EXPLAIN' then Exit('EXPLAIN');
  Analyze := False;
  { consume EXPLAIN options: ANALYZE, VERBOSE, QUERY PLAN, or a (...) option list }
  while True do
  begin
    SkipWS(Clean, i);
    if (i <= Length(Clean)) and (Clean[i] = '(') then
    begin
      { "EXPLAIN (ANALYZE, ...) stmt" -- ANALYZE inside the option list counts }
      save := i;
      if not SkipParenGroup(Clean, i) then Break;
      if Pos('ANALYZE', UpperCase(Copy(Clean, save, i - save))) > 0 then Analyze := True;
      Continue;
    end;
    save := i;
    w := ReadWord(Clean, i);
    if w = 'ANALYZE' then begin Analyze := True; Continue; end;
    if (w = 'VERBOSE') or (w = 'QUERY') or (w = 'PLAN') then Continue;
    i := save; Break;   { not an option keyword -> the inner statement starts }
  end;
  if not Analyze then Exit('EXPLAIN');   { plain plan -> read-only }
  w := ReadWord(Clean, i);               { inner statement verb executes }
  if w = 'WITH' then w := ResolveWithVerb(Copy(Clean, i - Length(w), MaxInt));
  if w = '' then Exit('');               { unparseable -> caller refuses }
  Result := w;
end;

function ClassifySQL(const SQL: string; out FirstWord: string): TSQLKind;
var
  Clean, Verb: string;
begin
  Clean := Trim(StripSQLNoise(SQL));
  FirstWord := LeadingWord(Clean);
  if FirstWord = '' then Exit(skEmpty);

  { A WITH (CTE) statement is read-only only if its MAIN statement is a read:
    "WITH c AS (SELECT 1) DELETE FROM t RETURNING *" is a WRITE. Resolve the
    verb the CTE actually runs; an unparseable CTE is not certified read-only. }
  if FirstWord = 'WITH' then
  begin
    Verb := ResolveWithVerb(Clean);
    if Verb = '' then begin FirstWord := 'WITH'; Exit(skOther); end;
    FirstWord := Verb;
    Exit(KindOfVerb(Verb));
  end;

  { EXPLAIN plans (read-only) unless it's EXPLAIN ANALYZE, which executes. }
  if FirstWord = 'EXPLAIN' then
  begin
    Verb := ResolveExplainVerb(Clean);
    if Verb = '' then begin FirstWord := 'EXPLAIN'; Exit(skOther); end;
    if Verb = 'EXPLAIN' then Exit(skReadOnly);
    FirstWord := Verb;
    Exit(KindOfVerb(Verb));
  end;

  { PRAGMA is read-only only in its "PRAGMA name;" form; "PRAGMA name = value"
    mutates. Treat the assignment form as skOther (blocked outside full). }
  if FirstWord = 'PRAGMA' then
  begin
    if Pos('=', Clean) > 0 then Exit(skOther) else Exit(skReadOnly);
  end;

  Result := KindOfVerb(FirstWord);
end;

function SQLHasMultipleStatements(const SQL: string): Boolean;
var
  Clean: string;
  i, n: Integer;
begin
  Result := False;
  Clean := StripSQLNoise(SQL);
  n := Length(Clean);
  { find the first ';' and see whether any non-space content follows it }
  i := 1;
  while i <= n do
  begin
    if Clean[i] = ';' then
    begin
      Inc(i);
      while i <= n do
      begin
        if Clean[i] > ' ' then Exit(True);   { content after a ';' => stacked }
        Inc(i);
      end;
      Exit(False);
    end;
    Inc(i);
  end;
end;

function IsSafeIdentifier(const Ident: string): Boolean;
var
  i, dots: Integer;
  c: Char;
begin
  Result := False;
  if (Ident = '') or (Length(Ident) > 128) then Exit;
  dots := 0;
  for i := 1 to Length(Ident) do
  begin
    c := Ident[i];
    if c = '.' then
    begin
      Inc(dots);
      if (dots > 1) or (i = 1) or (i = Length(Ident)) then Exit;
    end
    else if not (((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z'))
                 or ((c >= '0') and (c <= '9')) or (c = '_')) then
      Exit;
  end;
  Result := True;
end;

function ParseDBMode(const S: string): TDBMode;
var T: string;
begin
  T := LowerCase(Trim(S));
  if T = 'full' then Result := dbmFull
  else if (T = 'readwrite') or (T = 'read-write') or (T = 'rw') then Result := dbmReadWrite
  else Result := dbmReadOnly;
end;

function DBModeName(M: TDBMode): string;
begin
  case M of
    dbmFull:      Result := 'full';
    dbmReadWrite: Result := 'readwrite';
  else            Result := 'readonly';
  end;
end;

function RedactConnString(const Cfg: TDBConn): string;
var Pw: string;
begin
  if Cfg.Password <> '' then Pw := '***' else Pw := '';
  Result := Format('driver=%s; database=%s; server=%s; port=%d; user=%s; password=%s',
    [Cfg.Driver, Cfg.Database, Cfg.Server, Cfg.Port, Cfg.User, Pw]);
end;

{ ------------------------------------------------------------------ }
{ Backend                                                            }
{ ------------------------------------------------------------------ }

{ Map the canonical driver id to the backend's connector/driver name. Phase 1
  wires SQLite on both; the rest are recognised so config validates, but the
  matching connector/driver unit must be linked (Phase 2) before Open succeeds. }
{$IFDEF FPC}
function FPCConnectorType(const Driver: string): string;
var D: string;
begin
  D := LowerCase(Trim(Driver));
  if (D = 'sqlite') or (D = 'sqlite3') then Result := 'SQLite3'
  else if (D = 'postgres') or (D = 'postgresql') or (D = 'pg') then Result := 'PostgreSQL'
  else if (D = 'mysql') or (D = 'mysql5') or (D = 'mariadb') then Result := 'MySQL 5.7'
  else if (D = 'mysql8') then Result := 'MySQL 8.0'
  else if (D = 'firebird') or (D = 'interbase') then Result := 'Firebird'
  else if (D = 'mssql') or (D = 'sqlserver') then Result := 'MSSQLServer'
  else if D = 'oracle' then Result := 'Oracle'
  else if D = 'odbc' then Result := 'ODBC'
  else Result := Driver;   { pass through -- let sqldb reject unknowns }
end;
{$ELSE}
function FireDACDriverName(const Driver: string): string;
var D: string;
begin
  D := LowerCase(Trim(Driver));
  if (D = 'sqlite') or (D = 'sqlite3') then Result := 'SQLite'
  else if (D = 'postgres') or (D = 'postgresql') or (D = 'pg') then Result := 'PG'
  else if (D = 'mysql') or (D = 'mysql5') or (D = 'mysql8') or (D = 'mariadb') then Result := 'MySQL'
  else if (D = 'firebird') then Result := 'FB'
  else if (D = 'interbase') then Result := 'IB'
  else if (D = 'mssql') or (D = 'sqlserver') then Result := 'MSSQL'
  else if D = 'oracle' then Result := 'Ora'
  else if D = 'odbc' then Result := 'ODBC'
  else Result := Driver;
end;
{$ENDIF}

type
  TDBConnectionImpl = class(TInterfacedObject, IDBConnection)
  private
    {$IFDEF FPC}
    FConn: TSQLConnector;
    FTx:   TSQLTransaction;
    {$ELSE}
    FConn: TFDConnection;
    {$ENDIF}
    FOpen: Boolean;
    FDriver: string;
    {$IFDEF FPC}
    function NewQuery: TSQLQuery;
    {$ELSE}
    function NewQuery: TFDQuery;
    {$ENDIF}
    procedure BindParams(Q: TDataSet; const ParamsJSON: string);
    procedure FieldToJSON(F: TField; Obj: TJsonObject);
  public
    destructor Destroy; override;
    function  Open(const Cfg: TDBConn; out Err: string): Boolean;
    procedure Close;
    function  IsOpen: Boolean;
    function  Query(const SQL, ParamsJSON: string; MaxRows: Integer;
                    out ResultJSON: string; out RowCount: Integer;
                    out Truncated: Boolean; out Err: string): Boolean;
    function  Execute(const SQL, ParamsJSON: string; out RowsAffected: Integer;
                      out Err: string): Boolean;
    function  ListTables(out ResultJSON, Err: string): Boolean;
    function  DescribeTable(const TableName: string; out ResultJSON, Err: string): Boolean;
  end;

function NewDBConnection: IDBConnection;
begin
  Result := TDBConnectionImpl.Create;
end;

destructor TDBConnectionImpl.Destroy;
begin
  Close;
  inherited Destroy;
end;

function TDBConnectionImpl.IsOpen: Boolean;
begin
  Result := FOpen;
end;

{$IFDEF FPC}
function TDBConnectionImpl.NewQuery: TSQLQuery;
begin
  Result := TSQLQuery.Create(nil);
  Result.DataBase    := FConn;
  Result.Transaction := FTx;
end;
{$ELSE}
function TDBConnectionImpl.NewQuery: TFDQuery;
begin
  Result := TFDQuery.Create(nil);
  Result.Connection := FConn;
end;
{$ENDIF}

procedure TDBConnectionImpl.BindParams(Q: TDataSet; const ParamsJSON: string);
{ Bind :name placeholders from a flat name->value object, honouring each JSON
  value's type (number/bool/null/string) so an integer key binds as an integer
  rather than text -- SQLite rejects a string bound into an INTEGER PRIMARY KEY.
  A param present in the object but absent from the SQL is ignored. The security
  property is that values are *bound*, never concatenated. }
var
  Wrap: TJsonObject;
  {$IFDEF FPC}
  Obj: fpjson.TJSONObject;
  D: fpjson.TJSONData;
  Prm: TParams;
  i: Integer;
  Name: string;
  procedure BindOne(const N: string; V: fpjson.TJSONData);
  var P: TParam;
  begin
    P := Prm.FindParam(N);
    if P = nil then Exit;
    case V.JSONType of
      jtNumber:
        if fpjson.TJSONNumber(V).NumberType = ntFloat then P.AsFloat := V.AsFloat
        else P.AsLargeInt := V.AsInt64;
      jtBoolean: P.AsBoolean := V.AsBoolean;
      jtNull:    P.Clear;
    else         P.AsString := V.AsString;
    end;
  end;
  {$ELSE}
  Obj: System.JSON.TJSONObject;
  Pair: System.JSON.TJSONPair;
  Prm: TFDParams;
  i: Integer;
  Name, NumStr: string;
  P: TFDParam;
  {$ENDIF}
begin
  if Trim(ParamsJSON) = '' then Exit;
  try Wrap := TJsonObject.Parse(ParamsJSON); except Wrap := nil; end;
  if Wrap = nil then Exit;
  try
    {$IFDEF FPC}
    Obj := fpjson.TJSONObject(Wrap.Backing);
    Prm := TSQLQuery(Q).Params;
    for i := 0 to Obj.Count - 1 do
    begin
      Name := Obj.Names[i];
      D := Obj.Items[i];
      BindOne(Name, D);
    end;
    {$ELSE}
    Obj := System.JSON.TJSONObject(Wrap.Backing);
    Prm := TFDQuery(Q).Params;
    for i := 0 to Obj.Count - 1 do
    begin
      Pair := Obj.Pairs[i];
      Name := Pair.JsonString.Value;
      P := Prm.FindParam(Name);
      if P = nil then Continue;
      if Pair.JsonValue is TJSONNumber then
      begin
        NumStr := TJSONNumber(Pair.JsonValue).Value;
        if (Pos('.', NumStr) > 0) or (Pos('e', LowerCase(NumStr)) > 0) then
          P.AsFloat := TJSONNumber(Pair.JsonValue).AsDouble
        else
          P.AsLargeInt := TJSONNumber(Pair.JsonValue).AsInt64;
      end
      else if Pair.JsonValue is TJSONBool then
        P.AsBoolean := TJSONBool(Pair.JsonValue).AsBoolean
      else if Pair.JsonValue is TJSONNull then
        P.Clear
      else
        P.AsString := Pair.JsonValue.Value;
    end;
    {$ENDIF}
  finally
    Wrap.Free;
  end;
end;

procedure TDBConnectionImpl.FieldToJSON(F: TField; Obj: TJsonObject);
var S: string;
begin
  if F.IsNull then
  begin
    Obj.PutRaw(F.FieldName, 'null');
    Exit;
  end;
  case F.DataType of
    ftBoolean:
      Obj.PutBool(F.FieldName, F.AsBoolean);
    ftSmallint, ftInteger, ftWord, ftAutoInc, ftLargeint:
      Obj.PutInt(F.FieldName, F.AsLargeInt);
    ftFloat, ftCurrency, ftBCD, ftFMTBcd:
      Obj.PutFloat(F.FieldName, F.AsFloat);
  else
    begin
      S := F.AsString;
      if Length(S) > DB_CELL_CAP then
        S := Copy(S, 1, DB_CELL_CAP) + '...[truncated]';
      Obj.PutStr(F.FieldName, S);
    end;
  end;
end;

function TDBConnectionImpl.Open(const Cfg: TDBConn; out Err: string): Boolean;
begin
  Result := False;
  Err := '';
  if FOpen then Exit(True);
  FDriver := Cfg.Driver;
  try
    {$IFDEF FPC}
    FConn := TSQLConnector.Create(nil);
    FTx   := TSQLTransaction.Create(nil);
    FConn.ConnectorType := FPCConnectorType(Cfg.Driver);
    FConn.DatabaseName  := Cfg.Database;
    FConn.HostName      := Cfg.Server;
    FConn.UserName      := Cfg.User;
    FConn.Password      := Cfg.Password;
    FConn.Transaction   := FTx;
    FTx.Database        := FConn;
    if Cfg.ExtraParams <> '' then
      FConn.Params.Add(Cfg.ExtraParams);
    FConn.Open;
    FTx.StartTransaction;
    {$ELSE}
    FConn := TFDConnection.Create(nil);
    FConn.DriverName := FireDACDriverName(Cfg.Driver);
    FConn.Params.Values['Database'] := Cfg.Database;
    if Cfg.Server <> '' then FConn.Params.Values['Server'] := Cfg.Server;
    if Cfg.Port   <> 0  then FConn.Params.Values['Port']   := IntToStr(Cfg.Port);
    if Cfg.User   <> '' then FConn.Params.Values['User_Name'] := Cfg.User;
    if Cfg.Password <> '' then FConn.Params.Values['Password'] := Cfg.Password;
    FConn.LoginPrompt := False;
    FConn.Connected := True;
    {$ENDIF}
    FOpen := True;
    Result := True;
    LogDebug('db: opened connection "%s" (%s)', [Cfg.Name, Cfg.Driver]);
  except
    on E: Exception do
    begin
      Err := 'open failed: ' + E.Message;
      {$IFDEF FPC}
      FreeAndNil(FTx);
      {$ENDIF}
      FreeAndNil(FConn);
      FOpen := False;
    end;
  end;
end;

procedure TDBConnectionImpl.Close;
begin
  if not FOpen then Exit;
  try
    {$IFDEF FPC}
    if (FTx <> nil) and FTx.Active then FTx.Rollback;   { drop any uncommitted read tx }
    if (FConn <> nil) and FConn.Connected then FConn.Close;
    FreeAndNil(FTx);
    {$ELSE}
    if (FConn <> nil) and FConn.Connected then FConn.Connected := False;
    {$ENDIF}
    FreeAndNil(FConn);
  except
    on E: Exception do LogWarn('db: close error: %s', [E.Message]);
  end;
  FOpen := False;
end;

function TDBConnectionImpl.Query(const SQL, ParamsJSON: string; MaxRows: Integer;
  out ResultJSON: string; out RowCount: Integer; out Truncated: Boolean;
  out Err: string): Boolean;
var
  Q: {$IFDEF FPC}TSQLQuery{$ELSE}TFDQuery{$ENDIF};
  Arr: TJsonArray;
  Row: TJsonObject;
  i: Integer;
begin
  Result := False;
  Err := ''; ResultJSON := '[]'; RowCount := 0; Truncated := False;
  if not FOpen then begin Err := 'not connected'; Exit; end;
  if MaxRows <= 0 then MaxRows := DB_DEFAULT_MAXROWS;
  Q := NewQuery;
  Arr := TJsonArray.Create;
  try
    try
      Q.SQL.Text := SQL;
      BindParams(Q, ParamsJSON);
      Q.Open;
      while not Q.EOF do
      begin
        if RowCount >= MaxRows then begin Truncated := True; Break; end;
        Row := TJsonObject.Create;
        for i := 0 to Q.FieldCount - 1 do
          FieldToJSON(Q.Fields[i], Row);
        Arr.AddObject(Row);
        Inc(RowCount);
        Q.Next;
      end;
      ResultJSON := Arr.ToJSON;
      Result := True;
    except
      on E: Exception do Err := E.Message;
    end;
  finally
    Arr.Free;
    Q.Free;
  end;
end;

function TDBConnectionImpl.Execute(const SQL, ParamsJSON: string;
  out RowsAffected: Integer; out Err: string): Boolean;
var
  Q: {$IFDEF FPC}TSQLQuery{$ELSE}TFDQuery{$ENDIF};
begin
  Result := False;
  Err := ''; RowsAffected := -1;
  if not FOpen then begin Err := 'not connected'; Exit; end;
  Q := NewQuery;
  try
    try
      Q.SQL.Text := SQL;
      BindParams(Q, ParamsJSON);
      Q.ExecSQL;
      RowsAffected := Q.RowsAffected;
      {$IFDEF FPC}
      { commit the write, then reopen a tx so later reads/writes have one }
      if FTx.Active then FTx.Commit;
      FTx.StartTransaction;
      {$ENDIF}
      Result := True;
    except
      on E: Exception do
      begin
        Err := E.Message;
        {$IFDEF FPC}
        try if FTx.Active then FTx.Rollback; FTx.StartTransaction; except end;
        {$ENDIF}
      end;
    end;
  finally
    Q.Free;
  end;
end;

function TDBConnectionImpl.ListTables(out ResultJSON, Err: string): Boolean;
var
  L: TStringList;
  Arr: TJsonArray;
  i: Integer;
begin
  Result := False;
  Err := ''; ResultJSON := '[]';
  if not FOpen then begin Err := 'not connected'; Exit; end;
  L := TStringList.Create;
  Arr := TJsonArray.Create;
  try
    try
      {$IFDEF FPC}
      FConn.GetTableNames(L, False);
      {$ELSE}
      FConn.GetTableNames('', '', '', L);
      {$ENDIF}
      for i := 0 to L.Count - 1 do
        Arr.AddStr(L[i]);
      ResultJSON := Arr.ToJSON;
      Result := True;
    except
      on E: Exception do Err := E.Message;
    end;
  finally
    Arr.Free;
    L.Free;
  end;
end;

function TDBConnectionImpl.DescribeTable(const TableName: string;
  out ResultJSON, Err: string): Boolean;
var
  Q: {$IFDEF FPC}TSQLQuery{$ELSE}TFDQuery{$ENDIF};
  Arr: TJsonArray;
  Col: TJsonObject;
  i: Integer;
begin
  Result := False;
  Err := ''; ResultJSON := '[]';
  if not FOpen then begin Err := 'not connected'; Exit; end;
  if not IsSafeIdentifier(TableName) then
  begin Err := 'unsafe table name: ' + TableName; Exit; end;
  Q := NewQuery;
  Arr := TJsonArray.Create;
  try
    try
      { An empty result set exposes the column definitions cross-engine without
        an engine-specific catalog query. The name is identifier-validated
        above, so the interpolation is safe. }
      Q.SQL.Text := 'SELECT * FROM ' + TableName + ' WHERE 1=0';
      Q.Open;
      for i := 0 to Q.FieldDefs.Count - 1 do
      begin
        Col := TJsonObject.Create;
        Col.PutStr('name', Q.FieldDefs[i].Name);
        Col.PutStr('type', GetEnumName(TypeInfo(TFieldType), Ord(Q.FieldDefs[i].DataType)));
        Col.PutInt('size', Q.FieldDefs[i].Size);
        Col.PutBool('required', Q.FieldDefs[i].Required);
        Arr.AddObject(Col);
      end;
      ResultJSON := Arr.ToJSON;
      Result := True;
    except
      on E: Exception do Err := E.Message;
    end;
  finally
    Arr.Free;
    Q.Free;
  end;
end;

end.
