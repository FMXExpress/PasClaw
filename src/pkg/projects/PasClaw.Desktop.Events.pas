(*
  PasClaw.Desktop.Events - the desktop's event bus.

  The clients used to poll: refresh the tree, re-read the app manifest, tail a
  job log on a timer. That is fine for a board that changes when you click it,
  and wrong for one an agent is editing while you watch. This is the push side.

  Shape: an in-process fan-out to N subscribers, each holding a bounded queue.
  A subscriber is one connected SSE reader (GET /v1/desktop/events). Events are
  small JSON objects:

    {"type":"job","project":"spam-filter","task":"T0001","id":"J0001",
     "status":"running","seq":42,"ts":"..."}

  Design decisions worth stating:

  - BOUNDED QUEUES, OLDEST DROPPED. A browser tab that stops reading must not
    grow the server's memory without limit. When a queue overflows the
    subscriber gets a `{"type":"gap"}` marker instead of the lost events, and
    the client's answer to a gap is to refetch what it displays. Losing an
    event must never be able to wedge the gateway.

  - MONOTONIC seq. A client that reconnects sends Last-Event-ID; anything it
    missed while disconnected shows up as a gap, and it refetches. We do not
    keep a replay buffer: the state is on disk and cheap to re-read, so
    replay would be more machinery for less certainty.

  - PUBLISHING IS NON-BLOCKING and safe from any thread. Job progress arrives
    on agent threads, app exits on drain threads, and file changes on request
    threads.
*)
unit PasClaw.Desktop.Events;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs;

type
  { A subscriber handle. Created by DesktopSubscribe, freed by
    DesktopUnsubscribe. }
  TEventSubscriber = class
  private
    FQueue: TStringList;
    FLock: TCriticalSection;
    FDropped: Boolean;
    FSignal: TEvent;
  public
    (* Who this reader is, as the browser names itself on connect.

       A desktop command reaches EVERY connected screen, which is what
       you want for "tile the windows" -- every screen tidies. It is not
       what you want for "build me an app": two tabs open meant two
       build turns for the same project, racing on the same app
       directory and the same session file (reproduced: one command,
       two identical turns, and one turn's history lost). Side-effecting
       actions need exactly one executor, so the server names one and
       the clients compare. *)
    ClientId: string;
    constructor Create;
    destructor Destroy; override;
    { Take up to Max queued events. Returns '' when there is nothing. Each
      returned line is one complete JSON object. }
    function Drain(Max: Integer = 64): TStringList;   { caller frees }
    { Block until an event arrives or the timeout expires. Lets an SSE
      handler sleep instead of spinning. }
    function WaitFor(TimeoutMs: Cardinal): Boolean;
  end;

function DesktopSubscribe: TEventSubscriber;
procedure DesktopUnsubscribe(Sub: TEventSubscriber);
function DesktopSubscriberCount: Integer;

{ Publish a raw JSON object (without the trailing newline). Adds seq + ts. }
procedure PublishRaw(const JSONObj: string);

{ Typed helpers -- every caller in the tree uses one of these rather than
  hand-building JSON, so the event vocabulary stays discoverable. }
procedure PublishProjects;                                  { the board changed }
procedure PublishProject(const Project: string);

(* Ask the connected desktops to DO something -- tile the windows, open an
   app, change the theme.

   The other events report that something happened; this one asks. It
   exists because a tool runs in the gateway and the windows live in a
   browser: the agent cannot touch them directly, but the desktop is
   already listening here, so a command on the same feed reaches it.

   Any session can send one -- the shell chat, the Agent Console, a cron
   job that tidies the screen at nine every morning -- rather than only
   the one window that happens to own a conversation.

   ActionsJSON is a JSON array of {"do":...} objects, forwarded verbatim
   for the client to interpret: the vocabulary belongs to the desktop
   that executes it, and duplicating it here would create two lists to
   keep in step. *)
procedure PublishDesktopCommand(const ActionsJSON: string);

(* Which connected desktop should carry out the side-effecting half of a
   command. The oldest live subscriber -- arbitrary but STABLE, which is
   the property that matters: every command in a session lands on the
   same screen rather than scattering builds across tabs. '' when
   nothing is connected. *)
function DesktopPrimaryClient: string;

procedure PublishTask(const Project, TaskId, Status: string);
procedure PublishJob(const Project, TaskId, JobId, Status: string);
procedure PublishJobLog(const Project, TaskId, JobId, Line: string);
procedure PublishApp(const Project, State: string; Port: Integer);
procedure PublishPage(const PageId, Title: string; Sources: Integer);
procedure PublishWorkspace(const Name: string);

(* Progress while a research page is being built.

   A deep-research turn runs for minutes across many searches and fetches,
   and a spinner that says nothing for that long is indistinguishable from a
   hang. This carries what the agent is doing RIGHT NOW -- which tool, on
   what -- so the progress dialog shows work rather than patience. *)
procedure PublishPageProgress(const Phase, Detail: string);

(* A turn that is WAITING, not running.

   Same-session turns serialize on the session turn lock, and the queued
   tab's POST simply blocks -- which the browser paints exactly like a
   running turn. Nine silent seconds of "Stop" with no output reads as a
   hang. This names the one client whose turn is parked (as the browser
   named itself on connect) so that screen -- and only that screen -- can
   say "waiting for another turn on this conversation" instead. *)
procedure PublishTurnQueued(const SessionId, ClientId: string);

implementation

uses
  PasClaw.Utils,
  PasClaw.JSON;

const
  MaxQueued = 256;   { per subscriber, then oldest-dropped + gap marker }

var
  GLock: TCriticalSection = nil;
  GSubs: TList = nil;
  GSeq: Int64 = 0;
  { Names for connected desktops. Server-assigned rather than
    browser-chosen, so two tabs cannot claim the same one. }
  GClientSeq: Int64 = 0;

{ ------------------------------------------------------------ subscriber -- }

constructor TEventSubscriber.Create;
begin
  inherited Create;
  FQueue := TStringList.Create;
  FLock := TCriticalSection.Create;
  FSignal := TEvent.Create(nil, False, False, '');
end;

destructor TEventSubscriber.Destroy;
begin
  FreeAndNil(FSignal);
  FreeAndNil(FQueue);
  FreeAndNil(FLock);
  inherited;
end;

function TEventSubscriber.Drain(Max: Integer): TStringList;
var
  I, N: Integer;
begin
  Result := TStringList.Create;
  FLock.Acquire;
  try
    if FDropped then
    begin
      { Tell the client it missed something BEFORE handing it the events it
        did get, so it refetches and then applies the newer ones. }
      Result.Add('{"type":"gap"}');
      FDropped := False;
    end;
    N := FQueue.Count;
    if N > Max then N := Max;
    for I := 0 to N - 1 do
      Result.Add(FQueue[I]);
    for I := N - 1 downto 0 do
      FQueue.Delete(I);
  finally
    FLock.Release;
  end;
end;

function TEventSubscriber.WaitFor(TimeoutMs: Cardinal): Boolean;
begin
  Result := FSignal.WaitFor(TimeoutMs) = wrSignaled;
end;

{ --------------------------------------------------------------- fan-out -- }

function DesktopSubscribe: TEventSubscriber;
begin
  Result := TEventSubscriber.Create;
  GLock.Acquire;
  try
    Inc(GClientSeq);
    Result.ClientId := 'd' + IntToStr(GClientSeq);
    GSubs.Add(Result);
  finally
    GLock.Release;
  end;
end;

procedure DesktopUnsubscribe(Sub: TEventSubscriber);
var
  I: Integer;
begin
  if Sub = nil then Exit;
  GLock.Acquire;
  try
    I := GSubs.IndexOf(Sub);
    if I >= 0 then GSubs.Delete(I);
  finally
    GLock.Release;
  end;
  Sub.Free;
end;

function DesktopSubscriberCount: Integer;
begin
  GLock.Acquire;
  try
    Result := GSubs.Count;
  finally
    GLock.Release;
  end;
end;

procedure PublishRaw(const JSONObj: string);
var
  I: Integer;
  Sub: TEventSubscriber;
  Line, Body: string;
  Seq: Int64;
begin
  if GSubs = nil then Exit;
  { Nobody listening is the common case (a headless gateway); do no work. }
  GLock.Acquire;
  try
    if GSubs.Count = 0 then Exit;
    Inc(GSeq);
    Seq := GSeq;
  finally
    GLock.Release;
  end;

  Body := Trim(JSONObj);
  if (Body = '') or (Body[1] <> '{') then Exit;
  { Splice seq + ts in rather than reparsing: these events are emitted on hot
    paths (a job log line at a time) and a parse per event per subscriber is
    a cost with no upside. }
  Line := '{"seq":' + IntToStr(Seq) + ',"ts":"' + NowIsoUtc + '",' +
          Copy(Body, 2, MaxInt);

  GLock.Acquire;
  try
    for I := 0 to GSubs.Count - 1 do
    begin
      Sub := TEventSubscriber(GSubs[I]);
      Sub.FLock.Acquire;
      try
        if Sub.FQueue.Count >= MaxQueued then
        begin
          { Drop the OLDEST: a slow reader should still receive the newest
            state, which is what it will render. }
          Sub.FQueue.Delete(0);
          Sub.FDropped := True;
        end;
        Sub.FQueue.Add(Line);
      finally
        Sub.FLock.Release;
      end;
      Sub.FSignal.SetEvent;
    end;
  finally
    GLock.Release;
  end;
end;

{ ---------------------------------------------------------------- typed -- }

function Esc(const S: string): string;
begin
  Result := JsonEscape(S);
end;

procedure PublishProjects;
begin
  PublishRaw('{"type":"projects"}');
end;

procedure PublishProject(const Project: string);
begin
  PublishRaw('{"type":"project","project":"' + Esc(Project) + '"}');
end;

function DesktopPrimaryClient: string;
var
  I: Integer;
  Sub: TEventSubscriber;
begin
  Result := '';
  GLock.Acquire;
  try
    for I := 0 to GSubs.Count - 1 do
    begin
      Sub := TEventSubscriber(GSubs[I]);
      if (Sub <> nil) and (Sub.ClientId <> '') then
      begin
        Result := Sub.ClientId;
        Exit;
      end;
    end;
  finally
    GLock.Release;
  end;
end;

procedure PublishDesktopCommand(const ActionsJSON: string);
var
  Body, Target: string;
begin
  Body := Trim(ActionsJSON);
  { An empty or non-array payload would reach the client as a command it
    cannot read; refuse it here rather than make every desktop defend. }
  if (Body = '') or (Body[1] <> '[') then Exit;
  (* Every screen gets the command -- "tile the windows" should tidy all
     of them. "target" names the ONE screen allowed to run the actions
     that have consequences beyond the glass: starting a build, opening
     a page. Without it, two tabs meant two builds of the same project,
     racing on one app directory and one session file. *)
  Target := DesktopPrimaryClient;
  PublishRaw('{"type":"desktop-command","target":"' + Esc(Target) +
             '","actions":' + Body + '}');
end;

procedure PublishTask(const Project, TaskId, Status: string);
begin
  PublishRaw('{"type":"task","project":"' + Esc(Project) +
             '","task":"' + Esc(TaskId) +
             '","status":"' + Esc(Status) + '"}');
end;

procedure PublishJob(const Project, TaskId, JobId, Status: string);
begin
  PublishRaw('{"type":"job","project":"' + Esc(Project) +
             '","task":"' + Esc(TaskId) +
             '","id":"' + Esc(JobId) +
             '","status":"' + Esc(Status) + '"}');
end;

procedure PublishJobLog(const Project, TaskId, JobId, Line: string);
begin
  PublishRaw('{"type":"joblog","project":"' + Esc(Project) +
             '","task":"' + Esc(TaskId) +
             '","id":"' + Esc(JobId) +
             '","line":"' + Esc(Line) + '"}');
end;

procedure PublishApp(const Project, State: string; Port: Integer);
begin
  PublishRaw('{"type":"app","project":"' + Esc(Project) +
             '","state":"' + Esc(State) +
             '","port":' + IntToStr(Port) + '}');
end;

procedure PublishPage(const PageId, Title: string; Sources: Integer);
begin
  PublishRaw('{"type":"page","id":"' + Esc(PageId) +
             '","title":"' + Esc(Title) +
             '","sources":' + IntToStr(Sources) + '}');
end;

procedure PublishWorkspace(const Name: string);
begin
  PublishRaw('{"type":"workspace","name":"' + Esc(Name) + '"}');
end;

procedure PublishPageProgress(const Phase, Detail: string);
begin
  { Detail is bounded here rather than at the call site: a tool argument can
    be a whole document, and this is a status line, not a log. }
  PublishRaw('{"type":"page-progress","phase":"' + Esc(Phase) +
             '","detail":"' + Esc(Copy(Detail, 1, 200)) + '"}');
end;

procedure PublishTurnQueued(const SessionId, ClientId: string);
begin
  PublishRaw('{"type":"turn-queued","session":"' + Esc(SessionId) +
             '","client":"' + Esc(ClientId) + '"}');
end;

initialization
  GLock := TCriticalSection.Create;
  GSubs := TList.Create;

finalization
  { Subscribers are owned by their SSE handlers; by the time the unit is
    finalized those connections are gone. Free the list, not the items. }
  FreeAndNil(GSubs);
  FreeAndNil(GLock);


end.
