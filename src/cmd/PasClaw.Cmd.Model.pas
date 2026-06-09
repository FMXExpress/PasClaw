{ Model -- view or switch the default model. }
unit PasClaw.Cmd.Model;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Model_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.CliUI,
  PasClaw.Providers.Catalog,
  PasClaw.Providers.Models;

procedure Help;
begin
  PrintLn('Usage:');
  PrintLn('  pasclaw model show                    Print the active default + cache freshness');
  PrintLn('  pasclaw model set <name>              Set the default model');
  PrintLn('  pasclaw model add <provider> <name>   Pin a per-provider model override');
  PrintLn('  pasclaw model list <provider>         Show the cached model list for a provider');
  PrintLn('  pasclaw model refresh <provider>      Hit /v1/models and refresh the cache');
  PrintLn('  pasclaw model refresh --all           Refresh every configured provider');
end;

function DoShow: Integer;
{ Adds a "cache freshness" annotation for the default provider's
  /models cache, plus a top-N inline preview when a cache exists so
  `pasclaw model` is actually informative without a follow-up
  `model list` call -- user feedback on the first cut was that the
  list "wasn't there" because we only surfaced a count. The cached
  body lives in $PASCLAW_HOME/cache/models/<provider-name>.json
  keyed on the Provider Name (PR #171 Codex P2). }
const
  PREVIEW_TOP_N = 10;
var
  Cfg: TConfig;
  R:   TModelDiscoveryResult;
  i, N: Integer;
  Label_: string;
begin
  Cfg := LoadConfig;
  try
    PrintLn('default provider: ' + Cfg.DefaultProvider);
    PrintLn('default model:    ' + Cfg.DefaultModel);

    if Cfg.DefaultProvider = '' then
      Exit(0);

    if not LoadCachedModels(Cfg.DefaultProvider, R) then
    begin
      PrintLn('models cached:    ' + Ansi.Dim +
              '(none -- run `pasclaw model refresh ' + Cfg.DefaultProvider +
              '` to populate)' + Ansi.Reset);
      Exit(0);
    end;

    PrintLn(Format('models cached:    %d (refreshed %s)',
                   [Length(R.Models), HumanAge(R.FetchedAt)]));
    PrintLn('');
    N := Length(R.Models);
    if N > PREVIEW_TOP_N then N := PREVIEW_TOP_N;
    for i := 0 to N - 1 do
    begin
      Label_ := R.Models[i].Id;
      if (R.Models[i].Display <> '') and (R.Models[i].Display <> R.Models[i].Id) then
        Label_ := Label_ + Ansi.Dim + '   (' + R.Models[i].Display + ')' +
                  Ansi.Reset;
      PrintLn('  ' + Ansi.Dim + '·' + Ansi.Reset + ' ' + Label_);
    end;
    if Length(R.Models) > N then
      PrintLn(Ansi.Dim +
              Format('  (+ %d more -- run `pasclaw model list %s` for the full roster)',
                     [Length(R.Models) - N, Cfg.DefaultProvider]) +
              Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function RefreshOne(Cfg: TConfig; const Name: string): Boolean;
{ Spec lookup lives in PasClaw.Providers.Models so the TUI's inline
  /model auto-refresh path can reuse it without duplicating the
  PR #171 Codex P2 Kind-normalisation logic. }
var
  Spec: TProviderSpec;
  Base, Key, Err: string;
  R: TModelDiscoveryResult;
begin
  Result := False;
  if not ResolveProviderSpecForName(Cfg, Name, Spec, Base, Key, Err) then
  begin
    PrintLn('  ' + Ansi.Red + '✗ ' + Ansi.Reset + Name + ': ' + Err);
    Exit;
  end;
  PrintLn('  ' + Ansi.Dim + '· ' + Ansi.Reset +
          'fetching /models from ' + Spec.DisplayName + ' ...');
  R := DiscoverModels(Spec, Base, Key);
  if not R.Ok then
  begin
    PrintLn('  ' + Ansi.Red + '✗ ' + Ansi.Reset + Name + ': ' + R.ErrMsg);
    Exit;
  end;
  { Cache keyed on the operator-facing Provider Name (NOT Spec.Kind)
    so two Cfg.Providers[] rows that share a Kind but point at
    different APIBase/keys -- supported by NewProviderFromConfig --
    don't clobber each other's roster. Codex P2 on PR #171. }
  SaveCachedModels(Name, R);
  PrintLn(Format('  %s✓ %s%s: %d model(s) cached',
                 [Ansi.Green, Ansi.Reset, Name, Length(R.Models)]));
  Result := True;
end;

function DoRefresh(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  AnyFail, AnyOk: Boolean;
  i: Integer;
begin
  if Length(Argv) < 2 then
  begin
    PrintLn('Usage: pasclaw model refresh <provider> | --all');
    Exit(1);
  end;
  Cfg := LoadConfig;
  try
    if (Argv[1] = '--all') or (Argv[1] = '-a') then
    begin
      if Length(Cfg.Providers) = 0 then
      begin
        PrintLn('No providers configured. Run `pasclaw onboard` first.');
        Exit(1);
      end;
      AnyOk   := False;
      AnyFail := False;
      for i := 0 to High(Cfg.Providers) do
      begin
        if RefreshOne(Cfg, Cfg.Providers[i].Name) then
          AnyOk := True
        else
          AnyFail := True;
      end;
      if AnyOk and not AnyFail then Exit(0);
      if AnyOk then Exit(0);
      Exit(1);
    end
    else
    begin
      if RefreshOne(Cfg, Argv[1]) then Exit(0) else Exit(1);
    end;
  finally
    Cfg.Free;
  end;
end;

function DoList(const Argv: array of string): Integer;
var
  i, Cap: Integer;
  Name, Label_: string;
  R: TModelDiscoveryResult;
begin
  if Length(Argv) < 2 then
  begin
    PrintLn('Usage: pasclaw model list <provider>');
    Exit(1);
  end;
  { Cache lookup keys directly on the operator-facing Name -- same
    key RefreshOne writes to. Two configs sharing a Kind but with
    different APIBase keys each get their own roster file. }
  Name := Argv[1];
  if not LoadCachedModels(Name, R) then
  begin
    PrintLn('No cache for "' + Name +
            '". Run `pasclaw model refresh ' + Name + '` first.');
    Exit(1);
  end;
  PrintLn(Format('%s (%d cached, refreshed %s)',
                 [Name, Length(R.Models), HumanAge(R.FetchedAt)]));

  Cap := Length(R.Models);
  if Cap > 100 then Cap := 100;   { keep the printout readable; the
                                    JSON file holds the full list }
  for i := 0 to Cap - 1 do
  begin
    Label_ := R.Models[i].Display;
    if Label_ = R.Models[i].Id then
      PrintLn('  ' + Ansi.Dim + '·' + Ansi.Reset + ' ' + R.Models[i].Id)
    else
      PrintLn('  ' + Ansi.Dim + '·' + Ansi.Reset + ' ' + R.Models[i].Id +
              Ansi.Dim + '   (' + Label_ + ')' + Ansi.Reset);
  end;
  if Length(R.Models) > Cap then
    PrintLn(Ansi.Dim +
            Format('  … and %d more in %s',
                   [Length(R.Models) - Cap, ModelCachePath(Name)]) +
            Ansi.Reset);
  Result := 0;
end;

function DoSet(const Argv: array of string): Integer;
var
  Cfg: TConfig;
begin
  if Length(Argv) < 2 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Cfg.DefaultModel := Argv[1];
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'default model = ' + Argv[1]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoAdd(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  i: Integer;
  Found: Boolean;
begin
  if Length(Argv) < 3 then begin Help; Exit(1); end;
  Cfg := LoadConfig;
  try
    Found := False;
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Argv[1]) then
      begin
        Cfg.Providers[i].Model := Argv[2];
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
      Cfg.Providers[High(Cfg.Providers)].Name  := Argv[1];
      Cfg.Providers[High(Cfg.Providers)].Kind  := Argv[1];
      Cfg.Providers[High(Cfg.Providers)].Model := Argv[2];
    end;
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'registered ' + Argv[1] + '/' + Argv[2]);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Model_Run(const Argv: array of string): Integer;
begin
  if (Length(Argv) = 0) or (Argv[0] = 'show') then Exit(DoShow);
  if Argv[0] = 'set'     then Exit(DoSet(Argv));
  if Argv[0] = 'add'     then Exit(DoAdd(Argv));
  if Argv[0] = 'refresh' then Exit(DoRefresh(Argv));
  if Argv[0] = 'list'    then Exit(DoList(Argv));
  Help;
  Result := 1;
end;

end.
