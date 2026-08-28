unit OwnAlias;
(* Declares its own for Delphi, the way PasClaw.Tools.Registry does.
   The alias lives in the branch dcc64 DOES compile, so it counts. *)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils;

{$IFNDEF FPC}
type
  TStringArray = array of string;
{$ENDIF}

function Names: TStringArray;

implementation

function Names: TStringArray;
begin
  SetLength(Result, 0);
end;

end.
