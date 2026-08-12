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

end.
