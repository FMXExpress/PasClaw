program relay_servertools_tests;
(*
  The privacy flag must survive the relay hop.

  DisableServerTools is set by the maintenance callers (rerank, compact,
  distill, skill-distiller, goals, prune) because their prompts carry the
  user's own memory and transcripts, and provider grounding forms web-search
  queries from whatever is in context. The relay envelope did not serialise
  it, so the boundary held for a direct provider and silently failed for a
  relay worker whose own backend has grounding on by default -- Gemini's
  default. (Codex P1 on #578.)

  Also pins the initialisation bug found while verifying that: a function
  Result is not zero-initialised in Pascal, and DefaultChatOptions never
  assigned this field, so it read stack garbage. Observed on the wire as a
  plain agent turn emitting disable_server_tools=true with no caller having
  set it -- grounding suppressed or enabled at random, per call.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
uses
  SysUtils, PasClaw.JSON, PasClaw.Providers.Types, PasClaw.Providers.Relay;
var
  Fails: Integer = 0;
procedure Chk(Cond: Boolean; const What: string);
begin
  if not Cond then begin WriteLn('FAIL: ', What); Inc(Fails); end;
end;
var
  O: TChatOptions;
  M: array[0..0] of TMessage;
  T: array of TToolDefinition;
  Body: string;
  Root, Opts: TJsonObject;
begin
  SetLength(T, 0);
  M[0] := MakeMessage(mrUser, 'hello');

  (* 1. DefaultChatOptions must define the field rather than inherit stack
        noise.

        HONEST LIMIT: this assertion is a WEAK guard and cannot be made
        strong. An uninitialised Result reads whatever is on the stack, and
        in a small test program that is usually zero -- verified by deleting
        the initialiser, which leaves this test PASSING. The real evidence
        was on the wire, through the full gateway, where a deeper call stack
        made the garbage non-zero: a plain agent turn emitted
        disable_server_tools=true with no caller having set it. Keep the row
        as documentation of the defect; do not mistake it for detection. *)
  O := DefaultChatOptions;
  Chk(O.DisableServerTools = False, 'DefaultChatOptions leaves DisableServerTools False');

  { 2. Not set -> absent from the wire (compact envelope, historical meaning). }
  Body := BuildRelayRequestBody(M, T, 'model', O, 'id1');
  Root := TJsonObject.Parse(Body);
  try
    Opts := Root.ChildObject('options');
    Chk((Opts = nil) or (not Opts.Has('disable_server_tools')),
        'flag absent when not requested');
  finally Root.Free; end;

  { 3. Set -> present and true, so the worker can honour it. }
  O.DisableServerTools := True;
  Body := BuildRelayRequestBody(M, T, 'model', O, 'id2');
  Root := TJsonObject.Parse(Body);
  try
    Opts := Root.ChildObject('options');
    Chk(Opts <> nil, 'options object present');
    if Opts <> nil then
      Chk(Opts.GetBool('disable_server_tools', False),
          'flag serialised as true when requested');
  finally Root.Free; end;

  if Fails > 0 then
  begin
    WriteLn(Format('relay_servertools_tests: %d failure(s)', [Fails]));
    Halt(1);
  end;
  WriteLn('relay_servertools_tests: OK');
end.
