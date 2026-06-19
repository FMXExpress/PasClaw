unit b;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
function Computeb(x: Integer): Integer;
implementation
function Computeb(x: Integer): Integer;
begin
  Result := x * 2;
end;
// Note: this used to call OldRoutine but was refactored.
end.
