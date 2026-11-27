{
  PasClaw.MCP.StdioClient - spawns the configured MCP server command and
  speaks JSON-RPC 2.0 over its stdin/stdout pipes. The protocol itself --
  version negotiation, multi-round requests, tasks, elicitation -- lives in
  PasClaw.MCP.Client; this unit is the pipe.

  Protocol flow:
    1. Spawn `cmd args...` with piped stdin/stdout.
    2. Probe with `server/discover` (2026-07-28). A modern server answers
       it and every request carries _meta from then on; anything else
       (an error, or silence within the probe timeout) means a legacy
       server, which gets `initialize` + notifications/initialized.
    3. `tools/list`, `tools/call` ...
    4. Close: terminate the child.

  Message framing: one JSON object per line (LSP-style "Content-Length"
  headers are also valid but most MCP servers default to newline-delimited
  JSON, which is what we implement here).

  While a request is in flight a legacy server may send a request of its
  own (elicitation/create, ping); it is answered on the same pipe before
  the wait goes on. A modern server must not send any, and a modern client
  must not write responses, so in modern mode such a line is ignored.

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
  SysUtils, Classes, SyncObjs,
  PasClaw.MCP.Types,
  PasClaw.MCP.Client,
  PasClaw.Platform;

type
  TMCPStdioClient = class(TMCPProtocolClient)
  private
    FProcess: TStdioProcess;
    FCmd, FArgs: string;
    { One request on the pipe at a time: two threads interleaving writes
      and reads on one stdout would take each other's responses. }
    FIOLock:  TCriticalSection;
    { FBuffer is a UTF8String (1-byte-per-char in both FPC and Delphi) so
      byte-level accumulation from the child's stdout works regardless of
      whether `string` is AnsiString (FPC) or UnicodeString (Delphi). }
    FBuffer:  UTF8String;
    function  ReadLine(out Line: string; TimeoutMs: Integer): Boolean;
    function  WriteLine(const S: string): Boolean;
  protected
    function OpenTransport(TimeoutMs: Integer; out ErrMsg: string): Boolean; override;
    function Exchange(const Method, ParamsJSON: string; Id, TimeoutMs: Integer;
                      Modern: Boolean): TMCPWireReply; override;
    procedure Notify(const Method, ParamsJSON: string); override;
    function CanAnswerServerRequests: Boolean; override;
    function TransportAlive: Boolean; override;
  public
    constructor Create(const Name, Cmd, Args: string);
    destructor  Destroy; override;
    procedure Close;
  end;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Logger;

constructor TMCPStdioClient.Create(const Name, Cmd, Args: string);
begin
  inherited Create(Name);
  FCmd    := Cmd;
  FArgs   := Args;
  FBuffer := '';
  FIOLock := TCriticalSection.Create;
  FCallTimeoutMs := 30000;
  FListTimeoutMs := 5000;
end;

destructor TMCPStdioClient.Destroy;
begin
  Close;
  FIOLock.Free;
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

function TMCPStdioClient.OpenTransport(TimeoutMs: Integer; out ErrMsg: string): Boolean;
var
  ArgList: TStringList;
begin
  Result := False;
  ErrMsg := '';
  if FCmd = '' then begin ErrMsg := 'no command configured'; Exit; end;
  Close;
  FBuffer := '';
  FProcess := TStdioProcess.Create;
  ArgList := SplitArgs(FArgs);
  try
    if not FProcess.Spawn(FCmd, ArgList) then
    begin
      ErrMsg := 'failed to spawn ' + FCmd;
      FreeAndNil(FProcess);
      Exit;
    end;
  finally
    ArgList.Free;
  end;
  Result := TimeoutMs >= 0;
end;

function TMCPStdioClient.CanAnswerServerRequests: Boolean;
begin
  Result := True;
end;

function TMCPStdioClient.TransportAlive: Boolean;
begin
  Result := (FProcess <> nil) and FProcess.Running;
end;

procedure TMCPStdioClient.Notify(const Method, ParamsJSON: string);
var
  N: TJsonObject;
begin
  N := TJsonObject.Create;
  try
    N.PutStr('jsonrpc', JSONRPCVersion);
    N.PutStr('method', Method);
    if ParamsJSON <> '' then N.PutRaw('params', ParamsJSON);
    FIOLock.Acquire;
    try
      WriteLine(N.ToJSON);
    finally
      FIOLock.Release;
    end;
  finally
    N.Free;
  end;
end;

function TMCPStdioClient.Exchange(const Method, ParamsJSON: string; Id, TimeoutMs: Integer;
                                  Modern: Boolean): TMCPWireReply;
var
  Req, Obj: TJsonObject;
  Line, Answer: string;
  Deadline: Int64;
  Left: Integer;
  IsRequest: Boolean;

  function NowMs: Int64;
  begin
    Result := MilliSecondsBetween(Now, EncodeDate(2000, 1, 1));
  end;

begin
  Result.Body := '';
  Result.HttpStatus := 0;
  Result.Err := '';
  Result.TimedOut := False;
  FIOLock.Acquire;
  try
    Req := TJsonObject.Create;
    try
      Req.PutStr('jsonrpc', JSONRPCVersion);
      Req.PutInt('id',      Id);
      Req.PutStr('method',  Method);
      if ParamsJSON <> '' then Req.PutRaw('params', ParamsJSON);
      LogDebug('mcp[%s] -> %s', [FName, Copy(Req.ToJSON, 1, 300)]);
      if not WriteLine(Req.ToJSON) then
      begin
        Result.Err := 'the server process is not running';
        Exit;
      end;
    finally
      Req.Free;
    end;

    Deadline := NowMs + TimeoutMs;
    while True do
    begin
      Left := Integer(Deadline - NowMs);
      if Left <= 0 then
      begin
        Result.TimedOut := True;
        Exit;
      end;
      if not ReadLine(Line, Left) then
      begin
        if (FProcess = nil) or not FProcess.Running then
          Result.Err := 'the server process exited'
        else
          Result.TimedOut := True;
        Exit;
      end;
      Line := Trim(Line);
      if Line = '' then Continue;
      LogDebug('mcp[%s] <- %s', [FName, Copy(Line, 1, 300)]);
      Obj := JsonTryParse(Line);
      if Obj = nil then Continue;
      try
        IsRequest := Obj.Has('method') and Obj.Has('id');
        if Obj.Has('method') and not IsRequest then Continue;   { a notification }
        if IsRequest then
        begin
          { Legacy only: answer the server's request, then keep waiting --
            the time the user spends answering is not the server's. }
          if Modern then Continue;
          Answer := AnswerServerRequest(Line);
          if Answer <> '' then WriteLine(Answer);
          Deadline := NowMs + TimeoutMs;
          Continue;
        end;
        { Skip responses to other requests (a probe answered late). }
        if Obj.GetInt('id', -1) <> Id then Continue;
        Result.Body := Line;
        Exit;
      finally
        Obj.Free;
      end;
    end;
  finally
    FIOLock.Release;
  end;
end;

end.
