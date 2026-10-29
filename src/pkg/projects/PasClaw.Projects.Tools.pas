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

(* project / task / rule. AskOutsideAgents registers them as a standing
   agent's tools that an ordinary chat finds with tool_search and may call
   only with the operator's say-so (TTool.AskOutsideAgents) -- the default;
   desktop_tools_enabled registers them plainly for everyone. *)
procedure RegisterProjectTools(R: TToolRegistry; AskOutsideAgents: Boolean = False);

{ Handlers, exposed for tests. }
function Tool_Project(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Task(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Rule(const ArgsJSON: string; out ErrMsg: string): string;

(* A held-out check for a repeated cause, PROVEN before anyone sees it
   (docs/team-board-plan.md, Phase 4): the script must fail against the
   snapshot of a submission rejected for Cause and pass against the
   snapshot of that task's accepted fix. Proven, it becomes a decision
   for the operator (Install = False -- the `rule` tool) or goes straight
   into the project's scenarios (Install = True -- the operator's own
   rule, POST /v1/projects/<p>/rules). Report says what the proof found
   either way; Err is why nothing happened. *)
function ProposeRule(const Project, Cause, Name, Script, Actor: string;
  Install: Boolean; out Report, Err: string): Boolean;

{ The rule files installed for a project, its rule and declined causes,
  and how often each cause has rejected work -- as JSON. }
function RulesJSON(const Project: string): string;

(* Does a lane glob cover a workspace-relative path ('/'-separated)?
   '**' is any run of whole segments (including none), '*' any run within
   one segment, '?' one character that is not '/'. Exposed for tests. *)
function LaneMatches(const Glob, RelPath: string): Boolean;

(* A task was just created on Project by Actor -- assignee and waits_on
   already applied. Tells the team working the board what it has to do
   about it: a board-parked team goes back on, and ready work nobody owns
   reaches the board's takers, or its leads when nobody takes. Assigned
   work has already told its owner (OnTaskAssigned); work that waits is
   news when what it waits on is done (NotifyDependents). The leads are
   not told about tasks they made themselves. *)
procedure AnnounceNewTask(const Project, TaskId, Actor: string);
function Tool_Desktop(const ArgsJSON: string; out ErrMsg: string): string;

(* Exposed for tests: what a `desktop` call is READ as, before anything
   is published. Returns the actions array as JSON, or '' when the call
   carried nothing usable. Publishing is the side effect; this is the
   decision, and the decision is what is worth pinning. *)
function DesktopActionsJSON(const ArgsJSON: string): string;

(* The consent question for a desktop call, '' when there is none: a
   team_up action -- in any shape the tool accepts -- asks the operator
   first unless agent_tools_enabled said yes for good. Installed as the
   tool loop's ConsentProbe; public for its tests. *)
function DesktopConsent(const ToolName, ArgsJSON: string): string;

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
  PasClaw.Agent.Verify,    { RunScenarios -- the gate on submit, and a rule's proof }
  PasClaw.Decisions,       { a proven rule waits for the operator }
  PasClaw.Projects.Snapshots,  { what a rule is proven against }
  PasClaw.Config,          { GetHome -- where drafts are kept }
  PasClaw.Workspaces,      { ActiveWorkspaceName }
  PasClaw.Tools.Sandbox;   { OnLaneCheck -- lanes bind the file tools }

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

(* Notes grow -- agents add to them -- and the board listing is read on
   every wake, every task at once. Past a page, the listing keeps the
   start (the brief) and the end (the latest word); the cut says how
   much it left out. *)
function ListedNotes(const Notes: string): string;
const
  Keep = 300;
begin
  Result := Notes;
  if Length(Result) > 3 * Keep then
    Result := Copy(Result, 1, Keep) + ' [... ' +
              IntToStr(Length(Result) - 2 * Keep) + ' chars ...] ' +
              Copy(Result, Length(Result) - Keep + 1, Keep);
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
      S := S + '      ' + ListedNotes(Rows[I].Notes) + #10;
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

{ The leads of the team(s) working this board -- who a repeated cause is
  reported to, and who hands out a task nobody owns. }
function LeadsFor(const Project: string): TStringArray;
var
  States: TTeamStateArray;
  T: TTeamTemplate;
  Leads: TStringArray;
  I, J: Integer;
begin
  SetLength(Result, 0);
  States := ListTeamStates;
  for I := 0 to High(States) do
    if (States[I].Project = Project) and FindTeamTemplate(States[I].Name, T) then
    begin
      Leads := TeamLeads(T);
      for J := 0 to High(Leads) do
        if not InList(Leads[J], Result) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Leads[J];
        end;
    end;
end;

(* OnTaskClosed: a task reached done, so tasks that waited on it may be
   ready now. Their owners are told -- which is also what makes their
   team due on the next tick instead of at the next cadence. An unowned
   one is offered to the board's takers by the wake loop; on a board
   with no takers nobody would ever claim it, so the leads are told
   instead -- handing work out is theirs. *)
procedure NotifyDependents(const Project, TaskId: string);
var
  Board: TTaskInfoArray;
  Leads: TStringArray;
  I, K: Integer;
  Waited, LeadsKnown: Boolean;
  Delivered, Err: string;
begin
  Board := ListTasks(Project);
  LeadsKnown := False;
  for I := 0 to High(Board) do
  begin
    if Board[I].Status <> tsTodo then Continue;
    Waited := False;
    for K := 0 to High(Board[I].WaitsOn) do
      if Board[I].WaitsOn[K] = UpperCase(TaskId) then Waited := True;
    if not Waited or not TaskReady(Board[I], Board) then Continue;
    if Board[I].Assignee <> '' then
      AgentSend(Board[I].Assignee, 'board',
                Format('%s ("%s") on %s is ready: %s, the last thing it waited ' +
                       'on, is done. Claim it with task action="next" ' +
                       'project="%s".',
                       [Board[I].Id, Board[I].Title, Project, UpperCase(TaskId),
                        Project]), Delivered, Err)
    else if Length(ProjectTakers(Project)) = 0 then
    begin
      if not LeadsKnown then
      begin
        Leads := LeadsFor(Project);
        LeadsKnown := True;
      end;
      for K := 0 to High(Leads) do
        AgentSend(Leads[K], 'board',
                  Format('%s ("%s") on %s is ready -- %s, the last thing it ' +
                         'waited on, is done -- and nobody owns it. Assign it: ' +
                         'task action="update" project="%s" id="%s" ' +
                         'assignee="<agent>".',
                         [Board[I].Id, Board[I].Title, Project, UpperCase(TaskId),
                          Project, Board[I].Id]), Delivered, Err);
    end;
  end;
end;

procedure AnnounceNewTask(const Project, TaskId, Actor: string);
var
  Board: TTaskInfoArray;
  T: TTaskInfo;
  Leads, Takers: TStringArray;
  I: Integer;
  Text, Delivered, Err: string;
begin
  ResumeParkedTeams(Project);
  if not GetTask(Project, TaskId, T) then Exit;
  if (T.Status <> tsTodo) or (T.Assignee <> '') then Exit;
  Board := ListTasks(Project);
  if not TaskReady(T, Board) then Exit;
  Leads := LeadsFor(Project);
  if Length(Leads) = 0 then Exit;   { no team works this board }
  if InList(Actor, Leads) then Exit;
  Takers := ProjectTakers(Project);
  if Length(Takers) > 0 then
  begin
    Text := Format('%s added %s ("%s") on %s; it is ready and nobody owns ' +
                   'it. Claim it with task action="next" project="%s".',
                   [ActorLabel(Actor), T.Id, T.Title, Project, Project]);
    for I := 0 to High(Takers) do
      if Takers[I] <> Actor then
        AgentSend(Takers[I], 'board', Text, Delivered, Err);
    Exit;
  end;
  Text := Format('%s added %s ("%s") on %s and nobody owns it. Assign it: ' +
                 'task action="update" project="%s" id="%s" assignee="<agent>".',
                 [ActorLabel(Actor), T.Id, T.Title, Project, Project, T.Id]);
  for I := 0 to High(Leads) do
    AgentSend(Leads[I], 'board', Text, Delivered, Err);
end;

(* OnTaskAssigned: the task changed hands, so its new owner hears -- if
   it can start it now. One still waiting on other work is not news yet:
   NotifyDependents tells the owner when the last of it is done. *)
procedure NotifyAssignee(const Project, TaskId, Assignee, Actor: string);
var
  Board: TTaskInfoArray;
  T: TTaskInfo;
  Delivered, Err: string;
begin
  if not GetTask(Project, TaskId, T) then Exit;
  if not (T.Status in [tsTodo, tsActive]) then Exit;
  if T.Status = tsTodo then
  begin
    Board := ListTasks(Project);
    if not TaskReady(T, Board) then Exit;
  end;
  AgentSend(Assignee, ActorLabel(Actor),
            Format('%s ("%s") on %s is assigned to you by %s. Take it with ' +
                   'task action="next" project="%s".',
                   [T.Id, T.Title, Project, ActorLabel(Actor), Project]),
            Delivered, Err);
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
      (* Creating a task and handing it out are one move for a lead, and
         an assignee dropped here was silent: the task sat unowned while
         its intended owner was told it had nothing ready. After the
         edge, so the owner is told "it is yours" only when it is ready
         to start (NotifyAssignee reads waits_on). *)
      Assignee := Trim(Obj.GetStr('assignee', ''));
      if Assignee <> '' then
      begin
        if UpdateTask(Project, Id, '', '-', '', Err, Assignee, '-', Actor) then
        begin
          if GetTask(Project, Id, T) then Assignee := T.Assignee;
          Result := Result + ' (assigned to ' + Assignee + ')';
        end
        else
          Result := Result + '. Its assignee was NOT set: ' + Err;
      end;
      AnnounceNewTask(Project, Id, Actor);
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
      (* An agent's note is ADDED to the task's notes. Every role is told
         to "describe what changed in the task notes", and replacing
         meant the first progress note erased the brief the lead wrote --
         the output format, the constraints -- with nothing to say so.
         The operator's edit (PATCH) still replaces: that is an editor. *)
      if (Notes <> '-') and (Trim(Notes) <> '') and IsAgentCaller(Actor) and
         GetTask(Project, Id, T) and (Trim(T.Notes) <> '') and
         (Pos(Trim(T.Notes), Notes) = 0) then
        Notes := TrimRight(T.Notes) + #10'[' + Actor + '] ' + Trim(Notes);
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
      if not VerdictTask(Project, Id, Actor, Accept, Reason, Revs, Err,
                         Obj.GetStr('cause', '')) then
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

{ ------------------------------------------------------------------ rules -- }

function Names2(const A, B: string): TStringArray;
begin
  SetLength(Result, 2);
  Result[0] := A;
  Result[1] := B;
end;

{ One field of one activity line. }
function LineField(const Line, Key: string): string;
var
  O: TJsonObject;
begin
  Result := '';
  O := nil;
  try
    O := TJsonObject.Parse(Line);
  except
    O := nil;
  end;
  if O = nil then Exit;
  try
    Result := O.GetStr(Key, '');
  finally
    O.Free;
  end;
end;

type
  { A submission rejected for the cause, and the same task's accepted fix. }
  TProofPair = record
    Task, Rejected, Accepted: string;   { task id, two snapshot ids }
  end;

(* The newest reject for Cause that has a snapshot and a LATER accept of
   the same task with one. Newest first, because the most recent instance
   of a mistake is the one the current code most resembles. *)
function FindProofPair(const Project, Cause: string; out P: TProofPair): Boolean;
var
  Lines: TStringArray;
  I, J: Integer;
  Tk: string;
begin
  Result := False;
  P := Default(TProofPair);
  Lines := ReadActivity(Project, '');
  for I := High(Lines) downto 0 do
  begin
    if (LineField(Lines[I], 'event') <> 'reject') or
       (LineField(Lines[I], 'cause') <> Cause) or
       (LineField(Lines[I], 'snapshot') = '') then Continue;
    Tk := LineField(Lines[I], 'task');
    for J := I + 1 to High(Lines) do
      if (LineField(Lines[J], 'event') = 'accept') and
         (LineField(Lines[J], 'task') = Tk) and
         (LineField(Lines[J], 'snapshot') <> '') then
      begin
        P.Task := Tk;
        P.Rejected := LineField(Lines[I], 'snapshot');
        P.Accepted := LineField(Lines[J], 'snapshot');
        Exit(True);
      end;
  end;
end;

{ Rejects naming Cause on the board, and the distinct tasks they hit. }
function CauseRejects(const Project, Cause: string; out Tasks: TStringArray): Integer;
var
  Lines: TStringArray;
  I: Integer;
  Tk: string;
begin
  Result := 0;
  SetLength(Tasks, 0);
  Lines := ReadActivity(Project, '');
  for I := 0 to High(Lines) do
    if (LineField(Lines[I], 'event') = 'reject') and
       (LineField(Lines[I], 'cause') = Cause) then
    begin
      Inc(Result);
      Tk := LineField(Lines[I], 'task');
      if not InList(Tk, Tasks) then
      begin
        SetLength(Tasks, Length(Tasks) + 1);
        Tasks[High(Tasks)] := Tk;
      end;
    end;
end;

{ An open rule decision for this project and cause, or ''. }
function OpenRuleDecision(const Project, Cause: string): string;
var
  Open: TDecisionInfoArray;
  I: Integer;
  P: TJsonObject;
begin
  Result := '';
  Open := ListDecisions(True);
  for I := 0 to High(Open) do
  begin
    if (Open[I].Kind <> 'rule') or (Open[I].Project <> Project) or
       (Open[I].Payload = '') then Continue;
    P := TJsonObject.Parse(Open[I].Payload);
    if P = nil then Continue;
    try
      if P.GetStr('cause', '') = Cause then Exit(Open[I].Id);
    finally
      P.Free;
    end;
  end;
end;

(* Drafts live beside the scenarios, never in them -- a draft in the
   scenarios directory would already be gating submissions before anyone
   approved it -- and outside the workspace for the same reason. *)
function RuleDraftDir(const Project, Cause: string): string;
begin
  Result := JoinPath(JoinPath(JoinPath(JoinPath(GetHome, 'scenario-drafts'),
                     ActiveWorkspaceName), Project), Cause);
end;

{ A safe file name for the rule: [a-z0-9._-], .sh or .py, default <cause>.sh. }
function RuleFileName(const Name, Cause: string): string;
var
  I: Integer;
  S: string;
begin
  S := '';
  for I := 1 to Length(Name) do
    if LowerCase(Name)[I] in ['a'..'z', '0'..'9', '-', '_', '.'] then
      S := S + LowerCase(Name)[I];
  while (S <> '') and (S[1] = '.') do Delete(S, 1, 1);
  if S = '' then S := Cause;
  if not (SameText(ExtractFileExt(S), '.sh') or SameText(ExtractFileExt(S), '.py')) then
    S := S + '.sh';
  Result := S;
end;

(* Into the project's held-out scenarios -- from where every submit is
   held to it by the Phase 1 gate. Never over an existing check. *)
function InstallRule(const Project, Cause, DraftPath, FileName, Actor: string;
  out Installed, Err: string): Boolean;
var
  Dir, Dest, Base, Ext: string;
  N: Integer;
begin
  Result := False;
  Installed := '';
  Err := '';
  if not FileExists(DraftPath) then
  begin
    Err := 'the proven draft is gone (' + DraftPath + ')';
    Exit;
  end;
  Dir := ProjectScenariosDir(Project);
  ForceDirectories(Dir);
  Ext := ExtractFileExt(FileName);
  Base := ChangeFileExt(FileName, '');
  Dest := JoinPath(Dir, FileName);
  N := 2;
  while FileExists(Dest) do
  begin
    Dest := JoinPath(Dir, Base + '-' + IntToStr(N) + Ext);
    Inc(N);
  end;
  WriteFileText(Dest, ReadFileText(DraftPath));
  AddProjectCause(Project, 'rule_causes', Cause, Err);
  Err := '';
  Installed := ExtractFileName(Dest);
  RecordActivity(Project, '', 'rule', Actor, ['cause', Cause, 'file', Installed]);
  Result := True;
end;

function ProposeRule(const Project, Cause, Name, Script, Actor: string;
  Install: Boolean; out Report, Err: string): Boolean;
var
  C, FileName, DraftDir, DraftPath, RejDir, AccDir, Id, Q, Installed: string;
  P: TProofPair;
  R1, R2: TScenarioResults;
  Failed1, Passed2: Boolean;
  Obj, Sub: TJsonObject;
  SR: TSearchRec;

  function Outcome(const R: TScenarioResults): string;
  begin
    if Length(R) = 0 then Exit('did not run');
    if R[0].Passed then Result := 'passed' else
      Result := Format('failed (exit %d)', [R[0].ExitCode]);
    if R[0].Output <> '' then
      Result := Result + #10'    output: ' + FirstLine(R[0].Output);
  end;

begin
  Report := '';
  Err := '';
  Result := False;
  if not ProjectExists(Project) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  C := SanitizeName(Cause);
  if C = '' then
  begin
    Err := 'a rule needs the "cause" it catches -- the key the reviewer ' +
           'gave the rejects (e.g. untested-empty-input)';
    Exit;
  end;
  if Trim(Script) = '' then
  begin
    Err := 'a rule needs a "script": a shell (or python) check that exits ' +
           '0 when the work is right, run with the project as its cwd';
    Exit;
  end;
  if not Install then
  begin
    Id := OpenRuleDecision(Project, C);
    if Id <> '' then
    begin
      Err := Id + ' already proposes a rule for "' + C + '"; it is waiting ' +
             'for the operator.';
      Exit;
    end;
  end;
  if not FindProofPair(Project, C, P) then
  begin
    Err := 'nothing to prove "' + C + '" against yet: a rule has to FAIL on ' +
           'a submission that was rejected for it and PASS on that task''s ' +
           'accepted fix, and ' + Project + ' has no task rejected for "' + C +
           '" that was accepted since (with both submissions snapshotted).';
    Exit;
  end;
  RejDir := SnapshotDir(Project, P.Task, P.Rejected);
  AccDir := SnapshotDir(Project, P.Task, P.Accepted);
  if not (DirectoryExists(RejDir) and DirectoryExists(AccDir)) then
  begin
    Err := 'the snapshots of ' + P.Task + ' it would be proven against are ' +
           'gone (older ones are pruned).';
    Exit;
  end;

  (* The draft alone in its directory, so RunScenarios runs exactly it. *)
  FileName := RuleFileName(Name, C);
  DraftDir := RuleDraftDir(Project, C);
  ForceDirectories(DraftDir);
  if FindFirst(JoinPath(DraftDir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
        SysUtils.DeleteFile(JoinPath(DraftDir, SR.Name));
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  DraftPath := JoinPath(DraftDir, FileName);
  WriteFileText(DraftPath, Script);

  RunScenarios(ExpandFileName(DraftDir), ExpandFileName(RejDir), R1);
  RunScenarios(ExpandFileName(DraftDir), ExpandFileName(AccDir), R2);
  Failed1 := (Length(R1) = 1) and not R1[0].Passed;
  Passed2 := (Length(R2) = 1) and R2[0].Passed;
  Report := 'proof for "' + C + '" on ' + P.Task + ':'#10 +
            '  the rejected submission (' + P.Rejected + '): ' + Outcome(R1) + #10 +
            '  the accepted fix (' + P.Accepted + '): ' + Outcome(R2);
  if not Failed1 then
  begin
    Err := 'not proven: the check does not catch "' + C + '" -- it passed on ' +
           'the submission that was rejected for it.'#10 + Report;
    Exit;
  end;
  if not Passed2 then
  begin
    Err := 'not proven: the check would reject good work -- it failed on ' +
           'the accepted fix.'#10 + Report;
    Exit;
  end;

  if Install then
  begin
    if not InstallRule(Project, C, DraftPath, FileName, Actor, Installed, Err) then Exit;
    Report := 'Proven and installed as ' + Installed + ' in ' +
              ProjectScenariosDir(Project) + '; every submit on ' + Project +
              ' is held to it from now on.'#10 + Report;
    Result := True;
    Exit;
  end;

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('cause', C);
    Obj.PutStr('name', FileName);
    Obj.PutStr('draft', DraftPath);
    Obj.PutStr('script', Copy(Script, 1, 4000));
    Sub := TJsonObject.Create;
    Sub.PutStr('task', P.Task);
    Sub.PutStr('snapshot', P.Rejected);
    Obj.PutObject('rejected', Sub);
    Sub := TJsonObject.Create;
    Sub.PutStr('task', P.Task);
    Sub.PutStr('snapshot', P.Accepted);
    Obj.PutObject('accepted', Sub);
    Q := 'Add a held-out check for "' + C + '" to ' + Project + '? It fails ' +
         'on ' + P.Task + '''s rejected submission and passes on its ' +
         'accepted fix; approved, every submit is held to it.';
    Id := CreateDecision('rule', ActorLabel(Actor), Q, Names2('approve', 'decline'),
                         Project, '', '', Obj.ToJSON, Err);
  finally
    Obj.Free;
  end;
  if Id = '' then Exit;
  Report := 'Proven, and waiting for the operator as ' + Id + ' (approve or ' +
            'decline in Needs you).'#10 + Report;
  Result := True;
end;

(* A rule decision answered: approve installs the proven draft, decline
   records the cause so it does not nag again. The asker hears either way
   from PasClaw.Agents.Tools's listener. *)
procedure RuleDecisionAnswered(const D: TDecisionInfo);
var
  P: TJsonObject;
  Cause, Draft, Name_, Installed, Err: string;
begin
  if (D.Kind <> 'rule') or (D.Payload = '') then Exit;
  P := TJsonObject.Parse(D.Payload);
  if P = nil then Exit;
  try
    Cause := P.GetStr('cause', '');
    Draft := P.GetStr('draft', '');
    Name_ := P.GetStr('name', Cause + '.sh');
  finally
    P.Free;
  end;
  if SameText(D.Answer, 'approve') then
  begin
    if not InstallRule(D.Project, Cause, Draft, Name_, D.AnsweredBy, Installed, Err) then
      RecordActivity(D.Project, '', 'rule-failed', D.AnsweredBy,
                     ['cause', Cause, 'reason', Err]);
  end
  else
  begin
    AddProjectCause(D.Project, 'declined_causes', Cause, Err);
    RecordActivity(D.Project, '', 'rule-declined', D.AnsweredBy, ['cause', Cause]);
  end;
end;

(* OnTaskRejected: the second time one cause rejects work on a board, the
   lead hears -- the cause, the tasks, and the call that turns it into a
   proven rule. Not again once a rule exists, the operator declined one,
   or a draft is waiting. *)
procedure NoticeRepeatedCause(const Project, TaskId, Cause: string);
var
  Tasks, Leads: TStringArray;
  N, I: Integer;
  Text, Delivered, Err: string;
begin
  N := CauseRejects(Project, Cause, Tasks);
  if N < 2 then Exit;
  if InList(Cause, ProjectCauses(Project, 'rule_causes')) or
     InList(Cause, ProjectCauses(Project, 'declined_causes')) or
     (OpenRuleDecision(Project, Cause) <> '') then Exit;
  Leads := LeadsFor(Project);
  Text := Format('Cause "%s" has now rejected work %d times on %s (%s). If ' +
                 'a check would catch it, draft one: rule action="draft" ' +
                 'project="%s" cause="%s" script="..." -- it must fail on the ' +
                 'rejected submission and pass on the accepted fix, and then ' +
                 'the operator decides whether every submit is held to it.',
                 [Cause, N, Project, JoinList(Tasks), Project, Cause]);
  for I := 0 to High(Leads) do
    AgentSend(Leads[I], 'board', Text, Delivered, Err);
end;

function RulesJSON(const Project: string): string;
var
  Root, Item: TJsonObject;
  Arr, TArr: TJsonArray;
  Lines, Seen, Tasks, L: TStringArray;
  SR: TSearchRec;
  I, J: Integer;
  C, Dir: string;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Dir := ProjectScenariosDir(Project);
    if (Dir <> '') and (FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0) then
    try
      repeat
        if ((SR.Attr and faDirectory) = 0) and (SR.Name <> '') and (SR.Name[1] <> '.') then
          Arr.AddStr(SR.Name);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Root.PutArray('rules', Arr);
    Arr := TJsonArray.Create;
    L := ProjectCauses(Project, 'rule_causes');
    for I := 0 to High(L) do Arr.AddStr(L[I]);
    Root.PutArray('rule_causes', Arr);
    Arr := TJsonArray.Create;
    L := ProjectCauses(Project, 'declined_causes');
    for I := 0 to High(L) do Arr.AddStr(L[I]);
    Root.PutArray('declined_causes', Arr);
    Arr := TJsonArray.Create;
    SetLength(Seen, 0);
    Lines := ReadActivity(Project, '');
    for I := 0 to High(Lines) do
    begin
      C := LineField(Lines[I], 'cause');
      if (LineField(Lines[I], 'event') <> 'reject') or (C = '') or InList(C, Seen) then
        Continue;
      SetLength(Seen, Length(Seen) + 1);
      Seen[High(Seen)] := C;
      Item := TJsonObject.Create;
      Item.PutStr('cause', C);
      Item.PutInt('rejects', CauseRejects(Project, C, Tasks));
      TArr := TJsonArray.Create;
      for J := 0 to High(Tasks) do TArr.AddStr(Tasks[J]);
      Item.PutArray('tasks', TArr);
      Item.PutStr('open_draft', OpenRuleDecision(Project, C));
      Arr.AddObject(Item);
    end;
    Root.PutArray('causes', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function Tool_Rule(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Action, Project, Report, Err: string;
begin
  ErrMsg := '';
  Result := '';
  if not ArgObj(ArgsJSON, Obj, ErrMsg) then Exit;
  try
    Action  := LowerCase(Trim(Obj.GetStr('action', '')));
    Project := Trim(Obj.GetStr('project', ''));
    if Project = '' then
    begin
      ErrMsg := 'every rule action needs a "project"';
      Exit;
    end;
    if (Action = '') or (Action = 'list') then
    begin
      if not ProjectExists(Project) then
      begin
        ErrMsg := 'no such project: ' + Project;
        Exit;
      end;
      Result := RulesJSON(Project);
      Exit;
    end;
    if Action = 'draft' then
    begin
      if not ProposeRule(Project, Obj.GetStr('cause', ''), Obj.GetStr('name', ''),
                         Obj.GetStr('script', ''), TaskActor, False, Report, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := Report;
      Exit;
    end;
    ErrMsg := 'unknown action "' + Action + '" (use draft or list)';
  finally
    Obj.Free;
  end;
end;

{ ------------------------------------------------------------------ lanes -- }

function GlobFrom(const P, S: string; PIdx, SIdx: Integer): Boolean;
var
  K: Integer;
  Boundary: Boolean;
begin
  while PIdx <= Length(P) do
  begin
    if (P[PIdx] = '*') and (PIdx < Length(P)) and (P[PIdx + 1] = '*') then
    begin
      Inc(PIdx, 2);
      { "**/" matches at segment starts only, so **/app.json is not
        satisfied by notapp.json. }
      Boundary := (PIdx <= Length(P)) and (P[PIdx] = '/');
      if Boundary then Inc(PIdx);
      for K := SIdx to Length(S) + 1 do
        if ((not Boundary) or (K = SIdx) or (S[K - 1] = '/')) and
           GlobFrom(P, S, PIdx, K) then Exit(True);
      Exit(False);
    end;
    if P[PIdx] = '*' then
    begin
      Inc(PIdx);
      for K := SIdx to Length(S) + 1 do
      begin
        if GlobFrom(P, S, PIdx, K) then Exit(True);
        if (K <= Length(S)) and (S[K] = '/') then Break;
      end;
      Exit(False);
    end;
    if SIdx > Length(S) then Exit(False);
    if P[PIdx] = '?' then
    begin
      if S[SIdx] = '/' then Exit(False);
    end
    else if P[PIdx] <> S[SIdx] then Exit(False);
    Inc(PIdx);
    Inc(SIdx);
  end;
  Result := SIdx > Length(S);
end;

function LaneMatches(const Glob, RelPath: string): Boolean;
var
  G, P: string;
begin
  G := StringReplace(Trim(Glob), '\', '/', [rfReplaceAll]);
  P := StringReplace(RelPath, '\', '/', [rfReplaceAll]);
  {$IFDEF MSWINDOWS}
  G := LowerCase(G);
  P := LowerCase(P);
  {$ENDIF}
  Result := (G <> '') and GlobFrom(G, P, 1, 1);
end;

(* OnLaneCheck: a team agent with a lane writes only inside it.

   The caller is the agent whose turn is running; a turn that is not a
   standing agent's has no lane and is not checked. A laned agent's write
   anywhere else -- including outside the workspace -- is refused, and the
   refusal says whose lane the path IS in, because "message pm instead"
   is the next move and "permission denied" is not. Lanes bind the file
   tools only: a shell command's writes cannot be path-checked, and the
   plan says so rather than pretending. *)
function LaneCheck(const CanonPath: string; out Reason: string): Boolean;
var
  Agent, Root, Rel, Owner: string;
  Lanes: TLaneArray;
  Mine: TStringArray;
  I, J: Integer;
begin
  Result := True;
  Reason := '';
  Agent := CallingAgent;
  if Agent = '' then Exit;
  Lanes := AllLanes;
  SetLength(Mine, 0);
  for I := 0 to High(Lanes) do
    if Lanes[I].Agent = Agent then
      for J := 0 to High(Lanes[I].Globs) do
      begin
        SetLength(Mine, Length(Mine) + 1);
        Mine[High(Mine)] := Lanes[I].Globs[J];
      end;
  if Length(Mine) = 0 then Exit;

  Root := ExcludeTrailingPathDelimiter(ExpandFileName(ActiveWorkspaceRoot));
  Rel := '';
  if PathInsideDirectory(CanonPath, Root) and (Length(CanonPath) > Length(Root)) then
    Rel := StringReplace(Copy(CanonPath, Length(Root) + 2, MaxInt), '\', '/',
                         [rfReplaceAll]);
  if Rel <> '' then
    for I := 0 to High(Mine) do
      if LaneMatches(Mine[I], Rel) then Exit(True);

  Owner := '';
  if Rel <> '' then
    for I := 0 to High(Lanes) do
      if (Lanes[I].Agent <> Agent) and (Owner = '') then
        for J := 0 to High(Lanes[I].Globs) do
          if LaneMatches(Lanes[I].Globs[J], Rel) then
          begin
            Owner := Lanes[I].Agent;
            Break;
          end;
  Result := False;
  if Rel = '' then
    Reason := 'refused: outside ' + Agent + '''s lane -- ' + CanonPath +
              ' is not in the workspace, and ' + Agent + ' writes only in ' +
              JoinList(Mine) + '.'
  else if Owner <> '' then
    Reason := 'refused: outside ' + Agent + '''s lane: ' + Rel + ' is ' +
              Owner + '''s. Message ' + Owner + ' instead (agent action=send).'
  else
    Reason := 'refused: outside ' + Agent + '''s lane: ' + Rel + ' is not in ' +
              JoinList(Mine) + '. Ask your lead if your lane should change.';
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
function ArrayHasAction(Arr: TJsonArray; const Verb: string): Boolean; forward;

(* The consent probe for the desktop tool: a team_up action starts
   standing agents that go on working by themselves, so an ordinary chat's
   call that includes one asks the operator first -- unless
   agent_tools_enabled said yes for good. Tiling windows asks nothing. *)
function DesktopConsent(const ToolName, ArgsJSON: string): string;
var
  Arr: TJsonArray;
  Coerced: string;
begin
  Result := '';
  if (ToolName <> 'desktop') or GTeamActionsAllowed then Exit;
  (* The COERCED array, as the tool itself will read it -- so a team_up in
     a near-miss shape ({"action":"team_up"}, "TEAM_UP") asks like any. *)
  Coerced := DesktopActionsJSON(ArgsJSON);
  if Coerced = '' then Exit;
  try
    Arr := TJsonArray.Parse(Coerced);
  except
    Exit;
  end;
  if Arr = nil then Exit;
  try
    if ArrayHasAction(Arr, 'team_up') then
      Result := 'This chat wants to start an agent team (team_up): standing ' +
                'agents that plan, build and review on their own until the ' +
                'board is done.';
  finally
    Arr.Free;
  end;
end;

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
    (* team_up is the operator's to allow. From the tool loop the gate
       asked it BEFORE this ran (DesktopConsent); a call that never met
       the gate -- PasClaw's MCP server runs tools directly, and the
       desktop tool is exposed read-only -- was never asked, and is
       refused here, before the publish: the point of no return, since
       the connected desktop acts on it immediately. *)
    if (not GTeamActionsAllowed) and (not DispatchGatePassed) and
       ArrayHasAction(Arr, 'team_up') then
    begin
      ErrMsg := 'team_up needs the operator''s say-so, which a chat asks ' +
                'for; this call did not come through one. The operator can ' +
                'start a team from the desktop (Start -> Software Factory) ' +
                'or with `pasclaw team up`.';
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

procedure RegisterProjectTools(R: TToolRegistry; AskOutsideAgents: Boolean);
var
  T: TTool;

  procedure Add(const T: TTool);
  begin
    if AskOutsideAgents then R.RegisterAskOutsideAgents(T) else R.Register(T);
  end;

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
  Add(T);

  T.Name        := 'task';
  T.Description :=
    'Manage tasks inside a project, and report on the job you are running. ' +
    'action="list" shows the board; action="create" needs "project" and ' +
    '"title" (and takes assignee, criteria and waits_on too); ' +
    'action="update" needs "id" and can set status ' +
    '(todo/active/done/blocked), assignee, "criteria" (acceptance ' +
    'checks, one per line -- frozen once work starts) and "waits_on" ' +
    '(task ids this one needs done first); action="next" claims your ' +
    'next ready task -- use it to take work; action="job" ' +
    'reports the current run (status done/failed + "summary") and closes ' +
    'the task when done. On a board that requires review you never mark ' +
    'your own work done: action="submit" with "evidence" (what you ran ' +
    'and what it printed) hands it to a reviewer, and the reviewer gives ' +
    'action="verdict" verdict="accept", or verdict="reject" with a ' +
    '"reason" and a "cause" (a short key for the kind of mistake, reused ' +
    'across tasks). Keep this current as you work -- the user watches ' +
    'this board.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","update","next","job","submit","verdict"]},' +
    '"project":{"type":"string","description":"Project slug (always required)."},' +
    '"id":{"type":"string","description":"Task id, e.g. T0001 (update/job/submit/verdict)."},' +
    '"assignee":{"type":"string","description":"Agent slug that owns the task (create/update)."},' +
    '"title":{"type":"string","description":"Task title (create/update)."},' +
    '"notes":{"type":"string","description":"Free-text notes on the task. An agent''s notes on update are added under its name; the earlier notes stay."},' +
    '"criteria":{"type":"string","description":"Acceptance checks, one per line (create/update; frozen once the task starts)."},' +
    '"waits_on":{"type":"array","items":{"type":"string"},"description":"Task ids that must be done before this one is ready (create/update; [] clears)."},' +
    '"status":{"type":"string","description":"todo|active|done|blocked for a task; done|failed for a job."},' +
    '"job":{"type":"string","description":"Job id (defaults to the latest job on the task)."},' +
    '"summary":{"type":"string","description":"What the job accomplished (action=job)."},' +
    '"evidence":{"type":"string","description":"What you ran and what it printed (action=submit)."},' +
    '"verdict":{"type":"string","enum":["accept","reject"],"description":"action=verdict."},' +
    '"reason":{"type":"string","description":"Why it is rejected, with exact reproduction steps (required to reject)."},' +
    '"cause":{"type":"string","description":"A short key naming the KIND of mistake, reused across tasks, e.g. untested-empty-input (reject)."}' +
    '},"required":["action","project"]}';
  T.Handler     := Tool_Task;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcMutating;
  T.IsDeferred  := False;
  T.Hidden      := False;
  Add(T);

  T.Name        := 'rule';
  T.Description :=
    'Turn a mistake that keeps getting work rejected into a check every ' +
    'submit is held to. action="draft" needs "project", "cause" (the key ' +
    'reviewers gave the rejects) and "script" (a shell check, run with the ' +
    'project as its cwd, exit 0 = right); optional "name" (file name). The ' +
    'draft is PROVEN first -- it must fail on a submission rejected for ' +
    'that cause and pass on the accepted fix -- and then waits for the ' +
    'operator to approve. action="list" shows the rules, and how often ' +
    'each cause has rejected work.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["draft","list"]},' +
    '"project":{"type":"string","description":"Project slug (always required)."},' +
    '"cause":{"type":"string","description":"The reject cause the check catches (draft)."},' +
    '"script":{"type":"string","description":"The check: shell (or python with name *.py), cwd = the project, exit 0 when the work is right (draft)."},' +
    '"name":{"type":"string","description":"File name for the check, e.g. empty-title.sh (draft; optional)."}' +
    '},"required":["action","project"]}';
  T.Handler     := Tool_Rule;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcMutating;
  T.IsDeferred  := False;
  T.Hidden      := False;
  Add(T);

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
    'build_app {title,brief}, team_up {template,brief|project}, ' +
    'theme {id}. Use this when the user talks about the SCREEN -- tidying ' +
    'windows, opening something, starting several apps at once -- or asks ' +
    'to spin up an agent TEAM (team_up; the user is asked to allow it).';
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
  OnTaskAssigned := NotifyAssignee;
  OnTaskRejected := NoticeRepeatedCause;
  OnLaneCheck := LaneCheck;
  ConsentProbe := DesktopConsent;
  AddDecisionAnsweredListener(RuleDecisionAnswered);

end.