(*
  PasClaw.Skills.Pending - operator approval surface for staged,
  agent-authored skills (the read/approve/reject side of the
  self-improving-skills feature).

  When Cfg.SelfImprovingSkills.AutoApprove is False, skill_manage and the
  distiller stage their writes under

    $PASCLAW_HOME/workspace/skills/.pending/<id>/
        SKILL.md     (the proposed content; absent for a remove)
        meta.json    {id, action, name, source, created, ...}

  This unit lists those, lets an operator inspect them, and commits or
  discards them:

    ListPending      -> [{id, action, name, created}, ...]
    ReadPending      -> the staged SKILL.md text (for diff/preview)
    ApprovePending   -> apply the staged action to the live skills tree,
                        then delete the pending dir. Re-runs the name +
                        dangerous-pattern guard at approve time so a
                        hand-edited pending file can't smuggle anything
                        past the gate the model was held to.
    RejectPending    -> delete the pending dir, no changes to live skills.

  Approve does NOT hot-reload the registry: like a hub install, a newly
  approved skill is picked up on the next agent start.
*)
unit PasClaw.Skills.Pending;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config;

type
  TPendingSkill = record
    Id:      string;
    Action:  string;   { create | edit | patch | remove }
    Name:    string;
    Created: string;
    Dir:     string;   { absolute path to the .pending/<id> directory }
  end;
  TPendingSkillArray = array of TPendingSkill;

function ListPending(const HomeDir: string): TPendingSkillArray;
function ReadPending(const HomeDir, Id: string; out Content, ErrMsg: string): Boolean;
function ApprovePending(const HomeDir, Id: string;
                        const Cfg: TConfig; out ErrMsg: string): Boolean;
function RejectPending(const HomeDir, Id: string; out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Skills.Loader,
  PasClaw.Skills.Manage;   { IsSafeSkillName, GuardScan }

function PendingRoot(const HomeDir: string): string;
begin
  Result := JoinPath(JoinPath(HomeDir, 'workspace/skills'), '.pending');
end;

function SkillDir(const HomeDir, Name: string): string;
begin
  Result := JoinPath(JoinPath(HomeDir, 'workspace/skills'), Name);
end;

(* Local recursive delete -- a pending dir holds a couple of files but a
   committed skill dir can nest (scripts/ references/). *)
function DeleteTree(const Dir: string): Boolean;
var
  SR: TSearchRec;
  Child: string;
begin
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Child := JoinPath(Dir, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then DeleteTree(Child)
      else DeleteFile(Child);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := RemoveDir(Dir);
end;

function ReadMeta(const PendDir: string; out P: TPendingSkill): Boolean;
var
  O: TJsonObject;
  Body: string;
begin
  Result := False;
  Body := ReadFileText(JoinPath(PendDir, 'meta.json'));
  if Body = '' then Exit;
  O := TJsonObject.Parse(Body);
  if O = nil then Exit;
  try
    P.Id      := O.GetStr('id', '');
    P.Action  := O.GetStr('action', '');
    P.Name    := O.GetStr('name', '');
    P.Created := O.GetStr('created', '');
    P.Dir     := PendDir;
    Result    := P.Id <> '';
  finally
    O.Free;
  end;
end;

function ListPending(const HomeDir: string): TPendingSkillArray;
var
  Root: string;
  SR: TSearchRec;
  P: TPendingSkill;
begin
  SetLength(Result, 0);
  Root := PendingRoot(HomeDir);
  if not DirectoryExists(Root) then Exit;
  if FindFirst(JoinPath(Root, '*'), faDirectory, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then Continue;
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if ReadMeta(JoinPath(Root, SR.Name), P) then
      begin
        SetLength(Result, Length(Result) + 1);
        Result[High(Result)] := P;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function FindPending(const HomeDir, Id: string; out P: TPendingSkill): Boolean;
var
  Dir: string;
begin
  Result := False;
  { Id is operator-supplied; make sure it can't escape .pending. }
  if (Id = '') or (Pos('/', Id) > 0) or (Pos('\', Id) > 0) or
     (Pos('..', Id) > 0) then Exit;
  Dir := JoinPath(PendingRoot(HomeDir), Id);
  if not DirectoryExists(Dir) then Exit;
  Result := ReadMeta(Dir, P);
end;

function ReadPending(const HomeDir, Id: string; out Content, ErrMsg: string): Boolean;
var
  P: TPendingSkill;
begin
  Result := False;
  Content := '';
  ErrMsg := '';
  if not FindPending(HomeDir, Id, P) then begin ErrMsg := 'no pending skill ' + Id; Exit; end;
  if P.Action = 'remove' then
  begin
    Content := '(removal of skill "' + P.Name + '")';
    Exit(True);
  end;
  Content := ReadFileText(JoinPath(P.Dir, 'SKILL.md'));
  if Content = '' then begin ErrMsg := 'pending SKILL.md missing or empty'; Exit; end;
  Result := True;
end;

function ApprovePending(const HomeDir, Id: string;
                        const Cfg: TConfig; out ErrMsg: string): Boolean;
var
  P: TPendingSkill;
  Staged, Pattern, ParseErr, Dest, DestMD: string;
  Spec: TSkillSpec;
begin
  Result := False;
  ErrMsg := '';
  if not FindPending(HomeDir, Id, P) then begin ErrMsg := 'no pending skill ' + Id; Exit; end;

  if P.Action = 'remove' then
  begin
    Dest := SkillDir(HomeDir, P.Name);
    if DirectoryExists(Dest) then
      if not DeleteTree(Dest) then
      begin
        ErrMsg := 'failed to delete ' + Dest;
        Exit;
      end;
    DeleteTree(P.Dir);
    LogInfo('skills: approved removal of "%s" (%s)', [P.Name, Id]);
    Exit(True);
  end;

  { create / edit / patch all resolve to "write this SKILL.md". }
  Staged := ReadFileText(JoinPath(P.Dir, 'SKILL.md'));
  if Staged = '' then begin ErrMsg := 'staged SKILL.md missing'; Exit; end;

  { Re-validate at approve time: parse, name safety, dangerous-pattern
    guard. Protects against a hand-edited pending file. }
  if not ParseSkillMDText(Staged, '', Spec, ParseErr) then
  begin
    ErrMsg := 'staged SKILL.md invalid: ' + ParseErr;
    Exit;
  end;
  if not IsSafeSkillName(Spec.Name) then
  begin
    ErrMsg := 'unsafe skill name "' + Spec.Name + '"';
    Exit;
  end;
  if GuardScan(Spec.Shell + #10 + Spec.Body, Cfg.SelfImprovingSkills.GuardDeny, Pattern) then
  begin
    ErrMsg := 'staged skill matches dangerous pattern "' + Pattern + '" -- not approved';
    Exit;
  end;

  Dest := SkillDir(HomeDir, Spec.Name);
  if (P.Action = 'create') and DirectoryExists(Dest) then
  begin
    ErrMsg := 'a skill named "' + Spec.Name + '" already exists; reject this ' +
              'pending entry or remove the existing skill first';
    Exit;
  end;
  EnsureDir(Dest);
  DestMD := JoinPath(Dest, 'SKILL.md');
  WriteFileText(DestMD, Staged);
  DeleteTree(P.Dir);
  LogInfo('skills: approved %s of "%s" (%s) -> %s (effective next agent start)',
          [P.Action, Spec.Name, Id, DestMD]);
  Result := True;
end;

function RejectPending(const HomeDir, Id: string; out ErrMsg: string): Boolean;
var
  P: TPendingSkill;
begin
  Result := False;
  ErrMsg := '';
  if not FindPending(HomeDir, Id, P) then begin ErrMsg := 'no pending skill ' + Id; Exit; end;
  if not DeleteTree(P.Dir) then begin ErrMsg := 'failed to delete ' + P.Dir; Exit; end;
  LogInfo('skills: rejected pending %s ("%s")', [Id, P.Name]);
  Result := True;
end;

end.
