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
  standard tool.

  ArchivePrefix (optional) is prepended to every stored entry name,
  so PackDirToZip(home/workspace, ..., 'workspace') yields entries
  like "workspace/memory.md" -- matching `pasclaw build`'s whole-home
  layout so a web-exported zip drops straight into
  `pasclaw build --workspace-in`. Empty (default) keeps the old
  relative-to-SrcDir naming. }
function PackDirToZip(const SrcDir, ZipPath: string;
                      const ExcludeNames: array of string;
                      out ErrMsg: string;
                      const ArchivePrefix: string = ''): Boolean;

implementation

uses
  SysUtils, Classes, StrUtils,
  {$IFDEF FPC}
    Zipper
  {$ELSE}
    System.Zip
  {$ENDIF};

function IsUnsafeMemberName(const Name, AbsDest: string;
                            out Reason: string): Boolean;
{ Zip-slip guard. Reject when:
    1. The archive entry name is empty.
    2. It starts with a path separator -- absolute POSIX path.
    3. It looks like a Windows drive (X:\...) or UNC (\\...).
    4. Any segment is exactly "..".  Paranoid: ExpandFileName below
       handles arbitrary "../" composition, but a leading-segment
       reject gives a clearer error.
    5. The resolved absolute target falls outside AbsDest.  This is
       the canonical check; ExpandFileName collapses sequences like
       "foo/../../etc/passwd" so even clever encodings end up at a
       resolved path the containment test will reject.

  AbsDest must already be the ExpandFileName'd + slash-terminated
  destination root. Reason is set on rejection so the caller can
  surface a useful diagnostic. }
var
  i: Integer;
  Norm, AbsTarget, Segment: string;
  Sep: Char;
begin
  Reason := '';
  Result := True;
  if Name = '' then
  begin
    Reason := 'empty entry name';
    Exit;
  end;
  { Normalise separators so the segment scan + ExpandFileName both
    see a single canonical form. Zip entries are documented to use
    '/', but defensive code shouldn't trust that on a malicious input. }
  Norm := StringReplace(Name, '\', '/', [rfReplaceAll]);
  if (Norm[1] = '/') then
  begin
    Reason := 'absolute path';
    Exit;
  end;
  if (Length(Norm) >= 2) and
     (((Norm[1] >= 'A') and (Norm[1] <= 'Z')) or
      ((Norm[1] >= 'a') and (Norm[1] <= 'z'))) and
     (Norm[2] = ':') then
  begin
    Reason := 'Windows drive prefix';
    Exit;
  end;
  if (Length(Norm) >= 2) and (Norm[1] = '/') and (Norm[2] = '/') then
  begin
    Reason := 'UNC prefix';
    Exit;
  end;
  Segment := '';
  for i := 1 to Length(Norm) do
  begin
    if Norm[i] = '/' then
    begin
      if Segment = '..' then
      begin
        Reason := '".." segment';
        Exit;
      end;
      Segment := '';
    end
    else
      Segment := Segment + Norm[i];
  end;
  if Segment = '..' then
  begin
    Reason := '".." segment';
    Exit;
  end;

  { Canonical containment check. PathDelim on the host (Unix uses '/',
    Windows '\') is what ExpandFileName + filesystem APIs honour, so
    translate forward slashes to PathDelim before resolving. }
  Sep := PathDelim;
  AbsTarget := ExpandFileName(AbsDest +
    StringReplace(Norm, '/', Sep, [rfReplaceAll]));
  { Compare prefix using a string-aware case-insensitive match. On
    POSIX paths are case-sensitive so SameText is overkill but
    harmless; Windows demands case-insensitive. }
  if not StartsText(AbsDest, AbsTarget) then
  begin
    Reason := Format('resolves outside destination (%s -> %s)',
                     [Norm, AbsTarget]);
    Exit;
  end;

  Result := False;
end;

function ValidateZipEntries(const ZipPath, AbsDest: string;
                            out ErrMsg: string): Boolean;
{$IFDEF FPC}
var
  UZ: TUnZipper;
  i: Integer;
  EntryName, Reason: string;
begin
  Result := False;
  ErrMsg := '';
  UZ := TUnZipper.Create;
  try
    try
      UZ.FileName := ZipPath;
      UZ.Examine;
      for i := 0 to UZ.Entries.Count - 1 do
      begin
        EntryName := UZ.Entries[i].ArchiveFileName;
        if IsUnsafeMemberName(EntryName, AbsDest, Reason) then
        begin
          ErrMsg := Format('unsafe zip entry "%s": %s', [EntryName, Reason]);
          Exit;
        end;
      end;
      Result := True;
    except
      on E: Exception do ErrMsg := 'zip scan failed: ' + E.Message;
    end;
  finally
    UZ.Free;
  end;
end;
{$ELSE}
var
  Z: TZipFile;
  i: Integer;
  EntryName, Reason: string;
begin
  Result := False;
  ErrMsg := '';
  Z := TZipFile.Create;
  try
    try
      Z.Open(ZipPath, zmRead);
      try
        for i := 0 to Z.FileCount - 1 do
        begin
          EntryName := Z.FileNames[i];
          if IsUnsafeMemberName(EntryName, AbsDest, Reason) then
          begin
            ErrMsg := Format('unsafe zip entry "%s": %s', [EntryName, Reason]);
            Exit;
          end;
        end;
        Result := True;
      finally
        Z.Close;
      end;
    except
      on E: Exception do ErrMsg := 'zip scan failed: ' + E.Message;
    end;
  finally
    Z.Free;
  end;
end;
{$ENDIF}

function ExtractZipToDir(const ZipPath, DestDir: string;
                         out ErrMsg: string): Boolean;
var
  AbsDest: string;
{$IFDEF FPC}
var
  UZ: TUnZipper;
{$ENDIF}
begin
  Result := False;
  ErrMsg := '';
  if not FileExists(ZipPath) then begin ErrMsg := 'archive not found'; Exit; end;
  if not ForceDirectories(DestDir) then
  begin
    ErrMsg := 'cannot create destination directory: ' + DestDir;
    Exit;
  end;
  { Resolve destination once + slash-terminate so the containment
    check is byte-prefix-comparable. ExpandFileName on macOS resolves
    /var -> /private/var and similar symlinks; doing this once up
    front means every entry resolves into the same realpath space. }
  AbsDest := IncludeTrailingPathDelimiter(ExpandFileName(DestDir));

  { Validate every entry before letting either backend extract.
    Zip-slip: a malicious archive with "../../etc/passwd" or absolute-
    path entries could write outside DestDir under FPC's
    UnZipAllFiles or Delphi's ExtractZipFile, which neither library
    rejects. Codex P1 on PR #300. }
  if not ValidateZipEntries(ZipPath, AbsDest, ErrMsg) then Exit;

{$IFDEF FPC}
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
{$ELSE}
  try
    TZipFile.ExtractZipFile(ZipPath, DestDir);
    Result := True;
  except
    on E: Exception do ErrMsg := 'unzip failed: ' + E.Message;
  end;
{$ENDIF}
end;

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
                      out ErrMsg: string;
                      const ArchivePrefix: string): Boolean;
{$IFDEF FPC}
var
  Z: TZipper;
  Files: TStringList;
  i: Integer;
  Src, Pfx, OnDisk, InZip: string;
begin
  Result := False;
  ErrMsg := '';
  if not DirectoryExists(SrcDir) then
  begin
    ErrMsg := 'source directory not found: ' + SrcDir;
    Exit;
  end;
  Src := ExcludeTrailingPathDelimiter(SrcDir);
  { Stored entry names are forward-slash separated; append one '/' so the
    prefix becomes a directory component (e.g. "workspace/memory.md"). }
  Pfx := ArchivePrefix;
  if Pfx <> '' then Pfx := Pfx + '/';

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
        OnDisk := Src + PathDelim + StringReplace(Files[i], '/', PathDelim,
                                                 [rfReplaceAll]);
        InZip := Pfx + Files[i];
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
  Src, Pfx, OnDisk, InZip: string;
begin
  Result := False;
  ErrMsg := '';
  if not DirectoryExists(SrcDir) then
  begin
    ErrMsg := 'source directory not found: ' + SrcDir;
    Exit;
  end;
  Src := ExcludeTrailingPathDelimiter(SrcDir);
  Pfx := ArchivePrefix;
  if Pfx <> '' then Pfx := Pfx + '/';
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
        OnDisk := Src + PathDelim + StringReplace(Files[i], '/', PathDelim,
                                                 [rfReplaceAll]);
        InZip := Pfx + Files[i];
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
