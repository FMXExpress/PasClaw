program memory_facts_tests;
(*
  Covers PasClaw.Memory.Facts -- Phase 2 SQLite persistence for distilled
  facts. Uses a real temp SQLite db (libsqlite3 at runtime) and exercises
  the lifecycle contract:

    - Add returns a row id; facts read back with all fields intact
    - ActiveFacts(today) excludes EXPIRED facts (expires < today)
    - Supersede hides a fact from ActiveFacts but keeps it in AllFacts
    - Delete removes it entirely
    - Count(false) ignores superseded; Count(true) includes them
    - Facts persist across Close/Open (durable)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts;

var
  GTmpDir: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

function MkFact(const Txt, Kind, Scope, Expires: string; Conf: Double): TFact;
begin
  Result.Text          := Txt;
  Result.Kind          := Kind;
  Result.Scope         := Scope;
  Result.Confidence    := Conf;
  Result.Expires       := Expires;
  Result.SourceSession := 'sess-x';
end;

const
  TODAY = '2026-06-26';

procedure RunTests;
var
  DbPath: string;
  Store: IFactStore;
  IdNoExp, IdFuture, IdPast, IdSup: Int64;
  Active, All: TStoredFactArray;
begin
  DbPath := JoinPath(GTmpDir, 'facts.db');

  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'open store');

  IdNoExp  := Store.Add(MkFact('Prefers Delphi', 'static', 'user', '', 0.9), 1000);
  IdFuture := Store.Add(MkFact('Sprint ends soon', 'dynamic', 'project', '2026-12-31', 0.7), 1001);
  IdPast   := Store.Add(MkFact('Exam yesterday', 'dynamic', 'session', '2026-06-01', 0.6), 1002);
  IdSup    := Store.Add(MkFact('Old preference', 'static', 'user', '', 0.5), 1003);

  AssertTrue(IdNoExp > 0, 'add returns id');
  AssertTrue((IdFuture <> IdNoExp) and (IdPast <> IdFuture), 'ids distinct');

  { Active as of today: no-expiry + future-expiry + the soon-to-be-superseded
    one = 3; the past-expiry one is filtered out. }
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 3, 'active excludes expired');
  { Newest first -> IdSup (created_at 1003) is row 0. }
  AssertEqStr(Active[0].Text, 'Old preference', 'newest first ordering');
  AssertEqStr(Active[0].Kind, 'static', 'kind round-trips');
  AssertEqStr(Active[0].Scope, 'user', 'scope round-trips');
  AssertTrue(Abs(Active[0].Confidence - 0.5) < 0.001, 'confidence round-trips');

  { Supersede hides from Active but keeps in All. }
  AssertTrue(Store.Supersede(IdSup), 'supersede returns true');
  AssertTrue(not Store.Supersede(IdSup), 'second supersede is a no-op');
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 2, 'superseded fact drops out of active');

  All := Store.AllFacts;
  AssertEqInt(Length(All), 4, 'AllFacts keeps superseded + expired');

  { CountActive must match ActiveFacts exactly: NoExp + Future = 2 (the
    past-expiry fact is NOT counted, and the superseded one is gone). The
    old Count(False) wrongly reported 3 by ignoring expiry. }
  AssertEqInt(Store.CountActive(TODAY), 2, 'active count excludes superseded AND expired');
  AssertEqInt(Store.CountActive(TODAY), Length(Store.ActiveFacts(TODAY)),
              'CountActive agrees with ActiveFacts');
  AssertEqInt(Store.CountAll, 4, 'CountAll includes superseded + expired');

  { Delete the expired one entirely. }
  AssertTrue(Store.Delete(IdPast), 'delete returns true');
  AssertEqInt(Store.CountAll, 3, 'count drops after delete');

  Store.Close;

  { Reopen: durability. }
  Store := NewFactStore;
  AssertTrue(Store.Open(DbPath), 'reopen store');
  AssertEqInt(Store.CountAll, 3, 'facts persisted across reopen');
  Active := Store.ActiveFacts(TODAY);
  AssertEqInt(Length(Active), 2, 'active count stable after reopen');
  Store.Close;
end;

begin
  GTmpDir := JoinPath(GetTempDir, 'pasclaw-facts-test-' + IntToStr(Random(1 shl 30)));
  EnsureDir(GTmpDir);
  try
    RunTests;
    WriteLn('  ok: add / read-back / active-excludes-expired');
    WriteLn('  ok: supersede / delete / counts');
    WriteLn('  ok: durability across reopen');
    WriteLn('PASS');
  finally
    {$IFDEF UNIX}
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + GTmpDir + '"']);
    {$ENDIF}
  end;
end.
