{ Migrate -- migrate config from older PasClaw/PicoClaw layouts. Stub for Phase 1. }
unit PasClaw.Cmd.Migrate;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Migrate_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.Utils, PasClaw.CliUI;

function Cmd_Migrate_Run(const Argv: array of string): Integer;
var
  PicoPath, NewPath: string;
begin
  PicoPath := JoinPath(HomeDir, '.picoclaw/config.json');
  NewPath  := GetConfigPath;
  if FileExists(PicoPath) and not FileExists(NewPath) then
  begin
    WriteFileText(NewPath, ReadFileText(PicoPath));
    PrintLn('migrated ' + PicoPath + ' -> ' + NewPath);
    Exit(0);
  end;
  PrintLn('nothing to migrate (no ~/.picoclaw/config.json, or destination exists)');
  Result := 0;
end;

end.
