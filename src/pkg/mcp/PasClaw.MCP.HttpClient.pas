(*
  PasClaw.MCP.HttpClient - MCP over Streamable HTTP transport.

  Each call is a single POST to the configured URL with the JSON-RPC envelope.
  The same socket may be reused for the response stream (server-sent events)
  when the server elects to stream multi-part results -- we handle both:

    * Content-Type: application/json  -> response is one JSON object
    * Content-Type: text/event-stream -> parse `data:` lines, join, decode

  Auth tokens come from the configured `args` slot in the MCP server entry,
  shaped as "--header Authorization: Bearer ..." or just "Bearer ...". The
  args field is space-separated; we sniff for an Authorization header.

  Spec: https://modelcontextprotocol.io/specification/2025-03-26/basic/transports
*)
unit PasClaw.MCP.HttpClient;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.MCP.Types;

type
  TMCPHttpClient = class(TMCPBaseClient)
  private
    FName, FURL, FAuth: string;
    FNextId: Integer;
    { Streamable-HTTP session id -- issued by the server in the
      `Mcp-Session-Id` response header on `initialize`, and required
      back on every subsequent request per the MCP 2025-03-26 spec.
      Replicate's server returns 400 "Mcp-Session-Id header is
      required" if we don't echo it on tools/list etc. }
    FSessionId: string;
    function RoundTrip(const Method, ParamsJSON: string;
                       TimeoutSeconds: Integer; out RespJSON: string): Boolean;
  public
    constructor Create(const Name, URL, AuthHeader: string);
    function Connect(TimeoutSeconds: Integer; out ErrMsg: string): Boolean; override;
    function ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean; override;
    function CallTool(const ToolName, ArgsJSON: string;
                      out ResultText, ErrMsg: string): Boolean; override;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.MCP.OAuth;

constructor TMCPHttpClient.Create(const Name, URL, AuthHeader: string);
begin
  inherited Create;
  FName    := Name;
  FURL     := URL;
  FAuth    := AuthHeader;
  FNextId  := 1;
end;

(* Join all `data:` lines into one body (text/event-stream framing). *)
function CollapseSSE(const Body: string): string;
var
  L: TStringList;
  i: Integer;
  Line: string;
  Out_: TStringBuilder;
begin
  Result := '';
  if Pos('data:', Body) = 0 then
  begin
    Result := Body;
    Exit;
  end;
  L := TStringList.Create;
  Out_ := TStringBuilder.Create;
  try
    L.Text := Body;
    for i := 0 to L.Count - 1 do
    begin
      Line := L[i];
      if Copy(Line, 1, 5) = 'data:' then
      begin
        Line := Trim(Copy(Line, 6, MaxInt));
        if Line <> '' then Out_.Append(Line);
      end;
    end;
    Result := Out_.ToString;
  finally
    Out_.Free;
    L.Free;
  end;
end;

function LooksLikeJsonRpcReply(const S: string): Boolean;
{ True when S parses as a JSON object carrying a JSON-RPC reply shape
  (result / error / jsonrpc). Used to salvage a streamed reply when the
  HTTP layer reports a bad/zero status but the body actually arrived. }
var
  O: TJsonObject;
begin
  Result := False;
  if Trim(S) = '' then Exit;
  O := TJsonObject.Parse(S);
  if O = nil then Exit;
  try
    Result := O.Has('result') or O.Has('error') or O.Has('jsonrpc');
  finally
    O.Free;
  end;
end;

function LookupHeader(const Headers: THeaderPairs; const Name: string): string;
{ Case-insensitive header lookup. HTTP header names are
  case-insensitive per RFC 7230 §3.2, and Indy + TNetHTTPClient
  surface them with whatever case the wire used (Replicate sends
  "Mcp-Session-Id"; other servers may send "mcp-session-id"). }
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Headers) do
    if SameText(Headers[i].Name, Name) then
    begin
      Result := Headers[i].Value;
      Exit;
    end;
end;

function TMCPHttpClient.RoundTrip(const Method, ParamsJSON: string;
                                  TimeoutSeconds: Integer;
                                  out RespJSON: string): Boolean;

  function BuildHeaders(const EffectiveAuth: string): TArray<THeaderPair>;
  var
    N: Integer;
  begin
    N := 1;
    if EffectiveAuth <> '' then Inc(N);
    if FSessionId    <> '' then Inc(N);
    SetLength(Result, N);
    Result[0] := MakeHeader('Accept', 'application/json, text/event-stream');
    N := 1;
    if EffectiveAuth <> '' then
    begin
      Result[N] := MakeHeader('Authorization', EffectiveAuth);
      Inc(N);
    end;
    if FSessionId <> '' then
      Result[N] := MakeHeader('Mcp-Session-Id', FSessionId);
  end;

  function ResolveAuth: string;
  var
    AccessToken: string;
  begin
    if FAuth <> '' then
    begin
      Result := FAuth;
      Exit;
    end;
    { Catalog/onboard installs of OAuth servers leave FAuth empty and
      defer to the on-disk token store under <home>/oauth/<name>.json.
      A successful `pasclaw mcp auth <name>` populates it; an absent
      file just means we send no Authorization header and let the
      server's 401 surface as the usual "auth required" error. }
    AccessToken := GetAccessToken(FName);
    if AccessToken = '' then
      Result := ''
    else
      Result := 'Bearer ' + AccessToken;
  end;

var
  Req: TJsonObject;
  Body, EffectiveAuth, RefreshErr, Salvaged: string;
  Headers: TArray<THeaderPair>;
  Resp: THTTPResult;
begin
  RespJSON := '';
  Req := TJsonObject.Create;
  try
    Req.PutStr('jsonrpc', JSONRPCVersion);
    Req.PutInt('id', FNextId);
    Inc(FNextId);
    Req.PutStr('method', Method);
    if ParamsJSON <> '' then Req.PutRaw('params', ParamsJSON);
    Body := Req.ToJSON;
  finally
    Req.Free;
  end;

  EffectiveAuth := ResolveAuth;
  Headers := BuildHeaders(EffectiveAuth);
  Resp := PostJSON(FURL, Body, Headers, TimeoutSeconds);

  { OAuth refresh-and-retry: a 401 against a server we have stored
    tokens for usually means the access token expired between our
    last-checked expiry and now. Try one silent refresh, then retry
    the request. If refresh fails (or this isn't an OAuth server),
    surface the original failure. }
  if (Resp.StatusCode = 401) and (FAuth = '') and HasStoredTokens(FName) then
  begin
    if ForceRefresh(FName, RefreshErr) then
    begin
      EffectiveAuth := ResolveAuth;
      if EffectiveAuth <> '' then
      begin
        Headers := BuildHeaders(EffectiveAuth);
        Resp := PostJSON(FURL, Body, Headers, TimeoutSeconds);
      end;
    end
    else
      LogWarn('mcp-http[%s] 401 + refresh failed: %s', [FName, RefreshErr]);
  end;

  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    { Salvage a streamed reply. Streamable-HTTP servers (Replicate among
      them) send the JSON-RPC response as a single text/event-stream event
      and then hold or abruptly close the connection; System.Net raises on
      that, so we see StatusCode=0 even though the logical response landed
      in the body intact. If the collapsed body is a well-formed JSON-RPC
      envelope, treat it as success rather than discarding it. }
    Salvaged := CollapseSSE(Resp.Body);
    if LooksLikeJsonRpcReply(Salvaged) then
    begin
      if FSessionId = '' then
        FSessionId := LookupHeader(Resp.RespHeaders, 'Mcp-Session-Id');
      RespJSON := Salvaged;
      Exit(True);
    end;
    LogWarn('mcp-http[%s] status=%d body=%s',
            [FName, Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit(False);
  end;
  { Streamable-HTTP transport: capture the session id the server may
    have issued on this response. Per MCP 2025-03-26 the server sets
    it on the initialize response and rotates it at its discretion;
    we just always-latch the latest value so subsequent RoundTrips
    echo whatever the server most recently told us to use. }
  if FSessionId = '' then
    FSessionId := LookupHeader(Resp.RespHeaders, 'Mcp-Session-Id');
  RespJSON := CollapseSSE(Resp.Body);
  Result := RespJSON <> '';
end;

function TMCPHttpClient.Connect(TimeoutSeconds: Integer; out ErrMsg: string): Boolean;
var
  Params, ServerInfo: TJsonObject;
  Caps: TJsonObject;
  Resp: string;
  RespObj, ResultObj: TJsonObject;
  ServerInfoObj, CapsObj: TJsonObject;
begin
  ErrMsg := '';
  Params     := TJsonObject.Create;
  ServerInfo := TJsonObject.Create;
  Caps       := TJsonObject.Create;
  try
    Params.PutStr('protocolVersion', MCPProtocolVersion);
    ServerInfo.PutStr('name',    'pasclaw');
    ServerInfo.PutStr('version', '0.1');
    Params.PutObject('clientInfo', ServerInfo);
    Params.PutObject('capabilities', Caps);
    if not RoundTrip('initialize', Params.ToJSON, TimeoutSeconds, Resp) then
    begin
      ErrMsg := 'initialize failed';
      Exit(False);
    end;
  finally
    Params.Free;
    if ServerInfo <> nil then ServerInfo.Free;
    if Caps <> nil then Caps.Free;
  end;

  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then begin ErrMsg := 'bad initialize response'; Exit(False); end;
  try
    if RespObj.Has('error') then
    begin
      ErrMsg := 'initialize error';
      Exit(False);
    end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then begin ErrMsg := 'no result'; Exit(False); end;
    try
      ServerInfoObj := ResultObj.ChildObject('serverInfo');
      if ServerInfoObj <> nil then
      try
        FInfo.Name    := ServerInfoObj.GetStr('name', '');
        FInfo.Version := ServerInfoObj.GetStr('version', '');
      finally
        ServerInfoObj.Free;
      end;
      CapsObj := ResultObj.ChildObject('capabilities');
      if CapsObj <> nil then
      try
        FInfo.Caps.Tools     := CapsObj.Has('tools');
        FInfo.Caps.Resources := CapsObj.Has('resources');
        FInfo.Caps.Prompts   := CapsObj.Has('prompts');
      finally
        CapsObj.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

function TMCPHttpClient.ListTools(out Tools: TMCPToolArray; out ErrMsg: string): Boolean;
var
  Resp: string;
  RespObj, ResultObj, ToolObj: TJsonObject;
  Arr: TJsonArray;
  Schema: TJsonObject;
  i: Integer;
begin
  ErrMsg := '';
  SetLength(Tools, 0);
  if not RoundTrip('tools/list', '{}', 10, Resp) then
  begin
    ErrMsg := 'tools/list failed';
    Exit(False);
  end;
  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then Exit(False);
  try
    if RespObj.Has('error') then begin ErrMsg := 'tools/list error'; Exit(False); end;
    ResultObj := RespObj.ChildObject('result');
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
            Tools[i].Name        := ToolObj.GetStr('name', '');
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
    RespObj.Free;
  end;
  Result := True;
end;

function TMCPHttpClient.CallTool(const ToolName, ArgsJSON: string;
                                 out ResultText, ErrMsg: string): Boolean;
var
  Params: TJsonObject;
  Resp: string;
  RespObj, ResultObj, Block: TJsonObject;
  ContentArr: TJsonArray;
  i: Integer;
begin
  ResultText := '';
  ErrMsg := '';
  Params := TJsonObject.Create;
  try
    Params.PutStr('name', ToolName);
    if ArgsJSON <> '' then Params.PutRaw('arguments', ArgsJSON)
    else Params.PutRaw('arguments', '{}');
    if not RoundTrip('tools/call', Params.ToJSON, 60, Resp) then
    begin
      ErrMsg := 'tools/call failed';
      Exit(False);
    end;
  finally
    Params.Free;
  end;
  RespObj := TJsonObject.Parse(Resp);
  if RespObj = nil then Exit(False);
  try
    if RespObj.Has('error') then begin ErrMsg := 'tools/call error'; Exit(False); end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then Exit(False);
    try
      ContentArr := ResultObj.ChildArray('content');
      if ContentArr <> nil then
      try
        for i := 0 to ContentArr.Count - 1 do
        begin
          Block := ContentArr.ItemObject(i);
          if Block = nil then Continue;
          try
            if Block.GetStr('type', '') = 'text' then
            begin
              if ResultText <> '' then ResultText := ResultText + sLineBreak;
              ResultText := ResultText + Block.GetStr('text', '');
            end;
          finally
            Block.Free;
          end;
        end;
      finally
        ContentArr.Free;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

end.
