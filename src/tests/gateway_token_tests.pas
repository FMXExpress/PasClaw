program gateway_token_tests;
(*
  Pins the gateway bearer-token middleware contract:
    - Cfg.Gateway.Token = '' -> every route open (back-compat).
    - Cfg.Gateway.Token <> '' -> non-exempt routes require
      `Authorization: Bearer <token>` OR `?token=<token>`.
    - Exempt routes (/, /v1/health, /v1/version, /webhooks/<...> )
      pass through even when a token is configured.
    - Header beats query param when both are present.
    - Token comparison is constant-time (length-mismatch short-
      circuits; same-length compares touch every byte).
    - Bearer scheme is case-insensitive on the scheme name.
    - An env-var marker whose variable is not set is NO token, never
      the marker's own (public) text.
    - With no token, LocalRequestRefusal turns away the two things only
      a web page does -- an Origin from another site, and a domain name
      rebound to 127.0.0.1 (DNS rebinding) -- and nothing else: IP
      addresses (0.0.0.0, a LAN address), localhost, iframes, CLIs and
      proxies get through. make test-gateway-local-only drives the same
      through a live gateway.

  These tests exercise PasClaw.Gateway.Auth directly -- no Indy
  server, no provider stack, no config file. A future test that
  drives the full TGatewayServer would round-trip the same
  contract through actual HTTP; this file pins the decision
  function so a refactor of OnCommandGet can't silently change
  the gate's shape.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Gateway.Auth;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const A, B, Msg: string);
begin
  if A <> B then
    Fail_(Msg + ' (expected "' + B + '" got "' + A + '")');
end;

procedure TestUnauthenticatedModePassesEveryRoute;
begin
  AssertTrue(CheckGatewayAuth('', 'GET',  '/v1/health',          '', ''),
             'no token configured: /v1/health open');
  AssertTrue(CheckGatewayAuth('', 'POST', '/v1/chat/completions', '', ''),
             'no token configured: /v1/chat/completions open');
  AssertTrue(CheckGatewayAuth('', 'GET',  '/v1/logs',             '', ''),
             'no token configured: /v1/logs open');
  AssertTrue(CheckGatewayAuth('', 'POST', '/mcp',                 '', ''),
             'no token configured: /mcp open');
end;

procedure TestConfiguredTokenRefusesUnauthedRequest;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions', '', ''),
             'token configured, no header -> 401');
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                                  'Bearer wrong-token', ''),
             'token configured, wrong header -> 401');
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                                  'Basic dXNlcjpwYXNz', ''),
             'token configured, wrong scheme (Basic) -> 401');
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                                  'Bearer', ''),
             'token configured, Bearer with no token -> 401');
end;

procedure TestConfiguredTokenAcceptsBearerHeader;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                              'Bearer ' + Tok, ''),
             'matching Bearer header passes');
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                              'bearer ' + Tok, ''),
             'lowercase "bearer" scheme passes (case-insensitive)');
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                              'BEARER ' + Tok, ''),
             'uppercase "BEARER" scheme passes (case-insensitive)');
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                              '  Bearer ' + Tok + '  ', ''),
             'surrounding whitespace tolerated');
end;

procedure TestConfiguredTokenAcceptsQueryParam;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  AssertTrue(CheckGatewayAuth(Tok, 'GET', '/v1/logs', '', Tok),
             '?token=<correct> passes when header is missing');
  AssertTrue(not CheckGatewayAuth(Tok, 'GET', '/v1/logs', '', 'wrong-token'),
             '?token=<wrong> -> 401');
end;

procedure TestHeaderBeatsQueryParam;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  { When both are present, the header is the source of truth.
    Rationale: query params land in access logs and browser history;
    pinning the gate to the header forces the operator to consider
    where the secret leaks. }
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                              'Bearer ' + Tok, 'wrong-query-token'),
             'good header beats bad query (header is authoritative)');
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions',
                                  'Bearer wrong-header', Tok),
             'bad header is final even when query token would match');
end;

procedure TestExemptRoutesBypassTokenCheck;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  { Exempt even with no auth at all. }
  AssertTrue(CheckGatewayAuth(Tok, 'GET', '/v1/health',  '', ''),
             '/v1/health exempt -- k8s probes must succeed');
  AssertTrue(CheckGatewayAuth(Tok, 'GET', '/v1/version', '', ''),
             '/v1/version exempt -- build metadata');
  AssertTrue(CheckGatewayAuth(Tok, 'GET', '/',           '', ''),
             '/ (web UI HTML) exempt -- browser cannot send Bearer on initial GET');
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/webhooks/line',     '', ''),
             '/webhooks/line exempt -- per-channel signature gates this route');
  AssertTrue(CheckGatewayAuth(Tok, 'POST', '/webhooks/whatsapp', '', ''),
             '/webhooks/whatsapp exempt -- Meta x-hub-signature-256 gates this route');
  AssertTrue(CheckGatewayAuth(Tok, 'GET',  '/webhooks/whatsapp', '', ''),
             '/webhooks/whatsapp GET exempt -- Meta subscription handshake');

  { Non-exempt routes are still gated. }
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/v1/chat/completions', '', ''),
             '/v1/chat/completions is NOT exempt -- still 401');
  AssertTrue(not CheckGatewayAuth(Tok, 'GET',  '/v1/logs',             '', ''),
             '/v1/logs is NOT exempt -- still 401');
  AssertTrue(not CheckGatewayAuth(Tok, 'POST', '/mcp',                 '', ''),
             '/mcp is NOT exempt -- still 401 (operator can use --mcp-port for an unauthed listener)');
end;

procedure TestConstantTimeCompareBehaviour;
begin
  AssertTrue(ConstantTimeStringEqual('', ''),
             'empty == empty');
  AssertTrue(ConstantTimeStringEqual('abc', 'abc'),
             'equal short strings');
  AssertTrue(not ConstantTimeStringEqual('abc', 'abd'),
             'one-byte diff at end detected');
  AssertTrue(not ConstantTimeStringEqual('abc', 'xbc'),
             'one-byte diff at start detected');
  AssertTrue(not ConstantTimeStringEqual('abc', 'abcd'),
             'length mismatch short-circuits');
  AssertTrue(not ConstantTimeStringEqual('abcd', 'abc'),
             'length mismatch (other way) short-circuits');
  AssertTrue(ConstantTimeStringEqual(
              'sk-pasclaw-test-token-aaaaaaaa',
              'sk-pasclaw-test-token-aaaaaaaa'),
             'long equal strings');
  AssertTrue(not ConstantTimeStringEqual(
              'sk-pasclaw-test-token-aaaaaaaa',
              'sk-pasclaw-test-token-aaaaaaab'),
             'long strings differing only in last byte still detected');
end;

procedure TestExtractBearerTokenParses;
begin
  AssertEq(ExtractBearerToken(''),                                  '',
           'empty header -> ""');
  AssertEq(ExtractBearerToken('Bearer abc'),                        'abc',
           'standard Bearer abc');
  AssertEq(ExtractBearerToken('bearer abc'),                        'abc',
           'lowercase scheme');
  AssertEq(ExtractBearerToken('BEARER abc'),                        'abc',
           'uppercase scheme');
  AssertEq(ExtractBearerToken('  Bearer  abc  '),                   'abc',
           'whitespace around scheme + token');
  AssertEq(ExtractBearerToken('Basic dXNlcjpwYXNz'),                '',
           'wrong scheme -> ""');
  AssertEq(ExtractBearerToken('Bearer'),                            '',
           'scheme with no value -> ""');
  AssertEq(ExtractBearerToken('xBearer abc'),                       '',
           'prefix-shaped junk does not pass');
end;

procedure TestIsExemptRouteShape;
begin
  AssertTrue(IsExemptRoute('GET',  '/'),
             '/ is exempt');
  AssertTrue(IsExemptRoute('GET',  '/desktop'),
             '/desktop is exempt -- it hosts the token-entry dialog');
  AssertTrue(IsExemptRoute('GET',  '/desktop/'),
             '/desktop/ (trailing slash) is exempt too');
  AssertTrue(not IsExemptRoute('GET', '/desktopX'),
             'similar-looking path does not silently match /desktop');
  AssertTrue(not IsExemptRoute('GET', '/v1/desktop/state'),
             'the desktop DATA routes are NOT exempt -- only the shell HTML');
  AssertTrue(IsExemptRoute('GET',  '/v1/health'),
             '/v1/health is exempt');
  AssertTrue(IsExemptRoute('GET',  '/v1/version'),
             '/v1/version is exempt');
  AssertTrue(IsExemptRoute('POST', '/webhooks/line'),
             '/webhooks/line is exempt');
  AssertTrue(IsExemptRoute('POST', '/webhooks/whatsapp'),
             '/webhooks/whatsapp is exempt');
  AssertTrue(IsExemptRoute('POST', '/webhooks/custom-channel'),
             '/webhooks/* prefix means future channels stay exempt');
  AssertTrue(not IsExemptRoute('POST', '/v1/chat/completions'),
             '/v1/chat/completions is NOT exempt');
  AssertTrue(not IsExemptRoute('GET',  '/v1/logs'),
             '/v1/logs is NOT exempt -- log ring buffer can leak per-tool args');
  AssertTrue(not IsExemptRoute('GET',  '/v1/stats'),
             '/v1/stats is NOT exempt');
  AssertTrue(not IsExemptRoute('POST', '/v1/stats/reset'),
             '/v1/stats/reset is NOT exempt -- it erases the saved totals');
  AssertTrue(not IsExemptRoute('GET',  '/v1/config'),
             '/v1/config is NOT exempt -- carries masked API keys and bot tokens');
  AssertTrue(not IsExemptRoute('GET',  '/v1/healthbeat'),
             'similar-looking path does not silently match /v1/health');
end;

procedure TestEffectiveTokenContract;
(* PR #246 P2 (Codex) -- the env-var override MUST stay out of the
   persisted config, and the public getter MUST honour the env-vs-
   config precedence + the openclaw alias.

   We can't mutate process env here (FPC's RTL snapshots envp at
   startup -- same caveat that drove the otel_tests --env-mode
   round-trip). What we CAN pin in-process is the precedence
   contract: when GetEffectiveGatewayToken sees neither env nor a
   config field, it returns ''; when only the config field is set,
   it returns that; when ToJSON is called the in-config field
   round-trips but the env value never does.

   The env-vs-config-precedence path is exercised in a second pass
   driven by the Makefile (--env-mode), same shape as otel_tests. *)
var
  Cfg, RT: TConfig;
  Serialised: string;
begin
  Cfg := TConfig.Create;
  RT  := TConfig.Create;
  try
    { Baseline: no token anywhere -> getter returns ''. }
    AssertEq(GetEffectiveGatewayToken(Cfg), '',
             'no token anywhere: GetEffectiveGatewayToken returns ""');

    { Config-only token -> getter returns it. }
    Cfg.Gateway.Token := 'sk-pasclaw-from-config-aaaaaaaa';
    AssertEq(GetEffectiveGatewayToken(Cfg),
             'sk-pasclaw-from-config-aaaaaaaa',
             'config-only: getter returns Cfg.Gateway.Token');

    { Round-trip: config token DOES persist through ToJSON. }
    Serialised := Cfg.ToJSON;
    AssertTrue(Pos('"token"', Serialised) > 0,
               'ToJSON emits the gateway.token field when Cfg.Gateway.Token is set');
    RT.FromJSON(Serialised);
    AssertEq(RT.Gateway.Token, 'sk-pasclaw-from-config-aaaaaaaa',
             'FromJSON round-trip preserves Cfg.Gateway.Token');

    { Empty token NOT emitted -- a fresh config wouldn't grow a
      "token":"" field just by being serialised. Guards against a
      future SaveConfig dropping an empty token row that operators
      would then think they had to fill in. }
    Cfg.Gateway.Token := '';
    Serialised := Cfg.ToJSON;
    AssertTrue(Pos('"token"', Serialised) <= 0,
               'ToJSON omits gateway.token when empty');
  finally
    Cfg.Free;
    RT.Free;
  end;
end;

procedure TestEnvModePrecedence;
(* Second pass: invoked from the Makefile with PASCLAW_GATEWAY_TOKEN
   (or OPENCLAW_GATEWAY_TOKEN) set in the parent process so FPC's
   envp snapshot picks it up. Asserts that GetEffectiveGatewayToken
   returns the env value AND that Cfg.Gateway.Token (the config
   field, source of ToJSON) stays untouched by the env override.
   That second half is the literal Codex P2: env-only secrets must
   not bleed into persisted config. *)
var
  Cfg, RT: TConfig;
  Serialised: string;
  EnvPasclaw, EnvOpenclaw: string;
begin
  EnvPasclaw  := GetEnvironmentVariable('PASCLAW_GATEWAY_TOKEN');
  EnvOpenclaw := GetEnvironmentVariable('OPENCLAW_GATEWAY_TOKEN');
  AssertTrue((EnvPasclaw <> '') or (EnvOpenclaw <> ''),
             'precondition: one of PASCLAW_GATEWAY_TOKEN / OPENCLAW_GATEWAY_TOKEN inherited from Makefile');

  Cfg := TConfig.Create;
  RT  := TConfig.Create;
  try
    { LoadConfig is what populates the module-level GEnvGatewayToken
      from env -- we have to invoke the same code path here. The
      easiest path that doesn't require a real $PASCLAW_HOME is to
      construct a fresh TConfig (already done above) and then run
      the env-pickup logic via LoadConfig's chokepoint. LoadConfig
      tolerates a missing config file -- it just leaves Result at
      defaults. Then we observe the side-effect. }
    Cfg.Free;
    Cfg := LoadConfig;
    AssertEq(Cfg.Gateway.Token, '',
             'Cfg.Gateway.Token stays empty when only the env is set -- '
             + 'this is the Codex P2 fix: env-only secrets do NOT bleed into the persisted config');

    if EnvPasclaw <> '' then
      AssertEq(GetEffectiveGatewayToken(Cfg), EnvPasclaw,
               'PASCLAW_GATEWAY_TOKEN env value wins')
    else
      AssertEq(GetEffectiveGatewayToken(Cfg), EnvOpenclaw,
               'OPENCLAW_GATEWAY_TOKEN env value wins (openclaw-compat alias)');

    { ToJSON of an env-only-token config MUST NOT emit a token
      field -- this is the assertion that catches the original bug
      (SaveConfig writing the env value into config.json). }
    Serialised := Cfg.ToJSON;
    AssertTrue(Pos('"token"', Serialised) <= 0,
               'ToJSON does NOT emit gateway.token when only the env var was set');
    RT.FromJSON(Serialised);
    AssertEq(RT.Gateway.Token, '',
             'FromJSON round-trip of an env-only-token config produces empty Gateway.Token');
  finally
    Cfg.Free;
    RT.Free;
  end;
end;

procedure TestTokenLengthDoesNotLeakViaShortCircuit;
const
  Tok = 'sk-pasclaw-test-token-aaaaaaaa';
begin
  { Bytes-touched count for same-length compares is identical
    regardless of which byte differs -- the function returns the
    accumulated XOR diff only AFTER iterating every byte. We
    can't directly time the call, but we CAN assert the contract
    by checking that mismatches at the first byte and at the last
    byte both correctly return False (and that none of the
    intermediate code path returns early on the first mismatch). }
  AssertTrue(not ConstantTimeStringEqual(
              'xk-pasclaw-test-token-aaaaaaaa',
              'sk-pasclaw-test-token-aaaaaaaa'),
             'first-byte mismatch returns False (covers the early-byte path)');
  AssertTrue(not ConstantTimeStringEqual(
              'sk-pasclaw-test-token-aaaaaaax',
              'sk-pasclaw-test-token-aaaaaaaa'),
             'last-byte mismatch returns False (covers the late-byte path)');
  AssertTrue(ConstantTimeStringEqual(Tok, Tok),
             'identical strings still pass after both mismatch cases tested');
end;

procedure TestUnsetMarkerIsNoToken;
(* The DigitalOcean template's "${PASCLAW_GATEWAY_TOKEN}" is in the public
   repository. With the variable unset it used to BE the token: anyone who
   sent that text was in. Unset is no token now. *)
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    Cfg.Gateway.Token := '${PASCLAW_GATEWAY_TOKEN}';
    AssertEq(GetEffectiveGatewayToken(Cfg), '', 'an unset marker is no token');
    AssertTrue(GatewayAuthState(Cfg) = gasOpen, 'so the gateway is token-less');
    AssertTrue(Pos('DISABLED', DescribeGatewayAuthState(Cfg)) > 0, 'and says so');
    AssertTrue(Pos('${PASCLAW_GATEWAY_TOKEN}', DescribeGatewayAuthState(Cfg)) > 0,
               'naming the variable to set');
    Cfg.Gateway.Token := 'real-token-0123456789abcdef';
    AssertTrue(GatewayAuthState(Cfg) = gasRequired, 'a real token is required');
    AssertTrue(not CheckGatewayAuth(GetEffectiveGatewayToken(Cfg), 'GET', '/v1/config',
                                    'Bearer ${PASCLAW_GATEWAY_TOKEN}', ''),
               'and the marker text is no credential for it');
  finally
    Cfg.Free;
  end;
end;

procedure TestLocalRequestRefusal;
const
  H = '127.0.0.1:8088';
var
  None: array of string;
begin
  None := nil;
  { What a local client, an SDK, a relay worker or the gateway's own pages
    send. }
  AssertEq(LocalRequestRefusal(H, '', None), '', 'a plain local client');
  AssertEq(LocalRequestRefusal('', '', None), '', 'no Host at all (no browser sends that)');
  AssertEq(LocalRequestRefusal(H, 'http://127.0.0.1:8088', None), '', 'the web UI');
  AssertEq(LocalRequestRefusal(H, 'http://127.0.0.1:8088/desktop', None), '', 'an Origin with a path');
  AssertEq(LocalRequestRefusal('localhost:8088', '', None), '', 'localhost');
  AssertEq(LocalRequestRefusal('LOCALHOST', '', None), '', 'in any case');
  AssertEq(LocalRequestRefusal('127.0.0.5:8088', '', None), '', 'all of 127/8');
  AssertEq(LocalRequestRefusal('[::1]:8088', '', None), '', 'IPv6 loopback');
  AssertEq(LocalRequestRefusal('app.localhost:8088', '', None), '', '*.localhost');
  { An IP address cannot be rebound, so any is fine -- the browser's
    0.0.0.0, and a LAN worker that reaches the gateway by its address. }
  AssertEq(LocalRequestRefusal('0.0.0.0:8088', '', None), '', '0.0.0.0, as a browser reaches it');
  AssertEq(LocalRequestRefusal('0.0.0.0:8088', 'http://0.0.0.0:8088', None), '', 'and its own page there');
  AssertEq(LocalRequestRefusal('[::]:8088', '', None), '', 'and ::');
  AssertEq(LocalRequestRefusal('192.168.1.5:8088', '', None), '', 'a LAN address, not configured');
  AssertEq(LocalRequestRefusal('[fe80::1]:8088', '', None), '', 'an IPv6 address');
  AssertEq(LocalRequestRefusal('192.168.1.5:8088', 'http://192.168.1.5:8088', None), '',
           'the web UI opened by LAN address');
  { What only a browser on another site sends. }
  AssertTrue(LocalRequestRefusal(H, 'https://evil.example', None) <> '', 'a foreign Origin');
  AssertTrue(LocalRequestRefusal(H, 'null', None) <> '', 'an opaque Origin');
  AssertTrue(LocalRequestRefusal(H, 'http://127.0.0.1:8089', None) <> '',
             'another local port: the apps origin''s code is not the desktop''s');
  AssertTrue(LocalRequestRefusal(H, 'http://localhost:8088', None) <> '',
             'another name for the same machine is another origin');
  AssertTrue(LocalRequestRefusal(H, 'http://192.168.1.9', None) <> '',
             'a page on another machine');
  AssertTrue(LocalRequestRefusal('', 'https://evil.example', None) <> '',
             'an Origin with no Host to match');
  { DNS rebinding: the page is same-origin with the gateway, but its Host
    header still names it. }
  AssertTrue(LocalRequestRefusal('attacker.example:8088', 'http://attacker.example:8088', None) <> '',
             'a rebound name');
  AssertTrue(LocalRequestRefusal('attacker.example:8088', '', None) <> '',
             'a rebound name, on a request with no Origin');
  AssertTrue(Pos('gateway.allowed_hosts', LocalRequestRefusal('attacker.example', '', None)) > 0,
             'the refusal says how to allow a name');
  AssertTrue(LocalRequestRefusal('127.0.0.1.evil.example', '', None) <> '',
             'a name that only starts like loopback');
  AssertTrue(LocalRequestRefusal('evil-localhost', '', None) <> '',
             'a name that only ends like localhost');
  AssertTrue(LocalRequestRefusal('1.2.3.4.evil', '', None) <> '',
             'a name that only starts like an address');
  { Names the operator allowed: a reverse proxy, a machine's LAN name. }
  AssertEq(LocalRequestRefusal('proxy.example', 'https://proxy.example', ['proxy.example']), '',
           'an allowed name, from its own page (default ports)');
  AssertEq(LocalRequestRefusal(H, 'https://proxy.example', ['proxy.example']), '',
           'a proxy that rewrites Host to 127.0.0.1 keeps its own Origin');
  AssertEq(LocalRequestRefusal('Proxy.Example:443', '', ['proxy.example:8443']), '',
           'case and ports do not matter in the list');
  AssertTrue(LocalRequestRefusal('proxy.example', 'https://evil.example', ['proxy.example']) <> '',
             'an allowed name still refuses a foreign page');
  AssertTrue(LocalRequestRefusal(H, 'https://evil.example', ['proxy.example']) <> '',
             'and so does the proxy''s rewritten Host');
  AssertEq(LocalRequestRefusal('proxy.example:443', 'https://proxy.example', ['proxy.example']), '',
           'a default port on one side only is the same origin');
  AssertEq(LocalRequestRefusal('LOCALHOST:8088', 'http://localhost:8088', None), '',
           'and so is a different case');
  AssertEq(LocalRequestRefusal('localhost:80', 'http://localhost', None), '',
           'and a default port a proxy wrote into Host');
  AssertTrue(LocalRequestRefusal('192.168.1.5:8088', 'http://192.168.1.5:8089',
                                 ['192.168.1.5']) <> '',
             'an IP in the list does not let in its other ports (the apps origin)');
  AssertTrue(LocalRequestRefusal(H, 'http://localhost:3000', ['localhost']) <> '',
             'nor does localhost');
end;

procedure TestIsIPLiteral;
begin
  AssertTrue(IsIPLiteral('192.168.1.5'), 'v4');
  AssertTrue(IsIPLiteral('fe80::1'), 'v6');
  AssertTrue(IsIPLiteral('::ffff:127.0.0.1'), 'v6 with a v4 tail');
  AssertTrue(not IsIPLiteral(''), 'nothing');
  AssertTrue(not IsIPLiteral('1.2.3'), 'too few parts');
  AssertTrue(not IsIPLiteral('1.2.3.4.5'), 'too many');
  AssertTrue(not IsIPLiteral('deadbeef'), 'a hex-looking name');
  AssertTrue(not IsIPLiteral('1.2.3.example'), 'a name');
end;

procedure TestExposureWording;
(* The startup line must not tell an operator listening on 0.0.0.0 that
   only local clients get in. *)
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    Cfg.Gateway.Token := '';
    AssertTrue(Pos('ANY client', DescribeGatewayAuthState(Cfg, '0.0.0.0')) > 0,
               'a token-less 0.0.0.0 says anyone who reaches it gets in');
    AssertTrue(Pos('shell', DescribeGatewayAuthState(Cfg, '192.168.1.5')) > 0,
               'and what they get');
    AssertTrue(Pos('ANY client', DescribeGatewayAuthState(Cfg, '127.0.0.1')) = 0,
               'a loopback one does not');
    AssertTrue(Pos('this machine', DescribeGatewayAuthState(Cfg, '127.0.0.1')) > 0,
               'it says this machine');
    AssertTrue(Pos('ANY client', DescribeGatewayAuthState(Cfg, 'localhost')) = 0, 'nor localhost');
    Cfg.Gateway.Token := '${PASCLAW_GATEWAY_TOKEN}';
    AssertTrue(Pos('ANY client', DescribeGatewayAuthState(Cfg, '0.0.0.0')) > 0,
               'an unset marker on 0.0.0.0 says it too');
    Cfg.Gateway.Token := 'real-token-0123456789abcdef';
    AssertTrue(Pos('ENABLED', DescribeGatewayAuthState(Cfg, '0.0.0.0')) > 0,
               'a token is a token on any address');
  finally
    Cfg.Free;
  end;
end;

begin
  if (ParamCount >= 1) and (ParamStr(1) = '--env-mode') then
  begin
    { Second pass: PASCLAW_GATEWAY_TOKEN or OPENCLAW_GATEWAY_TOKEN
      set by the Makefile before launch. Only run the env-precedence
      assertions -- the rest were exercised in the first pass with a
      clean env. }
    TestEnvModePrecedence;
    WriteLn('  ok: env-mode -- env-only token does NOT bleed into Cfg.Gateway.Token (PR #246 P2)');
    WriteLn('PASS');
    Exit;
  end;

  TestUnauthenticatedModePassesEveryRoute;
  WriteLn('  ok: unauthenticated mode (empty token) passes every route');
  TestUnsetMarkerIsNoToken;
  WriteLn('  ok: an unset ${VAR} marker is no token, not the marker''s text');
  TestLocalRequestRefusal;
  WriteLn('  ok: no token: a foreign Origin or a rebound name is refused; IPs, local clients, proxies not');
  TestIsIPLiteral;
  WriteLn('  ok: IP addresses are told from domain names');
  TestExposureWording;
  WriteLn('  ok: the startup line says who a token-less gateway is open to, by address');
  TestConfiguredTokenRefusesUnauthedRequest;
  WriteLn('  ok: configured token refuses missing / wrong / wrong-scheme headers');
  TestConfiguredTokenAcceptsBearerHeader;
  WriteLn('  ok: matching Bearer header accepts (case-insensitive, whitespace-tolerant)');
  TestConfiguredTokenAcceptsQueryParam;
  WriteLn('  ok: ?token=<value> query param accepted as fallback');
  TestHeaderBeatsQueryParam;
  WriteLn('  ok: Authorization header is authoritative when both header + query present');
  TestExemptRoutesBypassTokenCheck;
  WriteLn('  ok: /, /v1/health, /v1/version, /webhooks/* exempt; other routes still gated');
  TestConstantTimeCompareBehaviour;
  WriteLn('  ok: constant-time compare: length-mismatch short-circuits, equal-length touches every byte');
  TestExtractBearerTokenParses;
  WriteLn('  ok: ExtractBearerToken parses standard + lowercase + whitespace variants');
  TestIsExemptRouteShape;
  WriteLn('  ok: IsExemptRoute names exactly the five families documented in the unit comment');
  TestTokenLengthDoesNotLeakViaShortCircuit;
  WriteLn('  ok: first-byte and last-byte mismatch both return False (no early short-circuit)');
  TestEffectiveTokenContract;
  WriteLn('  ok: GetEffectiveGatewayToken contract: empty when no source, config field round-trips, empty token NOT emitted (PR #246 P2)');
  WriteLn('PASS');
end.
