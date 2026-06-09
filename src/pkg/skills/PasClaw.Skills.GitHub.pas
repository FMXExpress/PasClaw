(*
  PasClaw.Skills.GitHub - install a skill from a GitHub repository.

  Surface:

    InstallFromGitHub(Target, DestRoot, out InstalledName, out ErrMsg)

  Target shapes accepted:

    owner/repo                  Install the repo's root SKILL.md.
    owner/repo/sub/path         Install the SKILL.md at sub/path/.
    owner/repo@branch           Pin to a branch / tag / commit instead
    owner/repo/sub/path@ref     of trying main then master.

  How it works (no clone / no git binary required -- PasClaw stays an
  Indy-only HTTP client):

    1. Parse Target into (Owner, Repo, SubPath, Ref).
    2. Download a zip snapshot of the repo from codeload.github.com.
       If Ref is empty, try `main` first and fall back to `master` on
       404. codeload returns a 302 to S3 and the zip itself; Indy
       follows redirects so this is one Get call.
    3. Save the zip to a temp file (memory-streaming the extract path
       would also work but the disk path is simpler and the zips are
       small enough that the I/O is invisible).
    4. Extract through PasClaw.Skills.Zip (FPC: Zipper, Delphi:
       System.Zip -- both natively ship a zip implementation; no tar
       dependency).
    5. GitHub's zip wraps everything in a `<repo>-<ref>/` directory.
       Strip that prefix; locate the SKILL.md at the requested
       SubPath; copy the containing directory tree into
       `<DestRoot>/<InstalledName>/`.
    6. Validate: the installed directory must contain SKILL.md, and
       ParseSkillMD must accept it. Otherwise remove the partial
       install and return an error.

  Naming: InstalledName defaults to the last segment of SubPath, or
  the repo name when SubPath is empty. The skill's own `name:`
  frontmatter is not used for the directory -- directory name is what
  the model sees in the system prompt's SKILLS section path, and
  matching the GitHub layout makes it easier for users to find the
  source.

  Overwrite policy: if the destination directory already exists we
  refuse and return an error. The caller (Cmd.Skills) surfaces a
  hint about re-running with a different name or removing the
  existing entry first. No `--force` yet; can add when there is real
  demand.

  Not in scope here (Phase 3+):
    - ClawHub registry -- separate HTTP API + slug resolution
    - Multiple registries in one install command
    - Lockfile / version pinning per skill
    - Signed downloads
*)
unit PasClaw.Skills.GitHub;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

function InstallFromGitHub(const Target, DestRoot: string;
                           out InstalledName, ErrMsg: string): Boolean;

implementation

uses
  SysUtils, Classes, DateUtils, StrUtils,
  {$IFNDEF FPC}
  System.IOUtils,
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Providers.HTTP,
  PasClaw.Skills.Zip,
  PasClaw.Skills.Loader;

function PlatformTempDir: string;
begin
  {$IFDEF FPC}
  Result := GetTempDir;
  {$ELSE}
  Result := TPath.GetTempPath;
  {$ENDIF}
end;

function UniqueSuffix: string;
{ A 16-digit-ish unique suffix using milliseconds since epoch + a
  random tail. Avoids GetTickCount (Windows-only) and the FPC/Delphi
  differences in epoch helpers. Collision probability across two
  installs in the same millisecond is vanishingly small for an
  interactive CLI; the random tail covers the rest. }
begin
  Result := Format('%d-%d',
                   [MilliSecondsBetween(Now, EncodeDate(1970, 1, 1)),
                    Random(1 shl 30)]);
end;

const
  MaxZipBytes = 64 * 1024 * 1024;  { GitHub repo snapshot cap }

type
  TTarget = record
    Owner:   string;
    Repo:    string;
    SubPath: string;   { '' for repo root, or 'sub/path' (no leading/trailing slash) }
    Ref:     string;   { '' means: try main then master; else use as-is }
  end;

function ParseTarget(const Target: string; out T: TTarget; out ErrMsg: string): Boolean;
var
  S, Spec, Rest: string;
  AtPos, Slash1, Slash2: Integer;
begin
  Result := False;
  ErrMsg := '';
  T.Owner   := '';
  T.Repo    := '';
  T.SubPath := '';
  T.Ref     := '';

  S := Trim(Target);
  if S = '' then begin ErrMsg := 'empty target'; Exit; end;

  { Split on '@' for the ref. The first '@' separates spec from ref;
    GitHub repo names cannot contain '@' so this is unambiguous. }
  AtPos := Pos('@', S);
  if AtPos > 0 then
  begin
    Spec  := Copy(S, 1, AtPos - 1);
    T.Ref := Trim(Copy(S, AtPos + 1, MaxInt));
  end
  else
    Spec := S;

  Slash1 := Pos('/', Spec);
  if Slash1 <= 0 then
  begin
    ErrMsg := 'target must look like "owner/repo[/sub/path][@ref]"';
    Exit;
  end;
  T.Owner := Copy(Spec, 1, Slash1 - 1);
  Rest    := Copy(Spec, Slash1 + 1, MaxInt);

  Slash2 := Pos('/', Rest);
  if Slash2 <= 0 then
  begin
    T.Repo    := Rest;
    T.SubPath := '';
  end
  else
  begin
    T.Repo    := Copy(Rest, 1, Slash2 - 1);
    T.SubPath := Copy(Rest, Slash2 + 1, MaxInt);
  end;

  if (T.Owner = '') or (T.Repo = '') then
  begin
    ErrMsg := 'malformed target -- both owner and repo are required';
    Exit;
  end;
  Result := True;
end;

function LastPathSegment(const P: string): string;
var
  i: Integer;
begin
  Result := P;
  for i := Length(P) downto 1 do
    if (P[i] = '/') or (P[i] = '\') then
    begin
      Result := Copy(P, i + 1, MaxInt);
      Exit;
    end;
end;

function CodeloadBranchURL(const Owner, Repo, Branch: string): string;
{ Specific to branches. Used for the implicit `main` then `master`
  fallback when the user did not pin a ref -- `refs/heads/<branch>`
  forces a branch lookup so a tag or PR-branch with the same name
  as a default branch never wins by accident. }
begin
  Result := Format('https://codeload.github.com/%s/%s/zip/refs/heads/%s',
                   [Owner, Repo, Branch]);
end;

function CodeloadAnyRefURL(const Owner, Repo, Ref: string): string;
{ Short codeload form. Accepts branches, tags, and commit SHAs
  uniformly -- used when the user pinned an explicit ref via the
  `@v1.2.3` / `@sha` syntax. The previous hardcoded
  `refs/heads/<ref>` only worked for branches and 404'd on tags
  and SHAs even though the archives existed. }
begin
  Result := Format('https://codeload.github.com/%s/%s/zip/%s',
                   [Owner, Repo, Ref]);
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
      if Resp.StatusCode = 404 then
        ErrMsg := 'not found'
      else if Resp.ErrorMsg <> '' then
        ErrMsg := Format('http %d: %s', [Resp.StatusCode, Resp.ErrorMsg])
      else
        ErrMsg := Format('http %d', [Resp.StatusCode]);
      Exit;
    end;
    if Strm.Size > MaxZipBytes then
    begin
      ErrMsg := Format('archive too large (%d bytes; cap %d)',
                       [Strm.Size, MaxZipBytes]);
      Exit;
    end;
    if Strm.Size = 0 then
    begin
      ErrMsg := 'empty archive';
      Exit;
    end;
    Result := True;
  finally
    Strm.Free;
  end;
end;

(* GitHub zips wrap every entry in `<repo>-<ref>/`. Returns the absolute
   path to that wrapper after extraction, or '' if it can't be found. *)
function FindExtractedRoot(const ExtractDir: string): string;
var
  SR: TSearchRec;
begin
  Result := '';
  if FindFirst(JoinPath(ExtractDir, '*'), faDirectory, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then Continue;
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Result := JoinPath(ExtractDir, SR.Name);
      Exit;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure CopyTree(const SrcDir, DstDir: string);
{ Recursive copy. ForceDirectories DstDir, then iterate SrcDir
  copying files and recursing into subdirs. Uses TFileStream to
  preserve bytes verbatim (no UTF-8 decoding the way ReadFileText
  would). }

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
{ Recursive delete. Failures swallowed -- used in the cleanup path
  where partial state is better than a stuck install. }
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

function InstallFromGitHub(const Target, DestRoot: string;
                           out InstalledName, ErrMsg: string): Boolean;
var
  T: TTarget;
  TempBase, ZipPath, ExtractDir, RepoRoot, SrcDir, DstDir: string;
  Refs: array of string;
  i: Integer;
  TempName: string;
  Spec: TSkillSpec;
  ParseErr: string;
begin
  Result := False;
  InstalledName := '';
  ErrMsg := '';

  if not ParseTarget(Target, T, ErrMsg) then Exit;

  if T.SubPath <> '' then
    InstalledName := LastPathSegment(T.SubPath)
  else
    InstalledName := T.Repo;

  DstDir := JoinPath(DestRoot, InstalledName);
  if DirectoryExists(DstDir) then
  begin
    ErrMsg := Format('skill "%s" already exists at %s -- remove it or pick a different target',
                     [InstalledName, DstDir]);
    Exit;
  end;
  if not ForceDirectories(DestRoot) then
  begin
    ErrMsg := 'cannot create skills root: ' + DestRoot;
    Exit;
  end;

  { Stage everything under a unique temp dir so a failed install
    never leaves half-written files in DstDir. }
  TempName := 'pasclaw-skill-' + UniqueSuffix;
  TempBase := JoinPath(PlatformTempDir, TempName);
  if not ForceDirectories(TempBase) then
  begin
    ErrMsg := 'cannot create temp dir: ' + TempBase;
    Exit;
  end;
  ZipPath    := JoinPath(TempBase, 'archive.zip');
  ExtractDir := JoinPath(TempBase, 'extracted');
  try
    if T.Ref <> '' then
    begin
      { Explicit ref -- use the short codeload form that accepts
        branches, tags, and commit SHAs alike. One attempt only;
        a 404 here means the ref does not exist, not that we should
        try a default branch. }
      LogDebug('skills.github: trying %s/%s @ %s', [T.Owner, T.Repo, T.Ref]);
      if not DownloadZip(CodeloadAnyRefURL(T.Owner, T.Repo, T.Ref), ZipPath, ErrMsg) then
      begin
        ErrMsg := Format('download failed for %s/%s@%s: %s',
                         [T.Owner, T.Repo, T.Ref, ErrMsg]);
        Exit;
      end;
    end
    else
    begin
      { Implicit ref -- try main then master. Use refs/heads/<branch>
        explicitly so a tag or unrelated ref with the same name does
        not slip in via the short form. }
      SetLength(Refs, 2);
      Refs[0] := 'main';
      Refs[1] := 'master';
      for i := 0 to High(Refs) do
      begin
        LogDebug('skills.github: trying %s/%s @ %s', [T.Owner, T.Repo, Refs[i]]);
        if DownloadZip(CodeloadBranchURL(T.Owner, T.Repo, Refs[i]), ZipPath, ErrMsg) then
        begin
          ErrMsg := '';
          T.Ref  := Refs[i];
          Break;
        end;
      end;
      if T.Ref = '' then
      begin
        if ErrMsg = '' then ErrMsg := 'main and master both unreachable' else
          ErrMsg := 'download failed: ' + ErrMsg;
        Exit;
      end;
    end;

    if not ExtractZipToDir(ZipPath, ExtractDir, ErrMsg) then Exit;

    RepoRoot := FindExtractedRoot(ExtractDir);
    if RepoRoot = '' then
    begin
      ErrMsg := 'extracted archive has no top-level directory';
      Exit;
    end;

    if T.SubPath = '' then SrcDir := RepoRoot
    else                   SrcDir := JoinPath(RepoRoot, T.SubPath);

    if not FileExists(JoinPath(SrcDir, 'SKILL.md')) then
    begin
      if T.SubPath = '' then
        ErrMsg := Format('repo %s/%s @ %s has no SKILL.md at the root -- ' +
                         'specify a subpath, e.g. owner/repo/path-to-skill',
                         [T.Owner, T.Repo, T.Ref])
      else
        ErrMsg := Format('%s/SKILL.md not found in %s/%s @ %s',
                         [T.SubPath, T.Owner, T.Repo, T.Ref]);
      Exit;
    end;

    { Validate by parsing -- refusing here is friendlier than letting a
      malformed skill land on disk and show up in `pasclaw skills list`
      with a warn-but-keep behaviour. }
    if not ParseSkillMD(JoinPath(SrcDir, 'SKILL.md'), Spec, ParseErr) then
    begin
      ErrMsg := 'SKILL.md is invalid: ' + ParseErr;
      Exit;
    end;

    CopyTree(SrcDir, DstDir);
    LogInfo('skills.github: installed %s/%s%s@%s as %s',
            [T.Owner, T.Repo,
             IfThen(T.SubPath = '', '', '/' + T.SubPath),
             T.Ref, DstDir]);
    Result := True;
  finally
    RemoveTree(TempBase);
    if (not Result) and DirectoryExists(DstDir) then RemoveTree(DstDir);
  end;
end;

end.
