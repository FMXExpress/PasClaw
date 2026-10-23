(*
  PasClaw.Tools.RPC -- in-process JSON-line RPC server that lets a
  spawned execute_code script call back into PasClaw's tool registry.

  The picoclaw design point we deferred: when the model writes a
  multi-line bash/PowerShell script, the script can shell out to
  `pasclaw __tool memory_search '{"q":"foo"}'` and the call is
  served by the SAME tool registry the agent loop is using -- with
  the same sandbox / output-cache / stats wiring around it. One
  script turns N tool-call rounds into 1. The killer use case is
  "list every *.pas under src/, grep each for symbol X, build a
  CSV" -- previously: 1 + N + 1 loop iterations. Now: one
  execute_code call whose body shells out to fs_list / fs_grep /
  fs_read as many times as it likes, all without re-entering the
  LLM.

  Lifetime is PER-CALL, not process-wide. Codex P1 + P2 on PR #206
  caught two bugs in the original singleton design:

    - P1: subagent's filtered registry never re-registered into
      the singleton, so a subagent's execute_code script could RPC
      its way into the PARENT's full tool surface and bypass the
      subagent's allowlist.
    - P2: two PasClaw processes sharing a $PASCLAW_HOME wrote into
      the same fixed info file path, so process A's running script
      would read process B's port and cross-dispatch into B's
      registry.

  Per-call isolation kills both:

    Tool_ExecuteCode for each call:
      Server := TToolRPCServer.Create(MyRegistry, UniquePath);
      Server.Start;
      env:PASCLAW_TOOL_RPC_INFO = UniquePath
      spawn the script (env inherited)
      script's `pasclaw __tool` reads $PASCLAW_TOOL_RPC_INFO
      ...script runs, may make 0..N RPC calls...
      Server.Stop;   { deletes the info file }
      Server.Free;

  Concurrency: a parent loop and a subagent loop can BOTH be
  inside Tool_ExecuteCode at the same time. Each creates its own
  server bound to its own registry, on its own kernel-allocated
  port, with its own info file. The env var passed to each
  spawned script disambiguates. No global state, no race.

  Wire shape (unchanged from v1):
    Request:  {"token":"...", "name":"...", "args":{...}}\n
              {"token":"...", "catalog":"<server or empty>"}\n
    Response: {"result":"...", "err":"..."}\n
    One request per connection. With a dispatcher bound (the
    production path) a request goes through the loop's dispatch
    gates and the OutputCache cap, same as the model-facing path.

  Auth: every request must carry the per-server random token.
  Bad token -> {"err":"invalid token"} and close.
*)
unit PasClaw.Tools.RPC;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  IdTCPServer, IdContext, IdGlobal, IdSocketHandle,
  PasClaw.Tools.Registry;

type
  TToolRPCServer = class
  private
    FServer:   TIdTCPServer;
    FRegistry: TToolRegistry;
    FDispatcher: IToolDispatcher;   { when set, every request goes through it }
    FToken:    string;
    FPort:     Integer;
    FInfoPath: string;
    FBindIP:   string;
    FAdvertiseHost: string;
    FLock:     TCriticalSection;
    procedure OnExecute(Ctx: TIdContext);
    procedure WriteInfoFile;
    procedure DeleteInfoFile;
  public
    (* Bind this RPC server to Registry. The server dispatches every
       authenticated request through Registry.RunTool -- whatever
       tool set the registry carries IS the tool set the RPC sees.
       Caller is responsible for keeping Registry alive for the
       lifetime of the server.

       InfoPath is where the {port, token, pid} discovery file
       gets written so the spawned script's `pasclaw __tool`
       command can find this server. Callers building a per-call
       server should pick a unique path so two concurrent
       Tool_ExecuteCode invocations don't trample each other. *)
    constructor Create(Registry: TToolRegistry; const InfoPath: string;
                       Dispatcher: IToolDispatcher = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Token: string read FToken;
    property Port:  Integer read FPort;
    property InfoPath: string read FInfoPath;

    (* Set these BEFORE Start when the script will run somewhere that
       cannot reach the host's loopback -- the Docker shell backend reads
       them off its IShellHostRPC implementation.

       BindIP replaces 127.0.0.1 as the listening address. An address that
       cannot be bound is NOT fatal: Start logs it and falls back to
       loopback, which is what makes the Docker Desktop case work by
       itself (the bridge gateway it names lives in the daemon's VM, not
       on this host, and host.docker.internal there already forwards to
       the host's loopback).

       AdvertiseHost is what goes in the discovery file as the host to
       dial. Empty means 127.0.0.1, so a local-backend server writes the
       same file it always did. *)
    property BindIP: string read FBindIP write FBindIP;
    property AdvertiseHost: string read FAdvertiseHost write FAdvertiseHost;
  end;

(* Compose a per-call info-file path under $PASCLAW_HOME/run/
   that's unique to this caller + a random suffix. Used by
   Tool_ExecuteCode to pick a path it can hand to the spawned
   script via the PASCLAW_TOOL_RPC_INFO env var without colliding
   with any other concurrent execute_code call. *)
function MakePerCallInfoPath: string;

(* Read the discovery file the spawned script uses to find the
   parent PasClaw process's RPC server. The path comes from the
   PASCLAW_TOOL_RPC_INFO env var the parent set before spawning
   the script. Returns False with a precise ErrMsg when:
     - the env var is missing (script wasn't spawned by
       Tool_ExecuteCode, or env didn't propagate)
     - the file doesn't exist (parent crashed mid-call?)
     - the file is malformed
   Used by Cmd.ToolRPC (`pasclaw __tool`). Host is the address to
   dial: the file's "host" field when the parent advertised one (the
   Docker backend does), 127.0.0.1 otherwise. *)
function DiscoverRunningRPC(out Port: Integer;
                            out Token, Host, ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Crypto.Random
  {$IFNDEF FPC}{$IFDEF MSWINDOWS}, Winapi.Windows{$ENDIF}
                {$IFDEF POSIX}, Posix.Unistd{$ENDIF}{$ENDIF};

const
  EnvInfoVar   = 'PASCLAW_TOOL_RPC_INFO';
  LoopbackHost = '127.0.0.1';

function CurrentProcessID: Int64;
{ Cross-compiler PID lookup. FPC ships SysUtils.GetProcessID;
  Delphi dcc64 doesn't (E2003 on that name) and routes through
  the platform RTL instead -- Winapi.Windows.GetCurrentProcessId
  on Windows, Posix.Unistd.getpid on POSIX. Wrapped so the two
  callers below don't have to repeat the IFDEF dance. }
begin
  {$IFDEF FPC}
  Result := GetProcessID;
  {$ELSE}{$IFDEF MSWINDOWS}
  Result := GetCurrentProcessId;
  {$ELSE}
  Result := getpid;
  {$ENDIF}{$ENDIF}
end;

function RandomHexToken(NBytes: Integer): string;
var
  B: TBytes;
  i: Integer;
const
  HexChars: array[0..15] of Char =
    ('0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f');
begin
  B := GetRandomBytes(NBytes);
  SetLength(Result, NBytes * 2);
  for i := 0 to NBytes - 1 do
  begin
    Result[(i * 2) + 1] := HexChars[(B[i] shr 4) and $0F];
    Result[(i * 2) + 2] := HexChars[B[i] and $0F];
  end;
end;

function MakePerCallInfoPath: string;
{ Per-call uniqueness: PID + random suffix. Parent and subagent
  share a PID so the PID alone isn't enough; the random suffix
  makes parallel calls within the same process unambiguous too. }
begin
  Result := JoinPath(JoinPath(GetHome, 'run'),
                     Format('tool-rpc-%d-%s.json',
                            [CurrentProcessID, RandomHexToken(4)]));
end;

constructor TToolRPCServer.Create(Registry: TToolRegistry; const InfoPath: string;
                                  Dispatcher: IToolDispatcher);
begin
  inherited Create;
  FLock     := TCriticalSection.Create;
  FRegistry := Registry;
  { The gated path. Tool_ExecuteCode captures it from the loop on the
    dispatching thread and hands it here, so a script's call is refused in
    plan mode, seen by hooks, scanned and capped exactly like a direct
    call. nil keeps the registry-only path for harnesses without a loop. }
  FDispatcher := Dispatcher;
  FInfoPath := InfoPath;
  FServer   := TIdTCPServer.Create(nil);
  FServer.OnExecute := OnExecute;
end;

destructor TToolRPCServer.Destroy;
begin
  Stop;
  FServer.Free;
  FLock.Free;
  inherited Destroy;
end;

function IsPlainHostToken(const S: string): Boolean;
{ A hostname or IP literal and nothing else. The advertised host is
  interpolated into the JSON discovery file by hand (Format, not a
  TJsonObject), so a quote or backslash in it would corrupt the file the
  callback has to parse. Nothing in-tree can produce one -- the Docker
  backend passes a constant or an address it read from `docker network
  inspect` -- but the file is the contract between two processes, so the
  check belongs on the writing side. }
var
  i: Integer;
  C: Char;
begin
  Result := S <> '';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if not (((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
            ((C >= '0') and (C <= '9')) or (C = '.') or (C = ':') or
            (C = '-') or (C = '_')) then
      Exit(False);
  end;
end;

procedure TToolRPCServer.WriteInfoFile;
var
  Sl: TStringList;
begin
  if not DirectoryExists(ExtractFilePath(FInfoPath)) then
    ForceDirectories(ExtractFilePath(FInfoPath));
  Sl := TStringList.Create;
  try
    { "host" only when it isn't loopback -- an unchanged file on every
      local-backend run, and the field the container-side `pasclaw
      __tool` dials instead of its own 127.0.0.1. }
    if (FAdvertiseHost <> LoopbackHost) and IsPlainHostToken(FAdvertiseHost) then
      Sl.Add(Format('{"port":%d,"token":"%s","pid":%d,"host":"%s"}',
                    [FPort, FToken, CurrentProcessID, FAdvertiseHost]))
    else
    begin
      if (FAdvertiseHost <> '') and (FAdvertiseHost <> LoopbackHost) then
        LogWarn('tool-rpc: ignoring unusable callback host "%s" -- ' +
                'scripts will dial %s', [FAdvertiseHost, LoopbackHost]);
      Sl.Add(Format('{"port":%d,"token":"%s","pid":%d}',
                    [FPort, FToken, CurrentProcessID]));
    end;
    WriteFileText(FInfoPath, Sl.Text);   { UTF-8 on both arms -- see docs/utf8-file-io }
  finally
    Sl.Free;
  end;
end;

procedure TToolRPCServer.DeleteInfoFile;
begin
  { SysUtils-qualified on purpose. PR #207 added Winapi.Windows to
    this unit's uses clause (for GetCurrentProcessId), and Delphi's
    later-unit-wins resolution then bound the bare DeleteFile to
    Winapi.Windows.DeleteFile(PWideChar) -- dcc64 E2010 on the
    string argument. FPC was unaffected (no Winapi.Windows in its
    branch of the uses clause) but the qualification is harmless
    there. }
  if FileExists(FInfoPath) then SysUtils.DeleteFile(FInfoPath);
end;

procedure TToolRPCServer.Start;
var
  IP: string;

  procedure BindOn(const Addr: string);
  var
    Bind: TIdSocketHandle;
  begin
    FServer.Bindings.Clear;
    Bind := FServer.Bindings.Add;
    Bind.IP   := Addr;
    Bind.Port := 0;   { kernel-allocated: one port per call, no collisions }
    FServer.Active := True;
  end;

begin
  FLock.Enter;
  try
    if FServer.Active then Exit;
    FToken := RandomHexToken(16);
    IP := FBindIP;
    if IP = '' then IP := LoopbackHost;
    try
      BindOn(IP);
    except
      on E: Exception do
      begin
        { A caller-supplied address that this host doesn't own is the
          expected Docker Desktop shape: the backend names the daemon's
          bridge gateway, which lives in Desktop's VM, and loopback is
          what host.docker.internal forwards to there. Fall back instead
          of failing the whole execute_code call. A loopback bind that
          fails is a real problem -- re-raise. }
        if IP = LoopbackHost then
        begin
          LogWarn('tool-rpc: bind failed: %s', [E.Message]);
          raise;
        end;
        LogDebug('tool-rpc: cannot listen on %s (%s) -- falling back to %s',
                 [IP, E.Message, LoopbackHost]);
        try FServer.Active := False; except end;   { roll back a half-open listener }
        IP := LoopbackHost;
        BindOn(IP);
      end;
    end;
    FPort := FServer.Bindings[0].Port;
    WriteInfoFile;
    LogDebug('tool-rpc: listening on %s:%d (info=%s)',
             [IP, FPort, FInfoPath]);
  finally
    FLock.Leave;
  end;
end;

procedure TToolRPCServer.Stop;
begin
  FLock.Enter;
  try
    if FServer.Active then
    begin
      try
        FServer.Active := False;
      except
        on E: Exception do
          LogWarn('tool-rpc: stop raised: %s', [E.Message]);
      end;
      DeleteInfoFile;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TToolRPCServer.OnExecute(Ctx: TIdContext);
{ One request / one response. Connection closes after. }
var
  Line, Name, ArgsJSON, ResultText, ErrMsg, ReqToken, CatalogServer: string;
  ReqObj, ArgsObj, RespObj: TJsonObject;
  Reg: TToolRegistry;
  CatalogReq: Boolean;
begin
  CatalogReq := False;
  CatalogServer := '';
  try
    Line := Ctx.Connection.IOHandler.ReadLn;
  except
    on E: Exception do
    begin
      LogDebug('tool-rpc: read failed (client closed?): %s', [E.Message]);
      Exit;
    end;
  end;
  if Trim(Line) = '' then Exit;

  Name     := '';
  ArgsJSON := '';
  ReqToken := '';
  try
    ReqObj := TJsonObject.Parse(Line);
  except
    ReqObj := nil;
  end;
  if ReqObj = nil then
  begin
    Ctx.Connection.IOHandler.WriteLn('{"err":"invalid JSON request"}');
    Exit;
  end;
  try
    ReqToken := ReqObj.GetStr('token', '');
    Name     := ReqObj.GetStr('name',  '');
    CatalogReq := ReqObj.Has('catalog');
    CatalogServer := ReqObj.GetStr('catalog', '');
    ArgsObj  := ReqObj.ChildObject('args');
    if ArgsObj <> nil then
    try
      ArgsJSON := ArgsObj.ToJSON;
    finally
      ArgsObj.Free;
    end;
  finally
    ReqObj.Free;
  end;

  if ReqToken <> FToken then
  begin
    Ctx.Connection.IOHandler.WriteLn('{"err":"invalid token"}');
    Exit;
  end;
  (* Catalog verb -- a request carrying "catalog" (a server name, or
     empty for all) instead of "name": the code-mode tools as JSON, read
     straight from the bound registry. Nothing runs. *)
  if CatalogReq then
  begin
    FLock.Enter;
    try
      Reg := FRegistry;
    finally
      FLock.Leave;
    end;
    RespObj := TJsonObject.Create;
    try
      if Reg = nil then RespObj.PutStr('err', 'no registry bound')
      else
      begin
        RespObj.PutStr('result', Reg.CodeModeCatalog(CatalogServer));
        RespObj.PutStr('err', '');
      end;
      Ctx.Connection.IOHandler.WriteLn(RespObj.ToJSON);
    finally
      RespObj.Free;
    end;
    Exit;
  end;
  if Name = '' then
  begin
    Ctx.Connection.IOHandler.WriteLn('{"err":"missing tool name"}');
    Exit;
  end;

  FLock.Enter;
  try
    Reg := FRegistry;
  finally
    FLock.Leave;
  end;
  if Reg = nil then
  begin
    Ctx.Connection.IOHandler.WriteLn('{"err":"no registry bound"}');
    Exit;
  end;

  if FDispatcher <> nil then
    ResultText := FDispatcher.Dispatch(Name, ArgsJSON, ErrMsg)
  else
    ResultText := Reg.RunTool(Name, ArgsJSON, ErrMsg);
  RespObj := TJsonObject.Create;
  try
    RespObj.PutStr('result', ResultText);
    RespObj.PutStr('err',    ErrMsg);
    Ctx.Connection.IOHandler.WriteLn(RespObj.ToJSON);
  finally
    RespObj.Free;
  end;
end;

function DiscoverRunningRPC(out Port: Integer;
                            out Token, Host, ErrMsg: string): Boolean;
var
  Sl: TStringList;
  Obj: TJsonObject;
  Path: string;
begin
  Result := False;
  Port   := 0;
  Token  := '';
  Host   := LoopbackHost;
  ErrMsg := '';
  Path := GetEnvironmentVariable(EnvInfoVar);
  if Path = '' then
  begin
    ErrMsg := 'no ' + EnvInfoVar +
              ' env var -- this command is meant to run from inside an ' +
              'execute_code script, not standalone';
    Exit;
  end;
  if not FileExists(Path) then
  begin
    ErrMsg := 'tool-rpc info file at ' + Path +
              ' is missing -- the parent execute_code may have already exited';
    Exit;
  end;
  Sl := TStringList.Create;
  try
    try
      Sl.Text := ReadFileText(Path);
    except
      on E: Exception do
      begin
        ErrMsg := 'failed reading info file: ' + E.Message;
        Exit;
      end;
    end;
    try
      Obj := TJsonObject.Parse(Sl.Text);
    except
      Obj := nil;
    end;
    if Obj = nil then
    begin
      ErrMsg := 'info file is not valid JSON';
      Exit;
    end;
    try
      Port  := Obj.GetInt('port',  0);
      Token := Obj.GetStr('token', '');
      { Absent on a local-backend server, which only ever listens on
        loopback -- and on an info file written by an older build. }
      Host  := Trim(Obj.GetStr('host', ''));
      if Host = '' then Host := LoopbackHost;
    finally
      Obj.Free;
    end;
  finally
    Sl.Free;
  end;
  if (Port <= 0) or (Token = '') then
  begin
    ErrMsg := 'info file missing port or token';
    Exit;
  end;
  Result := True;
end;

end.
