{ Config -- view/edit raw config. }
unit PasClaw.Cmd.Config_;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Config_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.Utils, PasClaw.CliUI;

function Cmd_Config_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
begin
  if (Length(Argv) > 0) and (Argv[0] = 'path') then
  begin
    PrintLn(GetConfigPath);
    Exit(0);
  end;
  if (Length(Argv) > 0) and (Argv[0] = 'reset') then
  begin
    Cfg := TConfig.Create;
    try
      SaveConfig(Cfg);
      PrintLn('wrote default config to ' + GetConfigPath);
    finally
      Cfg.Free;
    end;
    Exit(0);
  end;
  Cfg := LoadConfig;
  try
    PrintLn(Cfg.ToJSON);
  finally
    Cfg.Free;
  end;
  Result := 0;
end;

end.
