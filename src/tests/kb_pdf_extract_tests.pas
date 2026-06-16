program kb_pdf_extract_tests;
{ Pure-function coverage for the PDF text extractor that backs `.pdf`
  KB ingest. Builds a minimal uncompressed PDF in a temp file (one page,
  one Tj operator, a Type1 font, /Title metadata), runs it through
  ExtractPDFText, and asserts the extracted text contains the expected
  phrase and that bogus / non-PDF inputs are rejected with a useful
  Err string.

  Deliberately avoids /FlateDecode (would require synthesising a zlib
  stream by hand) -- ExtractPDFText's Flate path is exercised end-to-
  end by `kb_index_tests` via a real-world PDF dropped into a temp
  source dir, and on every PR via the smoke target. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.KB.PDF;

procedure Fail_(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail_(Msg + ' (got "' + Haystack + '", expected to contain "' + Needle + '")');
end;

{ Write S to Path as raw bytes (no BOM, no codepage rewrite). }
procedure WriteRaw(const Path, S: string);
var
  FS: TFileStream;
begin
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Length(S) > 0 then
      FS.WriteBuffer(S[1], Length(S));
  finally
    FS.Free;
  end;
end;

{ Minimal uncompressed PDF. xref offsets aren't strictly accurate (the
  parser doesn't consult them -- it regex-scans for /Type /Page and
  BT/ET) but the rest of the structure is well-formed.

  Carries: one page, one Type1 font (F1=Helvetica), one Tj operator
  showing "Hello PasClaw KB", and a /Title metadata entry the parser
  picks up for Meta.Title. }
function MakeMinimalPDF: string;
const
  CR = #13#10;
begin
  Result :=
    '%PDF-1.4' + CR +
    '%' + #$C4#$E5#$F2#$E5#$EB#$A7#$F3#$A0#$D0#$C4#$C6 + CR +
    '1 0 obj' + CR +
    '<</Type/Catalog/Pages 2 0 R>>' + CR +
    'endobj' + CR +
    '2 0 obj' + CR +
    '<</Type/Pages/Kids[3 0 R]/Count 1>>' + CR +
    'endobj' + CR +
    '3 0 obj' + CR +
    '<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]' +
      '/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>' + CR +
    'endobj' + CR +
    '4 0 obj' + CR +
    '<</Length 60>>' + CR +
    'stream' + CR +
    'BT' + CR +
    '/F1 24 Tf' + CR +
    '100 100 Td' + CR +
    '(Hello PasClaw KB) Tj' + CR +
    'ET' + CR +
    'endstream' + CR +
    'endobj' + CR +
    '5 0 obj' + CR +
    '<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>' + CR +
    'endobj' + CR +
    '6 0 obj' + CR +
    '<</Title(KB Test Doc)/Author(PasClaw)>>' + CR +
    'endobj' + CR +
    'xref' + CR +
    '0 7' + CR +
    '0000000000 65535 f ' + CR +
    '0000000018 00000 n ' + CR +
    '0000000062 00000 n ' + CR +
    '0000000110 00000 n ' + CR +
    '0000000214 00000 n ' + CR +
    '0000000291 00000 n ' + CR +
    '0000000360 00000 n ' + CR +
    'trailer' + CR +
    '<</Size 7/Root 1 0 R/Info 6 0 R>>' + CR +
    'startxref' + CR +
    '420' + CR +
    '%%EOF' + CR;
end;

procedure TestMissingFile;
var
  Text, Err: string;
  OK: Boolean;
begin
  OK := ExtractPDFText('/tmp/__pasclaw_no_such_file__.pdf', Text, Err);
  AssertFalse(OK, 'missing file -> False');
  AssertTrue(Err <> '', 'missing file -> Err set');
end;

procedure TestNonPDF;
var
  Dir, Path, Text, Err: string;
  OK: Boolean;
begin
  Dir := GetTempDir(False);
  Path := Dir + 'pasclaw_kb_pdf_test_notpdf.pdf';
  WriteRaw(Path, 'Not a PDF, just some plain text masquerading.');
  try
    OK := ExtractPDFText(Path, Text, Err);
    AssertFalse(OK, 'non-PDF (no %PDF header) -> False');
    AssertContains(Err, 'not a PDF', 'err mentions "not a PDF"');
  finally
    DeleteFile(Path);
  end;
end;

procedure TestMinimalPDF;
var
  Dir, Path, Text, Err: string;
  OK: Boolean;
begin
  Dir := GetTempDir(False);
  Path := Dir + 'pasclaw_kb_pdf_test_minimal.pdf';
  WriteRaw(Path, MakeMinimalPDF);
  try
    OK := ExtractPDFText(Path, Text, Err);
    AssertTrue(OK, 'minimal PDF extracts (err=' + Err + ')');
    AssertContains(Text, 'Hello PasClaw KB', 'extracted text contains Tj content');
  finally
    DeleteFile(Path);
  end;
end;

{ Two Tj operands in the same BT block separated by a Td position op.
  Before the spacing fix this concatenated as "FooBar" instead of
  "Foo Bar". Covers Codex P2 finding #3. }
procedure TestPositionedTjSpacing;
var
  Dir, Path, Text, Err: string;
  OK: Boolean;
  PositionedPDF: string;
const
  CR = #13#10;
begin
  PositionedPDF :=
    '%PDF-1.4' + CR +
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj' + CR +
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj' + CR +
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]' +
      '/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj' + CR +
    '4 0 obj<</Length 80>>' + CR +
    'stream' + CR +
    'BT' + CR +
    '/F1 24 Tf' + CR +
    '60 90 Td' + CR +
    '(Foo) Tj' + CR +
    '50 0 Td' + CR +
    '(Bar) Tj' + CR +
    'ET' + CR +
    'endstream' + CR +
    'endobj' + CR +
    '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj' + CR +
    'trailer<</Size 6/Root 1 0 R>>' + CR +
    '%%EOF' + CR;
  Dir := GetTempDir(False);
  Path := Dir + 'pasclaw_kb_pdf_test_positioned.pdf';
  WriteRaw(Path, PositionedPDF);
  try
    OK := ExtractPDFText(Path, Text, Err);
    AssertTrue(OK, 'positioned PDF extracts (err=' + Err + ')');
    AssertContains(Text, 'Foo Bar', 'Td-separated Tj operands get a space inserted');
  finally
    DeleteFile(Path);
  end;
end;

{ Content stream resolved through a nonzero-generation reference must
  still be located. The parser now uses BuildObjectIndex (which records
  every "N G obj" regardless of G) instead of a hardcoded "N 0 obj"
  regex. Covers Codex P2 finding #1. }
procedure TestNonZeroGenerationContent;
var
  Dir, Path, Text, Err: string;
  OK: Boolean;
  Pdf: string;
const
  CR = #13#10;
begin
  Pdf :=
    '%PDF-1.4' + CR +
    '1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj' + CR +
    '2 0 obj<</Type/Pages/Kids[3 0 R]/Count 1>>endobj' + CR +
    { Page's /Contents references gen 0 (the only generation supported by
      the regex in GetPageContentStreamIDs); we mark obj 4 itself as
      generation 1 to prove the lookup no longer hardcodes "0". }
    '3 0 obj<</Type/Page/Parent 2 0 R/MediaBox[0 0 300 144]' +
      '/Contents 4 0 R/Resources<</Font<</F1 5 0 R>>>>>>endobj' + CR +
    '4 1 obj<</Length 60>>' + CR +
    'stream' + CR +
    'BT' + CR +
    '/F1 24 Tf' + CR +
    '60 90 Td' + CR +
    '(GenOne text) Tj' + CR +
    'ET' + CR +
    'endstream' + CR +
    'endobj' + CR +
    '5 0 obj<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>endobj' + CR +
    'trailer<</Size 6/Root 1 0 R>>' + CR +
    '%%EOF' + CR;
  Dir := GetTempDir(False);
  Path := Dir + 'pasclaw_kb_pdf_test_gen1.pdf';
  WriteRaw(Path, Pdf);
  try
    OK := ExtractPDFText(Path, Text, Err);
    AssertTrue(OK, 'gen-1 content stream extracts (err=' + Err + ')');
    AssertContains(Text, 'GenOne text', 'non-zero generation content stream resolved');
  finally
    DeleteFile(Path);
  end;
end;

procedure TestEmptyTextPDF;
{ A PDF whose only objects are font/metadata (no BT/ET text streams)
  reports an explanatory Err rather than a silent empty index. Mirrors
  the image-only-PDF case in the wild. }
var
  Dir, Path, Text, Err: string;
  OK: Boolean;
  EmptyPDF: string;
const
  CR = #13#10;
begin
  EmptyPDF :=
    '%PDF-1.4' + CR +
    '1 0 obj<</Type/Catalog>>endobj' + CR +
    'xref' + CR +
    '0 2' + CR +
    '0000000000 65535 f ' + CR +
    '0000000009 00000 n ' + CR +
    'trailer<</Size 2/Root 1 0 R>>' + CR +
    'startxref' + CR +
    '50' + CR +
    '%%EOF' + CR;
  Dir := GetTempDir(False);
  Path := Dir + 'pasclaw_kb_pdf_test_empty.pdf';
  WriteRaw(Path, EmptyPDF);
  try
    OK := ExtractPDFText(Path, Text, Err);
    AssertFalse(OK, 'text-empty PDF -> False');
    AssertContains(Err, 'no extractable text', 'err mentions "no extractable text"');
  finally
    DeleteFile(Path);
  end;
end;

begin
  TestMissingFile;
  TestNonPDF;
  TestMinimalPDF;
  TestPositionedTjSpacing;
  TestNonZeroGenerationContent;
  TestEmptyTextPDF;
  Writeln('ok - kb pdf extract tests passed');
end.
