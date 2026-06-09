(*
  PasClaw.MCP.OAuth - OAuth 2.1 + PKCE flow for remote MCP servers
  that follow the MCP Authorization spec
  (https://modelcontextprotocol.io/specification/2025-03-26/basic/authorization).

  Replicate's mcp.replicate.com is the motivating case: every request
  comes back with `WWW-Authenticate: Bearer realm="OAuth"`, and the
  server publishes RFC 9728 protected-resource metadata + RFC 8414
  authorization-server metadata, supports RFC 7591 dynamic client
  registration with `"none"` auth (public client), and only accepts
  access tokens issued by its own /authorize → /token flow with PKCE.

  Flow:
    1. GET <mcp-url>/.well-known/oauth-protected-resource -- find the
       authorization_servers list.
    2. GET <auth-server>/.well-known/oauth-authorization-server --
       discover the authorization, token, and (optional) registration
       endpoints.
    3. If no client_id stored, POST to registration_endpoint as a
       public client with the loopback redirect_uri. Persist the
       returned client_id.
    4. Generate a 64-byte URL-safe code_verifier, derive
       code_challenge = BASE64URL(SHA256(verifier)), and a 32-byte
       state nonce.
    5. Stand up a one-shot TIdHTTPServer on a free loopback port,
       then shell-out the browser to the authorize URL.
    6. Browser → user consents → server redirects to
       http://127.0.0.1:<port>/cb?code=...&state=...; the loopback
       server captures code+state and unblocks the wait.
    7. POST the code + verifier to token_endpoint, get back access
       + refresh tokens.
    8. Persist tokens to <home>/.pasclaw/oauth/<server-name>.json
       (mode 0600 on POSIX) and refresh on demand.

  The HTTP MCP client (PasClaw.MCP.HttpClient) calls GetAccessToken at
  request time. If the access token is about to expire and we have a
  refresh token, RefreshAccessToken silently rotates. If refresh
  fails or there's no refresh token, the caller gets '' and surfaces
  "auth required, run `pasclaw mcp auth <name>`".
*)
unit PasClaw.MCP.OAuth;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TOAuthTokens = record
    AccessToken:  string;
    RefreshToken: string;
    TokenType:    string;
    ExpiresAtUnix: Int64;     { Unix seconds; 0 = no expiry known }
    Scope:        string;
    ClientId:     string;
    Issuer:       string;
    AuthEndpoint: string;
    TokenEndpoint: string;
    RegEndpoint:  string;
    { Canonical resource URI from the protected-resource metadata.
      Sent as the RFC 8707 `resource` parameter on every /authorize
      and /token call so the issued access token is audience-scoped
      to the MCP server. Without it Replicate's auth server hands
      back a token whose MCP endpoint rejects as "Invalid token
      format" -- the symptom that motivated PR #138. }
    Resource:     string;
  end;

{ Run the full interactive flow for ServerName (the MCP entry name,
  used to derive the token-store path) against ServerURL (the MCP
  server's base URL, used for protected-resource discovery). Opens
  a browser tab and blocks until the loopback callback fires or the
  timeout elapses. Returns False with ErrMsg populated on failure. }
function RunOAuthFlow(const ServerName, ServerURL: string;
                      out ErrMsg: string): Boolean;

{ Returns the current access token for ServerName, refreshing it
  silently if it's within RefreshSlackSeconds of expiring and we have
  a refresh token. Returns '' if no tokens are stored yet (caller
  should prompt the user to run `pasclaw mcp auth <name>`) or if a
  refresh attempt failed. }
function GetAccessToken(const ServerName: string;
                        RefreshSlackSeconds: Integer = 60): string;

{ Force a refresh regardless of expiry. Used by the HTTP client when
  it sees a 401 with `WWW-Authenticate: Bearer` -- the stored token
  may have been revoked or scope-rotated server-side. }
function ForceRefresh(const ServerName: string; out ErrMsg: string): Boolean;

{ Path the tokens for ServerName live at. Useful for `mcp show` and
  for telling the user where to delete the file if revoke is needed. }
function OAuthTokenPath(const ServerName: string): string;

{ True if a token file exists (regardless of expiry). Cheap predicate
  used by the CLI to print "(authorized)" vs "(needs auth)". }
function HasStoredTokens(const ServerName: string): Boolean;

implementation

uses
  DateUtils,
  IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal, IdSocketHandle,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Platform,
  PasClaw.Providers.HTTP,
  PasClaw.Crypto.HMAC,
  PasClaw.Crypto.Random;

function NowUnix: Int64;
{ Unix seconds, UTC. Avoids DateUtils.DateTimeToUnix which has subtly
  different signatures between FPC and Delphi modern. Local→UTC and
  the 1970 epoch conversion are done by hand. }
const
  UnixDelta = 25569.0;  { TDateTime value of 1970-01-01 00:00 UTC }
var
  T: TDateTime;
begin
  {$IFDEF FPC}
  T := LocalTimeToUniversal(Now);
  {$ELSE}
  T := TTimeZone.Local.ToUniversalTime(Now);
  {$ENDIF}
  Result := Round((T - UnixDelta) * 86400);
end;

const
  PkceVerifierBytes = 64;     { 64 → 86-char Base64URL string, within RFC 7636 43..128 }
  StateBytes        = 32;
  AuthFlowTimeoutMs = 180 * 1000;  { user has 3 minutes to consent }

{ ---------- Base64URL ---------------------------------------------- }

function BytesToBase64URL(const B: TBytes): string;
const
  Alpha = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
var
  i, N, V: Integer;
  Sb: TStringBuilder;
begin
  N := Length(B);
  Sb := TStringBuilder.Create;
  try
    i := 0;
    while i + 3 <= N do
    begin
      V := (B[i] shl 16) or (B[i+1] shl 8) or B[i+2];
      Sb.Append(Alpha[(V shr 18) and $3F + 1]);
      Sb.Append(Alpha[(V shr 12) and $3F + 1]);
      Sb.Append(Alpha[(V shr 6)  and $3F + 1]);
      Sb.Append(Alpha[ V         and $3F + 1]);
      Inc(i, 3);
    end;
    if i + 1 = N then
    begin
      V := B[i] shl 16;
      Sb.Append(Alpha[(V shr 18) and $3F + 1]);
      Sb.Append(Alpha[(V shr 12) and $3F + 1]);
    end
    else if i + 2 = N then
    begin
      V := (B[i] shl 16) or (B[i+1] shl 8);
      Sb.Append(Alpha[(V shr 18) and $3F + 1]);
      Sb.Append(Alpha[(V shr 12) and $3F + 1]);
      Sb.Append(Alpha[(V shr 6)  and $3F + 1]);
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

{ ---------- Token persistence ------------------------------------- }

function OAuthTokenPath(const ServerName: string): string;
begin
  Result := JoinPath(JoinPath(GetHome, 'oauth'), ServerName + '.json');
end;

function HasStoredTokens(const ServerName: string): Boolean;
begin
  Result := FileExists(OAuthTokenPath(ServerName));
end;

function LoadTokens(const ServerName: string; out Tok: TOAuthTokens;
                    out ErrMsg: string): Boolean;
var
  Path: string;
  L: TStringList;
  Obj: TJsonObject;
begin
  Result := False;
  ErrMsg := '';
  Tok := Default(TOAuthTokens);
  Path := OAuthTokenPath(ServerName);
  if not FileExists(Path) then
  begin
    ErrMsg := 'no stored tokens at ' + Path;
    Exit;
  end;
  L := TStringList.Create;
  try
    L.LoadFromFile(Path);
    Obj := TJsonObject.Parse(L.Text);
    if Obj = nil then
    begin
      ErrMsg := 'unparseable token file at ' + Path;
      Exit;
    end;
    try
      Tok.AccessToken    := Obj.GetStr('access_token',   '');
      Tok.RefreshToken   := Obj.GetStr('refresh_token',  '');
      Tok.TokenType      := Obj.GetStr('token_type',     'Bearer');
      Tok.Scope          := Obj.GetStr('scope',          '');
      Tok.ClientId       := Obj.GetStr('client_id',      '');
      Tok.Issuer         := Obj.GetStr('issuer',         '');
      Tok.AuthEndpoint   := Obj.GetStr('auth_endpoint',  '');
      Tok.TokenEndpoint  := Obj.GetStr('token_endpoint', '');
      Tok.RegEndpoint    := Obj.GetStr('reg_endpoint',   '');
      Tok.Resource       := Obj.GetStr('resource',       '');
      Tok.ExpiresAtUnix  := Obj.GetInt('expires_at_unix', 0);
    finally
      Obj.Free;
    end;
    Result := True;
  finally
    L.Free;
  end;
end;

procedure SaveTokens(const ServerName: string; const Tok: TOAuthTokens);
var
  Path, Dir: string;
  Obj: TJsonObject;
  L: TStringList;
begin
  Path := OAuthTokenPath(ServerName);
  Dir  := ExtractFilePath(Path);
  if Dir <> '' then ForceDirectories(Dir);
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('access_token',   Tok.AccessToken);
    if Tok.RefreshToken <> '' then Obj.PutStr('refresh_token', Tok.RefreshToken);
    Obj.PutStr('token_type',     Tok.TokenType);
    Obj.PutStr('scope',          Tok.Scope);
    Obj.PutStr('client_id',      Tok.ClientId);
    Obj.PutStr('issuer',         Tok.Issuer);
    Obj.PutStr('auth_endpoint',  Tok.AuthEndpoint);
    Obj.PutStr('token_endpoint', Tok.TokenEndpoint);
    Obj.PutStr('reg_endpoint',   Tok.RegEndpoint);
    Obj.PutStr('resource',       Tok.Resource);
    if Tok.ExpiresAtUnix > 0 then
      Obj.PutInt('expires_at_unix', Tok.ExpiresAtUnix);
    L := TStringList.Create;
    try
      L.Text := Obj.ToJSON;
      L.SaveToFile(Path);
    finally
      L.Free;
    end;
  finally
    Obj.Free;
  end;
end;

{ ---------- Discovery --------------------------------------------- }

function StripTrailingSlash(const S: string): string;
begin
  if (S <> '') and (S[Length(S)] = '/') then
    Result := Copy(S, 1, Length(S) - 1)
  else
    Result := S;
end;

procedure SplitOriginAndPath(const ServerURL: string;
                              out Origin, ResourcePath: string);
{ For "https://mcp.replicate.com/mcp" returns
    Origin       = "https://mcp.replicate.com"
    ResourcePath = "/mcp"
  Origin is empty if ServerURL doesn't have a scheme. ResourcePath is
  empty (not "/") when the URL had no path, so callers can distinguish
  "resource is at the origin" from "resource is at /". }
var
  i: Integer;
  Scheme, Rest: string;
begin
  Origin       := '';
  ResourcePath := '';
  i := Pos('://', ServerURL);
  if i = 0 then Exit;
  Scheme := Copy(ServerURL, 1, i + 2);
  Rest   := Copy(ServerURL, i + 3, MaxInt);
  i := Pos('/', Rest);
  if i > 0 then
  begin
    Origin := Scheme + Copy(Rest, 1, i - 1);
    { Drop a lone "/" -- RFC 9728 treats no path the same as path "/",
      and the well-known URL omits the trailing slash in both cases. }
    if (i < Length(Rest)) or False then
      ResourcePath := Copy(Rest, i, MaxInt)
    else
      ResourcePath := '';
  end
  else
    Origin := Scheme + Rest;
  if ResourcePath = '/' then ResourcePath := '';
end;

function ProtectedResourceMetadataURLs(const ServerURL: string): TArray<string>;
{ RFC 9728 §3.1: the well-known string is inserted between authority
  and path, so for "https://host/p1/p2" the metadata lives at
  "https://host/.well-known/oauth-protected-resource/p1/p2".
  Some implementations (Replicate today) only publish at the origin
  level, so we try the path-scoped URL first and fall back to the
  origin-only URL on 404. }
var
  Origin, Path: string;
begin
  SplitOriginAndPath(ServerURL, Origin, Path);
  if (Origin <> '') and (Path <> '') then
  begin
    SetLength(Result, 2);
    Result[0] := Origin + '/.well-known/oauth-protected-resource' + Path;
    Result[1] := Origin + '/.well-known/oauth-protected-resource';
  end
  else
  begin
    SetLength(Result, 1);
    Result[0] := Origin + '/.well-known/oauth-protected-resource';
  end;
end;

function DiscoverEndpoints(const ServerURL: string;
                           out AuthEndpoint, TokenEndpoint, RegEndpoint,
                               Issuer, Resource: string;
                           out ErrMsg: string): Boolean;
var
  Urls: TArray<string>;
  AuthServer: string;
  PrResult, AsResult: THTTPResult;
  Obj, AsObj: TJsonObject;
  AuthServers: TJsonArray;
  Empty: array of THeaderPair;
  i: Integer;
begin
  Result := False;
  ErrMsg := '';
  AuthEndpoint  := '';
  TokenEndpoint := '';
  RegEndpoint   := '';
  Issuer        := '';
  Resource      := '';
  SetLength(Empty, 0);

  Urls := ProtectedResourceMetadataURLs(ServerURL);
  PrResult.StatusCode := 0;
  PrResult.Body       := '';
  PrResult.ErrorMsg   := '';
  for i := 0 to High(Urls) do
  begin
    PrResult := GetJSONURL(Urls[i], Empty, 15);
    if PrResult.ErrorMsg <> '' then
    begin
      ErrMsg := 'protected-resource discovery failed: ' + PrResult.ErrorMsg;
      Exit;
    end;
    if (PrResult.StatusCode >= 200) and (PrResult.StatusCode < 300) then Break;
    { Path-scoped URL didn't exist → try the origin-only fallback (next
      iteration). Any non-404 server error is treated as fatal. }
    if (PrResult.StatusCode <> 404) or (i = High(Urls)) then
    begin
      ErrMsg := Format('protected-resource discovery returned HTTP %d at %s',
                       [PrResult.StatusCode, Urls[i]]);
      Exit;
    end;
  end;
  AuthServer := '';
  Obj := TJsonObject.Parse(PrResult.Body);
  if Obj = nil then
  begin
    ErrMsg := 'protected-resource doc not JSON';
    Exit;
  end;
  try
    { Canonical resource URI -- RFC 9728 §3.2. Fall back to the
      MCP server URL if absent so we always have something to feed
      RFC 8707; Replicate populates it as e.g. "https://mcp.replicate.com/". }
    Resource := Obj.GetStr('resource', ServerURL);
    AuthServers := Obj.ChildArray('authorization_servers');
    if (AuthServers <> nil) and (AuthServers.Count > 0) then
    try
      AuthServer := StripTrailingSlash(AuthServers.ItemStr(0, ''));
    finally
      AuthServers.Free;
    end;
  finally
    Obj.Free;
  end;
  if AuthServer = '' then
  begin
    ErrMsg := 'protected-resource doc missing authorization_servers';
    Exit;
  end;

  AsResult := GetJSONURL(AuthServer + '/.well-known/oauth-authorization-server',
                         Empty, 15);
  if AsResult.ErrorMsg <> '' then
  begin
    ErrMsg := 'auth-server discovery failed: ' + AsResult.ErrorMsg;
    Exit;
  end;
  if (AsResult.StatusCode < 200) or (AsResult.StatusCode >= 300) then
  begin
    ErrMsg := Format('auth-server discovery returned HTTP %d', [AsResult.StatusCode]);
    Exit;
  end;
  AsObj := TJsonObject.Parse(AsResult.Body);
  if AsObj = nil then
  begin
    ErrMsg := 'auth-server doc not JSON';
    Exit;
  end;
  try
    Issuer        := AsObj.GetStr('issuer', AuthServer);
    AuthEndpoint  := AsObj.GetStr('authorization_endpoint', '');
    TokenEndpoint := AsObj.GetStr('token_endpoint', '');
    RegEndpoint   := AsObj.GetStr('registration_endpoint', '');
  finally
    AsObj.Free;
  end;
  if (AuthEndpoint = '') or (TokenEndpoint = '') then
  begin
    ErrMsg := 'auth-server doc missing required endpoints';
    Exit;
  end;
  Result := True;
end;

{ ---------- Dynamic Client Registration (RFC 7591) ---------------- }

function RegisterClient(const RegEndpoint, RedirectURI: string;
                        out ClientId: string; out ErrMsg: string): Boolean;
var
  Body: string;
  Resp: THTTPResult;
  RObj: TJsonObject;
  Empty: array of THeaderPair;
begin
  Result := False;
  ErrMsg := '';
  ClientId := '';
  SetLength(Empty, 0);
  Body :=
    '{"client_name":"PasClaw",' +
    '"redirect_uris":["' + RedirectURI + '"],' +
    '"grant_types":["authorization_code","refresh_token"],' +
    '"response_types":["code"],' +
    '"token_endpoint_auth_method":"none"}';
  Resp := PostRaw(RegEndpoint, 'application/json', Body, Empty, 15, '', 'application/json');
  if Resp.ErrorMsg <> '' then
  begin
    ErrMsg := 'registration failed: ' + Resp.ErrorMsg;
    Exit;
  end;
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('registration returned HTTP %d: %s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;
  RObj := TJsonObject.Parse(Resp.Body);
  if RObj = nil then
  begin
    ErrMsg := 'registration response not JSON';
    Exit;
  end;
  try
    ClientId := RObj.GetStr('client_id', '');
  finally
    RObj.Free;
  end;
  if ClientId = '' then
  begin
    ErrMsg := 'registration response missing client_id';
    Exit;
  end;
  Result := True;
end;

{ ---------- URL form encoding ------------------------------------- }

function FormEncode(const S: string): string;
var
  i: Integer;
  B: TBytes;
  C: Byte;
begin
  Result := '';
  B := TEncoding.UTF8.GetBytes(S);
  for i := 0 to High(B) do
  begin
    C := B[i];
    if ((C >= Ord('A')) and (C <= Ord('Z'))) or
       ((C >= Ord('a')) and (C <= Ord('z'))) or
       ((C >= Ord('0')) and (C <= Ord('9'))) or
       (C = Ord('-')) or (C = Ord('_')) or (C = Ord('.')) or (C = Ord('~')) then
      Result := Result + Chr(C)
    else
      Result := Result + '%' + IntToHex(C, 2);
  end;
end;

{ ---------- Loopback callback server ------------------------------ }

type
  TCallbackResult = record
    Code:  string;
    State: string;
    Error: string;
  end;

  TLoopbackServer = class
  private
    FHttp: TIdHTTPServer;
    FResult: TCallbackResult;
    FGot:    Boolean;
    procedure HandleCommandGet(AContext: TIdContext;
                                ARequest: TIdHTTPRequestInfo;
                                AResponse: TIdHTTPResponseInfo);
  public
    ExpectedState: string;  { caller sets this once after Create, before
                              StartOnFreePort, so the handler can validate
                              the redirect's state nonce. }
    constructor Create;
    destructor  Destroy; override;
    function  StartOnFreePort: Integer;
    function  WaitForCallback(TimeoutMs: Integer): Boolean;
    property  Got: Boolean read FGot;
    property  CallbackResult: TCallbackResult read FResult;
  end;

constructor TLoopbackServer.Create;
begin
  inherited Create;
  ExpectedState := '';
  FGot := False;
  FHttp := TIdHTTPServer.Create(nil);
  FHttp.OnCommandGet := HandleCommandGet;
end;

destructor TLoopbackServer.Destroy;
begin
  try if FHttp.Active then FHttp.Active := False; except end;
  FHttp.Free;
  inherited Destroy;
end;

function TLoopbackServer.StartOnFreePort: Integer;
var
  Binding: TIdSocketHandle;
begin
  FHttp.Bindings.Clear;
  Binding := FHttp.Bindings.Add;
  Binding.IP   := '127.0.0.1';
  Binding.Port := 0;     { ask the OS for a free port }
  FHttp.Active := True;
  Result := FHttp.Bindings[0].Port;
end;

procedure TLoopbackServer.HandleCommandGet(AContext: TIdContext;
                                            ARequest: TIdHTTPRequestInfo;
                                            AResponse: TIdHTTPResponseInfo);
var
  Code, State, Err: string;
begin
  if ARequest.Document <> '/cb' then
  begin
    AResponse.ResponseNo := 404;
    AResponse.ContentText := 'not found';
    Exit;
  end;
  Code  := ARequest.Params.Values['code'];
  State := ARequest.Params.Values['state'];
  Err   := ARequest.Params.Values['error'];
  if Err <> '' then
  begin
    FResult.Error := Err + ': ' + ARequest.Params.Values['error_description'];
    AResponse.ResponseNo  := 200;
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.ContentText :=
      'PasClaw: authorization failed (' + Err + '). You can close this tab.';
    FGot := True;
    Exit;
  end;
  if State <> ExpectedState then
  begin
    FResult.Error := 'state mismatch -- possible CSRF; refusing';
    AResponse.ResponseNo  := 400;
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.ContentText := FResult.Error;
    FGot := True;
    Exit;
  end;
  FResult.Code  := Code;
  FResult.State := State;
  AResponse.ResponseNo  := 200;
  AResponse.ContentType := 'text/html; charset=utf-8';
  AResponse.ContentText :=
    '<html><body style="font:14px sans-serif;padding:2em">' +
    '<h2>PasClaw: authorization received.</h2>' +
    '<p>You can close this tab and return to the terminal.</p>' +
    '</body></html>';
  FGot := True;
end;

function TLoopbackServer.WaitForCallback(TimeoutMs: Integer): Boolean;
var
  Waited: Integer;
begin
  Waited := 0;
  while (not FGot) and (Waited < TimeoutMs) do
  begin
    Sleep(100);
    Inc(Waited, 100);
  end;
  Result := FGot;
end;

{ ---------- Browser open ------------------------------------------ }

{$IFDEF MSWINDOWS}
{ Direct ShellExecuteW import -- going through `cmd /C start ...`
  mangles every percent-encoded character in the authorize URL
  because cmd interprets `%NAME%` (and even partial `%NN` runs in
  some parsing modes) as environment-variable expansion. Codex
  caught this on PR #138 after the original cmd-nesting fix. Using
  the Windows shell API directly skips cmd entirely. }
const
  SW_SHOWNORMAL_ = 1;
function ShellExecuteW(hwnd: NativeUInt;
                       lpOperation, lpFile, lpParameters, lpDirectory: PWideChar;
                       nShowCmd: Integer): NativeUInt; stdcall;
  external 'shell32.dll' name 'ShellExecuteW';
{$ENDIF}

procedure OpenBrowser(const URL: string);
{$IFDEF MSWINDOWS}
var
  Rc: NativeUInt;
  UrlW: UnicodeString;
begin
  UrlW := UnicodeString(URL);
  Rc := ShellExecuteW(0, 'open', PWideChar(UrlW), nil, nil, SW_SHOWNORMAL_);
  if Rc <= 32 then
    LogWarn('OAuth: ShellExecuteW failed (rc=%d); paste this URL manually: %s',
            [Integer(Rc), URL]);
end;
{$ELSE}
var
  Cmd, Discard: string;
begin
  {$IFDEF DARWIN}
  Cmd := 'open ' + '"' + URL + '"';
  {$ELSE}
  Cmd := 'xdg-open ' + '"' + URL + '"';
  {$ENDIF}
  try
    RunOneShot(Cmd, Discard);
  except
    on E: Exception do
      LogWarn('OAuth: failed to open browser (%s); paste this URL manually: %s',
              [E.Message, URL]);
  end;
end;
{$ENDIF}

{ ---------- Token endpoint POST ----------------------------------- }

function PostToken(const TokenEndpoint, Form: string;
                   out RespBody: string; out StatusCode: Integer;
                   out ErrMsg: string): Boolean;
var
  Resp: THTTPResult;
  Empty: array of THeaderPair;
begin
  SetLength(Empty, 0);
  Resp := PostRaw(TokenEndpoint, 'application/x-www-form-urlencoded',
                  Form, Empty, 30, '', 'application/json');
  StatusCode := Resp.StatusCode;
  ErrMsg     := Resp.ErrorMsg;
  RespBody   := Resp.Body;
  Result     := (Resp.ErrorMsg = '') and (Resp.StatusCode >= 200) and
                (Resp.StatusCode < 300);
end;

function ParseTokenResponse(const Body: string; var Tok: TOAuthTokens;
                            out ErrMsg: string): Boolean;
var
  Obj: TJsonObject;
  ExpiresIn: Integer;
begin
  Result := False;
  ErrMsg := '';
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then
  begin
    ErrMsg := 'token response not JSON: ' + Copy(Body, 1, 200);
    Exit;
  end;
  try
    Tok.AccessToken := Obj.GetStr('access_token', '');
    if Tok.AccessToken = '' then
    begin
      ErrMsg := 'token response missing access_token: ' + Copy(Body, 1, 200);
      Exit;
    end;
    if Obj.GetStr('refresh_token', '') <> '' then
      Tok.RefreshToken := Obj.GetStr('refresh_token', Tok.RefreshToken);
    Tok.TokenType := Obj.GetStr('token_type', 'Bearer');
    if Obj.GetStr('scope', '') <> '' then
      Tok.Scope := Obj.GetStr('scope', Tok.Scope);
    ExpiresIn := Obj.GetInt('expires_in', 0);
    if ExpiresIn > 0 then
      Tok.ExpiresAtUnix := NowUnix + ExpiresIn
    else
      Tok.ExpiresAtUnix := 0;
  finally
    Obj.Free;
  end;
  Result := True;
end;

{ ---------- High-level entry points ------------------------------- }

function RunOAuthFlow(const ServerName, ServerURL: string;
                      out ErrMsg: string): Boolean;
var
  Auth, TokenEp, RegEp, Issuer, Resource: string;
  NewTok: TOAuthTokens;
  ClientId, Verifier, Challenge, State, RedirectURI: string;
  VerBytes, ChalBytes, StateBytesB: TBytes;
  Server: TLoopbackServer;
  Port: Integer;
  AuthorizeURL, Form, RespBody: string;
  Status: Integer;
begin
  Result := False;
  ErrMsg := '';

  if not DiscoverEndpoints(ServerURL, Auth, TokenEp, RegEp, Issuer, Resource, ErrMsg) then
    Exit;

  Server := TLoopbackServer.Create;
  try
    Port := Server.StartOnFreePort;
    RedirectURI := Format('http://127.0.0.1:%d/cb', [Port]);

    { Register a fresh public client on every auth run. The redirect_uri
      is pinned at registration time; reusing a prior client_id with a
      different ephemeral loopback port would fail server-side
      redirect_uri-match validation. Re-registering is cheap for
      RFC 7591 public clients (no secret, anonymous identity). }
    if RegEp = '' then
    begin
      ErrMsg := 'no client_id available -- auth server does not expose registration_endpoint';
      Exit;
    end;
    if not RegisterClient(RegEp, RedirectURI, ClientId, ErrMsg) then Exit;

    VerBytes    := GetRandomBytes(PkceVerifierBytes);
    Verifier    := BytesToBase64URL(VerBytes);
    ChalBytes   := SHA256Bytes(TEncoding.ASCII.GetBytes(Verifier));
    Challenge   := BytesToBase64URL(ChalBytes);
    StateBytesB := GetRandomBytes(StateBytes);
    State       := BytesToBase64URL(StateBytesB);
    Server.ExpectedState := State;

    AuthorizeURL :=
      Auth +
      '?response_type=code' +
      '&client_id='     + FormEncode(ClientId) +
      '&redirect_uri='  + FormEncode(RedirectURI) +
      '&state='         + FormEncode(State) +
      '&code_challenge=' + FormEncode(Challenge) +
      '&code_challenge_method=S256';
    { RFC 8707 + MCP Authorization spec: pin the access token to
      the MCP resource so the protected resource accepts it. Without
      this Replicate's auth server hands back a token whose
      /mcp endpoint rejects with "Invalid token format". }
    if Resource <> '' then
      AuthorizeURL := AuthorizeURL + '&resource=' + FormEncode(Resource);

    WriteLn('Opening browser to authorize PasClaw with ', ServerName, ':');
    WriteLn('  ', AuthorizeURL);
    OpenBrowser(AuthorizeURL);
    WriteLn('Waiting for callback on ', RedirectURI, ' (up to ',
            AuthFlowTimeoutMs div 1000, 's)...');

    if not Server.WaitForCallback(AuthFlowTimeoutMs) then
    begin
      ErrMsg := 'timed out waiting for browser callback';
      Exit;
    end;
    if Server.CallbackResult.Error <> '' then
    begin
      ErrMsg := Server.CallbackResult.Error;
      Exit;
    end;

    Form :=
      'grant_type=authorization_code' +
      '&code='          + FormEncode(Server.CallbackResult.Code) +
      '&redirect_uri='  + FormEncode(RedirectURI) +
      '&client_id='     + FormEncode(ClientId) +
      '&code_verifier=' + FormEncode(Verifier);
    if Resource <> '' then
      Form := Form + '&resource=' + FormEncode(Resource);

    if not PostToken(TokenEp, Form, RespBody, Status, ErrMsg) then
    begin
      if ErrMsg = '' then
        ErrMsg := Format('token endpoint returned HTTP %d: %s',
                         [Status, Copy(RespBody, 1, 200)]);
      Exit;
    end;

    NewTok.ClientId      := ClientId;
    NewTok.Issuer        := Issuer;
    NewTok.AuthEndpoint  := Auth;
    NewTok.TokenEndpoint := TokenEp;
    NewTok.RegEndpoint   := RegEp;
    NewTok.Resource      := Resource;
    if not ParseTokenResponse(RespBody, NewTok, ErrMsg) then Exit;

    SaveTokens(ServerName, NewTok);
    Result := True;
  finally
    Server.Free;
  end;
end;

function ForceRefresh(const ServerName: string; out ErrMsg: string): Boolean;
var
  Tok: TOAuthTokens;
  Form, RespBody: string;
  Status: Integer;
begin
  Result := False;
  if not LoadTokens(ServerName, Tok, ErrMsg) then Exit;
  if Tok.RefreshToken = '' then
  begin
    ErrMsg := 'no refresh_token stored -- re-run `pasclaw mcp auth ' + ServerName + '`';
    Exit;
  end;
  if Tok.TokenEndpoint = '' then
  begin
    ErrMsg := 'no token_endpoint cached -- re-run `pasclaw mcp auth ' + ServerName + '`';
    Exit;
  end;
  Form :=
    'grant_type=refresh_token' +
    '&refresh_token=' + FormEncode(Tok.RefreshToken) +
    '&client_id='     + FormEncode(Tok.ClientId);
  { Keep the refreshed token scoped to the same resource as the
    original -- same RFC 8707 requirement applies. }
  if Tok.Resource <> '' then
    Form := Form + '&resource=' + FormEncode(Tok.Resource);
  if not PostToken(Tok.TokenEndpoint, Form, RespBody, Status, ErrMsg) then
  begin
    if ErrMsg = '' then
      ErrMsg := Format('refresh returned HTTP %d: %s', [Status, Copy(RespBody, 1, 200)]);
    Exit;
  end;
  if not ParseTokenResponse(RespBody, Tok, ErrMsg) then Exit;
  SaveTokens(ServerName, Tok);
  Result := True;
end;

function GetAccessToken(const ServerName: string;
                        RefreshSlackSeconds: Integer): string;
var
  Tok: TOAuthTokens;
  Err: string;
begin
  Result := '';
  if not LoadTokens(ServerName, Tok, Err) then Exit;
  if (Tok.ExpiresAtUnix > 0) and
     (NowUnix + RefreshSlackSeconds >= Tok.ExpiresAtUnix) and
     (Tok.RefreshToken <> '') then
  begin
    if not ForceRefresh(ServerName, Err) then
    begin
      LogWarn('OAuth[%s]: refresh failed (%s) -- returning expired token; caller will see 401',
              [ServerName, Err]);
    end
    else
      LoadTokens(ServerName, Tok, Err);
  end;
  Result := Tok.AccessToken;
end;

end.
