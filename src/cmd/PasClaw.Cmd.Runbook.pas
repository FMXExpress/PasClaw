(*
  PasClaw.Cmd.Runbook -- `pasclaw runbook` command.

  Gives the model a clean way to self-configure on workspace setup:
  one short steering message plus a baked task instruction asks it to
  probe the project (`execute_code` for `ls`, `cat Makefile`, parse
  package.json, etc.) and write a starter ./AGENTS.md the operator can
  then commit. Subsequent runs of `pasclaw export agents` will overwrite
  ./AGENTS.md from PasClaw's curated state, so think of `runbook` as
  the one-shot bootstrap that produces the initial content -- not a
  refresh tool.

  We deliberately do NOT do the probing ourselves in Pascal. The model
  is already capable of running `ls -la`, grepping Makefile for
  targets, parsing package.json scripts, recognising a Cargo.toml,
  etc. Hardcoding "if Makefile then..." here would lock the runbook
  to a small set of project shapes and rot the moment a new ecosystem
  shows up. The whole point of pairing this with execute_code is that
  the model writes the probe script in-loop.

  Refusing to clobber an existing AGENTS.md is a safety net: an
  operator who already has a curated runbook shouldn't lose it to a
  re-run. `--force` is the explicit opt-in to overwrite.
*)
unit PasClaw.Cmd.Runbook;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function Cmd_Runbook_Run(const Argv: array of string): Integer;

implementation

uses
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Cmd.Agent;

procedure Help;
begin
  PrintLn('Usage: pasclaw runbook [options]');
  PrintLn('  Ask the model to probe the current project and write a starter');
  PrintLn('  ./AGENTS.md (covering build / test / conventions / gotchas).');
  PrintLn('');
  PrintLn('  Uses the execute_code tool for the probe, then writes the file');
  PrintLn('  via fs_write. The agent loop runs to completion (one-shot, no');
  PrintLn('  interactive prompt); on a typical small project this is one or');
  PrintLn('  two iterations.');
  PrintLn('');
  PrintLn('Options:');
  PrintLn('  --force        Overwrite ./AGENTS.md if it already exists');
  PrintLn('  --to <file>    Target a different filename (default: AGENTS.md)');
  PrintLn('  -h, --help     Show this help');
end;

function RunbookSteeringMessage(const TargetFile: string): string;
{ The model-facing instruction. Kept terse on purpose -- the model
  already knows what AGENTS.md is for and how to use its tools, so we
  set the goal, list the probe directions, and stay out of the way.
  Mentions execute_code by name so the model knows it has a multi-line
  script tool available rather than reaching for shell_exec and
  paying the per-command quoting tax.

  When tuning the content of the generated file, prefer to edit this
  message rather than wrapping the agent output -- the model knows
  how to write markdown, and "wrap with header + footer" leaks PasClaw
  internals into the file. }
begin
  Result :=
    'Generate a starter ' + TargetFile + ' file at the repository root. ' +
    sLineBreak +
    sLineBreak +
    'Steps:' + sLineBreak +
    '1. Use `execute_code` (bash) to probe the project: top-level layout, ' +
       'build / test commands inferred from Makefile / package.json / ' +
       'Cargo.toml / go.mod / pyproject.toml etc., language conventions ' +
       'visible from .editorconfig / .prettierrc / linter configs, and ' +
       'the recent git history shape (`git log --oneline -10` and ' +
       '`git status`).' + sLineBreak +
    '2. Use `read_file` on any small config / docs file you want to quote ' +
       'verbatim.' + sLineBreak +
    '3. Write a single ' + TargetFile + ' covering these sections, in ' +
       'this order, with a single one-line description per item ' +
       '(this is a runbook, not a README):' + sLineBreak +
    '   - Project overview (1-2 sentences: what is this, what language)' + sLineBreak +
    '   - How to build (the actual command, plus any non-obvious flags)' + sLineBreak +
    '   - How to test (the actual command)' + sLineBreak +
    '   - How to run / launch the app or tool (only if applicable)' + sLineBreak +
    '   - Repository layout (top-level directories with a one-line ' +
       'purpose each)' + sLineBreak +
    '   - Conventions worth knowing (commit style, branch naming, lint ' +
       'rules -- only what you can actually see, do not invent)' + sLineBreak +
    '   - Gotchas (the "I would have lost an hour without this" notes -- ' +
       'omit the section if you find nothing)' + sLineBreak +
    sLineBreak +
    'Use `write_file` to create the file. Do NOT use ' +
    '`pasclaw export` or any related tool -- this is a one-shot bootstrap, ' +
    'not a refresh.' + sLineBreak +
    sLineBreak +
    'Be concise. The goal is a runbook a teammate could scan in 30 ' +
    'seconds and use immediately. When done, print a one-line summary ' +
    'of what you wrote and exit.';
end;

function Cmd_Runbook_Run(const Argv: array of string): Integer;
var
  Force:      Boolean;
  TargetFile: string;
  i:          Integer;
  AgentArgv:  array of string;
begin
  Force      := False;
  TargetFile := 'AGENTS.md';
  i := 0;
  while i <= High(Argv) do
  begin
    if (Argv[i] = '-h') or (Argv[i] = '--help') then
    begin
      Help;
      Exit(0);
    end;
    if Argv[i] = '--force' then
    begin
      Force := True;
      Inc(i);
      Continue;
    end;
    if (Argv[i] = '--to') and (i < High(Argv)) then
    begin
      TargetFile := Argv[i + 1];
      Inc(i, 2);
      Continue;
    end;
    PrintLnErr(Ansi.Red + 'unknown runbook argument: ' + Argv[i] + Ansi.Reset);
    Exit(1);
  end;

  { Safety net: an operator with a curated AGENTS.md shouldn't lose
    it to a re-run. The model will write through fs_write which has
    its own overwrite semantics, but we want the refusal to surface
    here (with a CLI-level message) rather than as a vague tool
    failure inside the agent loop. }
  if FileExists(TargetFile) and (not Force) then
  begin
    PrintLnErr(Ansi.Yellow +
               TargetFile + ' already exists.' + Ansi.Reset);
    PrintLn('Pass --force to let the model overwrite it, or move the existing');
    PrintLn('file aside if you want to keep both.');
    Exit(1);
  end;

  PrintLn(Ansi.Dim +
          'asking the agent to probe the project and write ' + TargetFile + '...' +
          Ansi.Reset);

  { Hand off to the regular agent one-shot path. We rely on the
    default tool registry (shell_exec, execute_code, fs_*, etc.) and
    the default system prompt; the steering message carries the
    runbook intent. A dedicated --system-prompt would just be
    duplicating instructions the model already has via the standard
    PasClaw prompt. }
  SetLength(AgentArgv, 2);
  AgentArgv[0] := '-m';
  AgentArgv[1] := RunbookSteeringMessage(TargetFile);
  Result := Cmd_Agent_Run(AgentArgv);
end;

end.
