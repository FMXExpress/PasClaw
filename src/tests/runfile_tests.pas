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

  PASCLAW_HOME must be a scratch dir (the Makefile target arranges it).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
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

begin
  Home := GetHome;
  ForceDirectories(Home);
  Path := GatewayRunFilePath(Home);
  if FileExists(Path) then DeleteFile(Path);
  TestRoundTrip;
  TestStale;
  TestResolve;
  TestStopSignal;
  WriteLn('PASS');
end.
