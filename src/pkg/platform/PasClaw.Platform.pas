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
{$IFDEF FPC}
  {$CODEPAGE UTF8}            { Tag this unit's AnsiStrings as UTF-8 so
                                the UTF-8 bytes DecodeShellOutputBytes
                                builds survive the function return on
                                Windows. Without this, FPC implicitly
                                transcodes UTF-8 -> system ANSI
                                codepage (CP1252 on English Windows,
                                CP932 on Japanese, etc.) at the result
                                assignment, dropping characters that
                                aren't representable in the system CP
                                -- exactly the round-trip loss this
                                whole patch is trying to prevent. }
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

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

(* Same as RunOneShot, but adds ExtraEnv (a TStringList of
   "NAME=VALUE" lines) to the child process's environment on top
   of the parent's inherited env. The child sees ParentEnv +
   ExtraEnv with ExtraEnv winning on key collisions. Used by
   execute_code to pass PASCLAW_TOOL_RPC_INFO down to the spawned
   script -- a per-call temp value that mustn't leak into the
   parent process or any other concurrent RunOneShot. *)
function RunOneShotWithEnv(const Cmd, WorkingDir: string;
                            ExtraEnv: TStringList;
                            out Output: string): Integer;

(* Run a program directly from its argv vector -- NO shell. Captures
   combined stdout+stderr (UTF-8) up to OneShotMaxBytes; returns the
   exit code, -1 on spawn failure, 124 if output was truncated and the
   child killed.

   Unlike RunOneShot there is no `/bin/sh -c` or `cmd.exe /C` wrapper,
   so Args reach the program verbatim: no word-splitting, no glob, no
   quote-stripping, and -- crucially on Windows -- no cmd.exe `%VAR%`
   percent-expansion of the arguments. Callers that assemble a command
   from model/untrusted text (the Docker backend) use this to keep that
   text out of a host shell entirely. *)
function RunArgvCapture(const Exe: string; Args: TStrings;
                        const WorkingDir: string;
                        out Output: string;
                        TimeoutMs: Integer = 0): Integer;

(* Decode a byte buffer captured from a child shell's stdout/stderr
   into a UTF-8-encoded Pascal string suitable for tool output. On
   Windows, cmd.exe writes its stdout in the SYSTEM OEM CODEPAGE
   (CP437 on US English, CP866 on Cyrillic, CP932 on Japanese,
   etc.) -- NOT UTF-8. Decoding those bytes as UTF-8 produces
   mojibake on any non-ASCII byte and was the documented cause of
   the "directory exists?" failures on D:/E:/F: drives with
   non-ASCII path components. We detect the OEM codepage via
   GetOEMCP and route through MultiByteToWideChar to UTF-16, then
   UTF-8 encode. POSIX shells already output UTF-8 so the POSIX
   path is a plain UTF-8 decode -- unchanged from the previous
   behaviour, just routed through one helper.

   Codepage parameter: 0 (default) means "auto-detect per platform"
   -- Windows uses GetOEMCP, POSIX is fixed UTF-8. Explicit
   non-zero values pin the codepage and are used by tests so a
   known CP437 byte sequence decodes the same way on Linux as it
   would on a Windows operator's box. ByteCount lets the caller
   pass only the prefix of a larger buffer; pass -1 for "all of
   Bytes". *)
function DecodeShellOutputBytes(const Bytes: TBytes;
                                ByteCount: Integer = -1;
                                Codepage: UInt32 = 0): string;

implementation

uses
  {$IFDEF FPC}
    Process
    {$IFDEF MSWINDOWS}, Windows {$ENDIF}   { GetOEMCP + MultiByteToWideChar
                                             for cmd.exe output decode }
  {$ELSE}{$IFDEF MSWINDOWS}
    Winapi.Windows
  {$ELSE}
    Posix.Base, Posix.Unistd, Posix.Stdlib, Posix.SysWait,
    Posix.Signal, Posix.SysTypes, Posix.SysSelect,
    Posix.SysTime                  { timeval / Ptimeval for select() --
                                     NOT re-exported by Posix.SysSelect }
  {$ENDIF}{$ENDIF};

function DecodeShellOutputBytes(const Bytes: TBytes;
                                ByteCount: Integer;
                                Codepage: UInt32): string;
{$IFDEF MSWINDOWS}
const
  CP_UTF8_LOCAL              = 65001;
  MB_ERR_INVALID_CHARS_LOCAL = $00000008;
{$ENDIF}
var
  Len: Integer;
  {$IFDEF MSWINDOWS}
  WideLen: Integer;
  Wide: UnicodeString;
  CP: UInt32;
  {$ELSE}
  Enc: TEncoding;
  {$ENDIF}
begin
  Result := '';
  if ByteCount < 0 then Len := Length(Bytes) else Len := ByteCount;
  if Len <= 0 then Exit;
  if Len > Length(Bytes) then Len := Length(Bytes);

  {$IFDEF MSWINDOWS}
  if Codepage <> 0 then
    CP := Codepage
  else
  begin
    { Auto-detect between UTF-8 and OEM. PR #237's first attempt
      pinned GetConsoleOutputCP (wrong: returns OUR console's CP,
      not the spawned cmd.exe's piped-output CP). The revert to
      unconditional GetOEMCP was right for cmd.exe (which pipes
      OEM regardless of chcp) but wrong for pwsh -- PowerShell 6+
      defaults to UTF-8 stdout, so a `Write-Output 'résumé'` from
      execute_code's pwsh branch produces UTF-8 bytes that GetOEMCP
      would mojibake as CP437. Codex P2 on PR #239.

      Heuristic: try strict UTF-8 (MB_ERR_INVALID_CHARS) first.
      Valid UTF-8 -> use it (pwsh / chcp 65001 / Linux on Wine).
      Invalid sequence anywhere -> fall back to OEM (cmd.exe's
      piped output).

      This is robust because:
        - Pure ASCII (most output) is valid UTF-8 -> taken either way.
        - cmd's CP437 non-ASCII bytes (0x80-0xFF) are typically
          invalid UTF-8 lead bytes -- e.g. 0x82 (é in CP437) has
          binary 10000010 which is a UTF-8 continuation marker, not
          a lead byte, so it fails MB_ERR_INVALID_CHARS.
        - pwsh UTF-8 output (multi-byte sequences for é/résumé/etc.)
          parses cleanly.

      Edge case: OEM bytes that happen to coincide with a valid
      UTF-8 sequence (e.g. exactly a 2-byte CP437 pair that maps
      to a real Unicode codepoint via UTF-8 decoding). This is
      vanishingly unlikely for filename / dir output. }
    if MultiByteToWideChar(CP_UTF8_LOCAL, MB_ERR_INVALID_CHARS_LOCAL,
                            PAnsiChar(@Bytes[0]), Len, nil, 0) > 0 then
      CP := CP_UTF8_LOCAL
    else
      CP := GetOEMCP;
  end;
  { Pass 1: discover the wide-char buffer size we need. }
  WideLen := MultiByteToWideChar(CP, 0, PAnsiChar(@Bytes[0]), Len, nil, 0);
  if WideLen <= 0 then
  begin
    { Fall back to UTF-8 if the OEM decode failed -- better than
      returning empty. Catches the case where GetOEMCP returned an
      unsupported codepage on a weird locale. }
    Result := UTF8Encode(TEncoding.UTF8.GetString(Bytes, 0, Len));
    Exit;
  end;
  SetLength(Wide, WideLen);
  MultiByteToWideChar(CP, 0, PAnsiChar(@Bytes[0]), Len, PWideChar(Wide), WideLen);
  { Wide -> UTF-8. UTF8Encode is the cross-compiler explicit form;
    implicit assignment would go via DefaultSystemCodepage which on
    Windows is the ANSI codepage, not UTF-8 -- exactly the bug we're
    avoiding. }
  Result := UTF8Encode(Wide);
  {$ELSE}
  { POSIX shells (bash, sh, zsh) output UTF-8 -- just decode as such.
    Codepage param is honoured for tests so a fixture exercising the
    Windows OEM path can call from Linux with an explicit CP. The
    runtime always passes 0 on POSIX so the test-only branch never
    fires in production. 65001 = CP_UTF8 (named constant lives in
    Windows.pas which isn't imported on POSIX). }
  if (Codepage = 0) or (Codepage = 65001) then
  begin
    Result := UTF8Encode(TEncoding.UTF8.GetString(Bytes, 0, Len));
    Exit;
  end;
  { TEncoding.GetEncoding hands back a freshly-allocated instance the
    caller must Free; route through UTF8Encode for the implicit
    UnicodeString -> string conversion so the bytes land as UTF-8
    regardless of DefaultSystemCodepage. }
  Enc := TEncoding.GetEncoding(Codepage);
  try
    Result := UTF8Encode(Enc.GetString(Bytes, 0, Len));
  finally
    Enc.Free;
  end;
  {$ENDIF}
end;

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
  Bytes: TBytes;
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
    if M.Size > 0 then
    begin
      { Hand the captured bytes to the shared decoder rather than
        copying them straight into the Pascal string. On Windows
        cmd.exe writes its stdout in the system OEM codepage, not
        UTF-8 or the system ANSI codepage -- without a proper
        decode any non-ASCII path or filename surfaces as mojibake.
        See DecodeShellOutputBytes for the full rationale. }
      SetLength(Bytes, M.Size);
      M.Position := 0;
      M.ReadBuffer(Bytes[0], M.Size);
      Output := DecodeShellOutputBytes(Bytes, Length(Bytes));
    end;
  finally
    M.Free;
    P.Free;
  end;
end;

function RunOneShotWithEnv(const Cmd, WorkingDir: string;
                            ExtraEnv: TStringList;
                            out Output: string): Integer;
{ Same loop body as RunOneShot above, but composes an explicit
  Environment list (parent's env + ExtraEnv with ExtraEnv winning
  on name collisions) and hands it to TProcess.Environment. The
  child process sees exactly that env; the parent process and
  every other concurrent RunOneShot call stay untouched -- no
  global env-var mutation, no race. }
var
  P: TInternalProcess;
  M: TMemoryStream;
  Buf: array[0..ReadBufferSize - 1] of Byte;
  Bytes: TBytes;
  N, Total, i, EqPos: Integer;
  EnvList: TStringList;
  Name, Existing: string;
begin
  Result := -1;
  Output := '';
  P := TInternalProcess.Create(nil);
  M := TMemoryStream.Create;
  EnvList := TStringList.Create;
  try
    { Inherit the parent's env first (TProcess.Environment, when
      set, REPLACES inherited env rather than augmenting it).
      GetEnvironmentVariableCount / GetEnvironmentString are FPC
      stdlib -- one process-wide snapshot at call time. }
    for i := 0 to GetEnvironmentVariableCount - 1 do
      EnvList.Add(GetEnvironmentString(i));
    { Layer ExtraEnv on top. For each KEY=VAL, drop any existing
      KEY= line so the new value wins instead of duplicating. }
    if ExtraEnv <> nil then
      for i := 0 to ExtraEnv.Count - 1 do
      begin
        EqPos := Pos('=', ExtraEnv[i]);
        if EqPos <= 0 then Continue;
        Name := Copy(ExtraEnv[i], 1, EqPos - 1);
        for N := EnvList.Count - 1 downto 0 do
        begin
          Existing := EnvList[N];
          if (Pos('=', Existing) > 0) and
             (Copy(Existing, 1, Length(Name)) = Name) and
             (Existing[Length(Name) + 1] = '=') then
            EnvList.Delete(N);
        end;
        EnvList.Add(ExtraEnv[i]);
      end;
    P.Environment := EnvList;
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
    if M.Size > 0 then
    begin
      { Same OEM-decode trick as RunOneShot above -- see the
        comment there and DecodeShellOutputBytes for the rationale. }
      SetLength(Bytes, M.Size);
      M.Position := 0;
      M.ReadBuffer(Bytes[0], M.Size);
      Output := DecodeShellOutputBytes(Bytes, Length(Bytes));
    end;
  finally
    EnvList.Free;
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
      { OEM-aware decode on Windows; plain UTF-8 on POSIX. The
        helper makes both branches go through one place so the
        bug-fix history -- "cmd.exe is in OEM not UTF-8" -- lives
        in one comment block (see DecodeShellOutputBytes). }
      Output := DecodeShellOutputBytes(Bytes, Length(Bytes));
    end;
  finally
    Acc.Free;
    Args.Free;
    P.Free;
  end;
end;

function RunOneShotWithEnv(const Cmd, WorkingDir: string;
                            ExtraEnv: TStringList;
                            out Output: string): Integer;
{ Delphi Windows stub. Same story as the Delphi POSIX stub
  below -- the env-injection path goes through CreateProcess and
  needs an environment block, which is more invasive than the
  fcl-process Environment list. ExtraEnv ignored; warn-once so
  it's discoverable. Production builds use FPC. }
begin
  { ExtraEnv silently ignored on this build. The fix is a follow-up
    when someone exercises execute_code's tool-RPC on a Delphi
    Windows build -- not the production path today. }
  if ExtraEnv <> nil then ;
  Result := RunOneShot(Cmd, WorkingDir, Output);
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
  { @Buf: Delphi's Posix.Unistd declares __write(Handle, Buf: Pointer,
    Count) -- an untyped const param doesn't implicitly convert, so
    take its address explicitly. }
  Result := __write(FStdinFd, @Buf, Count);
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
  { fd_set, not FPC's TFDSet -- Delphi's Posix.SysSelect keeps the
    C type name. Its FD_* helpers are __-prefixed (__FD_SET below)
    because the bare name FD_SET would collide case-insensitively
    with the fd_set type itself. }
  TimeoutFd: fd_set;
  Tv: timeval;
begin
  Result := 0;
  if FStdoutFd < 0 then Exit;
  Waited := 0;
  while True do
  begin
    FillChar(TimeoutFd, SizeOf(TimeoutFd), 0);
    __FD_SET(FStdoutFd, TimeoutFd);
    Tv.tv_sec  := 0;
    Tv.tv_usec := 10 * 1000;   { 10 ms }
    Status := select(FStdoutFd + 1, @TimeoutFd, nil, nil, @Tv);
    if Status > 0 then
    begin
      { @Buf -- same Pointer-param contract as __write above. }
      R := __read(FStdoutFd, @Buf, BufSize);
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
  { @Status: Delphi's Posix.SysWait waitpid takes stat_loc: PInteger,
    not a var param like FPC's fpWaitPid. }
  R := waitpid(FPid, @Status, WNOHANG);
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
    waitpid(P.FPid, @Status, 0);   { PInteger stat_loc -- see Running }
    if WIFEXITED(Status) then Result := WEXITSTATUS(Status) else Result := -1;
    if Acc.Size > 0 then
    begin
      SetLength(Bytes, Acc.Size);
      Acc.Position := 0;
      Acc.ReadBuffer(Bytes[0], Acc.Size);
      { OEM-aware decode on Windows; plain UTF-8 on POSIX. The
        helper makes both branches go through one place so the
        bug-fix history -- "cmd.exe is in OEM not UTF-8" -- lives
        in one comment block (see DecodeShellOutputBytes). }
      Output := DecodeShellOutputBytes(Bytes, Length(Bytes));
    end;
  finally
    Acc.Free;
    Args.Free;
    P.Free;
  end;
end;

function RunOneShotWithEnv(const Cmd, WorkingDir: string;
                            ExtraEnv: TStringList;
                            out Output: string): Integer;
{ Delphi POSIX stub. Env-var injection isn't wired here yet --
  the Delphi POSIX path forks/execs directly rather than going
  through a TProcess abstraction with an Environment property,
  so the implementation is more invasive. For now ExtraEnv is
  ignored; production builds use the FPC implementation up top,
  so this only matters for a hypothetical Delphi/POSIX
  cross-build. Will produce a runtime warning when ExtraEnv is
  non-empty so a future operator notices. }
begin
  { ExtraEnv silently ignored on this build. Same story as the
    Delphi Windows stub above -- production path is FPC and that
    has the real implementation. }
  if ExtraEnv <> nil then ;
  Result := RunOneShot(Cmd, WorkingDir, Output);
end;

{$ENDIF}
{$ENDIF}

function RunOneShot(const Cmd: string; out Output: string): Integer;
begin
  Result := RunOneShot(Cmd, '', Output);
end;

function RunArgvCapture(const Exe: string; Args: TStrings;
                        const WorkingDir: string; out Output: string;
                        TimeoutMs: Integer = 0): Integer;
{ Cross-platform: built on the TStdioProcess abstraction (TProcess on
  FPC, CreateProcessW on Delphi/Windows, fork+execvp on Delphi/POSIX) so
  there is exactly one implementation. MergeStderr mirrors RunOneShot's
  combined-capture contract. Drain pattern matches RunOneShot and
  MCP.StdioClient: read what's available, and only stop once the pipe is
  empty AND the child has been reaped (Running populates ExitCode on the
  transition).

  TimeoutMs > 0 caps total wall-clock time: on expiry the child is
  Terminated and 124 is returned. This is what keeps a wedged Docker
  daemon (`docker info` that never returns) from hanging serve/agent at
  startup -- the Docker backend passes a bounded timeout for every
  `docker` invocation. 0 (default) preserves the historical unbounded
  behaviour for every other caller. }
var
  P: TStdioProcess;
  M: TMemoryStream;
  Buf: array[0..ReadBufferSize - 1] of Byte;
  Bytes: TBytes;
  N, Total: Integer;
  Overflow, TimedOut: Boolean;
  StartT: TDateTime;
begin
  Result := -1;
  Output := '';
  P := TStdioProcess.Create;
  M := TMemoryStream.Create;
  try
    if not P.Spawn(Exe, Args, {MergeStderr=}True, WorkingDir) then Exit;
    Total := 0;
    Overflow := False;
    TimedOut := False;
    StartT := Now;
    while True do
    begin
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        M.WriteBuffer(Buf, N);
        Inc(Total, N);
        if Total > OneShotMaxBytes then
        begin
          Overflow := True;
          P.Terminate;
          Break;
        end;
      end
      else if not P.Running then
        Break
      else
        Sleep(20);
      { Wall-clock cap. 86400000 = ms/day; Now's resolution (~10-16ms) is
        ample for the second-scale timeouts callers use. }
      if (TimeoutMs > 0) and
         (Trunc((Now - StartT) * 86400000.0) >= TimeoutMs) then
      begin
        TimedOut := True;
        P.Terminate;
        Break;
      end;
    end;
    if Overflow or TimedOut then
      Result := 124          { killed (byte cap or timeout); matches RunOneShot }
    else
      Result := P.ExitCode;
    if M.Size > 0 then
    begin
      SetLength(Bytes, M.Size);
      M.Position := 0;
      M.ReadBuffer(Bytes[0], M.Size);
      Output := DecodeShellOutputBytes(Bytes, Length(Bytes));
    end;
    if TimedOut then
      Output := Trim(Output + Format(' (timed out after %d ms)', [TimeoutMs]));
  finally
    M.Free;
    P.Free;
  end;
end;

end.
