program utf8_codepage_tag_tests;
(*
  Proves the FPC UTF-8 codepage-tag fix that lives in
  PasClaw.Utils.TagUTF8.

  Under FPC mode delphi, `string` is AnsiString with a codepage tag.
  Strings produced by TStringStream(... TEncoding.UTF8).DataString
  carry CP_0 (system default) but their bytes are valid UTF-8. The
  bug: any downstream TEncoding.UTF8.GetBytes() on that CP_0 string
  reinterprets the bytes as the system codepage (CP1252 on Windows)
  and re-encodes to UTF-8 -- classic double-encoding mojibake
  (`é` 2 bytes -> `Ã©` 4 bytes).

  TagUTF8 retags in place without rewriting bytes, so the round-trip
  through TEncoding.UTF8 is now lossless.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Utils;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqual(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertBytesEqual(const Got, Want: TBytes; const Msg: string);
var
  i: Integer;
begin
  if Length(Got) <> Length(Want) then
    Fail(Msg + Format(' (len got=%d want=%d)', [Length(Got), Length(Want)]));
  for i := 0 to High(Got) do
    if Got[i] <> Want[i] then
      Fail(Msg + Format(' (byte[%d] got=%.2x want=%.2x)', [i, Got[i], Want[i]]));
end;

procedure TestTagOnDataString;
{ The exact path PasClaw.Providers.HTTP.DoRequest used to take --
  TStringStream(UTF8) -> DataString -> assign to result body. The
  bytes ARE correct UTF-8 here (we wrote them), but on FPC the
  resulting string is CP_0 until TagUTF8 runs. }
var
  S: TStringStream;
  Body: string;
  Cafe: TBytes;
begin
  Cafe := TBytes.Create($63, $61, $66, $C3, $A9);  { c a f UTF-8(é) }
  S := TStringStream.Create('', TEncoding.UTF8);
  try
    S.WriteBuffer(Cafe[0], Length(Cafe));
    Body := S.DataString;
  finally
    S.Free;
  end;

  {$IFDEF FPC}
  { On FPC the smoking-gun symptom: codepage tag is 0, not 65001. }
  AssertEqual(StringCodePage(Body), 0,
              'pre-tag: AnsiString from DataString carries CP_0');
  TagUTF8(Body);
  AssertEqual(StringCodePage(Body), CP_UTF8,
              'post-tag: TagUTF8 retags AnsiString to CP_UTF8');
  {$ENDIF}

  { Bytes are unchanged either way -- the fix is metadata-only. }
  AssertEqual(Length(Body), Length(Cafe), 'byte length preserved');
  AssertBytesEqual(BytesOf(Body), Cafe,    'byte content preserved');
end;

procedure TestRoundTripThroughEncoding;
{ The actual bug: PasClaw.Gateway.Server.WriteBodyStream calls
  TEncoding.UTF8.GetBytes(Body) to put the bytes on the wire. With
  Body tagged CP_0 under FPC, GetBytes interprets the UTF-8 bytes as
  CP_1252 and re-encodes -- that's the double-encode that produces
  Ã© on the wire. With TagUTF8 applied first, GetBytes sees the
  correct tag and returns the bytes unchanged. }
var
  Body: string;
  Cafe, Wire: TBytes;
begin
  Cafe := TBytes.Create($63, $61, $66, $C3, $A9);
  SetLength(Body, Length(Cafe));
  Move(Cafe[0], Body[1], Length(Cafe));

  TagUTF8(Body);
  Wire := TEncoding.UTF8.GetBytes(Body);
  AssertBytesEqual(Wire, Cafe,
                   'TEncoding.UTF8.GetBytes(tagged) is lossless -- no double-encoding');
end;

procedure TestEmptyStringNoOp;
var
  Empty: string;
begin
  Empty := '';
  TagUTF8(Empty);
  AssertEqual(Length(Empty), 0, 'empty string stays empty');
end;

begin
  TestTagOnDataString;
  TestRoundTripThroughEncoding;
  TestEmptyStringNoOp;
  WriteLn('utf8_codepage_tag_tests: OK');
end.
