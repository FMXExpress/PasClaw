program checkpoints_zpaq_tests;
{ Round-trip coverage for PasClaw.Checkpoints.Zpaq:
    - Append-list-extract over multiple segments with the same name
      (the multi-version case the journal relies on).
    - Bytes (including embedded NULs) round-trip intact.
    - Out-of-range extract returns False with a useful error.
    - Append twice from separate process-of-thought (separate Packer
      instances against the same archive path) -- the canonical
      PasClaw.Checkpoints flow.

  Gated on PASCLAW_HAVE_ZPAQ: when the vendor isn't on disk, the
  whole suite prints "skipped" and exits 0 so CI on a fresh clone
  without `make get-zpaq` doesn't false-fail. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Checkpoints.Zpaq,
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
var
  i: Integer;
begin
  if Length(Got) <> Length(Want) then
    Fail_(Format('%s: length got=%d want=%d', [Msg, Length(Got), Length(Want)]));
  for i := 0 to Length(Want) - 1 do
    if Got[i] <> Want[i] then
      Fail_(Format('%s: byte %d differs (got %d, want %d)',
                   [Msg, i, Got[i], Want[i]]));
end;

function MakeTempDir: string;
begin
  Result := JoinPath(GetTempDir(False),
                     'pasclaw_zpaq_test_' + IntToStr(Random(MaxInt)));
  ForceDirectories(Result);
end;

procedure RemoveTree(const Path: string);
var
  Sr: TSearchRec;
  Sub: string;
begin
  if not DirectoryExists(Path) then Exit;
  if FindFirst(JoinPath(Path, '*'), faAnyFile, Sr) = 0 then
  try
    repeat
      if (Sr.Name = '.') or (Sr.Name = '..') then Continue;
      Sub := JoinPath(Path, Sr.Name);
      if (Sr.Attr and faDirectory) <> 0 then
        RemoveTree(Sub)
      else
        DeleteFile(Sub);
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
  RemoveDir(Path);
end;

function MakeBytes(const S: string): TBytes;
begin
  SetLength(Result, Length(S));
  if Length(S) > 0 then
    Move(S[1], Result[0], Length(S));
end;

procedure TestMultiVersionRoundtrip;
{ The fundamental PasClaw.Checkpoints flow: each `SnapshotBeforeWrite`
  appends one segment via a fresh ZpaqAppendBytes call. Three appends
  of differently-shaped bytes for the same logical path must surface
  as three list entries, and each must extract back to its original
  bytes verbatim. }
var
  Dir, Archive, Err: string;
  Entries: TZpaqArchiveEntries;
  Got, B1, B2, B3: TBytes;
begin
  if not ZpaqAvailable then
  begin
    Writeln('skipped - zpaq backend not available');
    Exit;
  end;
  Dir := MakeTempDir;
  try
    Archive := JoinPath(Dir, 'session.zpaq');
    B1 := MakeBytes('turn1 content');
    B2 := MakeBytes('turn2 different content');
    B3 := MakeBytes('turn3 again something else entirely here');
    AssertTrue(ZpaqAppendBytes(Archive, B1, 'src/foo.pas', ZpaqDefaultMethod, Err),
               'append #1: ' + Err);
    AssertTrue(ZpaqAppendBytes(Archive, B2, 'src/foo.pas', ZpaqDefaultMethod, Err),
               'append #2: ' + Err);
    AssertTrue(ZpaqAppendBytes(Archive, B3, 'src/foo.pas', ZpaqDefaultMethod, Err),
               'append #3: ' + Err);

    AssertTrue(ZpaqListEntries(Archive, Entries, Err), 'list: ' + Err);
    AssertTrue(Length(Entries) = 3,
               Format('expected 3 entries, got %d', [Length(Entries)]));
    AssertEqS(Entries[0].Name, 'src/foo.pas', 'entry 0 name');
    AssertEqS(Entries[1].Name, 'src/foo.pas', 'entry 1 name');
    AssertEqS(Entries[2].Name, 'src/foo.pas', 'entry 2 name');

    AssertTrue(ZpaqExtractByIndex(Archive, 0, Got, Err), 'extract 0: ' + Err);
    AssertBytesEq(Got, B1, 'entry 0 body');
    AssertTrue(ZpaqExtractByIndex(Archive, 1, Got, Err), 'extract 1: ' + Err);
    AssertBytesEq(Got, B2, 'entry 1 body');
    AssertTrue(ZpaqExtractByIndex(Archive, 2, Got, Err), 'extract 2: ' + Err);
    AssertBytesEq(Got, B3, 'entry 2 body');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestBinaryRoundtrip;
{ Snapshots are bytes, not text. Embed NUL bytes and high-bit bytes
  and confirm they survive. The Pascal port internally operates on
  AnsiString buffers; NUL-safety is a real concern. }
var
  Dir, Archive, Err: string;
  Want, Got: TBytes;
  i: Integer;
begin
  if not ZpaqAvailable then Exit;
  Dir := MakeTempDir;
  try
    Archive := JoinPath(Dir, 'bin.zpaq');
    SetLength(Want, 256);
    for i := 0 to 255 do Want[i] := i;
    AssertTrue(ZpaqAppendBytes(Archive, Want, 'binary.bin', ZpaqDefaultMethod, Err),
               'append: ' + Err);
    AssertTrue(ZpaqExtractByIndex(Archive, 0, Got, Err), 'extract: ' + Err);
    AssertBytesEq(Got, Want, 'binary bytes round-trip');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestExtractOutOfRange;
var
  Dir, Archive, Err: string;
  Got: TBytes;
begin
  if not ZpaqAvailable then Exit;
  Dir := MakeTempDir;
  try
    Archive := JoinPath(Dir, 'oor.zpaq');
    AssertTrue(ZpaqAppendBytes(Archive, MakeBytes('only entry'),
                               'x.txt', ZpaqDefaultMethod, Err),
               'append: ' + Err);
    AssertTrue(not ZpaqExtractByIndex(Archive, 5, Got, Err),
               'extract idx=5 should fail');
    AssertTrue(Pos('out of range', Err) > 0,
               'err mentions out-of-range (got: ' + Err + ')');
  finally
    RemoveTree(Dir);
  end;
end;

procedure TestListMissingArchive;
var
  Entries: TZpaqArchiveEntries;
  Err: string;
begin
  if not ZpaqAvailable then Exit;
  AssertTrue(not ZpaqListEntries('/tmp/__pasclaw_no_such_archive__.zpaq',
                                 Entries, Err),
             'list missing archive should fail');
  AssertTrue(Pos('not found', Err) > 0,
             'err mentions not-found (got: ' + Err + ')');
end;

begin
  Randomize;
  if not ZpaqAvailable then
  begin
    Writeln('ok - skipped (PASCLAW_HAVE_ZPAQ not defined; run `make get-zpaq` then rebuild)');
    Halt(0);
  end;
  TestMultiVersionRoundtrip;
  TestBinaryRoundtrip;
  TestExtractOutOfRange;
  TestListMissingArchive;
  Writeln('ok - checkpoints.zpaq round-trip tests passed');
end.
