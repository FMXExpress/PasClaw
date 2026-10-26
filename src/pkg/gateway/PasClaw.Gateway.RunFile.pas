(*
  PasClaw.Gateway.RunFile -- how a client finds the running gateway.

  `pasclaw gateway` / `pasclaw serve` write <home>/run/gateway.json on
  start and remove it on stop:

    {"port": 8088, "bind": "127.0.0.1", "pid": 4242,
     "token_hash": "<sha256 hex of gateway.token, or ''>",
     "started_at": "2026-10-17T12:00:00Z", "version": "0.1.6"}

  `pasclaw status`, `pasclaw agent --attach` and `pasclaw tui --attach`
  read it. A file whose pid is no longer alive is stale (the gateway was
  killed without a chance to clean up) and is treated as absent, so a
  crash never leaves clients trying to attach to nothing. The token
  itself is never written: a client that wants in reads gateway.token
  from its own config, and the hash lets status say whether the two
  agree.
*)
unit PasClaw.Gateway.RunFile;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TGatewayRunInfo = record
    Port:      Integer;
    Bind:      string;
    Pid:       Integer;
    TokenHash: string;
    StartedAt: string;
    Version:   string;
    { Where the file was read from. }
    Path:      string;
  end;

const
  RunFileName = 'gateway.json';

{ <Home>/run/gateway.json }
function GatewayRunFilePath(const Home: string): string;

{ Write the file for THIS process. Token is hashed, never stored. }
procedure WriteGatewayRunFile(const Home, Bind: string; Port: Integer;
                              const Token, Version: string);

{ Remove it -- only when it names this process, so a second gateway that
  failed to bind does not delete the first one's file on its way out. }
procedure RemoveGatewayRunFile(const Home: string);

{ Read it. False when missing, unparsable, or stale (pid not alive). }
function ReadGatewayRunFile(const Home: string; out Info: TGatewayRunInfo): Boolean;

{ The same, but also returns a stale file's contents with Alive=False, for
  a status line that wants to say "stale run file from pid N". }
function ReadGatewayRunFileRaw(const Home: string; out Info: TGatewayRunInfo;
                               out Alive: Boolean): Boolean;

{ http://<bind or 127.0.0.1>:<port> -- a bind of 0.0.0.0 / :: is reachable
  on loopback, which is what a local client wants. }
function GatewayBaseURL(const Info: TGatewayRunInfo): string;

function TokenHashHex(const Token: string): string;
function CurrentProcessId: Integer;
function ProcessAlive(Pid: Integer): Boolean;

(* The stop signal. A run file is only removed when the gateway's finally
   runs, and before this nothing caught SIGINT / SIGTERM / Ctrl-C: the
   process died where it stood and the file stayed behind every time.
   InstallStopSignalHandler makes the FIRST signal set StopRequested
   (async-signal-safe: a flag, nothing else) and restores the default
   action, so a second one still kills a gateway that is stuck shutting
   down. TGatewayServer.WaitForStop polls the flag. *)
procedure InstallStopSignalHandler;
function  StopRequested: Boolean;

implementation

uses
  {$IFDEF FPC}
    {$IFDEF UNIX}BaseUnix,{$ENDIF}
    {$IFDEF MSWINDOWS}Windows,{$ENDIF}
  {$ELSE}
    {$IFDEF MSWINDOWS}Winapi.Windows,{$ELSE}Posix.Signal, Posix.Unistd, Posix.Errno,{$ENDIF}
  {$ENDIF}
  PasClaw.Utils,   { NowIsoUtc, ReadFileText, WriteFileText }
  PasClaw.JSON,
  PasClaw.Crypto.HMAC;

function GatewayRunFilePath(const Home: string): string;
begin
  Result := IncludeTrailingPathDelimiter(IncludeTrailingPathDelimiter(Home) + 'run') + RunFileName;
end;

function TokenHashHex(const Token: string): string;
var
  B, H: TBytes;
  i: Integer;
begin
  Result := '';
  if Token = '' then Exit;
  B := TEncoding.UTF8.GetBytes(Token);
  H := SHA256Bytes(B);
  for i := 0 to High(H) do
    Result := Result + LowerCase(IntToHex(H[i], 2));
end;

function CurrentProcessId: Integer;
begin
  {$IFDEF FPC}
  Result := Integer(GetProcessID);
  {$ELSE}
    {$IFDEF MSWINDOWS}
    Result := Integer(GetCurrentProcessId);
    {$ELSE}
    Result := Integer(getpid);
    {$ENDIF}
  {$ENDIF}
end;

{$IFDEF MSWINDOWS}
const
  { PROCESS_QUERY_LIMITED_INFORMATION (Vista+): enough for
    GetExitCodeProcess, and granted on processes of other users where
    PROCESS_QUERY_INFORMATION is not. Declared here because dcc64's
    Winapi.Windows does not declare it (E2003 on the Delphi build); our own
    name, so it cannot collide with a unit that does. }
  RUNFILE_PROCESS_QUERY_LIMITED = $1000;
{$ENDIF}

function ProcessAlive(Pid: Integer): Boolean;
{$IFDEF MSWINDOWS}
var
  H: THandle;
  Code: DWORD;
{$ENDIF}
begin
  if Pid <= 0 then Exit(False);
  {$IFDEF MSWINDOWS}
  H := OpenProcess(RUNFILE_PROCESS_QUERY_LIMITED, False, DWORD(Pid));
  if H = 0 then Exit(False);
  try
    Result := GetExitCodeProcess(H, Code) and (Code = STILL_ACTIVE);
  finally
    CloseHandle(H);
  end;
  {$ELSE}
    {$IFDEF FPC}
    { kill(pid, 0): 0 = alive and ours, EPERM = alive but not ours (still
      alive), ESRCH = gone. }
    Result := (fpKill(Pid, 0) = 0) or (fpGetErrno = ESysEPERM);
    {$ELSE}
    Result := (kill(Pid, 0) = 0) or (GetLastError = EPERM);
    {$ENDIF}
  {$ENDIF}
end;

procedure WriteGatewayRunFile(const Home, Bind: string; Port: Integer;
                              const Token, Version: string);
var
  Obj: TJsonObject;
  Path: string;
begin
  Path := GatewayRunFilePath(Home);
  ForceDirectories(ExtractFileDir(Path));
  Obj := TJsonObject.Create;
  try
    Obj.PutInt('port', Port);
    Obj.PutStr('bind', Bind);
    Obj.PutInt('pid', CurrentProcessId);
    Obj.PutStr('token_hash', TokenHashHex(Token));
    { NowIsoUtc: LocalTimeToUniversal is FPC's DateUtils only (E2003 on
      dcc64); the helper picks TTimeZone on Delphi, and quotes its
      separators, which a bare ':' in FormatDateTime is not -- it becomes
      the locale's time separator. }
    Obj.PutStr('started_at', NowIsoUtc);
    Obj.PutStr('version', Version);
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure RemoveGatewayRunFile(const Home: string);
var
  Info: TGatewayRunInfo;
  Alive: Boolean;
begin
  if not ReadGatewayRunFileRaw(Home, Info, Alive) then Exit;
  { SysUtils', by name: on Delphi, Winapi.Windows comes later in scope and
    its DeleteFile(PWideChar) wins over SysUtils.DeleteFile(string) --
    E2010 on dcc64. }
  if (Info.Pid = CurrentProcessId) or (not Alive) then
    SysUtils.DeleteFile(Info.Path);
end;

function ReadGatewayRunFileRaw(const Home: string; out Info: TGatewayRunInfo;
                               out Alive: Boolean): Boolean;
var
  Obj: TJsonObject;
  Text: string;
begin
  Result := False;
  Alive := False;
  Info := Default(TGatewayRunInfo);
  Info.Path := GatewayRunFilePath(Home);
  if not FileExists(Info.Path) then Exit;
  (* The gateway deletes this file on its way out, and nothing orders that
     against a reader: FileExists can say yes and the open then find
     nothing. ReadFileText raises in that case, and none of the callers --
     `status`, `agent --attach`, `tui --attach` -- catches it, so an
     ordinary concurrent shutdown crashed the client instead of it reading
     "no gateway". Absent is the documented answer for a missing file, and
     a file that vanished mid-read is missing. (Codex P2 on #613.) *)
  try
    Text := ReadFileText(Info.Path);
  except
    Exit;
  end;
  try
    Obj := TJsonObject.Parse(Text);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Info.Port := Integer(Obj.GetInt('port', 0));
    Info.Bind := Obj.GetStr('bind', '');
    Info.Pid := Integer(Obj.GetInt('pid', 0));
    Info.TokenHash := Obj.GetStr('token_hash', '');
    Info.StartedAt := Obj.GetStr('started_at', '');
    Info.Version := Obj.GetStr('version', '');
  finally
    Obj.Free;
  end;
  if Info.Port <= 0 then Exit;
  Alive := ProcessAlive(Info.Pid);
  Result := True;
end;

function ReadGatewayRunFile(const Home: string; out Info: TGatewayRunInfo): Boolean;
var
  Alive: Boolean;
begin
  Result := ReadGatewayRunFileRaw(Home, Info, Alive) and Alive;
end;

{ ---- stop signal ---- }

var
  GStopRequested: Boolean = False;

function StopRequested: Boolean;
begin
  Result := GStopRequested;
end;

{$IFDEF MSWINDOWS}
function ConsoleHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  (* The second event is the operator saying "now". Returning True for it
     too kept this handler consuming every Ctrl-C, so a shutdown hung in
     channel or server cleanup could not be broken out of at all -- unlike
     Unix, where the first signal restores SIG_DFL and the second kills.
     False hands the event on to the default handler, which terminates.
     (Codex P2 on #613.) *)
  if GStopRequested then Exit(False);
  GStopRequested := True;
  Result := True;   { handled: the process keeps running until the finally has run }
end;

procedure InstallStopSignalHandler;
begin
  SetConsoleCtrlHandler(@ConsoleHandler, True);
end;
{$ELSE}
  {$IFDEF FPC}
procedure OnStopSignal(Sig: cint); cdecl;
begin
  GStopRequested := True;
  fpSignal(Sig, signalhandler(SIG_DFL));   { next one kills }
end;

procedure InstallStopSignalHandler;
begin
  fpSignal(SIGINT,  signalhandler(@OnStopSignal));
  fpSignal(SIGTERM, signalhandler(@OnStopSignal));
end;
  {$ELSE}
procedure OnStopSignal(Sig: Integer); cdecl;
begin
  GStopRequested := True;
  signal(Sig, TSignalHandler(SIG_DFL));
end;

procedure InstallStopSignalHandler;
begin
  signal(SIGINT,  TSignalHandler(@OnStopSignal));
  signal(SIGTERM, TSignalHandler(@OnStopSignal));
end;
  {$ENDIF}
{$ENDIF}

function GatewayBaseURL(const Info: TGatewayRunInfo): string;
var
  Host: string;
begin
  Host := Trim(Info.Bind);
  if (Host = '') or (Host = '0.0.0.0') or (Host = '::') or (Host = '*') then Host := '127.0.0.1';
  if Pos(':', Host) > 0 then Host := '[' + Host + ']';
  Result := 'http://' + Host + ':' + IntToStr(Info.Port);
end;

end.
