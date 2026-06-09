{ Cron -- list/add/disable/enable/remove scheduled tasks. Real scheduler in Phase 5. }
unit PasClaw.Cmd.Cron;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Cron_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, PasClaw.Config, PasClaw.CliUI;

procedure Help;
begin
  PrintLn('Usage: pasclaw cron <list|add|disable|enable|remove> [args]');
  PrintLn('  add <id> "<spec>" <skill> [args] [--channel <kind>:<target>]');
  PrintLn('                                     register a cron task');
  PrintLn('                                     channel kinds: discord, slack, teams,');
  PrintLn('                                                    webhook, line, whatsapp');
  PrintLn('  disable|enable <id>                toggle a task');
  PrintLn('  remove <id>                        delete a task');
end;

function DoList: Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.Crons) = 0 then
    begin
      PrintLn('(no cron entries)');
      Exit(0);
    end;
    PrintLn(Ansi.Bold + 'id' + Ansi.Reset + '              spec              skill         enabled');
    for i := 0 to High(Cfg.Crons) do
      PrintLn(Format('%14s  %14s  %12s  %s',
              [Cfg.Crons[i].Id,
               Cfg.Crons[i].Spec,
               Cfg.Crons[i].Skill,
               BoolToStr(Cfg.Crons[i].Enabled, True)]));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  n, i, ColonPos: Integer;
  Args, ChannelSpec, Kind, Target: string;
begin
  if Length(Argv) < 4 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Args := '';
    ChannelSpec := '';
    i := 4;
    while i <= High(Argv) do
    begin
      if (Argv[i] = '--channel') and (i < High(Argv)) then
      begin
        ChannelSpec := Argv[i + 1];
        Inc(i, 2);
        Continue;
      end;
      if Args <> '' then Args := Args + ' ';
      Args := Args + Argv[i];
      Inc(i);
    end;

    Kind   := '';
    Target := '';
    if ChannelSpec <> '' then
    begin
      ColonPos := Pos(':', ChannelSpec);
      if ColonPos <= 1 then
      begin
        PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
                '--channel must be <kind>:<target>');
        Exit(1);
      end;
      Kind   := Copy(ChannelSpec, 1, ColonPos - 1);
      Target := Copy(ChannelSpec, ColonPos + 1, MaxInt);
    end;

    n := Length(Cfg.Crons);
    SetLength(Cfg.Crons, n + 1);
    Cfg.Crons[n].Id            := Argv[1];
    Cfg.Crons[n].Spec          := Argv[2];
    Cfg.Crons[n].Skill         := Argv[3];
    Cfg.Crons[n].Args          := Args;
    Cfg.Crons[n].Enabled       := True;
    Cfg.Crons[n].ChannelKind   := Kind;
    Cfg.Crons[n].ChannelTarget := Target;
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'added cron ' + Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoToggle(const Argv: array of string; Enable: Boolean): Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.Crons) do
      if SameText(Cfg.Crons[i].Id, Argv[1]) then
        Cfg.Crons[i].Enabled := Enable;
    SaveConfig(Cfg);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    dst := 0;
    for i := 0 to High(Cfg.Crons) do
      if not SameText(Cfg.Crons[i].Id, Argv[1]) then
      begin
        Cfg.Crons[dst] := Cfg.Crons[i];
        Inc(dst);
      end;
    SetLength(Cfg.Crons, dst);
    SaveConfig(Cfg);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Cron_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'add'     then Result := DoAdd(Argv)
  else if Sub = 'disable' then Result := DoToggle(Argv, False)
  else if Sub = 'enable'  then Result := DoToggle(Argv, True)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else begin Help; Result := 1; end;
end;

end.
