program skills_prompt_tests;
(*
  Pins the skill-authoring primer in the system prompt's Skills section.

  The bug this guards: on a default install (NO skills), BuildSkillsSection
  used to emit nothing, so the agent had zero in-context notion of what a
  skill is or how to author one -- "build me a skill" sent it grepping the
  codebase. The primer must render in BOTH states:
    - zero skills   -> a "## Skills / No skills are installed yet / how to
                       author" block, so the format is always teachable;
    - skills present -> the catalog PLUS the primer appended, so "create
                       another one" still has the format in context.

  Both cases build a real prompt via BuildSystemPrompt against a clean,
  isolated PASCLAW_HOME.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Tools.Sandbox,
  PasClaw.Agent.Prompt;

var
  Failures: Integer = 0;

procedure WriteFileText(const Path, Content: string);
var S: TStringList;
begin
  S := TStringList.Create;
  try
    S.Text := Content;
    S.SaveToFile(Path);
  finally
    S.Free;
  end;
end;

procedure Contains(const Hay, Needle, Why: string);
begin
  if Pos(Needle, Hay) <= 0 then
  begin
    WriteLn('FAIL [', Why, ']: missing "', Needle, '"');
    Inc(Failures);
  end;
end;

procedure NotContains(const Hay, Needle, Why: string);
begin
  if Pos(Needle, Hay) > 0 then
  begin
    WriteLn('FAIL [', Why, ']: unexpected "', Needle, '"');
    Inc(Failures);
  end;
end;

function PromptNow: string;
var Cfg: TConfig;
begin
  Cfg := LoadConfig;
  try
    Result := BuildSystemPrompt(Cfg, '', {ToolsEnabled=} True, '');
  finally
    Cfg.Free;
  end;
end;

procedure TestZeroSkillsTeachesFormat;
var P: string;
begin
  P := PromptNow;
  Contains(P, '## Skills',                              'zero: section header present');
  Contains(P, 'No skills are installed yet.',           'zero: honest empty state');
  Contains(P, 'Authoring a skill',                      'zero: authoring primer present');
  Contains(P, 'SKILL.md',                               'zero: names the file format');
  Contains(P, 'write_file',                             'zero: points at write_file, not skills_manage');
  Contains(P, 'docs/skills.md',                         'zero: points at the full reference');
end;

procedure TestSkillPresentStillTeachesFormat(const Home: string);
var P, Dir: string;
begin
  { Drop one knowledge-only skill and confirm the catalog AND the primer render. }
  Dir := JoinPath(JoinPath(JoinPath(Home, 'workspace'), 'skills'), 'demo_skill');
  ForceDirectories(Dir);
  WriteFileText(JoinPath(Dir, 'SKILL.md'),
    '---'#10'name: demo_skill'#10'description: a demo skill for the prompt test'#10'---'#10#10'# Demo'#10'body'#10);

  P := PromptNow;
  Contains(P, 'demo_skill',        'present: catalog lists the installed skill');
  Contains(P, 'Authoring a skill', 'present: primer still appended alongside the catalog');
end;

procedure TestRestrictedSandboxSwitchesAdvice(const Home: string);
{ Codex #440 P2: when restrict_to_workspace pins writes to a project dir that
  the skills dir is outside of, write_file to the skills dir is refused -- so
  the primer must NOT advertise it. Point at skills_manage / allow_write_paths
  instead. Runs LAST because it mutates the process-global sandbox policy. }
var
  Cfg: TConfig;
  Pol: TSandboxPolicy;
  Elsewhere, P: string;
begin
  Elsewhere := JoinPath(GetTempDir, 'pasclaw-restrict-' + IntToStr(GetProcessID));
  ForceDirectories(Elsewhere);
  Cfg := LoadConfig;
  try
    Pol := Cfg.Sandbox;
    Pol.RestrictToWorkspace := True;              { pin writes... }
    ConfigureSandbox(Pol, Elsewhere);             { ...to a dir the skills dir is NOT under }
  finally
    Cfg.Free;
  end;

  P := PromptNow;
  Contains(P, 'skills_manage',                    'restricted: routes to skills_manage');
  Contains(P, 'allow_write_paths',                'restricted: offers the allowlist path');
  Contains(P, 'refused',                          'restricted: warns write_file is refused');
  { The writable-branch-only phrasing must be gone so the model is not told to
    just write_file into a dir where that call fails. }
  NotContains(P, 'this is the entire format',     'restricted: drops the plain write_file advice');
end;

var
  Home: string;
begin
  { PASCLAW_HOME is set to a clean, per-run temp dir by the make target, so no
    ambient skills leak into the zero-skills assertion. }
  Home := GetHome;
  ForceDirectories(JoinPath(Home, 'workspace'));

  TestZeroSkillsTeachesFormat;
  TestSkillPresentStillTeachesFormat(Home);
  TestRestrictedSandboxSwitchesAdvice(Home);

  if Failures = 0 then
    WriteLn('skills_prompt_tests: OK')
  else
  begin
    WriteLn('skills_prompt_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
