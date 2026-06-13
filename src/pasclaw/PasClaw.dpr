{
  PasClaw - Ultra-lightweight personal AI agent (Delphi Object Pascal port of picoclaw)
  Inspired by and based on picoclaw: https://github.com/sipeed/picoclaw
  License: MIT

  Copyright (c) 2026 PasClaw contributors

  Build with Free Pascal:
    fpc -Fusrc/pkg/... -FEbuild src/pasclaw/PasClaw.dpr
  Or use the project Makefile from the repo root:
    make
}

program PasClaw;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$APPTYPE CONSOLE}

uses
  {$IFDEF FPC}{$IFDEF UNIX}
  cthreads,            { FPC/Linux: pull in pthreads so Indy can use TThread }
  cmem,
  {$ENDIF}{$ENDIF}
  {$IFNDEF FPC}
  {$IFNDEF LINUX}
  FireDAC.Phys.SQLiteWrapper.Stat,  { Link sqlite3 statically into the exe so
                                      Delphi builds don't need to ship a
                                      sqlite3.dll alongside pasclaw.exe.
                                      Used by PasClaw.Memory.Index (FTS5).
                                      FPC links libsqlite3 dynamically.

                                      Excluded on Delphi's Linux64 target --
                                      RAD Studio ships the static SQLite
                                      wrapper for Windows / macOS / mobile
                                      only; FireDAC on Linux supports just
                                      the dynamic libsqlite3.so link path
                                      and including the static unit there
                                      breaks the compile.
                                      Codex P1 on PR #135. }
  {$ENDIF}
  {$ENDIF}
  SysUtils,
  PasClaw.CliUI,
  PasClaw.Logger,
  PasClaw.Config,
  PasClaw.Cmd.Root;

function IsStdioMCPInvocation: Boolean;
{ When invoked as `pasclaw mcp stdio`, stdout MUST stay clean JSON-RPC
  -- the host process pipes our stdout into its parser, and a banner
  on the first read would crash it. Same goes for the legacy
  __tool subprocess RPC. Skip the banner in those cases; the user
  on a real terminal still gets the full visual. }
var
  i: Integer;
  Cmd, Next: string;
begin
  Result := False;
  if ParamCount < 1 then Exit;
  Cmd := ParamStr(1);
  if Cmd = '__tool' then Exit(True);
  if Cmd <> 'mcp' then Exit;
  for i := 2 to ParamCount do
  begin
    Next := ParamStr(i);
    if (Next = '') or (Next[1] = '-') then Continue;
    Exit(Next = 'stdio');
  end;
end;

function IsQuietInvocation: Boolean;
{ Suppress the banner whenever the user passed --quiet or -q on the
  command line. The actual semantic suppression (tool decoration,
  token line, assistant header) lives inside Cmd.Agent's RunSingleTurn,
  but the banner is printed BEFORE arg parsing in this file, so we
  need an early scan here -- same shape IsStdioMCPInvocation uses
  for the mcp-stdio case. Flag form matches what Cmd.Agent.ParseArgs
  accepts, so users only have to type --quiet once. }
var
  i: Integer;
  Arg: string;
begin
  Result := False;
  for i := 1 to ParamCount do
  begin
    Arg := ParamStr(i);
    if (Arg = '--quiet') or (Arg = '-q') then Exit(True);
  end;
end;

var
  ExitCode_: Integer;
begin
  { Detect color support before any output so the banner respects NO_COLOR. }
  CliUI_Init(EarlyColorDisabled);

  if not (IsStdioMCPInvocation or IsQuietInvocation) then
    PrintBanner;
  if IsQuietInvocation then
    { --quiet / -q also clamps the logger to error level so the
      [info] / [debug] noise that LoadConfig + ConnectMCP +
      Search.Factory emit during agent startup ("web_search disabled",
      "mcp[<name>] cache hit", color-detect chatter, etc.) doesn't
      pollute the stdout pipeline scripts read. Real errors still
      reach stderr -- a quiet pipeline that silently swallows the
      reason it failed is worse than one that prints an extra
      [info] line. mcp-stdio mode handles its own logging upstream;
      we don't clamp there. }
    SetLogLevel(llError);
  ApplyTimezoneFromEnv;

  ExitCode_ := RunRootCommand;
  if ExitCode_ <> 0 then
    Halt(ExitCode_);
end.
