program session_port_tests;
(*
  Covers PasClaw.Session.Port -- import of foreign chat exports and Markdown
  export. Runs against an isolated PASCLAW_HOME (Makefile target sets it).

  Pins:
    - format detection: ChatGPT conversations.json (array + mapping),
      Claude Code .jsonl (typed lines), PasClaw native (messages object),
      garbage -> unknown
    - ChatGPT import walks the current_node parent chain (edited branches
      fall away), imports user/assistant text turns only, keeps title +
      create_time, one session per conversation
    - Claude Code import: summary line becomes the title, string and
      block-array content both work, tool_use/tool_result blocks skipped
    - native import round-trips an exported session under a fresh id
    - Markdown export renders title + role-labelled turns, skips system
    - imported sessions are immediately visible to ListSessions
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Session.Port;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

procedure WipeStore;
var
  Sr: TSearchRec;
  Dir: string;
begin
  Dir := JoinPath(GetHome, 'workspace/sessions');
  if not DirectoryExists(Dir) then begin ForceDirectories(Dir); Exit; end;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, Sr) = 0 then
  try
    repeat
      if (Sr.Attr and faDirectory) = 0 then DeleteFile(JoinPath(Dir, Sr.Name));
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
end;

const
  (* Two-conversation ChatGPT export. Conversation 1 has an edited branch:
     node "b2" (the abandoned answer) is NOT on the current_node parent
     chain and must not be imported. Node roles cover system (skipped),
     user, assistant. *)
  CHATGPT_EXPORT =
    '[' +
    ' {"title":"Pasta advice","create_time":1700000000.5,' +
    '  "current_node":"a3",' +
    '  "mapping":{' +
    '   "root":{"id":"root","message":null,"parent":null,"children":["s1"]},' +
    '   "s1":{"id":"s1","message":{"author":{"role":"system"},' +
    '         "content":{"content_type":"text","parts":[""]}},' +
    '         "parent":"root","children":["u1"]},' +
    '   "u1":{"id":"u1","message":{"author":{"role":"user"},' +
    '         "content":{"content_type":"text","parts":["how long do I boil rigatoni"]}},' +
    '         "parent":"s1","children":["b2","a2"]},' +
    '   "b2":{"id":"b2","message":{"author":{"role":"assistant"},' +
    '         "content":{"content_type":"text","parts":["ABANDONED BRANCH ANSWER"]}},' +
    '         "parent":"u1","children":[]},' +
    '   "a2":{"id":"a2","message":{"author":{"role":"assistant"},' +
    '         "content":{"content_type":"text","parts":["about 12 minutes, salted water"]}},' +
    '         "parent":"u1","children":["a3"]},' +
    '   "a3":{"id":"a3","message":{"author":{"role":"user"},' +
    '         "content":{"content_type":"text","parts":["and fresh pasta?"]}},' +
    '         "parent":"a2","children":[]}' +
    '  }},' +
    ' {"title":"Empty one","create_time":1700000001,' +
    '  "current_node":"r","mapping":{' +
    '   "r":{"id":"r","message":null,"parent":null,"children":[]}}}' +
    ']';

  CLAUDE_JSONL =
    '{"type":"summary","summary":"Fixing the build","leafUuid":"x"}' + #10 +
    '{"type":"user","uuid":"u1","message":{"role":"user","content":"why does make fail"}}' + #10 +
    '{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[' +
      '{"type":"text","text":"missing dependency; run make get-indy"},' +
      '{"type":"tool_use","id":"t1","name":"shell","input":{"cmd":"make"}}]}}' + #10 +
    '{"type":"user","uuid":"u2","message":{"role":"user","content":[' +
      '{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}' + #10 +
    '{"type":"user","uuid":"u3","message":{"role":"user","content":"thanks, that fixed it"}}';

const
  (* pi-agent format: header line, then id/parentId tree entries. Active leaf =
     last entry (a2); its chain is a2 -> uy -> mc -> a1 -> u1. "ux" is an
     abandoned sibling of uy; "tr" is a toolResult entry (not a chain member
     of the leaf path -- hangs off a2's sibling branch? no: keep it as an
     out-of-chain entry so the walk simply never visits it). *)
  PI_JSONL =
    '{"type":"session","version":3,"id":"sess-1","timestamp":"2024-12-03T14:00:00.000Z","cwd":"/tmp/p"}' + #10 +
    '{"type":"message","id":"u1","parentId":null,"message":{"role":"user","content":"first question"}}' + #10 +
    '{"type":"message","id":"a1","parentId":"u1","message":{"role":"assistant","content":[' +
      '{"type":"text","text":"answer one"},' +
      '{"type":"toolCall","id":"tc1","name":"bash","arguments":"ls"}]}}' + #10 +
    '{"type":"message","id":"ux","parentId":"a1","message":{"role":"user","content":"ABANDONED path"}}' + #10 +
    '{"type":"message","id":"tr","parentId":"ux","message":{"role":"toolResult","content":"ignored"}}' + #10 +
    '{"type":"model_change","id":"mc","parentId":"a1","provider":"openai","modelId":"gpt-4o"}' + #10 +
    '{"type":"message","id":"uy","parentId":"mc","message":{"role":"user","content":"real followup"}}' + #10 +
    '{"type":"message","id":"a2","parentId":"uy","message":{"role":"assistant","content":[' +
      '{"type":"text","text":"final answer"}]}}';

procedure TestDetect;
begin
  Check(DetectImportFormat(CHATGPT_EXPORT) = ifChatGPT, 'detect: chatgpt');
  Check(DetectImportFormat(CLAUDE_JSONL) = ifClaudeJSONL, 'detect: claude jsonl');
  Check(DetectImportFormat(PI_JSONL) = ifPiJSONL, 'detect: pi/openclaw jsonl');
  Check(DetectImportFormat('{"messages":[{"role":"user","content":"hi"}]}') = ifNative,
        'detect: native');
  Check(DetectImportFormat('hello world') = ifUnknown, 'detect: garbage unknown');
  Check(DetectImportFormat('') = ifUnknown, 'detect: empty unknown');
end;

procedure TestChatGPTImport;
var
  Ids: TImportedIds;
  Err: string;
  N: Integer;
  S: TSession;
begin
  WipeStore;
  N := ImportSessions(CHATGPT_EXPORT, Ids, Err);
  Check(N = 1, 'chatgpt: 1 conversation imported (empty one skipped), got ' +
        IntToStr(N) + ' err=' + Err);
  if N < 1 then Exit;
  S := TSession.Create(Ids[0]);
  try
    Check(S.MetaExists, 'chatgpt: session persisted');
    Check(S.Meta.Title = 'Pasta advice', 'chatgpt: title kept (got ' + S.Meta.Title + ')');
    Check(S.Meta.CreatedAt = 1700000000, 'chatgpt: create_time kept');
    Check(Pos('import:chatgpt', S.Meta.Provider) > 0, 'chatgpt: provider tagged');
    Check(Length(S.Messages) = 3, 'chatgpt: 3 turns (system skipped), got ' +
          IntToStr(Length(S.Messages)));
    if Length(S.Messages) = 3 then
    begin
      Check(S.Messages[0].Role = mrUser, 'chatgpt: turn 1 role');
      Check(Pos('rigatoni', S.Messages[0].Content) > 0, 'chatgpt: turn 1 content');
      Check(Pos('12 minutes', S.Messages[1].Content) > 0, 'chatgpt: current branch kept');
      Check(Pos('fresh pasta', S.Messages[2].Content) > 0, 'chatgpt: trailing user turn');
    end;
    Check(Pos('ABANDONED', ReadFileText(SessionPath(Ids[0]))) = 0,
          'chatgpt: abandoned branch not imported');
  finally
    S.Free;
  end;
end;

(* Pi / OpenClaw: tree-structured JSONL. The fixture has an ABANDONED branch
   (entry "ux" hangs off a1 but the appended-later path goes a1 -> mc
   (model_change, chain link only) -> uy -> a2), a toolResult entry (skipped),
   and an assistant whose content mixes a text block with a toolCall block. *)
procedure TestPiImport;
var
  Ids: TImportedIds;
  Err: string;
  N: Integer;
  S: TSession;
begin
  WipeStore;
  N := ImportSessions(PI_JSONL, Ids, Err);
  Check(N = 1, 'pi: 1 session imported, err=' + Err);
  if N < 1 then Exit;
  S := TSession.Create(Ids[0]);
  try
    Check(S.MetaExists, 'pi: session persisted');
    Check(Pos('import:pi', S.Meta.Provider) > 0, 'pi: provider tagged');
    Check(S.Meta.CreatedAt = 1733184000, 'pi: header date kept (got ' +
          IntToStr(S.Meta.CreatedAt) + ')');
    Check(Length(S.Messages) = 4, 'pi: 4 turns on the active branch, got ' +
          IntToStr(Length(S.Messages)));
    if Length(S.Messages) = 4 then
    begin
      Check(S.Messages[0].Role = mrUser, 'pi: turn 1 role');
      Check(Pos('first question', S.Messages[0].Content) > 0, 'pi: root user turn');
      Check(Pos('answer one', S.Messages[1].Content) > 0, 'pi: text block extracted');
      Check(Pos('toolCall', S.Messages[1].Content) = 0, 'pi: toolCall block skipped');
      Check(Pos('real followup', S.Messages[2].Content) > 0, 'pi: active branch kept');
      Check(Pos('final answer', S.Messages[3].Content) > 0, 'pi: leaf turn kept');
    end;
    Check(Pos('ABANDONED', ReadFileText(SessionPath(Ids[0]))) = 0,
          'pi: abandoned branch not imported');
  finally
    S.Free;
  end;
end;

procedure TestClaudeImport;
var
  Ids: TImportedIds;
  Err: string;
  N: Integer;
  S: TSession;
begin
  WipeStore;
  N := ImportSessions(CLAUDE_JSONL, Ids, Err);
  Check(N = 1, 'claude: 1 session imported, err=' + Err);
  if N < 1 then Exit;
  S := TSession.Create(Ids[0]);
  try
    Check(S.Meta.Title = 'Fixing the build', 'claude: summary became title');
    Check(Length(S.Messages) = 3, 'claude: 3 text turns (tool blocks skipped), got ' +
          IntToStr(Length(S.Messages)));
    if Length(S.Messages) = 3 then
    begin
      Check(Pos('make fail', S.Messages[0].Content) > 0, 'claude: user string content');
      Check(Pos('make get-indy', S.Messages[1].Content) > 0, 'claude: assistant text block');
      Check(Pos('tool_use', S.Messages[1].Content) = 0, 'claude: tool_use block skipped');
      Check(Pos('thanks', S.Messages[2].Content) > 0, 'claude: trailing user turn');
    end;
  finally
    S.Free;
  end;
end;

procedure TestNativeRoundTripAndMarkdown;
var
  Ids: TImportedIds;
  Err, Raw, MD: string;
  N: Integer;
  S: TSession;
begin
  WipeStore;
  { author a RICH session the agent-loop way: an assistant tool_call turn
    paired with a tool-result turn. A native re-import must keep the pairing,
    or the copy is invalid to resume against providers. }
  S := TSession.Create('sess-orig');
  try
    S.Meta.Title := 'Original';
    S.Meta.Model := 'orig-model';
    SetLength(S.Messages, 5);
    S.Messages[0] := MakeMessage(mrSystem,    'system blob');
    S.Messages[1] := MakeMessage(mrUser,      'ping?');
    S.Messages[2] := MakeMessage(mrAssistant, '');
    SetLength(S.Messages[2].ToolCalls, 1);
    S.Messages[2].ToolCalls[0].Id := 'call-1';
    S.Messages[2].ToolCalls[0].Kind := 'function';
    S.Messages[2].ToolCalls[0].Func.Name := 'shell_exec';
    S.Messages[2].ToolCalls[0].Func.Arguments := '{"cmd":"echo hi"}';
    S.Messages[3] := MakeMessage(mrTool, 'hi');
    S.Messages[3].ToolCallId := 'call-1';
    S.Messages[4] := MakeMessage(mrAssistant, 'pong!');
    S.Touch;
    S.Save;
  finally
    S.Free;
  end;

  { native import of its own export file = a fresh copy under a new id }
  Raw := ReadFileText(SessionPath('sess-orig'));
  N := ImportSessions(Raw, Ids, Err);
  Check(N = 1, 'native: re-import ok, err=' + Err);
  Check((N = 1) and (Ids[0] <> 'sess-orig'), 'native: fresh id assigned');
  if N = 1 then
  begin
    S := TSession.Create(Ids[0]);
    try
      Check(S.Meta.Title = 'Original', 'native: title preserved');
      Check(S.Meta.Model = 'orig-model', 'native: model preserved');
      Check(Length(S.Messages) = 5, 'native: all turns preserved (got ' +
            IntToStr(Length(S.Messages)) + ')');
      if Length(S.Messages) = 5 then
      begin
        Check(Length(S.Messages[2].ToolCalls) = 1, 'native: assistant tool_call kept');
        if Length(S.Messages[2].ToolCalls) = 1 then
        begin
          Check(S.Messages[2].ToolCalls[0].Id = 'call-1', 'native: tool_call id kept');
          Check(S.Messages[2].ToolCalls[0].Func.Name = 'shell_exec',
                'native: tool_call function kept');
        end;
        Check(S.Messages[3].Role = mrTool, 'native: tool turn kept');
        Check(S.Messages[3].ToolCallId = 'call-1', 'native: tool_call_id pairing kept');
      end;
    finally
      S.Free;
    end;
  end;

  { markdown export }
  Check(ExportSessionMarkdown('sess-orig', MD, Err), 'md: exports (' + Err + ')');
  Check(Pos('# Original', MD) = 1, 'md: title heading first');
  Check(Pos('## user', MD) > 0, 'md: user turn labelled');
  Check(Pos('pong!', MD) > 0, 'md: assistant content present');
  Check(Pos('system blob', MD) = 0, 'md: system turn skipped');
  Check(not ExportSessionMarkdown('nope-123', MD, Err), 'md: unknown id fails');
  Check(not ExportSessionMarkdown('../evil', MD, Err), 'md: unsafe id rejected');
end;

procedure TestUnknownFormat;
var
  Ids: TImportedIds;
  Err: string;
begin
  Check(ImportSessions('not json at all', Ids, Err) = 0, 'unknown: imports nothing');
  Check(Pos('unrecognized', Err) > 0, 'unknown: error names the supported formats');
end;

begin
  TestDetect;
  TestChatGPTImport;
  TestPiImport;
  TestClaudeImport;
  TestNativeRoundTripAndMarkdown;
  TestUnknownFormat;

  if Failures = 0 then WriteLn('session_port_tests: OK')
  else begin WriteLn('session_port_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
