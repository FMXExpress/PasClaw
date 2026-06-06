program markdown_render_tests;
{ Covers PasClaw.Markdown.Render — the ANSI styler for LLM output
  in the terminal. We don't assert on exact escape codes because
  Ansi.* fields are configurable; instead, prove the structural
  transformations happened: marker chars consumed, content
  preserved, ANSI escapes present in expected places. }

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Markdown.Render;

procedure Fail(const Msg, Body: string);
begin
  WriteLn('FAIL: ' + Msg);
  WriteLn('--- output ---');
  WriteLn(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected substring: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail(Msg + ' (did NOT expect substring: ' + Needle + ')', Haystack);
end;

procedure TestPlainPassThrough;
{ A plain-text reply with no markers should round-trip unchanged
  (modulo line terminators). Important for streaming chunks: we
  don't want the renderer adding ANSI noise to "Hello!". }
var
  Got: string;
begin
  Got := RenderMarkdown('Hello, world.');
  if Got <> 'Hello, world.' then
    Fail('plain text changed', Got);
end;

procedure TestBold;
var
  Got: string;
begin
  Got := RenderMarkdown('this is **important** text');
  AssertMissing(Got, '**', 'bold markers consumed');
  AssertContains(Got, 'important', 'bold content preserved');
  AssertContains(Got, Ansi.Bold, 'ANSI bold inserted');
end;

procedure TestItalic;
var
  Got: string;
begin
  Got := RenderMarkdown('an *emphasised* word');
  AssertMissing(Got, '*emphasised*', 'italic markers consumed');
  AssertContains(Got, 'emphasised',  'italic content preserved');
  AssertContains(Got, #27'[3m',      'ANSI italic-on inserted');
  AssertContains(Got, #27'[23m',     'ANSI italic-off inserted');
end;

procedure TestInlineCode;
var
  Got: string;
begin
  Got := RenderMarkdown('use `RenderMarkdown` here');
  AssertMissing(Got, '`RenderMarkdown`', 'backticks consumed');
  AssertContains(Got, 'RenderMarkdown',  'code text preserved');
  AssertContains(Got, Ansi.Dim,          'code styled with dim');
end;

procedure TestHeading;
var
  Got: string;
begin
  Got := RenderMarkdown('# Big Header');
  AssertMissing(Got, '# Big',     'heading hash consumed');
  AssertContains(Got, 'Big Header', 'heading text preserved');
  AssertContains(Got, Ansi.BoldBlue, 'h1 wrapped in BoldBlue');
end;

procedure TestBulletList;
var
  Got: string;
begin
  Got := RenderMarkdown('- one' + sLineBreak +
                        '- two' + sLineBreak +
                        '- three');
  AssertContains(Got, 'one',   'bullet 1 body preserved');
  AssertContains(Got, 'two',   'bullet 2 body preserved');
  AssertContains(Got, 'three', 'bullet 3 body preserved');
  AssertMissing(Got, '- one',  'bullet marker consumed');
  AssertContains(Got, #$E2#$80#$A2, 'unicode bullet glyph emitted');
end;

procedure TestFencedCode;
var
  Got: string;
begin
  Got := RenderMarkdown('before' + sLineBreak +
                        '```' + sLineBreak +
                        '  x := 1;' + sLineBreak +
                        '  **not bold inside**' + sLineBreak +
                        '```' + sLineBreak +
                        'after');
  AssertContains(Got, 'x := 1;', 'fenced code body preserved');
  { Bold markers inside a fenced block must NOT be transformed —
    that's the model's literal code, not styling. }
  AssertContains(Got, '**not bold inside**',
    'bold inside fenced block stays verbatim');
  AssertContains(Got, 'before', 'pre-fence content preserved');
  AssertContains(Got, 'after',  'post-fence content preserved');
end;

procedure TestLink;
var
  Got: string;
begin
  Got := RenderMarkdown('see [the docs](https://example.com/x) for more');
  AssertMissing(Got, '[the docs](https://example.com/x)',
    'link markdown markers consumed');
  AssertContains(Got, 'the docs', 'link text preserved');
  AssertContains(Got, 'https://example.com/x', 'link URL preserved');
  AssertContains(Got, #27'[4m',  'underline applied to link text');
end;

procedure TestBlockquote;
var
  Got: string;
begin
  Got := RenderMarkdown('> a quoted line');
  AssertContains(Got, 'a quoted line', 'blockquote body preserved');
  AssertMissing(Got, '> a',            'leading > consumed');
  AssertContains(Got, '│',             'blockquote bar emitted');
end;

procedure TestEmpty;
begin
  if RenderMarkdown('') <> '' then
    Fail('empty input returned non-empty', RenderMarkdown(''));
end;

procedure TestNoTrailingNewlineAdded;
{ Streaming chunks arrive without a final newline; if we add one
  the caller's next emission lands on the wrong line. }
var
  Got: string;
begin
  Got := RenderMarkdown('partial **token**');
  if (Got <> '') and (Got[Length(Got)] = #10) then
    Fail('renderer added a trailing newline to a no-newline input', Got);
end;

begin
  CliUI_Init(False);   { populate Ansi.* so style markers compare correctly }
  TestPlainPassThrough;
  TestBold;
  TestItalic;
  TestInlineCode;
  TestHeading;
  TestBulletList;
  TestFencedCode;
  TestLink;
  TestBlockquote;
  TestEmpty;
  TestNoTrailingNewlineAdded;
  WriteLn('markdown_render_tests: OK');
end.
