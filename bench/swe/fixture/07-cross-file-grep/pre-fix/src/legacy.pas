unit legacy;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface
procedure RunLegacy;
implementation
procedure RunLegacy;
begin
  WriteLn('starting legacy');
  OldRoutine(42);
end;
end.
