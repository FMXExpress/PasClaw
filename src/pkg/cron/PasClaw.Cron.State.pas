(*
  PasClaw.Cron.State - on-disk "when did each cron last fire" map.

  Stored at <home>/workspace/cron/state.json as
    { "entries": [
        { "id": "<cron-id>", "last_fired": <unix-seconds> },
        …
    ] }

  Why this exists: TCronScheduler used to look back two minutes from
  Now to find missed fires. If the gateway was down longer than that
  (laptop closed, server restart, weekend), jobs silently skipped. If
  the gateway restarted within the window, the same job could double
  fire. Persisting the last successful fire time per id lets RunOnce
  compute NextFireAfter(LastFired) and catch up exactly once on
  startup — no silent skips, no double fires.

  Concurrency: only the single scheduler thread reads / writes this
  file, so no locking. Writes are atomic via temp + rename so a crash
  mid-save leaves the previous state intact rather than producing a
  half-written JSON.
*)
unit PasClaw.Cron.State;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TCronStateEntry = record
    Id:        string;
    LastFired: Int64;   { unix seconds; 0 = never }
  end;

  TCronState = class
  private
    FPath:    string;
    FEntries: array of TCronStateEntry;
    function IndexOf(const Id: string): Integer;
  public
    constructor Create(const Path: string);
    procedure Load;
    procedure Save;
    function  GetLastFired(const Id: string): Int64;
    procedure SetLastFired(const Id: string; UnixSeconds: Int64);
  end;

function DefaultCronStatePath: string;

implementation

uses
  DateUtils,
  {$IFDEF MSWINDOWS}
  { Lets dcc64 inline SysUtils.RenameFile — 4 RenameFile calls in
    this unit's Load + Save paths all triggered H2443 without this.
    Same pattern as PasClaw.Session.Store / PasClaw.Agent.Steering. }
  {$IFDEF FPC}Windows,{$ELSE}Winapi.Windows,{$ENDIF}
  {$ENDIF}
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Utils,
  PasClaw.Logger;

function DefaultCronStatePath: string;
begin
  Result := JoinPath(GetHome, 'workspace/cron/state.json');
end;

constructor TCronState.Create(const Path: string);
begin
  inherited Create;
  FPath := Path;
  SetLength(FEntries, 0);
end;

function TCronState.IndexOf(const Id: string): Integer;
var
  i: Integer;
begin
  for i := 0 to High(FEntries) do
    if FEntries[i].Id = Id then Exit(i);
  Result := -1;
end;

procedure TCronState.Load;
var
  Body, ReadFrom, Bak: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  SetLength(FEntries, 0);
  Bak := FPath + '.bak';
  if FileExists(FPath) then
    ReadFrom := FPath
  else if FileExists(Bak) then
  begin
    { Save crashed between "move old to .bak" and "install new" —
      the previous-known-good state is the only surviving copy.
      Recover from it, then promote it back to the primary path so
      a future clean Save doesn't see a stale .bak. }
    LogWarn('cron.state: %s missing, recovering from %s', [FPath, Bak]);
    if not RenameFile(Bak, FPath) then
      LogWarn('cron.state: could not promote %s back to %s', [Bak, FPath]);
    ReadFrom := FPath;
    if not FileExists(ReadFrom) then Exit;
  end
  else
    Exit;

  try
    Body := ReadFileText(ReadFrom);
  except
    on E: Exception do
    begin
      LogWarn('cron.state: read %s failed: %s', [ReadFrom, E.Message]);
      Exit;
    end;
  end;
  if Trim(Body) = '' then Exit;
  try
    Root := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      LogWarn('cron.state: bad JSON in %s (%s) — starting fresh', [FPath, E.Message]);
      Exit;
    end;
  end;
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray('entries');
    if Arr = nil then Exit;
    try
      SetLength(FEntries, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          FEntries[i].Id        := Item.GetStr('id',         '');
          FEntries[i].LastFired := Item.GetInt('last_fired', 0);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

procedure TCronState.Save;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  Tmp, Bak: string;
  HadPrev: Boolean;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(FEntries) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('id',         FEntries[i].Id);
      Item.PutInt('last_fired', FEntries[i].LastFired);
      Arr.AddObject(Item);
    end;
    Root.PutArray('entries', Arr);

    EnsureDir(ExtractFilePath(FPath));
    Tmp := FPath + '.tmp';
    Bak := FPath + '.bak';
    WriteFileText(Tmp, Root.ToJSON);

    { Backup-file dance — guarantees a recoverable copy exists at
      every point in time, even if the process crashes mid-save or
      RenameFile fails. Sequence:
        1. Clear any stale .bak from a prior aborted save.
        2. Move current state to .bak  (if a current state exists).
        3. Install new state           (rename .tmp -> FPath).
        4. Delete .bak.
      If a crash happens between steps 2 and 3, the next Load notices
      FPath is missing and recovers from .bak.
      If RenameFile in step 3 fails, restore .bak so the previous
      state survives — never leave the user with no state at all. }
    if FileExists(Bak) then DeleteFile(Bak);

    HadPrev := FileExists(FPath);
    if HadPrev and not RenameFile(FPath, Bak) then
    begin
      LogWarn('cron.state: backup rename %s -> %s failed; aborting save',
              [FPath, Bak]);
      DeleteFile(Tmp);
      Exit;
    end;

    if not RenameFile(Tmp, FPath) then
    begin
      LogWarn('cron.state: install rename %s -> %s failed; restoring previous',
              [Tmp, FPath]);
      if HadPrev then RenameFile(Bak, FPath);
      DeleteFile(Tmp);
      Exit;
    end;

    if FileExists(Bak) then DeleteFile(Bak);
  finally
    Root.Free;
  end;
end;

function TCronState.GetLastFired(const Id: string): Int64;
var
  Idx: Integer;
begin
  Idx := IndexOf(Id);
  if Idx < 0 then Exit(0);
  Result := FEntries[Idx].LastFired;
end;

procedure TCronState.SetLastFired(const Id: string; UnixSeconds: Int64);
var
  Idx: Integer;
begin
  Idx := IndexOf(Id);
  if Idx >= 0 then
    FEntries[Idx].LastFired := UnixSeconds
  else
  begin
    SetLength(FEntries, Length(FEntries) + 1);
    FEntries[High(FEntries)].Id        := Id;
    FEntries[High(FEntries)].LastFired := UnixSeconds;
  end;
end;

end.
