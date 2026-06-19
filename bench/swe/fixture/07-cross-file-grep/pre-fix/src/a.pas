unit a;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
function Computea(x: Integer): Integer;
implementation
function Computea(x: Integer): Integer;
begin
  Result := x * 2;
end;
// Note: this used to call OldRoutine but was refactored.
end.
