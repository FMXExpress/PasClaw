unit cmd_quote;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

{ Quote a single argument for cmd.exe.

  Contract:
    - Wraps the input in double quotes.
    - Every internal '"' is doubled ('""') so cmd.exe sees a literal quote.
    - An empty input is quoted as '""' (length 2), NOT the empty string,
      so the argument is still passed (as an empty string) rather than
      dropped from the command line. }
function QuoteForCmd(const Arg: string): string;

implementation

function QuoteForCmd(const Arg: string): string;
begin
  Result := '"' + Arg + '"';
end;

end.
