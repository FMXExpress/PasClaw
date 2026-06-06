program json_utf8_roundtrip_tests;
(*
  Regression: PasClaw.JSON.Parse must preserve raw UTF-8 bytes in
  parsed string values. Under FPC 3.2 fpjson's default GetJSON path
  has a joUTF8 + DefaultSystemCodePage branch in jsonreader.pp that
  silently re-encodes parsed tokens through the system codepage:

      tkString : if (joUTF8 in Options) and (DefaultSystemCodePage<>CP_UTF8) then
                   StringValue(TJSONStringType(UTF8Decode(CurrentTokenString)))

  On a container locale with DefaultSystemCodePage=0 the round-trip
  clips every non-ASCII UTF-8 lead byte — `¶` (`C2 B6`) arrives as
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
    'U+00E9 (UTF-8 C3 A9) round-trips — covers `é` in HTTP / file paths');
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

procedure TestArrayElementRoundTrip;
{ Symmetric coverage for TJsonArray.Parse + ItemStr — same code
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
  TestArrayElementRoundTrip;
  WriteLn('json_utf8_roundtrip_tests: OK');
end.
