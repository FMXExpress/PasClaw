program team_board_tests;
(*
  Pins Phases 2-5 of docs/team-board-plan.md (Phase 1, review, is
  team_review_tests).

  Phase 2 -- dependencies and "next":
    - waits_on names tasks on the same board; a self-edge, an unknown task
      and a cycle (direct or through other tasks) are refused when set.
    - ready is computed: a task is ready when everything it waits on is
      done, and only then is it offered by `next` or wakes its owner.
    - `next` claims the oldest ready task routed to the caller, else --
      for a taker -- the oldest ready unassigned one; concurrent claims
      never hand out the same task twice.
    - a claim carries a lease; the owner touching the task renews it;
      leaving active drops it; an expired lease whose holder runs no turn
      hands the task back (to the pool, when it came from there) and the
      lead is told.
    - closing a task tells the owners of tasks that were waiting on it.

  Runs against a temp PASCLAW_HOME; no network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes, SyncObjs,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Projects.Tools,
  PasClaw.Agents,
  PasClaw.Agents.Tools,
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

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then WriteLn('  ok: ' + Msg)
  else Fail(Msg + ' -- "' + Needle + '" not in: ' + Copy(Haystack, 1, 300));
end;

function Names(const A: array of string): TStringArray;
var
  I: Integer;
begin
  SetLength(Result, Length(A));
  for I := 0 to High(A) do Result[I] := A[I];
end;

procedure MakeAgent(const Name, Parent: string);
var
  Info: TAgentInfo;
  Err: string;
begin
  Info := Default(TAgentInfo);
  Info.Name := Name;
  Info.Title := Name;
  Info.Role := 'test agent';
  Info.Parent := Parent;
  if SaveAgent(Info, Err) = '' then Fail('could not create agent ' + Name + ': ' + Err);
end;

function Task_(const Project, Id: string): TTaskInfo;
begin
  if not GetTask(Project, Id, Result) then Fail('no task ' + Project + '/' + Id);
end;

(* Age a task's lease into the past -- the only way to test expiry without
   waiting it out. The test is not a model, so the board-records guard on
   the file tools does not apply to it. *)
procedure AgeLease(const Project, Id: string);
var
  Path: string;
  Obj: TJsonObject;
begin
  Path := JoinPath(TaskDir(Project, Id), 'task.json');
  Obj := TJsonObject.Parse(ReadFileText(Path));
  try
    Obj.PutStr('lease_until', '2000-01-01T00:00:00Z');
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

function NeverBusy(const Agent: string): Boolean;
begin
  Result := False;
end;

function AlwaysBusy(const Agent: string): Boolean;
begin
  Result := True;
end;

{ ------------------------------------------------------------- phase 2 -- }

procedure TestWaitsOn;
var
  Err, T1, T2, T3: string;
  Board: TTaskInfoArray;
begin
  WriteLn('-- waits_on');
  CreateProject('Deps', 'deps', '', Err);
  T1 := CreateTask('deps', 'Schema', '', Err);
  T2 := CreateTask('deps', 'API', '', Err);
  T3 := CreateTask('deps', 'UI', '', Err);
  AssertTrue(SetTaskWaitsOn('deps', T2, Names([T1]), 'foreman', Err), 'API waits on Schema: ' + Err);
  AssertTrue(SetTaskWaitsOn('deps', T3, Names(['t0002']), 'foreman', Err),
             'UI waits on API (ids are case-folded)');
  Board := ListTasks('deps');
  AssertTrue(not TaskReady(Board[1], Board), 'API is not ready while Schema is open');
  AssertTrue((Length(TaskWaitingOn(Board[2], Board)) = 1) and
             (TaskWaitingOn(Board[2], Board)[0] = T2), 'UI waits on API');

  AssertTrue(not SetTaskWaitsOn('deps', T1, Names([T1]), 'foreman', Err), 'a task cannot wait on itself');
  AssertTrue(not SetTaskWaitsOn('deps', T1, Names(['T0099']), 'foreman', Err),
             'nor on a task that is not on the board');
  AssertContains(Err, 'no such task', 'and is told why');
  AssertTrue(not SetTaskWaitsOn('deps', T1, Names([T2]), 'foreman', Err), 'a direct cycle is refused');
  AssertContains(Err, 'cycle', 'naming it');
  AssertTrue(not SetTaskWaitsOn('deps', T1, Names([T3]), 'foreman', Err),
             'and so is one through another task (Schema -> UI -> API -> Schema)');
  AssertTrue(Length(Task_('deps', T1).WaitsOn) = 0, 'a refused edge is not written');

  UpdateTask('deps', T1, '', '-', 'done', Err);
  Board := ListTasks('deps');
  AssertTrue(TaskReady(Board[1], Board), 'Schema done: API is ready');
  AssertTrue(not TaskReady(Board[2], Board), 'and UI still is not -- readiness is not transitive');
  AssertTrue(SetTaskWaitsOn('deps', T3, Names([]), 'foreman', Err), 'an empty list clears it');
  Board := ListTasks('deps');
  AssertTrue(TaskReady(Board[2], Board), 'and the task is ready');
end;

procedure TestNext;
var
  Err, A, B, C, Pool1, Got: string;
  T: TTaskInfo;
begin
  WriteLn('-- next');
  CreateProject('Queue', 'queue', '', Err);
  A := CreateTask('queue', 'First, but waiting', '', Err);
  B := CreateTask('queue', 'Second, ready', '', Err);
  C := CreateTask('queue', 'Prerequisite', '', Err);
  UpdateTask('queue', A, '', '-', '', Err, 'dev');
  UpdateTask('queue', B, '', '-', '', Err, 'dev');
  SetTaskWaitsOn('queue', A, Names([C]), 'foreman', Err);

  AssertTrue(ClaimNextTask('queue', 'dev', False, Got, Err), 'dev claims');
  AssertEqStr(Got, B, 'the oldest READY task, skipping an older one that waits');
  T := Task_('queue', B);
  AssertTrue(T.Status = tsActive, 'the claim makes it active');
  AssertEqStr(T.LeaseBy, 'dev', 'and leases it to dev');
  AssertTrue(T.LeaseUntil > NowIsoUtc, 'until a time in the future');
  AssertTrue(not ClaimNextTask('queue', 'dev', False, Got, Err), 'nothing else is ready');
  AssertEqStr(Err, '', 'which is not an error');

  UpdateTask('queue', C, '', '-', 'done', Err);
  AssertTrue(ClaimNextTask('queue', 'dev', False, Got, Err) and (Got = A),
             'once its prerequisite is done, the waiting task is offered');

  Pool1 := CreateTask('queue', 'Anyone can do this', '', Err);
  AssertTrue(not ClaimNextTask('queue', 'ui', False, Got, Err),
             'an agent that takes routed work does not get unassigned tasks');
  AssertTrue(ClaimNextTask('queue', 'ui', True, Got, Err) and (Got = Pool1),
             'a taker does');
  T := Task_('queue', Pool1);
  AssertEqStr(T.Assignee, 'ui', 'and owns it');
  AssertEqStr(T.ClaimedFrom, 'pool', 'remembering where it came from');
  AssertTrue(not ClaimNextTask('queue', '', True, Got, Err), 'next needs a named agent');
  AssertTrue(Err <> '', 'and says so');
end;

type
  TClaimer = class(TThread)
  protected
    procedure Execute; override;
  public
    Agent, Got: string;
    Go: TEvent;
    constructor Create(const AAgent: string; AGo: TEvent);
  end;

constructor TClaimer.Create(const AAgent: string; AGo: TEvent);
begin
  Agent := AAgent;
  Go := AGo;
  inherited Create(False);
end;

procedure TClaimer.Execute;
var
  Err: string;
begin
  Go.WaitFor(5000);
  if not ClaimNextTask('race', Agent, True, Got, Err) then Got := '';
end;

procedure TestConcurrentClaims;
var
  Err: string;
  Go: TEvent;
  Th: array[0..7] of TClaimer;
  I, J, Claimed: Integer;
  Dup: Boolean;
begin
  WriteLn('-- concurrent claims');
  CreateProject('Race', 'race', '', Err);
  for I := 1 to 3 do CreateTask('race', 'Pool task ' + IntToStr(I), '', Err);
  Go := TEvent.Create(nil, True, False, '');
  try
    for I := 0 to High(Th) do Th[I] := TClaimer.Create('worker-' + IntToStr(I), Go);
    Go.SetEvent;
    for I := 0 to High(Th) do Th[I].WaitFor;
    Claimed := 0;
    Dup := False;
    for I := 0 to High(Th) do
      if Th[I].Got <> '' then
      begin
        Inc(Claimed);
        for J := 0 to I - 1 do
          if Th[J].Got = Th[I].Got then Dup := True;
      end;
    AssertTrue(Claimed = 3, 'eight agents asking at once claim the three tasks there are');
    AssertTrue(not Dup, 'and no task is handed out twice');
  finally
    for I := 0 to High(Th) do Th[I].Free;
    Go.Free;
  end;
end;

procedure TestLeases;
var
  Err, A, P, Got: string;
  T: TTaskInfo;
  Expired: TStringArray;
begin
  WriteLn('-- leases');
  CreateProject('Leases', 'leases', '', Err);
  A := CreateTask('leases', 'Routed work', '', Err);
  UpdateTask('leases', A, '', '-', '', Err, 'dev');
  AssertTrue(UpdateTask('leases', A, '', '-', 'active', Err, '-', '-', 'dev'),
             'dev starts its task');
  AssertEqStr(Task_('leases', A).LeaseBy, 'dev', 'starting takes a lease');

  AgeLease('leases', A);
  UpdateTask('leases', A, '', 'halfway', '', Err, '-', '-', 'dev');
  AssertTrue(Task_('leases', A).LeaseUntil > NowIsoUtc, 'the owner touching it renews the lease');

  AgeLease('leases', A);
  UpdateTask('leases', A, '', 'drive-by note', '', Err, '-', '-', 'ui');
  AssertTrue(Task_('leases', A).LeaseUntil < NowIsoUtc, 'someone else touching it does not');

  Expired := ExpireLeases('leases', AlwaysBusy);
  AssertTrue(Length(Expired) = 0, 'a holder that is mid-turn keeps its claim, whatever the clock');
  Expired := ExpireLeases('leases', NeverBusy);
  AssertTrue((Length(Expired) = 1) and (Expired[0] = A + ' dev'), 'an idle holder''s expired claim is handed back');
  T := Task_('leases', A);
  AssertTrue(T.Status = tsTodo, 'back to todo');
  AssertEqStr(T.Assignee, 'dev', 'still dev''s -- it was routed to dev');
  AssertEqStr(T.LeaseBy, '', 'with no lease');

  P := CreateTask('leases', 'Pool work', '', Err);
  ClaimNextTask('leases', 'ui', True, Got, Err);
  AssertEqStr(Got, P, 'ui claims from the pool');
  AgeLease('leases', P);
  ExpireLeases('leases', NeverBusy);
  T := Task_('leases', P);
  AssertTrue((T.Status = tsTodo) and (T.Assignee = ''),
             'a pool claim that expires goes back to the pool');

  { Leaving active drops the lease; a reject leases it to the owner again. }
  UpdateTask('leases', A, '', '-', 'active', Err, '-', '-', 'dev');
  SubmitTask('leases', A, 'dev', 'did it', '', Err);
  AssertEqStr(Task_('leases', A).LeaseBy, '', 'a submission is not a lease a dead run can hold');
  VerdictTask('leases', A, 'qa', False, 'not quite', Names([]), Err);
  T := Task_('leases', A);
  AssertTrue((T.Status = tsActive) and (T.LeaseBy = 'dev'), 'a reject leases it back to its owner');
  AssertTrue(Length(ReadActivity('leases', P)) > 0, 'expiry left receipts');
end;

procedure TestNotifyAndWake;
var
  Err, Pre, Dep, Out_: string;
  S: TTeamState;
  W: TWakeReasonArray;
  T: TTeamTemplate;
  I: Integer;
  OwnerWoken, TakerWoken: Boolean;
  Swept: TStringArray;
begin
  WriteLn('-- the board tells dependents, and wakes on readiness');
  MakeAgent('n-lead', '');
  MakeAgent('n-dev', 'n-lead');
  MakeAgent('n-any', 'n-lead');
  CreateProject('Notify', 'notify', '', Err);
  Pre := CreateTask('notify', 'Prerequisite', '', Err);
  Dep := CreateTask('notify', 'Dependent', '', Err);
  UpdateTask('notify', Dep, '', '-', '', Err, 'n-dev');
  SetTaskWaitsOn('notify', Dep, Names([Pre]), 'n-lead', Err);

  S := Default(TTeamState);
  S.Name := 'notify-team';
  S.Project := 'notify';
  S.Enabled := True;
  S.WakeWho := Names(['n-lead', 'n-dev', 'n-any']);
  W := TeamWakeDecisions(S);
  OwnerWoken := False;
  for I := 0 to High(W) do
    if (W[I].Agent = 'n-dev') and W[I].Wake then OwnerWoken := True;
  AssertTrue(not OwnerWoken, 'the owner of a task that is still waiting is not woken');

  AssertTrue(AgentPending('n-dev') = 0, 'no mail yet');
  UpdateTask('notify', Pre, '', '-', 'done', Err);
  AssertTrue(AgentPending('n-dev') > 0, 'closing the prerequisite tells the dependent''s owner');
  W := TeamWakeDecisions(S);
  OwnerWoken := False;
  for I := 0 to High(W) do
    if (W[I].Agent = 'n-dev') and W[I].Wake then OwnerWoken := True;
  AssertTrue(OwnerWoken, 'and it is woken');

  { A taker is offered ready unassigned work. }
  AssertTrue(ParseTemplateJSON('{"name":"notify-team","agents":[' +
    '{"name":"n-lead","role":"r"},{"name":"n-dev","role":"r","parent":"n-lead"},' +
    '{"name":"n-any","role":"r","parent":"n-lead","takes":"any"}]}', T),
    'a template with a taker parses');
  AssertTrue(ValidateTeamTemplate(T, Err), 'and validates: ' + Err);
  AssertTrue(BindTeamBoard(T, 'notify', Err), 'binding it records the takers');
  AssertTrue((Length(ProjectTakers('notify')) = 1) and (ProjectTakers('notify')[0] = 'n-any'),
             'n-any takes from the pool');
  CreateTask('notify', 'Up for grabs', '', Err);
  W := TeamWakeDecisions(S);
  TakerWoken := False;
  for I := 0 to High(W) do
    if (W[I].Agent = 'n-any') and W[I].Wake then
    begin
      TakerWoken := True;
      AssertContains(W[I].Why, 'unassigned', 'for the unassigned work');
    end;
  AssertTrue(TakerWoken, 'the taker is woken for ready unassigned work');

  AssertTrue(ParseTemplateJSON('{"name":"bad","agents":[{"name":"a","role":"r",' +
    '"takes":"everything"}]}', T) and not ValidateTeamTemplate(T, Err),
    'an unknown takes value is refused');
  AssertContains(Err, 'routed', 'naming the legal values');

  { The tick hands back a dead run's claim and tells the lead. }
  SetCallingAgent('n-dev');
  Out_ := Tool_Task('{"action":"next","project":"notify"}', Err);
  AssertContains(Out_, 'Claimed ' + Dep, 'n-dev claims the now-ready task through the tool');
  SetCallingAgent('');
  AgeLease('notify', Dep);
  ParseTemplateJSON('{"name":"notify-team","agents":[{"name":"n-lead","role":"r"},' +
    '{"name":"n-dev","role":"r","parent":"n-lead"}]}', T);
  Swept := TeamExpireLeases(T, S);
  AssertTrue(Length(Swept) = 1, 'the tick hands it back');
  AssertContains(Swept[0], 'n-lead', 'and tells the lead');
  AssertTrue(AgentPending('n-lead') > 0, 'who has the message');
end;

procedure TestTool;
var
  Err, Out_: string;
begin
  WriteLn('-- the task tool');
  CreateProject('Tool Deps', 'tool-deps', '', Err);
  SetCallingAgent('t-lead');
  Tool_Task('{"action":"create","project":"tool-deps","title":"One"}', Err);
  Out_ := Tool_Task('{"action":"create","project":"tool-deps","title":"Two",' +
                    '"waits_on":"T0001"}', Err);
  AssertContains(Out_, 'waits on T0001', 'create takes waits_on as a string');
  Out_ := Tool_Task('{"action":"create","project":"tool-deps","title":"Three",' +
                    '"waits_on":["T0001","T0002"],"assignee":"t-dev"}', Err);
  AssertContains(Out_, 'waits on T0001, T0002', 'or as a list');
  Out_ := Tool_Task('{"action":"update","project":"tool-deps","id":"T0001",' +
                    '"waits_on":["T0003"]}', Err);
  AssertContains(Err, 'cycle', 'a cycle is refused through the tool');
  Tool_Task('{"action":"update","project":"tool-deps","id":"T0003","assignee":"t-dev"}', Err);
  Out_ := Tool_Task('{"action":"list","project":"tool-deps"}', Err);
  AssertContains(Out_, 'waits on T0001, T0002 (not done yet)', 'the board says what is not ready');

  SetCallingAgent('t-dev');
  Out_ := Tool_Task('{"action":"next","project":"tool-deps"}', Err);
  AssertContains(Out_, 'Nothing is ready', 'nothing ready for t-dev');
  AssertContains(Out_, 'T0003 waits on', 'and it says what its task waits on');
  AssertContains(Out_, 'lead''s to hand out', 'and that unassigned work is routed');
  SetCallingAgent('');
  Out_ := Tool_Task('{"action":"next","project":"tool-deps"}', Err);
  AssertContains(Err, 'named agent', 'next from a turn that is not an agent''s is refused');
end;

begin
  TestWaitsOn;
  TestNext;
  TestConcurrentClaims;
  TestLeases;
  TestNotifyAndWake;
  TestTool;

  if Failures = 0 then
    WriteLn('team_board_tests: OK')
  else
  begin
    WriteLn('team_board_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
