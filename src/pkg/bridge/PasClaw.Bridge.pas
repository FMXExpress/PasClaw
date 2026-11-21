(*
  PasClaw.Bridge -- the modern end of the DOS link (`pasclaw bridge`).

  The DOS client (src/dos) runs the agent loop and the tools on the DOS
  PC. It cannot reach a model itself: no TCP/IP, no TLS. It sends plain
  HTTP/1.1 requests down a serial line (PasClaw.Bridge.Wire); the bridge
  reads them, forwards each to a PasClaw gateway over ordinary HTTP(S)
  with the gateway's bearer token, and writes the answer back down the
  line. The token, the provider keys and TLS all stay on this side.

  Only three routes cross:
    POST /v1/responses  the model call (function tools passed through,
                        so the model's tool calls come back to DOS)
    GET  /v1/health     the client's "is anyone there" at start
    GET  /v1/models     what --model can name
  Anything else is refused with 403: whoever holds the serial line gets
  a model, not the gateway's file, shell, config or session routes.

  A /v1/responses body is rewritten on the way: "stream" is forced off
  (the line carries one framed answer, not SSE) and, when the bridge was
  started with --model, that model is filled in for a request naming
  none. The answer is cut down to what the client reads (id, status,
  error, output, usage): the full Responses object echoes the request's
  tools and a dozen settings back, 2-3 KB a step that a 9600-baud line
  takes seconds to carry.
*)
unit PasClaw.Bridge;

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
  IdTCPServer, IdTCPConnection, IdContext, IdGlobal, IdSocketHandle,
  PasClaw.Bridge.Wire;

type
  TBridgeConfig = record
    GatewayURL: string;   { http(s)://host:port, no trailing slash }
    Token: string;        { bearer token for the gateway; '' sends none }
    Model: string;        { filled into a /v1/responses body naming none }
    TimeoutSec: Integer;  { one model call, at most }
  end;

  { How a request reaches the gateway. Tests swap it for a stub. False
    with Err when nothing answered; True with Status/RespBody otherwise
    (any status). }
  TBridgeForwardFn = function(const Method, URL, Body, Token: string;
    TimeoutSec: Integer; out Status: Integer; out RespBody, Err: string): Boolean;

  TBridgeLogFn = procedure(const Line: string);
  TBridgeStopFn = function: Boolean;

  TWireWriteFn = function(const S: RawByteString): Boolean of object;

  (* `--listen`: a TCP port the DOS end connects to -- DOSBox-X's
     nullmodem (server:<this host> port:<port> transparent:1), or a
     serial-to-TCP adapter. Each connection is one stream. *)
  TBridgeTcpServer = class
  private
    FServer: TIdTCPServer;
    FCfg: TBridgeConfig;
    FStopping: Boolean;
    procedure OnExecute(Ctx: TIdContext);
  public
    constructor Create(const Cfg: TBridgeConfig);
    destructor Destroy; override;
    { Port 0 picks a free one; read it back from Port. }
    procedure Start(const Addr: string; APort: Integer);
    procedure Stop;
    function Port: Integer;
  end;

var
  GBridgeForward: TBridgeForwardFn;
  GBridgeLog: TBridgeLogFn;

function BridgeRouteAllowed(const Method, Path: string): Boolean;

{ One request in, its answer out. Never raises. }
function BridgeHandle(const Cfg: TBridgeConfig; const Req: TWireMessage): TWireMessage;

(* Serve one stream: read a request, answer it, until the stream closes
   or StopFlag (or StopFn, when given) turns True -- checked about once a
   second. A request whose body fails its CRC is answered 400 "crc": the
   client sends it again. *)
procedure BridgeServeStream(const Cfg: TBridgeConfig; R: TWireReader;
  Send: TWireWriteFn; const Peer: string; var StopFlag: Boolean;
  StopFn: TBridgeStopFn = nil);

{ The default forwarder: PasClaw.Providers.HTTP, bearer token if any. }
function BridgeForwardHTTP(const Method, URL, Body, Token: string;
  TimeoutSec: Integer; out Status: Integer; out RespBody, Err: string): Boolean;

implementation

uses
  DateUtils,
  PasClaw.JSON,
  PasClaw.Providers.HTTP;

const
  ROUTES_TEXT = 'the bridge forwards only POST /v1/responses, GET /v1/health and GET /v1/models';

procedure Log(const S: string);
begin
  if Assigned(GBridgeLog) then GBridgeLog(S);
end;

function PathOnly(const Path: string): string;
var
  P: Integer;
begin
  P := Pos('?', Path);
  if P > 0 then Result := Copy(Path, 1, P - 1) else Result := Path;
end;

function BridgeRouteAllowed(const Method, Path: string): Boolean;
var
  P: string;
begin
  P := PathOnly(Path);
  Result := ((Method = 'POST') and (P = '/v1/responses')) or
            ((Method = 'GET') and ((P = '/v1/health') or (P = '/v1/models')));
end;

function ErrorBody(const Msg: string): RawByteString;
var
  O, E: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    E := TJsonObject.Create;
    E.PutStr('message', Msg);
    O.PutObject('error', E);
    Result := StringToWireBody(O.ToJSON);
  finally
    O.Free;
  end;
end;

function BridgeForwardHTTP(const Method, URL, Body, Token: string;
  TimeoutSec: Integer; out Status: Integer; out RespBody, Err: string): Boolean;
var
  H: array of THeaderPair;
  R: THTTPResult;
begin
  SetLength(H, 0);
  if Token <> '' then
  begin
    SetLength(H, 1);
    H[0] := MakeHeader('Authorization', 'Bearer ' + Token);
  end;
  if Method = 'POST' then R := PostJSON(URL, Body, H, TimeoutSec)
  else R := GetJSONURL(URL, H, TimeoutSec);
  Status := R.StatusCode;
  RespBody := R.Body;
  Err := R.ErrorMsg;
  Result := R.StatusCode > 0;
  if (not Result) and (Err = '') then Err := 'no answer';
end;

{ Force "stream": false and fill in the model. Err when the body is not
  a JSON object. }
function RewriteResponsesBody(const Cfg: TBridgeConfig; const Body: string;
  out Err: string): string;
var
  O: TJsonObject;
begin
  Result := '';
  Err := '';
  O := nil;
  try
    O := TJsonObject.Parse(Body);
  except
    O := nil;
  end;
  if O = nil then
  begin
    Err := 'the request body is not a JSON object';
    Exit;
  end;
  try
    O.PutBool('stream', False);
    if (Cfg.Model <> '') and (O.GetStr('model', '') = '') then
      O.PutStr('model', Cfg.Model);
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

{ The parts of a Responses answer the client reads; the rest is echo. }
function SlimResponsesAnswer(const Body: string): string;
const
  KEEP: array[0..5] of string = ('id', 'status', 'error', 'incomplete_details', 'output', 'usage');
var
  O, Slim, Child: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Result := Body;
  O := nil;
  try
    O := TJsonObject.Parse(Body);
  except
    O := nil;
  end;
  if O = nil then Exit;
  Slim := TJsonObject.Create;
  try
    for i := 0 to High(KEEP) do
    begin
      if not O.Has(KEEP[i]) then Continue;
      Child := O.ChildObject(KEEP[i]);
      if Child <> nil then
      begin
        Slim.PutRaw(KEEP[i], Child.ToJSON);
        Child.Free;
        Continue;
      end;
      Arr := O.ChildArray(KEEP[i]);
      if Arr <> nil then
      begin
        Slim.PutRaw(KEEP[i], Arr.ToJSON);
        Arr.Free;
        Continue;
      end;
      if O.GetStr(KEEP[i], '') <> '' then Slim.PutStr(KEEP[i], O.GetStr(KEEP[i], ''));
    end;
    Result := Slim.ToJSON;
  finally
    Slim.Free;
    O.Free;
  end;
end;

function BridgeHandle(const Cfg: TBridgeConfig; const Req: TWireMessage): TWireMessage;
var
  Body, RespBody, Err, Seq: string;
  Status: Integer;
  Fwd: TBridgeForwardFn;
begin
  Result.Method := '';
  Result.Path := '';
  Result.Reason := '';
  SetLength(Result.Headers, 0);
  WireSetHeader(Result, 'Content-Type', 'application/json');
  Seq := WireHeader(Req, WIRE_SEQ_HEADER);
  if Seq <> '' then WireSetHeader(Result, WIRE_SEQ_HEADER, Seq);
  try
    if not BridgeRouteAllowed(Req.Method, Req.Path) then
    begin
      Result.Status := 403;
      Result.Body := ErrorBody(ROUTES_TEXT + '; refused ' + Req.Method + ' ' + PathOnly(Req.Path));
      Exit;
    end;
    Body := WireBodyToString(Req.Body);
    if Req.Method = 'POST' then
    begin
      Body := RewriteResponsesBody(Cfg, Body, Err);
      if Err <> '' then
      begin
        Result.Status := 400;
        Result.Body := ErrorBody(Err);
        Exit;
      end;
    end;
    Fwd := GBridgeForward;
    if not Assigned(Fwd) then Fwd := BridgeForwardHTTP;
    if not Fwd(Req.Method, Cfg.GatewayURL + PathOnly(Req.Path), Body, Cfg.Token,
               Cfg.TimeoutSec, Status, RespBody, Err) then
    begin
      Result.Status := 502;
      Result.Body := ErrorBody('the gateway at ' + Cfg.GatewayURL + ' did not answer: ' + Err +
                               ' (is `pasclaw gateway` running?)');
      Exit;
    end;
    Result.Status := Status;
    if (Req.Method = 'POST') and (Status = 200) then RespBody := SlimResponsesAnswer(RespBody);
    Result.Body := StringToWireBody(RespBody);
  except
    on E: Exception do
    begin
      Result.Status := 502;
      Result.Body := ErrorBody('bridge: ' + E.Message);
    end;
  end;
end;

procedure BridgeServeStream(const Cfg: TBridgeConfig; R: TWireReader;
  Send: TWireWriteFn; const Peer: string; var StopFlag: Boolean;
  StopFn: TBridgeStopFn);
var
  Req, Resp: TWireMessage;
  Err: string;
  T0: TDateTime;
begin
  while not StopFlag and not (Assigned(StopFn) and StopFn()) do
  begin
    if not ReadWireRequest(R, Req, 1000, 10000, Err) then
    begin
      if R.IsClosed then Exit;
      if Err = 'idle' then Continue;
      if Copy(Err, 1, 4) = 'crc:' then
      begin
        { The head arrived whole, so the client is waiting for an
          answer: tell it to send again. }
        Resp.Method := '';
        Resp.Path := '';
        Resp.Reason := '';
        SetLength(Resp.Headers, 0);
        WireSetHeader(Resp, 'Content-Type', 'application/json');
        if WireHeader(Req, WIRE_SEQ_HEADER) <> '' then
          WireSetHeader(Resp, WIRE_SEQ_HEADER, WireHeader(Req, WIRE_SEQ_HEADER));
        Resp.Status := 400;
        Resp.Body := ErrorBody('crc');
        Send(FormatWireResponse(Resp));
      end;
      Log(Peer + ': ' + Err);
      Continue;
    end;
    T0 := Now;
    Resp := BridgeHandle(Cfg, Req);
    if not Send(FormatWireResponse(Resp)) then
    begin
      Log(Peer + ': ' + Req.Method + ' ' + Req.Path + ' -- the answer could not be sent');
      Exit;
    end;
    Log(Format('%s: %s %s %d B -> %d %d B (%.1f s)',
      [Peer, Req.Method, PathOnly(Req.Path), Length(Req.Body), Resp.Status,
       Length(Resp.Body), MilliSecondsBetween(Now, T0) / 1000]));
  end;
end;

{ ---- TCP ---- }

type
  TIndyWireStream = class(TWireReader)
  private
    FConn: TIdTCPConnection;
    FClosed: Boolean;
  public
    constructor Create(Conn: TIdTCPConnection);
    function ReadByte(out B: Byte; TimeoutMs: Integer): Boolean; override;
    function IsClosed: Boolean; override;
    function WriteBytes(const S: RawByteString): Boolean;
  end;

constructor TIndyWireStream.Create(Conn: TIdTCPConnection);
begin
  inherited Create;
  FConn := Conn;
end;

function TIndyWireStream.ReadByte(out B: Byte; TimeoutMs: Integer): Boolean;
begin
  B := 0;
  Result := False;
  if FClosed then Exit;
  try
    if FConn.IOHandler.InputBufferIsEmpty then
    begin
      FConn.IOHandler.CheckForDataOnSource(TimeoutMs);
      if FConn.IOHandler.InputBufferIsEmpty then
      begin
        if not FConn.Connected then FClosed := True;
        Exit;
      end;
    end;
    B := FConn.IOHandler.ReadByte;
    Result := True;
  except
    FClosed := True;
  end;
end;

function TIndyWireStream.IsClosed: Boolean;
begin
  if not FClosed then
  try
    if not FConn.Connected then FClosed := True;
  except
    FClosed := True;
  end;
  Result := FClosed;
end;

function TIndyWireStream.WriteBytes(const S: RawByteString): Boolean;
var
  Buf: TIdBytes;
begin
  Result := False;
  if FClosed then Exit;
  SetLength(Buf, Length(S));
  if Length(S) > 0 then Move(S[1], Buf[0], Length(S));
  try
    FConn.IOHandler.Write(Buf);
    Result := True;
  except
    FClosed := True;
  end;
end;

constructor TBridgeTcpServer.Create(const Cfg: TBridgeConfig);
begin
  inherited Create;
  FCfg := Cfg;
  FServer := TIdTCPServer.Create(nil);
  FServer.OnExecute := OnExecute;
end;

destructor TBridgeTcpServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited Destroy;
end;

procedure TBridgeTcpServer.Start(const Addr: string; APort: Integer);
var
  Bind: TIdSocketHandle;
begin
  FStopping := False;
  FServer.Bindings.Clear;
  Bind := FServer.Bindings.Add;
  Bind.IP := Addr;
  Bind.Port := APort;
  FServer.Active := True;
end;

procedure TBridgeTcpServer.Stop;
begin
  FStopping := True;
  if FServer.Active then
  try
    FServer.Active := False;
  except
  end;
end;

function TBridgeTcpServer.Port: Integer;
begin
  if FServer.Bindings.Count > 0 then Result := FServer.Bindings[0].Port
  else Result := 0;
end;

procedure TBridgeTcpServer.OnExecute(Ctx: TIdContext);
var
  S: TIndyWireStream;
  Peer: string;
begin
  Peer := Ctx.Binding.PeerIP + ':' + IntToStr(Ctx.Binding.PeerPort);
  Log(Peer + ': connected');
  S := TIndyWireStream.Create(Ctx.Connection);
  try
    BridgeServeStream(FCfg, S, S.WriteBytes, Peer, FStopping);
  finally
    S.Free;
  end;
  Log(Peer + ': disconnected');
  try
    Ctx.Connection.Disconnect;
  except
  end;
end;

end.
