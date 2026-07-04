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

// Compiler-neutral macOS symbol: FPC uses DARWIN, Delphi uses MACOS/OSX.
// Three separate IFDEF lines (not one IF DEFINED expression) so it stays
// portable across both toolchains' directive dialects.
{$IFDEF DARWIN}{$DEFINE PCLAW_MACOS}{$ENDIF}
{$IFDEF MACOS}{$DEFINE PCLAW_MACOS}{$ENDIF}
{$IFDEF OSX}{$DEFINE PCLAW_MACOS}{$ENDIF}

interface

function Cmd_Memory_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  {$IFDEF FPC}
  fphttpclient, opensslsockets,
  {$ELSE}
  System.Net.HttpClient, System.Net.URLClient,
  {$ENDIF}
  PasClaw.CliUI,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  DateUtils,
  PasClaw.Memory,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory,
  LocalVector.Models,
  LocalVector.OrtProvision,
  LocalVector.VecProvision,
  LocalVector.Downloader,
  PasClaw.Memory.Rerank;

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
  PrintLn('  provision [--rerank] [--rerank-model KEY]');
  PrintLn('              Download sqlite-vec, ONNX Runtime, and the default');
  PrintLn('              embedding model into $PASCLAW_HOME/cache/localvector/.');
  PrintLn('              --rerank also fetches the cross-encoder reranker');
  PrintLn('              (default ms-marco-minilm) for /v1/rerank; --rerank-model');
  PrintLn('              picks one (' + RerankerKeys + ').');
  PrintLn('  status      Show which runtime artifacts are present and which');
  PrintLn('              backend memory_search would pick on the next call');
  PrintLn('  distill [session] [--save]');
  PrintLn('              Extract durable facts from a session transcript via');
  PrintLn('              the LLM (latest session if omitted). --save persists');
  PrintLn('              them to the fact store; otherwise it just previews.');
  PrintLn('  facts [--all]');
  PrintLn('              List stored facts (active only; --all includes');
  PrintLn('              superseded/expired).');
  PrintLn('  add <text> [--kind k] [--scope s] [--event YYYY-MM-DD] [--expires YYYY-MM-DD]');
  PrintLn('              Manually remember a fact (--event = when it happens).');
  PrintLn('  upcoming [--days N]');
  PrintLn('              List active facts with an event date in the next N');
  PrintLn('              days (default 7), soonest first.');
  PrintLn('  forget <id> Delete a fact by id (from `memory facts`).');
  PrintLn('  export [--all] [--out FILE]');
  PrintLn('              Dump facts as Markdown (stdout, or to FILE).');
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

{$IFNDEF MSWINDOWS}
const
  { ONNX Runtime release pinned for the POSIX auto-download. The vendored
    LocalVector.OrtProvision only auto-fetches win-x64; this fills in
    Linux/macOS so `pasclaw memory provision` is one step on every host.
    Pinned to a known-good published release (the C API the bindings load
    is stable across 1.x). }
  ORT_POSIX_VERSION = '1.20.1';

function HttpDownload(const Url, Dest: string): Boolean;
{$IFDEF FPC}
var
  C: TFPHTTPClient;
begin
  Result := False;
  C := TFPHTTPClient.Create(nil);
  try
    C.AllowRedirect := True;
    C.AddHeader('User-Agent', 'pasclaw');
    C.Get(Url, Dest);
    Result := FileExists(Dest);
  finally
    C.Free;
  end;
end;
{$ELSE}
var
  C: THTTPClient;
  FS: TFileStream;
begin
  Result := False;
  C := THTTPClient.Create;
  FS := TFileStream.Create(Dest, fmCreate);
  try
    C.Get(Url, FS);
    Result := FS.Size > 0;
  finally
    FS.Free;
    C.Free;
  end;
end;
{$ENDIF}

function PosixOrtAsset(out Asset, LibGlob, DestName: string): Boolean;
{ Map this platform to its ONNX Runtime release asset + the library file
  to extract. Returns False on a platform with no known asset. }
begin
  Result := True;
  {$IFDEF PCLAW_MACOS}
  Asset    := 'onnxruntime-osx-universal2-' + ORT_POSIX_VERSION + '.tgz';
  LibGlob  := 'libonnxruntime*.dylib';
  DestName := 'onnxruntime.dylib';
  {$else}
    {$IFDEF CPUAARCH64}
    Asset := 'onnxruntime-linux-aarch64-' + ORT_POSIX_VERSION + '.tgz';
    {$ELSE}
    Asset := 'onnxruntime-linux-x64-' + ORT_POSIX_VERSION + '.tgz';
    {$ENDIF}
  LibGlob  := 'libonnxruntime.so.*';
  DestName := 'onnxruntime.so';
  {$ENDIF}
end;

function TryProvisionPosixRuntime: Boolean;
{ Download the platform's ONNX Runtime release, extract the shared lib,
  and drop it as the cache onnxruntime.so / .dylib -- exactly where
  EnsureOnnxRuntime looks. Uses the system `tar` (present on Linux/macOS).
  Best-effort: returns False (with a status line) on any failure. }
var
  Asset, LibGlob, DestName, Url, Tgz, Tmp, Dest: string;
begin
  Result := False;
  if not PosixOrtAsset(Asset, LibGlob, DestName) then Exit;
  ForceDirectories(CacheDir);
  Dest := JoinPath(CacheDir, DestName);
  Url  := 'https://github.com/microsoft/onnxruntime/releases/download/v' +
          ORT_POSIX_VERSION + '/' + Asset;
  Tgz  := JoinPath(CacheDir, Asset);
  Tmp  := JoinPath(CacheDir, 'ort-extract');

  try
    PrintLn('  ' + Ansi.Dim + 'downloading ONNX Runtime ' + ORT_POSIX_VERSION +
            ' (' + Asset + ') ...' + Ansi.Reset);
    if not HttpDownload(Url, Tgz) then
    begin
      PrintCheckMark(Ansi.Red, '✗', 'ONNX Runtime download failed: ' + Url);
      Exit;
    end;
    { Extract + copy the real (non-symlink) shared lib via system tar. }
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + Tmp + '" && mkdir -p "' + Tmp +
      '" && tar -xzf "' + Tgz + '" -C "' + Tmp + '" && cp "$(find "' + Tmp +
      '" -name ''' + LibGlob + ''' -type f | head -1)" "' + Dest + '"']);
    Result := FileExists(Dest);
    if Result then
      PrintCheckMark(Ansi.Green, '✓', 'ONNX Runtime installed at ' + Dest)
    else
      PrintCheckMark(Ansi.Red, '✗',
        'ONNX Runtime extract failed (no ' + LibGlob + ' in archive)');
  except
    on E: Exception do
      PrintCheckMark(Ansi.Red, '✗', 'ONNX Runtime: ' + E.Message);
  end;
  { Tidy the tarball + extract dir; leave only the installed lib. }
  try
    if FileExists(Tgz) then DeleteFile(Tgz);
    ExecuteProcess('/bin/sh', ['-c', 'rm -rf "' + Tmp + '"']);
  except
    on E: Exception do ;
  end;
end;
{$ENDIF}

function ProvisionOnnxRuntime: Boolean;
{ Returns True if the runtime ends up loadable. Win-x64 auto-downloads via
  the vendored EnsureOnnxRuntime; Linux/macOS auto-download here (the
  vendored unit is win-only). Either way EnsureOnnxRuntime is the final
  arbiter of "loadable". }
begin
  Result := False;
  {$IFNDEF MSWINDOWS}
  { POSIX: if the runtime isn't already on the loader path / in the cache,
    fetch + extract the release ourselves. }
  try
    EnsureOnnxRuntime(CacheDir, {AAllowDownload=} False, {AVerbose=} False);
  except
    on E: Exception do TryProvisionPosixRuntime;
  end;
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  { Windows-on-ARM has no wired asset -- the vendored auto-download is
    win-x64 only. POSIX is handled above. }
  if not CanAutoProvisionRuntime then
    PrintLn('  ' + Ansi.Dim + '·' + Ansi.Reset +
      ' ONNX Runtime auto-download is win-x64 only on this build.');
  {$ENDIF}
  try
    EnsureOnnxRuntime(CacheDir,
                      {AAllowDownload=} True,
                      {AVerbose=}        True);
    PrintCheckMark(Ansi.Green, '✓', 'ONNX Runtime is loadable');
    Result := True;
  except
    on E: Exception do
      PrintCheckMark(Ansi.Red, '✗', 'ONNX Runtime: ' + E.Message);
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

function ProvisionRerankerModel(const AKey: string): Boolean;
{ Downloads (if missing) the cross-encoder reranker model.onnx + vocab.txt
  for reranker spec AKey into <cache>/models/<spec.SubDir>/. Same shape as
  ProvisionEmbeddingModel but backed by the reranker registry. Reuses the
  ONNX Runtime already provisioned for the embedder -- no extra runtime. }
var
  Spec: TModelSpec;
  Dir:  string;
  D:    TModelDownloader;
begin
  Result := False;
  if not FindRerankerSpec(AKey, Spec) then
  begin
    PrintCheckMark(Ansi.Red, '✗',
      Format('reranker: unknown model "%s" (known: %s)', [AKey, RerankerKeys]));
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
          Format('reranker model %s (%s) installed at %s',
                 [Spec.DisplayName, Spec.SizeDesc, Dir]));
        Result := True;
      end
      else
        PrintCheckMark(Ansi.Red, '✗',
          'reranker model: download reported success but files missing');
    except
      on E: Exception do
        PrintCheckMark(Ansi.Red, '✗', 'reranker model: ' + E.Message);
    end;
  finally
    D.Free;
  end;
end;

function RunProvision(const Argv: array of string): Integer;
{ Drives the three provisioning steps in order, prints a summary at
  the end, returns 0 if all three succeeded, 1 if any failed (the
  hybrid backend needs all three).

  ForceDirectories on the cache root happens up-front so the provision
  routines (which assume the dir exists) don't trip on the very first
  fresh-install run. }
var
  OkVec, OkOrt, OkModel, OkRerank, WantRerank: Boolean;
  Cache, RerankKey: string;
  Cfg: TConfig;
  i: Integer;
begin
  { --rerank            also fetch the default cross-encoder reranker.
    --rerank-model KEY  fetch a specific reranker (implies --rerank). }
  WantRerank := False;
  RerankKey  := DEFAULT_RERANKER;
  i := 0;
  while i <= High(Argv) do
  begin
    if SameText(Argv[i], '--rerank') then
      WantRerank := True
    else if SameText(Argv[i], '--rerank-model') then
    begin
      WantRerank := True;
      if i < High(Argv) then
      begin
        RerankKey := Argv[i + 1];
        Inc(i);
      end;
    end;
    Inc(i);
  end;

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

  OkRerank := True;
  if WantRerank then
  begin
    PrintLn;
    PrintLn(Ansi.Bold + 'Reranker (cross-encoder)' + Ansi.Reset);
    OkRerank := ProvisionRerankerModel(RerankKey);
    if OkRerank then
    begin
      { Persist which reranker was installed so the /v1/rerank endpoint and
        the retrieval stage load it. Best-effort -- a save failure shouldn't
        fail an otherwise-successful download. }
      try
        Cfg := LoadConfig;
        try
          Cfg.RerankModel := LowerCase(Trim(RerankKey));
          SaveConfig(Cfg);
          PrintLn('  ' + Ansi.Dim + 'rerank_model set to "' +
            Cfg.RerankModel + '" in config.json' + Ansi.Reset);
        finally
          Cfg.Free;
        end;
      except
        on E: Exception do
          PrintLn('  ' + Ansi.Yellow + '·' + Ansi.Reset +
            ' could not persist rerank_model: ' + E.Message);
      end;
      PrintLn('  ' + Ansi.Dim +
        'enable with rerank_search_enabled: true in config.json ' +
        '(or serve /v1/rerank now).' + Ansi.Reset);
    end;
  end;

  PrintLn;
  if OkVec and OkOrt and OkModel and OkRerank then
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
  Spec, RSpec: TModelSpec;
  ModelP, VocabP, RModelP, RerankKey: string;
  Cfg: TConfig;
  Active, RerankState: string;
begin
  Cfg := LoadConfig;
  try
    if Cfg.VectorSearchEnabled then
      Active := 'hybrid (when artifacts present) else FTS-only'
    else
      Active := 'FTS-only (vector_search_enabled is false in config.json)';
    RerankKey := LowerCase(Trim(Cfg.RerankModel));
    if RerankKey = '' then RerankKey := DEFAULT_RERANKER;
    if Cfg.RerankSearchEnabled then
      RerankState := 'on (rerank_search_enabled) -- model ' + RerankKey
    else
      RerankState := 'off (rerank_search_enabled is false) -- model ' + RerankKey;
  finally
    Cfg.Free;
  end;

  PrintLn(Ansi.Bold + 'memory_search backend' + Ansi.Reset);
  PrintLn('  config setting: ' + Active);
  PrintLn('  reranking:      ' + RerankState);
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

  { Reranker (cross-encoder) -- optional second stage. Reported against the
    configured key (rerank_model) so `status` reflects what serve / retrieval
    would actually load; a '·' just means it hasn't been provisioned with
    `memory provision --rerank`. }
  if FindRerankerSpec(RerankKey, RSpec) then
  begin
    RModelP := JoinPath(ModelDir(RSpec.SubDir), 'model.onnx');
    if FileExists(RModelP) then
      PrintCheckMark(Ansi.Green, '✓',
        'reranker ' + RSpec.DisplayName + ' at ' + RModelP)
    else
      PrintCheckMark(Ansi.Yellow, '·',
        'reranker ' + RSpec.DisplayName + ' not provisioned (memory provision --rerank)');
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
  BestTime, FT: TDateTime;
begin
  Result := '';
  Best := '';
  BestTime := 0;
  if FindFirst(JoinPath(MemoryDir, '*.ndjson'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      { Use FileAge's TDateTime overload for "newest" ordering rather than
        SR.Time -- the packed TSearchRec.Time field is deprecated under
        Delphi, and the two-arg FileAge exists on both FPC and Delphi. }
      if not FileAge(JoinPath(MemoryDir, SR.Name), FT) then Continue;
      if (Best = '') or (FT > BestTime) then
      begin
        Best := SR.Name;
        BestTime := FT;
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
  Save: Boolean;
  Store: IFactStore;
  Saved: Integer;
  NowU: Int64;
begin
  Result := 1;
  { Args after 'distill': an optional session id and an optional --save. }
  Save := False;
  SessionId := '';
  for i := 1 to High(Argv) do
  begin
    if (Argv[i] = '--save') or (Argv[i] = '-s') then Save := True
    else if SessionId = '' then SessionId := Argv[i];
  end;
  if SessionId = '' then SessionId := LatestSessionId;
  if SessionId = '' then
  begin
    PrintErr('no session found under ' + MemoryDir + sLineBreak);
    Exit;
  end;

  { Guard before touching NewMemoryLog: it opens the .ndjson with fmCreate,
    so a typo'd session id would CREATE an empty log -- which then becomes
    the newest session and hijacks the default-latest selection on every
    later run. Require the transcript to already exist. }
  if not FileExists(JoinPath(MemoryDir, SessionId + '.ndjson')) then
  begin
    PrintErr('session "' + SessionId + '" not found under ' + MemoryDir + sLineBreak);
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
  if not Save then
    PrintLn(Ansi.Dim + '(preview only -- pass --save to persist)' + Ansi.Reset);
  for i := 0 to High(Facts) do
  begin
    Line := Format('  [%s/%s %.2f] %s',
      [Facts[i].Kind, Facts[i].Scope, Facts[i].Confidence, Facts[i].Text]);
    if Facts[i].Expires <> '' then
      Line := Line + Ansi.Dim + ' (expires ' + Facts[i].Expires + ')' + Ansi.Reset;
    PrintLn(Line);
  end;

  if Save and (Length(Facts) > 0) then
  begin
    Store := NewFactStore;
    if not Store.Open(DefaultFactsDbPath(GetHome)) then
    begin
      PrintErr('distill: could not open fact store' + sLineBreak);
      Exit;
    end;
    try
      NowU := DateTimeToUnix(Now, False);
      Saved := 0;
      for i := 0 to High(Facts) do
        if Store.Add(Facts[i], NowU + i) > 0 then Inc(Saved);
    finally
      Store.Close;
    end;
    PrintLn(Ansi.Green + 'Saved ' + IntToStr(Saved) + ' fact(s) to ' +
            DefaultFactsDbPath(GetHome) + Ansi.Reset);
  end;
  Result := 0;
end;

function RunFacts(const Argv: array of string): Integer;
{ pasclaw memory facts [--all]

  List stored facts. Default shows only ACTIVE facts (not superseded,
  not expired as of today); --all includes superseded/expired. }
var
  Store: IFactStore;
  Facts: TStoredFactArray;
  All: Boolean;
  i: Integer;
  Line, Today: string;
begin
  All := False;
  for i := 1 to High(Argv) do
    if (Argv[i] = '--all') or (Argv[i] = '-a') then All := True;

  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    PrintErr('facts: no fact store at ' + DefaultFactsDbPath(GetHome) + sLineBreak);
    Exit(1);
  end;
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    if All then Facts := Store.AllFacts
    else Facts := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;

  if All then
    PrintLn(Ansi.Bold + IntToStr(Length(Facts)) + ' fact(s) (all)' + Ansi.Reset)
  else
    PrintLn(Ansi.Bold + IntToStr(Length(Facts)) + ' active fact(s)' + Ansi.Reset);
  for i := 0 to High(Facts) do
  begin
    Line := Format('  #%d [%s/%s %.2f] %s',
      [Facts[i].Id, Facts[i].Kind, Facts[i].Scope, Facts[i].Confidence, Facts[i].Text]);
    if Facts[i].EventDate <> '' then
      Line := Line + Ansi.Dim + ' (event ' + Facts[i].EventDate + ')' + Ansi.Reset;
    if Facts[i].Expires <> '' then
      Line := Line + Ansi.Dim + ' (expires ' + Facts[i].Expires + ')' + Ansi.Reset;
    if Facts[i].Superseded then
      Line := Line + Ansi.Dim + ' (superseded)' + Ansi.Reset;
    PrintLn(Line);
  end;
  Result := 0;
end;

function RunUpcoming(const Argv: array of string): Integer;
{ pasclaw memory upcoming [--days N]

  List active facts whose event_date falls within the next N days
  (default 7), soonest first -- the proactive "your exam is tomorrow"
  view. Mirrors what BuildFactsSection injects into the system prompt. }
var
  Store: IFactStore;
  Facts: TStoredFactArray;
  Days, i: Integer;
  Today, Block: string;
begin
  Days := 7;
  for i := 1 to High(Argv) do
    if (Argv[i] = '--days') and (i < High(Argv)) then
      if not TryStrToInt(Argv[i+1], Days) then Days := 7;
  if Days < 0 then Days := 0;

  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    PrintErr('upcoming: no fact store at ' + DefaultFactsDbPath(GetHome) + sLineBreak);
    Exit(1);
  end;
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    Facts := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;

  { Reuse the pure formatter so the CLI and the prompt agree exactly. The
    CLI is interactive output, not the token-bounded prompt, so the budget
    is effectively unbounded (MaxInt) -- show every upcoming fact. }
  Block := FormatUpcomingBlock(Facts, Today, Days, MaxInt);
  if Block = '' then
  begin
    PrintLn(Ansi.Dim + 'Nothing upcoming in the next ' + IntToStr(Days) +
            ' day(s).' + Ansi.Reset);
    Exit(0);
  end;
  PrintLn(Block);
  Result := 0;
end;

function RunAdd(const Argv: array of string): Integer;
{ pasclaw memory add <text...> [--kind static|dynamic] [--scope user|project|session]
                               [--event YYYY-MM-DD] [--expires YYYY-MM-DD]
  Manually remember a fact. Goes through the same store (and dedup) as the
  auto-distiller; source is tagged "manual". --event records WHEN the
  thing happens (for proactive surfacing); --expires when the fact stops
  mattering. }
var
  F: TFact;
  Store: IFactStore;
  Cfg: TConfig;
  i: Integer;
  Id: Int64;
  TextParts: string;
  DistillOn: Boolean;
begin
  F.Text := ''; F.Kind := 'static'; F.Scope := 'user';
  F.Confidence := 1.0; F.EventDate := ''; F.Expires := ''; F.SourceSession := 'manual';
  TextParts := '';
  i := 1;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '--kind')    and (i < High(Argv)) then begin F.Kind := Argv[i+1];    Inc(i,2); Continue; end;
    if (Argv[i] = '--scope')   and (i < High(Argv)) then begin F.Scope := Argv[i+1];   Inc(i,2); Continue; end;
    if (Argv[i] = '--event')   and (i < High(Argv)) then begin F.EventDate := Argv[i+1]; Inc(i,2); Continue; end;
    if (Argv[i] = '--expires') and (i < High(Argv)) then begin F.Expires := Argv[i+1]; Inc(i,2); Continue; end;
    if TextParts <> '' then TextParts := TextParts + ' ';
    TextParts := TextParts + Argv[i];
    Inc(i);
  end;
  F.Text := Trim(TextParts);
  if F.Text = '' then
  begin
    PrintErr('add: fact text required, e.g. pasclaw memory add "prefers Delphi"' + sLineBreak);
    Exit(1);
  end;
  NormaliseFact(F);   { normalise kind/scope/confidence/expires like the distiller }

  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    PrintErr('add: cannot open fact store at ' + DefaultFactsDbPath(GetHome) + sLineBreak);
    Exit(1);
  end;
  try
    Id := Store.Add(F, DateTimeToUnix(Now, False));
  finally
    Store.Close;
  end;
  PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' remembered #' + IntToStr(Id) +
          ' [' + F.Kind + '/' + F.Scope + ']: ' + F.Text);

  { Gentle nudge: a manual fact only reaches the model when the feature is on. }
  Cfg := LoadConfig;
  try DistillOn := Cfg.MemoryDistillEnabled; finally Cfg.Free; end;
  if not DistillOn then
    PrintLn('  ' + Ansi.Dim +
      '(note: memory_distill_enabled is off -- enable it for this fact to be ' +
      'injected / searched)' + Ansi.Reset);
  Result := 0;
end;

function RunForget(const Argv: array of string): Integer;
{ pasclaw memory forget <id>   (id from `pasclaw memory facts`) }
var
  Store: IFactStore;
  Id: Int64;
  Ok: Boolean;
begin
  if (Length(Argv) < 2) or (not TryStrToInt64(Argv[1], Id)) then
  begin
    PrintErr('forget: a numeric fact id is required ' +
             '(see `pasclaw memory facts`)' + sLineBreak);
    Exit(1);
  end;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    PrintErr('forget: cannot open fact store' + sLineBreak);
    Exit(1);
  end;
  try
    Ok := Store.Delete(Id);
  finally
    Store.Close;
  end;
  if Ok then
  begin
    PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' forgot #' + IntToStr(Id));
    Result := 0;
  end
  else
  begin
    PrintErr('forget: no fact #' + IntToStr(Id) + sLineBreak);
    Result := 1;
  end;
end;

function RunExport(const Argv: array of string): Integer;
{ pasclaw memory export [--all] [--out FILE]
  Dump the fact store as human-readable / git-friendly Markdown (the
  auditability escape hatch for the SQLite store). }
var
  Store: IFactStore;
  Facts: TStoredFactArray;
  SL: TStringList;
  All: Boolean;
  OutFile, Today: string;
  i: Integer;

  procedure EmitScope(const Scope: string);
  var
    j: Integer;
    Any: Boolean;
    Line: string;
  begin
    Any := False;
    for j := 0 to High(Facts) do
    begin
      if Facts[j].Scope <> Scope then Continue;
      if not Any then begin SL.Add('## ' + Scope); SL.Add(''); Any := True; end;
      Line := Format('- %s  _(%s, conf %.2f)_',
        [Facts[j].Text, Facts[j].Kind, Facts[j].Confidence]);
      if Facts[j].Expires <> '' then Line := Line + ' _(until ' + Facts[j].Expires + ')_';
      if Facts[j].Superseded then Line := Line + ' _(superseded)_';
      SL.Add(Line);
    end;
    if Any then SL.Add('');
  end;

begin
  All := False; OutFile := '';
  i := 1;
  while i <= High(Argv) do
  begin
    if Argv[i] = '--all' then begin All := True; Inc(i); Continue; end;
    if (Argv[i] = '--out') and (i < High(Argv)) then begin OutFile := Argv[i+1]; Inc(i,2); Continue; end;
    Inc(i);
  end;

  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    PrintErr('export: no fact store at ' + DefaultFactsDbPath(GetHome) + sLineBreak);
    Exit(1);
  end;
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    if All then Facts := Store.AllFacts else Facts := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;

  SL := TStringList.Create;
  try
    SL.Add('# PasClaw distilled memory');
    SL.Add('');
    SL.Add(Format('_%d fact(s), exported %s._', [Length(Facts), Today]));
    SL.Add('');
    EmitScope('user');
    EmitScope('project');
    EmitScope('session');
    if OutFile <> '' then
    begin
      { WriteFileText is the codebase's UTF-8 writer (same path memory/
        checkpoints use) -- guarantees UTF-8 on BOTH compilers, unlike
        TStringList.SaveToFile whose default encoding is the system code
        page on Delphi and would mojibake accents / CJK / emoji. }
      WriteFileText(OutFile, SL.Text);
      PrintLn(Ansi.Green + '✓' + Ansi.Reset + ' exported ' + IntToStr(Length(Facts)) +
              ' fact(s) to ' + OutFile);
    end
    else
      Write(SL.Text);
  finally
    SL.Free;
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
  if Sub = 'provision' then Exit(RunProvision(Argv));
  if Sub = 'status'    then Exit(RunStatus);
  if Sub = 'distill'   then Exit(RunDistill(Argv));
  if Sub = 'facts'     then Exit(RunFacts(Argv));
  if Sub = 'upcoming'  then Exit(RunUpcoming(Argv));
  if Sub = 'add'       then Exit(RunAdd(Argv));
  if Sub = 'forget'    then Exit(RunForget(Argv));
  if Sub = 'export'    then Exit(RunExport(Argv));
  PrintErr('unknown memory subcommand: ' + Sub + sLineBreak);
  Help;
  Result := 1;
end;

end.
