(*
  PasClaw.Channels.IRC - IRC bot client wrapping Indy's TIdIRC.

  Connects to a single server, joins a single channel (extending to
  multi-channel is a config-loop away), and replies in-channel to
  any message addressed to the bot -- either prefixed with the bot's
  nickname (e.g. "BotName: tell me about Pascal") or via private
  message. Mirrors the Telegram/Matrix bot shape: holds Cfg /
  Provider / Registry and runs RunToolLoop inline on each match.

  TIdIRC handles the wire protocol on its own dispatcher thread, so
  the bot doesn't need a worker thread of its own -- Start blocks
  only long enough to connect + JOIN, then returns. Reply dispatch
  runs on the IRC dispatcher's context thread.

  Configuration:
    Server hostname: $PASCLAW_IRC_SERVER     (e.g. irc.libera.chat)
    Port:            $PASCLAW_IRC_PORT       (default 6667 plain,
                                              6697 if TLS; this Wave 1
                                              adapter ships plaintext --
                                              users wanting TLS today
                                              can stunnel locally)
    Nickname:        $PASCLAW_IRC_NICK
    Channel:         $PASCLAW_IRC_CHANNEL    (must start with #)
    NickServ pass:   $PASCLAW_IRC_PASSWORD   (optional, sent at
                                              connect via PASS)

  Reply addressing:
    Channel msg starting with "<nick>:" or "<nick>," → bot replies.
    Direct PM to the bot                              → bot replies.
    Anything else in the channel is ignored -- there's enough chatter
    on IRC that a code agent yelling at every line is a no-go.

  Out of scope for Wave 1 (documented for future work):
    - Multi-channel / multi-server support. Add another bot
      instance if you want both.
    - TLS. TIdIRC inherits from TIdCmdTCPClient and supports an
      IOHandler; wiring an OpenSSL SSL handler here is a follow-up.
    - Flood control. Long bot replies get rate-limited by the
      server. The current code sends one PRIVMSG per response;
      split-by-line is a follow-up.

  Docs: https://datatracker.ietf.org/doc/html/rfc2812
*)
unit PasClaw.Channels.IRC;

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
  IdContext, IdIRC,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry;

type
  TIRCBot = class
  private
    FServer:   string;
    FPort:     Integer;
    FNick:     string;
    FChannel:  string;
    FPassword: string;
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FClient:   TIdIRC;
    procedure HandlePrivMessage(ASender: TIdContext;
                                 const ANickname, AHost, ATarget, AMessage: string);
    procedure HandleJoin(ASender: TIdContext;
                          const ANickname, AHost, AChannel: string);
    function  ExtractAddressedText(const Message: string;
                                    out IsAddressed: Boolean): string;
    procedure RunAgentReply(const ReplyTarget, UserText, SenderNick: string);
  public
    constructor Create(const Server: string; Port: Integer;
                       const Nick, Channel, Password: string;
                       Cfg: TConfig; Provider: ILLMProvider;
                       Registry: TToolRegistry);
    destructor  Destroy; override;
    procedure Start;
    procedure RequestStop;
    procedure WaitForStop;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop,
  PasClaw.Identity;

type
  (* PR #86 Codex P2: RunToolLoop inside OnPrivateMessage blocks
     Indy's TIdCmdTCPClient listener thread. A slow model turn
     (tool loop chasing fs_read / shell_exec) keeps the listener
     from servicing PING from the server, the server kills the
     connection after its ping-timeout, and the bot drops.

     Fix: hand each inbound message off to a self-freeing worker
     thread. OnPrivateMessage returns immediately, the listener
     keeps PONGing on schedule, and the worker drives RunToolLoop +
     the FClient.Say reply asynchronously. Same suspended-then-
     Start idiom from PR #78's LINE/WhatsApp worker fix. *)
  TIRCMessageWorker = class(TThread)
  private
    FBot:         TIRCBot;
    FReplyTarget: string;
    FUserText:    string;
    FSenderNick:  string;
  public
    constructor Create(Bot: TIRCBot;
                       const ReplyTarget, UserText, SenderNick: string);
    procedure Execute; override;
  end;

constructor TIRCMessageWorker.Create(Bot: TIRCBot;
                                      const ReplyTarget, UserText, SenderNick: string);
begin
  inherited Create(True);   { suspended }
  FreeOnTerminate := True;
  FBot         := Bot;
  FReplyTarget := ReplyTarget;
  FUserText    := UserText;
  FSenderNick  := SenderNick;
  Start;
end;

procedure TIRCMessageWorker.Execute;
begin
  try
    FBot.RunAgentReply(FReplyTarget, FUserText, FSenderNick);
  except
    on E: Exception do
      LogWarn('irc worker: RunAgentReply raised %s: %s',
              [E.ClassName, E.Message]);
  end;
end;

constructor TIRCBot.Create(const Server: string; Port: Integer;
                            const Nick, Channel, Password: string;
                            Cfg: TConfig; Provider: ILLMProvider;
                            Registry: TToolRegistry);
begin
  inherited Create;
  FServer   := Server;
  FPort     := Port;
  if FPort = 0 then FPort := 6667;
  FNick     := Nick;
  FChannel  := Channel;
  FPassword := Password;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
end;

destructor TIRCBot.Destroy;
begin
  RequestStop;
  inherited Destroy;
end;

function TIRCBot.ExtractAddressedText(const Message: string;
                                       out IsAddressed: Boolean): string;
var
  LowMsg, LowNick: string;
  Prefix, Sep: string;
  PrefixLen: Integer;
begin
  { Recognise "<nick>:" or "<nick>," followed by space. Tolerates
    trailing whitespace in the prefix. Case-insensitive on the nick
    so "BotName" and "botname" both work. }
  IsAddressed := False;
  Result := '';
  LowMsg  := LowerCase(Message);
  LowNick := LowerCase(FNick);
  Prefix  := LowNick + ':';
  PrefixLen := Length(Prefix);
  if (Length(LowMsg) >= PrefixLen) and (Copy(LowMsg, 1, PrefixLen) = Prefix) then
    Sep := ':'
  else
  begin
    Prefix := LowNick + ',';
    if (Length(LowMsg) >= PrefixLen) and (Copy(LowMsg, 1, PrefixLen) = Prefix) then
      Sep := ','
    else
      Exit;
  end;
  IsAddressed := True;
  Result := Trim(Copy(Message, PrefixLen + 1, MaxInt));
end;

procedure TIRCBot.RunAgentReply(const ReplyTarget, UserText, SenderNick: string);
var
  Msgs: array of TMessage;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Response: string;
begin
  LogInfo('irc: target=%s from=%s msg=%s',
          [ReplyTarget, SenderNick, Copy(UserText, 1, 80)]);

  if FProvider = nil then
  begin
    if FClient <> nil then
      FClient.Say(ReplyTarget,
                   SenderNick + ': (no provider configured -- run `pasclaw onboard`)');
    Exit;
  end;

  LoopCfg.Identity := MakeIdentity('irc', SenderNick, SenderNick, ReplyTarget);
  if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
  begin
    LogInfo('irc: sender %s rejected by allow_senders',
            [FormatIdentity(LoopCfg.Identity)]);
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, UserText);

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

  if FClient = nil then Exit;

  { Channel replies prefix with the sender's nick so they know it's
    aimed at them. PMs don't need that -- the conversation context
    is implicit. }
  if (Length(ReplyTarget) > 0) and (ReplyTarget[1] = '#') then
    FClient.Say(ReplyTarget, SenderNick + ': ' + Response)
  else
    FClient.Say(ReplyTarget, Response);
end;

procedure TIRCBot.HandlePrivMessage(ASender: TIdContext;
                                     const ANickname, AHost, ATarget,
                                            AMessage: string);
var
  Text: string;
  IsAddressed: Boolean;
  ReplyTarget: string;
begin
  if SameText(ANickname, FNick) then Exit;   { our own echoes -- ignore }

  if SameText(ATarget, FNick) then
  begin
    { Direct PM. Spawn a worker so RunToolLoop doesn't block the
      Indy listener (server PINGs would time out and disconnect
      the bot). Worker frees itself on terminate. }
    TIRCMessageWorker.Create(Self, ANickname, AMessage, ANickname);
    Exit;
  end;

  { Channel message. Only respond when addressed by name. }
  if (Length(ATarget) > 0) and (ATarget[1] = '#') then
  begin
    Text := ExtractAddressedText(AMessage, IsAddressed);
    if not IsAddressed then Exit;
    if Trim(Text) = '' then Exit;
    ReplyTarget := ATarget;
    TIRCMessageWorker.Create(Self, ReplyTarget, Text, ANickname);
  end;
end;

procedure TIRCBot.HandleJoin(ASender: TIdContext;
                              const ANickname, AHost, AChannel: string);
begin
  if SameText(ANickname, FNick) then
    LogInfo('irc: joined %s', [AChannel]);
end;

procedure TIRCBot.Start;
begin
  if FClient <> nil then Exit;
  if (FServer = '') or (FNick = '') then
  begin
    LogError('irc: server or nick missing -- bot not started', []);
    Exit;
  end;

  FClient := TIdIRC.Create(nil);
  FClient.Host         := FServer;
  FClient.Port         := FPort;
  FClient.Nickname     := FNick;
  FClient.Username     := FNick;
  FClient.RealName     := 'PasClaw IRC bot';
  if FPassword <> '' then FClient.Password := FPassword;
  FClient.OnPrivateMessage := HandlePrivMessage;
  FClient.OnJoin           := HandleJoin;

  try
    FClient.Connect;
  except
    on E: Exception do
    begin
      LogError('irc: connect to %s:%d failed: %s', [FServer, FPort, E.Message]);
      FreeAndNil(FClient);
      Exit;
    end;
  end;

  LogInfo('irc: connected to %s:%d as %s', [FServer, FPort, FNick]);

  if FChannel <> '' then
  begin
    try
      FClient.Join(FChannel);
    except
      on E: Exception do
        LogWarn('irc: join %s failed: %s', [FChannel, E.Message]);
    end;
  end;
end;

procedure TIRCBot.RequestStop;
begin
  if FClient = nil then Exit;
  try
    if FClient.Connected then FClient.Disconnect;
  except
    on E: Exception do
      LogWarn('irc: disconnect error: %s', [E.Message]);
  end;
  FreeAndNil(FClient);
end;

procedure TIRCBot.WaitForStop;
begin
  { TIdIRC inherits TIdCmdTCPClient which spawns its own listener
    thread; Disconnect (called from RequestStop) tears it down
    synchronously. Nothing left to wait on. }
end;

end.
