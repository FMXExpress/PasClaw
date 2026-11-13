(*
  PasClaw.Agent.ContextUsage - what a turn's context is made of.

  The model's context is the system prompt, the tool schemas and the
  messages, and the person running PasClaw cannot see any of it: a reply
  gets slower and dearer as the conversation grows, compaction kicks in
  at some point, and nothing says which part grew. This unit takes the
  pieces a turn is about to send and says how big each one is, so the
  web UI can draw it -- the same idea as Claude Code's /context.

  Pure: the caller assembles the inputs the way the turn would (the
  gateway's /v1/context does it with the chat route's own code) and gets
  JSON back. Every number is an ESTIMATE from PasClaw.Tokenizer's
  4-characters-per-token rule, the one compaction uses -- right for
  "which part is big", not a provider's exact count, and the report
  says so in its "estimate" field.

  Report shape (all token counts are estimates):

    model, mode            what the turn would run with
    estimate               "chars/4"
    total_tokens           system + tools + messages
    window                 {tokens, source}: the space the graph is drawn
                           against. source "config"/"request" = the
                           model's context window as the operator gave it;
                           "compaction" = no window known, so the
                           compaction threshold, the point the loop
                           summarises the history; "unknown" = neither
                           (tokens 0).
    free_tokens            window - total, never below 0 (0 when unknown)
    compaction             {enabled, threshold_tokens, counted_tokens,
                           remaining_tokens}. counted_tokens is what
                           NeedsCompact measures (CompactMeasure: system
                           prompt and message bodies, not tool schemas,
                           not the turn clock), so it is the number that
                           triggers compaction.
    categories[]           {id, label, tokens} in drawing order:
                           system, memory, project, skills, tools, mcp,
                           messages. Ids are stable.
    system                 {source: "pasclaw"|"caller", tokens,
                           sections[] {id, title, group, tokens, text?}}
                           -- text only when WithText is set
    tools                  {enabled, tokens, count, deferred,
                           deferred_names[], items[] {name, server,
                           tokens}} -- server "" for a built-in tool,
                           else the MCP server. A deferred tool's schema
                           is not sent until tool_search reveals it; its
                           name is in the prompt's deferred_tools section.
    messages               {count, from_session, tokens,
                           by_role {user|assistant|tool: {count,tokens}},
                           largest[] {index, role, tokens, preview}}
*)
unit PasClaw.Agent.ContextUsage;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Agent.Prompt;

type
  TContextUsageInput = record
    Model:  string;
    Mode:   string;
    { PasClaw's composed prompt, section by section. Empty when the
      caller's own system message stands in for it. }
    Sections:     TPromptSectionArray;
    { Appended after the composed prompt for this turn (the working-state
      block a compaction leaves behind). '' = none. }
    WorkState:    string;
    { The messages exactly as the model would get them: stored turns
      merged in, the mode directive injected, the turn clock stamped on
      the last user message (HistWithTurnClock). A system message here
      is the caller's own prompt and is counted as system, not
      messages. }
    Messages:     TMessageArray;
    { How many of Messages came from the stored session. }
    FromSession:  Integer;
    ToolsEnabled: Boolean;
    { What the provider is sent (the registry's ToProviderDefs). }
    Tools:        TToolDefinitionArray;
    { Tools that exist but whose schema is not sent until tool_search
      reveals it. Only their names cost anything, in the prompt. }
    Deferred:     TStringArray;
    { Configured MCP server names, to tell an MCP tool (server__tool)
      from a built-in one and group it under its server. }
    MCPServers:   TStringArray;
    { The model's context window when someone said what it is; 0 = not
      known. WindowSource names who said ("config" / "request"). }
    ContextWindow: Integer;
    WindowSource:  string;
    CompactEnabled:   Boolean;
    CompactThreshold: Integer;
    { What compaction measures for this turn (CompactMeasure over the
      history and system prompt the loop holds). The caller computes it
      with the trigger's own function; the report passes it on. }
    CompactCounted:   Integer;
    { Put each system section's text in the report (its "text" field), so
      a reader can see what a section holds, not just its size. }
    WithText:         Boolean;
  end;

function BuildContextUsage(const Input: TContextUsageInput): TJsonObject;

{ Which category a prompt section is drawn in: memory, project, skills
  or system. Exposed for tests. }
function PromptSectionGroup(const SectionId: string): string;

{ The MCP server a tool belongs to, or '' for a built-in tool. }
function ToolServerOf(const ToolName: string;
                      const Servers: array of string): string;

{ The tokens one tool's schema costs: its wire form, the OpenAI
  function-tool object every provider adapter starts from. }
function ToolDefTokens(const T: TToolDefinition): Integer;

{ The tokens one message costs: its text, the 4-token envelope the
  tokenizer charges every message, and any tool calls it carries. }
function MessageTokens(const M: TMessage): Integer;

implementation

uses
  PasClaw.Tokenizer,
  PasClaw.Tools.ToolLoop;  { StripTurnClock -- previews show what was said }

const
  { The joiner BuildSystemPrompt puts between sections -- charged to the
    section after it, so the parts add up to the whole. }
  PromptSep = sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;
  LargestCount = 5;
  PreviewChars = 100;

function PromptSectionGroup(const SectionId: string): string;
begin
  if (SectionId = 'memory') or (SectionId = 'facts') then
    Result := 'memory'
  else if (SectionId = 'project_rules') or (SectionId = 'instructions') then
    Result := 'project'
  else if SectionId = 'skills' then
    Result := 'skills'
  else
    Result := 'system';
end;

function ToolServerOf(const ToolName: string;
                      const Servers: array of string): string;
var
  i, P: Integer;
  Prefix: string;
begin
  { Longest configured server whose "<name>__" prefixes the tool: server
    names may themselves contain underscores (MCPCallStructured matches
    the same way). }
  Result := '';
  for i := 0 to High(Servers) do
  begin
    if Servers[i] = '' then Continue;
    Prefix := Servers[i] + '__';
    if (Length(ToolName) > Length(Prefix)) and
       (Copy(ToolName, 1, Length(Prefix)) = Prefix) and
       (Length(Servers[i]) > Length(Result)) then
      Result := Servers[i];
  end;
  if Result <> '' then Exit;
  { A server registered by a client (ACP, a project's own MCP list) is not
    in the config, but its tools are still namespaced. No built-in tool
    name contains "__". }
  P := Pos('__', ToolName);
  if P > 1 then Result := Copy(ToolName, 1, P - 1);
end;

function ToolDefTokens(const T: TToolDefinition): Integer;
var
  Schema: string;
begin
  Schema := Trim(T.Schema);
  if Schema = '' then Schema := '{}';
  Result := EstimateTokens(
    '{"type":"function","function":{"name":"' + JsonEscape(T.Name) +
    '","description":"' + JsonEscape(T.Description) +
    '","parameters":' + Schema + '}}');
end;

function MessageTokens(const M: TMessage): Integer;
var
  i: Integer;
begin
  Result := EstimateTokens(M.Content) + 4;
  for i := 0 to High(M.ToolCalls) do
    Result := Result + EstimateTokens(M.ToolCalls[i].Func.Name) +
              EstimateTokens(M.ToolCalls[i].Func.Arguments) + 4;
end;

function OneLine(const S: string): string;
var
  i: Integer;
begin
  Result := Utf8SafeTruncate(Trim(S), PreviewChars * 2);
  for i := 1 to Length(Result) do
    if (Result[i] = #10) or (Result[i] = #13) or (Result[i] = #9) then
      Result[i] := ' ';
  Result := Trim(Result);
  if Length(Result) > PreviewChars then
    Result := Utf8SafeTruncate(Result, PreviewChars) + '...';
end;

function BuildContextUsage(const Input: TContextUsageInput): TJsonObject;
const
  CatIds: array[0..6] of string =
    ('system', 'memory', 'project', 'skills', 'tools', 'mcp', 'messages');
  CatLabels: array[0..6] of string =
    ('System prompt', 'Memory', 'Project rules', 'Skills',
     'Built-in tools', 'MCP tools', 'Messages');
var
  CatTokens: array[0..6] of Integer;
  Sys, Tools, Msgs, Cmp, Win, Item, RoleObj, ByRole: TJsonObject;
  Arr: TJsonArray;
  i, j, k, T, SysTokens, ToolTokens, MsgTokens, MsgCount, Total, Window,
    Counted, Best: Integer;
  RoleCount, RoleTokens: array[TMsgRole] of Integer;
  Group, Server, Source: string;
  Toks: array of Integer;
  Taken: array of Boolean;
  R: TMsgRole;
  CallerSystem: Boolean;

  function CatIndex(const Id: string): Integer;
  var
    n: Integer;
  begin
    for n := 0 to High(CatIds) do
      if CatIds[n] = Id then Exit(n);
    Result := 0;
  end;

begin
  for i := 0 to High(CatTokens) do CatTokens[i] := 0;
  Result := TJsonObject.Create;
  Result.PutStr('model', Input.Model);
  Result.PutStr('mode', Input.Mode);
  Result.PutStr('estimate', 'chars/4');

  { ---- system prompt ---- }
  CallerSystem := False;
  for i := 0 to High(Input.Messages) do
    if Input.Messages[i].Role = mrSystem then CallerSystem := True;
  SysTokens := 0;
  Sys := TJsonObject.Create;
  Arr := TJsonArray.Create;
  if CallerSystem then
  begin
    { The caller's system message replaced PasClaw's prompt (the chat
      route skips BuildSystemPrompt when one is present). }
    for i := 0 to High(Input.Messages) do
      if Input.Messages[i].Role = mrSystem then
      begin
        T := MessageTokens(Input.Messages[i]);
        Inc(SysTokens, T);
        Inc(CatTokens[0], T);
        Item := TJsonObject.Create;
        Item.PutStr('id', 'caller');
        Item.PutStr('title', 'Your system prompt');
        Item.PutStr('group', 'system');
        Item.PutInt('tokens', T);
        if Input.WithText then Item.PutStr('text', Input.Messages[i].Content);
        Arr.AddObject(Item);
      end;
  end
  else
  begin
    for i := 0 to High(Input.Sections) do
    begin
      if i = 0 then
        T := EstimateTokens(Input.Sections[i].Text)
      else
        T := EstimateTokens(PromptSep + Input.Sections[i].Text);
      Group := PromptSectionGroup(Input.Sections[i].Id);
      Inc(SysTokens, T);
      Inc(CatTokens[CatIndex(Group)], T);
      Item := TJsonObject.Create;
      Item.PutStr('id', Input.Sections[i].Id);
      Item.PutStr('title', Input.Sections[i].Title);
      Item.PutStr('group', Group);
      Item.PutInt('tokens', T);
      if Input.WithText then Item.PutStr('text', Input.Sections[i].Text);
      Arr.AddObject(Item);
    end;
    if Trim(Input.WorkState) <> '' then
    begin
      { The chat route appends it with one blank line, not the section
        joiner. }
      T := EstimateTokens(sLineBreak + sLineBreak + Input.WorkState);
      Inc(SysTokens, T);
      Inc(CatTokens[0], T);
      Item := TJsonObject.Create;
      Item.PutStr('id', 'working_state');
      Item.PutStr('title', 'Working state (after compaction)');
      Item.PutStr('group', 'system');
      Item.PutInt('tokens', T);
      if Input.WithText then Item.PutStr('text', Input.WorkState);
      Arr.AddObject(Item);
    end;
  end;
  if CallerSystem then
    Sys.PutStr('source', 'caller')
  else
    Sys.PutStr('source', 'pasclaw');
  Sys.PutInt('tokens', SysTokens);
  Sys.PutArray('sections', Arr);

  { ---- tools ---- }
  ToolTokens := 0;
  Tools := TJsonObject.Create;
  Tools.PutBool('enabled', Input.ToolsEnabled);
  Arr := TJsonArray.Create;
  if Input.ToolsEnabled then
    for i := 0 to High(Input.Tools) do
    begin
      T := ToolDefTokens(Input.Tools[i]);
      Server := ToolServerOf(Input.Tools[i].Name, Input.MCPServers);
      Inc(ToolTokens, T);
      if Server = '' then Inc(CatTokens[4], T) else Inc(CatTokens[5], T);
      Item := TJsonObject.Create;
      Item.PutStr('name', Input.Tools[i].Name);
      Item.PutStr('server', Server);
      Item.PutInt('tokens', T);
      Arr.AddObject(Item);
    end;
  Tools.PutInt('tokens', ToolTokens);
  if Input.ToolsEnabled then
    Tools.PutInt('count', Length(Input.Tools))
  else
    Tools.PutInt('count', 0);
  Tools.PutInt('deferred', Length(Input.Deferred));
  Tools.PutArray('items', Arr);
  Arr := TJsonArray.Create;
  for i := 0 to High(Input.Deferred) do Arr.AddStr(Input.Deferred[i]);
  Tools.PutArray('deferred_names', Arr);

  { ---- messages ---- }
  for R := Low(TMsgRole) to High(TMsgRole) do
  begin
    RoleCount[R] := 0;
    RoleTokens[R] := 0;
  end;
  MsgTokens := 0;
  MsgCount := 0;
  SetLength(Toks, Length(Input.Messages));
  SetLength(Taken, Length(Input.Messages));
  for i := 0 to High(Input.Messages) do
  begin
    Taken[i] := False;
    Toks[i] := MessageTokens(Input.Messages[i]);
    if Input.Messages[i].Role = mrSystem then
    begin
      Taken[i] := True;    { counted as system above }
      Continue;
    end;
    Inc(MsgCount);
    Inc(MsgTokens, Toks[i]);
    Inc(RoleCount[Input.Messages[i].Role]);
    Inc(RoleTokens[Input.Messages[i].Role], Toks[i]);
  end;
  CatTokens[6] := MsgTokens;
  Msgs := TJsonObject.Create;
  Msgs.PutInt('count', MsgCount);
  Msgs.PutInt('from_session', Input.FromSession);
  Msgs.PutInt('tokens', MsgTokens);
  ByRole := TJsonObject.Create;
  for R := mrUser to High(TMsgRole) do
  begin
    RoleObj := TJsonObject.Create;
    RoleObj.PutInt('count', RoleCount[R]);
    RoleObj.PutInt('tokens', RoleTokens[R]);
    ByRole.PutObject(MsgRoleToString(R), RoleObj);
  end;
  Msgs.PutObject('by_role', ByRole);
  Arr := TJsonArray.Create;
  for k := 1 to LargestCount do
  begin
    Best := -1;
    for j := 0 to High(Toks) do
      if (not Taken[j]) and ((Best < 0) or (Toks[j] > Toks[Best])) then
        Best := j;
    if Best < 0 then Break;
    Taken[Best] := True;
    Item := TJsonObject.Create;
    Item.PutInt('index', Best);
    Item.PutStr('role', MsgRoleToString(Input.Messages[Best].Role));
    Item.PutInt('tokens', Toks[Best]);
    if (Trim(Input.Messages[Best].Content) = '') and
       (Length(Input.Messages[Best].ToolCalls) > 0) then
      Item.PutStr('preview', 'calls ' + Input.Messages[Best].ToolCalls[0].Func.Name)
    else
      Item.PutStr('preview', OneLine(StripTurnClock(Input.Messages[Best].Content)));
    Arr.AddObject(Item);
  end;
  Msgs.PutArray('largest', Arr);

  { ---- totals ---- }
  Total := SysTokens + ToolTokens + MsgTokens;
  Result.PutInt('total_tokens', Total);

  Window := 0;
  Source := 'unknown';
  if Input.ContextWindow > 0 then
  begin
    Window := Input.ContextWindow;
    Source := Input.WindowSource;
    if Source = '' then Source := 'config';
  end
  else if Input.CompactEnabled and (Input.CompactThreshold > 0) then
  begin
    Window := Input.CompactThreshold;
    Source := 'compaction';
  end;
  Win := TJsonObject.Create;
  Win.PutInt('tokens', Window);
  Win.PutStr('source', Source);
  Result.PutObject('window', Win);
  if Window > Total then
    Result.PutInt('free_tokens', Window - Total)
  else
    Result.PutInt('free_tokens', 0);

  Counted := Input.CompactCounted;
  Cmp := TJsonObject.Create;
  Cmp.PutBool('enabled', Input.CompactEnabled and (Input.CompactThreshold > 0));
  Cmp.PutInt('threshold_tokens', Input.CompactThreshold);
  Cmp.PutInt('counted_tokens', Counted);
  if Input.CompactThreshold > Counted then
    Cmp.PutInt('remaining_tokens', Input.CompactThreshold - Counted)
  else
    Cmp.PutInt('remaining_tokens', 0);
  Result.PutObject('compaction', Cmp);

  Arr := TJsonArray.Create;
  for i := 0 to High(CatIds) do
  begin
    Item := TJsonObject.Create;
    Item.PutStr('id', CatIds[i]);
    Item.PutStr('label', CatLabels[i]);
    Item.PutInt('tokens', CatTokens[i]);
    Arr.AddObject(Item);
  end;
  Result.PutArray('categories', Arr);
  Result.PutObject('system', Sys);
  Result.PutObject('tools', Tools);
  Result.PutObject('messages', Msgs);
end;

end.
