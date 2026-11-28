(*
  dos for the FreePascalOS build of PasClaw: the one part of it paszlib
  needs.

  paszlib's gzio (under zstream, which the PDF reader and the vector
  provisioning use) asks dos.GetFAttr whether a file exists on every
  target that is not UNIX; FreePascalOS is not UNIX and its runtime has
  no dos unit. This gives gzio GetFAttr and DosError, over SysUtils.
  Only `make fpos` puts src/fpos on the unit path.

  PasClaw's own code, MIT like the rest of it.
*)
unit dos;

{$MODE OBJFPC}
{$H+}

interface

const
  faReadOnly  = $01;
  faDirectory = $10;
  faArchive   = $20;

var
  { 0 after a call that worked; 2 (file not found) otherwise. }
  DosError: Integer;

{ The attributes of the file assigned to F (Assign), or DosError = 2
  when there is no such file. }
procedure GetFAttr(var F; var Attr: Word);

implementation

uses
  SysUtils;

procedure GetFAttr(var F; var Attr: Word);
var
  Name: UnicodeString;
begin
  Name := FileRec(F).Name;
  Attr := 0;
  if DirectoryExists(Name) then
  begin
    Attr := faDirectory;
    DosError := 0;
  end
  else if FileExists(Name) then
  begin
    Attr := faArchive;
    DosError := 0;
  end
  else
    DosError := 2;
end;

end.
