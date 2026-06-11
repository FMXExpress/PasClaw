(*
  PasClaw.Tools.Shell.Filters - per-command output condensers for
  shell_exec. Inspired by rtk-ai/rtk: most dev commands produce
  noisy, repetitive output (every passing test, every untouched
  file, every "ok" line); a small per-command filter that keeps
  the SIGNAL (failures, error messages, counts, the first few
  changed paths) drops typical context usage by an order of
  magnitude.

  Two design contracts:

    1. Tee-on-failure. When ExitCode <> 0, ApplyShellFilter
       returns RawOut UNCHANGED. The model needs the full output
       to debug a failing test / build / command -- losing the
       stack trace under "first 5 lines + ..." is worse than the
       token cost.

    2. Unknown commands pass through. We only filter when we
       recognise the leading token(s); a bespoke incantation the
       model invented should NEVER come back mangled. The
       output-cache layer (PasClaw.Tools.OutputCache) handles
       the byte-cap safety net for outputs we don't filter.

  Cross-shell normalisation: the dispatcher canonicalises Windows
  PowerShell aliases and cmd.exe equivalents so a `Select-String`
  vs `findstr` vs `grep -r` all hit the same filter. The model
  doesn't have to remember which shell is hosting it.

  Per-process counters track bytes saved so the TUI /stats
  overlay can surface the impact (BytesSaved is the sum across
  every successful filter invocation; FilteredCalls is the count).
*)
unit PasClaw.Tools.Shell.Filters;

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

(* Apply a command-specific filter to RawOut, returning a condensed
   summary suitable for the LLM. On non-zero ExitCode, returns
   RawOut unchanged (tee-on-failure: failures need full context).
   Unknown commands also pass through. *)
function ApplyShellFilter(const Cmd, RawOut: string;
                          ExitCode: Integer): string;

(* Canonical dispatch key for Cmd: lowercased first token, with
   Windows / PowerShell aliases collapsed to their Unix-style
   equivalents (`gci`/`dir`/`Get-ChildItem` -> `ls`; `sls`/
   `findstr`/`Select-String` -> `grep`; etc.). Empty when Cmd is
   blank or unrecognised. Exposed for tests. *)
function CanonicalizeShellCommand(const Cmd: string): string;

(* Counters reset to zero at startup; accumulate across every
   ApplyShellFilter call that actually reduced byte count. The
   TUI /stats overlay reads these so operators can see what the
   filters are saving. *)
function ShellFilterCalls: Int64;
function ShellFilterBytesSaved: Int64;
procedure ResetShellFilterCounters;

implementation

uses
  Classes, StrUtils,
  PasClaw.Condense.JSON;   { FilterAws routes JSON-shaped aws CLI
                             output through the shared condenser }

{$IFNDEF FPC}
type
  { FPC's SysUtils declares TStringArray; Delphi's RTL doesn't,
    so dcc64 errors on the SplitTokens return type and every
    downstream LowerCase(Tokens[i]) call below. Declare it
    locally for the Delphi build only -- same pattern PasClaw
    uses in PasClaw.Tools.Registry. }
  TStringArray = array of string;
{$ENDIF}

var
  GCalls:      Int64;
  GBytesSaved: Int64;

function ShellFilterCalls: Int64;      begin Result := GCalls; end;
function ShellFilterBytesSaved: Int64; begin Result := GBytesSaved; end;
procedure ResetShellFilterCounters;
begin
  GCalls      := 0;
  GBytesSaved := 0;
end;

{ =================== command-token extraction =================== }

function SplitTokens(const S: string): TStringArray;
{ Whitespace tokenisation that strips quotes. Good enough for
  dispatch: we only care about the first 1-2 tokens. }
var
  i, Start: Integer;
  In_, Inq: Boolean;
  Tmp: TStringList;
  Tok: string;
begin
  SetLength(Result, 0);
  Tmp := TStringList.Create;
  try
    In_  := False;
    Inq  := False;
    Start := 1;
    for i := 1 to Length(S) do
    begin
      if (not Inq) and ((S[i] = '"') or (S[i] = '''')) then
      begin
        Inq := True;
        if not In_ then begin Start := i + 1; In_ := True; end;
      end
      else if Inq and ((S[i] = '"') or (S[i] = '''')) then
      begin
        Inq := False;
        Tmp.Add(Copy(S, Start, i - Start));
        In_ := False;
      end
      else if (not Inq) and ((S[i] = ' ') or (S[i] = #9)) then
      begin
        if In_ then
        begin
          Tmp.Add(Copy(S, Start, i - Start));
          In_ := False;
        end;
      end
      else if not In_ then
      begin
        Start := i;
        In_ := True;
      end;
    end;
    if In_ then Tmp.Add(Copy(S, Start, Length(S) - Start + 1));

    SetLength(Result, Tmp.Count);
    for i := 0 to Tmp.Count - 1 do
    begin
      Tok := Tmp[i];
      { Strip remaining stray quotes that survived a partial split. }
      if (Length(Tok) >= 2) and (Tok[1] = '"') and (Tok[Length(Tok)] = '"') then
        Tok := Copy(Tok, 2, Length(Tok) - 2);
      Result[i] := Tok;
    end;
  finally
    Tmp.Free;
  end;
end;

function CanonicalizeShellCommand(const Cmd: string): string;
{ Normalise the dispatch key:
    Unix:           git status / ls / grep / make / pytest / ...
    PowerShell:     Get-ChildItem / Select-String / Get-Content / ...
                    (or aliases: gci, sls, gc, cat, ls, dir, type)
    cmd.exe:        dir / findstr / type / ...
  Strip leading "powershell.exe -Command", "pwsh -c", "cmd /c" so the
  filter dispatches on the real command, not the shell wrapper. }
var
  Tokens: TStringArray;
  First, Second: string;
  Idx: Integer;
begin
  Result := '';
  Tokens := SplitTokens(Trim(Cmd));
  if Length(Tokens) = 0 then Exit;

  { Peel a shell-wrapper prefix the model sometimes uses on Windows:
      powershell.exe -Command "git status"
      pwsh -c "git status"
      cmd.exe /c dir /s
    These wrappers carry the real command as the trailing argument. }
  Idx := 0;
  First := LowerCase(Tokens[0]);
  { sudo / npx are transparent runners -- the interesting command is
    the next token (`sudo docker ps`, `npx eslint src/`). Peel before
    the shell-wrapper check so `sudo bash -c "..."` also unwraps. }
  while ((First = 'sudo') or (First = 'npx')) and (Idx + 1 < Length(Tokens)) do
  begin
    Inc(Idx);
    First := LowerCase(Tokens[Idx]);
  end;
  if (First = 'powershell') or (First = 'powershell.exe') or
     (First = 'pwsh')       or (First = 'pwsh.exe') then
  begin
    Inc(Idx);
    if (Idx < Length(Tokens)) and
       ((LowerCase(Tokens[Idx]) = '-command') or
        (LowerCase(Tokens[Idx]) = '-c')) then
      Inc(Idx);
  end
  else if (First = 'cmd')     or (First = 'cmd.exe') then
  begin
    Inc(Idx);
    if (Idx < Length(Tokens)) and (LowerCase(Tokens[Idx]) = '/c') then
      Inc(Idx);
  end
  else if (First = 'sh')      or (First = 'bash') or
          (First = 'zsh')     or (First = 'fish') then
  begin
    Inc(Idx);
    if (Idx < Length(Tokens)) and (LowerCase(Tokens[Idx]) = '-c') then
      Inc(Idx);
  end;
  if Idx >= Length(Tokens) then Exit;
  First := LowerCase(Tokens[Idx]);

  { Alias collapse. PowerShell verb-noun cmdlets and their short
    aliases map onto the Unix tool with the matching shape. cmd.exe's
    `dir` / `type` / `findstr` ride along since the output shape we
    filter on is similar enough. }
  if (First = 'dir') or (First = 'gci') or (First = 'get-childitem') then
    First := 'ls'
  else if (First = 'gc') or (First = 'get-content') or (First = 'type') then
    First := 'cat'
  else if (First = 'sls') or (First = 'select-string') or (First = 'findstr') then
    First := 'grep'
  else if (First = 'pip3') then
    First := 'pip'
  else if (Pos('gradlew', First) > 0) then
    { ./gradlew, gradlew.bat, /path/to/gradlew -- the wrapper script
      produces the same output shape as a bare gradle. }
    First := 'gradle';

  { Two-word commands have a meaningful subcommand the filter
    dispatcher cares about (git status vs git diff vs git log,
    docker ps vs docker build, kubectl get vs kubectl describe). }
  if (First = 'git')    or (First = 'npm')     or (First = 'pnpm')      or
     (First = 'yarn')   or (First = 'cargo')   or (First = 'mvn')       or
     (First = 'docker') or (First = 'kubectl') or (First = 'gh')        or
     (First = 'go')     or (First = 'pip')     or (First = 'terraform') or
     (First = 'gradle') then
  begin
    if Idx + 1 < Length(Tokens) then
    begin
      Second := LowerCase(Tokens[Idx + 1]);
      { npm i == npm install -- collapse so the dispatcher needs one key. }
      if ((First = 'npm') or (First = 'pnpm')) and (Second = 'i') then
        Second := 'install';
      { An option in subcommand position (`docker --context prod ps`)
        means we can't tell where the real subcommand starts without
        knowing each flag's arity. Degrade to the one-word key -- the
        dispatcher won't match it and the output passes through, which
        beats mis-dispatching to the wrong filter. }
      if (Length(Second) > 0) and (Second[1] = '-') then
        Second := '';
    end
    else
      Second := '';
    Result := Trim(First + ' ' + Second);
  end
  else
    Result := First;
end;

{ =================== shared line helpers =================== }

function SplitLines(const S: string): TArray<string>;
var
  i, Start: Integer;
begin
  SetLength(Result, 0);
  Start := 1;
  for i := 1 to Length(S) do
  begin
    if S[i] = #10 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(S, Start, i - Start);
      { Strip trailing CR for CRLF lines. }
      if (Length(Result[High(Result)]) > 0) and
         (Result[High(Result)][Length(Result[High(Result)])] = #13) then
        SetLength(Result[High(Result)], Length(Result[High(Result)]) - 1);
      Start := i + 1;
    end;
  end;
  if Start <= Length(S) then
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := Copy(S, Start, Length(S) - Start + 1);
  end;
end;

function JoinLines(const Lines: array of string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(Lines) do
  begin
    if i > 0 then Result := Result + sLineBreak;
    Result := Result + Lines[i];
  end;
end;

{ =================== per-command filters =================== }

function FilterGitStatus(const Raw: string): string;
{ `git status` (porcelain or default). Original output: branch
  header + Changes-to-be-committed + Changes-not-staged +
  Untracked-files, each with full file lists. We surface the
  branch line, file counts, and at most TOP_K files per group. }
const
  TOP_K = 8;
type
  TGroup = (gStaged, gUnstaged, gUntracked);
var
  Lines: TArray<string>;
  i: Integer;
  L: string;
  Branch: string;
  Counts: array[TGroup] of Integer;
  Samples: array[TGroup] of TStringList;
  Group: TGroup;
  Out_: TStringList;
  GotAny: Boolean;
  S: string;
  Mode: Integer;       { 0 = header, 1 = staged, 2 = unstaged, 3 = untracked }
begin
  Lines := SplitLines(Raw);
  Branch := '';
  for Group := gStaged to gUntracked do
  begin
    Counts[Group] := 0;
    Samples[Group] := TStringList.Create;
  end;
  Mode := 0;
  GotAny := False;
  try
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      if Pos('On branch ', L) = 1 then
      begin
        Branch := Copy(L, Length('On branch ') + 1, MaxInt);
        Continue;
      end;
      if Pos('Changes to be committed:', L) > 0 then begin Mode := 1; Continue; end;
      if (Pos('Changes not staged for commit:', L) > 0) or
         (Pos('Unmerged paths:', L) > 0) then begin Mode := 2; Continue; end;
      if Pos('Untracked files:', L) > 0 then begin Mode := 3; Continue; end;
      if Pos('nothing to commit', L) > 0 then
      begin
        Out_ := TStringList.Create;
        try
          if Branch <> '' then
            Out_.Add('branch: ' + Branch);
          Out_.Add('clean');
          Result := JoinLines(Out_.ToStringArray);
        finally
          Out_.Free;
        end;
        Exit;
      end;
      if (Length(Trim(L)) = 0) then Continue;
      if (Pos('  (', L) = 1) or (Pos('(use ', L) > 0) then Continue;
      { File lines in `git status` start with whitespace; the
        no-color porcelain uses 'M ', 'A ', '?? ', 'D ', etc.
        Either shape: count + keep the path. }
      S := Trim(L);
      case Mode of
        1: begin
             Inc(Counts[gStaged]);
             if Samples[gStaged].Count < TOP_K then Samples[gStaged].Add(S);
             GotAny := True;
           end;
        2: begin
             Inc(Counts[gUnstaged]);
             if Samples[gUnstaged].Count < TOP_K then Samples[gUnstaged].Add(S);
             GotAny := True;
           end;
        3: begin
             Inc(Counts[gUntracked]);
             if Samples[gUntracked].Count < TOP_K then Samples[gUntracked].Add(S);
             GotAny := True;
           end;
      end;
    end;

    if not GotAny then
    begin
      { Couldn't classify -- pass through. }
      Result := Raw;
      Exit;
    end;

    Out_ := TStringList.Create;
    try
      if Branch <> '' then Out_.Add('branch: ' + Branch);
      for Group := gStaged to gUntracked do
      begin
        if Counts[Group] = 0 then Continue;
        case Group of
          gStaged:    Out_.Add(Format('staged: %d', [Counts[Group]]));
          gUnstaged:  Out_.Add(Format('unstaged: %d', [Counts[Group]]));
          gUntracked: Out_.Add(Format('untracked: %d', [Counts[Group]]));
        end;
        for i := 0 to Samples[Group].Count - 1 do
          Out_.Add('  ' + Samples[Group][i]);
        if Counts[Group] > Samples[Group].Count then
          Out_.Add(Format('  ... and %d more',
                          [Counts[Group] - Samples[Group].Count]));
      end;
      Result := JoinLines(Out_.ToStringArray);
    finally
      Out_.Free;
    end;
  finally
    for Group := gStaged to gUntracked do
      Samples[Group].Free;
  end;
end;

function FilterGitDiff(const Raw: string): string;
{ `git diff` (or git diff --stat-ish behaviour). For small diffs we
  pass through unchanged -- the model needs the line-level detail.
  For large ones, walk hunks counting added/removed lines per file
  and emit a one-line-per-file summary. }
const
  PASSTHROUGH_LINES = 60;   { keep small diffs verbatim }
var
  Lines: TArray<string>;
  i: Integer;
  L, CurFile: string;
  Added, Removed: Integer;
  FileList: TStringList;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  if Length(Lines) <= PASSTHROUGH_LINES then
  begin
    Result := Raw;
    Exit;
  end;

  CurFile := '';
  Added   := 0;
  Removed := 0;
  FileList := TStringList.Create;
  try
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      if (Pos('diff --git ', L) = 1) then
      begin
        if CurFile <> '' then
          FileList.Add(Format('%s  +%d -%d', [CurFile, Added, Removed]));
        CurFile := Trim(Copy(L, Length('diff --git a/') + 1,
                              Pos(' b/', L) - Length('diff --git a/')));
        Added   := 0;
        Removed := 0;
      end
      else if (Length(L) > 0) and (L[1] = '+') and (Pos('+++', L) <> 1) then
        Inc(Added)
      else if (Length(L) > 0) and (L[1] = '-') and (Pos('---', L) <> 1) then
        Inc(Removed);
    end;
    if CurFile <> '' then
      FileList.Add(Format('%s  +%d -%d', [CurFile, Added, Removed]));

    Out_ := TStringList.Create;
    try
      Out_.Add(Format('diff summary: %d file(s) changed', [FileList.Count]));
      for i := 0 to FileList.Count - 1 do
        Out_.Add('  ' + FileList[i]);
      Out_.Add('(full diff elided; re-run with --stat or pipe to head for detail)');
      Result := JoinLines(Out_.ToStringArray);
    finally
      Out_.Free;
    end;
  finally
    FileList.Free;
  end;
end;

function FilterGitLog(const Raw: string): string;
{ `git log`. Default output is multi-line per commit. We keep the
  newest TOP_K commits' subject lines and report the total. }
const
  TOP_K = 20;
var
  Lines: TArray<string>;
  i: Integer;
  L: string;
  Subjects: TStringList;
  Total: Integer;
  Out_: TStringList;
  InMessageBody: Boolean;
begin
  Lines := SplitLines(Raw);
  Subjects := TStringList.Create;
  try
    Total := 0;
    InMessageBody := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      if Pos('commit ', L) = 1 then
      begin
        Inc(Total);
        InMessageBody := False;
        if Subjects.Count < TOP_K then
          Subjects.Add(Copy(L, Length('commit '), 8));  { short hash }
        Continue;
      end;
      if (not InMessageBody) and (Length(Trim(L)) = 0) then
      begin
        InMessageBody := True;
        Continue;
      end;
      if InMessageBody and (Subjects.Count > 0) and
         (Length(Trim(L)) > 0) and
         (Pos(' ', Trim(L)) <> 0) then
      begin
        { First non-blank line after the blank separator is the
          commit subject. Append to the most recent hash. }
        if Subjects.Count <= TOP_K then
        begin
          Subjects[Subjects.Count - 1] :=
            Subjects[Subjects.Count - 1] + '  ' + Trim(L);
          InMessageBody := False;
        end;
      end;
    end;

    if Total = 0 then
    begin
      Result := Raw;
      Exit;
    end;

    Out_ := TStringList.Create;
    try
      Out_.Add(Format('%d commit(s); newest %d:',
                      [Total, Subjects.Count]));
      for i := 0 to Subjects.Count - 1 do
        Out_.Add('  ' + Subjects[i]);
      if Total > Subjects.Count then
        Out_.Add(Format('(+ %d older commits elided)',
                        [Total - Subjects.Count]));
      Result := JoinLines(Out_.ToStringArray);
    finally
      Out_.Free;
    end;
  finally
    Subjects.Free;
  end;
end;

function FilterTestRunner(const Raw: string): string;
{ npm test / pytest / cargo test / yarn test / pnpm test all share a
  shape: a long stream of PASS/ok/passed lines plus a small number
  of FAIL/error/failed entries that matter. Collapse passes to a
  count, surface failures verbatim. }
var
  Lines: TArray<string>;
  i: Integer;
  L, LL: string;
  Pass, Fail, Skip: Integer;
  Failures: TStringList;
  Out_: TStringList;
  InFailure: Boolean;
  CurFailure: string;
begin
  Lines := SplitLines(Raw);
  Pass := 0;
  Fail := 0;
  Skip := 0;
  Failures := TStringList.Create;
  try
    InFailure := False;
    CurFailure := '';
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      LL := LowerCase(Trim(L));

      { Per-test PASS lines. Common shapes:
          pytest:    "test_foo.py::test_bar PASSED"
          cargo:     "test result: ok. N passed; M failed; ..."  (one line summary)
          jest/npm:  "PASS  src/foo.test.js" and "✓ should do thing"
          mocha:     "  ✓ should do thing"  }
      if (Pos('passed', LL) > 0) and
         ((Pos('test_', LL) > 0) or (Pos('::test', LL) > 0) or
          (Pos('  ✓', L) = 1)    or (Pos('ok ', LL) = 1)) then
      begin
        Inc(Pass);
        InFailure := False;
        Continue;
      end;
      if (Pos(' ok', LL) > 0) and (Pos('test', LL) > 0) and
         (Pos('failed', LL) = 0) then
      begin
        Inc(Pass);
        InFailure := False;
        Continue;
      end;
      if (Pos('skipped', LL) > 0) or (Pos('s ', LL) = 1) then
      begin
        Inc(Skip);
        InFailure := False;
        Continue;
      end;

      { Failure markers. }
      if (Pos('failed', LL) > 0) or (Pos('fail:', LL) > 0) or
         (Pos('error:', LL) > 0) or (Pos('  ✗', L) = 1) or
         (Pos('FAIL ', L) = 1)   or (Pos('FAILED', L) > 0) then
      begin
        if (CurFailure <> '') and (Failures.Count < 10) then
          Failures.Add(CurFailure);
        CurFailure := L;
        InFailure := True;
        Inc(Fail);
        Continue;
      end;

      { Carry failure context (next ~10 lines after a fail marker)
        until we hit a blank or another marker. }
      if InFailure and (Length(Trim(L)) > 0) and (Failures.Count < 10) then
        CurFailure := CurFailure + sLineBreak + L
      else if InFailure then
        InFailure := False;
    end;
    if (CurFailure <> '') and (Failures.Count < 10) then
      Failures.Add(CurFailure);

    if (Pass = 0) and (Fail = 0) and (Skip = 0) then
    begin
      { Didn't recognise a test runner output -- pass through. }
      Result := Raw;
      Exit;
    end;

    Out_ := TStringList.Create;
    try
      Out_.Add(Format('test results: %d passed, %d failed, %d skipped',
                      [Pass, Fail, Skip]));
      if Failures.Count > 0 then
      begin
        Out_.Add('');
        Out_.Add('failures:');
        for i := 0 to Failures.Count - 1 do
        begin
          Out_.Add('---');
          Out_.Add(Failures[i]);
        end;
        if Fail > Failures.Count then
          Out_.Add(Format('(+ %d more failures elided)',
                          [Fail - Failures.Count]));
      end;
      Result := JoinLines(Out_.ToStringArray);
    finally
      Out_.Free;
    end;
  finally
    Failures.Free;
  end;
end;

function FilterGrep(const Raw: string): string;
{ grep -r / findstr / Select-String all emit one match per line in
  "<file>:<line>:<text>" shape (findstr uses ':' too). Aggregate
  by file: counts + first N matches per file. }
const
  PER_FILE_TOP_K = 3;
  FILE_TOP_K     = 20;
var
  Lines: TArray<string>;
  i, ColonPos: Integer;
  L, File_: string;
  Files: TStringList;
  Counts: TStringList;
  Samples: array of TStringList;
  Idx: Integer;
  Out_: TStringList;
  Total: Integer;
begin
  Lines := SplitLines(Raw);
  Files := TStringList.Create;
  Counts := TStringList.Create;
  try
    Total := 0;
    SetLength(Samples, 0);
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      if Length(Trim(L)) = 0 then Continue;
      ColonPos := Pos(':', L);
      if ColonPos <= 0 then Continue;
      File_ := Copy(L, 1, ColonPos - 1);
      Idx := Files.IndexOf(File_);
      if Idx < 0 then
      begin
        Files.Add(File_);
        Counts.Add('1');
        SetLength(Samples, Length(Samples) + 1);
        Samples[High(Samples)] := TStringList.Create;
        Samples[High(Samples)].Add(L);
        Idx := Files.Count - 1;
      end
      else
      begin
        Counts[Idx] := IntToStr(StrToIntDef(Counts[Idx], 0) + 1);
        if Samples[Idx].Count < PER_FILE_TOP_K then
          Samples[Idx].Add(L);
      end;
      Inc(Total);
    end;

    if Files.Count = 0 then
    begin
      Result := Raw;
      Exit;
    end;

    Out_ := TStringList.Create;
    try
      Out_.Add(Format('%d match(es) in %d file(s)', [Total, Files.Count]));
      for i := 0 to Files.Count - 1 do
      begin
        if i >= FILE_TOP_K then Break;
        Out_.Add(Format('  %s  (%s matches)', [Files[i], Counts[i]]));
        for Idx := 0 to Samples[i].Count - 1 do
          Out_.Add('    ' + Samples[i][Idx]);
      end;
      if Files.Count > FILE_TOP_K then
        Out_.Add(Format('(+ %d more files elided)',
                        [Files.Count - FILE_TOP_K]));
      Result := JoinLines(Out_.ToStringArray);
    finally
      Out_.Free;
    end;
  finally
    for i := 0 to High(Samples) do Samples[i].Free;
    Files.Free;
    Counts.Free;
  end;
end;

function FilterLs(const Raw: string): string;
{ Recursive directory listings: `ls -R`, `find`, `dir /s`,
  `Get-ChildItem -Recurse`. All produce a long file/dir list.
  Cap at FILE_TOP_K entries, summary "(+N more)". }
const
  FILE_TOP_K = 40;
var
  Lines: TArray<string>;
  i, Kept: Integer;
  L: string;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  if Length(Lines) <= FILE_TOP_K then
  begin
    Result := Raw;
    Exit;
  end;
  Out_ := TStringList.Create;
  try
    Kept := 0;
    for i := 0 to High(Lines) do
    begin
      if Kept >= FILE_TOP_K then Break;
      L := Lines[i];
      if Length(Trim(L)) = 0 then Continue;
      Out_.Add(L);
      Inc(Kept);
    end;
    Out_.Add(Format('(+ %d more lines elided -- narrow the path or use a glob)',
                    [Length(Lines) - Kept]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterTabular(const Raw: string): string;
{ Header-plus-rows tables: `docker ps`, `docker images`, `kubectl get`,
  `gh pr list`, `gh run list`. Keep the header row + the first
  MAX_ROWS data rows; everything after collapses to a count. Small
  tables pass through untouched. }
const
  MAX_ROWS = 20;
var
  Lines: TArray<string>;
  i, Kept: Integer;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  if Length(Lines) <= MAX_ROWS + 1 then
  begin
    Result := Raw;
    Exit;
  end;
  Out_ := TStringList.Create;
  try
    Kept := 0;
    for i := 0 to High(Lines) do
    begin
      if Kept > MAX_ROWS then Break;   { header + MAX_ROWS rows }
      if (i > 0) and (Length(Trim(Lines[i])) = 0) then Continue;
      Out_.Add(Lines[i]);
      Inc(Kept);
    end;
    Out_.Add(Format('(+ %d more rows elided -- add a filter/--limit to narrow)',
                    [Length(Lines) - Kept]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterHeadTail(const Raw: string): string;
{ Log-shaped output where the TAIL matters most (`docker logs`,
  `kubectl logs`, `kubectl describe`, `tsc` listings): keep the first
  HEAD_K lines for orientation and the last TAIL_K where the recent
  events / final summary live. }
const
  MAX_PASSTHROUGH = 80;
  HEAD_K          = 15;
  TAIL_K          = 25;
var
  Lines: TArray<string>;
  i: Integer;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  if Length(Lines) <= MAX_PASSTHROUGH then
  begin
    Result := Raw;
    Exit;
  end;
  Out_ := TStringList.Create;
  try
    for i := 0 to HEAD_K - 1 do Out_.Add(Lines[i]);
    Out_.Add(Format('(... %d lines elided ...)',
                    [Length(Lines) - HEAD_K - TAIL_K]));
    for i := Length(Lines) - TAIL_K to High(Lines) do Out_.Add(Lines[i]);
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterDockerBuild(const Raw: string): string;
{ `docker build`. Classic builder emits "Step X/Y : ..." + layer noise;
  BuildKit emits "#N [stage a/b] ..." + per-layer progress. Keep the
  step/stage marker lines, warnings/errors, and the closing image
  lines; collapse everything else to a count. }
var
  Lines: TArray<string>;
  i, Dropped: Integer;
  L, LL: string;
  Out_: TStringList;
  GotMarker: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    Dropped := 0;
    GotMarker := False;
    for i := 0 to High(Lines) do
    begin
      L  := Lines[i];
      LL := LowerCase(L);
      if (Pos('Step ', L) = 1) or
         ((Length(L) > 1) and (L[1] = '#') and CharInSet(L[2], ['0'..'9'])) then
      begin
        { BuildKit repeats "#N ..." for every progress tick; keep only
          stage-define / finish lines, not the byte-counter spam. }
        if (Pos('Step ', L) = 1) or (Pos(' [', L) > 0) or
           (Pos('DONE', L) > 0) or (Pos('ERROR', L) > 0) or
           (Pos('CACHED', L) > 0) then
        begin
          Out_.Add(L);
          GotMarker := True;
        end
        else
          Inc(Dropped);
        Continue;
      end;
      if (Pos('warning', LL) > 0) or (Pos('error', LL) > 0) or
         (Pos('successfully built', LL) > 0) or
         (Pos('successfully tagged', LL) > 0) or
         (Pos('writing image', LL) > 0) or (Pos('naming to', LL) > 0) then
      begin
        Out_.Add(L);
        GotMarker := True;
        Continue;
      end;
      if Length(Trim(L)) > 0 then Inc(Dropped);
    end;
    if (not GotMarker) or (Dropped = 0) then
    begin
      Result := Raw;   { not docker-build shaped, or nothing to save }
      Exit;
    end;
    Out_.Add(Format('(%d layer/progress lines elided)', [Dropped]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterCargoCompile(const Raw: string): string;
{ `cargo build` / `cargo check` / `cargo clippy`. Success output is a
  wall of "Compiling crate vX.Y.Z" lines; what matters is warnings
  (clippy exits 0 with warnings!) and the Finished line. Keep the
  first MAX_WARN_BLOCKS warning blocks verbatim and surface a count
  of any that exceeded the cap so the model knows more diagnostics
  exist beyond what's printed -- silently dropping them would let
  warnings hide past the visible window (Codex P2 on PR #230).
  Compile/fetch noise collapses to a single count. }
const
  MAX_WARN_BLOCKS = 10;
var
  Lines: TArray<string>;
  i, Compiled, WarnBlocks: Integer;
  L, T: string;
  Out_: TStringList;
  InWarn: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    Compiled := 0;
    WarnBlocks := 0;
    InWarn := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if (Pos('Compiling ', T) = 1) or (Pos('Checking ', T) = 1) or
         (Pos('Fresh ', T) = 1)     or (Pos('Downloading ', T) = 1) or
         (Pos('Downloaded ', T) = 1) or (Pos('Updating ', T) = 1) or
         (Pos('Adding ', T) = 1)     or (Pos('Locking ', T) = 1) then
      begin
        Inc(Compiled);
        InWarn := False;
        Continue;
      end;
      if (Pos('warning', T) = 1) or (Pos('error', T) = 1) then
      begin
        { Count EVERY diagnostic header even when over the cap so we
          can tell the model how many extra ones got elided. Print only
          the first MAX_WARN_BLOCKS bodies. }
        Inc(WarnBlocks);
        InWarn := WarnBlocks <= MAX_WARN_BLOCKS;
        if InWarn then Out_.Add(L);
        Continue;
      end;
      if Pos('Finished ', T) = 1 then
      begin
        InWarn := False;
        Out_.Add(L);
        Continue;
      end;
      { Warning bodies are indented context lines ("  --> src/x.rs:1",
        "   |", note/help). Carry them while in a kept block. }
      if InWarn and (Length(T) > 0) then
        Out_.Add(L)
      else if Length(T) = 0 then
        InWarn := False;
    end;
    if Compiled = 0 then
    begin
      Result := Raw;
      Exit;
    end;
    if WarnBlocks > MAX_WARN_BLOCKS then
      Out_.Add(Format('(+ %d more warning/error block(s) elided -- ' +
                      're-run with --message-format=json or scope the ' +
                      'crate to see them)',
                      [WarnBlocks - MAX_WARN_BLOCKS]));
    Out_.Insert(0, Format('(%d compile/fetch lines elided)', [Compiled]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterGoTest(const Raw: string): string;
{ `go test ./...`. Passing packages each emit "ok  pkg  0.12s" (plus
  optional "=== RUN" / "--- PASS" verbosity). Collapse passes to a
  count; FAIL lines and their blocks stay verbatim (a failing suite
  usually exits non-zero and bypasses filters entirely via
  tee-on-failure, but `go test` keeps exit 0 for some flag combos). }
var
  Lines: TArray<string>;
  i, OkCount, RunCount: Integer;
  L, T: string;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    OkCount := 0;
    RunCount := 0;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if (Pos('ok ', T) = 1) or (Pos('ok'#9, T) = 1) then
      begin
        Inc(OkCount);
        Continue;
      end;
      if (Pos('=== RUN', T) = 1) or (Pos('--- PASS', T) = 1) or
         (T = 'PASS') then
      begin
        Inc(RunCount);
        Continue;
      end;
      if Length(T) > 0 then Out_.Add(L);
    end;
    if OkCount = 0 then
    begin
      Result := Raw;
      Exit;
    end;
    Out_.Insert(0, Format('go test: %d package(s) ok (%d per-test lines elided)',
                          [OkCount, RunCount]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterEslint(const Raw: string): string;
{ eslint's stylish reporter: a path line, then "  L:C  warning|error
  message  rule-id" lines, then a "✖ N problems" summary. Warnings
  exit 0, so a lint-y repo floods the context. Aggregate per file:
  counts + first PER_FILE_K problem lines, keep the summary. }
const
  PER_FILE_K = 3;
  FILE_TOP_K = 20;
var
  Lines: TArray<string>;
  i, FileCount, Problems, Shown: Integer;
  L, T: string;
  Out_: TStringList;
  PerFileShown: Integer;
  IsProblemLine: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    FileCount := 0;
    Problems := 0;
    Shown := 0;
    PerFileShown := 0;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if Length(T) = 0 then Continue;
      { Problem lines are indented and lead with "line:col". }
      IsProblemLine := (Length(L) > 2) and (L[1] = ' ') and
                       (Pos(':', T) > 1) and
                       CharInSet(T[1], ['0'..'9']) and
                       ((Pos(' warning ', T) > 0) or (Pos(' error ', T) > 0));
      if IsProblemLine then
      begin
        Inc(Problems);
        if (PerFileShown < PER_FILE_K) and (FileCount <= FILE_TOP_K) then
        begin
          Out_.Add(L);
          Inc(PerFileShown);
          Inc(Shown);
        end;
        Continue;
      end;
      { Summary line ("✖ 12 problems (2 errors, 10 warnings)"). }
      if (Pos('problem', T) > 0) and
         ((Pos('error', T) > 0) or (Pos('warning', T) > 0)) then
      begin
        Out_.Add(L);
        Continue;
      end;
      { Anything else non-indented is a file path header. }
      if L[1] <> ' ' then
      begin
        Inc(FileCount);
        PerFileShown := 0;
        if FileCount <= FILE_TOP_K then Out_.Add(L);
        Continue;
      end;
    end;
    if Problems = 0 then
    begin
      Result := Raw;
      Exit;
    end;
    if Problems > Shown then
      Out_.Add(Format('(+ %d more problem lines elided)', [Problems - Shown]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterNpmInstall(const Raw: string): string;
{ `npm install` / `npm ci` / pnpm / yarn equivalents. Keep the lines
  an operator actually reads -- "added N packages", deprecation
  warnings (capped), the audit summary -- and drop progress noise. }
const
  MAX_WARNS = 5;
var
  Lines: TArray<string>;
  i, Dropped, Warns: Integer;
  L, LL: string;
  Out_: TStringList;
  GotSummary: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    Dropped := 0;
    Warns := 0;
    GotSummary := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      LL := LowerCase(Trim(L));
      if Length(LL) = 0 then Continue;
      if ((Pos('added', LL) > 0) and (Pos('package', LL) > 0)) or
         (Pos('removed', LL) = 1) or (Pos('changed', LL) = 1) or
         (Pos('up to date', LL) > 0) or (Pos('audited', LL) > 0) or
         (Pos('vulnerabilit', LL) > 0) or
         (Pos('done in', LL) = 1) {yarn/pnpm} then
      begin
        Out_.Add(L);
        GotSummary := True;
        Continue;
      end;
      if (Pos('npm warn', LL) = 1) or (Pos('warning', LL) = 1) then
      begin
        Inc(Warns);
        if Warns <= MAX_WARNS then Out_.Add(L) else Inc(Dropped);
        Continue;
      end;
      Inc(Dropped);
    end;
    if not GotSummary then
    begin
      Result := Raw;
      Exit;
    end;
    if Warns > MAX_WARNS then
      Out_.Add(Format('(+ %d more warnings elided)', [Warns - MAX_WARNS]));
    if Dropped > 0 then
      Out_.Add(Format('(%d progress lines elided)', [Dropped]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterPipInstall(const Raw: string): string;
{ `pip install`. Collapse Collecting / Downloading / Requirement
  already satisfied / Using cached noise into counts; keep the
  "Successfully installed ..." line and any warnings/errors. }
var
  Lines: TArray<string>;
  i, Collected, Satisfied: Integer;
  L, T: string;
  Out_: TStringList;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    Collected := 0;
    Satisfied := 0;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if Length(T) = 0 then Continue;
      if (Pos('Collecting ', T) = 1) or (Pos('Downloading ', T) = 1) or
         (Pos('Using cached ', T) = 1) or (Pos('Preparing ', T) = 1) or
         (Pos('Building wheel', T) = 1) or (Pos('Created wheel', T) = 1) or
         (Pos('Stored in directory', T) = 1) or
         (Pos('Attempting uninstall', T) = 1) or
         (Pos('Found existing installation', T) = 1) or
         (Pos('Uninstalling ', T) = 1) then
      begin
        Inc(Collected);
        Continue;
      end;
      if Pos('Requirement already satisfied', T) = 1 then
      begin
        Inc(Satisfied);
        Continue;
      end;
      Out_.Add(L);
    end;
    if Collected + Satisfied = 0 then
    begin
      Result := Raw;
      Exit;
    end;
    Out_.Insert(0, Format('pip: %d fetch/build lines + %d already-satisfied elided',
                          [Collected, Satisfied]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterMaven(const Raw: string): string;
{ mvn anything. Maven prefixes every line with [INFO] / [WARNING] /
  [ERROR]; the [INFO] stream is overwhelmingly noise. Keep warnings
  and errors (capped), the BUILD SUCCESS/FAILURE block, reactor
  summary rows, and Total time. }
const
  MAX_WARNS = 10;
var
  Lines: TArray<string>;
  i, InfoDropped, Warns: Integer;
  L: string;
  Out_: TStringList;
  InReactor: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    InfoDropped := 0;
    Warns := 0;
    InReactor := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      if (Pos('[WARNING]', L) > 0) or (Pos('[ERROR]', L) > 0) then
      begin
        Inc(Warns);
        if Warns <= MAX_WARNS then Out_.Add(L);
        Continue;
      end;
      if Pos('Reactor Summary', L) > 0 then InReactor := True;
      if (Pos('BUILD SUCCESS', L) > 0) or (Pos('BUILD FAILURE', L) > 0) or
         (Pos('Total time', L) > 0) or (Pos('Reactor Summary', L) > 0) or
         (InReactor and (Pos('SUCCESS [', L) > 0)) or
         (InReactor and (Pos('FAILURE [', L) > 0)) then
      begin
        Out_.Add(L);
        Continue;
      end;
      if Pos('[INFO]', L) > 0 then
      begin
        Inc(InfoDropped);
        Continue;
      end;
    end;
    if InfoDropped = 0 then
    begin
      Result := Raw;
      Exit;
    end;
    if Warns > MAX_WARNS then
      Out_.Add(Format('(+ %d more warnings/errors elided)', [Warns - MAX_WARNS]));
    Out_.Insert(0, Format('(%d [INFO] lines elided)', [InfoDropped]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterGradle(const Raw: string): string;
{ gradle / ./gradlew. Keep "> Task" lines only when they carry a
  non-default outcome (FAILED / SKIPPED), warnings, and the BUILD
  SUCCESSFUL / actionable-tasks summary; count the rest. }
var
  Lines: TArray<string>;
  i, TaskDropped: Integer;
  L, T: string;
  Out_: TStringList;
  GotSummary: Boolean;
begin
  Lines := SplitLines(Raw);
  Out_ := TStringList.Create;
  try
    TaskDropped := 0;
    GotSummary := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if Length(T) = 0 then Continue;
      if Pos('> Task ', T) = 1 then
      begin
        if (Pos('FAILED', T) > 0) or (Pos('SKIPPED', T) > 0) then
          Out_.Add(L)
        else
          Inc(TaskDropped);
        Continue;
      end;
      if (Pos('BUILD SUCCESSFUL', T) > 0) or (Pos('BUILD FAILED', T) > 0) or
         (Pos('actionable task', T) > 0) then
      begin
        Out_.Add(L);
        GotSummary := True;
        Continue;
      end;
      if (Pos('warning', LowerCase(T)) > 0) or (Pos('deprecat', LowerCase(T)) > 0) then
      begin
        Out_.Add(L);
        Continue;
      end;
      Inc(TaskDropped);
    end;
    if not GotSummary then
    begin
      Result := Raw;
      Exit;
    end;
    if TaskDropped > 0 then
      Out_.Add(Format('(%d task/output lines elided)', [TaskDropped]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterTerraformPlan(const Raw: string): string;
{ `terraform plan` / `apply`. The attribute-level diff inside each
  resource block dwarfs the decision-relevant content: which
  resources change and the Plan: summary. Keep resource headers +
  summaries, drop attribute lines, only when output is long. }
const
  MAX_PASSTHROUGH = 60;
var
  Lines: TArray<string>;
  i, Dropped: Integer;
  L, T: string;
  Out_: TStringList;
  GotPlanLine: Boolean;
begin
  Lines := SplitLines(Raw);
  if Length(Lines) <= MAX_PASSTHROUGH then
  begin
    Result := Raw;
    Exit;
  end;
  Out_ := TStringList.Create;
  try
    Dropped := 0;
    GotPlanLine := False;
    for i := 0 to High(Lines) do
    begin
      L := Lines[i];
      T := Trim(L);
      if Length(T) = 0 then Continue;
      if (Pos('# ', T) = 1) or                       { "# aws_x.y will be created" }
         (Pos('Plan:', T) = 1) or
         (Pos('No changes', T) = 1) or
         (Pos('Apply complete', T) = 1) or
         (Pos('Terraform will perform', T) > 0) or
         (Pos('Terraform used', T) = 1) or
         (Pos('resource "', T) > 0) then
      begin
        Out_.Add(L);
        if (Pos('Plan:', T) = 1) or (Pos('No changes', T) = 1) or
           (Pos('Apply complete', T) = 1) then
          GotPlanLine := True;
        Continue;
      end;
      Inc(Dropped);
    end;
    if not GotPlanLine then
    begin
      Result := Raw;   { not plan-shaped after all }
      Exit;
    end;
    Out_.Add(Format('(%d attribute/diff lines elided -- the resource list above is complete)',
                    [Dropped]));
    Result := JoinLines(Out_.ToStringArray);
  finally
    Out_.Free;
  end;
end;

function FilterAws(const Raw: string): string;
{ aws CLI defaults to JSON output -- route it through the JSON-aware
  condenser (same engine the tool loop uses for MCP bodies, but with
  the shell filter's accounting). Non-JSON aws output (e.g. `aws s3
  ls`) gets the head/tail treatment when long. }
var
  T: string;
begin
  T := Trim(Raw);
  if (Length(T) > 0) and ((T[1] = '{') or (T[1] = '[')) then
    Result := MaybeCondenseJSON(Raw)
  else
    Result := FilterHeadTail(Raw);
end;

{ =================== dispatcher =================== }

function ApplyShellFilter(const Cmd, RawOut: string;
                          ExitCode: Integer): string;
var
  Key: string;
  OrigLen: Integer;
begin
  Result := RawOut;
  { Tee-on-failure: never filter a failure. The model needs the
    full stack / error output to debug. }
  if ExitCode <> 0 then Exit;
  if Trim(RawOut) = '' then Exit;

  Key := CanonicalizeShellCommand(Cmd);
  if Key = '' then Exit;

  OrigLen := Length(RawOut);

  if Key = 'git status' then       Result := FilterGitStatus(RawOut)
  else if Key = 'git diff' then    Result := FilterGitDiff(RawOut)
  else if Key = 'git log' then     Result := FilterGitLog(RawOut)
  else if (Key = 'npm test')   or (Key = 'pnpm test') or
          (Key = 'yarn test')  or (Key = 'cargo test') or
          (Key = 'pytest')     then
    Result := FilterTestRunner(RawOut)
  else if Key = 'grep' then        Result := FilterGrep(RawOut)
  else if Key = 'ls' then          Result := FilterLs(RawOut)
  else if Key = 'find' then        Result := FilterLs(RawOut)

  { --- rtk-inspired expansion: containers / k8s / gh / linters /
        compilers / package managers / IaC / cloud CLIs --- }
  else if (Key = 'docker ps')     or (Key = 'docker images') or
          (Key = 'docker image')  or (Key = 'docker container') or
          (Key = 'kubectl get')   or
          (Key = 'gh pr')         or (Key = 'gh run') or
          (Key = 'gh issue')      or (Key = 'gh release') then
    Result := FilterTabular(RawOut)
  else if Key = 'docker build' then
    Result := FilterDockerBuild(RawOut)
  else if (Key = 'docker logs')      or (Key = 'kubectl logs') or
          (Key = 'kubectl describe') or (Key = 'kubectl events') or
          (Key = 'tsc') then
    Result := FilterHeadTail(RawOut)
  else if (Key = 'cargo build') or (Key = 'cargo check') or
          (Key = 'cargo clippy') then
    Result := FilterCargoCompile(RawOut)
  else if Key = 'go test' then
    Result := FilterGoTest(RawOut)
  else if Key = 'eslint' then
    Result := FilterEslint(RawOut)
  else if (Key = 'npm install')  or (Key = 'npm ci') or
          (Key = 'pnpm install') or (Key = 'yarn install') or
          (Key = 'yarn add')     or (Key = 'pnpm add') then
    Result := FilterNpmInstall(RawOut)
  else if Key = 'pip install' then
    Result := FilterPipInstall(RawOut)
  else if Pos('mvn ', Key) = 1 then
    Result := FilterMaven(RawOut)
  else if (Key = 'gradle') or (Pos('gradle ', Key) = 1) then
    Result := FilterGradle(RawOut)
  else if (Key = 'terraform plan') or (Key = 'terraform apply') then
    Result := FilterTerraformPlan(RawOut)
  else if Key = 'aws' then
    Result := FilterAws(RawOut);

  if Length(Result) < OrigLen then
  begin
    Inc(GCalls);
    Inc(GBytesSaved, OrigLen - Length(Result));
  end;
end;

initialization
  GCalls      := 0;
  GBytesSaved := 0;

end.
