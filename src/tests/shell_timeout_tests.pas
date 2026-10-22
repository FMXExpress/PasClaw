program shell_timeout_tests;
(*
  shell_exec had no wall-clock bound: a command that never returned hung
  the turn for good. Pinned here (POSIX; the Windows arm is the same loop
  with the same flag):

    - the bound kills a sleeping command, reports exit 124 and appends
      "(timed out after N s)"
    - no bound: a quick command is unaffected
    - the per-thread override is what RunOneShot honours, and -1 clears it
    - Tool_Shell's `timeout_sec` argument produces exit=124 on line 1
    - TConfig: shell_timeout_sec defaults to 600 and round-trips, and
      ApplyConfigGlobals stores it as the TOOL default

  and the two things the first cut got wrong (Codex on #608):

    - the configured default reaches the tool shells and ONLY them. A
      bare RunOneShot -- how an app build and a benchmark agent are
      spawned -- is not bounded by a shell command's timeout.
    - a timeout kills the whole process TREE. Terminating the /bin/sh
      wrapper alone left the compiler, test runner or `sleep` under it
      running while PasClaw had already reported exit=124.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Platform,
  PasClaw.Shell.Backend,
  PasClaw.Config,
  PasClaw.Tools.Shell;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 200)); end;

{$IFDEF UNIX}
{ Is a process with this pid alive? `kill -0` without the signal. }
function PidAlive(const Pid: string): Boolean;
var
  Out_: string;
begin
  Result := RunOneShot('kill -0 ' + Pid + ' 2>/dev/null && echo YES || echo NO', '', Out_) >= 0;
  Result := Result and (Pos('YES', Out_) > 0);
end;
{$ENDIF}

var
  Out_, Err, J: string;
  Code: Integer;
  T0: TDateTime;
  A, B: TConfig;
  {$IFDEF UNIX}
  MarkerDir, PidFile, Kid: string;
  Waited: Integer;
  {$ENDIF}
begin
  {$IFDEF UNIX}
  { The bound, set the way a tool call sets it. }
  SetShellTimeoutOverrideMs(700);
  AssertEqInt(EffectiveShellTimeoutMs, 700, 'the override is what a run uses');
  T0 := Now;
  Code := RunOneShot('sleep 5; echo late', '', Out_);
  AssertEqInt(Code, 124, 'timed-out command reports 124');
  AssertTrue(MilliSecondsBetween(Now, T0) < 3000, 'killed well before the sleep would end');
  AssertContains(Out_, 'timed out after 1 s', 'output carries the note');
  AssertTrue(Pos('late', Out_) = 0, 'the command did not get to finish');

  { No bound. }
  SetShellTimeoutOverrideMs(-1);
  AssertEqInt(EffectiveShellTimeoutMs, 0, 'cleared means none');
  Code := RunOneShot('echo quick', '', Out_);
  AssertEqInt(Code, 0, 'quick command unaffected');
  AssertContains(Out_, 'quick', 'output intact');

  { The override drives RunOneShotWithEnv too. }
  SetShellTimeoutOverrideMs(500);
  Code := RunOneShotWithEnv('sleep 5', '', nil, Out_);
  AssertEqInt(Code, 124, 'override bound kills');
  SetShellTimeoutOverrideMs(-1);

  (* ---- the default is the TOOL shells', not every RunOneShot's ----

     It used to be a process-wide value RunOneShot read directly, so an
     app build (PasClaw.Apps.Runner) and a whole benchmark agent
     (PasClaw.Cmd.Profile) -- both plain RunOneShot callers -- were
     silently killed at the shell default and reported as that job
     failing. (Codex P2 on #608.) *)
  SetShellToolTimeoutMs(700);
  AssertEqInt(EffectiveShellTimeoutMs, 0,
              'the configured default does NOT bound a bare RunOneShot');
  T0 := Now;
  Code := RunOneShot('sleep 2; echo build-finished', '', Out_);
  AssertEqInt(Code, 0, 'a non-tool caller runs past the shell default');
  AssertContains(Out_, 'build-finished', 'and gets its output');
  AssertTrue(MilliSecondsBetween(Now, T0) >= 1500, 'it really did run the 2 s');

  { ...while the tool path DOES get it. }
  T0 := Now;
  Code := RunOneShotViaBackend('', 'sleep 5; echo late', '', Out_);
  AssertEqInt(Code, 124, 'a tool shell is bounded by the configured default');
  AssertTrue(MilliSecondsBetween(Now, T0) < 3000, 'and killed promptly');
  AssertEqInt(ShellTimeoutOverrideMs, 0,
              'the wrapper restored the override it borrowed');

  { An explicit per-call bound still wins over the configured default. }
  SetShellToolTimeoutMs(60000);
  SetShellTimeoutOverrideMs(500);
  T0 := Now;
  Code := RunOneShotViaBackend('', 'sleep 5', '', Out_);
  AssertEqInt(Code, 124, 'the explicit override wins over a larger default');
  AssertTrue(MilliSecondsBetween(Now, T0) < 3000, 'at the override, not the default');
  AssertEqInt(ShellTimeoutOverrideMs, 500, 'and is left as the caller set it');
  SetShellTimeoutOverrideMs(-1);
  SetShellToolTimeoutMs(0);
  WriteLn('  ok: the default bounds tool shells only; an explicit bound wins');

  (* ---- a timeout kills the TREE ----

     The command is run as `/bin/sh -c ...`, so terminating the child
     signals the shell. Anything it started -- here a grandchild sleep
     that records its own pid -- used to survive, still running, with
     PasClaw already reporting exit=124. (Codex P1 on #608.) *)
  MarkerDir := GetEnvironmentVariable('PASCLAW_HOME');
  if MarkerDir = '' then MarkerDir := GetTempDir;
  PidFile := IncludeTrailingPathDelimiter(MarkerDir) + 'treekill.pid';
  if FileExists(PidFile) then DeleteFile(PidFile);

  SetShellTimeoutOverrideMs(700);
  T0 := Now;
  { The grandchild outlives the shell unless the tree is killed: it
    writes its pid, then sleeps far past our bound. }
  Code := RunOneShot('sh -c ''echo $$ > "' + PidFile + '"; sleep 30'' & wait',
                     '', Out_);
  AssertEqInt(Code, 124, 'the wrapper timed out');
  AssertTrue(MilliSecondsBetween(Now, T0) < 4000, 'promptly');
  SetShellTimeoutOverrideMs(-1);

  AssertTrue(FileExists(PidFile), 'the grandchild got far enough to record its pid');
  with TStringList.Create do
  try
    LoadFromFile(PidFile);
    Kid := Trim(Text);
  finally
    Free;
  end;
  AssertTrue(Kid <> '', 'and the pid is readable: "' + Kid + '"');

  { Give the SIGTERM/SIGKILL pass a moment to land, then insist. }
  Waited := 0;
  while PidAlive(Kid) and (Waited < 3000) do
  begin
    Sleep(100);
    Inc(Waited, 100);
  end;
  AssertTrue(not PidAlive(Kid),
    'the grandchild (pid ' + Kid + ') was killed with its shell -- ' +
    'terminating only the /bin/sh wrapper leaves it running while ' +
    'PasClaw already reported exit=124');
  WriteLn(Format('  ok: timeout killed the whole tree (grandchild gone after %d ms)', [Waited]));

  { The tool's argument. }
  Out_ := Tool_Shell('{"command":"sleep 5; echo late","timeout_sec":1}', Err);
  AssertTrue(Err = '', 'tool returns a result, not an error: ' + Err);
  AssertTrue(Pos('exit=124', Out_) = 1, 'line 1 is exit=124: ' + Copy(Out_, 1, 40));
  AssertContains(Out_, 'timed out', 'tool result carries the note');
  AssertEqInt(EffectiveShellTimeoutMs, 0, 'the per-call override did not leak');
  WriteLn('  ok: bound, no bound, override, tool argument');
  {$ELSE}
  WriteLn('  skip: process-timing assertions are POSIX-only here');
  {$ENDIF}

  { Config. }
  A := TConfig.Create;
  B := TConfig.Create;
  try
    AssertEqInt(A.ShellTimeoutSec, 600, 'default 600 s');
    J := A.ToJSON;
    AssertTrue(Pos('shell_timeout_sec', J) = 0, 'default not emitted');
    A.ShellTimeoutSec := 0;
    B.FromJSON(A.ToJSON);
    AssertEqInt(B.ShellTimeoutSec, 0, 'explicit 0 round-trips');
    A.ShellTimeoutSec := 42;
    B.FromJSON(A.ToJSON);
    AssertEqInt(B.ShellTimeoutSec, 42, '42 round-trips');
    ApplyConfigGlobals(B);
    AssertEqInt(ShellToolTimeoutMs, 42000,
                'ApplyConfigGlobals stores it as the TOOL default');
    AssertEqInt(EffectiveShellTimeoutMs, 0,
                'and not as a bound on every RunOneShot');
    SetShellToolTimeoutMs(0);
  finally
    A.Free;
    B.Free;
  end;
  WriteLn('  ok: config default, round-trip, globals');
  WriteLn('PASS');
end.
