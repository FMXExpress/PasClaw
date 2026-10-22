program rpc_gate_tests;
(*
  The execute_code tool RPC goes through the loop's dispatch gates.

  Before: a script's `pasclaw __tool <name>` reached Registry.RunTool
  directly, so a plan-mode turn could mutate through a script, no
  BeforeToolCall hook saw the call, and the output cap did not apply.
  Now the RPC server carries an IToolDispatcher the loop hands out
  (TLoopDispatcher over DispatchOneToolCall).

  Pinned here, on the dispatcher built directly (MakeLoopDispatcher) and
  then end to end through a real TToolRPCServer on a loopback socket:

    - plan mode refuses a tcMutating tool with the same text a direct
      call gets; build mode runs it
    - a BeforeToolCall hook that cancels makes its synthetic result the
      answer and the handler never runs
    - the output cap applies (large result -> stash + handle hint)
    - CurrentDispatchDrainKey is the loop's BackgroundDrainKey inside a
      dispatch and '' outside
    - GCaptureDispatcher is installed by the loop unit, returns nil
      outside a dispatch and a live dispatcher inside one
    - the RPC server with no dispatcher keeps the registry-only path
      (test harnesses), with one it applies the gates
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
  PasClaw.Providers.Types,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.RPC,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Hooks,
  PasClaw.Tools.ToolLoop;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Copy(Got, 1, 160) + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 200)); end;

var
  GRan: Integer = 0;
  GSeenKey: string = '';
  GSeenCapture: Boolean = False;

function Danger(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Inc(GRan);
  Result := 'ran';
end;

function Big(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Result := StringOfChar('x', 5000);
end;

function Probe(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  GSeenKey := CurrentDispatchDrainKey;
  GSeenCapture := Assigned(GCaptureDispatcher) and (GCaptureDispatcher() <> nil);
  Result := 'probed';
end;

function MakeReg: TToolRegistry;
var
  T: TTool;
begin
  Result := TToolRegistry.Create;
  FillChar(T, SizeOf(T), 0);
  T.Name := 'danger'; T.Description := 'mutates'; T.Schema := '{"type":"object"}';
  T.Handler := @Danger; T.IsCore := True; T.Category := tcMutating;
  Result.Register(T);
  FillChar(T, SizeOf(T), 0);
  T.Name := 'big'; T.Description := 'large'; T.Schema := '{"type":"object"}';
  T.Handler := @Big; T.IsCore := True; T.Category := tcReadOnly;
  Result.Register(T);
  FillChar(T, SizeOf(T), 0);
  T.Name := 'probe'; T.Description := 'reads thread state'; T.Schema := '{"type":"object"}';
  T.Handler := @Probe; T.IsCore := True; T.Category := tcReadOnly;
  Result.Register(T);
end;

function MakeCfg(Reg: TToolRegistry; Mode: TPasClawMode): TToolLoopConfig;
begin
  Result := Default(TToolLoopConfig);
  Result.Registry := Reg;
  Result.Mode := Mode;
  Result.Model := 'fake';
  Result.MaxIterations := 1;
end;

type
  TCancelHook = class(TPasClawHook)
  public
    Fired: Integer;
    procedure BeforeToolCall(const ToolCall: TToolCall; var Cancel: Boolean;
                             var SyntheticResult: string); override;
  end;

procedure TCancelHook.BeforeToolCall(const ToolCall: TToolCall; var Cancel: Boolean;
                                     var SyntheticResult: string);
begin
  Inc(Fired);
  if ToolCall.Func.Name = 'danger' then
  begin
    Cancel := True;
    SyntheticResult := 'nope: hook said so';
  end;
end;

procedure TestModeGate;
var
  Reg: TToolRegistry;
  Disp: IToolDispatcher;
  Err, R: string;
begin
  Reg := MakeReg;
  try
    GRan := 0;
    Disp := MakeLoopDispatcher(MakeCfg(Reg, pmPlan));
    R := Disp.Dispatch('danger', '{}', Err);
    AssertEqStr(Err, '', 'plan-mode refusal is a result, not an error');
    AssertEqStr(R, PlanModeRefusal('danger'), 'plan mode refuses through the RPC path with the same text');
    AssertTrue(GRan = 0, 'the handler did not run in plan mode');

    Disp := MakeLoopDispatcher(MakeCfg(Reg, pmBuild));
    R := Disp.Dispatch('danger', '{}', Err);
    AssertEqStr(R, 'ran', 'build mode runs it');
    AssertTrue(GRan = 1, 'handler ran once');

    R := Disp.Dispatch('nosuch', '{}', Err);
    AssertTrue(Err <> '', 'unknown tool is an error');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: plan mode refuses, build mode runs, unknown errors');
end;

procedure TestHookAndCap;
var
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Hook: TCancelHook;
  Disp: IToolDispatcher;
  Err, R: string;
begin
  Reg := MakeReg;
  Hook := TCancelHook.Create;
  try
    Cfg := MakeCfg(Reg, pmBuild);
    SetLength(Cfg.Hooks, 1);
    Cfg.Hooks[0] := Hook;
    Cfg.ToolOutputCap := 200;
    GRan := 0;
    Disp := MakeLoopDispatcher(Cfg);
    R := Disp.Dispatch('danger', '{}', Err);
    AssertEqStr(R, 'nope: hook said so', 'a cancelling hook supplies the result');
    AssertTrue(GRan = 0, 'cancelled call never reached the handler');
    AssertTrue(Hook.Fired = 1, 'hook fired once');

    R := Disp.Dispatch('big', '{}', Err);
    AssertTrue(Length(R) < 5000, 'output cap applied on the RPC path');
    AssertContains(R, 'tool_output_get', 'capped output carries the retrieval hint');
  finally
    Hook.Free;
    Reg.Free;
  end;
  WriteLn('  ok: BeforeToolCall hook cancels, output cap applies');
end;

procedure TestDrainKeyAndCapture;
var
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Disp: IToolDispatcher;
  Err, R: string;
begin
  AssertEqStr(CurrentDispatchDrainKey, '', 'no drain key outside a dispatch');
  AssertTrue(Assigned(GCaptureDispatcher), 'the loop unit installed the capture hook');
  AssertTrue(GCaptureDispatcher() = nil, 'capture outside a dispatch is nil');
  Reg := MakeReg;
  try
    Cfg := MakeCfg(Reg, pmBuild);
    Cfg.BackgroundDrainKey := 'sess-A';
    Disp := MakeLoopDispatcher(Cfg);
    R := Disp.Dispatch('probe', '{}', Err);
    AssertEqStr(R, 'probed', 'probe ran');
    AssertEqStr(GSeenKey, 'sess-A', 'a handler sees the dispatching loop''s drain key');
    AssertTrue(GSeenCapture, 'a handler can capture a live dispatcher');
    AssertEqStr(CurrentDispatchDrainKey, '', 'drain key cleared after the dispatch');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: CurrentDispatchDrainKey and GCaptureDispatcher scoped to the dispatch');
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

function Field(const Resp, Key: string): string;
var
  Obj: TJsonObject;
begin
  Result := '';
  try Obj := TJsonObject.Parse(Resp); except Obj := nil; end;
  if Obj = nil then Exit;
  try Result := Obj.GetStr(Key, ''); finally Obj.Free; end;
end;

procedure TestThroughServer;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Disp: IToolDispatcher;
  Resp, P: string;
begin
  Reg := MakeReg;
  try
    P := JoinPath(JoinPath(GetHome, 'run'), 'tool-rpc-gate-test.json');
    { No dispatcher: the registry-only path a harness uses. }
    GRan := 0;
    Srv := TToolRPCServer.Create(Reg, P);
    try
      Srv.Start;
      Resp := CallRPC(Srv.Port, '{"token":"' + Srv.Token + '","name":"danger","args":{}}');
      AssertEqStr(Field(Resp, 'result'), 'ran', 'no dispatcher -> registry path runs the tool');
    finally
      Srv.Free;
    end;
    { With a plan-mode dispatcher: refused on the wire. }
    GRan := 0;
    Disp := MakeLoopDispatcher(MakeCfg(Reg, pmPlan));
    Srv := TToolRPCServer.Create(Reg, P, Disp);
    try
      Srv.Start;
      Resp := CallRPC(Srv.Port, '{"token":"' + Srv.Token + '","name":"danger","args":{}}');
      AssertEqStr(Field(Resp, 'result'), PlanModeRefusal('danger'), 'plan-mode refusal crosses the RPC wire');
      AssertEqStr(Field(Resp, 'err'), '', 'refusal is not an err');
      AssertTrue(GRan = 0, 'handler did not run');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
  WriteLn('  ok: RPC server applies the dispatcher when given one, registry path otherwise');
end;

begin
  TestModeGate;
  TestHookAndCap;
  TestDrainKeyAndCapture;
  TestThroughServer;
  WriteLn('PASS');
end.
