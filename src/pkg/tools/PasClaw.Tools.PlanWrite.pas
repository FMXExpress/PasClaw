(*
  PasClaw.Tools.PlanWrite - the `plan_write` tool used by `pasclaw plan`.

  Why this exists
  ===============

  `pasclaw plan` runs the agent in `pmPlan` mode (read-only safety gate
  -- no fs_write, no shell mutations, no edits). For the command to
  produce a deliverable, SOMETHING has to write the model's finalized
  plan to `<PASCLAW_HOME>/workspace/PLAN.md`. Two options:

    a) Have the wrapper capture stdout and tee to PLAN.md. Fragile --
       FPC's Output redirection is finicky, and the agent prints
       progress alongside the final reply so we'd have to parse out
       the plan text.

    b) Give the model a tool that writes specifically to PLAN.md.
       Transactional, transparent, the model decides when the plan
       is "done" by calling the tool. This is the chosen path.

  The tool is registered ONLY when `Cmd.Agent` builds the registry
  with `EnablePlanWrite := True`, which happens iff `--mode plan` was
  passed. `pasclaw agent --mode plan` (without the `plan` subcommand)
  also gets the tool -- it's a sensible default for plan-mode
  sessions.

  Why category tcReadOnly even though it writes
  ============================================

  `pmPlan`'s dispatch gate refuses tcMutating tools. `plan_write`
  writes exactly one file at a fixed path (workspace/PLAN.md) -- it's
  meta-state describing intent, not project code. Marking it
  tcReadOnly lets it pass the plan-mode gate without weakening the
  gate's protection on real mutation tools (fs_write, shell_exec,
  fs_edit_hashline, etc.) which stay refused.

  This is the only tool in the codebase that's labeled tcReadOnly
  while writing to disk. The justification is the scope: a single
  hard-coded file with no path argument. The tool cannot be turned
  into a general-purpose write primitive by a model crafting clever
  arguments -- the path is not parameterised.

  Sandbox interaction
  ====================

  Workspace sandbox (PasClaw.Tools.Sandbox) still applies on the
  write, so an operator's `sandbox.restrict_to_workspace` setting
  is honoured. The plan file lives under <home>/workspace/ which
  IS the workspace root, so the sandbox check passes in the normal
  case. Operators who've narrowed the workspace below the home dir
  get a sandbox-refused error and the model retries with the
  configured workspace.
*)
unit PasClaw.Tools.PlanWrite;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterPlanWriteTool(R: TToolRegistry);

{ Returns the canonical absolute path the tool writes to.
  <PASCLAW_HOME>/workspace/PLAN.md. Exposed for tests and for
  Cmd.Plan's post-run sanity check. }
function ResolvePlanPath: string;

const
  PLAN_FILENAME = 'PLAN.md';

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Tools.Sandbox;

function ResolvePlanPath: string;
begin
  Result := JoinPath(JoinPath(GetHome, 'workspace'), PLAN_FILENAME);
end;

function ParseContentArg(const ArgsJSON: string;
                         out Content: string;
                         out ErrMsg: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  Content := '';
  ErrMsg := '';
  if Trim(ArgsJSON) = '' then
  begin
    ErrMsg := 'plan_write: missing arguments';
    Exit;
  end;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then
    begin
      ErrMsg := 'plan_write: invalid JSON arguments';
      Exit;
    end;
    try
      if not Obj.Has('content') then
      begin
        { Treat a missing `content` key the same way fs_write does -- it
          almost always means the provider truncated mid-tool_call. The
          model gets the error and retries on the next iteration; we do
          NOT silently write an empty plan. }
        ErrMsg := 'plan_write: missing required argument `content` ' +
                  '(provider may have truncated; please retry with the ' +
                  'full plan body)';
        Exit;
      end;
      Content := Obj.GetStr('content', '');
    finally
      Obj.Free;
    end;
  except
    on E: Exception do
    begin
      ErrMsg := 'plan_write: ' + E.ClassName + ': ' + E.Message;
      Exit;
    end;
  end;
  Result := True;
end;

function Tool_PlanWrite(const ArgsJSON: string; out ErrMsg: string): string;
var
  Content, PlanPath, Reason: string;
begin
  ErrMsg := '';
  Result := '';
  if not ParseContentArg(ArgsJSON, Content, ErrMsg) then Exit;

  PlanPath := ResolvePlanPath;

  { Sandbox check: even though the path is hard-coded, the operator
    may have narrowed the workspace below the default. Surface the
    refusal to the model so it can ask the operator to widen it. }
  if not CanWritePath(PlanPath, Reason) then
  begin
    ErrMsg := 'plan_write: refused by sandbox: ' + Reason;
    Exit;
  end;

  if not ForceDirectories(ExtractFilePath(PlanPath)) then
  begin
    ErrMsg := 'plan_write: cannot create directory for ' + PlanPath;
    Exit;
  end;

  try
    WriteFileText(PlanPath, Content);
  except
    on E: Exception do
    begin
      ErrMsg := 'plan_write: write failed: ' + E.ClassName + ': ' + E.Message;
      Exit;
    end;
  end;

  LogInfo('plan_write: wrote %d byte(s) to %s',
          [Length(Content), PlanPath]);
  Result := Format('wrote %d byte(s) to %s', [Length(Content), PlanPath]);
end;

const
  PlanWriteDesc =
    'Save the finalized plan to workspace/PLAN.md. ONE call per ' +
    '`pasclaw plan` run -- when the plan is complete, call this once ' +
    'with the full markdown body and end your turn. Content should ' +
    'follow the structure: ## Goal, ## Files, ## Steps, ' +
    '## Open questions, ## Risks. The file path is hard-coded; do not ' +
    'pass a path argument.';

  PlanWriteSchema =
    '{"type":"object","properties":{' +
    '"content":{"type":"string","description":"Full markdown body of the plan."}' +
    '},"required":["content"]}';

procedure RegisterPlanWriteTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  FillChar(T, SizeOf(T), 0);
  T.Name        := 'plan_write';
  T.Description := PlanWriteDesc;
  T.Schema      := PlanWriteSchema;
  T.Handler     := Tool_PlanWrite;
  T.HandlerObj  := nil;
  T.IsCore      := False;
  { tcReadOnly -- see unit comment. Passes the pmPlan dispatch gate
    even though the handler writes a file. Justified by the fixed
    target path; the tool is not a general write primitive. }
  T.Category    := tcReadOnly;
  R.Register(T);
  LogInfo('plan_write: registered (plan mode)');
end;

end.
