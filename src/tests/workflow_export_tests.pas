program workflow_export_tests;
(*
  The workflow exporters (PasClaw.Workflow.Export) and the workflow file
  import (PasClaw.Workflow.Share), without a network or a gateway:

    - string escaping: Python literals, Pascal literals and ASCII-only JSON
      for quotes, backslashes, newlines, tabs, control characters, double
      braces, non-ASCII and a character outside the BMP;
    - every node kind (llm, replicate, an MCP tool, a built-in tool, an
      await), a loop and the inputs reach the Python export as data;
    - the Pascal export embeds a spec that parses back to the same workflow;
    - nothing secret from the config is in any export, and `requires` names
      what the workflow needs;
    - a workflow file round-trips through ParseWorkflowFile; bad files are
      refused with their reason; an import stages, refuses a clash, and
      takes --as / --replace / --approve.

  The e2e (src/tests/workflow_export_e2e.py) proves the exports RUN.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils, Classes,
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Tools.Sandbox,
  PasClaw.Workflow,
  PasClaw.Workflow.Store,
  PasClaw.Workflow.Export,
  PasClaw.Workflow.Share;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

procedure CheckEq(const Got, Want, Why: string);
begin
  if Got <> Want then
  begin
    WriteLn('FAIL: ', Why);
    WriteLn('   got:  ', Got);
    WriteLn('   want: ', Want);
    Inc(Failures);
  end;
end;

function Has(const Needle, Hay: string): Boolean;
begin
  Result := Pos(Needle, Hay) > 0;
end;

const
  NASTY = 'He said "stop" \ then' + #10 + 'left' + #9 + 'tab ' + #1 +
          ' {{inputs.topic}} and {{ stay, ''single'', café 😀';

function NewCfg: TConfig;
begin
  Result := TConfig.Create;
  SetLength(Result.Providers, 1);
  Result.Providers[0].Name := 'fake';
  Result.Providers[0].Kind := 'openai';
  Result.Providers[0].APIBase := 'http://127.0.0.1:9';
  Result.Providers[0].APIKey := 'sk-UNIT-SECRET';
  Result.Providers[0].Model := 'm1';
  Result.DefaultProvider := 'fake';
  Result.DefaultModel := 'm1';
  Result.Gateway.Token := 'GW-UNIT-SECRET';
  SetLength(Result.MCPServers, 2);
  Result.MCPServers[0].Name := 'fk';
  Result.MCPServers[0].Cmd := 'python3';
  Result.MCPServers[0].Args := 'server.py --era "legacy mode"';
  Result.MCPServers[0].Env := 'FAKE_TOKEN=ENV-UNIT-SECRET;OTHER=x';
  Result.MCPServers[0].Enabled := True;
  Result.MCPServers[1].Name := 'remote';
  Result.MCPServers[1].Cmd := 'https://mcp.example.com/mcp';
  Result.MCPServers[1].Args := 'Bearer HTTP-UNIT-SECRET';
  Result.MCPServers[1].Enabled := True;
end;

function AllKindsSpec: TWorkflowSpec;
var
  Err: string;
begin
  if not ParseWorkflow(
    '{"id":"all-kinds.v2","name":"all kinds","description":"every \"kind\"",' +
    '"inputs":[{"name":"topic","type":"string","required":true},{"name":"n","type":"number"}],' +
    '"outputs":[{"name":"o","value":"{{nodes.echo}}"}],' +
    '"nodes":[' +
    '{"id":"ask","tool":"llm","args":{"prompt":"' + 'He said \"stop\" \\ then\nleft {{inputs.topic}} {{ stay' + '","model":"big"}},' +
    '{"id":"echo","tool":"fk__echo","args":{"text":"{{nodes.ask}}"}},' +
    '{"id":"far","tool":"remote__lookup","args":{"q":"{{nodes.ask}}"}},' +
    '{"id":"pic","tool":"replicate","args":{"model":"owner/flux","input":{"prompt":"{{nodes.ask}}"}}},' +
    '{"id":"rd","tool":"read_file","args":{"path":"notes.txt"}},' +
    '{"id":"job","tool":"fk__start","args":{},"await":{"tool":"fk__status","args":{"id":"{{self.id}}"},' +
      '"status_selector":"state","success":["done"],"failure":["bad"],"interval_ms":5,"timeout_ms":50}}' +
    '],"edges":[{"from":"ask","to":"echo"}],' +
    '"loop":{"max":3,"until":"{{nodes.echo}}","feedback":[{"output":"o","input":"topic"}]}}',
    Result, Err) then
    raise Exception.Create('AllKindsSpec: ' + Err);
end;

procedure TestEscaping;
var
  Spec, Back: TWorkflowSpec;
  Err: string;
begin
  CheckEq(PythonStringLiteral(NASTY),
    '"He said \"stop\" \\ then\nleft\ttab \x01 {{inputs.topic}} and {{ stay, ''single'', caf\u00E9 \U0001F600"',
    'Python literal of quotes, backslash, newline, tab, control, braces, non-ASCII, astral');
  CheckEq(PythonStringLiteral(''), '""', 'empty Python literal');
  CheckEq(PascalStringLiteral('it''s'), '''it''''s''', 'Pascal literal doubles a quote');
  CheckEq(PascalStringLiteral('a' + #10 + 'b'), '''a''#10''b''', 'Pascal literal: a newline as #10');
  CheckEq(PascalStringLiteral(''), '''''', 'empty Pascal literal');
  CheckEq(AsciiJSON('{"d":"café 😀"}'), '{"d":"caf\u00E9 \uD83D\uDE00"}', 'AsciiJSON: \u escapes, a surrogate pair');
  CheckEq(ExportBaseName('my-flow.v2'), 'wf_my_flow_v2', 'export base name is an identifier');
  CheckEq(PrettyJSON('{"a":[1,{}],"b":"x{,}"}'),
    '{' + sLineBreak + '  "a": [' + sLineBreak + '    1,' + sLineBreak + '    {}' + sLineBreak + '  ],' +
    sLineBreak + '  "b": "x{,}"' + sLineBreak + '}', 'PrettyJSON keeps strings, indents the rest');
  { the spec the Pascal export embeds parses back to the same workflow }
  Spec := AllKindsSpec;
  Spec.Description := NASTY;
  Check(ParseWorkflow(AsciiJSON(WorkflowToJSON(Spec)), Back, Err), 'ASCII spec parses: ' + Err);
  CheckEq(Back.Description, NASTY, 'non-ASCII and controls survive the ASCII spec');
  CheckEq(WorkflowToJSON(Back), WorkflowToJSON(Spec), 'the ASCII spec is the same workflow');
end;

{ The Pascal literal pieces of `Result := Result + '...';` lines, joined. }
function EmbeddedSpec(const Src: string): string;
var
  L: TStringList;
  i, j: Integer;
  S, Num: string;
  InQ: Boolean;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Src;
    for i := 0 to L.Count - 1 do
    begin
      S := Trim(L[i]);
      if Copy(S, 1, 19) <> 'Result := Result + ' then Continue;
      S := Copy(S, 20, Length(S) - 20);   { drop the trailing ; }
      j := 1;
      InQ := False;
      while j <= Length(S) do
      begin
        if InQ then
        begin
          if S[j] = '''' then
          begin
            if (j < Length(S)) and (S[j + 1] = '''') then begin Result := Result + ''''; Inc(j); end
            else InQ := False;
          end
          else Result := Result + S[j];
        end
        else if S[j] = '''' then InQ := True
        else if S[j] = '#' then
        begin
          Num := '';
          Inc(j);
          while (j <= Length(S)) and CharInSet(S[j], ['0'..'9']) do begin Num := Num + S[j]; Inc(j); end;
          Result := Result + Chr(StrToInt(Num));
          Continue;
        end;
        Inc(j);
      end;
    end;
  finally
    L.Free;
  end;
end;

procedure TestPascalExport;
var
  Spec, Back: TWorkflowSpec;
  Src, Err: string;
begin
  Spec := AllKindsSpec;
  Spec.Description := NASTY;
  Spec.UiJSON := '{"pan":[1,2]}';
  Src := ExportWorkflowPascal(Spec);
  Check(Has('program wf_all_kinds_v2;', Src), 'program name is wf_<id>');
  Check(Has('PasClaw.Workflow.Standalone', Src), 'runs on PasClaw''s engine');
  Check(Has('{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}', Src), 'Delphi-compatible mode switch');
  Check(Has('fpc -MDelphi -Sh -Fubuild/lib -FEbuild wf_all_kinds_v2.dpr', Src), 'says how to build it');
  Check(Has('Halt(RunStandaloneWorkflow(WorkflowSpec));', Src), 'runs the embedded spec');
  Check(not Has('*)' + 'x', Src) and (Pos('*)', Src) = Pos('*)' + sLineBreak + 'program', Src)),
        'nothing in the header closes its comment early');
  Check(ParseWorkflow(EmbeddedSpec(Src), Back, Err), 'embedded spec parses: ' + Err);
  Spec.UiJSON := '';
  CheckEq(WorkflowToJSON(Back), WorkflowToJSON(Spec), 'embedded spec is the workflow (layout dropped)');
end;

procedure TestPythonExport;
var
  Spec: TWorkflowSpec;
  Cfg: TConfig;
  Src: string;
begin
  Cfg := NewCfg;
  Spec := AllKindsSpec;
  Src := ExportWorkflowPython(Spec, Cfg);
  Check(Has('#!/usr/bin/env python3', Src), 'shebang');
  Check(Has('Python 3.9+, standard library only', Src), 'requirements in the header');
  Check(Has('pip install mcp', Src), 'MCP steps: the header says pip install mcp');
  Check(Has('{"name": "topic", "type": "string", "required": True},', Src), 'inputs embedded');
  Check(Has('{"name": "n", "type": "number", "required": False},', Src), 'optional input embedded');
  Check(Has('# Usage: python3 wf_all_kinds_v2.py --input topic=... --input n=... [--json]', Src), 'usage line');
  { every node kind, its args as the exact JSON the engine templates }
  Check(Has('{"id": "ask", "tool": "llm",', Src), 'llm step');
  Check(Has('"args": ' + PythonStringLiteral(Spec.Nodes[0].ArgsJSON) + ',', Src), 'llm args, escaped exactly');
  Check(Has('\"He said \\\"stop\\\" \\\\ then\\nleft {{inputs.topic}} {{ stay\"', Src),
        'quotes, backslashes, newline and braces in the prompt');
  Check(Has('{"id": "echo", "tool": "fk__echo",', Src), 'MCP step');
  Check(Has('{"id": "pic", "tool": "replicate",', Src), 'replicate step');
  Check(Has('REPLICATE_API_TOKEN', Src), 'replicate: the token env var is named');
  Check(Has('{"id": "rd", "tool": "read_file",', Src), 'built-in step');
  Check(Has('not supported in the exported script', Src), 'unsupported built-ins fail clearly');
  Check(Has('"await": {"tool": "fk__status", "args": "{ \"id\" : \"{{self.id}}\" }", "status_selector": "state"', Src),
        'await embedded');
  Check(Has('"success": ["done"], "failure": ["bad"]}', Src), 'await statuses embedded');
  Check(Has('"loop": {"max": 3, "until": "{{nodes.echo}}", "feedback": [', Src), 'loop embedded');
  Check(Has('{"output": "o", "input": "topic"},', Src), 'loop feedback embedded');
  Check(Has('{"from": "ask", "to": "echo"},', Src), 'edges embedded');
  { providers and MCP servers, by reference }
  Check(Has('"fake": {"base_url": "http://127.0.0.1:9", "model": "m1", "key_env": "FAKE_API_KEY"},', Src), 'provider');
  Check(Has('FAKE_API_KEY', Src) and Has('LLM_BASE_URL', Src) and Has('LLM_MODEL', Src), 'LLM env vars named');
  Check(Has('"fk": {"command": "python3", "args": ["server.py", "--era", "legacy mode"]},', Src), 'stdio MCP server');
  Check(Has('"remote": {"url": "https://mcp.example.com/mcp", "auth_env": "MCP_REMOTE_AUTH"},', Src), 'HTTP MCP server');
  Check(Has('FAKE_TOKEN, OTHER', Src), 'MCP env var names listed');
  Check(not Has('"replicate": {', Src), 'the replicate step uses the HTTP API, not an MCP server');
  Check(Has('def run_repeated(spec, inputs):', Src), 'the runtime is appended');
  { no secrets }
  Check(not Has('sk-UNIT-SECRET', Src), 'no provider key');
  Check(not Has('ENV-UNIT-SECRET', Src), 'no MCP env value');
  Check(not Has('HTTP-UNIT-SECRET', Src), 'no HTTP MCP auth header');
  Check(not Has('GW-UNIT-SECRET', Src), 'no gateway token');
  { no loop, no MCP: no mcp package mentioned in the header }
  Spec.Loop.Enabled := False;
  SetLength(Spec.Nodes, 1);
  SetLength(Spec.Edges, 0);
  Src := ExportWorkflowPython(Spec, Cfg);
  Check(Has('    "loop": None,', Src), 'no loop: None');
  Check(not Has('#   MCP steps also need', Src), 'no MCP step: no mcp requirement');
  Cfg.Free;
end;

procedure TestRequirementsAndFile;
var
  Spec, Back: TWorkflowSpec;
  Cfg: TConfig;
  R: TWorkflowRequirements;
  Req, FileText, Err, RqJSON: string;
  Missing: TStringArray;
  i: Integer;
  S: string;
begin
  Cfg := NewCfg;
  Spec := AllKindsSpec;
  R := CollectWorkflowRequirements(Spec, Cfg);
  Req := RequirementsToJSON(R);
  Check(Has('"name" : "fk", "command" : "python3", "args" : ["server.py", "--era", "legacy mode"], "env" : ["FAKE_TOKEN", "OTHER"]', Req),
        'requires: stdio server with args and env NAMES: ' + Req);
  Check(Has('"name" : "remote", "url" : "https://mcp.example.com/mcp"', Req), 'requires: HTTP server by URL');
  Check(Has('"name" : "replicate"', Req), 'requires: the replicate step''s MCP server');
  Check(Has('"name" : "fake", "kind" : "openai", "models" : ["big"]', Req), 'requires: provider and model');
  Check(Has('"tools" : ["read_file"]', Req), 'requires: built-in tools');
  Check(Has('"replicate_models" : ["owner/flux"]', Req), 'requires: Replicate models');
  Check(not Has('UNIT-SECRET', Req), 'requires: no secrets');

  FileText := ExportWorkflowFile(Spec, Cfg);
  Check(not Has('UNIT-SECRET', FileText), 'workflow file: no secrets');
  Check(Has('"format": "pasclaw-workflow"', FileText) and Has('"version": 1', FileText), 'envelope');
  Check(ParseWorkflowFile(FileText, Back, RqJSON, Err), 'the file parses: ' + Err);
  CheckEq(WorkflowToJSON(Back), WorkflowToJSON(Spec), 'the spec round-trips through the file');

  Check(not ParseWorkflowFile('[1]', Back, RqJSON, Err) and Has('not a JSON object', Err), 'not an object: ' + Err);
  Check(not ParseWorkflowFile('{"format":"x"}', Back, RqJSON, Err) and Has('"format" is "x"', Err), 'wrong format: ' + Err);
  Check(not ParseWorkflowFile('{"version":1}', Back, RqJSON, Err) and Has('"format" is missing', Err), 'no format: ' + Err);
  Check(not ParseWorkflowFile('{"format":"pasclaw-workflow","version":2}', Back, RqJSON, Err) and Has('version 2', Err),
        'future version: ' + Err);
  Check(not ParseWorkflowFile('{"format":"pasclaw-workflow","version":1}', Back, RqJSON, Err) and
        Has('no "workflow"', Err), 'no workflow: ' + Err);
  Check(not ParseWorkflowFile('{"format":"pasclaw-workflow","version":1,"workflow":{"name":"x","nodes":[' +
        '{"id":"a","tool":"llm","args":{"p":"{{nodes.b}}"}}]}}', Back, RqJSON, Err) and Has('not valid', Err),
        'invalid spec: ' + Err);

  { a machine without the MCP servers or the provider }
  Check(ParseWorkflowFile(FileText, Back, RqJSON, Err), 'the file parses again: ' + Err);
  SetLength(Cfg.MCPServers, 0);
  Cfg.Providers[0].Name := 'other';
  Missing := MissingRequirements(Spec, RqJSON, Cfg, nil);
  S := '';
  for i := 0 to High(Missing) do S := S + Missing[i] + '|';
  Check(Has('MCP server "fk" is not configured here (the author ran: python3 server.py --era legacy mode)', S),
        'missing stdio server, with how: ' + S);
  Check(Has('MCP server "remote" is not configured here (the author ran: https://mcp.example.com/mcp)', S),
        'missing HTTP server: ' + S);
  Check(Has('provider "fake" is not configured here', S), 'missing provider: ' + S);
  Cfg.Free;
end;

procedure TestImport;
var
  Spec, Back: TWorkflowSpec;
  Cfg: TConfig;
  FileText, Err: string;
  R: TWorkflowImportResult;
begin
  Cfg := NewCfg;
  Spec := AllKindsSpec;
  Spec.Id := 'imp';
  FileText := ExportWorkflowFile(Spec, Cfg);
  Check(ImportWorkflowFile(FileText, '', False, False, Cfg, nil, R, Err), 'import: ' + Err);
  Check(R.Staged and (R.Id = 'imp') and not R.Replaces, 'import stages');
  Check(not WorkflowExists('imp'), 'a staged import is not saved');
  Check(LoadPendingWorkflow('imp', Back, Err), 'the staged copy loads: ' + Err);
  CheckEq(WorkflowToJSON(Back), WorkflowToJSON(Spec), 'the staged spec is the exported one');
  Check(not ImportWorkflowFile(FileText, '', False, False, Cfg, nil, R, Err) and R.Clash and
        Has('already waiting', Err), 'a second import clashes with the staged one: ' + Err);
  Check(ImportWorkflowFile(FileText, '', True, False, Cfg, nil, R, Err) and R.Replaces, 'replace: ' + Err);
  Check(ImportWorkflowFile(FileText, 'imp2', False, True, Cfg, nil, R, Err) and not R.Staged and
        WorkflowExists('imp2'), '--as with --approve saves: ' + Err);
  Check(not ImportWorkflowFile(FileText, 'imp2', False, False, Cfg, nil, R, Err) and R.Clash and
        Has('already saved', Err), 'a clash with a saved one: ' + Err);
  Check(not ImportWorkflowFile(FileText, '../x', False, False, Cfg, nil, R, Err) and Has('unsafe', Err),
        'an unsafe --as is refused: ' + Err);
  Check(not ImportWorkflowFile(FileText, 'pending', False, False, Cfg, nil, R, Err) and Has('reserved', Err),
        '"pending" is reserved: ' + Err);
  Check(not FetchWorkflowURL('file:///etc/passwd', 1000, FileText, Err) and Has('http', Err), 'file:// refused: ' + Err);
  Check(not FetchWorkflowURL('http://127.0.0.1:1/x', 1000, FileText, Err) and Has('SSRF', Err), 'private URL refused: ' + Err);
  Cfg.Free;
end;

procedure TestExportAs;
var
  Spec: TWorkflowSpec;
  Text, Name, Err: string;
begin
  Spec := AllKindsSpec;
  Check(ExportWorkflowAs(Spec, 'python', nil, Text, Name, Err) and (Name = 'wf_all_kinds_v2.py'), 'python name');
  Check(ExportWorkflowAs(Spec, 'pascal', nil, Text, Name, Err) and (Name = 'wf_all_kinds_v2.dpr'), 'pascal name');
  Check(ExportWorkflowAs(Spec, 'workflow', nil, Text, Name, Err) and (Name = 'all-kinds.v2.pasclaw-workflow.json'),
        'workflow file name');
  Check(not ExportWorkflowAs(Spec, 'cobol', nil, Text, Name, Err) and Has('unknown export language', Err),
        'unknown language refused');
end;

procedure PinWorkspaceToTestHome;
var
  Pol: TSandboxPolicy;
begin
  Pol.RestrictToWorkspace       := False;
  Pol.AllowReadOutsideWorkspace := True;
  Pol.Workspace                 := '';
  SetLength(Pol.AllowReadPaths, 0);
  SetLength(Pol.AllowWritePaths, 0);
  SetLength(Pol.CustomShellDeny, 0);
  Pol.ShellDenyEnabled          := False;
  Pol.BlockPrivateNetworks      := True;
  ForceDirectories(JoinPath(GetHome, 'workspace'));
  ConfigureSandbox(Pol, JoinPath(GetHome, 'workspace'));
end;

begin
  PinWorkspaceToTestHome;
  TestEscaping;
  TestPascalExport;
  TestPythonExport;
  TestRequirementsAndFile;
  TestImport;
  TestExportAs;
  if Failures = 0 then WriteLn('workflow_export_tests: OK')
  else begin WriteLn('workflow_export_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
