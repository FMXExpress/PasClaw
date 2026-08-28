unit FpcOnlyUse;
(* Uses the type only where FPC compiles. Delphi never sees it, so
   there is nothing to import and nothing to report. *)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils;

{$IFDEF FPC}
function Names: TStringArray;
{$ENDIF}

implementation

{$IFDEF FPC}
function Names: TStringArray;
begin
  SetLength(Result, 0);
end;
{$ENDIF}

end.
