(*
  PasClaw.Channels.Teams - Microsoft Teams Incoming Webhook sender.

  Microsoft Teams' "Incoming Webhook" connector gives the user a URL like
    https://<tenant>.webhook.office.com/webhookb2/<id>@<tenant>/IncomingWebhook/<conn>/<obj>
  POSTing a JSON {"text": "..."} body to that URL renders as a card in
  the configured Teams channel. No auth header -- the secret is the URL
  itself, so treat it like the Slack incoming webhook URL.

  This unit only ships the outbound sender. Two-way conversations (the
  model replies to user messages from a Teams channel) require Microsoft
  Bot Framework registration and a publicly-reachable webhook endpoint;
  that's a Wave 2 follow-up alongside the LINE / WhatsApp Cloud
  receivers.

  Docs: https://learn.microsoft.com/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook
*)
unit PasClaw.Channels.Teams;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  TTeamsWebhook = class
  private
    FURL: string;
  public
    constructor Create(const WebhookURL: string);
    function Post(const Text: string): Boolean;
  end;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

constructor TTeamsWebhook.Create(const WebhookURL: string);
begin
  inherited Create;
  FURL := WebhookURL;
end;

function TTeamsWebhook.Post(const Text: string): Boolean;
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
    LogWarn('teams webhook: status=%d body=%s',
            [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
end;

end.
