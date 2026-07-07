program mcp_result_tests;
(*
  Pins PasClaw.MCP.Result.ParseToolCallResult -- the shared parse both MCP
  clients now use. The point of the refactor: the raw `result` object survives
  as ResultJSON (structuredContent / image URLs / non-text blocks), which the
  old text-only flattening dropped, so a workflow can chain one tool's output
  into the next. Text flattening + error signalling must stay byte-identical.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.MCP.Result;

var
  Failures: Integer = 0;

procedure Check(Cond: Boolean; const Why: string);
begin
  if not Cond then begin WriteLn('FAIL: ', Why); Inc(Failures); end;
end;

procedure TestTextOnly;
var Text, JSON, Err: string; Ok: Boolean;
begin
  Ok := ParseToolCallResult(
    '{"jsonrpc":"2.0","id":1,"result":{"content":[' +
    '{"type":"text","text":"line one"},{"type":"text","text":"line two"}]}}',
    Text, JSON, Err);
  Check(Ok, 'text-only: succeeds');
  Check(Pos('line one', Text) > 0, 'text-only: first block kept');
  Check(Pos('line two', Text) > 0, 'text-only: second block kept');
  Check(Pos('content', JSON) > 0, 'text-only: ResultJSON is the whole result object');
  Check(Err = '', 'text-only: no error');
end;

procedure TestStructuredSurvives;
{ The core win: an image URL that lives ONLY in structuredContent / a non-text
  block must reach the caller via ResultJSON even though ResultText is empty. }
var Text, JSON, Err: string; Ok: Boolean;
begin
  Ok := ParseToolCallResult(
    '{"jsonrpc":"2.0","id":1,"result":{' +
    '"content":[{"type":"image","url":"https://x/out.png"}],' +
    '"structuredContent":{"output":["https://x/final.png"]}}}',
    Text, JSON, Err);
  Check(Ok, 'structured: succeeds even with no text block');
  Check(Text = '', 'structured: no text content -> empty ResultText');
  Check(Pos('structuredContent', JSON) > 0, 'structured: structuredContent survives in ResultJSON');
  Check(Pos('https://x/final.png', JSON) > 0, 'structured: output URL survives');
  Check(Pos('https://x/out.png', JSON) > 0, 'structured: image-block URL survives');
end;

procedure TestJsonRpcError;
var Text, JSON, Err: string; Ok: Boolean;
begin
  Ok := ParseToolCallResult(
    '{"jsonrpc":"2.0","id":1,"error":{"code":-32601,"message":"nope"}}',
    Text, JSON, Err);
  Check(not Ok, 'jsonrpc-error: returns False');
  Check(Err <> '', 'jsonrpc-error: sets ErrMsg');
end;

procedure TestIsErrorNoText;
var Text, JSON, Err: string; Ok: Boolean;
begin
  Ok := ParseToolCallResult(
    '{"jsonrpc":"2.0","id":1,"result":{"content":[],"isError":true}}',
    Text, JSON, Err);
  Check(not Ok, 'isError-no-text: returns False');
  Check(Err <> '', 'isError-no-text: sets ErrMsg');
end;

procedure TestUnparseable;
var Text, JSON, Err: string; Ok: Boolean;
begin
  Ok := ParseToolCallResult('not json at all', Text, JSON, Err);
  Check(not Ok, 'unparseable: returns False');
  Check(Err <> '', 'unparseable: sets ErrMsg');
end;

begin
  TestTextOnly;
  TestStructuredSurvives;
  TestJsonRpcError;
  TestIsErrorNoText;
  TestUnparseable;

  if Failures = 0 then WriteLn('mcp_result_tests: OK')
  else begin WriteLn('mcp_result_tests: ', Failures, ' failure(s)'); Halt(1); end;
end.
