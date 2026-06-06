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

                                      Excluded on Delphi's Linux64 target —
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

var
  ExitCode_: Integer;
begin
  { Detect color support before any output so the banner respects NO_COLOR. }
  CliUI_Init(EarlyColorDisabled);

  PrintBanner;
  ApplyTimezoneFromEnv;

  ExitCode_ := RunRootCommand;
  if ExitCode_ <> 0 then
    Halt(ExitCode_);
end.
