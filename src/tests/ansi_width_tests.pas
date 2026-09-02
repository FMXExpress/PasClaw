program ansi_width_tests;
(*
  Covers the ANSI-aware visible-width helpers in PasClaw.Utils:

    VisibleLength    -- count display columns, skip ANSI escapes,
                        treat UTF-8 multi-byte runs as one column.
    PadVisibleRight  -- right-pad to W visible columns.
    TruncateVisible  -- carve a visible-width-bounded prefix while
                        keeping ANSI sequences intact (and emitting
                        a closing reset if any escape opened in
                        the prefix).

  The TUI chat pane uses these so RenderMarkdown's ANSI output
  doesn't break wrap math (Codex P2 on PR #182). A regression
  here would silently under-pad styled chat rows or split lines
  in the middle of a CSI sequence.

  Also covers the Unicode half added for the CJK bug report (Chinese
  disappearing from the TUI input line):

    CodePointCellWidth  -- 2 cells for CJK / Hangul / fullwidth /
                           emoji, 0 for combining marks and ZW chars.
    VisibleLength etc.  -- now sum cells per code point, so 你好 is
                           4 columns, and TruncateVisible never leaves
                           half a wide character on a row.
    TruncateVisibleTail -- keep the cursor end of an input line.
    Utf8SeqLen / Utf8DecodeCodePoint -- the byte-stream decoder the
                           Delphi TUI uses on POSIX, where GetKey
                           hands over one byte at a time.

  Under FPC `string` is UTF-8 bytes, so the literals below are byte
  escapes rather than relying on the source codepage. The Delphi
  (UTF-16) arm of NextCodePoint is not exercised here -- no Delphi
  toolchain in CI -- and is stated as such.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils;

const
  ESC = #27;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure TestVisibleLengthSkipsAnsi;
begin
  AssertEqInt(VisibleLength('hello'), 5, 'plain text');
  AssertEqInt(VisibleLength(ESC + '[1mhello' + ESC + '[0m'), 5,
              'bold-wrapped 5 chars still counts 5 visible columns');
  AssertEqInt(VisibleLength(ESC + '[31m' + ESC + '[1m' + 'hi' + ESC + '[0m'),
              2, 'chained CSI sequences contribute zero visible width');
  AssertEqInt(VisibleLength(''), 0, 'empty string');
end;

procedure TestPadVisibleRightCountsAnsiAsZero;
{ Padding a styled line should reach the requested visible width
  -- not stop short because the ANSI escape bytes inflated
  Length(). The TUI chat-pane right-edge regression that motivated
  the helpers shows up here. }
var
  Styled, Padded: string;
begin
  Styled := ESC + '[36mhi' + ESC + '[0m';   { 2 visible columns }
  Padded := PadVisibleRight(Styled, 10);
  AssertEqInt(VisibleLength(Padded), 10,
              'padded styled line reaches the visible target');
  { Already-wide input passes through unchanged. }
  AssertEqStr(PadVisibleRight('exactly10!', 10), 'exactly10!',
              'already-wide input returns unchanged');
end;

procedure TestTruncateVisibleKeepsAnsiIntact;
{ Carving a styled string mid-content must not split a CSI
  sequence -- the prefix must end with either a complete sequence
  or no open sequence at all, and the helper appends a final
  reset whenever any escape opened. }
var
  Styled, Prefix, Remainder: string;
begin
  { 'abcdef' with bold around 'cd'. Carve to 4 visible columns:
    prefix should be 'ab' + boldstart + 'cd' + reset + (closer);
    remainder should be the (boldreset) + 'ef'. }
  Styled := 'ab' + ESC + '[1m' + 'cd' + ESC + '[0m' + 'ef';
  Prefix := TruncateVisible(Styled, 4, Remainder);
  AssertEqInt(VisibleLength(Prefix), 4,
              'prefix has 4 visible columns');
  AssertEqStr(Remainder, 'ef', 'remainder is the trailing bytes');

  { Plain text path: no escapes opened, no reset appended. }
  Prefix := TruncateVisible('abcdef', 3, Remainder);
  AssertEqStr(Prefix, 'abc', 'plain prefix');
  AssertEqStr(Remainder, 'def', 'plain remainder');

  { Exact-fit edge: no remainder. }
  Prefix := TruncateVisible('abc', 3, Remainder);
  AssertEqStr(Prefix, 'abc', 'exact-fit prefix');
  AssertEqStr(Remainder, '', 'exact-fit empty remainder');
end;

procedure TestTruncateVisibleIterates;
{ The chat-pane wrap loop feeds Remainder back into TruncateVisible
  until it's empty. Two iterations over a 6-visible-col styled
  string with MaxVis=3 should give two prefixes that together
  cover the original visible columns. }
var
  Styled, Rest, Next, Part: string;
  Total: Integer;
begin
  Styled := ESC + '[31m' + 'abcdef' + ESC + '[0m';   { 6 visible cols }
  Rest := Styled;
  Total := 0;
  while Rest <> '' do
  begin
    { Don't alias Rest as both the input string and the out
      Remainder -- TruncateVisible zeroes the out param before
      reading, which would wipe S out from under itself. }
    Part := TruncateVisible(Rest, 3, Next);
    Inc(Total, VisibleLength(Part));
    Rest := Next;
  end;
  AssertEqInt(Total, 6,
              'iterated truncation covers all 6 visible columns');
end;

const
  { UTF-8 byte forms, so the test does not depend on the source codepage. }
  NI    = #$E4#$BD#$A0;           { 你  U+4F60 }
  HAO   = #$E5#$A5#$BD;           { 好  U+597D }
  SHI   = #$E4#$B8#$96;           { 世  U+4E16 }
  JIE   = #$E7#$95#$8C;           { 界  U+754C }
  GRIN  = #$F0#$9F#$98#$80;       { 😀 U+1F600, 4 bytes, 2 cells }
  ACUTE = #$CC#$81;               { U+0301 combining acute, 0 cells }
  ZWSP  = #$E2#$80#$8B;           { U+200B zero-width space }
  EACUTE_NFC = #$C3#$A9;          { é U+00E9 precomposed, 1 cell }

procedure TestCodePointCellWidth;
begin
  AssertEqInt(CodePointCellWidth(Ord('a')),  1, 'ascii is 1 cell');
  AssertEqInt(CodePointCellWidth($4F60),     2, 'CJK ideograph is 2 cells');
  AssertEqInt(CodePointCellWidth($AC00),     2, 'Hangul syllable is 2 cells');
  AssertEqInt(CodePointCellWidth($FF21),     2, 'fullwidth A is 2 cells');
  AssertEqInt(CodePointCellWidth($1F600),    2, 'emoji is 2 cells');
  AssertEqInt(CodePointCellWidth($0301),     0, 'combining acute is 0 cells');
  AssertEqInt(CodePointCellWidth($200B),     0, 'zero-width space is 0 cells');
  AssertEqInt(CodePointCellWidth($00E9),     1, 'latin e-acute is 1 cell');
  AssertEqInt(CodePointCellWidth($303F),     1, 'the one narrow hole in the CJK block');
end;

procedure TestVisibleLengthCountsCells;
begin
  AssertEqInt(VisibleLength(NI + HAO), 4,
              'two CJK characters are four columns, not two and not six bytes');
  AssertEqInt(VisibleLength('a' + NI + 'b'), 4, 'mixed ascii and CJK');
  AssertEqInt(VisibleLength(ESC + '[1m' + NI + ESC + '[0m'), 2,
              'ANSI around a wide char still counts only the char');
  AssertEqInt(VisibleLength(GRIN), 2, 'four-byte emoji is two cells');
  AssertEqInt(VisibleLength('e' + ACUTE), 1, 'combining mark adds no width');
  AssertEqInt(VisibleLength(ZWSP), 0, 'zero-width space is zero');
  AssertEqInt(VisibleLength(EACUTE_NFC), 1, 'precomposed accent is one cell');
  { Malformed input costs one column per bad byte, never an exception. }
  AssertEqInt(VisibleLength(#$E4#$B8), 2, 'truncated sequence: one column per byte');
  AssertEqInt(VisibleLength(#$80), 1, 'stray continuation byte: one column');
end;

procedure TestTruncateVisibleNeverSplitsWide;
var
  Prefix, Rem: string;
begin
  { 你好世界 is 8 cells. Room for 5: 你好 fit (4), 世 would make 6. }
  Prefix := TruncateVisible(NI + HAO + SHI + JIE, 5, Rem);
  AssertEqStr(Prefix, NI + HAO, 'wide char that would straddle stays whole');
  AssertEqStr(Rem, SHI + JIE, 'and moves to the remainder intact');
  AssertEqInt(VisibleLength(Prefix), 4, 'prefix width is under the cap, not over');

  Prefix := TruncateVisible('a' + NI, 2, Rem);
  AssertEqStr(Prefix, 'a', 'one cell left: a two-cell char does not squeeze in');
  AssertEqStr(Rem, NI, 'it is the remainder');

  Prefix := TruncateVisible(NI + HAO, 4, Rem);
  AssertEqStr(Prefix, NI + HAO, 'exact fit');
  AssertEqStr(Rem, '', 'nothing left');
end;

procedure TestPadVisibleRightCjk;
var
  Padded: string;
begin
  Padded := PadVisibleRight(NI + HAO, 6);
  AssertEqInt(VisibleLength(Padded), 6, 'pads to six cells');
  AssertEqStr(Copy(Padded, Length(Padded) - 1, 2), '  ',
              'exactly two spaces appended, not four');
end;

procedure TestTruncateVisibleTail;
begin
  AssertEqStr(TruncateVisibleTail('abcdef', 3), 'def', 'keeps the tail');
  AssertEqStr(TruncateVisibleTail('a' + NI + HAO, 4), NI + HAO,
              'drops the leading ascii to fit two wide chars');
  AssertEqStr(TruncateVisibleTail(NI + HAO + SHI, 3), SHI,
              'drops whole wide chars until it fits -- never half of one');
  AssertEqStr(TruncateVisibleTail('abc', 3), 'abc', 'already fits');
  AssertEqStr(TruncateVisibleTail('', 3), '', 'empty stays empty');
end;

procedure TestUtf8SeqLen;
begin
  AssertEqInt(Utf8SeqLen($41), 1, 'ascii lead');
  AssertEqInt(Utf8SeqLen($C3), 2, 'two-byte lead');
  AssertEqInt(Utf8SeqLen($E4), 3, 'three-byte lead');
  AssertEqInt(Utf8SeqLen($F0), 4, 'four-byte lead');
  AssertEqInt(Utf8SeqLen($80), 0, 'continuation byte is not a lead');
  AssertEqInt(Utf8SeqLen($C0), 0, 'overlong lead C0 rejected');
  AssertEqInt(Utf8SeqLen($C1), 0, 'overlong lead C1 rejected');
  AssertEqInt(Utf8SeqLen($F5), 0, 'lead beyond U+10FFFF rejected');
  AssertEqInt(Utf8SeqLen($FF), 0, 'FF is never valid');
end;

procedure TestUtf8DecodeCodePoint;
var
  CP: Integer;
begin
  if not Utf8DecodeCodePoint('A', CP) then Fail('ascii decodes');
  AssertEqInt(CP, $41, 'ascii value');
  if not Utf8DecodeCodePoint(EACUTE_NFC, CP) then Fail('two-byte decodes');
  AssertEqInt(CP, $E9, 'e-acute value');
  if not Utf8DecodeCodePoint(NI, CP) then Fail('three-byte decodes');
  AssertEqInt(CP, $4F60, 'ni value');
  if not Utf8DecodeCodePoint(GRIN, CP) then Fail('four-byte decodes');
  AssertEqInt(CP, $1F600, 'grin value');
  { Rejections -- each is a way the byte stream can arrive damaged. }
  if Utf8DecodeCodePoint(#$E4#$B8, CP) then Fail('short sequence must fail');
  if Utf8DecodeCodePoint(#$E4#$41#$AD, CP) then Fail('bad continuation must fail');
  if Utf8DecodeCodePoint(#$C0#$80, CP) then Fail('overlong NUL must fail');
  if Utf8DecodeCodePoint(#$ED#$A0#$80, CP) then Fail('encoded surrogate must fail');
  if Utf8DecodeCodePoint('', CP) then Fail('empty must fail');
  if Utf8DecodeCodePoint(#$80, CP) then Fail('lone continuation must fail');
end;

begin
  TestVisibleLengthSkipsAnsi;
  TestPadVisibleRightCountsAnsiAsZero;
  TestTruncateVisibleKeepsAnsiIntact;
  TestCodePointCellWidth;
  TestVisibleLengthCountsCells;
  TestTruncateVisibleNeverSplitsWide;
  TestPadVisibleRightCjk;
  TestTruncateVisibleTail;
  TestUtf8SeqLen;
  TestUtf8DecodeCodePoint;
  TestTruncateVisibleIterates;
  WriteLn('ansi_width_tests: OK');
end.
