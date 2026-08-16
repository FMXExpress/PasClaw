program shell_denylist_bypass_tests;
(*
  Bypasses of the shell_exec denylist, found by fuzzing ShellAllowed with
  the spellings an attacker (or a prompt-injected model) reaches for when
  a token denylist is the only thing in the way. Every "must be blocked"
  case below was verified ALLOWED before the fix:

    /bin/rm -rf x                 exact token compare, so the most
    /usr/bin/sudo whoami          natural spelling of the command missed
    r\m -rf x                     sh removes backslashes during word
    \rm -rf x                     expansion; the tokenizer did not
    C:\Windows\System32\rm.exe    Windows path + .exe suffix

  The must-NOT-block half is not decoration. The first attempt at this
  fix stripped backslashes to catch r\m, which destroyed the separators
  in Windows paths and silently disabled the basename check for them --
  every attack case still read "blocked" and the fix looked complete.
  Only asserting that ordinary commands still run distinguishes a
  working guard from a broken one.

  KNOWN LIMIT, deliberately asserted as ALLOWED so the gap stays
  visible rather than being quietly forgotten: variable indirection
  (`a=rm; $a -rf x`) still passes. Catching it needs a shell parser and
  variable tracking, not a bigger denylist. This is a guardrail against
  model mistakes and casual injection, not a security boundary -- the
  sandbox backend is that.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Tools.Sandbox;

var
  Failures: Integer = 0;

procedure Check(const Cmd: string; WantAllowed: Boolean; const What: string);
var
  Why: string;
  Got: Boolean;
begin
  Got := ShellAllowed(Cmd, Why);
  if Got <> WantAllowed then
  begin
    WriteLn(Format('FAIL: %s -- %s (allowed=%s, wanted %s)',
                   [Cmd, What, BoolToStr(Got, True), BoolToStr(WantAllowed, True)]));
    Inc(Failures);
  end;
end;

begin
  { Baseline -- these always worked. }
  Check('rm -rf /tmp/x',       False, 'plain rm');
  Check('sudo whoami',         False, 'plain sudo');
  Check('r''m'' -rf /tmp/x',   False, 'quote-split (GuardFall Class A)');

  { Path spellings. }
  Check('/bin/rm -rf /tmp/x',       False, 'absolute path to rm');
  Check('/usr/bin/sudo whoami',     False, 'absolute path to sudo');
  Check('../../bin/rm -rf /tmp/x',  False, 'relative path to rm');

  { Backslash removal, which sh performs during word expansion. }
  Check('r\m -rf /tmp/x',  False, 'backslash inside the word');
  Check('\rm -rf /tmp/x',  False, 'leading backslash');

  { Windows spellings: separator + executable suffix. }
  Check('C:\Windows\System32\rm.exe x',        False, 'windows path + .exe');
  Check('C:\Windows\System32\reg.exe add HK',  False, 'reg.exe (was missing from the array)');

  { Must NOT block -- ordinary developer commands. }
  Check('make test',                   True, 'make');
  Check('git commit -m "fix"',         True, 'git');
  Check('./build/pasclaw doctor',      True, 'relative binary');
  Check('cat /etc/hosts',              True, 'reading a config file');
  Check('grep -rn foo src/',           True, 'grep with a trailing slash');
  Check('fpc -MDelphi src/tests/x.pas', True, 'compiler with path args');
  Check('ls -la /usr/local/bin',       True, 'listing a bin directory');
  Check('node scripts/build.js',       True, 'script with a path');
  Check('dcc32 C:\proj\kill.pas',      True, 'windows path whose basename is not a token');

  { Documented limit -- asserted so it cannot silently change. }
  Check('a=rm; $a -rf /tmp/x', True,
        'variable indirection is NOT caught (needs a shell parser)');

  if Failures > 0 then
  begin
    WriteLn(Format('shell_denylist_bypass_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('shell_denylist_bypass_tests: OK');
end.
