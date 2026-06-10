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
    Response: {"result":"...", "err":"..."}\n
    One request per connection. Tools that return huge outputs
    route through the existing OutputCache same as the model-
    facing path.

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
    FToken:    string;
    FPort:     Integer;
    FInfoPath: string;
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
    constructor Create(Registry: TToolRegistry; const InfoPath: string);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    property Token: string read FToken;
    property Port:  Integer read FPort;
    property InfoPath: string read FInfoPath;
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
   Used by Cmd.ToolRPC (`pasclaw __tool`). *)
function DiscoverRunningRPC(out Port: Integer; out Token, ErrMsg: string): Boolean;

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
  EnvInfoVar = 'PASCLAW_TOOL_RPC_INFO';

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

constructor TToolRPCServer.Create(Registry: TToolRegistry; const InfoPath: string);
begin
  inherited Create;
  FLock     := TCriticalSection.Create;
  FRegistry := Registry;
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

procedure TToolRPCServer.WriteInfoFile;
var
  Sl: TStringList;
begin
  if not DirectoryExists(ExtractFilePath(FInfoPath)) then
    ForceDirectories(ExtractFilePath(FInfoPath));
  Sl := TStringList.Create;
  try
    Sl.Add(Format('{"port":%d,"token":"%s","pid":%d}',
                  [FPort, FToken, CurrentProcessID]));
    Sl.SaveToFile(FInfoPath);
  finally
    Sl.Free;
  end;
end;

procedure TToolRPCServer.DeleteInfoFile;
begin
  if FileExists(FInfoPath) then DeleteFile(FInfoPath);
end;

procedure TToolRPCServer.Start;
var
  Bind: TIdSocketHandle;
begin
  FLock.Enter;
  try
    if FServer.Active then Exit;
    FToken := RandomHexToken(16);
    FServer.Bindings.Clear;
    Bind := FServer.Bindings.Add;
    Bind.IP   := '127.0.0.1';
    Bind.Port := 0;
    try
      FServer.Active := True;
    except
      on E: Exception do
      begin
        LogWarn('tool-rpc: bind failed: %s', [E.Message]);
        raise;
      end;
    end;
    FPort := FServer.Bindings[0].Port;
    WriteInfoFile;
    LogDebug('tool-rpc: listening on 127.0.0.1:%d (info=%s)',
             [FPort, FInfoPath]);
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

function DiscoverRunningRPC(out Port: Integer; out Token, ErrMsg: string): Boolean;
var
  Sl: TStringList;
  Obj: TJsonObject;
  Path: string;
begin
  Result := False;
  Port   := 0;
  Token  := '';
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

end.
