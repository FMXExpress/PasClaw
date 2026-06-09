(*
  PasClaw.Channels.Slack - Slack adapter.

  Outbound: Incoming Webhook URLs (https://hooks.slack.com/services/...).
  Inbound:  Events API webhook receiver -- registered as a gateway route by
            PasClaw.Gateway.Server (Phase 8). Phase 6 ships the webhook
            sender + the verification logic for the URL-verification
            challenge so registration works.

  Docs: https://api.slack.com/messaging/webhooks
        https://api.slack.com/events-api
*)
unit PasClaw.Channels.Slack;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TSlackWebhook = class
  private
    FURL: string;
  public
    constructor Create(const WebhookURL: string);
    function Post(const Text: string): Boolean;
    function PostBlocks(const Text: string; const BlocksJSON: string): Boolean;
  end;

(* Slack URL verification challenge: when an Events API endpoint is
   registered, Slack POSTs a url_verification payload with a challenge
   string. The gateway echoes it back. Returns True if the body was a
   challenge and Response holds the echo body to send. *)
function SlackChallengeResponse(const Body: string; out Response: string): Boolean;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

constructor TSlackWebhook.Create(const WebhookURL: string);
begin
  inherited Create;
  FURL := WebhookURL;
end;

function TSlackWebhook.Post(const Text: string): Boolean;
var
  Obj: TJsonObject;
  Body: string;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('text', Text);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  Resp := PostJSON(FURL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
  if not Result then
    LogWarn('slack webhook: status=%d body=%s', [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

function TSlackWebhook.PostBlocks(const Text, BlocksJSON: string): Boolean;
var
  Obj: TJsonObject;
  Body: string;
  Empty: array of THeaderPair;
  Resp: THTTPResult;
begin
  SetLength(Empty, 0);
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('text', Text);
    Obj.PutRaw('blocks', BlocksJSON);
    Body := Obj.ToJSON;
  finally
    Obj.Free;
  end;
  Resp := PostJSON(FURL, Body, Empty, 30);
  Result := (Resp.StatusCode >= 200) and (Resp.StatusCode < 300);
end;

function SlackChallengeResponse(const Body: string; out Response: string): Boolean;
var
  Obj: TJsonObject;
  Kind, Challenge: string;
begin
  Response := '';
  Result := False;
  Obj := TJsonObject.Parse(Body);
  if Obj = nil then Exit;
  try
    Kind := Obj.GetStr('type', '');
    if Kind <> 'url_verification' then Exit;
    Challenge := Obj.GetStr('challenge', '');
    if Challenge = '' then Exit;
    Response := '{"challenge":"' + JsonEscape(Challenge) + '"}';
    Result := True;
  finally
    Obj.Free;
  end;
end;

end.
