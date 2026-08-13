(*
  PasClaw.Gateway.Desktop - the desktop client's HTTP surface.

  Everything the retro desktop needs: workspaces, the project/task/job board,
  app serving, the per-app state store, and answer pages. One entry point --
  DesktopRoute -- which the gateway calls before its own dispatch chain and
  which returns False for anything that isn't ours, so PasClaw.Gateway.Server
  needs exactly one new line.

  Deliberately transport-agnostic: strings in, a response record out, no Indy
  types anywhere. That is what lets desktop_routes_tests exercise every route
  (including the traversal attempts) without opening a socket.

  Two things this unit cannot do by itself -- run an agent turn, and generate
  a page -- arrive as injected callbacks (SetJobRunner / SetPageGenerator)
  that the gateway wires to its agent at startup. Unset, those routes answer
  503 with a plain explanation instead of pretending.
*)
unit PasClaw.Gateway.Desktop;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Pages;

type
  TDesktopResponse = record
    Status:      Integer;
    ContentType: string;
    Body:        string;
    { When set, the caller streams this file instead of Body -- app assets
      and page documents are served from disk. }
    FilePath:    string;
    { Extra response headers as "Name: Value" lines, e.g. the CSP an app's
      content must be served under. }
    Headers:     string;
  end;

  { Runs one agent turn against a task, returning the job id it opened.
    Wired to the gateway's agent; nil in tests and in a gateway started
    without a model. }
  TJobRunner = function(const Project, TaskId, Prompt: string;
    out JobId, Err: string): Boolean;

  (* Produces a page body + a SOURCES JSON array for a query.

     RevisePageId names an existing page when the query is a FOLLOW-UP to
     it: the generator then edits that document rather than starting a new
     topic. Empty for an ordinary question, which is the common case and
     costs nothing. *)
  TPageGenerator = function(const Query: string; Kind: TPageKind;
    const RevisePageId: string;
    out Title, BodyHTML, SourcesJSON, Err: string): Boolean;

  (* One agent turn, plain text in and out. The general-purpose sibling of
     the two above: Mail's summarise-and-draft needs a model but not a page
     and not a job, and inventing a third bespoke callback shape for every
     such feature would be the wrong trade. *)
  TTextGenerator = function(const SystemPrompt, Prompt: string;
    out Reply, Err: string): Boolean;

procedure SetJobRunner(Runner: TJobRunner);
procedure SetPageGenerator(Gen: TPageGenerator);
procedure SetTextGenerator(Gen: TTextGenerator);

(* The origin generated apps are served from. Empty (the default) means "the
   same origin as everything else", which is the simple arrangement and the
   one where an app shares storage with the desktop page. Set by the gateway
   when --apps-port spins up a separate listener; the desktop reads it from
   /v1/desktop/config and points its iframes there. *)
procedure SetAppsOrigin(const Origin: string);
function AppsOrigin: string;

{ True when Doc is a path this unit owns -- used by the gateway to decide
  whether to consult us at all (and to keep auth gating in one place). }
function IsDesktopPath(const Doc: string): Boolean;

(* True for the per-app routes an app may call FROM ITS OWN ORIGIN: its state
   store and its allowlisted read window. The apps-only listener (--apps-port)
   serves these and nothing else, so an app opened standalone on that origin
   can still persist its data without being able to reach /v1/chat, the
   project board, or the desktop's stored token. *)
function IsAppScopedPath(const Doc: string): Boolean;

{ Handle a request. Returns False when the path isn't ours. Method is
  'GET'/'POST'/'PATCH'/'DELETE'; Doc is the path with no query string;
  Query is the raw query string; Body is the request body. }
function DesktopRoute(const Method, Doc, Query, Body: string;
  out Resp: TDesktopResponse): Boolean;

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Workspaces,
  PasClaw.Projects.Store,
  PasClaw.Apps,
  PasClaw.Apps.Runner,
  PasClaw.Desktop.Events,
  PasClaw.Config,           { cron entries + provider names for the read surface }
  PasClaw.Suite.Mail,       { the mail-sync action }
  PasClaw.Suite.Notes,      { the notes surface + note-save/note-delete }
  PasClaw.Memory.Facts,     { the memory surface -- what Brain shows }
  PasClaw.Memory.Distill,   { TFact, for a fact the user types themselves }
  PasClaw.Tools.Cron,       { Tool_Cron -- Calendar schedules through it }
  PasClaw.Skills.Loader,    { the skills surface -- what Calendar may schedule }
  PasClaw.KB.Index,         { the kb surface -- Library searches it }
  PasClaw.Checkpoints,      { the checkpoints surface -- how far undo reaches }
  DateUtils,                { DateTimeToUnix }
  PasClaw.Session.Store;    { session list for the Library app }

var
  GJobRunner: TJobRunner = nil;
  GPageGen: TPageGenerator = nil;
  GTextGen: TTextGenerator = nil;
  GAppsOrigin: string = '';

procedure SetJobRunner(Runner: TJobRunner);
begin
  GJobRunner := Runner;
end;

procedure SetPageGenerator(Gen: TPageGenerator);
begin
  GPageGen := Gen;
end;

procedure SetTextGenerator(Gen: TTextGenerator);
begin
  GTextGen := Gen;
end;

procedure SetAppsOrigin(const Origin: string);
begin
  GAppsOrigin := Origin;
end;

function AppsOrigin: string;
begin
  Result := GAppsOrigin;
end;

const
  { A window layout, not a document store. Anything past this is a mistake
    or an attempt to use the gateway as one. }
  MaxDesktopState = 256 * 1024;
  { An app entry is a page or a script. Anything past this is not one. }
  MaxEntryBytes   = 2 * 1024 * 1024;

(* Desktops inside a workspace: numbered layouts, like the Linux pager --
   but INSIDE the wall, because which windows are on screen is a view and
   must never be the isolation boundary. desktop 1 is state.json (the
   pre-desktops file, so an existing layout just becomes desktop 1);
   desktop N>1 is stateN.json. desktops.json holds {current, count}. *)
const
  MaxDesktops = 9;

function DesktopMetaPath: string;
begin
  Result := JoinPath(WorkspaceSubdir('desktop'), 'desktops.json');
end;

procedure ReadDesktopMeta(out Current, Count: Integer);
var
  Obj: TJsonObject;
begin
  Current := 1;
  Count := 1;
  if not FileExists(DesktopMetaPath) then Exit;
  try
    Obj := TJsonObject.Parse(ReadFileText(DesktopMetaPath));
  except
    Exit;
  end;
  if Obj = nil then Exit;
  try
    Current := Integer(Obj.GetInt('current', 1));
    Count   := Integer(Obj.GetInt('count', 1));
  finally
    Obj.Free;
  end;
  if Count < 1 then Count := 1;
  if Count > MaxDesktops then Count := MaxDesktops;
  if (Current < 1) or (Current > Count) then Current := 1;
end;

procedure WriteDesktopMeta(Current, Count: Integer);
begin
  if EnsureDir(WorkspaceSubdir('desktop')) then
    WriteFileText(DesktopMetaPath,
      '{"current":' + IntToStr(Current) + ',"count":' + IntToStr(Count) + '}');
end;

{ Layout file for one desktop of the active workspace. 0 = the current one. }
function DesktopStatePath(N: Integer = 0): string;
var
  Cur, Cnt: Integer;
begin
  if N <= 0 then
  begin
    ReadDesktopMeta(Cur, Cnt);
    N := Cur;
  end;
  if N = 1 then
    Result := JoinPath(WorkspaceSubdir('desktop'), 'state.json')
  else
    Result := JoinPath(WorkspaceSubdir('desktop'), 'state' + IntToStr(N) + '.json');
end;

function ReadDesktopState(N: Integer; out Body: string): Boolean;
begin
  Body := '';
  Result := False;
  if not FileExists(DesktopStatePath(N)) then Exit;
  try
    Body := ReadFileText(DesktopStatePath(N));
  except
    Exit;
  end;
  Result := Trim(Body) <> '';
end;

function WriteDesktopState(N: Integer; const Body: string;
  out Err: string): Boolean;
begin
  Err := '';
  Result := False;
  if not EnsureDir(WorkspaceSubdir('desktop')) then
  begin
    Err := 'could not create the desktop directory';
    Exit;
  end;
  try
    WriteFileText(DesktopStatePath(N), Body);
  except
    on E: Exception do
    begin
      Err := 'could not write the desktop state: ' + E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

{ ---------------------------------------------------------------- helpers -- }

procedure Reply(out Resp: TDesktopResponse; Status: Integer;
  const ContentType, Body: string);
begin
  Resp.Status      := Status;
  Resp.ContentType := ContentType;
  Resp.Body        := Body;
  Resp.FilePath    := '';
  Resp.Headers     := '';
end;

procedure ReplyJSON(out Resp: TDesktopResponse; Status: Integer; const Body: string);
begin
  Reply(Resp, Status, 'application/json; charset=utf-8', Body);
end;

procedure ReplyErr(out Resp: TDesktopResponse; Status: Integer; const Msg: string);
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('error', Msg);
    ReplyJSON(Resp, Status, Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

procedure ReplyOK(out Resp: TDesktopResponse; const Extra: string = '');
var
  Obj: TJsonObject;
begin
  if Extra <> '' then
  begin
    ReplyJSON(Resp, 200, Extra);
    Exit;
  end;
  Obj := TJsonObject.Create;
  try
    Obj.PutBool('ok', True);
    ReplyJSON(Resp, 200, Obj.ToJSON);
  finally
    Obj.Free;
  end;
end;

function UrlDecode(const S: string): string;
var
  I, Code: Integer;
begin
  Result := '';
  I := 1;
  while I <= Length(S) do
  begin
    if (S[I] = '%') and (I + 2 <= Length(S)) then
    begin
      Code := StrToIntDef('$' + Copy(S, I + 1, 2), -1);
      if Code >= 0 then
      begin
        Result := Result + Chr(Code);
        Inc(I, 3);
        Continue;
      end;
    end;
    if S[I] = '+' then
      Result := Result + ' '
    else
      Result := Result + S[I];
    Inc(I);
  end;
end;

function QueryValue(const Query, Key: string): string;
var
  Parts: TStringList;
  I, P: Integer;
  K: string;
begin
  Result := '';
  if Query = '' then Exit;
  Parts := SplitToList(Query, '&');
  try
    for I := 0 to Parts.Count - 1 do
    begin
      P := Pos('=', Parts[I]);
      if P <= 0 then Continue;
      K := Copy(Parts[I], 1, P - 1);
      if SameText(K, Key) then
        Exit(UrlDecode(Copy(Parts[I], P + 1, MaxInt)));
    end;
  finally
    Parts.Free;
  end;
end;

{ Split a path into its '/' segments, URL-decoded. }
function PathSegments(const Doc: string): TStringList;
var
  Raw: TStringList;
  I: Integer;
begin
  Result := TStringList.Create;
  Raw := SplitToList(Doc, '/');
  try
    for I := 0 to Raw.Count - 1 do
      if Raw[I] <> '' then
        Result.Add(UrlDecode(Raw[I]));
  finally
    Raw.Free;
  end;
end;

{ '-' is the store's "leave this field alone" sentinel; an absent JSON key
  must not clear text the user wrote. }
function FieldOrKeep(Obj: TJsonObject; const Key: string): string;
begin
  if (Obj <> nil) and Obj.Has(Key) then
    Result := Obj.GetStr(Key, '')
  else
    Result := '-';
end;

{ A string field from an optional body object -- '' when either is absent. }
function IfEmpty(Obj: TJsonObject; const Key: string): string;
begin
  if Obj = nil then Result := '' else Result := Trim(Obj.GetStr(Key, ''));
end;

function BodyObj(const Body: string): TJsonObject;
begin
  Result := nil;
  if Trim(Body) = '' then Exit;
  try
    Result := TJsonObject.Parse(Body);
  except
    Result := nil;
  end;
end;

{ ------------------------------------------------------------- serialisers -- }

function WorkspaceJSON(const W: TWorkspaceInfo): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',     W.Name);
  Result.PutInt ('slot',     W.Slot);
  Result.PutStr ('label',    W.Label_);
  Result.PutBool('active',   W.Active);
  Result.PutInt ('projects', W.Projects);
end;

function ProjectJSON(const P: TProjectInfo): TJsonObject;
var
  App: TAppInfo;
begin
  Result := TJsonObject.Create;
  Result.PutStr ('name',        P.Name);
  Result.PutStr ('title',       P.Title);
  Result.PutStr ('description', P.Description);
  Result.PutStr ('created',     P.Created);
  Result.PutStr ('updated',     P.Updated);
  Result.PutStr ('icon',        P.Icon);
  Result.PutBool('suite',       P.Suite);
  Result.PutBool('has_app',     P.HasApp);
  Result.PutInt ('tasks',       P.TaskCount);
  Result.PutInt ('open_tasks',  P.OpenTasks);
  { The desktop needs the app's kind and window size to open a window without
    a second round trip. }
  if P.HasApp and GetApp(P.Name, App) and App.Exists then
  begin
    Result.PutStr('app_kind', AppKindToStr(App.Kind));
    Result.PutInt('app_width', App.Width);
    Result.PutInt('app_height', App.Height);
    Result.PutBool('app_ready', App.EntryExists);
  end;
end;

function TaskJSON(const T: TTaskInfo): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',      T.Id);
  Result.PutStr('project', T.Project);
  Result.PutStr('title',   T.Title);
  Result.PutStr('status',  TaskStatusToStr(T.Status));
  Result.PutStr('notes',   T.Notes);
  Result.PutStr('created', T.Created);
  Result.PutStr('updated', T.Updated);
  Result.PutInt('jobs',    T.JobCount);
end;

function JobJSON(const J: TJobInfo): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',         J.Id);
  Result.PutStr('project',    J.Project);
  Result.PutStr('task',       J.Task);
  Result.PutStr('status',     JobStatusToStr(J.Status));
  Result.PutStr('session_id', J.SessionId);
  Result.PutStr('started',    J.Started);
  Result.PutStr('ended',      J.Ended);
  Result.PutStr('summary',    J.Summary);
end;

function PageJSON(const P: TPageInfo): TJsonObject;
var
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',      P.Id);
  Result.PutStr('title',   P.Title);
  Result.PutStr('query',   P.Query);
  Result.PutStr('kind',    PageKindToStr(P.Kind));
  Result.PutStr('created', P.Created);
  Result.PutStr('url',     '/pages/' + P.Id + '/');
  Arr := TJsonArray.Create;
  for I := 0 to High(P.Sources) do
  begin
    Item := TJsonObject.Create;
    Item.PutStr('title', P.Sources[I].Title);
    Item.PutStr('url',   P.Sources[I].URL);
    Arr.AddObject(Item);
  end;
  Result.PutArray('sources', Arr);
  Result.PutInt('source_count', Length(P.Sources));
end;

{ --------------------------------------------------------------- routing -- }

function IsAppScopedPath(const Doc: string): Boolean;
var
  Segs: TStringList;
  Tail: string;
begin
  Result := False;
  if not HasPrefix(Doc, '/v1/apps/') then Exit;
  Segs := PathSegments(Doc);
  try
    { v1 / apps / <project> / (state|read) [/ <key>] -- the manifest route
      (3 segments) is deliberately NOT included: it carries the declared
      permissions and window geometry, which is desktop business. }
    if Segs.Count < 4 then Exit;
    Tail := LowerCase(Segs[3]);
    Result := (Tail = 'state') or (Tail = 'read') or (Tail = 'action');
  finally
    Segs.Free;
  end;
end;

function IsDesktopPath(const Doc: string): Boolean;
begin
  Result := (Doc = '/v1/desktop/config')
         or (Doc = '/v1/desktop/state')
         or (Doc = '/v1/desktop/desktops')
         or HasPrefix(Doc, '/v1/workspaces')
         or HasPrefix(Doc, '/v1/projects')
         or HasPrefix(Doc, '/v1/apps')
         or HasPrefix(Doc, '/v1/pages')
         or HasPrefix(Doc, '/apps/')
         or HasPrefix(Doc, '/pages/');
end;

{ ---- /v1/workspaces ---- }

function RouteWorkspaces(const Method, Doc, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  List: TWorkspaceInfoArray;
  I: Integer;
  Obj: TJsonObject;
  Name_, Err: string;
begin
  Result := True;

  if (Method = 'GET') and (Doc = '/v1/workspaces') then
  begin
    Root := TJsonObject.Create;
    try
      Arr := TJsonArray.Create;
      List := ListWorkspaces;
      for I := 0 to High(List) do
      begin
        Item := WorkspaceJSON(List[I]);
        Arr.AddObject(Item);
      end;
      Root.PutArray('workspaces', Arr);
      Root.PutStr('active', ActiveWorkspaceName);
      ReplyJSON(Resp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
    Exit;
  end;

  if (Method = 'POST') and (Doc = '/v1/workspaces') then
  begin
    Obj := BodyObj(Body);
    try
      Name_ := '';
      if Obj <> nil then Name_ := Obj.GetStr('label', '');
      Name_ := CreateWorkspace(Name_);
      Root := TJsonObject.Create;
      try
        Root.PutStr('name', Name_);
        Root.PutStr('label', WorkspaceLabel(Name_));
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  if (Method = 'POST') and (Doc = '/v1/workspaces/activate') then
  begin
    Obj := BodyObj(Body);
    try
      if Obj = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body with "name"');
        Exit;
      end;
      Name_ := Obj.GetStr('name', '');
      if not SetActiveWorkspace(Name_, Err) then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('active', ActiveWorkspaceName);
        { A non-fatal warning (the env var outranks config) still needs to
          reach the user, or the switch looks like it silently failed. }
        if Err <> '' then Root.PutStr('warning', Err);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  Result := False;
end;

{ ---- /v1/projects... ---- }

function RouteProjectCollection(const Method, Doc, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  List: TProjectInfoArray;
  I: Integer;
  Obj: TJsonObject;
  Slug, Err: string;
begin
  Result := True;

  if (Method = 'GET') and (Doc = '/v1/projects') then
  begin
    Root := TJsonObject.Create;
    try
      Arr := TJsonArray.Create;
      List := ListProjects;
      for I := 0 to High(List) do
      begin
        Item := ProjectJSON(List[I]);
        Arr.AddObject(Item);
      end;
      Root.PutArray('projects', Arr);
      Root.PutStr('workspace', ActiveWorkspaceName);
      ReplyJSON(Resp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
    Exit;
  end;

  if (Method = 'POST') and (Doc = '/v1/projects') then
  begin
    Obj := BodyObj(Body);
    try
      if Obj = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body with "title"');
        Exit;
      end;
      Slug := CreateProject(Obj.GetStr('title', ''), Obj.GetStr('name', ''),
                            Obj.GetStr('description', ''), Err);
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('name', Slug);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  if (Method = 'POST') and (Doc = '/v1/projects/import') then
  begin
    Obj := BodyObj(Body);
    try
      if Obj = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body with "blueprint"');
        Exit;
      end;
      { The blueprint may arrive as an object or as a JSON string holding
        one -- both are natural for a client pasting an export. }
      Slug := Obj.GetStr('blueprint', '');
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, 'body needs a "blueprint" string');
        Exit;
      end;
      Slug := ImportBlueprint(Slug, Obj.GetStr('name', ''), Err);
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('name', Slug);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Obj.Free;
    end;
    Exit;
  end;

  Result := False;
end;

function RouteJobs(const Method, Project, TaskId: string; Segs: TStringList;
  const Body: string; out Resp: TDesktopResponse): Boolean;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  List: TJobInfoArray;
  I: Integer;
  Obj: TJsonObject;
  JobId, Err, Status, Summary, Session: string;
  Info: TJobInfo;
begin
  Result := True;

  { /v1/projects/<p>/tasks/<t>/jobs -- segments:
      0:v1 1:projects 2:<project> 3:tasks 4:<taskid> 5:jobs 6:<jobid> 7:log }
  if Segs.Count = 6 then
  begin
    if Method = 'GET' then
    begin
      Root := TJsonObject.Create;
      try
        Arr := TJsonArray.Create;
        List := ListJobs(Project, TaskId);
        for I := 0 to High(List) do
        begin
          Item := JobJSON(List[I]);
          Arr.AddObject(Item);
        end;
        Root.PutArray('jobs', Arr);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;
    if Method = 'POST' then
    begin
      Obj := BodyObj(Body);
      try
        if Obj <> nil then Session := Obj.GetStr('session_id', '') else Session := '';
        JobId := CreateJob(Project, TaskId, Session, Err);
        if JobId = '' then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        Root := TJsonObject.Create;
        try
          Root.PutStr('id', JobId);
          ReplyJSON(Resp, 200, Root.ToJSON);
        finally
          Root.Free;
        end;
      finally
        Obj.Free;
      end;
      Exit;
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;

  { /v1/projects/<p>/tasks/<t>/jobs/<j>[/log] }
  if Segs.Count >= 7 then
  begin
    JobId := Segs[6];
    if (Segs.Count = 8) and (LowerCase(Segs[7]) = 'log') and (Method = 'GET') then
    begin
      Root := TJsonObject.Create;
      try
        Root.PutStr('log', ReadJobLog(Project, TaskId, JobId));
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;
    if Segs.Count <> 7 then
    begin
      ReplyErr(Resp, 404, 'no such route');
      Exit;
    end;
    if Method = 'GET' then
    begin
      if not GetJob(Project, TaskId, JobId, Info) then
      begin
        ReplyErr(Resp, 404, 'no such job');
        Exit;
      end;
      Item := JobJSON(Info);
      try
        ReplyJSON(Resp, 200, Item.ToJSON);
      finally
        Item.Free;
      end;
      Exit;
    end;
    if Method = 'PATCH' then
    begin
      Obj := BodyObj(Body);
      try
        Status := ''; Summary := '-';
        if Obj <> nil then
        begin
          Status := Obj.GetStr('status', '');
          if Obj.Has('summary') then Summary := Obj.GetStr('summary', '');
        end;
        if not UpdateJob(Project, TaskId, JobId, Status, Summary, '-', Err) then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        ReplyOK(Resp);
      finally
        Obj.Free;
      end;
      Exit;
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;

  Result := False;
end;

function RouteTasks(const Method, Project: string; Segs: TStringList;
  const Body: string; out Resp: TDesktopResponse): Boolean;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  List: TTaskInfoArray;
  I: Integer;
  Obj: TJsonObject;
  TaskId, Err, Title, Notes, Status, JobId, Prompt: string;
  Info: TTaskInfo;
begin
  Result := True;

  { /v1/projects/<p>/tasks }
  if Segs.Count = 4 then
  begin
    if Method = 'GET' then
    begin
      Root := TJsonObject.Create;
      try
        Arr := TJsonArray.Create;
        List := ListTasks(Project);
        for I := 0 to High(List) do
        begin
          Item := TaskJSON(List[I]);
          Arr.AddObject(Item);
        end;
        Root.PutArray('tasks', Arr);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;
    if Method = 'POST' then
    begin
      Obj := BodyObj(Body);
      try
        if Obj = nil then
        begin
          ReplyErr(Resp, 400, 'expected a JSON body with "title"');
          Exit;
        end;
        TaskId := CreateTask(Project, Obj.GetStr('title', ''),
                             Obj.GetStr('notes', ''), Err);
        if TaskId = '' then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        Root := TJsonObject.Create;
        try
          Root.PutStr('id', TaskId);
          ReplyJSON(Resp, 200, Root.ToJSON);
        finally
          Root.Free;
        end;
      finally
        Obj.Free;
      end;
      Exit;
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;

  TaskId := Segs[4];

  { /v1/projects/<p>/tasks/<t>/jobs... }
  if (Segs.Count >= 6) and (LowerCase(Segs[5]) = 'jobs') then
  begin
    Result := RouteJobs(Method, Project, TaskId, Segs, Body, Resp);
    Exit;
  end;

  { /v1/projects/<p>/tasks/<t>/run -- start an agent turn on this task. }
  if (Segs.Count = 6) and (LowerCase(Segs[5]) = 'run') and (Method = 'POST') then
  begin
    if not Assigned(GJobRunner) then
    begin
      ReplyErr(Resp, 503,
        'this gateway has no agent attached, so it cannot run jobs');
      Exit;
    end;
    Obj := BodyObj(Body);
    try
      Prompt := '';
      if Obj <> nil then Prompt := Obj.GetStr('prompt', '');
    finally
      Obj.Free;
    end;
    if not GJobRunner(Project, TaskId, Prompt, JobId, Err) then
    begin
      ReplyErr(Resp, 400, Err);
      Exit;
    end;
    Root := TJsonObject.Create;
    try
      Root.PutStr('job', JobId);
      ReplyJSON(Resp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
    Exit;
  end;

  { /v1/projects/<p>/tasks/<t> }
  if Segs.Count = 5 then
  begin
    if Method = 'GET' then
    begin
      if not GetTask(Project, TaskId, Info) then
      begin
        ReplyErr(Resp, 404, 'no such task');
        Exit;
      end;
      Item := TaskJSON(Info);
      try
        ReplyJSON(Resp, 200, Item.ToJSON);
      finally
        Item.Free;
      end;
      Exit;
    end;
    if Method = 'PATCH' then
    begin
      Obj := BodyObj(Body);
      try
        Title := ''; Notes := '-'; Status := '';
        if Obj <> nil then
        begin
          Title  := Obj.GetStr('title', '');
          Status := Obj.GetStr('status', '');
          if Obj.Has('notes') then Notes := Obj.GetStr('notes', '');
        end;
        if not UpdateTask(Project, TaskId, Title, Notes, Status, Err) then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        ReplyOK(Resp);
      finally
        Obj.Free;
      end;
      Exit;
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;

  ReplyErr(Resp, 404, 'no such route');
end;

function RouteProjectItem(const Method, Doc, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Project, Err, Blueprint: string;
  Info: TProjectInfo;
  Item, Obj, Root: TJsonObject;
begin
  Result := True;
  Segs := PathSegments(Doc);
  try
    { segments: v1 / projects / <name> / ... }
    if Segs.Count < 3 then
    begin
      Result := False;
      Exit;
    end;
    Project := Segs[2];

    { A name that isn't a safe slug can never match anything on disk; say so
      as a 404 rather than letting it reach a path join. }
    if not IsSafeName(Project) then
    begin
      ReplyErr(Resp, 404, 'no such project');
      Exit;
    end;

    if (Segs.Count = 4) and (LowerCase(Segs[3]) = 'blueprint') and (Method = 'GET') then
    begin
      Blueprint := ExportBlueprint(Project, Err);
      if Blueprint = '' then
      begin
        ReplyErr(Resp, 404, Err);
        Exit;
      end;
      ReplyJSON(Resp, 200, Blueprint);
      Exit;
    end;

    if (Segs.Count >= 4) and (LowerCase(Segs[3]) = 'tasks') then
    begin
      if not ProjectExists(Project) then
      begin
        ReplyErr(Resp, 404, 'no such project');
        Exit;
      end;
      Result := RouteTasks(Method, Project, Segs, Body, Resp);
      Exit;
    end;

    if Segs.Count <> 3 then
    begin
      ReplyErr(Resp, 404, 'no such route');
      Exit;
    end;

    if Method = 'GET' then
    begin
      if not GetProject(Project, Info) then
      begin
        ReplyErr(Resp, 404, 'no such project');
        Exit;
      end;
      Item := ProjectJSON(Info);
      try
        ReplyJSON(Resp, 200, Item.ToJSON);
      finally
        Item.Free;
      end;
      Exit;
    end;

    if Method = 'PATCH' then
    begin
      Obj := BodyObj(Body);
      try
        Root := nil;
        if Obj = nil then
        begin
          ReplyErr(Resp, 400, 'expected a JSON body');
          Exit;
        end;
        if not UpdateProject(Project, Obj.GetStr('title', ''),
             FieldOrKeep(Obj, 'description'),
             FieldOrKeep(Obj, 'icon'), Err) then
        begin
          ReplyErr(Resp, 404, Err);
          Exit;
        end;
        ReplyOK(Resp);
      finally
        Obj.Free;
      end;
      Exit;
    end;

    if Method = 'DELETE' then
    begin
      if not DeleteProject(Project, Err) then
      begin
        ReplyErr(Resp, 404, Err);
        Exit;
      end;
      ReplyOK(Resp);
      Exit;
    end;

    ReplyErr(Resp, 405, 'method not allowed');
  finally
    Segs.Free;
  end;
end;

{ ---- /v1/apps + /apps ---- }

(* Open the fact store the AGENT uses and hand back its active facts.

   Note the path: DefaultFactsDbPath(GetHome), which resolves to
   <home>/workspace/memory/facts.db regardless of the active workspace.
   That is a pre-existing wart -- distilled facts are the one part of the
   agent's state that Phase 1 did not make workspace-scoped -- and Brain
   deliberately inherits it rather than routing through WorkspaceSubdir.
   Showing workspace2's facts while the model is primed with workspace1's
   would be a prettier lie than the one we are here to fix. When facts
   become per-workspace, this follows for free. *)
function ActiveFacts_(const Today: string): TStoredFactArray;
var
  Store: IFactStore;
begin
  SetLength(Result, 0);
  Store := NewFactStore;
  { No store yet is the normal state of a fresh install, not an error: the
    file appears the first time distillation runs. Brain shows an empty
    Rolodex and says so. }
  if not Store.Open(DefaultFactsDbPath(GetHome)) then Exit;
  try
    Result := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;
end;

{ Forget one. Supersede rather than Delete: the fact stops being active (so
  it leaves the prompt, which is what the user asked for) but the row
  survives, so "why did it stop knowing that" is answerable later. }
function ForgetFact(Id: Int64): Boolean;
var
  Store: IFactStore;
begin
  Result := False;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then Exit;
  try
    Result := Store.Supersede(Id);
  finally
    Store.Close;
  end;
end;

(* Remember one, typed by the user rather than distilled from a transcript.

   scope=user, kind=static, confidence=1.0: the user said it themselves, so
   it is not a guess about them and it does not decay. Distillation's job is
   inferring facts; this is the user stating one, and the store should not
   treat the two the same. *)
function RememberFact(const Text: string): Boolean;
var
  Store: IFactStore;
  F: TFact;
begin
  Result := False;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then Exit;
  try
    F.Text          := Text;
    F.Kind          := 'static';
    F.Scope         := 'user';
    F.Confidence    := 1.0;
    F.EventDate     := '';
    F.Expires       := '';
    F.SourceSession := 'brain';
    Result := Store.Add(F, DateTimeToUnix(Now, False)) > 0;
  finally
    Store.Close;
  end;
end;

(* The allowlisted read surfaces. Each is a small projection built here from
   a store this unit already depends on -- deliberately NOT a proxy to the
   gateway's own handlers, because a proxy would inherit whatever those
   handlers ever start returning. Adding a surface has to be a deliberate
   edit to this function. *)
function ReadSurface(const Project, Surface, Query: string;
  out Resp: TDesktopResponse): Boolean;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  Cfg: TConfig;
  I: Integer;
  Metas: TSessionMetaArray;
  Pages_: TPageInfoArray;
  Projs: TProjectInfoArray;
  Facts: TStoredFactArray;
  Notes_: TNoteInfoArray;
  Skills_: TSkillSpecArray;
  Tasks_: TTaskInfoArray;
  KB: IKBIndex;
  Hits: TKBHitArray;
  Srcs: TKBSourceArray;
  Q: string;
  OldestTurn, NewestTurn: Integer;
begin
  Result := True;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;

    if Surface = 'cron' then
    begin
      Cfg := LoadConfig;
      for I := 0 to High(Cfg.Crons) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr ('id',      Cfg.Crons[I].Id);
        Item.PutStr ('spec',    Cfg.Crons[I].Spec);
        Item.PutStr ('skill',   Cfg.Crons[I].Skill);
        Item.PutStr ('args',    Cfg.Crons[I].Args);
        Item.PutBool('enabled', Cfg.Crons[I].Enabled);
        Arr.AddObject(Item);
      end;
    end
    else if Surface = 'sessions' then
    begin
      Metas := ListSessions(False);
      for I := 0 to High(Metas) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr('id',       Metas[I].Id);
        Item.PutStr('title',    Metas[I].Title);
        Item.PutStr('model',    Metas[I].Model);
        Item.PutStr('provider', Metas[I].Provider);
        Item.PutInt('updated',  Metas[I].UpdatedAt);
        Arr.AddObject(Item);
      end;
    end
    else if Surface = 'providers' then
    begin
      { Names and models only. An api_key must never leave the server, and
        the surface that cannot carry it is the one that never will. }
      Cfg := LoadConfig;
      for I := 0 to High(Cfg.Providers) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr ('name',  Cfg.Providers[I].Name);
        Item.PutStr ('kind',  Cfg.Providers[I].Kind);
        Item.PutStr ('model', Cfg.Providers[I].Model);
        Item.PutBool('has_key', Trim(Cfg.Providers[I].APIKey) <> '');
        Arr.AddObject(Item);
      end;
      Root.PutStr('default', Cfg.DefaultProvider);
      Root.PutStr('default_model', Cfg.DefaultModel);
    end
    else if Surface = 'pages' then
    begin
      Pages_ := ListPages;
      for I := 0 to High(Pages_) do
      begin
        Item := PageJSON(Pages_[I]);
        Arr.AddObject(Item);
      end;
    end
    else if Surface = 'projects' then
    begin
      Projs := ListProjects;
      for I := 0 to High(Projs) do
      begin
        Item := ProjectJSON(Projs[I]);
        Arr.AddObject(Item);
      end;
    end
    (* memory -- the distilled facts the agent carries into every turn.

       This is what makes the Brain app honest. Without it Brain shows what
       you typed into Brain, which is a notepad wearing the word "memory".
       With it, the cards on screen ARE the block the model is primed with,
       so tearing one up changes what the assistant knows.

       Active facts only: a superseded or expired fact is not in the prompt,
       so showing it would misrepresent what PasClaw currently believes. *)
    else if Surface = 'memory' then
    begin
      Facts := ActiveFacts_(FormatDateTime('yyyy-mm-dd', Now));
      for I := 0 to High(Facts) do
      begin
        Item := TJsonObject.Create;
        Item.PutInt('id',         Facts[I].Id);
        Item.PutStr('text',       Facts[I].Text);
        Item.PutStr('kind',       Facts[I].Kind);
        Item.PutStr('scope',      Facts[I].Scope);
        Item.PutStr('event_date', Facts[I].EventDate);
        Item.PutStr('expires',    Facts[I].Expires);
        Item.PutStr('source',     Facts[I].SourceSession);
        Arr.AddObject(Item);
      end;
    end
    (* notes -- markdown files under <workspace>/memory/notes.

       Deliberately a surface rather than app state: a note written here is
       a file in the directory the memory index walks, so it is searchable
       by the agent the moment it is saved. That is the entire point of
       moving Notes out of the state store. *)
    else if Surface = 'notes' then
    begin
      Notes_ := ListNotes;
      for I := 0 to High(Notes_) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr('name',     Notes_[I].Name);
        Item.PutStr('title',    Notes_[I].Title);
        Item.PutStr('body',     Notes_[I].Body);
        Item.PutStr('modified', Notes_[I].Modified);
        Arr.AddObject(Item);
      end;
    end
    (* skills -- what can actually be scheduled.

       Calendar needs this to offer a choice rather than a text box: a cron
       entry naming a skill that isn't installed is an entry that silently
       never fires, and a normal person has no way to find that out. Name
       and description only; the shell command and prompt body stay out of
       an app's reach. *)
    else if Surface = 'skills' then
    begin
      Skills_ := LoadSkillManifests(GetHome);
      for I := 0 to High(Skills_) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr('name',        Skills_[I].Name);
        Item.PutStr('description', Skills_[I].Description);
        Item.PutStr('kind',        Skills_[I].Kind);
        Arr.AddObject(Item);
      end;
    end
    (* tasks -- the board, scoped to the app that asked.

       Note the Project argument: unlike the other surfaces this one is not
       global, and a to-do app must not be able to read another project's
       task list by naming it. The scoping comes from the route, which knows
       which app is calling; the app never gets to say. *)
    else if Surface = 'tasks' then
    begin
      Tasks_ := ListTasks(Project);
      for I := 0 to High(Tasks_) do
      begin
        Item := TaskJSON(Tasks_[I]);
        Arr.AddObject(Item);
      end;
    end
    (* kb -- the knowledgebase, searched.

       The only surface that takes an argument, because a knowledgebase
       listing is useless and a knowledgebase search is the whole point.
       Empty query returns the sources and the counts, which is what the
       Library shows before you type anything. *)
    else if Surface = 'kb' then
    begin
      Q := Trim(QueryValue(Query, 'q'));
      KB := NewKBIndex;
      if KB.Open(DefaultKBDbPath) then
      try
        if Q <> '' then
        begin
          Hits := KB.Search(Q, 20);
          for I := 0 to High(Hits) do
          begin
            Item := TJsonObject.Create;
            Item.PutStr('path',  Hits[I].Path);
            Item.PutStr('text',  Copy(Hits[I].Snippet, 1, 600));
            Item.PutInt('chunk', Hits[I].ChunkNo);
            Arr.AddObject(Item);
          end;
        end
        else
        begin
          Srcs := KB.GetSources;
          for I := 0 to High(Srcs) do
          begin
            Item := TJsonObject.Create;
            Item.PutStr('path', Srcs[I].Root);
            Item.PutStr('text', Format('%d file(s), %d chunk(s) indexed',
                                       [Srcs[I].Files, Srcs[I].Chunks]));
            Item.PutInt('chunk', 0);
            Arr.AddObject(Item);
          end;
        end;
      finally
        KB.Close;
      end;
      { No kb.db is the normal state of an install that has never run
        `pasclaw kb add`, so an empty list is the honest answer, not a 500. }
    end
    (* checkpoints -- how far back the undo goes.

       Not a file list: checkpoints are per-turn snapshots, so what a person
       wants to know is "can I still get back to before this went wrong",
       and that is a range and a backend, not rows. *)
    else if Surface = 'checkpoints' then
    begin
      Item := TJsonObject.Create;
      Item.PutBool('enabled', CheckpointsEnabled);
      Item.PutInt ('turns',   CountSnapshottedTurns(OldestTurn, NewestTurn));
      Item.PutInt ('oldest',  OldestTurn);
      Item.PutInt ('newest',  NewestTurn);
      Item.PutBool('can_redo', CanRedo);
      Arr.AddObject(Item);
    end
    else
    begin
      Arr.Free;
      ReplyErr(Resp, 404, 'no such surface: ' + Surface +
               ' (cron, sessions, providers, pages, projects, memory, notes,' +
               ' skills, tasks, kb, checkpoints)');
      Exit;
    end;

    Root.PutArray('items', Arr);
    Root.PutStr('surface', Surface);
    ReplyJSON(Resp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

(* The allowlisted actions: how a sandboxed app asks for a side effect.

   Every entry is a pair -- an action name AND the project allowed to run
   it. The pairing is the security property, not the name list: without it
   any app could drive `memory-forget` or `note-save` and edit what the
   assistant remembers. Widening this is a deliberate edit, never an
   emergent one.

   Body is the raw request body, so an action can take an argument. It is
   attacker-controlled text from a sandboxed frame; each handler parses
   what it needs and validates it itself. *)
function RunAppAction(const Project, Action, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Root, Arg: TJsonObject;
  Filed: Integer;
  Err, Slug, Out_: string;
begin
  Result := True;

  (* Brain: forget a fact. The premise of the Rolodex metaphor is that
     tearing up a card actually does something, so this has to reach the
     store the model is primed from -- not a copy of it. *)
  if (Action = 'memory-forget') or (Action = 'memory-remember') then
  begin
    if Project <> 'brain' then
    begin
      ReplyErr(Resp, 404, Action + ' belongs to the brain app');
      Exit;
    end;
    if Action = 'memory-remember' then
    begin
      Arg := BodyObj(Body);
      try
        if (Arg = nil) or (Trim(Arg.GetStr('text', '')) = '') then
        begin
          ReplyErr(Resp, 400, 'remember what? send {"text": "..."}');
          Exit;
        end;
        if not RememberFact(Trim(Arg.GetStr('text', ''))) then
        begin
          { No fact store means memory has never been provisioned here.
            Say that rather than "failed" -- it is a setup state with a
            known fix, not a malfunction. }
          ReplyErr(Resp, 503, 'no fact store yet (run: pasclaw memory provision)');
          Exit;
        end;
        ReplyOK(Resp);
      finally
        Arg.Free;
      end;
      Exit;
    end;
    Arg := BodyObj(Body);
    try
      if (Arg = nil) or (Arg.GetInt('id', 0) <= 0) then
      begin
        ReplyErr(Resp, 400, 'which fact? send {"id": <n>}');
        Exit;
      end;
      if not ForgetFact(Arg.GetInt('id', 0)) then
      begin
        ReplyErr(Resp, 404, 'no such fact');
        Exit;
      end;
      ReplyOK(Resp);
    finally
      Arg.Free;
    end;
    Exit;
  end;

  (* Notes: write and delete markdown under <workspace>/memory/notes.

     This is the only action that puts app-authored text on disk in the
     directory the memory index walks, which is exactly the point -- and
     exactly why the slug is derived server-side by SaveNote rather than
     taken from the request. The app names a note; it never names a file. *)
  if (Action = 'note-save') or (Action = 'note-delete') then
  begin
    if Project <> 'notes' then
    begin
      ReplyErr(Resp, 404, Action + ' belongs to the notes app');
      Exit;
    end;
    Arg := BodyObj(Body);
    try
      if Arg = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body');
        Exit;
      end;
      if Action = 'note-delete' then
      begin
        if not DeleteNote(Arg.GetStr('name', ''), Err) then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        ReplyOK(Resp);
        Exit;
      end;
      Slug := SaveNote(Arg.GetStr('name', ''), Arg.GetStr('title', ''),
                       Arg.GetStr('body', ''), Err);
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('name', Slug);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Arg.Free;
    end;
    Exit;
  end;

  (* Calendar: schedule and unschedule agent work.

     This delegates to Tool_Cron -- the same handler the model's `cron` tool
     uses -- rather than editing config.json here. One implementation means
     the spec validation, the skill-must-exist check, and the raw-JSON edit
     (which deliberately avoids baking an active profile's resolved values
     into the file) are the ones already tested by test-cron-tool.

     Note it calls the HANDLER, not the registered tool. `cron_tool_enabled`
     gates whether the MODEL may schedule work unprompted; a person clicking
     a button in their own calendar is a different actor asking a different
     question, and gating the user behind a switch meant for the agent would
     be a category error. *)
  if (Action = 'cron-add') or (Action = 'cron-remove') then
  begin
    if Project <> 'calendar' then
    begin
      ReplyErr(Resp, 404, Action + ' belongs to the calendar app');
      Exit;
    end;
    Arg := BodyObj(Body);
    try
      if Arg = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body');
        Exit;
      end;
      { Rebuild the tool's argument object rather than forwarding the body:
        the app names three fields and gets exactly three fields, so it
        cannot smuggle a fourth (a channel target, say) into a handler that
        would honour it. }
      Root := TJsonObject.Create;
      try
        if Action = 'cron-add' then
        begin
          Root.PutStr('action', 'add');
          Root.PutStr('spec',   Arg.GetStr('spec', ''));
          Root.PutStr('skill',  Arg.GetStr('skill', ''));
          Root.PutStr('args',   Arg.GetStr('args', ''));
        end
        else
        begin
          Root.PutStr('action', 'remove');
          Root.PutStr('id',     Arg.GetStr('id', ''));
        end;
        Out_ := Tool_Cron(Root.ToJSON, Err);
      finally
        Root.Free;
      end;
      if Err <> '' then
      begin
        { The tool's own message names what was wrong -- a malformed spec, a
          skill that isn't installed. Pass it through rather than replacing
          it with something vaguer. }
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('result', Out_);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Arg.Free;
    end;
    Exit;
  end;

  (* To Do: the user's list and the agent's board are the same board.

     A task created here is an ordinary task in the todo project -- it shows
     in the desktop tree, the agent can see it, and closing it closes the
     same record. That unification is the plan's point; a private list in
     app state would have been easier and would have meant nothing. *)
  if (Action = 'task-add') or (Action = 'task-done') then
  begin
    if Project <> 'todo' then
    begin
      ReplyErr(Resp, 404, Action + ' belongs to the to-do app');
      Exit;
    end;
    Arg := BodyObj(Body);
    try
      if Arg = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body');
        Exit;
      end;
      if Action = 'task-add' then
      begin
        Slug := CreateTask('todo', Arg.GetStr('title', ''),
                           Arg.GetStr('notes', ''), Err);
        if Slug = '' then
        begin
          ReplyErr(Resp, 400, Err);
          Exit;
        end;
        Root := TJsonObject.Create;
        try
          Root.PutStr('id', Slug);
          ReplyJSON(Resp, 200, Root.ToJSON);
        finally
          Root.Free;
        end;
        Exit;
      end;
      if not UpdateTask('todo', Arg.GetStr('id', ''), '-', '-',
                        Arg.GetStr('status', 'done'), Err) then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      ReplyOK(Resp);
    finally
      Arg.Free;
    end;
    Exit;
  end;

  (* Mail: summarise a message and draft a reply.

     The half of Mail that was missing. Triage is a keyword pass and costs
     nothing; this costs a model call, so it is per-message and on demand --
     a button, not a timer.

     NOTHING IS SENT. The draft lands in the app for the user to read, edit
     and send themselves from their own mail client. Sending would need SMTP
     credentials, a consent gesture, and an undo -- and a feature that
     quietly acquires the ability to email people on your behalf is not a
     feature anyone asked for. The email channel is where "PasClaw answers
     your mail" lives, deliberately behind its own configuration. *)
  if Action = 'mail-draft' then
  begin
    if Project <> MailProject then
    begin
      ReplyErr(Resp, 404, 'mail-draft belongs to the mail app');
      Exit;
    end;
    if not Assigned(GTextGen) then
    begin
      ReplyErr(Resp, 503, 'this gateway has no model configured');
      Exit;
    end;
    Arg := BodyObj(Body);
    try
      if Arg = nil then
      begin
        ReplyErr(Resp, 400, 'expected a JSON body');
        Exit;
      end;
      Slug := Trim(Arg.GetStr('subject', ''));
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, 'which message? send its subject');
        Exit;
      end;
      if not GTextGen(
        'You are helping someone work through their inbox. Answer in ' +
        'exactly two parts and nothing else:'#10 +
        'SUMMARY: one sentence saying what this message wants.'#10 +
        'DRAFT: a short reply they could send, in their voice, plain text, ' +
        'no greeting boilerplate beyond what a colleague would write.'#10#10 +
        'If the message does not warrant a reply, say so in the DRAFT ' +
        'rather than inventing one. If the excerpt is too thin to work ' +
        'from, say that too -- a confident draft written from a subject ' +
        'line is worse than an admission.',
        'From: ' + Arg.GetStr('from', '') + #10 +
        'Subject: ' + Slug + #10#10 +
        Arg.GetStr('excerpt', '(no body text was captured)'),
        Out_, Err) then
      begin
        ReplyErr(Resp, 502, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('text', Out_);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      Arg.Free;
    end;
    Exit;
  end;

  if Action = 'mail-sync' then
  begin
    { Scoped to the Mail app: any other project asking to fill the mail store
      would be writing into somebody else's app. }
    if Project <> MailProject then
    begin
      ReplyErr(Resp, 404, 'mail-sync belongs to the mail app');
      Exit;
    end;
    Root := TJsonObject.Create;
    try
      if not SyncMail(Filed, Err) then
      begin
        Root.PutStr('error', Err);
        Root.PutBool('configured', MailConfigured);
        { Neither failure is the caller's fault, so neither is a 4xx. No IMAP
          credentials is a service that isn't set up yet (503); credentials
          that fail at the far end is an upstream that let us down (502). The
          app shows the message either way, but the status is what a proxy or
          a log reads, and mislabelling this as a bad request would send
          anyone debugging it to look at the wrong side. }
        if not MailConfigured then
          ReplyJSON(Resp, 503, Root.ToJSON)
        else
          ReplyJSON(Resp, 502, Root.ToJSON);
        Exit;
      end;
      Root.PutInt ('filed', Filed);
      Root.PutBool('configured', True);
      ReplyJSON(Resp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
    Exit;
  end;
  ReplyErr(Resp, 404, 'no such action: ' + Action);
end;

{ Serialise a run record for the clients. }
function RunJSON(const R: TRunInfo): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('project',  R.Project);
  Result.PutStr('state',    RunStateToStr(R.State));
  Result.PutInt('port',     R.Port);
  Result.PutStr('started',  R.Started);
  Result.PutInt('exit_code', R.ExitCode);
  Result.PutStr('command',  R.Command);
  Result.PutStr('backend',  R.Backend);
  if R.Error <> '' then Result.PutStr('error', R.Error);
  { An app that serves HTTP is reachable directly; the desktop points a
    window at this. }
  if (R.State = rsRunning) and (R.Port > 0) then
    Result.PutStr('url', 'http://127.0.0.1:' + IntToStr(R.Port) + '/');
end;

function RouteAppAPI(const Method, Doc, Query, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Project, Key, Val, Err, Path: string;
  Info, App: TAppInfo;
  Root: TJsonObject;
  Obj: TJsonObject;
  Arr: TJsonArray;
  Keys: TStringList;
  I: Integer;
  Consented: Boolean;
  Run: TRunInfo;
begin
  Result := True;
  Segs := PathSegments(Doc);
  try
    { v1 / apps / <project> [ / state [ / <key> ] ] }
    if Segs.Count < 3 then
    begin
      Result := False;
      Exit;
    end;
    Project := Segs[2];
    if not IsSafeName(Project) then
    begin
      ReplyErr(Resp, 404, 'no such project');
      Exit;
    end;

    if Segs.Count = 3 then
    begin
      if Method <> 'GET' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      if not ProjectExists(Project) or not GetApp(Project, Info) then
      begin
        ReplyErr(Resp, 404, 'no such project');
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutBool('exists', Info.Exists);
        Root.PutStr ('name',   Info.Name);
        Root.PutStr ('kind',   AppKindToStr(Info.Kind));
        Root.PutStr ('entry',  Info.Entry);
        Root.PutInt ('width',  Info.Width);
        Root.PutInt ('height', Info.Height);
        Root.PutStr ('icon',   Info.Icon);
        Root.PutBool('ready',  Info.EntryExists);
        Root.PutBool('servable', AppIsServable(Info));
        { What the runner would ACTUALLY do. A client that decides from
          `kind` alone offers Run for a process app with no command and
          gets a 400 the user can do nothing with. }
        Root.PutBool('runnable', AppIsRunnable(Info));
        { Declared permissions travel to the client so the desktop can show
          them before the user opens or runs the app. }
        Root.PutStr ('network', Info.Network);
        Root.PutStr ('env',     Info.EnvKeys);
        if AppIsServable(Info) then
          Root.PutStr('url', '/apps/' + Project + '/');
        { Process kinds carry their run state here so the desktop can render
          a Run / Stop button without a second round trip. }
        if Info.Exists and not AppIsServable(Info) then
        begin
          Run := AppRunInfo(Project);
          Root.PutStr('run_backend', Run.Backend);
          Root.PutStr('run_state', RunStateToStr(Run.State));
          Root.PutInt('run_port',  Run.Port);
          Root.PutStr('run_command', PlannedCommand(Project, Err));
          if Run.Port > 0 then
            Root.PutStr('run_url',
              'http://127.0.0.1:' + IntToStr(Run.Port) + '/');
        end;
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;

    { /v1/apps/<p>/run|stop|runlog -- the process kinds. }
    if LowerCase(Segs[3]) = 'run' then
    begin
      if Method <> 'POST' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      Obj := BodyObj(Body);
      try
        Consented := (Obj <> nil) and Obj.GetBool('confirm', False);
      finally
        Obj.Free;
      end;
      if not Consented then
      begin
        { Answer with the command the user is being asked to approve, so a
          client can show it verbatim before asking again with confirm. }
        Root := TJsonObject.Create;
        try
          Root.PutStr('error', 'running this app needs explicit confirmation');
          Root.PutStr('command', PlannedCommand(Project, Err));
          if Err <> '' then Root.PutStr('detail', Err);
          Root.PutBool('needs_confirm', True);
          ReplyJSON(Resp, 409, Root.ToJSON);
        finally
          Root.Free;
        end;
        Exit;
      end;
      if not StartApp(Project, True, Run, Err) then
      begin
        { A launch that never got off the ground is a terminal state like any
          other, and the stream is how every OTHER client finds out. Only the
          caller sees this 400; without the event, a second desktop watching
          the same workspace would sit on "stopped" with no idea a start had
          been attempted and failed. }
        PublishApp(Project, 'failed', 0);
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      PublishApp(Project, RunStateToStr(Run.State), Run.Port);
      Root := RunJSON(Run);
      try
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;

    if LowerCase(Segs[3]) = 'stop' then
    begin
      if Method <> 'POST' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      if not StopApp(Project, Err) then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      PublishApp(Project, 'stopped', 0);
      ReplyOK(Resp);
      Exit;
    end;

    if LowerCase(Segs[3]) = 'runlog' then
    begin
      if Method <> 'GET' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('log', AppRunLog(Project));
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;

    { /v1/apps/<p>/read/<surface> -- a NARROW, ALLOWLISTED read window onto
      the agent's own surfaces.

      The suite apps (Calendar over cron, Library over sessions and pages,
      Cookbook over the provider catalog) are ordinary sandboxed apps, and a
      sandboxed app cannot call /v1/* itself. Rather than punching a general
      hole, this route exposes a fixed set of read-only projections and
      nothing else -- no /v1/config, no secrets, no writes. The allowlist is
      enforced HERE, server-side, so it holds however the app is opened. }
    (* /v1/apps/<p>/action/<name> -- the ALLOWLISTED write counterpart to the
       read window. An app cannot call the API, so this is how the Mail app
       asks for a sync. Same rule as the read surface: the names are listed
       here and nothing else resolves, so widening the surface is a
       deliberate edit rather than an emergent property. *)
    if LowerCase(Segs[3]) = 'action' then
    begin
      if Method <> 'POST' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      if Segs.Count < 5 then
      begin
        ReplyErr(Resp, 404, 'name an action');
        Exit;
      end;
      Result := RunAppAction(Project, LowerCase(Segs[4]), Body, Resp);
      Exit;
    end;

    (* PUT /v1/apps/<p>/entry -- put an earlier version of the app back.

       The chat keeps an artifact card per turn, so scrolling back through a
       conversation is scrolling back through versions; this is what makes an
       old card actionable rather than decorative.

       Deliberately narrow. It writes ONE file -- the entry the manifest
       already declares -- resolved through the same two-barrier resolver
       that serves it, so this cannot become a way to write anywhere in the
       project. And it is NOT app-scoped: an app must not be able to rewrite
       itself, only the desktop may hand it a previous body. *)
    if LowerCase(Segs[3]) = 'entry' then
    begin
      if Method <> 'PUT' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      if not GetApp(Project, App) or not App.Exists then
      begin
        ReplyErr(Resp, 404, 'no app');
        Exit;
      end;
      if Length(Body) > MaxEntryBytes then
      begin
        ReplyErr(Resp, 413, 'that is too large for an app entry');
        Exit;
      end;
      Path := ResolveAssetPath(Project, App.Entry);
      if Path = '' then
      begin
        ReplyErr(Resp, 400, 'the manifest entry does not resolve');
        Exit;
      end;
      try
        WriteFileText(Path, Body);
      except
        on E: Exception do
        begin
          ReplyErr(Resp, 500, 'could not write the entry: ' + E.Message);
          Exit;
        end;
      end;
      PublishApp(Project, 'updated', 0);
      ReplyOK(Resp);
      Exit;
    end;

    if LowerCase(Segs[3]) = 'read' then
    begin
      if Method <> 'GET' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      if Segs.Count < 5 then
      begin
        ReplyErr(Resp, 404, 'name a surface: cron, sessions, providers, pages, projects');
        Exit;
      end;
      Result := ReadSurface(Project, LowerCase(Segs[4]), Query, Resp);
      Exit;
    end;

    if LowerCase(Segs[3]) <> 'state' then
    begin
      ReplyErr(Resp, 404, 'no such route');
      Exit;
    end;

    { /v1/apps/<p>/state -- list keys }
    if Segs.Count = 4 then
    begin
      if Method <> 'GET' then
      begin
        ReplyErr(Resp, 405, 'method not allowed');
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Arr := TJsonArray.Create;
        Keys := StateKeys(Project);
        try
          for I := 0 to Keys.Count - 1 do
            Arr.AddStr(Keys[I]);
        finally
          Keys.Free;
        end;
        Root.PutArray('keys', Arr);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;

    Key := Segs[4];
    if Method = 'GET' then
    begin
      { An unset key is a normal answer, not an error: every app's first run
        reads keys it has never written. Answering 404 made browsers log a
        console error on every cold start, which reads as a broken app. }
      Root := TJsonObject.Create;
      try
        Root.PutStr ('key', Key);
        if StateGet(Project, Key, Val) then
        begin
          Root.PutBool('exists', True);
          Root.PutStr ('value', Val);
        end
        else
          Root.PutBool('exists', False);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;
    if (Method = 'PUT') or (Method = 'POST') then
    begin
      { The value is the raw body -- an app storing JSON shouldn't have to
        double-encode it into a wrapper object. }
      if not StateSet(Project, Key, Body, Err) then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      ReplyOK(Resp);
      Exit;
    end;
    if Method = 'DELETE' then
    begin
      if not StateDelete(Project, Key, Err) then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      ReplyOK(Resp);
      Exit;
    end;
    ReplyErr(Resp, 405, 'method not allowed');
  finally
    Segs.Free;
  end;
end;

{ GET /apps/<project>/<path...> -- serve the app's own files. }
function RouteAppAsset(const Method, Doc: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Project, Rel, Full: string;
  I: Integer;
  Info: TAppInfo;
begin
  Result := True;
  if Method <> 'GET' then
  begin
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;
  Segs := PathSegments(Doc);
  try
    if Segs.Count < 2 then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    Project := Segs[1];
    if not IsSafeName(Project) then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    Rel := '';
    for I := 2 to Segs.Count - 1 do
    begin
      if Rel <> '' then Rel := Rel + '/';
      Rel := Rel + Segs[I];
    end;

    if not GetApp(Project, Info) then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    if not AppIsServable(Info) then
    begin
      ReplyErr(Resp, 404,
        'this project has no servable app (kind must be page or html)');
      Exit;
    end;

    { pasclaw.js is virtual: generated per project rather than read from
      disk, so every app has the SDK without shipping a copy of it. A real
      file of that name in the app directory still wins, so an app can
      override it if it ever needs to. }
    Full := ResolveAssetPath(Project, Rel);
    if (Full = '') and SameText(Rel, 'pasclaw.js') then
    begin
      Resp.Status      := 200;
      Resp.ContentType := 'application/javascript; charset=utf-8';
      Resp.Body        := AppSDK(Project);
      Resp.FilePath    := '';
      Resp.Headers     := 'X-Content-Type-Options: nosniff';
      Exit;
    end;
    if Full = '' then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;

    Resp.Status      := 200;
    Resp.ContentType := AssetContentType(Full);
    Resp.Body        := '';
    Resp.FilePath    := Full;
    { Model-authored code: served under the tightest policy its kind allows,
      and never sniffed into something executable. }
    Resp.Headers     := 'Content-Security-Policy: ' +
                        AppContentSecurityPolicy(Info.Kind) + #13#10 +
                        'X-Content-Type-Options: nosniff' + #13#10 +
                        'Referrer-Policy: no-referrer';
  finally
    Segs.Free;
  end;
end;

{ ---- /v1/pages + /pages ---- }

function RoutePagesAPI(const Method, Doc, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Root, Obj, Item: TJsonObject;
  Arr: TJsonArray;
  List: TPageInfoArray;
  I: Integer;
  Id, Query, Err, Title, BodyHTML, SourcesJSON, Slug, Revise: string;
  Kind: TPageKind;
  Info, PriorInfo: TPageInfo;
  Sources: TPageSourceArray;
begin
  Result := True;
  Segs := PathSegments(Doc);
  try
    if (Method = 'GET') and (Segs.Count = 2) then
    begin
      Root := TJsonObject.Create;
      try
        Arr := TJsonArray.Create;
        List := ListPages;
        for I := 0 to High(List) do
        begin
          Item := PageJSON(List[I]);
          Arr.AddObject(Item);
        end;
        Root.PutArray('pages', Arr);
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      Exit;
    end;

    if (Method = 'POST') and (Segs.Count = 2) then
    begin
      Obj := BodyObj(Body);
      try
        if Obj = nil then
        begin
          ReplyErr(Resp, 400, 'expected a JSON body with "query"');
          Exit;
        end;
        Query := Trim(Obj.GetStr('query', ''));
        if Query = '' then
        begin
          ReplyErr(Resp, 400, '"query" is required');
          Exit;
        end;
        Kind := StrToPageKind(Obj.GetStr('kind', 'search'));
        (* "revise": "<page id>" -- this question continues that page.

           Validated here rather than trusted: an id naming a page that does
           not exist is treated as an ordinary new question, because
           refusing the whole request over a stale tab id would lose the
           user's actual question. *)
        Revise := Trim(Obj.GetStr('revise', ''));
        if (Revise <> '') and not GetPage(Revise, PriorInfo) then Revise := '';

        { A caller may supply the rendered body itself (the agent loop does
          exactly this once it has run the search), or ask us to generate. }
        if Obj.Has('body') then
        begin
          Title       := Obj.GetStr('title', Query);
          BodyHTML    := Obj.GetStr('body', '');
          SourcesJSON := '';
          if Obj.Has('sources') then
          begin
            Arr := Obj.ChildArray('sources');
            if Arr <> nil then SourcesJSON := Arr.ToJSON;
          end;
        end
        else
        begin
          if not Assigned(GPageGen) then
          begin
            ReplyErr(Resp, 503,
              'this gateway has no agent attached, so it cannot generate ' +
              'pages; POST a rendered "body" instead');
            Exit;
          end;
          if not GPageGen(Query, Kind, Revise, Title, BodyHTML,
                          SourcesJSON, Err) then
          begin
            ReplyErr(Resp, 500, Err);
            Exit;
          end;
        end;

        Sources := ParseSources(SourcesJSON);
        Id := SavePage(Title, Query, Kind, BodyHTML, Sources, Err);
        if Id = '' then
        begin
          ReplyErr(Resp, 500, Err);
          Exit;
        end;
        (* Announce it. PublishPage existed and nothing called it, so the one
           event on the whole stream that marks the END of the longest thing
           the gateway does -- a research turn, minutes of it -- was never
           emitted. The requesting client got its answer in the response and
           every other client learned nothing.

           Published before replying, deliberately: a subscriber that is also
           the requester should not be able to render the page and only then
           be told it exists. *)
        PublishPage(Id, Title, Length(Sources));
        Root := TJsonObject.Create;
        try
          Root.PutStr('id', Id);
          Root.PutStr('url', '/pages/' + Id + '/');
          Root.PutInt('source_count', Length(Sources));
          ReplyJSON(Resp, 200, Root.ToJSON);
        finally
          Root.Free;
        end;
      finally
        Obj.Free;
      end;
      Exit;
    end;

    (* POST /v1/pages/<id>/promote -- "make this interactive".

       The page is copied into a new project as an `html` app; the page
       itself stays in the history untouched, because it is the record of an
       answer at a time and editing it in place would falsify it. *)
    if (Method = 'POST') and (Segs.Count = 4) and
       (LowerCase(Segs[3]) = 'promote') then
    begin
      Obj := BodyObj(Body);
      try
        Slug := PromotePage(Segs[2],
                  IfEmpty(Obj, 'name'), Err);
      finally
        Obj.Free;
      end;
      if Slug = '' then
      begin
        ReplyErr(Resp, 400, Err);
        Exit;
      end;
      Root := TJsonObject.Create;
      try
        Root.PutStr('project', Slug);
        Root.PutStr('url', '/apps/' + Slug + '/index.html');
        ReplyJSON(Resp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
      PublishProjects;
      Exit;
    end;

    if Segs.Count = 3 then
    begin
      Id := Segs[2];
      if Method = 'GET' then
      begin
        if not GetPage(Id, Info) then
        begin
          ReplyErr(Resp, 404, 'no such page');
          Exit;
        end;
        Item := PageJSON(Info);
        try
          ReplyJSON(Resp, 200, Item.ToJSON);
        finally
          Item.Free;
        end;
        Exit;
      end;
      if Method = 'DELETE' then
      begin
        if not DeletePage(Id, Err) then
        begin
          ReplyErr(Resp, 404, Err);
          Exit;
        end;
        ReplyOK(Resp);
        Exit;
      end;
      ReplyErr(Resp, 405, 'method not allowed');
      Exit;
    end;

    ReplyErr(Resp, 404, 'no such route');
  finally
    Segs.Free;
  end;
end;

{ GET /pages/<id>/ -- serve the rendered document. }
function RoutePageDoc(const Method, Doc: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Info: TPageInfo;
begin
  Result := True;
  if Method <> 'GET' then
  begin
    ReplyErr(Resp, 405, 'method not allowed');
    Exit;
  end;
  Segs := PathSegments(Doc);
  try
    if Segs.Count < 2 then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    if not GetPage(Segs[1], Info) then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    if not FileExists(Info.Path) then
    begin
      ReplyErr(Resp, 404, 'not found');
      Exit;
    end;
    Resp.Status      := 200;
    Resp.ContentType := 'text/html; charset=utf-8';
    Resp.Body        := '';
    Resp.FilePath    := Info.Path;
    { A page is a document: no scripts, no network, ever. }
    Resp.Headers     := 'Content-Security-Policy: ' +
                        AppContentSecurityPolicy(akPage) + #13#10 +
                        'X-Content-Type-Options: nosniff' + #13#10 +
                        'Referrer-Policy: no-referrer';
  finally
    Segs.Free;
  end;
end;

{ ------------------------------------------------------------------ entry -- }

{ The machine app processes actually run on. The desktop shows this so a
  user opening a remote gateway knows a "local" app is not on their laptop. }
function LocalHostName: string;
begin
  Result := GetEnvironmentVariable('HOSTNAME');
  if Result = '' then Result := GetEnvironmentVariable('COMPUTERNAME');
  if Result = '' then Result := 'this host';
end;

function DesktopRoute(const Method, Doc, Query, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  M, StateBody, StateErr: string;
  CurDesk, CntDesk, NewDesk: Integer;
  Root: TJsonObject;
begin
  Reply(Resp, 404, 'application/json; charset=utf-8', '{"error":"not found"}');
  M := UpperCase(Trim(Method));

  (* GET/PUT /v1/desktop/state -- the desktop's own layout.

     Server-side rather than localStorage, and per WORKSPACE rather than per
     browser, because the arrangement of windows belongs to the world you
     are working in. Switching to the "home" workspace should bring back the
     home desktop, from any browser, on any machine pointed at this gateway.

     The body is opaque to us: the client decides what a restorable window
     is, and a gateway that tried to schema it would have to be edited every
     time the client learned a new window kind. Bounded, though -- this is a
     layout, and anything megabyte-sized is a bug or an attempt. *)
  (* GET/POST /v1/desktop/desktops -- the pager. {current, count}; POST
     {"current": n} switches, growing count when n is the next number up.
     Bounded at MaxDesktops because a pager with 40 slots is not a pager. *)
  if Doc = '/v1/desktop/desktops' then
  begin
    ReadDesktopMeta(CurDesk, CntDesk);
    if M = 'GET' then
    begin
      ReplyJSON(Resp, 200, '{"current":' + IntToStr(CurDesk) +
                           ',"count":' + IntToStr(CntDesk) + '}');
      Exit(True);
    end;
    if M = 'POST' then
    begin
      Root := BodyObj(Body);
      if Root = nil then
      begin
        ReplyErr(Resp, 400, 'expected {"current": n}');
        Exit(True);
      end;
      try
        NewDesk := Integer(Root.GetInt('current', 0));
      finally
        Root.Free;
      end;
      if (NewDesk < 1) or (NewDesk > CntDesk + 1) or (NewDesk > MaxDesktops) then
      begin
        ReplyErr(Resp, 400, Format('desktop must be 1..%d (or %d to add one)',
                 [CntDesk, CntDesk + 1]));
        Exit(True);
      end;
      if NewDesk > CntDesk then CntDesk := NewDesk;
      WriteDesktopMeta(NewDesk, CntDesk);
      ReplyJSON(Resp, 200, '{"current":' + IntToStr(NewDesk) +
                           ',"count":' + IntToStr(CntDesk) + '}');
      Exit(True);
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit(True);
  end;

  if Doc = '/v1/desktop/state' then
  begin
    { ?desktop=N names a layout explicitly; without it, the current one.
      The default is what keeps old clients working: they save and restore
      "the layout" and never learn desktops exist. }
    NewDesk := StrToIntDef(QueryValue(Query, 'desktop'), 0);
    if M = 'GET' then
    begin
      if not ReadDesktopState(NewDesk, StateBody) then StateBody := '{}';
      ReplyJSON(Resp, 200, StateBody);
      Exit(True);
    end;
    if M = 'PUT' then
    begin
      if Length(Body) > MaxDesktopState then
      begin
        ReplyErr(Resp, 413, 'desktop state is too large');
        Exit(True);
      end;
      { Parse-check before writing: a truncated PUT must not leave a state
        file that makes every future load fail. }
      Root := BodyObj(Body);
      if Root = nil then
      begin
        ReplyErr(Resp, 400, 'desktop state must be a JSON object');
        Exit(True);
      end;
      Root.Free;
      if not WriteDesktopState(NewDesk, Body, StateErr) then
      begin
        ReplyErr(Resp, 500, StateErr);
        Exit(True);
      end;
      ReplyOK(Resp);
      Exit(True);
    end;
    ReplyErr(Resp, 405, 'method not allowed');
    Exit(True);
  end;

  { GET /v1/desktop/config -- what the client needs to know about THIS
    gateway before it renders: where apps are served from, and whether that
    is a separate origin. }
  if (Doc = '/v1/desktop/config') and (M = 'GET') then
  begin
    Root := TJsonObject.Create;
    try
      Root.PutStr ('apps_origin',   GAppsOrigin);
      Root.PutBool('apps_isolated', GAppsOrigin <> '');
      Root.PutStr ('host',          LocalHostName);
      ReplyJSON(Resp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
    Exit(True);
  end;

  if HasPrefix(Doc, '/v1/workspaces') then
    Exit(RouteWorkspaces(M, Doc, Body, Resp));

  if HasPrefix(Doc, '/v1/projects') then
  begin
    if RouteProjectCollection(M, Doc, Body, Resp) then Exit(True);
    Exit(RouteProjectItem(M, Doc, Body, Resp));
  end;

  if HasPrefix(Doc, '/v1/apps') then
    Exit(RouteAppAPI(M, Doc, Query, Body, Resp));

  if HasPrefix(Doc, '/v1/pages') then
    Exit(RoutePagesAPI(M, Doc, Body, Resp));

  if HasPrefix(Doc, '/apps/') then
    Exit(RouteAppAsset(M, Doc, Resp));

  if HasPrefix(Doc, '/pages/') then
    Exit(RoutePageDoc(M, Doc, Resp));

  Result := False;
end;

end.
