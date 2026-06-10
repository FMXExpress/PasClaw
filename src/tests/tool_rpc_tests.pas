program tool_rpc_tests;
(*
  Covers PasClaw.Tools.RPC -- the per-call tool-callback server an
  execute_code script uses to reach back into the parent PasClaw's
  registry.

  Post-Codex-P1+P2 (PR #206): the server is no longer a singleton
  bound to a global registry. Each Tool_ExecuteCode invocation
  constructs its own TToolRPCServer bound to ITS registry, on a
  unique info-file path, and tells the spawned script via env
  PASCLAW_TOOL_RPC_INFO. Tests drive the server directly via the
  exposed constructor.

  We pin:
    - Construct/Start writes the per-instance info file at the
      caller-chosen path
    - The file goes away on Stop, freeing the port + cleaning up
    - A valid request dispatches through the registry we bound
      this instance to (not some global)
    - A bad token is rejected without dispatching
    - An unknown tool surfaces a clean error
    - DiscoverRunningRPC fails with an actionable error when the
      PASCLAW_TOOL_RPC_INFO env var is missing -- matches what a
      `pasclaw __tool` call from outside a script would see

  Two concurrent server instances (simulating parent + subagent
  execute_codes running in parallel) get distinct ports + tokens
  and dispatch to their OWN registry -- that's the heart of the
  P1+P2 fix and the most important regression guard here.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  IdTCPClient, IdGlobal,
  PasClaw.Config,
  PasClaw.Utils,
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

{ Two distinct tool handlers so we can prove a request dispatched
  through registry A returns A's result, not B's -- the core P1
  contract.

  These need to be module-level functions; they're registered as
  ordinary TToolHandlers (not method-of-object) and the registry
  invokes them via @-reference. }
function EchoA(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Result := 'from-A:' + ArgsJSON;
end;

function EchoB(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Result := 'from-B:' + ArgsJSON;
end;

function FailingTool(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := 'failing tool said no';
  Result := '';
end;

function MakeRegistryWith(Handler: TToolHandler; const ToolName: string): TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  T.Name        := ToolName;
  T.Description := 'test';
  T.Schema      := '{"type":"object"}';
  T.Handler     := Handler;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Result.Register(T);
end;

function MakeFailingRegistry: TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  T.Name        := 'failing';
  T.Description := 'always fails';
  T.Schema      := '{"type":"object"}';
  T.Handler     := @FailingTool;
  T.HandlerObj  := nil;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Result.Register(T);
end;

function CallRPC(Port: Integer; const RequestJSON: string): string;
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

function TestInfoPath(const Suffix: string): string;
begin
  Result := JoinPath(JoinPath(GetHome, 'run'),
                     'tool-rpc-test-' + Suffix + '.json');
end;

procedure TestStartWritesInfoStopRemovesIt;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  P: string;
begin
  Reg := MakeRegistryWith(@EchoA, 'echo');
  try
    P := TestInfoPath('start-stop');
    Srv := TToolRPCServer.Create(Reg, P);
    try
      Srv.Start;
      AssertTrue(FileExists(P), 'info file written on Start');
      AssertTrue(Srv.Port > 0, 'kernel assigned a non-zero port');
      AssertEqInt(Length(Srv.Token), 32, 'token is 32 hex chars');
      Srv.Stop;
      AssertTrue(not FileExists(P), 'info file deleted on Stop');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestValidRequestRoundTrips;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Req, ArgsObj: TJsonObject;
  Resp, RText: string;
begin
  Reg := MakeRegistryWith(@EchoA, 'echo');
  try
    Srv := TToolRPCServer.Create(Reg, TestInfoPath('valid'));
    try
      Srv.Start;
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Srv.Token);
        Req.PutStr('name',  'echo');
        ArgsObj := TJsonObject.Parse('{"hello":"world"}');
        Req.PutObject('args', ArgsObj);
        Resp := CallRPC(Srv.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertEqStr(ResponseErr(Resp), '', 'no err in response');
      RText := ResponseResult(Resp);
      AssertContains(RText, 'from-A:', 'result came from registry A');
      AssertContains(RText, '"hello"', 'args survived round trip');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestBadTokenRejected;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Req, ArgsObj: TJsonObject;
  Resp: string;
begin
  Reg := MakeRegistryWith(@EchoA, 'echo');
  try
    Srv := TToolRPCServer.Create(Reg, TestInfoPath('badtoken'));
    try
      Srv.Start;
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', 'definitely-not-the-real-token');
        Req.PutStr('name',  'echo');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        Resp := CallRPC(Srv.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'invalid token',
                     'bad token rejected with clear message');
      AssertEqStr(ResponseResult(Resp), '',
                  'no result leaked when token rejected');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestUnknownToolSurfaces;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Req, ArgsObj: TJsonObject;
  Resp: string;
begin
  Reg := MakeRegistryWith(@EchoA, 'echo');
  try
    Srv := TToolRPCServer.Create(Reg, TestInfoPath('unknown'));
    try
      Srv.Start;
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Srv.Token);
        Req.PutStr('name',  'this_tool_does_not_exist');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        Resp := CallRPC(Srv.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'unknown tool',
                     'unknown tool error surfaces');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestFailingToolErrorPropagates;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Req, ArgsObj: TJsonObject;
  Resp: string;
begin
  Reg := MakeFailingRegistry;
  try
    Srv := TToolRPCServer.Create(Reg, TestInfoPath('failing'));
    try
      Srv.Start;
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', Srv.Token);
        Req.PutStr('name',  'failing');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        Resp := CallRPC(Srv.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(Resp), 'failing tool said no',
                     'tool-side ErrMsg propagated verbatim');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestTwoServersDispatchToTheirOwnRegistries;
{ The heart of Codex P1 + P2. Two TToolRPCServer instances bound
  to DIFFERENT registries run concurrently (simulating parent and
  subagent execute_codes). Each request must dispatch through the
  registry that server was bound to -- A's request returns from-A,
  B's returns from-B. Pre-fix the global singleton would have
  routed both requests through whichever registry registered
  execute_code last. }
var
  RegA, RegB: TToolRegistry;
  SrvA, SrvB: TToolRPCServer;
  Req, ArgsObj: TJsonObject;
  RespA, RespB: string;
begin
  RegA := MakeRegistryWith(@EchoA, 'shared_name');
  RegB := MakeRegistryWith(@EchoB, 'shared_name');
  try
    SrvA := TToolRPCServer.Create(RegA, TestInfoPath('iso-A'));
    SrvB := TToolRPCServer.Create(RegB, TestInfoPath('iso-B'));
    try
      SrvA.Start;
      SrvB.Start;
      { Distinct ports + distinct tokens prove the instances are
        independent at the wire level. }
      AssertTrue(SrvA.Port <> SrvB.Port,
                 'each server got its own port');
      AssertTrue(SrvA.Token <> SrvB.Token,
                 'each server got its own token');

      { Hit A with A's token; expect from-A. }
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', SrvA.Token);
        Req.PutStr('name',  'shared_name');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        RespA := CallRPC(SrvA.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseResult(RespA), 'from-A:',
                     'server A dispatched through registry A');

      { Hit B with B's token; expect from-B. Same tool name, different
        registry, different result. }
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', SrvB.Token);
        Req.PutStr('name',  'shared_name');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        RespB := CallRPC(SrvB.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseResult(RespB), 'from-B:',
                     'server B dispatched through registry B');

      { Cross-token attack: hit A's port with B's token. A's token
        check rejects it -- prevents a subagent's script from
        guessing the parent's port and trying to dispatch with the
        subagent's own credentials. }
      Req := TJsonObject.Create;
      try
        Req.PutStr('token', SrvB.Token);
        Req.PutStr('name',  'shared_name');
        ArgsObj := TJsonObject.Parse('{}');
        Req.PutObject('args', ArgsObj);
        RespA := CallRPC(SrvA.Port, Req.ToJSON);
      finally
        Req.Free;
      end;
      AssertContains(ResponseErr(RespA), 'invalid token',
                     'cross-instance token reuse rejected');
    finally
      SrvA.Free;
      SrvB.Free;
    end;
  finally
    RegA.Free;
    RegB.Free;
  end;
end;

procedure TestDiscoverFailsWithoutEnvVar;
{ DiscoverRunningRPC reads PASCLAW_TOOL_RPC_INFO. The Makefile
  target doesn't set it, so a fresh test run sees an empty env var
  and bails with an actionable ErrMsg. If a contributor's shell
  has the var set from outside, we skip the assertion (rare; would
  only happen during interactive debugging). }
var
  P: Integer;
  Tok, Err: string;
begin
  if GetEnvironmentVariable('PASCLAW_TOOL_RPC_INFO') <> '' then
  begin
    WriteLn('  skipping discover-no-env test: PASCLAW_TOOL_RPC_INFO is set');
    Exit;
  end;
  AssertTrue(not DiscoverRunningRPC(P, Tok, Err),
             'discovery returns False with no env var set');
  AssertContains(Err, 'PASCLAW_TOOL_RPC_INFO',
                 'ErrMsg names the missing env var');
end;

begin
  TestStartWritesInfoStopRemovesIt;
  TestValidRequestRoundTrips;
  TestBadTokenRejected;
  TestUnknownToolSurfaces;
  TestFailingToolErrorPropagates;
  TestTwoServersDispatchToTheirOwnRegistries;
  TestDiscoverFailsWithoutEnvVar;
  WriteLn('tool_rpc_tests: OK');
end.
