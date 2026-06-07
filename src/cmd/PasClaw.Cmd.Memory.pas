(*
  PasClaw.Cmd.Memory - manage the hybrid memory_search runtime.

    pasclaw memory provision    Download sqlite-vec, ONNX Runtime, and
                                the default embedding model into
                                $PASCLAW_HOME/cache/localvector/.
    pasclaw memory status       Show which runtime artifacts are present
                                and where the active backend (hybrid or
                                FTS-only) would pick them up.

  The provision command is idempotent — re-running skips anything
  already on disk, redownloads anything suspiciously small (treated as
  a partial fetch). All artifacts land under $PASCLAW_HOME/cache/localvector/,
  which is exactly where PasClaw.Memory.Vector.Open looks. Once the
  three pieces are present, memory_search picks the hybrid backend
  automatically on the next call — no restart required.

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
  LocalVector.Models,
  LocalVector.OrtProvision,
  LocalVector.VecProvision,
  LocalVector.Downloader;

const
  CACHE_SUBDIR = 'cache/localvector';

procedure Help;
begin
  PrintLn('Usage: pasclaw memory <subcommand>');
  PrintLn;
  PrintLn('Subcommands:');
  PrintLn('  provision   Download sqlite-vec, ONNX Runtime, and the default');
  PrintLn('              embedding model into $PASCLAW_HOME/cache/localvector/');
  PrintLn('  status      Show which runtime artifacts are present and which');
  PrintLn('              backend memory_search would pick on the next call');
end;

function CacheDir: string;
begin
  Result := JoinPath(GetHome, CACHE_SUBDIR);
end;

function ModelDir(const SubDir: string): string;
begin
  Result := JoinPath(JoinPath(CacheDir, 'models'), SubDir);
end;

function VecExtPath: string;
{ Mirrors PasClaw.Memory.Vector.VecExtPath — kept in sync by hand so
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
  Color is Ansi.Green / Ansi.Red / Ansi.Yellow / etc. — the call site
  picks. }
begin
  PrintLn('  ' + Color + Glyph + Ansi.Reset + ' ' + Msg);
end;

function ProvisionVecExt: Boolean;
{ Returns True on success. Always emits a status line — does not throw.
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
    'on demand by PasClaw.Memory.Vector — no restart needed.' + Ansi.Reset);
  PrintLn;

  OkVec   := ProvisionVecExt;
  OkOrt   := ProvisionOnnxRuntime;
  OkModel := ProvisionEmbeddingModel;

  PrintLn;
  if OkVec and OkOrt and OkModel then
  begin
    PrintLn(Ansi.Green + '✓' + Ansi.Reset +
      ' hybrid backend ready — memory_search will use FTS + vector on next call');
    Result := 0;
  end
  else
  begin
    PrintLn(Ansi.Yellow + '!' + Ansi.Reset +
      ' provisioning incomplete — memory_search will fall back to FTS-only');
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

  { ONNX Runtime — same gate TVectorMemoryIndex.Open calls before
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
        'ONNX Runtime not loadable — ' + E.Message);
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
  PrintErr('unknown memory subcommand: ' + Sub + sLineBreak);
  Help;
  Result := 1;
end;

end.
