(*
  PasClaw.Channels.WhatsApp - WhatsApp Cloud API (Meta).

  Two surfaces, matching the LINE shape:

    TWhatsAppPush - outbound send. POST a text message to a phone
                    number via the Cloud API messages endpoint. Useful
                    from cron skills via `pasclaw post whatsapp`.
                    Endpoint: POST /v18.0/<phone-number-id>/messages
                              on graph.facebook.com.
                    Body:     {"messaging_product":"whatsapp",
                                "to":"<phone>","type":"text",
                                "text":{"body":"<text>"}}

    TWhatsAppBot  - bidirectional webhook receiver + reply. Mounted as
                    a gateway route via TGatewayServer.MountWebhook.
                    The same path handles two verbs:
                      GET  /webhooks/whatsapp  -> subscription
                           verification. Meta sends
                             hub.mode=subscribe
                             hub.verify_token=<configured>
                             hub.challenge=<random>
                           we echo hub.challenge as text/plain if the
                           token matches; 403 otherwise.
                      POST /webhooks/whatsapp  -> message events.
                           Header: X-Hub-Signature-256: sha256=<hex>
                           Body:   JSON envelope with
                                   entry[].changes[].value.messages[]
                           Each text message runs through RunToolLoop
                           and the reply goes out via the same
                           messages endpoint TWhatsAppPush uses.

  Required configuration:
    Access token (system user, long-lived): $PASCLAW_WHATSAPP_TOKEN
    Phone number ID (NOT the phone number): $PASCLAW_WHATSAPP_PHONE_ID
    User-chosen verify-token string:        $PASCLAW_WHATSAPP_VERIFY_TOKEN
    Meta App Secret (for HMAC):             $PASCLAW_WHATSAPP_APP_SECRET

  Docs:
    Webhook setup: https://developers.facebook.com/docs/whatsapp/cloud-api/guides/set-up-webhooks
    Send message:  https://developers.facebook.com/docs/whatsapp/cloud-api/reference/messages
    Signature:     https://developers.facebook.com/docs/graph-api/webhooks/getting-started#validating-payloads
*)
unit PasClaw.Channels.WhatsApp;

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
  TWhatsAppPush = class
  private
    FToken:   string;
    FPhoneId: string;
  public
    constructor Create(const AccessToken, PhoneNumberId: string);
    function Push(const ToPhoneNumber, Text: string): Boolean;
  end;

  TWhatsAppBot = class
  private
    FToken:       string;
    FPhoneId:     string;
    FVerifyToken: string;
    FAppSecret:   string;
    FCfg:         TConfig;
    FProvider:    ILLMProvider;
    FRegistry:    TToolRegistry;
    FPush:        TWhatsAppPush;
    function VerifySignature(const Body, SignatureHeader: string): Boolean;
    procedure HandleVerify(ARequest: TIdHTTPRequestInfo;
                           AResponse: TIdHTTPResponseInfo);
    procedure HandleEvents(ARequest: TIdHTTPRequestInfo;
                           AResponse: TIdHTTPResponseInfo);
    procedure ProcessMessage(const FromNumber, Text: string);
  public
    constructor Create(const AccessToken, PhoneNumberId,
                       VerifyToken, AppSecret: string;
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
  (* One-shot worker that calls TWhatsAppBot.ProcessMessage off the Indy
     dispatcher thread. HandleEvents spawns one per inbound text message
     and returns; Indy then flushes the 200 ack right away instead of
     holding it open while RunToolLoop chases tools. Meta's webhook
     ingestion times out around 20s and backs off exponentially on
     retry -- without async, a long tool loop tips the request past the
     timeout and the same event gets re-delivered, duplicating replies.
     FreeOnTerminate so the worker cleans up after Execute returns. *)
  TWhatsAppMessageWorker = class(TThread)
  private
    FBot:        TWhatsAppBot;
    FFromNumber: string;
    FText:       string;
  public
    constructor Create(Bot: TWhatsAppBot; const FromNumber, Text: string);
    procedure Execute; override;
  end;

constructor TWhatsAppMessageWorker.Create(Bot: TWhatsAppBot;
                                            const FromNumber, Text: string);
begin
  { Construct SUSPENDED, assign state, then Start. With Create(False)
    the kernel can schedule Execute before the field assignments below
    finish -- FBot would be nil and FFromNumber/FText would be empty
    when the worker ran. Codex flagged this on PR #78; the cron
    scheduler's TCronThread uses the same suspended-then-start
    pattern. }
  inherited Create(True);
  FreeOnTerminate := True;
  FBot         := Bot;
  FFromNumber  := FromNumber;
  FText        := Text;
  Start;
end;

procedure TWhatsAppMessageWorker.Execute;
begin
  try
    FBot.ProcessMessage(FFromNumber, FText);
  except
    on E: Exception do
      LogWarn('whatsapp worker: ProcessMessage raised %s: %s',
              [E.ClassName, E.Message]);
  end;
end;

const
  WA_API_BASE = 'https://graph.facebook.com/v18.0';

function BuildSendBody(const ToNumber, Text: string): string;
var
  Root, TextObj: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('messaging_product', 'whatsapp');
    Root.PutStr('to',                ToNumber);
    Root.PutStr('type',              'text');
    TextObj := TJsonObject.Create;
    TextObj.PutStr('body', Text);
    Root.PutObject('text', TextObj);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function SendMessage(const Token, PhoneId, ToNumber, Text: string): Boolean;
var
  URL: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  URL := WA_API_BASE + '/' + PhoneId + '/messages';
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bearer ' + Token);
  Resp := PostJSON(URL, BuildSendBody(ToNumber, Text), Headers, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('whatsapp: send -> status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

constructor TWhatsAppPush.Create(const AccessToken, PhoneNumberId: string);
begin
  inherited Create;
  FToken   := AccessToken;
  FPhoneId := PhoneNumberId;
end;

function TWhatsAppPush.Push(const ToPhoneNumber, Text: string): Boolean;
begin
  if FToken = '' then
  begin
    LogWarn('whatsapp push: no access token configured', []);
    Exit(False);
  end;
  if FPhoneId = '' then
  begin
    LogWarn('whatsapp push: no phone-number-id configured', []);
    Exit(False);
  end;
  if Trim(ToPhoneNumber) = '' then
  begin
    LogWarn('whatsapp push: empty target phone number', []);
    Exit(False);
  end;
  Result := SendMessage(FToken, FPhoneId, ToPhoneNumber, Text);
end;

constructor TWhatsAppBot.Create(const AccessToken, PhoneNumberId,
                                  VerifyToken, AppSecret: string;
                                  Cfg: TConfig; Provider: ILLMProvider;
                                  Registry: TToolRegistry);
begin
  inherited Create;
  FToken       := AccessToken;
  FPhoneId     := PhoneNumberId;
  FVerifyToken := VerifyToken;
  FAppSecret   := AppSecret;
  FCfg         := Cfg;
  FProvider    := Provider;
  FRegistry    := Registry;
  FPush        := TWhatsAppPush.Create(AccessToken, PhoneNumberId);
end;

destructor TWhatsAppBot.Destroy;
begin
  FPush.Free;
  inherited Destroy;
end;

function TWhatsAppBot.VerifySignature(const Body, SignatureHeader: string): Boolean;
var
  Expected, Got: string;
const
  Prefix = 'sha256=';
begin
  if FAppSecret = '' then
  begin
    LogWarn('whatsapp webhook: no app secret configured; rejecting', []);
    Exit(False);
  end;
  if SignatureHeader = '' then Exit(False);
  if Pos(Prefix, SignatureHeader) <> 1 then
  begin
    LogWarn('whatsapp webhook: malformed signature (no sha256= prefix)', []);
    Exit(False);
  end;
  Got      := Copy(SignatureHeader, Length(Prefix) + 1, MaxInt);
  Expected := HMACSHA256HexLower(StringToBytes(FAppSecret), StringToBytes(Body));
  Result   := ConstantTimeEqual(Expected, Got);
end;

procedure TWhatsAppBot.HandleVerify(ARequest: TIdHTTPRequestInfo;
                                    AResponse: TIdHTTPResponseInfo);
var
  Mode, Token, Challenge: string;
begin
  { Meta's subscription verify: GET with query params. If hub.mode is
    "subscribe" AND hub.verify_token matches what we configured, echo
    hub.challenge back as plain text with 200. Anything else is 403.
    The challenge body MUST be the raw value (no JSON wrapping) per
    Meta's docs -- they parse it as text. }
  Mode      := ARequest.Params.Values['hub.mode'];
  Token     := ARequest.Params.Values['hub.verify_token'];
  Challenge := ARequest.Params.Values['hub.challenge'];

  if (Mode = 'subscribe') and (FVerifyToken <> '') and
     ConstantTimeEqual(Token, FVerifyToken) then
  begin
    AResponse.ResponseNo  := 200;
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.ContentText := Challenge;
    LogInfo('whatsapp: subscription verified', []);
    Exit;
  end;

  LogWarn('whatsapp: subscription verify rejected (mode=%s)', [Mode]);
  AResponse.ResponseNo  := 403;
  AResponse.ContentType := 'application/json';
  AResponse.ContentText := '{"error":"verify failed"}';
end;

procedure TWhatsAppBot.ProcessMessage(const FromNumber, Text: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Response: string;
begin
  LogInfo('whatsapp: %s msg=%s', [FromNumber, Copy(Text, 1, 80)]);

  if FProvider = nil then
  begin
    FPush.Push(FromNumber,
               '(no provider configured -- run `pasclaw onboard`)');
    Exit;
  end;

  LoopCfg.Identity := MakeIdentity('whatsapp', FromNumber);
  if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
  begin
    LogInfo('whatsapp: sender %s rejected by allow_senders',
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

  FPush.Push(FromNumber, Response);
end;

procedure TWhatsAppBot.HandleEvents(ARequest: TIdHTTPRequestInfo;
                                     AResponse: TIdHTTPResponseInfo);
var
  Body, Signature: string;
  Bytes: TBytes;
  Root, ValueObj, MsgObj, EntryObj, ChangeObj, TextObj: TJsonObject;
  EntryArr, ChangeArr, MsgArr: TJsonArray;
  i, j, k: Integer;
  MsgType, From_, Text: string;
begin
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

  Signature := ARequest.RawHeaders.Values['X-Hub-Signature-256'];

  if not VerifySignature(Body, Signature) then
  begin
    AResponse.ResponseNo  := 401;
    AResponse.ContentText := '{"error":"signature"}';
    AResponse.ContentType := 'application/json';
    LogWarn('whatsapp webhook: signature rejected', []);
    Exit;
  end;

  { Meta retries with backoff on non-2xx, so always ack 200 -- dispatch
    errors get logged but don't trigger duplicate-delivery storms. }
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
      LogWarn('whatsapp webhook: bad JSON: %s', [E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    EntryArr := Root.ChildArray('entry');
    if EntryArr = nil then Exit;
    try
      for i := 0 to EntryArr.Count - 1 do
      begin
        EntryObj := EntryArr.ItemObject(i);
        if EntryObj = nil then Continue;
        try
          ChangeArr := EntryObj.ChildArray('changes');
          if ChangeArr = nil then Continue;
          try
            for j := 0 to ChangeArr.Count - 1 do
            begin
              ChangeObj := ChangeArr.ItemObject(j);
              if ChangeObj = nil then Continue;
              try
                ValueObj := ChangeObj.ChildObject('value');
                if ValueObj = nil then Continue;
                try
                  MsgArr := ValueObj.ChildArray('messages');
                  if MsgArr = nil then Continue;
                  try
                    for k := 0 to MsgArr.Count - 1 do
                    begin
                      MsgObj := MsgArr.ItemObject(k);
                      if MsgObj = nil then Continue;
                      try
                        MsgType := MsgObj.GetStr('type', '');
                        if MsgType <> 'text' then Continue;
                        From_ := MsgObj.GetStr('from', '');
                        { Text body lives one level down at
                          messages[].text.body. }
                        TextObj := MsgObj.ChildObject('text');
                        if TextObj = nil then Continue;
                        try
                          Text := TextObj.GetStr('body', '');
                        finally
                          TextObj.Free;
                        end;
                        if (From_ = '') or (Text = '') then Continue;
                        { Hand the message off to a self-freeing worker
                          thread so HandleEvents returns and Indy can
                          flush the 200 ack before Meta times the
                          delivery out. FBot fields are read-only after
                          construction; FromNumber + Text are
                          per-thread locals. }
                        TWhatsAppMessageWorker.Create(Self, From_, Text);
                      finally
                        MsgObj.Free;
                      end;
                    end;
                  finally
                    MsgArr.Free;
                  end;
                finally
                  ValueObj.Free;
                end;
              finally
                ChangeObj.Free;
              end;
            end;
          finally
            ChangeArr.Free;
          end;
        finally
          EntryObj.Free;
        end;
      end;
    finally
      EntryArr.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TWhatsAppBot.HandleWebhook(AContext: TIdContext;
                                      ARequest: TIdHTTPRequestInfo;
                                      AResponse: TIdHTTPResponseInfo);
begin
  if ARequest.Command = 'GET' then
    HandleVerify(ARequest, AResponse)
  else if ARequest.Command = 'POST' then
    HandleEvents(ARequest, AResponse)
  else
  begin
    AResponse.ResponseNo  := 405;
    AResponse.ContentText := '{"error":"method not allowed"}';
    AResponse.ContentType := 'application/json';
  end;
end;

end.
