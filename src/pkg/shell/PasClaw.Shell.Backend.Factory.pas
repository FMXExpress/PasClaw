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
  Err: string;
begin
  if CLIOverride <> '' then
    KindSelected := ParseKind(CLIOverride, Cfg.ShellBackend)
  else
    KindSelected := Cfg.ShellBackend;

  case KindSelected of
    sbDocker:
      begin
        if not DockerCliReachable(Err) then
          raise Exception.Create(
            'shell_backend=docker selected but ' + Err + sLineBreak +
            '  Start Docker, set shell_backend=local in config.json,' +
            sLineBreak +
            '  or pass --backend local on this command.');
        Opts := DefaultDockerBackendOptions;
        if Cfg.ShellBackendDocker.Image   <> '' then Opts.Image   := Cfg.ShellBackendDocker.Image;
        if Cfg.ShellBackendDocker.Network <> '' then Opts.Network := Cfg.ShellBackendDocker.Network;
        Opts.User       := Cfg.ShellBackendDocker.User;
        Opts.Privileged := Cfg.ShellBackendDocker.Privileged;
        Backend := TDockerShellBackend.Create(Opts);
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
