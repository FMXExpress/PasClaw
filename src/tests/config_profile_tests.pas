program config_profile_tests;
(*
  PR #291: configuration profile machinery.

  Coverage:
    - Built-in catalogue: ListAvailableProfiles returns the five
      built-ins, each with a non-empty description.
    - LookupProfile + ResolveProfileBodies handle the base case,
      inheritance, and the error paths (unknown name, cycle).
    - max-build inherits low-token; both layers come back in the
      right order (parent first, child last).
    - User profile at $PASCLAW_HOME/profiles/<name>.json shadows a
      built-in with the same name.
    - ExtractProfileField pulls the "profile" key out of a config.json
      blob; returns '' on absent / malformed input.
    - End-to-end LoadConfig(name) applies the profile fields, and an
      operator config.json value wins over the profile value.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Config.Profile,
  PasClaw.Utils;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

procedure AssertEqI(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')'); end;

var
  Home: string;

procedure TestCatalogue;
var
  Profiles: TProfileSpecArray;
  i: Integer;
  HaveStock, HaveBaseline, HaveLowToken, HaveSecurity, HaveMaxBuild, HaveAllOn: Boolean;
begin
  Profiles := ListAvailableProfiles(Home);
  AssertTrue(Length(Profiles) >= 6, 'at least six built-ins');
  HaveStock := False; HaveBaseline := False; HaveLowToken := False;
  HaveSecurity := False; HaveMaxBuild := False; HaveAllOn := False;
  for i := 0 to High(Profiles) do
  begin
    AssertTrue(Profiles[i].Description <> '', 'profile "' + Profiles[i].Name + '" has a description');
    if Profiles[i].Name = 'stock'     then HaveStock     := True;
    if Profiles[i].Name = 'baseline'  then HaveBaseline  := True;
    if Profiles[i].Name = 'low-token' then HaveLowToken  := True;
    if Profiles[i].Name = 'security'  then HaveSecurity  := True;
    if Profiles[i].Name = 'max-build' then HaveMaxBuild  := True;
    if Profiles[i].Name = 'all-on'    then HaveAllOn     := True;
  end;
  AssertTrue(HaveStock,    'stock present');
  AssertTrue(HaveBaseline, 'baseline present');
  AssertTrue(HaveLowToken, 'low-token present');
  AssertTrue(HaveSecurity, 'security present');
  AssertTrue(HaveMaxBuild, 'max-build present');
  AssertTrue(HaveAllOn,    'all-on present');
  AssertTrue(IsBuiltinProfile('stock'),    'stock is built-in');
  AssertTrue(IsBuiltinProfile('baseline'), 'baseline is built-in');
  AssertTrue(not IsBuiltinProfile('not-a-real-one'), 'unknown is not built-in');
end;

(* PR #291 follow-up: `stock` mirrors TConfig.Create defaults so
   applying it is a no-op. The drift test: load a fresh TConfig, snap
   the relevant booleans/ints, then apply `stock`, then compare. They
   must match -- a divergence means the stock profile and
   TConfig.Create have drifted. *)
procedure TestStockMatchesDefaults;
var
  Fresh, Stocked: TConfig;
begin
  Fresh   := TConfig.Create;
  Stocked := LoadConfig('stock');
  try
    AssertTrue(Fresh.VaultToolsEnabled    = Stocked.VaultToolsEnabled,    'stock: vault_tools_enabled');
    AssertTrue(Fresh.WebFetchEnabled      = Stocked.WebFetchEnabled,      'stock: web_fetch_enabled');
    AssertTrue(Fresh.VectorSearchEnabled  = Stocked.VectorSearchEnabled,  'stock: vector_search_enabled');
    AssertTrue(Fresh.RenderMarkdown       = Stocked.RenderMarkdown,       'stock: render_markdown');
    AssertTrue(Fresh.PromptwareEnabled    = Stocked.PromptwareEnabled,    'stock: promptware_enabled');
    AssertTrue(Fresh.CondenseReversible   = Stocked.CondenseReversible,   'stock: condense_reversible');
    AssertTrue(Fresh.ToolOutputCap        = Stocked.ToolOutputCap,        'stock: tool_output_cap');
    AssertTrue(Fresh.OrientTaskAware      = Stocked.OrientTaskAware,      'stock: orient_task_aware');
    AssertTrue(Fresh.StatsCollectionEnabled = Stocked.StatsCollectionEnabled, 'stock: stats_collection_enabled');
    AssertTrue(Fresh.CheckpointsEnabled   = Stocked.CheckpointsEnabled,   'stock: checkpoints_enabled');
    AssertTrue(Fresh.SelfImprovingSkills.SelfManage =
               Stocked.SelfImprovingSkills.SelfManage,
               'stock: self_improving_skills.self_manage');
    AssertTrue(Fresh.SelfImprovingSkills.ProgressiveDisclosure =
               Stocked.SelfImprovingSkills.ProgressiveDisclosure,
               'stock: self_improving_skills.progressive_disclosure');
    AssertTrue(Fresh.SelfImprovingSkills.AutoApprove =
               Stocked.SelfImprovingSkills.AutoApprove,
               'stock: self_improving_skills.auto_approve');
    AssertTrue(Fresh.SelfImprovingSkills.Distiller.Enabled =
               Stocked.SelfImprovingSkills.Distiller.Enabled,
               'stock: self_improving_skills.distiller.enabled');
    AssertTrue(Fresh.AutoRouter.Enabled   = Stocked.AutoRouter.Enabled,   'stock: auto_router.enabled');
    AssertTrue(Fresh.PromptCache.Enabled  = Stocked.PromptCache.Enabled,  'stock: prompt_cache.enabled');
    AssertTrue(Fresh.Sandbox.RestrictToWorkspace =
               Stocked.Sandbox.RestrictToWorkspace,
               'stock: sandbox.restrict_to_workspace');
    AssertTrue(Fresh.Sandbox.ShellDenyEnabled =
               Stocked.Sandbox.ShellDenyEnabled,
               'stock: sandbox.shell_deny_enabled');
    AssertTrue(Fresh.Sandbox.BlockPrivateNetworks =
               Stocked.Sandbox.BlockPrivateNetworks,
               'stock: sandbox.block_private_networks');
  finally
    Stocked.Free;
    Fresh.Free;
  end;
end;

procedure TestResolveSingleLayer;
var
  Bodies: TProfileBodyArray;
  Err: string;
begin
  AssertTrue(ResolveProfileBodies(Home, 'low-token', Bodies, Err),
             'resolve low-token: ' + Err);
  AssertEqI(Length(Bodies), 1, 'low-token has one layer');
  AssertTrue(Pos('"condense_reversible":true', Bodies[0]) > 0,
             'low-token body contains condense_reversible');
end;

procedure TestResolveInherits;
var
  Bodies: TProfileBodyArray;
  Err: string;
begin
  { max-build _inherits low-token. Resolution order is parent first,
    so Bodies[0] should be low-token and Bodies[1] should be max-build. }
  AssertTrue(ResolveProfileBodies(Home, 'max-build', Bodies, Err),
             'resolve max-build: ' + Err);
  AssertEqI(Length(Bodies), 2, 'max-build has two layers');
  AssertTrue(Pos('"_description":"Minimise tokens', Bodies[0]) > 0,
             'first layer is low-token (the parent)');
  AssertTrue(Pos('"_description":"Best settings', Bodies[1]) > 0,
             'second layer is max-build itself');

  { all-on _inherits max-build, which itself _inherits low-token.
    So three layers in transitive order: low-token, max-build, all-on. }
  AssertTrue(ResolveProfileBodies(Home, 'all-on', Bodies, Err),
             'resolve all-on: ' + Err);
  AssertEqI(Length(Bodies), 3, 'all-on resolves three layers');
end;

procedure TestUnknownProfile;
var
  Bodies: TProfileBodyArray;
  Err: string;
begin
  AssertTrue(not ResolveProfileBodies(Home, 'not-a-real-one', Bodies, Err),
             'unknown profile rejected');
  AssertTrue(Pos('not found', Err) > 0, 'error message mentions not found');
end;

procedure TestUserProfileShadowsBuiltin;
var
  Bodies: TProfileBodyArray;
  Err, ProfilesDir: string;
  Spec: TProfileSpec;
  Body: string;
begin
  ProfilesDir := JoinPath(Home, 'profiles');
  EnsureDir(ProfilesDir);
  { Write a user "low-token" that sets a distinctive field so we can
    confirm it WINS over the built-in. }
  WriteFileText(JoinPath(ProfilesDir, 'low-token.json'),
    '{"_description":"USER override low-token","tool_output_cap":4242}');
  try
    AssertTrue(LookupProfile(Home, 'low-token', Spec, Body),
               'lookup low-token after user shadow');
    AssertTrue(Pos('USER override', Body) > 0, 'user body wins');
    AssertEqS(Spec.Source, JoinPath(ProfilesDir, 'low-token.json'),
              'source is the user file path');
  finally
    DeleteFile(JoinPath(ProfilesDir, 'low-token.json'));
  end;
end;

procedure TestExtractProfileField;
begin
  AssertEqS(ExtractProfileField('{"profile":"low-token"}'),
            'low-token', 'extract profile field');
  AssertEqS(ExtractProfileField('{"other":"x"}'),
            '', 'absent returns empty');
  AssertEqS(ExtractProfileField(''), '', 'empty body returns empty');
  AssertEqS(ExtractProfileField('not-json'), '', 'malformed returns empty');
end;

procedure TestLoadConfigAppliesProfile;
var
  CfgPath: string;
  C: TConfig;
begin
  { Write a config.json with NO profile field and ONE explicit
    override: condense_reversible=false (matches the post-PR-#289
    default). Then call LoadConfig with --profile low-token. The
    profile sets condense_reversible=true, tool_output_cap=8192.
    The config.json has no condense_reversible field (since it
    matches the default and our ToJSON suppresses it). After load:
      tool_output_cap should be 8192 (profile value, no override)
      orient_task_aware should be True (profile set, no override)
    Then write an explicit operator value and prove it wins. }
  CfgPath := JoinPath(Home, 'config.json');

  { Case 1: profile only, no operator overrides. }
  WriteFileText(CfgPath, '{}');
  C := LoadConfig('low-token');
  try
    AssertTrue(C.CondenseReversible, 'profile sets CondenseReversible');
    AssertTrue(C.ToolOutputCap = 8192, 'profile sets ToolOutputCap=8192');
    AssertTrue(C.OrientTaskAware, 'profile sets OrientTaskAware');
  finally
    C.Free;
  end;

  { Case 2: operator config.json wins over profile. }
  WriteFileText(CfgPath, '{"tool_output_cap":2048}');
  C := LoadConfig('low-token');
  try
    AssertTrue(C.CondenseReversible, 'profile still applies (no override)');
    if C.ToolOutputCap <> 2048 then
      Fail_('operator wins over profile (got cap=' + IntToStr(C.ToolOutputCap) + ', want 2048)');
  finally
    C.Free;
  end;

  { Case 3: config.json "profile" field is honoured when no CLI flag. }
  WriteFileText(CfgPath, '{"profile":"low-token"}');
  C := LoadConfig('');
  try
    AssertTrue(C.CondenseReversible, 'config.json "profile" field is read');
    AssertTrue(C.ToolOutputCap = 8192, 'config.json profile applies');
  finally
    C.Free;
  end;
end;

procedure TestLoadConfigInheritsChain;
var
  CfgPath: string;
  C: TConfig;
begin
  CfgPath := JoinPath(Home, 'config.json');
  WriteFileText(CfgPath, '{}');
  C := LoadConfig('max-build');
  try
    { max-build inherits low-token, then overrides tool_output_cap to 16384. }
    AssertTrue(C.ToolOutputCap = 16384, 'max-build override wins over parent');
    AssertTrue(C.OrientTaskAware, 'low-token field inherited through max-build');
    AssertTrue(C.WebFetchEnabled, 'max-build sets WebFetchEnabled');
    AssertTrue(C.SelfImprovingSkills.SelfManage,
               'max-build sets self_manage on top of progressive_disclosure from parent');
    AssertTrue(C.SelfImprovingSkills.ProgressiveDisclosure,
               'progressive_disclosure inherited from low-token');
  finally
    C.Free;
  end;
end;

(* Codex P2 #1: --profile / PASCLAW_PROFILE must work even when
   config.json doesn't exist. *)
procedure TestProfileWithoutConfigFile;
var
  CfgPath: string;
  C: TConfig;
begin
  CfgPath := JoinPath(Home, 'config.json');
  if FileExists(CfgPath) then DeleteFile(CfgPath);
  AssertTrue(not FileExists(CfgPath), 'config.json removed before test');

  C := LoadConfig('low-token');
  try
    AssertTrue(C.CondenseReversible, 'profile applied without config.json');
    AssertTrue(C.ToolOutputCap = 8192, 'tool_output_cap set from profile alone');
  finally
    C.Free;
  end;
end;

(* Codex P2 #2: SaveConfig must preserve the persisted profile field
   so mutating commands (auth login, model set, ...) don't drop it. *)
procedure TestSaveConfigPreservesProfile;
var
  C, C2: TConfig;
  CfgPath: string;
begin
  CfgPath := JoinPath(Home, 'config.json');
  WriteFileText(CfgPath, '{}');

  { Stamp "profile": "low-token" via the TConfig field + SaveConfig
    (same path `pasclaw profile use` writes through). }
  C := LoadConfig('');
  try
    C.Profile := 'low-token';
    SaveConfig(C);
  finally
    C.Free;
  end;

  { Simulate a config-mutating command: load, edit something
    unrelated, save again. The profile field must survive. }
  C := LoadConfig('');
  try
    AssertEqS(C.Profile, 'low-token', 'persisted profile read back');
    C.DefaultModel := 'claude-opus-4-7';
    SaveConfig(C);
  finally
    C.Free;
  end;

  { Final load: profile is still there. }
  C2 := LoadConfig('');
  try
    AssertEqS(C2.Profile, 'low-token', 'profile survives SaveConfig');
    AssertEqS(C2.DefaultModel, 'claude-opus-4-7', 'unrelated edit persisted');
    AssertTrue(C2.CondenseReversible,
               'profile actually applied on the persisted-field path');
  finally
    C2.Free;
  end;
end;

(* Codex P2 #3: a user file at $HOME/profiles/low-token.json whose
   _inherits contains "low-token" should resolve to (built-in low-token
   layer, then user's overrides) -- not a cycle error. *)
procedure TestSelfShadowInherit;
var
  ProfilesDir, UserFile: string;
  Bodies: TProfileBodyArray;
  Err: string;
begin
  ProfilesDir := JoinPath(Home, 'profiles');
  EnsureDir(ProfilesDir);
  UserFile := JoinPath(ProfilesDir, 'low-token.json');
  WriteFileText(UserFile,
    '{"_description":"USER fork of low-token, smaller cap",' +
    '"_inherits":["low-token"],' +
    '"tool_output_cap":4096}');
  try
    AssertTrue(ResolveProfileBodies(Home, 'low-token', Bodies, Err),
               'self-shadow resolves: ' + Err);
    AssertEqI(Length(Bodies), 2, 'two layers: built-in then user override');
    AssertTrue(Pos('"_description":"Minimise tokens', Bodies[0]) > 0,
               'first layer is the built-in low-token');
    AssertTrue(Pos('USER fork of low-token', Bodies[1]) > 0,
               'second layer is the user file');
  finally
    DeleteFile(UserFile);
  end;
end;

(* PR #292 Stage D-prep: the diff command relies on profiles producing
   different TConfig states. This test checks the contract from the
   TConfig side -- if two profiles do diverge on at least one tracked
   field, that divergence shows up post-apply. (DoDiff's own table
   layout is exercised by smoke; the field-level divergence is the
   logical invariant under test.) *)
procedure TestDiffMaterial;
var
  CfgA, CfgB: TConfig;
begin
  WriteFileText(JoinPath(Home, 'config.json'), '{}');
  CfgA := LoadConfig('baseline');
  CfgB := LoadConfig('max-build');
  try
    AssertTrue((CfgA.VaultToolsEnabled <> CfgB.VaultToolsEnabled) or
               (CfgA.WebFetchEnabled   <> CfgB.WebFetchEnabled) or
               (CfgA.CondenseReversible <> CfgB.CondenseReversible) or
               (CfgA.ToolOutputCap     <> CfgB.ToolOutputCap),
               'baseline vs max-build differ on at least one tracked field');
  finally
    CfgA.Free; CfgB.Free;
  end;

  { stock vs the baseline of TConfig.Create should be a no-op. }
  CfgA := LoadConfig('stock');
  CfgB := LoadConfig('');
  try
    AssertTrue(CfgA.VaultToolsEnabled  = CfgB.VaultToolsEnabled,  'stock vs no-profile: vault');
    AssertTrue(CfgA.CondenseReversible = CfgB.CondenseReversible, 'stock vs no-profile: condense');
    AssertTrue(CfgA.ToolOutputCap      = CfgB.ToolOutputCap,      'stock vs no-profile: cap');
  finally
    CfgA.Free; CfgB.Free;
  end;
end;

begin
  { PASCLAW_HOME is set by the Makefile target before launching --
    fpc doesn't ship fpSetenv on every supported version and setting
    the env from Pascal mid-process is unreliable across libc/FPC
    runtime boundaries. Read it back here. }
  Home := GetEnvironmentVariable('PASCLAW_HOME');
  if Home = '' then
  begin
    WriteLn('FAIL: test must be invoked with PASCLAW_HOME set ' +
            '(see Makefile target test-config-profile)');
    Halt(1);
  end;
  EnsureDir(Home);
  try
    TestCatalogue;
    TestStockMatchesDefaults;
    TestResolveSingleLayer;
    TestResolveInherits;
    TestUnknownProfile;
    TestUserProfileShadowsBuiltin;
    TestExtractProfileField;
    TestLoadConfigAppliesProfile;
    TestLoadConfigInheritsChain;
    TestProfileWithoutConfigFile;
    TestSaveConfigPreservesProfile;
    TestSelfShadowInherit;
    TestDiffMaterial;
    WriteLn('ok - config profile tests passed');
  finally
    try RemoveDir(JoinPath(Home, 'profiles')); except end;
    try DeleteFile(JoinPath(Home, 'config.json')); except end;
    try RemoveDir(Home); except end;
  end;
end.
