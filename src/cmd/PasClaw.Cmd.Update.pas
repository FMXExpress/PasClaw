(*
  Update - self-update over GitHub releases.

    pasclaw update              # check + download + install
    pasclaw update --check      # only report what's available
    pasclaw update --repo o/r   # override the release repo
*)
unit PasClaw.Cmd.Update;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Update_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Updater;

procedure Help;
begin
  PrintLn('Usage: pasclaw update [--check] [--repo owner/name]');
end;

function SplitRepo(const Slug: string; out Owner, Repo: string): Boolean;
var
  p: Integer;
begin
  p := Pos('/', Slug);
  if p = 0 then Exit(False);
  Owner := Copy(Slug, 1, p - 1);
  Repo  := Copy(Slug, p + 1, MaxInt);
  Result := (Owner <> '') and (Repo <> '');
end;

function Cmd_Update_Run(const Argv: array of string): Integer;
var
  i: Integer;
  CheckOnly: Boolean;
  Owner, Repo, Err: string;
  Info: TReleaseInfo;
  Current, BinPath, NewPath: string;
  Cmp: Integer;
begin
  CheckOnly := False;
  Owner := 'FMXExpress';
  Repo  := 'PasClaw';
  i := 0;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--check' then begin CheckOnly := True; Inc(i); Continue; end;
    if Argv[i] = '--repo'  then
    begin
      if i = High(Argv) then begin Help; Exit(1); end;
      if not SplitRepo(Argv[i + 1], Owner, Repo) then
      begin
        PrintLnErr('invalid --repo "' + Argv[i + 1] + '" (expected owner/name)');
        Exit(1);
      end;
      Inc(i, 2);
      Continue;
    end;
    if (Argv[i] = '-h') or (Argv[i] = '--help') then begin Help; Exit(0); end;
    Inc(i);
  end;

  Current := FormatVersion;
  PrintLn(Ansi.Bold + 'PasClaw update' + Ansi.Reset);
  PrintLn('  current:  ' + Current);
  PrintLn('  repo:     ' + Owner + '/' + Repo);
  PrintLn('  platform: ' + HostPlatformSuffix);
  PrintLn('  fetching latest release...');

  if not FetchLatestRelease(Owner, Repo, Info, Err) then
  begin
    PrintLn(Ansi.Yellow + '  ' + Err + Ansi.Reset);
    if Pos('404', Err) > 0 then
      PrintLn('  (no releases published yet -- this is expected for a fresh repo)');
    Exit(0);
  end;

  PrintLn('  latest:   ' + Info.TagName + '  (' + Info.HtmlUrl + ')');
  Cmp := CompareVersions(Current, Info.TagName);
  if Cmp >= 0 then
  begin
    PrintLn(Ansi.Green + '  up to date.' + Ansi.Reset);
    Exit(0);
  end;
  PrintLn(Ansi.Bold + '  update available.' + Ansi.Reset);

  if Info.AssetUrl = '' then
  begin
    PrintLn(Ansi.Yellow + '  no asset for ' + HostPlatformSuffix +
            ' in this release -- see ' + Info.HtmlUrl + Ansi.Reset);
    Exit(0);
  end;
  PrintLn('  asset:    ' + Info.AssetName + '  (' + IntToStr(Info.AssetSize) + ' bytes)');

  if CheckOnly then Exit(0);

  BinPath := ParamStr(0);
  NewPath := BinPath + '.new';
  PrintLn('  downloading to ' + NewPath + '...');
  if not DownloadAsset(Info.AssetUrl, NewPath, Err) then
  begin
    PrintLn(Ansi.Red + '  download failed: ' + Err + Ansi.Reset);
    Exit(1);
  end;
  if not InstallUpdate(NewPath, BinPath, Err) then
  begin
    PrintLn(Ansi.Red + '  install failed: ' + Err + Ansi.Reset);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '  installed ' + Info.TagName + ' -- restart pasclaw.' + Ansi.Reset);
  Result := 0;
end;

end.
