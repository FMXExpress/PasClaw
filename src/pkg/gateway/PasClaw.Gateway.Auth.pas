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
  a web page the operator visits runs ON the machine. Two attacks follow,
  and a token-less gateway refuses exactly what each needs
  (LocalRequestRefusal), nothing more:

    cross-site requests -- a page on another site POSTs text/plain (no
                       CORS preflight; the gateway reads any body as
                       JSON) and drives the agent blind. The browser
                       always sends an Origin on such a request: one
                       that is neither the gateway's own nor an allowed
                       name is refused.
    DNS rebinding      -- a page re-points its own domain name at
                       127.0.0.1 and is then same-origin with the
                       gateway, able to read every answer. Its requests
                       still carry that domain as their Host: a Host
                       that is a domain name other than localhost /
                       *.localhost / an allowed one is refused. An IP
                       address cannot be rebound, so an IP Host (127.x,
                       0.0.0.0, a LAN address) is always fine.

  Nothing else is checked. CLI tools, SDKs, MCP clients and relay
  workers send no Origin, and reach the gateway by localhost or an IP;
  with a token set none of this applies, the token is the gate. What it
  does NOT do: keep a client on the network out -- it can send any Host
  it likes. That needs a token, or a loopback bind.
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
    Host and Origin are the request's headers, '' when absent.
    AllowedHosts are the domain names besides localhost the gateway
    answers to, and whose pages may call it (gateway.allowed_hosts); a
    port in an entry is ignored. Pure. *)
function LocalRequestRefusal(const Host, Origin: string;
                             const AllowedHosts: array of string): string;

{ localhost and *.localhost -- the domain names that always mean this
  machine (browsers resolve them to loopback themselves, never by DNS). }
function IsLocalhostName(const Name: string): Boolean;

{ An IPv4 or IPv6 address rather than a domain name -- which no page can
  re-point by DNS. }
function IsIPLiteral(const Name: string): Boolean;

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

function IsIPLiteral(const Name: string): Boolean;
var
  i, Dots: Integer;
begin
  Result := False;
  if Name = '' then Exit;
  if Pos(':', Name) > 0 then
  begin
    { IPv6 (brackets already gone): hex digits, colons, and an embedded
      dotted v4 tail. }
    for i := 1 to Length(Name) do
      if not (CharInSet(Name[i], ['0'..'9', 'a'..'f', 'A'..'F', ':', '.'])) then Exit;
    Exit(True);
  end;
  Dots := 0;
  for i := 1 to Length(Name) do
    if Name[i] = '.' then Inc(Dots)
    else if not ((Name[i] >= '0') and (Name[i] <= '9')) then Exit;
  Result := Dots = 3;
end;

function IsLocalhostName(const Name: string): Boolean;
var
  N: string;
begin
  N := LowerCase(Name);
  Result := (N = 'localhost') or
            ((Length(N) > 10) and (Copy(N, Length(N) - 9, 10) = '.localhost'));
end;

function LocalRequestRefusal(const Host, Origin: string;
                             const AllowedHosts: array of string): string;

  function IsAllowedName(const Name: string): Boolean;
  var
    i: Integer;
  begin
    Result := IsLocalhostName(Name);
    for i := Low(AllowedHosts) to High(AllowedHosts) do
      if (not Result) and (HostOnly(AllowedHosts[i]) = Name) then
        Result := True;
  end;

var
  Name, O, Authority: string;
  P: Integer;
begin
  Result := '';
  { 1. DNS rebinding: a domain name in Host that is not ours. An IP address
       cannot be rebound, and a request with no Host is no browser's. }
  Name := HostOnly(Host);
  if (Name <> '') and not IsIPLiteral(Name) and not IsAllowedName(Name) then
    Exit(Format('this gateway has no token, so it answers only requests ' +
                'addressed to localhost, an IP address, or a name in ' +
                'gateway.allowed_hosts; "%s" is none of them. Set ' +
                'PASCLAW_GATEWAY_TOKEN to require a token, or add the name ' +
                'to gateway.allowed_hosts', [Name]));

  { 2. A cross-site request: the browser names the page it came from. The
       gateway's own pages are fine, and so are pages under an allowed
       domain name, whatever the port -- a reverse proxy that rewrites Host
       to 127.0.0.1 leaves the Origin as its own name. Anything else is
       not: another site, an opaque "null", or another port of localhost
       or an IP address (the --apps-port origin is one). }
  O := Trim(Origin);
  if O = '' then Exit;
  Authority := '';
  P := Pos('://', O);
  if P > 0 then
  begin
    Authority := Copy(O, P + 3, MaxInt);
    if Pos('/', Authority) > 0 then
      Authority := Copy(Authority, 1, Pos('/', Authority) - 1);
  end;
  if (Authority <> '') and (Host <> '') and SameAuthority(Authority, Host) then Exit;
  Name := HostOnly(Authority);
  if (Name <> '') and not IsIPLiteral(Name) and not IsLocalhostName(Name) and
     IsAllowedName(Name) then
    Exit;
  Result := Format('this gateway has no token, so it refuses requests from ' +
                   'other web sites (this one came from %s). Set ' +
                   'PASCLAW_GATEWAY_TOKEN to use it from one', [O]);
end;

end.
