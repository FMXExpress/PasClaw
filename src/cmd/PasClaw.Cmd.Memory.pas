(*
  PasClaw.Cmd.Memory - manage the hybrid memory_search runtime.

    pasclaw memory provision    Download sqlite-vec, ONNX Runtime, and
                                the default embedding model into
                                $PASCLAW_HOME/cache/localvector/.
    pasclaw memory status       Show which runtime artifacts are present
                                and where the active backend (hybrid or
                                FTS-only) would pick them up.

  The provision command is idempotent -- re-running skips anything
  already on disk, redownloads anything suspiciously small (treated as
  a partial fetch). All artifacts land under $PASCLAW_HOME/cache/localvector/,
  which is exactly where PasClaw.Memory.Vector.Open looks. Once the
  three pieces are present, memory_search picks the hybrid backend
  automatically on the next call -- no restart required.

  Cross-platform footprint:
    sqlite-vec extension       auto-downloaded from asg017/sqlite-vec
                               releases on win-x64 / linux-x86_64 /
                               linux-aarch64 / macos-x86_64 /
                               macos-aarch64.
    ONNX Runtime               auto-downloaded only on win-x64 (per
                               LocalVector.OrtProvision.CanAutoProvisionRuntime);
                               other platforms print install
                               instructions for the system package
                               manager.
    Embedding model + vocab    auto-downloaded from HuggingFace for any
                               platform (no architecture-specific
                               weights).
*)
unit PasClaw.Cmd.Memory;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

function Cmd_Memory_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Memory,
  PasClaw.Memory.Distill,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  LocalVector.Models,
  LocalVector.OrtProvision,
  LocalVector.VecProvision,
  LocalVector.Downloader;

{ Cache directory under PASCLAW_HOME. Built up via nested JoinPath
  calls -- NOT as a single `'cache/localvector'` const -- because on
  Windows JoinPath only inserts a PathDelim BETWEEN the two args; an
  embedded `/` inside one of them survives, producing mixed-separator
  paths like `C:\Users\anony\.pasclaw\cache/localvector`. ForceDirectories
  and the downstream CreateFile calls in the localvector downloaders
  then disagree about where the directory actually lives, and the
  whole provisioning step fails with "system cannot find the path
  specified" on every artifact (Codex / user report on PR #168). }
function CacheDir: string;
begin
  Result := JoinPath(JoinPath(GetHome, 'cache'), 'localvector');
end;

procedure Help;
begin
  PrintLn('Usage: pasclaw memory <subcommand>');
  PrintLn;
  PrintLn('Subcommands:');
  PrintLn('  provision   Download sqlite-vec, ONNX Runtime, and the default');
  PrintLn('              embedding model into $PASCLAW_HOME/cache/localvector/');
  PrintLn('  status      Show which runtime artifacts are present and which');
  PrintLn('              backend memory_search would pick on the next call');
  PrintLn('  distill [session]');
  PrintLn('              Extract durable facts from a session transcript via');
  PrintLn('              the LLM and print them (latest session if omitted).');
end;

function ModelDir(const SubDir: string): string;
begin
  Result := JoinPath(JoinPath(CacheDir, 'models'), SubDir);
end;

function VecExtPath: string;
{ Mirrors PasClaw.Memory.Vector.VecExtPath -- kept in sync by hand so
  this unit doesn't have to import the IMemoryIndex type just for one
  string. If you change either, change both. }
begin
  {$IFDEF MSWINDOWS}
  Result := JoinPath(CacheDir, 'vec0.dll');
  {$ELSE}
    {$IFDEF DARWIN}
    Result := JoinPath(CacheDir, 'vec0.dylib');
    {$ELSE}
    Result := JoinPath(CacheDir, 'vec0.so');
    {$ENDIF}
  {$ENDIF}
end;

procedure PrintCheckMark(const Color: string; const Glyph, Msg: string);
{ Compose a single status line: '  ' + colored glyph + ' ' + Msg.
  Color is Ansi.Green / Ansi.Red / Ansi.Yellow / etc. -- the call site
  picks. }
begin
  PrintLn('  ' + Color + Glyph + Ansi.Reset + ' ' + Msg);
end;

function ProvisionVecExt: Boolean;
{ Returns True on success. Always emits a status line -- does not throw.
  Idempotent: EnsureVec0 short-circuits on FileExists(Dest). }
var
  Dest: string;
begin
  Result := False;
  if FileExists(VecExtPath) then
  begin
    PrintCheckMark(Ansi.Green, '✓',
      'sqlite-vec extension already present at ' + VecExtPath);
    Exit(True);
  end;
  try
    Dest := EnsureVec0(CacheDir,
                       {AAllowDownload=} True,
                       {AVerbose=}        True);
    if FileExists(Dest) then
    begin
      PrintCheckMark(Ansi.Green, '✓',
        'sqlite-vec extension installed at ' + Dest);
      Result := True;
    end
    else
      PrintCheckMark(Ansi.Red, '✗',
        'sqlite-vec install reported success but file is missing');
  except
    on E: Exception do
      PrintCheckMark(Ansi.Red, '✗', 'sqlite-vec: ' + E.Message);
  end;
end;

function ProvisionOnnxRuntime: Boolean;
{ Returns True if the runtime ends up loadable (auto-downloaded on
  win-x64 OR resolvable through the system loader on Linux/macOS).
  EnsureOnnxRuntime is the single entry; CanAutoProvisionRuntime tells
  us whether auto-download is even an option on this platform. }
begin
  Result := False;
  if not CanAutoProvisionRuntime then
  begin
    PrintLn('  ' + Ansi.Dim + '·' + Ansi.Reset +
      ' ONNX Runtime auto-download is win-x64 only on this build;');
    PrintLn('    install via your system package manager:');
    PrintLn('      Debian / Ubuntu:  apt install libonnxruntime-dev');
    PrintLn('      macOS (Homebrew): brew install onnxruntime');
    PrintLn('      Other Linux:      see https://onnxruntime.ai/docs/install/');
  end;
  try
    EnsureOnnxRuntime(CacheDir,
                      {AAllowDownload=} True,
                      {AVerbose=}        True);
    PrintCheckMark(Ansi.Green, '✓', 'ONNX Runtime is loadable');
    Result := True;
  except
    on E: Exception do
    begin
      PrintCheckMark(Ansi.Red, '✗', 'ONNX Runtime: ' + E.Message);
      if not CanAutoProvisionRuntime then
        PrintLn('    (install per the instructions above, then re-run ' +
                '`pasclaw memory provision`)');
    end;
  end;
end;

function ProvisionEmbeddingModel: Boolean;
{ Downloads (if missing) the model.onnx + vocab.txt for the DEFAULT_MODEL
  spec into <cache>/models/<spec.SubDir>/. Returns True on success. The
  TModelDownloader does its own progress logging to ErrOutput. }
var
  Spec: TModelSpec;
  Dir:  string;
  D:    TModelDownloader;
begin
  Result := False;
  if not FindModelSpec(DEFAULT_MODEL, Spec) then
  begin
    PrintCheckMark(Ansi.Red, '✗',
      Format('embedding model: DEFAULT_MODEL "%s" not registered',
             [DEFAULT_MODEL]));
    Exit;
  end;

  Dir := ModelDir(Spec.SubDir);
  ForceDirectories(Dir);

  D := TModelDownloader.Create(Spec, Dir, {AVerbose=} True);
  try
    try
      D.EnsureFiles;
      if FileExists(D.ModelPath) and FileExists(D.VocabPath) then
      begin
        PrintCheckMark(Ansi.Green, '✓',
          Format('embedding model %s (%s) installed at %s',
                 [Spec.DisplayName, Spec.SizeDesc, Dir]));
        Result := True;
      end
      else
        PrintCheckMark(Ansi.Red, '✗',
          'embedding model: download reported success but files missing');
    except
      on E: Exception do
        PrintCheckMark(Ansi.Red, '✗', 'embedding model: ' + E.Message);
    end;
  finally
    D.Free;
  end;
end;

function RunProvision: Integer;
{ Drives the three provisioning steps in order, prints a summary at
  the end, returns 0 if all three succeeded, 1 if any failed (the
  hybrid backend needs all three).

  ForceDirectories on the cache root happens up-front so the provision
  routines (which assume the dir exists) don't trip on the very first
  fresh-install run. }
var
  OkVec, OkOrt, OkModel: Boolean;
  Cache: string;
begin
  Cache := CacheDir;
  ForceDirectories(Cache);

  PrintLn(Ansi.Bold + 'Provisioning hybrid memory_search runtime' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'All artifacts land under ' + Cache + ' and are loaded' + Ansi.Reset);
  PrintLn(Ansi.Dim +
    'on demand by PasClaw.Memory.Vector -- no restart needed.' + Ansi.Reset);
  PrintLn;

  OkVec   := ProvisionVecExt;
  OkOrt   := ProvisionOnnxRuntime;
  OkModel := ProvisionEmbeddingModel;

  PrintLn;
  if OkVec and OkOrt and OkModel then
  begin
    PrintLn(Ansi.Green + '✓' + Ansi.Reset +
      ' hybrid backend ready -- memory_search will use FTS + vector on next call');
    Result := 0;
  end
  else
  begin
    PrintLn(Ansi.Yellow + '!' + Ansi.Reset +
      ' provisioning incomplete -- memory_search will fall back to FTS-only');
    PrintLn('  Re-run after fixing the failures above.');
    Result := 1;
  end;
end;

function RunStatus: Integer;
{ Read-only mirror of what PasClaw.Memory.Vector.Open checks. Useful
  for diagnostics and as the "did the provision actually work" answer
  separate from running memory_search. }
var
  Spec: TModelSpec;
  ModelP, VocabP: string;
  Cfg: TConfig;
  Active: string;
begin
  Cfg := LoadConfig;
  try
    if Cfg.VectorSearchEnabled then
      Active := 'hybrid (when artifacts present) else FTS-only'
    else
      Active := 'FTS-only (vector_search_enabled is false in config.json)';
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Bold + 'memory_search backend' + Ansi.Reset);
  PrintLn('  config setting: ' + Active);
  PrintLn('  cache dir:      ' + CacheDir);
  PrintLn;
  PrintLn(Ansi.Bold + 'Runtime artifacts' + Ansi.Reset);

  if FileExists(VecExtPath) then
    PrintCheckMark(Ansi.Green, '✓', 'sqlite-vec at ' + VecExtPath)
  else
    PrintCheckMark(Ansi.Yellow, '·', 'sqlite-vec missing at ' + VecExtPath);

  if FindModelSpec(DEFAULT_MODEL, Spec) then
  begin
    ModelP := JoinPath(ModelDir(Spec.SubDir), 'model.onnx');
    VocabP := JoinPath(ModelDir(Spec.SubDir), 'vocab.txt');
    if FileExists(ModelP) then
      PrintCheckMark(Ansi.Green, '✓',
        Spec.DisplayName + ' model at ' + ModelP)
    else
      PrintCheckMark(Ansi.Yellow, '·',
        Spec.DisplayName + ' model missing at ' + ModelP);
    if FileExists(VocabP) then
      PrintCheckMark(Ansi.Green, '✓', 'vocab at ' + VocabP)
    else
      PrintCheckMark(Ansi.Yellow, '·', 'vocab missing at ' + VocabP);
  end;

  { ONNX Runtime -- same gate TVectorMemoryIndex.Open calls before
    enabling the hybrid backend. Codex P2 on PR #166: on Linux/macOS a
    host with vec0 + model + vocab on disk but no system libonnxruntime
    will see every file-based check go green here even though
    memory_search keeps falling back to FTS, because Open() bails on
    EnsureOnnxRuntime first. Run the same check (AllowDownload=False
    so this stays read-only) and surface the result so the status
    output mirrors what the backend gate actually decides. }
  try
    EnsureOnnxRuntime(CacheDir,
                      {AAllowDownload=} False,
                      {AVerbose=}        False);
    PrintCheckMark(Ansi.Green, '✓', 'ONNX Runtime is loadable');
  except
    on E: Exception do
    begin
      PrintCheckMark(Ansi.Yellow, '·',
        'ONNX Runtime not loadable -- ' + E.Message);
      if not CanAutoProvisionRuntime then
      begin
        PrintLn('    ' + Ansi.Dim +
          'auto-download is win-x64 only on this build; install via:' +
          Ansi.Reset);
        PrintLn('    ' + Ansi.Dim +
          '  Debian / Ubuntu:  apt install libonnxruntime-dev' +
          Ansi.Reset);
        PrintLn('    ' + Ansi.Dim +
          '  macOS (Homebrew): brew install onnxruntime' +
          Ansi.Reset);
        PrintLn('    ' + Ansi.Dim +
          '  Other Linux:      see https://onnxruntime.ai/docs/install/' +
          Ansi.Reset);
      end;
    end;
  end;

  PrintLn;
  PrintLn(Ansi.Dim +
    'Run `pasclaw memory provision` to download missing artifacts.' + Ansi.Reset);
  Result := 0;
end;

function MemoryDir: string;
begin
  Result := JoinPath(JoinPath(GetHome, 'workspace'), 'memory');
end;

function LatestSessionId: string;
{ Newest *.ndjson under workspace/memory (by mtime), or '' if none. }
var
  SR: TSearchRec;
  Best: string;
  BestTime: LongInt;
begin
  Result := '';
  Best := '';
  BestTime := -1;
  if FindFirst(JoinPath(MemoryDir, '*.ndjson'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      { SR.Time is a packed file timestamp -- fine for "newest" ordering
        and available under both FPC and Delphi (unlike .TimeStamp). }
      if (Best = '') or (SR.Time > BestTime) then
      begin
        Best := SR.Name;
        BestTime := SR.Time;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if Best <> '' then
    Result := ChangeFileExt(Best, '');   { strip .ndjson -> session id }
end;

function RunDistill(const Argv: array of string): Integer;
{ pasclaw memory distill [sessionId]

  Phase 1: read a session's transcript, run the LLM distiller, and PRINT
  the extracted facts. Persistence (SQLite fact store) lands in Phase 2,
  so this is a read-only preview of what the distiller would remember. }
var
  Cfg: TConfig;
  Provider: ILLMProvider;
  Err, SessionId, Today: string;
  Log: TMemoryLog;
  Hist: TMessageArray;
  Distiller: TMemoryDistiller;
  Facts: TFactArray;
  i: Integer;
  Line: string;
begin
  Result := 1;
  if Length(Argv) >= 2 then
    SessionId := Argv[1]
  else
    SessionId := LatestSessionId;
  if SessionId = '' then
  begin
    PrintErr('no session found under ' + MemoryDir + sLineBreak);
    Exit;
  end;

  Cfg := LoadConfig;
  try
    if not NewDefaultProvider(Cfg, Provider, Err) then
    begin
      PrintErr('distill: ' + Err + sLineBreak);
      Exit;
    end;

    Log := NewMemoryLog(GetHome, SessionId);
    try
      Hist := Log.LoadHistory;
    finally
      Log.Free;
    end;
    if Length(Hist) = 0 then
    begin
      PrintErr('session "' + SessionId + '" has no transcript' + sLineBreak);
      Exit;
    end;

    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    Distiller := TMemoryDistiller.Create(Provider, Cfg.DefaultModel);
    try
      if not Distiller.Distill(Hist, SessionId, Today, Facts, Err) then
      begin
        PrintErr('distill: ' + Err + sLineBreak);
        Exit;
      end;
    finally
      Distiller.Free;
    end;
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Bold + 'Distilled ' + IntToStr(Length(Facts)) +
          ' fact(s) from session ' + SessionId + Ansi.Reset);
  PrintLn(Ansi.Dim + '(preview only -- persistence lands in Phase 2)' + Ansi.Reset);
  for i := 0 to High(Facts) do
  begin
    Line := Format('  [%s/%s %.2f] %s',
      [Facts[i].Kind, Facts[i].Scope, Facts[i].Confidence, Facts[i].Text]);
    if Facts[i].Expires <> '' then
      Line := Line + Ansi.Dim + ' (expires ' + Facts[i].Expires + ')' + Ansi.Reset;
    PrintLn(Line);
  end;
  Result := 0;
end;

function Cmd_Memory_Run(const Argv: array of string): Integer;
var
  Sub: string;
begin
  if Length(Argv) = 0 then
  begin
    Help;
    Exit(1);
  end;
  Sub := LowerCase(Argv[0]);
  if (Sub = '-h') or (Sub = '--help') or (Sub = 'help') then
  begin
    Help;
    Exit(0);
  end;
  if Sub = 'provision' then Exit(RunProvision);
  if Sub = 'status'    then Exit(RunStatus);
  if Sub = 'distill'   then Exit(RunDistill(Argv));
  PrintErr('unknown memory subcommand: ' + Sub + sLineBreak);
  Help;
  Result := 1;
end;

end.
