(*
  PasClaw.Cron.Sinks - where a fired cron's output goes.

  Two sinks, both optional and independent:

    AppendCronToDaily - appends a dated section to
                        <home>/workspace/memory/<today>.md so the
                        model can recall cron output on the next turn
                        (memory_search picks it up via the FTS5
                        index, and BuildMemorySection auto-injects
                        today's note into the system prompt). Output
                        is truncated to keep daily notes readable; if
                        the cron job produces megabytes, only the
                        first chunk lands in memory.

    PostCronToChannel - dispatches to the existing outbound channel
                        adapters (Discord, Slack, Teams, generic
                        webhook, LINE push, WhatsApp push). The cron
                        entry's ChannelKind picks the adapter;
                        ChannelTarget is the webhook URL / userId /
                        phone number. LINE and WhatsApp read their
                        credentials from PASCLAW_LINE_TOKEN /
                        PASCLAW_WHATSAPP_TOKEN+PHONE_ID at fire time
                        -- match the existing `pasclaw post` shape so
                        cron and CLI use the same env vars.

  Both sinks return Boolean; failure logs warn and continues so a
  Slack outage doesn't keep cron from updating memory (or vice
  versa).
*)
unit PasClaw.Cron.Sinks;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  MAX_CRON_OUTPUT_TO_MEMORY  = 2000;   { chars; longer outputs get truncated }
  MAX_CRON_OUTPUT_TO_CHANNEL = 3500;   { Slack/Discord cap text around 4KB; leave headroom }

function AppendCronToDaily(const Id, Skill, Output: string): Boolean;
function PostCronToChannel(const Kind, Target, Text: string): Boolean;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Channels.Discord,
  PasClaw.Channels.Slack,
  PasClaw.Channels.Teams,
  PasClaw.Channels.Webhook,
  PasClaw.Channels.LINE,
  PasClaw.Channels.WhatsApp;

function DailyNotePath: string;
begin
  Result := JoinPath(GetHome,
              ActiveWorkspaceName + '/memory/' +
              FormatDateTime('yyyy-mm-dd', Now) + '.md');
end;

function ReadOptional(const Path: string): string;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  try
    Result := ReadFileText(Path);
  except
    Result := '';
  end;
end;

function AppendCronToDaily(const Id, Skill, Output: string): Boolean;
var
  Path, Existing, Section, Body: string;
begin
  Path := DailyNotePath;
  EnsureDir(ExtractFilePath(Path));
  Existing := ReadOptional(Path);

  Body := Output;
  if Length(Body) > MAX_CRON_OUTPUT_TO_MEMORY then
    Body := Copy(Body, 1, MAX_CRON_OUTPUT_TO_MEMORY) +
            sLineBreak + sLineBreak +
            '_(truncated -- full output went to the gateway log)_';

  Section :=
    sLineBreak +
    '## cron[' + Id + '] @ ' + FormatDateTime('hh:nn:ss', Now) +
    ' (skill=' + Skill + ')' + sLineBreak +
    sLineBreak + Body + sLineBreak;

  try
    if Existing = '' then
      WriteFileText(Path,
        '# Daily memory ' + FormatDateTime('yyyy-mm-dd', Now) + sLineBreak +
        Section)
    else
      WriteFileText(Path, Existing + Section);
    Result := True;
  except
    on E: Exception do
    begin
      LogWarn('cron.sink: append to %s failed: %s', [Path, E.Message]);
      Result := False;
    end;
  end;
end;

function PostCronToChannel(const Kind, Target, Text: string): Boolean;
var
  Body: string;
  D: TDiscordWebhook;
  S: TSlackWebhook;
  T: TTeamsWebhook;
  W: TGenericWebhook;
  L: TLinePush;
  P: TWhatsAppPush;
  Token, PhoneId: string;
begin
  Result := False;
  if (Kind = '') or (Target = '') then Exit;

  Body := Text;
  if Length(Body) > MAX_CRON_OUTPUT_TO_CHANNEL then
    Body := Copy(Body, 1, MAX_CRON_OUTPUT_TO_CHANNEL) + #10'…(truncated)';

  if Kind = 'discord' then
  begin
    D := TDiscordWebhook.Create(Target);
    try Result := D.Post(Body); finally D.Free; end;
  end
  else if Kind = 'slack' then
  begin
    S := TSlackWebhook.Create(Target);
    try Result := S.Post(Body); finally S.Free; end;
  end
  else if Kind = 'teams' then
  begin
    T := TTeamsWebhook.Create(Target);
    try Result := T.Post(Body); finally T.Free; end;
  end
  else if Kind = 'webhook' then
  begin
    W := TGenericWebhook.Create(Target,
                                GetEnvironmentVariable('PASCLAW_WEBHOOK_AUTH'));
    try Result := W.Post(Body); finally W.Free; end;
  end
  else if Kind = 'line' then
  begin
    Token := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
    if Token = '' then
    begin
      LogWarn('cron.sink: line target %s but $PASCLAW_LINE_TOKEN unset',
              [Target]);
      Exit;
    end;
    L := TLinePush.Create(Token);
    try Result := L.Push(Target, Body); finally L.Free; end;
  end
  else if Kind = 'whatsapp' then
  begin
    Token   := GetEnvironmentVariable('PASCLAW_WHATSAPP_TOKEN');
    PhoneId := GetEnvironmentVariable('PASCLAW_WHATSAPP_PHONE_ID');
    if (Token = '') or (PhoneId = '') then
    begin
      LogWarn('cron.sink: whatsapp target %s but $PASCLAW_WHATSAPP_TOKEN ' +
              'or $PASCLAW_WHATSAPP_PHONE_ID unset', [Target]);
      Exit;
    end;
    P := TWhatsAppPush.Create(Token, PhoneId);
    try Result := P.Push(Target, Body); finally P.Free; end;
  end
  else
    LogWarn('cron.sink: unknown channel kind %s', [Kind]);
end;

end.
