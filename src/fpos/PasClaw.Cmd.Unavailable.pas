(*
  PasClaw.Cmd.Unavailable - the commands the FreePascalOS build leaves out.

  What is left out is `tui`: the full-screen UI drives a Unix terminal
  through termios, which FreePascalOS's console is not. Cmd.Root takes
  this unit in its place on FreePascalOS, so `pasclaw tui` there says why
  it is missing instead of being an unknown command. The gateway, serve,
  relay, bridge and the execute_code callback run there, on Indy's
  FreePascalOS socket stack (src/fpos/indy). Only `make fpos` compiles
  this unit (src/fpos).

  PasClaw's own code, MIT like the rest of it.
*)
unit PasClaw.Cmd.Unavailable;

{$MODE DELPHI}
{$H+}

interface

function Cmd_TUI_Run(const Argv: array of string): Integer;

{ The line each of them prints: "pasclaw <Cmd> is not available on
  FreePascalOS (<Why>)". }
function UnavailableMessage(const Cmd, Why: string): string;

implementation

uses
  PasClaw.CliUI;

function UnavailableMessage(const Cmd, Why: string): string;
begin
  Result := 'pasclaw ' + Cmd + ' is not available on FreePascalOS (' + Why + ')';
end;

function Unavailable(const Cmd, Why: string): Integer;
begin
  PrintErr(FormatCLIError(UnavailableMessage(Cmd, Why), 'pasclaw ' + Cmd));
  Result := 1;
end;

function Cmd_TUI_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('tui', 'the full-screen UI needs a Unix terminal; use ' +
                        '`pasclaw agent`, or the web UI of `pasclaw gateway`');
end;

end.
