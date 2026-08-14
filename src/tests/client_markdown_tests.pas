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

procedure ExpectStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '"');
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
  Blocks: TMdBlocks;
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

  { ------------------------------------- protected spans stay protected -- }
  (* Each inline pass used to run over the previous pass's OUTPUT, so the
     two things that must stay literal did not. Both cases are ordinary in
     model output: code samples contain asterisks, real URLs contain
     underscores. *)
  H := MarkdownToHTML('use `**not bold**` here');
  ExpectHas(H, '<code>**not bold**</code>',
            'emphasis does not reach inside a code span');
  ExpectLacks(H, '<strong>not bold</strong>',
              'and the asterisks are not markup');

  H := MarkdownToHTML('[docs](https://example.com/a_b_c)');
  ExpectHas(H, 'href="https://example.com/a_b_c"',
            'underscores in a URL survive the italic pass');
  ExpectLacks(H, '<em>b</em>', 'they are not read as emphasis');

  H := MarkdownToHTML('see [a_b](https://e.com/x_y) and *real* emphasis');
  ExpectHas(H, 'href="https://e.com/x_y"', 'the URL is intact');
  ExpectHas(H, '<em>real</em>', 'while emphasis outside a link still works');

  { A code span next to a link: neither may capture the other. }
  H := MarkdownToHTML('`a` then [t](https://e.com/p) then `b`');
  ExpectHas(H, '<code>a</code>', 'first code span');
  ExpectHas(H, '<code>b</code>', 'second code span');
  ExpectHas(H, 'href="https://e.com/p"', 'and the link between them');

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

  (* A COMPLETE, STANDALONE document, and the reason that matters changed.

     It used to reach the browser through LoadFromStrings, where an
     unterminated or headless fragment would still mostly render. It is
     written to a file and navigated to now -- see ShowHtml in the FMX
     client, and the white chat window that made it necessary -- and a file
     is parsed as a file: no doctype at the front and the charset is a guess,
     no </html> and a truncated write looks like a whole page.

     So this pins the frame, not just the body. If a chat window ever comes
     up blank again, these assertions passing is what says the content was
     fine and the delivery was not. *)
  ExpectTrue(Pos('<!doctype html>', LowerCase(H)) = 1,
             'the document opens with a doctype, at the very start');
  ExpectHas(LowerCase(H), 'charset="utf-8"',
            'and declares utf-8 rather than leaving it to be sniffed');
  ExpectHas(LowerCase(H), '</html>', 'and is terminated');

  { Unicode in the model's own words has to survive the whole way out. }
  H := ChatDocumentHTML(MarkdownToHTML('an em dash -- really a ' + #$2014 +
                                       ' and a ' + #$00E9),
                        '#c0c0c0', '#000', '#000080', '#fff');
  ExpectHas(H, #$2014, 'an em dash survives into the document');
  ExpectHas(H, #$00E9, 'and an accented letter');

  (* ---- the same markdown, as BLOCKS ----

     The chat window renders with ordinary FMX controls rather than a
     TWebBrowser -- a browser is a native control that has to be swapped for
     a snapshot to coexist with overlapping windows, and its engine
     initialises asynchronously, which is how the chat became a white
     square. A stack of labels has neither problem.

     Which puts the parsing here, where FPC compiles it and this runs. The
     client is left with "make a label, make a memo", and everything with a
     rule in it is asserted below. *)
  Blocks := MarkdownToBlocks('# Title'#10#10'Some **bold** prose.'#10 +
    'Wrapped onto two lines.'#10#10'- one'#10'- two'#10#10'1. first'#10 +
    '2. second'#10#10'> quoted'#10#10'---'#10#10'```'#10'x := 1;'#10'```');

  ExpectTrue(Length(Blocks) = 9,
             'nine blocks out of that document');
  ExpectTrue(Blocks[0].Kind = mbHeading, 'the heading is a heading');
  ExpectTrue(Blocks[0].Level = 1, 'at level one');
  ExpectStr(Blocks[0].Text, 'Title', 'with its hashes gone');

  { Consecutive prose lines are ONE paragraph -- a model that hard-wraps
    must not become a column of one-line labels. }
  ExpectTrue(Blocks[1].Kind = mbParagraph, 'the prose is a paragraph');
  ExpectStr(Blocks[1].Text, 'Some bold prose. Wrapped onto two lines.',
            'joined, with the emphasis markers flattened');

  ExpectTrue(Blocks[2].Kind = mbBullet, 'a bullet');
  ExpectStr(Blocks[2].Text, 'one', 'with its dash gone');
  ExpectTrue(Blocks[4].Kind = mbNumber, 'a numbered item');
  ExpectTrue(Blocks[4].Level = 1, 'carrying its own number');
  ExpectStr(Blocks[5].Text, 'second', 'and the second');
  ExpectTrue(Blocks[6].Kind = mbQuote, 'a quote');
  ExpectTrue(Blocks[7].Kind = mbRule, 'a rule');
  ExpectTrue(Blocks[8].Kind = mbCode, 'and a code block');
  ExpectStr(Blocks[8].Text, 'x := 1;',
            'handed over VERBATIM -- a fence is the one place the source ' +
            'characters are the content');

  { Inline flattening, on its own. A label has no rich text, so the markers
    come off -- but a link's destination is kept, because dropping where
    something points is worse than showing it. }
  ExpectStr(FlattenInline('a **bold** and `code` word'),
            'a bold and code word', 'emphasis and code markers come off');
  ExpectStr(FlattenInline('see [the docs](https://x.test/a)'),
            'see the docs (https://x.test/a)',
            'a link keeps its destination');
  ExpectStr(FlattenInline('an ![image](p.png) inline'),
            'an image (p.png) inline', 'an image loses only its bang');
  ExpectStr(FlattenInline('2 * 3 * 4'), '2 * 3 * 4',
            'a lone asterisk in prose is not emphasis');
  ExpectStr(FlattenInline('a * b'#10'c * d'), 'a * b'#10'c * d',
            'and a pair spanning a newline is not either');

  (* What is inside a code span and inside a URL is LITERAL, and both are
     full of characters that look like emphasis markers. Stripping the
     backticks and moving on left the later passes free to eat what they
     had been protecting: `__init__` came out as "init". *)
  ExpectStr(FlattenInline('call `__init__` first'), 'call __init__ first',
            'a code span survives the emphasis passes intact');
  ExpectStr(FlattenInline('`a * b * c`'), 'a * b * c',
            'asterisks inside code are characters, not markers');
  ExpectStr(FlattenInline('see [docs](https://x.test/a_b_c)'),
            'see docs (https://x.test/a_b_c)',
            'and underscores in a URL are part of the address');
  ExpectStr(FlattenInline('[**docs**](https://x.test/a)'),
            'docs (https://x.test/a)',
            'the link TEXT is still flattened -- only the URL is protected');
  ExpectStr(FlattenInline('`code` and **bold**'), 'code and bold',
            'the ordinary case is unchanged by the parking');

  { A fence hands over its lines verbatim, and a blank first line is one of
    them. Using "nothing accumulated yet" to mean "no line seen yet" ate
    exactly the leading whitespace the block promised to keep. }
  Blocks := MarkdownToBlocks('```'#10#10'  indented'#10'```');
  ExpectTrue(Length(Blocks) = 1, 'the fence is one block');
  ExpectStr(Blocks[0].Text, #10'  indented',
            'and its leading blank line survives');

  { The fail-safe rule the HTML side keeps, kept here too. }
  Blocks := MarkdownToBlocks('before'#10'```'#10'never closed');
  ExpectTrue(Length(Blocks) = 2, 'an unterminated fence still yields blocks');
  ExpectTrue(Blocks[1].Kind = mbCode, 'the run becomes code');
  ExpectStr(Blocks[1].Text, 'never closed',
            'and the text inside it survives rather than vanishing');

  ExpectTrue(Length(MarkdownToBlocks('   ')) = 0, 'blank in, nothing out');

  if Failures = 0 then
    WriteLn('client_markdown_tests: OK')
  else
  begin
    WriteLn('client_markdown_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
