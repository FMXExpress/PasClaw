(*
  PasClaw.Providers.Gemini - Google Gemini "generateContent" REST client.

  Endpoint : POST <api_base>/v1beta/models/<model>:generateContent
  Auth     : x-goog-api-key: <api_key>

  Gemini's wire shape differs from OpenAI / Anthropic in three places
  that matter for the tool loop:

    1. Roles: messages use "user" / "model" (not "assistant"). System
       prompts do not go in the messages array -- they live in a
       top-level `systemInstruction` field.

    2. Tool calls live inside `parts[].functionCall`, and tool results
       come back via `parts[].functionResponse` (sent with role "user"
       per Google's spec). Function responses are keyed by tool NAME,
       not by ID -- we build an id->name map on the fly when scanning
       earlier assistant turns.

    3. Tools are sent at the top level as
       `tools: [{functionDeclarations: [{name, description, parameters}]}]`.

  Scope of this initial cut: text + tool calls + tool results, plus
  basic generationConfig (max_tokens, temperature) and usage parsing.
  Streaming, thinkingConfig, image attachments, and proxy / extraBody
  knobs are deferred -- ChatStream falls back to a synchronous Chat()
  call and emits the result as one text chunk, matching what
  TOpenAIProvider does for its non-streaming providers.
*)
unit PasClaw.Providers.Gemini;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  (* Opt-in toggles for Gemini-side server tools. Mirrors
     PasClaw.Config.TGeminiServerToolsConfig -- kept local to this
     unit so the provider's tests can build the wire body without
     importing the config unit (same shape Anthropic uses, see
     TAnthropicServerTools). *)
  TGeminiServerTools = record
    GoogleSearch: Boolean;
  end;

  TGeminiProvider = class(TInterfacedObject, ILLMProvider)
  private
    FAPIKey:       string;
    FAPIBase:      string;
    FDefaultModel: string;
    FServerTools:  TGeminiServerTools;
  public
    constructor Create(const APIKey, APIBase, DefaultModel: string;
                       const ServerTools: TGeminiServerTools);
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

{ Default-initialised TGeminiServerTools (everything off). Use in
  tests / embedders that don't want server tools in the wire body. }
function NoGeminiServerTools: TGeminiServerTools;

{ Exported for test fixtures -- given a TLLMResponse-shaped input,
  returns the JSON body that would be POSTed to generateContent.
  Used by the Codex PR #116 review-fix test to assert SystemPrompt
  / in-history mrSystem dedup without spinning up a real HTTPS
  round-trip. Tools / ToolIds / ToolNames are normally constructed
  inside the request flow; tests pass empty arrays.

  The 4-arg overload delegates to the 5-arg form with
  NoGeminiServerTools -- server tools off -- so existing call sites
  and tests that don't care about Google search stay untouched. }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string; overload;
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions;
                      const ServerTools: TGeminiServerTools): string; overload;

(* Strip JSON-Schema fields Gemini's function-calling API doesn't
   accept (additionalProperties, $schema, $id, $ref, definitions,
   $defs, patternProperties, unevaluatedProperties, propertyNames)
   from a tool parameter schema. Walker is schema-aware -- only
   strips on schema nodes, never on the user-property name map
   under `properties`, so a tool parameter literally named
   "additionalProperties" survives. Returns the input verbatim on
   parse failure so a genuinely-malformed schema still surfaces
   Gemini's own 400 with a useful pointer. Exposed for tests. *)
function SanitizeSchemaForGemini(const RawSchema: string): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Providers.HTTP,
  PasClaw.Logger;

function NoGeminiServerTools: TGeminiServerTools;
begin
  Result.GoogleSearch := False;
end;

function IsGemini3OrLater(const Model: string): Boolean;
(* True when Model names a Gemini family at major version 3 or higher.
   Gates the google_search + functionDeclarations combo: pre-Gemini-3
   models (2.0, 2.5, 1.5 etc.) reject the request with 400 when both
   are present in the same `tools[]` array -- Google's current docs
   route mixed-tool flows on those models through the Live API
   instead. Gemini 3.x lifted the restriction and accepts both shapes
   in a single REST call.

   Detection is a deliberate cheap prefix check on the digit
   immediately after `gemini-` -- covers `gemini-3-flash`,
   `gemini-3.5-flash`, `gemini-3.0-pro`, hypothetical `gemini-4-*`,
   etc. Vendor-prefixed deployments (e.g. `vertex/gemini-3-...`) hit
   the substring match. Anything that doesn't fit the pattern --
   `gemini-pro`, `gemini-1.5-flash`, `gemini-2.5-flash`, an unknown
   name -- is conservatively treated as "cannot combine", so the
   default-on toggle never lights a 400 on a user's tool-using
   chat. *)
var
  M: string;
  i: Integer;
begin
  M := LowerCase(Model);
  i := Pos('gemini-', M);
  if i = 0 then Exit(False);
  i := i + Length('gemini-');
  if i > Length(M) then Exit(False);
  Result := (M[i] >= '3') and (M[i] <= '9');
end;

constructor TGeminiProvider.Create(const APIKey, APIBase, DefaultModel: string;
                                   const ServerTools: TGeminiServerTools);
begin
  inherited Create;
  FAPIKey := APIKey;
  if APIBase <> '' then FAPIBase := APIBase
                   else FAPIBase := 'https://generativelanguage.googleapis.com';
  if DefaultModel <> '' then FDefaultModel := DefaultModel
                       else FDefaultModel := 'gemini-1.5-flash';
  FServerTools := ServerTools;
end;

function TGeminiProvider.GetDefaultModel: string;     begin Result := FDefaultModel; end;
function TGeminiProvider.GetName: string;             begin Result := 'gemini';      end;
function TGeminiProvider.SupportsThinking: Boolean;   begin Result := False;         end;
function TGeminiProvider.SupportsNativeSearch: Boolean; begin Result := FServerTools.GoogleSearch; end;
function TGeminiProvider.SupportsStreaming: Boolean;  begin Result := False;         end;

{ Map TMsgRole to Gemini's content.role. Note tool/system are special
  cases handled by the caller -- system goes in systemInstruction,
  tool result content is wrapped with role "user" + functionResponse
  part. This helper only matters for plain user / assistant turns. }
function RoleForGemini(R: TMsgRole): string;
begin
  case R of
    mrAssistant: Result := 'model';
  else
    Result := 'user';
  end;
end;

procedure StripUnsupportedSchemaFields(Obj: TJsonObject); forward;
procedure StripUnsupportedFromArray(Arr: TJsonArray); forward;
procedure WalkPropertyMap(Map: TJsonObject); forward;

procedure StripUnsupportedSchemaFields(Obj: TJsonObject);
{ Recursively remove JSON-Schema fields that Gemini's
  function-calling API rejects. Currently:

    additionalProperties   -- error: "Unknown name 'additionalProperties'
                              at tools[0].function_declarations[N].
                              parameters.properties[M].value: Cannot
                              find field"
    $schema, $id, $ref     -- meta fields Gemini doesn't model
    definitions, $defs     -- JSON Schema 2019-09+ -- Gemini takes
                              OpenAPI 3.0 schema subset only
    patternProperties      -- not in OpenAPI 3.0
    unevaluatedProperties  -- JSON Schema 2019-09+
    propertyNames          -- JSON Schema 2019-09+

  MCP servers and external skill manifests frequently emit
  additionalProperties: false on their tool schemas (it's the JSON
  Schema "strict" convention); these end up verbatim in PasClaw's
  Tools[i].Schema via PutRaw. Anthropic and OpenAI tolerate the
  extra fields silently; Gemini 400s. Strip them at the wire boundary
  so all three back-ends see the same schema with no behavioural
  change on the others.

  Walker is schema-aware: it only strips keywords on schema nodes,
  and only recurses through schema-keyword fields that hold
  subschemas (`items`, `anyOf`, `oneOf`, `allOf`, `not`) or maps of
  subschemas (`properties`). Codex P2 on PR #153: the original
  blind recursion treated the `properties` map as a schema node and
  would drop a tool parameter literally named "additionalProperties"
  (or any other stripped keyword). Rare but legitimately broken --
  user property names share a namespace with schema keywords. }
var
  Sub: TJsonObject;
  SubArr: TJsonArray;
begin
  if Obj = nil then Exit;

  { Drop unsupported schema keywords on THIS schema node. }
  Obj.Remove('additionalProperties');
  Obj.Remove('$schema');
  Obj.Remove('$id');
  Obj.Remove('$ref');
  Obj.Remove('definitions');
  Obj.Remove('$defs');
  Obj.Remove('patternProperties');
  Obj.Remove('unevaluatedProperties');
  Obj.Remove('propertyNames');

  { Recurse into name->subschema maps. The map's KEYS are arbitrary
    user-supplied names -- never strip keywords on the map itself. }
  Sub := Obj.ChildObject('properties');
  if Sub <> nil then
  try
    WalkPropertyMap(Sub);
  finally
    Sub.Free;
  end;

  { Recurse into schema-keyword fields that hold a single subschema. }
  Sub := Obj.ChildObject('items');
  if Sub <> nil then
  try
    StripUnsupportedSchemaFields(Sub);
  finally
    Sub.Free;
  end;
  Sub := Obj.ChildObject('not');
  if Sub <> nil then
  try
    StripUnsupportedSchemaFields(Sub);
  finally
    Sub.Free;
  end;

  { Recurse into schema-keyword fields that hold arrays of
    subschemas. `items` can be array-shaped in tuple-validation
    schemas; we already handle the object case above and fall
    through to the array case here. }
  SubArr := Obj.ChildArray('items');
  if SubArr <> nil then
  try
    StripUnsupportedFromArray(SubArr);
  finally
    SubArr.Free;
  end;
  SubArr := Obj.ChildArray('anyOf');
  if SubArr <> nil then
  try
    StripUnsupportedFromArray(SubArr);
  finally
    SubArr.Free;
  end;
  SubArr := Obj.ChildArray('oneOf');
  if SubArr <> nil then
  try
    StripUnsupportedFromArray(SubArr);
  finally
    SubArr.Free;
  end;
  SubArr := Obj.ChildArray('allOf');
  if SubArr <> nil then
  try
    StripUnsupportedFromArray(SubArr);
  finally
    SubArr.Free;
  end;
end;

procedure WalkPropertyMap(Map: TJsonObject);
{ The `properties` field is a map from arbitrary user property name
  to subschema. Iterate the values (each IS a schema, recurse with
  the full strip pass) but never strip on Map itself -- Map's keys
  are user data, not schema keywords. }
var
  Keys: TStringList;
  i: Integer;
  ChildObj: TJsonObject;
begin
  if Map = nil then Exit;
  Keys := Map.Keys;
  if Keys = nil then Exit;
  try
    for i := 0 to Keys.Count - 1 do
    begin
      ChildObj := Map.ChildObject(Keys[i]);
      if ChildObj <> nil then
      try
        StripUnsupportedSchemaFields(ChildObj);
      finally
        ChildObj.Free;
      end;
    end;
  finally
    Keys.Free;
  end;
end;

procedure StripUnsupportedFromArray(Arr: TJsonArray);
{ Recurse into each element of an anyOf/oneOf/allOf/items array.
  Every element is itself a schema, so the full strip pass applies. }
var
  i: Integer;
  ChildObj: TJsonObject;
begin
  if Arr = nil then Exit;
  for i := 0 to Arr.Count - 1 do
  begin
    ChildObj := Arr.ItemObject(i);
    if ChildObj <> nil then
    try
      StripUnsupportedSchemaFields(ChildObj);
    finally
      ChildObj.Free;
    end;
  end;
end;

function SanitizeSchemaForGemini(const RawSchema: string): string;
{ Parse, scrub, re-serialise. Returns the original string verbatim on
  parse failure so a malformed schema doesn't silently disappear --
  the API will surface its own 400 with a clearer pointer. }
var
  Root: TJsonObject;
begin
  Result := RawSchema;
  if Trim(RawSchema) = '' then Exit;
  try
    Root := TJsonObject.Parse(RawSchema);
  except
    Exit;
  end;
  if Root = nil then Exit;
  try
    StripUnsupportedSchemaFields(Root);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

{ 4-arg overload -- no server tools. Preserved so existing tests
  (gemini_schema_strip_tests.pas + friends) and embedders that
  predate the server-tool field keep compiling unchanged. }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions): string;
begin
  Result := BuildRequest(Messages, Tools, Model, Options, NoGeminiServerTools);
end;

{ Builds the request body. Mirrors picoclaw's pkg/providers/httpapi
  gemini_provider.go buildRequestBody, trimmed to text + tool support. }
function BuildRequest(const Messages: array of TMessage;
                      const Tools:    array of TToolDefinition;
                      const Model:    string;
                      const Options:  TChatOptions;
                      const ServerTools: TGeminiServerTools): string;
var
  Root, Content, Part, ToolObj, FuncDecl, FuncCall, FuncResp,
    FuncRespBody, EmptyObj, GenCfg, SysContent, SysPart,
    GoogleSearchObj, GoogleSearchEntry, ToolCfg: TJsonObject;
  Contents, Parts, ToolsArr, FuncDecls, SysParts: TJsonArray;
  i, j: Integer;
  Sys, ToolName, ArgsJSON: string;
  ToolIds, ToolNames: TStringList;   { id -> name map, parallel arrays }
  Idx, StartIdx: Integer;
  EmitGoogleSearch: Boolean;
begin
  ToolIds   := TStringList.Create;
  ToolNames := TStringList.Create;
  Root := TJsonObject.Create;
  try
    Contents := TJsonArray.Create;

    { First pass: collect system prompt for systemInstruction.

      Precedence matches the OpenAI / Anthropic builders: when
      Options.SystemPrompt is non-empty, that wins and in-history
      mrSystem entries are skipped. When SystemPrompt is empty,
      fold every in-history mrSystem into Sys. Earlier this
      builder concatenated BOTH, which double-shipped the policy
      when the ToolLoop's steering fold copied in-history
      mrSystem into LiveOptions.SystemPrompt (the original entries
      stay in Hist for ephemeral-reset recovery -- see
      CopyHistorySystem in PasClaw.Tools.ToolLoop). Codex P2 on
      PR #116. }
    Sys := Options.SystemPrompt;
    if Sys = '' then
      for i := 0 to High(Messages) do
        if (Messages[i].Role = mrSystem) and (Trim(Messages[i].Content) <> '') then
        begin
          if Sys = '' then
            Sys := Messages[i].Content
          else
            Sys := Sys + sLineBreak + Messages[i].Content;
        end;

    { Pre-scan assistant turns so tool-result messages can resolve a
      function name from their tool_call_id. Gemini's functionResponse
      requires the NAME, not the id. }
    for i := 0 to High(Messages) do
      if Messages[i].Role = mrAssistant then
        for j := 0 to High(Messages[i].ToolCalls) do
          if (Messages[i].ToolCalls[j].Id <> '') and
             (ToolIds.IndexOf(Messages[i].ToolCalls[j].Id) < 0) then
          begin
            ToolIds.Add(Messages[i].ToolCalls[j].Id);
            ToolNames.Add(Messages[i].ToolCalls[j].Func.Name);
          end;

    { Gemini ordering guard for a compacted tail. After compaction folds
      the summary into systemInstruction and keeps only the trailing
      messages, the first turn we'd emit can be:
        - a model functionCall whose originating user turn was summarised
          away -- Gemini 400s ("function call turn comes immediately after
          a user turn or after a function response turn"), or
        - an orphaned tool functionResponse whose functionCall was
          summarised away -- a functionResponse with no matching call.
      Skip leading orphaned tool results, then synthesise a user turn when
      the first real turn is the model's -- OR when EVERY retained entry
      was a skipped orphan (a tail that fell wholly inside a parallel
      tool-result block), which would otherwise leave contents[] empty and
      give Gemini no user turn to continue from. The summarised context
      lives in systemInstruction, so nothing is lost. }
    StartIdx := 0;
    while (StartIdx <= High(Messages)) and
          ((Messages[StartIdx].Role = mrSystem) or
           (Messages[StartIdx].Role = mrTool)) do
      Inc(StartIdx);
    if (StartIdx > High(Messages)) or
       (Messages[StartIdx].Role = mrAssistant) then
    begin
      Content := TJsonObject.Create;
      Content.PutStr('role', 'user');
      Parts := TJsonArray.Create;
      Part := TJsonObject.Create;
      Part.PutStr('text', 'Continue.');
      Parts.AddObject(Part);
      Content.PutArray('parts', Parts);
      Contents.AddObject(Content);
    end;

    { Second pass: build contents[] in order. }
    for i := StartIdx to High(Messages) do
    begin
      if Messages[i].Role = mrSystem then Continue;

      if Messages[i].Role = mrTool then
      begin
        // Tool result -> role:user, parts:[{functionResponse}].
        Content := TJsonObject.Create;
        Content.PutStr('role', 'user');
        Parts := TJsonArray.Create;

        Part := TJsonObject.Create;
        FuncResp := TJsonObject.Create;

        Idx := ToolIds.IndexOf(Messages[i].ToolCallId);
        if Idx >= 0 then ToolName := ToolNames[Idx]
                    else ToolName := '';
        FuncResp.PutStr('name', ToolName);

        FuncRespBody := TJsonObject.Create;
        FuncRespBody.PutStr('result', Messages[i].Content);
        FuncResp.PutObject('response', FuncRespBody);

        Part.PutObject('functionResponse', FuncResp);
        Parts.AddObject(Part);
        Content.PutArray('parts', Parts);
        Contents.AddObject(Content);
        Continue;
      end;

      if Messages[i].Role = mrAssistant then
      begin
        Content := TJsonObject.Create;
        Content.PutStr('role', 'model');
        Parts := TJsonArray.Create;

        if Trim(Messages[i].Content) <> '' then
        begin
          Part := TJsonObject.Create;
          Part.PutStr('text', Messages[i].Content);
          Parts.AddObject(Part);
        end;

        for j := 0 to High(Messages[i].ToolCalls) do
        begin
          if Messages[i].ToolCalls[j].Func.Name = '' then Continue;
          Part := TJsonObject.Create;
          FuncCall := TJsonObject.Create;
          FuncCall.PutStr('name', Messages[i].ToolCalls[j].Func.Name);
          ArgsJSON := Messages[i].ToolCalls[j].Func.Arguments;
          if Trim(ArgsJSON) = '' then
          begin
            EmptyObj := TJsonObject.Create;
            FuncCall.PutObject('args', EmptyObj);
          end
          else
            FuncCall.PutRaw('args', ArgsJSON);
          Part.PutObject('functionCall', FuncCall);
          { Gemini 3+: echo back the thoughtSignature on the part
            (sibling of functionCall) verbatim. Mandatory on Gemini
            3 function calling; absent / empty on Gemini 2.x and
            earlier. Without this, Gemini 3 rejects the next request
            with 400 "Function call is missing a thought_signature
            in functionCall parts". }
          if Messages[i].ToolCalls[j].ProviderSignature <> '' then
            Part.PutStr('thoughtSignature',
                        Messages[i].ToolCalls[j].ProviderSignature);
          Parts.AddObject(Part);
        end;

        if Parts.Count > 0 then
        begin
          Content.PutArray('parts', Parts);
          Contents.AddObject(Content);
        end
        else
        begin
          { Drop the empty assistant turn -- Gemini rejects empty parts. }
          Parts.Free;
          Content.Free;
        end;
        Continue;
      end;

      { Plain user turn. }
      Content := TJsonObject.Create;
      Content.PutStr('role', RoleForGemini(Messages[i].Role));
      Parts := TJsonArray.Create;
      Part := TJsonObject.Create;
      Part.PutStr('text', Messages[i].Content);
      Parts.AddObject(Part);
      Content.PutArray('parts', Parts);
      Contents.AddObject(Content);
    end;

    Root.PutArray('contents', Contents);

    if Sys <> '' then
    begin
      SysContent := TJsonObject.Create;
      SysParts := TJsonArray.Create;
      SysPart := TJsonObject.Create;
      SysPart.PutStr('text', Sys);
      SysParts.AddObject(SysPart);
      SysContent.PutArray('parts', SysParts);
      Root.PutObject('systemInstruction', SysContent);
    end;

    (* Decide whether google_search will actually go on the wire.
       The toggle says "the operator wants grounding when possible",
       but Gemini's wire constraints narrow that:

         - On Gemini 3.x+ we may combine google_search with
           functionDeclarations in the same request -- emit both.
         - On Gemini 2.x and earlier, mixing the two in a single
           REST call returns 400 ("Live API only" per Google's
           function-calling docs). If the caller has registered
           local tools, preserve those (they're the user's
           explicit configuration) and suppress google_search this
           turn -- silently better than a 400 on every tool-using
           chat. With no local tools the combo doesn't arise and
           google_search ships.

       Codex P2 on PR #158. *)
    EmitGoogleSearch := ServerTools.GoogleSearch and
                       ((Length(Tools) = 0) or IsGemini3OrLater(Model));
    if ServerTools.GoogleSearch and (Length(Tools) > 0) and
       (not IsGemini3OrLater(Model)) then
      LogDebug('gemini: suppressing google_search for this turn -- model %s ' +
               'rejects google_search alongside functionDeclarations ' +
               '(combo requires gemini-3.x or later)', [Model]);

    (* Build the tools[] array when EITHER caller tools or the
       effective google_search emission is active. Each tool
       category is its own object inside the array --
       `functionDeclarations: [...]` for our local tools,
       `google_search: ` empty-object for Gemini's grounded search. *)
    if (Length(Tools) > 0) or EmitGoogleSearch then
    begin
      ToolsArr := TJsonArray.Create;

      if Length(Tools) > 0 then
      begin
        FuncDecls := TJsonArray.Create;
        for i := 0 to High(Tools) do
        begin
          FuncDecl := TJsonObject.Create;
          FuncDecl.PutStr('name', Tools[i].Name);
          if Tools[i].Description <> '' then
            FuncDecl.PutStr('description', Tools[i].Description);
          if Tools[i].Schema <> '' then
            { Strip JSON-Schema fields Gemini's function-calling API
              doesn't accept (additionalProperties, $schema, etc.) --
              see SanitizeSchemaForGemini for the full list and why
              MCP / skill schemas trip into them. }
            FuncDecl.PutRaw('parameters', SanitizeSchemaForGemini(Tools[i].Schema))
          else
          begin
            EmptyObj := TJsonObject.Create;
            FuncDecl.PutObject('parameters', EmptyObj);
          end;
          FuncDecls.AddObject(FuncDecl);
        end;
        ToolObj := TJsonObject.Create;
        ToolObj.PutArray('functionDeclarations', FuncDecls);
        ToolsArr.AddObject(ToolObj);
      end;

      if EmitGoogleSearch then
      begin
        (* Wire shape: a tools-array entry whose only key is
           "google_search" with an empty config object as its value.
           The empty value opts into Gemini's default grounding
           behaviour; extra keys here are rejected by the API. *)
        GoogleSearchEntry := TJsonObject.Create;
        GoogleSearchObj   := TJsonObject.Create;
        GoogleSearchEntry.PutObject('google_search', GoogleSearchObj);
        ToolsArr.AddObject(GoogleSearchEntry);
      end;

      Root.PutArray('tools', ToolsArr);

      (* On Gemini 3.x the combo functionDeclarations + google_search
         additionally requires tool_config.include_server_side_tool_invocations
         to be set, otherwise the API returns:

           400: Please enable tool_config.include_server_side_tool_invocations
                to use Built-in tools with Function calling.

         Emit the field only when BOTH categories are on the wire --
         it's a no-op (and a wire-noise warning on some endpoints)
         when only one tool type is present. *)
      if EmitGoogleSearch and (Length(Tools) > 0) then
      begin
        ToolCfg := TJsonObject.Create;
        ToolCfg.PutBool('include_server_side_tool_invocations', True);
        Root.PutObject('tool_config', ToolCfg);
      end;
    end;

    if (Options.MaxTokens > 0) or (Options.Temperature > 0) then
    begin
      GenCfg := TJsonObject.Create;
      if Options.MaxTokens > 0 then GenCfg.PutInt('maxOutputTokens', Options.MaxTokens);
      if Options.Temperature > 0 then GenCfg.PutFloat('temperature', Options.Temperature);
      Root.PutObject('generationConfig', GenCfg);
    end;

    Result := Root.ToJSON;
  finally
    Root.Free;
    ToolIds.Free;
    ToolNames.Free;
  end;
end;

procedure ParseResponse(const Body: string; var Resp: TLLMResponse);
var
  Obj, Candidate, ContentObj, Part, FuncCall, ArgsObj, Usage: TJsonObject;
  Candidates, Parts: TJsonArray;
  i, j: Integer;
  Text: string;
  TC: TToolCall;
begin
  Resp.Content := '';
  Resp.FinishReason := '';
  Resp.Model := '';
  Resp.Usage.InputTokens  := 0;
  Resp.Usage.OutputTokens := 0;
  SetLength(Resp.ToolCalls, 0);
  if Trim(Body) = '' then Exit;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Resp.Model := Obj.GetStr('modelVersion', '');

    Candidates := Obj.ChildArray('candidates');
    if Candidates <> nil then
    try
      for i := 0 to Candidates.Count - 1 do
      begin
        Candidate := Candidates.ItemObject(i);
        if Candidate = nil then Continue;
        try
          if Resp.FinishReason = '' then
            Resp.FinishReason := Candidate.GetStr('finishReason', '');

          ContentObj := Candidate.ChildObject('content');
          if ContentObj = nil then Continue;
          try
            Parts := ContentObj.ChildArray('parts');
            if Parts = nil then Continue;
            try
              for j := 0 to Parts.Count - 1 do
              begin
                Part := Parts.ItemObject(j);
                if Part = nil then Continue;
                try
                  Text := Part.GetStr('text', '');
                  if Text <> '' then
                  begin
                    if Resp.Content <> '' then Resp.Content := Resp.Content + sLineBreak;
                    Resp.Content := Resp.Content + Text;
                  end;
                  FuncCall := Part.ChildObject('functionCall');
                  if FuncCall <> nil then
                  try
                    TC.Kind      := 'function';
                    TC.Func.Name := FuncCall.GetStr('name', '');
                    { Gemini 3+: thoughtSignature is a sibling of
                      functionCall on the part. Must be echoed back
                      verbatim when we send the matching
                      functionResponse, or the next request 400s
                      with "Function call is missing a
                      thought_signature". Empty for Gemini 2.x where
                      it's not required. }
                    TC.ProviderSignature := Part.GetStr('thoughtSignature', '');
                    { Gemini's functionCall has name + args but no
                      OpenAI-style id. The tool loop later records this
                      id on the mrTool result, and BuildRequest above
                      needs a non-empty id to resolve the call->name
                      map for functionResponse -- leaving Id empty
                      makes the tool result go back with name: "" and
                      the model can't associate it with the requested
                      call. Synthesize a deterministic local id from
                      the function name + the position of this call in
                      the response. Collisions across turns are fine:
                      same id always maps to the same name. }
                    TC.Id        := FuncCall.GetStr('id', '');
                    if Trim(TC.Id) = '' then
                      TC.Id := Format('gemini_call_%s_%d',
                                      [TC.Func.Name, Length(Resp.ToolCalls)]);
                    ArgsObj := FuncCall.ChildObject('args');
                    if ArgsObj <> nil then
                    try
                      TC.Func.Arguments := ArgsObj.ToJSON;
                    finally
                      ArgsObj.Free;
                    end
                    else
                      TC.Func.Arguments := '{}';
                    SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
                    Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
                  finally
                    FuncCall.Free;
                  end;
                finally
                  Part.Free;
                end;
              end;
            finally
              Parts.Free;
            end;
          finally
            ContentObj.Free;
          end;
        finally
          Candidate.Free;
        end;
      end;
    finally
      Candidates.Free;
    end;

    { Map Gemini's STOP / MAX_TOKENS / etc. to the canonical OpenAI-style
      finish_reason strings the rest of PasClaw expects. }
    if Resp.FinishReason = 'STOP' then
    begin
      if Length(Resp.ToolCalls) > 0 then Resp.FinishReason := 'tool_calls'
                                    else Resp.FinishReason := 'stop';
    end
    else if Resp.FinishReason = 'MAX_TOKENS' then
      Resp.FinishReason := 'length'
    else if (Resp.FinishReason <> '') and (Length(Resp.ToolCalls) > 0) then
      Resp.FinishReason := 'tool_calls';

    Usage := Obj.ChildObject('usageMetadata');
    if Usage <> nil then
    try
      Resp.Usage.InputTokens  := Usage.GetInt('promptTokenCount',     0);
      Resp.Usage.OutputTokens := Usage.GetInt('candidatesTokenCount', 0);
    finally
      Usage.Free;
    end;
  finally
    Obj.Free;
  end;
end;

function TGeminiProvider.Chat(const Messages: array of TMessage;
                              const Tools:    array of TToolDefinition;
                              const Model:    string;
                              const Options:  TChatOptions): TLLMResponse;
var
  Body, URL, UseModel: string;
  Resp: THTTPResult;
  Headers: array of THeaderPair;
begin
  if Model <> '' then UseModel := Model else UseModel := FDefaultModel;
  URL  := FAPIBase + '/v1beta/models/' + UseModel + ':generateContent';
  Body := BuildRequest(Messages, Tools, UseModel, Options, FServerTools);

  SetLength(Headers, 1);
  Headers[0] := MakeHeader('x-goog-api-key', FAPIKey);

  LogDebug('gemini POST %s (model=%s, body=%d bytes)', [URL, UseModel, Length(Body)]);
  Resp := PostJSON(URL, Body, Headers, 120);

  Result.Content := '';
  Result.StatusCode := Resp.StatusCode;
  SetLength(Result.ToolCalls, 0);
  if (Resp.StatusCode >= 200) and (Resp.StatusCode < 300) then
  begin
    ParseResponse(Resp.Body, Result);
    Exit;
  end;

  if Resp.Body <> '' then
    Result.Content := Format('gemini error %d: %s', [Resp.StatusCode, Resp.Body])
  else
    Result.Content := Format('gemini error: status=%d msg=%s', [Resp.StatusCode, Resp.ErrorMsg]);
  Result.FinishReason := 'error';
end;

function TGeminiProvider.ChatStream(const Messages: array of TMessage;
                                    const Tools:    array of TToolDefinition;
                                    const Model:    string;
                                    const Options:  TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
var
  C: TStreamChunk;
begin
  Result := Chat(Messages, Tools, Model, Options);
  if Assigned(OnChunk) then
  begin
    C.Kind := 'text'; C.Text := Result.Content; OnChunk(C);
    C.Kind := 'done'; C.Text := '';             OnChunk(C);
  end;
end;

end.
