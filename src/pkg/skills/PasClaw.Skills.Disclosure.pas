(*
  PasClaw.Skills.Disclosure - progressive-disclosure tools for skills.

  Hermes-style "Level 0 / Level 1" skill access: instead of inlining
  every skill's name + description into the system prompt on every turn
  (which BuildSkillsSection does by default), advertise two tools and let
  the model pull what it needs:

    skills_list()        -> [{name, description, kind, source}, ...]
                            Cheap metadata index (Level 0).
    skills_view(name)     -> the full SKILL.md body (Level 1).
    skills_view(name,path)-> a specific auxiliary file under the skill
                            directory, e.g. references/api.md (Level 2).

  Both tools are read-only (tcReadOnly) and self-gate: RegisterSkill-
  DisclosureTools is a no-op unless Cfg.SelfImprovingSkills.Progressive-
  Disclosure is True. When it IS on, PasClaw.Agent.Prompt swaps the full
  SKILLS catalog for a short "use skills_list / skills_view" pointer so the
  prompt stays small as a deployment accrues many skills.

  Naming: the prefix is `skills_` (PLURAL) so these tools sit in a
  separate namespace from user-installed callable skills, which register
  as `skill_<name>` (SINGULAR). Without that distinction, a user skill
  named `view` would collide with the disclosure tool and get silently
  shadowed -- Codex P2 on PR #288. skills_manage in PasClaw.Skills.Manage
  follows the same convention.

  skills_view confines reads to the skill's own directory: a `path` arg
  with '..' or an absolute path is rejected, so this can't be turned into
  a general file-read primitive that sidesteps the fs sandbox.
*)
unit PasClaw.Skills.Disclosure;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Registry;

procedure RegisterSkillDisclosureTools(Reg: TToolRegistry; const Cfg: TConfig);

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Tools.Types,
  PasClaw.Skills.Loader;

var
  GHomeDir: string = '';

function SkillsListHandler(const ArgsJSON: string; out ErrMsg: string): string;
var
  Skills: TSkillSpecArray;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  ErrMsg := '';
  Skills := LoadSkillManifests(GHomeDir);
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(Skills) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('name',        Skills[i].Name);
      Item.PutStr('description', Skills[i].Description);
      Item.PutStr('kind',        Skills[i].Kind);
      Item.PutStr('source',      Skills[i].Source);
      Arr.AddObject(Item);
    end;
    Root.PutArray('skills', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

(* Reject a path that would escape the skill directory: absolute paths,
   drive letters, and any '..' segment. Only relative paths into the
   skill's own subtree are allowed. *)
function IsSafeRelPath(const P: string): Boolean;
begin
  Result := False;
  if P = '' then Exit;
  if (P[1] = '/') or (P[1] = '\') then Exit;            { absolute }
  if (Length(P) >= 2) and (P[2] = ':') then Exit;        { drive letter }
  if Pos('..', P) > 0 then Exit;                         { traversal }
  Result := True;
end;

function SkillViewHandler(const ArgsJSON: string; out ErrMsg: string): string;
var
  O: TJsonObject;
  Name, Sub, Dir, Target: string;
  Skills: TSkillSpecArray;
  i, Found: Integer;
begin
  ErrMsg := '';
  Result := '';
  O := TJsonObject.Parse(ArgsJSON);
  if O = nil then begin ErrMsg := 'invalid JSON arguments'; Exit; end;
  try
    Name := Trim(O.GetStr('name', ''));
    Sub  := Trim(O.GetStr('path', ''));
  finally
    O.Free;
  end;
  if Name = '' then begin ErrMsg := 'skills_view requires `name`'; Exit; end;

  Skills := LoadSkillManifests(GHomeDir);
  Found := -1;
  for i := 0 to High(Skills) do
    if SameText(Skills[i].Name, Name) then begin Found := i; Break; end;
  if Found < 0 then begin ErrMsg := 'no skill named "' + Name + '"'; Exit; end;

  Dir := Skills[Found].Dir;
  if Sub = '' then
  begin
    { Whole SKILL.md (or, for legacy JSON skills, the parsed body). }
    if Skills[Found].Source <> '' then
      Result := ReadFileText(Skills[Found].Source)
    else
      Result := Skills[Found].Body;
    if Result = '' then Result := Skills[Found].Body;
    Exit;
  end;

  if not IsSafeRelPath(Sub) then
  begin
    ErrMsg := 'refused: path must be relative and inside the skill directory';
    Exit;
  end;
  Target := JoinPath(Dir, Sub);
  if not FileExists(Target) then
  begin
    ErrMsg := 'no such file under skill "' + Name + '": ' + Sub;
    Exit;
  end;
  Result := ReadFileText(Target);
end;

const
  SkillsListSchema = '{"type":"object","properties":{}}';
  SkillsListDesc =
    'List installed skills as a metadata index (name, description, kind, ' +
    'source path). Cheap -- call this first, then skills_view(name) to load ' +
    'the full instructions for the one you need.';

  SkillViewSchema =
    '{"type":"object","properties":{' +
    '"name":{"type":"string","description":"skill name from skills_list"},' +
    '"path":{"type":"string","description":"optional file under the skill dir, e.g. references/api.md"}' +
    '},"required":["name"]}';
  SkillViewDesc =
    'Read a skill''s full SKILL.md (or a specific reference file under its ' +
    'directory via the optional path arg). Use after skills_list to load ' +
    'the procedure for the matching task.';

procedure RegisterSkillDisclosureTools(Reg: TToolRegistry; const Cfg: TConfig);
var
  T: TTool;
begin
  if Reg = nil then Exit;
  if not Cfg.SelfImprovingSkills.ProgressiveDisclosure then Exit;

  GHomeDir := GetHome;

  T.Name := 'skills_list';   T.Description := SkillsListDesc;
  T.Schema := SkillsListSchema; T.Handler := SkillsListHandler;
  T.HandlerObj := nil; T.IsCore := False; T.Category := tcReadOnly;
  Reg.Register(T);

  T.Name := 'skills_view';    T.Description := SkillViewDesc;
  T.Schema := SkillViewSchema; T.Handler := SkillViewHandler;
  T.HandlerObj := nil; T.IsCore := False; T.Category := tcReadOnly;
  Reg.Register(T);

  LogInfo('skills: progressive-disclosure tools registered (skills_list, skills_view)');
end;

end.
