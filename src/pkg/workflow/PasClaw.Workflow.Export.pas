(*
  PasClaw.Workflow.Export - a saved workflow as something to take away:

    python    a standalone Python 3.9+ script (wf_<id>.py) that re-implements
              the engine's semantics -- templates, selectors, order, await,
              loop, outputs -- over an OpenAI-compatible endpoint, Replicate's
              HTTP API and the official `mcp` SDK. Standard library only,
              except `mcp`, imported when an MCP step runs.
    pascal    an Object Pascal program (wf_<id>.dpr) that embeds the spec and
              runs it with PasClaw's own engine and units
              (PasClaw.Workflow.Standalone): the same gates, providers and MCP
              servers from the user's PasClaw config.
    workflow  the portable workflow file (<id>.pasclaw-workflow.json): a
              versioned envelope around the spec plus what it needs from the
              machine that runs it (requires). PasClaw.Workflow.Share imports
              it.

  Nothing secret is ever written: no provider key, no MCP env value, no HTTP
  MCP auth header (TMCPServer.Args of a URL server), no gateway token. The
  exports name environment variables instead.

  Every string embedded in generated source goes through PythonStringLiteral
  or PascalStringLiteral, so quotes, backslashes, newlines and double braces
  in prompts arrive byte for byte.
*)
unit PasClaw.Workflow.Export;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Utils,             { TStringArray }
  PasClaw.Config,
  PasClaw.Workflow;

type
  TWfReqMCP = record
    Name: string;
    Command: string;              { stdio: the command; '' for a URL server }
    Args: TStringArray;           { stdio: argv after the command }
    Url: string;                  { HTTP: the endpoint; never its auth header }
    EnvNames: TStringArray;       { names of the env vars it is configured with }
    Configured: Boolean;          { in this machine's config.json }
    SugarOnly: Boolean;           { only a `replicate` step needs it (the Python
                                    export calls Replicate's HTTP API instead) }
  end;

  TWfReqProvider = record
    Name: string;                 { '' = the default provider }
    Kind: string;
    BaseURL: string;
    Model: string;                { the provider's default model }
    Models: TStringArray;         { models the steps name }
    Configured: Boolean;
  end;

  TWorkflowRequirements = record
    MCP: array of TWfReqMCP;
    Providers: array of TWfReqProvider;
    Tools: TStringArray;          { built-in tools the steps call }
    ReplicateModels: TStringArray;
    UsesLLM, UsesMCP, UsesReplicate: Boolean;
  end;

{ What Spec needs from the machine that runs it. Cfg may be nil (nothing is
  then "configured", and no command/URL is known). }
function CollectWorkflowRequirements(const Spec: TWorkflowSpec; Cfg: TConfig): TWorkflowRequirements;
function RequirementsToJSON(const R: TWorkflowRequirements): string;

{ wf_<id>, every character an identifier cannot hold made '_'. }
function ExportBaseName(const Id: string): string;
{ A double-quoted, ASCII-only Python string literal for S (UTF-8 in FPC). }
function PythonStringLiteral(const S: string): string;
{ A single-quoted Pascal string literal for an ASCII S ('' doubled, control
  characters as #nn). }
function PascalStringLiteral(const S: string): string;
{ JSON text with every non-ASCII character as a \u escape (only strings hold
  them, so the text still parses to the same value). }
function AsciiJSON(const S: string): string;
{ JSON text indented two spaces per level. }
function PrettyJSON(const S: string): string;

function ExportWorkflowPython(const Spec: TWorkflowSpec; Cfg: TConfig): string;
function ExportWorkflowPascal(const Spec: TWorkflowSpec): string;
function ExportWorkflowFile(const Spec: TWorkflowSpec; Cfg: TConfig): string;

{ Lang: python | pascal | workflow (json is an alias of workflow). False
  with Err for any other language. FileName is the suggested download
  name. }
function ExportWorkflowAs(const Spec: TWorkflowSpec; const Lang: string; Cfg: TConfig;
  out Text, FileName, Err: string): Boolean;

const
  WORKFLOW_FILE_FORMAT  = 'pasclaw-workflow';
  WORKFLOW_FILE_VERSION = 1;

implementation

uses
  PasClaw.JSON;

{ ---------- text helpers ---------- }

{ The code point at S[i], advancing i past it. FPC strings here are UTF-8
  bytes; Delphi's are UTF-16 code units. An invalid sequence yields U+FFFD. }
function NextCodePoint(const S: string; var i: Integer): Cardinal;
{$IFDEF FPC}
var
  c: Cardinal;
  Need, k: Integer;
begin
  c := Ord(S[i]);
  Inc(i);
  if c < $80 then Exit(c);
  if (c and $E0) = $C0 then begin Result := c and $1F; Need := 1; end
  else if (c and $F0) = $E0 then begin Result := c and $0F; Need := 2; end
  else if (c and $F8) = $F0 then begin Result := c and $07; Need := 3; end
  else Exit($FFFD);
  for k := 1 to Need do
  begin
    if (i > Length(S)) or ((Ord(S[i]) and $C0) <> $80) then Exit($FFFD);
    Result := (Result shl 6) or (Cardinal(Ord(S[i])) and $3F);
    Inc(i);
  end;
end;
{$ELSE}
var
  c, d: Cardinal;
begin
  c := Ord(S[i]);
  Inc(i);
  if (c >= $D800) and (c <= $DBFF) and (i <= Length(S)) then
  begin
    d := Ord(S[i]);
    if (d >= $DC00) and (d <= $DFFF) then
    begin
      Inc(i);
      Exit($10000 + ((c - $D800) shl 10) + (d - $DC00));
    end;
  end;
  Result := c;
end;
{$ENDIF}

function PythonStringLiteral(const S: string): string;
var
  i: Integer;
  cp: Cardinal;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    SB.Append('"');
    i := 1;
    while i <= Length(S) do
    begin
      cp := NextCodePoint(S, i);
      case cp of
        Ord('\'): SB.Append('\\');
        Ord('"'): SB.Append('\"');
        10: SB.Append('\n');
        13: SB.Append('\r');
        9:  SB.Append('\t');
      else
        if (cp < 32) or (cp = 127) then SB.Append(Format('\x%.2x', [cp]))
        else if cp < 127 then SB.Append(Char(cp))
        else if cp <= $FFFF then SB.Append(Format('\u%.4x', [cp]))
        else SB.Append(Format('\U%.8x', [cp]));
      end;
    end;
    SB.Append('"');
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function PascalStringLiteral(const S: string): string;
var
  i: Integer;
  InQuote: Boolean;
begin
  Result := '';
  InQuote := False;
  for i := 1 to Length(S) do
  begin
    if (Ord(S[i]) < 32) or (Ord(S[i]) > 126) then
    begin
      if InQuote then begin Result := Result + ''''; InQuote := False; end;
      Result := Result + '#' + IntToStr(Ord(S[i]));
    end
    else
    begin
      if not InQuote then begin Result := Result + ''''; InQuote := True; end;
      if S[i] = '''' then Result := Result + ''''''
      else Result := Result + S[i];
    end;
  end;
  if InQuote then Result := Result + '''';
  if Result = '' then Result := '''''';
end;

function AsciiJSON(const S: string): string;
var
  i: Integer;
  cp: Cardinal;
  SB: TStringBuilder;
begin
  SB := TStringBuilder.Create;
  try
    i := 1;
    while i <= Length(S) do
    begin
      cp := NextCodePoint(S, i);
      if cp < 128 then SB.Append(Char(cp))
      else if cp <= $FFFF then SB.Append(Format('\u%.4x', [cp]))
      else
      begin
        Dec(cp, $10000);
        SB.Append(Format('\u%.4x\u%.4x', [$D800 + (cp shr 10), $DC00 + (cp and $3FF)]));
      end;
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function PrettyJSON(const S: string): string;
var
  i, j, Depth: Integer;
  C: Char;
  InStr: Boolean;
  SB: TStringBuilder;

  procedure NewLine;
  begin
    SB.Append(sLineBreak);
    SB.Append(StringOfChar(' ', Depth * 2));
  end;

begin
  SB := TStringBuilder.Create;
  try
    Depth := 0;
    InStr := False;
    i := 1;
    while i <= Length(S) do
    begin
      C := S[i];
      if InStr then
      begin
        SB.Append(C);
        if C = '\' then
        begin
          if i < Length(S) then SB.Append(S[i + 1]);
          Inc(i);
        end
        else if C = '"' then InStr := False;
      end
      else
        case C of
          '"': begin SB.Append(C); InStr := True; end;
          ' ', #9, #10, #13: ;
          '{', '[':
            begin
              j := i + 1;
              while (j <= Length(S)) and CharInSet(S[j], [' ', #9, #10, #13]) do Inc(j);
              if (j <= Length(S)) and (((C = '{') and (S[j] = '}')) or ((C = '[') and (S[j] = ']'))) then
              begin
                SB.Append(C); SB.Append(S[j]);
                i := j;
              end
              else
              begin
                SB.Append(C);
                Inc(Depth);
                NewLine;
              end;
            end;
          '}', ']':
            begin
              Dec(Depth);
              NewLine;
              SB.Append(C);
            end;
          ',': begin SB.Append(C); NewLine; end;
          ':': SB.Append(': ');
        else
          SB.Append(C);
        end;
      Inc(i);
    end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

{ A one-line comment's text: control characters become spaces, and nothing
  can close the comment it sits in. }
function CommentText(const S: string): string;
var
  i: Integer;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Ord(Result[i]) < 32 then Result[i] := ' ';
  Result := StringReplace(Result, '*)', '* )', [rfReplaceAll]);
end;

function ExportBaseName(const Id: string): string;
var
  i: Integer;
begin
  Result := 'wf_' + Id;
  for i := 1 to Length(Result) do
    if not CharInSet(Result[i], ['a'..'z', 'A'..'Z', '0'..'9', '_']) then
      Result[i] := '_';
end;

function EnvName(const S: string): string;
var
  i: Integer;
begin
  Result := UpperCase(S);
  for i := 1 to Length(Result) do
    if not CharInSet(Result[i], ['A'..'Z', '0'..'9', '_']) then
      Result[i] := '_';
end;

procedure AddUnique(var A: TStringArray; const S: string);
var
  i: Integer;
begin
  if S = '' then Exit;
  for i := 0 to High(A) do
    if A[i] = S then Exit;
  SetLength(A, Length(A) + 1);
  A[High(A)] := S;
end;

{ ---------- requirements ---------- }

function ArgStr(const ArgsJSON, Key: string): string;
var
  O: TJsonObject;
begin
  Result := '';
  O := JsonTryParse(ArgsJSON);
  if O = nil then Exit;
  try
    Result := Trim(O.GetStr(Key, ''));
  finally
    O.Free;
  end;
  { a template is decided at run time, not something to require }
  if Pos('{{', Result) > 0 then Result := '';
end;

function IsHttpURL(const S: string): Boolean;
begin
  Result := SameText(Copy(S, 1, 7), 'http://') or SameText(Copy(S, 1, 8), 'https://');
end;

{ Tokenize a stdio server's args the way PasClaw.MCP.StdioClient.SplitArgs
  does: unquoted whitespace splits, paired quotes group. }
function SplitArgList(const S: string): TStringArray;
var
  i: Integer;
  InQ: Boolean;
  Q: Char;
  Cur: string;
begin
  SetLength(Result, 0);
  Cur := '';
  InQ := False;
  Q := ' ';
  for i := 1 to Length(S) do
  begin
    if InQ then
    begin
      if S[i] = Q then InQ := False else Cur := Cur + S[i];
    end
    else if (S[i] = '"') or (S[i] = '''') then
    begin
      InQ := True;
      Q := S[i];
    end
    else if S[i] = ' ' then
    begin
      if Cur <> '' then begin SetLength(Result, Length(Result) + 1); Result[High(Result)] := Cur; Cur := ''; end;
    end
    else
      Cur := Cur + S[i];
  end;
  if Cur <> '' then begin SetLength(Result, Length(Result) + 1); Result[High(Result)] := Cur; end;
end;

{ The NAMES in an MCP server's env setting (KEY=value pairs, or a JSON
  object) -- never the values. }
function EnvNamesOf(const Env: string): TStringArray;
var
  O: TJsonObject;
  Keys: TStringList;
  Parts: TStringList;
  i, Eq: Integer;
begin
  SetLength(Result, 0);
  if Trim(Env) = '' then Exit;
  O := JsonTryParse(Env);
  if O <> nil then
  try
    Keys := O.Keys;
    try
      for i := 0 to Keys.Count - 1 do AddUnique(Result, Keys[i]);
    finally
      Keys.Free;
    end;
    Exit;
  finally
    O.Free;
  end;
  Parts := TStringList.Create;
  try
    Parts.Text := StringReplace(StringReplace(StringReplace(Env, ';', #10, [rfReplaceAll]),
      ',', #10, [rfReplaceAll]), ' ', #10, [rfReplaceAll]);
    for i := 0 to Parts.Count - 1 do
    begin
      Eq := Pos('=', Parts[i]);
      if Eq > 1 then AddUnique(Result, Trim(Copy(Parts[i], 1, Eq - 1)));
    end;
  finally
    Parts.Free;
  end;
end;

procedure RequireMCP(var R: TWorkflowRequirements; const Tool: string; Cfg: TConfig;
  Sugar: Boolean = False);
var
  i, P: Integer;
  Name: string;
  M: TWfReqMCP;
  Srv: TMCPServer;
  Found: Boolean;
begin
  if Pos('__', Tool) = 0 then Exit;
  R.UsesMCP := True;
  Name := '';
  Found := False;
  Srv := Default(TMCPServer);
  { the bridge's rule: the first configured server whose name + '__'
    prefixes the tool }
  if Cfg <> nil then
    for i := 0 to High(Cfg.MCPServers) do
      if (Cfg.MCPServers[i].Name <> '') and
         (Copy(Tool, 1, Length(Cfg.MCPServers[i].Name) + 2) = Cfg.MCPServers[i].Name + '__') and
         (Length(Tool) > Length(Cfg.MCPServers[i].Name) + 2) then
      begin
        Srv := Cfg.MCPServers[i];
        Name := Srv.Name;
        Found := True;
        Break;
      end;
  if Name = '' then
  begin
    P := Pos('__', Tool);
    Name := Copy(Tool, 1, P - 1);
  end;
  for i := 0 to High(R.MCP) do
    if R.MCP[i].Name = Name then
    begin
      if not Sugar then R.MCP[i].SugarOnly := False;
      Exit;
    end;
  M := Default(TWfReqMCP);
  M.Name := Name;
  M.SugarOnly := Sugar;
  M.Configured := Found and Srv.Enabled;
  if Found then
  begin
    if IsHttpURL(Srv.Cmd) then
      M.Url := Srv.Cmd           { Args of a URL server is its auth header: never exported }
    else
    begin
      M.Command := Srv.Cmd;
      M.Args := SplitArgList(Srv.Args);
    end;
    M.EnvNames := EnvNamesOf(Srv.Env);
  end;
  SetLength(R.MCP, Length(R.MCP) + 1);
  R.MCP[High(R.MCP)] := M;
end;

procedure RequireProvider(var R: TWorkflowRequirements; const Name, Model: string; Cfg: TConfig);
var
  i, k: Integer;
  P: TWfReqProvider;
  Eff: string;
begin
  Eff := Name;
  if (Eff = '') and (Cfg <> nil) then Eff := Cfg.DefaultProvider;
  for i := 0 to High(R.Providers) do
    if R.Providers[i].Name = Eff then
    begin
      AddUnique(R.Providers[i].Models, Model);
      Exit;
    end;
  P := Default(TWfReqProvider);
  P.Name := Eff;
  if Cfg <> nil then
    for k := 0 to High(Cfg.Providers) do
      if Cfg.Providers[k].Name = Eff then
      begin
        P.Configured := True;
        P.Kind := Cfg.Providers[k].Kind;
        P.BaseURL := Cfg.Providers[k].APIBase;
        P.Model := Cfg.Providers[k].Model;
        Break;
      end;
  if (P.Model = '') and (Cfg <> nil) and (Eff = Cfg.DefaultProvider) then P.Model := Cfg.DefaultModel;
  AddUnique(P.Models, Model);
  SetLength(R.Providers, Length(R.Providers) + 1);
  R.Providers[High(R.Providers)] := P;
end;

function CollectWorkflowRequirements(const Spec: TWorkflowSpec; Cfg: TConfig): TWorkflowRequirements;
var
  i: Integer;
  T, L, M: string;
begin
  Result := Default(TWorkflowRequirements);
  for i := 0 to High(Spec.Nodes) do
  begin
    T := Trim(Spec.Nodes[i].Tool);
    L := LowerCase(T);
    if (L = 'llm') or (L = 'provider') then
    begin
      Result.UsesLLM := True;
      RequireProvider(Result, ArgStr(Spec.Nodes[i].ArgsJSON, 'provider'),
                      ArgStr(Spec.Nodes[i].ArgsJSON, 'model'), Cfg);
    end
    else if L = 'replicate' then
    begin
      Result.UsesReplicate := True;
      M := ArgStr(Spec.Nodes[i].ArgsJSON, 'model');
      if M = '' then M := ArgStr(Spec.Nodes[i].ArgsJSON, 'version');
      AddUnique(Result.ReplicateModels, M);
      { in PasClaw the sugar runs through the Replicate MCP server }
      RequireMCP(Result, 'replicate__create_predictions', Cfg, True);
    end
    else if Pos('__', T) > 0 then
    begin
      RequireMCP(Result, T, Cfg);
      if Pos('create_prediction', L) > 0 then
      begin
        M := ArgStr(Spec.Nodes[i].ArgsJSON, 'model');
        if M = '' then M := ArgStr(Spec.Nodes[i].ArgsJSON, 'version');
        AddUnique(Result.ReplicateModels, M);
      end;
    end
    else if T <> '' then
      AddUnique(Result.Tools, T);
    if Spec.Nodes[i].Await.Enabled and (Trim(Spec.Nodes[i].Await.PollTool) <> '') then
    begin
      T := Trim(Spec.Nodes[i].Await.PollTool);
      if Pos('__', T) > 0 then RequireMCP(Result, T, Cfg)
      else AddUnique(Result.Tools, T);
    end;
  end;
end;

function StrArrayJSON(const A: array of string): TJsonArray;
var
  i: Integer;
begin
  Result := TJsonArray.Create;
  for i := 0 to High(A) do Result.AddStr(A[i]);
end;

function RequirementsToJSON(const R: TWorkflowRequirements): string;
var
  Root, O: TJsonObject;
  Arr, Sub: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(R.MCP) do
    begin
      O := TJsonObject.Create;
      O.PutStr('name', R.MCP[i].Name);
      if R.MCP[i].Url <> '' then
        O.PutStr('url', R.MCP[i].Url)
      else if R.MCP[i].Command <> '' then
      begin
        O.PutStr('command', R.MCP[i].Command);
        Sub := StrArrayJSON(R.MCP[i].Args);
        O.PutArray('args', Sub);
      end;
      if Length(R.MCP[i].EnvNames) > 0 then
      begin
        Sub := StrArrayJSON(R.MCP[i].EnvNames);
        O.PutArray('env', Sub);
      end;
      Arr.AddObject(O);
    end;
    Root.PutArray('mcp_servers', Arr);

    Arr := TJsonArray.Create;
    for i := 0 to High(R.Providers) do
    begin
      O := TJsonObject.Create;
      O.PutStr('name', R.Providers[i].Name);
      if R.Providers[i].Kind <> '' then O.PutStr('kind', R.Providers[i].Kind);
      Sub := StrArrayJSON(R.Providers[i].Models);
      if Sub.Count = 0 then
      begin
        Sub.Free;
        Sub := StrArrayJSON([R.Providers[i].Model]);
        if R.Providers[i].Model = '' then begin Sub.Free; Sub := TJsonArray.Create; end;
      end;
      O.PutArray('models', Sub);
      Arr.AddObject(O);
    end;
    Root.PutArray('providers', Arr);

    Sub := StrArrayJSON(R.Tools);
    Root.PutArray('tools', Sub);
    Sub := StrArrayJSON(R.ReplicateModels);
    Root.PutArray('replicate_models', Sub);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

{ ---------- the portable workflow file ---------- }

function ExportWorkflowFile(const Spec: TWorkflowSpec; Cfg: TConfig): string;
var
  Root: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('format', WORKFLOW_FILE_FORMAT);
    Root.PutInt('version', WORKFLOW_FILE_VERSION);
    Root.PutStr('exported_at', NowIsoUtc);
    Root.PutStr('pasclaw_version', FormatVersion);
    Root.PutRaw('workflow', WorkflowToJSON(Spec));
    Root.PutRaw('requires', RequirementsToJSON(CollectWorkflowRequirements(Spec, Cfg)));
    Result := PrettyJSON(Root.ToJSON) + sLineBreak;
  finally
    Root.Free;
  end;
end;

{ ---------- Python ---------- }

function PyList(const A: array of string): string;
var
  i: Integer;
begin
  Result := '[';
  for i := 0 to High(A) do
  begin
    if i > 0 then Result := Result + ', ';
    Result := Result + PythonStringLiteral(A[i]);
  end;
  Result := Result + ']';
end;

function PyBool(B: Boolean): string;
begin
  if B then Result := 'True' else Result := 'False';
end;

procedure AddPythonRuntime(L: TStringList);
begin
  {$I PasClaw.Workflow.Export.Runtime.inc}
end;

function ExportWorkflowPython(const Spec: TWorkflowSpec; Cfg: TConfig): string;
var
  L: TStringList;
  R: TWorkflowRequirements;
  i, k: Integer;
  S, Base, DefProv, DefModel: string;
  A: TWorkflowAwait;
  HasMCPLib: Boolean;
begin
  R := CollectWorkflowRequirements(Spec, Cfg);
  DefProv := '';
  DefModel := '';
  if Cfg <> nil then begin DefProv := Cfg.DefaultProvider; DefModel := Cfg.DefaultModel; end;
  HasMCPLib := False;
  for i := 0 to High(R.MCP) do
    if not R.MCP[i].SugarOnly then HasMCPLib := True;
  L := TStringList.Create;
  try
    L.Add('#!/usr/bin/env python3');
    L.Add('# ' + ExportBaseName(Spec.Id) + '.py -- the PasClaw workflow "' + CommentText(Spec.Name) +
          '", exported as a standalone script.');
    if Spec.Description <> '' then L.Add('# ' + CommentText(Spec.Description));
    L.Add('#');
    L.Add('# Generated by PasClaw ' + FormatVersion + ' (pasclaw workflow export ' + CommentText(Spec.Id) +
          ' --lang python). It runs the steps in');
    L.Add('# dependency order with the same templates, selectors, loop and outputs as a run in PasClaw.');
    L.Add('#');
    L.Add('# Requirements: Python 3.9+, standard library only.');
    if HasMCPLib then
      L.Add('#   MCP steps also need the official MCP SDK:  pip install mcp');
    L.Add('#');
    L.Add('# Environment variables (no key or token is written into this file):');
    if R.UsesLLM then
    begin
      Base := '';
      for i := 0 to High(R.Providers) do
        if (R.Providers[i].Name = DefProv) or (Base = '') then Base := R.Providers[i].BaseURL;
      if Base = '' then Base := 'https://api.openai.com';
      L.Add('#   LLM_BASE_URL     OpenAI-compatible endpoint for llm steps; /v1/chat/completions is');
      L.Add('#                    appended (default: each provider''s api_base below, else ' + CommentText(Base) + ')');
      L.Add('#   LLM_MODEL        model for every llm step (default: the step''s model, else the provider''s)');
      for i := 0 to High(R.Providers) do
        L.Add(Format('#   %-16s API key for provider "%s" (else LLM_API_KEY, else OPENAI_API_KEY)',
          [EnvName(R.Providers[i].Name) + '_API_KEY', CommentText(R.Providers[i].Name)]));
    end;
    if R.UsesReplicate then
    begin
      L.Add('#   REPLICATE_API_TOKEN  Replicate API token for replicate steps');
      L.Add('#   REPLICATE_API_BASE   (optional) default https://api.replicate.com');
    end;
    for i := 0 to High(R.MCP) do
      if R.MCP[i].SugarOnly then
        Continue
      else if R.MCP[i].Url <> '' then
        L.Add(Format('#   %-16s (optional) Authorization header value for the MCP server "%s"',
          ['MCP_' + EnvName(R.MCP[i].Name) + '_AUTH', CommentText(R.MCP[i].Name)]))
      else if Length(R.MCP[i].EnvNames) > 0 then
      begin
        S := '';
        for k := 0 to High(R.MCP[i].EnvNames) do
        begin
          if S <> '' then S := S + ', ';
          S := S + R.MCP[i].EnvNames[k];
        end;
        L.Add('#   ' + CommentText(S) + '  -- set for the MCP server "' + CommentText(R.MCP[i].Name) +
              '" (it inherits this environment)');
      end;
    if not (R.UsesLLM or R.UsesReplicate or HasMCPLib) then
      L.Add('#   (none)');
    L.Add('#');
    L.Add('# Steps:');
    for i := 0 to High(Spec.Nodes) do
      L.Add(Format('#   %d. %s: %s', [i + 1, CommentText(Spec.Nodes[i].Id), CommentText(Spec.Nodes[i].Tool)]));
    if Spec.Loop.Enabled then
      L.Add(Format('#   Repeats up to %d times.', [Spec.Loop.MaxIterations]));
    if Length(R.Tools) > 0 then
    begin
      L.Add('#');
      L.Add('# Built-in tools supported here: read_file, write_file, shell_exec (paths and commands run');
      L.Add('# relative to the current directory). Any other built-in tool fails its step with');
      L.Add('# "not supported in the exported script".');
    end;
    L.Add('#');
    S := '';
    for i := 0 to High(Spec.Inputs) do
      S := S + ' --input ' + Spec.Inputs[i].Name + '=...';
    L.Add('# Usage: python3 ' + ExportBaseName(Spec.Id) + '.py' + CommentText(S) + ' [--json]');
    L.Add('');
    L.Add('WORKFLOW = {');
    L.Add('    "id": ' + PythonStringLiteral(Spec.Id) + ',');
    L.Add('    "name": ' + PythonStringLiteral(Spec.Name) + ',');
    L.Add('    "description": ' + PythonStringLiteral(Spec.Description) + ',');
    L.Add('    "output_dir": ' + PythonStringLiteral(Spec.OutputDir) + ',');
    L.Add('    "inputs": [');
    for i := 0 to High(Spec.Inputs) do
      L.Add('        {"name": ' + PythonStringLiteral(Spec.Inputs[i].Name) +
            ', "type": ' + PythonStringLiteral(Spec.Inputs[i].InputType) +
            ', "required": ' + PyBool(Spec.Inputs[i].Required) + '},');
    L.Add('    ],');
    L.Add('    "outputs": [');
    for i := 0 to High(Spec.Outputs) do
      L.Add('        {"name": ' + PythonStringLiteral(Spec.Outputs[i].Name) +
            ', "value": ' + PythonStringLiteral(Spec.Outputs[i].ValueTemplate) +
            ', "type": ' + PythonStringLiteral(Spec.Outputs[i].OutputType) + '},');
    L.Add('    ],');
    L.Add('    "nodes": [');
    for i := 0 to High(Spec.Nodes) do
    begin
      L.Add('        {"id": ' + PythonStringLiteral(Spec.Nodes[i].Id) +
            ', "tool": ' + PythonStringLiteral(Spec.Nodes[i].Tool) + ',');
      L.Add('         "args": ' + PythonStringLiteral(Spec.Nodes[i].ArgsJSON) + ',');
      A := Spec.Nodes[i].Await;
      if A.Enabled then
        L.Add('         "await": {"tool": ' + PythonStringLiteral(A.PollTool) +
              ', "args": ' + PythonStringLiteral(A.PollArgsJSON) +
              ', "status_selector": ' + PythonStringLiteral(A.StatusSelector) +
              ', "output_selector": ' + PythonStringLiteral(A.OutputSelector) +
              ', "interval_ms": ' + IntToStr(A.IntervalMs) +
              ', "timeout_ms": ' + IntToStr(A.TimeoutMs) +
              ', "success": ' + PyList(A.Success) +
              ', "failure": ' + PyList(A.Failure) + '}},')
      else
        L.Add('         "await": None},');
    end;
    L.Add('    ],');
    L.Add('    "edges": [');
    for i := 0 to High(Spec.Edges) do
      L.Add('        {"from": ' + PythonStringLiteral(Spec.Edges[i].FromId) +
            ', "to": ' + PythonStringLiteral(Spec.Edges[i].ToId) + '},');
    L.Add('    ],');
    if Spec.Loop.Enabled then
    begin
      L.Add('    "loop": {"max": ' + IntToStr(Spec.Loop.MaxIterations) +
            ', "until": ' + PythonStringLiteral(Spec.Loop.UntilTemplate) + ', "feedback": [');
      for i := 0 to High(Spec.Loop.Feedback) do
        L.Add('        {"output": ' + PythonStringLiteral(Spec.Loop.Feedback[i].OutputName) +
              ', "input": ' + PythonStringLiteral(Spec.Loop.Feedback[i].InputName) + '},');
      L.Add('    ]},');
    end
    else
      L.Add('    "loop": None,');
    L.Add('}');
    L.Add('');
    L.Add('# Providers the llm steps use: endpoint and default model from the PasClaw config');
    L.Add('# this was exported from. Keys come from the environment (key_env), never from here.');
    L.Add('DEFAULT_PROVIDER = ' + PythonStringLiteral(DefProv));
    L.Add('DEFAULT_MODEL = ' + PythonStringLiteral(DefModel));
    L.Add('PROVIDERS = {');
    for i := 0 to High(R.Providers) do
      L.Add('    ' + PythonStringLiteral(R.Providers[i].Name) + ': {"base_url": ' +
            PythonStringLiteral(R.Providers[i].BaseURL) + ', "model": ' +
            PythonStringLiteral(R.Providers[i].Model) + ', "key_env": ' +
            PythonStringLiteral(EnvName(R.Providers[i].Name) + '_API_KEY') + '},');
    L.Add('}');
    L.Add('');
    L.Add('# MCP servers the steps call, as configured when this was exported: stdio servers by');
    L.Add('# command and args (they inherit this environment), HTTP servers by URL (auth from');
    L.Add('# auth_env). No env value or header is written here.');
    L.Add('MCP_SERVERS = {');
    for i := 0 to High(R.MCP) do
      if R.MCP[i].SugarOnly then
        Continue
      else if R.MCP[i].Url <> '' then
        L.Add('    ' + PythonStringLiteral(R.MCP[i].Name) + ': {"url": ' + PythonStringLiteral(R.MCP[i].Url) +
              ', "auth_env": ' + PythonStringLiteral('MCP_' + EnvName(R.MCP[i].Name) + '_AUTH') + '},')
      else if R.MCP[i].Command <> '' then
        L.Add('    ' + PythonStringLiteral(R.MCP[i].Name) + ': {"command": ' +
              PythonStringLiteral(R.MCP[i].Command) + ', "args": ' + PyList(R.MCP[i].Args) + '},')
      else
        L.Add('    # ' + CommentText(R.MCP[i].Name) + ': not configured where this was exported -- add its ' +
              '"command"/"args" or "url" here');
    L.Add('}');
    L.Add('');
    L.Add('');
    AddPythonRuntime(L);
    Result := L.Text;
  finally
    L.Free;
  end;
end;

{ ---------- Object Pascal ---------- }

function ExportWorkflowPascal(const Spec: TWorkflowSpec): string;
const
  CHUNK = 96;
var
  L: TStringList;
  Bare: TWorkflowSpec;
  Json, Base, S: string;
  i: Integer;
begin
  Bare := Spec;
  Bare.UiJSON := '';           { the editor's layout: nothing to run }
  Json := AsciiJSON(WorkflowToJSON(Bare));
  Base := ExportBaseName(Spec.Id);
  L := TStringList.Create;
  try
    L.Add('(*');
    L.Add('  ' + Base + '.dpr -- the PasClaw workflow "' + CommentText(Spec.Name) +
          '", exported as an Object Pascal program.');
    if Spec.Description <> '' then L.Add('  ' + CommentText(Spec.Description));
    L.Add('');
    L.Add('  Generated by PasClaw ' + FormatVersion + ' (pasclaw workflow export ' + CommentText(Spec.Id) +
          ' --lang pascal).');
    L.Add('  It embeds the workflow and runs it with PasClaw''s own engine and units, so it');
    L.Add('  behaves like a run in PasClaw: the same templates, loops and outputs, every step');
    L.Add('  through the same permission rules, and the providers and MCP servers from your');
    L.Add('  PasClaw config ($PASCLAW_HOME/config.json). No key is written into this file.');
    L.Add('');
    L.Add('  Build it from a PasClaw source checkout (FPC 3.2+), after `make`:');
    L.Add('    fpc -MDelphi -Sh -Fubuild/lib -FEbuild ' + Base + '.dpr');
    L.Add('  or straight from the sources, without make:');
    L.Add('    mkdir -p /tmp/wf-units && fpc -MDelphi -Sh -Fusrc/pkg/* -Fusrc/pkg/memory/localvector \');
    L.Add('      -Fusrc/pkg/vendor/zpaq -Fuvendor/Indy/Lib/* -Fivendor/Indy/Lib/* \');
    L.Add('      -Fu/usr/lib/lazarus/3.0/components/lazutils -FU/tmp/wf-units -FEbuild ' + Base + '.dpr');
    L.Add('  Delphi: add the same source folders to the project''s search path.');
    L.Add('');
    L.Add('  Run:');
    S := '';
    for i := 0 to High(Spec.Inputs) do
      S := S + ' --input ' + Spec.Inputs[i].Name + '=...';
    L.Add('    build/' + Base + CommentText(S) + ' [--json]');
    L.Add('    build/' + Base + ' --help        (lists the inputs)');
    L.Add('*)');
    L.Add('program ' + Base + ';');
    L.Add('');
    L.Add('{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}');
    L.Add('{$H+}');
    L.Add('{$APPTYPE CONSOLE}');
    L.Add('');
    L.Add('uses');
    L.Add('  {$IFDEF FPC}{$IFDEF UNIX}');
    L.Add('  cthreads,');
    L.Add('  cmem,');
    L.Add('  {$ENDIF}{$ENDIF}');
    L.Add('  PasClaw.Workflow.Standalone;');
    L.Add('');
    L.Add('{ The workflow, as PasClaw saved it (JSON; non-ASCII as \u escapes). }');
    L.Add('function WorkflowSpec: string;');
    L.Add('begin');
    L.Add('  Result := '''';');
    i := 1;
    while i <= Length(Json) do
    begin
      L.Add('  Result := Result + ' + PascalStringLiteral(Copy(Json, i, CHUNK)) + ';');
      Inc(i, CHUNK);
    end;
    L.Add('end;');
    L.Add('');
    L.Add('begin');
    L.Add('  Halt(RunStandaloneWorkflow(WorkflowSpec));');
    L.Add('end.');
    Result := L.Text;
  finally
    L.Free;
  end;
end;

function ExportWorkflowAs(const Spec: TWorkflowSpec; const Lang: string; Cfg: TConfig;
  out Text, FileName, Err: string): Boolean;
var
  L: string;
begin
  Result := False;
  Text := '';
  FileName := '';
  Err := '';
  L := LowerCase(Trim(Lang));
  if (L = 'python') or (L = 'py') then
  begin
    Text := ExportWorkflowPython(Spec, Cfg);
    FileName := ExportBaseName(Spec.Id) + '.py';
  end
  else if (L = 'pascal') or (L = 'dpr') or (L = 'delphi') then
  begin
    Text := ExportWorkflowPascal(Spec);
    FileName := ExportBaseName(Spec.Id) + '.dpr';
  end
  else if (L = 'workflow') or (L = 'json') then
  begin
    Text := ExportWorkflowFile(Spec, Cfg);
    FileName := Spec.Id + '.pasclaw-workflow.json';
  end
  else
  begin
    Err := Format('unknown export language "%s" (use python, pascal or workflow)', [Lang]);
    Exit;
  end;
  Result := True;
end;

end.
