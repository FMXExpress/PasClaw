program client_markdown_tests;
(*
  Pins PasClaw.Client.Markdown: the markdown-to-HTML converter the GUI
  clients render chat with.

  Two things matter more than the formatting itself, and they are what most
  of this file is about:

    1. HTML in model output is ESCAPED. A reply containing a script tag has
       to render as those characters. This is the security boundary of the
       unit, and it is the assertion worth breaking the build over.
    2. Nothing DISAPPEARS. Unmatched markers, unterminated fences and odd
       input must degrade to their own literal characters -- an answer that
       comes out emptier than it went in is worse than an ugly one.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, PasClaw.Client.Markdown;

var Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectHas(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" missing from: ' + Copy(Hay, 1, 300));
end;

procedure ExpectLacks(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) > 0 then
    Fail_(Msg + ' -- "' + Needle + '" unexpectedly present in: ' +
          Copy(Hay, 1, 300));
end;

var
  H: string;
begin
  { ---------------------------------------------------- the safety rule -- }
  (* Model output is untrusted text. Every one of these must come back as
     characters on screen, not as markup the renderer honours. *)
  H := MarkdownToHTML('before <script>alert(1)</script> after');
  ExpectLacks(H, '<script>', 'a script tag never survives as markup');
  ExpectHas(H, '&lt;script&gt;', 'it is shown as text instead');
  ExpectHas(H, 'before', 'and the surrounding words survive');

  H := MarkdownToHTML('<img src=x onerror="steal()">');
  ExpectLacks(H, '<img', 'an img tag is escaped too');
  ExpectHas(H, '&lt;img', 'and rendered as text');

  H := MarkdownToHTML('an & ampersand and a "quote"');
  ExpectHas(H, '&amp;', 'ampersands are escaped');
  ExpectHas(H, '&quot;', 'quotes are escaped');

  { A javascript: link is either a mistake or an attack. Either way it does
    not become clickable. }
  H := MarkdownToHTML('[click](javascript:alert(1))');
  ExpectLacks(H, '<a href', 'a javascript: URL is not linked');
  ExpectHas(H, 'click', 'but the text is still shown');

  H := MarkdownToHTML('[docs](https://example.com/x)');
  ExpectHas(H, '<a href="https://example.com/x">docs</a>', 'an http link is linked');

  { ------------------------------------------------------- the formatting }
  H := MarkdownToHTML('# Title');
  ExpectHas(H, '<h1>Title</h1>', 'heading level 1');
  H := MarkdownToHTML('### Small');
  ExpectHas(H, '<h3>Small</h3>', 'heading level 3');

  H := MarkdownToHTML('this is **bold** here');
  ExpectHas(H, '<strong>bold</strong>', 'bold');
  H := MarkdownToHTML('this is *italic* here');
  ExpectHas(H, '<em>italic</em>', 'italic');
  H := MarkdownToHTML('call `foo()` now');
  ExpectHas(H, '<code>foo()</code>', 'inline code');

  H := MarkdownToHTML('- one'#10'- two');
  ExpectHas(H, '<ul>', 'a bullet list opens');
  ExpectHas(H, '<li>one</li>', 'with its items');
  ExpectHas(H, '</ul>', 'and closes');

  H := MarkdownToHTML('1. first'#10'2. second');
  ExpectHas(H, '<ol>', 'a numbered list opens');
  ExpectHas(H, '<li>second</li>', 'with its items');

  H := MarkdownToHTML('> quoted');
  ExpectHas(H, '<blockquote>quoted</blockquote>', 'blockquote');

  H := MarkdownToHTML('a'#10#10'---'#10#10'b');
  ExpectHas(H, '<hr>', 'horizontal rule');

  { Code blocks are verbatim: markers inside them are content, not markup. }
  H := MarkdownToHTML('```'#10'not **bold** here'#10'```');
  ExpectHas(H, '<pre><code>', 'a fence opens a code block');
  ExpectHas(H, 'not **bold** here', 'and its contents are untouched');
  ExpectLacks(H, '<strong>', 'inline markup is not applied inside code');

  { ...and escaped inside them too, which is where a naive renderer leaks. }
  H := MarkdownToHTML('```'#10'<script>x</script>'#10'```');
  ExpectLacks(H, '<script>', 'a script tag inside a fence is still escaped');

  { ------------------------------------------------ nothing disappears -- }
  { An unmatched marker is a character, not an instruction. }
  H := MarkdownToHTML('2 * 3 = 6');
  ExpectHas(H, '2 * 3 = 6', 'a lone asterisk is left alone');

  H := MarkdownToHTML('unclosed **bold');
  ExpectHas(H, 'unclosed', 'text before an unpaired marker survives');
  ExpectHas(H, 'bold', 'and after it');

  { An unterminated fence must still close its element, or everything the
    caller appends afterwards lands inside a code block. }
  H := MarkdownToHTML('```'#10'dangling');
  ExpectHas(H, '</code></pre>', 'an unterminated fence is closed anyway');
  ExpectHas(H, 'dangling', 'and its content is kept');

  ExpectTrue(MarkdownToHTML('') = '', 'empty in, empty out');
  ExpectTrue(Trim(MarkdownToHTML('   ')) = '', 'blank in, empty out');

  H := MarkdownToHTML('just a sentence');
  ExpectHas(H, '<p>just a sentence</p>', 'plain prose becomes a paragraph');

  { ------------------------------------------------------ the document -- }
  H := ChatDocumentHTML('<p>hi</p>', '#c0c0c0', '#000', '#000080', '#fff');
  ExpectHas(H, '<p>hi</p>', 'the body is included');
  ExpectHas(H, '#c0c0c0', 'the background colour is applied');
  ExpectHas(H, '#000080', 'and the accent');
  ExpectHas(H, 'scrollTo', 'and it scrolls to the newest turn');

  if Failures = 0 then
    WriteLn('client_markdown_tests: OK')
  else
  begin
    WriteLn('client_markdown_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
