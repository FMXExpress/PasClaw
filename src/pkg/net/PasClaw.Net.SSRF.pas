(*
  PasClaw.Net.SSRF - Server-Side Request Forgery guard for outbound
  URL fetches.

  The model can hand any URL to web_fetch. Without this guard, an
  agent running on (e.g.) an EC2 instance can be tricked into
  fetching http://169.254.169.254/latest/meta-data/iam/security-
  credentials/<role> and leaking the instance's temporary AWS
  credentials. Same trick works against GCP / Azure metadata, against
  internal services on the operator's LAN, and against localhost
  services (Postgres on 5432, Redis on 6379, etc.) that were never
  meant to be reachable by the model.

  The guard does two things:

    1. Pre-check: parse the URL, resolve the hostname to one or more
       IPv4 addresses, refuse if ANY of them fall in a blocked range.
       "Any" so a DNS record with both public and private A records
       can't smuggle a request through.

    2. Redirect re-check: after a 3xx redirect, the agent's HTTP
       client re-resolves the new target. The redirect handler in
       web_fetch wires URLIsLocal in so a public->private redirect
       gets aborted mid-flight.

  Known gaps (intentional, documented for the security-conscious):

    - IPv6 hosts are not blocklisted. The most common attack
      vectors (cloud metadata, internal LAN services, localhost
      ports) all surface on IPv4. Adding v6 ranges (::1, fc00::/7,
      fe80::/10, ::ffff:0:0/96 IPv4-mapped, etc.) is straightforward
      when someone reports a v6-specific incident.

    - DNS rebinding: this guard re-resolves at request time, not
      at every TCP packet. A determined attacker could swap the A
      record between the pre-check and the actual connect.
      Mitigation requires pinning the TCP connection to the IP
      that passed validation, which Indy doesn't make easy.
      Accepted residual risk; same gap picoclaw ships with.

  Blocked IPv4 ranges (CIDR / decimal):
    0.0.0.0/8          unspecified / kernel localhost on some BSDs
    10.0.0.0/8         RFC1918 corporate LAN
    100.64.0.0/10      RFC6598 carrier-grade NAT
    127.0.0.0/8        loopback (every localhost variant)
    169.254.0.0/16     link-local -- INCLUDES 169.254.169.254 cloud metadata
    172.16.0.0/12      RFC1918 corporate LAN
    192.0.0.0/24       IETF Protocol Assignments
    192.168.0.0/16     RFC1918 home LAN
    198.18.0.0/15      RFC2544 benchmark
    224.0.0.0/4        IPv4 multicast
    240.0.0.0/4        reserved
*)
unit PasClaw.Net.SSRF;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

(* Returns True if Host either parses as an IPv4 literal in a blocked
   range, or resolves (via DNS) to at least one such address. Reason
   carries a human-readable explanation when True. False means "safe
   to fetch" -- including the case where DNS resolution failed (the
   request will likely fail at connect time anyway with a clearer
   network error). *)
function HostIsLocal(const Host: string; out Reason: string): Boolean;

(* Extracts the host out of an http/https URL and runs HostIsLocal
   on it. Refuses (returns True) for malformed URLs, but does not
   refuse for non-http(s) schemes -- the caller (web_fetch) already
   filters those at its own layer. *)
function URLIsLocal(const URL: string; out Reason: string): Boolean;

implementation

uses
  IdStack, IdGlobal;

function ParseIPv4(const S: string; out V: UInt32): Boolean;
var
  Parts: array[0..3] of Integer;
  i, p, len, octet: Integer;
  C: Char;
  Got: Integer;
begin
  Result := False;
  V := 0;
  p := 1;
  len := Length(S);
  for i := 0 to 3 do
  begin
    if p > len then Exit;
    octet := 0;
    Got := 0;
    while p <= len do
    begin
      C := S[p];
      if (C >= '0') and (C <= '9') then
      begin
        octet := octet * 10 + (Ord(C) - Ord('0'));
        if octet > 255 then Exit;
        Inc(Got);
        if Got > 3 then Exit;
        Inc(p);
      end
      else
        Break;
    end;
    if Got = 0 then Exit;
    Parts[i] := octet;
    if i < 3 then
    begin
      if (p > len) or (S[p] <> '.') then Exit;
      Inc(p);
    end;
  end;
  if p <= len then Exit;   { trailing junk }
  V := (UInt32(Parts[0]) shl 24) or
       (UInt32(Parts[1]) shl 16) or
       (UInt32(Parts[2]) shl  8) or
        UInt32(Parts[3]);
  Result := True;
end;

function InRange(IP: UInt32; const NetStr: string; PrefixBits: Integer): Boolean;
var
  Net: UInt32;
  Mask: UInt32;
begin
  Result := False;
  if not ParseIPv4(NetStr, Net) then Exit;
  if PrefixBits <= 0       then Mask := 0
  else if PrefixBits >= 32 then Mask := $FFFFFFFF
  else                          Mask := UInt32($FFFFFFFF) shl (32 - PrefixBits);
  Result := (IP and Mask) = (Net and Mask);
end;

function IPv4Blocked(IP: UInt32; out Reason: string): Boolean;
type
  TBlocked = record
    Net:    string;
    Prefix: Integer;
    Label_: string;
  end;
const
  Ranges: array[0..10] of TBlocked = (
    (Net: '0.0.0.0';       Prefix: 8;  Label_: 'unspecified / kernel localhost'),
    (Net: '10.0.0.0';      Prefix: 8;  Label_: 'RFC1918 private (10.0.0.0/8)'),
    (Net: '100.64.0.0';    Prefix: 10; Label_: 'RFC6598 carrier-grade NAT'),
    (Net: '127.0.0.0';     Prefix: 8;  Label_: 'loopback (127.0.0.0/8)'),
    (Net: '169.254.0.0';   Prefix: 16; Label_: 'link-local -- cloud metadata endpoint range'),
    (Net: '172.16.0.0';    Prefix: 12; Label_: 'RFC1918 private (172.16.0.0/12)'),
    (Net: '192.0.0.0';     Prefix: 24; Label_: 'IETF Protocol Assignments'),
    (Net: '192.168.0.0';   Prefix: 16; Label_: 'RFC1918 private (192.168.0.0/16)'),
    (Net: '198.18.0.0';    Prefix: 15; Label_: 'RFC2544 benchmark'),
    (Net: '224.0.0.0';     Prefix: 4;  Label_: 'IPv4 multicast'),
    (Net: '240.0.0.0';     Prefix: 4;  Label_: 'reserved')
  );
var
  i: Integer;
begin
  Reason := '';
  for i := 0 to High(Ranges) do
    if InRange(IP, Ranges[i].Net, Ranges[i].Prefix) then
    begin
      Reason := Ranges[i].Label_;
      Exit(True);
    end;
  Result := False;
end;

type
  TIPv6Bytes = array[0..15] of Byte;

function ParseIPv6(const S: string; out B: TIPv6Bytes): Boolean;
(* Compact RFC 4291 literal parser: hex groups, one optional "::"
   run-compression, and the trailing dotted-quad form used by
   IPv4-mapped/compatible addresses (::ffff:169.254.169.254).

   Written here rather than borrowed from Indy because the guard must
   run BEFORE any socket call -- resolving through the stack to find
   out whether an address is local is exactly the round trip an SSRF
   guard exists to avoid. A zone id (fe80::1%eth0) is stripped: the
   scope does not change which range the address is in. *)
var
  Src, Head, Tail, Grp: string;
  DblPos, i, n, Code: Integer;
  HeadB, TailB: array of Byte;
  V4: UInt32;

  function SplitGroups(const Text: string; var Outp: array of Byte;
                       out Count: Integer): Boolean;
  var
    Start, k: Integer;
    Piece: string;
  begin
    Result := True;
    Count  := 0;
    if Text = '' then Exit;
    Start := 1;
    for k := 1 to Length(Text) + 1 do
      if (k > Length(Text)) or (Text[k] = ':') then
      begin
        Piece := Copy(Text, Start, k - Start);
        Start := k + 1;
        if Piece = '' then Exit(False);
        { trailing dotted-quad tail, e.g. ::ffff:1.2.3.4 }
        if Pos('.', Piece) > 0 then
        begin
          if not ParseIPv4(Piece, V4) then Exit(False);
          if Count + 4 > Length(Outp) then Exit(False);
          Outp[Count]     := Byte(V4 shr 24);
          Outp[Count + 1] := Byte(V4 shr 16);
          Outp[Count + 2] := Byte(V4 shr 8);
          Outp[Count + 3] := Byte(V4);
          Inc(Count, 4);
          Continue;
        end;
        if Length(Piece) > 4 then Exit(False);
        Val(  '$' + Piece, n, Code);
        if Code <> 0 then Exit(False);
        if (n < 0) or (n > $FFFF) then Exit(False);
        if Count + 2 > Length(Outp) then Exit(False);
        Outp[Count]     := Byte(n shr 8);
        Outp[Count + 1] := Byte(n);
        Inc(Count, 2);
      end;
  end;

var
  HeadN, TailN: Integer;
begin
  Result := False;
  FillChar(B, SizeOf(B), 0);
  Src := Trim(S);
  i := Pos('%', Src);
  if i > 0 then Src := Copy(Src, 1, i - 1);
  if Src = '' then Exit;
  if Pos(':', Src) = 0 then Exit;   { not an IPv6 literal at all }

  SetLength(HeadB, 16);
  SetLength(TailB, 16);
  DblPos := Pos('::', Src);
  if DblPos > 0 then
  begin
    Head := Copy(Src, 1, DblPos - 1);
    Tail := Copy(Src, DblPos + 2, MaxInt);
    if not SplitGroups(Head, HeadB, HeadN) then Exit;
    if not SplitGroups(Tail, TailB, TailN) then Exit;
    if HeadN + TailN > 16 then Exit;
    for i := 0 to HeadN - 1 do B[i] := HeadB[i];
    for i := 0 to TailN - 1 do B[16 - TailN + i] := TailB[i];
  end
  else
  begin
    if not SplitGroups(Src, HeadB, HeadN) then Exit;
    if HeadN <> 16 then Exit;
    for i := 0 to 15 do B[i] := HeadB[i];
  end;
  Result := True;
end;

function IPv6Blocked(const B: TIPv6Bytes; out Reason: string): Boolean;
(* Ranges that matter for SSRF. The IPv4-mapped and NAT64 cases are the
   important ones: they carry a v4 address inside a v6 literal, so the
   v4 blocklist has to be re-applied to the embedded address or
   ::ffff:169.254.169.254 walks straight past a guard that only ever
   looked at dotted quads. *)
var
  i: Integer;
  AllZero: Boolean;
  V4: UInt32;
  V4Reason: string;

  function MappedV4: Boolean;
  var
    k: Integer;
  begin
    { ::ffff:a.b.c.d -- 80 zero bits, then 0xFFFF }
    Result := False;
    for k := 0 to 9 do if B[k] <> 0 then Exit;
    if (B[10] <> $FF) or (B[11] <> $FF) then Exit;
    Result := True;
  end;

  function NAT64: Boolean;
  var
    k: Integer;
  begin
    { 64:ff9b::/96 -- the well-known prefix, and the low 32 bits are the
      embedded v4. All 96 bits must match: comparing only the leading 32
      swept in 64:ff9b:1::/48, the SEPARATE local-use translation range,
      whose low bytes are not an IPv4 address at all -- a legitimate
      translated destination there was judged by unrelated bytes (often
      as 0.0.0.0) and refused. }
    Result := False;
    if (B[0] <> $00) or (B[1] <> $64) or (B[2] <> $FF) or (B[3] <> $9B) then Exit;
    for k := 4 to 11 do
      if B[k] <> 0 then Exit;
    Result := True;
  end;

begin
  Reason := '';
  Result := True;

  AllZero := True;
  for i := 0 to 15 do if B[i] <> 0 then begin AllZero := False; Break; end;
  if AllZero then
  begin
    Reason := 'IPv6 unspecified (::)';
    Exit;
  end;

  AllZero := True;
  for i := 0 to 14 do if B[i] <> 0 then begin AllZero := False; Break; end;
  if AllZero and (B[15] = 1) then
  begin
    Reason := 'IPv6 loopback (::1)';
    Exit;
  end;

  if MappedV4 or NAT64 then
  begin
    V4 := (UInt32(B[12]) shl 24) or (UInt32(B[13]) shl 16) or
          (UInt32(B[14]) shl 8) or UInt32(B[15]);
    if IPv4Blocked(V4, V4Reason) then
    begin
      Reason := 'IPv4-in-IPv6 literal -> ' + V4Reason;
      Exit;
    end;
    { A mapped PUBLIC v4 is still a v4 request wearing a v6 costume;
      allow it, same as the bare dotted quad would be. }
    Exit(False);
  end;

  if (B[0] = $FE) and ((B[1] and $C0) = $80) then
  begin
    Reason := 'IPv6 link-local (fe80::/10)';
    Exit;
  end;
  if (B[0] and $FE) = $FC then
  begin
    Reason := 'IPv6 unique-local (fc00::/7)';
    Exit;
  end;

  Result := False;
end;

function NumericHostNotDottedQuad(const Host: string; out Reason: string): Boolean;
(* Integer, octal and hex spellings of an IPv4 address -- 2852039166,
   0xA9FEA9FE, 0251.0376.0251.0376, 127.1, and MIXED-radix forms such
   as 127.0x0.0.1 -- are accepted by inet_addr and by most resolvers,
   and are a standard way to smuggle a blocked address past a guard
   that only understands dotted quads.

   Every label is classified independently, because the radix can vary
   from label to label: an earlier version tested only whether the
   WHOLE host began with "0x" and whether every label was decimal, so
   127.0x0.0.1 was judged non-numeric and allowed straight through.

   Rejecting an all-numeric host cannot break a real hostname: a DNS
   name's rightmost label may not be all-numeric (RFC 1123), so any
   host whose labels are ALL numeric in some radix is either a valid
   dotted quad -- handled before this is reached -- or a smuggled
   spelling. Conversely a hex-looking label only counts when its whole
   body is hex digits, so ordinary names that merely begin with those
   characters (0xample.com, 0xdead.com) are left alone. *)
var
  i, Start: Integer;
  Piece: string;

  function IsNumericLabel(const L: string): Boolean;
  var
    k: Integer;
    Body: string;
  begin
    Result := False;
    if L = '' then Exit;
    if (Length(L) > 2) and (L[1] = '0') and ((L[2] = 'x') or (L[2] = 'X')) then
    begin
      Body := Copy(L, 3, MaxInt);
      for k := 1 to Length(Body) do
        if not (((Body[k] >= '0') and (Body[k] <= '9')) or
                ((Body[k] >= 'a') and (Body[k] <= 'f')) or
                ((Body[k] >= 'A') and (Body[k] <= 'F'))) then Exit;
      Exit(True);
    end;
    for k := 1 to Length(L) do
      if (L[k] < '0') or (L[k] > '9') then Exit;
    Result := True;
  end;

begin
  Result := False;
  Reason := '';
  if Host = '' then Exit;

  Start := 1;
  for i := 1 to Length(Host) + 1 do
    if (i > Length(Host)) or (Host[i] = '.') then
    begin
      Piece := Copy(Host, Start, i - Start);
      Start := i + 1;
      if not IsNumericLabel(Piece) then Exit;   { a real hostname }
    end;

  Reason := 'numeric host "' + Host + '" is not a valid dotted-quad ' +
            '(integer / octal / hex IPv4 spelling)';
  Result := True;
end;

function HostIsLocal(const Host: string; out Reason: string): Boolean;
var
  IP:  UInt32;
  Resolved: string;
  V6:  TIPv6Bytes;
begin
  Reason := '';
  if Trim(Host) = '' then
  begin
    Reason := 'empty host';
    Exit(True);
  end;

  { Short-circuit on the symbolic localhost names -- DNS-on-some-
    systems returns 127.0.0.1, on others doesn't resolve at all
    (no /etc/hosts entry, ResolveHost raises). Either way we want
    to refuse. ::1 is here too because ExtractHost unwraps
    bracketed IPv6 literals to their bare form and ::1 is the
    one IPv6 case where "you should never reach this" matches
    IPv4 loopback semantics. }
  if SameText(Host, 'localhost') or SameText(Host, 'localhost.localdomain')
     or SameText(Host, '::1') then
  begin
    Reason := 'symbolic localhost';
    Exit(True);
  end;

  { Already-numeric IPv4? No DNS lookup needed. }
  if ParseIPv4(Host, IP) then
    Exit(IPv4Blocked(IP, Reason));

  { IPv6 literal (ExtractHost has already unwrapped the brackets). }
  if Pos(':', Host) > 0 then
  begin
    if ParseIPv6(Host, V6) then
      Exit(IPv6Blocked(V6, Reason));
    { Looks like v6 but does not parse -- refuse rather than hand a
      malformed literal to the resolver and hope. }
    Reason := 'unparseable IPv6 literal "' + Host + '"';
    Exit(True);
  end;

  { Integer / hex / octal IPv4 spellings. }
  if NumericHostNotDottedQuad(Host, Reason) then Exit(True);

  { Otherwise resolve via DNS. Failures (no DNS server, NXDOMAIN,
    timeout) return False -- the request itself will fail at
    connect time with a clearer network error, no need to
    pre-mask it as SSRF. }
  try
    Resolved := GStack.ResolveHost(Host, Id_IPv4);
  except
    on E: Exception do
    begin
      Reason := 'dns lookup failed: ' + E.Message;
      Exit(False);
    end;
  end;
  if Resolved = '' then Exit(False);
  if not ParseIPv4(Resolved, IP) then Exit(False);
  Result := IPv4Blocked(IP, Reason);
end;

function ExtractHost(const URL: string): string;
var
  S, Authority: string;
  SchemeEnd, AuthEnd, HostEnd, BracketEnd, AtPos: Integer;
  i: Integer;
  C: Char;
begin
  Result := '';
  S := URL;
  SchemeEnd := Pos('://', S);
  if SchemeEnd = 0 then Exit;
  S := Copy(S, SchemeEnd + 3, MaxInt);
  if S = '' then Exit;

  { Slice the authority component out FIRST -- everything from the
    end of '://' to the first '/', '?', or '#'. Codex PR #85 P1
    caught the bug where Pos('@', S) operated on the WHOLE
    post-scheme string, so a benign-looking userinfo-shaped
    fragment inside the path (e.g.
    http://169.254.169.254/latest/meta-data/@example.com) bypassed
    the SSRF check by retargeting the host to "example.com" while
    Indy connected to the real host before the slash. Bounding
    userinfo parsing to the authority closes that hole. }
  AuthEnd := Length(S) + 1;
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if (C = '/') or (C = '?') or (C = '#') then
    begin
      AuthEnd := i;
      Break;
    end;
  end;
  Authority := Copy(S, 1, AuthEnd - 1);
  if Authority = '' then Exit;

  { Now strip userinfo from the authority ONLY. user:pass@host:port
    → host:port. The @ here is unambiguously the userinfo
    delimiter because it's still inside the authority. }
  AtPos := Pos('@', Authority);
  if AtPos > 0 then Authority := Copy(Authority, AtPos + 1, MaxInt);

  { Bracketed IPv6 literal: [::1]:port → ::1 (no v6 handling in
    HostIsLocal beyond the symbolic ::1 short-circuit -- keep the
    extraction logic anyway so a caller sees the bare host). }
  if (Length(Authority) > 0) and (Authority[1] = '[') then
  begin
    BracketEnd := Pos(']', Authority);
    if BracketEnd <= 1 then Exit;
    Result := Copy(Authority, 2, BracketEnd - 2);
    Exit;
  end;

  { Trim the port: host:port → host. Operates on the authority,
    so a real ':' inside the path or fragment further on can't
    mask the boundary. Only ':' matters here -- '/', '?', '#'
    were already used to slice the authority. }
  S := Authority;
  HostEnd := Length(S) + 1;
  for i := 1 to Length(S) do
  begin
    if S[i] = ':' then
    begin
      HostEnd := i;
      Break;
    end;
  end;
  Result := Copy(S, 1, HostEnd - 1);
end;

function URLIsLocal(const URL: string; out Reason: string): Boolean;
var
  Host: string;
begin
  Host := ExtractHost(URL);
  if Host = '' then
  begin
    Reason := 'could not parse host out of URL';
    Exit(True);   { fail closed }
  end;
  Result := HostIsLocal(Host, Reason);
end;

initialization
  TIdStack.IncUsage;

finalization
  try
    TIdStack.DecUsage;
  except
    { Shutting down. }
  end;

end.
