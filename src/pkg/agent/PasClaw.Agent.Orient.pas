(*
  PasClaw.Agent.Orient - task-aware MEMORY slicing for the system
  prompt. Inspired by atlas's `orient` step: instead of injecting the
  WHOLE MEMORY.md + daily notes every turn (which grows without bound
  and front-loads the model's attention with mostly-irrelevant notes),
  pick only the sections that lexically overlap the task at hand and
  leave the rest on disk for memory_search.

  Mechanics, deliberately boring:

    - A "section" is a run of lines starting at a markdown heading
      ("#", "##", ...) and ending before the next heading. Files with
      no headings at all fall back to blank-line-separated paragraph
      blocks, so plain-prose notes still slice.

    - Scoring is bag-of-words overlap: lowercase the task hint, keep
      tokens of length >= 3 (drops "a"/"of"/"to" without a stopword
      list), dedupe, then count how many distinct hint tokens appear
      in each section. No embeddings here on purpose -- this runs
      synchronously inside system-prompt assembly on every turn, and
      the vector path (PasClaw.Memory.Vector) needs provisioned model
      weights this must not depend on.

    - Selection keeps every section that scored > 0, in ORIGINAL
      order (memory files are often chronological or curated -- the
      author's ordering carries meaning a relevance sort would
      destroy), accumulating until MaxBytes.

  Wiring: PasClaw.Agent.Prompt.BuildMemorySection calls
  SelectRelevantSlices per memory file when Cfg.OrientTaskAware is on
  AND the caller provided a task hint. Off (default) or hint-less
  calls keep the verbatim whole-file behaviour PasClaw has always
  had -- gateway requests with no clear "task", /goal-less REPL
  sessions, etc. degrade gracefully.
*)
unit PasClaw.Agent.Orient;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils;

const
  { Per-file budget for sliced injection. Roughly 1K tokens -- enough
    for a handful of substantial sections without recreating the
    whole-file problem the slicer exists to solve. }
  DefaultOrientBudgetBytes = 4096;

{ Slice Body into markdown-heading sections (paragraph blocks when no
  headings exist), score each against TaskHint by distinct-token
  overlap, and return the sections that scored > 0 -- original order,
  capped at MaxBytes. ElidedCount reports how many sections were
  dropped (zero-score or over-budget) so the caller can tell the model
  what it isn't seeing. Returns '' when nothing scored (caller decides
  the fallback: PasClaw.Agent.Prompt emits a memory_search pointer). }
function SelectRelevantSlices(const Body, TaskHint: string;
                              MaxBytes: Integer;
                              out ElidedCount: Integer): string;

implementation

uses
  Classes;

const
  { The function words length-filtering alone can't drop. Anything in
    here would match nearly every English paragraph and make every
    section "relevant". Deliberately small -- topical words must
    survive, and a missed stopword only costs an extra section. }
  StopWords: array[0..23] of string = (
    'the', 'and', 'for', 'with', 'that', 'this', 'from', 'into',
    'are', 'was', 'has', 'have', 'will', 'can', 'you', 'your',
    'not', 'but', 'all', 'any', 'its', 'out', 'use', 'how');

function IsStopWord(const Tok: string): Boolean;
var
  i: Integer;
begin
  for i := Low(StopWords) to High(StopWords) do
    if Tok = StopWords[i] then Exit(True);
  Result := False;
end;

function TokenizeHint(const TaskHint: string): TStringList;
{ Lowercased, deduped, stopword-stripped tokens of length >= 3.
  Caller frees. }
var
  i, Start: Integer;
  L, Tok: string;

  procedure Flush(EndPos: Integer);
  begin
    if EndPos - Start >= 3 then
    begin
      Tok := Copy(L, Start, EndPos - Start);
      if (not IsStopWord(Tok)) and (Result.IndexOf(Tok) < 0) then
        Result.Add(Tok);
    end;
  end;

begin
  Result := TStringList.Create;
  L := LowerCase(TaskHint);
  Start := 1;
  for i := 1 to Length(L) do
    if not CharInSet(L[i], ['a'..'z', '0'..'9', '_', '-']) then
    begin
      Flush(i);
      Start := i + 1;
    end;
  Flush(Length(L) + 1);
end;

procedure SplitSections(const Body: string; Sections: TStringList);
{ Markdown-heading sections; falls back to paragraph blocks when the
  file has no headings. Each Sections[i] is the full section text
  (heading line included), trailing whitespace trimmed. }
var
  Lines: TStringList;
  i: Integer;
  Cur: string;
  HasHeadings: Boolean;

  procedure Push;
  begin
    if Trim(Cur) <> '' then Sections.Add(TrimRight(Cur));
    Cur := '';
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Text := Body;
    HasHeadings := False;
    for i := 0 to Lines.Count - 1 do
      if (Length(Lines[i]) > 0) and (Lines[i][1] = '#') then
      begin
        HasHeadings := True;
        Break;
      end;

    Cur := '';
    for i := 0 to Lines.Count - 1 do
    begin
      if HasHeadings then
      begin
        if (Length(Lines[i]) > 0) and (Lines[i][1] = '#') then Push;
      end
      else
      begin
        if Trim(Lines[i]) = '' then begin Push; Continue; end;
      end;
      if Cur <> '' then Cur := Cur + sLineBreak;
      Cur := Cur + Lines[i];
    end;
    Push;
  finally
    Lines.Free;
  end;
end;

function SelectRelevantSlices(const Body, TaskHint: string;
                              MaxBytes: Integer;
                              out ElidedCount: Integer): string;
var
  Hint, Sections: TStringList;
  i, j, Score: Integer;
  SecLower: string;
  Budget: Integer;
begin
  Result := '';
  ElidedCount := 0;
  if (Trim(Body) = '') or (Trim(TaskHint) = '') then Exit;
  if MaxBytes <= 0 then MaxBytes := DefaultOrientBudgetBytes;

  Hint := TokenizeHint(TaskHint);
  Sections := TStringList.Create;
  try
    SplitSections(Body, Sections);
    if Hint.Count = 0 then
    begin
      { Hint degenerated to nothing scoreable ("do it", "go") --
        treat as no-match; the caller's fallback note applies. }
      ElidedCount := Sections.Count;
      Exit;
    end;

    Budget := MaxBytes;
    for i := 0 to Sections.Count - 1 do
    begin
      SecLower := LowerCase(Sections[i]);
      Score := 0;
      for j := 0 to Hint.Count - 1 do
        if Pos(Hint[j], SecLower) > 0 then Inc(Score);
      if (Score > 0) and (Length(Sections[i]) <= Budget) then
      begin
        if Result <> '' then Result := Result + sLineBreak + sLineBreak;
        Result := Result + Sections[i];
        Dec(Budget, Length(Sections[i]));
      end
      else
        Inc(ElidedCount);
    end;
  finally
    Hint.Free;
    Sections.Free;
  end;
end;

end.
