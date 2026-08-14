program desktop_routes_tests;
(*
  Pins the desktop HTTP surface (PasClaw.Gateway.Desktop) end to end without
  a socket: every route, its status codes, and -- the part that matters --
  that path traversal cannot reach a file through the *routing* layer either,
  not just through PasClaw.Apps' resolver.

  Also pins the two injected capabilities (job runner, page generator):
  absent, their routes must answer 503 with an explanation rather than
  pretending to work.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  { Starting an app spawns a drain thread, and on FPC/Linux the pthreads
    driver has to be linked in before anything that touches TThread. }
  {$IFDEF FPC}{$IFDEF UNIX}cthreads,{$ENDIF}{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Pages,
  PasClaw.Suite,
  PasClaw.Suite.Notes,
  PasClaw.Apps.Runner,
  PasClaw.Desktop.Events,
  PasClaw.Gateway.Desktop;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
end;

function Req(const Method, Doc, Body: string; out Resp: TDesktopResponse): Boolean;
begin
  Result := DesktopRoute(Method, Doc, '', Body, Resp);
end;

function Req2(const Method, Doc, Query, Body: string;
  out Resp: TDesktopResponse): Boolean;
begin
  Result := DesktopRoute(Method, Doc, Query, Body, Resp);
end;

{ Assert a route answers with the given status. }
procedure ExpectStatus(const Method, Doc, Body: string; Want: Integer;
  const Msg: string);
var
  R: TDesktopResponse;
begin
  if not Req(Method, Doc, Body, R) then
  begin
    Fail_(Msg + ' -- route not handled at all');
    Exit;
  end;
  if R.Status <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(R.Status) + ', want ' + IntToStr(Want) +
          ' (body: ' + Copy(R.Body, 1, 200) + ')');
end;

{ The JSON writer pretty-prints ("key" : "value"), so a raw substring match
  against compact JSON would fail for formatting reasons rather than real
  ones. Compare with all spaces removed. }
function Squeeze(const S: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 1 to Length(S) do
    if S[I] <> ' ' then Result := Result + S[I];
end;

procedure ExpectBodyContains(const Method, Doc, Body, Needle, Msg: string);
var
  R: TDesktopResponse;
begin
  if not Req(Method, Doc, Body, R) then
  begin
    Fail_(Msg + ' -- route not handled');
    Exit;
  end;
  if Pos(Squeeze(Needle), Squeeze(R.Body)) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" not in: ' + Copy(R.Body, 1, 300));
end;

{ String field of a JSON response, compared after decoding -- the right way
  to assert a value that itself contains quotes. }
procedure ExpectField(const Method, Doc, Body, Key, Want, Msg: string);
var
  R: TDesktopResponse;
  Obj: TJsonObject;
  Got: string;
begin
  if not Req(Method, Doc, Body, R) then
  begin
    Fail_(Msg + ' -- route not handled');
    Exit;
  end;
  try
    Obj := TJsonObject.Parse(R.Body);
  except
    Fail_(Msg + ' -- response is not JSON: ' + Copy(R.Body, 1, 200));
    Exit;
  end;
  try
    Got := Obj.GetStr(Key, #1'missing');
  finally
    Obj.Free;
  end;
  if Got <> Want then
    Fail_(Msg + ' -- ' + Key + ' is "' + Got + '", want "' + Want + '"');
end;

{ No asset route may ever hand back a FilePath outside the app dir. }
procedure ExpectNoFile(const Doc, Msg: string);
var
  R: TDesktopResponse;
begin
  if not Req('GET', Doc, '', R) then Exit;   { unrouted is fine }
  if R.FilePath <> '' then
    Fail_('ESCAPE: ' + Msg + ' served ' + R.FilePath);
  if R.Status = 200 then
    Fail_('ESCAPE: ' + Msg + ' answered 200');
end;

{ ---- stub capabilities, to prove the wiring and the 503 fallback ---- }

var
  RunnerCalledWith: string = '';

function StubRunner(const Project, TaskId, Prompt: string;
  out JobId, Err: string): Boolean;
begin
  RunnerCalledWith := Project + '/' + TaskId + '/' + Prompt;
  Err := '';
  JobId := CreateJob(Project, TaskId, 'stub-session', Err);
  Result := JobId <> '';
end;

{ Records what the route handed the generator, so the assertions can check
  that a follow-up actually arrived as one. }
var
  GLastRevise: string = '';

function StubPageGen(const Query: string; Kind: TPageKind;
  const RevisePageId: string;
  out Title, BodyHTML, SourcesJSON, Err: string): Boolean;
begin
  Err := '';
  GLastRevise := RevisePageId;
  Title := 'About ' + Query;
  BodyHTML := '<p>Answer about ' + Query + '</p>';
  SourcesJSON := '[{"title":"Example","url":"https://example.com/a"}]';
  Result := True;
end;

{ Drain a subscriber until Needle shows up or the wait runs out. Bounded so
  a missing event fails the test rather than hanging the suite. }
function SawEvent(Sub: TEventSubscriber; const Needle: string): Boolean;
var
  Lines: TStringList;
  I, Waited: Integer;
begin
  Result := False;
  Waited := 0;
  while (not Result) and (Waited < 60) do
  begin
    Sub.WaitFor(50);
    Lines := Sub.Drain(128);
    try
      for I := 0 to Lines.Count - 1 do
        if Pos(Needle, Lines[I]) > 0 then Result := True;
    finally
      Lines.Free;
    end;
    Inc(Waited);
  end;
end;

var
  R: TDesktopResponse;
  Err, AppDir, Slug, Blueprint: string;
  Sub: TEventSubscriber;
  Obj: TJsonObject;
  Sources: TPageSourceArray;
  PageId: string;
  AppInfo: TAppInfo;
begin
  { --------------------------------------------------------- unowned paths -- }
  ExpectTrue(not Req('GET', '/v1/health', '', R), 'health is not ours');
  ExpectTrue(not Req('GET', '/v1/chat', '', R), 'chat is not ours');
  ExpectTrue(IsDesktopPath('/v1/projects'), 'projects is ours');
  ExpectTrue(IsDesktopPath('/apps/x/index.html'), 'app assets are ours');
  ExpectTrue(not IsDesktopPath('/v1/memory'), 'memory is not ours');

  { ----------------------------------------------------------- workspaces -- }
  ExpectStatus('GET', '/v1/workspaces', '', 200, 'list workspaces');
  ExpectBodyContains('GET', '/v1/workspaces', '', '"active":"workspace"',
                     'reports the active workspace');

  ExpectStatus('POST', '/v1/workspaces', '{"label":"Home"}', 200, 'create workspace');
  ExpectBodyContains('GET', '/v1/workspaces', '', 'workspace2', 'new workspace listed');

  ExpectStatus('POST', '/v1/workspaces/activate', '{"name":"workspace2"}', 200,
               'activate workspace');
  ExpectStr(ActiveWorkspaceName, 'workspace2', 'activation took effect');
  ExpectStatus('POST', '/v1/workspaces/activate', '{"name":"workspace9"}', 400,
               'activating a missing workspace is a 400');
  ExpectStatus('POST', '/v1/workspaces/activate', '{"name":"../etc"}', 400,
               'activating a malformed name is a 400');
  ExpectStatus('POST', '/v1/workspaces/activate', 'not json', 400,
               'malformed body is a 400');
  ExpectStatus('POST', '/v1/workspaces/activate', '{"name":"workspace"}', 200,
               'back to workspace 1');

  { ------------------------------------------------------------- projects -- }
  ExpectStatus('GET', '/v1/projects', '', 200, 'list projects');
  ExpectStatus('POST', '/v1/projects', '{"title":"Spam Filter"}', 200, 'create project');
  ExpectBodyContains('POST', '/v1/projects', '{"title":"Reading Log"}',
                     'reading-log', 'create returns the slug');
  ExpectStatus('POST', '/v1/projects', '{"title":"!!!"}', 400, 'unusable title is a 400');
  ExpectStatus('POST', '/v1/projects', '', 400, 'missing body is a 400');

  ExpectStatus('GET', '/v1/projects/spam-filter', '', 200, 'get project');
  ExpectStatus('GET', '/v1/projects/nope', '', 404, 'missing project is a 404');
  ExpectStatus('GET', '/v1/projects/..', '', 404, 'traversal as a project name is a 404');
  ExpectStatus('GET', '/v1/projects/%2e%2e%2f%2e%2e', '', 404,
               'url-encoded traversal is a 404');

  (* DELETING A PROJECT MUST NOT LEAVE ITS APP RUNNING.

     DeleteProject removes a directory and knows nothing about the runner --
     it cannot, since the runner is built on top of it. So a project whose
     process app was running used to lose the project and keep the child: a
     program the agent wrote, still executing, with no entry left in any UI
     to stop it. The route stops it first now, and this is that. *)
  Slug := CreateProject('Doomed', '', '', Err);
  EnsureDir(ProjectAppDir(Slug));
  WriteFileText(JoinPath(ProjectAppDir(Slug), 'app.json'),
    '{"name":"Sleeper","kind":"python","entry":"main.py","run":"/bin/sleep 30"}');
  ExpectStatus('POST', '/v1/apps/' + Slug + '/run', '{"confirm":true}', 200,
               'a probe app starts');
  ExpectTrue(AppRunInfo(Slug).State = rsRunning, 'and is running');
  ExpectStatus('DELETE', '/v1/projects/' + Slug, '', 200, 'delete it');
  ExpectTrue(AppRunInfo(Slug).State <> rsRunning,
             'and its app is not still running afterwards');

  ExpectStatus('PATCH', '/v1/projects/spam-filter', '{"icon":"Mail"}', 200, 'patch project');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', '"icon":"Mail"',
                     'patch persisted');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', '"title":"Spam Filter"',
                     'patch did not clobber the title');

  (* Omitting a key means LEAVE IT ALONE, and clients lean on that: a rename
     dialog knows the new title and nothing else, so it sends only "title".
     If an absent key read as "make it empty", renaming a project would wipe
     its description as a side effect. *)
  ExpectStatus('PATCH', '/v1/projects/spam-filter',
               '{"description":"Filters mail"}', 200, 'set a description');
  ExpectStatus('PATCH', '/v1/projects/spam-filter', '{"title":"Junk Filter"}',
               200, 'rename with title alone');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', '"title":"Junk Filter"',
                     'the rename took');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', 'Filters mail',
                     'and the description it never mentioned survived');

  { ---------------------------------------------------------------- tasks -- }
  ExpectStatus('GET', '/v1/projects/spam-filter/tasks', '', 200, 'list tasks');
  ExpectBodyContains('POST', '/v1/projects/spam-filter/tasks',
                     '{"title":"Connect IMAP"}', 'T0001', 'create task');
  ExpectStatus('POST', '/v1/projects/spam-filter/tasks', '{"title":""}', 400,
               'task without a title is a 400');
  ExpectStatus('POST', '/v1/projects/nope/tasks', '{"title":"x"}', 404,
               'task in a missing project is a 404');

  ExpectStatus('GET', '/v1/projects/spam-filter/tasks/T0001', '', 200, 'get task');
  ExpectStatus('PATCH', '/v1/projects/spam-filter/tasks/T0001',
               '{"status":"active"}', 200, 'patch task status');
  ExpectStatus('PATCH', '/v1/projects/spam-filter/tasks/T0001',
               '{"status":"sideways"}', 400, 'bogus status is a 400');
  { Same rule one level down: the desktop's Status button sends a status and
    nothing else, and must not erase the notes that say what the task is. }
  ExpectStatus('PATCH', '/v1/projects/spam-filter/tasks/T0001',
               '{"notes":"needs an app password"}', 200, 'set task notes');
  ExpectStatus('PATCH', '/v1/projects/spam-filter/tasks/T0001',
               '{"status":"done"}', 200, 'status alone');
  ExpectBodyContains('GET', '/v1/projects/spam-filter/tasks/T0001', '',
                     'app password', 'the notes survived a status-only patch');
  ExpectBodyContains('GET', '/v1/projects/spam-filter/tasks/T0001', '',
                     'Connect IMAP', 'and so did the title');
  ExpectStatus('GET', '/v1/projects/spam-filter/tasks/nope', '', 404,
               'bad task id is a 404');

  { ----------------------------------------------------------------- jobs -- }
  ExpectStatus('GET', '/v1/projects/spam-filter/tasks/T0001/jobs', '', 200, 'list jobs');
  ExpectBodyContains('POST', '/v1/projects/spam-filter/tasks/T0001/jobs',
                     '{"session_id":"s1"}', 'J0001', 'open job');
  ExpectBodyContains('GET', '/v1/projects/spam-filter/tasks/T0001/jobs/J0001', '',
                     '"session_id":"s1"', 'job carries its session');
  ExpectStatus('PATCH', '/v1/projects/spam-filter/tasks/T0001/jobs/J0001',
               '{"status":"done","summary":"ok"}', 200, 'patch job');
  ExpectBodyContains('GET', '/v1/projects/spam-filter/tasks/T0001/jobs/J0001', '',
                     '"status":"done"', 'job status persisted');
  ExpectStatus('GET', '/v1/projects/spam-filter/tasks/T0001/jobs/J0001/log', '',
               200, 'job log');
  ExpectStatus('GET', '/v1/projects/spam-filter/tasks/T0001/jobs/J9999', '', 404,
               'missing job is a 404');

  { ---------------------------------------------------- run (injected hook) -- }
  { With no agent attached the route must say so, not fake a job. }
  ExpectStatus('POST', '/v1/projects/spam-filter/tasks/T0001/run',
               '{"prompt":"go"}', 503, 'run without an agent is a 503');
  ExpectBodyContains('POST', '/v1/projects/spam-filter/tasks/T0001/run',
                     '{"prompt":"go"}', 'no agent',
                     '503 explains that no agent is attached');

  SetJobRunner(StubRunner);
  ExpectStatus('POST', '/v1/projects/spam-filter/tasks/T0001/run',
               '{"prompt":"go"}', 200, 'run with an agent attached');
  ExpectStr(RunnerCalledWith, 'spam-filter/T0001/go', 'runner got the right arguments');
  { No prompt is the ordinary case: the task's own title and notes are what
    it is about, so the desktop leaves the key out entirely rather than
    inventing a sentence. That must still start a job. }
  ExpectStatus('POST', '/v1/projects/spam-filter/tasks/T0001/run', '{}', 200,
               'run with no prompt at all');
  ExpectStr(RunnerCalledWith, 'spam-filter/T0001/',
            'and the runner is told there was none');
  SetJobRunner(nil);

  { ------------------------------------------------------------------ apps -- }
  AppDir := ProjectAppDir('spam-filter');
  ExpectBodyContains('GET', '/v1/apps/spam-filter', '', '"exists":false',
                     'appless project reports no app');

  WriteFileText(JoinPath(AppDir, 'app.json'),
    '{"name":"Spam Filter","kind":"html","entry":"index.html",' +
    '"window":{"width":700,"height":520},' +
    '"permissions":{"network":["imap.gmail.com:993"]}}');
  WriteFileText(JoinPath(AppDir, 'index.html'), '<h1>spam</h1>');

  ExpectBodyContains('GET', '/v1/apps/spam-filter', '', '"kind":"html"',
                     'manifest surfaced');
  ExpectBodyContains('GET', '/v1/apps/spam-filter', '', 'imap.gmail.com:993',
                     'declared network surfaced for consent');
  ExpectStatus('GET', '/v1/apps/nope', '', 404, 'app of a missing project is a 404');

  { --- asset serving --- }
  if Req('GET', '/apps/spam-filter/index.html', '', R) then
  begin
    ExpectTrue(R.Status = 200, 'asset served');
    ExpectTrue(R.FilePath <> '', 'asset served from disk');
    ExpectTrue(Pos('Content-Security-Policy', R.Headers) > 0, 'CSP attached');
    ExpectTrue(Pos('connect-src ''self''', R.Headers) > 0,
               'html apps may reach only this gateway');
    ExpectTrue(Pos('nosniff', R.Headers) > 0, 'nosniff attached');
  end
  else
    Fail_('asset route not handled');

  { Directory request serves the entry document. }
  ExpectStatus('GET', '/apps/spam-filter/', '', 200, 'directory request serves the entry');

  { --- the escape suite, replayed through routing --- }
  ExpectNoFile('/apps/spam-filter/../project.json',           'parent traversal');
  ExpectNoFile('/apps/spam-filter/../../../../etc/passwd',    'deep traversal');
  ExpectNoFile('/apps/spam-filter/%2e%2e/project.json',       'encoded traversal');
  ExpectNoFile('/apps/spam-filter/%2e%2e%2f%2e%2e%2fconfig.json', 'encoded deep traversal');
  ExpectNoFile('/apps/../config.json',                        'traversal in the project slot');
  ExpectNoFile('/apps/spam-filter/index.html%00.png',         'NUL byte');
  ExpectNoFile('/apps/spam-filter/state.json',                'state store is not a servable asset');

  { A `page` kind must not be reachable as an app with scripts, and a project
    with no app must not serve files at all. }
  CreateProject('No App', 'no-app', '', Err);
  WriteFileText(JoinPath(ProjectAppDir('no-app'), 'secret.html'), 'hi');
  ExpectStatus('GET', '/apps/no-app/secret.html', '', 404,
               'files of an app-less project are not served');

  { --- state store --- }
  ExpectStatus('PUT', '/v1/apps/spam-filter/state/rules', '["a","b"]', 200, 'state put');
  ExpectField('GET', '/v1/apps/spam-filter/state/rules', '', 'value', '["a","b"]',
              'state round-trips verbatim');
  { An unset key answers 200 with exists:false -- an app's first run reads
    keys it has never written, and a 404 there makes every cold start log a
    console error. }
  ExpectStatus('GET', '/v1/apps/spam-filter/state/missing', '', 200,
               'missing key is not an error');
  ExpectBodyContains('GET', '/v1/apps/spam-filter/state/missing', '',
                     '"exists":false', 'missing key reports exists:false');
  ExpectBodyContains('GET', '/v1/apps/spam-filter/state/rules', '',
                     '"exists":true', 'present key reports exists:true');
  ExpectBodyContains('GET', '/v1/apps/spam-filter/state', '', 'rules', 'state key list');
  ExpectStatus('DELETE', '/v1/apps/spam-filter/state/rules', '', 200, 'state delete');
  ExpectBodyContains('GET', '/v1/apps/spam-filter/state/rules', '',
                     '"exists":false', 'deleted key is gone');
  ExpectStatus('PUT', '/v1/apps/nope/state/k', 'v', 400, 'state on a missing project');

  { ------------------------------------------------- run consent + surfaces -- }
  { An html app is served, never run -- asking to run one is a 400, not a
    silently-spawned process. }
  ExpectStatus('POST', '/v1/apps/spam-filter/run', '{"confirm":true}', 400,
               'a servable app has nothing to run');

  { A process app must not start without explicit consent, and the refusal
    has to hand back the command so a client can show what it is asking
    about. This is the containment story for model-authored `run` lines. }
  CreateProject('Proc App', 'proc-app', '', Err);
  WriteFileText(JoinPath(ProjectAppDir('proc-app'), 'app.json'),
    '{"name":"Proc","kind":"python","entry":"main.py","run":"python3 main.py {port}"}');
  WriteFileText(JoinPath(ProjectAppDir('proc-app'), 'main.py'), 'print(1)');
  ExpectStatus('POST', '/v1/apps/proc-app/run', '{}', 409,
               'running without confirmation is refused');
  ExpectBodyContains('POST', '/v1/apps/proc-app/run', '{}', 'python3 main.py',
                     'the refusal shows the command being consented to');
  ExpectBodyContains('POST', '/v1/apps/proc-app/run', '{}', '"needs_confirm":true',
                     'and marks itself as a consent prompt');
  ExpectStatus('POST', '/v1/apps/proc-app/stop', '', 400, 'stopping a stopped app');
  ExpectStatus('GET', '/v1/apps/proc-app/runlog', '', 200, 'run log readable');
  ExpectBodyContains('GET', '/v1/apps/proc-app', '', '"run_state":"stopped"',
                     'manifest carries run state for process kinds');

  { The allowlisted read surface: apps get these projections and nothing
    else. The refusal is what keeps it a window rather than a hole. }
  ExpectStatus('GET', '/v1/apps/spam-filter/read/cron',      '', 200, 'read cron');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/projects',  '', 200, 'read projects');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/pages',     '', 200, 'read pages');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/providers', '', 200, 'read providers');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/sessions',  '', 200, 'read sessions');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/config',    '', 404,
               'config is NOT a readable surface');
  ExpectStatus('GET', '/v1/apps/spam-filter/read/../../etc', '', 404,
               'traversal is not a surface');
  ExpectStatus('POST', '/v1/apps/spam-filter/read/cron', '', 405,
               'the read surface is read-only');
  ExpectBodyContains('GET', '/v1/apps/spam-filter/read/projects', '',
                     'spam-filter', 'the projects surface carries real data');
  { A provider's key must never reach an app -- only whether one is set. }
  ExpectBodyContains('GET', '/v1/apps/spam-filter/read/providers', '',
                     '"surface":"providers"', 'providers surface labelled');

  { The action surface. `read` and `state` cannot make anything happen, so
    an app that needs a side effect -- Mail fetching from IMAP -- needs a
    third verb. It is an ALLOWLIST, and these are the two ways it says no:
    an action nobody implements, and a real action asked for by a project it
    does not belong to. The second is the interesting one -- without the
    scope check, any app could drive mail-sync and write attacker-chosen
    JSON into the Mail app's store. }
  ExpectStatus('POST', '/v1/apps/spam-filter/action/mail-sync', '', 404,
               'a real action is refused to a project that does not own it');
  ExpectStatus('POST', '/v1/apps/spam-filter/action/rm-rf', '', 404,
               'an unknown action is not an action');
  ExpectStatus('POST', '/v1/apps/mail/action/rm-rf', '', 404,
               'not even for the app that owns the surface');
  { The allowlisted call for the owning project reaches the bridge. There is
    no IMAP server here, so the honest answer is 503 -- a service that is not
    configured, not a request that was wrong. }
  ExpectStatus('POST', '/v1/apps/mail/action/mail-sync', '', 503,
               'mail-sync reaches the bridge and reports it is unconfigured');
  ExpectBodyContains('POST', '/v1/apps/mail/action/mail-sync', '',
                     '"configured":false',
                     'and says so in a form the app can render');
  ExpectTrue(IsAppScopedPath('/v1/apps/mail/action/mail-sync'),
             'actions are reachable from the apps origin');

  { ------------------------------------------------- memory + notes -- }
  (* The two surfaces that make Brain and Notes honest. Brain over its own
     state store would be a notepad wearing the word "memory"; these assert
     that the app is looking at the agent's own data and can change it. *)
  ExpectStatus('GET', '/v1/apps/brain/read/memory', '', 200,
               'the memory surface exists');
  ExpectBodyContains('GET', '/v1/apps/brain/read/memory', '', '"surface":"memory"',
                     'and is labelled');
  ExpectStatus('POST', '/v1/apps/brain/action/memory-remember',
               '{"text":"Ships on Fridays"}', 200, 'Brain can remember');
  ExpectBodyContains('GET', '/v1/apps/brain/read/memory', '', 'Ships on Fridays',
                     'and the fact comes back on the surface the app reads');

  { Scope, again: these are the actions that edit what the assistant knows,
    so the wrong project asking must get nowhere. }
  ExpectStatus('POST', '/v1/apps/notes/action/memory-forget', '{"id":1}', 404,
               'only Brain may forget');
  ExpectStatus('POST', '/v1/apps/brain/action/note-save', '{"title":"x"}', 404,
               'only Notes may write notes');
  ExpectStatus('POST', '/v1/apps/brain/action/memory-forget', '{}', 400,
               'forget needs to say which fact');

  { Notes land as markdown in the memory directory -- that IS the feature,
    so assert the file, not just the response. }
  ExpectStatus('POST', '/v1/apps/notes/action/note-save',
               '{"title":"Invoice terms","body":"Net 30."}', 200, 'note saved');
  ExpectTrue(FileExists(JoinPath(NotesDir, 'invoice-terms.md')),
             'a note is a markdown file the agent can read');
  ExpectBodyContains('GET', '/v1/apps/notes/read/notes', '', 'Invoice terms',
                     'and shows up on the notes surface');

  (* The slug is the only path from a text box to a filename. Every one of
     these must fail to name a file -- and they fail by not being in the
     alphabet at all, which is why this is a whitelist and not a list of
     traversal patterns to block. *)
  ExpectStatus('POST', '/v1/apps/notes/action/note-save',
               '{"name":"../../../../escaped","title":"x","body":"y"}', 400,
               'ESCAPE: traversal in a note name');
  ExpectStatus('POST', '/v1/apps/notes/action/note-save',
               '{"name":"/etc/passwd","title":"x","body":"y"}', 400,
               'ESCAPE: absolute path in a note name');
  ExpectTrue(not FileExists(JoinPath(GetHome, 'escaped.md')),
             'ESCAPE: nothing was written outside the notes directory');

  { A title of pure punctuation still has to produce a usable filename
    rather than '', which would resolve to the notes directory itself. }
  ExpectTrue(SlugForNote('!!!') <> '', 'an unsluggable title still gets a name');
  ExpectStr(SlugForNote('Hello, World!'), 'hello-world', 'ordinary slug');
  ExpectStr(SlugForNote('  spaced  out  '), 'spaced-out', 'no leading/trailing dashes');

  { Deleting twice is not an error -- the caller wanted it gone and it is. }
  ExpectStatus('POST', '/v1/apps/notes/action/note-delete',
               '{"name":"invoice-terms"}', 200, 'note deleted');
  ExpectStatus('POST', '/v1/apps/notes/action/note-delete',
               '{"name":"invoice-terms"}', 200, 'deleting it again is fine');

  { ------------------------------------------- calendar + to-do actions -- }
  { These two act on real records, so the suite has to be installed for
    there to be anything to act on. }
  SeedSuite(Err);
  ExpectTrue(ProjectExists('todo'), 'the to-do app is a project');
  (* Calendar schedules through Tool_Cron, so the interesting assertions are
     that a bad schedule is REFUSED rather than silently accepted. A cron
     entry with a malformed spec, or one naming a skill nobody installed,
     never fires -- and a normal person has no way to discover that. *)
  ExpectStatus('POST', '/v1/apps/calendar/action/cron-add',
               '{"spec":"nonsense","skill":"whatever"}', 400,
               'a malformed cron spec is refused');
  ExpectStatus('POST', '/v1/apps/calendar/action/cron-add',
               '{"spec":"0 9 * * 1","skill":"not-installed"}', 400,
               'scheduling an uninstalled skill is refused');
  ExpectStatus('POST', '/v1/apps/todo/action/cron-add',
               '{"spec":"0 9 * * 1","skill":"x"}', 404,
               'only Calendar may schedule');
  ExpectStatus('GET', '/v1/apps/calendar/read/skills', '', 200,
               'the skills surface exists so Calendar can offer a choice');

  (* To Do writes to the REAL board -- that unification is the feature, so
     assert against the store rather than the response. *)
  ExpectStatus('POST', '/v1/apps/todo/action/task-add',
               '{"title":"Renew the domain"}', 200, 'to-do adds a task');
  ExpectBodyContains('GET', '/v1/projects/todo/tasks', '', 'Renew the domain',
                     'and it is an ordinary task on the project board');
  ExpectBodyContains('GET', '/v1/apps/todo/read/tasks', '', 'Renew the domain',
                     'visible on the app surface too');
  ExpectStatus('POST', '/v1/apps/calendar/action/task-add', '{"title":"x"}', 404,
               'only To Do may add to its board');

  { The tasks surface is scoped by the ROUTE, not by anything the app says --
    an app cannot read another project's board by naming it. }
  ExpectBodyContains('GET', '/v1/apps/calendar/read/tasks', '', '"items":[]',
                     'the tasks surface is scoped to the calling app');

  (* Ticking the checkbox must not wipe the title. It did once: the store
     spells "leave this field alone" as '' for the title and '-' for the
     notes, and a caller using the wrong one silently cleared the text. *)
  ExpectStatus('POST', '/v1/apps/todo/action/task-done',
               '{"id":"T0001","status":"done"}', 200, 'to-do closes a task');
  ExpectBodyContains('GET', '/v1/apps/todo/read/tasks', '', 'Renew the domain',
                     'closing a task keeps its title');
  ExpectBodyContains('GET', '/v1/apps/todo/read/tasks', '', '"status":"done"',
                     'and actually closes it');

  { The apps-origin split. IsAppScopedPath decides what the --apps-port
    listener will serve; everything it excludes is unreachable from an app's
    own origin, which is the whole point of the second listener. }
  ExpectTrue(IsAppScopedPath('/v1/apps/spam-filter/state/rules'),
             'an app may reach its own state');
  ExpectTrue(IsAppScopedPath('/v1/apps/spam-filter/read/cron'),
             'an app may reach its read window');
  ExpectTrue(not IsAppScopedPath('/v1/apps/spam-filter'),
             'the manifest is desktop business, not app business');
  ExpectTrue(not IsAppScopedPath('/v1/apps/spam-filter/run'),
             'an app may NOT start a process');
  ExpectTrue(not IsAppScopedPath('/v1/projects'),
             'an app may NOT read the board');
  ExpectTrue(not IsAppScopedPath('/v1/config'),
             'an app may NOT read config');
  ExpectTrue(not IsAppScopedPath('/v1/chat/completions'),
             'an app may NOT talk to the model');

  { The desktop learns the arrangement rather than guessing it. }
  ExpectStatus('GET', '/v1/desktop/config', '', 200, 'desktop config route');
  ExpectBodyContains('GET', '/v1/desktop/config', '', '"apps_isolated":false',
                     'a single-listener gateway reports apps are NOT isolated');
  SetAppsOrigin('http://127.0.0.1:9999');
  ExpectBodyContains('GET', '/v1/desktop/config', '', '"apps_isolated":true',
                     'and reports isolation once an apps origin is set');
  ExpectBodyContains('GET', '/v1/desktop/config', '', '127.0.0.1:9999',
                     'carrying the origin the client must use');
  SetAppsOrigin('');

  { When apps live on their own origin the desktop must still be allowed to
    frame them, or the isolation would break the product. }
  ExpectTrue(Pos('frame-ancestors ''self''',
                 AppContentSecurityPolicy(akHtml)) > 0,
             'by default only same-origin framing');
  SetFrameParentOrigin('http://127.0.0.1:8910');
  ExpectTrue(Pos('frame-ancestors ''self'' http://127.0.0.1:8910',
                 AppContentSecurityPolicy(akHtml)) > 0,
             'the desktop origin is named once apps are isolated');
  SetFrameParentOrigin('');

  { The virtual SDK is served per project and carries that project's name. }
  if Req('GET', '/apps/spam-filter/pasclaw.js', '', R) then
  begin
    ExpectTrue(R.Status = 200, 'the SDK is served');
    ExpectTrue(Pos('"spam-filter"', R.Body) > 0, 'SDK is scoped to its project');
    ExpectTrue(Pos('getJSON', R.Body) > 0, 'SDK exposes the state helpers');
    ExpectTrue(Pos('read:', R.Body) > 0, 'SDK exposes the read helper');
  end
  else
    Fail_('SDK route not handled');

  { ------------------------------------------------------------ blueprints -- }
  if Req('GET', '/v1/projects/spam-filter/blueprint', '', R) then
  begin
    ExpectTrue(R.Status = 200, 'blueprint exported');
    Blueprint := R.Body;
    ExpectTrue(Pos('index.html', Blueprint) > 0, 'blueprint carries app files');
  end
  else
    Fail_('blueprint route not handled');

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('blueprint', Blueprint);
    Obj.PutStr('name', 'copied');
    ExpectStatus('POST', '/v1/projects/import', Obj.ToJSON, 200, 'blueprint import');
  finally
    Obj.Free;
  end;
  ExpectTrue(ProjectExists('copied'), 'imported project exists');
  ExpectStatus('POST', '/v1/projects/import', '{"name":"x"}', 400,
               'import without a blueprint is a 400');

  (* ---- what the event stream says about the two things that FINISH ----

     Both of these had a publisher and no caller, so the stream was silent
     about exactly the transitions a client would want to act on: a page
     landing (the end of a research turn, minutes of it) and a launch that
     never got off the ground. The requesting client saw the outcome in its
     own response and every other client saw nothing at all.

     Subscribed for the whole section, drained after each act: PublishRaw
     does no work when nobody is listening, so this has to be in place before
     the route runs. *)
  Sub := DesktopSubscribe;
  try
    { A page, generated through the hook. }
    SetPageGenerator(StubPageGen);
    ExpectStatus('POST', '/v1/pages', '{"query":"event probe"}', 200,
                 'page generated');
    SetPageGenerator(nil);
    ExpectTrue(SawEvent(Sub, '"type":"page"'),
               'a finished page announces itself');

    (* And a launch that fails. Its own project, not spam-filter's: this
       manifest names a program that does not exist, and later assertions
       here still need spam-filter's real app. *)
    Slug := CreateProject('Launch Probe', '', '', Err);
    EnsureDir(ProjectAppDir(Slug));
    WriteFileText(JoinPath(ProjectAppDir(Slug), 'app.json'),
      '{"name":"Nope","kind":"python","entry":"main.py",' +
      '"run":"/nonexistent/definitely-not-here"}');
    ExpectStatus('POST', '/v1/apps/' + Slug + '/run', '{"confirm":true}', 400,
                 'a launch that cannot start is a 400');
    ExpectTrue(SawEvent(Sub, '"state":"failed"'),
               'and the failure reaches the stream, not just the caller');
  finally
    DesktopUnsubscribe(Sub);
  end;

  { ----------------------------------------------------------------- pages -- }
  ExpectStatus('GET', '/v1/pages', '', 200, 'list pages');
  ExpectStatus('POST', '/v1/pages', '{"kind":"search"}', 400, 'page without a query');
  ExpectStatus('POST', '/v1/pages', '{"query":"delphi news"}', 503,
               'page generation without an agent is a 503');

  { A caller may post a rendered body directly -- this is the path the agent
    loop itself uses once it has done the searching. }
  ExpectStatus('POST', '/v1/pages',
    '{"query":"delphi news","title":"Delphi News","body":"<p>hi</p>",' +
    '"sources":[{"title":"Embarcadero","url":"https://example.com"}]}',
    200, 'page from a supplied body');

  SetPageGenerator(StubPageGen);
  if Req('POST', '/v1/pages', '{"query":"fpc release"}', R) then
  begin
    ExpectTrue(R.Status = 200, 'page generated via the hook');
    ExpectTrue(Pos('"source_count":1', Squeeze(R.Body)) > 0, 'sources counted');
    ExpectTrue(GLastRevise = '',
               'an ordinary question revises nothing');
    { The id of the page just made, for the follow-up below. }
    PageId := JsonReadStr(R.Body, 'id', '');
  end
  else
    Fail_('page generation route not handled');

  (* Follow-up. A browser where every question throws away the last answer
     is a search box; asking again with a page open should CHANGE it. The
     route's job is to recognise the id and pass it on -- what the model
     does with it is the prompt's business, not this test's. *)
  GLastRevise := 'not-called';
  if Req('POST', '/v1/pages',
         '{"query":"now sort it by date","revise":"' + PageId + '"}', R) then
  begin
    ExpectTrue(R.Status = 200, 'a follow-up produces a page');
    ExpectTrue(GLastRevise = PageId,
               'and the generator is told which page it revises');
    { Still a NEW page: the old one is the record of an answer at a time
      and editing it in place would falsify it. }
    ExpectTrue(JsonReadStr(R.Body, 'id', '') <> PageId,
               'revision writes a new page rather than overwriting');
  end
  else
    Fail_('revise request not handled');

  { An id naming no page must not fail the whole request -- a stale tab is
    not a reason to lose the question. }
  GLastRevise := 'not-called';
  if Req('POST', '/v1/pages',
         '{"query":"anything","revise":"P9999"}', R) then
  begin
    ExpectTrue(R.Status = 200, 'a stale revise id still answers');
    ExpectTrue(GLastRevise = '', 'and is treated as a new question');
  end
  else
    Fail_('stale revise request not handled');

  SetPageGenerator(nil);

  ExpectBodyContains('GET', '/v1/pages', '', 'P0001', 'pages listed');
  ExpectStatus('GET', '/v1/pages/P0001', '', 200, 'get page metadata');
  ExpectStatus('GET', '/v1/pages/nope', '', 404, 'bad page id is a 404');

  { The rendered document is served from disk under a script-free CSP. }
  if Req('GET', '/pages/P0001/', '', R) then
  begin
    ExpectTrue(R.Status = 200, 'page document served');
    ExpectTrue(R.FilePath <> '', 'served from disk');
    ExpectTrue(Pos('script-src ''none''', R.Headers) > 0,
               'pages are served script-free');
    ExpectTrue(Pos('connect-src ''none''', R.Headers) > 0,
               'pages reach no network');
  end
  else
    Fail_('page document route not handled');

  ExpectNoFile('/pages/../config.json', 'traversal in the page slot');
  ExpectStatus('DELETE', '/v1/pages/P0001', '', 200, 'delete page');
  ExpectStatus('GET', '/v1/pages/P0001', '', 404, 'deleted page is gone');

  { --------------------------------------------- page rendering guarantees -- }
  { The sources strip is written by Pascal, not by the model, so a body that
    tries to fake or suppress provenance cannot. }
  SetLength(Sources, 0);
  PageId := SavePage('Ungrounded', 'q', pkSearch, '<p>x</p>', Sources, Err);
  ExpectTrue(PageId <> '', 'ungrounded page still saves');
  ExpectTrue(Pos('could not be grounded',
             ReadFileText(JoinPath(PageDir(PageId), 'index.html'))) > 0,
             'an ungrounded page says so on its face');

  SetLength(Sources, 1);
  Sources[0].Title := 'Ex';
  Sources[0].URL   := 'https://example.com/x';
  PageId := SavePage('Scripted', 'q', pkSearch,
    '<p>ok</p><script>fetch("/v1/config")</script>' +
    '<img src=x onerror="alert(1)"><a href="javascript:alert(2)">go</a>',
    Sources, Err);
  Blueprint := ReadFileText(JoinPath(PageDir(PageId), 'index.html'));
  ExpectTrue(Pos('<script', LowerCase(Blueprint)) = 0, 'scripts stripped from page bodies');
  ExpectTrue(Pos('onerror', LowerCase(Blueprint)) = 0, 'event handlers stripped');
  ExpectTrue(Pos('javascript:', LowerCase(Blueprint)) = 0, 'javascript: URLs neutralised');
  ExpectTrue(Pos('example.com/x', Blueprint) > 0, 'sources footer present');
  ExpectTrue(Pos('ok', Blueprint) > 0, 'legitimate content survives');

  { --------------------------------------------------- artifact versions -- }
  (* An old artifact card opens the version THAT turn produced, and can put
     it back. The write is deliberately narrow: one file, the entry the
     manifest already declares, resolved through the same two-barrier
     resolver that serves it. *)
  ExpectStatus('PUT', '/v1/apps/spam-filter/entry',
               '<!doctype html><h1>v2</h1>', 200, 'an earlier version restores');
  ExpectTrue(Pos('v2', ReadFileText(JoinPath(ProjectAppDir('spam-filter'),
                                             'index.html'))) > 0,
             'and lands in the entry file');
  ExpectStatus('GET', '/v1/apps/spam-filter/entry', '', 405,
               'entry is write-only -- reading it is what /apps/ is for');
  ExpectStatus('PUT', '/v1/apps/nope/entry', 'x', 404,
               'a project with no app has no entry to restore');

  { An app must not be able to rewrite ITSELF: the apps-origin listener has
    to refuse this path, or a generated page could edit its own source. }
  ExpectTrue(not IsAppScopedPath('/v1/apps/spam-filter/entry'),
             'ESCAPE: an app may NOT write its own entry');

  { ------------------------------------------------------- mail drafts -- }
  (* The "answer this for me" half. Nothing is SENT from here -- the draft
     lands in the app for the user to send from their own client -- so the
     assertions are about scope and about failing honestly when there is no
     model, not about delivery. *)
  ExpectStatus('POST', '/v1/apps/notes/action/mail-draft', '{"subject":"x"}', 404,
               'only Mail may draft');
  ExpectStatus('POST', '/v1/apps/mail/action/mail-draft', '{}', 503,
               'no model configured is a 503, not a fabricated draft');

  { ---------------------------------------------------- desktop state -- }
  (* The layout belongs to the WORKSPACE, not the browser: switching to the
     "home" workspace should bring back the home desktop from any machine
     pointed at this gateway. *)
  ExpectStatus('GET', '/v1/desktop/state', '', 200, 'a fresh desktop has state');
  ExpectBodyContains('GET', '/v1/desktop/state', '', '{}',
                     'and it is empty rather than a 404');
  ExpectStatus('PUT', '/v1/desktop/state',
               '{"v":1,"windows":[{"fn":"library"}]}', 200, 'state saves');
  ExpectBodyContains('GET', '/v1/desktop/state', '', 'library',
                     'and comes back');

  { A truncated PUT must not leave a state file that breaks every load. }
  ExpectStatus('PUT', '/v1/desktop/state', '{"v":1,"windows":', 400,
               'malformed state is refused before it is written');
  ExpectBodyContains('GET', '/v1/desktop/state', '', 'library',
                     'and the good state survives the bad write');

  ExpectStatus('DELETE', '/v1/desktop/state', '', 405, 'no delete verb');

  { --------------------------------------------------------- desktops -- }
  (* Desktops are VIEWS inside the workspace: numbered layouts on a pager.
     The property under test is that switching one moves nothing but the
     window arrangement -- each desktop's layout is its own document. *)
  ExpectBodyContains('GET', '/v1/desktop/desktops', '', '"current":1',
                     'a fresh workspace has one desktop');
  ExpectStatus('POST', '/v1/desktop/desktops', '{"current":2}', 200,
               'asking for the next number up creates it');
  ExpectBodyContains('GET', '/v1/desktop/desktops', '', '"count":2',
                     'and the count grew');
  ExpectStatus('POST', '/v1/desktop/desktops', '{"current":7}', 400,
               'but not by skipping ahead');
  ExpectStatus('POST', '/v1/desktop/desktops', '{"current":0}', 400,
               'and zero is not a desktop');

  { Layouts are per desktop. Write one on 2, one on 1 via ?desktop=,
    and prove they do not bleed. }
  ExpectStatus('PUT', '/v1/desktop/state', '{"v":1,"windows":[{"fn":"files"}]}',
               200, 'the current desktop (2) takes a layout');
  if Req2('PUT', '/v1/desktop/state', 'desktop=1',
          '{"v":1,"windows":[{"fn":"library"}]}', R) then
    ExpectTrue(R.Status = 200, 'desktop 1 takes a layout by name');
  ExpectBodyContains('GET', '/v1/desktop/state', '', 'files',
                     'the current desktop reads its own layout');
  if Req2('GET', '/v1/desktop/state', 'desktop=1', '', R) then
    ExpectTrue(Pos('library', R.Body) > 0, 'desktop 1 kept its own');
  ExpectStatus('POST', '/v1/desktop/desktops', '{"current":1}', 200,
               'switch back to desktop 1');
  ExpectBodyContains('GET', '/v1/desktop/state', '', 'library',
                     'and the default now reads desktop 1');


  { ------------------------------------------------------ research mode -- }
  (* Deep research is a distinct KIND, not a longer search. The prompt is
     where the difference lives, so assert the three phases are actually
     demanded -- a prompt that merely said "try harder" would produce a
     longer version of the same one-pass answer. *)
  ExpectStr(PageKindToStr(StrToPageKind('research')), 'research',
            'research round-trips as a kind');
  ExpectTrue(Pos('DEEP RESEARCH', BuildPagePrompt('x', pkResearch)) > 0,
             'the research prompt names itself');
  ExpectTrue((Pos('1. PLAN', BuildPagePrompt('x', pkResearch)) > 0) and
             (Pos('2. READ', BuildPagePrompt('x', pkResearch)) > 0) and
             (Pos('3. SYNTHESISE', BuildPagePrompt('x', pkResearch)) > 0),
             'and lays out the three phases');
  ExpectTrue(Pos('INDEPENDENT', BuildPagePrompt('x', pkResearch)) > 0,
             'and demands independent sources, not one source repeated');
  ExpectTrue(Pos('DEEP RESEARCH', BuildPagePrompt('x', pkSearch)) = 0,
             'an ordinary search is not silently upgraded');

  { ----------------------------------------------------- page promotion -- }
  (* "Make this interactive" -- a page becomes an app you own. The copy is
     the design: a page is the record of an answer at a time, so promotion
     must leave it exactly as generated. *)
  SetLength(Sources, 1);
  Sources[0].Title := 'Tracker';
  Sources[0].URL   := 'https://example.com/bugs';
  PageId := SavePage('Open bugs by age', 'open bugs by age', pkReport,
                     '<h2>Open bugs</h2><p>Four over 30 days.</p>', Sources, Err);
  ExpectTrue(PageId <> '', 'a page to promote');

  ExpectStatus('POST', '/v1/pages/' + PageId + '/promote', '', 200,
               'a page promotes to an app');
  ExpectTrue(ProjectExists('open-bugs-by-age'), 'and lands as a real project');
  ExpectTrue(GetApp('open-bugs-by-age', AppInfo) and AppInfo.Exists,
             'with an app manifest');
  ExpectStr(AppKindToStr(AppInfo.Kind), 'html',
            'as html -- a page is inert, an app can move');

  Blueprint := ReadFileText(JoinPath(ProjectAppDir('open-bugs-by-age'),
                                     'index.html'));
  ExpectTrue(Pos('example.com/bugs', Blueprint) > 0,
             'provenance survives promotion -- it does not stop mattering');
  ExpectTrue(Pos('pasclaw.js', Blueprint) > 0,
             'and the SDK is wired for the first "now make it sortable"');

  { The page is a record, not a draft. Promotion must not touch it. }
  ExpectStatus('GET', '/pages/' + PageId + '/', '', 200,
               'the page is still there afterwards');

  ExpectStatus('POST', '/v1/pages/P9999/promote', '', 400,
               'promoting a page that does not exist is a 400, not a crash');

  { ------------------------------------------------- workspace scoping again -- }
  { The board a client sees must follow the active workspace. }
  ExpectStatus('POST', '/v1/workspaces/activate', '{"name":"workspace2"}', 200,
               'switch to workspace2');
  if Req('GET', '/v1/projects', '', R) then
    ExpectTrue(Pos('spam-filter', R.Body) = 0,
               'workspace2 does not see workspace1 projects');
  ExpectStatus('GET', '/v1/projects/spam-filter', '', 404,
               'and cannot address them directly');
  ExpectStatus('GET', '/apps/spam-filter/index.html', '', 404,
               'nor serve their app files');

  (* The off-origin scan behind the "app may render unstyled" warning.

     The app CSP blocks every off-origin load SILENTLY -- an app styled
     from a CDN renders bare in every PasClaw viewer while the same file
     opened straight into a browser looks perfect. The scan is what turns
     that silence into a log line, so what it counts (and what it must
     not) is worth pinning. *)
  ExpectTrue(OffOriginHosts(
    '<script src="https://cdn.tailwindcss.com"></script>') =
    'cdn.tailwindcss.com',
    'a CDN script is an off-origin load');
  ExpectTrue(OffOriginHosts(
    '<link rel="stylesheet" href="https://cdnjs.cloudflare.com/x.css">') =
    'cdnjs.cloudflare.com',
    'a CDN stylesheet is too');
  ExpectTrue(OffOriginHosts(
    '<script src="https://a.test/x.js"></script>' +
    '<link href="https://fonts.googleapis.com/css2?family=Inter" rel="stylesheet">' +
    '<script src="https://a.test/y.js"></script>') =
    'a.test fonts.googleapis.com',
    'hosts are collected once each');
  ExpectTrue(OffOriginHosts(
    '<a href="https://example.com/docs">read the docs</a>') = '',
    'a plain link is navigation, not a load -- no warning');
  ExpectTrue(OffOriginHosts(
    '<script src="pasclaw.js"></script>' +
    '<link rel="stylesheet" href="style.css">') = '',
    'same-origin references are fine');
  ExpectTrue(OffOriginHosts('<p>see https://example.com in prose</p>') = '',
    'a URL in text content is not a load either');

  if Failures = 0 then
    WriteLn('desktop_routes_tests: OK')
  else
  begin
    WriteLn('desktop_routes_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
