program json_utf8_roundtrip_tests;
(*
  Regression: PasClaw.JSON.Parse must preserve raw UTF-8 bytes in
  parsed string values. Under FPC 3.2 fpjson's default GetJSON path
  has a joUTF8 + DefaultSystemCodePage branch in jsonreader.pp that
  silently re-encodes parsed tokens through the system codepage:

      tkString : if (joUTF8 in Options) and (DefaultSystemCodePage<>CP_UTF8) then
                   StringValue(TJSONStringType(UTF8Decode(CurrentTokenString)))

  On a container locale with DefaultSystemCodePage=0 the round-trip
  clips every non-ASCII UTF-8 lead byte -- `¶` (`C2 B6`) arrives as
  bare `B6`, `é` (`C3 A9`) as `A9`, etc. PasClaw.JSON.Parse sidesteps
  the branch by driving TJSONParser directly with no joUTF8 in
  options; this test pins that behaviour.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.JSON;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ', Msg);
  Halt(1);
end;

function HexBytes(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    if Result <> '' then Result := Result + ' ';
    Result := Result + IntToHex(Ord(S[i]), 2);
  end;
end;

procedure AssertBytesEqual(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got [' + HexBytes(Got) + '] len=' + IntToStr(Length(Got)) +
                ', want [' + HexBytes(Want) + '] len=' + IntToStr(Length(Want)) + ')');
end;

procedure TestPilcrowRoundTrip;
{ The exact byte sequence the toolview hashline-patch test surfaces. }
var
  J: TJsonObject;
  Got: string;
const
  Want = #$C2#$B6 + 'src/foo.pas';
begin
  J := TJsonObject.Parse('{"path":"' + #$C2#$B6 + 'src/foo.pas"}');
  try
    Got := J.GetStr('path', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'U+00B6 (UTF-8 C2 B6) round-trips through Parse + GetStr');
end;

procedure TestEacuteRoundTrip;
var
  J: TJsonObject;
  Got: string;
const
  Want = 'caf' + #$C3#$A9;
begin
  J := TJsonObject.Parse('{"name":"caf' + #$C3#$A9 + '"}');
  try
    Got := J.GetStr('name', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'U+00E9 (UTF-8 C3 A9) round-trips -- covers `é` in HTTP / file paths');
end;

procedure TestThreeByteRoundTrip;
{ U+4E2D (中) and U+2022 (•) both serialise to 3-byte UTF-8.
  The lossy GetJSON path collapsed these to a single trailing byte
  the same way it broke `¶`. }
var
  J: TJsonObject;
  Got: string;
const
  Want = #$E4#$B8#$AD + ' ' + #$E2#$80#$A2;
begin
  J := TJsonObject.Parse('{"v":"' + #$E4#$B8#$AD + ' ' + #$E2#$80#$A2 + '"}');
  try
    Got := J.GetStr('v', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    '3-byte UTF-8 sequences round-trip (U+4E2D, U+2022)');
end;

procedure TestPlainASCIIUnchanged;
{ Defensive: the fix must not perturb the ASCII-only common case
  the rest of the codebase relies on. }
var
  J: TJsonObject;
  Got: string;
begin
  J := TJsonObject.Parse('{"k":"hello world"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, 'hello world', 'plain ASCII round-trip');
end;

procedure TestJsonEscapesPreserved;
{ The scanner's escape-handling path (\" \\ \n) must still work
  under the byte-preserving parser. }
var
  J: TJsonObject;
  Got: string;
begin
  J := TJsonObject.Parse('{"s":"a\"b\\c\nd"}');
  try
    Got := J.GetStr('s', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, 'a"b\c' + #10 + 'd', 'JSON escapes parsed correctly');
end;

procedure TestUnicodeEscapeBMP;
(* Codex P2 on PR #161. Producers that emit ASCII-safe JSON spell
   non-ASCII as \uXXXX escapes. The scanner's escape-handling branch
   (jsonscanner.pp:270) goes through `String(WideChar(...))` when
   joUTF8 is cleared AND DefaultSystemCodePage <> CP_UTF8 -- which is
   exactly our locale. Result: `é` decodes to byte `E9`
   (Latin-1) instead of UTF-8 `C3 A9`, and `中` outright drops
   to `?` because it's unmappable in CP_1252.

   The fix is to swap DefaultSystemCodePage = CP_UTF8 across the
   parse so the Utf8Encode branch is taken. *)
var
  J: TJsonObject;
  Got: string;
const
  Want = 'caf' + #$C3#$A9;
begin
  J := TJsonObject.Parse('{"k":"café"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'BMP \uXXXX escape (é = é) decodes to UTF-8');
end;

procedure TestUnicodeEscapeBMP3Byte;
{ 中 is U+4E2D (中) -- outside Latin-1 so the lossy path falls
  back to ASCII '?'. Catches the 3-byte UTF-8 escape regression. }
var
  J: TJsonObject;
  Got: string;
const
  Want = #$E4#$B8#$AD;
begin
  J := TJsonObject.Parse('{"k":"中"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    '3-byte \uXXXX escape (中 = 中) decodes to UTF-8');
end;

procedure TestUnicodeEscapeInKey;
(* Codex P2 specifically called out object KEYS that arrive escaped.
   The wrapper's Has / GetStr lookups compare against the caller's
   UTF-8 form, so the stored key MUST be UTF-8 bytes too -- anything
   else makes valid JSON unfindable downstream. *)
var
  J: TJsonObject;
  Got: string;
const
  UTF8Key = 'caf' + #$C3#$A9;
begin
  J := TJsonObject.Parse('{"café":"v"}');
  try
    if not J.Has(UTF8Key) then
      Fail('Has() should find the escaped key under its UTF-8 spelling');
    Got := J.GetStr(UTF8Key, '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, 'v',
    'GetStr finds escaped key via UTF-8 lookup');
end;

procedure TestSurrogatePairEscape;
(* \uXXXX surrogate pairs cover U+10000 and above (emoji, supp planes).
   The scanner's two-codepoint accumulator path (jsonscanner.pp:359)
   shares the same lossy String() cast on non-UTF-8 locales; pin its
   correct behaviour too. 😀 = U+1F600 (😀, UTF-8 F0 9F 98 80). *)
var
  J: TJsonObject;
  Got: string;
const
  Want = #$F0#$9F#$98#$80;
begin
  J := TJsonObject.Parse('{"k":"' + #$F0#$9F#$98#$80 + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'surrogate pair 😀 decodes to 4-byte UTF-8 (😀)');
end;

procedure TestAdjacentEscapePairCJK;
(* Pass-16 improve-loop find. fpjson's scanner (FPC 3.2.2
   jsonscanner.pp) accumulates \uXXXX escapes in a String[4] --
   sized for one surrogate pair (exactly 4 UTF-8 bytes) but shared
   by the combining path for ANY two adjacent escapes, so two
   adjacent 3-byte BMP escapes (6 bytes) silently truncate to 4.
   Python's json.dump default (ensure_ascii=True) emits exactly
   this shape for all non-ASCII text, so any adjacent pair of CJK
   chars or an emoji + variation selector corrupted every relay
   write_file payload. PreDecodeUnicodeEscapes decodes the escapes
   to raw UTF-8 before fpjson sees them. NOTE: Pascal string
   literals do not process backslashes, so the concatenated
   backslash-u sequences below really are escape text -- unlike the raw-byte
   literals in the tests above, these exercise the escape path. *)
var
  J: TJsonObject;
  Got: string;
const
  Want = #$E4#$B8#$AD + #$E6#$96#$87;   { U+4E2D U+6587 }
begin
  J := TJsonObject.Parse('{"k":"' + '\' + 'u4e2d' + '\' + 'u6587' + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'adjacent BMP \uXXXX escapes decode without String[4] truncation');
end;

procedure TestAdjacentEscapeTrioVariationSelector;
{ The shape that surfaced the bug: warning sign U+26A0 + variation
  selector U+FE0F + check mark U+2705, all escaped and adjacent.
  Before the fix the middle escape lost its trailing two bytes. }
var
  J: TJsonObject;
  Got: string;
const
  Want = #$E2#$9A#$A0 + #$EF#$B8#$8F + #$E2#$9C#$85;
begin
  J := TJsonObject.Parse('{"k":"' + '\' + 'u26a0' + '\' + 'ufe0f' + '\' + 'u2705' + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'escaped emoji + variation selector round-trips byte-exact');
end;

procedure TestSurrogatePairAsEscapes;
{ Real surrogate pair spelled as escapes -- must combine to one
  4-byte astral codepoint, not decode as two lone WideChars. }
var
  J: TJsonObject;
  Got: string;
const
  Want = #$F0#$9F#$98#$80;   { U+1F600 }
begin
  J := TJsonObject.Parse('{"k":"' + '\' + 'ud83d' + '\' + 'ude00' + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, Want,
    'escaped surrogate pair combines to 4-byte UTF-8');
end;

procedure TestEscapedBackslashNotDecoded;
{ '\\u1234' is a literal backslash followed by the text u1234 --
  the pre-decoder must not treat the second backslash-u as an
  escape. Guards the escape-state walk. }
var
  J: TJsonObject;
  Got: string;
begin
  J := TJsonObject.Parse('{"k":"' + '\\' + 'u1234' + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, '\' + 'u1234',
    'escaped backslash before u is not decoded as a unicode escape');
end;

procedure TestLowCodepointEscapeUntouched;
{ " is a double quote. Pre-decoding it to a raw quote would
  terminate the JSON string early -- it must stay escaped for
  fpjson, which decodes it correctly on its lone-escape path. }
var
  J: TJsonObject;
  Got: string;
begin
  J := TJsonObject.Parse('{"k":"a' + '\' + 'u0022' + '"}');
  try
    Got := J.GetStr('k', '');
  finally
    J.Free;
  end;
  AssertBytesEqual(Got, 'a"b',
    'sub-$80 \uXXXX escapes are left for fpjson and still decode');
end;

procedure TestArrayElementRoundTrip;
{ Symmetric coverage for TJsonArray.Parse + ItemStr -- same code
  path on the lossy fpjson branch. }
var
  A: TJsonArray;
  Got: string;
const
  Want = #$C2#$B6 + 'item';
begin
  A := TJsonArray.Parse('["' + #$C2#$B6 + 'item"]');
  try
    Got := A.ItemStr(0, '');
  finally
    A.Free;
  end;
  AssertBytesEqual(Got, Want,
    'TJsonArray.Parse + ItemStr preserves UTF-8 bytes');
end;

begin
  TestPlainASCIIUnchanged;
  TestPilcrowRoundTrip;
  TestEacuteRoundTrip;
  TestThreeByteRoundTrip;
  TestJsonEscapesPreserved;
  TestUnicodeEscapeBMP;
  TestUnicodeEscapeBMP3Byte;
  TestUnicodeEscapeInKey;
  TestSurrogatePairEscape;
  TestArrayElementRoundTrip;
  WriteLn('json_utf8_roundtrip_tests: OK');
end.
