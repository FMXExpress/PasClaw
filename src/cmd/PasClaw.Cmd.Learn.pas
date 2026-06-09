(*
  PasClaw.Cmd.Learn — mine session transcripts for recurring tool
  failures so the operator can promote them into MEMORY.md as
  durable hints.

  Borrowed from Headroom's `headroom learn` (chopratejas/headroom):
  the model often makes the same mistake across many sessions
  (calls `npm test` in a pnpm repo; tries fs_write to a read-only
  path; reaches for `make build` when the Makefile has no `build`
  target). Each failure is recoverable in-loop, but the PATTERN
  only becomes visible when you look across sessions.

  Two pieces:

    1. Mining: walk $PASCLAW_HOME/workspace/sessions/*.json, scan
       every mrTool message for failure-shaped content (an
       'ERROR:' prefix, a non-zero shell exit, common failure
       phrases like `command not found` / `permission denied`).
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

(* Normalise a failure-shaped line into a clustering key. Strips
   pids, line / column numbers, hex hashes, and absolute paths so
   superficially-different lines from the same root cause group
   together. Exposed so a regression test can pin the contract,
   not "approximately whatever this regex did today". *)
function NormalizeErrorSignature(const Raw: string): string;

(* Heuristic predicate: True iff Line looks like a failure marker.
   Used to filter the per-tool output before normalisation; pinned
   here so the matchers stay together with the rules they imply. *)
function LooksLikeFailure(const Line: string): Boolean;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Providers.Types,
  PasClaw.Session.Store;

type
  TErrorPattern = record
    Signature:  string;       { normalised cluster key }
    Count:      Integer;      { total occurrences across all sessions }
    Sessions:   TStringList;  { distinct session ids that hit this }
    Sample:     string;       { first verbatim line we saw }
    Context:    string;       { tool name from the assistant turn that
                                triggered the error (best-effort) }
    FirstSeen:  Int64;        { unix seconds, earliest session UpdatedAt }
    LastSeen:   Int64;        { unix seconds, latest session UpdatedAt }
  end;
  TErrorPatternArray = array of TErrorPattern;

  TLearnArgs = record
    SinceDays:   Integer;     { 0 = no window }
    Write_:      Boolean;     { --write -> append to MEMORY.md }
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
  PrintLn('  --verbose                Print scan progress per session');
end;

function ParseArgs(const Argv: array of string; out A: TLearnArgs): Boolean;
var
  i: Integer;
begin
  A.SinceDays   := 0;
  A.Write_      := False;
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
    if Argv[i] = '--write'   then begin A.Write_  := True; Inc(i); Continue; end;
    if Argv[i] = '--verbose' then begin A.Verbose := True; Inc(i); Continue; end;
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      PrintHelp;
      Exit(False);
    end;
    Inc(i);
  end;
end;

{ ============================ normalisation ============================ }

function IsDigit(c: Char): Boolean;
begin
  Result := (c >= '0') and (c <= '9');
end;

function IsHexDigit(c: Char): Boolean;
begin
  Result := ((c >= '0') and (c <= '9')) or
            ((c >= 'a') and (c <= 'f')) or
            ((c >= 'A') and (c <= 'F'));
end;

function IsAsciiLetter(c: Char): Boolean;
begin
  Result := ((c >= 'a') and (c <= 'z')) or
            ((c >= 'A') and (c <= 'Z'));
end;

function NormalizeErrorSignature(const Raw: string): string;
{ Walk Raw once, replacing variable bits with placeholders so
  same-root-cause failures cluster:

    "fs_write to /tmp/abc123/foo.pas line 42 failed"
       -> "fs_write to <path> line <n> failed"

  Specific transforms (order matters; first match wins per
  position):

    - Long digit run (>= 2 digits) -> <n>
    - Long hex run (>= 8 chars, must contain at least one letter
      so a pure-decimal sequence doesn't accidentally become
      <hash>) -> <hash>
    - Absolute path (starts with / or X:\ or X:/) -> <path>
    - Whitespace runs collapse to a single space; final string
      Trim'd. }
var
  i, j, RunLen, Lookahead: Integer;
  Tok: string;
  c: Char;
  SawLetter: Boolean;
begin
  Result := '';
  i := 1;
  while i <= Length(Raw) do
  begin
    c := Raw[i];

    { Hex run >= 8 chars with at least one letter -> <hash>.
      Checked BEFORE the digit-only run so a hash that happens to
      start with digits (e.g. '0123456789abcdef') isn't eaten
      piecewise. The letter requirement means a pure-decimal 8+
      digit sequence falls through to the digit-run check below. }
    if IsHexDigit(c) then
    begin
      j := i;
      SawLetter := False;
      while (j <= Length(Raw)) and IsHexDigit(Raw[j]) do
      begin
        if IsAsciiLetter(Raw[j]) then SawLetter := True;
        Inc(j);
      end;
      RunLen := j - i;
      if (RunLen >= 8) and SawLetter then
      begin
        Result := Result + '<hash>';
        i := j;
        Continue;
      end;
    end;

    { Long digit run -> <n>. Keep a single literal digit so '0' /
      '1' / '2' survive when they're meaningful (exit codes,
      single-letter flags). }
    if IsDigit(c) then
    begin
      j := i;
      while (j <= Length(Raw)) and IsDigit(Raw[j]) do Inc(j);
      RunLen := j - i;
      if RunLen >= 2 then
      begin
        Result := Result + '<n>';
        i := j;
        Continue;
      end;
    end;

    { Absolute path -> <path>. Unix: leading '/'. Windows: drive
      letter + ':' + ('/' or '\'). Consume up to the next
      whitespace / quote / colon so the whole path collapses; a
      bare '/' (e.g. divider in prose) shouldn't trigger.   }
    if (c = '/') or
       ((i + 2 <= Length(Raw)) and IsAsciiLetter(c) and
        (Raw[i + 1] = ':') and ((Raw[i + 2] = '\') or (Raw[i + 2] = '/'))) then
    begin
      if c = '/' then Lookahead := i + 1 else Lookahead := i + 3;
      if (Lookahead <= Length(Raw)) and (Raw[Lookahead] <> ' ') and
         (Raw[Lookahead] <> #9) and (Raw[Lookahead] <> #10) and
         (Raw[Lookahead] <> #13) and (Raw[Lookahead] <> '"') and
         (Raw[Lookahead] <> '''') then
      begin
        j := Lookahead;
        while (j <= Length(Raw)) and (Raw[j] <> ' ') and (Raw[j] <> #9) and
              (Raw[j] <> #10) and (Raw[j] <> #13) and
              (Raw[j] <> '"') and (Raw[j] <> '''') and (Raw[j] <> ':') do
          Inc(j);
        Result := Result + '<path>';
        i := j;
        Continue;
      end;
    end;

    Result := Result + c;
    Inc(i);
  end;

  { Collapse whitespace runs; trim. }
  Tok := '';
  for i := 1 to Length(Result) do
  begin
    c := Result[i];
    if (c = #10) or (c = #13) or (c = #9) then c := ' ';
    if (c = ' ') and (Length(Tok) > 0) and (Tok[Length(Tok)] = ' ') then
      Continue;
    Tok := Tok + c;
  end;
  Result := Trim(Tok);
end;

{ ============================ scanning ============================ }

function LooksLikeFailure(const Line: string): Boolean;
{ Substring matches against marker phrases that consistently
  appear on the failure side of tool returns. Tuned for precision
  over recall -- false positives waste the operator's time more
  than missed signal. }
var
  L: string;
begin
  L := LowerCase(Line);
  Result :=
    (Pos('error:',                L) > 0) or
    (Pos('command not found',     L) > 0) or
    (Pos('permission denied',     L) > 0) or
    (Pos('no such file',          L) > 0) or
    (Pos('not a directory',       L) > 0) or
    (Pos('cannot find',           L) > 0) or
    (Pos('could not find',        L) > 0) or
    (Pos('connection refused',    L) > 0) or
    (Pos('failed to',             L) > 0) or
    (Pos('undefined symbol',      L) > 0) or
    (Pos('module not found',      L) > 0) or
    (Pos('cannot read',           L) > 0) or
    (Pos('exit=1',                L) = 1) or
    (Pos('exit=2',                L) = 1);
end;

function FindPatternIndex(const Sig: string;
                          const Patterns: TErrorPatternArray): Integer;
var
  i: Integer;
begin
  for i := 0 to High(Patterns) do
    if Patterns[i].Signature = Sig then Exit(i);
  Result := -1;
end;

procedure SplitToolBody(const Body: string; out Lines: TArray<string>);
{ Tool result bodies are often multi-line (shell stderr, JSON
  parse errors). We want each candidate line separately so a
  single "error:" anywhere in the body triggers detection, not
  just on the first line. Pascal's TStringList.Text rewrites line
  separators, which we don't want; hand-roll. }
var
  i, Start: Integer;
begin
  SetLength(Lines, 0);
  Start := 1;
  for i := 1 to Length(Body) do
  begin
    if Body[i] = #10 then
    begin
      SetLength(Lines, Length(Lines) + 1);
      Lines[High(Lines)] := Copy(Body, Start, i - Start);
      { Strip trailing CR from CRLF line endings. }
      if (Length(Lines[High(Lines)]) > 0) and
         (Lines[High(Lines)][Length(Lines[High(Lines)])] = #13) then
        SetLength(Lines[High(Lines)],
                  Length(Lines[High(Lines)]) - 1);
      Start := i + 1;
    end;
  end;
  if Start <= Length(Body) then
  begin
    SetLength(Lines, Length(Lines) + 1);
    Lines[High(Lines)] := Copy(Body, Start, Length(Body) - Start + 1);
  end;
end;

procedure ScanSession(const Sess: TSession; SinceUnix: Int64;
                     var Patterns: TErrorPatternArray);
var
  i, j, k, Idx, NameIdx: Integer;
  Line, Sig, Context, CallId: string;
  Lines: TArray<string>;
  ToolNamesById: TStringList;
begin
  if (SinceUnix > 0) and (Sess.Meta.UpdatedAt > 0) and
     (Sess.Meta.UpdatedAt < SinceUnix) then
    Exit;

  { Map ToolCallId -> Func.Name across the whole session so a tool
    result can be attributed to ITS call (not just whichever call
    happened to be first in the last assistant turn). The tool loop
    appends one assistant message with all parallel calls, then one
    mrTool message per call; matching by ToolCallId is the only
    correct attribution. Codex P2 #2 on PR #190. Sorted +
    case-sensitive IndexOfName lookup. }
  ToolNamesById := TStringList.Create;
  try
    ToolNamesById.Sorted     := True;
    ToolNamesById.Duplicates := dupIgnore;
    for i := 0 to High(Sess.Messages) do
    begin
      if Sess.Messages[i].Role = mrAssistant then
      begin
        for k := 0 to High(Sess.Messages[i].ToolCalls) do
        begin
          CallId := Sess.Messages[i].ToolCalls[k].Id;
          if CallId <> '' then
            ToolNamesById.Add(CallId + '=' +
                              Sess.Messages[i].ToolCalls[k].Func.Name);
        end;
        Continue;
      end;
      if Sess.Messages[i].Role <> mrTool then Continue;
      if Sess.Messages[i].Content = '' then Continue;

      { Per-tool-message context: look up by ToolCallId. Empty
        when the result has no id (older session JSON, model
        skipped the id field, etc.) -- safer to drop the tool
        annotation than to mis-attribute. }
      Context := '';
      if Sess.Messages[i].ToolCallId <> '' then
      begin
        NameIdx := ToolNamesById.IndexOfName(Sess.Messages[i].ToolCallId);
        if NameIdx >= 0 then
          Context := ToolNamesById.ValueFromIndex[NameIdx];
      end;

      SplitToolBody(Sess.Messages[i].Content, Lines);
      for j := 0 to High(Lines) do
      begin
        Line := Trim(Lines[j]);
        if not LooksLikeFailure(Line) then Continue;
        Sig := NormalizeErrorSignature(Line);
        if Sig = '' then Continue;

        Idx := FindPatternIndex(Sig, Patterns);
        if Idx < 0 then
        begin
          SetLength(Patterns, Length(Patterns) + 1);
          Idx := High(Patterns);
          Patterns[Idx].Signature := Sig;
          Patterns[Idx].Count     := 0;
          Patterns[Idx].Sessions  := TStringList.Create;
          Patterns[Idx].Sessions.Sorted     := True;
          Patterns[Idx].Sessions.Duplicates := dupIgnore;
          Patterns[Idx].Sample    := Line;
          Patterns[Idx].Context   := Context;
          Patterns[Idx].FirstSeen := Sess.Meta.UpdatedAt;
          Patterns[Idx].LastSeen  := Sess.Meta.UpdatedAt;
        end
        else if (Patterns[Idx].Context = '') and (Context <> '') then
          { Backfill the tool name if the first hit didn't have a
            ToolCallId but a later same-signature hit does. }
          Patterns[Idx].Context := Context;
        Inc(Patterns[Idx].Count);
        Patterns[Idx].Sessions.Add(Sess.Meta.Id);
        if Sess.Meta.UpdatedAt > Patterns[Idx].LastSeen then
          Patterns[Idx].LastSeen := Sess.Meta.UpdatedAt;
        if (Patterns[Idx].FirstSeen = 0) or
           ((Sess.Meta.UpdatedAt > 0) and
            (Sess.Meta.UpdatedAt < Patterns[Idx].FirstSeen)) then
          Patterns[Idx].FirstSeen := Sess.Meta.UpdatedAt;
      end;
    end;
  finally
    ToolNamesById.Free;
  end;
end;

procedure SortPatternsByCount(var Patterns: TErrorPatternArray);
{ Insertion sort descending on Count. Pattern count is typically
  in the dozens; O(N^2) is fine. }
var
  i, j: Integer;
  Pivot: TErrorPattern;
begin
  for i := 1 to High(Patterns) do
  begin
    Pivot := Patterns[i];
    j := i - 1;
    while (j >= 0) and (Patterns[j].Count < Pivot.Count) do
    begin
      Patterns[j + 1] := Patterns[j];
      Dec(j);
    end;
    Patterns[j + 1] := Pivot;
  end;
end;

function FormatAge(SecondsAgo: Int64): string;
begin
  if SecondsAgo < 60    then Exit(IntToStr(SecondsAgo) + 's');
  if SecondsAgo < 3600  then Exit(IntToStr(SecondsAgo div 60) + 'm');
  if SecondsAgo < 86400 then Exit(IntToStr(SecondsAgo div 3600) + 'h');
  Result := IntToStr(SecondsAgo div 86400) + 'd';
end;

function PassesThreshold(const P: TErrorPattern; MinSessions: Integer): Boolean;
{ Codex P2 #1 on PR #190: gate on distinct session count, not total
  occurrence count. A single session repeating the same failure
  three times still counts as one session and shouldn't qualify as
  "recurring across sessions" -- that contradicts the command's
  purpose and would persist single-session noise into MEMORY.md. }
begin
  Result := P.Sessions.Count >= MinSessions;
end;

procedure PrintReport(const Patterns: TErrorPatternArray;
                     MinSessions, ScannedSessions: Integer);
var
  Now_:  Int64;
  i:     Integer;
  Shown: Integer;
begin
  PrintLn(Ansi.Bold + 'pasclaw learn' + Ansi.Reset +
          Format(' — scanned %d session(s), found %d unique pattern(s)',
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

  Path := JoinPath(JoinPath(GetHome, 'workspace/memory'), 'MEMORY.md');
  if not DirectoryExists(ExtractFilePath(Path)) then
    ForceDirectories(ExtractFilePath(Path));

  Sl := TStringList.Create;
  try
    if FileExists(Path) then Sl.LoadFromFile(Path);
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
      if Patterns[i].Context <> '' then
        Sl.Add(Format('  (tool: `%s`)', [Patterns[i].Context]));
    end;
    Sl.Add('');
    Sl.SaveToFile(Path);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset +
            'appended ' + IntToStr(Shown) + ' pattern(s) to ' + Path);
  finally
    Sl.Free;
  end;
end;

function Cmd_Learn_Run(const Argv: array of string): Integer;
var
  A:         TLearnArgs;
  Sessions:  TSessionMetaArray;
  Sess:      TSession;
  Patterns:  TErrorPatternArray;
  i:         Integer;
  SinceUnix: Int64;
  Scanned:   Integer;
begin
  if not ParseArgs(Argv, A) then Exit(0);

  Sessions := ListSessions;
  if Length(Sessions) = 0 then
  begin
    PrintLn(Ansi.Dim + '(no saved sessions to mine)' + Ansi.Reset);
    Exit(0);
  end;

  if A.SinceDays > 0 then
    SinceUnix := DateTimeToUnix(Now, False) - Int64(A.SinceDays) * 86400
  else
    SinceUnix := 0;

  Scanned := 0;
  SetLength(Patterns, 0);
  try
    for i := 0 to High(Sessions) do
    begin
      if (SinceUnix > 0) and (Sessions[i].UpdatedAt > 0) and
         (Sessions[i].UpdatedAt < SinceUnix) then
        Continue;
      Sess := TSession.Create(Sessions[i].Id);
      try
        if A.Verbose then
          PrintLn(Ansi.Dim + 'scanning ' + Sessions[i].Id + Ansi.Reset);
        ScanSession(Sess, SinceUnix, Patterns);
        Inc(Scanned);
      finally
        Sess.Free;
      end;
    end;

    SortPatternsByCount(Patterns);
    PrintReport(Patterns, A.MinSessions, Scanned);
    if A.Write_ then AppendToMemoryMd(Patterns, A.MinSessions);
  finally
    for i := 0 to High(Patterns) do Patterns[i].Sessions.Free;
  end;
  Result := 0;
end;

end.
