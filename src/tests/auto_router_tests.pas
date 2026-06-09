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

procedure TestRouteProviderEmptyModelOverride;
{ Operator set EasyProvider but left EasyModel blank -- caller
  should get an empty Model so it falls through to that
  provider's catalog default via NewProviderFromConfig. Pinned
  because earlier drafts accidentally echoed back the primary's
  model. }
var
  Cfg: TConfig;
  Provider, Model: string;
begin
  Cfg := TConfig.Create;
  try
    Cfg.AutoRouter.Enabled        := True;
    Cfg.AutoRouter.EasyProvider   := 'groq';
    Cfg.AutoRouter.EasyModel      := '';
    Cfg.AutoRouter.EasyMaxTokens  := 500;
    Cfg.DefaultProvider := 'anthropic';
    Cfg.DefaultModel    := 'claude-opus-4-8';
    SetLength(Cfg.Providers, 1);
    Cfg.Providers[0].Name := 'groq';
    Cfg.Providers[0].Kind := 'groq';
    AssertTrue(RouteProvider(Cfg, 'summarize this',
                              ReadOnlyTools, Provider, Model),
               'happy path resolves');
    AssertEqStr(Model, '', 'empty EasyModel means "use catalog default"');
  finally
    Cfg.Free;
  end;
end;

begin
  TestHardKeywordsBeatEverything;
  TestTokenCountThreshold;
  TestEasyKeywordsRouteEasy;
  TestWriteRunToolsBlockEasyOnAmbiguousIntent;
  TestWriteToolsAllowEasyWithEasyMarker;
  TestRouteProviderRespectsDisabledFlag;
  TestRouteProviderRefusesUnconfiguredEasyProvider;
  TestRouteProviderHappyPath;
  TestRouteProviderEmptyModelOverride;
  WriteLn('auto_router_tests: OK');
end.
