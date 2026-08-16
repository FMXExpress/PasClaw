program toolview_tests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Config,          { GetHome, to build the path under test }
  PasClaw.Gateway.ToolView;

procedure Fail(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected to find "' + Needle + '" in "' + Haystack + '")');
end;

procedure AssertEquals(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure TestFsReadCall;
begin
  AssertEquals(FormatToolCallLine('fs_read', '{"path":"README.md"}'),
               TV_CALL_GLYPH + ' fs_read(README.md)',
               'fs_read call summary');
  AssertContains(FormatToolCallLine('fs_read', '{"path":"a.txt","plain":true}'),
                 'a.txt, plain', 'fs_read plain flag');
end;

procedure TestShellCall;
begin
  AssertEquals(FormatToolCallLine('shell_exec', '{"command":"ls -la"}'),
               TV_CALL_GLYPH + ' shell_exec(ls -la)',
               'shell_exec call summary');
end;

procedure TestGrepCall;
begin
  AssertEquals(FormatToolCallLine('fs_grep', '{"path":"src","pattern":"TODO"}'),
               TV_CALL_GLYPH + ' fs_grep("TODO" in src)',
               'fs_grep call summary');
  AssertContains(FormatToolCallLine('fs_grep',
                   '{"path":"src","pattern":"TODO","include":"*.pas"}'),
                 '(*.pas)', 'fs_grep include glob');
end;

procedure TestEditHashlineCall;
begin
  { Path is pulled out of the patch header (¶path#hash on the first line). }
  AssertEquals(FormatToolCallLine('fs_edit_hashline',
                 '{"patch":"¶src/foo.pas#abcd\n42:\n|new line"}'),
               TV_CALL_GLYPH + ' fs_edit_hashline(src/foo.pas)',
               'fs_edit_hashline path from patch header');
end;

procedure TestUnknownToolFallback;
begin
  { MCP / unknown tools dump the raw args, whitespace collapsed to one line. }
  AssertContains(FormatToolCallLine('web_search', '{"query":"pascal"}'),
                 'web_search(', 'unknown tool keeps name');
  AssertContains(FormatToolCallLine('web_search', '{"query":"pascal"}'),
                 'query', 'unknown tool dumps raw args');
end;

procedure TestArgTruncation;
{ Glyph form depends on the compiler's `string` type -- see TV_ELLIPSIS
  in PasClaw.Gateway.ToolView. Use the same constant the renderer emits
  so the assertion is codepage-tag-independent. }
const
  {$IFDEF FPC}
  EllipsisGlyph = #$E2#$80#$A6;
  {$ELSE}
  EllipsisGlyph = #$2026;
  {$ENDIF}
var
  Big, Line: string;
  i: Integer;
begin
  Big := '';
  for i := 1 to 500 do Big := Big + 'x';
  Line := FormatToolCallLine('shell_exec', '{"command":"' + Big + '"}');
  AssertContains(Line, EllipsisGlyph, 'long argument is ellipsized');
  if Length(Line) > 220 then
    Fail('long argument not capped (len=' + IntToStr(Length(Line)) + ')');
end;

procedure TestResultLineCount;
begin
  AssertContains(FormatToolResultLine('fs_read', 'a'#10'b'#10'c', ''),
                 '3 lines', 'multi-line result counts lines');
  AssertContains(FormatToolResultLine('fs_read', 'a'#10'b'#10'c', ''),
                 TV_RESULT_GLYPH, 'result line carries the corner glyph');
end;

procedure TestResultSingleLineEcho;
begin
  { A single short line is echoed verbatim, not reduced to a byte count. }
  AssertContains(FormatToolResultLine('shell_exec', 'exit=0', ''),
                 'exit=0', 'short single-line result is echoed');
end;

procedure TestResultError;
{ Same compiler-split rationale as TestArgTruncation. }
const
  {$IFDEF FPC}
  ErrorGlyph = #$E2#$9C#$97;
  {$ELSE}
  ErrorGlyph = #$2717;
  {$ENDIF}
begin
  AssertContains(FormatToolResultLine('fs_read', '', 'file not found'),
                 ErrorGlyph, 'error result carries the failure glyph');
  AssertContains(FormatToolResultLine('fs_read', '', 'file not found'),
                 'file not found', 'error result carries the message');
end;

procedure TestResultEmpty;
begin
  AssertContains(FormatToolResultLine('fs_write', '', ''),
                 '(no output)', 'empty success result is labelled');
end;

procedure TestResultTrailingNewline;
begin
  { A trailing newline must not inflate the line count. }
  AssertContains(FormatToolResultLine('shell_exec', 'only line'#10, ''),
                 'only line', 'trailing newline kept as single line');
end;

procedure TestMalformedArgsDoesNotRaise;
{ Providers occasionally stream truncated `arguments` (think mid-token
  cut-off in a tool_use block). TJsonObject.Parse raises EPasClawJSON on
  that input, and FormatToolCallLine sits on the SSE-streamer hot path --
  if it lets the exception escape, the whole stream tears down with no
  terminal event. Verify the helper handles malformed JSON by falling
  back to the raw-args echo. }
var
  Line: string;
begin
  Line := FormatToolCallLine('fs_read', '{"path":"foo');
  AssertContains(Line, 'fs_read', 'malformed fs_read still names the tool');

  Line := FormatToolCallLine('shell_exec', 'not json at all');
  AssertContains(Line, 'shell_exec', 'malformed shell_exec still names the tool');

  Line := FormatToolCallLine('fs_grep', '{"pattern":"x"');
  AssertContains(Line, 'fs_grep', 'malformed fs_grep still names the tool');

  Line := FormatToolCallLine('web_search', '');
  AssertContains(Line, 'web_search', 'empty args fall through to the unknown branch');
end;

procedure TestDetailJSON;
{ The pasclaw-tool side-channel payload: compact, single-line JSON the web UI
  parses to fill the expandable card. Must carry full args/result, be one
  physical line, and cap pathological sizes. }
var
  J, Big: string;
  i: Integer;
begin
  (* Serializer spaces the tokens but stays on one physical line; JSON.parse
     in the web UI tolerates the spacing. Assert on values + the no-newline
     invariant rather than exact byte spacing. *)
  J := FormatToolDetailJSON('call', 'fs_read', '{"path":"README.md"}', '', '');
  AssertContains(J, '"call"',    'detail call kind');
  AssertContains(J, 'fs_read',   'detail call name');
  AssertContains(J, 'README.md', 'detail call carries full args');
  if Pos(#10, J) > 0 then Fail('detail JSON must be one physical line (call)');

  J := FormatToolDetailJSON('result', 'shell_exec', '', 'exit=0'#10'done', '');
  AssertContains(J, '"result"', 'detail result kind');
  AssertContains(J, 'exit=0',   'detail result carries full text');
  if Pos(#10, J) > 0 then Fail('detail JSON must be one physical line (result)');

  J := FormatToolDetailJSON('result', 'fs_read', '', '', 'file not found');
  AssertContains(J, '"err"', 'detail surfaces the error field');
  AssertContains(J, 'file not found', 'detail carries the error message');

  { Oversized result is capped with a truncation marker. }
  Big := '';
  for i := 1 to 40 * 1024 do Big := Big + 'x';
  J := FormatToolDetailJSON('result', 'fs_read', '', Big, '');
  AssertContains(J, 'truncated', 'oversized result flags truncation');
  if Length(J) > 20 * 1024 then
    Fail('oversized result not capped (len=' + IntToStr(Length(J)) + ')');
end;

(* Paths shown to a human are relative to the PasClaw home.

   A write confirmation used to read "wrote 98 bytes to /home/you/
   .pasclaw/workspace/projects/x/app/app.json" in the desktop's chat --
   three wrapped lines to say something the reader knew, with the
   server's directory layout attached. What the MODEL receives is
   untouched; only these display strings change. *)
procedure TestRelativePaths;
var
  Abs, Line, J: string;
begin
  Abs := GetHome;
  if Abs = '' then Exit;            { no home configured: nothing to fold }
  if Abs[Length(Abs)] <> PathDelim then Abs := Abs + PathDelim;
  Abs := Abs + 'workspace' + PathDelim + 'projects' + PathDelim + 'x' +
         PathDelim + 'app.json';

  Line := FormatToolResultLine('write_file',
            'wrote 98 bytes to ' + Abs, '');
  AssertContains(Line, 'workspace', 'the workspace-relative path survives');
  if Pos(GetHome, Line) > 0 then
    Fail('the home directory is still in the visible result line: ' + Line);

  { The side-channel feeds the web UI's tool card -- display too. }
  J := FormatToolDetailJSON('result', 'write_file', '',
         'wrote 98 bytes to ' + Abs, '');
  if Pos(GetHome, J) > 0 then
    Fail('the home directory is still in the tool-card detail: ' + J);
end;

begin
  TestFsReadCall;
  TestShellCall;
  TestGrepCall;
  TestEditHashlineCall;
  TestUnknownToolFallback;
  TestArgTruncation;
  TestResultLineCount;
  TestResultSingleLineEcho;
  TestResultError;
  TestResultEmpty;
  TestResultTrailingNewline;
  TestMalformedArgsDoesNotRaise;
  TestDetailJSON;
  TestRelativePaths;
  Writeln('PASS');
end.
