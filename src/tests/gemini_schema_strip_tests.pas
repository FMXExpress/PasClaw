program gemini_schema_strip_tests;
(*
  Covers SanitizeSchemaForGemini -- the wire-boundary scrub that lets
  Gemini accept tool schemas containing additionalProperties (and
  other JSON-Schema-but-not-OpenAPI-3.0 fields) that MCP servers and
  external skill manifests emit.

  Test 1 reproduces the exact 400 shape the user hit and asserts
  the unsupported fields are gone while the legitimate ones survive.

  Test 2 covers Codex P2 on PR #153 -- a tool parameter literally
  named "additionalProperties" must NOT be dropped by the walker.
  The original blind-recursion walker treated the `properties` map
  as a schema node and would strip user-defined keys colliding with
  schema keywords. The schema-aware walker only strips on schema
  nodes, never on the properties name->schema map itself.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Gemini,
  PasClaw.Session.Store,
  PasClaw.JSON;

procedure Fail(const Msg, Body: string);
begin
  WriteLn('FAIL: ' + Msg);
  WriteLn('--- body ---');
  WriteLn(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected substring: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail(Msg + ' (did NOT expect substring: ' + Needle + ')', Haystack);
end;

procedure TestRejectedFieldsScrubbed;
const
  { Same shape as the user's reported 400 -- additionalProperties at
    two nesting levels plus $schema meta. }
  Bad =
    '{' +
      '"type":"object",' +
      '"properties":{' +
        '"url":{"type":"string"},' +
        '"options":{' +
          '"type":"object",' +
          '"properties":{"timeout":{"type":"integer"}},' +
          '"additionalProperties":false' +
        '}' +
      '},' +
      '"required":["url"],' +
      '"additionalProperties":false,' +
      '"$schema":"http://json-schema.org/draft-07/schema#"' +
    '}';
var
  Out_: string;
begin
  Out_ := SanitizeSchemaForGemini(Bad);
  AssertMissing(Out_, 'additionalProperties', 'additionalProperties stripped');
  AssertMissing(Out_, '$schema',              '$schema stripped');
  AssertContains(Out_, '"url"',               'url property survives');
  AssertContains(Out_, '"timeout"',           'nested timeout survives');
  AssertContains(Out_, '"required"',          'required[] survives');
end;

procedure TestUserPropertyNamedAdditionalPropertiesSurvives;
const
  { Two layers of trickery:
      - A schema KEYWORD additionalProperties at the top level
        (should be stripped).
      - A user PROPERTY literally named additionalProperties inside
        the `properties` map (must NOT be stripped -- it's a tool
        parameter name).
      - Same trap for $schema and $ref as user property names. }
  Bad =
    '{' +
      '"type":"object",' +
      '"properties":{' +
        '"additionalProperties":{"type":"boolean","description":"user property"},' +
        '"$schema":{"type":"string"},' +
        '"$ref":{"type":"string"},' +
        '"normal":{"type":"integer"}' +
      '},' +
      '"additionalProperties":false,' +
      '"$schema":"http://json-schema.org/draft-07/schema#"' +
    '}';
var
  Out_: string;
begin
  Out_ := SanitizeSchemaForGemini(Bad);

  { The user PROPERTIES survive even though they share names with
    schema keywords. Match on the description / type tag we put
    inside their schemas -- the bare key text "additionalProperties"
    can match either the property name OR the schema keyword, so we
    pin the assertion on a sibling that only exists if the property
    schema was preserved. }
  AssertContains(Out_, '"description" : "user property"',
    'user property named "additionalProperties" survives');
  AssertContains(Out_, '"normal"', 'normal property survives');

  { Top-level schema keywords ARE stripped -- we proved that in test 1.
    Here, prove there are no instances of additionalProperties:false
    or $schema as a URL (the keyword forms) left, while accepting
    that "additionalProperties" as a key name in the properties map
    is allowed. }
  AssertMissing(Out_, ':false', 'top-level additionalProperties:false stripped');
  AssertMissing(Out_, 'json-schema.org', '$schema URL keyword stripped');
end;

procedure TestEmptyAndMalformed;
begin
  if SanitizeSchemaForGemini('') <> '' then
    Fail('empty input should round-trip as empty', SanitizeSchemaForGemini(''));
  { Malformed JSON: walker returns input verbatim so Gemini's own
    400 with field pointer surfaces, instead of a silent drop. }
  if SanitizeSchemaForGemini('not json') <> 'not json' then
    Fail('malformed input should round-trip verbatim',
         SanitizeSchemaForGemini('not json'));
end;

procedure TestThoughtSignatureRoundTrip;
{ Gemini 3+ requires the assistant turn to carry the thoughtSignature
  back on the part. Verify that when a TToolCall has ProviderSignature
  set, BuildRequest emits "thoughtSignature": "<value>" as a sibling
  of "functionCall" inside the part. Without this, Gemini 3 rejects
  the follow-up with 400 "Function call is missing a thought_signature
  in functionCall parts". }
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 3);
  { user turn }
  Msgs[0] := MakeMessage(mrUser, 'list pwd');
  { assistant turn with a tool call carrying the signature }
  Msgs[1].Role := mrAssistant;
  Msgs[1].Content := '';
  SetLength(Msgs[1].ToolCalls, 1);
  Msgs[1].ToolCalls[0].Id   := 'gemini_call_fs_list_0';
  Msgs[1].ToolCalls[0].Kind := 'function';
  Msgs[1].ToolCalls[0].Func.Name      := 'fs_list';
  Msgs[1].ToolCalls[0].Func.Arguments := '{"path":"."}';
  Msgs[1].ToolCalls[0].ProviderSignature := 'SIG_AAA_BBB_OPAQUE_BLOB';
  { tool result echoed back as a user/tool turn -- Gemini path }
  Msgs[2].Role       := mrTool;
  Msgs[2].ToolCallId := 'gemini_call_fs_list_0';
  Msgs[2].Content    := '[".", "..", "README.md"]';
  Msgs[2].Name       := 'fs_list';

  SetLength(Tools, 0);
  Opts := DefaultChatOptions;
  Body := BuildRequest(Msgs, Tools, 'gemini-3.5-flash', Opts);

  { The signature must be on the wire body, verbatim. }
  AssertContains(Body, '"thoughtSignature"',
    'thoughtSignature key emitted on assistant turn');
  AssertContains(Body, 'SIG_AAA_BBB_OPAQUE_BLOB',
    'thoughtSignature value preserved verbatim');
  AssertContains(Body, '"functionCall"',
    'functionCall still emitted alongside thoughtSignature');
  AssertContains(Body, '"fs_list"',
    'function name preserved');
end;

procedure TestNoSignatureWhenEmpty;
{ Gemini 2.x doesn't require thoughtSignature. When ProviderSignature
  is empty (the common case for non-Gemini-3 paths), BuildRequest must
  NOT emit an empty "thoughtSignature":"" field -- that's invalid wire
  shape. }
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'hi');
  Msgs[1].Role := mrAssistant;
  Msgs[1].Content := '';
  SetLength(Msgs[1].ToolCalls, 1);
  Msgs[1].ToolCalls[0].Id   := 'gemini_call_x_0';
  Msgs[1].ToolCalls[0].Kind := 'function';
  Msgs[1].ToolCalls[0].Func.Name := 'x';
  Msgs[1].ToolCalls[0].Func.Arguments := '{}';
  Msgs[1].ToolCalls[0].ProviderSignature := '';   { Gemini 2 path }

  SetLength(Tools, 0);
  Opts := DefaultChatOptions;
  Body := BuildRequest(Msgs, Tools, 'gemini-1.5-flash', Opts);

  AssertMissing(Body, '"thoughtSignature"',
    'no thoughtSignature key when ProviderSignature is empty');
  AssertContains(Body, '"functionCall"',
    'functionCall still emitted normally');
end;

procedure TestSessionPersistenceRoundTrip;
{ Codex P2 on PR #154: a session saved mid-Gemini-3-tool-loop must
  keep the thoughtSignature on disk, otherwise resume drops it and
  the next provider request 400s. Round-trip a TToolCall through
  ToolCallToJSON / ToolCallFromJSON and assert ProviderSignature
  survives. }
var
  TC, Restored: TToolCall;
  Obj, Reparsed: TJsonObject;
  Body: string;
begin
  TC.Id   := 'gemini_call_fs_list_0';
  TC.Kind := 'function';
  TC.Func.Name      := 'fs_list';
  TC.Func.Arguments := '{"path":"."}';
  TC.ProviderSignature := 'SIG_PERSIST_THIS_BLOB';

  Obj := ToolCallToJSON(TC);
  try
    Body := Obj.ToJSON;
    AssertContains(Body, '"provider_signature"',
      'session writer emits provider_signature key');
    AssertContains(Body, 'SIG_PERSIST_THIS_BLOB',
      'session writer preserves the blob verbatim');
  finally
    Obj.Free;
  end;

  Reparsed := TJsonObject.Parse(Body);
  if Reparsed = nil then
    Fail('reparse of session JSON failed', Body);
  try
    ToolCallFromJSON(Reparsed, Restored);
  finally
    Reparsed.Free;
  end;

  if Restored.ProviderSignature <> TC.ProviderSignature then
    Fail('session reader did NOT restore ProviderSignature',
         'got "' + Restored.ProviderSignature +
         '", want "' + TC.ProviderSignature + '"');
  if Restored.Id <> TC.Id then
    Fail('Id did not round-trip', Restored.Id);
  if Restored.Func.Name <> TC.Func.Name then
    Fail('Func.Name did not round-trip', Restored.Func.Name);
end;

procedure TestSessionPersistenceEmpty;
{ Empty ProviderSignature must NOT add an empty key to the session
  file -- keeps stock session JSON tidy for non-Gemini-3 sessions
  (the common case) and round-trips back to empty. }
var
  TC, Restored: TToolCall;
  Obj, Reparsed: TJsonObject;
  Body: string;
begin
  TC.Id   := 'call_x';
  TC.Kind := 'function';
  TC.Func.Name      := 'x';
  TC.Func.Arguments := '{}';
  TC.ProviderSignature := '';

  Obj := ToolCallToJSON(TC);
  try
    Body := Obj.ToJSON;
    AssertMissing(Body, 'provider_signature',
      'empty ProviderSignature omitted from session JSON');
  finally
    Obj.Free;
  end;

  Reparsed := TJsonObject.Parse(Body);
  if Reparsed = nil then Fail('reparse failed', Body);
  try
    ToolCallFromJSON(Reparsed, Restored);
  finally
    Reparsed.Free;
  end;
  if Restored.ProviderSignature <> '' then
    Fail('empty signature did not round-trip empty', Restored.ProviderSignature);
end;

procedure TestGoogleSearchEmittedWhenEnabled;
(* ServerTools.GoogleSearch=True puts a tools[] entry whose key is
   "google_search" with an empty-object value into the request body.
   Coexists with the caller's functionDeclarations entry when local
   tools are also registered. *)
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  ST:    TGeminiServerTools;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'what is the weather today');
  SetLength(Tools, 0);
  Opts := DefaultChatOptions;
  ST.GoogleSearch := True;

  Body := BuildRequest(Msgs, Tools, 'gemini-3.5-flash', Opts, ST);

  AssertContains(Body, '"tools"',
    'tools array emitted even when no local tools are registered');
  AssertContains(Body, '"google_search"',
    'google_search entry present when toggle is on');
end;

procedure TestGoogleSearchOmittedWhenDisabled;
{ NoGeminiServerTools (or any record with GoogleSearch=False) means
  no google_search entry, and with no local tools, no tools array
  at all -- Gemini 400s on an empty tools[]. }
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'hello');
  SetLength(Tools, 0);
  Opts := DefaultChatOptions;

  Body := BuildRequest(Msgs, Tools, 'gemini-3.5-flash', Opts,
                       NoGeminiServerTools);

  AssertMissing(Body, '"google_search"',
    'google_search omitted when toggle is off');
  AssertMissing(Body, '"tools"',
    'no tools array at all when neither server nor local tools present');
  AssertMissing(Body, '"tool_config"',
    'tool_config not emitted when there is no tool combo to gate');
end;

procedure TestGoogleSearchCoexistsWithFunctionDeclarations;
{ Gemini 3.x accepts both entries in the same tools array. Verify
  the wire body emits BOTH on a 3.x model. }
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  ST:    TGeminiServerTools;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'list files then search');
  SetLength(Tools, 1);
  Tools[0].Name        := 'fs_list';
  Tools[0].Description := 'list a directory';
  Tools[0].Schema      := '{"type":"object","properties":{"path":{"type":"string"}}}';
  Opts := DefaultChatOptions;
  ST.GoogleSearch := True;

  Body := BuildRequest(Msgs, Tools, 'gemini-3.5-flash', Opts, ST);

  AssertContains(Body, '"functionDeclarations"',
    'local tools still emitted under functionDeclarations');
  AssertContains(Body, '"fs_list"',
    'local tool name preserved');
  AssertContains(Body, '"google_search"',
    'google_search emitted alongside functionDeclarations on 3.x');
  (* The combo on 3.x additionally requires tool_config.include_server_side_tool_invocations
     or the API returns 400: "Please enable tool_config.include_server_side_tool_invocations
     to use Built-in tools with Function calling." *)
  AssertContains(Body, '"tool_config"',
    'tool_config block emitted when both tool categories present');
  AssertContains(Body, '"include_server_side_tool_invocations"',
    'include_server_side_tool_invocations field emitted for combo');
end;

procedure TestGoogleSearchSuppressedOnPreGemini3WithLocalTools;
(* Codex P2 on PR #158. Gemini 2.x rejects the
   google_search + functionDeclarations combo with a 400. Default-on
   would silently break every tool-using chat on a 2.x model.
   BuildRequest must suppress google_search this turn and keep the
   functionDeclarations the user explicitly registered. *)
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  ST:    TGeminiServerTools;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'list pwd');
  SetLength(Tools, 1);
  Tools[0].Name        := 'fs_list';
  Tools[0].Description := 'list a directory';
  Tools[0].Schema      := '{"type":"object","properties":{"path":{"type":"string"}}}';
  Opts := DefaultChatOptions;
  ST.GoogleSearch := True;

  Body := BuildRequest(Msgs, Tools, 'gemini-2.5-flash', Opts, ST);

  AssertContains(Body, '"functionDeclarations"',
    'local tools kept on 2.x -- they were the user''s explicit config');
  AssertContains(Body, '"fs_list"',
    'local tool name preserved on 2.x');
  AssertMissing(Body, '"google_search"',
    'google_search suppressed on 2.x when local tools present');
end;

procedure TestGoogleSearchEmittedOnPreGemini3WithoutLocalTools;
(* The suppression only applies to the combo. Bare google_search on
   2.x is a valid request -- keep emitting it so default-on grounding
   still works on 2.x for non-tool-loop conversations. *)
var
  Msgs:  TMessageArray;
  Tools: TToolDefinitionArray;
  Opts:  TChatOptions;
  ST:    TGeminiServerTools;
  Body:  string;
begin
  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'who won the world cup');
  SetLength(Tools, 0);
  Opts := DefaultChatOptions;
  ST.GoogleSearch := True;

  Body := BuildRequest(Msgs, Tools, 'gemini-2.5-flash', Opts, ST);

  AssertContains(Body, '"google_search"',
    'bare google_search still emitted on 2.x when no local tools present');
  AssertMissing(Body, '"functionDeclarations"',
    'no functionDeclarations entry when caller has no tools');
end;

begin
  TestRejectedFieldsScrubbed;
  TestUserPropertyNamedAdditionalPropertiesSurvives;
  TestEmptyAndMalformed;
  TestThoughtSignatureRoundTrip;
  TestNoSignatureWhenEmpty;
  TestSessionPersistenceRoundTrip;
  TestSessionPersistenceEmpty;
  TestGoogleSearchEmittedWhenEnabled;
  TestGoogleSearchOmittedWhenDisabled;
  TestGoogleSearchCoexistsWithFunctionDeclarations;
  TestGoogleSearchSuppressedOnPreGemini3WithLocalTools;
  TestGoogleSearchEmittedOnPreGemini3WithoutLocalTools;
  WriteLn('gemini_schema_strip_tests: OK');
end.
