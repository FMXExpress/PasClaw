unit PasClaw.Checkpoints.Zpaq;
(*
  PasClaw.Checkpoints.Zpaq - thin Pascal wrapper around the vendored
  Xelitan FPC port of libzpaq 7.15 (vendor/zpaq).

  Exposes the three operations PasClaw.Checkpoints needs to back its
  per-session journal:

    ZpaqAppendBytes(archive, body, name)     -- one new streaming
                                                segment, appended.
    ZpaqListEntries(archive, out entries)    -- enumerate every
                                                segment in order.
    ZpaqExtractByIndex(archive, idx, body)   -- read segment N back.

  Why we don't write the journaling (JIDAC) format: the Xelitan port's
  TZpaqPacker writes the streaming format only. The journaling format
  would give us cross-segment fragment dedup, but it needs more of the
  underlying library exposed than the port's public API offers; punted
  to a follow-up. The streaming format still gets us per-segment
  compression (LZ77 method 1 by default for the snapshot hot path),
  multi-version history in a single file, and indexed extraction.

  Availability: gated on the PASCLAW_HAVE_ZPAQ define, which the
  Makefile sets when vendor/zpaq/libzpaq.pas is on disk. Without it
  ZpaqAvailable returns False and the other calls fail with a clear
  error message; PasClaw.Checkpoints then routes through its legacy
  blob backend. The vendor is `{$mode objfpc}` so this whole unit is
  FPC-only -- under Delphi the helpers compile to "not available"
  stubs and the legacy backend is the only path.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
{$ENDIF}

interface

uses
  SysUtils, Classes;

type
  TZpaqArchiveEntry = record
    Name: string;
    Size: Int64;     { decompressed bytes; -1 for streaming entries
                       whose size wasn't recorded by the writer }
    Date: TDateTime; { 0 for streaming entries }
  end;
  TZpaqArchiveEntries = array of TZpaqArchiveEntry;

{ Returns True when the wrapper can actually call into the vendored
  port (i.e. PASCLAW_HAVE_ZPAQ is defined). Callers should check this
  before invoking the other entry points -- when False, the others
  return False with Err = 'zpaq backend not available'. }
function ZpaqAvailable: Boolean;

{ Compression-method tier for the streaming writer. 1 (LZ77) is fast
  and good enough for source-file snapshots; higher tiers cost more
  CPU per turn for marginal storage wins on already-text content. }
function ZpaqDefaultMethod: Integer;

{ Append Body as a new streaming segment named Name. Archive is
  created if it doesn't exist; otherwise the segment is appended
  after the existing data. Method is 1..5 (1 = fast LZ77 default,
  5 = context-mixing maxcompress). On success returns True; on
  failure False with Err set. Does NOT report the new segment's
  index -- callers track count externally (see PasClaw.Checkpoints'
  index.json). }
function ZpaqAppendBytes(const Archive: string; const Body: TBytes;
                         const Name: string; Method: Integer;
                         out Err: string): Boolean;

{ Enumerate every segment in Archive. Order matches the order the
  segments were appended, which is what callers use as the index. }
function ZpaqListEntries(const Archive: string;
                         out Entries: TZpaqArchiveEntries;
                         out Err: string): Boolean;

{ Extract the segment at zero-based Idx into Body. Idx must be in
  [0, Length(ListEntries result)). Err carries the reason on
  out-of-range or read errors. }
function ZpaqExtractByIndex(const Archive: string; Idx: Integer;
                            out Body: TBytes;
                            out Err: string): Boolean;

implementation

{$IFDEF PASCLAW_HAVE_ZPAQ}
uses
  ZpaqClasses;
{$ENDIF}

function ZpaqAvailable: Boolean;
begin
  {$IFDEF PASCLAW_HAVE_ZPAQ}
  Result := True;
  {$ELSE}
  Result := False;
  {$ENDIF}
end;

function ZpaqDefaultMethod: Integer;
begin
  { LZ77, fastest tier. The snapshot-before-write path runs inside
    the agent loop; spending 5x as much CPU on context-mixing for
    text files that already compress to 30% of the original under
    LZ77 isn't worth the turn latency. Operators who want maximum
    compression can call the underlying ZpaqAppendBytes directly. }
  Result := 1;
end;

{$IFDEF PASCLAW_HAVE_ZPAQ}

function ZpaqAppendBytes(const Archive: string; const Body: TBytes;
                         const Name: string; Method: Integer;
                         out Err: string): Boolean;
var
  Packer: TZpaqPacker;
  S: TMemoryStream;
begin
  Result := False;
  Err := '';
  if (Method < 0) or (Method > 5) then
  begin
    Err := Format('invalid method %d (expected 0..5)', [Method]);
    Exit;
  end;
  try
    S := TMemoryStream.Create;
    try
      if Length(Body) > 0 then
      begin
        S.WriteBuffer(Body[0], Length(Body));
        S.Position := 0;
      end;
      Packer := TZpaqPacker.Create(Archive);
      try
        Packer.SetMethod(Method);
        Packer.AddFile(S, Name);
      finally
        Packer.Free;
      end;
    finally
      S.Free;
    end;
    Result := True;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

function ZpaqListEntries(const Archive: string;
                         out Entries: TZpaqArchiveEntries;
                         out Err: string): Boolean;
var
  U: TZpaqUnpacker;
  Name: string;
  Sz: Int64;
  Dt: TDateTime;
  Count: Integer;
begin
  Result := False;
  Err := '';
  SetLength(Entries, 0);
  if not FileExists(Archive) then
  begin
    Err := 'archive not found: ' + Archive;
    Exit;
  end;
  try
    U := TZpaqUnpacker.Create(Archive);
    try
      Count := 0;
      while U.NextEntry(Name, Sz, Dt) do
      begin
        if Count >= Length(Entries) then
          SetLength(Entries, Length(Entries) * 2 + 16);
        Entries[Count].Name := Name;
        Entries[Count].Size := Sz;
        Entries[Count].Date := Dt;
        Inc(Count);
      end;
      SetLength(Entries, Count);
    finally
      U.Free;
    end;
    Result := True;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

function ZpaqExtractByIndex(const Archive: string; Idx: Integer;
                            out Body: TBytes;
                            out Err: string): Boolean;
var
  U: TZpaqUnpacker;
  Name: string;
  Sz: Int64;
  Dt: TDateTime;
  i: Integer;
  S: TMemoryStream;
begin
  Result := False;
  Err := '';
  SetLength(Body, 0);
  if Idx < 0 then
  begin
    Err := Format('negative index %d', [Idx]);
    Exit;
  end;
  if not FileExists(Archive) then
  begin
    Err := 'archive not found: ' + Archive;
    Exit;
  end;
  try
    U := TZpaqUnpacker.Create(Archive);
    try
      i := -1;
      while U.NextEntry(Name, Sz, Dt) do
      begin
        Inc(i);
        if i = Idx then
        begin
          S := TMemoryStream.Create;
          try
            U.Extract(S);
            S.Position := 0;
            SetLength(Body, S.Size);
            if S.Size > 0 then
              S.ReadBuffer(Body[0], S.Size);
            Result := True;
          finally
            S.Free;
          end;
          Exit;
        end;
      end;
      Err := Format('index %d out of range (only %d entries)', [Idx, i + 1]);
    finally
      U.Free;
    end;
  except
    on E: Exception do
      Err := E.Message;
  end;
end;

{$ELSE}

{ ----- PASCLAW_HAVE_ZPAQ stubs ----- }

function ZpaqAppendBytes(const Archive: string; const Body: TBytes;
                         const Name: string; Method: Integer;
                         out Err: string): Boolean;
begin
  Err := 'zpaq backend not available (vendor/zpaq missing; run `make get-zpaq`)';
  Result := False;
end;

function ZpaqListEntries(const Archive: string;
                         out Entries: TZpaqArchiveEntries;
                         out Err: string): Boolean;
begin
  SetLength(Entries, 0);
  Err := 'zpaq backend not available (vendor/zpaq missing; run `make get-zpaq`)';
  Result := False;
end;

function ZpaqExtractByIndex(const Archive: string; Idx: Integer;
                            out Body: TBytes;
                            out Err: string): Boolean;
begin
  SetLength(Body, 0);
  Err := 'zpaq backend not available (vendor/zpaq missing; run `make get-zpaq`)';
  Result := False;
end;

{$ENDIF}

end.
