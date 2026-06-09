program output_cache_tests;
(*
  Covers PasClaw.Tools.OutputCache -- the truncation + handle layer
  RunToolLoop calls into when Cfg.ToolOutputCap > 0.

  We pin:
    - small outputs pass through untouched (no handle stashed)
    - outputs above the cap get a handle + head + tail + elision notice
    - the stashed handle round-trips bytes-for-bytes via FetchStashedOutput
    - bad / unknown / out-of-range handles return clean errors
    - the cache stats counter reflects what's actually held

  Tests run with ClearOutputCache between cases so they don't see
  each other's handles; the cache is a process-lifetime singleton
  (it has to be -- the tool_output_get handler can only reach it
  that way).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Tools.OutputCache;

procedure Fail(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

procedure AssertEqInt(Got, Want: Int64; const Msg: string);
begin
  if Got <> Want then
    Fail(Msg + ' (got ' + IntToStr(Got) + ', want ' + IntToStr(Want) + ')');
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail(Msg);
end;

procedure TestPassThroughBelowCap;
{ Outputs at or under the cap should come back identically and not
  consume a handle slot. Otherwise we'd pay the bookkeeping cost
  on every tiny tool result. }
var
  Out_: string;
  Trunc: Boolean;
  EntryCount: Integer;
  TotalBytes: Int64;
begin
  ClearOutputCache;
  Out_ := StashAndMaybeTruncate('hello world', 4096, Trunc);
  AssertEqStr(Out_, 'hello world', 'short output round-trips verbatim');
  AssertTrue(not Trunc, 'short output is not flagged truncated');
  GetOutputCacheStats(EntryCount, TotalBytes);
  AssertEqInt(EntryCount, 0, 'no handle stashed for short output');
end;

procedure TestPassThroughOnCapZero;
{ Cap = 0 means "feature off" -- even huge outputs go through
  verbatim. Important so the default config keeps the legacy
  behaviour until the operator opts in. }
var
  Big, Out_: string;
  Trunc: Boolean;
begin
  ClearOutputCache;
  Big := StringOfChar('x', 100000);
  Out_ := StashAndMaybeTruncate(Big, 0, Trunc);
  AssertEqInt(Length(Out_), 100000, 'cap=0 leaves output untouched');
  AssertTrue(not Trunc, 'cap=0 never flags truncation');
end;

procedure TestTruncateAboveCap;
{ Output above the cap should be replaced with a multi-line notice
  containing the handle, byte count, head, elision, tail. The
  in-context replacement length must actually be smaller than the
  original -- otherwise we'd be making context usage worse. }
var
  Big, Out_, Bytes, Err: string;
  Trunc: Boolean;
  Handle: string;
  P: Integer;
  EntryCount: Integer;
  TotalBytes: Int64;
begin
  ClearOutputCache;
  Big := StringOfChar('a', 4000) + StringOfChar('b', 4000) + StringOfChar('c', 4000);
  Out_ := StashAndMaybeTruncate(Big, 2048, Trunc, 800, 400);
  AssertTrue(Trunc, 'oversize output is flagged truncated');
  AssertTrue(Length(Out_) < Length(Big),
             'truncated replacement is smaller than original');
  AssertTrue(Pos('truncated', Out_) > 0, 'notice mentions "truncated"');
  AssertTrue(Pos('handle=', Out_) > 0, 'notice carries handle');
  AssertTrue(Pos('elided', Out_) > 0, 'notice carries elision count');

  { Pull the handle out so we can verify the round-trip. Format
    "handle=tcXXXXXX" up to the next "]" closer. }
  P := Pos('handle=', Out_);
  if P <= 0 then Fail('no handle= in truncation notice');
  Handle := Copy(Out_, P + Length('handle='),
                 Pos(']', Copy(Out_, P, Length(Out_))) -
                 Length('handle=') - 1);
  AssertTrue(Length(Handle) > 0, 'extracted non-empty handle');

  GetOutputCacheStats(EntryCount, TotalBytes);
  AssertEqInt(EntryCount, 1, 'one handle stashed after truncation');
  AssertEqInt(TotalBytes, Length(Big), 'cache holds the full original bytes');

  if not FetchStashedOutput(Handle, 0, -1, Bytes, Err) then
    Fail('fetch of valid handle failed: ' + Err);
  AssertEqInt(Length(Bytes), Length(Big),
              'full-fetch returns the original byte count');
  AssertTrue(Bytes = Big, 'full-fetch round-trips exact bytes');
end;

procedure TestFetchSliceRange;
{ The model can call tool_output_get with offset/len to page through
  a stashed body. Verify the slice math: offset clamped to 0,
  offset past end returns empty, len = -1 means "to end". }
var
  Big, Out_, Bytes, Err: string;
  Trunc: Boolean;
  Handle: string;
  P: Integer;
begin
  ClearOutputCache;
  Big := StringOfChar('x', 5000);
  Out_ := StashAndMaybeTruncate(Big, 100, Trunc, 40, 20);
  AssertTrue(Trunc, 'precondition: 5000-byte body truncated at 100');
  P := Pos('handle=', Out_);
  Handle := Copy(Out_, P + Length('handle='),
                 Pos(']', Copy(Out_, P, Length(Out_))) -
                 Length('handle=') - 1);

  { mid-range slice }
  if not FetchStashedOutput(Handle, 100, 50, Bytes, Err) then
    Fail('mid-range fetch failed: ' + Err);
  AssertEqInt(Length(Bytes), 50, 'mid-range returns requested length');

  { offset past end is not an error -- returns empty so the model
    can probe without crashing the tool. }
  if not FetchStashedOutput(Handle, 100000, 10, Bytes, Err) then
    Fail('past-end fetch should succeed with empty bytes');
  AssertEqInt(Length(Bytes), 0, 'past-end returns empty slice');

  { negative offset clamps to 0 }
  if not FetchStashedOutput(Handle, -10, 5, Bytes, Err) then
    Fail('negative-offset fetch should clamp to 0');
  AssertEqInt(Length(Bytes), 5, 'negative-offset clamps and reads from 0');

  { len > remaining is clamped }
  if not FetchStashedOutput(Handle, 4990, 100, Bytes, Err) then
    Fail('len > remaining should clamp');
  AssertEqInt(Length(Bytes), 10, 'len clamps to remaining bytes');
end;

procedure TestFetchUnknownHandle;
{ The tool handler returns the error message so the model can see
  what went wrong rather than getting a silent empty body. }
var
  Bytes, Err: string;
begin
  ClearOutputCache;
  if FetchStashedOutput('tcDEADBEEF', 0, -1, Bytes, Err) then
    Fail('unknown handle should not succeed');
  AssertTrue(Err <> '', 'unknown handle populates error message');
  AssertTrue(Pos('no such handle', Err) > 0,
             'error message identifies the problem');
end;

procedure TestFetchEmptyHandle;
var
  Bytes, Err: string;
begin
  ClearOutputCache;
  if FetchStashedOutput('', 0, -1, Bytes, Err) then
    Fail('empty handle should not succeed');
  AssertTrue(Err <> '', 'empty handle populates error message');
end;

procedure TestStatsAfterMultipleStashes;
{ Stats should reflect every stashed entry. Caller surfaces this in
  the TUI /stats overlay so the operator can see how much memory
  the cache is holding. }
var
  Out1, Out2, Out3: string;
  Trunc: Boolean;
  EntryCount: Integer;
  TotalBytes: Int64;
begin
  ClearOutputCache;
  Out1 := StashAndMaybeTruncate(StringOfChar('a', 5000), 1000, Trunc);
  Out2 := StashAndMaybeTruncate(StringOfChar('b', 3000), 1000, Trunc);
  Out3 := StashAndMaybeTruncate(StringOfChar('c', 7000), 1000, Trunc);
  if Out1 = '' then ;  { silence unused warning }
  if Out2 = '' then ;
  if Out3 = '' then ;

  GetOutputCacheStats(EntryCount, TotalBytes);
  AssertEqInt(EntryCount, 3, 'three handles stashed');
  AssertEqInt(TotalBytes, 15000, 'cache holds 5000+3000+7000 = 15000 bytes');
end;

begin
  TestPassThroughBelowCap;
  TestPassThroughOnCapZero;
  TestTruncateAboveCap;
  TestFetchSliceRange;
  TestFetchUnknownHandle;
  TestFetchEmptyHandle;
  TestStatsAfterMultipleStashes;
  WriteLn('output_cache_tests: OK');
end.
