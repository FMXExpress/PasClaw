unit DelphiBranchImport;
(* Imported only where Delphi needs it. FPC gets the type from its own
   SysUtils, so this is correct, not a near miss -- and the check must
   not cry wolf about it. *)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils
  {$IFNDEF FPC}, PasClaw.Utils{$ENDIF};

function Names: TStringArray;

implementation

function Names: TStringArray;
begin
  SetLength(Result, 0);
end;

end.
