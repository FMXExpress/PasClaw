(*
  PasClaw.Cmd.Relay -- `pasclaw relay` worker client.

  Opens a long-lived SSE GET to a remote PasClaw gateway's
  /v1/relay/poll endpoint, pulls inference requests off the wire,
  dispatches each one through the locally-configured ILLMProvider, and
  POSTs the result back to /v1/relay/respond/<id>.

  This is the client side of the relay protocol -- the inverse of
  PasClaw.Providers.Relay (which enqueues requests on the gateway's
  in-process queue waiting for a worker to pick them up). A worker is
  just a PasClaw instance that has a real LLM behind it (Claude API
  key, local llama.cpp, whatever) lending that capacity to a separate
  gateway machine that doesn't.

  V1 scope -- intentionally thin:
    * Single-threaded. One SSE GET, one dispatch at a time. Slow
      models back-pressure the wire; queue accumulates on the
      gateway side, no data loss.
    * No tool execution on the worker. The gateway-side PasClaw owns
      the agent loop and dispatches tool calls; the worker is just
      "Provider.Chat() in a loop". Workers that run tools would
      double-dispatch.
    * Reconnect on drop with exponential backoff (1s -> 30s cap).
    * Bearer auth via PASCLAW_GATEWAY_TOKEN or --gateway-token flag.

  Usage:
    pasclaw relay [flags]

    --gateway-url URL    Remote PasClaw gateway base URL (e.g.
                         http://192.168.1.10:8888). Falls back to
                         PASCLAW_GATEWAY_URL env var.
    --gateway-token TOK  Bearer token for the gateway. Falls back to
                         PASCLAW_GATEWAY_TOKEN env var.
    --provider NAME      PasClaw provider to forward jobs through.
                         Defaults to the configured default provider.
                         Must not itself be a relay provider (refuses
                         on detection -- would loop forever).
    --model NAME         Capability the worker advertises (the model id
                         the gateway-side queue matches against).
                         Defaults to the provider's default model. Pass
                         '' (empty) for wildcard -- accept any model.
    --worker-id ID       Worker identity for the gateway's status
                         panel. Defaults to "<host>-<pid>".

  See docs/providers-relay.md for the wire protocol.
*)
unit PasClaw.Cmd.Relay;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  PasClaw.Providers.Types;

function Cmd_Relay_Run(const Argv: array of string): Integer;

(* Exposed for test coverage of the worker-side response envelope.
   Returns the JSON the worker POSTs to /v1/relay/respond/<id>. Any
   non-2xx upstream status (and the StatusCode=-1 socket-failure
   sentinel) becomes an "error" field so the gateway's DecodeResponse
   flips the relay response into the retryable-failure path -- without
   this, a 429/5xx upstream surfaced as the assistant's reply text
   and bypassed Cfg.Fallbacks. Codex P2 review on PR #323. *)
function BuildRelayWorkerResponseJSON(const R: TLLMResponse): string;

implementation

uses
  SysUtils, Classes, SyncObjs,
{$IFDEF FPC}
  {$IFDEF UNIX}cthreads,{$ENDIF}
{$ENDIF}
{$IF Defined(PASCLAW_NETHTTP) and not Defined(FPC)}
  System.Net.HttpClient, System.Net.URLClient,
{$ELSE}
  IdHTTP, IdSSLOpenSSL, IdException, IdExceptionCore,
{$IFEND}
  PasClaw.CliUI, PasClaw.Logger, PasClaw.Utils,
  PasClaw.JSON, PasClaw.Config,
  PasClaw.Providers.Intf, PasClaw.Providers.Factory,
  PasClaw.Providers.HTTP;

type
  TWorkerCtx = record
    GatewayURL: string;
    Token:      string;
    WorkerId:   string;
    Caps:       string;
    Provider:   ILLMProvider;
  end;
  PWorkerCtx = ^TWorkerCtx;

  (* TSSEStream: Indy writes response body bytes here as they arrive.
     We accumulate, scan for the SSE event delimiter (blank line --
     #10#10 or #13#10#13#10), and call Ctx.Provider.Chat() for each
     completed `data:` envelope. Dispatch is synchronous inside Write
     so the SSE socket back-pressures naturally. The destination
     stream isn't used for Read/Seek; we override them as no-ops since
     Indy never calls them on a GET destination. *)
  TSSEStream = class(TStream)
  private
    FBuf:   string;
    FCtx:   PWorkerCtx;
    procedure ProcessFrame(const Frame: string);
  public
    constructor Create(Ctx: PWorkerCtx);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(Offset: Longint; Origin: Word): Longint; override;
  end;

function EnvOr(const EnvName, FlagValue: string): string;
begin
  if FlagValue <> '' then Result := FlagValue
  else                    Result := GetEnvironmentVariable(EnvName);
end;

function HostName: string;
begin
  Result := GetEnvironmentVariable('HOSTNAME');
  if Result = '' then Result := GetEnvironmentVariable('COMPUTERNAME');
  if Result = '' then Result := 'worker';
end;

function StripTrailingSlash(const URL: string): string;
begin
  Result := URL;
  while (Result <> '') and (Result[Length(Result)] = '/') do
    SetLength(Result, Length(Result) - 1);
end;

function DecodeToolCalls(TCArr: TJsonArray): TToolCallArray;
var
  i: Integer;
  Obj, FObj: TJsonObject;
begin
  SetLength(Result, 0);
  if TCArr = nil then Exit;
  SetLength(Result, TCArr.Count);
  for i := 0 to TCArr.Count - 1 do
  begin
    Obj := TCArr.ItemObject(i);
    if Obj = nil then Continue;
    Result[i].Id   := Obj.GetStr('id', '');
    Result[i].Kind := Obj.GetStr('type', 'function');
    FObj := Obj.ChildObject('function');
    if FObj <> nil then
    begin
      Result[i].Func.Name      := FObj.GetStr('name', '');
      Result[i].Func.Arguments := FObj.GetStr('arguments', '{}');
    end;
  end;
end;

function DecodeMessages(MArr: TJsonArray): TMessageArray;
{ Round-trip the OpenAI-shape message fields BuildRelayRequestBody now
  emits: role + content + optional name + tool_call_id + tool_calls.
  Without these, a multi-turn relayed session that fires a tool call
  loses the tool-call/result correlation on its second turn and the
  forwarded Provider.Chat() fails with "missing tool_call_id" (OpenAI)
  / "tool_use_id not found" (Anthropic) / similar elsewhere. Codex P1
  review on PR #323. }
var
  i: Integer;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  if MArr = nil then Exit;
  SetLength(Result, MArr.Count);
  for i := 0 to MArr.Count - 1 do
  begin
    Obj := MArr.ItemObject(i);
    if Obj = nil then Continue;
    Result[i].Role       := MsgRoleFromString(Obj.GetStr('role', 'user'));
    Result[i].Content    := Obj.GetStr('content', '');
    Result[i].Name       := Obj.GetStr('name', '');
    Result[i].ToolCallId := Obj.GetStr('tool_call_id', '');
    Result[i].ToolCalls  := DecodeToolCalls(Obj.ChildArray('tool_calls'));
  end;
end;

function DecodeTools(TArr: TJsonArray): TToolDefinitionArray;
var
  i: Integer;
  Obj: TJsonObject;
begin
  SetLength(Result, 0);
  if TArr = nil then Exit;
  SetLength(Result, TArr.Count);
  for i := 0 to TArr.Count - 1 do
  begin
    Obj := TArr.ItemObject(i);
    if Obj = nil then Continue;
    Result[i].Name        := Obj.GetStr('name',        '');
    Result[i].Description := Obj.GetStr('description', '');
    { Schema is JSON; the envelope ships it as a string-containing-JSON
      under the parameters key (see BuildRelayRequestBody). Forward as-is
      -- the provider's request builder expects a JSON schema string. }
    Result[i].Schema      := Obj.GetStr('parameters',  '{}');
  end;
end;

function DecodeOptions(OObj: TJsonObject; const SessionId: string): TChatOptions;
var
  TempStr: string;
begin
  Result := DefaultChatOptions;
  if OObj <> nil then
  begin
    Result.MaxTokens    := Integer(OObj.GetInt('max_tokens', Result.MaxTokens));
    Result.SystemPrompt := OObj.GetStr('system_prompt', '');
    TempStr := OObj.GetStr('temperature', '');
    if TempStr <> '' then
      Result.Temperature := StrToFloatDef(TempStr, 0);
  end;
  { Thread the envelope's session_id back into Options.CacheKey so the
    locally-configured provider's own prompt caching aligns with the
    gateway-side session. Empty for one-shot turns. }
  Result.CacheKey := SessionId;
end;

function EncodeToolCalls(const Calls: TToolCallArray): TJsonArray;
var
  i: Integer;
  Obj, FObj: TJsonObject;
begin
  Result := TJsonArray.Create;
  for i := 0 to High(Calls) do
  begin
    Obj := TJsonObject.Create;
    Obj.PutStr('id',   Calls[i].Id);
    Obj.PutStr('type', Calls[i].Kind);
    FObj := TJsonObject.Create;
    FObj.PutStr('name',      Calls[i].Func.Name);
    FObj.PutStr('arguments', Calls[i].Func.Arguments);
    Obj.PutObject('function', FObj);
    Result.AddObject(Obj);
  end;
end;

function ResponseIsError(const R: TLLMResponse): Boolean; inline;
{ Any non-success outcome the worker should surface as a relay error
  rather than a "valid LLM reply." StatusCode = -1 is the pre-HTTP /
  socket / TLS failure path other providers use (network unreachable,
  DNS, etc.). StatusCode in [200..299] is a successful HTTP exchange.
  Anything else -- 4xx / 5xx returned by the upstream provider --
  must NOT be encoded as a normal completion: the gateway-side
  TRelayProvider.DecodeResponse reads `error` to flip StatusCode to
  -1, which is what triggers the agent loop's fallback-walk over
  Cfg.Fallbacks. Without this, a worker forwarding to a 429-rate-
  limited OpenAI key would surface the upstream error JSON to the
  agent as if it were the assistant's reply, killing fallback. Codex
  P2 review on PR #323. }
begin
  if R.StatusCode = -1 then Exit(True);
  if R.StatusCode = 0  then Exit(False);  { older providers that don't populate -- treat as success }
  Result := (R.StatusCode < 200) or (R.StatusCode >= 300);
end;

function BuildRelayWorkerResponseJSON(const R: TLLMResponse): string;
var
  Root, Usage: TJsonObject;
  TCArr: TJsonArray;
  ErrText: string;
begin
  Root := TJsonObject.Create;
  try
    if ResponseIsError(R) then
    begin
      if R.StatusCode = -1 then
        ErrText := R.Content
      else
        ErrText := Format('upstream HTTP %d: %s', [R.StatusCode, R.Content]);
      Root.PutStr('error', ErrText);
    end
    else
    begin
      Root.PutStr('content',       R.Content);
      Root.PutStr('finish_reason', R.FinishReason);
      Usage := TJsonObject.Create;
      Usage.PutInt('prompt_tokens',     R.Usage.InputTokens);
      Usage.PutInt('completion_tokens', R.Usage.OutputTokens);
      Root.PutObject('usage', Usage);
      if Length(R.ToolCalls) > 0 then
      begin
        TCArr := EncodeToolCalls(R.ToolCalls);
        Root.PutArray('tool_calls', TCArr);
      end;
    end;
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure PostResponse(const Ctx: TWorkerCtx; const ReqId, BodyJSON: string);
var
  Hdrs: array[0..0] of THeaderPair;
  Resp: THTTPResult;
  URL: string;
begin
  URL := StripTrailingSlash(Ctx.GatewayURL) + '/v1/relay/respond/' + ReqId;
  Hdrs[0] := MakeHeader('Authorization', 'Bearer ' + Ctx.Token);
  Resp := PostJSON(URL, BodyJSON, Hdrs, 60);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    LogWarn('relay worker: respond POST for %s got HTTP %d: %s',
            [ReqId, Resp.StatusCode, Resp.ErrorMsg + Resp.Body]);
end;

procedure DispatchEvent(const Ctx: TWorkerCtx; const Data: string);
var
  Env: TJsonObject;
  ReqId, Model, SessionId: string;
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  Resp:  TLLMResponse;
  RespJSON: string;
  StartTick: QWord;
begin
  Env := TJsonObject.Parse(Data);
  if Env = nil then
  begin
    LogWarn('relay worker: dropped event with unparseable JSON');
    Exit;
  end;
  try
    ReqId     := Env.GetStr('id',         '');
    Model     := Env.GetStr('model',      '');
    SessionId := Env.GetStr('session_id', '');
    Msgs      := DecodeMessages(Env.ChildArray('messages'));
    Tools     := DecodeTools   (Env.ChildArray('tools'));
    Opts      := DecodeOptions (Env.ChildObject('options'), SessionId);
  finally
    Env.Free;
  end;

  if ReqId = '' then
  begin
    LogWarn('relay worker: dropped event with empty id');
    Exit;
  end;

  LogInfo('relay worker: dispatching %s (model=%s, %d msgs, %d tools)',
          [ReqId, Model, Length(Msgs), Length(Tools)]);
  StartTick := GetTickCount64;
  try
    Resp := Ctx.Provider.Chat(Msgs, Tools, Model, Opts);
  except
    on E: Exception do
    begin
      LogWarn('relay worker: provider Chat raised for %s: %s', [ReqId, E.Message]);
      FillChar(Resp, SizeOf(Resp), 0);
      Resp.StatusCode := -1;
      Resp.Content    := '[worker error: ' + E.Message + ']';
    end;
  end;
  LogInfo('relay worker: completed %s in %dms (status=%d, %d in / %d out)',
          [ReqId, GetTickCount64 - StartTick, Resp.StatusCode,
           Resp.Usage.InputTokens, Resp.Usage.OutputTokens]);

  RespJSON := BuildRelayWorkerResponseJSON(Resp);
  PostResponse(Ctx, ReqId, RespJSON);
end;

{ ----- TSSEStream ----- }

constructor TSSEStream.Create(Ctx: PWorkerCtx);
begin
  inherited Create;
  FCtx := Ctx;
  FBuf := '';
end;

function TSSEStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TSSEStream.Seek(Offset: Longint; Origin: Word): Longint;
begin
  Result := 0;
end;

procedure TSSEStream.ProcessFrame(const Frame: string);
var
  Lines: TStringList;
  i: Integer;
  Line, DataAcc: string;
begin
  { An SSE frame may contain several `data:` lines that the receiver
    must join with newlines (per the EventSource spec). PasClaw's
    gateway emits a single `data:` line per event, but we follow the
    spec to be safe with future protocol additions. }
  DataAcc := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Frame;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];
      if Copy(Line, 1, 5) = 'data:' then
      begin
        if DataAcc <> '' then DataAcc := DataAcc + #10;
        DataAcc := DataAcc + Trim(Copy(Line, 6, MaxInt));
      end;
    end;
  finally
    Lines.Free;
  end;
  if DataAcc <> '' then
    DispatchEvent(FCtx^, DataAcc);
end;

function TSSEStream.Write(const Buffer; Count: Longint): Longint;
var
  Chunk: AnsiString;
  P: Integer;
  Frame: string;
begin
  Result := Count;
  if Count <= 0 then Exit;
  SetLength(Chunk, Count);
  Move(Buffer, Chunk[1], Count);
  FBuf := FBuf + string(Chunk);

  { Drain complete frames. SSE delimiter is a blank line: #10#10 (LF
    only) or #13#10#13#10 (CRLF). Normalise CRLF -> LF for the scan
    so we don't have to special-case both. }
  FBuf := StringReplace(FBuf, #13#10, #10, [rfReplaceAll]);
  repeat
    P := Pos(#10#10, FBuf);
    if P = 0 then Break;
    Frame := Copy(FBuf, 1, P - 1);
    Delete(FBuf, 1, P + 1);
    ProcessFrame(Frame);
  until False;
end;

{ ----- worker loop ----- }

function OpenSSEAndPump(const Ctx: TWorkerCtx; out ErrMsg: string): Boolean;
{$IF Defined(PASCLAW_NETHTTP) and not Defined(FPC)}
{ TNetHTTPClient path: not supported for V1. SSE through TNetHTTPClient
  requires its OnReceiveData callback, which has a different lifecycle.
  Surface a clear error so operators on the Delphi -DPASCLAW_NETHTTP
  build know to switch backends. }
begin
  ErrMsg := 'pasclaw relay worker requires the Indy HTTP backend; ' +
           'rebuild without -DPASCLAW_NETHTTP';
  Result := False;
end;
{$ELSE}
var
  Http: TIdHTTP;
  Stream: TSSEStream;
  SSL: TIdSSLIOHandlerSocketOpenSSL;
  URL: string;
  SSLErr: string;
begin
  Result := False;
  ErrMsg := '';
  URL := StripTrailingSlash(Ctx.GatewayURL) + '/v1/relay/poll';

  Http := TIdHTTP.Create(nil);
  try
    Http.ConnectTimeout := 15 * 1000;
    { Long-poll: idle time between events can be arbitrary. 0 = wait
      forever per Indy's convention. The outer Run loop catches drops
      and reconnects. }
    Http.ReadTimeout    := 0;
    Http.HandleRedirects := True;
    Http.Request.UserAgent := 'PasClaw-relay-worker/0.1';
    Http.Request.Accept    := 'text/event-stream';
    Http.Request.CustomHeaders.AddValue('Authorization',
                                         'Bearer ' + Ctx.Token);
    Http.Request.CustomHeaders.AddValue('X-Relay-Worker-Id', Ctx.WorkerId);
    if Ctx.Caps <> '' then
      Http.Request.CustomHeaders.AddValue('X-Relay-Capabilities', Ctx.Caps);

    if (Length(URL) >= 8) and SameText(Copy(URL, 1, 8), 'https://') then
    begin
      if not EnsureOpenSSL(SSLErr) then
      begin
        ErrMsg := SSLErr;
        Exit;
      end;
      SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Http);
      SSL.SSLOptions.Method      := sslvTLSv1_2;
      SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
      Http.IOHandler := SSL;
    end;

    Stream := TSSEStream.Create(@Ctx);
    try
      try
        Http.Get(URL, Stream);
        { Get returned without an exception -> server closed cleanly.
          Outer loop will reconnect. }
        Result := True;
      except
        on E: Exception do
        begin
          ErrMsg := E.Message;
          Result := False;
        end;
      end;
    finally
      Stream.Free;
    end;
  finally
    Http.Free;
  end;
end;
{$IFEND}

procedure RunWorkerLoop(const Ctx: TWorkerCtx);
var
  BackoffSec, Attempt: Integer;
  ErrMsg: string;
begin
  BackoffSec := 1;
  Attempt    := 0;
  while True do
  begin
    Inc(Attempt);
    LogInfo('relay worker: connecting to %s (attempt %d, id=%s, caps=%s)',
            [Ctx.GatewayURL, Attempt, Ctx.WorkerId, Ctx.Caps]);

    if OpenSSEAndPump(Ctx, ErrMsg) then
    begin
      LogInfo('relay worker: SSE stream closed cleanly; reconnecting');
      BackoffSec := 1;
    end
    else
    begin
      LogWarn('relay worker: SSE error: %s', [ErrMsg]);
    end;

    LogInfo('relay worker: reconnecting in %ds', [BackoffSec]);
    Sleep(BackoffSec * 1000);
    BackoffSec := BackoffSec * 2;
    if BackoffSec > 30 then BackoffSec := 30;
  end;
end;

{ ----- CLI ----- }

procedure PrintRelayHelp;
begin
  PrintLn('Usage: pasclaw relay [flags]');
  PrintLn('');
  PrintLn('Connects to a remote PasClaw gateway''s /v1/relay/poll, pulls inference');
  PrintLn('requests, and forwards them through the locally-configured provider.');
  PrintLn('');
  PrintLn('Flags:');
  PrintLn('  --gateway-url URL      Remote gateway base URL (or PASCLAW_GATEWAY_URL)');
  PrintLn('  --gateway-token TOK    Bearer token       (or PASCLAW_GATEWAY_TOKEN)');
  PrintLn('  --provider NAME        Provider to forward to (default: configured default)');
  PrintLn('  --model NAME           Capability to advertise (default: provider default;');
  PrintLn('                         pass empty string for wildcard)');
  PrintLn('  --worker-id ID         Worker identity (default: <host>-<pid>)');
  PrintLn('  -h, --help             Show this help');
end;

function ResolveProvider(Cfg: TConfig; const ProviderName: string;
                          out Provider: ILLMProvider; out ErrMsg: string;
                          out ResolvedKind, ResolvedName: string): Boolean;
var
  EffName: string;
  i: Integer;
begin
  Result := False;
  Provider := nil;
  EffName := ProviderName;
  if EffName = '' then EffName := Cfg.DefaultProvider;
  if EffName = '' then
  begin
    ErrMsg := 'no provider configured -- run `pasclaw onboard` or pass --provider';
    Exit;
  end;

  ResolvedName := EffName;
  ResolvedKind := '';
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, EffName) then
    begin
      ResolvedKind := NormalizeProviderKind(Cfg.Providers[i].Kind);
      if ResolvedKind = '' then
        ResolvedKind := NormalizeProviderKind(Cfg.Providers[i].Name);
      Break;
    end;

  { Refuse a relay-on-relay loop. If the worker forwarded to a relay
    provider, the request would be re-enqueued back into the same
    gateway's queue and immediately polled back -- infinite loop. }
  if ResolvedKind = 'relay' then
  begin
    ErrMsg := 'provider "' + EffName + '" is itself a relay provider -- ' +
              'refusing to forward (would loop). Pass --provider with a real ' +
              'LLM-backed provider (anthropic / openai / gemini / ...).';
    Exit;
  end;

  Result := NewProviderFromConfig(Cfg, EffName, Provider, ErrMsg);
end;

function GetArgValue(const Argv: array of string; const Flag: string;
                      out Value: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  Value := '';
  for i := 0 to High(Argv) - 1 do
    if Argv[i] = Flag then
    begin
      Value := Argv[i + 1];
      Result := True;
      Exit;
    end;
end;

function HasFlag(const Argv: array of string; const Flag: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Argv) do
    if Argv[i] = Flag then Exit(True);
  Result := False;
end;

function Cmd_Relay_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Ctx: TWorkerCtx;
  ProviderName, ModelArg, WorkerIdArg, ErrMsg: string;
  ModelExplicit: Boolean;
  ResolvedKind, ResolvedName: string;
begin
  if HasFlag(Argv, '-h') or HasFlag(Argv, '--help') then
  begin
    PrintRelayHelp;
    Exit(0);
  end;

  GetArgValue(Argv, '--gateway-url',   Ctx.GatewayURL);
  GetArgValue(Argv, '--gateway-token', Ctx.Token);
  GetArgValue(Argv, '--provider',      ProviderName);
  ModelExplicit := GetArgValue(Argv, '--model',    ModelArg);
  GetArgValue(Argv, '--worker-id',     WorkerIdArg);

  Ctx.GatewayURL := EnvOr('PASCLAW_GATEWAY_URL',   Ctx.GatewayURL);
  Ctx.Token      := EnvOr('PASCLAW_GATEWAY_TOKEN', Ctx.Token);

  if Ctx.GatewayURL = '' then
  begin
    PrintErr(FormatCLIError(
      'missing --gateway-url (or PASCLAW_GATEWAY_URL env)',
      'pasclaw relay'));
    Exit(1);
  end;
  if Ctx.Token = '' then
  begin
    PrintErr(FormatCLIError(
      'missing --gateway-token (or PASCLAW_GATEWAY_TOKEN env)',
      'pasclaw relay'));
    Exit(1);
  end;

  Cfg := LoadConfig;
  try
    if not ResolveProvider(Cfg, ProviderName, Ctx.Provider, ErrMsg,
                            ResolvedKind, ResolvedName) then
    begin
      PrintErr(FormatCLIError(ErrMsg, 'pasclaw relay'));
      Exit(1);
    end;

    if ModelExplicit then
      Ctx.Caps := ModelArg
    else
      Ctx.Caps := Ctx.Provider.GetDefaultModel;

    if WorkerIdArg <> '' then
      Ctx.WorkerId := WorkerIdArg
    else
      Ctx.WorkerId := HostName + '-' + IntToStr(GetProcessID);

    PrintLn(Ansi.Bold + 'pasclaw relay worker' + Ansi.Reset);
    PrintLn('  gateway        : ' + Ctx.GatewayURL);
    PrintLn('  provider       : ' + ResolvedName + ' (kind=' + ResolvedKind + ')');
    if Ctx.Caps = '' then
      PrintLn('  advertised caps: (wildcard -- accepting any model)')
    else
      PrintLn('  advertised caps: ' + Ctx.Caps);
    PrintLn('  worker id      : ' + Ctx.WorkerId);
    PrintLn('');
    PrintLn('Polling for jobs. Ctrl-C to stop.');

    RunWorkerLoop(Ctx);   { blocks forever; exits via Ctrl-C }
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
