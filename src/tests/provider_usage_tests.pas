program provider_usage_tests;
(*
  A provider's reply carries only the token counts the provider sent.

  Chat returns a record, and a record result is not cleared for the
  function: its plain fields hold whatever the caller's memory held. The
  OpenAI, Anthropic and Gemini Chat set only what the reply carried, so a
  call that failed came back with that memory as its token counts, and a
  good reply with no cache figures came back with it as its cache counts.
  The gateway and the CLI add a reply's counts to the stored totals:
  /v1/stats showed billions of tokens no provider had reported.

  Pinned here without a server:

    - each provider's Chat against a port nothing listens on: the call
      fails, and every counter of what it returns is zero. The destination
      is filled with a marker first and the stack is scribbled over before
      the call, so leftover memory is never zero by luck -- whichever way
      the compiler hands the result back.
    - ParseOAIResponse into a record that already holds counts: a body
      with usage but no cache details, a body with no usage, an empty body
      and a body with cache details each leave exactly what the body said.

  usage_stats_e2e.py holds the real gateway to the same rule over HTTP.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.OpenAI,
  PasClaw.Providers.Anthropic,
  PasClaw.Providers.Gemini;

const
  MARK = $5A5A5A5A;
  { Nothing listens on port 1: the connection is refused at once. }
  DEAD = 'http://127.0.0.1:1';

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

function UsageText(const U: TUsageInfo): string;
begin
  Result := Format('in=%d out=%d cache_read=%d cache_created=%d',
                   [U.InputTokens, U.OutputTokens, U.CacheReadTokens, U.CacheCreatedTokens]);
end;

procedure AssertUsage(const U: TUsageInfo; WantIn, WantOut, WantRead, WantNew: Integer;
                      const Msg: string);
begin
  if (U.InputTokens <> WantIn) or (U.OutputTokens <> WantOut) or
     (U.CacheReadTokens <> WantRead) or (U.CacheCreatedTokens <> WantNew) then
    Fail_(Format('%s: got %s, want in=%d out=%d cache_read=%d cache_created=%d',
                 [Msg, UsageText(U), WantIn, WantOut, WantRead, WantNew]));
end;

procedure Mark_(var R: TLLMResponse);
begin
  R := Default(TLLMResponse);
  R.Content := 'stale';
  R.Model := 'stale-model';
  R.FinishReason := 'stale';
  R.StatusCode := MARK;
  R.Usage.InputTokens := MARK;
  R.Usage.OutputTokens := MARK;
  R.Usage.CacheReadTokens := MARK;
  R.Usage.CacheCreatedTokens := MARK;
end;

{ Leaves the marker in the stack the next call's frame is built on, so a
  temporary the compiler makes for a record result does not start at zero. }
procedure ScribbleStack;
var
  Buf: array[0..32767] of Byte;
begin
  FillChar(Buf, SizeOf(Buf), $5A);
  if Buf[SizeOf(Buf) - 1] <> $5A then Fail_('scribble');   { keeps Buf alive }
end;

procedure FailedCall(const P: ILLMProvider; const Name: string);
var
  R: TLLMResponse;
  Msgs: array of TMessage;
begin
  SetLength(Msgs, 1);
  Msgs[0] := Default(TMessage);
  Msgs[0].Role := mrUser;
  Msgs[0].Content := 'hi';
  Mark_(R);
  R := P.Chat(Msgs, [], 'm', Default(TChatOptions));
  if (R.StatusCode >= 200) and (R.StatusCode < 300) then
    Fail_(Name + ': a call to a dead port answered ' + IntToStr(R.StatusCode));
  if R.StatusCode = Integer(MARK) then
    Fail_(Name + ': the status was never set');
  AssertUsage(R.Usage, 0, 0, 0, 0, Name + ': usage of a failed call');
  if R.Model <> '' then
    Fail_(Name + ': a failed call kept the model "' + R.Model + '" from before');
  if Length(R.ToolCalls) <> 0 then
    Fail_(Name + ': a failed call has tool calls');
  WriteLn('  ok: ', Name, ' -- a failed call reports no tokens (status ', R.StatusCode, ')');
end;

procedure TestFailedCalls;
var
  OpenAI, Anthropic, Gemini: ILLMProvider;
begin
  { Built first: a constructor run between the scribble and the call would
    leave its own leftovers where the call's frame goes. }
  OpenAI    := TOpenAIProvider.Create('sk-test', DEAD + '/v1', 'm');
  Anthropic := TAnthropicProvider.Create('k', DEAD, 'm', NoAnthropicServerTools);
  Gemini    := TGeminiProvider.Create('k', DEAD, 'm', NoGeminiServerTools);
  ScribbleStack;
  FailedCall(OpenAI, 'openai');
  ScribbleStack;
  FailedCall(Anthropic, 'anthropic');
  ScribbleStack;
  FailedCall(Gemini, 'gemini');
end;

procedure TestParseOAIResponse;
const
  REPLY = '"choices":[{"index":0,"finish_reason":"stop",' +
          '"message":{"role":"assistant","content":"hello"}}]';
var
  R: TLLMResponse;
begin
  Mark_(R);
  ParseOAIResponse('{"model":"m",' + REPLY +
                   ',"usage":{"prompt_tokens":11,"completion_tokens":7}}', R);
  if R.Content <> 'hello' then Fail_('parse: content "' + R.Content + '"');
  AssertUsage(R.Usage, 11, 7, 0, 0, 'parse: usage with no cache details');

  Mark_(R);
  ParseOAIResponse('{"model":"m",' + REPLY + '}', R);
  AssertUsage(R.Usage, 0, 0, 0, 0, 'parse: a reply with no usage');

  Mark_(R);
  ParseOAIResponse('', R);
  AssertUsage(R.Usage, 0, 0, 0, 0, 'parse: an empty body');

  Mark_(R);
  ParseOAIResponse('{"model":"m",' + REPLY +
                   ',"usage":{"prompt_tokens":11,"completion_tokens":7,' +
                   '"prompt_tokens_details":{"cached_tokens":5}}}', R);
  AssertUsage(R.Usage, 11, 7, 5, 0, 'parse: usage with cache details');
  WriteLn('  ok: ParseOAIResponse leaves exactly the counts the body carried');
end;

begin
  TestFailedCalls;
  TestParseOAIResponse;
  WriteLn('ok - provider usage tests passed');
end.
