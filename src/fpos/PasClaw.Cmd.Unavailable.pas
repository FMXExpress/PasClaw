(*
  PasClaw.Cmd.Unavailable - the commands the FreePascalOS build leaves out.

  They need what FreePascalOS does not have for PasClaw: Indy's socket
  servers and clients (gateway, serve, relay, bridge, the execute_code
  callback), or a terminal driven through Unix termios with a gateway
  client behind it (tui). Cmd.Root takes these in their place on
  FreePascalOS, so `pasclaw gateway` there says why it is missing
  instead of being an unknown command. Only `make fpos` compiles this
  unit (src/fpos).

  PasClaw's own code, MIT like the rest of it.
*)
unit PasClaw.Cmd.Unavailable;

{$MODE DELPHI}
{$H+}

interface

function Cmd_Gateway_Run(const Argv: array of string): Integer;
function Cmd_Serve_Run(const Argv: array of string): Integer;
function Cmd_Relay_Run(const Argv: array of string): Integer;
function Cmd_Bridge_Run(const Argv: array of string): Integer;
function Cmd_TUI_Run(const Argv: array of string): Integer;
function Cmd_ToolRPC_Run(const Argv: array of string): Integer;

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

function Cmd_Gateway_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('gateway', 'it needs an HTTP server; use `pasclaw agent`');
end;

function Cmd_Serve_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('serve', 'it needs an HTTP server');
end;

function Cmd_Relay_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('relay', 'it needs the gateway client');
end;

function Cmd_Bridge_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('bridge', 'it needs a TCP server and a serial line');
end;

function Cmd_TUI_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('tui', 'the full-screen UI needs a Unix terminal; use `pasclaw agent`');
end;

function Cmd_ToolRPC_Run(const Argv: array of string): Integer;
begin
  Result := Unavailable('__tool', 'execute_code''s tool callback needs a TCP server');
end;

end.
