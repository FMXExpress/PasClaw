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
    3. Get a client_id, in the order MCP 2026-07-28 asks for:
       - Client ID Metadata Document: when the authorization server
         advertises client_id_metadata_document_supported AND the operator
         configured mcp_oauth_client_metadata_url, that HTTPS URL is the
         client_id. Nothing is registered.
       - Dynamic Client Registration (deprecated, kept for servers without
         CIMD): POST to registration_endpoint as a public "native" client
         (application_type -- OIDC servers otherwise assume "web" and
         reject a loopback redirect) with the loopback redirect_uri. The
         registration is stored with the issuer that made it and reused
         only with that issuer and the same redirect_uri; when the
         protected resource points at another authorization server, the
         old client is not used and a new one is registered.
    4. Generate a 64-byte URL-safe code_verifier, derive
       code_challenge = BASE64URL(SHA256(verifier)), and a 32-byte
       state nonce.
    5. Stand up a one-shot TIdHTTPServer on a free loopback port,
       then shell-out the browser to the authorize URL.
    6. Browser → user consents → server redirects to
       http://127.0.0.1:<port>/cb?code=...&state=...&iss=...; the loopback
       server captures the parameters and unblocks the wait. Before the
       code is used, RFC 9207: a present `iss` must equal the issuer
       recorded from the server metadata (exact string comparison), and
       when the metadata says authorization_response_iss_parameter_supported
       an absent `iss` is refused too. A mismatched response's error text
       is neither shown nor acted on -- it came from the wrong server.
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
    { The client registration ClientId belongs to: the issuer that made it
      (credentials are bound to one authorization server), the redirect_uri
      it was registered with, and how it was obtained -- "dcr" or "cimd". }
    ClientIssuer:      string;
    ClientRedirectURI: string;
    ClientRegistration: string;
  end;

  { The parameters of the authorization redirect, as received. }
  TAuthCallbackParams = record
    Code:             string;
    State:            string;
    Iss:              string;
    HasIss:           Boolean;
    Error:            string;
    ErrorDescription: string;
  end;

{ Run the full interactive flow for ServerName (the MCP entry name,
  used to derive the token-store path) against ServerURL (the MCP
  server's base URL, used for protected-resource discovery). Opens
  a browser tab and blocks until the loopback callback fires or the
  timeout elapses. Returns False with ErrMsg populated on failure.
  ClientMetadataURL is the operator's Client ID Metadata Document URL
  (config mcp_oauth_client_metadata_url); '' = register with DCR. }
function RunOAuthFlow(const ServerName, ServerURL: string;
                      out ErrMsg: string;
                      const ClientMetadataURL: string = ''): Boolean;

{ The checks on an authorization response, in the order they must run:
  issuer (RFC 9207: a present iss must equal RecordedIssuer exactly; an
  absent one is refused when IssParameterSupported), then state, then the
  error the server reported, then the code. On success Code is the
  authorization code to redeem. On an issuer mismatch ErrMsg does not
  repeat the response's error text. Pure, for the unit test. }
function ValidateAuthorizationResponse(const Cb: TAuthCallbackParams;
  const ExpectedState, RecordedIssuer: string; IssParameterSupported: Boolean;
  out Code, ErrMsg: string): Boolean;

(* After a failed authorization: whether to forget the stored client
   registration, because the authorization server said it no longer knows
   it (invalid_client / unauthorized_client). Only for a response that
   passed the issuer and state checks: anything on this machine, or any web
   page the browser has open, can send a request to the loopback callback,
   and one that could not pass them must not wipe a working registration --
   the next refresh would then go out with an empty client_id. Reused: the
   run presented a stored registration (a fresh one has nothing to forget).
   Pure, for the unit test. *)
function ShouldForgetClient(const Cb: TAuthCallbackParams;
  const ExpectedState, RecordedIssuer: string; IssParameterSupported,
  Reused: Boolean): Boolean;

{ The body of a Dynamic Client Registration request (RFC 7591) for a
  loopback redirect: a public, native client. Exposed for the unit test. }
function ClientRegistrationBody(const RedirectURI: string): string;

{ True when Tok holds a DCR registration PasClaw may reuse with Issuer:
  same authorization server, a redirect_uri to listen on again. }
function CanReuseClient(const Tok: TOAuthTokens; const Issuer: string): Boolean;

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
    L.Text := ReadFileText(Path);
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
      { A file from before issuer binding: its client was made by the
        issuer recorded beside it. }
      Tok.ClientIssuer       := Obj.GetStr('client_issuer', Tok.Issuer);
      Tok.ClientRedirectURI  := Obj.GetStr('client_redirect_uri', '');
      Tok.ClientRegistration := Obj.GetStr('client_registration', 'dcr');
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
    Obj.PutStr('client_issuer',       Tok.ClientIssuer);
    Obj.PutStr('client_redirect_uri', Tok.ClientRedirectURI);
    Obj.PutStr('client_registration', Tok.ClientRegistration);
    if Tok.ExpiresAtUnix > 0 then
      Obj.PutInt('expires_at_unix', Tok.ExpiresAtUnix);
    L := TStringList.Create;
    try
      L.Text := Obj.ToJSON;
      WriteFileText(Path, L.Text);
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
                           out IssSupported, CIMDSupported: Boolean;
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
  IssSupported  := False;
  CIMDSupported := False;
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
    { RFC 9207: the server promises an iss on every authorization
      response, so one without is refused. }
    IssSupported  := AsObj.GetBool('authorization_response_iss_parameter_supported', False);
    CIMDSupported := AsObj.GetBool('client_id_metadata_document_supported', False);
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

function ClientRegistrationBody(const RedirectURI: string): string;
var
  O: TJsonObject;
  A: TJsonArray;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('client_name', 'PasClaw');
    A := TJsonArray.Create;
    A.AddStr(RedirectURI);
    O.PutArray('redirect_uris', A);
    A := TJsonArray.Create;
    A.AddStr('authorization_code');
    A.AddStr('refresh_token');
    O.PutArray('grant_types', A);
    A := TJsonArray.Create;
    A.AddStr('code');
    O.PutArray('response_types', A);
    O.PutStr('token_endpoint_auth_method', 'none');
    { A CLI with a loopback redirect is a native app. MCP 2026-07-28
      requires the client to say so: OIDC registration defaults to "web",
      whose rules refuse an http://127.0.0.1 redirect. }
    O.PutStr('application_type', 'native');
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

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
  Body := ClientRegistrationBody(RedirectURI);
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

{ ---------- Authorization response validation (RFC 9207) -------- }

{ The checks that tie a response to this authorization request -- issuer,
  then state. What a response says is only acted on after they pass. }
function ResponseFromThisRequest(const Cb: TAuthCallbackParams;
  const ExpectedState, RecordedIssuer: string; IssParameterSupported: Boolean;
  out ErrMsg: string): Boolean;
begin
  Result := False;
  ErrMsg := '';
  { Issuer first: a response from another authorization server (a mix-up
    attack) must not be acted on at all -- not its code, and not its error
    text either. Simple string comparison, no normalisation: RFC 9207 2.4
    and MCP 2026-07-28 forbid case folding, port elision or trailing-slash
    games here. }
  if Cb.HasIss then
  begin
    if Cb.Iss <> RecordedIssuer then
    begin
      ErrMsg := Format('authorization response names issuer "%s", but the ' +
        'authorization server is "%s" -- refusing it (RFC 9207 mix-up protection)',
        [Cb.Iss, RecordedIssuer]);
      Exit;
    end;
  end
  else if IssParameterSupported then
  begin
    ErrMsg := 'authorization response has no "iss" although the authorization ' +
              'server advertises authorization_response_iss_parameter_supported -- refusing it';
    Exit;
  end;
  if Cb.State <> ExpectedState then
  begin
    ErrMsg := 'state mismatch -- possible CSRF; refusing';
    Exit;
  end;
  Result := True;
end;

function ValidateAuthorizationResponse(const Cb: TAuthCallbackParams;
  const ExpectedState, RecordedIssuer: string; IssParameterSupported: Boolean;
  out Code, ErrMsg: string): Boolean;
begin
  Result := False;
  Code := '';
  if not ResponseFromThisRequest(Cb, ExpectedState, RecordedIssuer,
                                 IssParameterSupported, ErrMsg) then Exit;
  if Cb.Error <> '' then
  begin
    ErrMsg := Cb.Error;
    if Cb.ErrorDescription <> '' then ErrMsg := ErrMsg + ': ' + Cb.ErrorDescription;
    Exit;
  end;
  if Cb.Code = '' then
  begin
    ErrMsg := 'authorization response carries no code';
    Exit;
  end;
  Code := Cb.Code;
  Result := True;
end;

function ShouldForgetClient(const Cb: TAuthCallbackParams;
  const ExpectedState, RecordedIssuer: string; IssParameterSupported,
  Reused: Boolean): Boolean;
var
  Ignored: string;
begin
  Result := Reused and
            ((Cb.Error = 'invalid_client') or (Cb.Error = 'unauthorized_client')) and
            ResponseFromThisRequest(Cb, ExpectedState, RecordedIssuer,
                                    IssParameterSupported, Ignored);
end;

function CanReuseClient(const Tok: TOAuthTokens; const Issuer: string): Boolean;
begin
  { Client credentials belong to the authorization server that issued
    them; never present one to another. A redirect_uri is needed too: the
    registration pinned it, so the callback must listen there again. }
  Result := (Tok.ClientRegistration = 'dcr') and (Tok.ClientId <> '') and
            (Tok.ClientIssuer <> '') and (Tok.ClientIssuer = Issuer) and
            (Tok.ClientRedirectURI <> '');
end;

function PortOfURL(const URL: string): Integer;
var
  P, Q: Integer;
  Rest: string;
begin
  Result := 0;
  P := Pos('://', URL);
  if P = 0 then Exit;
  Rest := Copy(URL, P + 3, MaxInt);
  Q := Pos('/', Rest);
  if Q > 0 then Rest := Copy(Rest, 1, Q - 1);
  Q := Pos(':', Rest);
  if Q = 0 then Exit;
  Result := StrToIntDef(Copy(Rest, Q + 1, MaxInt), 0);
end;

function ValidClientMetadataURL(const URL: string; out ErrMsg: string): Boolean;
var
  Rest: string;
begin
  { draft-ietf-oauth-client-id-metadata-document: an https URL with a path. }
  ErrMsg := '';
  Result := False;
  if LowerCase(Copy(URL, 1, 8)) <> 'https://' then
  begin
    ErrMsg := 'mcp_oauth_client_metadata_url must be an https:// URL: ' + URL;
    Exit;
  end;
  Rest := Copy(URL, 9, MaxInt);
  if (Pos('/', Rest) = 0) or (Pos('/', Rest) = Length(Rest)) then
  begin
    ErrMsg := 'mcp_oauth_client_metadata_url needs a path (e.g. ' +
              'https://example.com/pasclaw-client.json): ' + URL;
    Exit;
  end;
  Result := True;
end;

{ ---------- Loopback callback server ------------------------------ }

type
  TLoopbackServer = class
  private
    FHttp: TIdHTTPServer;
    FParams: TAuthCallbackParams;
    FGot:    Boolean;
    FValid:  Boolean;
    FCode:   string;
    FError:  string;
    procedure HandleCommandGet(AContext: TIdContext;
                                ARequest: TIdHTTPRequestInfo;
                                AResponse: TIdHTTPResponseInfo);
  public
    { Set once after Create, before the browser is sent off, so the handler
      can validate the redirect: the state nonce, and the issuer recorded
      from the authorization server's metadata (RFC 9207). }
    ExpectedState:  string;
    ExpectedIssuer: string;
    IssSupported:   Boolean;
    constructor Create;
    destructor  Destroy; override;
    { Listen on 127.0.0.1:Port (0 = any free port). Returns the port, or
      -1 when it cannot be bound. }
    function  StartOnPort(Port: Integer): Integer;
    function  WaitForCallback(TimeoutMs: Integer): Boolean;
    property  Got: Boolean read FGot;
    property  Valid: Boolean read FValid;
    property  Code: string read FCode;
    property  Error: string read FError;
    property  Params: TAuthCallbackParams read FParams;
  end;

constructor TLoopbackServer.Create;
begin
  inherited Create;
  ExpectedState := '';
  ExpectedIssuer := '';
  IssSupported := False;
  FGot := False;
  FValid := False;
  FHttp := TIdHTTPServer.Create(nil);
  FHttp.OnCommandGet := HandleCommandGet;
end;

destructor TLoopbackServer.Destroy;
begin
  try if FHttp.Active then FHttp.Active := False; except end;
  FHttp.Free;
  inherited Destroy;
end;

function TLoopbackServer.StartOnPort(Port: Integer): Integer;
var
  Binding: TIdSocketHandle;
begin
  Result := -1;
  try
    if FHttp.Active then FHttp.Active := False;
    FHttp.Bindings.Clear;
    Binding := FHttp.Bindings.Add;
    Binding.IP   := '127.0.0.1';
    Binding.Port := Port;     { 0: ask the OS for a free port }
    FHttp.Active := True;
    Result := FHttp.Bindings[0].Port;
  except
    { the remembered port is taken: the caller falls back to a free one }
    try FHttp.Active := False; except end;
  end;
end;

procedure TLoopbackServer.HandleCommandGet(AContext: TIdContext;
                                            ARequest: TIdHTTPRequestInfo;
                                            AResponse: TIdHTTPResponseInfo);
begin
  if ARequest.Document <> '/cb' then
  begin
    AResponse.ResponseNo := 404;
    AResponse.ContentText := 'not found';
    Exit;
  end;
  FParams.Code             := ARequest.Params.Values['code'];
  FParams.State            := ARequest.Params.Values['state'];
  FParams.Error            := ARequest.Params.Values['error'];
  FParams.ErrorDescription := ARequest.Params.Values['error_description'];
  FParams.Iss              := ARequest.Params.Values['iss'];
  FParams.HasIss           := ARequest.Params.IndexOfName('iss') >= 0;
  FValid := ValidateAuthorizationResponse(FParams, ExpectedState, ExpectedIssuer,
                                          IssSupported, FCode, FError);
  AResponse.ResponseNo  := 200;
  if FValid then
  begin
    AResponse.ContentType := 'text/html; charset=utf-8';
    AResponse.ContentText :=
      '<html><body style="font:14px sans-serif;padding:2em">' +
      '<h2>PasClaw: authorization received.</h2>' +
      '<p>You can close this tab and return to the terminal.</p>' +
      '</body></html>';
  end
  else
  begin
    { Nothing the redirect carried is echoed into the page: it may come
      from the wrong server, and the terminal has the details. }
    if FParams.Error = '' then AResponse.ResponseNo := 400;
    AResponse.ContentType := 'text/plain; charset=utf-8';
    AResponse.ContentText :=
      'PasClaw: authorization failed. See the terminal for why; you can close this tab.';
  end;
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
                      out ErrMsg: string;
                      const ClientMetadataURL: string): Boolean;
var
  Auth, TokenEp, RegEp, Issuer, Resource: string;
  IssSupported, CIMDSupported, HavePrev, Reused: Boolean;
  Prev, NewTok: TOAuthTokens;
  ClientId, Registration, Verifier, Challenge, State, RedirectURI, Dummy: string;
  VerBytes, ChalBytes, StateBytesB: TBytes;
  Server: TLoopbackServer;
  Port: Integer;
  AuthorizeURL, Form, RespBody: string;
  Status: Integer;
begin
  Result := False;
  ErrMsg := '';

  if not DiscoverEndpoints(ServerURL, Auth, TokenEp, RegEp, Issuer, Resource,
                           IssSupported, CIMDSupported, ErrMsg) then
    Exit;

  HavePrev := LoadTokens(ServerName, Prev, Dummy);
  Reused := False;
  ClientId := '';
  Registration := '';
  RedirectURI := '';
  Server := TLoopbackServer.Create;
  try
    if CIMDSupported and (ClientMetadataURL <> '') then
    begin
      { Client ID Metadata Document: the URL is the client_id, the server
        fetches it, nothing is registered. Portable across authorization
        servers, so there is no issuer binding to check. }
      if not ValidClientMetadataURL(ClientMetadataURL, ErrMsg) then Exit;
      ClientId := ClientMetadataURL;
      Registration := 'cimd';
      Port := Server.StartOnPort(0);
      WriteLn('Client: ', ClientId, ' (Client ID Metadata Document)');
    end
    else
    begin
      if ClientMetadataURL <> '' then
        WriteLn('The authorization server does not advertise Client ID Metadata ',
                'Document support; using dynamic client registration.');
      if HavePrev and (Prev.ClientId <> '') and (Prev.ClientRegistration = 'dcr') and
         (Prev.ClientIssuer <> '') and (Prev.ClientIssuer <> Issuer) then
        WriteLn('The authorization server changed (', Prev.ClientIssuer, ' -> ',
                Issuer, '): registering a new client.');
      Port := -1;
      if HavePrev and CanReuseClient(Prev, Issuer) then
      begin
        { The registration pinned its redirect_uri, so listen there again;
          if that port is taken, register afresh on a free one. }
        Port := Server.StartOnPort(PortOfURL(Prev.ClientRedirectURI));
        if Port > 0 then
        begin
          ClientId := Prev.ClientId;
          RedirectURI := Prev.ClientRedirectURI;
          Registration := 'dcr';
          Reused := True;
          WriteLn('Client: reusing the registration made with ', Issuer);
        end;
      end;
      if ClientId = '' then
      begin
        if Port <= 0 then Port := Server.StartOnPort(0);
        if Port <= 0 then
        begin
          ErrMsg := 'cannot listen on 127.0.0.1 for the authorization callback';
          Exit;
        end;
        RedirectURI := Format('http://127.0.0.1:%d/cb', [Port]);
        if RegEp = '' then
        begin
          ErrMsg := 'no client_id available -- auth server does not expose registration_endpoint';
          if CIMDSupported then
            ErrMsg := ErrMsg + '; it accepts Client ID Metadata Documents, so set ' +
                      'mcp_oauth_client_metadata_url to the HTTPS URL of one you host';
          Exit;
        end;
        if not RegisterClient(RegEp, RedirectURI, ClientId, ErrMsg) then Exit;
        Registration := 'dcr';
      end;
    end;
    if Port <= 0 then
    begin
      ErrMsg := 'cannot listen on 127.0.0.1 for the authorization callback';
      Exit;
    end;
    if RedirectURI = '' then RedirectURI := Format('http://127.0.0.1:%d/cb', [Port]);

    VerBytes    := GetRandomBytes(PkceVerifierBytes);
    Verifier    := BytesToBase64URL(VerBytes);
    ChalBytes   := SHA256Bytes(TEncoding.ASCII.GetBytes(Verifier));
    Challenge   := BytesToBase64URL(ChalBytes);
    StateBytesB := GetRandomBytes(StateBytes);
    State       := BytesToBase64URL(StateBytesB);
    { Kept beside the state and PKCE verifier, from the metadata we fetched:
      the iss the redirect must carry back. }
    Server.ExpectedState  := State;
    Server.ExpectedIssuer := Issuer;
    Server.IssSupported   := IssSupported;

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
    { A piped stdout (a script, a test) must see the URL before we block. }
    Flush(Output);
    OpenBrowser(AuthorizeURL);
    WriteLn('Waiting for callback on ', RedirectURI, ' (up to ',
            AuthFlowTimeoutMs div 1000, 's)...');
    Flush(Output);

    if not Server.WaitForCallback(AuthFlowTimeoutMs) then
    begin
      ErrMsg := 'timed out waiting for browser callback';
      Exit;
    end;
    if not Server.Valid then
    begin
      ErrMsg := Server.Error;
      { A reused registration the server no longer knows: forget it, so the
        next run registers a new client instead of failing the same way --
        but only on a response that passed the issuer and state checks
        (ShouldForgetClient says why). }
      if ShouldForgetClient(Server.Params, Server.ExpectedState, Server.ExpectedIssuer,
                            Server.IssSupported, Reused) then
      begin
        Prev.ClientId := '';
        Prev.ClientRedirectURI := '';
        SaveTokens(ServerName, Prev);
        ErrMsg := ErrMsg + ' -- dropped the stored client registration; run ' +
                  'pasclaw mcp auth ' + ServerName + ' again to register a new one';
      end;
      Exit;
    end;

    Form :=
      'grant_type=authorization_code' +
      '&code='          + FormEncode(Server.Code) +
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

    NewTok := Default(TOAuthTokens);
    NewTok.ClientId      := ClientId;
    NewTok.Issuer        := Issuer;
    NewTok.AuthEndpoint  := Auth;
    NewTok.TokenEndpoint := TokenEp;
    NewTok.RegEndpoint   := RegEp;
    NewTok.Resource      := Resource;
    NewTok.ClientIssuer       := Issuer;
    NewTok.ClientRedirectURI  := RedirectURI;
    NewTok.ClientRegistration := Registration;
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
  { A registered client is bound to the authorization server that issued
    it; never present it to another one. (A CIMD client_id is a URL any
    server can resolve, so it carries no such binding.) }
  if (Tok.ClientRegistration <> 'cimd') and (Tok.ClientIssuer <> '') and
     (Tok.Issuer <> '') and (Tok.ClientIssuer <> Tok.Issuer) then
  begin
    ErrMsg := 'the stored client was registered with ' + Tok.ClientIssuer +
              ', not ' + Tok.Issuer + ' -- re-run `pasclaw mcp auth ' + ServerName + '`';
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
