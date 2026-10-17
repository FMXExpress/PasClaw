(*
  PasClaw.Cmd.Route -- `pasclaw route report`: which models the last N
  days of sessions actually ran on, and how much of the token volume each
  one carried.

  The setups that run for under a few dollars a month put 70-80% of calls
  on a small or local model and escalate the rest. You cannot tune toward
  that split without seeing it. Sessions already record their model and
  token counts (TSessionMeta.Model / Stats); this aggregates them and
  prints the cheap-tier settings beside the numbers so the gap is visible.

  Caveat printed with the table: a session's Model is the LAST model it
  used. Turns the auto-router sent to the easy tier inside a session are
  attributed to the session's model. The split is therefore a floor on
  how much ran cheap, not an exact figure.
*)
unit PasClaw.Cmd.Route;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Route_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes, DateUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Session.Store;

type
  TRow = record
    Key: string;         { provider/model }
    Sessions, Turns: Integer;
    InTok, OutTok: Int64;
  end;

function IfEmpty(const S, Fallback: string): string;
begin
  if Trim(S) = '' then Result := Fallback else Result := S;
end;

procedure Help;
begin
  PrintLn('Usage: pasclaw route report [--since N]');
  PrintLn;
  PrintLn('  Token volume per provider/model over the last N days of saved sessions');
  PrintLn('  (default 7), beside the cheap-tier settings (background_model, fast_model,');
  PrintLn('  auto_router.easy_model). A session counts under the last model it used.');
end;

function Cmd_Route_Run(const Argv: array of string): Integer;
var
  i, j, Since: Integer;
  Sessions: TSessionMetaArray;
  Rows: array of TRow;
  Key: string;
  SinceUnix, TotIn, TotOut: Int64;
  Cfg: TConfig;
  Pct: Double;
  Found: Boolean;
  Tmp: TRow;
begin
  Since := 7;
  i := 0;
  Found := False;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-h') or (Argv[i] = '--help') then begin Help; Exit(0); end
    else if Argv[i] = 'report' then Found := True
    else if (Argv[i] = '--since') and (i < High(Argv)) then
    begin
      Inc(i);
      Since := StrToIntDef(Argv[i], 7);
    end
    else
    begin
      PrintErr(FormatCLIError('unknown argument: ' + Argv[i], 'pasclaw route'));
      Exit(1);
    end;
    Inc(i);
  end;
  if not Found then begin Help; Exit(1); end;

  SinceUnix := DateTimeToUnix(Now, False) - Int64(Since) * 86400;
  Sessions := ListSessions;
  SetLength(Rows, 0);
  TotIn := 0;
  TotOut := 0;
  for i := 0 to High(Sessions) do
  begin
    if Sessions[i].UpdatedAt < SinceUnix then Continue;
    Key := Sessions[i].Provider;
    if Key = '' then Key := '?';
    if Sessions[i].Model <> '' then Key := Key + '/' + Sessions[i].Model
    else Key := Key + '/?';
    j := 0;
    while (j <= High(Rows)) and (Rows[j].Key <> Key) do Inc(j);
    if j > High(Rows) then
    begin
      SetLength(Rows, j + 1);
      Rows[j].Key := Key;
    end;
    Inc(Rows[j].Sessions);
    Inc(Rows[j].Turns, Sessions[i].Stats.Turns);
    Inc(Rows[j].InTok, Sessions[i].Stats.InputTokens);
    Inc(Rows[j].OutTok, Sessions[i].Stats.OutputTokens);
    Inc(TotIn, Sessions[i].Stats.InputTokens);
    Inc(TotOut, Sessions[i].Stats.OutputTokens);
  end;

  { Largest input volume first. }
  for i := 1 to High(Rows) do
  begin
    Tmp := Rows[i];
    j := i - 1;
    while (j >= 0) and (Rows[j].InTok < Tmp.InTok) do
    begin
      Rows[j + 1] := Rows[j];
      Dec(j);
    end;
    Rows[j + 1] := Tmp;
  end;

  PrintLn(Ansi.Bold + Format('model usage, last %d day(s)', [Since]) + Ansi.Reset);
  if Length(Rows) = 0 then
    PrintLn('  (no sessions in the window)')
  else
  begin
    PrintLn(Format('  %-44s %8s %7s %12s %12s %6s', ['provider/model', 'sessions', 'turns', 'in', 'out', 'in%']));
    for i := 0 to High(Rows) do
    begin
      if TotIn > 0 then Pct := 100.0 * Rows[i].InTok / TotIn else Pct := 0;
      PrintLn(Format('  %-44s %8d %7d %12d %12d %5.1f%%',
              [Rows[i].Key, Rows[i].Sessions, Rows[i].Turns, Rows[i].InTok, Rows[i].OutTok, Pct]));
    end;
    PrintLn(Format('  %-44s %8s %7s %12d %12d', ['total', '', '', TotIn, TotOut]));
  end;

  Cfg := LoadConfig;
  try
    PrintLn;
    PrintLn(Ansi.Bold + 'cheap tier' + Ansi.Reset);
    PrintLn('  background_model:       ' + IfEmpty(Cfg.BackgroundModel, '(unset -> fast_model -> main model)'));
    PrintLn('  fast_model:             ' + IfEmpty(Cfg.FastModel, '(unset)'));
    if Cfg.AutoRouter.Enabled and (Cfg.AutoRouter.EasyModel <> '') then
      PrintLn('  auto_router easy tier:  ' + IfEmpty(Cfg.AutoRouter.EasyProvider, Cfg.DefaultProvider) +
              '/' + Cfg.AutoRouter.EasyModel)
    else
      PrintLn('  auto_router easy tier:  (not configured -- every turn runs on the main model)');
    PrintLn(Ansi.Dim + '  a session counts under the last model it used; turns the auto-router sent to' + Ansi.Reset);
    PrintLn(Ansi.Dim + '  the easy tier mid-session are attributed to that model, so cheap% is a floor.' + Ansi.Reset);
  finally
    Cfg.Free;
  end;
  Result := 0;
end;

end.
