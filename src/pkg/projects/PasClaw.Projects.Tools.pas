(*
  PasClaw.Projects.Tools - the model-callable `project` and `task` tools.

  These let the agent keep its own board: create the project it is building
  in, break the work into tasks, and report progress as it goes. The desktop
  reads exactly the same manifests, so the left-hand tree updates while the
  agent works -- the board is not a separate thing the model narrates, it IS
  the thing the model edits.

  Two tools rather than five, because a tool list is prompt budget:

    project  action = list | create | get | update
    task     action = list | create | update | job | submit | verdict

  `task action=job` is how a run reports itself: status/summary against a job
  the runtime opened. Jobs are created by the runtime (PasClaw.Projects.Store
  CreateJob) when a turn starts working a task, so the model never has to
  remember to open one -- it only closes them.

  `submit` and `verdict` are the review loop (docs/team-board-plan.md): the
  builder submits with evidence, someone else gives the verdict against
  the task's frozen criteria. The rules are the store's; this unit's part
  is telling the store WHO is asking -- the calling agent, or ActorModel
  when the turn is not a standing agent's, which is never the operator --
  naming the reviewers, and messaging them so the handoff does not wait
  for the next tick.

  Both are tcMutating: they write manifests under the active workspace.
*)
unit PasClaw.Projects.Tools;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

interface

uses
  PasClaw.Tools.Registry;

(* The `desktop` tool alone: arrange the screen a person is looking at.

   Split out from the board tools because it answers a different
   question. `project` and `task` let the MODEL manage the board, which
   is what desktop_tools_enabled gates and why that gate is off by
   default. `desktop` moves windows in a browser -- it is meaningless
   without a desktop connected, and it is what the shell's Auto routing
   is built on. Gating it behind the board flag meant a fresh install
   answered "tile the open windows" with a model that had no way to do
   it. *)
procedure RegisterDesktopTool(R: TToolRegistry);

(* May the MODEL fire up an agent team through the desktop tool?

   The `desktop` tool is registered ALWAYS -- it moves windows, and
   gating window management behind a board flag meant a fresh install
   could not answer "tile these". team_up is not window management: it
   seeds standing agents, creates a project and starts a turn, which is
   exactly what agent_tools_enabled exists to let an operator decline.
   Without this gate a default gateway with a desktop open let the
   model create autonomous colleagues the operator had switched off --
   the flag was consulted only afterwards, to warn about a team that
   already existed.

   Off unless the caller says otherwise, so a host that forgets to call
   this refuses rather than permits. The HTTP route stays open: a
   person clicking New team... is the operator, and gating them behind
   a switch meant for the model is the category error /v1/agents
   already documents. *)
procedure SetTeamActionsAllowed(Allowed: Boolean);

procedure RegisterProjectTools(R: TToolRegistry);

{ Handlers, exposed for tests. }
function Tool_Project(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Task(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Desktop(const ArgsJSON: string; out ErrMsg: string): string;

(* Exposed for tests: what a `desktop` call is READ as, before anything
   is published. Returns the actions array as JSON, or '' when the call
   carried nothing usable. Publishing is the side effect; this is the
   decision, and the decision is what is worth pinning. *)
function DesktopActionsJSON(const ArgsJSON: string): string;

implementation

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Projects.Store,
  PasClaw.Desktop.Events,
  PasClaw.Agents,          { AgentSend -- a submit tells its reviewers }
  PasClaw.Agents.Tools,    { CallingAgent -- who is asking }
  PasClaw.Teams,           { TaskReviewers -- who may give the verdict }
  PasClaw.Agent.Verify;    { RunScenarios -- the gate on submit }

var
  GTeamActionsAllowed: Boolean = False;

procedure SetTeamActionsAllowed(Allowed: Boolean);
begin
  GTeamActionsAllowed := Allowed;
end;

function IfThenStr(Cond: Boolean; const Yes, No: string): string;
begin
  if Cond then Result := Yes else Result := No;
end;

function ArgObj(const ArgsJSON: string; out Obj: TJsonObject; out Err: string): Boolean;
begin
  Err := '';
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
  except
    on E: Exception do
    begin
      Err := 'arguments are not valid JSON: ' + E.Message;
      Exit(False);
    end;
  end;
  Result := Obj <> nil;
  if not Result then
    Err := 'arguments are not valid JSON';
end;

{ ---------------------------------------------------------------- project -- }

function ProjectList: string;
var
  Rows: TProjectInfoArray;
  I: Integer;
  S: string;
begin
  Rows := ListProjects;
  if Length(Rows) = 0 then
    Exit('No projects yet. Create one with project action="create".');
  S := 'Projects in the active workspace:'#10;
  for I := 0 to High(Rows) do
  begin
    S := S + '  ' + Rows[I].Name;
    if Rows[I].Title <> Rows[I].Name then
      S := S + '  "' + Rows[I].Title + '"';
    S := S + '  tasks: ' + IntToStr(Rows[I].TaskCount) +
         ' (' + IntToStr(Rows[I].OpenTasks) + ' open)';
    if Rows[I].HasApp then
      S := S + '  [has app]';
    S := S + #10;
  end;
  Result := S;
end;

function ProjectGet(const Name: string; out Err: string): string;
var
  Info: TProjectInfo;
  Tasks: TTaskInfoArray;
  I: Integer;
  S: string;
begin
  Err := '';
  Result := '';
  if not GetProject(Name, Info) then
  begin
    Err := 'no such project: ' + Name;
    Exit;
  end;
  S := 'Project ' + Info.Name + ' -- "' + Info.Title + '"'#10;
  if Info.Description <> '' then
    S := S + Info.Description + #10;
  S := S + 'created: ' + Info.Created + #10;
  if Info.HasApp then
    S := S + 'app: app/ (see app.json)'#10;
  Tasks := ListTasks(Info.Name);
  if Length(Tasks) = 0 then
    S := S + 'No tasks yet.'#10
  else
  begin
    S := S + 'Tasks:'#10;
    for I := 0 to High(Tasks) do
      S := S + '  ' + Tasks[I].Id + '  [' + TaskStatusToStr(Tasks[I].Status) +
           ']  ' + Tasks[I].Title + '  (jobs: ' + IntToStr(Tasks[I].JobCount) + ')'#10;
  end;
  Result := S;
end;

function Tool_Project(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Action, Name_, Title, Desc, Icon, Err: string;
begin
  ErrMsg := '';
  Result := '';
  if not ArgObj(ArgsJSON, Obj, ErrMsg) then Exit;
  try
    Action := LowerCase(Trim(Obj.GetStr('action', '')));
    Name_  := Trim(Obj.GetStr('name', ''));
    Title  := Trim(Obj.GetStr('title', ''));

    if (Action = '') or (Action = 'list') then
      Exit(ProjectList);

    if Action = 'get' then
    begin
      if Name_ = '' then
      begin
        ErrMsg := 'project action="get" needs a "name"';
        Exit;
      end;
      Result := ProjectGet(Name_, ErrMsg);
      Exit;
    end;

    if Action = 'create' then
    begin
      Desc := Obj.GetStr('description', '');
      if (Title = '') and (Name_ = '') then
      begin
        ErrMsg := 'project action="create" needs a "title" (or a "name")';
        Exit;
      end;
      Name_ := CreateProject(Title, Name_, Desc, Err);
      if Name_ = '' then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Created project "' + Name_ + '". Its app goes in projects/' +
                Name_ + '/app/. Break the work into tasks with ' +
                'task action="create" project="' + Name_ + '".';
      Exit;
    end;

    if Action = 'update' then
    begin
      if Name_ = '' then
      begin
        ErrMsg := 'project action="update" needs a "name"';
        Exit;
      end;
      { '-' is the unchanged sentinel in the store; absent keys must not
        clear a description the user wrote. }
      if Obj.Has('description') then Desc := Obj.GetStr('description', '') else Desc := '-';
      if Obj.Has('icon')        then Icon := Obj.GetStr('icon', '')        else Icon := '-';
      if not UpdateProject(Name_, Title, Desc, Icon, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Updated project "' + Name_ + '".';
      Exit;
    end;

    ErrMsg := 'unknown action "' + Action + '" (use list, create, get or update)';
  finally
    Obj.Free;
  end;
end;

{ ------------------------------------------------------------------- task -- }

{ Who this call is from, for the store's review rules: the agent whose
  turn is running, or ActorModel -- "cannot tell", which the store never
  reads as the operator. }
function TaskActor: string;
begin
  Result := CallingAgent;
  if Result = '' then Result := ActorModel;
end;

(* "criteria" as the store keeps it: one check per line. A model sends a
   list as often as a string, and both mean the same thing. Present says
   the key was there at all -- "criteria": "" clears, an absent key leaves
   them alone. *)
function CriteriaArg(Obj: TJsonObject; out Present: Boolean): string;
var
  Arr: TJsonArray;
  I: Integer;
begin
  Result := '';
  Present := Obj.Has('criteria');
  if not Present then Exit;
  Arr := Obj.ChildArray('criteria');
  if Arr <> nil then
  begin
    try
      for I := 0 to Arr.Count - 1 do
        if Trim(Arr.ItemStr(I)) <> '' then
        begin
          if Result <> '' then Result := Result + #10;
          Result := Result + Trim(Arr.ItemStr(I));
        end;
    finally
      Arr.Free;
    end;
    Exit;
  end;
  Result := Trim(Obj.GetStr('criteria', ''));
end;

(* "waits_on" as task ids: a list, or one string of ids separated by
   commas or spaces -- the same two shapes a model sends for criteria. *)
function WaitsOnArg(Obj: TJsonObject; out Present: Boolean): TStringArray;
var
  Arr: TJsonArray;
  I: Integer;
  S, Tok: string;

  procedure Add(const Id: string);
  begin
    if Trim(Id) = '' then Exit;
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := UpperCase(Trim(Id));
  end;

begin
  SetLength(Result, 0);
  Present := Obj.Has('waits_on');
  if not Present then Exit;
  Arr := Obj.ChildArray('waits_on');
  if Arr <> nil then
  begin
    try
      for I := 0 to Arr.Count - 1 do Add(Arr.ItemStr(I));
    finally
      Arr.Free;
    end;
    Exit;
  end;
  S := Obj.GetStr('waits_on', '') + ' ';
  Tok := '';
  for I := 1 to Length(S) do
    if (S[I] = ',') or (S[I] = ' ') then
    begin
      Add(Tok);
      Tok := '';
    end
    else
      Tok := Tok + S[I];
end;

{ Each non-blank line of Text, prefixed. }
function PrefixLines(const Text, Prefix: string): string;
var
  Lines: TStringList;
  I: Integer;
begin
  Result := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for I := 0 to Lines.Count - 1 do
      if Trim(Lines[I]) <> '' then
        Result := Result + Prefix + Trim(Lines[I]) + #10;
  finally
    Lines.Free;
  end;
end;

function FirstLine(const Text: string): string;
var
  P: Integer;
begin
  Result := Trim(Text);
  P := Pos(#10, Result);
  if P > 0 then Result := TrimRight(Copy(Result, 1, P - 1)) + ' ...';
  if Length(Result) > 160 then Result := Copy(Result, 1, 157) + '...';
end;

function JoinList(const Names: TStringArray): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(Names) do
  begin
    if Result <> '' then Result := Result + ', ';
    Result := Result + Names[I];
  end;
end;

{ "qa gives the verdict" / "the operator gives the verdict". }
function VerdictWho(const Reviewers: TStringArray): string;
begin
  if Length(Reviewers) = 0 then
    Result := 'the operator (no agent on this board can review it)'
  else
    Result := JoinList(Reviewers);
end;

function TaskList(const Project: string; out Err: string): string;
var
  Rows: TTaskInfoArray;
  Waiting: TStringArray;
  I: Integer;
  S: string;
begin
  Err := '';
  Result := '';
  if not ProjectExists(Project) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  Rows := ListTasks(Project);
  if Length(Rows) = 0 then
    Exit('No tasks in ' + Project + ' yet.');
  S := 'Tasks in ' + Project + ':'#10;
  { Said where it is read: the board is where an agent decides what to
    do next, and "you cannot close this yourself" belongs on it. }
  if ProjectRequiresReview(Project) then
    S := S + '(This board requires review: submit finished work with ' +
         'action="submit"; a verdict from someone else closes it.)'#10;
  for I := 0 to High(Rows) do
  begin
    S := S + '  ' + Rows[I].Id + '  [' + TaskStatusToStr(Rows[I].Status) + ']  ' +
         Rows[I].Title;
    if Rows[I].Assignee <> '' then
      S := S + '  @' + Rows[I].Assignee;
    if Rows[I].JobCount > 0 then
      S := S + '  (jobs: ' + IntToStr(Rows[I].JobCount) + ')';
    S := S + #10;
    if Rows[I].Notes <> '' then
      S := S + '      ' + Rows[I].Notes + #10;
    if Rows[I].Criteria <> '' then
      S := S + '      criteria:'#10 + PrefixLines(Rows[I].Criteria, '        - ');
    if Rows[I].Status = tsReview then
      S := S + '      submitted by ' + Rows[I].SubmittedBy + ': ' +
           FirstLine(Rows[I].Evidence) + #10;
    { Readiness is computed, so it is said here rather than stored: a
      task waiting on unfinished work is not one to start. }
    if Length(Rows[I].WaitsOn) > 0 then
    begin
      Waiting := TaskWaitingOn(Rows[I], Rows);
      if Length(Waiting) > 0 then
        S := S + '      waits on ' + JoinList(Waiting) + ' (not done yet)'#10
      else
        S := S + '      waited on ' + JoinList(Rows[I].WaitsOn) + ' -- all done, ready'#10;
    end;
  end;
  Result := S;
end;

(* Tell each reviewer a task is waiting for it. The wake loop would find
   it on the next tick anyway; a message is what makes the team due NOW
   (TeamHasWaitingMail), and a handoff that waits out the cadence is the
   slowest thing in a team. Best effort: a reviewer that is not a
   standing agent -- an operator-only board -- has no mailbox. *)
procedure TellReviewers(const Project: string; const T: TTaskInfo;
  const Reviewers: TStringArray);
var
  I: Integer;
  Text, Delivered, Err: string;
begin
  Text := Format('%s ("%s") on %s was submitted by %s and waits for your ' +
                 'verdict. Evidence: %s'#10'Check it against its criteria, ' +
                 'then task action="verdict" project="%s" id="%s" ' +
                 'verdict="accept" -- or verdict="reject" with a "reason".',
                 [T.Id, T.Title, Project, T.SubmittedBy, FirstLine(T.Evidence),
                  Project, T.Id]);
  for I := 0 to High(Reviewers) do
    AgentSend(Reviewers[I], ActorLabel(T.SubmittedBy), Text, Delivered, Err);
end;

{ The result of a submission that went through: who reviews, and the
  criteria they will hold it to. }
function SubmittedText(const Project, TaskId: string): string;
var
  T: TTaskInfo;
  Revs: TStringArray;
begin
  Result := 'Submitted ' + UpperCase(TaskId) + ' for review.';
  if not GetTask(Project, TaskId, T) then Exit;
  Revs := TaskReviewers(Project, T);
  Result := Result + ' ' + VerdictWho(Revs) + ' gives the verdict';
  if T.Criteria <> '' then
    Result := Result + ' against its criteria:'#10 + PrefixLines(T.Criteria, '  - ')
  else
    Result := Result + ' (it has no criteria, so the reviewer judges it ' +
              'against its title and notes).';
  TellReviewers(Project, T, Revs);
end;

function IsAgentCaller(const Actor: string): Boolean;
begin
  Result := (Actor <> ActorOperator) and (Actor <> ActorModel);
end;

function InList(const Name: string; const Names: TStringArray): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(Names) do
    if Names[I] = Name then Exit(True);
end;

(* "Nothing ready" with the reasons, because the model's next move
   depends on them: wait for a prerequisite, finish what it holds, or
   ask its lead for work. *)
function NothingReadyText(const Project, Agent: string): string;
var
  Board: TTaskInfoArray;
  I: Integer;
  Lines: string;
begin
  Result := 'Nothing is ready for you on ' + Project + '.';
  Board := ListTasks(Project);
  Lines := '';
  for I := 0 to High(Board) do
    if Board[I].Assignee = Agent then
      case Board[I].Status of
        tsActive: Lines := Lines + #10'  ' + Board[I].Id + ' is already yours and active -- carry on with it.';
        tsReview: Lines := Lines + #10'  ' + Board[I].Id + ' waits for a verdict.';
        tsBlocked: Lines := Lines + #10'  ' + Board[I].Id + ' is blocked: ' + FirstLine(Board[I].Notes);
        tsTodo:
          if not TaskReady(Board[I], Board) then
            Lines := Lines + #10'  ' + Board[I].Id + ' waits on ' +
                     JoinList(TaskWaitingOn(Board[I], Board)) + '.';
      end;
  Result := Result + Lines;
  if not InList(Agent, ProjectTakers(Project)) then
    Result := Result + #10'You take work routed to you; unassigned tasks ' +
              'are your lead''s to hand out.';
end;

(* OnTaskClosed: a task reached done, so tasks that waited on it may be
   ready now. Their owners are told -- which is also what makes their
   team due on the next tick instead of at the next cadence. Unassigned
   ones are left to the wake loop, which offers them to the board's
   takers. *)
procedure NotifyDependents(const Project, TaskId: string);
var
  Board: TTaskInfoArray;
  I, K: Integer;
  Waited: Boolean;
  Delivered, Err: string;
begin
  Board := ListTasks(Project);
  for I := 0 to High(Board) do
  begin
    if (Board[I].Status <> tsTodo) or (Board[I].Assignee = '') then Continue;
    Waited := False;
    for K := 0 to High(Board[I].WaitsOn) do
      if Board[I].WaitsOn[K] = UpperCase(TaskId) then Waited := True;
    if not Waited or not TaskReady(Board[I], Board) then Continue;
    AgentSend(Board[I].Assignee, 'board',
              Format('%s ("%s") on %s is ready: %s, the last thing it waited ' +
                     'on, is done. Claim it with task action="next" ' +
                     'project="%s".',
                     [Board[I].Id, Board[I].Title, Project, UpperCase(TaskId),
                      Project]), Delivered, Err);
  end;
end;

function Tool_Task(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Action, Project, Id, Title, Notes, Status, Summary, JobId, Assignee, Err,
    Criteria, Actor, Verdict, Reason, SubmitErr, Delivered, Owner: string;
  HasCriteria, HasWaits, Accept: Boolean;
  Jobs: TJobInfoArray;
  T: TTaskInfo;
  Revs, WaitsOn: TStringArray;
begin
  ErrMsg := '';
  Result := '';
  if not ArgObj(ArgsJSON, Obj, ErrMsg) then Exit;
  try
    Action  := LowerCase(Trim(Obj.GetStr('action', '')));
    Project := Trim(Obj.GetStr('project', ''));
    Id      := Trim(Obj.GetStr('id', ''));
    Title   := Trim(Obj.GetStr('title', ''));
    Status  := Trim(Obj.GetStr('status', ''));
    Actor   := TaskActor;

    if Project = '' then
    begin
      ErrMsg := 'every task action needs a "project"';
      Exit;
    end;

    if (Action = '') or (Action = 'list') then
    begin
      Result := TaskList(Project, ErrMsg);
      Exit;
    end;

    if Action = 'create' then
    begin
      Notes := Obj.GetStr('notes', '');
      Criteria := CriteriaArg(Obj, HasCriteria);
      WaitsOn := WaitsOnArg(Obj, HasWaits);
      Id := CreateTask(Project, Title, Notes, Err, Criteria, Actor);
      if Id = '' then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Created task ' + Id + ' in ' + Project + ': ' + Title;
      if HasWaits and (Length(WaitsOn) > 0) then
      begin
        if SetTaskWaitsOn(Project, Id, WaitsOn, Actor, Err) then
          Result := Result + ' (waits on ' + JoinList(WaitsOn) + ')'
        else
          { The task exists either way; say the edge did not take, and why,
            rather than failing a create that succeeded. }
          Result := Result + '. Its waits_on was NOT set: ' + Err;
      end;
      Exit;
    end;

    (* next: the board hands the caller its next piece of work. *)
    if Action = 'next' then
    begin
      if not IsAgentCaller(Actor) then
      begin
        ErrMsg := 'task action="next" claims work for a named agent, and ' +
                  'this call is not running as one. Pick a task with ' +
                  'action="list" and work it with action="update".';
        Exit;
      end;
      if ClaimNextTask(Project, Actor, InList(Actor, ProjectTakers(Project)),
                       Id, Err) then
      begin
        GetTask(Project, Id, T);
        Result := 'Claimed ' + Id + ': ' + T.Title + ' -- it is yours and ' +
                  'active. Your claim lasts ' + IntToStr(ClaimLeaseMinutes) +
                  ' minutes and renews whenever you update the task.';
        if T.Notes <> '' then Result := Result + #10'notes: ' + T.Notes;
        if T.Criteria <> '' then
          Result := Result + #10'criteria (what the verdict checks):'#10 +
                    PrefixLines(T.Criteria, '  - ');
        Exit;
      end;
      if Err <> '' then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := NothingReadyText(Project, Actor);
      Exit;
    end;

    if Action = 'update' then
    begin
      if Id = '' then
      begin
        ErrMsg := 'task action="update" needs the task "id" (e.g. T0001)';
        Exit;
      end;
      if Obj.Has('notes') then Notes := Obj.GetStr('notes', '') else Notes := '-';
      { Absent key = leave alone; "assignee":"" = explicitly unassign. }
      if Obj.Has('assignee') then Assignee := Obj.GetStr('assignee', '')
                              else Assignee := '-';
      Criteria := CriteriaArg(Obj, HasCriteria);
      if not HasCriteria then Criteria := '-';
      WaitsOn := WaitsOnArg(Obj, HasWaits);
      { The edge first: a refused cycle should leave the rest of the call
        unapplied, not half of it. }
      if HasWaits and not SetTaskWaitsOn(Project, Id, WaitsOn, Actor, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      if not UpdateTask(Project, Id, Title, Notes, Status, Err, Assignee,
                        Criteria, Actor) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Updated task ' + UpperCase(Id) + ' in ' + Project;
      if Status <> '' then
        Result := Result + ' (status: ' + LowerCase(Status) + ')';
      if HasWaits then
      begin
        if Length(WaitsOn) = 0 then Result := Result + ' (waits on nothing)'
        else Result := Result + ' (waits on ' + JoinList(WaitsOn) + ')';
      end;
      Exit;
    end;

    if Action = 'submit' then
    begin
      if Id = '' then
      begin
        ErrMsg := 'task action="submit" needs the task "id"';
        Exit;
      end;
      JobId := Trim(Obj.GetStr('job', ''));
      { The run this came from, when the runtime opened one: the reviewer
        can read its log. }
      if JobId = '' then
      begin
        Jobs := ListJobs(Project, Id);
        if Length(Jobs) > 0 then JobId := Jobs[High(Jobs)].Id;
      end;
      if not SubmitTask(Project, Id, Actor, Obj.GetStr('evidence', ''),
                        JobId, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := SubmittedText(Project, Id);
      Exit;
    end;

    if Action = 'verdict' then
    begin
      if Id = '' then
      begin
        ErrMsg := 'task action="verdict" needs the task "id"';
        Exit;
      end;
      Verdict := LowerCase(Trim(Obj.GetStr('verdict', '')));
      if (Verdict <> 'accept') and (Verdict <> 'reject') then
      begin
        ErrMsg := 'task action="verdict" needs verdict="accept" or ' +
                  'verdict="reject" (with a "reason")';
        Exit;
      end;
      Accept := Verdict = 'accept';
      Reason := Trim(Obj.GetStr('reason', ''));
      if Reason = '' then Reason := Trim(Obj.GetStr('note', ''));
      if not GetTask(Project, Id, T) then
      begin
        ErrMsg := 'no such task: ' + Project + '/' + Id;
        Exit;
      end;
      Revs := TaskReviewers(Project, T);
      if not VerdictTask(Project, Id, Actor, Accept, Reason, Revs, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      if Accept then
        Result := 'Accepted ' + T.Id + ': it is done.'
      else
      begin
        Owner := T.Assignee;
        if Owner = '' then Owner := T.SubmittedBy;
        Result := 'Rejected ' + T.Id + ': it is back to ' + ActorLabel(Owner) +
                  ' (active), with your reason in its notes.';
        { The builder is told now rather than finding out on the next
          tick -- and being told is what wakes it. }
        AgentSend(Owner, ActorLabel(Actor),
                  Format('%s ("%s") on %s was rejected by %s: %s'#10 +
                         'Fix it and submit it again (task action="submit").',
                         [T.Id, T.Title, Project, ActorLabel(Actor), Reason]),
                  Delivered, Err);
      end;
      (* The criteria said back: a reviewer that skipped one is then
         visible in its own transcript, next to the verdict it gave. *)
      if T.Criteria <> '' then
        Result := Result + #10'Judged against its criteria:'#10 +
                  PrefixLines(T.Criteria, '  - ');
      Exit;
    end;

    if Action = 'job' then
    begin
      if Id = '' then
      begin
        ErrMsg := 'task action="job" needs the task "id"';
        Exit;
      end;
      JobId   := Trim(Obj.GetStr('job', ''));
      Summary := Obj.GetStr('summary', '');
      { No job id: report against the most recent job on the task, which is
        the one the runtime opened for this turn. }
      if JobId = '' then
      begin
        Jobs := ListJobs(Project, Id);
        if Length(Jobs) = 0 then
        begin
          ErrMsg := 'no jobs on ' + Project + '/' + UpperCase(Id) +
                    ' to report against';
          Exit;
        end;
        JobId := Jobs[High(Jobs)].Id;
      end;
      if Status = '' then Status := 'done';
      (* A board that requires review: finishing the job SUBMITS the task,
         with the summary as its evidence (FinishJob), and the result says
         what happened -- submitted, or refused and why -- because a model
         told only "reported done" would believe the task closed. *)
      if ProjectRequiresReview(Project) then
      begin
        if not FinishJob(Project, Id, JobId, Status, Summary, Actor,
                         Err, SubmitErr) then
        begin
          ErrMsg := Err;
          Exit;
        end;
        Result := 'Job ' + JobId + ' on ' + Project + '/' + UpperCase(Id) +
                  ' reported ' + LowerCase(Status) + '.';
        if LowerCase(Status) <> 'done' then Exit;
        if SubmitErr <> '' then
          Result := Result + ' The task was NOT submitted: ' + SubmitErr
        else if GetTask(Project, Id, T) and (T.Status = tsReview) then
          Result := Result + ' ' + SubmittedText(Project, Id)
        else
          Result := Result + ' The task stays ' + TaskStatusToStr(T.Status) +
                    ' (another job on it is still running, or it was not ' +
                    'active); submit it with action="submit" when it is ready.';
        Exit;
      end;
      if not UpdateJob(Project, Id, JobId, Status, Summary, '-', Err, Actor) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      { Finishing the last open job on a task is what closes the task. The
        model can still set a task status explicitly; this is the default so
        a well-behaved run leaves a tidy board without extra calls. }
      if LowerCase(Status) = 'done' then
        UpdateTask(Project, Id, '', '-', 'done', Err, '-', '-', Actor);
      Result := 'Job ' + JobId + ' on ' + Project + '/' + UpperCase(Id) +
                ' reported ' + LowerCase(Status) + '.';
      Exit;
    end;

    ErrMsg := 'unknown action "' + Action +
              '" (use list, create, update, next, job, submit or verdict)';
  finally
    Obj.Free;
  end;
end;

(* The gate on submit: the operator's held-out checks for this project,
   run before the work reaches a reviewer. Work the operator's own checks
   already reject should not cost a reviewer's turn, and a reviewer that
   accepted it anyway would be accepting a known failure.

   No scenarios directory, or nothing in it, is a PASS here -- unlike
   verification.scenarios, where a configured-but-empty set is a mistake.
   A project opts in by the operator putting checks in its directory;
   nothing there means nothing was asked for. Run with the project
   directory as cwd, so a check can say `test -f app/index.html`. *)
function ProjectScenarioGate(const Project, TaskId: string;
  out Report: string): Boolean;
var
  Dir: string;
  Results: TScenarioResults;
  I: Integer;
begin
  Report := '';
  Result := True;
  Dir := ProjectScenariosDir(Project);
  if (Dir = '') or (Length(ListScenarios(Dir)) = 0) then Exit;
  (* Both absolute: the scenario runs with the PROJECT as its cwd, so a
     scenario path relative to anything else -- a $PASCLAW_HOME given as
     a relative path, say -- would name a file that is not there and fail
     with nothing to show for it. *)
  if RunScenarios(ExpandFileName(Dir), ExpandFileName(ProjectDir(Project)),
                  Results) then Exit;
  Result := False;
  Report := Format('%d of %d held-out check(s) failed:',
                   [Length(Results) - CountPassed(Results), Length(Results)]);
  for I := 0 to High(Results) do
    if not Results[I].Passed then
    begin
      Report := Report + #10'- ' + Results[I].Name +
                Format(': FAILED (exit %d)', [Results[I].ExitCode]);
      if Results[I].Output <> '' then
        Report := Report + #10'  output (the check''s, quoted as data):'#10'  ' +
                  StringReplace(Results[I].Output, #10, #10'  ', [rfReplaceAll]);
    end;
end;

{ --------------------------------------------------------------- register -- }

(* desktop -- arrange the screen the user is looking at.

   The windows live in a browser and this runs in the gateway, so the
   tool cannot move anything itself. It publishes a command on the
   desktop event feed, which every connected desktop is already
   subscribed to, and they act on it. That indirection is what makes the
   capability general: the shell chat, the Agent Console and a scheduled
   job all reach the same screen through the same door.

   Fire and forget by design. The tool returns as soon as the command is
   on the feed -- a desktop may be open, closed, or three of them may be
   connected at once, and blocking an agent turn on a browser that might
   not be there would be a worse contract than "asked". *)
(* Turn what the model ACTUALLY sent into an actions array.

   The documented shape is {"actions":[{"do":...}]} and the shell prompt
   spells it out, but three sibling tools -- project, task, agent -- all
   take a singular "action" STRING, so a model reaching for this one has
   a strong prior toward the wrong key and the wrong arity. Observed in
   real use: "build me a book comparison app" produced desktop() with no
   arguments at all, the turn spent on an error instead of an app.

   So the near misses are accepted rather than refused. Same trade the
   app manifest makes when it reads "type" as a synonym for "kind": a
   request should not fail over a word when what was meant is
   unambiguous. Anything genuinely ambiguous still errors -- and the
   error now shows a correct call, because the model's next move is a
   retry and it should have the shape in front of it.

   Returns nil when nothing usable is there; caller frees the result. *)

(* One action object as the desktop will actually dispatch it: the
   sibling tools' "action" renamed to the "do" the client reads.

   Renamed, not merely tolerated. runShellActions looks up
   SHELL_ACTIONS[a.do] and nothing else, so an object still keyed
   "action" would be published, reported to the model as sent, and then
   rejected by the screen as an unknown action. A success the caller
   never receives is worse than the refusal this coercion replaced.

   '' when there is no action name to dispatch on. *)
function NormalizedAction(Src: TJsonObject): string;
var
  One: TJsonObject;
  Verb: string;
begin
  Result := '';
  if Src = nil then Exit;
  Verb := Trim(Src.GetStr('do', ''));
  if Verb = '' then Verb := Trim(Src.GetStr('action', ''));
  if Verb = '' then Exit;
  One := TJsonObject.Parse(Src.ToJSON);
  try
    One.PutStr('do', Verb);
    One.Remove('action');
    Result := One.ToJSON;
  finally
    One.Free;
  end;
end;

(* The same rename across a whole array, because a model that got the
   arity right and the key wrong -- {"actions":[{"action":"tile"}]} --
   fails in exactly the way above.

   nil means "nothing to rename, use what arrived". The rebuild happens
   only when every item is an object with a name to dispatch on: one
   item we cannot read is a malformed request rather than a near miss,
   and passing the original through so the screen names it is better
   than quietly reshaping around it. Caller frees. *)
function RenamedItems(Src: TJsonArray): TJsonArray;
var
  I: Integer;
  Item: TJsonObject;
  Need: Boolean;
begin
  Result := nil;
  if (Src = nil) or (Src.Count = 0) then Exit;

  Need := False;
  for I := 0 to Src.Count - 1 do
  begin
    Item := Src.ItemObject(I);
    try
      if Item = nil then Exit;
      if Trim(Item.GetStr('do', '')) = '' then
      begin
        if Trim(Item.GetStr('action', '')) = '' then Exit;
        Need := True;
      end;
    finally
      Item.Free;
    end;
  end;
  if not Need then Exit;

  Result := TJsonArray.Create;
  for I := 0 to Src.Count - 1 do
  begin
    Item := Src.ItemObject(I);
    try
      Result.AddRaw(NormalizedAction(Item));
    finally
      Item.Free;
    end;
  end;
end;

(* Whatever we settled on, with the rename applied. Every path lands
   here so no shape can reach the feed keyed the way the client cannot
   read. *)
function Dispatchable(var Arr: TJsonArray): TJsonArray;
var
  Fixed: TJsonArray;
begin
  Result := Arr;
  Fixed := RenamedItems(Arr);
  if Fixed <> nil then
  begin
    FreeAndNil(Arr);
    Result := Fixed;
  end;
end;

function CoerceDesktopActions(Obj: TJsonObject): TJsonArray;
var
  One: TJsonObject;
  Raw, Norm: string;
begin
  Result := nil;
  if Obj = nil then Exit;

  { 1. The documented shape. }
  Result := Obj.ChildArray('actions');
  if (Result <> nil) and (Result.Count > 0) then Exit(Dispatchable(Result));
  if Result <> nil then FreeAndNil(Result);

  { 2. A single action object under "actions" rather than a list. }
  One := Obj.ChildObject('actions');
  if One <> nil then
  try
    Norm := NormalizedAction(One);
    if Norm <> '' then
    begin
      Result := TJsonArray.Create;
      Result.AddRaw(Norm);
      Exit;
    end;
  finally
    One.Free;
  end;

  { 3. The array as a STRING -- models stringify JSON arguments often
       enough that refusing it is pedantry. }
  Raw := Trim(Obj.GetStr('actions', ''));
  if (Raw <> '') and (Raw[1] = '[') then
  begin
    try
      Result := TJsonArray.Parse(Raw);
    except
      Result := nil;
    end;
    if (Result <> nil) and (Result.Count > 0) then Exit(Dispatchable(Result));
    if Result <> nil then FreeAndNil(Result);
  end;

  (* 4. The action at the TOP level, unwrapped -- {"do":"tile"} or, from
        the sibling tools' habit, {"action":"build_app","title":...}.
        "action" is read as an action name only here and in 2, where
        there is no actions array to disagree with it. *)
  Norm := NormalizedAction(Obj);
  if Norm <> '' then
  begin
    Result := TJsonArray.Create;
    Result.AddRaw(Norm);
  end;
end;

(* Does this actions array carry the named verb? Reads the coerced
   array, so a near-miss shape cannot smuggle a gated action past the
   check by arriving keyed "action". *)
function ArrayHasAction(Arr: TJsonArray; const Verb: string): Boolean;
var
  I: Integer;
  Item: TJsonObject;
begin
  Result := False;
  if Arr = nil then Exit;
  for I := 0 to Arr.Count - 1 do
  begin
    Item := Arr.ItemObject(I);
    if Item = nil then Continue;
    try
      if SameText(Trim(Item.GetStr('do', '')), Verb) then Exit(True);
    finally
      Item.Free;
    end;
  end;
end;

function DesktopActionsJSON(const ArgsJSON: string): string;
var
  Obj: TJsonObject;
  Arr: TJsonArray;
  Err: string;
begin
  Result := '';
  if not ArgObj(ArgsJSON, Obj, Err) then Exit;
  try
    Arr := CoerceDesktopActions(Obj);
    if Arr = nil then Exit;
    try
      if Arr.Count > 0 then Result := Arr.ToJSON;
    finally
      Arr.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function Tool_Desktop(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Arr: TJsonArray;
  Body: string;
  N: Integer;
begin
  Result := '';
  if not ArgObj(ArgsJSON, Obj, ErrMsg) then Exit;
  try
    Arr := CoerceDesktopActions(Obj);
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      { A worked example, not just a complaint: this text is what the
        model reads before its retry, and "here is the call" recovers a
        turn that "missing required argument" spends. }
      ErrMsg := 'missing required argument: actions. Send an array of ' +
                '{"do":...} objects, e.g. ' +
                '{"actions":[{"do":"build_app","title":"Book compare",' +
                '"brief":"enter four Amazon book URLs and compare them"}]} ' +
                'or {"actions":[{"do":"tile"}]}. Note the plural "actions" ' +
                'and "do" -- this tool takes a LIST of actions, unlike the ' +
                'project/task/agent tools which take a single "action".';
      if Arr <> nil then Arr.Free;
      Exit;
    end;
    (* Refuse BEFORE the command is published, not after the team is
       running: publishing is the point of no return -- the connected
       desktop acts on it immediately. *)
    if (not GTeamActionsAllowed) and ArrayHasAction(Arr, 'team_up') then
    begin
      ErrMsg := 'team_up is off: firing up standing agents is what ' +
                'agent_tools_enabled governs, and it is not enabled on ' +
                'this gateway. Set {"agent_tools_enabled": true} in ' +
                'config.json, or the operator can start a team from the ' +
                'desktop (Start -> New Team...) or with `pasclaw team up`.';
      Arr.Free;
      Exit;
    end;
    N := Arr.Count;
    Body := Arr.ToJSON;
    Arr.Free;
  finally
    Obj.Free;
  end;
  PublishDesktopCommand(Body);
  Result := Format('sent %d desktop action(s) to %d connected desktop(s)',
                   [N, DesktopSubscriberCount]);
end;

procedure RegisterProjectTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;

  T.Name        := 'project';
  T.Description :=
    'Manage the projects on the desktop board. A project is a thing you are ' +
    'building for the user -- its app lives in projects/<name>/app/. ' +
    'action="list" shows every project; action="create" needs a "title" ' +
    '(optional "name" slug, "description"); action="get" needs a "name" and ' +
    'shows its tasks; action="update" edits title/description/icon. Create a ' +
    'project before building anything the user will want to keep or re-open.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","get","update"]},' +
    '"name":{"type":"string","description":"Project slug (get/update; optional on create)."},' +
    '"title":{"type":"string","description":"Display title (create/update)."},' +
    '"description":{"type":"string","description":"What the project is for."},' +
    '"icon":{"type":"string","description":"Desktop icon hint, e.g. Mail (update)."}' +
    '},"required":["action"]}';
  T.Handler     := Tool_Project;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcMutating;
  T.IsDeferred  := False;
  T.Hidden      := False;
  R.Register(T);

  T.Name        := 'task';
  T.Description :=
    'Manage tasks inside a project, and report on the job you are running. ' +
    'action="list" shows the board; action="create" needs "project" and ' +
    '"title"; action="update" needs "id" and can set status ' +
    '(todo/active/done/blocked), assignee, "criteria" (acceptance ' +
    'checks, one per line -- frozen once work starts) and "waits_on" ' +
    '(task ids this one needs done first); action="next" claims your ' +
    'next ready task -- use it to take work; action="job" ' +
    'reports the current run (status done/failed + "summary") and closes ' +
    'the task when done. On a board that requires review you never mark ' +
    'your own work done: action="submit" with "evidence" (what you ran ' +
    'and what it printed) hands it to a reviewer, and the reviewer gives ' +
    'action="verdict" verdict="accept", or verdict="reject" with a ' +
    '"reason". Keep this current as you work -- the user watches this board.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","update","next","job","submit","verdict"]},' +
    '"project":{"type":"string","description":"Project slug (always required)."},' +
    '"id":{"type":"string","description":"Task id, e.g. T0001 (update/job/submit/verdict)."},' +
    '"assignee":{"type":"string","description":"Agent slug that owns the task (update)."},' +
    '"title":{"type":"string","description":"Task title (create/update)."},' +
    '"notes":{"type":"string","description":"Free-text notes on the task."},' +
    '"criteria":{"type":"string","description":"Acceptance checks, one per line (create/update; frozen once the task starts)."},' +
    '"waits_on":{"type":"array","items":{"type":"string"},"description":"Task ids that must be done before this one is ready (create/update; [] clears)."},' +
    '"status":{"type":"string","description":"todo|active|done|blocked for a task; done|failed for a job."},' +
    '"job":{"type":"string","description":"Job id (defaults to the latest job on the task)."},' +
    '"summary":{"type":"string","description":"What the job accomplished (action=job)."},' +
    '"evidence":{"type":"string","description":"What you ran and what it printed (action=submit)."},' +
    '"verdict":{"type":"string","enum":["accept","reject"],"description":"action=verdict."},' +
    '"reason":{"type":"string","description":"Why it is rejected, with exact reproduction steps (required to reject)."}' +
    '},"required":["action","project"]}';
  T.Handler     := Tool_Task;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcMutating;
  T.IsDeferred  := False;
  T.Hidden      := False;
  R.Register(T);

  { The board tools imply the screen tool -- an operator who asked for
    the model to manage the board gets the same set as before this
    split. The gateway registers the screen tool on its own as well. }
  RegisterDesktopTool(R);
end;

procedure RegisterDesktopTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;

  T.Name        := 'desktop';
  T.Description :=
    'Arrange the desktop the user is looking at: window layout, opening ' +
    'apps and projects, the theme. Pass "actions" as an array of ' +
    '{"do":...} objects, several at once when the user asks for several ' +
    'things. Actions: tile, cascade, minimize_all, close_all, refresh, ' +
    'open_app {project}, open_chat {project}, open_agent {agent}, ' +
    'build_app {title,brief}, ' +
    IfThenStr(GTeamActionsAllowed, 'team_up {template,brief|project}, ', '') +
    'theme {id}. Use this when the user talks about the SCREEN -- tidying ' +
    'windows, opening something, starting several apps at once' +
    IfThenStr(GTeamActionsAllowed,
              ' -- or asks to spin up an agent TEAM (team_up).', '.');
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"actions":{"type":"array","description":' +
    (* Escaped \" -- NOT the Pascal doubling convention. Written as
       ""do"" this schema did not parse, and PutRaw answers an
       unparseable schema by substituting {} without a word, so every
       provider was told `desktop` takes no arguments. The model obeyed:
       desktop() with nothing in it, every time, and no error text can
       argue a model out of the schema it was given. *)
    '"Desktop actions in order, e.g. [{\"do\": \"tile\"}].",' +
    '"items":{"type":"object","properties":{' +
    '"do":{"type":"string"},"project":{"type":"string"},' +
    '"title":{"type":"string"},"brief":{"type":"string"},' +
    '"agent":{"type":"string"},"template":{"type":"string"},' +
    '"id":{"type":"string"}},"required":["do"]}}' +
    '},"required":["actions"]}';
  T.Handler     := Tool_Desktop;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  { Read-only: it moves windows in a browser, it does not touch the
    workspace -- so it stays available in plan mode, where "show me what
    you would do, and tidy the screen while you explain" is reasonable. }
  T.Category    := tcReadOnly;
  T.IsDeferred  := False;
  T.Hidden      := False;
  R.Register(T);
end;

initialization
  { Installed here, where the scenario runner is in reach: every binary
    that can run an agent links this unit, and the store must not link
    the shell backend to get it. }
  OnSubmitGate := ProjectScenarioGate;
  OnTaskClosed := NotifyDependents;

end.