program gemini_schema_strip_tests;
(*
  Covers SanitizeSchemaForGemini — the wire-boundary scrub that lets
  Gemini accept tool schemas containing additionalProperties (and
  other JSON-Schema-but-not-OpenAPI-3.0 fields) that MCP servers and
  external skill manifests emit.

  Test 1 reproduces the exact 400 shape the user hit and asserts
  the unsupported fields are gone while the legitimate ones survive.

  Test 2 covers Codex P2 on PR #153 — a tool parameter literally
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
  PasClaw.Providers.Gemini;

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
  { Same shape as the user's reported 400 — additionalProperties at
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
        the `properties` map (must NOT be stripped — it's a tool
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
    inside their schemas — the bare key text "additionalProperties"
    can match either the property name OR the schema keyword, so we
    pin the assertion on a sibling that only exists if the property
    schema was preserved. }
  AssertContains(Out_, '"description" : "user property"',
    'user property named "additionalProperties" survives');
  AssertContains(Out_, '"normal"', 'normal property survives');

  { Top-level schema keywords ARE stripped — we proved that in test 1.
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
  { tool result echoed back as a user/tool turn — Gemini path }
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
  NOT emit an empty "thoughtSignature":"" field — that's invalid wire
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

begin
  TestRejectedFieldsScrubbed;
  TestUserPropertyNamedAdditionalPropertiesSurvives;
  TestEmptyAndMalformed;
  TestThoughtSignatureRoundTrip;
  TestNoSignatureWhenEmpty;
  WriteLn('gemini_schema_strip_tests: OK');
end.
