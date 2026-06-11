program orient_tests;
(*
  Covers PasClaw.Agent.Orient -- task-aware MEMORY slicing.

  Contracts pinned:
    - Sections whose text shares tokens with the task hint survive;
      unrelated sections are elided (and counted)
    - Original document order is preserved (no relevance re-sort)
    - Headingless prose falls back to paragraph-block slicing
    - The byte budget is honoured; over-budget sections count as elided
    - Degenerate hints (all short stopword-ish tokens) match nothing
    - Empty body / empty hint return '' without slicing
    - Token match is case-insensitive
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Agent.Orient;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

function SampleMemory: string;
begin
  Result :=
    '## Build system' + sLineBreak +
    'The project builds with FPC via make; Delphi uses PasClaw.dproj.' + sLineBreak +
    sLineBreak +
    '## Database conventions' + sLineBreak +
    'SQLite via FireDAC on Delphi, dynamic libsqlite3 on FPC.' + sLineBreak +
    sLineBreak +
    '## Holiday schedule' + sLineBreak +
    'Team is out the first week of July.' + sLineBreak +
    sLineBreak +
    '## Deployment' + sLineBreak +
    'Releases go out via GitHub Actions; tag with v-prefix.';
end;

procedure TestRelevantSectionsSurvive;
var
  Got: string;
  Elided: Integer;
begin
  Got := SelectRelevantSlices(SampleMemory,
           'fix the sqlite database open failure', 4096, Elided);
  AssertTrue(Pos('Database conventions', Got) > 0, 'database section kept');
  AssertTrue(Pos('Holiday schedule', Got) = 0, 'holiday section elided');
  AssertTrue(Elided >= 2, 'unrelated sections counted as elided');
end;

procedure TestOriginalOrderPreserved;
var
  Got: string;
  Elided: Integer;
begin
  { Hint matches Deployment strongly and Build weakly -- order in the
    output must still be document order (Build before Deployment). }
  Got := SelectRelevantSlices(SampleMemory,
           'deployment releases build make', 4096, Elided);
  AssertTrue(Pos('Build system', Got) > 0, 'build section kept');
  AssertTrue(Pos('Deployment', Got) > 0, 'deployment section kept');
  AssertTrue(Pos('Build system', Got) < Pos('Deployment', Got),
             'document order preserved');
end;

procedure TestHeadinglessParagraphFallback;
var
  Body, Got: string;
  Elided: Integer;
begin
  Body :=
    'We prefer tabs over spaces in the legacy tree.' + sLineBreak +
    sLineBreak +
    'The staging server lives at staging.example.com behind wireguard.' + sLineBreak +
    sLineBreak +
    'Lunch orders go in the #food channel.';
  Got := SelectRelevantSlices(Body, 'restart the staging server', 4096, Elided);
  AssertTrue(Pos('staging.example.com', Got) > 0, 'matching paragraph kept');
  AssertTrue(Pos('Lunch orders', Got) = 0, 'unrelated paragraph elided');
  AssertTrue(Elided = 2, 'two paragraphs elided');
end;

procedure TestBudgetHonoured;
var
  Body, Big, Got: string;
  Elided, i: Integer;
begin
  Big := '## Big section about sqlite' + sLineBreak;
  for i := 1 to 200 do
    Big := Big + 'sqlite filler line ' + IntToStr(i) + sLineBreak;
  Body := Big + sLineBreak +
          '## Small sqlite note' + sLineBreak +
          'sqlite is dynamically loaded.';
  { Budget too small for the big section -- it must be skipped (and
    counted as elided), while the small one still fits. }
  Got := SelectRelevantSlices(Body, 'sqlite loading', 200, Elided);
  AssertTrue(Pos('Small sqlite note', Got) > 0, 'small section fits budget');
  AssertTrue(Pos('filler line 50', Got) = 0, 'oversized section skipped');
  AssertTrue(Elided = 1, 'oversized section counted as elided');
  AssertTrue(Length(Got) <= 200, 'output within budget');
end;

procedure TestDegenerateHintMatchesNothing;
var
  Got: string;
  Elided: Integer;
begin
  Got := SelectRelevantSlices(SampleMemory, 'do it', 4096, Elided);
  AssertTrue(Got = '', 'stopword-only hint yields no slices');
  AssertTrue(Elided = 4, 'all sections reported elided');
end;

procedure TestEmptyInputs;
var
  Got: string;
  Elided: Integer;
begin
  Got := SelectRelevantSlices('', 'anything', 4096, Elided);
  AssertTrue(Got = '', 'empty body -> empty');
  Got := SelectRelevantSlices(SampleMemory, '', 4096, Elided);
  AssertTrue(Got = '', 'empty hint -> empty (caller keeps whole-file path)');
end;

procedure TestCaseInsensitiveMatch;
var
  Got: string;
  Elided: Integer;
begin
  Got := SelectRelevantSlices(SampleMemory, 'FIREDAC SQLITE', 4096, Elided);
  AssertTrue(Pos('Database conventions', Got) > 0,
             'uppercase hint matches lowercase body');
end;

begin
  TestRelevantSectionsSurvive;      WriteLn('  ok: relevant sections survive');
  TestOriginalOrderPreserved;       WriteLn('  ok: document order preserved');
  TestHeadinglessParagraphFallback; WriteLn('  ok: paragraph fallback');
  TestBudgetHonoured;               WriteLn('  ok: byte budget honoured');
  TestDegenerateHintMatchesNothing; WriteLn('  ok: degenerate hint -> no slices');
  TestEmptyInputs;                  WriteLn('  ok: empty inputs');
  TestCaseInsensitiveMatch;         WriteLn('  ok: case-insensitive match');
  WriteLn('PASS');
end.
