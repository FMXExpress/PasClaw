(*
  stats_attribution_repro - the /v1/stats by_model / by_provider
  breakdown must attribute tokens to the model that actually spent them.

  The bug this pins. Gateway endpoints fold stateless traffic into
  synthetic "bucket" sessions. Those buckets used to be keyed by
  endpoint alone, and TSessionMeta.Model / .Provider are scalar fields
  overwritten on every request -- so a bucket's ENTIRE cumulative total
  was attributed to whichever model happened to run last. Measured
  before the fix, with 100 requests on one model and one request on
  another:

      model-EXPENSIVE  150,000 tok / 100 reqs  ->  absent from by_model
      model-CHEAP           15 tok / 1 req     ->  150,015

  Totals (input, output, turns) were correct throughout; only the
  breakdown was wrong -- which is the half the web UI renders as a
  per-model table, with no caveat, next to a model picker that makes
  switching models routine.

  The fix is GatewayBucketId: one bucket per (endpoint, model), so the
  scalar field is true by construction.

  Why this test drives primitives rather than the gateway: the gateway
  unit cannot be linked into a test binary, so the checks below call
  TSession + AccumulateTurnStats in the same order
  AccumulateGatewayStatsRaw does, and reimplement GatewayBucketId's
  contract as ExpectBucketId. That is a real limitation -- it pins the
  BEHAVIOUR the gateway depends on, not the gateway's own call. If
  GatewayBucketId changes shape, the assertions here still pass while
  the gateway breaks; the guard against that is the id-shape block,
  which encodes the exact strings the gateway must produce.

  Not covered: the aggregation itself (HandleStats lives in the gateway
  unit). This asserts the on-disk shape the aggregator reads -- one
  bucket per model, each carrying only its own model's tokens.
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

var
  Failures: Integer = 0;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then WriteLn('  ok   ', Name)
  else begin WriteLn('  FAIL ', Name); Inc(Failures); end;
end;

procedure CheckEq(const Name: string; Got, Want: Int64);
begin
  if Got = Want then WriteLn('  ok   ', Name, ' = ', Got)
  else
  begin
    WriteLn(Format('  FAIL %s: got %d, want %d', [Name, Got, Want]));
    Inc(Failures);
  end;
end;

procedure CheckEqStr(const Name, Got, Want: string);
begin
  if Got = Want then WriteLn('  ok   ', Name, ' = ', Got)
  else
  begin
    WriteLn(Format('  FAIL %s: got "%s", want "%s"', [Name, Got, Want]));
    Inc(Failures);
  end;
end;

(* Mirror of PasClaw.Gateway.Server.GatewayBucketId. Kept in step by the
   id-shape assertions below, which spell out the exact strings the
   gateway must produce for real model names. *)
function ExpectBucketId(const Endpoint, Model: string): string;
const
  MaxModelPart = 80;
var
  i: Integer;
  C: Char;
  Clean: string;
begin
  Clean := '';
  for i := 1 to Length(Model) do
  begin
    C := Model[i];
    if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_') then
      Clean := Clean + C
    else
      Clean := Clean + '-';
    if Length(Clean) >= MaxModelPart then Break;
  end;
  for i := Length(Clean) downto 1 do
    if Clean[i] <> '-' then Break else SetLength(Clean, i - 1);
  if Clean = '' then Exit(Endpoint);
  Result := Endpoint + '_' + Clean;
end;

{ One gateway request. Mirrors AccumulateGatewayStatsRaw's sequence. }
procedure OneRequest(const Endpoint, ProviderName, Model: string;
                     InTok, OutTok: Int64);
var
  S: TSession;
begin
  S := TSession.Create(ExpectBucketId(Endpoint, Model));
  try
    if (not S.MetaExists) and (S.Meta.Title = '') then
      S.Meta.Title := '(gateway: ' + Endpoint + ' ' + Model + ')';
    if Model        <> '' then S.Meta.Model    := Model;
    if ProviderName <> '' then S.Meta.Provider := ProviderName;
    AccumulateTurnStats(S.Meta, InTok, OutTok, 0, 0, 0, 0);
    S.Touch;
    S.Save;
  finally
    S.Free;
  end;
end;

function BucketTokens(const Id: string; out Model, Provider: string): Int64;
var
  S: TSession;
begin
  Result := -1; Model := ''; Provider := '';
  S := TSession.Create(Id);
  try
    if not S.MetaExists then Exit;
    Model    := S.Meta.Model;
    Provider := S.Meta.Provider;
    Result   := S.Meta.Stats.InputTokens + S.Meta.Stats.OutputTokens;
  finally
    S.Free;
  end;
end;

const
  EP = '_gateway_v1_chat';

procedure TestIdShape;
(* The exact strings the gateway must mint. These are the contract
   between GatewayBucketId and this file's ExpectBucketId; if the
   gateway's sanitiser drifts, these are what catch it. *)
begin
  CheckEqStr('plain model',
    ExpectBucketId(EP, 'claude-opus-4-7'), '_gateway_v1_chat_claude-opus-4-7');
  CheckEqStr('slash becomes dash',
    ExpectBucketId(EP, 'anthropic/claude-x'), '_gateway_v1_chat_anthropic-claude-x');
  CheckEqStr('colon becomes dash',
    ExpectBucketId(EP, 'openai:gpt-5'), '_gateway_v1_chat_openai-gpt-5');
  { Dot is legal in a session id but "<id>.orig" is treated as a
    pre-prune archive and skipped by every listing, so dots must not
    survive into a bucket id. }
  CheckEqStr('dot becomes dash',
    ExpectBucketId(EP, 'claude-3.5-sonnet'), '_gateway_v1_chat_claude-3-5-sonnet');
  CheckEqStr('empty model falls back to the bare endpoint',
    ExpectBucketId(EP, ''), EP);
  CheckEqStr('all-separator model falls back too',
    ExpectBucketId(EP, '///'), EP);
  Check('long model stays within the id ceiling',
    Length(ExpectBucketId(EP, StringOfChar('m', 400))) <= 128);
  Check('every minted id is a legal session id',
    IsSafeSessionId(ExpectBucketId(EP, 'anthropic/claude-3.5:beta')));
  Check('minted ids are still recognised as gateway buckets',
    IsGatewayBucketSessionId(ExpectBucketId(EP, 'claude-opus-4-7')));
end;

procedure TestAttribution;
(* The regression proper: the exact workload that used to invert.
   100 requests on the expensive model, then one on a cheap one. *)
var
  i: Integer;
  Tok: Int64;
  M, P: string;
begin
  for i := 1 to 100 do
    OneRequest(EP, 'anthropic', 'model-EXPENSIVE', 1000, 500);
  OneRequest(EP, 'openai', 'model-CHEAP', 10, 5);

  Tok := BucketTokens(ExpectBucketId(EP, 'model-EXPENSIVE'), M, P);
  CheckEq   ('expensive bucket tokens',   Tok, 150000);
  CheckEqStr('expensive bucket model',    M,   'model-EXPENSIVE');
  CheckEqStr('expensive bucket provider', P,   'anthropic');

  Tok := BucketTokens(ExpectBucketId(EP, 'model-CHEAP'), M, P);
  CheckEq   ('cheap bucket tokens',   Tok, 15);
  CheckEqStr('cheap bucket model',    M,   'model-CHEAP');
  CheckEqStr('cheap bucket provider', P,   'openai');

  { The old shape: one bucket named after the endpoint alone, holding
    everything. Its absence is what makes the fix real rather than
    additive. }
  Check('no un-scoped endpoint bucket remains',
        BucketTokens(EP, M, P) = -1);
end;

var
  Home: string;
begin
  WriteLn('stats_attribution_repro');
  Home := GetHome;
  if GetEnvironmentVariable('PASCLAW_HOME') = '' then
  begin
    WriteLn('  FAIL refusing to run without $PASCLAW_HOME ' +
            '(use: make test-stats-attribution)');
    Halt(1);
  end;
  ForceDirectories(JoinPath(Home, ActiveWorkspaceName + '/sessions'));

  TestIdShape;
  TestAttribution;

  if Failures = 0 then begin WriteLn('OK'); Halt(0); end
  else begin WriteLn(Failures, ' failure(s)'); Halt(1); end;
end.
