program active_plan_section_tests;
(*
  Pins BuildActivePlanSection's three gating cases (NoPlan opt-out,
  pmPlan suppression, missing file) and the happy-path injection of
  PLAN.md as system-prompt context. Belt-and-braces guard against
  someone refactoring BuildSystemPrompt and silently dropping the
  Phase-2 wiring.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,        { GetHome }
  PasClaw.Utils,
  PasClaw.Agent.Mode,
  PasClaw.Agent.Prompt;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin if Pos(Needle, Haystack) = 0 then
  Fail_(Msg + ' (no "' + Needle + '" in section)'); end;

procedure AssertEmpty(const S, Msg: string);
begin if Trim(S) <> '' then Fail_(Msg + ' (got "' + S + '")'); end;

procedure WritePlanInHome(const Body: string);
var
  Path, Dir: string;
begin
  Dir := JoinPath(GetHome, 'workspace');
  ForceDirectories(Dir);
  Path := JoinPath(Dir, 'PLAN.md');
  WriteFileText(Path, Body);
end;

procedure DeletePlanInHome;
var
  Path: string;
begin
  Path := JoinPath(JoinPath(GetHome, 'workspace'), 'PLAN.md');
  if FileExists(Path) then SysUtils.DeleteFile(Path);
end;

procedure TestEmptyWhenNoPlanTrue;
var
  Section: string;
begin
  WritePlanInHome('## Goal' + sLineBreak + 'Test goal.' + sLineBreak);
  Section := BuildActivePlanSection({NoPlan=}True, pmBuild);
  AssertEmpty(Section, 'NoPlan=True must suppress the section');
  WriteLn('  ok: NoPlan=True suppresses (opt-out)');
end;

procedure TestEmptyWhenPlanMode;
var
  Section: string;
begin
  WritePlanInHome('## Goal' + sLineBreak + 'Test goal.' + sLineBreak);
  Section := BuildActivePlanSection({NoPlan=}False, pmPlan);
  AssertEmpty(Section, 'Mode=pmPlan must suppress the section ' +
                       '(Cmd.Plan handles PLAN.md via --system)');
  WriteLn('  ok: pmPlan mode suppresses (planner handles it)');
end;

procedure TestEmptyWhenPlanMissing;
var
  Section: string;
begin
  DeletePlanInHome;
  Section := BuildActivePlanSection({NoPlan=}False, pmBuild);
  AssertEmpty(Section, 'missing PLAN.md must produce empty section');
  WriteLn('  ok: missing PLAN.md -> empty');
end;

procedure TestInjectsBody;
var
  Section: string;
begin
  WritePlanInHome('## Goal' + sLineBreak +
                  'Add a flag.' + sLineBreak + sLineBreak +
                  '## Files' + sLineBreak +
                  '- src/main.pas' + sLineBreak);
  Section := BuildActivePlanSection({NoPlan=}False, pmBuild);
  AssertTrue(Section <> '', 'happy path produces a non-empty section');
  AssertContains(Section, '## Active Plan',
                 'section starts with the Active Plan header');
  AssertContains(Section, 'Add a flag.',
                 'section includes the plan body verbatim');
  AssertContains(Section, '## Files',
                 'section preserves plan subheadings');
  AssertContains(Section, '--no-plan',
                 'section mentions the opt-out flag');
  WriteLn('  ok: happy path injects PLAN.md body');
end;

procedure TestStaleNoteWhenOver24h;
var
  Section: string;
  Path: string;
begin
  WritePlanInHome('## Goal' + sLineBreak + 'Stale plan.' + sLineBreak);
  Path := JoinPath(JoinPath(GetHome, 'workspace'), 'PLAN.md');
  { Backdate mtime to 48h ago. FileSetDate takes a Unix-style age int. }
  FileSetDate(Path, DateTimeToFileDate(Now - 2.0));
  Section := BuildActivePlanSection({NoPlan=}False, pmBuild);
  AssertTrue(Section <> '', 'stale PLAN.md still loads');
  AssertContains(Section, 'stale:',
                 'stale plan picks up the "stale:" note');
  WriteLn('  ok: stale (>24h) PLAN.md gets a stale: note');
end;

begin
  { The Makefile sets PASCLAW_HOME to a fresh tempdir before invoking
    this binary, so each test run is isolated from the operator's
    real config. GetHome reads $PASCLAW_HOME and returns the
    Makefile-supplied path. }
  TestEmptyWhenNoPlanTrue;
  TestEmptyWhenPlanMode;
  TestEmptyWhenPlanMissing;
  TestInjectsBody;
  TestStaleNoteWhenOver24h;
  WriteLn('ok - active plan section tests passed');
end.
