program apps_tests;
(*
  Pins PasClaw.Apps: manifest reading, the two-barrier asset path resolver
  (this is the containment boundary for model-authored code, so the escape
  attempts are the point of the file), the CSP split between `page` and
  `html`, the per-app state store, and blueprint export/import -- including
  that a blueprint carries the software but never the data.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Apps.Runner;

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

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" not in: ' + Copy(Haystack, 1, 400));
end;

procedure ExpectMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' -- "' + Needle + '" unexpectedly present');
end;

{ Every one of these must resolve to '' -- a served path that escapes the app
  directory would hand out the user's whole home directory. }
procedure ExpectBlocked(const Project, RelPath, Msg: string);
begin
  if ResolveAssetPath(Project, RelPath) <> '' then
    Fail_('ESCAPE: ' + Msg + ' (' + RelPath + ')');
end;

var
  Err, Slug, AppDir, Blueprint, Val, Resolved: string;
  Info: TAppInfo;
  Keys: TStringList;
  DArgs, Env: TStringList;
  Joined: string;
  Tasks: TTaskInfoArray;
begin
  Slug := CreateProject('Spam Filter', '', 'filter mail', Err);
  ExpectStr(Slug, 'spam-filter', 'project created');
  AppDir := ProjectAppDir('spam-filter');

  { ------------------------------------------------------------- manifest -- }
  { No app yet reads as "no app", not as an error. }
  ExpectTrue(GetApp('spam-filter', Info), 'appless project still loads');
  ExpectTrue(not Info.Exists, 'and reports no app');

  WriteFileText(JoinPath(AppDir, 'app.json'),
    '{"name":"Spam Filter","kind":"html","entry":"index.html",' +
    '"window":{"width":700,"height":520,"icon":"Mail"},' +
    '"permissions":{"network":["imap.gmail.com:993"],"env":["IMAP_PASSWORD"]}}');
  WriteFileText(JoinPath(AppDir, 'index.html'), '<h1>hi</h1>');

  ExpectTrue(GetApp('spam-filter', Info), 'manifest loads');
  ExpectTrue(Info.Exists, 'app reported present');
  ExpectTrue(Info.Kind = akHtml, 'kind parsed');
  ExpectStr(Info.Entry, 'index.html', 'entry parsed');
  ExpectTrue(Info.Width = 700, 'window width parsed');
  ExpectStr(Info.Icon, 'Mail', 'icon parsed');
  ExpectStr(Info.Network, 'imap.gmail.com:993', 'declared network surfaced for consent');
  ExpectStr(Info.EnvKeys, 'IMAP_PASSWORD', 'declared env surfaced for consent');
  ExpectTrue(Info.EntryExists, 'entry file found');
  ExpectTrue(AppIsServable(Info), 'html apps are servable');

  { A corrupt manifest must degrade to "no app", never throw. }
  WriteFileText(JoinPath(AppDir, 'app.json'), '{not json');
  ExpectTrue(GetApp('spam-filter', Info), 'broken manifest does not throw');
  ExpectTrue(not Info.Exists, 'broken manifest reads as no app');
  WriteFileText(JoinPath(AppDir, 'app.json'),
    '{"name":"Spam Filter","kind":"html","entry":"index.html"}');

  { ------------------------------------------------------- asset resolving -- }
  Resolved := ResolveAssetPath('spam-filter', 'index.html');
  ExpectTrue(Resolved <> '', 'entry file resolves');
  ExpectContains(Resolved, 'index.html', 'resolved to the right file');

  { An empty path is a directory request -> the manifest's entry. }
  ExpectTrue(ResolveAssetPath('spam-filter', '') <> '', 'directory request serves the entry');

  EnsureDir(JoinPath(AppDir, 'assets'));
  WriteFileText(JoinPath(JoinPath(AppDir, 'assets'), 'app.css'), 'body{}');
  ExpectTrue(ResolveAssetPath('spam-filter', 'assets/app.css') <> '',
             'subdirectory assets resolve');

  { --- the escape suite --- }
  ExpectBlocked('spam-filter', '../project.json',        'parent traversal');
  ExpectBlocked('spam-filter', '../../../../etc/passwd', 'deep traversal');
  ExpectBlocked('spam-filter', 'assets/../../project.json', 'traversal mid-path');
  ExpectBlocked('spam-filter', '/etc/passwd',            'absolute path');
  ExpectBlocked('spam-filter', '..\\project.json',       'backslash traversal');
  ExpectBlocked('spam-filter', './index.html',           'dot segment');
  ExpectBlocked('spam-filter', 'C:\\windows\\win.ini',   'drive-letter path');
  ExpectBlocked('spam-filter', 'index.html'#0'.png',     'NUL byte');
  ExpectBlocked('spam-filter', 'assets//app.css',        'empty segment');
  ExpectBlocked('../escape',   'index.html',             'unsafe project name');
  { Extension allowlist: state.json is servable-by-extension but the app's
    own secrets-adjacent files should not be reachable by a wrong guess. }
  WriteFileText(JoinPath(AppDir, 'notes.exe'), 'MZ');
  ExpectBlocked('spam-filter', 'notes.exe',              'non-allowlisted extension');
  ExpectTrue(ResolveAssetPath('spam-filter', 'missing.html') = '',
             'missing file resolves to nothing');

  { ------------------------------------------------------------------ CSP -- }
  ExpectContains(AppContentSecurityPolicy(akPage), 'script-src ''none''',
                 'pages run no scripts at all');
  ExpectContains(AppContentSecurityPolicy(akPage), 'connect-src ''none''',
                 'pages reach no network');
  ExpectContains(AppContentSecurityPolicy(akHtml), 'connect-src ''self''',
                 'apps may reach only this gateway');
  ExpectMissing(AppContentSecurityPolicy(akHtml), 'script-src ''none''',
                'apps may run their own scripts');
  ExpectContains(AppContentSecurityPolicy(akHtml), 'frame-ancestors ''self''',
                 'no foreign framing');

  { ------------------------------------------------------------ state store -- }
  ExpectTrue(StateSet('spam-filter', 'rules', '["spam","promo"]', Err), 'state set');
  ExpectStr(Err, '', 'state set is clean');
  ExpectTrue(StateGet('spam-filter', 'rules', Val), 'state get');
  ExpectStr(Val, '["spam","promo"]', 'value round-trips');

  ExpectTrue(not StateGet('spam-filter', 'nothing', Val), 'missing key reports missing');
  ExpectTrue(not StateSet('spam-filter', 'bad key!', 'x', Err), 'illegal key refused');
  ExpectTrue(not StateSet('nope', 'k', 'v', Err), 'state on a missing project refused');

  ExpectTrue(StateSet('spam-filter', 'count', '3', Err), 'second key');
  Keys := StateKeys('spam-filter');
  try
    ExpectTrue(Keys.IndexOf('rules') >= 0, 'keys lists rules');
    ExpectTrue(Keys.IndexOf('count') >= 0, 'keys lists count');
  finally
    Keys.Free;
  end;

  ExpectTrue(StateDelete('spam-filter', 'count', Err), 'delete');
  ExpectTrue(not StateGet('spam-filter', 'count', Val), 'deleted key is gone');
  ExpectTrue(StateGet('spam-filter', 'rules', Val), 'sibling key survives delete');

  { ------------------------------------------------------------ blueprints -- }
  CreateTask('spam-filter', 'Connect IMAP', 'private note', Err);
  Blueprint := ExportBlueprint('spam-filter', Err);
  ExpectStr(Err, '', 'export is clean');
  ExpectContains(Blueprint, 'index.html', 'blueprint carries the app files');
  ExpectContains(Blueprint, 'Connect IMAP', 'blueprint carries task titles');
  { The whole point: software travels, data does not. }
  ExpectMissing(Blueprint, 'promo', 'blueprint must NOT carry the state store');
  ExpectMissing(Blueprint, 'private note', 'blueprint must NOT carry task notes');

  Slug := ImportBlueprint(Blueprint, 'imported', Err);
  ExpectStr(Err, '', 'import is clean');
  ExpectStr(Slug, 'imported', 'imported under the requested name');
  ExpectTrue(ProjectExists('imported'), 'imported project exists');
  ExpectTrue(FileExists(JoinPath(ProjectAppDir('imported'), 'index.html')),
             'app files landed');
  ExpectTrue(not FileExists(JoinPath(ProjectAppDir('imported'), 'state.json')),
             'no state came across');
  Tasks := ListTasks('imported');
  ExpectTrue(Length(Tasks) = 1, 'task seeded from the blueprint');
  ExpectTrue(Tasks[0].Status = tsTodo, 'imported tasks start fresh, not done');

  { Importing twice must not overwrite -- the recipient gets their own copy. }
  Slug := ImportBlueprint(Blueprint, 'imported', Err);
  ExpectStr(Slug, 'imported-2', 'second import gets its own project');
  ExpectTrue(ProjectExists('imported'), 'first import untouched');

  ExpectStr(ImportBlueprint('{"nope":1}', '', Err), '', 'non-blueprint refused');
  ExpectTrue(Err <> '', 'and says why');
  ExpectStr(ImportBlueprint('not json', '', Err), '', 'malformed JSON refused');

  { A blueprint from elsewhere is untrusted input: its file paths get the
    same treatment as an HTTP request's. }
  Slug := ImportBlueprint(
    '{"blueprint":"1","name":"eviltest","title":"Evil","files":[' +
    '{"path":"../../../../escaped.html","body":"pwned"},' +
    '{"path":"ok.html","body":"fine"}]}', 'evil', Err);
  ExpectStr(Slug, 'evil', 'import still succeeds');
  ExpectTrue(FileExists(JoinPath(ProjectAppDir('evil'), 'ok.html')), 'safe file written');
  ExpectTrue(not FileExists(JoinPath(GetHome, 'escaped.html')),
             'ESCAPE: traversal path in a blueprint must not be written');

  { ------------------------------------------------ docker run policy -- }
  { The argv the runner hands `docker run` is the isolation policy in
    executable form: which directory is mounted, where the port is
    published, what image. Asserted here so it is reviewable on a machine
    with no Docker -- otherwise the only way to check it is to run it. }
  DArgs := TStringList.Create;
  try
    BuildDockerRunArgs('spam-filter', '/home/u/.pasclaw/workspace/projects/spam-filter/app',
                       'python3 main.py 8700', 'debian:bookworm-slim', 8700, nil,
                       True, DArgs);
    Joined := DArgs.Text;
    ExpectContains(Joined, 'create',
      'created rather than run, so files can land before anything starts');
    ExpectContains(Joined, '--rm', 'no corpse left behind');
    ExpectContains(Joined, 'pasclaw-app-spam-filter', 'identifiable container name');
    ExpectContains(Joined,
      '/home/u/.pasclaw/workspace/projects/spam-filter/app:/app',
      'the app directory is mounted');
    ExpectContains(Joined, '127.0.0.1:8700:8700',
      'the port is published to LOOPBACK, never 0.0.0.0');
    ExpectContains(Joined, 'debian:bookworm-slim', 'the configured image is used');
    { Nothing broader than the app dir may be mounted -- a workspace or home
      mount would hand the container everything. }
    ExpectMissing(Joined, '.pasclaw:/', 'the home directory is NOT mounted');
    ExpectMissing(Joined, '--privileged', 'not privileged');
    ExpectMissing(Joined, '--network host', 'not on the host network');

    { No port -> no publish rule at all. }
    BuildDockerRunArgs('spam-filter', '/tmp/app', 'python3 worker.py',
                       'debian:bookworm-slim', 0, nil, True, DArgs);
    ExpectMissing(DArgs.Text, '-p', 'a console app publishes no port');

    (* Remote daemon: no bind mount. A -v path resolves on the DAEMON's
       filesystem, so against a remote daemon it names something that is not
       there and the app comes up against an empty /app -- silently. The
       caller copies the directory in instead. *)
    BuildDockerRunArgs('spam-filter', '/tmp/app', 'python3 worker.py',
                       'debian:bookworm-slim', 0, nil, False, DArgs);
    ExpectMissing(DArgs.Text, '/tmp/app:/app',
      'no bind mount when the daemon is elsewhere');
    ExpectContains(DArgs.Text, '-w' + sLineBreak + '/app',
      'but the working directory is still /app');

    { Declared env travels as -e pairs, one per name. }
    Env := TStringList.Create;
    try
      Env.Add('IMAP_PASSWORD=hunter2');
      BuildDockerRunArgs('spam-filter', '/tmp/app', 'python3 main.py',
                         'debian:bookworm-slim', 0, Env, True, DArgs);
      ExpectContains(DArgs.Text, 'IMAP_PASSWORD=hunter2', 'declared env passed through');
    finally
      Env.Free;
    end;
  finally
    DArgs.Free;
  end;

  (* An endpoint we cannot read must count as LOCAL. There is no docker on
     this machine, so the probe fails -- and calling that "remote" would
     refuse to run apps on a perfectly ordinary local Docker just because
     the probe did. Failing safe here means failing towards the behaviour
     that has always worked. *)
  ExpectTrue(not DockerIsRemote,
             'an unreadable docker endpoint is treated as local');
  ExpectStr(RunnerBackendName, 'host',
            'and with shell_backend unset the runner is on the host');

  if Failures = 0 then
    WriteLn('apps_tests: OK')
  else
  begin
    WriteLn('apps_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
