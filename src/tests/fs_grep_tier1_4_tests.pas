program fs_grep_tier1_4_tests;
(*
  Pin the four ripgrep-inspired fs_grep optimisations as observable
  behaviour, not just timing.

    Tier 1  Defer ComputeFileHash until first match in a file.
            Not directly observable in output (the hash is still
            correct when a match DOES happen). Covered by the
            general correctness tests -- if we broke deferral the
            existing match output would still be right.

    Tier 2  Hardcoded skip-dirs (.git, node_modules, target, ...).
            Test by seeding a temp tree with one of these
            containing a unique pattern and asserting fs_grep
            does NOT find it.

    Tier 3  Binary file detection. Seed a file with embedded NUL
            byte in the first 1024 bytes AND the pattern; assert
            the file is silently skipped.

    Tier 4  File-size cap. Seed an oversize file; assert it's
            skipped when default cap applies AND included when
            max_file_bytes overrides upward.

  Strategy: spin a unique-per-run temp dir under SysUtils.GetTempDir,
  populate fixtures, drive Tool_FSGrep via its public handler with
  hand-built JSON args, clean up. No model, no provider, no
  PasClaw runtime beyond the FS tool registry.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.FS;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 200) + '")');
end;

procedure AssertNotContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) > 0 then
    Fail_(Msg + ' (unwanted needle "' + Needle +
          '" found in "' + Copy(Haystack, 1, 200) + '")');
end;

procedure WriteText(const Path, Content: string);
var
  F: TFileStream;
begin
  F := TFileStream.Create(Path, fmCreate);
  try
    if Length(Content) > 0 then
      F.WriteBuffer(Content[1], Length(Content));
  finally
    F.Free;
  end;
end;

function MakeTempDir(const Tag: string): string;
begin
  Result := IncludeTrailingPathDelimiter(SysUtils.GetTempDir) +
            'pasclaw-fsgrep-' + Tag + '-' +
            IntToStr(Random(MaxInt));
  ForceDirectories(Result);
end;

procedure DeleteTree(const Dir: string);
var
  SR: TSearchRec;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  begin
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) <> 0 then
          DeleteTree(JoinPath(Dir, SR.Name))
        else
          DeleteFile(JoinPath(Dir, SR.Name));
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;
  RemoveDir(Dir);
end;

function CallGrep(const Path, Pattern: string;
                  MaxFileBytes: Int64 = -1): string;
var
  Reg: TToolRegistry;
  Tool: TTool;
  Args, ErrMsg: string;
begin
  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);
    if not Reg.Find('fs_grep', Tool) then
      Fail_('fs_grep not registered');
    if MaxFileBytes < 0 then
      Args := Format('{"path":"%s","pattern":"%s"}',
                     [StringReplace(Path, '\', '\\', [rfReplaceAll]), Pattern])
    else
      Args := Format('{"path":"%s","pattern":"%s","max_file_bytes":%d}',
                     [StringReplace(Path, '\', '\\', [rfReplaceAll]),
                      Pattern, MaxFileBytes]);
    Result := Tool.Handler(Args, ErrMsg);
    if ErrMsg <> '' then
      Fail_('fs_grep returned error: ' + ErrMsg);
  finally
    Reg.Free;
  end;
end;

procedure TestSkipsBlockedDirsByName;
var
  Root, Got: string;
const
  UniqueMarker = 'FsGrepTier2Marker_TRIPWIRE';
begin
  Root := MakeTempDir('skipdirs');
  try
    { Marker in a clean place we should find. }
    WriteText(JoinPath(Root, 'good.txt'), 'header'#10 + UniqueMarker + #10);

    { Same marker inside each blocked directory -- should be ignored. }
    ForceDirectories(JoinPath(Root, 'node_modules'));
    WriteText(JoinPath(Root, 'node_modules' + PathDelim + 'inner.txt'),
              UniqueMarker);
    ForceDirectories(JoinPath(Root, 'target'));
    WriteText(JoinPath(Root, 'target' + PathDelim + 'inner.txt'),
              UniqueMarker);
    ForceDirectories(JoinPath(Root, '__pycache__'));
    WriteText(JoinPath(Root, '__pycache__' + PathDelim + 'inner.txt'),
              UniqueMarker);

    Got := CallGrep(Root, UniqueMarker);
    AssertContains(Got, 'good.txt',
                   'match in non-blocked dir surfaces');
    AssertNotContains(Got, 'node_modules',
                      'node_modules path NOT in output');
    AssertNotContains(Got, 'target' + PathDelim + 'inner',
                      'target/inner NOT in output');
    AssertNotContains(Got, '__pycache__',
                      '__pycache__ NOT in output');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestSkipsBinaryByNULDetection;
var
  Root, Got, Binary: string;
const
  Marker = 'FsGrepTier3Marker_TRIPWIRE';
begin
  Root := MakeTempDir('binary');
  try
    { Text file with the marker -- found. }
    WriteText(JoinPath(Root, 'text.txt'), Marker + ' lives here');

    { "Binary" file: NUL byte in the first kilobyte alongside the
      marker. Source code never has embedded NUL; the model would
      get noise from the bytes anyway. }
    Binary := 'header'#10'something'#0'more text with ' + Marker;
    WriteText(JoinPath(Root, 'image.bin'), Binary);

    Got := CallGrep(Root, Marker);
    AssertContains(Got, 'text.txt',
                   'text-file match surfaces');
    AssertNotContains(Got, 'image.bin',
                      'binary file silently skipped (NUL-byte check)');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestSkipsLargeFileAtDefaultCap;
var
  Root, Got, Big: string;
const
  Marker = 'FsGrepTier4Marker_TRIPWIRE';
  { 11 MiB > 10 MiB default cap. Building a 11 MiB AnsiString in
    one shot is fine memory-wise on every supported platform. }
  BigSize = 11 * 1024 * 1024;
begin
  Root := MakeTempDir('largefile');
  try
    WriteText(JoinPath(Root, 'small.txt'), Marker);
    SetLength(Big, BigSize);
    FillChar(Big[1], BigSize, Ord('A'));
    { Put the marker inside so the file would match if scanned. }
    Move(Marker[1], Big[BigSize - Length(Marker) + 1], Length(Marker));
    WriteText(JoinPath(Root, 'huge.log'), Big);

    Got := CallGrep(Root, Marker);
    AssertContains(Got, 'small.txt',
                   'small file match surfaces');
    AssertNotContains(Got, 'huge.log',
                      'oversize file skipped at default 10 MiB cap');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestRaisingCapIncludesLargeFile;
var
  Root, Got, Big: string;
const
  Marker = 'FsGrepTier4RaiseCapMarker_TRIPWIRE';
  BigSize = 11 * 1024 * 1024;
begin
  Root := MakeTempDir('largefile-raised');
  try
    SetLength(Big, BigSize);
    FillChar(Big[1], BigSize, Ord('A'));
    Move(Marker[1], Big[BigSize - Length(Marker) + 1], Length(Marker));
    WriteText(JoinPath(Root, 'huge.log'), Big);

    { Override the cap so the same file is now in scope. }
    Got := CallGrep(Root, Marker, 20 * 1024 * 1024);
    AssertContains(Got, 'huge.log',
                   'oversize file IS scanned when max_file_bytes is raised');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestEmptyResultRendersClean;
var
  Root, Got: string;
begin
  Root := MakeTempDir('empty');
  try
    WriteText(JoinPath(Root, 'a.txt'), 'no match here');
    Got := CallGrep(Root, 'absent_pattern_xyz');
    AssertContains(Got, 'no matches',
                   'zero-match result has friendly placeholder');
  finally
    DeleteTree(Root);
  end;
end;

procedure TestMatchOutputUnchangedForHitFiles;
{ Sanity that tier-1 (deferred hash) still emits the correct
  hashline header when a file actually matches. The header is what
  fs_edit_hashline parses for the file-hash check; getting it wrong
  would silently break the edit path even if grep "ran fast". }
var
  Root, Got: string;
begin
  Root := MakeTempDir('hashok');
  try
    WriteText(JoinPath(Root, 'src.pas'),
              'line one'#10'line with NEEDLE'#10'line three');
    Got := CallGrep(Root, 'NEEDLE');
    AssertContains(Got, '¶', 'hashline ¶ prefix present');
    AssertContains(Got, 'src.pas#', 'path + # separator present');
    AssertContains(Got, '2:line with NEEDLE',
                   'matching line surfaces with correct line number');
  finally
    DeleteTree(Root);
  end;
end;

begin
  Randomize;
  TestSkipsBlockedDirsByName;
  WriteLn('  ok: tier 2 -- blocked dirs (.git/node_modules/target/...) skipped');
  TestSkipsBinaryByNULDetection;
  WriteLn('  ok: tier 3 -- binary files (NUL byte) skipped');
  TestSkipsLargeFileAtDefaultCap;
  WriteLn('  ok: tier 4 -- 11 MiB file skipped at default 10 MiB cap');
  TestRaisingCapIncludesLargeFile;
  WriteLn('  ok: tier 4 -- raising max_file_bytes brings file back in scope');
  TestEmptyResultRendersClean;
  WriteLn('  ok: zero-match result still renders friendly placeholder');
  TestMatchOutputUnchangedForHitFiles;
  WriteLn('  ok: tier 1 -- deferred-hash header still correct for matched files');
  WriteLn('PASS');
end.
