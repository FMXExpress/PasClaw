(*
  PasClaw.Tools.SendMessage - the `send_message` model tool. `pasclaw
  post` could already push to Discord / Slack / Teams / generic
  webhooks / LINE / WhatsApp, but only from the CLI -- the model had
  no way to notify a channel mid-task ("build finished", "deploy step
  3 needs approval"). This registers the same channel senders as a
  tool the model can call.

  Security shape: the model addresses channels strictly BY NAME. The
  name -> (kind, target) mapping lives in config.json under operator
  control:

      "channels": [
        { "name": "team-alerts", "kind": "slack",
          "target": "https://hooks.slack.com/services/..." },
        { "name": "ops",         "kind": "discord",
          "target": "https://discord.com/api/webhooks/..." }
      ]

  so a prompt-injected model cannot exfiltrate to a webhook URL it
  invented -- only to endpoints the operator pre-declared. When no
  channels are configured the tool is not registered at all (callers
  gate on Length(Cfg.Channels) > 0), so the schema doesn't spend
  context tokens on a tool that can only error.

  tcMutating: an outbound HTTP POST is a side effect; never fan it
  out in parallel with siblings.
*)
unit PasClaw.Tools.SendMessage;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Tools.Registry;

{ Register the send_message tool. No-op when the loaded config has no
  named channels -- check Length(LoadConfig.Channels) at the call site
  (NewBuiltinRegistry does) or just call this and let it gate itself. }
procedure RegisterSendMessageTool(R: TToolRegistry);

implementation

uses
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Tools.Types,
  PasClaw.Channels.Discord,
  PasClaw.Channels.Slack,
  PasClaw.Channels.Teams,
  PasClaw.Channels.Webhook,
  PasClaw.Channels.LINE,
  PasClaw.Channels.WhatsApp;

function ParseArg(const ArgsJSON, Field: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      Result := Obj.GetStr(Field, '');
    finally
      Obj.Free;
    end;
  except
    Result := '';
  end;
end;

function DispatchToChannel(const Kind, Target, Message: string;
                           out ErrMsg: string): Boolean;
var
  K, Token, PhoneId: string;
  Discord: TDiscordWebhook;
  Slack:   TSlackWebhook;
  Teams:   TTeamsWebhook;
  Hook:    TGenericWebhook;
  Line:    TLinePush;
  WA:      TWhatsAppPush;
begin
  Result := False;
  ErrMsg := '';
  K := LowerCase(Trim(Kind));
  if K = 'discord' then
  begin
    Discord := TDiscordWebhook.Create(Target);
    try Result := Discord.Post(Message);
    finally Discord.Free; end;
  end
  else if K = 'slack' then
  begin
    Slack := TSlackWebhook.Create(Target);
    try Result := Slack.Post(Message);
    finally Slack.Free; end;
  end
  else if K = 'teams' then
  begin
    Teams := TTeamsWebhook.Create(Target);
    try Result := Teams.Post(Message);
    finally Teams.Free; end;
  end
  else if K = 'webhook' then
  begin
    Hook := TGenericWebhook.Create(Target,
              GetEnvironmentVariable('PASCLAW_WEBHOOK_AUTH'));
    try Result := Hook.Post(Message);
    finally Hook.Free; end;
  end
  else if K = 'line' then
  begin
    Token := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
    if Token = '' then
    begin
      ErrMsg := 'line channel needs PASCLAW_LINE_TOKEN in the environment';
      Exit;
    end;
    Line := TLinePush.Create(Token);
    try Result := Line.Push(Target, Message);
    finally Line.Free; end;
  end
  else if K = 'whatsapp' then
  begin
    Token   := GetEnvironmentVariable('PASCLAW_WHATSAPP_TOKEN');
    PhoneId := GetEnvironmentVariable('PASCLAW_WHATSAPP_PHONE_ID');
    if (Token = '') or (PhoneId = '') then
    begin
      ErrMsg := 'whatsapp channel needs PASCLAW_WHATSAPP_TOKEN and ' +
                'PASCLAW_WHATSAPP_PHONE_ID in the environment';
      Exit;
    end;
    WA := TWhatsAppPush.Create(Token, PhoneId);
    try Result := WA.Push(Target, Message);
    finally WA.Free; end;
  end
  else
    ErrMsg := 'unsupported channel kind "' + Kind + '" (config error)';

  if (not Result) and (ErrMsg = '') then
    ErrMsg := Kind + ' post failed (HTTP error -- check the target URL/token)';
end;

function Tool_SendMessage(const ArgsJSON: string; out ErrMsg: string): string;
var
  Name, Message: string;
  Cfg: TConfig;
  i, Found: Integer;
  Kind, Target: string;
  Names: string;
begin
  ErrMsg := '';
  Result := '';
  Name    := Trim(ParseArg(ArgsJSON, 'channel'));
  Message := ParseArg(ArgsJSON, 'message');
  if Name = '' then begin ErrMsg := 'missing required argument: channel'; Exit; end;
  if Trim(Message) = '' then begin ErrMsg := 'missing required argument: message'; Exit; end;

  { Re-load config at call time (not registration time) so an operator
    editing config.json mid-session is honoured, and so the handler --
    a plain function pointer with no closure -- has somewhere to get
    the mapping from. }
  Cfg := LoadEffectiveConfig;
  try
    Found := -1;
    Names := '';
    for i := 0 to High(Cfg.Channels) do
    begin
      if Names <> '' then Names := Names + ', ';
      Names := Names + Cfg.Channels[i].Name;
      if SameText(Cfg.Channels[i].Name, Name) then Found := i;
    end;
    if Found < 0 then
    begin
      if Names = '' then
        ErrMsg := 'no channels configured -- the operator must add ' +
                  '"channels": [{name,kind,target}] to config.json'
      else
        ErrMsg := 'unknown channel "' + Name + '" (configured: ' + Names + ')';
      Exit;
    end;
    Kind   := Cfg.Channels[Found].Kind;
    Target := Cfg.Channels[Found].Target;
  finally
    Cfg.Free;
  end;

  if DispatchToChannel(Kind, Target, Message, ErrMsg) then
  begin
    LogInfo('send_message: posted %d bytes to %s (%s)',
            [Length(Message), Name, Kind]);
    Result := 'posted to ' + Name + ' (' + Kind + ')';
  end;
end;

procedure RegisterSendMessageTool(R: TToolRegistry);
var
  T: TTool;
  Cfg: TConfig;
  i: Integer;
  Names: string;
begin
  if R = nil then Exit;

  { Enumerate the configured channel names into the description so
    the model knows its options without a failed probe call. }
  Names := '';
  Cfg := LoadEffectiveConfig;
  try
    if Length(Cfg.Channels) = 0 then Exit;   { nothing to send to -- skip }
    for i := 0 to High(Cfg.Channels) do
    begin
      if Names <> '' then Names := Names + ', ';
      Names := Names + '"' + Cfg.Channels[i].Name + '" (' +
               Cfg.Channels[i].Kind + ')';
    end;
  finally
    Cfg.Free;
  end;

  T.Name        := 'send_message';
  T.Description :=
    'Send a notification message to one of the operator''s configured ' +
    'channels. Use it to push progress updates, alerts, or results to ' +
    'where the team is -- mid-task, without waiting for the turn to end. ' +
    'Configured channels: ' + Names + '.';
  T.Schema      := '{"type":"object",' +
    '"properties":{' +
    '"channel":{"type":"string","description":"Name of a configured channel (see tool description for the list)"},' +
    '"message":{"type":"string","description":"Plain-text message body to post"}' +
    '},"required":["channel","message"]}';
  T.Handler     := Tool_SendMessage;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcMutating;   { outbound HTTP POST -- never parallelize }
  R.Register(T);
end;

end.
