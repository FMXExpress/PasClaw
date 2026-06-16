(*
  PasClaw.Skills.Manage - agent-authored skills (the write side of the
  Hermes-style "self-improving skills" feature).

  Registers the `skills_manage` tool so the model can create / edit /
  patch / remove skills on disk during a turn. Off by default; the
  command layer registers it only when
  Cfg.SelfImprovingSkills.SelfManage is True.

  Actions (the `action` arg selects one):

    create  {name, content?}  or  {name, description?, kind?, shell?,
            prompt?, schema?, body?}
            New skill. Refuses to overwrite an existing committed skill
            (matches Hermes: remove first, then recreate). When `content`
            is supplied it is taken verbatim as the SKILL.md; otherwise
            a SKILL.md is assembled from the structured fields.

    edit    {name, content}
            Full SKILL.md rewrite. The named skill must already exist.

    patch   {name, old_string, new_string}
            Targeted single-occurrence substitution inside the existing
            SKILL.md. Preferred over `edit` for small fixes (token-cheap).
            old_string must occur exactly once.

    remove  {name}
            Delete (or stage a tombstone for) an existing skill.

  Staging vs auto-commit (Cfg.SelfImprovingSkills.AutoApprove):

    AutoApprove = False (default): every write is STAGED under
      $PASCLAW_HOME/workspace/skills/.pending/<id>/ with a meta.json
      sidecar. It does not become a live skill until an operator runs
      `pasclaw skills approve <id>` (or the gateway / web UI approve
      action). The model is told the id so it can mention it.

    AutoApprove = True: writes land straight in
      $PASCLAW_HOME/workspace/skills/<name>/. NOTE: like a hub install,
      a freshly committed skill is picked up on the NEXT agent start --
      RegisterSkills runs once at boot, so the tool registry is not
      mutated mid-session. The handler says so in its result.

  Safety:
    - Every write path is confined under workspace/skills/{,.pending/}.
      A name that escapes (slashes, '..', drive letters) is rejected.
    - The model-authored body + shell field are scanned against a
      dangerous-pattern denylist (rm -rf, curl|sh, ...) PLUS any
      operator-supplied Cfg.SelfImprovingSkills.GuardDeny substrings.
    - The description + body go through PasClaw.Promptware so an
      injected "ignore previous instructions" string can't be smuggled
      into the system prompt catalog via a self-authored skill.
    - skills_manage cannot touch .pending sidecar internals or anything
      outside the skills tree; it only writes SKILL.md + meta.json.
*)
unit PasClaw.Skills.Manage;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Registry;

(* Register the `skills_manage` tool. No-op when SelfManage is off.
   Captures the relevant Cfg fields into module state (the tool handler
   is a plain function pointer with no closure, same constraint the
   skill slot table works under). *)
procedure RegisterSkillManageTool(Reg: TToolRegistry; const Cfg: TConfig);

(* Core create entry point, reusable by the distiller (Stage C) without
   going through the tool. RawSKILLMD must be a complete SKILL.md
   (frontmatter + body). Applies the guard + promptware scan, then
   either commits to workspace/skills/<name>/ (AutoApprove) or stages
   under .pending/<id>/. On success OutPath is the committed dir or the
   pending dir, and OutPendingId is the pending id ('' when committed). *)
function CreateSkillFromContent(const HomeDir, RawSKILLMD: string;
                                AutoApprove: Boolean;
                                const GuardDeny: array of string;
                                out OutName, OutPath, OutPendingId, ErrMsg: string): Boolean;

(* True iff Name is a safe skill directory name: lowercase letters,
   digits, '-' and '_' only, non-empty, not '.'/'..'. Shared with the
   approval surface. *)
function IsSafeSkillName(const Name: string): Boolean;

(* Scan Text against the built-in dangerous-pattern denylist plus the
   operator-supplied Extra substrings. Returns True (and sets Pattern)
   on the first hit. Case-insensitive substring match. Exposed for the
   approval surface so a staged skill is re-checked at approve time. *)
function GuardScan(const Text: string; const Extra: array of string;
                   out Pattern: string): Boolean;

implementation

uses
  StrUtils,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Tools.Types,
  PasClaw.Promptware,
  PasClaw.Skills.Loader;

var
  GHomeDir:     string = '';
  GAutoApprove: Boolean = False;
  GGuardDeny:   array of string;

const
  { Substrings that must never appear in a model-authored shell skill.
    Deliberately blunt -- a self-authored skill that wants to run any of
    these should be written by a human and installed the normal way. }
  BuiltinGuardDeny: array[0..11] of string = (
    'rm -rf',
    'rm -fr',
    ':(){',          { fork bomb }
    'mkfs',
    'dd if=',
    '> /dev/sd',
    'curl | sh',
    'curl|sh',
    'wget | sh',
    'wget|sh',
    'chmod 777 /',
    'sudo '
  );

function IsSafeSkillName(const Name: string): Boolean;
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

function GuardScan(const Text: string; const Extra: array of string;
                   out Pattern: string): Boolean;
var
  LowText, P: string;
  i: Integer;
begin
  Result := False;
  Pattern := '';
  LowText := LowerCase(Text);
  for i := System.Low(BuiltinGuardDeny) to System.High(BuiltinGuardDeny) do
  begin
    P := LowerCase(BuiltinGuardDeny[i]);
    if (P <> '') and (Pos(P, LowText) > 0) then
    begin
      Pattern := BuiltinGuardDeny[i];
      Exit(True);
    end;
  end;
  for i := 0 to System.High(Extra) do
  begin
    P := LowerCase(Trim(Extra[i]));
    if (P <> '') and (Pos(P, LowText) > 0) then
    begin
      Pattern := Extra[i];
      Exit(True);
    end;
  end;
end;

function SkillsRoot(const HomeDir: string): string;
begin
  Result := JoinPath(HomeDir, 'workspace/skills');
end;

function PendingRoot(const HomeDir: string): string;
begin
  Result := JoinPath(SkillsRoot(HomeDir), '.pending');
end;

function GenPendingId: string;
var
  R: Integer;
begin
  R := Random(65536);
  Result := FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + IntToHex(R, 4);
end;

(* JSON-string-escape result builder for the tool's machine-readable
   replies. Kept tiny -- we only ever emit a flat object. *)
function OkJSON(const Pairs: array of string): string;
var
  i: Integer;
  Sb: TStringBuilder;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append('{');
    i := 0;
    while i + 1 <= High(Pairs) do
    begin
      if i > 0 then Sb.Append(',');
      Sb.Append('"').Append(JsonEscape(Pairs[i])).Append('":"')
        .Append(JsonEscape(Pairs[i + 1])).Append('"');
      Inc(i, 2);
    end;
    Sb.Append('}');
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

(* Validate a candidate SKILL.md: parses, has a safe name, passes the
   guard + promptware scan. Returns the parsed name on success. *)
function ValidateCandidate(const RawSKILLMD: string;
                           const GuardDeny: array of string;
                           out Name, ErrMsg: string): Boolean;
var
  Spec: TSkillSpec;
  ParseErr, Pattern, RuleId: string;
begin
  Result := False;
  Name := '';

  { Validate in-memory via the canonical parser -- no temp file. }
  if not ParseSkillMDText(RawSKILLMD, '', Spec, ParseErr) then
  begin
    ErrMsg := 'invalid SKILL.md: ' + ParseErr;
    Exit;
  end;

  if not IsSafeSkillName(Spec.Name) then
  begin
    ErrMsg := 'unsafe or missing skill name "' + Spec.Name +
              '" (lowercase letters, digits, - and _ only)';
    Exit;
  end;

  { Guard the executable surface (shell template) AND the body -- a
    knowledge skill could still embed a "run this" instruction. }
  if GuardScan(Spec.Shell + #10 + Spec.Body, GuardDeny, Pattern) then
  begin
    ErrMsg := 'refused: skill content matches dangerous pattern "' +
              Pattern + '"';
    Exit;
  end;

  if PromptwareScanEnabled then
    if ScanPromptware(Spec.Description + #10 + Spec.Body, RuleId) then
    begin
      ErrMsg := 'refused: skill content matched prompt-injection pattern "' +
                RuleId + '"';
      Exit;
    end;

  Name := Spec.Name;
  Result := True;
end;

function CreateSkillFromContent(const HomeDir, RawSKILLMD: string;
                                AutoApprove: Boolean;
                                const GuardDeny: array of string;
                                out OutName, OutPath, OutPendingId, ErrMsg: string): Boolean;
var
  Name, Dir, MDPath, PendId, PendDir, MetaPath: string;
  Meta: TJsonObject;
begin
  Result := False;
  OutName := ''; OutPath := ''; OutPendingId := ''; ErrMsg := '';

  if not ValidateCandidate(RawSKILLMD, GuardDeny, Name, ErrMsg) then Exit;
  OutName := Name;

  if AutoApprove then
  begin
    Dir := JoinPath(SkillsRoot(HomeDir), Name);
    if DirectoryExists(Dir) then
    begin
      ErrMsg := 'a skill named "' + Name + '" already exists; remove it first';
      Exit;
    end;
    EnsureDir(Dir);
    MDPath := JoinPath(Dir, 'SKILL.md');
    WriteFileText(MDPath, RawSKILLMD);
    OutPath := Dir;
    LogInfo('skills_manage: committed skill "%s" -> %s (effective next agent start)',
            [Name, MDPath]);
    Result := True;
    Exit;
  end;

  { Stage. }
  PendId  := GenPendingId;
  PendDir := JoinPath(PendingRoot(HomeDir), PendId);
  EnsureDir(PendDir);
  WriteFileText(JoinPath(PendDir, 'SKILL.md'), RawSKILLMD);
  Meta := TJsonObject.Create;
  try
    Meta.PutStr('id',      PendId);
    Meta.PutStr('action',  'create');
    Meta.PutStr('name',    Name);
    Meta.PutStr('source',  'agent');
    Meta.PutStr('created', NowIsoUtc);
    WriteFileText(JoinPath(PendDir, 'meta.json'), Meta.ToJSON);
  finally
    Meta.Free;
  end;
  OutPath := PendDir;
  OutPendingId := PendId;
  LogInfo('skills_manage: staged skill "%s" as pending %s', [Name, PendId]);
  Result := True;
end;

(* Assemble a SKILL.md from structured fields when the model didn't pass
   a raw `content`. *)
function AssembleSKILLMD(O: TJsonObject): string;
var
  Sb: TStringBuilder;
  Kind, Schema: string;
begin
  Sb := TStringBuilder.Create;
  try
    Sb.Append('---'#10);
    Sb.Append('name: ').Append(O.GetStr('name', '')).Append(#10);
    if O.GetStr('description', '') <> '' then
      Sb.Append('description: ').Append(O.GetStr('description', '')).Append(#10);
    Kind := O.GetStr('kind', '');
    if Kind <> '' then Sb.Append('kind: ').Append(Kind).Append(#10);
    if O.GetStr('shell', '') <> '' then
      Sb.Append('shell: ').Append(O.GetStr('shell', '')).Append(#10);
    if O.GetStr('prompt', '') <> '' then
      Sb.Append('prompt: ').Append(O.GetStr('prompt', '')).Append(#10);
    Schema := O.GetStr('schema', '');
    if Schema <> '' then Sb.Append('schema: ').Append(Schema).Append(#10);
    Sb.Append('---'#10#10);
    Sb.Append(O.GetStr('body', ''));
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

function DoCreate(O: TJsonObject; out ErrMsg: string): string;
var
  Content, Name, Path, PendId: string;
begin
  Result := '';
  Content := O.GetStr('content', '');
  if Content = '' then Content := AssembleSKILLMD(O);
  if not CreateSkillFromContent(GHomeDir, Content, GAutoApprove, GGuardDeny,
                                Name, Path, PendId, ErrMsg) then Exit;
  if PendId <> '' then
    Result := OkJSON(['status', 'staged', 'name', Name, 'pending_id', PendId,
                      'note', 'awaiting operator approval (pasclaw skills approve ' + PendId + ')'])
  else
    Result := OkJSON(['status', 'committed', 'name', Name, 'path', Path,
                      'note', 'effective on next agent start']);
end;

(* Read the committed SKILL.md for Name, or '' if not present. *)
function ReadCommitted(const Name: string; out MDPath: string): string;
begin
  MDPath := JoinPath(JoinPath(SkillsRoot(GHomeDir), Name), 'SKILL.md');
  if FileExists(MDPath) then Result := ReadFileText(MDPath)
  else Result := '';
end;

function StageEdit(const Name, NewContent, Action, OldStr, NewStr: string;
                   out ErrMsg: string): string;
var
  PendId, PendDir: string;
  Meta: TJsonObject;
  ValName, VErr: string;
begin
  Result := '';
  { Validate the resulting content before staging (so a bad patch/edit
    is rejected up front, not at approve time). }
  if not ValidateCandidate(NewContent, GGuardDeny, ValName, VErr) then
  begin
    ErrMsg := VErr; Exit;
  end;
  if not SameText(ValName, Name) then
  begin
    ErrMsg := 'edited content renames the skill (' + Name + ' -> ' + ValName +
              '); create a new skill instead';
    Exit;
  end;

  if GAutoApprove then
  begin
    WriteFileText(JoinPath(JoinPath(SkillsRoot(GHomeDir), Name), 'SKILL.md'),
                  NewContent);
    LogInfo('skills_manage: %s applied to "%s" (effective next agent start)',
            [Action, Name]);
    Result := OkJSON(['status', 'committed', 'name', Name, 'action', Action,
                      'note', 'effective on next agent start']);
    Exit;
  end;

  PendId  := GenPendingId;
  PendDir := JoinPath(PendingRoot(GHomeDir), PendId);
  EnsureDir(PendDir);
  WriteFileText(JoinPath(PendDir, 'SKILL.md'), NewContent);
  Meta := TJsonObject.Create;
  try
    Meta.PutStr('id',      PendId);
    Meta.PutStr('action',  Action);
    Meta.PutStr('name',    Name);
    Meta.PutStr('source',  'agent');
    Meta.PutStr('created', NowIsoUtc);
    if Action = 'patch' then
    begin
      Meta.PutStr('old_string', OldStr);
      Meta.PutStr('new_string', NewStr);
    end;
    WriteFileText(JoinPath(PendDir, 'meta.json'), Meta.ToJSON);
  finally
    Meta.Free;
  end;
  LogInfo('skills_manage: staged %s of "%s" as pending %s', [Action, Name, PendId]);
  Result := OkJSON(['status', 'staged', 'name', Name, 'action', Action,
                    'pending_id', PendId,
                    'note', 'awaiting operator approval (pasclaw skills approve ' + PendId + ')']);
end;

function DoEdit(O: TJsonObject; out ErrMsg: string): string;
var
  Name, Content, MDPath: string;
begin
  Result := '';
  Name := O.GetStr('name', '');
  if not IsSafeSkillName(Name) then begin ErrMsg := 'invalid skill name'; Exit; end;
  if ReadCommitted(Name, MDPath) = '' then
  begin
    ErrMsg := 'no committed skill named "' + Name + '" to edit';
    Exit;
  end;
  Content := O.GetStr('content', '');
  if Content = '' then begin ErrMsg := 'edit requires `content` (full SKILL.md)'; Exit; end;
  Result := StageEdit(Name, Content, 'edit', '', '', ErrMsg);
end;

function DoPatch(O: TJsonObject; out ErrMsg: string): string;
var
  Name, OldStr, NewStr, Cur, MDPath, NewContent: string;
  P, P2: Integer;
begin
  Result := '';
  Name := O.GetStr('name', '');
  if not IsSafeSkillName(Name) then begin ErrMsg := 'invalid skill name'; Exit; end;
  Cur := ReadCommitted(Name, MDPath);
  if Cur = '' then
  begin
    ErrMsg := 'no committed skill named "' + Name + '" to patch';
    Exit;
  end;
  OldStr := O.GetStr('old_string', '');
  NewStr := O.GetStr('new_string', '');
  if OldStr = '' then begin ErrMsg := 'patch requires a non-empty old_string'; Exit; end;
  P := Pos(OldStr, Cur);
  if P <= 0 then begin ErrMsg := 'old_string not found in SKILL.md'; Exit; end;
  P2 := PosEx(OldStr, Cur, P + Length(OldStr));
  if P2 > 0 then begin ErrMsg := 'old_string occurs more than once -- make it unique'; Exit; end;
  NewContent := Copy(Cur, 1, P - 1) + NewStr +
                Copy(Cur, P + Length(OldStr), MaxInt);
  Result := StageEdit(Name, NewContent, 'patch', OldStr, NewStr, ErrMsg);
end;

(* Recursively delete a skill directory (SKILL.md plus any scripts/
   references/ assets/ subtrees). Returns True when the directory is
   gone. Kept local -- the hub installers use a flat RemoveDir because
   their temp dirs are shallow; a skill tree can nest. *)
function DeleteSkillDir(const Dir: string): Boolean;
var
  SR: TSearchRec;
  Child: string;
begin
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Child := JoinPath(Dir, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then
        DeleteSkillDir(Child)
      else
        DeleteFile(Child);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := RemoveDir(Dir);
end;

function DoRemove(O: TJsonObject; out ErrMsg: string): string;
var
  Name, Dir, PendId, PendDir: string;
  Meta: TJsonObject;
begin
  Result := '';
  Name := O.GetStr('name', '');
  if not IsSafeSkillName(Name) then begin ErrMsg := 'invalid skill name'; Exit; end;
  Dir := JoinPath(SkillsRoot(GHomeDir), Name);
  if not DirectoryExists(Dir) then
  begin
    ErrMsg := 'no committed skill named "' + Name + '"';
    Exit;
  end;

  if GAutoApprove then
  begin
    { Best-effort recursive delete of the skill dir. }
    if not DeleteSkillDir(Dir) then
    begin
      ErrMsg := 'failed to delete ' + Dir;
      Exit;
    end;
    LogInfo('skills_manage: removed skill "%s"', [Name]);
    Result := OkJSON(['status', 'committed', 'name', Name, 'action', 'remove',
                      'note', 'effective on next agent start']);
    Exit;
  end;

  PendId  := GenPendingId;
  PendDir := JoinPath(PendingRoot(GHomeDir), PendId);
  EnsureDir(PendDir);
  Meta := TJsonObject.Create;
  try
    Meta.PutStr('id',      PendId);
    Meta.PutStr('action',  'remove');
    Meta.PutStr('name',    Name);
    Meta.PutStr('source',  'agent');
    Meta.PutStr('created', NowIsoUtc);
    WriteFileText(JoinPath(PendDir, 'meta.json'), Meta.ToJSON);
  finally
    Meta.Free;
  end;
  LogInfo('skills_manage: staged removal of "%s" as pending %s', [Name, PendId]);
  Result := OkJSON(['status', 'staged', 'name', Name, 'action', 'remove',
                    'pending_id', PendId,
                    'note', 'awaiting operator approval (pasclaw skills approve ' + PendId + ')']);
end;

function SkillManageHandler(const ArgsJSON: string; out ErrMsg: string): string;
var
  O: TJsonObject;
  Action: string;
begin
  ErrMsg := '';
  Result := '';
  if GHomeDir = '' then begin ErrMsg := 'skills_manage not initialised'; Exit; end;
  O := TJsonObject.Parse(ArgsJSON);
  if O = nil then begin ErrMsg := 'invalid JSON arguments'; Exit; end;
  try
    Action := LowerCase(Trim(O.GetStr('action', '')));
    if      Action = 'create' then Result := DoCreate(O, ErrMsg)
    else if Action = 'edit'   then Result := DoEdit(O, ErrMsg)
    else if Action = 'patch'  then Result := DoPatch(O, ErrMsg)
    else if Action = 'remove' then Result := DoRemove(O, ErrMsg)
    else ErrMsg := 'unknown action "' + Action +
                   '" (expected create / edit / patch / remove)';
  finally
    O.Free;
  end;
end;

const
  SkillManageSchema =
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["create","edit","patch","remove"]},' +
    '"name":{"type":"string","description":"skill name (lowercase, digits, - _)"},' +
    '"content":{"type":"string","description":"full SKILL.md (frontmatter + body) for create/edit"},' +
    '"description":{"type":"string"},' +
    (* Gemini rejects empty strings in enum arrays with "enum[0]: cannot
       be empty" -- so the historical {"enum":["","shell","prompt"]}
       shape that used "" to signal "knowledge-only skill" broke any
       deploy that registered skills_manage against a Gemini model
       (max-build profile + Gemini provider was the reported repro).
       Drop the empty-string member; absent / missing `kind` already
       means knowledge-only (the assembler at line ~336 skips writing
       the `kind:` frontmatter line when GetStr('kind','') returns
       empty), so this is a schema cleanup, not a behaviour change. *)
    '"kind":{"type":"string","enum":["shell","prompt"],' +
      '"description":"omit for knowledge-only skills (markdown body only); ' +
      '\"shell\" or \"prompt\" registers a callable skill_<name> tool"},' +
    '"shell":{"type":"string"},"prompt":{"type":"string"},"schema":{"type":"string"},' +
    '"body":{"type":"string","description":"markdown body when not passing full content"},' +
    '"old_string":{"type":"string","description":"patch: unique text to replace"},' +
    '"new_string":{"type":"string","description":"patch: replacement text"}' +
    '},"required":["action"]}';

  SkillManageDesc =
    'Create, edit, patch, or remove a reusable skill on disk. Capture a ' +
    'non-trivial workflow you just performed so a future turn can reuse it. ' +
    'action=create needs name + content (a full SKILL.md: YAML frontmatter ' +
    'with name/description, optional kind: shell|prompt, then a markdown ' +
    'body). action=patch does a unique old_string->new_string substitution. ' +
    'Writes may be staged for operator approval and take effect on the next ' +
    'agent start, not immediately.';

procedure RegisterSkillManageTool(Reg: TToolRegistry; const Cfg: TConfig);
var
  Tool: TTool;
  i: Integer;
begin
  if Reg = nil then Exit;
  if not Cfg.SelfImprovingSkills.SelfManage then Exit;

  GHomeDir     := GetHome;
  GAutoApprove := Cfg.SelfImprovingSkills.AutoApprove;
  SetLength(GGuardDeny, Length(Cfg.SelfImprovingSkills.GuardDeny));
  for i := 0 to High(Cfg.SelfImprovingSkills.GuardDeny) do
    GGuardDeny[i] := Cfg.SelfImprovingSkills.GuardDeny[i];

  Tool.Name        := 'skills_manage';
  Tool.Description := SkillManageDesc;
  Tool.Schema      := SkillManageSchema;
  Tool.Handler     := SkillManageHandler;
  Tool.HandlerObj  := nil;
  Tool.IsCore      := False;
  Tool.Category    := tcMutating;   { writes files -- never parallelised }
  Reg.Register(Tool);
  LogInfo('skills: skills_manage tool registered (auto_approve=%s)',
          [BoolToStr(GAutoApprove, True)]);
end;

initialization
  Randomize;

end.
