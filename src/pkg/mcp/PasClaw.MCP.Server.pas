(*
  PasClaw.MCP.Server - inbound MCP server core: dispatches JSON-RPC 2.0
  requests against a curated read-only slice of the tool registry so
  external runtimes (Claude Desktop, Cursor, Codex CLI, any MCP host)
  can consume PasClaw's memory_search / kb_search / session_search /
  SCARS live, against the SAME corpus the local CLI sees. Completes
  the "source of truth" story the static export commands started.

  This unit is TRANSPORT-AGNOSTIC: HandleRequest takes a single
  JSON-RPC request line and returns the response line. The HTTP route
  in PasClaw.Gateway.Server and the stdio loop in PasClaw.Cmd.MCP
  both call into it -- one source of truth for the protocol, two
  transports.

  Tool surface (read-only by default):

    - memory_search / memory_get / memory_fetch    : workspace/memory
                                                     (incl. SCARS.md)
    - kb_search / kb_get                           : knowledgebase corpus
    - session_search                               : past sessions
    - any other tcReadOnly tool registered in the parent registry

  Operators who want write tools exposed pass AllowMutating := True at
  Create. Off by default because letting a foreign MCP host call
  fs_write / shell on the operator's box is exactly the bad outcome
  the sandbox layer exists to prevent.

  Implements just enough of the MCP spec for the read-corpus case, serving
  BOTH protocol eras from one dispatcher (the core was per-request stateless
  from day one, so the 2026-07-28 "stateless" revision mostly named what we
  already did):

    modern (2026-07-28, per-request _meta, no handshake):
    - server/discover             -> supportedVersions + capabilities + serverInfo
    - a declared _meta protocol version we don't serve gets
      UnsupportedProtocolVersionError (-32022) with the supported list
    legacy (2024-11-05, initialize handshake):
    - initialize                  -> serverInfo + capabilities
    - notifications/initialized   -> ack (no response, void)
    both eras:
    - ping                        -> {}
    - tools/list                  -> tool descriptors
    - tools/call                  -> dispatch via TToolRegistry

  resources/* and prompts/* are not advertised; a future revision can
  fold skills in as MCP prompts (a better fit than as tools, since a
  skill on its own without the parent LLM isn't directly callable).
*)
unit PasClaw.MCP.Server;

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
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

const
  MCPServerProtocolVersion = '2024-11-05';   { legacy (initialize handshake) }
  MCPServerProtocolModern  = '2026-07-28';   { stateless (per-request _meta) }
  MCPServerName            = 'pasclaw';

type
  TMCPServerCore = class
  private
    FRegistry:      TToolRegistry;
    FAllowMutating: Boolean;
    FAllowList:     array of string;  { empty = "all tcReadOnly tools" }
    FVersion:       string;
    function IsExposed(const Name: string): Boolean;
    function HandleInitialize(const Params, Id: string): string;
    function HandleDiscover(const Id: string): string;
    function HandleToolsList(const Id: string; Modern: Boolean): string;
    function HandleToolsCall(const Params, Id: string; Modern: Boolean): string;
    function HandlePing(const Id: string): string;
    function ErrorResponse(const Id: string; Code: Integer;
                            const Message: string): string;
    function ErrorResponseData(const Id: string; Code: Integer;
                                const Message, DataJSON: string): string;
    function SuccessResponse(const Id, ResultJSON: string): string;
  public
    constructor Create(ARegistry: TToolRegistry; AAllowMutating: Boolean;
                       const AVersion: string);
    destructor Destroy; override;

    { Restrict exposure to a specific name list (in addition to the
      mutating gate). Empty array = "no name filter, expose whatever
      passes the mutating gate". Set this when the operator wants to
      narrow the MCP surface to e.g. just memory_search + kb_search. }
    procedure SetAllowList(const Names: array of string);

    { HandleRequest:
        ALine -- one JSON-RPC request line (newline-stripped).
        Returns the response line ('' for notifications which by spec
        get no response).
      Idempotent + thread-safe (TToolRegistry handles its own locking).
      Never raises; all errors land as JSON-RPC error responses. }
    function HandleRequest(const ALine: string): string; overload;
    { Transport-aware variant: HttpStatus is the HTTP status an HTTP binding
      should send with the response -- 400 for UnsupportedProtocolVersionError
      (per the 2026-07-28 Streamable HTTP rules), 200 otherwise. The stdio
      loop uses the plain overload and ignores it. }
    function HandleRequest(const ALine: string;
                           out HttpStatus: Integer): string; overload;

    property AllowMutating: Boolean read FAllowMutating;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger;

constructor TMCPServerCore.Create(ARegistry: TToolRegistry;
                                   AAllowMutating: Boolean;
                                   const AVersion: string);
begin
  inherited Create;
  FRegistry      := ARegistry;
  FAllowMutating := AAllowMutating;
  FVersion       := AVersion;
  if FVersion = '' then FVersion := '0.1';
  SetLength(FAllowList, 0);
end;

destructor TMCPServerCore.Destroy;
begin
  { Registry is owned by the caller -- the gateway / cmd hands us a
    reference, lifetime tracks the gateway server itself. }
  inherited Destroy;
end;

procedure TMCPServerCore.SetAllowList(const Names: array of string);
var
  i: Integer;
begin
  SetLength(FAllowList, Length(Names));
  for i := 0 to High(Names) do FAllowList[i] := Names[i];
end;

function TMCPServerCore.IsExposed(const Name: string): Boolean;
var
  T: TTool;
  i: Integer;
begin
  Result := False;
  if FRegistry = nil then Exit;
  if not FRegistry.Find(Name, T) then Exit;
  if (not FAllowMutating) and (T.Category <> tcReadOnly) then Exit;
  if Length(FAllowList) > 0 then
  begin
    Result := False;
    for i := 0 to High(FAllowList) do
      if FAllowList[i] = Name then Exit(True);
  end
  else
    Result := True;
end;

function TMCPServerCore.ErrorResponse(const Id: string; Code: Integer;
                                       const Message: string): string;
var
  Root, Err: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('jsonrpc', '2.0');
    { Id may be either a string or a number on the wire. We preserve
      what the client sent verbatim by emitting via PutRaw when the
      input looks numeric (no quotes / no "null"), otherwise as
      string. Empty = notification id (no response expected, but
      callers may still ask for one for trace symmetry). }
    if (Id = '') or (Id = 'null') then
      { Spec: error responses MUST carry id=null when the request id
        couldn't be determined. }
      Root.PutRaw('id', 'null')
    else
      Root.PutRaw('id', Id);
    Err := TJsonObject.Create;
    Err.PutInt('code',    Code);
    Err.PutStr('message', Message);
    Root.PutObject('error', Err);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TMCPServerCore.ErrorResponseData(const Id: string; Code: Integer;
                                          const Message, DataJSON: string): string;
var
  Root, Err: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('jsonrpc', '2.0');
    if (Id = '') or (Id = 'null') then
      Root.PutRaw('id', 'null')
    else
      Root.PutRaw('id', Id);
    Err := TJsonObject.Create;
    Err.PutInt('code',    Code);
    Err.PutStr('message', Message);
    if DataJSON <> '' then Err.PutRaw('data', DataJSON);
    Root.PutObject('error', Err);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TMCPServerCore.SuccessResponse(const Id, ResultJSON: string): string;
var
  Root: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('jsonrpc', '2.0');
    if (Id = '') or (Id = 'null') then
      Root.PutRaw('id', 'null')
    else
      Root.PutRaw('id', Id);
    Root.PutRaw('result', ResultJSON);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function TMCPServerCore.HandleInitialize(const Params, Id: string): string;
var
  ResObj, Caps, ToolsCap, ServerInfo: TJsonObject;
begin
  { Params currently ignored. A future revision can negotiate
    protocolVersion / capabilities; for v1 we advertise the fixed
    tool surface. }
  if Params <> '' then ;  { silence unused-param hint on Delphi }

  ResObj := TJsonObject.Create;
  try
    ResObj.PutStr('protocolVersion', MCPServerProtocolVersion);
    Caps := TJsonObject.Create;
    ToolsCap := TJsonObject.Create;
    { listChanged: false -- we don't push notifications when the
      registry updates. Skill loaders fire at startup before we
      announce, so the list is stable for the session. }
    ToolsCap.PutBool('listChanged', False);
    Caps.PutObject('tools', ToolsCap);
    ResObj.PutObject('capabilities', Caps);
    ServerInfo := TJsonObject.Create;
    ServerInfo.PutStr('name',    MCPServerName);
    ServerInfo.PutStr('version', FVersion);
    ResObj.PutObject('serverInfo', ServerInfo);
    Result := SuccessResponse(Id, ResObj.ToJSON);
  finally
    ResObj.Free;
  end;
end;

function TMCPServerCore.HandleToolsList(const Id: string; Modern: Boolean): string;
var
  ResObj, ToolObj: TJsonObject;
  Arr: TJsonArray;
  Names: TStringArray;
  i: Integer;
  T: TTool;
begin
  ResObj := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    if FRegistry <> nil then
    begin
      Names := FRegistry.Names;
      for i := 0 to High(Names) do
      begin
        if not IsExposed(Names[i]) then Continue;
        if not FRegistry.Find(Names[i], T) then Continue;
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('name',        T.Name);
        ToolObj.PutStr('description', T.Description);
        { Schema is already a JSON object (string form). PutRaw keeps
          the nested shape intact -- PutStr would double-quote it. }
        if Trim(T.Schema) <> '' then
          ToolObj.PutRaw('inputSchema', T.Schema)
        else
          ToolObj.PutRaw('inputSchema', '{"type":"object"}');
        Arr.AddObject(ToolObj);
      end;
    end;
    ResObj.PutArray('tools', Arr);
    { Modern (2026-07-28) result schema additionally requires resultType +
      cache directives; legacy clients get the unchanged 2024-11-05 shape. }
    if Modern then
    begin
      ResObj.PutStr('resultType', 'complete');
      ResObj.PutInt('ttlMs', 0);
      ResObj.PutStr('cacheScope', 'private');
    end;
    Result := SuccessResponse(Id, ResObj.ToJSON);
  finally
    ResObj.Free;
  end;
end;

function TMCPServerCore.HandleToolsCall(const Params, Id: string; Modern: Boolean): string;
var
  ParamsObj, ArgsObj, ResObj, ContentObj: TJsonObject;
  Arr: TJsonArray;
  ToolName, ArgsJSON, Output, Err: string;
begin
  ToolName := '';
  ArgsJSON := '{}';

  ParamsObj := TJsonObject.Parse(Params);
  if ParamsObj = nil then
  begin
    Result := ErrorResponse(Id, -32602, 'invalid tools/call params');
    Exit;
  end;
  try
    ToolName := ParamsObj.GetStr('name', '');
    ArgsObj  := ParamsObj.ChildObject('arguments');
    if ArgsObj <> nil then
    try
      ArgsJSON := ArgsObj.ToJSON;
    finally
      ArgsObj.Free;
    end;
  finally
    ParamsObj.Free;
  end;

  if ToolName = '' then
  begin
    Result := ErrorResponse(Id, -32602, 'tools/call requires "name"');
    Exit;
  end;
  if not IsExposed(ToolName) then
  begin
    { -32601 is JSON-RPC "method not found"; MCP overloads it as
      "tool not exposed" since the wire shape is the same. }
    Result := ErrorResponse(Id, -32601,
                             'tool not exposed: ' + ToolName);
    Exit;
  end;

  LogDebug('mcp-server: tools/call name=%s args=%s',
           [ToolName, Copy(ArgsJSON, 1, 200)]);
  Output := FRegistry.RunTool(ToolName, ArgsJSON, Err);
  if Err <> '' then
  begin
    { Surface the tool error inside an isError result content block
      (per MCP) rather than a JSON-RPC error -- the spec distinguishes
      transport errors (JSON-RPC) from tool errors (isError content).
      Hosts render isError=true with a different glyph but keep the
      session alive, which is what we want for "memory index temporarily
      offline" style failures. }
    ResObj := TJsonObject.Create;
    try
      Arr := TJsonArray.Create;
      ContentObj := TJsonObject.Create;
      ContentObj.PutStr('type', 'text');
      ContentObj.PutStr('text', '[error] ' + Err);
      Arr.AddObject(ContentObj);
      ResObj.PutArray('content', Arr);
      ResObj.PutBool('isError', True);
      if Modern then ResObj.PutStr('resultType', 'complete');
      Result := SuccessResponse(Id, ResObj.ToJSON);
    finally
      ResObj.Free;
    end;
    Exit;
  end;

  ResObj := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    ContentObj := TJsonObject.Create;
    ContentObj.PutStr('type', 'text');
    ContentObj.PutStr('text', Output);
    Arr.AddObject(ContentObj);
    ResObj.PutArray('content', Arr);
    { Modern result schema requires resultType on call results too. }
    if Modern then ResObj.PutStr('resultType', 'complete');
    Result := SuccessResponse(Id, ResObj.ToJSON);
  finally
    ResObj.Free;
  end;
end;

function TMCPServerCore.HandlePing(const Id: string): string;
var
  Empty: TJsonObject;
begin
  Empty := TJsonObject.Create;
  try
    Result := SuccessResponse(Id, Empty.ToJSON);
  finally
    Empty.Free;
  end;
end;

function ExtractIdRaw(Obj: TJsonObject): string;
{ Return the JSON literal for the request's id field so we can echo
  it back unchanged -- a numeric id ("42") stays numeric, a string id
  ("\"req-1\"") stays a string. Reads from the PARSED object rather
  than the raw line, so an "id" key sitting inside a nested params
  field can't confuse a substring scan. Returns 'null' for missing /
  unparseable ids.

  Detection trick: GetStr returns the supplied default when the field
  exists but isn't a string -- so a sentinel default that can never
  appear in valid JSON (a literal NUL+SOH+STX triplet -- control chars
  must be escaped in JSON strings) lets us reliably distinguish
  "string id" from "numeric id". }
const
  StringSentinel = #0#1#2;
var
  S: string;
  I: Int64;
begin
  Result := 'null';
  if (Obj = nil) or (not Obj.Has('id')) then Exit;
  S := Obj.GetStr('id', StringSentinel);
  if S <> StringSentinel then
  begin
    Result := '"' + JsonEscape(S) + '"';
    Exit;
  end;
  { Not a string -- emit numeric form. GetInt's default is harmless
    here because Has() already confirmed the field is present, so
    the return value is the id itself (or 0 for an unusual null /
    float id, which is the best we can do without round-tripping
    floating-point literals -- the spec discourages float ids
    anyway, hosts use ints or strings). }
  I := Obj.GetInt('id', 0);
  Result := IntToStr(I);
end;

function TMCPServerCore.HandleDiscover(const Id: string): string;
(* server/discover -- the modern (2026-07-28 stateless) entry point. Modern
   servers MUST implement it; clients may call it to learn versions +
   capabilities up front, and dual-era clients use it as the stdio probe
   that distinguishes a modern server from a legacy one. *)
var
  ResObj, Caps, ToolsCap, Meta, ServerInfo: TJsonObject;
  Vers: TJsonArray;
begin
  ResObj := TJsonObject.Create;
  try
    ResObj.PutStr('resultType', 'complete');
    Vers := TJsonArray.Create;
    Vers.AddStr(MCPServerProtocolModern);
    Vers.AddStr(MCPServerProtocolVersion);   { dual-era: legacy still served }
    ResObj.PutArray('supportedVersions', Vers);
    Caps := TJsonObject.Create;
    ToolsCap := TJsonObject.Create;
    ToolsCap.PutBool('listChanged', False);
    Caps.PutObject('tools', ToolsCap);
    ResObj.PutObject('capabilities', Caps);
    Meta := TJsonObject.Create;
    ServerInfo := TJsonObject.Create;
    ServerInfo.PutStr('name',    MCPServerName);
    ServerInfo.PutStr('version', FVersion);
    Meta.PutObject('io.modelcontextprotocol/serverInfo', ServerInfo);
    ResObj.PutObject('_meta', Meta);
    { Required cache directives: ttlMs=0 + private -- our tool surface can
      change per process (skills/config), so tell clients not to cache. }
    ResObj.PutInt('ttlMs', 0);
    ResObj.PutStr('cacheScope', 'private');
    Result := SuccessResponse(Id, ResObj.ToJSON);
  finally
    ResObj.Free;
  end;
end;

function TMCPServerCore.HandleRequest(const ALine: string): string;
var
  Ignored: Integer;
begin
  Result := HandleRequest(ALine, Ignored);
end;

function TMCPServerCore.HandleRequest(const ALine: string;
                                      out HttpStatus: Integer): string;
var
  Obj, ParamsObj, MetaObj: TJsonObject;
  Method, Id, Params, ReqVer: string;
  Modern: Boolean;
begin
  Result := '';
  HttpStatus := 200;
  if Trim(ALine) = '' then Exit;

  Obj := nil;
  try
    Obj := TJsonObject.Parse(ALine);
  except
    Result := ErrorResponse('null', -32700, 'parse error');
    Exit;
  end;
  if Obj = nil then
  begin
    Result := ErrorResponse('null', -32700, 'parse error');
    Exit;
  end;
  try
    Method := Obj.GetStr('method', '');
    Id     := ExtractIdRaw(Obj);
    ReqVer := '';
    ParamsObj := Obj.ChildObject('params');
    Params := '';
    if ParamsObj <> nil then
    try
      Params := ParamsObj.ToJSON;
      { Modern (2026-07-28) requests declare their protocol version in
        params._meta on every request -- there is no handshake. ChildObject
        allocates a fresh wrapper; free it or every modern request leaks one. }
      MetaObj := ParamsObj.ChildObject('_meta');
      if MetaObj <> nil then
      try
        ReqVer := MetaObj.GetStr('io.modelcontextprotocol/protocolVersion', '');
      finally
        MetaObj.Free;
      end;
    finally
      ParamsObj.Free;
    end;
  finally
    Obj.Free;
  end;

  if Method = '' then
  begin
    Result := ErrorResponse(Id, -32600, 'invalid request: missing "method"');
    Exit;
  end;

  { Per-request version gate (modern era). A declared version we don't
    serve MUST get UnsupportedProtocolVersionError (-32022) listing what we
    do support, so the client can retry with a mutual version. Requests
    with no _meta version are legacy-era and flow through unchanged. }
  if (ReqVer <> '') and (ReqVer <> MCPServerProtocolModern)
     and (ReqVer <> MCPServerProtocolVersion) then
  begin
    { Streamable HTTP sends this JSON-RPC error with HTTP 400 so proxies /
      clients see a protocol failure, not a success. stdio ignores the hint. }
    HttpStatus := 400;
    Result := ErrorResponseData(Id, -32022, 'Unsupported protocol version',
      '{"supported":["' + MCPServerProtocolModern + '","' +
      MCPServerProtocolVersion + '"],"requested":"' + JsonEscape(ReqVer) + '"}');
    Exit;
  end;
  Modern := ReqVer = MCPServerProtocolModern;

  { Notifications: methods that start with "notifications/" carry no
    id, expect no response. Silence is the correct reply. }
  if (Id = 'null') and (Copy(Method, 1, Length('notifications/')) = 'notifications/') then
  begin
    LogDebug('mcp-server: notification %s', [Method]);
    Result := '';
    Exit;
  end;

  { Dual-era dispatch: server/discover + per-request _meta serve modern
    stateless clients; initialize keeps serving legacy (2024-11-05)
    handshake clients. tools/list & tools/call were stateless all along. }
  if      Method = 'initialize'      then Result := HandleInitialize(Params, Id)
  else if Method = 'server/discover' then Result := HandleDiscover(Id)
  else if Method = 'tools/list'      then Result := HandleToolsList(Id, Modern)
  else if Method = 'tools/call'      then Result := HandleToolsCall(Params, Id, Modern)
  else if Method = 'ping'            then Result := HandlePing(Id)
  else
    Result := ErrorResponse(Id, -32601, 'method not found: ' + Method);
end;

end.
