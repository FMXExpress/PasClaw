(*
  PasClaw.Platform - cross-toolchain process primitives.

  Two surfaces:

    RunOneShot       Spawn a shell command, capture stdout+stderr, wait
                     for exit. Caps output at 1 MiB. Used by Tools.Shell
                     and Skills.Loader.

    TStdioProcess    Long-lived child process with bidirectional pipes.
                     Used by MCP.StdioClient. Write JSON-RPC frames in,
                     read responses out. Non-blocking-ish reads with a
                     small per-call buffer; ReadAvailable returns however
                     much is currently in the pipe.

  Three implementations selected at compile time:
    {$IFDEF FPC}                use fcl-process (works on every FPC target --
                                Windows, Linux, macOS, BSD, ...)
    {$ELSE} {$IFDEF MSWINDOWS}  CreateProcess + CreatePipe + ReadFile/WriteFile
    {$ELSE}                     Posix.Unistd pipe / fork / execvp / waitpid.
                                Covers every Delphi POSIX target: LINUX64,
                                MACOS64 (Intel + ARM), and the mobile
                                targets where fork is permitted.

  The interface is identical across all three so callers stay free of
  IFDEFs.
*)
unit PasClaw.Platform;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  OneShotMaxBytes = 1024 * 1024;  { 1 MiB cap on captured output }
  ReadBufferSize  = 4096;

type
  TStdioProcess = class
  private
    {$IFDEF FPC}
    FProcess: TObject;   { TProcess; declared as TObject to keep fcl-process
                           out of the public interface }
    {$ENDIF}
    {$IFNDEF FPC}{$IFDEF MSWINDOWS}
    FProcHandle: THandle;
    FThreadHandle: THandle;
    FStdinWrite:  THandle;
    FStdoutRead:  THandle;
    {$ENDIF}{$ENDIF}
    {$IFNDEF FPC}{$IFNDEF MSWINDOWS}
    FPid:        Integer;
    FStdinFd:    Integer;   { write end of child stdin pipe }
    FStdoutFd:   Integer;   { read end of child stdout pipe }
    {$ENDIF}{$ENDIF}
    FStarted: Boolean;
    FExited:  Boolean;
    FExitCode: Integer;
  public
    constructor Create;
    destructor  Destroy; override;

    { Spawn Cmd with each entry of Args as a separate argv element. Returns
      True on successful spawn, False on failure (errno-style; check log).

      When MergeStderr is True the child's stderr is redirected into the
      same pipe as stdout, so ReadAvailable surfaces both streams. This
      is what shell-style "capture combined output" callers want -- git
      clone (progress + fatals on stderr) and RunOneShot rely on it.
      The default (False) leaves stderr inheriting from the parent
      process so a long-lived child's log lines reach the user's
      terminal instead of polluting the JSON-RPC stream on stdout --
      the contract MCP stdio servers expect.

      WorkingDir, when non-empty, becomes the child's current working
      directory. Set in the child only -- the parent's cwd is never
      touched. This matters because PasClaw's gateway may fan multiple
      shell_exec calls out concurrently, and earlier code used a
      parent-side ChDir + restore that raced under load. Implemented
      as CreateProcessW's lpCurrentDirectory on Windows, chdir() in
      the forked child on POSIX, and TProcess.CurrentDirectory on FPC. }
    function Spawn(const Cmd: string; Args: TStrings;
                    MergeStderr: Boolean = False;
                    const WorkingDir: string = ''): Boolean;

    { Send Buf to child stdin. Returns the byte count written. }
    function WriteBytes(const Buf; Count: Integer): Integer;
    function WriteLineUTF8(const S: string): Boolean;

    { Read up to BufSize bytes from child stdout. Returns the count actually
      read; 0 = no data available right now (or child has exited and pipe
      is drained). Does not block longer than ~50 ms. }
    function ReadAvailable(var Buf; BufSize: Integer): Integer;

    { True until the process has been reaped. }
    function Running: Boolean;

    procedure Terminate;
    property ExitCode: Integer read FExitCode;
  end;

(* Run a shell command; capture combined stdout+stderr (UTF-8) up to
   OneShotMaxBytes. Returns the exit code; -1 on failure to spawn.

   WorkingDir is the directory the child process starts in. Pass an
   empty string to inherit the parent's cwd (legacy behaviour); pass
   an absolute path to bind the shell there -- Tool_Shell uses this
   to pin the shell to the sandbox workspace so a command can't
   reference relative paths above the boundary. *)
function RunOneShot   (const Cmd: string;                  out Output: string): Integer; overload;
function RunOneShot   (const Cmd, WorkingDir: string;      out Output: string): Integer; overload;

implementation

uses
  {$IFDEF FPC}
    Process
  {$ELSE}{$IFDEF MSWINDOWS}
    Winapi.Windows
  {$ELSE}
    Posix.Base, Posix.Unistd, Posix.Stdlib, Posix.SysWait,
    Posix.Signal, Posix.SysTypes, Posix.SysSelect
  {$ENDIF}{$ENDIF};

{$IFDEF FPC}
(* ----- FPC backend (fcl-process) ----- *)

type
  TInternalProcess = Process.TProcess;

constructor TStdioProcess.Create;
begin
  inherited Create;
  FProcess := nil;
end;

destructor TStdioProcess.Destroy;
begin
  Terminate;
  if FProcess <> nil then begin TInternalProcess(FProcess).Free; FProcess := nil; end;
  inherited Destroy;
end;

function TStdioProcess.Spawn(const Cmd: string; Args: TStrings;
                              MergeStderr: Boolean;
                              const WorkingDir: string): Boolean;
var
  P: TInternalProcess;
  i: Integer;
begin
  if FStarted then Exit(False);
  P := TInternalProcess.Create(nil);
  P.Executable := Cmd;
  for i := 0 to Args.Count - 1 do P.Parameters.Add(Args[i]);
  if WorkingDir <> '' then P.CurrentDirectory := WorkingDir;
  if MergeStderr then
    P.Options := [poUsePipes, poStderrToOutPut]
  else
    P.Options := [poUsePipes];
  try
    P.Execute;
  except
    P.Free;
    Exit(False);
  end;
  FProcess := P;
  FStarted := True;
  Result := True;
end;

function TStdioProcess.WriteBytes(const Buf; Count: Integer): Integer;
begin
  Result := 0;
  if (FProcess = nil) or not TInternalProcess(FProcess).Running then Exit;
  try
    Result := TInternalProcess(FProcess).Input.Write(Buf, Count);
  except
    Result := 0;
  end;
end;

function TStdioProcess.WriteLineUTF8(const S: string): Boolean;
var
  Line: string;
begin
  Line := S + #10;
  Result := WriteBytes(Pointer(Line)^, Length(Line)) = Length(Line);
end;

function TStdioProcess.ReadAvailable(var Buf; BufSize: Integer): Integer;
var
  P: TInternalProcess;
  Avail, Waited: Integer;
begin
  Result := 0;
  if FProcess = nil then Exit;
  P := TInternalProcess(FProcess);
  Waited := 0;
  while True do
  begin
    Avail := P.Output.NumBytesAvailable;
    if Avail > 0 then
    begin
      if Avail > BufSize then Avail := BufSize;
      Result := P.Output.Read(Buf, Avail);
      Exit;
    end;
    if (not P.Running) then Exit;
    Sleep(10);
    Inc(Waited, 10);
    if Waited >= 50 then Exit;
  end;
end;

function TStdioProcess.Running: Boolean;
begin
  if (FProcess = nil) or not FStarted then Exit(False);
  Result := TInternalProcess(FProcess).Running;
  if not Result and not FExited then
  begin
    FExited := True;
    try FExitCode := TInternalProcess(FProcess).ExitStatus; except FExitCode := -1; end;
  end;
end;

procedure TStdioProcess.Terminate;
begin
  if (FProcess <> nil) and TInternalProcess(FProcess).Running then
    try TInternalProcess(FProcess).Terminate(0); except end;
end;

function RunOneShot(const Cmd, WorkingDir: string; out Output: string): Integer;
var
  P: TInternalProcess;
  M: TMemoryStream;
  Buf: array[0..ReadBufferSize - 1] of Byte;
  N, Total: Integer;
begin
  Result := -1;
  Output := '';
  P := TInternalProcess.Create(nil);
  M := TMemoryStream.Create;
  try
    {$IFDEF MSWINDOWS}
    P.Executable := 'cmd.exe';
    P.Parameters.Add('/C'); P.Parameters.Add(Cmd);
    {$ELSE}
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c'); P.Parameters.Add(Cmd);
    {$ENDIF}
    if WorkingDir <> '' then P.CurrentDirectory := WorkingDir;
    P.Options := [poUsePipes, poStderrToOutPut];
    try P.Execute; except Exit; end;
    Total := 0;
    while P.Running or (P.Output.NumBytesAvailable > 0) do
    begin
      while P.Output.NumBytesAvailable > 0 do
      begin
        N := P.Output.Read(Buf, SizeOf(Buf));
        if N > 0 then begin M.WriteBuffer(Buf, N); Inc(Total, N); end;
        if Total > OneShotMaxBytes then begin P.Terminate(124); Break; end;
      end;
      Sleep(20);
    end;
    Result := P.ExitStatus;
    SetLength(Output, M.Size);
    if M.Size > 0 then begin M.Position := 0; M.ReadBuffer(Output[1], M.Size); end;
  finally
    M.Free;
    P.Free;
  end;
end;

{$ELSE}
{$IFDEF MSWINDOWS}
(* ----- Delphi/Windows backend (Win32 API direct) ----- *)

constructor TStdioProcess.Create;
begin
  inherited Create;
  FProcHandle   := 0;
  FThreadHandle := 0;
  FStdinWrite   := 0;
  FStdoutRead   := 0;
end;

destructor TStdioProcess.Destroy;
begin
  Terminate;
  if FStdinWrite  <> 0 then CloseHandle(FStdinWrite);
  if FStdoutRead  <> 0 then CloseHandle(FStdoutRead);
  if FProcHandle  <> 0 then CloseHandle(FProcHandle);
  if FThreadHandle <> 0 then CloseHandle(FThreadHandle);
  inherited Destroy;
end;

function QuoteArg(const S: string): string;
begin
  if (Pos(' ', S) > 0) or (Pos('"', S) > 0) then
    Result := '"' + StringReplace(S, '"', '\"', [rfReplaceAll]) + '"'
  else
    Result := S;
end;

function TStdioProcess.Spawn(const Cmd: string; Args: TStrings;
                              MergeStderr: Boolean;
                              const WorkingDir: string): Boolean;
var
  SA: TSecurityAttributes;
  SI: TStartupInfoW;
  PI: TProcessInformation;
  ChildStdinRead, ChildStdoutWrite: THandle;
  CmdLine, CurDirW: string;
  CurDirPtr: PWideChar;
  i: Integer;
begin
  if FStarted then Exit(False);
  SA.nLength := SizeOf(SA);
  SA.bInheritHandle := True;
  SA.lpSecurityDescriptor := nil;

  { stdout pipe: parent reads, child writes }
  if not CreatePipe(FStdoutRead, ChildStdoutWrite, @SA, 0) then Exit(False);
  SetHandleInformation(FStdoutRead, HANDLE_FLAG_INHERIT, 0);
  { stdin pipe: parent writes, child reads }
  if not CreatePipe(ChildStdinRead, FStdinWrite, @SA, 0) then
  begin
    CloseHandle(FStdoutRead); CloseHandle(ChildStdoutWrite);
    Exit(False);
  end;
  SetHandleInformation(FStdinWrite, HANDLE_FLAG_INHERIT, 0);

  ZeroMemory(@SI, SizeOf(SI));
  SI.cb := SizeOf(SI);
  SI.dwFlags := STARTF_USESHOWWINDOW or STARTF_USESTDHANDLES;
  SI.wShowWindow := SW_HIDE;
  SI.hStdInput  := ChildStdinRead;
  SI.hStdOutput := ChildStdoutWrite;
  { stderr: merge into stdout pipe iff caller asked. Otherwise let it
    inherit from the parent process so the child's diagnostics reach
    the user's terminal instead of mixing with stdout (the contract
    MCP stdio servers expect for their JSON-RPC frames). }
  if MergeStderr then
    SI.hStdError := ChildStdoutWrite
  else
    SI.hStdError := GetStdHandle(STD_ERROR_HANDLE);

  CmdLine := QuoteArg(Cmd);
  for i := 0 to Args.Count - 1 do CmdLine := CmdLine + ' ' + QuoteArg(Args[i]);

  { Pass WorkingDir via lpCurrentDirectory so the child's cwd is set
    by the kernel at CreateProcess time -- no need for a parent-side
    ChDir + restore, which would race under concurrent shell_exec. }
  if WorkingDir <> '' then
  begin
    CurDirW := WorkingDir;
    CurDirPtr := PWideChar(CurDirW);
  end
  else
    CurDirPtr := nil;

  if not CreateProcessW(nil, PWideChar(CmdLine), nil, nil, True,
                        CREATE_NO_WINDOW, nil, CurDirPtr, SI, PI) then
  begin
    CloseHandle(FStdoutRead); CloseHandle(ChildStdoutWrite);
    CloseHandle(ChildStdinRead); CloseHandle(FStdinWrite);
    FStdoutRead := 0; FStdinWrite := 0;
    Exit(False);
  end;

  { Close child-side ends in the parent }
  CloseHandle(ChildStdinRead);
  CloseHandle(ChildStdoutWrite);

  FProcHandle   := PI.hProcess;
  FThreadHandle := PI.hThread;
  FStarted := True;
  Result := True;
end;

function TStdioProcess.WriteBytes(const Buf; Count: Integer): Integer;
var
  W: DWORD;
begin
  Result := 0;
  if FStdinWrite = 0 then Exit;
  if not WriteFile(FStdinWrite, Buf, Count, W, nil) then Exit(0);
  Result := Integer(W);
end;

function TStdioProcess.WriteLineUTF8(const S: string): Boolean;
var
  Line: UTF8String;
begin
  Line := UTF8String(S) + #10;
  Result := WriteBytes(Pointer(Line)^, Length(Line)) = Length(Line);
end;

function TStdioProcess.ReadAvailable(var Buf; BufSize: Integer): Integer;
var
  Avail, R: DWORD;
  Waited: Integer;
begin
  Result := 0;
  if FStdoutRead = 0 then Exit;
  Waited := 0;
  while True do
  begin
    Avail := 0;
    if not PeekNamedPipe(FStdoutRead, nil, 0, nil, @Avail, nil) then Exit(0);
    if Avail > 0 then
    begin
      if Integer(Avail) > BufSize then Avail := DWORD(BufSize);
      if not ReadFile(FStdoutRead, Buf, Avail, R, nil) then Exit(0);
      Exit(Integer(R));
    end;
    if WaitForSingleObject(FProcHandle, 0) = WAIT_OBJECT_0 then Exit;
    Sleep(10);
    Inc(Waited, 10);
    if Waited >= 50 then Exit;
  end;
end;

function TStdioProcess.Running: Boolean;
var
  Code: DWORD;
begin
  if (FProcHandle = 0) or not FStarted then Exit(False);
  if not GetExitCodeProcess(FProcHandle, Code) then Exit(False);
  Result := Code = STILL_ACTIVE;
  if (not Result) and (not FExited) then
  begin
    FExited := True;
    FExitCode := Integer(Code);
  end;
end;

procedure TStdioProcess.Terminate;
begin
  if (FProcHandle <> 0) and Running then
    TerminateProcess(FProcHandle, 0);
end;

function RunOneShot(const Cmd, WorkingDir: string; out Output: string): Integer;
var
  P: TStdioProcess;
  Args: TStringList;
  Buf: array[0..ReadBufferSize - 1] of Byte;
  Total, N: Integer;
  Acc: TMemoryStream;
  Bytes: TBytes;
begin
  Result := -1;
  Output := '';
  P := TStdioProcess.Create;
  Args := TStringList.Create;
  Acc := TMemoryStream.Create;
  try
    Args.Add('/C'); Args.Add(Cmd);
    { WorkingDir flows into CreateProcessW.lpCurrentDirectory inside
      Spawn -- no parent-side ChDir, so two RunOneShot calls firing in
      parallel from the gateway can't trample each other's cwd. }
    if not P.Spawn('cmd.exe', Args, {MergeStderr=}True, WorkingDir) then Exit;
    Total := 0;
    while True do
    begin
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        Acc.WriteBuffer(Buf, N);
        Inc(Total, N);
        if Total > OneShotMaxBytes then begin P.Terminate; Break; end;
      end
      else if not P.Running then Break;
    end;
    WaitForSingleObject(P.FProcHandle, INFINITE);
    P.Running;   { latches ExitCode via the side effect }
    Result := P.ExitCode;
    if Acc.Size > 0 then
    begin
      SetLength(Bytes, Acc.Size);
      Acc.Position := 0;
      Acc.ReadBuffer(Bytes[0], Acc.Size);
      Output := TEncoding.UTF8.GetString(Bytes);
    end;
  finally
    Acc.Free;
    Args.Free;
    P.Free;
  end;
end;

{$ELSE}
(* ----- Delphi/POSIX backend ----- *)

const
  STDIN_FILENO  = 0;
  STDOUT_FILENO = 1;
  STDERR_FILENO = 2;

type
  { Fixed-size pipe fd pair; pass by var so the C ABI receives a bare pointer,
    not the (High,Ptr) pair that Delphi's open-array convention would send. }
  TPipeFDs = array[0..1] of Integer;

function pipe(var pipefds: TPipeFDs): Integer; cdecl;
  external libc name _PU + 'pipe';
function execvp(const path: PAnsiChar; const argv: PPAnsiChar): Integer; cdecl;
  external libc name _PU + 'execvp';
function chdir(const path: PAnsiChar): Integer; cdecl;
  external libc name _PU + 'chdir';

constructor TStdioProcess.Create;
begin
  inherited Create;
  FPid := 0;
  FStdinFd := -1;
  FStdoutFd := -1;
end;

destructor TStdioProcess.Destroy;
begin
  Terminate;
  if FStdinFd  >= 0 then __close(FStdinFd);
  if FStdoutFd >= 0 then __close(FStdoutFd);
  inherited Destroy;
end;

function TStdioProcess.Spawn(const Cmd: string; Args: TStrings;
                              MergeStderr: Boolean;
                              const WorkingDir: string): Boolean;
var
  StdinPipe, StdoutPipe: TPipeFDs;
  Pid: pid_t;
  i: Integer;
  Argv: array of Pointer;
  ArgsI: array of RawByteString;
  Path, WDPath: AnsiString;
begin
  if FStarted then Exit(False);
  if pipe(StdinPipe)  <> 0 then Exit(False);
  if pipe(StdoutPipe) <> 0 then begin __close(StdinPipe[0]); __close(StdinPipe[1]); Exit(False); end;

  Pid := fork;
  if Pid < 0 then
  begin
    { fork() failed -- parent still owns both pipes' fds. Close them
      before returning or we'd leak 4 fds per failed spawn (matters
      under the gateway's burst-spawn pattern: a low ulimit can EMFILE
      quickly). }
    __close(StdinPipe[0]);  __close(StdinPipe[1]);
    __close(StdoutPipe[0]); __close(StdoutPipe[1]);
    Exit(False);
  end;

  if Pid = 0 then
  begin
    { child }
    dup2(StdinPipe[0],  STDIN_FILENO);
    dup2(StdoutPipe[1], STDOUT_FILENO);
    { stderr: merge into stdout pipe iff caller asked. Otherwise leave
      it pointing at whatever the parent's stderr is (terminal, log
      file, etc.) so child diagnostics don't pollute the stdout
      JSON-RPC stream MCP stdio servers write. }
    if MergeStderr then
      dup2(StdoutPipe[1], STDERR_FILENO);
    __close(StdinPipe[0]);  __close(StdinPipe[1]);
    __close(StdoutPipe[0]); __close(StdoutPipe[1]);

    { Bind cwd in the child rather than parent-side ChDir + restore.
      Safe for concurrent shell_exec because the parent's cwd is
      untouched. chdir failure is non-fatal here -- exec runs anyway
      and either picks the wrong files (rare, since callers pass
      absolute paths) or returns a non-zero status the parent will
      surface. }
    if WorkingDir <> '' then
    begin
      WDPath := UTF8Encode(WorkingDir);
      chdir(PAnsiChar(WDPath));
    end;

    Path := UTF8Encode(Cmd);
    SetLength(ArgsI, Args.Count);
    SetLength(Argv, Args.Count + 2);
    Argv[0] := PAnsiChar(Path);
    for i := 0 to Args.Count - 1 do
    begin
      ArgsI[i] := UTF8Encode(Args[i]);
      Argv[i + 1] := PAnsiChar(ArgsI[i]);
    end;
    Argv[Args.Count + 1] := nil;
    execvp(PAnsiChar(Path), PPAnsiChar(@Argv[0]));
    _exit(127);
  end;

  { parent }
  __close(StdinPipe[0]);
  __close(StdoutPipe[1]);
  FStdinFd  := StdinPipe[1];
  FStdoutFd := StdoutPipe[0];
  FPid := Pid;
  FStarted := True;
  Result := True;
end;

function TStdioProcess.WriteBytes(const Buf; Count: Integer): Integer;
begin
  if FStdinFd < 0 then Exit(0);
  Result := __write(FStdinFd, Buf, Count);
end;

function TStdioProcess.WriteLineUTF8(const S: string): Boolean;
var
  Line: UTF8String;
begin
  Line := UTF8String(S) + #10;
  Result := WriteBytes(Pointer(Line)^, Length(Line)) = Length(Line);
end;

function TStdioProcess.ReadAvailable(var Buf; BufSize: Integer): Integer;
var
  Status, R, Waited: Integer;
  TimeoutFd: TFDSet;
  Tv: timeval;
begin
  Result := 0;
  if FStdoutFd < 0 then Exit;
  Waited := 0;
  while True do
  begin
    FillChar(TimeoutFd, SizeOf(TimeoutFd), 0);
    FD_SET(FStdoutFd, TimeoutFd);
    Tv.tv_sec  := 0;
    Tv.tv_usec := 10 * 1000;   { 10 ms }
    Status := select(FStdoutFd + 1, @TimeoutFd, nil, nil, @Tv);
    if Status > 0 then
    begin
      R := __read(FStdoutFd, Buf, BufSize);
      if R > 0 then Exit(R);
      Exit;
    end;
    if not Running then Exit;
    Inc(Waited, 10);
    if Waited >= 50 then Exit;
  end;
end;

function TStdioProcess.Running: Boolean;
var
  Status, R: Integer;
begin
  if (FPid = 0) or not FStarted then Exit(False);
  R := waitpid(FPid, Status, WNOHANG);
  if R = 0 then Exit(True);   { still running }
  if R = FPid then
  begin
    FExited := True;
    if WIFEXITED(Status) then FExitCode := WEXITSTATUS(Status)
    else FExitCode := -1;
  end;
  Result := False;
end;

procedure TStdioProcess.Terminate;
begin
  if (FPid <> 0) and Running then
    kill(FPid, SIGTERM);
end;

function RunOneShot(const Cmd, WorkingDir: string; out Output: string): Integer;
var
  P: TStdioProcess;
  Args: TStringList;
  Buf: array[0..ReadBufferSize - 1] of Byte;
  Total, N, Status: Integer;
  Acc: TMemoryStream;
  Bytes: TBytes;
begin
  Result := -1;
  Output := '';
  P := TStdioProcess.Create;
  Args := TStringList.Create;
  Acc := TMemoryStream.Create;
  try
    Args.Add('-c'); Args.Add(Cmd);
    { WorkingDir flows into chdir() in the forked child inside Spawn --
      no parent-side ChDir, so two RunOneShot calls firing in parallel
      from the gateway can't trample each other's cwd. }
    if not P.Spawn('/bin/sh', Args, {MergeStderr=}True, WorkingDir) then Exit;
    Total := 0;
    while True do
    begin
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        Acc.WriteBuffer(Buf, N);
        Inc(Total, N);
        if Total > OneShotMaxBytes then begin P.Terminate; Break; end;
      end
      else if not P.Running then Break;
    end;
    waitpid(P.FPid, Status, 0);
    if WIFEXITED(Status) then Result := WEXITSTATUS(Status) else Result := -1;
    if Acc.Size > 0 then
    begin
      SetLength(Bytes, Acc.Size);
      Acc.Position := 0;
      Acc.ReadBuffer(Bytes[0], Acc.Size);
      Output := TEncoding.UTF8.GetString(Bytes);
    end;
  finally
    Acc.Free;
    Args.Free;
    P.Free;
  end;
end;

{$ENDIF}
{$ENDIF}

function RunOneShot(const Cmd: string; out Output: string): Integer;
begin
  Result := RunOneShot(Cmd, '', Output);
end;

end.
