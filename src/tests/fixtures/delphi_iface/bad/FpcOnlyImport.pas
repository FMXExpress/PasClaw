unit FpcOnlyImport;
(* The hole Codex found on #592: the provider is imported ONLY in the
   FPC branch. Before DelphiActive, StripComments blanked the
   directives and left a bare "PasClaw.Utils" behind, so the check
   passed while dcc64 still failed with E2003. *)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
interface

uses
  SysUtils
  {$IFDEF FPC}, PasClaw.Utils{$ENDIF};

function Names: TStringArray;

implementation

function Names: TStringArray;
begin
  SetLength(Result, 0);
end;

end.
