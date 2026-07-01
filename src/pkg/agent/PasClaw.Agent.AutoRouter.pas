(*
  PasClaw.Agent.AutoRouter -- task-difficulty classifier that picks a
  cheaper provider for simple turns, falling through to the primary
  for anything that looks like real work.

  Borrowed shape from UltraCode-Shim: classify the user message before
  the loop fires, route to a "cheap tier" provider when the heuristics
  agree it's easy, otherwise stay on the primary. Sits on top of the
  existing Cfg.Fallbacks machinery -- the operator already names the
  candidate pool by authenticating fallback providers; the router just
  picks which member of that pool to call FIRST for a given turn.

  Heuristic, not a model: deliberately. Spinning up a separate
  difficulty-classification LLM call per turn would eat the cost
  savings we're trying to capture. The heuristic is intentionally
  conservative -- abstain on anything ambiguous, route the operator
  back to their primary. Cost of a false-easy (model fumbles a
  complex request) > cost of a false-hard (we paid more than we had
  to). Default-route-to-primary is the safe bias.

  Three signals, all cheap to compute:
    1. Token count of the latest user message. Long messages are
       almost always real work -- code review, refactor, multi-step
       implementation. Above EasyMaxTokens (default 500) → tdHard.
    2. Tool mix: if any tool in this loop's allowlist suggests the
       agent is going to be writing or running code (shell_exec,
       execute_code, fs_write, fs_edit_hashline) and the message
       isn't visibly read-only, lean hard. Pure read-only tool
       loops (fs_read + fs_list) over a short message → fine for
       cheap.
    3. Keyword markers. The English the operator types is a
       cheap signal: "implement", "refactor", "debug", "fix bug",
       "write tests" → hard. "summarize", "what is", "list",
       "translate", "explain" + short message → easy. Order
       matters: hard markers win over easy ones if both appear.

  When all three agree on tdEasy AND Cfg.AutoRouter.Enabled is True
  AND Cfg.AutoRouter.EasyProvider is non-empty and resolves to a
  configured provider, RouteProvider returns True with the cheap
  provider name. Otherwise returns False and the caller uses the
  primary it already had.

  Out of scope: per-model "quality tier" pricing data. We trust the
  operator's manual pick (whatever they put in
  Cfg.AutoRouter.EasyProvider). If they pointed it at GPT-5, that's
  their call -- the router will still route easy tasks to it. The
  classifier doesn't second-guess.
*)
unit PasClaw.Agent.AutoRouter;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  PasClaw.Config;

type
  TTaskDifficulty = (tdEasy, tdAbstain, tdHard);

(* Classify a single user message against the heuristic. Exposed
   so a test can pin the contract without standing up the rest of
   the agent stack. ToolNamesInUse is the registry's tool name
   list at this point in the loop (e.g. ['fs_read', 'fs_list',
   'shell_exec', 'execute_code']); pass an empty array when the
   loop is running with --no-tools. *)
function ClassifyTask(const UserMessage: string;
                      const ToolNamesInUse: array of string;
                      EasyMaxTokens: Integer): TTaskDifficulty;

(* Structural complexity score in 0..1 (Wayfinder-shaped): a logistic of a
   weighted linear sum of cheap, deterministic features -- estimated token
   count (the dominant term), code-fence / list / heading counts, and
   hard/easy keyword + write-run-tool signals. Higher = harder. No model
   call, no network. Exposed so a caller (or test) can read the score
   directly -- "you get a score and a recommendation, what you do with it is
   up to you." Pass DefaultAutoRouterWeights (or Cfg.AutoRouter.Weights) for
   W; a zeroed record falls back to the defaults. *)
function ClassifyScore(const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       const W: TRouterWeights): Double;

(* Decide whether to route this turn to the cheap provider. Returns True
   (and writes the routed provider's name + model to RoutedProvider /
   RoutedModel, and the computed complexity score to RoutedScore) when the
   structural score is at/under the configured threshold AND the categorical
   safety rails don't veto it (hard keyword, over-length, write/run-tool
   ambiguity) AND the router is enabled AND EasyProvider resolves in
   Cfg.Providers. Returns False otherwise -- the caller keeps the primary.
   RoutedScore is set whenever scoring runs (>= 0), or -1 when the router
   short-circuits before scoring (disabled / no easy provider). *)
function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string;
                       out RoutedScore: Double): Boolean; overload;
{ Back-compat shorthand that discards the score. }
function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string): Boolean; overload;

implementation

uses
  SysUtils,
  StrUtils,
  Math,
  PasClaw.Tokenizer,
  PasClaw.Providers.Catalog;

const
  DefaultEasyMaxTokens = 500;
  { Below this many estimated tokens an unmarked message is treated as a
    continuation ("yes", "ok", "continue") and kept on the primary even if it
    scores low -- in an agent loop a bare one-word turn usually means "carry
    on with the (possibly hard) thing", not a standalone easy question. An
    explicit easy marker bypasses this floor. }
  MinScoreRouteTokens = 6;

  HardKeywords: array[0..14] of string = (
    'implement', 'refactor', 'debug', 'fix bug', 'fix the bug',
    'write tests', 'add tests', 'design', 'architect',
    'optimize', 'rewrite', 'port to', 'migrate', 'review',
    'pr feedback'
  );

  { Markers that suggest a write- or run-oriented session. Pure
    read-only loops can still be "easy"; once we see one of these
    in the tool registry the bar goes up unless the message is
    visibly read-only (handled below via the keyword sweep). }
  WriteOrRunTools: array[0..6] of string = (
    'shell_exec', 'execute_code',
    'write_file', 'append_file', 'edit_file',
    'fs_write', 'fs_edit_hashline'   { back-compat aliases in older sessions }
  );

  EasyKeywords: array[0..7] of string = (
    'summarize', 'what is', 'what does', 'list ',
    'translate', 'explain', 'one sentence', 'one-sentence'
  );

function ContainsAny(const Haystack: string;
                     const Needles: array of string): Boolean;
var
  Lo: string;
  i: Integer;
begin
  Lo := LowerCase(Haystack);
  for i := Low(Needles) to High(Needles) do
    if Pos(Needles[i], Lo) > 0 then Exit(True);
  Result := False;
end;

function HasAnyToolMatching(const ToolNames: array of string;
                            const Targets: array of string): Boolean;
var
  i, j: Integer;
begin
  for i := Low(ToolNames) to High(ToolNames) do
    for j := Low(Targets) to High(Targets) do
      if SameText(ToolNames[i], Targets[j]) then Exit(True);
  Result := False;
end;

function CountSubstr(const S, Sub: string): Integer;
var
  P, Start: Integer;
begin
  Result := 0;
  if Sub = '' then Exit;
  Start := 1;
  repeat
    P := PosEx(Sub, S, Start);
    if P = 0 then Break;
    Inc(Result);
    Start := P + Length(Sub);
  until False;
end;

{ Single pass over the message counting markdown heading lines (leading '#')
  and list-item lines (leading '-'/'*'/'N.'/'N)' followed by a space). Cheap
  structural signals: a prompt full of lists/headings is usually a spec or
  multi-step task, not a one-liner. }
procedure CountLineMarkers(const S: string; out Headings, ListItems: Integer);
var
  i, j, k, len: Integer;
begin
  Headings := 0;
  ListItems := 0;
  len := Length(S);
  i := 1;
  while i <= len do
  begin
    j := i;
    while (j <= len) and ((S[j] = ' ') or (S[j] = #9)) do Inc(j);
    if j <= len then
    begin
      if S[j] = '#' then
        Inc(Headings)
      else if ((S[j] = '-') or (S[j] = '*')) and (j < len) and (S[j + 1] = ' ') then
        Inc(ListItems)
      else if (S[j] >= '0') and (S[j] <= '9') then
      begin
        k := j;
        while (k <= len) and (S[k] >= '0') and (S[k] <= '9') do Inc(k);
        if (k < len) and ((S[k] = '.') or (S[k] = ')')) and (S[k + 1] = ' ') then
          Inc(ListItems);
      end;
    end;
    while (i <= len) and (S[i] <> #10) do Inc(i);
    Inc(i);
  end;
end;

function CountKeywordHits(const LowerMsg: string;
                         const Needles: array of string): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := Low(Needles) to High(Needles) do
    if Pos(Needles[i], LowerMsg) > 0 then Inc(Result);
end;

function Sigmoid(X: Double): Double;
var
  E: Double;
begin
  if X >= 0 then
    Result := 1.0 / (1.0 + Exp(-X))
  else
  begin
    E := Exp(X);
    Result := E / (1.0 + E);
  end;
end;

{ A TConfig built without Create (or with a hand-zeroed weights block) would
  carry an all-zero TRouterWeights -- which would score everything at 0.5 with
  a 0 threshold. Substitute the defaults so scoring is always well-defined. }
function EffectiveWeights(const W: TRouterWeights): TRouterWeights;
begin
  if (W.Threshold = 0) and (W.Tokens = 0) and (W.Bias = 0) then
    Result := DefaultAutoRouterWeights
  else
    Result := W;
end;

function ClassifyScore(const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       const W: TRouterWeights): Double;
var
  EW: TRouterWeights;
  Lo: string;
  Tokens, Fences, Headings, ListItems, HardHits, EasyHits, WriteRun: Integer;
  Raw: Double;
begin
  EW := EffectiveWeights(W);
  Lo := LowerCase(UserMessage);
  Tokens := EstimateTokens(UserMessage);
  Fences := CountSubstr(UserMessage, '```');
  CountLineMarkers(UserMessage, Headings, ListItems);
  HardHits := CountKeywordHits(Lo, HardKeywords);
  EasyHits := CountKeywordHits(Lo, EasyKeywords);
  if HasAnyToolMatching(ToolNamesInUse, WriteOrRunTools) then
    WriteRun := 1
  else
    WriteRun := 0;

  Raw := EW.Bias
       + EW.Tokens       * Tokens
       + EW.CodeFence    * Fences
       + EW.ListItem     * ListItems
       + EW.Heading      * Headings
       + EW.HardKeyword  * HardHits
       + EW.WriteRunTool * WriteRun
       - EW.EasyKeyword  * EasyHits;
  Result := Sigmoid(Raw);
end;

function ClassifyTask(const UserMessage: string;
                      const ToolNamesInUse: array of string;
                      EasyMaxTokens: Integer): TTaskDifficulty;
var
  Tokens: Integer;
  HasHardMarker, HasEasyMarker, HasWriteRunTool: Boolean;
begin
  if EasyMaxTokens <= 0 then EasyMaxTokens := DefaultEasyMaxTokens;

  { Hard-keyword wins outright. A message containing "implement X"
    is real work no matter how short. Order matters: we check
    hard first so "refactor and summarise" isn't routed cheap. }
  HasHardMarker := ContainsAny(UserMessage, HardKeywords);
  if HasHardMarker then Exit(tdHard);

  Tokens := EstimateTokens(UserMessage);
  if Tokens > EasyMaxTokens then Exit(tdHard);

  HasWriteRunTool := HasAnyToolMatching(ToolNamesInUse, WriteOrRunTools);
  HasEasyMarker   := ContainsAny(UserMessage, EasyKeywords);

  { Write/run tools present but no easy-marker AND no clear short
    intent -- the message could mean "now go write the code we
    discussed". Stay on the primary. }
  if HasWriteRunTool and (not HasEasyMarker) then Exit(tdAbstain);

  if HasEasyMarker then Exit(tdEasy);

  { Short message, no markers, no write/run tools -- still ambiguous
    ("yes", "thanks", "continue") so we abstain rather than route.
    The cost asymmetry says: false-hard is cheap, false-easy is
    expensive. Bias to safe. }
  Result := tdAbstain;
end;

function ConfiguredProviderExists(const Cfg: TConfig; const Name: string): Boolean;
var
  i: Integer;
begin
  if Name = '' then Exit(False);
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Name) then Exit(True);
  Result := False;
end;

function ResolveEasyModel(const Cfg: TConfig): string;
{ Three-step resolution. The router must NEVER hand the caller an
  empty Model that gets passed to e.g. Groq.Chat -- the primary's
  model (still sitting on LoopCfg.Model from BuildLoopConfig) would
  silently leak through and we'd ship `claude-opus-4-8` to Groq,
  which fails. So: explicit override wins; else the per-provider
  config's stored Model (what onboarding wrote when the operator
  picked a model from the picker); else the catalog default for
  that Kind. Empty result = "we can't resolve a safe model, refuse
  to route." (Codex P2 on PR #203.) }
var
  i: Integer;
  Spec: TProviderSpec;
begin
  if Cfg.AutoRouter.EasyModel <> '' then Exit(Cfg.AutoRouter.EasyModel);
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Cfg.AutoRouter.EasyProvider) then
    begin
      if Cfg.Providers[i].Model <> '' then Exit(Cfg.Providers[i].Model);
      { Per-provider stored model is blank -- fall through to the
        catalog default keyed on Kind (which onboarding sets equal
        to Name for the providers it creates). }
      if Cfg.Providers[i].Kind <> '' then
        if LookupProvider(Cfg.Providers[i].Kind, Spec) then
          Exit(Spec.DefaultModel);
      Break;
    end;
  Result := '';
end;

function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string;
                       out RoutedScore: Double): Boolean;
var
  W: TRouterWeights;
  MaxTokens, Tokens: Integer;
  HasEasy, HasWriteRun, ShouldRoute: Boolean;
begin
  RoutedProvider := '';
  RoutedModel    := '';
  RoutedScore    := -1;
  if not Cfg.AutoRouter.Enabled then Exit(False);
  if Cfg.AutoRouter.EasyProvider = '' then Exit(False);
  if not ConfiguredProviderExists(Cfg, Cfg.AutoRouter.EasyProvider) then
  begin
    { An EasyProvider that doesn't resolve is an operator config
      mistake -- decline silently and stay on the primary rather
      than crash mid-turn (`pasclaw status` surfaces the misconfig). }
    Exit(False);
  end;

  W := EffectiveWeights(Cfg.AutoRouter.Weights);
  RoutedScore := ClassifyScore(UserMessage, ToolNamesInUse, W);

  { Categorical safety rails, kept from the conservative v1 classifier --
    these matter more in an agent loop than in Wayfinder's one-shot use:
      - a hard-keyword task ("implement", "refactor", ...) never routes;
      - an over-length prompt never routes;
      - an ambiguous continuation with write/run tools available ("yes",
        "continue") stays on the primary -- it may mean "now run the risky
        thing we just discussed". }
  if ContainsAny(UserMessage, HardKeywords) then Exit(False);
  MaxTokens := Cfg.AutoRouter.EasyMaxTokens;
  if MaxTokens <= 0 then MaxTokens := DefaultEasyMaxTokens;
  Tokens := EstimateTokens(UserMessage);
  if Tokens > MaxTokens then Exit(False);
  HasWriteRun := HasAnyToolMatching(ToolNamesInUse, WriteOrRunTools);
  HasEasy     := ContainsAny(UserMessage, EasyKeywords);
  if HasWriteRun and (not HasEasy) then Exit(False);

  { Decision: route when the structural score is at/under threshold. An
    explicit easy marker is enough on its own; an unmarked message must also
    clear the continuation floor (a bare "ok" stays on the primary). The
    score still vetoes "summarize <huge fenced code block>" -- the fences and
    length push it back over the threshold. }
  ShouldRoute := (RoutedScore <= W.Threshold)
                 and (HasEasy or (Tokens >= MinScoreRouteTokens));
  if not ShouldRoute then Exit(False);

  RoutedProvider := Cfg.AutoRouter.EasyProvider;
  RoutedModel    := ResolveEasyModel(Cfg);
  if RoutedModel = '' then
  begin
    { Couldn't pin a safe model for the easy provider. Refuse to route rather
      than hand the loop a primary-tier model the cheap provider can't serve. }
    RoutedProvider := '';
    Exit(False);
  end;
  Result := True;
end;

function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string): Boolean;
var
  IgnoredScore: Double;
begin
  Result := RouteProvider(Cfg, UserMessage, ToolNamesInUse,
                          RoutedProvider, RoutedModel, IgnoredScore);
end;

end.
