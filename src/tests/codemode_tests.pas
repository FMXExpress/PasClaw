program codemode_tests;
(*
  Code Mode for MCP servers: a server's tools are reachable from an
  execute_code script and nowhere else.

    - registry: RegisterCodeMode keeps a tool out of ToProviderDefs (even
      after a Reveal), out of DeferredNames / DeferredFind (so tool_search
      cannot list or load it), while Find / RunTool dispatch it;
      CodeModeNames and CodeModeCatalog (all / per server / unknown)
    - tool_search select: on a code-mode name explains the situation
    - the "## Deferred Tools" section names code-mode servers with the
      script recipe, with and without classic deferred tools present
    - code_catalog tool registers once and returns the catalog
    - the RPC server answers the catalog verb from its bound registry
    - config: codemode defaults true, per-server false, mcp_codemode_default
      false flips the default, round-trip; a server added by `mcp add`
      keeps FOLLOWING that default instead of being pinned to the
      zero-initialised false (Codex P1 on #609)
    - execute_code: the prologue defines `tool` for bash and PowerShell and
      a real bash run sees the function
    - execute_code tells the script where to call BACK to, taking the
      address from the active shell backend -- without which the callback
      cannot leave a container and code-mode tools are unreachable there
      (Codex P1 on #609)
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
  PasClaw.Tools.ExecuteCode,
  PasClaw.Platform,
  PasClaw.Shell.Backend,
  PasClaw.MCP.Disclosure;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 300)); end;
procedure AssertNotContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) > 0 then Fail_(Msg + ' -- did not expect "' + Needle + '"'); end;

function Echo(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Result := 'echo:' + ArgsJSON; end;

function Tool(const Name, Desc, Schema: string): TTool;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Name := Name; Result.Description := Desc; Result.Schema := Schema;
  Result.Handler := @Echo; Result.IsCore := False; Result.Category := tcReadOnly;
end;

function MakeReg: TToolRegistry;
begin
  Result := TToolRegistry.Create;
  Result.Register(Tool('fs_read', 'read', '{"type":"object"}'));
  Result.RegisterDeferred(Tool('other__x', '[mcp:other] classic deferred', '{"type":"object"}'), True);
  Result.RegisterCodeMode(Tool('gh__list', '[mcp:gh] list issues', '{"type":"object","properties":{"repo":{"type":"string"}}}'));
  Result.RegisterCodeMode(Tool('gh__get', '[mcp:gh] get issue', '{"type":"object"}'));
  Result.RegisterCodeMode(Tool('db__query', '[mcp:db] run "sql"', ''));
end;

function InArr(const A: TStringArray; const S: string): Boolean;
var i: Integer;
begin for i := 0 to High(A) do if A[i] = S then Exit(True); Result := False; end;

procedure TestRegistry;
var
  Reg: TToolRegistry;
  Defs: TToolDefinitionArray;
  i: Integer;
  Names: TStringArray;
  T: TTool;
  Err, R: string;
begin
  Reg := MakeReg;
  try
    Defs := Reg.ToProviderDefs;
    for i := 0 to High(Defs) do
      AssertTrue(Pos('gh__', Defs[i].Name) = 0, 'code-mode tool is never a provider def: ' + Defs[i].Name);
    AssertEqInt(Length(Defs), 1, 'only fs_read is a provider def (other__x deferred)');
    Reg.Reveal('gh__list');
    Defs := Reg.ToProviderDefs;
    AssertEqInt(Length(Defs), 1, 'a stale reveal does not resurrect a code-mode schema');

    Names := Reg.DeferredNames;
    AssertTrue(InArr(Names, 'other__x'), 'classic deferred tool listed for tool_search');
    AssertTrue(not InArr(Names, 'gh__list'), 'code-mode tool not listed for tool_search');
    AssertTrue(not Reg.DeferredFind('gh__list', T), 'DeferredFind does not hand out a code-mode schema');
    AssertTrue(Reg.Find('gh__list', T) and T.CodeMode and T.IsDeferred, 'Find still resolves it, flagged');
    R := Reg.RunTool('gh__list', '{"repo":"a"}', Err);
    AssertEqStr(R, 'echo:{"repo":"a"}', 'RunTool dispatches a code-mode tool');

    Names := Reg.CodeModeNames;
    AssertEqInt(Length(Names), 3, 'three code-mode tools');
    R := Reg.CodeModeCatalog('');
    AssertContains(R, '"name":"gh__list"', 'catalog has gh__list');
    AssertContains(R, '"server":"gh"', 'catalog names the server');
    AssertContains(R, '"description":"[mcp:gh] list issues"', 'catalog carries the description');
    AssertContains(R, '"schema":{"type":"object","properties":{"repo":{"type":"string"}}}', 'schema embedded raw');
    AssertContains(R, '"name":"db__query"', 'db tool present');
    AssertContains(R, 'run \"sql\"', 'description quotes are escaped');
    AssertContains(R, '"schema":{}', 'empty schema becomes {}');
    AssertNotContains(R, 'other__x', 'classic deferred tool not in the catalog');
    R := Reg.CodeModeCatalog('gh');
    AssertContains(R, 'gh__get', 'per-server catalog has gh tools');
    AssertNotContains(R, 'db__query', 'per-server catalog excludes other servers');
    AssertEqStr(Reg.CodeModeCatalog('nope'), '[]', 'unknown server -> empty array');
    { Register / RegisterDeferred clear the flag on a stack record. }
    T := Tool('plain', 'p', '{}'); T.CodeMode := True;
    Reg.Register(T);
    AssertTrue(Reg.Find('plain', T) and (not T.CodeMode), 'Register clears CodeMode');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: registry keeps code-mode tools out of schemas and tool_search, in dispatch and catalog');
end;

procedure TestDisclosureAndCatalogTool;
var
  Reg: TToolRegistry;
  Cfg: TConfig;
  Disc: TMCPDisclosure;
  Err, R, Sec: string;
  T: TTool;
begin
  Reg := MakeReg;
  Cfg := TConfig.Create;
  try
    Cfg.MCPProgressiveDisclosure := True;
    Disc := RegisterMCPDisclosureTools(Reg, Cfg, False);
    try
      R := Reg.RunTool('tool_search', '{"query":"select:gh__list"}', Err);
      AssertContains(R, 'code-mode tool', 'select: on a code-mode name explains it');
      AssertContains(R, 'tool gh__list', 'and gives the script recipe');
      AssertTrue(not Reg.AnyRevealed, 'nothing was revealed');
      R := Reg.RunTool('tool_search', '{"query":"select:other__x"}', Err);
      AssertContains(R, 'other__x', 'classic deferred tool still loads');
    finally
      Disc.Free;
    end;

    Sec := BuildDeferredToolsSection(Reg);
    AssertContains(Sec, '## Deferred Tools', 'section present');
    AssertContains(Sec, '### Code-mode MCP servers', 'code-mode paragraph present');
    AssertContains(Sec, '`gh` (2 tools)', 'gh listed with its count');
    AssertContains(Sec, '`db` (1 tools)', 'db listed');
    AssertContains(Sec, 'tool <server>__<name>', 'script recipe given');
    AssertContains(Sec, 'tool --catalog', 'catalog recipe given');
    AssertNotContains(Sec, 'gh__list', 'individual code-mode tool names are not listed');

    { Only code-mode tools, no classic deferred ones: the section still renders. }
    Reg.Reveal('other__x');
    Sec := BuildDeferredToolsSection(Reg);
    AssertContains(Sec, '## Deferred Tools', 'section present with only code-mode servers');
    AssertContains(Sec, '### Code-mode MCP servers', 'code-mode paragraph present');
    AssertNotContains(Sec, 'available but not loaded', 'no classic preamble when nothing classic is deferred');

    RegisterCodeCatalogTool(Reg);
    RegisterCodeCatalogTool(Reg);
    AssertTrue(Reg.Find('code_catalog', T) and (T.Category = tcReadOnly), 'code_catalog registered, read-only');
    R := Reg.RunTool('code_catalog', '{}', Err);
    AssertContains(R, '"name":"gh__list"', 'code_catalog lists everything');
    AssertContains(R, 'tool <name>', 'code_catalog says how to call');
    R := Reg.RunTool('code_catalog', '{"server":"db"}', Err);
    AssertContains(R, 'db__query', 'narrowed to db');
    AssertNotContains(R, 'gh__list', 'gh excluded');
    R := Reg.RunTool('code_catalog', '{"server":"zz"}', Err);
    AssertContains(R, 'no code-mode tools for server "zz"', 'unknown server message');
  finally
    Cfg.Free;
    Reg.Free;
  end;
  WriteLn('  ok: tool_search explains, prompt section names servers, code_catalog works');
end;

function CallRPC(Port: Integer; const RequestJSON: string): string;
var
  Client: TIdTCPClient;
begin
  Result := '';
  Client := TIdTCPClient.Create(nil);
  try
    Client.Host := '127.0.0.1'; Client.Port := Port; Client.ConnectTimeout := 3000;
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

procedure TestRPCCatalog;
var
  Reg: TToolRegistry;
  Srv: TToolRPCServer;
  Resp, R: string;
  Obj: TJsonObject;
begin
  Reg := MakeReg;
  try
    Srv := TToolRPCServer.Create(Reg, JoinPath(JoinPath(GetHome, 'run'), 'tool-rpc-codemode-test.json'));
    try
      Srv.Start;
      Resp := CallRPC(Srv.Port, '{"token":"' + Srv.Token + '","catalog":"gh"}');
      Obj := TJsonObject.Parse(Resp);
      try
        R := Obj.GetStr('result', '');
        AssertEqStr(Obj.GetStr('err', ''), '', 'catalog verb has no err');
      finally
        Obj.Free;
      end;
      AssertContains(R, 'gh__list', 'catalog over the wire');
      AssertNotContains(R, 'db__query', 'narrowed over the wire');
      Resp := CallRPC(Srv.Port, '{"token":"bad","catalog":""}');
      AssertContains(Resp, 'invalid token', 'catalog needs the token too');
    finally
      Srv.Free;
    end;
  finally
    Reg.Free;
  end;
  WriteLn('  ok: RPC catalog verb');
end;

procedure TestConfig;
var
  A, B: TConfig;
begin
  A := TConfig.Create;
  B := TConfig.Create;
  try
    AssertTrue(A.MCPCodeModeDefault, 'code mode is the default');
    A.FromJSON('{"mcp_servers":[{"name":"a","cmd":"x"},{"name":"b","cmd":"y","codemode":false}]}');
    AssertEqInt(Length(A.MCPServers), 2, 'two servers');
    AssertTrue(A.MCPServers[0].CodeMode, 'absent codemode -> default true');
    AssertTrue(not A.MCPServers[1].CodeMode, 'explicit false honoured');
    B.FromJSON(A.ToJSON);
    AssertTrue(B.MCPServers[0].CodeMode and (not B.MCPServers[1].CodeMode), 'round-trips');
    AssertNotContains(A.ToJSON, 'mcp_codemode_default', 'default-true global not emitted');

    B.FromJSON('{"mcp_codemode_default":false,"mcp_servers":[{"name":"a","cmd":"x"},{"name":"c","cmd":"z","codemode":true}]}');
    AssertTrue(not B.MCPCodeModeDefault, 'global default read');
    AssertTrue(not B.MCPServers[0].CodeMode, 'absent codemode -> global default false');
    AssertTrue(B.MCPServers[1].CodeMode, 'explicit true still wins');
    AssertContains(StringReplace(B.ToJSON, ' ', '', [rfReplaceAll]), '"mcp_codemode_default":false', 'explicit-false global emitted');
  finally
    A.Free;
    B.Free;
  end;
  WriteLn('  ok: config codemode per server and global default');
end;

type
  (* A backend that runs the command on the host (so a real script runs)
     but answers IShellHostRPC like the Docker one does. Stands in for a
     container we cannot spawn in the test suite. *)
  TPassthroughHostBackend = class(TInterfacedObject, IShellBackend, IShellHostRPC)
  public
    function Name: string;
    function Describe: string;
    procedure StartSession(const SessionId: string);
    procedure CloseSession(const SessionId: string);
    function Exec(const SessionId, Cmd, WorkDir: string;
                  ExtraEnv: TStringList; out Output: string): Integer;
    function RpcBindIP: string;
    function RpcConnectHost: string;
  end;

function TPassthroughHostBackend.Name: string; begin Result := 'passthrough'; end;
function TPassthroughHostBackend.Describe: string; begin Result := 'test'; end;
procedure TPassthroughHostBackend.StartSession(const SessionId: string); begin end;
procedure TPassthroughHostBackend.CloseSession(const SessionId: string); begin end;

function TPassthroughHostBackend.Exec(const SessionId, Cmd, WorkDir: string;
                                      ExtraEnv: TStringList;
                                      out Output: string): Integer;
begin
  Result := RunOneShotWithEnv(Cmd, WorkDir, ExtraEnv, Output);
end;

function TPassthroughHostBackend.RpcBindIP: string;
begin
  { '' so the server stays on loopback and really starts here; the
    address itself is the docker backend's business and is tested there. }
  Result := '';
end;

function TPassthroughHostBackend.RpcConnectHost: string;
begin
  Result := 'fake-host.test';
end;

procedure TestScriptIsToldWhereToCallBack;
(* The glue: execute_code has to ask the active backend where its
   tool-RPC server should listen and what the script should dial, and put
   that in the discovery file the script reads.

   Without it the file only ever said 127.0.0.1, so under the Docker
   backend `tool ...` dialled the container itself and every code-mode
   call failed to connect. Asserted from inside the script, on the file
   it actually gets handed. (Codex P1 on #609.) *)
{$IFDEF UNIX}
var
  Reg: TToolRegistry;
  Out_, Err: string;
begin
  Reg := MakeReg;
  try
    RegisterExecuteCodeTool(Reg);
    SetActiveShellBackend(TPassthroughHostBackend.Create);
    try
      Out_ := Reg.RunTool('execute_code',
                '{"lang":"bash","code":"cat \"$PASCLAW_TOOL_RPC_INFO\""}', Err);
      AssertEqStr(Err, '', 'the script ran');
      AssertContains(Out_, '"host":"fake-host.test"',
                     'the script is told to dial the backend''s host, ' +
                     'not its own loopback');
      AssertContains(Out_, '"token":"', 'and still gets the token + port');
    finally
      SetActiveShellBackend(nil);
    end;
  finally
    Reg.Free;
  end;
  WriteLn('  ok: the discovery file carries the backend''s callback host');
end;
{$ELSE}
begin
  WriteLn('  skip: callback-host test needs a POSIX shell');
end;
{$ENDIF}

function AddedServerHasCodeModeKey(const Raw: string): Boolean;
{ Does the single server in this config.json carry an explicit
  "codemode"? Absent is the whole point: it means "follow the default". }
var
  Obj, Srv: TJsonObject;
  Arr: TJsonArray;
begin
  Result := False;
  Obj := TJsonObject.Parse(Raw);
  try
    Arr := Obj.ChildArray('mcp_servers');
    AssertTrue(Arr <> nil, 'config.json has an mcp_servers array');
    try
      AssertEqInt(Arr.Count, 1, 'exactly one server was added');
      Srv := Arr.ItemObject(0);
      AssertTrue(Srv <> nil, 'the entry is an object');
      try
        Result := Srv.Has('codemode');
      finally
        Srv.Free;
      end;
    finally
      Arr.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function LoadedCodeMode(const Raw: string): Boolean;
{ What that file actually means once loaded. }
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    Cfg.FromJSON(Raw);
    AssertEqInt(Length(Cfg.MCPServers), 1, 'one server loaded back');
    Result := Cfg.MCPServers[0].CodeMode;
  finally
    Cfg.Free;
  end;
end;

procedure TestMcpAddFollowsTheDefault;
(* `mcp add` has to leave the new server FOLLOWING mcp_codemode_default,
   not pin it.

   Two things conspired to pin it off. The record `mcp add` / `mcp
   install` / onboarding build is zero-initialised, so CodeMode came out
   False; and MCPToJSON wrote the key unconditionally, so that False was
   persisted. Every server added through a supported flow was therefore
   stuck on classic exposure whatever the operator set the default to.
   (Codex P1 on #609.)

   Runs the real binary: the whole bug lived in what the command wrote to
   disk, and an in-process assertion on a hand-built record would have
   missed both halves. *)
{$IFDEF UNIX}
var
  Home, Bin, Out_, Raw: string;

  function AddServer(const PreWrittenConfig: string): string;
  { Fresh home, optional config.json seeded first, `mcp add`, return the
    config.json it left behind. }
  var
    Env: TStringList;
  begin
    RunOneShot('rm -rf "' + Home + '"; mkdir -p "' + Home + '"', '', Out_);
    if PreWrittenConfig <> '' then
      WriteFileText(JoinPath(Home, 'config.json'), PreWrittenConfig);
    Env := TStringList.Create;
    try
      Env.Add('PASCLAW_HOME=' + Home);
      AssertEqInt(RunOneShotWithEnv('"' + Bin + '" mcp add srv /usr/bin/true',
                                    '', Env, Out_), 0,
                  'mcp add succeeded: ' + Copy(Out_, 1, 300));
    finally
      Env.Free;
    end;
    Result := ReadFileText(JoinPath(Home, 'config.json'));
  end;

begin
  Bin := ExpandFileName('build/pasclaw');
  if not FileExists(Bin) then
  begin
    WriteLn('  skipping mcp-add test: build/pasclaw missing');
    Exit;
  end;
  Home := JoinPath(GetTempDir, 'pasclaw-mcpadd-' + IntToStr(Random(MaxInt)));
  try
    { Default (true): no key at all, and it reads back as code mode. }
    Raw := AddServer('');
    AssertTrue(not AddedServerHasCodeModeKey(Raw),
               'no codemode key -- the server follows the default: ' +
               Copy(Raw, 1, 300));
    AssertTrue(LoadedCodeMode(Raw),
               'so it reads back as code mode, like the default says');

    { Default flipped off: still no key, and now it reads back off. Same
      file shape either way -- that is what "follows the default" means. }
    Raw := AddServer('{"mcp_codemode_default":false}');
    AssertTrue(not AddedServerHasCodeModeKey(Raw),
               'still no codemode key under a false default: ' +
               Copy(Raw, 1, 300));
    AssertTrue(not LoadedCodeMode(Raw),
               'and it follows the default DOWN, not pinned to either value');
  finally
    RunOneShot('rm -rf "' + Home + '"', '', Out_);
  end;
  WriteLn('  ok: `mcp add` leaves the server following mcp_codemode_default');
end;
{$ELSE}
begin
  WriteLn('  skip: mcp-add test needs a POSIX shell');
end;
{$ENDIF}

procedure TestPrologue;
var
  Body, Err, Out_: string;
begin
  Body := PrepareScriptBody('bash', 'echo hi');
  AssertContains(Body, 'tool() {', 'bash prologue defines tool');
  AssertContains(Body, '__tool "$@"', 'bash prologue forwards args');
  AssertTrue(Pos('echo hi', Body) > Pos('tool() {', Body), 'body follows the prologue');
  AssertEqInt(Pos(#10, Body), Length(ScriptPrologue('bash')) + 1, 'prologue is exactly one line');
  Body := PrepareScriptBody('powershell', 'Write-Output hi');
  AssertContains(Body, 'function tool', 'powershell prologue defines tool');
  AssertContains(Body, '__tool @args', 'powershell prologue forwards args');
  {$IFDEF UNIX}
  Out_ := Tool_ExecuteCode('{"code":"type tool | head -1; echo BIN=[$PASCLAW_BIN]","lang":"bash"}', Err);
  AssertTrue(Err = '', 'script ran: ' + Err);
  AssertContains(Out_, 'tool is a function', 'the function exists in a real script');
  { Without a registry (this harness) there is no RPC server and so no
    env; the function then falls back to a `pasclaw` on PATH. }
  AssertContains(Out_, 'BIN=[]', 'no PASCLAW_BIN without an RPC server');
  AssertNotContains(ScriptPrologue('bash'), '${', 'prologue avoids the expansion the denylist forbids');
  {$ENDIF}
  WriteLn('  ok: script prologue');
end;

begin
  TestRegistry;
  TestDisclosureAndCatalogTool;
  TestRPCCatalog;
  TestConfig;
  TestPrologue;
  TestScriptIsToldWhereToCallBack;
  TestMcpAddFollowsTheDefault;
  WriteLn('PASS');
end.
