(*
  PasClaw.Backup - workspace backups that can actually be restored.

  What goes in one archive:

    <workspace>/...            the active workspace, minus caches that are
                               machine-bound or regenerable (the WebView2
                               profile, SQLite journals, .git)
    config.redacted.json       config.json with every secret replaced by
                               the gateway's mask placeholder -- enough to
                               see what was configured, never enough to
                               leak a key
    RESTORE.md                 what this is, which PasClaw wrote it, and
                               the exact command that puts it back

  The notes travel inside every archive on purpose. A backup found on a
  disk two years from now by someone who was not there when it was made
  should explain itself without a wiki.

  Rotation is the 7 / 4 / 6 shape the long-running setups converge on,
  with borg's semantics: the newest backup of each of the last KeepDaily
  days THAT HAVE ONE, of each of the last KeepWeekly ISO weeks that have
  one, and of each of the last KeepMonthly months that have one. Counting
  days-with-backups rather than calendar days means a machine that was
  off for a fortnight does not come back and delete its history. The
  newest archive is always kept. Everything else in the backup directory
  that this unit named is deleted after a successful write; files it did
  not name are never touched. SelectBackupsToPrune is pure so the policy
  is tested, not trusted.

  Remote targets (S3, R2, a NAS) are deliberately not here: the backup
  directory can be a mount, and copying a directory elsewhere is a solved
  problem with better tools than this one.
*)
unit PasClaw.Backup;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

const
  BackupPrefix       = 'pasclaw-';
  BackupExt          = '.zip';
  RestoreNotesName   = 'RESTORE.md';
  RedactedConfigName = 'config.redacted.json';
  FullConfigName     = 'config.json';

type
  TBackupResult = record
    ZipPath:  string;
    Files:    Integer;          { workspace files packed }
    Pruned:   TArray<string>;   { archives deleted by rotation }
    Redacted: TArray<string>;   { human labels of secrets that were masked; [] when WithSecrets }
    WithSecrets: Boolean;       { the archive holds the real config.json }
  end;

  TRestoreResult = record
    Workspace: string;          { workspace dir name found in the archive }
    Files:     Integer;         { files written }
    Notes:     string;          { RESTORE.md from the archive, '' if none }
    Redacted:  TArray<string>;  { secrets the operator must re-enter }
    ConfigWritten: Boolean;     { the archive carried a full config.json and it was put in place }
    ConfigBackedUpTo: string;   { the previous config.json, when --force replaced one }
  end;

{ pasclaw-<workspace>-YYYYMMDD-HHMMSS.zip. Pure. }
function BackupFileName(const Workspace: string; When: TDateTime): string;

{ Inverse of BackupFileName on the basename: True with When set when the
  name is one this unit would have produced. Pure. }
function ParseBackupStamp(const FileName: string; out When: TDateTime): Boolean;

{ Which of Names (basenames; non-matching ones are ignored and never
  returned) should be deleted under a keep-daily/weekly/monthly policy.
  The newest archive is always kept. Pure. }
function SelectBackupsToPrune(const Names: array of string;
                              KeepDaily, KeepWeekly, KeepMonthly: Integer): TArray<string>;

{ The notes written into every archive. Pure. }
function BuildRestoreNotes(const Version, Workspace, Home: string; When: TDateTime;
                           FileCount: Integer; const Redacted: array of string;
                           WithSecrets: Boolean): string;

{ Which secrets a masked config JSON is missing, as human labels
  ("providers[anthropic].api_key", "gateway.token"). Pure. }
function ListRedactedSecrets(const MaskedJSON: string): TArray<string>;

{ Write one archive of <Home>/<Workspace> into DestDir and apply rotation.
  Version is stamped into RESTORE.md. WithSecrets puts the real config.json
  in the archive instead of config.redacted.json -- a restore then brings
  every connected API back, and the archive must be stored like a
  credential. A DestDir inside the workspace is excluded from the walk, so
  backups never contain earlier backups. False with Err on any failure; a
  failed write never prunes. }
function RunBackup(const Home, Workspace, DestDir, Version: string;
                   KeepDaily, KeepWeekly, KeepMonthly: Integer;
                   WithSecrets: Boolean;
                   out Res: TBackupResult; out Err: string): Boolean;

{ Put an archive back under Home. Refuses when the workspace directory
  already exists unless Force, in which case the archive's files overlay
  it (files not in the archive are left alone). An archive made with
  WithSecrets carries config.json; it is written to Home when none exists,
  and with Force replaces the existing one after copying it to
  config.json.bak. A redacted-only archive never writes config.json.
  False with Err on failure. }
function RunRestore(const ZipPath, Home: string; Force: Boolean;
                    out Res: TRestoreResult; out Err: string): Boolean;

implementation

uses
  DateUtils,
  {$IFDEF FPC}
    Zipper,
  {$ELSE}
    System.Zip,
  {$ENDIF}
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Skills.Zip;

const
  { Basenames skipped at any depth. The WebView2 profile is the browser
    desktop's logins and cache -- hundreds of MB, machine-bound, and not
    something to put on a shared disk. Journals are mid-write state. }
  ExcludeNames: array[0..5] of string =
    ('.git', '.DS_Store', 'Thumbs.db', 'kb.db-journal', 'webview2', '.search.db');
  ExcludeSuffixes: array[0..2] of string =
    ('-journal', '-wal', '-shm');

{ ------------------------------------------------------------ naming }

function BackupFileName(const Workspace: string; When: TDateTime): string;
begin
  Result := BackupPrefix + Workspace + '-' +
            FormatDateTime('yyyymmdd"-"hhnnss', When) + BackupExt;
end;

function ParseBackupStamp(const FileName: string; out When: TDateTime): Boolean;
var
  Base, Stamp: string;
  n, Y, Mo, D, H, Mi, S: Integer;
begin
  Result := False;
  When := 0;
  Base := ExtractFileName(FileName);
  if (Length(Base) < Length(BackupPrefix) + 17 + Length(BackupExt)) then Exit;
  if not SameText(Copy(Base, 1, Length(BackupPrefix)), BackupPrefix) then Exit;
  if not SameText(Copy(Base, Length(Base) - Length(BackupExt) + 1, Length(BackupExt)), BackupExt) then Exit;
  n := Length(Base) - Length(BackupExt);
  { ...-YYYYMMDD-HHMMSS.zip : the stamp is the last 15 chars before .zip,
    preceded by a dash. }
  Stamp := Copy(Base, n - 14, 15);
  if (Length(Stamp) <> 15) or (Stamp[9] <> '-') then Exit;
  if (n - 15 < 1) or (Base[n - 15] <> '-') then Exit;
  Y  := StrToIntDef(Copy(Stamp, 1, 4), -1);
  Mo := StrToIntDef(Copy(Stamp, 5, 2), -1);
  D  := StrToIntDef(Copy(Stamp, 7, 2), -1);
  H  := StrToIntDef(Copy(Stamp, 10, 2), -1);
  Mi := StrToIntDef(Copy(Stamp, 12, 2), -1);
  S  := StrToIntDef(Copy(Stamp, 14, 2), -1);
  if (Y < 2000) or (Mo < 1) or (Mo > 12) or (D < 1) or (D > 31) or
     (H < 0) or (H > 23) or (Mi < 0) or (Mi > 59) or (S < 0) or (S > 59) then Exit;
  if not TryEncodeDateTime(Y, Mo, D, H, Mi, S, 0, When) then Exit;
  Result := True;
end;

{ ---------------------------------------------------------- rotation }

type
  TStamped = record
    Name: string;
    When: TDateTime;
  end;

function SelectBackupsToPrune(const Names: array of string;
                              KeepDaily, KeepWeekly, KeepMonthly: Integer): TArray<string>;
var
  Items: array of TStamped;
  Keep: array of Boolean;
  i, j, n: Integer;
  T: TStamped;
  W: TDateTime;
  Seen: TStringList;
  Key: string;
  Yr, Wk: Word;

  procedure KeepNewestPer(const Kind: string; Limit: Integer);
  { Walk newest-first; the first archive seen for each bucket is that
    bucket's survivor, until Limit distinct buckets have one. }
  var
    k: Integer;
    Buckets: Integer;
  begin
    if Limit <= 0 then Exit;
    Seen.Clear;
    Buckets := 0;
    for k := 0 to n - 1 do
    begin
      if Kind = 'day' then
        Key := FormatDateTime('yyyymmdd', Items[k].When)
      else if Kind = 'month' then
        Key := FormatDateTime('yyyymm', Items[k].When)
      else
      begin
        Wk := WeekOfTheYear(Items[k].When, Yr);
        Key := Format('%.4d-W%.2d', [Yr, Wk]);
      end;
      if Seen.IndexOf(Key) >= 0 then Continue;
      Seen.Add(Key);
      Inc(Buckets);
      Keep[k] := True;
      if Buckets >= Limit then Break;
    end;
  end;

begin
  SetLength(Result, 0);
  n := 0;
  SetLength(Items, Length(Names));
  for i := 0 to High(Names) do
    if ParseBackupStamp(Names[i], W) then
    begin
      Items[n].Name := Names[i];
      Items[n].When := W;
      Inc(n);
    end;
  SetLength(Items, n);
  if n = 0 then Exit;

  { Newest first. Insertion sort; a backup directory holds dozens. }
  for i := 1 to n - 1 do
  begin
    T := Items[i];
    j := i - 1;
    while (j >= 0) and (Items[j].When < T.When) do
    begin
      Items[j + 1] := Items[j];
      Dec(j);
    end;
    Items[j + 1] := T;
  end;

  SetLength(Keep, n);
  for i := 0 to n - 1 do Keep[i] := False;
  Keep[0] := True;   { the newest is always kept }

  Seen := TStringList.Create;
  try
    Seen.Sorted := True;
    Seen.Duplicates := dupIgnore;
    KeepNewestPer('day',   KeepDaily);
    KeepNewestPer('week',  KeepWeekly);
    KeepNewestPer('month', KeepMonthly);
  finally
    Seen.Free;
  end;

  for i := 0 to n - 1 do
    if not Keep[i] then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Items[i].Name;
    end;
end;

{ ------------------------------------------------------------- notes }

function BuildRestoreNotes(const Version, Workspace, Home: string; When: TDateTime;
                           FileCount: Integer; const Redacted: array of string;
                           WithSecrets: Boolean): string;
var
  i: Integer;
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Add('# PasClaw backup');
    L.Add('');
    L.Add('- Created: ' + FormatDateTime('yyyy-mm-dd hh:nn:ss', When));
    L.Add('- PasClaw: ' + Version);
    L.Add('- Workspace: `' + Workspace + '` (' + IntToStr(FileCount) + ' files)');
    L.Add('- Taken from: `' + Home + '`');
    L.Add('');
    L.Add('## What is in here');
    L.Add('');
    L.Add('- `' + Workspace + '/` -- the workspace: memory (MEMORY.md, USER.md, SOUL.md,');
    L.Add('  daily notes, facts.db), sessions, skills, knowledge base, checkpoints,');
    L.Add('  AGENTS.md, PLAN.md. Everything the agent knows.');
    if WithSecrets then
    begin
      L.Add('- `' + FullConfigName + '` -- the real config.json, **API keys and tokens included**.');
      L.Add('  This archive is a credential. Store it like one.');
    end
    else
    begin
      L.Add('- `' + RedactedConfigName + '` -- config.json with secrets replaced by `' +
            MaskedSecretPlaceholder + '`.');
      L.Add('  Providers, models, channels, sandbox, memory settings are all intact.');
    end;
    L.Add('- `' + RestoreNotesName + '` -- this file.');
    L.Add('');
    L.Add('Not included: the WebView2 browser profile, SQLite journals, `.git`.');
    L.Add('');
    L.Add('## Restore');
    L.Add('');
    L.Add('On a machine with PasClaw installed:');
    L.Add('');
    L.Add('```sh');
    L.Add('pasclaw restore ' + BackupFileName(Workspace, When));
    L.Add('```');
    L.Add('');
    L.Add('That unpacks `' + Workspace + '/` under the current `PASCLAW_HOME`');
    L.Add('(`~/.pasclaw` by default) and refuses if that workspace already exists;');
    L.Add('add `--force` to overlay an existing one.');
    L.Add('');
    if WithSecrets then
    begin
      L.Add('`config.json` is written too when none exists there; with `--force` the');
      L.Add('existing one is kept as `config.json.bak` and replaced. Nothing to re-enter.');
    end
    else
    begin
      L.Add('It never writes `config.json`: copy `' + RedactedConfigName + '` over it by');
      L.Add('hand, or run `pasclaw onboard`, then re-enter these secrets, which were');
      L.Add('deliberately not backed up (`pasclaw backup --with-secrets` includes them):');
      L.Add('');
      if Length(Redacted) = 0 then
        L.Add('- (none were set)')
      else
        for i := 0 to High(Redacted) do
          L.Add('- ' + Redacted[i]);
    end;
    L.Add('');
    L.Add('Then `pasclaw doctor` to confirm the workspace is seen, and');
    L.Add('`pasclaw memory status` if the hybrid search runtime needs provisioning');
    L.Add('again (model weights are not part of a backup).');
  finally
    Result := L.Text;
    L.Free;
  end;
end;

function ListRedactedSecrets(const MaskedJSON: string): TArray<string>;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;

  { Byte compare: PasClaw.Config has no codepage directive, so its '•••'
    literal carries a different codepage tag from the parser's UTF-8
    output and a plain string = would convert first. Same trick as
    RestoreMaskedConfigSecrets. }
  function IsMask(const S: string): Boolean;
  begin
    Result := RawByteString(S) = RawByteString(MaskedSecretPlaceholder);
  end;

  procedure Add(const S: string);
  begin
    SetLength(Result, Length(Result) + 1);
    Result[High(Result)] := S;
  end;

begin
  SetLength(Result, 0);
  if Trim(MaskedJSON) = '' then Exit;
  try
    Root := TJsonObject.Parse(MaskedJSON);
  except
    Root := nil;
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('providers');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          if IsMask(Item.GetStr('api_key', '')) then
            Add('providers[' + Item.GetStr('name', IntToStr(i)) + '].api_key');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Arr := Root.ChildArray('mcp_servers');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          if IsMask(Item.GetStr('env', '')) then
            Add('mcp_servers[' + Item.GetStr('name', IntToStr(i)) + '].env');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Item := Root.ChildObject('gateway');
    if Item <> nil then
    try
      if IsMask(Item.GetStr('token', '')) then Add('gateway.token');
    finally
      Item.Free;
    end;
    Item := Root.ChildObject('web_search');
    if Item <> nil then
    try
      if IsMask(Item.GetStr('api_key', '')) then Add('web_search.api_key');
    finally
      Item.Free;
    end;
    Arr := Root.ChildArray('channels');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          if IsMask(Item.GetStr('target', '')) then
            Add('channels[' + Item.GetStr('name', IntToStr(i)) + '].target');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Arr := Root.ChildArray('crons');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          if IsMask(Item.GetStr('channel_target', '')) then
            Add('crons[' + Item.GetStr('id', IntToStr(i)) + '].channel_target');
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

{ ----------------------------------------------------------- packing }

function Excluded(const Name: string): Boolean;
var
  i: Integer;
  L: string;
begin
  L := LowerCase(Name);
  for i := Low(ExcludeNames) to High(ExcludeNames) do
    if L = LowerCase(ExcludeNames[i]) then Exit(True);
  for i := Low(ExcludeSuffixes) to High(ExcludeSuffixes) do
    if (Length(L) > Length(ExcludeSuffixes[i])) and
       (Copy(L, Length(L) - Length(ExcludeSuffixes[i]) + 1, MaxInt) = ExcludeSuffixes[i]) then
      Exit(True);
  Result := False;
end;

function SamePath(const A, B: string): Boolean;
begin
  {$IFDEF MSWINDOWS}
  Result := SameText(ExcludeTrailingPathDelimiter(A), ExcludeTrailingPathDelimiter(B));
  {$ELSE}
  Result := ExcludeTrailingPathDelimiter(A) = ExcludeTrailingPathDelimiter(B);
  {$ENDIF}
end;

procedure Walk(const Root, Rel: string; Files: TStringList;
               const ExcludeAbsDir: string = '');
{ Forward-slash relative paths, the shape both zip libraries store.
  ExcludeAbsDir (absolute, or '') names one directory to skip wherever it
  sits in the tree -- the backup destination, so a backup directory inside
  the workspace never ends up inside the next backup. }
var
  SR: TSearchRec;
  Dir, Entry, Child: string;
begin
  Dir := Root;
  if Rel <> '' then Dir := Dir + PathDelim + StringReplace(Rel, '/', PathDelim, [rfReplaceAll]);
  if FindFirst(Dir + PathDelim + '*', faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if Excluded(SR.Name) then Continue;
      if Rel = '' then Entry := SR.Name else Entry := Rel + '/' + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        Child := Dir + PathDelim + SR.Name;
        if (ExcludeAbsDir <> '') and SamePath(ExpandFileName(Child), ExcludeAbsDir) then
          Continue;
        Walk(Root, Entry, Files, ExcludeAbsDir);
      end
      else
        Files.Add(Entry);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

{ UTF-8 in, UTF-8 out, via the shared helpers so the repo's file-IO lint
  holds here too. ReadTextFile tolerates a missing file. }
function ReadTextFile(const Path: string): string;
begin
  Result := '';
  if not FileExists(Path) then Exit;
  Result := ReadFileText(Path);
end;

procedure WriteTextFile(const Path, Text: string);
begin
  WriteFileText(Path, Text);
end;

procedure CopyFileRaw(const Src, Dst: string);
var
  I, O: TFileStream;
begin
  ForceDirectories(ExtractFileDir(Dst));
  I := TFileStream.Create(Src, fmOpenRead or fmShareDenyWrite);
  try
    O := TFileStream.Create(Dst, fmCreate);
    try
      if I.Size > 0 then O.CopyFrom(I, I.Size);
    finally
      O.Free;
    end;
  finally
    I.Free;
  end;
end;

procedure RemoveTreeQuiet(const Path: string);
var
  SR: TSearchRec;
  Child: string;
begin
  if not DirectoryExists(Path) then Exit;
  if FindFirst(Path + PathDelim + '*', faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Child := Path + PathDelim + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then RemoveTreeQuiet(Child)
      else SysUtils.DeleteFile(Child);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Path);
end;

function PackArchive(const WsDir, Workspace, ZipPath: string;
                     const Files: TStringList;
                     const NotesPath, ConfigPath, ConfigEntryName: string;
                     out Err: string): Boolean;
{$IFDEF FPC}
var
  Z: TZipper;
  i: Integer;
begin
  Result := False;
  Err := '';
  Z := TZipper.Create;
  try
    try
      for i := 0 to Files.Count - 1 do
        Z.Entries.AddFileEntry(
          WsDir + PathDelim + StringReplace(Files[i], '/', PathDelim, [rfReplaceAll]),
          Workspace + '/' + Files[i]);
      Z.Entries.AddFileEntry(NotesPath, RestoreNotesName);
      if ConfigPath <> '' then
        Z.Entries.AddFileEntry(ConfigPath, ConfigEntryName);
      Z.FileName := ZipPath;
      Z.ZipAllFiles;
      Result := True;
    except
      on E: Exception do Err := 'zip failed: ' + E.Message;
    end;
  finally
    Z.Free;
  end;
end;
{$ELSE}
var
  Z: TZipFile;
  i: Integer;
begin
  Result := False;
  Err := '';
  Z := TZipFile.Create;
  try
    try
      Z.Open(ZipPath, zmWrite);
      for i := 0 to Files.Count - 1 do
        Z.Add(WsDir + PathDelim + StringReplace(Files[i], '/', PathDelim, [rfReplaceAll]),
              Workspace + '/' + Files[i]);
      Z.Add(NotesPath, RestoreNotesName);
      if ConfigPath <> '' then
        Z.Add(ConfigPath, ConfigEntryName);
      Z.Close;
      Result := True;
    except
      on E: Exception do Err := 'zip failed: ' + E.Message;
    end;
  finally
    Z.Free;
  end;
end;
{$ENDIF}

function RunBackup(const Home, Workspace, DestDir, Version: string;
                   KeepDaily, KeepWeekly, KeepMonthly: Integer;
                   WithSecrets: Boolean;
                   out Res: TBackupResult; out Err: string): Boolean;
var
  WsDir, Stage, NotesPath, RedactedPath, ConfigPath, Masked, ZipPath, DestAbs: string;
  Files, Existing: TStringList;
  SR: TSearchRec;
  When: TDateTime;
  i: Integer;
  ToPrune: TArray<string>;
begin
  Result := False;
  Err := '';
  Res := Default(TBackupResult);
  WsDir := IncludeTrailingPathDelimiter(Home) + Workspace;
  if not DirectoryExists(WsDir) then
  begin
    Err := 'workspace directory not found: ' + WsDir;
    Exit;
  end;
  if not ForceDirectories(DestDir) then
  begin
    Err := 'cannot create backup directory: ' + DestDir;
    Exit;
  end;

  When := Now;
  ZipPath := IncludeTrailingPathDelimiter(DestDir) + BackupFileName(Workspace, When);
  if FileExists(ZipPath) then
  begin
    { Two backups within one second. Not worth a collision scheme. }
    Err := 'a backup with this timestamp already exists: ' + ZipPath;
    Exit;
  end;

  { The config, when there is one. A home with no config.json (a fresh
    install backed up before onboarding) is still backed up. Redacted by
    default; the real file when WithSecrets. }
  Res.WithSecrets := WithSecrets;
  ConfigPath := IncludeTrailingPathDelimiter(Home) + FullConfigName;
  Masked := '';
  if FileExists(ConfigPath) and not WithSecrets then
  begin
    Masked := MaskConfigSecretsJSON(ReadTextFile(ConfigPath));
    if Masked = '' then
    begin
      Err := 'config.json does not parse; refusing to back up a config that cannot be redacted';
      Exit;
    end;
    Res.Redacted := ListRedactedSecrets(Masked);
  end;
  DestAbs := ExpandFileName(ExcludeTrailingPathDelimiter(DestDir));

  Stage := IncludeTrailingPathDelimiter(DestDir) + '.stage-' + IntToStr(GetProcessID);
  Files := TStringList.Create;
  try
    RemoveTreeQuiet(Stage);
    if not ForceDirectories(Stage) then
    begin
      Err := 'cannot create staging directory: ' + Stage;
      Exit;
    end;
    try
      Walk(WsDir, '', Files, DestAbs);
      Res.Files := Files.Count;
      NotesPath := Stage + PathDelim + RestoreNotesName;
      WriteTextFile(NotesPath,
        BuildRestoreNotes(Version, Workspace, Home, When, Files.Count, Res.Redacted, WithSecrets));
      RedactedPath := '';
      if WithSecrets and FileExists(ConfigPath) then
        Result := PackArchive(WsDir, Workspace, ZipPath, Files, NotesPath, ConfigPath, FullConfigName, Err)
      else
      begin
        if Masked <> '' then
        begin
          RedactedPath := Stage + PathDelim + RedactedConfigName;
          WriteTextFile(RedactedPath, Masked);
        end;
        Result := PackArchive(WsDir, Workspace, ZipPath, Files, NotesPath, RedactedPath, RedactedConfigName, Err);
      end;
      if not Result then
      begin
        SysUtils.DeleteFile(ZipPath);
        Exit;
      end;
    finally
      RemoveTreeQuiet(Stage);
    end;
    Res.ZipPath := ZipPath;

    { Rotation, only after a successful write, and only over names this
      unit produced for THIS workspace. }
    Existing := TStringList.Create;
    try
      if FindFirst(IncludeTrailingPathDelimiter(DestDir) + BackupPrefix + Workspace + '-*' + BackupExt,
                   faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Attr and faDirectory) = 0 then Existing.Add(SR.Name);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
      ToPrune := SelectBackupsToPrune(Existing.ToStringArray, KeepDaily, KeepWeekly, KeepMonthly);
      for i := 0 to High(ToPrune) do
        if SysUtils.DeleteFile(IncludeTrailingPathDelimiter(DestDir) + ToPrune[i]) then
        begin
          SetLength(Res.Pruned, Length(Res.Pruned) + 1);
          Res.Pruned[High(Res.Pruned)] := ToPrune[i];
        end;
    finally
      Existing.Free;
    end;
    Result := True;
  finally
    Files.Free;
  end;
end;

{ ----------------------------------------------------------- restore }

function RunRestore(const ZipPath, Home: string; Force: Boolean;
                    out Res: TRestoreResult; out Err: string): Boolean;
var
  Tmp, Src, Dst: string;
  SR: TSearchRec;
  Files: TStringList;
  i: Integer;
begin
  Result := False;
  Err := '';
  Res := Default(TRestoreResult);
  if not FileExists(ZipPath) then
  begin
    Err := 'archive not found: ' + ZipPath;
    Exit;
  end;
  if not ForceDirectories(Home) then
  begin
    Err := 'cannot create home: ' + Home;
    Exit;
  end;
  Tmp := IncludeTrailingPathDelimiter(Home) + '.restore-' + IntToStr(GetProcessID);
  RemoveTreeQuiet(Tmp);
  try
    { ExtractZipToDir validates every member name against the destination
      (no absolute paths, no ..), so a hostile archive fails here. }
    if not ExtractZipToDir(ZipPath, Tmp, Err) then Exit;

    Res.Notes := ReadTextFile(Tmp + PathDelim + RestoreNotesName);
    Res.Redacted := ListRedactedSecrets(ReadTextFile(Tmp + PathDelim + RedactedConfigName));

    { The one directory in the archive is the workspace. }
    if FindFirst(Tmp + PathDelim + '*', faDirectory, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        if (SR.Attr and faDirectory) = 0 then Continue;
        if Res.Workspace <> '' then
        begin
          Err := 'archive holds more than one top-level directory; not a PasClaw backup';
          Exit;
        end;
        Res.Workspace := SR.Name;
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    if Res.Workspace = '' then
    begin
      Err := 'archive holds no workspace directory; not a PasClaw backup';
      Exit;
    end;

    Dst := IncludeTrailingPathDelimiter(Home) + Res.Workspace;
    if DirectoryExists(Dst) and not Force then
    begin
      Err := 'workspace already exists: ' + Dst + ' -- pass --force to overlay it, ' +
             'or restore into an empty PASCLAW_HOME';
      Exit;
    end;

    Src := Tmp + PathDelim + Res.Workspace;
    Files := TStringList.Create;
    try
      Walk(Src, '', Files);
      for i := 0 to Files.Count - 1 do
      begin
        CopyFileRaw(Src + PathDelim + StringReplace(Files[i], '/', PathDelim, [rfReplaceAll]),
                    Dst + PathDelim + StringReplace(Files[i], '/', PathDelim, [rfReplaceAll]));
        Inc(Res.Files);
      end;
    finally
      Files.Free;
    end;
    { The notes and redacted config land beside the workspace so the
      operator can read them after the temp dir is gone. }
    if Res.Notes <> '' then
      WriteTextFile(IncludeTrailingPathDelimiter(Home) + 'RESTORE-' + Res.Workspace + '.md', Res.Notes);
    if FileExists(Tmp + PathDelim + RedactedConfigName) then
      CopyFileRaw(Tmp + PathDelim + RedactedConfigName,
                  IncludeTrailingPathDelimiter(Home) + RedactedConfigName);
    { A --with-secrets archive carries the real config.json: put it in
      place when there is none; with Force, keep the old one as .bak and
      replace it. Never silently overwrite. }
    if FileExists(Tmp + PathDelim + FullConfigName) then
    begin
      Dst := IncludeTrailingPathDelimiter(Home) + FullConfigName;
      if FileExists(Dst) then
      begin
        if Force then
        begin
          Res.ConfigBackedUpTo := Dst + '.bak';
          CopyFileRaw(Dst, Res.ConfigBackedUpTo);
          CopyFileRaw(Tmp + PathDelim + FullConfigName, Dst);
          Res.ConfigWritten := True;
        end;
        { Not Force: the existing config wins; the archive's copy is
          reachable from the zip itself. }
      end
      else
      begin
        CopyFileRaw(Tmp + PathDelim + FullConfigName, Dst);
        Res.ConfigWritten := True;
      end;
    end;
    Result := True;
  finally
    RemoveTreeQuiet(Tmp);
  end;
end;

end.
