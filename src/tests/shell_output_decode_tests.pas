program shell_output_decode_tests;
(*
  Covers PasClaw.Platform.DecodeShellOutputBytes -- the helper that
  decodes captured shell-process bytes (cmd.exe / /bin/sh stdout) into
  a UTF-8 Pascal string. The core bug it fixes: cmd.exe on Windows
  writes its stdout in the system OEM codepage (CP437 / CP866 / CP932 /
  ...) NOT UTF-8, and naive `TEncoding.UTF8.GetString` produces
  mojibake on any non-ASCII byte. That was the root cause of the "is
  this D:\non-ascii-folder there?" failures the bug reporter hit.

  Tests run on every platform (Linux CI is fine -- the helper accepts
  an explicit codepage argument so we can pin Windows OEM behaviour
  without needing Windows itself). On POSIX the codepage table for 437
  is the same one Windows ships, so the conversion math works.

  Contracts pinned:
    - Empty input -> empty output (no decode attempted)
    - ASCII-only bytes round-trip identically regardless of codepage
      (every codepage agrees on the lower 128)
    - ByteCount = -1 means "all of Bytes"
    - ByteCount cap respected
    - On POSIX, codepage=0 routes to UTF-8 (the default and the
      historical behaviour we're preserving)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cwstring,{$ENDIF}    { Bridges TEncoding.GetEncoding to
                                      iconv for non-default codepages.
                                      Production POSIX paths only ever
                                      decode UTF-8, which works without
                                      this; the explicit-codepage tests
                                      below need it to actually resolve
                                      CP437 (otherwise FPC falls back
                                      to Latin-1 sign-extension and
                                      0x82 round-trips as U+0082 instead
                                      of U+00E9). }
  SysUtils,
  PasClaw.Platform;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

function MakeBytes(const S: string): TBytes;
{ Pack ASCII characters into a TBytes the same way a freshly-captured
  child stdout buffer would arrive -- one byte per character. }
var
  i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do
    Result[i - 1] := Byte(S[i]);
end;

procedure TestEmptyInputEmptyOutput;
var
  B: TBytes;
begin
  SetLength(B, 0);
  AssertEqStr(DecodeShellOutputBytes(B), '', 'empty TBytes -> empty');
  AssertEqStr(DecodeShellOutputBytes(B, 0), '', 'ByteCount=0 -> empty');
  AssertEqStr(DecodeShellOutputBytes(B, -1), '', 'ByteCount=-1 on empty -> empty');
end;

procedure TestAsciiRoundTripDefault;
begin
  AssertEqStr(DecodeShellOutputBytes(MakeBytes('hello world')),
              'hello world', 'plain ASCII round-trips on default codepage');
end;

procedure TestAsciiRoundTripExplicit437;
{ The lower 128 of CP437 == ASCII, so explicit codepage=437 must round
  trip ASCII verbatim. Exercises the OEM-decode path on Windows; on
  POSIX exercises the explicit-codepage fallback. }
begin
  AssertEqStr(DecodeShellOutputBytes(MakeBytes('Volume in drive C is OS'),
                                     -1, 437),
              'Volume in drive C is OS',
              'ASCII bytes decoded via CP437 are byte-identical');
end;

procedure TestByteCountCap;
var
  B: TBytes;
begin
  B := MakeBytes('abcdefghij');
  AssertEqStr(DecodeShellOutputBytes(B, 5),
              'abcde', 'ByteCount = 5 takes the first 5 bytes only');
  AssertEqStr(DecodeShellOutputBytes(B, 0),
              '', 'ByteCount = 0 returns empty');
  AssertEqStr(DecodeShellOutputBytes(B, -1),
              'abcdefghij', 'ByteCount = -1 takes all bytes');
  AssertEqStr(DecodeShellOutputBytes(B, 1000),
              'abcdefghij',
              'ByteCount > Length clamps to Length (no buffer overrun)');
end;

procedure TestNewlineAndPunctSurvive;
{ Real `dir` output has CR/LF + spaces + slashes. Pin that none of
  those are mangled by the decode path regardless of codepage. }
var
  Raw: string;
  i: Integer;
begin
  Raw := '12/24/2026  10:15 AM    <DIR>          Documents' + sLineBreak +
         '                       Total bytes:   123,456';
  AssertEqStr(DecodeShellOutputBytes(MakeBytes(Raw), -1, 437),
              Raw, 'dir-shaped ASCII survives CP437 decode intact');
  AssertEqStr(DecodeShellOutputBytes(MakeBytes(Raw)),
              Raw, 'dir-shaped ASCII survives default decode intact');
  { sanity: the input itself has non-zero length so the test isn't
    vacuous }
  AssertTrue(Length(Raw) > 0, 'fixture is non-empty');
  for i := 1 to Length(Raw) do
    AssertTrue(Ord(Raw[i]) < 128,
               'fixture must stay pure ASCII so the test runs ' +
               'identically across CI platforms');
end;

procedure TestLengthExceedsBytes;
var
  B: TBytes;
begin
  B := MakeBytes('abc');
  AssertEqInt(Length(DecodeShellOutputBytes(B, 999)), 3,
              'oversized ByteCount clamps to actual array length');
end;

procedure TestCP437SingleNonAsciiByte;
(* The actual point of the whole patch: prove the codepage table is
   hit correctly, not just that the byte-counting math works. Byte
   0x82 in CP437 is 'é' (U+00E9); UTF-8 encodes 'é' as the two-byte
   sequence 0xC3 0xA9. This is the exact mojibake the bug reporter
   hit -- under naive UTF-8 decoding 0x82 is an invalid lead byte
   and shows up as a replacement character. Through GetOEMCP +
   MultiByteToWideChar (Windows) or TEncoding.GetEncoding(437)
   (Linux via iconv's IBM437) the byte resolves to the right
   character.

   The CODEPAGE UTF8 directive at the top of this file means 'é'
   as a source literal is encoded as bytes 0xC3 0xA9 too, so
   AssertEqStr is meaningful -- otherwise we'd be comparing
   different encodings. Paren-star delimiters because the directive
   token would close a curly-brace comment early on dcc64. *)
var
  B: TBytes;
  Got: string;
begin
  SetLength(B, 1);
  B[0] := $82;
  Got := DecodeShellOutputBytes(B, 1, 437);
  AssertEqInt(Length(Got), 2,
              'é UTF-8-encodes to exactly 2 bytes');
  AssertEqInt(Byte(Got[1]), $C3, 'first UTF-8 byte of é is 0xC3');
  AssertEqInt(Byte(Got[2]), $A9, 'second UTF-8 byte of é is 0xA9');
  AssertEqStr(Got, 'é',
              'CP437 byte 0x82 decodes to é (and round-trips as UTF-8)');
end;

procedure TestCP437MultiByteString;
{ A string with multiple non-ASCII CP437 bytes mixed with ASCII --
  like a real `dir` listing of a directory whose name contains
  accents. Pins that the conversion handles a mixed run, not just
  one byte in isolation. }
var
  B: TBytes;
  Got: string;
begin
  { "résumé" in CP437:
      r=0x72, é=0x82, s=0x73, u=0x75, m=0x6D, é=0x82 }
  SetLength(B, 6);
  B[0] := $72;
  B[1] := $82;
  B[2] := $73;
  B[3] := $75;
  B[4] := $6D;
  B[5] := $82;
  Got := DecodeShellOutputBytes(B, 6, 437);
  AssertEqStr(Got, 'résumé',
              'CP437 multibyte sequence round-trips through the helper');
end;

procedure TestCP437BoxDrawing;
{ `dir`'s table output uses CP437 box-drawing characters by
  default. Byte 0xC4 in CP437 is U+2500 (─, light horizontal),
  which UTF-8 encodes as 3 bytes 0xE2 0x94 0x80. Pins the
  three-byte UTF-8 case in addition to the two-byte one above. }
var
  B: TBytes;
  Got: string;
begin
  SetLength(B, 1);
  B[0] := $C4;
  Got := DecodeShellOutputBytes(B, 1, 437);
  AssertEqInt(Length(Got), 3,
              'U+2500 UTF-8-encodes to exactly 3 bytes');
  AssertEqInt(Byte(Got[1]), $E2, 'first UTF-8 byte of ─ is 0xE2');
  AssertEqInt(Byte(Got[2]), $94, 'second UTF-8 byte of ─ is 0x94');
  AssertEqInt(Byte(Got[3]), $80, 'third UTF-8 byte of ─ is 0x80');
end;

procedure TestUTF8InputThroughExplicitCP65001;
{ Codepage 65001 is the magic "this is UTF-8" CP on Windows. When
  the input is already UTF-8 bytes (which is what cmd.exe writes
  on Windows 10/11 when the operator has the "Use Unicode UTF-8"
  region option enabled), we must round-trip verbatim. Pins both
  the Windows-UTF-8-locale branch and the POSIX default. }
var
  B: TBytes;
  Got: string;
begin
  { 'é' in UTF-8 = 0xC3 0xA9 }
  SetLength(B, 2);
  B[0] := $C3;
  B[1] := $A9;
  Got := DecodeShellOutputBytes(B, 2, 65001);
  AssertEqStr(Got, 'é',
              'UTF-8 input round-trips through codepage 65001');
end;

procedure TestAutoDetectPrefersUTF8ForValidSequences;
(* Codex P2 on PR #239: PowerShell 6+ (pwsh) defaults to UTF-8 stdout,
   so when execute_code or shell_exec captures pwsh output the bytes
   are valid UTF-8 sequences -- decoding via GetOEMCP would mojibake
   them. With Codepage = 0 the helper should detect "this is valid
   UTF-8" and pass through verbatim, NOT route through CP437. POSIX
   side: Codepage=0 already goes through TEncoding.UTF8.GetString
   so the same input is handled the same way on Linux CI. *)
var
  B: TBytes;
  Got: string;
begin
  { "résumé" as UTF-8: r(0x72), é(0xC3 0xA9), s(0x73), u(0x75),
    m(0x6D), é(0xC3 0xA9) -- 8 bytes total. }
  SetLength(B, 8);
  B[0] := $72;
  B[1] := $C3; B[2] := $A9;
  B[3] := $73;
  B[4] := $75;
  B[5] := $6D;
  B[6] := $C3; B[7] := $A9;
  Got := DecodeShellOutputBytes(B);   { Codepage = 0 -> auto-detect }
  AssertEqStr(Got, 'résumé',
              'auto-detect: valid UTF-8 input passes through verbatim ' +
              '(would be mojibake "rA©sumA©" or similar if CP437 was forced)');
end;

begin
  TestEmptyInputEmptyOutput;
  WriteLn('  ok: empty input -> empty output');
  TestAsciiRoundTripDefault;
  WriteLn('  ok: ASCII round-trips on default codepage');
  TestAsciiRoundTripExplicit437;
  WriteLn('  ok: ASCII round-trips on explicit CP437 (OEM path)');
  TestByteCountCap;
  WriteLn('  ok: ByteCount cap respected, -1 = all');
  TestNewlineAndPunctSurvive;
  WriteLn('  ok: dir-shaped output survives intact');
  TestLengthExceedsBytes;
  WriteLn('  ok: oversized ByteCount clamps safely');
  TestCP437SingleNonAsciiByte;
  WriteLn('  ok: CP437 0x82 -> é (the actual codepage table is hit)');
  TestCP437MultiByteString;
  WriteLn('  ok: CP437 multibyte sequence round-trips');
  TestCP437BoxDrawing;
  WriteLn('  ok: CP437 0xC4 -> ─ (3-byte UTF-8)');
  TestUTF8InputThroughExplicitCP65001;
  WriteLn('  ok: codepage 65001 = pass-through UTF-8');
  TestAutoDetectPrefersUTF8ForValidSequences;
  WriteLn('  ok: auto-detect picks UTF-8 for valid UTF-8 input (pwsh case)');
  WriteLn('PASS');
end.
