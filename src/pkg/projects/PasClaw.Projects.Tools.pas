(*
  PasClaw.Projects.Tools - the model-callable `project` and `task` tools.

  These let the agent keep its own board: create the project it is building
  in, break the work into tasks, and report progress as it goes. The desktop
  reads exactly the same manifests, so the left-hand tree updates while the
  agent works -- the board is not a separate thing the model narrates, it IS
  the thing the model edits.

  Two tools rather than five, because a tool list is prompt budget:

    project  action = list | create | get | update
    task     action = list | create | update | job

  `task action=job` is how a run reports itself: status/summary against a job
  the runtime opened. Jobs are created by the runtime (PasClaw.Projects.Store
  CreateJob) when a turn starts working a task, so the model never has to
  remember to open one -- it only closes them.

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

procedure RegisterProjectTools(R: TToolRegistry);

{ Handlers, exposed for tests. }
function Tool_Project(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Task(const ArgsJSON: string; out ErrMsg: string): string;
function Tool_Desktop(const ArgsJSON: string; out ErrMsg: string): string;

implementation

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Projects.Store,
  PasClaw.Desktop.Events;

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

function TaskList(const Project: string; out Err: string): string;
var
  Rows: TTaskInfoArray;
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
  for I := 0 to High(Rows) do
  begin
    S := S + '  ' + Rows[I].Id + '  [' + TaskStatusToStr(Rows[I].Status) + ']  ' +
         Rows[I].Title;
    if Rows[I].JobCount > 0 then
      S := S + '  (jobs: ' + IntToStr(Rows[I].JobCount) + ')';
    S := S + #10;
    if Rows[I].Notes <> '' then
      S := S + '      ' + Rows[I].Notes + #10;
  end;
  Result := S;
end;

function Tool_Task(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Action, Project, Id, Title, Notes, Status, Summary, JobId, Err: string;
  Jobs: TJobInfoArray;
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
      Id := CreateTask(Project, Title, Notes, Err);
      if Id = '' then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Created task ' + Id + ' in ' + Project + ': ' + Title;
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
      if not UpdateTask(Project, Id, Title, Notes, Status, Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      Result := 'Updated task ' + UpperCase(Id) + ' in ' + Project;
      if Status <> '' then
        Result := Result + ' (status: ' + LowerCase(Status) + ')';
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
      if not UpdateJob(Project, Id, JobId, Status, Summary, '-', Err) then
      begin
        ErrMsg := Err;
        Exit;
      end;
      { Finishing the last open job on a task is what closes the task. The
        model can still set a task status explicitly; this is the default so
        a well-behaved run leaves a tidy board without extra calls. }
      if LowerCase(Status) = 'done' then
        UpdateTask(Project, Id, '', '-', 'done', Err);
      Result := 'Job ' + JobId + ' on ' + Project + '/' + UpperCase(Id) +
                ' reported ' + LowerCase(Status) + '.';
      Exit;
    end;

    ErrMsg := 'unknown action "' + Action + '" (use list, create, update or job)';
  finally
    Obj.Free;
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
    Arr := Obj.ChildArray('actions');
    if (Arr = nil) or (Arr.Count = 0) then
    begin
      ErrMsg := 'missing required argument: actions (a non-empty array of ' +
                '{"do":...} objects)';
      Exit;
    end;
    N := Arr.Count;
    Body := Arr.ToJSON;
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
    '(todo/active/done/blocked); action="job" reports the current run ' +
    '(status done/failed + "summary") and closes the task when done. Keep ' +
    'this current as you work -- the user watches this board.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"action":{"type":"string","enum":["list","create","update","job"]},' +
    '"project":{"type":"string","description":"Project slug (always required)."},' +
    '"id":{"type":"string","description":"Task id, e.g. T0001 (update/job)."},' +
    '"title":{"type":"string","description":"Task title (create/update)."},' +
    '"notes":{"type":"string","description":"Free-text notes on the task."},' +
    '"status":{"type":"string","description":"todo|active|done|blocked for a task; done|failed for a job."},' +
    '"job":{"type":"string","description":"Job id (defaults to the latest job on the task)."},' +
    '"summary":{"type":"string","description":"What the job accomplished (action=job)."}' +
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
    'open_app {project}, open_chat {project}, build_app {title,brief}, ' +
    'theme {id}. Use this when the user talks about the SCREEN -- tidying ' +
    'windows, opening something, starting several apps at once.';
  T.Schema      :=
    '{"type":"object","properties":{' +
    '"actions":{"type":"array","description":' +
    '"Desktop actions in order, e.g. [{""do"":""tile""}].",' +
    '"items":{"type":"object","properties":{' +
    '"do":{"type":"string"},"project":{"type":"string"},' +
    '"title":{"type":"string"},"brief":{"type":"string"},' +
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

end.