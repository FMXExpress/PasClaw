(*
  PasClaw.Config.Profile - configuration profiles.

  A profile is a small JSON blob that gets merged into TConfig BEFORE
  the operator's config.json is applied. Five built-in profiles ship
  embedded as Pascal string constants below; operators can add their
  own by dropping files at $PASCLAW_HOME/profiles/<name>.json.

  Six built-ins:

    stock       TConfig.Create's exact defaults. Adopted the bench-
                grounded lean-edit shape (bench/swe/README.md): vault OFF
                out-of-box (operators turn it on via onboarding when they
                actually use it), web_fetch and the memory_fetch it gates
                ON (TConfig.Create sets WebFetchEnabled := True, and
                Profile_Stock carries "web_fetch_enabled":true); the
                five zero-prompt-cost behavioral toggles (checkpoints,
                stats, 1h prompt cache, distiller, auto-router) ON by
                default. orient_task_aware is OFF by default (whole-file
                MEMORY injection is the contract; opt in per-run with
                `pasclaw agent --orient`). fs_edit_hashline ON by default
                (small-model operators opt out via onboarding's
                PromptHashline question or the --no-hashline CLI flag);
                fs_grep registers UNCONDITIONALLY -- its six ripgrep-
                inspired optimisations (skip lists, BMH, binary
                detection, byte-walking, file-size cap, deferred
                hashing) make it 10-50x faster than shell_exec grep on
                real codebases, and on Windows it's the only grep
                equivalent available. Applying the profile explicitly
                is a no-op; it exists so `pasclaw profile show stock`
                documents the no-profile fresh-install state.

    baseline    Everything off. Bare-minimum control profile for A/B
                comparison ("how does pasclaw behave with no features").

    low-token   Minimise tokens going to/from the model: condenser on,
                output cap on, prompt cache, progressive disclosure for
                skills (so the registry advertises skills_list/view
                without the heavier skills_manage), auto-router for
                easy turns.

    security    Maximum sandboxing: workspace restriction + shell deny
                + private-network block, promptware scan, web_fetch
                and vault tools off, agent-authored skills stage for
                approval (auto_approve off).

    max-build   Maximum capability surface: web_fetch + vault + memory_fetch
                back on, plus skill discovery (progressive_disclosure)
                and skill authoring (self_manage), condenser + 16KB
                output cap. Use when you need the broadest tool surface
                and don't mind paying ~2900 bytes/turn for it.

    all-on      Every boolean knob flipped on. For surface-area /
                integration testing only.

  Selection precedence (highest wins):

    1. --profile <name> CLI flag (per-invocation).
    2. PASCLAW_PROFILE env var (process scope).
    3. "profile": "<name>" field in $PASCLAW_HOME/config.json (persisted).
    4. None -- TConfig.Create defaults flow straight through.

  Inheritance: a profile MAY carry "_inherits": ["a", "b"] -- the
  named profiles are loaded first, applied in order, then the current
  profile's fields override. Cycles are detected; depth is capped at
  4 to bound recursion. The _description / _inherits / _name keys
  themselves are stripped before the body reaches TConfig.FromJSON.

  Merge mechanics: TConfig.FromJSON is merge-style (every GetX call
  has the current TConfig value as its default), so we just call
  FromJSON once per resolved profile body in order: ancestors first,
  current profile, then the operator's config.json. The last write
  wins by construction -- no separate deep-merge helper needed.
*)
unit PasClaw.Config.Profile;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TProfileSpec = record
    Name:        string;
    Description: string;
    Source:      string;   { 'builtin' | absolute path }
  end;
  TProfileSpecArray = array of TProfileSpec;

  TProfileBodyArray = array of string;

{ Return the catalogue: built-in profiles first, then any user
  $PASCLAW_HOME/profiles/<name>.json shadowing or extending them. }
function ListAvailableProfiles(const HomeDir: string): TProfileSpecArray;

{ True iff a profile with this exact name is shipped as a built-in.
  Used by `pasclaw profile show` to label "built-in" rows. }
function IsBuiltinProfile(const Name: string): Boolean;

{ Resolve a profile name to the FULL ordered list of JSON bodies that
  LoadConfig should apply via TConfig.FromJSON (ancestors first, then
  the profile itself). Each body is the raw profile JSON with the
  meta keys (_description / _inherits / _name) STILL PRESENT --
  TConfig.FromJSON ignores unknown keys, and keeping the meta keys
  in the returned blobs lets `pasclaw profile show` reuse this path
  without a second read. ErrMsg names a missing profile, a cycle, or
  an inheritance over-depth. }
function ResolveProfileBodies(const HomeDir, Name: string;
                              out Bodies: TProfileBodyArray;
                              out ErrMsg: string): Boolean;

{ Read JUST the "profile" field from a raw config.json body, without
  parsing the whole thing into TConfig. Returns '' when the field is
  absent or the body is malformed. Used by LoadConfig before it knows
  whether to apply a profile. }
function ExtractProfileField(const ConfigJSON: string): string;

(* The profile the ACTIVE workspace is bound to, or ''. Reads the same raw
   config text LoadConfig already holds; the active name resolves the same
   way PasClaw.Workspaces does it (env override, then active_workspace,
   then 'workspace') -- duplicated here in miniature because Config sits
   underneath Workspaces and cannot use it. *)
function ExtractWorkspaceProfile(const ConfigJSON: string): string;

(* The profile name that WOULD be applied for the given raw config text and
   an explicit override (CLI --profile; '' when none), following the whole
   precedence chain in one place:

     1. Override      (CLI --profile)
     2. $PASCLAW_PROFILE
     3. the active workspace's binding (workspace_profiles)
     4. the global "profile" field

   LoadConfig uses it to decide what to apply. Callers that need to know
   what a running process resolved -- e.g. the gateway, to warn that a
   runtime workspace switch wants a profile it cannot adopt mid-flight --
   use it so the answer is derived from the same chain rather than a
   re-implementation that can drift. Returns '' when no layer names one. *)
function ResolveProfileName(const ConfigJSON, Override: string): string;

{ Look up one profile's raw JSON body + a TProfileSpec describing it.
  No inheritance resolution -- this is the leaf operation
  ResolveProfileBodies recurses against. Returns False on unknown
  name. }
function LookupProfile(const HomeDir, Name: string;
                      out Spec: TProfileSpec;
                      out Body: string): Boolean;

const
  MaxInheritDepth = 4;

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Logger;

(* ====================================================================
   Built-in profile blobs. Kept as multi-line string concatenations so
   FPC + dcc64 are both happy and source diffs are readable. Order
   matches docs/configuration.md's table.
   ==================================================================== *)

const
  Profile_Baseline: string =
    '{' +
    '"_description":"Everything off. Bare-minimum baseline for A/B testing.",' +
    '"condense_reversible":false,' +
    '"tool_output_cap":0,' +
    '"orient_task_aware":false,' +
    '"promptware_enabled":false,' +
    '"web_fetch_enabled":false,' +
    '"vault_tools_enabled":false,' +
    '"vector_search_enabled":false,' +
    '"checkpoints_enabled":false,' +
    '"stats_collection_enabled":false,' +
    '"self_improving_skills":{' +
      '"self_manage":false,' +
      '"progressive_disclosure":false,' +
      '"auto_approve":false,' +
      '"distiller":{"enabled":false}' +
    '},' +
    '"auto_router":{"enabled":false},' +
    '"prompt_cache":{"enabled":false}' +
    '}';

  Profile_LowToken: string =
    '{' +
    '"_description":"Minimise tokens. Condenser on, output cap, prompt ' +
    'cache, progressive disclosure, auto-router. (MEMORY task-aware ' +
    'orient is off by default -- enable per-run with --orient.)",' +
    '"condense_reversible":true,' +
    '"tool_output_cap":8192,' +
    '"prompt_cache":{"enabled":true,"ttl":"5m"},' +
    '"self_improving_skills":{' +
      '"progressive_disclosure":true' +
    '},' +
    '"auto_router":{"enabled":true}' +
    '}';

  Profile_Security: string =
    '{' +
    '"_description":"Maximum sandboxing: workspace restriction, shell ' +
    'denylist, private-net block, promptware scan, no outbound HTTP, ' +
    'agent-authored skill writes staged for approval.",' +
    '"sandbox":{' +
      '"restrict_to_workspace":true,' +
      '"shell_deny_enabled":true,' +
      '"block_private_networks":true,' +
      '"allow_read_outside_workspace":false' +
    '},' +
    '"promptware_enabled":true,' +
    '"web_fetch_enabled":false,' +
    '"vault_tools_enabled":false,' +
    '"self_improving_skills":{' +
      '"auto_approve":false' +
    '}' +
    '}';

  Profile_MaxBuild: string =
    '{' +
    '"_description":"Best settings for productive coding sessions: ' +
    'web_fetch, vault, vector search, checkpoints, stats, condenser, ' +
    '16KB cap, 1h prompt cache, all four self-improving skill switches.",' +
    '"_inherits":["low-token"],' +
    '"web_fetch_enabled":true,' +
    '"vault_tools_enabled":true,' +
    '"vector_search_enabled":true,' +
    '"checkpoints_enabled":true,' +
    '"checkpoints_keep_last":32,' +
    '"stats_collection_enabled":true,' +
    '"promptware_enabled":true,' +
    '"condense_reversible":true,' +
    '"tool_output_cap":16384,' +
    '"prompt_cache":{"enabled":true,"ttl":"1h"},' +
    '"self_improving_skills":{' +
      '"self_manage":true,' +
      '"progressive_disclosure":true,' +
      '"auto_approve":false,' +
      '"distiller":{"enabled":true,"min_tool_calls":5}' +
    '}' +
    '}';

  Profile_AllOn: string =
    '{' +
    '"_description":"Every boolean knob flipped on, EXCEPT orient ' +
    '(task-aware MEMORY slicing) which is CLI-only via --orient. ' +
    'Surface-area / integration testing only -- not recommended for ' +
    'daily use.",' +
    '"_inherits":["max-build"],' +
    '"self_improving_skills":{' +
      '"auto_approve":true' +
    '}' +
    '}';

  (* `stock` mirrors TConfig.Create's exact defaults as an explicit
     profile so `pasclaw profile show stock` documents the fresh-
     install state. Applying it is a no-op (FromJSON sees its own
     defaults), but it makes the no-profile case visible and lets
     `pasclaw profile diff stock low-token` work cleanly (Stage D
     follow-up). Keep this in lockstep with TConfig.Create -- a
     drift between the two is what the test-config-profile suite's
     stock cross-check catches. *)
  Profile_Stock: string =
    '{' +
    '"_description":"Stock TConfig.Create defaults. vault OFF (operators ' +
    'opt in via onboarding); web_fetch + memory_fetch ON (web_fetch''s ' +
    'description documents the HTML-strip + 50000-char cap so the model ' +
    'knows what it returns); ' +
    'orient (task-aware MEMORY slicing) OFF -- whole-file injection is ' +
    'the contract, opt in per-run with --orient; 5 zero-prompt-cost ' +
    'behavioral toggles ON (checkpoints, ' +
    'stats, 1h cache, distiller, auto-router). hashline_enabled gates ' +
    'fs_edit_hashline ONLY -- defaults True; small-model operators opt ' +
    'out via the onboarding PromptHashline question or --no-hashline ' +
    'CLI flag. fs_grep registers unconditionally (6 ripgrep-inspired ' +
    'optimisations + no shell grep on Windows).",' +
    '"vault_tools_enabled":false,' +
    '"web_fetch_enabled":true,' +
    '"vector_search_enabled":true,' +
    '"render_markdown":true,' +
    '"promptware_enabled":true,' +
    '"condense_reversible":false,' +
    '"tool_output_cap":24576,' +
    '"stats_collection_enabled":true,' +
    '"checkpoints_enabled":true,' +
    '"checkpoints_keep_last":32,' +
    '"self_improving_skills":{' +
      '"self_manage":false,' +
      '"progressive_disclosure":false,' +
      '"auto_approve":false,' +
      '"distiller":{"enabled":true,"min_tool_calls":5}' +
    '},' +
    '"auto_router":{"enabled":true},' +
    '"prompt_cache":{"enabled":true,"ttl":"1h"},' +
    '"sandbox":{' +
      '"restrict_to_workspace":false,' +
      '"shell_deny_enabled":true,' +
      '"block_private_networks":true,' +
      '"allow_read_outside_workspace":false' +
    '}' +
    '}';

type
  TBuiltin = record
    Name:        string;
    Body:        string;
    Description: string;
  end;
  TBuiltinArray = array of TBuiltin;

function Builtins: TBuiltinArray;
begin
  SetLength(Result, 6);
  Result[0].Name := 'stock';      Result[0].Body := Profile_Stock;
  Result[1].Name := 'baseline';   Result[1].Body := Profile_Baseline;
  Result[2].Name := 'low-token';  Result[2].Body := Profile_LowToken;
  Result[3].Name := 'security';   Result[3].Body := Profile_Security;
  Result[4].Name := 'max-build';  Result[4].Body := Profile_MaxBuild;
  Result[5].Name := 'all-on';     Result[5].Body := Profile_AllOn;
end;

function ExtractDescription(const Body: string): string;
var
  O: TJsonObject;
begin
  Result := '';
  try
    O := TJsonObject.Parse(Body);
  except
    Exit;
  end;
  if O = nil then Exit;
  try
    Result := O.GetStr('_description', '');
  finally
    O.Free;
  end;
end;

function IsBuiltinProfile(const Name: string): Boolean;
var
  i: Integer;
  B: TBuiltinArray;
begin
  Result := False;
  B := Builtins;
  for i := 0 to High(B) do
    if SameText(B[i].Name, Name) then Exit(True);
end;

function UserProfilePath(const HomeDir, Name: string): string;
begin
  Result := JoinPath(JoinPath(HomeDir, 'profiles'), Name + '.json');
end;

(* Name safety: a profile name reaches the filesystem, so reject
   slashes, dots, and anything outside lowercase-alphanumeric-dash-
   underscore. Same shape as IsSafeSkillName. *)
function IsSafeProfileName(const Name: string): Boolean;
var
  i: Integer;
  c: Char;
begin
  Result := False;
  if (Name = '') or (Name = '.') or (Name = '..') then Exit;
  if Length(Name) > 64 then Exit;
  for i := 1 to Length(Name) do
  begin
    c := Name[i];
    if not (((c >= 'a') and (c <= 'z')) or
            ((c >= '0') and (c <= '9')) or
            (c = '-') or (c = '_')) then Exit;
  end;
  Result := True;
end;

(* Internal lookup with an explicit user-shadow bypass switch.
   Codex P2 on PR #291: the documented fork pattern
     $PASCLAW_HOME/profiles/low-token.json:
       {"_inherits":["low-token"], "tool_output_cap":4096}
   would loop forever, because LookupProfile('low-token') hit the user
   file for both the child AND the inherited parent, and the resolver
   then saw 'low-token' twice and reported a cycle. The resolver passes
   BypassUserShadow=True when it's chasing an _inherits parent whose
   name matches the CURRENT profile's name, so the parent lookup
   reaches past the user shadow to the built-in underneath. *)
function LookupProfileInternal(const HomeDir, Name: string;
                               BypassUserShadow: Boolean;
                               out Spec: TProfileSpec;
                               out Body: string): Boolean;
var
  i: Integer;
  B: TBuiltinArray;
  Path: string;
begin
  Result := False;
  Body := '';
  Spec := Default(TProfileSpec);
  Spec.Name := Name;
  if not IsSafeProfileName(Name) then Exit;

  { User profile takes precedence over a same-named built-in --
    same shadowing rule the skills loader uses. Lets an operator
    customise a built-in without forking the binary. }
  if not BypassUserShadow then
  begin
    Path := UserProfilePath(HomeDir, Name);
    if FileExists(Path) then
    begin
      Body := ReadFileText(Path);
      Spec.Source := Path;
      Spec.Description := ExtractDescription(Body);
      Exit(True);
    end;
  end;

  B := Builtins;
  for i := 0 to High(B) do
    if SameText(B[i].Name, Name) then
    begin
      Body := B[i].Body;
      Spec.Source := 'builtin';
      Spec.Description := ExtractDescription(Body);
      Exit(True);
    end;
end;

function LookupProfile(const HomeDir, Name: string;
                      out Spec: TProfileSpec;
                      out Body: string): Boolean;
begin
  Result := LookupProfileInternal(HomeDir, Name, False, Spec, Body);
end;

function ListAvailableProfiles(const HomeDir: string): TProfileSpecArray;
var
  i: Integer;
  B: TBuiltinArray;
  SR: TSearchRec;
  Root, Name, Body: string;
  Spec: TProfileSpec;

  procedure AddSpec(const S: TProfileSpec);
  var
    j: Integer;
  begin
    for j := 0 to High(Result) do
      if SameText(Result[j].Name, S.Name) then
      begin
        { User entries shadow built-ins -- replace, don't dupe. }
        Result[j] := S;
        Exit;
      end;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  SetLength(Result, 0);
  B := Builtins;
  for i := 0 to High(B) do
  begin
    Spec.Name        := B[i].Name;
    Spec.Source      := 'builtin';
    Spec.Description := ExtractDescription(B[i].Body);
    AddSpec(Spec);
  end;

  Root := JoinPath(HomeDir, 'profiles');
  if DirectoryExists(Root) and (FindFirst(JoinPath(Root, '*.json'), faAnyFile, SR) = 0) then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Name := ExtractFileName(SR.Name);
      if Length(Name) > 5 then Delete(Name, Length(Name) - 4, 5);   { strip .json }
      if not IsSafeProfileName(Name) then Continue;
      Body := ReadFileText(JoinPath(Root, SR.Name));
      Spec.Name        := Name;
      Spec.Source      := JoinPath(Root, SR.Name);
      Spec.Description := ExtractDescription(Body);
      AddSpec(Spec);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

(* Recursive resolver. Visited is the cycle-guard; Depth caps inheritance.
   On success, appends one body per ancestor in inheritance order, then
   the current profile's body at the end.

   NameToBypass: when non-empty AND matches Name, the current lookup
   bypasses the user-shadow file and reaches the built-in directly.
   Set by the caller when recursing for an _inherits parent whose name
   matches the current profile's name (Codex P2 on PR #291 -- the
   "fork a built-in" pattern). Empty otherwise. *)
function ResolveInto(const HomeDir, Name, NameToBypass: string;
                    var Bodies: TProfileBodyArray;
                    var Visited: TStringList;
                    Depth: Integer;
                    out ErrMsg: string): Boolean;
var
  Spec: TProfileSpec;
  Body, VisitedKey: string;
  O: TJsonObject;
  Inh: TJsonArray;
  ParentName: string;
  i, VisitedIdx: Integer;
  PoppedSelf: Boolean;
  BypassThisLookup: Boolean;
begin
  Result := False;
  ErrMsg := '';
  PoppedSelf := False;
  if Depth > MaxInheritDepth then
  begin
    ErrMsg := 'profile inheritance over depth cap (' + IntToStr(MaxInheritDepth) +
              ') resolving "' + Name + '"';
    Exit;
  end;
  if Visited.IndexOf(LowerCase(Name)) >= 0 then
  begin
    ErrMsg := 'profile inheritance cycle through "' + Name + '"';
    Exit;
  end;
  Visited.Add(LowerCase(Name));

  BypassThisLookup := (NameToBypass <> '') and SameText(Name, NameToBypass);
  if not LookupProfileInternal(HomeDir, Name, BypassThisLookup, Spec, Body) then
  begin
    ErrMsg := 'profile "' + Name + '" not found';
    Exit;
  end;

  try
    O := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'profile "' + Name + '" parse error: ' + E.Message;
      Exit;
    end;
  end;
  if O = nil then begin ErrMsg := 'profile "' + Name + '" empty / invalid'; Exit; end;
  try
    Inh := O.ChildArray('_inherits');
    if Inh <> nil then
    try
      for i := 0 to Inh.Count - 1 do
      begin
        ParentName := Trim(Inh.ItemStr(i, ''));
        if ParentName = '' then Continue;

        if SameText(ParentName, Name) and (not BypassThisLookup) and
           (Spec.Source <> 'builtin') then
        begin
          (* Self-shadow case (Codex P2): user file
             $PASCLAW_HOME/profiles/<X>.json whose _inherits list
             contains "X". Pop our own name from Visited so the
             recursive call doesn't false-cycle, signal "bypass the
             user-shadow for this one lookup", then re-add (no-op
             via dupIgnore but explicit for readability). *)
          VisitedKey := LowerCase(Name);
          VisitedIdx := Visited.IndexOf(VisitedKey);
          if VisitedIdx >= 0 then
          begin
            Visited.Delete(VisitedIdx);
            PoppedSelf := True;
          end;
          try
            if not ResolveInto(HomeDir, ParentName, Name,
                               Bodies, Visited, Depth + 1, ErrMsg) then Exit;
          finally
            if PoppedSelf then Visited.Add(VisitedKey);
            PoppedSelf := False;
          end;
        end
        else if not ResolveInto(HomeDir, ParentName, '',
                                Bodies, Visited, Depth + 1, ErrMsg) then Exit;
      end;
    finally
      Inh.Free;
    end;
  finally
    O.Free;
  end;

  SetLength(Bodies, Length(Bodies) + 1);
  Bodies[High(Bodies)] := Body;
  Result := True;
end;

function ResolveProfileBodies(const HomeDir, Name: string;
                              out Bodies: TProfileBodyArray;
                              out ErrMsg: string): Boolean;
var
  Visited: TStringList;
begin
  SetLength(Bodies, 0);
  Visited := TStringList.Create;
  Visited.Sorted := True;
  Visited.Duplicates := dupIgnore;
  try
    Result := ResolveInto(HomeDir, Name, '', Bodies, Visited, 0, ErrMsg);
  finally
    Visited.Free;
  end;
end;

function ExtractProfileField(const ConfigJSON: string): string;
var
  O: TJsonObject;
begin
  Result := '';
  if Trim(ConfigJSON) = '' then Exit;
  try
    O := TJsonObject.Parse(ConfigJSON);
  except
    Exit;
  end;
  if O = nil then Exit;
  try
    Result := Trim(O.GetStr('profile', ''));
  finally
    O.Free;
  end;
end;

{ 'workspace' or 'workspaceN' -- the shape PasClaw.Workspaces accepts. }
function LooksLikeWorkspaceName(const S: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if Copy(S, 1, 9) <> 'workspace' then Exit;
  for I := 10 to Length(S) do
    if not (S[I] in ['0'..'9']) then Exit;
  Result := True;
end;

function ExtractWorkspaceProfile(const ConfigJSON: string): string;
var
  O, Map: TJsonObject;
  Name: string;
begin
  Result := '';
  if Trim(ConfigJSON) = '' then Exit;
  Name := Trim(GetEnvironmentVariable('PASCLAW_WORKSPACE'));
  try
    O := TJsonObject.Parse(ConfigJSON);
  except
    Exit;
  end;
  if O = nil then Exit;
  try
    if (Name = '') or not LooksLikeWorkspaceName(Name) then
      Name := Trim(O.GetStr('active_workspace', ''));
    if (Name = '') or not LooksLikeWorkspaceName(Name) then
      Name := 'workspace';
    Map := O.ChildObject('workspace_profiles');
    if Map <> nil then
      Result := Trim(Map.GetStr(Name, ''));
  finally
    O.Free;
  end;
end;

function ResolveProfileName(const ConfigJSON, Override: string): string;
begin
  Result := Trim(Override);
  if Result <> '' then Exit;
  Result := Trim(GetEnvironmentVariable('PASCLAW_PROFILE'));
  if Result <> '' then Exit;
  { Below the explicit selectors, above the global field: the binding is
    the more specific statement about this workspace. }
  Result := ExtractWorkspaceProfile(ConfigJSON);
  if Result <> '' then Exit;
  Result := ExtractProfileField(ConfigJSON);
end;

end.
