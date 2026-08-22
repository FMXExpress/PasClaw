(*
  memory_search_roundtrip_tests - end-to-end happy path for the
  memory_search tool, through the real tool registry.

  Why this exists: adding LastError to IMemoryIndex touched the
  interface that TMemoryIndexImpl and TVectorMemoryIndex both
  implement, and Tool_MemorySearch was rewritten around the failure
  branch. sqlite_hint_tests covers the two pure helpers and the
  manual repro covered the failure path, but nothing asserted that
  a SUCCESSFUL search still returns hits. A regression there would
  have been invisible: memory_search would just report "no matches"
  and the agent would carry on without its notes.

  What this covers: write markdown notes -> memory_search finds them
  by keyword, returns the path and a bm25 score, and reports a clean
  miss for a term that is absent. Also that LastError stays empty on
  a successful open, so no spurious reason leaks into a good result.

  Also covers the kb_search FAILURE branch. Two sites in
  PasClaw.Tools.KB shipped reporting the generic backend hint
  because they released the index before reading LastError (Codex P2
  on PR #582). The Makefile lint catches the bare-hint spelling; this
  asserts the behaviour end to end, through the registry, so a future
  rewrite that keeps the right function name but restores the wrong
  ORDER still fails here.

  What it does NOT cover: the vector backend (needs provisioned ONNX
  runtime + model, absent in CI -- Open() declines and we fall
  through to FTS, which is what this exercises), the gateway's
  /v1/memory/search wrapper, and distilled facts.
*)
program memory_search_roundtrip_tests;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workspaces,
  PasClaw.Memory.Index,
  PasClaw.Tools.Types,
  PasClaw.KB.Index,
  PasClaw.Tools.Registry,
  PasClaw.Tools.KB,
  PasClaw.Tools.Memory;

var
  Failures: Integer = 0;
  Home: string;

procedure Check(const Name: string; Cond: Boolean);
begin
  if Cond then
    WriteLn('  ok   ', Name)
  else
  begin
    WriteLn('  FAIL ', Name);
    Inc(Failures);
  end;
end;

procedure WriteFile_(const Path, Text: string);
var
  L: TStringList;
begin
  ForceDirectories(ExtractFileDir(Path));
  L := TStringList.Create;
  try
    L.Text := Text;
    L.SaveToFile(Path);
  finally
    L.Free;
  end;
end;

procedure SetUp;
var
  MemDir: string;
begin
  { The Makefile target points $PASCLAW_HOME at a fresh mktemp -d, the
    same way the other home-dependent suites are driven, so GetHome
    lands somewhere disposable and never touches a real profile.
    Guard rather than assume -- running this binary by hand without
    the env var would otherwise write notes into the user's actual
    memory directory. }
  Home := GetHome;
  if (GetEnvironmentVariable('PASCLAW_HOME') = '') or (Home = '') then
  begin
    WriteLn('  FAIL refusing to run without $PASCLAW_HOME ' +
            '(use: make test-memory-search-roundtrip)');
    Halt(1);
  end;
  ForceDirectories(Home);

  MemDir := JoinPath(Home, ActiveWorkspaceName + '/memory');
  WriteFile_(JoinPath(MemDir, 'MEMORY.md'),
    '# Durable notes'#10#10 +
    'The deployment target is a Raspberry Pi running Alpine.'#10 +
    'Postgres credentials rotate every ninety days.'#10);
  WriteFile_(JoinPath(MemDir, '2026-08-21.md'),
    '- Discussed the zpaq checkpoint format with the team.'#10 +
    '- Alpine images need musl-compatible binaries.'#10);
end;

procedure TearDown;
begin
  { The Makefile owns the temp home; nothing to unwind here. }
end;

var
  R: TToolRegistry;
  T: TTool;

procedure TestFindsAKnownTerm;
var
  Err, Out_: string;
begin
  Out_ := R.RunTool('memory_search', '{"query":"Alpine"}', Err);
  WriteLn('  --- output ---');
  WriteLn(Out_);
  WriteLn('  --------------');
  Check('no error', Err = '');
  Check('found at least one match', Pos('match(es)', Out_) > 0);
  Check('reports a source path', Pos('.md', Out_) > 0);
  Check('reports a bm25 score', Pos('bm25=', Out_) > 0);
  { Both files mention Alpine, so both should surface. }
  Check('MEMORY.md hit',   Pos('MEMORY.md', Out_) > 0);
  Check('daily note hit',  Pos('2026-08-21', Out_) > 0);
end;

procedure TestFindsATermInOneFileOnly;
var
  Err, Out_: string;
begin
  Out_ := R.RunTool('memory_search', '{"query":"Postgres"}', Err);
  Check('no error (single-file term)', Err = '');
  Check('MEMORY.md matched', Pos('MEMORY.md', Out_) > 0);
  Check('daily note not matched', Pos('2026-08-21', Out_) = 0);
end;

procedure TestCleanMissOnAbsentTerm;
var
  Err, Out_: string;
begin
  Out_ := R.RunTool('memory_search', '{"query":"kubernetes"}', Err);
  Check('absent term is not an error', Err = '');
  Check('absent term reports no matches', Pos('no matches', Out_) > 0);
  { The whole point of the change: a miss must not be dressed up as
    an unavailable index, and an available index must not report a
    failure reason. }
  Check('miss is not reported as unavailable',
        Pos('unavailable', Out_) = 0);
  Check('miss mentions no sqlite library',
        (Pos('libsqlite3', Out_) = 0) and (Pos('sqlite3.dll', Out_) = 0));
end;

procedure TestLastErrorEmptyOnSuccess;
var
  Idx: IMemoryIndex;
  DbPath: string;
begin
  DbPath := JoinPath(JoinPath(Home, ActiveWorkspaceName + '/memory'),
                     '.index.db');
  Idx := NewMemoryIndex;
  Check('index opens', Idx.Open(DbPath));
  Check('LastError empty after a good open', Idx.LastError = '');
  Idx := nil;
end;

procedure TestKbSearchReportsTheDriverReason;
(* Regression test for the two PasClaw.Tools.KB sites that read
   LastError AFTER releasing Idx, and so reported the generic backend
   hint instead of the driver's reason (Codex P2 on PR #582).

   Reaching that branch takes a specific, real sequence: kb_search
   only registers when a valid kb.db with at least one source exists
   at boot, so the tool must be registered while the KB is healthy and
   the DB must break afterwards -- deleted, chmod'd, or corrupted
   mid-session. Anything less never reaches the branch, which is why
   the first draft of this test passed on "unknown tool: kb_search"
   instead of on the behaviour. Build the KB, register, then corrupt. *)
var
  Err, Out_, KbDb, SrcDir: string;
  Idx: IKBIndex;
  Files, Chunks: Integer;
  F: TFileStream;
  Junk: AnsiString;
  R2: TToolRegistry;
begin
  KbDb   := JoinPath(JoinPath(Home, ActiveWorkspaceName), 'kb.db');
  SrcDir := JoinPath(Home, 'kbsource');
  WriteFile_(JoinPath(SrcDir, 'manual.md'),
    '# Manual'#10#10'The widget calibration tolerance is 0.5mm.'#10);

  Idx := NewKBIndex;
  Check('kb index opens for setup', Idx.Open(KbDb));
  Check('kb source added', Idx.AddSource(SrcDir, Err));
  Idx.Sync(Files, Chunks);
  Check('kb indexed at least one file', Files >= 1);
  Idx := nil;

  { Register against the HEALTHY kb, the way a real boot would. }
  R2 := TToolRegistry.Create;
  try
    RegisterKBTools(R2);
    Check('kb_search registered while healthy', R2.Find('kb_search', T));

    { Now break it underneath the registered tool. }
    F := TFileStream.Create(KbDb, fmCreate);
    try
      Junk := 'not a database at all, just bytes';
      F.WriteBuffer(Junk[1], Length(Junk));
    finally
      F.Free;
    end;

    Out_ := R2.RunTool('kb_search', '{"query":"calibration"}', Err);
    WriteLn('  kb_search err = ', Err);
    Check('kb_search reports a failure', Err <> '');
    Check('kb_search quotes the driver reason',
          Pos('not a database', LowerCase(Err)) > 0);
    Check('kb_search does not blame a missing library',
          (Pos('libsqlite3', Err) = 0) and (Pos('sqlite3.dll', Err) = 0));
    Check('kb_search returned no body', Out_ = '');
  finally
    R2.Free;
  end;
end;

begin
  WriteLn('memory_search_roundtrip_tests');
  SetUp;
  R := TToolRegistry.Create;
  try
    RegisterMemoryTools(R);
    Check('memory_search is registered', R.Find('memory_search', T));
    TestFindsAKnownTerm;
    TestFindsATermInOneFileOnly;
    TestCleanMissOnAbsentTerm;
    TestLastErrorEmptyOnSuccess;
    TestKbSearchReportsTheDriverReason;
  finally
    R.Free;
    TearDown;
  end;

  if Failures = 0 then
  begin
    WriteLn('OK');
    Halt(0);
  end
  else
  begin
    WriteLn(Failures, ' failure(s)');
    Halt(1);
  end;
end.
