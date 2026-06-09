(*
  PasClaw.Channels.Email - bidirectional email channel.

  Outbound: TIdSMTP -- sends a text/plain message to a recipient with
  the configured From address. Uses STARTTLS by default; explicit TLS
  on port 465 is the alternative when SMTPSSLMode = sslmTLS.

  Inbound: TIdIMAP4 polling. Connects, selects INBOX, list-fetches
  every UNSEEN message, runs each through the agent loop, replies via
  SMTP, then marks the message Seen so we don't process it again. The
  polling interval defaults to 30s; configure with PASCLAW_EMAIL_POLL.

  Configuration via env vars (all required for the bot path; SMTP-only
  push works with the SMTP set alone):

      PASCLAW_EMAIL_SMTP_HOST      smtp.example.com
      PASCLAW_EMAIL_SMTP_PORT      587            (or 465 for sslmTLS)
      PASCLAW_EMAIL_SMTP_USER      bot@example.com
      PASCLAW_EMAIL_SMTP_PASS      app-password
      PASCLAW_EMAIL_SMTP_TLS       starttls       (or "tls" for 465)
      PASCLAW_EMAIL_FROM           bot@example.com
      PASCLAW_EMAIL_IMAP_HOST      imap.example.com
      PASCLAW_EMAIL_IMAP_PORT      993
      PASCLAW_EMAIL_IMAP_USER      bot@example.com
      PASCLAW_EMAIL_IMAP_PASS      app-password
      PASCLAW_EMAIL_POLL           30s            (optional; min 5s)
      PASCLAW_EMAIL_ALLOW          @example.com   (optional sender allowlist;
                                                   substring match, comma-separated)

  The bot only auto-replies when the inbound From address matches the
  allowlist (substring). Without an allowlist, every UNSEEN message is
  answered -- fine for a personal mailbox, dangerous for a shared one.
*)
unit PasClaw.Channels.Email;

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
  TEmailSMTPMode = (esmStartTLS, esmExplicitTLS, esmPlain);

  TEmailAuth = record
    Host: string;
    Port: Integer;
    User: string;
    Pass: string;
    Mode: TEmailSMTPMode;  { SMTP only; IMAP forces explicit TLS on 993 }
  end;

  TEmailChannel = class
  private
    FCfg:       TConfig;
    FProvider:  ILLMProvider;
    FRegistry:  TToolRegistry;
    FSMTP:      TEmailAuth;
    FIMAP:      TEmailAuth;
    FFrom:      string;
    FAllow:     TStringArray;   { named type, not `array of string`, so Delphi 12
                                  dcc64 accepts the SplitCSV(...) assignment
                                  result without an E2010 -- same pattern as
                                  PR #104 fixed for TLLMProviderArray. }
    FPollSec:   Integer;
    FStop:      Boolean;
    FWorker:    TThread;
    function MatchesAllow(const FromAddr: string): Boolean;
    procedure ProcessInbox;
    procedure RunOnePoll;
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
    destructor  Destroy; override;
    { Send a single text message. Returns False on transport error; the
      ErrMsg holds a one-line description. Doesn't require IMAP. }
    function Push(const Recipient, Subject, Body: string;
                  out ErrMsg: string): Boolean;
    { Block and poll IMAP until RequestStop is called. Each unseen
      message routes to the agent loop and the reply is sent via SMTP. }
    procedure Run;
    { Spawn Run on a dedicated TThread and return immediately. The
      worker stays alive until Stop is called; the gateway is
      responsible for calling Stop before tearing down FProvider /
      FRegistry / FCfg so the worker can't dereference freed state. }
    procedure Spawn;
    { Signal the worker to wind down on the next poll boundary
      (≤500ms), then join it. Safe to call repeatedly. }
    procedure Stop;
    procedure RequestStop;
  end;

implementation

uses
  DateUtils,
  IdSMTP, IdIMAP4, IdMessage, IdSSLOpenSSL, IdExplicitTLSClientServerBase,
  IdMessageBuilder, IdMessageParts, IdAttachmentFile,
  IdMailBox,  { TUInt32Array -- needed for the Unseen local in ProcessInbox
                because IMAP.MailBox.SearchResult is declared as
                TUInt32Array; dcc64 won't assign it into an inline
                `array of UInt32` (PR #104 same pattern). }
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.Factory,
  PasClaw.Tools.ToolLoop,
  PasClaw.Identity;

const
  { Per-operation IMAP / SMTP timeout. Bounds how long a single
    Connect / Login / Retrieve / Send can block before raising; in
    turn bounds Email.Stop's shutdown wait. 30s is generous for
    healthy mail servers (typical SMTP STARTTLS roundtrip is well
    under a second) and tight enough that a wedged server doesn't
    keep the gateway alive for minutes. Tune via constant edit if
    your environment legitimately needs more. }
  EmailIOTimeoutMS = 30000;

{ TThread.WaitFor blocks indefinitely -- Indy doesn't ship a
  timeout-aware variant. Poll Finished at 50ms granularity for up
  to TimeoutMS, return True if the thread exited in time. }
function WaitForWorkerWithTimeout(W: TThread; TimeoutMS: Cardinal): Boolean;
var
  Elapsed: Cardinal;
const
  PollMS = 50;
begin
  Elapsed := 0;
  while (not W.Finished) and (Elapsed < TimeoutMS) do
  begin
    Sleep(PollMS);
    Inc(Elapsed, PollMS);
  end;
  Result := W.Finished;
end;

function ParseSMTPMode(const S: string): TEmailSMTPMode;
var
  L: string;
begin
  L := LowerCase(S);
  if (L = 'tls') or (L = 'sslm') or (L = 'explicit') then
    Result := esmExplicitTLS
  else if (L = 'plain') or (L = 'none') then
    Result := esmPlain
  else
    Result := esmStartTLS;
end;

function ParsePollSeconds(const S: string): Integer;
var
  N: Integer;
  T: string;
begin
  Result := 30;
  T := Trim(S);
  if T = '' then Exit;
  { Strip trailing s/m/h. CharInSet (vs `in [...]`) silences dcc64
    W1050: on the modern compiler Char is WideChar and a bare set
    membership test against byte-char literals narrows implicitly. }
  if (Length(T) > 1) and CharInSet(T[Length(T)], ['s', 'm', 'h', 'S', 'M', 'H']) then
  begin
    case T[Length(T)] of
      's', 'S': N := 1;
      'm', 'M': N := 60;
      'h', 'H': N := 3600;
    else
      N := 1;
    end;
    SetLength(T, Length(T) - 1);
  end
  else
    N := 1;
  if TryStrToInt(Trim(T), Result) then
    Result := Result * N
  else
    Result := 30;
  if Result < 5 then Result := 5;
end;

function SplitCSV(const S: string): TStringArray;
var
  L: TStringList;
  i: Integer;
begin
  SetLength(Result, 0);
  if S = '' then Exit;
  L := TStringList.Create;
  try
    L.Delimiter := ',';
    L.StrictDelimiter := True;
    L.DelimitedText := S;
    SetLength(Result, L.Count);
    for i := 0 to L.Count - 1 do
      Result[i] := LowerCase(Trim(L[i]));
  finally
    L.Free;
  end;
end;

constructor TEmailChannel.Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;

  FSMTP.Host := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_HOST');
  FSMTP.Port := StrToIntDef(GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_PORT'), 587);
  FSMTP.User := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_USER');
  FSMTP.Pass := GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_PASS');
  FSMTP.Mode := ParseSMTPMode(GetEnvironmentVariable('PASCLAW_EMAIL_SMTP_TLS'));
  FFrom      := GetEnvironmentVariable('PASCLAW_EMAIL_FROM');
  if FFrom = '' then FFrom := FSMTP.User;

  FIMAP.Host := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_HOST');
  FIMAP.Port := StrToIntDef(GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PORT'), 993);
  FIMAP.User := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_USER');
  FIMAP.Pass := GetEnvironmentVariable('PASCLAW_EMAIL_IMAP_PASS');
  FIMAP.Mode := esmExplicitTLS;  { IMAPS on 993 }

  FPollSec := ParsePollSeconds(GetEnvironmentVariable('PASCLAW_EMAIL_POLL'));
  FAllow   := SplitCSV(GetEnvironmentVariable('PASCLAW_EMAIL_ALLOW'));

  FStop := False;
end;

function TEmailChannel.MatchesAllow(const FromAddr: string): Boolean;
var
  i: Integer;
  L: string;
begin
  if Length(FAllow) = 0 then Exit(True);  { no allowlist = allow all }
  L := LowerCase(FromAddr);
  for i := 0 to High(FAllow) do
    if (FAllow[i] <> '') and (Pos(FAllow[i], L) > 0) then
      Exit(True);
  Result := False;
end;

function TEmailChannel.Push(const Recipient, Subject, Body: string;
                             out ErrMsg: string): Boolean;
var
  SMTP: TIdSMTP;
  SSL:  TIdSSLIOHandlerSocketOpenSSL;
  Msg:  TIdMessage;
begin
  ErrMsg := '';
  if FSMTP.Host = '' then
  begin
    ErrMsg := 'PASCLAW_EMAIL_SMTP_HOST not set';
    Exit(False);
  end;
  SMTP := TIdSMTP.Create(nil);
  SSL  := nil;
  Msg  := TIdMessage.Create(nil);
  try
    if FSMTP.Mode <> esmPlain then
    begin
      SSL := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
      SSL.SSLOptions.Method := sslvTLSv1_2;
      SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
      SMTP.IOHandler := SSL;
      if FSMTP.Mode = esmExplicitTLS then
        SMTP.UseTLS := utUseImplicitTLS
      else
        SMTP.UseTLS := utUseExplicitTLS;
    end;
    SMTP.Host           := FSMTP.Host;
    SMTP.Port           := FSMTP.Port;
    SMTP.Username       := FSMTP.User;
    SMTP.Password       := FSMTP.Pass;
    SMTP.AuthType       := satDefault;
    SMTP.ConnectTimeout := EmailIOTimeoutMS;
    SMTP.ReadTimeout    := EmailIOTimeoutMS;

    Msg.From.Address := FFrom;
    Msg.Recipients.EMailAddresses := Recipient;
    Msg.Subject := Subject;
    Msg.Body.Text := Body;
    Msg.ContentType := 'text/plain; charset=utf-8';

    try
      SMTP.Connect;
      try
        SMTP.Authenticate;
        SMTP.Send(Msg);
      finally
        SMTP.Disconnect;
      end;
      Result := True;
    except
      on E: Exception do
      begin
        ErrMsg := E.ClassName + ': ' + E.Message;
        Result := False;
      end;
    end;
  finally
    Msg.Free;
    if SSL <> nil then SSL.Free;
    SMTP.Free;
  end;
end;

procedure TEmailChannel.ProcessInbox;
var
  IMAP: TIdIMAP4;
  SSL:  TIdSSLIOHandlerSocketOpenSSL;
  Msg:  TIdMessage;
  Unseen: TUInt32Array;
  Search: array of TIdIMAP4SearchRec;
  SeqNum: UInt32;
  k: Integer;
  FromAddr, Subj, BodyText, Reply, PushErr: string;
  RToolMsgs: array of TMessage;
  LoopCfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  ReplySent, ReplyAttempted: Boolean;
begin
  if (FIMAP.Host = '') or (FIMAP.User = '') then
  begin
    LogWarn('email IMAP config incomplete -- inbound disabled');
    Exit;
  end;
  IMAP := TIdIMAP4.Create(nil);
  SSL  := TIdSSLIOHandlerSocketOpenSSL.Create(nil);
  try
    SSL.SSLOptions.Method := sslvTLSv1_2;
    SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
    IMAP.IOHandler := SSL;
    IMAP.UseTLS := utUseImplicitTLS;
    IMAP.Host := FIMAP.Host;
    IMAP.Port := FIMAP.Port;
    IMAP.Username := FIMAP.User;
    IMAP.Password := FIMAP.Pass;
    { Bounded I/O: if the IMAP server stalls, individual ops fail
      after 30s instead of blocking the worker forever. Caps the
      shutdown latency Email.Stop sees at roughly one ReadTimeout
      cycle. }
    IMAP.ConnectTimeout := EmailIOTimeoutMS;
    IMAP.ReadTimeout    := EmailIOTimeoutMS;

    try
      IMAP.Connect;
      try
        IMAP.Login;
        IMAP.SelectMailBox('INBOX');
        { Server-side filter for unread messages -- iterating
          1..TotalMsgs and checking flags client-side would still
          re-Retrieve already-seen messages every poll, growing
          linearly with mailbox size. SEARCH UNSEEN returns only
          the sequence numbers we actually need to process. }
        SetLength(Search, 1);
        Search[0].SearchKey := skUnseen;
        if not IMAP.SearchMailBox(Search) then
        begin
          LogWarn('email IMAP SEARCH UNSEEN failed');
          Exit;
        end;
        Unseen := Copy(IMAP.MailBox.SearchResult);
        if Length(Unseen) = 0 then Exit;
        LogDebug('email: %d unseen message(s) to process', [Length(Unseen)]);

        for k := 0 to High(Unseen) do
        begin
          if FStop then Break;
          SeqNum := Unseen[k];
          Msg := TIdMessage.Create(nil);
          try
            { Peek (BODY.PEEK[]) doesn't set \Seen as a side effect
              the way Retrieve does -- so when SMTP delivery fails
              below and we skip StoreFlags, the next SEARCH UNSEEN
              still returns this message and we retry. Retrieve would
              silently mark Seen on fetch, draining the message from
              the unseen set even though the reply never went out. }
            if not IMAP.RetrievePeek(SeqNum, Msg) then Continue;
            FromAddr := Msg.From.Address;
            Subj := Msg.Subject;
            BodyText := Msg.Body.Text;
            if not MatchesAllow(FromAddr) then
            begin
              LogDebug('email %d: skipping %s (not in allowlist)', [SeqNum, FromAddr]);
              { Mark non-allowed messages Seen so we never re-process
                them -- otherwise the allowlist would force a per-poll
                Retrieve of every junk message in the inbox. }
              IMAP.StoreFlags([SeqNum], sdAdd, [mfSeen]);
              Continue;
            end;
            LogInfo('email %d: from=%s subj=%s', [SeqNum, FromAddr, Subj]);

            { Run through the agent loop. }
            SetLength(RToolMsgs, 1);
            LoopCfg.Identity := MakeIdentity('email', FromAddr);
            if not IsAllowedSender(LoopCfg.Identity, FCfg.AllowSenders) then
            begin
              LogInfo('email: sender %s rejected by allow_senders',
                      [FormatIdentity(LoopCfg.Identity)]);
              { Mark seen so this rejected message doesn't get re-fetched
                via RetrievePeek on every poll forever -- same pattern the
                channel-specific MatchesAllow rejection above uses.
                Codex P2 on PR #119. }
              IMAP.StoreFlags([SeqNum], sdAdd, [mfSeen]);
              Continue;
            end;

            RToolMsgs[0] := MakeMessage(mrUser, BodyText);
            LoopCfg.Provider      := FProvider;
            LoopCfg.Registry      := FRegistry;
            LoopCfg.Model         := FCfg.DefaultModel;
            LoopCfg.MaxIterations := 6;
            LoopCfg.Parallel      := True;
            LoopCfg.Fallbacks     := ResolveFallbacks(FCfg);
            LoopCfg.Options       := DefaultChatOptions;
            ApplyPromptCacheConfig(LoopCfg.Options, FCfg.PromptCache);
            LoopCfg.OnText        := nil;
            LoopCfg.OnToolCall    := nil;
            LoopCfg.OnToolResult  := nil;

            ReplySent       := False;
            ReplyAttempted  := False;
            if RunToolLoop(LoopCfg, RToolMsgs, Loop) and (Loop.Content <> '') then
            begin
              Reply := Loop.Content;
              ReplyAttempted := True;
              ReplySent := Push(FromAddr, 'Re: ' + Subj, Reply, PushErr);
              if not ReplySent then
                LogWarn('email reply send failed to %s: %s', [FromAddr, PushErr]);
            end;

            { Mark Seen only when the reply landed, OR when the agent
              loop produced no reply at all (failed or empty content
              -- a poison message we don't want to loop on forever).
              Failed SMTP transport leaves the message Unseen so the
              next poll retries.

                ReplyAttempted   ReplySent   StoreFlags?
                False (no reply)  -          Yes -- don't loop on poison
                True              True       Yes -- delivered
                True              False      No  -- transient SMTP, retry }
            if (not ReplyAttempted) or ReplySent then
              IMAP.StoreFlags([SeqNum], sdAdd, [mfSeen]);
          finally
            Msg.Free;
          end;
        end;
      finally
        IMAP.Disconnect;
      end;
    except
      on E: Exception do
        LogWarn('email IMAP poll error: %s: %s', [E.ClassName, E.Message]);
    end;
  finally
    SSL.Free;
    IMAP.Free;
  end;
end;

procedure TEmailChannel.RunOnePoll;
begin
  ProcessInbox;
end;

procedure TEmailChannel.Run;
var
  WaitedMS: Integer;
const
  PollTickMS = 500;
begin
  if FIMAP.Host = '' then
  begin
    LogWarn('email: PASCLAW_EMAIL_IMAP_HOST not set -- bot mode disabled, push only');
    Exit;
  end;
  LogInfo('email channel: polling %s every %ds', [FIMAP.Host, FPollSec]);
  while not FStop do
  begin
    RunOnePoll;
    { Sleep in 500ms ticks so RequestStop can break the loop within
      half a second; count milliseconds (NOT ticks) so the user's
      PASCLAW_EMAIL_POLL value matches the actual interval. The
      previous loop incremented WaitedSec by 1 each 500ms tick and
      stopped at FPollSec, halving every configured poll. }
    WaitedMS := 0;
    while (WaitedMS < FPollSec * 1000) and (not FStop) do
    begin
      Sleep(PollTickMS);
      Inc(WaitedMS, PollTickMS);
    end;
  end;
end;

type
  TEmailWorker = class(TThread)
  private
    FChan: TEmailChannel;
  protected
    procedure Execute; override;
  public
    constructor Create(AChan: TEmailChannel);
  end;

constructor TEmailWorker.Create(AChan: TEmailChannel);
begin
  inherited Create(True);
  FreeOnTerminate := False;  { Stop / Destroy joins us -- see TEmailChannel.Stop }
  FChan := AChan;
end;

procedure TEmailWorker.Execute;
begin
  try
    FChan.Run;
  except
    on E: Exception do
      LogWarn('email worker crashed: %s: %s', [E.ClassName, E.Message]);
  end;
end;

procedure TEmailChannel.Spawn;
begin
  if FWorker <> nil then Exit;  { idempotent -- already spawned }
  FWorker := TEmailWorker.Create(Self);
  FWorker.Start;
end;

procedure TEmailChannel.Stop;
const
  { Worst-case shutdown latency the gateway is willing to absorb.
    The worker may currently be blocked in IMAP.Retrieve or
    SMTP.Send, both of which now carry EmailIOTimeoutMS read
    timeouts -- so the actual wait is bounded by one ReadTimeout
    plus the post-op return path. EmailStopWatchdogMS gives that
    a generous ceiling; the WaitFor fallback below catches the
    pathological "server stops responding mid-TLS handshake"
    case so gateway shutdown doesn't hang forever. }
  EmailStopWatchdogMS = EmailIOTimeoutMS + 5000;
begin
  if FWorker = nil then Exit;
  FStop := True;
  { Indy's TThread.WaitFor doesn't take a timeout argument, so we
    poll. Cheap -- Sleep(50ms) until Finished or timeout. The
    worker sets Finished := True the moment Execute returns. }
  if not WaitForWorkerWithTimeout(FWorker, EmailStopWatchdogMS) then
  begin
    LogWarn('email worker did not exit within %d ms -- leaking thread (IMAP/SMTP socket likely wedged)',
            [EmailStopWatchdogMS]);
    { Detach: set FreeOnTerminate so the thread cleans itself up
      whenever it does eventually exit. Better than blocking the
      gateway shutdown forever. NB: if FProvider / FRegistry /
      FCfg get torn down before the thread exits the worker may
      hit a UAF on its next access -- that's the lesser evil vs.
      a wedged gateway. }
    FWorker.FreeOnTerminate := True;
    FWorker := nil;
    Exit;
  end;
  FreeAndNil(FWorker);
end;

procedure TEmailChannel.RequestStop;
begin
  FStop := True;
end;

destructor TEmailChannel.Destroy;
begin
  Stop;  { idempotent; tears down a still-running worker before
          the channel's FProvider / FCfg references go away }
  inherited Destroy;
end;

end.
