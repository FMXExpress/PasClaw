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

  What is NOT mined is as important, now that the nightly pass writes
  SCARS.md unattended: text a tool merely returns -- a file read_file
  read, a grep hit, a memory_search snippet of SCARS.md itself, a board
  check's output in a task, a subagent's answer -- is quoted, not
  failed, and only such a result's own status line counts (the tools are
  QuotingTools in PasClaw.Tools.Notes). Otherwise SCARS.md, once read,
  would come back as new failures, and the next night would write
  anchors for its own Symptom lines. A line that only says a result
  failed ("exit=1", a traceback's header) counts it as failed but is
  never a pattern. Lines are stripped of colour codes, masked for
  secrets (RedactSecrets) and cut to a length before they are kept.

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
  (* pkFailure -- the call failed. pkMisuse -- it worked, but the tool's
     own result says the model used it wrongly (MisuseSignature). *)
  TPatternKind = (pkFailure, pkMisuse);

  TErrorPattern = record
    Signature:  string;       { cluster key }
    Count:      Integer;      { total occurrences across all sessions }
    Sessions:   TStringList;  { distinct session ids that hit this }
    Sample:     string;       { first line seen, secrets masked }
    Kind:       TPatternKind;
    Context:    string;       { the tool whose call produced it }
    FirstSeen:  Int64;        { unix seconds, earliest session UpdatedAt }
    LastSeen:   Int64;        { unix seconds, latest session UpdatedAt }
  end;
  TErrorPatternArray = array of TErrorPattern;

  { One problem line of one tool result. }
  TProblemLine = record
    Kind:      TPatternKind;
    Line:      string;        { trimmed, colour codes gone, secrets masked, clipped }
    Signature: string;
    (* The line says the result failed but not how: "exit=1", a traceback's
       header, "build FAILED (...)". It counts the result as failed and is
       never a pattern: every failing command in every session shares it. *)
    Bare:      Boolean;
  end;
  TProblemLineArray = array of TProblemLine;

  { Called with each session's id as MinePatterns reads it. }
  TLearnProgress = procedure(const SessionId: string);

  (* Patterns over many sessions, with one signature index for the whole
     pass. A linear search per candidate line was quadratic in the number
     of patterns, which the nightly pass over 30 days made matter. *)
  TPatternMiner = class
  private
    FPatterns: TErrorPatternArray;
    FCount:    Integer;
    FIndex:    TStringList;   { signature -> index into FPatterns (Objects) }
    procedure Reindex;
    procedure AddLine(const P: TProblemLine; const Tool: string;
                      const Sess: TSession);
  public
    constructor Create;
    destructor Destroy; override;
    { Take over Patterns (Patterns becomes nil) and keep adding to them. }
    procedure Adopt(var Patterns: TErrorPatternArray);
    { One tool result's problem lines (ProblemLines), for a caller that
      classifies each result once and uses it for more than mining. Bare
      lines are not patterns and are skipped. }
    procedure Add(const Probs: TProblemLineArray; const Tool: string;
                  const Sess: TSession);
    { Add one session's problem lines. Names is ResultToolNames(Sess), for
      a caller that already has it. }
    procedure Scan(const Sess: TSession); overload;
    procedure Scan(const Sess: TSession; const Names: TArray<string>); overload;
    { The patterns, most occurrences first. The caller owns them now
      (FreePatterns) and the miner is empty. }
    function Take: TErrorPatternArray;
  end;

(* Normalise a failure-shaped line into a clustering key. Strips
   pids, line / column numbers, hex hashes, and absolute paths so
   superficially-different lines from the same root cause group
   together. Exposed so a regression test can pin the contract,
   not "approximately whatever this regex did today". *)
function NormalizeErrorSignature(const Raw: string): string;

(* Heuristic predicate: True iff Line looks like a failure marker.
   The one definition of a failed tool result: `pasclaw learn` clusters
   by it and `pasclaw maintain` counts by it. *)
function LooksLikeFailure(const Line: string): Boolean;

(* True for a line that says a result failed but not how -- a nonzero
   "exit=N" (the shell and execute_code tools' first line), a Python
   traceback's header, "build FAILED (...)". LooksLikeFailure is True for
   it too; ProblemLines marks it Bare. *)
function IsBareStatus(const Line: string): Boolean;

{ Line without its ANSI escape sequences (colour, cursor). }
function StripAnsi(const Line: string): string;

(* The cluster key for a misuse line -- a result line that starts with one
   of the notes in PasClaw.Tools.Notes -- or '' for any other line. One
   fixed signature per kind of misuse, not the normalised line: a note can
   carry the call's own argument (the definition hint names the symbol
   searched for), and every name would otherwise be a one-off. Only the
   start of a line counts, so a file or a memory note that quotes a note
   is not a misuse. *)
function MisuseSignature(const Line: string): string;

{ MisuseSignature(Line) <> '' }
function LooksLikeMisuse(const Line: string): Boolean;

(* Line with the credentials a failure line tends to carry replaced by
   <redacted>: URL userinfo (https://user:pass@host), tokens with a known
   prefix (ghp_, github_pat_, sk-, xoxb-, AKIA, AIza ...), the value after
   a password= / token= / secret: style key or after Bearer, and long
   mixed-case alphanumeric runs. Samples and signatures go through this
   before they are kept: SCARS.md is written unattended, and `pasclaw
   export` copies it into rule files that get committed. *)
function RedactSecrets(const Line: string): string;

(* True for a tool whose result is text it read, fetched or keeps rather
   than the outcome of something it ran (PasClaw.Tools.Notes'
   QuotingTools). Only the first line of such a result can be its own
   failure ('ERROR: ...', the tool loop's prefix) or misuse note; the
   rest is quoted. *)
function QuotesStoredText(const ToolName: string): Boolean;

(* The problem lines of one tool result: its failures and misuse notes,
   with what it only quotes left out -- the body of a read or a search,
   and lines of SCARS.md or a maintenance report wherever they turn up --
   and secrets masked. *)
function ProblemLines(const ToolName, Content: string): TProblemLineArray;

(* For each message of Sess, the name of the tool whose call a tool result
   answers ('' for other messages and for a result that matches no call).
   The latest call with an id wins: a result always follows its own call,
   and some servers number calls per turn (c1, c2 ...), so an id is only
   unique within a turn. *)
function ResultToolNames(const Sess: TSession): TArray<string>;

(* When a session last changed, in unix seconds: its UpdatedAt, else its
   CreatedAt, else its file's modification time -- so a session saved by
   an older build with no timestamps still ages out of a window. 0 only
   when none of them can be had. *)
function SessionStamp(const Meta: TSessionMeta): Int64;

(* Is a session stamped Stamp (SessionStamp) inside the window that starts
   at SinceUnix? SinceUnix <= 0 is no window, and everything is in it.
   With a window, a session of unknown age is outside: counted forever it
   would recur forever. The one rule for both callers. *)
function InWindow(Stamp, SinceUnix: Int64): Boolean;

(* Derive a stable SCARS §ANCHOR-NAME from a normalised pattern
   signature. Exposed so a regression test can pin the contract --
   the anchor is the join point between a learn-run today and a
   commit message tomorrow ("fixes §FOO-BAR"); if the derivation
   drifts, the link rots silently. *)
function MakeAnchorName(const Signature: string): string;

(* Parse an existing SCARS.md and return the set of anchor names
   AND the set of signature markers found in `<!-- signature: ...
   -->` lines. Re-runs skip a pattern whose signature is already
   present; the signature path is the rename-survival promise from
   MakeAnchorName's docstring. (Codex P2 on PR #197.) Both lists are
   caller-owned. *)
procedure ReadExistingScars(const Path: string;
                            out Anchors, Signatures: TStringList);

{ One session's problem lines added into Patterns. A TPatternMiner for one
  session; across many, use the miner. }
procedure ScanSession(const Sess: TSession; var Patterns: TErrorPatternArray);

(* Every saved session (of the last SinceDays days; 0 = all), mined and
   sorted by occurrence count, most first. Scanned says how many sessions
   were read; Progress, when set, hears each one. Free the result with
   FreePatterns. *)
function MinePatterns(SinceDays: Integer; out Scanned: Integer;
  Progress: TLearnProgress = nil): TErrorPatternArray;

{ Most occurrences first; equal counts keep their order. }
procedure SortPatternsByCount(var Patterns: TErrorPatternArray);

{ Recurring means seen in at least MinSessions distinct sessions. }
function PassesThreshold(const P: TErrorPattern; MinSessions: Integer): Boolean;

procedure FreePatterns(var Patterns: TErrorPatternArray);

{ <home>/<workspace>/memory/SCARS.md }
function ScarsPath: string;

(* Bring the SCARS.md at Path up to date with the recurring patterns
   (seen in at least MinSessions sessions):
   - one the file already has is left alone and counted in SkippedCount.
     It is found by its signature marker, so an anchor the operator
     renamed is followed; a hand-written block with no marker is taken to
     be the pattern whose anchor it has, as before markers existed;
   - one it does not have gets a new `## §ANCHOR` block. An anchor another
     pattern already holds gets a -2, -3 ... suffix rather than the new
     pattern being dropped as "already there".
   AnchorOf[i] is the anchor Patterns[i] has in the file afterwards, ''
   when it has none (below the threshold, or new in a DryRun). DryRun
   works it all out and writes nothing; FreshCount is then what a real run
   would add. False, with both counts 0 and every anchor '', when the file
   could not be read or written. *)
function WriteScars(const Path: string; const Patterns: TErrorPatternArray;
  MinSessions: Integer; DryRun: Boolean;
  out FreshCount, SkippedCount: Integer; out AnchorOf: TArray<string>): Boolean;

implementation

uses
  SysUtils, DateUtils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Utils,
  PasClaw.Providers.Types,
  PasClaw.Tools.Notes;

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
    (Pos('exception:',            L) > 0) or
    IsBareStatus(Line);
end;

function IsBareStatus(const Line: string): Boolean;
{ "exit=" then a code that is not 0 -- every one, where only exit=1 and
  exit=2 counted before (pytest's 4 and 5, curl's 6 and 7 did not). }
var
  L: string;
  i: Integer;
  NonZero: Boolean;
begin
  L := LowerCase(TrimLeft(Line));
  if Pos('exit=', L) = 1 then
  begin
    i := 6;
    NonZero := False;
    while (i <= Length(L)) and (L[i] >= '0') and (L[i] <= '9') do
    begin
      if L[i] <> '0' then NonZero := True;
      Inc(i);
    end;
    Exit(NonZero);
  end;
  Result := (Pos('traceback (most recent call last)', L) = 1) or
            (Pos('build failed', L) = 1);
end;

function StripAnsi(const Line: string): string;
{ CSI (ESC [ ... final byte), OSC (ESC ] ... BEL or ESC \), and the
  two-byte escapes. A coloured and a plain run of the same failure must
  give one signature, and SCARS.md has no use for escape bytes. }
var
  i, N: Integer;
begin
  if Pos(#27, Line) = 0 then Exit(Line);
  Result := '';
  N := Length(Line);
  i := 1;
  while i <= N do
  begin
    if Line[i] <> #27 then
    begin
      Result := Result + Line[i];
      Inc(i);
      Continue;
    end;
    Inc(i);
    if i > N then Break;
    if Line[i] = '[' then
    begin
      Inc(i);
      while (i <= N) and not ((Line[i] >= '@') and (Line[i] <= '~')) do Inc(i);
      Inc(i);
    end
    else if Line[i] = ']' then
    begin
      Inc(i);
      while (i <= N) and (Line[i] <> #7) and
            not ((Line[i] = #27) and (i < N) and (Line[i + 1] = '\')) do
        Inc(i);
      if (i <= N) and (Line[i] = #27) then Inc(i, 2) else Inc(i);
    end
    else
      Inc(i);
  end;
end;

function MisuseSignature(const Line: string): string;
{ The call worked -- nothing failed -- but the tool's own result says the
  model used it wrongly, and how to do it right. grep_files given a regex
  ("a|b" matches those three characters) answers "(no matches)" with
  such a note, and before this nothing counted it: the live security
  run's sweep lost a call to it and no report saw. The notes and their
  signatures are one table in PasClaw.Tools.Notes, which the tool builds
  its notes from; learn_tests runs the tool to keep the two in step. }
var
  L: string;
  i: Integer;
begin
  L := TrimLeft(Line);
  for i := Low(MisuseNotes) to High(MisuseNotes) do
    if Pos(MisuseNotes[i].Starts, L) = 1 then Exit(MisuseNotes[i].Signature);
  Result := '';
end;

function LooksLikeMisuse(const Line: string): Boolean;
begin
  Result := MisuseSignature(Line) <> '';
end;

{ ------------------------------------------------------------- secrets }

function IsWordChar(c: Char): Boolean;
begin
  Result := ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
            ((c >= '0') and (c <= '9')) or (c = '_') or (c = '-');
end;

function LooksLikeToken(const W: string): Boolean;
{ A word that is a credential by its shape: a known vendor prefix with a
  body after it, or a long run that mixes upper case, lower case and
  digits the way generated keys do (a hex hash is one case, so it stays). }
const
  Prefixes: array[0..17] of string = (
    'ghp_', 'gho_', 'ghu_', 'ghs_', 'ghr_', 'github_pat_', 'glpat-',
    'sk-', 'xoxb-', 'xoxp-', 'xoxa-', 'xoxs-', 'xapp-', 'AKIA', 'ASIA',
    'AIza', 'npm_', 'hf_');
var
  i: Integer;
  Up, Lo, Dig: Boolean;
begin
  for i := Low(Prefixes) to High(Prefixes) do
    if (Pos(Prefixes[i], W) = 1) and (Length(W) >= Length(Prefixes[i]) + 12) then
      Exit(True);
  Result := False;
  if Length(W) < 32 then Exit;
  Up := False; Lo := False; Dig := False;
  for i := 1 to Length(W) do
    case W[i] of
      'A'..'Z': Up := True;
      'a'..'z': Lo := True;
      '0'..'9': Dig := True;
    end;
  Result := Up and Lo and Dig;
end;

function IsSecretKey(const W: string): Boolean;
{ A key whose value is a secret: password=..., --token ..., API_KEY: ... }
const
  Tails: array[0..9] of string = (
    'password', 'passwd', 'secret', 'token', 'apikey', 'api_key', 'api-key',
    'secret_key', 'access_key', 'private_key');
var
  L: string;
  i: Integer;
begin
  L := LowerCase(W);
  if (L = 'pwd') or (L = 'auth') or (L = 'authorization') then Exit(True);
  for i := Low(Tails) to High(Tails) do
    if (Length(L) >= Length(Tails[i])) and
       (Copy(L, Length(L) - Length(Tails[i]) + 1, MaxInt) = Tails[i]) then
      Exit(True);
  Result := False;
end;

function LooksLikeSecretValue(const V: string): Boolean;
{ After a secret key: long enough, and not a plain lowercase word --
  "unexpected token: identifier" is a parser talking, not a credential. }
var
  i: Integer;
begin
  Result := False;
  if Length(V) < 6 then Exit;
  for i := 1 to Length(V) do
    if not ((V[i] >= 'a') and (V[i] <= 'z')) then Exit(True);
end;

function IsBase64Char(c: Char): Boolean;
begin
  Result := IsWordChar(c) or (c = '+') or (c = '/') or (c = '=');
end;

function LooksLikeBase64Secret(const R: string): Boolean;
{ A long run that only base64 makes: a '+', or '=' padding at its end,
  with mixed case and digits. The word rule sees such a run in pieces
  ('+' and '/' end a word), each too short to catch. A path has '/'
  but neither mark, and KEY=value has '=' in the middle. }
var
  i: Integer;
  Up, Lo, Dig: Boolean;
begin
  Result := False;
  if Length(R) < 32 then Exit;
  if (Pos('+', R) = 0) and (R[Length(R)] <> '=') then Exit;
  Up := False; Lo := False; Dig := False;
  for i := 1 to Length(R) do
    case R[i] of
      'A'..'Z': Up := True;
      'a'..'z': Lo := True;
      '0'..'9': Dig := True;
    end;
  Result := Up and Lo and Dig;
end;

function IsValueEnd(c: Char): Boolean;
begin
  Result := (c = ' ') or (c = #9) or (c = '"') or (c = '''') or (c = '&') or
            (c = ',') or (c = ';') or (c = ')') or (c = ']') or (c = '}') or
            (c = '>') or (c = '<');
end;

function RedactSecrets(const Line: string): string;
const
  Mark = '<redacted>';
var
  i, j, k, N: Integer;
  W, V: string;
begin
  Result := '';
  N := Length(Line);
  i := 1;
  while i <= N do
  begin
    { A base64 key, whole. }
    if IsBase64Char(Line[i]) and ((i = 1) or not IsBase64Char(Line[i - 1])) then
    begin
      k := i;
      while (k <= N) and IsBase64Char(Line[k]) do Inc(k);
      if LooksLikeBase64Secret(Copy(Line, i, k - i)) then
      begin
        Result := Result + Mark;
        i := k;
        Continue;
      end;
    end;
    { scheme://user[:password]@host -- the userinfo goes, whatever it is. }
    if (Line[i] = ':') and (i + 2 <= N) and (Line[i + 1] = '/') and (Line[i + 2] = '/') then
    begin
      j := i + 3;
      k := j;
      while (k <= N) and (Line[k] <> '/') and (Line[k] <> '@') and
            not IsValueEnd(Line[k]) do
        Inc(k);
      Result := Result + '://';
      if (k <= N) and (Line[k] = '@') and (k > j) then
      begin
        Result := Result + Mark + '@';
        i := k + 1;
      end
      else
        i := j;
      Continue;
    end;
    if IsWordChar(Line[i]) and ((i = 1) or not IsWordChar(Line[i - 1])) then
    begin
      k := i;
      while (k <= N) and IsWordChar(Line[k]) do Inc(k);
      W := Copy(Line, i, k - i);
      if LooksLikeToken(W) then
      begin
        Result := Result + Mark;
        i := k;
        Continue;
      end;
      Result := Result + W;
      i := k;
      { Bearer <value>, Basic <value>. }
      if SameText(W, 'bearer') or SameText(W, 'basic') then
      begin
        j := i;
        while (j <= N) and (Line[j] = ' ') do Inc(j);
        k := j;
        while (k <= N) and not IsValueEnd(Line[k]) do Inc(k);
        if (j > i) and (k - j >= 8) then
        begin
          Result := Result + Copy(Line, i, j - i) + Mark;
          i := k;
        end;
        Continue;
      end;
      { key=value, key: value, key="value"; and a flag's value after a
        space: --password Hunter22, --token abc... }
      if IsSecretKey(W) then
      begin
        j := i;
        while (j <= N) and (Line[j] = ' ') do Inc(j);
        if (W[1] = '-') and (j > i) and (j <= N) and
           (Line[j] <> '=') and (Line[j] <> ':') and (Line[j] <> '-') then
        begin
          k := j;
          while (k <= N) and not IsValueEnd(Line[k]) do Inc(k);
          V := Copy(Line, j, k - j);
          if LooksLikeSecretValue(V) then
          begin
            Result := Result + Copy(Line, i, j - i) + Mark;
            i := k;
          end;
        end
        else if (j <= N) and ((Line[j] = '=') or (Line[j] = ':')) then
        begin
          Inc(j);
          while (j <= N) and (Line[j] = ' ') do Inc(j);
          if (j <= N) and ((Line[j] = '"') or (Line[j] = '''')) then Inc(j);
          k := j;
          while (k <= N) and not IsValueEnd(Line[k]) do Inc(k);
          V := Copy(Line, j, k - j);
          { "Authorization: Bearer x": leave Bearer to its own rule. }
          if SameText(V, 'bearer') or SameText(V, 'basic') then
          begin
            Result := Result + Copy(Line, i, j - i);
            i := j;
          end
          else if LooksLikeSecretValue(V) then
          begin
            Result := Result + Copy(Line, i, j - i) + Mark;
            i := k;
          end;
        end;
      end;
      Continue;
    end;
    Result := Result + Line[i];
    Inc(i);
  end;
end;

{ ------------------------------------------------------------- results }

function QuotesStoredText(const ToolName: string): Boolean;
var
  i: Integer;
begin
  for i := Low(QuotingTools) to High(QuotingTools) do
    if ToolName = QuotingTools[i] then Exit(True);
  Result := False;
end;

function IsRecordedLine(const Line: string): Boolean;
{ A line of SCARS.md or of a maintenance report, wherever it turns up --
  `cat` in a shell as much as a read. It quotes a failure; mining it
  would turn the record of a failure into a new one. }
begin
  Result :=
    (Pos('**Symptom:**', Line) = 1) or
    (Pos('<!-- signature:', Line) = 1) or
    (Pos('- `', Line) = 1) or                      { a report's failure sample }
    { "- 2x across 2 sessions, ..." (a report's recurring line, with or
      without its anchor) and "- **2x across 2 session(s)**: ..." (the
      Patterns block `pasclaw learn --write` puts in MEMORY.md) }
    ((Pos('- ', Line) = 1) and (Pos('x across ', Line) > 0) and
     (Pos(' session', Line) > 0));
end;

procedure SplitToolBody(const Body: string; out Lines: TArray<string>);
{ Tool result bodies are often multi-line (shell stderr, JSON parse
  errors). We want each candidate line separately so a single "error:"
  anywhere in the body triggers detection, not just on the first line.
  TStringList.Text rewrites line separators, which we don't want, so this
  counts the lines first and fills the array once. }
var
  i, Start, N, Count: Integer;
begin
  Count := 1;
  for i := 1 to Length(Body) do
    if Body[i] = #10 then Inc(Count);
  SetLength(Lines, Count);
  N := 0;
  Start := 1;
  for i := 1 to Length(Body) + 1 do
    if (i > Length(Body)) or (Body[i] = #10) then
    begin
      Lines[N] := Copy(Body, Start, i - Start);
      { Strip trailing CR from CRLF line endings. }
      if (Length(Lines[N]) > 0) and (Lines[N][Length(Lines[N])] = #13) then
        SetLength(Lines[N], Length(Lines[N]) - 1);
      Inc(N);
      Start := i + 1;
    end;
  { A body that ends in a newline has no last line after it. }
  if (N > 0) and (Lines[N - 1] = '') and (Length(Body) > 0) and
     (Body[Length(Body)] = #10) then
    Dec(N);
  SetLength(Lines, N);
end;

function ClipTo(const S: string; Cols: Integer): string;
{ At most Cols columns, cut between characters, never inside one. }
var
  Rest: string;
begin
  if Length(S) <= Cols then Exit(S);
  Result := TruncateVisible(S, Cols, Rest);
end;

const
  { How much of a line is redacted, and then kept. A failure line can be a
    whole minified bundle; the sample and the signature of one are not.
    Redacting a wider span first means no secret is cut in half before
    the redactor has seen it whole. }
  RedactSpan = 4000;
  KeptSpan   = 400;

function ProblemLines(const ToolName, Content: string): TProblemLineArray;
var
  Lines: TArray<string>;
  j, N: Integer;
  Line, Sig: string;
  Quoting, Bare: Boolean;
  Kind: TPatternKind;
begin
  Result := nil;
  if Content = '' then Exit;
  Quoting := QuotesStoredText(ToolName);
  SplitToolBody(Content, Lines);
  N := 0;
  for j := 0 to High(Lines) do
  begin
    if Quoting and (j > 0) then Break;     { the rest is what it read }
    Line := Trim(StripAnsi(Lines[j]));
    if (Line = '') or IsRecordedLine(Line) then Continue;
    Bare := False;
    Sig := MisuseSignature(Line);
    if Sig <> '' then
      Kind := pkMisuse
    else if Quoting then
    begin
      if Pos('ERROR:', Line) <> 1 then Continue;
      Kind := pkFailure;
    end
    else if LooksLikeFailure(Line) then
    begin
      Kind := pkFailure;
      Bare := IsBareStatus(Line);
    end
    else
      Continue;
    Line := ClipTo(RedactSecrets(ClipTo(Line, RedactSpan)), KeptSpan);
    if Kind = pkFailure then Sig := NormalizeErrorSignature(Line);
    if Sig = '' then Continue;
    if N = Length(Result) then SetLength(Result, 2 * N + 2);
    Result[N].Kind      := Kind;
    Result[N].Line      := Line;
    Result[N].Signature := Sig;
    Result[N].Bare      := Bare;
    Inc(N);
  end;
  SetLength(Result, N);
end;

function ResultToolNames(const Sess: TSession): TArray<string>;
{ A sorted, case-sensitive list of ids, each pointing into Names. Not
  Name=Value pairs: an id with '=' in it (base64 padding) would split
  there and never be found. }
var
  Ids: TStringList;
  Names: TArray<string>;
  i, k, P, N: Integer;
  Id: string;
begin
  Result := nil;
  SetLength(Result, Length(Sess.Messages));
  Names := nil;
  N := 0;
  Ids := TStringList.Create;
  try
    Ids.CaseSensitive := True;
    Ids.Sorted := True;
    for i := 0 to High(Sess.Messages) do
      case Sess.Messages[i].Role of
        mrAssistant:
          for k := 0 to High(Sess.Messages[i].ToolCalls) do
          begin
            Id := Sess.Messages[i].ToolCalls[k].Id;
            if Id = '' then Continue;
            if Ids.Find(Id, P) then
              Names[NativeInt(Ids.Objects[P])] := Sess.Messages[i].ToolCalls[k].Func.Name
            else
            begin
              if N = Length(Names) then SetLength(Names, 2 * N + 4);
              Names[N] := Sess.Messages[i].ToolCalls[k].Func.Name;
              Ids.AddObject(Id, TObject(NativeInt(N)));
              Inc(N);
            end;
          end;
        mrTool:
          if (Sess.Messages[i].ToolCallId <> '') and
             Ids.Find(Sess.Messages[i].ToolCallId, P) then
            Result[i] := Names[NativeInt(Ids.Objects[P])];
      end;
  finally
    Ids.Free;
  end;
end;

function SessionStamp(const Meta: TSessionMeta): Int64;
var
  Dt: TDateTime;
  Path: string;
begin
  if Meta.UpdatedAt > 0 then Exit(Meta.UpdatedAt);
  if Meta.CreatedAt > 0 then Exit(Meta.CreatedAt);
  Result := 0;
  Path := SessionPath(Meta.Id);
  if (Path <> '') and FileAge(Path, Dt) then
    Result := DateTimeToUnix(Dt, False);
end;

function InWindow(Stamp, SinceUnix: Int64): Boolean;
begin
  Result := (SinceUnix <= 0) or ((Stamp > 0) and (Stamp >= SinceUnix));
end;

{ ------------------------------------------------------------- patterns }

procedure SortPatternsByCount(var Patterns: TErrorPatternArray);
{ A stable merge sort, most occurrences first: equal counts keep the order
  they were found in. The insertion sort it replaces was quadratic. }
var
  Tmp: TErrorPatternArray;
  Width, Lo, Mid, Hi, A, B, K, N: Integer;
  Src, Dst: ^TErrorPatternArray;
  Swap: Pointer;
begin
  N := Length(Patterns);
  if N < 2 then Exit;
  SetLength(Tmp, N);
  Src := @Patterns;
  Dst := @Tmp;
  Width := 1;
  while Width < N do
  begin
    Lo := 0;
    while Lo < N do
    begin
      Mid := Lo + Width;
      if Mid > N then Mid := N;
      Hi := Lo + 2 * Width;
      if Hi > N then Hi := N;
      A := Lo; B := Mid; K := Lo;
      while K < Hi do
      begin
        if (A < Mid) and ((B >= Hi) or (Src^[A].Count >= Src^[B].Count)) then
        begin
          Dst^[K] := Src^[A];
          Inc(A);
        end
        else
        begin
          Dst^[K] := Src^[B];
          Inc(B);
        end;
        Inc(K);
      end;
      Lo := Hi;
    end;
    Swap := Src; Src := Dst; Dst := Swap;
    Width := Width * 2;
  end;
  if Src <> @Patterns then Patterns := Tmp;
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

constructor TPatternMiner.Create;
begin
  inherited Create;
  FIndex := TStringList.Create;
  FIndex.CaseSensitive := True;
  FIndex.Sorted := True;
end;

destructor TPatternMiner.Destroy;
begin
  SetLength(FPatterns, FCount);
  FreePatterns(FPatterns);
  FIndex.Free;
  inherited Destroy;
end;

procedure TPatternMiner.Reindex;
var
  i: Integer;
begin
  FIndex.Clear;
  for i := 0 to FCount - 1 do
    FIndex.AddObject(FPatterns[i].Signature, TObject(NativeInt(i)));
end;

procedure TPatternMiner.Adopt(var Patterns: TErrorPatternArray);
begin
  SetLength(FPatterns, FCount);
  FreePatterns(FPatterns);
  FPatterns := Patterns;
  FCount := Length(FPatterns);
  Patterns := nil;
  Reindex;
end;

procedure TPatternMiner.AddLine(const P: TProblemLine; const Tool: string;
                                const Sess: TSession);
var
  Idx, Pos_: Integer;
begin
  if P.Bare then Exit;
  if FIndex.Find(P.Signature, Pos_) then
  begin
    Idx := NativeInt(FIndex.Objects[Pos_]);
    { Backfill the tool name if the first hit didn't have a ToolCallId
      but a later same-signature hit does. }
    if (FPatterns[Idx].Context = '') and (Tool <> '') then
      FPatterns[Idx].Context := Tool;
  end
  else
  begin
    if FCount = Length(FPatterns) then SetLength(FPatterns, 2 * FCount + 8);
    Idx := FCount;
    Inc(FCount);
    FPatterns[Idx].Signature := P.Signature;
    FPatterns[Idx].Count     := 0;
    FPatterns[Idx].Sessions  := TStringList.Create;
    FPatterns[Idx].Sessions.Sorted     := True;
    FPatterns[Idx].Sessions.Duplicates := dupIgnore;
    FPatterns[Idx].Sample    := P.Line;
    FPatterns[Idx].Kind      := P.Kind;
    FPatterns[Idx].Context   := Tool;
    FPatterns[Idx].FirstSeen := Sess.Meta.UpdatedAt;
    FPatterns[Idx].LastSeen  := Sess.Meta.UpdatedAt;
    FIndex.AddObject(P.Signature, TObject(NativeInt(Idx)));
  end;
  Inc(FPatterns[Idx].Count);
  FPatterns[Idx].Sessions.Add(Sess.Meta.Id);
  if Sess.Meta.UpdatedAt > FPatterns[Idx].LastSeen then
    FPatterns[Idx].LastSeen := Sess.Meta.UpdatedAt;
  if (FPatterns[Idx].FirstSeen = 0) or
     ((Sess.Meta.UpdatedAt > 0) and (Sess.Meta.UpdatedAt < FPatterns[Idx].FirstSeen)) then
    FPatterns[Idx].FirstSeen := Sess.Meta.UpdatedAt;
end;

procedure TPatternMiner.Add(const Probs: TProblemLineArray; const Tool: string;
                            const Sess: TSession);
var
  j: Integer;
begin
  for j := 0 to High(Probs) do AddLine(Probs[j], Tool, Sess);
end;

procedure TPatternMiner.Scan(const Sess: TSession);
begin
  Scan(Sess, ResultToolNames(Sess));
end;

procedure TPatternMiner.Scan(const Sess: TSession; const Names: TArray<string>);
var
  i: Integer;
  Tool: string;
  Probs: TProblemLineArray;
begin
  for i := 0 to High(Sess.Messages) do
  begin
    if (Sess.Messages[i].Role <> mrTool) or (Sess.Messages[i].Content = '') then
      Continue;
    { Empty when the result has no id, or matches no call (older session
      JSON, a model that skipped the id) -- safer to drop the tool
      annotation than to mis-attribute. }
    if i <= High(Names) then Tool := Names[i] else Tool := '';
    Probs := ProblemLines(Tool, Sess.Messages[i].Content);
    Add(Probs, Tool, Sess);
  end;
end;

function TPatternMiner.Take: TErrorPatternArray;
begin
  SetLength(FPatterns, FCount);
  SortPatternsByCount(FPatterns);
  Result := FPatterns;
  FPatterns := nil;
  FCount := 0;
  FIndex.Clear;
end;

procedure ScanSession(const Sess: TSession; var Patterns: TErrorPatternArray);
var
  M: TPatternMiner;
begin
  M := TPatternMiner.Create;
  try
    M.Adopt(Patterns);
    M.Scan(Sess);
    Patterns := M.Take;
  finally
    M.Free;
  end;
end;

function MinePatterns(SinceDays: Integer; out Scanned: Integer;
  Progress: TLearnProgress): TErrorPatternArray;
var
  Sessions: TSessionMetaArray;
  Sess: TSession;
  SinceUnix: Int64;
  i: Integer;
  M: TPatternMiner;
begin
  Scanned := 0;
  if SinceDays > 0 then
    SinceUnix := DateTimeToUnix(Now, False) - Int64(SinceDays) * 86400
  else
    SinceUnix := 0;
  M := TPatternMiner.Create;
  try
    Sessions := ListSessions;
    for i := 0 to High(Sessions) do
    begin
      if not InWindow(SessionStamp(Sessions[i]), SinceUnix) then Continue;
      if Assigned(Progress) then Progress(Sessions[i].Id);
      Sess := TSession.Create(Sessions[i].Id);
      try
        M.Scan(Sess);
        Inc(Scanned);
      finally
        Sess.Free;
      end;
    end;
    Result := M.Take;
  finally
    M.Free;
  end;
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

const
  SigMarker    = '<!-- signature:';
  { SectionSign, not the literal glyph: FPC was transcoding the inline
    glyph through the system codepage, which left a different byte
    sequence in the constant than what TStringList.LoadFromFile
    returned, so the matcher silently failed. }
  AnchorPrefix = '## ' + SectionSign;

function NewNameList(CaseSensitive: Boolean): TStringList;
{ Anchors compare without case (they are upper case, and an operator may
  not be); signatures with it, as the miner keeps them -- otherwise
  "Error: X" would be found as "error: x" and cited under its anchor. }
begin
  Result := TStringList.Create;
  Result.CaseSensitive := CaseSensitive;
  Result.Sorted     := True;
  Result.Duplicates := dupIgnore;
end;

procedure ParseScars(Sl: TStrings; Anchors, Signed, Sigs: TStringList;
                     var SigAnchor: TArray<string>);
{ Anchors: every `## §NAME`. Signed: the anchors whose block carries a
  signature marker. Sigs: each marker's signature, its Objects an index
  into SigAnchor, the anchor of the block it sits in -- which is how a
  renamed anchor is followed. Sl is the file's text, read once by the
  caller. }
var
  i, P: Integer;
  Line, Name, Sig, Current: string;
  EndPos: Integer;
begin
  Current := '';
  for i := 0 to Sl.Count - 1 do
  begin
    Line := Trim(Sl[i]);
    if Pos(AnchorPrefix, Line) = 1 then
    begin
      Name := Trim(Copy(Line, Length(AnchorPrefix) + 1, MaxInt));
      { Drop any trailing description / annotation after the name. }
      if Pos(' ', Name) > 0 then
        Name := Copy(Name, 1, Pos(' ', Name) - 1);
      Current := Name;
      if Name <> '' then Anchors.Add(Name);
    end
    else if Pos(SigMarker, Line) = 1 then
    begin
      Sig := Trim(Copy(Line, Length(SigMarker) + 1, MaxInt));
      EndPos := Pos('-->', Sig);
      if EndPos > 0 then Sig := Trim(Copy(Sig, 1, EndPos - 1));
      if Sig = '' then Continue;
      if Current <> '' then Signed.Add(Current);
      if not Sigs.Find(Sig, P) then
      begin
        SetLength(SigAnchor, Length(SigAnchor) + 1);
        SigAnchor[High(SigAnchor)] := Current;
        Sigs.AddObject(Sig, TObject(NativeInt(High(SigAnchor))));
      end;
    end;
  end;
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
  renamed entry got duplicated on the next learn run. A file that
  cannot be read reads as empty. }
var
  Signed, Sl: TStringList;
  SigAnchor: TArray<string>;
begin
  Anchors    := NewNameList(False);
  Signatures := NewNameList(True);
  Signed     := NewNameList(False);
  Sl         := TStringList.Create;
  SigAnchor  := nil;
  try
    try
      if FileExists(Path) then
      begin
        Sl.Text := ReadFileText(Path);
        ParseScars(Sl, Anchors, Signed, Signatures, SigAnchor);
      end;
    except
      Anchors.Clear;
      Signatures.Clear;
    end;
  finally
    Signed.Free;
    Sl.Free;
  end;
end;

function WriteScars(const Path: string; const Patterns: TErrorPatternArray;
  MinSessions: Integer; DryRun: Boolean;
  out FreshCount, SkippedCount: Integer; out AnchorOf: TArray<string>): Boolean;
{ Emit / refresh workspace/memory/SCARS.md with Atlas-style stable
  §ANCHOR ids per pattern. Re-running does NOT clobber existing
  anchors -- operators routinely fill in Root cause / Do / Do NOT
  with hand-written rationale, and we'd be unfriendly to overwrite
  that work. New patterns get a fresh anchor + boilerplate + an
  embedded `<!-- signature: ... -->` marker. (Refresh of See: counts
  on existing anchors is a follow-up; for v1 the operator can drop
  the file and re-run for full re-extraction.) The counts are only
  handed back once the file is written, so a failed write never
  reports anchors it did not add. }
var
  Sl, Anchors, Signed, Sigs: TStringList;
  SigAnchor: TArray<string>;
  i, P, n, Fresh, Skipped: Integer;
  Anchor, Base, Sig: string;
begin
  Result := False;
  FreshCount := 0;
  SkippedCount := 0;
  SetLength(AnchorOf, Length(Patterns));
  for i := 0 to High(AnchorOf) do AnchorOf[i] := '';
  Fresh := 0;
  Skipped := 0;
  SigAnchor := nil;
  Sl := TStringList.Create;
  Anchors := NewNameList(False);
  Signed := NewNameList(False);
  Sigs := NewNameList(True);
  try
    try
      { One read: what is parsed is what is appended to. }
      if FileExists(Path) then
      begin
        Sl.Text := ReadFileText(Path);
        ParseScars(Sl, Anchors, Signed, Sigs, SigAnchor);
      end
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

      for i := 0 to High(Patterns) do
      begin
        if not PassesThreshold(Patterns[i], MinSessions) then Continue;
        Sig := Patterns[i].Signature;

        { Known by its signature: left alone, the operator's anchor (renamed
          or not) is the one to cite. }
        if Sigs.Find(Sig, P) then
        begin
          AnchorOf[i] := SigAnchor[NativeInt(Sigs.Objects[P])];
          Inc(Skipped);
          Continue;
        end;

        Anchor := MakeAnchorName(Sig);
        { A hand-written block with this anchor and no marker: taken to be
          this pattern, as it was before markers existed. }
        if (Anchors.IndexOf(Anchor) >= 0) and (Signed.IndexOf(Anchor) < 0) then
        begin
          AnchorOf[i] := Anchor;
          Signed.Add(Anchor);   { claimed: a later pattern deriving it gets a suffix }
          Inc(Skipped);
          Continue;
        end;
        { Held by another pattern -- MakeAnchorName keeps five words, so two
          refusals of two different commands can derive the same one. }
        Base := Anchor;
        n := 2;
        while Anchors.IndexOf(Anchor) >= 0 do
        begin
          Anchor := Base + '-' + IntToStr(n);
          Inc(n);
        end;

        { SectionSign, so the bytes we emit here match the ones ParseScars
          looks for via AnchorPrefix. }
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
        if Patterns[i].Kind = pkMisuse then
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

        { In-run dedup: a later pattern with this signature is this one,
          and a later one deriving this anchor gets the next suffix. }
        Anchors.Add(Anchor);
        Signed.Add(Anchor);
        SetLength(SigAnchor, Length(SigAnchor) + 1);
        SigAnchor[High(SigAnchor)] := Anchor;
        Sigs.AddObject(Sig, TObject(NativeInt(High(SigAnchor))));
        if not DryRun then AnchorOf[i] := Anchor;
        Inc(Fresh);
      end;

      if (Fresh > 0) and not DryRun then
      begin
        if not DirectoryExists(ExtractFilePath(Path)) then
          ForceDirectories(ExtractFilePath(Path));
        WriteFileText(Path, Sl.Text);
      end;
      FreshCount := Fresh;
      SkippedCount := Skipped;
      Result := True;
    except
      on E: Exception do
      begin
        { Unreadable or unwritable: nothing added, nothing to cite. }
        for i := 0 to High(AnchorOf) do AnchorOf[i] := '';
        Result := False;
      end;
    end;
  finally
    Sl.Free;
    Anchors.Free;
    Signed.Free;
    Sigs.Free;
  end;
end;

end.
