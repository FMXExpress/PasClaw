program http_proxy_tests;
(*
  Pins the environment-proxy decision logic added so normal (non-c2w)
  pasclaw builds honour HTTP(S)_PROXY / NO_PROXY like curl / git / npm:

    * ExtractURLHost -- host out of a URL (scheme, userinfo, port, path
      stripped; IPv6 literal unwrapped; lowercased).
    * HostBypassesProxy -- loopback always bypasses (so local ollama /
      lmstudio / vllm providers never get proxied), plus NO_PROXY list
      matching (exact, domain-suffix, leading-dot, '*').

  Pure functions -- no network, no env mutation.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Providers.HTTP;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure EqS(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

procedure IsTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure IsFalse(Cond: Boolean; const Msg: string);
begin if Cond then Fail_(Msg); end;

begin
  { --- ExtractURLHost --- }
  EqS(ExtractURLHost('https://api.openai.com/v1/chat'), 'api.openai.com', 'basic https host');
  EqS(ExtractURLHost('http://host:8080/path'), 'host', 'strips port + path');
  EqS(ExtractURLHost('https://user:pass@host.example.com:443/x'), 'host.example.com', 'strips userinfo + port');
  EqS(ExtractURLHost('http://[::1]:8000/'), '::1', 'unwraps IPv6 literal, strips port');
  EqS(ExtractURLHost('https://API.Example.COM'), 'api.example.com', 'lowercased, no path');
  { Path may legitimately contain '@' -- the authority must be isolated BEFORE
    userinfo stripping or the host comes out wrong (review P2 on #430). }
  EqS(ExtractURLHost('http://localhost/@health'), 'localhost',
      '@ in path does not corrupt the host (loopback still matches)');
  EqS(ExtractURLHost('https://api.example.com/users/@me'), 'api.example.com',
      '@ in path does not corrupt the host');
  EqS(ExtractURLHost('https://user:pass@host.example.com/p/@x'), 'host.example.com',
      'real userinfo stripped even when the path also has an @');
  WriteLn('  ok: ExtractURLHost parses scheme/userinfo/port/path/IPv6 (+ @ in path)');

  { --- HostBypassesProxy: loopback always bypasses (empty NO_PROXY) --- }
  IsTrue(HostBypassesProxy('localhost', ''),   'localhost bypasses');
  IsTrue(HostBypassesProxy('127.0.0.1', ''),   '127.0.0.1 bypasses');
  IsTrue(HostBypassesProxy('127.0.0.5', ''),   '127.0.0.0/8 bypasses');
  IsTrue(HostBypassesProxy('::1', ''),         'IPv6 loopback bypasses');
  WriteLn('  ok: loopback always bypasses the proxy (local providers safe)');

  { --- HostBypassesProxy: NO_PROXY matching --- }
  IsFalse(HostBypassesProxy('api.openai.com', ''),                 'no NO_PROXY -> proxied');
  IsTrue (HostBypassesProxy('api.openai.com', '*'),                '* bypasses everything');
  IsTrue (HostBypassesProxy('api.openai.com', 'openai.com'),       'domain-suffix match');
  IsTrue (HostBypassesProxy('api.openai.com', '.openai.com'),      'leading-dot suffix match');
  IsTrue (HostBypassesProxy('openai.com',     'openai.com'),       'exact match');
  IsTrue (HostBypassesProxy('api.openai.com', 'example.com,openai.com'), 'matches a later list entry');
  IsTrue (HostBypassesProxy('api.openai.com', 'OPENAI.COM'),       'NO_PROXY match is case-insensitive');
  IsFalse(HostBypassesProxy('notopenai.com',  'openai.com'),       'suffix must be on a dot boundary (no false positive)');
  IsFalse(HostBypassesProxy('api.openai.com', 'anthropic.com'),    'non-matching entry -> proxied');
  WriteLn('  ok: NO_PROXY exact / suffix / leading-dot / wildcard / boundary');

  WriteLn('http_proxy_tests: OK');
end.
