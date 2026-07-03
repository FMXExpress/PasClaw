program zip_pack_tests;
(*
  Pins PackDirToZip's archive validity, in particular the empty-directory
  case that broke the cog workspace handshake:

    * An EMPTY source directory must yield a VALID (openable) empty zip --
      not a 0-byte file. FPC's TZipper.ZipAllFiles writes a zero-length
      file for an empty entry set; that is not a valid archive, so the cog
      predictor (which returns the zip as a Cog Path output) shipped a
      corrupt artifact that failed to upload with an opaque error. The fix
      writes the 22-byte End-Of-Central-Directory record instead.

    * A NON-empty directory round-trips: pack then extract recovers the
      file and its contents.

  Drives PackDirToZip / ExtractZipToDir against temp dirs. No model.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes,
  PasClaw.Skills.Zip;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;

function ReadAll(const Path: string): string;
var S: TStringList;
begin
  S := TStringList.Create;
  try S.LoadFromFile(Path); Result := S.Text; finally S.Free; end;
end;

var
  Base, EmptyDir, FullDir, EmptyZip, FullZip, OutDir, Err: string;
  F: TextFile;
  Sz: Int64;
  FS: TFileStream;
  Sig: array[0..3] of Byte;

begin
  Base := IncludeTrailingPathDelimiter(GetTempDir) + 'pcziptest_' + IntToStr(GetProcessID);
  EmptyDir := Base + PathDelim + 'empty';
  FullDir  := Base + PathDelim + 'full';
  EmptyZip := Base + PathDelim + 'empty.zip';
  FullZip  := Base + PathDelim + 'full.zip';
  OutDir   := Base + PathDelim + 'out';
  ForceDirectories(EmptyDir);
  ForceDirectories(FullDir);

  { --- 1. Empty directory -> valid, openable empty zip (not 0 bytes). --- }
  AssertTrue(PackDirToZip(EmptyDir, EmptyZip, [], Err),
             'PackDirToZip(empty) should succeed: ' + Err);
  AssertTrue(FileExists(EmptyZip), 'empty zip file created');
  FS := TFileStream.Create(EmptyZip, fmOpenRead or fmShareDenyNone);
  try
    Sz := FS.Size;
    FS.ReadBuffer(Sig, 4);
  finally FS.Free; end;
  AssertTrue(Sz >= 22, 'empty zip is a real archive, not a 0-byte file (got '
                       + IntToStr(Sz) + ' bytes)');
  { Must carry the End-Of-Central-Directory signature (PK\005\006) -- exactly
    what zipfile.is_zipfile scans for on the cog side, i.e. the check the
    corrupt 0-byte file failed. }
  AssertTrue((Sig[0] = $50) and (Sig[1] = $4B) and (Sig[2] = $05) and (Sig[3] = $06),
             'empty zip starts with the EOCD signature (valid empty archive)');
  WriteLn('  ok: empty directory -> valid empty zip with EOCD signature (not 0 bytes)');

  { --- 2. Non-empty directory round-trips. --- }
  AssignFile(F, FullDir + PathDelim + 'hello.txt'); Rewrite(F);
  Write(F, 'hi there'); CloseFile(F);
  AssertTrue(PackDirToZip(FullDir, FullZip, [], Err),
             'PackDirToZip(full) should succeed: ' + Err);
  FS := TFileStream.Create(FullZip, fmOpenRead or fmShareDenyNone);
  try Sz := FS.Size; finally FS.Free; end;
  AssertTrue(Sz > 22, 'non-empty zip larger than a bare EOCD');
  AssertTrue(ExtractZipToDir(FullZip, OutDir, Err),
             'full zip extracts: ' + Err);
  AssertTrue(FileExists(OutDir + PathDelim + 'hello.txt'),
             'round-tripped file present after extract');
  AssertTrue(Pos('hi there', ReadAll(OutDir + PathDelim + 'hello.txt')) > 0,
             'round-tripped file content preserved');
  WriteLn('  ok: non-empty directory packs + round-trips through extract');

  WriteLn('zip_pack_tests: OK');
end.
