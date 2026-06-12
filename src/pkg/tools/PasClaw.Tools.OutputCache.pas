{
  PasClaw.Tools.OutputCache - cap how much tool output enters the LLM
  context window. Large outputs (web fetches, recursive greps,
  multi-thousand-line file reads) routinely dump 20-50 KB of raw bytes
  into the message history; after a dozen of those, the bulk of the
  context budget is tool noise the model rarely needs in full.

  Flow:

    1. RunToolLoop calls StashAndMaybeTruncate(ResultText, Cap) before
       appending the tool_result to history.
    2. If Length(ResultText) <= Cap, returns ResultText unchanged.
    3. Otherwise stashes the full bytes under a fresh handle, returns
       a compact message containing the head + tail of the output plus
       the handle so the LLM can opt into fetching the rest.

  The `tool_output_get` tool registered here reads from the same
  process-lifetime in-memory store. Handles are valid until the
  pasclaw process exits -- long enough for the agent loop to decide
  whether to dereference, short enough that we don't grow unbounded
  across runs. (A future PR can persist to $PASCLAW_HOME/cache/ if
  resume-across-restart matters.)

  Thread-safety: tool dispatch is parallel for tcReadOnly batches
  (PasClaw.Tools.ToolLoop), so multiple workers can be stashing or
  reading at once. The store sits behind a TCriticalSection.
}
unit PasClaw.Tools.OutputCache;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Tools.Registry;

{ If Length(Body) <= Cap (or Cap <= 0), returns Body unchanged and
  Truncated = False. Otherwise stashes Body under a fresh handle and
  returns a multi-line message containing the head + tail of the
  output plus "use tool_output_get(handle=...)" -- Truncated = True.

  HeadBytes / TailBytes are caps on the visible head and tail slices;
  defaults pick a reasonable split when callers don't care. }
function StashAndMaybeTruncate(const Body: string; Cap: Integer;
                               out Truncated: Boolean;
                               HeadBytes: Integer = 2048;
                               TailBytes: Integer = 1024): string;

{ Read a slice of a stashed output. Offset/Len in bytes (Length()
  semantics). Len < 0 means "to end". Used by the tool_output_get
  handler; also exposed for tests. }
function FetchStashedOutput(const Handle: string;
                            Offset, Len: Integer;
                            out Bytes: string;
                            out ErrMsg: string): Boolean;

{ How many entries are currently held + total bytes -- surfaced by
  /stats. Cheap to call; takes the lock for the snapshot. }
procedure GetOutputCacheStats(out EntryCount: Integer;
                              out TotalBytes: Int64);

{ Resets the store. Called between top-level CLI invocations would
  defeat the purpose; the TUI doesn't call it. Exposed for tests. }
procedure ClearOutputCache;

{ Reversible condensation (CCR, headroom-inspired). When a condenser
  (PasClaw.Condense.JSON, PasClaw.Tools.Shell.Filters) actually shrinks
  output, callers wrap their (Original, Condensed) pair through here:
  if the saving exceeds MinSavingsBytes, stash the ORIGINAL bytes under
  a fresh handle and append a footer pointing the model at
  tool_output_get for the full text. Otherwise return Condensed
  unchanged. The model gets the structural summary by default; the
  bytes-as-written remain reachable on demand. Same OutputCache the
  byte-budget truncation already uses -- one stash hub, one retrieval
  tool. No-op when SetCondenseReversible(False) was called from
  config.json. }
function AttachReversibleStashFooter(const Original, Condensed: string;
                                     MinSavingsBytes: Integer = 256): string;

{ Process-wide enable switch for AttachReversibleStashFooter. Default
  True; LoadConfig propagates Cfg.CondenseReversible here. Mirrors
  PasClaw.Promptware.SetPromptwareEnabled. }
procedure SetCondenseReversible(AEnabled: Boolean);
function CondenseReversibleEnabled: Boolean;

{ Counters: how many condense outputs were stashed reversibly + the
  cumulative bytes the model would have otherwise lost access to.
  Surfaced by the TUI /stats overlay alongside the byte-cap savings. }
function CondenseStashCount: Int64;
function CondenseStashBytesPreserved: Int64;

{ Adds the `tool_output_get` tool to the registry. Callers only invoke
  this when the truncation feature is on (Cfg.ToolOutputCap > 0) -- no
  point advertising a tool that always returns "no handle". }
procedure RegisterOutputCacheTool(R: TToolRegistry);

implementation

uses
  PasClaw.Tools.Types,
  PasClaw.JSON;

const
  HANDLE_PREFIX = 'tc';     { tool-cache; short so the truncation
                              notice stays compact in context }

type
  TOutputEntry = record
    Handle: string;
    Body:   string;
  end;

var
  GLock:     TCriticalSection;
  GEntries:  array of TOutputEntry;
  GCounter:  Int64;             { monotonic; combined with PID-ish
                                  randomness for the handle id }
  GCondenseReversible: Boolean = True;   { LoadConfig forwards Cfg.CondenseReversible here. }
  GCondenseStashCount: Int64 = 0;
  GCondenseStashBytes: Int64 = 0;

function IndexOfHandle(const Handle: string): Integer;
{ Caller holds GLock. Linear scan -- entry count rarely exceeds the
  dozens, so a hash map's overhead would dominate. }
var
  i: Integer;
begin
  for i := 0 to High(GEntries) do
    if GEntries[i].Handle = Handle then
      Exit(i);
  Result := -1;
end;

function NewHandle: string;
var
  N: Int64;
begin
  GLock.Enter;
  try
    Inc(GCounter);
    N := GCounter;
  finally
    GLock.Leave;
  end;
  Result := HANDLE_PREFIX + IntToHex(N, 6);
end;

function StashAndMaybeTruncate(const Body: string; Cap: Integer;
                               out Truncated: Boolean;
                               HeadBytes: Integer;
                               TailBytes: Integer): string;
var
  Handle, Head, Tail: string;
  Elided: Integer;
begin
  Truncated := False;
  if (Cap <= 0) or (Length(Body) <= Cap) then
    Exit(Body);

  { Head + tail can't add up to more than the cap or we negate the
    point of truncating. Shrink proportionally if the caller passed
    oversize values. }
  if HeadBytes + TailBytes >= Cap then
  begin
    HeadBytes := (Cap * 2) div 3;       { 2/3 head, 1/3 tail }
    TailBytes := Cap - HeadBytes - 256; { leave room for the notice }
    if TailBytes < 0 then TailBytes := 0;
  end;

  Head := Copy(Body, 1, HeadBytes);
  if Length(Body) > TailBytes then
    Tail := Copy(Body, Length(Body) - TailBytes + 1, TailBytes)
  else
    Tail := '';
  Elided := Length(Body) - Length(Head) - Length(Tail);

  Handle := NewHandle;
  GLock.Enter;
  try
    SetLength(GEntries, Length(GEntries) + 1);
    GEntries[High(GEntries)].Handle := Handle;
    GEntries[High(GEntries)].Body   := Body;
  finally
    GLock.Leave;
  end;

  Truncated := True;
  Result :=
    Format('[tool output truncated: %d bytes, handle=%s]', [Length(Body), Handle]) +
    sLineBreak + '--- first ' + IntToStr(Length(Head)) + ' bytes ---' + sLineBreak +
    Head + sLineBreak +
    Format('... %d bytes elided ...', [Elided]) + sLineBreak;
  if Tail <> '' then
    Result := Result +
      '--- last ' + IntToStr(Length(Tail)) + ' bytes ---' + sLineBreak +
      Tail + sLineBreak;
  Result := Result +
    Format('[call tool_output_get(handle="%s", offset=N, len=M) for more]',
           [Handle]);
end;

function FetchStashedOutput(const Handle: string;
                            Offset, Len: Integer;
                            out Bytes: string;
                            out ErrMsg: string): Boolean;
var
  Full: string;
  Idx, Take: Integer;
begin
  Result  := False;
  Bytes   := '';
  ErrMsg  := '';
  if Handle = '' then
  begin
    ErrMsg := 'handle required';
    Exit;
  end;
  GLock.Enter;
  try
    Idx := IndexOfHandle(Handle);
    if Idx < 0 then
    begin
      ErrMsg := 'no such handle: ' + Handle;
      Exit;
    end;
    Full := GEntries[Idx].Body;
  finally
    GLock.Leave;
  end;

  if Offset < 0 then Offset := 0;
  if Offset >= Length(Full) then
  begin
    Bytes := '';
    Exit(True);
  end;
  if Len < 0 then
    Take := Length(Full) - Offset
  else
    Take := Len;
  if Offset + Take > Length(Full) then
    Take := Length(Full) - Offset;
  Bytes  := Copy(Full, Offset + 1, Take);
  Result := True;
end;

procedure GetOutputCacheStats(out EntryCount: Integer; out TotalBytes: Int64);
var
  i: Integer;
begin
  GLock.Enter;
  try
    EntryCount := Length(GEntries);
    TotalBytes := 0;
    for i := 0 to High(GEntries) do
      Inc(TotalBytes, Length(GEntries[i].Body));
  finally
    GLock.Leave;
  end;
end;

procedure ClearOutputCache;
begin
  GLock.Enter;
  try
    SetLength(GEntries, 0);
    GCounter := 0;
  finally
    GLock.Leave;
  end;
end;

procedure SetCondenseReversible(AEnabled: Boolean);
begin
  GCondenseReversible := AEnabled;
end;

function CondenseReversibleEnabled: Boolean;
begin
  Result := GCondenseReversible;
end;

function CondenseStashCount: Int64;        begin Result := GCondenseStashCount; end;
function CondenseStashBytesPreserved: Int64; begin Result := GCondenseStashBytes; end;

function AttachReversibleStashFooter(const Original, Condensed: string;
                                     MinSavingsBytes: Integer): string;
var
  Saved: Integer;
  Handle: string;
begin
  Result := Condensed;
  if not GCondenseReversible then Exit;
  { Length() is char-count, which for UTF-8 strings under FPC mode
    delphi (8-bit AnsiString) equals byte count -- same as everywhere
    else in this codebase that compares to byte caps. }
  Saved := Length(Original) - Length(Condensed);
  if Saved < MinSavingsBytes then Exit;
  { Stash the FULL original. The body is the bytes we want the model
    to be able to retrieve; the head/tail-splitting StashAndMaybeTruncate
    does is unhelpful here (the condenser already gave the model a
    shape-preserving view -- tool_output_get is the escape hatch when
    that shape isn't enough). Allocate a handle directly. }
  Handle := NewHandle;
  GLock.Enter;
  try
    SetLength(GEntries, Length(GEntries) + 1);
    GEntries[High(GEntries)].Handle := Handle;
    GEntries[High(GEntries)].Body   := Original;
    Inc(GCondenseStashCount);
    Inc(GCondenseStashBytes, Length(Original));
  finally
    GLock.Leave;
  end;
  Result := Condensed + sLineBreak +
    Format('[condensed %d -> %d bytes; full original at handle="%s" via tool_output_get]',
           [Length(Original), Length(Condensed), Handle]);
end;

function Tool_OutputGet(const ArgsJSON: string; out ErrMsg: string): string;
var
  Obj: TJsonObject;
  Handle: string;
  Offset, Len: Integer;
  Bytes, Err: string;
begin
  Result := '';
  ErrMsg := '';
  Obj := nil;
  try
    try
      Obj := TJsonObject.Parse(ArgsJSON);
    except
      on E: Exception do
      begin
        ErrMsg := 'args must be valid JSON: ' + E.Message;
        Exit;
      end;
    end;
    if Obj = nil then
    begin
      ErrMsg := 'args must be a JSON object';
      Exit;
    end;
    Handle := Obj.GetStr('handle', '');
    Offset := Integer(Obj.GetInt('offset', 0));
    Len    := Integer(Obj.GetInt('len', -1));
  finally
    Obj.Free;
  end;
  if not FetchStashedOutput(Handle, Offset, Len, Bytes, Err) then
  begin
    ErrMsg := Err;
    Exit;
  end;
  Result := Bytes;
end;

procedure RegisterOutputCacheTool(R: TToolRegistry);
var
  T: TTool;
begin
  T := Default(TTool);
  T.Name        := 'tool_output_get';
  T.Description := 'Read a slice of a stashed tool output. The truncation notice on a previous tool result contains the handle.';
  T.Schema      := '{"type":"object","properties":{' +
                   '"handle":{"type":"string","description":"Handle from the truncation notice."},' +
                   '"offset":{"type":"integer","description":"Byte offset to start at (default 0)."},' +
                   '"len":{"type":"integer","description":"Bytes to return; -1 = to end (default -1)."}' +
                   '},"required":["handle"]}';
  T.Handler     := Tool_OutputGet;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);
end;

initialization
  GLock  := TCriticalSection.Create;
  SetLength(GEntries, 0);
  GCounter := 0;

finalization
  SetLength(GEntries, 0);
  GLock.Free;

end.
