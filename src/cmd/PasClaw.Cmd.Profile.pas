(*
  pasclaw profile - configuration profile management (PR #291).

  Three subcommands shipping in this PR:

    pasclaw profile list           List built-in + user profiles
    pasclaw profile show <name>    Print the profile's effective JSON
                                   (after _inherits resolution)
    pasclaw profile use <name>     Write "profile": "<name>" into
                                   config.json so it sticks across runs

  Future (Stage D, separate PR):

    pasclaw profile diff <a> <b>   Show field-level differences
    pasclaw profile bench ...      A/B test profiles against a task

  Profile selection precedence at LoadConfig time:

    1. --profile <name>   (CLI per-invocation)
    2. PASCLAW_PROFILE    (env var, process scope)
    3. "profile": "<name>" in config.json   (persisted; `profile use` writes this)
    4. None
*)
unit PasClaw.Cmd.Profile;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Profile_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Config.Profile,
  PasClaw.JSON,
  PasClaw.Utils;

procedure Help;
begin
  PrintLn('Usage: pasclaw profile <list|show|use> [args]');
  PrintLn;
  PrintLn('  list                List built-in + $PASCLAW_HOME/profiles/ profiles.');
  PrintLn('  show <name>         Print the profile body (with _inherits resolved).');
  PrintLn('  use  <name>         Save "profile": <name> into config.json.');
  PrintLn;
  PrintLn('Built-in profiles: baseline | low-token | security | max-build | all-on');
  PrintLn('Per-invocation override: ' + Ansi.Bold + 'pasclaw <cmd> --profile <name>' + Ansi.Reset);
  PrintLn('Process override:        ' + Ansi.Bold + 'PASCLAW_PROFILE=<name> pasclaw ...' + Ansi.Reset);
end;

function DoList: Integer;
var
  Profiles: TProfileSpecArray;
  i: Integer;
  Src, Active: string;
begin
  Profiles := ListAvailableProfiles(GetHome);
  if Length(Profiles) = 0 then
  begin
    PrintLn('(no profiles)');
    Exit(0);
  end;

  Active := GetEnvironmentVariable('PASCLAW_PROFILE');
  if Active = '' then
  try
    Active := ExtractProfileField(ReadFileText(GetConfigPath));
  except
    Active := '';
  end;

  PrintLn(Ansi.Bold + 'name           source         description' + Ansi.Reset);
  for i := 0 to High(Profiles) do
  begin
    Src := Profiles[i].Source;
    if Src <> 'builtin' then
    begin
      { Show ~/.../ relative path so the line stays readable. }
      if Pos(GetHome, Src) = 1 then
        Src := '~' + Copy(Src, Length(GetHome) + 1, MaxInt);
    end;
    if SameText(Profiles[i].Name, Active) then
      PrintLn(Format('* %-12s  %-12s  %s',
        [Profiles[i].Name, Src, Profiles[i].Description]))
    else
      PrintLn(Format('  %-12s  %-12s  %s',
        [Profiles[i].Name, Src, Profiles[i].Description]));
  end;
  if Active <> '' then
    PrintLn(Ansi.Dim + sLineBreak + '(* marks the active profile from ' +
            'PASCLAW_PROFILE or config.json)' + Ansi.Reset);
  Result := 0;
end;

function DoShow(const Argv: array of string): Integer;
var
  Bodies: TProfileBodyArray;
  Err: string;
  i: Integer;
  Sb: TStringBuilder;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if not ResolveProfileBodies(GetHome, Argv[1], Bodies, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Exit(1);
  end;
  PrintLn(Ansi.Bold + 'profile ' + Argv[1] +
          Ansi.Reset + Ansi.Dim +
          Format('  (%d layer(s) including ancestors)', [Length(Bodies)]) +
          Ansi.Reset);
  PrintLn;
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Bodies) do
    begin
      if Length(Bodies) > 1 then
      begin
        PrintLn(Ansi.Dim + Format('--- layer %d/%d ---', [i + 1, Length(Bodies)]) +
                Ansi.Reset);
      end;
      PrintLn(Bodies[i]);
      if i < High(Bodies) then PrintLn;
    end;
  finally
    Sb.Free;
  end;
  Result := 0;
end;

function DoUse(const Argv: array of string): Integer;
var
  Err: string;
  Bodies: TProfileBodyArray;
  Cfg: TConfig;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  { Validate the profile resolves BEFORE writing -- prevents stamping
    a typo into config.json that LoadConfig will then warn about
    forever. }
  if not ResolveProfileBodies(GetHome, Argv[1], Bodies, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Exit(1);
  end;

  { PR #291 Codex fix: write through TConfig + SaveConfig, not by
    hand-rolling JSON. Cfg.Profile is a proper field now, so any
    config-mutating command after this (auth login, model set, /v1/config
    PUT, ...) preserves it instead of dropping the key on the next save. }
  Cfg := LoadConfig('');
  try
    Cfg.Profile := Argv[1];
    SaveConfig(Cfg);
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
          'config.json now selects profile "' + Argv[1] + '"');
  PrintLn(Ansi.Dim +
          '  Override per-invocation: pasclaw <cmd> --profile <other>' +
          Ansi.Reset);
  Result := 0;
end;

function Cmd_Profile_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list' then Result := DoList
  else if Sub = 'show' then Result := DoShow(Argv)
  else if Sub = 'use'  then Result := DoUse(Argv)
  else begin Help; Result := 1; end;
end;

end.
