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
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Pages,
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

function StubPageGen(const Query: string; Kind: TPageKind;
  out Title, BodyHTML, SourcesJSON, Err: string): Boolean;
begin
  Err := '';
  Title := 'About ' + Query;
  BodyHTML := '<p>Answer about ' + Query + '</p>';
  SourcesJSON := '[{"title":"Example","url":"https://example.com/a"}]';
  Result := True;
end;

var
  R: TDesktopResponse;
  Err, AppDir, Slug, Blueprint: string;
  Obj: TJsonObject;
  Sources: TPageSourceArray;
  PageId: string;
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

  ExpectStatus('PATCH', '/v1/projects/spam-filter', '{"icon":"Mail"}', 200, 'patch project');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', '"icon":"Mail"',
                     'patch persisted');
  ExpectBodyContains('GET', '/v1/projects/spam-filter', '', '"title":"Spam Filter"',
                     'patch did not clobber the title');

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
  end
  else
    Fail_('page generation route not handled');
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

  if Failures = 0 then
    WriteLn('desktop_routes_tests: OK')
  else
  begin
    WriteLn('desktop_routes_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
