program doctor_tests;
(*
  Covers `pasclaw doctor`: both output modes and the exit-code contract.

  Runs the real binary against a synthetic PASCLAW_HOME so the checks see a
  known world -- a home with no config.json and no workspace exercises the
  WARN and FAIL paths, and a fully-populated one exercises PASS.

  The contract worth pinning is the exit code: 0 when nothing FAILs, 1
  otherwise. Anything reading `pasclaw doctor` in CI keys on that, and text
  wording is free to change.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes, Process,
  PasClaw.Utils;

var
  BinPath, TmpRoot: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

{ Run `pasclaw doctor <Args>` under Home; return the exit code, fill Output. }
function RunDoctor(const Home, Args: string; out Output: string): Integer;
var
  P: TProcess;
  M: TMemoryStream;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  Result := -1;
  Output := '';
  P := TProcess.Create(nil);
  M := TMemoryStream.Create;
  try
    P.Executable := BinPath;
    P.Parameters.Add('--no-color');
    P.Parameters.Add('doctor');
    if Args <> '' then P.Parameters.Add(Args);
    P.Environment.Add('PASCLAW_HOME=' + Home);
    P.Environment.Add('PATH=' + GetEnvironmentVariable('PATH'));
    P.Environment.Add('HOME=' + GetEnvironmentVariable('HOME'));
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      while P.Output.NumBytesAvailable > 0 do
      begin
        N := P.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then M.WriteBuffer(Buf, N);
      end;
      Sleep(20);
    end;
    Result := P.ExitCode;
    if M.Size > 0 then
    begin
      SetLength(Output, M.Size);
      M.Position := 0;
      M.ReadBuffer(Output[1], M.Size);
    end;
  finally
    M.Free;
    P.Free;
  end;
end;

procedure TestTextModeReportsEveryCheck;
var
  Home, Out_: string;
  Code: Integer;
begin
  Home := JoinPath(TmpRoot, 'home-text');
  ForceDirectories(JoinPath(Home, 'workspace'));
  Code := RunDoctor(Home, '', Out_);
  AssertTrue(Pos('config', Out_) > 0,    'text mode names the config check');
  AssertTrue(Pos('workspace', Out_) > 0, 'text mode names the workspace check');
  AssertTrue(Pos('memory', Out_) > 0,    'text mode names the memory check');
  AssertTrue(Pos('profile', Out_) > 0,   'text mode names the profile check');
  AssertTrue(Pos('toolchain', Out_) > 0, 'text mode names the toolchain check');
  AssertTrue(Pos('sessions', Out_) > 0,  'text mode names the sessions check');
  AssertTrue(Code = 0, 'a writable workspace with no config does not FAIL');
end;

procedure TestJsonModeParsesAndCarriesSixChecks;
var
  Home, Out_: string;
  Code, i, Count_: Integer;
begin
  Home := JoinPath(TmpRoot, 'home-json');
  ForceDirectories(JoinPath(Home, 'workspace'));
  Code := RunDoctor(Home, '--json', Out_);
  AssertTrue(Pos('[', Out_) > 0, '--json emits an array');
  Count_ := 0;
  for i := 1 to Length(Out_) - 6 do
    if Copy(Out_, i, 7) = '"check"' then Inc(Count_);
  AssertTrue(Count_ = 6, 'six checks in the JSON array (got ' +
                         IntToStr(Count_) + ')');
  AssertTrue(Pos('"level"', Out_) > 0,  '--json carries a level per check');
  AssertTrue(Pos('"reason"', Out_) > 0, '--json carries a reason per check');
  AssertTrue(Code = 0, '--json uses the same exit-code contract');
end;

procedure TestMissingWorkspaceFails;
var
  Home, Out_: string;
  Code: Integer;
begin
  { A home with no workspace directory at all: the workspace check FAILs,
    so the command must exit 1. }
  Home := JoinPath(TmpRoot, 'home-broken');
  ForceDirectories(Home);
  Code := RunDoctor(Home, '', Out_);
  AssertTrue(Pos('FAIL', Out_) > 0, 'a missing workspace reports FAIL');
  AssertTrue(Code = 1, 'a FAILing check exits 1 (got ' + IntToStr(Code) + ')');
end;

begin
  BinPath := 'build/pasclaw';
  if not FileExists(BinPath) then
  begin
    WriteLn('FAIL: build/pasclaw missing -- run `make all` first');
    Halt(1);
  end;
  BinPath := ExpandFileName(BinPath);
  TmpRoot := JoinPath(GetTempDir, 'pasclaw-doctor-tests-' +
                       IntToStr(Random(MaxInt)));
  ForceDirectories(TmpRoot);
  try
    TestTextModeReportsEveryCheck;
    TestJsonModeParsesAndCarriesSixChecks;
    TestMissingWorkspaceFails;
    WriteLn('doctor_tests: OK');
  finally
    try RemoveDir(TmpRoot); except end;
  end;
end.
