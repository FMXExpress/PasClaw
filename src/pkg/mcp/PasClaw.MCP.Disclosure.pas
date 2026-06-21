(*
  PasClaw.MCP.Disclosure - progressive-disclosure tool surface for MCP
  tools, modelled on Claude Code's ToolSearch.

  Why
  ===

  PasClaw registers every MCP tool from every configured server into a
  single TToolRegistry, and ToProviderDefs dumps ALL their JSON schemas
  into the per-request `tools` array on every turn. For deployments
  with one or two MCP servers that's cheap; for deployments with the
  GitHub MCP (50+ tools) or several stacked servers, the schemas
  dominate the prompt-cost budget on turns that touch zero MCP tools.

  When Cfg.MCPProgressiveDisclosure is True:

    - MCP tools register with IsDeferred=True (PasClaw.MCP.Bridge).
    - TToolRegistry.ToProviderDefs strips deferred-and-not-revealed
      tools from the provider's tools array (the schemas stay in the
      dispatcher; the model just doesn't see them).
    - PasClaw.Agent.Prompt's tool section grows a "## Deferred Tools"
      block listing the deferred tool NAMES (cheap -- one line each).
      The model knows the tools exist but not how to call them.
    - This unit's tool_search lets the model load schemas on demand:
      one call returns the matching tools' full definitions AND
      reveals them in the registry so the very next ToProviderDefs
      pass (= start of the next iter loop) surfaces them as callable.

  Query shapes (mirrors Claude Code's ToolSearch)
  ===============================================

    select:Name1,Name2,...
      Exact-name fetch. The names are looked up in the deferred set;
      each match is revealed and its schema returned. Unknown names
      are silently dropped (a model with stale tool names from a
      previous session can't wedge the search).

    +required keyword1 keyword2 ...
      The "+required" term MUST appear in the tool name; the remaining
      keywords rank candidate matches. Useful when you know the
      namespace ("+github issue list") but not the exact tool.

    keyword1 keyword2 ...
      Plain keyword search. Each keyword is matched against name AND
      description; tools that hit more distinct keywords rank higher.

  Result format
  =============

  A single text result so the model can read it in one tool_result
  turn without parsing nested JSON. Shape:

    Loaded N tool(s):

    <function>{"name":"server__tool","description":"...","parameters":{...}}</function>
    <function>{"name":"server__other","description":"...","parameters":{...}}</function>

  The <function> envelope mirrors the shape Claude Code uses in its
  ToolSearch result so a model that has seen the Claude Code pattern
  doesn't have to relearn it. Each block carries enough information
  to author a tool_call.

  Revealing & dispatch
  ====================

  Reveal is per-name in the registry's FRevealed set; it's idempotent
  and survives re-registration from the MCP bridge's live-connect pass
  (FRevealed is keyed on name, not TTool identity). RunTool dispatch
  is unchanged -- the dispatcher always finds the tool regardless of
  IsDeferred, so even a misbehaving model that tries to invoke a
  deferred tool BEFORE searching gets the real call (it just had to
  guess the schema). That's "fail open" rather than "fail closed" --
  worth the tradeoff because the alternative is a hard error mid-turn
  that the model can't recover from.

  Naming
  ======

  The tool is `tool_search` (singular `tool_`) so it never collides
  with namespaced MCP tools (which use `<server>__<tool>` -- two
  underscores). Mirrors the convention PasClaw.Skills.Disclosure
  uses for skills_list / skills_view.
*)
unit PasClaw.MCP.Disclosure;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Tools.Registry;

{ Register tool_search into Reg. No-op when
  Cfg.MCPProgressiveDisclosure is False. The registry pointer is
  captured into a module global so the handler can call back into
  it without threading state through the TToolHandler signature
  (matches the pattern PasClaw.Skills.Disclosure uses for
  GHomeDir). }
procedure RegisterMCPDisclosureTools(Reg: TToolRegistry; const Cfg: TConfig);

{ Build the "## Deferred Tools" section the system-prompt assembler
  appends when progressive disclosure is on. Lists the names of all
  deferred-and-not-yet-revealed tools so the model knows what's
  available without paying the schema-token cost. Returns '' when
  disclosure is off (GRegistry uncaptured) or when no deferred
  tools are present. Safe to call from any thread -- DeferredNames
  takes the registry lock. }
function BuildDeferredToolsSection: string;

implementation

uses
  PasClaw.Tools.Types,
  PasClaw.JSON,
  PasClaw.Logger;

var
  GRegistry: TToolRegistry = nil;

{ ---- query parsing ---- }

function SplitWords(const S: string): TStringArray;
var
  i, n: Integer;
  buf: string;
begin
  SetLength(Result, 0);
  buf := '';
  n := 0;
  for i := 1 to Length(S) do
    if (S[i] = ' ') or (S[i] = #9) or (S[i] = ',') then
    begin
      if buf <> '' then
      begin
        SetLength(Result, n + 1);
        Result[n] := buf;
        Inc(n);
        buf := '';
      end;
    end
    else
      buf := buf + S[i];
  if buf <> '' then
  begin
    SetLength(Result, n + 1);
    Result[n] := buf;
  end;
end;

function StartsWith(const S, Prefix: string): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
            (Copy(S, 1, Length(Prefix)) = Prefix);
end;

{ Score a tool against a list of lowercase keyword tokens. One point
  per distinct keyword that appears as a substring of name OR
  description (case-insensitive). RequiredTerm, when non-empty, MUST
  appear in the name -- otherwise the tool scores 0 regardless of the
  other terms. }
function ScoreTool(const Name, Description: string;
                   const Keywords: TStringArray;
                   const RequiredTerm: string): Integer;
var
  i: Integer;
  NameLow, DescLow, KW: string;
begin
  Result := 0;
  NameLow := LowerCase(Name);
  DescLow := LowerCase(Description);
  if RequiredTerm <> '' then
    if Pos(LowerCase(RequiredTerm), NameLow) = 0 then Exit;
  for i := 0 to High(Keywords) do
  begin
    KW := LowerCase(Keywords[i]);
    if KW = '' then Continue;
    if (Pos(KW, NameLow) > 0) or (Pos(KW, DescLow) > 0) then
      Inc(Result);
  end;
end;

{ ---- result formatting ---- }

function FormatToolBlock(const T: TTool): string;
var
  O: TJsonObject;
  ParamsObj: TJsonObject;
  Schema: string;
begin
  O := TJsonObject.Create;
  try
    O.PutStr('name',        T.Name);
    O.PutStr('description', T.Description);
    Schema := Trim(T.Schema);
    if Schema = '' then
      O.PutStr('parameters', '')
    else
    begin
      ParamsObj := TJsonObject.Parse(Schema);
      if ParamsObj <> nil then
        { PutObject takes ownership and zeroes the var. ParamsObj is no
          longer ours after this call. }
        O.PutObject('parameters', ParamsObj)
      else
        { Schema came in as something other than a JSON object
          (rare, but some MCP servers send a bare string). Pass
          it through as a string so the model still sees SOMETHING
          rather than a silent drop. }
        O.PutStr('parameters', Schema);
    end;
    Result := '<function>' + O.ToJSON + '</function>';
  finally
    O.Free;
  end;
end;

{ ---- handler ---- }

function ToolSearchHandler(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Query: string;
  MaxResults: Integer;
  DeferredNames: TStringArray;
  Keywords: TStringArray;
  RequiredTerm: string;
  Tokens: TStringArray;
  Matches: array of record
    Name:  string;
    Score: Integer;
  end;
  Tok: string;
  i, j, k, NumMatches, NumResults: Integer;
  T: TTool;
  Sb: TStringBuilder;
  Selected: TStringArray;
  IsSelect: Boolean;
begin
  ErrMsg := '';
  Result := '';
  if GRegistry = nil then
  begin
    ErrMsg := 'tool_search: registry not initialised';
    Exit;
  end;

  Query := '';
  MaxResults := 5;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj <> nil then
  try
    Query := Trim(Obj.GetStr('query', ''));
    MaxResults := Integer(Obj.GetInt('max_results', MaxResults));
  finally
    Obj.Free;
  end;
  if MaxResults < 1 then MaxResults := 1;
  if MaxResults > 50 then MaxResults := 50;

  if Query = '' then
  begin
    ErrMsg := 'tool_search: `query` is required ' +
              '(use "select:Name1,Name2" or keyword search)';
    Exit;
  end;

  DeferredNames := GRegistry.DeferredNames;
  if Length(DeferredNames) = 0 then
  begin
    Result := 'No deferred tools to search.';
    Exit;
  end;

  IsSelect := StartsWith(LowerCase(Query), 'select:');
  SetLength(Selected, 0);

  if IsSelect then
  begin
    { Exact-name fetch. The "select:" arg form is "select:N1,N2,N3"
      with optional whitespace. Look each name up in the deferred set;
      silently drop unknowns so a stale model can't wedge the call. }
    Tokens := SplitWords(Copy(Query, 8, MaxInt));
    for i := 0 to High(Tokens) do
      for j := 0 to High(DeferredNames) do
        if SameText(Tokens[i], DeferredNames[j]) then
        begin
          SetLength(Selected, Length(Selected) + 1);
          Selected[High(Selected)] := DeferredNames[j];
          Break;
        end;
    NumResults := Length(Selected);
  end
  else
  begin
    { Keyword search. A token beginning with '+' is the required-in-
      name term (drop the leading '+'); remaining tokens are ranked
      keywords. Score each deferred tool and pick the top MaxResults
      by score (ties broken by lexical name order, which is the
      registry's insertion order for MCP tools = server group
      order). }
    Tokens := SplitWords(Query);
    SetLength(Keywords, 0);
    RequiredTerm := '';
    for i := 0 to High(Tokens) do
    begin
      Tok := Tokens[i];
      if (Tok <> '') and (Tok[1] = '+') then
        RequiredTerm := Copy(Tok, 2, MaxInt)
      else
      begin
        SetLength(Keywords, Length(Keywords) + 1);
        Keywords[High(Keywords)] := Tok;
      end;
    end;
    if (Length(Keywords) = 0) and (RequiredTerm = '') then
    begin
      ErrMsg := 'tool_search: query had no usable tokens';
      Exit;
    end;

    SetLength(Matches, Length(DeferredNames));
    NumMatches := 0;
    for i := 0 to High(DeferredNames) do
    begin
      if not GRegistry.DeferredFind(DeferredNames[i], T) then Continue;
      Matches[NumMatches].Name  := DeferredNames[i];
      Matches[NumMatches].Score := ScoreTool(T.Name, T.Description,
                                              Keywords, RequiredTerm);
      if Matches[NumMatches].Score > 0 then Inc(NumMatches);
    end;
    SetLength(Matches, NumMatches);

    { Simple O(N*MaxResults) selection sort -- N is the deferred-tool
      count, typically tens, never thousands. Avoid pulling in
      generics.Defaults / TList<T> sort for a one-shot ranker. Each
      outer iteration locks in the next-highest scorer at position i. }
    NumResults := NumMatches;
    if NumResults > MaxResults then NumResults := MaxResults;
    for i := 0 to NumResults - 1 do
      for j := i + 1 to NumMatches - 1 do
        if Matches[j].Score > Matches[i].Score then
        begin
          Tok := Matches[i].Name;
          Matches[i].Name  := Matches[j].Name;
          Matches[j].Name  := Tok;
          k := Matches[i].Score;
          Matches[i].Score := Matches[j].Score;
          Matches[j].Score := k;
        end;

    SetLength(Selected, NumResults);
    for i := 0 to NumResults - 1 do
      Selected[i] := Matches[i].Name;
  end;

  if Length(Selected) = 0 then
  begin
    Result := 'No deferred tools matched "' + Query + '".';
    Exit;
  end;

  Sb := TStringBuilder.Create;
  try
    Sb.Append('Loaded ');
    Sb.Append(Length(Selected));
    Sb.Append(' tool(s):');
    Sb.AppendLine; Sb.AppendLine;
    for i := 0 to High(Selected) do
    begin
      if not GRegistry.DeferredFind(Selected[i], T) then
      begin
        { Race: registry pruned the entry between the deferred-names
          snapshot and the lookup. Skip silently rather than fail the
          whole search. }
        Continue;
      end;
      Sb.AppendLine(FormatToolBlock(T));
      GRegistry.Reveal(Selected[i]);
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
  LogInfo('tool_search: revealed %d tool(s) for query "%s"',
          [Length(Selected), Query]);
end;

const
  ToolSearchSchema =
    '{"type":"object","properties":{' +
    '"query":{"type":"string","description":"' +
      '\"select:Name1,Name2\" for exact-name fetch; ' +
      '\"+required keyword1 keyword2\" to require a name substring + rank; ' +
      'plain \"keyword1 keyword2\" for ranked keyword search across name + description.' +
    '"},' +
    '"max_results":{"type":"integer","description":"Maximum tools to return (default 5, max 50). Ignored for select: queries."}' +
    '},"required":["query"]}';

  ToolSearchDesc =
    'Search the deferred MCP tool catalog and load matching tools'' full ' +
    'definitions. Returns name + description + JSON schema for each match in ' +
    '<function>{...}</function> blocks. Tools returned by this call become ' +
    'callable on the next tool-loop iteration -- you do NOT need to call ' +
    'tool_search again to invoke them.';

function BuildDeferredToolsSection: string;
var
  Names: TStringArray;
  Sb: TStringBuilder;
  i: Integer;
begin
  Result := '';
  if GRegistry = nil then Exit;
  Names := GRegistry.DeferredNames;
  if Length(Names) = 0 then Exit;
  Sb := TStringBuilder.Create;
  try
    Sb.AppendLine('## Deferred Tools');
    Sb.AppendLine;
    Sb.Append('You have ');
    Sb.Append(Length(Names));
    Sb.AppendLine(' MCP tool(s) available but not loaded into your callable ' +
                  'tools array (their schemas are withheld to keep the prompt ' +
                  'small). Call `tool_search` to load schemas for the ones ' +
                  'you need before invoking them. Once loaded, the tool ' +
                  'becomes callable on the very next iteration -- you do NOT ' +
                  'need to tool_search again.');
    Sb.AppendLine;
    Sb.AppendLine('Deferred tool names (call tool_search with `select:` or a ' +
                  'keyword query to load):');
    for i := 0 to High(Names) do
    begin
      Sb.Append('- ');
      Sb.AppendLine(Names[i]);
    end;
    Result := Sb.ToString;
  finally
    Sb.Free;
  end;
end;

procedure RegisterMCPDisclosureTools(Reg: TToolRegistry; const Cfg: TConfig);
var
  T: TTool;
begin
  if Reg = nil then Exit;
  if not Cfg.MCPProgressiveDisclosure then Exit;

  GRegistry := Reg;

  T.Name        := 'tool_search';
  T.Description := ToolSearchDesc;
  T.Schema      := ToolSearchSchema;
  T.Handler     := ToolSearchHandler;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  T.Category    := tcReadOnly;
  T.IsDeferred  := False;   { the discovery tool itself is always visible }
  Reg.Register(T);

  LogInfo('mcp: progressive-disclosure tool registered (tool_search)');
end;

end.
