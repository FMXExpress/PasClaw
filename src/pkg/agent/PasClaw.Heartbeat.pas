(*
  PasClaw.Heartbeat - periodic proactive wake-up. Reads
  $PASCLAW_HOME/workspace/heartbeat.md every IntervalMins minutes,
  runs RunToolLoop on its body, and optionally posts the result to
  a named channel from Cfg.Channels.

  Modelled after picoclaw / openclaw's heartbeat. The idea: the
  agent doesn't only respond when the user talks -- it also wakes
  up on its own, reads a short markdown file the user maintains
  ("check the build status; if it's been red over an hour, message
  me on Slack"), acts, optionally pushes the result somewhere the
  user is.

  The whole subsystem is off by default. Operators opt in via
  `pasclaw onboard` (Cfg.Heartbeat.Enabled := True) or by editing
  config.json's "heartbeat" block. Running `pasclaw heartbeat`
  without opt-in either succeeds with a warning or exits, depending
  on --force.

  Why it's its own thread / unit instead of piggybacking on cron:

    - Cron runs SKILLS via PasClaw.Cron.Scheduler, not the agent
      loop. Heartbeat runs the FULL tool loop: provider + registry
      + MCP + steering + checkpoints, the works.
    - Heartbeat doesn't need a cron expression -- just an interval
      and a content file.
    - Cron entries can already post to channels via the same
      Cfg.Channels indirection -- heartbeat just reuses that
      channel-name -> kind/target mapping.

  Lifecycle: Start spins up a TThread that sleeps IntervalMins
  between ticks (with a stop-event short-circuit so RequestStop
  doesn't wait the full interval). Each tick re-reads the content
  file from disk -- the operator's edits land on the next tick
  without restarting the daemon.

  Empty / missing content file = skip the tick. Otherwise the file's
  body becomes the user message to RunToolLoop; the assistant's
  reply gets logged, written to today's daily memory note (so
  memory_search picks it up on the next normal conversation), and
  posted to the configured channel if any. Failures (provider
  errors, sandbox refusals, tool errors) are logged but don't stop
  the daemon -- the next tick tries again.
*)
unit PasClaw.Heartbeat;

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
  THeartbeat = class
  private
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    FModel:    string;
    FThread:   TThread;
    FStopEvt:  TEvent;
    FStop:     Boolean;
    FTicks:    Integer;     { exposed for tests / stats }
    function ResolveContentPath: string;
    function ResolveChannelTarget(const ChannelName: string;
                                   out Kind, Target: string): Boolean;
    function PostToChannel(const Kind, Target, Message: string): Boolean;
    procedure RunOneTick;
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider;
                       Registry: TToolRegistry; const Model: string);
    destructor  Destroy; override;
    procedure Start;
    procedure RequestStop;
    procedure WaitForStop;
    { One-shot tick for testing or `pasclaw heartbeat --once`. Returns
      True iff the content file had a non-empty body AND the loop
      completed without provider/tool error. Safe to call without
      Start. }
    function  TickOnce: Boolean;
    property  Ticks: Integer read FTicks;
  end;

{ Default location of the heartbeat content file. Operators can
  override via Cfg.Heartbeat.ContentPath. }
function DefaultHeartbeatPath: string;

implementation

uses
  PasClaw.Workspaces,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Tools.ToolLoop,
  PasClaw.Shell.Backend,        { per-tick StartShellSession +
                                  SetCurrentSessionId so the docker
                                  backend gets its own container for
                                  every heartbeat tick }
  PasClaw.Channels.Discord,
  PasClaw.Channels.Slack,
  PasClaw.Channels.Teams,
  PasClaw.Channels.Webhook,
  PasClaw.Channels.LINE,
  PasClaw.Channels.WhatsApp;

const
  { Floor on IntervalMins. A 0-minute interval would spin; a negative
    value is meaningless. The defensible minimum is "every minute" --
    that's already aggressive for a model wake-up. }
  MinIntervalMins = 1;

function DefaultHeartbeatPath: string;
begin
  Result := JoinPath(GetHome, ActiveWorkspaceName + '/heartbeat.md');
end;

type
  THeartbeatThread = class(TThread)
  private
    FOwner: THeartbeat;
  protected
    procedure Execute; override;
  public
    constructor Create(Owner: THeartbeat);
  end;

constructor THeartbeatThread.Create(Owner: THeartbeat);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FOwner := Owner;
end;

procedure THeartbeatThread.Execute;
var
  Mins, WaitMs: Integer;
begin
  while not Terminated do
  begin
    try
      FOwner.RunOneTick;
    except
      on E: Exception do
        LogError('heartbeat: tick error: %s (%s)', [E.Message, E.ClassName]);
    end;
    Mins := FOwner.FCfg.Heartbeat.IntervalMins;
    if Mins < MinIntervalMins then Mins := MinIntervalMins;
    WaitMs := Mins * 60 * 1000;
    if FOwner.FStopEvt.WaitFor(Cardinal(WaitMs)) = wrSignaled then Break;
    if FOwner.FStop then Break;
  end;
end;

constructor THeartbeat.Create(Cfg: TConfig; Provider: ILLMProvider;
                              Registry: TToolRegistry; const Model: string);
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FModel    := Model;
  FStopEvt  := TEvent.Create(nil, True, False, '');
end;

destructor THeartbeat.Destroy;
begin
  RequestStop;
  WaitForStop;
  FStopEvt.Free;
  inherited Destroy;
end;

procedure THeartbeat.Start;
var
  ChanLabel: string;
begin
  if FThread <> nil then Exit;
  FThread := THeartbeatThread.Create(Self);
  FThread.Start;
  if FCfg.Heartbeat.Channel = '' then ChanLabel := '<none>'
  else ChanLabel := FCfg.Heartbeat.Channel;
  LogInfo('heartbeat: started (interval=%d min, content=%s, channel=%s)',
          [FCfg.Heartbeat.IntervalMins, ResolveContentPath, ChanLabel]);
end;

procedure THeartbeat.RequestStop;
begin
  FStop := True;
  FStopEvt.SetEvent;
end;

procedure THeartbeat.WaitForStop;
begin
  if FThread <> nil then
  begin
    FThread.WaitFor;
    FreeAndNil(FThread);
  end;
end;

function THeartbeat.ResolveContentPath: string;
begin
  Result := FCfg.Heartbeat.ContentPath;
  if Result = '' then
    Result := DefaultHeartbeatPath
  else if (Result <> '') and
          { Heuristic absolute-path check: POSIX leading '/' or
            Windows drive-letter ('C:'). Otherwise treat as
            workspace-relative and anchor on $PASCLAW_HOME. }
          (Result[1] <> '/') and
          ((Length(Result) < 2) or (Result[2] <> ':')) then
    Result := JoinPath(GetHome, Result);
end;

function THeartbeat.ResolveChannelTarget(const ChannelName: string;
                                         out Kind, Target: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  Kind   := '';
  Target := '';
  if Trim(ChannelName) = '' then Exit;
  for i := 0 to High(FCfg.Channels) do
    if SameText(FCfg.Channels[i].Name, ChannelName) then
    begin
      Kind   := FCfg.Channels[i].Kind;
      Target := FCfg.Channels[i].Target;
      Exit(True);
    end;
end;

function THeartbeat.PostToChannel(const Kind, Target, Message: string): Boolean;
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
  K := LowerCase(Trim(Kind));
  if K = 'discord' then
  begin
    Discord := TDiscordWebhook.Create(Target);
    try Result := Discord.Post(Message); finally Discord.Free; end;
  end
  else if K = 'slack' then
  begin
    Slack := TSlackWebhook.Create(Target);
    try Result := Slack.Post(Message); finally Slack.Free; end;
  end
  else if K = 'teams' then
  begin
    Teams := TTeamsWebhook.Create(Target);
    try Result := Teams.Post(Message); finally Teams.Free; end;
  end
  else if K = 'webhook' then
  begin
    Hook := TGenericWebhook.Create(Target,
              GetEnvironmentVariable('PASCLAW_WEBHOOK_AUTH'));
    try Result := Hook.Post(Message); finally Hook.Free; end;
  end
  else if K = 'line' then
  begin
    Token := GetEnvironmentVariable('PASCLAW_LINE_TOKEN');
    if Token = '' then Exit;
    Line := TLinePush.Create(Token);
    try Result := Line.Push(Target, Message); finally Line.Free; end;
  end
  else if K = 'whatsapp' then
  begin
    Token   := GetEnvironmentVariable('PASCLAW_WHATSAPP_TOKEN');
    PhoneId := GetEnvironmentVariable('PASCLAW_WHATSAPP_PHONE_ID');
    if (Token = '') or (PhoneId = '') then Exit;
    WA := TWhatsAppPush.Create(Token, PhoneId);
    try Result := WA.Push(Target, Message); finally WA.Free; end;
  end;
end;

procedure THeartbeat.RunOneTick;
begin
  TickOnce;
end;

function THeartbeat.TickOnce: Boolean;
var
  Path, Body, Reply: string;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  Cfg:  TToolLoopConfig;
  Kind, Target, SessionId: string;
begin
  Result := False;
  Inc(FTicks);
  { Heartbeats are ephemeral so each tick gets its own session id
    (and, on the docker backend, its own short-lived container).
    Tying the id to the tick number keeps the docker container
    naming deterministic per tick while still isolating ticks from
    one another in their state -- a `cd /tmp` in tick N doesn't
    survive into tick N+1. }
  SessionId := Format('heartbeat-tick-%d', [FTicks]);

  Path := ResolveContentPath;
  if not FileExists(Path) then
  begin
    LogDebug('heartbeat: no content file at %s -- skipping tick', [Path]);
    Exit;
  end;
  try
    Body := Trim(ReadFileText(Path));
  except
    on E: Exception do
    begin
      LogWarn('heartbeat: read %s failed: %s', [Path, E.Message]);
      Exit;
    end;
  end;
  if Body = '' then
  begin
    LogDebug('heartbeat: %s is empty -- skipping tick', [Path]);
    Exit;
  end;

  if FProvider = nil then
  begin
    LogWarn('heartbeat: no provider configured -- cannot tick');
    Exit;
  end;

  Cfg                := Default(TToolLoopConfig);
  Cfg.Provider       := FProvider;
  Cfg.Registry       := FRegistry;
  Cfg.Model          := FModel;
  Cfg.MaxIterations  := 4;     { tight -- heartbeats should not spin out }
  Cfg.Options        := DefaultChatOptions;
  Cfg.Options.SystemPrompt :=
    'You are PasClaw running on a heartbeat schedule. Read the user ' +
    'message (the contents of workspace/heartbeat.md) and act on it ' +
    'briefly. Keep the reply to a few lines -- it may be sent to a ' +
    'notification channel.';

  SetLength(Msgs, 1);
  Msgs[0].Role    := mrUser;
  Msgs[0].Content := Body;

  { Start the per-tick shell session (docker container) BEFORE the
    loop and close it AFTER -- so heartbeat ticks don't leak
    containers if the operator stops the daemon mid-tick. The
    Local backend's Start/Close are no-ops. }
  StartShellSession(SessionId);
  SetCurrentSessionId(SessionId);
  try
    try
      if not RunToolLoop(Cfg, Msgs, Loop) then
      begin
        LogWarn('heartbeat: tool loop failed (no reply)');
        Exit;
      end;
    except
      on E: Exception do
      begin
        LogError('heartbeat: tool loop raised %s: %s', [E.ClassName, E.Message]);
        Exit;
      end;
    end;

    Reply := Trim(Loop.Content);
    if Reply = '' then Reply := '(no reply)';
    LogInfo('heartbeat: tick %d ok (%d iters, reply=%d bytes)',
            [FTicks, Loop.Iterations, Length(Reply)]);

    if FCfg.Heartbeat.Channel <> '' then
    begin
      if ResolveChannelTarget(FCfg.Heartbeat.Channel, Kind, Target) then
      begin
        if not PostToChannel(Kind, Target,
                             Format('heartbeat:'#10'%s', [Reply])) then
          LogWarn('heartbeat: post to channel "%s" (%s) failed',
                  [FCfg.Heartbeat.Channel, Kind]);
      end
      else
        LogWarn('heartbeat: channel "%s" not declared in config.json',
                [FCfg.Heartbeat.Channel]);
    end;
    Result := True;
  finally
    CloseShellSession(SessionId);
    SetCurrentSessionId('');
  end;
end;

end.
