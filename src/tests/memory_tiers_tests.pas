program memory_tiers_tests;
(*
  The always-loaded memory tier: SOUL.md / USER.md / MEMORY.md / the two
  daily notes, each capped by Cfg.MemoryCoreBudgetBytes.

    - ClampToBudget: no-op under budget or with budget 0; cuts at the
      last line boundary at or before the budget; a single over-long
      line is cut at the budget; ElidedBytes is exactly what was dropped;
      never splits a UTF-8 sequence when the cut lands on a newline.
    - BuildSystemPrompt against a temp PASCLAW_HOME: SOUL.md and USER.md
      are injected in their own subsections, in persona -> user ->
      durable order, before MEMORY.md; a MEMORY.md over budget carries
      the "elided" note naming the byte count and memory_search; budget
      0 injects the whole file and no note.
    - The memory rule carries the six-months test and names USER.md.
    - BackgroundModelFor: background_model wins, then fast_model, then ''.
    - Config round-trip for memory_core_budget_bytes (including 0),
      background_model, maintenance and backup blocks.

  The Makefile points PASCLAW_HOME at a fresh temp dir for this binary.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Agent.Prompt;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected to contain "' + Needle + '"'); end;

procedure AssertNotContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) > 0 then Fail_(Msg + ' -- did not expect "' + Needle + '"'); end;

procedure TestClamp;
var
  S, R: string;
  E: Integer;
begin
  S := 'line one' + #10 + 'line two' + #10 + 'line three';
  R := ClampToBudget(S, 0, E);
  AssertEqStr(R, S, 'budget 0 is no cap');
  AssertEqInt(E, 0, 'budget 0 elides nothing');
  R := ClampToBudget(S, 1000, E);
  AssertEqStr(R, S, 'under budget is untouched');
  AssertEqInt(E, 0, 'under budget elides nothing');

  { Budget lands inside "line two": cut back to the end of line one. }
  R := ClampToBudget(S, 12, E);
  AssertEqStr(R, 'line one', 'cut at the last line boundary before the budget');
  AssertEqInt(E, Length(S) - Length('line one'), 'elided is exactly what went');
  AssertTrue(Length(R) <= 12, 'result within budget');

  { Budget exactly on a newline: that newline is the cut. }
  R := ClampToBudget(S, 9, E);
  AssertEqStr(R, 'line one', 'budget on the newline cuts there');

  { One line longer than the budget: cut at the budget, lesser evil. }
  R := ClampToBudget('abcdefghij', 4, E);
  AssertEqStr(R, 'abcd', 'single over-long line is cut at the budget');
  AssertEqInt(E, 6, 'elided counts the tail');

  { Multi-byte content before the cut survives intact when the cut is a newline. }
  S := 'caf' + #$C3#$A9 + ' au lait' + #10 + 'second line here';
  R := ClampToBudget(S, Length(S) - 3, E);
  AssertEqStr(R, 'caf' + #$C3#$A9 + ' au lait', 'UTF-8 line kept whole');
  WriteLn('  ok: ClampToBudget no-op / line boundary / over-long line / utf-8');
end;

procedure TestPromptInjection;
var
  Home, MemDir, P, Big: string;
  Cfg: TConfig;
  i: Integer;
begin
  Home := GetHome;
  MemDir := JoinPath(Home, 'workspace/memory');
  EnsureDir(MemDir);
  WriteFileText(JoinPath(MemDir, 'SOUL.md'), '# Soul' + #10 + 'Terse. Honest. SOULMARK.');
  WriteFileText(JoinPath(MemDir, 'USER.md'), '# User' + #10 + 'Name: Eli. Prefers Delphi. USERMARK.');
  Big := '# Memory' + #10;
  for i := 1 to 200 do
    Big := Big + Format('- durable note number %d about the project MEMMARK%d', [i, i]) + #10;
  WriteFileText(JoinPath(MemDir, 'MEMORY.md'), Big);

  Cfg := TConfig.Create;
  try
    Cfg.MemoryCoreBudgetBytes := 2000;
    P := BuildSystemPrompt(Cfg, '', True, '');
    AssertContains(P, '### SOUL.md (who you are)', 'SOUL.md subsection present');
    AssertContains(P, 'SOULMARK', 'SOUL.md body injected');
    AssertContains(P, '### USER.md (who the user is)', 'USER.md subsection present');
    AssertContains(P, 'USERMARK', 'USER.md body injected');
    AssertContains(P, '### MEMORY.md (durable)', 'MEMORY.md subsection present');
    AssertTrue(Pos('SOULMARK', P) < Pos('USERMARK', P), 'persona before user');
    AssertTrue(Pos('USERMARK', P) < Pos('MEMMARK1 ', P) + Pos('MEMMARK1'#10, P),
               'user before durable');
    AssertContains(P, 'MEMMARK1', 'start of MEMORY.md kept');
    AssertNotContains(P, 'MEMMARK200', 'tail of an over-budget MEMORY.md is not injected');
    AssertContains(P, 'over the 2000-byte always-loaded budget elided', 'elided note names the budget');
    AssertContains(P, '`memory_search` reaches them', 'elided note points at memory_search');
    { The small files are under budget and carry no note of their own. }
    AssertEqInt(Length(StringReplace(P, 'always-loaded budget elided', '', [rfReplaceAll])),
                Length(P) - Length('always-loaded budget elided'),
                'exactly one file was clamped');

    { The rule text. }
    AssertContains(P, 'six months', 'memory rule carries the six-months test');
    AssertContains(P, 'USER.md', 'memory rule names USER.md');

    { Budget 0: whole file, no note. }
    Cfg.MemoryCoreBudgetBytes := 0;
    P := BuildSystemPrompt(Cfg, '', True, '');
    AssertContains(P, 'MEMMARK200', 'budget 0 injects the whole file');
    AssertNotContains(P, 'always-loaded budget elided', 'budget 0 has no elided note');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: SOUL/USER/MEMORY injected in order, over-budget file clamped with a note, rule text');
end;

procedure TestBackgroundModel;
var
  Cfg: TConfig;
begin
  Cfg := TConfig.Create;
  try
    AssertEqStr(BackgroundModelFor(nil), '', 'nil config -> empty');
    AssertEqStr(BackgroundModelFor(Cfg), '', 'neither key -> empty (caller keeps its model)');
    Cfg.FastModel := 'small-1';
    AssertEqStr(BackgroundModelFor(Cfg), 'small-1', 'fast_model is the fallback');
    Cfg.BackgroundModel := 'bg-1';
    AssertEqStr(BackgroundModelFor(Cfg), 'bg-1', 'background_model wins');
  finally
    Cfg.Free;
  end;
  WriteLn('  ok: BackgroundModelFor precedence');
end;

procedure TestConfigRoundTrip;
var
  A, B: TConfig;
  J: string;
begin
  A := TConfig.Create;
  B := TConfig.Create;
  try
    AssertEqInt(A.MemoryCoreBudgetBytes, 16384, 'default core budget');
    AssertEqInt(A.Maintenance.KeepSupersededDays, 30, 'default keep_superseded_days');
    AssertEqInt(A.Backup.KeepDaily, 7, 'default keep_daily');
    { Defaults do not emit the keys. }
    J := A.ToJSON;
    AssertNotContains(J, 'memory_core_budget_bytes', 'default budget not emitted');
    AssertNotContains(J, '"maintenance"', 'default maintenance block not emitted');
    AssertNotContains(J, '"backup"', 'default backup block not emitted');

    A.MemoryCoreBudgetBytes := 0;
    A.BackgroundModel := 'claude-haiku-4-5-20251001';
    A.Maintenance.Review := True;
    A.Maintenance.KeepSupersededDays := 7;
    A.Backup.Dir := '/mnt/backups';
    A.Backup.KeepMonthly := 12;
    J := A.ToJSON;
    B.FromJSON(J);
    AssertEqInt(B.MemoryCoreBudgetBytes, 0, 'explicit 0 budget round-trips');
    AssertEqStr(B.BackgroundModel, 'claude-haiku-4-5-20251001', 'background_model round-trips');
    AssertTrue(B.Maintenance.Review, 'maintenance.review round-trips');
    AssertEqInt(B.Maintenance.KeepSupersededDays, 7, 'keep_superseded_days round-trips');
    AssertEqInt(B.Maintenance.UnusedSkillDays, 30, 'untouched maintenance default survives');
    AssertEqStr(B.Backup.Dir, '/mnt/backups', 'backup.dir round-trips');
    AssertEqInt(B.Backup.KeepMonthly, 12, 'keep_monthly round-trips');
    AssertEqInt(B.Backup.KeepWeekly, 4, 'untouched backup default survives');
  finally
    A.Free;
    B.Free;
  end;
  WriteLn('  ok: config round-trip for the new keys');
end;

begin
  TestClamp;
  TestPromptInjection;
  TestBackgroundModel;
  TestConfigRoundTrip;
  WriteLn('PASS');
end.
