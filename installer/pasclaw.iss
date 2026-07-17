; PasClaw -- Inno Setup installer script
; ---------------------------------------------------------------------------
; Produces a SEPARATE installer per architecture. Pass /DArch=x64 or /DArch=x86
; (default x64); each build writes its own setup EXE:
;   PasClaw-<version>-x64-setup.exe   and   PasClaw-<version>-x86-setup.exe
;
; The Windows (Delphi/dcc64) build is self-contained -- a single PasClaw.exe
; (SQLite linked statically, TLS via Windows SChannel, web UI embedded in the
; binary), so there are NO OpenSSL / sqlite3 DLLs to ship.
;
; Build:
;   1. Build the Release binary for the target platform (RAD Studio / dcc):
;        Win64 -> build\delphi\Win64\Release\PasClaw.exe
;        Win32 -> build\delphi\Win32\Release\PasClaw.exe
;      (or override with /DSourceExe=<path>).
;   2. Compile the installer(s):
;        iscc /DArch=x64 installer\pasclaw.iss
;        iscc /DArch=x86 installer\pasclaw.iss
;      Pass a version too:  iscc /DArch=x64 /DMyAppVersion=0.2.0 installer\pasclaw.iss
;   Output lands in installer\Output\.
; ---------------------------------------------------------------------------

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif

#if Arch == "x64"
  #define ArchSuffix "x64"
  #ifndef SourceExe
    #define SourceExe "..\build\delphi\Win64\Release\PasClaw.exe"
  #endif
#elif Arch == "x86"
  #define ArchSuffix "x86"
  #ifndef SourceExe
    #define SourceExe "..\build\delphi\Win32\Release\PasClaw.exe"
  #endif
#else
  #error Arch must be "x64" or "x86"
#endif

#define MyAppName    "PasClaw"
#define MyAppExe     "PasClaw.exe"
#define MyAppPublisher "PasClaw contributors"
#define MyAppURL     "https://github.com/fmxexpress/pasclaw"

[Setup]
; A STABLE AppId -- constant across versions AND architectures so a switch or
; upgrade replaces the prior install in place (it is one application).
AppId={{A7C3E1F2-9B4D-4E5A-8C6F-1D2E3F4A5B6C}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}/issues
AppUpdatesURL={#MyAppURL}/releases
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
LicenseFile=..\LICENSE
OutputDir=Output
OutputBaseFilename=PasClaw-{#MyAppVersion}-{#ArchSuffix}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; So Windows broadcasts the PATH change to running shells.
ChangesEnvironment=yes
UninstallDisplayIcon={app}\{#MyAppExe}
#if Arch == "x64"
; 64-bit installer. "x64compatible" (Inno Setup 6.3+) also lets this native
; x64 build install and run on Windows on ARM via the OS's built-in x64
; emulation -- not just on native x64 Windows. Delphi has no Windows-ARM64
; target, so this emulated x64 build is how PasClaw runs on ARM. Installs to
; the real 64-bit Program Files.
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#else
; 32-bit installer: runs on 32-bit Windows and as a 32-bit app on x64/ARM64.
ArchitecturesAllowed=x86compatible
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Add PasClaw to PATH (run `pasclaw` from any terminal)"; GroupDescription: "Integration:"
Name: "webuiicon"; Description: "Create a ""PasClaw Web UI"" Start Menu shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; DestName: "{#MyAppExe}"; Flags: ignoreversion
Source: "..\LICENSE";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\*";     DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\PasClaw Web UI"; Filename: "{app}\{#MyAppExe}"; Parameters: "serve"; WorkingDir: "{app}"; Comment: "Start the PasClaw gateway + web UI"; Tasks: webuiicon
Name: "{group}\PasClaw Terminal"; Filename: "{cmd}"; Parameters: "/K ""{app}\{#MyAppExe}"" --help"; WorkingDir: "{app}"; Comment: "Open a terminal with PasClaw ready"
Name: "{group}\Documentation"; Filename: "{app}\docs\README.md"
Name: "{group}\Uninstall PasClaw"; Filename: "{uninstallexe}"

[Run]
Filename: "{cmd}"; Parameters: "/K ""{app}\{#MyAppExe}"" onboard"; Description: "Run PasClaw onboarding now"; Flags: postinstall skipifsilent nowait
Filename: "{app}\docs\README.md"; Description: "Open the documentation"; Flags: postinstall skipifsilent shellexec nowait unchecked

[Code]
const
  EnvHKLMKey = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment';
  EnvHKCUKey = 'Environment';

function PathRootKey: Integer;
begin
  if IsAdminInstallMode then Result := HKEY_LOCAL_MACHINE
  else Result := HKEY_CURRENT_USER;
end;

function PathSubKey: string;
begin
  if IsAdminInstallMode then Result := EnvHKLMKey
  else Result := EnvHKCUKey;
end;

{ Case-insensitive check for the app dir already being on PATH in one hive. }
function DirOnPathIn(Root: Integer; const SubKey, Dir: string): Boolean;
var
  Cur: string;
begin
  Result := False;
  if not RegQueryStringValue(Root, SubKey, 'Path', Cur) then Exit;
  Result := Pos(';' + Uppercase(RemoveBackslash(Dir)) + ';',
                ';' + Uppercase(Cur) + ';') > 0;
end;

procedure AddDirToPath(const Dir: string);
var
  Cur: string;
begin
  { Install-time: IsAdminInstallMode is authoritative, so add to just the one
    hive that matches this install's scope. }
  if DirOnPathIn(PathRootKey, PathSubKey, Dir) then Exit;
  if not RegQueryStringValue(PathRootKey, PathSubKey, 'Path', Cur) then Cur := '';
  if (Cur <> '') and (Copy(Cur, Length(Cur), 1) <> ';') then Cur := Cur + ';';
  RegWriteExpandStringValue(PathRootKey, PathSubKey, 'Path', Cur + RemoveBackslash(Dir));
end;

{ Remove Dir from the PATH stored in one hive. When Dir isn't present the
  function exits before writing, so calling it on a hive we can only read
  (e.g. HKLM during a non-elevated user uninstall) is a harmless no-op. }
procedure RemoveDirFromPathIn(Root: Integer; const SubKey, Dir: string);
var
  Cur, D, Wrapped: string;
  P: Integer;
begin
  if not RegQueryStringValue(Root, SubKey, 'Path', Cur) then Exit;
  D := RemoveBackslash(Dir);
  Wrapped := ';' + Cur + ';';
  P := Pos(Uppercase(';' + D + ';'), Uppercase(Wrapped));
  if P = 0 then Exit;
  Delete(Wrapped, P, Length(D) + 1);
  if (Length(Wrapped) > 0) and (Wrapped[1] = ';') then Delete(Wrapped, 1, 1);
  if (Length(Wrapped) > 0) and (Wrapped[Length(Wrapped)] = ';') then Delete(Wrapped, Length(Wrapped), 1);
  RegWriteExpandStringValue(Root, SubKey, 'Path', Wrapped);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddDirToPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Dir: string;
begin
  if CurUninstallStep = usUninstall then
  begin
    { The install added {app} to exactly one hive (HKLM for an admin install,
      HKCU otherwise), but at uninstall we can't reliably tell which: Inno's
      IsAdminInstallMode reflects the uninstaller's own elevation token, which
      an admin deployment tool can flip relative to install time. Rather than
      persist the mode and second-guess it, clean both hives -- each call
      no-ops when {app} isn't on that hive's PATH, so the real entry is removed
      and never orphaned. }
    Dir := ExpandConstant('{app}');
    RemoveDirFromPathIn(HKEY_LOCAL_MACHINE, EnvHKLMKey, Dir);
    RemoveDirFromPathIn(HKEY_CURRENT_USER, EnvHKCUKey, Dir);
  end;
end;
