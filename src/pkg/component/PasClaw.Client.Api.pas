(*
  PasClaw.Client.Api - a plain client for a running PasClaw gateway.

  Shared by the two native clients: PasclawStudio (studio/) and PasclawDesktop
  (desktop/). Neither should carry its own copy of the HTTP + JSON plumbing --
  when a route changes, it should change once.

  Deliberately UI-free: no FMX, no VCL, no forms. It speaks the desktop
  surface (PasClaw.Gateway.Desktop) plus the bits of /v1/* a client needs,
  and hands back records the caller renders however it likes. That is also
  what lets it compile and be tested under FPC even though the FireMonkey
  client it serves needs Delphi.

  Indy for transport under both compilers -- the repo already vendors it for
  FPC and Delphi ships it, so there is one code path rather than an
  {$IFDEF}-split between TIdHTTP and System.Net.HttpClient.
*)
unit PasClaw.Client.Api;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  EPasClawClient = class(Exception)
  public
    Status: Integer;
  end;

  TWorkspaceRow = record
    Name, Label_: string;
    Slot, Projects: Integer;
    Active: Boolean;
  end;
  TWorkspaceRows = array of TWorkspaceRow;

  TProjectRow = record
    Name, Title, Description, Icon, Created: string;
    HasApp, AppReady: Boolean;
    AppKind: string;
    AppWidth, AppHeight: Integer;
    Tasks, OpenTasks: Integer;
  end;
  TProjectRows = array of TProjectRow;

  TTaskRow = record
    Id, Project, Title, Status, Notes: string;
    Jobs: Integer;
  end;
  TTaskRows = array of TTaskRow;

  TJobRow = record
    Id, Project, Task, Status, SessionId, Started, Ended, Summary: string;
  end;
  TJobRows = array of TJobRow;

  TAppRow = record
    Exists, Ready, Servable: Boolean;
    Name, Kind, Entry, Icon, Network, Env, URL: string;
    Width, Height: Integer;
  end;

  TPageRow = record
    Id, Title, Query, Kind, Created, URL: string;
    SourceCount: Integer;
  end;
  TPageRows = array of TPageRow;

  { Called for each streamed chunk of an assistant reply. Set Abort to stop. }
  TChatChunkProc = procedure(const Chunk: string; var Abort: Boolean) of object;

  TPasClawClient = class
  private
    FBaseURL: string;
    FToken: string;
    FTimeoutMs: Integer;
    FLastError: string;
    function Request(const Method, Path, Body: string): string;
    function GetJSON(const Path: string): string;
  public
    constructor Create(const ABaseURL: string = 'http://127.0.0.1:8088');
    { Base URL without a trailing slash; setting it normalises. }
    property BaseURL: string read FBaseURL write FBaseURL;
    property Token: string read FToken write FToken;
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property LastError: string read FLastError;

    function Ping(out Version: string): Boolean;

    { ---- workspaces ---- }
    function Workspaces: TWorkspaceRows;
    function CreateWorkspace(const ALabel: string): string;
    function ActivateWorkspace(const Name: string): Boolean;

    { ---- projects ---- }
    function Projects: TProjectRows;
    function Project(const Name: string; out Row: TProjectRow): Boolean;
    function CreateProject(const Title: string): string;
    function DeleteProject(const Name: string): Boolean;

    { ---- tasks + jobs ---- }
    function Tasks(const Project: string): TTaskRows;
    function CreateTask(const Project, Title: string): string;
    function UpdateTaskStatus(const Project, TaskId, Status: string): Boolean;
    function Jobs(const Project, TaskId: string): TJobRows;
    function JobLog(const Project, TaskId, JobId: string): string;

    { ---- apps ---- }
    function App(const Project: string; out Row: TAppRow): Boolean;
    { Absolute URL a browser control should open for a servable app. }
    function AppURL(const Project: string): string;
    function StateGet(const Project, Key: string; out Value: string): Boolean;
    function StateSet(const Project, Key, Value: string): Boolean;

    { ---- pages ---- }
    function Pages: TPageRows;
    function PageURL(const Id: string): string;
    { Ask the gateway to research a query and render it as a page. Returns the
      new page id. Needs a gateway with an agent attached. }
    function CreatePage(const Query: string; out Id: string): Boolean;

    { ---- chat ---- }
    (* Stream one turn through /v1/chat/completions. History is a JSON array
       of {"role","content"} objects; System, when non-empty, is sent as the
       leading system message. OnChunk receives assistant text as it arrives.
       Returns the full reply. *)
    function Chat(const HistoryJSON, System_: string;
      OnChunk: TChatChunkProc): string;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils,
  IdHTTP, IdGlobal, IdSSLOpenSSL, IdComponent;

type
  { Indy hands us the body as it arrives; this feeds the caller's callback
    without buffering the whole SSE stream first. }
  TSSEStream = class(TStream)
  private
    FBuf: string;
    FText: string;
    FOnChunk: TChatChunkProc;
    FAbort: Boolean;
    procedure Consume(const Data: string);
  public
    constructor Create(AOnChunk: TChatChunkProc);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    property Text: string read FText;
    property Aborted: Boolean read FAbort;
  end;

constructor TSSEStream.Create(AOnChunk: TChatChunkProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
end;

function TSSEStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TSSEStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

procedure TSSEStream.Consume(const Data: string);
var
  NL: Integer;
  Line, Payload, Delta: string;
  Obj, Choice, DeltaObj: TJsonObject;
  Arr: TJsonArray;
begin
  FBuf := FBuf + Data;
  repeat
    NL := Pos(#10, FBuf);
    if NL = 0 then Break;
    Line := Copy(FBuf, 1, NL - 1);
    Delete(FBuf, 1, NL);
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    (* The gateway's ": pasclaw-tool ..." SSE comments carry tool detail the
       desktop surfaces elsewhere; the text stream ignores them. Paren-star
       delimiters because a brace in the example would close the comment. *)
    if (Line = '') or (Line[1] = ':') then Continue;
    if not HasPrefix(Line, 'data:') then Continue;
    Payload := Trim(Copy(Line, 6, MaxInt));
    if (Payload = '') or (Payload = '[DONE]') then Continue;
    Delta := '';
    try
      Obj := TJsonObject.Parse(Payload);
    except
      Continue;
    end;
    try
      Arr := Obj.ChildArray('choices');
      if (Arr <> nil) and (Arr.Count > 0) then
      begin
        Choice := Arr.ItemObject(0);
        if Choice <> nil then
        begin
          DeltaObj := Choice.ChildObject('delta');
          if DeltaObj <> nil then
            Delta := DeltaObj.GetStr('content', '');
        end;
      end;
    finally
      Obj.Free;
    end;
    if Delta = '' then Continue;
    FText := FText + Delta;
    if Assigned(FOnChunk) then
      FOnChunk(Delta, FAbort);
  until False;
end;

function TSSEStream.Write(const Buffer; Count: Longint): Longint;
var
  S: AnsiString;
begin
  Result := Count;
  if Count <= 0 then Exit;
  SetLength(S, Count);
  Move(Buffer, S[1], Count);
  Consume(string(S));
  { Indy has no cancel hook on the content stream, so an aborted stream
    raises out of Write -- the caller catches it and keeps the text so far. }
  if FAbort then
    raise EAbort.Create('chat aborted by caller');
end;

{ --------------------------------------------------------------- client -- }

constructor TPasClawClient.Create(const ABaseURL: string);
begin
  inherited Create;
  FBaseURL := ABaseURL;
  while (FBaseURL <> '') and (FBaseURL[Length(FBaseURL)] = '/') do
    SetLength(FBaseURL, Length(FBaseURL) - 1);
  FTimeoutMs := 30000;
end;

function NewHttp(const Token: string; TimeoutMs: Integer): TIdHTTP;
begin
  Result := TIdHTTP.Create(nil);
  Result.HandleRedirects := True;
  Result.ConnectTimeout  := TimeoutMs;
  Result.ReadTimeout     := TimeoutMs;
  Result.Request.ContentType := 'application/json';
  Result.Request.Accept      := 'application/json';
  if Token <> '' then
    Result.Request.CustomHeaders.AddValue('Authorization', 'Bearer ' + Token);
  { A gateway reached over https (a tunnel, a remote box) needs the TLS
    handler; a local http gateway never touches it. }
  Result.IOHandler := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
end;

function TPasClawClient.Request(const Method, Path, Body: string): string;
var
  Http: TIdHTTP;
  Req: TStringStream;
  Resp: TStringStream;
  E2: EPasClawClient;
begin
  Result := '';
  FLastError := '';
  Http := NewHttp(FToken, FTimeoutMs);
  Req  := nil;
  Resp := TStringStream.Create('');
  try
    try
      if Body <> '' then
        Req := TStringStream.Create(Body);
      if Method = 'GET' then
        Http.Get(FBaseURL + Path, Resp)
      else if Method = 'POST' then
        Http.Post(FBaseURL + Path, Req, Resp)
      else if Method = 'PUT' then
        Http.Put(FBaseURL + Path, Req, Resp)
      else if Method = 'DELETE' then
        Http.Delete(FBaseURL + Path)
      else if Method = 'PATCH' then
        Http.Patch(FBaseURL + Path, Req, Resp)
      else
        raise EPasClawClient.Create('unsupported method ' + Method);
      Result := Resp.DataString;
    except
      on E: EIdHTTPProtocolException do
      begin
        { The gateway's error bodies are JSON with an "error" field; surface
          that rather than Indy's generic status text. }
        FLastError := JsonReadStr(E.ErrorMessage, 'error', E.Message);
        E2 := EPasClawClient.Create(FLastError);
        E2.Status := E.ErrorCode;
        raise E2;
      end;
      on E: Exception do
      begin
        FLastError := E.Message;
        E2 := EPasClawClient.Create(E.Message);
        E2.Status := 0;
        raise E2;
      end;
    end;
  finally
    Resp.Free;
    Req.Free;
    Http.Free;
  end;
end;

function TPasClawClient.GetJSON(const Path: string): string;
begin
  Result := Request('GET', Path, '');
end;

function TPasClawClient.Ping(out Version: string): Boolean;
var
  Body: string;
begin
  Version := '';
  try
    Body := GetJSON('/v1/health');
  except
    Exit(False);
  end;
  Version := JsonReadStr(Body, 'version', '');
  Result := JsonReadStr(Body, 'status', '') = 'ok';
end;

{ ---- workspaces ---- }

function TPasClawClient.Workspaces: TWorkspaceRows;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  SetLength(Result, 0);
  Root := TJsonObject.Parse(GetJSON('/v1/workspaces'));
  try
    Arr := Root.ChildArray('workspaces');
    if Arr = nil then Exit;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item = nil then Continue;
      Result[I].Name     := Item.GetStr('name', '');
      Result[I].Label_   := Item.GetStr('label', '');
      Result[I].Slot     := Integer(Item.GetInt('slot', 0));
      Result[I].Projects := Integer(Item.GetInt('projects', 0));
      Result[I].Active   := Item.GetBool('active', False);
    end;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.CreateWorkspace(const ALabel: string): string;
var
  Req: TJsonObject;
begin
  Req := TJsonObject.Create;
  try
    Req.PutStr('label', ALabel);
    Result := JsonReadStr(Request('POST', '/v1/workspaces', Req.ToJSON), 'name', '');
  finally
    Req.Free;
  end;
end;

function TPasClawClient.ActivateWorkspace(const Name: string): Boolean;
var
  Req: TJsonObject;
begin
  Req := TJsonObject.Create;
  try
    Req.PutStr('name', Name);
    Result := JsonReadStr(Request('POST', '/v1/workspaces/activate', Req.ToJSON),
                          'active', '') = Name;
  finally
    Req.Free;
  end;
end;

{ ---- projects ---- }

procedure ReadProject(Item: TJsonObject; var Row: TProjectRow);
begin
  Row.Name        := Item.GetStr('name', '');
  Row.Title       := Item.GetStr('title', Row.Name);
  Row.Description := Item.GetStr('description', '');
  Row.Icon        := Item.GetStr('icon', '');
  Row.Created     := Item.GetStr('created', '');
  Row.HasApp      := Item.GetBool('has_app', False);
  Row.AppReady    := Item.GetBool('app_ready', False);
  Row.AppKind     := Item.GetStr('app_kind', '');
  Row.AppWidth    := Integer(Item.GetInt('app_width', 640));
  Row.AppHeight   := Integer(Item.GetInt('app_height', 480));
  Row.Tasks       := Integer(Item.GetInt('tasks', 0));
  Row.OpenTasks   := Integer(Item.GetInt('open_tasks', 0));
end;

function TPasClawClient.Projects: TProjectRows;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  SetLength(Result, 0);
  Root := TJsonObject.Parse(GetJSON('/v1/projects'));
  try
    Arr := Root.ChildArray('projects');
    if Arr = nil then Exit;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item <> nil then ReadProject(Item, Result[I]);
    end;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.Project(const Name: string; out Row: TProjectRow): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  try
    Obj := TJsonObject.Parse(GetJSON('/v1/projects/' + Name));
  except
    Exit;
  end;
  try
    ReadProject(Obj, Row);
    Result := Row.Name <> '';
  finally
    Obj.Free;
  end;
end;

function TPasClawClient.CreateProject(const Title: string): string;
var
  Req: TJsonObject;
begin
  Req := TJsonObject.Create;
  try
    Req.PutStr('title', Title);
    Result := JsonReadStr(Request('POST', '/v1/projects', Req.ToJSON), 'name', '');
  finally
    Req.Free;
  end;
end;

function TPasClawClient.DeleteProject(const Name: string): Boolean;
begin
  Result := True;
  try
    Request('DELETE', '/v1/projects/' + Name, '');
  except
    Result := False;
  end;
end;

{ ---- tasks + jobs ---- }

function TPasClawClient.Tasks(const Project: string): TTaskRows;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  SetLength(Result, 0);
  Root := TJsonObject.Parse(GetJSON('/v1/projects/' + Project + '/tasks'));
  try
    Arr := Root.ChildArray('tasks');
    if Arr = nil then Exit;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item = nil then Continue;
      Result[I].Id      := Item.GetStr('id', '');
      Result[I].Project := Item.GetStr('project', Project);
      Result[I].Title   := Item.GetStr('title', '');
      Result[I].Status  := Item.GetStr('status', 'todo');
      Result[I].Notes   := Item.GetStr('notes', '');
      Result[I].Jobs    := Integer(Item.GetInt('jobs', 0));
    end;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.CreateTask(const Project, Title: string): string;
var
  Req: TJsonObject;
begin
  Req := TJsonObject.Create;
  try
    Req.PutStr('title', Title);
    Result := JsonReadStr(
      Request('POST', '/v1/projects/' + Project + '/tasks', Req.ToJSON), 'id', '');
  finally
    Req.Free;
  end;
end;

function TPasClawClient.UpdateTaskStatus(const Project, TaskId, Status: string): Boolean;
var
  Req: TJsonObject;
begin
  Req := TJsonObject.Create;
  try
    Req.PutStr('status', Status);
    Result := True;
    try
      Request('PATCH', '/v1/projects/' + Project + '/tasks/' + TaskId, Req.ToJSON);
    except
      Result := False;
    end;
  finally
    Req.Free;
  end;
end;

function TPasClawClient.Jobs(const Project, TaskId: string): TJobRows;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  SetLength(Result, 0);
  Root := TJsonObject.Parse(
    GetJSON('/v1/projects/' + Project + '/tasks/' + TaskId + '/jobs'));
  try
    Arr := Root.ChildArray('jobs');
    if Arr = nil then Exit;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item = nil then Continue;
      Result[I].Id        := Item.GetStr('id', '');
      Result[I].Project   := Item.GetStr('project', Project);
      Result[I].Task      := Item.GetStr('task', TaskId);
      Result[I].Status    := Item.GetStr('status', '');
      Result[I].SessionId := Item.GetStr('session_id', '');
      Result[I].Started   := Item.GetStr('started', '');
      Result[I].Ended     := Item.GetStr('ended', '');
      Result[I].Summary   := Item.GetStr('summary', '');
    end;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.JobLog(const Project, TaskId, JobId: string): string;
begin
  Result := JsonReadStr(
    GetJSON('/v1/projects/' + Project + '/tasks/' + TaskId + '/jobs/' + JobId + '/log'),
    'log', '');
end;

{ ---- apps ---- }

function TPasClawClient.App(const Project: string; out Row: TAppRow): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  FillChar(Row, SizeOf(Row), 0);
  Row.Name := ''; Row.Kind := ''; Row.Entry := ''; Row.Icon := '';
  Row.Network := ''; Row.Env := ''; Row.URL := '';
  try
    Obj := TJsonObject.Parse(GetJSON('/v1/apps/' + Project));
  except
    Exit;
  end;
  try
    Row.Exists   := Obj.GetBool('exists', False);
    Row.Ready    := Obj.GetBool('ready', False);
    Row.Servable := Obj.GetBool('servable', False);
    Row.Name     := Obj.GetStr('name', Project);
    Row.Kind     := Obj.GetStr('kind', '');
    Row.Entry    := Obj.GetStr('entry', '');
    Row.Icon     := Obj.GetStr('icon', '');
    Row.Network  := Obj.GetStr('network', '');
    Row.Env      := Obj.GetStr('env', '');
    Row.URL      := Obj.GetStr('url', '');
    Row.Width    := Integer(Obj.GetInt('width', 640));
    Row.Height   := Integer(Obj.GetInt('height', 480));
    Result := True;
  finally
    Obj.Free;
  end;
end;

function TPasClawClient.AppURL(const Project: string): string;
begin
  Result := FBaseURL + '/apps/' + Project + '/';
end;

function TPasClawClient.StateGet(const Project, Key: string;
  out Value: string): Boolean;
var
  Obj: TJsonObject;
begin
  Value := '';
  Result := False;
  try
    Obj := TJsonObject.Parse(GetJSON('/v1/apps/' + Project + '/state/' + Key));
  except
    Exit;
  end;
  try
    Result := Obj.GetBool('exists', False);
    if Result then Value := Obj.GetStr('value', '');
  finally
    Obj.Free;
  end;
end;

function TPasClawClient.StateSet(const Project, Key, Value: string): Boolean;
begin
  Result := True;
  try
    Request('PUT', '/v1/apps/' + Project + '/state/' + Key, Value);
  except
    Result := False;
  end;
end;

{ ---- pages ---- }

function TPasClawClient.Pages: TPageRows;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
begin
  SetLength(Result, 0);
  Root := TJsonObject.Parse(GetJSON('/v1/pages'));
  try
    Arr := Root.ChildArray('pages');
    if Arr = nil then Exit;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item = nil then Continue;
      Result[I].Id          := Item.GetStr('id', '');
      Result[I].Title       := Item.GetStr('title', '');
      Result[I].Query       := Item.GetStr('query', '');
      Result[I].Kind        := Item.GetStr('kind', '');
      Result[I].Created     := Item.GetStr('created', '');
      Result[I].URL         := Item.GetStr('url', '');
      Result[I].SourceCount := Integer(Item.GetInt('source_count', 0));
    end;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.PageURL(const Id: string): string;
begin
  Result := FBaseURL + '/pages/' + Id + '/';
end;

function TPasClawClient.CreatePage(const Query: string; out Id: string): Boolean;
var
  Req: TJsonObject;
begin
  Id := '';
  Req := TJsonObject.Create;
  try
    Req.PutStr('query', Query);
    Req.PutStr('kind', 'search');
    try
      Id := JsonReadStr(Request('POST', '/v1/pages', Req.ToJSON), 'id', '');
    except
      Id := '';
    end;
  finally
    Req.Free;
  end;
  Result := Id <> '';
end;

{ ---- chat ---- }

function TPasClawClient.Chat(const HistoryJSON, System_: string;
  OnChunk: TChatChunkProc): string;
var
  Http: TIdHTTP;
  Req: TStringStream;
  Sink: TSSEStream;
  Root: TJsonObject;
  Msgs, Hist: TJsonArray;
  Sys: TJsonObject;
  I: Integer;
  Item: TJsonObject;
begin
  Result := '';
  FLastError := '';

  Root := TJsonObject.Create;
  Sink := TSSEStream.Create(OnChunk);
  Req  := nil;
  Http := NewHttp(FToken, FTimeoutMs);
  try
    Msgs := TJsonArray.Create;
    { A system message leads the array -- the gateway lets a client system
      prompt win over its own default, which is how builder mode reaches
      the model without a server-side flag. }
    if Trim(System_) <> '' then
    begin
      Sys := TJsonObject.Create;
      Sys.PutStr('role', 'system');
      Sys.PutStr('content', System_);
      Msgs.AddObject(Sys);
    end;
    if Trim(HistoryJSON) <> '' then
    begin
      Hist := nil;
      try
        Hist := TJsonArray.Parse(HistoryJSON);
      except
        Hist := nil;
      end;
      if Hist <> nil then
        try
          for I := 0 to Hist.Count - 1 do
          begin
            Item := Hist.ItemObject(I);
            if Item = nil then Continue;
            Msgs.AddRaw(Item.ToJSON);
          end;
        finally
          Hist.Free;
        end;
    end;
    Root.PutArray('messages', Msgs);
    Root.PutBool('stream', True);

    Http.Request.Accept := 'text/event-stream';
    Req := TStringStream.Create(Root.ToJSON);
    try
      Http.Post(FBaseURL + '/v1/chat/completions', Req, Sink);
    except
      on E: EAbort do
        { caller stopped the stream -- keep what arrived }
        ;
      on E: EIdHTTPProtocolException do
        FLastError := JsonReadStr(E.ErrorMessage, 'error', E.Message);
      on E: Exception do
        FLastError := E.Message;
    end;
    Result := Sink.Text;
  finally
    Http.Free;
    Req.Free;
    Sink.Free;
    Root.Free;
  end;
end;

end.
