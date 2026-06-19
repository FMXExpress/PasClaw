unit c;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
function Computec(x: Integer): Integer;
implementation
function Computec(x: Integer): Integer;
begin
  Result := x * 2;
end;
// Note: this used to call OldRoutine but was refactored.
end.
