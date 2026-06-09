(*
  PasClaw.Skills.Loader - skill manifest loader and runner.

  Two on-disk layouts are accepted, scanned from $PASCLAW_HOME/workspace/skills:

  1. Per-directory SKILL.md (preferred; matches picoclaw / nanobot /
     Anthropic agent-skills format):

       workspace/skills/<name>/SKILL.md
                         /scripts/    (optional, Phase 4)
                         /references/ (optional, Phase 4)
                         /assets/     (optional, Phase 4)

     SKILL.md is YAML frontmatter + markdown body:

       ---
       name: weather_report
       description: Fetch weather for a city
       kind: shell
       shell: curl -s 'https://wttr.in/{{city}}?format=3'
       schema: {"type":"object","properties":{"city":{"type":"string"}}}
       ---

       # Weather report

       Procedural knowledge the model loads on demand via fs_read.

  2. Legacy single-JSON file (still loaded for backwards compat):

       workspace/skills/<name>.json

     Same field set as the frontmatter above, no body. New skills should
     use the directory layout; the JSON path will stay until existing
     deployments have migrated.

  Skill kinds:

    shell   - Renders Shell as a {{var}} template, runs through
              PasClaw.Platform.RunOneShot, returns combined stdout/stderr.
              Registered as `skill_<name>` in the tool registry.
    prompt  - Renders Prompt as a {{var}} template, returns the
              substituted string verbatim. Registered as `skill_<name>`.
              Useful when a skill is just a frequently reused prompt
              fragment.
    (empty) - Pure-knowledge skill. No tool is registered; the SKILL.md
              body is advertised in the system prompt's SKILLS section
              so the model knows to fs_read it for procedural context.
              This is the dominant pattern picoclaw and nanobot ship.

  A skill registers as a `skill_<name>` tool in the registry once loaded
  (kinds `shell` and `prompt` only; pure-knowledge skills do not get a
  tool entry).
*)
unit PasClaw.Skills.Loader;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

type
  TSkillSpec = record
    Name:        string;
    Description: string;
    Kind:        string;   { "shell" | "prompt" | "" (knowledge-only) }
    Schema:      string;
    Shell:       string;
    Prompt:      string;
    Body:        string;   { markdown body after YAML frontmatter, if any }
    Dir:         string;   { absolute path to the skill's directory (SKILL.md
                             layout) or the file's directory (.json layout) }
    Source:      string;   { absolute path to SKILL.md or the .json file --
                             used by the system prompt so the model can
                             fs_read for the full body }
  end;

  TSkillSpecArray = array of TSkillSpec;

function LoadSkillManifests(const HomeDir: string): TSkillSpecArray;
procedure RegisterSkills(Reg: TToolRegistry; const Skills: TSkillSpecArray);
function RunSkill(Reg: TToolRegistry; const Name, ArgsJSON: string; out ErrMsg: string): string;
function RenderTemplate(const Template, ArgsJSON: string): string;

{ Parse a SKILL.md file into a TSkillSpec. Returns False with ErrMsg set
  on a malformed file (no frontmatter, missing `name:`, etc). Exposed for
  testing and for future hub-side validation; LoadSkillManifests is the
  normal entry point. }
function ParseSkillMD(const FilePath: string;
                      out Spec: TSkillSpec;
                      out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Platform;

const
  MaxSkills = 64;

var
  GSpecs: array[0..MaxSkills - 1] of TSkillSpec;
  GUsed: array[0..MaxSkills - 1] of Boolean;

function AllocSlot: Integer;
var
  i: Integer;
begin
  for i := 0 to High(GUsed) do
    if not GUsed[i] then Exit(i);
  Result := -1;
end;

(* Forward-declared handlers -- one per slot. Same approach as MCP bridge. *)
function H_0  (const A: string; out E: string): string; forward;
function H_1  (const A: string; out E: string): string; forward;
function H_2  (const A: string; out E: string): string; forward;
function H_3  (const A: string; out E: string): string; forward;
function H_4  (const A: string; out E: string): string; forward;
function H_5  (const A: string; out E: string): string; forward;
function H_6  (const A: string; out E: string): string; forward;
function H_7  (const A: string; out E: string): string; forward;
function H_8  (const A: string; out E: string): string; forward;
function H_9  (const A: string; out E: string): string; forward;
function H_10 (const A: string; out E: string): string; forward;
function H_11 (const A: string; out E: string): string; forward;
function H_12 (const A: string; out E: string): string; forward;
function H_13 (const A: string; out E: string): string; forward;
function H_14 (const A: string; out E: string): string; forward;
function H_15 (const A: string; out E: string): string; forward;

function RunShellSkill(Slot: Integer; const ArgsJSON: string; out ErrMsg: string): string; forward;

function H_0  (const A: string; out E: string): string; begin Result := RunShellSkill(0,  A, E); end;
function H_1  (const A: string; out E: string): string; begin Result := RunShellSkill(1,  A, E); end;
function H_2  (const A: string; out E: string): string; begin Result := RunShellSkill(2,  A, E); end;
function H_3  (const A: string; out E: string): string; begin Result := RunShellSkill(3,  A, E); end;
function H_4  (const A: string; out E: string): string; begin Result := RunShellSkill(4,  A, E); end;
function H_5  (const A: string; out E: string): string; begin Result := RunShellSkill(5,  A, E); end;
function H_6  (const A: string; out E: string): string; begin Result := RunShellSkill(6,  A, E); end;
function H_7  (const A: string; out E: string): string; begin Result := RunShellSkill(7,  A, E); end;
function H_8  (const A: string; out E: string): string; begin Result := RunShellSkill(8,  A, E); end;
function H_9  (const A: string; out E: string): string; begin Result := RunShellSkill(9,  A, E); end;
function H_10 (const A: string; out E: string): string; begin Result := RunShellSkill(10, A, E); end;
function H_11 (const A: string; out E: string): string; begin Result := RunShellSkill(11, A, E); end;
function H_12 (const A: string; out E: string): string; begin Result := RunShellSkill(12, A, E); end;
function H_13 (const A: string; out E: string): string; begin Result := RunShellSkill(13, A, E); end;
function H_14 (const A: string; out E: string): string; begin Result := RunShellSkill(14, A, E); end;
function H_15 (const A: string; out E: string): string; begin Result := RunShellSkill(15, A, E); end;

{ Delphi rejects @FunctionName as a constant expression in typed-constant
  array initializers; populate the first 16 slots in the initialization
  section below. Slots 16..63 stay nil -- RunShellSkill guards against that. }
var
  SkillHandlers: array[0..MaxSkills - 1] of TToolHandler;

function RenderTemplate(const Template, ArgsJSON: string): string;
var
  Obj: TJsonObject;
  Out_: string;
  i: Integer;
  Token, Key, Value: string;
  InToken: Boolean;
begin
  Result := Template;
  if (Template = '') or (ArgsJSON = '') then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then Exit;
  try
    Out_ := '';
    Token := '';
    InToken := False;
    i := 1;
    while i <= Length(Template) do
    begin
      if (not InToken) and (i < Length(Template)) and
         (Template[i] = '{') and (Template[i + 1] = '{') then
      begin
        InToken := True;
        Token := '';
        Inc(i, 2);
        Continue;
      end;
      if InToken and (i < Length(Template)) and
         (Template[i] = '}') and (Template[i + 1] = '}') then
      begin
        Key := Trim(Token);
        Value := Obj.GetStr(Key, '');
        Out_ := Out_ + Value;
        InToken := False;
        Inc(i, 2);
        Continue;
      end;
      if InToken then Token := Token + Template[i]
      else Out_ := Out_ + Template[i];
      Inc(i);
    end;
    Result := Out_;
  finally
    Obj.Free;
  end;
end;

function RunShell(const Cmd: string; out ExitCode: Integer): string;
begin
  ExitCode := RunOneShot(Cmd, Result);
end;

function RunShellSkill(Slot: Integer; const ArgsJSON: string; out ErrMsg: string): string;
var
  Spec: TSkillSpec;
  Cmd: string;
  ExitCode: Integer;
begin
  ErrMsg := '';
  if (Slot < 0) or (Slot >= MaxSkills) or (not GUsed[Slot]) then
  begin
    ErrMsg := 'stale skill slot';
    Exit('');
  end;
  Spec := GSpecs[Slot];
  if Spec.Kind = 'prompt' then
  begin
    Result := RenderTemplate(Spec.Prompt, ArgsJSON);
    Exit;
  end;
  Cmd := RenderTemplate(Spec.Shell, ArgsJSON);
  if Cmd = '' then
  begin
    ErrMsg := 'empty shell template after rendering';
    Exit('');
  end;
  LogDebug('skill[%s]: %s', [Spec.Name, Copy(Cmd, 1, 200)]);
  Result := RunShell(Cmd, ExitCode);
  if ExitCode <> 0 then
    ErrMsg := Format('skill exit=%d', [ExitCode]);
end;

function LoadJsonSkill(const Path: string; out Spec: TSkillSpec): Boolean;
var
  Body: string;
  Obj, Schema: TJsonObject;
begin
  Result := False;
  Body := ReadFileText(Path);
  if Body = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Spec.Name        := Obj.GetStr('name',        '');
    Spec.Description := Obj.GetStr('description', '');
    Spec.Kind        := Obj.GetStr('type',        'shell');
    Spec.Shell       := Obj.GetStr('shell',       '');
    Spec.Prompt      := Obj.GetStr('prompt',      '');
    Spec.Body        := '';
    Spec.Dir         := ExtractFileDir(Path);
    Spec.Source      := Path;
    Schema := Obj.ChildObject('schema');
    if Schema <> nil then
    begin
      Spec.Schema := Schema.ToJSON;
      Schema.Free;
    end
    else
      Spec.Schema := '{"type":"object"}';
    Result := Spec.Name <> '';
  finally
    Obj.Free;
  end;
end;

(* Split a line at the first ':' and return (key, value) with both sides
   trimmed. Strips surrounding single or double quotes from value if
   present -- common in YAML for values that contain colons or other
   metacharacters. Returns False if there is no ':' on the line. *)
function SplitYAMLEntry(const Line: string; out Key, Value: string): Boolean;
var
  P: Integer;
begin
  Result := False;
  P := Pos(':', Line);
  if P <= 0 then Exit;
  Key   := Trim(Copy(Line, 1, P - 1));
  Value := Trim(Copy(Line, P + 1, MaxInt));
  if (Length(Value) >= 2) and
     ( ((Value[1] = '"')  and (Value[Length(Value)] = '"'))  or
       ((Value[1] = '''') and (Value[Length(Value)] = '''')) ) then
    Value := Copy(Value, 2, Length(Value) - 2);
  Result := Key <> '';
end;

function ParseSkillMD(const FilePath: string; out Spec: TSkillSpec;
                      out ErrMsg: string): Boolean;
var
  Text, Line, Key, Value: string;
  Lines: TStringList;
  i, StartIdx, EndIdx: Integer;
  Body: TStringList;
  InFrontmatter: Boolean;
begin
  Result := False;
  ErrMsg := '';
  if not FileExists(FilePath) then begin ErrMsg := 'no such file'; Exit; end;
  Text := ReadFileText(FilePath);
  if Text = '' then begin ErrMsg := 'empty file'; Exit; end;

  Lines := TStringList.Create;
  Body  := TStringList.Create;
  try
    Lines.Text := Text;

    (* Locate the frontmatter block. The first non-empty line must be `---`;
       the closing `---` marks the end. We allow leading blank lines to
       tolerate editors that prepend stray whitespace, and explicitly
       strip a UTF-8 BOM at the start of the first line -- Trim only
       handles ASCII whitespace, so a SKILL.md saved by a Windows editor
       with BOM would otherwise be rejected here with `no YAML
       frontmatter`. ReadFileText returns AnsiString-UTF8 under FPC and
       UnicodeString under Delphi, so the BOM lives as different
       sequences on each toolchain:

         FPC AnsiString  : three bytes EF BB BF at positions 1..3
         Delphi UnicodeString : one Char #$FEFF at position 1
                                (TEncoding.UTF8.GetString decodes the
                                 three UTF-8 bytes to that codepoint,
                                 it does not silently strip them).

       Handle both. *)
    StartIdx := -1;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if i = 0 then
      begin
        {$IFDEF FPC}
        if (Length(Line) >= 3) and
           (Byte(Line[1]) = $EF) and (Byte(Line[2]) = $BB) and (Byte(Line[3]) = $BF) then
          Line := Copy(Line, 4, MaxInt);
        {$ELSE}
        if (Length(Line) >= 1) and (Line[1] = #$FEFF) then
          Line := Copy(Line, 2, MaxInt);
        {$ENDIF}
      end;
      Line := Trim(Line);
      if Line = '' then Continue;
      if Line = '---' then begin StartIdx := i; Break; end;
      Break;
    end;
    if StartIdx < 0 then
    begin
      ErrMsg := 'no YAML frontmatter (expected leading `---`)';
      Exit;
    end;

    EndIdx := -1;
    for i := StartIdx + 1 to Lines.Count - 1 do
      if Trim(Lines[i]) = '---' then begin EndIdx := i; Break; end;
    if EndIdx < 0 then
    begin
      ErrMsg := 'unterminated YAML frontmatter (missing closing `---`)';
      Exit;
    end;

    Spec.Name        := '';
    Spec.Description := '';
    Spec.Kind        := '';
    Spec.Schema      := '{"type":"object"}';
    Spec.Shell       := '';
    Spec.Prompt      := '';
    Spec.Dir         := ExtractFileDir(FilePath);
    Spec.Source      := FilePath;

    InFrontmatter := True;
    for i := StartIdx + 1 to EndIdx - 1 do
    begin
      if not InFrontmatter then Break;
      Line := Lines[i];
      if Trim(Line) = '' then Continue;
      if not SplitYAMLEntry(Line, Key, Value) then Continue;
      Key := LowerCase(Key);
      if      Key = 'name'        then Spec.Name        := Value
      else if Key = 'description' then Spec.Description := Value
      else if (Key = 'kind') or (Key = 'type') then Spec.Kind := Value
      else if Key = 'shell'       then Spec.Shell       := Value
      else if Key = 'prompt'      then Spec.Prompt      := Value
      else if Key = 'schema'      then
      begin
        if Value <> '' then Spec.Schema := Value;
      end;
    end;

    Body.Clear;
    for i := EndIdx + 1 to Lines.Count - 1 do
      Body.Add(Lines[i]);
    Spec.Body := Trim(Body.Text);

    if Spec.Name = '' then
    begin
      ErrMsg := 'missing required frontmatter field `name`';
      Exit;
    end;

    Result := True;
  finally
    Body.Free;
    Lines.Free;
  end;
end;

function HasSpec(const Arr: TSkillSpecArray; const Name: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Arr) do
    if SameText(Arr[i].Name, Name) then Exit(True);
  Result := False;
end;

function FindSpecSource(const Arr: TSkillSpecArray; const Name: string): string;
var
  i: Integer;
begin
  Result := '(unknown)';
  for i := 0 to High(Arr) do
    if SameText(Arr[i].Name, Name) then Exit(Arr[i].Source);
end;

procedure ScanSkillDirs(const Root: string; var Out_: TSkillSpecArray);
var
  SR: TSearchRec;
  SkillDir, MDPath, Err: string;
  Spec: TSkillSpec;
begin
  if FindFirst(JoinPath(Root, '*'), faDirectory, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then Continue;
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      SkillDir := JoinPath(Root, SR.Name);
      MDPath   := JoinPath(SkillDir, 'SKILL.md');
      if not FileExists(MDPath) then Continue;
      if ParseSkillMD(MDPath, Spec, Err) then
      begin
        if HasSpec(Out_, Spec.Name) then
        begin
          LogWarn('skills: duplicate name "%s" (already loaded from %s); ' +
                  'ignoring %s', [Spec.Name, FindSpecSource(Out_, Spec.Name), MDPath]);
          Continue;
        end;
        SetLength(Out_, Length(Out_) + 1);
        Out_[High(Out_)] := Spec;
      end
      else
        LogWarn('skills: %s: %s', [MDPath, Err]);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure ScanJsonSkills(const Root: string; var Out_: TSkillSpecArray);
var
  SR: TSearchRec;
  Path: string;
  Spec: TSkillSpec;
begin
  if FindFirst(JoinPath(Root, '*.json'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Path := JoinPath(Root, SR.Name);
      if not LoadJsonSkill(Path, Spec) then Continue;
      { Per-directory SKILL.md wins when names collide. Keeps the migration
        path safe: a user can drop a SKILL.md next to an existing JSON,
        verify it loads, then delete the JSON when ready. }
      if HasSpec(Out_, Spec.Name) then
      begin
        LogDebug('skills: %s.json shadowed by SKILL.md entry', [Spec.Name]);
        Continue;
      end;
      SetLength(Out_, Length(Out_) + 1);
      Out_[High(Out_)] := Spec;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function LoadSkillManifests(const HomeDir: string): TSkillSpecArray;
var
  Root: string;
begin
  SetLength(Result, 0);
  Root := JoinPath(HomeDir, 'workspace/skills');
  if not DirectoryExists(Root) then Exit;
  { Per-directory SKILL.md takes priority -- that is the format every new
    skill (picoclaw, nanobot, ClawHub, Anthropic agent-skills) ships in. }
  ScanSkillDirs(Root, Result);
  ScanJsonSkills(Root, Result);
end;

procedure RegisterSkills(Reg: TToolRegistry; const Skills: TSkillSpecArray);
var
  i, Slot: Integer;
  Tool: TTool;
  K: string;
begin
  if Reg = nil then Exit;
  for i := 0 to High(Skills) do
  begin
    K := LowerCase(Trim(Skills[i].Kind));
    { Pure-knowledge skills (no kind set; SKILL.md is just a markdown
      body the model reads via fs_read) get advertised in the system
      prompt's SKILLS section but skip tool registration -- there is no
      callable tool to attach a handler to, and registering a no-op
      stub would mislead the model into calling it. The catalog listing
      in the system prompt is the contract. }
    if (K <> 'shell') and (K <> 'prompt') then
    begin
      LogDebug('skills: %s registered as knowledge-only (no tool, body=%d bytes)',
               [Skills[i].Name, Length(Skills[i].Body)]);
      Continue;
    end;

    Slot := AllocSlot;
    if (Slot < 0) or (not Assigned(SkillHandlers[Slot])) then
    begin
      LogWarn('skills: out of handler slots (skipping %s)', [Skills[i].Name]);
      Continue;
    end;
    GSpecs[Slot] := Skills[i];
    GUsed[Slot]  := True;
    Tool.Name        := 'skill_' + Skills[i].Name;
    Tool.Description := Skills[i].Description;
    Tool.Schema      := Skills[i].Schema;
    Tool.Handler     := SkillHandlers[Slot];
    Tool.IsCore      := False;
    Reg.Register(Tool);
    LogDebug('skills: registered %s (slot=%d, kind=%s)', [Skills[i].Name, Slot, K]);
  end;
end;

function RunSkill(Reg: TToolRegistry; const Name, ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  if Reg = nil then begin ErrMsg := 'no registry'; Exit(''); end;
  Result := Reg.RunTool('skill_' + Name, ArgsJSON, ErrMsg);
end;

initialization
  { all slots free }
  SkillHandlers[0]  := @H_0;   SkillHandlers[1]  := @H_1;   SkillHandlers[2]  := @H_2;   SkillHandlers[3]  := @H_3;
  SkillHandlers[4]  := @H_4;   SkillHandlers[5]  := @H_5;   SkillHandlers[6]  := @H_6;   SkillHandlers[7]  := @H_7;
  SkillHandlers[8]  := @H_8;   SkillHandlers[9]  := @H_9;   SkillHandlers[10] := @H_10;  SkillHandlers[11] := @H_11;
  SkillHandlers[12] := @H_12;  SkillHandlers[13] := @H_13;  SkillHandlers[14] := @H_14;  SkillHandlers[15] := @H_15;

end.
