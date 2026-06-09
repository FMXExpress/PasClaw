(*
  PasClaw.Providers.Stream - Server-Sent Events parser shared by both
  OpenAI's and Anthropic's streaming endpoints.

  SSE framing:
    data: <chunk>\n
    data: <chunk>\n
    \n               <- blank line ends an event
    event: <name>\n  <- optional, present in Anthropic stream
    ...

  The HTTP POST is delegated to PasClaw.Providers.HTTP.PostJSONToStream
  so this unit doesn't need its own Indy plumbing or SSL setup. We
  parse the buffered response (Indy doesn't expose true real-time
  streaming for the protocols we care about) and drive per-event
  callbacks from that.
*)
unit PasClaw.Providers.Stream;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Providers.Types,
  PasClaw.Providers.HTTP;

type
  TSSECallback = procedure(const Event, Data: string) of object;
  TSSECallbackProc = procedure(const Event, Data: string);

function PostStreaming(const URL, JSON: string;
                       const Headers: array of THeaderPair;
                       TimeoutSeconds: Integer;
                       OnLine: TSSECallbackProc;
                       out StatusCode: Integer;
                       out ErrMsg: string): Boolean;

implementation

function PostStreaming(const URL, JSON: string;
                       const Headers: array of THeaderPair;
                       TimeoutSeconds: Integer;
                       OnLine: TSSECallbackProc;
                       out StatusCode: Integer;
                       out ErrMsg: string): Boolean;
var
  Resp: TStringStream;
  Body: TStringList;
  i: Integer;
  EventName, DataAccum, Line: string;

  procedure Flush;
  begin
    if (EventName <> '') or (DataAccum <> '') then
    begin
      if Assigned(OnLine) then OnLine(EventName, DataAccum);
      EventName := '';
      DataAccum := '';
    end;
  end;

begin
  Result := False;
  { Explicit UTF-8 -- Delphi's TStringStream defaults to ANSI which
    would mangle the SSE response body. }
  Resp := TStringStream.Create('', TEncoding.UTF8);
  try
    PostJSONToStream(URL, JSON, Resp, Headers, TimeoutSeconds,
                     'PasClaw/0.1', 'text/event-stream',
                     StatusCode, ErrMsg);

    Body := TStringList.Create;
    try
      Body.Text := Resp.DataString;
      EventName := '';
      DataAccum := '';
      for i := 0 to Body.Count - 1 do
      begin
        Line := Body[i];
        if Line = '' then
        begin
          Flush;
          Continue;
        end;
        if Copy(Line, 1, 6) = 'event:' then
          EventName := Trim(Copy(Line, 7, MaxInt))
        else if Copy(Line, 1, 5) = 'data:' then
        begin
          if DataAccum <> '' then DataAccum := DataAccum + #10;
          DataAccum := DataAccum + Trim(Copy(Line, 6, MaxInt));
        end;
      end;
      Flush;
    finally
      Body.Free;
    end;

    Result := (StatusCode >= 200) and (StatusCode < 300);
  finally
    Resp.Free;
  end;
end;

end.
