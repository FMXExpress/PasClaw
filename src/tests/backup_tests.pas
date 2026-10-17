program backup_tests;
(*
  PasClaw.Backup -- archives that can be restored, and a rotation policy
  that is tested rather than trusted.

    - BackupFileName / ParseBackupStamp round-trip; foreign names are
      rejected (never pruned).
    - SelectBackupsToPrune: the newest is always kept; 7/4/6 keeps the
      newest per day / ISO week / month; same-day older copies go; a
      zero tier keeps nothing for that tier; foreign names are ignored.
    - MaskConfigSecretsJSON masks api_key / env / gateway.token /
      web_search.api_key and nothing else; ListRedactedSecrets names them.
    - RunBackup against a temp home: the zip exists and is named right,
      RESTORE.md and config.redacted.json are inside, the WebView2 profile
      and a -journal file are NOT, the real API key is nowhere in the
      archive, and rotation removed the planted stale archives but not a
      foreign zip.
    - RunRestore into a fresh home: files come back byte-identical,
      RESTORE.md and the redacted config land beside the workspace,
      config.json is NOT created; restoring again refuses without --force
      and overlays with it.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, DateUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Skills.Zip,
  PasClaw.Backup;

var
  GTmp: string;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqInt(Got, Want: Integer; const Msg: string);
begin if Got <> Want then Fail_(Format('%s (got %d, want %d)', [Msg, Got, Want])); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '"'); end;
procedure AssertNotContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) > 0 then Fail_(Msg + ' -- did not expect "' + Needle + '"'); end;

function InList(const L: array of string; const S: string): Boolean;
var i: Integer;
begin
  for i := 0 to High(L) do if L[i] = S then Exit(True);
  Result := False;
end;

procedure TestNames;
var
  N: string;
  W: TDateTime;
begin
  N := BackupFileName('workspace', EncodeDateTime(2026, 10, 17, 3, 4, 5, 0));
  AssertEqStr(N, 'pasclaw-workspace-20261017-030405.zip', 'file name shape');
  AssertTrue(ParseBackupStamp(N, W), 'own name parses');
  AssertEqStr(FormatDateTime('yyyy-mm-dd hh:nn:ss', W), '2026-10-17 03:04:05', 'stamp round-trips');
  AssertTrue(ParseBackupStamp('/some/dir/' + N, W), 'parses with a directory');
  AssertTrue(not ParseBackupStamp('holiday-photos.zip', W), 'foreign zip rejected');
  AssertTrue(not ParseBackupStamp('pasclaw-workspace-20261399-030405.zip', W), 'impossible date rejected');
  AssertTrue(not ParseBackupStamp('pasclaw-workspace-20261017-030405.tar', W), 'wrong extension rejected');
  WriteLn('  ok: backup names round-trip, foreign names rejected');
end;

procedure TestRotation;
var
  Names: array of string;
  Prune: TArray<string>;
  D: TDateTime;
  i: Integer;
  procedure AddName(const When: TDateTime);
  begin
    SetLength(Names, Length(Names) + 1);
    Names[High(Names)] := BackupFileName('ws', When);
  end;
begin
  { 40 consecutive days ending 2026-10-17, one backup each at 02:00, plus a
    second same-day backup on the last day and a foreign zip. }
  SetLength(Names, 0);
  D := EncodeDateTime(2026, 10, 17, 2, 0, 0, 0);
  for i := 0 to 39 do AddName(IncDay(D, -i));
  AddName(EncodeDateTime(2026, 10, 17, 9, 30, 0, 0));   { newest of all }
  SetLength(Names, Length(Names) + 1);
  Names[High(Names)] := 'holiday-photos.zip';

  Prune := SelectBackupsToPrune(Names, 7, 4, 6);
  AssertTrue(not InList(Prune, 'holiday-photos.zip'), 'foreign zip never pruned');
  AssertTrue(not InList(Prune, BackupFileName('ws', EncodeDateTime(2026, 10, 17, 9, 30, 0, 0))),
             'newest kept');
  AssertTrue(InList(Prune, BackupFileName('ws', D)),
             'older same-day copy pruned (daily keeps the newest of the day)');
  { Days 2..7 back: kept by the daily tier. Day 8 back: 2026-10-09, not a
    daily survivor; is it a weekly one? Weeks: 10-17 (W42), 10-11..10-16 ->
    the newest in W41 is 10-11 (Sunday is end of ISO week? ISO weeks run
    Mon-Sun; 2026-10-11 is a Sunday, W41). So 10-09 (Friday, W41) goes. }
  for i := 1 to 6 do
    AssertTrue(not InList(Prune, BackupFileName('ws', IncDay(D, -i))),
               Format('day -%d kept by the daily tier', [i]));
  AssertTrue(InList(Prune, BackupFileName('ws', IncDay(D, -8))), 'day -8 pruned (neither daily nor newest of its week)');
  AssertTrue(not InList(Prune, BackupFileName('ws', EncodeDateTime(2026, 10, 11, 2, 0, 0, 0))),
             '2026-10-11 kept as the newest of ISO week 41');
  AssertTrue(not InList(Prune, BackupFileName('ws', EncodeDateTime(2026, 9, 30, 2, 0, 0, 0))),
             '2026-09-30 kept as the newest of September (monthly tier)');
  AssertTrue(InList(Prune, BackupFileName('ws', EncodeDateTime(2026, 9, 10, 2, 0, 0, 0))),
             '2026-09-10 pruned (older than every weekly bucket, not month-newest)');

  { All tiers zero: only the newest survives. }
  Prune := SelectBackupsToPrune(Names, 0, 0, 0);
  AssertEqInt(Length(Prune), 40, 'zero tiers keep only the newest (41 own - 1)');
  AssertTrue(not InList(Prune, 'holiday-photos.zip'), 'foreign zip still untouched');

  { Nothing to prune when under every limit. }
  Prune := SelectBackupsToPrune([BackupFileName('ws', D), BackupFileName('ws', IncDay(D, -1))], 7, 4, 6);
  AssertEqInt(Length(Prune), 0, 'two recent backups: nothing pruned');
  WriteLn('  ok: rotation keeps newest / per-day / per-week / per-month, ignores foreign names');
end;

const
  CfgJSON =
    '{"default_provider":"anthropic","default_model":"m",' +
    '"providers":[{"name":"anthropic","api_key":"sk-ant-REALKEY-123"},{"name":"ollama","api_key":""}],' +
    '"mcp_servers":[{"name":"gh","env":"GITHUB_TOKEN=ghp_REAL"}],' +
    '"gateway":{"token":"gw-REAL","port":18790},' +
    '"web_search":{"provider":"brave","api_key":"brave-REAL"},' +
    '"memory_facts_budget":1234}';

procedure TestMask;
var
  M, C: string;
  R: TArray<string>;
begin
  M := MaskConfigSecretsJSON(CfgJSON);
  AssertTrue(M <> '', 'mask parses');
  AssertNotContains(M, 'REAL', 'no real secret survives the mask');
  { The serialiser may pretty-print; compare with whitespace removed. }
  C := StringReplace(StringReplace(StringReplace(M, ' ', '', [rfReplaceAll]),
                     #10, '', [rfReplaceAll]), #13, '', [rfReplaceAll]);
  AssertContains(C, '"port":18790', 'non-secret gateway field intact');
  AssertContains(C, '"memory_facts_budget":1234', 'unrelated field intact');
  AssertContains(C, '"default_model":"m"', 'model intact');
  AssertContains(C, '"provider":"brave"', 'web_search provider intact');
  AssertEqStr(MaskConfigSecretsJSON('not json'), '', 'unparseable -> empty');
  R := ListRedactedSecrets(M);
  AssertEqInt(Length(R), 4, 'four secrets were masked');
  AssertTrue(InList(R, 'providers[anthropic].api_key'), 'anthropic key listed');
  AssertTrue(not InList(R, 'providers[ollama].api_key'), 'empty ollama key not listed');
  AssertTrue(InList(R, 'mcp_servers[gh].env'), 'mcp env listed');
  AssertTrue(InList(R, 'gateway.token'), 'gateway token listed');
  AssertTrue(InList(R, 'web_search.api_key'), 'web_search key listed');
  WriteLn('  ok: secrets masked and named, nothing else touched');
end;

procedure WriteF(const Path, Text: string);
begin
  EnsureDir(ExtractFileDir(Path));
  WriteFileText(Path, Text);
end;

procedure TestBackupAndRestore;
var
  Home, Home2, Ws, Dest, Err, Listing, Unz: string;
  Res: TBackupResult;
  RR: TRestoreResult;
  D: TDateTime;
  i: Integer;
  F: TextFile;
begin
  Home := JoinPath(GTmp, 'home');
  Ws := JoinPath(Home, 'workspace');
  WriteF(JoinPath(Home, 'config.json'), CfgJSON);
  WriteF(JoinPath(Ws, 'memory/MEMORY.md'), '# Memory' + #10 + 'caf' + #$C3#$A9 + ' MEMBODY');
  WriteF(JoinPath(Ws, 'memory/USER.md'), 'Name: Eli');
  WriteF(JoinPath(Ws, 'sessions/s1.json'), '{"id":"s1"}');
  WriteF(JoinPath(Ws, 'memory/facts.db-journal'), 'journal junk');
  WriteF(JoinPath(Ws, 'browser/webview2/Default/Cookies'), 'cookie jar');
  WriteF(JoinPath(Ws, 'skills/x/SKILL.md'), '---' + #10 + 'name: x' + #10 + '---');
  Dest := JoinPath(GTmp, 'backups');
  EnsureDir(Dest);
  { Plant stale archives: 10 daily ones from 20 days back, and a foreign zip. }
  D := IncDay(Now, -20);
  for i := 0 to 9 do
    WriteF(JoinPath(Dest, BackupFileName('workspace', IncDay(D, -i))), 'stale');
  WriteF(JoinPath(Dest, 'holiday-photos.zip'), 'mine');

  AssertTrue(RunBackup(Home, 'workspace', Dest, 'pasclaw-test 0.0.0', 7, 4, 6, Res, Err),
             'backup succeeds: ' + Err);
  AssertTrue(FileExists(Res.ZipPath), 'zip written');
  AssertTrue(Pos('pasclaw-workspace-', ExtractFileName(Res.ZipPath)) = 1, 'zip named by this unit');
  AssertEqInt(Res.Files, 4, 'four workspace files packed (journal and webview2 excluded)');
  AssertEqInt(Length(Res.Redacted), 4, 'four secrets reported redacted');
  AssertTrue(FileExists(JoinPath(Dest, 'holiday-photos.zip')), 'foreign zip survived rotation');
  { Rotation is borg-shaped: "keep daily 7" keeps the newest archive of
    each of the last 7 days THAT HAVE ONE, so with 10 consecutive stale
    days plus today the daily tier keeps today + 6 stale days and the
    weekly / monthly tiers keep one more each at most. The exact policy
    is pinned by TestRotation on fixed dates; here we check that pruning
    happened, touched only our own names, and that disk agrees. }
  AssertTrue(Length(Res.Pruned) >= 1, Format('rotation pruned stale archives (%d)', [Length(Res.Pruned)]));
  AssertTrue(Length(Res.Pruned) <= 4, Format('rotation kept the daily/weekly/monthly survivors (%d pruned)', [Length(Res.Pruned)]));
  for i := 0 to High(Res.Pruned) do
  begin
    AssertTrue(Pos('pasclaw-workspace-', Res.Pruned[i]) = 1, 'only own archives pruned');
    AssertTrue(not FileExists(JoinPath(Dest, Res.Pruned[i])), 'pruned archive is gone from disk');
  end;
  AssertTrue(FileExists(JoinPath(Dest, BackupFileName('workspace', D))), 'newest stale day kept by the daily tier');

  { Inspect the archive by extracting it somewhere neutral. }
  Unz := JoinPath(GTmp, 'inspect');
  AssertTrue(ExtractZipToDir(Res.ZipPath, Unz, Err), 'archive extracts: ' + Err);
  AssertTrue(FileExists(JoinPath(Unz, 'RESTORE.md')), 'RESTORE.md inside');
  AssertTrue(FileExists(JoinPath(Unz, 'config.redacted.json')), 'redacted config inside');
  AssertTrue(FileExists(JoinPath(Unz, 'workspace/memory/MEMORY.md')), 'workspace file inside under its dir name');
  AssertTrue(not FileExists(JoinPath(Unz, 'workspace/memory/facts.db-journal')), 'journal excluded');
  AssertTrue(not DirectoryExists(JoinPath(Unz, 'workspace/browser/webview2')), 'webview2 profile excluded');
  Listing := ReadFileText(JoinPath(Unz, 'config.redacted.json'));
  AssertNotContains(Listing, 'REALKEY', 'real key not in archive');
  AssertNotContains(Listing, 'ghp_REAL', 'real mcp env not in archive');
  Listing := ReadFileText(JoinPath(Unz, 'RESTORE.md'));
  AssertContains(Listing, 'pasclaw restore pasclaw-workspace-', 'notes carry the restore command');
  AssertContains(Listing, 'providers[anthropic].api_key', 'notes name the secret to re-enter');
  AssertContains(Listing, 'pasclaw-test 0.0.0', 'notes carry the version');
  AssertContains(Listing, '4 files', 'notes carry the file count');

  { Restore into a fresh home. }
  Home2 := JoinPath(GTmp, 'home2');
  AssertTrue(RunRestore(Res.ZipPath, Home2, False, RR, Err), 'restore succeeds: ' + Err);
  AssertEqStr(RR.Workspace, 'workspace', 'workspace dir name detected');
  AssertEqInt(RR.Files, 4, 'four files restored');
  AssertEqStr(ReadFileText(JoinPath(Home2, 'workspace/memory/MEMORY.md')),
              '# Memory' + #10 + 'caf' + #$C3#$A9 + ' MEMBODY', 'file content byte-identical (UTF-8)');
  AssertTrue(FileExists(JoinPath(Home2, 'RESTORE-workspace.md')), 'notes left beside the workspace');
  AssertTrue(FileExists(JoinPath(Home2, 'config.redacted.json')), 'redacted config left beside the workspace');
  AssertTrue(not FileExists(JoinPath(Home2, 'config.json')), 'config.json is never written by restore');
  AssertEqInt(Length(RR.Redacted), 4, 'restore reports the secrets to re-enter');
  AssertTrue(not DirectoryExists(JoinPath(Home2, '.restore-' + IntToStr(GetProcessID))), 'temp dir cleaned');

  { Second restore refuses, then overlays with Force. }
  AssertTrue(not RunRestore(Res.ZipPath, Home2, False, RR, Err), 'restore over existing refuses');
  AssertContains(Err, '--force', 'refusal names --force');
  WriteF(JoinPath(Home2, 'workspace/memory/extra.md'), 'kept');
  AssertTrue(RunRestore(Res.ZipPath, Home2, True, RR, Err), 'forced restore succeeds: ' + Err);
  AssertTrue(FileExists(JoinPath(Home2, 'workspace/memory/extra.md')), 'overlay keeps files not in the archive');

  { A missing workspace is an error, not an empty archive. }
  AssertTrue(not RunBackup(Home, 'nope', Dest, 'v', 7, 4, 6, Res, Err), 'missing workspace fails');
  { Archive names carry a one-second stamp; step past the first backup's. }
  Sleep(1100);
  { A corrupt config.json refuses rather than shipping it unredacted. }
  AssignFile(F, JoinPath(Home, 'config.json')); Rewrite(F); Write(F, '{not json'); CloseFile(F);
  AssertTrue(not RunBackup(Home, 'workspace', Dest, 'v', 7, 4, 6, Res, Err), 'unparseable config refuses');
  AssertContains(Err, 'redact', 'refusal explains why');
  WriteLn('  ok: backup packs / excludes / redacts / rotates; restore round-trips, refuses, overlays');
end;

begin
  GTmp := JoinPath(GetTempDir, 'pasclaw-backup-test-' + IntToStr(GetProcessID));
  EnsureDir(GTmp);
  TestNames;
  TestRotation;
  TestMask;
  TestBackupAndRestore;
  WriteLn('PASS');
end.
