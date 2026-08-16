(*
  PasClaw.Skills.Provenance - client-side integrity records for
  installed skills.

  Why this exists. PasClaw installs skills from ClawHub (see
  PasClaw.Skills.ClawHub), the registry picoclaw and nanobot
  standardised on. In February 2026 that registry shipped hundreds of
  malicious skills (the "ClawHavoc" incident) and responded by adding
  scanning at PUBLISH time -- SHA-256 plus VirusTotal plus an LLM code
  review. The clients did not respond at all: every claw client,
  PasClaw included, downloaded an archive and copied it onto disk with
  no check of any kind.

  Registry-side scanning is a rung the operator does not control. This
  unit adds the two rungs that are purely client-side and need nothing
  from ClawHub:

    1. RECORD what was actually installed. A .provenance.json inside
       each installed skill dir carries the source, slug, resolved
       version, the SHA-256 of the downloaded archive, and a per-file
       SHA-256 manifest. This is the VSIX `.signature.manifest` shape:
       size + digest of every file in the package.

    2. REFUSE SILENT DRIFT. Two different questions, both previously
       unanswerable:
         - did the bytes on disk change after install? (local tampering,
           a half-finished edit, a second tool writing into the dir)
         - did the REGISTRY serve different bytes for a slug+version we
           already hold? (the reinstall-substitution attack: publish
           clean, get installed, republish poisoned under the same
           version)
       VerifySkill answers the first. ArchiveDigestMatchesPin answers
       the second, and is what an install path calls before it copies.

  What this deliberately does NOT claim. There is no signature and no
  transparency log here, because ClawHub issues neither -- a digest we
  compute ourselves proves continuity, not authenticity. It cannot tell
  you the FIRST download was honest; it can only tell you that nothing
  changed since, and that is exactly how it is described to the user.
  Upgrading to real attestation (Sigstore-style keyless signing, the
  npm/PyPI rung) requires the registry to publish something signed.
  See docs/agent-features.md section 43 for the full ladder.

  Format (.provenance.json inside the skill dir):

    {
      "schema":       1,
      "source":       "clawhub",
      "slug":         "pdf-tools",
      "version":      "1.2.0",
      "archive_sha256": "<hex>",
      "installed_at": "2026-08-16T04:11:09Z",
      "files": [ { "path": "SKILL.md", "size": 812, "sha256": "<hex>" } ]
    }

  Paths in "files" are relative and always use '/' so a record written
  on Windows verifies on Linux. The record itself is excluded from the
  manifest (it cannot hash itself).
*)
unit PasClaw.Skills.Provenance;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

const
  ProvenanceFileName = '.provenance.json';
  ProvenanceSchema   = 1;

type
  TSkillFileDigest = record
    RelPath: string;   { always '/'-separated }
    Size:    Int64;
    Sha256:  string;   { lowercase hex }
  end;

  TSkillProvenance = record
    Source:        string;   { 'clawhub' | 'pasclawhub' | 'local' }
    Slug:          string;
    Version:       string;
    ArchiveSha256: string;
    InstalledAt:   string;
    Files:         array of TSkillFileDigest;
  end;

  { Outcome of comparing a record against what is on disk. }
  TSkillVerifyStatus = (
    svOK,           { every recorded file present and byte-identical }
    svNoRecord,     { no .provenance.json -- installed before this existed,
                      or by hand. NOT a failure; reported as unknown. }
    svModified,     { a recorded file's digest changed }
    svMissing,      { a recorded file is gone }
    svAdded,        { a file exists that the record does not list }
    svUnreadable    { the record itself is absent/corrupt/unparseable }
  );

  TSkillVerifyResult = record
    Status:   TSkillVerifyStatus;
    { Human-readable, one line per finding. Populated for every status
      except svOK. The point of this unit is to say WHAT differed, not
      merely that something did. }
    Findings: array of string;
    Checked:  Integer;   { files hashed }
    Skipped:  Integer;   { unreadable during the walk -- reported, never
                           silently dropped }
  end;

{ SHA-256 of a file's bytes, lowercase hex. Empty string on read
  failure (caller decides whether that is fatal). Size is the byte
  count that was hashed -- returned from the same read so the two can
  never disagree about which bytes they describe. }
function FileSha256Sized(const Path: string; out Size: Int64): string;
function FileSha256(const Path: string): string;

{ Build a record by walking Root. Does not write anything. }
function BuildProvenance(const Root, Source, Slug, Version,
                         ArchiveSha256: string): TSkillProvenance;

{ Serialise/persist. WriteProvenance puts the file inside Root. }
function ProvenanceToJSON(const P: TSkillProvenance): string;
function WriteProvenance(const Root: string; const P: TSkillProvenance;
                         out ErrMsg: string): Boolean;
function ReadProvenance(const Root: string; out P: TSkillProvenance;
                        out ErrMsg: string): Boolean;

{ Re-hash Root and compare against its stored record. }
function VerifySkill(const Root: string): TSkillVerifyResult;

{ True when Root has a record whose archive digest differs from
  NewDigest -- i.e. the registry served different bytes for something
  we already hold. HasRecord is False when there is nothing to compare
  against, in which case the result is meaningless and the caller
  should proceed. }
function ArchiveDigestDiffers(const Root, NewDigest: string;
                              out HasRecord: Boolean;
                              out OldDigest: string): Boolean;

function VerifyStatusText(S: TSkillVerifyStatus): string;

(* ---- the lock ----

   The per-skill record lives INSIDE the skill directory, so removing a
   skill removes its record too. That leaves the substitution attack
   wide open in its most natural form: uninstall, reinstall the same
   slug+version, receive different bytes, notice nothing.

   skills.lock.json sits at the skills ROOT and outlives any individual
   skill. It remembers the archive digest first seen for a
   slug+version, so a later install of that same pair can be compared
   against what this machine trusted before. This is the npm
   lockfile's job, not its format.

   CheckLock returns lkFirstSight when the pair is unknown (nothing to
   compare -- proceed and record), lkMatch when the digest is the one
   we saw before, and lkDrift when the registry served something else
   for a version that is supposed to be immutable. lkDrift is the
   finding worth refusing on. *)
type
  TLockCheck = (lkFirstSight, lkMatch, lkDrift);

function CheckLock(const SkillsRoot, Slug, Version, Digest: string;
                   out KnownDigest: string): TLockCheck;
procedure RecordInLock(const SkillsRoot, Slug, Version, Digest: string);

implementation

uses
  PasClaw.Utils, PasClaw.JSON, PasClaw.Crypto.HMAC, PasClaw.Logger;

function FileSha256Sized(const Path: string; out Size: Int64): string;
var
  FS: TFileStream;
  Data: TBytes;
begin
  Result := '';
  Size   := 0;
  if not FileExists(Path) then Exit;
  try
    FS := TFileStream.Create(Path, fmOpenRead or fmShareDenyNone);
    try
      Size := FS.Size;
      SetLength(Data, FS.Size);
      if FS.Size > 0 then FS.ReadBuffer(Data[0], FS.Size);
    finally
      FS.Free;
    end;
  except
    on E: Exception do
    begin
      LogDebug('provenance: cannot read %s: %s', [Path, E.Message]);
      Size := 0;
      Exit('');
    end;
  end;
  Result := BytesToHexLower(SHA256Bytes(Data));
end;

function FileSha256(const Path: string): string;
var
  Ignored: Int64;
begin
  Result := FileSha256Sized(Path, Ignored);
end;

function ToRelSlashPath(const Root, Full: string): string;
begin
  Result := Copy(Full, Length(Root) + 1, MaxInt);
  while (Result <> '') and ((Result[1] = '/') or (Result[1] = '\')) do
    Delete(Result, 1, 1);
  Result := StringReplace(Result, '\', '/', [rfReplaceAll]);
end;

procedure WalkFiles(const Root, Dir: string; List: TStringList);
var
  SR: TSearchRec;
  Full: string;
begin
  if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      Full := JoinPath(Dir, SR.Name);
      if (SR.Attr and faDirectory) <> 0 then
        WalkFiles(Root, Full, List)
      else
      begin
        { The record cannot contain its own digest. }
        if not SameText(SR.Name, ProvenanceFileName) then
          List.Add(Full);
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

function BuildProvenance(const Root, Source, Slug, Version,
                         ArchiveSha256: string): TSkillProvenance;
var
  List: TStringList;
  i, n: Integer;
  D: TSkillFileDigest;
  Hash: string;
  Sz: Int64;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Source        := Source;
  Result.Slug          := Slug;
  Result.Version       := Version;
  Result.ArchiveSha256 := ArchiveSha256;
  Result.InstalledAt   := NowIsoUtc;

  List := TStringList.Create;
  try
    WalkFiles(Root, Root, List);
    List.Sort;   { stable order so two installs of identical content
                   produce identical records }
    n := 0;
    SetLength(Result.Files, List.Count);
    for i := 0 to List.Count - 1 do
    begin
      Hash := FileSha256Sized(List[i], Sz);
      if Hash = '' then
      begin
        LogWarn('provenance: skipping unreadable file %s', [List[i]]);
        Continue;
      end;
      D.RelPath := ToRelSlashPath(Root, List[i]);
      D.Size    := Sz;
      D.Sha256  := Hash;
      Result.Files[n] := D;
      Inc(n);
    end;
    SetLength(Result.Files, n);
  finally
    List.Free;
  end;
end;

function ProvenanceToJSON(const P: TSkillProvenance): string;
var
  Root, FO: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Root.PutInt('schema', ProvenanceSchema);
    Root.PutStr('source', P.Source);
    Root.PutStr('slug', P.Slug);
    Root.PutStr('version', P.Version);
    Root.PutStr('archive_sha256', P.ArchiveSha256);
    Root.PutStr('installed_at', P.InstalledAt);
    Arr := TJsonArray.Create;
    for i := 0 to High(P.Files) do
    begin
      FO := TJsonObject.Create;
      FO.PutStr('path', P.Files[i].RelPath);
      FO.PutInt('size', P.Files[i].Size);
      FO.PutStr('sha256', P.Files[i].Sha256);
      Arr.AddObject(FO);
    end;
    Root.PutArray('files', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function WriteProvenance(const Root: string; const P: TSkillProvenance;
                         out ErrMsg: string): Boolean;
begin
  Result := False;
  ErrMsg := '';
  try
    WriteFileText(JoinPath(Root, ProvenanceFileName), ProvenanceToJSON(P));
    Result := True;
  except
    on E: Exception do ErrMsg := E.Message;
  end;
end;

function ReadProvenance(const Root: string; out P: TSkillProvenance;
                        out ErrMsg: string): Boolean;
var
  Path, Body: string;
  Obj, FO: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Result := False;
  ErrMsg := '';
  FillChar(P, SizeOf(P), 0);
  Path := JoinPath(Root, ProvenanceFileName);
  if not FileExists(Path) then
  begin
    ErrMsg := 'no provenance record';
    Exit;
  end;
  Body := ReadFileText(Path);
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then
  begin
    ErrMsg := 'provenance record is not valid JSON';
    Exit;
  end;
  try
    P.Source        := Obj.GetStr('source', '');
    P.Slug          := Obj.GetStr('slug', '');
    P.Version       := Obj.GetStr('version', '');
    P.ArchiveSha256 := Obj.GetStr('archive_sha256', '');
    P.InstalledAt   := Obj.GetStr('installed_at', '');
    Arr := Obj.ChildArray('files');
    if Arr <> nil then
    begin
      SetLength(P.Files, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        FO := Arr.ItemObject(i);
        if FO = nil then Continue;
        P.Files[i].RelPath := FO.GetStr('path', '');
        P.Files[i].Size    := FO.GetInt('size', 0);
        P.Files[i].Sha256  := FO.GetStr('sha256', '');
      end;
    end;
    Result := True;
  finally
    Obj.Free;
  end;
end;

procedure AddFinding(var R: TSkillVerifyResult; const S: string);
begin
  SetLength(R.Findings, Length(R.Findings) + 1);
  R.Findings[High(R.Findings)] := S;
end;

function VerifySkill(const Root: string): TSkillVerifyResult;
var
  P: TSkillProvenance;
  Err, Rel, Hash: string;
  i, j: Integer;
  Found: Boolean;
  OnDisk: TStringList;
  Recorded: TStringList;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.Status := svOK;

  if not FileExists(JoinPath(Root, ProvenanceFileName)) then
  begin
    Result.Status := svNoRecord;
    AddFinding(Result, 'no ' + ProvenanceFileName +
      ' -- installed before provenance recording, or installed by hand');
    Exit;
  end;
  if not ReadProvenance(Root, P, Err) then
  begin
    Result.Status := svUnreadable;
    AddFinding(Result, Err);
    Exit;
  end;

  OnDisk   := TStringList.Create;
  Recorded := TStringList.Create;
  try
    WalkFiles(Root, Root, OnDisk);
    for i := 0 to High(P.Files) do
      Recorded.Add(P.Files[i].RelPath);

    { recorded -> disk: missing or modified }
    for i := 0 to High(P.Files) do
    begin
      Rel := P.Files[i].RelPath;
      Hash := FileSha256(JoinPath(Root,
                StringReplace(Rel, '/', PathDelim, [rfReplaceAll])));
      if Hash = '' then
      begin
        if Result.Status = svOK then Result.Status := svMissing;
        AddFinding(Result, 'missing or unreadable: ' + Rel);
        Inc(Result.Skipped);
        Continue;
      end;
      Inc(Result.Checked);
      if not SameText(Hash, P.Files[i].Sha256) then
      begin
        Result.Status := svModified;
        AddFinding(Result, 'modified since install: ' + Rel);
      end;
    end;

    { disk -> recorded: additions }
    for i := 0 to OnDisk.Count - 1 do
    begin
      Rel := ToRelSlashPath(Root, OnDisk[i]);
      Found := False;
      for j := 0 to Recorded.Count - 1 do
        if Recorded[j] = Rel then begin Found := True; Break; end;
      if not Found then
      begin
        if Result.Status = svOK then Result.Status := svAdded;
        AddFinding(Result, 'added since install: ' + Rel);
      end;
    end;
  finally
    OnDisk.Free;
    Recorded.Free;
  end;
end;

function ArchiveDigestDiffers(const Root, NewDigest: string;
                              out HasRecord: Boolean;
                              out OldDigest: string): Boolean;
var
  P: TSkillProvenance;
  Err: string;
begin
  Result    := False;
  HasRecord := False;
  OldDigest := '';
  if not ReadProvenance(Root, P, Err) then Exit;
  if P.ArchiveSha256 = '' then Exit;
  HasRecord := True;
  OldDigest := P.ArchiveSha256;
  Result    := (NewDigest <> '') and not SameText(NewDigest, P.ArchiveSha256);
end;

const
  LockFileName = 'skills.lock.json';

function LockKey(const Slug, Version: string): string;
{ Version '' and 'latest' are the same unpinned request; normalise so a
  drift check cannot be dodged by asking for one spelling then the
  other. }
var
  V: string;
begin
  V := LowerCase(Trim(Version));
  if (V = '') or (V = 'latest') then V := 'latest';
  Result := LowerCase(Trim(Slug)) + '@' + V;
end;

function CheckLock(const SkillsRoot, Slug, Version, Digest: string;
                   out KnownDigest: string): TLockCheck;
var
  Path: string;
  Root, Ent: TJsonObject;
begin
  Result      := lkFirstSight;
  KnownDigest := '';
  Path := JoinPath(SkillsRoot, LockFileName);
  if not FileExists(Path) then Exit;
  Root := TJsonObject.Parse(ReadFileText(Path));
  if Root = nil then
  begin
    { A corrupt lock must not silently behave like "no lock". Say so and
      treat the pair as unknown -- the operator can delete it. }
    LogWarn('provenance: %s is unreadable -- drift checking is OFF until ' +
            'it is repaired or removed', [Path]);
    Exit;
  end;
  try
    Ent := Root.ChildObject(LockKey(Slug, Version));
    if Ent = nil then Exit;
    KnownDigest := Ent.GetStr('archive_sha256', '');
    if KnownDigest = '' then Exit;
    if SameText(KnownDigest, Digest) then
      Result := lkMatch
    else
      Result := lkDrift;
  finally
    Root.Free;
  end;
end;

procedure RecordInLock(const SkillsRoot, Slug, Version, Digest: string);
var
  Path: string;
  Root, Ent: TJsonObject;
begin
  if (Digest = '') or (SkillsRoot = '') then Exit;
  Path := JoinPath(SkillsRoot, LockFileName);
  if FileExists(Path) then
    Root := TJsonObject.Parse(ReadFileText(Path))
  else
    Root := nil;
  if Root = nil then Root := TJsonObject.Create;
  try
    Ent := TJsonObject.Create;
    Ent.PutStr('archive_sha256', Digest);
    Ent.PutStr('first_seen', NowIsoUtc);
    Ent.PutStr('slug', Slug);
    Ent.PutStr('version', Version);
    Root.PutObject(LockKey(Slug, Version), Ent);
    try
      WriteFileText(Path, Root.ToJSON);
    except
      on E: Exception do
        LogWarn('provenance: cannot write %s: %s', [Path, E.Message]);
    end;
  finally
    Root.Free;
  end;
end;

function VerifyStatusText(S: TSkillVerifyStatus): string;
begin
  case S of
    svOK:         Result := 'ok';
    svNoRecord:   Result := 'unknown';
    svModified:   Result := 'MODIFIED';
    svMissing:    Result := 'INCOMPLETE';
    svAdded:      Result := 'EXTRA FILES';
    svUnreadable: Result := 'UNREADABLE RECORD';
  else
    Result := '?';
  end;
end;

end.
