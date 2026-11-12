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
    Texts: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnChunk(const C: TStreamChunk);
  end;

constructor TChunks.Create;
begin
  Texts := TStringList.Create;
end;

destructor TChunks.Destroy;
begin
  Texts.Free;
  inherited;
end;

procedure TChunks.OnChunk(const C: TStreamChunk);
begin
  if C.Kind = 'text' then Texts.Add(C.Text);
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

  R := ParseOAIStream(Ev('{"choices":[{"index":0,"delta":{"content":"par"}}]}') +
                      Ev('{"error":{"message":"overloaded","type":"server_error"}}'),
                      nil, Failed);
  AssertEq(Failed, 'overloaded', 'an error sent inside the stream is reported');
  WriteLn('  ok: a Chat Completions stream: text pieces, tool-call fragments, finish, usage, an error');
end;

{ ------------------------------------------------------------- the loop -- }

type
  { One scripted round per call: the text pieces ChatStream passes on, and
    the response it (or Chat) then returns. }
  TRound = record
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
    Deltas, Texts: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnDelta(const Delta: string; First: Boolean);
    procedure OnText(const S: string);
  end;

constructor TSeen.Create;
begin
  Deltas := TStringList.Create;
  Texts := TStringList.Create;
end;

destructor TSeen.Destroy;
begin
  Deltas.Free;
  Texts.Free;
  inherited;
end;

procedure TSeen.OnDelta(const Delta: string; First: Boolean);
begin
  if First then Deltas.Add('^' + Delta) else Deltas.Add(Delta);
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
end;

{ Run one turn over the scripted rounds; the seen deltas and texts, joined. }
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
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go');
    AssertTrue(RunToolLoop(Cfg, Msgs, Loop), 'the loop runs');
    Deltas := StringReplace(Trim(Seen.Deltas.Text), sLineBreak, '|', [rfReplaceAll]);
    Texts := StringReplace(Trim(Seen.Texts.Text), sLineBreak, '|', [rfReplaceAll]);
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
  WriteLn('  ok: the loop''s OnTextDelta: streamed rounds, OnText otherwise, a mismatch, the rest, rounds');
end;

begin
  TestParser;
  TestOAIStream;
  TestLoop;
  WriteLn('PASS');
end.
