(*
  PasClaw.Shell.Backend.Local - the default shell backend. Forwards
  every call straight to PasClaw.Platform.RunOneShot /
  RunOneShotWithEnv, which is what shell_exec and execute_code used
  before the backend abstraction. Per-session lifecycle is a no-op
  because the local shell IS the host process -- there's no
  container to spin up or tear down.

  Keeping this as a class with the IShellBackend interface (instead
  of treating "no backend" as "use local") means:

    - The IShellBackend chain is uniform from every caller's point
      of view; the local case isn't a special branch in Tool_Shell.
    - Status output / log lines from "local" come out the same way
      they do for "docker (image=debian:bookworm-slim)".
    - The Cfg.ShellBackend = "local" path is explicit and tested,
      not "whatever the default was when no backend got set".

  PasClaw.Shell.Backend.Factory builds an instance of this when
  Cfg.ShellBackend = sbLocal.
*)
unit PasClaw.Shell.Backend.Local;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Shell.Backend;

type
  TLocalShellBackend = class(TInterfacedObject, IShellBackend)
  public
    function Name: string;
    function Describe: string;
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);
    function Exec(const SessionId, Cmd, WorkDir: string;
                  ExtraEnv: TStringList;
                  out Output: string): Integer;
  end;

implementation

uses
  PasClaw.Platform;

function TLocalShellBackend.Name: string;
begin
  Result := 'local';
end;

function TLocalShellBackend.Describe: string;
begin
  Result := 'runs in the host process (/bin/sh -c on POSIX, cmd.exe /c on Windows)';
end;

procedure TLocalShellBackend.StartSession(const SessionId: string);
begin
  { No-op. The host process IS the session's shell environment.
    Files the model writes via fs_*/shell_exec persist on the host
    filesystem regardless of session boundaries -- session
    semantics for "what files exist" come from the existing
    Cfg.Sandbox.RestrictToWorkspace + checkpoint machinery, not
    from anything this backend would do. }
end;

procedure TLocalShellBackend.CloseSession(const SessionId: string);
begin
  { No-op. See StartSession. }
end;

function TLocalShellBackend.Exec(const SessionId, Cmd, WorkDir: string;
                                 ExtraEnv: TStringList;
                                 out Output: string): Integer;
begin
  if ExtraEnv <> nil then
    Result := RunOneShotWithEnv(Cmd, WorkDir, ExtraEnv, Output)
  else
    Result := RunOneShot(Cmd, WorkDir, Output);
end;

end.
