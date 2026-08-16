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
  {$IFDEF UNIX}BaseUnix,{$ENDIF}
  PasClaw.Utils,           { JoinPath, GetHome }
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

{$IFDEF UNIX}
procedure WriteSmallFile(const Path, Content: string);
var
  F: Text;
begin
  AssignFile(F, Path);
  Rewrite(F);
  Write(F, Content);
  CloseFile(F);
end;

procedure RunSymlinkChecks;
var
  Dir, Cfg, KeyTarget, Plain: string;
  AliasCfg, AliasKey, AliasPlain, HardCfg: string;
begin
  { Absolute paths so the symlink targets resolve regardless of cwd. }
  Cfg := ExpandFileName(GetConfigPath); { build/fs-gate-test.cfg via Makefile }
  Dir := ExtractFilePath(Cfg);
  { The config target must exist so realpath/inode can resolve it. }
  WriteSmallFile(Cfg, '{"api_key":"secret"}');

  { Innocuously-named symlink whose target IS the config -> caught by inode
    and by the canonical-path exact match. }
  AliasCfg := Dir + 'notes.txt';
  DeleteFile(AliasCfg);
  if fpSymlink(PChar(Cfg), PChar(AliasCfg)) <> 0 then Fail_('could not symlink notes.txt');
  AssertRestricted(AliasCfg, True, 'symlink to config hidden');

  { Symlink to a *.key target under a harmless name -> caught by the
    denylist running against the resolved target basename. }
  KeyTarget := Dir + 'tls-server.key';
  WriteSmallFile(KeyTarget, 'PRIVATE KEY');
  AliasKey := Dir + 'harmless.txt';
  DeleteFile(AliasKey);
  if fpSymlink(PChar(KeyTarget), PChar(AliasKey)) <> 0 then Fail_('could not symlink harmless.txt');
  AssertRestricted(AliasKey, True, 'symlink to .key hidden');

  { Symlink to an ordinary file stays visible. }
  Plain := Dir + 'plain.txt';
  WriteSmallFile(Plain, 'hello');
  AliasPlain := Dir + 'link-ok.txt';
  DeleteFile(AliasPlain);
  if fpSymlink(PChar(Plain), PChar(AliasPlain)) <> 0 then Fail_('could not symlink link-ok.txt');
  AssertRestricted(AliasPlain, False, 'symlink to ordinary file visible');

  { Hardlink to the config (own name, shared inode) -> caught by inode.
    Skip silently if the platform/fs refuses the link. }
  HardCfg := Dir + 'hard.txt';
  DeleteFile(HardCfg);
  if fpLink(PChar(Cfg), PChar(HardCfg)) = 0 then
    AssertRestricted(HardCfg, True, 'hardlink to config hidden');
end;
{$ENDIF}

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

  { Symlink/hardlink bypass (PR #280 Codex P1): an innocuously-named alias
    whose target is a secret file must still be restricted, because
    HandleFSRead opens it with a symlink-following TFileStream. Exercise
    the realpath + inode resolution on Unix with real files. }
  {$IFDEF UNIX}
  RunSymlinkChecks;
  {$ENDIF}

  (* MCP OAuth token store. $PASCLAW_HOME/oauth/<server>.json holds
     access_token and refresh_token in cleartext, and its basename is
     whatever the MCP server happens to be called -- so no basename rule
     can cover it and only a directory test works.

     Demonstrated live before the guard existed: with
     sandbox.allow_read_paths widened to the home tree,
     GET /v1/fs/read?path=$PASCLAW_HOME/oauth/github.json returned the
     tokens while config.json was correctly refused. Same endpoint, same
     threat, one covered and one not. *)
  AssertRestricted(JoinPath(JoinPath(GetHome, 'oauth'), 'github.json'),
                   True,  'MCP OAuth token file hidden');
  AssertRestricted(JoinPath(JoinPath(GetHome, 'oauth'), 'any-server-name.json'),
                   True,  'OAuth store hidden whatever the server is called');
  AssertRestricted(JoinPath(JoinPath(JoinPath(GetHome, 'oauth'), 'nested'), 'x.json'),
                   True,  'nested file under oauth/ hidden');
  { A sibling directory whose name merely starts with the same letters
    must NOT be swept up -- the check is a path-boundary test, not a
    string prefix. }
  AssertRestricted(JoinPath(GetHome, 'oauth-notes.txt'),
                   False, 'oauth-notes.txt is not inside oauth/ and stays visible');

  WriteLn('fs_secret_gate_tests: OK');
end.
