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

begin
  Randomize;
  TestSimpleRoundtrip;
  TestBinaryRoundtrip;
  TestExclusionDenylist;
  TestEmptyDir;
  TestMissingSource;
  Writeln('ok - build workspace round-trip tests passed');
end.
