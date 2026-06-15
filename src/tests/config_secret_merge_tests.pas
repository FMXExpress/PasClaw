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

{ Pull providers[name].api_key (or mcp_servers[name].env) out of a config
  JSON string for assertions. }
function ArrField(const Json, ArrKey, Name, Field: string): string;
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
          if It.GetStr('name', '') = Name then Exit(It.GetStr(Field, ''));
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

  { A placeholder for a name with no server match clears (can't invent a
    secret) -- the client still never reads one. }
  Edited := '{"providers":[{"name":"ghost","api_key":"' + M + '"}]}';
  Merged := RestoreMaskedConfigSecrets(Edited, Current);
  AssertEqS(ArrField(Merged, 'providers', 'ghost', 'api_key'), '',
            'placeholder with no server match clears rather than leaking');

  WriteLn('config_secret_merge_tests: OK');
end.
