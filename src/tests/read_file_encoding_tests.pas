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

  { --- validator sanity --- }
  Check(BytesAreValidUTF8(TBytes.Create($E2, $98, $83)), 'validator: accepts UTF-8 snowman');
  Check(not BytesAreValidUTF8(TBytes.Create($93, $94)), 'validator: rejects cp1252 quotes');
  Check(not BytesAreValidUTF8(TBytes.Create($C0, $80)), 'validator: rejects overlong');
  Check(BytesAreValidUTF8(TBytes.Create(Ord('a'), Ord('z'))), 'validator: accepts ASCII');

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
