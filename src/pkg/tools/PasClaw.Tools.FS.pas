(*
  PasClaw.Tools.FS - built-in filesystem tools: fs_read, fs_write, fs_list,
  fs_edit_hashline, fs_grep. Every path argument is fed through
  PasClaw.Tools.Sandbox before the underlying file operation runs;
  when sandbox.restrict_to_workspace is set in config.json, reads and
  writes outside the workspace (modulo allow_read_paths /
  allow_write_paths) are refused with a Reason the model sees.

  fs_read emits hashline-prefixed output by default -- each file body is
  preceded by a ¶path#hash header and every line is prefixed with
  LINENO:. That format is the input contract for fs_edit_hashline, which
  applies anchored diff operations without needing the model to reproduce
  the original text. Pass plain=true in the JSON args to get raw bytes
  back instead.
*)
unit PasClaw.Tools.FS;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

{ UseHashline controls fs_read's default output format (hashline-prefixed
  vs raw bytes) and whether fs_edit_hashline gets registered. As of
  PR #314 fs_grep registers UNCONDITIONALLY -- its six ripgrep-inspired
  optimisations (skip lists, BMH, binary detection, byte-walking,
  file-size cap, deferred hashing) make it 10-50x faster than
  shell_exec grep on real codebases, and on Windows there's no shell
  grep at all. Default True. Set False from a command with
  --no-hashline or from config hashline_enabled: false. }
procedure RegisterFSTools(R: TToolRegistry; UseHashline: Boolean = True);

implementation

uses
  Masks,
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Hashline,
  PasClaw.Tools.Sandbox,
  PasClaw.Checkpoints;

var
  GHashlineEnabled: Boolean = True;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if not Obj.Has(Field) then Exit;
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function HasJSONKey(const ArgsJSON, Field: string): Boolean;
{ Returns True iff the JSON object actually contains the key.
  Distinct from ParseStringArg, which returns False both when the key
  is missing AND when its value is the empty string. fs_write needs
  the distinction: a missing `content` is almost always a truncated
  tool call (Anthropic hits max_tokens mid-tool_use generation and
  returns partial JSON) and silently writing 0 bytes would clobber the
  user's file. A present-but-empty `content` is a legitimate
  "clear the file" request. }
var
  Obj: TJsonObject;
begin
  Result := False;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      Result := Obj.Has(Field);
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseBoolArg(const ArgsJSON, Field: string; Default: Boolean): Boolean;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetBool(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function ParseInt64Arg(const ArgsJSON, Field: string; Default_: Int64): Int64;
var
  Obj: TJsonObject;
begin
  Result := Default_;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default_);
    finally
      Obj.Free;
    end;
  except
    Result := Default_;
  end;
end;

function IsBlockedGrepDir(const Name: string): Boolean;
{ ripgrep-style hardcoded skip list. The model never wants
  fs_grep results from .git/, node_modules/, etc. -- they're
  pure noise for project-level queries. Cuts directory walk
  time by ~10x on a typical repo where the bulk of file count
  lives under these dirs. Operators with non-standard layouts
  who genuinely need to grep into one of these can pass an
  explicit Path pointing INTO it (the skip list only kicks
  during recursion, not at the user-supplied Root). }
const
  BlockedDirs: array[0..11] of string = (
    '.git', '.hg', '.svn',                  { VCS }
    'node_modules',                          { JS/TS deps }
    'target',                                { Rust / Java build }
    'build',                                 { generic build dir }
    'dist',                                  { JS publish output }
    'vendor',                                { Go / PHP deps }
    '.venv',                                 { Python venv }
    '__pycache__',                           { Python bytecode }
    '.gradle',                               { Gradle cache }
    '.next'                                  { Next.js build }
  );
var
  i: Integer;
begin
  for i := Low(BlockedDirs) to High(BlockedDirs) do
    if SameText(Name, BlockedDirs[i]) then Exit(True);
  Result := False;
end;

function LooksBinary(const Body: string): Boolean;
{ ripgrep-style binary detection: peek at the first 1024 bytes
  for a NUL. Source code never embeds NUL; PDFs / PNGs / zips /
  .exe / .so all do at the file header. Cheap O(1024) scan that
  saves the per-line allocation work on the (often majority)
  files where the model has no use for the contents anyway. }
var
  N, i: Integer;
begin
  N := Length(Body);
  if N > 1024 then N := 1024;
  for i := 1 to N do
    if Body[i] = #0 then Exit(True);
  Result := False;
end;

function Tool_FSRead(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path, Body, Reason: string;
  Hashline: Boolean;
  StartLn, EndLn, Total, i: Integer;
  Lines: TStringList;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Path := ResolveWorkspacePath(Path);
  if not CanReadPath(Path, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  if not FileExists(Path) then
  begin
    ErrMsg := 'no such file: ' + Path;
    Exit('');
  end;
  Body := ReadFileText(Path);
  { Optional line range (C2): a grep_files hit gives the line number; the
    follow-up read can be surgical instead of swallowing the whole file
    into history. 1-based inclusive; bounds are clamped; range implies
    plain output (hashline headers hash the WHOLE file, so a sliced body
    must not carry one). }
  StartLn := Integer(ParseInt64Arg(ArgsJSON, 'start_line', 0));
  EndLn   := Integer(ParseInt64Arg(ArgsJSON, 'end_line', 0));
  if (StartLn > 0) or (EndLn > 0) then
  begin
    Lines := TStringList.Create;
    try
      Lines.LineBreak := #10;
      Lines.StrictDelimiter := True;
      Lines.Text := StringReplace(Body, #13, '', [rfReplaceAll]);
      Total := Lines.Count;
      { Empty file: the clamps below would drive StartLn to 0 and the
        slice loop into Lines[-1] (range-check error). Say it plainly. }
      if Total = 0 then Exit('(empty file: 0 lines)');
      if StartLn < 1 then StartLn := 1;
      if (EndLn < 1) or (EndLn > Total) then EndLn := Total;
      if StartLn > Total then StartLn := Total;
      if EndLn < StartLn then EndLn := StartLn;
      Body := '';
      for i := StartLn to EndLn do
      begin
        if Body <> '' then Body := Body + #10;
        Body := Body + Lines[i - 1];
      end;
      Exit(Format('(lines %d-%d of %d)', [StartLn, EndLn, Total]) + #10 + Body);
    finally
      Lines.Free;
    end;
  end;
  { Plain text is the default -- clean content is what edit_file's
    old_text/new_text string replacement matches against, and it's what
    smaller models handle best. The hashline #hash + LINENO:line format is
    now OPT-IN via a hashline:true arg (mirrors edit_file's advanced patch
    mode), and only when hashline was enabled at register time (otherwise
    there's no patch consumer, so a header would just be noise). The legacy
    plain:true arg is still accepted and, since plain is now the default,
    is a harmless no-op. }
  Hashline := GHashlineEnabled and ParseBoolArg(ArgsJSON, 'hashline', False);
  if Hashline then
    Result := FormatHashlineRead(Path, Body)
  else
    Result := Body;
end;

function Tool_FSWrite(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path, Content, Reason: string;
  Lines: TStringList;
  Stripped: Boolean;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Path := ResolveWorkspacePath(Path);
  if not CanWritePath(Path, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  if not HasJSONKey(ArgsJSON, 'content') then
  begin
    { A missing `content` key almost always means the model''s response
      was truncated mid-tool_call (Anthropic / OpenAI hit max_tokens
      during tool_use generation and returned the partial JSON). The
      old behavior dutifully treated the missing field as the empty
      string and overwrote the file with 0 bytes -- destroying the
      user''s content with no error signal to the model, which then
      retried the same truncated call in a loop. Refuse the call so
      the model gets feedback and either re-emits with full content or
      switches to fs_edit_hashline for incremental writes. Pass
      "content":"" explicitly to legitimately clear a file. }
    ErrMsg := 'missing required argument: content. ' +
              'If your previous response was truncated mid-tool_call (model hit max_tokens), ' +
              're-emit write_file with the full content as a string, or build the file ' +
              'incrementally with append_file / edit_file. Pass "content":"" explicitly to clear a file.';
    Exit('');
  end;
  ParseStringArg(ArgsJSON, 'content', Content);
  { Defensive: strip hashline LINE: prefixes if the model copied them
    in from fs_read output. Only strips when every non-empty line has
    one -- so a real ratio like "42:00" won't be mangled. }
  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := StringReplace(Content, #13, '', [rfReplaceAll]);
    Stripped := StripHashlinePrefixes(Lines);
    if Stripped then Content := Lines.Text;
  finally
    Lines.Free;
  end;
  try
    { Checkpoint hook: snapshot the file's current bytes BEFORE we
      overwrite. No-op when checkpoints are disabled, when the file
      didn't exist (the model is creating it; /undo leaves new files
      in place), or when we already snapshotted this path earlier in
      the same turn. See PasClaw.Checkpoints for the storage layout. }
    SnapshotBeforeWrite(Path);
    WriteFileText(Path, Content);
    if Stripped then
      Result := Format('wrote %d bytes to %s (stripped hashline prefixes)', [Length(Content), Path])
    else
      Result := Format('wrote %d bytes to %s', [Length(Content), Path]);
  except
    on E: Exception do
    begin
      ErrMsg := E.Message;
      Result := '';
    end;
  end;
end;

function Tool_FSEditHashline(const ArgsJSON: string; out ErrMsg: string): string;
{ Apply a hashline-format patch to one or more files. The patch text carries
  its own ¶path#hash headers; we read each referenced file, validate the
  header hash matches what's on disk, apply the edits to an in-memory
  buffer, and only write any file once every section has validated and
  applied successfully. That keeps the stale-or-out-of-range abort path
  truly all-or-nothing -- a later section failing can't leave an earlier
  section's file mutated. }
type
  TPlan = record
    Path:      string;
    NewBody:   string;
    EditCount: Integer;
  end;
var
  Patch, ParseErr, ApplyErr, FileBody, NewBody, CurrentHash: string;
  Sections: THLSectionArray;
  Plans: array of TPlan;
  i: Integer;
  Sb: TStringBuilder;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'patch', Patch) then
  begin
    ErrMsg := 'missing required argument: patch';
    Exit('');
  end;
  if not ParseHashlinePatch(Patch, Sections, ParseErr) then
  begin
    ErrMsg := 'patch parse: ' + ParseErr;
    Exit('');
  end;
  if Length(Sections) = 0 then
  begin
    ErrMsg := 'patch contained no sections; expected one or more lines starting with ' + HL_FILE_PREFIX + 'path#hash';
    Exit('');
  end;

  { Resolve each section's ¶path against the workspace so a relative header
    (¶index.html#hash) lands in the same place read_file / write_file do. }
  for i := 0 to High(Sections) do
    Sections[i].Path := ResolveWorkspacePath(Sections[i].Path);

  { Pass 1: validate every section and stage the new body in memory.
    No writes happen during this pass, so a stale hash / missing file /
    out-of-range anchor on any section leaves the disk untouched. }
  SetLength(Plans, Length(Sections));
  for i := 0 to High(Sections) do
  begin
    { Enforce the contract: every section header must carry a #hash so
      we can verify the file hasn't drifted since the model read it.
      ParseHashlinePatch accepts hashless ¶path headers for the format
      library's other consumers (streaming previews, abbreviated diffs),
      but at the tool layer we refuse them -- applying line-anchored
      edits without verifying the file version is exactly the silent
      corruption hashline was designed to prevent. }
    if not Sections[i].HasFileHash then
    begin
      ErrMsg := Format('section %d (%s): header is missing %shash; re-read the file with fs_read and use the returned %spath%shash header',
                       [i + 1, Sections[i].Path,
                        HL_FILE_HASH_SEP, HL_FILE_PREFIX, HL_FILE_HASH_SEP]);
      Exit('');
    end;
    if not CanWritePath(Sections[i].Path, ApplyErr) then
    begin
      ErrMsg := Format('section %d (%s): %s', [i + 1, Sections[i].Path, ApplyErr]);
      Exit('');
    end;
    if not FileExists(Sections[i].Path) then
    begin
      ErrMsg := Format('section %d: no such file: %s', [i + 1, Sections[i].Path]);
      Exit('');
    end;
    FileBody := ReadFileText(Sections[i].Path);
    CurrentHash := ComputeFileHash(FileBody);
    if CurrentHash <> Sections[i].FileHash then
    begin
      ErrMsg := Format('section %d: stale patch for %s (header hash %s, file hash %s) -- re-read and rebase',
                       [i + 1, Sections[i].Path, Sections[i].FileHash, CurrentHash]);
      Exit('');
    end;
    if not ApplyHashlineEdits(FileBody, Sections[i].Edits, NewBody, ApplyErr) then
    begin
      ErrMsg := Format('section %d (%s): %s', [i + 1, Sections[i].Path, ApplyErr]);
      Exit('');
    end;
    Plans[i].Path      := Sections[i].Path;
    Plans[i].NewBody   := NewBody;
    Plans[i].EditCount := Length(Sections[i].Edits);
  end;

  { Pass 2: commit. By now every section is known to apply cleanly.
    A disk-level write failure can still partially apply, but that's a
    filesystem-atomicity concern beyond the hashline contract. }
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Plans) do
    begin
      { Same checkpoint hook as fs_write. Plans[i].Path has already
        passed the sandbox + stale-hash gates above, so the file
        definitely exists and we want its pre-edit bytes. }
      SnapshotBeforeWrite(Plans[i].Path);
      WriteFileText(Plans[i].Path, Plans[i].NewBody);
      Sb.Append(Format('%s: wrote %d bytes (%d edits)',
                       [Plans[i].Path, Length(Plans[i].NewBody), Plans[i].EditCount]));
      Sb.Append(sLineBreak);
    end;
    Result := Format('applied patch to %d file(s)'#10'%s', [Length(Plans), Sb.ToString]);
  finally
    Sb.Free;
  end;
end;

function MatchesAny(const Name: string; Globs: TStringList): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Globs = nil) or (Globs.Count = 0) then
  begin
    Result := True;
    Exit;
  end;
  for i := 0 to Globs.Count - 1 do
    if MatchesMask(Name, Globs[i]) then Exit(True);
end;

type
  TBMHShift = array[Byte] of Integer;
  TByteFold = array[Byte] of Byte;

procedure BuildAsciiLowerFold(out T: TByteFold);
{ ripgrep tier 6 helper: byte-level case-fold table. ASCII-only,
  matching what SysUtils.LowerCase did per-line in the prior
  PatLower / per-line LowerCase path. Built once per Tool_FSGrep
  call; 256 bytes; fits in L1 forever. }
var
  i: Integer;
begin
  for i := 0 to 255 do T[i] := Byte(i);
  for i := Ord('A') to Ord('Z') do T[i] := Byte(i + 32);
end;

procedure BuildBMHShift(const Pat: string; out Shift: TBMHShift);
{ Boyer-Moore-Horspool bad-character shift table. The pattern is
  assumed to be already case-folded by the caller when ignore_case
  is on (we pre-lower PatLower once in Tool_FSGrep). For each byte
  b, Shift[b] is "how far to slide the pattern forward when b
  ended a failed alignment" -- m for bytes that never appear in
  pat[1..m-1], smaller for ones that do. The LAST pattern byte is
  intentionally excluded from the loop because if the failing
  alignment ended on a byte that equals the last pat byte, we'd
  set Shift to 0 and loop forever. }
var
  i, m: Integer;
begin
  m := Length(Pat);
  for i := 0 to 255 do Shift[i] := m;
  for i := 1 to m - 1 do
    Shift[Byte(Pat[i])] := m - i;
end;

function BMHFindInBuf(Buf: PByte; n: Integer;
                      const Pat: string; m: Integer;
                      IgnoreCase: Boolean;
                      const Fold: TByteFold;
                      const Shift: TBMHShift): Boolean;
{ Returns True iff Pat occurs anywhere in Buf[0..n-1]. Text bytes
  are folded through Fold[] on the fly when IgnoreCase is on; the
  pattern bytes are stored pre-folded. Worst case O(n*m); average
  closer to O(n/m) thanks to the bad-character shift -- typical
  pattern lengths (4-12 chars like TODO, function, class, FIXME)
  hit 3-10x fewer text-byte comparisons than Pos(), which walks
  one byte at a time. }
var
  i, j: Integer;
  pb, tb: Byte;
begin
  if m = 0 then Exit(True);
  if (n = 0) or (m > n) then Exit(False);
  i := 0;
  while i <= n - m do
  begin
    j := m;
    while j > 0 do
    begin
      pb := Byte(Pat[j]);
      tb := (Buf + (i + j - 1))^;
      if IgnoreCase then tb := Fold[tb];
      if pb <> tb then Break;
      Dec(j);
    end;
    if j = 0 then Exit(True);
    tb := (Buf + (i + m - 1))^;
    if IgnoreCase then tb := Fold[tb];
    Inc(i, Shift[tb]);
  end;
  Result := False;
end;

function Tool_FSGrep(const ArgsJSON: string; out ErrMsg: string): string;
{ Recursive line scan returning hashline-formatted matches. Output looks
  like one section per matched file (¶path#hash header + N:line per
  match), so a follow-up fs_edit_hashline call can paste anchors
  verbatim.

  Speed: six ripgrep-inspired optimisations layered on top of the
  original naive scan -- walk-time filters first, then per-file
  filters, then the inner scan loop.

    Tier 1 -- defer ComputeFileHash until the first match in a file.
              Most scanned files don't match; hashing them was waste.
    Tier 2 -- skip well-known VCS / build / dependency dirs by name
              at walk time (.git, node_modules, target, build, ...).
              Cuts directory walk by ~10x on a typical project.
    Tier 3 -- binary file detection (NUL byte in first 1024 bytes).
              Source code never has embedded NUL; PDFs / PNGs /
              archives / executables always do at the file header.
              Skips them before any line-splitting work.
    Tier 4 -- file-size cap (default 10 MB, override via
              max_file_bytes arg). Prevents one accidental fs_grep
              over a multi-GB log from stalling a session.

    Tier 5 -- walk bytes, not lines:
              The naive version paid for (a) StringReplace(Body, #13,
              '') which cloned the whole body, (b) TStringList.Text :=
              ... which allocated one AnsiString per line, and (c)
              LowerCase(Lines[j]) per match-candidate line. The byte
              walker splits on #10 in place, trims trailing #13 for
              CRLF, and only Copy()s the line bytes on the rare lines
              that actually match. 3-5x faster on the per-file path.

    Tier 6 -- Boyer-Moore-Horspool substring search:
              Pos(PatLower, Line) advances one byte at a time. BMH
              precomputes a 256-entry shift table once at startup,
              and on a failed alignment slides the pattern by up to
              m bytes instead of 1. For the patterns the model
              actually queries (TODO, function, class, FIXME, def,
              return), this hits 3-10x fewer text-byte reads.
              Case-insensitive is handled by folding text bytes
              through a 256-entry ASCII lower table -- one branch
              instead of per-line LowerCase(). }
const
  { 10 MiB. Source files are kilobytes; binary blobs get caught by
    the NUL-byte check above; the cap exists for "the model accidentally
    fs_greps a giant log file" cases that would otherwise stall a
    session for tens of seconds reading megabytes off disk. }
  DefaultMaxFileBytes = 10 * 1024 * 1024;
var
  Root, Pattern, IncludeGlob: string;
  IgnoreCase: Boolean;
  MaxMatches: Int64;
  MaxFileBytes: Int64;
  Globs: TStringList;
  Sb: TStringBuilder;
  TotalMatches: Integer;
  PatLower: string;
  DirectSR: TSearchRec;
  GrepFold: TByteFold;
  GrepShift: TBMHShift;

  procedure ScanFile(const Path: string);
  var
    Body: string;
    pBody: PByte;
    BodyLen, i, LineStart, LineEnd, LineNo, m: Integer;
    Wrote: Boolean;
  begin
    if TotalMatches >= MaxMatches then Exit;
    try
      Body := ReadFileText(Path);
    except
      Exit;  { permissions -- skip silently to keep grep tractable }
    end;
    { ripgrep tier 3: skip binaries before any scan work. Source code
      never has embedded NUL bytes; PDFs / PNGs / zips / executables
      always do at the file header. }
    if LooksBinary(Body) then Exit;
    BodyLen := Length(Body);
    if BodyLen = 0 then Exit;
    m := Length(PatLower);
    if m = 0 then Exit;  { caller validates pattern non-empty, but defensive }
    pBody := PByte(@Body[1]);
    Wrote := False;
    LineStart := 0;
    LineNo := 0;
    i := 0;
    { Byte walker (tier 5). LineStart..LineEnd is the half-open
      byte range for the current line in pBody. We close the line
      either at #10 OR at end-of-buffer (last line with no trailing
      newline). CRLF -> trailing #13 is trimmed before BMH so the
      pattern doesn't have to know about line-ending convention. }
    while i <= BodyLen do
    begin
      if (i = BodyLen) or ((pBody + i)^ = $0A) then
      begin
        Inc(LineNo);
        LineEnd := i;
        if (LineEnd > LineStart) and ((pBody + LineEnd - 1)^ = $0D) then
          Dec(LineEnd);
        if BMHFindInBuf(pBody + LineStart, LineEnd - LineStart,
                        PatLower, m, IgnoreCase, GrepFold, GrepShift) then
        begin
          if not Wrote then
          begin
            if Sb.Length > 0 then Sb.Append(#10);
            { ripgrep tier 1: defer ComputeFileHash until we actually
              have a match. On a typical project scan most files have
              zero matches -- hashing them all was pure waste. }
            Sb.Append(FormatHashlineHeader(Path,
                       ComputeFileHash(Body))).Append(#10);
            Wrote := True;
          end;
          { Copy() only fires on lines that match -- which is the
            whole point of tier 5. The bulk of the body never
            allocates a per-line string. }
          Sb.Append(FormatNumberedLine(LineNo,
                    Copy(Body, LineStart + 1, LineEnd - LineStart))).Append(#10);
          Inc(TotalMatches);
          if TotalMatches >= MaxMatches then Break;
        end;
        LineStart := i + 1;
      end;
      Inc(i);
    end;
  end;

  procedure Walk(const Dir: string);
  var
    SR: TSearchRec;
    Full: string;
  begin
    if TotalMatches >= MaxMatches then Exit;
    if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          Full := JoinPath(Dir, SR.Name);
          if (SR.Attr and faDirectory) <> 0 then
          begin
            if (SR.Name <> '') and (SR.Name[1] = '.') then Continue;
            { ripgrep tier 2: skip well-known VCS / build / deps dirs
              by name. The model never wants results from node_modules
              etc. -- and these dirs dominate file count on real repos. }
            if IsBlockedGrepDir(SR.Name) then Continue;
            Walk(Full);
          end
          else
          begin
            { ripgrep tier 4: skip files over the cap WITHOUT reading
              them. TSearchRec.Size is already populated by FindFirst /
              FindNext, so no extra stat call. }
            if SR.Size > MaxFileBytes then Continue;
            if MatchesAny(SR.Name, Globs) then
              ScanFile(Full);
          end;
        until (FindNext(SR) <> 0) or (TotalMatches >= MaxMatches);
      finally
        FindClose(SR);
      end;
    end;
  end;

begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Root) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Root := ResolveWorkspacePath(Root);
  if not CanReadPath(Root, ErrMsg) then Exit('');
  if not ParseStringArg(ArgsJSON, 'pattern', Pattern) then
  begin
    ErrMsg := 'missing required argument: pattern';
    Exit('');
  end;
  IgnoreCase := ParseBoolArg(ArgsJSON, 'ignore_case', False);
  if IgnoreCase then PatLower := LowerCase(Pattern) else PatLower := Pattern;
  { ripgrep tier 6 setup: build the case-fold and BMH shift tables
    once per call. Cost is O(256 + m) bytes touched; the per-file
    BMH inner loop reads them but never mutates. }
  BuildAsciiLowerFold(GrepFold);
  BuildBMHShift(PatLower, GrepShift);
  MaxMatches := 1000;
  MaxFileBytes := ParseInt64Arg(ArgsJSON, 'max_file_bytes', DefaultMaxFileBytes);
  if MaxFileBytes <= 0 then MaxFileBytes := DefaultMaxFileBytes;
  IncludeGlob := '';
  ParseStringArg(ArgsJSON, 'include', IncludeGlob);
  Globs := TStringList.Create;
  Sb := TStringBuilder.Create;
  try
    if IncludeGlob <> '' then Globs.CommaText := IncludeGlob;
    TotalMatches := 0;
    if DirectoryExists(Root) then
      Walk(Root)
    else if FileExists(Root) then
    begin
      { ripgrep tier 4: enforce the size cap on the direct-file path
        too, not just inside Walk. Without this, `fs_grep
        path=server.log pattern=...` against an 11 MiB log would
        still scan it -- the schema and tool description promise
        files over max_file_bytes are skipped, so the direct-file
        case has to honour that contract too. SR.Size from FindFirst
        is the same stat that Walk uses; no read of the file body. }
      if FindFirst(Root, faAnyFile, DirectSR) = 0 then
        try
          if DirectSR.Size <= MaxFileBytes then ScanFile(Root);
        finally
          FindClose(DirectSR);
        end;
    end
    else
    begin
      ErrMsg := 'no such path: ' + Root;
      Exit('');
    end;
    if TotalMatches = 0 then
      Result := '(no matches)'
    else
    begin
      Result := Sb.ToString;
      {$IFDEF FPC}
      { fs_grep's TStringBuilder concatenates hashline-formatted
        per-file sections (each CP_UTF8) with #10 separators. The
        builder's ToString resets the codepage tag back to 0 ("use
        DefaultSystemCodepage"), which on Windows means CP1252 and
        the JSON serialiser would re-encode our valid UTF-8 bytes
        as if they were CP1252 chars -- the same root mojibake the
        hashline fix is undoing in FormatHashlineRead. Stamp the
        final fs_grep result CP_UTF8 too. Codex P2 on PR #238. }
      SetCodePage(RawByteString(Result), CP_UTF8, False);
      {$ENDIF}
    end;
  finally
    Sb.Free;
    Globs.Free;
  end;
end;

function Tool_FSList(const ArgsJSON: string; out ErrMsg: string): string;
var
  Path: string;
  SR: TSearchRec;
  SB: TStringBuilder;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Path := ResolveWorkspacePath(Path);
  if not CanReadPath(Path, ErrMsg) then Exit('');
  if not DirectoryExists(Path) then
  begin
    ErrMsg := 'no such directory: ' + Path;
    Exit('');
  end;
  SB := TStringBuilder.Create;
  try
    if FindFirst(JoinPath(Path, '*'), faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Name = '.') or (SR.Name = '..') then Continue;
          if (SR.Attr and faDirectory) <> 0 then
            SB.Append('d ').Append(SR.Name).Append(sLineBreak)
          else
            SB.Append('- ').Append(SR.Name).Append('  ').Append(SR.Size).Append(sLineBreak);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ ===== apply_patch: multi-file, context-anchored patches (Codex / OpenClaw
  apply_patch format) ===================================================== }
type
  TLineArray = array of string;
  TPatchOpKind = (pokAdd, pokUpdate, pokDelete);
  TPatchAction = record
    Kind:    TPatchOpKind;
    Path:    string;
    MoveTo:  string;
    Content: string;
  end;
  TPatchActionArray = array of TPatchAction;

function ApSplitLF(const S: string): TLineArray;
{ Split on LF (CRLF/CR normalised first), keeping empty segments so a
  join round-trips exactly, including a trailing newline. }
var
  T: string;
  i, StartPos: Integer;
begin
  SetLength(Result, 0);
  T := StringReplace(S, #13#10, #10, [rfReplaceAll]);
  T := StringReplace(T, #13, #10, [rfReplaceAll]);
  StartPos := 1;
  for i := 1 to Length(T) do
    if T[i] = #10 then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(T, StartPos, i - StartPos);
      StartPos := i + 1;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(T, StartPos, Length(T) - StartPos + 1);
end;

function ApJoinLF(const A: TLineArray): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(A) do
  begin
    if i > 0 then Result := Result + #10;
    Result := Result + A[i];
  end;
end;

function ApFindBlock(const Hay, Needle: TLineArray; StartAt: Integer): Integer;
var
  i, j: Integer;
  Ok: Boolean;
begin
  Result := -1;
  if Length(Needle) = 0 then Exit(StartAt);
  if StartAt < 0 then StartAt := 0;
  for i := StartAt to Length(Hay) - Length(Needle) do
  begin
    Ok := True;
    for j := 0 to High(Needle) do
      if Hay[i + j] <> Needle[j] then begin Ok := False; Break; end;
    if Ok then Exit(i);
  end;
end;

procedure ApSplice(var Arr: TLineArray; StartIdx, RemoveCount: Integer; const Ins: TLineArray);
var
  Res: TLineArray;
  i, k: Integer;
begin
  SetLength(Res, Length(Arr) - RemoveCount + Length(Ins));
  k := 0;
  for i := 0 to StartIdx - 1 do begin Res[k] := Arr[i]; Inc(k); end;
  for i := 0 to High(Ins) do begin Res[k] := Ins[i]; Inc(k); end;
  for i := StartIdx + RemoveCount to High(Arr) do begin Res[k] := Arr[i]; Inc(k); end;
  Arr := Res;
end;

procedure ApAppend(var A: TLineArray; const S: string);
begin
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

function ApStarts(const S, Prefix: string): Boolean;
begin
  Result := Copy(S, 1, Length(Prefix)) = Prefix;
end;

function ParseApplyPatch(const PatchText: string; out Actions: TPatchActionArray;
                         out ErrMsg: string): Boolean;
var
  P: TLineArray;
  n, i, Idx: Integer;
  Line, Path, MoveTo, Anchor, Reason: string;
  CurLines, OldB, NewB, Content: TLineArray;
  CurSearch: Integer;
  Act: TPatchAction;

  procedure AddAction;
  begin
    SetLength(Actions, Length(Actions) + 1);
    Actions[High(Actions)] := Act;
  end;

begin
  Result := False;
  ErrMsg := '';
  SetLength(Actions, 0);
  P := ApSplitLF(PatchText);
  { Drop the trailing '' ApSplitLF adds when the patch ends in a newline --
    a split artifact, not a blank line. }
  if (Length(P) > 0) and (P[High(P)] = '') then SetLength(P, Length(P) - 1);
  n := Length(P);
  i := 0;
  while (i < n) and (Trim(P[i]) = '') do Inc(i);
  if (i >= n) or (Trim(P[i]) <> '*** Begin Patch') then
  begin
    ErrMsg := 'apply_patch: missing "*** Begin Patch" header';
    Exit;
  end;
  Inc(i);

  while i < n do
  begin
    Line := P[i];
    if Trim(Line) = '*** End Patch' then Exit(True);

    if ApStarts(Line, '*** Add File: ') then
    begin
      Path := ResolveWorkspacePath(Trim(Copy(Line, Length('*** Add File: ') + 1, MaxInt)));
      Inc(i);
      SetLength(Content, 0);
      while (i < n) and (not ApStarts(P[i], '*** ')) do
      begin
        if P[i] = '' then
          ApAppend(Content, '')
        else if P[i][1] = '+' then
          ApAppend(Content, Copy(P[i], 2, MaxInt))
        else
        begin
          ErrMsg := 'apply_patch: Add File body lines must start with "+" (' + Path + ')';
          Exit;
        end;
        Inc(i);
      end;
      Act.Kind := pokAdd; Act.Path := Path; Act.MoveTo := '';
      Act.Content := ApJoinLF(Content);
      if Length(Content) > 0 then Act.Content := Act.Content + #10;
      AddAction;
    end
    else if ApStarts(Line, '*** Delete File: ') then
    begin
      Path := ResolveWorkspacePath(Trim(Copy(Line, Length('*** Delete File: ') + 1, MaxInt)));
      Act.Kind := pokDelete; Act.Path := Path; Act.MoveTo := ''; Act.Content := '';
      AddAction;
      Inc(i);
    end
    else if ApStarts(Line, '*** Update File: ') then
    begin
      Path := ResolveWorkspacePath(Trim(Copy(Line, Length('*** Update File: ') + 1, MaxInt)));
      Inc(i);
      MoveTo := '';
      if (i < n) and ApStarts(P[i], '*** Move to: ') then
      begin
        MoveTo := ResolveWorkspacePath(Trim(Copy(P[i], Length('*** Move to: ') + 1, MaxInt)));
        Inc(i);
      end;
      if not CanReadPath(Path, Reason) then begin ErrMsg := 'apply_patch: ' + Reason; Exit; end;
      if not FileExists(Path) then
      begin ErrMsg := 'apply_patch: no such file to update: ' + Path; Exit; end;
      CurLines := ApSplitLF(ReadFileText(Path));
      CurSearch := 0;
      while (i < n) and (not ApStarts(P[i], '*** ')) do
      begin
        if ApStarts(P[i], '@@') then
        begin
          Anchor := Trim(Copy(P[i], 3, MaxInt));
          Inc(i);
          if Anchor <> '' then
          begin
            Idx := CurSearch;
            while (Idx < Length(CurLines)) and (Pos(Anchor, CurLines[Idx]) = 0) do Inc(Idx);
            if Idx < Length(CurLines) then CurSearch := Idx;
          end;
          Continue;
        end;
        SetLength(OldB, 0); SetLength(NewB, 0);
        while (i < n) and (not ApStarts(P[i], '@@')) and (not ApStarts(P[i], '*** ')) do
        begin
          if P[i] = '' then
          begin ApAppend(OldB, ''); ApAppend(NewB, ''); end
          else
            case P[i][1] of
              '+': ApAppend(NewB, Copy(P[i], 2, MaxInt));
              '-': ApAppend(OldB, Copy(P[i], 2, MaxInt));
              ' ': begin ApAppend(OldB, Copy(P[i], 2, MaxInt)); ApAppend(NewB, Copy(P[i], 2, MaxInt)); end;
            else
              begin
                ErrMsg := 'apply_patch: hunk line must start with " ", "+" or "-" (' + Path + '): ' + P[i];
                Exit;
              end;
            end;
          Inc(i);
        end;
        if Length(OldB) = 0 then
        begin
          ErrMsg := 'apply_patch: a hunk in ' + Path + ' has no context or "-" lines to locate the edit';
          Exit;
        end;
        Idx := ApFindBlock(CurLines, OldB, CurSearch);
        if Idx < 0 then Idx := ApFindBlock(CurLines, OldB, 0);   { anchor may have over-advanced }
        if Idx < 0 then
        begin
          ErrMsg := 'apply_patch: context not found in ' + Path + ' near: ' + OldB[0];
          Exit;
        end;
        ApSplice(CurLines, Idx, Length(OldB), NewB);
        CurSearch := Idx + Length(NewB);
      end;
      Act.Kind := pokUpdate; Act.Path := Path; Act.MoveTo := MoveTo;
      Act.Content := ApJoinLF(CurLines);
      AddAction;
    end
    else if Trim(Line) = '' then
      Inc(i)   { tolerate blank lines between sections }
    else
    begin
      ErrMsg := 'apply_patch: unexpected line (want *** Add/Update/Delete File or *** End Patch): ' + Line;
      Exit;
    end;
  end;

  ErrMsg := 'apply_patch: missing "*** End Patch" terminator';
  Result := False;
end;

function Tool_FSApplyPatch(const ArgsJSON: string; out ErrMsg: string): string;
var
  PatchText, Reason: string;
  Actions: TPatchActionArray;
  i, nAdd, nUpd, nDel: Integer;
begin
  ErrMsg := '';
  if not HasJSONKey(ArgsJSON, 'patch') then
  begin
    ErrMsg := 'missing required argument: patch';
    Exit('');
  end;
  ParseStringArg(ArgsJSON, 'patch', PatchText);
  { Parse + locate every hunk BEFORE touching disk. A failure here writes
    nothing, so a multi-file patch is all-or-nothing. }
  if not ParseApplyPatch(PatchText, Actions, ErrMsg) then Exit('');

  { Sandbox-gate every target up front, still before any write. Also refuse
    create-targets that already exist: WriteFileText opens with fmCreate, so
    an "Add File" (or a "Move to" destination) pointing at an existing path
    would silently truncate the user's file and report it as "added". Make
    that a hard failure so a model that used Add File instead of Update File
    can't clobber content -- and abort before touching disk (atomic). }
  for i := 0 to High(Actions) do
  begin
    if not CanWritePath(Actions[i].Path, Reason) then
    begin ErrMsg := 'apply_patch: ' + Reason; Exit(''); end;
    if (Actions[i].MoveTo <> '') and (not CanWritePath(Actions[i].MoveTo, Reason)) then
    begin ErrMsg := 'apply_patch: ' + Reason; Exit(''); end;
    if (Actions[i].Kind = pokAdd) and FileExists(Actions[i].Path) then
    begin
      ErrMsg := 'apply_patch: Add File target already exists: ' + Actions[i].Path +
                ' (use "*** Update File" to modify an existing file)';
      Exit('');
    end;
    if (Actions[i].Kind = pokUpdate) and (Actions[i].MoveTo <> '')
       and FileExists(Actions[i].MoveTo) then
    begin
      ErrMsg := 'apply_patch: Move to target already exists: ' + Actions[i].MoveTo;
      Exit('');
    end;
  end;

  nAdd := 0; nUpd := 0; nDel := 0;
  try
    for i := 0 to High(Actions) do
      case Actions[i].Kind of
        pokAdd:
          begin
            SnapshotBeforeWrite(Actions[i].Path);
            WriteFileText(Actions[i].Path, Actions[i].Content);
            Inc(nAdd);
          end;
        pokDelete:
          begin
            SnapshotBeforeWrite(Actions[i].Path);
            if FileExists(Actions[i].Path) then DeleteFile(Actions[i].Path);
            Inc(nDel);
          end;
        pokUpdate:
          begin
            SnapshotBeforeWrite(Actions[i].Path);
            if Actions[i].MoveTo <> '' then
            begin
              SnapshotBeforeWrite(Actions[i].MoveTo);
              WriteFileText(Actions[i].MoveTo, Actions[i].Content);
              if FileExists(Actions[i].Path) then DeleteFile(Actions[i].Path);
            end
            else
              WriteFileText(Actions[i].Path, Actions[i].Content);
            Inc(nUpd);
          end;
      end;
  except
    on E: Exception do
    begin
      ErrMsg := 'apply_patch: ' + E.Message;
      Exit('');
    end;
  end;
  Result := Format('applied patch: %d added, %d updated, %d deleted', [nAdd, nUpd, nDel]);
end;

function Tool_FSFindFiles(const ArgsJSON: string; out ErrMsg: string): string;
{ find_files -- locate files by NAME with a glob, the question grep_files
  (contents) and list_dir (one level) can't answer without either a
  known-content guess or a directory-by-directory descent -- the exact
  fs_list ladder observed in real transcripts. Reuses grep_files' walk
  discipline: skip dotdirs and the well-known build/VCS/deps dirs, cap
  the result list. Matches the Glob/Grep tool pair every mature harness
  ships, so the model's priors already expect it. }
const
  DefaultMax = 100;
  HardMax    = 500;
var
  Root, Pattern, Reason, Rel: string;
  MaxResults, Found: Integer;
  Hits: TStringList;

  procedure Walk(const Dir: string);
  var
    SR: TSearchRec;
  begin
    if Found > MaxResults then Exit;
    if FindFirst(Dir + PathDelim + '*', faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
        begin
          if (SR.Name <> '') and (SR.Name[1] = '.') then Continue;
          if IsBlockedGrepDir(SR.Name) then Continue;
          Walk(Dir + PathDelim + SR.Name);
        end
        else if MatchesMask(SR.Name, Pattern) then
        begin
          Inc(Found);
          if Found <= MaxResults then
          begin
            Rel := Dir + PathDelim + SR.Name;
            if Copy(Rel, 1, Length(Root) + 1) = Root + PathDelim then
              Delete(Rel, 1, Length(Root) + 1);
            Hits.Add(Rel);
          end;
        end;
        if Found > MaxResults then Break;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  ErrMsg := '';
  Result := '';
  if not ParseStringArg(ArgsJSON, 'pattern', Pattern) then
  begin
    ErrMsg := 'missing required argument: pattern (a filename glob, e.g. "*.pas" or "webui.*")';
    Exit('');
  end;
  if not ParseStringArg(ArgsJSON, 'path', Root) then Root := '.';
  Root := ResolveWorkspacePath(Root);
  if not CanReadPath(Root, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  if not DirectoryExists(Root) then
  begin
    ErrMsg := 'no such directory: ' + Root;
    Exit('');
  end;
  Root := ExcludeTrailingPathDelimiter(Root);
  MaxResults := Integer(ParseInt64Arg(ArgsJSON, 'max_results', DefaultMax));
  if MaxResults < 1 then MaxResults := 1;
  if MaxResults > HardMax then MaxResults := HardMax;

  Found := 0;
  Hits := TStringList.Create;
  try
    Walk(Root);
    Hits.Sort;
    if Hits.Count = 0 then
      Exit(Format('no files matching "%s" under %s (names only -- use grep_files to search contents)',
                  [Pattern, Root]));
    Result := Format('%d file(s) matching "%s" under %s:', [Hits.Count, Pattern, Root])
              + #10 + TrimRight(Hits.Text);
    if Found > MaxResults then
      Result := Result + #10 + Format('... (more matches beyond the %d-result cap; narrow the pattern or path)',
                                      [MaxResults]);
  finally
    Hits.Free;
  end;
end;

function Tool_FSAppend(const ArgsJSON: string; out ErrMsg: string): string;
{ append_file: add content to the end of a file (creating it + parent dirs
  when absent). The incremental-write escape hatch -- build a large file
  across several turns instead of one oversized write_file arg that a
  provider may fail to serialise. Unlike write_file it does NOT strip
  hashline prefixes: an append chunk is content the model just generated,
  taken verbatim. }
var
  Path, Content, Existing, Reason: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Path := ResolveWorkspacePath(Path);
  if not CanWritePath(Path, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  if not HasJSONKey(ArgsJSON, 'content') then
  begin
    ErrMsg := 'missing required argument: content. If your previous response was ' +
              'truncated mid-tool_call (model hit max_tokens), re-emit append_file with ' +
              'the next chunk as a string.';
    Exit('');
  end;
  ParseStringArg(ArgsJSON, 'content', Content);
  try
    if FileExists(Path) then Existing := ReadFileText(Path) else Existing := '';
    SnapshotBeforeWrite(Path);
    WriteFileText(Path, Existing + Content);
    Result := Format('appended %d bytes to %s (now %d bytes)',
                     [Length(Content), Path, Length(Existing) + Length(Content)]);
  except
    on E: Exception do
    begin
      ErrMsg := E.Message;
      Result := '';
    end;
  end;
end;

function CountSubstr(const S, Sub: string): Integer;
{ Non-overlapping occurrence count. Sub is assumed non-empty. }
var
  Rest: string;
  P: Integer;
begin
  Result := 0;
  Rest := S;
  repeat
    P := Pos(Sub, Rest);
    if P = 0 then Break;
    Inc(Result);
    Rest := Copy(Rest, P + Length(Sub), MaxInt);
  until False;
end;

function EditContextSnippet(const NewContent: string;
                            FirstChangeOfs, NewTextLen: Integer): string;
{ Mini-diff feedback: the changed region of the NEW file body with +-3
  context lines and line numbers, so the model can confirm the edit
  landed where intended WITHOUT a follow-up full-file read_file (which
  re-injects the whole body into history). FirstChangeOfs is the 1-based
  char offset where the replacement begins. Bounded to 12 lines. }
const
  CtxLines = 3;
  MaxLines = 12;
var
  Lines: TStringList;
  i, FirstLine, LastLine, Lo, Hi, Shown: Integer;
begin
  Result := '';
  { 1-based line of the change start = newlines before it + 1. }
  FirstLine := 1;
  for i := 1 to FirstChangeOfs - 1 do
    if (i <= Length(NewContent)) and (NewContent[i] = #10) then Inc(FirstLine);
  LastLine := FirstLine;
  for i := FirstChangeOfs to FirstChangeOfs + NewTextLen - 1 do
    if (i >= 1) and (i <= Length(NewContent)) and (NewContent[i] = #10) then Inc(LastLine);

  Lines := TStringList.Create;
  try
    Lines.LineBreak := #10;
    Lines.StrictDelimiter := True;
    Lines.Text := StringReplace(NewContent, #13, '', [rfReplaceAll]);
    Lo := FirstLine - CtxLines; if Lo < 1 then Lo := 1;
    Hi := LastLine + CtxLines;  if Hi > Lines.Count then Hi := Lines.Count;
    Shown := 0;
    for i := Lo to Hi do
    begin
      if Shown >= MaxLines then
      begin
        Result := Result + Format('  ... (%d more line(s))', [Hi - i + 1]) + #10;
        Break;
      end;
      Result := Result + Format('%6d: %s', [i, Lines[i - 1]]) + #10;
      Inc(Shown);
    end;
    Result := TrimRight(Result);
    if Result <> '' then
      Result := Format('now reads (lines %d-%d):', [Lo, Hi]) + #10 + Result;
  finally
    Lines.Free;
  end;
end;

function Tool_FSEdit(const ArgsJSON: string; out ErrMsg: string): string;
{ edit_file: two modes.
    1. Plain string replacement (default): old_text -> new_text, the form
       every model authors natively. Requires a unique match unless
       replace_all is set.
    2. Hashline patch (advanced): when a `patch` argument is present, defer
       to the line-anchored applier (Tool_FSEditHashline) for precise
       multi-hunk edits. }
var
  Path, OldText, NewText, Content, Reason: string;
  ReplaceAll: Boolean;
  Cnt, FirstOfs: Integer;
begin
  ErrMsg := '';
  { Hashline mode wins when a patch is supplied. }
  if HasJSONKey(ArgsJSON, 'patch') then
    Exit(Tool_FSEditHashline(ArgsJSON, ErrMsg));

  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
  Path := ResolveWorkspacePath(Path);
  if not CanWritePath(Path, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  if not HasJSONKey(ArgsJSON, 'old_text') then
  begin
    ErrMsg := 'missing required argument: old_text. Provide old_text + new_text for a ' +
              'string replacement, or a `patch` for a hashline edit.';
    Exit('');
  end;
  ParseStringArg(ArgsJSON, 'old_text', OldText);
  { new_text may be omitted -> treated as '' (a deletion). }
  NewText := '';
  ParseStringArg(ArgsJSON, 'new_text', NewText);
  ReplaceAll := ParseBoolArg(ArgsJSON, 'replace_all', False);
  if OldText = '' then
  begin
    ErrMsg := 'old_text must not be empty';
    Exit('');
  end;
  if not FileExists(Path) then
  begin
    ErrMsg := 'no such file: ' + Path + ' (use write_file to create it)';
    Exit('');
  end;
  Content := ReadFileText(Path);
  Cnt := CountSubstr(Content, OldText);
  if Cnt = 0 then
  begin
    ErrMsg := 'old_text not found in ' + Path + '. The match must be exact, including ' +
              'whitespace and indentation; do not include read_file''s "N:" line-number ' +
              'prefixes in old_text.';
    Exit('');
  end;
  if (Cnt > 1) and (not ReplaceAll) then
  begin
    ErrMsg := Format('old_text matches %d times in %s. Add surrounding context to make it ' +
                     'unique, or pass "replace_all":true to replace every occurrence.',
                     [Cnt, Path]);
    Exit('');
  end;
  FirstOfs := Pos(OldText, Content);   { where the (first) change lands }
  if ReplaceAll then
    Content := StringReplace(Content, OldText, NewText, [rfReplaceAll])
  else
    Content := StringReplace(Content, OldText, NewText, []);
  try
    SnapshotBeforeWrite(Path);
    WriteFileText(Path, Content);
    Result := Format('edited %s (replaced %d occurrence(s))', [Path, Cnt]) + #10 +
              EditContextSnippet(Content, FirstOfs, Length(NewText));
  except
    on E: Exception do
    begin
      ErrMsg := E.Message;
      Result := '';
    end;
  end;
end;

function Tool_TodoWrite(const ArgsJSON: string; out ErrMsg: string): string;
{ todo_write -- the model's working checklist for the current task. The
  handler itself only validates and acknowledges: the REAL consumer is
  RunToolLoop (PasClaw.Tools.ToolLoop), which watches dispatched calls for
  this name, keeps the latest checklist in its per-loop progress ledger,
  and folds it back into the system prompt each iteration. That design
  needs no shared state between the tool and the loop -- the checklist
  rides in the call's own arguments -- so concurrent gateway sessions and
  subagent child loops each track their own list for free. }
var
  CL: string;
  i, Lines: Integer;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'checklist', CL) then
  begin
    ErrMsg := 'missing required argument: checklist. Pass the FULL current ' +
              'checklist as markdown "- [ ] step" / "- [x] done step" lines; ' +
              'it replaces the previous one.';
    Exit('');
  end;
  Lines := 1;
  for i := 1 to Length(CL) do
    if CL[i] = #10 then Inc(Lines);
  Result := Format('checklist recorded (%d line(s)); it is shown back to you ' +
                   'each turn in the progress ledger', [Lines]);
end;

procedure RegisterFSTools(R: TToolRegistry; UseHashline: Boolean);
var
  T: TTool;

  { Register the canonical tool T, then a hidden back-compat alias under the
    old name pointing at the same handler. Old configs / sessions / muscle-
    memory keep working; the model only ever sees the new canonical name. }
  procedure Emit(const OldName: string);
  var
    A: TTool;
  begin
    R.Register(T);
    A := T;
    A.Name := OldName;
    R.RegisterHidden(A);
  end;

begin
  GHashlineEnabled := UseHashline;

  { read_file (was fs_read) }
  T := Default(TTool);
  T.Name := 'read_file';
  if UseHashline then
  begin
    T.Description := 'Read the contents of a file. Returns plain text by default. ' +
                     'Pass {"hashline":true} for the ' + HL_FILE_PREFIX +
                     'path#hash header + LINENO:line format used to build an ' +
                     'edit_file `patch` (advanced).';
    T.Schema      := '{"type":"object","properties":{"path":{"type":"string"},' +
                     '"start_line":{"type":"integer","minimum":1,"description":"First line to return (1-based). Use with end_line to read just the region a grep_files hit pointed at."},' +
                     '"end_line":{"type":"integer","minimum":1,"description":"Last line to return (inclusive; clamped to the file end)."},' +
                     '"hashline":{"type":"boolean","description":"Return the hashline #hash+LINENO format for edit_file patch edits, instead of plain text. Ignored when a line range is set."}},"required":["path"]}';
  end
  else
  begin
    T.Description := 'Read the contents of a file from the local filesystem.';
    T.Schema      := '{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file."},' +
                     '"start_line":{"type":"integer","minimum":1,"description":"First line to return (1-based)."},' +
                     '"end_line":{"type":"integer","minimum":1,"description":"Last line to return (inclusive; clamped)."}},"required":["path"]}';
  end;
  T.Handler  := Tool_FSRead;
  T.IsCore   := True;
  T.Category := tcReadOnly;
  Emit('fs_read');

  { write_file (was fs_write) }
  T := Default(TTool);
  T.Name := 'write_file';
  if UseHashline then
    T.Description := 'Write a string to a file (overwrites). Creates parent dirs. ' +
                     'Strips hashline LINENO: prefixes from `content` when every non-empty line carries one.'
  else
    T.Description := 'Write a string to a file (overwrites). Creates parent dirs.';
  T.Schema   := '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}';
  T.Handler  := Tool_FSWrite;
  T.IsCore   := True;
  T.Category := tcMutating;
  Emit('fs_write');

  { append_file (new) -- the incremental-write escape hatch for large files. }
  T := Default(TTool);
  T.Name        := 'append_file';
  T.Description := 'Append a string to the end of a file (creates it and parent dirs when missing). ' +
                   'Use this to build a large file across several turns instead of one huge write_file ' +
                   'call, which a provider may fail to serialise.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}';
  T.Handler     := Tool_FSAppend;
  T.IsCore      := True;
  T.Category    := tcMutating;
  R.Register(T);

  { list_dir (was fs_list) }
  T := Default(TTool);
  T.Name        := 'list_dir';
  T.Description := 'List entries in a directory. Returns "d name" or "- name  size" lines.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}';
  T.Handler     := Tool_FSList;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Emit('fs_list');

  { grep_files (was fs_grep) -- registers UNCONDITIONALLY -- the six
    ripgrep-inspired optimisations (skip lists, BMH, binary detection,
    byte-walking, file-size cap, deferred hashing) make it 10-50x faster
    than shell_exec grep on real codebases, and on Windows it's the only
    grep equivalent the agent has (Windows ships no grep). }
  T := Default(TTool);
  T.Name        := 'grep_files';
  T.Description := 'Search files for a substring. Recursive when path is a directory. ' +
                   'Skips dotdirs, well-known build/VCS/deps dirs (.git, node_modules, target, build, ' +
                   'dist, vendor, .venv, __pycache__, .gradle, .next), binary files (NUL-byte detection ' +
                   'in first 1 KiB), and files larger than max_file_bytes (default 10 MiB). Returns ' +
                   'matches with LINENO:line per hit, one section per file.';
  T.Schema      := '{"type":"object","properties":{' +
                   '"path":{"type":"string"},' +
                   '"pattern":{"type":"string"},' +
                   '"ignore_case":{"type":"boolean"},' +
                   '"include":{"type":"string","description":"Comma-separated filename glob(s), e.g. *.pas,*.dpr"},' +
                   '"max_file_bytes":{"type":"integer","description":"Skip files larger than this (default 10485760 = 10 MiB). Override for grepping into giant log files."}' +
                   '},"required":["path","pattern"]}';
  T.Handler     := Tool_FSGrep;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  Emit('fs_grep');

  { find_files (new) -- locate files by NAME; the Glob half of the
    Glob/Grep pair. }
  T := Default(TTool);
  T.Name        := 'find_files';
  T.Description := 'Find files by NAME with a glob pattern (e.g. "*.pas", "webui.*", ' +
                   '"Makefile"). Searches recursively from path (default: the working ' +
                   'directory), skipping VCS/build/deps dirs, and returns matching paths ' +
                   'one per line. Use this to locate a file before reading it; use ' +
                   'grep_files to search file CONTENTS instead.';
  T.Schema      := '{"type":"object","properties":{' +
                   '"pattern":{"type":"string","description":"Filename glob: * and ? wildcards, matched against the file NAME."},' +
                   '"path":{"type":"string","description":"Directory to search from (default: the working directory)."},' +
                   '"max_results":{"type":"integer","minimum":1,"maximum":500,"description":"Cap on returned paths (default 100)."}' +
                   '},"required":["pattern"]}';
  T.Handler     := Tool_FSFindFiles;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);

  { edit_file (was fs_edit_hashline) -- now registered UNCONDITIONALLY. The
    default old_text->new_text string-replacement mode works for every
    model; the hashline `patch` mode is advanced and only advertised (in
    the schema/description) when UseHashline is on, so smaller models that
    mis-author the anchor format don't see it. The handler still accepts a
    patch either way, so the fs_edit_hashline alias keeps working. }
  T := Default(TTool);
  T.Name := 'edit_file';
  if UseHashline then
  begin
    T.Description := 'Edit a file. Default: replace an exact snippet -- pass old_text (the existing text, ' +
                     'verbatim including whitespace) and new_text. The match must be unique unless ' +
                     'replace_all is set; omit new_text to delete. Advanced: pass a hashline `patch` instead ' +
                     'for line-anchored multi-hunk edits -- first read the file with {"hashline":true} to ' +
                     'get the ' + HL_FILE_PREFIX + 'path#hash header, then send "42:" anchors + ' +
                     HL_PAYLOAD_REPLACE + '/' + HL_PAYLOAD_ABOVE + '/' + HL_PAYLOAD_BELOW +
                     ' payload markers (header hash must match disk).';
    T.Schema      := '{"type":"object","properties":{' +
                     '"path":{"type":"string"},' +
                     '"old_text":{"type":"string","description":"Exact existing text to replace (verbatim, including whitespace)."},' +
                     '"new_text":{"type":"string","description":"Replacement text. Omit to delete old_text."},' +
                     '"replace_all":{"type":"boolean","description":"Replace every occurrence instead of requiring a unique match."},' +
                     '"patch":{"type":"string","description":"Advanced: a hashline-format patch, used INSTEAD of old_text/new_text."}' +
                     '}}';
  end
  else
  begin
    T.Description := 'Edit a file by replacing an exact snippet: pass old_text (the existing text, verbatim ' +
                     'including whitespace) and new_text. The match must be unique unless replace_all is set; ' +
                     'omit new_text to delete text.';
    T.Schema      := '{"type":"object","properties":{' +
                     '"path":{"type":"string"},' +
                     '"old_text":{"type":"string","description":"Exact existing text to replace (verbatim, including whitespace)."},' +
                     '"new_text":{"type":"string","description":"Replacement text. Omit to delete old_text."},' +
                     '"replace_all":{"type":"boolean","description":"Replace every occurrence instead of requiring a unique match."}' +
                     '},"required":["path","old_text"]}';
  end;
  T.Handler  := Tool_FSEdit;
  T.IsCore   := True;
  T.Category := tcMutating;
  Emit('fs_edit_hashline');

  { todo_write -- task checklist for the progress ledger. Registered here
    (not in a unit of its own) because RegisterFSTools is the one
    registration path every surface -- CLI, TUI, serve, gateway, heartbeat,
    component -- already calls, and subagent child registries inherit it via
    the '*' expansion. tcReadOnly on purpose: updating the checklist is
    bookkeeping, so it can run in a parallel batch and never counts as
    "progress" for the ledger's nothing-written-yet nudge. }
  T := Default(TTool);
  T.Name        := 'todo_write';
  T.Description := 'Maintain your working checklist for the current task. Pass ' +
                   'the FULL checklist each call as markdown lines ("- [ ] step" / ' +
                   '"- [x] done step") -- it replaces the previous one and is shown ' +
                   'back to you every turn in the progress ledger. Write it at the ' +
                   'start of multi-step work; update it as steps complete.';
  T.Schema      := '{"type":"object","properties":{"checklist":{"type":"string",' +
                   '"description":"The complete current checklist, markdown - [ ] / - [x] lines."}},' +
                   '"required":["checklist"]}';
  T.Handler     := Tool_TodoWrite;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);

  { apply_patch (new) -- multi-file, context-anchored patches in one call. }
  T := Default(TTool);
  T.Name := 'apply_patch';
  T.Description :=
    'Apply a multi-file patch in ONE call (Codex / OpenClaw apply_patch format). ' +
    'Wrap everything between a "*** Begin Patch" line and a "*** End Patch" line. ' +
    'Inside, one or more file sections: "*** Add File: <path>" then the new content ' +
    'as lines each prefixed with "+"; "*** Delete File: <path>"; or "*** Update File: ' +
    '<path>" (optionally followed by "*** Move to: <newpath>") then hunks. In a hunk, ' +
    'optional "@@ <context>" lines help locate the region, then each change line starts ' +
    'with " " (unchanged context), "-" (remove) or "+" (add). Edits are located by their ' +
    'context and removed lines, NOT by line number. All-or-nothing: if any hunk fails to ' +
    'locate, nothing is written. Prefer this over several edit_file calls when a change ' +
    'spans multiple files or many hunks.';
  T.Schema :=
    '{"type":"object","properties":{"patch":{"type":"string",' +
    '"description":"Full patch text, from *** Begin Patch through *** End Patch."}},' +
    '"required":["patch"]}';
  T.Handler  := Tool_FSApplyPatch;
  T.IsCore   := True;
  T.Category := tcMutating;
  R.Register(T);
end;

end.
