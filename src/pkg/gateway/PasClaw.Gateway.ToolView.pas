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
     `string`=AnsiString, `Char`=AnsiChar (1 byte) -- a literal '⏺' is a
     3-byte UTF-8 sequence tagged with whichever codepage the source file
     resolves to, and concatenating it with a CP_0-tagged variable can
     drop it to '?' on a non-UTF-8 locale; raw `#$XX#$XX#$XX` byte
     constants are codepage-agnostic. On Delphi `string`=UnicodeString,
     `Char`=WideChar -- the single WideChar form is the natural way to
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
  surrounding newlines -- the caller frames it for the stream. }
function FormatToolCallLine(const Name, ArgsJSON: string): string;

{ One visible line summarizing a tool result, indented two spaces to sit under
  its call line, e.g.
    ⎿ 312 lines, 12044 bytes -- ¶README.md#a1b2
    ⎿ exit=0
    ⎿ ✗ file not found
  No trailing newline. }
function FormatToolResultLine(const Name, ResultText, Err: string): string;

{ Compact single-line JSON describing a tool call or result, carried over the
  `pasclaw-tool` SSE comment side-channel (TSSEStreamer.WriteComment). The web
  UI reads these to populate the expandable tool-card body with the FULL
  arguments / result; OpenAI-compatible clients drop SSE comments, so the
  visible content stream (FormatToolCallLine / FormatToolResultLine) is
  unaffected. Kind is 'call' or 'result'. Large args / results are capped so a
  giant patch or file read can't flood the stream; truncation is flagged in
  the value. The JSON is always one physical line (string values escape
  newlines), so it rides a single comment frame. }
function FormatToolDetailJSON(const Kind, Name, ArgsJSON, ResultText, Err: string): string;

implementation

uses
  SysUtils, Classes,      { TStringList, for the checklist summary }
  PasClaw.JSON,
  PasClaw.Config,          { GetHome, for Relativize }
  PasClaw.Hashline;

const
  MaxArgWidth     = 160;  { cap inline arg summaries so a giant command or
                            patch can't flood the chat transcript }
  MaxResultWidth  = 200;  { cap single-line result echoes and error text }
  MaxPreviewWidth = 120;  { cap the first-line preview on multi-line results }

function Relativize(const S: string): string;
{ Fold the PasClaw home out of any path in a line meant for a human.

  Tool results carry absolute paths, and the desktop shows them in the
  chat: "wrote 98 bytes to /home/you/.pasclaw/workspace/projects/x/app/
  app.json" wraps over three lines to say something the reader already
  knows, and publishes the server's directory layout to anyone looking
  over their shoulder. Rendered relative it is "wrote 98 bytes to
  workspace/projects/x/app/app.json".

  DISPLAY ONLY. The tool result the model receives is untouched -- it
  needs the real path to act on it, and rewriting what the agent sees to
  make the UI tidier would be a bug factory. }
var
  Home: string;
begin
  Result := S;
  Home := GetHome;
  if Home = '' then Exit;
  while (Home <> '') and (Home[Length(Home)] = PathDelim) do
    SetLength(Home, Length(Home) - 1);
  if Home = '' then Exit;
  Result := StringReplace(Result, Home + PathDelim, '', [rfReplaceAll]);
  { A bare mention of the home directory with nothing after it. }
  Result := StringReplace(Result, Home, '~', [rfReplaceAll]);
end;

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

(* "tile, then open notes" rather than the JSON that said so.

   The desktop tool takes an ARRAY of {"do":...} objects, and the
   interesting part of each is the verb plus whatever it names. Several
   actions in one call is the normal case -- the tool exists so "tidy up
   and open my three projects" is one turn -- so they are joined rather
   than truncated to the first. *)
function DesktopActions(Obj: TJsonObject): string;
var
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Verb, What, Sep: string;
begin
  Result := '';
  if Obj = nil then Exit;
  Arr := Obj.ChildArray('actions');
  if Arr = nil then Exit;
  try
    for i := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(i);
      if Item = nil then Continue;
      try
        Verb := Item.GetStr('do', '');
        if Verb = '' then Continue;
        What := Item.GetStr('project', '');
        if What = '' then What := Item.GetStr('title', '');
        if What = '' then What := Item.GetStr('id', '');
        if What <> '' then Verb := Verb + ' ' + What;
        if Result = '' then Sep := '' else Sep := ', ';
        Result := Result + Sep + Verb;
      finally
        Item.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

(* A checklist is markdown lines; showing its source with the newlines
   escaped is showing the reader the wire format. Say the shape --
   how many steps, how many are done -- and let the ledger carry the
   detail, which is where the model reads it back anyway. *)
function ChecklistSummary(const Checklist: string): string;
var
  L: TStringList;
  i, Total, Done: Integer;
  Line: string;
begin
  Total := 0; Done := 0;
  L := TStringList.Create;
  try
    L.Text := StringReplace(Checklist, #13, '', [rfReplaceAll]);
    for i := 0 to L.Count - 1 do
    begin
      Line := TrimLeft(L[i]);
      if Copy(Line, 1, 2) <> '- ' then Continue;
      Inc(Total);
      Line := TrimLeft(Copy(Line, 3, MaxInt));
      if (Copy(Line, 1, 3) = '[x]') or (Copy(Line, 1, 3) = '[X]') then Inc(Done);
    end;
  finally
    L.Free;
  end;
  if Total = 0 then Exit('checklist');
  Result := Format('%d step(s), %d done', [Total, Done]);
end;

function FormatToolCallLine(const Name, ArgsJSON: string): string;
var
  Obj: TJsonObject;
  Summary, Pattern, Path, Inc_: string;
begin
  { TJsonObject.Parse raises EPasClawJSON on malformed input -- providers
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
    if (Name = 'read_file') or (Name = 'fs_read') then
    begin
      Summary := ArgStr(Obj, 'path');
      if (Obj <> nil) and Obj.GetBool('plain', False) then
        Summary := Summary + ', plain';
    end
    else if (Name = 'write_file') or (Name = 'append_file') or
            (Name = 'list_dir') or
            (Name = 'fs_write') or (Name = 'fs_list') then
      Summary := ArgStr(Obj, 'path')
    else if (Name = 'grep_files') or (Name = 'fs_grep') then
    begin
      Pattern := ArgStr(Obj, 'pattern');
      Path    := ArgStr(Obj, 'path');
      Summary := '"' + Pattern + '"';
      if Path <> '' then Summary := Summary + ' in ' + Path;
      Inc_ := ArgStr(Obj, 'include');
      if Inc_ <> '' then Summary := Summary + ' (' + Inc_ + ')';
    end
    else if (Name = 'edit_file') or (Name = 'fs_edit_hashline') then
    begin
      { str-replace mode carries a path; hashline mode carries a patch. }
      Summary := ArgStr(Obj, 'path');
      if Summary = '' then Summary := FirstPatchPath(ArgStr(Obj, 'patch'));
    end
    else if Name = 'apply_patch' then
      Summary := FirstPatchPath(ArgStr(Obj, 'patch'))
    else if Name = 'shell_exec' then
      Summary := ArgStr(Obj, 'command')

    (* ---- the desktop's own vocabulary ----

       Everything below fell through to the raw-arguments branch, which
       meant the tools that make the desktop a DESKTOP were the ones
       shown as JSON: a person who asked for their windows tidied read
       back `desktop({"actions": [{"do": "tile"}]})`, and a checklist
       came back as its escaped markdown source. The unknown-tool dump
       is the right answer for an MCP tool nobody here has seen; it is
       the wrong one for the tools this product ships. *)
    else if Name = 'desktop' then
      Summary := DesktopActions(Obj)
    else if Name = 'todo_write' then
      Summary := ChecklistSummary(ArgStr(Obj, 'checklist'))
    else if (Name = 'project') or (Name = 'task') then
    begin
      { "what it did, to what" -- the action plus whichever name the
        action actually carries. }
      Summary := ArgStr(Obj, 'action');
      Path := ArgStr(Obj, 'name');
      if Path = '' then Path := ArgStr(Obj, 'id');
      if Path = '' then Path := ArgStr(Obj, 'title');
      if (Name = 'task') and (ArgStr(Obj, 'project') <> '') then
      begin
        if Path = '' then Path := ArgStr(Obj, 'project')
        else Path := ArgStr(Obj, 'project') + '/' + Path;
      end;
      if Path <> '' then Summary := Summary + ' ' + Path;
    end
    else if (Name = 'memory_search') or (Name = 'kb_search') or
            (Name = 'web_search') or (Name = 'tool_search') or
            (Name = 'session_search') then
      Summary := '"' + ArgStr(Obj, 'query') + '"'
    else if (Name = 'web_fetch') or (Name = 'memory_fetch') then
      Summary := ArgStr(Obj, 'url')
    else if Name = 'find_files' then
    begin
      Summary := '"' + ArgStr(Obj, 'pattern') + '"';
      Path := ArgStr(Obj, 'path');
      if Path <> '' then Summary := Summary + ' in ' + Path;
    end
    else if Name = 'execute_code' then
    begin
      { The code itself is the wrong summary -- it is the whole
        argument. Say the language and how much of it there is. }
      Path := ArgStr(Obj, 'lang');
      if Path = '' then Path := 'code';
      Summary := Format('%s, %d chars', [Path, Length(ArgStr(Obj, 'code'))]);
    end
    else if Name = 'tool_output_get' then
      Summary := ArgStr(Obj, 'handle')
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
    Body := Ellipsize(Relativize(CollapseWhitespace(ResultText)), MaxResultWidth)
  else
  begin
    { Multi-line: counts plus a peek at the first line (the hashline header on
      fs_read/fs_grep, "exit=N" on shell_exec, etc.). }
    Preview := Ellipsize(Relativize(CollapseWhitespace(FirstLineOf(ResultText))),
                         MaxPreviewWidth);
    if Preview <> '' then
      Body := Format('%d lines, %d bytes -- %s', [Lines, Bytes, Preview])
    else
      Body := Format('%d lines, %d bytes', [Lines, Bytes]);
  end;

  Result := '  ' + TV_RESULT_GLYPH + ' ' + Body;
end;

const
  MaxDetailArgs   = 8 * 1024;   { cap full-args echo in the side-channel    }
  MaxDetailResult = 16 * 1024;  { cap full-result echo in the side-channel  }

function CapDetail(const S: string; Max: Integer): string;
begin
  if Length(S) <= Max then Result := S
  else Result := Copy(S, 1, Max) +
    Format(#10'...(truncated, %d more bytes)', [Length(S) - Max]);
end;

function FormatToolDetailJSON(const Kind, Name, ArgsJSON, ResultText, Err: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('t', Kind);
    Obj.PutStr('name', Name);
    { Relativized like the visible lines: this feeds the web UI's
      expandable tool card, which is a display surface too. The model
      never reads the side-channel, so nothing it acts on changes. }
    if Kind = 'call' then
      Obj.PutStr('args', Relativize(CapDetail(ArgsJSON, MaxDetailArgs)))
    else if Err <> '' then
      Obj.PutStr('err', Relativize(CapDetail(Err, MaxDetailResult)))
    else
      Obj.PutStr('result', Relativize(CapDetail(ResultText, MaxDetailResult)));
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

end.
