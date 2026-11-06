(*
  PasClaw.Gateway.Auth - inbound bearer-token check for the HTTP
  gateway. Reads Cfg.Gateway.Token; when empty, every route passes
  through unchecked (back-compat with the pre-token release). When
  non-empty, every non-exempt route requires either:

    Authorization: Bearer <token>      (preferred -- header-based,
                                         no leak through logs)
    ?token=<token>                     (fallback -- needed by
                                         browser EventSource which
                                         can't set headers)

  Exempt routes:
    /                  embedded web UI HTML (operator-facing
                       page; the JS inside is responsible for
                       attaching the token to subsequent
                       /v1/* fetches)
    /desktop           desktop shell HTML -- same rationale as /,
                       and it hosts the token-entry dialog itself
    /v1/health         health probes (k8s liveness, load balancer)
    /v1/version        build metadata (frequently scraped)
    /webhooks/*        per-channel webhook receivers carry their
                       own signature secret (LINE x-line-signature,
                       Meta x-hub-signature-256, etc.) -- gating
                       them on the gateway token too would require
                       the upstream channel to send it, which they
                       can't.

  Token comparison is constant-time so a timing oracle can't
  enumerate the token byte-by-byte. ASCII byte equality only --
  the token is whatever string the operator put in config.json
  (or in the PASCLAW_GATEWAY_TOKEN env var).

  With no token, the gateway is only as private as the machine -- and
  a web page the operator visits runs ON the machine. So a token-less
  gateway refuses what only a browser sends (LocalRequestRefusal):

    a Host that is not localhost / 127.x / ::1 (or configured)
                       -- a page that rebinds its own name to 127.0.0.1
                       is same-origin with the gateway and could read
                       every answer; its Host header still names it
    an Origin that is not the gateway's own
                       -- a cross-site POST needs no preflight when it
                       is text/plain, and the gateway reads any body as
                       JSON; the browser always says where it came from
    Sec-Fetch-Site: cross-site
                       -- the same, for requests that carry no Origin

  CLI tools, SDKs and MCP clients send none of these, so they are not
  affected; with a token set none of this applies, the token is the gate.
*)
unit PasClaw.Gateway.Auth;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

(*  ConstantTimeStringEqual -- equal-length compare that returns
    after touching every byte. Defeats simple timing oracles that
    measure "how soon does the comparison short-circuit on a
    mismatch byte" to leak the token. Returns False immediately
    when lengths differ (the length itself is not a secret worth
    protecting -- token length is fixed per deployment). *)
function ConstantTimeStringEqual(const A, B: string): Boolean;

(*  IsExemptRoute -- True iff Method+Doc names a route that
    bypasses the bearer-token check. See unit-level comment for
    the rationale per route. Pass the HTTP method (`GET`/`POST`/...)
    and the request path; case-insensitive on the path's static
    prefix (just to be friendly -- web clients normalise paths). *)
function IsExemptRoute(const Method, Doc: string): Boolean;

(*  ExtractBearerToken -- parse `Authorization: Bearer <token>`
    from the raw header value. Case-insensitive on the scheme
    name ("Bearer" / "bearer" / "BEARER" all work; the spec is
    case-insensitive on auth schemes). Returns '' on missing
    header, missing scheme, or unsupported scheme. *)
function ExtractBearerToken(const AuthHeader: string): string;

(*  CheckGatewayAuth -- the decision function the middleware
    calls. Returns True when the request should proceed (no
    token configured, OR token configured and matched, OR route
    exempt). Returns False when the request should be refused
    with 401. ConfiguredToken is Cfg.Gateway.Token at the time
    of the request. *)
function CheckGatewayAuth(const ConfiguredToken: string;
                          const Method, Doc: string;
                          const AuthHeader: string;
                          const QueryToken: string): Boolean;

(*  LocalRequestRefusal -- for a gateway with NO token: '' when the
    request may proceed, else why it is refused (send 403 with it).
    Host, Origin and SecFetchSite are the request's headers, '' when
    absent. AllowedHosts are the names besides the loopback ones the
    gateway answers to (gateway.allowed_hosts, and the bind address when
    it is a specific one); a port in an entry is ignored. Pure. *)
function LocalRequestRefusal(const Host, Origin, SecFetchSite: string;
                             const AllowedHosts: array of string): string;

{ localhost, *.localhost, 127.0.0.0/8, ::1 -- names that always mean
  this machine. }
function IsLoopbackHostName(const Name: string): Boolean;

(* The names a token-less listener answers to besides the loopback ones:
   the configured ones (gateway.allowed_hosts), and the address it is
   bound to when that is a specific one -- an operator who bound
   192.168.1.5 means to be reached there. 0.0.0.0 / :: are every address,
   so no name. *)
function ListenerAllowedHosts(const Configured: array of string;
                              const BindAddr: string): TArray<string>;

implementation

function ConstantTimeStringEqual(const A, B: string): Boolean;
var
  i, n, diff: Integer;
begin
  if Length(A) <> Length(B) then Exit(False);
  n := Length(A);
  diff := 0;
  for i := 1 to n do
    diff := diff or (Ord(A[i]) xor Ord(B[i]));
  Result := diff = 0;
end;

function StartsWithLower(const S, Prefix: string): Boolean;
{ Case-insensitive prefix check restricted to ASCII -- the only
  case that matters here is the "Bearer " scheme name and a few
  exempt path prefixes. LowerCase() in the default locale would
  allocate; we want a stack-only check. }
var
  i: Integer;
  cs, cp: Char;
begin
  if Length(S) < Length(Prefix) then Exit(False);
  for i := 1 to Length(Prefix) do
  begin
    cs := S[i];
    cp := Prefix[i];
    if (cs >= 'A') and (cs <= 'Z') then cs := Chr(Ord(cs) + 32);
    if (cp >= 'A') and (cp <= 'Z') then cp := Chr(Ord(cp) + 32);
    if cs <> cp then Exit(False);
  end;
  Result := True;
end;

function IsExemptRoute(const Method, Doc: string): Boolean;
begin
  { /webhooks/<channel> -- per-channel signature secret already
    gates these; the upstream can't supply a gateway bearer. }
  if StartsWithLower(Doc, '/webhooks/') then Exit(True);

  { Root web UI HTML. The JS inside is responsible for attaching
    the token to subsequent fetches; the initial GET / can't carry
    a bearer header because the browser issues it before any JS
    runs. Same as Grafana's behaviour. }
  if Doc = '/' then Exit(True);

  { Desktop shell HTML -- same deal as '/'. A browser navigating to
    /desktop cannot attach the bearer stored in localStorage, and the
    page IS the thing that holds the token-entry dialog: returning it
    as 401 locks the user out of the very UI that would let them
    authenticate. The JS inside attaches the token to every /v1/*
    fetch it makes. }
  if (Doc = '/desktop') or (Doc = '/desktop/') then Exit(True);

  { Health probe -- k8s readiness/liveness, load-balancer pings.
    Returning 401 here would route the platform's probe into the
    "instance unhealthy" path even though the gateway is up. }
  if Doc = '/v1/health' then Exit(True);

  { Build metadata. Frequently scraped; pinning a token on it
    would just push the secret into more places without
    protecting anything sensitive. }
  if Doc = '/v1/version' then Exit(True);

  Result := False;
end;

function ExtractBearerToken(const AuthHeader: string): string;
const
  SchemeBearer = 'bearer ';   { 7 chars including the trailing space }
var
  Trimmed: string;
begin
  Result := '';
  Trimmed := TrimLeft(AuthHeader);
  if Trimmed = '' then Exit;
  if not StartsWithLower(Trimmed, SchemeBearer) then Exit;
  Result := Trim(Copy(Trimmed, Length(SchemeBearer) + 1,
                      Length(Trimmed)));
end;

function CheckGatewayAuth(const ConfiguredToken: string;
                          const Method, Doc: string;
                          const AuthHeader: string;
                          const QueryToken: string): Boolean;
var
  Bearer: string;
begin
  { Unauthenticated mode: no token configured -> every route open. }
  if ConfiguredToken = '' then Exit(True);

  { Exempt routes pass through even when a token IS configured. }
  if IsExemptRoute(Method, Doc) then Exit(True);

  { Header beats query param -- prefer the path that doesn't end
    up in access logs. }
  Bearer := ExtractBearerToken(AuthHeader);
  if Bearer <> '' then
    Exit(ConstantTimeStringEqual(Bearer, ConfiguredToken));

  if QueryToken <> '' then
    Exit(ConstantTimeStringEqual(QueryToken, ConfiguredToken));

  Result := False;
end;

function HostOnly(const Authority: string): string;
{ The host of "host", "host:port", "[v6]" or "[v6]:port", lower case and
  without brackets. A bare v6 address (two or more colons) is all host. }
var
  A: string;
  P, Colons, i: Integer;
begin
  A := LowerCase(Trim(Authority));
  if (A <> '') and (A[1] = '[') then
  begin
    P := Pos(']', A);
    if P > 0 then Exit(Copy(A, 2, P - 2));
    Exit(Copy(A, 2, MaxInt));
  end;
  Colons := 0;
  for i := 1 to Length(A) do
    if A[i] = ':' then Inc(Colons);
  if Colons = 1 then
    Result := Copy(A, 1, Pos(':', A) - 1)
  else
    Result := A;
end;

function SameAuthority(const A, B: string): Boolean;
{ "host[:port]" equality, ignoring case and a default port (80, 443):
  the Host header has no scheme to say which one was meant. }
  function Norm(const S: string): string;
  begin
    Result := LowerCase(Trim(S));
    if (Length(Result) > 3) and (Copy(Result, Length(Result) - 2, 3) = ':80') then
      SetLength(Result, Length(Result) - 3)
    else if (Length(Result) > 4) and (Copy(Result, Length(Result) - 3, 4) = ':443') then
      SetLength(Result, Length(Result) - 4);
  end;
begin
  Result := Norm(A) = Norm(B);
end;

function IsLoopbackHostName(const Name: string): Boolean;
var
  N: string;
  i: Integer;
begin
  N := LowerCase(Name);
  if (N = 'localhost') or (N = '::1') then Exit(True);
  if (Length(N) > 10) and (Copy(N, Length(N) - 9, 10) = '.localhost') then Exit(True);
  Result := False;
  if Copy(N, 1, 4) <> '127.' then Exit;
  for i := 5 to Length(N) do
    if not (((N[i] >= '0') and (N[i] <= '9')) or (N[i] = '.')) then Exit;
  Result := True;
end;

function ListenerAllowedHosts(const Configured: array of string;
                              const BindAddr: string): TArray<string>;
var
  i: Integer;
begin
  SetLength(Result, Length(Configured));
  for i := 0 to High(Configured) do Result[i] := Configured[i];
  if (BindAddr <> '') and (BindAddr <> '0.0.0.0') and (BindAddr <> '::') and
     (BindAddr <> '[::]') and (BindAddr <> '*') then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := BindAddr;
  end;
end;

function LocalRequestRefusal(const Host, Origin, SecFetchSite: string;
                             const AllowedHosts: array of string): string;
var
  Name, O, Authority: string;
  i, P: Integer;
  Allowed: Boolean;
begin
  Result := '';
  { 1. Host: a name that means this machine, or one the operator named. A
       request with no Host at all is no browser's. }
  Name := HostOnly(Host);
  if Name <> '' then
  begin
    Allowed := IsLoopbackHostName(Name);
    for i := Low(AllowedHosts) to High(AllowedHosts) do
      if (not Allowed) and (HostOnly(AllowedHosts[i]) = Name) then
        Allowed := True;
    if not Allowed then
      Exit(Format('this gateway has no token, so it answers only requests ' +
                  'addressed to localhost; "%s" is not one. Set ' +
                  'PASCLAW_GATEWAY_TOKEN to require a token, or add the name ' +
                  'to gateway.allowed_hosts', [Name]));
  end;

  { 2. Origin: a browser names the page a request came from. Only the
       gateway's own pages (the web UI, the desktop) may use it. }
  O := Trim(Origin);
  if O <> '' then
  begin
    Authority := '';
    P := Pos('://', O);
    if P > 0 then
    begin
      Authority := Copy(O, P + 3, MaxInt);
      if Pos('/', Authority) > 0 then
        Authority := Copy(Authority, 1, Pos('/', Authority) - 1);
    end;
    if (Authority = '') or (Host = '') or not SameAuthority(Authority, Host) then
      Exit(Format('this gateway has no token, so it refuses requests from ' +
                  'other web sites (this one came from %s). Set ' +
                  'PASCLAW_GATEWAY_TOKEN to use it from one', [O]));
    Exit;
  end;

  { 3. No Origin (a GET, mostly): the fetch metadata still says whether
       another site sent it. same-site (this host, another port: the apps
       origin's iframes) and none (typed into the address bar) are fine. }
  if LowerCase(Trim(SecFetchSite)) = 'cross-site' then
    Exit('this gateway has no token, so it refuses requests from other ' +
         'web sites. Set PASCLAW_GATEWAY_TOKEN to use it from one');
end;

end.
