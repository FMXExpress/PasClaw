(*
  PasClaw.Skills.Zip - thin cross-toolchain wrapper around the two
  bundled zip libraries:

    FPC    : Zipper.TUnZipper / TZipper (fcl-base, ships in every FPC install)
    Delphi : System.Zip.TZipFile (RTL since Delphi XE2)

  Surface:

    ExtractZipToDir(const ZipPath, DestDir: string; out ErrMsg)
        Unpack ZipPath into DestDir. Used by the skills install path.

    PackDirToZip(const SrcDir, ZipPath: string;
                 const ExcludeNames: array of string;
                 out ErrMsg)
        Walk SrcDir and bundle every file under it into ZipPath at
        paths relative to SrcDir. ExcludeNames is a case-insensitive
        denylist of basenames anywhere in the tree (e.g. ".git" to
        skip vendor metadata). Used by `pasclaw build`'s
        workspace.zip output handshake.

  Both return False without raising on failure; ErrMsg carries the
  reason so callers can format a user-facing message rather than
  surfacing a raw Indy / TZipFile exception.

  We deliberately do not pre-validate archives (size limit, file
  count) here. Callers bound the input + validate the result (e.g.
  PasClaw.Skills.GitHub looks for SKILL.md after extraction;
  PasClaw.Cmd.Build caps the input zip at PASCLAW_WORKSPACE_ZIP_CAP
  bytes). Anything weirder (zip-slip, encrypted archives) should be
  checked there, not here.
*)
unit PasClaw.Skills.Zip;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function ExtractZipToDir(const ZipPath, DestDir: string;
                         out ErrMsg: string): Boolean;

{ Bundle every file under SrcDir into ZipPath, with paths stored
  relative to SrcDir. ExcludeNames is a case-insensitive list of
  basenames to skip at any depth (e.g. ['.git', 'node_modules']);
  pass [] to include everything. Returns False with ErrMsg set on
  any error; on success ZipPath is a valid zip readable by any
  standard tool. }
function PackDirToZip(const SrcDir, ZipPath: string;
                      const ExcludeNames: array of string;
                      out ErrMsg: string): Boolean;

implementation

uses
  SysUtils, Classes,
  {$IFDEF FPC}
    Zipper
  {$ELSE}
    System.Zip
  {$ENDIF};

function ExtractZipToDir(const ZipPath, DestDir: string;
                         out ErrMsg: string): Boolean;
{$IFDEF FPC}
var
  UZ: TUnZipper;
begin
  Result := False;
  ErrMsg := '';
  if not FileExists(ZipPath) then begin ErrMsg := 'archive not found'; Exit; end;
  if not ForceDirectories(DestDir) then
  begin
    ErrMsg := 'cannot create destination directory: ' + DestDir;
    Exit;
  end;
  UZ := TUnZipper.Create;
  try
    try
      UZ.FileName   := ZipPath;
      UZ.OutputPath := DestDir;
      UZ.Examine;
      UZ.UnZipAllFiles;
      Result := True;
    except
      on E: Exception do ErrMsg := 'unzip failed: ' + E.Message;
    end;
  finally
    UZ.Free;
  end;
end;
{$ELSE}
begin
  Result := False;
  ErrMsg := '';
  if not FileExists(ZipPath) then begin ErrMsg := 'archive not found'; Exit; end;
  if not ForceDirectories(DestDir) then
  begin
    ErrMsg := 'cannot create destination directory: ' + DestDir;
    Exit;
  end;
  try
    TZipFile.ExtractZipFile(ZipPath, DestDir);
    Result := True;
  except
    on E: Exception do ErrMsg := 'unzip failed: ' + E.Message;
  end;
end;
{$ENDIF}

function NameExcluded(const Name: string;
                      const ExcludeNames: array of string): Boolean;
var
  i: Integer;
  L: string;
begin
  L := LowerCase(Name);
  for i := Low(ExcludeNames) to High(ExcludeNames) do
    if L = LowerCase(ExcludeNames[i]) then Exit(True);
  Result := False;
end;

function JoinFromParts(const A, B, C: string): string;
{ Three-part path joiner that handles empty middle segments cleanly.
  Local because including PasClaw.Utils.JoinPath from a pkg/skills
  unit would create a cycle once Cmd.Build pulls in both. }
begin
  Result := A;
  if (B <> '') then
  begin
    if (Result <> '') and (Result[Length(Result)] <> PathDelim) and
       (Result[Length(Result)] <> '/') then
      Result := Result + PathDelim;
    Result := Result + B;
  end;
  if (C <> '') then
  begin
    if (Result <> '') and (Result[Length(Result)] <> PathDelim) and
       (Result[Length(Result)] <> '/') then
      Result := Result + PathDelim;
    Result := Result + C;
  end;
end;

procedure CollectFiles(const Root, Rel: string;
                       const ExcludeNames: array of string;
                       Files: TStringList);
{ Recursive walk. Files entries are stored as forward-slash-separated
  paths relative to Root, which is what both Zipper.TZipper and
  System.Zip.TZipFile expect as the in-archive name. }
var
  SR: TSearchRec;
  NextRel, EntryName: string;
begin
  if FindFirst(JoinFromParts(Root, Rel, '*'), faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if NameExcluded(SR.Name, ExcludeNames) then Continue;
      if Rel = '' then EntryName := SR.Name
      else EntryName := Rel + '/' + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if Rel = '' then NextRel := SR.Name
        else NextRel := Rel + '/' + SR.Name;
        CollectFiles(Root, NextRel, ExcludeNames, Files);
      end
      else
        Files.Add(EntryName);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function PackDirToZip(const SrcDir, ZipPath: string;
                      const ExcludeNames: array of string;
                      out ErrMsg: string): Boolean;
{$IFDEF FPC}
var
  Z: TZipper;
  Files: TStringList;
  i: Integer;
  Src, OnDisk, InZip: string;
begin
  Result := False;
  ErrMsg := '';
  if not DirectoryExists(SrcDir) then
  begin
    ErrMsg := 'source directory not found: ' + SrcDir;
    Exit;
  end;
  Src := ExcludeTrailingPathDelimiter(SrcDir);

  { Make sure the destination parent dir exists -- TZipper.SaveToFile
    raises a generic exception otherwise. Don't ForceDirectories on
    ZipPath itself; that would create it as a directory. }
  if ExtractFilePath(ZipPath) <> '' then
    ForceDirectories(ExtractFilePath(ZipPath));

  Files := TStringList.Create;
  Z := TZipper.Create;
  try
    try
      CollectFiles(Src, '', ExcludeNames, Files);
      for i := 0 to Files.Count - 1 do
      begin
        InZip := Files[i];
        OnDisk := Src + PathDelim + StringReplace(InZip, '/', PathDelim,
                                                 [rfReplaceAll]);
        Z.Entries.AddFileEntry(OnDisk, InZip);
      end;
      Z.FileName := ZipPath;
      Z.ZipAllFiles;
      Result := True;
    except
      on E: Exception do ErrMsg := 'zip failed: ' + E.Message;
    end;
  finally
    Z.Free;
    Files.Free;
  end;
end;
{$ELSE}
var
  Z: TZipFile;
  Files: TStringList;
  i: Integer;
  Src, OnDisk, InZip: string;
begin
  Result := False;
  ErrMsg := '';
  if not DirectoryExists(SrcDir) then
  begin
    ErrMsg := 'source directory not found: ' + SrcDir;
    Exit;
  end;
  Src := ExcludeTrailingPathDelimiter(SrcDir);
  if ExtractFilePath(ZipPath) <> '' then
    ForceDirectories(ExtractFilePath(ZipPath));

  Files := TStringList.Create;
  Z := TZipFile.Create;
  try
    try
      CollectFiles(Src, '', ExcludeNames, Files);
      Z.Open(ZipPath, zmWrite);
      for i := 0 to Files.Count - 1 do
      begin
        InZip := Files[i];
        OnDisk := Src + PathDelim + StringReplace(InZip, '/', PathDelim,
                                                 [rfReplaceAll]);
        Z.Add(OnDisk, InZip);
      end;
      Z.Close;
      Result := True;
    except
      on E: Exception do ErrMsg := 'zip failed: ' + E.Message;
    end;
  finally
    Z.Free;
    Files.Free;
  end;
end;
{$ENDIF}

end.
