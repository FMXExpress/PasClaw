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
    (* The whole response body, not just the "error" field.

       A 409 from the run route is the clearest case: refusing to start
       without consent, it hands back the exact command the caller must show
       the user. Reducing that to its error string would throw away the only
       part that matters. *)
    Body: string;
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

  { One saved conversation. The Library lists these beside pages, and
    opening one is how you get back into a chat you left. }
  TSessionRow = record
    Id, Title, Model, Provider: string;
    Updated: Int64;
  end;
  TSessionRows = array of TSessionRow;

  { What a running process app is doing. Backend is 'host', 'docker' or
    'docker-remote' -- three genuinely different places, and the user should
    never have to guess which one their app is in. }
  TRunRow = record
    Project, State, Started, Command, Backend, Error, URL: string;
    Port, ExitCode: Integer;
  end;

  { One row of a directory listing from /v1/fs. }
  TFileRow = record
    Name: string;
    Size: Int64;
    IsDir: Boolean;
  end;
  TFileRows = array of TFileRow;

  { A directory: its path, its rows, and the two roots the gateway offers as
    quick-switch destinations. }
  TDirListing = record
    Path:          string;
    WorkspaceRoot: string;
    CwdRoot:       string;
    Rows:          TFileRows;
  end;

  { The kinds of answer page. Research is the multi-step mode -- plan, read
    several independent sources, synthesise -- and the one that narrates. }
  TPageKindSel = (pkeSearch, pkeData, pkeReport, pkeResearch);

  { Called for each streamed chunk of an assistant reply. Set Abort to stop. }
  TChatChunkProc = procedure(const Chunk: string; var Abort: Boolean) of object;

  (* Called as the model uses a tool, if the caller wants to watch.

     The gateway already narrates tool use as SSE comments beside the text
     stream; without somewhere to send them a client shows prose only, so
     "build me an app" looks like a long silence followed by an answer, with
     no sign of the dozen file writes that actually did the work.

     Kind is 'call' or 'result'. For a call, Detail is the (capped) argument
     summary; for a result it is the result text, or the error when Err is
     True. *)
  TToolTraceProc = procedure(const Kind, Name, Detail: string;
    IsErr: Boolean) of object;

  (* ---- request tracing ----

     Every call this client makes to the gateway, reported as it completes.

     This is the half of the picture the gateway's own log cannot give you.
     Its log is filtered server-side by log level before anything is
     recorded, so a client asking for more detail cannot get it; and even at
     debug it says what the SERVER did, never what a particular window
     asked for. Tracing here is unconditional, costs a callback, and answers
     the question a desktop actually raises -- "what did this window just
     do, and what came back".

     Origin is the context the call was made under (see SetClientContext):
     which window, which conversation. Without it a busy desktop's traffic
     is one undifferentiated stream, because a single shared client serves
     every window.

     Millis is wall time for the whole call. Status is the HTTP status, or 0
     when the request never got an answer -- in which case Note carries the
     reason. *)
  TRequestTraceProc = procedure(const Origin, Method, Path: string;
    Status, Millis: Integer; const Note: string) of object;

  (* ---- period-native output ----

     The web desktop renders structured agent output as real UI: a plan
     becomes a wizard, a question becomes a message box. The CONVENTION is a
     fenced ```pasclaw-ui block carrying one JSON object; recognising it is
     pure string work, so it lives here rather than in either client. That
     way the FMX desktop renders the same furniture from the same rules, and
     the rules are testable without a UI toolkit.

     Fail-safe by construction: text outside a block is untouched, and a
     block that does not parse is LEFT IN the visible text rather than
     silently swallowed. An answer must never disappear. *)
  TUIBlockKind = (ubNone, ubWizard, ubMessage, ubAsk);

  TUIStep = record
    Title: string;
    Body:  string;
  end;
  TUISteps = array of TUIStep;

  TUIButton = record
    Caption: string;
    Value:   string;
  end;
  TUIButtons = array of TUIButton;

  TUIBlock = record
    Kind:    TUIBlockKind;
    Title:   string;
    Text:    string;
    Kind_:   string;      { info | ask | warn | stop, for message boxes }
    Steps:   TUISteps;
    Buttons: TUIButtons;
  end;
  TUIBlocks = array of TUIBlock;

  { One desktop event off /v1/desktop/events. }
  TDesktopEvent = record
    Seq:     Int64;
    EvType:  string;   { projects | project | task | job | joblog | app | page |
                         page-progress | workspace | hello | gap }
    Project: string;
    Task:    string;
    Id:      string;
    Status:  string;
    Line:    string;
    Raw:     string;
  end;

  { Called for each event as it arrives. Set Stop to end the subscription. }
  TDesktopEventProc = procedure(const Ev: TDesktopEvent; var Stop: Boolean) of object;

  { One line off the gateway's log stream, already split into its level tag
    and body so a viewer can colour or filter without re-parsing. }
  TLogLineProc = procedure(const Level, Text_: string;
    var Stop: Boolean) of object;

  TPasClawClient = class
  private
    FBaseURL: string;
    FToken: string;
    FTimeoutMs: Integer;
    FModelTimeoutMs: Integer;
    FLastError: string;
    FOnTrace: TRequestTraceProc;
    procedure Trace(const Method, Path: string; Status, Millis: Integer;
      const Note: string);
    function Request(const Method, Path, Body: string): string;
    function RequestT(const Method, Path, Body: string;
      TimeoutMs: Integer): string;
    function GetJSON(const Path: string): string;
  public
    constructor Create(const ABaseURL: string = 'http://127.0.0.1:8088');
    { Base URL without a trailing slash; setting it normalises. }
    property BaseURL: string read FBaseURL write FBaseURL;
    property Token: string read FToken write FToken;
    (* Two clocks, because there are two kinds of call.

       A board read is a database hit: if it has not answered in seconds,
       something is wrong and failing fast is the useful behaviour. A call
       that goes through the MODEL is a different animal -- deep research
       plans, reads several sources and synthesises, and the gateway holds
       the request open with nothing on the wire for the whole turn. Judging
       that by the same clock is what made the Browser give up mid-answer.

       Still bounded rather than infinite: a genuinely dead gateway should
       eventually surface as an error rather than a window that waits
       forever. Streaming calls have their own liveness signal (chunks keep
       arriving) and set no read timeout at all. *)
    property TimeoutMs: Integer read FTimeoutMs write FTimeoutMs;
    property ModelTimeoutMs: Integer read FModelTimeoutMs write FModelTimeoutMs;
    property LastError: string read FLastError;
    (* Set it and every call this client makes is reported. Nothing else
       turns it on: tracing that needs enabling is tracing you do not have
       when the thing you wanted to see already happened. *)
    property OnTrace: TRequestTraceProc read FOnTrace write FOnTrace;

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

    { ---- process apps ---- }
    (* Start a process app. Consent is not a formality: without it the
       gateway answers 409 and hands back the exact command, which is what a
       client must show the user BEFORE asking. PlannedCommand gets that
       command without starting anything. *)
    function PlannedCommand(const Project: string; out Cmd: string): Boolean;
    function RunApp(const Project: string; out Row: TRunRow;
      out Err: string): Boolean;
    function StopApp(const Project: string): Boolean;
    function RunState(const Project: string; out Row: TRunRow): Boolean;
    function RunLog(const Project: string): string;

    (* Read and replace an app's entry file. The pair behind artifact
       versions: a client captures the body a turn produced and can put it
       back later. PutAppEntry writes ONE file -- the entry the manifest
       already declares. *)
    function AppEntry(const Project: string): string;
    function PutAppEntry(const Project, Body: string): Boolean;

    { ---- files ---- }
    (* Browse the workspace. Sandbox-checked and secret-filtered server-side,
       so a client shows exactly what the operator surface will show. Pass an
       empty path for the gateway's default landing directory.

       Listing is `var`, not `out`, on purpose. The natural way to descend is
       ListDir(D.Path + '/sub', D) -- and with an `out` parameter the
       compiler is free to clear D BEFORE evaluating that expression, so the
       path silently becomes '/sub'. That cost an afternoon once; `var` makes
       the idiom mean what it reads like. *)
    function ListDir(const Path: string; var Listing: TDirListing): Boolean;
    (* Read a file. Binary says so rather than handing back mojibake, and
       Truncated says so rather than quietly showing the first slice of a
       log as if it were the whole thing. *)
    function ReadFile_(const Path: string; out Content: string;
      out Binary, Truncated: Boolean): Boolean;

    { ---- pages ---- }
    function Pages: TPageRows;
    function PageURL(const Id: string): string;
    { Ask the gateway to research a query and render it as a page. Returns the
      new page id. Needs a gateway with an agent attached. }
    function CreatePage(const Query: string; out Id: string): Boolean;
    { The same, with the mode chosen. Research takes minutes and narrates
      through page-progress events; the others come back in one go. }
    function CreatePageOfKind(const Query: string; Kind: TPageKindSel;
      out Id: string): Boolean;
    (* "Make this interactive" -- copy a page into a new project as an html
       app. The page stays in the history: it is the record of an answer at a
       time, and the app is the part that changes. *)
    function PromotePage(const PageId: string; out Project: string): Boolean;

    { ---- desktop state ---- }
    (* The window layout, stored per WORKSPACE on the gateway rather than per
       client. Both desktops read and write the same document, so a layout
       arranged in one is the layout the other opens with. *)
    function DesktopState: string;
    function SetDesktopState(const JSON: string): Boolean;
    (* The same two, against a NAMED desktop instead of whichever is current.

       Paging desks is save-here then switch-there, and "here" stops being
       current the moment the switch lands. Anything that saves without
       naming the desktop -- a deferred autosave that fires after the
       switch, say -- writes the wrong layout to the wrong desk, and the
       arrangement the user had is simply gone. Naming the number removes
       the ordering question entirely. N < 1 means "current", so these are
       a superset of the two above. *)
    function DesktopStateFor(N: Integer): string;
    function SetDesktopStateFor(N: Integer; const JSON: string): Boolean;
    (* Desktops inside the workspace: numbered layouts, like a pager.
       Switching one is cheap and invisible to the agent -- the whole
       difference from a workspace switch. *)
    function Desktops(out Current, Count: Integer): Boolean;
    function SwitchDesktop(N: Integer; out Current, Count: Integer): Boolean;

    { ---- chat ---- }
    (* Stream one turn through /v1/chat/completions. History is a JSON array
       of {"role","content"} objects; System, when non-empty, is sent as the
       leading system message. OnChunk receives assistant text as it arrives.
       Returns the full reply. *)
    function Chat(const HistoryJSON, System_: string;
      OnChunk: TChatChunkProc): string; overload;
    (* The same turn, with the model's tool use narrated. Separate overload
       rather than a nil-able extra parameter on the one above so existing
       callers are untouched. *)
    function Chat(const HistoryJSON, System_: string;
      OnChunk: TChatChunkProc; OnTool: TToolTraceProc): string; overload;

    (* Subscribe to /v1/desktop/events and pump until the callback stops it or
       the connection drops. BLOCKS -- run it on its own thread. The FMX
       client does exactly that, which is how its tree updates while an agent
       works instead of waiting for a refresh click. *)
    procedure WatchEvents(OnEvent: TDesktopEventProc);

    { ---- library ---- }
    (* Saved conversations, newest first as the gateway orders them. Pages
       answer "what did I look up"; these answer "what did I talk about",
       and the Library window wants both. *)
    function Sessions: TSessionRows;
    (* One session's messages, as the JSON array a chat window seeds its
       history from -- the same [{role,content}] shape Chat sends back, so
       reopening a conversation is loading it, not re-deriving it. Empty
       array when the session is gone or unreadable: an unopenable session
       should give you a blank window, not an exception. *)
    function SessionHistory(const Id: string): string;

    { ---- logs ---- }
    (* Subscribe to /v1/logs. Same shape as WatchEvents -- BLOCKS, so run it
       on its own thread -- and the gateway replays its recent ring buffer
       before going live, so a viewer opens with history rather than waiting
       for the next line.

       What arrives is bounded by the GATEWAY's log level, not by anything
       a client can ask for: a line below that level was never recorded and
       cannot be recovered here. Debug output needs gateway.log_level set to
       "debug" on the server. *)
    procedure WatchLogs(OnLine: TLogLineProc);

    { ---- raw bytes ---- }
    (* A bounded window of a file's bytes, for the hex viewer: a binary file
       is worth looking at, and downloading a 2 GB one to show 256 bytes of
       it is not. Total comes back as the file's real size so a viewer can
       page. Len is capped at 64 KB by the gateway. *)
    function PeekFile(const Path: string; Offset, Len: Int64;
      out Data: TBytes; out Total: Int64): Boolean;
  end;

(* Split an assistant reply into the text a human reads and the UI blocks a
   client should render. Both clients call this on every finished turn. *)
procedure ParseUIBlocks(const Reply: string; out VisibleText: string;
  out Blocks: TUIBlocks);

(* ---- the calling context ----

   Names whoever is about to make requests, so a trace can say which window
   or conversation a call came from. Per THREAD, not per client: one client
   object serves every window, and the deep-research call runs on its own
   thread while the main one keeps serving the board -- a single shared
   field would attribute whichever finished last to whoever set it first.

   Callers set it at the top of an operation and are not required to clear
   it; the next Set on that thread replaces it. '' means unattributed,
   which a trace should render rather than hide. *)
procedure SetClientContext(const Name: string);
function ClientContext: string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils,
  DateUtils,                 { MilliSecondsBetween -- request timing }
  IdHTTP, IdGlobal, IdSSLOpenSSL, IdComponent;

threadvar
  GContext: string;

procedure SetClientContext(const Name: string);
begin
  GContext := Name;
end;

function ClientContext: string;
begin
  Result := GContext;
end;

type
  { Indy hands us the body as it arrives; this feeds the caller's callback
    without buffering the whole SSE stream first. }
  TSSEStream = class(TStream)
  private
    FBuf: string;
    FText: string;
    FOnChunk: TChatChunkProc;
    FOnTool: TToolTraceProc;
    FAbort: Boolean;
    procedure Consume(const Data: string);
    procedure HandleToolComment(const Payload: string);
  public
    constructor Create(AOnChunk: TChatChunkProc;
      AOnTool: TToolTraceProc = nil);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    property Text: string read FText;
    property Aborted: Boolean read FAbort;
  end;

constructor TSSEStream.Create(AOnChunk: TChatChunkProc;
  AOnTool: TToolTraceProc);
begin
  inherited Create;
  FOnChunk := AOnChunk;
  FOnTool := AOnTool;
end;

(* One ": pasclaw-tool {...}" comment off the chat stream.

   These ride the SSE channel as comments precisely so a client that does
   not care keeps working: an OpenAI-compatible consumer skips them without
   knowing they exist. A client that DOES care gets the model's working
   shown. *)
procedure TSSEStream.HandleToolComment(const Payload: string);
var
  Obj: TJsonObject;
  Kind, Name, Detail: string;
  IsErr: Boolean;
begin
  if not Assigned(FOnTool) then Exit;
  try
    Obj := TJsonObject.Parse(Payload);
  except
    Exit;
  end;
  if Obj = nil then Exit;
  try
    Kind := Obj.GetStr('t', '');
    Name := Obj.GetStr('name', '');
    if Kind = 'call' then
    begin
      Detail := Obj.GetStr('args', '');
      IsErr := False;
    end
    else
    begin
      Detail := Obj.GetStr('err', '');
      IsErr := Detail <> '';
      if not IsErr then Detail := Obj.GetStr('result', '');
    end;
    if Name <> '' then FOnTool(Kind, Name, Detail, IsErr);
  finally
    Obj.Free;
  end;
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
    (* The gateway's ": pasclaw-tool ..." SSE comments carry tool detail.
       Routed to the trace callback when a caller wants it, skipped
       otherwise -- which is what keeps a plain OpenAI client working
       against this stream. Paren-star delimiters because a brace in the
       example would close the comment. *)
    if Line = '' then Continue;
    if Line[1] = ':' then
    begin
      if HasPrefix(Line, ': pasclaw-tool ') then
        HandleToolComment(Trim(Copy(Line, 16, MaxInt)));
      Continue;
    end;
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


{ ------------------------------------------------------- UI block parsing -- }

function ParseOneUIBlock(const JSONText: string; out Block: TUIBlock): Boolean;
var
  Obj, Item: TJsonObject;
  Arr: TJsonArray;
  I, N: Integer;
  UI: string;
begin
  Result := False;
  FillChar(Block, SizeOf(Block), 0);
  Block.Kind := ubNone;
  Block.Title := ''; Block.Text := ''; Block.Kind_ := '';
  SetLength(Block.Steps, 0);
  SetLength(Block.Buttons, 0);

  try
    Obj := TJsonObject.Parse(JSONText);
  except
    Exit;   { unparseable -> the caller leaves it as visible text }
  end;
  try
    UI := LowerCase(Trim(Obj.GetStr('ui', '')));
    if      UI = 'wizard'  then Block.Kind := ubWizard
    else if UI = 'message' then Block.Kind := ubMessage
    else if UI = 'ask'     then Block.Kind := ubAsk
    else Exit;

    Block.Title := Obj.GetStr('title', '');
    Block.Text  := Obj.GetStr('text', '');
    Block.Kind_ := LowerCase(Obj.GetStr('kind', ''));
    if Block.Kind_ = '' then
      if Block.Kind = ubAsk then Block.Kind_ := 'ask' else Block.Kind_ := 'info';

    Arr := Obj.ChildArray('steps');
    if Arr <> nil then
    begin
      SetLength(Block.Steps, Arr.Count);
      N := 0;
      for I := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(I);
        if Item = nil then Continue;
        Block.Steps[N].Title := Item.GetStr('title', '');
        Block.Steps[N].Body  := Item.GetStr('body', '');
        if (Block.Steps[N].Title = '') and (Block.Steps[N].Body = '') then Continue;
        Inc(N);
      end;
      SetLength(Block.Steps, N);
    end;

    Arr := Obj.ChildArray('buttons');
    if Arr <> nil then
    begin
      SetLength(Block.Buttons, Arr.Count);
      N := 0;
      for I := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(I);
        if Item = nil then Continue;
        Block.Buttons[N].Caption := Item.GetStr('label', '');
        Block.Buttons[N].Value   := Item.GetStr('value', Block.Buttons[N].Caption);
        if Block.Buttons[N].Caption = '' then Continue;
        Inc(N);
      end;
      SetLength(Block.Buttons, N);
    end;

    { A wizard with no steps is not a wizard; rendering an empty one would be
      worse than leaving the text. }
    if (Block.Kind = ubWizard) and (Length(Block.Steps) = 0) then Exit;
    { A question with no buttons gets one, so it can at least be dismissed. }
    if (Block.Kind in [ubMessage, ubAsk]) and (Length(Block.Buttons) = 0) then
    begin
      SetLength(Block.Buttons, 1);
      Block.Buttons[0].Caption := 'OK';
      Block.Buttons[0].Value   := 'OK';
    end;
    Result := True;
  finally
    Obj.Free;
  end;
end;

procedure ParseUIBlocks(const Reply: string; out VisibleText: string;
  out Blocks: TUIBlocks);
const
  Fence = '```pasclaw-ui';
var
  Rest, Body, Before: string;
  P, Q: Integer;
  Block: TUIBlock;
begin
  VisibleText := Reply;
  SetLength(Blocks, 0);
  if Pos(Fence, Reply) = 0 then Exit;

  VisibleText := '';
  Rest := Reply;
  repeat
    P := Pos(Fence, Rest);
    if P = 0 then
    begin
      VisibleText := VisibleText + Rest;
      Break;
    end;
    Before := Copy(Rest, 1, P - 1);
    Rest := Copy(Rest, P + Length(Fence), MaxInt);
    { Body runs to the closing fence. An unterminated block is malformed:
      put the whole thing back rather than swallowing the rest of the reply. }
    Q := Pos('```', Rest);
    if Q = 0 then
    begin
      VisibleText := VisibleText + Before + Fence + Rest;
      Break;
    end;
    Body := Copy(Rest, 1, Q - 1);
    Rest := Copy(Rest, Q + 3, MaxInt);

    if ParseOneUIBlock(Body, Block) then
    begin
      SetLength(Blocks, Length(Blocks) + 1);
      Blocks[High(Blocks)] := Block;
      VisibleText := VisibleText + Before;
    end
    else
      { Not a block we understand -- leave it where the model put it. }
      VisibleText := VisibleText + Before + Fence + Body + '```';
  until False;
  VisibleText := Trim(VisibleText);
end;

{ ----------------------------------------------------------- event stream -- }

type
  (* Feeds /v1/desktop/events into the caller's callback as frames arrive.
     Same shape as TSSEStream above; different payload. *)
  TEventStream = class(TStream)
  private
    FBuf: string;
    FOnEvent: TDesktopEventProc;
    FStop: Boolean;
    procedure Consume(const Data: string);
  public
    constructor Create(AOnEvent: TDesktopEventProc);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
    property Stopped: Boolean read FStop;
  end;

  { The same sink shape for /v1/logs. Separate class rather than a mode flag
    on the one above: the payloads have nothing in common -- one is a JSON
    object, one is a bracketed line -- and a stream that had to ask which it
    was would be harder to read than two that each know. }
  TLogStream = class(TStream)
  private
    FBuf: string;
    FOnLine: TLogLineProc;
    FStop: Boolean;
    procedure Consume(const Data: string);
  public
    constructor Create(AOnLine: TLogLineProc);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

constructor TEventStream.Create(AOnEvent: TDesktopEventProc);
begin
  inherited Create;
  FOnEvent := AOnEvent;
end;

function TEventStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TEventStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

procedure TEventStream.Consume(const Data: string);
var
  NL: Integer;
  Line, Payload: string;
  Obj: TJsonObject;
  Ev: TDesktopEvent;
begin
  FBuf := FBuf + Data;
  repeat
    NL := Pos(#10, FBuf);
    if NL = 0 then Break;
    Line := Copy(FBuf, 1, NL - 1);
    Delete(FBuf, 1, NL);
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    if (Line = '') or (Line[1] = ':') then Continue;   { blank / keepalive }
    if not HasPrefix(Line, 'data:') then Continue;
    Payload := Trim(Copy(Line, 6, MaxInt));
    if Payload = '' then Continue;

    FillChar(Ev, SizeOf(Ev), 0);
    Ev.EvType := ''; Ev.Project := ''; Ev.Task := '';
    Ev.Id := ''; Ev.Status := ''; Ev.Line := '';
    Ev.Raw := Payload;
    try
      Obj := TJsonObject.Parse(Payload);
    except
      Continue;
    end;
    try
      Ev.Seq     := Obj.GetInt('seq', 0);
      Ev.EvType  := Obj.GetStr('type', '');
      Ev.Project := Obj.GetStr('project', '');
      Ev.Task    := Obj.GetStr('task', '');
      Ev.Id      := Obj.GetStr('id', '');
      Ev.Status  := Obj.GetStr('status', '');
      Ev.Line    := Obj.GetStr('line', '');
      { page-progress carries its own two fields. Mapping them onto Status
        and Line keeps the record flat -- a client that shows "what is it
        doing" reads the same two fields whatever produced them. }
      if Ev.EvType = 'page-progress' then
      begin
        Ev.Status := Obj.GetStr('phase', '');
        Ev.Line   := Obj.GetStr('detail', '');
      end;
    finally
      Obj.Free;
    end;
    if Assigned(FOnEvent) then
      FOnEvent(Ev, FStop);
    if FStop then Break;
  until False;
end;

function TEventStream.Write(const Buffer; Count: Longint): Longint;
var
  S: AnsiString;
begin
  Result := Count;
  if Count <= 0 then Exit;
  SetLength(S, Count);
  Move(Buffer, S[1], Count);
  Consume(string(S));
  { Indy offers no cancel hook on the content stream, so a caller-requested
    stop unwinds through an exception the subscriber catches. }
  if FStop then
    raise EAbort.Create('event subscription stopped by caller');
end;

{ --------------------------------------------------------------- client -- }

constructor TPasClawClient.Create(const ABaseURL: string);
begin
  inherited Create;
  FBaseURL := ABaseURL;
  while (FBaseURL <> '') and (FBaseURL[Length(FBaseURL)] = '/') do
    SetLength(FBaseURL, Length(FBaseURL) - 1);
  FTimeoutMs := 30000;
  FModelTimeoutMs := 20 * 60 * 1000;   { deep research runs for minutes }
end;

function UrlEncode_(const S: string): string;
var
  I: Integer;
  C: Char;
begin
  Result := '';
  for I := 1 to Length(S) do
  begin
    C := S[I];
    if (C in ['A'..'Z', 'a'..'z', '0'..'9', '-', '_', '.', '~', '/']) then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Ord(C), 2);
  end;
end;

(* ReadTimeoutMs of 0 means "wait indefinitely for the body" -- correct for
   a stream whose liveness is the arrival of chunks. ConnectTimeout is kept
   separate and never infinite: a gateway that is not listening should fail
   in seconds, whatever the body clock says, or the UI hangs on a typo in
   the address. *)
function NewHttp(const Token: string; ReadTimeoutMs: Integer;
  ConnectTimeoutMs: Integer = 15000): TIdHTTP;
begin
  Result := TIdHTTP.Create(nil);
  Result.HandleRedirects := True;
  Result.ConnectTimeout  := ConnectTimeoutMs;
  Result.ReadTimeout     := ReadTimeoutMs;
  Result.Request.ContentType := 'application/json';
  Result.Request.Accept      := 'application/json';
  if Token <> '' then
    Result.Request.CustomHeaders.AddValue('Authorization', 'Bearer ' + Token);
  { A gateway reached over https (a tunnel, a remote box) needs the TLS
    handler; a local http gateway never touches it. }
  Result.IOHandler := TIdSSLIOHandlerSocketOpenSSL.Create(Result);
end;

constructor TLogStream.Create(AOnLine: TLogLineProc);
begin
  inherited Create;
  FOnLine := AOnLine;
end;

function TLogStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TLogStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

function TLogStream.Write(const Buffer; Count: Longint): Longint;
var
  S: AnsiString;
begin
  Result := Count;
  if Count <= 0 then Exit;
  SetLength(S, Count);
  Move(Buffer, S[1], Count);
  Consume(string(S));
  if FStop then
    raise EAbort.Create('log subscription stopped by caller');
end;

procedure TLogStream.Consume(const Data: string);
var
  NL, Close_: Integer;
  Line, Payload, Level, Body: string;
  Obj: TJsonObject;
begin
  FBuf := FBuf + Data;
  repeat
    NL := Pos(#10, FBuf);
    if NL = 0 then Break;
    Line := Copy(FBuf, 1, NL - 1);
    Delete(FBuf, 1, NL);
    Line := StringReplace(Line, #13, '', [rfReplaceAll]);
    if (Line = '') or (Line[1] = ':') then Continue;   { blank / keepalive }
    if not HasPrefix(Line, 'data:') then Continue;
    Payload := Trim(Copy(Line, 6, MaxInt));
    if Payload = '' then Continue;

    { The gateway JSON-escapes the line but does not quote it. Round-tripping
      it through the parser as a one-field object is cheaper than a second
      unescaper that could disagree with the first. }
    Obj := nil;
    try
      Obj := TJsonObject.Parse('{"m":"' + Payload + '"}');
    except
      Obj := nil;
    end;
    if Obj <> nil then
    begin
      try
        Payload := Obj.GetStr('m', Payload);
      finally
        Obj.Free;
      end;
    end;

    { "[info] listening on ..." -> level + body. A line that does not carry
      a tag is still a line; it is shown at info rather than dropped. }
    Level := 'info';
    Body  := Payload;
    if (Payload <> '') and (Payload[1] = '[') then
    begin
      Close_ := Pos(']', Payload);
      if Close_ > 2 then
      begin
        Level := Copy(Payload, 2, Close_ - 2);
        Body  := TrimLeft(Copy(Payload, Close_ + 1, MaxInt));
      end;
    end;

    if Assigned(FOnLine) then
      FOnLine(Level, Body, FStop);
    if FStop then Break;
  until False;
end;

procedure TPasClawClient.WatchLogs(OnLine: TLogLineProc);
var
  Http: TIdHTTP;
  Sink: TLogStream;
begin
  FLastError := '';
  Sink := TLogStream.Create(OnLine);
  Http := NewHttp(FToken, 0);
  try
    { Same deal as WatchEvents: an open, mostly-idle connection. }
    Http.ReadTimeout := 0;
    Http.Request.Accept := 'text/event-stream';
    try
      Http.Get(FBaseURL + '/v1/logs', Sink);
    except
      on E: EAbort do ;      { caller asked to stop }
      on E: Exception do FLastError := E.Message;
    end;
  finally
    Http.Free;
    Sink.Free;
  end;
end;

function TPasClawClient.Sessions: TSessionRows;
var
  Body: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I, N: Integer;
begin
  SetLength(Result, 0);
  Body := GetJSON('/v1/sessions');
  if Trim(Body) = '' then Exit;
  try
    Root := TJsonObject.Parse(Body);
  except
    Exit;
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('sessions');
    if Arr = nil then Exit;
    N := 0;
    SetLength(Result, Arr.Count);
    for I := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(I);
      if Item = nil then Continue;
      Result[N].Id       := Item.GetStr('id', '');
      Result[N].Title    := Item.GetStr('title', '');
      Result[N].Model    := Item.GetStr('model', '');
      Result[N].Provider := Item.GetStr('provider', '');
      Result[N].Updated  := Item.GetInt('updated', 0);
      if Result[N].Id <> '' then Inc(N);
    end;
    SetLength(Result, N);
  finally
    Root.Free;
  end;
end;

function TPasClawClient.SessionHistory(const Id: string): string;
var
  Body: string;
  Root: TJsonObject;
  Arr: TJsonArray;
begin
  Result := '[]';
  if Trim(Id) = '' then Exit;
  Body := GetJSON('/v1/sessions/' + UrlEncode_(Id));
  if Trim(Body) = '' then Exit;
  try
    Root := TJsonObject.Parse(Body);
  except
    Exit;
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('messages');
    if Arr <> nil then Result := Arr.ToJSON;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.PeekFile(const Path: string; Offset, Len: Int64;
  out Data: TBytes; out Total: Int64): Boolean;
var
  Http: TIdHTTP;
  Mem: TMemoryStream;
  Hdr: string;
  Started: TDateTime;
begin
  Result := False;
  SetLength(Data, 0);
  Total := 0;
  FLastError := '';
  Started := Now;
  Http := NewHttp(FToken, FTimeoutMs);
  Mem  := TMemoryStream.Create;
  try
    { Raw bytes, not JSON -- this is the one route whose body is the file. }
    Http.Request.Accept := 'application/octet-stream';
    try
      Http.Get(FBaseURL + '/v1/fs/peek?path=' + UrlEncode_(Path) +
               '&offset=' + IntToStr(Offset) + '&len=' + IntToStr(Len), Mem);
    except
      on E: Exception do
      begin
        FLastError := E.Message;
        Trace('GET', '/v1/fs/peek', 0,
              MilliSecondsBetween(Now, Started), E.Message);
        Exit;
      end;
    end;
    Trace('GET', '/v1/fs/peek', Http.ResponseCode,
          MilliSecondsBetween(Now, Started), Path);
    Hdr := Http.Response.RawHeaders.Values['X-File-Total'];
    Total := StrToInt64Def(Trim(Hdr), Mem.Size);
    SetLength(Data, Mem.Size);
    if Mem.Size > 0 then
    begin
      Mem.Position := 0;
      Mem.ReadBuffer(Data[0], Mem.Size);
    end;
    Result := True;
  finally
    Mem.Free;
    Http.Free;
  end;
end;

procedure TPasClawClient.WatchEvents(OnEvent: TDesktopEventProc);
var
  Http: TIdHTTP;
  Sink: TEventStream;
begin
  FLastError := '';
  Sink := TEventStream.Create(OnEvent);
  Http := NewHttp(FToken, 0);
  try
    { No read timeout: this connection is SUPPOSED to stay open and quiet.
      The gateway sends a keepalive comment every ~15s, so a genuinely dead
      socket still surfaces as a read error rather than hanging forever. }
    Http.ReadTimeout := 0;
    Http.Request.Accept := 'text/event-stream';
    try
      Http.Get(FBaseURL + '/v1/desktop/events', Sink);
    except
      on E: EAbort do ;      { caller asked to stop }
      on E: Exception do FLastError := E.Message;
    end;
  finally
    Http.Free;
    Sink.Free;
  end;
end;

function TPasClawClient.Request(const Method, Path, Body: string): string;
begin
  Result := RequestT(Method, Path, Body, FTimeoutMs);
end;

procedure TPasClawClient.Trace(const Method, Path: string;
  Status, Millis: Integer; const Note: string);
begin
  if not Assigned(FOnTrace) then Exit;
  try
    FOnTrace(ClientContext, Method, Path, Status, Millis, Note);
  except
    { A trace listener must never be able to fail the call it is watching. }
  end;
end;

function TPasClawClient.RequestT(const Method, Path, Body: string;
  TimeoutMs: Integer): string;
var
  Http: TIdHTTP;
  Req: TStringStream;
  Resp: TStringStream;
  E2: EPasClawClient;
  Started: TDateTime;
  Ms: Integer;
begin
  Result := '';
  FLastError := '';
  Started := Now;
  Http := NewHttp(FToken, TimeoutMs);
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
      Trace(Method, Path, Http.ResponseCode,
            MilliSecondsBetween(Now, Started), '');
    except
      on E: EIdHTTPProtocolException do
      begin
        { The gateway's error bodies are JSON with an "error" field; surface
          that rather than Indy's generic status text. }
        FLastError := JsonReadStr(E.ErrorMessage, 'error', E.Message);
        { Traced before the raise: a failed call is the one most worth
          seeing, and the caller may swallow this exception. }
        Trace(Method, Path, E.ErrorCode,
              MilliSecondsBetween(Now, Started), FLastError);
        E2 := EPasClawClient.Create(FLastError);
        E2.Status := E.ErrorCode;
        E2.Body   := E.ErrorMessage;
        raise E2;
      end;
      on E: Exception do
      begin
        FLastError := E.Message;
        Trace(Method, Path, 0, MilliSecondsBetween(Now, Started), E.Message);
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

{ ---- process apps ---- }

(* Percent-encode a path for a query string. Deliberately a whitelist of the
   unreserved set: a Windows path carries backslashes and a colon, and a
   filename can carry anything at all, so listing what is SAFE is the only
   version of this that stays correct. *)
{ Fill a run record from the gateway's JSON. Shared by run/stop/state so the
  three cannot drift into reporting different shapes of the same thing. }
procedure FillRun(Obj: TJsonObject; out Row: TRunRow);
begin
  Row.Project  := Obj.GetStr('project', '');
  Row.State    := Obj.GetStr('state', 'stopped');
  Row.Started  := Obj.GetStr('started', '');
  Row.Command  := Obj.GetStr('command', '');
  Row.Backend  := Obj.GetStr('backend', 'host');
  Row.Error    := Obj.GetStr('error', '');
  Row.URL      := Obj.GetStr('url', '');
  Row.Port     := Integer(Obj.GetInt('port', 0));
  Row.ExitCode := Integer(Obj.GetInt('exit_code', 0));
end;

function TPasClawClient.PlannedCommand(const Project: string;
  out Cmd: string): Boolean;
var
  Body: string;
begin
  Cmd := '';
  Result := False;
  (* Deliberately asks WITHOUT confirm. The 409 is not a failure here, it is
     the answer: it carries the exact command, which is the thing a consent
     dialog has to show. A confirmation that hides the command is theatre. *)
  Body := '';
  try
    Body := Request('POST', '/v1/apps/' + Project + '/run', '{}');
  except
    on E: EPasClawClient do
      Body := E.Body;
  end;
  Cmd := JsonReadStr(Body, 'command', '');
  Result := Cmd <> '';
end;

function TPasClawClient.RunApp(const Project: string; out Row: TRunRow;
  out Err: string): Boolean;
var
  Obj: TJsonObject;
begin
  FillChar(Row, SizeOf(Row), 0);
  Err := '';
  Result := False;
  try
    Obj := TJsonObject.Parse(
      Request('POST', '/v1/apps/' + Project + '/run', '{"confirm":true}'));
  except
    on E: EPasClawClient do
    begin
      Err := E.Message;
      Exit;
    end;
    on E: Exception do
    begin
      Err := E.Message;
      Exit;
    end;
  end;
  try
    FillRun(Obj, Row);
    Err := Row.Error;
    Result := True;
  finally
    Obj.Free;
  end;
end;

function TPasClawClient.StopApp(const Project: string): Boolean;
begin
  Result := False;
  try
    Request('POST', '/v1/apps/' + Project + '/stop', '{}');
    Result := True;
  except
    Result := False;
  end;
end;

function TPasClawClient.RunState(const Project: string; out Row: TRunRow): Boolean;
var
  Obj: TJsonObject;
begin
  FillChar(Row, SizeOf(Row), 0);
  Result := False;
  try
    Obj := TJsonObject.Parse(GetJSON('/v1/apps/' + Project + '/run'));
  except
    Exit;
  end;
  try
    FillRun(Obj, Row);
    Result := True;
  finally
    Obj.Free;
  end;
end;

function TPasClawClient.RunLog(const Project: string): string;
begin
  Result := JsonReadStr(GetJSON('/v1/apps/' + Project + '/runlog'), 'log', '');
end;

function TPasClawClient.AppEntry(const Project: string): string;
var
  Row: TAppRow;
begin
  Result := '';
  if not App(Project, Row) then Exit;
  if (not Row.Exists) or (Row.Entry = '') then Exit;
  { The served asset, not a JSON wrapper -- this is the file itself. }
  try
    Result := Request('GET', '/apps/' + Project + '/' + Row.Entry, '');
  except
    Result := '';
  end;
end;

function TPasClawClient.PutAppEntry(const Project, Body: string): Boolean;
begin
  Result := False;
  try
    Request('PUT', '/v1/apps/' + Project + '/entry', Body);
    Result := True;
  except
    Result := False;
  end;
end;

{ ---- files ---- }

function TPasClawClient.ListDir(const Path: string;
  var Listing: TDirListing): Boolean;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  I: Integer;
  Q: string;
begin
  Listing.Path := '';
  Listing.WorkspaceRoot := '';
  Listing.CwdRoot := '';
  SetLength(Listing.Rows, 0);
  Result := False;
  if Path <> '' then Q := '/v1/fs?path=' + UrlEncode_(Path) else Q := '/v1/fs';
  try
    Root := TJsonObject.Parse(GetJSON(Q));
  except
    Exit;
  end;
  try
    Listing.Path          := Root.GetStr('path', '');
    Listing.WorkspaceRoot := Root.GetStr('workspace_root', '');
    Listing.CwdRoot       := Root.GetStr('cwd_root', '');
    Arr := Root.ChildArray('entries');
    if Arr <> nil then
    begin
      SetLength(Listing.Rows, Arr.Count);
      for I := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(I);
        if Item = nil then Continue;
        Listing.Rows[I].Name  := Item.GetStr('name', '');
        Listing.Rows[I].Size  := Item.GetInt('size', 0);
        Listing.Rows[I].IsDir := Item.GetBool('dir', False);
      end;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function TPasClawClient.ReadFile_(const Path: string; out Content: string;
  out Binary, Truncated: Boolean): Boolean;
var
  Root: TJsonObject;
begin
  Content := '';
  Binary := False;
  Truncated := False;
  Result := False;
  try
    Root := TJsonObject.Parse(GetJSON('/v1/fs/read?path=' + UrlEncode_(Path)));
  except
    Exit;
  end;
  try
    Binary    := Root.GetBool('binary', False);
    Truncated := Root.GetBool('truncated', False);
    Content   := Root.GetStr('content', '');
    Result    := True;
  finally
    Root.Free;
  end;
end;

{ ---- desktop state ---- }

function TPasClawClient.DesktopState: string;
begin
  { An empty object is the honest answer for a desktop nobody has arranged
    yet, and it is also what a gateway too old to know the route leaves us
    with -- either way the caller opens an empty desktop rather than an
    error. }
  Result := '';
  try
    Result := GetJSON('/v1/desktop/state');
  except
    Result := '';
  end;
  if Trim(Result) = '' then Result := '{}';
end;

function TPasClawClient.Desktops(out Current, Count: Integer): Boolean;
var
  Body: string;
begin
  Current := 1;
  Count := 1;
  Result := False;
  try
    Body := GetJSON('/v1/desktop/desktops');
  except
    Exit;
  end;
  Current := Integer(JsonReadInt(Body, 'current', 1));
  Count   := Integer(JsonReadInt(Body, 'count', 1));
  Result := True;
end;

function TPasClawClient.SwitchDesktop(N: Integer;
  out Current, Count: Integer): Boolean;
var
  Body: string;
begin
  Current := 1;
  Count := 1;
  Result := False;
  try
    Body := Request('POST', '/v1/desktop/desktops',
                    '{"current":' + IntToStr(N) + '}');
  except
    Exit;
  end;
  Current := Integer(JsonReadInt(Body, 'current', 1));
  Count   := Integer(JsonReadInt(Body, 'count', 1));
  Result := True;
end;

function TPasClawClient.SetDesktopState(const JSON: string): Boolean;
begin
  Result := SetDesktopStateFor(0, JSON);
end;

function TPasClawClient.SetDesktopStateFor(N: Integer;
  const JSON: string): Boolean;
var
  Path: string;
begin
  Result := False;
  Path := '/v1/desktop/state';
  if N >= 1 then Path := Path + '?desktop=' + IntToStr(N);
  try
    Request('PUT', Path, JSON);
    Result := True;
  except
    Result := False;
  end;
end;

function TPasClawClient.DesktopStateFor(N: Integer): string;
var
  Path: string;
begin
  Result := '';
  Path := '/v1/desktop/state';
  if N >= 1 then Path := Path + '?desktop=' + IntToStr(N);
  try
    Result := GetJSON(Path);
  except
    Result := '';
  end;
  if Trim(Result) = '' then Result := '{}';
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

function PageKindName(K: TPageKindSel): string;
begin
  case K of
    pkeData:     Result := 'data';
    pkeReport:   Result := 'report';
    pkeResearch: Result := 'research';
    else         Result := 'search';
  end;
end;

function TPasClawClient.CreatePageOfKind(const Query: string; Kind: TPageKindSel;
  out Id: string): Boolean;
var
  Req: TJsonObject;
begin
  Id := '';
  Req := TJsonObject.Create;
  try
    Req.PutStr('query', Query);
    Req.PutStr('kind', PageKindName(Kind));
    try
      { The model clock: this call IS a turn. }
      Id := JsonReadStr(
        RequestT('POST', '/v1/pages', Req.ToJSON, FModelTimeoutMs), 'id', '');
    except
      Id := '';
    end;
  finally
    Req.Free;
  end;
  Result := Id <> '';
end;

function TPasClawClient.PromotePage(const PageId: string;
  out Project: string): Boolean;
begin
  Project := '';
  try
    Project := JsonReadStr(
      Request('POST', '/v1/pages/' + PageId + '/promote', '{}'), 'project', '');
  except
    Project := '';
  end;
  Result := Project <> '';
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
begin
  Result := Chat(HistoryJSON, System_, OnChunk, nil);
end;

function TPasClawClient.Chat(const HistoryJSON, System_: string;
  OnChunk: TChatChunkProc; OnTool: TToolTraceProc): string;
var
  Started: TDateTime;
  Code: Integer;
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
  Sink := TSSEStream.Create(OnChunk, OnTool);
  Req  := nil;
  Started := Now;
  { A streamed turn carries its own liveness: chunks keep arriving, and a
    socket that dies still raises. A read timeout here only ever fires on a
    model that is thinking hard, which is not an error. }
  Http := NewHttp(FToken, 0);
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
    { One line for the whole turn. Chunks are the interesting part while it
      runs and the chat window already shows them; the trace records what
      the call was and how long it took. }
    if FLastError = '' then Code := 200 else Code := 0;
    Trace('POST', '/v1/chat/completions', Code,
          MilliSecondsBetween(Now, Started), FLastError);
  finally
    Http.Free;
    Req.Free;
    Sink.Free;
    Root.Free;
  end;
end;

end.
