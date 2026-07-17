; PasClaw -- Inno Setup installer script
; ---------------------------------------------------------------------------
; Packages the self-contained Windows build of PasClaw (a single PasClaw.exe --
; SQLite is statically linked, TLS uses Windows SChannel, and the web UI is
; embedded in the binary, so there are NO OpenSSL / sqlite3 DLLs to ship).
;
; Build:
;   1. Build the Release Win64 binary (RAD Studio / dcc64) so it lands at
;      build\delphi\Win64\Release\PasClaw.exe  (or pass /DSourceExe=<path>).
;   2. Compile this script with Inno Setup 6:
;        iscc installer\pasclaw.iss
;      Optionally pass the version:  iscc /DMyAppVersion=0.2.0 installer\pasclaw.iss
;   The installer is written to installer\Output\.
;
; The installer: installs to Program Files (or per-user), optionally adds the
; install dir to PATH so `pasclaw` works in any terminal, creates Start Menu
; shortcuts (Web UI, terminal, docs), and can run onboarding on finish.
; ---------------------------------------------------------------------------

#ifndef MyAppVersion
  #define MyAppVersion "0.1.0"
#endif
#ifndef SourceExe
  #define SourceExe "..\build\delphi\Win64\Release\PasClaw.exe"
#endif

#define MyAppName    "PasClaw"
#define MyAppExe     "PasClaw.exe"
#define MyAppPublisher "PasClaw contributors"
#define MyAppURL     "https://github.com/fmxexpress/pasclaw"

[Setup]
; A STABLE AppId -- keep it constant across versions so upgrades replace in place.
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
OutputBaseFilename=PasClaw-{#MyAppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; 64-bit only -- the Delphi build target is Win64. ("x64" works on all Inno 6;
; newer 6.3+ prefers "x64compatible" but that would fail to compile on <6.3.)
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
; Allow either a per-machine (admin, Program Files) or per-user install.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
; So Windows broadcasts the PATH change to running shells.
ChangesEnvironment=yes
UninstallDisplayIcon={app}\{#MyAppExe}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "addtopath"; Description: "Add PasClaw to PATH (run `pasclaw` from any terminal)"; GroupDescription: "Integration:"
Name: "webuiicon"; Description: "Create a ""PasClaw Web UI"" Start Menu shortcut"; GroupDescription: "Shortcuts:"

[Files]
Source: "{#SourceExe}"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\LICENSE";    DestDir: "{app}"; Flags: ignoreversion
Source: "..\README.md";  DestDir: "{app}"; Flags: ignoreversion
Source: "..\docs\*";     DestDir: "{app}\docs"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; Start the local gateway + web UI (prints the URL; a browser tab opens on the operator side).
Name: "{group}\PasClaw Web UI"; Filename: "{app}\{#MyAppExe}"; Parameters: "serve"; WorkingDir: "{app}"; Comment: "Start the PasClaw gateway + web UI"; Tasks: webuiicon
; A terminal already sitting in the install dir, for CLI use.
Name: "{group}\PasClaw Terminal"; Filename: "{cmd}"; Parameters: "/K ""{app}\{#MyAppExe}"" --help"; WorkingDir: "{app}"; Comment: "Open a terminal with PasClaw ready"
Name: "{group}\Documentation"; Filename: "{app}\docs\README.md"
Name: "{group}\Uninstall PasClaw"; Filename: "{uninstallexe}"

[Run]
; Offer to run first-time onboarding in a console once install finishes.
Filename: "{cmd}"; Parameters: "/K ""{app}\{#MyAppExe}"" onboard"; Description: "Run PasClaw onboarding now"; Flags: postinstall skipifsilent nowait
; Offer to open the docs.
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

{ Case-insensitive check for the app dir already being on PATH. }
function DirOnPath(const Dir: string): Boolean;
var
  Cur: string;
begin
  Result := False;
  if not RegQueryStringValue(PathRootKey, PathSubKey, 'Path', Cur) then Exit;
  Result := Pos(';' + Uppercase(RemoveBackslash(Dir)) + ';',
                ';' + Uppercase(Cur) + ';') > 0;
end;

procedure AddDirToPath(const Dir: string);
var
  Cur: string;
begin
  if DirOnPath(Dir) then Exit;
  if not RegQueryStringValue(PathRootKey, PathSubKey, 'Path', Cur) then Cur := '';
  if (Cur <> '') and (Copy(Cur, Length(Cur), 1) <> ';') then Cur := Cur + ';';
  RegWriteExpandStringValue(PathRootKey, PathSubKey, 'Path', Cur + RemoveBackslash(Dir));
end;

procedure RemoveDirFromPath(const Dir: string);
var
  Cur, D, Wrapped: string;
  P: Integer;
begin
  if not RegQueryStringValue(PathRootKey, PathSubKey, 'Path', Cur) then Exit;
  D := RemoveBackslash(Dir);
  Wrapped := ';' + Cur + ';';
  { Find ";Dir;" case-insensitively and drop the ";Dir", leaving one separator. }
  P := Pos(Uppercase(';' + D + ';'), Uppercase(Wrapped));
  if P = 0 then Exit;
  Delete(Wrapped, P, Length(D) + 1);
  if (Length(Wrapped) > 0) and (Wrapped[1] = ';') then Delete(Wrapped, 1, 1);
  if (Length(Wrapped) > 0) and (Wrapped[Length(Wrapped)] = ';') then Delete(Wrapped, Length(Wrapped), 1);
  RegWriteExpandStringValue(PathRootKey, PathSubKey, 'Path', Wrapped);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and WizardIsTaskSelected('addtopath') then
    AddDirToPath(ExpandConstant('{app}'));
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    RemoveDirFromPath(ExpandConstant('{app}'));
end;
