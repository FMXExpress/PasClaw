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

  { Produces a page body + a SOURCES JSON array for a query. }
  TPageGenerator = function(const Query: string; Kind: TPageKind;
    out Title, BodyHTML, SourcesJSON, Err: string): Boolean;

procedure SetJobRunner(Runner: TJobRunner);
procedure SetPageGenerator(Gen: TPageGenerator);

{ True when Doc is a path this unit owns -- used by the gateway to decide
  whether to consult us at all (and to keep auth gating in one place). }
function IsDesktopPath(const Doc: string): Boolean;

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
  PasClaw.Session.Store;    { session list for the Library app }

var
  GJobRunner: TJobRunner = nil;
  GPageGen: TPageGenerator = nil;

procedure SetJobRunner(Runner: TJobRunner);
begin
  GJobRunner := Runner;
end;

procedure SetPageGenerator(Gen: TPageGenerator);
begin
  GPageGen := Gen;
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

function IsDesktopPath(const Doc: string): Boolean;
begin
  Result := HasPrefix(Doc, '/v1/workspaces')
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

(* The allowlisted read surfaces. Each is a small projection built here from
   a store this unit already depends on -- deliberately NOT a proxy to the
   gateway's own handlers, because a proxy would inherit whatever those
   handlers ever start returning. Adding a surface has to be a deliberate
   edit to this function. *)
function ReadSurface(const Surface: string;
  out Resp: TDesktopResponse): Boolean;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  Cfg: TConfig;
  I: Integer;
  Metas: TSessionMetaArray;
  Pages_: TPageInfoArray;
  Projs: TProjectInfoArray;
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
    else
    begin
      Arr.Free;
      ReplyErr(Resp, 404, 'no such surface: ' + Surface +
               ' (cron, sessions, providers, pages, projects)');
      Exit;
    end;

    Root.PutArray('items', Arr);
    Root.PutStr('surface', Surface);
    ReplyJSON(Resp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
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
  if R.Error <> '' then Result.PutStr('error', R.Error);
  { An app that serves HTTP is reachable directly; the desktop points a
    window at this. }
  if (R.State = rsRunning) and (R.Port > 0) then
    Result.PutStr('url', 'http://127.0.0.1:' + IntToStr(R.Port) + '/');
end;

function RouteAppAPI(const Method, Doc, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  Segs: TStringList;
  Project, Key, Val, Err: string;
  Info: TAppInfo;
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
      Result := ReadSurface(LowerCase(Segs[4]), Resp);
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
  Id, Query, Err, Title, BodyHTML, SourcesJSON: string;
  Kind: TPageKind;
  Info: TPageInfo;
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
          if not GPageGen(Query, Kind, Title, BodyHTML, SourcesJSON, Err) then
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

function DesktopRoute(const Method, Doc, Query, Body: string;
  out Resp: TDesktopResponse): Boolean;
var
  M: string;
begin
  Reply(Resp, 404, 'application/json; charset=utf-8', '{"error":"not found"}');
  M := UpperCase(Trim(Method));

  if HasPrefix(Doc, '/v1/workspaces') then
    Exit(RouteWorkspaces(M, Doc, Body, Resp));

  if HasPrefix(Doc, '/v1/projects') then
  begin
    if RouteProjectCollection(M, Doc, Body, Resp) then Exit(True);
    Exit(RouteProjectItem(M, Doc, Body, Resp));
  end;

  if HasPrefix(Doc, '/v1/apps') then
    Exit(RouteAppAPI(M, Doc, Body, Resp));

  if HasPrefix(Doc, '/v1/pages') then
    Exit(RoutePagesAPI(M, Doc, Body, Resp));

  if HasPrefix(Doc, '/apps/') then
    Exit(RouteAppAsset(M, Doc, Resp));

  if HasPrefix(Doc, '/pages/') then
    Exit(RoutePageDoc(M, Doc, Resp));

  Result := False;
end;

end.
