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
  PasClaw.Decisions,
  PasClaw.Tools.Sandbox,
  PasClaw.Projects.Snapshots,
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

{ ------------------------------------------------------------- phase 3 -- }

procedure TestDecisionStore;
var
  Err, Id, Id2, R, Ans: string;
  D: TDecisionInfo;
begin
  WriteLn('-- decisions');
  AssertEqStr(NormalizeDecisionId('D12'), 'D0012', 'D12 is D0012');
  AssertEqStr(NormalizeDecisionId('d0012'), 'D0012', 'case and padding fold');
  AssertEqStr(NormalizeDecisionId('Dave'), '', 'a word is not an id');
  AssertEqStr(NormalizeDecisionId('D0'), '', 'nor is zero');

  Id := CreateDecision('question', 'lead', 'Spend $40 on a domain?',
                       Names(['yes', 'no']), '', '', '', '', Err);
  AssertEqStr(Id, 'D0001', 'the first decision');
  Id2 := CreateDecision('question', 'lead', 'Which colour?', Names([]), '', '', '', '', Err);
  AssertEqStr(Id2, 'D0002', 'ids increment');
  AssertTrue(CreateDecision('question', 'lead', '  ', Names([]), '', '', '', '', Err) = '',
             'a decision needs a question');
  AssertTrue(Length(ListDecisions(True)) = 2, 'two open');

  AssertTrue(not AnswerDecision(Id, 'maybe', 'operator', Err), 'an answer outside the choices is refused');
  AssertContains(Err, 'yes, no', 'and the choices are named');
  AssertTrue(AnswerDecision(Id, 'YES', 'operator', Err), 'a choice matches case-insensitively');
  AssertTrue(GetDecision(Id, D) and (D.Answer = 'yes') and (D.Status = 'answered'),
             'stored as the choice is written');
  AssertTrue(not AnswerDecision(Id, 'no', 'operator', Err), 'an answered decision is not re-answered');
  AssertContains(Err, 'already answered', 'because the asker may have acted');
  AssertTrue(Length(ListDecisions(True)) = 1, 'one left open');

  AssertTrue(ParseDecisionReply('D2 teal', R, Ans) and (R = 'D0002') and (Ans = 'teal'),
             '"D2 teal" is a reply');
  AssertTrue(ParseDecisionReply('d0002: a nice teal', R, Ans) and (Ans = 'a nice teal'),
             '"d0002: ..." too');
  AssertTrue(not ParseDecisionReply('D2teal', R, Ans), 'the id has to end');
  AssertTrue(not ParseDecisionReply('Dave says hi', R, Ans), 'a sentence is not a reply');
  AssertTrue(not ParseDecisionReply('D2', R, Ans), 'an id with no answer is not one');

  AssertTrue(HandleDecisionReply('D2 teal', 'telegram:999', ['telegram:123'], R),
             'a reply from someone not in answer_from is handled');
  AssertContains(R, 'answer_from', 'refused, saying why');
  AssertTrue(GetDecision(Id2, D) and (D.Status = 'open'), 'and the decision stays open');
  AssertTrue(HandleDecisionReply('D2 teal', 'telegram:999', [], R) and
             (Pos('not answered', R) > 0), 'an empty answer_from refuses every chat');
  AssertTrue(HandleDecisionReply('D2 teal', 'telegram:123', ['telegram:123'], R),
             'a named sender answers it');
  AssertTrue(GetDecision(Id2, D) and (D.Answer = 'teal') and (D.AnsweredBy = 'telegram:123'),
             'recorded with who answered');
  AssertTrue(not HandleDecisionReply('D77 yes', 'telegram:123', ['telegram:123'], R),
             'a "D77" that is not a decision goes on to the model');
  AssertTrue(not CanWritePath(JoinPath(DecisionsDir, 'D0002.json'), R),
             'the file tools cannot write a decision -- an agent cannot answer its own');
end;

procedure TestAskOperator;
var
  Err, Out_, Tid: string;
  List: TDecisionInfoArray;
  D: TDecisionInfo;
  Before: Integer;
begin
  WriteLn('-- ask_operator');
  MakeAgent('a-lead', '');
  MakeAgent('a-dev', 'a-lead');
  CreateProject('Asks', 'asks', '', Err);
  Tid := CreateTask('asks', 'Buy the domain', 'register it', Err);
  UpdateTask('asks', Tid, '', '-', 'active', Err, 'a-lead', '-', 'a-lead');
  Before := Length(ListDecisions(False));

  SetCallingAgent('a-dev');
  Out_ := Tool_Agent('{"action":"ask_operator","question":"Buy example.dev for $40?",' +
                     '"choices":["yes","no"]}', Err);
  AssertEqStr(Err, '', 'a worker asks');
  AssertContains(Out_, '"escalated_to"', 'and it is routed up the chain');
  AssertContains(Out_, 'a-lead', 'to its lead');
  AssertTrue(Length(ListDecisions(False)) = Before, 'no decision reaches the operator');
  AssertTrue(AgentPending('a-lead') > 0, 'the lead has it in its mailbox');

  SetCallingAgent('a-lead');
  Out_ := Tool_Agent('{"action":"ask_operator","question":"Buy example.dev for $40? I recommend yes.",' +
                     '"choices":["yes","no"],"project":"asks","task":"' + Tid + '"}', Err);
  AssertEqStr(Err, '', 'the lead asks the operator');
  AssertContains(Out_, '"decision"', 'which makes a decision');
  List := ListDecisions(True);
  D := List[High(List)];
  AssertEqStr(D.AskedBy, 'a-lead', 'asked by the lead');
  AssertTrue(Task_('asks', Tid).Status = tsBlocked, 'the task it holds up is blocked');
  AssertContains(Task_('asks', Tid).Notes, D.Id, 'saying what it waits on');

  AssertTrue(AnswerDecision(D.Id, 'yes', 'operator', Err), 'the operator answers');
  AssertTrue(Task_('asks', Tid).Status = tsActive, 'the task goes back to what it was doing');
  AssertTrue(AgentPending('a-lead') > 0, 'and the lead hears the answer');

  SetCallingAgent('');
  Out_ := Tool_Agent('{"action":"ask_operator","question":"anything?"}', Err);
  AssertContains(Err, 'standing agents', 'a turn that is not an agent''s is told to ask in its reply');
end;

{ ------------------------------------------------------------- phase 4 -- }

procedure WriteApp(const Project, Html: string);
begin
  ForceDirectories(ProjectAppDir(Project));
  WriteFileText(JoinPath(ProjectAppDir(Project), 'index.html'), Html);
end;

function Has(const Name: string; const List: TStringArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(List) do
    if List[I] = Name then Exit(True);
end;

procedure TestRules;
var
  Err, T1, T2, T3, Out_, Snap, Rep: string;
  S: TTeamState;
  List: TDecisionInfoArray;
  D: TDecisionInfo;
  Lines: TStringArray;
  Mail: Integer;
begin
  WriteLn('-- causes, snapshots and proven rules');
  MakeAgent('foreman', '');
  MakeAgent('r-dev', 'foreman');
  MakeAgent('r-qa', 'foreman');
  CreateProject('Rules', 'rules', '', Err);
  SetProjectReview('rules', True, Names(['r-qa']), Err);
  { A team on the board, so a repeated cause has a lead to tell (duo's
    lead is the foreman). Parked: nothing here runs turns. }
  S := Default(TTeamState);
  S.Name := 'duo';
  S.Project := 'rules';
  SaveTeamState(S, Err);

  T1 := CreateTask('rules', 'Signup form', '', Err);
  UpdateTask('rules', T1, '', '-', 'active', Err, 'r-dev', '-', 'r-dev');
  WriteApp('rules', '<form><input name=email></form>');
  AssertTrue(SubmitTask('rules', T1, 'r-dev', 'form renders', '', Err), 'submitted');
  AssertEqStr(Task_('rules', T1).SubmittedSnapshot, 'S0001', 'the submission is snapshotted');
  Snap := SnapshotDir('rules', T1, 'S0001');
  AssertTrue(FileExists(JoinPath(JoinPath(Snap, 'app'), 'index.html')), 'with the app as it was');
  AssertTrue(not DirectoryExists(JoinPath(Snap, 'tasks')), 'and without the board''s records');
  AssertTrue(Pos(ActiveWorkspaceRoot, ExpandFileName(Snap)) <> 1, 'outside the workspace');
  AssertTrue(not CanWritePath(JoinPath(JoinPath(Snap, 'app'), 'index.html'), Rep),
             'and out of the file tools'' reach');

  AssertTrue(VerdictTask('rules', T1, 'r-qa', False, 'email is not required',
                         Names(['r-qa']), Err, 'Missing Required'), 'rejected with a cause');
  AssertEqStr(Task_('rules', T1).VerdictCause, 'missing-required', 'the cause is slugged');
  Lines := ReadActivity('rules', T1);
  AssertContains(Lines[High(Lines)], 'missing-required', 'and on the receipt');
  AssertContains(Lines[High(Lines)], 'S0001', 'with the snapshot it was given on');
  AssertTrue(AgentPending('foreman') = 0, 'one reject is not a pattern');

  WriteApp('rules', '<form><input name=email required></form>');
  SubmitTask('rules', T1, 'r-dev', 'email required now', '', Err);
  AssertEqStr(Task_('rules', T1).SubmittedSnapshot, 'S0002', 'a resubmission has its own snapshot');
  VerdictTask('rules', T1, 'r-qa', True, '', Names(['r-qa']), Err);

  T2 := CreateTask('rules', 'Login form', '', Err);
  UpdateTask('rules', T2, '', '-', 'active', Err, 'r-dev', '-', 'r-dev');
  WriteApp('rules', '<form><input name=pass></form>');
  SubmitTask('rules', T2, 'r-dev', 'login renders', '', Err);
  VerdictTask('rules', T2, 'r-qa', False, 'password not required', Names(['r-qa']),
              Err, 'missing-required');
  AssertTrue(AgentPending('foreman') > 0, 'the second reject for one cause tells the lead');

  SetCallingAgent('foreman');
  Out_ := Tool_Rule('{"action":"draft","project":"rules","cause":"missing-required",' +
                    '"script":"exit 0"}', Err);
  AssertContains(Err, 'does not catch', 'a check that passes everything is not proven');
  Out_ := Tool_Rule('{"action":"draft","project":"rules","cause":"missing-required",' +
                    '"script":"exit 1"}', Err);
  AssertContains(Err, 'reject good work', 'nor is one that fails everything');
  Out_ := Tool_Rule('{"action":"draft","project":"rules","cause":"never-seen",' +
                    '"script":"exit 0"}', Err);
  AssertContains(Err, 'nothing to prove', 'a cause with no rejected-then-accepted task cannot be proven');
  Out_ := Tool_Rule('{"action":"draft","project":"rules","cause":"missing-required",' +
                    '"name":"inputs-required.sh","script":"grep -q required app/index.html"}', Err);
  AssertEqStr(Err, '', 'a real check is proven');
  AssertContains(Out_, 'waiting for the operator', 'and waits for the operator');
  Tool_Rule('{"action":"draft","project":"rules","cause":"missing-required",' +
            '"script":"grep -q required app/index.html"}', Err);
  AssertContains(Err, 'already proposes', 'one draft per cause at a time');
  List := ListDecisions(True);
  D := List[High(List)];
  AssertEqStr(D.Kind, 'rule', 'the draft is a rule decision');
  AssertContains(D.Payload, 'grep -q required', 'carrying the script the operator will read');
  AssertTrue(not FileExists(JoinPath(ProjectScenariosDir('rules'), 'inputs-required.sh')),
             'nothing is installed before approval');

  AssertTrue(AnswerDecision(D.Id, 'approve', 'operator', Err), 'the operator approves');
  AssertTrue(FileExists(JoinPath(ProjectScenariosDir('rules'), 'inputs-required.sh')),
             'and it joins the project''s held-out checks');
  AssertTrue(Has('missing-required', ProjectCauses('rules', 'rule_causes')),
             'the cause is recorded as ruled');
  AssertTrue(not SubmitTask('rules', T2, 'r-dev', 'trying again', '', Err),
             'from now on, a submit that makes the mistake is refused');
  AssertContains(Err, 'held-out', 'by the gate');
  WriteApp('rules', '<form><input name=pass required></form>');
  AssertTrue(SubmitTask('rules', T2, 'r-dev', 'password required now', '', Err),
             'and the fixed work goes through');
  VerdictTask('rules', T2, 'r-qa', True, '', Names(['r-qa']), Err);

  { Decline: recorded, and the cause stops nagging. }
  T3 := CreateTask('rules', 'Labels', '', Err);
  UpdateTask('rules', T3, '', '-', 'active', Err, 'r-dev', '-', 'r-dev');
  WriteApp('rules', '<form><input name=pass required></form>');
  SubmitTask('rules', T3, 'r-dev', 'v1', '', Err);
  VerdictTask('rules', T3, 'r-qa', False, 'no label', Names(['r-qa']), Err, 'no-label');
  WriteApp('rules', '<form><label>Pass</label><input name=pass required></form>');
  SubmitTask('rules', T3, 'r-dev', 'v2', '', Err);
  VerdictTask('rules', T3, 'r-qa', True, '', Names(['r-qa']), Err);
  Tool_Rule('{"action":"draft","project":"rules","cause":"no-label",' +
            '"script":"grep -q label app/index.html"}', Err);
  AssertEqStr(Err, '', 'a second cause is proven too');
  List := ListDecisions(True);
  D := List[High(List)];
  AssertTrue(AnswerDecision(D.Id, 'decline', 'operator', Err), 'the operator declines');
  AssertTrue(Has('no-label', ProjectCauses('rules', 'declined_causes')), 'and that is recorded');
  AssertTrue(not FileExists(JoinPath(ProjectScenariosDir('rules'), 'no-label.sh')),
             'nothing installed');
  Mail := AgentPending('foreman');
  UpdateTask('rules', T3, '', '-', 'todo', Err);
  UpdateTask('rules', T3, '', '-', 'active', Err, '-', '-', 'r-dev');
  SubmitTask('rules', T3, 'r-dev', 'v3', '', Err);
  VerdictTask('rules', T3, 'r-qa', False, 'still no label', Names(['r-qa']), Err, 'no-label');
  AssertTrue(AgentPending('foreman') = Mail, 'a declined cause does not nag again');

  { The operator's own rule is proven and goes straight in. }
  AssertTrue(ProposeRule('rules', 'no-label', 'labels.sh', 'grep -q label app/index.html',
                         ActorOperator, True, Rep, Err), 'the operator writes a rule directly: ' + Err);
  AssertTrue(FileExists(JoinPath(ProjectScenariosDir('rules'), 'labels.sh')), 'installed');
  Out_ := Tool_Rule('{"action":"list","project":"rules"}', Err);
  AssertContains(Out_, 'inputs-required.sh', 'list shows the rules');
  AssertContains(Out_, '"rejects" : 2', 'and how often each cause rejected work');
  SetCallingAgent('');
end;

begin
  TestWaitsOn;
  TestNext;
  TestConcurrentClaims;
  TestLeases;
  TestNotifyAndWake;
  TestTool;
  TestDecisionStore;
  TestAskOperator;
  TestRules;

  if Failures = 0 then
    WriteLn('team_board_tests: OK')
  else
  begin
    WriteLn('team_board_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
