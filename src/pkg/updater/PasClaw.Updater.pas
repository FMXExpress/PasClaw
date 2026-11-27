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
  {$IFNDEF FPC}{$IFDEF MSWINDOWS} Winapi.Windows, {$ENDIF}{$ENDIF}
  {$IFNDEF FPC}{$IFDEF POSIX} Posix.SysStat, Posix.UniStd, Posix.Errno, {$ENDIF}{$ENDIF}
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

function LastOSErrno: Integer;
(* Cross-compiler errno read for the "rename failed" diagnostic. Skips
   System.SysUtils.GetLastOSError because dcc64 has refused it on the
   builds we've hit: on Delphi Linux it isn't declared at all (E2003
   was the original report -- PR #229), and on dcc64 Windows the
   declaration's call-through to GetLastError won't resolve unless
   Winapi.Windows is in scope, so leaning on the SysUtils wrapper
   would still re-import the Windows API anyway. Going straight to the
   per-platform primitive is one fewer indirection and one fewer
   surprise. *)
begin
  {$IFDEF FPC}
  Result := GetLastOSError;
  {$ELSE}
  {$IFDEF MSWINDOWS}
  Result := Integer(GetLastError);
  {$ELSE}
  Result := errno;
  {$ENDIF}
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

{ The dotted number at the front of a version, and what follows it:
  v0.1.5-36-g4f611ca -> '0.1.5' + '-36-g4f611ca'. }
procedure SplitVersion(const V: string; out Core, Suffix: string);
var
  S: string;
  i: Integer;
begin
  S := NormalizeVersion(V);
  i := 1;
  while (i <= Length(S)) and (((S[i] >= '0') and (S[i] <= '9')) or (S[i] = '.')) do
    Inc(i);
  Core   := Copy(S, 1, i - 1);
  Suffix := Copy(S, i, MaxInt);
end;

{ `git describe` past a tag: -<commits>-g<hash>, maybe -dirty after it.
  Commits is how far past the tag; -1 when Suffix is not that shape. }
function GitDescribeCommits(const Suffix: string): Integer;
var
  i, Start: Integer;
  Rest: string;
begin
  Result := -1;
  if (Length(Suffix) < 4) or (Suffix[1] <> '-') then Exit;
  i := 2;
  Start := i;
  while (i <= Length(Suffix)) and (Suffix[i] >= '0') and (Suffix[i] <= '9') do Inc(i);
  if (i = Start) or (i + 1 > Length(Suffix)) or (Suffix[i] <> '-') or (Suffix[i + 1] <> 'g') then Exit;
  Inc(i, 2);
  Start := i;
  while (i <= Length(Suffix)) and
        (((Suffix[i] >= '0') and (Suffix[i] <= '9')) or
         ((Suffix[i] >= 'a') and (Suffix[i] <= 'f'))) do Inc(i);
  if i = Start then Exit;
  Rest := Copy(Suffix, i, MaxInt);
  if (Rest <> '') and (Rest <> '-dirty') then Exit;
  Result := StrToIntDef(Copy(Suffix, 2, Pos('-g', Suffix) - 2), -1);
end;

(* -1 when A is older than B, 0 the same, +1 newer. The dotted numbers
   decide; with the same numbers, a `git describe` suffix is AFTER the
   release (a dev build on top of v0.1.5 is up to date) and any other
   suffix BEFORE it (v0.2.0-rc1 is older than v0.2.0).

   The numbers used to be read straight off the whole string by ParseNum,
   which stops at a character that is neither digit nor dot without moving
   past it: from a dev build (v0.1.5-36-g4f611ca against the latest tag
   v0.1.5) the loop below never ended, and `pasclaw update --check` spun at
   full CPU. Reading only the dotted part, every character is consumed. *)
function CompareVersions(const A, B: string): Integer;
var
  Pa, Pb: Integer;
  Na, Nb: Integer;
  Ca, Cb, Xa, Xb: string;
  Ga, Gb, Ra, Rb: Integer;
begin
  SplitVersion(A, Ca, Xa);
  SplitVersion(B, Cb, Xb);
  Pa := 1; Pb := 1;
  while (Pa <= Length(Ca)) or (Pb <= Length(Cb)) do
  begin
    if Pa <= Length(Ca) then Na := ParseNum(Ca, Pa) else Na := 0;
    if Pb <= Length(Cb) then Nb := ParseNum(Cb, Pb) else Nb := 0;
    if Na < Nb then Exit(-1);
    if Na > Nb then Exit( 1);
  end;
  if Xa = Xb then Exit(0);
  { Rank: a pre-release below the release, a dev build above it. }
  Ga := GitDescribeCommits(Xa);
  Gb := GitDescribeCommits(Xb);
  if Xa = '' then Ra := 0 else if Ga >= 0 then Ra := 1 else Ra := -1;
  if Xb = '' then Rb := 0 else if Gb >= 0 then Rb := 1 else Rb := -1;
  if Ra < Rb then Exit(-1);
  if Ra > Rb then Exit( 1);
  if (Ga >= 0) and (Gb >= 0) then
  begin
    if Ga < Gb then Exit(-1);
    if Ga > Gb then Exit( 1);
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
