program team_review_tests;
(*
  Pins Phase 1 of docs/team-board-plan.md: the board holds the review
  rule instead of the role prompts.

    - review is a state a task enters by being SUBMITTED, with evidence,
      and leaves only by a verdict -- never from its submitter or owner,
      never from a caller that cannot be identified, and (when the team
      named reviewers) only from one of them. The operator can do
      anything, and it is recorded as theirs.
    - on a board that requires review an agent cannot mark work done, and
      a finished job submits instead of closing.
    - criteria are written by someone other than the builder, while the
      task waits, and freeze once work starts; a reopen unfreezes them.
    - every move leaves a receipt in activity.jsonl, attributed.
    - the operator's held-out scenarios gate a submission.
    - the file tools cannot rewrite the board's records around all of it.
    - teams: review.by, review on for a team's board, who reviews what,
      and the wake loop waking the reviewer rather than the owner.
    - the caller identity reaches the `task` tool through the real tool
      loop, on the thread that set it and no other.

  Runs against a temp PASCLAW_HOME; no network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Projects.Tools,
  PasClaw.Agents,
  PasClaw.Agents.Tools,
  PasClaw.Teams,
  PasClaw.Tools.Sandbox,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop;

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

{ ------------------------------------------------------------------ store -- }

(* "event:by event:by ..." for one task's receipts -- the whole trail in a
   string an assertion can read. *)
function EventTrail(const Project, TaskId: string): string;
var
  Lines: TStringArray;
  I: Integer;
  Obj: TJsonObject;
begin
  Result := '';
  Lines := ReadActivity(Project, TaskId);
  for I := 0 to High(Lines) do
  begin
    Obj := TJsonObject.Parse(Lines[I]);
    try
      if Result <> '' then Result := Result + ' ';
      Result := Result + Obj.GetStr('event', '?') + ':' + Obj.GetStr('by', '?');
    finally
      Obj.Free;
    end;
  end;
end;

procedure TestStoreRules;
var
  Err, T1, T2, T3: string;
  P: TProjectInfo;
  T: TTaskInfo;
  Qa: TStringArray;
begin
  WriteLn('-- store: review, verdicts, frozen criteria');
  AssertEqStr(CreateProject('Review Board', 'board', '', Err), 'board', 'a board');
  AssertTrue(not ProjectRequiresReview('board'), 'a hand-made project does not require review');
  AssertTrue(SetProjectReview('board', True, Names(['QA']), Err), 'review switched on: ' + Err);
  AssertTrue(GetProject('board', P), 'it loads');
  AssertTrue(P.Review, 'and requires review');
  AssertTrue((Length(P.Reviewers) = 1) and (P.Reviewers[0] = 'qa'),
             'reviewers are stored as slugs');
  Qa := Names(['qa']);

  T1 := CreateTask('board', 'Build the form', 'a form for rows', Err,
                   'empty title is refused'#10'save adds a row', 'pm');
  AssertTrue(T1 <> '', 'task created with criteria');
  AssertTrue(GetTask('board', T1, T), 'it loads');
  AssertContains(T.Criteria, 'save adds a row', 'criteria stored apart from notes');
  AssertTrue(UpdateTask('board', T1, '', '-', '', Err, 'dev', '-', 'foreman'),
             'the lead assigns it');

  AssertTrue(not UpdateTask('board', T1, '', '-', 'review', Err), '"review" is not a settable status');
  AssertContains(Err, 'action="submit"', 'and the refusal names the submit');

  AssertTrue(not UpdateTask('board', T1, '', '-', '', Err, '-', 'whatever passes', 'dev'),
             'the builder does not write its own criteria');
  AssertContains(Err, 'builder', 'and is told why');
  AssertTrue(UpdateTask('board', T1, '', '-', '', Err, '-',
             'empty title is refused'#10'save adds a row'#10'reload keeps it', 'pm'),
             'someone else may, while it waits: ' + Err);

  AssertTrue(UpdateTask('board', T1, '', '-', 'active', Err, '-', '-', 'dev'), 'the builder starts');
  AssertTrue(GetTask('board', T1, T) and (T.Started <> ''), 'starting stamps started');
  AssertTrue(not UpdateTask('board', T1, '', '-', '', Err, '-', 'a lower bar', 'pm'),
             'once started, the criteria are frozen for agents');
  AssertContains(Err, 'frozen', 'and the refusal says so');
  AssertTrue(UpdateTask('board', T1, '', '-', '', Err, '-',
             'empty title is refused'#10'save adds a row'#10'reload keeps it'#10 +
             'works offline', ActorOperator),
             'the operator can still edit them');
  AssertTrue(GetTask('board', T1, T) and (Pos('offline', T.Criteria) > 0),
             'and the edit landed');

  AssertTrue(not UpdateTask('board', T1, '', '-', 'done', Err, '-', '-', 'dev'),
             'an agent cannot mark work done on a reviewed board');
  AssertContains(Err, 'action="submit"', 'and is shown the submit instead');
  AssertTrue(not UpdateTask('board', T1, '', '-', 'done', Err, '-', '-', ActorModel),
             'nor can an unattributed model turn -- it is not the operator');

  AssertTrue(not SubmitTask('board', T1, 'dev', '  ', '', Err), 'a submission needs evidence');
  AssertContains(Err, 'evidence', 'and says so');
  AssertTrue(SubmitTask('board', T1, 'dev', 'ran it: 3 rows saved, empty title refused', '', Err),
             'submitted: ' + Err);
  AssertTrue(GetTask('board', T1, T) and (T.Status = tsReview), 'it is in review');
  AssertEqStr(T.SubmittedBy, 'dev', 'submitted by the builder');
  AssertContains(T.Evidence, '3 rows', 'with the evidence');
  AssertTrue(not SubmitTask('board', T1, 'dev', 'again', '', Err), 'a second submit is refused');
  AssertContains(Err, 'already waiting', 'because it is already waiting');
  AssertTrue(not UpdateTask('board', T1, '', '-', 'active', Err, '-', '-', 'dev'),
             'the builder cannot pull it back out of review');
  AssertContains(Err, 'waiting for a verdict', 'only a verdict moves it');

  AssertTrue(not VerdictTask('board', T1, 'dev', True, '', Qa, Err),
             'the submitter cannot give the verdict');
  AssertContains(Err, 'submitted by dev', 'the refusal says whose it is');
  AssertContains(Err, 'qa', 'and names who reviews');
  AssertTrue(not VerdictTask('board', T1, ActorModel, True, '', Qa, Err),
             'a caller that cannot be identified is refused, not allowed');
  AssertContains(Err, 'named agent', 'and is told why');
  AssertTrue(not VerdictTask('board', T1, 'ui', True, '', Qa, Err),
             'an agent that is not a reviewer is refused');
  AssertTrue(not VerdictTask('board', T1, 'qa', False, '', Qa, Err), 'a reject needs a reason');
  AssertContains(Err, 'reason', 'and says so');

  AssertTrue(VerdictTask('board', T1, 'qa', False, 'empty title still saves a row', Qa, Err),
             'the reviewer rejects: ' + Err);
  AssertTrue(GetTask('board', T1, T), 'it reloads');
  AssertTrue(T.Status = tsActive, 'a reject puts it back to active');
  AssertEqStr(T.Assignee, 'dev', 'with the same owner');
  AssertContains(T.Notes, 'empty title still saves a row', 'and the reason in its notes');
  AssertEqStr(T.Verdict, 'reject', 'the verdict is recorded');
  AssertEqStr(T.VerdictBy, 'qa', 'with who gave it');

  AssertTrue(SubmitTask('board', T1, 'dev', 'fixed: empty title refused now', '', Err),
             'resubmitted');
  AssertTrue(GetTask('board', T1, T) and (T.Verdict = ''), 'a new submission clears the old verdict');
  AssertTrue(VerdictTask('board', T1, 'qa', True, 'all three pass', Qa, Err), 'accepted: ' + Err);
  AssertTrue(GetTask('board', T1, T) and (T.Status = tsDone), 'an accept closes it');
  AssertTrue(not VerdictTask('board', T1, 'qa', True, '', Qa, Err),
             'a verdict on a task not in review is refused');
  AssertContains(Err, 'not waiting', 'and says what state it is in');

  { The operator is the authority the review exists for. }
  T2 := CreateTask('board', 'Copy edits', '', Err);
  UpdateTask('board', T2, '', '-', '', Err, 'dev');
  AssertTrue(SubmitTask('board', T2, 'dev', 'changed the labels', '', Err), 'submitted');
  AssertTrue(UpdateTask('board', T2, '', '-', 'done', Err), 'the operator can close a task in review');
  AssertTrue(GetTask('board', T2, T) and (T.Status = tsDone), 'and it is done');

  { A run starting on a task in review must not quietly take it out. }
  T3 := CreateTask('board', 'Icons', '', Err);
  UpdateTask('board', T3, '', '-', '', Err, 'dev');
  SubmitTask('board', T3, 'dev', 'drew them', '', Err);
  CreateJob('board', T3, '', Err);
  AssertTrue(GetTask('board', T3, T) and (T.Status = tsReview), 'opening a job leaves review alone');

  AssertTrue(GetProject('board', P), 'the board reloads');
  AssertTrue(P.ReviewTasks = 1, 'one task is waiting for a verdict');
  AssertTrue(P.DoneTasks = 2, 'two are done');
  AssertTrue(P.OpenTasks = 1, 'review counts as open -- someone still has to act');

  WriteLn('-- receipts');
  AssertEqStr(EventTrail('board', T1),
    'create:pm assign:foreman criteria:pm start:dev criteria:operator ' +
    'submit:dev reject:qa submit:dev accept:qa',
    'every move on the task left its line, attributed');
  AssertContains(EventTrail('board', T2), 'status:operator',
                 'the operator''s override is recorded as theirs');
  AssertTrue(Length(ReadActivity('board', '', 2)) = 2, 'limit keeps the newest lines');
  AssertTrue(Length(ReadActivity('board', '')) > Length(ReadActivity('board', T1)),
             'the board''s log holds every task''s lines');
end;

procedure TestJobsSubmit;
var
  Err, T4, T5, J, SubmitErr: string;
  T: TTaskInfo;
begin
  WriteLn('-- a finished job submits on a reviewed board');
  T4 := CreateTask('board', 'Wire the save button', '', Err);
  UpdateTask('board', T4, '', '-', '', Err, 'dev');
  J := CreateJob('board', T4, '', Err);
  AssertTrue(GetTask('board', T4, T) and (T.Status = tsActive), 'the job activates it');
  AssertTrue(UpdateJob('board', T4, J, 'done', 'save button writes the row', '-', Err, 'dev'),
             'the job reports done');
  AssertTrue(GetTask('board', T4, T) and (T.Status = tsReview), 'which SUBMITS the task');
  AssertEqStr(T.Evidence, 'save button writes the row', 'the summary is the evidence');
  AssertEqStr(T.SubmittedJob, J, 'and the job is named');
  AssertEqStr(T.SubmittedBy, 'dev', 'by the agent that ran it');

  T5 := CreateTask('board', 'Runner job', '', Err);
  UpdateTask('board', T5, '', '-', '', Err, 'dev');
  J := CreateJob('board', T5, '', Err);
  AssertTrue(FinishJob('board', T5, J, 'done', '-', ActorOperator, Err, SubmitErr),
             'a runner finishing with no summary');
  AssertEqStr(SubmitErr, '', 'is not refused');
  AssertTrue(GetTask('board', T5, T) and (T.Status = tsReview), 'still submits');
  AssertContains(T.Evidence, 'finished', 'naming the job when it said nothing');
  AssertEqStr(T.SubmittedBy, 'dev', 'and it is the owner''s work, not the operator''s');
end;

procedure TestScenarioGate;
var
  Dir, Err, T6: string;
begin
  WriteLn('-- the held-out scenarios gate a submission');
  AssertTrue(Assigned(OnSubmitGate), 'the task tools install the gate');
  Dir := ProjectScenariosDir('board');
  AssertTrue(Pos(ActiveWorkspaceRoot, Dir) <> 1, 'the scenarios live outside the workspace');
  ForceDirectories(Dir);
  WriteFileText(JoinPath(Dir, '01-has-app.sh'),
    'test -f app/index.html || { echo "no app/index.html yet"; exit 1; }' + #10);
  T6 := CreateTask('board', 'Ship the page', '', Err);
  UpdateTask('board', T6, '', '-', 'active', Err, 'dev');
  AssertTrue(not SubmitTask('board', T6, 'dev', 'it works on my machine', '', Err),
             'a red scenario refuses the submit');
  AssertContains(Err, 'held-out', 'saying whose checks failed');
  AssertContains(Err, 'no app/index.html yet', 'with the check''s output');
  AssertContains(EventTrail('board', T6), 'submit-refused:dev', 'and the refusal is a receipt');
  WriteFileText(JoinPath(ProjectAppDir('board'), 'index.html'), '<p>hi</p>');
  AssertTrue(SubmitTask('board', T6, 'dev', 'page is there', '', Err),
             'green, it goes through: ' + Err);
  DeleteFile(JoinPath(Dir, '01-has-app.sh'));
end;

procedure TestBoardRecordsGuard;
var
  Reason: string;
begin
  WriteLn('-- the file tools cannot rewrite the board');
  AssertTrue(not CanWritePath(JoinPath(TaskDir('board', 'T0001'), 'task.json'), Reason),
             'task.json is refused');
  AssertContains(Reason, 'task tool', 'pointing at the tool that owns it');
  AssertTrue(not CanWritePath(JoinPath(ProjectDir('board'), 'activity.jsonl'), Reason),
             'the receipts are refused');
  AssertTrue(not CanWritePath(JoinPath(ProjectDir('board'), 'project.json'), Reason),
             'the manifest is refused');
  AssertTrue(not CanWritePath(JoinPath(JobDir('board', 'T0004', 'J0001'), 'job.json'), Reason),
             'a job manifest is refused');
  AssertTrue(CanWritePath(JoinPath(ProjectAppDir('board'), 'index.html'), Reason),
             'the app the team builds is not');
  AssertTrue(CanWritePath(JoinPath(JoinPath(JobDir('board', 'T0004', 'J0001'), 'artifacts'),
             'out.txt'), Reason), 'nor is a job''s artifacts/');
  AssertTrue(CanWritePath(JoinPath(JoinPath(ProjectDir('board'), 'docs'), 'plan.md'), Reason),
             'nor the project''s docs');
end;

procedure TestToolAsAgents;
var
  Err, Out_, Id: string;
  T: TTaskInfo;
  J: string;
begin
  WriteLn('-- the task tool, as the agents');
  MakeAgent('foreman', '');
  MakeAgent('dev', 'foreman');
  MakeAgent('qa', 'foreman');
  CreateProject('Team Board', 'team-board', '', Err);
  SetProjectReview('team-board', True, Names(['qa']), Err);

  SetCallingAgent('foreman');
  Out_ := Tool_Task('{"action":"create","project":"team-board","title":"Form",' +
                    '"criteria":["empty title refused","save adds a row"]}', Err);
  AssertEqStr(Err, '', 'create with a criteria list');
  Id := 'T0001';
  AssertTrue(GetTask('team-board', Id, T), 'it loads');
  AssertEqStr(T.Criteria, 'empty title refused'#10'save adds a row', 'a list becomes one per line');
  Tool_Task('{"action":"update","project":"team-board","id":"T0001","assignee":"dev"}', Err);

  SetCallingAgent('dev');
  Out_ := Tool_Task('{"action":"update","project":"team-board","id":"T0001","status":"done"}', Err);
  AssertContains(Err, 'action="submit"', 'dev cannot close its own task through the tool');
  Out_ := Tool_Task('{"action":"submit","project":"team-board","id":"T0001",' +
                    '"evidence":"ran it: rows save"}', Err);
  AssertEqStr(Err, '', 'dev submits');
  AssertContains(Out_, 'qa gives the verdict', 'the result names the reviewer');
  AssertContains(Out_, 'save adds a row', 'and the criteria it will be held to');
  AssertTrue(AgentPending('qa') > 0, 'and the reviewer was told -- that is what wakes it');
  Out_ := Tool_Task('{"action":"verdict","project":"team-board","id":"T0001",' +
                    '"verdict":"accept"}', Err);
  AssertContains(Err, 'submitted by dev', 'dev cannot accept its own work');

  SetCallingAgent('');
  Out_ := Tool_Task('{"action":"verdict","project":"team-board","id":"T0001",' +
                    '"verdict":"accept"}', Err);
  AssertContains(Err, 'named agent', 'a turn that is not an agent''s cannot give a verdict');

  SetCallingAgent('qa');
  Out_ := Tool_Task('{"action":"verdict","project":"team-board","id":"T0001",' +
                    '"verdict":"reject"}', Err);
  AssertContains(Err, 'reason', 'a reject without a reason is refused');
  Out_ := Tool_Task('{"action":"verdict","project":"team-board","id":"T0001",' +
                    '"verdict":"reject","reason":"empty title saves a blank row"}', Err);
  AssertEqStr(Err, '', 'qa rejects');
  AssertContains(Out_, 'Judged against its criteria', 'the criteria are said back');
  AssertTrue(AgentPending('dev') > 0, 'and the builder was told');

  SetCallingAgent('dev');
  Tool_Task('{"action":"submit","project":"team-board","id":"T0001",' +
            '"evidence":"blank title now refused"}', Err);
  SetCallingAgent('qa');
  Out_ := Tool_Task('{"action":"verdict","project":"team-board","id":"T0001",' +
                    '"verdict":"accept"}', Err);
  AssertEqStr(Err, '', 'qa accepts the fix');
  AssertTrue(GetTask('team-board', 'T0001', T) and (T.Status = tsDone), 'and it is done');
  Out_ := Tool_Task('{"action":"list","project":"team-board"}', Err);
  AssertContains(Out_, 'requires review', 'the board says it requires review');
  AssertContains(Out_, 'criteria:', 'and lists criteria');

  { The job path: finishing reports that it SUBMITTED, so the model does
    not believe the task closed. }
  SetCallingAgent('foreman');
  Tool_Task('{"action":"create","project":"team-board","title":"Export"}', Err);
  Tool_Task('{"action":"update","project":"team-board","id":"T0002","assignee":"dev"}', Err);
  J := CreateJob('team-board', 'T0002', '', Err);
  SetCallingAgent('dev');
  Out_ := Tool_Task('{"action":"job","project":"team-board","id":"T0002",' +
                    '"status":"done","summary":"export writes a csv"}', Err);
  AssertEqStr(Err, '', 'the job reports');
  AssertContains(Out_, 'Submitted T0002', 'and says the task was submitted');
  AssertTrue(GetTask('team-board', 'T0002', T) and (T.Status = tsReview), 'it is in review');
  SetCallingAgent('');
end;

procedure TestTeams;
var
  T: TTeamTemplate;
  Err: string;
  Info: TTaskInfo;
  Revs: TStringArray;
  S: TTeamState;
  Wakes: TWakeReasonArray;
  I: Integer;
  QaWoken, DevWoken: Boolean;
begin
  WriteLn('-- teams');
  AssertTrue(FindTeamTemplate('software-team', T), 'software-team exists');
  AssertTrue(not T.SkipReview, 'its board requires review');
  AssertTrue((Length(T.ReviewBy) = 1) and (T.ReviewBy[0] = 'qa'), 'the Test Engineer reviews');
  AssertTrue(ValidateTeamTemplate(T, Err), 'and it still validates: ' + Err);
  AssertTrue(FindTeamTemplate('duo', T) and (Length(T.ReviewBy) = 0) and not T.SkipReview,
             'duo requires review with no list -- the parent reviews');

  AssertTrue(ParseTemplateJSON('{"name":"solo","agents":[{"name":"a","role":"r"}],' +
                               '"review":false}', T), 'a template parses');
  AssertTrue(T.SkipReview, '"review": false opts out');
  AssertTrue(ParseTemplateJSON('{"name":"bad","agents":[{"name":"a","role":"r"}],' +
                               '"review":{"by":["zz"]}}', T), 'a template parses');
  AssertTrue(not ValidateTeamTemplate(T, Err), 'a reviewer not on the team is refused');
  AssertContains(Err, 'review.by', 'naming the field');

  CreateProject('Fresh', 'fresh', '', Err);
  FindTeamTemplate('software-team', T);
  AssertTrue(BindTeamBoard(T, 'fresh', Err), 'binding a team sets its rules: ' + Err);
  AssertTrue(ProjectRequiresReview('fresh'), 'the board requires review');
  ParseTemplateJSON('{"name":"solo","agents":[{"name":"a","role":"r"}],"review":false}', T);
  CreateProject('Plain', 'plain', '', Err);
  AssertTrue(BindTeamBoard(T, 'plain', Err) and not ProjectRequiresReview('plain'),
             'a template that opts out leaves the board alone');

  { Who reviews what. }
  Info := Default(TTaskInfo);
  Info.Assignee := 'dev'; Info.SubmittedBy := 'dev';
  Revs := TaskReviewers('team-board', Info);
  AssertTrue((Length(Revs) = 1) and (Revs[0] = 'qa'), 'dev''s work goes to qa');
  Info.Assignee := 'qa'; Info.SubmittedBy := 'qa';
  Revs := TaskReviewers('team-board', Info);
  AssertTrue((Length(Revs) = 1) and (Revs[0] = 'foreman'),
             'qa''s own work goes to its parent -- never to itself');
  CreateProject('Duo Board', 'duo-board', '', Err);
  SetProjectReview('duo-board', True, Names([]), Err);
  Info.Assignee := 'dev'; Info.SubmittedBy := 'dev';
  Revs := TaskReviewers('duo-board', Info);
  AssertTrue((Length(Revs) = 1) and (Revs[0] = 'foreman'),
             'with no list, the submitter''s parent reviews');

  { The wake loop wakes the reviewer, not the owner, for a task in review.
    Fresh agents with empty mailboxes, so mail is not the reason. }
  MakeAgent('w-lead', '');
  MakeAgent('w-dev', 'w-lead');
  MakeAgent('w-qa', 'w-lead');
  CreateProject('Wake Board', 'wake-board', '', Err);
  SetProjectReview('wake-board', True, Names(['w-qa']), Err);
  CreateTask('wake-board', 'The thing', '', Err);
  UpdateTask('wake-board', 'T0001', '', '-', 'active', Err, 'w-dev');
  SubmitTask('wake-board', 'T0001', 'w-dev', 'it runs', '', Err);
  S := Default(TTeamState);
  S.Name := 'wake-team';
  S.Project := 'wake-board';
  S.Enabled := True;
  S.WakeWho := Names(['w-lead', 'w-dev', 'w-qa']);
  Wakes := TeamWakeDecisions(S);
  QaWoken := False; DevWoken := False;
  for I := 0 to High(Wakes) do
  begin
    if (Wakes[I].Agent = 'w-qa') and Wakes[I].Wake then
    begin
      QaWoken := True;
      AssertContains(Wakes[I].Why, 'verdict', 'the reviewer is woken for the verdict');
    end;
    if (Wakes[I].Agent = 'w-dev') and Wakes[I].Wake then DevWoken := True;
  end;
  AssertTrue(QaWoken, 'the reviewer is woken');
  AssertTrue(not DevWoken, 'the owner is not -- the task is not its to move');
  AssertTrue(not TeamBoardDone('wake-board'), 'a board with work in review is not done');
end;

{ ---------------------------------------------- through the real tool loop -- }

type
  TOneShotProvider = class(TInterfacedObject, ILLMProvider)
  private
    FRound: Integer;
    FArgs: string;
  public
    constructor Create(const TaskArgs: string);
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

constructor TOneShotProvider.Create(const TaskArgs: string);
begin
  inherited Create;
  FArgs := TaskArgs;
end;

function TOneShotProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TOneShotProvider.GetName: string;         begin Result := 'fake'; end;
function TOneShotProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TOneShotProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TOneShotProvider.SupportsStreaming: Boolean;    begin Result := False; end;

(* Round 1: two read-only calls (a real parallel batch on worker threads)
   and the `task` call -- so the round exercises both dispatch paths and
   the task call must still land on the loop thread. *)
function TOneShotProvider.Chat(const Messages: array of TMessage;
                               const Tools: array of TToolDefinition;
                               const Model: string;
                               const Options: TChatOptions): TLLMResponse;
var
  I: Integer;
begin
  Inc(FRound);
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  if FRound = 1 then
  begin
    SetLength(Result.ToolCalls, 3);
    for I := 0 to 2 do
    begin
      Result.ToolCalls[I].Id   := 'c' + IntToStr(I);
      Result.ToolCalls[I].Kind := 'function';
      Result.ToolCalls[I].Func.Name := 'peek';
      Result.ToolCalls[I].Func.Arguments := '{}';
    end;
    Result.ToolCalls[2].Func.Name := 'task';
    Result.ToolCalls[2].Func.Arguments := FArgs;
    Result.FinishReason := 'tool_calls';
  end
  else
  begin
    Result.Content := 'done';
    Result.FinishReason := 'stop';
  end;
end;

function TOneShotProvider.ChatStream(const Messages: array of TMessage;
                                     const Tools: array of TToolDefinition;
                                     const Model: string;
                                     const Options: TChatOptions;
                                     OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function HandlePeek(const A: string; out E: string): string;
begin
  E := '';
  Result := 'nothing to see';
end;

type
  (* One agent turn on its own thread, the shape TAgentRunThread has: set
     who this thread is (or not), run the loop, keep the task result. *)
  TTurnThread = class(TThread)
  private
    FAgent, FArgs: string;
    FReg: TToolRegistry;
  protected
    procedure Execute; override;
  public
    TaskResult: string;
    constructor Create(const Agent, Args: string; Reg: TToolRegistry);
  end;

constructor TTurnThread.Create(const Agent, Args: string; Reg: TToolRegistry);
begin
  FAgent := Agent;
  FArgs := Args;
  FReg := Reg;
  inherited Create(False);
end;

procedure TTurnThread.Execute;
var
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: array of TMessage;
  I: Integer;
begin
  if FAgent <> '' then SetCallingAgent(FAgent);
  try
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider      := TOneShotProvider.Create(FArgs);
    Cfg.Registry      := FReg;
    Cfg.Model         := 'fake';
    Cfg.MaxIterations := 3;
    Cfg.Parallel      := True;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'review it');
    if RunToolLoop(Cfg, Msgs, Loop) then
      for I := 0 to High(Loop.FinalMessages) do
        if (Loop.FinalMessages[I].Role = mrTool) and
           (Loop.FinalMessages[I].ToolCallId = 'c2') then
          TaskResult := Loop.FinalMessages[I].Content;
  finally
    SetCallingAgent('');
  end;
end;

procedure TestThroughTheLoop;
var
  Reg: TToolRegistry;
  Tl: TTool;
  Err: string;
  Th: TTurnThread;
  T: TTaskInfo;
const
  Verdict = '{"action":"verdict","project":"loop-board","id":"T0001","verdict":"accept"}';
begin
  WriteLn('-- the caller reaches the task tool through the tool loop');
  MakeAgent('l-lead', '');
  MakeAgent('l-dev', 'l-lead');
  MakeAgent('l-qa', 'l-lead');
  CreateProject('Loop Board', 'loop-board', '', Err);
  SetProjectReview('loop-board', True, Names(['l-qa']), Err);
  CreateTask('loop-board', 'Thing', '', Err);
  UpdateTask('loop-board', 'T0001', '', '-', 'active', Err, 'l-dev');
  SubmitTask('loop-board', 'T0001', 'l-dev', 'built it', '', Err);

  Reg := TToolRegistry.Create;
  try
    RegisterProjectTools(Reg);
    AssertTrue(Reg.Find('task', Tl) and (Tl.Category = tcMutating),
               'task is mutating -- so it dispatches inline, on the loop thread');
    Tl := Default(TTool);
    Tl.Name := 'peek';
    Tl.Description := 'read-only probe';
    Tl.Schema := '{"type":"object"}';
    Tl.Handler := HandlePeek;
    Tl.Category := tcReadOnly;
    Reg.Register(Tl);

    { The main thread claims an identity; a turn thread that set none must
      not inherit it -- a threadvar, not a global. }
    SetCallingAgent('l-qa');
    Th := TTurnThread.Create('', Verdict, Reg);
    try
      Th.WaitFor;
      AssertContains(Th.TaskResult, 'named agent',
                     'a turn thread with no identity is refused, whatever another thread set');
    finally
      Th.Free;
    end;
    SetCallingAgent('');
    AssertTrue(GetTask('loop-board', 'T0001', T) and (T.Status = tsReview), 'still in review');

    Th := TTurnThread.Create('l-dev', Verdict, Reg);
    try
      Th.WaitFor;
      AssertContains(Th.TaskResult, 'submitted by l-dev',
                     'the builder''s own turn cannot accept its work');
    finally
      Th.Free;
    end;

    Th := TTurnThread.Create('l-qa', Verdict, Reg);
    try
      Th.WaitFor;
      AssertContains(Th.TaskResult, 'Accepted T0001', 'the reviewer''s turn can');
    finally
      Th.Free;
    end;
    AssertTrue(GetTask('loop-board', 'T0001', T) and (T.Status = tsDone), 'and it is done');
    AssertContains(EventTrail('loop-board', 'T0001'), 'accept:l-qa',
                   'recorded as the agent whose turn it was');
  finally
    Reg.Free;
  end;
end;

begin
  TestStoreRules;
  TestJobsSubmit;
  TestScenarioGate;
  TestBoardRecordsGuard;
  TestToolAsAgents;
  TestTeams;
  TestThroughTheLoop;

  if Failures = 0 then
    WriteLn('team_review_tests: OK')
  else
  begin
    WriteLn('team_review_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
