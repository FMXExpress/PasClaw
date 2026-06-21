{
  PasClaw.MCP.Bridge - register MCP tools into the PasClaw tool registry
  so the agent loop can invoke them transparently. Tools are namespaced
  "<server>__<tool>" to avoid clashes with built-ins or between servers.

  Two-layer boot for fast startup with multiple servers:

    1. Cache pass (synchronous, instant).
       Each enabled MCP server's tools/list response from the previous
       boot lives at <home>/mcp-cache/<server>.json. ConnectMCPServers
       reads each cache and registers the tools with a "still loading"
       dispatch (server state = lsLoading). The model sees the tools
       immediately on the first chat completion; attempts to *call*
       them before the live connect finishes return
       "mcp loading, retry" rather than crashing.

    2. Network pass (one TThread per server, parallel).
       Each TMCPLoader creates the real client, runs Connect + ListTools,
       saves a fresh cache, and atomically swaps the live Client into
       its server-state object (lsReady). Tools newly seen vs the cache
       get fresh dispatch objects registered into the (thread-safe)
       TToolRegistry; stale ones stay in the registry but their state
       flips to lsFailed so calls surface "no longer exposed".

       A failed connect leaves the cached tools registered but the
       server state goes lsFailed + Error, so CallTool surfaces the
       connect error rather than silently looking like "loading"
       forever.

  Dispatch uses TTool.HandlerObj (method-of-object) so each registered
  tool carries its server+tool context implicitly -- no fixed slot table,
  no per-slot handler boilerplate, no MaxBindings cap. Replicate's
  catalog can be as big as it wants.

  FreeMCPClients gives each loader a bounded wait to finish (so the
  common case frees cleanly), but a loader still blocked inside a network
  Connect/ListTools is abandoned to the OS (FreeOnTerminate) rather than
  hanging the app's exit -- its Terminated checks keep it from touching
  the registry/state after teardown begins.

  Refresh TTL: a tools/list cache younger than MCPRefreshTTLSeconds is
  reused as-is. The loader still connects (so tool calls work) but skips
  the expensive tools/list; only a stale/absent cache pays the full
  refresh. This is what keeps a quick start+exit cheap.
}
unit PasClaw.MCP.Bridge;

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
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.MCP.Types,
  PasClaw.MCP.StdioClient,
  PasClaw.MCP.HttpClient;

type
  TMCPClientList = array of TThread;

{ Connect every enabled MCP server from the config and register their tools
  into Reg. Cached tools become visible immediately; live connects happen
  in background threads. Returns the list of loader threads -- pass it back
  to FreeMCPClients to drain on shutdown. }
function ConnectMCPServers(Cfg: TConfig; Reg: TToolRegistry): TMCPClientList;
procedure FreeMCPClients(var Clients: TMCPClientList);

implementation

uses
  SyncObjs,
  PasClaw.Logger,
  PasClaw.MCP.Cache,
  PasClaw.MCP.Disclosure;

type
  TMCPLoadState = (lsLoading, lsReady, lsFailed);

  TMCPServerState = class;

  { One per registered MCP tool. Holds enough context for the registry
    to dispatch through HandlerObj without consulting any global table.
    Owned by its TMCPServerState. }
  TMCPToolDispatch = class
  private
    FState:    TMCPServerState;
    FToolName: string;
  public
    constructor Create(State: TMCPServerState; const ToolName: string);
    function Handler(const ArgsJSON: string; out ErrMsg: string): string;
  end;

  { Per-server shared state. One instance per MCP server entry; every
    tool dispatched for that server reads its live Client + State from
    here. Also owns the list of TMCPToolDispatch instances created on
    its behalf -- they outlive any single tools/list call so the
    registry's HandlerObj pointers stay valid for the process lifetime. }
  TMCPServerState = class
  private
    FLock:        TCriticalSection;
    FName:        string;
    FClient:      TMCPBaseClient;
    FState:      TMCPLoadState;
    FError:       string;
    FDispatchLock: TCriticalSection;  { guards FDispatches concurrent grow/scan }
    FDispatches:  TList;              { TList of TMCPToolDispatch -- owned }
  public
    constructor Create(const AName: string);
    destructor  Destroy; override;
    procedure SetReady(C: TMCPBaseClient);
    procedure SetFailed(const Err: string);
    function  CallTool(const ToolName, ArgsJSON: string;
                       out ErrMsg: string): string;
    function  FindDispatchFor(const ToolName: string): TMCPToolDispatch;
    function  AddDispatch(const ToolName: string): TMCPToolDispatch;
    property Name: string read FName;
  end;

  TMCPLoader = class(TThread)
  private
    FCfg:    TMCPServer;
    FDeferred: Boolean;   { snapshot of Cfg.MCPProgressiveDisclosure -- TMCPLoader
                            mirrors the flag at create time so the loader thread
                            doesn't have to hold a TConfig reference. }
    FReg:    TToolRegistry;
    FState:  TMCPServerState;
    FClient: TMCPBaseClient;
    FDone:   TEvent;   { signalled when Execute returns -- lets shutdown
                         bound its wait instead of a 30s-connect WaitFor }
    FRegLock: TCriticalSection;  { held across the registry mutation so
                                   shutdown can flush an in-progress
                                   registration before freeing FReg }
  protected
    procedure Execute; override;
  public
    constructor Create(const ServerCfg: TMCPServer; Reg: TToolRegistry;
                       State: TMCPServerState; Deferred: Boolean);
    destructor  Destroy; override;
    property DoneEvent: TEvent read FDone;
    { Block until the loader is not mid-registration. After this returns,
      with Terminated already set, the loader will not touch FReg again --
      so the caller can free the registry and abandon the thread safely. }
    procedure FlushPendingRegistration;
  end;

const
  { TTL for the live tools/list refresh. A cache younger than this is
    reused as-is (the loader still connects, so tool calls work, but skips
    the expensive tools/list -- Replicate returns thousands of tools). }
  MCPRefreshTTLSeconds = 12 * 60 * 60;

var
  GStates: TList;  { TList of TMCPServerState -- owned; freed in FreeMCPClients }

constructor TMCPServerState.Create(const AName: string);
begin
  inherited Create;
  FLock         := TCriticalSection.Create;
  FDispatchLock := TCriticalSection.Create;
  FDispatches   := TList.Create;
  FName   := AName;
  FClient := nil;
  FState  := lsLoading;
  FError  := '';
end;

destructor TMCPServerState.Destroy;
var
  i: Integer;
begin
  if FClient <> nil then begin FClient.Free; FClient := nil; end;
  for i := 0 to FDispatches.Count - 1 do
    TMCPToolDispatch(FDispatches[i]).Free;
  FDispatches.Free;
  FDispatchLock.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TMCPServerState.SetReady(C: TMCPBaseClient);
begin
  FLock.Acquire;
  try
    FClient := C;
    FState  := lsReady;
    FError  := '';
  finally
    FLock.Release;
  end;
end;

procedure TMCPServerState.SetFailed(const Err: string);
begin
  FLock.Acquire;
  try
    FState := lsFailed;
    FError := Err;
    { Keep FClient as-is -- if a prior connect had succeeded and the
      refresh subsequently failed, calls can still go through the old
      session until the next FreeMCPClients. The MCP HTTP client will
      surface its own error if the session has gone stale. }
  finally
    FLock.Release;
  end;
end;

function TMCPServerState.CallTool(const ToolName, ArgsJSON: string;
                                  out ErrMsg: string): string;
var
  C: TMCPBaseClient;
  S: TMCPLoadState;
  E: string;
  OK: Boolean;
begin
  Result := '';
  ErrMsg := '';
  FLock.Acquire;
  try
    C := FClient;
    S := FState;
    E := FError;
  finally
    FLock.Release;
  end;
  case S of
    lsLoading:
      begin
        ErrMsg := Format('mcp[%s] still connecting -- retry in a moment', [FName]);
        Exit;
      end;
    lsFailed:
      if C = nil then
      begin
        ErrMsg := Format('mcp[%s] unreachable: %s', [FName, E]);
        Exit;
      end;
    lsReady: ;
  end;
  if C = nil then
  begin
    ErrMsg := Format('mcp[%s] client missing (internal bridge bug)', [FName]);
    Exit;
  end;
  OK := C.CallTool(ToolName, ArgsJSON, Result, ErrMsg);
  if (not OK) and (ErrMsg = '') then ErrMsg := 'mcp call failed';
end;

function TMCPServerState.FindDispatchFor(const ToolName: string): TMCPToolDispatch;
var
  i: Integer;
begin
  Result := nil;
  FDispatchLock.Acquire;
  try
    for i := 0 to FDispatches.Count - 1 do
      if TMCPToolDispatch(FDispatches[i]).FToolName = ToolName then
        Exit(TMCPToolDispatch(FDispatches[i]));
  finally
    FDispatchLock.Release;
  end;
end;

function TMCPServerState.AddDispatch(const ToolName: string): TMCPToolDispatch;
begin
  Result := TMCPToolDispatch.Create(Self, ToolName);
  FDispatchLock.Acquire;
  try
    FDispatches.Add(Result);
  finally
    FDispatchLock.Release;
  end;
end;

constructor TMCPToolDispatch.Create(State: TMCPServerState; const ToolName: string);
begin
  inherited Create;
  FState    := State;
  FToolName := ToolName;
end;

function TMCPToolDispatch.Handler(const ArgsJSON: string;
                                   out ErrMsg: string): string;
begin
  Result := FState.CallTool(FToolName, ArgsJSON, ErrMsg);
end;

function IsHttpUrl(const S: string): Boolean;
begin
  Result := (Length(S) >= 7) and
            ((LowerCase(Copy(S, 1, 7)) = 'http://') or
             ((Length(S) >= 8) and (LowerCase(Copy(S, 1, 8)) = 'https://')));
end;

function NamespacedToolName(const Server, Tool: string): string;
begin
  Result := Server + '__' + Tool;
end;

procedure RegisterToolViaDispatch(Reg: TToolRegistry;
                                   const Server: string;
                                   const Tool: TMCPTool;
                                   Dispatch: TMCPToolDispatch;
                                   Deferred: Boolean);
var
  Entry: TTool;
begin
  Entry.Name        := NamespacedToolName(Server, Tool.Name);
  Entry.Description := '[mcp:' + Server + '] ' + Tool.Description;
  Entry.Schema      := Tool.Schema;
  { Object-method dispatch -- no static slot indirection, no MaxBindings
    cap. The registry zeros Handler when HandlerObj is set elsewhere;
    here we point Handler at nil and rely on RunTool's "if Assigned
    HandlerObj" branch. }
  Entry.Handler     := nil;
  Entry.HandlerObj  := Dispatch.Handler;
  Entry.IsCore      := False;
  { IsDeferred drives progressive disclosure (Cfg.MCPProgressiveDisclosure):
    the dispatcher still resolves the tool, but ToProviderDefs strips it
    from the per-request `tools` array until tool_search reveals the
    name. The two-layer boot (cache then live connect) re-registers the
    same name -- IsDeferred is set from the same Cfg field both times,
    so a tool revealed mid-session stays revealed (the registry's
    FRevealed set is keyed on name, not on TTool identity). }
  Entry.IsDeferred  := Deferred;
  Reg.Register(Entry);
end;

{ ============================================================
  TMCPLoader -- one per MCP server, runs Connect+ListTools async.
  ============================================================ }

constructor TMCPLoader.Create(const ServerCfg: TMCPServer; Reg: TToolRegistry;
                              State: TMCPServerState; Deferred: Boolean);
begin
  inherited Create({CreateSuspended=}True);
  FreeOnTerminate := False;
  FCfg    := ServerCfg;
  FDeferred := Deferred;
  FReg    := Reg;
  FState  := State;
  FClient := nil;
  FDone   := TEvent.Create(nil, {ManualReset=}True, {InitialState=}False, '');
  FRegLock := TCriticalSection.Create;
end;

procedure TMCPLoader.FlushPendingRegistration;
begin
  FRegLock.Acquire;
  FRegLock.Release;
end;

destructor TMCPLoader.Destroy;
begin
  { Execute either transferred FClient to FState (and nulled FClient
    here) or failed before reaching that point -- in which case the
    client is still ours to free. }
  if FClient <> nil then begin FClient.Free; FClient := nil; end;
  FDone.Free;
  FRegLock.Free;
  inherited Destroy;
end;

{$IFDEF MSWINDOWS}
{ ole32 imports -- declared locally instead of pulling in Windows /
  Winapi.ActiveX so the bridge stays cross-compiler-friendly. WinHTTP
  (which System.Net.HttpClient uses under PASCLAW_NETHTTP) needs COM
  initialised on any thread that issues a request -- without it the
  WinHTTP proxy/cert/cred plumbing can't talk to the OS providers and
  every request fails with WINHTTP_NAME_NOT_RESOLVED (12007) even
  though main-thread requests against the same host succeed fine.
  Indy on FPC doesn't care, but the call is cheap and consistent. }
const
  COINIT_MULTITHREADED = $0;
function CoInitializeEx(pvReserved: Pointer; dwCoInit: LongWord): Integer; stdcall;
  external 'ole32.dll' name 'CoInitializeEx';
procedure CoUninitialize; stdcall;
  external 'ole32.dll' name 'CoUninitialize';
{$ENDIF}

procedure TMCPLoader.Execute;
var
  Tools: TMCPToolArray;
  Err: string;
  Dispatch: TMCPToolDispatch;
  i: Integer;
  Age: Int64;
begin
  try
  {$IFDEF MSWINDOWS}
  CoInitializeEx(nil, COINIT_MULTITHREADED);
  try
  {$ENDIF}
  try
    if IsHttpUrl(FCfg.Cmd) then
      FClient := TMCPHttpClient.Create(FCfg.Name, FCfg.Cmd, FCfg.Args)
    else
      FClient := TMCPStdioClient.Create(FCfg.Name, FCfg.Cmd, FCfg.Args);
    if Terminated then Exit;
    if not FClient.Connect(30 * 1000, Err) then
    begin
      LogWarn('mcp[%s] connect failed: %s', [FCfg.Name, Err]);
      FState.SetFailed(Err);
      Exit;
    end;
    if Terminated then Exit;

    { TTL gate: a cache younger than MCPRefreshTTLSeconds is still good.
      Connect above established the live session so tool calls work --
      reuse the tools we already registered at startup and skip the
      expensive tools/list (Replicate's catalog is thousands of tools). }
    Age := CacheAgeSeconds(FCfg.Name);
    if (Age >= 0) and (Age < MCPRefreshTTLSeconds) then
    begin
      LogInfo('mcp[%s] cache fresh (%ds old < %ds TTL) -- reusing cached tools, skipping live tools/list',
              [FCfg.Name, Age, Int64(MCPRefreshTTLSeconds)]);
      FState.SetReady(FClient);
      FClient := nil;
      Exit;
    end;

    if not FClient.ListTools(Tools, Err) then
    begin
      LogWarn('mcp[%s] tools/list failed: %s', [FCfg.Name, Err]);
      FState.SetFailed(Err);
      Exit;
    end;
    LogInfo('mcp[%s] live connect OK (%d tools)', [FCfg.Name, Length(Tools)]);
    SaveCachedTools(FCfg.Name, Tools);
    { Cheap early-out before taking the lock -- the cache is already saved. }
    if Terminated then Exit;

    { Registry mutation is the one shutdown-sensitive step: it writes FReg,
      which the caller frees right after FreeMCPClients returns. Hold
      FRegLock across the whole re-register + SetReady so a concurrent
      shutdown's FlushPendingRegistration blocks until we finish (bounded
      by registration time -- CPU only, no network), then re-check
      Terminated INSIDE the lock: if shutdown began before we acquired it,
      skip touching FReg entirely. Together with FreeMCPClients setting
      Terminated before the flush, this guarantees an abandoned loader
      never writes a freed registry. }
    FRegLock.Acquire;
    try
      if Terminated then Exit;

      { Always re-register every live tool. Reuse the existing
        dispatch object (created in the cache pass) when one is
        present so HandlerObj pointer stability holds -- only the
        description and schema on the TTool entry change. Skipping
        re-registration when a cached entry exists would leave the
        registry stuck on yesterday's (possibly stale) description
        and inputSchema while the model continued to dispatch via
        the (live, working) dispatch object. Codex P2 on PR #141.
        FindDispatchFor + Register are both O(N); for several
        thousand tools that's an O(N²) one-time cost in the loader
        thread -- acceptable, but if it ever becomes noticeable
        promote FDispatches to a sorted TStringList. }
      for i := 0 to High(Tools) do
      begin
        Dispatch := FState.FindDispatchFor(Tools[i].Name);
        if Dispatch = nil then
          Dispatch := FState.AddDispatch(Tools[i].Name);
        RegisterToolViaDispatch(FReg, FCfg.Name, Tools[i], Dispatch, FDeferred);
      end;

      FState.SetReady(FClient);
      { Ownership transferred to FState; clear ours so Destroy doesn't
        double-free. }
      FClient := nil;
    finally
      FRegLock.Release;
    end;
  except
    on E: Exception do
    begin
      LogWarn('mcp[%s] loader crashed: %s', [FCfg.Name, E.Message]);
      FState.SetFailed(E.Message);
    end;
  end;
  {$IFDEF MSWINDOWS}
  finally
    CoUninitialize;
  end;
  {$ENDIF}
  finally
    { Always signal completion so a bounded shutdown wait can proceed. }
    FDone.SetEvent;
  end;
end;

{ ============================================================
  Boot path.
  ============================================================ }

function ConnectMCPServers(Cfg: TConfig; Reg: TToolRegistry): TMCPClientList;
var
  i, j: Integer;
  CachedTools: TMCPToolArray;
  Loader: TMCPLoader;
  State: TMCPServerState;
  Dispatch: TMCPToolDispatch;
  CachedCount, CachedRegistered: Integer;
begin
  SetLength(Result, 0);
  CachedRegistered := 0;
  for i := 0 to High(Cfg.MCPServers) do
  begin
    if not Cfg.MCPServers[i].Enabled then Continue;

    State := TMCPServerState.Create(Cfg.MCPServers[i].Name);
    GStates.Add(State);

    { Cache pass: register cached tools with the state in lsLoading. }
    CachedCount := 0;
    if LoadCachedTools(Cfg.MCPServers[i].Name, CachedTools) then
    begin
      for j := 0 to High(CachedTools) do
      begin
        Dispatch := State.AddDispatch(CachedTools[j].Name);
        RegisterToolViaDispatch(Reg, Cfg.MCPServers[i].Name,
                                CachedTools[j], Dispatch,
                                Cfg.MCPProgressiveDisclosure);
        Inc(CachedCount);
      end;
      if CachedCount > 0 then
        LogInfo('mcp[%s] cache hit: %d tool(s) registered (connecting in background)',
                [Cfg.MCPServers[i].Name, CachedCount]);
      Inc(CachedRegistered, CachedCount);
    end;

    Loader := TMCPLoader.Create(Cfg.MCPServers[i], Reg, State,
                                 Cfg.MCPProgressiveDisclosure);
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Loader;
    Loader.Start;
  end;
  if CachedRegistered > 0 then
    LogDebug('mcp: %d cached tool(s) registered across %d server(s); waiting on background refresh',
             [CachedRegistered, Length(Result)]);

  { Register tool_search whenever progressive disclosure is on. The
    discovery tool is the only path the model has to load schemas
    for the deferred MCP tools registered above. No-op when
    Cfg.MCPProgressiveDisclosure is False; safe even when zero MCP
    servers are configured (reports "No deferred tools" on every
    call). One registration point so every caller -- Cmd.Agent,
    Cmd.Serve, Cmd.Gateway, Cmd.TUI, the long-running TAgent -- gets
    it for free. }
  RegisterMCPDisclosureTools(Reg, Cfg);
end;

procedure FreeMCPClients(var Clients: TMCPClientList);
const
  { Per-loader budget. A finished or fresh-cache loader signals DoneEvent
    almost immediately; only one still blocked in a network call waits the
    full budget before being abandoned. Bounds exit instead of a 30s
    connect WaitFor. }
  ShutdownWaitMs = 1000;
var
  i: Integer;
  Loader: TMCPLoader;
  Abandoned: Boolean;
begin
  Abandoned := False;
  for i := 0 to High(Clients) do
    if Clients[i] <> nil then
    begin
      Loader := TMCPLoader(Clients[i]);
      { Order matters: set Terminated, THEN flush. After the flush returns,
        any registration that was in flight has finished and -- because
        Terminated is now set and the registration block re-checks it under
        FRegLock -- the loader will never write FReg again. Only then is it
        safe for the abandon branch to let the caller free the registry.
        The flush blocks at most for a registration pass (CPU only); it
        never waits on the network. }
      Loader.Terminate;
      Loader.FlushPendingRegistration;
      if Loader.DoneEvent.WaitFor(ShutdownWaitMs) = wrSignaled then
      begin
        Loader.WaitFor;
        Loader.Free;
      end
      else
      begin
        { Still blocked in a network call (Connect/ListTools -- neither
          touches FReg). Don't hang the app on exit: hand the thread to the
          OS (FreeOnTerminate) and abandon it. The flush above + the
          Terminated re-check guarantee it can't write the about-to-be-freed
          registry; it self-frees when the call returns. }
        Loader.FreeOnTerminate := True;
        Abandoned := True;
      end;
    end;
  SetLength(Clients, 0);

  { Server states (and their owned dispatch objects + clients) are
    referenced from the registry via HandlerObj pointers; freeing them
    here invalidates those entries, but the caller is tearing the whole
    agent down so the registry is going too.

    When a loader was abandoned, skip this: that loader still references
    its TMCPServerState, so freeing it would risk a use-after-free. The
    process is exiting, so the leak is reclaimed by the OS momentarily. }
  if not Abandoned then
  begin
    for i := 0 to GStates.Count - 1 do
      TMCPServerState(GStates[i]).Free;
    GStates.Clear;
  end;
end;

initialization
  GStates := TList.Create;

finalization
  GStates.Free;

end.
