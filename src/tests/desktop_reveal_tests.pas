program desktop_reveal_tests;
(*
  The `desktop` tool is in the built-in long tail -- its schema withheld
  behind tool_search -- because it does nothing without a desktop: an API
  caller, a channel or a plain chat never needs it. A running desktop
  does, from its first turn: the shell's prompt routes every screen
  request ("tile the windows") through that tool, and a model that has to
  tool_search for it first spends a turn before it can act.

  A desktop announces itself by subscribing to /v1/desktop/events -- only
  the browser /desktop and the native app do -- and the gateway reveals
  the tool then. Proven against the real binary: before a desktop
  connects, GET /v1/tools (what a request carries) has no `desktop`;
  after one connects, it does, and tool_search is still there for the
  rest of the long tail.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads, BaseUnix,{$ENDIF}
  SysUtils, Classes,
  IdHTTP, IdTCPClient, IdGlobal,
  PasClaw.Utils,
  PasClaw.Platform;

var
  { The gateway this test started, and its scratch home. Globals because
    Fail_ halts, and Halt skips every finally: a failed assertion left the
    gateway running and its home on disk. }
  GPid: Integer = 0;
  GHome: string = '';

procedure StopGateway;
var
  i: Integer;
  Out_: string;
begin
  {$IFDEF UNIX}
  if GPid > 0 then
  begin
    fpKill(GPid, SIGINT);
    for i := 1 to 80 do
    begin
      if fpKill(GPid, 0) <> 0 then Break;
      Sleep(125);
    end;
    if fpKill(GPid, 0) = 0 then fpKill(GPid, SIGKILL);
  end;
  {$ENDIF}
  GPid := 0;
  if GHome <> '' then RunOneShot('rm -rf "' + GHome + '"', '', Out_);
  GHome := '';
end;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); StopGateway; Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

function GetTools(Port: Integer; out Body: string): Boolean;
var
  Http: TIdHTTP;
begin
  Body := '';
  Http := TIdHTTP.Create(nil);
  try
    Http.ConnectTimeout := 1000;
    Http.ReadTimeout := 3000;
    try
      Body := Http.Get('http://127.0.0.1:' + IntToStr(Port) + '/v1/tools');
      Result := Http.ResponseCode = 200;
    except
      Result := False;
    end;
  finally
    Http.Free;
  end;
end;

function Lists(const ToolsBody, Name: string): Boolean;
begin
  Result := Pos('"name":"' + Name + '"', StringReplace(ToolsBody, ' ', '', [rfReplaceAll])) > 0;
end;

{ Subscribe to the desktop feed the way a desktop does, read its hello,
  hang up. }
function ConnectDesktop(Port: Integer): string;
var
  C: TIdTCPClient;
  Line: string;
  i: Integer;
begin
  Result := '';
  C := TIdTCPClient.Create(nil);
  try
    C.Host := '127.0.0.1';
    C.Port := Port;
    C.ConnectTimeout := 2000;
    C.ReadTimeout := 5000;
    C.Connect;
    C.IOHandler.Write('GET /v1/desktop/events HTTP/1.1'#13#10 +
                      'Host: 127.0.0.1'#13#10 +
                      'Accept: text/event-stream'#13#10#13#10);
    for i := 1 to 40 do
    begin
      Line := C.IOHandler.ReadLn;
      if Pos('"hello"', Line) > 0 then
      begin
        Result := Line;
        Break;
      end;
    end;
    C.Disconnect;
  finally
    C.Free;
  end;
end;

procedure TestDesktopRevealsItsTool;
var
  Cmd, Out_, Before, After, Hello: string;
  Port, i: Integer;
  Up: Boolean;
begin
  {$IFNDEF UNIX}
  WriteLn('  skip: the gateway is started through sh here');
  Exit;
  {$ENDIF}
  if not FileExists('build/pasclaw') then
  begin
    WriteLn('  skip: needs build/pasclaw');
    Exit;
  end;
  GHome := IncludeTrailingPathDelimiter(GetTempDir(False)) +
           'pasclaw-desktop-reveal-' + IntToStr(GetProcessID);
  ForceDirectories(GHome);
  WriteFileText(JoinPath(GHome, 'config.json'), '{}');   { defaults: long tail deferred }
  Port := 20000 + Integer(GetProcessID mod 20000);
  Cmd := 'PASCLAW_HOME="' + GHome + '" "' + ExpandFileName('build/pasclaw') +
         '" gateway --port ' + IntToStr(Port) + ' < /dev/null > "' +
         JoinPath(GHome, 'gateway.log') + '" 2>&1 & echo $!';
  RunOneShot(Cmd, '', Out_);
  GPid := StrToIntDef(Trim(Out_), 0);
  AssertTrue(GPid > 0, 'gateway did not start: ' + Out_);
  try
    Up := False;
    for i := 1 to 120 do
    begin
      if GetTools(Port, Before) then begin Up := True; Break; end;
      Sleep(125);
    end;
    AssertTrue(Up, 'gateway never answered /v1/tools on port ' + IntToStr(Port));
    AssertTrue(Lists(Before, 'tool_search'), 'the long tail is deferred behind tool_search');
    AssertTrue(not Lists(Before, 'desktop'),
               'with no desktop connected, `desktop` stays in the long tail');

    Hello := ConnectDesktop(Port);
    AssertTrue(Hello <> '', 'the desktop feed said hello');

    AssertTrue(GetTools(Port, After), '/v1/tools after the desktop connected');
    AssertTrue(Lists(After, 'desktop'),
               'a connected desktop gets its `desktop` tool without a tool_search turn');
    AssertTrue(Lists(After, 'tool_search'), 'tool_search stays for the rest of the long tail');
  finally
    StopGateway;
  end;
  WriteLn('  ok: a connected desktop reveals the desktop tool; before one connects it stays deferred');
end;

begin
  {$IFDEF UNIX}
  fpSignal(SIGPIPE, SignalHandler(SIG_IGN));
  {$ENDIF}
  TestDesktopRevealsItsTool;
  WriteLn('PASS');
end.
