(*
  PasClaw.Maintain - the nightly maintenance pass.

  The setups that stay good for months all run one: something that looks
  at the day's work after the fact, prunes what has gone stale, and says
  what went wrong, so the agent gets better with use instead of worse.
  Without it facts pile up past their expiry, skills accumulate that
  nothing calls, MEMORY.md swells past the always-loaded budget, and the
  operator only notices when the prompt is mostly noise.

  One pass, in order:

    1. Facts     -- IFactStore.Sweep: expired rows go, superseded rows go
                    once older than keep_superseded_days.
    2. Core tier -- size SOUL.md / USER.md / MEMORY.md / the two daily
                    notes against memory_core_budget_bytes and say which
                    are over.
    3. Sessions  -- walk the sessions of the last N days: turns, tool
                    calls, tool failures (with samples) and misuses,
                    tokens. A failure is what PasClaw.Learn calls one, so
                    this count and the Recurring list agree.
       Recurring -- PasClaw.Learn over a longer window (30 days): the
                    failures, and the misuses a tool pointed out, that
                    came back in two or more sessions. One that SCARS.md
                    lacks gets an anchor there (what `pasclaw learn
                    --write-scars` does by hand), so the record of what
                    keeps going wrong stays current without anyone
                    remembering to run it.
    4. Skills    -- callable skills no session has invoked within
                    unused_skill_days; pairs whose name+description
                    overlap enough to be the same skill twice. Reported,
                    never deleted.
    5. Review    -- optional: one call to the background model with the
                    numbers, the failure samples and the recurring
                    patterns, asking for a short
                    critique and what to change tomorrow. The "dream log".
    6. Backup    -- optional: PasClaw.Backup with rotation.
    7. Report    -- everything above as Markdown, written to
                    <workspace>/memory/maintenance/<date>.md so it is in
                    the searchable tier and never in the always-loaded one.

  Entry points: RunMaintenance for the CLI (`pasclaw maintain`) and
  RunMaintenanceForCron for the gateway scheduler, which fires it when a
  cron entry names the reserved skill "@maintain". The pure pieces --
  the report renderer, the overlap finder -- are exported so they can be
  tested without a model or a clock; the failure heuristic is
  PasClaw.Learn's.
*)
unit PasClaw.Maintain;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Intf,
  PasClaw.Skills.Loader;

const
  { The cron "skill" name that runs this pass in-process. }
  MaintenanceCronSkill = '@maintain';
  { Name+description Jaccard above which two skills are reported as one
    skill twice. Same threshold the skill distiller refuses to create at. }
  SkillOverlapThreshold = 0.8;
  MaxFailureSamples = 12;
  MaxRecurringShown = 12;

type
  TCoreFileStat = record
    Name:   string;
    Bytes:  Integer;
    Budget: Integer;
    Exists: Boolean;
  end;

  TMaintainOptions = record
    Home:       string;
    Workspace:  string;        { directory name under Home }
    Today:      string;        { YYYY-MM-DD }
    NowUnix:    Int64;
    SinceDays:  Integer;       { session window for stats + review; 1 = today }
    KeepSupersededDays: Integer;
    UnusedSkillDays:    Integer;
    CoreBudget: Integer;
    Review:     Boolean;
    Provider:   ILLMProvider;  { required when Review }
    Model:      string;
    DoBackup:   Boolean;
    BackupWithSecrets: Boolean;   { Cfg.Backup.IncludeSecrets }
    BackupDir:  string;
    Version:    string;
    KeepDaily, KeepWeekly, KeepMonthly: Integer;
    { Recurring patterns: sessions of the last LearnDays, seen in at least
      LearnMinSessions of them; Scars adds the new ones to SCARS.md. }
    LearnDays, LearnMinSessions: Integer;
    Scars:      Boolean;
    DryRun:     Boolean;       { report only: no sweep, no backup, no model call,
                                 no SCARS.md write, no report file }
  end;

  TMaintainReport = record
    FactsAvailable: Boolean;
    FactsTotalBefore, FactsRemoved, FactsActive: Integer;
    Core: array of TCoreFileStat;
    SessionsScanned, Turns, ToolCalls, ToolFailures, ToolMisuses: Integer;
    InputTokens, OutputTokens: Int64;
    FailureSamples: TArray<string>;
    { One line per recurring pattern, most frequent first, at most
      MaxRecurringShown; RecurringCount is how many there were. }
    Recurring:      TArray<string>;
    RecurringCount: Integer;
    ScarsNew, ScarsKnown: Integer;   { anchors added to / already in SCARS.md }
    ScarsWouldAdd:  Integer;         { a dry run: what a real one would add }
    ScarsPath:      string;          { set when SCARS.md was refreshed }
    SkillsTotal, SkillsCallable: Integer;
    UnusedSkills:  TArray<string>;
    OverlapPairs:  TArray<string>;
    ReviewText:    string;
    BackupPath:    string;
    BackupPruned:  Integer;
    Warnings:      TArray<string>;
    ReportPath:    string;
  end;

{ Options from a config: paths from the active workspace, budgets and the
  backup shape from Cfg, Today/NowUnix from the clock, Provider nil (set it
  and Review := True to get the critique). }
function DefaultMaintainOptions(Cfg: TConfig): TMaintainOptions;

{ The pass. False with Err only when nothing could be done at all (no
  workspace); partial failures are Warnings in the report. }
function RunMaintenance(const O: TMaintainOptions; out R: TMaintainReport;
                        out Err: string): Boolean;

{ The report as Markdown. Pure. }
function RenderMaintenanceReport(const O: TMaintainOptions;
                                 const R: TMaintainReport): string;

{ Pairs "a <-> b (0.87)" whose name+description Jaccard exceeds Threshold.
  Pure. }
function SkillOverlapPairs(const Skills: TSkillSpecArray;
                           Threshold: Double): TArray<string>;

{ What the gateway's cron scheduler calls for an "@maintain" entry: build
  options from Cfg (with a provider when maintenance.review is on), run,
  and return a one-paragraph summary for the cron sinks. Err set when the
  pass could not run. }
function RunMaintenanceForCron(Cfg: TConfig; out Err: string): string;

implementation

uses
  DateUtils,
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Workspaces,
  PasClaw.Providers.Types,
  PasClaw.Providers.Factory,
  PasClaw.Memory.Facts,
  PasClaw.Session.Store,
  PasClaw.Learn,
  PasClaw.Backup;

{ ------------------------------------------------------------- pure }

function TokenSetOf(const S: string): TStringList;
var
  i: Integer;
  c: Char;
  Cur: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Cur := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
       ((c >= '0') and (c <= '9')) then
      Cur := Cur + LowerCase(c)
    else
    begin
      if Length(Cur) >= 3 then Result.Add(Cur);
      Cur := '';
    end;
  end;
  if Length(Cur) >= 3 then Result.Add(Cur);
end;

function JaccardOf(A, B: TStringList): Double;
var
  i, Inter, UnionN: Integer;
begin
  if (A.Count = 0) or (B.Count = 0) then Exit(0);
  Inter := 0;
  for i := 0 to A.Count - 1 do
    if B.IndexOf(A[i]) >= 0 then Inc(Inter);
  UnionN := A.Count + B.Count - Inter;
  if UnionN = 0 then Exit(0);
  Result := Inter / UnionN;
end;

function SkillOverlapPairs(const Skills: TSkillSpecArray;
                           Threshold: Double): TArray<string>;
var
  Sets: array of TStringList;
  i, j: Integer;
  Sim: Double;
begin
  SetLength(Result, 0);
  SetLength(Sets, Length(Skills));
  for i := 0 to High(Skills) do
    Sets[i] := TokenSetOf(Skills[i].Name + ' ' + Skills[i].Description);
  try
    for i := 0 to High(Skills) do
      for j := i + 1 to High(Skills) do
      begin
        Sim := JaccardOf(Sets[i], Sets[j]);
        if Sim > Threshold then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Format('%s <-> %s (%.2f)', [Skills[i].Name, Skills[j].Name, Sim]);
        end;
      end;
  finally
    for i := 0 to High(Sets) do Sets[i].Free;
  end;
end;

procedure AddStr(var Arr: TArray<string>; const S: string);
begin
  SetLength(Arr, Length(Arr) + 1);
  Arr[High(Arr)] := S;
end;

function Plural(N: Integer; const One, Many: string): string;
begin
  if N = 1 then Result := IntToStr(N) + ' ' + One else Result := IntToStr(N) + ' ' + Many;
end;

function RenderMaintenanceReport(const O: TMaintainOptions;
                                 const R: TMaintainReport): string;
var
  L: TStringList;
  i: Integer;
  Over: Integer;
  Line: string;
begin
  L := TStringList.Create;
  try
    L.Add('# Maintenance ' + O.Today);
    L.Add('');
    if O.DryRun then
    begin
      L.Add('_Dry run: nothing was deleted, backed up, or sent to a model._');
      L.Add('');
    end;

    L.Add('## Facts');
    L.Add('');
    if not R.FactsAvailable then
      L.Add('- fact store not available (see warnings)')
    else
    begin
      L.Add(Format('- %d before the sweep, %d removed (expired, or superseded for more than %d days), %d active now',
                   [R.FactsTotalBefore, R.FactsRemoved, O.KeepSupersededDays, R.FactsActive]));
    end;
    L.Add('');

    L.Add('## Always-loaded memory');
    L.Add('');
    Over := 0;
    for i := 0 to High(R.Core) do
      with R.Core[i] do
      begin
        if not Exists then Continue;
        if (Budget > 0) and (Bytes > Budget) then
        begin
          Inc(Over);
          L.Add(Format('- **%s: %d bytes, %d over the %d-byte budget** -- move dated or one-off material out',
                       [Name, Bytes, Bytes - Budget, Budget]));
        end
        else
          L.Add(Format('- %s: %d bytes', [Name, Bytes]));
      end;
    if Length(R.Core) = 0 then L.Add('- (no memory files)');
    if Over > 0 then
    begin
      L.Add('');
      L.Add('The six-months test: if it would not matter in six months with no refresher, ' +
            'it belongs in a dated note or a fact with an expiry, not in these files.');
    end;
    L.Add('');

    L.Add(Format('## Sessions (last %s)', [Plural(O.SinceDays, 'day', 'days')]));
    L.Add('');
    Line := Format('- %s, %s, %s, %s',
                   [Plural(R.SessionsScanned, 'session', 'sessions'),
                    Plural(R.Turns, 'turn', 'turns'),
                    Plural(R.ToolCalls, 'tool call', 'tool calls'),
                    Plural(R.ToolFailures, 'tool failure', 'tool failures')]);
    if R.ToolMisuses > 0 then
      Line := Line + ', ' + Plural(R.ToolMisuses, 'misuse', 'misuses');
    L.Add(Line);
    L.Add(Format('- tokens: %d in, %d out', [R.InputTokens, R.OutputTokens]));
    if Length(R.FailureSamples) > 0 then
    begin
      L.Add('- failure samples:');
      for i := 0 to High(R.FailureSamples) do
        L.Add('  - `' + R.FailureSamples[i] + '`');
    end;
    L.Add('');

    if O.LearnDays > 0 then
    begin
      L.Add(Format('## Recurring (last %s, %d+ sessions)',
                   [Plural(O.LearnDays, 'day', 'days'), O.LearnMinSessions]));
      L.Add('');
      if R.RecurringCount = 0 then
        L.Add(Format('- nothing went wrong the same way in %d or more sessions', [O.LearnMinSessions]))
      else
      begin
        for i := 0 to High(R.Recurring) do L.Add('- ' + R.Recurring[i]);
        if R.RecurringCount > Length(R.Recurring) then
          L.Add(Format('- and %d more (`pasclaw learn --since %d`)',
                       [R.RecurringCount - Length(R.Recurring), O.LearnDays]));
        if R.ScarsPath <> '' then
          L.Add(Format('- SCARS.md: %s added, %d already there',
                       [Plural(R.ScarsNew, 'new anchor', 'new anchors'), R.ScarsKnown]))
        else if O.DryRun and O.Scars then
          L.Add(Format('- SCARS.md not refreshed (dry run): %s would be added',
                       [Plural(R.ScarsWouldAdd, 'new anchor', 'new anchors')]));
      end;
      L.Add('');
    end;

    L.Add('## Skills');
    L.Add('');
    L.Add(Format('- %d installed, %d callable', [R.SkillsTotal, R.SkillsCallable]));
    if Length(R.UnusedSkills) > 0 then
    begin
      L.Add(Format('- not invoked in %d days (consider `pasclaw skills remove`):', [O.UnusedSkillDays]));
      for i := 0 to High(R.UnusedSkills) do L.Add('  - ' + R.UnusedSkills[i]);
    end
    else
      L.Add(Format('- every callable skill was used within %d days', [O.UnusedSkillDays]));
    if Length(R.OverlapPairs) > 0 then
    begin
      L.Add('- overlapping (likely the same skill twice):');
      for i := 0 to High(R.OverlapPairs) do L.Add('  - ' + R.OverlapPairs[i]);
    end;
    L.Add('');

    if R.ReviewText <> '' then
    begin
      L.Add('## Review');
      L.Add('');
      L.Add(Trim(R.ReviewText));
      L.Add('');
    end;

    if R.BackupPath <> '' then
    begin
      L.Add('## Backup');
      L.Add('');
      L.Add('- ' + R.BackupPath);
      if R.BackupPruned > 0 then
        L.Add(Format('- rotation removed %d older archive(s)', [R.BackupPruned]));
      L.Add('');
    end;

    if Length(R.Warnings) > 0 then
    begin
      L.Add('## Warnings');
      L.Add('');
      for i := 0 to High(R.Warnings) do L.Add('- ' + R.Warnings[i]);
      L.Add('');
    end;
  finally
    Result := L.Text;
    L.Free;
  end;
end;

{ ------------------------------------------------------------ options }

function DefaultMaintainOptions(Cfg: TConfig): TMaintainOptions;
begin
  Result := Default(TMaintainOptions);
  Result.Home      := GetHome;
  Result.Workspace := ActiveWorkspaceName;
  Result.Today     := FormatDateTime('yyyy-mm-dd', Now);
  Result.NowUnix   := DateTimeToUnix(Now, False);
  Result.SinceDays := 1;
  Result.Version   := FormatBuildInfo;
  if Cfg <> nil then
  begin
    Result.KeepSupersededDays := Cfg.Maintenance.KeepSupersededDays;
    Result.UnusedSkillDays    := Cfg.Maintenance.UnusedSkillDays;
    Result.CoreBudget         := Cfg.MemoryCoreBudgetBytes;
    Result.Review             := Cfg.Maintenance.Review;
    Result.DoBackup           := Cfg.Maintenance.Backup;
    Result.BackupDir          := Trim(Cfg.Backup.Dir);
    Result.KeepDaily          := Cfg.Backup.KeepDaily;
    Result.KeepWeekly         := Cfg.Backup.KeepWeekly;
    Result.KeepMonthly        := Cfg.Backup.KeepMonthly;
    Result.BackupWithSecrets  := Cfg.Backup.IncludeSecrets;
    Result.Model              := BackgroundModelFor(Cfg);
    if Result.Model = '' then Result.Model := Cfg.DefaultModel;
  end
  else
  begin
    Result.KeepSupersededDays := 30;
    Result.UnusedSkillDays    := 30;
    Result.CoreBudget         := 16384;
    Result.KeepDaily := 7; Result.KeepWeekly := 4; Result.KeepMonthly := 6;
    Result.BackupWithSecrets := True;
  end;
  Result.LearnDays        := 30;
  Result.LearnMinSessions := 2;
  Result.Scars            := True;
  if Result.BackupDir = '' then Result.BackupDir := JoinPath(Result.Home, 'backups');
end;

{ --------------------------------------------------------------- pass }

function SafeReadSize(const Path: string): Integer;
var
  F: TSearchRec;
begin
  Result := 0;
  if FindFirst(Path, faAnyFile, F) = 0 then
  begin
    Result := F.Size;
    FindClose(F);
  end;
end;

function Clip(const S: string): string;
{ At most 160 columns, cut between characters: a byte Copy could split a
  multi-byte one and leave invalid UTF-8 in the report and in the review
  prompt sent to the provider. }
var
  Rest: string;
begin
  Result := TruncateVisible(S, 160, Rest);
end;

function RecurringLine(const P: TErrorPattern; const Anchor: string): string;
{ Anchor is the one the pattern has in SCARS.md (WriteScars' AnchorOf):
  the operator's if they renamed it, none yet if a dry run left it new. }
begin
  Result := Format('%dx across %d sessions', [P.Count, P.Sessions.Count]);
  if P.Context <> '' then
  begin
    Result := Result + ', `' + P.Context + '`';
    if P.Kind = pkMisuse then Result := Result + ' (misused)';
  end
  else if P.Kind = pkMisuse then
    Result := Result + ' (a misuse)';
  Result := Result + ': `' + Clip(P.Sample) + '`';
  if Anchor <> '' then Result := Result + ' ' + SectionSign + Anchor;
end;

function ReviewPrompt(const O: TMaintainOptions; const R: TMaintainReport): string;
begin
  { The report minus the review section it is about to produce. }
  Result :=
    'Below is today''s maintenance report for a personal AI agent (PasClaw). ' +
    'Write a short, concrete critique for the operator, at most 200 words, in Markdown bullets:' + sLineBreak +
    '1. what went wrong today, from the tool failures and counts;' + sLineBreak +
    '2. one or two changes for tomorrow (a rule for AGENTS.md, a skill to fix or remove, a fact to correct);' + sLineBreak +
    '3. anything in the always-loaded memory that should move out, judged by: ' +
    'would it still matter in six months?' + sLineBreak +
    'Do not restate the numbers. Say "nothing notable" for a section with nothing to say.' +
    sLineBreak + sLineBreak + RenderMaintenanceReport(O, R);
end;

function RunMaintenance(const O: TMaintainOptions; out R: TMaintainReport;
                        out Err: string): Boolean;
var
  WsDir, MemDir, Yesterday, Name, ReportDir: string;
  Store: IFactStore;
  Sessions: TSessionMetaArray;
  Sess: TSession;
  i, j, k, n: Integer;
  SinceStats, SinceSkills: Int64;
  Used: TStringList;
  Skills: TSkillSpecArray;
  Resp: TLLMResponse;
  Opts: TChatOptions;
  Msgs: array of TMessage;
  BR: TBackupResult;
  Kind: string;
  CoreNames: array[0..4] of string;
  SinceLearn, SinceLoad, Updated: Int64;
  Patterns: TErrorPatternArray;
  Miner: TPatternMiner;
  Names, AnchorOf: TArray<string>;
  Probs: TProblemLineArray;
  InLearn, Failed, Misused, WriteIt: Boolean;
  ScarsFile: string;
begin
  Result := False;
  Err := '';
  R := Default(TMaintainReport);
  WsDir := JoinPath(O.Home, O.Workspace);
  if not DirectoryExists(WsDir) then
  begin
    Err := 'workspace not found: ' + WsDir;
    Exit;
  end;
  MemDir := JoinPath(WsDir, 'memory');

  { 1. Facts. }
  Store := NewFactStore;
  if Store.Open(JoinPath(MemDir, 'facts.db')) then
  begin
    R.FactsAvailable := True;
    R.FactsTotalBefore := Store.CountAll;
    if not O.DryRun then
      R.FactsRemoved := Store.Sweep(O.Today, O.NowUnix, O.KeepSupersededDays);
    R.FactsActive := Store.CountActive(O.Today);
    Store.Close;
  end
  else
    AddStr(R.Warnings, 'fact store could not be opened: ' + Store.LastError);
  Store := nil;

  { 2. The always-loaded tier. }
  Yesterday := FormatDateTime('yyyy-mm-dd', IncDay(UnixToDateTime(O.NowUnix, False), -1));
  CoreNames[0] := 'SOUL.md';
  CoreNames[1] := 'USER.md';
  CoreNames[2] := 'MEMORY.md';
  CoreNames[3] := O.Today + '.md';
  CoreNames[4] := Yesterday + '.md';
  SetLength(R.Core, Length(CoreNames));
  for i := 0 to High(CoreNames) do
  begin
    R.Core[i].Name   := CoreNames[i];
    R.Core[i].Budget := O.CoreBudget;
    R.Core[i].Exists := FileExists(JoinPath(MemDir, CoreNames[i]));
    if R.Core[i].Exists then
      R.Core[i].Bytes := SafeReadSize(JoinPath(MemDir, CoreNames[i]));
  end;

  { 3 + 3b + 4a. Sessions: stats over SinceDays, recurring patterns over
    LearnDays, skill usage over UnusedSkillDays -- one read of each
    session for all three, each window checked on its own. }
  SinceStats  := O.NowUnix - Int64(O.SinceDays) * 86400;
  SinceSkills := O.NowUnix - Int64(O.UnusedSkillDays) * 86400;
  SinceLearn  := O.NowUnix - Int64(O.LearnDays) * 86400;
  SinceLoad := SinceStats;
  if SinceSkills < SinceLoad then SinceLoad := SinceSkills;
  Patterns := nil;
  Miner := nil;
  if O.LearnDays > 0 then Miner := TPatternMiner.Create;
  Used := TStringList.Create;
  try
    Used.Sorted := True;
    Used.Duplicates := dupIgnore;
    Used.CaseSensitive := False;
    try
      Sessions := ListSessions;
    except
      on E: Exception do
      begin
        SetLength(Sessions, 0);
        AddStr(R.Warnings, 'sessions could not be listed: ' + E.Message);
      end;
    end;
    for i := 0 to High(Sessions) do
    begin
      Updated := Sessions[i].UpdatedAt;
      { The learn window's rule is PasClaw.Learn's, so `pasclaw learn
        --since N` and this pass mine the same sessions -- one with no
        timestamp included. }
      InLearn := (Miner <> nil) and InWindow(Updated, SinceLearn);
      if (Updated < SinceLoad) and not InLearn then Continue;
      Sess := TSession.Create(Sessions[i].Id);
      try
        Names := ResultToolNames(Sess);
        { Recurring patterns: the learn window. }
        if InLearn then Miner.Scan(Sess, Names);
        { Skill usage: every skill_<name> call in the skill window. }
        if Updated >= SinceSkills then
          for j := 0 to High(Sess.Messages) do
            if Sess.Messages[j].Role = mrAssistant then
              for k := 0 to High(Sess.Messages[j].ToolCalls) do
              begin
                Name := Sess.Messages[j].ToolCalls[k].Func.Name;
                if Pos('skill_', Name) = 1 then Used.Add(Copy(Name, 7, MaxInt));
              end;
        { Stats: the --since window. }
        if Updated >= SinceStats then
        begin
          Inc(R.SessionsScanned);
          Inc(R.InputTokens,  Sess.Meta.Stats.InputTokens);
          Inc(R.OutputTokens, Sess.Meta.Stats.OutputTokens);
          for j := 0 to High(Sess.Messages) do
            case Sess.Messages[j].Role of
              mrUser: Inc(R.Turns);
              mrAssistant: Inc(R.ToolCalls, Length(Sess.Messages[j].ToolCalls));
              mrTool:
                begin
                  { At most one failure and one misuse per tool result;
                    keep the failing line. }
                  if j <= High(Names) then Name := Names[j] else Name := '';
                  Probs := ProblemLines(Name, Sess.Messages[j].Content);
                  Failed := False;
                  Misused := False;
                  for n := 0 to High(Probs) do
                    if (Probs[n].Kind = pkFailure) and not Failed then
                    begin
                      Failed := True;
                      Inc(R.ToolFailures);
                      if Length(R.FailureSamples) < MaxFailureSamples then
                        AddStr(R.FailureSamples, Clip(Probs[n].Line));
                    end
                    else if (Probs[n].Kind = pkMisuse) and not Misused then
                    begin
                      Misused := True;
                      Inc(R.ToolMisuses);
                    end;
                end;
            end;
        end;
      finally
        Sess.Free;
      end;
    end;

    { 3b. Recurring: give SCARS.md the new ones, then report them with the
      anchors they have there. }
    if Miner <> nil then Patterns := Miner.Take;
    for i := 0 to High(Patterns) do
      if PassesThreshold(Patterns[i], O.LearnMinSessions) then Inc(R.RecurringCount);
    if R.RecurringCount > 0 then
    begin
      ScarsFile := JoinPath(MemDir, 'SCARS.md');
      WriteIt := O.Scars and not O.DryRun;
      { Not writing still reads the file, to cite the anchors it has. }
      if WriteScars(ScarsFile, Patterns, O.LearnMinSessions, not WriteIt,
                    R.ScarsNew, R.ScarsKnown, AnchorOf) then
      begin
        if WriteIt then
          R.ScarsPath := ScarsFile
        else
        begin
          R.ScarsWouldAdd := R.ScarsNew;
          R.ScarsNew := 0;
        end;
      end
      else if WriteIt then
        AddStr(R.Warnings, 'SCARS.md could not be written: ' + ScarsFile)
      else
        AddStr(R.Warnings, 'SCARS.md could not be read: ' + ScarsFile);
      for i := 0 to High(Patterns) do
        if PassesThreshold(Patterns[i], O.LearnMinSessions) and
           (Length(R.Recurring) < MaxRecurringShown) then
          AddStr(R.Recurring, RecurringLine(Patterns[i], AnchorOf[i]));
    end;

    { 4b. Skills. }
    Skills := LoadSkillManifests(O.Home);
    R.SkillsTotal := Length(Skills);
    for i := 0 to High(Skills) do
    begin
      Kind := LowerCase(Trim(Skills[i].Kind));
      if (Kind <> 'shell') and (Kind <> 'prompt') then Continue;
      Inc(R.SkillsCallable);
      if Used.IndexOf(Skills[i].Name) < 0 then AddStr(R.UnusedSkills, Skills[i].Name);
    end;
    R.OverlapPairs := SkillOverlapPairs(Skills, SkillOverlapThreshold);
  finally
    FreePatterns(Patterns);
    Miner.Free;
    Used.Free;
  end;

  { 5. Review. }
  if O.Review and not O.DryRun then
  begin
    if O.Provider = nil then
      AddStr(R.Warnings, 'review requested but no provider was available')
    else
    try
      Opts := DefaultChatOptions;
      Opts.MaxTokens := 700;
      Opts.SystemPrompt := 'You review an AI agent''s day for its operator. Be specific and brief.';
      SetLength(Msgs, 1);
      Msgs[0] := MakeMessage(mrUser, ReviewPrompt(O, R));
      Resp := O.Provider.Chat(Msgs, [], O.Model, Opts);
      if Trim(Resp.Content) = '' then
        AddStr(R.Warnings, Format('review: empty reply from %s (status %d)', [O.Model, Resp.StatusCode]))
      else
        R.ReviewText := Resp.Content;
    except
      on E: Exception do AddStr(R.Warnings, 'review failed: ' + E.Message);
    end;
  end;

  { 6. Backup. }
  if O.DoBackup and not O.DryRun then
  begin
    if RunBackup(O.Home, O.Workspace, O.BackupDir, O.Version,
                 O.KeepDaily, O.KeepWeekly, O.KeepMonthly, O.BackupWithSecrets, BR, Err) then
    begin
      R.BackupPath := BR.ZipPath;
      R.BackupPruned := Length(BR.Pruned);
    end
    else
      AddStr(R.Warnings, 'backup failed: ' + Err);
    Err := '';
  end;

  { 7. Report. }
  if not O.DryRun then
  begin
    ReportDir := JoinPath(MemDir, 'maintenance');
    try
      EnsureDir(ReportDir);
      R.ReportPath := JoinPath(ReportDir, O.Today + '.md');
      WriteFileText(R.ReportPath, RenderMaintenanceReport(O, R));
    except
      on E: Exception do
      begin
        R.ReportPath := '';
        AddStr(R.Warnings, 'report could not be written: ' + E.Message);
      end;
    end;
  end;
  Result := True;
end;

function RunMaintenanceForCron(Cfg: TConfig; out Err: string): string;
var
  O: TMaintainOptions;
  R: TMaintainReport;
  Prov: ILLMProvider;
  PErr: string;
begin
  Result := '';
  Err := '';
  O := DefaultMaintainOptions(Cfg);
  if O.Review then
  begin
    if (Cfg = nil) or not NewProviderFromConfig(Cfg, Cfg.DefaultProvider, Prov, PErr) then
    begin
      LogWarn('maintain: review requested but no provider: %s', [PErr]);
      O.Review := False;
    end
    else
      O.Provider := Prov;
  end;
  if not RunMaintenance(O, R, Err) then Exit;
  Result := Format('maintenance %s: %d facts removed (%d active); %d sessions, %d tool calls, ' +
                   '%d failures; %d recurring (%d new in SCARS.md); %d unused skills, %d overlapping pairs',
                   [O.Today, R.FactsRemoved, R.FactsActive, R.SessionsScanned, R.ToolCalls,
                    R.ToolFailures, R.RecurringCount, R.ScarsNew,
                    Length(R.UnusedSkills), Length(R.OverlapPairs)]);
  if R.BackupPath <> '' then Result := Result + '; backup ' + ExtractFileName(R.BackupPath);
  if R.ReportPath <> '' then Result := Result + '; report ' + R.ReportPath;
  if Length(R.Warnings) > 0 then
    Result := Result + Format('; %d warning(s), see report', [Length(R.Warnings)]);
end;

end.
