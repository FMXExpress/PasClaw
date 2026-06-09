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
  PasClaw.Tools.Sandbox;

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

function Tool_FSGrep(const ArgsJSON: string; out ErrMsg: string): string;
{ Recursive line scan returning hashline-formatted matches. Output looks
  like one section per matched file (¶path#hash header + N:line per
  match), so a follow-up fs_edit_hashline call can paste anchors
  verbatim. }
var
  Root, Pattern, IncludeGlob: string;
  IgnoreCase: Boolean;
  MaxMatches: Int64;
  Globs: TStringList;
  Sb: TStringBuilder;
  TotalMatches: Integer;
  PatLower: string;

  procedure ScanFile(const Path: string);
  var
    Body, Header: string;
    Lines: TStringList;
    j: Integer;
    Cmp: string;
    Wrote: Boolean;
  begin
    if TotalMatches >= MaxMatches then Exit;
    try
      Body := ReadFileText(Path);
    except
      Exit;  { binary / permissions -- skip silently to keep grep tractable }
    end;
    Header := FormatHashlineHeader(Path, ComputeFileHash(Body));
    Lines := TStringList.Create;
    try
      Lines.LineBreak := #10;
      Lines.StrictDelimiter := True;
      Lines.Text := StringReplace(Body, #13, '', [rfReplaceAll]);
      Wrote := False;
      { Removed MatchCount local -- it was incremented per match but
        never read; the per-file scope made it look like a counter
        but only TotalMatches actually gates the loop. dcc64 H2077
        flagged the dead writes; removing the var keeps the code
        honest about what's being tracked. }
      for j := 0 to Lines.Count - 1 do
      begin
        if TotalMatches >= MaxMatches then Break;
        if IgnoreCase then Cmp := LowerCase(Lines[j]) else Cmp := Lines[j];
        if Pos(PatLower, Cmp) > 0 then
        begin
          if not Wrote then
          begin
            if Sb.Length > 0 then Sb.Append(#10);
            Sb.Append(Header).Append(#10);
            Wrote := True;
          end;
          Sb.Append(FormatNumberedLine(j + 1, Lines[j])).Append(#10);
          Inc(TotalMatches);
        end;
      end;
    finally
      Lines.Free;
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
            if SR.Name <> '' then
              if SR.Name[1] = '.' then Continue;  { skip dotdirs }
            Walk(Full);
          end
          else if MatchesAny(SR.Name, Globs) then
            ScanFile(Full);
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
  MaxMatches := 1000;
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
      ScanFile(Root)
    else
    begin
      ErrMsg := 'no such path: ' + Root;
      Exit('');
    end;
    if TotalMatches = 0 then
      Result := '(no matches)'
    else
      Result := Sb.ToString;
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
    T.Description := 'Apply a hashline-format patch. Patch begins with ' + HL_FILE_PREFIX +
                     'path#hash; each block is an anchor like 42: or 7-10: followed by ' +
                     '| (replace), ' + HL_PAYLOAD_ABOVE + ' (insert above), or ' +
                     HL_PAYLOAD_BELOW + ' (insert below). The header hash must match the file on disk; ' +
                     'stale patches abort without writing.';
    T.Schema      := '{"type":"object","properties":{"patch":{"type":"string","description":"Hashline-format patch text."}},"required":["patch"]}';
    T.Handler     := Tool_FSEditHashline;
    T.IsCore      := True;
    T.Category    := tcMutating;
    R.Register(T);

    T.Name        := 'fs_grep';
    T.Description := 'Search files for a substring. Recursive when path is a directory. ' +
                     'Skips dotdirs. Returns hashline-formatted matches (one section per file, header + LINENO:line per match) ' +
                     'so you can paste anchors directly into fs_edit_hashline.';
    T.Schema      := '{"type":"object","properties":{"path":{"type":"string"},"pattern":{"type":"string"},"ignore_case":{"type":"boolean"},"include":{"type":"string","description":"Comma-separated filename glob(s), e.g. *.pas,*.dpr"}},"required":["path","pattern"]}';
    T.Handler     := Tool_FSGrep;
    T.IsCore      := True;
    T.Category    := tcReadOnly;
    R.Register(T);
  end;
end;

end.
