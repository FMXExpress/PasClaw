{ Auth -- login/logout/status for configured providers. }
unit PasClaw.Cmd.Auth;
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Auth_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, StrUtils, PasClaw.Config, PasClaw.Utils, PasClaw.CliUI, PasClaw.Logger;

procedure Help;
begin
  PrintLn('Usage: pasclaw auth <login|logout|status|weixin> [provider]');
end;

function DoStatus: Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    if Length(Cfg.Providers) = 0 then
    begin
      PrintLn('(no providers configured -- run `pasclaw onboard`)');
      Exit(0);
    end;
    for i := 0 to High(Cfg.Providers) do
      PrintLn(Format('%14s  key: %s',
        [Cfg.Providers[i].Name,
         IfThen(Cfg.Providers[i].APIKey <> '', 'present', 'missing')]));
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoLogin(const Provider: string): Integer;
var
  Cfg: TConfig;
  Key: string;
  i: Integer;
  Found: Boolean;
begin
  Cfg := LoadConfig;
  try
    Print('API key for ' + Provider + ': ');
    ReadLn(Key);
    Found := False;
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Provider) then
      begin
        Cfg.Providers[i].APIKey := Key;
        Found := True;
        Break;
      end;
    if not Found then
    begin
      SetLength(Cfg.Providers, Length(Cfg.Providers) + 1);
      Cfg.Providers[High(Cfg.Providers)].Name   := Provider;
      Cfg.Providers[High(Cfg.Providers)].Kind   := Provider;
      Cfg.Providers[High(Cfg.Providers)].APIKey := Key;
    end;
    SaveConfig(Cfg);
    PrintLn(Ansi.Green + '✓ ' + Ansi.Reset + 'stored key for ' + Provider);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function DoLogout(const Provider: string): Integer;
var
  Cfg: TConfig;
  i: Integer;
begin
  Cfg := LoadConfig;
  try
    for i := 0 to High(Cfg.Providers) do
      if SameText(Cfg.Providers[i].Name, Provider) then
        Cfg.Providers[i].APIKey := '';
    SaveConfig(Cfg);
    PrintLn('cleared key for ' + Provider);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

function Cmd_Auth_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then begin Help; Exit(1); end;
  Sub := Argv[0];
  if      Sub = 'status' then Result := DoStatus
  else if (Sub = 'login') and (Length(Argv) >= 2) then Result := DoLogin(Argv[1])
  else if (Sub = 'logout') and (Length(Argv) >= 2) then Result := DoLogout(Argv[1])
  else if Sub = 'weixin' then
  begin
    PrintLn('(weixin/WeChat QR linking will land in Phase 5)');
    Result := 0;
  end
  else begin Help; Result := 1; end;
end;

end.
