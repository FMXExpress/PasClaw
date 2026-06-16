program run_timeout_tests;
(*
  Pins RunArgvCapture's TimeoutMs cap -- the guard that keeps a wedged
  Docker daemon (`docker info` that never returns) from hanging
  serve/agent at startup. A timed-out child must be terminated, report
  124, carry a "timed out" note, and -- crucially -- the call must return
  in roughly the timeout window, not run to completion.

  Unix-only (drives /bin/sh); the CI test runner is FPC/Linux.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Platform;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

{$IFDEF UNIX}
function ElapsedMs(const StartT: TDateTime): Int64;
begin
  Result := Trunc((Now - StartT) * 86400000.0);
end;

procedure RunChecks;
var
  Args: TStrings;
  Output: string;
  Code: Integer;
  StartT: TDateTime;
  Elapsed: Int64;
begin
  { 1. A child that sleeps far past the timeout is killed at ~the deadline. }
  Args := TStringList.Create;
  try
    Args.Add('-c');
    Args.Add('sleep 10');
    StartT := Now;
    Code := RunArgvCapture('/bin/sh', Args, '', Output, 500);
    Elapsed := ElapsedMs(StartT);
  finally
    Args.Free;
  end;
  if Code <> 124 then Fail_(Format('timed-out child should return 124, got %d', [Code]));
  if Pos('timed out', LowerCase(Output)) = 0 then
    Fail_('timed-out output should note the timeout, got: ' + Output);
  if Elapsed > 4000 then
    Fail_(Format('timeout did not bound runtime: took %d ms (cap 500)', [Elapsed]));

  { 2. A fast child finishes normally well within a generous timeout -- the
       cap must not interfere with successful runs. }
  Args := TStringList.Create;
  try
    Args.Add('-c');
    Args.Add('printf hello');
    Code := RunArgvCapture('/bin/sh', Args, '', Output, 5000);
  finally
    Args.Free;
  end;
  if Code <> 0 then Fail_(Format('fast child should return 0, got %d', [Code]));
  if Trim(Output) <> 'hello' then Fail_('fast child output mismatch: ' + Output);

  { 3. TimeoutMs = 0 keeps the historical unbounded behaviour (still completes). }
  Args := TStringList.Create;
  try
    Args.Add('-c');
    Args.Add('printf ok');
    Code := RunArgvCapture('/bin/sh', Args, '', Output, 0);
  finally
    Args.Free;
  end;
  if (Code <> 0) or (Trim(Output) <> 'ok') then
    Fail_('TimeoutMs=0 path regressed: code=' + IntToStr(Code) + ' out=' + Output);
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  RunChecks;
  {$ENDIF}
  WriteLn('run_timeout_tests: OK');
end.
