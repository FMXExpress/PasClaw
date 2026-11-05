(*
  PasClaw.Learn -- recurring tool failures, mined from saved sessions.

  The model often makes the same mistake across many sessions (calls
  `npm test` in a pnpm repo, writes to a read-only path, reaches for a
  `make build` the Makefile does not have). Each is recoverable in-loop;
  the PATTERN only shows when you look across sessions. This walks
  $PASCLAW_HOME/workspace/sessions/*.json, takes every tool result line
  that reads as a failure -- or as a misuse the tool itself pointed out --
  normalises it into a cluster signature (pids, line numbers, hashes and
  paths stripped), and counts each signature's occurrences and distinct
  sessions. SCARS.md gets a stable `## §ANCHOR` block per recurring
  pattern; an operator's Root cause / Do / Do NOT survive re-runs.

  Two callers: `pasclaw learn` (PasClaw.Cmd.Learn: the report, MEMORY.md,
  SCARS.md on request) and the nightly pass (PasClaw.Maintain: a
  "Recurring" section in the maintenance report, and SCARS.md refreshed)
  -- which is why this lives in a package unit and not the command.

  Borrowed from Headroom's `headroom learn` (chopratejas/headroom); the
  SCARS anchor convention from Abbasi-Alain/atlas.
*)
unit PasClaw.Learn;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  Classes,
  PasClaw.Session.Store;

const
  (* U+00A7, the anchor mark: UTF-8 bytes in FPC's 8-bit strings, the
     character in Delphi's UTF-16 ones. Spelled out because a literal
     glyph is transcoded through the runtime codepage under FPC (a test
     binary got the Latin-1 byte), and the bytes alone are two characters
     under Delphi. *)
  SectionSign = {$IFDEF FPC}#$C2#$A7{$ELSE}#$00A7{$ENDIF};

type
  TErrorPattern = record
    Signature:  string;       { normalised cluster key }
    Count:      Integer;      { total occurrences across all sessions }
    Sessions:   TStringList;  { distinct session ids that hit this }
    Sample:     string;       { first verbatim line we saw }
    (* 'failure' -- the call failed; 'misuse' -- it worked, but the tool's
       result says the model used it wrongly (LooksLikeMisuse). *)
    Kind:       string;
    Context:    string;       { the tool whose call produced it }
    FirstSeen:  Int64;        { unix seconds, earliest session UpdatedAt }
    LastSeen:   Int64;        { unix seconds, latest session UpdatedAt }
  end;
  TErrorPatternArray = array of TErrorPattern;

  { Called with each session's id as MinePatterns reads it. }
  TLearnProgress = procedure(const SessionId: string);

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

(* True iff Line is a tool's own note that the model misused it -- the
   call worked, nothing failed, and the result says how to do it right. *)
function LooksLikeMisuse(const Line: string): Boolean;

(* The cluster key for a misuse line: one fixed signature per kind of
   misuse, '' for any other line. Not the normalised line -- a note can
   carry the call's own argument (the definition hint names the symbol
   searched for), and every name would otherwise be a pattern of its own
   that never recurs. *)
function MisuseSignature(const Line: string): string;

(* Derive a stable SCARS §ANCHOR-NAME from a normalised pattern
   signature. Exposed so a regression test can pin the contract --
   the anchor is the join point between a learn-run today and a
   commit message tomorrow ("fixes §FOO-BAR"); if the derivation
   drifts, the link rots silently. *)
function MakeAnchorName(const Signature: string): string;

(* Parse an existing SCARS.md and return the set of anchor names
   AND the set of signature markers found in `<!-- signature: ...
   -->` lines. Re-runs skip a pattern whose anchor OR signature is
   already present; the signature path is the rename-survival promise
   from MakeAnchorName's docstring. (Codex P2 on PR #197.) Both lists
   are caller-owned. *)
procedure ReadExistingScars(const Path: string;
                            out Anchors, Signatures: TStringList);

(* One session's tool results, added into Patterns. Sessions older than
   SinceUnix (when > 0) are skipped. *)
procedure ScanSession(const Sess: TSession; SinceUnix: Int64;
                     var Patterns: TErrorPatternArray);

(* Every saved session (of the last SinceDays days; 0 = all), mined and
   sorted by occurrence count, most first. Scanned says how many sessions
   were read; Progress, when set, hears each one. Free the result with
   FreePatterns. *)
function MinePatterns(SinceDays: Integer; out Scanned: Integer;
  Progress: TLearnProgress = nil): TErrorPatternArray;

procedure SortPatternsByCount(var Patterns: TErrorPatternArray);

{ Recurring means seen in at least MinSessions distinct sessions. }
function PassesThreshold(const P: TErrorPattern; MinSessions: Integer): Boolean;

procedure FreePatterns(var Patterns: TErrorPatternArray);

{ <home>/<workspace>/memory/SCARS.md }
function ScarsPath: string;

(* Add a `## §ANCHOR` block to the SCARS.md at Path for each recurring pattern it does
   not already hold (by anchor or by signature); existing blocks, and the
   operator's edits in them, are left alone. Writes only when there is
   something new. False when the file could not be read or written. *)
function WriteScars(const Path: string; const Patterns: TErrorPatternArray;
  MinSessions: Integer; out FreshCount, SkippedCount: Integer): Boolean;

implementation

uses
  SysUtils, DateUtils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Utils,
  PasClaw.Providers.Types;

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

function MisuseSignature(const Line: string): string;
{ The call worked -- nothing failed -- but the tool's own result says
  the model used it wrongly, and how to do it right: the next-move notes
  tools add on a misuse. grep_files given a regex ("a|b" matches those
  three characters) answers "(no matches)" with such a note, and before
  this nothing counted it: the live security run's sweep lost a call to
  it and no report saw. Matched on the notes' fixed wording
  (PasClaw.Tools.FS; learn_tests runs the tool to keep the two in step),
  so a new note needs its phrase added here -- precision over recall, as
  in LooksLikeFailure. }
var
  L: string;
begin
  L := LowerCase(Line);
  if Pos('-- note: grep_files matches a literal substring', L) > 0 then
    Result := 'grep_files regex: a literal-substring search was given a regex'
  else if Pos('-- to find where a name is defined', L) > 0 then
    Result := 'grep_files definition hunt: a keyword guess, where code_outline symbol= finds it'
  else
    Result := '';
end;

function LooksLikeMisuse(const Line: string): Boolean;
begin
  Result := MisuseSignature(Line) <> '';
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
  Line, Sig, Context, CallId, Kind: string;
  Lines: TArray<string>;
  ToolNamesById: TStringList;
begin
  if (SinceUnix > 0) and (Sess.Meta.UpdatedAt > 0) and
     (Sess.Meta.UpdatedAt < SinceUnix) then
    Exit;

  { Map ToolCallId -> Func.Name so a tool result is attributed to ITS
    call (not just whichever call happened to be first in the last
    assistant turn). The tool loop appends one assistant message with
    all parallel calls, then one mrTool message per call; matching by
    ToolCallId is the only correct attribution. Codex P2 #2 on PR #190.

    The latest call with an id wins: a result always follows its own
    call, and ids are only unique within a turn. Some servers number
    calls per turn (c1, c2 ...; the relay provider, several local
    OpenAI-compatible servers), and with the first call kept, every
    later "c1" went to the first turn's tool -- a shell_exec refusal
    was reported as grep_files'. }
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
          if CallId = '' then Continue;
          NameIdx := ToolNamesById.IndexOfName(CallId);
          if NameIdx >= 0 then ToolNamesById.Delete(NameIdx);
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
        Sig := MisuseSignature(Line);
        if Sig <> '' then Kind := 'misuse'
        else if LooksLikeFailure(Line) then
        begin
          Kind := 'failure';
          Sig := NormalizeErrorSignature(Line);
        end
        else Continue;
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
          Patterns[Idx].Kind      := Kind;
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

function PassesThreshold(const P: TErrorPattern; MinSessions: Integer): Boolean;
{ Codex P2 #1 on PR #190: gate on distinct session count, not total
  occurrence count. A single session repeating the same failure
  three times still counts as one session and shouldn't qualify as
  "recurring across sessions" -- that contradicts the command's
  purpose and would persist single-session noise into MEMORY.md. }
begin
  Result := P.Sessions.Count >= MinSessions;
end;

procedure FreePatterns(var Patterns: TErrorPatternArray);
var
  i: Integer;
begin
  for i := 0 to High(Patterns) do Patterns[i].Sessions.Free;
  Patterns := nil;
end;

function MinePatterns(SinceDays: Integer; out Scanned: Integer;
  Progress: TLearnProgress): TErrorPatternArray;
var
  Sessions: TSessionMetaArray;
  Sess: TSession;
  SinceUnix: Int64;
  i: Integer;
begin
  Result := nil;
  Scanned := 0;
  Sessions := ListSessions;
  if SinceDays > 0 then
    SinceUnix := DateTimeToUnix(Now, False) - Int64(SinceDays) * 86400
  else
    SinceUnix := 0;
  for i := 0 to High(Sessions) do
  begin
    if (SinceUnix > 0) and (Sessions[i].UpdatedAt > 0) and
       (Sessions[i].UpdatedAt < SinceUnix) then
      Continue;
    if Assigned(Progress) then Progress(Sessions[i].Id);
    Sess := TSession.Create(Sessions[i].Id);
    try
      ScanSession(Sess, SinceUnix, Result);
      Inc(Scanned);
    finally
      Sess.Free;
    end;
  end;
  SortPatternsByCount(Result);
end;

function ScarsPath: string;
begin
  Result := JoinPath(JoinPath(GetHome, ActiveWorkspaceName + '/memory'), 'SCARS.md');
end;

{ ============================ SCARS.md ============================ }

const
  SCARS_HEADER_MARKER = '<!-- pasclaw scars vN: stable §ANCHOR ids; ' +
                        'operator-edited rationale survives re-runs -->';

function MakeAnchorName(const Signature: string): string;
{ Derive a stable §ANCHOR-NAME from a normalised pattern signature.
  Strategy: drop our own placeholders (`<n>`, `<path>`, `<hash>`),
  uppercase, split on non-alphanumeric, drop English stopwords + the
  most generic failure words, keep the first ~5 distinctive tokens,
  join with `-`, cap at 50 chars. Operators can rename the anchor
  in SCARS.md freely -- pasclaw learn looks patterns up by
  Signature, not by anchor name, so renames don't break the
  duplicate-detection on re-runs. }
const
  MAX_TOKENS = 5;
  MAX_LEN    = 50;
  Stopwords: array[0..15] of string = (
    'a', 'an', 'the', 'in', 'on', 'with', 'for', 'at', 'to', 'by',
    'of', 'from', 'or', 'and', 'is', 'was');
var
  S, Tok, Result_: string;
  Sl: TStringList;
  i, j, k: Integer;
  IsStop: Boolean;
  c: Char;
begin
  { Strip placeholders. }
  S := Signature;
  S := StringReplace(S, '<n>',    ' ', [rfReplaceAll]);
  S := StringReplace(S, '<path>', ' ', [rfReplaceAll]);
  S := StringReplace(S, '<hash>', ' ', [rfReplaceAll]);

  { Tokenise on any non-alphanumeric. Build word list. }
  Sl := TStringList.Create;
  try
    Tok := '';
    for i := 1 to Length(S) do
    begin
      c := S[i];
      if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
         ((c >= '0') and (c <= '9')) then
        Tok := Tok + UpCase(c)
      else
      begin
        if Tok <> '' then Sl.Add(Tok);
        Tok := '';
      end;
    end;
    if Tok <> '' then Sl.Add(Tok);

    { Drop stopwords. Keep first MAX_TOKENS distinctive tokens. }
    Result_ := '';
    for i := 0 to Sl.Count - 1 do
    begin
      IsStop := False;
      for j := Low(Stopwords) to High(Stopwords) do
        if SameText(Sl[i], Stopwords[j]) then
        begin
          IsStop := True;
          Break;
        end;
      if IsStop then Continue;
      if Result_ = '' then Result_ := Sl[i]
      else                 Result_ := Result_ + '-' + Sl[i];
      if Length(Result_) >= MAX_LEN then Break;
      { Count tokens emitted, cap at MAX_TOKENS. }
      if Length(Result_) > 0 then
      begin
        j := 1;
        for k := 1 to Length(Result_) do
          if Result_[k] = '-' then Inc(j);
        if j >= MAX_TOKENS then Break;
      end;
    end;
  finally
    Sl.Free;
  end;

  if Length(Result_) > MAX_LEN then SetLength(Result_, MAX_LEN);
  if Result_ = '' then Result_ := 'PATTERN';
  Result := Result_;
end;

procedure ReadExistingScars(const Path: string;
                            out Anchors, Signatures: TStringList);
{ Parse existing SCARS.md for anchor names AND the per-block
  `<!-- signature: ... -->` markers we emit alongside them, so
  re-runs don't duplicate even when the operator has renamed a
  `## §ANCHOR` heading. Both lists are fresh sorted dupIgnore
  TStringLists; caller owns them. Codex P2 on PR #197: the rename
  promise in MakeAnchorName's docstring is only credible if we
  actually persist the signature; reading by anchor alone meant a
  renamed entry got duplicated on the next learn run. }
const
  SigMarker    = '<!-- signature:';
  { SectionSign, not the literal glyph: FPC was transcoding the inline
    glyph through the system codepage, which left a different byte
    sequence in the constant than what TStringList.LoadFromFile
    returned, so the matcher silently failed. }
  AnchorPrefix = '## ' + SectionSign;
var
  Sl: TStringList;
  i: Integer;
  Line, Name, Sig: string;
  EndPos: Integer;
begin
  Anchors    := TStringList.Create;
  Anchors.Sorted     := True;
  Anchors.Duplicates := dupIgnore;
  Signatures := TStringList.Create;
  Signatures.Sorted     := True;
  Signatures.Duplicates := dupIgnore;
  if not FileExists(Path) then Exit;
  Sl := TStringList.Create;
  try
    try
      Sl.Text := ReadFileText(Path);
    except
      Exit;
    end;
    for i := 0 to Sl.Count - 1 do
    begin
      Line := Trim(Sl[i]);
      { Match `## §NAME ...` -- the §...whitespace tail. The §
        prefix is the AnchorPrefix const above, built from
        SectionSign so FPC can't transcode it through a non-UTF-8
        codepage at runtime. }
      if (Pos(AnchorPrefix, Line) = 1) then
      begin
        Name := Trim(Copy(Line, Length(AnchorPrefix) + 1, MaxInt));
        { Drop any trailing description / annotation after the name. }
        if Pos(' ', Name) > 0 then
          Name := Copy(Name, 1, Pos(' ', Name) - 1);
        if Name <> '' then Anchors.Add(Name);
      end
      else if Pos(SigMarker, Line) = 1 then
      begin
        Sig := Trim(Copy(Line, Length(SigMarker) + 1, MaxInt));
        EndPos := Pos('-->', Sig);
        if EndPos > 0 then Sig := Trim(Copy(Sig, 1, EndPos - 1));
        if Sig <> '' then Signatures.Add(Sig);
      end;
    end;
  finally
    Sl.Free;
  end;
end;

function WriteScars(const Path: string; const Patterns: TErrorPatternArray;
  MinSessions: Integer; out FreshCount, SkippedCount: Integer): Boolean;
{ Emit / refresh workspace/memory/SCARS.md with Atlas-style stable
  §ANCHOR ids per pattern. Re-running does NOT clobber existing
  anchors -- operators routinely fill in Root cause / Do / Do NOT
  with hand-written rationale, and we'd be unfriendly to overwrite
  that work. New patterns get a fresh anchor + boilerplate + an
  embedded `<!-- signature: ... -->` marker; known patterns get
  skipped silently (matched on either the anchor name OR the
  persisted signature, so renamed-by-operator entries still match).
  (Refresh of See: counts on existing anchors is a follow-up; for
  v1 the operator can drop the file and re-run for full
  re-extraction.) }
var
  Sl: TStringList;
  ExistingAnchors, ExistingSignatures: TStringList;
  i: Integer;
  Anchor, Sig: string;
begin
  Result := False;
  FreshCount := 0;
  SkippedCount := 0;
  try
  if not DirectoryExists(ExtractFilePath(Path)) then
    ForceDirectories(ExtractFilePath(Path));

  ReadExistingScars(Path, ExistingAnchors, ExistingSignatures);
  Sl := TStringList.Create;
  try
    if FileExists(Path) then
      Sl.Text := ReadFileText(Path)
    else
    begin
      { Fresh file -- write the header preamble. }
      Sl.Add('# SCARS -- recurring failures the operator has codified');
      Sl.Add('');
      Sl.Add(SCARS_HEADER_MARKER);
      Sl.Add('');
      Sl.Add('Each `## §ANCHOR-NAME` block describes one recurring tool');
      Sl.Add('failure surfaced by `pasclaw learn`. Anchor names are stable --');
      Sl.Add('cite them in commit messages and PRs (`git log --grep "§"`)');
      Sl.Add('to link a fix back to the failure it addresses. Operators');
      Sl.Add('rename anchors freely; pasclaw learn matches patterns by the');
      Sl.Add('embedded `<!-- signature: ... -->` marker, not by anchor');
      Sl.Add('name, so renames survive re-runs. Do not edit the signature');
      Sl.Add('marker -- it is how we know we have already cataloged this');
      Sl.Add('pattern.');
      Sl.Add('');
    end;
    if (Sl.Count > 0) and (Trim(Sl[Sl.Count - 1]) <> '') then
      Sl.Add('');

    FreshCount   := 0;
    SkippedCount := 0;
    for i := 0 to High(Patterns) do
    begin
      if Patterns[i].Sessions.Count < MinSessions then Continue;
      Anchor := MakeAnchorName(Patterns[i].Signature);
      Sig    := Patterns[i].Signature;

      { Re-runs leave operator-edited anchors alone. Match on
        anchor OR signature -- the signature check is the one that
        catches a renamed `## §FOO-BAR` heading whose underlying
        pattern we'd otherwise duplicate. Same pattern appearing
        in fresh sessions still bumps the in-memory counts the
        reports show, but it doesn't overwrite the on-disk SCARS
        entry. }
      if (ExistingAnchors.IndexOf(Anchor) >= 0) or
         (ExistingSignatures.IndexOf(Sig) >= 0) then
      begin
        Inc(SkippedCount);
        Continue;
      end;

      { SectionSign, so the bytes we emit here match the ones
        ReadExistingScars looks for via AnchorPrefix -- see the
        const block in that function for the why. }
      Sl.Add(Format('## ' + SectionSign + '%s', [Anchor]));
      Sl.Add(Format('<!-- signature: %s -->', [Sig]));
      Sl.Add('');
      Sl.Add(Format('**Symptom:** %s', [Patterns[i].Sample]));
      Sl.Add('');
      Sl.Add('**Root cause:** _operator: fill in -- what was the underlying problem?_');
      Sl.Add('');
      Sl.Add('**Do NOT:** _operator: fill in -- what shouldn''t we try again?_');
      Sl.Add('');
      Sl.Add('**Do:** _operator: fill in -- the working remedy._');
      Sl.Add('');
      if Patterns[i].Kind = 'misuse' then
      begin
        Sl.Add('**Kind:** misuse -- the call worked, but the tool''s result says ' +
               'it was used wrongly');
        Sl.Add('');
      end;
      if Patterns[i].Context <> '' then
        Sl.Add(Format('**Where:** tool `%s`', [Patterns[i].Context]))
      else
        Sl.Add('**Where:** _multiple tools or none surfaced via Context_');
      Sl.Add('');
      Sl.Add(Format(
        '**See:** %d occurrence(s) across %d session(s)',
        [Patterns[i].Count, Patterns[i].Sessions.Count]));
      Sl.Add('');

      Inc(FreshCount);
      ExistingAnchors.Add(Anchor);       { in-run dedup against later
                                           patterns that collapse to
                                           the same anchor }
      ExistingSignatures.Add(Sig);       { and against later
                                           patterns with the same
                                           normalised signature }
    end;

    if FreshCount > 0 then WriteFileText(Path, Sl.Text);
    Result := True;
  finally
    Sl.Free;
    ExistingAnchors.Free;
    ExistingSignatures.Free;
  end;
  except
    on E: Exception do Result := False;   { unreadable or unwritable }
  end;
end;

end.
