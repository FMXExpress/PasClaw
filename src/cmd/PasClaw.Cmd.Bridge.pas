(*
  PasClaw.Cmd.Bridge -- `pasclaw bridge`: carry the DOS client's model
  calls from a serial line (or a TCP port an emulator's serial port is
  wired to) to a PasClaw gateway. See PasClaw.Bridge and docs/dos.md.

    pasclaw bridge                            # TCP 127.0.0.1:5150 (DOSBox-X)
    pasclaw bridge --listen 0.0.0.0:5150      # a serial-to-Ethernet adapter
    pasclaw bridge --serial /dev/ttyUSB0      # a null-modem cable, 115200 8N1
    pasclaw bridge --serial COM3 --baud 38400

  The gateway is the one this config runs (run/gateway.json, else
  127.0.0.1:<gateway.port>) with this config's gateway token, or
  --gateway URL with --token / $PASCLAW_GATEWAY_TOKEN -- this config's
  token is never sent to a gateway named on the command line.
*)
unit PasClaw.Cmd.Bridge;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Bridge_Run(const Argv: array of string): Integer;

{ "[addr:]port" -> Addr, Port. False when the port is not 1..65535. }
function ParseListenSpec(const Spec: string; out Addr: string; out Port: Integer): Boolean;

(* Which gateway gets the requests, with which token. GatewayArg is
   --gateway or $PASCLAW_GATEWAY_URL; when it names one, the token is
   --token or EnvToken ($PASCLAW_GATEWAY_TOKEN) -- never LocalToken, which
   is this config's and belongs to LocalURL, the gateway this config runs. *)
function ResolveBridgeTarget(const GatewayArg, TokenArg: string; HasToken: Boolean;
  const LocalURL, LocalToken, EnvToken: string; out Token: string): string;

implementation

uses
  SysUtils, SyncObjs,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Gateway.RunFile,
  PasClaw.Bridge.Wire,
  PasClaw.Bridge.Serial,
  PasClaw.Bridge;

const
  DEFAULT_BRIDGE_PORT = 5150;

var
  GLogLock: TCriticalSection;

procedure LogLine(const Line: string);
begin
  GLogLock.Enter;
  try
    PrintLn(FormatDateTime('hh:nn:ss', Now) + '  ' + Line);
  finally
    GLogLock.Leave;
  end;
end;

procedure Help;
begin
  PrintLn('Usage: pasclaw bridge [--listen [ADDR:]PORT | --serial DEVICE [--baud N]]');
  PrintLn('                      [--gateway URL] [--token TOKEN] [--model NAME] [--timeout SEC]');
  PrintLn;
  PrintLn('Carries the DOS client''s model calls (PCLAW.EXE, see docs/dos.md) from a');
  PrintLn('serial line to a PasClaw gateway. Only POST /v1/responses, GET /v1/health and');
  PrintLn('GET /v1/models are forwarded; the gateway token and provider keys stay here.');
  PrintLn;
  PrintLn('  --listen [ADDR:]PORT  TCP for an emulator''s serial port (default 127.0.0.1:' +
          IntToStr(DEFAULT_BRIDGE_PORT) + ').');
  PrintLn('                        DOSBox-X: serial1=nullmodem server:127.0.0.1 port:' +
          IntToStr(DEFAULT_BRIDGE_PORT) + ' transparent:1');
  PrintLn('  --serial DEVICE       A real serial port: /dev/ttyUSB0, /dev/ttyS0, COM1 ...');
  PrintLn('  --baud N              300 .. 115200 (default 115200). Same on both ends.');
  PrintLn('  --gateway URL         The gateway (default: the one this config runs).');
  PrintLn('  --token TOKEN         Its bearer token (default: $PASCLAW_GATEWAY_TOKEN; with no');
  PrintLn('                        --gateway, this config''s gateway token).');
  PrintLn('  --model NAME          Model for requests that name none (default: the gateway''s).');
  PrintLn('  --timeout SEC         Longest one model call may take (default 600).');
end;

function ParseListenSpec(const Spec: string; out Addr: string; out Port: Integer): Boolean;
var
  P: Integer;
  PortText: string;
begin
  Addr := '127.0.0.1';
  P := LastDelimiter(':', Spec);
  if P > 0 then
  begin
    Addr := Copy(Spec, 1, P - 1);
    PortText := Copy(Spec, P + 1, MaxInt);
    if (Length(Addr) >= 2) and (Addr[1] = '[') and (Addr[Length(Addr)] = ']') then
      Addr := Copy(Addr, 2, Length(Addr) - 2);
    if Addr = '' then Addr := '127.0.0.1';
  end
  else
    PortText := Spec;
  Port := StrToIntDef(PortText, -1);
  Result := (Port >= 1) and (Port <= 65535);
end;

function IsLoopbackAddr(const Addr: string): Boolean;
begin
  Result := (Addr = '127.0.0.1') or (Addr = '::1') or SameText(Addr, 'localhost') or
            (Copy(Addr, 1, 4) = '127.');
end;

function TrimSlash(const S: string): string;
begin
  Result := S;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function ResolveBridgeTarget(const GatewayArg, TokenArg: string; HasToken: Boolean;
  const LocalURL, LocalToken, EnvToken: string; out Token: string): string;
begin
  if GatewayArg <> '' then
  begin
    Result := TrimSlash(GatewayArg);
    if HasToken then Token := TokenArg else Token := EnvToken;
  end
  else
  begin
    Result := TrimSlash(LocalURL);
    if HasToken then Token := TokenArg else Token := LocalToken;
  end;
end;

{ The gateway's own health route: is anything there, before we wait on a
  DOS PC that will only find out on its first request. }
procedure ProbeGateway(const Cfg: TBridgeConfig);
var
  Status: Integer;
  Body, Err: string;
begin
  if BridgeForwardHTTP('GET', Cfg.GatewayURL + '/v1/health', '', Cfg.Token, 10,
                       Status, Body, Err) and (Status = 200) then
    LogLine('gateway ' + Cfg.GatewayURL + ' is up')
  else if Status > 0 then
    LogLine(Ansi.Yellow + 'gateway ' + Cfg.GatewayURL + ' answered ' + IntToStr(Status) +
            Ansi.Reset + ' -- check --token')
  else
    LogLine(Ansi.Yellow + 'gateway ' + Cfg.GatewayURL + ' is not answering (' + Err + ')' +
            Ansi.Reset + ' -- start `pasclaw gateway`; requests get 502 until it is up');
end;

{ The value after Argv[i], moving i onto it. }
function FlagValue(const Argv: array of string; var i: Integer; const Flag: string): string;
begin
  if i >= High(Argv) then
    raise Exception.Create(Flag + ' needs a value');
  Inc(i);
  Result := Argv[i];
end;

function Cmd_Bridge_Run(const Argv: array of string): Integer;
var
  BCfg: TBridgeConfig;
  Cfg: TConfig;
  Info: TGatewayRunInfo;
  Listen, SerialDev, GatewayArg, TokenArg, Addr, Err, LocalURL: string;
  ListenPort, Baud, i: Integer;
  HasToken: Boolean;
  Server: TBridgeTcpServer;
  Port: TSerialPort;
  Stop: Boolean;
begin
  Listen := '';
  SerialDev := '';
  GatewayArg := '';
  TokenArg := '';
  HasToken := False;
  Baud := 115200;
  BCfg.Model := '';
  BCfg.TimeoutSec := 600;
  try
    i := 0;
    while i <= High(Argv) do
    begin
      if (Argv[i] = '-h') or (Argv[i] = '--help') or (Argv[i] = 'help') then
      begin
        Help;
        Exit(0);
      end
      else if Argv[i] = '--listen'  then Listen := FlagValue(Argv, i, '--listen')
      else if Argv[i] = '--serial'  then SerialDev := FlagValue(Argv, i, '--serial')
      else if Argv[i] = '--baud'    then Baud := StrToIntDef(FlagValue(Argv, i, '--baud'), -1)
      else if Argv[i] = '--gateway' then GatewayArg := FlagValue(Argv, i, '--gateway')
      else if Argv[i] = '--token'   then begin TokenArg := FlagValue(Argv, i, '--token'); HasToken := True; end
      else if Argv[i] = '--model'   then BCfg.Model := FlagValue(Argv, i, '--model')
      else if Argv[i] = '--timeout' then BCfg.TimeoutSec := StrToIntDef(FlagValue(Argv, i, '--timeout'), -1)
      else
        raise Exception.Create('unknown flag: ' + Argv[i]);
      Inc(i);
    end;
  except
    on E: Exception do
    begin
      PrintErr(FormatCLIError(E.Message, 'pasclaw bridge'));
      Exit(1);
    end;
  end;
  if (Listen <> '') and (SerialDev <> '') then
  begin
    PrintErr(FormatCLIError('--listen and --serial are two ways to reach the DOS PC; pick one',
                            'pasclaw bridge'));
    Exit(1);
  end;
  if not SerialBaudSupported(Baud) then
  begin
    PrintErr(FormatCLIError('--baud must be one of 300 1200 2400 4800 9600 19200 38400 57600 115200',
                            'pasclaw bridge'));
    Exit(1);
  end;
  if BCfg.TimeoutSec < 1 then
  begin
    PrintErr(FormatCLIError('--timeout must be a number of seconds', 'pasclaw bridge'));
    Exit(1);
  end;
  if Listen = '' then Listen := IntToStr(DEFAULT_BRIDGE_PORT);
  if not ParseListenSpec(Listen, Addr, ListenPort) then
  begin
    PrintErr(FormatCLIError('--listen wants [ADDR:]PORT, got "' + Listen + '"', 'pasclaw bridge'));
    Exit(1);
  end;

  { Which gateway, with which token. A gateway named on the command line
    gets --token or the env token, never this config's: that token is for
    this config's gateway. }
  Cfg := LoadConfig;
  try
    if GatewayArg = '' then GatewayArg := GetEnvironmentVariable('PASCLAW_GATEWAY_URL');
    if ReadGatewayRunFile(GetHome, Info) then LocalURL := GatewayBaseURL(Info)
    else LocalURL := 'http://127.0.0.1:' + IntToStr(Cfg.Gateway.Port);
    BCfg.GatewayURL := ResolveBridgeTarget(GatewayArg, TokenArg, HasToken, LocalURL,
      GetEffectiveGatewayToken(Cfg), GetEnvironmentVariable('PASCLAW_GATEWAY_TOKEN'), BCfg.Token);
  finally
    Cfg.Free;
  end;

  GBridgeLog := LogLine;
  InstallStopSignalHandler;
  ProbeGateway(BCfg);
  Stop := False;

  if SerialDev <> '' then
  begin
    Port := TSerialPort.Create;
    try
      if not Port.Open(SerialDev, Baud, Err) then
      begin
        PrintErr(FormatCLIError(Err, 'pasclaw bridge'));
        Exit(1);
      end;
      LogLine(Format('bridge: %s at %d 8N1 -> %s', [SerialDev, Baud, BCfg.GatewayURL]));
      PrintLn(Ansi.Dim + 'On the DOS PC: PCLAW /PORT:COM1 /BAUD:' + IntToStr(Baud) +
              '   Press Ctrl-C to stop.' + Ansi.Reset);
      { A serial line never closes: this returns on Ctrl-C only. }
      BridgeServeStream(BCfg, Port, Port.WriteBytes, SerialDev, Stop, StopRequested);
    finally
      Port.Free;
    end;
    Exit(0);
  end;

  Server := TBridgeTcpServer.Create(BCfg);
  try
    try
      Server.Start(Addr, ListenPort);
    except
      on E: Exception do
      begin
        PrintErr(FormatCLIError('cannot listen on ' + Addr + ':' + IntToStr(ListenPort) +
                                ': ' + E.Message, 'pasclaw bridge'));
        Exit(1);
      end;
    end;
    LogLine(Format('bridge: listening on %s:%d -> %s', [Addr, Server.Port, BCfg.GatewayURL]));
    if not IsLoopbackAddr(Addr) then
      LogLine(Ansi.Yellow + 'anyone who can reach this port can use the model through your ' +
              'gateway token' + Ansi.Reset);
    PrintLn(Ansi.Dim + 'DOSBox-X: serial1=nullmodem server:127.0.0.1 port:' +
            IntToStr(Server.Port) + ' transparent:1   Press Ctrl-C to stop.' + Ansi.Reset);
    while not StopRequested do Sleep(200);
    LogLine('bridge: stopping');
    Server.Stop;
  finally
    Server.Free;
  end;
  Result := 0;
end;

initialization
  GLogLock := TCriticalSection.Create;

finalization
  GLogLock.Free;

end.
