(*
  PasClaw.Workflow.Standalone - run one workflow from the command line, the
  way a run in PasClaw runs it.

  Two callers:
    - `pasclaw workflow run <id>`: the saved spec;
    - a program `pasclaw workflow export <id> --lang pascal` wrote: the spec
      it embeds (RunStandaloneWorkflow reads ParamStr).

  Both load the user's PasClaw config, build a tool registry with the
  built-in tools a step can call, connect the configured MCP servers, and run
  RunWorkflowRepeated through WorkflowDispatch with the headless gate -- the
  permission rules apply and an `ask` is refused, as for any run with nobody
  to ask. Declared outputs are written to the workspace like workflow_run
  writes them.

    --input NAME=VALUE   a workflow input (repeatable)
    --json               print the outputs as one JSON object
    --no-files           do not write the outputs to the workspace
    --verbose            keep PasClaw's info log on stderr
    --help               the inputs and outputs

  Without --json one declared output prints as its bare value, several as
  `name: value` lines; with no declared outputs, the text of the last step
  that produced one (as workflow_run's "output"). Exit 0 on success, 1 when
  a step fails, 2 on bad arguments.
*)
unit PasClaw.Workflow.Standalone;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

{ Run SpecJSON with the program's own command line. }
function RunStandaloneWorkflow(const SpecJSON: string): Integer;
{ Run SpecJSON with Args (the flags above); Usage names the command in help. }
function RunWorkflowCommand(const SpecJSON, Usage: string; const Args: array of string): Integer;

implementation

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Workflow,
  PasClaw.Workflow.Dispatch,
  PasClaw.Workflow.Tools,       { WriteRunOutputs }
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,       { the headless gate every step goes through }
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ExecuteCode,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.SessionSearch,
  PasClaw.Tools.WebSearch,
  PasClaw.Search.Factory,
  PasClaw.Tools.WebFetch,
  PasClaw.Tools.Sandbox,
  PasClaw.Shell.Backend,
  PasClaw.Shell.Backend.Factory,
  PasClaw.Skills.Loader,
  PasClaw.MCP.Bridge;

procedure Help(const Spec: TWorkflowSpec; const Usage: string);
var
  i: Integer;
  Req: string;
begin
  WriteLn(Spec.Name + ' -- ' + Spec.Description);
  WriteLn;
  WriteLn('Usage: ' + Usage + ' [--input NAME=VALUE ...] [--json] [--no-files] [--verbose]');
  WriteLn;
  if Length(Spec.Inputs) = 0 then WriteLn('Inputs: (none)')
  else
  begin
    WriteLn('Inputs:');
    for i := 0 to High(Spec.Inputs) do
    begin
      if Spec.Inputs[i].Required then Req := ' (required)' else Req := '';
      WriteLn(Format('  %s: %s%s', [Spec.Inputs[i].Name, Spec.Inputs[i].InputType, Req]));
    end;
  end;
  if Length(Spec.Outputs) > 0 then
  begin
    WriteLn('Outputs:');
    for i := 0 to High(Spec.Outputs) do
      WriteLn(Format('  %s = %s', [Spec.Outputs[i].Name, Spec.Outputs[i].ValueTemplate]));
  end;
  WriteLn;
  WriteLn('  --input NAME=VALUE  a workflow input (repeatable)');
  WriteLn('  --json              print the outputs as JSON');
  WriteLn('  --no-files          do not write the outputs to the workspace');
  WriteLn('  --verbose           show PasClaw''s log on stderr');
  WriteLn('Providers, keys and MCP servers come from $PASCLAW_HOME/config.json.');
end;

function BuildRegistry(Cfg: TConfig): TToolRegistry;
begin
  Result := TToolRegistry.Create;
  RegisterFSTools(Result, True);
  RegisterShellTool(Result);
  RegisterExecuteCodeTool(Result);
  RegisterMemoryTools(Result);
  RegisterKBTools(Result);
  RegisterSessionSearchTool(Result);
  if HasConfiguredWebSearchProvider(Cfg) then RegisterWebSearchTool(Result);
  if Cfg.WebFetchEnabled then RegisterWebFetchTool(Result);
  { skills, and the workflow tools with them (a step may run a workflow) }
  RegisterSkills(Result, LoadSkillManifests(GetHome));
end;

function RunWorkflowCommand(const SpecJSON, Usage: string; const Args: array of string): Integer;
var
  Spec: TWorkflowSpec;
  Err, Name, Value, InputsJSON, OutJSON, OutErrs, Dir, DirErr, Text, Desc: string;
  Inputs, OutObj: TJsonObject;
  Keys: TStringList;
  i, Eq: Integer;
  AsJSON, NoFiles, Verbose, Ok: Boolean;
  Cfg: TConfig;
  Reg: TToolRegistry;
  Clients: TMCPClientList;
  Res: TWorkflowNodeResultArray;
  Saved: Pointer;
  Kind: TShellBackendKind;
begin
  if not ParseWorkflow(SpecJSON, Spec, Err) then
  begin
    WriteLn(ErrOutput, 'error: ' + Err);
    Exit(2);
  end;
  AsJSON := False;
  NoFiles := False;
  Verbose := False;
  Inputs := TJsonObject.Create;
  try
    i := 0;
    while i <= High(Args) do
    begin
      if (Args[i] = '--help') or (Args[i] = '-h') then
      begin
        Help(Spec, Usage);
        Exit(0);
      end
      else if Args[i] = '--json' then AsJSON := True
      else if Args[i] = '--no-files' then NoFiles := True
      else if Args[i] = '--verbose' then Verbose := True
      else if (Args[i] = '--input') or (Copy(Args[i], 1, 8) = '--input=') then
      begin
        if Args[i] = '--input' then
        begin
          if i = High(Args) then begin WriteLn(ErrOutput, 'error: --input needs NAME=VALUE'); Exit(2); end;
          Inc(i);
          Value := Args[i];
        end
        else
          Value := Copy(Args[i], 9, MaxInt);
        Eq := Pos('=', Value);
        if Eq < 2 then begin WriteLn(ErrOutput, 'error: --input wants NAME=VALUE, got "' + Value + '"'); Exit(2); end;
        Name := Copy(Value, 1, Eq - 1);
        Inputs.PutStr(Name, Copy(Value, Eq + 1, MaxInt));
      end
      else
      begin
        WriteLn(ErrOutput, 'error: unknown argument "' + Args[i] + '" (see --help)');
        Exit(2);
      end;
      Inc(i);
    end;
    for i := 0 to High(Spec.Inputs) do
      if Spec.Inputs[i].Required and not Inputs.Has(Spec.Inputs[i].Name) then
      begin
        WriteLn(ErrOutput, 'error: missing required input "' + Spec.Inputs[i].Name + '" (--input ' +
                Spec.Inputs[i].Name + '=...)');
        Exit(2);
      end;
    InputsJSON := Inputs.ToJSON;
  finally
    Inputs.Free;
  end;

  if not Verbose then SetLogLevel(llError);
  Cfg := LoadConfig;
  Reg := nil;
  SetLength(Clients, 0);
  try
    ConfigureSandbox(Cfg.Sandbox, '');
    try
      InstallShellBackend(Cfg, '', Kind, Desc);
    except
      on E: Exception do
      begin
        WriteLn(ErrOutput, 'error: ' + E.Message);
        Exit(1);
      end;
    end;
    Reg := BuildRegistry(Cfg);
    Clients := ConnectMCPServers(Cfg, Reg);
    SetWorkflowConfig(Cfg);
    EnterWorkflowRun(nil, Saved);
    try
      Ok := RunWorkflowRepeated(Spec, InputsJSON, @WorkflowDispatch, Res, Err);
    finally
      LeaveWorkflowRun(Saved);
    end;
    for i := 0 to High(Res) do
      if Res[i].Ok then WriteLn(ErrOutput, '  ok   ' + Res[i].NodeId + ' (' + Res[i].Tool + ')')
      else WriteLn(ErrOutput, '  FAIL ' + Res[i].NodeId + ' (' + Res[i].Tool + ')');
    if not Ok then
    begin
      WriteLn(ErrOutput, 'error: ' + Err);
      Exit(1);
    end;

    if Length(Spec.Outputs) > 0 then
    begin
      OutJSON := ResolveWorkflowOutputs(Spec, InputsJSON, Res, OutErrs);
      if OutErrs <> '' then WriteLn(ErrOutput, 'output error: ' + OutErrs);
      if not NoFiles then
        if WriteRunOutputs(Spec, OutJSON, FormatDateTime('yyyymmdd"T"hhnnss', Now), Dir, DirErr) then
          WriteLn(ErrOutput, 'outputs written to ' + Dir)
        else if DirErr <> '' then
          WriteLn(ErrOutput, 'outputs not written: ' + DirErr);
    end
    else
    begin
      Text := '';
      for i := High(Res) downto 0 do
        if Res[i].Text <> '' then begin Text := Res[i].Text; Break; end;
      OutObj := TJsonObject.Create;
      try
        OutObj.PutStr('output', Text);
        OutJSON := OutObj.ToJSON;
      finally
        OutObj.Free;
      end;
    end;

    if AsJSON then
      WriteLn(OutJSON)
    else
    begin
      OutObj := JsonTryParse(OutJSON);
      if OutObj <> nil then
      try
        Keys := OutObj.Keys;
        try
          if Keys.Count = 1 then
            WriteLn(OutObj.GetStr(Keys[0], ''))
          else
            for i := 0 to Keys.Count - 1 do
              WriteLn(Keys[i] + ': ' + OutObj.GetStr(Keys[i], ''));
        finally
          Keys.Free;
        end;
      finally
        OutObj.Free;
      end;
    end;
    Result := 0;
  finally
    { The MCP servers' processes stop here. The registry and the config are
      left to the process's exit: units' finalizations may still hold them. }
    FreeMCPClients(Clients);
  end;
end;

function RunStandaloneWorkflow(const SpecJSON: string): Integer;
var
  Args: array of string;
  i: Integer;
begin
  SetLength(Args, ParamCount);
  for i := 1 to ParamCount do Args[i - 1] := ParamStr(i);
  Result := RunWorkflowCommand(SpecJSON, ExtractFileName(ParamStr(0)), Args);
end;

end.
