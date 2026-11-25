program updater_version_tests;
{ CompareVersions (PasClaw.Updater), which `pasclaw update` uses to decide
  whether the latest release is newer than this build. A dev build's version
  is `git describe` output (v0.1.5-36-g4f611ca); comparing it with the tag it
  sits on (v0.1.5) used to loop for ever. Run it under a time limit when
  checking that: a regression hangs rather than fails. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$APPTYPE CONSOLE}
uses
  SysUtils, PasClaw.Updater;

var
  Fails: Integer = 0;

procedure Check(const A, B: string; Want: Integer);
var
  Got: Integer;
begin
  Got := CompareVersions(A, B);
  if Got = Want then
    WriteLn(Format('  ok: %s vs %s = %d', [A, B, Got]))
  else
  begin
    WriteLn(Format('FAIL: %s vs %s = %d, want %d', [A, B, Got, Want]));
    Inc(Fails);
  end;
end;

begin
  { Plain releases. }
  Check('v0.1.5', 'v0.1.5', 0);
  Check('0.1.5', 'v0.1.5', 0);
  Check('v0.1.4', 'v0.1.5', -1);
  Check('v0.1.10', 'v0.1.9', 1);
  Check('v0.2', 'v0.2.0', 0);
  { A dev build on top of the latest tag is up to date (this one hung). }
  Check('v0.1.5-36-g4f611ca', 'v0.1.5', 1);
  Check('v0.1.5-36-g4f611ca-dirty', 'v0.1.5', 1);
  Check('v0.1.5', 'v0.1.5-36-g4f611ca', -1);
  { ...but one on an older tag is not. }
  Check('v0.1.4-3-gabc1234', 'v0.1.5', -1);
  Check('v0.1.5-2-gabc1234', 'v0.1.5-36-g4f611ca', -1);
  { A pre-release is older than its release. }
  Check('v0.2.0-rc1', 'v0.2.0', -1);
  Check('v0.2.0', 'v0.2.0-rc1', 1);
  Check('v0.2.0-rc1', 'v0.1.9', 1);
  { No version from git at all: terminates, and the release counts as newer. }
  Check('dev', 'v0.1.5', -1);
  Check('', 'v0.1.5', -1);
  if Fails > 0 then
  begin
    WriteLn(Format('updater_version_tests: %d failed', [Fails]));
    Halt(1);
  end;
  WriteLn('updater_version_tests: OK');
end.
