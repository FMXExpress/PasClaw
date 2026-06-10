program tool_rpc_tests;
(*
  Covers PasClaw.Tools.RPC -- the in-process tool callback server
  spawned execute_code scripts use to reach back into the parent
  PasClaw's registry.

  We pin:
    - StartToolRPCIfNeeded brings up a TCP listener and writes a
      readable info file (port + token + pid)
    - DiscoverRunningRPC round-trips that file back into the same
      port + token, so the `pasclaw __tool` subcommand finds the
      right server
    - A valid request gets dispatched to the registered tool and
      the result comes back on the wire
    - A bad token is rejected without dispatching
    - An unknown tool surfaces a clean error message
    - Missing info file produces an actionable ErrMsg
    - StopToolRPC tears the file down so a follow-up
      DiscoverRunningRPC fails the way the model would see in a
      detached environment

  We talk to the server over a plain TCP connection from the test
  body -- no need to spawn a subprocess to exercise the same wire
  protocol the production `pasclaw __tool` binary uses.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  IdTCPClient, IdGlobal,
  PasClaw.JSON,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.RPC;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Int64; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing)');
end;

function FakeTool(const ArgsJSON: string; out ErrMsg: string): string;
{ A dummy tool the tests register: echoes the args back so we can
  verify the JSON survived the round trip cleanly. }
begin
  ErrMsg := '';
  Result := 'echo:' + ArgsJSON;
end;

function FakeFailingTool(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := 'failing tool said no';
  Result := '';
end;

function MakeRegistry: TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  T.Name        := 'fake_echo';
  T.Description := 'echoes args';
  T.Schema      := '{"type":"object"}';
  T.Handler     := @FakeTool;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Result.Register(T);

  T.Name        := 'fake_failing';
  T.Description := 'always fails';
  T.Schema      := '{"type":"object"}';
  T.Handler     := @FakeFailingTool;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Result.Register(T);
end;

function CallRPC(Port: Integer; const RequestJSON: string): string;
{ Tiny client: connect to the running server, write one JSON line,
  read one JSON line back. Mirrors what `pasclaw __tool` does. }
var
  Client: TIdTCPClient;
begin
  Result := '';
  Client := TIdTCPClient.Create(nil);
  try
    Client.Host := '127.0.0.1';
    Client.Port := Port;
    Client.ConnectTimeout := 3000;
    Client.Connect;
    try
      Client.IOHandler.WriteLn(RequestJSON);
      Result := Client.IOHandler.ReadLn(LF, 5000);
    finally
      try Client.Disconnect; except end;
    end;
  finally
    Client.Free;
  end;
end;

function ResponseErr(const Resp: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  try
    Obj := TJsonObject.Parse(Resp);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetStr('err', '');
  finally
    Obj.Free;
  end;
end;

function ResponseResult(const Resp: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  try
    Obj := TJsonObject.Parse(Resp);
  except
    Obj := nil;
  end;
  if Obj = nil then Exit;
  try
    Result := Obj.GetStr('result', '');
  finally
    Obj.Free;
  end;
end;

procedure TestServerStartWritesInfo;
var
  Reg: TToolRegistry;
  P: Integer;
  Tok, Err: string;
begin
  Reg := MakeRegistry;
  try
    StartToolRPCIfNeeded(Reg);
    try
      AssertTrue(FileExists(ToolRPCInfoPath),
                 'StartToolRPCIfNeeded creates info file at ' + ToolRPCInfoPath);
      AssertTrue(DiscoverRunningRPC(P, Tok, Err),
                 'DiscoverRunningRPC succeeds while server up (' + Err + ')');
      AssertTrue(P > 0, 'discovered port > 0');
      AssertEqInt(Length(Tok), 32, 'token is 32 hex chars');
    finally
      StopToolRPC;
    end;
    AssertTrue(not FileExists(ToolRPCInfoPath),
               'StopToolRPC removes info file');
  finally
    Reg.Free;
  end;
end;

procedure TestValidRequestRoundTrips;
var
  Reg: TToolRegistry;
  P: Integer;
  Tok, Err, Resp, ResultText: string;
  Req, ArgsObj: TJsonObject;
begin
  Reg := MakeRegistry;
  try
    StartToolRPCIfNeeded(Reg);
    try
      DiscoverRunningRPC(P, Tok, Err);
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Tok);
        Req.PutStr('name',  'fake_echo');
        ArgsObj := TJsonObject.Parse('{"hello":"world"}');
        Req.PutObject('args', ArgsObj);
        Resp := CallRPC(P, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertEqStr(ResponseErr(Resp), '', 'no err in response');
      ResultText := ResponseResult(Resp);
      AssertContains(ResultText, 'echo:',  'echo prefix present');
      AssertContains(ResultText, '"hello"', 'args survived');
      AssertContains(ResultText, '"world"', 'value survived');
    finally
      StopToolRPC;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestBadTokenRejected;
var
  Reg: TToolRegistry;
  P: Integer;
  Tok, Err, Resp: string;
  Req, ArgsObj: TJsonObject;
begin
  Reg := MakeRegistry;
  try
    StartToolRPCIfNeeded(Reg);
    try
      DiscoverRunningRPC(P, Tok, Err);
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', 'definitely-not-the-real-token');
        Req.PutStr('name',  'fake_echo');
        ArgsObj := TJsonObject.Parse('{}'); Req.PutObject('args', ArgsObj);
        Resp := CallRPC(P, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'invalid token',
                     'bad token rejected with clear message');
      AssertEqStr(ResponseResult(Resp), '',
                  'no result leaked when token rejected');
    finally
      StopToolRPC;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestUnknownToolSurfaces;
var
  Reg: TToolRegistry;
  P: Integer;
  Tok, Err, Resp: string;
  Req, ArgsObj: TJsonObject;
begin
  Reg := MakeRegistry;
  try
    StartToolRPCIfNeeded(Reg);
    try
      DiscoverRunningRPC(P, Tok, Err);
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Tok);
        Req.PutStr('name',  'this_tool_does_not_exist');
        ArgsObj := TJsonObject.Parse('{}'); Req.PutObject('args', ArgsObj);
        Resp := CallRPC(P, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'unknown tool',
                     'unknown tool error surfaces');
    finally
      StopToolRPC;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestFailingToolErrorPropagates;
var
  Reg: TToolRegistry;
  P: Integer;
  Tok, Err, Resp: string;
  Req, ArgsObj: TJsonObject;
begin
  Reg := MakeRegistry;
  try
    StartToolRPCIfNeeded(Reg);
    try
      DiscoverRunningRPC(P, Tok, Err);
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Tok);
        Req.PutStr('name',  'fake_failing');
        ArgsObj := TJsonObject.Parse('{}'); Req.PutObject('args', ArgsObj);
        Resp := CallRPC(P, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'failing tool said no',
                     'tool-side ErrMsg propagated verbatim');
    finally
      StopToolRPC;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestDiscoverFailsWhenNoInfoFile;
var
  P: Integer;
  Tok, Err: string;
begin
  { Ensure no leftover file. }
  if FileExists(ToolRPCInfoPath) then DeleteFile(ToolRPCInfoPath);
  AssertTrue(not DiscoverRunningRPC(P, Tok, Err),
             'discovery returns False when info file is missing');
  AssertContains(Err, 'no tool-rpc info file',
                 'ErrMsg names the missing file path');
end;

begin
  TestServerStartWritesInfo;
  TestValidRequestRoundTrips;
  TestBadTokenRejected;
  TestUnknownToolSurfaces;
  TestFailingToolErrorPropagates;
  TestDiscoverFailsWhenNoInfoFile;
  WriteLn('tool_rpc_tests: OK');
end.
