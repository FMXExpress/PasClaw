{
  PasClaw.MCP.Result - pure parser for a JSON-RPC `tools/call` response.

  Both the HTTP and stdio MCP clients used to inline near-identical parsing
  that kept ONLY `result.content[]` blocks of type "text" and discarded the
  rest -- so `structuredContent`, image/resource blocks, and the raw result
  object never reached callers. That flattening makes it impossible to chain
  one MCP tool's real output into the next (a workflow builder needs the image
  URL a generate step returns, which may live in structuredContent or a
  non-text block).

  This unit factors the parse into ONE pure function that yields both the
  flattened text (unchanged, for back-compat) AND the raw `result` object as
  JSON (`ResultJSON`), so structured consumers have an escape hatch. Being a
  pure string->string function it is unit-testable with no live server.
}
unit PasClaw.MCP.Result;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

{ Parse a JSON-RPC `tools/call` response body.

    ResultText - text content blocks concatenated with line breaks (the
                 historical flattened form; empty when there are none).
    ResultJSON - the raw `result` object as JSON ('' when absent), so callers
                 can read structuredContent / output URLs / non-text blocks.
    ErrMsg     - set (and Result=False) on a JSON-RPC error, an unparseable
                 body, or an isError result with no text.

  Returns True on a successful tool result. Mirrors the previous inline
  behaviour exactly for ResultText and error signalling. }
function ParseToolCallResult(const RespJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;

implementation

uses
  PasClaw.JSON;

function ParseToolCallResult(const RespJSON: string;
  out ResultText, ResultJSON, ErrMsg: string): Boolean;
var
  RespObj, ResultObj, Block: TJsonObject;
  ContentArr: TJsonArray;
  i: Integer;
begin
  Result := False;
  ResultText := '';
  ResultJSON := '';
  ErrMsg := '';

  try
    RespObj := TJsonObject.Parse(RespJSON);
  except
    on E: Exception do
    begin
      ErrMsg := 'unparseable tools/call response: ' + E.Message;
      Exit;
    end;
  end;
  if RespObj = nil then
  begin
    ErrMsg := 'unparseable tools/call response';
    Exit;
  end;
  try
    if RespObj.Has('error') then
    begin
      ErrMsg := 'tools/call error';
      Exit;
    end;
    ResultObj := RespObj.ChildObject('result');
    if ResultObj = nil then
    begin
      ErrMsg := 'tools/call response has no result';
      Exit;
    end;
    try
      { The whole result object, verbatim, is the structured escape hatch. }
      ResultJSON := ResultObj.ToJSON;

      ContentArr := ResultObj.ChildArray('content');
      if ContentArr <> nil then
      try
        for i := 0 to ContentArr.Count - 1 do
        begin
          Block := ContentArr.ItemObject(i);
          if Block = nil then Continue;
          try
            if Block.GetStr('type', '') = 'text' then
            begin
              if ResultText <> '' then ResultText := ResultText + sLineBreak;
              ResultText := ResultText + Block.GetStr('text', '');
            end;
          finally
            Block.Free;
          end;
        end;
      finally
        ContentArr.Free;
      end;

      if (ResultText = '') and ResultObj.GetBool('isError', False) then
      begin
        ErrMsg := 'tool reported error (no text content)';
        Exit;
      end;
    finally
      ResultObj.Free;
    end;
  finally
    RespObj.Free;
  end;
  Result := True;
end;

end.
