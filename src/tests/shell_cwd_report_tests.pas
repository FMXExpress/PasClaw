program shell_cwd_report_tests;
(*
  Pins the cwd line on shell_exec results.

  The failure this closes: a result never named the directory the command
  ran in, so `exit=2 / No rule to make target 'test-orient'` read as "there
  is no such target" when it meant "you are not in that repo". 22 such
  failures across 5 persisted relay sessions, despite three ante-hoc
  disclosures (the cwd argument, its description, and the working-directory
  line in the system prompt) -- none of which appear at the moment of
  failure.

  Both directions are asserted. A hint that fires on every red result is
  noise, and noise is how a real signal gets ignored, so the negative
  controls below carry as much weight as the positive ones.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Shell;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

function FirstLine(const S: string): string;
var P: Integer;
begin
  Result := S;
  P := Pos(#10, Result);
  if P > 0 then Result := Copy(Result, 1, P - 1);
end;

function NthLine(const S: string; N: Integer): string;
var
  Rest, L: string;
  i, P: Integer;
begin
  Rest := S;
  Result := '';
  for i := 1 to N do
  begin
    P := Pos(#10, Rest);
    if P > 0 then begin L := Copy(Rest, 1, P - 1); Rest := Copy(Rest, P + 1, MaxInt); end
    else begin L := Rest; Rest := ''; end;
    Result := L;
  end;
end;

var
  Reg: TToolRegistry;

function Run(const ArgsJSON: string): string;
{ Dispatch through the registry rather than calling the handler
  directly: Tool_Shell is implementation-private, and a test should not
  make a unit widen its interface. This also exercises the real
  registration path. }
var
  T: TTool;
  Err: string;
begin
  Result := '';
  if not Reg.Find('shell_exec', T) then
  begin
    Fail_('shell_exec is not registered');
    Exit;
  end;
  Result := T.Handler(ArgsJSON, Err);
end;

var
  Pol: TSandboxPolicy;
  Res, WS: string;

begin
  { Unrestricted sandbox rooted at a real directory, so the shell runs
    for real and WorkDir is a known value we can assert against. }
  WS := GetTempDir;
  FillChar(Pol, SizeOf(Pol), 0);
  Pol.RestrictToWorkspace := False;
  ConfigureSandbox(Pol, WS);
  Reg := TToolRegistry.Create;
  RegisterShellTool(Reg);

  { --- line 1 is still exactly exit=N. Two consumers depend on this:
        Cmd.Learn matches exit=1/exit=2 at POSITION 1 for SCARS mining,
        and ToolLoop reads everything before the first newline as the
        progress-ledger entry. --- }
  Res := Run('{"command":"exit 0"}');
  if FirstLine(Res) <> 'exit=0' then
    Fail_('line 1 must be exactly "exit=0", got "' + FirstLine(Res) + '"');

  Res := Run('{"command":"exit 3"}');
  if FirstLine(Res) <> 'exit=3' then
    Fail_('line 1 must be exactly "exit=3", got "' + FirstLine(Res) + '"');

  { --- line 2 names the directory, on success as well as failure. A
        wrong-directory SUCCESS is the worse case: nothing prompts a
        second look. --- }
  Res := Run('{"command":"exit 0"}');
  if Copy(NthLine(Res, 2), 1, 4) <> 'cwd=' then
    Fail_('line 2 must start with cwd= on success, got "' + NthLine(Res, 2) + '"');

  Res := Run('{"command":"exit 1"}');
  if Copy(NthLine(Res, 2), 1, 4) <> 'cwd=' then
    Fail_('line 2 must start with cwd= on failure, got "' + NthLine(Res, 2) + '"');

  { --- an explicit cwd is echoed as the directory actually used --- }
  Res := Run('{"command":"exit 0","cwd":"' + StringReplace(WS, '\', '\\', [rfReplaceAll]) + '"}');
  if Pos('cwd=', Res) = 0 then
    Fail_('explicit cwd must still be reported');

  { --- the hint fires on a wrong-directory signature with a defaulted cwd --- }
  Res := Run('{"command":"echo \"make: *** No rule to make target x\" 1>&2; exit 2"}');
  if Pos('hint: cwd was not specified', Res) = 0 then
    Fail_('hint must fire on "No rule to make target" with a defaulted cwd');

  { --- NEGATIVE CONTROL 1: no hint when the model DID specify cwd. It
        already thought about geography; repeating it is noise. --- }
  Res := Run('{"command":"echo \"make: *** No rule to make target x\" 1>&2; exit 2",' +
             '"cwd":"' + StringReplace(WS, '\', '\\', [rfReplaceAll]) + '"}');
  if Pos('hint: cwd was not specified', Res) > 0 then
    Fail_('hint must NOT fire when cwd was passed explicitly');

  { --- NEGATIVE CONTROL 2: no hint on an unrelated failure. --- }
  Res := Run('{"command":"echo \"error: undefined reference to foo\" 1>&2; exit 1"}');
  if Pos('hint: cwd was not specified', Res) > 0 then
    Fail_('hint must NOT fire on an unrelated failure');

  { --- NEGATIVE CONTROL 3: no hint on success, even if the output
        happens to contain a matching phrase. --- }
  Res := Run('{"command":"echo \"no such file or directory\"; exit 0"}');
  if Pos('hint: cwd was not specified', Res) > 0 then
    Fail_('hint must NOT fire when the command succeeded');

  Reg.Free;

  if Failures > 0 then
  begin
    WriteLn(Format('shell_cwd_report_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('shell_cwd_report_tests: OK');
end.
