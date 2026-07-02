(*
  PasClaw.Channels.Discord - Discord adapter.

  Two modes:

    1. Webhook (outbound only). Easiest setup; post messages to a channel by
       calling a webhook URL. Used by `pasclaw post discord ...` or by skills
       that want to push notifications.

    2. Bot polling (inbound + outbound). Polls /users/@me/channels and
       /channels/:id/messages, dispatches each new user message through the
       agent loop, replies via POST /channels/:id/messages. Authenticated
       with a Bot token.

  Discord does NOT support long-poll on its REST API the way Telegram does;
  the production-grade path is the Gateway WebSocket. That's a substantial
  implementation, so for Phase 6 we ship the webhook (which is what most
  picoclaw users want anyway) and a basic poll-once REST loop.

  API docs: https://discord.com/developers/docs/reference
*)
unit PasClaw.Channels.Discord;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TDiscordWebhook = class
  private
    FURL: string;
  public
    constructor Create(const WebhookURL: string);
    function Post(const Content: string): Boolean;
    function PostEmbed(const Title, Description: string; Color: Integer): Boolean;
  end;

  TDiscordBot = class
  private
    FToken:    string;
    FChannel:  string;          { numeric channel id to watch }
    FLastId:   string;
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FStop:     Boolean;
    function FetchNewMessages(out RawJSON: string): Boolean;
    function PostMessage(const Content: string): Boolean;
    procedure ProcessMessages(const ArrJSON: string);
  public
    constructor Create(const Token, ChannelId: string; Cfg: TConfig;
                       Provider: ILLMProvider; Registry: TToolRegistry);
    procedure Run;
    procedure RequestStop;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.HTTP,
  PasClaw.Tools.ToolLoop,
  PasClaw.Identity;

(* ---- Webhook ---- *)

constructor TDiscordWebhook.Create(const WebhookURL: string);
begin
  inherited Create;
  FURL := WebhookURL;
end;

function TDiscordWebhook.Post(const Content: string): Boolean;
var
  Body: string;
  Obj: TJsonObject;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('content', Content);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  Resp := PostJSON(FURL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('discord webhook: status=%d body=%s', [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

function TDiscordWebhook.PostEmbed(const Title, Description: string; Color: Integer): Boolean;
var
  Body: string;
  Outer, Embed: TJsonObject;
  Embeds: TJsonArray;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  Outer  := TJsonObject.Create;
  Embed  := TJsonObject.Create;
  Embeds := TJsonArray.Create;
  try
    Embed.PutStr('title',       Title);
    Embed.PutStr('description', Description);
    Embed.PutInt('color',       Color);
    Embeds.AddObject(Embed);
    Outer.PutArray('embeds', Embeds);
    Body := Outer.ToJSON;
  finally
    Outer.Free;
    if Embed  <> nil then Embed.Free;   { only frees if AddObject didn't take it }
    if Embeds <> nil then Embeds.Free;
  end;
  Resp := PostJSON(FURL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
end;

(* ---- Bot polling ---- *)

constructor TDiscordBot.Create(const Token, ChannelId: string; Cfg: TConfig;
                               Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FToken    := Token;
  FChannel  := ChannelId;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FLastId   := '';
  FStop     := False;
end;

function TDiscordBot.FetchNewMessages(out RawJSON: string): Boolean;
var
  URL: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  RawJSON := '';
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bot ' + FToken);
  URL := 'https://discord.com/api/v10/channels/' + FChannel + '/messages?limit=20';
  if FLastId <> '' then
    URL := URL + '&after=' + FLastId;
  Resp := GetJSONURL(URL, Headers, 30);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    RawJSON := Resp.Body;
    Exit(True);
  end;
  LogWarn('discord fetch: status=%d err=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result := False;
end;

function TDiscordBot.PostMessage(const Content: string): Boolean;
var
  URL, Body: string;
  Headers: array of THeaderPair;
  Obj: TJsonObject;
  Resp: THTTPResult;
begin
  SetLength(Headers, 1);
  Headers[0] := MakeHeader('Authorization', 'Bot ' + FToken);
  URL := 'https://discord.com/api/v10/channels/' + FChannel + '/messages';
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('content', Content);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  Resp := PostJSON(URL, Body, Headers, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('discord post: status=%d body=%s', [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

procedure TDiscordBot.ProcessMessages(const ArrJSON: string);
var
  Arr: TJsonArray;
  Msg, Author: TJsonObject;
  i: Integer;
  Content, Id, NewestId, AuthorId, AuthorName: string;
  IsBot: Boolean;
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
begin
  Arr := TJsonArray.Parse(ArrJSON);
  if Arr = nil then Exit;
  NewestId := '';
  try
    { Discord returns newest first; iterate reversed so we reply in order. }
    for i := Arr.Count - 1 downto 0 do
    begin
      Msg := Arr.ItemObject(i);
      if Msg = nil then Continue;
      try
        Id      := Msg.GetStr('id', '');
        Content := Msg.GetStr('content', '');
        Author  := Msg.ChildObject('author');
        IsBot   := False;
        AuthorId   := '';
        AuthorName := '';
        if Author <> nil then
        begin
          IsBot      := Author.GetBool('bot',     False);
          AuthorId   := Author.GetStr ('id',      '');
          AuthorName := Author.GetStr ('username', '');
          Author.Free;
        end;
        if NewestId = '' then NewestId := Id;
        if (Id > FLastId) then FLastId := Id;
        if IsBot or (Content = '') then Continue;

        LogInfo('discord: msg from channel=%s: %s', [FChannel, Copy(Content, 1, 80)]);
        if FProvider = nil then
        begin
          PostMessage('(no provider configured)');
          Continue;
        end;

        { Default-init: locals are not zero-initialized; unset fields (e.g. DisableProgressLedger) would read stack garbage. }
        LoopCfg := Default(TToolLoopConfig);
        LoopCfg.Identity := MakeIdentity('discord', AuthorId, AuthorName, FChannel);
        if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
        begin
          LogInfo('discord: sender %s rejected by allow_senders',
                  [FormatIdentity(LoopCfg.Identity)]);
          Continue;
        end;

        SetLength(Msgs, 1);
        Msgs[0] := MakeMessage(mrUser, Content);
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
          PostMessage(Loop.Content);
      finally
        Msg.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

procedure TDiscordBot.Run;
var
  RawJSON: string;
begin
  if FToken = '' then begin LogError('discord: no bot token'); Exit; end;
  if FChannel = '' then begin LogError('discord: no channel id'); Exit; end;
  LogInfo('discord: polling channel %s', [FChannel]);
  while not FStop do
  begin
    if FetchNewMessages(RawJSON) then
      ProcessMessages(RawJSON);
    { Discord rate-limits -- keep poll interval > 1s. 3s is friendly. }
    Sleep(3000);
  end;
end;

procedure TDiscordBot.RequestStop;
begin
  FStop := True;
end;

end.
