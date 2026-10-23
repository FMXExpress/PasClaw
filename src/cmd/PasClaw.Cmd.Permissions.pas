(*
  PasClaw.Cmd.Permissions -- `pasclaw permissions list | test`.

  The rule list is evaluated last-match-wins across two files, which is
  easy to get backwards by hand. `list` prints both lists in evaluation
  order with their source; `test <tool> [resource]` prints the decision
  the dispatch gate would make for that call, and which rule made it.
*)
unit PasClaw.Cmd.Permissions;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Permissions_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Config,
  PasClaw.Permissions;

procedure Help;
begin
  PrintLn('Usage: pasclaw permissions list');
  PrintLn('       pasclaw permissions test <tool> [resource]');
  PrintLn;
  PrintLn('  list  Print the policy rules (policies.json) and the config rules');
  PrintLn('        (config.json "permissions") in evaluation order. Last match wins;');
  PrintLn('        a policy deny is final; a policy ask outranks a config allow.');
  PrintLn('  test  Print what the dispatch gate would decide for one call. The');
  PrintLn('        resource is the command for shell tools, the path for file tools,');
  PrintLn('        the url for fetch tools.');
end;

procedure PrintRules(const Title: string; const Rules: TPermRuleArray);
var
  i: Integer;
  Res: string;
begin
  PrintLn(Ansi.Bold + Title + Ansi.Reset);
  if Length(Rules) = 0 then
  begin
    PrintLn('  (none)');
    Exit;
  end;
  for i := 0 to High(Rules) do
  begin
    Res := Rules[i].Resource;
    if Res = '' then Res := '*';
    PrintLn(Format('  %3d  %-6s  tool=%-28s resource=%s',
            [i, EffectName(Rules[i].Effect), Rules[i].Tool, Res]));
  end;
end;

function Cmd_Permissions_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Sub, Tool, Res: string;
  D: TPermDecision;
begin
  Result := 0;
  if (Length(Argv) = 0) or (Argv[0] = '-h') or (Argv[0] = '--help') then
  begin
    Help;
    Exit;
  end;
  Sub := LowerCase(Argv[0]);
  { Install the rules the way a running pasclaw would: LoadConfig calls
    ApplyConfigGlobals, which sets the config rules and reads policies.json. }
  Cfg := LoadConfig;
  try
    if Sub = 'list' then
    begin
      PrintRules('policies  (' + PolicyFilePath(GetHome) + ')', PolicyRules);
      if PolicyLoadFailures > 0 then
        PrintLn(Ansi.Yellow + '  ! the last read of that file was unusable; ' +
                'these are the rules still in force, not what is on disk' +
                Ansi.Reset);
      PrintLn;
      PrintRules('config    (' + GetConfigPath + ' "permissions")', PermissionRules);
      PrintLn;
      PrintLn(Ansi.Dim + '  evaluation: policies first; a policy deny is final and a policy ask' + Ansi.Reset);
      PrintLn(Ansi.Dim + '  outranks a config allow. Within a list the last matching rule wins.' + Ansi.Reset);
      PrintLn(Ansi.Dim + '  No match = no opinion: the sandbox and mode gates still apply.' + Ansi.Reset);
    end
    else if Sub = 'test' then
    begin
      if Length(Argv) < 2 then
      begin
        PrintErr('permissions test needs a tool name');
        Help;
        Exit(2);
      end;
      Tool := Argv[1];
      if Length(Argv) >= 3 then Res := Argv[2] else Res := '';
      D := Decide(Tool, Res);
      case D.Effect of
        peNone:
          PrintLn('no rule matches ' + Tool + ' -> proceeds through the existing gates');
        peAllow, peDeny, peAsk:
          begin
            PrintLn(Ansi.Bold + EffectName(D.Effect) + Ansi.Reset + '  ' + Tool +
                    ' ' + Res);
            PrintLn('  by ' + PermissionAskReason(D));
          end;
      end;
    end
    else
    begin
      PrintErr('unknown permissions subcommand: ' + Argv[0]);
      Help;
      Result := 2;
    end;
  finally
    Cfg.Free;
  end;
end;

end.
