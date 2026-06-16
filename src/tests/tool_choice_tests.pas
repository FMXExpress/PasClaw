program tool_choice_tests;
(*
  Pins tool_choice emission across the keyword forms AND the
  force-a-specific-tool form. The gap this guards: the named-function
  tool_choice ({"type":"function","function":{"name":...}}) used to be
  dropped, so a client could not force a specific tool. By convention any
  non-keyword ToolChoice value is a tool NAME; each provider emits its
  native object shape (OpenAI type=function, Anthropic type=tool).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.OpenAI,
  PasClaw.Providers.Anthropic;

procedure Fail_(const Msg, Body: string);
begin
  WriteLn('FAIL: ' + Msg);
  WriteLn('--- body ---'); WriteLn(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then Fail_(Msg + ' (want: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then Fail_(Msg + ' (did NOT expect: ' + Needle + ')', Haystack);
end;

function OneUser: TMessageArray;
begin
  SetLength(Result, 1);
  Result[0] := MakeMessage(mrUser, 'hi');
end;

function OneTool: TToolDefinitionArray;
begin
  SetLength(Result, 1);
  Result[0].Name        := 'get_weather';
  Result[0].Description := 'look up the weather';
  Result[0].Schema      := '{"type":"object","properties":{}}';
end;

var
  Opts: TChatOptions;
  Body: string;
begin
  { ---- OpenAI ---- }
  { keyword form stays a plain string (NB: the tools array always carries
    "function", so we assert on the tool_choice VALUE specifically). }
  Opts := DefaultChatOptions; Opts.ToolChoice := 'required';
  Body := BuildOAIRequest(OneUser, OneTool, 'gpt-4o', Opts, NoOpenAIServerTools);
  AssertContains(Body, '"tool_choice" : "required"', 'openai: required is the string form');
  AssertMissing(Body, '"tool_choice" : {', 'openai: required is NOT the object form');

  { named form -> object: type=function with function.name }
  Opts := DefaultChatOptions; Opts.ToolChoice := 'get_weather';
  Body := BuildOAIRequest(OneUser, OneTool, 'gpt-4o', Opts, NoOpenAIServerTools);
  AssertContains(Body, '"tool_choice" : {', 'openai: named is the object form');
  AssertContains(Body, 'get_weather',       'openai: named carries the function name');

  { empty -> no tool_choice }
  Opts := DefaultChatOptions; Opts.ToolChoice := '';
  Body := BuildOAIRequest(OneUser, OneTool, 'gpt-4o', Opts, NoOpenAIServerTools);
  AssertMissing(Body, '"tool_choice"', 'openai: empty omits tool_choice');

  { ---- Anthropic ---- }
  { keyword: required -> type=any }
  Opts := DefaultChatOptions; Opts.ToolChoice := 'required';
  Body := BuildRequest(OneUser, OneTool, 'claude-opus-4-7', Opts, NoAnthropicServerTools);
  AssertContains(Body, '"tool_choice"', 'anthropic: required emits tool_choice');
  AssertContains(Body, '"type" : "any"', 'anthropic: required maps to any');

  { named -> object: type=tool with name }
  Opts := DefaultChatOptions; Opts.ToolChoice := 'get_weather';
  Body := BuildRequest(OneUser, OneTool, 'claude-opus-4-7', Opts, NoAnthropicServerTools);
  AssertContains(Body, '"type" : "tool"', 'anthropic: named maps to type=tool');
  AssertContains(Body, 'get_weather', 'anthropic: named carries the tool name');

  { empty -> no tool_choice }
  Opts := DefaultChatOptions; Opts.ToolChoice := '';
  Body := BuildRequest(OneUser, OneTool, 'claude-opus-4-7', Opts, NoAnthropicServerTools);
  AssertMissing(Body, '"tool_choice"', 'anthropic: empty omits tool_choice');

  WriteLn('tool_choice_tests: OK');
end.
