program responses_tool_choice_tests;
(*
  Pins ResolveResponsesToolChoice -- the /v1/responses tool_choice parser.
  Two parse bugs lived here (PR #297): the object form was dropped entirely,
  then only the nested Chat-Completions function.name was read while the
  Responses API actually forces a tool with a flat top-level "name". This
  locks in both object shapes plus the keyword forms.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.JSON,
  PasClaw.Gateway.Server;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

{ Parse JSON -> resolve tool_choice -> assert -> free. }
procedure Check(const JSON, Want, Msg: string);
var
  Req: TJsonObject;
  Got: string;
begin
  Req := TJsonObject.Parse(JSON);
  if Req = nil then Fail_(Msg + ' (test JSON did not parse: ' + JSON + ')');
  try
    Got := ResolveResponsesToolChoice(Req);
  finally
    Req.Free;
  end;
  if Got <> Want then
    Fail_(Msg + ' -- got "' + Got + '", want "' + Want + '" (json: ' + JSON + ')');
end;

begin
  { Absent -> '' (caller leaves the provider default). }
  Check('{}', '', 'absent tool_choice');

  { Keyword string forms pass through (lower-cased). }
  Check('{"tool_choice":"auto"}',     'auto',     'keyword auto');
  Check('{"tool_choice":"none"}',     'none',     'keyword none');
  Check('{"tool_choice":"required"}', 'required', 'keyword required');
  Check('{"tool_choice":"AUTO"}',     'auto',     'keyword case-folded');

  { A bare non-keyword string is not a valid tool_choice -> dropped. }
  Check('{"tool_choice":"banana"}', '', 'bare non-keyword string dropped');

  { Responses API force form: flat top-level name. }
  Check('{"tool_choice":{"type":"function","name":"get_weather"}}',
        'get_weather', 'responses flat top-level name');

  { Chat-Completions force form: nested function.name. }
  Check('{"tool_choice":{"type":"function","function":{"name":"get_weather"}}}',
        'get_weather', 'chat-completions nested function.name');

  { Top-level name wins when both are present. }
  Check('{"tool_choice":{"type":"function","name":"top","function":{"name":"nested"}}}',
        'top', 'top-level name preferred over nested');

  { Object with no name anywhere -> dropped. }
  Check('{"tool_choice":{"type":"function"}}', '', 'object without a name dropped');

  WriteLn('responses_tool_choice_tests: OK');
end.
