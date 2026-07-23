program db_tools_tests;
(*
  Phase 1 of the database tools: the engine-agnostic seam (PasClaw.DB) + the
  agent tools (PasClaw.Tools.DB), exercised against a throwaway SQLite file.

  Covers the TMS-style safety model without a network: SQL classification after
  comment/literal stripping, statement-stacking rejection, per-connection mode
  gating (db_execute refused on readonly; DDL needs full), :name param binding,
  the row cap + truncated flag, identifier validation for describe, and password
  redaction.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Tools.Registry,
  PasClaw.DB,
  PasClaw.Tools.DB;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

{ The JSON serializer pretty-prints (spaces around ':'), so match against a
  space-stripped copy to keep assertions independent of formatting. }
function NoSp(const S: string): string;
var i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] <> ' ' then Result := Result + S[i];
end;

function HasSub(const Haystack, Needle: string): Boolean;
begin
  Result := Pos(Needle, NoSp(Haystack)) > 0;
end;

function DbPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'pasclaw_dbtools_test.db';
end;

function MkConn(const Name: string; Mode: TDBMode): TDBConn;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Name     := Name;
  Result.Driver   := 'sqlite';
  Result.Database := DbPath;
  Result.Mode     := Mode;
  Result.MaxRows  := 1000;
end;

{ ---- pure helpers: classification / stacking / redaction / identifiers ---- }
procedure TestClassify;
var w: string;
begin
  Check(ClassifySQL('SELECT * FROM t', w) = skReadOnly, 'classify: SELECT');
  Check(ClassifySQL('  with x as (select 1) select * from x', w) = skReadOnly, 'classify: WITH');
  Check(ClassifySQL('EXPLAIN SELECT 1', w) = skReadOnly, 'classify: EXPLAIN');
  Check(ClassifySQL('insert into t values (1)', w) = skDML, 'classify: INSERT');
  Check(ClassifySQL('UPDATE t SET a=1', w) = skDML, 'classify: UPDATE');
  Check(ClassifySQL('drop table t', w) = skDDL, 'classify: DROP');
  Check(ClassifySQL('VACUUM', w) = skOther, 'classify: VACUUM -> other');
  Check(ClassifySQL('', w) = skEmpty, 'classify: empty');
  { a DELETE hidden in a comment must not mask a SELECT reading as writeable,
    and vice versa -- a comment/string must not change the leading keyword. }
  Check(ClassifySQL('/* delete from t */ SELECT 1', w) = skReadOnly, 'classify: leading block comment ignored');
  Check(ClassifySQL('SELECT ''drop table t''', w) = skReadOnly, 'classify: keyword inside a string literal');
  Check(ClassifySQL('PRAGMA table_info(t)', w) = skReadOnly, 'classify: PRAGMA read');
  Check(ClassifySQL('PRAGMA journal_mode = WAL', w) = skOther, 'classify: PRAGMA write -> other');
  { writable CTEs: WITH is read-only ONLY when its main statement reads. }
  Check(ClassifySQL('WITH c AS (SELECT 1) SELECT * FROM c', w) = skReadOnly, 'classify: WITH..SELECT is read');
  Check(ClassifySQL('WITH c AS (SELECT 1) DELETE FROM t RETURNING *', w) = skDML, 'classify: WITH..DELETE is write');
  Check(ClassifySQL('with recursive c(x) as (select 1) insert into t select * from c', w) = skDML,
    'classify: WITH RECURSIVE..INSERT is write');
  Check(ClassifySQL('WITH a AS (SELECT 1), b AS (SELECT 2) UPDATE t SET x=1', w) = skDML,
    'classify: multi-CTE ..UPDATE is write');
  Check(ClassifySQL('WITH c AS (SELECT 1) UPDATE t SET x=1', w) <> skReadOnly, 'classify: WITH..UPDATE not read');
  { data-modifying CTE bodies: the mutation is INSIDE the CTE, main verb is SELECT }
  Check(ClassifySQL('WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d', w) = skDML,
    'classify: data-modifying CTE (DELETE body) is a write');
  Check(ClassifySQL('WITH d AS (INSERT INTO t VALUES (1) RETURNING *) SELECT * FROM d', w) = skDML,
    'classify: data-modifying CTE (INSERT body) is a write');
  Check(ClassifySQL('WITH a AS (SELECT 1), b AS (UPDATE t SET x=1 RETURNING *) SELECT * FROM b', w) = skDML,
    'classify: data-modifying CTE among reads is a write');
  Check(ClassifySQL('WITH d AS (SELECT 1) SELECT * FROM d', w) = skReadOnly,
    'classify: all-read CTE stays read');
  Check(ClassifySQL('EXPLAIN ANALYZE WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d', w) = skDML,
    'classify: EXPLAIN ANALYZE + data-modifying CTE is a write');
  { EXPLAIN plans (read); EXPLAIN ANALYZE executes -> classify by inner stmt. }
  Check(ClassifySQL('EXPLAIN SELECT 1', w) = skReadOnly, 'classify: EXPLAIN plan is read');
  Check(ClassifySQL('EXPLAIN ANALYZE DELETE FROM t', w) = skDML, 'classify: EXPLAIN ANALYZE DELETE is write');
  Check(ClassifySQL('EXPLAIN (ANALYZE, VERBOSE) UPDATE t SET x=1', w) = skDML,
    'classify: EXPLAIN (ANALYZE) UPDATE is write');
end;

procedure TestStacking;
begin
  Check(not SQLHasMultipleStatements('SELECT 1'), 'stacking: single');
  Check(not SQLHasMultipleStatements('SELECT 1;'), 'stacking: single trailing ;');
  Check(SQLHasMultipleStatements('SELECT 1; DROP TABLE t'), 'stacking: two statements');
  Check(not SQLHasMultipleStatements('SELECT '';'' AS x'), 'stacking: ; inside a string is not stacking');
end;

procedure TestRedactAndIdent;
var C: TDBConn;
begin
  C := MkConn('main', dbmReadOnly);
  C.Password := 'hunter2';
  Check(Pos('hunter2', RedactConnString(C)) = 0, 'redact: password not present');
  Check(Pos('***', RedactConnString(C)) > 0, 'redact: masked marker present');

  Check(IsSafeIdentifier('users'), 'ident: plain');
  Check(IsSafeIdentifier('public.users'), 'ident: schema.table');
  Check(not IsSafeIdentifier('users; drop table x'), 'ident: rejects injection');
  Check(not IsSafeIdentifier('a.b.c'), 'ident: rejects double dot');
  Check(not IsSafeIdentifier(''), 'ident: rejects empty');
end;

{ ---- live SQLite via the tool handlers ---- }
procedure TestToolsLive;
var
  Reg: TToolRegistry;
  Err, Res, CountBefore: string;
  RW: TDBConn;
begin
  { fresh db }
  if FileExists(DbPath) then DeleteFile(DbPath);

  Reg := TToolRegistry.Create;
  try
    RegisterDBTools(Reg);

    { full-mode connection so we can create + seed a table }
    RW := MkConn('main', dbmFull);
    SetDBConfig([RW]);
    Check(DBConnectionCount = 1, 'config: one connection registered');

    Res := Reg.RunTool('db_execute',
      '{"sql":"CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT)"}', Err);
    Check(Err = '', 'execute: create table (' + Err + ')');

    Res := Reg.RunTool('db_execute',
      '{"sql":"INSERT INTO t (id,name) VALUES (:id,:n)","params":{"id":1,"n":"alice"}}', Err);
    Check(Err = '', 'execute: parameterized insert (' + Err + ')');
    Check(HasSub(Res, '"rows_affected":1'), 'execute: 1 row affected (got ' + Res + ')');

    Reg.RunTool('db_execute',
      '{"sql":"INSERT INTO t (id,name) VALUES (2,''bob'')"}', Err);
    Check(Err = '', 'execute: literal insert (' + Err + ')');

    { db_query returns rows; param binding filters correctly }
    Res := Reg.RunTool('db_query',
      '{"sql":"SELECT name FROM t WHERE id = :id","params":{"id":1}}', Err);
    Check(Err = '', 'query: ran (' + Err + ')');
    Check(Pos('alice', Res) > 0, 'query: param-bound row returned (got ' + Res + ')');
    Check(Pos('bob', Res) = 0, 'query: param filtered out the other row');
    Check(HasSub(Res, '"row_count":1'), 'query: row_count=1');

    { db_query refuses a write }
    Res := Reg.RunTool('db_query', '{"sql":"DELETE FROM t"}', Err);
    Check(Err <> '', 'query: refuses DELETE');
    Check(Pos('db_execute', Err) > 0, 'query: refusal points at db_execute');

    { db_query refuses stacked statements }
    Res := Reg.RunTool('db_query', '{"sql":"SELECT 1; DROP TABLE t"}', Err);
    Check(Err <> '', 'query: refuses statement stacking');

    { db_query refuses a writable CTE (the readonly-bypass this hardening fixes) }
    Res := Reg.RunTool('db_query', '{"sql":"WITH c AS (SELECT 1) DELETE FROM t"}', Err);
    Check(Err <> '', 'query: refuses writable CTE (WITH..DELETE)');
    { and a data-modifying CTE whose MAIN verb is SELECT is refused too }
    Res := Reg.RunTool('db_query', '{"sql":"WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d"}', Err);
    Check(Err <> '', 'query: refuses data-modifying CTE (DELETE body, SELECT main)');
    { rows must still be there -- neither refused statement ran }
    Res := Reg.RunTool('db_query', '{"sql":"SELECT COUNT(*) AS n FROM t"}', Err);
    Check(HasSub(Res, '"n":2'), 'query: refused CTEs did not delete rows (got ' + Res + ')');

    { db_tables + db_describe }
    Res := Reg.RunTool('db_tables', '{}', Err);
    Check((Err = '') and HasSub(Res, '"t"'), 'tables: lists t (got ' + Res + ')');

    Res := Reg.RunTool('db_describe', '{"table":"t"}', Err);
    Check((Err = '') and HasSub(Res, '"name":"id"') and HasSub(Res, '"name":"name"'),
      'describe: lists columns (got ' + Res + ')');

    { db_describe rejects an unsafe identifier before any SQL runs }
    Res := Reg.RunTool('db_describe', '{"table":"t; drop table t"}', Err);
    Check(Err <> '', 'describe: rejects unsafe table name');

    { db_info redacts }
    Res := Reg.RunTool('db_info', '{}', Err);
    Check((Err = '') and HasSub(Res, '"mode":"full"'), 'info: reports mode (got ' + Res + ')');

    { row cap + truncated flag: seed 5, cap at 2 }
    Reg.RunTool('db_execute', '{"sql":"INSERT INTO t (id,name) VALUES (3,''c'')"}', Err);
    Reg.RunTool('db_execute', '{"sql":"INSERT INTO t (id,name) VALUES (4,''d'')"}', Err);
    Reg.RunTool('db_execute', '{"sql":"INSERT INTO t (id,name) VALUES (5,''e'')"}', Err);
    Res := Reg.RunTool('db_query', '{"sql":"SELECT * FROM t","max_rows":2}', Err);
    Check(HasSub(Res, '"row_count":2'), 'query: max_rows caps count (got ' + Res + ')');
    Check(HasSub(Res, '"truncated":true'), 'query: truncated flag set');

    { ---- capability gating: a readonly connection refuses writes ---- }
    SetDBConfig([MkConn('ro', dbmReadOnly)]);
    Res := Reg.RunTool('db_execute', '{"sql":"DELETE FROM t"}', Err);
    Check(Err <> '', 'gating: readonly refuses db_execute');
    Check(Pos('readonly', Err) > 0, 'gating: refusal names readonly');

    { readwrite allows DML but not DDL }
    SetDBConfig([MkConn('rw', dbmReadWrite)]);
    Res := Reg.RunTool('db_execute', '{"sql":"UPDATE t SET name=''x'' WHERE id=1"}', Err);
    Check(Err = '', 'gating: readwrite allows UPDATE (' + Err + ')');
    Res := Reg.RunTool('db_execute', '{"sql":"DROP TABLE t"}', Err);
    Check(Err <> '', 'gating: readwrite refuses DROP (needs full)');
    Check(Pos('full', Err) > 0, 'gating: DDL refusal names full mode');

    { ---- Phase 4 DBA tools ---- }
    SetDBConfig([RW]);   { back to the seeded full-mode db }

    { db_schema: lists the table + its columns + a row count }
    Res := Reg.RunTool('db_schema', '{}', Err);
    Check(Err = '', 'schema: ran (' + Err + ')');
    Check(HasSub(Res, '"name":"t"'), 'schema: lists table t (got ' + Res + ')');
    Check(HasSub(Res, '"name":"id"') and HasSub(Res, '"name":"name"'), 'schema: lists columns');
    Check(Pos('row_count', Res) > 0, 'schema: includes row_count');

    { db_explain: a WHERE on an unindexed column is a full SCAN -> flagged }
    Res := Reg.RunTool('db_explain', '{"sql":"SELECT * FROM t WHERE name = ''alice''"}', Err);
    Check(Err = '', 'explain: ran (' + Err + ')');
    Check(Pos('"plan"', Res) > 0, 'explain: returns a plan');
    Check(HasSub(Res, '"full_scans":["t"]') or (Pos('"t"', Res) > 0), 'explain: flags the full scan on t (got ' + Res + ')');
    Check(Pos('hint', Res) > 0, 'explain: gives an index hint');

    { after indexing name, the same query no longer full-scans }
    Reg.RunTool('db_execute', '{"sql":"CREATE INDEX idx_t_name ON t(name)"}', Err);
    Check(Err = '', 'explain: create index (' + Err + ')');
    Res := Reg.RunTool('db_explain', '{"sql":"SELECT * FROM t WHERE name = ''alice''"}', Err);
    Check(Pos('"full_scans":[]', StringReplace(Res, ' ', '', [rfReplaceAll])) > 0,
          'explain: indexed query no longer flagged as full scan (got ' + Res + ')');

    { db_explain plans without executing -- an explained DELETE must not delete }
    CountBefore := Reg.RunTool('db_query', '{"sql":"SELECT COUNT(*) AS n FROM t"}', Err);
    Reg.RunTool('db_explain', '{"sql":"DELETE FROM t WHERE id=1"}', Err);
    Res := Reg.RunTool('db_query', '{"sql":"SELECT COUNT(*) AS n FROM t"}', Err);
    Check(Res = CountBefore, 'explain: planning a DELETE did not run it (before=' +
          CountBefore + ' after=' + Res + ')');

    { no connection configured => clear guidance, not a crash }
    SetDBConfig([]);
    Res := Reg.RunTool('db_query', '{"sql":"SELECT 1"}', Err);
    Check(Pos('no database configured', Err) > 0, 'unconfigured: clear message');
  finally
    Reg.Free;
    if FileExists(DbPath) then DeleteFile(DbPath);
  end;
end;

{ ---- config parsing (the Phase-2 wiring seam) ---- }
procedure TestConfigFromJSON;
var n: Integer;
begin
  n := SetDBConfigFromJSON(
    '[{"name":"main","driver":"sqlite","database":"/tmp/a.db","mode":"readwrite","max_rows":250},' +
    ' {"name":"reports","driver":"postgres","database":"rpt","mode":"readonly"}]');
  Check(n = 2, 'config-json: parsed 2 connections (got ' + IntToStr(n) + ')');
  Check(DBConnectionCount = 2, 'config-json: installed 2');
  Check(SetDBConfigFromJSON('') = 0, 'config-json: empty clears');
  Check(DBConnectionCount = 0, 'config-json: cleared');
  Check(SetDBConfigFromJSON('not json') = 0, 'config-json: garbage is safe');
end;

begin
  TestClassify;
  TestStacking;
  TestRedactAndIdent;
  TestConfigFromJSON;
  TestToolsLive;

  if Failures = 0 then WriteLn('db_tools_tests: OK')
  else begin WriteLn('db_tools_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
