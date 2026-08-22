(*
  sqlite_hint_tests - PasClaw.Utils.SqliteBackendHint.

  The "index unavailable" diagnostics used to hardcode "libsqlite3
  missing or unreadable" on every target. That is right for the FPC
  build and for Delphi Linux64, and wrong for the Delphi Windows /
  macOS / mobile build, where PasClaw.dpr links
  FireDAC.Phys.SQLiteWrapper.Stat and no sqlite3.dll exists to go
  find. SqliteBackendHint replaces that text with something true of
  the build actually running.

  SqliteOpenFailureReason then prefers what the driver actually
  reported (IMemoryIndex/IKBIndex/ISessionSearchIndex.LastError) and
  keeps the hint only as the fallback for the paths that return False
  without raising.

  What this covers: the hint is non-empty and names the right
  dependency for THIS build; the reason function prefers real driver
  text, falls back to the hint on empty/blank, and neutralises the
  bytes that would break the gateway's hand-built JSON bodies.

  What it does NOT cover:
    - The Delphi arms. This suite is compiled by FPC, so the
      {$IFNDEF FPC} branches of SqliteBackendHint never execute here;
      only their syntax is checked, and only when a Delphi build runs.
    - The static-link claim itself (that the Delphi Windows exe truly
      needs no sqlite3.dll). That rests on PasClaw.dpr's uses clause,
      not on any assertion here.
    - The wiring. That LastError is populated and reaches the ten
      call sites is exercised manually (`pasclaw kb search` against a
      blocked db path prints the driver's own text), not by this
      suite -- it tests the two pure functions only.
*)
program sqlite_hint_tests;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils;

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  ok   ', Name)
  else
  begin
    WriteLn('  FAIL ', Name);
    Inc(Failures);
  end;
end;

procedure TestNonEmpty;
var
  H: string;
begin
  H := SqliteBackendHint;
  WriteLn('  hint = ', H);
  Check('hint is non-empty', H <> '');
  Check('hint has no leading/trailing space', H = Trim(H));
end;

procedure TestJsonSafe;
(* PasClaw.Gateway.Server builds its 503 bodies by string concatenation
   rather than through the JSON writer, so an unescaped quote or
   backslash in the hint would emit a malformed body. Three call sites
   do this (kb_search, kb reindex, memory_search). *)
var
  H: string;
begin
  H := SqliteBackendHint;
  Check('no double quote', Pos('"', H) = 0);
  Check('no backslash',    Pos('\', H) = 0);
  Check('no newline',      (Pos(#10, H) = 0) and (Pos(#13, H) = 0));
end;

procedure TestNamesTheRightDependency;
(* This suite runs under FPC, whose sqldb/sqlite3conn backend resolves
   the SQLite shared library at runtime -- so the hint MUST still point
   at that library here. The regression being guarded is the opposite
   direction: someone "fixing" the message for the Delphi static build
   by dropping the dynamic-library wording everywhere. *)
var
  H: string;
begin
  {$IFDEF FPC}
    {$IFDEF MSWINDOWS}
    H := LowerCase(SqliteBackendHint);
    Check('FPC/Windows names sqlite3.dll', Pos('sqlite3.dll', H) > 0);
    {$ELSE}
    H := LowerCase(SqliteBackendHint);
    Check('FPC/unix names libsqlite3', Pos('libsqlite3', H) > 0);
    {$ENDIF}
  {$ELSE}
  WriteLn('  skip Delphi arms not exercised by the FPC test build');
  {$ENDIF}
end;

procedure TestReasonPrefersTheRealError;
(* The hint is a fallback. When the index captured what the driver
   actually said, that wins -- it is the difference between telling
   the user to install a library and telling them the path is
   unwritable. *)
begin
  Check('driver detail wins over the hint',
        SqliteOpenFailureReason('TSQLite3Connection : unable to open database file') =
        'TSQLite3Connection : unable to open database file');
  Check('empty detail falls back to the hint',
        SqliteOpenFailureReason('') = SqliteBackendHint);
  Check('whitespace-only detail falls back to the hint',
        SqliteOpenFailureReason('   '#9) = SqliteBackendHint);
  Check('detail is trimmed',
        SqliteOpenFailureReason('  file is not a database  ') =
        'file is not a database');
end;

procedure TestReasonSanitisesForJson;
(* Driver text is not under our control and three gateway handlers
   splice it straight into a hand-built JSON body. A quote or
   backslash would break out of the string literal and produce a
   malformed 503 -- so those bytes, and newlines, become spaces. *)
var
  R: string;
begin
  R := SqliteOpenFailureReason('bad "quote" and \ slash');
  Check('quotes neutralised',   Pos('"', R) = 0);
  Check('backslash neutralised', Pos('\', R) = 0);
  Check('text otherwise intact', Pos('quote', R) > 0);

  R := SqliteOpenFailureReason('line one'#13#10'line two');
  Check('CR neutralised', Pos(#13, R) = 0);
  Check('LF neutralised', Pos(#10, R) = 0);
  Check('both lines survive',
        (Pos('line one', R) > 0) and (Pos('line two', R) > 0));
end;

begin
  WriteLn('sqlite_hint_tests');
  TestNonEmpty;
  TestJsonSafe;
  TestNamesTheRightDependency;
  TestReasonPrefersTheRealError;
  TestReasonSanitisesForJson;

  if Failures = 0 then
  begin
    WriteLn('OK');
    Halt(0);
  end
  else
  begin
    WriteLn(Failures, ' failure(s)');
    Halt(1);
  end;
end.
