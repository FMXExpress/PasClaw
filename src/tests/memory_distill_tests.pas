program memory_distill_tests;
(*
  Covers PasClaw.Memory.Distill -- Phase 1 of the distilled-memory
  system: turning a transcript into normalised TFact records via one
  LLM pass. No real model: a scripted ILLMProvider returns canned
  Content so we exercise the prompt/parse/normalise/dedup path
  deterministically.

  Pinned contracts:
    - facts parse out of {"facts":[...]} (and survive a ```json fence)
    - kind/scope normalise to the allowed enums; bad values default
    - confidence clamps to 0..1
    - expires keeps a YYYY-MM-DD shape, blanks anything else
    - empty-text facts are dropped; duplicate text collapses
    - empty transcript -> ok, zero facts, provider NOT called
    - provider exception -> False + ErrMsg
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Memory.Distill;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

type
  { Returns FReply verbatim as Content; counts calls; optionally raises. }
  TScriptedProvider = class(TInterfacedObject, ILLMProvider)
  public
    Reply:     string;
    Calls:     Integer;
    RaiseIt:   Boolean;
    LastSystem: string;
    function Chat(const Messages: array of TMessage;
                  const Tools: array of TToolDefinition;
                  const Model: string;
                  const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools: array of TToolDefinition;
                        const Model: string;
                        const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TScriptedProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TScriptedProvider.GetName: string;         begin Result := 'fake'; end;
function TScriptedProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TScriptedProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScriptedProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TScriptedProvider.Chat(const Messages: array of TMessage;
  const Tools: array of TToolDefinition; const Model: string;
  const Options: TChatOptions): TLLMResponse;
begin
  Inc(Calls);
  LastSystem := Options.SystemPrompt;
  if RaiseIt then raise Exception.Create('boom');
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Result.Content := Reply;
end;

function TScriptedProvider.ChatStream(const Messages: array of TMessage;
  const Tools: array of TToolDefinition; const Model: string;
  const Options: TChatOptions; OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function Convo: TMessageArray;
begin
  SetLength(Result, 2);
  Result[0] := MakeMessage(mrUser, 'I always use Delphi, never Lazarus. Exam tomorrow.');
  Result[1] := MakeMessage(mrAssistant, 'Noted.');
end;

procedure TestSliceJsonObject;
begin
  AssertEqStr(SliceJsonObject('{"a":1}'), '{"a":1}', 'plain object');
  AssertEqStr(SliceJsonObject('```json'#10'{"a":1}'#10'```'), '{"a":1}', 'fenced object');
  AssertEqStr(SliceJsonObject('here you go: {"a":{"b":2}} ok'), '{"a":{"b":2}}', 'embedded object');
  AssertEqStr(SliceJsonObject('no json here'), '', 'no object -> empty');
end;

procedure TestNormaliseFact;
var F: TFact;
begin
  F.Text := '  hi  '; F.Kind := 'STATIC'; F.Scope := 'Project';
  F.Confidence := 2.5; F.Expires := '2026-07-01';
  NormaliseFact(F);
  AssertEqStr(F.Text, 'hi', 'text trimmed');
  AssertEqStr(F.Kind, 'static', 'kind lowercased/kept');
  AssertEqStr(F.Scope, 'project', 'scope lowercased/kept');
  AssertTrue(F.Confidence = 1, 'confidence clamped to 1');
  AssertEqStr(F.Expires, '2026-07-01', 'valid expiry kept');

  F.Kind := 'weird'; F.Scope := 'galaxy'; F.Confidence := -3; F.Expires := 'soon';
  NormaliseFact(F);
  AssertEqStr(F.Kind, 'dynamic', 'bad kind -> dynamic');
  AssertEqStr(F.Scope, 'user', 'bad scope -> user');
  AssertTrue(F.Confidence = 0, 'confidence clamped to 0');
  AssertEqStr(F.Expires, '', 'malformed expiry -> blank');
end;

procedure TestDistillParsesAndNormalises;
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
begin
  P := TScriptedProvider.Create;
  P.Reply :=
    '```json'#10 +
    '{"facts":[' +
    '{"text":"User prefers Delphi over Lazarus","kind":"static","scope":"user","confidence":0.9,"expires":""},' +
    '{"text":"Has an exam","kind":"bogus","scope":"nowhere","confidence":5,"expires":"2026-06-27"},' +
    '{"text":"  ","kind":"static","scope":"user","confidence":0.5,"expires":""},' +
    '{"text":"User prefers Delphi over Lazarus","kind":"dynamic","scope":"user","confidence":0.4,"expires":""}' +
    ']}'#10'```';
  D := TMemoryDistiller.Create(P, 'fake');
  try
    AssertTrue(D.Distill(Convo, 'sess-1', '2026-06-26', Facts, Err), 'distill ok: ' + Err);
    AssertEqInt(Length(Facts), 2, 'empty dropped + duplicate collapsed -> 2 facts');

    AssertEqStr(Facts[0].Text, 'User prefers Delphi over Lazarus', 'fact 0 text');
    AssertEqStr(Facts[0].Kind, 'static', 'fact 0 kind');
    AssertEqStr(Facts[0].Scope, 'user', 'fact 0 scope');
    AssertEqStr(Facts[0].SourceSession, 'sess-1', 'fact 0 carries session');

    AssertEqStr(Facts[1].Kind, 'dynamic', 'fact 1 bad kind normalised');
    AssertEqStr(Facts[1].Scope, 'user', 'fact 1 bad scope normalised');
    AssertTrue(Facts[1].Confidence = 1, 'fact 1 confidence clamped');
    AssertEqStr(Facts[1].Expires, '2026-06-27', 'fact 1 keeps valid expiry');

    AssertTrue(Pos('2026-06-26', P.LastSystem) > 0, 'today injected into system prompt');
  finally
    D.Free;
  end;
end;

procedure TestEmptyTranscriptSkipsProvider;
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
  Empty: TMessageArray;
begin
  P := TScriptedProvider.Create;
  P.Reply := '{"facts":[{"text":"should not happen","kind":"static","scope":"user","confidence":1,"expires":""}]}';
  D := TMemoryDistiller.Create(P, 'fake');
  try
    SetLength(Empty, 0);
    AssertTrue(D.Distill(Empty, 'sess-2', '2026-06-26', Facts, Err), 'empty transcript ok');
    AssertEqInt(Length(Facts), 0, 'no facts from empty transcript');
    AssertEqInt(P.Calls, 0, 'provider not called for empty transcript');
  finally
    D.Free;
  end;
end;

procedure TestProviderErrorSurfaces;
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
begin
  P := TScriptedProvider.Create;
  P.RaiseIt := True;
  D := TMemoryDistiller.Create(P, 'fake');
  try
    AssertTrue(not D.Distill(Convo, 'sess-3', '2026-06-26', Facts, Err), 'provider error -> False');
    AssertTrue(Pos('provider error', Err) > 0, 'ErrMsg names the cause');
    AssertEqInt(Length(Facts), 0, 'no facts on error');
  finally
    D.Free;
  end;
end;

procedure TestGarbageReplyYieldsNoFacts;
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
begin
  P := TScriptedProvider.Create;
  P.Reply := 'I could not find anything to remember, sorry!';
  D := TMemoryDistiller.Create(P, 'fake');
  try
    AssertTrue(D.Distill(Convo, 'sess-4', '2026-06-26', Facts, Err), 'non-JSON reply still ok');
    AssertEqInt(Length(Facts), 0, 'no facts from prose reply');
  finally
    D.Free;
  end;
end;

procedure TestMalformedBracesDoNotRaise;
{ Braces that are NOT valid JSON must be swallowed -> 0 facts, no crash
  (TJsonObject.Parse raises on these). }
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
begin
  P := TScriptedProvider.Create;
  P.Reply := 'sure: {not json, just braces ::}';
  D := TMemoryDistiller.Create(P, 'fake');
  try
    AssertTrue(D.Distill(Convo, 'sess-5', '2026-06-26', Facts, Err), 'malformed braces -> still ok');
    AssertEqInt(Length(Facts), 0, 'malformed braces -> no facts (no exception)');
  finally
    D.Free;
  end;
end;

procedure TestOversizedNewestMessageStillRenders;
{ When the newest message alone exceeds the byte budget, RenderTranscript
  must keep a truncated head rather than producing an empty transcript
  (which would skip the provider and silently return zero facts). }
var
  P: TScriptedProvider;
  D: TMemoryDistiller;
  Facts: TFactArray;
  Err: string;
  Big: TMessageArray;
begin
  P := TScriptedProvider.Create;
  P.Reply := '{"facts":[{"text":"something","kind":"static","scope":"user","confidence":0.8,"expires":""}]}';
  D := TMemoryDistiller.Create(P, 'fake');
  try
    D.MaxTranscriptChars := 50;
    SetLength(Big, 1);
    Big[0] := MakeMessage(mrUser, StringOfChar('x', 500));   { newest > budget }
    AssertTrue(D.Distill(Big, 'sess-6', '2026-06-26', Facts, Err), 'oversized ok');
    AssertEqInt(P.Calls, 1, 'provider WAS called (transcript not empty)');
    AssertEqInt(Length(Facts), 1, 'facts still extracted from truncated context');
  finally
    D.Free;
  end;
end;

begin
  TestSliceJsonObject;                  WriteLn('  ok: slice json object (fences/embedded)');
  TestNormaliseFact;                    WriteLn('  ok: normalise fact fields');
  TestDistillParsesAndNormalises;       WriteLn('  ok: distill parses + normalises + dedups');
  TestEmptyTranscriptSkipsProvider;     WriteLn('  ok: empty transcript skips provider');
  TestProviderErrorSurfaces;            WriteLn('  ok: provider error surfaces');
  TestGarbageReplyYieldsNoFacts;        WriteLn('  ok: non-JSON reply -> no facts');
  TestMalformedBracesDoNotRaise;        WriteLn('  ok: malformed braces -> no crash, no facts');
  TestOversizedNewestMessageStillRenders; WriteLn('  ok: oversized newest message still renders');
  WriteLn('PASS');
end.
