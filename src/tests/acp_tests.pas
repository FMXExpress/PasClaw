program acp_tests;
(*
  Pins PasClaw.ACP -- the agent side of the Agent Client Protocol -- with a
  scripted TACPHost in place of the tool loop: no model, no network.

    - the translation: tool kinds and titles, todo_write's checklist as a
      plan, a prompt's content blocks as one prompt, paths against the
      session's cwd, the modes
    - the wire: ids echoed as they came (number or string), parse errors,
      a request before initialize, unknown methods, unknown notifications
      ignored
    - a turn: text, a tool call and its update, a diff for a file an edit
      tool rewrote -- and none for a file a read tool merely named
    - an ask: session/request_permission out, the client's answer back to
      the host, as allow-for-the-session
    - cancel: a pending ask is released as a no, the turn answers
      "cancelled", a second prompt on a busy session is refused
    - load: the history is replayed, in order, before the response
    - a host that raises: a JSON-RPC error, not a dead agent
    - a call the turn never finished: shown failed before the turn answers,
      and not left to take the next turn's same-named result
    - a long result cut for display stays valid UTF-8

  acp_e2e_test.py drives the real binary over stdio against a fake model;
  this file pins the protocol layer alone, fast.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Providers.Types,
  PasClaw.Permissions,
  PasClaw.Agent.Mode,
  PasClaw.ACP;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const A, B, Msg: string);
begin
  if A <> B then Fail_(Msg + ' (expected "' + B + '" got "' + A + '")');
end;

{ ------------------------------------------------------------- the wire -- }

type
  TCapture = class
    Lines: TStringList;
    Lock: TCriticalSection;
    constructor Create;
    destructor Destroy; override;
    procedure WriteLine(const L: string);
    function Count: Integer;
    function Line(i: Integer): string;
    { Wait for a line containing Sub at or after From; its index, or -1. }
    function WaitFor(const Sub: string; From: Integer = 0; TimeoutMs: Integer = 5000): Integer;
    function Has(const Sub: string; From: Integer = 0): Boolean;
  end;

constructor TCapture.Create;
begin
  Lines := TStringList.Create;
  Lock := TCriticalSection.Create;
end;

destructor TCapture.Destroy;
begin
  Lines.Free;
  Lock.Free;
  inherited;
end;

procedure TCapture.WriteLine(const L: string);
begin
  Lock.Enter;
  try
    Lines.Add(L);
  finally
    Lock.Leave;
  end;
end;

function TCapture.Count: Integer;
begin
  Lock.Enter;
  try
    Result := Lines.Count;
  finally
    Lock.Leave;
  end;
end;

function TCapture.Line(i: Integer): string;
begin
  Lock.Enter;
  try
    Result := Lines[i];
  finally
    Lock.Leave;
  end;
end;

function TCapture.WaitFor(const Sub: string; From, TimeoutMs: Integer): Integer;
var
  Deadline: QWord;
  i: Integer;
begin
  Deadline := GetTickCount64 + QWord(TimeoutMs);
  repeat
    for i := From to Count - 1 do
      if Pos(Sub, Line(i)) > 0 then Exit(i);
    Sleep(10);
  until GetTickCount64 > Deadline;
  Result := -1;
end;

function TCapture.Has(const Sub: string; From: Integer): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := From to Count - 1 do
    if Pos(Sub, Line(i)) > 0 then Exit(True);
end;

{ ------------------------------------------------------- the fake agent -- }

type
  TFakeHost = class(TACPHost)
    Dir: string;               { a scratch "project" }
    History: TMessageArray;    { what a load returns }
    Answer: TAskAnswer;
    Asked: Boolean;
    function OpenSession(S: TACPSession; McpServers: TJsonArray; Load: Boolean;
                         out Hist: TMessageArray; out NotFound: Boolean;
                         out Err: string): Boolean; override;
    function RunPrompt(S: TACPSession; const PromptText: string;
                       Turn: TACPTurn): TACPTurnOutcome; override;
  end;

var
  SessionSeq: Integer = 0;

function TFakeHost.OpenSession(S: TACPSession; McpServers: TJsonArray; Load: Boolean;
  out Hist: TMessageArray; out NotFound: Boolean; out Err: string): Boolean;
begin
  NotFound := False;
  Err := '';
  SetLength(Hist, 0);
  if Load then
  begin
    if S.Id <> 'saved' then
    begin
      NotFound := True;
      Err := 'no such session';
      Exit(False);
    end;
    Hist := History;
  end
  else
  begin
    Inc(SessionSeq);
    S.Id := 'sess-' + IntToStr(SessionSeq);
  end;
  Result := True;
end;

function TFakeHost.RunPrompt(S: TACPSession; const PromptText: string;
  Turn: TACPTurn): TACPTurnOutcome;
var
  F: string;
  Deadline: QWord;
begin
  Result := Default(TACPTurnOutcome);
  Result.StopReason := 'end_turn';
  if Pos('basic', PromptText) > 0 then
  begin
    Turn.Text('hello');
    { An edit: the file changes between call and result. }
    F := IncludeTrailingPathDelimiter(Dir) + 'edit.txt';
    WriteFileText(F, 'old' + LineEnding);
    Turn.ToolCall('write_file', '{"path":"edit.txt","content":"new"}');
    WriteFileText(F, 'new' + LineEnding);
    Turn.ToolResult('write_file', 'wrote 4 bytes', '');
    { A read naming a file: no diff, whatever the file says. }
    Turn.ToolCall('read_file', '{"path":"edit.txt"}');
    WriteFileText(F, 'changed by someone else' + LineEnding);
    Turn.ToolResult('read_file', 'new', '');
    Turn.ToolCall('shell_exec', '{"command":"false"}');
    Turn.ToolResult('shell_exec', 'exit=1', 'command failed');
    Turn.ToolCall('write_file', '{"path":"plan.txt","content":"x"}');
    Turn.ToolResult('write_file', 'refused: tool "write_file" needs build mode', '');
    Turn.Text('done');
  end
  else if Pos('ask', PromptText) > 0 then
  begin
    Turn.ToolCall('shell_exec', '{"command":"ls"}');
    Answer := Turn.Ask('shell_exec', '{"command":"ls"}', 'ls', 'a rule says ask');
    Asked := True;
    Turn.ToolResult('shell_exec', 'ok', '');
  end
  else if Pos('wait', PromptText) > 0 then
  begin
    { Run until cancelled -- the loop's cooperative stop, in miniature. }
    Deadline := GetTickCount64 + 5000;
    while not Turn.Cancelled and (GetTickCount64 < Deadline) do Sleep(10);
  end
  else if Pos('boom', PromptText) > 0 then
    raise Exception.Create('the model went away')
  else if Pos('orphan', PromptText) > 0 then
  begin
    { Two calls announced, one result: the loop stopped between them. }
    Turn.ToolCall('shell_exec', '{"command":"a"}');
    Turn.ToolCall('shell_exec', '{"command":"b"}');
    Turn.ToolResult('shell_exec', 'a done', '');
  end
  else if Pos('next', PromptText) > 0 then
  begin
    Turn.ToolCall('shell_exec', '{"command":"c"}');
    Turn.ToolResult('shell_exec', 'c done', '');
  end
  else if Pos('deltas', PromptText) > 0 then
  begin
    { Streamed text: pieces as written, a new round's first marked. }
    Turn.TextDelta('Hel', True);
    Turn.TextDelta('lo', False);
    Turn.ToolCall('list_dir', '{"path":"."}');
    Turn.ToolResult('list_dir', 'a.txt', '');
    Turn.TextDelta('Next', True);
  end
  else if Pos('utf8', PromptText) > 0 then
  begin
    { A two-byte character straddling the 32 KiB display cut. }
    Turn.ToolCall('read_file', '{"path":"big.txt"}');
    Turn.ToolResult('read_file', StringOfChar('a', 32 * 1024 - 1) + #$C3#$A9 + 'tail', '');
  end;
end;

var
  Cap: TCapture;
  Host: TFakeHost;
  Agent: TACPAgent;
  ScratchDir: string;

procedure Send(const L: string);
begin
  Agent.HandleLine(L);
end;

function Prompt(const Id, Sid, Text: string): string;
begin
  Result := '{"jsonrpc":"2.0","id":' + Id + ',"method":"session/prompt","params":{' +
            '"sessionId":"' + Sid + '","prompt":[{"type":"text","text":"' + Text + '"}]}}';
end;

{ ----------------------------------------------------------- the tests -- }

procedure TestTranslation;
var
  Arr: TJsonArray;
  P: string;
begin
  AssertEq(ACPToolKind('read_file'), 'read', 'read_file reads');
  AssertEq(ACPToolKind('write_file'), 'edit', 'write_file edits');
  AssertEq(ACPToolKind('apply_patch'), 'edit', 'apply_patch edits');
  AssertEq(ACPToolKind('shell_exec'), 'execute', 'shell_exec executes');
  AssertEq(ACPToolKind('grep_files'), 'search', 'grep_files searches');
  AssertEq(ACPToolKind('memory_search'), 'search', 'any *_search searches');
  AssertEq(ACPToolKind('web_fetch'), 'fetch', 'web_fetch fetches');
  AssertEq(ACPToolKind('todo_write'), 'think', 'the checklist is thinking');
  AssertEq(ACPToolKind('desktop'), 'other', 'the rest is other');

  AssertEq(ACPToolTitle('shell_exec', '{"command":"ls -la\nwc"}'), 'ls -la wc',
           'a command is its own title, on one line');
  AssertEq(ACPToolTitle('read_file', '{"path":"src/a.pas"}'), 'Read src/a.pas', 'verb + path');
  AssertEq(ACPToolTitle('kb_get', '{"query":"q"}'), 'kb_get q', 'unknown tools: name + main argument');
  AssertEq(ACPToolTitle('todo_write', '{"checklist":"- [ ] a"}'), 'Update the checklist',
           'the checklist call');
  AssertEq(ACPToolTitle('list_dir', 'not json'), 'List', 'bad arguments still give a title');

  AssertEq(ACPPlanEntries('- [ ] write it' + LineEnding + '- [x] read it' + LineEnding +
                          '* [~] run it' + LineEnding + 'notes here' + LineEnding + '- [ ]'),
    '[{"content":"write it","priority":"medium","status":"pending"},' +
    '{"content":"read it","priority":"medium","status":"completed"},' +
    '{"content":"run it","priority":"medium","status":"in_progress"}]',
    'checklist lines become plan entries; the rest is ignored');
  AssertEq(ACPPlanEntries(''), '[]', 'an empty checklist is an empty plan');

  Arr := TJsonArray.Parse('[{"type":"text","text":"fix this"},' +
    '{"type":"resource_link","uri":"file:///p/a.pas","name":"a.pas"},' +
    '{"type":"resource","resource":{"uri":"file:///p/b.pas","text":"unit b;"}},' +
    '{"type":"image","data":"xx","mimeType":"image/png"}]');
  try
    P := ACPPromptText(Arr);
  finally
    Arr.Free;
  end;
  AssertTrue(Pos('fix this', P) = 1, 'text first, as written');
  AssertTrue(Pos('@a.pas (file:///p/a.pas)', P) > 0, 'a link is a reference');
  AssertTrue(Pos('<context uri="file:///p/b.pas">', P) > 0, 'embedded text is context');
  AssertTrue(Pos('unit b;', P) > 0, 'with its text');
  AssertTrue(Pos('image content left out', P) > 0, 'an image is named, not dropped silently');

  {$IFNDEF MSWINDOWS}
  AssertEq(ACPToolPath('{"path":"src/a.pas"}', '/proj'), '/proj/src/a.pas', 'relative to cwd');
  AssertEq(ACPToolPath('{"path":"/etc/x"}', '/proj'), '/etc/x', 'absolute stays');
  {$ENDIF}
  AssertEq(ACPToolPath('{"command":"ls"}', '/proj'), '', 'no path, no location');
  AssertTrue(Pos('"currentModeId":"plan"', ACPModesJSON(pmPlan)) > 0, 'the current mode');
  AssertTrue(Pos('"id":"space"', ACPModesJSON(pmBuild)) > 0, 'all four modes');
end;

procedure TestWire;
var
  N: Integer;
begin
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/tmp","mcpServers":[]}}');
  AssertTrue(Cap.Has('"id":1,"error":{"code":-32600', N), 'nothing before initialize');
  N := Cap.Count;
  Send('not json at all');
  AssertTrue(Cap.Has('"id":null,"error":{"code":-32700', N), 'a parse error answers id null');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":7}}');
  AssertTrue(Cap.Has('"id":"init-1","result":{"protocolVersion":1', N),
             'a string id is echoed as a string; version 1 whatever was asked');
  AssertTrue(Cap.Has('"loadSession":true', N), 'loadSession advertised');
  AssertTrue(Cap.Has('"embeddedContext":true', N), 'embedded context advertised');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":2,"method":"fs/frobnicate","params":{}}');
  AssertTrue(Cap.Has('"id":2,"error":{"code":-32601', N), 'unknown method');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","method":"something/else","params":{}}');
  Sleep(50);
  AssertTrue(Cap.Count = N, 'an unknown notification gets no answer');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":3,"method":"session/new","params":{"cwd":"relative","mcpServers":[]}}');
  AssertTrue(Cap.Has('"id":3,"error":{"code":-32602', N), 'cwd must be absolute');
  N := Cap.Count;
  Send(Prompt('4', 'nope', 'x'));
  AssertTrue(Cap.Has('"id":4,"error":{"code":-32002', N), 'unknown session');
  AssertTrue(Cap.Has('"data":{"sessionId":"nope"}', N), 'naming it in data');
end;

procedure TestTurn;
var
  N, iCall, iUpd, iDone: Integer;
  Dir: string;
begin
  Dir := ExcludeTrailingPathDelimiter(Host.Dir);
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":10,"method":"session/new","params":{"cwd":"' + Dir + '","mcpServers":[]}}');
  AssertTrue(Cap.Has('"id":10,"result":{"sessionId":"sess-1","modes":{"currentModeId":"build"', N),
             'session/new: id and modes');
  N := Cap.Count;
  Send(Prompt('11', 'sess-1', 'basic'));
  iDone := Cap.WaitFor('"id":11,"result"', N);
  AssertTrue(iDone >= 0, 'the turn answers');
  AssertTrue(Pos('"stopReason":"end_turn"', Cap.Line(iDone)) > 0, 'end_turn');
  AssertTrue(Cap.Has('"agent_message_chunk","content":{"type":"text","text":"hello"}', N), 'text');
  AssertTrue(Cap.Has('"text":"\n\ndone"', N) or Cap.Has('"text":"\r\n\r\ndone"', N),
             'a second round of text is a new paragraph');
  iCall := Cap.WaitFor('"sessionUpdate":"tool_call","toolCallId":"call_1"', N, 100);
  iUpd := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"call_1"', N, 100);
  AssertTrue((iCall >= 0) and (iUpd > iCall), 'a call, then its update');
  AssertTrue(Pos('"kind":"edit"', Cap.Line(iCall)) > 0, 'write_file is an edit');
  AssertTrue(Pos('"locations":[{"path":"' + JsonEscape(Dir + PathDelim + 'edit.txt') + '"}]',
                 Cap.Line(iCall)) > 0, 'located in the session''s cwd');
  AssertTrue(Pos('"rawInput":{"path":"edit.txt","content":"new"}', Cap.Line(iCall)) > 0,
             'raw arguments as JSON');
  AssertTrue(Pos('"type":"diff"', Cap.Line(iUpd)) > 0, 'an edit carries a diff');
  AssertTrue((Pos('"oldText":"old\n"', Cap.Line(iUpd)) > 0) and
             (Pos('"newText":"new\n"', Cap.Line(iUpd)) > 0), 'of the file before and after');
  iUpd := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"call_2"', N, 100);
  AssertTrue((iUpd >= 0) and (Pos('"type":"diff"', Cap.Line(iUpd)) = 0),
             'a read that names a file carries no diff');
  iUpd := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"call_3"', N, 100);
  AssertTrue((iUpd >= 0) and (Pos('"status":"failed"', Cap.Line(iUpd)) > 0) and
             (Pos('command failed', Cap.Line(iUpd)) > 0), 'a failed call says so');
  iUpd := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"call_4"', N, 100);
  AssertTrue((iUpd >= 0) and (Pos('"status":"failed"', Cap.Line(iUpd)) > 0),
             'a call a gate refused is failed, not completed');
end;

procedure TestAsk;
var
  N, iAsk, iDone: Integer;
  L, Id: string;
  O: TJsonObject;
begin
  N := Cap.Count;
  Host.Asked := False;
  Send(Prompt('20', 'sess-1', 'ask'));
  iAsk := Cap.WaitFor('"method":"session/request_permission"', N);
  AssertTrue(iAsk >= 0, 'an ask goes to the client');
  L := Cap.Line(iAsk);
  AssertTrue(Pos('"toolCallId":"call_5"', L) > 0, 'about the announced call');
  AssertTrue(Pos('a rule says ask', L) > 0, 'with the reason');
  AssertTrue(Pos('"kind":"allow_always"', L) > 0, 'offering once, session and no');
  O := TJsonObject.Parse(L);
  try
    Id := IntToStr(O.GetInt('id', -1));
  finally
    O.Free;
  end;
  Send('{"jsonrpc":"2.0","id":' + Id + ',"result":{"outcome":{"outcome":"selected",' +
       '"optionId":"allow_session"}}}');
  iDone := Cap.WaitFor('"id":20,"result"', N);
  AssertTrue(iDone >= 0, 'the turn finishes once answered');
  AssertTrue(Host.Asked and (Host.Answer = aaAllowSession), 'the host got allow-for-the-session');

  { An answer that is not a selected allow is a no. }
  N := Cap.Count;
  Send(Prompt('21', 'sess-1', 'ask'));
  iAsk := Cap.WaitFor('"method":"session/request_permission"', N);
  O := TJsonObject.Parse(Cap.Line(iAsk));
  try
    Id := IntToStr(O.GetInt('id', -1));
  finally
    O.Free;
  end;
  Send('{"jsonrpc":"2.0","id":' + Id + ',"result":{"outcome":{"outcome":"selected",' +
       '"optionId":"something_we_never_offered"}}}');
  AssertTrue(Cap.WaitFor('"id":21,"result"', N) >= 0, 'answered');
  AssertTrue(Host.Answer = aaDeny, 'an option we never offered is a no');

  { No answer within the limit is a no, and the editor is told to drop
    the prompt; an answer after that is ignored. }
  Agent.AskTimeoutMs := 300;
  try
    N := Cap.Count;
    Host.Answer := aaAllowOnce;
    Send(Prompt('22', 'sess-1', 'ask'));
    iAsk := Cap.WaitFor('"method":"session/request_permission"', N);
    O := TJsonObject.Parse(Cap.Line(iAsk));
    try
      Id := IntToStr(O.GetInt('id', -1));
    finally
      O.Free;
    end;
    AssertTrue(Cap.WaitFor('"id":22,"result"', N) >= 0, 'the turn goes on after the limit');
    AssertTrue(Host.Answer = aaDeny, 'unanswered is a no');
    AssertTrue(Cap.Has('"method":"$/cancel_request","params":{"requestId":' + Id + '}', N),
               'and the editor is told the prompt is no longer wanted');
    N := Cap.Count;
    Send('{"jsonrpc":"2.0","id":' + Id + ',"result":{"outcome":{"outcome":"selected",' +
         '"optionId":"allow_once"}}}');
    Sleep(50);
    AssertTrue(Cap.Count = N, 'a late answer is ignored');
  finally
    Agent.AskTimeoutMs := INFINITE;
  end;
end;

procedure TestCancel;
var
  N, iAsk, iDone: Integer;
begin
  { A pending ask is released by the cancel itself. }
  N := Cap.Count;
  Host.Asked := False;
  Send(Prompt('30', 'sess-1', 'ask'));
  iAsk := Cap.WaitFor('"method":"session/request_permission"', N);
  AssertTrue(iAsk >= 0, 'the ask is out');
  Send('{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess-1"}}');
  iDone := Cap.WaitFor('"id":30,"result"', N);
  AssertTrue(iDone >= 0, 'the turn ends without the client answering the ask');
  AssertTrue(Pos('"stopReason":"cancelled"', Cap.Line(iDone)) > 0, 'cancelled');
  AssertTrue(Host.Asked and (Host.Answer = aaDeny), 'and the ask was a no');

  { A busy session refuses a second prompt; cancel ends the first. }
  N := Cap.Count;
  Send(Prompt('31', 'sess-1', 'wait'));
  Sleep(50);
  Send(Prompt('32', 'sess-1', 'basic'));
  AssertTrue(Cap.WaitFor('"id":32,"error":{"code":-32600', N, 1000) >= 0,
             'one turn at a time per session');
  Send('{"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"sess-1"}}');
  iDone := Cap.WaitFor('"id":31,"result"', N);
  AssertTrue((iDone >= 0) and (Pos('"stopReason":"cancelled"', Cap.Line(iDone)) > 0),
             'the running turn answers cancelled');
  { And the session works again. }
  N := Cap.Count;
  Send(Prompt('33', 'sess-1', 'basic'));
  iDone := Cap.WaitFor('"id":33,"result"', N);
  AssertTrue((iDone >= 0) and (Pos('"end_turn"', Cap.Line(iDone)) > 0),
             'a cancel does not stick to the next turn');
end;

procedure TestModesAndErrors;
var
  N, iDone: Integer;
begin
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":40,"method":"session/set_mode","params":{"sessionId":"sess-1","modeId":"improve"}}');
  AssertTrue(Cap.Has('"id":40,"result":{}', N), 'set_mode');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":41,"method":"session/set_mode","params":{"sessionId":"sess-1","modeId":"i"}}');
  AssertTrue(Cap.Has('"id":41,"error":{"code":-32602', N), 'an alias is not an id');
  N := Cap.Count;
  Send(Prompt('42', 'sess-1', 'boom'));
  iDone := Cap.WaitFor('"id":42,"error"', N);
  AssertTrue(iDone >= 0, 'a host that raises gives an error response');
  AssertTrue(Pos('the model went away', Cap.Line(iDone)) > 0, 'with its message');
  N := Cap.Count;
  Send(Prompt('43', 'sess-1', 'basic'));
  AssertTrue(Cap.WaitFor('"id":43,"result"', N) >= 0, 'and the agent carries on');
end;

procedure TestLoad;
var
  N, iUser, iAgent, iCall, iUpd, iResp: Integer;
begin
  SetLength(Host.History, 7);
  Host.History[0] := MakeMessage(mrSystem, 'a note the user never typed');
  Host.History[1] := MakeMessage(mrUser, 'read a' + LineEnding + LineEnding +
                                 '[current date/time: Thu 2026-11-12 10:00:00 UTC+00:00 (2026-11-12T10:00:00Z)]');
  Host.History[2] := MakeMessage(mrAssistant, 'reading');
  SetLength(Host.History[2].ToolCalls, 1);
  Host.History[2].ToolCalls[0].Id := 't1';
  Host.History[2].ToolCalls[0].Func.Name := 'read_file';
  Host.History[2].ToolCalls[0].Func.Arguments := '{"path":"a"}';
  Host.History[3] := MakeMessage(mrTool, 'contents of a');
  Host.History[3].ToolCallId := 't1';
  Host.History[4] := MakeMessage(mrAssistant, '');
  SetLength(Host.History[4].ToolCalls, 1);
  Host.History[4].ToolCalls[0].Id := 't2';
  Host.History[4].ToolCalls[0].Func.Name := 'write_file';
  Host.History[4].ToolCalls[0].Func.Arguments := '{"path":"b"}';
  Host.History[5] := MakeMessage(mrTool, 'refused: tool "write_file" needs build mode');
  Host.History[5].ToolCallId := 't2';
  { A call its turn never finished: no result recorded. }
  Host.History[6] := MakeMessage(mrAssistant, '');
  SetLength(Host.History[6].ToolCalls, 1);
  Host.History[6].ToolCalls[0].Id := 't3';
  Host.History[6].ToolCalls[0].Func.Name := 'shell_exec';
  Host.History[6].ToolCalls[0].Func.Arguments := '{"command":"sleep 9"}';
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":50,"method":"session/load","params":{"sessionId":"saved",' +
       '"cwd":"/tmp","mcpServers":[]}}');
  iResp := Cap.WaitFor('"id":50,"result":{"modes"', N);
  iUser := Cap.WaitFor('"user_message_chunk"', N, 100);
  iAgent := Cap.WaitFor('"agent_message_chunk","content":{"type":"text","text":"reading"}', N, 100);
  iCall := Cap.WaitFor('"tool_call","toolCallId":"t1"', N, 100);
  iUpd := Cap.WaitFor('"tool_call_update","toolCallId":"t1"', N, 100);
  AssertTrue(iResp >= 0, 'load answers with the modes');
  AssertTrue((iUser >= 0) and (iUser < iAgent) and (iAgent < iCall) and (iCall < iUpd) and
             (iUpd < iResp), 'the history is replayed in order, before the response');
  AssertTrue(Pos('"text":"read a"', Cap.Line(iUser)) > 0, 'without the turn clock');
  AssertTrue(not Cap.Has('never typed', N), 'system notes are not replayed');
  AssertTrue(Pos('contents of a', Cap.Line(iUpd)) > 0, 'with the tool''s result');
  iUpd := Cap.WaitFor('"tool_call_update","toolCallId":"t2"', N, 100);
  AssertTrue((iUpd >= 0) and (Pos('"status":"failed"', Cap.Line(iUpd)) > 0),
             'a refused call replays as failed, as it was shown live');
  { Announced with the status it ended with: never done first, failed after. }
  AssertTrue(Pos('"status":"completed"', Cap.Line(iCall)) > 0, 'a call that ran is announced completed');
  iCall := Cap.WaitFor('"tool_call","toolCallId":"t2"', N, 100);
  AssertTrue((iCall >= 0) and (Pos('"status":"failed"', Cap.Line(iCall)) > 0),
             'a refused call is announced failed, not completed');
  iCall := Cap.WaitFor('"tool_call","toolCallId":"t3"', N, 100);
  iUpd := Cap.WaitFor('"tool_call_update","toolCallId":"t3"', N, 100);
  AssertTrue((iCall >= 0) and (Pos('"status":"failed"', Cap.Line(iCall)) > 0) and
             (iUpd > iCall) and (Pos('ended before this call finished', Cap.Line(iUpd)) > 0),
             'a call with no result replays failed, as it was closed live');
  AssertTrue(iUpd < iResp, 'all before the response');
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":51,"method":"session/load","params":{"sessionId":"gone",' +
       '"cwd":"/tmp","mcpServers":[]}}');
  AssertTrue(Cap.Has('"id":51,"error":{"code":-32002', N), 'a missing session is not found');
  N := Cap.Count;
  Send(Prompt('52', 'saved', 'basic'));
  AssertTrue(Cap.WaitFor('"id":52,"result"', N) >= 0, 'a loaded session takes prompts');
end;

procedure TestOpenCallsClose;
var
  N, iB, iDone, iC: Integer;
begin
  N := Cap.Count;
  Send(Prompt('60', 'sess-1', 'orphan'));
  iDone := Cap.WaitFor('"id":60,"result"', N);
  AssertTrue(iDone >= 0, 'the turn answers');
  { call ids so far: call_1..call_4 (basic), call_5..call_7 (asks), call_8..
    in later turns -- find b's id from its announcement instead. }
  iB := Cap.WaitFor('"rawInput":{"command":"b"}', N, 100);
  AssertTrue(iB >= 0, 'b was announced');
  iC := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"' +
    Copy(Cap.Line(iB), Pos('"toolCallId":"', Cap.Line(iB)) + 14,
         Pos('","title"', Cap.Line(iB)) - Pos('"toolCallId":"', Cap.Line(iB)) - 14) + '"', N, 100);
  AssertTrue((iC >= 0) and (iC < iDone), 'b gets an update before the turn answers');
  AssertTrue(Pos('"status":"failed"', Cap.Line(iC)) > 0, 'as failed');
  AssertTrue(Pos('ended before this call finished', Cap.Line(iC)) > 0, 'saying why');
  { The next turn's result lands on its own call, not on b's. }
  N := Cap.Count;
  Send(Prompt('61', 'sess-1', 'next'));
  AssertTrue(Cap.WaitFor('"id":61,"result"', N) >= 0, 'the next turn answers');
  iC := Cap.WaitFor('"rawInput":{"command":"c"}', N, 100);
  AssertTrue(iC >= 0, 'c was announced');
  iC := Cap.WaitFor('"sessionUpdate":"tool_call_update","toolCallId":"' +
    Copy(Cap.Line(iC), Pos('"toolCallId":"', Cap.Line(iC)) + 14,
         Pos('","title"', Cap.Line(iC)) - Pos('"toolCallId":"', Cap.Line(iC)) - 14) + '"', N, 100);
  AssertTrue((iC >= 0) and (Pos('c done', Cap.Line(iC)) > 0),
             'c''s result goes to c''s call');
end;

procedure TestUtf8Cut;
var
  N, iUpd: Integer;
  L: string;
  B: TBytes;
begin
  N := Cap.Count;
  Send(Prompt('70', 'sess-1', 'utf8'));
  AssertTrue(Cap.WaitFor('"id":70,"result"', N) >= 0, 'the turn answers');
  iUpd := Cap.WaitFor('shortened for display', N, 100);
  AssertTrue(iUpd >= 0, 'the long result is cut for display');
  L := Cap.Line(iUpd);
  SetLength(B, Length(L));
  if Length(L) > 0 then Move(L[1], B[0], Length(L));
  AssertTrue(BytesAreValidUTF8(B), 'and the cut line is still valid UTF-8');
  AssertTrue(Utf8SafeTruncate('a' + #$C3#$A9, 2) = 'a', 'the cut backs off a split character');
  AssertTrue(Utf8SafeTruncate('a' + #$C3#$A9, 3) = 'a' + #$C3#$A9, 'and keeps a whole one');
end;

procedure TestTextDeltas;
var
  N, iDone, i: Integer;
  Got: string;
  O, U, C: TJsonObject;
begin
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":10,"method":"session/new","params":{"cwd":"' +
       ExcludeTrailingPathDelimiter(Host.Dir) + '","mcpServers":[]}}');
  iDone := Cap.WaitFor('"id":10,"result"', N);
  O := TJsonObject.Parse(Cap.Line(iDone));
  try
    C := O.ChildObject('result');
    try
      Got := C.GetStr('sessionId', '');
    finally
      C.Free;
    end;
  finally
    O.Free;
  end;
  N := Cap.Count;
  Send(Prompt('80', Got, 'deltas'));
  iDone := Cap.WaitFor('"id":80,"result"', N);
  AssertTrue(iDone >= 0, 'the turn answers');
  Got := '';
  for i := N to iDone - 1 do
    if Pos('"agent_message_chunk"', Cap.Line(i)) > 0 then
    begin
      O := TJsonObject.Parse(Cap.Line(i));
      try
        U := O.ChildObject('params');
        try
          C := U.ChildObject('update');
          try
            U.Free;
            U := C.ChildObject('content');
            Got := Got + '[' + U.GetStr('text', '') + ']';
          finally
            C.Free;
          end;
        finally
          U.Free;
        end;
      finally
        O.Free;
      end;
    end;
  AssertTrue((Got = '[Hel][lo][' + #10#10 + 'Next]') or (Got = '[Hel][lo][' + #13#10#13#10 + 'Next]'),
             'pieces as they come, one chunk each; a new round opens a paragraph (got ' + Got + ')');
end;

procedure TestNullId;
var
  N: Integer;
begin
  N := Cap.Count;
  Send('{"jsonrpc":"2.0","id":null,"method":"fs/frobnicate","params":{}}');
  AssertTrue(Cap.Has('"id":null,"error":{"code":-32601', N), 'a null id is echoed as null');
end;

procedure RemoveScratch(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Name <> '.') and (SR.Name <> '..') then
        DeleteFile(IncludeTrailingPathDelimiter(Dir) + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

procedure TestStdoutIsJSON;
var
  i: Integer;
  O: TJsonObject;
begin
  for i := 0 to Cap.Count - 1 do
  begin
    try
      O := TJsonObject.Parse(Cap.Line(i));
    except
      Fail_('line ' + IntToStr(i) + ' is not JSON: ' + Copy(Cap.Line(i), 1, 120));
      Exit;
    end;
    try
      AssertEq(O.GetStr('jsonrpc', ''), '2.0', 'every line is JSON-RPC 2.0');
    finally
      O.Free;
    end;
  end;
end;

begin
  Cap := TCapture.Create;
  Host := TFakeHost.Create;
  Host.Dir := IncludeTrailingPathDelimiter(GetTempDir(False)) + 'pasclaw-acp-tests-' +
              IntToStr(GetProcessID);
  ScratchDir := Host.Dir;
  ForceDirectories(Host.Dir);
  Agent := TACPAgent.Create(Host, Cap.WriteLine, 'test');
  try
    TestTranslation;
    WriteLn('  ok: kinds, titles, plans, prompts, paths and modes translate');
    TestWire;
    WriteLn('  ok: ids echo as they came; parse errors, init order, unknown methods, bad cwd');
    TestTurn;
    WriteLn('  ok: a turn: text, calls before their updates, a diff for an edit only');
    TestAsk;
    WriteLn('  ok: an ask goes out and comes back; anything but a selected allow is a no; the limit');
    TestCancel;
    WriteLn('  ok: cancel releases a pending ask, answers cancelled, one turn per session');
    TestModesAndErrors;
    WriteLn('  ok: set_mode takes only mode ids; a raising host is an error, not a crash');
    TestLoad;
    WriteLn('  ok: load replays the conversation in order before answering');
    TestOpenCallsClose;
    WriteLn('  ok: a call left open is shown failed before the answer, and takes no later result');
    TestUtf8Cut;
    WriteLn('  ok: a result cut for display stays valid UTF-8');
    TestNullId;
    WriteLn('  ok: a null id is echoed as null');
    TestTextDeltas;
    WriteLn('  ok: streamed text goes out piece by piece, a paragraph between rounds');
    TestStdoutIsJSON;
    WriteLn('  ok: every line written is JSON-RPC 2.0');
    Agent.Shutdown;
  finally
    Agent.Free;
    RemoveScratch(Host.Dir);
    Host.Free;
    Cap.Free;
  end;
  AssertTrue(not DirectoryExists(ScratchDir), 'the scratch project is removed');
  WriteLn('PASS');
end.
