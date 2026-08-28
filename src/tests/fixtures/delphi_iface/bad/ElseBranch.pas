unit ElseBranch;
(* Same hole through {$ELSE}: the provider sits in the branch dcc64
   skips. *)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils,
  {$IFNDEF FPC}Classes{$ELSE}PasClaw.Utils{$ENDIF};

procedure Take(const A: TStringArray);

implementation

procedure Take(const A: TStringArray);
begin
end;

end.
