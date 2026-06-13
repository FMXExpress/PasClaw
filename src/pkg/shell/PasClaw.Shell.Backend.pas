(*
  PasClaw.Shell.Backend - the abstraction shell_exec and execute_code
  go through to actually run a command. Today there's exactly one
  implementation (local: spawn /bin/sh -c or cmd.exe /c in the host
  process via PasClaw.Platform.RunOneShot); this PR adds the Docker
  backend (docker exec into a per-session container) behind the same
  IShellBackend interface.

  Why an interface and not just a switch inside Tool_Shell:

    - shell_exec, execute_code, and a future SSH backend all share
      the same dispatch shape (Cmd + WorkDir + ExtraEnv -> Output +
      ExitCode); a switch would duplicate that shape per caller.
    - Container lifecycle (StartSession / CloseSession) only makes
      sense if the dispatcher knows about sessions. Adding it to
      the interface keeps Tool_Shell / Tool_ExecuteCode unaware of
      WHICH backend is active -- they just call Exec.
    - Mock backends for tests (record what was asked of them, return
      scripted responses) drop in cleanly.

  Lifecycle: every entry point that runs a session (pasclaw agent,
  pasclaw tui, pasclaw heartbeat, pasclaw serve, pasclaw gateway)
  calls StartShellSession(SessionId) before the first RunToolLoop
  and CloseShellSession(SessionId) when the session ends. Local
  backends ignore both -- per-process state is the session. Docker
  backends spawn a container at Start and stop it at Close.

  Selection: SetActiveShellBackend installs the process-wide active
  backend. PasClaw.Shell.Backend.Factory builds the right one from
  Cfg.ShellBackend + an optional CLI override and calls
  SetActiveShellBackend at command startup.
*)
unit PasClaw.Shell.Backend;

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
  TShellBackendKind = (sbLocal, sbDocker);

  IShellBackend = interface
    ['{B7C0F5B3-2DCB-4A5F-9E40-7F2C6DBE1A11}']
    { Identifier for status output / log lines. e.g. 'local',
      'docker (image=debian:bookworm-slim)'. Never empty. }
    function Name: string;

    { Human-readable backend descriptor for the shell_exec tool
      description -- the model reads this to know where its
      commands run, so a "wget X && make install" doesn't expect
      host persistence. }
    function Describe: string;

    { Per-session lifecycle. Local impl is a no-op. Docker impl
      spawns a long-running idle container at Start (image pull may
      block on first use) and stops it at Close. Multiple calls
      with the same SessionId are idempotent. SessionId can be ''
      for one-shot paths where a session-scoped container isn't
      worth spinning -- backend impls may either spin a per-call
      container or fall back to the legacy local behaviour
      (documented per-impl). }
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);

    { Run a command. WorkDir = '' uses the backend's default cwd.
      ExtraEnv = nil means no extra env. Returns the process's
      exit code; -1 on spawn failure. Output captures combined
      stdout+stderr. Mirrors RunOneShotWithEnv's contract so the
      local backend is a thin wrapper. }
    function Exec(const SessionId, Cmd, WorkDir: string;
                  ExtraEnv: TStringList;
                  out Output: string): Integer;
  end;

  { Optional capability. A backend that runs commands in a DIFFERENT
    filesystem namespace than the host (docker: a Linux container, and
    on Windows the host path can't even exist inside it) implements this
    so a caller that bakes an absolute HOST path into a command --
    notably execute_code's `bash <script>` -- can translate it to the
    path the command will actually see. Queried with Supports(), so
    host-namespace backends (local) simply don't implement it and the
    path is used unchanged. }
  IShellPathMapper = interface
    ['{3F2A9C84-1B6E-4D7A-9C2F-8E5B0A1D6F33}']
    function HostToContainerPath(const HostPath: string): string;
  end;

{ Process-wide active backend. nil until set; helpers below treat
  nil as "use the local fallback" so a caller who never called
  SetActiveShellBackend (test harnesses, scripts that didn't go
  through a command bootstrap) still works. }
procedure SetActiveShellBackend(Backend: IShellBackend);
function  GetActiveShellBackend: IShellBackend;

{ Convenience wrappers that dispatch through the active backend.
  Tool_Shell and Tool_ExecuteCode call these instead of the
  Platform.RunOneShot* primitives directly. SessionId carries
  through so the Docker backend can pick the right container. }
function RunOneShotViaBackend(const SessionId, Cmd, WorkDir: string;
                              out Output: string): Integer;
function RunOneShotWithEnvViaBackend(const SessionId, Cmd, WorkDir: string;
                                     ExtraEnv: TStringList;
                                     out Output: string): Integer;

{ Translate a host path to the path the active backend's commands will
  see. Identity unless the active backend implements IShellPathMapper
  (docker). execute_code uses this for the script path it embeds in the
  command it runs, so `bash <script>` resolves inside the container. }
function HostToContainerPathViaBackend(const HostPath: string): string;

{ Convenience: lifecycle for the CURRENT (active) backend. Safe
  to call when no backend is set -- both are no-ops. }
procedure StartShellSession(const SessionId: string);
procedure CloseShellSession(const SessionId: string);

{ The "current session" the next Exec should dispatch through.
  Tool_Shell and Tool_ExecuteCode read this via GetCurrentSessionId
  so they don't need a TToolLoopConfig handle just to find the
  backend container. The command bootstrap sets it after
  StartShellSession; one process at a time (gateway concurrency
  across sessions is a follow-up). Empty when no session is active
  -- backends fall back to a per-call execution path in that case
  (see TDockerShellBackend.Exec for the documented contract). }
procedure SetCurrentSessionId(const SessionId: string);
function  GetCurrentSessionId: string;

implementation

uses
  PasClaw.Platform;   { used by the local-fallback path when no
                        backend is installed at call time -- keeps
                        legacy test paths working without changes }

var
  GActive:           IShellBackend = nil;
  GCurrentSessionId: string = '';

procedure SetActiveShellBackend(Backend: IShellBackend);
begin
  GActive := Backend;
end;

function GetActiveShellBackend: IShellBackend;
begin
  Result := GActive;
end;

function RunOneShotViaBackend(const SessionId, Cmd, WorkDir: string;
                              out Output: string): Integer;
begin
  if GActive <> nil then
    Result := GActive.Exec(SessionId, Cmd, WorkDir, nil, Output)
  else
    Result := RunOneShot(Cmd, WorkDir, Output);
end;

function RunOneShotWithEnvViaBackend(const SessionId, Cmd, WorkDir: string;
                                     ExtraEnv: TStringList;
                                     out Output: string): Integer;
begin
  if GActive <> nil then
    Result := GActive.Exec(SessionId, Cmd, WorkDir, ExtraEnv, Output)
  else
    Result := RunOneShotWithEnv(Cmd, WorkDir, ExtraEnv, Output);
end;

function HostToContainerPathViaBackend(const HostPath: string): string;
var
  Mapper: IShellPathMapper;
begin
  if (GActive <> nil) and Supports(GActive, IShellPathMapper, Mapper) then
    Result := Mapper.HostToContainerPath(HostPath)
  else
    Result := HostPath;
end;

procedure StartShellSession(const SessionId: string);
begin
  if GActive <> nil then GActive.StartSession(SessionId);
end;

procedure CloseShellSession(const SessionId: string);
begin
  if GActive <> nil then GActive.CloseSession(SessionId);
end;

procedure SetCurrentSessionId(const SessionId: string);
begin
  GCurrentSessionId := SessionId;
end;

function GetCurrentSessionId: string;
begin
  Result := GCurrentSessionId;
end;

end.
