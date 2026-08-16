program ssrf_guard_tests;
(*
  Pins PasClaw.Net.SSRF against the bypass forms an attacker reaches for
  when a dotted-quad blocklist is the only thing in the way. Every case
  below was verified to FAIL before the IPv6 / numeric-host work landed:
  the guard blocked 169.254.169.254 but allowed ::ffff:169.254.169.254,
  0xA9FEA9FE, and 2852039166, all of which name the cloud metadata
  endpoint the unit header cites as its reason for existing.

  The "must not block" half matters just as much. An over-broad guard
  that refuses public IPv6 breaks web_fetch on any v6 host, and a first
  cut of the IPv6 parser did exactly that -- it failed to parse valid
  literals and the unparseable-means-refuse fallback swallowed them.
  These rows would have caught that on their own.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Net.SSRF;

var
  Failures: Integer = 0;

procedure Check(const URL: string; Want: Boolean; const What: string);
var
  Got: Boolean;
  Why: string;
begin
  Got := URLIsLocal(URL, Why);
  if Got <> Want then
  begin
    WriteLn(Format('FAIL: %s -- %s (blocked=%s, wanted %s)',
                   [URL, What, BoolToStr(Got, True), BoolToStr(Want, True)]));
    Inc(Failures);
  end;
end;

begin
  { Baseline: the ranges the unit always covered. }
  Check('http://169.254.169.254/latest/meta-data/', True,  'cloud metadata');
  Check('http://127.0.0.1/',        True,  'loopback');
  Check('http://localhost/',        True,  'symbolic localhost');
  Check('http://10.0.0.5/',         True,  'RFC1918 10/8');
  Check('http://192.168.1.1/',      True,  'RFC1918 192.168/16');
  Check('http://[::1]/',            True,  'IPv6 loopback');

  { IPv4 smuggled inside an IPv6 literal. }
  Check('http://[::ffff:169.254.169.254]/', True, 'IPv4-mapped metadata');
  Check('http://[::ffff:127.0.0.1]/',       True, 'IPv4-mapped loopback');
  Check('http://[0:0:0:0:0:ffff:169.254.169.254]/', True,
        'IPv4-mapped metadata, uncompressed');
  Check('http://[64:ff9b::169.254.169.254]/', True, 'NAT64-prefixed metadata');

  { IPv6 local scopes. }
  Check('http://[fe80::1]/',        True,  'link-local fe80::/10');
  Check('http://[fc00::1]/',        True,  'unique-local fc00::/7');
  Check('http://[fd00::1]/',        True,  'unique-local fd00::/8');
  Check('http://[::]/',             True,  'unspecified ::');
  Check('http://[fe80::1%25eth0]/', True,  'link-local with zone id');

  { Non-dotted-quad spellings of an IPv4 address. }
  Check('http://2852039166/',       True,  'integer form of 169.254.169.254');
  Check('http://0xA9FEA9FE/',       True,  'hex form of 169.254.169.254');
  Check('http://0251.0376.0251.0376/', True, 'octal dotted form');
  Check('http://127.1/',            True,  'short form of 127.0.0.1');

  { Must NOT block: ordinary traffic. A guard that over-refuses is a
    broken tool, and these rows are the reason the IPv6 parser bug was
    caught before it shipped. }
  Check('http://example.com/',      False, 'ordinary hostname');
  Check('http://1password.com/',    False, 'hostname starting with a digit');
  Check('http://3com.com/',         False, 'another digit-leading hostname');
  Check('http://8.8.8.8/',          False, 'public IPv4');
  Check('http://93.184.216.34/',    False, 'public IPv4');
  Check('http://[2606:2800:220:1:248:1893:25c8:1946]/', False, 'public IPv6');
  Check('http://[::ffff:93.184.216.34]/', False,
        'IPv4-mapped PUBLIC address is still public');

  { Mixed-radix labels (Codex P1 on #563). The radix can vary per label,
    so classifying the host by its leading characters missed these
    entirely -- 127.0x0.0.1 was allowed while 127.0.0.1 was blocked. }
  Check('http://127.0x0.0.1/',    True,  'decimal + hex labels mixed');
  Check('http://0177.0x0.0.1/',   True,  'octal + hex labels mixed');
  Check('http://0x7f.0.0.1/',     True,  'hex first label');

  { ...and the matching false positive: a hex-LOOKING label only counts
    when its whole body is hex digits, or ordinary names beginning with
    those two characters break. }
  Check('http://0xample.com/',    False, 'hostname merely starting with 0x');
  Check('http://0xdead.com/',     False, 'valid-hex label but a real TLD follows');

  { NAT64 is a /96, not a /32 (Codex P2 on #563). Matching only the
    leading 32 bits swept in 64:ff9b:1::/48 -- a separate local-use
    range whose low bytes are not an embedded IPv4 address. }
  Check('http://[64:ff9b::7f00:1]/', True,  'NAT64 well-known prefix, embedded loopback');
  Check('http://[64:ff9b:1::1]/',    False, 'local-use 64:ff9b:1::/48 is not NAT64');

  { The userinfo trick from PR #85 must stay closed. }
  Check('http://169.254.169.254/latest/meta-data/@example.com', True,
        'userinfo-shaped path fragment does not retarget the host');

  if Failures > 0 then
  begin
    WriteLn(Format('ssrf_guard_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('ssrf_guard_tests: OK');
end.
