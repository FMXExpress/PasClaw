program maintain_tests;
(*
  PasClaw.Maintain -- the nightly pass, against a temp PASCLAW_HOME.

    - LooksLikeFailure (PasClaw.Learn's, which the pass counts by): positives
      and the negatives that matter
      ("exit code 0", "0 failed").
    - SkillOverlapPairs: near-duplicate pair found, distinct pair not.
    - RunMaintenance end to end with Review off and DryRun off:
        * a fact store with one expired and one active fact: the expired
          one is swept, the active one is counted
        * MEMORY.md over the budget is flagged; USER.md under it is not
        * two sessions in the window: turns, tool calls, one failure with
          its sample line; a session outside the window is ignored for
          stats but its skill call still counts as usage
        * skills: the called one is used, the uncalled callable one is
          listed, the knowledge-only one is neither; the near-duplicate
          pair is reported
        * the report file lands under memory/maintenance/<date>.md and
          says all of the above; a backup zip exists when DoBackup
    - DryRun: nothing deleted, no report file, counts still reported.
    - RenderMaintenanceReport mentions the six-months test only when a
      core file is over budget.

  The Makefile points PASCLAW_HOME at a fresh temp dir for this binary.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Session.Store,
  PasClaw.Skills.Loader,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts,
  PasClaw.Learn,
  PasClaw.Maintain;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '"'); end;
procedure AssertNotContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) > 0 then Fail_(Msg + ' -- did not expect "' + Needle + '"'); end;

function InList(const L: array of string; const S: string): Boolean;
var i: Integer;
begin
  for i := 0 to High(L) do if L[i] = S then Exit(True);
  Result := False;
end;

function ValidUtf8(const S: string): Boolean;
var
  i, n, k: Integer;
begin
  Result := False;
  i := 1;
  while i <= Length(S) do
  begin
    n := Utf8SeqLen(Ord(S[i]));
    if (n = 0) or (i + n - 1 > Length(S)) then Exit;
    for k := 1 to n - 1 do
      if (Ord(S[i + k]) and $C0) <> $80 then Exit;
    Inc(i, n);
  end;
  Result := True;
end;

function JoinArr(const L: array of string): string;
var i: Integer;
begin
  Result := '';
  for i := 0 to High(L) do
  begin
    if Result <> '' then Result := Result + ' | ';
    Result := Result + L[i];
  end;
end;

procedure TestHeuristics;
var
  A, B: TSkillSpecArray;
  Pairs: TArray<string>;
begin
  AssertTrue(LooksLikeFailure('ERROR: npm test failed with exit code 1'), 'error line');
  AssertTrue(LooksLikeFailure('bash: pnpm: command not found'), 'command not found');
  AssertTrue(LooksLikeFailure('Traceback (most recent call last):'), 'traceback');
  AssertTrue(not LooksLikeFailure('exit code 0'), 'exit code 0 is not a failure');
  AssertTrue(not LooksLikeFailure('12 passed, 0 failed'), '0 failed is not a failure');
  AssertTrue(not LooksLikeFailure('wrote 3 files'), 'plain success line');
  AssertTrue(not LooksLikeFailure(''), 'empty line');

  SetLength(A, 3);
  A[0].Name := 'deploy_site';     A[0].Description := 'Deploy the static site to the production bucket';
  A[1].Name := 'deploy_website';  A[1].Description := 'Deploy the static site to the production bucket';
  A[2].Name := 'weather';         A[2].Description := 'Fetch the weather for a city';
  Pairs := SkillOverlapPairs(A, SkillOverlapThreshold);
  AssertEqInt(Length(Pairs), 1, 'one overlapping pair');
  AssertContains(Pairs[0], 'deploy_site <-> deploy_website', 'the pair is named');
  SetLength(B, 0);
  AssertEqInt(Length(SkillOverlapPairs(B, SkillOverlapThreshold)), 0, 'no skills, no pairs');
  WriteLn('  ok: failure heuristic and skill overlap');
end;

procedure WriteF(const Path, Text: string);
begin
  EnsureDir(ExtractFileDir(Path));
  WriteFileText(Path, Text);
end;

procedure WriteSkill(const Dir, Name, Desc, Kind: string);
var
  S: string;
begin
  S := '---' + #10 + 'name: ' + Name + #10 + 'description: ' + Desc + #10;
  if Kind <> '' then
    S := S + 'kind: ' + Kind + #10 + 'shell: echo hi' + #10;
  S := S + '---' + #10 + '# ' + Name + #10;
  WriteF(JoinPath(JoinPath(Dir, Name), 'SKILL.md'), S);
end;

function MkFact(const Txt, Expires: string): TFact;
begin
  Result := Default(TFact);
  Result.Text := Txt;
  Result.Kind := 'dynamic';
  Result.Scope := 'user';
  Result.Confidence := 0.9;
  Result.Expires := Expires;
  Result.SourceSession := 's';
end;

procedure SaveSession(const Id: string; UpdatedAt: Int64; const Msgs: array of TMessage;
                      InTok, OutTok: Int64);
var
  S: TSession;
  i: Integer;
begin
  S := TSession.Create(Id);
  try
    SetLength(S.Messages, Length(Msgs));
    for i := 0 to High(Msgs) do S.Messages[i] := Msgs[i];
    S.Meta.Id := Id;
    S.Meta.CreatedAt := UpdatedAt;
    S.Meta.UpdatedAt := UpdatedAt;
    S.Meta.Model := 'm';
    S.Meta.Provider := 'p';
    S.Meta.Stats.InputTokens := InTok;
    S.Meta.Stats.OutputTokens := OutTok;
    S.Meta.Stats.Turns := 1;
    S.Save;
  finally
    S.Free;
  end;
end;

function ToolCallMsg(const ToolName, Id: string): TMessage;
begin
  Result := MakeMessage(mrAssistant, '');
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0].Id := Id;
  Result.ToolCalls[0].Func.Name := ToolName;
  Result.ToolCalls[0].Func.Arguments := '{}';
end;

function ToolResult(const Id, Content: string): TMessage;
begin
  Result := MakeMessage(mrTool, Content);
  Result.ToolCallId := Id;
end;

procedure TestPass;
var
  Home, Ws, MemDir, Today, Big, Report, Rendered: string;
  O: TMaintainOptions;
  R: TMaintainReport;
  Err: string;
  Store: IFactStore;
  NowU: Int64;
  i: Integer;
begin
  Home := GetHome;
  Ws := JoinPath(Home, 'workspace');
  MemDir := JoinPath(Ws, 'memory');
  EnsureDir(MemDir);
  NowU := DateTimeToUnix(Now, False);
  Today := FormatDateTime('yyyy-mm-dd', Now);

  { Facts: one expired, one active. }
  Store := NewFactStore;
  AssertTrue(Store.Open(JoinPath(MemDir, 'facts.db')), 'open facts');
  AssertTrue(Store.Add(MkFact('old sprint goal', '2020-01-01'), NowU - 100) > 0, 'add expired');
  AssertTrue(Store.Add(MkFact('prefers tabs', ''), NowU - 50) > 0, 'add active');
  Store.Close;
  Store := nil;

  { Core files: MEMORY.md over a 500-byte budget, USER.md under. }
  Big := '';
  for i := 1 to 40 do Big := Big + Format('- durable note %d that is long enough to matter', [i]) + #10;
  WriteF(JoinPath(MemDir, 'MEMORY.md'), Big);
  WriteF(JoinPath(MemDir, 'USER.md'), 'Name: Eli');

  { Skills: one called, one callable but never called, one knowledge-only,
    plus a near-duplicate of the called one. }
  WriteSkill(JoinPath(Ws, 'skills'), 'deploy_site',    'Deploy the static site to the production bucket', 'shell');
  WriteSkill(JoinPath(Ws, 'skills'), 'deploy_website', 'Deploy the static site to the production bucket', 'shell');
  WriteSkill(JoinPath(Ws, 'skills'), 'unused_thing',   'Rotate the logs on the NAS', 'shell');
  WriteSkill(JoinPath(Ws, 'skills'), 'notes_only',     'How the deploy pipeline is wired', '');

  { Sessions: two in the last day, one 10 days old. }
  SaveSession('20260101T000001-aaaaaaaa', NowU - 3600,
    [MakeMessage(mrUser, 'deploy it'),
     ToolCallMsg('skill_deploy_site', 'c1'),
     ToolResult('c1', 'ok' + #10 + 'done'),
     MakeMessage(mrAssistant, 'deployed')], 1000, 100);
  SaveSession('20260101T000002-bbbbbbbb', NowU - 7200,
    [MakeMessage(mrUser, 'run the tests'),
     ToolCallMsg('shell', 'c2'),
     ToolResult('c2', '$ npm test' + #10 + 'bash: npm: command not found' + #10 + 'exit code 127'),
     MakeMessage(mrAssistant, 'npm is missing'),
     MakeMessage(mrUser, 'ok use pnpm'),
     ToolCallMsg('shell', 'c3'),
     ToolResult('c3', '12 passed, 0 failed'),
     ToolCallMsg('grep_files', 'c8'),
     ToolResult('c8', '(no matches) -- note: grep_files matches a LITERAL substring, ' +
       'not a regex. Search one plain term (e.g. "to_csv"), or run it once per alternative.'),
     ToolCallMsg('memory_search', 'c12'),
     ToolResult('c12', 'notes.md'#10'  error: the build broke on Tuesday'),   { quoted }
     MakeMessage(mrAssistant, 'green')], 2000, 300);
  { cccc and eeee are outside the one-day stats window but inside the
    30-day learn window, and fail the way bbbb did: one recurring pattern.
    eeee (25 days) is past the 20-day skill window too, so its skill call
    does not count as a use. dddd fails the same way, but 40 days ago,
    past every window. ffff has no timestamp: inside the learn window, as
    `pasclaw learn` has it, and outside the others. cccc and eeee also
    read SCARS.md back (memory_search) and cat it (shell): quoted, so not
    a second recurring pattern. }
  SaveSession('20260101T000003-cccccccc', NowU - 10 * 86400,
    [MakeMessage(mrUser, 'old'),
     ToolCallMsg('skill_deploy_website', 'c4'),
     ToolResult('c4', 'ok'),
     ToolCallMsg('shell', 'c5'),
     ToolResult('c5', 'bash: npm: command not found'),
     ToolCallMsg('shell', 'c7'),
     ToolResult('c7', 'error: disk quota exceeded'),   { once: not recurring }
     ToolCallMsg('memory_search', 'c10'),
     ToolResult('c10', 'SCARS.md'#10'  **Symptom:** ERROR: refused: eval'#10 +
       'notes.md'#10'  error: the build broke on Tuesday'),
     ToolCallMsg('shell', 'c11'),
     ToolResult('c11', '**Symptom:** ERROR: refused: eval'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);
  SaveSession('20260101T000005-eeeeeeee', NowU - 25 * 86400,
    [MakeMessage(mrUser, 'a while back'),
     ToolCallMsg('skill_unused_thing', 'c1'),
     ToolResult('c1', 'rotated'),
     ToolCallMsg('shell', 'c2'),
     ToolResult('c2', 'bash: npm: command not found'),
     ToolCallMsg('memory_search', 'c10'),
     ToolResult('c10', 'SCARS.md'#10'  **Symptom:** ERROR: refused: eval'#10 +
       'notes.md'#10'  error: the build broke on Tuesday'),
     ToolCallMsg('shell', 'c11'),
     ToolResult('c11', '**Symptom:** ERROR: refused: eval'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);
  SaveSession('20260101T000006-ffffffff', 0,
    [MakeMessage(mrUser, 'undated'),
     ToolCallMsg('shell', 'c1'),
     ToolResult('c1', 'bash: npm: command not found'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);
  { gggg: 33 days, inside a 35-day stats window and outside the learn and
    skill windows, so only a stats window that loads on its own reaches it. }
  SaveSession('20260101T000007-gggggggg', NowU - 33 * 86400,
    [MakeMessage(mrUser, 'a month ago'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);
  SaveSession('20260101T000004-dddddddd', NowU - 40 * 86400,
    [MakeMessage(mrUser, 'ancient'),
     ToolCallMsg('shell', 'c6'),
     ToolResult('c6', 'bash: npm: command not found'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);

  O := DefaultMaintainOptions(nil);
  O.Home := Home;
  O.Workspace := 'workspace';
  O.Today := Today;
  O.NowUnix := NowU;
  O.SinceDays := 1;
  O.UnusedSkillDays := 20;
  O.CoreBudget := 500;
  O.Review := False;
  O.DoBackup := True;
  O.BackupDir := JoinPath(Home, 'backups');
  O.Version := 'test 0.0.0';

  AssertTrue(RunMaintenance(O, R, Err), 'pass runs: ' + Err);
  AssertEqInt(Length(R.Warnings), 0, 'no warnings: ' + JoinArr(R.Warnings));

  AssertTrue(R.FactsAvailable, 'facts available');
  AssertEqInt(R.FactsTotalBefore, 2, 'two facts before');
  AssertEqInt(R.FactsRemoved, 1, 'expired fact swept');
  AssertEqInt(R.FactsActive, 1, 'active fact kept');

  AssertEqInt(Length(R.Core), 5, 'five core slots');
  AssertTrue(R.Core[2].Exists and (R.Core[2].Bytes > 500), 'MEMORY.md is over budget');
  AssertTrue(R.Core[1].Exists and (R.Core[1].Bytes < 500), 'USER.md is under budget');
  AssertTrue(not R.Core[0].Exists, 'SOUL.md absent');

  AssertEqInt(R.SessionsScanned, 2, 'two sessions in the window');
  AssertEqInt(R.Turns, 3, 'three user turns');
  AssertEqInt(R.ToolCalls, 5, 'five tool calls in the window');
  AssertEqInt(R.ToolFailures, 1, 'one failing tool result');
  AssertEqInt(R.ToolMisuses, 1, 'one misused tool: grep_files given a regex');
  AssertEqInt(Length(R.FailureSamples), 1, 'one sample');
  AssertContains(R.FailureSamples[0], 'command not found', 'the sample is the failing line');
  AssertEqInt(Integer(R.InputTokens), 3000, 'input tokens summed over the window');
  AssertEqInt(Integer(R.OutputTokens), 400, 'output tokens summed over the window');

  AssertEqInt(R.SkillsTotal, 4, 'four skills');
  AssertEqInt(R.SkillsCallable, 3, 'three callable');
  AssertTrue(InList(R.UnusedSkills, 'unused_thing'), 'uncalled callable skill listed');
  AssertTrue(not InList(R.UnusedSkills, 'deploy_site'), 'called skill not listed');
  AssertTrue(not InList(R.UnusedSkills, 'deploy_website'), 'skill called 10 days ago counts as used');
  AssertTrue(not InList(R.UnusedSkills, 'notes_only'), 'knowledge-only skill is not "unused"');

  { Recurring: npm missing in bbbb, cccc, eeee and the undated ffff (dddd is
    past the window); what cccc and eeee only quoted is not a pattern. }
  AssertEqInt(R.RecurringCount, 1, 'one pattern recurs across sessions');
  AssertContains(R.Recurring[0], '4x across 4 sessions', 'counted over the learn window only');
  AssertContains(R.Recurring[0], '`shell`', 'attributed to its tool');
  AssertContains(R.Recurring[0], 'npm: command not found', 'with its sample');
  AssertContains(R.Recurring[0], '` ' + SectionSign + 'BASH-NPM-COMMAND-NOT-FOUND', 'and its anchor');
  AssertTrue(R.ScarsPath <> '', 'SCARS.md refreshed');
  AssertEqInt(R.ScarsNew, 1, 'one new anchor');
  AssertTrue(FileExists(JoinPath(MemDir, 'SCARS.md')), 'SCARS.md written in the workspace memory');
  AssertContains(ReadFileText(JoinPath(MemDir, 'SCARS.md')), 'npm: command not found',
                 'SCARS.md holds the pattern');
  AssertEqInt(Length(R.OverlapPairs), 1, 'one overlapping pair');
  { Directory listing order decides which name comes first. }
  AssertContains(R.OverlapPairs[0], 'deploy_site', 'pair names deploy_site');
  AssertContains(R.OverlapPairs[0], 'deploy_website', 'pair names deploy_website');
  AssertContains(R.OverlapPairs[0], '<->', 'pair is a pair');

  AssertTrue(R.BackupPath <> '', 'backup ran');
  AssertTrue(FileExists(R.BackupPath), 'backup zip exists');
  AssertTrue(R.ReportPath <> '', 'report written');
  AssertTrue(FileExists(R.ReportPath), 'report file exists');
  AssertContains(R.ReportPath, 'maintenance' + PathDelim + Today + '.md', 'report path under memory/maintenance');
  Report := ReadFileText(R.ReportPath);
  AssertContains(Report, '# Maintenance ' + Today, 'report title');
  AssertContains(Report, '1 removed', 'report: facts removed');
  AssertContains(Report, 'MEMORY.md:', 'report: MEMORY.md sized');
  AssertContains(Report, 'over the 500-byte budget', 'report: over budget flagged');
  AssertContains(Report, 'six-months test', 'report: six-months test when over budget');
  AssertContains(Report, '2 sessions, 3 turns, 5 tool calls, 1 tool failure, 1 misuse', 'report: session line');
  AssertContains(Report, 'command not found', 'report: failure sample');
  AssertContains(Report, '## Recurring (last 30 days, 2+ sessions)', 'report: recurring section');
  AssertContains(Report, 'SCARS.md: 1 new anchor added, 0 already there', 'report: SCARS refresh');
  AssertContains(Report, '- unused_thing', 'report: unused skill');
  AssertContains(Report, 'overlapping (likely the same skill twice)', 'report: overlap');
  AssertContains(Report, '## Backup', 'report: backup section');
  AssertNotContains(Report, '## Review', 'report: no review section without a model');
  AssertNotContains(Report, '## Warnings', 'report: no warnings section');

  { Dry run on the now-swept store: counts, no deletes, no new report. }
  SysUtils.DeleteFile(R.ReportPath);
  Store := NewFactStore;
  AssertTrue(Store.Open(JoinPath(MemDir, 'facts.db')), 'reopen facts');
  AssertTrue(Store.Add(MkFact('another old one', '2019-01-01'), NowU - 10) > 0, 'add expired again');
  Store.Close;
  Store := nil;
  O.DryRun := True;
  O.DoBackup := True;
  AssertTrue(RunMaintenance(O, R, Err), 'dry run runs: ' + Err);
  AssertEqInt(R.FactsRemoved, 0, 'dry run removes nothing');
  AssertEqInt(R.FactsTotalBefore, 2, 'dry run still counts');
  AssertTrue(R.ReportPath = '', 'dry run writes no report');
  AssertTrue(R.BackupPath = '', 'dry run makes no backup');
  AssertTrue(not FileExists(JoinPath(JoinPath(MemDir, 'maintenance'), Today + '.md')), 'no report file after dry run');
  Rendered := RenderMaintenanceReport(O, R);
  AssertContains(Rendered, 'Dry run', 'rendered report says dry run');
  AssertEqInt(R.RecurringCount, 1, 'dry run still finds the pattern');
  AssertTrue(R.ScarsPath = '', 'dry run leaves SCARS.md alone');
  AssertContains(Rendered, 'SCARS.md not refreshed (dry run): 0 new anchors would be added', 'and says so');
  AssertContains(R.Recurring[0], SectionSign + 'BASH-NPM-COMMAND-NOT-FOUND', 'citing the anchor SCARS.md has');

  { A second real run finds the anchor already there -- under the name the
    operator gave it, which is the one the report cites. }
  Big := ReadFileText(JoinPath(MemDir, 'SCARS.md'));
  Big := StringReplace(Big, '## ' + SectionSign + 'BASH-NPM-COMMAND-NOT-FOUND',
                       '## ' + SectionSign + 'NPM-MISSING', []);
  WriteF(JoinPath(MemDir, 'SCARS.md'), Big);
  O.DryRun := False;
  O.DoBackup := False;
  AssertTrue(RunMaintenance(O, R, Err), 'second run');
  AssertEqInt(R.ScarsNew, 0, 'nothing new for SCARS.md');
  AssertEqInt(R.ScarsKnown, 1, 'the anchor is already there');
  AssertContains(R.Recurring[0], '` ' + SectionSign + 'NPM-MISSING', 'cited by its new name');

  { A skill window longer than the learn window: dddd is read for its
    skill calls, but its failure is still too old to count. }
  O.UnusedSkillDays := 60;
  AssertTrue(RunMaintenance(O, R, Err), 'long skill window');
  AssertContains(R.Recurring[0], '4x across 4 sessions', 'the learn window still holds');
  O.UnusedSkillDays := 20;

  { A stats window longer than the skill window: every session in it counts. }
  O.SinceDays := 35;
  AssertTrue(RunMaintenance(O, R, Err), 'long stats window');
  AssertEqInt(R.SessionsScanned, 5, 'aaaa, bbbb, cccc, eeee and gggg are within 35 days');
  O.SinceDays := 1;

  { Under budget: no six-months nag. }
  O.CoreBudget := 0;
  AssertTrue(RunMaintenance(O, R, Err), 'uncapped run');
  Rendered := RenderMaintenanceReport(O, R);
  AssertNotContains(Rendered, 'six-months test', 'no nag when nothing is over budget');

  { A long line with a two-byte character across the 160-column cut: the
    sample and the recurring line keep it whole. }
  Big := 'error: ' + StringOfChar('x', 152) + #$C3#$A9 + ' and the rest of the line';
  SaveSession('20260101T000008-hhhhhhhh', NowU - 60,
    [ToolCallMsg('shell', 'c1'), ToolResult('c1', Big)], 0, 0);
  SaveSession('20260101T000009-iiiiiiii', NowU - 120,
    [ToolCallMsg('shell', 'c1'), ToolResult('c1', Big)], 0, 0);
  AssertTrue(RunMaintenance(O, R, Err), 'utf-8 run');
  for i := 0 to High(R.FailureSamples) do
    AssertTrue(ValidUtf8(R.FailureSamples[i]), 'a failure sample is valid UTF-8: ' + R.FailureSamples[i]);
  for i := 0 to High(R.Recurring) do
    AssertTrue(ValidUtf8(R.Recurring[i]), 'a recurring line is valid UTF-8: ' + R.Recurring[i]);
  AssertContains(JoinArr(R.FailureSamples), #$C3#$A9, 'the character is kept, not cut');

  WriteLn('  ok: sweep / core sizes / sessions / skills / backup / report / dry run');
end;

begin
  TestHeuristics;
  TestPass;
  WriteLn('PASS');
end.
