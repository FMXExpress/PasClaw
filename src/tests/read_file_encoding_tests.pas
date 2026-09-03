program read_file_encoding_tests;
(*
  ReadFileText must never raise on a non-UTF-8 file. Old bug: a file with bytes
  that decode to characters with no mapping in the Windows ANSI codepage raised
  EEncodingError ("No mapping for the Unicode character exists in the target
  multi-byte code page") -- read_file(C:\www\v1\getdesc.php) crashed on a legacy
  Windows-1252 PHP source. The fix passes valid UTF-8 through untouched and
  reinterprets a non-UTF-8 file as Latin-1, always yielding valid UTF-8 text.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

{ True when S (a pasclaw UTF-8-tagged string) holds well-formed UTF-8 bytes. }
function StrIsValidUTF8(const S: string): Boolean;
var B: TBytes; i: Integer;
begin
  SetLength(B, Length(S));
  for i := 1 to Length(S) do B[i - 1] := Byte(S[i]);
  Result := BytesAreValidUTF8(B);
end;

procedure WriteRaw(const Path: string; const B: array of Byte);
var Strm: TFileStream;
begin
  Strm := TFileStream.Create(Path, fmCreate);
  try
    if Length(B) > 0 then Strm.WriteBuffer(B[0], Length(B));
  finally
    Strm.Free;
  end;
end;

var
  Dir, Path, Body: string;
begin
  Dir := GetTempDir(False);
  if Dir = '' then Dir := '.';

  { --- legacy multibyte bytes must still read as text, never raise ---
    CP932 for the Japanese "日本" is 93 FA 96 7B: not valid UTF-8. On
    Windows the ANSI step decodes it correctly; here it lands on Latin-1.
    Either way ReadFileText must return well-formed UTF-8 and not throw. --- }
  Path := Dir + PathDelim + 'pasclaw-cp932-legacy.txt';
  WriteRaw(Path, [$93, $FA, $96, $7B]);
  Body := '';
  try
    Body := ReadFileText(Path);
  except
    on E: Exception do
      Check(False, 'legacy multibyte file raised ' + E.ClassName);
  end;
  Check(Body <> '', 'legacy multibyte file reads as some text');
  Check(StrIsValidUTF8(Body), 'legacy multibyte file yields valid UTF-8');
  DeleteFile(Path);

  { --- validator sanity --- }
  Check(BytesAreValidUTF8(TBytes.Create($E2, $98, $83)), 'validator: accepts UTF-8 snowman');
  Check(not BytesAreValidUTF8(TBytes.Create($93, $94)), 'validator: rejects cp1252 quotes');
  Check(not BytesAreValidUTF8(TBytes.Create($C0, $80)), 'validator: rejects 2-byte overlong');
  Check(BytesAreValidUTF8(TBytes.Create(Ord('a'), Ord('z'))), 'validator: accepts ASCII');

  { --- RFC 3629 boundary cases: reject overlongs, surrogates, out-of-range --- }
  Check(not BytesAreValidUTF8(TBytes.Create($E0, $80, $80)), 'validator: rejects 3-byte overlong (E0 80 80)');
  Check(not BytesAreValidUTF8(TBytes.Create($ED, $A0, $80)), 'validator: rejects UTF-16 surrogate (ED A0 80)');
  Check(not BytesAreValidUTF8(TBytes.Create($F0, $80, $80, $80)), 'validator: rejects 4-byte overlong (F0 80 80 80)');
  Check(not BytesAreValidUTF8(TBytes.Create($F4, $90, $80, $80)), 'validator: rejects > U+10FFFF (F4 90 80 80)');
  Check(not BytesAreValidUTF8(TBytes.Create($F5, $80, $80, $80)), 'validator: rejects lead > F4 (F5 ..)');
  { valid boundary values must still be accepted (no over-rejection) }
  Check(BytesAreValidUTF8(TBytes.Create($E0, $A0, $80)), 'validator: accepts U+0800 (E0 A0 80)');
  Check(BytesAreValidUTF8(TBytes.Create($ED, $9F, $BF)), 'validator: accepts U+D7FF (ED 9F BF)');
  Check(BytesAreValidUTF8(TBytes.Create($F0, $90, $80, $80)), 'validator: accepts U+10000 (F0 90 80 80)');
  Check(BytesAreValidUTF8(TBytes.Create($F4, $8F, $BF, $BF)), 'validator: accepts U+10FFFF (F4 8F BF BF)');

  { --- non-UTF-8 (Windows-1252) file: the crashing case --- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'pasclaw_enc_1252.php';
  { <?php $x = "caf" + 0xE9(é) + " " + 0x93/0x94 curly quotes + 0xA0 nbsp ?> }
  WriteRaw(Path, [Ord('<'), Ord('?'), Ord('p'), Ord('h'), Ord('p'), Ord(' '),
                  $22, Ord('c'), Ord('a'), Ord('f'), $E9, $22, $20,
                  $93, Ord('h'), Ord('i'), $94, $A0, Ord('!')]);
  Body := '';
  try
    Body := ReadFileText(Path);
  except
    on E: Exception do Check(False, 'read cp1252 raised ' + E.ClassName + ': ' + E.Message);
  end;
  Check(Body <> '', 'cp1252: got content');
  Check(StrIsValidUTF8(Body), 'cp1252: output is valid UTF-8');
  Check(Pos('<?php', Body) > 0, 'cp1252: ASCII preserved');
  DeleteFile(Path);

  { --- valid UTF-8 file: passes through byte-for-byte --- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'pasclaw_enc_utf8.txt';
  WriteRaw(Path, [Ord('a'), $E2, $98, $83, Ord('z')]);   { a + snowman + z }
  Body := ReadFileText(Path);
  Check(StrIsValidUTF8(Body), 'utf8: stays valid UTF-8');
  Check(Length(Body) = 5, 'utf8: byte-preserving (got ' + IntToStr(Length(Body)) + ')');
  DeleteFile(Path);

  { --- UTF-8 BOM is stripped --- }
  Path := IncludeTrailingPathDelimiter(Dir) + 'pasclaw_enc_bom.txt';
  WriteRaw(Path, [$EF, $BB, $BF, Ord('h'), Ord('i')]);
  Body := ReadFileText(Path);
  Check(Body = 'hi', 'bom: stripped (got "' + Body + '")');
  DeleteFile(Path);

  if Failures = 0 then WriteLn('read_file_encoding_tests: OK')
  else begin WriteLn('read_file_encoding_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
