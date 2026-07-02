(*
  PasClaw.Channels.Telegram - long-polling Telegram bot adapter.

  Uses PasClaw.Providers.HTTP to call the Bot API. No webhook needed - getUpdates with a
  long poll keeps things firewall-friendly. Each incoming text message is
  fed to the agent loop and the reply is sent back via sendMessage.

  Configure with PASCLAW_TELEGRAM_TOKEN or pass --token on the command line.
  Bot API docs: https://core.telegram.org/bots/api
*)
unit PasClaw.Channels.Telegram;

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
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TTelegramChannel = class
  private
    FToken:     string;
    FCfg:       TConfig;
    FProvider:  ILLMProvider;
    FRegistry:  TToolRegistry;
    FOffset:    Int64;
    FStop:      Boolean;
    function ApiUrl(const Method: string): string;
    function GetUpdates(out RawJSON: string): Boolean;
    function SendMessage(ChatId: Int64; const Text: string): Boolean;
    procedure ProcessUpdate(const UpdateJSON: string);
  public
    constructor Create(const Token: string; Cfg: TConfig;
                       Provider: ILLMProvider; Registry: TToolRegistry);
    procedure Run;       { blocks until Stop is called or Ctrl-C }
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

constructor TTelegramChannel.Create(const Token: string; Cfg: TConfig;
                                    Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FToken    := Token;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FOffset   := 0;
  FStop     := False;
end;

function TTelegramChannel.ApiUrl(const Method: string): string;
begin
  Result := 'https://api.telegram.org/bot' + FToken + '/' + Method;
end;

function TTelegramChannel.GetUpdates(out RawJSON: string): Boolean;
var
  URL: string;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  RawJSON := '';
  SetLength(Empty, 0);
  URL := ApiUrl('getUpdates') +
         '?timeout=25&offset=' + IntToStr(FOffset);
  Resp := GetJSONURL(URL, Empty, 30);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    RawJSON := Resp.Body;
    Exit(True);
  end;
  LogWarn('telegram getUpdates failed: status=%d err=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result := False;
end;

function TTelegramChannel.SendMessage(ChatId: Int64; const Text: string): Boolean;
var
  URL, Body: string;
  Empty: array of THeaderPair;
  J: TJsonObject;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  URL := ApiUrl('sendMessage');
  J := TJsonObject.Create;
  try
    J.PutInt('chat_id', ChatId);
    J.PutStr('text',    Text);
    Body := J.ToJSON;
  finally
    J.Free;
  end;
  Resp := PostJSON(URL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('telegram sendMessage failed: status=%d body=%s', [Resp.StatusCode, Copy(Resp.Body,1,200)]);
end;

procedure TTelegramChannel.ProcessUpdate(const UpdateJSON: string);
var
  Obj, Msg, Chat, From: TJsonObject;
  Text, FromId, FromName: string;
  ChatId, UpdateId: Int64;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Msgs: array of TMessage;
begin
  Obj := TJsonObject.Parse(UpdateJSON);
  if Obj = nil then Exit;
  try
    UpdateId := Obj.GetInt('update_id', 0);
    if UpdateId >= FOffset then FOffset := UpdateId + 1;
    Msg := Obj.ChildObject('message');
    if Msg = nil then Exit;
    try
      Chat := Msg.ChildObject('chat');
      if Chat = nil then Exit;
      try
        ChatId := Chat.GetInt('id', 0);
      finally
        Chat.Free;
      end;
      { Sender identity for allow_senders gating. In group chats
        message.chat.id is the GROUP, not the user -- using it as the
        canonical id would let every group member through a single
        allowlist entry. message.from.id is the actual sender;
        chat.id rides along as RoomId so a hook can still filter
        by room when it wants to. Codex P1 on PR #119. }
      FromId   := '';
      FromName := '';
      From := Msg.ChildObject('from');
      if From <> nil then
      try
        FromId   := IntToStr(From.GetInt('id', 0));
        if FromId = '0' then FromId := '';
        FromName := From.GetStr('username', '');
        if FromName = '' then FromName := From.GetStr('first_name', '');
      finally
        From.Free;
      end;
      Text := Msg.GetStr('text', '');
      if Text = '' then Exit;
    finally
      Msg.Free;
    end;
  finally
    Obj.Free;
  end;

  LogInfo('telegram: chat=%d from=%s msg=%s', [ChatId, FromId, Copy(Text, 1, 80)]);

  if FProvider = nil then
  begin
    SendMessage(ChatId, '(no provider configured -- run `pasclaw onboard`)');
    Exit;
  end;

  { Default-init: locals are not zero-initialized; unset fields (e.g. DisableProgressLedger) would read stack garbage. }
  LoopCfg := Default(TToolLoopConfig);
  LoopCfg.Identity := MakeIdentity('telegram', FromId, FromName, IntToStr(ChatId));
  if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
  begin
    LogInfo('telegram: sender %s rejected by allow_senders',
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
    SendMessage(ChatId, Loop.Content)
  else
    SendMessage(ChatId, '(sorry -- model returned no content)');
end;

procedure TTelegramChannel.Run;
var
  RawJSON: string;
  Obj, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  if FToken = '' then
  begin
    LogError('telegram: no bot token (set PASCLAW_TELEGRAM_TOKEN or --token)');
    Exit;
  end;
  LogInfo('telegram: long-poll started (token ...%s)',
    [Copy(FToken, Length(FToken) - 5, 5)]);

  while not FStop do
  begin
    if not GetUpdates(RawJSON) then
    begin
      Sleep(2000);
      Continue;
    end;
    Obj := TJsonObject.Parse(RawJSON);
    if Obj = nil then begin Sleep(1000); Continue; end;
    try
      if not Obj.GetBool('ok', False) then Continue;
      Arr := Obj.ChildArray('result');
      if Arr = nil then Continue;
      try
        for i := 0 to Arr.Count - 1 do
        begin
          Item := Arr.ItemObject(i);
          if Item = nil then Continue;
          try
            ProcessUpdate(Item.ToJSON);
          finally
            Item.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
    finally
      Obj.Free;
    end;
  end;
  LogInfo('telegram: long-poll stopped');
end;

procedure TTelegramChannel.RequestStop;
begin
  FStop := True;
end;

end.
