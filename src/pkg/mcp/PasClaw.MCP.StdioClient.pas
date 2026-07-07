{
  PasClaw.MCP.StdioClient - spawns the configured MCP server command and
  speaks JSON-RPC 2.0 over its stdin/stdout pipes. Mirrors a thin slice of
  pkg/mcp/manager.go in picoclaw.

  Protocol flow:
    1. Spawn `cmd args...` with piped stdin/stdout.
    2. Send `initialize` request, receive server capabilities.
    3. Send `tools/list`, get the available tool descriptors.
    4. Optionally `tools/call` to invoke one.
    5. `shutdown` + close pipes; reap.

  Message framing: one JSON object per line (LSP-style "Content-Length"
  headers are also valid but most MCP servers default to newline-delimited
  JSON, which is what we implement here).

  Process spawn is delegated to PasClaw.Platform.TStdioProcess, which
  provides bidirectional pipes on both FPC (via fcl-process) and Delphi
  (CreateProcess on Windows, fork+pipe on POSIX), so stdio MCP works on
  both compilers.
}
unit PasClaw.MCP.StdioClient;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.MCP.Types,
  PasClaw.Platform;

type
  TMCPStdioClient = class(TMCPBaseClient)
  private
    FProcess: TStdioProcess;
    FCmd, FArgs, FName: string;
    FNextId:  Integer;
    { FBuffer is a UTF8String (1-byte-per-char in both FPC and Delphi) so
      byte-level accumulation from the child's stdout works regardless of
      whether `string` is AnsiString (FPC) or UnicodeString (Delphi). }
    FBuffer:  UTF8String;
    function  ReadLine(out Line: string; TimeoutMs: Integer): Boolean;
    function  WriteLine(const S: string): Boolean;
    function  RoundTrip(const Method, ParamsJSON: string;
                        TimeoutMs: Integer; out RespJSON: string): Boolean;
  public
    constructor Create(const Name, Cmd, Args: string);
    destructor  Destroy; override;

    function Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean; override;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; override;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; override;
    procedure Close;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.MCP.Result;

constructor TMCPStdioClient.Create(const Name, Cmd, Args: string);
begin
  inherited Create;
  FName   := Name;
  FCmd    := Cmd;
  FArgs   := Args;
  FNextId := 1;
  FBuffer := '';
end;

destructor TMCPStdioClient.Destroy;
begin
  Close;
  inherited Destroy;
end;

procedure TMCPStdioClient.Close;
begin
  if FProcess <> nil then
  begin
    try
      if FProcess.Running then FProcess.Terminate;
    except
      { ignore -- we're tearing down }
    end;
    FreeAndNil(FProcess);
  end;
end;

function SplitArgs(const S: string): TStringList;
{ Tokenize a `cmd args...` string for direct-to-argv handoff to
  TStdioProcess.Spawn (no shell is involved). Splits on unquoted
  whitespace and honors paired single/double quotes; everything else,
  including backslashes, is taken literally. That keeps Windows paths
  intact -- most importantly UNC roots like \\server\share -- which a
  POSIX-style \\-escape rule would mangle. When richer escaping is
  needed, an array-form config will eventually replace this entirely. }
var
  i, n: Integer;
  inQuote: Boolean;
  qc: Char;
  cur: string;
begin
  Result := TStringList.Create;
  n := Length(S);
  cur := '';
  inQuote := False;
  qc := ' ';
  i := 1;
  while i <= n do
  begin
    if inQuote then
    begin
      if S[i] = qc then inQuote := False
      else cur := cur + S[i];
    end
    else
    begin
      if (S[i] = '"') or (S[i] = '''') then
      begin
        inQuote := True;
        qc := S[i];
      end
      else if S[i] = ' ' then
      begin
        if cur <> '' then begin Result.Add(cur); cur := ''; end;
      end
      else
        cur := cur + S[i];
    end;
    Inc(i);
  end;
  if cur <> '' then Result.Add(cur);
end;

function TMCPStdioClient.WriteLine(const S: string): Boolean;
begin
  if (FProcess = nil) or not FProcess.Running then Exit(False);
  Result := FProcess.WriteLineUTF8(S);
end;

function TMCPStdioClient.ReadLine(out Line: string; TimeoutMs: Integer): Boolean;
var
  Buf: array[0..4095] of Byte;
  N, Waited, NLPos: Integer;
  Chunk, LineUTF8: UTF8String;
begin
  Line := '';
  Waited := 0;
  if FProcess = nil then Exit(False);
  while True do
  begin
    NLPos := Pos(UTF8String(#10), FBuffer);
    if NLPos > 0 then
    begin
      LineUTF8 := Copy(FBuffer, 1, NLPos - 1);
      FBuffer  := Copy(FBuffer, NLPos + 1, MaxInt);
      { UTF8String -> string: AnsiString-identity under FPC, UTF-8 decode under Delphi. }
      Line := string(LineUTF8);
      Exit(True);
    end;
    N := FProcess.ReadAvailable(Buf, SizeOf(Buf));
    if N > 0 then
    begin
      SetLength(Chunk, N);
      Move(Buf[0], Chunk[1], N);   { safe: UTF8String is 1 byte per char }
      FBuffer := FBuffer + Chunk;
      Continue;
    end;
    if not FProcess.Running then Exit(False);
    Inc(Waited, 50);   { ReadAvailable already slept up to ~50 ms }
    if Waited >= TimeoutMs then Exit(False);
  end;
end;

function TMCPStdioClient.RoundTrip(const Method, ParamsJSON: string;
                                   TimeoutMs: Integer;
                                   out RespJSON: string): Boolean;
var
  Id: Integer;
  Req, RespObj: TJsonObject;
  Line: string;
begin
  RespJSON := '';
  Id := FNextId; Inc(FNextId);

  Req := TJsonObject.Create;
  try
    Req.PutStr('jsonrpc', JSONRPCVersion);
    Req.PutInt('id',      Id);
    Req.PutStr('method',  Method);
    if ParamsJSON <> '' then Req.PutRaw('params', ParamsJSON);
    if not WriteLine(Req.ToJSON) then Exit(False);
  finally
    Req.Free;
  end;

  while ReadLine(Line, TimeoutMs) do
  begin
    Line := Trim(Line);
    if Line = '' then Continue;
    LogDebug('mcp[%s] <- %s', [FName, Copy(Line, 1, 200)]);
    RespObj := TJsonObject.Parse(Line);
    if RespObj = nil then Continue;
    try
      { Skip notifications (no id) and responses to other requests. }
      if (not RespObj.Has('id')) or (RespObj.GetInt('id', -1) <> Id) then
        Continue;
      RespJSON := Line;
      Exit(True);
    finally
      RespObj.Free;
    end;
  end;
  Result := False;
end;

function TMCPStdioClient.Connect(TimeoutMs: Integer; out ErrMsg: string): Boolean;
var
  Params, Caps, ClientInfo, RespObj, ResultObj, Inner: TJsonObject;
  Resp: string;
  ArgList: TStringList;
begin
  ErrMsg := '';
  if FCmd = '' then begin ErrMsg := 'no command configured'; Exit(False); end;

  FProcess := TStdioProcess.Create;
  ArgList := SplitArgs(FArgs);
  try
    if not FProcess.Spawn(FCmd, ArgList) then
    begin
      ErrMsg := 'failed to spawn ' + FCmd;
      FreeAndNil(FProcess);
      Exit(False);
    end;
  finally
    ArgList.Free;
  end;

  { initialize }
  Params := TJsonObject.Create;
  try
    Params.PutStr('protocolVersion', MCPProtocolVersion);
    Caps := TJsonObject.Create;
    Params.PutObject('capabilities', Caps);
    ClientInfo := TJsonObject.Create;
    ClientInfo.PutStr('name',    'pasclaw');
    ClientInfo.PutStr('version', '0.1');
    Params.PutObject('clientInfo', ClientInfo);
    if not RoundTrip('initialize', Params.ToJSON, TimeoutMs, Resp) then
    begin
      ErrMsg := 'no response to initialize from ' + FCmd;
      Exit(False);
    end;
  finally
    Params.Free;
  end;

  { Parse server info & capabilities out of the response. }
  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then begin ErrMsg := 'bad initialize response'; Exit(False); end;
  try
    if RespObj.Has('error') then
    begin
      ErrMsg := 'initialize error';
      Exit(False);
    end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj <> nil then
    try
      Inner := ResultObj.ChildObject('serverInfo');
      if Inner <> nil then
      try
        FInfo.Name    := Inner.GetStr('name',    '');
        FInfo.Version := Inner.GetStr('version', '');
      finally
        Inner.Free;
      end;
      Inner := ResultObj.ChildObject('capabilities');
      if Inner <> nil then
      try
        FInfo.Caps.Tools     := Inner.Has('tools');
        FInfo.Caps.Resources := Inner.Has('resources');
        FInfo.Caps.Prompts   := Inner.Has('prompts');
      finally
        Inner.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;

  { Send "initialized" notification (no id, no response expected). }
  WriteLine('{"jsonrpc":"2.0","method":"notifications/initialized"}');
  Result := True;
end;

function TMCPStdioClient.ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
var
  Resp: string;
  Obj, ResultObj, ToolObj, Schema: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  ErrMsg := '';
  SetLength(Tools, 0);
  if not RoundTrip('tools/list', '{}', 5000, Resp) then
  begin
    ErrMsg := 'no response to tools/list';
    Exit(False);
  end;
  Obj := TJsonObject.Parse(Resp);
  if Obj = nil then Exit(False);
  try
    if Obj.Has('error') then begin ErrMsg := 'tools/list error'; Exit(False); end;
    ResultObj := Obj.ChildObject('result');
    if ResultObj = nil then Exit(True);
    try
      Arr := ResultObj.ChildArray('tools');
      if Arr = nil then Exit(True);
      try
        SetLength(Tools, Arr.Count);
        for i := 0 to Arr.Count - 1 do
        begin
          ToolObj := Arr.ItemObject(i);
          if ToolObj = nil then Continue;
          try
            Tools[i].Name        := ToolObj.GetStr('name',        '');
            Tools[i].Description := ToolObj.GetStr('description', '');
            Schema := ToolObj.ChildObject('inputSchema');
            if Schema <> nil then
            try
              Tools[i].Schema := Schema.ToJSON;
            finally
              Schema.Free;
            end
            else
              Tools[i].Schema := '{"type":"object"}';
            Tools[i].Server := FName;
          finally
            ToolObj.Free;
          end;
        end;
      finally
        Arr.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    Obj.Free;
  end;
  Result := True;
end;

function TMCPStdioClient.CallTool(const ToolName, ArgsJSON: string;
                                  out ResultText, ErrMsg: string): Boolean;
var
  Dummy: string;
begin
  Result := CallToolStructured(ToolName, ArgsJSON, ResultText, Dummy, ErrMsg);
end;

function TMCPStdioClient.CallToolStructured(const ToolName, ArgsJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  Params: TJsonObject;
  Resp: string;
begin
  ResultText := '';
  ResultJSON := '';
  ErrMsg := '';
  Params := TJsonObject.Create;
  try
    Params.PutStr('name', ToolName);
    if ArgsJSON <> '' then Params.PutRaw('arguments', ArgsJSON)
    else                    Params.PutRaw('arguments', '{}');
    if not RoundTrip('tools/call', Params.ToJSON, 30000, Resp) then
    begin
      ErrMsg := 'no response to tools/call';
      Exit(False);
    end;
  finally
    Params.Free;
  end;
  Result := ParseToolCallResult(Resp, ResultText, ResultJSON, ErrMsg);
end;

end.
