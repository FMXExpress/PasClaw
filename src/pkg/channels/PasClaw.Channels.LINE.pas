(*
  PasClaw.Channels.LINE - LINE Messaging API client.

  Two surfaces:

    TLinePush - outbound push. Sends a text message to a known userId,
                groupId, or roomId via POST /v2/bot/message/push with
                Bearer <token>. Useful from cron skills via
                `pasclaw post line`.

    TLineBot  - bidirectional webhook receiver + reply. Mounted as a
                gateway route via TGatewayServer.MountWebhook; receives
                events at POST /webhooks/line, verifies the
                X-Line-Signature HMAC-SHA256/Base64 against the channel
                secret, parses the event JSON, and runs each text
                message through the same RunToolLoop the Telegram bot
                uses. Replies use the one-shot replyToken (POST
                /v2/bot/message/reply) for the first response inside
                the ~30 s window; the bot falls back to push when the
                handler responds after the reply window closes.

  Configuration:
    Channel access token:  $PASCLAW_LINE_TOKEN
    Channel secret (HMAC): $PASCLAW_LINE_SECRET

  Docs:
    Push:    https://developers.line.biz/en/reference/messaging-api/#send-push-message
    Reply:   https://developers.line.biz/en/reference/messaging-api/#send-reply-message
    Webhook: https://developers.line.biz/en/reference/messaging-api/#webhooks
*)
unit PasClaw.Channels.LINE;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  IdContext, IdCustomHTTPServer,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TLinePush = class
  private
    FToken: string;
  public
    constructor Create(const ChannelAccessToken: string);
    function Push(const ToId, Text: string): Boolean;
  end;

  TLineBot = class
  private
    FToken:    string;
    FSecret:   string;
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FPush:     TLinePush;
    function VerifySignature(const Body, SignatureB64: string): Boolean;
    function Reply(const ReplyToken, Text: string): Boolean;
    procedure ProcessEvent(const EventJSON: string);
  public
    constructor Create(const ChannelAccessToken, ChannelSecret: string;
                       Cfg: TConfig; Provider: ILLMProvider;
                       Registry: TToolRegistry);
    destructor Destroy; override;
    procedure HandleWebhook(AContext: TIdContext;
                            ARequest: TIdHTTPRequestInfo;
                            AResponse: TIdHTTPResponseInfo);
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop,
  PasClaw.Crypto.HMAC,
  PasClaw.Identity;

type
  (* One-shot worker that calls TLineBot.ProcessEvent off the Indy
     dispatcher thread. HandleWebhook spawns one of these per event and
     returns; Indy then flushes the 200 ack within milliseconds instead
     of holding it open while RunToolLoop chases tools. LINE's webhook
     timeout is 1s -- without async, a slow turn (long tool loop, large
     model response) blows past it and LINE retries the event up to 3
     more times, generating 4× duplicate replies even though we set
     ResponseNo := 200 early. FreeOnTerminate := True so the worker
     cleans itself up after Execute returns. *)
  TLineEventWorker = class(TThread)
  private
    FBot:       TLineBot;
    FEventJSON: string;
  public
    constructor Create(Bot: TLineBot; const EventJSON: string);
    procedure Execute; override;
  end;

constructor TLineEventWorker.Create(Bot: TLineBot; const EventJSON: string);
begin
  { Construct SUSPENDED, assign state, then Start. With Create(False)
    the kernel can schedule Execute before the field assignments below
    finish -- FBot would be nil and FEventJSON would be empty when the
    worker ran. Codex flagged this on PR #78; the cron scheduler's
    TCronThread uses the same suspended-then-start pattern. }
  inherited Create(True);
  FreeOnTerminate := True;
  FBot       := Bot;
  FEventJSON := EventJSON;
  Start;
end;

procedure TLineEventWorker.Execute;
begin
  try
    FBot.ProcessEvent(FEventJSON);
  except
    on E: Exception do
      LogWarn('line worker: ProcessEvent raised %s: %s',
              [E.ClassName, E.Message]);
  end;
end;

const
  LINE_PUSH_URL  = 'https://api.line.me/v2/bot/message/push';
  LINE_REPLY_URL = 'https://api.line.me/v2/bot/message/reply';

constructor TLinePush.Create(const ChannelAccessToken: string);
begin
  inherited Create;
  FToken := ChannelAccessToken;
end;

function PushOrReply(const URL, Token, BodyJSON: string): Boolean;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + Token);
  Resp := PostJSON(URL, BodyJSON, Headers, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('line: %s -> status=%d body=%s',
            [URL, Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

function BuildTextMessagesBody(const KeyName, KeyValue, Text: string): string;
var
  Root, Msg: TJsonObject;
  Msgs: TJsonArray;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr(KeyName, KeyValue);
    Msgs := TJsonArray.Create;
    Msg  := TJsonObject.Create;
    Msg.PutStr('type', 'text');
    Msg.PutStr('text', Text);
    Msgs.AddObject(Msg);
    Root.PutArray('messages', Msgs);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TLinePush.Push(const ToId, Text: string): Boolean;
begin
  if FToken = '' then
  begin
    LogWarn('line push: no channel access token configured', []);
    Exit(False);
  end;
  if Trim(ToId) = '' then
  begin
    LogWarn('line push: empty target id', []);
    Exit(False);
  end;
  Result := PushOrReply(LINE_PUSH_URL, FToken,
                        BuildTextMessagesBody('to', ToId, Text));
end;

constructor TLineBot.Create(const ChannelAccessToken, ChannelSecret: string;
                             Cfg: TConfig; Provider: ILLMProvider;
                             Registry: TToolRegistry);
begin
  inherited Create;
  FToken    := ChannelAccessToken;
  FSecret   := ChannelSecret;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FPush     := TLinePush.Create(ChannelAccessToken);
end;

destructor TLineBot.Destroy;
begin
  FPush.Free;
  inherited Destroy;
end;

function TLineBot.VerifySignature(const Body, SignatureB64: string): Boolean;
var
  Expected: string;
begin
  if FSecret = '' then
  begin
    LogWarn('line webhook: no channel secret configured; rejecting', []);
    Exit(False);
  end;
  if SignatureB64 = '' then Exit(False);
  Expected := HMACSHA256Base64(StringToBytes(FSecret), StringToBytes(Body));
  Result := ConstantTimeEqual(Expected, SignatureB64);
end;

function TLineBot.Reply(const ReplyToken, Text: string): Boolean;
begin
  if Trim(ReplyToken) = '' then Exit(False);
  Result := PushOrReply(LINE_REPLY_URL, FToken,
                        BuildTextMessagesBody('replyToken', ReplyToken, Text));
end;

procedure TLineBot.ProcessEvent(const EventJSON: string);
var
  Obj, MsgObj, SrcObj: TJsonObject;
  Kind, MsgType, Text, ReplyToken, SourceId, Response: string;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Obj := TJsonObject.Parse(EventJSON);
  if Obj = nil then Exit;
  try
    Kind := Obj.GetStr('type', '');
    if Kind <> 'message' then Exit;

    MsgObj := Obj.ChildObject('message');
    if MsgObj = nil then Exit;
    try
      MsgType := MsgObj.GetStr('type', '');
      if MsgType <> 'text' then Exit;
      Text := MsgObj.GetStr('text', '');
    finally
      MsgObj.Free;
    end;

    if Trim(Text) = '' then Exit;
    ReplyToken := Obj.GetStr('replyToken', '');

    SrcObj := Obj.ChildObject('source');
    if SrcObj <> nil then
    try
      { LINE source.type is "user" / "group" / "room"; the matching
        id field varies. Pick whichever exists for push fallback. }
      SourceId := SrcObj.GetStr('userId',  '');
      if SourceId = '' then SourceId := SrcObj.GetStr('groupId', '');
      if SourceId = '' then SourceId := SrcObj.GetStr('roomId',  '');
    finally
      SrcObj.Free;
    end;
  finally
    Obj.Free;
  end;

  LogInfo('line: %s msg=%s', [SourceId, Copy(Text, 1, 80)]);

  if FProvider = nil then
  begin
    Response := '(no provider configured -- run `pasclaw onboard`)';
    if not Reply(ReplyToken, Response) and (SourceId <> '') then
      FPush.Push(SourceId, Response);
    Exit;
  end;

  { Default-init: locals are not zero-initialized; unset fields (e.g. DisableProgressLedger) would read stack garbage. }
  LoopCfg := Default(TToolLoopConfig);
  LoopCfg.Identity := MakeIdentity('line', SourceId);
  if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
  begin
    LogInfo('line: sender %s rejected by allow_senders',
            [FormatIdentity(LoopCfg.Identity)]);
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Text);

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

  { Try Reply first -- free, fast, single-use. If the token expired or
    was already consumed (RunToolLoop took >30 s) fall back to Push so
    the user still gets the answer. }
  if not Reply(ReplyToken, Response) then
    if SourceId <> '' then FPush.Push(SourceId, Response);
end;

procedure TLineBot.HandleWebhook(AContext: TIdContext;
                                  ARequest: TIdHTTPRequestInfo;
                                  AResponse: TIdHTTPResponseInfo);
var
  Body, Signature: string;
  Bytes: TBytes;
  Root: TJsonObject;
  Events: TJsonArray;
  EvObj: TJsonObject;
  i: Integer;
begin
  { Gateway dispatch is path-only (channels like WhatsApp Cloud bind
    GET and POST to the same URL). LINE only delivers via POST; emit
    405 on anything else so the platform doesn't silently treat a
    misconfigured probe as success. }
  if ARequest.Command <> 'POST' then
  begin
    AResponse.ResponseNo  := 405;
    AResponse.ContentText := '{"error":"method not allowed"}';
    AResponse.ContentType := 'application/json';
    Exit;
  end;

  if ARequest.PostStream <> nil then
  begin
    SetLength(Bytes, ARequest.PostStream.Size);
    ARequest.PostStream.Position := 0;
    if Length(Bytes) > 0 then
      ARequest.PostStream.ReadBuffer(Bytes[0], Length(Bytes));
    {$IFDEF FPC}
    SetString(Body, PAnsiChar(@Bytes[0]), Length(Bytes));
    {$ELSE}
    Body := TEncoding.UTF8.GetString(Bytes);
    {$ENDIF}
  end
  else
    Body := '';

  Signature := ARequest.RawHeaders.Values['X-Line-Signature'];

  if not VerifySignature(Body, Signature) then
  begin
    AResponse.ResponseNo  := 401;
    AResponse.ContentText := '{"error":"signature"}';
    AResponse.ContentType := 'application/json';
    LogWarn('line webhook: signature rejected', []);
    Exit;
  end;

  { LINE retries up to 3 times when we return non-2xx, so respond 200
    even if dispatch fails internally -- the retries would only make
    duplicate replies. }
  AResponse.ResponseNo  := 200;
  AResponse.ContentText := '{}';
  AResponse.ContentType := 'application/json';

  { Pre-try `Root := nil` removed -- dead write per dcc64 H2077. The
    except branch always Exits, so Root is either assigned by Parse
    on the success path or we never reach the post-try-except code. }
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      LogWarn('line webhook: bad JSON: %s', [E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    Events := Root.ChildArray('events');
    if Events = nil then Exit;
    try
      for i := 0 to Events.Count - 1 do
      begin
        EvObj := Events.ItemObject(i);
        if EvObj = nil then Continue;
        try
          { Hand the event off to a self-freeing worker thread so the
            handler can return and Indy can flush the 200 ack inside
            LINE's 1s timeout window. The worker owns its own copy of
            the event JSON; FBot fields are read-only after construction
            so the thread reads them without locking. }
          TLineEventWorker.Create(Self, EvObj.ToJSON);
        finally
          EvObj.Free;
        end;
      end;
    finally
      Events.Free;
    end;
  finally
    Root.Free;
  end;
end;

end.
