(*
  PasClaw.Skills.Zip - thin cross-toolchain wrapper around the two
  bundled zip libraries:

    FPC    : Zipper.TUnZipper (fcl-base, ships in every FPC install)
    Delphi : System.Zip.TZipFile (RTL since Delphi XE2)

  Single function exposed:

    ExtractZipToDir(const ZipPath, DestDir: string; out ErrMsg)

  Caller is responsible for creating DestDir if needed. ErrMsg is
  set on failure; the function returns False without raising so the
  skills-install path can format a user-friendly message instead of
  surfacing the raw Indy / TZipFile exception text.

  We deliberately do not pre-validate the archive (size limit, file
  count, etc.) -- the install layer in PasClaw.Skills.GitHub already
  bounds the download to a sensible cap and validates the final tree
  by looking for SKILL.md. Anything weirder (zip-slip, encrypted
  archives, etc.) should be checked there, not here.
*)
unit PasClaw.Skills.Zip;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function ExtractZipToDir(const ZipPath, DestDir: string;
                         out ErrMsg: string): Boolean;

implementation

uses
  SysUtils,
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

end.
