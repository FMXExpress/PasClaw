(*
  PasClaw.Skills.Slash -- prompt skills as slash commands.

  A prompt skill is a template the model can call as a tool. Typed by the
  operator it is a command: `/deploy staging` should run the deploy
  template with "staging" in it, not go to the model as the literal
  text "/deploy staging". The CLI REPL and both TUI builds ask this unit
  first; a line that names an installed prompt skill is expanded, and
  the skill's frontmatter says where the result runs (agent / model /
  subagent -- see TSkillSpec). Built-in slash commands keep winning: the
  surfaces check their own list before calling ResolveSlashSkill, so a
  skill named "help" cannot shadow /help.

  Name matching is case-insensitive and treats '-' and '_' alike, so
  /code-review and /code_review both reach a skill named code_review.
*)
unit PasClaw.Skills.Slash;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Skills.Loader;

{ "/name rest of line" against the installed prompt skills. True with the
  spec and the raw argument string (may be '') when Line names one. }
function ResolveSlashSkill(const Line: string; const Skills: TSkillSpecArray;
                           out Spec: TSkillSpec; out Arguments: string): Boolean;

{ The user message a matched slash skill becomes: the template (Prompt,
  else the markdown Body) with $ARGUMENTS / $1.. filled in. }
function ExpandSlashSkill(const Spec: TSkillSpec; const Arguments: string): string;

{ One line per prompt skill for /help: "/name  description". '' when none. }
function SlashSkillHelp(const Skills: TSkillSpecArray): string;

{ The JSON the spawn tool takes for a skill with agent: set. }
function SlashSkillSpawnArgs(const Spec: TSkillSpec; const Prompt: string): string;

implementation

uses
  PasClaw.JSON;

function Canon(const S: string): string;
begin
  Result := LowerCase(StringReplace(Trim(S), '-', '_', [rfReplaceAll]));
end;

function ResolveSlashSkill(const Line: string; const Skills: TSkillSpecArray;
                           out Spec: TSkillSpec; out Arguments: string): Boolean;
var
  L, Name: string;
  p, i: Integer;
begin
  Result := False;
  Arguments := '';
  Spec := Default(TSkillSpec);
  L := Trim(Line);
  if (Length(L) < 2) or (L[1] <> '/') then Exit;
  p := Pos(' ', L);
  if p = 0 then
  begin
    Name := Copy(L, 2, MaxInt);
    Arguments := '';
  end
  else
  begin
    Name := Copy(L, 2, p - 2);
    Arguments := Trim(Copy(L, p + 1, MaxInt));
  end;
  Name := Canon(Name);
  if Name = '' then Exit;
  for i := 0 to High(Skills) do
    if (LowerCase(Trim(Skills[i].Kind)) = 'prompt') and (Canon(Skills[i].Name) = Name) then
    begin
      Spec := Skills[i];
      Exit(True);
    end;
end;

function ExpandSlashSkill(const Spec: TSkillSpec; const Arguments: string): string;
var
  T: string;
begin
  T := Spec.Prompt;
  if Trim(T) = '' then T := Spec.Body;
  Result := RenderSkillArguments(T, Arguments);
  { A template with no placeholder still gets the arguments: appended,
    so "/review src/x.pas" on a plain template is not silently lossy. }
  if (Arguments <> '') and (not TemplateUsesArguments(T)) then
    Result := Result + sLineBreak + sLineBreak + Arguments;
end;

function SlashSkillHelp(const Skills: TSkillSpecArray): string;
var
  i: Integer;
  Where: string;
begin
  Result := '';
  for i := 0 to High(Skills) do
    if LowerCase(Trim(Skills[i].Kind)) = 'prompt' then
    begin
      Where := '';
      if Skills[i].Agent <> '' then Where := ' [agent ' + Skills[i].Agent + ']'
      else if Skills[i].Subagent then Where := ' [child session]';
      if Skills[i].Model <> '' then Where := Where + ' [model ' + Skills[i].Model + ']';
      Result := Result + '  /' + Skills[i].Name;
      if TemplateUsesArguments(Skills[i].Prompt + Skills[i].Body) then Result := Result + ' <args>';
      Result := Result + '  ' + Skills[i].Description + Where + sLineBreak;
    end;
  Result := TrimRight(Result);
end;

function SlashSkillSpawnArgs(const Spec: TSkillSpec; const Prompt: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('agent', Spec.Agent);
    Obj.PutStr('prompt', Prompt);
    if Spec.Model <> '' then Obj.PutStr('model', Spec.Model);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

end.
