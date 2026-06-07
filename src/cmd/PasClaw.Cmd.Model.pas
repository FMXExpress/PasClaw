{ Model — view or switch the default model. }
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

function FindProviderConfig(Cfg: TConfig; const Name: string;
                            out Idx: Integer): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Cfg.Providers) do
    if SameText(Cfg.Providers[i].Name, Name) then
    begin
      Idx := i;
      Exit(True);
    end;
  Idx := -1;
  Result := False;
end;

function DoShow: Integer;
{ Adds a "cache freshness" annotation for the default provider's
  /models cache when one exists, plus a hint to refresh when nothing
  is cached. The actual cached model body lives in
  $PASCLAW_HOME/cache/models/<kind>.json; `pasclaw model list`
  surfaces it in full. }
var
  Cfg: TConfig;
  Idx: Integer;
  R:   TModelDiscoveryResult;
  Kind: string;
begin
  Cfg := LoadConfig;
  try
    PrintLn('default provider: ' + Cfg.DefaultProvider);
    PrintLn('default model:    ' + Cfg.DefaultModel);

    if Cfg.DefaultProvider <> '' then
    begin
      if FindProviderConfig(Cfg, Cfg.DefaultProvider, Idx) then
        Kind := Cfg.Providers[Idx].Kind
      else
        Kind := Cfg.DefaultProvider;

      if Kind <> '' then
      begin
        if LoadCachedModels(Kind, R) then
          PrintLn(Format('models cached:    %d (refreshed %s)',
                         [Length(R.Models), HumanAge(R.FetchedAt)]))
        else
          PrintLn('models cached:    ' + Ansi.Dim +
                  '(none — run `pasclaw model refresh ' + Cfg.DefaultProvider +
                  '` to populate)' + Ansi.Reset);
      end;
    end;
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function ResolveSpecForName(Cfg: TConfig; const Name: string;
                            out Spec: TProviderSpec;
                            out Base, Key: string;
                            out ErrMsg: string): Boolean;
{ Walks the same path NewProviderFromConfig walks — find the config
  entry by Name, look its Kind up in the catalog, resolve base / key
  via catalog defaults. Centralises the lookup so refresh + list both
  fail with the same operator-facing wording. }
var
  Idx: Integer;
begin
  Result := False;
  ErrMsg := '';
  if not FindProviderConfig(Cfg, Name, Idx) then
  begin
    ErrMsg := 'no provider entry for "' + Name +
              '" — run `pasclaw auth login ' + Name + '` first';
    Exit;
  end;
  if not LookupProvider(Cfg.Providers[Idx].Kind, Spec) then
  begin
    ErrMsg := 'provider "' + Name + '" has unknown kind "' +
              Cfg.Providers[Idx].Kind + '"';
    Exit;
  end;
  Base := Cfg.Providers[Idx].APIBase;
  if Base = '' then Base := Spec.DefaultBase;
  Key := Cfg.Providers[Idx].APIKey;
  Result := True;
end;

function RefreshOne(Cfg: TConfig; const Name: string): Boolean;
var
  Spec: TProviderSpec;
  Base, Key, Err: string;
  R: TModelDiscoveryResult;
begin
  Result := False;
  if not ResolveSpecForName(Cfg, Name, Spec, Base, Key, Err) then
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
  SaveCachedModels(Spec.Kind, R);
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
  Cfg: TConfig;
  Idx, i, Cap: Integer;
  Kind, Label_: string;
  R: TModelDiscoveryResult;
begin
  if Length(Argv) < 2 then
  begin
    PrintLn('Usage: pasclaw model list <provider>');
    Exit(1);
  end;
  Cfg := LoadConfig;
  try
    if FindProviderConfig(Cfg, Argv[1], Idx) then
      Kind := Cfg.Providers[Idx].Kind
    else
      Kind := Argv[1];

    if not LoadCachedModels(Kind, R) then
    begin
      PrintLn('No cache for "' + Argv[1] +
              '". Run `pasclaw model refresh ' + Argv[1] + '` first.');
      Exit(1);
    end;
    PrintLn(Format('%s (%d cached, refreshed %s)',
                   [Argv[1], Length(R.Models), HumanAge(R.FetchedAt)]));

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
                     [Length(R.Models) - Cap, ModelCachePath(Kind)]) +
              Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
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
