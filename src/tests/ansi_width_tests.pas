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

begin
  TestVisibleLengthSkipsAnsi;
  TestPadVisibleRightCountsAnsiAsZero;
  TestTruncateVisibleKeepsAnsiIntact;
  TestTruncateVisibleIterates;
  WriteLn('ansi_width_tests: OK');
end.
