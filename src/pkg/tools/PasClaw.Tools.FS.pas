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

{ UseHashline controls fs_read's default output format and whether the
  hashline-only tools (fs_edit_hashline, fs_grep) get registered at all.
  Default True. Set False from a command with --no-hashline. }
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
  Plain: Boolean;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'path', Path) then
  begin
    ErrMsg := 'missing required argument: path';
    Exit('');
  end;
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
  { When hashline is disabled at register time, force plain regardless of
    the per-call flag: there's no fs_edit_hashline registered to consume
    a header, so emitting one would just confuse the model. The per-call
    plain=true escape hatch still works in hashline-on mode. }
  if not GHashlineEnabled then
    Plain := True
  else
    Plain := ParseBoolArg(ArgsJSON, 'plain', False);
  if Plain then
    Result := Body
  else
    Result := FormatHashlineRead(Path, Body);
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
              're-emit fs_write with the full content as a string, or use fs_edit_hashline ' +
              'to apply incremental edits. Pass "content":"" explicitly to clear a file.';
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

procedure RegisterFSTools(R: TToolRegistry; UseHashline: Boolean);
var
  T: TTool;
begin
  GHashlineEnabled := UseHashline;

  T.Name := 'fs_read';
  if UseHashline then
  begin
    T.Description := 'Read a file. Returns hashline format: a ' + HL_FILE_PREFIX +
                     'path#hash header followed by LINENO:line per source line. Pass {"plain":true} for raw bytes.';
    T.Schema      := '{"type":"object","properties":{"path":{"type":"string"},"plain":{"type":"boolean","description":"Return raw file bytes instead of hashline-prefixed output."}},"required":["path"]}';
  end
  else
  begin
    T.Description := 'Read the contents of a file from the local filesystem.';
    T.Schema      := '{"type":"object","properties":{"path":{"type":"string","description":"Absolute or relative path to the file."}},"required":["path"]}';
  end;
  T.Handler  := Tool_FSRead;
  T.IsCore   := True;
  T.Category := tcReadOnly;
  R.Register(T);

  T.Name := 'fs_write';
  if UseHashline then
    T.Description := 'Write a string to a file (overwrites). Creates parent dirs. ' +
                     'Strips hashline LINENO: prefixes from `content` when every non-empty line carries one.'
  else
    T.Description := 'Write a string to a file (overwrites). Creates parent dirs.';
  T.Schema   := '{"type":"object","properties":{"path":{"type":"string"},"content":{"type":"string"}},"required":["path","content"]}';
  T.Handler  := Tool_FSWrite;
  T.IsCore   := True;
  T.Category := tcMutating;
  R.Register(T);

  T.Name        := 'fs_list';
  T.Description := 'List entries in a directory. Returns "d name" or "- name  size" lines.';
  T.Schema      := '{"type":"object","properties":{"path":{"type":"string"}},"required":["path"]}';
  T.Handler     := Tool_FSList;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);

  { Hashline-only tools: skip registration entirely when UseHashline is False
    so the model never sees them in the tool list and doesn't try to call
    fs_edit_hashline with a hashless patch that we'd reject. }
  if UseHashline then
  begin
    T.Name        := 'fs_edit_hashline';
    T.Description := 'Apply a hashline-format patch. Begins with a ' + HL_FILE_PREFIX +
                     'path#hash header, then one or more blocks. Each block is an anchor line ' +
                     'that is JUST the line number(s) -- "42:" for one line, "7-10:" for a ' +
                     'range -- with NOTHING after the colon. Do NOT copy fs_read''s "N:content" ' +
                     'display onto the anchor (write "42:", not "42:  the old text"). The ' +
                     'anchor is followed by payload lines, and EVERY payload line must start ' +
                     'with its own marker: ' + HL_PAYLOAD_REPLACE +
                     ' to replace, ' + HL_PAYLOAD_ABOVE + ' to insert above the anchor, ' +
                     HL_PAYLOAD_BELOW + ' to insert below. A multi-line replacement repeats ' +
                     HL_PAYLOAD_REPLACE + ' on every line (a 3-line replacement has three ' +
                     HL_PAYLOAD_REPLACE + ' lines) -- never a bare line. Example: "' +
                     HL_FILE_PREFIX + 'foo.pas#ab12" / "10:" / "' + HL_PAYLOAD_REPLACE +
                     '  new line 10 text". The header hash must match the file on disk; ' +
                     'stale patches abort without writing.';
    T.Schema      := '{"type":"object","properties":{"patch":{"type":"string","description":"Hashline-format patch text."}},"required":["patch"]}';
    T.Handler     := Tool_FSEditHashline;
    T.IsCore      := True;
    T.Category    := tcMutating;
    R.Register(T);

    T.Name        := 'fs_grep';
    T.Description := 'Search files for a substring. Recursive when path is a directory. ' +
                     'Skips dotdirs, well-known build/VCS/deps dirs (.git, node_modules, target, build, ' +
                     'dist, vendor, .venv, __pycache__, .gradle, .next), binary files (NUL-byte detection ' +
                     'in first 1 KiB), and files larger than max_file_bytes (default 10 MiB). Returns ' +
                     'hashline-formatted matches (one section per file, header + LINENO:line per match) ' +
                     'so you can paste anchors directly into fs_edit_hashline.';
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
    R.Register(T);
  end;
end;

end.
