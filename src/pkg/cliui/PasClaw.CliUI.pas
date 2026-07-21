{
  PasClaw.CliUI - terminal colour handling, banner, help/error rendering.
  Mirrors cmd/picoclaw/internal/cliui in picoclaw.
}
unit PasClaw.CliUI;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  { File has a UTF-8 BOM (Delphi auto-detects it). FPC also honours the
    BOM, but additionally needs $CODEPAGE UTF8 so string literals are
    stored as AnsiString CP_UTF8 -- without it FPC stores them as
    UnicodeString and the implicit conversions on PrintLn(Ansi.X + L +
    Ansi.Reset) become 6 warnings per banner line. dcc64 has no
    equivalent directive (E1030 "Invalid compiler directive: 'CODEPAGE'");
    Delphi reads the source as UTF-8 from the BOM and the literals
    become UnicodeString naturally. }
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TAnsi = record
    Reset, Bold, Dim, Red, Green, Yellow, Blue, Magenta, Cyan, Gray, BoldBlue, BoldRed: string;
  end;

var
  Ansi: TAnsi;

procedure CliUI_Init(NoColor: Boolean);
function  CliUI_NoColor: Boolean;
function  EarlyColorDisabled: Boolean;
procedure PrintBanner;
procedure ApplyTimezoneFromEnv;

{ Boxed panel rendering used by help / error output. Width auto-fits to the
  terminal (capped at 100 cols) and falls back to ASCII when colour is off. }
function  RenderPanel(const Title: string; const Lines: array of string): string;
function  FormatCLIError(const Msg, CommandPath: string): string;
function  RenderCommandHelp(const Use, Short, Long, Example: string;
                            const Subcommands, Flags: array of string): string;

(* Prompt for a line of input WITHOUT echoing keystrokes to the
   terminal -- for API keys, MCP auth tokens, and any other secret
   credential the user pastes during onboarding. Echo is restored
   before return regardless of exception. Falls back to a plain
   ReadLn (with echo) when the terminal mode can't be queried
   (e.g. stdin is a pipe, as in scripted tests) so non-interactive
   automation still works. Codex P2 on PR #126. *)
function ReadSecretLine(const Prompt: string): string;

(* UTF-8-safe console output. Bypasses the RTL's WriteLn path on
   Windows + Delphi, which transcodes UnicodeString through the
   Text-file codepage and produces mojibake (é → Ã©, … → â€¦) on
   default ANSI consoles even when SetConsoleOutputCP(CP_UTF8) has
   been called. Implementation per surface:

     Windows + Delphi   WriteConsoleW(GetStdHandle(...), PWideChar(S),
                        Length(S), ...) -- UTF-16 straight to the
                        renderer. Falls back to UTF-8 bytes + WriteFile
                        when stdout/stderr is redirected to a pipe or
                        file (WriteConsoleW returns ERROR_INVALID_HANDLE
                        on non-console handles).

     FPC any-OS, Delphi non-Windows   plain Write/WriteLn. FPC's
                        runtime emits the AnsiString's UTF-8 bytes
                        directly; POSIX terminals interpret UTF-8 by
                        default. No transcode trap to bypass.

   Call sites that used to do  WriteLn('foo: ', x)  with x non-string
   need to concatenate to a single string first (string concat or
   Format) since the helpers are not variadic. *)
procedure Print(const S: string);
procedure PrintLn(const S: string = '');
procedure PrintErr(const S: string);
procedure PrintLnErr(const S: string = '');

implementation

uses
  PasClaw.Utils
  {$IFDEF MSWINDOWS}
  , {$IFDEF FPC}Windows{$ELSE}Winapi.Windows{$ENDIF}
  {$ENDIF}
  {$IFDEF UNIX}
  , BaseUnix, TermIO
  {$ENDIF}
  {$IF DEFINED(POSIX) AND NOT DEFINED(FPC)}
  , Posix.Termios   { Delphi/Linux+macOS: tcgetattr/tcsetattr for ECHO control }
  {$IFEND}
  ;

var
  GNoColor: Boolean = False;

{$IFDEF MSWINDOWS}
procedure EnableUTF8Console;
begin
  { Force UTF-8 console code pages on Windows so Unicode banner/panel glyphs
    (█, ╔, ┌, etc.) are not interpreted via legacy ANSI/OEM encodings.
    SetConsoleOutputCP alone tells the console how to interpret bytes;
    under Delphi the RTL also caches a per-Text-file codepage that
    converts UnicodeString → bytes before they reach the console, so we
    need SetTextCodePage to point Output/ErrOutput at UTF-8 as well.
    FPC's WriteLn already emits the UTF-8 bytes its AnsiString holds,
    so it doesn't need the extra call. }
  SetConsoleCP(CP_UTF8);
  SetConsoleOutputCP(CP_UTF8);
  {$IFNDEF FPC}
  SetTextCodePage(Output,    CP_UTF8);
  SetTextCodePage(ErrOutput, CP_UTF8);
  {$ENDIF}
end;
{$ENDIF}

procedure SetAnsi(Disabled: Boolean);
begin
  if Disabled then
  begin
    Ansi.Reset    := '';
    Ansi.Bold     := '';
    Ansi.Dim      := '';
    Ansi.Red      := '';
    Ansi.Green    := '';
    Ansi.Yellow   := '';
    Ansi.Blue     := '';
    Ansi.Magenta  := '';
    Ansi.Cyan     := '';
    Ansi.Gray     := '';
    Ansi.BoldBlue := '';
    Ansi.BoldRed  := '';
  end
  else
  begin
    Ansi.Reset    := #27'[0m';
    Ansi.Bold     := #27'[1m';
    Ansi.Dim      := #27'[2m';
    Ansi.Red      := #27'[31m';
    Ansi.Green    := #27'[32m';
    Ansi.Yellow   := #27'[33m';
    Ansi.Blue     := #27'[34m';
    Ansi.Magenta  := #27'[35m';
    Ansi.Cyan     := #27'[36m';
    Ansi.Gray     := #27'[90m';
    Ansi.BoldBlue := #27'[1;38;2;62;93;185m';
    Ansi.BoldRed  := #27'[1;38;2;213;70;70m';
  end;
end;

procedure CliUI_Init(NoColor: Boolean);
begin
  {$IFDEF MSWINDOWS}
  EnableUTF8Console;
  {$ENDIF}
  GNoColor := NoColor;
  SetAnsi(NoColor);
end;

function CliUI_NoColor: Boolean;
begin
  Result := GNoColor;
end;

function EarlyColorDisabled: Boolean;
var
  i: Integer;
  a: string;
begin
  Result := False;
  if (GetEnvironmentVariable('NO_COLOR') <> '') or (GetEnvironmentVariable('TERM') = 'dumb') then
    Exit(True);
  for i := 1 to ParamCount do
  begin
    a := ParamStr(i);
    if (a = '--no-color') or (a = '--no-color=true') or (a = '--no-color=1') then
      Exit(True);
  end;
end;

procedure PrintBanner;
const
  L1 = '██████╗  █████╗ ███████╗ ██████╗██╗      █████╗ ██╗    ██╗';
  L2 = '██╔══██╗██╔══██╗██╔════╝██╔════╝██║     ██╔══██╗██║    ██║';
  L3 = '██████╔╝███████║███████╗██║     ██║     ███████║██║ █╗ ██║';
  L4 = '██╔═══╝ ██╔══██║╚════██║██║     ██║     ██╔══██║██║███╗██║';
  L5 = '██║     ██║  ██║███████║╚██████╗███████╗██║  ██║╚███╔███╔╝';
  L6 = '╚═╝     ╚═╝  ╚═╝╚══════╝ ╚═════╝╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ';
begin
  PrintLn;
  if GNoColor then
  begin
    PrintLn(L1); PrintLn(L2); PrintLn(L3);
    PrintLn(L4); PrintLn(L5); PrintLn(L6);
  end
  else
  begin
    PrintLn(Ansi.BoldBlue + L1 + Ansi.Reset);
    PrintLn(Ansi.BoldBlue + L2 + Ansi.Reset);
    PrintLn(Ansi.BoldBlue + L3 + Ansi.Reset);
    PrintLn(Ansi.BoldRed  + L4 + Ansi.Reset);
    PrintLn(Ansi.BoldRed  + L5 + Ansi.Reset);
    PrintLn(Ansi.BoldRed  + L6 + Ansi.Reset);
  end;
  PrintLn;
end;

procedure ApplyTimezoneFromEnv;
var
  Tz: string;
begin
  Tz := GetEnvironmentVariable('TZ');
  if Tz = '' then Exit;
  PrintLn('TZ environment: ' + Tz);
  PrintLn('ZONEINFO environment: ' + GetEnvironmentVariable('ZONEINFO'));
  { FPC honours the TZ environment variable on Unix natively; on Windows we
    simply report it and let the RTL handle conversions. }
end;

function PadRight(const S: string; W: Integer): string;
begin
  if VisibleLength(S) >= W then Result := S
  else Result := S + StringOfChar(' ', W - VisibleLength(S));
end;

function RenderPanel(const Title: string; const Lines: array of string): string;
const
  TL = '┌'; TR = '┐'; BL = '└'; BR = '┘'; H = '─'; V = '│';
var
  i, W: Integer;
  SB: TStringBuilder;
  Hbar: string;
begin
  W := VisibleLength(Title) + 2;
  for i := 0 to High(Lines) do
    if VisibleLength(Lines[i]) + 2 > W then
      W := VisibleLength(Lines[i]) + 2;
  if W < 32 then W := 32;
  if W > 100 then W := 100;

  Hbar := DupStr(H, W);
  SB := TStringBuilder.Create;
  try
    SB.Append(Ansi.BoldBlue).Append(TL).Append(Hbar).Append(TR).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).Append(' ')
      .Append(Ansi.Bold).Append(PadRight(Title, W - 1)).Append(Ansi.Reset)
      .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset)
      .Append(StringOfChar(' ', W))
      .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    for i := 0 to High(Lines) do
      SB.Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).Append(' ')
        .Append(PadRight(Lines[i], W - 1))
        .Append(Ansi.BoldBlue).Append(V).Append(Ansi.Reset).AppendLine;
    SB.Append(Ansi.BoldBlue).Append(BL).Append(Hbar).Append(BR).Append(Ansi.Reset).AppendLine;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function FormatCLIError(const Msg, CommandPath: string): string;
var
  Lines: array of string;
begin
  SetLength(Lines, 2);
  Lines[0] := Ansi.Red + 'error: ' + Ansi.Reset + Msg;
  if CommandPath <> '' then
    Lines[1] := Ansi.Dim + 'run `' + CommandPath + ' --help` for usage' + Ansi.Reset
  else
    Lines[1] := Ansi.Dim + 'run `pasclaw --help` for usage' + Ansi.Reset;
  Result := RenderPanel('PasClaw error', Lines);
end;

function RenderCommandHelp(const Use, Short, Long, Example: string;
                          const Subcommands, Flags: array of string): string;
var
  Lines: TStringList;
  i: Integer;
  Tmp: string;
begin
  Lines := TStringList.Create;
  try
    if Short <> '' then Lines.Add(Short);
    if Long  <> '' then
    begin
      Lines.Add('');
      Lines.Add(Long);
    end;
    Lines.Add('');
    Lines.Add(Ansi.Bold + 'Usage:' + Ansi.Reset);
    Lines.Add('  ' + Use);
    if Length(Subcommands) > 0 then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Commands:' + Ansi.Reset);
      for i := 0 to High(Subcommands) do
        Lines.Add('  ' + Subcommands[i]);
    end;
    if Length(Flags) > 0 then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Flags:' + Ansi.Reset);
      for i := 0 to High(Flags) do
        Lines.Add('  ' + Flags[i]);
    end;
    if Example <> '' then
    begin
      Lines.Add('');
      Lines.Add(Ansi.Bold + 'Examples:' + Ansi.Reset);
      Lines.Add('  ' + Example);
    end;

    Tmp := '';
    for i := 0 to Lines.Count - 1 do
    begin
      if i > 0 then Tmp := Tmp + sLineBreak;
      Tmp := Tmp + Lines[i];
    end;
    Result := Tmp + sLineBreak;
  finally
    Lines.Free;
  end;
end;

function ReadSecretLine(const Prompt: string): string;
{$IFDEF UNIX}
var
  Old, New_: TermIOS;
  HaveTerm: Boolean;
begin
  Print(Prompt);
  Flush(Output);
  HaveTerm := tcgetattr(0, Old) = 0;
  if HaveTerm then
  begin
    New_ := Old;
    { Clear ECHO so the typed/pasted token doesn't appear on screen or
      land in the terminal scrollback. Leave ICANON on so the user can
      still backspace and the line is delivered on Enter. }
    New_.c_lflag := New_.c_lflag and not ECHO;
    tcsetattr(0, TCSANOW, New_);
  end;
  try
    ReadLn(Result);
  finally
    if HaveTerm then tcsetattr(0, TCSANOW, Old);
  end;
  { ReadLn consumed the newline silently when echo was off -- emit one
    so the next prompt starts on a fresh line. }
  if HaveTerm then PrintLn;
end;
{$ENDIF}
{$IF DEFINED(POSIX) AND NOT DEFINED(FPC)}
{ Delphi on Linux/macOS: same ECHO-off trick via the RTL's Posix.Termios,
  so a pasted secret isn't echoed to the terminal or its scrollback. }
var
  Old, New_: termios;
  HaveTerm: Boolean;
begin
  Print(Prompt);
  Flush(Output);
  HaveTerm := tcgetattr(0, Old) = 0;
  if HaveTerm then
  begin
    New_ := Old;
    New_.c_lflag := New_.c_lflag and not Cardinal(ECHO);
    tcsetattr(0, TCSANOW, New_);
  end;
  try
    ReadLn(Result);
  finally
    if HaveTerm then tcsetattr(0, TCSANOW, Old);
  end;
  if HaveTerm then PrintLn;
end;
{$IFEND}
{$IFDEF MSWINDOWS}
var
  H: THandle;
  OldMode, NewMode: DWORD;
  HaveMode: Boolean;
begin
  Print(Prompt);
  Flush(Output);
  H := GetStdHandle(STD_INPUT_HANDLE);
  HaveMode := (H <> INVALID_HANDLE_VALUE) and GetConsoleMode(H, OldMode);
  if HaveMode then
  begin
    NewMode := OldMode and not DWORD(ENABLE_ECHO_INPUT);
    SetConsoleMode(H, NewMode);
  end;
  try
    ReadLn(Result);
  finally
    if HaveMode then SetConsoleMode(H, OldMode);
  end;
  if HaveMode then PrintLn;
end;
{$ENDIF}
{ Bare/unknown platform (none of Windows, FPC/Unix, or Delphi/POSIX): no way to
  turn off terminal echo, so fall back to a plain read. }
{$IF NOT DEFINED(UNIX) AND NOT DEFINED(POSIX) AND NOT DEFINED(MSWINDOWS)}
begin
  { Unknown platform -- fall through to plain echoing read so the
    program still runs. }
  Print(Prompt);
  ReadLn(Result);
end;
{$IFEND}

{$IF DEFINED(MSWINDOWS) AND NOT DEFINED(FPC)}
procedure WriteToHandle(H: THandle; const S: string);
{ Per the per-surface plan above: WriteConsoleW when H is a real
  console (UTF-16 → renderer, no codepage conversion); UTF-8 bytes
  via WriteFile otherwise (pipe / file redirection -- WriteConsoleW
  would return ERROR_INVALID_HANDLE there). Empty S is a no-op. }
var
  Mode: DWORD;
  Written: DWORD;
  Bytes: TBytes;
begin
  if (H = INVALID_HANDLE_VALUE) or (S = '') then Exit;
  if GetConsoleMode(H, Mode) then
    WriteConsoleW(H, PWideChar(S), Length(S), Written, nil)
  else
  begin
    Bytes := TEncoding.UTF8.GetBytes(S);
    if Length(Bytes) > 0 then
      WriteFile(H, Bytes[0], Length(Bytes), Written, nil);
  end;
end;

procedure Print(const S: string);
begin
  WriteToHandle(GetStdHandle(STD_OUTPUT_HANDLE), S);
end;

procedure PrintLn(const S: string);
begin
  WriteToHandle(GetStdHandle(STD_OUTPUT_HANDLE), S + sLineBreak);
end;

procedure PrintErr(const S: string);
begin
  WriteToHandle(GetStdHandle(STD_ERROR_HANDLE), S);
end;

procedure PrintLnErr(const S: string);
begin
  WriteToHandle(GetStdHandle(STD_ERROR_HANDLE), S + sLineBreak);
end;
{$ELSE}
{ FPC any-OS + Delphi non-Windows: standard Write/WriteLn already
  emits the string's bytes directly to stdout/stderr. FPC's RTL
  carries AnsiString as UTF-8; Delphi on POSIX writes through the
  C runtime which honours the terminal's UTF-8 expectation. No
  WriteConsoleW bypass needed. }
procedure Print(const S: string);
begin
  Write(Output, S);
end;

procedure PrintLn(const S: string);
begin
  WriteLn(Output, S);
end;

procedure PrintErr(const S: string);
begin
  Write(ErrOutput, S);
end;

procedure PrintLnErr(const S: string);
begin
  WriteLn(ErrOutput, S);
end;
{$IFEND}

initialization
  SetAnsi(False);
end.
