program bridge_wire_tests;
(*
  The DOS link without a DOS PC: PasClaw.Bridge.Wire (framing, CRC,
  resync), PasClaw.Bridge (routes, rewrites, the serve loop -- with the
  gateway stubbed), and the host-testable parts of the DOS client
  (CP437 text, the tools, the history cap, compact JSON).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils, Classes,
  PasClaw.JSON,
  PasClaw.Bridge.Wire,
  PasClaw.Bridge,
  PasClaw.Cmd.Bridge,
  PasClaw.Dos.Text,
  PasClaw.Dos.Link,
  PasClaw.Dos.Tools,
  PasClaw.Dos.Agent;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Msg: string);
begin
  if not Cond then
  begin
    WriteLn('FAIL: ' + Msg);
    Inc(Failures);
  end;
end;

procedure CheckEq(const Got, Want, Msg: string);
begin
  Check(Got = Want, Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

function Req(const Method, Path, Body: string): TWireMessage;
begin
  Result.Method := Method;
  Result.Path := Path;
  Result.Status := 0;
  Result.Reason := '';
  SetLength(Result.Headers, 0);
  Result.Body := StringToWireBody(Body);
end;

{ ---- wire ---- }

procedure TestCrc;
begin
  CheckEq(Crc32Hex('123456789'), 'cbf43926', 'CRC-32 check value');
  CheckEq(Crc32Hex(''), '00000000', 'CRC-32 of nothing');
end;

procedure TestRoundTrip;
var
  M, Got: TWireMessage;
  R: TWireStringReader;
  Err: string;
  Body: RawByteString;
  i: Integer;
begin
  { Every byte value survives, NUL and CR LF included. }
  SetLength(Body, 256);
  for i := 0 to 255 do Body[i + 1] := AnsiChar(i);
  M := Req('POST', '/v1/responses', '');
  M.Body := Body;
  WireSetHeader(M, WIRE_SEQ_HEADER, '42');
  WireSetHeader(M, 'Content-Length', '1');   { replaced, not trusted }
  R := TWireStringReader.Create(FormatWireRequest(M));
  try
    Check(ReadWireRequest(R, Got, 100, 100, Err), 'request round trip: ' + Err);
    CheckEq(Got.Method, 'POST', 'method');
    CheckEq(Got.Path, '/v1/responses', 'path');
    CheckEq(WireHeader(Got, WIRE_SEQ_HEADER), '42', 'seq header');
    Check(Got.Body = Body, 'all 256 byte values come back');
    CheckEq(WireHeader(Got, 'content-length'), '256', 'Content-Length set from the body');
  finally
    R.Free;
  end;

  M := Req('', '', '{"output":[]}');
  M.Status := 403;
  R := TWireStringReader.Create(FormatWireResponse(M));
  try
    Check(ReadWireResponse(R, Got, 100, 100, Err), 'response round trip: ' + Err);
    Check(Got.Status = 403, 'status');
    CheckEq(Got.Reason, 'Forbidden', 'reason filled in');
    CheckEq(WireBodyToString(Got.Body), '{"output":[]}', 'body');
  finally
    R.Free;
  end;
end;

procedure TestCrcMismatch;
var
  Wire: RawByteString;
  R: TWireStringReader;
  Got: TWireMessage;
  Err: string;
  P: Integer;
begin
  Wire := FormatWireRequest(Req('POST', '/v1/responses', '{"input":"hello"}'));
  { One flipped bit in the body. }
  P := Pos('hello', Wire);
  Wire[P] := 'j';
  R := TWireStringReader.Create(Wire);
  try
    Check(not ReadWireRequest(R, Got, 100, 100, Err), 'a damaged body is refused');
    Check(Copy(Err, 1, 4) = 'crc:', 'the error says crc: ' + Err);
    CheckEq(Got.Method, 'POST', 'the head is still there to answer');
  finally
    R.Free;
  end;
  { No CRC header at all (curl, socat): accepted. }
  R := TWireStringReader.Create('GET /v1/health HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  try
    Check(ReadWireRequest(R, Got, 100, 100, Err), 'a request without the CRC header: ' + Err);
  finally
    R.Free;
  end;
end;

procedure TestResyncAndErrors;
var
  R: TWireStringReader;
  Got: TWireMessage;
  Err: string;
begin
  R := TWireStringReader.Create(#0#255'noise'#13#10'more noise here'#13#10#13#10 +
                                FormatWireRequest(Req('GET', '/v1/health', '')));
  try
    Check(ReadWireRequest(R, Got, 100, 100, Err), 'found after noise: ' + Err);
    CheckEq(Got.Path, '/v1/health', 'the right request');
  finally
    R.Free;
  end;
  R := TWireStringReader.Create('');
  try
    Check(not ReadWireRequest(R, Got, 10, 10, Err), 'nothing');
    CheckEq(Err, 'idle', 'nothing at all is idle');
  finally
    R.Free;
  end;
  R := TWireStringReader.Create('POST /x HTTP/1.1'#13#10'Content-Length: 10'#13#10#13#10'abc');
  try
    Check(not ReadWireRequest(R, Got, 10, 10, Err), 'cut-off body');
    Check(Pos('cut off', Err) > 0, 'says cut off: ' + Err);
  finally
    R.Free;
  end;
  R := TWireStringReader.Create('POST /x HTTP/1.1'#13#10'Transfer-Encoding: chunked'#13#10#13#10);
  try
    Check(not ReadWireRequest(R, Got, 10, 10, Err), 'chunked refused');
  finally
    R.Free;
  end;
  R := TWireStringReader.Create('POST /x HTTP/1.1'#13#10'Content-Length: 99999999'#13#10#13#10);
  try
    Check(not ReadWireRequest(R, Got, 10, 10, Err), 'oversized refused');
    Check(Pos('out of range', Err) > 0, 'says out of range: ' + Err);
  finally
    R.Free;
  end;
  R := TWireStringReader.Create('garbage'#13#10);
  try
    Check(not ReadWireResponse(R, Got, 10, 10, Err), 'a response must start with HTTP/');
  finally
    R.Free;
  end;
end;

{ ---- bridge, gateway stubbed ---- }

var
  StubMethod, StubURL, StubBody, StubToken: string;
  StubStatus: Integer;
  StubAnswer: string;
  StubUp: Boolean;

function StubForward(const Method, URL, Body, Token: string;
  TimeoutSec: Integer; out Status: Integer; out RespBody, Err: string): Boolean;
begin
  StubMethod := Method;
  StubURL := URL;
  StubBody := Body;
  StubToken := Token;
  Status := StubStatus;
  RespBody := StubAnswer;
  Err := 'connection refused';
  Result := StubUp;
end;

procedure TestBridgeHandle;
var
  Cfg: TBridgeConfig;
  M, R: TWireMessage;
  O: TJsonObject;
begin
  GBridgeForward := StubForward;
  Cfg.GatewayURL := 'http://gw:8088';
  Cfg.Token := 'tok';
  Cfg.Model := 'bridge-model';
  Cfg.TimeoutSec := 5;
  StubUp := True;
  StubStatus := 200;
  StubAnswer := '{"id":"r1","object":"response","status":"completed","tools":[{"type":"function","name":"x"}],' +
                '"instructions":null,"output":[{"type":"message","content":[{"type":"output_text","text":"hi"}]}],' +
                '"usage":{"input_tokens":3}}';

  { Not one of the three routes: refused, the gateway never asked. }
  StubURL := '';
  M := Req('GET', '/v1/config', '');
  WireSetHeader(M, WIRE_SEQ_HEADER, '9');
  R := BridgeHandle(Cfg, M);
  Check(R.Status = 403, '/v1/config is refused');
  CheckEq(StubURL, '', 'a refused route never reaches the gateway');
  CheckEq(WireHeader(R, WIRE_SEQ_HEADER), '9', 'seq echoed on a refusal');
  Check(not BridgeRouteAllowed('POST', '/v1/chat/completions'), 'chat/completions is not forwarded');
  Check(not BridgeRouteAllowed('GET', '/v1/responses'), 'GET /v1/responses is not forwarded');
  Check(not BridgeRouteAllowed('POST', '/v1/health'), 'POST /v1/health is not forwarded');
  Check(BridgeRouteAllowed('GET', '/v1/models?x=1'), 'a query string is fine');

  { The model call: stream off, model filled in, token sent, answer slimmed. }
  M := Req('POST', '/v1/responses', '{"input":"hi","stream":true}');
  WireSetHeader(M, WIRE_SEQ_HEADER, '10');
  R := BridgeHandle(Cfg, M);
  Check(R.Status = 200, 'forwarded');
  CheckEq(StubURL, 'http://gw:8088/v1/responses', 'to the gateway');
  CheckEq(StubToken, 'tok', 'with the token');
  O := TJsonObject.Parse(StubBody);
  try
    Check(not O.GetBool('stream', True), 'stream forced off');
    CheckEq(O.GetStr('model', ''), 'bridge-model', 'model filled in');
  finally
    O.Free;
  end;
  CheckEq(WireHeader(R, WIRE_SEQ_HEADER), '10', 'seq echoed');
  O := TJsonObject.Parse(WireBodyToString(R.Body));
  try
    Check(not O.Has('tools') and not O.Has('instructions') and not O.Has('object'),
          'the echo is cut from the answer');
    Check(O.Has('output') and O.Has('usage') and (O.GetStr('id', '') = 'r1') and
          (O.GetStr('status', '') = 'completed'), 'what the client reads is kept');
  finally
    O.Free;
  end;
  Check(Pos('"hi"', WireBodyToString(R.Body)) > 0, 'the output text survives');

  { A request naming its model keeps it. }
  BridgeHandle(Cfg, Req('POST', '/v1/responses', '{"input":"hi","model":"mine"}'));
  CheckEq(JsonReadStr(StubBody, 'model', ''), 'mine', 'the request''s model wins');

  { Not JSON: 400 here, not a gateway round trip. }
  StubURL := '';
  R := BridgeHandle(Cfg, Req('POST', '/v1/responses', 'not json'));
  Check(R.Status = 400, 'a non-JSON body is 400');
  CheckEq(StubURL, '', 'and never forwarded');

  { A gateway error passes through untouched (not slimmed). }
  StubStatus := 401;
  StubAnswer := '{"error":{"message":"unauthorized"}}';
  R := BridgeHandle(Cfg, Req('POST', '/v1/responses', '{"input":"hi"}'));
  Check(R.Status = 401, 'gateway status kept');
  CheckEq(ErrorMessageOf(WireBodyToString(R.Body)), 'unauthorized', 'gateway error kept');

  { Gateway down: 502 that says so. }
  StubUp := False;
  R := BridgeHandle(Cfg, Req('GET', '/v1/health', ''));
  Check(R.Status = 502, 'gateway down is 502');
  Check(Pos('connection refused', WireBodyToString(R.Body)) > 0, 'with the reason');
  StubUp := True;
end;

type
  TSink = class
    Data: RawByteString;
    function Write(const S: RawByteString): Boolean;
  end;

function TSink.Write(const S: RawByteString): Boolean;
begin
  Data := Data + S;
  Result := True;
end;

procedure TestServeStream;
var
  Cfg: TBridgeConfig;
  In_: RawByteString;
  Bad, M: TWireMessage;
  R, Out_: TWireStringReader;
  Sink: TSink;
  Stop: Boolean;
  Err: string;
  P: Integer;
begin
  GBridgeForward := StubForward;
  Cfg.GatewayURL := 'http://gw';
  Cfg.Token := '';
  Cfg.Model := '';
  Cfg.TimeoutSec := 5;
  StubUp := True;
  StubStatus := 200;
  StubAnswer := '{"status":"ok"}';
  Bad := Req('POST', '/v1/responses', '{"input":"abc"}');
  WireSetHeader(Bad, WIRE_SEQ_HEADER, '2');
  In_ := FormatWireRequest(Bad);
  P := Pos('abc', In_);
  In_[P] := 'x';
  M := Req('GET', '/v1/health', '');
  WireSetHeader(M, WIRE_SEQ_HEADER, '1');
  In_ := FormatWireRequest(M) + In_ + 'line noise'#13#10;
  M := Req('GET', '/v1/models', '');
  WireSetHeader(M, WIRE_SEQ_HEADER, '3');
  In_ := In_ + FormatWireRequest(M);
  R := TWireStringReader.Create(In_);
  Sink := TSink.Create;
  try
    Stop := False;
    BridgeServeStream(Cfg, R, Sink.Write, 'test', Stop);
    Out_ := TWireStringReader.Create(Sink.Data);
    try
      Check(ReadWireResponse(Out_, M, 10, 10, Err), 'answer 1: ' + Err);
      Check((M.Status = 200) and (WireHeader(M, WIRE_SEQ_HEADER) = '1'), 'health answered');
      Check(ReadWireResponse(Out_, M, 10, 10, Err), 'answer 2: ' + Err);
      Check((M.Status = 400) and (WireHeader(M, WIRE_SEQ_HEADER) = '2') and
            (ErrorMessageOf(WireBodyToString(M.Body)) = 'crc'), 'a bad CRC is answered 400 crc');
      Check(ReadWireResponse(Out_, M, 10, 10, Err), 'answer 3: ' + Err);
      Check((M.Status = 200) and (WireHeader(M, WIRE_SEQ_HEADER) = '3'), 'found after the noise');
      Check(not ReadWireResponse(Out_, M, 10, 10, Err), 'and nothing else');
    finally
      Out_.Free;
    end;
  finally
    Sink.Free;
    R.Free;
  end;
end;

procedure TestTarget;
var
  URL, Tok, Addr: string;
  Port: Integer;
begin
  URL := ResolveBridgeTarget('', '', False, 'http://127.0.0.1:8088/', 'cfgtok', 'envtok', Tok);
  CheckEq(URL, 'http://127.0.0.1:8088', 'the local gateway');
  CheckEq(Tok, 'cfgtok', 'gets this config''s token');
  URL := ResolveBridgeTarget('https://remote.example/', '', False, 'http://127.0.0.1:8088', 'cfgtok', 'envtok', Tok);
  CheckEq(URL, 'https://remote.example', 'a named gateway');
  CheckEq(Tok, 'envtok', 'gets the env token, never this config''s');
  URL := ResolveBridgeTarget('https://remote.example', '', False, 'http://127.0.0.1:8088', 'cfgtok', '', Tok);
  CheckEq(Tok, '', 'and no token when there is none in the env');
  URL := ResolveBridgeTarget('https://remote.example', 'flag', True, 'http://127.0.0.1:8088', 'cfgtok', 'envtok', Tok);
  CheckEq(Tok, 'flag', '--token wins');
  URL := ResolveBridgeTarget('', '', True, 'http://127.0.0.1:8088', 'cfgtok', 'envtok', Tok);
  CheckEq(Tok, '', 'an explicit empty --token sends none');

  Check(ParseListenSpec('5150', Addr, Port) and (Addr = '127.0.0.1') and (Port = 5150), 'port alone is loopback');
  Check(ParseListenSpec('0.0.0.0:23', Addr, Port) and (Addr = '0.0.0.0') and (Port = 23), 'addr:port');
  Check(ParseListenSpec('[::1]:5150', Addr, Port) and (Addr = '::1'), 'bracketed IPv6');
  Check(not ParseListenSpec('host:99999', Addr, Port), 'port out of range');
  Check(not ParseListenSpec('nope', Addr, Port), 'not a port');
end;

{ ---- the DOS client's host-testable parts ---- }

procedure TestCp437;
var
  i: Integer;
  All, Back: string;
begin
  SetLength(All, 128);
  for i := 128 to 255 do All[i - 127] := AnsiChar(i);
  Back := Utf8ToCp437(Cp437ToUtf8(All));
  Check(Back = All, 'all 128 high CP437 bytes survive UTF-8 and back');
  CheckEq(Utf8ToCp437('caf'#$C3#$A9), 'caf'#$82, 'e-acute is CP437 82');
  CheckEq(Utf8ToCp437(#$E2#$80#$94' '#$E2#$80#$9C'q'#$E2#$80#$9D' '#$E2#$80#$A6),
          '-- "q" ...', 'typography falls back to ASCII');
  CheckEq(Utf8ToCp437(#$E2#$94#$80#$E2#$94#$82), #$C4#$B3, 'box drawing maps to CP437 lines');
  CheckEq(Utf8ToCp437(#$F0#$9F#$98#$80'!'), '?!', 'an emoji is ?');
  CheckEq(Utf8ToCp437(#$E2#$80#$A2' x'), '* x', 'a bullet is * (CP437 7 rings the bell)');
  CheckEq(Cp437ToUtf8(#$82), #$C3#$A9, 'CP437 82 reads as e-acute');
end;

procedure TestWrap;
var
  L: TStringList;
begin
  L := WrapText('aaa bbb ccc ddd', 7);
  try
    Check((L.Count = 2) and (L[0] = 'aaa bbb') and (L[1] = 'ccc ddd'), 'wraps at a space: ' + L.CommaText);
  finally
    L.Free;
  end;
  L := WrapText('abcdefghij', 4);
  try
    Check((L.Count = 3) and (L[0] = 'abcd'), 'breaks a long word: ' + L.CommaText);
  finally
    L.Free;
  end;
  L := WrapText(#$C3#$A9#$C3#$A9#$C3#$A9, 2);
  try
    Check((L.Count = 2) and (L[0] = #$C3#$A9#$C3#$A9), 'counts characters, not bytes');
  finally
    L.Free;
  end;
end;

type
  TAsker = class
    Answer: Boolean;
    Asked: string;
    function Ask(const Q: string): Boolean;
  end;

function TAsker.Ask(const Q: string): Boolean;
begin
  Asked := Q;
  Result := Answer;
end;

procedure TestTools;
var
  Dir, F, Out_, Err, Data: string;
  IsErr: Boolean;
  A: TAsker;
  L: TStringList;
  i: Integer;
  Tools: TJsonArray;
begin
  Tools := TJsonArray.Parse(DosToolsJSON);
  try
    Check((Tools <> nil) and (Tools.Count = 5), 'five tools, valid JSON');
  finally
    Tools.Free;
  end;
  Dir := IncludeTrailingPathDelimiter(GetTempDir) + 'pclaw-tools-' + IntToStr(Random(1000000));
  ForceDirectories(Dir);
  F := IncludeTrailingPathDelimiter(Dir) + 'a.txt';
  A := TAsker.Create;
  L := TStringList.Create;
  try
    for i := 1 to 300 do L.Add('line ' + IntToStr(i));
    WriteFileBytes(F, L.Text, Err);

    Out_ := RunDosTool('read_file', '{"path":"' + JsonEscape(F) + '"}', A.Ask, IsErr);
    Check(not IsErr and (Pos('line 200', Out_) > 0) and (Pos('line 201', Out_) = 0), 'a window of 200 lines');
    Check(Pos('start_line=201', Out_) > 0, 'says how to read on: ' + Copy(Out_, Length(Out_) - 60, 61));
    Out_ := RunDosTool('read_file', '{"path":"' + JsonEscape(F) + '","start_line":299}', A.Ask, IsErr);
    Check(Pos('line 299', Out_) = 1, 'start_line');

    A.Answer := False;
    Out_ := RunDosTool('edit_file', '{"path":"' + JsonEscape(F) + '","old_text":"line 1\n","new_text":"first\n"}', A.Ask, IsErr);
    Check(IsErr and (Pos('said no', Out_) > 0), 'edit refused: ' + Out_);
    Check(Pos('Edit ', A.Asked) = 1, 'the question names the edit: ' + A.Asked);
    A.Answer := True;
    Out_ := RunDosTool('edit_file', '{"path":"' + JsonEscape(F) + '","old_text":"line 3","new_text":"x"}', A.Ask, IsErr);
    Check(IsErr and (Pos('occurs', Out_) > 0), 'ambiguous old_text refused (line 3, 30..39, 300): ' + Out_);
    Out_ := RunDosTool('edit_file', '{"path":"' + JsonEscape(F) + '","old_text":"line 300\n","new_text":"last\n"}', A.Ask, IsErr);
    Check(not IsErr, 'unique edit: ' + Out_);
    ReadFileBytes(F, Data, Err);
    Check(Pos('last', Data) > 0, 'the edit landed');

    A.Answer := False;
    Out_ := RunDosTool('write_file', '{"path":"' + JsonEscape(Dir + '/b.txt') + '","content":"x"}', A.Ask, IsErr);
    Check(IsErr and not FileExists(Dir + '/b.txt'), 'write refused, nothing written');
    A.Answer := True;
    Out_ := RunDosTool('write_file', '{"path":"' + JsonEscape(Dir + '/sub/b.txt') + '","content":"x"}', A.Ask, IsErr);
    Check(not IsErr and FileExists(Dir + '/sub/b.txt'), 'write makes the directory: ' + Out_);

    Out_ := RunDosTool('list_dir', '{"path":"' + JsonEscape(Dir) + '"}', A.Ask, IsErr);
    Check((Pos('a.txt', Out_) > 0) and (Pos('sub', Out_) > 0) and (Pos('<DIR>', Out_) > 0), 'list: ' + Out_);
    Out_ := RunDosTool('list_dir', '{"path":"' + JsonEscape(Dir + '/nope') + '"}', A.Ask, IsErr);
    Check(IsErr, 'listing a missing directory is an error');

    A.Answer := False;
    Out_ := RunDosTool('run', '{"command":"echo should-not-run"}', A.Ask, IsErr);
    Check(IsErr and (Pos('should-not-run', Out_) = 0), 'run refused');
    A.Answer := True;
    Out_ := RunDosTool('run', '{"command":"echo ran; exit 3"}', A.Ask, IsErr);
    Check((Pos('ran', Out_) > 0) and (Pos('[exit code 3]', Out_) > 0), 'run output and exit code: ' + Out_);

    Out_ := RunDosTool('nope', '{}', A.Ask, IsErr);
    Check(IsErr, 'unknown tool');
    Out_ := RunDosTool('read_file', 'not json', A.Ask, IsErr);
    Check(IsErr, 'bad arguments');
    CheckEq(DescribeToolCall('run', '{"command":"DIR /W"}'), 'run DIR /W', 'describe run');
  finally
    L.Free;
    A.Free;
  end;
end;

procedure TestHistory;
var
  Ag: TDosAgent;
  Opts: TDosAgentOptions;
  i: Integer;
  Big: string;
  O: TJsonObject;
begin
  CheckEq(CompactJson('{ "a" : "x y", "b" : [ 1, 2 ] }'), '{"a":"x y","b":[1,2]}', 'compact keeps string spaces');
  CheckEq(CompactJson('{"a":"q\" , \\"}'), '{"a":"q\" , \\"}', 'compact handles escapes');
  CheckEq(ErrorMessageOf('{"error":{"message":"m1"}}'), 'm1', 'error object');
  CheckEq(ErrorMessageOf('{"error":"m2"}'), 'm2', 'error string');
  CheckEq(ErrorMessageOf('plain'), 'plain', 'not JSON');

  Opts := DefaultAgentOptions;
  Opts.HistoryCap := 2000;
  Ag := TDosAgent.Create(nil, Opts);
  try
    Big := StringOfChar('x', 300);
    for i := 1 to 5 do
    begin
      Ag.AddItem('{"type":"message","role":"user","content":"turn ' + IntToStr(i) + '"}');
      Ag.AddItem('{"type":"function_call","call_id":"c' + IntToStr(i) + '","name":"run","arguments":"{}"}');
      Ag.AddItem('{"type":"function_call_output","call_id":"c' + IntToStr(i) + '","output":"' + Big + '"}');
    end;
    Ag.TrimHistory;
    Check(Pos('"role":"user"', Ag.History[0]) > 0, 'what is left starts at a user message');
    Check(Pos('turn 5', Ag.History.Text) > 0, 'the newest turn is kept');
    Check(Pos('turn 1"', Ag.History.Text) = 0, 'the oldest turn went');
    Check(Length(Ag.History.Text) <= 2100, 'under the cap');
    Check(Ag.History.Count mod 3 = 0, 'whole turns only (no call without its output)');

    { One turn bigger than the cap: older outputs shrink, the newest stay. }
    Ag.Clear;
    Ag.AddItem('{"type":"message","role":"user","content":"one long turn"}');
    for i := 1 to 8 do
    begin
      Ag.AddItem('{"type":"function_call","call_id":"d' + IntToStr(i) + '","name":"run","arguments":"{}"}');
      Ag.AddItem('{"type":"function_call_output","call_id":"d' + IntToStr(i) + '","output":"' + StringOfChar('y', 500) + '"}');
    end;
    Ag.TrimHistory;
    CheckEq(IntToStr(Ag.History.Count), '17', 'nothing dropped from the only turn');
    O := TJsonObject.Parse(Ag.History[2]);
    try
      Check(Pos('cut to keep', O.GetStr('output', '')) > 0, 'an old output is shortened');
    finally
      O.Free;
    end;
    O := TJsonObject.Parse(Ag.History[16]);
    try
      CheckEq(IntToStr(Length(O.GetStr('output', ''))), '500', 'the newest output is whole');
    finally
      O.Free;
    end;
  finally
    Ag.Free;
  end;
end;

procedure TestLinkSpecs;
var
  L: TDosLink;
  Err: string;
begin
  Check(not OpenLink('COM1', 115200, L, Err), 'COM1 is DOS-only on a host build');
  Check(Pos('host:port', Err) > 0, 'and the error says what to use: ' + Err);
  Check(not OpenLink('127.0.0.1:1', 115200, L, Err), 'nothing listens on port 1');
  Check(BaudSupported(115200) and BaudSupported(9600) and not BaudSupported(12345), 'baud list');
end;

begin
  Randomize;
  InitDosText;
  TestCrc;
  TestRoundTrip;
  TestCrcMismatch;
  TestResyncAndErrors;
  TestBridgeHandle;
  TestServeStream;
  TestTarget;
  TestCp437;
  TestWrap;
  TestTools;
  TestHistory;
  TestLinkSpecs;
  if Failures > 0 then
  begin
    WriteLn(Format('bridge_wire_tests: %d failure(s)', [Failures]));
    Halt(1);
  end;
  WriteLn('bridge_wire_tests: OK');
end.
