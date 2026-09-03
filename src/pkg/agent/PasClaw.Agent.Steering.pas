(*
  PasClaw.Agent.Steering -- mid-loop interrupt queue.

  Today a user mid-conversation can't course-correct while a tool loop
  is running -- their next message is processed AFTER the loop returns.
  picoclaw's pkg/agent/steering.go and nanobot's _inject_pending path
  both let the user push a follow-up into a queue that the loop drains
  between iterations and folds into the next LLM round-trip as a
  system note. This unit ports that mechanism.

  Storage: append-only JSONL files at
    $PASCLAW_HOME/workspace/steering/<key>.jsonl
  one line per pending message: {"at":<unix>,"text":"..."}

  Key choice: callers pass the SessionKey on TToolLoopConfig.SteeringKey.
  Cmd.Agent uses Session.Meta.Id (always present since PR #117);
  channels can pass their own stable per-conversation key (Telegram
  chat id, Slack channel, etc.) when they wire concurrent polling
  (currently CLI-only -- see README for the per-channel follow-up).

  Concurrency model: every push AND drain acquires a directory-
  based mutex first (mkdir of <key>.jsonl.lock -- atomic on both
  POSIX and Windows). A stale lock from a crashed process is auto-
  recovered after STALE_LOCK_SECS. Inside the mutex a drain renames
  the queue file to <key>.jsonl.draining, then reads and deletes,
  so a push that beat the drain to the lock is in the renamed
  inode and gets returned; one that arrives later opens a fresh
  <key>.jsonl that the NEXT drain picks up. No message lost, no
  message returned twice, no torn writes.

  Cap: caller decides via MaxPerTurn (RunToolLoop passes a small
  fixed cap so a runaway pusher can't grow Hist unbounded). Messages
  beyond the cap are PUT BACK, not dropped: the cap bounds what one
  iteration injects, and the next iteration's drain takes the next
  batch. picoclaw's MaxInjections drops them; that was survivable when
  the queue was a human typing course corrections and is not now that
  it also carries an agent's mailbox (PasClaw.Agents), where a dropped
  message is recorded as delivered and never seen.
*)
unit PasClaw.Agent.Steering;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TSteeringMessage = record
    PostedAt: Int64;     { unix seconds, UTC }
    Text:     string;
  end;
  TSteeringMessageArray = array of TSteeringMessage;

{ Push a steering message to the queue keyed by SessionKey. Returns
  True on success, False when the key is unsafe (rejected for the
  same reasons PasClaw.Session.Store.IsSafeSessionId rejects: path
  traversal, NULs, leading dot, length cap) or write fails. }
function PushSteering(const SessionKey, Text: string): Boolean;

{ Drain up to MaxMessages from the queue. Anything beyond the cap
  stays queued for the next drain -- the cap bounds one batch, it does
  not discard. Empty array when no messages or unsafe key. Atomic
  across concurrent drains via rename. }
function DrainSteering(const SessionKey: string; MaxMessages: Integer): TSteeringMessageArray;

{ Erase the queue entirely. Called by /reset, /new, session delete. }
procedure ClearSteering(const SessionKey: string);

{ Inspect without consuming -- list / show / debug. }
function PendingSteeringCount(const SessionKey: string): Integer;

{ Absolute path of the on-disk queue file (or '' for an unsafe key).
  Exposed so the CLI `pasclaw steer` can print where the message
  landed and so cmd/session show can include it. }
function SteeringPath(const SessionKey: string): string;

implementation

uses
  PasClaw.Workspaces,
  Classes, DateUtils,
  {$IFDEF MSWINDOWS}
  { Lets dcc64 inline SysUtils.RenameFile (used by the .drain
    handoff in Drain) instead of falling back and emitting H2443. }
  {$IFDEF FPC}Windows,{$ELSE}Winapi.Windows,{$ENDIF}
  {$ENDIF}
  PasClaw.Utils,
  PasClaw.Config,
  PasClaw.Session.Store,
  PasClaw.JSON,
  PasClaw.Logger;

function SteeringDir: string;
begin
  Result := JoinPath(GetHome, ActiveWorkspaceName + '/steering');
end;

function SteeringPath(const SessionKey: string): string;
begin
  if not IsSafeSessionId(SessionKey) then Exit('');
  Result := JoinPath(SteeringDir, SessionKey + '.jsonl');
end;

procedure EnsureSteeringDir;
begin
  if not DirectoryExists(SteeringDir) then
    ForceDirectories(SteeringDir);
end;

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(Now, False);
end;

const
  { A process that crashed mid-push leaves the lock dir behind. After
    this many seconds we treat it as orphaned and reclaim -- small
    enough that an interrupted user CLI doesn't permanently wedge
    the queue, large enough that a normal push/drain (millisecond
    scale) never trips it. }
  STALE_LOCK_SECS  = 30;
  LOCK_SPIN_MS     = 25;
  LOCK_MAX_WAIT_MS = 2000;

{ Directory-based mutex. mkdir is atomic on both POSIX and Windows
  (POSIX: O_CREAT|O_EXCL semantics; Windows: CreateDirectory is
  atomic against concurrent calls). One process creates, others see
  EEXIST and spin. Returns True when acquired; False on timeout.
  Stale locks older than STALE_LOCK_SECS are reclaimed. }
function AcquireLock(const LockDir: string): Boolean;
var
  Waited: Integer;
  Age: Int64;
  Info: TSearchRec;
begin
  Waited := 0;
  while Waited < LOCK_MAX_WAIT_MS do
  begin
    if CreateDir(LockDir) then Exit(True);
    { Already exists -- check whether it's stale. FindFirst on the
      directory itself gives us its mtime via SR.Time. }
    if FindFirst(LockDir, faDirectory, Info) = 0 then
    try
      { Info.TimeStamp is the modern TDateTime field -- the legacy
        Info.Time + FileDateToDateTime pair is deprecated on dcc64
        (W1000) and flagged platform-specific (W1002). TimeStamp
        has shipped on both FPC 3.0+ and Delphi for years. }
      Age := DateTimeToUnix(Now, False) - DateTimeToUnix(Info.TimeStamp, False);
      if Age > STALE_LOCK_SECS then
      begin
        LogWarn('steering: reclaiming stale lock %s (age=%ds)', [LockDir, Age]);
        RemoveDir(LockDir);
        Continue;
      end;
    finally
      { SysUtils.FindClose takes a TSearchRec; the Winapi.Windows
        version pulled in for RenameFile-inline takes a Handle.
        Fully-qualify so dcc64 picks the right overload. }
      SysUtils.FindClose(Info);
    end;
    Sleep(LOCK_SPIN_MS);
    Inc(Waited, LOCK_SPIN_MS);
  end;
  Result := False;
end;

procedure ReleaseLock(const LockDir: string);
begin
  RemoveDir(LockDir);
end;

function LockPath(const SessionKey: string): string;
begin
  Result := JoinPath(SteeringDir, SessionKey + '.jsonl.lock');
end;

function EncodeLine(PostedAt: Int64; const Text: string): string;
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutInt('at',   PostedAt);
    Obj.PutStr('text', Text);
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function DecodeLine(const Line: string; out Msg: TSteeringMessage): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  if Trim(Line) = '' then Exit;
  Obj := TJsonObject.Parse(Line);
  if Obj = nil then Exit;
  try
    Msg.PostedAt := Obj.GetInt('at',   0);
    Msg.Text     := Obj.GetStr('text', '');
  finally
    Obj.Free;
  end;
  Result := Msg.Text <> '';
end;

function PushSteering(const SessionKey, Text: string): Boolean;
var
  Path, Lock: string;
  Stream: TFileStream;
  Line: UTF8String;
  TrimmedText: string;
begin
  Result := False;
  TrimmedText := Trim(Text);
  if TrimmedText = '' then Exit;
  Path := SteeringPath(SessionKey);
  if Path = '' then Exit;

  { Wrap directory creation, lock acquisition, and the write in
    try/except so a read-only $PASCLAW_HOME, a permissions denial,
    or a vanishing disk yields the documented False return instead
    of an exception propagating out of the CLI. (Codex P2 on PR #120.) }
  try
    EnsureSteeringDir;
  except
    on E: Exception do
    begin
      LogWarn('steering: cannot create %s: %s', [SteeringDir, E.Message]);
      Exit;
    end;
  end;

  Lock := LockPath(SessionKey);
  if not AcquireLock(Lock) then
  begin
    LogWarn('steering: lock acquisition timed out for %s', [SessionKey]);
    Exit;
  end;
  try
    try
      if FileExists(Path) then
        Stream := TFileStream.Create(Path, fmOpenWrite or fmShareDenyWrite)
      else
        Stream := TFileStream.Create(Path, fmCreate);
    except
      on E: Exception do
      begin
        LogWarn('steering: cannot open %s for append: %s', [Path, E.Message]);
        Exit;
      end;
    end;
    try
      try
        Stream.Seek(0, soEnd);
        Line := UTF8String(EncodeLine(NowUnix, TrimmedText) + #10);
        Stream.WriteBuffer(Pointer(Line)^, Length(Line));
        Result := True;
      except
        on E: Exception do
          LogWarn('steering: write to %s failed: %s', [Path, E.Message]);
      end;
    finally
      Stream.Free;
    end;
  finally
    ReleaseLock(Lock);
  end;
end;

{ Replace the queue file with these lines, as raw bytes.

  Not SaveToFile: the lines are UTF-8 on disk and a TStringList write
  would put them through the RTL's encoding, which PushSteering
  deliberately avoids by writing bytes itself. Same contract here --
  what came off disk goes back byte-for-byte. }
function RewriteQueue(const Path: string; Lines: TStringList): Boolean;
var
  Stream: TFileStream;
  Raw: AnsiString;
  i: Integer;
begin
  Result := False;
  try
    Stream := TFileStream.Create(Path, fmCreate);
    try
      for i := 0 to Lines.Count - 1 do
      begin
        Raw := AnsiString(Lines[i]) + #10;
        if Length(Raw) > 0 then
          Stream.WriteBuffer(Raw[1], Length(Raw));
      end;
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on E: Exception do
      LogWarn('steering: could not rewrite %s: %s', [Path, E.Message]);
  end;
end;

function DrainSteering(const SessionKey: string; MaxMessages: Integer): TSteeringMessageArray;
var
  Path, DrainPath, Lock: string;
  S, Rest, Fresh: TStringList;
  i, Kept, RestFrom: Integer;
  Msg: TSteeringMessage;
begin
  SetLength(Result, 0);
  Path := SteeringPath(SessionKey);
  if Path = '' then Exit;

  Lock := LockPath(SessionKey);
  if not AcquireLock(Lock) then
  begin
    { Benign and self-healing: we never renamed the queue file, so the
      pending messages are still there and the next loop iteration's
      drain picks them up. This only trips under lock contention (a
      concurrent push/drain, or a stale lock not yet reclaimed) and fires
      at the loop's per-iteration cadence -- warn-level spam for a
      condition that needs no operator action. Debug keeps it diagnosable
      without the noise. }
    LogDebug('steering: drain lock contended for %s (retrying next turn)', [SessionKey]);
    Exit;
  end;
  try
    if not FileExists(Path) then Exit;
    DrainPath := Path + '.draining';
    { Inside the lock the rename is uncontended -- but keep the
      rename anyway so a stale-lock reclaim mid-drain doesn't
      surprise a concurrent reader with mid-read deletion. }
    if FileExists(DrainPath) then SysUtils.DeleteFile(DrainPath);
    if not RenameFile(Path, DrainPath) then Exit;
    S := TStringList.Create;
    try
      try
        { The writer below encodes UTF-8 by hand precisely because a TStrings
          write would not; the readers have to match it. }
        S.Text := ReadFileText(DrainPath);
      except
        on E: Exception do
        begin
          LogWarn('steering: drain read failed (%s); discarding queue', [E.Message]);
          SysUtils.DeleteFile(DrainPath);
          Exit;
        end;
      end;
      Kept := 0;
      RestFrom := -1;
      for i := 0 to S.Count - 1 do
      begin
        if Kept >= MaxMessages then
        begin
          RestFrom := i;
          Break;
        end;
        if DecodeLine(S[i], Msg) then
        begin
          SetLength(Result, Length(Result) + 1);
          Result[High(Result)] := Msg;
          Inc(Kept);
        end;
      end;
      (* The overflow is KEPT, not dropped.

         The cap bounds how much one turn injects -- a runaway pusher
         must not grow Hist without limit -- and putting the rest back
         preserves that while ending the silent loss: the next
         iteration's drain takes the next MaxMessages. Dropping was
         survivable when the queue was a human typing course
         corrections; it is not when the queue is an agent's MAILBOX
         (PasClaw.Agents), where message five onward was recorded as
         delivered in messages.jsonl, never shown to the agent, and the
         pending count fell to zero as if it had been read.

         Order matters and is why the leftovers go FIRST: anything a
         push added after the rename landed in a fresh queue file and is
         NEWER than what we are putting back. Both writes happen while
         we still hold the mutex, so no third party is mid-write. *)
      if RestFrom >= 0 then
      begin
        Rest := TStringList.Create;
        try
          for i := RestFrom to S.Count - 1 do
            Rest.Add(S[i]);
          if FileExists(Path) then
          begin
            Fresh := TStringList.Create;
            try
              try
                Fresh.Text := ReadFileText(Path);
                for i := 0 to Fresh.Count - 1 do
                  Rest.Add(Fresh[i]);
              except
                { An unreadable fresh queue is not a reason to lose the
                  leftovers we already hold. }
                on E: Exception do
                  LogWarn('steering[%s]: could not re-read the queue while ' +
                          'preserving overflow: %s', [SessionKey, E.Message]);
              end;
            finally
              Fresh.Free;
            end;
          end;
          { Written as raw bytes, the way PushSteering writes them --
            SaveToFile would re-encode, and these lines are already
            UTF-8 on disk. }
          if not RewriteQueue(Path, Rest) then
            LogWarn('steering[%s]: could not put %d pending message(s) back',
                    [SessionKey, Rest.Count])
          else
            LogDebug('steering[%s]: took %d, kept %d for the next iteration',
                     [SessionKey, Kept, Rest.Count]);
        finally
          Rest.Free;
        end;
      end;
    finally
      S.Free;
      SysUtils.DeleteFile(DrainPath);
    end;
  finally
    ReleaseLock(Lock);
  end;
end;

procedure ClearSteering(const SessionKey: string);
var
  Path, Lock: string;
begin
  Path := SteeringPath(SessionKey);
  if Path = '' then Exit;
  Lock := LockPath(SessionKey);
  if not AcquireLock(Lock) then Exit;   { best-effort -- no log spam }
  try
    if FileExists(Path) then SysUtils.DeleteFile(Path);
  finally
    ReleaseLock(Lock);
  end;
end;

function PendingSteeringCount(const SessionKey: string): Integer;
var
  Path: string;
  S: TStringList;
begin
  Result := 0;
  Path := SteeringPath(SessionKey);
  if (Path = '') or (not FileExists(Path)) then Exit;
  S := TStringList.Create;
  try
    try
      S.Text := ReadFileText(Path);
    except
      Exit;
    end;
    Result := S.Count;
  finally
    S.Free;
  end;
end;

end.
