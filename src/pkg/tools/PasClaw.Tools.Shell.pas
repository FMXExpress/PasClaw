(*
  PasClaw.Tools.Shell - shell_exec tool. Runs a command via /bin/sh -c
  (or cmd.exe on Windows) and captures stdout+stderr.

  Safety: PasClaw.Tools.Sandbox.ShellAllowed enforces a token + substring
  denylist (sudo, rm, chmod, chown, kill family, mkfs, dd if=,
  command substitution, package installs, device writes, etc.) and,
  when sandbox.restrict_to_workspace is set, refuses commands that
  reference absolute paths outside the workspace. Both checks are
  configured from TConfig.Sandbox at command startup. This is the
  Phase-4-promised "workspace-restricted variant" the original
  comment kept pointing at.
*)
unit PasClaw.Tools.Shell;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterShellTool(R: TToolRegistry);

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Tools.Sandbox,
  PasClaw.Tools.Shell.Filters,
  PasClaw.Tools.OutputCache,     { AttachReversibleStashFooter --
                                   when ApplyShellFilter shrinks the
                                   bytes, stash the original so the
                                   model can recall it via
                                   tool_output_get. Same retrieval
                                   substrate the byte-cap path uses. }
  PasClaw.Shell.Backend;         { dispatch through the active
                                   IShellBackend instead of going
                                   straight to RunOneShot -- the
                                   docker backend exec's into a
                                   per-session container; the local
                                   backend is the legacy path. }

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if not Obj.Has(Field) then Exit;
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function Tool_Shell(const ArgsJSON: string; out ErrMsg: string): string;
var
  Cmd, Reason, WorkDir: string;
  ExitCode: Integer;
  Out_, RawOut: string;
begin
  ErrMsg := '';
  if not ParseStringArg(ArgsJSON, 'command', Cmd) then
  begin
    ErrMsg := 'missing required argument: command';
    Exit('');
  end;
  if not ShellAllowed(Cmd, Reason) then
  begin
    ErrMsg := Reason;
    Exit('');
  end;
  { Pin the shell's cwd to the workspace when restriction is on. Paired
    with the cd / chdir / pushd / popd token denylist and the '..'
    traversal check in ShellAllowed, this closes the relative-path
    bypass: a sandboxed model has no way to read or write files
    outside the workspace via shell_exec. When restriction is off,
    WorkDir is empty and RunOneShot inherits the parent's cwd
    (legacy behaviour, byte-identical to the previous release). }
  if RestrictionActive then
    WorkDir := CurrentWorkspace
  else
    WorkDir := '';
  LogDebug('shell exec (cwd=%s): %s', [WorkDir, Cmd]);
  ExitCode := RunOneShotViaBackend(GetCurrentSessionId, Cmd, WorkDir, Out_);
  { Per-command condenser. Tee-on-failure: ApplyShellFilter returns
    raw output verbatim when ExitCode <> 0 so the model gets full
    error context to debug. On the success path, known commands
    (git status/diff/log, npm/pytest/cargo test, grep/findstr/sls,
    ls -R / find / dir /s, with PowerShell-alias normalisation)
    get condensed; everything else passes through and falls back
    to the OutputCache byte cap if it's still oversize. }
  RawOut := Out_;
  Out_   := ApplyShellFilter(Cmd, Out_, ExitCode);
  { Reversible condensation (CCR). When the filter actually shrunk
    the bytes, stash the original under a fresh OutputCache handle
    and append a footer naming it so the model can retrieve the
    untruncated output via tool_output_get. ApplyShellFilter is
    tee-on-failure, so RawOut and Out_ are byte-identical on failure
    and the footer doesn't attach -- no wasted slots for raw error
    output. No-op when SetCondenseReversible(False) is in effect. }
  Out_ := AttachReversibleStashFooter(RawOut, Out_);
  Result := Format('exit=%d'#10'%s', [ExitCode, Out_]);
end;

procedure RegisterShellTool(R: TToolRegistry);
var
  T: TTool;
  Backend: IShellBackend;
  BackendNote: string;
begin
  Backend := GetActiveShellBackend;
  if (Backend <> nil) and (Backend.Name <> 'local') then
    { Tell the model where commands actually run so it doesn't
      `apt install` something expecting host-persistence. Same
      trick send_message uses to enumerate configured channels. }
    BackendNote := ' Runs via the ' + Backend.Name + ' shell backend: ' +
                   Backend.Describe + '.'
  else
    BackendNote := '';
  T.Name        := 'shell_exec';
  T.Description := 'Run a shell command via /bin/sh -c (or cmd.exe on Windows). ' +
                   'Captures stdout+stderr, caps output at 1 MiB.' + BackendNote;
  T.Schema      := '{"type":"object","properties":{"command":{"type":"string","description":"Shell command to execute."}},"required":["command"]}';
  T.Handler     := Tool_Shell;
  T.IsCore      := True;
  T.Category    := tcMutating;  { spawns subprocesses; default-mutating is correct }
  R.Register(T);
end;

end.
