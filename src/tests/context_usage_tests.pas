program context_usage_tests;
{ The context breakdown (PasClaw.Agent.ContextUsage, /v1/context).

  - BuildSystemPromptSections joins to exactly BuildSystemPrompt, in every
    mode, with and without tools, and never lists an empty section;
  - prompt sections land in the right categories, MCP tools under their
    server (longest configured prefix first);
  - the report adds up: categories to the total, sections to the system
    figure, tools and messages to theirs;
  - a caller's own system message is counted as the system prompt;
  - the window is the given one, else the compaction threshold, else
    unknown;
  - CompactMeasure is the number NeedsCompact triggers on.

  The e2e half (context_usage_e2e.py) checks the report against the
  request a real gateway sends the model. }

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Tokenizer,
  PasClaw.Providers.Types,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Prompt,
  PasClaw.Agent.Compact,
  PasClaw.Agent.ContextUsage;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ', Msg);
    Inc(Failures);
  end;
end;

procedure CheckEq(Got, Want: Int64; const Msg: string);
begin
  Check(Got = Want, Format('%s (got %d, want %d)', [Msg, Got, Want]));
end;

function Obj(Parent: TJsonObject; const Key: string): TJsonObject;
begin
  Result := Parent.ChildObject(Key);
  if Result = nil then
  begin
    WriteLn('FAIL: missing object ', Key);
    Halt(1);
  end;
end;

function IntAt(Parent: TJsonObject; const Path: array of string): Int64;
var
  i: Integer;
  Cur, Next: TJsonObject;
begin
  Cur := Parent;
  for i := 0 to High(Path) - 1 do
  begin
    Next := Obj(Cur, Path[i]);
    if Cur <> Parent then Cur.Free;
    Cur := Next;
  end;
  Result := Cur.GetInt(Path[High(Path)], -1);
  if Cur <> Parent then Cur.Free;
end;

function CategoryTokens(Report: TJsonObject; const Id: string): Int64;
var
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  Result := -1;
  Arr := Report.ChildArray('categories');
  try
    for i := 0 to Arr.Count - 1 do
    begin
      Item := Arr.ItemObject(i);
      try
        if Item.GetStr('id', '') = Id then Result := Item.GetInt('tokens', -1);
      finally
        Item.Free;
      end;
    end;
  finally
    Arr.Free;
  end;
end;

function Section(const Id, Text: string): TPromptSection;
begin
  Result.Id := Id;
  Result.Title := Id;
  Result.Text := Text;
end;

function Tool(const Name, Schema: string): TToolDefinition;
begin
  Result.Name := Name;
  Result.Description := 'does ' + Name;
  Result.Schema := Schema;
end;

{ ---- the prompt split ---- }

procedure TestSectionsJoinToPrompt;
var
  Cfg: TConfig;
  M: TPasClawMode;
  T: Boolean;
  S: TPromptSectionArray;
  i: Integer;
  Ids: string;
begin
  Cfg := TConfig.Create;
  try
    for M := Low(TPasClawMode) to High(TPasClawMode) do
      for T := False to True do
      begin
        S := BuildSystemPromptSections(Cfg, '  house rule  ', T, '', M);
        Check(JoinPromptSections(S) = BuildSystemPrompt(Cfg, '  house rule  ', T, '', M),
              Format('sections join to the prompt (mode %d, tools %s)',
                     [Ord(M), BoolToStr(T, True)]));
        Ids := '';
        for i := 0 to High(S) do
        begin
          Check(Trim(S[i].Text) <> '', 'no empty section: ' + S[i].Id);
          Check(S[i].Title <> '', 'every section has a title: ' + S[i].Id);
          Ids := Ids + S[i].Id + ',';
        end;
        Check(Pos('identity,', Ids) > 0, 'identity section present');
        Check(Pos('rules,', Ids) > 0, 'rules section present');
        Check(S[High(S)].Id = 'user', 'the caller''s addition is the last section');
        Check(S[High(S)].Text = 'house rule', 'the caller''s addition is trimmed');
        Check((Pos('skills,', Ids) > 0) = T, 'skill catalog only with tools');
        Check((S[0].Id = 'mode') = (M <> pmBuild), 'a mode block leads in a non-build mode');
      end;
    S := BuildSystemPromptSections(Cfg, '', True, '', pmBuild);
    Check(S[High(S)].Id <> 'user', 'no caller section without an addition');
    Check(JoinPromptSections(nil) = '', 'no sections, no prompt');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: sections join to the prompt in every mode');
end;

{ ---- classification ---- }

procedure TestClassification;
var
  Servers: TStringArray;
begin
  Check(PromptSectionGroup('memory') = 'memory', 'memory -> memory');
  Check(PromptSectionGroup('facts') = 'memory', 'facts -> memory');
  Check(PromptSectionGroup('project_rules') = 'project', 'AGENTS.md -> project');
  Check(PromptSectionGroup('instructions') = 'project', 'instruction files -> project');
  Check(PromptSectionGroup('skills') = 'skills', 'skills -> skills');
  Check(PromptSectionGroup('identity') = 'system', 'identity -> system');
  Check(PromptSectionGroup('working_state') = 'system', 'anything else -> system');

  SetLength(Servers, 2);
  Servers[0] := 'git';
  Servers[1] := 'git__hub';
  Check(ToolServerOf('git__hub__list', Servers) = 'git__hub',
        'the longest configured server prefix wins');
  Check(ToolServerOf('git__log', Servers) = 'git', 'a configured server');
  Check(ToolServerOf('slack__post', Servers) = 'slack',
        'a server not in the config is still the part before __');
  Check(ToolServerOf('read_file', Servers) = '', 'a built-in tool has no server');
  Check(ToolServerOf('__odd', Servers) = '', 'a leading __ is not a server');
  Check(ToolServerOf('git__', Servers) = 'git', 'bare prefix falls back to before __');
  WriteLn('  ok: sections and tools are filed in the right categories');
end;

procedure TestUnitCosts;
var
  M: TMessage;
  T: TToolDefinition;
begin
  M := MakeMessage(mrUser, StringOfChar('x', 40));
  CheckEq(MessageTokens(M), 10 + 4, 'a message is its text plus the 4-token envelope');
  M := MakeMessage(mrAssistant, '');
  SetLength(M.ToolCalls, 1);
  M.ToolCalls[0].Func.Name := 'read_file';                 { 9 chars -> 3 }
  M.ToolCalls[0].Func.Arguments := '{"path":"a.txt"}';     { 16 chars -> 4 }
  CheckEq(MessageTokens(M), 0 + 4 + 3 + 4 + 4, 'tool calls count their name and arguments');

  T := Tool('read_file', '{"type":"object"}');
  CheckEq(ToolDefTokens(T), EstimateTokens(
    '{"type":"function","function":{"name":"read_file","description":"does read_file",' +
    '"parameters":{"type":"object"}}}'), 'a tool costs its wire form');
  T.Schema := '';
  Check(ToolDefTokens(T) > 0, 'a tool with no schema still costs its name');
  WriteLn('  ok: messages and tools cost what they send');
end;

{ ---- the report ---- }

function SampleInput: TContextUsageInput;
begin
  Result := Default(TContextUsageInput);
  Result.Model := 'm';
  Result.Mode := 'build';
  SetLength(Result.Sections, 3);
  Result.Sections[0] := Section('identity', StringOfChar('i', 400));
  Result.Sections[1] := Section('memory', StringOfChar('m', 200));
  Result.Sections[2] := Section('skills', StringOfChar('s', 120));
  Result.ToolsEnabled := True;
  SetLength(Result.Tools, 2);
  Result.Tools[0] := Tool('read_file', '{"type":"object","properties":{"path":{"type":"string"}}}');
  Result.Tools[1] := Tool('stub__echo', '{"type":"object"}');
  SetLength(Result.MCPServers, 1);
  Result.MCPServers[0] := 'stub';
  SetLength(Result.Deferred, 2);
  Result.Deferred[0] := 'db_query';
  Result.Deferred[1] := 'spawn';
  SetLength(Result.Messages, 3);
  Result.Messages[0] := MakeMessage(mrUser, 'hello');
  Result.Messages[1] := MakeMessage(mrAssistant, StringOfChar('a', 800));
  Result.Messages[2] := MakeMessage(mrTool, 'ok');
  Result.FromSession := 1;
  Result.CompactEnabled := True;
  Result.CompactThreshold := 1000;
  Result.CompactCounted := 321;
end;

procedure TestReportAddsUp;
var
  In_: TContextUsageInput;
  R, Sys, Tools, Msgs, Item: TJsonObject;
  Arr: TJsonArray;
  Sum, i: Integer;
  Total: Int64;
begin
  In_ := SampleInput;
  R := BuildContextUsage(In_);
  try
    Total := R.GetInt('total_tokens', -1);
    Sum := 0;
    Arr := R.ChildArray('categories');
    try
      CheckEq(Arr.Count, 7, 'seven categories');
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        Inc(Sum, Item.GetInt('tokens', 0));
        Item.Free;
      end;
    finally
      Arr.Free;
    end;
    CheckEq(Sum, Total, 'the categories add up to the total');
    CheckEq(IntAt(R, ['system', 'tokens']) + IntAt(R, ['tools', 'tokens']) +
            IntAt(R, ['messages', 'tokens']), Total, 'total = system + tools + messages');

    { First section uncharged, later ones carry the joiner. }
    CheckEq(CategoryTokens(R, 'system'), 100, 'identity is the system category');
    CheckEq(CategoryTokens(R, 'memory'),
            EstimateTokens(sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak +
                           StringOfChar('m', 200)), 'memory carries its joiner');
    Check(CategoryTokens(R, 'skills') > 30, 'skills category');
    CheckEq(CategoryTokens(R, 'project'), 0, 'no project rules');
    CheckEq(CategoryTokens(R, 'mcp'), ToolDefTokens(In_.Tools[1]), 'the MCP tool is MCP');
    CheckEq(CategoryTokens(R, 'tools'), ToolDefTokens(In_.Tools[0]), 'the built-in is built-in');
    CheckEq(CategoryTokens(R, 'messages'), (2 + 4) + (200 + 4) + (1 + 4),
            'messages are their texts and envelopes');

    Sys := Obj(R, 'system');
    try
      Check(Sys.GetStr('source', '') = 'pasclaw', 'PasClaw composed the prompt');
      Arr := Sys.ChildArray('sections');
      try
        CheckEq(Arr.Count, 3, 'three sections');
        Item := Arr.ItemObject(1);
        Check((Item.GetStr('id', '') = 'memory') and (Item.GetStr('group', '') = 'memory'),
              'memory section is filed under memory');
        Check(not Item.Has('text'), 'no text unless asked');
        Item.Free;
      finally
        Arr.Free;
      end;
    finally
      Sys.Free;
    end;

    Tools := Obj(R, 'tools');
    try
      CheckEq(Tools.GetInt('count', -1), 2, 'two tools offered');
      CheckEq(Tools.GetInt('deferred', -1), 2, 'two deferred');
      Arr := Tools.ChildArray('deferred_names');
      Check((Arr <> nil) and (Arr.ItemStr(1, '') = 'spawn'), 'deferred names listed');
      Arr.Free;
      Arr := Tools.ChildArray('items');
      Item := Arr.ItemObject(1);
      Check(Item.GetStr('server', '') = 'stub', 'the MCP tool names its server');
      Item.Free;
      Arr.Free;
    finally
      Tools.Free;
    end;

    Msgs := Obj(R, 'messages');
    try
      CheckEq(Msgs.GetInt('count', -1), 3, 'three messages');
      CheckEq(Msgs.GetInt('from_session', -1), 1, 'one from the session');
      CheckEq(IntAt(Msgs, ['by_role', 'assistant', 'tokens']), 204, 'assistant tokens');
      CheckEq(IntAt(Msgs, ['by_role', 'tool', 'count']), 1, 'one tool result');
      Arr := Msgs.ChildArray('largest');
      CheckEq(Arr.Count, 3, 'every message ranks when there are fewer than five');
      Item := Arr.ItemObject(0);
      CheckEq(Item.GetInt('index', -1), 1, 'the long assistant reply ranks first');
      Check(Length(Item.GetStr('preview', '')) <= 103, 'the preview is short');
      Item.Free;
      Item := Arr.ItemObject(2);
      CheckEq(Item.GetInt('index', -1), 2, 'the smallest ranks last');
      Item.Free;
      Arr.Free;
    finally
      Msgs.Free;
    end;

    CheckEq(IntAt(R, ['compaction', 'counted_tokens']), 321, 'compaction measure passed on');
    CheckEq(IntAt(R, ['compaction', 'remaining_tokens']), 1000 - 321, 'room before compaction');
  finally
    R.Free;
  end;
  WriteLn('  ok: the report adds up');
end;

procedure TestWindow;
var
  In_: TContextUsageInput;
  R, W: TJsonObject;
  Total: Int64;
begin
  In_ := SampleInput;
  In_.ContextWindow := 200000;
  In_.WindowSource := 'config';
  R := BuildContextUsage(In_);
  W := Obj(R, 'window');
  CheckEq(W.GetInt('tokens', -1), 200000, 'the given window');
  Check(W.GetStr('source', '') = 'config', 'its source');
  Total := R.GetInt('total_tokens', 0);
  CheckEq(R.GetInt('free_tokens', -1), 200000 - Total, 'free = window - total');
  W.Free;
  R.Free;

  In_.ContextWindow := 0;
  R := BuildContextUsage(In_);
  W := Obj(R, 'window');
  CheckEq(W.GetInt('tokens', -1), 1000, 'no window: the compaction threshold');
  Check(W.GetStr('source', '') = 'compaction', 'source says so');
  Total := R.GetInt('total_tokens', 0);
  Check(Total < 1000, 'the sample fits under the threshold');
  CheckEq(R.GetInt('free_tokens', -1), 1000 - Total, 'under the threshold: the rest is free');
  W.Free;
  R.Free;

  In_.CompactThreshold := 50;
  R := BuildContextUsage(In_);
  CheckEq(R.GetInt('free_tokens', -1), 0, 'over the threshold: no free space, not negative');
  W := Obj(R, 'compaction');
  CheckEq(W.GetInt('remaining_tokens', -1), 0, 'past the trigger: nothing remaining, not negative');
  W.Free;
  R.Free;

  In_.CompactEnabled := False;
  R := BuildContextUsage(In_);
  W := Obj(R, 'window');
  CheckEq(W.GetInt('tokens', -1), 0, 'nothing known: 0');
  Check(W.GetStr('source', '') = 'unknown', 'source unknown');
  W.Free;
  W := Obj(R, 'compaction');
  Check(not W.GetBool('enabled', True), 'compaction off');
  W.Free;
  R.Free;
  WriteLn('  ok: window is the given one, else the compaction point, else unknown');
end;

procedure TestCallerSystem;
var
  In_: TContextUsageInput;
  R, Sys, Item: TJsonObject;
  Arr: TJsonArray;
begin
  In_ := SampleInput;
  SetLength(In_.Sections, 0);
  In_.WithText := True;
  SetLength(In_.Messages, 2);
  In_.Messages[0] := MakeMessage(mrSystem, StringOfChar('p', 80));
  In_.Messages[1] := MakeMessage(mrUser, 'hi');
  R := BuildContextUsage(In_);
  try
    Sys := Obj(R, 'system');
    Check(Sys.GetStr('source', '') = 'caller', 'the caller''s prompt');
    CheckEq(Sys.GetInt('tokens', -1), 20 + 4, 'counted as a message is: text + envelope');
    Arr := Sys.ChildArray('sections');
    CheckEq(Arr.Count, 1, 'one section');
    Item := Arr.ItemObject(0);
    Check(Item.GetStr('id', '') = 'caller', 'id caller');
    Check(Item.GetStr('text', '') = StringOfChar('p', 80), 'its text, when asked');
    Item.Free;
    Arr.Free;
    Sys.Free;
    CheckEq(IntAt(R, ['messages', 'count']), 1, 'the system message is not a message');
    CheckEq(CategoryTokens(R, 'messages'), 1 + 4, 'only the user message');
  finally
    R.Free;
  end;
  WriteLn('  ok: a caller''s system message is the system prompt');
end;

procedure TestCompactMeasure;
var
  M: TMessageArray;
  Sys: string;
  N: Integer;
begin
  SetLength(M, 3);
  M[0] := MakeMessage(mrUser, StringOfChar('u', 37));
  M[1] := MakeMessage(mrAssistant, StringOfChar('a', 401));
  M[2] := MakeMessage(mrTool, '');
  Sys := StringOfChar('s', 999);
  N := CompactMeasure(M, Sys);
  CheckEq(N, 250 + (10 + 4) + (101 + 4) + (0 + 4), 'the measure');
  Check(NeedsCompact(M, Sys, N), 'compacts at exactly the measure');
  Check(not NeedsCompact(M, Sys, N + 1), 'not one token below it');
  Check(not NeedsCompact(M, Sys, 0), 'a zero threshold never compacts');
  Check(NeedsCompact(M, Sys, 250), 'the system prompt alone can trigger it');
  WriteLn('  ok: CompactMeasure is what NeedsCompact triggers on');
end;

begin
  TestSectionsJoinToPrompt;
  TestClassification;
  TestUnitCosts;
  TestReportAddsUp;
  TestWindow;
  TestCallerSystem;
  TestCompactMeasure;
  if Failures > 0 then
  begin
    WriteLn(Failures, ' failure(s)');
    Halt(1);
  end;
  WriteLn('ok - context usage tests passed');
end.
