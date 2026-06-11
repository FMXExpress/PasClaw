(*
  PasClaw.Updater - self-update over GitHub releases.

  Flow:
    1. GET https://api.github.com/repos/<owner>/<repo>/releases/latest
    2. Parse tag_name (e.g. "v0.2.0") and compare against the build version.
    3. Pick the asset matching the host OS+CPU (naming convention:
       pasclaw_<os>_<cpu>[.exe]).
    4. Download to <binary>.new alongside the current binary.
    5. On POSIX, rename(<binary>.new, <binary>) -- replacing an executable
       while it runs is legal on Linux/macOS.
    6. On Windows, leave <binary>.new in place and print instructions; an
       upgrade helper or restart script does the actual swap. (Phase 10
       can add a Windows-native MoveFileEx/MOVEFILE_DELAY_UNTIL_REBOOT path.)

  No release exists yet; the code paths are exercised by `pasclaw update
  --check` which only queries the API.
*)
unit PasClaw.Updater;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TReleaseInfo = record
    TagName:    string;
    Name:       string;
    HtmlUrl:    string;
    AssetUrl:   string;
    AssetName:  string;
    AssetSize:  Int64;
    Found:      Boolean;
  end;

function HostPlatformSuffix: string;
function CompareVersions(const A, B: string): Integer;     { -1, 0, +1 }
function NormalizeVersion(const V: string): string;
function FetchLatestRelease(const Owner, Repo: string;
                            out Info: TReleaseInfo;
                            out ErrMsg: string): Boolean;
function DownloadAsset(const URL, DestPath: string;
                       out ErrMsg: string): Boolean;
function InstallUpdate(const DownloadedPath, TargetBinary: string;
                       out ErrMsg: string): Boolean;

implementation

uses
  Classes,
  {$IFDEF FPC}{$IFDEF UNIX} BaseUnix, {$ENDIF}{$ENDIF}
  {$IFNDEF FPC}{$IFDEF POSIX} Posix.SysStat, Posix.UniStd, Posix.Errno, {$ENDIF}{$ENDIF}
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

function LastOSErrno: Integer;
{ Cross-compiler errno read for the "rename failed" diagnostic.
  GetLastOSError is in System.SysUtils on Delphi Windows (returns
  GetLastError) and on FPC (returns fpgeterrno / errno), but dcc64
  Linux doesn't expose it as of the version we target -- E2003 on
  the call site. Read errno directly via Posix.Errno there. }
begin
  {$IFNDEF FPC}{$IFDEF POSIX}
  Result := errno;
  {$ELSE}
  Result := GetLastOSError;
  {$ENDIF}{$ELSE}
  Result := GetLastOSError;
  {$ENDIF}
end;

function HostPlatformSuffix: string;
begin
  {$IF DEFINED(MSWINDOWS) OR DEFINED(WINDOWS)}
    { Delphi 13's Windows-on-ARM target (when it ships) defines
      CPUARM64; FPC's Windows-aarch64 cross-build defines
      CPUAARCH64. Check both so the right suffix lands regardless
      of compiler. For the 64-bit Windows-x64 case, Delphi defines
      CPU64BITS (the Embarcadero canonical name for "running on a
      64-bit CPU") and FPC defines CPUX86_64; the older CPU_X64 /
      CPU64 spellings we used to check aren't standard on either
      compiler. (Codex P2 on PR #115.) }
    {$IF DEFINED(CPUARM64) OR DEFINED(CPUAARCH64)}
      Result := 'windows_arm64.exe';
    {$ELSEIF DEFINED(CPUX86_64) OR DEFINED(CPU64BITS)}
      Result := 'windows_amd64.exe';
    {$ELSE}
      Result := 'windows_386.exe';
    {$ENDIF}
  {$ELSEIF DEFINED(DARWIN)}
    {$IF DEFINED(CPUAARCH64) OR DEFINED(CPU_ARM64)}
      Result := 'darwin_arm64';
    {$ELSE}
      Result := 'darwin_amd64';
    {$ENDIF}
  {$ELSEIF DEFINED(LINUX) OR DEFINED(UNIX)}
    {$IF DEFINED(CPUAARCH64) OR DEFINED(CPU_ARM64)}
      Result := 'linux_arm64';
    {$ELSEIF DEFINED(CPUX86_64) OR DEFINED(CPU_X64)}
      Result := 'linux_amd64';
    {$ELSE}
      Result := 'linux_386';
    {$ENDIF}
  {$ELSE}
    Result := 'unknown';
  {$ENDIF}
end;

function NormalizeVersion(const V: string): string;
var
  s: string;
begin
  s := Trim(V);
  if (s <> '') and ((s[1] = 'v') or (s[1] = 'V')) then
    s := Copy(s, 2, MaxInt);
  Result := s;
end;

function ParseNum(const S: string; var Pos: Integer): Integer;
var
  N: string;
begin
  N := '';
  while (Pos <= Length(S)) and (S[Pos] >= '0') and (S[Pos] <= '9') do
  begin
    N := N + S[Pos];
    Inc(Pos);
  end;
  if N = '' then Result := 0 else Result := StrToIntDef(N, 0);
  if (Pos <= Length(S)) and (S[Pos] = '.') then Inc(Pos);
end;

function CompareVersions(const A, B: string): Integer;
var
  Pa, Pb: Integer;
  Na, Nb: Integer;
  Sa, Sb: string;
begin
  Sa := NormalizeVersion(A);
  Sb := NormalizeVersion(B);
  Pa := 1; Pb := 1;
  while (Pa <= Length(Sa)) or (Pb <= Length(Sb)) do
  begin
    if Pa <= Length(Sa) then Na := ParseNum(Sa, Pa) else Na := 0;
    if Pb <= Length(Sb) then Nb := ParseNum(Sb, Pb) else Nb := 0;
    if Na < Nb then Exit(-1);
    if Na > Nb then Exit( 1);
  end;
  Result := 0;
end;

function PickAsset(Assets: TJsonArray; const Suffix: string;
                   out Url, Name: string; out Size: Int64): Boolean;
var
  i: Integer;
  Obj: TJsonObject;
  AName: string;
begin
  Url := '';
  Name := '';
  Size := 0;
  Result := False;
  if Assets = nil then Exit;
  for i := 0 to Assets.Count - 1 do
  begin
    Obj := Assets.ItemObject(i);
    if Obj = nil then Continue;
    try
      AName := Obj.GetStr('name', '');
      if (AName <> '') and (Pos(LowerCase(Suffix), LowerCase(AName)) > 0) then
      begin
        Name := AName;
        Url  := Obj.GetStr('browser_download_url', '');
        Size := Obj.GetInt('size', 0);
        Exit(True);
      end;
    finally
      Obj.Free;
    end;
  end;
end;

function FetchLatestRelease(const Owner, Repo: string;
                            out Info: TReleaseInfo;
                            out ErrMsg: string): Boolean;
var
  Url: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root: TJsonObject;
  Assets: TJsonArray;
  Suffix: string;
begin
  ErrMsg := '';
  FillChar(Info, SizeOf(Info), 0);
  SetLength(Headers, 2);
  Headers[0] := MakeHeader('Accept',     'application/vnd.github+json');
  Headers[1] := MakeHeader('X-GitHub-Api-Version', '2022-11-28');
  Url := Format('https://api.github.com/repos/%s/%s/releases/latest', [Owner, Repo]);
  Resp := GetJSONURL(Url, Headers, 30);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('github API status=%d', [Resp.StatusCode]);
    Exit(False);
  end;

  Root := TJsonObject.Parse(Resp.Body);
  if Root = nil then begin ErrMsg := 'bad JSON from github'; Exit(False); end;
  try
    Info.TagName := Root.GetStr('tag_name', '');
    Info.Name    := Root.GetStr('name',     Info.TagName);
    Info.HtmlUrl := Root.GetStr('html_url', '');
    Info.Found   := Info.TagName <> '';
    Suffix := HostPlatformSuffix;
    Assets := Root.ChildArray('assets');
    if Assets <> nil then
    try
      PickAsset(Assets, Suffix, Info.AssetUrl, Info.AssetName, Info.AssetSize);
    finally
      Assets.Free;
    end;
  finally
    Root.Free;
  end;
  Result := Info.Found;
end;

function DownloadAsset(const URL, DestPath: string;
                       out ErrMsg: string): Boolean;
var
  Empty: array of THeaderPair;
  Resp: THTTPResult;
  Strm: TFileStream;
  Bytes: TBytes;
begin
  ErrMsg := '';
  SetLength(Empty, 0);
  { GitHub redirects asset downloads to a signed CDN URL; Indy follows
    redirects by default. The asset URL is a "browser_download_url" so a
    plain GET is enough. }
  Resp := GetJSONURL(URL, Empty, 120);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('download status=%d', [Resp.StatusCode]);
    Exit(False);
  end;
  try
    Strm := TFileStream.Create(DestPath, fmCreate);
    try
      if Resp.Body <> '' then
      begin
        Bytes := TEncoding.UTF8.GetBytes(Resp.Body);
        if Length(Bytes) > 0 then
          Strm.WriteBuffer(Bytes[0], Length(Bytes));
      end;
    finally
      Strm.Free;
    end;
  except
    on E: Exception do
    begin
      ErrMsg := 'write failed: ' + E.Message;
      Exit(False);
    end;
  end;
  Result := True;
end;

function InstallUpdate(const DownloadedPath, TargetBinary: string;
                       out ErrMsg: string): Boolean;
begin
  ErrMsg := '';
  {$IFDEF MSWINDOWS}
  { Windows can't replace a running .exe; leave the .new file in place. }
  LogInfo('updater: new binary at %s -- restart pasclaw and move it over.', [DownloadedPath]);
  Result := True;
  {$ELSE}
  if not RenameFile(DownloadedPath, TargetBinary) then
  begin
    ErrMsg := 'rename failed (errno=' + IntToStr(LastOSErrno) + ')';
    Exit(False);
  end;
  {$IFDEF FPC}{$IFDEF UNIX}
  { Best-effort chmod 0755; ignore errors. }
  FpChmod(TargetBinary, &755);
  {$ENDIF}{$ENDIF}
  {$IFNDEF FPC}{$IFDEF POSIX}
  Posix.SysStat.chmod(PAnsiChar(AnsiString(TargetBinary)), $1ED);  { 0755 }
  {$ENDIF}{$ENDIF}
  Result := True;
  {$ENDIF}
end;

end.
