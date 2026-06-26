(*
  PasClaw.Memory.AutoDistill - fire-and-forget per-turn fact distillation.

  When memory_distill_enabled is on, each completed turn schedules a
  BACKGROUND distill of the latest exchange: extract facts with the chat
  provider (PasClaw.Memory.Distill) and persist them to the SQLite fact
  store (PasClaw.Memory.Facts). Background so the ~one extra LLM call
  never adds latency to the user's turn.

  Scope of each pass is the RECENT TAIL, not the whole session: the new
  user/assistant exchange plus a few prior messages for grounding. That
  keeps the prompt bounded (cost doesn't grow with session length) and
  avoids re-extracting facts already stored every turn. Exact-text dedup
  in the fact store collapses the residual repeats; semantic dedup is a
  later phase.

  Lifecycle: each schedule spins one TThread with FreeOnTerminate. A
  small global cap (MaxConcurrentDistill) drops new jobs when the
  backlog is saturated -- distilled memory is best-effort, never worth
  unbounded threads or blocking a turn.
*)
unit PasClaw.Memory.AutoDistill;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

const
  { Default number of trailing messages handed to the distiller -- the
    new exchange plus a little grounding context. The distiller also
    caps by bytes, so this is just a message-count ceiling. }
  DefaultRecentMsgs = 8;
  { At most this many distill jobs in flight at once; extra turns skip
    (best-effort). }
  MaxConcurrentDistill = 2;

{ Build the recent-tail transcript for a turn: the last MaxMsgs of Full,
  with FinalContent appended as a trailing assistant message when it's
  non-empty (RunToolLoop returns FinalMessages BEFORE the final answer,
  so callers pass Loop.Content here to include it). }
function BuildRecentTranscript(const Full: array of TMessage;
                               const FinalContent: string;
                               MaxMsgs: Integer): TMessageArray;

{ Schedule a background distill of Transcript for SessionId, persisting
  to <HomeDir>/workspace/memory/facts.db. No-op when Provider is nil,
  the transcript is empty, or the concurrency cap is hit. Never raises. }
procedure ScheduleDistill(Provider: ILLMProvider; const Model, HomeDir,
                          SessionId: string; const Transcript: array of TMessage);

implementation

uses
  DateUtils,
  SyncObjs,
  PasClaw.Logger,
  PasClaw.Memory.Distill,
  PasClaw.Memory.Facts;

var
  GLock:   TCriticalSection;
  GActive: Integer;

type
  TDistillThread = class(TThread)
  private
    FProvider:  ILLMProvider;
    FModel:     string;
    FHome:      string;
    FSession:   string;
    FTranscript: TMessageArray;
  protected
    procedure Execute; override;
  end;

procedure TDistillThread.Execute;
var
  Distiller: TMemoryDistiller;
  Store: IFactStore;
  Facts: TFactArray;
  Err, Today: string;
  i: Integer;
  NowU: Int64;
begin
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    Distiller := TMemoryDistiller.Create(FProvider, FModel);
    try
      if not Distiller.Distill(FTranscript, FSession, Today, Facts, Err) then
      begin
        LogDebug('auto-distill: %s', [Err]);
        Exit;
      end;
    finally
      Distiller.Free;
    end;

    if Length(Facts) = 0 then Exit;

    Store := NewFactStore;
    if not Store.Open(DefaultFactsDbPath(FHome)) then Exit;
    try
      NowU := DateTimeToUnix(Now, False);
      for i := 0 to High(Facts) do
        Store.Add(Facts[i], NowU + i);
    finally
      Store.Close;
    end;
    LogDebug('auto-distill: stored %d fact(s) from session %s',
             [Length(Facts), FSession]);
  except
    on E: Exception do
      LogWarn('auto-distill: %s', [E.Message]);
  end;
  GLock.Acquire;
  try
    Dec(GActive);
  finally
    GLock.Release;
  end;
end;

function BuildRecentTranscript(const Full: array of TMessage;
  const FinalContent: string; MaxMsgs: Integer): TMessageArray;
var
  StartIdx, i, n: Integer;
begin
  SetLength(Result, 0);
  if MaxMsgs <= 0 then MaxMsgs := DefaultRecentMsgs;
  StartIdx := Length(Full) - MaxMsgs;
  if StartIdx < 0 then StartIdx := 0;
  n := 0;
  for i := StartIdx to High(Full) do
  begin
    SetLength(Result, n + 1);
    Result[n] := Full[i];
    Inc(n);
  end;
  if Trim(FinalContent) <> '' then
  begin
    SetLength(Result, n + 1);
    Result[n] := MakeMessage(mrAssistant, FinalContent);
  end;
end;

procedure ScheduleDistill(Provider: ILLMProvider; const Model, HomeDir,
  SessionId: string; const Transcript: array of TMessage);
var
  T: TDistillThread;
  i: Integer;
begin
  if (Provider = nil) or (Length(Transcript) = 0) then Exit;

  GLock.Acquire;
  try
    if GActive >= MaxConcurrentDistill then
    begin
      LogDebug('auto-distill: %d in flight (cap %d) -- skipping this turn',
               [GActive, MaxConcurrentDistill]);
      Exit;
    end;
    Inc(GActive);
  finally
    GLock.Release;
  end;

  try
    T := TDistillThread.Create(True);   { suspended }
    T.FreeOnTerminate := True;
    T.FProvider := Provider;
    T.FModel    := Model;
    T.FHome     := HomeDir;
    T.FSession  := SessionId;
    SetLength(T.FTranscript, Length(Transcript));
    for i := 0 to High(Transcript) do
      T.FTranscript[i] := Transcript[i];
    T.Start;
  except
    on E: Exception do
    begin
      { Failed to even launch -- release the slot we reserved. }
      GLock.Acquire;
      try
        Dec(GActive);
      finally
        GLock.Release;
      end;
      LogWarn('auto-distill: schedule failed: %s', [E.Message]);
    end;
  end;
end;

initialization
  GLock := TCriticalSection.Create;
  GActive := 0;

finalization
  GLock.Free;

end.
