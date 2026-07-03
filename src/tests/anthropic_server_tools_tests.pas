program anthropic_server_tools_tests;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Anthropic;

procedure Fail(const Msg, Body: string);
begin
  Writeln('FAIL: ' + Msg);
  Writeln('--- body ---');
  Writeln(Body);
  Halt(1);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) = 0 then
    Fail(Msg + ' (expected to find: ' + Needle + ')', Haystack);
end;

procedure AssertMissing(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail(Msg + ' (did NOT expect: ' + Needle + ')', Haystack);
end;

function OneUserMessage(const Text: string): TMessageArray;
begin
  SetLength(Result, 1);
  Result[0] := MakeMessage(mrUser, Text);
end;

function NoUserTools: TToolDefinitionArray;
begin
  SetLength(Result, 0);
end;

function UserTool(const Name, Desc, Schema: string): TToolDefinition;
begin
  Result.Name        := Name;
  Result.Description := Desc;
  Result.Schema      := Schema;
end;

procedure TestNoServerTools;
var
  Opts: TChatOptions;
  Body: string;
begin
  Opts := DefaultChatOptions;
  Opts.CacheEnabled := False;
  Body := BuildRequest(OneUserMessage('hi'), NoUserTools, 'claude-opus-4-7',
                       Opts, NoAnthropicServerTools);
  AssertMissing(Body, '"web_search_20260209"', 'no server tools by default');
  AssertMissing(Body, '"web_fetch_20260209"',  'no server tools by default');
  AssertMissing(Body, '"tools"',               'no tools key when nothing registered');
end;

procedure TestServerWebSearchOnly;
var
  Opts: TChatOptions;
  Body: string;
  ST: TAnthropicServerTools;
begin
  Opts := DefaultChatOptions;
  Opts.CacheEnabled := False;
  ST := NoAnthropicServerTools;
  ST.WebSearch := True;

  Body := BuildRequest(OneUserMessage('hi'), NoUserTools, 'claude-opus-4-7',
                       Opts, ST);
  AssertContains(Body, '"tools"',                'tools array emitted');
  AssertContains(Body, '"type" : "web_search_20260209"', 'web_search type id');
  AssertContains(Body, '"name" : "web_search"',    'web_search name');
  AssertMissing(Body, '"web_fetch_20260209"',    'web_fetch off when not enabled');
  AssertMissing(Body, '"max_uses"',              'no max_uses when unset');
end;

procedure TestServerToolsBoth;
var
  Opts: TChatOptions;
  Body: string;
  ST: TAnthropicServerTools;
begin
  Opts := DefaultChatOptions;
  Opts.CacheEnabled := False;
  ST := NoAnthropicServerTools;
  ST.WebSearch        := True;
  ST.WebSearchMaxUses := 3;
  ST.WebFetch         := True;
  ST.WebFetchMaxUses  := 5;

  Body := BuildRequest(OneUserMessage('hi'), NoUserTools, 'claude-opus-4-7',
                       Opts, ST);
  AssertContains(Body, '"type" : "web_search_20260209"', 'web_search type id');
  AssertContains(Body, '"type" : "web_fetch_20260209"',  'web_fetch type id');
  AssertContains(Body, '"max_uses" : 3',                  'web_search max_uses');
  AssertContains(Body, '"max_uses" : 5',                  'web_fetch max_uses');
end;

procedure TestUserToolNameCollisionDropped;
var
  Opts: TChatOptions;
  Body: string;
  ST: TAnthropicServerTools;
  Tools: TToolDefinitionArray;
begin
  Opts := DefaultChatOptions;
  Opts.CacheEnabled := False;
  ST := NoAnthropicServerTools;
  ST.WebSearch := True;
  ST.WebFetch  := True;

  SetLength(Tools, 3);
  Tools[0] := UserTool('fs_read',    'read a file', '{"type":"object"}');
  Tools[1] := UserTool('web_search', 'should be dropped', '{"type":"object"}');
  Tools[2] := UserTool('web_fetch',  'should be dropped', '{"type":"object"}');

  Body := BuildRequest(OneUserMessage('hi'), Tools, 'claude-opus-4-7',
                       Opts, ST);
  { fs_read survives, the colliders are dropped, the server entries
    take their place. The "should be dropped" description proves the
    user entry was removed -- Anthropic would otherwise see two tools
    named "web_search" and 400. }
  AssertContains(Body, '"name" : "fs_read"',           'non-colliding user tool kept');
  AssertContains(Body, '"type" : "web_search_20260209"', 'server web_search emitted');
  AssertContains(Body, '"type" : "web_fetch_20260209"',  'server web_fetch emitted');
  AssertMissing(Body, 'should be dropped',           'colliding user tools dropped');
end;

procedure TestContinuePausedTurnAppendsAssistantBlock;
const
  ReqBody  =
    '{"model":"claude-opus-4-7","max_tokens":8192,' +
    '"messages":[{"role":"user","content":[{"type":"text","text":"hi"}]}]}';
  RespBody =
    '{"id":"msg_1","model":"claude-opus-4-7","stop_reason":"pause_turn",' +
    '"content":[' +
      '{"type":"text","text":"searching..."},' +
      '{"type":"server_tool_use","id":"srvtoolu_1","name":"web_search","input":{"query":"CVE.org"}}' +
    ']}';
var
  Next: string;
begin
  Next := ContinuePausedTurn(ReqBody, RespBody);
  if Next = '' then
    Fail('ContinuePausedTurn returned empty for valid input', RespBody);

  { Original user turn survives. }
  AssertContains(Next, '"role" : "user"', 'user turn preserved');
  AssertContains(Next, '"text" : "hi"',   'user text preserved');

  { New assistant turn carries the response content verbatim -- both the
    text block and the server_tool_use block -- so Anthropic's server-
    side loop sees the trailing server_tool_use and resumes. }
  AssertContains(Next, '"role" : "assistant"', 'assistant turn appended');
  AssertContains(Next, '"server_tool_use"',    'server_tool_use preserved verbatim');
  AssertContains(Next, '"srvtoolu_1"',         'server tool id preserved');
  AssertContains(Next, 'searching',            'in-flight text preserved');

  { Top-level model + max_tokens still present so the body is a valid
    /v1/messages POST, not just a fragment. }
  AssertContains(Next, '"max_tokens" : 8192', 'request scaffolding preserved');
end;

procedure TestContinuePausedTurnHandlesMalformedInput;
var
  Next: string;
begin
  Next := ContinuePausedTurn('not json',   '{"content":[]}');
  if Next <> '' then Fail('expected empty result on malformed request body', Next);

  Next := ContinuePausedTurn('{"messages":[]}', 'not json');
  if Next <> '' then Fail('expected empty result on malformed response body', Next);
end;

procedure TestMaxTokensFloorAndOverride;
{ max_tokens is required by Anthropic, so a 0 ("provider default") must be
  substituted with the floor (8192); an explicit value passes through. }
var
  Opts: TChatOptions;
  Body: string;
begin
  Opts := DefaultChatOptions;
  Opts.CacheEnabled := False;
  if Opts.MaxTokens <> 0 then
    Fail('DefaultChatOptions should leave max_tokens unset (0)', IntToStr(Opts.MaxTokens));
  Body := BuildRequest(OneUserMessage('hi'), NoUserTools, 'claude-opus-4-7',
                       Opts, NoAnthropicServerTools);
  AssertContains(Body, '"max_tokens" : 8192',
    'unset max_tokens substitutes the floor for the required Anthropic field');

  Opts.MaxTokens := 32000;
  Body := BuildRequest(OneUserMessage('hi'), NoUserTools, 'claude-opus-4-7',
                       Opts, NoAnthropicServerTools);
  AssertContains(Body, '"max_tokens" : 32000',
    'an explicit max_tokens override is honoured verbatim');
end;

begin
  TestNoServerTools;
  TestServerWebSearchOnly;
  TestServerToolsBoth;
  TestUserToolNameCollisionDropped;
  TestContinuePausedTurnAppendsAssistantBlock;
  TestContinuePausedTurnHandlesMalformedInput;
  TestMaxTokensFloorAndOverride;
  Writeln('anthropic_server_tools_tests: OK');
end.
