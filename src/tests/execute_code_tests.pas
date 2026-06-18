program execute_code_tests;
(*
  Covers PasClaw.Tools.ExecuteCode -- the execute_code tool. Three
  pieces in scope:

    - ResolveExecuteCodeLang: dispatch table from the model-facing
      `lang` arg (auto/bash/sh/powershell/pwsh/...) to the actual
      shell we'll spawn. The default-fallback path matters because
      a silently-wrong shell wastes inference rounds.

    - BuildExecuteCodeArgv: the argv shape per language. PowerShell
      needs -ExecutionPolicy Bypass -NoProfile -File or a stock
      Windows box refuses to run the script. Pin both shapes so a
      well-meaning refactor doesn't drop a required flag.

    - Tool_ExecuteCode: end-to-end run on the host shell. On a
      Linux CI box this exercises the bash path; on Windows it'd
      exercise PowerShell. We don't gate on $CI -- we just want
      the round trip (script -> spawn -> capture) to work.

  We also pin that the sandbox denylist applies to the script body,
  not just to the shell command -- otherwise execute_code would be
  a trivial workaround for the shell_exec safety floor.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.ExecuteCode;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' + Haystack + '")');
end;

procedure SetupSandbox;
var
  Cfg: TConfig;
begin
  Cfg := LoadConfig;
  try
    ConfigureSandbox(Cfg.Sandbox, '');
  finally
    Cfg.Free;
  end;
end;

procedure TestResolveLangDispatch;
{ Pin every entry in the dispatch table. `auto` resolves per host;
  bash/sh both collapse to bash (because /bin/sh on Debian is dash,
  which is missing common bashisms the model assumes); powershell
  aliases all collapse to powershell; anything else falls back to
  the host default. }
begin
  AssertEqStr(ResolveExecuteCodeLang('bash'),       'bash',
              'bash -> bash');
  AssertEqStr(ResolveExecuteCodeLang('sh'),         'bash',
              'sh -> bash (dash is missing bashisms; bash is safer default)');
  AssertEqStr(ResolveExecuteCodeLang('powershell'), 'powershell',
              'powershell -> powershell');
  AssertEqStr(ResolveExecuteCodeLang('pwsh'),       'powershell',
              'pwsh alias -> powershell');
  AssertEqStr(ResolveExecuteCodeLang('ps'),         'powershell',
              'ps alias -> powershell');
  AssertEqStr(ResolveExecuteCodeLang('BASH'),       'bash',
              'casing normalised');
  AssertEqStr(ResolveExecuteCodeLang('  bash  '),   'bash',
              'whitespace trimmed');
  { Unknown / empty falls back to the host default. We can't pin
    the exact return on a cross-platform build, but we can pin
    that it's never empty and never echoes back the bad input. }
  AssertTrue(ResolveExecuteCodeLang('') <> '',
             'empty falls back to host default, not empty string');
  AssertTrue(ResolveExecuteCodeLang('') <> '',
             'empty is non-empty (host default)');
  AssertTrue(ResolveExecuteCodeLang('nonsense') <> 'nonsense',
             'unknown lang does not echo back the bad arg');
end;

procedure TestBuildArgvBash;
var
  Argv: TStringArray;
begin
  Argv := nil;
  AssertTrue(BuildExecuteCodeArgv('bash', '/tmp/x.sh', Argv),
             'bash argv builds');
  AssertTrue(Length(Argv) = 2, 'bash argv has 2 elements');
  AssertEqStr(Argv[0], 'bash',      'argv[0] is bash');
  AssertEqStr(Argv[1], '/tmp/x.sh', 'argv[1] is the script path');
end;

procedure TestBuildArgvPowerShell;
{ PowerShell needs -NoProfile + -ExecutionPolicy Bypass + -File
  in that shape. Stock Windows refuses to run an unsigned .ps1
  without Bypass; -NoProfile keeps the operator's $PROFILE.ps1
  out of the picture so the script runs the same regardless of
  whose box it's on. A reorder here (dropping any flag) silently
  changes execution behaviour on Windows.

  argv[0] is whatever ResolvePowerShellExe returned -- either
  'pwsh' (when PowerShell 7 is installed; common on unix dev
  boxes via dotnet) or 'powershell' (the Windows 5.1 fallback).
  Both are valid; pin the set rather than the exact value because
  CI hosts differ in which they have installed. }
var
  Argv: TStringArray;
begin
  Argv := nil;
  AssertTrue(BuildExecuteCodeArgv('powershell', '/tmp/x.ps1', Argv),
             'powershell argv builds');
  AssertTrue(Length(Argv) = 6, 'powershell argv has 6 elements');
  AssertTrue((Argv[0] = 'pwsh') or (Argv[0] = 'powershell'),
             'argv[0] is pwsh or powershell (got "' + Argv[0] + '")');
  AssertEqStr(Argv[1], '-NoProfile',        'argv[1] is -NoProfile');
  AssertEqStr(Argv[2], '-ExecutionPolicy',  'argv[2] is -ExecutionPolicy');
  AssertEqStr(Argv[3], 'Bypass',            'argv[3] is Bypass');
  AssertEqStr(Argv[4], '-File',             'argv[4] is -File');
  AssertEqStr(Argv[5], '/tmp/x.ps1',        'argv[5] is the script path');
end;

procedure TestResolvePowerShellExeFallback;
(* Codex P2 on PR #199: the original implementation hardcoded
   pwsh, which silently breaks on stock Windows (Windows
   PowerShell 5.1 only -- `pwsh` requires the optional
   PowerShell 7+ install). ResolvePowerShellExe now picks pwsh
   when it's on PATH and falls back to `powershell` on Windows.

   We can only pin the unix half of the contract directly from
   this test (the Windows fallback fires only when MSWINDOWS is
   defined). On unix, the test box typically does NOT have pwsh,
   so we expect 'pwsh' -- but if a contributor's box does have
   pwsh installed, that's also valid. Either way the result must
   be non-empty and must be one of the two known values. *)
var
  Exe: string;
begin
  Exe := ResolvePowerShellExe;
  AssertTrue(Exe <> '', 'ResolvePowerShellExe is never empty');
  AssertTrue((Exe = 'pwsh') or (Exe = 'powershell'),
             'ResolvePowerShellExe returns a known binary (got "' + Exe + '")');
end;

procedure TestBuildArgvUnknownLang;
var
  Argv: TStringArray;
begin
  Argv := nil;
  AssertTrue(not BuildExecuteCodeArgv('nodejs', '/tmp/x.js', Argv),
             'unknown lang returns False');
end;

procedure TestEndToEndRoundTrip;
{ Drive the actual tool handler. On a Linux CI box this writes a
  bash script and runs it; the assertion is that the script's
  echo output makes it back through RunOneShot's capture pipe.
  Skip the test gracefully on Windows where the runner may not
  have pwsh installed -- the BuildArgv test above covers the
  PowerShell contract without needing to spawn. }
var
  Out_, Err: string;
begin
  SetupSandbox;
  Out_ := Tool_ExecuteCode(
            '{"lang":"bash","code":"for i in 1 2 3; do echo line $i; done"}',
            Err);
  AssertEqStr(Err, '', 'no error on happy path');
  AssertContains(Out_, 'exit=0',  'success exit code returned');
  AssertContains(Out_, 'line 1', 'first iteration of loop in output');
  AssertContains(Out_, 'line 2', 'second iteration of loop in output');
  AssertContains(Out_, 'line 3', 'third iteration of loop in output');
end;

procedure TestDenylistRejectsScriptBody;
(* The denylist is the safety floor. If the model wrote
   `rm -rf /` inside a bash heredoc, that has to be refused
   identically to a shell_exec call carrying the same command.
   Otherwise execute_code is a trivial bypass and we'd be
   silently weakening the sandbox.

   We don't test EVERY denied token here -- shell_exec's own test
   suite covers the matrix. We just pin that the rejection
   triggers when the bad substring is buried inside a multi-line
   body, which is the path most likely to silently regress
   ("ShellAllowed only checks the first line" was a real bug at
   one point). *)
var
  Out_, Err: string;
begin
  SetupSandbox;
  Out_ := Tool_ExecuteCode(
            '{"lang":"bash","code":"echo this looks innocent\nls /tmp\n' +
            'rm -rf /  # buried deep in the script\necho still here"}',
            Err);
  AssertEqStr(Out_, '', 'denied script returns empty result');
  AssertTrue(Err <> '', 'denied script populates ErrMsg');
end;

procedure TestMissingCodeArg;
var
  Out_, Err: string;
begin
  SetupSandbox;
  Out_ := Tool_ExecuteCode('{}', Err);
  AssertEqStr(Out_, '', 'missing code arg returns empty result');
  AssertContains(Err, 'code', 'error mentions the missing arg');
end;

procedure TestArgvNeedsQuoting;
{ Regression for the Windows cmd-quoting bug that produced
  "'\"powershell\"' is not recognized as an internal or external
  command". Argv[0] is always a bareword executable name on every
  current code path (bash / pwsh / powershell), so the quoting
  helper must NOT wrap it. The script-path argument can contain
  spaces when $PASCLAW_HOME sits under a profile with spaces, so
  it must still get quoted. }
begin
  { Bareword executable names: must NOT be quoted. }
  AssertTrue(not ArgvNeedsQuoting('bash'),
             'bash bareword unquoted');
  AssertTrue(not ArgvNeedsQuoting('powershell'),
             'powershell bareword unquoted');
  AssertTrue(not ArgvNeedsQuoting('pwsh'),
             'pwsh bareword unquoted');

  { Bareword flags: also unquoted. }
  AssertTrue(not ArgvNeedsQuoting('-File'),
             '-File flag unquoted');
  AssertTrue(not ArgvNeedsQuoting('-NoProfile'),
             '-NoProfile flag unquoted');
  AssertTrue(not ArgvNeedsQuoting('Bypass'),
             'Bypass policy value unquoted');

  { Paths without spaces -- safe unquoted. }
  AssertTrue(not ArgvNeedsQuoting('/tmp/x.ps1'),
             'simple POSIX path unquoted');
  AssertTrue(not ArgvNeedsQuoting('/home/u/.pasclaw/tmp/exec.sh'),
             'real-shape POSIX path unquoted');

  { Windows paths without spaces -- safe unquoted. Backslash is not a
    shell metacharacter on either cmd or sh, so a bareword Windows
    path passes through clean. }
  AssertTrue(not ArgvNeedsQuoting('C:\Users\anony\.pasclaw\tmp\exec.ps1'),
             'plain Windows path unquoted (no spaces, no specials)');

  { Paths WITH spaces -- must be quoted. This is the realistic case
    that makes Cmd_Build_Run keep the quoting code path at all. }
  AssertTrue(ArgvNeedsQuoting('C:\Program Files\thing\x.ps1'),
             'Windows path with literal space must be quoted');
  AssertTrue(ArgvNeedsQuoting('/path with space/script.sh'),
             'POSIX path with space must be quoted');

  { Empty string -- needs explicit "" so the arg slot isn't lost. }
  AssertTrue(ArgvNeedsQuoting(''), 'empty arg needs "" wrapping');

  { Shell-special chars in the body. }
  AssertTrue(ArgvNeedsQuoting('a && b'),  '&& metacharacter');
  AssertTrue(ArgvNeedsQuoting('a | b'),   '| pipe');
  AssertTrue(ArgvNeedsQuoting('a"b'),     'embedded quote');
  AssertTrue(ArgvNeedsQuoting('a$b'),     '$ dollar');
  AssertTrue(ArgvNeedsQuoting('a`b'),     '` backtick');
end;

begin
  TestResolveLangDispatch;
  TestBuildArgvBash;
  TestBuildArgvPowerShell;
  TestResolvePowerShellExeFallback;
  TestBuildArgvUnknownLang;
  TestEndToEndRoundTrip;
  TestDenylistRejectsScriptBody;
  TestMissingCodeArg;
  TestArgvNeedsQuoting;
  WriteLn('execute_code_tests: OK');
end.
