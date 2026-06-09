(*
  PasClaw.Channels.Matrix - Matrix client/server bot.

  Federated, self-hostable, no token-vendor lock-in. The bot is a
  regular Matrix user identified by an access token; messages
  arrive via the standard /sync long-poll and outbound replies go
  back through /rooms/<roomId>/send.

  Mirrors TTelegramChannel's shape: holds Cfg / Provider / Registry,
  runs RunToolLoop inline per inbound text event. Difference from
  Telegram is that Matrix can't block the main thread -- the gateway
  may want to run the HTTP server alongside, so Run launches an
  internal worker thread and returns; RequestStop / WaitForStop
  drive the shutdown.

  Configuration:
    Homeserver URL:  $PASCLAW_MATRIX_HOMESERVER  (e.g. https://matrix.org)
    Access token:    $PASCLAW_MATRIX_TOKEN       (provisioned once
                                                  via /login or the
                                                  homeserver admin UI)

  Endpoints used:
    GET  /_matrix/client/v3/sync?since=<token>&timeout=30000
    PUT  /_matrix/client/v3/rooms/<roomId>/send/m.room.message/<txnId>
    GET  /_matrix/client/v3/account/whoami     (one-shot at startup to
                                                resolve the bot's user
                                                id so it can ignore its
                                                own echoed messages)

  Out of scope for Wave 1 (documented for future work):
    - End-to-end encryption (E2EE rooms produce m.room.encrypted
      events the bot can't decrypt; those events are skipped with
      a debug log).
    - Login flow. The user provisions an access token out of band.
    - Room joins / leaves driven by the bot. The bot replies in
      whatever rooms its account is already joined to.

  Docs: https://spec.matrix.org/v1.11/client-server-api/#syncing
*)
unit PasClaw.Channels.Matrix;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TMatrixBot = class
  private
    FHomeserver: string;
    FToken:      string;
    FUserId:     string;          { resolved at startup via /whoami }
    FCfg:        TConfig;
    FProvider:   ILLMProvider;
    FRegistry:   TToolRegistry;
    FThread:     TThread;
    FStop:       Boolean;
    FStopEvt:    TEvent;
    FNextBatch:  string;
    function  ApiURL(const Path: string): string;
    function  GetSync(out RawJSON: string): Boolean;
    function  PostSend(const RoomId, Text: string): Boolean;
    function  WhoAmI(out UserId: string): Boolean;
    function  WhoAmIWithRetry(out UserId: string; Attempts: Integer): Boolean;
    function  InitialSyncToken: Boolean;
    procedure ProcessSync(const RawJSON: string);
    procedure ProcessEvent(const RoomId, EventJSON: string);
  public
    constructor Create(const Homeserver, AccessToken: string;
                       Cfg: TConfig; Provider: ILLMProvider;
                       Registry: TToolRegistry);
    destructor  Destroy; override;
    procedure Start;
    procedure RequestStop;
    procedure WaitForStop;
    property StopEvt: TEvent read FStopEvt;
    property Cfg: TConfig read FCfg;
    property Provider: ILLMProvider read FProvider;
    property Registry: TToolRegistry read FRegistry;
    property UserId: string read FUserId;
    property NextBatch: string read FNextBatch write FNextBatch;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop,
  PasClaw.Identity;

const
  SYNC_TIMEOUT_MS = 30000;

type
  (* Drives the bot's sync loop on its own TThread. Created
     suspended, fields populated, then Start'd -- same pattern the
     LINE / WhatsApp event workers used (Codex P2 fix from PR
     #78). FreeOnTerminate is False because TMatrixBot owns the
     thread and tears it down explicitly via RequestStop +
     WaitForStop. *)
  TMatrixSyncThread = class(TThread)
  private
    FBot: TMatrixBot;
  protected
    procedure Execute; override;
  public
    constructor Create(Bot: TMatrixBot);
  end;

constructor TMatrixSyncThread.Create(Bot: TMatrixBot);
begin
  inherited Create(True);   { suspended; caller Start's after assignments }
  FreeOnTerminate := False;
  FBot := Bot;
end;

procedure TMatrixSyncThread.Execute;
var
  RawJSON: string;
begin
  while not Terminated do
  begin
    try
      if FBot.GetSync(RawJSON) then
        FBot.ProcessSync(RawJSON)
      else
        { Transient network error -- back off briefly before retry
          so a server hiccup doesn't tight-loop. The /sync call
          itself does a 30 s long-poll under normal operation,
          so this sleep only kicks in on actual failure. }
        FBot.StopEvt.WaitFor(2000);
    except
      on E: Exception do
      begin
        LogError('matrix: sync loop error: %s', [E.Message]);
        FBot.StopEvt.WaitFor(5000);
      end;
    end;
  end;
end;

constructor TMatrixBot.Create(const Homeserver, AccessToken: string;
                               Cfg: TConfig; Provider: ILLMProvider;
                               Registry: TToolRegistry);
var
  Trimmed: string;
begin
  inherited Create;
  Trimmed := Homeserver;
  while (Length(Trimmed) > 0) and (Trimmed[Length(Trimmed)] = '/') do
    SetLength(Trimmed, Length(Trimmed) - 1);
  FHomeserver := Trimmed;
  FToken      := AccessToken;
  FCfg        := Cfg;
  FProvider   := Provider;
  FRegistry   := Registry;
  FStopEvt    := TEvent.Create(nil, True, False, '');
end;

destructor TMatrixBot.Destroy;
begin
  RequestStop;
  WaitForStop;
  FStopEvt.Free;
  inherited Destroy;
end;

function TMatrixBot.ApiURL(const Path: string): string;
begin
  if (Length(Path) > 0) and (Path[1] = '/') then
    Result := FHomeserver + Path
  else
    Result := FHomeserver + '/' + Path;
end;

function TMatrixBot.WhoAmI(out UserId: string): Boolean;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root: TJsonObject;
begin
  Result := False;
  UserId := '';
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FToken);
  Resp := GetJSONURL(ApiURL('/_matrix/client/v3/account/whoami'), Headers, 15);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    LogWarn('matrix: whoami status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;
  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      LogWarn('matrix: whoami bad JSON: %s', [E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    UserId := Root.GetStr('user_id', '');
    Result := UserId <> '';
  finally
    Root.Free;
  end;
end;

function TMatrixBot.WhoAmIWithRetry(out UserId: string; Attempts: Integer): Boolean;
var
  i: Integer;
begin
  (* PR #86 Codex P1: starting the sync thread before /whoami
     succeeds leaves FUserId empty. ProcessEvent's
     "if Sender = FUserId" then matches Sender='' rather than
     the bot's actual user_id, so every outbound reply
     re-enters the loop as a fresh prompt and the bot spam-
     replies to itself until the server boots it or the API
     quota dies. Retry a few times with exponential-ish
     backoff before giving up; if all attempts fail, Start
     refuses to launch the loop. *)
  Result := False;
  UserId := '';
  for i := 0 to Attempts - 1 do
  begin
    if WhoAmI(UserId) then Exit(True);
    if i = Attempts - 1 then Break;
    if FStopEvt.WaitFor(1000 * (1 shl i)) = wrSignaled then Break;
  end;
end;

function TMatrixBot.InitialSyncToken: Boolean;
var
  URL, Body: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root: TJsonObject;
begin
  (* PR #86 Codex P1: the first /sync without a since=
     parameter returns whatever recent timeline the homeserver
     has cached for each joined room. ProcessSync would then
     reply to every old message and look like the bot just
     time-travelled. Spec workaround: do a one-shot sync with
     timeline.limit=0 so we get only the next_batch token and
     no events; the long-poll loop in TMatrixSyncThread then
     starts strictly from that token. *)
  Result := False;
  URL := ApiURL('/_matrix/client/v3/sync?timeout=0&filter=' +
                '%7B%22room%22%3A%7B%22timeline%22%3A%7B%22limit%22%3A0%7D%7D%7D');
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FToken);
  Resp := GetJSONURL(URL, Headers, 30);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    LogWarn('matrix: initial sync status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;
  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      LogWarn('matrix: initial sync bad JSON: %s', [E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    FNextBatch := Root.GetStr('next_batch', '');
    Result := FNextBatch <> '';
    Body := FNextBatch;
    if Result then
      LogDebug('matrix: initial sync token len=%d', [Length(Body)]);
  finally
    Root.Free;
  end;
end;

function TMatrixBot.GetSync(out RawJSON: string): Boolean;
var
  URL: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  Result := False;
  RawJSON := '';
  URL := ApiURL('/_matrix/client/v3/sync?timeout=' + IntToStr(SYNC_TIMEOUT_MS));
  if FNextBatch <> '' then
    URL := URL + '&since=' + FNextBatch;

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FToken);
  Resp := GetJSONURL(URL, Headers, (SYNC_TIMEOUT_MS div 1000) + 15);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    LogWarn('matrix: sync status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;
  RawJSON := Resp.Body;
  Result := True;
end;

function TMatrixBot.PostSend(const RoomId, Text: string): Boolean;
var
  Path, TxnId, Body: string;
  Root: TJsonObject;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  TxnId := IntToStr(DateTimeToFileDate(Now)) + '_' + IntToStr(Random(1000000));
  Path  := '/_matrix/client/v3/rooms/' + RoomId +
           '/send/m.room.message/' + TxnId;

  Root := TJsonObject.Create;
  try
    Root.PutStr('msgtype', 'm.text');
    Root.PutStr('body',    Text);
    Body := Root.ToJSON;
  finally
    Root.Free;
  end;

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + FToken);
  Resp := PutJSON(ApiURL(Path), Body, Headers, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('matrix: send status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

procedure TMatrixBot.ProcessEvent(const RoomId, EventJSON: string);
var
  Obj, Content: TJsonObject;
  EvType, Sender, MsgType, Body, Response: string;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Obj := TJsonObject.Parse(EventJSON);
  if Obj = nil then Exit;
  try
    EvType := Obj.GetStr('type', '');
    if EvType <> 'm.room.message' then Exit;
    Sender := Obj.GetStr('sender', '');
    if (Sender = '') or (Sender = FUserId) then Exit;   { ignore our own echoes }

    Content := Obj.ChildObject('content');
    if Content = nil then Exit;
    try
      MsgType := Content.GetStr('msgtype', '');
      if MsgType <> 'm.text' then Exit;
      Body := Content.GetStr('body', '');
    finally
      Content.Free;
    end;
  finally
    Obj.Free;
  end;
  if Trim(Body) = '' then Exit;

  LogInfo('matrix: room=%s sender=%s msg=%s',
          [RoomId, Sender, Copy(Body, 1, 80)]);

  if FProvider = nil then
  begin
    PostSend(RoomId, '(no provider configured -- run `pasclaw onboard`)');
    Exit;
  end;

  LoopCfg.Identity := MakeIdentity('matrix', Sender, '', RoomId);
  if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
  begin
    LogInfo('matrix: sender %s rejected by allow_senders',
            [FormatIdentity(LoopCfg.Identity)]);
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Body);

  LoopCfg.Provider      := FProvider;
  LoopCfg.Registry      := FRegistry;
  LoopCfg.Model         := FCfg.DefaultModel;
  LoopCfg.MaxIterations := 6;
  LoopCfg.Parallel := True;
  LoopCfg.Options       := DefaultChatOptions;
  ApplyPromptCacheConfig(LoopCfg.Options, FCfg.PromptCache);
  LoopCfg.OnText        := nil;
  LoopCfg.OnToolCall    := nil;
  LoopCfg.OnToolResult  := nil;

  if RunToolLoop(LoopCfg, Msgs, Loop) and (Loop.Content <> '') then
    Response := Loop.Content
  else
    Response := '(sorry -- model returned no content)';

  PostSend(RoomId, Response);
end;

procedure TMatrixBot.ProcessSync(const RawJSON: string);
var
  Root, RoomsObj, JoinedObj, RoomObj, TimelineObj, EvObj: TJsonObject;
  EventsArr: TJsonArray;
  i: Integer;
  RoomIds: TStringList;
  RoomId: string;
begin
  { Pre-try `Root := nil` removed -- dead write per dcc64 H2077. The
    except branch always Exits, so Root is either assigned by Parse
    on the success path or we never reach the post-try-except code. }
  try
    Root := TJsonObject.Parse(RawJSON);
  except
    on E: Exception do
    begin
      LogWarn('matrix: bad sync JSON: %s', [E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    FNextBatch := Root.GetStr('next_batch', FNextBatch);

    RoomsObj := Root.ChildObject('rooms');
    if RoomsObj = nil then Exit;
    try
      JoinedObj := RoomsObj.ChildObject('join');
      if JoinedObj = nil then Exit;
      try
        RoomIds := JoinedObj.Keys;
        if RoomIds = nil then Exit;
        try
          for RoomId in RoomIds do
          begin
            RoomObj := JoinedObj.ChildObject(RoomId);
            if RoomObj = nil then Continue;
            try
              TimelineObj := RoomObj.ChildObject('timeline');
              if TimelineObj = nil then Continue;
              try
                EventsArr := TimelineObj.ChildArray('events');
                if EventsArr = nil then Continue;
                try
                  for i := 0 to EventsArr.Count - 1 do
                  begin
                    EvObj := EventsArr.ItemObject(i);
                    if EvObj = nil then Continue;
                    try
                      ProcessEvent(RoomId, EvObj.ToJSON);
                    finally
                      EvObj.Free;
                    end;
                  end;
                finally
                  EventsArr.Free;
                end;
              finally
                TimelineObj.Free;
              end;
            finally
              RoomObj.Free;
            end;
          end;
        finally
          RoomIds.Free;
        end;
      finally
        JoinedObj.Free;
      end;
    finally
      RoomsObj.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TMatrixBot.Start;
var
  T: TMatrixSyncThread;
begin
  if FThread <> nil then Exit;
  if (FHomeserver = '') or (FToken = '') then
  begin
    LogError('matrix: homeserver or access token missing -- bot not started', []);
    Exit;
  end;

  if not WhoAmIWithRetry(FUserId, 3) then
  begin
    LogError('matrix: /whoami failed after retries -- refusing to start ' +
             '(without a confirmed user_id the bot would reply to its own ' +
             'echoes; check $PASCLAW_MATRIX_TOKEN and homeserver reachability)', []);
    Exit;
  end;
  LogInfo('matrix: logged in as %s on %s', [FUserId, FHomeserver]);

  if not InitialSyncToken then
  begin
    LogError('matrix: initial sync token fetch failed -- refusing to start ' +
             '(without an anchor token, the first long-poll would replay ' +
             'old timeline events and reply to each)', []);
    Exit;
  end;

  T := TMatrixSyncThread.Create(Self);
  FThread := T;
  FThread.Start;
  LogInfo('matrix: sync loop started from token len=%d', [Length(FNextBatch)]);
end;

procedure TMatrixBot.RequestStop;
begin
  FStop := True;
  if FStopEvt <> nil then FStopEvt.SetEvent;
  if FThread <> nil then FThread.Terminate;
end;

procedure TMatrixBot.WaitForStop;
begin
  if FThread = nil then Exit;
  FThread.WaitFor;
  FreeAndNil(FThread);
end;

end.
