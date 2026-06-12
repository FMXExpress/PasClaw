{ Status -- print effective config, home dir, key health checks. }
unit PasClaw.Cmd.Status;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Status_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config, PasClaw.Utils, PasClaw.CliUI,
  PasClaw.Shell.Backend;     { TShellBackendKind for the new
                               shell-backend status line }

function YesNo(b: Boolean): string;
begin
  if b then Result := Ansi.Green + 'yes' + Ansi.Reset
       else Result := Ansi.Red   + 'no'  + Ansi.Reset;
end;

function FormatShellBackend(const Cfg: TConfig): string;
begin
  case Cfg.ShellBackend of
    sbLocal:  Result := 'local';
    sbDocker: Result := Format('docker (image=%s, network=%s)',
                               [Cfg.ShellBackendDocker.Image,
                                Cfg.ShellBackendDocker.Network]);
  else
    Result := '(unknown)';
  end;
end;

function Cmd_Status_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  HomeOk, CfgOk: Boolean;
begin
  HomeOk := DirectoryExists(GetHome);
  CfgOk  := FileExists(GetConfigPath);
  Cfg    := LoadConfig;
  try
    PrintLn(Ansi.Bold + 'PasClaw status' + Ansi.Reset);
    PrintLn('  home directory : ' + GetHome + '   present: ' + YesNo(HomeOk));
    PrintLn('  config file    : ' + GetConfigPath + '   present: ' + YesNo(CfgOk));
    PrintLn('  default provider: ' + Cfg.DefaultProvider);
    PrintLn('  default model   : ' + Cfg.DefaultModel);
    PrintLn(Format('  providers       : %d', [Length(Cfg.Providers)]));
    PrintLn(Format('  mcp servers     : %d', [Length(Cfg.MCPServers)]));
    PrintLn(Format('  cron entries    : %d', [Length(Cfg.Crons)]));
    PrintLn(Format('  skills          : %d', [Length(Cfg.Skills)]));
    PrintLn(Format('  gateway bind    : %s:%d', [Cfg.Gateway.BindAddr, Cfg.Gateway.Port]));
    PrintLn('  log level       : ' + Cfg.Gateway.LogLevel);
    PrintLn('  shell backend   : ' + FormatShellBackend(Cfg));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
