unit d;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
function Computed(x: Integer): Integer;
implementation
function Computed(x: Integer): Integer;
begin
  Result := x * 2;
end;
// Note: this used to call OldRoutine but was refactored.
end.
