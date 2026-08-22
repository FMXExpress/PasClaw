(*
  stats_attribution_repro - is the /v1/stats by_model / by_provider
  breakdown accurate for gateway traffic?

  Reproduces AccumulateGatewayStatsRaw's exact sequence (open the bucket
  session by id, overwrite Meta.Model / Meta.Provider when non-empty,
  AccumulateTurnStats, Save) for a series of requests through ONE
  endpoint using DIFFERENT models -- which is what a web UI user does
  every time they switch model in the picker.

  The gateway unit cannot be linked into a test binary, so this drives
  the same primitives in the same order rather than calling
  AccumulateGatewayStatsRaw itself. Line-for-line correspondence is with
  PasClaw.Gateway.Server.pas AccumulateGatewayStatsRaw.

  Run it, then GET /v1/stats against the same PASCLAW_HOME and compare
  the by_model table against the ground truth this prints.
*)
program stats_attribution_repro;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Session.Store;

{ One gateway request through BucketId on (ProviderName, Model). Mirrors
  AccumulateGatewayStatsRaw: the scalar Meta.Model / Meta.Provider are
  overwritten, the counters accumulate. }
procedure OneRequest(const BucketId, ProviderName, Model: string;
                     InTok, OutTok: Int64);
var
  S: TSession;
begin
  S := TSession.Create(BucketId);
  try
    if (not S.MetaExists) and (S.Meta.Title = '') then
      S.Meta.Title := '(gateway: /v1/chat)';
    if Model        <> '' then S.Meta.Model    := Model;
    if ProviderName <> '' then S.Meta.Provider := ProviderName;
    AccumulateTurnStats(S.Meta, InTok, OutTok, 0, 0, 0, 0);
    S.Touch;
    S.Save;
  finally
    S.Free;
  end;
end;

var
  Home: string;
  i: Integer;
  TruthA, TruthB: Int64;
begin
  Home := GetHome;
  if GetEnvironmentVariable('PASCLAW_HOME') = '' then
  begin
    WriteLn('refusing to run without $PASCLAW_HOME');
    Halt(1);
  end;
  ForceDirectories(JoinPath(Home, ActiveWorkspaceName + '/sessions'));

  { 100 requests on the expensive model, then ONE on a cheap one --
    the shape of "I did a day's work on opus, then asked haiku one
    throwaway question". }
  TruthA := 0;
  for i := 1 to 100 do
  begin
    OneRequest('_gateway_v1_chat', 'anthropic', 'model-EXPENSIVE', 1000, 500);
    Inc(TruthA, 1500);
  end;

  TruthB := 0;
  OneRequest('_gateway_v1_chat', 'openai', 'model-CHEAP', 10, 5);
  Inc(TruthB, 15);

  WriteLn('ground truth (what actually happened):');
  WriteLn(Format('  model-EXPENSIVE : %d tokens over 100 requests', [TruthA]));
  WriteLn(Format('  model-CHEAP     : %d tokens over 1 request',    [TruthB]));
  WriteLn(Format('  provider anthropic : %d', [TruthA]));
  WriteLn(Format('  provider openai    : %d', [TruthB]));
  WriteLn;
  WriteLn('now GET /v1/stats against this PASCLAW_HOME and compare by_model.');
end.
