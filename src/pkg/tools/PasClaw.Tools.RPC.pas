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

  Wire shape:

    Discovery: when the RPC server starts it writes
      $PASCLAW_HOME/run/tool-rpc.json  containing
      {"port": <int>, "token": "<32-hex>"}
      Stale files left by a previous PasClaw process get
      overwritten -- they only matter if someone else stole the
      port number in the meantime, in which case the token check
      below catches them.

    Auth: every request must carry the token from the discovery
    file. Process-local files are good enough for a personal-agent
    home directory; cross-user attacks aren't in scope.

    Protocol:
      Client sends:    {"token":"...", "name":"...", "args":{...}}\n
      Server replies:  {"result":"...stringified...", "err":"..."}\n
      One request, one response, connection closes. No streaming;
      tools that return huge outputs route through the existing
      OutputCache same as the model-facing path.

  Concurrency: TIdTCPServer spawns a thread per connection.
  TToolRegistry.RunTool is internally locked, so concurrent RPC
  requests don't race.

  Lifecycle: started lazily on first execute_code call (per
  process), torn down by finalization. Cheap to keep alive across
  calls -- one socket, no resource cost when idle.
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
    FToken:    string;
    FPort:     Integer;
    FInfoPath: string;
    FLock:     TCriticalSection;
    procedure OnExecute(Ctx: TIdContext);
    procedure WriteInfoFile;
    procedure DeleteInfoFile;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Start(Registry: TToolRegistry);
    procedure Stop;
    property Token: string read FToken;
    property Port:  Integer read FPort;
    property InfoPath: string read FInfoPath;
  end;

(* Start the process-wide singleton RPC server if it isn't running
   yet. Subsequent calls with a different registry rebind the
   server to the new one -- the gateway / serve / agent loops
   should each plug in their own registry on startup. Safe to
   call from any thread; idempotent. *)
procedure StartToolRPCIfNeeded(Registry: TToolRegistry);

(* Stop the singleton if it's running. Called from unit
   finalization; callers don't normally invoke this directly. *)
procedure StopToolRPC;

(* Discover the running server's connection info by reading the
   info file. Used by Cmd.ToolRPC (`pasclaw __tool`) to find the
   parent PasClaw process's RPC port + token. Returns False with
   ErrMsg populated when no running server is discoverable. *)
function DiscoverRunningRPC(out Port: Integer; out Token, ErrMsg: string): Boolean;

(* The info file path for the running RPC server. Exposed so the
   `pasclaw __tool` subcommand can read it without duplicating
   the path-derivation logic. *)
function ToolRPCInfoPath: string;

implementation

uses
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Crypto.Random;

function RandomHexToken(NBytes: Integer): string;
{ Hex-encoded random bytes from PasClaw.Crypto.Random's OS-CSPRNG.
  We need a token the model's script can pass back over an HTTP-
  shaped wire; hex is the cheapest "safe" encoding for that. }
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

var
  GServer:     TToolRPCServer = nil;
  GServerLock: TCriticalSection = nil;

function ToolRPCInfoPath: string;
begin
  Result := JoinPath(JoinPath(GetHome, 'run'), 'tool-rpc.json');
end;

constructor TToolRPCServer.Create;
begin
  inherited Create;
  FLock     := TCriticalSection.Create;
  FServer   := TIdTCPServer.Create(nil);
  FServer.OnExecute := OnExecute;
  FInfoPath := ToolRPCInfoPath;
end;

destructor TToolRPCServer.Destroy;
begin
  Stop;
  FServer.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TToolRPCServer.WriteInfoFile;
var
  Sl: TStringList;
begin
  if not DirectoryExists(ExtractFilePath(FInfoPath)) then
    ForceDirectories(ExtractFilePath(FInfoPath));
  Sl := TStringList.Create;
  try
    Sl.Add(Format('{"port":%d,"token":"%s","pid":%d}',
                  [FPort, FToken, GetProcessID]));
    Sl.SaveToFile(FInfoPath);
  finally
    Sl.Free;
  end;
end;

procedure TToolRPCServer.DeleteInfoFile;
begin
  if FileExists(FInfoPath) then DeleteFile(FInfoPath);
end;

procedure TToolRPCServer.Start(Registry: TToolRegistry);
var
  Bind: TIdSocketHandle;
begin
  FLock.Enter;
  try
    FRegistry := Registry;
    if FServer.Active then Exit;
    FToken := RandomHexToken(16);   { 32 hex chars }
    FServer.Bindings.Clear;
    Bind := FServer.Bindings.Add;
    Bind.IP   := '127.0.0.1';
    Bind.Port := 0;  { let the kernel pick }
    try
      FServer.Active := True;
    except
      on E: Exception do
      begin
        LogWarn('tool-rpc: bind failed: %s', [E.Message]);
        raise;
      end;
    end;
    { Pick up the actual port the kernel assigned. }
    FPort := FServer.Bindings[0].Port;
    WriteInfoFile;
    LogDebug('tool-rpc: listening on 127.0.0.1:%d', [FPort]);
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
  Line, Name, ArgsJSON, ResultText, ErrMsg, ReqToken: string;
  ReqObj, ArgsObj, RespObj: TJsonObject;
  Reg: TToolRegistry;
begin
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

procedure StartToolRPCIfNeeded(Registry: TToolRegistry);
begin
  if Registry = nil then Exit;
  GServerLock.Enter;
  try
    if GServer = nil then GServer := TToolRPCServer.Create;
    GServer.Start(Registry);
  finally
    GServerLock.Leave;
  end;
end;

procedure StopToolRPC;
begin
  if GServerLock = nil then Exit;
  GServerLock.Enter;
  try
    if GServer <> nil then
    begin
      GServer.Free;
      GServer := nil;
    end;
  finally
    GServerLock.Leave;
  end;
end;

function DiscoverRunningRPC(out Port: Integer; out Token, ErrMsg: string): Boolean;
{ Read the info file written by the parent pasclaw process. The
  `pasclaw __tool` subcommand uses this to find where to connect.
  Returns False with a precise ErrMsg so the model gets actionable
  feedback when execute_code is being driven outside of a tool
  loop (e.g. a test rig that doesn't start the server). }
var
  Sl: TStringList;
  Obj: TJsonObject;
  Path: string;
begin
  Result := False;
  Port   := 0;
  Token  := '';
  ErrMsg := '';
  Path := ToolRPCInfoPath;
  if not FileExists(Path) then
  begin
    ErrMsg := 'no tool-rpc info file at ' + Path + ' -- is pasclaw running?';
    Exit;
  end;
  Sl := TStringList.Create;
  try
    try
      Sl.LoadFromFile(Path);
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

initialization
  GServerLock := TCriticalSection.Create;

finalization
  StopToolRPC;
  if GServerLock <> nil then GServerLock.Free;

end.
