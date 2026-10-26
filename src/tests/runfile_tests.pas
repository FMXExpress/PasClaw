program runfile_tests;
(*
  PasClaw.Gateway.RunFile (how a client finds the running gateway) and
  PasClaw.Cmd.Attach.ResolveAttach (whether this run should attach).

    - write / read round trip: port, bind, our pid, token hash, version
    - TokenHashHex is sha256 hex; '' for no token
    - GatewayBaseURL maps wildcard binds to loopback
    - a file naming a dead pid is stale: ReadGatewayRunFile says absent,
      ReadGatewayRunFileRaw returns it with Alive=False
    - RemoveGatewayRunFile removes our own file and a stale one, and
      leaves another live process's file alone
    - ResolveAttach: off => local; auto with no gateway => local, not a
      failure; on / --attach with no gateway => failure with a reason;
      a live file => attach with its URL; a token mismatch => a warning
    - an attached turn carries --plan / --model / --system / --max-tokens
      / --no-tools to the gateway, and the flags a gateway turn cannot
      take are refused by name before anything is sent -- the real
      `pasclaw agent --attach` against a fake gateway that records what
      arrives (Codex P1 on #613)
    - the run file vanishing between FileExists and the read reads as
      absent, not as an exception (Codex P2 on #613)
    - the Telegram channel's long-poll loop consults the process-wide stop
      flag, so the first Ctrl-C reaches it (Codex P1 on #613)

  PASCLAW_HOME must be a scratch dir (the Makefile target arranges it).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Platform,
  PasClaw.Client.Api,
  PasClaw.Channels.Telegram,
  PasClaw.Gateway.RunFile,
  PasClaw.Cmd.Attach;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Hay); end;

var
  Home, Path: string;

procedure TestRoundTrip;
var
  Info: TGatewayRunInfo;
  Alive: Boolean;
begin
  AssertTrue(not ReadGatewayRunFile(Home, Info), 'no file -> absent');
  WriteGatewayRunFile(Home, '0.0.0.0', 8099, 'tok', '0.1.6');
  AssertTrue(FileExists(Path), 'file written at ' + Path);
  AssertTrue(ReadGatewayRunFile(Home, Info), 'file read');
  AssertEqInt(Info.Port, 8099, 'port');
  AssertEqStr(Info.Bind, '0.0.0.0', 'bind');
  AssertEqInt(Info.Pid, CurrentProcessId, 'pid is ours');
  AssertEqStr(Info.TokenHash, TokenHashHex('tok'), 'token hash');
  AssertEqStr(Info.Version, '0.1.6', 'version');
  AssertTrue(Info.StartedAt <> '', 'started_at stamped');
  { ISO 8601 UTC, "2026-10-26T21:30:05Z": the separators are literal, not
    the locale's (NowIsoUtc quotes them). }
  AssertTrue((Length(Info.StartedAt) = 20) and (Info.StartedAt[5] = '-') and
             (Info.StartedAt[11] = 'T') and (Info.StartedAt[14] = ':') and
             (Info.StartedAt[20] = 'Z'), 'started_at is ISO 8601 UTC: ' + Info.StartedAt);
  AssertEqStr(GatewayBaseURL(Info), 'http://127.0.0.1:8099', 'wildcard bind -> loopback');
  Info.Bind := '192.168.1.5';
  AssertEqStr(GatewayBaseURL(Info), 'http://192.168.1.5:8099', 'explicit bind kept');
  Info.Bind := '::';
  AssertEqStr(GatewayBaseURL(Info), 'http://127.0.0.1:8099', 'v6 wildcard -> loopback');
  AssertEqStr(TokenHashHex('abc'),
              'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad', 'sha256 vector');
  AssertEqStr(TokenHashHex(''), '', 'no token -> empty hash');
  AssertTrue(ProcessAlive(CurrentProcessId), 'we are alive');
  AssertTrue(ReadGatewayRunFileRaw(Home, Info, Alive) and Alive, 'raw read says alive');
  RemoveGatewayRunFile(Home);
  AssertTrue(not FileExists(Path), 'own file removed');
  WriteLn('  ok: write / read / url / hash / remove own');
end;

procedure TestStale;
var
  Info: TGatewayRunInfo;
  Alive: Boolean;
begin
  { A pid that cannot be alive: far above any pid_max in use. }
  WriteFileText(Path, '{"port":8100,"bind":"127.0.0.1","pid":2147480000,"token_hash":"","started_at":"x","version":"v"}');
  AssertTrue(not ProcessAlive(2147480000), 'huge pid is not alive');
  AssertTrue(not ReadGatewayRunFile(Home, Info), 'stale -> absent');
  AssertTrue(ReadGatewayRunFileRaw(Home, Info, Alive), 'raw still reads it');
  AssertTrue(not Alive, 'raw says dead');
  AssertEqInt(Info.Port, 8100, 'raw has the port');
  RemoveGatewayRunFile(Home);
  AssertTrue(not FileExists(Path), 'stale file removed');

  { Another LIVE process's file (pid 1 is always alive on a POSIX host)
    is not ours to remove. }
  WriteFileText(Path, '{"port":8101,"bind":"127.0.0.1","pid":1,"token_hash":"","started_at":"x","version":"v"}');
  AssertTrue(ProcessAlive(1), 'pid 1 alive');
  RemoveGatewayRunFile(Home);
  AssertTrue(FileExists(Path), 'another live process''s file left alone');
  DeleteFile(Path);
  AssertTrue(not ReadGatewayRunFile(Home, Info), 'gone');
  { Garbage and a missing port are absent too. }
  WriteFileText(Path, 'not json');
  AssertTrue(not ReadGatewayRunFileRaw(Home, Info, Alive), 'garbage -> absent');
  WriteFileText(Path, '{"pid":' + IntToStr(CurrentProcessId) + '}');
  AssertTrue(not ReadGatewayRunFileRaw(Home, Info, Alive), 'no port -> absent');
  DeleteFile(Path);
  WriteLn('  ok: stale pid, other live pid, garbage');
end;

procedure TestResolve;
var
  Cfg: TConfig;
  URL, Reason, Warn: string;
  Fail: Boolean;
begin
  Cfg := TConfig.Create;
  try
    AssertEqStr(Cfg.Cli.Attach, 'off', 'default off');
    AssertTrue(not ResolveAttach(Cfg, False, URL, Reason, Warn, Fail), 'off -> local');
    AssertTrue(not Fail, 'off is not a failure');

    Cfg.Cli.Attach := 'auto';
    AssertTrue(not ResolveAttach(Cfg, False, URL, Reason, Warn, Fail), 'auto, no gateway -> local');
    AssertTrue(not Fail, 'auto never fails');

    Cfg.Cli.Attach := 'on';
    AssertTrue(not ResolveAttach(Cfg, False, URL, Reason, Warn, Fail), 'on, no gateway -> not attached');
    AssertTrue(Fail, 'on with no gateway is a failure');
    AssertContains(Reason, 'no running gateway', 'reason names the problem');
    AssertContains(Reason, 'pasclaw gateway', 'reason says what to run');

    Cfg.Cli.Attach := 'off';
    AssertTrue(not ResolveAttach(Cfg, True, URL, Reason, Warn, Fail), '--attach, no gateway');
    AssertTrue(Fail, '--attach with no gateway is a failure');

    WriteGatewayRunFile(Home, '127.0.0.1', 8102, 'secret', '0.1.6');
    Cfg.Gateway.Token := 'secret';
    AssertTrue(ResolveAttach(Cfg, True, URL, Reason, Warn, Fail), 'live file -> attach');
    AssertEqStr(URL, 'http://127.0.0.1:8102', 'url from the file');
    AssertEqStr(Warn, '', 'matching token: no warning');
    Cfg.Gateway.Token := 'other';
    AssertTrue(ResolveAttach(Cfg, True, URL, Reason, Warn, Fail), 'still attaches');
    AssertContains(Warn, 'different gateway.token', 'token mismatch warned');
    Cfg.Cli.Attach := 'auto';
    AssertTrue(ResolveAttach(Cfg, False, URL, Reason, Warn, Fail), 'auto with a live file attaches');
    RemoveGatewayRunFile(Home);

    { Config round-trip of cli.attach. }
    Cfg.Cli.Attach := 'auto';
    AssertContains(Cfg.ToJSON, '"attach"', 'non-default emitted');
    Cfg.FromJSON('{"cli":{"attach":"ON"}}');
    AssertEqStr(Cfg.Cli.Attach, 'on', 'parsed, lowercased');
    Cfg.FromJSON('{"cli":{"attach":"bogus"}}');
    AssertEqStr(Cfg.Cli.Attach, 'off', 'unknown -> off');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: ResolveAttach off / auto / on / --attach / live / token warning; cli.attach round-trip');
end;

procedure TestStopSignal;
begin
  {$IFDEF UNIX}
  AssertTrue(not StopRequested, 'not requested yet');
  InstallStopSignalHandler;
  fpKill(fpGetPid, SIGTERM);   { would kill us without the handler }
  Sleep(50);
  AssertTrue(StopRequested, 'SIGTERM set the stop flag instead of killing the process');
  WriteLn('  ok: stop signal handler');
  {$ELSE}
  WriteLn('  skip: stop signal handler (not unix)');
  {$ENDIF}
end;


{ ---- a fake gateway that records what it is sent ---- }

type
  TFakeGateway = class
  public
    Server: TIdHTTPServer;
    Lock: TCriticalSection;
    ChatBodies: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure Get(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
                  AResponseInfo: TIdHTTPResponseInfo);
    function ChatCount: Integer;
    function LastChat: string;
  end;

constructor TFakeGateway.Create;
begin
  inherited Create;
  Lock := TCriticalSection.Create;
  ChatBodies := TStringList.Create;
  Server := TIdHTTPServer.Create(nil);
  Server.DefaultPort := 0;
  with Server.Bindings.Add do
  begin
    IP := '127.0.0.1';
    Port := 0;
  end;
  Server.OnCommandGet := Get;
  Server.OnCommandOther := Get;
  Server.Active := True;
end;

destructor TFakeGateway.Destroy;
begin
  Server.Active := False;
  Server.Free;
  ChatBodies.Free;
  Lock.Free;
  inherited Destroy;
end;

function BodyOf(ARequestInfo: TIdHTTPRequestInfo): string;
var
  Bytes: TBytes;
begin
  Result := '';
  if ARequestInfo.PostStream = nil then Exit;
  ARequestInfo.PostStream.Position := 0;
  SetLength(Bytes, ARequestInfo.PostStream.Size);
  if Length(Bytes) > 0 then
  begin
    ARequestInfo.PostStream.ReadBuffer(Bytes[0], Length(Bytes));
    Result := TEncoding.UTF8.GetString(Bytes);
  end;
end;

procedure TFakeGateway.Get(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
                           AResponseInfo: TIdHTTPResponseInfo);
begin
  AResponseInfo.ContentType := 'application/json';
  if ARequestInfo.Document = '/v1/health' then
    AResponseInfo.ContentText := '{"status":"ok","version":"fake"}'
  else if (ARequestInfo.Document = '/v1/sessions') and (ARequestInfo.Command = 'POST') then
    AResponseInfo.ContentText := '{"id":"sess-fake"}'
  else if ARequestInfo.Document = '/v1/chat/completions' then
  begin
    Lock.Enter;
    try
      ChatBodies.Add(BodyOf(ARequestInfo));
    finally
      Lock.Leave;
    end;
    AResponseInfo.ContentType := 'text/event-stream';
    AResponseInfo.ContentText :=
      'data: {"choices":[{"delta":{"content":"fake reply"}}]}'#10#10 +
      'data: [DONE]'#10#10;
  end
  else
  begin
    AResponseInfo.ResponseNo := 404;
    AResponseInfo.ContentText := '{"error":"not here"}';
  end;
end;

function TFakeGateway.ChatCount: Integer;
begin
  Lock.Enter;
  try
    Result := ChatBodies.Count;
  finally
    Lock.Leave;
  end;
end;

function TFakeGateway.LastChat: string;
begin
  Lock.Enter;
  try
    if ChatBodies.Count = 0 then Result := '' else Result := ChatBodies[ChatBodies.Count - 1];
  finally
    Lock.Leave;
  end;
end;

function RunPasclaw(const Args: string; out Output: string): Integer;
begin
  Result := RunOneShot('"' + ExpandFileName('build/pasclaw') + '" ' + Args + ' 2>&1',
                       '', Output);
  { RunOneShot reports the raw wait status on FPC; the exit code is the
    high byte. }
  {$IFDEF UNIX}
  if Result > 255 then Result := Result shr 8;
  {$ENDIF}
end;

procedure TestAttachedTurnCarriesTheFlags;
(* An attached turn has to mean what the same flags mean locally.

   It used to send the user's message and nothing else, and the gateway
   treats a request with no mode as BUILD mode -- so `pasclaw agent
   --attach --plan` ran with mutating tools exposed, the one thing --plan
   is for preventing. --model, --system, --max-tokens and --no-tools were
   dropped the same way. Proven against the real binary: whatever arrives
   at the fake gateway is what a real one would have been asked for.
   (Codex P1 on #613.) *)
var
  Fake: TFakeGateway;
  Out_, Body: string;
  Code, Before: Integer;
  Obj: TJsonObject;
begin
  if not FileExists('build/pasclaw') then
  begin
    WriteLn('  skip: attached-turn test needs build/pasclaw');
    Exit;
  end;
  Fake := TFakeGateway.Create;
  try
    WriteGatewayRunFile(Home, '127.0.0.1', Fake.Server.Bindings[0].Port, '', 'fake');

    { The flags, forwarded. }
    Code := RunPasclaw('agent --attach --plan --model m-attached --system "be terse" ' +
                       '--max-tokens 123 --no-tools -q -m hello', Out_);
    AssertEqInt(Code, 0, 'the attached turn ran: ' + Copy(Out_, 1, 300));
    AssertEqInt(Fake.ChatCount, 1, 'one turn reached the gateway');
    Body := Fake.LastChat;
    Obj := TJsonObject.Parse(Body);
    AssertTrue(Obj <> nil, 'the body is JSON: ' + Body);
    try
      AssertEqStr(Obj.GetStr('mode', ''), 'plan',
                  '--plan reaches the gateway -- without it the turn ran in build mode');
      AssertEqStr(Obj.GetStr('model', ''), 'm-attached', '--model is forwarded');
      AssertEqStr(Obj.GetStr('system', ''), 'be terse', '--system is forwarded, as the field');
      AssertEqInt(Integer(Obj.GetInt('max_tokens', 0)), 123, '--max-tokens is forwarded');
      AssertTrue(Obj.GetBool('no_tools', False), '--no-tools is forwarded');
    finally
      Obj.Free;
    end;
    AssertContains(Body, '"hello"', 'and the message itself');

    { No flags: the body is the shape it always was. }
    Code := RunPasclaw('agent --attach -q -m plain', Out_);
    AssertEqInt(Code, 0, 'a plain attached turn ran: ' + Copy(Out_, 1, 300));
    Body := Fake.LastChat;
    AssertTrue(Pos('"mode"', Body) = 0, 'no mode is sent when none was asked for');
    AssertTrue(Pos('"model"', Body) = 0, 'nor a model');
    AssertTrue(Pos('"no_tools"', Body) = 0, 'nor no_tools');
    AssertTrue(Pos('"max_tokens"', Body) = 0, 'nor the default max_tokens');

    { Flags a gateway turn cannot carry: refused, and nothing is sent. }
    Before := Fake.ChatCount;
    Code := RunPasclaw('agent --attach --provider other --no-mcp -q -m refused', Out_);
    AssertEqInt(Code, 2, 'unsupported flags are a usage error: ' + Copy(Out_, 1, 300));
    AssertContains(Out_, '--provider', 'the refusal names --provider');
    AssertContains(Out_, '--no-mcp', 'and --no-mcp');
    AssertContains(Out_, 'cannot be used with --attach', 'and says why');
    AssertEqInt(Fake.ChatCount, Before, 'and no turn was sent to the gateway');
  finally
    RemoveGatewayRunFile(Home);
    Fake.Free;
  end;
  WriteLn('  ok: an attached turn carries its flags, and refuses the ones it cannot');
end;

procedure TestChatRequestBody;
var
  C: TPasClawClient;
  T: TChatTurnOptions;
  Body: string;
begin
  C := TPasClawClient.Create('http://127.0.0.1:1');
  try
    Body := C.ChatRequestBody('[{"role":"user","content":"x"}]', '');
    AssertTrue(Pos('"mode"', Body) = 0, 'no turn options -> no extra fields');
    T := Default(TChatTurnOptions);
    T.Mode := 'plan';
    T.System := 'sys';
    C.TurnOptions := T;
    Body := C.ChatRequestBody('[{"role":"user","content":"x"}]', '');
    AssertContains(Body, '"mode"', 'mode in the body');
    AssertContains(Body, '"system"', 'system as a field');
    AssertTrue(Pos('"role":"system"', StringReplace(Body, ' ', '', [rfReplaceAll])) = 0,
               'and NOT as a system message, which would replace the gateway''s prompt');
  finally
    C.Free;
  end;
  WriteLn('  ok: ChatRequestBody writes the turn options, only when set');
end;

{ ---- the run file vanishing mid-read ---- }

type
  TFlapper = class(TThread)
  public
    procedure Execute; override;
  end;

procedure TFlapper.Execute;
begin
  while not Terminated do
  begin
    WriteGatewayRunFile(Home, '127.0.0.1', 9, '', 'flap');
    DeleteFile(GatewayRunFilePath(Home));
  end;
end;

procedure TestRunFileVanishingMidRead;
(* The gateway deletes the run file on its way out, unordered against a
   reader. FileExists could say yes and the read then raise, and the
   callers -- status, agent --attach, tui --attach -- do not catch it, so
   an ordinary concurrent shutdown crashed the client. (Codex P2 on #613.)

   Raced for real: one thread writes and deletes the file in a loop while
   this one reads it. Any exception escaping ReadGatewayRunFile fails. *)
var
  F: TFlapper;
  Info: TGatewayRunInfo;
  T0: TDateTime;
  Reads: Integer;
begin
  F := TFlapper.Create(False);
  Reads := 0;
  T0 := Now;
  try
    try
      while (Now - T0) * 86400 < 1.5 do
      begin
        ReadGatewayRunFile(Home, Info);
        Inc(Reads);
      end;
    except
      on E: Exception do
        Fail_('ReadGatewayRunFile raised while the file was being removed ' +
              'under it (' + E.ClassName + ': ' + E.Message + ') -- a ' +
              'gateway shutting down would crash the client');
    end;
  finally
    F.Terminate;
    F.WaitFor;
    F.Free;
    DeleteFile(GatewayRunFilePath(Home));
  end;
  AssertTrue(Reads > 100, 'the race was actually exercised (' + IntToStr(Reads) + ' reads)');
  WriteLn(Format('  ok: a run file vanishing mid-read reads as absent (%d reads raced)', [Reads]));
end;

{ ---- Telegram hears the stop flag ---- }

var
  GStopNow: Boolean = False;

function StopNow: Boolean;
begin
  Result := GStopNow;
end;

type
  TTelegramRunner = class(TThread)
  public
    Channel: TTelegramChannel;
    procedure Execute; override;
  end;

procedure TTelegramRunner.Execute;
begin
  Channel.Run;
end;

procedure TestTelegramHearsTheStopFlag;
(* `pasclaw gateway --telegram` blocks in TTelegramChannel.Run, not in
   Server.WaitForStop, and the signal handler only sets a process-wide
   flag. Nothing in the channel read that flag, so the first Ctrl-C did
   nothing and the second killed the process without the cleanup the
   handler exists for. (Codex P1 on #613.)

   With the flag already up, Run must return without polling at all --
   which also keeps this test off the network. *)
var
  Cfg: TConfig;
  R: TTelegramRunner;
  Waited: Integer;
begin
  Cfg := TConfig.Create;
  R := TTelegramRunner.Create(True);
  try
    R.FreeOnTerminate := False;
    R.Channel := TTelegramChannel.Create('0000:fake-token-for-tests', Cfg, nil, nil);
    R.Channel.StopCheck := StopNow;
    GStopNow := True;
    R.Start;
    Waited := 0;
    while (not R.Finished) and (Waited < 5000) do
    begin
      Sleep(20);
      Inc(Waited, 20);
    end;
    AssertTrue(R.Finished,
               'Run did not notice the stop flag -- the first Ctrl-C would never ' +
               'reach `pasclaw gateway --telegram`');
    R.WaitFor;
  finally
    if R.Finished then
    begin
      R.Channel.Free;
      R.Free;
    end;
    Cfg.Free;
  end;
  WriteLn('  ok: the Telegram loop hears the process-wide stop flag');
end;

begin
  Home := GetHome;
  ForceDirectories(Home);
  Path := GatewayRunFilePath(Home);
  if FileExists(Path) then DeleteFile(Path);
  TestRoundTrip;
  TestStale;
  TestResolve;
  TestChatRequestBody;
  TestAttachedTurnCarriesTheFlags;
  TestRunFileVanishingMidRead;
  TestTelegramHearsTheStopFlag;
  TestStopSignal;   { last: it installs the real handler on this process }
  WriteLn('PASS');
end.
