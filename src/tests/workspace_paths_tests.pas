program workspace_paths_tests;
(*
  Pins that fs tools resolve RELATIVE paths against the configured workspace
  (CurrentWorkspace) rather than the process's launch directory. Before this,
  a gateway/serve run with sandbox.workspace set still wrote write_file("x")
  into the launch CWD (the repo root), diverging from what the system prompt
  advertised.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.FS;

procedure Fail_(const Msg: string);
begin WriteLn('FAIL: ' + Msg); Halt(1); end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin if not Cond then Fail_(Msg); end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin if Cond then Fail_(Msg); end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

var
  Pol: TSandboxPolicy;
  Reg: TToolRegistry;
  WsDir, AbsPath, Err, R: string;
begin
  WsDir := JoinPath(GetTempDir, 'pcwsrel');
  ForceDirectories(WsDir);
  { fresh }
  if FileExists(JoinPath(WsDir, 'rel.txt')) then DeleteFile(JoinPath(WsDir, 'rel.txt'));
  if FileExists(JoinPath(GetCurrentDir, 'rel.txt')) then DeleteFile(JoinPath(GetCurrentDir, 'rel.txt'));

  Pol := Default(TSandboxPolicy);
  Pol.RestrictToWorkspace := False;   { test resolution, not restriction }
  ConfigureSandbox(Pol, WsDir);

  { ResolveWorkspacePath: relative -> workspace; absolute -> itself. }
  AssertEqStr(ResolveWorkspacePath('rel.txt'),
              ExpandFileName(JoinPath(WsDir, 'rel.txt')),
              'ResolveWorkspacePath resolves relative against the workspace');
  AbsPath := ExpandFileName(JoinPath(WsDir, 'abs.txt'));
  AssertEqStr(ResolveWorkspacePath(AbsPath), AbsPath,
              'ResolveWorkspacePath passes an absolute path through');
  WriteLn('  ok: ResolveWorkspacePath (relative -> workspace, absolute -> itself)');

  Reg := TToolRegistry.Create;
  try
    RegisterFSTools(Reg, True);

    { A relative write must land in the workspace, NOT the launch dir. }
    R := Reg.RunTool('write_file', '{"path":"rel.txt","content":"hi"}', Err);
    AssertEqStr(Err, '', 'write_file relative no error');
    AssertTrue(FileExists(JoinPath(WsDir, 'rel.txt')),
      'relative write_file landed in the workspace');
    AssertFalse(FileExists(JoinPath(GetCurrentDir, 'rel.txt')),
      'relative write_file did NOT land in the launch CWD');

    { A relative read resolves to the same place. }
    AssertEqStr(Reg.RunTool('read_file', '{"path":"rel.txt","plain":true}', Err), 'hi',
      'relative read_file resolves to the workspace');

    { append_file relative resolves too. }
    Reg.RunTool('append_file', '{"path":"rel.txt","content":"!"}', Err);
    AssertEqStr(Reg.RunTool('read_file', '{"path":"rel.txt","plain":true}', Err), 'hi!',
      'relative append_file resolves to the workspace');

    WriteLn('  ok: write/read/append relative paths resolve to the workspace');
  finally
    Reg.Free;
    if FileExists(JoinPath(WsDir, 'rel.txt')) then DeleteFile(JoinPath(WsDir, 'rel.txt'));
    RemoveDir(WsDir);
  end;

  WriteLn('PASS');
end.
