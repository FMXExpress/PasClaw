program config_secret_merge_tests;
(*
  Covers PasClaw.Config.RestoreMaskedConfigSecrets -- the merge behind the
  web UI's editable Settings (PUT /v1/config). The contract: the client
  never SEES real secrets (GET masks them to MaskedSecretPlaceholder), but
  can SET them. So on write:

    - a field still showing the placeholder keeps the server's value
      (providers[].api_key + mcp_servers[].env matched by name, plus the
      single gateway.token / web_search.api_key),
    - any other value overwrites it (set a new secret, or clear it),
    - non-secret edits pass through untouched,
    - matching is by name, not array index (reordering is safe).
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Config;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertEqS(const Got, Want, Msg: string);
begin
  if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")');
end;

{ Pull <ArrKey>[KeyField = Key].Field out of a config JSON string for
  assertions (crons are keyed by id, every other list by name). }
function ArrFieldBy(const Json, ArrKey, KeyField, Key, Field: string): string;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  It: TJsonObject;
  i: Integer;
begin
  Result := '';
  Root := TJsonObject.Parse(Json);
  if Root = nil then Exit;
  try
    Arr := Root.ChildArray(ArrKey);
    if Arr = nil then Exit;
    try
      for i := 0 to Arr.Count - 1 do
      begin
        It := Arr.ItemObject(i);
        if It = nil then Continue;
        try
          if It.GetStr(KeyField, '') = Key then Exit(It.GetStr(Field, ''));
        finally
          It.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;
end;

{ Pull providers[name].api_key (or mcp_servers[name].env) out of a config
  JSON string for assertions. }
function ArrField(const Json, ArrKey, Name, Field: string): string;
begin
  Result := ArrFieldBy(Json, ArrKey, 'name', Name, Field);
end;

{ diagnostics.otel.headers[Name], or '' when any level is missing. }
function OtelHeader(const Json, Name: string): string;
var
  Root, D, O, H: TJsonObject;
begin
  Result := '';
  Root := TJsonObject.Parse(Json);
  if Root = nil then Exit;
  D := nil; O := nil; H := nil;
  try
    D := Root.ChildObject('diagnostics');
    if D <> nil then O := D.ChildObject('otel');
    if O <> nil then H := O.ChildObject('headers');
    if H <> nil then Result := H.GetStr(Name, '');
  finally
    if H <> nil then H.Free;
    if O <> nil then O.Free;
    if D <> nil then D.Free;
    Root.Free;
  end;
end;

function ObjField(const Json, ObjKey, Field: string): string;
var
  Root, O: TJsonObject;
begin
  Result := '';
  Root := TJsonObject.Parse(Json);
  if Root = nil then Exit;
  try
    O := Root.ChildObject(ObjKey);
    if O = nil then Exit;
    try
      Result := O.GetStr(Field, '');
    finally
      O.Free;
    end;
  finally
    Root.Free;
  end;
end;

function TopField(const Json, Field: string): string;
var
  Root: TJsonObject;
begin
  Result := '';
  Root := TJsonObject.Parse(Json);
  if Root = nil then Exit;
  try
    Result := Root.GetStr(Field, '');
  finally
    Root.Free;
  end;
end;

var
  M, Current, Edited, Merged: string;

begin
  M := MaskedSecretPlaceholder;

  Current :=
    '{"default_model":"m1",' +
    '"providers":[{"name":"openai","api_key":"SECRET-A"},' +
                 '{"name":"anthropic","api_key":"SECRET-B"}],' +
    '"mcp_servers":[{"name":"gh","env":"GITHUB_TOKEN=ghp_x"}],' +
    '"gateway":{"token":"GW-TOKEN"},' +
    '"web_search":{"api_key":"WS-KEY"}}';

  { Client sends back: model changed, providers reordered, openai kept
    (mask), anthropic given a NEW key, env/token/web_search kept (mask). }
  Edited :=
    '{"default_model":"m2",' +
    '"providers":[{"name":"anthropic","api_key":"NEW-KEY"},' +
                 '{"name":"openai","api_key":"' + M + '"}],' +
    '"mcp_servers":[{"name":"gh","env":"' + M + '"}],' +
    '"gateway":{"token":"' + M + '"},' +
    '"web_search":{"api_key":"' + M + '"}}';

  Merged := RestoreMaskedConfigSecrets(Edited, Current);

  AssertEqS(TopField(Merged, 'default_model'), 'm2', 'non-secret edit passes through');
  AssertEqS(ArrField(Merged, 'providers', 'openai', 'api_key'), 'SECRET-A',
            'masked provider key restored from server (matched by name despite reorder)');
  AssertEqS(ArrField(Merged, 'providers', 'anthropic', 'api_key'), 'NEW-KEY',
            'new provider key value is kept');
  AssertEqS(ArrField(Merged, 'mcp_servers', 'gh', 'env'), 'GITHUB_TOKEN=ghp_x',
            'masked mcp env restored from server');
  AssertEqS(ObjField(Merged, 'gateway', 'token'), 'GW-TOKEN',
            'masked gateway token restored from server');
  AssertEqS(ObjField(Merged, 'web_search', 'api_key'), 'WS-KEY',
            'masked web_search key restored from server');

  { mcp env, per variable: GET shows the names and masks each value; a
    masked value comes back from the same-named variable, a typed one is
    kept, a new one is added, and one left out is dropped. }
  Current := '{"mcp_servers":[{"name":"gh","env":"GITHUB_TOKEN=ghp_x;DEBUG=1;GONE=z;EMPTY="}]}';
  AssertEqS(ArrField(MaskConfigSecretsJSON(Current), 'mcp_servers', 'gh', 'env'),
            'GITHUB_TOKEN=' + M + ';DEBUG=' + M + ';GONE=' + M + ';EMPTY=',
            'mcp env: each value masked, the names kept');
  Edited := '{"mcp_servers":[{"name":"gh","env":"GITHUB_TOKEN=' + M + ';DEBUG=2;NEW=n;EMPTY="}]}';
  Merged := RestoreMaskedConfigSecrets(Edited, Current);
  AssertEqS(ArrField(Merged, 'mcp_servers', 'gh', 'env'), 'GITHUB_TOKEN=ghp_x;DEBUG=2;NEW=n;EMPTY=',
            'mcp env: kept, typed, added and removed variables merge per name');

  { A placeholder for a name with no server match clears (can't invent a
    secret) -- the client still never reads one. }
  Edited := '{"providers":[{"name":"ghost","api_key":"' + M + '"}]}';
  Merged := RestoreMaskedConfigSecrets(Edited, Current);
  AssertEqS(ArrField(Merged, 'providers', 'ghost', 'api_key'), '',
            'placeholder with no server match clears rather than leaking');

  { Channel targets (by name), cron channel targets (by id) and OTel
    header values (by header name) are masked on read too, so they must
    come back on write -- before this, an untouched Settings save wrote
    the placeholder itself into config.json. }
  Current :=
    '{"channels":[{"name":"ops","kind":"discord","target":"https://hook/ops"},' +
                 '{"name":"dev","kind":"slack","target":"https://hook/dev"}],' +
    '"crons":[{"id":"daily","spec":"0 9 * * *","channel_target":"https://hook/cron"}],' +
    '"diagnostics":{"otel":{"enabled":true,"headers":{"Authorization":"Bearer OT",' +
                                                     '"x-team":"TEAM"}}}}';
  Edited :=
    '{"channels":[{"name":"dev","kind":"slack","target":"' + M + '"},' +
                 '{"name":"ops","kind":"discord","target":"https://hook/new"}],' +
    '"crons":[{"id":"daily","spec":"0 8 * * *","channel_target":"' + M + '"}],' +
    '"diagnostics":{"otel":{"enabled":true,"headers":{"Authorization":"' + M + '",' +
                                                     '"x-team":"NEW-TEAM",' +
                                                     '"x-ghost":"' + M + '"}}}}';
  Merged := RestoreMaskedConfigSecrets(Edited, Current);
  AssertEqS(ArrField(Merged, 'channels', 'dev', 'target'), 'https://hook/dev',
            'masked channel target restored by name despite reorder');
  AssertEqS(ArrField(Merged, 'channels', 'ops', 'target'), 'https://hook/new',
            'a new channel target is kept');
  AssertEqS(ArrFieldBy(Merged, 'crons', 'id', 'daily', 'channel_target'), 'https://hook/cron',
            'masked cron channel_target restored by id');
  AssertEqS(OtelHeader(Merged, 'Authorization'), 'Bearer OT',
            'masked OTel header restored by header name');
  AssertEqS(OtelHeader(Merged, 'x-team'), 'NEW-TEAM', 'a new OTel header value is kept');
  AssertEqS(OtelHeader(Merged, 'x-ghost'), '',
            'a masked OTel header with no server match clears');

  { And the read side masks what the write side restores. }
  Merged := MaskConfigSecretsJSON(Current);
  AssertEqS(OtelHeader(Merged, 'Authorization'), M, 'OTel header value masked on read');
  AssertEqS(ArrField(Merged, 'channels', 'ops', 'target'), M, 'channel target masked on read');
  if Pos('Bearer OT', Merged) > 0 then Fail_('masked config still carries the OTel header value');

  WriteLn('config_secret_merge_tests: OK');
end.
