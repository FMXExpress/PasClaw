(*
  PasClaw.Cmd.Steer -- push a follow-up message into a running
  agent's mid-loop steering queue. Mirrors picoclaw's `steer`
  subcommand and nanobot's _inject_pending side-channel.

  Usage:
    pasclaw steer <session-id> "your follow-up message"
    pasclaw steer <session-id> --list           # show pending count
    pasclaw steer <session-id> --clear          # drop pending queue
    pasclaw steer --help

  The other terminal running `pasclaw agent --session <id>` (or a
  channel daemon wired to use this session key) will drain the
  queue at the top of its NEXT tool-loop iteration and fold each
  pending message into history as a "[user steering] ..." system
  note. If no loop is currently running, the message sits queued
  for the next time one is.
*)
unit PasClaw.Cmd.Steer;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Steer_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Agent.Steering;

procedure PrintHelp;
begin
  PrintLn('Usage: pasclaw steer <session-id> <message>');
  PrintLn('       pasclaw steer <session-id> --list');
  PrintLn('       pasclaw steer <session-id> --clear');
  PrintLn;
  PrintLn('Push a mid-loop steering message to a running agent. The');
  PrintLn('next iteration of the agent''s tool loop folds it into');
  PrintLn('history as a "[user steering] ..." system note before the');
  PrintLn('next LLM call.');
end;

function Cmd_Steer_Run(const Argv: array of string): Integer;
var
  Id, Msg: string;
  i, n: Integer;
begin
  if Length(Argv) = 0 then begin PrintHelp; Exit(1); end;
  if (Argv[0] = '-h') or (Argv[0] = '--help') then
  begin
    PrintHelp; Exit(0);
  end;

  Id := Argv[0];
  if Length(Argv) < 2 then
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'missing message argument');
    PrintHelp;
    Exit(1);
  end;

  if Argv[1] = '--list' then
  begin
    n := PendingSteeringCount(Id);
    if n = 0 then
      PrintLn(Ansi.Dim + '(no pending steering for ' + Id + ')' + Ansi.Reset)
    else
      PrintLn('  pending steering messages for ' + Id + ': ' + IntToStr(n));
    Exit(0);
  end;

  if Argv[1] = '--clear' then
  begin
    ClearSteering(Id);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'cleared steering queue for ' + Id);
    Exit(0);
  end;

  { Concatenate remaining argv as the message (shell already split
    on whitespace; we want the original sentence back). }
  Msg := Argv[1];
  for i := 2 to High(Argv) do Msg := Msg + ' ' + Argv[i];

  if PushSteering(Id, Msg) then
  begin
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'queued: "' + Copy(Msg, 1, 80) + '"');
    PrintLn(Ansi.Dim + '  the running agent will pick it up at the top of its next iteration' + Ansi.Reset);
    Exit(0);
  end
  else
  begin
    PrintLn(Ansi.Red + '✗ ' + Ansi.Reset + 'push failed -- invalid session id "' + Id + '" or write error');
    Exit(1);
  end;
end;

end.
