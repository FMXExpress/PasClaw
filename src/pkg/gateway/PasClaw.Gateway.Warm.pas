(*
  PasClaw.Gateway.Warm -- prompt-cache keep-alive.

  A provider's prompt cache expires after its TTL with no traffic. For an
  operator on a short TTL (Anthropic's 5m), a pause of six minutes
  between turns throws the whole cached system block + tool catalogue
  away and the next turn pays to write it again. The keep-alive sends
  one minimal request -- same system prompt, same tools, so the cached
  prefix matches, user text "ping", max_tokens 1 -- after four minutes
  of silence and every four minutes after that, and gives up thirty
  minutes after the last real turn. Off by default (prompt_cache.warm):
  with the one-hour TTL PasClaw defaults to it buys almost nothing, and
  every ping is a billed request. The pings are counted and shown in
  /v1/stats so the cost is visible.

  The snapshot is taken from the last real turn's loop config by the
  gateway (WarmNoteTurn); the gateway's tick thread calls WarmTick.
*)
unit PasClaw.Gateway.Warm;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.ToolLoop;

const
  WarmIdleAfterSec = 240;    { first ping after this much silence }
  WarmEverySec     = 240;    { and then this often }
  WarmStopAfterSec = 1800;   { until this long after the last real turn }

{ Pure: is a ping due now? LastPing = 0 means never pinged since the
  last turn. }
function WarmPingDue(NowT, LastTurn, LastPing: TDateTime;
                     IdleAfterSec, EverySec, StopAfterSec: Integer): Boolean;

{ Remember what the last real turn looked like: provider, model, system
  prompt, tool catalogue and options. Called by the gateway before each
  loop; cheap (a few string copies). }
procedure WarmNoteTurn(const Cfg: TToolLoopConfig);

{ Ping if enabled and due. True when a ping was sent. Safe to call from
  any thread; one ping at a time. }
function WarmTick(Enabled: Boolean): Boolean;

function WarmPingCount: Integer;

{ Tests: the time the next WarmTick considers "now" (0 = the clock). }
procedure WarmSetClock(FakeNow: TDateTime);

implementation

uses
  PasClaw.Logger;

var
  GLock:      TCriticalSection;
  GHave:      Boolean = False;
  GProvider:  ILLMProvider;
  GModel:     string;
  GTools:     TToolDefinitionArray;
  GOptions:   TChatOptions;
  GLastTurn:  TDateTime = 0;
  GLastPing:  TDateTime = 0;
  GPings:     Integer = 0;
  GClock:     TDateTime = 0;

function NowT: TDateTime;
begin
  if GClock <> 0 then Result := GClock else Result := Now;
end;

function WarmPingDue(NowT, LastTurn, LastPing: TDateTime;
                     IdleAfterSec, EverySec, StopAfterSec: Integer): Boolean;
var
  SinceTurn, SincePing: Double;
begin
  Result := False;
  if LastTurn = 0 then Exit;
  SinceTurn := (NowT - LastTurn) * 86400.0;
  if SinceTurn < IdleAfterSec then Exit;
  if SinceTurn > StopAfterSec then Exit;
  if LastPing <> 0 then
  begin
    SincePing := (NowT - LastPing) * 86400.0;
    if SincePing < EverySec then Exit;
  end;
  Result := True;
end;

procedure WarmNoteTurn(const Cfg: TToolLoopConfig);
var
  i: Integer;
  Defs: TToolDefinitionArray;
begin
  if Cfg.Provider = nil then Exit;
  if Cfg.Registry <> nil then Defs := Cfg.Registry.ToProviderDefs
  else SetLength(Defs, 0);
  GLock.Enter;
  try
    GProvider := Cfg.Provider;
    GModel := Cfg.Model;
    SetLength(GTools, Length(Defs));
    for i := 0 to High(Defs) do GTools[i] := Defs[i];
    GOptions := Cfg.Options;
    GLastTurn := NowT;
    GLastPing := 0;
    GHave := True;
  finally
    GLock.Leave;
  end;
end;

function WarmTick(Enabled: Boolean): Boolean;
var
  P: ILLMProvider;
  Model: string;
  Tools: TToolDefinitionArray;
  Opts: TChatOptions;
  Msgs: array[0..0] of TMessage;
  Resp: TLLMResponse;
  i: Integer;
begin
  Result := False;
  if not Enabled then Exit;
  GLock.Enter;
  try
    if (not GHave) or (not WarmPingDue(NowT, GLastTurn, GLastPing,
                                       WarmIdleAfterSec, WarmEverySec, WarmStopAfterSec)) then
      Exit;
    { Claim this slot before the call so a slow provider does not get a
      second ping from the next tick. }
    GLastPing := NowT;
    P := GProvider;
    Model := GModel;
    SetLength(Tools, Length(GTools));
    for i := 0 to High(GTools) do Tools[i] := GTools[i];
    Opts := GOptions;
  finally
    GLock.Leave;
  end;
  Opts.MaxTokens := 1;
  Opts.Stream := False;
  Opts.ThinkingLevel := '';
  Msgs[0] := MakeMessage(mrUser, 'ping');
  try
    Resp := P.Chat(Msgs, Tools, Model, Opts);
    GLock.Enter;
    try
      Inc(GPings);
    finally
      GLock.Leave;
    end;
    LogDebug('prompt-cache warm: ping %d (model=%s status=%d cache_read=%d)',
             [GPings, Model, Resp.StatusCode, Resp.Usage.CacheReadTokens]);
    Result := True;
  except
    on E: Exception do
      LogWarn('prompt-cache warm: ping failed: %s', [E.Message]);
  end;
end;

function WarmPingCount: Integer;
begin
  Result := GPings;
end;

procedure WarmSetClock(FakeNow: TDateTime);
begin
  GClock := FakeNow;
end;

initialization
  GLock := TCriticalSection.Create;

finalization
  GLock.Free;

end.
