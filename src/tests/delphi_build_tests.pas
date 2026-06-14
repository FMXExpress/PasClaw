program delphi_build_tests;
(*
  Covers PasClaw.Tools.DelphiBuild.ParseDelphiOutput -- the tolerant,
  format-agnostic classifier that turns raw dcc / MSBuild output into
  error/warning/hint counts + a compact diagnostic list. It keys off the
  Delphi code token (E####/W####/H####/F####), which both the raw dcc
  format and MSBuild's "[dcc32 Error]" bracket form embed.

  The discovery + actual compile path is Windows/RAD-Studio only and is
  not exercised here; this pins the one piece that is cross-platform.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Tools.DelphiBuild;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEq(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + Format(' (got %d, want %d)', [Got, Want]));
end;

procedure AssertContains(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) = 0 then
    Fail(Msg + ' (missing "' + Needle + '")');
end;

procedure AssertMissing(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) > 0 then
    Fail(Msg + ' (unexpected "' + Needle + '")');
end;

procedure TestRawDccFormat;
var
  Raw, Diags: string;
  E, W, H: Integer;
begin
  Raw :=
    'Embarcadero Delphi for Win32 compiler version 36.0'  + #10 +
    'MyForm.pas(42): E2003 Undeclared identifier: ''Foo''' + #10 +
    'MyForm.pas(50): W1002 Symbol is specific to a platform' + #10 +
    'MyForm.pas(60): H2077 Value assigned to ''X'' never used' + #10 +
    'Fatal: F2613 Unit ''Baz'' not found.'                 + #10 +
    '53 lines, 0.1 seconds, 12345 bytes code';
  Diags := ParseDelphiOutput(Raw, E, W, H);
  AssertEq(E, 2, 'errors (E2003 + fatal F2613)');
  AssertEq(W, 1, 'warnings');
  AssertEq(H, 1, 'hints');
  AssertContains(Diags, 'E2003', 'error line kept');
  AssertContains(Diags, 'F2613', 'fatal line kept');
  AssertMissing(Diags, 'compiler version', 'non-diagnostic header dropped');
end;

procedure TestMsbuildBracketFormat;
var
  Raw, Diags: string;
  E, W, H: Integer;
begin
  Raw :=
    '  Building MyApp.dproj'                                       + #10 +
    '  [dcc32 Error] MyForm.pas(42): E2003 Undeclared identifier'  + #10 +
    '  [dcc32 Warning] MyForm.pas(50): W1002 platform symbol'      + #10 +
    '  [dcc32 Hint] MyForm.pas(60): H2077 never used'              + #10 +
    '  [dcc32 Fatal Error] MyForm.pas(1): F2613 Unit not found';
  Diags := ParseDelphiOutput(Raw, E, W, H);
  AssertEq(E, 2, 'errors (E + F)');
  AssertEq(W, 1, 'warnings');
  AssertEq(H, 1, 'hints');
  AssertContains(Diags, 'E2003', 'bracket error kept');
end;

procedure TestCleanBuildAndNoFalsePositives;
var
  Raw, Diags: string;
  E, W, H: Integer;
begin
  { No diagnostic codes, plus a token that must NOT be mistaken for one
    (FIRE2003: the digits are preceded by letters -> not a code). }
  Raw := 'Build succeeded.' + #10 + 'class TFIRE2003Handler done' + #10 +
         'hash ABCDEF12 written';
  Diags := ParseDelphiOutput(Raw, E, W, H);
  AssertEq(E, 0, 'no errors on clean build');
  AssertEq(W, 0, 'no warnings');
  AssertEq(H, 0, 'no hints');
  if Diags <> '' then Fail('clean build yields no diagnostics, got: ' + Diags);
end;

begin
  TestRawDccFormat;
  TestMsbuildBracketFormat;
  TestCleanBuildAndNoFalsePositives;
  WriteLn('delphi_build_tests: OK');
end.
