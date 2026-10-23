program worktree_tests;
(*
  PasClaw.Tools.Worktree and the per-thread sandbox workspace.

  Against a temp git repository:
    - BranchDirName / WorktreeBaseDir are pure and predictable
    - create / list / remove round trip; create is idempotent
    - remove refuses a dirty worktree without force, removes with it
    - the worktree_* tool handlers run through the registry
    - SetThreadSandboxWorkspace is per thread: a worker sees its
      override, the main thread does not
    - TToolLoopConfig.Workspace is bracketed around a dispatch: the
      handler sees it as CurrentWorkspace, the caller's thread is back
      to the parent workspace afterwards
    - spawn(worktree:"<branch>") runs the child in the worktree: an
      fs_write with a relative path lands there, not in the parent tree,
      and the result names the worktree
    - worktree.enabled:false is honoured by spawn and spawn_background
      too (no schema property, the argument refused) -- not only by the
      worktree_* tools (Codex P2 on #612)
    - a spawn that is refused -- at the background-job cap, an unknown
      agent, no prompt -- creates no branch and no worktree first (Codex
      P2 on #612)
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils, Classes, Process,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS,
  PasClaw.Tools.ToolLoop,
  PasClaw.Agent.Subagent,
  PasClaw.Agent.SubagentBg,
  PasClaw.Tools.Worktree;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '" in: ' + Copy(Hay, 1, 300)); end;

function Sh(const Dir, Cmd: string): string;
var
  P: TProcess;
  Buf: array[0..4095] of Byte;
  N: Integer;
begin
  Result := '';
  P := TProcess.Create(nil);
  try
    P.Executable := '/bin/sh';
    P.Parameters.Add('-c');
    P.Parameters.Add(Cmd);
    P.CurrentDirectory := Dir;
    P.Options := [poUsePipes, poStderrToOutPut];
    P.Execute;
    repeat
      N := P.Output.Read(Buf, SizeOf(Buf));
      if N > 0 then Result := Result + Copy(PAnsiChar(@Buf[0]), 1, N);
    until N <= 0;
    P.WaitOnExit;
  finally
    P.Free;
  end;
end;

var
  Root, Repo, WtBase: string;

procedure MakeRepo;
begin
  Root := JoinPath(GetTempDir, 'pasclaw-wt-' + IntToStr(GetProcessID));
  if DirectoryExists(Root) then Sh(GetTempDir, 'rm -rf ' + Root);
  Repo := JoinPath(Root, 'proj');
  ForceDirectories(Repo);
  Sh(Repo, 'git init -q -b main . && git config user.email t@t && git config user.name t && ' +
           'echo hello > README && git add README && git commit -q -m init');
  WtBase := JoinPath(Root, 'proj-worktrees');
end;

procedure TestPure;
begin
  AssertEqStr(BranchDirName('feature/login-form'), 'feature-login-form', 'slash -> dash');
  AssertEqStr(BranchDirName('///'), 'worktree', 'all separators -> fallback');
  AssertEqStr(BranchDirName('x.y_z-1'), 'x.y_z-1', 'safe chars kept');
  AssertEqStr(WorktreeBaseDir('/a/b/repo', ''), '/a/b/repo-worktrees', 'default beside repo');
  AssertEqStr(WorktreeBaseDir('/a/b/repo', '/tmp/wts'), '/tmp/wts', 'configured wins');
  WriteLn('  ok: BranchDirName / WorktreeBaseDir');
end;

procedure TestRoundTrip;
var
  R, Path, Path2, Err, Text: string;
begin
  AssertTrue(GitRepoRoot(Repo, R), 'repo root found');
  AssertEqStr(R, Repo, 'repo root is the repo');
  AssertTrue(not GitRepoRoot(GetTempDir, R), 'tmp is not a repo');

  AssertTrue(WorktreeCreate(Repo, '', 'feat-a', '', Path, Err), 'create: ' + Err);
  AssertEqStr(Path, JoinPath(WtBase, 'feat-a'), 'default location');
  AssertTrue(DirectoryExists(Path), 'worktree dir exists');
  AssertTrue(FileExists(JoinPath(Path, 'README')), 'checkout has the file');
  AssertContains(Trim(Sh(Path, 'git branch --show-current')), 'feat-a', 'on the branch');

  AssertTrue(WorktreeCreate(Repo, '', 'feat-a', '', Path2, Err), 'create again: ' + Err);
  AssertEqStr(Path2, Path, 'idempotent');

  AssertTrue(WorktreeList(Repo, Text, Err), 'list: ' + Err);
  AssertContains(Text, Path + '  feat-a', 'list names the worktree and branch');
  AssertContains(Text, Repo + '  main', 'list names the main checkout');

  AssertTrue(not WorktreeDirty(Path), 'clean after create');
  AssertTrue(WorktreeRemove(Repo, Path, False, Err), 'remove clean: ' + Err);
  AssertTrue(not DirectoryExists(Path), 'gone');
  AssertTrue(not WorktreeRemove(Repo, Repo, True, Err), 'main checkout refused');
  AssertContains(Err, 'main checkout', 'says why');

  { Dirty refusal. }
  AssertTrue(WorktreeCreate(Repo, '', 'feat-b', 'main', Path, Err), 'create b: ' + Err);
  WriteFileText(JoinPath(Path, 'scratch.txt'), 'wip');
  AssertTrue(WorktreeDirty(Path), 'dirty');
  AssertTrue(not WorktreeRemove(Repo, Path, False, Err), 'dirty refused');
  AssertContains(Err, 'uncommitted', 'dirty message');
  AssertTrue(DirectoryExists(Path), 'still there');
  AssertTrue(WorktreeRemove(Repo, Path, True, Err), 'force removes: ' + Err);
  AssertTrue(not DirectoryExists(Path), 'force gone');

  { Bad names. }
  AssertTrue(not WorktreeCreate(Repo, '', 'x; rm -rf /', '', Path, Err), 'shell-shaped branch refused');
  AssertTrue(not WorktreeCreate(Repo, '', '-flag', '', Path, Err), 'dash-leading branch refused');
  WriteLn('  ok: create / list / remove, idempotent create, dirty refusal, force, bad names');
end;

procedure TestTools;
var
  Reg: TToolRegistry;
  Pol: TSandboxPolicy;
  Err, Res: string;
begin
  Pol := Default(TSandboxPolicy);
  Pol.ShellDenyEnabled := True;
  ConfigureSandbox(Pol, Repo);
  Reg := TToolRegistry.Create;
  try
    RegisterWorktreeTools(Reg);
    Res := Reg.RunTool('worktree_create', '{"branch":"tool-x"}', Err);
    AssertEqStr(Err, '', 'tool create ok');
    AssertContains(Res, 'worktree ready: ' + JoinPath(WtBase, 'tool-x'), 'tool create path');
    Res := Reg.RunTool('worktree_list', '{}', Err);
    AssertContains(Res, 'tool-x', 'tool list');
    Res := Reg.RunTool('worktree_remove', '{"path":"' + JoinPath(WtBase, 'tool-x') + '"}', Err);
    AssertEqStr(Err, '', 'tool remove ok');
    Res := Reg.RunTool('worktree_remove', '{"path":"' + JoinPath(WtBase, 'nope') + '"}', Err);
    AssertContains(Err, 'no such directory', 'tool remove missing');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: worktree_* tools through the registry');
end;

{ ---- thread override ---- }

type
  TWsProbe = class(TThread)
  public
    Seen, After: string;
    procedure Execute; override;
  end;

procedure TWsProbe.Execute;
begin
  SetThreadSandboxWorkspace(JoinPath(Root, 'elsewhere'));
  Seen := CurrentWorkspace;
  SetThreadSandboxWorkspace('');
  After := CurrentWorkspace;
end;

var
  GHandlerSawWs: string;

function ProbeTool(const ArgsJSON: string; out ErrMsg: string): string;
begin
  ErrMsg := '';
  GHandlerSawWs := CurrentWorkspace;
  Result := 'ok';
end;

procedure TestThreadOverride;
var
  T: TWsProbe;
  Reg: TToolRegistry;
  Tool: TTool;
  Cfg: TToolLoopConfig;
  Disp: IToolDispatcher;
  Err: string;
begin
  ForceDirectories(JoinPath(Root, 'elsewhere'));
  T := TWsProbe.Create(True);
  try
    T.Start;
    T.WaitFor;
    AssertEqStr(T.Seen, JoinPath(Root, 'elsewhere'), 'worker sees its override');
    AssertEqStr(T.After, Repo, 'worker cleared -> process workspace');
  finally
    T.Free;
  end;
  AssertEqStr(CurrentWorkspace, Repo, 'main thread never saw the override');

  Reg := TToolRegistry.Create;
  try
    FillChar(Tool, SizeOf(Tool), 0);
    Tool.Name := 'probe'; Tool.Description := 'd'; Tool.Schema := '{"type":"object"}';
    Tool.Handler := @ProbeTool; Tool.Category := tcReadOnly;
    Reg.Register(Tool);
    Cfg := Default(TToolLoopConfig);
    Cfg.Registry := Reg; Cfg.Model := 'fake'; Cfg.MaxIterations := 1;
    Cfg.Workspace := JoinPath(Root, 'elsewhere');
    Disp := MakeLoopDispatcher(Cfg);
    GHandlerSawWs := '';
    Disp.Dispatch('probe', '{}', Err);
    AssertEqStr(GHandlerSawWs, JoinPath(Root, 'elsewhere'), 'dispatch brackets Cfg.Workspace');
    AssertEqStr(CurrentWorkspace, Repo, 'restored after dispatch');
  finally
    Reg.Free;
  end;
  WriteLn('  ok: per-thread override and the dispatch bracket');
end;

{ ---- spawn with a worktree ---- }

type
  { First call: write a relative file. Second call: done. }
  TWriterProvider = class(TInterfacedObject, ILLMProvider)
  public
    Calls: Integer;
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                  const Model: string; const Options: TChatOptions): TLLMResponse;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                        const Model: string; const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
  end;

function TWriterProvider.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                              const Model: string; const Options: TChatOptions): TLLMResponse;
begin
  Result := Default(TLLMResponse);
  Result.StatusCode := 200;
  Inc(Calls);
  if Calls = 1 then
  begin
    SetLength(Result.ToolCalls, 1);
    Result.ToolCalls[0].Id := 'c1';
    Result.ToolCalls[0].Kind := 'function';
    Result.ToolCalls[0].Func.Name := 'fs_write';
    Result.ToolCalls[0].Func.Arguments := '{"path":"child-note.txt","content":"from the child"}';
    Result.FinishReason := 'tool_calls';
  end
  else
  begin
    Result.Content := 'wrote the note';
    Result.FinishReason := 'stop';
  end;
end;

function TWriterProvider.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                                    const Model: string; const Options: TChatOptions;
                                    OnChunk: TStreamCallback): TLLMResponse;
begin Result := Chat(Messages, Tools, Model, Options); end;
function TWriterProvider.GetDefaultModel: string; begin Result := 'fake'; end;
function TWriterProvider.GetName: string; begin Result := 'fake-writer'; end;
function TWriterProvider.SupportsThinking: Boolean; begin Result := False; end;
function TWriterProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TWriterProvider.SupportsStreaming: Boolean; begin Result := False; end;

procedure TestSpawnWorktree;
var
  Parent: TToolRegistry;
  Ctx: TSubagentContext;
  Specs: TSubagentSpecArray;
  Tool: TSpawnTool;
  Prov: ILLMProvider;
  Res, Err, WtPath: string;
begin
  Prov := TWriterProvider.Create;
  Parent := TToolRegistry.Create;
  try
    RegisterFSTools(Parent, False);
    Ctx := Default(TSubagentContext);
    Ctx.Provider := Prov;
    Ctx.ParentRegistry := Parent;
    Ctx.DefaultModel := 'fake';
    SetLength(Specs, 1);
    Specs[0].Name := 'writer';
    Specs[0].Description := 'writes';
    Specs[0].SystemPrompt := 'You write files.';
    SetLength(Specs[0].Tools, 1);
    Specs[0].Tools[0] := 'fs_write';
    Specs[0].MaxIter := 3;
    Tool := TSpawnTool.Create(Ctx, Specs);
    try
      AssertContains(Tool.Schema, '"worktree"', 'spawn schema advertises worktree');
      Res := Tool.Run('{"agent":"writer","prompt":"write a note","worktree":"child-branch"}', Err);
      AssertEqStr(Err, '', 'spawn ok');
      WtPath := JoinPath(WtBase, 'child-branch');
      AssertContains(Res, 'worked in worktree ' + WtPath, 'result names the worktree');
      AssertTrue(FileExists(JoinPath(WtPath, 'child-note.txt')), 'relative write landed in the worktree');
      AssertTrue(not FileExists(JoinPath(Repo, 'child-note.txt')), 'and not in the parent tree');
      AssertEqStr(CurrentWorkspace, Repo, 'parent workspace restored after spawn');
      { Not a repo: a clear error, no child run. }
      ConfigureSandbox(Default(TSandboxPolicy), JoinPath(Root, 'elsewhere'));
      Res := Tool.Run('{"agent":"writer","prompt":"x","worktree":"nope"}', Err);
      AssertContains(Err, 'not inside a git repository', 'no repo -> error');
      ConfigureSandbox(Default(TSandboxPolicy), Repo);
    finally
      Tool.Free;
    end;
  finally
    Parent.Free;
  end;
  WriteLn('  ok: spawn(worktree) runs the child in its own checkout');
end;


function BranchExists(const Branch: string): Boolean;
begin
  Result := Trim(Sh(Repo, 'git branch --list ' + Branch)) <> '';
end;

procedure AssertNothingCreated(const Branch, Why: string);
begin
  AssertTrue(not DirectoryExists(JoinPath(WtBase, Branch)),
             Why + ': no worktree directory was created for ' + Branch);
  AssertTrue(not BranchExists(Branch),
             Why + ': no branch ' + Branch + ' was created');
end;

function WriterSpecs: TSubagentSpecArray;
begin
  SetLength(Result, 1);
  Result[0].Name := 'writer';
  Result[0].Description := 'writes';
  Result[0].SystemPrompt := 'You write files.';
  SetLength(Result[0].Tools, 1);
  Result[0].Tools[0] := 'fs_write';
  Result[0].MaxIter := 3;
end;

procedure TestWorktreeFlagIsHonouredBySpawn;
(* worktree.enabled:false has to take away every way to make a worktree.

   Only the standalone worktree_* tools used to go: spawn and
   spawn_background still advertised a `worktree` argument and still made
   a branch and a checkout when it was passed. (Codex P2 on #612.) *)
var
  Parent: TToolRegistry;
  Ctx: TSubagentContext;
  Tool: TSpawnTool;
  Coord: TBackgroundSpawnCoordinator;
  Cfg: TConfig;
  Prov: ILLMProvider;
  Res, Err: string;
  T: TTool;
begin
  Prov := TWriterProvider.Create;
  Parent := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.Worktree.Enabled := False;
    RegisterFSTools(Parent, False);
    Ctx := Default(TSubagentContext);
    Ctx.Provider := Prov;
    Ctx.ParentRegistry := Parent;
    Ctx.DefaultModel := 'fake';
    Ctx.Cfg := Cfg;

    { spawn }
    Tool := TSpawnTool.Create(Ctx, WriterSpecs);
    try
      AssertTrue(Pos('"worktree"', Tool.Schema) = 0,
                 'spawn does not offer worktree when the feature is off');
      Res := Tool.Run('{"agent":"writer","prompt":"x","worktree":"flag-off-a"}', Err);
      AssertContains(Err, 'worktrees are turned off', 'spawn refuses the argument');
      AssertNothingCreated('flag-off-a', 'spawn with worktree.enabled:false');
    finally
      Tool.Free;
    end;

    { spawn_background }
    Coord := RegisterBackgroundSpawnTools(Parent, Ctx, WriterSpecs);
    AssertTrue(Parent.Find('spawn_background', T), 'spawn_background registered');
    AssertTrue(Pos('"worktree"', T.Schema) = 0,
               'spawn_background does not offer worktree when the feature is off');
    Res := Coord.HandleSpawnBackground(
             '{"agent":"writer","prompt":"x","worktree":"flag-off-b"}', Err);
    AssertContains(Err, 'worktrees are turned off', 'spawn_background refuses it too');
    AssertNothingCreated('flag-off-b', 'spawn_background with worktree.enabled:false');

    { With the feature on (the default) both offer it again. }
    Cfg.Worktree.Enabled := True;
    Tool := TSpawnTool.Create(Ctx, WriterSpecs);
    try
      AssertContains(Tool.Schema, '"worktree"', 'and spawn offers it when on');
    finally
      Tool.Free;
    end;
  finally
    Parent.Free;
    Cfg.Free;
  end;
  WriteLn('  ok: worktree.enabled:false is honoured by spawn and spawn_background');
end;

procedure TestRejectedSpawnTouchesNoRepo;
(* A spawn that is going to be refused must not create anything first.

   spawn_background made the worktree, THEN checked the job cap, so a
   spawn the cap was always going to refuse still left a branch and a
   checkout behind. spawn did the same with its cheap checks: no prompt,
   or a misspelt agent, made a worktree on the way to being refused.
   (Codex P2 on #612.) *)
var
  Parent: TToolRegistry;
  Ctx: TSubagentContext;
  Tool: TSpawnTool;
  Coord: TBackgroundSpawnCoordinator;
  Cfg: TConfig;
  Prov: ILLMProvider;
  Res, Err, H: string;
  i, P: Integer;
begin
  Prov := TWriterProvider.Create;
  Parent := TToolRegistry.Create;
  Cfg := TConfig.Create;
  try
    Cfg.BackgroundJobsMax := 1;
    RegisterFSTools(Parent, False);
    Ctx := Default(TSubagentContext);
    Ctx.Provider := Prov;
    Ctx.ParentRegistry := Parent;
    Ctx.DefaultModel := 'fake';
    Ctx.Cfg := Cfg;

    { spawn: refused for a bad agent name, before any git. }
    Tool := TSpawnTool.Create(Ctx, WriterSpecs);
    try
      Res := Tool.Run('{"agent":"no-such-agent","prompt":"x","worktree":"reject-a"}', Err);
      AssertContains(Err, 'no subagent named', 'spawn refuses the agent');
      AssertNothingCreated('reject-a', 'spawn with an unknown agent');
      Res := Tool.Run('{"agent":"writer","prompt":"","worktree":"reject-b"}', Err);
      AssertContains(Err, 'prompt required', 'spawn refuses an empty prompt');
      AssertNothingCreated('reject-b', 'spawn with no prompt');
    finally
      Tool.Free;
    end;

    { spawn_background at the cap: one shell job holds the only slot. }
    Coord := RegisterBackgroundSpawnTools(Parent, Ctx, WriterSpecs);
    Coord.SetKey('cap-test');
    Res := Coord.HandleShellBackground('{"command":"sleep 30"}', Err);
    AssertEqStr(Err, '', 'the slot-holder starts');
    H := '';
    P := Pos('handle=', Res);
    if P > 0 then
    begin
      i := P + 7;
      while (i <= Length(Res)) and (Res[i] in ['a'..'z', '0'..'9', '-']) do
      begin
        H := H + Res[i];
        Inc(i);
      end;
    end;
    AssertTrue(H <> '', 'slot-holder handle: ' + Res);
    Res := Coord.HandleSpawnBackground(
             '{"agent":"writer","prompt":"x","worktree":"reject-cap"}', Err);
    AssertContains(Err, 'already running', 'spawn_background refused at the cap');
    AssertNothingCreated('reject-cap',
      'spawn_background at the cap -- the refusal used to come after git');
    Coord.HandleCancel('{"handle":"' + H + '"}', Err);
  finally
    Parent.Free;
    Cfg.Free;
  end;
  WriteLn('  ok: a refused spawn creates no branch and no worktree');
end;

begin
  MakeRepo;
  try
    TestPure;
    TestRoundTrip;
    TestTools;
    TestThreadOverride;
    TestSpawnWorktree;
    TestWorktreeFlagIsHonouredBySpawn;
    TestRejectedSpawnTouchesNoRepo;
    WriteLn('PASS');
  finally
    Sh(GetTempDir, 'rm -rf ' + Root);
  end;
end.
