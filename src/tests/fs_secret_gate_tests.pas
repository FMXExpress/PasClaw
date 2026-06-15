program fs_secret_gate_tests;
(*
  Pins IsRestrictedFsPath -- the denylist that keeps the operator-facing
  /v1/fs browse (HandleFSList / HandleFSRead) from listing or serving
  secret-bearing files. The leak it closes: config.json carries cleartext
  provider api_keys, the gateway bearer token, mcp env, and the web_search
  key, all of which GET /v1/config masks but the raw file would expose.

  Run with PASCLAW_CONFIG pointed at a non-"config.json" path so the
  exact-resolved-path branch is exercised alongside the basename rules.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,          { GetConfigPath }
  PasClaw.Gateway.Server;  { IsRestrictedFsPath }

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertRestricted(const Path: string; Want: Boolean; const Msg: string);
begin
  if IsRestrictedFsPath(Path) <> Want then
    Fail_(Msg + ' (path "' + Path + '", got ' + BoolToStr(IsRestrictedFsPath(Path), True)
          + ', want ' + BoolToStr(Want, True) + ')');
end;

begin
  { Basename denylist -- conventional secret files anywhere. }
  AssertRestricted('/home/op/.pasclaw/config.json', True,  'config.json hidden');
  AssertRestricted('/srv/app/.env',                 True,  '.env hidden');
  AssertRestricted('/srv/app/.env.local',           True,  '.env.local hidden');
  AssertRestricted('/etc/ssl/server.pem',           True,  '.pem hidden');
  AssertRestricted('/etc/ssl/server.key',           True,  '.key hidden');

  { Ordinary files stay visible. }
  AssertRestricted('/home/op/workspace/README.md',  False, 'README visible');
  AssertRestricted('/home/op/workspace/notes.txt',  False, 'txt visible');
  AssertRestricted('/home/op/workspace/config.yaml', False, 'unrelated yaml visible');
  AssertRestricted('',                              False, 'empty path not restricted');

  { Exact-resolved-config-path branch: PASCLAW_CONFIG points the test at a
    file NOT named config.json, so only the exact match can catch it. }
  if LowerCase(ExtractFileName(GetConfigPath)) <> 'config.json' then
  begin
    AssertRestricted(GetConfigPath, True, 'resolved $PASCLAW_CONFIG hidden');
    { A sibling that is not the config file is still visible. }
    AssertRestricted(ExtractFilePath(GetConfigPath) + 'sibling.txt', False,
                     'sibling of moved config visible');
  end;

  WriteLn('fs_secret_gate_tests: OK');
end.
