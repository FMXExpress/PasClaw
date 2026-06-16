program env_inject_tests;
(*
  Pins env-var injection into spawned children. The bug this guards:
  on Delphi builds RunOneShotWithEnv used to ignore ExtraEnv, so
  execute_code's tool-RPC vars never reached the child.

  This sandbox compiles the FPC backend, so we exercise (a) the public
  RunOneShotWithEnv contract and (b) the new TStdioProcess.Spawn ExtraEnv
  path directly. The Delphi Windows (CREATE_UNICODE_ENVIRONMENT block) and
  Delphi POSIX (setenv-in-child) backends mirror the same contract.

  Unix-only (drives /bin/sh).
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

procedure Expect(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

{$IFDEF UNIX}
{ Capture merged stdout of `sh -c <Shell>` spawned via TStdioProcess with the
  given environment overrides -- exercises the new Spawn ExtraEnv path. }
function CaptureWithEnv(const Shell: string; Env: TStrings): string;
var
  P: TStdioProcess;
  Args: TStringList;
  M: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: Integer;
  Bytes: TBytes;
begin
  Result := '';
  P := TStdioProcess.Create;
  Args := TStringList.Create;
  M := TMemoryStream.Create;
  try
    Args.Add('-c'); Args.Add(Shell);
    if not P.Spawn('/bin/sh', Args, True, '', Env) then Fail_('spawn failed');
    while True do
    begin
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then M.WriteBuffer(Buf, N)
      else if not P.Running then Break
      else Sleep(10);
    end;
    if M.Size > 0 then
    begin
      SetLength(Bytes, M.Size);
      M.Position := 0;
      M.ReadBuffer(Bytes[0], M.Size);
      SetString(Result, PAnsiChar(@Bytes[0]), Length(Bytes));
    end;
  finally
    M.Free; Args.Free; P.Free;
  end;
end;

procedure RunChecks;
var
  Env: TStringList;
  Out_: string;
  Code: Integer;
begin
  { 1. Spawn injects an ExtraEnv var into the child. }
  Env := TStringList.Create;
  try
    Env.Add('PASCLAW_ENVTEST=hello123');
    Expect(CaptureWithEnv('printf %s "$PASCLAW_ENVTEST"', Env) = 'hello123',
           'Spawn did not inject ExtraEnv var');
    { 2. Parent env survives the override merge (Environment replaces, so the
         child would lose PATH if we didn''t fold parent env back in). }
    Expect(CaptureWithEnv('printf %s "$PATH"', Env) <> '',
           'parent PATH lost when ExtraEnv set');
  finally
    Env.Free;
  end;

  { 3. ExtraEnv wins over an inherited var of the same name. }
  Env := TStringList.Create;
  try
    Env.Add('PATH=OVERRIDDEN');
    Expect(CaptureWithEnv('printf %s "$PATH"', Env) = 'OVERRIDDEN',
           'ExtraEnv did not override inherited PATH');
  finally
    Env.Free;
  end;

  { 4. nil ExtraEnv = no injection (var unset, child still runs). }
  Expect(CaptureWithEnv('printf %s "${PASCLAW_ENVTEST:-MISSING}"', nil) = 'MISSING',
         'nil ExtraEnv unexpectedly set a var');

  { 5. Public RunOneShotWithEnv end-to-end. }
  Env := TStringList.Create;
  try
    Env.Add('PASCLAW_ENVTEST=roundtrip');
    Code := RunOneShotWithEnv('printf %s "$PASCLAW_ENVTEST"', '', Env, Out_);
    Expect(Code = 0, 'RunOneShotWithEnv nonzero exit');
    Expect(Trim(Out_) = 'roundtrip', 'RunOneShotWithEnv did not pass the var: ' + Out_);
  finally
    Env.Free;
  end;
end;
{$ENDIF}

begin
  {$IFDEF UNIX}
  RunChecks;
  {$ENDIF}
  WriteLn('env_inject_tests: OK');
end.
