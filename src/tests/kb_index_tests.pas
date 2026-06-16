program kb_index_tests;
{ Pure-function coverage for the knowledgebase unit: the chunker, the
  extension filter, the binary sniff, and the HTML stripper. The
  SQLite-backed paths are exercised end to end by `pasclaw kb` against
  a temp PASCLAW_HOME in the smoke suite — these tests stay
  dependency-free so they run on any build host. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils,
  PasClaw.KB.Index;

procedure Fail(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure TestChunkEmpty;
begin
  AssertTrue(Length(KBChunkDocument('')) = 0, 'empty input -> no chunks');
  AssertTrue(Length(KBChunkDocument(#10#10'   '#10)) = 0,
             'whitespace-only input -> no chunks');
end;

procedure TestChunkSmallDocIsOneChunk;
var
  C: TArray<string>;
begin
  C := KBChunkDocument('Para one.'#10#10'Para two.');
  AssertTrue(Length(C) = 1, Format('small doc packs to 1 chunk (got %d)', [Length(C)]));
  AssertTrue(Pos('Para one.', C[0]) > 0, 'chunk keeps first paragraph');
  AssertTrue(Pos('Para two.', C[0]) > 0, 'chunk keeps second paragraph');
end;

procedure TestChunkSplitsAtTarget;
var
  A, B: string;
  C: TArray<string>;
begin
  A := StringOfChar('a', KB_CHUNK_TARGET - 100);
  B := StringOfChar('b', KB_CHUNK_TARGET - 100);
  C := KBChunkDocument(A + #10#10 + B);
  AssertTrue(Length(C) = 2, Format('two near-target paragraphs -> 2 chunks (got %d)', [Length(C)]));
end;

procedure TestChunkHardCap;
var
  C: TArray<string>;
  i: Integer;
begin
  { One giant single-line paragraph must be split into <= KB_CHUNK_MAX
    slices rather than emitted whole. }
  C := KBChunkDocument(StringOfChar('x', 3 * KB_CHUNK_MAX + 17));
  AssertTrue(Length(C) >= 3, Format('giant paragraph split (got %d chunks)', [Length(C)]));
  for i := 0 to High(C) do
    AssertTrue(Length(C[i]) <= KB_CHUNK_MAX,
               Format('chunk %d within hard cap (%d bytes)', [i, Length(C[i])]));
end;

procedure TestChunkUtf8NotSplit;
{$IFDEF FPC}
const
  { é as explicit UTF-8 bytes — a textual 'é' literal would be
    re-encoded through the system codepage and degrade to '?' under a
    C/POSIX locale, silently deflating the run below the cap. Same
    codepage-tag rationale as toolview_tests' EllipsisGlyph. }
  E2 = #$C3#$A9;
var
  S: string;
  C: TArray<string>;
  i, j: Integer;
begin
  { A giant run of 2-byte UTF-8 chars: no chunk may end on a lead byte
    or start on a continuation byte. Byte-level slicing only exists on
    FPC (strings are bytes); Delphi's UTF-16 Copy can't split a BMP
    char, so the property holds there by construction. }
  S := '';
  for i := 1 to (KB_CHUNK_MAX div 2) + 50 do S := S + E2;
  C := KBChunkDocument(S);
  AssertTrue(Length(C) >= 2, 'utf8 run splits into multiple chunks');
  for i := 0 to High(C) do
  begin
    j := Length(C[i]);
    AssertTrue((Byte(C[i][1]) and $C0) <> $80, 'chunk does not start mid-sequence');
    AssertTrue((Byte(C[i][j]) and $C0) = $80,
               'two-byte char chunk ends on its continuation byte');
  end;
end;
{$ELSE}
begin
  { See FPC branch — not meaningful on UTF-16 strings. }
end;
{$ENDIF}

procedure TestChunkCrlf;
var
  C: TArray<string>;
begin
  C := KBChunkDocument('one'#13#10#13#10'two');
  AssertTrue(Length(C) = 1, 'CRLF blank line still separates paragraphs and packs');
  AssertTrue(Pos('one', C[0]) > 0, 'CRLF doc keeps content');
end;

procedure TestExtSupported;
begin
  AssertTrue(KBExtSupported('/x/doc.md'),    '.md supported');
  AssertTrue(KBExtSupported('/x/Unit1.PAS'), '.pas supported (case-insensitive)');
  AssertTrue(KBExtSupported('/x/page.htm'),  '.htm aliases .html');
  AssertTrue(KBExtSupported('/x/book.pdf'),  '.pdf now supported (native parser)');
  AssertTrue(not KBExtSupported('/x/image.png'), '.png not supported');
  AssertTrue(not KBExtSupported('/x/noext'),     'no extension not supported');
end;

procedure TestLooksBinary;
begin
  AssertTrue(KBLooksBinary('abc'#0'def'), 'NUL byte -> binary');
  AssertTrue(not KBLooksBinary('plain text, ümlauts, 中文'), 'text -> not binary');
end;

procedure TestStripHtml;
var
  S: string;
begin
  S := KBStripHtml('<html><head><style>.x{color:red}</style>' +
                   '<script>alert(1)</script></head>' +
                   '<body><h1>Title</h1><p>Hello &amp; welcome</p></body></html>');
  AssertTrue(Pos('Title', S) > 0,          'keeps heading text');
  AssertTrue(Pos('Hello & welcome', S) > 0, 'decodes &amp;');
  AssertTrue(Pos('alert', S) = 0,          'drops script body');
  AssertTrue(Pos('color:red', S) = 0,      'drops style body');
  AssertTrue(Pos('<', S) = 0,              'strips all tags');
end;

begin
  TestChunkEmpty;
  TestChunkSmallDocIsOneChunk;
  TestChunkSplitsAtTarget;
  TestChunkHardCap;
  TestChunkUtf8NotSplit;
  TestChunkCrlf;
  TestExtSupported;
  TestLooksBinary;
  TestStripHtml;
  Writeln('PASS');
end.
