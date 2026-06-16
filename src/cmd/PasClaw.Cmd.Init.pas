unit PasClaw.Cmd.Init;
(*
  PasClaw.Cmd.Init - generate a starter AGENTS.md for the current
  project by walking the working directory in-Pascal and asking the
  configured model to summarise it in one shot.

  AGENTS.md is the cross-tool convention for project-level agent rules
  (read by opencode, Codex, Cursor, Zed AI, Claude Code as a fallback,
  and PasClaw itself via PasClaw.Agent.Prompt BuildProjectRulesSection).

  Two ways to bootstrap AGENTS.md from PasClaw:

    pasclaw init      -- this command. Pascal walks the file tree and
                         reads a handful of well-known config files;
                         the digest goes to the model in a single
                         Chat() call; the response is written to
                         AGENTS.md. No tool loop, no shell exec, no
                         workspace mutations beyond the one file.
                         Fast and trust-minimal.

    pasclaw runbook   -- the older, deeper variant. Spins the agent
                         loop with execute_code so the MODEL probes
                         the project (running `ls`, `cat Makefile`,
                         `git log`, etc.) and writes the file via
                         fs_write. Produces richer output but requires
                         shell exec to be allowed and takes longer.

  Usage:
    pasclaw init [<path>] [--force] [--model <name>] [--provider <name>]

  Defaults: path = current directory; model = Cfg.DefaultModel;
  provider = Cfg.DefaultProvider. Refuses to overwrite an existing
  AGENTS.md unless --force.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

function Cmd_Init_Run(const Argv: array of string): Integer;

{ Build the project digest (file tree + key-file snippets) that the
  model receives as the user message. Exposed for the /init slash
  command in the TUI and for unit tests that pin the digest shape.
  Bytes are capped so a giant repo doesn't blow the prompt window. }
function BuildProjectDigest(const RootDir: string): string;

{ Strip a leading ```...``` markdown fence if the model wrapped its
  output in one. Some models love to do this even after being asked
  not to. Idempotent / safe on bare text. Exposed for tests. }
function UnfenceMarkdown(const S: string): string;

implementation

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Factory;

const
  { File-tree depth: shallow enough to fit in the prompt for a typical
    repo (a few hundred entries), deep enough to surface package
    structure. opencode picks 3; we match it. }
  TreeMaxDepth    = 3;
  TreeMaxEntries  = 400;

  { Per-key-file snippet: enough head bytes to identify build tooling
    and the project's purpose without dragging the whole file in. }
  SnippetMaxBytes = 4 * 1024;

  { Total digest cap. Generous (most projects fit easily); keeps the
    prompt under ~64 KB even for big monorepos. }
  DigestMaxBytes  = 48 * 1024;

  { Files we always read a snippet of when present. Order matters --
    earliest wins the budget. README first so the model has narrative
    context before it sees build config. }
  KeyFiles: array[0..14] of string = (
    'README.md', 'README', 'README.txt', 'README.rst',
    'package.json', 'pyproject.toml', 'Cargo.toml', 'go.mod',
    'pom.xml', 'build.gradle', 'CMakeLists.txt', 'Makefile',
    'Gemfile', 'composer.json', 'pubspec.yaml'
  );

  { Directory names skipped when walking the tree -- noise that would
    drown out signal (build caches, dependency stashes, VCS metadata).
    Lowercased compares. }
  SkipDirs: array[0..14] of string = (
    '.git', '.hg', '.svn', 'node_modules', 'vendor', 'target',
    'build', 'dist', '.venv', 'venv', '__pycache__',
    '.idea', '.vscode', '.gradle', '.mvn'
  );

function IsSkipDir(const Name: string): Boolean;
var
  i: Integer;
  L: string;
begin
  L := LowerCase(Name);
  for i := Low(SkipDirs) to High(SkipDirs) do
    if L = SkipDirs[i] then Exit(True);
  Result := False;
end;

procedure WalkDir(const Root, RelDir: string; Depth: Integer;
                  Lines: TStringList; var Count: Integer);
var
  Sr: TSearchRec;
  Sub: string;
  Indent: string;
  i: Integer;
begin
  if Depth > TreeMaxDepth then Exit;
  if Count >= TreeMaxEntries then Exit;
  Indent := '';
  for i := 0 to Depth - 1 do Indent := Indent + '  ';

  if FindFirst(JoinPath(JoinPath(Root, RelDir), '*'), faAnyFile, Sr) = 0 then
  try
    repeat
      if Count >= TreeMaxEntries then Break;
      if (Sr.Name = '.') or (Sr.Name = '..') then Continue;
      if (Sr.Attr and faDirectory) <> 0 then
      begin
        if IsSkipDir(Sr.Name) then Continue;
        Lines.Add(Indent + Sr.Name + '/');
        Inc(Count);
        if RelDir = '' then Sub := Sr.Name else Sub := JoinPath(RelDir, Sr.Name);
        WalkDir(Root, Sub, Depth + 1, Lines, Count);
      end
      else
      begin
        Lines.Add(Indent + Sr.Name);
        Inc(Count);
      end;
    until FindNext(Sr) <> 0;
  finally
    FindClose(Sr);
  end;
end;

function ReadHead(const Path: string; MaxBytes: Integer): string;
var
  FS: TFileStream;
  Buf: TBytes;
  N: Int64;
begin
  Result := '';
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      N := FS.Size;
      if N > MaxBytes then N := MaxBytes;
      if N <= 0 then Exit;
      SetLength(Buf, N);
      FS.ReadBuffer(Buf[0], N);
      SetLength(Result, N);
      Move(Buf[0], Result[1], N);
    finally
      FS.Free;
    end;
  except
    Result := '';
  end;
end;

function BuildProjectDigest(const RootDir: string): string;
var
  Tree: TStringList;
  Count, i, Truncated: Integer;
  KeyPath, Snippet, Ext: string;
  Out_: TStringBuilder;
begin
  Out_ := TStringBuilder.Create;
  Tree := TStringList.Create;
  try
    Out_.Append('# Project root: ').Append(RootDir).Append(sLineBreak);
    Out_.Append(sLineBreak);

    Out_.Append('## File tree (depth=').Append(TreeMaxDepth)
        .Append(', max ').Append(TreeMaxEntries).Append(' entries)' + sLineBreak);
    Out_.Append('```').Append(sLineBreak);
    Count := 0;
    WalkDir(RootDir, '', 0, Tree, Count);
    for i := 0 to Tree.Count - 1 do
    begin
      if Out_.Length >= DigestMaxBytes then Break;
      Out_.Append(Tree[i]).Append(sLineBreak);
    end;
    if Count >= TreeMaxEntries then
      Out_.Append('(... entry cap reached, list truncated ...)').Append(sLineBreak);
    Out_.Append('```').Append(sLineBreak).Append(sLineBreak);

    Out_.Append('## Key files (first ').Append(SnippetMaxBytes)
        .Append(' bytes each)' + sLineBreak).Append(sLineBreak);
    for i := Low(KeyFiles) to High(KeyFiles) do
    begin
      if Out_.Length >= DigestMaxBytes then Break;
      KeyPath := JoinPath(RootDir, KeyFiles[i]);
      if not FileExists(KeyPath) then Continue;
      Snippet := ReadHead(KeyPath, SnippetMaxBytes);
      if Trim(Snippet) = '' then Continue;
      Ext := LowerCase(ExtractFileExt(KeyFiles[i]));
      if Ext = '' then Ext := 'txt' else Delete(Ext, 1, 1);
      Out_.Append('### ').Append(KeyFiles[i]).Append(sLineBreak);
      Out_.Append('```').Append(Ext).Append(sLineBreak);
      Out_.Append(Snippet).Append(sLineBreak);
      Out_.Append('```').Append(sLineBreak).Append(sLineBreak);
    end;

    Result := Out_.ToString;
    if Length(Result) > DigestMaxBytes then
    begin
      Truncated := Length(Result) - DigestMaxBytes;
      SetLength(Result, DigestMaxBytes);
      Result := Result + sLineBreak + sLineBreak +
                Format('(... %d byte(s) elided to fit prompt budget ...)',
                       [Truncated]);
    end;
  finally
    Tree.Free;
    Out_.Free;
  end;
end;

function UnfenceMarkdown(const S: string): string;
var
  Trimmed, Lower: string;
  FirstLineEnd, LastFenceStart: Integer;
begin
  Result := S;
  Trimmed := Trim(Result);
  if (Length(Trimmed) < 6) or (Copy(Trimmed, 1, 3) <> '```') then Exit;

  { Drop the first line (the opening fence, possibly with a language tag). }
  FirstLineEnd := Pos(#10, Trimmed);
  if FirstLineEnd = 0 then Exit;
  Trimmed := Copy(Trimmed, FirstLineEnd + 1, MaxInt);

  { Drop the closing fence if present. Search from the end so embedded
    fences in the body don't trip the strip. }
  Lower := Trimmed;
  LastFenceStart := 0;
  while True do
  begin
    FirstLineEnd := Pos('```', Lower);
    if FirstLineEnd = 0 then Break;
    LastFenceStart := LastFenceStart + FirstLineEnd;
    Lower := Copy(Lower, FirstLineEnd + 3, MaxInt);
  end;
  if LastFenceStart > 0 then
    Trimmed := Copy(Trimmed, 1, LastFenceStart - 1);

  Result := Trim(Trimmed);
end;

const
  InitSystemPrompt =
    'You are generating a starter AGENTS.md file for a software project. ' +
    'AGENTS.md is the cross-tool convention (opencode, Codex, Cursor, Zed AI, ' +
    'Claude Code) for per-project agent rules.' + sLineBreak + sLineBreak +
    'Output a single markdown document, ready to commit. Include these sections, ' +
    'in this order, omitting any you genuinely cannot infer from the digest:' + sLineBreak +
    sLineBreak +
    '  # <Project Name>' + sLineBreak +
    '  One-paragraph project description.' + sLineBreak + sLineBreak +
    '  ## Build, run, test' + sLineBreak +
    '  The exact commands a contributor would run.' + sLineBreak + sLineBreak +
    '  ## Code style' + sLineBreak +
    '  Language, formatter, linter, naming conventions if discoverable.' + sLineBreak + sLineBreak +
    '  ## Key directories' + sLineBreak +
    '  One line per important top-level dir.' + sLineBreak + sLineBreak +
    '  ## Common tasks' + sLineBreak +
    '  Short bullet list of "to add X, do Y" entries inferrable from the layout.' + sLineBreak + sLineBreak +
    '  ## Gotchas' + sLineBreak +
    '  Anything a fresh contributor would trip over.' + sLineBreak + sLineBreak +
    'Rules:' + sLineBreak +
    ' - Output ONLY the markdown body. No preamble, no code fence around the whole thing, no commentary.' + sLineBreak +
    ' - Do not invent facts. If something is not discoverable from the digest, leave the section out.' + sLineBreak +
    ' - Be concise. The target reader is another AI agent + a human reviewer; both want signal, not prose.';

function ParseArgs(const Argv: array of string;
                   out Path: string; out Force: Boolean;
                   out ModelArg, ProviderArg: string;
                   out ErrMsg: string): Boolean;
var
  i: Integer;
  Token: string;
begin
  Path        := '';
  Force       := False;
  ModelArg    := '';
  ProviderArg := '';
  ErrMsg      := '';
  i := Low(Argv);
  while i <= High(Argv) do
  begin
    Token := Argv[i];
    if (Token = '-h') or (Token = '--help') then
    begin
      ErrMsg := '__help__';
      Exit(False);
    end
    else if Token = '--force' then Force := True
    else if Token = '--model' then
    begin
      if i = High(Argv) then begin ErrMsg := '--model needs a value'; Exit(False); end;
      Inc(i); ModelArg := Argv[i];
    end
    else if Token = '--provider' then
    begin
      if i = High(Argv) then begin ErrMsg := '--provider needs a value'; Exit(False); end;
      Inc(i); ProviderArg := Argv[i];
    end
    else if (Length(Token) > 0) and (Token[1] = '-') then
    begin
      ErrMsg := 'unknown flag: ' + Token;
      Exit(False);
    end
    else if Path = '' then Path := Token
    else
    begin
      ErrMsg := 'unexpected positional argument: ' + Token;
      Exit(False);
    end;
    Inc(i);
  end;
  Result := True;
end;

procedure ShowHelp;
begin
  PrintLn('Usage: pasclaw init [<path>] [--force] [--model <name>] [--provider <name>]');
  PrintLn;
  PrintLn('Generate a starter AGENTS.md for the project at <path> (default: cwd).');
  PrintLn('AGENTS.md is the cross-tool convention (opencode, Codex, Cursor, Zed AI,');
  PrintLn('Claude Code) for project-level agent rules; PasClaw itself reads it into');
  PrintLn('the system prompt at session start.');
  PrintLn;
  PrintLn('Flags:');
  PrintLn('  --force          Overwrite an existing AGENTS.md');
  PrintLn('  --model <name>   Override the configured default model');
  PrintLn('  --provider <n>   Override the configured default provider');
  PrintLn('  -h, --help       Show this help');
end;

function Cmd_Init_Run(const Argv: array of string): Integer;
var
  Cfg: TConfig;
  Provider: ILLMProvider;
  Path, ModelArg, ProviderArg, ErrMsg, Target, Digest, ModelName: string;
  ProviderName: string;
  Force: Boolean;
  Messages: array of TMessage;
  EmptyTools: array of TToolDefinition;
  Opts: TChatOptions;
  Resp: TLLMResponse;
  Body: string;
  FS: TFileStream;
begin
  if not ParseArgs(Argv, Path, Force, ModelArg, ProviderArg, ErrMsg) then
  begin
    if ErrMsg = '__help__' then
    begin
      ShowHelp;
      Exit(0);
    end;
    PrintErr('init: ' + ErrMsg);
    Exit(2);
  end;

  if Path = '' then Path := GetCurrentDir;
  Path := ExpandFileName(Path);
  if not DirectoryExists(Path) then
  begin
    PrintErr('init: directory does not exist: ' + Path);
    Exit(2);
  end;

  Target := JoinPath(Path, 'AGENTS.md');
  if FileExists(Target) and (not Force) then
  begin
    PrintErr('init: ' + Target + ' already exists -- pass --force to overwrite');
    Exit(1);
  end;

  Cfg := LoadConfig;
  try
    if ProviderArg <> '' then ProviderName := ProviderArg
    else ProviderName := Cfg.DefaultProvider;
    if not NewProviderFromConfig(Cfg, ProviderName, Provider, ErrMsg) then
    begin
      PrintErr('init: provider "' + ProviderName + '" unavailable: ' + ErrMsg);
      Exit(1);
    end;

    if ModelArg <> '' then ModelName := ModelArg
    else ModelName := Cfg.DefaultModel;
    if Trim(ModelName) = '' then ModelName := Provider.GetDefaultModel;

    PrintLn(Ansi.Dim + 'scanning ' + Path + ' ...' + Ansi.Reset);
    Digest := BuildProjectDigest(Path);

    Opts := Default(TChatOptions);
    Opts.SystemPrompt := InitSystemPrompt;
    Opts.MaxTokens    := 4096;

    SetLength(Messages, 1);
    Messages[0] := MakeMessage(mrUser,
      'Generate AGENTS.md for the following project digest.' + sLineBreak +
      sLineBreak + Digest);
    SetLength(EmptyTools, 0);

    PrintLn(Ansi.Dim + 'asking ' + Provider.GetName + '/' + ModelName +
            ' for a starter AGENTS.md ...' + Ansi.Reset);
    try
      Resp := Provider.Chat(Messages, EmptyTools, ModelName, Opts);
    except
      on E: Exception do
      begin
        PrintErr('init: provider call failed: ' + E.Message);
        Exit(1);
      end;
    end;

    if (Resp.StatusCode >= 400) or (Trim(Resp.Content) = '') then
    begin
      PrintErr(Format('init: provider returned status=%d, content=%d bytes',
                      [Resp.StatusCode, Length(Resp.Content)]));
      Exit(1);
    end;

    Body := UnfenceMarkdown(Resp.Content);

    try
      FS := TFileStream.Create(Target, fmCreate);
      try
        if Body <> '' then
          FS.WriteBuffer(Body[1], Length(Body));
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        PrintErr('init: write failed: ' + E.Message);
        Exit(1);
      end;
    end;

    PrintLn(Ansi.Green + 'wrote ' + Target + ' (' + IntToStr(Length(Body)) +
            ' bytes)' + Ansi.Reset);
    PrintLn(Ansi.Dim + 'review and commit it; PasClaw will load it as ' +
            'authoritative project rules on the next session.' + Ansi.Reset);
    Result := 0;
  finally
    Cfg.Free;
  end;
end;

end.
