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
  SysUtils, Classes,
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

procedure TestErrorsLeadAndSurviveCap;
{ A real build can emit hundreds of hints/warnings -- more than the 200-line
  keep cap. The model must still SEE the actual errors, and they must lead the
  output, so they can't be silently dropped behind a hint flood. }
var
  Raw, Diags: string;
  E, W, H, i: Integer;
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    { 300 hints (over the 200 cap), then the one error that matters, last. }
    for i := 1 to 300 do
      Sb.Append(Format('Unit.pas(%d): H2077 Value assigned to ''X'' never used'#10, [i]));
    Sb.Append('Broken.pas(7): E2003 Undeclared identifier: ''DoThing''');
    Raw := Sb.ToString;
  finally
    Sb.Free;
  end;
  Diags := ParseDelphiOutput(Raw, E, W, H);
  AssertEq(E, 1, 'one error counted under hint flood');
  AssertEq(H, 300, 'all hints counted');
  AssertContains(Diags, 'E2003', 'error survives the keep cap');
  { The error must come first -- before any hint text in the kept output. }
  if Pos('E2003', Diags) > Pos('H2077', Diags) then
    Fail('error must lead the diagnostics, not trail the hints');
end;

procedure TestDprojTokenExtraction;
{ dcc-direct pulls the project's own search paths + namespaces from the
  .dproj so multi-dir projects compile without hand-rolled -U flags. Verify:
  ';'-split, skip $() macros, dedupe across groups, AND honour PropertyGroup
  conditions -- a Win32 build must NOT pull a Win64-only group's dirs. }
const
  Dproj =
    '<Project>' +
    { Base/unconditional group -- applies to every build. }
    '<PropertyGroup>' +
    '<DCC_UnitSearchPath>src;src\llama_cpp;src\llama_cpp\Api;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>' +
    '<DCC_Namespace>System;FMX;$(DCC_Namespace)</DCC_Namespace>' +
    '</PropertyGroup>' +
    { Win32 group -- applies to a Win32 build. }
    '<PropertyGroup Condition="''$(Platform)''==''Win32''">' +
    '<DCC_UnitSearchPath>src\llama_cpp\CType;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>' +
    '</PropertyGroup>' +
    { Win64-only group -- must be EXCLUDED from a Win32 build. }
    '<PropertyGroup Condition="''$(Platform)''==''Win64''">' +
    '<DCC_UnitSearchPath>src\only_win64;$(DCC_UnitSearchPath)</DCC_UnitSearchPath>' +
    '</PropertyGroup>' +
    '</Project>';
var
  Dirs, Ns: TStringList;
begin
  Dirs := TStringList.Create;
  Ns := TStringList.Create;
  try
    CollectDprojTokens(Dproj, 'DCC_UnitSearchPath', 'Win32', 'Debug', Dirs);
    CollectDprojTokens(Dproj, 'DCC_Namespace', 'Win32', 'Debug', Ns);

    { Base (3) + Win32 group (1 new). Macro + the Win64 dir excluded. }
    AssertEq(Dirs.Count, 4, 'Win32 build: base + Win32 dirs only');
    if Dirs.IndexOf('src\llama_cpp\Api') < 0 then Fail('expected base dir src\llama_cpp\Api');
    if Dirs.IndexOf('src\llama_cpp\CType') < 0 then Fail('expected Win32 dir src\llama_cpp\CType');
    if Dirs.IndexOf('src\only_win64') >= 0 then Fail('Win64-only dir must be excluded from Win32 build');
    if Dirs.IndexOf('$(DCC_UnitSearchPath)') >= 0 then Fail('macro token must be skipped');

    AssertEq(Ns.Count, 2, 'namespaces (System, FMX); macro skipped');
    if Ns.IndexOf('FMX') < 0 then Fail('expected FMX namespace');

    { A Win64 build picks up the Win64 dir and drops nothing of the base. }
    Dirs.Clear;
    CollectDprojTokens(Dproj, 'DCC_UnitSearchPath', 'Win64', 'Debug', Dirs);
    if Dirs.IndexOf('src\only_win64') < 0 then Fail('Win64 build should include src\only_win64');
  finally
    Ns.Free;
    Dirs.Free;
  end;
end;

begin
  TestRawDccFormat;
  TestMsbuildBracketFormat;
  TestCleanBuildAndNoFalsePositives;
  TestErrorsLeadAndSurviveCap;
  TestDprojTokenExtraction;
  WriteLn('delphi_build_tests: OK');
end.
