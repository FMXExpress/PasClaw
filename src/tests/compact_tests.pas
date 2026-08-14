program compact_tests;
(*
  Pins PasClaw.Agent.Compact: conversation-history compaction.

  The properties worth breaking the build over:

    1. The summary is a ROLLING RECORD. Compacting twice must leave
       exactly ONE "[Conversation summary so far]" block in the system
       prompt, and the second summariser call must have received the
       first summary as input -- otherwise repeat compactions stack
       blocks the trigger never counts, and each new summary silently
       forgets everything before the previous one.
    2. A tool_call / tool_result group is never split across the cut.
       A tail that opens with an orphaned tool_result is a 400 on both
       Anthropic and OpenAI.
    3. Retention is a token budget with a message-count floor. Eight
       fat tool results are not "recent context" just because eight is
       the configured count -- and one giant message must not shrink
       the tail to nothing.
    4. Every failure returns the history verbatim. A broken summariser
       can never wipe live context.
    5. Config defaults equal code defaults -- the call sites pass
       TCompactionConfig values into TCompactOptions, and two
       disagreeing defaults would make behaviour depend on which path
       built the options.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Agent.Compact,
  PasClaw.Config;

var Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectEq(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(Got) + ', want ' + IntToStr(Want));
end;

procedure ExpectHas(const Hay, Needle, Msg: string);
begin
  if Pos(Needle, Hay) = 0 then
    Fail_(Msg + ' -- "' + Needle + '" missing from: ' + Copy(Hay, 1, 300));
end;

function CountOf(const Hay, Needle: string): Integer;
var
  P: Integer;
begin
  Result := 0;
  P := Pos(Needle, Hay);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(Needle, Copy(Hay, P + Length(Needle), MaxInt));
    { Pos on the copy is relative; only the count matters here. }
  end;
end;

type
  { A provider that answers every Chat with a canned summary and
    remembers what it was asked. Failing mode: raises instead. }
  TStubProvider = class(TInterfacedObject, ILLMProvider)
  public
    Reply:      string;
    RaiseIt:    Boolean;
    Calls:      Integer;
    LastPrompt: string;
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TStubProvider.Chat(const Messages: array of TMessage;
                            const Tools: array of TToolDefinition;
                            const Model: string;
                            const Options: TChatOptions): TLLMResponse;
begin
  Inc(Calls);
  if Length(Messages) > 0 then
    LastPrompt := Messages[0].Content
  else
    LastPrompt := '';
  if RaiseIt then
    raise Exception.Create('stub says no');
  Result := Default(TLLMResponse);
  Result.Content := Reply;
  Result.StatusCode := 200;
end;

function TStubProvider.GetDefaultModel: string; begin Result := 'stub-1'; end;
function TStubProvider.GetName: string;         begin Result := 'stub';   end;
function TStubProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TStubProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TStubProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TStubProvider.ChatStream(const Messages: array of TMessage;
                                  const Tools: array of TToolDefinition;
                                  const Model: string;
                                  const Options: TChatOptions;
                                  OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

{ A body of N alternating user/assistant messages, each Chars long, so
  token estimates are predictable (~Chars/4 each). }
function MakeBody(N, Chars: Integer): TMessageArray;
var
  i: Integer;
  R: TMsgRole;
begin
  SetLength(Result, N);
  for i := 0 to N - 1 do
  begin
    if i mod 2 = 0 then R := mrUser else R := mrAssistant;
    Result[i] := MakeMessage(R, 'msg' + IntToStr(i) + ' ' +
                                StringOfChar('x', Chars));
  end;
end;

var
  Stub:     TStubProvider;
  Provider: ILLMProvider;
  Opts:     TCompactOptions;
  ChatOpts: TChatOptions;
  Msgs, Tail: TMessageArray;
  Cfg:      TConfig;
  Def:      TCompactOptions;
  i: Integer;
begin
  { -------------------------------------------------- the trigger -- }
  Msgs := MakeBody(4, 40);
  ExpectTrue(not NeedsCompact(Msgs, '', 1000),
             'a small history does not trip the threshold');
  ExpectTrue(NeedsCompact(Msgs, '', 20),
             'a large one does');
  ExpectTrue(NeedsCompact(Msgs, StringOfChar('s', 4000), 1000),
             'the system prompt counts toward the trigger -- the summary ' +
             'lives there and must not be invisible to it');
  ExpectTrue(not NeedsCompact(Msgs, StringOfChar('s', 4000), 0),
             'threshold 0 disables the feature entirely');

  { -------------------------------------- the overflow classifier -- }
  ExpectTrue(IsContextOverflowError(400,
             '{"error":{"message":"prompt is too long: 210000 tokens > 200000 maximum"}}'),
             'Anthropic wording classifies');
  ExpectTrue(IsContextOverflowError(400,
             '{"error":{"code":"context_length_exceeded"}}'),
             'OpenAI code classifies');
  ExpectTrue(IsContextOverflowError(400,
             'The input token count (1200000) exceeds the maximum'),
             'Gemini wording classifies');
  ExpectTrue(not IsContextOverflowError(200, 'prompt is too long'),
             'a 2xx is never an overflow, whatever the body says');
  ExpectTrue(not IsContextOverflowError(400, 'invalid api key'),
             'an unrelated 400 does not classify');
  ExpectTrue(not IsContextOverflowError(429, 'rate limit exceeded'),
             'a rate limit is not an overflow -- "exceeded" alone must ' +
             'not match');

  { ------------------------------------------- the rolling record -- }
  Stub := TStubProvider.Create;
  Provider := Stub;           { interface ref owns it from here }
  Stub.Reply := 'first summary: the user wants a parser.';

  Opts := DefaultCompactOptions;
  Opts.ThresholdTokens := 1;
  Opts.KeepRecentTurns := 2;
  Opts.RetainBudgetTokens := 0;   { count-driven for determinism here }
  ChatOpts := DefaultChatOptions;
  ChatOpts.SystemPrompt := 'You are a test agent.';

  Msgs := MakeBody(10, 40);
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 2, 'first compaction keeps the floor');
  ExpectEq(CountOf(ChatOpts.SystemPrompt, '[Conversation summary so far]'), 1,
           'one summary block after one compaction');
  ExpectHas(ChatOpts.SystemPrompt, 'You are a test agent.',
            'the base prompt survives');
  ExpectHas(ChatOpts.SystemPrompt, 'first summary',
            'and carries the summary');
  ExpectHas(Stub.LastPrompt, 'Goal:',
            'the summariser is asked for the sectioned record');

  { Compact AGAIN on top of the compacted state. }
  Stub.Reply := 'second summary: parser built, tests pending.';
  SetLength(Msgs, 0);
  Msgs := MakeBody(10, 40);
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(CountOf(ChatOpts.SystemPrompt, '[Conversation summary so far]'), 1,
           'STILL one summary block after two -- replace, not append');
  ExpectHas(ChatOpts.SystemPrompt, 'second summary',
            'the block carries the new record');
  ExpectTrue(Pos('first summary', ChatOpts.SystemPrompt) = 0,
             'the old record is out of the prompt...');
  ExpectHas(Stub.LastPrompt, 'first summary',
            '...because it went INTO the summariser input instead');
  ExpectHas(ChatOpts.SystemPrompt, 'You are a test agent.',
            'the base prompt survives repeat compactions');

  { ------------------------------- caller system messages, verbatim -- }
  ChatOpts := DefaultChatOptions;   { gateway shape: no SystemPrompt }
  SetLength(Msgs, 0);
  Msgs := MakeBody(10, 40);
  SetLength(Msgs, 11);
  for i := 10 downto 1 do Msgs[i] := Msgs[i - 1];
  Msgs[0] := MakeMessage(mrSystem, 'POLICY: never delete files.');
  Stub.Reply := 'sum';
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectHas(ChatOpts.SystemPrompt, 'POLICY: never delete files.',
            'a leading mrSystem message moves to the prompt bit-for-bit');
  ExpectTrue(Pos('POLICY', Stub.LastPrompt) = 0,
             'and is never shown to the summariser');
  for i := 0 to High(Tail) do
    ExpectTrue(Tail[i].Role <> mrSystem,
               'no mrSystem entries survive in the returned tail');

  { -------------------------------------- tool-boundary safety ------ }
  SetLength(Msgs, 0);
  Msgs := MakeBody(10, 40);
  Msgs[8].Role := mrTool;   { cut at 10-2=8 would orphan this }
  Msgs[9].Role := mrTool;
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectTrue((Length(Tail) = 0) or (Tail[0].Role <> mrTool),
             'the tail never opens with an orphaned tool_result');

  { ------------------------------ retention budget, and its floor -- }
  Opts.KeepRecentTurns := 2;
  Opts.RetainBudgetTokens := 500;
  { 12 small messages (~13 tokens each): the budget holds far more
    than the 2-message floor, so the cut moves EARLIER. }
  SetLength(Msgs, 0);
  Msgs := MakeBody(12, 40);
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectTrue(Length(Tail) > 2,
             'a small tail keeps more than the floor (got ' +
             IntToStr(Length(Tail)) + ')');

  { 12 fat messages (~500 tokens each): the budget would keep zero or
    one; the floor holds the tail at 2. }
  SetLength(Msgs, 0);
  Msgs := MakeBody(12, 2000);
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 2,
           'a fat tail is cut to the floor, not below it');

  { ------------------------------------------ verbatim on failure -- }
  SetLength(Msgs, 0);
  Msgs := MakeBody(10, 40);
  ChatOpts := DefaultChatOptions;
  ChatOpts.SystemPrompt := 'base';
  Stub.RaiseIt := True;
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 10, 'a raising summariser returns verbatim');
  ExpectTrue(ChatOpts.SystemPrompt = 'base',
             'and leaves the system prompt untouched');
  Stub.RaiseIt := False;

  Stub.Reply := '   ';
  SetLength(Msgs, 0);
  Msgs := MakeBody(10, 40);
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 10, 'an empty summary returns verbatim');
  ExpectTrue(ChatOpts.SystemPrompt = 'base',
             'without touching the prompt either');

  Tail := CompactMessages(nil, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 10, 'no provider returns verbatim');

  SetLength(Msgs, 0);
  Msgs := MakeBody(3, 40);
  Stub.Reply := 'sum';
  Tail := CompactMessages(Provider, 'stub-1', Msgs, ChatOpts, Opts);
  ExpectEq(Length(Tail), 3, 'a body at the floor is not sliced');

  { ------------------------- config defaults match code defaults -- }
  Cfg := TConfig.Create;   { constructor applies the defaults }
  Def := DefaultCompactOptions;
  ExpectTrue(Cfg.Compaction.Enabled, 'compaction is on by default');
  ExpectEq(Cfg.Compaction.ThresholdTokens,    Def.ThresholdTokens,
           'config threshold default = code default');
  ExpectEq(Cfg.Compaction.RetainBudgetTokens, Def.RetainBudgetTokens,
           'config retention default = code default');
  ExpectEq(Cfg.Compaction.KeepRecentTurns,    Def.KeepRecentTurns,
           'config floor default = code default');
  ExpectEq(Cfg.Compaction.SummaryBudget,      Def.SummaryBudget,
           'config summary budget default = code default');
  Cfg.Free;

  if Failures = 0 then
    WriteLn('compact_tests: OK')
  else
  begin
    WriteLn('compact_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
