program instructions_tests;
(*
  The `instructions` list (BuildInstructionsSection) and prompt-cache warm
  scheduling (WarmPingDue / WarmTick).

  Instructions:
    - a file relative to the base dir is injected under its path
    - a glob lists matches sorted; a missing file is skipped
    - an oversized body is capped with an elision note
    - an http URL with a fresh cache file is served from the cache (no
      network in the test); an empty list yields ''
    - config round-trip of "instructions"
  Warm:
    - WarmPingDue table: before idle, in window, every-N spacing, after stop
    - WarmTick with a fake provider: disabled -> no call; enabled and due
      -> one call with max_tokens 1, the noted model and tools; not due
      again until EverySec later; counter increments
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes, DateUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Prompt,
  PasClaw.Crypto.HMAC,
  PasClaw.Gateway.Warm;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Want + '")'); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 400)); end;

var
  Base: string;

function HexSha(const S: string): string;
var
  H: TBytes;
  i: Integer;
begin
  H := SHA256Bytes(TEncoding.UTF8.GetBytes(S));
  Result := '';
  for i := 0 to High(H) do Result := Result + LowerCase(IntToHex(H[i], 2));
end;

procedure TestInstructions;
var
  S, Big, URL, CachePath: string;
  i: Integer;
  Cfg: TConfig;
begin
  Base := JoinPath(GetTempDir, 'pasclaw-instr-' + IntToStr(GetProcessID));
  ForceDirectories(JoinPath(Base, 'rules'));
  ForceDirectories(JoinPath(Base, 'docs'));
  WriteFileText(JoinPath(Base, 'docs/style.md'), 'Use tabs. Never spaces.');
  WriteFileText(JoinPath(Base, 'rules/b.md'), 'rule b');
  WriteFileText(JoinPath(Base, 'rules/a.md'), 'rule a');
  WriteFileText(JoinPath(Base, 'rules/notes.txt'), 'not matched');

  AssertEqStr(BuildInstructionsSection([], Base), '', 'empty list -> nothing');
  S := BuildInstructionsSection(['docs/style.md', 'rules/*.md', 'missing.md'], Base);
  AssertContains(S, '## Instructions', 'header');
  AssertContains(S, '### ' + JoinPath(Base, 'docs/style.md'), 'file named');
  AssertContains(S, 'Use tabs. Never spaces.', 'file body');
  AssertTrue(Pos('rule a', S) < Pos('rule b', S), 'glob sorted a before b');
  AssertTrue(Pos('not matched', S) = 0, 'glob mask respected');
  AssertTrue(Pos('missing.md', S) = 0, 'missing file skipped silently');

  { Cap. }
  Big := '';
  for i := 1 to 70000 do Big := Big + 'x';
  WriteFileText(JoinPath(Base, 'big.md'), Big);
  S := BuildInstructionsSection(['big.md'], Base);
  AssertContains(S, 'elided', 'oversized body capped');
  AssertTrue(Length(S) < 66000, 'section bounded');

  { URL from a fresh cache file: no network touched. }
  URL := 'https://example.invalid/team.md';
  CachePath := JoinPath(JoinPath(JoinPath(GetHome, 'cache'), 'instructions'), HexSha(URL) + '.md');
  ForceDirectories(ExtractFileDir(CachePath));
  WriteFileText(CachePath, 'team rules from cache');
  S := BuildInstructionsSection([URL], Base);
  AssertContains(S, '### ' + URL, 'url named');
  AssertContains(S, 'team rules from cache', 'served from cache');

  { Config round-trip. }
  Cfg := TConfig.Create;
  try
    AssertEqInt(Length(Cfg.Instructions), 0, 'default empty');
    Cfg.FromJSON('{"instructions":["docs/style.md"," rules/*.md "]}');
    AssertEqInt(Length(Cfg.Instructions), 2, 'parsed');
    AssertEqStr(Cfg.Instructions[1], 'rules/*.md', 'trimmed');
    AssertContains(Cfg.ToJSON, '"instructions"', 'emitted');
    Cfg.FromJSON('{"prompt_cache":{"warm":true}}');
    AssertTrue(Cfg.PromptCache.Warm, 'warm parsed');
    AssertContains(Cfg.ToJSON, '"warm"', 'warm emitted');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: instructions files / glob / cap / cached url; config round-trip');
end;

{ ---- warm ---- }

type
  TCountingProvider = class(TInterfacedObject, ILLMProvider)
  public
    Calls: Integer;
    LastMaxTokens, LastToolCount: Integer;
    LastModel: string;
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

function TCountingProvider.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                                const Model: string; const Options: TChatOptions): TLLMResponse;
begin
  Inc(Calls);
  LastMaxTokens := Options.MaxTokens;
  LastToolCount := Length(Tools);
  LastModel := Model;
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Result.Content := 'pong';
  Result.FinishReason := 'stop';
end;

function TCountingProvider.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                                      const Model: string; const Options: TChatOptions;
                                      OnChunk: TStreamCallback): TLLMResponse;
begin Result := Chat(Messages, Tools, Model, Options); end;
function TCountingProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TCountingProvider.GetName: string; begin Result := 'fake-count'; end;
function TCountingProvider.SupportsThinking: Boolean; begin Result := False; end;
function TCountingProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TCountingProvider.SupportsStreaming: Boolean; begin Result := False; end;

function Probe(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Result := 'ok'; end;

procedure TestWarm;
var
  T0: TDateTime;
  P: TCountingProvider;
  PI: ILLMProvider;
  Reg: TToolRegistry;
  Tool: TTool;
  Cfg: TToolLoopConfig;
begin
  T0 := EncodeDateTime(2026, 10, 17, 12, 0, 0, 0);
  AssertTrue(not WarmPingDue(T0, 0, 0, 240, 240, 1800), 'no turn yet');
  AssertTrue(not WarmPingDue(IncSecond(T0, 100), T0, 0, 240, 240, 1800), 'before idle threshold');
  AssertTrue(WarmPingDue(IncSecond(T0, 240), T0, 0, 240, 240, 1800), 'at idle threshold');
  AssertTrue(not WarmPingDue(IncSecond(T0, 300), T0, IncSecond(T0, 240), 240, 240, 1800), 'too soon after a ping');
  AssertTrue(WarmPingDue(IncSecond(T0, 480), T0, IncSecond(T0, 240), 240, 240, 1800), 'next ping due');
  AssertTrue(not WarmPingDue(IncSecond(T0, 1801), T0, IncSecond(T0, 1680), 240, 240, 1800), 'stopped after 30 min');

  P := TCountingProvider.Create;
  PI := P;
  Reg := TToolRegistry.Create;
  try
    FillChar(Tool, SizeOf(Tool), 0);
    Tool.Name := 'probe'; Tool.Description := 'd'; Tool.Schema := '{"type":"object"}';
    Tool.Handler := @Probe; Tool.Category := tcReadOnly;
    Reg.Register(Tool);
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider := PI;
    Cfg.Registry := Reg;
    Cfg.Model := 'warm-model';
    Cfg.Options := DefaultChatOptions;
    Cfg.Options.SystemPrompt := 'SYS';
    Cfg.Options.MaxTokens := 4096;

    WarmSetClock(T0);
    WarmNoteTurn(Cfg);
    AssertTrue(not WarmTick(False), 'disabled -> no ping');
    AssertTrue(not WarmTick(True), 'enabled but not idle yet');
    WarmSetClock(IncSecond(T0, 250));
    AssertTrue(WarmTick(True), 'idle -> ping');
    AssertEqInt(P.Calls, 1, 'one provider call');
    AssertEqInt(P.LastMaxTokens, 1, 'max_tokens 1');
    AssertEqInt(P.LastToolCount, 1, 'same tools');
    AssertEqStr(P.LastModel, 'warm-model', 'same model');
    AssertEqInt(WarmPingCount, 1, 'counted');
    AssertTrue(not WarmTick(True), 'not again right away');
    WarmSetClock(IncSecond(T0, 500));
    AssertTrue(WarmTick(True), 'again after EverySec');
    AssertEqInt(P.Calls, 2, 'two calls');
    WarmSetClock(IncSecond(T0, 2000));
    AssertTrue(not WarmTick(True), 'stopped after the window');
    { A new turn resets the clock. }
    WarmNoteTurn(Cfg);
    AssertTrue(not WarmTick(True), 'fresh turn: not idle');
    WarmSetClock(IncSecond(T0, 2300));
    AssertTrue(WarmTick(True), 'idle again after the new turn');
    AssertEqInt(WarmPingCount, 3, 'three pings total');
    WarmSetClock(0);
  finally
    Reg.Free;
  end;
  WriteLn('  ok: WarmPingDue table, WarmTick with a counting provider');
end;

begin
  TestInstructions;
  TestWarm;
  WriteLn('PASS');
end.
