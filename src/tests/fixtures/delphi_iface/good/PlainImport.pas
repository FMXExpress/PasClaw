unit PlainImport;
{ The ordinary correct shape: imported for both compilers. }
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils,
  PasClaw.Utils;

function Names: TStringArray;

implementation

function Names: TStringArray;
begin
  SetLength(Result, 0);
end;

end.
