(*
  PasClaw.Cmd.Backup -- `pasclaw backup` and `pasclaw restore`.

    pasclaw backup [--to DIR] [--keep-daily N] [--keep-weekly N] [--keep-monthly N]
        Zip the active workspace plus a redacted config.json and a
        RESTORE.md into DIR (default <home>/backups, or backup.dir in
        config.json), then rotate: keep the newest of each of the last
        7 days / 4 weeks / 6 months that have one, delete the rest of
        what this command wrote. Secrets never leave config.json.

    pasclaw backup list [--to DIR]
        What is there and when it was taken.

    pasclaw restore <zip> [--into HOME] [--force]
        Put a backup's workspace back under HOME (default PASCLAW_HOME).
        Refuses when that workspace already exists unless --force, which
        overlays it. Never writes config.json: it drops the redacted copy
        and the notes beside the workspace and prints the secrets you
        have to re-enter.

  The mechanics are PasClaw.Backup (tested); this unit is argument
  parsing and printing.
*)
unit PasClaw.Cmd.Backup;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Backup_Run(const Argv: array of string): Integer;
function Cmd_Restore_Run(const Argv: array of string): Integer;

{ The backup directory for a config: backup.dir, else <home>/backups. }
function ResolveBackupDir(const Home, ConfiguredDir: string): string;

implementation

uses
  SysUtils, Classes,
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Backup;

function ResolveBackupDir(const Home, ConfiguredDir: string): string;
begin
  Result := Trim(ConfiguredDir);
  if Result = '' then Result := JoinPath(Home, 'backups');
end;

procedure BackupHelp;
begin
  PrintLn('Usage: pasclaw backup [list] [--to DIR] [--keep-daily N] [--keep-weekly N] [--keep-monthly N]');
  PrintLn;
  PrintLn('  Zips the active workspace, a redacted config.json and a RESTORE.md into');
  PrintLn('  DIR (default: backup.dir in config.json, else $PASCLAW_HOME/backups), then');
  PrintLn('  rotates: the newest backup of each of the last N days / weeks / months that');
  PrintLn('  have one is kept, the rest of what this command wrote is deleted.');
  PrintLn('  Defaults 7 / 4 / 6. Secrets are never written to the archive.');
  PrintLn;
  PrintLn('  list        show the archives in DIR, newest first');
  PrintLn;
  PrintLn('Restore with: pasclaw restore <zip> [--into HOME] [--force]');
end;

procedure RestoreHelp;
begin
  PrintLn('Usage: pasclaw restore <zip> [--into HOME] [--force]');
  PrintLn;
  PrintLn('  Unpacks the backup''s workspace under HOME (default $PASCLAW_HOME).');
  PrintLn('  Refuses when that workspace already exists; --force overlays it (files');
  PrintLn('  not in the archive are kept). config.json is never written: the redacted');
  PrintLn('  copy and RESTORE.md are placed beside the workspace, and the secrets');
  PrintLn('  you have to re-enter are listed.');
end;

function IntArg(const Argv: array of string; var i: Integer; Default: Integer): Integer;
begin
  Result := Default;
  if i < High(Argv) then
  begin
    Inc(i);
    Result := StrToIntDef(Argv[i], Default);
  end;
end;

function DoList(const Dir: string): Integer;
var
  SR: TSearchRec;
  L: TStringList;
  i: Integer;
  When: TDateTime;
begin
  L := TStringList.Create;
  try
    if FindFirst(IncludeTrailingPathDelimiter(Dir) + BackupPrefix + '*' + BackupExt, faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Attr and faDirectory) = 0 then L.Add(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    if L.Count = 0 then
    begin
      PrintLn('(no backups in ' + Dir + ')');
      Exit(0);
    end;
    L.Sort;
    PrintLn(Ansi.Bold + 'backups in ' + Dir + Ansi.Reset);
    for i := L.Count - 1 downto 0 do
      if ParseBackupStamp(L[i], When) then
        PrintLn(Format('  %s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss', When), L[i]]))
      else
        PrintLn('  (unrecognised)       ' + L[i]);
    Result := 0;
  finally
    L.Free;
  end;
end;

function Cmd_Backup_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, KD, KW, KM: Integer;
  Dir, Err: string;
  ListOnly: Boolean;
  Res: TBackupResult;
begin
  for i := 0 to High(Argv) do
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      BackupHelp;
      Exit(0);
    end;

  Cfg := LoadConfig;
  try
    KD := Cfg.Backup.KeepDaily;
    KW := Cfg.Backup.KeepWeekly;
    KM := Cfg.Backup.KeepMonthly;
    Dir := ResolveBackupDir(GetHome, Cfg.Backup.Dir);
    ListOnly := False;
    i := 0;
    while i <= High(Argv) do
    begin
      if Argv[i] = 'list' then ListOnly := True
      else if (Argv[i] = '--to') and (i < High(Argv)) then begin Inc(i); Dir := Argv[i]; end
      else if Argv[i] = '--keep-daily' then KD := IntArg(Argv, i, KD)
      else if Argv[i] = '--keep-weekly' then KW := IntArg(Argv, i, KW)
      else if Argv[i] = '--keep-monthly' then KM := IntArg(Argv, i, KM)
      else
      begin
        PrintErr(FormatCLIError('unknown argument: ' + Argv[i], 'pasclaw backup'));
        Exit(1);
      end;
      Inc(i);
    end;

    if ListOnly then Exit(DoList(Dir));

    if not RunBackup(GetHome, ActiveWorkspaceName, Dir, FormatBuildInfo, KD, KW, KM, Res, Err) then
    begin
      PrintErr(Ansi.Red + '✗ ' + Ansi.Reset + 'backup failed: ' + Err);
      Exit(1);
    end;
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + Format('backed up %d files -> %s', [Res.Files, Res.ZipPath]));
    if Length(Res.Redacted) > 0 then
    begin
      PrintLn('  secrets left out (re-enter after a restore):');
      for i := 0 to High(Res.Redacted) do PrintLn('    - ' + Res.Redacted[i]);
    end;
    if Length(Res.Pruned) > 0 then
      PrintLn(Format('  rotation removed %d older archive(s) (keep %d daily / %d weekly / %d monthly)',
                     [Length(Res.Pruned), KD, KW, KM]));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Restore_Run(const Argv: array of string): Integer;
var
  i: Integer;
  Zip, Home, Err: string;
  Force: Boolean;
  Res: TRestoreResult;
begin
  Zip := '';
  Home := GetHome;
  Force := False;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-h') or (Argv[i] = '--help') then begin RestoreHelp; Exit(0); end
    else if (Argv[i] = '--into') and (i < High(Argv)) then begin Inc(i); Home := Argv[i]; end
    else if Argv[i] = '--force' then Force := True
    else if (Zip = '') and (Argv[i] <> '') and (Argv[i][1] <> '-') then Zip := Argv[i]
    else
    begin
      PrintErr(FormatCLIError('unknown argument: ' + Argv[i], 'pasclaw restore'));
      Exit(1);
    end;
    Inc(i);
  end;
  if Zip = '' then
  begin
    RestoreHelp;
    Exit(1);
  end;

  if not RunRestore(Zip, Home, Force, Res, Err) then
  begin
    PrintErr(Ansi.Red + '✗ ' + Ansi.Reset + 'restore failed: ' + Err);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
          Format('restored %d files into %s', [Res.Files, JoinPath(Home, Res.Workspace)]));
  PrintLn('  config.json was not written. ' + RedactedConfigName + ' and RESTORE-' +
          Res.Workspace + '.md are beside the workspace.');
  if Length(Res.Redacted) > 0 then
  begin
    PrintLn('  re-enter these secrets (pasclaw onboard, or edit config.json):');
    for i := 0 to High(Res.Redacted) do PrintLn('    - ' + Res.Redacted[i]);
  end;
  PrintLn('  then: pasclaw doctor');
  Result := 0;
end;

end.
