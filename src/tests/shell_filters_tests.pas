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
  SysUtils, StrUtils,
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

procedure TestCanonicalizeExpandedFamilies;
{ The rtk-inspired families: containers, k8s, gh, linters, package
  managers, IaC. Plus the sudo/npx peel and the option-skipping
  subcommand walk. }
begin
  AssertEqStr(CanonicalizeShellCommand('docker ps -a'), 'docker ps',
              'docker ps');
  AssertEqStr(CanonicalizeShellCommand('sudo docker images'), 'docker images',
              'sudo peeled before docker');
  AssertEqStr(CanonicalizeShellCommand('docker --context prod ps'), 'docker',
              'option in subcommand position degrades to one-word key (passes through)');
  AssertEqStr(CanonicalizeShellCommand('kubectl get pods -n prod'), 'kubectl get',
              'kubectl get');
  AssertEqStr(CanonicalizeShellCommand('gh pr list --limit 50'), 'gh pr',
              'gh pr');
  AssertEqStr(CanonicalizeShellCommand('npx eslint src/'), 'eslint',
              'npx peeled before eslint');
  AssertEqStr(CanonicalizeShellCommand('pip3 install -r requirements.txt'),
              'pip install', 'pip3 -> pip');
  AssertEqStr(CanonicalizeShellCommand('npm i lodash'), 'npm install',
              'npm i -> npm install');
  AssertEqStr(CanonicalizeShellCommand('./gradlew build'), 'gradle build',
              'gradlew wrapper -> gradle');
  AssertEqStr(CanonicalizeShellCommand('terraform plan -out tf.plan'),
              'terraform plan', 'terraform plan');
  AssertEqStr(CanonicalizeShellCommand('aws s3 ls'), 'aws', 'aws one-word key');
end;

procedure TestTabularCapsDockerPs;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := 'CONTAINER ID   IMAGE     COMMAND   STATUS' + sLineBreak;
  for i := 1 to 60 do
    Raw := Raw + Format('%.12d   img%d:latest   "cmd"   Up %d minutes',
                        [i, i, i]) + sLineBreak;
  Got := ApplyShellFilter('docker ps -a', Raw, 0);
  AssertTrue(Pos('CONTAINER ID', Got) > 0, 'header row kept');
  AssertTrue(Pos('more rows elided', Got) > 0, 'overflow hint shown');
  AssertTrue(Length(Got) < Length(Raw), 'docker ps table capped');
  { Same shape via kubectl get. }
  Got := ApplyShellFilter('kubectl get pods', Raw, 0);
  AssertTrue(Pos('more rows elided', Got) > 0, 'kubectl get capped too');
  { Small tables pass through. }
  Raw := 'CONTAINER ID   IMAGE' + sLineBreak + 'abc   img:1';
  Got := ApplyShellFilter('docker ps', Raw, 0);
  AssertEqStr(Got, Raw, 'small table passes through');
end;

procedure TestCargoClippyCollapsesCompileNoise;
{ clippy exits 0 with warnings -- exactly the case tee-on-failure
  does NOT protect, so the filter must keep the warnings verbatim
  while dropping the Compiling/Checking wall. }
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 40 do
    Raw := Raw + '    Checking crate' + IntToStr(i) + ' v0.1.' + IntToStr(i) +
           sLineBreak;
  Raw := Raw +
    'warning: unused variable: `x`' + sLineBreak +
    '  --> src/main.rs:4:9' + sLineBreak +
    '   = note: `#[warn(unused_variables)]` on by default' + sLineBreak +
    '' + sLineBreak +
    '    Finished dev [unoptimized] target(s) in 12.3s';
  Got := ApplyShellFilter('cargo clippy', Raw, 0);
  AssertTrue(Pos('unused variable', Got) > 0, 'warning text kept verbatim');
  AssertTrue(Pos('src/main.rs:4:9', Got) > 0, 'warning location kept');
  AssertTrue(Pos('Finished', Got) > 0, 'Finished line kept');
  AssertTrue(Pos('40 compile/fetch lines elided', Got) > 0,
             'compile noise collapsed to count');
  AssertTrue(Length(Got) < Length(Raw), 'clippy filter saves bytes');
end;

procedure TestCargoOverCapReportsElidedCount;
{ Codex P2 on PR #230: when warnings exceed MAX_WARN_BLOCKS the
  filter must tell the model how many extra diagnostics exist --
  not silently drop them. clippy exits 0 with warnings, so they
  bypass tee-on-failure and would otherwise vanish past the cap. }
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 5 do
    Raw := Raw + '    Checking pkg' + IntToStr(i) + ' v0.1.0' + sLineBreak;
  { 15 warnings -- 5 more than MAX_WARN_BLOCKS = 10. }
  for i := 1 to 15 do
    Raw := Raw +
      'warning: unused variable: `x' + IntToStr(i) + '`' + sLineBreak +
      '  --> src/main.rs:' + IntToStr(i) + ':9' + sLineBreak +
      '' + sLineBreak;
  Raw := Raw + '    Finished dev [unoptimized] target(s) in 1.2s';
  Got := ApplyShellFilter('cargo clippy', Raw, 0);
  AssertTrue(Pos('5 more warning/error block(s) elided', Got) > 0,
             'over-cap diagnostics counted and reported');
  AssertTrue(Pos('Finished', Got) > 0, 'Finished line still kept');
  AssertTrue(Pos('unused variable: `x1`', Got) > 0,
             'first warning kept verbatim');
end;

procedure TestGoTestCollapsesOkPackages;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 30 do
    Raw := Raw + 'ok  	example.com/pkg' + IntToStr(i) + '	0.0' +
           IntToStr(i mod 10) + 's' + sLineBreak;
  Got := ApplyShellFilter('go test ./...', Raw, 0);
  AssertTrue(Pos('30 package(s) ok', Got) > 0, 'ok packages counted');
  AssertTrue(Length(Got) < Length(Raw), 'go test filter saves bytes');
end;

procedure TestEslintAggregates;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '/repo/src/app.ts' + sLineBreak;
  for i := 1 to 30 do
    Raw := Raw + Format('  %d:10  warning  Unexpected any  @typescript-eslint/no-explicit-any',
                        [i]) + sLineBreak;
  Raw := Raw + sLineBreak +
         '✖ 30 problems (0 errors, 30 warnings)';
  Got := ApplyShellFilter('npx eslint src/', Raw, 0);
  AssertTrue(Pos('/repo/src/app.ts', Got) > 0, 'file header kept');
  AssertTrue(Pos('30 problems', Got) > 0, 'summary line kept');
  AssertTrue(Pos('more problem lines elided', Got) > 0,
             'per-file problems capped');
  AssertTrue(Length(Got) < Length(Raw), 'eslint filter saves bytes');
end;

procedure TestPipInstallCollapses;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 15 do
    Raw := Raw + 'Collecting package' + IntToStr(i) + '>=1.0' + sLineBreak +
           'Downloading package' + IntToStr(i) + '-1.0-py3-none-any.whl (50 kB)' +
           sLineBreak;
  for i := 1 to 10 do
    Raw := Raw + 'Requirement already satisfied: dep' + IntToStr(i) +
           ' in ./venv/lib' + sLineBreak;
  Raw := Raw + 'Successfully installed package1-1.0 package2-1.0';
  Got := ApplyShellFilter('pip install -r requirements.txt', Raw, 0);
  AssertTrue(Pos('Successfully installed', Got) > 0,
             'Successfully-installed line kept');
  AssertTrue(Pos('30 fetch/build lines + 10 already-satisfied elided', Got) > 0,
             'noise collapsed to counts');
  AssertTrue(Length(Got) < Length(Raw), 'pip filter saves bytes');
end;

procedure TestNpmInstallKeepsSummary;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 25 do
    Raw := Raw + 'npm http fetch GET 200 https://registry.npmjs.org/pkg' +
           IntToStr(i) + sLineBreak;
  Raw := Raw +
    'added 312 packages, and audited 313 packages in 12s' + sLineBreak +
    'found 0 vulnerabilities';
  Got := ApplyShellFilter('npm install', Raw, 0);
  AssertTrue(Pos('added 312 packages', Got) > 0, 'added-summary kept');
  AssertTrue(Pos('vulnerabilities', Got) > 0, 'audit line kept');
  AssertTrue(Pos('progress lines elided', Got) > 0, 'progress collapsed');
  AssertTrue(Length(Got) < Length(Raw), 'npm install filter saves bytes');
end;

procedure TestMavenDropsInfoWall;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 50 do
    Raw := Raw + '[INFO] Downloading from central: https://repo/' +
           IntToStr(i) + sLineBreak;
  Raw := Raw +
    '[WARNING] Using platform encoding (UTF-8)' + sLineBreak +
    '[INFO] BUILD SUCCESS' + sLineBreak +
    '[INFO] Total time:  12.3 s';
  Got := ApplyShellFilter('mvn package', Raw, 0);
  AssertTrue(Pos('BUILD SUCCESS', Got) > 0, 'build status kept');
  AssertTrue(Pos('Total time', Got) > 0, 'total time kept');
  AssertTrue(Pos('[WARNING]', Got) > 0, 'warnings kept');
  AssertTrue(Pos('[INFO] lines elided', Got) > 0, 'INFO wall collapsed');
  AssertTrue(Length(Got) < Length(Raw), 'mvn filter saves bytes');
end;

procedure TestTerraformPlanKeepsResourceList;
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := 'Terraform will perform the following actions:' + sLineBreak;
  for i := 1 to 5 do
  begin
    Raw := Raw + sLineBreak +
      '  # aws_instance.web' + IntToStr(i) + ' will be created' + sLineBreak +
      '  + resource "aws_instance" "web' + IntToStr(i) + '" {' + sLineBreak;
    { 20 attribute lines per resource -- the noise we drop. }
    Raw := Raw + StringOfChar(' ', 6) + '+ ami           = "ami-123"' + sLineBreak;
    Raw := Raw + DupeString('      + tag           = "v"' + sLineBreak, 19);
    Raw := Raw + '    }' + sLineBreak;
  end;
  Raw := Raw + sLineBreak + 'Plan: 5 to add, 0 to change, 0 to destroy.';
  Got := ApplyShellFilter('terraform plan', Raw, 0);
  AssertTrue(Pos('aws_instance.web1', Got) > 0, 'resource header kept');
  AssertTrue(Pos('Plan: 5 to add', Got) > 0, 'plan summary kept');
  AssertTrue(Pos('attribute/diff lines elided', Got) > 0,
             'attribute noise collapsed');
  AssertTrue(Length(Got) < Length(Raw), 'terraform filter saves bytes');
end;

procedure TestHeadTailKeepsLogTail;
{ docker/kubectl logs -- the tail is where the recent (interesting)
  events live, so the filter must keep BOTH ends. }
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '';
  for i := 1 to 200 do
    Raw := Raw + 'log line ' + IntToStr(i) + sLineBreak;
  Got := ApplyShellFilter('docker logs mycontainer', Raw, 0);
  AssertTrue(Pos('log line 1' + sLineBreak, Got) > 0, 'head kept');
  AssertTrue(Pos('log line 200', Got) > 0, 'tail kept');
  AssertTrue(Pos('lines elided', Got) > 0, 'middle elided');
  AssertTrue(Length(Got) < Length(Raw), 'log filter saves bytes');
end;

procedure TestAwsJsonRoutesThroughCondenser;
{ aws CLI defaults to JSON; a long array response should come back
  condensed (first-N + "...more items" + last), same engine as the
  tool loop's MCP condenser. }
var
  Raw, Got: string;
  i: Integer;
begin
  ResetShellFilterCounters;
  Raw := '{"Reservations":[';
  for i := 1 to 300 do
  begin
    if i > 1 then Raw := Raw + ',';
    Raw := Raw + '{"InstanceId":"i-' + IntToStr(100000 + i) +
           '","State":"running","Az":"us-east-1a"}';
  end;
  Raw := Raw + ']}';
  Got := ApplyShellFilter('aws ec2 describe-instances', Raw, 0);
  AssertTrue(Length(Got) < Length(Raw), 'aws JSON condensed');
  AssertTrue(Pos('more items', Got) > 0, 'array collapse marker present');
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
  TestCanonicalizeExpandedFamilies;
  TestTabularCapsDockerPs;
  TestCargoClippyCollapsesCompileNoise;
  TestCargoOverCapReportsElidedCount;
  TestGoTestCollapsesOkPackages;
  TestEslintAggregates;
  TestPipInstallCollapses;
  TestNpmInstallKeepsSummary;
  TestMavenDropsInfoWall;
  TestTerraformPlanKeepsResourceList;
  TestHeadTailKeepsLogTail;
  TestAwsJsonRoutesThroughCondenser;
  WriteLn('shell_filters_tests: OK');
end.
