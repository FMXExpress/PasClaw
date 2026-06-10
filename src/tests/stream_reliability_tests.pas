program stream_reliability_tests;
(*
  Covers PasClaw.Stream.Reliability -- the empty-turn auto-retry,
  ChatStream idle-timeout wrapper, and orphaned-tool-call repair
  that ship with the UltraCode-Shim gateway polish.

  We pin contracts that don't require a real LLM:

    - IsEmptyTurn identifies the three-piece empty shape and
      rejects every legitimate response shape that differs.
    - ChatWithEmptyRetry returns the FIRST non-empty response
      after one or more empty responses (happy retry path).
    - ChatWithEmptyRetry stops at EmptyRetryAttempts and surfaces
      the last empty response when the provider stays silent
      (exhaustion path; we cap the loop, don't pound forever).
    - ChatWithEmptyRetry with EmptyRetryAttempts=0 is single-shot.
    - ChatStreamWithReliability times out a hung provider (no
      chunks within IdleTimeoutMs) and returns a synthetic
      timeout response without leaking the worker.
    - ChatStreamWithReliability passes through the happy stream
      verbatim when no timeout fires.
    - RepairOrphanedToolCalls synthesizes stubs for tool_call ids
      that lack matching tool_results, leaves matched pairs alone,
      and reports the synthesized count.

  Strategy: substitute a FAKE ILLMProvider with scripted behaviour
  per test (return-N-empties-then-content; sleep-for-N-seconds; ...)
  so the test doesn't need a real model and isn't flaky.

  Threading note: ChatStreamWithReliability owns a worker thread.
  The two stream tests below use a fake provider whose ChatStream
  sleeps a deterministic amount before returning -- short for the
  passthrough test, long for the timeout test -- so we can verify
  both the success path and the watcher kill path without flakiness.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, SyncObjs,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Stream.Reliability;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure AssertEqInt(const Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want]));
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 200) + '")');
end;

type
  { Scripted ILLMProvider. Each call to Chat or ChatStream returns
    the next entry from Script (cycling at end). When Script is
    empty, returns a real-looking response with Content='OK'. }
  TScriptedProvider = class(TInterfacedObject, ILLMProvider)
  private
    FScript:      array of TLLMResponse;
    FCallCount:   Integer;
    FSleepBefore: Integer;  { ms per Chat / ChatStream call }
    FChunkText:   string;   { if non-empty, ChatStream emits this as one chunk
                              before returning the scripted response }
    FProtocolOnlyChunks: Boolean;
                            { when True, ChatStream emits one empty 'text' chunk
                              and one 'done' chunk before returning -- the
                              "stream produced protocol events but no user-
                              visible content" shape that finding #2 covers }
    FRaiseFromStream: string;
                            { when non-empty, ChatStream raises Exception with
                              this message before producing any chunks --
                              the DNS/socket/provider exception shape that
                              finding #1 covers }
  public
    constructor Create;
    function ChatCallCount: Integer;
    procedure SetSleepBeforeMs(MS: Integer);
    procedure SetChunkText(const Text: string);
    procedure SetProtocolOnlyChunks(V: Boolean);
    procedure SetRaiseFromStream(const Msg: string);
    procedure AddScriptedEmpty;
    procedure AddScriptedContent(const Body: string);
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

constructor TScriptedProvider.Create;
begin
  inherited;
  SetLength(FScript, 0);
  FCallCount         := 0;
  FSleepBefore       := 0;
  FChunkText         := '';
  FProtocolOnlyChunks := False;
  FRaiseFromStream   := '';
end;

function TScriptedProvider.ChatCallCount: Integer; begin Result := FCallCount; end;

procedure TScriptedProvider.SetSleepBeforeMs(MS: Integer);
begin FSleepBefore := MS; end;

procedure TScriptedProvider.SetChunkText(const Text: string);
begin FChunkText := Text; end;

procedure TScriptedProvider.SetProtocolOnlyChunks(V: Boolean);
begin FProtocolOnlyChunks := V; end;

procedure TScriptedProvider.SetRaiseFromStream(const Msg: string);
begin FRaiseFromStream := Msg; end;

procedure TScriptedProvider.AddScriptedEmpty;
var
  R: TLLMResponse;
begin
  R := Default(TLLMResponse);
  R.StatusCode   := 200;
  R.FinishReason := 'stop';
  R.Content      := '';
  SetLength(R.ToolCalls, 0);
  SetLength(FScript, Length(FScript) + 1);
  FScript[High(FScript)] := R;
end;

procedure TScriptedProvider.AddScriptedContent(const Body: string);
var
  R: TLLMResponse;
begin
  R := Default(TLLMResponse);
  R.StatusCode   := 200;
  R.FinishReason := 'stop';
  R.Content      := Body;
  SetLength(R.ToolCalls, 0);
  SetLength(FScript, Length(FScript) + 1);
  FScript[High(FScript)] := R;
end;

function TScriptedProvider.Chat(const Messages: array of TMessage;
                                 const Tools:    array of TToolDefinition;
                                 const Model:    string;
                                 const Options:  TChatOptions): TLLMResponse;
var
  Idx: Integer;
begin
  if FSleepBefore > 0 then Sleep(FSleepBefore);
  Inc(FCallCount);
  if Length(FScript) = 0 then
  begin
    Result := Default(TLLMResponse);
    Result.StatusCode := 200;
    Result.FinishReason := 'stop';
    Result.Content := 'OK';
    Exit;
  end;
  Idx := (FCallCount - 1);
  if Idx > High(FScript) then Idx := High(FScript);  { cycle on last }
  Result := FScript[Idx];
end;

function TScriptedProvider.ChatStream(const Messages: array of TMessage;
                                       const Tools:    array of TToolDefinition;
                                       const Model:    string;
                                       const Options:  TChatOptions;
                                       OnChunk: TStreamCallback): TLLMResponse;
var
  Chunk: TStreamChunk;
begin
  if FSleepBefore > 0 then Sleep(FSleepBefore);
  Inc(FCallCount);
  if FRaiseFromStream <> '' then
    raise Exception.Create(FRaiseFromStream);
  if FProtocolOnlyChunks and Assigned(OnChunk) then
  begin
    Chunk := Default(TStreamChunk);
    Chunk.Kind := 'text';
    Chunk.Text := '';            { empty delta -- protocol event only }
    OnChunk(Chunk);
    Chunk := Default(TStreamChunk);
    Chunk.Kind := 'done';
    OnChunk(Chunk);
  end
  else if (FChunkText <> '') and Assigned(OnChunk) then
  begin
    Chunk := Default(TStreamChunk);
    Chunk.Kind := 'text';
    Chunk.Text := FChunkText;
    OnChunk(Chunk);
  end;
  if Length(FScript) = 0 then
  begin
    Result := Default(TLLMResponse);
    Result.StatusCode := 200;
    Result.FinishReason := 'stop';
    Result.Content := FChunkText;  { mirror the chunk content for parity }
    Exit;
  end;
  Result := FScript[(FCallCount - 1) mod Length(FScript)];
end;

function TScriptedProvider.GetDefaultModel: string; begin Result := 'scripted'; end;
function TScriptedProvider.GetName: string;         begin Result := 'scripted'; end;
function TScriptedProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TScriptedProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScriptedProvider.SupportsStreaming: Boolean;    begin Result := True;  end;

procedure TestIsEmptyTurn;
var
  R: TLLMResponse;
  Tc: TToolCall;
begin
  R := Default(TLLMResponse);
  R.StatusCode := 200;
  R.FinishReason := 'stop';
  AssertTrue(IsEmptyTurn(R), 'empty + stop is empty turn');

  R.FinishReason := '';
  AssertTrue(IsEmptyTurn(R), 'empty finish_reason still empty turn');

  R.FinishReason := 'end_turn';
  AssertTrue(IsEmptyTurn(R), 'Anthropic end_turn shape recognised');

  R.Content := 'hi';
  R.FinishReason := 'stop';
  AssertFalse(IsEmptyTurn(R), 'non-empty content not empty turn');

  R.Content := '';
  R.FinishReason := 'tool_use';
  AssertFalse(IsEmptyTurn(R), 'tool_use finish not empty turn');

  R.FinishReason := 'stop';
  Tc := Default(TToolCall);
  Tc.Id := 'tc1';
  SetLength(R.ToolCalls, 1);
  R.ToolCalls[0] := Tc;
  AssertFalse(IsEmptyTurn(R), 'has tool calls not empty turn');
end;

procedure TestChatWithEmptyRetryHappyPath;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
begin
  P := TScriptedProvider.Create;
  Pi := P;  { hold a reference }
  P.AddScriptedEmpty;
  P.AddScriptedEmpty;
  P.AddScriptedContent('hello there');

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.EmptyRetryAttempts  := 3;
  Cfg.EmptyRetryBackoffMs := 50;  { keep test fast }

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');
  SetLength(Tools, 0);

  R := ChatWithEmptyRetry(Pi, Msgs, Tools, 'fake', DefaultChatOptions, Cfg);

  AssertEqStr(R.Content, 'hello there', 'retried until non-empty response');
  AssertEqInt(P.ChatCallCount, 3, 'three calls (2 empty + 1 success)');
end;

procedure TestChatWithEmptyRetryExhaustion;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  P.AddScriptedEmpty;  { every call returns the same empty (cycles) }

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.EmptyRetryAttempts  := 2;
  Cfg.EmptyRetryBackoffMs := 50;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');
  SetLength(Tools, 0);

  R := ChatWithEmptyRetry(Pi, Msgs, Tools, 'fake', DefaultChatOptions, Cfg);

  AssertEqStr(R.Content, '', 'still empty after exhausting retries');
  AssertEqInt(P.ChatCallCount, 3, 'one initial + two retries = three calls');
end;

procedure TestChatWithEmptyRetryDisabled;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  P.AddScriptedEmpty;
  P.AddScriptedContent('would-have-retried');

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.EmptyRetryAttempts := 0;  { disabled }

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');
  SetLength(Tools, 0);

  R := ChatWithEmptyRetry(Pi, Msgs, Tools, 'fake', DefaultChatOptions, Cfg);

  AssertEqStr(R.Content, '', 'no retry when attempts=0');
  AssertEqInt(P.ChatCallCount, 1, 'single call when retries disabled');
end;

type
  TStreamCollector = class
  public
    Chunks: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnChunk(const C: TStreamChunk);
  end;

constructor TStreamCollector.Create;
begin
  inherited;
  Chunks := TStringList.Create;
end;

destructor TStreamCollector.Destroy;
begin
  Chunks.Free;
  inherited;
end;

procedure TStreamCollector.OnChunk(const C: TStreamChunk);
begin
  if C.Kind = 'text' then Chunks.Add(C.Text);
end;

procedure TestChatStreamHappyPath;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
  Collector: TStreamCollector;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  P.SetChunkText('hello world');

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.StreamIdleTimeoutMs := 5000;
  Cfg.EmptyRetryAttempts  := 0;  { not testing retry here }

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');

  Collector := TStreamCollector.Create;
  try
    SetLength(Tools, 0);
    R := ChatStreamWithReliability(Pi, Msgs, Tools, 'fake',
                                    DefaultChatOptions, Collector.OnChunk, Cfg);
    AssertEqStr(R.Content, 'hello world', 'response carries the chunk content');
    AssertEqInt(Collector.Chunks.Count, 1, 'one chunk delivered to user');
    AssertEqStr(Collector.Chunks[0], 'hello world', 'chunk text matched');
  finally
    Collector.Free;
  end;
end;

procedure TestChatStreamIdleTimeout;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
  Collector: TStreamCollector;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  { Provider sleeps for 4 seconds before returning; timeout fires at 1s. }
  P.SetSleepBeforeMs(4000);

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.StreamIdleTimeoutMs := 1000;
  Cfg.EmptyRetryAttempts  := 0;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');

  Collector := TStreamCollector.Create;
  try
    SetLength(Tools, 0);
    R := ChatStreamWithReliability(Pi, Msgs, Tools, 'fake',
                                    DefaultChatOptions, Collector.OnChunk, Cfg);
    AssertEqStr(R.FinishReason, 'timeout', 'finish_reason marked timeout');
    AssertEqInt(Collector.Chunks.Count, 0, 'no chunks delivered before timeout');
    { Negative status signals the synthetic-empty path. }
    AssertTrue(R.StatusCode < 0, 'status code negative on timeout');
  finally
    Collector.Free;
  end;
  { Give the orphaned worker a moment to drain before the test exits;
    the FreeOnTerminate worker will clean itself up. }
  Sleep(5000);
end;

procedure TestChatStreamExceptionMarkedAsFailure;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
  Collector: TStreamCollector;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  P.SetRaiseFromStream('simulated socket reset');

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.StreamIdleTimeoutMs := 5000;
  Cfg.EmptyRetryAttempts  := 0;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');

  Collector := TStreamCollector.Create;
  try
    SetLength(Tools, 0);
    R := ChatStreamWithReliability(Pi, Msgs, Tools, 'fake',
                                    DefaultChatOptions, Collector.OnChunk, Cfg);
    AssertEqStr(R.FinishReason, 'error', 'exception turns into FinishReason=error');
    AssertTrue(R.StatusCode < 0, 'status code negative on exception');
    AssertContains(R.Content, 'simulated socket reset',
                   'exception message surfaced in Content for the gateway');
  finally
    Collector.Free;
  end;
end;

procedure TestProtocolOnlyChunksDoNotSuppressRetry;
var
  P: TScriptedProvider;
  Pi: ILLMProvider;
  Cfg: TStreamReliabilityConfig;
  Msgs: array of TMessage;
  Tools: array of TToolDefinition;
  R: TLLMResponse;
  Collector: TStreamCollector;
begin
  P := TScriptedProvider.Create;
  Pi := P;
  { First call: empty TLLMResponse plus protocol-only chunks (one
    empty 'text' delta + a 'done'). Second call: real content. }
  P.SetProtocolOnlyChunks(True);
  P.AddScriptedEmpty;
  P.AddScriptedContent('recovered');

  Cfg := DefaultStreamReliabilityConfig;
  Cfg.StreamIdleTimeoutMs := 5000;
  Cfg.EmptyRetryAttempts  := 2;
  Cfg.EmptyRetryBackoffMs := 50;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, 'ping');

  Collector := TStreamCollector.Create;
  try
    SetLength(Tools, 0);
    R := ChatStreamWithReliability(Pi, Msgs, Tools, 'fake',
                                    DefaultChatOptions, Collector.OnChunk, Cfg);
    { On the retry attempt the provider had its protocol-only flag
      still set, but the scripted response carries content -- this
      asserts the retry FIRED. Without the fix, FChunkCount would
      have been bumped by the empty-text + done chunks of the
      first call and the retry would have been skipped, leaving
      R.Content empty. }
    AssertEqStr(R.Content, 'recovered', 'retry fired despite protocol-only chunks');
    AssertTrue(P.ChatCallCount >= 2, 'at least one retry attempted');
  finally
    Collector.Free;
  end;
end;

procedure TestRepairLeavesMatchedPairsAlone;
var
  Msgs: TMessageArray;
  Asst: TMessage;
  Tc: TToolCall;
  Synth: Integer;
begin
  SetLength(Msgs, 3);
  Msgs[0] := MakeMessage(mrUser, 'hi');

  Asst := MakeMessage(mrAssistant, '');
  Tc := Default(TToolCall);
  Tc.Id := 'tc-1';
  Tc.Func.Name := 'fs_read';
  SetLength(Asst.ToolCalls, 1);
  Asst.ToolCalls[0] := Tc;
  Msgs[1] := Asst;

  Msgs[2] := MakeMessage(mrTool, 'file contents');
  Msgs[2].ToolCallId := 'tc-1';

  Synth := RepairOrphanedToolCalls(Msgs);
  AssertEqInt(Synth, 0, 'matched pair needs no repair');
  AssertEqInt(Length(Msgs), 3, 'history length unchanged');
end;

procedure TestRepairSynthesizesStubsForOrphans;
var
  Msgs: TMessageArray;
  Asst: TMessage;
  Tc1, Tc2: TToolCall;
  Synth: Integer;
  i, StubIdx: Integer;
begin
  SetLength(Msgs, 2);
  Msgs[0] := MakeMessage(mrUser, 'do two things');

  Asst := MakeMessage(mrAssistant, '');
  Tc1 := Default(TToolCall); Tc1.Id := 'tc-a'; Tc1.Func.Name := 'fs_read';
  Tc2 := Default(TToolCall); Tc2.Id := 'tc-b'; Tc2.Func.Name := 'shell';
  SetLength(Asst.ToolCalls, 2);
  Asst.ToolCalls[0] := Tc1;
  Asst.ToolCalls[1] := Tc2;
  Msgs[1] := Asst;

  { No mrTool messages follow -- both calls are orphaned. }
  Synth := RepairOrphanedToolCalls(Msgs);
  AssertEqInt(Synth, 2, 'two orphans repaired');
  AssertEqInt(Length(Msgs), 4, 'history grew by two stubs');

  { Stubs land immediately after the assistant turn, in array
    order matching the tool_call sequence. }
  StubIdx := -1;
  for i := 0 to High(Msgs) do
    if (Msgs[i].Role = mrTool) and (Msgs[i].ToolCallId = 'tc-a') then
    begin
      StubIdx := i;
      Break;
    end;
  AssertTrue(StubIdx > 1, 'tc-a stub appears after the assistant turn');
  AssertContains(Msgs[StubIdx].Content, 'missing',
                 'stub content mentions repair');

  StubIdx := -1;
  for i := 0 to High(Msgs) do
    if (Msgs[i].Role = mrTool) and (Msgs[i].ToolCallId = 'tc-b') then
    begin
      StubIdx := i;
      Break;
    end;
  AssertTrue(StubIdx > 1, 'tc-b stub appears after the assistant turn');
end;

procedure TestRepairPartialOrphanMix;
var
  Msgs: TMessageArray;
  Asst: TMessage;
  Tc1, Tc2: TToolCall;
  Synth, i, Stubs: Integer;
begin
  { Assistant emits two tool calls; only tc-a's result follows.
    tc-b is orphaned -- exactly the parallel-tool-cancelled
    scenario strict backends 400 on. }
  SetLength(Msgs, 3);
  Msgs[0] := MakeMessage(mrUser, 'do two things');

  Asst := MakeMessage(mrAssistant, '');
  Tc1 := Default(TToolCall); Tc1.Id := 'tc-a'; Tc1.Func.Name := 'fs_read';
  Tc2 := Default(TToolCall); Tc2.Id := 'tc-b'; Tc2.Func.Name := 'shell';
  SetLength(Asst.ToolCalls, 2);
  Asst.ToolCalls[0] := Tc1;
  Asst.ToolCalls[1] := Tc2;
  Msgs[1] := Asst;

  Msgs[2] := MakeMessage(mrTool, 'OK');
  Msgs[2].ToolCallId := 'tc-a';

  Synth := RepairOrphanedToolCalls(Msgs);
  AssertEqInt(Synth, 1, 'only the orphan got a stub');
  AssertEqInt(Length(Msgs), 4, 'history grew by one');

  { Total tool messages: original tc-a result + one synth stub. }
  Stubs := 0;
  for i := 0 to High(Msgs) do
    if Msgs[i].Role = mrTool then Inc(Stubs);
  AssertEqInt(Stubs, 2, 'two tool messages after repair');
end;

procedure TestLoadFromEnv;
var
  Cfg: TStreamReliabilityConfig;
begin
  { Defaults come through when env unset. We can't reliably modify
    process env from inside a test on every platform, but we CAN
    verify the defaults map identically when no overrides exist. }
  Cfg := LoadStreamReliabilityFromEnv(DefaultStreamReliabilityConfig);
  AssertEqInt(Cfg.EmptyRetryAttempts,  2, 'default attempts');
  AssertEqInt(Cfg.EmptyRetryBackoffMs, 750, 'default backoff');
  AssertEqInt(Cfg.StreamIdleTimeoutMs, 150 * 1000, 'default idle timeout');
  AssertTrue(Cfg.ToolCallRepairEnabled, 'default repair enabled');
end;

begin
  TestIsEmptyTurn;                       WriteLn('  ok: IsEmptyTurn');
  TestChatWithEmptyRetryHappyPath;       WriteLn('  ok: ChatWithEmptyRetry happy path');
  TestChatWithEmptyRetryExhaustion;      WriteLn('  ok: ChatWithEmptyRetry exhaustion');
  TestChatWithEmptyRetryDisabled;        WriteLn('  ok: ChatWithEmptyRetry disabled');
  TestChatStreamHappyPath;               WriteLn('  ok: ChatStream happy path');
  TestChatStreamIdleTimeout;             WriteLn('  ok: ChatStream idle timeout');
  TestChatStreamExceptionMarkedAsFailure; WriteLn('  ok: ChatStream exception marked as failure');
  TestProtocolOnlyChunksDoNotSuppressRetry; WriteLn('  ok: Protocol-only chunks do not suppress retry');
  TestRepairLeavesMatchedPairsAlone;     WriteLn('  ok: Repair leaves matched pairs alone');
  TestRepairSynthesizesStubsForOrphans;  WriteLn('  ok: Repair synthesizes stubs');
  TestRepairPartialOrphanMix;            WriteLn('  ok: Repair partial-orphan mix');
  TestLoadFromEnv;                       WriteLn('  ok: LoadStreamReliabilityFromEnv defaults');
  WriteLn('PASS');
end.
