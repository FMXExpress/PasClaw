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
  Classes, StrUtils;

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
    First := 'grep';

  { Two-word commands have a meaningful subcommand the filter
    dispatcher cares about (git status vs git diff vs git log). }
  if (First = 'git') or (First = 'npm')   or (First = 'pnpm') or
     (First = 'yarn') or (First = 'cargo') or (First = 'mvn') then
  begin
    if Idx + 1 < Length(Tokens) then
      Second := LowerCase(Tokens[Idx + 1])
    else
      Second := '';
    Result := First + ' ' + Second;
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
  else if Key = 'find' then        Result := FilterLs(RawOut);

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
