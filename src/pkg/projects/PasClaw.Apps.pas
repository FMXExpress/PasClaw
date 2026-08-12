(*
  PasClaw.Apps - the app factory's runtime: manifests, serving, state, and
  blueprints.

  A project's app lives in projects/<name>/app/ and is described by app.json:

    {
      "name": "Spam Filter",
      "kind": "page | html | python | fpc | delphi",
      "entry": "index.html",
      "run":   "python3 main.py --port {port}",
      "build": "fpc src/spamfilter.pas",
      "window": { "width": 640, "height": 480, "icon": "Mail" },
      "permissions": { "network": ["imap.gmail.com:993"], "env": ["IMAP_PASSWORD"] }
    }

  Five kinds, cheapest first:

    page    a single static HTML document, no scripts. What an answer page is
            (see PasClaw.Pages). Nothing to run; the gateway serves it.
    html    a self-contained page WITH scripts, allowed to call this unit's
            state store so it can persist without a backend process.
    python  a script run through the shell backend.
    fpc     compiled with fpc, then launched as a native process.
    delphi  built via the delphi_build tool on a host with RAD Studio.

  Serving is deliberately narrow: ResolveAssetPath refuses anything that
  escapes the app directory, and only a known extension set is served. A
  generated app is untrusted code -- it is authored by a model, from text a
  web page may have influenced -- so the containment is here, in Pascal, not
  in the client.

  The state store is the reason `html` is worth having at all. Most useful
  small apps need a little persistence (filter rules, a todo list, a reading
  log) and spawning a Python process for that is absurd. Each app gets a
  key/value namespace at projects/<name>/app/state.json, reachable over HTTP
  at /v1/apps/<project>/state/<key>. Kept as JSON rather than SQLite so the
  user can read and edit their own data with a text editor -- these stores
  hold personal notes, not scale.
*)
unit PasClaw.Apps;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TAppKind = (akNone, akPage, akHtml, akPython, akFpc, akDelphi);

  TAppInfo = record
    Project:     string;
    Name:        string;
    Kind:        TAppKind;
    Entry:       string;   { relative to app/ }
    Run:         string;   { shell template for python/native kinds }
    Build:       string;
    Width:       Integer;
    Height:      Integer;
    Icon:        string;
    Network:     string;   { comma-joined host:port list, for display/consent }
    EnvKeys:     string;   { comma-joined env var names the app expects }
    Exists:      Boolean;  { app.json present }
    EntryExists: Boolean;  { the entry file is actually there }
  end;

function AppKindToStr(K: TAppKind): string;
function StrToAppKind(const S: string): TAppKind;

{ Read projects/<project>/app/app.json. Exists=False when there is no app
  yet -- callers show "no app" rather than an error. }
function GetApp(const Project: string; out Info: TAppInfo): Boolean;

{ Write/merge an app manifest. Used by the blueprint importer and the suite
  seeder; the agent itself writes app.json with write_file like any other
  file, which is the point -- the manifest is editable source, not a private
  format. }
function WriteApp(const Project: string; const Info: TAppInfo;
  out Err: string): Boolean;

{ True when the app can be opened in a desktop window without running
  anything (page/html). }
function AppIsServable(const Info: TAppInfo): Boolean;

{ Map a request path under /apps/<project>/... to a real file inside the
  app directory. Returns '' when the project is unknown, the app has no
  files, the path escapes the app dir, or the extension isn't servable. }
function ResolveAssetPath(const Project, RelPath: string): string;

{ MIME type for a served asset. }
function AssetContentType(const Path: string): string;

(* The app SDK, served virtually at /apps/<project>/pasclaw.js.

   An html app is sandboxed WITHOUT allow-same-origin, so it sits in an opaque
   origin and cannot fetch this gateway directly -- which is the point: if it
   could, it would also be same-origin with the desktop page and could read the
   operator's bearer token out of localStorage.

   So state goes through a broker. Inside the desktop the SDK posts a message
   to the parent, which performs the call scoped to THIS project and posts the
   answer back. Opened standalone (a plain tab, or the FMX client's browser
   window) the page is genuinely same-origin, and the SDK falls back to fetch.
   The app author writes the same two calls either way.

   Injected with the project name so an app cannot address another app's
   store even by editing its own copy of the SDK -- the broker re-checks. *)
function AppSDK(const Project: string): string;

{ Content-Security-Policy for served app content. `page` kind gets a
  script-free policy; `html` may run its own inline scripts but may not
  reach any other origin. Neither may be framed by a foreign site. }
function AppContentSecurityPolicy(Kind: TAppKind): string;

(* The origin allowed to FRAME app content, besides the app's own.

   When apps are served from their own port (the isolated arrangement), the
   desktop is a different origin -- so a bare `frame-ancestors 'self'` would
   stop the desktop displaying its own apps. This names the one page that may
   embed them. Empty (the default) keeps the strict same-origin rule. *)
procedure SetFrameParentOrigin(const Origin: string);

{ ---- per-app state store ---- }

function StateGet(const Project, Key: string; out Value: string): Boolean;
function StateSet(const Project, Key, Value: string; out Err: string): Boolean;
function StateDelete(const Project, Key: string; out Err: string): Boolean;
function StateKeys(const Project: string): TStringList;   { caller frees }

{ ---- blueprints ---- }

{ Serialise a project's app + manifests as a single JSON document: the app's
  files (text only) plus project.json and the task titles. Deliberately does
  NOT include state.json, job history, or anything from the environment --
  a blueprint is the software, not the data or the secrets. }
function ExportBlueprint(const Project: string; out Err: string): string;

{ Instantiate a blueprint as a new project. Returns the new project slug. }
function ImportBlueprint(const BlueprintJSON, PreferredName: string;
  out Err: string): string;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Projects.Store;

const
  { Extensions the gateway will serve out of an app directory. An allowlist,
    not a denylist: a generated app has no business shipping a .so, and a
    typo in a denylist is a hole. }
  ServableExts: array[0..16] of string =
    ('.html', '.htm', '.css', '.js', '.json', '.svg', '.png', '.jpg',
     '.jpeg', '.gif', '.webp', '.ico', '.txt', '.md', '.woff', '.woff2', '.map');

  MaxStateValue = 1024 * 1024;      { 1 MiB per key }
  MaxBlueprintFile = 512 * 1024;    { skip anything bigger when exporting }

var
  { The desktop's origin, when apps are served from a separate one. }
  GFrameParent: string = '';

function AppKindToStr(K: TAppKind): string;
begin
  case K of
    akPage:   Result := 'page';
    akHtml:   Result := 'html';
    akPython: Result := 'python';
    akFpc:    Result := 'fpc';
    akDelphi: Result := 'delphi';
    else      Result := '';
  end;
end;

function StrToAppKind(const S: string): TAppKind;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if      L = 'page'   then Result := akPage
  else if L = 'html'   then Result := akHtml
  else if L = 'python' then Result := akPython
  else if L = 'fpc'    then Result := akFpc
  else if L = 'delphi' then Result := akDelphi
  else Result := akNone;
end;

function AppIsServable(const Info: TAppInfo): Boolean;
begin
  Result := Info.Exists and (Info.Kind in [akPage, akHtml]);
end;

function GetApp(const Project: string; out Info: TAppInfo): Boolean;
var
  Dir, Path: string;
  Obj, Win, Perm: TJsonObject;
  Arr: TJsonArray;
  I: Integer;
  S: string;
begin
  Result := False;
  FillChar(Info, SizeOf(Info), 0);
  Info.Project := ''; Info.Name := ''; Info.Entry := ''; Info.Run := '';
  Info.Build := ''; Info.Icon := ''; Info.Network := ''; Info.EnvKeys := '';
  Info.Kind := akNone;
  Info.Width := 640;
  Info.Height := 480;

  Dir := ProjectAppDir(Project);
  if Dir = '' then Exit;
  Info.Project := Project;
  Path := JoinPath(Dir, 'app.json');
  if not FileExists(Path) then
    Exit(True);   { valid answer: this project has no app yet }

  try
    Obj := TJsonObject.Parse(ReadFileText(Path));
  except
    Exit(True);   { a broken manifest reads as "no app", never as a crash }
  end;
  try
    Info.Exists := True;
    Info.Name   := Obj.GetStr('name', Project);
    Info.Kind   := StrToAppKind(Obj.GetStr('kind', ''));
    Info.Entry  := Obj.GetStr('entry', '');
    Info.Run    := Obj.GetStr('run', '');
    Info.Build  := Obj.GetStr('build', '');

    Win := Obj.ChildObject('window');
    if Win <> nil then
    begin
      Info.Width  := Integer(Win.GetInt('width', 640));
      Info.Height := Integer(Win.GetInt('height', 480));
      Info.Icon   := Win.GetStr('icon', '');
    end;

    Perm := Obj.ChildObject('permissions');
    if Perm <> nil then
    begin
      Arr := Perm.ChildArray('network');
      if Arr <> nil then
        for I := 0 to Arr.Count - 1 do
        begin
          S := Arr.ItemStr(I, '');
          if S = '' then Continue;
          if Info.Network <> '' then Info.Network := Info.Network + ', ';
          Info.Network := Info.Network + S;
        end;
      Arr := Perm.ChildArray('env');
      if Arr <> nil then
        for I := 0 to Arr.Count - 1 do
        begin
          S := Arr.ItemStr(I, '');
          if S = '' then Continue;
          if Info.EnvKeys <> '' then Info.EnvKeys := Info.EnvKeys + ', ';
          Info.EnvKeys := Info.EnvKeys + S;
        end;
    end;
  finally
    Obj.Free;
  end;

  { Default entry by kind, so a manifest that omits it still opens. }
  if Info.Entry = '' then
    case Info.Kind of
      akPage, akHtml: Info.Entry := 'index.html';
      akPython:       Info.Entry := 'main.py';
    end;
  if Info.Entry <> '' then
    Info.EntryExists := FileExists(JoinPath(Dir, Info.Entry));
  Result := True;
end;

function WriteApp(const Project: string; const Info: TAppInfo;
  out Err: string): Boolean;
var
  Dir: string;
  Obj, Win: TJsonObject;
begin
  Err := '';
  Result := False;
  Dir := ProjectAppDir(Project);
  if Dir = '' then
  begin
    Err := 'not a project name: ' + Project;
    Exit;
  end;
  if not ProjectExists(Project) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  EnsureDir(Dir);

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('name', Info.Name);
    Obj.PutStr('kind', AppKindToStr(Info.Kind));
    Obj.PutStr('entry', Info.Entry);
    if Info.Run   <> '' then Obj.PutStr('run', Info.Run);
    if Info.Build <> '' then Obj.PutStr('build', Info.Build);
    Win := TJsonObject.Create;
    Win.PutInt('width',  Info.Width);
    Win.PutInt('height', Info.Height);
    if Info.Icon <> '' then Win.PutStr('icon', Info.Icon);
    Obj.PutObject('window', Win);
    WriteFileText(JoinPath(Dir, 'app.json'), Obj.ToJSON);
  finally
    Obj.Free;
  end;
  Result := True;
end;

{ ---------------------------------------------------------------- serving -- }

function IsServableExt(const Ext: string): Boolean;
var
  I: Integer;
  L: string;
begin
  L := LowerCase(Ext);
  for I := Low(ServableExts) to High(ServableExts) do
    if L = ServableExts[I] then Exit(True);
  Result := False;
end;

{ Reject any path that could leave the app directory. Checked on the raw
  request text BEFORE it is joined to anything: '..' segments, absolute
  paths, drive letters, backslashes and NULs all disqualify it outright.
  Belt and braces -- the resolved path is re-checked against the app dir
  prefix afterwards too. }
function IsSafeRelPath(const P: string): Boolean;
var
  I: Integer;
  Parts: TStringList;
begin
  Result := False;
  if P = '' then Exit;
  if Pos(#0, P) > 0 then Exit;
  if Pos('\', P) > 0 then Exit;
  if P[1] = '/' then Exit;
  if (Length(P) > 1) and (P[2] = ':') then Exit;
  Parts := SplitToList(P, '/');
  try
    for I := 0 to Parts.Count - 1 do
    begin
      if Parts[I] = '' then Exit;      { '//' or a trailing slash }
      if Parts[I] = '.' then Exit;
      if Parts[I] = '..' then Exit;
    end;
  finally
    Parts.Free;
  end;
  Result := True;
end;

function ResolveAssetPath(const Project, RelPath: string): string;
var
  Dir, Rel, Full, DirNorm: string;
  Info: TAppInfo;
begin
  Result := '';
  Dir := ProjectAppDir(Project);
  if (Dir = '') or not DirectoryExists(Dir) then Exit;

  Rel := RelPath;
  while (Rel <> '') and (Rel[1] = '/') do
    Delete(Rel, 1, 1);
  if Rel = '' then
  begin
    { Directory request: hand back the manifest's entry document. }
    if not GetApp(Project, Info) then Exit;
    if not AppIsServable(Info) then Exit;
    Rel := Info.Entry;
    if Rel = '' then Rel := 'index.html';
  end;
  if not IsSafeRelPath(Rel) then Exit;
  if not IsServableExt(ExtractFileExt(Rel)) then Exit;

  Full := JoinPath(Dir, Rel);
  { Second barrier: whatever the path text did, the result must still sit
    inside the app directory. Compares normalised prefixes rather than
    trusting the join. }
  DirNorm := IncludeTrailingPathDelimiter(NormalizePathSep(Dir));
  if not HasPrefix(NormalizePathSep(Full), DirNorm) then Exit;
  if not FileExists(Full) then Exit;
  Result := Full;
end;

function AssetContentType(const Path: string): string;
var
  E: string;
begin
  E := LowerCase(ExtractFileExt(Path));
  if      (E = '.html') or (E = '.htm') then Result := 'text/html; charset=utf-8'
  else if E = '.css'   then Result := 'text/css; charset=utf-8'
  else if E = '.js'    then Result := 'application/javascript; charset=utf-8'
  else if E = '.json'  then Result := 'application/json; charset=utf-8'
  else if E = '.svg'   then Result := 'image/svg+xml'
  else if E = '.png'   then Result := 'image/png'
  else if (E = '.jpg') or (E = '.jpeg') then Result := 'image/jpeg'
  else if E = '.gif'   then Result := 'image/gif'
  else if E = '.webp'  then Result := 'image/webp'
  else if E = '.ico'   then Result := 'image/x-icon'
  else if E = '.md'    then Result := 'text/markdown; charset=utf-8'
  else if E = '.woff'  then Result := 'font/woff'
  else if E = '.woff2' then Result := 'font/woff2'
  else Result := 'text/plain; charset=utf-8';
end;

function AppSDK(const Project: string): string;
begin
  Result :=
    '/* PasClaw app SDK -- generated per project, served at pasclaw.js. */' + #10 +
    '(function () {' + #10 +
    '  var PROJECT = ' + AnsiQuotedStr(Project, '"') + ';' + #10 +
    '  var framed = (window.parent && window.parent !== window);' + #10 +
    '  var seq = 0, waiting = {};' + #10 +
    '  if (framed) {' + #10 +
    '    window.addEventListener("message", function (e) {' + #10 +
    '      var m = e.data;' + #10 +
    '      if (!m || m.__pasclaw !== "reply" || !waiting[m.id]) return;' + #10 +
    '      var w = waiting[m.id]; delete waiting[m.id];' + #10 +
    '      if (m.error) w.reject(new Error(m.error)); else w.resolve(m.value);' + #10 +
    '    });' + #10 +
    '  }' + #10 +
    '  function ask(op, key, value) {' + #10 +
    '    if (!framed) {' + #10 +
    '      if (op === "read") {' + #10 +
    '        return fetch("/v1/apps/" + PROJECT + "/read/" +' + #10 +
    '                     encodeURIComponent(key)).then(function (r) {' + #10 +
    '          if (!r.ok) throw new Error("http " + r.status);' + #10 +
    '          return r.json().then(function (j) { return j.items || []; });' + #10 +
    '        });' + #10 +
    '      }' + #10 +
    '      if (op === "action") {' + #10 +
    '        return fetch("/v1/apps/" + PROJECT + "/action/" +' + #10 +
    '                     encodeURIComponent(key),' + #10 +
    '                     { method: "POST", body: value || "" })' + #10 +
    '          .then(function (r) { return r.json().then(function (j) {' + #10 +
    '            if (!r.ok) throw new Error(j.error || ("http " + r.status));' + #10 +
    '            return j; }); });' + #10 +
    '      }' + #10 +
    '      var url = "/v1/apps/" + PROJECT + "/state/" + encodeURIComponent(key);' + #10 +
    '      if (op === "get") {' + #10 +
    '        return fetch(url).then(function (r) {' + #10 +
    '          if (!r.ok) throw new Error("http " + r.status);' + #10 +
    '          return r.json().then(function (j) {' + #10 +
    '            return j.exists ? j.value : null; });' + #10 +
    '        });' + #10 +
    '      }' + #10 +
    '      if (op === "set")' + #10 +
    '        return fetch(url, { method: "PUT", body: value }).then(function (r) {' + #10 +
    '          if (!r.ok) throw new Error("http " + r.status); return true; });' + #10 +
    '      return fetch(url, { method: "DELETE" }).then(function () { return true; });' + #10 +
    '    }' + #10 +
    '    var id = ++seq;' + #10 +
    '    return new Promise(function (resolve, reject) {' + #10 +
    '      waiting[id] = { resolve: resolve, reject: reject };' + #10 +
    '      window.parent.postMessage(' + #10 +
    '        { __pasclaw: "state", id: id, op: op, key: key, value: value }, "*");' + #10 +
    '      setTimeout(function () {' + #10 +
    '        if (waiting[id]) { delete waiting[id]; reject(new Error("timeout")); }' + #10 +
    '      }, 10000);' + #10 +
    '    });' + #10 +
    '  }' + #10 +
    '  window.pasclaw = {' + #10 +
    '    project: PROJECT,' + #10 +
    '    /* Raw string value, or null when unset. */' + #10 +
    '    get: function (key) { return ask("get", key); },' + #10 +
    '    set: function (key, value) { return ask("set", key, String(value)); },' + #10 +
    '    remove: function (key) { return ask("del", key); },' + #10 +
    '    /* JSON convenience -- what most apps actually want. */' + #10 +
    '    getJSON: function (key, fallback) {' + #10 +
    '      return ask("get", key).then(function (v) {' + #10 +
    '        if (v === null || v === undefined || v === "") return fallback;' + #10 +
    '        try { return JSON.parse(v); } catch (e) { return fallback; }' + #10 +
    '      }, function () { return fallback; });' + #10 +
    '    },' + #10 +
    '    setJSON: function (key, obj) { return ask("set", key, JSON.stringify(obj)); },' + #10 +
    '    /* Read one of the gateway ALLOWLISTED surfaces: cron, sessions,' + #10 +
    '       providers, pages, projects. Returns the items array. Anything' + #10 +
    '       else is refused server-side. */' + #10 +
    '    read: function (surface) { return ask("read", surface); },' + #10 +
    '    /* Run one of the gateway ALLOWLISTED actions for this app. The' + #10 +
    '       optional arg is sent as the JSON request body; the server' + #10 +
    '       decides what each action accepts. Rejects with the server''s' + #10 +
    '       own message so an app can show it rather than "failed". */' + #10 +
    '    action: function (name, arg) {' + #10 +
    '      return ask("action", name,' + #10 +
    '                 arg === undefined ? "" : JSON.stringify(arg));' + #10 +
    '    }' + #10 +
    '  };' + #10 +
    '})();' + #10;
end;

procedure SetFrameParentOrigin(const Origin: string);
begin
  GFrameParent := Origin;
end;

function AppContentSecurityPolicy(Kind: TAppKind): string;
var
  Ancestors: string;
begin
  { Common to both: no plugins, no base-tag rewriting, no foreign framing,
    and no form posts anywhere. Images/styles may be inline or data: URIs. }
  Ancestors := '''self''';
  if GFrameParent <> '' then
    Ancestors := Ancestors + ' ' + GFrameParent;
  Result := 'default-src ''none''; ' +
            'img-src ''self'' data: blob:; ' +
            'style-src ''self'' ''unsafe-inline''; ' +
            'font-src ''self'' data:; ' +
            'base-uri ''none''; form-action ''none''; ' +
            'frame-ancestors ' + Ancestors;
  case Kind of
    akPage:
      { A page is a document. No scripts at all, and no network of any kind --
        everything it shows was baked in when it was generated. }
      Result := Result + '; script-src ''none''; connect-src ''none''';
    akHtml:
      { An app may run its own inline scripts and talk to this gateway (the
        state store) -- and nowhere else. No CDNs, no third-party beacons. }
      Result := Result + '; script-src ''self'' ''unsafe-inline''; ' +
                'connect-src ''self''';
    else
      Result := Result + '; script-src ''none''; connect-src ''none''';
  end;
end;

{ ------------------------------------------------------------ state store -- }

function StatePath(const Project: string): string;
var
  Dir: string;
begin
  Result := '';
  Dir := ProjectAppDir(Project);
  if Dir = '' then Exit;
  Result := JoinPath(Dir, 'state.json');
end;

function LoadState(const Project: string): TJsonObject;
var
  Path: string;
begin
  Result := nil;
  Path := StatePath(Project);
  if (Path = '') or not FileExists(Path) then Exit;
  try
    Result := TJsonObject.Parse(ReadFileText(Path));
  except
    Result := nil;
  end;
end;

{ Keys are namespaced by the app itself, so they may be any short printable
  token -- but they land in a JSON object read by the user, and a key with
  control characters or absurd length is a bug or an attack either way. }
function IsSafeStateKey(const Key: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (Key = '') or (Length(Key) > 128) then Exit;
  for I := 1 to Length(Key) do
    if not (Key[I] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', ':']) then
      Exit;
  Result := True;
end;

function StateGet(const Project, Key: string; out Value: string): Boolean;
var
  Obj: TJsonObject;
begin
  Value := '';
  Result := False;
  if not IsSafeStateKey(Key) then Exit;
  Obj := LoadState(Project);
  if Obj = nil then Exit;
  try
    if not Obj.Has(Key) then Exit;
    Value := Obj.GetStr(Key, '');
    Result := True;
  finally
    Obj.Free;
  end;
end;

function StateSet(const Project, Key, Value: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Path: string;
begin
  Err := '';
  Result := False;
  Path := StatePath(Project);
  if Path = '' then
  begin
    Err := 'not a project name: ' + Project;
    Exit;
  end;
  if not ProjectExists(Project) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;
  if not IsSafeStateKey(Key) then
  begin
    Err := 'state keys are up to 128 chars of [A-Za-z0-9-_.:]';
    Exit;
  end;
  if Length(Value) > MaxStateValue then
  begin
    Err := 'value too large (limit ' + IntToStr(MaxStateValue div 1024) + ' KiB)';
    Exit;
  end;

  Obj := LoadState(Project);
  if Obj = nil then Obj := TJsonObject.Create;
  try
    Obj.PutStr(Key, Value);
    EnsureDir(ExtractFileDir(Path));
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
  Result := True;
end;

function StateDelete(const Project, Key: string; out Err: string): Boolean;
var
  Obj: TJsonObject;
  Path: string;
begin
  Err := '';
  Result := False;
  if not IsSafeStateKey(Key) then
  begin
    Err := 'not a valid state key';
    Exit;
  end;
  Path := StatePath(Project);
  if Path = '' then
  begin
    Err := 'not a project name: ' + Project;
    Exit;
  end;
  Obj := LoadState(Project);
  if Obj = nil then Exit(True);   { nothing stored is already deleted }
  try
    Obj.Remove(Key);
    WriteFileText(Path, Obj.ToJSON);
  finally
    Obj.Free;
  end;
  Result := True;
end;

function StateKeys(const Project: string): TStringList;
var
  Obj: TJsonObject;
begin
  Result := TStringList.Create;
  Obj := LoadState(Project);
  if Obj = nil then Exit;
  try
    Result.Free;
    Result := Obj.Keys;
  finally
    Obj.Free;
  end;
end;

{ ------------------------------------------------------------- blueprints -- }

{ Collect app/ files worth shipping: text-ish, small, and never the state
  store. Recurses one level of subdirectories (assets/, src/). }
procedure CollectFiles(const Root, Prefix: string; Files: TJsonArray;
  Depth: Integer);
var
  Rec: TSearchRec;
  Rel, Full, Body: string;
  Item: TJsonObject;
begin
  if Depth > 3 then Exit;
  if FindFirst(JoinPath(Root, '*'), faAnyFile, Rec) = 0 then
    try
      repeat
        if (Rec.Name = '.') or (Rec.Name = '..') then Continue;
        Full := JoinPath(Root, Rec.Name);
        if Prefix = '' then Rel := Rec.Name else Rel := Prefix + '/' + Rec.Name;
        if (Rec.Attr and faDirectory) <> 0 then
        begin
          CollectFiles(Full, Rel, Files, Depth + 1);
          Continue;
        end;
        { The state store is the user's data, not the app. Excluding it is
          what makes a blueprint shareable. }
        if SameText(Rel, 'state.json') then Continue;
        if Rec.Size > MaxBlueprintFile then Continue;
        if not IsServableExt(ExtractFileExt(Rec.Name)) and
           not SameText(ExtractFileExt(Rec.Name), '.py') and
           not SameText(ExtractFileExt(Rec.Name), '.pas') and
           not SameText(ExtractFileExt(Rec.Name), '.dpr') and
           not SameText(ExtractFileExt(Rec.Name), '.lpr') then
          Continue;
        Body := ReadFileText(Full);
        Item := TJsonObject.Create;
        Item.PutStr('path', Rel);
        Item.PutStr('body', Body);
        Files.AddObject(Item);
      until FindNext(Rec) <> 0;
    finally
      FindClose(Rec);
    end;
end;

function ExportBlueprint(const Project: string; out Err: string): string;
var
  Info: TProjectInfo;
  Root, Meta: TJsonObject;
  Files, Tasks: TJsonArray;
  TaskRows: TTaskInfoArray;
  TaskObj: TJsonObject;
  I: Integer;
  AppDir: string;
begin
  Err := '';
  Result := '';
  if not GetProject(Project, Info) then
  begin
    Err := 'no such project: ' + Project;
    Exit;
  end;

  Root := TJsonObject.Create;
  try
    Root.PutStr('blueprint', '1');
    Root.PutStr('name', Info.Name);
    Root.PutStr('title', Info.Title);
    Root.PutStr('description', Info.Description);
    Root.PutStr('exported', NowIsoUtc);

    Files := TJsonArray.Create;
    AppDir := ProjectAppDir(Project);
    if (AppDir <> '') and DirectoryExists(AppDir) then
      CollectFiles(AppDir, '', Files, 0);
    Root.PutArray('files', Files);

    { Task TITLES travel; their status, notes and job history do not. The
      recipient is starting this work, not inheriting someone's progress. }
    Tasks := TJsonArray.Create;
    TaskRows := ListTasks(Project);
    for I := 0 to High(TaskRows) do
    begin
      TaskObj := TJsonObject.Create;
      TaskObj.PutStr('title', TaskRows[I].Title);
      Tasks.AddObject(TaskObj);
    end;
    Root.PutArray('tasks', Tasks);

    Meta := TJsonObject.Create;
    Meta.PutStr('source_workspace_project', Info.Name);
    Root.PutObject('meta', Meta);

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function ImportBlueprint(const BlueprintJSON, PreferredName: string;
  out Err: string): string;
var
  Root: TJsonObject;
  Files, Tasks: TJsonArray;
  Item: TJsonObject;
  I: Integer;
  Slug, Title, Desc, AppDir, Rel, Full, DirNorm: string;
  Ignored: string;
begin
  Err := '';
  Result := '';
  try
    Root := TJsonObject.Parse(BlueprintJSON);
  except
    on E: Exception do
    begin
      Err := 'blueprint is not valid JSON: ' + E.Message;
      Exit;
    end;
  end;
  try
    if Root.GetStr('blueprint', '') = '' then
    begin
      Err := 'not a blueprint (missing "blueprint" version field)';
      Exit;
    end;
    Title := Root.GetStr('title', Root.GetStr('name', 'Imported App'));
    Desc  := Root.GetStr('description', '');

    Slug := PreferredName;
    if Trim(Slug) = '' then Slug := Root.GetStr('name', '');
    { An import must never overwrite an existing project -- the whole point
      of a blueprint is that the recipient gets their OWN copy. }
    Slug := SanitizeName(Slug);
    if Slug = '' then Slug := 'imported-app';
    if ProjectExists(Slug) then
    begin
      I := 2;
      while ProjectExists(Slug + '-' + IntToStr(I)) do
        Inc(I);
      Slug := Slug + '-' + IntToStr(I);
    end;

    Slug := CreateProject(Title, Slug, Desc, Err);
    if Slug = '' then Exit;

    AppDir := ProjectAppDir(Slug);
    EnsureDir(AppDir);
    DirNorm := IncludeTrailingPathDelimiter(NormalizePathSep(AppDir));

    Files := Root.ChildArray('files');
    if Files <> nil then
      for I := 0 to Files.Count - 1 do
      begin
        Item := Files.ItemObject(I);
        if Item = nil then Continue;
        Rel := Item.GetStr('path', '');
        { A blueprint is a file someone else wrote. Its paths get the same
          treatment as an HTTP request's. }
        if not IsSafeRelPath(Rel) then Continue;
        Full := JoinPath(AppDir, Rel);
        if not HasPrefix(NormalizePathSep(Full), DirNorm) then Continue;
        EnsureDir(ExtractFileDir(Full));
        WriteFileText(Full, Item.GetStr('body', ''));
      end;

    Tasks := Root.ChildArray('tasks');
    if Tasks <> nil then
      for I := 0 to Tasks.Count - 1 do
      begin
        Item := Tasks.ItemObject(I);
        if Item = nil then Continue;
        if Trim(Item.GetStr('title', '')) = '' then Continue;
        CreateTask(Slug, Item.GetStr('title', ''), '', Ignored);
      end;

    Result := Slug;
  finally
    Root.Free;
  end;
end;

end.
