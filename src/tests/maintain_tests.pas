program maintain_tests;
(*
  PasClaw.Maintain -- the nightly pass, against a temp PASCLAW_HOME.

    - LooksLikeToolFailure: positives and the negatives that matter
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
  AssertTrue(LooksLikeToolFailure('ERROR: npm test failed with exit code 1'), 'error line');
  AssertTrue(LooksLikeToolFailure('bash: pnpm: command not found'), 'command not found');
  AssertTrue(LooksLikeToolFailure('Traceback (most recent call last):'), 'traceback');
  AssertTrue(not LooksLikeToolFailure('exit code 0'), 'exit code 0 is not a failure');
  AssertTrue(not LooksLikeToolFailure('12 passed, 0 failed'), '0 failed is not a failure');
  AssertTrue(not LooksLikeToolFailure('wrote 3 files'), 'plain success line');
  AssertTrue(not LooksLikeToolFailure(''), 'empty line');

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
     MakeMessage(mrAssistant, 'green')], 2000, 300);
  SaveSession('20260101T000003-cccccccc', NowU - 10 * 86400,
    [MakeMessage(mrUser, 'old'),
     ToolCallMsg('skill_deploy_website', 'c4'),
     ToolResult('c4', 'ok'),
     MakeMessage(mrAssistant, 'ok')], 500, 50);

  O := DefaultMaintainOptions(nil);
  O.Home := Home;
  O.Workspace := 'workspace';
  O.Today := Today;
  O.NowUnix := NowU;
  O.SinceDays := 1;
  O.UnusedSkillDays := 30;
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
  AssertEqInt(R.ToolCalls, 3, 'three tool calls in the window');
  AssertEqInt(R.ToolFailures, 1, 'one failing tool result');
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
  AssertContains(Report, '2 sessions, 3 turns, 3 tool calls, 1 tool failure', 'report: session line');
  AssertContains(Report, 'command not found', 'report: failure sample');
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

  { Under budget: no six-months nag. }
  O.CoreBudget := 0;
  AssertTrue(RunMaintenance(O, R, Err), 'uncapped run');
  Rendered := RenderMaintenanceReport(O, R);
  AssertNotContains(Rendered, 'six-months test', 'no nag when nothing is over budget');

  WriteLn('  ok: sweep / core sizes / sessions / skills / backup / report / dry run');
end;

begin
  TestHeuristics;
  TestPass;
  WriteLn('PASS');
end.
