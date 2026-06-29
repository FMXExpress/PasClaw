program auto_router_tests;
(*
  Covers PasClaw.Agent.AutoRouter -- the task-difficulty
  classifier + the routing decision.

  We pin:
    - hard keyword markers win outright (long-form work)
    - token-count threshold catches sneaky-long messages even
      with no hard keywords
    - easy keyword markers route easy ONLY when the short-and-
      read-only side conditions agree
    - tool-mix gate: write/run tools in the loop's allowlist
      tip ambiguous messages to abstain (we don't know if
      "yes" / "continue" means run-the-code-now)
    - RouteProvider returns False when the router is disabled,
      when EasyProvider is empty, and when EasyProvider doesn't
      resolve against Cfg.Providers (operator config drift)

  The classifier is intentionally conservative -- abstain-on-
  ambiguous is the design. False-hard costs the operator extra
  tokens; false-easy costs them a fumbled task. Bias to safe.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Agent.AutoRouter;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqDiff(Got, Want: TTaskDifficulty; const Msg: string);
const
  Labels: array[TTaskDifficulty] of string = ('easy', 'abstain', 'hard');
begin
  if Got <> Want then
    Fail_(Msg + ' (got ' + Labels[Got] + ', want ' + Labels[Want] + ')');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

const
  NoTools: array[0..0] of string = ('');
  ReadOnlyTools: array[0..1] of string = ('fs_read', 'fs_list');
  FullTools: array[0..3] of string =
    ('fs_read', 'fs_list', 'shell_exec', 'execute_code');

procedure TestHardKeywordsBeatEverything;
{ A short message asking for implementation work routes hard
  even when an easy keyword also appears -- "refactor and
  summarise" is fundamentally a refactor task. Order matters
  in the classifier; this pins it. }
begin
  AssertEqDiff(ClassifyTask('implement the auth flow', ReadOnlyTools, 500),
               tdHard, 'implement -> hard');
  AssertEqDiff(ClassifyTask('refactor and summarise the parser', ReadOnlyTools, 500),
               tdHard, 'hard marker beats easy marker');
  AssertEqDiff(ClassifyTask('debug the failing test', NoTools, 500),
               tdHard, 'debug -> hard');
  AssertEqDiff(ClassifyTask('fix the bug in PolarRouter', NoTools, 500),
               tdHard, '"fix the bug" -> hard');
  AssertEqDiff(ClassifyTask('write tests for the new module', NoTools, 500),
               tdHard, 'write tests -> hard');
  AssertEqDiff(ClassifyTask('please optimize the inner loop', NoTools, 500),
               tdHard, 'optimize -> hard');
end;

procedure TestTokenCountThreshold;
{ A long message routes hard even with no hard keywords -- a
  500-token prose dump is real work no matter how it's phrased.
  Default threshold is 500 tokens (~2000 chars at 4 chars/token);
  test with explicit thresholds to keep the assertion stable. }
var
  LongMsg: string;
begin
  LongMsg := StringOfChar('x', 2500);  { ~625 tokens }
  AssertEqDiff(ClassifyTask(LongMsg, ReadOnlyTools, 500), tdHard,
               'long message -> hard');
  { Same content under a higher threshold abstains (no hard
    markers, no easy markers, no write tools). }
  AssertEqDiff(ClassifyTask(LongMsg, ReadOnlyTools, 10000), tdAbstain,
               'long message under raised threshold -> abstain');
end;

procedure TestEasyKeywordsRouteEasy;
{ Easy markers + short message + read-only tools = the cheap-
  tier sweet spot. All three conditions must agree -- the
  classifier won't route a "summarise" call that's running
  alongside execute_code in the registry. }
begin
  AssertEqDiff(ClassifyTask('summarize the README', ReadOnlyTools, 500),
               tdEasy, 'summarize + read-only tools -> easy');
  AssertEqDiff(ClassifyTask('what is mode delphi in fpc', ReadOnlyTools, 500),
               tdEasy, '"what is" question -> easy');
  AssertEqDiff(ClassifyTask('list files in src/', ReadOnlyTools, 500),
               tdEasy, 'list query -> easy');
  AssertEqDiff(ClassifyTask('translate to french: hello', NoTools, 500),
               tdEasy, 'translate -> easy');
end;

procedure TestWriteRunToolsBlockEasyOnAmbiguousIntent;
{ A short, unmarked message ("yes", "continue", "ok do that")
  could mean "now go run the script you proposed". With
  execute_code in the registry, abstain rather than route -- we
  don't know what's about to happen. }
begin
  AssertEqDiff(ClassifyTask('yes', FullTools, 500), tdAbstain,
               '"yes" with write/run tools available -> abstain');
  AssertEqDiff(ClassifyTask('continue', FullTools, 500), tdAbstain,
               '"continue" with write/run tools -> abstain');
  AssertEqDiff(ClassifyTask('ok', FullTools, 500), tdAbstain,
               '"ok" with write/run tools -> abstain');
  { Same message, read-only tool surface only -- still abstain
    because there's no easy marker either. Just confirms the
    abstain path isn't accidentally tied to the tool mix. }
  AssertEqDiff(ClassifyTask('yes', ReadOnlyTools, 500), tdAbstain,
               '"yes" with read-only tools -> abstain (no easy marker)');
end;

procedure TestWriteToolsAllowEasyWithEasyMarker;
{ Easy marker + write/run tools in registry = still easy. The
  marker is what carries the read-only intent. "summarize the
  output of `ls`" is fine regardless of execute_code being
  registered. }
begin
  AssertEqDiff(ClassifyTask('summarize what shell_exec returned',
                            FullTools, 500),
               tdEasy, 'summarize wins over tool-mix gate');
  AssertEqDiff(ClassifyTask('explain what this script does',
                            FullTools, 500),
               tdEasy, 'explain wins over tool-mix gate');
end;

procedure TestRouteProviderRespectsDisabledFlag;
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled       := False;
    Cfg.AutoRouter.EasyProvider  := 'cheap';
    Cfg.AutoRouter.EasyMaxTokens := 500;
    { Even with a clearly-easy message, the flag-off path
      returns False so the caller stays on the primary. }
    AssertTrue(not RouteProvider(Cfg, 'summarize this',
                                  ReadOnlyTools, Provider, Model),
               'flag off -> RouteProvider returns False');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderRefusesUnconfiguredEasyProvider;
{ Operator typo / catalog drift: EasyProvider names something
  that isn't in Cfg.Providers. Stay on primary instead of
  crashing the turn. }
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := 'phantom-provider';
    Cfg.AutoRouter.EasyMaxTokens := 500;
    { Cfg.Providers is empty by default -- nothing for
      "phantom-provider" to match against. }
    AssertTrue(not RouteProvider(Cfg, 'summarize this',
                                  ReadOnlyTools, Provider, Model),
               'unresolvable EasyProvider -> RouteProvider returns False');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderHappyPath;
{ All conditions agree: flag on, configured EasyProvider, easy
  message. RouteProvider returns True with the provider name
  set and the optional model override threaded through. }
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled        := True;
    Cfg.AutoRouter.EasyProvider   := 'groq';
    Cfg.AutoRouter.EasyModel      := 'llama-3.3-70b-versatile';
    Cfg.AutoRouter.EasyMaxTokens  := 500;
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name := 'groq';
    Cfg.Providers[0].Kind := 'groq';

    AssertTrue(RouteProvider(Cfg, 'summarize this readme',
                              ReadOnlyTools, Provider, Model),
               'easy + configured + enabled -> route');
    AssertEqStr(Provider, 'groq',                     'routed to EasyProvider');
    AssertEqStr(Model,    'llama-3.3-70b-versatile', 'EasyModel threaded through');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderFallsBackToProviderStoredModel;
(* Codex P2 on PR #203: an empty EasyModel must NOT leave the
   caller passing the primary's model name to the cheap
   provider's chat endpoint (claude-* to Groq fails). The router
   now resolves the model itself: explicit EasyModel ->
   per-provider stored Model -> catalog DefaultModel. This case
   exercises the middle step. *)
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled        := True;
    Cfg.AutoRouter.EasyProvider   := 'groq';
    Cfg.AutoRouter.EasyModel      := '';   { no explicit override }
    Cfg.AutoRouter.EasyMaxTokens  := 500;
    Cfg.DefaultProvider := 'anthropic';
    Cfg.DefaultModel    := 'claude-opus-4-8';
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name  := 'groq';
    Cfg.Providers[0].Kind  := 'groq';
    Cfg.Providers[0].Model := 'llama-3.3-70b-stored-by-onboard';

    AssertTrue(RouteProvider(Cfg, 'summarize this',
                              ReadOnlyTools, Provider, Model),
               'happy path resolves');
    AssertEqStr(Model, 'llama-3.3-70b-stored-by-onboard',
                'empty EasyModel falls back to provider config Model');
    AssertTrue(Model <> 'claude-opus-4-8',
               'primary model never leaks into the routed Model');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderResolvesCatalogDefault;
(* Third step of the model resolution chain: explicit EasyModel
   blank, per-provider Model blank, but Kind points at a catalog
   entry with a non-empty DefaultModel. The router picks up the
   catalog value. Anthropic is a stable test target -- its
   catalog spec has carried a non-empty DefaultModel across
   every release. *)
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled        := True;
    Cfg.AutoRouter.EasyProvider   := 'anthropic';
    Cfg.AutoRouter.EasyMaxTokens  := 500;
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name  := 'anthropic';
    Cfg.Providers[0].Kind  := 'anthropic';
    Cfg.Providers[0].Model := '';        { force catalog-default fall-through }
    AssertTrue(RouteProvider(Cfg, 'summarize this',
                              ReadOnlyTools, Provider, Model),
               'catalog-default fall-through resolves');
    AssertTrue(Model <> '', 'catalog default produced a non-empty model');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderRefusesWithoutResolvableModel;
(* Sibling of the test above: when EasyModel is empty, the
   per-provider Model is empty, AND the catalog lookup misses
   (Kind = '' or unknown), refuse to route rather than hand the
   loop an empty model name. Caller stays on the primary. *)
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled        := True;
    Cfg.AutoRouter.EasyProvider   := 'mystery';
    Cfg.AutoRouter.EasyMaxTokens  := 500;
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name  := 'mystery';
    Cfg.Providers[0].Kind  := '';        { won't match any catalog entry }
    Cfg.Providers[0].Model := '';
    AssertTrue(not RouteProvider(Cfg, 'summarize this',
                                  ReadOnlyTools, Provider, Model),
               'no resolvable model -> refuse to route');
    AssertEqStr(Provider, '', 'no Provider leaks on refusal');
    AssertEqStr(Model,    '', 'no Model leaks on refusal');
  finally
    Cfg.Free;
  end;
end;

procedure TestNilToolsArraySafe;
(* Codex P2 on PR #203: --no-tools mode leaves the registry nil.
   The agent loop now passes a nil/empty tool list to
   ClassifyTask -- pin that this doesn't crash and routes the
   same as "read-only tools" (no write/run gate fires). *)
var
  Empty: array of string;
begin
  SetLength(Empty, 0);
  AssertEqDiff(ClassifyTask('summarize this', Empty, 500),
               tdEasy,
               'nil/empty tool list + easy marker -> easy');
  AssertEqDiff(ClassifyTask('yes', Empty, 500),
               tdAbstain,
               'nil/empty tool list + ambiguous -> abstain (not crash)');
end;

procedure TestClassifyScoreMonotonic;
{ The structural score is the new Wayfinder-shaped engine. We don't pin exact
  values (weights are tunable) -- we pin the relationships that must hold:
  easy markers lower the score, length / code fences / hard keywords raise it,
  and a trivial message scores below the default threshold while a structured
  one scores above. }
var
  W: TRouterWeights;
  Trivial, WithFence, Longer, EasyOne, HardOne: Double;
  Big: string;
begin
  W := DefaultAutoRouterWeights;
  Trivial   := ClassifyScore('hello there', NoTools, W);
  EasyOne   := ClassifyScore('summarize the readme', NoTools, W);
  WithFence := ClassifyScore('here is code ```let x = 1``` ok', NoTools, W);
  HardOne   := ClassifyScore('implement the parser', NoTools, W);
  Big := StringOfChar('x', 1600);   { ~400 tokens, under the 500 cap }
  Longer := ClassifyScore(Big, NoTools, W);

  AssertTrue(Trivial < W.Threshold, 'trivial message scores below threshold');
  AssertTrue(EasyOne < Trivial, 'easy marker lowers the score');
  AssertTrue(WithFence > Trivial, 'a code fence raises the score');
  AssertTrue(HardOne > Trivial, 'a hard keyword raises the score');
  AssertTrue(Longer > W.Threshold, 'a long message scores above threshold');
end;

procedure TestClassifyScoreZeroWeightsFallBack;
{ A zeroed weights record (TConfig built without Create) must not collapse
  scoring -- EffectiveWeights substitutes the defaults. }
var
  Zero: TRouterWeights;
  S: Double;
begin
  FillChar(Zero, SizeOf(Zero), 0);
  S := ClassifyScore('summarize the readme', NoTools, Zero);
  AssertTrue((S > 0) and (S < 1), 'zeroed weights fall back to defaults (score in range)');
end;

procedure TestRouteProviderRoutesUnmarkedLowScore;
{ New capability over the v1 keyword-only path: a low-complexity message with
  NO easy marker now routes on the score alone (once it clears the
  continuation floor). }
var
  Cfg: TConfig;
  Provider, Model: string;
  Score: Double;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := 'groq';
    Cfg.AutoRouter.EasyModel     := 'llama-3.3-70b-versatile';
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name := 'groq';
    Cfg.Providers[0].Kind := 'groq';
    AssertTrue(RouteProvider(Cfg, 'who wrote the linux kernel originally',
                             ReadOnlyTools, Provider, Model, Score),
               'unmarked low-score message routes on score');
    AssertTrue((Score >= 0) and (Score <= Cfg.AutoRouter.Weights.Threshold),
               'routed message score is at/under threshold');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderStructuralVeto;
{ The score's safety value: a message with an easy marker but heavy structure
  (a big fenced code block) does NOT route -- the fences + length push it back
  over the threshold even though "explain" is present. }
var
  Cfg: TConfig;
  Provider, Model: string;
  Score: Double;
  Heavy: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := 'groq';
    Cfg.AutoRouter.EasyModel     := 'llama-3.3-70b-versatile';
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name := 'groq';
    Cfg.Providers[0].Kind := 'groq';
    Heavy := 'explain this ```' + StringOfChar('a', 1200) + '```';
    AssertTrue(not RouteProvider(Cfg, Heavy, ReadOnlyTools, Provider, Model, Score),
               'easy marker + heavy structure -> score veto, no route');
    AssertTrue(Score > Cfg.AutoRouter.Weights.Threshold,
               'heavy message scored above threshold');
  finally
    Cfg.Free;
  end;
end;

procedure TestRouteProviderContinuationFloor;
{ A bare one-word continuation must NOT route even with read-only tools: in an
  agent loop "ok" means "carry on with the current (maybe hard) task". }
var
  Cfg: TConfig;
  Provider, Model: string;
  Score: Double;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled       := True;
    Cfg.AutoRouter.EasyProvider  := 'groq';
    Cfg.AutoRouter.EasyModel     := 'llama-3.3-70b-versatile';
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name := 'groq';
    Cfg.Providers[0].Kind := 'groq';
    AssertTrue(not RouteProvider(Cfg, 'ok', ReadOnlyTools, Provider, Model, Score),
               'bare continuation stays on primary (continuation floor)');
  finally
    Cfg.Free;
  end;
end;

begin
  TestHardKeywordsBeatEverything;
  TestTokenCountThreshold;
  TestClassifyScoreMonotonic;
  TestClassifyScoreZeroWeightsFallBack;
  TestRouteProviderRoutesUnmarkedLowScore;
  TestRouteProviderStructuralVeto;
  TestRouteProviderContinuationFloor;
  TestEasyKeywordsRouteEasy;
  TestWriteRunToolsBlockEasyOnAmbiguousIntent;
  TestWriteToolsAllowEasyWithEasyMarker;
  TestRouteProviderRespectsDisabledFlag;
  TestRouteProviderRefusesUnconfiguredEasyProvider;
  TestRouteProviderHappyPath;
  TestRouteProviderFallsBackToProviderStoredModel;
  TestRouteProviderResolvesCatalogDefault;
  TestRouteProviderRefusesWithoutResolvableModel;
  TestNilToolsArraySafe;
  WriteLn('auto_router_tests: OK');
end.
