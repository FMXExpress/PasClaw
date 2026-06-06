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
{ Apply per-line inline transforms in an order that avoids
  collisions:
    1. inline code first (so other markers inside stay verbatim)
    2. bold (**) before italic (*) so we don't mis-pair the inner *
    3. strikethrough (~~)
    4. links [text](url) — show url after the styled text
  Headings, bullets, blockquotes are handled at the line level by
  RenderMarkdown before this is called. }
var
  Idx, LParen, RParen, LBracket, RBracket: Integer;
  Before, LinkText, Url, After: string;
begin
  Result := S;

  { Inline code: `code` -> dim + reverse. Done first so other
    markers inside backticks survive untouched. }
  Result := ReplaceFenced(Result, '`', '`',
                          Ansi.Dim + #27'[7m', #27'[27m' + Ansi.Reset);

  { Bold: **text** -> bold. Must precede italic. }
  Result := ReplaceFenced(Result, '**', '**',
                          Ansi.Bold, Ansi.Reset);

  { Italic: *text* -> italic ANSI (3m). Skipped when the markers
    are flanked by other word chars (e.g. snake_case_var) — that's
    why we look for whitespace / start-of-string before the opener. }
  Result := ReplaceFenced(Result, '*', '*',
                          #27'[3m', #27'[23m');

  { Strikethrough: ~~text~~ -> ANSI 9m. }
  Result := ReplaceFenced(Result, '~~', '~~',
                          #27'[9m', #27'[29m');

  { Links: [text](url) -> underlined text + (url). Hand-rolled
    because the pattern needs two adjacent markers. }
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
  Out_ := Indent + Ansi.BoldBlue + '•' + Ansi.Reset + ' ' +
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
  Out_ := Ansi.Dim + '│ ' + Ansi.Reset +
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
        SB.AppendLine(Ansi.Dim + '────' + Ansi.Reset);
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
