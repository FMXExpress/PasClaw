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

  Where the child runs. With shell_backend = docker it runs in a container;
  otherwise it runs on the host. The container path does NOT reuse the shell
  backend's Exec -- that is one-shot, and a long-lived server started through
  it would have no handle to stop. It drives the docker CLI directly instead,
  so `docker run -d` returns a container id that stop and logs can address.
  Either way the run record reports which one happened, because "it works on
  my machine" is a different sentence depending on whose machine it is.
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
    Backend:  string;    { 'host' or 'docker' -- where it actually ran }
  end;

{ Where the runner will put the next child: 'host' or 'docker'. Reported to
  the clients so the desktop can say "in a container" rather than implying a
  bare host process. }
function RunnerBackendName: string;

function RunStateToStr(S: TRunState): string;

(* Everything StartApp would execute, with the {port} placeholder
   substituted: the manifest's build line first (when present, one per
   line) and then the run command. Exposed so the desktop can show the
   user exactly what they are consenting to BEFORE they consent -- a
   confirmation that hides any of the commands is theatre. Paren-star
   delimiters: the placeholder's brace would close a curly-brace comment
   early. *)
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

(* The argv handed to `docker run` for a project. Exposed because this
   command IS the isolation policy -- which directory is mounted, where the
   port is published, which image -- and that should be assertable in a test
   on a machine with no Docker, not only reviewable by running it.

   Mount decides how the app's files reach the container. See DockerIsRemote
   for why that is not a constant. *)
procedure BuildDockerRunArgs(const Project, AppDir, Cmd, Image: string;
  Port: Integer; Env: TStrings; Mount: Boolean; Args: TStringList);

(* The daemon this process will actually talk to, and whether it is on
   another machine. Exposed so the gateway can say so rather than making the
   user infer it from an app that came up empty. *)
function DockerEndpoint: string;
function DockerIsRemote: Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Platform,
  PasClaw.Config,
  PasClaw.Shell.Backend,   { TShellBackendKind -- which boundary we run in }
  PasClaw.Projects.Store,
  PasClaw.Desktop.Events,  { so an app that dies on its own says so }
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
    { Non-empty when the child is a container rather than a host process.
      The two are mutually exclusive; whichever is set is how we stop it. }
    Container: string;
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
  C := TIdTCPClient.Create(nil);
  try
    { The property writes are inside the try so every path out of this
      function assigns Result exactly once -- a leading Result := False
      would be dead on both branches below, which Delphi reports as
      H2077. }
    try
      C.Host := '127.0.0.1';
      C.Port := Port;
      C.ConnectTimeout := 250;
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

{ ----------------------------------------------------------------- docker -- }

(* Run a command as argv and wait for it, capturing combined output. Needed
   because the platform's RunOneShot takes a SHELL STRING, and the docker
   argv carries a user-supplied run line we must not hand to a shell for
   re-splitting -- the whole point of passing argv is that quoting cannot go
   wrong on the way in. *)
function RunArgs(const Exe: string; Args: TStrings; const WorkDir: string;
  out Output: string): Integer;
var
  P: TStdioProcess;
  Buf: array[0..4095] of Byte;
  N, Spins: Integer;
  Chunk: AnsiString;
begin
  Output := '';
  Result := -1;
  P := TStdioProcess.Create;
  try
    if not P.Spawn(Exe, Args, True, WorkDir, nil) then
    begin
      Output := 'could not start ' + Exe;
      Exit;
    end;
    Spins := 0;
    { Bounded: a docker CLI call that never returns must not park a request
      thread forever. ~30s at 50ms per empty read. }
    while (Spins < 600) do
    begin
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Chunk, N);
        Move(Buf[0], Chunk[1], N);
        Output := Output + string(Chunk);
        Spins := 0;
        Continue;
      end;
      if not P.Running then Break;
      Inc(Spins);
      Sleep(50);
    end;
    if P.Running then
    begin
      P.Terminate;
      Output := Output + #10 + '(timed out)';
      Exit;
    end;
    Result := P.ExitCode;
  finally
    P.Free;
  end;
end;


(* Docker mode. Deliberately drives the CLI rather than reusing the shell
   backend: that backend's Exec is one-shot, so a server started through it
   would run with no handle to stop. `docker run -d` returns a container id,
   which is exactly the handle we need. *)

function DockerConfigured: Boolean;
var
  Cfg: TConfig;
begin
  Cfg := LoadConfig;
  Result := Cfg.ShellBackend = sbDocker;
end;

function RunnerBackendName: string;
begin
  if not DockerConfigured then Exit('host');
  { Two very different places, and the difference is the user's to know:
    with a remote daemon the app's files and ports are on another machine. }
  if DockerIsRemote then Result := 'docker-remote' else Result := 'docker';
end;

function DockerImage: string;
var
  Cfg: TConfig;
begin
  Cfg := LoadConfig;
  Result := Trim(Cfg.ShellBackendDocker.Image);
  if Result = '' then Result := 'debian:bookworm-slim';
end;

var
  GEndpoint: string = #1;   { #1 = not probed yet; '' is a real answer }

(* Where the daemon lives.

   Asks docker rather than reading DOCKER_HOST, because `docker context use`
   repoints the CLI without touching the environment -- an env-var check
   would call a remote daemon local and produce exactly the silent failure
   this function exists to prevent. One probe, cached for the process. *)
function DockerEndpoint: string;
var
  Args: TStringList;
  Out_: string;
begin
  if GEndpoint <> #1 then Exit(GEndpoint);
  GEndpoint := '';
  Args := TStringList.Create;
  try
    Args.Add('context');
    Args.Add('inspect');
    Args.Add('--format');
    Args.Add('{{.Endpoints.docker.Host}}');
    if RunArgs('docker', Args, '', Out_) = 0 then
      GEndpoint := Trim(Out_);
  finally
    Args.Free;
  end;
  Result := GEndpoint;
end;

(* True when the daemon is on another machine.

   Local means a unix socket or a Windows named pipe -- the two spellings of
   "this kernel". Anything else (tcp://, ssh://) is somewhere the app's
   files are not and the app's ports would not be. An endpoint we could not
   read at all counts as local: assuming remote would refuse to run apps on
   a perfectly ordinary local Docker just because the probe failed. *)
function DockerIsRemote: Boolean;
var
  E: string;
begin
  E := LowerCase(DockerEndpoint);
  Result := (E <> '') and
            (Pos('unix://', E) <> 1) and (Pos('npipe://', E) <> 1);
end;

{ A stable, obviously-ours container name so an orphan is identifiable in
  `docker ps` and a restart can reclaim or clear it. }
function ContainerNameFor(const Project: string): string;
begin
  Result := 'pasclaw-app-' + Project;
end;

(* Build the argv for the detached run. Split out from the spawn so it can be
   asserted in a test on a machine with no Docker -- the shape of this command
   IS the isolation policy, and it should not be reviewable only by running
   it. *)
procedure BuildDockerRunArgs(const Project, AppDir, Cmd, Image: string;
  Port: Integer; Env: TStrings; Mount: Boolean; Args: TStringList);
var
  I: Integer;
begin
  Args.Clear;
  { create, not run: with a remote daemon the files have to be copied in
    before anything starts, and `docker run` gives no window to do that. The
    caller starts it once the copy lands. }
  Args.Add('create');
  Args.Add('--rm');                     { no corpse to clean up after a stop }
  Args.Add('--name'); Args.Add(ContainerNameFor(Project));
  (* The app directory is the ONLY mount -- not the workspace, not the home.

     And only when the daemon is local. A bind mount resolves on the
     DAEMON's filesystem, so against a remote daemon this path names
     something that isn't there and the app comes up against an empty /app.
     Silently. The caller copies the directory in instead. *)
  if Mount then
  begin
    Args.Add('-v'); Args.Add(AppDir + ':/app');
  end;
  Args.Add('-w'); Args.Add('/app');
  { Published to loopback only -- an app the user ran for themselves should
    not become reachable from their network because Docker helpfully bound
    0.0.0.0. }
  if Port > 0 then
  begin
    Args.Add('-p');
    Args.Add('127.0.0.1:' + IntToStr(Port) + ':' + IntToStr(Port));
  end;
  if Env <> nil then
    for I := 0 to Env.Count - 1 do
      if Trim(Env[I]) <> '' then
      begin
        Args.Add('-e');
        Args.Add(Env[I]);
      end;
  Args.Add(Image);
  { sh -c so the manifest's run line keeps working unchanged: inside a
    container of its own, a shell is not the risk it is on the host. }
  Args.Add('sh');
  Args.Add('-c');
  Args.Add(Cmd);
end;

function DockerRun(const Project, AppDir, Cmd: string; Port: Integer;
  Env: TStrings; out ContainerId, Err: string): Boolean;
var
  Args: TStringList;
  Line, Out_: string;
  RC: Integer;
  Remote: Boolean;
begin
  ContainerId := '';
  Err := '';
  Result := False;
  Remote := DockerIsRemote;

  (* A port cannot be published usefully OR safely to a remote daemon.

     -p 127.0.0.1:N:N binds the DAEMON's loopback, which this process cannot
     reach -- the app would come up and the window would point at nothing.
     Publishing 0.0.0.0 instead would make it reachable, and also make it
     reachable to everyone else on that host's network, which is not what
     anyone asked for by typing `docker context use`. So: refuse, and say
     which of the two fixes applies. *)
  if Remote and (Port > 0) then
  begin
    Err := 'this app serves HTTP on a port, and the Docker daemon is on ' +
           'another machine (' + DockerEndpoint + '). A published port ' +
           'would bind that machine''s loopback, not this one. Run the ' +
           'gateway on the Docker host, or point it at a local daemon.';
    Exit;
  end;

  Args := TStringList.Create;
  try
    { A previous run that died badly can leave the name taken. }
    RunOneShot('docker rm -f ' + ContainerNameFor(Project), AppDir, Out_);

    { create -> (copy) -> start. Bind-mounting is better when it works --
      the app sees edits live and its writes land back in the project -- so
      keep it for a local daemon and copy only when we have to. }
    BuildDockerRunArgs(Project, AppDir, Cmd, DockerImage, Port, Env,
                       not Remote, Args);
    Line := 'docker';
    RC := RunArgs(Line, Args, AppDir, Out_);
    if RC <> 0 then
    begin
      Err := 'docker create failed: ' + Copy(Trim(Out_), 1, 400);
      Exit;
    end;
    ContainerId := Trim(Out_);
    if ContainerId = '' then ContainerId := ContainerNameFor(Project);

    if Remote then
    begin
      { Copies the directory ITSELF as /app -- docker cp creates the
        destination when it does not exist, which it does not, because
        nothing was mounted there. }
      Args.Clear;
      Args.Add('cp');
      Args.Add(ExcludeTrailingPathDelimiter(AppDir));
      Args.Add(ContainerNameFor(Project) + ':/app');
      if RunArgs('docker', Args, '', Out_) <> 0 then
      begin
        Err := 'could not copy the app into the container: ' +
               Copy(Trim(Out_), 1, 400);
        RunOneShot('docker rm -f ' + ContainerNameFor(Project), '', Out_);
        Exit;
      end;
    end;

    Args.Clear;
    Args.Add('start');
    Args.Add(ContainerNameFor(Project));
    if RunArgs('docker', Args, '', Out_) <> 0 then
    begin
      Err := 'docker start failed: ' + Copy(Trim(Out_), 1, 400);
      RunOneShot('docker rm -f ' + ContainerNameFor(Project), '', Out_);
      Exit;
    end;
    Result := True;
  finally
    Args.Free;
  end;
end;

function DockerLogs(const Project: string): string;
var
  Out_: string;
begin
  Result := '';
  if RunOneShot('docker logs --tail 500 ' + ContainerNameFor(Project), '', Out_) = 0 then
    Result := Out_;
end;

function DockerAlive(const Project: string): Boolean;
var
  Out_: string;
begin
  Result := False;
  if RunOneShot('docker inspect -f {{.State.Running}} ' +
                ContainerNameFor(Project), '', Out_) <> 0 then Exit;
  Result := Pos('true', LowerCase(Out_)) > 0;
end;

procedure DockerStop(const Project: string);
var
  Out_: string;
begin
  { -t 3: give the app a moment to close its listener, then take it. }
  RunOneShot('docker stop -t 3 ' + ContainerNameFor(Project), '', Out_);
  RunOneShot('docker rm -f ' + ContainerNameFor(Project), '', Out_);
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
  Alive, IsContainer: Boolean;
  Logs: string;
  (* An app that dies on its own has to SAY so.

     Until now the only record of it was a state field a client had to poll
     for, so the desktop learned about a crashed app on its next tick and
     anything not polling never learned at all. Announcing it on the event
     stream puts it beside every other thing the board reports.

     Published after the lock is released, never inside it: PublishRaw takes
     the event module's own lock, and holding two global locks at once is
     how a deadlock gets written by accident. *)
  Exited: Boolean;

  procedure AnnounceExit;
  begin
    if not Exited then Exit;
    Exited := False;
    { Port 0: the app is gone, so it is not listening on anything. The exit
      code stays where it already is, on the run state a client reads. }
    PublishApp(FProject, 'exited', 0);
  end;

begin
  Exited := False;
  { A container has no pipe to drain: its output lives in the daemon and is
    read back with `docker logs`. Poll it on a slower beat -- shelling out
    twice a second would cost more than the output is worth. }
  GLock.Acquire;
  try
    R := FindRunning(FProject);
    IsContainer := (R <> nil) and (R.Container <> '');
  finally
    GLock.Release;
  end;

  if IsContainer then
  begin
    while not Terminated do
    begin
      Logs := DockerLogs(FProject);
      Alive := DockerAlive(FProject);
      GLock.Acquire;
      try
        R := FindRunning(FProject);
        if R = nil then Break;
        if Logs <> '' then
        begin
          { docker logs returns the whole tail each time, so replace rather
            than append -- appending would duplicate every line per poll. }
          R.Log := '$ docker run (' + DockerImage + ')  ' + R.Command + #10 + Logs;
          if Length(R.Log) > MaxLogBytes then
            R.Log := Copy(R.Log, Length(R.Log) - (MaxLogBytes div 2), MaxInt);
        end;
        if (not Alive) and (R.State = rsRunning) then
        begin
          R.State := rsExited;
          Exited := True;
          LogInfo('app %s container exited', [FProject]);
        end;
      finally
        GLock.Release;
      end;
      AnnounceExit;
      if not Alive then Break;
      Sleep(1500);
    end;
    Exit;
  end;

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
          Exited := True;
          LogInfo('app %s exited with code %d', [FProject, R.ExitCode]);
        end;
      end;
    finally
      GLock.Release;
    end;
    AnnounceExit;
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
  begin
    Err := 'app.json has no "run" command for this kind';
    Exit;
  end;
  { The manifest's build line is executed through a shell before the run
    command, on the same consent -- so it belongs in the plan. Showing
    only the run line would let a model-authored manifest hide arbitrary
    shell in `build` behind a benign-looking confirmation. }
  { sLineBreak, not LineEnding: the latter is FPC-only and this unit is
    compiled by Delphi too. }
  if Trim(Info.Build) <> '' then
    Result := Trim(Info.Build) + sLineBreak + Result;
  (* The port isn't claimed until the app starts, so show a placeholder a
     person reads as one -- the raw brace token in a consent prompt looks
     like the command is broken. Paren-star: the token itself would close a
     curly-brace comment. *)
  Result := StringReplace(Result, '{port}', '<port>', [rfReplaceAll, rfIgnoreCase]);
end;

function StartApp(const Project: string; Consented: Boolean;
  out Info: TRunInfo; out Err: string): Boolean;
var
  App: TAppInfo;
  R: TRunning;
  AppDir, Cmd, Exe, Out_, ContainerId: string;
  Args, Env: TStringList;
  Port, RC: Integer;
begin
  Err := '';
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Project := Project; Info.State := rsStopped;
  Info.Started := ''; Info.Command := ''; Info.Error := '';
  Info.Backend := RunnerBackendName;

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
    { Docker mode: a detached container instead of a host child. The command
      is unchanged -- what changes is the boundary it runs inside. }
    if DockerConfigured then
    begin
      R := TRunning.Create;
      R.Project := Project;
      R.Port    := Port;
      R.Command := Cmd;
      R.Started := NowIsoUtc;
      R.Log     := '$ docker run (' + DockerImage + ')  ' + Cmd + #10;
      if not DockerRun(Project, AppDir, Cmd, Port, Env, ContainerId, Err) then
      begin
        R.State := rsFailed;
        R.Error := Err;
        R.Log := R.Log + Err + #10;
        GLock.Acquire;
        try
          GApps.AddObject(Project, R);
        finally
          GLock.Release;
        end;
        Info := AppRunInfo(Project);
        Exit;
      end;
      R.Container := ContainerId;
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
        LogInfo('app %s started in a container on port %d: %s', [Project, Port, Cmd])
      else
        LogInfo('app %s started in a container: %s', [Project, Cmd]);
      Info := AppRunInfo(Project);
      Result := Info.State = rsRunning;
      Exit;
    end;

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
  if R.Container <> '' then
    DockerStop(Project)
  else if (R.Proc <> nil) and R.Proc.Running then
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
  Result.Backend := RunnerBackendName;
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
    { A container tells us it is docker; only the endpoint tells us WHERE.
      Reporting a remote container as plain 'docker' would have the clients
      say "on the PasClaw host" about a machine that is not it. }
    if R.Container = '' then Result.Backend := 'host'
    else if DockerIsRemote then Result.Backend := 'docker-remote'
    else Result.Backend := 'docker';
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
