unit PasClaw.KB.PDF;

(*
  PasClaw.KB.PDF - thin wrapper over the PDF parser, exposing the one
  function the KB ingest pipeline actually needs:

    ExtractPDFText(Path, Text, Err) -> Boolean

  Returns the cleaned, decoded text from Path. Err carries a short
  failure message ('not a PDF', 'parse failed') when Result is False.
  The full parser API (TPDFMetadata, page ranges, /ToUnicode internals)
  lives in PasClaw.KB.PDF.Parser; the KB pipeline only needs the text.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

function ExtractPDFText(const Path: string; out Text: string; out Err: string): Boolean;

implementation

uses
  SysUtils,
  PasClaw.KB.PDF.Parser;

{$IFDEF FPC}
{ Under FPC the parser runs in delphiunicode mode, so its `Text` out
  parameter is a UnicodeString. PasClaw.KB.Index is compiled in
  DELPHI / CODEPAGE UTF8 mode, where `string` is an AnsiString tagged
  UTF-8. Convert at the boundary so the KB store gets UTF-8 bytes. }
function UTF16ToUTF8(const W: UnicodeString): RawByteString;
var
  U: UTF8String;
begin
  U := UTF8Encode(W);
  SetCodePage(RawByteString(U), CP_UTF8, False);
  Result := RawByteString(U);
end;
{$ENDIF}

function ExtractPDFText(const Path: string; out Text: string; out Err: string): Boolean;
var
  Meta: TPDFMetadata;
  {$IFDEF FPC}
  WText: UnicodeString;
  {$ENDIF}
begin
  Text := '';
  Err := '';

  if not FileExists(Path) then
  begin
    Err := 'file not found';
    Exit(False);
  end;

  if not TPDFParser.IsValidPDFHeader(Path) then
  begin
    Err := 'not a PDF (missing %PDF header)';
    Exit(False);
  end;

  try
    {$IFDEF FPC}
    Result := TPDFParser.ExtractTextAndMetadata(Path, WText, Meta);
    if Result then
      Text := string(UTF16ToUTF8(WText));
    {$ELSE}
    Result := TPDFParser.ExtractTextAndMetadata(Path, Text, Meta);
    {$ENDIF}
    if not Result then
    begin
      Err := 'parse failed';
      Exit;
    end;
    if Trim(Text) = '' then
    begin
      Err := 'no extractable text (image-only PDF?)';
      Result := False;
      Exit;
    end;
  except
    on E: Exception do
    begin
      Err := 'parse exception: ' + E.Message;
      Result := False;
    end;
  end;
end;

end.
