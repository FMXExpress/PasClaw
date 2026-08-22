(*
  stats_attribution_repro - the /v1/stats by_model / by_provider
  breakdown must credit the provider and model that actually spent the
  tokens.

  The bug this pins. Gateway endpoints fold stateless traffic into
  synthetic "bucket" sessions. TSessionMeta.Model / .Provider are scalar
  fields overwritten on every request, so a bucket keyed too coarsely
  attributes its ENTIRE cumulative total to whichever request landed
  last. Measured with buckets keyed by endpoint alone, 100 requests on
  one model then one on another:

      model-EXPENSIVE  150,000 tok / 100 reqs  ->  absent from by_model
      model-CHEAP           15 tok / 1 req     ->  150,015

  Totals (input, output, turns) were correct throughout; only the
  breakdown was wrong -- which is the half the web UI renders as a
  per-model table, with no caveat, next to a model picker that makes
  switching models routine.

  The fix is GatewayBucketId: one bucket per (endpoint, provider,
  model), plus a hash of the raw pair, so both scalars are true by
  construction.

  Two ways the first attempt at that fix was still wrong, both caught by
  Codex P2 on PR #586 and both pinned below:

    1. Keying on model alone left by_provider with the identical
       defect -- two providers serving one model string share a bucket.
       The first version of this suite could not have caught it: it
       varied model and provider TOGETHER, so its provider assertions
       passed for the wrong reason. TestAttributionByProvider now holds
       the model constant and varies only the provider.

    2. The readable part of the id is lossy -- "openai/gpt-5" and
       "openai:gpt-5" flatten to one string, trailing separators are
       stripped, and anything past the length cap is truncated. Any
       collision merges counters and reinstates the misattribution.
       TestNoCollisions pins the pairs that flatten identically.

  Why this test drives primitives rather than the gateway: the gateway
  unit cannot be linked into a test binary, so the checks below call
  TSession + AccumulateTurnStats in the same order
  AccumulateGatewayStatsRaw does, and reimplement GatewayBucketId as
  ExpectBucketId. That is a real limitation -- it pins the BEHAVIOUR the
  gateway depends on, not the gateway's own call, so a divergence in
  GatewayBucketId would leave these green while the gateway broke.

  Not covered: the aggregation itself (HandleStats lives in the gateway
  unit). This asserts the on-disk shape the aggregator reads -- one
  bucket per (provider, model), each carrying only its own tokens.
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
   id-shape assertions below, which spell out exact expected strings. *)
function Fnv1a32(const S: string): LongWord;
var
  i: Integer;
begin
  Result := LongWord($811C9DC5);
  for i := 1 to Length(S) do
  begin
    Result := Result xor LongWord(Byte(S[i]));
    Result := Result * LongWord($01000193);
  end;
end;

function ExpectBucketId(const Endpoint, ProviderName, Model: string): string;
const
  MaxReadable = 64;
var
  i: Integer;
  C: Char;
  Clean, Raw: string;
begin
  Raw := ProviderName + #1 + Model;
  if (ProviderName = '') and (Model = '') then Exit(Endpoint);
  Clean := '';
  for i := 1 to Length(Raw) do
  begin
    C := Raw[i];
    if ((C >= 'a') and (C <= 'z')) or ((C >= 'A') and (C <= 'Z')) or
       ((C >= '0') and (C <= '9')) or (C = '-') or (C = '_') then
      Clean := Clean + C
    else
      Clean := Clean + '-';
    if Length(Clean) >= MaxReadable then Break;
  end;
  while (Clean <> '') and (Clean[Length(Clean)] = '-') do
    SetLength(Clean, Length(Clean) - 1);
  while (Clean <> '') and (Clean[1] = '-') do
    Delete(Clean, 1, 1);
  Result := Endpoint + '_';
  if Clean <> '' then Result := Result + Clean + '-';
  Result := Result + LowerCase(IntToHex(Fnv1a32(Raw), 8));
end;

{ One gateway request. Mirrors AccumulateGatewayStatsRaw's sequence. }
procedure OneRequest(const Endpoint, ProviderName, Model: string;
                     InTok, OutTok: Int64);
var
  S: TSession;
begin
  S := TSession.Create(ExpectBucketId(Endpoint, ProviderName, Model));
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
{ Legality and stability of every minted id. }
var
  A, B: string;
begin
  Check('every minted id is a legal session id',
    IsSafeSessionId(ExpectBucketId(EP, 'anthropic', 'claude-3.5:beta')));
  Check('minted ids are still recognised as gateway buckets',
    IsGatewayBucketSessionId(ExpectBucketId(EP, 'anthropic', 'claude-opus-4-7')));
  Check('long model stays within the 128-char id ceiling',
    Length(ExpectBucketId(EP, StringOfChar('p', 200), StringOfChar('m', 400))) <= 128);
  CheckEqStr('empty provider AND model falls back to the bare endpoint',
    ExpectBucketId(EP, '', ''), EP);

  { Dot must not survive: an id ending ".orig" is treated as a pre-prune
    archive by IsSessionArchiveId and skipped by every listing. }
  Check('no dot survives sanitising',
    Pos('.', ExpectBucketId(EP, 'anthropic', 'claude-3.5-sonnet')) = 0);

  { Deterministic -- the id must be stable across calls or every restart
    orphans yesterday's bucket. }
  A := ExpectBucketId(EP, 'anthropic', 'claude-opus-4-7');
  B := ExpectBucketId(EP, 'anthropic', 'claude-opus-4-7');
  CheckEqStr('id is deterministic', A, B);
end;

procedure TestNoCollisions;
(* Codex P2 on PR #586: the readable part is lossy, so it cannot carry
   identity on its own. Each pair below flattens to the SAME readable
   prefix and must still land in different buckets -- a collision merges
   counters and reinstates the misattribution this file exists to
   prevent. *)
  procedure Distinct(const Name, P1, M1, P2, M2: string);
  var
    A, B: string;
  begin
    A := ExpectBucketId(EP, P1, M1);
    B := ExpectBucketId(EP, P2, M2);
    if A <> B then WriteLn('  ok   ', Name)
    else
    begin
      WriteLn(Format('  FAIL %s: both -> %s', [Name, A]));
      Inc(Failures);
    end;
  end;
begin
  Distinct('slash vs colon in the model',
           'openai', 'openai/gpt-5', 'openai', 'openai:gpt-5');
  Distinct('same model, different provider',
           'anthropic', 'claude-opus-4-7', 'openrouter', 'claude-opus-4-7');
  { Field-boundary confusion: provider "a" + model "bc" must not hash
    the same as provider "ab" + model "c". }
  Distinct('provider/model boundary is not ambiguous',
           'a', 'bc', 'ab', 'c');
  { Truncation: two ids sharing the first 64 readable chars. Realistic
    for dated or versioned model names. }
  Distinct('long models sharing a 64-char prefix',
           'anthropic', StringOfChar('m', 70) + '-VARIANT-ONE',
           'anthropic', StringOfChar('m', 70) + '-VARIANT-TWO');
  { Trailing separators are stripped, so these share a readable part. }
  Distinct('trailing separators do not merge ids',
           'openai', 'gpt-5/', 'openai', 'gpt-5:');
end;

procedure TestAttributionByModel;
(* The original regression: 100 requests on the expensive model, then
   one on a cheap one, through one endpoint. *)
var
  i: Integer;
  Tok: Int64;
  M, P: string;
begin
  for i := 1 to 100 do
    OneRequest(EP, 'anthropic', 'model-EXPENSIVE', 1000, 500);
  OneRequest(EP, 'openai', 'model-CHEAP', 10, 5);

  Tok := BucketTokens(ExpectBucketId(EP, 'anthropic', 'model-EXPENSIVE'), M, P);
  CheckEq   ('expensive bucket tokens',   Tok, 150000);
  CheckEqStr('expensive bucket model',    M,   'model-EXPENSIVE');
  CheckEqStr('expensive bucket provider', P,   'anthropic');

  Tok := BucketTokens(ExpectBucketId(EP, 'openai', 'model-CHEAP'), M, P);
  CheckEq   ('cheap bucket tokens',   Tok, 15);
  CheckEqStr('cheap bucket model',    M,   'model-CHEAP');
  CheckEqStr('cheap bucket provider', P,   'openai');

  Check('no un-scoped endpoint bucket remains',
        BucketTokens(EP, M, P) = -1);
end;

procedure TestAttributionByProvider;
(* Codex P2 on PR #586. The first version of this suite varied model and
   provider TOGETHER, so its provider assertions passed for the wrong
   reason and could never have caught a model-only key. Here the model
   string is IDENTICAL and only the provider differs -- what happens when
   /v1/config switches the primary provider, or when a direct vendor key
   and an aggregator both serve one name. *)
var
  i: Integer;
  Tok: Int64;
  M, P: string;
begin
  for i := 1 to 50 do
    OneRequest(EP, 'anthropic', 'shared-model', 200, 100);
  OneRequest(EP, 'openrouter', 'shared-model', 2, 1);

  Tok := BucketTokens(ExpectBucketId(EP, 'anthropic', 'shared-model'), M, P);
  CheckEq   ('direct-provider bucket tokens',   Tok, 15000);
  CheckEqStr('direct-provider bucket provider', P,   'anthropic');
  CheckEqStr('direct-provider bucket model',    M,   'shared-model');

  Tok := BucketTokens(ExpectBucketId(EP, 'openrouter', 'shared-model'), M, P);
  CheckEq   ('aggregator bucket tokens',   Tok, 3);
  CheckEqStr('aggregator bucket provider', P,   'openrouter');
  CheckEqStr('aggregator bucket model',    M,   'shared-model');
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
  TestNoCollisions;
  TestAttributionByModel;
  TestAttributionByProvider;

  if Failures = 0 then begin WriteLn('OK'); Halt(0); end
  else begin WriteLn(Failures, ' failure(s)'); Halt(1); end;
end.
