{ Skills -- list / install / remove / search skill extensions.

  install accepts three target shapes (in this dispatch order):

    pasclaw skills install owner/repo[/sub/path][@ref]
        Fetch a SKILL.md tree from GitHub (zip via codeload, extract
        with PasClaw.Skills.Zip). Default ref tries main then master.

    pasclaw skills install clawhub:<slug>[@<version>]
        Resolve <slug> on ClawHub (https://clawhub.ai). Picoclaw and
        nanobot's default registry -- slug syntax is lowercase
        alphanumerics, '-', and '_'. `@<version>` pins; omitting it
        uses the slug's latestVersion if metadata is available,
        otherwise 'latest'. The explicit `clawhub:` prefix is
        required so a slug-shaped bare name like `my-skill` does
        not silently swap places with a same-named registry entry
        -- see the docstring on IsClawHubTarget for the backwards
        compat rationale.

    pasclaw skills search <query>
        Hit ClawHub's /api/v1/search and print result rows. No
        install side effects.

  Legacy `pasclaw skills install <name>` (anything not matching the
  two forms above) still records the name in config.json without
  downloading anything. Kept for backwards compat with older
  workflows that drove Cfg.Skills directly. }
unit PasClaw.Cmd.Skills;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Skills_Run(const Argv: array of string): Integer;

implementation

uses
  PasClaw.Workspaces,
  SysUtils, Classes, PasClaw.Config, PasClaw.CliUI, PasClaw.Utils, PasClaw.Logger,
  PasClaw.Skills.Loader,
  PasClaw.Skills.GitHub,
  PasClaw.Skills.Provenance,
  PasClaw.Skills.ClawHub,
  PasClaw.Skills.PasClawHub,
  PasClaw.Skills.Pending;

procedure Help;
begin
  PrintLn('Usage: pasclaw skills <list|install|remove|search> [args]');
  PrintLn;
  PrintLn('  list                                List installed skills.');
  PrintLn('  install owner/repo[/path][@ref]     Install a SKILL.md from GitHub.');
  PrintLn('  install hub:<slug>[@<version>]      Install from pasclaw.dev (forced).');
  PrintLn('  install clawhub:<slug>[@<version>]  Install from ClawHub (https://clawhub.ai).');
  PrintLn('  install <slug>                      Try pasclaw.dev first, then ClawHub.');
  PrintLn('  remove <name>                       Remove from config.json + workspace.');
  PrintLn('  verify                              Re-hash installed skills against their install-time record.');
  PrintLn('  search <query>                      Search pasclaw.dev + ClawHub for skills.');
  PrintLn('  pending                             List agent-authored skills awaiting approval.');
  PrintLn('  diff <id>                           Show a pending skill''s proposed SKILL.md.');
  PrintLn('  approve <id>                        Commit a pending skill (effective next run).');
  PrintLn('  reject <id>                         Discard a pending skill.');
end;

function IsGitHubTarget(const Target: string): Boolean;
{ Cheapest sniff: a slash that is not at position 1 (so not a local
  absolute path starting with /), no leading dot (so not ./relative
  or ../relative), and not starting with a Windows drive letter.
  Anything else falls through to the ClawHub / legacy paths. }
var
  i: Integer;
begin
  Result := False;
  if Target = '' then Exit;
  if (Target[1] = '/') or (Target[1] = '\') or (Target[1] = '.') then Exit;
  if (Length(Target) >= 2) and (Target[2] = ':') then Exit; { drive letter }
  for i := 1 to Length(Target) do
    if Target[i] = '/' then Exit(True);
end;

const
  ClawHubPrefix = 'clawhub:';

function IsClawHubTarget(const Target: string; out Slug: string): Boolean;
{ ClawHub installs require an explicit `clawhub:<slug>[@version]`
  prefix. Bare slug-shaped names ('my-skill', 'code-review' etc.)
  stay on the legacy config-only path so pre-existing scripts that
  used `pasclaw skills install <name>` to record an entry in
  config.json keep working -- they'd otherwise either 404 on
  ClawHub or, worse, silently install an unrelated registry skill
  that happened to share the slug.

  Validates the slug after stripping the prefix so e.g.
  `clawhub:Foo` (mixed case) fails fast here rather than 404'ing
  on the server. Optional `@<version>` suffix permitted. }
var
  i, AtPos: Integer;
  Rest: string;
  C: Char;
begin
  Result := False;
  Slug := '';
  if Length(Target) <= Length(ClawHubPrefix) then Exit;
  if Copy(Target, 1, Length(ClawHubPrefix)) <> ClawHubPrefix then Exit;
  Rest := Copy(Target, Length(ClawHubPrefix) + 1, MaxInt);
  if (Rest = '') or (Length(Rest) > 128) then Exit;
  AtPos := Pos('@', Rest);
  if AtPos > 0 then Slug := Copy(Rest, 1, AtPos - 1)
              else Slug := Rest;
  if Slug = '' then Exit;
  for i := 1 to Length(Slug) do
  begin
    C := Slug[i];
    if not ( ((C >= 'a') and (C <= 'z')) or
             ((C >= '0') and (C <= '9')) or
             (C = '-') or (C = '_') ) then Exit;
  end;
  Slug := Rest;   { hand the full "<slug>[@version]" back to caller }
  Result := True;
end;

const
  HubPrefix = 'hub:';

function IsPasClawHubTarget(const Target: string; out Slug: string): Boolean;
{ Parallel to IsClawHubTarget -- `hub:<slug>[@version]` forces routing
  through the pasclaw.dev hub. Same slug constraints (lowercase
  alphanumeric + dash + underscore, ≤128 chars). Used to bypass the
  bare-slug hub-then-clawhub fallback when the caller explicitly
  wants pasclaw.dev only. }
var
  i, AtPos: Integer;
  Rest: string;
  C: Char;
begin
  Result := False;
  Slug := '';
  if Length(Target) <= Length(HubPrefix) then Exit;
  if Copy(Target, 1, Length(HubPrefix)) <> HubPrefix then Exit;
  Rest := Copy(Target, Length(HubPrefix) + 1, MaxInt);
  if (Rest = '') or (Length(Rest) > 128) then Exit;
  AtPos := Pos('@', Rest);
  if AtPos > 0 then Slug := Copy(Rest, 1, AtPos - 1)
              else Slug := Rest;
  if Slug = '' then Exit;
  for i := 1 to Length(Slug) do
  begin
    C := Slug[i];
    if not ( ((C >= 'a') and (C <= 'z')) or
             ((C >= '0') and (C <= '9')) or
             (C = '-') or (C = '_') ) then Exit;
  end;
  Slug := Rest;   { hand "<slug>[@version]" back to caller }
  Result := True;
end;

function IsBareSlug(const Target: string): Boolean;
{ A target with no slash, no leading dot, no drive letter, and no
  ':' prefix is a candidate for the bare-slug install path
  (pasclaw.dev → ClawHub → legacy fallback). Slug character set is
  enforced by the hub clients themselves; this is just the
  "looks-like-a-slug" sniff. }
var
  i: Integer;
begin
  Result := False;
  if Target = '' then Exit;
  if (Target[1] = '/') or (Target[1] = '\') or (Target[1] = '.') then Exit;
  if (Length(Target) >= 2) and (Target[2] = ':') then Exit;
  for i := 1 to Length(Target) do
    if (Target[i] = '/') or (Target[i] = ':') then Exit;
  Result := True;
end;

procedure SplitSlugAtVersion(const Target: string; out Slug, Version: string);
var
  AtPos: Integer;
begin
  AtPos := Pos('@', Target);
  if AtPos > 0 then
  begin
    Slug    := Copy(Target, 1, AtPos - 1);
    Version := Copy(Target, AtPos + 1, MaxInt);
  end
  else
  begin
    Slug    := Target;
    Version := '';
  end;
end;

function DoVerify: Integer;
(* Re-hash every installed skill against the record written at install
   time. The exit code is the point: 0 when nothing changed, 1 when
   something did, so this can gate a deploy or run from cron.

   Skills with no record report "unknown" and do NOT fail the run --
   anything installed before provenance existed, or by hand, is not
   evidence of tampering. Per the verification-scope finding in
   docs/agent-features.md, the summary states how many skills were NOT
   checked rather than letting them pass silently as clean. *)
var
  Root, Dir: string;
  SR: TSearchRec;
  R: TSkillVerifyResult;
  i, Bad, Unknown, Good: Integer;
begin
  Root := JoinPath(JoinPath(GetHome, ActiveWorkspaceName), 'skills');
  if not DirectoryExists(Root) then
  begin
    PrintLn('(no skills directory at ' + Root + ')');
    Exit(0);
  end;
  Bad := 0; Unknown := 0; Good := 0;
  if FindFirst(JoinPath(Root, '*'), faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) = 0 then Continue;
      Dir := JoinPath(Root, SR.Name);
      R := VerifySkill(Dir);
      case R.Status of
        svOK:
          begin
            Inc(Good);
            PrintLn(Format('  %s%-24s%s ok        %d file(s) verified',
                           [Ansi.Green, SR.Name, Ansi.Reset, R.Checked]));
          end;
        svNoRecord:
          begin
            Inc(Unknown);
            PrintLn(Format('  %s%-24s%s unknown   no provenance record -- not checked',
                           [Ansi.Dim, SR.Name, Ansi.Reset]));
          end;
      else
        begin
          Inc(Bad);
          PrintLn(Format('  %s%-24s%s %s',
                         [Ansi.Yellow, SR.Name, Ansi.Reset,
                          VerifyStatusText(R.Status)]));
          for i := 0 to High(R.Findings) do
            PrintLn('      ' + R.Findings[i]);
        end;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;

  PrintLn;
  PrintLn(Format('  %d verified, %d unknown, %d changed', [Good, Unknown, Bad]));
  if Unknown > 0 then
    PrintLn(Ansi.Dim +
      '  "unknown" means this command did not check that skill, not that it is clean.' +
      Ansi.Reset);
  if Bad > 0 then Result := 1 else Result := 0;
end;

function DoList: Integer;
var
  Specs: TSkillSpecArray;
  i: Integer;
  K, Src: string;
begin
  Specs := LoadSkillManifests(GetHome);
  if Length(Specs) = 0 then
  begin
    PrintLn('(no skills found at ' + JoinPath(GetHome, ActiveWorkspaceName + '/skills') + ')');
    PrintLn('Add one: mkdir -p ~/.pasclaw/workspace/skills/<name>; place a SKILL.md inside.');
    Exit(0);
  end;
  PrintLn(Ansi.Bold + 'name' + Ansi.Reset + '              kind        source');
  for i := 0 to High(Specs) do
  begin
    K := Specs[i].Kind;
    if K = '' then K := 'knowledge';
    { Show relative path under ~/.pasclaw so the line stays readable. }
    Src := Specs[i].Source;
    if Pos(GetHome, Src) = 1 then
      Src := '~' + Copy(Src, Length(GetHome) + 1, MaxInt);
    PrintLn(Format('%18s  %9s  %s', [Specs[i].Name, K, Src]));
    if Specs[i].Description <> '' then
      PrintLn('                    ' + Ansi.Dim + Specs[i].Description + Ansi.Reset);
  end;
  Result := 0;
end;

function DoInstallGitHub(const Target: string): Integer;
var
  DestRoot, Installed, ErrMsg: string;
begin
  DestRoot := JoinPath(GetHome, ActiveWorkspaceName + '/skills');
  PrintLn('Fetching ' + Target + ' …');
  if not InstallFromGitHub(Target, DestRoot, Installed, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'install failed: ' + ErrMsg);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'installed as ' +
          JoinPath(DestRoot, Installed));
  PrintLn('  Run ' + Ansi.Bold + 'pasclaw skills list' + Ansi.Reset +
          ' to confirm; next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
          ' invocation will pick it up.');
  Result := 0;
end;

function DoInstallLegacy(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  n: Integer;
begin
  Cfg := LoadConfig;
  try
    n := Length(Cfg.Skills);
    SetLength(Cfg.Skills, n + 1);
    Cfg.Skills[n].Name    := Argv[1];
    Cfg.Skills[n].Source  := Argv[1];
    Cfg.Skills[n].Enabled := True;
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'recorded ' + Argv[1] + ' in config.json');
    PrintLn(Ansi.Dim + '  (no files downloaded -- for a GitHub install use ' +
            'owner/repo syntax)' + Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoInstallClawHub(const Target: string): Integer;
var
  Slug, Version, DestRoot, Installed, ErrMsg: string;
begin
  SplitSlugAtVersion(Target, Slug, Version);
  DestRoot := JoinPath(GetHome, ActiveWorkspaceName + '/skills');
  if Version <> '' then
    PrintLn('Fetching clawhub:' + Slug + ' @' + Version + ' …')
  else
    PrintLn('Fetching clawhub:' + Slug + ' …');
  if not InstallFromClawHub(Slug, Version, DestRoot, Installed, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'install failed: ' + ErrMsg);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'installed as ' +
          JoinPath(DestRoot, Installed));
  PrintLn('  Run ' + Ansi.Bold + 'pasclaw skills list' + Ansi.Reset +
          ' to confirm; next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
          ' invocation will pick it up.');
  Result := 0;
end;

function DoInstallPasClawHub(const Target: string): Integer;
{ Parallel to DoInstallClawHub but targets the pasclaw.dev hub. Used
  by the explicit `hub:<slug>` prefix and by the bare-slug fallback
  chain (which tries this first, then ClawHub on a not-found / network
  error). }
var
  Slug, Version, DestRoot, Installed, ErrMsg: string;
begin
  SplitSlugAtVersion(Target, Slug, Version);
  DestRoot := JoinPath(GetHome, ActiveWorkspaceName + '/skills');
  if Version <> '' then
    PrintLn('Fetching pasclaw.dev: ' + Slug + ' @' + Version + ' …')
  else
    PrintLn('Fetching pasclaw.dev: ' + Slug + ' …');
  if not InstallFromPasClawHub(Slug, Version, DestRoot, Installed, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'install failed: ' + ErrMsg);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'installed as ' +
          JoinPath(DestRoot, Installed));
  PrintLn('  Run ' + Ansi.Bold + 'pasclaw skills list' + Ansi.Reset +
          ' to confirm; next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
          ' invocation will pick it up.');
  Result := 0;
end;

function TryInstallFromHub(const Slug, Version, DestRoot: string;
                            out InstalledName, ErrMsg: string;
                            out NotFound: Boolean): Boolean;
{ Thin wrapper around InstallFromPasClawHub that splits "not found"
  (the hub doesn't carry this slug) from other failures (network /
  TLS / parse error). Only `not found` lets the bare-slug dispatcher
  fall through to ClawHub -- a network blip pinned on pasclaw.dev
  should surface as an error rather than silently retrying against
  a different hub the user may not have intended. }
begin
  NotFound := False;
  Result := InstallFromPasClawHub(Slug, Version, DestRoot, InstalledName, ErrMsg);
  if Result then Exit;
  NotFound := SameText(ErrMsg, 'not found');
end;

function DoInstallBareSlug(const Argv: array of string): Integer;
{ Bare-slug install: try pasclaw.dev first, fall back to ClawHub on
  'not found', fall back to the legacy "just record in config.json"
  path only when BOTH hubs report not-found. Network errors on the
  first hop surface as failures rather than silently demoting to
  ClawHub -- that way an unreachable pasclaw.dev (cached DNS, mid-
  flight TLS rotation, etc.) is visible to the operator instead of
  being papered over. }
var
  Slug, Version, DestRoot, Installed, ErrMsg: string;
  HubNotFound, ClawNotFound: Boolean;
begin
  SplitSlugAtVersion(Argv[1], Slug, Version);
  DestRoot := JoinPath(GetHome, ActiveWorkspaceName + '/skills');

  if Version <> '' then
    PrintLn('Fetching pasclaw.dev: ' + Slug + ' @' + Version + ' …')
  else
    PrintLn('Fetching pasclaw.dev: ' + Slug + ' …');
  if TryInstallFromHub(Slug, Version, DestRoot, Installed, ErrMsg, HubNotFound) then
  begin
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'installed as ' +
            JoinPath(DestRoot, Installed));
    PrintLn('  Run ' + Ansi.Bold + 'pasclaw skills list' + Ansi.Reset +
            ' to confirm; next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
            ' invocation will pick it up.');
    Exit(0);
  end;
  if not HubNotFound then
  begin
    { Real error, not a miss -- surface and stop. }
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'pasclaw.dev install failed: ' + ErrMsg);
    PrintLn(Ansi.Dim + '  retry with ' + Ansi.Reset + '`pasclaw skills install clawhub:' + Slug + '`' +
            Ansi.Dim + ' to force ClawHub.' + Ansi.Reset);
    Exit(1);
  end;

  PrintLn(Ansi.Dim + '  not on pasclaw.dev -- trying ClawHub …' + Ansi.Reset);
  { Pre-call `ClawNotFound := False` removed -- dead write per dcc64
    H2077. The only read is at the `if not ClawNotFound` below, and
    we unconditionally reassign on line `ClawNotFound := SameText(...)`
    before that read. }
  if InstallFromClawHub(Slug, Version, DestRoot, Installed, ErrMsg) then
  begin
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'installed as ' +
            JoinPath(DestRoot, Installed) + Ansi.Dim + ' (from ClawHub)' + Ansi.Reset);
    PrintLn('  Run ' + Ansi.Bold + 'pasclaw skills list' + Ansi.Reset +
            ' to confirm; next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset +
            ' invocation will pick it up.');
    Exit(0);
  end;
  ClawNotFound := SameText(ErrMsg, 'not found');
  if not ClawNotFound then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'ClawHub install failed: ' + ErrMsg);
    Exit(1);
  end;

  { Both hubs say "not found". Fall through to legacy record-only
    behaviour so existing user scripts that did
    `pasclaw skills install my-local-name` keep working -- with a
    note that nothing was downloaded. }
  PrintLn(Ansi.Yellow + '! ' + Ansi.Reset +
          'no hub entry for "' + Slug + '" -- recording in config.json only.');
  Result := DoInstallLegacy(Argv);
end;

function DoInstall(const Argv: array of string): Integer;
var
  HubSlug, ClawHubSlug: string;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  { Explicit hub prefixes are checked first so an out-of-shape target
    like `hub:owner/repo` routes to the validator, which rejects the
    slash and falls through to legacy. Same hardening as the original
    ClawHub prefix; mirrored for `hub:` so the GitHub sniff doesn't
    eat the slash on a malformed prefix. Bare slugs (no slash, no
    leading dot/drive letter, no colon) take the new hub-then-clawhub
    fallback chain; anything left over (paths, malformed targets)
    drops to the legacy record-in-config path. }
  if IsPasClawHubTarget(Argv[1], HubSlug) then
    Result := DoInstallPasClawHub(HubSlug)
  else if IsClawHubTarget(Argv[1], ClawHubSlug) then
    Result := DoInstallClawHub(ClawHubSlug)
  else if IsGitHubTarget(Argv[1]) then
    Result := DoInstallGitHub(Argv[1])
  else if IsBareSlug(Argv[1]) then
    Result := DoInstallBareSlug(Argv)
  else
    Result := DoInstallLegacy(Argv);
end;

function DoSearch(const Argv: array of string): Integer;
var
  Query, HubErr, ClawErr: string;
  HubResults: TPasClawHubResultArray;
  ClawResults: TClawHubResultArray;
  i: Integer;
  Summary, Source: string;
  HubOk, ClawOk: Boolean;
  Slug: string;
  SeenSlugs: TStringList;
  TotalShown: Integer;
begin
  if Length(Argv) < 2 then
  begin
    PrintLn('Usage: pasclaw skills search <query>');
    Exit(1);
  end;
  Query := Argv[1];

  { Query both hubs. pasclaw.dev results render first; ClawHub
    results follow, with slugs already seen on pasclaw.dev dropped
    (the local hub wins the dedup). Either hub being unreachable
    is recoverable -- we degrade to whatever did respond. }
  PrintLn('Searching pasclaw.dev + ClawHub: ' + Query + ' …');
  HubOk := SearchPasClawHub(Query, 20, HubResults, HubErr);
  ClawOk := SearchClawHub(Query, 20, ClawResults, ClawErr);
  if (not HubOk) and (not ClawOk) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'both hubs failed:');
    PrintLn('  pasclaw.dev: ' + HubErr);
    PrintLn('  clawhub:     ' + ClawErr);
    Exit(1);
  end;
  if not HubOk then
    PrintLn(Ansi.Yellow + '! ' + Ansi.Reset +
            'pasclaw.dev unreachable (' + HubErr + ') -- showing ClawHub only');
  if not ClawOk then
    PrintLn(Ansi.Yellow + '! ' + Ansi.Reset +
            'clawhub unreachable (' + ClawErr + ') -- showing pasclaw.dev only');

  if (Length(HubResults) = 0) and (Length(ClawResults) = 0) then
  begin
    PrintLn('(no matches)');
    Exit(0);
  end;

  PrintLn(Ansi.Bold + 'src   slug' + Ansi.Reset +
          '                       version    name');
  TotalShown := 0;
  SeenSlugs := TStringList.Create;
  try
    SeenSlugs.CaseSensitive := False;
    for i := 0 to High(HubResults) do
    begin
      Slug := HubResults[i].Slug;
      if SeenSlugs.IndexOf(Slug) >= 0 then Continue;
      SeenSlugs.Add(Slug);
      Source := Ansi.Bold + 'hub' + Ansi.Reset;
      PrintLn(Format('%s   %24s  %9s  %s',
              [Source, Slug, HubResults[i].Version, HubResults[i].DisplayName]));
      Summary := Trim(HubResults[i].Summary);
      if Summary <> '' then
        PrintLn('                                  ' + Ansi.Dim + Summary + Ansi.Reset);
      Inc(TotalShown);
    end;
    for i := 0 to High(ClawResults) do
    begin
      Slug := ClawResults[i].Slug;
      if SeenSlugs.IndexOf(Slug) >= 0 then Continue;
      SeenSlugs.Add(Slug);
      Source := Ansi.Dim + 'claw' + Ansi.Reset;
      PrintLn(Format('%s  %24s  %9s  %s',
              [Source, Slug, ClawResults[i].Version, ClawResults[i].DisplayName]));
      Summary := Trim(ClawResults[i].Summary);
      if Summary <> '' then
        PrintLn('                                  ' + Ansi.Dim + Summary + Ansi.Reset);
      Inc(TotalShown);
    end;
  finally
    SeenSlugs.Free;
  end;

  if TotalShown = 0 then
  begin
    PrintLn('(no matches)');
    Exit(0);
  end;

  PrintLn;
  PrintLn(Ansi.Dim + 'Install with: ' + Ansi.Reset +
          Ansi.Bold + 'pasclaw skills install <slug>' + Ansi.Reset +
          Ansi.Dim + ' (tries pasclaw.dev first, then ClawHub).' + Ansi.Reset);
  Result := 0;
end;

procedure RemoveSkillDir(const Dir: string);
{ Recursive delete used by `skills remove`. Best-effort: failures get
  logged but do not block the config-side removal. }

  procedure Walk(const D: string);
  var
    SR: TSearchRec;
    Path: string;
  begin
    if FindFirst(JoinPath(D, '*'), faAnyFile, SR) <> 0 then Exit;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Path := JoinPath(D, SR.Name);
        if (SR.Attr and faDirectory) <> 0 then Walk(Path)
        else try DeleteFile(Path); except end;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    try RemoveDir(D); except end;
  end;

begin
  if DirectoryExists(Dir) then Walk(Dir);
end;

function IsSafeSkillName(const Name: string): Boolean;
{ Skill names go into JoinPath without canonicalisation, so a path
  with separators or '..' would escape workspace/skills/ and let
  `pasclaw skills remove ../memory` recursively delete an unrelated
  workspace subtree. Only single-segment ASCII-ish names are
  accepted on the remove path. Names that came from
  InstallFromGitHub are derived from URL path segments -- none of
  the rejected characters can appear there -- so legitimate
  installs always pass. }
var
  i: Integer;
begin
  Result := False;
  if (Name = '') or (Name = '.') or (Name = '..') then Exit;
  for i := 1 to Length(Name) do
    case Name[i] of
      '/', '\', ':', #0..#31: Exit;
    end;
  if Pos('..', Name) > 0 then Exit;
  Result := True;
end;

function DoRemove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i, dst: Integer;
  WorkspaceDir, LegacyJSON: string;
  RemovedFiles: Boolean;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if not IsSafeSkillName(Argv[1]) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset +
            'unsafe skill name "' + Argv[1] + '" -- skill names must be a single ' +
            'path segment with no /, \, :, or ".." sequence');
    Exit(1);
  end;
  RemovedFiles := False;

  WorkspaceDir := JoinPath(GetHome, ActiveWorkspaceName + '/skills');
  LegacyJSON   := JoinPath(WorkspaceDir, Argv[1] + '.json');
  if FileExists(LegacyJSON) then
  begin
    if DeleteFile(LegacyJSON) then RemovedFiles := True
    else LogWarn('skills: could not delete %s', [LegacyJSON]);
  end;
  if DirectoryExists(JoinPath(WorkspaceDir, Argv[1])) then
  begin
    RemoveSkillDir(JoinPath(WorkspaceDir, Argv[1]));
    RemovedFiles := True;
  end;

  Cfg := LoadConfig;
  try
    dst := 0;
    for i := 0 to High(Cfg.Skills) do
      if not SameText(Cfg.Skills[i].Name, Argv[1]) then
      begin
        Cfg.Skills[dst] := Cfg.Skills[i];
        Inc(dst);
      end;
    SetLength(Cfg.Skills, dst);
    SaveConfig(Cfg);
  finally
    Cfg.Free;
  end;
  if RemovedFiles then
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'removed ' + Argv[1])
  else
    PrintLn(Ansi.Yellow + '(' + Argv[1] +
            ' was not found on disk; config entry cleared if present)' +
            Ansi.Reset);
  Result := 0;
end;

function DoPending: Integer;
var
  Pend: TPendingSkillArray;
  i: Integer;
begin
  Pend := ListPending(GetHome);
  if Length(Pend) = 0 then
  begin
    PrintLn('(no pending skills)');
    PrintLn(Ansi.Dim + '  Agent-authored skills land here when ' +
            'self_improving_skills.auto_approve is false.' + Ansi.Reset);
    Exit(0);
  end;
  PrintLn(Ansi.Bold + 'id                      action   name' + Ansi.Reset);
  for i := 0 to High(Pend) do
    PrintLn(Format('%-22s  %-7s  %s', [Pend[i].Id, Pend[i].Action, Pend[i].Name]));
  PrintLn;
  PrintLn(Ansi.Dim + 'Inspect: pasclaw skills diff <id>   ' +
          'Commit: pasclaw skills approve <id>   ' +
          'Discard: pasclaw skills reject <id>' + Ansi.Reset);
  Result := 0;
end;

function DoDiff(const Argv: array of string): Integer;
var
  Content, ErrMsg: string;
begin
  if Length(Argv) < 2 then begin PrintLn('Usage: pasclaw skills diff <id>'); Exit(1); end;
  if not ReadPending(GetHome, Argv[1], Content, ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + ErrMsg);
    Exit(1);
  end;
  PrintLn(Content);
  Result := 0;
end;

function DoApprove(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  ErrMsg: string;
begin
  if Length(Argv) < 2 then begin PrintLn('Usage: pasclaw skills approve <id>'); Exit(1); end;
  Cfg := LoadConfig;
  try
    if not ApprovePending(GetHome, Argv[1], Cfg, ErrMsg) then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'approve failed: ' + ErrMsg);
      Exit(1);
    end;
  finally
    Cfg.Free;
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'approved ' + Argv[1] +
          ' -- effective on next ' + Ansi.Bold + 'pasclaw agent' + Ansi.Reset + ' run.');
  Result := 0;
end;

function DoReject(const Argv: array of string): Integer;
var
  ErrMsg: string;
begin
  if Length(Argv) < 2 then begin PrintLn('Usage: pasclaw skills reject <id>'); Exit(1); end;
  if not RejectPending(GetHome, Argv[1], ErrMsg) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'reject failed: ' + ErrMsg);
    Exit(1);
  end;
  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'discarded ' + Argv[1] + '.');
  Result := 0;
end;

function Cmd_Skills_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'    then Result := DoList
  else if Sub = 'install' then Result := DoInstall(Argv)
  else if Sub = 'remove'  then Result := DoRemove(Argv)
  else if Sub = 'search'  then Result := DoSearch(Argv)
  else if Sub = 'pending' then Result := DoPending
  else if Sub = 'diff'    then Result := DoDiff(Argv)
  else if Sub = 'approve' then Result := DoApprove(Argv)
  else if Sub = 'reject'  then Result := DoReject(Argv)
  else if Sub = 'verify'  then Result := DoVerify
  else begin Help; Result := 1; end;
end;

end.
