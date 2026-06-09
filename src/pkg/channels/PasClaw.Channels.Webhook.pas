(*
  PasClaw.Channels.Webhook - generic outbound webhook sender.

  Sometimes the target service doesn't fit any specific adapter -- a
  Zapier hook, an in-house notification endpoint, an n8n workflow, a
  Discord-but-via-DM-relay, etc. This adapter just POSTs a JSON body
  to a URL the caller provides:

    { "text": "<text>" }

  Auth: callers can supply an Authorization header value as a string
  (e.g. "Bearer xyz" or "Basic …"). Empty means no auth header.
  Anything richer -- HMAC signing, OAuth refresh, multipart -- belongs
  in a dedicated adapter, not here.

  Useful for cron skills:
    pasclaw post webhook https://hooks.example.com/cron-summary "ran fine"
*)
unit PasClaw.Channels.Webhook;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TGenericWebhook = class
  private
    FURL:  string;
    FAuth: string;
  public
    constructor Create(const URL: string; const AuthHeader: string = '');
    function Post(const Text: string): Boolean;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

constructor TGenericWebhook.Create(const URL: string; const AuthHeader: string);
begin
  inherited Create;
  FURL  := URL;
  FAuth := AuthHeader;
end;

function TGenericWebhook.Post(const Text: string): Boolean;
var
  Body: string;
  Obj: TJsonObject;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  if FAuth <> '' then
  begin
    SetLength(Headers, 1);
    Headers[0] := MakeHeader('Authorization', FAuth);
  end
  else
    SetLength(Headers, 0);

  Obj := TJsonObject.Create;
  try
    Obj.PutStr('text', Text);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  Resp := PostJSON(FURL, Body, Headers, 30);

  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('webhook: status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

end.
