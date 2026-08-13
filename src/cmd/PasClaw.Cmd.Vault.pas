(*
  PasClaw.Cmd.Vault -- `pasclaw vault <search|show|install>`.

    pasclaw vault search <query> [--limit N]
        Search the pasclaw.dev Code Vault. Prints a table of
        matching entries (slug + version + name + summary).

    pasclaw vault show <slug>
        Print full entry detail -- description, repo URL, license,
        Delphi versions, install snippet.

    pasclaw vault install <slug> [<dest-path>]
        git clone the entry's repoUrl into <dest-path> (or
        $PASCLAW_HOME/workspace/vault/<slug> if not given).
        Refuses if the destination already exists.

  Vault entries are GitHub repos -- there's no zip / download step
  the way Skills + ClawHub have. The install path shells out to
  `git clone` and inherits whatever git auth the user already has.
*)
unit PasClaw.Cmd.Vault;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Vault_Run(const Argv: array of string): Integer;

implementation

uses
  PasClaw.Workspaces,
  SysUtils, Classes,
  PasClaw.Platform,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Vault.Client;

procedure Help;
begin
  PrintLn('Usage: pasclaw vault <search|show|install> [args]');
  PrintLn;
  PrintLn('  search <query> [--limit N]   Search pasclaw.dev Code Vault.');
  PrintLn('  show <slug>                  Print full entry detail.');
  PrintLn('  install <slug> [<dest>]      git clone the repo into <dest>');
  PrintLn('                               (default $PASCLAW_HOME/workspace/vault/<slug>).');
end;

function DoSearch(const Argv: array of string): Integer;
var
  Query: string;
  Limit, i: Integer;
  Results: TVaultResultArray;
  ErrMsg, Summary: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Query := Argv[1];
  Limit := 25;
  if Length(Argv) >= 4 then
    if Argv[2] = '--limit' then
      Limit := StrToIntDef(Argv[3], 25);

  PrintLn('Searching pasclaw.dev Code Vault: ' + Query + ' …');
  if not SearchVault(Query, Limit, Results, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'search failed: ' + ErrMsg);
    Exit(1);
  end;
  if Length(Results) = 0 then
  begin
    PrintLn('(no matches)');
    Exit(0);
  end;
  PrintLn(Ansi.Bold + 'slug' + Ansi.Reset + '                       version    name');
  for i := 0 to High(Results) do
  begin
    PrintLn(Format('%26s  %9s  %s', [Results[i].Slug, Results[i].Version, Results[i].DisplayName]));
    Summary := Trim(Results[i].Summary);
    if Summary <> '' then
      PrintLn('                            ' + Ansi.Dim + Summary + Ansi.Reset);
  end;
  PrintLn;
  PrintLn(Ansi.Dim + 'Show with:    ' + Ansi.Reset +
          Ansi.Bold + 'pasclaw vault show <slug>' + Ansi.Reset);
  PrintLn(Ansi.Dim + 'Install with: ' + Ansi.Reset +
          Ansi.Bold + 'pasclaw vault install <slug>' + Ansi.Reset +
          Ansi.Dim + '  (git clone into workspace/vault/<slug>)' + Ansi.Reset);
  Result := 0;
end;

function DoShow(const Argv: array of string): Integer;
var
  Slug, ErrMsg: string;
  Detail: TVaultDetail;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Slug := Argv[1];
  if not GetVaultEntry(Slug, Detail, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'get failed: ' + ErrMsg);
    Exit(1);
  end;
  if Detail.Blocked then
    PrintLn(Ansi.Red + '⚠ malware-flagged' + Ansi.Reset)
  else if Detail.Suspicious then
    PrintLn(Ansi.Yellow + '⚠ flagged as suspicious' + Ansi.Reset);
  PrintLn(Ansi.Bold + 'slug:        ' + Ansi.Reset + Detail.Slug);
  PrintLn(Ansi.Bold + 'name:        ' + Ansi.Reset + Detail.DisplayName);
  if Detail.Summary <> '' then
    PrintLn(Ansi.Bold + 'summary:     ' + Ansi.Reset + Detail.Summary);
  if Detail.RepoURL <> '' then
    PrintLn(Ansi.Bold + 'repo:        ' + Ansi.Reset + Detail.RepoURL);
  if Detail.HomepageURL <> '' then
    PrintLn(Ansi.Bold + 'homepage:    ' + Ansi.Reset + Detail.HomepageURL);
  if Detail.License <> '' then
    PrintLn(Ansi.Bold + 'license:     ' + Ansi.Reset + Detail.License);
  if Detail.LatestVersion <> '' then
    PrintLn(Ansi.Bold + 'version:     ' + Ansi.Reset + Detail.LatestVersion);
  if Detail.Category <> '' then
    PrintLn(Ansi.Bold + 'category:    ' + Ansi.Reset + Detail.Category);
  if Detail.Tags <> '' then
    PrintLn(Ansi.Bold + 'tags:        ' + Ansi.Reset + Detail.Tags);
  if Detail.DelphiVersions <> '' then
    PrintLn(Ansi.Bold + 'delphi:      ' + Ansi.Reset + Detail.DelphiVersions);
  if Detail.PackageManager <> '' then
    PrintLn(Ansi.Bold + 'package mgr: ' + Ansi.Reset + Detail.PackageManager);
  if Detail.ViewCount > 0 then
    PrintLn(Ansi.Bold + 'views:       ' + Ansi.Reset + IntToStr(Detail.ViewCount));
  if Detail.InstallSnippet <> '' then
  begin
    PrintLn;
    PrintLn(Ansi.Bold + 'install snippet:' + Ansi.Reset);
    PrintLn(Detail.InstallSnippet);
  end;
  if Detail.DescriptionMarkdown <> '' then
  begin
    PrintLn;
    PrintLn(Ansi.Bold + 'description:' + Ansi.Reset);
    PrintLn(Detail.DescriptionMarkdown);
  end;
  Result := 0;
end;

function RunGitClone(const RepoURL, DestDir: string; out ErrMsg: string): Boolean;
{ Shells out to `git clone <repoUrl> <destDir>` via PasClaw.Platform's
  TStdioProcess (fcl-process on FPC; CreateProcess / fork+execvp on
  Delphi) so both compilers can drain output the same way. Inherits
  whatever git auth the user already has (SSH keys, credential
  helper, etc.) -- we don't handle private-repo auth ourselves.
  Output is streamed to stdout so the user sees clone progress in
  real time. }
var
  P: TStdioProcess;
  Args: TStringList;
  Buf: array[0..4095] of Byte;
  Bytes: TBytes;
  N: Integer;
begin
  Result := False;
  ErrMsg := '';
  P    := TStdioProcess.Create;
  Args := TStringList.Create;
  try
    Args.Add('clone');
    Args.Add('--');
    Args.Add(RepoURL);
    Args.Add(DestDir);
    { git writes progress and most fatal messages to stderr -- merge it
      into stdout so users see clone progress and so a chatty failure
      can't block the child on a full stderr pipe. }
    if not P.Spawn('git', Args, {MergeStderr=}True) then
    begin
      ErrMsg := 'git clone failed to start (is `git` installed and on PATH?)';
      Exit;
    end;
    repeat
      N := P.ReadAvailable(Buf, SizeOf(Buf));
      if N > 0 then
      begin
        SetLength(Bytes, N);
        Move(Buf[0], Bytes[0], N);
        Print(TEncoding.UTF8.GetString(Bytes));
      end;
    until (N = 0) and (not P.Running);
    { latch ExitCode via the side-effect on Running }
    P.Running;
    if P.ExitCode <> 0 then
    begin
      ErrMsg := Format('git clone exited %d', [P.ExitCode]);
      Exit;
    end;
    Result := True;
  finally
    Args.Free;
    P.Free;
  end;
end;

function DoInstall(const Argv: array of string): Integer;
var
  Slug, DestDir, ParentDir, ErrMsg: string;
  Detail: TVaultDetail;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Slug := Argv[1];

  if Length(Argv) >= 3 then
    DestDir := Argv[2]
  else
    DestDir := JoinPath(GetHome, ActiveWorkspaceName + '/vault/');

  if DirectoryExists(DestDir) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
            'destination already exists: ' + DestDir);
    PrintLn(Ansi.Dim + '  remove it first, or pass a different <dest> path.' + Ansi.Reset);
    Exit(1);
  end;

  if not GetVaultEntry(Slug, Detail, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'vault lookup failed: ' + ErrMsg);
    Exit(1);
  end;
  if Detail.Blocked then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
            'pasclaw.dev flagged "' + Slug + '" as malware -- refusing install');
    Exit(1);
  end;
  if Detail.Suspicious then
    PrintLn(Ansi.Yellow + '! ' + Ansi.Reset +
            'pasclaw.dev flagged "' + Slug + '" as suspicious -- proceeding anyway');
  if Detail.RepoURL = '' then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
            'vault entry has no repoUrl');
    Exit(1);
  end;

  ParentDir := ExtractFileDir(DestDir);
  if ParentDir <> '' then
    ForceDirectories(ParentDir);
  PrintLn('Cloning ' + Detail.RepoURL + ' …');
  if not RunGitClone(Detail.RepoURL, DestDir, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + ErrMsg);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'cloned into ' + DestDir);
  if Detail.InstallSnippet <> '' then
  begin
    PrintLn(Ansi.Dim + 'Install snippet from vault:' + Ansi.Reset);
    PrintLn(Detail.InstallSnippet);
  end;
  Result := 0;
end;

function Cmd_Vault_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'search'  then Result := DoSearch(Argv)
  else if Sub = 'show'    then Result := DoShow(Argv)
  else if Sub = 'install' then Result := DoInstall(Argv)
  else                         begin Help; Result := 1; end;
end;

end.
