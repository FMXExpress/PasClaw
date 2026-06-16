(*
  pasclaw profile - configuration profile management (PR #291).

  Three subcommands shipping in this PR:

    pasclaw profile list           List built-in + user profiles
    pasclaw profile show <name>    Print the profile's effective JSON
                                   (after _inherits resolution)
    pasclaw profile use <name>     Write "profile": "<name>" into
                                   config.json so it sticks across runs

  Future (Stage D, separate PR):

    pasclaw profile diff <a> <b>   Show field-level differences
    pasclaw profile bench ...      A/B test profiles against a task

  Profile selection precedence at LoadConfig time:

    1. --profile <name>   (CLI per-invocation)
    2. PASCLAW_PROFILE    (env var, process scope)
    3. "profile": "<name>" in config.json   (persisted; `profile use` writes this)
    4. None
*)
unit PasClaw.Cmd.Profile;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Profile_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Config.Profile,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Platform,        { RunOneShot for the bench spawner }
  PasClaw.Session.Store;   { TSession to read back per-run stats }

procedure Help;
begin
  PrintLn('Usage: pasclaw profile <list|show|use|diff|bench> [args]');
  PrintLn;
  PrintLn('  list                List built-in + $PASCLAW_HOME/profiles/ profiles.');
  PrintLn('  show <name>         Print the profile body (with _inherits resolved).');
  PrintLn('  use  <name>         Save "profile": <name> into config.json.');
  PrintLn('  diff <a> <b>        Show fields where two profiles disagree.');
  PrintLn('  bench --task "..." --profiles a,b,c [--runs N]');
  PrintLn('                      Run the same task against each profile and print a stats table.');
  PrintLn;
  PrintLn('Built-in profiles: baseline | low-token | security | max-build | all-on');
  PrintLn('Per-invocation override: ' + Ansi.Bold + 'pasclaw <cmd> --profile <name>' + Ansi.Reset);
  PrintLn('Process override:        ' + Ansi.Bold + 'PASCLAW_PROFILE=<name> pasclaw ...' + Ansi.Reset);
end;

function DoList: Integer;
var
  Profiles: TProfileSpecArray;
  i: Integer;
  Src, Active: string;
begin
  Profiles := ListAvailableProfiles(GetHome);
  if Length(Profiles) = 0 then
  begin
    PrintLn('(no profiles)');
    Exit(0);
  end;

  Active := GetEnvironmentVariable('PASCLAW_PROFILE');
  if Active = '' then
  try
    Active := ExtractProfileField(ReadFileText(GetConfigPath));
  except
    Active := '';
  end;

  PrintLn(Ansi.Bold + 'name           source         description' + Ansi.Reset);
  for i := 0 to High(Profiles) do
  begin
    Src := Profiles[i].Source;
    if Src <> 'builtin' then
    begin
      { Show ~/.../ relative path so the line stays readable. }
      if Pos(GetHome, Src) = 1 then
        Src := '~' + Copy(Src, Length(GetHome) + 1, MaxInt);
    end;
    if SameText(Profiles[i].Name, Active) then
      PrintLn(Format('* %-12s  %-12s  %s',
        [Profiles[i].Name, Src, Profiles[i].Description]))
    else
      PrintLn(Format('  %-12s  %-12s  %s',
        [Profiles[i].Name, Src, Profiles[i].Description]));
  end;
  if Active <> '' then
    PrintLn(Ansi.Dim + sLineBreak + '(* marks the active profile from ' +
            'PASCLAW_PROFILE or config.json)' + Ansi.Reset);
  Result := 0;
end;

function DoShow(const Argv: array of string): Integer;
var
  Bodies: TProfileBodyArray;
  Err: string;
  i: Integer;
  Sb: TStringBuilder;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  if not ResolveProfileBodies(GetHome, Argv[1], Bodies, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Exit(1);
  end;
  PrintLn(Ansi.Bold + 'profile ' + Argv[1] +
          Ansi.Reset + Ansi.Dim +
          Format('  (%d layer(s) including ancestors)', [Length(Bodies)]) +
          Ansi.Reset);
  PrintLn;
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Bodies) do
    begin
      if Length(Bodies) > 1 then
      begin
        PrintLn(Ansi.Dim + Format('--- layer %d/%d ---', [i + 1, Length(Bodies)]) +
                Ansi.Reset);
      end;
      PrintLn(Bodies[i]);
      if i < High(Bodies) then PrintLn;
    end;
  finally
    Sb.Free;
  end;
  Result := 0;
end;

function DoUse(const Argv: array of string): Integer;
var
  Err: string;
  Bodies: TProfileBodyArray;
  Cfg: TConfig;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  { Validate the profile resolves BEFORE writing -- prevents stamping
    a typo into config.json that LoadConfig will then warn about
    forever. }
  if not ResolveProfileBodies(GetHome, Argv[1], Bodies, Err) then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Err);
    Exit(1);
  end;

  { PR #291 Codex fix: write through TConfig + SaveConfig, not by
    hand-rolling JSON. Cfg.Profile is a proper field now, so any
    config-mutating command after this (auth login, model set, /v1/config
    PUT, ...) preserves it instead of dropping the key on the next save. }
  Cfg := LoadConfig('');
  try
    Cfg.Profile := Argv[1];
    SaveConfig(Cfg);
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
          'config.json now selects profile "' + Argv[1] + '"');
  PrintLn(Ansi.Dim +
          '  Override per-invocation: pasclaw <cmd> --profile <other>' +
          Ansi.Reset);
  Result := 0;
end;

(* ----------------------------------------------------------------------
   `pasclaw profile diff <a> <b>` (PR #292 / Stage C-tail of the
   profile system plan). Apply each profile in isolation against a
   fresh TConfig (no operator config.json on top), then diff a curated
   list of fields that profiles actually touch. Rows where the two
   sides disagree print as:

       field                              <a>          <b>
       condense_reversible                false        true
       tool_output_cap                    0            8192
       self_improving_skills.distiller    false        true

   Why a hand-listed field set and not a JSON-walk of ToJSON output:
   ToJSON is "tidy" -- it suppresses fields matching their default,
   which would hide cases like "baseline sets condense_reversible=
   false explicitly" vs "stock leaves it at the default false" (same
   value, no row needed -- correct -- but the walker would have no
   row data for either side at all). Comparing the LIVE TConfig
   fields after apply is the authoritative diff.
   ---------------------------------------------------------------------- *)
type
  TDiffRow = record
    Field, ValA, ValB: string;
  end;
  TDiffRowArray = array of TDiffRow;

procedure AddRow(var Rows: TDiffRowArray; const Field, ValA, ValB: string);
begin
  if ValA = ValB then Exit;
  SetLength(Rows, Length(Rows) + 1);
  Rows[High(Rows)].Field := Field;
  Rows[High(Rows)].ValA  := ValA;
  Rows[High(Rows)].ValB  := ValB;
end;

function BoolStr(B: Boolean): string;
begin
  if B then Result := 'true' else Result := 'false';
end;

procedure CompareConfigs(A, B: TConfig; var Rows: TDiffRowArray);
begin
  AddRow(Rows, 'vault_tools_enabled',      BoolStr(A.VaultToolsEnabled),    BoolStr(B.VaultToolsEnabled));
  AddRow(Rows, 'web_fetch_enabled',        BoolStr(A.WebFetchEnabled),      BoolStr(B.WebFetchEnabled));
  AddRow(Rows, 'vector_search_enabled',    BoolStr(A.VectorSearchEnabled),  BoolStr(B.VectorSearchEnabled));
  AddRow(Rows, 'render_markdown',          BoolStr(A.RenderMarkdown),       BoolStr(B.RenderMarkdown));
  AddRow(Rows, 'promptware_enabled',       BoolStr(A.PromptwareEnabled),    BoolStr(B.PromptwareEnabled));
  AddRow(Rows, 'condense_reversible',      BoolStr(A.CondenseReversible),   BoolStr(B.CondenseReversible));
  AddRow(Rows, 'tool_output_cap',          IntToStr(A.ToolOutputCap),       IntToStr(B.ToolOutputCap));
  AddRow(Rows, 'orient_task_aware',        BoolStr(A.OrientTaskAware),      BoolStr(B.OrientTaskAware));
  AddRow(Rows, 'stats_collection_enabled', BoolStr(A.StatsCollectionEnabled), BoolStr(B.StatsCollectionEnabled));
  AddRow(Rows, 'checkpoints_enabled',      BoolStr(A.CheckpointsEnabled),   BoolStr(B.CheckpointsEnabled));
  AddRow(Rows, 'checkpoints_keep_last',    IntToStr(A.CheckpointsKeepLast), IntToStr(B.CheckpointsKeepLast));
  AddRow(Rows, 'self_improving_skills.self_manage',
              BoolStr(A.SelfImprovingSkills.SelfManage),
              BoolStr(B.SelfImprovingSkills.SelfManage));
  AddRow(Rows, 'self_improving_skills.progressive_disclosure',
              BoolStr(A.SelfImprovingSkills.ProgressiveDisclosure),
              BoolStr(B.SelfImprovingSkills.ProgressiveDisclosure));
  AddRow(Rows, 'self_improving_skills.auto_approve',
              BoolStr(A.SelfImprovingSkills.AutoApprove),
              BoolStr(B.SelfImprovingSkills.AutoApprove));
  AddRow(Rows, 'self_improving_skills.distiller.enabled',
              BoolStr(A.SelfImprovingSkills.Distiller.Enabled),
              BoolStr(B.SelfImprovingSkills.Distiller.Enabled));
  AddRow(Rows, 'self_improving_skills.distiller.min_tool_calls',
              IntToStr(A.SelfImprovingSkills.Distiller.MinToolCalls),
              IntToStr(B.SelfImprovingSkills.Distiller.MinToolCalls));
  AddRow(Rows, 'auto_router.enabled',      BoolStr(A.AutoRouter.Enabled),   BoolStr(B.AutoRouter.Enabled));
  AddRow(Rows, 'prompt_cache.enabled',     BoolStr(A.PromptCache.Enabled),  BoolStr(B.PromptCache.Enabled));
  AddRow(Rows, 'prompt_cache.ttl',         A.PromptCache.TTL,               B.PromptCache.TTL);
  AddRow(Rows, 'sandbox.restrict_to_workspace',
              BoolStr(A.Sandbox.RestrictToWorkspace),
              BoolStr(B.Sandbox.RestrictToWorkspace));
  AddRow(Rows, 'sandbox.shell_deny_enabled',
              BoolStr(A.Sandbox.ShellDenyEnabled),
              BoolStr(B.Sandbox.ShellDenyEnabled));
  AddRow(Rows, 'sandbox.block_private_networks',
              BoolStr(A.Sandbox.BlockPrivateNetworks),
              BoolStr(B.Sandbox.BlockPrivateNetworks));
  AddRow(Rows, 'sandbox.allow_read_outside_workspace',
              BoolStr(A.Sandbox.AllowReadOutsideWorkspace),
              BoolStr(B.Sandbox.AllowReadOutsideWorkspace));
end;

(* Build a fresh TConfig + apply each layer of the resolved profile
   chain. No env-var expansion (profiles are bundled / static so the
   ${VAR} feature doesn't apply -- a profile body with a literal
   ${VAR} would compare verbatim and that's fine for diff purposes). *)
function ApplyProfileToFreshConfig(const Name: string;
                                   out ErrMsg: string): TConfig;
var
  Bodies: TProfileBodyArray;
  i: Integer;
begin
  Result := nil;
  if not ResolveProfileBodies(GetHome, Name, Bodies, ErrMsg) then Exit;
  Result := TConfig.Create;
  for i := 0 to High(Bodies) do
  try
    Result.FromJSON(Bodies[i]);
  except
    { Leave Result at partial state and bail -- caller treats as failure. }
    on E: Exception do
    begin
      ErrMsg := 'apply layer ' + IntToStr(i + 1) + ': ' + E.Message;
      FreeAndNil(Result);
      Exit;
    end;
  end;
end;

function DoDiff(const Argv: array of string): Integer;
var
  A, B: TConfig;
  ErrA, ErrB: string;
  Rows: TDiffRowArray;
  i, FieldW, ValW: Integer;
begin
  if Length(Argv) < 3 then
  begin
    PrintLn('Usage: pasclaw profile diff <a> <b>');
    Exit(1);
  end;

  A := ApplyProfileToFreshConfig(Argv[1], ErrA);
  if A = nil then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Argv[1] + ': ' + ErrA);
    Exit(1);
  end;
  B := ApplyProfileToFreshConfig(Argv[2], ErrB);
  if B = nil then
  begin
    A.Free;
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Argv[2] + ': ' + ErrB);
    Exit(1);
  end;
  try
    SetLength(Rows, 0);
    CompareConfigs(A, B, Rows);

    if Length(Rows) = 0 then
    begin
      PrintLn(Ansi.Dim + '(no differences across the comparable field set)' + Ansi.Reset);
      Exit(0);
    end;

    { Column widths -- pick maxes against the actual data so the
      "field" column doesn't waste space when every row is short, and
      the value columns line up. }
    FieldW := Length('field');
    ValW   := Length(Argv[1]);
    if Length(Argv[2]) > ValW then ValW := Length(Argv[2]);
    for i := 0 to High(Rows) do
    begin
      if Length(Rows[i].Field) > FieldW then FieldW := Length(Rows[i].Field);
      if Length(Rows[i].ValA)  > ValW   then ValW   := Length(Rows[i].ValA);
      if Length(Rows[i].ValB)  > ValW   then ValW   := Length(Rows[i].ValB);
    end;
    PrintLn(Format('%s' + Ansi.Bold + '%-' + IntToStr(FieldW) + 's' + Ansi.Reset +
                   '  %-' + IntToStr(ValW) + 's  %-' + IntToStr(ValW) + 's',
                   ['', 'field', Argv[1], Argv[2]]));
    for i := 0 to High(Rows) do
      PrintLn(Format('%-' + IntToStr(FieldW) + 's  %-' + IntToStr(ValW) + 's  %-' +
                     IntToStr(ValW) + 's',
                     [Rows[i].Field, Rows[i].ValA, Rows[i].ValB]));
    PrintLn;
    PrintLn(Ansi.Dim + '(' + IntToStr(Length(Rows)) + ' differing field(s))' + Ansi.Reset);
  finally
    A.Free;
    B.Free;
  end;
  Result := 0;
end;

(* ----------------------------------------------------------------------
   `pasclaw profile bench` (PR #292 / Stage D of the profile plan).

   Run the same task N times against each named profile and summarise
   per-profile stats so an operator can answer "which profile is most
   effective for this kind of work".

       pasclaw profile bench \
         --task "implement fizzbuzz in pascal" \
         --profiles baseline,low-token,max-build \
         --runs 3

   Mechanics:
     - For each (profile, run) pair, spawn this same binary as
         pasclaw agent --profile <P> --quiet \
                       --session bench-<P>-<N>-<ts> -m "<task>"
     - The CLI agent path already persists session JSON to
       workspace/sessions/<id>.json with TSessionStats populated
       when stats_collection_enabled is True. For profiles that have
       it off (most), token counts come back as 0 -- the wall-clock
       and exit-code numbers are still recorded so the comparison
       isn't useless.
     - After all runs complete, aggregate min/avg/max per metric per
       profile, print a table.

   Defaults:
     --runs    3            (override; > 0)
     --provider-config: the operator's live $PASCLAW_HOME/config.json
                       is reused, so API keys etc. don't need
                       restating. Each spawn just adds --profile.
     --judge   not implemented in v1 -- token + wall-time numbers
                       plus the printed responses are enough to
                       eyeball. The Ralph-loop judge pattern from
                       PR #223 plugs in here as a follow-up.

   Not a benchmark in the academic sense (no statistical-significance
   testing, no controlled variance) -- it's a "show me concrete
   numbers" comparison harness.
   ---------------------------------------------------------------------- *)

type
  TBenchRunStat = record
    Profile:       string;
    RunIdx:        Integer;
    SessionId:     string;
    ExitCode:      Integer;
    WallMs:        Int64;
    InputTokens:   Int64;
    OutputTokens:  Int64;
    CacheRead:     Int64;
    CacheCreated:  Int64;
    Turns:         Int64;
    ToolCalls:     Int64;
  end;
  TBenchRunStatArray = array of TBenchRunStat;

  TBenchAgg = record
    Profile:          string;
    Runs:             Integer;
    Failures:         Integer;
    SumWallMs:        Int64;
    SumInputTokens:   Int64;
    SumOutputTokens:  Int64;
    SumCacheRead:     Int64;
    SumTurns:         Int64;
    SumToolCalls:     Int64;
  end;
  TBenchAggArray = array of TBenchAgg;

(* Split "a,b,c" into ['a','b','c'], trimming each entry. *)
function SplitCSV(const S: string): TStringArray;
var
  Cur: string;
  i: Integer;

  procedure Push;
  begin
    Cur := Trim(Cur);
    if Cur <> '' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Cur;
    end;
    Cur := '';
  end;

begin
  SetLength(Result, 0);
  Cur := '';
  for i := 1 to Length(S) do
  begin
    if S[i] = ',' then Push
    else Cur := Cur + S[i];
  end;
  Push;
end;

function NowMs: Int64;
begin
  Result := DateTimeToUnix(Now) * Int64(1000) +
            (MilliSecondOfTheDay(Now) mod 1000);
end;

function FindBenchArg(const Argv: array of string;
                      const Name: string;
                      out Value: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  Value := '';
  for i := 1 to High(Argv) - 1 do
    if Argv[i] = Name then
    begin
      Value := Argv[i + 1];
      Exit(True);
    end;
end;

function HasFlag(const Argv: array of string; const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 1 to High(Argv) do
    if Argv[i] = Name then Exit(True);
end;

(* Escape a string so it survives as a single shell-arg literal in
   single quotes. For a task description we trust the operator's input
   reasonably -- we're spawning their own binary against their own
   provider -- but the prompt may legitimately contain a single quote,
   so swap each ' for the '\'' idiom. *)
function ShellQuoteSingle(const S: string): string;
var
  i: Integer;
begin
  Result := '''';
  for i := 1 to Length(S) do
    if S[i] = '''' then Result := Result + ''''#92''''''''
    else Result := Result + S[i];
  Result := Result + '''';
end;

function PasClawExePath: string;
begin
  Result := ParamStr(0);
end;

(* Run one bench round: spawn the agent against the given profile +
   task, with a fixed session id, and read the session JSON back to
   harvest stats. Populates RunOut on either success or failure --
   ExitCode tells the caller which. *)
function RunOneBench(const ProfileName, Task: string;
                    RunIdx: Integer;
                    out Run: TBenchRunStat): Boolean;
var
  StartedMs: Int64;
  Cmd, Output: string;
  Session: TSession;
begin
  Result := False;
  Run := Default(TBenchRunStat);
  Run.Profile := ProfileName;
  Run.RunIdx  := RunIdx;
  Run.SessionId := Format('bench-%s-%d-%d',
                          [ProfileName, RunIdx, DateTimeToUnix(Now)]);

  Cmd := PasClawExePath + ' agent --profile ' + ProfileName +
         ' --quiet --session ' + Run.SessionId + ' -m ' + ShellQuoteSingle(Task);

  StartedMs := NowMs;
  Run.ExitCode := RunOneShot(Cmd, Output);
  Run.WallMs   := NowMs - StartedMs;

  { Read the persisted session JSON to harvest stats. TSession.Create
    with a non-empty id loads if it exists. }
  Session := TSession.Create(Run.SessionId);
  try
    if Session.MetaExists then
    begin
      Run.InputTokens   := Session.Meta.Stats.InputTokens;
      Run.OutputTokens  := Session.Meta.Stats.OutputTokens;
      Run.CacheRead     := Session.Meta.Stats.CacheReadTokens;
      Run.CacheCreated  := Session.Meta.Stats.CacheCreatedTokens;
      Run.Turns         := Session.Meta.Stats.Turns;
      Run.ToolCalls     := Session.Meta.Stats.ToolCalls;
      Result := True;
    end;
  finally
    Session.Free;
  end;
end;

procedure AggregateRun(var Aggs: TBenchAggArray; const Run: TBenchRunStat);
var
  i, Found: Integer;
begin
  Found := -1;
  for i := 0 to High(Aggs) do
    if SameText(Aggs[i].Profile, Run.Profile) then begin Found := i; Break; end;
  if Found < 0 then
  begin
    SetLength(Aggs, Length(Aggs) + 1);
    Found := High(Aggs);
    Aggs[Found].Profile := Run.Profile;
  end;
  with Aggs[Found] do
  begin
    Inc(Runs);
    if Run.ExitCode <> 0 then Inc(Failures);
    Inc(SumWallMs,        Run.WallMs);
    Inc(SumInputTokens,   Run.InputTokens);
    Inc(SumOutputTokens,  Run.OutputTokens);
    Inc(SumCacheRead,     Run.CacheRead);
    Inc(SumTurns,         Run.Turns);
    Inc(SumToolCalls,     Run.ToolCalls);
  end;
end;

function Mean(Sum: Int64; N: Integer): Int64;
begin
  if N <= 0 then Result := 0
  else Result := Sum div N;
end;

procedure PrintSummary(const Aggs: TBenchAggArray);
var
  i: Integer;
begin
  PrintLn;
  PrintLn(Ansi.Bold + 'bench summary' + Ansi.Reset);
  PrintLn(Format('  %-12s %4s %3s %6s %8s %8s %5s %6s',
    ['profile', 'runs', 'err', 'wall(s)', 'in_tok', 'out_tok', 'turns', 't_call']));
  for i := 0 to High(Aggs) do
    with Aggs[i] do
      PrintLn(Format('  %-12s %4d %3d %6.1f %8d %8d %5d %6d',
        [Profile, Runs, Failures,
         Mean(SumWallMs, Runs) / 1000.0,
         Mean(SumInputTokens, Runs),
         Mean(SumOutputTokens, Runs),
         Mean(SumTurns, Runs),
         Mean(SumToolCalls, Runs)]));
  PrintLn;
  PrintLn(Ansi.Dim +
    '(values are per-run means; "err" counts non-zero exit codes. ' +
    'in_tok/out_tok/turns/t_call read back from the session JSON -- ' +
    'requires stats_collection_enabled to be on in the active profile ' +
    'for non-zero values.)' + Ansi.Reset);
end;

function DoBench(const Argv: array of string): Integer;
var
  TaskArg, ProfilesArg, RunsArg: string;
  Profiles: TStringArray;
  Runs, RunIdx, ProfileIdx: Integer;
  Run: TBenchRunStat;
  Aggs: TBenchAggArray;
  AllRuns: TBenchRunStatArray;
  ErrMsg: string;
  Bodies: TProfileBodyArray;
begin
  if HasFlag(Argv, '--help') or (Length(Argv) < 2) then
  begin
    PrintLn('Usage: pasclaw profile bench --task "<prompt>" --profiles <a,b,c> [--runs N]');
    PrintLn;
    PrintLn('  --task <s>          The prompt to send to each profile + run.');
    PrintLn('  --profiles <list>   Comma-separated profile names.');
    PrintLn('  --runs N            How many times to run each profile (default 3).');
    PrintLn;
    PrintLn('Spawns `pasclaw agent --profile <p> --quiet --session <id> -m <task>`');
    PrintLn('for each pair; reads the session JSON for stats; prints a comparison table.');
    Exit(1);
  end;

  if not FindBenchArg(Argv, '--task', TaskArg) or (TaskArg = '') then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'missing required --task "<prompt>"');
    Exit(1);
  end;
  if not FindBenchArg(Argv, '--profiles', ProfilesArg) or (ProfilesArg = '') then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'missing required --profiles <a,b,c>');
    Exit(1);
  end;
  Profiles := SplitCSV(ProfilesArg);
  if Length(Profiles) = 0 then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + '--profiles parsed to empty list');
    Exit(1);
  end;

  Runs := 3;
  if FindBenchArg(Argv, '--runs', RunsArg) then
    Runs := StrToIntDef(RunsArg, 3);
  if Runs < 1 then Runs := 1;

  { Validate every profile up front so we don't burn provider calls
    before discovering a typo. }
  for ProfileIdx := 0 to High(Profiles) do
    if not ResolveProfileBodies(GetHome, Profiles[ProfileIdx], Bodies, ErrMsg) then
    begin
      PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + Profiles[ProfileIdx] + ': ' + ErrMsg);
      Exit(1);
    end;

  PrintLn(Ansi.Bold + 'profile bench' + Ansi.Reset);
  PrintLn('  task:     ' + TaskArg);
  PrintLn('  profiles: ' + ProfilesArg);
  PrintLn('  runs:     ' + IntToStr(Runs));
  PrintLn;

  SetLength(AllRuns, 0);
  SetLength(Aggs,    0);

  for ProfileIdx := 0 to High(Profiles) do
    for RunIdx := 1 to Runs do
    begin
      Print(Format('  [%s run %d/%d] ', [Profiles[ProfileIdx], RunIdx, Runs]));
      RunOneBench(Profiles[ProfileIdx], TaskArg, RunIdx, Run);
      SetLength(AllRuns, Length(AllRuns) + 1);
      AllRuns[High(AllRuns)] := Run;
      AggregateRun(Aggs, Run);
      if Run.ExitCode = 0 then
        PrintLn(Format('exit=0  wall=%.1fs  in=%d  out=%d  turns=%d',
          [Run.WallMs / 1000.0, Run.InputTokens, Run.OutputTokens, Run.Turns]))
      else
        PrintLn(Ansi.Red + Format('exit=%d (failed)  wall=%.1fs',
          [Run.ExitCode, Run.WallMs / 1000.0]) + Ansi.Reset);
    end;

  PrintSummary(Aggs);
  Result := 0;
end;

function Cmd_Profile_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'list'  then Result := DoList
  else if Sub = 'show'  then Result := DoShow(Argv)
  else if Sub = 'use'   then Result := DoUse(Argv)
  else if Sub = 'diff'  then Result := DoDiff(Argv)
  else if Sub = 'bench' then Result := DoBench(Argv)
  else begin Help; Result := 1; end;
end;

end.
