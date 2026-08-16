(*
  PasClaw.Skills.ClawHub - install / search skills from the public
  ClawHub registry (https://clawhub.ai), the slug-based hub that
  picoclaw and nanobot standardised on.

  Endpoints (the same paths picoclaw's clawhub_registry.go targets):

    GET /api/v1/search?q=<query>&limit=<n>
       {"results":[{"score":0.91, "slug":"code-review",
                    "displayName":"Code review",
                    "summary":"Static review …",
                    "version":"1.2.3"}, …]}

    GET /api/v1/skills/<slug>
       {"slug":"code-review",
        "displayName":"Code review",
        "summary":"…",
        "latestVersion":{"version":"1.2.3"},
        "moderation":{"isMalwareBlocked":false,"isSuspicious":false}}

    GET /api/v1/download?slug=<slug>&version=<version>
       application/zip

  No authentication is required for the public skill catalogue;
  ClawHubConfig.AuthToken (picoclaw's term) is reserved for private
  skill packs and not exposed here.

  Install pipeline:
    1. Parse slug + optional @version.
    2. (Optional) fetch metadata so we can warn about
       moderation flags. Failure to fetch metadata does not block
       the install -- picoclaw treats the metadata fetch as advisory.
    3. Refuse if the destination directory already exists.
    4. GET the zip into a temp file (`download` endpoint).
    5. Extract through PasClaw.Skills.Zip.
    6. Validate by re-parsing the installed SKILL.md.
    7. Copy the extracted tree into workspace/skills/<slug>/.

  Output sharing the PasClaw.Skills.GitHub shape lets Cmd.Skills
  dispatch on the target form (slug vs owner/repo vs local) and
  delegate without each path knowing the other exists.
*)
unit PasClaw.Skills.ClawHub;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

type
  TClawHubResult = record
    Slug:        string;
    DisplayName: string;
    Summary:     string;
    Version:     string;
    Score:       Double;
  end;
  TClawHubResultArray = array of TClawHubResult;

function SearchClawHub(const Query: string; Limit: Integer;
                       out Results: TClawHubResultArray;
                       out ErrMsg: string): Boolean;

function InstallFromClawHub(const Slug, Version, DestRoot: string;
                            out InstalledName, ErrMsg: string): Boolean;

implementation

uses
  SysUtils, Classes, DateUtils,
  {$IFNDEF FPC}
  System.IOUtils,
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Skills.Provenance,
  PasClaw.Providers.HTTP,
  PasClaw.Skills.Zip,
  PasClaw.Skills.Loader;

const
  ClawHubBaseURL  = 'https://clawhub.ai';
  SearchEndpoint  = '/api/v1/search';
  SkillsEndpoint  = '/api/v1/skills';
  DownloadEndpoint = '/api/v1/download';
  MaxZipBytes     = 64 * 1024 * 1024;

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
{ Minimal percent-encoder for query-string values. Encodes everything
  outside the URL-safe set per RFC 3986; conservative is fine here. }
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
{ ClawHub slugs are lowercase-alphanumeric with optional hyphens or
  underscores. Reject anything else early so we do not turn a typo
  into a 404 round-trip. Matches picoclaw's ValidateSkillIdentifier
  in spirit. }
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
  Resp := GetJSONURL(URL, Headers, 30);
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

function SearchClawHub(const Query: string; Limit: Integer;
                       out Results: TClawHubResultArray;
                       out ErrMsg: string): Boolean;
var
  URL, Body, S: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Res: TClawHubResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Results, 0);
  if Trim(Query) = '' then begin ErrMsg := 'empty query'; Exit; end;
  if Limit <= 0 then Limit := 10;

  URL := ClawHubBaseURL + SearchEndpoint +
         '?q=' + UrlEncode(Query) +
         '&limit=' + IntToStr(Limit);
  LogDebug('clawhub: GET %s', [URL]);
  if not DoGetJSON(URL, Body, ErrMsg) then Exit;

  { Same EPasClawJSON guard as FetchMetadata: TJsonObject.Parse
    raises rather than returning nil, so a bad-bytes-from-server
    case would otherwise propagate up to Cmd.Skills as an
    unhandled exception. Here a parse failure IS a search error
    (unlike the metadata path, which is best-effort), so surface
    it through ErrMsg. }
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
  Suspicious = False. The caller treats the metadata as advisory. }
var
  URL, Body, Err: string;
  Root, LV, Mod_: TJsonObject;
begin
  LatestVersion := '';
  Blocked       := False;
  Suspicious    := False;
  URL := ClawHubBaseURL + SkillsEndpoint + '/' + UrlEncode(Slug);
  if not DoGetJSON(URL, Body, Err) then
  begin
    LogDebug('clawhub: metadata fetch failed (%s) -- proceeding without it', [Err]);
    Exit;
  end;
  { TJsonObject.Parse raises EPasClawJSON on malformed JSON rather
    than returning nil. The metadata fetch is best-effort -- a
    parsing failure should leave LatestVersion / Blocked /
    Suspicious at their defaults and let the install continue. }
  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        LogDebug('clawhub: metadata JSON parse failed (%s) -- proceeding without it',
                 [E.Message]);
        Exit;
      end;
    end;
    if Root = nil then Exit;
    LV := Root.ChildObject('latestVersion');
    if LV <> nil then
    try
      LatestVersion := LV.GetStr('version', '');
    finally
      LV.Free;
    end;
    Mod_ := Root.ChildObject('moderation');
    if Mod_ <> nil then
    try
      Blocked    := Mod_.GetBool('isMalwareBlocked', False);
      Suspicious := Mod_.GetBool('isSuspicious',     False);
    finally
      Mod_.Free;
    end;
  finally
    Root.Free;
  end;
end;

function DownloadZip(const URL, DestPath: string; out ErrMsg: string): Boolean;
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

  procedure Walk(const FromDir, ToDir: string);
  var
    SR: TSearchRec;
    Src, Dst: string;
  begin
    ForceDirectories(ToDir);
    if FindFirst(JoinPath(FromDir, '*'), faAnyFile, SR) <> 0 then Exit;
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        Src := JoinPath(FromDir, SR.Name);
        Dst := JoinPath(ToDir,   SR.Name);
        if (SR.Attr and faDirectory) <> 0 then Walk(Src, Dst)
        else CopyOne(Src, Dst);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
  end;

begin
  Walk(SrcDir, DstDir);
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
      else try DeleteFile(Path); except end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  try RemoveDir(Dir); except end;
end;

function FindSkillRoot(const ExtractDir: string): string;
{ ClawHub archives, like GitHub's codeload, wrap entries in a single
  top-level directory. Return its path. If there is no wrapper (the
  zip has SKILL.md at its root) return ExtractDir verbatim. }
var
  SR: TSearchRec;
  Found, SkillMdAtRoot: Boolean;
  Candidate: string;
begin
  Result := ExtractDir;
  SkillMdAtRoot := FileExists(JoinPath(ExtractDir, 'SKILL.md'));
  if SkillMdAtRoot then Exit;
  Found := False;
  if FindFirst(JoinPath(ExtractDir, '*'), faDirectory, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then Continue;
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Candidate := JoinPath(ExtractDir, SR.Name);
      if FileExists(JoinPath(Candidate, 'SKILL.md')) then
      begin
        Result := Candidate;
        Found := True;
        Break;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  if not Found then Result := '';
end;

function InstallFromClawHub(const Slug, Version, DestRoot: string;
                            out InstalledName, ErrMsg: string): Boolean;
var
  URL, TempBase, ZipPath, ExtractDir, SrcDir, DstDir: string;
  EffectiveVersion, LatestVersion: string;
  Blocked, Suspicious: Boolean;
  Spec: TSkillSpec;
  ParseErr: string;
  ArchiveDigest, ProvErr, KnownDigest: string;
  Prov: TSkillProvenance;
begin
  Result := False;
  InstalledName := '';
  ErrMsg := '';

  if not IsValidSlug(Slug) then
  begin
    ErrMsg := Format('invalid clawhub slug "%s" -- expected lowercase ' +
                     'letters, digits, "-", and "_" only', [Slug]);
    Exit;
  end;

  InstalledName := Slug;
  DstDir := JoinPath(DestRoot, InstalledName);
  if DirectoryExists(DstDir) then
  begin
    ErrMsg := Format('skill "%s" already exists at %s -- remove it first',
                     [InstalledName, DstDir]);
    Exit;
  end;
  if not ForceDirectories(DestRoot) then
  begin
    ErrMsg := 'cannot create skills root: ' + DestRoot;
    Exit;
  end;

  { Metadata fetch is advisory -- failure does not block the install,
    but a successful fetch lets us reject malware-flagged skills and
    surface the latest version when the caller did not pin one. }
  FetchMetadata(Slug, LatestVersion, Blocked, Suspicious);
  if Blocked then
  begin
    ErrMsg := Format('clawhub flagged "%s" as malware -- refusing install', [Slug]);
    Exit;
  end;
  if Suspicious then
    LogWarn('clawhub: "%s" is flagged as suspicious -- proceeding anyway', [Slug]);

  EffectiveVersion := Version;
  if (EffectiveVersion = '') and (LatestVersion <> '') then
    EffectiveVersion := LatestVersion;

  URL := ClawHubBaseURL + DownloadEndpoint + '?slug=' + UrlEncode(Slug);
  if (EffectiveVersion <> '') and not SameText(EffectiveVersion, 'latest') then
    URL := URL + '&version=' + UrlEncode(EffectiveVersion);

  TempBase := JoinPath(PlatformTempDir, 'pasclaw-clawhub-' + UniqueSuffix);
  if not ForceDirectories(TempBase) then
  begin
    ErrMsg := 'cannot create temp dir: ' + TempBase;
    Exit;
  end;
  ZipPath    := JoinPath(TempBase, 'archive.zip');
  ExtractDir := JoinPath(TempBase, 'extracted');
  try
    LogDebug('clawhub: GET %s', [URL]);
    if not DownloadZip(URL, ZipPath, ErrMsg) then
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

    (* Provenance. ClawHub signs nothing and publishes no digest, so
       this cannot prove the download was honest -- it records what we
       actually received so any later change is detectable, and it
       refuses the reinstall-substitution case where the registry
       serves different bytes for a slug+version already seen on this
       machine. See PasClaw.Skills.Provenance for the rungs this
       deliberately does not claim. *)
    ArchiveDigest := FileSha256(ZipPath);
    if ArchiveDigest = '' then
      LogWarn('clawhub: could not hash the downloaded archive for "%s" -- ' +
              'installing without a provenance record', [Slug])
    else
    begin
      { Drift check BEFORE anything is copied, so a refusal leaves the
        skills tree untouched. A pinned version whose bytes changed is
        not an upgrade -- it is the same name serving different code,
        which is the shape ClawHavoc used. }
      case CheckLock(DestRoot, Slug, EffectiveVersion, ArchiveDigest, KnownDigest) of
        lkDrift:
          begin
            ErrMsg := Format(
              'refusing install: "%s" version "%s" was previously installed ' +
              'from an archive with sha256 %s, but the registry now serves ' +
              '%s. Same name, different code. If the change is expected, ' +
              'remove that entry from %s and reinstall.',
              [Slug, EffectiveVersion, Copy(KnownDigest, 1, 16),
               Copy(ArchiveDigest, 1, 16),
               JoinPath(DestRoot, 'skills.lock.json')]);
            LogWarn('%s', [ErrMsg]);
            Exit;
          end;
        lkMatch:
          LogDebug('clawhub: %s@%s archive digest matches the lock',
                   [Slug, EffectiveVersion]);
        lkFirstSight:
          LogDebug('clawhub: %s@%s not seen before -- recording its digest',
                   [Slug, EffectiveVersion]);
      end;
    end;

    CopyTree(SrcDir, DstDir);

    if ArchiveDigest <> '' then
    begin
      Prov := BuildProvenance(DstDir, 'clawhub', Slug, EffectiveVersion,
                              ArchiveDigest);
      if not WriteProvenance(DstDir, Prov, ProvErr) then
        LogWarn('clawhub: installed %s but could not write its provenance ' +
                'record: %s', [Slug, ProvErr]);
      RecordInLock(DestRoot, Slug, EffectiveVersion, ArchiveDigest);
      LogInfo('clawhub: installed %s (v=%s, %d file(s), archive sha256 %s) at %s',
              [Slug, EffectiveVersion, Length(Prov.Files),
               Copy(ArchiveDigest, 1, 12), DstDir]);
    end
    else
      LogInfo('clawhub: installed %s (v=%s) at %s',
              [Slug, EffectiveVersion, DstDir]);
    Result := True;
  finally
    RemoveTree(TempBase);
    if (not Result) and DirectoryExists(DstDir) then RemoveTree(DstDir);
  end;
end;

end.
