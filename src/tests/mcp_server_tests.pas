program mcp_server_tests;
(*
  Covers PasClaw.MCP.Server -- the inbound MCP server core that exposes
  a curated read-only slice of the tool registry as MCP tools, so
  external runtimes (Claude Desktop, Cursor, Codex CLI, any MCP host)
  consume PasClaw's memory_search / kb_search / session_search live.

  Strategy: build a TToolRegistry with two synthetic tools (one
  tcReadOnly, one tcMutating), feed JSON-RPC request lines through
  TMCPServerCore.HandleRequest, parse the response, assert shape +
  values. No network, no real MCP host.

  Pins contracts the protocol surface needs:
    - initialize round-trip carries serverInfo + tools capability
    - notifications/initialized produces no response (notification)
    - tools/list filters out tcMutating by default
    - tools/list includes tcMutating when AllowMutating=true
    - tools/call dispatches into the registry and returns the result
      in the MCP "content[]" shape
    - tools/call against a mutating tool with AllowMutating=false
      returns method-not-found (tool not exposed)
    - tools/call against an unknown name returns method-not-found
    - tool failures land as isError=true with content (not a
      JSON-RPC error), so hosts keep the session alive
    - unknown methods return -32601 method-not-found
    - malformed JSON returns -32700 parse error with id=null
    - explicit SetAllowList narrows the surface further
    - request id type round-trips: numeric in -> numeric out,
      string in -> string out, missing -> null in error responses
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.MCP.Server;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

function StripSpaces(const S: string): string;
var
  i, k: Integer;
begin
  SetLength(Result, Length(S));
  k := 0;
  for i := 1 to Length(S) do
    if S[i] <> ' ' then
    begin
      Inc(k);
      Result[k] := S[i];
    end;
  SetLength(Result, k);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  { Strip ASCII spaces from both sides so tests aren't tied to the
    JSON serialiser's choice of whitespace ("a" : 1 vs "a":1). }
  if Pos(StripSpaces(Needle), StripSpaces(Haystack)) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 300) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(StripSpaces(Needle), StripSpaces(Haystack)) > 0 then
    Fail_(Msg + ' (needle "' + Needle + '" was present in "' +
          Copy(Haystack, 1, 300) + '")');
end;

function MemoryHandler(const ArgsJSON: string; out ErrMsg: string): string;
{ Fake memory_search: echoes back the q field so we can verify the
  registry got the right arguments. }
var
  Obj: TJsonObject;
  Q: string;
begin
  ErrMsg := '';
  Q := '';
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj <> nil then
  try
    Q := Obj.GetStr('q', '');
  finally
    Obj.Free;
  end;
  Result := 'mem-result for q=' + Q;
end;

function FailingHandler(const ArgsJSON: string; out ErrMsg: string): string;
begin
  Result  := '';
  ErrMsg  := 'simulated tool failure';
  if ArgsJSON = '' then ;
end;

function ShellHandler(const ArgsJSON: string; out ErrMsg: string): string;
{ Fake mutating tool to verify the gate skips it by default. }
begin
  ErrMsg := '';
  Result := 'shell-result';
  if ArgsJSON = '' then ;
end;

procedure RegisterFakeTools(Reg: TToolRegistry);
var
  T: TTool;
begin
  T := Default(TTool);
  T.Name        := 'memory_search';
  T.Description := 'search workspace memory';
  T.Schema      := '{"type":"object","properties":{"q":{"type":"string"}}}';
  T.Category    := tcReadOnly;
  T.Handler     := MemoryHandler;
  Reg.Register(T);

  T := Default(TTool);
  T.Name        := 'session_search';
  T.Description := 'search past sessions';
  T.Schema      := '{"type":"object"}';
  T.Category    := tcReadOnly;
  T.Handler     := MemoryHandler;
  Reg.Register(T);

  T := Default(TTool);
  T.Name        := 'shell';
  T.Description := 'run a shell command';
  T.Schema      := '{"type":"object"}';
  T.Category    := tcMutating;
  T.Handler     := ShellHandler;
  Reg.Register(T);

  T := Default(TTool);
  T.Name        := 'broken_search';
  T.Description := 'always fails';
  T.Schema      := '{"type":"object"}';
  T.Category    := tcReadOnly;
  T.Handler     := FailingHandler;
  Reg.Register(T);
end;

procedure TestInitializeRoundTrip;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Req, Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '1.2.3');
    try
      Req := '{"jsonrpc":"2.0","id":1,"method":"initialize",' +
             '"params":{"protocolVersion":"2024-11-05",' +
             '"capabilities":{},"clientInfo":{"name":"t","version":"0"}}}';
      Resp := Srv.HandleRequest(Req);
      AssertContains(Resp, '"id":1', 'numeric id echoed as number');
      AssertContains(Resp, 'serverInfo',     'serverInfo present');
      AssertContains(Resp, '"name":"pasclaw"', 'server name = pasclaw');
      AssertContains(Resp, '"version":"1.2.3"', 'server version surfaced');
      AssertContains(Resp, 'protocolVersion', 'protocolVersion in result');
      AssertContains(Resp, '"tools":{',      'tools capability advertised');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestInitializedNotificationHasNoResponse;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","method":"notifications/initialized"}');
      AssertEqStr(Resp, '', 'notification produces empty response');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsListFiltersMutating;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}');
      AssertContains(Resp, '"name":"memory_search"', 'memory_search exposed');
      AssertContains(Resp, '"name":"session_search"', 'session_search exposed');
      AssertContains(Resp, '"name":"broken_search"',  'broken_search exposed');
      AssertNotContains(Resp, '"name":"shell"',
                        'mutating shell tool filtered out by default');
      AssertContains(Resp, '"inputSchema"', 'inputSchema present');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsListWithMutatingAllowed;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, True, '');  { allow mutating }
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}');
      AssertContains(Resp, '"name":"shell"',
                      'shell tool exposed when allow_mutating');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsCallHappyPath;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":3,"method":"tools/call",' +
        '"params":{"name":"memory_search","arguments":{"q":"SCARS"}}}');
      AssertContains(Resp, '"id":3',         'id echoed');
      AssertContains(Resp, '"content"',      'MCP content[] shape');
      AssertContains(Resp, '"type":"text"',  'content type = text');
      AssertContains(Resp, 'mem-result for q=SCARS',
                      'tool output reached MCP response');
      AssertNotContains(Resp, '"isError":true', 'no isError on happy path');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsCallToolErrorLandsAsIsError;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":4,"method":"tools/call",' +
        '"params":{"name":"broken_search","arguments":{}}}');
      AssertContains(Resp, '"isError":true',
                      'tool failures land as isError=true');
      AssertContains(Resp, 'simulated tool failure',
                      'error text surfaced as content');
      AssertNotContains(Resp, '"error":', 'no JSON-RPC error wrapper');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsCallMutatingGateBlocks;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":5,"method":"tools/call",' +
        '"params":{"name":"shell","arguments":{}}}');
      AssertContains(Resp, '"error"',          'JSON-RPC error returned');
      AssertContains(Resp, '"code":-32601',    'method-not-found code');
      AssertContains(Resp, 'tool not exposed', 'message identifies the gate');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestToolsCallUnknownToolErrors;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":6,"method":"tools/call",' +
        '"params":{"name":"no_such_tool","arguments":{}}}');
      AssertContains(Resp, '"code":-32601',
                      'unknown tool -> method-not-found');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestUnknownMethodErrors;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":"r1","method":"resources/list"}');
      AssertContains(Resp, '"code":-32601',
                      'unimplemented method -> method-not-found');
      AssertContains(Resp, '"id":"r1"', 'string id round-trips');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestParseErrorReturnsNullId;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest('{not json}');
      AssertContains(Resp, '"code":-32700', 'parse-error code');
      AssertContains(Resp, '"id":null',     'id=null on parse error');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestAllowListNarrowsSurface;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
  Only: array of string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFakeTools(Reg);
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      SetLength(Only, 1);
      Only[0] := 'memory_search';
      Srv.SetAllowList(Only);
      Resp := Srv.HandleRequest(
        '{"jsonrpc":"2.0","id":7,"method":"tools/list"}');
      AssertContains(Resp,    '"name":"memory_search"', 'allowlist keeps memory_search');
      AssertNotContains(Resp, '"name":"session_search"',
                        'allowlist drops session_search');
      AssertNotContains(Resp, '"name":"broken_search"',
                        'allowlist drops broken_search');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

procedure TestPingRoundTrip;
var
  Reg: TToolRegistry;
  Srv: TMCPServerCore;
  Resp: string;
begin
  Reg := TToolRegistry.Create;
  try
    Srv := TMCPServerCore.Create(Reg, False, '');
    try
      Resp := Srv.HandleRequest('{"jsonrpc":"2.0","id":8,"method":"ping"}');
      AssertContains(Resp, '"id":8',   'numeric id echoed');
      AssertContains(Resp, '"result"', 'ping returns a result');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
end;

begin
  TestInitializeRoundTrip;                  WriteLn('  ok: initialize');
  TestInitializedNotificationHasNoResponse; WriteLn('  ok: initialized notification (no response)');
  TestToolsListFiltersMutating;             WriteLn('  ok: tools/list filters mutating');
  TestToolsListWithMutatingAllowed;         WriteLn('  ok: tools/list with mutating allowed');
  TestToolsCallHappyPath;                   WriteLn('  ok: tools/call happy path');
  TestToolsCallToolErrorLandsAsIsError;     WriteLn('  ok: tools/call tool-error -> isError');
  TestToolsCallMutatingGateBlocks;          WriteLn('  ok: tools/call mutating gate blocks');
  TestToolsCallUnknownToolErrors;           WriteLn('  ok: tools/call unknown tool errors');
  TestUnknownMethodErrors;                  WriteLn('  ok: unknown method errors');
  TestParseErrorReturnsNullId;              WriteLn('  ok: parse error returns id=null');
  TestAllowListNarrowsSurface;              WriteLn('  ok: allowlist narrows surface');
  TestPingRoundTrip;                        WriteLn('  ok: ping round-trip');
  WriteLn('PASS');
end.
