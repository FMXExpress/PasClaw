program workspaces_tests;
(*
  Pins PasClaw.Workspaces: name<->slot mapping, enumeration ordering, creation
  of the next free slot, active-workspace resolution (env over config over
  default), and the back-compat guarantee that an untouched install still
  resolves to <home>/workspace.

  Runs against a temp PASCLAW_HOME; no network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
end;

procedure ExpectInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(Got) + ', want ' + IntToStr(Want));
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then
    Fail_(Msg);
end;

var
  List: TWorkspaceInfoArray;
  Name_, Err: string;
begin
  { Second pass: the Makefile re-runs this binary with PASCLAW_WORKSPACE set,
    against the home the first pass built. FPC has no portable setenv, and
    exercising the override from outside is the truer test anyway -- that is
    exactly how a subagent or a second gateway would use it. }
  if Trim(GetEnvironmentVariable(EnvWorkspace)) <> '' then
  begin
    ExpectStr(ActiveWorkspaceName, 'workspace3',
              'env var wins over config.json active_workspace');
    ExpectStr(ActiveWorkspaceRoot, JoinPath(GetHome, 'workspace3'),
              'root follows the env override');
    if Failures = 0 then
      WriteLn('workspaces_tests (env override): OK')
    else
    begin
      WriteLn('workspaces_tests (env override): ', Failures, ' failure(s)');
      Halt(1);
    end;
    Halt(0);
  end;

  { --- naming --- }
  ExpectStr(WorkspaceDirName(1), 'workspace',  'slot 1 keeps the bare name');
  ExpectStr(WorkspaceDirName(2), 'workspace2', 'slot 2 is suffixed');
  ExpectStr(WorkspaceDirName(11), 'workspace11', 'multi-digit slot');

  ExpectInt(WorkspaceSlot('workspace'),   1, 'bare name is slot 1');
  ExpectInt(WorkspaceSlot('workspace3'),  3, 'suffixed name parses');
  ExpectInt(WorkspaceSlot('workspace1'),  0, 'workspace1 is not a second name for slot 1');
  ExpectInt(WorkspaceSlot('workspace0'),  0, 'workspace0 rejected');
  ExpectInt(WorkspaceSlot('workspaces'),  0, 'non-numeric tail rejected');
  ExpectInt(WorkspaceSlot('work'),        0, 'unrelated name rejected');
  ExpectInt(WorkspaceSlot(''),            0, 'empty name rejected');
  { Path traversal must not survive the name check -- these arrive over HTTP. }
  ExpectInt(WorkspaceSlot('workspace2/../..'), 0, 'traversal rejected');
  ExpectTrue(not IsWorkspaceName('../workspace'), 'leading traversal rejected');

  { --- default resolution (fresh home, no config) --- }
  ExpectStr(ActiveWorkspaceName, 'workspace', 'defaults to workspace');
  ExpectStr(ActiveWorkspaceRoot, JoinPath(GetHome, 'workspace'),
            'back-compat: same path the old hardcoded join produced');

  { --- enumeration on a fresh install --- }
  List := ListWorkspaces;
  ExpectInt(Length(List), 1, 'fresh install lists exactly one workspace');
  ExpectStr(List[0].Name, 'workspace', 'that one is slot 1');
  ExpectTrue(List[0].Active, 'and it is active');

  { --- creation --- }
  Name_ := CreateWorkspace('Home');
  ExpectStr(Name_, 'workspace2', 'first created workspace takes slot 2');
  ExpectTrue(DirectoryExists(JoinPath(GetHome, 'workspace2')), 'directory made');
  ExpectTrue(DirectoryExists(JoinPath(JoinPath(GetHome, 'workspace2'), 'projects')),
             'projects/ seeded');
  ExpectTrue(DirectoryExists(JoinPath(JoinPath(GetHome, 'workspace2'), 'memory')),
             'memory/ seeded');
  ExpectStr(WorkspaceLabel('workspace2'), 'Home', 'label persisted');
  ExpectStr(WorkspaceLabel('workspace'), 'Workspace 1', 'unlabelled falls back');

  Name_ := CreateWorkspace('');
  ExpectStr(Name_, 'workspace3', 'next create takes the next free slot');

  List := ListWorkspaces;
  ExpectInt(Length(List), 3, 'three workspaces listed');
  ExpectStr(List[0].Name, 'workspace',  'ordered by slot: 1st');
  ExpectStr(List[1].Name, 'workspace2', 'ordered by slot: 2nd');
  ExpectStr(List[2].Name, 'workspace3', 'ordered by slot: 3rd');

  { --- switching --- }
  ExpectTrue(SetActiveWorkspace('workspace2', Err), 'switch to workspace2');
  ExpectStr(Err, '', 'switch is clean');
  ExpectStr(ActiveWorkspaceName, 'workspace2', 'active follows the switch');
  ExpectStr(ActiveWorkspaceRoot, JoinPath(GetHome, 'workspace2'), 'root follows');
  ExpectStr(WorkspacePath('memory'), JoinPath(JoinPath(GetHome, 'workspace2'), 'memory'),
            'subpaths follow the active workspace');

  List := ListWorkspaces;
  ExpectTrue(List[1].Active, 'workspace2 reports active');
  ExpectTrue(not List[0].Active, 'workspace1 no longer active');

  ExpectTrue(not SetActiveWorkspace('workspace9', Err), 'cannot switch to a missing workspace');
  ExpectTrue(Err <> '', 'and it says why');
  ExpectStr(ActiveWorkspaceName, 'workspace2', 'failed switch changes nothing');

  ExpectTrue(not SetActiveWorkspace('../etc', Err), 'malformed name refused');

  { Switching back to slot 1 is always allowed, even before its dir exists. }
  ExpectTrue(SetActiveWorkspace('workspace', Err), 'switch back to slot 1');
  ExpectStr(ActiveWorkspaceName, 'workspace', 'back on slot 1');

  { The env-override half runs as a second pass -- see the top of the program. }

  if Failures = 0 then
    WriteLn('workspaces_tests: OK')
  else
  begin
    WriteLn('workspaces_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
