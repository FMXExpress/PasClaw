program banner_in_demo_app;
(*
  Drops the PASCLAW box-drawing banner into the same harness from the
  user's UTF8ConsoleDemo (the one that "just worked" on Windows). If
  the demo path renders the banner cleanly, the source-file encoding
  is the issue and PasClaw needs `{$CODEPAGE UTF8}` (FPC) plus the
  matching Delphi project setting / BOM. If the demo ALSO mojibakes,
  the source bytes themselves are wrong and we need a different fix.

  Build:
    fpc -MDelphi banner_in_demo_app.dpr
    dcc64 banner_in_demo_app.dpr        (Delphi)

  Output on a working console should show 6 contiguous lines of
  blocks/box-drawings spelling PASCLAW, no `Ã` / `â` glyphs anywhere.
*)

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

{$IFDEF FPC}
  { Same FPC source-codepage tag as PasClaw.CliUI.pas. Delphi's
    dcc64 does not have this directive and errors with
    E1030 "Invalid compiler directive: 'CODEPAGE'", so the IFDEF
    keeps it strictly FPC-side. Delphi reads source via its project
    setting / BOM. }
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

uses
  {$IFDEF MSWINDOWS}
  {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF},
  {$ENDIF}
  SysUtils,
  Classes;

procedure ConWrite(const S: string);
{$IFDEF MSWINDOWS}
var
  H: THandle;
  Mode: DWORD;
  Written: DWORD;
  Bytes: TBytes;
begin
  H := GetStdHandle(STD_OUTPUT_HANDLE);
  if H = INVALID_HANDLE_VALUE then Exit;
  if S = '' then Exit;
  if GetConsoleMode(H, Mode) then
    { Real console: send UTF-16 straight to the renderer. PWideChar(S)
      under Delphi widens UnicodeString trivially; under FPC it widens
      the AnsiString through its codepage tag (CP_UTF8 here, thanks to
      the directive above), which is exactly the conversion we want. }
    WriteConsoleW(H, PWideChar(string(S)), Length(S), Written, nil)
  else
  begin
    { Pipe / file: emit raw UTF-8 bytes. }
    Bytes := TEncoding.UTF8.GetBytes(S);
    if Length(Bytes) > 0 then
      WriteFile(H, Bytes[0], Length(Bytes), Written, nil);
  end;
end;
{$ELSE}
begin
  (* Linux / macOS: Write() ships the AnsiString's bytes directly.
     With the $CODEPAGE UTF8 tag on FPC, those bytes are valid UTF-8;
     every modern POSIX terminal honours UTF-8 by default. *)
  Write(Output, S);
end;
{$ENDIF}

procedure ConWriteLn(const S: string = '');
begin
  ConWrite(S);
  ConWrite(sLineBreak);
end;

procedure InitConsoleForUTF8;
begin
  {$IFDEF MSWINDOWS}
  SetConsoleOutputCP(CP_UTF8);
  SetConsoleCP(CP_UTF8);
  {$ENDIF}
end;

procedure PrintBanner;
const
  { Bytes are exact UTF-8 for U+2588 (FULL BLOCK), U+2554 / U+2557 /
    U+255A / U+255D (BOX DRAWINGS DOUBLE CORNERS), U+2550 (DOUBLE
    HORIZONTAL), U+2551 (DOUBLE VERTICAL). Copy-pasted verbatim from
    PasClaw.CliUI.PrintBanner. }
  L1 = '██████╗  █████╗ ███████╗ ██████╗██╗      █████╗ ██╗    ██╗';
  L2 = '██╔══██╗██╔══██╗██╔════╝██╔════╝██║     ██╔══██╗██║    ██║';
  L3 = '██████╔╝███████║███████╗██║     ██║     ███████║██║ █╗ ██║';
  L4 = '██╔═══╝ ██╔══██║╚════██║██║     ██║     ██╔══██║██║███╗██║';
  L5 = '██║     ██║  ██║███████║╚██████╗███████╗██║  ██║╚███╔███╔╝';
  L6 = '╚═╝     ╚═╝  ╚═╝╚══════╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ';
begin
  ConWriteLn;
  ConWriteLn(L1);
  ConWriteLn(L2);
  ConWriteLn(L3);
  ConWriteLn(L4);
  ConWriteLn(L5);
  ConWriteLn(L6);
  ConWriteLn;
end;

procedure RoundTripSelfTest;
(*
  Same in-memory self-test as the demo. Confirms the string handling
  is intact regardless of what the terminal renders. PASS means the
  bytes are correct and any visible weirdness is the terminal / font.
*)
const
  S0 = '██████╗';
  S1 = '╔═════╗';
var
  RT0, RT1: string;
  OK: Boolean;
begin
  RT0 := TEncoding.UTF8.GetString(TEncoding.UTF8.GetBytes(S0));
  RT1 := TEncoding.UTF8.GetString(TEncoding.UTF8.GetBytes(S1));
  OK := (RT0 = S0) and (RT1 = S1);
  ConWriteLn;
  if OK then
    ConWriteLn('Round-trip self-test: PASS  (bytes intact in memory)')
  else
    ConWriteLn('Round-trip self-test: FAIL  (string handling is broken)');
end;

begin
  try
    InitConsoleForUTF8;
    PrintBanner;
    RoundTripSelfTest;
    ConWriteLn;
    ConWriteLn('Done. If the blocks above look like ASCII art of PASCLAW,');
    ConWriteLn('the source-encoding fix works. If they look like Ã©/â€¦ garbage,');
    ConWriteLn('the fix is incomplete on this compiler/OS combination.');
  except
    on E: Exception do
      ConWriteLn('EXCEPTION ' + E.ClassName + ': ' + E.Message);
  end;
end.
