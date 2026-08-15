program provider_retry_tests;
(*
  Covers the bounded same-provider retry added alongside the
  "a dead provider is not a model turn" guard.

  Two behaviours, and the second matters as much as the first:

    - an explicitly transient status (408 / 429 / 5xx) is retried up to
      ProviderRetryAttempts before anything else happens
    - status <= 0 is NOT retried. IsRetryableStatus counts those as
      retryable because a socket reset looks like one, but so does every
      permanent local misconfiguration -- a relay with no gateway, an
      unresolvable host. Retrying buys latency and the identical failure.

  A counting fake provider makes the call count the assertion.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop;

var Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if Cond then WriteLn('  ok   ', Msg)
  else begin WriteLn('  FAIL ', Msg); Inc(Failures); end;
end;

type
  { Answers with a fixed status N times, then 200. Counts every call. }
  TFlakyProvider = class(TInterfacedObject, ILLMProvider)
  public
    Calls: Integer;
    FailStatus: Integer;
    FailTimes: Integer;
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

function TFlakyProvider.Chat(const Messages: array of TMessage;
                             const Tools:    array of TToolDefinition;
                             const Model:    string;
                             const Options:  TChatOptions): TLLMResponse;
begin
  Result := Default(TLLMResponse);
  Inc(Calls);
  if Calls <= FailTimes then
  begin
    Result.StatusCode := FailStatus;
    Result.Content    := 'transient';
    Exit;
  end;
  Result.StatusCode   := 200;
  Result.Content      := 'recovered';
  Result.FinishReason := 'stop';
end;

function TFlakyProvider.ChatStream(const Messages: array of TMessage;
                                   const Tools:    array of TToolDefinition;
                                   const Model:    string;
                                   const Options:  TChatOptions;
                                   OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

function TFlakyProvider.GetDefaultModel: string;    begin Result := 'fake'; end;
function TFlakyProvider.GetName: string;            begin Result := 'flaky'; end;
function TFlakyProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TFlakyProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TFlakyProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function RunOnce(FailStatus, FailTimes, Attempts: Integer;
                 out Calls: Integer; out Content: string): Boolean;
var
  P: TFlakyProvider;
  Prov: ILLMProvider;
  Reg: TToolRegistry;
  Cfg: TToolLoopConfig;
  Loop: TToolLoopResult;
  Msgs: TMessageArray;
begin
  P := TFlakyProvider.Create;
  P.FailStatus := FailStatus;
  P.FailTimes  := FailTimes;
  Prov := P;
  Reg := TToolRegistry.Create;
  try
    Cfg := Default(TToolLoopConfig);
    Cfg.Provider      := Prov;
    Cfg.Registry      := Reg;
    Cfg.Model         := 'fake';
    Cfg.MaxIterations := 4;
    Cfg.ProviderRetryAttempts  := Attempts;
    Cfg.ProviderRetryBackoffMs := 1;   { keep the suite fast }
    SetLength(Msgs, 1);
    Msgs[0] := MakeMessage(mrUser, 'go');
    Result  := RunToolLoop(Cfg, Msgs, Loop);
    Calls   := P.Calls;
    Content := Loop.Content;
  finally
    Reg.Free;
  end;
end;

procedure TestTransientIsRetried;
var Calls: Integer; C: string;
begin
  WriteLn('429 is retried');
  RunOnce(429, 1, 2, Calls, C);
  Check(Calls = 2, 'one 429 then success = 2 calls (got ' + IntToStr(Calls) + ')');
  Check(C = 'recovered', 'the recovered answer is what the caller sees');
end;

procedure TestRetryIsBounded;
var Calls: Integer; C: string;
begin
  WriteLn('retries are bounded');
  RunOnce(503, 99, 2, Calls, C);
  Check(Calls = 3, 'initial + 2 attempts = 3 calls (got ' + IntToStr(Calls) + ')');
end;

procedure TestPermanentIsNotRetried;
var Calls: Integer; C: string;
begin
  WriteLn('status <= 0 is not retried');
  RunOnce(-1, 99, 2, Calls, C);
  Check(Calls = 1, 'a permanent -1 is called exactly once (got ' +
                   IntToStr(Calls) + ')');
end;

procedure TestZeroAttemptsDisables;
var Calls: Integer; C: string;
begin
  WriteLn('attempts=0 disables');
  RunOnce(429, 99, 0, Calls, C);
  Check(Calls = 1, 'no retry when attempts is 0 (got ' + IntToStr(Calls) + ')');
end;

begin
  TestTransientIsRetried;
  TestRetryIsBounded;
  TestPermanentIsNotRetried;
  TestZeroAttemptsDisables;
  WriteLn;
  if Failures = 0 then WriteLn('provider_retry_tests: OK')
  else begin WriteLn('provider_retry_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
