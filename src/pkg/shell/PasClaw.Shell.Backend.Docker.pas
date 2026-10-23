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
  TDockerShellBackend = class(TInterfacedObject, IShellBackend, IShellPathMapper,
                              IShellHostRPC)
  private
    FOpts:  TDockerBackendOptions;
    FLock:  TCriticalSection;
    FAlive: TStringList;   { session ids whose containers are running }
    FGateway: string;      { cached default-bridge gateway, '' = none/unknown }
    FGatewayProbed: Boolean;
    function ContainerName(const SessionId: string): string;
    function IsRunning(const SessionId: string): Boolean;
    function HostGatewayIP: string;
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
    { IShellHostRPC }
    function RpcBindIP: string;
    function RpcConnectHost: string;

    { The `docker run` argv SpawnContainer spawns. Public so a test can
      read the flags without a daemon on the box -- which is how the
      whole file is tested (see TestDockerRefusesEmptySessionId). Appends
      to Args; the caller owns the list. }
    procedure BuildRunArgv(const SessionId: string; Args: TStringList);
  end;

{ The first IPv4 address in `docker network inspect`'s gateway output
  (the template can emit several, one per IPAM config, in either family).
  '' when there is none. A dual-stack bridge lists both families and Indy
  needs IPVersion set to bind a v6 address, which nothing here does -- so
  this takes the one we can actually listen on and yields '' rather than
  an address that would only fail the bind. Exposed for tests. }
function FirstIPv4Token(const S: string): string;

{ 'bridge' (the default), a user-defined network, or anything else that
  gives the container its OWN network namespace -- the case where the
  host's loopback is not the container's. False for 'host' (shared with
  the host, loopback works as-is) and 'none' (no networking at all, so
  there is nothing to reach the host with). Exposed for tests. }
function DockerNetworkIsolatesHost(const Network: string): Boolean;

{ The name the container resolves to the host. Docker's own convention;
  provided natively by Docker Desktop and added explicitly on Linux via
  --add-host=<name>:host-gateway. Exposed for tests. }
const
  DockerHostAlias = 'host.docker.internal';

{ Probe: is the `docker` CLI on PATH and answering `docker info`?
  Bootstrap calls this before SetActiveShellBackend so an operator
  with shell_backend=docker but no daemon gets a clean error. }
function DockerCliReachable(out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Logger,
  PasClaw.Platform,
  PasClaw.Tools.Worktree,   { WorktreeMountFor -- the worktree directory to mount }
  PasClaw.Utils,
  PasClaw.Config;     { GetHome -- workspace bind-mount path. The
                        TShellBackendKind enum is exported from
                        PasClaw.Shell.Backend; PasClaw.Config uses
                        IT for its TConfig.ShellBackend field, so
                        this back-edge stays acyclic. }

const
  KeepAliveCmd = 'tail -f /dev/null';

  { Timeouts (ms) for `docker` invocations, so a wedged Docker daemon
    fails fast with a clear error instead of hanging serve/agent (Windows:
    Docker Desktop mid-restart is the classic case). `docker info` is the
    reachability probe and is the one that actually wedges -- hard-bound it
    short. `docker stop` is bounded so cleanup on exit can't wedge either.
    `docker run` is deliberately NOT capped: a first-run pull of a large or
    private image can legitimately take minutes, and a fixed cap would
    abort an otherwise-healthy backend (Codex P2 on PR #286). The short
    info probe already gates daemon health before we ever reach run. }
  DockerInfoTimeoutMs = 12000;     { DockerCliReachable probe }
  DockerStopTimeoutMs = 15000;     { StopContainer }

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
  if MapUnderRoot(HostPath, JoinPath(Home, ActiveWorkspaceName), '/workspace', M) then Exit(M);
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
    ExitCode := RunArgvCapture('docker', Args, '', Out_, DockerInfoTimeoutMs);
  finally
    Args.Free;
  end;
  Result := ExitCode = 0;
  if not Result then
    ErrMsg := 'docker CLI not reachable: ' + Trim(Out_) +
              ' (is the daemon running and on PATH?)';
end;

function FirstIPv4Token(const S: string): string;
var
  Tok: string;
  i: Integer;
begin
  Result := '';
  Tok    := '';
  for i := 1 to Length(S) + 1 do
    if (i <= Length(S)) and (S[i] > ' ') then
      Tok := Tok + S[i]
    else
    begin
      if (Pos('.', Tok) > 0) and (Pos(':', Tok) = 0) then
      begin
        { Strip a /prefix if the template ever carries one. }
        if Pos('/', Tok) > 0 then Tok := Copy(Tok, 1, Pos('/', Tok) - 1);
        Exit(Tok);
      end;
      Tok := '';
    end;
end;

function DockerNetworkIsolatesHost(const Network: string): Boolean;
var
  N: string;
begin
  N := LowerCase(Trim(Network));
  Result := (N <> 'host') and (N <> 'none');
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
  {$IFDEF MSWINDOWS}
  { Windows host only: without this the model follows the host platform and
    emits cmd.exe (`dir /s /b`, C:\ paths) into the Linux container, which
    fails. Spell out Linux/POSIX, the mapped container cwd (/workspace),
    AND a concrete host->container path example -- the model otherwise sees
    host paths everywhere (fs_read/fs_list return them) and mistranslates,
    e.g. C:\...\workspace\DelphiPalAI became /workspace/workspace/DelphiPalAI
    (the 'workspace' segment counted twice). On POSIX hosts the container
    shares the host's conventions and the workspace is same-path, so no
    such warning is needed -- see the ELSE branch (original wording). }
  Result := Format('runs each command inside a per-session Linux Docker container ' +
                   '(image=%s, network=%s) via /bin/sh. Use POSIX commands (ls, find, ' +
                   'grep, cat) and POSIX paths -- NOT Windows cmd (dir) or C:\ paths ' +
                   'even though the host is Windows. The workspace is mounted at %s, ' +
                   'which is the working directory: a host path %s\NAME appears here ' +
                   'as %s/NAME (do not reuse the C:\ path or repeat "workspace"). ' +
                   'Prefer paths relative to the working directory.',
                   [FOpts.Image, FOpts.Network,
                    ContainerPath(JoinPath(GetHome, ActiveWorkspaceName)),
                    JoinPath(GetHome, ActiveWorkspaceName),
                    ContainerPath(JoinPath(GetHome, ActiveWorkspaceName))]);
  {$ELSE}
  Result := Format('runs inside a per-session Docker container (image=%s, network=%s; ' +
                   'workspace bind-mounted at the same path so the model sees the ' +
                   'same files you do on the host)',
                   [FOpts.Image, FOpts.Network]);
  {$ENDIF}
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

procedure TDockerShellBackend.BuildRunArgv(const SessionId: string;
                                           Args: TStringList);
{ The argv for a long-running idle container with workspace + tmp + run
  bind-mounted at the same path. The trio mounts are deliberate:
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
  WorkspacePath{$IFNDEF MSWINDOWS}, WtMount{$ENDIF}: string;
  i: Integer;
begin
  WorkspacePath := JoinPath(GetHome, ActiveWorkspaceName);
  Args.Add('run');
  Args.Add('-d');
  Args.Add('--rm');
  Args.Add('--name');
  Args.Add(ContainerName(SessionId));
  AddBindIfExists(Args, WorkspacePath);
  AddBindIfExists(Args, JoinPath(GetHome, 'tmp'));
  {$IFNDEF MSWINDOWS}
  { The running executable, read-only at the same path, so a script's
    `tool` function (and `pasclaw __tool`) exists inside the container
    without installing anything there. POSIX only: a Windows host binary
    cannot run in a Linux container. The image must be glibc-compatible
    with the host build; the Debian image this backend defaults to is. }
  Args.Add('-v');
  Args.Add(ExpandFileName(ParamStr(0)) + ':' + ExpandFileName(ParamStr(0)) + ':ro');
  {$ENDIF}
  AddBindIfExists(Args, JoinPath(GetHome, 'run'));
  {$IFNDEF MSWINDOWS}
  (* Where worktrees of the workspace's repository go, at the same path.

     The worktree tools run git through this backend, so `git worktree
     add` runs in here -- and the default worktree directory is BESIDE
     the repository (<repo>-worktrees), outside the workspace mount. The
     checkout was built in the container's own filesystem and registered
     in the host's .git, and the host got back a path with nothing in it.
     (Codex P1 on #612.) Not mounted when it is already under the
     workspace (worktree.directory set inside it), when the feature is
     off, or when the workspace is not a repository.

     POSIX only: a same-path mount cannot hold a C:\ path, and on Windows
     the worktree tools' own host-side check refuses a worktree the host
     cannot see and rolls it back, which is the safe failure. *)
  WtMount := WorktreeMountFor(WorkspacePath);
  { Compared expanded: WtMount comes from the repository root on disk,
    which is absolute, while WorkspacePath is whatever PASCLAW_HOME was. }
  if (WtMount <> '') and
     (Pos(IncludeTrailingPathDelimiter(ExpandFileName(WorkspacePath)),
          IncludeTrailingPathDelimiter(WtMount)) <> 1) then
    AddBindIfExists(Args, WtMount);
  {$ENDIF}
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
  if DockerNetworkIsolatesHost(FOpts.Network) then
  begin
    (* Make the host reachable by name from inside. Without this the
       execute_code tool-RPC callback simply does not work on a bridge
       network: the script's `tool ...` dials the port the parent
       advertised, and from in here 127.0.0.1 is the container. Docker
       Desktop supplies this name itself; on Linux it only exists if we
       ask, hence the explicit mapping. (Codex P1 on #609.)

       `host-gateway` is Docker's own alias for the host address and
       needs Docker >= 20.10 -- the same address RpcBindIP binds, which
       is why both read the DEFAULT bridge. *)
    Args.Add('--add-host');
    Args.Add(DockerHostAlias + ':host-gateway');
  end
  else if LowerCase(Trim(FOpts.Network)) = 'none' then
    LogInfo('shell-backend(docker): network=none -- execute_code scripts ' +
            'cannot call tools back (`tool ...`), and with code mode on ' +
            'that is how MCP tools are reached');
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
end;

procedure TDockerShellBackend.SpawnContainer(const SessionId: string);
{ Run what BuildRunArgv composed. Caller has already verified
  DockerCliReachable. }
var
  Args: TStringList;
  Out_: string;
  ExitCode: Integer;
begin
  Args := TStringList.Create;
  try
    BuildRunArgv(SessionId, Args);
    LogInfo('shell-backend(docker): spawning %s (image=%s)',
            [ContainerName(SessionId), FOpts.Image]);
    { Unbounded on purpose -- a cache-miss image pull can run for minutes;
      see the timeout-const comment. Daemon health is already gated by the
      bounded `docker info` probe before we get here. }
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
    RunArgvCapture('docker', Args, '', Out_, DockerStopTimeoutMs);
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
  Err: string;
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
  { Lazy start: the container is spawned on first use, not at boot, so a
    down/slow/wedged Docker only affects chats that actually run a shell
    tool -- never serve/agent startup. DockerCliReachable is the bounded
    health probe; SpawnContainer does the (unbounded) pull+run. Both stay
    isolation-safe -- no host fallback. Surface either failure as the tool
    result rather than crashing the agent loop. (If the operator pre-spawned
    via StartShellSession, IsRunning is already true and we skip straight to
    exec.) }
  if not IsRunning(SessionId) then
  begin
    if not DockerCliReachable(Err) then
    begin
      Output := 'shell-backend(docker): ' + Err +
                ' -- start Docker, or set shell_backend=local in config.json.';
      Result := -1;
      Exit;
    end;
    try
      SpawnContainer(SessionId);
    except
      on E: Exception do
      begin
        Output := 'shell-backend(docker): ' + E.Message;
        Result := -1;
        Exit;
      end;
    end;
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
      that exit code. The same wall-clock bound as the local backend: a
      contained command that never exits must not hang the turn either. }
    Result := RunArgvCapture('docker', Args, '', Output, EffectiveShellTimeoutMs);
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

function TDockerShellBackend.HostGatewayIP: string;
(* The default bridge's gateway -- the host address a container reaches the
   host at, and the same address `--add-host=NAME:host-gateway` resolves to
   (the daemon's host-gateway-ip defaults to exactly this). The DEFAULT
   bridge on purpose, not FOpts.Network: host-gateway is defined off the
   default bridge whichever network the container joins, so inspecting the
   one the container is on would hand us a different address than the name
   inside it resolves to.

   Probed once and cached: this is per execute_code call, and a daemon
   round-trip on each would be felt. '' on any failure -- caller treats
   that as "bind loopback and hope host.docker.internal forwards", which
   is the Docker Desktop case anyway. *)
var
  Args: TStringList;
  Out_: string;
begin
  FLock.Enter;
  try
    if FGatewayProbed then Exit(FGateway);
    FGatewayProbed := True;
    FGateway := '';
    Args := TStringList.Create;
    try
      Args.Add('network');
      Args.Add('inspect');
      Args.Add('bridge');
      Args.Add('--format');
      { Range, not `index .IPAM.Config 0`: an empty Config makes the
        index form fail the whole template. }
      Args.Add('{{range .IPAM.Config}}{{.Gateway}} {{end}}');
      if RunArgvCapture('docker', Args, '', Out_, DockerInfoTimeoutMs) = 0 then
        FGateway := FirstIPv4Token(Out_);
    finally
      Args.Free;
    end;
    if FGateway = '' then
      LogDebug('shell-backend(docker): no bridge gateway found -- ' +
               'tool-rpc will listen on loopback only');
    Result := FGateway;
  finally
    FLock.Leave;
  end;
end;

function TDockerShellBackend.RpcBindIP: string;
{ IShellHostRPC: where execute_code's tool-RPC server has to listen for
  `pasclaw __tool` inside the container to reach it. }
begin
  if not DockerNetworkIsolatesHost(FOpts.Network) then
    Result := ''          { --network host: the container's loopback IS ours }
  else
    Result := HostGatewayIP;
end;

function TDockerShellBackend.RpcConnectHost: string;
{ IShellHostRPC: what the contained command dials. '' leaves the
  discovery file on 127.0.0.1, which is right when the container shares
  our network namespace -- and the only thing on offer with --network
  none, where the callback cannot work at all (SpawnContainer says so). }
begin
  if DockerNetworkIsolatesHost(FOpts.Network) then
    Result := DockerHostAlias
  else
    Result := '';
end;

end.
