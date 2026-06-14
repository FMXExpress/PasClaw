(*
  PasClaw.Tools.DelphiBuild -- delphi_build tool.

  Why this exists: with the docker shell backend on a Windows host, the
  agent's shell_exec/execute_code run inside a Linux container, but the
  Delphi compiler (dcc32/dcc64) lives on the Windows HOST. The model
  could not reach it ("dcc32: command not found" / "No such file"). Like
  fs_read/fs_write, this tool runs on the HOST (via PasClaw.Platform's
  RunOneShot, NOT the shell backend), against the same workspace that is
  bind-mounted into the container -- so the model's edit -> build ->
  read-errors loop works regardless of the shell backend.

  Two build mechanisms (operator picks the security/fidelity trade-off):

    * dcc-direct (DEFAULT). Invokes dcc32.exe / dcc64.exe on the project's
      .dpr with best-effort RAD-Studio library paths + namespaces. The
      compiler does not execute arbitrary host code, so this is the
      sandbox-friendly default. Non-trivial projects may need extra unit
      paths -- supply them via PASCLAW_DELPHI_SEARCH.

    * MSBuild (OPT-IN). Builds the .dproj via rsvars.bat + MSBuild, which
      is IDE-identical (honours the project's own library paths/defines).
      BUT MSBuild runs the .dproj's pre/post-build events -- arbitrary
      host commands -- which defeats the docker sandbox. Gated behind
      PASCLAW_DELPHI_ALLOW_MSBUILD=1 so a model can't turn on host
      execution just by passing an argument.

  Operator configuration (env vars; no config.json schema change):
    PASCLAW_DELPHI_BIN          override the RAD Studio \bin directory
    PASCLAW_DELPHI_SEARCH       extra ';'-separated unit search paths (dcc -U)
    PASCLAW_DELPHI_NAMESPACES   override the default unit-scope namespaces
    PASCLAW_DELPHI_ALLOW_MSBUILD  '1'/'true'/'yes' to allow MSBuild mode

  Registration self-gates: RegisterDelphiBuildTool is a no-op unless a
  Delphi \bin is discoverable, so it stays invisible on Linux/macOS and
  on Windows boxes without RAD Studio.
*)
unit PasClaw.Tools.DelphiBuild;

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

{ Registers delphi_build iff a RAD Studio \bin is discoverable. }
procedure RegisterDelphiBuildTool(R: TToolRegistry);

{ Absolute path of the RAD Studio \bin dir (with dcc32.exe), or '' if not
  found. Exposed for status output / tests. }
function DiscoverDelphiBin: string;

{ Tolerant parse of dcc/MSBuild output into a compact diagnostic summary.
  Classifies each line carrying a Delphi code token (E#### / W#### / H####
  / F####) and returns the kept diagnostic lines; counts come back via the
  out params. Format-agnostic across raw dcc and MSBuild's "[dcc32 Error]"
  bracket form -- both embed the code. Exposed for tests. }
function ParseDelphiOutput(const Raw: string;
                           out NErrors, NWarnings, NHints: Integer): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Utils,
  PasClaw.Platform,
  PasClaw.Tools.Sandbox,
  PasClaw.Logger
  {$IFDEF MSWINDOWS}
  {$IFDEF FPC}, Windows, Registry{$ELSE}, Winapi.Windows, System.Win.Registry{$ENDIF}
  {$ENDIF}
  ;

{$IFDEF MSWINDOWS}
const
  { Searched newest-first; first install with dcc32.exe wins. Athens=23,
    Alexandria=22, Sydney=21, ... }
  KnownStudioVersions: array[0..7] of string =
    ('23.0', '22.0', '21.0', '20.0', '19.0', '18.0', '17.0', '36.0');
{$ENDIF}

const
  DefaultNamespaces =
    'System;System.Win;Winapi;Data;Data.Win;Xml;Web;Soap;Vcl;Vcl.Imaging;' +
    'Vcl.Touch;Vcl.Samples;Vcl.Shell;FMX;System.Json;Data.Bind;' +
    'System.Actions;System.ImageList;System.Bluetooth';

function HasDcc(const BinDir: string): Boolean;
begin
  Result := (BinDir <> '') and
            (FileExists(JoinPath(BinDir, 'dcc32.exe')) or
             FileExists(JoinPath(BinDir, 'dcc64.exe')));
end;

{$IFDEF MSWINDOWS}
function RegFindBin(Root: HKEY): string;
{ RAD Studio records its install dir at
  <Root>\SOFTWARE\Embarcadero\BDS\<ver>\RootDir -- the canonical way to
  find a compiler installed anywhere (custom drive/path), which the
  Program-Files probe below would miss. HKCU is where a normal per-user
  install writes it and isn't WOW64-redirected; HKLM is the fallback.
  Enumerate versions and prefer the newest. }
var
  Reg: TRegistry;
  Keys: TStringList;
  i: Integer;
  RootDir, Bin: string;
begin
  Result := '';
  Reg := TRegistry.Create;
  Keys := TStringList.Create;
  try
    Reg.RootKey := Root;
    if not Reg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS') then Exit;
    Reg.GetKeyNames(Keys);
    Reg.CloseKey;
    Keys.Sort;   { ascending -> walk descending for newest-first }
    for i := Keys.Count - 1 downto 0 do
    begin
      if Reg.OpenKeyReadOnly('SOFTWARE\Embarcadero\BDS\' + Keys[i]) then
      begin
        try
          RootDir := Reg.ReadString('RootDir');
        except
          RootDir := '';
        end;
        Reg.CloseKey;
        if RootDir <> '' then
        begin
          Bin := JoinPath(RootDir, 'bin');
          if HasDcc(Bin) then Exit(Bin);
        end;
      end;
    end;
  finally
    Keys.Free;
    Reg.Free;
  end;
end;
{$ENDIF}

function DiscoverDelphiBin: string;
var
  Cand: string;
  {$IFDEF MSWINDOWS}
  PF, PFx86: string;

  function ProbeRoots(const ProgFiles: string): string;
  var
    v: Integer;
    B: string;
  begin
    Result := '';
    if ProgFiles = '' then Exit;
    for v := Low(KnownStudioVersions) to High(KnownStudioVersions) do
    begin
      B := JoinPath(JoinPath(JoinPath(ProgFiles, 'Embarcadero'), 'Studio'),
                    KnownStudioVersions[v]);
      B := JoinPath(B, 'bin');
      if HasDcc(B) then Exit(B);
    end;
  end;
  {$ENDIF}
begin
  Result := '';
  { 1. Explicit operator override -- works on any OS (e.g. a cross-mounted
       toolchain), and lets tests point at a fixture. }
  Cand := GetEnvironmentVariable('PASCLAW_DELPHI_BIN');
  if (Cand <> '') and HasDcc(Cand) then Exit(Cand);

  {$IFDEF MSWINDOWS}
  { 2. Registry (canonical -- finds installs on any drive/path). }
  Cand := RegFindBin(HKEY_CURRENT_USER);
  if Cand <> '' then Exit(Cand);
  Cand := RegFindBin(HKEY_LOCAL_MACHINE);
  if Cand <> '' then Exit(Cand);
  { 3. Default Program Files roots as a last resort. }
  PFx86 := GetEnvironmentVariable('ProgramFiles(x86)');
  PF    := GetEnvironmentVariable('ProgramFiles');
  Cand := ProbeRoots(PFx86);
  if Cand <> '' then Exit(Cand);
  Cand := ProbeRoots(PF);
  if Cand <> '' then Exit(Cand);
  {$ENDIF}
end;

function FindDelphiCode(const Line: string; out Letter: Char): Boolean;
{ True when Line contains a Delphi diagnostic code token: one of E/W/H/F
  followed by exactly four digits, at a word boundary (so "FIRE2003" or a
  hex blob doesn't false-positive). }
var
  i, n: Integer;
begin
  Result := False;
  Letter := ' ';
  n := Length(Line);
  for i := 1 to n - 4 do
    if CharInSet(Line[i], ['E', 'W', 'H', 'F']) and
       CharInSet(Line[i + 1], ['0'..'9']) and
       CharInSet(Line[i + 2], ['0'..'9']) and
       CharInSet(Line[i + 3], ['0'..'9']) and
       CharInSet(Line[i + 4], ['0'..'9']) and
       ((i = 1) or not CharInSet(Line[i - 1], ['A'..'Z', 'a'..'z', '0'..'9', '_'])) and
       ((i + 5 > n) or not CharInSet(Line[i + 5], ['0'..'9'])) then
    begin
      Letter := Line[i];
      Exit(True);
    end;
end;

function ParseDelphiOutput(const Raw: string;
                           out NErrors, NWarnings, NHints: Integer): string;
const
  MaxKept = 200;   { cap so a runaway build can't blow the tool-result budget }
var
  Lines: TStringList;
  Sb: TStringBuilder;
  i, Kept: Integer;
  Letter: Char;
  Ln: string;
begin
  NErrors := 0; NWarnings := 0; NHints := 0;
  Kept := 0;
  Lines := TStringList.Create;
  Sb := TStringBuilder.Create;
  try
    Lines.Text := StringReplace(Raw, #13, '', [rfReplaceAll]);
    for i := 0 to Lines.Count - 1 do
    begin
      Ln := Lines[i];
      if not FindDelphiCode(Ln, Letter) then Continue;
      case Letter of
        'F': Inc(NErrors);   { fatal counts as an error for the model }
        'E': Inc(NErrors);
        'W': Inc(NWarnings);
        'H': Inc(NHints);
      end;
      if Kept < MaxKept then
      begin
        if Sb.Length > 0 then Sb.Append(#10);
        Sb.Append(Trim(Ln));
        Inc(Kept);
      end;
    end;
    Result := Sb.ToString;
    {$IFDEF FPC}
    SetCodePage(RawByteString(Result), CP_UTF8, False);
    {$ENDIF}
  finally
    Sb.Free;
    Lines.Free;
  end;
end;

function MsbuildAllowed: Boolean;
var
  V: string;
begin
  V := LowerCase(Trim(GetEnvironmentVariable('PASCLAW_DELPHI_ALLOW_MSBUILD')));
  Result := (V = '1') or (V = 'true') or (V = 'yes') or (V = 'on');
end;

function DQuote(const S: string): string;
{ Double-quote a path/arg for the cmd.exe / dcc command line we hand to
  RunOneShot (which wraps in cmd /C on Windows). }
begin
  Result := '"' + S + '"';
end;

function BuildViaDcc(const BinDir, ProjDpr, Platform_, Config: string;
                     out Output: string): Integer;
var
  Bds, Dcc, LibBase, Cmd, NS, Extra, DbgDcu, RelDcu: string;
begin
  Bds := ExtractFileDir(ExcludeTrailingPathDelimiter(BinDir));   { ...\Studio\NN.0 }

  if SameText(Platform_, 'Win64') then
    Dcc := JoinPath(BinDir, 'dcc64.exe')
  else
    Dcc := JoinPath(BinDir, 'dcc32.exe');

  { Standard precompiled-DCU library dirs for this platform. release holds
    the RTL/FMX/VCL .dcu the project links against; debug too for Debug. }
  LibBase := JoinPath(JoinPath(Bds, 'lib'), Platform_);
  RelDcu  := JoinPath(LibBase, 'release');
  DbgDcu  := JoinPath(LibBase, 'debug');

  NS := GetEnvironmentVariable('PASCLAW_DELPHI_NAMESPACES');
  if NS = '' then NS := DefaultNamespaces;

  Extra := GetEnvironmentVariable('PASCLAW_DELPHI_SEARCH');

  { -B build all; -NS namespaces; -U unit search; -$D+/- debug info.
    Output (exe/dcu) lands in the project dir (the cwd we run from). }
  Cmd := DQuote(Dcc) + ' -B -NS' + NS;
  if DirectoryExists(RelDcu) then Cmd := Cmd + ' -U' + DQuote(RelDcu);
  if SameText(Config, 'Debug') and DirectoryExists(DbgDcu) then
    Cmd := Cmd + ' -U' + DQuote(DbgDcu);
  if Extra <> '' then Cmd := Cmd + ' -U' + DQuote(Extra);
  if SameText(Config, 'Release') then
    Cmd := Cmd + ' -$D- -$L- -$O+'
  else
    Cmd := Cmd + ' -$D+ -$L+ -$O-';
  Cmd := Cmd + ' ' + DQuote(ProjDpr) + ' 2>&1';

  Result := RunOneShot(Cmd, ExtractFileDir(ProjDpr), Output);
end;

function BuildViaMsbuild(const BinDir, Proj, Platform_, Config: string;
                         out Output: string): Integer;
var
  Rsvars, Cmd: string;
begin
  Rsvars := JoinPath(BinDir, 'rsvars.bat');
  if not FileExists(Rsvars) then
  begin
    Output := 'rsvars.bat not found in ' + BinDir;
    Exit(-1);
  end;
  { call rsvars to set up the MSBuild + compiler environment, then build. }
  Cmd := 'call ' + DQuote(Rsvars) + ' && msbuild ' + DQuote(Proj) +
         ' /t:Build /p:Config=' + Config + ';Platform=' + Platform_ +
         ' /nologo /v:minimal 2>&1';
  Result := RunOneShot(Cmd, ExtractFileDir(Proj), Output);
end;

function Tool_DelphiBuild(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Project, Platform_, Config, ProjAbs, ProjDpr, BinDir, Out_, Diags, Reason: string;
  WantMsbuild: Boolean;
  ExitCode, NErr, NWarn, NHint: Integer;
begin
  Result := '';
  ErrMsg := '';

  Project := ''; Platform_ := 'Win32'; Config := 'Debug'; WantMsbuild := False;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj <> nil then
  try
    Project := Trim(Obj.GetStr('project', ''));
    if Obj.GetStr('platform', '') <> '' then Platform_ := Obj.GetStr('platform', 'Win32');
    if Obj.GetStr('config', '')   <> '' then Config    := Obj.GetStr('config', 'Debug');
    WantMsbuild := Obj.GetBool('msbuild', False);
  finally
    Obj.Free;
  end;

  if Project = '' then
  begin
    ErrMsg := 'missing required argument: project (path to a .dpr or .dproj)';
    Exit;
  end;
  if not (SameText(Platform_, 'Win32') or SameText(Platform_, 'Win64')) then
  begin
    ErrMsg := 'platform must be Win32 or Win64 (got "' + Platform_ + '")';
    Exit;
  end;
  if not (SameText(Config, 'Debug') or SameText(Config, 'Release')) then
  begin
    ErrMsg := 'config must be Debug or Release (got "' + Config + '")';
    Exit;
  end;

  BinDir := DiscoverDelphiBin;
  if BinDir = '' then
  begin
    ErrMsg := 'no RAD Studio install found. Set PASCLAW_DELPHI_BIN to the \bin ' +
              'directory containing dcc32.exe.';
    Exit;
  end;

  { Sandbox: only build a project inside the workspace. CanReadPath honours
    restrict_to_workspace; building writes outputs next to the project, but
    the gate we care about is "is this a workspace project, not some
    arbitrary host path the model dreamed up". }
  ProjAbs := ExpandFileName(ExpandHome(Project));
  if not CanReadPath(ProjAbs, Reason) then
  begin
    ErrMsg := Reason;
    Exit;
  end;
  if not FileExists(ProjAbs) then
  begin
    ErrMsg := 'no such project file: ' + ProjAbs;
    Exit;
  end;

  if WantMsbuild then
  begin
    if not MsbuildAllowed then
    begin
      ErrMsg := 'MSBuild mode is disabled. It runs the .dproj''s pre/post-build ' +
                'events on the host (a sandbox escape), so it must be enabled by ' +
                'the operator via PASCLAW_DELPHI_ALLOW_MSBUILD=1. Omit "msbuild" ' +
                'to use the dcc-direct compiler instead.';
      Exit;
    end;
    LogInfo('delphi_build: msbuild %s (%s/%s)', [ProjAbs, Config, Platform_]);
    ExitCode := BuildViaMsbuild(BinDir, ProjAbs, Platform_, Config, Out_);
  end
  else
  begin
    { dcc compiles a .dpr. If handed a .dproj, fall back to the sibling
      .dpr; if that's missing, point the model at MSBuild mode. }
    if SameText(ExtractFileExt(ProjAbs), '.dproj') then
    begin
      ProjDpr := ChangeFileExt(ProjAbs, '.dpr');
      if not FileExists(ProjDpr) then
      begin
        ErrMsg := 'dcc-direct needs a .dpr; none found next to ' + ProjAbs +
                  '. Pass the .dpr, or enable MSBuild mode ' +
                  '(PASCLAW_DELPHI_ALLOW_MSBUILD=1 + "msbuild":true) to build the .dproj.';
        Exit;
      end;
    end
    else
      ProjDpr := ProjAbs;
    LogInfo('delphi_build: dcc %s (%s/%s)', [ProjDpr, Config, Platform_]);
    ExitCode := BuildViaDcc(BinDir, ProjDpr, Platform_, Config, Out_);
  end;

  Diags := ParseDelphiOutput(Out_, NErr, NWarn, NHint);
  if (ExitCode = 0) and (NErr = 0) then
    Result := Format('build OK (%s/%s): %d warning(s), %d hint(s)',
                     [Config, Platform_, NWarn, NHint])
  else
    Result := Format('build FAILED (%s/%s, exit=%d): %d error(s), %d warning(s)',
                     [Config, Platform_, ExitCode, NErr, NWarn]);
  if Diags <> '' then
    Result := Result + #10 + Diags
  else if ExitCode <> 0 then
    { No coded diagnostics parsed but the compiler failed -- surface the
      raw tail so the model isn't blind (e.g. "file not found", env issues). }
    Result := Result + #10 + Copy(Trim(Out_), 1, 1500);
end;

procedure RegisterDelphiBuildTool(R: TToolRegistry);
var
  T: TTool;
begin
  if DiscoverDelphiBin = '' then Exit;   { no toolchain -> tool stays hidden }
  T.Name        := 'delphi_build';
  T.Description :=
    'Compile a Delphi/RAD Studio project on the host with dcc32/dcc64 ' +
    '(runs host-side even when shell_exec is in a docker container). Args: ' +
    'project (path to a .dpr, or a .dproj for MSBuild mode), platform ' +
    '(Win32|Win64, default Win32), config (Debug|Release, default Debug), ' +
    'msbuild (bool, default false -- MSBuild/.dproj mode is operator-gated). ' +
    'Returns a build status plus parsed errors/warnings/hints.';
  T.Schema :=
    '{"type":"object","properties":{' +
    '"project":{"type":"string","description":"Path to the .dpr (.dproj for MSBuild mode), inside the workspace."},' +
    '"platform":{"type":"string","enum":["Win32","Win64"]},' +
    '"config":{"type":"string","enum":["Debug","Release"]},' +
    '"msbuild":{"type":"boolean","description":"Build the .dproj via MSBuild (IDE-identical; runs build events; operator-gated)."}' +
    '},"required":["project"]}';
  T.Handler  := Tool_DelphiBuild;
  T.HandlerObj := nil;
  T.IsCore   := False;
  T.Category := tcMutating;   { produces binaries / .dcu }
  R.Register(T);
end;

end.
