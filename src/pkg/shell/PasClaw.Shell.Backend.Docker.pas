(*
  PasClaw.Shell.Backend.Docker - shell backend that spawns a
  long-running container at StartSession and `docker exec`s into it
  per call. Tears the container down at CloseSession.

  Workspace handling: we bind-mount $PASCLAW_HOME/workspace at the
  SAME path inside the container. Same-path means fs_read /
  fs_write on the host process work as-is (they're reading and
  writing the same files the bind mount exposes inside the
  container), and the model's mental model "I'm in workspace/"
  stays consistent whether the command runs inside docker or
  whether PasClaw reads the file directly on the host. Operators
  inspect with `ls ~/.pasclaw/workspace/` on the host. ✓

  Windows exception: a Linux container can't hold a `C:\` path, so
  same-path is impossible there. ContainerPath maps the bind roots
  to fixed POSIX mount points (workspace -> /workspace, tmp ->
  /pasclaw/tmp, run -> /pasclaw/run) and `-w` / shell_exec's pinned
  cwd are translated through it. shell_exec works; execute_code,
  which embeds an absolute host path in the command it runs
  (`bash C:\...\script`), still needs per-command path translation
  and is a tracked Windows follow-up.

  No host shell: every docker invocation is built as an argv vector
  and spawned via RunArgvCapture (CreateProcessW / execvp / TProcess --
  no intermediate /bin/sh or cmd.exe). The model's command reaches the
  container as a single argv element after `sh -c`, so the host shell
  never parses it. This is what keeps Windows correct: cmd.exe would
  otherwise strip the POSIX quoting AND percent-expand `%VAR%` in
  container commands like `printf '%s\n'` or `date +%Y` before docker
  ever saw them.

  Container naming: `pasclaw-<session-id>` (truncated + sanitised
  for Docker's name restrictions). Same SessionId across multiple
  StartSession calls is idempotent -- StartSession is a no-op when
  a container by that name is already running.

  Failure mode: on a Docker daemon that isn't running, or an image
  that fails to pull, StartSession raises a clear exception so the
  command bootstrap can surface it and refuse to start the session.
  Silently falling back to the local backend would defeat the
  security expectation the operator opted into.

  Keep-alive: the container's foreground process is `tail -f
  /dev/null` -- an infinitely-idle sleep loop that the OS exits
  when SIGTERM lands at CloseSession. No risk of the container
  exiting on its own and leaving exec calls without a target.

  v1 scope:
    - shell_exec and execute_code redirect (the high-risk surface)
    - fs_* keep operating on the host workspace (bind mount makes
      them see the same files)
    - No SSH backend yet -- Phase 2
    - Sandbox denylist still runs BEFORE every dispatch so the
      same protections apply across backends
*)
unit PasClaw.Shell.Backend.Docker;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Shell.Backend;

type
  TDockerBackendOptions = record
    Image:       string;   { e.g. 'debian:bookworm-slim' (default) }
    Network:     string;   { 'bridge' (default) | 'host' | 'none' }
    ExtraMounts: TStringList;   { each entry passed verbatim to -v;
                                  caller owns the list }
    Privileged:  Boolean;
    User:        string;   { '' = default; non-empty -> -u <user> }
  end;

function DefaultDockerBackendOptions: TDockerBackendOptions;

type
  TDockerShellBackend = class(TInterfacedObject, IShellBackend, IShellPathMapper)
  private
    FOpts:  TDockerBackendOptions;
    FLock:  TCriticalSection;
    FAlive: TStringList;   { session ids whose containers are running }
    function ContainerName(const SessionId: string): string;
    function IsRunning(const SessionId: string): Boolean;
    procedure SpawnContainer(const SessionId: string);
    procedure StopContainer(const SessionId: string);
  public
    constructor Create(const Opts: TDockerBackendOptions);
    destructor  Destroy; override;
    function Name: string;
    function Describe: string;
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);
    function Exec(const SessionId, Cmd, WorkDir: string;
                  ExtraEnv: TStringList;
                  out Output: string): Integer;
    { IShellPathMapper }
    function HostToContainerPath(const HostPath: string): string;
  end;

{ Probe: is the `docker` CLI on PATH and answering `docker info`?
  Bootstrap calls this before SetActiveShellBackend so an operator
  with shell_backend=docker but no daemon gets a clean error. }
function DockerCliReachable(out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Logger,
  PasClaw.Platform,
  PasClaw.Utils,
  PasClaw.Config;     { GetHome -- workspace bind-mount path. The
                        TShellBackendKind enum is exported from
                        PasClaw.Shell.Backend; PasClaw.Config uses
                        IT for its TConfig.ShellBackend field, so
                        this back-edge stays acyclic. }

const
  KeepAliveCmd = 'tail -f /dev/null';

function DefaultDockerBackendOptions: TDockerBackendOptions;
begin
  Result.Image      := 'debian:bookworm-slim';
  Result.Network    := 'bridge';
  Result.ExtraMounts := nil;
  Result.Privileged := False;
  Result.User       := '';
end;

{$IFDEF MSWINDOWS}
function ToPosixSlashes(const S: string): string;
begin
  Result := StringReplace(S, '\', '/', [rfReplaceAll]);
end;

function MapUnderRoot(const HostPath, HostRoot, ContainerRoot: string;
                      out Mapped: string): Boolean;
{ True when HostPath is HostRoot or a descendant of it; yields the
  container path with the root prefix swapped and separators
  POSIX-normalised. Case-insensitive because Windows paths are. }
var
  Rest: string;
begin
  Result := False;
  if (HostRoot = '') or (HostPath = '') then Exit;
  if SameText(HostPath, HostRoot) then
  begin
    Mapped := ContainerRoot;
    Exit(True);
  end;
  if (Length(HostPath) > Length(HostRoot)) and
     SameText(Copy(HostPath, 1, Length(HostRoot) + 1), HostRoot + PathDelim) then
  begin
    Rest := Copy(HostPath, Length(HostRoot) + 2, MaxInt);
    Mapped := ContainerRoot + '/' + ToPosixSlashes(Rest);
    Result := True;
  end;
end;
{$ENDIF}

function ContainerPath(const HostPath: string): string;
{ The path the Linux container sees for a given host path.

  POSIX: identity. The bind mounts are same-path (host /x mounted at
  container /x), so no translation -- byte-identical to before.

  Windows: a Linux container cannot hold a `C:\` path, so same-path
  is impossible. Map the three bind roots ($PASCLAW_HOME/workspace,
  /tmp, /run) to fixed POSIX mount points and rewrite descendants
  accordingly. This is what lets `-w <workspace>`, shell_exec's
  workspace-pinned cwd, and the script path execute_code bakes into
  its command (via IShellPathMapper.HostToContainerPath) resolve
  inside the container. }
{$IFDEF MSWINDOWS}
var
  Home, M: string;
{$ENDIF}
begin
  {$IFDEF MSWINDOWS}
  if HostPath = '' then Exit('');
  Home := GetHome;
  if MapUnderRoot(HostPath, JoinPath(Home, 'workspace'), '/workspace', M) then Exit(M);
  if MapUnderRoot(HostPath, JoinPath(Home, 'tmp'), '/pasclaw/tmp', M) then Exit(M);
  if MapUnderRoot(HostPath, JoinPath(Home, 'run'), '/pasclaw/run', M) then Exit(M);
  { Unknown root: best-effort POSIXify. Only meaningful if the operator
    added a matching ExtraMount; otherwise it isn't mounted anyway. }
  Result := ToPosixSlashes(HostPath);
  {$ELSE}
  Result := HostPath;
  {$ENDIF}
end;

function DockerCliReachable(out ErrMsg: string): Boolean;
var
  ExitCode: Integer;
  Out_: string;
  Args: TStringList;
begin
  ErrMsg := '';
  Args := TStringList.Create;
  try
    Args.Add('info');
    Args.Add('--format');
    Args.Add('{{.ServerVersion}}');
    ExitCode := RunArgvCapture('docker', Args, '', Out_);
  finally
    Args.Free;
  end;
  Result := ExitCode = 0;
  if not Result then
    ErrMsg := 'docker CLI not reachable: ' + Trim(Out_) +
              ' (is the daemon running and on PATH?)';
end;

constructor TDockerShellBackend.Create(const Opts: TDockerBackendOptions);
begin
  inherited Create;
  FOpts  := Opts;
  FLock  := TCriticalSection.Create;
  FAlive := TStringList.Create;
  FAlive.Duplicates := dupIgnore;
  FAlive.Sorted := True;
end;

destructor TDockerShellBackend.Destroy;
var
  i: Integer;
begin
  { Reap any containers still alive at process exit -- a clean
    shutdown path (CloseSession was called) won't have any entries
    here; a crash path will leave us with one container per
    in-flight session to clean up. }
  FLock.Enter;
  try
    for i := FAlive.Count - 1 downto 0 do
      try
        StopContainer(FAlive[i]);
      except
        { swallow; we're tearing down }
      end;
  finally
    FLock.Leave;
  end;
  FAlive.Free;
  FLock.Free;
  inherited Destroy;
end;

function TDockerShellBackend.Name: string;
begin
  Result := 'docker';
end;

function TDockerShellBackend.Describe: string;
begin
  { Spell out that commands run in a LINUX container via /bin/sh, with the
    workspace at its container path -- otherwise, on a Windows host, the
    model follows the host platform and emits cmd.exe (`dir /s /b`) with
    C:\ paths, which fail inside the Linux container. ContainerPath gives
    the in-container workspace dir (same-path on POSIX, /workspace on
    Windows). }
  Result := Format('runs each command inside a per-session Linux Docker container ' +
                   '(image=%s, network=%s) via /bin/sh, so use POSIX commands ' +
                   '(ls, find, grep, cat) and POSIX paths -- NOT Windows cmd ' +
                   '(dir) or C:\ paths, even when the host is Windows. The ' +
                   'workspace is mounted at %s, which is the working directory',
                   [FOpts.Image, FOpts.Network,
                    ContainerPath(JoinPath(GetHome, 'workspace'))]);
end;

function TDockerShellBackend.ContainerName(const SessionId: string): string;
{ Docker name regex: [a-zA-Z0-9][a-zA-Z0-9_.-]*. SessionId is a UUID
  or similar in practice but we sanitise defensively. Truncate at
  48 chars after the "pasclaw-" prefix to stay under Docker's
  internal 64-char limit. }
var
  Safe: string;
  i: Integer;
  c: Char;
begin
  Safe := '';
  for i := 1 to Length(SessionId) do
  begin
    c := SessionId[i];
    if (c in ['a'..'z', 'A'..'Z', '0'..'9', '_', '.', '-']) then
      Safe := Safe + c
    else
      Safe := Safe + '_';
  end;
  if Length(Safe) > 48 then Safe := Copy(Safe, 1, 48);
  if Safe = '' then Safe := 'default';
  Result := 'pasclaw-' + Safe;
end;

function TDockerShellBackend.IsRunning(const SessionId: string): Boolean;
{ Caller does NOT hold the lock; we take it. }
begin
  FLock.Enter;
  try
    Result := FAlive.IndexOf(SessionId) >= 0;
  finally
    FLock.Leave;
  end;
end;

procedure AddBindIfExists(Args: TStringList; const Path: string);
{ Append a `-v host:container` bind mount to the argv. On POSIX the
  container side is the same host path (ContainerPath is identity); on
  Windows it's the mapped POSIX mount point, since a Linux container
  can't hold a `C:\` path. ForceDirectories first because docker
  silently creates the source if missing AS ROOT, which then trips
  ENOENT on every operation the container does inside that path. No
  quoting: each token is a separate argv element passed straight to
  docker (RunArgvCapture spawns it without a host shell). }
begin
  if Path = '' then Exit;
  if not DirectoryExists(Path) then
    ForceDirectories(Path);
  Args.Add('-v');
  Args.Add(Path + ':' + ContainerPath(Path));
end;

procedure TDockerShellBackend.SpawnContainer(const SessionId: string);
{ Spawn a long-running idle container with workspace + tmp + run
  bind-mounted at the same path. Caller has already verified
  DockerCliReachable. The trio mounts are deliberate:
    workspace/  the model's working tree (the whole point)
    tmp/        execute_code's temp script files live here on the
                host; the container needs to see them to `bash <path>`
    run/        tool-RPC info file the `pasclaw __tool` callback uses
                so execute_code scripts can call back into the agent's
                tool registry from inside the container

  Anything else under $PASCLAW_HOME (config.json with provider keys,
  cache/, logs/) stays out so a leaky shell can't `cat` operator
  secrets. On POSIX the bind is same-path so PasClaw's host-side code
  needs no translation; on Windows ContainerPath maps the roots (see
  there). The command is built as an argv vector and spawned without a
  host shell -- no quoting, no cmd.exe percent-expansion. }
var
  Args: TStringList;
  WorkspacePath, Out_: string;
  ExitCode, i: Integer;
begin
  WorkspacePath := JoinPath(GetHome, 'workspace');
  Args := TStringList.Create;
  try
    Args.Add('run');
    Args.Add('-d');
    Args.Add('--rm');
    Args.Add('--name');
    Args.Add(ContainerName(SessionId));
    AddBindIfExists(Args, WorkspacePath);
    AddBindIfExists(Args, JoinPath(GetHome, 'tmp'));
    AddBindIfExists(Args, JoinPath(GetHome, 'run'));
    Args.Add('-w');
    Args.Add(ContainerPath(WorkspacePath));
    if (FOpts.ExtraMounts <> nil) then
      for i := 0 to FOpts.ExtraMounts.Count - 1 do
        if Trim(FOpts.ExtraMounts[i]) <> '' then
        begin
          Args.Add('-v');
          Args.Add(FOpts.ExtraMounts[i]);
        end;
    Args.Add('--network');
    Args.Add(FOpts.Network);
    if FOpts.Privileged then Args.Add('--privileged');
    if FOpts.User <> '' then
    begin
      Args.Add('-u');
      Args.Add(FOpts.User);
    end;
    Args.Add(FOpts.Image);
    Args.Add('sh');
    Args.Add('-c');
    Args.Add(KeepAliveCmd);

    LogInfo('shell-backend(docker): spawning %s (image=%s)',
            [ContainerName(SessionId), FOpts.Image]);
    ExitCode := RunArgvCapture('docker', Args, '', Out_);
  finally
    Args.Free;
  end;

  if ExitCode <> 0 then
    raise Exception.CreateFmt(
      'docker: failed to start container %s: %s',
      [ContainerName(SessionId), Trim(Out_)]);
  FLock.Enter;
  try
    FAlive.Add(SessionId);
  finally
    FLock.Leave;
  end;
end;

procedure TDockerShellBackend.StopContainer(const SessionId: string);
var
  Out_: string;
  Idx: Integer;
  Args: TStringList;
begin
  { Best-effort stop -- if Docker can't reach it (already gone,
    daemon died), proceed anyway. The --rm we passed at spawn means
    the container is removed automatically on stop. Output discarded. }
  Args := TStringList.Create;
  try
    Args.Add('stop');
    Args.Add('--time');
    Args.Add('2');
    Args.Add(ContainerName(SessionId));
    RunArgvCapture('docker', Args, '', Out_);
  finally
    Args.Free;
  end;
  FLock.Enter;
  try
    Idx := FAlive.IndexOf(SessionId);
    if Idx >= 0 then FAlive.Delete(Idx);
  finally
    FLock.Leave;
  end;
  LogInfo('shell-backend(docker): stopped %s', [ContainerName(SessionId)]);
end;

procedure TDockerShellBackend.StartSession(const SessionId: string);
begin
  { No empty-SessionId fallback. Codex P1 on PR #233: silently
    skipping Spawn here let Exec route to the host (RunOneShot),
    bypassing the isolation the operator asked for and the
    shell_exec description advertises. Every caller must allocate
    a SessionId; one-shot CLI turns allocate a synthetic id
    (RunSingleTurn). The Local backend ignores SessionId, so this
    extra strictness only affects docker/ssh. }
  if Trim(SessionId) = '' then
    raise Exception.Create(
      'shell-backend(docker): StartSession with empty SessionId. ' +
      'Each session must allocate an id before tools can run. ' +
      '(Caller bug -- file a PasClaw issue.)');
  if IsRunning(SessionId) then Exit;
  SpawnContainer(SessionId);
end;

procedure TDockerShellBackend.CloseSession(const SessionId: string);
begin
  if not IsRunning(SessionId) then Exit;
  StopContainer(SessionId);
end;

function TDockerShellBackend.Exec(const SessionId, Cmd, WorkDir: string;
                                  ExtraEnv: TStringList;
                                  out Output: string): Integer;
var
  Args: TStringList;
  i: Integer;
begin
  Output := '';

  { No host fallback. Codex P1 on PR #233 was right: silently
    routing to RunOneShot when SessionId is empty (or the container
    didn't start) bypasses the isolation the operator chose, AND
    the model thinks it's running in the container because the
    shell_exec description advertises it. The fix isn't a softer
    fallback -- the fix is for every entry point to allocate a
    session id; RunSingleTurn now does. Surface any remaining
    forgotten paths as a clear error rather than a security
    regression. }
  if Trim(SessionId) = '' then
  begin
    Output :=
      'shell-backend(docker): refusing to run with empty SessionId. ' +
      'StartShellSession must be called for every session that runs ' +
      'tools (CLI / TUI / heartbeat / embedder). Pass --backend local ' +
      'if a one-off host execution was intended.';
    Result := -1;
    Exit;
  end;
  if not IsRunning(SessionId) then
  begin
    Output :=
      'shell-backend(docker): container for SessionId "' + SessionId +
      '" is not running. StartSession may have failed; check docker daemon.';
    Result := -1;
    Exit;
  end;

  { Build `docker exec [-e ...] [-w ...] <name> sh -c <Cmd>` as an argv
    vector. Cmd is the model's command and becomes a SINGLE argv element
    passed to the container's `sh -c` -- the host never parses it, so
    quoting and (on Windows) cmd.exe percent-expansion can't corrupt it.
    The container sees the workspace at ContainerPath(WorkDir). }
  Args := TStringList.Create;
  try
    Args.Add('exec');
    if ExtraEnv <> nil then
      for i := 0 to ExtraEnv.Count - 1 do
        if Trim(ExtraEnv[i]) <> '' then
        begin
          Args.Add('-e');
          Args.Add(ExtraEnv[i]);
        end;
    if WorkDir <> '' then
    begin
      Args.Add('-w');
      Args.Add(ContainerPath(WorkDir));
    end;
    Args.Add(ContainerName(SessionId));
    Args.Add('sh');
    Args.Add('-c');
    Args.Add(Cmd);

    { Spawn on the HOST -- this is a docker CLI call, not the contained
      command. RunArgvCapture blocks until `docker exec` exits, which it
      does when the command inside the container exits, and propagates
      that exit code. }
    Result := RunArgvCapture('docker', Args, '', Output);
  finally
    Args.Free;
  end;
end;

function TDockerShellBackend.HostToContainerPath(const HostPath: string): string;
{ IShellPathMapper: let execute_code translate the script path it bakes
  into its command to the path the container will see. }
begin
  Result := ContainerPath(HostPath);
end;

end.
