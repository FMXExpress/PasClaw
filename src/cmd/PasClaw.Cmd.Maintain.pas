(*
  PasClaw.Cmd.Maintain -- `pasclaw maintain`, the nightly pass by hand.

    pasclaw maintain [--since N] [--review | --no-review] [--backup | --no-backup] [--dry-run] [--quiet]

  Sweeps expired and aged-superseded facts, sizes the always-loaded memory
  files against their budget, walks the last N days of sessions (turns,
  tool calls, failures, tokens), audits skills for ones nothing calls and
  pairs that are the same skill twice, optionally asks the background
  model for a short critique, optionally runs a backup, and writes the
  report to <workspace>/memory/maintenance/<date>.md.

  Defaults come from config.json's "maintenance" block; the flags override
  for one run. Schedule it nightly with the reserved cron skill:

    pasclaw cron add nightly "0 3 * * *" @maintain

  which the gateway's scheduler runs in-process (PasClaw.Maintain).
*)
unit PasClaw.Cmd.Maintain;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Maintain_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  PasClaw.Maintain;

procedure Help;
begin
  PrintLn('Usage: pasclaw maintain [--since N] [--review|--no-review] [--backup|--no-backup] [--dry-run] [--quiet]');
  PrintLn;
  PrintLn('  The nightly pass: sweep expired facts, size the always-loaded memory files,');
  PrintLn('  summarise the last N days of sessions (default 1), audit skills, optionally');
  PrintLn('  ask the background model for a critique, optionally back up, and write');
  PrintLn('  <workspace>/memory/maintenance/<date>.md.');
  PrintLn;
  PrintLn('  --since N     session window in days (default 1)');
  PrintLn('  --review      ask the model for a short critique (one call on background_model)');
  PrintLn('  --backup      run `pasclaw backup` at the end');
  PrintLn('  --dry-run     report only: delete nothing, back up nothing, call no model');
  PrintLn('  --quiet       print only the report path');
  PrintLn;
  PrintLn('Schedule it: pasclaw cron add nightly "0 3 * * *" ' + MaintenanceCronSkill);
end;

function Cmd_Maintain_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  O: TMaintainOptions;
  R: TMaintainReport;
  i: Integer;
  Err: string;
  Quiet: Boolean;
  Prov: ILLMProvider;
begin
  Cfg := LoadConfig;
  try
    O := DefaultMaintainOptions(Cfg);
    Quiet := False;
    i := 0;
    while i <= High(Argv) do
    begin
      if (Argv[i] = '-h') or (Argv[i] = '--help') then begin Help; Exit(0); end
      else if (Argv[i] = '--since') and (i < High(Argv)) then
      begin
        Inc(i);
        O.SinceDays := StrToIntDef(Argv[i], O.SinceDays);
        if O.SinceDays < 1 then O.SinceDays := 1;
      end
      else if Argv[i] = '--review' then O.Review := True
      else if Argv[i] = '--no-review' then O.Review := False
      else if Argv[i] = '--backup' then O.DoBackup := True
      else if Argv[i] = '--no-backup' then O.DoBackup := False
      else if Argv[i] = '--dry-run' then O.DryRun := True
      else if (Argv[i] = '--quiet') or (Argv[i] = '-q') then Quiet := True
      else
      begin
        PrintErr(FormatCLIError('unknown argument: ' + Argv[i], 'pasclaw maintain'));
        Exit(1);
      end;
      Inc(i);
    end;

    if O.Review and not O.DryRun then
    begin
      if Cfg.DefaultProvider = '' then
      begin
        PrintErr(Ansi.Yellow + '!' + Ansi.Reset + ' --review needs a default_provider; skipping the review');
        O.Review := False;
      end
      else if not NewProviderFromConfig(Cfg, Cfg.DefaultProvider, Prov, Err) then
      begin
        PrintErr(Ansi.Yellow + '!' + Ansi.Reset + ' --review: ' + Err + '; skipping the review');
        O.Review := False;
      end
      else
        O.Provider := Prov;
    end;

    if not RunMaintenance(O, R, Err) then
    begin
      PrintErr(Ansi.Red + '✗ ' + Ansi.Reset + 'maintain: ' + Err);
      Exit(1);
    end;

    if Quiet then
    begin
      if R.ReportPath <> '' then PrintLn(R.ReportPath);
    end
    else
    begin
      Print(RenderMaintenanceReport(O, R));
      if R.ReportPath <> '' then
        PrintLn(Ansi.Dim + 'written to ' + R.ReportPath + Ansi.Reset);
    end;
    if Length(R.Warnings) > 0 then Result := 2 else Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
