unit queue;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
implementation
procedure Pump;
var x: Integer;
begin
  x := OldRoutine(0);
  if x > 0 then WriteLn(x);
end;
end.
