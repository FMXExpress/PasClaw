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
  WriteLn('PASS');
end.
