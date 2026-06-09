(*
  PasClaw.Skills.PasClawHub -- install / search skills from the
  pasclaw.dev hub, the first-party registry that PasClaw checks
  before falling through to clawhub.ai.

  Endpoints (base: https://pasclaw.dev/api/public/v1):

    GET /search?q=<query>&limit=<n>
       {"results":[{"slug":"…", "displayName":"…", "summary":"…",
                    "version":"…", "score":0.91}, …]}

    GET /skills/<slug>
       {"slug":"…", "displayName":"…", "summary":"…",
        "descriptionMarkdown":"…", "category":"…", "tags":[…],
        "downloadCount":42,
        "moderation":{"isMalwareBlocked":false,"isSuspicious":false},
        "latestVersion":{"version":"1.2.3"},
        "versions":[…]}

    GET /download?slug=<slug>&version=<version>
       {"slug":"…","version":"…","archiveSizeBytes":12345,
        "url":"<signed-url-to-zip>","expiresInSeconds":300}

  Difference vs ClawHub: pasclaw.dev's /download returns a JSON
  envelope with a SIGNED URL to the zip, not the zip itself. The
  installer does two hops -- GET /download → parse url → fetch url.

  Helper duplication: this unit copies UrlEncode / IsValidSlug /
  DownloadZip / CopyTree / RemoveTree / FindSkillRoot from
  PasClaw.Skills.ClawHub. The codebase has accepted that
  duplication across installers (ClawHub + GitHub both carry
  their own copies); a follow-up should factor them into a shared
  PasClaw.Skills.HubCommon unit. Out of scope for this PR.

  Cmd.Skills routing: bare slug "code-review" tries this hub
  first, falls back to ClawHub on 'not found' (404) or network
  error. `hub:<slug>` forces pasclaw.dev only. `clawhub:<slug>`
  forces ClawHub only.
*)
unit PasClaw.Skills.PasClawHub;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils;

type
  TPasClawHubResult = record
    Slug:        string;
    DisplayName: string;
    Summary:     string;
    Version:     string;
    Score:       Double;
  end;
  TPasClawHubResultArray = array of TPasClawHubResult;

function SearchPasClawHub(const Query: string; Limit: Integer;
                          out Results: TPasClawHubResultArray;
                          out ErrMsg: string): Boolean;

function InstallFromPasClawHub(const Slug, Version, DestRoot: string;
                                out InstalledName, ErrMsg: string): Boolean;

implementation

uses
  Classes, DateUtils,
  {$IFNDEF FPC}
  System.IOUtils,
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Providers.HTTP,
  PasClaw.Skills.Zip,
  PasClaw.Skills.Loader;

const
  PasClawHubBaseURL = 'https://pasclaw.dev/api/public/v1';
  SearchEndpoint    = '/search';
  SkillsEndpoint    = '/skills';
  DownloadEndpoint  = '/download';
  MaxZipBytes       = 64 * 1024 * 1024;
  RequestTimeoutSec = 30;

function PlatformTempDir: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
end;

function UniqueSuffix: string;
begin
  Result := Format('%d-%d',
                   [MilliSecondsBetween(Now, EncodeDate(1970, 1, 1)),
                    Random(1 shl 30)]);
end;

function UrlEncode(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if ((C >= 'A') and (C <= 'Z')) or
       ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or
       (C = '-') or (C = '_') or (C = '.') or (C = '~') then
      Result := Result + C
    else
      Result := Result + Format('%%%2.2X', [Ord(C)]);
  end;
end;

function IsValidSlug(const S: string): Boolean;
var
  i: Integer;
  C: Char;
begin
  Result := False;
  if (S = '') or (Length(S) > 128) then Exit;
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if not ( ((C >= 'a') and (C <= 'z')) or
             ((C >= '0') and (C <= '9')) or
             (C = '-') or (C = '_') ) then Exit;
  end;
  Result := True;
end;

function DoGetJSON(const URL: string; out Body, ErrMsg: string): Boolean;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Headers, 0);
  Resp := GetJSONURL(URL, Headers, RequestTimeoutSec);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    if Resp.StatusCode = 404 then ErrMsg := 'not found'
    else if Resp.ErrorMsg <> '' then ErrMsg := Format('http %d: %s', [Resp.StatusCode, Resp.ErrorMsg])
    else ErrMsg := Format('http %d', [Resp.StatusCode]);
    Exit;
  end;
  Body := Resp.Body;
  Result := True;
end;

function SearchPasClawHub(const Query: string; Limit: Integer;
                          out Results: TPasClawHubResultArray;
                          out ErrMsg: string): Boolean;
var
  URL, Body, S: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Res: TPasClawHubResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Results, 0);
  if Trim(Query) = '' then begin ErrMsg := 'empty query'; Exit; end;
  if Limit <= 0 then Limit := 10;
  if Limit > 100 then Limit := 100;   { OpenAPI caps at 100 }

  URL := PasClawHubBaseURL + SearchEndpoint +
         '?q=' + UrlEncode(Query) +
         '&limit=' + IntToStr(Limit);
  LogDebug('pasclaw-hub: GET %s', [URL]);
  if not DoGetJSON(URL, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed JSON response: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed JSON response';
      Exit;
    end;
    Arr := Root.ChildArray('results');
    if Arr = nil then Exit(True);   { empty result set, not an error }
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          S := Item.GetStr('slug', '');
          if S = '' then Continue;
          Res.Slug        := S;
          Res.DisplayName := Item.GetStr('displayName', S);
          Res.Summary     := Item.GetStr('summary',     '');
          Res.Version     := Item.GetStr('version',     '');
          Res.Score       := Item.GetFloat('score',     0);
          SetLength(Results, Length(Results) + 1);
          Results[High(Results)] := Res;
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

procedure FetchMetadata(const Slug: string; out LatestVersion: string;
                       out Blocked, Suspicious: Boolean);
{ Best-effort. Failure to fetch (network, 404, malformed JSON) leaves
  the out values at defaults: LatestVersion = '', Blocked = False,
  Suspicious = False -- same advisory semantics as ClawHub.FetchMetadata. }
var
  URL, Body, Err: string;
  Root, ModObj, VerObj: TJsonObject;
begin
  LatestVersion := '';
  Blocked := False;
  Suspicious := False;

  URL := PasClawHubBaseURL + SkillsEndpoint + '/' + UrlEncode(Slug);
  LogDebug('pasclaw-hub: GET %s', [URL]);
  if not DoGetJSON(URL, Body, Err) then
  begin
    LogDebug('pasclaw-hub: metadata fetch failed (%s) -- proceeding without it', [Err]);
    Exit;
  end;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      LogDebug('pasclaw-hub: metadata parse failed -- proceeding without it', []);
      Exit;
    end;
    if Root = nil then Exit;

    VerObj := Root.ChildObject('latestVersion');
    if VerObj <> nil then
    try
      LatestVersion := VerObj.GetStr('version', '');
    finally
      VerObj.Free;
    end;

    ModObj := Root.ChildObject('moderation');
    if ModObj <> nil then
    try
      Blocked    := ModObj.GetBool('isMalwareBlocked', False);
      Suspicious := ModObj.GetBool('isSuspicious',     False);
    finally
      ModObj.Free;
    end;
  finally
    Root.Free;
  end;
end;

function ResolveSignedDownload(const Slug, Version: string;
                                out SignedURL: string;
                                out ErrMsg: string): Boolean;
{ Pasclaw.dev's /download returns a JSON envelope with a short-lived
  signed URL pointing at the actual zip. Two-hop install path:
  this resolves the URL; DownloadZip below fetches it. }
var
  URL, Body: string;
  Root: TJsonObject;
begin
  Result := False;
  SignedURL := '';

  URL := PasClawHubBaseURL + DownloadEndpoint + '?slug=' + UrlEncode(Slug);
  if (Version <> '') and not SameText(Version, 'latest') then
    URL := URL + '&version=' + UrlEncode(Version);
  LogDebug('pasclaw-hub: GET %s', [URL]);
  if not DoGetJSON(URL, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed download envelope: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed download envelope';
      Exit;
    end;
    SignedURL := Root.GetStr('url', '');
    if SignedURL = '' then
    begin
      ErrMsg := 'download envelope missing "url" field';
      Exit;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function DownloadZip(const URL, DestPath: string; out ErrMsg: string): Boolean;
{ Streams the response straight into a TFileStream. The signed URL
  returns the actual zip bytes -- routing it through GetJSONURL
  would decode the body as UTF-8 and corrupt arbitrary binary, so
  use the dedicated GetURLToStream path (same approach ClawHub
  takes for its raw-bytes /download endpoint). Codex P1 on PR #129. }
var
  Strm: TFileStream;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Headers, 0);
  Strm := TFileStream.Create(DestPath, fmCreate);
  try
    Resp := GetURLToStream(URL, Strm, Headers, 60);
    if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
    begin
      if Resp.StatusCode = 404 then ErrMsg := 'not found'
      else if Resp.ErrorMsg <> '' then ErrMsg := Format('http %d: %s', [Resp.StatusCode, Resp.ErrorMsg])
      else ErrMsg := Format('http %d', [Resp.StatusCode]);
      Exit;
    end;
    if Strm.Size > MaxZipBytes then
    begin
      ErrMsg := Format('archive too large (%d bytes; cap %d)',
                       [Strm.Size, MaxZipBytes]);
      Exit;
    end;
    if Strm.Size = 0 then begin ErrMsg := 'empty archive'; Exit; end;
    Result := True;
  finally
    Strm.Free;
  end;
end;

procedure CopyTree(const SrcDir, DstDir: string);

  procedure CopyOne(const From_, To_: string);
  var
    A, B: TFileStream;
  begin
    A := TFileStream.Create(From_, fmOpenRead or fmShareDenyWrite);
    try
      B := TFileStream.Create(To_, fmCreate);
      try
        if A.Size > 0 then B.CopyFrom(A, A.Size);
      finally
        B.Free;
      end;
    finally
      A.Free;
    end;
  end;

var
  SR: TSearchRec;
  SrcPath, DstPath: string;
begin
  ForceDirectories(DstDir);
  if FindFirst(JoinPath(SrcDir, '*'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      SrcPath := JoinPath(SrcDir, SR.Name);
      DstPath := JoinPath(DstDir, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then CopyTree(SrcPath, DstPath)
      else                                   CopyOne(SrcPath, DstPath);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure RemoveTree(const Dir: string);
var
  SR: TSearchRec;
  Path: string;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Path := JoinPath(Dir, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then RemoveTree(Path)
      else SysUtils.DeleteFile(Path);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

function FindSkillRoot(const ExtractDir: string): string;
{ Returns the directory containing SKILL.md. The zip may put it at
  the root, or inside a single top-level wrapper directory. }
var
  SR: TSearchRec;
  WrapperCount: Integer;
  WrapperPath, Probe: string;
begin
  Result := '';
  if FileExists(JoinPath(ExtractDir, 'SKILL.md')) then
    Exit(ExtractDir);

  WrapperCount := 0;
  WrapperPath := '';
  if FindFirst(JoinPath(ExtractDir, '*'), faAnyFile, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        Inc(WrapperCount);
        WrapperPath := JoinPath(ExtractDir, SR.Name);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if (WrapperCount = 1) and (WrapperPath <> '') then
  begin
    Probe := JoinPath(WrapperPath, 'SKILL.md');
    if FileExists(Probe) then Exit(WrapperPath);
  end;
end;

function InstallFromPasClawHub(const Slug, Version, DestRoot: string;
                                out InstalledName, ErrMsg: string): Boolean;
var
  EffectiveVersion: string;
  LatestVersion: string;
  Blocked, Suspicious: Boolean;
  TempBase, ZipPath, ExtractDir, SrcDir, DstDir: string;
  Spec: TSkillSpec;
  ParseErr: string;
  SignedURL: string;
begin
  Result := False;
  InstalledName := '';
  ErrMsg := '';

  if not IsValidSlug(Slug) then
  begin
    ErrMsg := 'invalid slug: ' + Slug;
    Exit;
  end;
  InstalledName := Slug;
  DstDir := JoinPath(DestRoot, Slug);
  if DirectoryExists(DstDir) then
  begin
    ErrMsg := Format('"%s" already installed at %s -- run `pasclaw skills remove %s` first',
                     [Slug, DstDir, Slug]);
    Exit;
  end;
  if not ForceDirectories(DestRoot) then
  begin
    ErrMsg := 'cannot create skills root: ' + DestRoot;
    Exit;
  end;

  { Advisory metadata: lets us refuse malware-flagged installs and
    pick up `latestVersion` when the caller didn't pin one. Network
    failure here is not fatal -- we proceed with whatever the caller
    asked for. }
  FetchMetadata(Slug, LatestVersion, Blocked, Suspicious);
  if Blocked then
  begin
    ErrMsg := Format('pasclaw-hub flagged "%s" as malware -- refusing install', [Slug]);
    Exit;
  end;
  if Suspicious then
    LogWarn('pasclaw-hub: "%s" is flagged as suspicious -- proceeding anyway', [Slug]);

  EffectiveVersion := Version;
  if (EffectiveVersion = '') and (LatestVersion <> '') then
    EffectiveVersion := LatestVersion;

  if not ResolveSignedDownload(Slug, EffectiveVersion, SignedURL, ErrMsg) then Exit;

  TempBase := JoinPath(PlatformTempDir, 'pasclaw-hub-' + UniqueSuffix);
  if not ForceDirectories(TempBase) then
  begin
    ErrMsg := 'cannot create temp dir: ' + TempBase;
    Exit;
  end;
  ZipPath    := JoinPath(TempBase, 'archive.zip');
  ExtractDir := JoinPath(TempBase, 'extracted');
  try
    LogDebug('pasclaw-hub: fetching signed URL', []);
    if not DownloadZip(SignedURL, ZipPath, ErrMsg) then
    begin
      ErrMsg := 'download failed: ' + ErrMsg;
      Exit;
    end;
    if not ExtractZipToDir(ZipPath, ExtractDir, ErrMsg) then Exit;

    SrcDir := FindSkillRoot(ExtractDir);
    if SrcDir = '' then
    begin
      ErrMsg := 'archive has no SKILL.md (neither at root nor in a single top-level directory)';
      Exit;
    end;

    if not ParseSkillMD(JoinPath(SrcDir, 'SKILL.md'), Spec, ParseErr) then
    begin
      ErrMsg := 'SKILL.md is invalid: ' + ParseErr;
      Exit;
    end;

    CopyTree(SrcDir, DstDir);
    LogInfo('pasclaw-hub: installed %s (v=%s) at %s',
            [Slug, EffectiveVersion, DstDir]);
    Result := True;
  finally
    RemoveTree(TempBase);
    if (not Result) and DirectoryExists(DstDir) then RemoveTree(DstDir);
  end;
end;

end.
