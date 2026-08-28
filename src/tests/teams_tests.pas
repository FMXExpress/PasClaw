program teams_tests;
(*
  Pins PasClaw.Teams -- ready-made agent teams -- and the task assignee
  field they stand on.

  What is asserted, in the order it matters:

    - the BUILT-IN catalogue validates: a template we ship that fails
      our own referential-integrity rules should fail in CI, not in a
      user's workspace.
    - validation refuses the real mistakes: a parent not in the
      template, a duplicate agent, a reporting cycle, a model ID where
      a tier belongs.
    - seeding is idempotent skip-and-report, parents are created before
      their reports, and an operator's edited agent is KEPT.
    - a task's assignee round-trips through the store and the task
      tool, with '-' leave-alone and '' unassign semantics.
    - the wake policy: an idle agent with pending messages or an open
      assigned task is woken; one with nothing to do is left alone --
      with the WHY carried out for each, because the reasons are the
      policy.
    - a board with no tasks is NOT done; a board of done tasks is;
      state round-trips; a user template file overrides a built-in of
      the same name; a roster export parses back as a template.

  Runs against a temp PASCLAW_HOME; no network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Projects.Tools,
  PasClaw.Agents,
  PasClaw.Teams;

var
  Failures: Integer = 0;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok: ' + Msg) else Fail(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got = Want then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got = Want then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' -- "' + Needle + '" not in: ' + Copy(Haystack, 1, 160));
end;

function MiniTemplate: TTeamTemplate;
begin
  Result := Default(TTeamTemplate);
  Result.Name := 'mini';
  Result.Title := 'Mini';
  SetLength(Result.Agents, 3);
  Result.Agents[0].Name := 'boss';  Result.Agents[0].Title := 'Boss';
  Result.Agents[0].Role := 'Lead.'; Result.Agents[0].Parent := '';
  { Deliberately listed BEFORE its parent: seeding must order it after. }
  Result.Agents[1].Name := 'worker'; Result.Agents[1].Title := 'Worker';
  Result.Agents[1].Role := 'Does.';  Result.Agents[1].Parent := 'mid';
  Result.Agents[2].Name := 'mid';   Result.Agents[2].Title := 'Mid';
  Result.Agents[2].Role := 'Leads.'; Result.Agents[2].Parent := 'boss';
  Result.WakeMinutes := 15;
  Result.Exists := True;
end;

var
  All: TTeamTemplateArray;
  T, T2: TTeamTemplate;
  S, S2: TTeamState;
  Info: TAgentInfo;
  Created, Skipped: TStringArray;
  Wakes: TWakeReasonArray;
  Task: TTaskInfo;
  I: Integer;
  Err, Out_, Delivered, TaskId, Proj: string;
  Found: Boolean;
begin
  { ------------------------------------------------- built-in catalogue -- }
  All := TeamTemplates;
  AssertTrue(Length(All) >= 2, 'catalogue has at least duo and software-team');
  Found := False;
  for I := 0 to High(All) do
  begin
    if not ValidateTeamTemplate(All[I], Err) then
      Fail('built-in template "' + All[I].Name + '" fails validation: ' + Err)
    else
      WriteLn('  ok: built-in "' + All[I].Name + '" validates');
    if All[I].Name = 'software-team' then Found := True;
  end;
  AssertTrue(Found, 'software-team is in the catalogue');

  AssertTrue(FindTeamTemplate('software-team', T), 'software-team loads');
  AssertEqInt(Length(TeamLeads(T)), 1, 'software-team has exactly one lead');
  AssertEqStr(TeamLeads(T)[0], 'foreman', 'and it is the foreman');
  (* The wake list is NOT the lead list. Shipping a template whose wake
     list held only the foreman meant a worker holding an assigned task
     never ran: the lead cannot start another agent's turn, and nothing
     else was looking. Caught by a live probe; pinned here. *)
  AssertEqInt(Length(TeamWakeList(T)), 5,
              'the whole team is eligible to be woken, not just the lead');
  AssertContains(T.Agents[2].Role, 'app.json',
                 'the developer role carries the app recipe');
  AssertContains(T.Agents[0].Role, 'open_agent',
                 'the foreman role owns the screen');
  (* From driving the team by hand: with every task left todo, the UI
     reviewer and the tester were both woken to look at a project that
     had nothing in it yet. The mechanism was already right -- only
     todo/active wake an owner -- the lead was simply never told to use
     blocked. *)
  AssertContains(T.Agents[0].Role, 'BLOCKED',
                 'the foreman is told to block work that waits on other work');

  { ----------------------------------------------------------- validation -- }
  T2 := MiniTemplate;
  AssertTrue(ValidateTeamTemplate(T2, Err), 'a sound template validates');

  T2 := MiniTemplate; T2.Agents[1].Parent := 'nobody';
  AssertTrue(not ValidateTeamTemplate(T2, Err), 'a dangling parent is refused');
  AssertContains(Err, 'nobody', 'and named');

  T2 := MiniTemplate; T2.Agents[2].Name := 'boss';
  AssertTrue(not ValidateTeamTemplate(T2, Err), 'a duplicate agent is refused');

  T2 := MiniTemplate;
  T2.Agents[0].Parent := 'worker';   { boss -> worker -> mid -> boss }
  AssertTrue(not ValidateTeamTemplate(T2, Err), 'a reporting cycle is refused');

  T2 := MiniTemplate; T2.Agents[1].Model := 'gemini-3.5-flash';
  AssertTrue(not ValidateTeamTemplate(T2, Err),
             'a literal model id is refused where a tier belongs');
  AssertContains(Err, 'tier', 'and the error says tier');

  T2 := MiniTemplate;
  SetLength(T2.WakeWho, 1); T2.WakeWho[0] := 'stranger';
  AssertTrue(not ValidateTeamTemplate(T2, Err),
             'a wake list naming a stranger is refused');

  { -------------------------------------------------------------- seeding -- }
  T2 := MiniTemplate;
  AssertTrue(SeedTeam(T2, Created, Skipped, Err), 'seeding succeeds: ' + Err);
  AssertEqInt(Length(Created), 3, 'three agents created');
  AssertEqInt(Length(Skipped), 0, 'none skipped on a clean workspace');
  { Parents first: boss before mid before worker, whatever the listing
    order said. }
  AssertEqStr(Created[0], 'boss', 'the top of the chart is created first');
  AssertTrue(GetAgent('worker', Info), 'the worker exists');
  AssertEqStr(Info.Parent, 'mid', 'and reports to mid');

  { Idempotent, and an operator's edit survives. }
  Info.Role := 'Edited by the operator.';
  AssertTrue(SaveAgent(Info, Err) <> '', 'operator edits the worker');
  AssertTrue(SeedTeam(T2, Created, Skipped, Err), 'reseeding succeeds');
  AssertEqInt(Length(Created), 0, 'nothing recreated');
  AssertEqInt(Length(Skipped), 3, 'all three reported as kept');
  GetAgent('worker', Info);
  AssertEqStr(Info.Role, 'Edited by the operator.',
              'the edited role was NOT overwritten');

  (* ------------------------------------------------- goal -> project name -- *)
  (* From the live run: this goal became the project slug
     "a-book-comparison-app-enter-up-to-4-book-titles-and-compare-them",
     which then appeared in every path, task listing and message the
     team sent. The desktop's Ask path has always derived a short title
     from a brief; this is the same rule server-side. *)
  AssertEqStr(GoalToTitle('A book comparison app: enter up to 4 book ' +
                          'titles and compare them side by side'),
              'book comparison app', 'the goal that started this is trimmed');
  AssertEqStr(GoalToTitle('build me a stopwatch'), 'stopwatch',
              'the request framing and the article go');
  (* Parity with the desktop's deriveProjectTitle is the point, so
     these keep the trailing qualifier exactly as the client does: the
     title is already short, and trimming further would be this
     function inventing an opinion the desktop does not share. *)
  AssertEqStr(GoalToTitle('Please can you create an invoice tracker for ' +
                          'my shop'), 'invoice tracker for my shop',
              'the polite framing and the article go, the thing stays');
  AssertEqStr(GoalToTitle('I want a dashboard with charts and filters'),
              'dashboard with charts and filters',
              'a short-enough title is not trimmed further');
  AssertEqStr(GoalToTitle('an expense tracker'), 'expense tracker',
              '"an" is not read as "a" plus a stray "n"');
  AssertEqStr(GoalToTitle('Write a tool to rename photos. It should ' +
                          'handle EXIF.'), 'tool to rename photos',
              'the first sentence only');
  AssertEqStr(GoalToTitle('build a Node.js dashboard'), 'Node.js dashboard',
              'a dotted name is not a sentence end');
  AssertTrue(Length(GoalToTitle(StringOfChar('x', 200))) <= 48,
             'one enormous token is still bounded');
  AssertEqStr(GoalToTitle(''), '', 'nothing in, nothing out');
  AssertTrue(GoalToTitle('...') <> '', 'unusable input falls back to itself');

  { ------------------------------------------------------------- assignee -- }
  Proj := CreateProject('Team Board', '', '', Err);
  AssertEqStr(Proj, 'team-board', 'board project exists');
  TaskId := CreateTask(Proj, 'Build the thing', '', Err);
  AssertTrue(UpdateTask(Proj, TaskId, '', '-', '', Err, 'worker'),
             'assignee set through the store');
  GetTask(Proj, TaskId, Task);
  AssertEqStr(Task.Assignee, 'worker', 'assignee reads back');
  AssertTrue(UpdateTask(Proj, TaskId, '', '-', '', Err), 'update without assignee');
  GetTask(Proj, TaskId, Task);
  AssertEqStr(Task.Assignee, 'worker', 'the "-" default left it alone');

  Out_ := Tool_Task('{"action":"update","project":"' + Proj + '","id":"' +
                    TaskId + '","assignee":"mid"}', Err);
  AssertEqStr(Err, '', 'task tool sets assignee cleanly');
  GetTask(Proj, TaskId, Task);
  AssertEqStr(Task.Assignee, 'mid', 'tool-set assignee reads back');
  Out_ := Tool_Task('{"action":"list","project":"' + Proj + '"}', Err);
  AssertContains(Out_, '@mid', 'the board listing shows the owner');
  Out_ := Tool_Task('{"action":"update","project":"' + Proj + '","id":"' +
                    TaskId + '","assignee":""}', Err);
  GetTask(Proj, TaskId, Task);
  AssertEqStr(Task.Assignee, '', 'an explicit "" unassigns');

  { -------------------------------------------------------- wake decisions -- }
  S := Default(TTeamState);
  S.Name := 'mini'; S.Project := Proj; S.Enabled := True;
  S.WakeMinutes := 15;
  SetLength(S.WakeWho, 3);
  S.WakeWho[0] := 'boss'; S.WakeWho[1] := 'mid'; S.WakeWho[2] := 'worker';

  { boss: a pending message; worker: an assigned open task; mid: nothing. }
  AssertTrue(AgentSend('boss', 'operator', 'kickoff', Delivered, Err),
             'kickoff queued to boss');
  Out_ := Tool_Task('{"action":"update","project":"' + Proj + '","id":"' +
                    TaskId + '","assignee":"worker"}', Err);

  Wakes := TeamWakeDecisions(S);
  AssertEqInt(Length(Wakes), 3, 'a decision per wake-list agent');
  AssertTrue(Wakes[0].Wake, 'boss wakes (pending message)');
  AssertContains(Wakes[0].Why, 'message', 'and says why');
  AssertTrue(not Wakes[1].Wake, 'mid stays asleep');
  AssertContains(Wakes[1].Why, 'nothing to do', 'and says why');
  AssertTrue(Wakes[2].Wake, 'worker wakes (open assigned task)');
  AssertContains(Wakes[2].Why, 'assigned', 'and says why');

  { ----------------------------------------------------------- board done -- }
  AssertTrue(not TeamBoardDone(Proj), 'an open board is not done');
  Out_ := Tool_Task('{"action":"update","project":"' + Proj + '","id":"' +
                    TaskId + '","status":"done"}', Err);
  AssertTrue(TeamBoardDone(Proj), 'an all-done board is done');
  AssertTrue(not TeamBoardDone('no-such-project'), 'a missing board is not done');
  Proj := CreateProject('Empty Board', '', '', Err);
  AssertTrue(not TeamBoardDone(Proj),
             'an EMPTY board is "not started", never "finished"');

  { ---------------------------------------------------------------- state -- }
  AssertTrue(SaveTeamState(S, Err), 'state saves: ' + Err);
  AssertTrue(LoadTeamState('mini', S2), 'state loads');
  AssertEqStr(S2.Project, 'team-board', 'project survives');
  AssertTrue(S2.Enabled, 'enabled survives');
  AssertEqInt(S2.WakeMinutes, 15, 'cadence survives');
  AssertEqInt(Length(S2.WakeWho), 3, 'wake list survives');
  AssertTrue(TeamTickDue(S2), 'a never-ticked enabled team is due');
  S2.Enabled := False;
  AssertTrue(not TeamTickDue(S2), 'a parked team is never due');
  S2.Enabled := True; S2.LastTick := NowIsoUtc;
  AssertTrue(not TeamTickDue(S2), 'a just-ticked team is not due');
  (* ...but waiting mail skips the cadence. Without this a lead
     delegated and the whole team sat still until the next tick --
     measured at fifteen minutes, with the handoff the slowest thing
     in the system. *)
  AssertTrue(TeamHasWaitingMail(S2),
             'a just-ticked team with mail waiting is still due');
  AssertTrue(AgentSend('mid', 'boss', 'take T0001', Delivered, Err),
             'a second message queues');
  S2.Enabled := False;
  AssertTrue(not TeamHasWaitingMail(S2), 'a parked team ignores its mail');

  { ------------------------------------------------- user template override -- }
  AssertTrue(EnsureDir(WorkspaceSubdir('teams')), 'teams dir exists');
  WriteFileText(JoinPath(WorkspaceSubdir('teams'), 'duo.json'),
    '{"name":"duo","title":"My Duo","agents":[' +
    '{"name":"solo","title":"Solo","role":"Everything."}],' +
    '"wake":{"minutes":30}}');
  AssertTrue(FindTeamTemplate('duo', T2), 'duo still resolves');
  AssertEqStr(T2.Title, 'My Duo', 'the user file overrides the built-in');
  AssertEqInt(Length(T2.Agents), 1, 'with the user roster');
  AssertEqInt(T2.WakeMinutes, 30, 'and the user cadence');
  AssertTrue(FindTeamTemplate('software-team', T2),
             'unshadowed built-ins are untouched');

  { --------------------------------------------------------------- export -- }
  Out_ := ExportRosterJSON('my-team', 'My Team');
  AssertTrue(ParseTemplateJSON(Out_, T2), 'an export parses back as a template');
  AssertEqStr(T2.Name, 'my-team', 'with its name');
  AssertEqInt(Length(T2.Agents), 3, 'and the live roster');

  if Failures = 0 then
    WriteLn('teams_tests: OK')
  else
  begin
    WriteLn('teams_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
