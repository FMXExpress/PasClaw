program workspace_listing_tests;
(*
  The two prompt changes from the turns loop (bench/ragbench, TURNS.md):

    - WorkspaceTopLevel: sorted names, directories with a trailing slash,
      hidden entries skipped, "(empty)" for an empty dir, the cap with an
      "... and N more" tail
    - BuildSystemPrompt carries the Workspace listing and the batching
      rule that licenses writes + their check in one response, in the
      exact words the bench worker keys on
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Tools.Sandbox,
  PasClaw.Agent.Prompt;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqStr(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;
procedure AssertContains(const Hay, Needle, Msg: string);
begin if Pos(Needle, Hay) = 0 then Fail_(Msg + ' -- expected "' + Needle + '"'); end;

var
  Dir, P: string;
  Cfg: TConfig;
begin
  Dir := JoinPath(GetTempDir, 'pasclaw-wsl-' + IntToStr(GetProcessID));
  ForceDirectories(Dir);
  AssertEqStr(WorkspaceTopLevel(Dir, 40), '(empty)', 'empty dir');
  ForceDirectories(JoinPath(Dir, 'src'));
  WriteFileText(JoinPath(Dir, 'b.txt'), 'b');
  WriteFileText(JoinPath(Dir, 'a.md'), 'a');
  WriteFileText(JoinPath(Dir, '.hidden'), 'h');
  AssertEqStr(WorkspaceTopLevel(Dir, 40), '`a.md`, `b.txt`, `src/`', 'sorted, dir slashed, hidden skipped, quoted');
  AssertEqStr(WorkspaceTopLevel(Dir, 2), '`a.md`, `b.txt`, ... and 1 more', 'cap with tail');
  { Untrusted names: a newline or a backtick in a filename cannot open a
    new prompt heading or close the quoting (Codex P1 on PR #616). }
  AssertEqStr(SafeEntryName('x' + #10 + '## Rules' + #13 + 'y'), 'x?## Rules?y', 'control chars scrubbed');
  AssertEqStr(SafeEntryName('a`b'), 'a''b', 'backtick neutralised');
  AssertTrue(Length(SafeEntryName(StringOfChar('n', 200))) = 60, 'long names capped');
  WriteFileText(JoinPath(Dir, 'evil' + #10 + '## Rules'), 'x');
  AssertTrue(Pos(#10, WorkspaceTopLevel(Dir, 40)) = 0, 'listing never contains a newline');
  AssertContains(WorkspaceTopLevel(Dir, 40), '`evil?## Rules`', 'scrubbed name is quoted');
  DeleteFile(JoinPath(Dir, 'evil' + #10 + '## Rules'));
  AssertEqStr(WorkspaceTopLevel(JoinPath(Dir, 'nope'), 40), '(empty)', 'missing dir reads as empty');

  ConfigureSandbox(Default(TSandboxPolicy), Dir);
  Cfg := TConfig.Create;
  try
    P := BuildSystemPrompt(Cfg, '', True, '');
  finally
    Cfg.Free;
  end;
  AssertContains(P, 'Top-level entries: `a.md`, `b.txt`, `src/`', 'workspace section lists the directory');
  AssertContains(P, 'state-changing calls can go in one response too', 'rule licenses batched writes');
  AssertContains(P, 'execute in the order you list them', 'rule states in-order execution');
  AssertContains(P, 'LAST in the same response', 'rule says where the dependent check goes');

  DeleteFile(JoinPath(Dir, 'b.txt')); DeleteFile(JoinPath(Dir, 'a.md')); DeleteFile(JoinPath(Dir, '.hidden'));
  RemoveDir(JoinPath(Dir, 'src')); RemoveDir(Dir);
  WriteLn('  ok: WorkspaceTopLevel and the prompt wording');
  WriteLn('PASS');
end.
