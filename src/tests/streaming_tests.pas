program streaming_tests;
(*
  Pins token streaming, below the editor:

    - TSSEParseStream: SSE parsed as bytes arrive -- a byte at a time, CRLF
      lines, a UTF-8 character split across writes, comments, an event with
      no closing blank line, the raw copy kept for a body that is not SSE
    - ParseOAIStream: a Chat Completions stream put back together the way
      ChatStream does -- text pieces passed on, tool calls from id/name and
      argument fragments, finish_reason, usage with cached tokens, a name a
      server repeats, an error sent inside the stream
    - ParseAnthropicStream: a Messages API stream the way ChatStream reads
      it -- text blocks joined as Chat joins them, thinking kept but not
      shown, a tool call from input_json fragments, usage from message_start
      and message_delta, the content array rebuilt block for block (thinking
      with its signature, citations) for a pause_turn continuation, an error
      event
    - the tool loop's OnTextDelta: a streamed round goes to OnTextDelta and
      not to OnText; without OnTextDelta, or with a provider that does not
      stream, OnText as before; a round that ended with something else than
      was streamed goes to OnText; text after what was streamed is passed on;
      each round's first piece is marked

  acp_e2e_test.py drives the real thing over HTTP: the fake model holds its
  stream until the editor has shown the first piece.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Stream,
  PasClaw.Providers.OpenAI,
  PasClaw.Providers.Anthropic,
  PasClaw.JSON,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEq(const Got, Want, Msg: string);
begin
  if Got <> Want then Fail_(Msg + ' (expected "' + Want + '" got "' + Got + '")');
end;

{ ------------------------------------------------------------ the parser -- }

type
  TEvents = class
    Names, Datas: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnEvent(const Event, Data: string);
  end;

constructor TEvents.Create;
begin
  Names := TStringList.Create;
  Datas := TStringList.Create;
end;

destructor TEvents.Destroy;
begin
  Names.Free;
  Datas.Free;
  inherited;
end;

procedure TEvents.OnEvent(const Event, Data: string);
begin
  Names.Add(Event);
  Datas.Add(Data);
end;

procedure Feed(S: TSSEParseStream; const Text: string; Step: Integer);
var
  i, n: Integer;
begin
  i := 1;
  while i <= Length(Text) do
  begin
    n := Step;
    if i + n - 1 > Length(Text) then n := Length(Text) - i + 1;
    S.Write(Text[i], n);
    Inc(i, n);
  end;
end;

procedure TestParser;
var
  E: TEvents;
  S: TSSEParseStream;
  Text: string;
begin
  E := TEvents.Create;
  S := TSSEParseStream.Create(E.OnEvent);
  try
    Text := ': keep-alive' + #13#10 +
            'event: first' + #13#10 + 'data: {"x":1}' + #13#10 + #13#10 +
            'data: one' + #10 + 'data: two' + #10 + #10 +
            'data: caf' + #$C3#$A9 + #10 + #10 +
            'data: tail-without-blank-line';
    Feed(S, Text, 1);                     { a byte at a time }
    AssertTrue(E.Datas.Count = 3, 'three events before the end (got ' + IntToStr(E.Datas.Count) + ')');
    AssertEq(E.Names[0], 'first', 'an event name');
    AssertEq(E.Datas[0], '{"x":1}', 'its data, CRLF stripped');
    AssertEq(E.Datas[1], 'one' + #10 + 'two', 'two data lines joined');
    AssertEq(E.Datas[2], 'caf' + #$C3#$A9, 'a character split across writes stays whole');
    S.Finish;
    AssertTrue(E.Datas.Count = 4, 'Finish flushes an event with no closing blank line');
    AssertEq(E.Datas[3], 'tail-without-blank-line', 'that event');
    AssertTrue(S.Events = 4, 'counted');
    AssertTrue(S.Seek(0, soCurrent) = Length(Text), 'Seek answers how much was written');
    AssertEq(S.Raw, Text, 'Raw keeps the body');
  finally
    S.Free;
    E.Free;
  end;

  E := TEvents.Create;
  S := TSSEParseStream.Create(E.OnEvent);
  try
    S.RawCap := 5;
    Text := '{"error":{"message":"bad key"}}';
    Feed(S, Text, 7);
    S.Finish;
    AssertEq(S.Raw, Copy(Text, 1, 5), 'Raw stops at RawCap');
    AssertTrue(S.Events = 0, 'a JSON body is not an event');
  finally
    S.Free;
    E.Free;
  end;
  WriteLn('  ok: SSE parsed as bytes arrive: split lines, CRLF, split UTF-8, comments, a last event');
end;

{ ---------------------------------------------------- the OpenAI stream -- }

type
  TChunks = class
    Texts, Thoughts: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnChunk(const C: TStreamChunk);
  end;

constructor TChunks.Create;
begin
  Texts := TStringList.Create;
  Thoughts := TStringList.Create;
end;

destructor TChunks.Destroy;
begin
  Texts.Free;
  Thoughts.Free;
  inherited;
end;

procedure TChunks.OnChunk(const C: TStreamChunk);
begin
  if C.Kind = 'text' then Texts.Add(C.Text)
  else if C.Kind = 'thinking' then Thoughts.Add(C.Text);
end;

function Ev(const JSON: string): string;
begin
  Result := 'data: ' + JSON + #10#10;
end;

procedure TestOAIStream;
var
  K: TChunks;
  R: TLLMResponse;
  Failed, SSE: string;
begin
  SSE :=
    Ev('{"model":"m1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hel"}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"content":"lo"}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"content":null}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"read_file","arguments":""}}]}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"pa"}}]}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"name":"read_file","arguments":"th\":\"a\"}"}}]}}]}') +
    Ev('{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"c2","function":{"name":"list_dir"}}]}}]}') +
    Ev('{"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}') +
    Ev('{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":7,"prompt_tokens_details":{"cached_tokens":4}}}') +
    Ev('[DONE]');
  K := TChunks.Create;
  try
    R := ParseOAIStream(SSE, K.OnChunk, Failed);
    AssertEq(Failed, '', 'no error');
    AssertTrue((K.Texts.Count = 2) and (K.Texts[0] = 'Hel') and (K.Texts[1] = 'lo'),
               'each text piece passed on as it came, a null content skipped');
    AssertEq(R.Content, 'Hello', 'the text put together');
    AssertEq(R.Model, 'm1', 'the model');
    AssertTrue(Length(R.ToolCalls) = 2, 'two tool calls');
    AssertEq(R.ToolCalls[0].Id, 'c1', 'first call id');
    AssertEq(R.ToolCalls[0].Func.Name, 'read_file', 'a name the server repeats is not doubled');
    AssertEq(R.ToolCalls[0].Func.Arguments, '{"path":"a"}', 'arguments from fragments');
    AssertEq(R.ToolCalls[1].Func.Name, 'list_dir', 'second call');
    AssertEq(R.ToolCalls[1].Func.Arguments, '{}', 'a call with no arguments reads as {}, as Chat does');
    AssertEq(R.FinishReason, 'tool_calls', 'finish_reason');
    AssertTrue((R.Usage.InputTokens = 11) and (R.Usage.OutputTokens = 7) and
               (R.Usage.CacheReadTokens = 4), 'usage from the last chunk, cached tokens too');
  finally
    K.Free;
  end;

  K := TChunks.Create;
  try
    R := ParseOAIStream(
      Ev('{"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"Think"}}]}') +
      Ev('{"choices":[{"index":0,"delta":{"reasoning":"ing."}}]}') +
      Ev('{"choices":[{"index":0,"delta":{"content":"Answer"}}]}') +
      Ev('{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}'), K.OnChunk, Failed);
    AssertTrue((K.Thoughts.Count = 2) and (K.Thoughts[0] = 'Think') and (K.Thoughts[1] = 'ing.'),
               'reasoning_content and reasoning passed on as thinking');
    AssertEq(R.Content, 'Answer', 'and kept out of the reply');
  finally
    K.Free;
  end;

  R := ParseOAIStream(Ev('{"choices":[{"index":0,"delta":{"content":"par"}}]}') +
                      Ev('{"error":{"message":"overloaded","type":"server_error"}}'),
                      nil, Failed);
  AssertEq(Failed, 'overloaded', 'an error sent inside the stream is reported');
  WriteLn('  ok: a Chat Completions stream: text pieces, tool-call fragments, finish, usage, an error');
end;

{ ------------------------------------------------- the Anthropic stream -- }

function AEv(const Name, JSON: string): string;
begin
  Result := 'event: ' + Name + #10 + 'data: ' + JSON + #10#10;
end;

procedure TestAnthropicStream;
var
  K: TChunks;
  R: TLLMResponse;
  Failed, Content, SSE: string;
  Root, B, In_: TJsonObject;
  Arr, Cits: TJsonArray;
begin
  SSE :=
    AEv('message_start', '{"type":"message_start","message":{"model":"claude-x","usage":' +
        '{"input_tokens":12,"cache_read_input_tokens":3,"cache_creation_input_tokens":2,"output_tokens":1}}}') +
    AEv('content_block_start', '{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me"}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig1"}}') +
    AEv('content_block_stop', '{"type":"content_block_stop","index":0}') +
    AEv('content_block_start', '{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}}') +
    AEv('ping', '{"type":"ping"}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":1,"delta":{"type":"citations_delta",' +
        '"citation":{"type":"web_search_result_location","url":"https://x.example","title":"X","cited_text":"c"}}}') +
    AEv('content_block_stop', '{"type":"content_block_stop","index":1}') +
    AEv('content_block_start', '{"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"World"}}') +
    AEv('content_block_stop', '{"type":"content_block_stop","index":2}') +
    AEv('content_block_start', '{"type":"content_block_start","index":3,"content_block":' +
        '{"type":"tool_use","id":"toolu_1","name":"read_file","input":{}}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"{\"pa"}}') +
    AEv('content_block_delta', '{"type":"content_block_delta","index":3,"delta":{"type":"input_json_delta","partial_json":"th\": \"a\"}"}}') +
    AEv('content_block_stop', '{"type":"content_block_stop","index":3}') +
    AEv('message_delta', '{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}') +
    AEv('message_stop', '{"type":"message_stop"}');
  K := TChunks.Create;
  try
    R := ParseAnthropicStream(SSE, K.OnChunk, Failed, Content);
    AssertEq(Failed, '', 'no error');
    AssertTrue((K.Texts.Count = 4) and (K.Texts[0] = 'Hel') and (K.Texts[1] = 'lo') and
               (K.Texts[2] = sLineBreak) and (K.Texts[3] = 'World'),
               'text pieces as they come, a line break between text blocks, thinking not in them');
    AssertTrue((K.Thoughts.Count = 1) and (K.Thoughts[0] = 'Let me'),
               'thinking passed on as thinking chunks');
    AssertEq(R.Content, 'Hello' + sLineBreak + 'World', 'text blocks joined as Chat joins them');
    AssertEq(R.Model, 'claude-x', 'the model');
    AssertEq(R.FinishReason, 'tool_use', 'the stop reason');
    AssertTrue((R.Usage.InputTokens = 12) and (R.Usage.OutputTokens = 9) and
               (R.Usage.CacheReadTokens = 3) and (R.Usage.CacheCreatedTokens = 2),
               'usage from message_start and message_delta');
    AssertTrue(Length(R.ToolCalls) = 1, 'one tool call');
    AssertEq(R.ToolCalls[0].Id, 'toolu_1', 'its id');
    AssertEq(R.ToolCalls[0].Func.Name, 'read_file', 'its name');
    In_ := TJsonObject.Parse(R.ToolCalls[0].Func.Arguments);
    try
      AssertEq(In_.GetStr('path', ''), 'a', 'its input, from input_json fragments');
    finally
      In_.Free;
    end;
  finally
    K.Free;
  end;

  { The content array, block for block, as a pause_turn continuation
    re-sends it. }
  Root := TJsonObject.Parse('{"c":' + Content + '}');
  try
    Arr := Root.ChildArray('c');
    try
      AssertTrue(Arr.Count = 4, 'four blocks in the content array');
      B := Arr.ItemObject(0);
      try
        AssertTrue((B.GetStr('type', '') = 'thinking') and (B.GetStr('thinking', '') = 'Let me') and
                   (B.GetStr('signature', '') = 'sig1'), 'thinking kept with its signature');
      finally
        B.Free;
      end;
      B := Arr.ItemObject(1);
      try
        AssertEq(B.GetStr('text', ''), 'Hello', 'a text block''s text');
        Cits := B.ChildArray('citations');
        try
          AssertTrue((Cits <> nil) and (Cits.Count = 1), 'and its citation');
        finally
          Cits.Free;
        end;
      finally
        B.Free;
      end;
      B := Arr.ItemObject(3);
      try
        In_ := B.ChildObject('input');
        try
          AssertTrue((B.GetStr('type', '') = 'tool_use') and (In_ <> nil) and
                     (In_.GetStr('path', '') = 'a'), 'a tool block with its input');
        finally
          In_.Free;
        end;
      finally
        B.Free;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;

  R := ParseAnthropicStream(
    AEv('message_start', '{"type":"message_start","message":{"model":"m","usage":{"input_tokens":1}}}') +
    AEv('error', '{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}'),
    nil, Failed, Content);
  AssertEq(Failed, 'Overloaded', 'an error event is reported');
  WriteLn('  ok: an Anthropic stream: text blocks, thinking kept, tool input, usage, content for a continuation, an error');
end;

{ ------------------------------------------------------------- the loop -- }

type
  { One scripted round per call: the text pieces ChatStream passes on, and
    the response it (or Chat) then returns. }
  TRound = record
    Thoughts: array of string;   { thinking pieces streamed before the text }
    Pieces: array of string;
    Content: string;
    Tool: string;            { a tool to call, '' = none }
  end;

  TFakeStreamer = class(TInterfacedObject, ILLMProvider)
  public
    Streams: Boolean;
    Rounds: array of TRound;
    Call, StreamCalls, ChatCalls: Integer;
    function Next: TLLMResponse;
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                  const Model: string; const Options: TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                        const Model: string; const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

function TFakeStreamer.Next: TLLMResponse;
begin
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Result.Content := Rounds[Call].Content;
  Result.FinishReason := 'stop';
  if Rounds[Call].Tool <> '' then
  begin
    SetLength(Result.ToolCalls, 1);
    Result.ToolCalls[0].Id := 't' + IntToStr(Call);
    Result.ToolCalls[0].Kind := 'function';
    Result.ToolCalls[0].Func.Name := Rounds[Call].Tool;
    Result.ToolCalls[0].Func.Arguments := '{}';
    Result.FinishReason := 'tool_calls';
  end;
  Inc(Call);
end;

function TFakeStreamer.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                            const Model: string; const Options: TChatOptions): TLLMResponse;
begin
  Inc(ChatCalls);
  Result := Next;
end;

function TFakeStreamer.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                                  const Model: string; const Options: TChatOptions;
                                  OnChunk: TStreamCallback): TLLMResponse;
var
  i: Integer;
  C: TStreamChunk;
begin
  Inc(StreamCalls);
  for i := 0 to High(Rounds[Call].Thoughts) do
  begin
    C := Default(TStreamChunk);
    C.Kind := 'thinking';
    C.Text := Rounds[Call].Thoughts[i];
    OnChunk(C);
  end;
  for i := 0 to High(Rounds[Call].Pieces) do
  begin
    C := Default(TStreamChunk);
    C.Kind := 'text';
    C.Text := Rounds[Call].Pieces[i];
    OnChunk(C);
  end;
  Result := Next;
end;

function TFakeStreamer.GetDefaultModel: string; begin Result := 'fake'; end;
function TFakeStreamer.GetName: string; begin Result := 'fake-streamer'; end;
function TFakeStreamer.SupportsThinking: Boolean; begin Result := False; end;
function TFakeStreamer.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFakeStreamer.SupportsStreaming: Boolean; begin Result := Streams; end;

type
  TSeen = class
    Deltas, Texts, Thoughts: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnDelta(const Delta: string; First: Boolean);
    procedure OnText(const S: string);
    procedure OnThought(const Delta: string; First: Boolean);
  end;

constructor TSeen.Create;
begin
  Deltas := TStringList.Create;
  Texts := TStringList.Create;
  Thoughts := TStringList.Create;
end;

destructor TSeen.Destroy;
begin
  Deltas.Free;
  Texts.Free;
  Thoughts.Free;
  inherited;
end;

procedure TSeen.OnDelta(const Delta: string; First: Boolean);
begin
  if First then Deltas.Add('^' + Delta) else Deltas.Add(Delta);
end;

procedure TSeen.OnThought(const Delta: string; First: Boolean);
begin
  if First then Thoughts.Add('^' + Delta) else Thoughts.Add(Delta);
end;

procedure TSeen.OnText(const S: string);
begin
  Texts.Add(S);
end;

function NoopTool(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  Result := 'ok';
end;

function R1(const Pieces: array of string; const Content: string; const Tool: string = ''): TRound;
var
  i: Integer;
begin
  SetLength(Result.Pieces, Length(Pieces));
  for i := 0 to High(Pieces) do Result.Pieces[i] := Pieces[i];
  Result.Content := Content;
  Result.Tool := Tool;
  SetLength(Result.Thoughts, 0);
end;

function RT(const Thoughts, Pieces: array of string; const Content: string;
            const Tool: string = ''): TRound;
var
  i: Integer;
begin
  Result := R1(Pieces, Content, Tool);
  SetLength(Result.Thoughts, Length(Thoughts));
  for i := 0 to High(Thoughts) do Result.Thoughts[i] := Thoughts[i];
end;

{ Run one turn over the scripted rounds; the seen deltas and texts, joined. }
var
  LastThoughts: string;   { what OnThoughtDelta saw in the last RunOne }
  WantThoughts: Boolean;  { RunOne sets OnThoughtDelta }

procedure RunOne(Streams, WantDeltas: Boolean; const Rounds: array of TRound;
                 out Deltas, Texts: string; out StreamCalls, ChatCalls: Integer);
var
  P: TFakeStreamer;
  Prov: ILLMProvider;
  Reg: TToolRegistry;
  T: TTool;
  Cfg: TToolLoopConfig;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  Seen: TSeen;
  i: Integer;
begin
  P := TFakeStreamer.Create;
  Prov := P;
  P.Streams := Streams;
  SetLength(P.Rounds, Length(Rounds));
  for i := 0 to High(Rounds) do P.Rounds[i] := Rounds[i];
  Reg := TToolRegistry.Create;
  Seen := TSeen.Create;
  try
    FillChar(T, SizeOf(T), 0);
    T.Name := 'noop'; T.Description := 'd'; T.Schema := '{"type":"object"}';
    T.Handler := @NoopTool; T.Category := tcReadOnly;
    Reg.Register(T);
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider := Prov;
    Cfg.Registry := Reg;
    Cfg.Model := 'fake';
    Cfg.MaxIterations := 5;
    Cfg.Options := DefaultChatOptions;
    Cfg.OnText := Seen.OnText;
    if WantDeltas then Cfg.OnTextDelta := Seen.OnDelta;
    if WantThoughts then Cfg.OnThoughtDelta := Seen.OnThought;
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'the loop runs');
    Deltas := StringReplace(Trim(Seen.Deltas.Text), sLineBreak, '|', [rfReplaceAll]);
    Texts := StringReplace(Trim(Seen.Texts.Text), sLineBreak, '|', [rfReplaceAll]);
    LastThoughts := StringReplace(Trim(Seen.Thoughts.Text), sLineBreak, '|', [rfReplaceAll]);
    StreamCalls := P.StreamCalls;
    ChatCalls := P.ChatCalls;
  finally
    Seen.Free;
    Reg.Free;
  end;
end;

procedure TestLoop;
var
  D, T: string;
  SC, CC: Integer;
begin
  RunOne(True, True, [R1(['Hel', 'lo'], 'Hello')], D, T, SC, CC);
  AssertEq(D, '^Hel|lo', 'a streamed round goes to OnTextDelta, its first piece marked');
  AssertEq(T, '', 'and not to OnText as well');
  AssertTrue((SC = 1) and (CC = 0), 'through ChatStream');

  RunOne(True, False, [R1(['Hel', 'lo'], 'Hello')], D, T, SC, CC);
  AssertEq(D, '', 'no OnTextDelta, nothing streamed');
  AssertEq(T, 'Hello', 'OnText once per round, as before');
  AssertTrue((SC = 0) and (CC = 1), 'through Chat');

  RunOne(False, True, [R1(['Hel', 'lo'], 'Hello')], D, T, SC, CC);
  AssertEq(D, '', 'a provider that does not stream is not asked to');
  AssertEq(T, 'Hello', 'its text goes to OnText');
  AssertTrue((SC = 0) and (CC = 1), 'through Chat');

  RunOne(True, True, [R1(['partial'], 'Something else')], D, T, SC, CC);
  AssertEq(D, '^partial', 'what was streamed was shown');
  AssertEq(T, 'Something else', 'a round that ended with other text goes to OnText');

  RunOne(True, True, [R1(['Hel'], 'Hello')], D, T, SC, CC);
  AssertEq(D, '^Hel|lo', 'text after what was streamed is passed on, unmarked');
  AssertEq(T, '', 'and nothing to OnText');

  RunOne(True, True, [R1(['Look', 'ing'], 'Looking', 'noop'), R1(['Done'], 'Done')], D, T, SC, CC);
  AssertEq(D, '^Look|ing|^Done', 'each round''s first piece is marked');
  AssertTrue(SC = 2, 'both rounds streamed');

  { Thinking goes to OnThoughtDelta only, a round's first piece marked. }
  WantThoughts := True;
  try
    RunOne(True, True, [RT(['Hm', 'm'], ['Look'], 'Look', 'noop'), RT(['Ok'], ['Done'], 'Done')], D, T, SC, CC);
    AssertEq(LastThoughts, '^Hm|m|^Ok', 'thinking to OnThoughtDelta, each round''s first marked');
    AssertEq(D, '^Look|^Done', 'the text stream is unchanged by it');
    AssertEq(T, '', 'and thinking never reaches OnText');
    RunOne(True, False, [RT(['Hmm'], ['Ans', 'wer'], 'Answer')], D, T, SC, CC);
    AssertEq(LastThoughts, '^Hmm', 'OnThoughtDelta alone streams the round');
    AssertTrue(SC = 1, 'through ChatStream');
    AssertEq(T, 'Answer', 'and its text still goes to OnText whole');
  finally
    WantThoughts := False;
  end;
  WriteLn('  ok: the loop''s OnTextDelta and OnThoughtDelta: streamed rounds, OnText otherwise, a mismatch, the rest, rounds, thinking');
end;

begin
  TestParser;
  TestOAIStream;
  TestAnthropicStream;
  TestLoop;
  WriteLn('PASS');
end.
