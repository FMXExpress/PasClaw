(*
  PasClaw.Gateway.ToolView - human-readable summaries of tool activity for
  the streaming /v1/chat/completions endpoint.

  Background: when the gateway runs the tool loop for a streamed completion it
  used to surface each tool to the client as a bare "[tool: <name>]" marker.
  The interesting detail (which file, which command, how big the result) lived
  only in the server debug log and in SSE comment lines (`: ...`) that every
  spec-compliant OpenAI client silently discards. The front end therefore saw
  "[tool: fs_read]" and nothing else.

  Claude Code's transcript instead shows each call with its name and key
  argument plus a short result summary. These pure string transforms build the
  same kind of one-liners so the streamer can emit them as *visible* content
  deltas. They have no Indy/socket dependency, so they can be unit-tested in
  isolation (see src/tests/toolview_tests.pas).
*)
unit PasClaw.Gateway.ToolView;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

const
  (* Glyphs mirror the agent CLI handlers (PasClaw.Cmd.Agent) and Claude
     Code's transcript style: a filled dot marks the call, a corner marks the
     result line that sits under it.

     Encoded the way the active compiler's `string` type wants them, same
     trick as PasClaw.Markdown.Render after PR #157. On FPC mode delphi
     `string`=AnsiString, `Char`=AnsiChar (1 byte) — a literal '⏺' is a
     3-byte UTF-8 sequence tagged with whichever codepage the source file
     resolves to, and concatenating it with a CP_0-tagged variable can
     drop it to '?' on a non-UTF-8 locale; raw `#$XX#$XX#$XX` byte
     constants are codepage-agnostic. On Delphi `string`=UnicodeString,
     `Char`=WideChar — the single WideChar form is the natural way to
     name the codepoint and WriteConsoleW renders it directly.

     Codepoints: U+23FA ⏺ BLACK CIRCLE FOR RECORD, U+23BF ⎿ LIGHT
     LEFT TORTOISE SHELL BRACKET LOWER CORNER. *)
  {$IFDEF FPC}
  TV_CALL_GLYPH   = #$E2#$8F#$BA;
  TV_RESULT_GLYPH = #$E2#$8E#$BF;
  TV_ELLIPSIS     = #$E2#$80#$A6;        { U+2026 HORIZONTAL ELLIPSIS    }
  TV_ERROR_GLYPH  = #$E2#$9C#$97;        { U+2717 BALLOT X               }
  {$ELSE}
  TV_CALL_GLYPH   = #$23FA;
  TV_RESULT_GLYPH = #$23BF;
  TV_ELLIPSIS     = #$2026;
  TV_ERROR_GLYPH  = #$2717;
  {$ENDIF}

{ One visible line describing a tool invocation, e.g.
    ⏺ fs_read(README.md)
    ⏺ shell_exec(ls -la)
    ⏺ fs_grep("TODO" in src)
  Known tools surface their most meaningful argument; unknown / MCP tools fall
  back to a compact single-line dump of the raw arguments. The result has no
  surrounding newlines — the caller frames it for the stream. }
function FormatToolCallLine(const Name, ArgsJSON: string): string;

{ One visible line summarizing a tool result, indented two spaces to sit under
  its call line, e.g.
    ⎿ 312 lines, 12044 bytes — ¶README.md#a1b2
    ⎿ exit=0
    ⎿ ✗ file not found
  No trailing newline. }
function FormatToolResultLine(const Name, ResultText, Err: string): string;

implementation

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Hashline;

const
  MaxArgWidth     = 160;  { cap inline arg summaries so a giant command or
                            patch can't flood the chat transcript }
  MaxResultWidth  = 200;  { cap single-line result echoes and error text }
  MaxPreviewWidth = 120;  { cap the first-line preview on multi-line results }

function CollapseWhitespace(const S: string): string;
{ Fold CR/LF/TAB and runs of spaces into a single space so a multi-line value
  renders as one tidy inline summary. Implemented with ASCII-only
  StringReplace, which is byte-safe under FPC's UTF-8 strings: the bytes we
  match (0x0D / 0x0A / 0x09 / 0x20) never occur inside a multi-byte UTF-8
  sequence, so a codepoint is never split or corrupted. }
const
  ScanCap = 4096;  { bound the squeeze loop on pathological input; the output
                     is ellipsized far below this anyway }
var
  W: string;
begin
  if Length(S) > ScanCap then W := Copy(S, 1, ScanCap) else W := S;
  W := StringReplace(W, #13, ' ', [rfReplaceAll]);
  W := StringReplace(W, #10, ' ', [rfReplaceAll]);
  W := StringReplace(W, #9,  ' ', [rfReplaceAll]);
  { Each pass halves runs of spaces; loop until none remain. }
  while Pos('  ', W) > 0 do
    W := StringReplace(W, '  ', ' ', [rfReplaceAll]);
  Result := Trim(W);
end;

function Ellipsize(const S: string; MaxLen: Integer): string;
begin
  if Length(S) <= MaxLen then Result := S
  else Result := Copy(S, 1, MaxLen) + TV_ELLIPSIS;
end;

function FirstLineOf(const S: string): string;
var
  NL: Integer;
begin
  NL := Pos(#10, S);
  if NL > 0 then Result := Copy(S, 1, NL - 1)
  else Result := S;
end;

function CountLines(const S: string): Integer;
{ Lines of content, ignoring a single trailing newline so "exit=0"#10 counts
  as one line, not two. }
var
  i: Integer;
begin
  if S = '' then Exit(0);
  Result := 1;
  for i := 1 to Length(S) do
    if S[i] = #10 then Inc(Result);
  if S[Length(S)] = #10 then Dec(Result);
  if Result < 1 then Result := 1;
end;

function FirstPatchPath(const Patch: string): string;
{ Pull the target path out of a hashline patch header (¶path#hash on the
  first line). Encoding-agnostic: HL_FILE_PREFIX and the patch share the
  compiler's native string form, so the prefix Copy/compare lines up under
  both Delphi (WideChar) and FPC (UTF-8 bytes). }
var
  Line: string;
  HashPos: Integer;
begin
  Line := Trim(StringReplace(FirstLineOf(Patch), #13, '', [rfReplaceAll]));
  if Copy(Line, 1, Length(HL_FILE_PREFIX)) = HL_FILE_PREFIX then
    Line := Copy(Line, Length(HL_FILE_PREFIX) + 1, MaxInt);
  HashPos := Pos(HL_FILE_HASH_SEP, Line);
  if HashPos > 0 then Line := Copy(Line, 1, HashPos - 1);
  Result := Trim(Line);
end;

function ArgStr(Obj: TJsonObject; const Key: string): string;
begin
  if Obj = nil then Result := ''
  else Result := Obj.GetStr(Key, '');
end;

function FormatToolCallLine(const Name, ArgsJSON: string): string;
var
  Obj: TJsonObject;
  Summary, Pattern, Path, Inc_: string;
begin
  { TJsonObject.Parse raises EPasClawJSON on malformed input — providers
    occasionally stream truncated `arguments` (the tool loop tolerates
    this and surfaces a per-tool error). Swallow the parse failure here
    and treat Obj as nil so the unknown-tool branch echoes the raw
    ArgsJSON; the helper must never raise, otherwise an exception
    propagates through TSSEStreamer and the whole stream dies. }
  Obj := nil;
  try
    try
      Obj := TJsonObject.Parse(ArgsJSON);
    except
      on EPasClawJSON do
        Obj := nil;
    end;
    if Name = 'fs_read' then
    begin
      Summary := ArgStr(Obj, 'path');
      if (Obj <> nil) and Obj.GetBool('plain', False) then
        Summary := Summary + ', plain';
    end
    else if (Name = 'fs_write') or (Name = 'fs_list') then
      Summary := ArgStr(Obj, 'path')
    else if Name = 'fs_grep' then
    begin
      Pattern := ArgStr(Obj, 'pattern');
      Path    := ArgStr(Obj, 'path');
      Summary := '"' + Pattern + '"';
      if Path <> '' then Summary := Summary + ' in ' + Path;
      Inc_ := ArgStr(Obj, 'include');
      if Inc_ <> '' then Summary := Summary + ' (' + Inc_ + ')';
    end
    else if Name = 'fs_edit_hashline' then
      Summary := FirstPatchPath(ArgStr(Obj, 'patch'))
    else if Name = 'shell_exec' then
      Summary := ArgStr(Obj, 'command')
    else
      { Unknown / MCP tool: compact dump of the raw arguments so the client
        still sees what the model passed. }
      Summary := ArgsJSON;
  finally
    Obj.Free;
  end;

  Summary := Ellipsize(CollapseWhitespace(Summary), MaxArgWidth);
  Result := TV_CALL_GLYPH + ' ' + Name + '(' + Summary + ')';
end;

function FormatToolResultLine(const Name, ResultText, Err: string): string;
var
  Body, Preview: string;
  Lines, Bytes: Integer;
begin
  if Err <> '' then
  begin
    Result := '  ' + TV_RESULT_GLYPH + ' ' + TV_ERROR_GLYPH + ' ' +
              Ellipsize(CollapseWhitespace(Err), MaxResultWidth);
    Exit;
  end;

  Bytes := Length(ResultText);
  if Bytes = 0 then
  begin
    Result := '  ' + TV_RESULT_GLYPH + ' (no output)';
    Exit;
  end;

  Lines := CountLines(ResultText);
  if Lines <= 1 then
    { Single-line result: echo it (truncated). Covers fs_write confirmations,
      short shell output, etc. }
    Body := Ellipsize(CollapseWhitespace(ResultText), MaxResultWidth)
  else
  begin
    { Multi-line: counts plus a peek at the first line (the hashline header on
      fs_read/fs_grep, "exit=N" on shell_exec, etc.). }
    Preview := Ellipsize(CollapseWhitespace(FirstLineOf(ResultText)), MaxPreviewWidth);
    if Preview <> '' then
      Body := Format('%d lines, %d bytes — %s', [Lines, Bytes, Preview])
    else
      Body := Format('%d lines, %d bytes', [Lines, Bytes]);
  end;

  Result := '  ' + TV_RESULT_GLYPH + ' ' + Body;
end;

end.
