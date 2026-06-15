(*
  PasClaw.Skills.Install -- reusable skill install / remove, shared by the
  `pasclaw skills` CLI surface and the web UI's POST/DELETE /v1/skills.

  Install routing mirrors the CLI's: an explicit `hub:` / `clawhub:` prefix
  forces that hub; an `owner/repo` or github.com URL goes to GitHub; a bare
  slug tries pasclaw.dev first and falls back to ClawHub on "not found"
  (a network error on the first hop surfaces rather than silently retrying).

  Console-free (returns ok + name/err) so it's callable from an HTTP
  handler; the CLI keeps its own pretty-printing wrappers.
*)
unit PasClaw.Skills.Install;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

type
  TSkillTargetKind = (stPasClawHub, stClawHub, stGitHub, stBareSlug);

{ Classify an install target and split off any @version. stBareSlug means
  "try the hubs in order". Exposed for tests (no network). }
procedure ClassifySkillTarget(const Target: string; out Kind: TSkillTargetKind;
                              out Slug, Version: string);

{ Install Target into DestRoot (the workspace/skills dir). Returns the
  installed directory name via InstalledName, or False + ErrMsg. }
function InstallSkillTarget(const Target, DestRoot: string;
                           out InstalledName, ErrMsg: string): Boolean;

{ A skill name is a single path segment that goes into JoinPath without
  canonicalisation -- reject separators / '..' so a remove can't escape
  workspace/skills/. Mirrors the rule in PasClaw.Cmd.Skills. }
function IsSafeSkillName(const Name: string): Boolean;

{ Delete <SkillsDir>/<Name>/ (recursively) and any legacy
  <SkillsDir>/<Name>.json. Returns True if anything was removed. Caller
  MUST have validated Name with IsSafeSkillName first. }
function RemoveSkillFiles(const SkillsDir, Name: string): Boolean;

implementation

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.Skills.GitHub,
  PasClaw.Skills.ClawHub,
  PasClaw.Skills.PasClawHub;

procedure SplitSlugAtVersion(const S: string; out Slug, Version: string);
{ "slug@1.2" -> ("slug","1.2"); "slug" -> ("slug",""). The '@' must not be
  the first char (an empty slug is meaningless). }
var
  p: Integer;
begin
  Slug := S;
  Version := '';
  p := Pos('@', S);
  if p > 1 then
  begin
    Slug := Copy(S, 1, p - 1);
    Version := Copy(S, p + 1, MaxInt);
  end;
end;

procedure ClassifySkillTarget(const Target: string; out Kind: TSkillTargetKind;
                              out Slug, Version: string);
var
  L: string;
begin
  L := LowerCase(Target);
  if HasPrefix(L, 'hub:') then
  begin
    Kind := stPasClawHub;
    SplitSlugAtVersion(Copy(Target, Length('hub:') + 1, MaxInt), Slug, Version);
  end
  else if HasPrefix(L, 'clawhub:') then
  begin
    Kind := stClawHub;
    SplitSlugAtVersion(Copy(Target, Length('clawhub:') + 1, MaxInt), Slug, Version);
  end
  else if (Pos('github.com', L) > 0) or (Pos('/', Target) > 0) then
  begin
    { owner/repo or a full github URL -- handed to the GitHub installer
      verbatim (it parses owner/repo/ref itself). }
    Kind := stGitHub;
    Slug := Target;
    Version := '';
  end
  else
  begin
    Kind := stBareSlug;
    SplitSlugAtVersion(Target, Slug, Version);
  end;
end;

function InstallSkillTarget(const Target, DestRoot: string;
                           out InstalledName, ErrMsg: string): Boolean;
var
  Kind: TSkillTargetKind;
  Slug, Version: string;
begin
  InstalledName := '';
  ErrMsg := '';
  if Trim(Target) = '' then
  begin
    ErrMsg := 'empty install target';
    Exit(False);
  end;
  ClassifySkillTarget(Trim(Target), Kind, Slug, Version);
  case Kind of
    stPasClawHub:
      Result := InstallFromPasClawHub(Slug, Version, DestRoot, InstalledName, ErrMsg);
    stClawHub:
      Result := InstallFromClawHub(Slug, Version, DestRoot, InstalledName, ErrMsg);
    stGitHub:
      Result := InstallFromGitHub(Slug, DestRoot, InstalledName, ErrMsg);
  else
    { Bare slug: pasclaw.dev first, then ClawHub only on a clean
      "not found" so a network blip doesn't silently switch hubs. }
    Result := InstallFromPasClawHub(Slug, Version, DestRoot, InstalledName, ErrMsg);
    if (not Result) and SameText(ErrMsg, 'not found') then
      Result := InstallFromClawHub(Slug, Version, DestRoot, InstalledName, ErrMsg);
  end;
end;

function IsSafeSkillName(const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Name = '') or (Name = '.') or (Name = '..') then Exit;
  for i := 1 to Length(Name) do
    case Name[i] of
      '/', '\', ':', #0..#31: Exit;
    end;
  if Pos('..', Name) > 0 then Exit;
  Result := True;
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
    SysUtils.FindClose(SR);
  end;
  try RemoveDir(Dir); except end;
end;

function RemoveSkillFiles(const SkillsDir, Name: string): Boolean;
var
  Dir, LegacyJSON: string;
begin
  Result := False;
  if not IsSafeSkillName(Name) then Exit;   { defensive -- caller checks too }
  Dir := JoinPath(SkillsDir, Name);
  if DirectoryExists(Dir) then
  begin
    RemoveTree(Dir);
    Result := True;
  end;
  LegacyJSON := JoinPath(SkillsDir, Name + '.json');
  if FileExists(LegacyJSON) then
  begin
    if DeleteFile(LegacyJSON) then Result := True;
  end;
end;

end.
