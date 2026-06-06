(*
  PasClaw.Markdown.Render - convert LLM-emitted markdown to ANSI-
  styled text for terminal display.

  Mirrors what nanobot (HKUDS/nanobot) gets from Python's
  `rich.markdown.Markdown` for free; picoclaw doesn't render
  markdown at all and prints raw stars + hashes. We split the
  difference: terminal surfaces (agent, tui) render, machine
  surfaces (serve, gateway) emit the original text unchanged.

  Subset supported (covers ~95% of what models produce):

    # / ## / ### / #### heading            bold + colour
    **bold**                               ANSI bold
    *italic* / _italic_                    ANSI italic
    ~~strikethrough~~                      ANSI strikethrough
    `inline code`                          dim + reverse
    ```fenced code block```                dim, multi-line, no
                                           inline transforms inside
    - / * bullet list                      bullet + indent
    1. / 2. / ... numbered list            preserved
    > blockquote                           italic + bar prefix
    [text](url)                            underline text + bare url

  Falls back to passthrough on anything unrecognised. Empty input
  returns empty output. Plain text (no markers) is byte-identical
  to input — important for streaming paths where we may render
  partial chunks.
*)
unit PasClaw.Markdown.Render;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function RenderMarkdown(const S: string): string;

implementation

uses
  SysUtils, StrUtils, Classes,
  PasClaw.CliUI;

const
  { Box-drawing / bullet glyphs encoded the way the active compiler's
    `string` type wants them — different on FPC and Delphi, and you
    can't paper over the difference with a shared literal.

      FPC mode delphi: string = AnsiString, Char = AnsiChar. A
      literal #$E2#$80#$A2 is three single-byte AnsiChars, i.e. the
      raw UTF-8 byte sequence for U+2022. Write/WriteLn emit those
      bytes verbatim to a UTF-8 terminal.

      Delphi: string = UnicodeString, Char = WideChar. The same
      literal #$E2#$80#$A2 is three UTF-16 code units U+00E2 /
      U+0094 / U+0080 — `â` followed by two C1 control characters,
      not the intended glyph. WriteConsoleW(PWideChar(S), Length(S))
      ships exactly those three wide chars to the console, producing
      mojibake. The Delphi-correct form is a single WideChar at the
      Unicode codepoint, e.g. #$2022, which WriteConsoleW renders
      directly and TEncoding.UTF8 encodes to the 3-byte UTF-8
      sequence for redirected stdout.

    Picking by compiler avoids both pitfalls and needs no codepage
    directive or BOM. }
  {$IFDEF FPC}
  GLYPH_BULLET  = #$E2#$80#$A2;                            { U+2022 BULLET         }
  GLYPH_VBAR    = #$E2#$94#$82;                            { U+2502 BOX VERTICAL   }
  GLYPH_HBAR    = #$E2#$94#$80;                            { U+2500 BOX HORIZONTAL }
  {$ELSE}
  GLYPH_BULLET  = #$2022;                                  { U+2022 BULLET         }
  GLYPH_VBAR    = #$2502;                                  { U+2502 BOX VERTICAL   }
  GLYPH_HBAR    = #$2500;                                  { U+2500 BOX HORIZONTAL }
  {$ENDIF}
  GLYPH_DIVIDER = GLYPH_HBAR + GLYPH_HBAR +
                  GLYPH_HBAR + GLYPH_HBAR;                 { 4x ──── fence marker  }

function StartsWithStr(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            (Copy(S, 1, Length(Prefix)) = Prefix);
end;

function ReplaceFenced(const S, Open, Close, Wrap1, Wrap2: string): string;
{ Replace every occurrence of <Open>...<Close> in S with
  Wrap1<body>Wrap2. Open and Close are the marker strings (e.g. '**'
  for bold, '`' for inline code). Skips an empty body so '**' alone
  with no inside content stays verbatim. Uses PosEx to advance the
  search index — Pos always finds the first occurrence and would
  loop forever otherwise. }
var
  Idx, BodyStart, EndIdx: Integer;
  Before, Body, After: string;
begin
  Result := S;
  if Open = '' then Exit;
  Idx := 1;
  while True do
  begin
    Idx := PosEx(Open, Result, Idx);
    if Idx <= 0 then Break;
    BodyStart := Idx + Length(Open);
    EndIdx := PosEx(Close, Result, BodyStart);
    if EndIdx <= 0 then Break;
    if EndIdx = BodyStart then
    begin
      { Empty body — skip past both markers as literal text. }
      Idx := EndIdx + Length(Close);
      Continue;
    end;
    Before := Copy(Result, 1, Idx - 1);
    Body   := Copy(Result, BodyStart, EndIdx - BodyStart);
    After  := Copy(Result, EndIdx + Length(Close), MaxInt);
    Result := Before + Wrap1 + Body + Wrap2 + After;
    Idx := Length(Before) + Length(Wrap1) + Length(Body) +
           Length(Wrap2) + 1;
  end;
end;

function RenderInline(const S: string): string;
{ Apply per-line inline transforms in an order that prevents nested
  styling inside code spans (Codex P2 on PR #155).

  Strategy: pull every backtick-delimited code span out FIRST, store
  its already-rendered ANSI body in a parallel array, and leave a
  placeholder `#1<index>#1` in the text. Subsequent transforms
  (bold, italic, strikethrough, links) scan the placeholder-laden
  string and can't see what was inside the code; once they're done,
  we substitute each placeholder back with its stored body. The
  delimiter is SOH (#1), which models virtually never emit and which
  has no markdown meaning.

  Pass order on the remaining text:
    1. Bold (**) before italic (*) so the inner * isn't mis-paired.
    2. Strikethrough (~~).
    3. Links [text](url) — show URL after the styled text.
  Headings, bullets, blockquotes are line-level — handled before
  this is called. }
const
  PLACEHOLDER = #1;
var
  CodeBodies: array of string;
  Idx, BodyStart, EndIdx, LParen, RParen, LBracket, RBracket: Integer;
  Before, Body, LinkText, Url, After, Tag: string;
  i: Integer;
begin
  Result := S;

  { Pass 1: extract inline code into placeholders.

    `code` -> #1<N>#1 in the string, and CodeBodies[N] holds the
    already-styled "dim+reverse code reset" so later passes can't
    walk into it. Empty body (` `) stays verbatim. }
  SetLength(CodeBodies, 0);
  Idx := 1;
  while True do
  begin
    Idx := PosEx('`', Result, Idx);
    if Idx <= 0 then Break;
    BodyStart := Idx + 1;
    EndIdx := PosEx('`', Result, BodyStart);
    if EndIdx <= 0 then Break;
    if EndIdx = BodyStart then
    begin
      Idx := EndIdx + 1;
      Continue;
    end;
    Before := Copy(Result, 1, Idx - 1);
    Body   := Copy(Result, BodyStart, EndIdx - BodyStart);
    After  := Copy(Result, EndIdx + 1, MaxInt);
    SetLength(CodeBodies, Length(CodeBodies) + 1);
    CodeBodies[High(CodeBodies)] :=
      Ansi.Dim + #27'[7m' + Body + #27'[27m' + Ansi.Reset;
    Tag := PLACEHOLDER + IntToStr(High(CodeBodies)) + PLACEHOLDER;
    Result := Before + Tag + After;
    Idx := Length(Before) + Length(Tag) + 1;
  end;

  { Pass 2: the rest. Placeholders are #1-delimited, contain no
    markdown markers, and are invisible to these scans. }
  Result := ReplaceFenced(Result, '**', '**', Ansi.Bold, Ansi.Reset);
  Result := ReplaceFenced(Result, '*', '*', #27'[3m', #27'[23m');
  Result := ReplaceFenced(Result, '~~', '~~', #27'[9m', #27'[29m');

  { Links: [text](url) -> underlined text + (url) in dim. }
  Idx := Pos('[', Result);
  while Idx > 0 do
  begin
    LBracket := Idx;
    RBracket := PosEx(']', Result, LBracket + 1);
    if (RBracket <= 0) or (RBracket - LBracket < 2) then
    begin
      Idx := PosEx('[', Result, LBracket + 1);
      Continue;
    end;
    if (RBracket >= Length(Result)) or (Result[RBracket + 1] <> '(') then
    begin
      Idx := PosEx('[', Result, RBracket + 1);
      Continue;
    end;
    LParen := RBracket + 1;
    RParen := PosEx(')', Result, LParen + 1);
    if RParen <= 0 then Break;
    Before   := Copy(Result, 1, LBracket - 1);
    LinkText := Copy(Result, LBracket + 1, RBracket - LBracket - 1);
    Url      := Copy(Result, LParen + 1, RParen - LParen - 1);
    After    := Copy(Result, RParen + 1, MaxInt);
    Result   := Before + #27'[4m' + LinkText + #27'[24m' +
                ' (' + Ansi.Dim + Url + Ansi.Reset + ')' + After;
    Idx := Length(Before) + Length(LinkText) + Length(Url) + 16;
    if Idx > Length(Result) then Break;
    Idx := PosEx('[', Result, Idx);
  end;

  { Pass 3: substitute placeholders back with the stored code
    bodies. Runs after every other transform so the styled code
    text drops in untouched. }
  for i := 0 to High(CodeBodies) do
  begin
    Tag := PLACEHOLDER + IntToStr(i) + PLACEHOLDER;
    Result := StringReplace(Result, Tag, CodeBodies[i], []);
  end;
end;

function ApplyHeading(const Line: string; out Out_: string): Boolean;
{ #..#### at start of line followed by space => heading. Replaces
  the prefix with bold + colour. False if the line isn't a heading. }
begin
  Result := True;
  if StartsWithStr(Line, '#### ') then
    Out_ := Ansi.Bold + Copy(Line, 6, MaxInt) + Ansi.Reset
  else if StartsWithStr(Line, '### ') then
    Out_ := Ansi.Bold + Copy(Line, 5, MaxInt) + Ansi.Reset
  else if StartsWithStr(Line, '## ') then
    Out_ := Ansi.Bold + Ansi.Cyan + Copy(Line, 4, MaxInt) + Ansi.Reset
  else if StartsWithStr(Line, '# ') then
    Out_ := Ansi.BoldBlue + Copy(Line, 3, MaxInt) + Ansi.Reset
  else
    Result := False;
end;

function ApplyBullet(const Line: string; out Out_: string): Boolean;
{ - foo / * foo (leading whitespace allowed) => bullet glyph + body
  rendered through inline transforms. False on a non-bullet line. }
var
  Trim_, Body: string;
  Indent: string;
  i: Integer;
begin
  Result := False;
  Trim_ := TrimLeft(Line);
  if not (StartsWithStr(Trim_, '- ') or StartsWithStr(Trim_, '* ')) then Exit;
  Indent := '';
  for i := 1 to Length(Line) do
  begin
    if Line[i] = ' ' then Indent := Indent + ' '
    else Break;
  end;
  Body := Copy(Trim_, 3, MaxInt);
  Out_ := Indent + Ansi.BoldBlue + GLYPH_BULLET + Ansi.Reset + ' ' +
          RenderInline(Body);
  Result := True;
end;

function ApplyBlockquote(const Line: string; out Out_: string): Boolean;
{ > foo => `│ foo` with italic body, recursively rendered. }
var
  Body: string;
begin
  Result := False;
  if not StartsWithStr(Line, '> ') then Exit;
  Body := Copy(Line, 3, MaxInt);
  Out_ := Ansi.Dim + GLYPH_VBAR + ' ' + Ansi.Reset +
          #27'[3m' + RenderInline(Body) + #27'[23m';
  Result := True;
end;

function RenderMarkdown(const S: string): string;
{ Walk S line by line. Track fenced-code state across lines so an
  open ``` doesn't get its body inline-transformed. Returns the
  rendered output with newlines preserved (final newline included
  iff S had one). Plain text without markers passes through unchanged. }
var
  Lines: TStringList;
  i: Integer;
  Line, Rendered: string;
  SB: TStringBuilder;
  InCode: Boolean;
  HadFinalNewline: Boolean;
begin
  if S = '' then Exit('');
  HadFinalNewline := (S[Length(S)] = #10);
  Lines := TStringList.Create;
  SB := TStringBuilder.Create;
  try
    { TStringList.Text re-splits on the platform line terminator;
      use SetTextStr or assign Text directly — both keep blank
      lines, which markdown relies on for paragraph separation. }
    Lines.Text := S;
    InCode := False;
    for i := 0 to Lines.Count - 1 do
    begin
      Line := Lines[i];

      if StartsWithStr(TrimLeft(Line), '```') then
      begin
        InCode := not InCode;
        SB.AppendLine(Ansi.Dim + GLYPH_DIVIDER + Ansi.Reset);
        Continue;
      end;
      if InCode then
      begin
        SB.AppendLine(Ansi.Dim + '  ' + Line + Ansi.Reset);
        Continue;
      end;

      if ApplyHeading(Line, Rendered) then
      begin
        SB.AppendLine(Rendered);
        Continue;
      end;
      if ApplyBullet(Line, Rendered) then
      begin
        SB.AppendLine(Rendered);
        Continue;
      end;
      if ApplyBlockquote(Line, Rendered) then
      begin
        SB.AppendLine(Rendered);
        Continue;
      end;

      SB.AppendLine(RenderInline(Line));
    end;
    Result := SB.ToString;
    { TStringBuilder.AppendLine always adds a terminator. If the
      input didn't end with a newline (e.g. mid-stream chunk), trim
      ours off so the caller's next emission stays adjacent. }
    if (not HadFinalNewline) and (Result <> '') and
       (Result[Length(Result)] = #10) then
      SetLength(Result, Length(Result) - 1);
  finally
    SB.Free;
    Lines.Free;
  end;
end;

end.
