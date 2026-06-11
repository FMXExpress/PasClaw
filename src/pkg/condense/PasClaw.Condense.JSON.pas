(*
  PasClaw.Condense.JSON - content-type-aware compression for tool output
  that happens to be JSON. Sits alongside the existing per-command
  filters (PasClaw.Tools.Shell.Filters, PasClaw.Tools.OutputCache) and
  applies BEFORE the byte-budget truncate so a 200 KB tool result that
  is 80% repetition condenses to a 4 KB structural summary the model
  can still reason about, instead of getting a head + tail snippet
  with the middle silently stashed.

  What gets condensed:

    - Arrays of more than MaxArrayItems elements -> show first N + 1,
      then "...K more items" as a synthetic string element, then the
      LAST element so the model sees the shape at both ends. An MCP
      tool that returns a 300-row "search_results" array becomes
      `[ {...row 0...}, {...row 1...}, "...297 more items",
        {...row 299...} ]`.

    - String literals longer than MaxStringLen -> ellipsized to
      "<first half>...<last quarter>" so the model still sees the
      shape (file paths, URLs, error messages stay recognisable at
      both ends).

    - Object keys are preserved verbatim. The condenser cares about
      STRUCTURE; a hash map with 50 keys where each key carries a
      bool flag is meaningful at full fidelity.

    - Primitive values (numbers, booleans, null) pass through
      verbatim.

    - Depth limit: defensive cap so a pathological self-referential
      blob (rare in JSON-the-format, but the parser tolerates it)
      can't OOM us. At MaxDepth the condenser emits "...".

  What's NOT condensed:

    - Non-JSON. The parser bails on first malformed token and the
      caller falls back to the original string. We treat a parse
      failure as "not really JSON" and skip condensation rather than
      throw.

    - Bodies smaller than MaxBytes. The whole point is saving the
      model's attention on big blobs; a 200-byte response is fine
      verbatim.

  Where this hooks in: RunToolLoop's per-result body, after the
  raw tool output and BEFORE PasClaw.Tools.OutputCache decides
  whether to stash + head/tail truncate. The condenser keeps
  the model's view structural; the cache stays the fallback for
  bodies that are still too large after condensation (binary
  blobs, opaque text, etc.).

  We deliberately do NOT parse via PasClaw.JSON's TJsonObject:
  the wrapper lacks key enumeration cross-compiler, and a raw
  walker keeps this unit self-contained and free of fpjson /
  System.JSON imports. The walker tolerates whitespace, JSON
  string escapes, all four JSON literals, and both number forms.
*)
unit PasClaw.Condense.JSON;

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
  TJSONCondenseOptions = record
    MaxBytes:       Integer;  { do not condense bodies smaller than this; default 4096 }
    MaxArrayItems:  Integer;  { arrays with more than this -> collapse; default 6 }
    MaxStringLen:   Integer;  { strings longer than this -> ellipsize; default 120 }
    MaxDepth:       Integer;  { recursion guard; default 16 }
  end;

function DefaultJSONCondenseOptions: TJSONCondenseOptions;

{ MaybeCondenseJSON tries to condense Body as JSON. Returns the
  condensed text on success, or Body verbatim when:

    - Body is shorter than Opts.MaxBytes (nothing to gain),
    - Body doesn't parse as JSON (gracefully fall through),
    - condensation produced something LARGER than the input
      (degenerate case: small arrays with deeply nested objects
      where the synthetic "N more" element is heavier than the
      original; we refuse to make the situation worse).

  Never throws -- malformed JSON returns the original string. }
function MaybeCondenseJSON(const Body: string;
                            const Opts: TJSONCondenseOptions): string; overload;
function MaybeCondenseJSON(const Body: string): string; overload;

implementation

function DefaultJSONCondenseOptions: TJSONCondenseOptions;
begin
  Result.MaxBytes      := 4096;
  Result.MaxArrayItems := 6;
  Result.MaxStringLen  := 120;
  Result.MaxDepth      := 16;
end;

type
  TWalker = record
    Src:    string;
    Len:    Integer;
    Pos:    Integer;       { 1-based, matches Pascal string indexing }
    Opts:   TJSONCondenseOptions;
    Failed: Boolean;
  end;

procedure EmitValue(var W: TWalker; SB: TStringBuilder; Depth: Integer); forward;

procedure FailParse(var W: TWalker);
begin
  W.Failed := True;
end;

procedure SkipWS(var W: TWalker);
begin
  while (W.Pos <= W.Len) and
        ((W.Src[W.Pos] = ' ') or (W.Src[W.Pos] = #9) or
         (W.Src[W.Pos] = #10) or (W.Src[W.Pos] = #13)) do
    Inc(W.Pos);
end;

function PeekChar(const W: TWalker): Char;
begin
  if W.Pos <= W.Len then Result := W.Src[W.Pos] else Result := #0;
end;

procedure ReadString(var W: TWalker; out S: string);
{ Read a JSON string literal at W.Pos (expects to start ON the leading
  quote). Returns the literal including the surrounding quotes and
  preserving every escape sequence verbatim -- the condenser doesn't
  care about decoded contents, only byte length for the ellipsis
  decision. }
var
  Start: Integer;
  C: Char;
begin
  S := '';
  if PeekChar(W) <> '"' then begin FailParse(W); Exit; end;
  Start := W.Pos;
  Inc(W.Pos);  { past opening quote }
  while W.Pos <= W.Len do
  begin
    C := W.Src[W.Pos];
    if C = '\' then
    begin
      { Skip the escape's payload. Most are single-char; \uXXXX is
        four hex digits. The walker doesn't validate the hex; an
        invalid escape just lands us partway through. }
      if W.Pos + 1 > W.Len then begin FailParse(W); Exit; end;
      Inc(W.Pos, 2);
      if (W.Pos - 2 <= W.Len) and (W.Src[W.Pos - 1] = 'u') then
        Inc(W.Pos, 4);
      Continue;
    end;
    if C = '"' then
    begin
      Inc(W.Pos);  { past closing quote }
      S := Copy(W.Src, Start, W.Pos - Start);
      Exit;
    end;
    Inc(W.Pos);
  end;
  FailParse(W);
end;

function AdvanceCodePoint(const S: string; var P: Integer): Boolean;
{ Advance P past one logical character in a JSON string body --
  either a complete escape sequence ('\X' or '\uXXXX') or one
  UTF-8 byte sequence (1-4 bytes). Returns False if we ran off the
  end mid-escape or hit the closing quote at P. The condenser uses
  this to enumerate safe split positions so the head/tail join
  never falls INSIDE an escape (which would emit invalid JSON like
  "head\..." or "...\uXX...") and never inside a multi-byte UTF-8
  rune (which would emit a half-formed character).

  AdvanceCodePoint is forgiving: a malformed UTF-8 lead byte
  advances by 1 instead of failing, so the worst case is a
  conservative split rather than a refusal to condense. }
var
  C: Char;
  B: Byte;
begin
  Result := False;
  if (P < 1) or (P > Length(S)) then Exit;
  C := S[P];
  if C = '"' then Exit;     { closing quote -- string body done }
  if C = '\' then
  begin
    if P + 1 > Length(S) then Exit;
    if S[P + 1] = 'u' then
    begin
      if P + 5 > Length(S) then Exit;
      Inc(P, 6);
    end
    else
      Inc(P, 2);
    Result := True;
    Exit;
  end;
  B := Ord(C);
  if (B and $80) = 0 then
    Inc(P)
  else if (B and $E0) = $C0 then
  begin
    if P + 1 > Length(S) then Exit;
    Inc(P, 2);
  end
  else if (B and $F0) = $E0 then
  begin
    if P + 2 > Length(S) then Exit;
    Inc(P, 3);
  end
  else if (B and $F8) = $F0 then
  begin
    if P + 3 > Length(S) then Exit;
    Inc(P, 4);
  end
  else
    Inc(P);                 { malformed lead -- consume one byte }
  Result := True;
end;

procedure EmitCondensedString(SB: TStringBuilder; const Raw: string;
                               MaxLen: Integer);
{ Raw includes the surrounding double quotes. When the inner length
  exceeds MaxLen, keep a HEAD prefix + "..." + a TAIL suffix inside
  the quotes so the result is still valid JSON. The split positions
  are picked from a precomputed list of SAFE code-point boundaries
  (see AdvanceCodePoint) so the join never lands inside a JSON
  escape sequence or a UTF-8 multi-byte rune -- Codex P2 on PR #223:
  the previous Copy(Raw, 2, HeadLen) cut blindly at arbitrary byte
  positions and could emit "head\..." or "...\uXX...", which is not
  parseable JSON.

  Boundary distribution: ~2/3 of MaxLen budget goes to head, ~1/3 to
  tail. Paths / URLs / error prefixes stay grep-recognisable at the
  front; filenames / status codes / extension fragments survive at
  the tail. When no safe split is possible within budget (a giant
  string of one continuous escape or multi-byte rune chain), we
  fall back to emitting the original verbatim -- the caller's
  outer "did we shrink it?" check then keeps the original. }
var
  InnerLen, HeadTarget, TailTarget: Integer;
  Boundaries: array of Integer;
  BCap, BCount, P, i: Integer;
  HeadEnd, TailStart: Integer;
begin
  InnerLen := Length(Raw) - 2;
  if InnerLen <= MaxLen then
  begin
    SB.Append(Raw);
    Exit;
  end;

  HeadTarget := (MaxLen * 2) div 3;
  TailTarget := MaxLen - HeadTarget;
  if HeadTarget < 8 then HeadTarget := 8;
  if TailTarget < 8 then TailTarget := 8;

  { Enumerate safe code-point start positions within the body.
    Boundaries[k] = the 1-based index in Raw where code point k
    begins. Boundaries[BCount] (the sentinel) is the position of the
    closing quote, so any byte slice Boundaries[i]..Boundaries[j]-1
    lies on safe boundaries on both ends. }
  BCap := InnerLen + 2;
  SetLength(Boundaries, BCap);
  BCount := 0;
  P := 2;
  while P < Length(Raw) do
  begin
    Boundaries[BCount] := P;
    Inc(BCount);
    if BCount >= BCap then Break;
    if not AdvanceCodePoint(Raw, P) then Break;
  end;
  if BCount >= BCap then
  begin
    { Defensive: bail to verbatim rather than risk an out-of-range
      sentinel write. The outer inflation check still applies. }
    SB.Append(Raw);
    Exit;
  end;
  Boundaries[BCount] := Length(Raw);  { = closing-quote position }

  { HeadEnd: largest boundary index whose byte-offset-from-body-start
    fits in HeadTarget. }
  HeadEnd := 0;
  for i := 0 to BCount do
  begin
    if Boundaries[i] - 2 <= HeadTarget then
      HeadEnd := i
    else
      Break;
  end;

  { TailStart: smallest boundary index whose bytes-to-end fit in
    TailTarget. Iterate forward and stop at the first hit. }
  TailStart := BCount;
  for i := 0 to BCount do
    if (Length(Raw) - Boundaries[i]) <= TailTarget then
    begin
      TailStart := i;
      Break;
    end;

  { If head and tail would overlap or touch, no safe split within
    budget -- emit verbatim. The condenser's outer length-check then
    surfaces the original to the caller. }
  if TailStart <= HeadEnd then
  begin
    SB.Append(Raw);
    Exit;
  end;

  SB.Append('"');
  if Boundaries[HeadEnd] > 2 then
    SB.Append(Copy(Raw, 2, Boundaries[HeadEnd] - 2));
  SB.Append('...');
  if Boundaries[TailStart] < Length(Raw) then
    SB.Append(Copy(Raw, Boundaries[TailStart],
                    Length(Raw) - Boundaries[TailStart]));
  SB.Append('"');
end;

procedure EmitLiteral(var W: TWalker; SB: TStringBuilder);
{ true / false / null. We don't bother validating the spelling;
  whatever runs of letters lands here gets emitted. Misspelled
  literals would have failed real JSON parsing upstream. }
var
  Start: Integer;
begin
  Start := W.Pos;
  while (W.Pos <= W.Len) and
        (((W.Src[W.Pos] >= 'a') and (W.Src[W.Pos] <= 'z')) or
         ((W.Src[W.Pos] >= 'A') and (W.Src[W.Pos] <= 'Z'))) do
    Inc(W.Pos);
  SB.Append(Copy(W.Src, Start, W.Pos - Start));
end;

procedure EmitNumber(var W: TWalker; SB: TStringBuilder);
{ A JSON number: optional minus, digits, optional fraction, optional
  exponent. The walker doesn't validate -- whatever character run is
  number-shaped passes through. Real JSON would have failed parsing
  upstream if it were malformed. }
var
  Start: Integer;
  C: Char;
begin
  Start := W.Pos;
  while W.Pos <= W.Len do
  begin
    C := W.Src[W.Pos];
    if ((C >= '0') and (C <= '9')) or
       (C = '-') or (C = '+') or (C = '.') or
       (C = 'e') or (C = 'E') then
      Inc(W.Pos)
    else
      Break;
  end;
  SB.Append(Copy(W.Src, Start, W.Pos - Start));
end;

procedure EmitObject(var W: TWalker; SB: TStringBuilder; Depth: Integer);
var
  KeyStr: string;
  First: Boolean;
begin
  if PeekChar(W) <> '{' then begin FailParse(W); Exit; end;
  Inc(W.Pos);  // past open-brace
  SB.Append('{');
  First := True;
  SkipWS(W);
  while PeekChar(W) <> '}' do
  begin
    if W.Pos > W.Len then begin FailParse(W); Exit; end;
    if not First then SB.Append(',');
    First := False;
    SkipWS(W);
    ReadString(W, KeyStr);
    if W.Failed then Exit;
    SB.Append(KeyStr);
    SkipWS(W);
    if PeekChar(W) <> ':' then begin FailParse(W); Exit; end;
    Inc(W.Pos);
    SB.Append(':');
    SkipWS(W);
    EmitValue(W, SB, Depth + 1);
    if W.Failed then Exit;
    SkipWS(W);
    if PeekChar(W) = ',' then
    begin
      Inc(W.Pos);
      SkipWS(W);
    end;
  end;
  Inc(W.Pos);  // past close-brace
  SB.Append('}');
end;

procedure SkipValue(var W: TWalker; Depth: Integer); forward;

procedure SkipString(var W: TWalker);
var
  Sink: string;
begin
  ReadString(W, Sink);
end;

procedure SkipObject(var W: TWalker; Depth: Integer);
begin
  if PeekChar(W) <> '{' then begin FailParse(W); Exit; end;
  Inc(W.Pos);
  SkipWS(W);
  while PeekChar(W) <> '}' do
  begin
    if W.Pos > W.Len then begin FailParse(W); Exit; end;
    SkipString(W);
    if W.Failed then Exit;
    SkipWS(W);
    if PeekChar(W) <> ':' then begin FailParse(W); Exit; end;
    Inc(W.Pos);
    SkipWS(W);
    SkipValue(W, Depth + 1);
    if W.Failed then Exit;
    SkipWS(W);
    if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
  end;
  Inc(W.Pos);
end;

procedure SkipArray(var W: TWalker; Depth: Integer);
begin
  if PeekChar(W) <> '[' then begin FailParse(W); Exit; end;
  Inc(W.Pos);
  SkipWS(W);
  while PeekChar(W) <> ']' do
  begin
    if W.Pos > W.Len then begin FailParse(W); Exit; end;
    SkipValue(W, Depth + 1);
    if W.Failed then Exit;
    SkipWS(W);
    if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
  end;
  Inc(W.Pos);
end;

procedure SkipPrimitive(var W: TWalker);
var
  C: Char;
begin
  C := PeekChar(W);
  if (C = 't') or (C = 'f') or (C = 'n') then
  begin
    while (W.Pos <= W.Len) and
          (((W.Src[W.Pos] >= 'a') and (W.Src[W.Pos] <= 'z'))) do
      Inc(W.Pos);
  end
  else
  begin
    while (W.Pos <= W.Len) and
          (((W.Src[W.Pos] >= '0') and (W.Src[W.Pos] <= '9')) or
           (W.Src[W.Pos] = '-') or (W.Src[W.Pos] = '+') or
           (W.Src[W.Pos] = '.') or
           (W.Src[W.Pos] = 'e') or (W.Src[W.Pos] = 'E')) do
      Inc(W.Pos);
  end;
end;

procedure SkipValue(var W: TWalker; Depth: Integer);
var
  C: Char;
begin
  SkipWS(W);
  C := PeekChar(W);
  case C of
    '{': SkipObject(W, Depth);
    '[': SkipArray(W, Depth);
    '"': SkipString(W);
  else
    SkipPrimitive(W);
  end;
end;

procedure EmitArray(var W: TWalker; SB: TStringBuilder; Depth: Integer);
{ Two-pass: first count the items by skipping the whole array, then
  rewind to the array start and emit either verbatim (if count <=
  MaxArrayItems) or the collapsed form (first N, "...K more items"
  synthetic, last 1). }
var
  StartPos, EndPos, Count, KeepFront: Integer;
  ScanW: TWalker;
  First: Boolean;
begin
  if PeekChar(W) <> '[' then begin FailParse(W); Exit; end;
  StartPos := W.Pos;

  { Pass 1: count items in this array. }
  ScanW := W;
  Inc(ScanW.Pos);  // past open-bracket
  SkipWS(ScanW);
  Count := 0;
  while PeekChar(ScanW) <> ']' do
  begin
    if ScanW.Pos > ScanW.Len then begin FailParse(W); Exit; end;
    SkipValue(ScanW, Depth + 1);
    if ScanW.Failed then begin W.Failed := True; Exit; end;
    Inc(Count);
    SkipWS(ScanW);
    if PeekChar(ScanW) = ',' then begin Inc(ScanW.Pos); SkipWS(ScanW); end;
  end;
  Inc(ScanW.Pos);  // past close-bracket
  EndPos := ScanW.Pos;

  { Verbatim path: rewind and emit every element as the recursive
    walker normally would (which still respects per-element
    condensation for nested arrays / long strings). }
  if Count <= W.Opts.MaxArrayItems then
  begin
    W.Pos := StartPos;
    Inc(W.Pos);
    SB.Append('[');
    First := True;
    SkipWS(W);
    while PeekChar(W) <> ']' do
    begin
      if W.Pos > W.Len then begin FailParse(W); Exit; end;
      if not First then SB.Append(',');
      First := False;
      EmitValue(W, SB, Depth + 1);
      if W.Failed then Exit;
      SkipWS(W);
      if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
    end;
    Inc(W.Pos);
    SB.Append(']');
    Exit;
  end;

  { Collapsed path: keep the first KeepFront elements, then emit a
    synthetic "...N more items" string, then the LAST element so the
    model sees both ends. KeepFront = MaxArrayItems - 2 (one slot for
    the "..." synthetic, one for the trailing element). }
  KeepFront := W.Opts.MaxArrayItems - 2;
  if KeepFront < 1 then KeepFront := 1;

  W.Pos := StartPos;
  Inc(W.Pos);
  SkipWS(W);
  SB.Append('[');
  First := True;
  { Emit the front KeepFront elements. }
  while First or (W.Pos < EndPos) do
  begin
    if PeekChar(W) = ']' then Break;
    if W.Pos > W.Len then begin FailParse(W); Exit; end;
    if KeepFront <= 0 then Break;
    if not First then SB.Append(',');
    First := False;
    EmitValue(W, SB, Depth + 1);
    if W.Failed then Exit;
    Dec(KeepFront);
    SkipWS(W);
    if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
  end;
  { Skip middle elements (everything except the last). }
  while PeekChar(W) <> ']' do
  begin
    { Look ahead one element; if there's another comma after, skip
      this element and keep going. If there's not (= this is the
      last), break out and emit it as the trailing slot. }
    ScanW := W;
    SkipValue(ScanW, Depth + 1);
    if ScanW.Failed then begin W.Failed := True; Exit; end;
    SkipWS(ScanW);
    if PeekChar(ScanW) = ']' then Break;
    { Not the last -- advance past this element. }
    W := ScanW;
    if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
  end;
  { Insert the "...N more items" marker. Count - KeepFront(original)
    - 1(trailing) is the suppressed count; reconstruct from
    Opts.MaxArrayItems. }
  SB.Append(',"...');
  SB.Append(IntToStr(Count - (W.Opts.MaxArrayItems - 2) - 1));
  SB.Append(' more items"');
  { Emit the trailing element. }
  if PeekChar(W) <> ']' then
  begin
    SB.Append(',');
    EmitValue(W, SB, Depth + 1);
    if W.Failed then Exit;
    SkipWS(W);
    if PeekChar(W) = ',' then begin Inc(W.Pos); SkipWS(W); end;
  end;
  if PeekChar(W) <> ']' then begin FailParse(W); Exit; end;
  Inc(W.Pos);
  SB.Append(']');
end;

procedure EmitValue(var W: TWalker; SB: TStringBuilder; Depth: Integer);
var
  C: Char;
  Raw: string;
begin
  SkipWS(W);
  if Depth >= W.Opts.MaxDepth then
  begin
    SB.Append('"..."');
    { Still advance the walker past whatever value is there so
      siblings keep parsing. }
    SkipValue(W, Depth);
    Exit;
  end;
  C := PeekChar(W);
  case C of
    '{': EmitObject(W, SB, Depth);
    '[': EmitArray(W, SB, Depth);
    '"':
      begin
        ReadString(W, Raw);
        if not W.Failed then
          EmitCondensedString(SB, Raw, W.Opts.MaxStringLen);
      end;
    't', 'f', 'n': EmitLiteral(W, SB);
  else
    EmitNumber(W, SB);
  end;
end;

function MaybeCondenseJSON(const Body: string;
                            const Opts: TJSONCondenseOptions): string;
var
  W: TWalker;
  SB: TStringBuilder;
  Condensed: string;
begin
  Result := Body;
  if Length(Body) <= Opts.MaxBytes then Exit;
  W.Src    := Body;
  W.Len    := Length(Body);
  W.Pos    := 1;
  W.Opts   := Opts;
  W.Failed := False;
  SB := TStringBuilder.Create;
  try
    EmitValue(W, SB, 0);
    if W.Failed then Exit;
    { Tolerate trailing whitespace -- e.g. a trailing newline from
      `curl -s`. We're not strict about additional non-WS after the
      root value; if it's there, treat as parse failure (caller gets
      the original body). }
    SkipWS(W);
    if W.Pos <= W.Len then Exit;
    Condensed := SB.ToString;
    { Defensive: if condensation somehow inflated the body (small
      array of deeply-nested objects where the synthetic marker is
      heavier than the original), prefer the verbatim source. }
    if Length(Condensed) >= Length(Body) then Exit;
    Result := Condensed;
  finally
    SB.Free;
  end;
end;

function MaybeCondenseJSON(const Body: string): string;
begin
  Result := MaybeCondenseJSON(Body, DefaultJSONCondenseOptions);
end;

end.
