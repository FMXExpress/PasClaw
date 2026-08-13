(*
  PasClaw.Suite.Notes - notes as markdown files the agent can read.

  The Notes app used to keep its notes in the per-app state store, which
  works and is invisible. Nothing else could see them: not memory_search,
  not the agent, not grep. A notes app whose notes the assistant cannot read
  is a text box.

  So notes live here instead:

    <workspace>/memory/notes/<slug>.md

  under the memory directory, which is what the memory index already walks.
  Writing a note is therefore the cheapest possible way to tell PasClaw
  something durable -- no tool call, no distillation pass, just a file in
  the place the agent already looks. That is the whole design, and it is why
  this is worth a unit rather than a state key.

  A note is a markdown file with its title on the first line as an H1. No
  front matter, no sidecar index: the file IS the record, so a note you drop
  in with an editor shows up in the app, and a note the app writes is a file
  you can read with `cat`.
*)
unit PasClaw.Suite.Notes;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TNoteInfo = record
    Name:     string;   { the slug -- also the filename without .md }
    Title:    string;   { first H1, or the slug if the file has none }
    Body:     string;
    Modified: string;   { ISO-ish, for ordering in the UI }
  end;
  TNoteInfoArray = array of TNoteInfo;

{ The directory notes live in. Created on demand. }
function NotesDir: string;

{ Every note in the active workspace, newest first. }
function ListNotes: TNoteInfoArray;

{ Read one. False when there is no such note. }
function GetNote(const Name: string; out Note: TNoteInfo): Boolean;

(* Write one. Pass an empty Name to create: a slug is derived from the
   title. Returns the slug actually written, or '' with Err set.

   Title and Body are UNTRUSTED -- they come from a text box in a sandboxed
   app, and on the model's side from whatever the agent was reading. The
   slug is the only part that becomes a filename, so SlugForNote is the one
   function in this unit that has to be right. *)
function SaveNote(const Name, Title, Body: string; out Err: string): string;

{ Remove one. Missing is not an error -- deleting a note twice is fine. }
function DeleteNote(const Name: string; out Err: string): Boolean;

(* Filename-safe slug for a title: lowercase, alphanumerics and dashes
   only, bounded length, never empty, never a traversal. Exposed for tests
   because it is the containment boundary. *)
function SlugForNote(const Title: string): string;

implementation

uses
  PasClaw.Utils,
  PasClaw.Logger,
  PasClaw.Workspaces;

const
  MaxSlug  = 60;
  MaxNotes = 500;   { a listing, not an archive -- see ListNotes }

function NotesDir: string;
begin
  Result := JoinPath(WorkspaceSubdir('memory'), 'notes');
end;

function SlugForNote(const Title: string): string;
var
  I: Integer;
  C: Char;
  Last: Char;
begin
  Result := '';
  Last := '-';
  for I := 1 to Length(Title) do
  begin
    C := Title[I];
    if C in ['A'..'Z'] then C := Chr(Ord(C) + 32);
    if C in ['a'..'z', '0'..'9'] then
    begin
      Result := Result + C;
      Last := C;
    end
    else if (Last <> '-') and (Length(Result) > 0) then
    begin
      Result := Result + '-';
      Last := '-';
    end;
    if Length(Result) >= MaxSlug then Break;
  end;

  while (Result <> '') and (Result[Length(Result)] = '-') do
    SetLength(Result, Length(Result) - 1);

  { A title of nothing but punctuation, or an empty one, must still produce
    a usable filename rather than '' -- which would resolve to the notes
    directory itself. }
  if Result = '' then
    Result := 'note-' + FormatDateTime('yyyymmdd-hhnnss', Now);
end;

(* Resolve a slug to a path, or '' if it is not a plain slug.

   This is deliberately a WHITELIST rather than a traversal blacklist: the
   only thing that can name a file here is [a-z0-9-], so '..', absolute
   paths, backslashes, NUL and every encoding of them fail by not being in
   the alphabet. There is nothing to escape. *)
function PathForNote(const Name: string): string;
var
  I: Integer;
begin
  Result := '';
  if (Name = '') or (Length(Name) > MaxSlug) then Exit;
  for I := 1 to Length(Name) do
    if not (Name[I] in ['a'..'z', '0'..'9', '-']) then Exit;
  Result := JoinPath(NotesDir, Name + '.md');
end;

{ The title is the first H1; markdown already says so, and it means a note
  written by hand in an editor gets the same title the app would give it. }
function TitleOf(const Body, Fallback: string): string;
var
  L: TStringList;
  I: Integer;
  S: string;
begin
  Result := '';
  L := TStringList.Create;
  try
    L.Text := Body;
    for I := 0 to L.Count - 1 do
    begin
      S := Trim(L[I]);
      if S = '' then Continue;
      if Copy(S, 1, 2) = '# ' then Result := Trim(Copy(S, 3, MaxInt))
      else Result := S;
      Break;
    end;
  finally
    L.Free;
  end;
  if Result = '' then Result := Fallback;
  if Length(Result) > 120 then Result := Copy(Result, 1, 117) + '...';
end;

function ListNotes: TNoteInfoArray;
var
  Rec: TSearchRec;
  Dir, Slug: string;
  N: Integer;
  Tmp: TNoteInfo;
  I, J: Integer;
  Swap: TNoteInfo;
begin
  SetLength(Result, 0);
  Dir := NotesDir;
  if not DirectoryExists(Dir) then Exit;
  N := 0;
  if FindFirst(JoinPath(Dir, '*.md'), faAnyFile, Rec) = 0 then
  try
    repeat
      if (Rec.Attr and faDirectory) <> 0 then Continue;
      Slug := ChangeFileExt(Rec.Name, '');
      if PathForNote(Slug) = '' then Continue;   { not ours; leave it alone }
      Tmp.Name     := Slug;
      Tmp.Body     := ReadFileText(JoinPath(Dir, Rec.Name));
      Tmp.Title    := TitleOf(Tmp.Body, Slug);
      Tmp.Modified := FormatDateTime('yyyy-mm-dd hh:nn',
                        FileDateToDateTime(Rec.Time));
      SetLength(Result, N + 1);
      Result[N] := Tmp;
      Inc(N);
      { A listing is a UI, not an archive. Past this many the app is
        unusable anyway and the agent should be searching, not scrolling. }
      if N >= MaxNotes then Break;
    until FindNext(Rec) <> 0;
  finally
    FindClose(Rec);
  end;

  { Newest first. Insertion sort: N is small and bounded above. }
  for I := 1 to High(Result) do
  begin
    J := I;
    while (J > 0) and (Result[J - 1].Modified < Result[J].Modified) do
    begin
      Swap := Result[J - 1];
      Result[J - 1] := Result[J];
      Result[J] := Swap;
      Dec(J);
    end;
  end;
end;

function GetNote(const Name: string; out Note: TNoteInfo): Boolean;
var
  Path: string;
begin
  Result := False;
  Path := PathForNote(Name);
  if (Path = '') or not FileExists(Path) then Exit;
  Note.Name     := Name;
  Note.Body     := ReadFileText(Path);
  Note.Title    := TitleOf(Note.Body, Name);
  Note.Modified := FormatDateTime('yyyy-mm-dd hh:nn',
                     FileDateToDateTime(FileAge(Path)));
  Result := True;
end;

function SaveNote(const Name, Title, Body: string; out Err: string): string;
var
  Slug, Path, Text_, T: string;
begin
  Result := '';
  Err := '';
  T := Trim(Title);

  Slug := Trim(Name);
  if Slug = '' then
    Slug := SlugForNote(T);

  Path := PathForNote(Slug);
  if Path = '' then
  begin
    Err := 'bad note name';
    Exit;
  end;

  if not EnsureDir(NotesDir) then
  begin
    Err := 'could not create ' + NotesDir;
    Exit;
  end;

  { Store the title as the H1 so the file is self-describing -- and so the
    memory index, which reads these as plain markdown, sees a heading. }
  Text_ := Body;
  if T <> '' then
  begin
    if Copy(TrimLeft(Text_), 1, 2) = '# ' then
      { the body already carries its own heading; don't stack a second one }
    else
      Text_ := '# ' + T + sLineBreak + sLineBreak + Text_;
  end;

  try
    WriteFileText(Path, Text_);
  except
    on E: Exception do
    begin
      Err := 'could not write ' + Path + ': ' + E.Message;
      Exit;
    end;
  end;
  LogInfo('notes: wrote %s', [Slug]);
  Result := Slug;
end;

function DeleteNote(const Name: string; out Err: string): Boolean;
var
  Path: string;
begin
  Err := '';
  Path := PathForNote(Name);
  if Path = '' then
  begin
    Err := 'bad note name';
    Exit(False);
  end;
  { Already gone is the state the caller wanted. }
  if not FileExists(Path) then Exit(True);
  Result := DeleteFile(Path);
  if not Result then Err := 'could not delete ' + Path
  else LogInfo('notes: deleted %s', [Name]);
end;

end.
