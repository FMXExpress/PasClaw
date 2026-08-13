(*
  PasClaw.Shell.Backend.Factory - reads Cfg.ShellBackend + optional
  CLI override, builds the matching IShellBackend impl, installs it
  via SetActiveShellBackend. Called from each entry point's startup
  (pasclaw agent / tui / heartbeat / serve / gateway).

  This is the only place that knows how to translate from
  "TShellBackendConfig" + CLI flag to a concrete backend. Adding the
  SSH backend in Phase 2 lands here.
*)
unit PasClaw.Shell.Backend.Factory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Shell.Backend;

{ Build the backend dictated by Cfg + override. CLIOverride is the
  --backend flag value -- empty string means "use config". Returns
  the kind that was actually selected so the caller can print it.
  Raises Exception with a clear message on failure (docker not
  reachable when docker was selected, etc.) so the command startup
  can surface the error and exit. }
function InstallShellBackend(const Cfg: TConfig;
                              const CLIOverride: string;
                              out KindSelected: TShellBackendKind;
                              out Description: string): IShellBackend;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Utils,                 { JoinPath -- workspace cwd align (GetHome is in PasClaw.Config) }
  PasClaw.Tools.Sandbox,         { ConfigureSandbox -- re-point GWorkspace after the chdir }
  PasClaw.Shell.Backend.Local,
  PasClaw.Shell.Backend.Docker;

function ParseKind(const S: string; const Default_: TShellBackendKind): TShellBackendKind;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if L = 'local'  then Exit(sbLocal);
  if L = 'docker' then Exit(sbDocker);
  Result := Default_;
end;

function InstallShellBackend(const Cfg: TConfig;
                              const CLIOverride: string;
                              out KindSelected: TShellBackendKind;
                              out Description: string): IShellBackend;
var
  Backend: IShellBackend;
  Opts: TDockerBackendOptions;
  WsHost: string;
begin
  if CLIOverride <> '' then
    KindSelected := ParseKind(CLIOverride, Cfg.ShellBackend)
  else
    KindSelected := Cfg.ShellBackend;

  case KindSelected of
    sbDocker:
      begin
        { Docker is NOT probed here. Reachability + container spawn happen
          lazily on the first shell_exec/execute_code (see
          TDockerShellBackend.Exec), so a down/slow/wedged Docker never
          blocks serve/agent startup -- only chats that actually run a
          shell tool pay the cost, and the failure surfaces as that tool's
          result. (Previously a boot-time `docker info` here could hang the
          whole app; PR #286.) }
        Opts := DefaultDockerBackendOptions;
        if Cfg.ShellBackendDocker.Image   <> '' then Opts.Image   := Cfg.ShellBackendDocker.Image;
        if Cfg.ShellBackendDocker.Network <> '' then Opts.Network := Cfg.ShellBackendDocker.Network;
        Opts.User       := Cfg.ShellBackendDocker.User;
        Opts.Privileged := Cfg.ShellBackendDocker.Privileged;
        Backend := TDockerShellBackend.Create(Opts);

        { Align the host process cwd with the container's workspace mount.
          The docker backend bind-mounts $PASCLAW_HOME/workspace at
          /workspace and runs shell_exec there, but fs_read/fs_grep/fs_list
          run on the HOST and resolve relative paths against the process
          cwd -- which is usually PasClaw's launch dir (the exe dir), NOT
          the workspace. The model then sees two different trees for the
          same "." (shell_exec finds the project under /workspace; fs_*
          find the exe dir) and can't navigate. chdir-ing here makes fs_*'s
          "." == the container's /workspace. Docker-only; the local backend
          leaves the operator's launch cwd untouched. }
        WsHost := JoinPath(GetHome, ActiveWorkspaceName);
        if not DirectoryExists(WsHost) then ForceDirectories(WsHost);
        if DirectoryExists(WsHost) then
        begin
          SetCurrentDir(WsHost);
          { Re-point the sandbox at the new cwd. The surface called
            ConfigureSandbox BEFORE us, so (with restrict_to_workspace=true
            and sandbox.workspace empty) GWorkspace was pinned to the launch
            dir. After the chdir, fs tools canonicalize relative paths
            against WsHost; without this re-config a plain fs_read("foo")
            would resolve under WsHost yet be rejected as outside the stale
            GWorkspace, and shell_exec would pin to the stale dir. Codex P1
            on PR #267. Passing WsHost explicitly makes GWorkspace == cwd. }
          ConfigureSandbox(Cfg.Sandbox, WsHost);
        end;
      end;
  else
    { sbLocal -- and any unknown future enum value falls back here
      so the result is always non-nil. }
    Backend := TLocalShellBackend.Create;
  end;
  SetActiveShellBackend(Backend);
  Description := Backend.Describe;
  Result := Backend;
end;

end.
