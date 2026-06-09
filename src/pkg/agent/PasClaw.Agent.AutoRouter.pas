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

(* Decide whether to route this turn to the cheap provider. Returns
   True (and writes the routed provider's name to RoutedProvider /
   RoutedModel) when the classifier says tdEasy AND the router is
   enabled AND the EasyProvider is resolvable in Cfg.Providers.
   Returns False otherwise -- the caller keeps using the primary.
   ToolNamesInUse threaded through to the classifier. *)
function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string): Boolean;

implementation

uses
  SysUtils,
  PasClaw.Tokenizer;

const
  DefaultEasyMaxTokens = 500;

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
  WriteOrRunTools: array[0..3] of string = (
    'shell_exec', 'execute_code', 'fs_write', 'fs_edit_hashline'
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

function RouteProvider(const Cfg: TConfig;
                       const UserMessage: string;
                       const ToolNamesInUse: array of string;
                       out RoutedProvider, RoutedModel: string): Boolean;
var
  Difficulty: TTaskDifficulty;
begin
  RoutedProvider := '';
  RoutedModel    := '';
  if not Cfg.AutoRouter.Enabled then Exit(False);
  if Cfg.AutoRouter.EasyProvider = '' then Exit(False);
  if not ConfiguredProviderExists(Cfg, Cfg.AutoRouter.EasyProvider) then
  begin
    { An EasyProvider that doesn't resolve is an operator config
      mistake -- log it once and stay on the primary. We can't
      surface it to stderr from here without dragging the logger
      into the unit, but `pasclaw status` or the gateway's
      /v1/status would let an operator notice. For now: silently
      decline rather than crash mid-turn. }
    Exit(False);
  end;

  Difficulty := ClassifyTask(UserMessage, ToolNamesInUse,
                             Cfg.AutoRouter.EasyMaxTokens);
  if Difficulty <> tdEasy then Exit(False);

  RoutedProvider := Cfg.AutoRouter.EasyProvider;
  RoutedModel    := Cfg.AutoRouter.EasyModel;  { '' = use that provider's
                                                 catalog default; resolved
                                                 by NewProviderFromConfig }
  Result := True;
end;

end.
