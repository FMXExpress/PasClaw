{
  PasClaw.Providers.Anthropic - Anthropic Messages API client.
  Mirrors pkg/providers/anthropic_messages in picoclaw.

  Endpoint: POST <api_base>/v1/messages
  Auth:     x-api-key: <key>, anthropic-version: 2023-06-01
}
unit PasClaw.Providers.Anthropic;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  (* Opt-in toggles for Anthropic-side server tools. Mirrors
     PasClaw.Config.TAnthropicServerToolsConfig -- kept in this unit so
     PasClaw.Providers.Anthropic doesn't have to USE the config unit
     (the providers/config dependency direction is currently
     config → providers, and inverting that would pull TConfig into
     every provider unit test). *)
  TAnthropicServerTools = record
    WebSearch:        Boolean;
    WebSearchMaxUses: Integer;
    WebFetch:         Boolean;
    WebFetchMaxUses:  Integer;
  end;

  TAnthropicProvider = class(TInterfacedObject, ILLMProvider)
  private
    FAPIKey:  string;
    FAPIBase: string;
    FDefaultModel: string;
    FServerTools: TAnthropicServerTools;
  public
    constructor Create(const APIKey, APIBase, DefaultModel: string;
                       const ServerTools: TAnthropicServerTools);
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

{ Default-initialised TAnthropicServerTools (everything off). Use in
  tests / embedders that don't care about the server-tool surface. }
function NoAnthropicServerTools: TAnthropicServerTools;

{ Exposed so tests + embedders can render the wire body without
  hitting the network. Pure function; doesn't depend on the provider
  instance. Same code path Chat / ChatStream execute.

  ServerTools.WebSearch / WebFetch append the corresponding
  Anthropic server-side tool entries (web_search_20260209 /
  web_fetch_20260209) to the tools array. When a server tool is
  active, any caller-supplied tool with a colliding name (web_search,
  web_fetch) is silently dropped so the request doesn't 400 with
  "tools[*].name: duplicate". }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions;
                      const ServerTools: TAnthropicServerTools): string;

(* Build the follow-up request body for a stop_reason: "pause_turn"
   continuation. Takes the prior request body and the response body
   that returned pause_turn, appends a new assistant turn to the
   request's messages[] carrying the response's content array
   verbatim, and serialises the result. Anthropic detects the
   trailing server_tool_use block and resumes the server-side
   sampling loop where it paused. Returns '' on parse failure.

   Exposed for tests; production callers reach it via Chat() which
   runs the bounded continuation loop. *)
function ContinuePausedTurn(const ReqBody, RespBody: string): string;

(* A whole Messages API SSE stream, as text, read the way ChatStream reads
   it as it arrives: text pieces to OnChunk (text blocks joined with a line
   break, as Chat joins them), the rest put together into one response.
   Failed is the message of an `error` event, else ''. ContentJSON is the
   content array as Anthropic sent it -- text, tool_use, server tool
   blocks, thinking with its signature, citations -- for a pause_turn
   continuation. Pure, for tests. *)
function ParseAnthropicStream(const SSE: string; OnChunk: TStreamCallback;
                              out Failed, ContentJSON: string): TLLMResponse;

implementation

uses
  PasClaw.JSON,
  PasClaw.Providers.HTTP,
  PasClaw.Providers.Stream,
  PasClaw.Logger;

function NoAnthropicServerTools: TAnthropicServerTools;
begin
  Result.WebSearch        := False;
  Result.WebSearchMaxUses := 0;
  Result.WebFetch         := False;
  Result.WebFetchMaxUses  := 0;
end;

constructor TAnthropicProvider.Create(const APIKey, APIBase, DefaultModel: string;
                                      const ServerTools: TAnthropicServerTools);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase else FAPIBase := 'https://api.anthropic.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel else FDefaultModel := 'claude-opus-4-7';
  FServerTools := ServerTools;
end;

function TAnthropicProvider.GetDefaultModel: string;
begin
  Result := FDefaultModel;
end;

function TAnthropicProvider.GetName: string;
begin
  Result := 'anthropic';
end;

function TAnthropicProvider.SupportsThinking: Boolean;
begin
  Result := True;
end;

function TAnthropicProvider.SupportsNativeSearch: Boolean;
begin
  Result := False;
end;

function TAnthropicProvider.SupportsStreaming: Boolean;
begin
  Result := True;
end;

function RoleForAnthropic(R: TMsgRole): string;
begin
  case R of
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'user';   { tool result is delivered as user turn with tool_result content }
  else           Result := 'user';
  end;
end;

(* Build a fresh ephemeral cache_control object (with optional
   ttl="1h") for attaching to a content block / tool entry. Caller
   takes ownership via PutObject. The TTL field is optional --
   Anthropic's default cache TTL is 5 minutes and we pass that
   through implicitly by omitting the field; only "1h" (extended
   TTL beta) is recognised and emitted. *)
function MakeCacheControl(const TTL: string): TJsonObject;
begin
  Result := TJsonObject.Create;
  Result.PutStr('type', 'ephemeral');
  if TTL = '1h' then Result.PutStr('ttl', '1h');
end;

function ServerToolCollides(const Name: string;
                            const ServerTools: TAnthropicServerTools): Boolean;
{ True iff Name is one of the user-tool names that would duplicate a
  server-side tool we're about to emit. Anthropic rejects a tools
  array with two entries sharing a name; we drop the user entry in
  favour of the server-side one (Claude runs the latter on its own
  infrastructure, no round-trip needed). }
begin
  Result := (ServerTools.WebSearch and SameText(Name, 'web_search'))
         or (ServerTools.WebFetch  and SameText(Name, 'web_fetch'));
end;

function CountEffectiveTools(const Tools: array of TToolDefinition;
                              const ServerTools: TAnthropicServerTools): Integer;
{ How many user tools survive the collision filter, plus the server
  tools that will be appended. Used to pick the last-tool index for
  the cache_control breakpoint. }
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Tools) do
    if not ServerToolCollides(Tools[i].Name, ServerTools) then
      Inc(Result);
  if ServerTools.WebSearch then Inc(Result);
  if ServerTools.WebFetch  then Inc(Result);
end;

function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions;
                      const ServerTools: TAnthropicServerTools): string;
var
  Root, Block, ToolObj, Thinking, Msg, EmptyInput, SysBlock, CC: TJsonObject;
  MsgArr, ToolArr, ContentArr, SysArr: TJsonArray;
  i, j, Emitted, LastIdx: Integer;
  Sys: string;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('model',      Model);
    { max_tokens is REQUIRED by the Anthropic API, so a 0 ("provider
      default") must become a concrete value -- substitute the floor,
      which is the historical 8192 default and safe for every Claude model
      pasclaw talks to. }
    if Options.MaxTokens > 0 then
      Root.PutInt('max_tokens', Options.MaxTokens)
    else
      Root.PutInt('max_tokens', DefaultOutputTokenFloor);
    if Options.Temperature > 0 then Root.PutFloat('temperature', Options.Temperature);

    { System prompt: prefer Options.SystemPrompt, else first system message. }
    Sys := Options.SystemPrompt;
    for i := 0 to High(Messages) do
      if (Messages[i].Role = mrSystem) and (Sys = '') then
        Sys := Messages[i].Content;
    if Sys <> '' then
    begin
      if Options.CacheEnabled then
      begin
        (* Block form is required to attach cache_control. Anthropic
           accepts system as either a plain string or an array of
           text blocks (each with optional cache_control). Tagging
           the system prompt caches everything up to the tools array
           on the next turn -- biggest single-breakpoint win for
           multi-turn chats. *)
        SysArr   := TJsonArray.Create;
        SysBlock := TJsonObject.Create;
        SysBlock.PutStr('type', 'text');
        SysBlock.PutStr('text', Sys);
        CC := MakeCacheControl(Options.CacheTTL);
        SysBlock.PutObject('cache_control', CC);
        SysArr.AddObject(SysBlock);
        Root.PutArray('system', SysArr);
      end
      else
        Root.PutStr('system', Sys);
    end;

    if Options.ThinkingLevel <> '' then
    begin
      Thinking := TJsonObject.Create;
      Thinking.PutStr('type', 'enabled');
      if      Options.ThinkingLevel = 'low'  then Thinking.PutInt('budget_tokens', 1024)
      else if Options.ThinkingLevel = 'high' then Thinking.PutInt('budget_tokens', 8192)
      else                                        Thinking.PutInt('budget_tokens', 2048);
      Root.PutObject('thinking', Thinking);
    end;

    MsgArr := TJsonArray.Create;
    for i := 0 to High(Messages) do
    begin
      if Messages[i].Role = mrSystem then Continue;
      Msg := TJsonObject.Create;
      Msg.PutStr('role', RoleForAnthropic(Messages[i].Role));
      ContentArr := TJsonArray.Create;
      if Messages[i].Role = mrTool then
      begin
        Block := TJsonObject.Create;
        Block.PutStr('type',        'tool_result');
        Block.PutStr('tool_use_id', Messages[i].ToolCallId);
        Block.PutStr('content',     Messages[i].Content);
        ContentArr.AddObject(Block);
      end
      else if Length(Messages[i].ToolCalls) > 0 then
      begin
        if Messages[i].Content <> '' then
        begin
          Block := TJsonObject.Create;
          Block.PutStr('type', 'text');
          Block.PutStr('text', Messages[i].Content);
          ContentArr.AddObject(Block);
        end;
        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          Block := TJsonObject.Create;
          Block.PutStr('type', 'tool_use');
          Block.PutStr('id',   Messages[i].ToolCalls[j].Id);
          Block.PutStr('name', Messages[i].ToolCalls[j].Func.Name);
          if Messages[i].ToolCalls[j].Func.Arguments <> '' then
            Block.PutRaw('input', Messages[i].ToolCalls[j].Func.Arguments)
          else
          begin
            EmptyInput := TJsonObject.Create;
            Block.PutObject('input', EmptyInput);
          end;
          ContentArr.AddObject(Block);
        end;
      end
      else
      begin
        Block := TJsonObject.Create;
        Block.PutStr('type', 'text');
        Block.PutStr('text', Messages[i].Content);
        ContentArr.AddObject(Block);
      end;
      Msg.PutArray('content', ContentArr);
      MsgArr.AddObject(Msg);
    end;
    Root.PutArray('messages', MsgArr);

    if (Length(Tools) > 0) or ServerTools.WebSearch or ServerTools.WebFetch then
    begin
      ToolArr := TJsonArray.Create;
      LastIdx := CountEffectiveTools(Tools, ServerTools) - 1;
      Emitted := 0;
      for i := 0 to High(Tools) do
      begin
        { When Cfg flips on a server-side equivalent, suppress the
          user-registered tool with the same name. Two entries called
          "web_search" in the tools array would 400 with "duplicate
          tool name"; we keep the server-side one (Claude executes it
          on Anthropic's infrastructure, no round-trip via PasClaw). }
        if ServerToolCollides(Tools[i].Name, ServerTools) then Continue;

        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('name', Tools[i].Name);
        if Tools[i].Description <> '' then ToolObj.PutStr('description', Tools[i].Description);
        if Tools[i].Schema <> '' then
          ToolObj.PutRaw('input_schema', Tools[i].Schema)
        else
        begin
          EmptyInput := TJsonObject.Create;
          ToolObj.PutObject('input_schema', EmptyInput);
        end;
        { Tag the LAST effective tool entry with cache_control --
          Anthropic caches up to and including the tagged block, so
          a single breakpoint on the trailing tool covers the entire
          tools array as a stable prefix. Combined with the
          system-prompt breakpoint above we use 2 of Anthropic's
          4-breakpoint budget; the remaining two are reserved for
          compaction summaries or higher-layer hints later. }
        if Options.CacheEnabled and (Emitted = LastIdx) then
        begin
          CC := MakeCacheControl(Options.CacheTTL);
          ToolObj.PutObject('cache_control', CC);
        end;
        ToolArr.AddObject(ToolObj);
        Inc(Emitted);
      end;

      { Server-side tools -- Claude executes web_search / web_fetch on
        Anthropic's infrastructure. The tool entries are versioned
        type strings, not the user-tool name+input_schema shape; no
        beta header is required for the _20260209 versions. Dynamic
        filtering of search results activates automatically.
        See: https://platform.claude.com/docs/en/agents-and-tools/tool-use/overview }
      if ServerTools.WebSearch then
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('type', 'web_search_20260209');
        ToolObj.PutStr('name', 'web_search');
        if ServerTools.WebSearchMaxUses > 0 then
          ToolObj.PutInt('max_uses', ServerTools.WebSearchMaxUses);
        if Options.CacheEnabled and (Emitted = LastIdx) then
        begin
          CC := MakeCacheControl(Options.CacheTTL);
          ToolObj.PutObject('cache_control', CC);
        end;
        ToolArr.AddObject(ToolObj);
        Inc(Emitted);
      end;
      if ServerTools.WebFetch then
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('type', 'web_fetch_20260209');
        ToolObj.PutStr('name', 'web_fetch');
        if ServerTools.WebFetchMaxUses > 0 then
          ToolObj.PutInt('max_uses', ServerTools.WebFetchMaxUses);
        if Options.CacheEnabled and (Emitted = LastIdx) then
        begin
          CC := MakeCacheControl(Options.CacheTTL);
          ToolObj.PutObject('cache_control', CC);
        end;
        ToolArr.AddObject(ToolObj);
        Inc(Emitted);
      end;

      Root.PutArray('tools', ToolArr);

      (* tool_choice mapping (Anthropic Messages API):
          "auto"     -> {"type":"auto"}     (model decides; Anthropic default)
          "required" -> {"type":"any"}      (must call one of the tools)
          "none"     -> {"type":"none"}     (must not call any tool; needed
                                              because omitting the field with
                                              a non-empty tools array still
                                              lets the model call them)
          <tool name> -> {"type":"tool","name":<name>}  (force that tool)
        Empty string means "don't emit; let provider default apply". By
        convention any non-keyword, non-empty value is a tool name to
        force -- see TChatOptions.ToolChoice. *)
      if (Options.ToolChoice = 'auto')
         or (Options.ToolChoice = 'required')
         or (Options.ToolChoice = 'none') then
      begin
        ToolObj := TJsonObject.Create;
        if Options.ToolChoice = 'auto' then
          ToolObj.PutStr('type', 'auto')
        else if Options.ToolChoice = 'required' then
          ToolObj.PutStr('type', 'any')
        else
          ToolObj.PutStr('type', 'none');
        Root.PutObject('tool_choice', ToolObj);
      end
      else if Options.ToolChoice <> '' then
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('type', 'tool');
        ToolObj.PutStr('name', Options.ToolChoice);
        Root.PutObject('tool_choice', ToolObj);
      end;
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure ParseResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Block, Usage, InputObj: TJsonObject;
  Arr: TJsonArray;
  InputArr: TJsonArray;
  i: Integer;
  Kind, Text: string;
  TC: TToolCall;
begin
  Resp.Content := '';
  Resp.FinishReason := '';
  Resp.Model := '';
  Resp.Usage.InputTokens := 0;
  Resp.Usage.OutputTokens := 0;
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model        := Obj.GetStr('model',       '');
    Resp.FinishReason := Obj.GetStr('stop_reason', '');
    Arr := Obj.ChildArray('content');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Block := Arr.ItemObject(i);
        if Block = nil then Continue;
        try
          Kind := Block.GetStr('type', '');
          if Kind = 'text' then
          begin
            Text := Block.GetStr('text', '');
            if Resp.Content <> '' then Resp.Content := Resp.Content + sLineBreak;
            Resp.Content := Resp.Content + Text;
          end
          else if Kind = 'tool_use' then
          begin
            TC.Id        := Block.GetStr('id',   '');
            TC.Kind      := 'function';
            TC.Func.Name := Block.GetStr('name', '');
            InputObj := Block.ChildObject('input');
            if InputObj <> nil then
            try
              TC.Func.Arguments := InputObj.ToJSON;
            finally
              InputObj.Free;
            end
            else
            begin
              InputArr := Block.ChildArray('input');
              if InputArr <> nil then
              try
                TC.Func.Arguments := InputArr.ToJSON;
              finally
                InputArr.Free;
              end
              else
                TC.Func.Arguments := '{}';
            end;
            SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
            Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
          end;
        finally
          Block.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Usage := Obj.ChildObject('usage');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens        := Usage.GetInt('input_tokens',  0);
      Resp.Usage.OutputTokens       := Usage.GetInt('output_tokens', 0);
      Resp.Usage.CacheReadTokens    := Usage.GetInt('cache_read_input_tokens',     0);
      Resp.Usage.CacheCreatedTokens := Usage.GetInt('cache_creation_input_tokens', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
  end;
end;

const
  { Cap on continuation rounds for stop_reason: "pause_turn". Server-side
    web tools (web_search_20260209 / web_fetch_20260209) run inside an
    Anthropic-side sampling loop with a default 10-iteration ceiling;
    when that ceiling hits, the API returns pause_turn with the partial
    assistant content and expects the client to re-POST with the prior
    assistant turn appended verbatim. Five rounds is enough headroom for
    multi-search agentic queries while still bounding spend if Anthropic
    ever pause_turn'd unboundedly. }
  PAUSE_TURN_MAX_CONTINUATIONS = 5;

function SafeParseObject(const S: string): TJsonObject;
{ TJsonObject.Parse raises EPasClawJSON on malformed input rather than
  returning nil; ContinuePausedTurn needs nil-on-failure semantics so
  a bad body short-circuits to "return original" instead of crashing. }
begin
  Result := nil;
  try
    Result := TJsonObject.Parse(S);
  except
    Result := nil;
  end;
end;

{ ReqBody with an assistant turn appended whose content is ContentRaw (a
  JSON array), or '' when ReqBody does not parse. }
function AppendAssistantContent(const ReqBody, ContentRaw: string): string;
var
  Req, AssistantMsg: TJsonObject;
  MsgArr: TJsonArray;
begin
  Result := '';
  if Trim(ContentRaw) = '' then Exit;
  Req := SafeParseObject(ReqBody);
  if Req = nil then Exit;
  try
    MsgArr := Req.ChildArray('messages');
    if MsgArr = nil then Exit;
    try
      AssistantMsg := TJsonObject.Create;
      AssistantMsg.PutStr('role', 'assistant');
      AssistantMsg.PutRaw('content', ContentRaw);
      MsgArr.AddObject(AssistantMsg);
    finally
      MsgArr.Free;
    end;
    Result := Req.ToJSON;
  finally
    Req.Free;
  end;
end;

function ContinuePausedTurn(const ReqBody, RespBody: string): string;
{ Build the follow-up request body for a pause_turn continuation:
  take the prior response's content array verbatim and append it to
  the request's messages[] as a new assistant turn. Anthropic detects
  the trailing server_tool_use block and resumes the server-side
  loop from where it paused. Adding any user message in between (or
  re-rendering the assistant content as text-only) would break the
  resume detection.
  Returns the new wire body, or '' on parse failure (caller surfaces
  the prior response unchanged). }
var
  Resp: TJsonObject;
  ContentArr: TJsonArray;
  ContentRaw: string;
begin
  Result := '';
  Resp := SafeParseObject(RespBody);
  if Resp = nil then Exit;
  try
    ContentArr := Resp.ChildArray('content');
    if ContentArr = nil then Exit;
    try
      ContentRaw := ContentArr.ToJSON;
    finally
      ContentArr.Free;
    end;
  finally
    Resp.Free;
  end;
  Result := AppendAssistantContent(ReqBody, ContentRaw);
end;

function TAnthropicProvider.Chat(const Messages: array of TMessage;
                                 const Tools:    array of TToolDefinition;
                                 const Model:    string;
                                 const Options:  TChatOptions): TLLMResponse;
var
  Body, NextBody, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
  RoundResp: TLLMResponse;
  Continuations, i: Integer;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1/messages';
  { A caller can force server tools off for one call (the reranker sets this so
    a rank-these-docs prompt never triggers provider-side web search / fetch). }
  if Options.DisableServerTools then
    Body := BuildRequest(Messages, Tools, UseModel, Options, NoAnthropicServerTools)
  else
    Body := BuildRequest(Messages, Tools, UseModel, Options, FServerTools);

  {$IFDEF PASCLAW_C2W}
  SetLength(Headers, 3);
  {$ELSE}
  SetLength(Headers, 2);
  {$ENDIF}
  Headers[0] := MakeHeader('x-api-key',          FAPIKey);
  Headers[1] := MakeHeader('anthropic-version', '2023-06-01');
  {$IFDEF PASCLAW_C2W}
  { Browser (container2wasm) deployment only: Anthropic returns the CORS
    headers the in-browser Fetch proxy needs only when the caller opts in via
    this header. Excluded from normal builds so the server-side wire is
    byte-identical to before. }
  Headers[2] := MakeHeader('anthropic-dangerous-direct-browser-access', 'true');
  {$ENDIF}

  Result.Content := '';
  Result.StatusCode := 0;
  SetLength(Result.ToolCalls, 0);

  Continuations := 0;
  while True do
  begin
    LogDebug('anthropic POST %s (model=%s, body=%d bytes, continuation=%d)',
             [URL, UseModel, Length(Body), Continuations]);
    Resp := PostJSON(URL, Body, Headers, 120);
    Result.StatusCode := Resp.StatusCode;

    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    begin
      if Resp.Body <> '' then
        Result.Content := Format('anthropic error %d: %s', [Resp.StatusCode, Resp.Body])
      else
        Result.Content := Format('anthropic error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
      Result.FinishReason := 'error';
      Exit;
    end;

    Finalize(RoundResp);
    FillChar(RoundResp, SizeOf(RoundResp), 0);
    ParseResponse(Resp.Body, RoundResp);

    { Aggregate text across continuation rounds. Tool calls and usage
      come from the FINAL round (the only round that returns control
      to PasClaw); intermediate pause_turn rounds carry server-side
      activity only and have no client ToolCalls to surface. }
    if RoundResp.Content <> '' then
    begin
      if Result.Content <> '' then Result.Content := Result.Content + sLineBreak;
      Result.Content := Result.Content + RoundResp.Content;
    end;
    Result.FinishReason := RoundResp.FinishReason;
    Result.Model        := RoundResp.Model;
    Result.Usage.InputTokens        := Result.Usage.InputTokens        + RoundResp.Usage.InputTokens;
    Result.Usage.OutputTokens       := Result.Usage.OutputTokens       + RoundResp.Usage.OutputTokens;
    Result.Usage.CacheReadTokens    := Result.Usage.CacheReadTokens    + RoundResp.Usage.CacheReadTokens;
    Result.Usage.CacheCreatedTokens := Result.Usage.CacheCreatedTokens + RoundResp.Usage.CacheCreatedTokens;
    SetLength(Result.ToolCalls, Length(RoundResp.ToolCalls));
    for i := 0 to High(RoundResp.ToolCalls) do
      Result.ToolCalls[i] := RoundResp.ToolCalls[i];

    if RoundResp.FinishReason <> 'pause_turn' then Exit;

    if Continuations >= PAUSE_TURN_MAX_CONTINUATIONS then
    begin
      LogWarn('anthropic pause_turn cap (%d) reached; returning partial answer',
              [PAUSE_TURN_MAX_CONTINUATIONS]);
      Exit;
    end;

    NextBody := ContinuePausedTurn(Body, Resp.Body);
    if NextBody = '' then
    begin
      LogWarn('anthropic pause_turn: continuation body build failed; returning partial answer');
      Exit;
    end;
    Body := NextBody;
    Inc(Continuations);
  end;
end;

type
  { One content block of a streamed message, as it is put together. }
  TAnthBlock = class
    Kind: string;
    Start: string;        { the content_block as content_block_start sent it }
    Text: string;         { text_delta, or thinking_delta for a thinking block }
    PartialJson: string;  { input_json_delta fragments }
    Signature: string;    { signature_delta, for a thinking block }
    Citations: string;    { citations_delta citations, JSON objects joined by ',' }
  end;

  (* One streamed answer, put back together, every bit of state its own --
     no globals, so concurrent streams never meet. Content carries across
     pause_turn rounds the way Chat joins them; the rest is per round. *)
  TAnthropicStreamAcc = class
  private
    FBlocks: TList;
    function Block(Index: Integer): TAnthBlock;
    procedure Emit(const Text: string);
    function InputOf(B: TAnthBlock): string;
  public
    OnChunk: TStreamCallback;
    Content: string;
    Round: TLLMResponse;     { this round: model, stop reason, usage, tool calls }
    Failed, FailedType: string;
    constructor Create;
    destructor Destroy; override;
    procedure NewRound;
    procedure OnEvent(const Event, Data: string);
    function ContentJSON: string;
  end;

constructor TAnthropicStreamAcc.Create;
begin
  inherited Create;
  FBlocks := TList.Create;
end;

destructor TAnthropicStreamAcc.Destroy;
begin
  NewRound;
  FBlocks.Free;
  inherited;
end;

procedure TAnthropicStreamAcc.NewRound;
var
  i: Integer;
begin
  for i := 0 to FBlocks.Count - 1 do TObject(FBlocks[i]).Free;
  FBlocks.Clear;
  Round := Default(TLLMResponse);
end;

function TAnthropicStreamAcc.Block(Index: Integer): TAnthBlock;
begin
  if (Index >= 0) and (Index < FBlocks.Count) then
    Result := TAnthBlock(FBlocks[Index])
  else
    Result := nil;
end;

procedure TAnthropicStreamAcc.Emit(const Text: string);
var
  C: TStreamChunk;
begin
  if Text = '' then Exit;
  Content := Content + Text;
  if Assigned(OnChunk) then
  begin
    C := Default(TStreamChunk);
    C.Kind := 'text';
    C.Text := Text;
    OnChunk(C);
  end;
end;

{ A tool block's input as Chat reports it: the object, re-serialised. }
function TAnthropicStreamAcc.InputOf(B: TAnthBlock): string;
var
  O, In_: TJsonObject;
begin
  Result := '{}';
  if Trim(B.PartialJson) <> '' then
  begin
    try
      O := TJsonObject.Parse(B.PartialJson);
    except
      O := nil;
    end;
    if O <> nil then
    try
      Result := O.ToJSON;
    finally
      O.Free;
    end;
    Exit;
  end;
  { No fragments: the input the block started with, if any. }
  try
    O := TJsonObject.Parse(B.Start);
  except
    O := nil;
  end;
  if O <> nil then
  try
    In_ := O.ChildObject('input');
    if In_ <> nil then
    try
      Result := In_.ToJSON;
    finally
      In_.Free;
    end;
  finally
    O.Free;
  end;
end;

procedure TAnthropicStreamAcc.OnEvent(const Event, Data: string);
var
  Root, Sub, Usage, D, Cit: TJsonObject;
  Kind, DeltaKind, T: string;
  B: TAnthBlock;
  Tc: TToolCall;
  Idx: Integer;
begin
  if Trim(Data) = '' then Exit;
  try
    Root := TJsonObject.Parse(Data);
  except
    Exit;   { a line we cannot read is skipped, not fatal }
  end;
  if Root = nil then Exit;
  try
    Kind := Root.GetStr('type', Event);

    if Kind = 'message_start' then
    begin
      Sub := Root.ChildObject('message');
      if Sub <> nil then
      try
        Round.Model := Sub.GetStr('model', Round.Model);
        Usage := Sub.ChildObject('usage');
        if Usage <> nil then
        try
          Round.Usage.InputTokens        := Usage.GetInt('input_tokens', 0);
          Round.Usage.OutputTokens       := Usage.GetInt('output_tokens', 0);
          Round.Usage.CacheReadTokens    := Usage.GetInt('cache_read_input_tokens', 0);
          Round.Usage.CacheCreatedTokens := Usage.GetInt('cache_creation_input_tokens', 0);
        finally
          Usage.Free;
        end;
      finally
        Sub.Free;
      end;
    end

    else if Kind = 'content_block_start' then
    begin
      Idx := Integer(Root.GetInt('index', FBlocks.Count));
      Sub := Root.ChildObject('content_block');
      if Sub <> nil then
      try
        B := TAnthBlock.Create;
        B.Kind := Sub.GetStr('type', '');
        B.Start := Sub.ToJSON;
        while FBlocks.Count < Idx do FBlocks.Add(TAnthBlock.Create);   { a gap: keep indexes }
        if Idx < FBlocks.Count then
        begin
          TObject(FBlocks[Idx]).Free;
          FBlocks[Idx] := B;
        end
        else
          FBlocks.Add(B);
        if B.Kind = 'text' then
        begin
          { Chat joins text blocks -- and pause_turn rounds -- with a line
            break; so does the stream, at the block's start. }
          if Content <> '' then Emit(sLineBreak);
          T := Sub.GetStr('text', '');
          B.Text := T;
          Emit(T);
        end;
      finally
        Sub.Free;
      end;
    end

    else if Kind = 'content_block_delta' then
    begin
      B := Block(Integer(Root.GetInt('index', -1)));
      D := Root.ChildObject('delta');
      if (B <> nil) and (D <> nil) then
      begin
        DeltaKind := D.GetStr('type', '');
        if DeltaKind = 'text_delta' then
        begin
          T := D.GetStr('text', '');
          B.Text := B.Text + T;
          Emit(T);
        end
        else if DeltaKind = 'input_json_delta' then
          B.PartialJson := B.PartialJson + D.GetStr('partial_json', '')
        else if DeltaKind = 'thinking_delta' then
          B.Text := B.Text + D.GetStr('thinking', '')     { kept, not shown: Chat drops it }
        else if DeltaKind = 'signature_delta' then
          B.Signature := B.Signature + D.GetStr('signature', '')
        else if DeltaKind = 'citations_delta' then
        begin
          Cit := D.ChildObject('citation');
          if Cit <> nil then
          try
            if B.Citations <> '' then B.Citations := B.Citations + ',';
            B.Citations := B.Citations + Cit.ToJSON;
          finally
            Cit.Free;
          end;
        end;
      end;
      D.Free;
    end

    else if Kind = 'content_block_stop' then
    begin
      B := Block(Integer(Root.GetInt('index', -1)));
      if (B <> nil) and (B.Kind = 'tool_use') then
      begin
        Sub := TJsonObject.Parse(B.Start);
        try
          Tc := Default(TToolCall);
          Tc.Id := Sub.GetStr('id', '');
          Tc.Kind := 'function';
          Tc.Func.Name := Sub.GetStr('name', '');
          Tc.Func.Arguments := InputOf(B);
        finally
          Sub.Free;
        end;
        SetLength(Round.ToolCalls, Length(Round.ToolCalls) + 1);
        Round.ToolCalls[High(Round.ToolCalls)] := Tc;
      end;
    end

    else if Kind = 'message_delta' then
    begin
      D := Root.ChildObject('delta');
      if D <> nil then
      try
        Round.FinishReason := D.GetStr('stop_reason', Round.FinishReason);
      finally
        D.Free;
      end;
      Usage := Root.ChildObject('usage');
      if Usage <> nil then
      try
        { Cumulative; newer API versions repeat the input counts here. }
        Round.Usage.OutputTokens := Usage.GetInt('output_tokens', Round.Usage.OutputTokens);
        if Usage.GetInt('input_tokens', 0) > 0 then
          Round.Usage.InputTokens := Usage.GetInt('input_tokens', 0);
        if Usage.GetInt('cache_read_input_tokens', 0) > 0 then
          Round.Usage.CacheReadTokens := Usage.GetInt('cache_read_input_tokens', 0);
        if Usage.GetInt('cache_creation_input_tokens', 0) > 0 then
          Round.Usage.CacheCreatedTokens := Usage.GetInt('cache_creation_input_tokens', 0);
      finally
        Usage.Free;
      end;
    end

    else if Kind = 'error' then
    begin
      Sub := Root.ChildObject('error');
      if Sub <> nil then
      try
        Failed := Sub.GetStr('message', Data);
        FailedType := Sub.GetStr('type', '');
      finally
        Sub.Free;
      end
      else
        Failed := Data;
    end;
    { ping and message_stop carry nothing to keep. }
  finally
    Root.Free;
  end;
end;

{ The round's content array, block by block as Anthropic sent it, for the
  assistant turn a pause_turn continuation re-sends. }
function TAnthropicStreamAcc.ContentJSON: string;
var
  i: Integer;
  B: TAnthBlock;
  O: TJsonObject;
begin
  Result := '';
  for i := 0 to FBlocks.Count - 1 do
  begin
    B := TAnthBlock(FBlocks[i]);
    if B.Start = '' then Continue;
    try
      O := TJsonObject.Parse(B.Start);
    except
      Continue;
    end;
    if O = nil then Continue;
    try
      if B.Kind = 'text' then
      begin
        O.PutStr('text', B.Text);
        if B.Citations <> '' then O.PutRaw('citations', '[' + B.Citations + ']');
      end
      else if (B.Kind = 'tool_use') or (B.Kind = 'server_tool_use') or
              (B.Kind = 'mcp_tool_use') then
        O.PutRaw('input', InputOf(B))
      else if B.Kind = 'thinking' then
      begin
        O.PutStr('thinking', B.Text);
        O.PutStr('signature', B.Signature);
      end;
      if Result <> '' then Result := Result + ',';
      Result := Result + O.ToJSON;
    finally
      O.Free;
    end;
  end;
  Result := '[' + Result + ']';
end;

function ParseAnthropicStream(const SSE: string; OnChunk: TStreamCallback;
                              out Failed, ContentJSON: string): TLLMResponse;
var
  Acc: TAnthropicStreamAcc;
  P: TSSEParseStream;
  B: TBytes;
begin
  Acc := TAnthropicStreamAcc.Create;
  P := TSSEParseStream.Create(Acc.OnEvent);
  try
    Acc.OnChunk := OnChunk;
    Acc.NewRound;
    {$IFDEF FPC}
    SetLength(B, Length(SSE));
    if Length(SSE) > 0 then Move(SSE[1], B[0], Length(SSE));
    {$ELSE}
    B := TEncoding.UTF8.GetBytes(SSE);
    {$ENDIF}
    if Length(B) > 0 then P.Write(B[0], Length(B));
    P.Finish;
    Result := Acc.Round;
    Result.Content := Acc.Content;
    Failed := Acc.Failed;
    ContentJSON := Acc.ContentJSON;
  finally
    P.Free;
    Acc.Free;
  end;
end;

function TAnthropicProvider.ChatStream(const Messages: array of TMessage;
                                       const Tools:    array of TToolDefinition;
                                       const Model:    string;
                                       const Options:  TChatOptions;
                                       OnChunk: TStreamCallback): TLLMResponse;
var
  Body, NextBody, URL, UseModel, ErrMsg, Raw: string;
  Headers: array of THeaderPair;
  Opts: TChatOptions;
  Status, Events, Continuations, i: Integer;
  Root: TJsonObject;
  Acc: TAnthropicStreamAcc;
  Plain: TLLMResponse;
  C: TStreamChunk;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL := FAPIBase + '/v1/messages';

  { The same request Chat sends, streamed. }
  Opts := Options;
  Opts.Stream := True;
  if Opts.DisableServerTools then
    Body := BuildRequest(Messages, Tools, UseModel, Opts, NoAnthropicServerTools)
  else
    Body := BuildRequest(Messages, Tools, UseModel, Opts, FServerTools);
  Root := TJsonObject.Parse(Body);
  if Root = nil then
  begin
    Result := Chat(Messages, Tools, UseModel, Options);
    Exit;
  end;
  try
    Root.PutBool('stream', True);
    Body := Root.ToJSON;
  finally
    Root.Free;
  end;

  {$IFDEF PASCLAW_C2W}
  SetLength(Headers, 3);
  {$ELSE}
  SetLength(Headers, 2);
  {$ENDIF}
  Headers[0] := MakeHeader('x-api-key',         FAPIKey);
  Headers[1] := MakeHeader('anthropic-version', '2023-06-01');
  {$IFDEF PASCLAW_C2W}
  { See the non-streaming path: opt into Anthropic's browser/CORS mode for the
    c2w Fetch-proxy deployment only. }
  Headers[2] := MakeHeader('anthropic-dangerous-direct-browser-access', 'true');
  {$ENDIF}

  Result := Default(TLLMResponse);
  Acc := TAnthropicStreamAcc.Create;
  try
    Acc.OnChunk := OnChunk;
    Continuations := 0;
    while True do
    begin
      Acc.NewRound;
      LogDebug('anthropic SSE POST %s (model=%s, body=%d bytes, continuation=%d)',
               [URL, UseModel, Length(Body), Continuations]);
      PostSSE(URL, Body, Headers, 120, Acc.OnEvent, Status, ErrMsg, Raw, Events);
      Result.StatusCode := Status;

      if (Status < 200) or (Status >= 300) then
      begin
        if ErrMsg <> '' then
          Result.Content := Format('anthropic error %d: %s', [Status, ErrMsg])
        else if Raw <> '' then
          Result.Content := Format('anthropic error %d: %s', [Status, Raw])
        else
          Result.Content := Format('anthropic error: status=%d', [Status]);
        Result.FinishReason := 'error';
        SetLength(Result.ToolCalls, 0);
        Break;
      end;

      if Acc.Failed <> '' then
      begin
        { An error event inside a 200 stream (overloaded, api_error): the
          turn failed, whatever arrived before it. overloaded_error is
          Anthropic's 529, which the loop retries like any 5xx. }
        if Acc.FailedType = 'overloaded_error' then Result.StatusCode := 529
        else Result.StatusCode := 500;
        Result.Content := 'anthropic stream error: ' + Acc.Failed;
        Result.FinishReason := 'error';
        SetLength(Result.ToolCalls, 0);
        Break;
      end;

      if (Events = 0) and (Trim(Raw) <> '') then
      begin
        { No events: something between us and the API answered with one
          JSON body. Read it as Chat would, and pass its text on whole. }
        Plain := Default(TLLMResponse);
        ParseResponse(Raw, Plain);
        Acc.Round := Plain;
        if Plain.Content <> '' then
        begin
          if Acc.Content <> '' then
          begin
            C := Default(TStreamChunk);
            C.Kind := 'text';
            C.Text := sLineBreak;
            Acc.Content := Acc.Content + sLineBreak;
            if Assigned(OnChunk) then OnChunk(C);
          end;
          Acc.Content := Acc.Content + Plain.Content;
          if Assigned(OnChunk) then
          begin
            C := Default(TStreamChunk);
            C.Kind := 'text';
            C.Text := Plain.Content;
            OnChunk(C);
          end;
        end;
      end;

      { As Chat: text across every round, usage summed, the stop reason,
        model and tool calls of the last round. }
      Result.Content := Acc.Content;
      Result.FinishReason := Acc.Round.FinishReason;
      Result.Model := Acc.Round.Model;
      Inc(Result.Usage.InputTokens,        Acc.Round.Usage.InputTokens);
      Inc(Result.Usage.OutputTokens,       Acc.Round.Usage.OutputTokens);
      Inc(Result.Usage.CacheReadTokens,    Acc.Round.Usage.CacheReadTokens);
      Inc(Result.Usage.CacheCreatedTokens, Acc.Round.Usage.CacheCreatedTokens);
      SetLength(Result.ToolCalls, Length(Acc.Round.ToolCalls));
      for i := 0 to High(Acc.Round.ToolCalls) do
        Result.ToolCalls[i] := Acc.Round.ToolCalls[i];

      if Acc.Round.FinishReason <> 'pause_turn' then Break;
      if Continuations >= PAUSE_TURN_MAX_CONTINUATIONS then
      begin
        LogWarn('anthropic pause_turn cap (%d) reached; returning partial answer',
                [PAUSE_TURN_MAX_CONTINUATIONS]);
        Break;
      end;
      { Resume the server-side loop: the round's content, block for block,
        as the next assistant turn -- what Chat sends from the JSON body. }
      if (Events = 0) and (Trim(Raw) <> '') then
        NextBody := ContinuePausedTurn(Body, Raw)
      else
        NextBody := AppendAssistantContent(Body, Acc.ContentJSON);
      if NextBody = '' then
      begin
        LogWarn('anthropic pause_turn: continuation body build failed; returning partial answer');
        Break;
      end;
      Body := NextBody;
      Inc(Continuations);
    end;
  finally
    Acc.Free;
  end;
  if Assigned(OnChunk) then
  begin
    C := Default(TStreamChunk);
    C.Kind := 'done';
    OnChunk(C);
  end;
end;

end.
