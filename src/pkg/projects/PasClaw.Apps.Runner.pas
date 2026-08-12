(*
  PasClaw.Apps.Runner - running the app kinds that are programs.

  `page` and `html` apps are documents the gateway serves. The other three are
  processes:

    python   run the manifest's `run` command
    fpc      `build` first (fpc ...), then run the produced binary
    delphi   `build` via a RAD Studio toolchain, then run

  What this unit owns: building, spawning, keeping one child per project,
  draining its output into a ring buffer the desktop can tail, allocating a
  port for apps that serve HTTP, and stopping it again.

  SAFETY, STATED PLAINLY. The `run` and `build` strings come from app.json,
  which a model wrote. Executing them is arbitrary code execution on the host
  -- that is the deal the app factory makes, the same one `shell_exec` already
  makes. What this unit does about it:

    - Nothing starts without explicit per-start consent from the caller
      (StartApp refuses unless Consented is True; the gateway route requires
      "confirm": true, and both clients ask the user first, showing the
      command and the declared permissions).
    - The child runs with its cwd pinned to the project's app directory.
    - Secrets are never read from app.json. An app that declares
      permissions.env gets those names filled from projects/<n>/app/.env,
      a file only the user writes, and nothing else from the parent
      environment is added.
    - One child per project, tracked, killable, and reaped on shutdown.

  What it does NOT do: run the child inside the Docker shell backend. That
  backend's Exec is one-shot, so a long-lived server has no handle to stop;
  wiring it properly is a separate piece of work. Until then a `python` app
  runs on the host, and the docs say so.
*)
unit PasClaw.Apps.Runner;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Apps;

type
  TRunState = (rsStopped, rsBuilding, rsRunning, rsFailed, rsExited);

  TRunInfo = record
    Project:  string;
    State:    TRunState;
    Port:     Integer;   { 0 when the app doesn't serve HTTP }
    Pid:      Integer;   { informational; 0 when unknown }
    Started:  string;
    ExitCode: Integer;
    Command:  string;    { what was actually run, after substitution }
    Error:    string;
  end;

function RunStateToStr(S: TRunState): string;

(* The command StartApp would run, with the {port} placeholder substituted.
   Exposed so the desktop can show the user exactly what they are consenting
   to BEFORE they consent -- a confirmation that hides the command is
   theatre. Paren-star delimiters: the placeholder's brace would close a
   curly-brace comment early. *)
function PlannedCommand(const Project: string; out Err: string): string;

{ Build (when the manifest has a `build`) and start the app. Refuses unless
  Consented is True. Idempotent: an already-running app returns its info. }
function StartApp(const Project: string; Consented: Boolean;
  out Info: TRunInfo; out Err: string): Boolean;

{ Stop a running app. True when something was stopped. }
function StopApp(const Project: string; out Err: string): Boolean;

{ Current state; State=rsStopped when we have never run it. }
function AppRunInfo(const Project: string): TRunInfo;

{ Combined stdout+stderr captured so far (capped). }
function AppRunLog(const Project: string): string;

{ Every project we currently hold a child for. }
function RunningApps: TStringList;   { caller frees }

{ Stop every child. Called on gateway shutdown so a killed server doesn't
  leave orphaned app processes behind. }
procedure StopAllApps;

implementation

uses
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Platform,
  PasClaw.Projects.Store,
  IdTCPClient;

const
  { Ports handed to apps that serve HTTP. Deliberately far from the
    gateway's own range so a mistake is obvious in netstat. }
  PortBase  = 8700;
  PortCount = 60;
  MaxLogBytes = 256 * 1024;

type
  { Drains the child's pipe. A child whose output nobody reads eventually
    fills the pipe buffer and blocks forever, so this is not optional. }
  TDrainThread = class(TThread)
  private
    FProject: string;
  protected
    procedure Execute; override;
  public
    constructor Create(const AProject: string);
  end;

  TRunning = class
    Project:  string;
    Proc:     TStdioProcess;
    Drain:    TDrainThread;
    Port:     Integer;
    State:    TRunState;
    Started:  string;
    ExitCode: Integer;
    Command:  string;
    Error:    string;
    Log:      string;
    destructor Destroy; override;
  end;

var
  GLock: TCriticalSection = nil;
  GApps: TStringList = nil;   { project -> TRunning }

function RunStateToStr(S: TRunState): string;
begin
  case S of
    rsBuilding: Result := 'building';
    rsRunning:  Result := 'running';
    rsFailed:   Result := 'failed';
    rsExited:   Result := 'exited';
    else        Result := 'stopped';
  end;
end;

destructor TRunning.Destroy;
begin
  { The drain thread touches Proc, so it must be gone first. }
  if Drain <> nil then
  begin
    Drain.Terminate;
    Drain.WaitFor;
    FreeAndNil(Drain);
  end;
  FreeAndNil(Proc);
  inherited;
end;

function FindRunning(const Project: string): TRunning;
var
  I: Integer;
begin
  Result := nil;
  if GApps = nil then Exit;
  I := GApps.IndexOf(Project);
  if I >= 0 then
    Result := TRunning(GApps.Objects[I]);
end;

{ ------------------------------------------------------------------ ports -- }

{ True when something is already listening. A connect attempt is cruder than
  binding, but it needs no new socket plumbing and it is the question we
  actually care about: "will the app's own bind fail?" }
function PortInUse(Port: Integer): Boolean;
var
  C: TIdTCPClient;
begin
  Result := False;
  C := TIdTCPClient.Create(nil);
  try
    C.Host := '127.0.0.1';
    C.Port := Port;
    C.ConnectTimeout := 250;
    try
      C.Connect;
      Result := True;      { someone answered -- taken }
      C.Disconnect;
    except
      Result := False;     { refused -- free }
    end;
  finally
    C.Free;
  end;
end;

function ClaimPort: Integer;
var
  P, I: Integer;
  Taken: Boolean;
  J: Integer;
begin
  for I := 0 to PortCount - 1 do
  begin
    P := PortBase + I;
    { Skip ports we have already handed out this process, even if the app
      hasn't bound yet -- two apps starting back to back would otherwise
      both be told 8700. }
    Taken := False;
    if GApps <> nil then
      for J := 0 to GApps.Count - 1 do
        if TRunning(GApps.Objects[J]).Port = P then
        begin
          Taken := True;
          Break;
        end;
    if Taken then Continue;
    if not PortInUse(P) then
      Exit(P);
  end;
  Result := 0;
end;

{ ------------------------------------------------------------------ drain -- }

constructor TDrainThread.Create(const AProject: string);
begin
  inherited Create(True);
  FProject := AProject;
  FreeOnTerminate := False;
end;

procedure TDrainThread.Execute;
var
  Buf: array[0..4095] of Byte;
  N: Integer;
  S: AnsiString;
  R: TRunning;
  Alive: Boolean;
begin
  while not Terminated do
  begin
    N := 0;
    Alive := False;
    GLock.Acquire;
    try
      R := FindRunning(FProject);
      if (R <> nil) and (R.Proc <> nil) then
      begin
        Alive := R.Proc.Running;
        N := R.Proc.ReadAvailable(Buf, SizeOf(Buf));
        if N > 0 then
        begin
          SetLength(S, N);
          Move(Buf[0], S[1], N);
          R.Log := R.Log + string(S);
          { Ring-buffer the tail: an app that logs a line a second would
            otherwise grow this without bound for as long as it runs. }
          if Length(R.Log) > MaxLogBytes then
            R.Log := Copy(R.Log, Length(R.Log) - (MaxLogBytes div 2), MaxInt);
        end;
        if (not Alive) and (R.State = rsRunning) then
        begin
          R.State := rsExited;
          R.ExitCode := R.Proc.ExitCode;
          LogInfo('app %s exited with code %d', [FProject, R.ExitCode]);
        end;
      end;
    finally
      GLock.Release;
    end;
    if R = nil then Break;
    { Only idle when there was nothing to read; a chatty child should be
      drained as fast as it writes. }
    if (N = 0) then
    begin
      if not Alive then
      begin
        { One more pass to drain whatever is still in the pipe, then stop. }
        Sleep(60);
        GLock.Acquire;
        try
          R := FindRunning(FProject);
          if (R <> nil) and (R.Proc <> nil) then
          begin
            N := R.Proc.ReadAvailable(Buf, SizeOf(Buf));
            if N > 0 then
            begin
              SetLength(S, N);
              Move(Buf[0], S[1], N);
              R.Log := R.Log + string(S);
            end;
          end;
        finally
          GLock.Release;
        end;
        if N = 0 then Break;
      end
      else
        Sleep(120);
    end;
  end;
end;

{ ------------------------------------------------------------------ start -- }

{ Split a command line into program + argv the way a shell would for the
  simple cases: spaces separate, quotes group. We do NOT hand the string to
  a shell, so an app.json `run` cannot smuggle in `; rm -rf ~` -- there is no
  shell to interpret it. }
function SplitCommand(const Cmd: string; Args: TStringList): string;
var
  I: Integer;
  Cur: string;
  Quote: Char;
  InQuote: Boolean;
begin
  Result := '';
  Args.Clear;
  Cur := '';
  InQuote := False;
  Quote := #0;
  for I := 1 to Length(Cmd) do
  begin
    if InQuote then
    begin
      if Cmd[I] = Quote then InQuote := False else Cur := Cur + Cmd[I];
      Continue;
    end;
    case Cmd[I] of
      '"', '''':
        begin
          InQuote := True;
          Quote := Cmd[I];
        end;
      ' ', #9:
        begin
          if Cur <> '' then
          begin
            if Result = '' then Result := Cur else Args.Add(Cur);
            Cur := '';
          end;
        end;
      else
        Cur := Cur + Cmd[I];
    end;
  end;
  if Cur <> '' then
  begin
    if Result = '' then Result := Cur else Args.Add(Cur);
  end;
end;

function Substitute(const S: string; Port: Integer; const AppDir: string): string;
begin
  Result := StringReplace(S, '{port}', IntToStr(Port), [rfReplaceAll, rfIgnoreCase]);
  Result := StringReplace(Result, '{dir}', AppDir, [rfReplaceAll, rfIgnoreCase]);
end;

{ Env for the child: ONLY the names the manifest declared, read from the
  project's own .env file. Nothing is inherited implicitly, so an app cannot
  read the operator's provider keys just by existing. }
function BuildEnv(const Project: string; const Info: TAppInfo;
  Port: Integer): TStringList;
var
  EnvPath, Line, Key: string;
  Declared, FileLines: TStringList;
  I, J, P: Integer;
begin
  Result := TStringList.Create;
  if Port > 0 then
    Result.Add('PORT=' + IntToStr(Port));
  if Trim(Info.EnvKeys) = '' then Exit;

  Declared := SplitToList(Info.EnvKeys, ',');
  FileLines := TStringList.Create;
  try
    EnvPath := JoinPath(ProjectAppDir(Project), '.env');
    if FileExists(EnvPath) then
      FileLines.Text := ReadFileText(EnvPath);
    for I := 0 to Declared.Count - 1 do
    begin
      Key := Trim(Declared[I]);
      if Key = '' then Continue;
      for J := 0 to FileLines.Count - 1 do
      begin
        Line := Trim(FileLines[J]);
        if (Line = '') or (Line[1] = '#') then Continue;
        P := Pos('=', Line);
        if P <= 1 then Continue;
        if SameText(Trim(Copy(Line, 1, P - 1)), Key) then
        begin
          Result.Add(Key + '=' + Copy(Line, P + 1, MaxInt));
          Break;
        end;
      end;
    end;
  finally
    FileLines.Free;
    Declared.Free;
  end;
end;

function PlannedCommand(const Project: string; out Err: string): string;
var
  Info: TAppInfo;
begin
  Err := '';
  Result := '';
  if not GetApp(Project, Info) or not Info.Exists then
  begin
    Err := 'no app in project ' + Project;
    Exit;
  end;
  if Info.Kind in [akPage, akHtml] then
  begin
    Err := 'a ' + AppKindToStr(Info.Kind) + ' app is served, not run';
    Exit;
  end;
  Result := Trim(Info.Run);
  if (Result = '') and (Info.Kind = akPython) then
  begin
    { A python app with no explicit run line gets the obvious one. }
    if Info.Entry = '' then Info.Entry := 'main.py';
    Result := 'python3 ' + Info.Entry;
  end;
  if Result = '' then
    Err := 'app.json has no "run" command for this kind';
end;

function StartApp(const Project: string; Consented: Boolean;
  out Info: TRunInfo; out Err: string): Boolean;
var
  App: TAppInfo;
  R: TRunning;
  AppDir, Cmd, Exe, Out_: string;
  Args, Env: TStringList;
  Port, RC: Integer;
begin
  Err := '';
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Project := Project; Info.State := rsStopped;
  Info.Started := ''; Info.Command := ''; Info.Error := '';

  if not GetApp(Project, App) or not App.Exists then
  begin
    Err := 'no app in project ' + Project;
    Exit;
  end;
  if App.Kind in [akPage, akHtml] then
  begin
    Err := 'a ' + AppKindToStr(App.Kind) + ' app opens in a window; ' +
           'there is nothing to run';
    Exit;
  end;
  if not Consented then
  begin
    { The caller has to have shown the user the command. Refusing here rather
      than defaulting to "yes" is the whole point. }
    Err := 'running this app needs explicit confirmation';
    Exit;
  end;

  GLock.Acquire;
  try
    R := FindRunning(Project);
    if (R <> nil) and (R.State = rsRunning) and (R.Proc <> nil) and R.Proc.Running then
    begin
      Info := AppRunInfo(Project);
      Exit(True);
    end;
    { A dead entry from a previous run is replaced, not reused. }
    if R <> nil then
    begin
      GApps.Delete(GApps.IndexOf(Project));
      R.Free;
    end;
  finally
    GLock.Release;
  end;

  AppDir := ProjectAppDir(Project);
  if (AppDir = '') or not DirectoryExists(AppDir) then
  begin
    Err := 'project has no app directory';
    Exit;
  end;

  { --- build --- }
  { The build step is one-shot, so it goes through RunOneShot (a shell) rather
    than the argv spawn used for the long-lived child: build lines legitimately
    contain pipes and && chains, and they only run on explicit consent. }
  if Trim(App.Build) <> '' then
  begin
    RC := RunOneShot(Substitute(App.Build, 0, AppDir), AppDir, Out_);
    if RC <> 0 then
    begin
      Err := 'build failed (exit ' + IntToStr(RC) + '): ' + Copy(Trim(Out_), 1, 400);
      GLock.Acquire;
      try
        R := TRunning.Create;
        R.Project := Project;
        R.State := rsFailed;
        R.Error := Err;
        R.Log := '$ ' + App.Build + #10 + Out_;
        GApps.AddObject(Project, R);
      finally
        GLock.Release;
      end;
      Info := AppRunInfo(Project);
      Exit;
    end;
  end;

  { --- port --- }
  Port := 0;
  Cmd := '';
  Cmd := Trim(App.Run);
  if (Cmd = '') and (App.Kind = akPython) then
    Cmd := 'python3 ' + App.Entry;
  if Cmd = '' then
  begin
    Err := 'app.json has no "run" command';
    Exit;
  end;
  if Pos('{port}', LowerCase(Cmd)) > 0 then
  begin
    Port := ClaimPort;
    if Port = 0 then
    begin
      Err := 'no free port in range ' + IntToStr(PortBase) + '-' +
             IntToStr(PortBase + PortCount - 1);
      Exit;
    end;
  end;
  Cmd := Substitute(Cmd, Port, AppDir);

  { --- spawn --- }
  Args := TStringList.Create;
  Env  := BuildEnv(Project, App, Port);
  try
    Exe := SplitCommand(Cmd, Args);
    if Exe = '' then
    begin
      Err := 'empty run command';
      Exit;
    end;
    R := TRunning.Create;
    R.Project  := Project;
    R.Port     := Port;
    R.Command  := Cmd;
    R.Started  := NowIsoUtc;
    R.Proc     := TStdioProcess.Create;
    R.Log      := '$ ' + Cmd + #10;
    { MergeStderr: a crashing app prints its traceback on stderr, and that is
      exactly what the user needs to see in the log window. }
    if not R.Proc.Spawn(Exe, Args, True, AppDir, Env) then
    begin
      R.State := rsFailed;
      R.Error := 'could not start ' + Exe;
      Err := R.Error;
      GLock.Acquire;
      try
        GApps.AddObject(Project, R);
      finally
        GLock.Release;
      end;
      Info := AppRunInfo(Project);
      Exit;
    end;
    R.State := rsRunning;
    GLock.Acquire;
    try
      GApps.AddObject(Project, R);
    finally
      GLock.Release;
    end;
    R.Drain := TDrainThread.Create(Project);
    R.Drain.Start;
    if Port > 0 then
      LogInfo('app %s started on port %d: %s', [Project, Port, Cmd])
    else
      LogInfo('app %s started: %s', [Project, Cmd]);
  finally
    Args.Free;
    Env.Free;
  end;

  Info := AppRunInfo(Project);
  Result := Info.State = rsRunning;
end;

function StopApp(const Project: string; out Err: string): Boolean;
var
  R: TRunning;
  Idx: Integer;
begin
  Err := '';
  Result := False;
  GLock.Acquire;
  try
    Idx := GApps.IndexOf(Project);
    if Idx < 0 then
    begin
      Err := 'not running';
      Exit;
    end;
    R := TRunning(GApps.Objects[Idx]);
    GApps.Delete(Idx);
  finally
    GLock.Release;
  end;
  { Freed outside the lock: TRunning.Destroy joins the drain thread, which
    takes the same lock. }
  if (R.Proc <> nil) and R.Proc.Running then
    R.Proc.Terminate;
  R.Free;
  LogInfo('app %s stopped', [Project]);
  Result := True;
end;

function AppRunInfo(const Project: string): TRunInfo;
var
  R: TRunning;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Project := Project;
  Result.State := rsStopped;
  Result.Started := ''; Result.Command := ''; Result.Error := '';
  GLock.Acquire;
  try
    R := FindRunning(Project);
    if R = nil then Exit;
    Result.State    := R.State;
    Result.Port     := R.Port;
    Result.Started  := R.Started;
    Result.ExitCode := R.ExitCode;
    Result.Command  := R.Command;
    Result.Error    := R.Error;
  finally
    GLock.Release;
  end;
end;

function AppRunLog(const Project: string): string;
var
  R: TRunning;
begin
  Result := '';
  GLock.Acquire;
  try
    R := FindRunning(Project);
    if R <> nil then Result := R.Log;
  finally
    GLock.Release;
  end;
end;

function RunningApps: TStringList;
var
  I: Integer;
begin
  Result := TStringList.Create;
  GLock.Acquire;
  try
    for I := 0 to GApps.Count - 1 do
      if TRunning(GApps.Objects[I]).State = rsRunning then
        Result.Add(GApps[I]);
  finally
    GLock.Release;
  end;
end;

procedure StopAllApps;
var
  Names: TStringList;
  I: Integer;
  Err: string;
begin
  Names := TStringList.Create;
  try
    GLock.Acquire;
    try
      for I := 0 to GApps.Count - 1 do
        Names.Add(GApps[I]);
    finally
      GLock.Release;
    end;
    for I := 0 to Names.Count - 1 do
      StopApp(Names[I], Err);
  finally
    Names.Free;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GApps := TStringList.Create;

finalization
  StopAllApps;
  FreeAndNil(GApps);
  FreeAndNil(GLock);

end.
