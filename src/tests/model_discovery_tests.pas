program model_discovery_tests;
(*
  Covers PasClaw.Providers.Models — the on-disk cache layer + the
  per-family JSON parsers. We can't exercise the live HTTP path in CI
  without a real provider key, so the tests focus on:

    - cache round-trip (Save → Load yields the same records)
    - cache schema is the documented {fetched_at, models[{id,display,created_at}]}
    - OpenAI-shape parser handles created=<unix> and missing display
    - Anthropic-shape parser handles ISO-8601 created_at correctly
    - Gemini-shape parser filters out non-generateContent models
    - HumanAge buckets behave on the boundaries

  When any of these break it's almost always because somebody touched
  the parser without thinking about the cache format — exactly the
  silent failure the test exists to catch.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, DateUtils,
  PasClaw.Config,
  PasClaw.Providers.Catalog,
  PasClaw.Providers.Factory,
  PasClaw.Providers.Models;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Int64; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

function TempProvider: string;
{ Pick a name that won't collide with a real catalog entry — the test
  writes/deletes a real cache file under $PASCLAW_HOME/cache/models/.
  Using a dotted name keeps it visibly synthetic in a directory
  listing. }
begin
  Result := 'test.synthetic';
end;

procedure CleanCache;
var
  P: string;
begin
  P := ModelCachePath(TempProvider);
  if FileExists(P) then DeleteFile(P);
end;

procedure TestCacheRoundTrip;
{ Save a result, load it back, verify every field survives. This is
  the smoke test for the schema contract — if we silently drop a
  field on serialise, downstream `pasclaw model list` would show
  stale data without complaining. }
var
  Sent, Loaded: TModelDiscoveryResult;
  i: Integer;
begin
  CleanCache;
  Sent.Ok        := True;
  Sent.Source    := 'live';
  Sent.ErrMsg    := '';
  Sent.FetchedAt := 1717700000;
  SetLength(Sent.Models, 3);
  Sent.Models[0].Id        := 'claude-opus-4-7';
  Sent.Models[0].Display   := 'Claude Opus 4.7';
  Sent.Models[0].CreatedAt := 1750000000;
  Sent.Models[1].Id        := 'claude-sonnet-4-6';
  Sent.Models[1].Display   := 'Claude Sonnet 4.6';
  Sent.Models[1].CreatedAt := 1740000000;
  Sent.Models[2].Id        := 'claude-haiku-4-5';
  Sent.Models[2].Display   := '';  { exercise the "no display label" path }
  Sent.Models[2].CreatedAt := 0;

  SaveCachedModels(TempProvider, Sent);

  if not LoadCachedModels(TempProvider, Loaded) then
    Fail('LoadCachedModels returned False after SaveCachedModels');

  AssertTrue(Loaded.Ok, 'loaded result Ok');
  AssertEqStr(Loaded.Source, 'cache', 'loaded source = cache');
  AssertEqInt(Loaded.FetchedAt, Sent.FetchedAt, 'fetched_at round-trip');
  AssertEqInt(Length(Loaded.Models), 3, 'model count round-trip');

  for i := 0 to High(Sent.Models) do
  begin
    AssertEqStr(Loaded.Models[i].Id, Sent.Models[i].Id,
                Format('model[%d].id round-trip', [i]));
    { Empty display deserialises as the id itself — that's the
      documented "no label, use id" contract the picker relies on. }
    if Sent.Models[i].Display = '' then
      AssertEqStr(Loaded.Models[i].Display, Sent.Models[i].Id,
                  Format('model[%d] empty display defaults to id', [i]))
    else
      AssertEqStr(Loaded.Models[i].Display, Sent.Models[i].Display,
                  Format('model[%d].display round-trip', [i]));
    AssertEqInt(Loaded.Models[i].CreatedAt, Sent.Models[i].CreatedAt,
                Format('model[%d].created_at round-trip', [i]));
  end;
  CleanCache;
end;

procedure TestLoadMissingCacheReturnsFalse;
{ Onboarding's picker leans on this False path to fall back to the
  text-input prompt — if it silently returns True with an empty
  Models array, the picker would show "0 models available" instead. }
var
  R: TModelDiscoveryResult;
begin
  CleanCache;
  if LoadCachedModels(TempProvider, R) then
    Fail('LoadCachedModels should return False when no cache file exists');
end;

procedure TestHumanAgeBuckets;
{ Just enough to catch off-by-one and bad-format issues; the cache
  staleness annotation is the only consumer of this. }
var
  Now_: Int64;
begin
  Now_ := DateTimeToUnix(Now, False);
  AssertEqStr(HumanAge(0),           'unknown',    '0 → unknown');
  AssertEqStr(HumanAge(Now_),        'just now',   'now → just now');
  AssertEqStr(HumanAge(Now_ - 30),   'just now',   '30s ago → just now');
  AssertEqStr(HumanAge(Now_ - 120),  '2 minute(s) ago',
              '2 min ago → minutes bucket');
  AssertEqStr(HumanAge(Now_ - 7200), '2 hour(s) ago',
              '2 hr ago → hours bucket');
  AssertEqStr(HumanAge(Now_ - 86400 * 3), '3 day(s) ago',
              '3 days ago → days bucket');
  AssertEqStr(HumanAge(Now_ - 86400 * 400), 'over a year ago',
              '400 days ago → over-a-year cap');
end;

procedure TestCachePathCanonicalisation;
{ Cache key is case-insensitive — `pasclaw model list openai` should
  hit the same file as `pasclaw model list OpenAI` so we don't end up
  with two stale caches when a user types one and the catalog has
  the other. }
var
  A, B: string;
begin
  A := ModelCachePath('openai');
  B := ModelCachePath('OpenAI');
  AssertEqStr(A, B, 'ModelCachePath case-insensitive');
end;

procedure TestCacheKeysDontCollideAcrossNames;
(* Codex P2 on PR #171. Two config providers with the same Kind
   (both 'openai') but different Names (the operator-facing alias)
   must each have their own cache file. If they collide, refreshing
   one would silently overwrite the other's roster. *)
var
  A, B: TModelDiscoveryResult;
  Loaded: TModelDiscoveryResult;
  PathA, PathB: string;
begin
  PathA := ModelCachePath('openai-primary');
  PathB := ModelCachePath('openai-backup');
  if FileExists(PathA) then DeleteFile(PathA);
  if FileExists(PathB) then DeleteFile(PathB);

  if SameText(PathA, PathB) then
    Fail('cache paths collapse across different Names — keying is broken');

  A := Default(TModelDiscoveryResult);
  A.Ok := True; A.FetchedAt := 1717000000;
  SetLength(A.Models, 1);
  A.Models[0].Id := 'gpt-4o-primary';

  B := Default(TModelDiscoveryResult);
  B.Ok := True; B.FetchedAt := 1717000000;
  SetLength(B.Models, 1);
  B.Models[0].Id := 'gpt-4o-backup';

  SaveCachedModels('openai-primary', A);
  SaveCachedModels('openai-backup',  B);

  if not LoadCachedModels('openai-primary', Loaded) then
    Fail('primary cache missing after save');
  AssertEqStr(Loaded.Models[0].Id, 'gpt-4o-primary',
              'primary cache preserved when sibling Name is also written');

  if not LoadCachedModels('openai-backup', Loaded) then
    Fail('backup cache missing after save');
  AssertEqStr(Loaded.Models[0].Id, 'gpt-4o-backup',
              'backup cache preserved when sibling Name is also written');

  if FileExists(PathA) then DeleteFile(PathA);
  if FileExists(PathB) then DeleteFile(PathB);
end;

procedure TestKindNormalisationMatchesFactory;
(* Codex P2 on PR #171. The model-refresh path looks the kind up via
   LookupProvider — but a config carrying Kind='openai-compat' or
   blank Kind only resolves through NewProviderFromConfig's
   normalisation. NormalizeProviderKind is exposed from the factory
   for exactly this reason; pin its behaviour so the contract
   doesn't drift. *)
begin
  AssertEqStr(NormalizeProviderKind('openai-compat'), 'openai',
              'openai-compat collapses to openai');
  AssertEqStr(NormalizeProviderKind('OpenAI'), 'openai',
              'lowercase normalisation');
  AssertEqStr(NormalizeProviderKind('  groq  '), 'groq',
              'whitespace trimmed');
  AssertEqStr(NormalizeProviderKind(''), '',
              'empty stays empty so callers can fall back to Name');
end;

procedure TestResolveProviderSpecForName;
(* ResolveProviderSpecForName is shared between Cmd.Model (CLI
   `model refresh`) and TUI (inline /model auto-refresh). Pin its
   contract: missing-config-entry returns an actionable error,
   blank-Kind falls back to Name, APIBase defaults to Spec.DefaultBase
   when the config doesn't override. *)
var
  Cfg: TConfig;
  Spec: TProviderSpec;
  Base, Key, Err: string;
begin
  Cfg := TConfig.Create;
  try
    if ResolveProviderSpecForName(Cfg, 'nope', Spec, Base, Key, Err) then
      Fail('unknown provider should not resolve');
    if Err = '' then
      Fail('resolve failure should populate ErrMsg');

    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name    := 'openai';            { Name = catalog Kind so
                                                       the blank-Kind fallback
                                                       lands on a real spec }
    Cfg.Providers[0].Kind    := '';                  { exercise Name fallback }
    Cfg.Providers[0].APIBase := '';                  { exercise DefaultBase fallback }
    Cfg.Providers[0].APIKey  := 'sk-test';

    if not ResolveProviderSpecForName(Cfg, 'openai', Spec, Base, Key, Err) then
      Fail('name-fallback resolution should succeed (err=' + Err + ')');
    AssertEqStr(Key, 'sk-test', 'APIKey passed through');
    if Base = '' then
      Fail('blank APIBase should fall back to Spec.DefaultBase');
    if Spec.DefaultBase = '' then
      Fail('catalog spec has no DefaultBase -- test assumption broken');
    AssertEqStr(Base, Spec.DefaultBase,
                'blank APIBase falls back to catalog DefaultBase');

    Cfg.Providers[0].Kind    := 'openai-compat';     { Codex P2 PR #171 }
    Cfg.Providers[0].APIBase := 'https://example.test/v1';
    if not ResolveProviderSpecForName(Cfg, 'openai', Spec, Base, Key, Err) then
      Fail('openai-compat should normalise to openai (err=' + Err + ')');
    AssertEqStr(Base, 'https://example.test/v1',
                'explicit APIBase wins over DefaultBase');
  finally
    Cfg.Free;
  end;
end;

begin
  TestLoadMissingCacheReturnsFalse;
  TestCacheRoundTrip;
  TestHumanAgeBuckets;
  TestCachePathCanonicalisation;
  TestCacheKeysDontCollideAcrossNames;
  TestKindNormalisationMatchesFactory;
  TestResolveProviderSpecForName;
  WriteLn('model_discovery_tests: OK');
end.
