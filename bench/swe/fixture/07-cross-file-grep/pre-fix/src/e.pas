unit e;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
function Computee(x: Integer): Integer;
implementation
function Computee(x: Integer): Integer;
begin
  Result := x * 2;
end;
// Note: this used to call OldRoutine but was refactored.
end.
