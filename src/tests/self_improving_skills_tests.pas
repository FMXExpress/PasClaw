program self_improving_skills_tests;
(*
  Network-free coverage of the self-improving-skills write + approval
  path (PasClaw.Skills.Manage + PasClaw.Skills.Pending):

    - IsSafeSkillName / GuardScan guards
    - CreateSkillFromContent staging (AutoApprove off) -> a .pending/<id>
      dir with SKILL.md + meta.json
    - CreateSkillFromContent commit (AutoApprove on) -> workspace/skills/<name>
    - ListPending / ReadPending / ApprovePending / RejectPending
    - the dangerous-pattern guard rejecting a shell skill

  Drives a throwaway $PASCLAW_HOME under the system temp dir so it leaves
  nothing behind and needs no provider / network.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Skills.Loader,
  PasClaw.Skills.Manage,
  PasClaw.Skills.Pending;

var
  Home: string;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

function MakeMD(const Name, Desc, Body: string): string;
begin
  Result := '---'#10 + 'name: ' + Name + #10 + 'description: ' + Desc + #10 +
            '---'#10#10 + Body;
end;

procedure TestGuards;
var
  Pat: string;
begin
  AssertTrue(IsSafeSkillName('good_name-1'), 'good name accepted');
  AssertTrue(not IsSafeSkillName('Bad Name'), 'space/upper rejected');
  AssertTrue(not IsSafeSkillName('../escape'), 'traversal rejected');
  AssertTrue(not IsSafeSkillName(''), 'empty rejected');

  AssertTrue(GuardScan('please run rm -rf /tmp/x', [], Pat), 'rm -rf flagged');
  AssertTrue(not GuardScan('a wholly benign body', [], Pat), 'benign body passes');
  AssertTrue(GuardScan('echo SECRET', ['SECRET'], Pat), 'custom guard term flagged');
end;

procedure TestStageAndApprove;
var
  Name, Path, Pend, Err, Content: string;
  PendList: TPendingSkillArray;
  Cfg: TConfig;
  Specs: TSkillSpecArray;
  i: Integer;
  Found: Boolean;
begin
  Cfg := TConfig.Create;   { defaults: AutoApprove off, empty GuardDeny }
  try
    { Stage a knowledge skill. }
    AssertTrue(CreateSkillFromContent(Home,
                 MakeMD('deploy_check', 'verify a deploy is healthy',
                        '# Deploy check'#10#10'1. curl /v1/health'#10'2. check 200'),
                 False, Cfg.SelfImprovingSkills.GuardDeny,
                 Name, Path, Pend, Err),
               'stage create succeeds: ' + Err);
    AssertTrue(Name = 'deploy_check', 'staged name');
    AssertTrue(Pend <> '', 'staging returns a pending id');

    PendList := ListPending(Home);
    AssertTrue(Length(PendList) = 1, 'one pending entry');
    AssertTrue(PendList[0].Action = 'create', 'pending action create');
    AssertTrue(PendList[0].Name = 'deploy_check', 'pending name');

    AssertTrue(ReadPending(Home, Pend, Content, Err), 'read pending diff: ' + Err);
    AssertTrue(Pos('Deploy check', Content) > 0, 'diff has body');

    { Not yet a live skill. }
    Specs := LoadSkillManifests(Home);
    AssertTrue(Length(Specs) = 0, 'staged skill not yet loaded');

    { Approve -> becomes a live skill, pending dir gone. }
    AssertTrue(ApprovePending(Home, Pend, Cfg, Err), 'approve: ' + Err);
    AssertTrue(Length(ListPending(Home)) = 0, 'pending cleared after approve');

    Specs := LoadSkillManifests(Home);
    Found := False;
    for i := 0 to High(Specs) do
      if Specs[i].Name = 'deploy_check' then Found := True;
    AssertTrue(Found, 'approved skill is now loadable');
  finally
    Cfg.Free;
  end;
end;

procedure TestRejectAndDangerous;
var
  Name, Path, Pend, Err: string;
  Cfg: TConfig;
  Ok: Boolean;
begin
  Cfg := TConfig.Create;
  try
    { A shell skill running rm -rf must be refused at stage time. }
    Ok := CreateSkillFromContent(Home,
            '---'#10'name: nuke'#10'description: bad'#10'kind: shell'#10 +
            'shell: rm -rf /'#10'---'#10#10'body',
            False, Cfg.SelfImprovingSkills.GuardDeny, Name, Path, Pend, Err);
    AssertTrue(not Ok, 'dangerous shell skill refused');
    AssertTrue(Pos('dangerous', Err) > 0, 'refusal mentions dangerous pattern');

    { Stage a good one, then reject it. }
    AssertTrue(CreateSkillFromContent(Home,
                 MakeMD('temp_skill', 'throwaway', '# Temp'),
                 False, Cfg.SelfImprovingSkills.GuardDeny, Name, Path, Pend, Err),
               'stage temp: ' + Err);
    AssertTrue(RejectPending(Home, Pend, Err), 'reject: ' + Err);
    AssertTrue(Length(ListPending(Home)) = 0, 'pending cleared after reject');
  finally
    Cfg.Free;
  end;
end;

procedure TestAutoApproveCommit;
var
  Name, Path, Pend, Err: string;
  Cfg: TConfig;
  Specs: TSkillSpecArray;
  i: Integer;
  Found: Boolean;
begin
  Cfg := TConfig.Create;
  try
    AssertTrue(CreateSkillFromContent(Home,
                 MakeMD('auto_skill', 'auto committed', '# Auto'),
                 True, Cfg.SelfImprovingSkills.GuardDeny, Name, Path, Pend, Err),
               'auto-commit create: ' + Err);
    AssertTrue(Pend = '', 'auto-approve returns no pending id');
    AssertTrue(Length(ListPending(Home)) = 0, 'auto-approve does not stage');
    Specs := LoadSkillManifests(Home);
    Found := False;
    for i := 0 to High(Specs) do
      if Specs[i].Name = 'auto_skill' then Found := True;
    AssertTrue(Found, 'auto-committed skill is loadable');
  finally
    Cfg.Free;
  end;
end;

(* Codex PR #288 P1: a hand-edited meta.json with `"name": "../../etc"`
   would let the remove branch DeleteTree escape workspace/skills. *)
procedure TestApprovePendingRejectsUnsafeMetaName;
var
  PendId, PendDir, Err: string;
  Cfg: TConfig;
  Ok: Boolean;
begin
  PendId := 'bad-meta-' + IntToStr(Random(1 shl 30));
  PendDir := JoinPath(JoinPath(Home, 'workspace/skills/.pending'), PendId);
  EnsureDir(PendDir);
  WriteFileText(JoinPath(PendDir, 'meta.json'),
    '{"id":"' + PendId + '","action":"remove","name":"../../escape","source":"x","created":"x"}');

  Cfg := TConfig.Create;
  try
    Ok := ApprovePending(Home, PendId, Cfg, Err);
  finally
    Cfg.Free;
  end;
  AssertTrue(not Ok, 'approve must refuse unsafe meta name');
  AssertTrue(Pos('unsafe', LowerCase(Err)) > 0, 'error mentions unsafe');
  { Cleanup. }
  DeleteFile(JoinPath(PendDir, 'meta.json'));
  RemoveDir(PendDir);
end;

(* Codex PR #288 P2: an edit/patch whose staged SKILL.md renames the
   skill must be refused; an edit/patch whose target no longer exists
   must be refused too. *)
procedure TestApprovePendingEditNameMismatch;
var
  Name, Path, Pend, Err, RenameId, RenameDir: string;
  Cfg: TConfig;
  Ok: Boolean;
begin
  Cfg := TConfig.Create;
  try
    { Stage + auto-approve an initial skill so something exists to edit. }
    AssertTrue(CreateSkillFromContent(Home,
                 MakeMD('orig_skill', 'first', '# Orig'),
                 True, Cfg.SelfImprovingSkills.GuardDeny, Name, Path, Pend, Err),
               'seed orig_skill: ' + Err);

    { Hand-craft a pending edit whose meta says orig_skill but whose
      staged SKILL.md renames to other_skill. }
    RenameId := 'rename-' + IntToStr(Random(1 shl 30));
    RenameDir := JoinPath(JoinPath(Home, 'workspace/skills/.pending'), RenameId);
    EnsureDir(RenameDir);
    WriteFileText(JoinPath(RenameDir, 'SKILL.md'),
      MakeMD('other_skill', 'renamed', '# Renamed'));
    WriteFileText(JoinPath(RenameDir, 'meta.json'),
      '{"id":"' + RenameId + '","action":"edit","name":"orig_skill","source":"x","created":"x"}');

    Ok := ApprovePending(Home, RenameId, Cfg, Err);
    AssertTrue(not Ok, 'approve must refuse rename-via-edit');
    AssertTrue(Pos('renames', Err) > 0, 'error mentions renames');
    { Cleanup pending. }
    DeleteFile(JoinPath(RenameDir, 'SKILL.md'));
    DeleteFile(JoinPath(RenameDir, 'meta.json'));
    RemoveDir(RenameDir);

    { Now stage a legit edit, then delete the target before approving. }
    RenameId := 'missing-' + IntToStr(Random(1 shl 30));
    RenameDir := JoinPath(JoinPath(Home, 'workspace/skills/.pending'), RenameId);
    EnsureDir(RenameDir);
    WriteFileText(JoinPath(RenameDir, 'SKILL.md'),
      MakeMD('orig_skill', 'first revised', '# Revised'));
    WriteFileText(JoinPath(RenameDir, 'meta.json'),
      '{"id":"' + RenameId + '","action":"edit","name":"orig_skill","source":"x","created":"x"}');
    { Vanish the target. }
    DeleteFile(JoinPath(JoinPath(Home, 'workspace/skills/orig_skill'), 'SKILL.md'));
    RemoveDir(JoinPath(Home, 'workspace/skills/orig_skill'));

    Ok := ApprovePending(Home, RenameId, Cfg, Err);
    AssertTrue(not Ok, 'approve must refuse edit of missing target');
    AssertTrue(Pos('no longer exists', Err) > 0, 'error mentions missing target');
    DeleteFile(JoinPath(RenameDir, 'SKILL.md'));
    DeleteFile(JoinPath(RenameDir, 'meta.json'));
    RemoveDir(RenameDir);
  finally
    Cfg.Free;
  end;
end;

procedure TestConfigRoundTrip;
var
  C, C2: TConfig;
  S: string;
begin
  C := TConfig.Create;
  try
    C.SelfImprovingSkills.SelfManage            := True;
    C.SelfImprovingSkills.ProgressiveDisclosure := True;
    C.SelfImprovingSkills.AutoApprove           := True;
    C.SelfImprovingSkills.Distiller.Enabled      := True;
    C.SelfImprovingSkills.Distiller.MinToolCalls := 9;
    C.SelfImprovingSkills.Distiller.Model        := 'claude-haiku-4-5';
    S := C.ToJSON;
  finally
    C.Free;
  end;
  C2 := TConfig.Create;
  try
    C2.FromJSON(S);
    AssertTrue(C2.SelfImprovingSkills.SelfManage, 'self_manage round-trips');
    AssertTrue(C2.SelfImprovingSkills.ProgressiveDisclosure, 'progressive_disclosure round-trips');
    AssertTrue(C2.SelfImprovingSkills.AutoApprove, 'auto_approve round-trips');
    AssertTrue(C2.SelfImprovingSkills.Distiller.Enabled, 'distiller.enabled round-trips');
    AssertTrue(C2.SelfImprovingSkills.Distiller.MinToolCalls = 9, 'min_tool_calls round-trips');
    AssertTrue(C2.SelfImprovingSkills.Distiller.Model = 'claude-haiku-4-5', 'distiller.model round-trips');
  finally
    C2.Free;
  end;
end;

begin
  Home := JoinPath(GetTempDir, 'pasclaw-sis-' + IntToStr(Random(1 shl 30)));
  EnsureDir(JoinPath(Home, 'workspace/skills'));
  try
    TestGuards;
    TestStageAndApprove;
    TestRejectAndDangerous;
    TestAutoApproveCommit;
    TestApprovePendingRejectsUnsafeMetaName;
    TestApprovePendingEditNameMismatch;
    TestConfigRoundTrip;
    WriteLn('ok - self-improving-skills tests passed');
  finally
    { best-effort cleanup }
    try RemoveDir(Home); except end;
  end;
end.
