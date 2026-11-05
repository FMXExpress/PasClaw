(*
  PasClaw.Cmd.Learn -- `pasclaw learn`: mine session transcripts for
  recurring tool failures so the operator can promote them into
  MEMORY.md or SCARS.md as durable hints. The mining itself lives in
  PasClaw.Learn, which the nightly `pasclaw maintain` also runs.

  Borrowed from Headroom's `headroom learn` (chopratejas/headroom):
  the model often makes the same mistake across many sessions
  (calls `npm test` in a pnpm repo; tries fs_write to a read-only
  path; reaches for `make build` when the Makefile has no `build`
  target). Each failure is recoverable in-loop, but the PATTERN
  only becomes visible when you look across sessions.

  Two pieces:

    1. Mining (PasClaw.Learn): walk $PASCLAW_HOME/workspace/sessions/
       *.json, scan every mrTool message for failure-shaped content
       (an 'ERROR:' prefix, a non-zero shell exit, common failure
       phrases like `command not found` / `permission denied`) and
       for a tool's own note that it was misused.
       Normalise each candidate line into a cluster signature --
       strip variable bits (pids, line numbers, temp paths) that
       would otherwise split otherwise-identical failures into a
       long tail of one-offs. Aggregate by signature with counts,
       distinct sessions, and a sample.

    2. Reporting + (opt-in) write-back. Default `pasclaw learn`
       prints a Markdown report sorted by frequency. `--write`
       appends a structured `### Patterns observed (YYYY-MM-DD)`
       block to workspace/memory/MEMORY.md so the next agent
       loop picks it up via the system prompt. `--since <days>`
       limits the window so old sessions don't keep resurfacing
       the same fix the operator has already applied.

  Out of scope for this PR: LLM-generated explanations of each
  pattern. Headroom does that; PasClaw's first cut leaves the
  diagnosis to the operator (they know their project better than
  the model does on a cold read of someone else's session JSON).
*)
unit PasClaw.Cmd.Learn;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Learn_Run(const Argv: array of string): Integer;

implementation

uses
  Classes, SysUtils, DateUtils,
  PasClaw.Workspaces,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Learn;

type
  TLearnArgs = record
    SinceDays:   Integer;     { 0 = no window }
    Write_:      Boolean;     { --write -> append to MEMORY.md }
    WriteScars:  Boolean;     { --write-scars -> emit / refresh
                                workspace/memory/SCARS.md (stable
                                §ANCHOR-NAME ids citable from
                                commits/PRs, format borrowed from
                                Abbasi-Alain/atlas). }
    MinSessions: Integer;     { drop patterns with fewer DISTINCT
                                sessions; default 2. Codex P2 #1 on
                                PR #190: was MinCount over total
                                occurrences, which let one noisy
                                session that repeated a single
                                failure twice slip past the
                                "recurring across sessions" gate. }
    Verbose:     Boolean;
  end;

procedure PrintHelp;
begin
  PrintLn('Usage: pasclaw learn [options]');
  PrintLn('  Mine session transcripts for recurring tool failures.');
  PrintLn('');
  PrintLn('Options:');
  PrintLn('  --since <days>           Only consider sessions newer than N days (default: all)');
  PrintLn('  --min-sessions <count>   Drop patterns seen in fewer distinct sessions (default: 2)');
  PrintLn('  --write                  Append a Patterns block to workspace/memory/MEMORY.md');
  PrintLn('  --write-scars            Emit / refresh workspace/memory/SCARS.md (stable §ANCHOR ids');
  PrintLn('                           per pattern, citable from commits + PRs via `git log --grep "§"`)');
  PrintLn('  --verbose                Print scan progress per session');
end;

function ParseArgs(const Argv: array of string; out A: TLearnArgs): Boolean;
var
  i: Integer;
begin
  A.SinceDays   := 0;
  A.Write_      := False;
  A.WriteScars  := False;
  A.MinSessions := 2;
  A.Verbose     := False;
  Result := True;
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '--since') and (i < High(Argv)) then
    begin
      A.SinceDays := StrToIntDef(Argv[i + 1], 0);
      Inc(i, 2);
      Continue;
    end;
    if ((Argv[i] = '--min-sessions') or (Argv[i] = '--min'))
       and (i < High(Argv)) then
    begin
      { --min kept as a deprecated alias of --min-sessions to soften
        the rename. Help text only advertises --min-sessions. }
      A.MinSessions := StrToIntDef(Argv[i + 1], 2);
      if A.MinSessions < 1 then A.MinSessions := 1;
      Inc(i, 2);
      Continue;
    end;
    if Argv[i] = '--write'       then begin A.Write_     := True; Inc(i); Continue; end;
    if Argv[i] = '--write-scars' then begin A.WriteScars := True; Inc(i); Continue; end;
    if Argv[i] = '--verbose'     then begin A.Verbose    := True; Inc(i); Continue; end;
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      PrintHelp;
      Exit(False);
    end;
    Inc(i);
  end;
end;

function FormatAge(SecondsAgo: Int64): string;
begin
  if SecondsAgo < 60    then Exit(IntToStr(SecondsAgo) + 's');
  if SecondsAgo < 3600  then Exit(IntToStr(SecondsAgo div 60) + 'm');
  if SecondsAgo < 86400 then Exit(IntToStr(SecondsAgo div 3600) + 'h');
  Result := IntToStr(SecondsAgo div 86400) + 'd';
end;

procedure PrintReport(const Patterns: TErrorPatternArray;
                     MinSessions, ScannedSessions: Integer);
var
  Now_:  Int64;
  i:     Integer;
  Shown: Integer;
begin
  PrintLn(Ansi.Bold + 'pasclaw learn' + Ansi.Reset +
          Format(' -- scanned %d session(s), found %d unique pattern(s)',
                 [ScannedSessions, Length(Patterns)]));
  PrintLn('');

  Shown := 0;
  Now_  := DateTimeToUnix(Now, False);
  for i := 0 to High(Patterns) do
  begin
    if not PassesThreshold(Patterns[i], MinSessions) then Continue;
    Inc(Shown);
    PrintLn(Ansi.Bold +
            Format('[%d] %d occurrence(s) across %d session(s)',
                   [Shown, Patterns[i].Count, Patterns[i].Sessions.Count]) +
            Ansi.Reset);
    if Patterns[i].Context <> '' then
      PrintLn('    tool:   ' + Ansi.Cyan + Patterns[i].Context + Ansi.Reset);
    if Patterns[i].Kind = 'misuse' then
      PrintLn('    kind:   misuse (the call worked; the tool said it was used wrongly)');
    PrintLn('    sample: ' + Patterns[i].Sample);
    if (Patterns[i].FirstSeen > 0) and (Patterns[i].LastSeen > 0) then
      PrintLn('    seen:   first ' +
              FormatAge(Now_ - Patterns[i].FirstSeen) + ' ago, last ' +
              FormatAge(Now_ - Patterns[i].LastSeen) + ' ago');
    PrintLn('');
  end;
  if Shown = 0 then
    PrintLn(Ansi.Dim + '(no patterns seen in at least ' +
            IntToStr(MinSessions) + ' session(s))' + Ansi.Reset);
end;

procedure AppendToMemoryMd(const Patterns: TErrorPatternArray;
                           MinSessions: Integer);
{ Append a fresh "Patterns observed" block to workspace/memory/
  MEMORY.md. Each run gets its own dated section so re-running
  doesn't clobber an earlier block; operators prune entries they've
  already addressed by hand. Skipped silently when nothing meets
  the threshold. }
var
  Path: string;
  Sl:   TStringList;
  i, Shown: Integer;
begin
  Shown := 0;
  for i := 0 to High(Patterns) do
    if PassesThreshold(Patterns[i], MinSessions) then Inc(Shown);
  if Shown = 0 then
  begin
    PrintLn(Ansi.Dim + '(no patterns to write)' + Ansi.Reset);
    Exit;
  end;

  Path := JoinPath(JoinPath(GetHome, ActiveWorkspaceName + '/memory'), 'MEMORY.md');
  if not DirectoryExists(ExtractFilePath(Path)) then
    ForceDirectories(ExtractFilePath(Path));

  Sl := TStringList.Create;
  try
    if FileExists(Path) then Sl.Text := ReadFileText(Path);
    if (Sl.Count > 0) and (Trim(Sl[Sl.Count - 1]) <> '') then
      Sl.Add('');
    Sl.Add(Format('### Patterns observed (%s)',
                  [FormatDateTime('yyyy-mm-dd', Now)]));
    Sl.Add('');
    Sl.Add('Surfaced by `pasclaw learn`. Each entry is a recurring tool failure ' +
           'across multiple sessions. Edit / delete entries the operator has ' +
           'already addressed.');
    Sl.Add('');
    for i := 0 to High(Patterns) do
    begin
      if not PassesThreshold(Patterns[i], MinSessions) then Continue;
      Sl.Add(Format('- **%dx across %d session(s)**: %s',
                    [Patterns[i].Count, Patterns[i].Sessions.Count,
                     Patterns[i].Sample]));
      if (Patterns[i].Context <> '') and (Patterns[i].Kind = 'misuse') then
        Sl.Add(Format('  (tool: `%s`, misused)', [Patterns[i].Context]))
      else if Patterns[i].Context <> '' then
        Sl.Add(Format('  (tool: `%s`)', [Patterns[i].Context]));
    end;
    Sl.Add('');
    WriteFileText(Path, Sl.Text);   { samples are transcript text -- UTF-8 }
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
            'appended ' + IntToStr(Shown) + ' pattern(s) to ' + Path);
  finally
    Sl.Free;
  end;
end;

procedure AppendToScarsMd(const Patterns: TErrorPatternArray;
                          MinSessions: Integer);
var
  Fresh, Skipped: Integer;
  Path: string;
begin
  Path := ScarsPath;
  if not WriteScars(Path, Patterns, MinSessions, Fresh, Skipped) then
  begin
    PrintLn(Ansi.Red + 'could not write ' + Path + Ansi.Reset);
    Exit;
  end;
  if Fresh = 0 then
    PrintLn(Ansi.Dim +
            Format('(no new SCARS to write; %d existing anchor(s) already cover the patterns)',
                   [Skipped]) +
            Ansi.Reset)
  else
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
            Format('wrote %d new SCARS anchor(s) to %s (%d existing skipped)',
                   [Fresh, Path, Skipped]));
end;

procedure PrintScanning(const SessionId: string);
begin
  PrintLn(Ansi.Dim + 'scanning ' + SessionId + Ansi.Reset);
end;

function Cmd_Learn_Run(const Argv: array of string): Integer;
var
  A:        TLearnArgs;
  Patterns: TErrorPatternArray;
  Scanned:  Integer;
  Progress: TLearnProgress;
begin
  Result := 0;
  if not ParseArgs(Argv, A) then Exit;

  Progress := nil;
  if A.Verbose then Progress := PrintScanning;
  Patterns := MinePatterns(A.SinceDays, Scanned, Progress);
  try
    if Scanned = 0 then
    begin
      if A.SinceDays > 0 then
        PrintLn(Ansi.Dim + Format('(no saved sessions in the last %d day(s) to mine)',
                                  [A.SinceDays]) + Ansi.Reset)
      else
        PrintLn(Ansi.Dim + '(no saved sessions to mine)' + Ansi.Reset);
      Exit;
    end;
    PrintReport(Patterns, A.MinSessions, Scanned);
    if A.Write_      then AppendToMemoryMd(Patterns, A.MinSessions);
    if A.WriteScars  then AppendToScarsMd(Patterns, A.MinSessions);
  finally
    FreePatterns(Patterns);
  end;
end;

end.
