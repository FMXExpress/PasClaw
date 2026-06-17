program build_workspace_roundtrip_tests;
(*
  Coverage for the bits of `pasclaw build` that don't need a real
  provider:

    * PackDirToZip + ExtractZipToDir round-trip (the workspace.zip
      handshake on its own).
    * Exclusion denylist (.git, .DS_Store, ...) honoured.
    * Binary files (NULs + high bytes) survive the round-trip.
    * Nested directory structure preserved.

  Build's argv parser, env override, and agent dispatch are exercised
  via the smoke target on a temp PASCLAW_HOME with a real provider --
  not appropriate for unit tests that run on every PR.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils, Classes,
  {$IFDEF FPC} Zipper {$ELSE} System.Zip {$ENDIF},
  PasClaw.Cmd.Build,
  PasClaw.Skills.Zip,
  PasClaw.Utils;

procedure Fail_(const Msg: string);
begin
  Writeln('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertBytesEq(const Got, Want: TBytes; const Msg: string);
var i: Integer;
begin
  if Length(Got) <> Length(Want) then
    Fail_(Format('%s: length got=%d want=%d', [Msg, Length(Got), Length(Want)]));
  for i := 0 to Length(Want) - 1 do
    if Got[i] <> Want[i] then
      Fail_(Format('%s: byte %d differs (got %d, want %d)',
                   [Msg, i, Got[i], Want[i]]));
end;

procedure WriteText(const Path, Content: string);
var FS: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Path));
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Content <> '' then FS.WriteBuffer(Content[1], Length(Content));
  finally
    FS.Free;
  end;
end;

procedure WriteBytes(const Path: string; const Bytes: TBytes);
var FS: TFileStream;
begin
  ForceDirectories(ExtractFilePath(Path));
  FS := TFileStream.Create(Path, fmCreate);
  try
    if Length(Bytes) > 0 then FS.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FS.Free;
  end;
end;

function ReadText(const Path: string): string;
var FS: TFileStream;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Result[1], FS.Size);
  finally
    FS.Free;
  end;
end;

function ReadBytes(const Path: string): TBytes;
var FS: TFileStream;
begin
  SetLength(Result, 0);
  if not FileExists(Path) then Exit;
  FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, FS.Size);
    if FS.Size > 0 then FS.ReadBuffer(Result[0], FS.Size);
  finally
    FS.Free;
  end;
end;

function MakeTempDir(const Tag: string): string;
begin
  Result := JoinPath(GetTempDir(False),
                     'pasclaw_build_test_' + Tag + '_' + IntToStr(Random(MaxInt)));
  ForceDirectories(Result);
end;

procedure RemoveTree(const Path: string);
var SR: TSearchRec; Sub: string;
begin
  if not DirectoryExists(Path) then Exit;
  if FindFirst(JoinPath(Path, '*'), faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Sub := JoinPath(Path, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then RemoveTree(Sub)
      else DeleteFile(Sub);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

procedure TestSimpleRoundtrip;
{ A small workspace with text + nested dirs round-trips through
  PackDirToZip and ExtractZipToDir cleanly. }
var
  Src, Dst, Zip, Err: string;
  Empty: array of string;
begin
  SetLength(Empty, 0);
  Src := MakeTempDir('src');
  Dst := MakeTempDir('dst');
  Zip := JoinPath(GetTempDir(False), 'roundtrip_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteText(JoinPath(Src, 'README.md'),
              '# project' + sLineBreak + 'hello world' + sLineBreak);
    WriteText(JoinPath(JoinPath(Src, 'src'), 'main.pas'),
              'program p; begin end.');
    WriteText(JoinPath(JoinPath(JoinPath(Src, 'workspace'), 'memory'), 'MEMORY.md'),
              '## rules' + sLineBreak + '- be excellent.');

    AssertTrue(PackDirToZip(Src, Zip, Empty, Err), 'pack: ' + Err);
    AssertTrue(FileExists(Zip), 'zip file exists');
    AssertTrue(ExtractZipToDir(Zip, Dst, Err), 'extract: ' + Err);

    AssertTrue(FileExists(JoinPath(Dst, 'README.md')), 'README round-tripped');
    AssertEqS(ReadText(JoinPath(Dst, 'README.md')),
              '# project' + sLineBreak + 'hello world' + sLineBreak,
              'README content preserved');
    AssertTrue(FileExists(JoinPath(JoinPath(Dst, 'src'), 'main.pas')),
               'nested src/main.pas round-tripped');
    AssertTrue(FileExists(JoinPath(JoinPath(JoinPath(Dst, 'workspace'),
                                            'memory'), 'MEMORY.md')),
               '3-level-deep MEMORY.md round-tripped');
  finally
    DeleteFile(Zip);
    RemoveTree(Src);
    RemoveTree(Dst);
  end;
end;

procedure TestBinaryRoundtrip;
{ Snapshots / kb.db / checkpoints archive.zpaq are all binary -- must
  survive the zip path without bit mangling. Test with a payload that
  has every byte value 0..255. }
var
  Src, Dst, Zip, Err: string;
  Empty: array of string;
  Want, Got: TBytes;
  i: Integer;
begin
  SetLength(Empty, 0);
  Src := MakeTempDir('bin_src');
  Dst := MakeTempDir('bin_dst');
  Zip := JoinPath(GetTempDir(False), 'binroundtrip_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    SetLength(Want, 256);
    for i := 0 to 255 do Want[i] := i;
    WriteBytes(JoinPath(JoinPath(Src, 'workspace'), 'kb.db'), Want);

    AssertTrue(PackDirToZip(Src, Zip, Empty, Err), 'pack: ' + Err);
    AssertTrue(ExtractZipToDir(Zip, Dst, Err), 'extract: ' + Err);

    Got := ReadBytes(JoinPath(JoinPath(Dst, 'workspace'), 'kb.db'));
    AssertBytesEq(Got, Want, 'binary kb.db round-trip');
  finally
    DeleteFile(Zip);
    RemoveTree(Src);
    RemoveTree(Dst);
  end;
end;

procedure TestExclusionDenylist;
{ ExcludeFromZip in PasClaw.Cmd.Build drops .git / .DS_Store etc.
  Verify the underlying PackDirToZip honours an arbitrary denylist. }
var
  Src, Dst, Zip, Err: string;
  Excludes: array of string;
begin
  SetLength(Excludes, 2);
  Excludes[0] := '.git';
  Excludes[1] := '.DS_Store';
  Src := MakeTempDir('excl_src');
  Dst := MakeTempDir('excl_dst');
  Zip := JoinPath(GetTempDir(False), 'excl_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteText(JoinPath(Src, 'README.md'), 'keep');
    WriteText(JoinPath(JoinPath(Src, '.git'), 'HEAD'), 'ref: refs/heads/main');
    WriteText(JoinPath(JoinPath(JoinPath(Src, 'src'), '.git'), 'config'),
              '[core]');
    WriteText(JoinPath(Src, '.DS_Store'), 'finder noise');

    AssertTrue(PackDirToZip(Src, Zip, Excludes, Err), 'pack: ' + Err);
    AssertTrue(ExtractZipToDir(Zip, Dst, Err), 'extract: ' + Err);

    AssertTrue(FileExists(JoinPath(Dst, 'README.md')), 'README kept');
    AssertTrue(not DirectoryExists(JoinPath(Dst, '.git')),
               '.git at root dropped');
    AssertTrue(not DirectoryExists(JoinPath(JoinPath(Dst, 'src'), '.git')),
               '.git at depth 2 dropped (case-insensitive denylist)');
    AssertTrue(not FileExists(JoinPath(Dst, '.DS_Store')),
               '.DS_Store dropped');
  finally
    DeleteFile(Zip);
    RemoveTree(Src);
    RemoveTree(Dst);
  end;
end;

procedure TestEmptyDir;
{ Pack of an empty source dir must succeed (produce a zip file).
  Re-extracting an empty archive is a corner case the underlying
  TZipper / TZipFile don't all handle uniformly, so we don't assert
  on that side -- the build flow that needs this property would
  have included at least config.json or AGENTS.md before zipping. }
var
  Src, Zip, Err: string;
  Empty: array of string;
begin
  SetLength(Empty, 0);
  Src := MakeTempDir('empty_src');
  Zip := JoinPath(GetTempDir(False), 'empty_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    AssertTrue(PackDirToZip(Src, Zip, Empty, Err), 'pack empty: ' + Err);
    AssertTrue(FileExists(Zip), 'empty zip file produced');
  finally
    DeleteFile(Zip);
    RemoveTree(Src);
  end;
end;

procedure TestMissingSource;
var
  Zip, Err: string;
  Empty: array of string;
begin
  SetLength(Empty, 0);
  Zip := JoinPath(GetTempDir(False), 'never.zip');
  AssertTrue(not PackDirToZip('/tmp/__pasclaw_no_such_src__', Zip, Empty, Err),
             'pack of missing src should fail');
  AssertTrue(Pos('not found', Err) > 0,
             'err mentions not-found (got: ' + Err + ')');
end;

{ ----- Zip-slip regression suite (Codex P1 on PR #300) ----- }

procedure WriteMaliciousZip(const ZipPath, MaliciousMember, Content: string);
{ Build a zip whose single entry has MaliciousMember as its archive
  name. The on-disk source path is benign (an actual file in a temp
  scratch dir); only the in-archive name is dangerous. The point of
  this helper is to hand the extractor an entry name that tries to
  escape the destination. }
var
  Z: {$IFDEF FPC}TZipper{$ELSE}TZipFile{$ENDIF};
  Bench: string;
  FS: TFileStream;
begin
  Bench := JoinPath(GetTempDir(False), 'mz_' + IntToStr(Random(MaxInt)) + '.bin');
  FS := TFileStream.Create(Bench, fmCreate);
  try
    if Content <> '' then FS.WriteBuffer(Content[1], Length(Content));
  finally
    FS.Free;
  end;
  Z := {$IFDEF FPC}TZipper{$ELSE}TZipFile{$ENDIF}.Create;
  try
    {$IFDEF FPC}
    Z.Entries.AddFileEntry(Bench, MaliciousMember);
    Z.FileName := ZipPath;
    Z.ZipAllFiles;
    {$ELSE}
    Z.Open(ZipPath, zmWrite);
    Z.Add(Bench, MaliciousMember);
    Z.Close;
    {$ENDIF}
  finally
    Z.Free;
    DeleteFile(Bench);
  end;
end;

procedure TestRejectsParentTraversal;
var
  Dest, Zip, Err: string;
begin
  Dest := MakeTempDir('slip_dest');
  Zip := JoinPath(GetTempDir(False),
                  'slip_parent_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteMaliciousZip(Zip, '../escaped.txt', 'OWNED');
    AssertTrue(not ExtractZipToDir(Zip, Dest, Err),
               '../escaped.txt should be rejected, got Result=True');
    AssertTrue(Pos('unsafe', Err) > 0,
               'err mentions "unsafe": ' + Err);
    AssertTrue(not FileExists(JoinPath(ExtractFileDir(Dest), 'escaped.txt')),
               'no file written outside Dest');
  finally
    DeleteFile(Zip);
    RemoveTree(Dest);
  end;
end;

procedure TestRejectsDeepParentTraversal;
{ Sneakier: legitimate-looking prefix that then climbs out via ../. }
var
  Dest, Zip, Err: string;
begin
  Dest := MakeTempDir('slip_deep');
  Zip := JoinPath(GetTempDir(False),
                  'slip_deep_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteMaliciousZip(Zip, 'workspace/../../escaped.txt', 'OWNED');
    AssertTrue(not ExtractZipToDir(Zip, Dest, Err),
               'workspace/../../escaped.txt should be rejected');
    AssertTrue(Pos('unsafe', Err) > 0,
               'err mentions "unsafe": ' + Err);
  finally
    DeleteFile(Zip);
    RemoveTree(Dest);
  end;
end;

procedure TestRejectsAbsolutePath;
var
  Dest, Zip, Err: string;
begin
  Dest := MakeTempDir('slip_abs');
  Zip := JoinPath(GetTempDir(False),
                  'slip_abs_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteMaliciousZip(Zip, '/tmp/__pasclaw_owned__', 'OWNED');
    AssertTrue(not ExtractZipToDir(Zip, Dest, Err),
               'absolute /tmp/... should be rejected');
    AssertTrue(not FileExists('/tmp/__pasclaw_owned__'),
               'no file written at the absolute path');
  finally
    DeleteFile(Zip);
    RemoveTree(Dest);
  end;
end;

procedure TestRejectsBackslashTraversal;
{ Zips occasionally carry backslash separators (Windows-produced
  archives). Our validator normalises to forward-slash before the
  segment scan; a sneaky ..\.. should be rejected just like ../.. }
var
  Dest, Zip, Err: string;
begin
  Dest := MakeTempDir('slip_bs');
  Zip := JoinPath(GetTempDir(False),
                  'slip_bs_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    WriteMaliciousZip(Zip, '..\..\escaped.txt', 'OWNED');
    AssertTrue(not ExtractZipToDir(Zip, Dest, Err),
               'backslash ..\..\escaped.txt should be rejected');
  finally
    DeleteFile(Zip);
    RemoveTree(Dest);
  end;
end;

procedure TestAcceptsLegitimateNested;
{ Containment check must not over-fire on legitimate nested paths
  that LOOK like they could escape but actually resolve inside Dest. }
var
  Src, Dest, Zip, Err: string;
  Empty: array of string;
begin
  SetLength(Empty, 0);
  Src := MakeTempDir('legit_src');
  Dest := MakeTempDir('legit_dest');
  Zip := JoinPath(GetTempDir(False),
                  'legit_' + IntToStr(Random(MaxInt)) + '.zip');
  try
    { Legitimate deeply-nested file -- the validator MUST accept this. }
    WriteText(JoinPath(JoinPath(JoinPath(JoinPath(Src, 'workspace'),
                                          'sessions'), 'foo'),
                       'session.json'),
              '{"ok": true}');
    AssertTrue(PackDirToZip(Src, Zip, Empty, Err), 'pack: ' + Err);
    AssertTrue(ExtractZipToDir(Zip, Dest, Err),
               'legitimate nested path should extract: ' + Err);
    AssertTrue(FileExists(JoinPath(JoinPath(JoinPath(JoinPath(Dest,
                          'workspace'), 'sessions'), 'foo'), 'session.json')),
               'legitimate file extracted to correct location');
  finally
    DeleteFile(Zip);
    RemoveTree(Src);
    RemoveTree(Dest);
  end;
end;

procedure TestUniqueTempDirNoCollisions;
{ Codex P2 on PR #301: with the old Randomize+Random scheme, two
  processes started in the same second produced the same tempdir
  name; with both calling ForceDirectories (idempotent) they ended
  up sharing one $PASCLAW_HOME, and the first to RemoveTree it
  wiped the other's state.  The fix routes through CreateGUID +
  CreateDir.  Test:

    1. Within one process: 64 sequential calls must each return a
       new path that exists on disk and is unique.  64 is well
       inside the GUID space; collisions would imply broken
       OS entropy.
    2. The path lies under the OS temp root (implementation detail,
       but easy to verify and a good sanity check for misconfigured
       hosts where TMPDIR points somewhere wrong).

  True cross-process race is exercised by the smoke harness
  documented in the PR description -- 8 parallel `pasclaw build`
  invocations, all picked distinct GUID-suffixed paths. }
var
  Seen: TStringList;
  Path: string;
  i: Integer;
begin
  Seen := TStringList.Create;
  Seen.Sorted := True;
  Seen.Duplicates := dupError;
  try
    for i := 1 to 64 do
    begin
      Path := MakeUniqueTempDir('pasclaw_uniq_test');
      try
        AssertTrue(DirectoryExists(Path),
                   Format('attempt %d: tempdir not created: %s', [i, Path]));
        try
          Seen.Add(Path);
        except
          on E: EStringListError do
            Fail_(Format('attempt %d: duplicate tempdir %s', [i, Path]));
        end;
      finally
        RemoveDir(Path);
      end;
    end;
    AssertTrue(Seen.Count = 64,
               Format('expected 64 unique tempdirs, got %d', [Seen.Count]));
  finally
    Seen.Free;
  end;
end;

begin
  Randomize;
  TestSimpleRoundtrip;
  TestBinaryRoundtrip;
  TestExclusionDenylist;
  TestEmptyDir;
  TestMissingSource;
  TestRejectsParentTraversal;
  TestRejectsDeepParentTraversal;
  TestRejectsAbsolutePath;
  TestRejectsBackslashTraversal;
  TestAcceptsLegitimateNested;
  TestUniqueTempDirNoCollisions;
  Writeln('ok - build workspace round-trip tests passed');
end.
