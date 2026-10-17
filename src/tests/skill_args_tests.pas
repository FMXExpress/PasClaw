program skill_args_tests;
(*
  Command-style arguments for prompt skills and the slash-command bridge.

    - SplitSkillArgs: whitespace, "double" and 'single' quotes, escapes
    - RenderSkillArguments: $ARGUMENTS, $1 / $2, last $N absorbs the rest,
      missing tokens render '', $0 is the raw string, a template without
      placeholders is untouched
    - RenderTemplate still fills {{key}} and then the arguments string
    - ParseSkillMDText reads agent: / model: / subagent:
    - ResolveSlashSkill matches /name and /Name-With-Dashes, not built-ins
      or shell skills; ExpandSlashSkill appends args to a plain template
    - RegisterSkills gives an argument-taking template a one-string schema
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Skills.Loader,
  PasClaw.Skills.Slash;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Hay); end;

procedure TestSplit;
var
  T: TStringArray;
begin
  T := SplitSkillArgs('staging  now');
  AssertEqInt(Length(T), 2, 'two tokens');
  AssertEqStr(T[0], 'staging', 't0'); AssertEqStr(T[1], 'now', 't1');
  T := SplitSkillArgs('"a b" c ''d e'' f\ g');
  AssertEqInt(Length(T), 4, 'quotes group');
  AssertEqStr(T[0], 'a b', 'double'); AssertEqStr(T[1], 'c', 'bare');
  AssertEqStr(T[2], 'd e', 'single'); AssertEqStr(T[3], 'f g', 'escaped space');
  T := SplitSkillArgs('say "he said \"hi\""');
  AssertEqInt(Length(T), 2, 'escaped quote inside');
  AssertEqStr(T[1], 'he said "hi"', 'escaped quote kept');
  T := SplitSkillArgs('');
  AssertEqInt(Length(T), 0, 'empty');
  T := SplitSkillArgs('""');
  AssertEqInt(Length(T), 1, 'empty quoted token counts');
  AssertEqStr(T[0], '', 'and is empty');
  WriteLn('  ok: SplitSkillArgs');
end;

procedure TestRender;
begin
  AssertEqStr(RenderSkillArguments('Deploy to $ARGUMENTS now', 'staging --fast'),
              'Deploy to staging --fast now', '$ARGUMENTS');
  AssertEqStr(RenderSkillArguments('env=$1 flags=$2', 'staging --fast --quiet'),
              'env=staging flags=--fast --quiet', 'last absorbs rest');
  AssertEqStr(RenderSkillArguments('a=$1 b=$2 c=$3', 'x y z w'),
              'a=x b=y c=z w', 'highest N absorbs');
  AssertEqStr(RenderSkillArguments('a=$1 b=$2', 'only'),
              'a=only b=', 'missing token -> empty');
  AssertEqStr(RenderSkillArguments('raw=$0', 'p q'), 'raw=p q', '$0 raw');
  AssertEqStr(RenderSkillArguments('no placeholders', 'x'), 'no placeholders', 'untouched');
  AssertEqStr(RenderSkillArguments('cost $5 is not an arg', ''), 'cost  is not an arg',
              '$5 with no args renders empty (documented: use a JSON key for literal dollars)');
  AssertTrue(TemplateUsesArguments('x $1'), 'uses $1');
  AssertTrue(TemplateUsesArguments('x $ARGUMENTS'), 'uses $ARGUMENTS');
  AssertTrue(not TemplateUsesArguments('x {' + '{y}' + '}'), 'braces are not arguments');
  (* RenderTemplate: JSON-key placeholders first, then the arguments string *)
  AssertEqStr(RenderTemplate('Hi {{name}}, do $1 and $2', '{"name":"Eli","arguments":"this \"that thing\""}'),
              'Hi Eli, do this and that thing', 'both substitutions');
  AssertEqStr(RenderTemplate('plain {{k}}', '{"k":"v"}'), 'plain v', 'no arguments key is fine');
  WriteLn('  ok: RenderSkillArguments / RenderTemplate');
end;

const
  SkillDeploy =
    '---' + sLineBreak +
    'name: deploy' + sLineBreak +
    'description: Deploy an environment' + sLineBreak +
    'kind: prompt' + sLineBreak +
    'prompt: Deploy $1 with flags $2' + sLineBreak +
    'agent: ops' + sLineBreak +
    'model: small-1' + sLineBreak +
    'subagent: true' + sLineBreak +
    '---' + sLineBreak +
    'body';
  SkillReview =
    '---' + sLineBreak +
    'name: code_review' + sLineBreak +
    'description: Review code' + sLineBreak +
    'kind: prompt' + sLineBreak +
    '---' + sLineBreak +
    'Review the following carefully.';
  SkillShell =
    '---' + sLineBreak +
    'name: ls' + sLineBreak +
    'description: list' + sLineBreak +
    'kind: shell' + sLineBreak +
    'shell: ls $1' + sLineBreak +
    '---' + sLineBreak;

procedure TestFrontmatterAndSlash;
var
  Skills: TSkillSpecArray;
  S: TSkillSpec;
  Err, Args: string;
  Reg: TToolRegistry;
  T: TTool;
begin
  SetLength(Skills, 3);
  AssertTrue(ParseSkillMDText(SkillDeploy, '/x/deploy/SKILL.md', Skills[0], Err), 'parse deploy: ' + Err);
  AssertTrue(ParseSkillMDText(SkillReview, '/x/review/SKILL.md', Skills[1], Err), 'parse review: ' + Err);
  AssertTrue(ParseSkillMDText(SkillShell, '/x/ls/SKILL.md', Skills[2], Err), 'parse ls: ' + Err);
  AssertEqStr(Skills[0].Agent, 'ops', 'agent:');
  AssertEqStr(Skills[0].Model, 'small-1', 'model:');
  AssertTrue(Skills[0].Subagent, 'subagent:');
  AssertTrue(not Skills[1].Subagent, 'default not subagent');

  AssertTrue(ResolveSlashSkill('/deploy staging --fast', Skills, S, Args), 'resolves /deploy');
  AssertEqStr(S.Name, 'deploy', 'spec');
  AssertEqStr(Args, 'staging --fast', 'args');
  AssertEqStr(ExpandSlashSkill(S, Args), 'Deploy staging with flags --fast', 'expanded');
  AssertTrue(ResolveSlashSkill('/Code-Review src/a.pas', Skills, S, Args), 'dash/underscore/case-insensitive');
  AssertEqStr(S.Name, 'code_review', 'spec 2');
  AssertEqStr(ExpandSlashSkill(S, Args), 'Review the following carefully.' + sLineBreak + sLineBreak + 'src/a.pas',
              'plain template gets the args appended');
  AssertTrue(ResolveSlashSkill('/deploy', Skills, S, Args), 'no args');
  AssertEqStr(Args, '', 'empty args');
  AssertTrue(not ResolveSlashSkill('/ls .', Skills, S, Args), 'shell skills are not slash commands');
  AssertTrue(not ResolveSlashSkill('/help', Skills, S, Args), 'unknown stays unknown');
  AssertTrue(not ResolveSlashSkill('deploy x', Skills, S, Args), 'needs the slash');
  AssertContains(SlashSkillHelp(Skills), '/deploy <args>', 'help lists args-taking skill');
  AssertContains(SlashSkillHelp(Skills), '[agent ops]', 'help shows agent');
  Skills[1].Agent := 'rev';
  AssertContains(StringReplace(SlashSkillSpawnArgs(Skills[1], 'p'), ' ', '', [rfReplaceAll]),
                 '"agent":"rev"', 'spawn args');

  { Registration: deploy takes arguments -> one-string schema; review (no
    placeholders) keeps the bare object schema. }
  Reg := TToolRegistry.Create;
  try
    RegisterSkills(Reg, Skills);
    AssertTrue(Reg.Find('skill_deploy', T), 'deploy registered');
    AssertContains(T.Schema, '"arguments"', 'argument schema');
    AssertTrue(Reg.Find('skill_code_review', T), 'review registered');
    AssertTrue(Pos('"arguments"', T.Schema) = 0, 'no args -> plain schema');
    AssertEqStr(Reg.RunTool('skill_deploy', '{"arguments":"prod \"--dry run\""}', Err),
                'Deploy prod with flags --dry run', 'tool call with arguments');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: frontmatter, slash resolution, expansion, registration schema');
end;

begin
  TestSplit;
  TestRender;
  TestFrontmatterAndSlash;
  WriteLn('PASS');
end.
