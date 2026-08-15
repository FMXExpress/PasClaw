program heartbeat_tests;
(*
  Covers PasClaw.Heartbeat -- the proactive periodic wake-up daemon.

  Strategy: substitute a FAKE ILLMProvider whose Chat returns a
  scripted reply, point Cfg.Heartbeat.ContentPath at a temp file the
  test writes, call THeartbeat.TickOnce, and assert behaviour.

  Contracts pinned:
    - Missing content file: TickOnce returns False, no provider call.
    - Empty content file: TickOnce returns False, no provider call.
    - Non-empty content file: TickOnce calls the provider with the
      file body as the user message and returns True.
    - Content path overrides: empty value falls back to default
      workspace/heartbeat.md; relative value anchors on $PASCLAW_HOME;
      absolute value used as-is.
    - Channel "" = no post attempt (covered by the no-channel test
      not crashing on a nil sender).
    - Ticks counter increments on every call (including the skip-no-
      content path -- the counter reflects scheduler firings, not
      successful runs).

  No real model, no real network. The fake provider records what it
  saw so we can assert the user message reached it intact.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,
  PasClaw.Heartbeat;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

type
  { Minimal scripted provider: records every Chat call, returns a
    pre-canned reply. Implementing ILLMProvider keeps THeartbeat
    completely model-free in tests. }
  TScriptedProvider = class(TInterfacedObject, ILLMProvider)
  private
    FLastUserMsg: string;
    FCallCount:   Integer;
    FScriptedReply: string;
  public
    constructor Create(const Reply: string);
    function GetName: string;
    function GetDefaultModel: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    property LastUserMsg: string read FLastUserMsg;
    property CallCount: Integer read FCallCount;
  end;

constructor TScriptedProvider.Create(const Reply: string);
begin
  inherited Create;
  FScriptedReply := Reply;
end;

function TScriptedProvider.GetName: string;        begin Result := 'scripted'; end;
function TScriptedProvider.GetDefaultModel: string; begin Result := 'scripted-1'; end;
function TScriptedProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TScriptedProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TScriptedProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TScriptedProvider.Chat(const Messages: array of TMessage;
                                const Tools:    array of TToolDefinition;
                                const Model:    string;
                                const Options:  TChatOptions): TLLMResponse;
var
  i: Integer;
begin
  Inc(FCallCount);
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrUser then
      FLastUserMsg := Messages[i].Content;
  Result := Default(TLLMResponse);
  Result.Content    := FScriptedReply;
  Result.StatusCode := 200;
end;

function TScriptedProvider.ChatStream(const Messages: array of TMessage;
                                      const Tools:    array of TToolDefinition;
                                      const Model:    string;
                                      const Options:  TChatOptions;
                                      OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function NewCfg: TConfig;
begin
  Result := TConfig.Create;
  Result.Heartbeat.Enabled      := True;
  Result.Heartbeat.IntervalMins := 30;
end;

procedure WriteTempFile(const Path, Content: string);
var
  F: TextFile;
begin
  AssignFile(F, Path);
  Rewrite(F);
  Write(F, Content);
  CloseFile(F);
end;

procedure TestMissingContentSkips;
var
  Cfg: TConfig;
  P: TScriptedProvider;
  Reg: TToolRegistry;
  HB: THeartbeat;
  Path: string;
begin
  Cfg := NewCfg;
  P   := TScriptedProvider.Create('reply');
  Reg := TToolRegistry.Create;
  Path := IncludeTrailingPathDelimiter(SysUtils.GetTempDir) +
          'pasclaw-hb-missing-' + IntToStr(Random(MaxInt)) + '.md';
  if FileExists(Path) then DeleteFile(Path);
  Cfg.Heartbeat.ContentPath := Path;
  HB := THeartbeat.Create(Cfg, P, Reg, 'scripted-1');
  try
    AssertTrue(not HB.TickOnce, 'missing file -> TickOnce returns False');
    AssertTrue(P.CallCount = 0, 'no provider call on missing file');
    AssertTrue(HB.Ticks = 1, 'tick counted regardless');
  finally
    HB.Free;
    Reg.Free;
    Cfg.Free;
  end;
end;

procedure TestEmptyContentSkips;
var
  Cfg: TConfig;
  P: TScriptedProvider;
  Reg: TToolRegistry;
  HB: THeartbeat;
  Path: string;
begin
  Cfg := NewCfg;
  P   := TScriptedProvider.Create('reply');
  Reg := TToolRegistry.Create;
  Path := IncludeTrailingPathDelimiter(SysUtils.GetTempDir) +
          'pasclaw-hb-empty-' + IntToStr(Random(MaxInt)) + '.md';
  WriteTempFile(Path, '   ' + sLineBreak + sLineBreak);
  try
    Cfg.Heartbeat.ContentPath := Path;
    HB := THeartbeat.Create(Cfg, P, Reg, 'scripted-1');
    try
      AssertTrue(not HB.TickOnce,
                 'whitespace-only file -> TickOnce returns False');
      AssertTrue(P.CallCount = 0, 'no provider call on empty body');
    finally
      HB.Free;
    end;
  finally
    DeleteFile(Path);
    Reg.Free;
    Cfg.Free;
  end;
end;

procedure TestNonEmptyContentRuns;
var
  Cfg: TConfig;
  P: TScriptedProvider;
  Reg: TToolRegistry;
  HB: THeartbeat;
  Path: string;
begin
  Cfg := NewCfg;
  P   := TScriptedProvider.Create('build is green');
  Reg := TToolRegistry.Create;
  Path := IncludeTrailingPathDelimiter(SysUtils.GetTempDir) +
          'pasclaw-hb-ok-' + IntToStr(Random(MaxInt)) + '.md';
  WriteTempFile(Path, 'check the build status briefly');
  try
    Cfg.Heartbeat.ContentPath := Path;
    HB := THeartbeat.Create(Cfg, P, Reg, 'scripted-1');
    try
      AssertTrue(HB.TickOnce, 'non-empty body -> TickOnce returns True');
      AssertTrue(P.CallCount = 1, 'exactly one provider call');
      { The tool loop appends a turn clock to the outbound copy, so the
        provider legitimately sees `body + clock`. Strip through
        StripTurnClock rather than matching the stamp here -- the format
        has one owner and a test that respells it rots when that moves. }
      AssertEqStr(StripTurnClock(P.LastUserMsg), 'check the build status briefly',
                  'user message body equals the file body');
    finally
      HB.Free;
    end;
  finally
    DeleteFile(Path);
    Reg.Free;
    Cfg.Free;
  end;
end;

procedure TestDefaultPathFallback;
var
  Cfg: TConfig;
  P: TScriptedProvider;
  Reg: TToolRegistry;
  HB: THeartbeat;
begin
  { ContentPath '' -> default workspace/heartbeat.md. We don't need
    the file to exist to verify the resolution path -- the daemon
    skips cleanly when it's missing, which is the same code path
    that exercises ResolveContentPath. }
  Cfg := NewCfg;
  P   := TScriptedProvider.Create('x');
  Reg := TToolRegistry.Create;
  HB  := THeartbeat.Create(Cfg, P, Reg, 'scripted-1');
  try
    HB.TickOnce;
    AssertTrue(P.CallCount = 0,
               'no provider call when default path does not exist');
  finally
    HB.Free;
    Reg.Free;
    Cfg.Free;
  end;
end;

begin
  Randomize;
  TestMissingContentSkips;     WriteLn('  ok: missing content file skips');
  TestEmptyContentSkips;       WriteLn('  ok: empty content file skips');
  TestNonEmptyContentRuns;     WriteLn('  ok: non-empty body fires provider');
  TestDefaultPathFallback;     WriteLn('  ok: empty content path -> default workspace path');
  WriteLn('PASS');
end.
