program shell_filters_tests;
(*
  Covers PasClaw.Tools.Shell.Filters.

  Two contracts to pin:
    1. Tee-on-failure. ExitCode <> 0 returns RawOut unchanged. The
       model needs the full output to debug; a condensed failure
       is worse than a long one.
    2. Unknown commands pass through. Only commands the dispatcher
       recognises get filtered -- a bespoke incantation the model
       invented never comes back mangled.

  Plus per-filter behaviour: git status/diff/log, the
  npm/pytest/cargo test runners, grep/findstr/Select-String, and
  ls/find/Get-ChildItem -Recurse. PowerShell + cmd.exe aliases
  normalise to the Unix shape so the same filter fires regardless
  of which shell the model addressed.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Tools.Shell.Filters;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure TestCanonicalize;
{ Pin the dispatch key normalisation. The same filter should fire
  whether the operator's host is Linux/macOS bash, cmd.exe, or
  PowerShell -- the model just calls the command natural to its
  context. }
begin
  AssertEqStr(CanonicalizeShellCommand('git status'), 'git status',
              'git status passes through');
  AssertEqStr(CanonicalizeShellCommand('git diff --stat'), 'git diff',
              'git diff with flag normalises');

  { PowerShell aliases. }
  AssertEqStr(CanonicalizeShellCommand('Get-ChildItem -Recurse src'), 'ls',
              'Get-ChildItem -> ls');
  AssertEqStr(CanonicalizeShellCommand('gci -r src'), 'ls',
              'gci -> ls');
  AssertEqStr(CanonicalizeShellCommand('Select-String -Path *.pas foo'), 'grep',
              'Select-String -> grep');
  AssertEqStr(CanonicalizeShellCommand('sls foo *.pas'), 'grep',
              'sls -> grep');

  { cmd.exe builtins. }
  AssertEqStr(CanonicalizeShellCommand('dir /s'), 'ls', 'dir -> ls');
  AssertEqStr(CanonicalizeShellCommand('findstr /R "foo" *.pas'), 'grep',
              'findstr -> grep');
  AssertEqStr(CanonicalizeShellCommand('type README.md'), 'cat',
              'type -> cat');

  { Shell-wrapper peeling -- on Windows, the model sometimes
    invokes `powershell -Command "git status"`. The filter should
    dispatch on the inner command, not the wrapper. }
  AssertEqStr(CanonicalizeShellCommand('powershell -Command "git status"'),
              'git status', 'powershell -Command wrapper peeled');
  AssertEqStr(CanonicalizeShellCommand('cmd /c dir /s'), 'ls',
              'cmd /c wrapper peeled');
  AssertEqStr(CanonicalizeShellCommand('bash -c "git log"'), 'git log',
              'bash -c wrapper peeled');

  { Edge cases. }
  AssertEqStr(CanonicalizeShellCommand(''), '', 'empty command');
  AssertEqStr(CanonicalizeShellCommand('   '), '', 'whitespace-only');
end;

procedure TestTeeOnFailure;
{ Non-zero exit must short-circuit -- if cargo test fails with a
  300-line stack trace, the model needs every byte of it to fix
  the bug. Filter returns RawOut byte-identical. }
var
  Raw: string;
  Got: string;
begin
  ResetShellFilterCounters;
  Raw := 'test result: FAILED' + sLineBreak +
         '    Compiling foo v0.1.0' + sLineBreak +
         'error[E0308]: mismatched types';
  Got := ApplyShellFilter('cargo test', Raw, 1);
  AssertEqStr(Got, Raw, 'tee-on-failure: cargo test exit 1 passes through');
  AssertTrue(ShellFilterCalls = 0,
             'failure path does not bump counters');
end;

procedure TestUnknownCommand;
{ A command the dispatcher doesn't recognise -- e.g. a one-off
  invocation -- must round-trip unchanged. We don't filter what
  we don't understand. }
var
  Raw, Got: string;
begin
  ResetShellFilterCounters;
  Raw := 'whatever the operator typed';
  Got := ApplyShellFilter('xyzzy-custom-script.sh --foo', Raw, 0);
  AssertEqStr(Got, Raw, 'unknown command passes through');
  AssertTrue(ShellFilterCalls = 0,
             'unknown command does not bump counters');
end;

procedure TestGitStatusClean;
var
  Raw, Got: string;
begin
  ResetShellFilterCounters;
  Raw := 'On branch main' + sLineBreak +
         'Your branch is up to date with ''origin/main''.' + sLineBreak +
         '' + sLineBreak +
         'nothing to commit, working tree clean';
  Got := ApplyShellFilter('git status', Raw, 0);
  AssertTrue(Pos('branch: main', Got) > 0,
             'clean status surfaces branch');
  AssertTrue(Pos('clean', Got) > 0,
             'clean status says clean');
  AssertTrue(Length(Got) < Length(Raw),
             'clean-status filter reduces byte count');
end;

procedure TestGitStatusWithChanges;
{ Pin the count surfacing: a `git status` with a long list of
  files must come back with grouped counts and a sample slice, not
  the full list. }
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := 'On branch feature/x' + sLineBreak +
         'Changes to be committed:' + sLineBreak;
  for i := 1 to 12 do
    Raw := Raw + '	modified:   src/a' + IntToStr(i) + '.pas' + sLineBreak;
  Raw := Raw +
         'Changes not staged for commit:' + sLineBreak +
         '	modified:   README.md' + sLineBreak +
         'Untracked files:' + sLineBreak +
         '	build/' + sLineBreak;
  Got := ApplyShellFilter('git status', Raw, 0);
  AssertTrue(Pos('branch: feature/x', Got) > 0, 'branch surfaced');
  AssertTrue(Pos('staged: 12', Got) > 0, 'staged count');
  AssertTrue(Pos('and 4 more', Got) > 0,
             'overflow truncation hint shown');
  AssertTrue(Length(Got) < Length(Raw),
             'filter actually saves bytes');
end;

procedure TestGitDiffPassthroughSmall;
{ Small diffs (under the line cap) pass through verbatim -- the
  model needs the line-level detail to read a real diff. }
var
  Raw, Got: string;
begin
  ResetShellFilterCounters;
  Raw := 'diff --git a/foo.pas b/foo.pas' + sLineBreak +
         '+added' + sLineBreak +
         '-removed';
  Got := ApplyShellFilter('git diff', Raw, 0);
  AssertEqStr(Got, Raw, 'small diff passes through verbatim');
end;

procedure TestGitDiffSummarisesLarge;
{ Once a diff blows past the passthrough cap, the filter walks
  hunks and emits a one-line-per-file summary with +/- counts. }
var
  Raw, Got: string;
  i, j: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 3 do
  begin
    Raw := Raw + 'diff --git a/file' + IntToStr(i) + '.pas b/file' +
           IntToStr(i) + '.pas' + sLineBreak +
           '--- a/file' + IntToStr(i) + '.pas' + sLineBreak +
           '+++ b/file' + IntToStr(i) + '.pas' + sLineBreak +
           '@@ -1,3 +1,3 @@' + sLineBreak;
    for j := 1 to 30 do
      Raw := Raw + '+added line ' + IntToStr(j) + sLineBreak;
  end;
  Got := ApplyShellFilter('git diff', Raw, 0);
  AssertTrue(Pos('3 file(s) changed', Got) > 0,
             'diff summary file count');
  AssertTrue(Pos('file1.pas', Got) > 0, 'file1 listed');
  AssertTrue(Pos('+30', Got) > 0, 'plus count surfaced');
  AssertTrue(Length(Got) < Length(Raw),
             'diff filter saves bytes on large diffs');
end;

procedure TestPytestFailures;
{ The test-runner filter collapses passes and surfaces failures
  with context. A real pytest run on a moderately broken project
  would otherwise dump kilobytes of PASSED lines we never need. }
var
  Raw, Got: string;
begin
  ResetShellFilterCounters;
  Raw :=
    'tests/test_foo.py::test_a PASSED' + sLineBreak +
    'tests/test_foo.py::test_b PASSED' + sLineBreak +
    'tests/test_foo.py::test_c PASSED' + sLineBreak +
    'tests/test_bar.py::test_x FAILED' + sLineBreak +
    '    AssertionError: expected 1, got 2' + sLineBreak +
    '    at line 42' + sLineBreak +
    '' + sLineBreak +
    'tests/test_foo.py::test_d PASSED';
  Got := ApplyShellFilter('pytest', Raw, 0);
  AssertTrue(Pos('test_x', Got) > 0, 'failed test name surfaced');
  AssertTrue(Pos('AssertionError', Got) > 0,
             'failure context surfaced');
  AssertTrue(Length(Got) < Length(Raw),
             'pytest filter saves bytes when passes outnumber fails');
end;

procedure TestGrepAggregatesByFile;
{ A wide `grep -r` over a big repo emits one line per match; the
  filter groups by file and shows counts + a sample slice. The
  exact same shape from findstr / Select-String hits the same
  filter via canonicalisation. }
var
  Raw, Got: string;
begin
  ResetShellFilterCounters;
  Raw :=
    'src/a.pas:10:procedure Foo;' + sLineBreak +
    'src/a.pas:20:procedure Foo;' + sLineBreak +
    'src/a.pas:30:procedure Foo;' + sLineBreak +
    'src/a.pas:40:procedure Foo;' + sLineBreak +
    'src/b.pas:5:procedure Foo;';
  Got := ApplyShellFilter('grep -r procedure src/', Raw, 0);
  AssertTrue(Pos('5 match', Got) > 0, 'total match count');
  AssertTrue(Pos('2 file', Got) > 0,  'file count');
  AssertTrue(Pos('src/a.pas', Got) > 0, 'first file surfaced');
  { Filter dispatch via Select-String alias. }
  Got := ApplyShellFilter('Select-String -Path *.pas procedure', Raw, 0);
  AssertTrue(Pos('5 match', Got) > 0,
             'Select-String alias hits same filter');
end;

procedure TestCountersIncrement;
{ Pin the cross-call accumulator the TUI /stats overlay reads.
  Each successful filter run that actually reduced byte count
  bumps the counters; pass-through runs do not. }
var
  Raw: string;
  GotByteSavings: Int64;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := 'On branch main' + sLineBreak +
         'Changes to be committed:' + sLineBreak;
  for i := 1 to 20 do
    Raw := Raw + '	modified:   src/f' + IntToStr(i) + '.pas' + sLineBreak;
  ApplyShellFilter('git status', Raw, 0);
  GotByteSavings := ShellFilterBytesSaved;
  AssertTrue(ShellFilterCalls = 1, 'one call recorded');
  AssertTrue(GotByteSavings > 0,
             'positive byte savings on a 20-file status');

  { Second call accumulates. }
  ApplyShellFilter('git status', Raw, 0);
  AssertTrue(ShellFilterCalls = 2, 'counter accumulates');
  AssertTrue(ShellFilterBytesSaved >= 2 * GotByteSavings,
             'byte savings accumulate');
end;

begin
  TestCanonicalize;
  TestTeeOnFailure;
  TestUnknownCommand;
  TestGitStatusClean;
  TestGitStatusWithChanges;
  TestGitDiffPassthroughSmall;
  TestGitDiffSummarisesLarge;
  TestPytestFailures;
  TestGrepAggregatesByFile;
  TestCountersIncrement;
  WriteLn('shell_filters_tests: OK');
end.
