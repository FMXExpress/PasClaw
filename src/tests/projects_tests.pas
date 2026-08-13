program projects_tests;
(*
  Pins PasClaw.Projects.Store and the `project` / `task` tools: slug
  sanitisation (the only barrier between model/HTTP text and a directory
  path), ordinal id allocation, task/job lifecycle, and the two status
  side-effects the desktop depends on -- opening a job activates its task,
  reporting a job done closes it.

  Runs against a temp PASCLAW_HOME. No network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Projects.Tools;

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
  if not Cond then Fail_(Msg);
end;

procedure ExpectContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" not in: ' + Haystack);
end;

var
  Slug, TaskId, JobId, Err, Out_: string;
  Projects: TProjectInfoArray;
  Tasks: TTaskInfoArray;
  Jobs: TJobInfoArray;
  P: TProjectInfo;
  T: TTaskInfo;
  J: TJobInfo;
begin
  { --------------------------------------------------------- sanitisation -- }
  ExpectStr(SanitizeName('Spam Filter'),      'spam-filter', 'spaces to dashes, lowercased');
  ExpectStr(SanitizeName('My  App!!'),        'my-app',      'separator runs collapse, trailing trimmed');
  ExpectStr(SanitizeName('  leading'),        'leading',     'no leading separator');
  ExpectStr(SanitizeName('Invoice #42'),      'invoice-42',  'digits kept');
  ExpectStr(SanitizeName('../../etc/passwd'), 'etc-passwd',  'traversal cannot survive');
  ExpectStr(SanitizeName('...'),              '',            'nothing usable -> empty');
  ExpectStr(SanitizeName(''),                 '',            'empty stays empty');
  ExpectTrue(not IsSafeName('../x'),   'traversal is not a safe name');
  ExpectTrue(not IsSafeName('a/b'),    'separators are not safe names');
  ExpectTrue(not IsSafeName('Upper'),  'uppercase is not the canonical form');
  ExpectTrue(IsSafeName('spam-filter'), 'canonical slug accepted');

  { A path built from an unsafe name must be refused outright, not coerced. }
  ExpectStr(ProjectDir('../escape'), '', 'ProjectDir refuses unsafe names');
  ExpectStr(TaskDir('spam-filter', '../..'), '', 'TaskDir refuses non-ids');
  ExpectStr(JobDir('spam-filter', 'T0001', 'nope'), '', 'JobDir refuses non-ids');

  { ------------------------------------------------------------- projects -- }
  Slug := CreateProject('Spam Filter', '', 'Filter my email', Err);
  ExpectStr(Slug, 'spam-filter', 'project slug derived from title');
  ExpectStr(Err, '', 'create is clean');
  ExpectTrue(ProjectExists('spam-filter'), 'project directory exists');
  ExpectTrue(DirectoryExists(JoinPath(ProjectDir('spam-filter'), 'app')),
             'app/ seeded for the factory to write into');

  { Idempotent -- an agent re-running its create step must not fail the job. }
  ExpectStr(CreateProject('Spam Filter', '', '', Err), 'spam-filter', 're-create returns the same slug');
  ExpectStr(Err, '', 're-create is not an error');

  ExpectStr(CreateProject('!!!', '', '', Err), '', 'unusable title refused');
  ExpectTrue(Err <> '', 'and it says why');

  ExpectTrue(GetProject('spam-filter', P), 'project loads');
  ExpectStr(P.Title, 'Spam Filter', 'title preserved verbatim');
  ExpectStr(P.Description, 'Filter my email', 'description preserved');
  ExpectTrue(P.Created <> '', 'created stamped');

  CreateProject('Reading Log', '', '', Err);
  Projects := ListProjects;
  ExpectInt(Length(Projects), 2, 'two projects listed');

  { ---------------------------------------------------------------- tasks -- }
  TaskId := CreateTask('spam-filter', 'Connect to IMAP', 'use app password', Err);
  ExpectStr(TaskId, 'T0001', 'first task id');
  ExpectStr(CreateTask('spam-filter', 'Classify messages', '', Err), 'T0002', 'ids increment');
  ExpectStr(CreateTask('nope', 'x', '', Err), '', 'task in a missing project refused');
  ExpectStr(CreateTask('spam-filter', '', '', Err), '', 'task needs a title');

  Tasks := ListTasks('spam-filter');
  ExpectInt(Length(Tasks), 2, 'two tasks');
  ExpectStr(Tasks[0].Id, 'T0001', 'listed in ordinal order');
  ExpectStr(Tasks[1].Id, 'T0002', 'listed in ordinal order');
  ExpectTrue(Tasks[0].Status = tsTodo, 'new task starts todo');

  ExpectTrue(UpdateTask('spam-filter', 'T0001', '', '-', 'blocked', Err), 'status update');
  ExpectTrue(GetTask('spam-filter', 'T0001', T), 'task reloads');
  ExpectTrue(T.Status = tsBlocked, 'status persisted');
  ExpectStr(T.Notes, 'use app password', 'notes untouched by the "-" sentinel');
  ExpectTrue(not UpdateTask('spam-filter', 'T0001', '', '-', 'sideways', Err),
             'bogus status refused');
  ExpectContains(Err, 'todo', 'refusal names the legal values');

  { ----------------------------------------------------------------- jobs -- }
  JobId := CreateJob('spam-filter', 'T0002', 'sess-abc', Err);
  ExpectStr(JobId, 'J0001', 'first job id');
  ExpectTrue(GetTask('spam-filter', 'T0002', T), 'task reloads after job open');
  ExpectTrue(T.Status = tsActive, 'opening a job activates its task');

  ExpectTrue(GetJob('spam-filter', 'T0002', 'J0001', J), 'job loads');
  ExpectTrue(J.Status = jsRunning, 'job starts running');
  ExpectStr(J.SessionId, 'sess-abc', 'session linked');
  ExpectStr(J.Ended, '', 'not ended yet');

  AppendJobLog('spam-filter', 'T0002', 'J0001', 'reading inbox');
  AppendJobLog('spam-filter', 'T0002', 'J0001', 'wrote classifier');
  ExpectContains(ReadJobLog('spam-filter', 'T0002', 'J0001'), 'wrote classifier',
                 'job log appends');

  ExpectTrue(UpdateJob('spam-filter', 'T0002', 'J0001', 'done', 'built it', '-', Err),
             'job reported done');
  ExpectTrue(GetJob('spam-filter', 'T0002', 'J0001', J), 'job reloads');
  ExpectTrue(J.Status = jsDone, 'status persisted');
  ExpectTrue(J.Ended <> '', 'end stamped');
  ExpectStr(J.Summary, 'built it', 'summary persisted');

  { A task with another job still in flight must NOT close when one finishes. }
  ExpectStr(CreateJob('spam-filter', 'T0002', '', Err), 'J0002', 'job ids increment');
  Jobs := ListJobs('spam-filter', 'T0002');
  ExpectInt(Length(Jobs), 2, 'two jobs on the task');
  ExpectTrue(GetTask('spam-filter', 'T0002', T), 'task reloads');
  ExpectTrue(T.Status = tsActive, 'a second open job reactivates the task');
  ExpectTrue(UpdateJob('spam-filter', 'T0002', 'J0002', 'done', '-', '-', Err),
             'second job done');
  ExpectTrue(GetTask('spam-filter', 'T0002', T), 'task reloads');
  ExpectTrue(T.Status = tsDone, 'task closes once its LAST job finishes');

  { A failed run leaves work to do: back to todo, never done. }
  CreateTask('spam-filter', 'Flaky step', '', Err);
  CreateJob('spam-filter', 'T0003', '', Err);
  ExpectTrue(UpdateJob('spam-filter', 'T0003', 'J0001', 'failed', 'boom', '-', Err),
             'job reported failed');
  ExpectTrue(GetTask('spam-filter', 'T0003', T), 'task reloads');
  ExpectTrue(T.Status = tsTodo, 'a failed job returns its task to todo');

  { A blocked task is not quietly reopened by a finishing job. }
  CreateTask('spam-filter', 'Blocked step', '', Err);
  CreateJob('spam-filter', 'T0004', '', Err);
  UpdateTask('spam-filter', 'T0004', '', '-', 'blocked', Err);
  ExpectTrue(UpdateJob('spam-filter', 'T0004', 'J0001', 'done', '-', '-', Err),
             'job done on a blocked task');
  ExpectTrue(GetTask('spam-filter', 'T0004', T), 'task reloads');
  ExpectTrue(T.Status = tsBlocked, 'a blocked task stays blocked');

  { ---------------------------------------------------------------- tools -- }
  Out_ := Tool_Project('{"action":"list"}', Err);
  ExpectStr(Err, '', 'project list is clean');
  ExpectContains(Out_, 'spam-filter', 'list names the project');

  Out_ := Tool_Project('{"action":"create","title":"Invoice Desk"}', Err);
  ExpectStr(Err, '', 'tool create is clean');
  ExpectTrue(ProjectExists('invoice-desk'), 'tool created the project');

  Out_ := Tool_Project('{"action":"get","name":"spam-filter"}', Err);
  ExpectContains(Out_, 'T0001', 'get shows the board');

  Out_ := Tool_Project('{"action":"get"}', Err);
  ExpectTrue(Err <> '', 'get without a name is an error');

  Out_ := Tool_Project('{"action":"wat"}', Err);
  ExpectContains(Err, 'unknown action', 'unknown action refused');

  Out_ := Tool_Project('not json', Err);
  ExpectTrue(Err <> '', 'malformed arguments refused');

  Out_ := Tool_Task('{"action":"create","project":"invoice-desk","title":"Import PDFs"}', Err);
  ExpectStr(Err, '', 'task create via tool');
  ExpectContains(Out_, 'T0001', 'tool reports the new id');

  Out_ := Tool_Task('{"action":"list","project":"invoice-desk"}', Err);
  ExpectContains(Out_, 'Import PDFs', 'task list shows titles');

  Out_ := Tool_Task('{"action":"create","title":"orphan"}', Err);
  ExpectTrue(Err <> '', 'task without a project refused');

  { A run reports itself: no explicit job id -> the latest job on the task. }
  CreateJob('invoice-desk', 'T0001', 'sess-xyz', Err);
  Out_ := Tool_Task('{"action":"job","project":"invoice-desk","id":"T0001",' +
                    '"status":"done","summary":"imported 12 PDFs"}', Err);
  ExpectStr(Err, '', 'job report is clean');
  ExpectTrue(GetJob('invoice-desk', 'T0001', 'J0001', J), 'job reloads');
  ExpectTrue(J.Status = jsDone, 'reported status stuck');
  ExpectStr(J.Summary, 'imported 12 PDFs', 'summary stuck');
  ExpectTrue(GetTask('invoice-desk', 'T0001', T), 'task reloads');
  ExpectTrue(T.Status = tsDone, 'a done job closes its task');

  Out_ := Tool_Task('{"action":"job","project":"invoice-desk","id":"T0002"}', Err);
  ExpectTrue(Err <> '', 'reporting against a missing task is an error');

  { --------------------------------------------------- workspace isolation -- }
  { Projects belong to a workspace: switching desktops must switch boards. }
  CreateWorkspace('Home');
  ExpectTrue(SetActiveWorkspace('workspace2', Err), 'switched workspace');
  Projects := ListProjects;
  ExpectInt(Length(Projects), 0, 'a new workspace starts with no projects');
  ExpectTrue(not ProjectExists('spam-filter'), 'other workspace projects are invisible');
  CreateProject('Groceries', '', '', Err);
  ExpectInt(Length(ListProjects), 1, 'new project lands in the new workspace');

  ExpectTrue(SetActiveWorkspace('workspace', Err), 'switched back');
  ExpectInt(Length(ListProjects), 3, 'original workspace board intact');
  ExpectTrue(ProjectExists('spam-filter'), 'original projects back');

  if Failures = 0 then
    WriteLn('projects_tests: OK')
  else
  begin
    WriteLn('projects_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
