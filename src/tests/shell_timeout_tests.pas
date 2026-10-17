program shell_timeout_tests;
(*
  shell_exec had no wall-clock bound: a command that never returned hung
  the turn for good. Pinned here (POSIX; the Windows arm is the same loop
  with the same flag):

    - the process default (SetShellTimeoutMs) kills a sleeping command,
      reports exit 124 and appends "(timed out after N s)"
    - 0 = no bound: a quick command is unaffected
    - the per-thread override wins over the default and -1 clears it
    - Tool_Shell's `timeout_sec` argument produces exit=124 on line 1
    - TConfig: shell_timeout_sec defaults to 600 and round-trips, and
      ApplyConfigGlobals pushes it into the platform mirror
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Platform,
  PasClaw.Config,
  PasClaw.Tools.Shell;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 200)); end;

var
  Out_, Err, J: string;
  Code: Integer;
  T0: TDateTime;
  A, B: TConfig;
begin
  {$IFDEF UNIX}
  { Default bound. }
  SetShellTimeoutMs(700);
  AssertEqInt(EffectiveShellTimeoutMs, 700, 'default applies');
  T0 := Now;
  Code := RunOneShot('sleep 5; echo late', Out_);
  AssertEqInt(Code, 124, 'timed-out command reports 124');
  AssertTrue(MilliSecondsBetween(Now, T0) < 3000, 'killed well before the sleep would end');
  AssertContains(Out_, 'timed out after 1 s', 'output carries the note');
  AssertTrue(Pos('late', Out_) = 0, 'the command did not get to finish');

  { No bound. }
  SetShellTimeoutMs(0);
  AssertEqInt(EffectiveShellTimeoutMs, 0, '0 means none');
  Code := RunOneShot('echo quick', Out_);
  AssertEqInt(Code, 0, 'quick command unaffected');
  AssertContains(Out_, 'quick', 'output intact');

  { Per-thread override. }
  SetShellTimeoutMs(60000);
  SetShellTimeoutOverrideMs(500);
  AssertEqInt(EffectiveShellTimeoutMs, 500, 'override wins');
  Code := RunOneShotWithEnv('sleep 5', '', nil, Out_);
  AssertEqInt(Code, 124, 'override bound kills');
  SetShellTimeoutOverrideMs(-1);
  AssertEqInt(EffectiveShellTimeoutMs, 60000, '-1 clears the override');

  { The tool's argument. }
  SetShellTimeoutMs(0);
  Out_ := Tool_Shell('{"command":"sleep 5; echo late","timeout_sec":1}', Err);
  AssertTrue(Err = '', 'tool returns a result, not an error: ' + Err);
  AssertTrue(Pos('exit=124', Out_) = 1, 'line 1 is exit=124: ' + Copy(Out_, 1, 40));
  AssertContains(Out_, 'timed out', 'tool result carries the note');
  AssertEqInt(EffectiveShellTimeoutMs, 0, 'the per-call override did not leak');
  WriteLn('  ok: default bound, no bound, override, tool argument');
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
    AssertEqInt(EffectiveShellTimeoutMs, 42000, 'ApplyConfigGlobals pushes the mirror');
  finally
    A.Free;
    B.Free;
  end;
  WriteLn('  ok: config default, round-trip, globals');
  WriteLn('PASS');
end.
