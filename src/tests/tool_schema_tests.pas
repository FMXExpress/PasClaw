program tool_schema_tests;
(*
  Every registered tool's parameter schema must be valid JSON, and must
  be a JSON Schema object.

  This exists because a broken one is INVISIBLE. Providers inject the
  schema with PutRaw, and PutRaw answers an unparseable string by
  substituting {} without a word -- so a tool with a typo'd schema is
  advertised to the model as taking NO ARGUMENTS. The model then calls
  it with none, correctly, forever, and no amount of error text argues
  it out of the schema it was given.

  That is not hypothetical. `desktop`'s schema carried

      "e.g. [{""do"":""tile""}]"

  -- the Pascal doubling convention applied to double quotes, where
  JSON wanted \". It shipped, reached every real provider as
  parameters:{}, and cost a user a turn: `desktop()` with nothing in
  it, twice in a row, the second time after being shown a worked
  example.

  Turning every register-time schema into a parse is the cheap net.
  Registration is where the mistake is made, so registration is where
  it should be caught -- not in a bug report about a model that "won't
  pass arguments".

  Runs against a temp PASCLAW_HOME. No network, no gateway.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Utils,
  PasClaw.JSON,
  PasClaw.Providers.Types,
  PasClaw.Tools.Registry,
  PasClaw.Tools.Types,
  PasClaw.Tools.FS,
  PasClaw.Tools.Shell,
  PasClaw.Tools.ExecuteCode,
  PasClaw.Tools.Memory,
  PasClaw.Tools.KB,
  PasClaw.Tools.Vault,
  PasClaw.Tools.DB,
  PasClaw.Agents.Tools,
  PasClaw.Projects.Tools;

var
  Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

(* One tool, checked the way a provider will use it: parse the schema,
   and insist the result is an object declaring an object type. A
   schema that parses into a string or an array would be accepted by
   PutRaw and then mean nothing to the model -- the same silent
   failure wearing different clothes. *)
procedure CheckSchema(const Name, Schema: string);
var
  Obj: TJsonObject;
begin
  { An absent schema is legitimate: a tool may genuinely take no
    arguments, and providers omit the key entirely for those. }
  if Trim(Schema) = '' then Exit;

  Obj := nil;
  try
    Obj := TJsonObject.Parse(Schema);
  except
    on E: Exception do
    begin
      Fail_(Name + ': schema is not valid JSON -- ' + E.Message + #10 +
            '       providers inject this with PutRaw, which silently ' +
            'substitutes {} , so the model would be told this tool takes ' +
            'no arguments.' + #10 +
            '       schema: ' + Copy(Schema, 1, 200));
      Exit;
    end;
  end;

  if Obj = nil then
  begin
    Fail_(Name + ': schema parsed to nothing');
    Exit;
  end;
  try
    if LowerCase(Trim(Obj.GetStr('type', ''))) <> 'object' then
      Fail_(Name + ': schema is not an object schema -- got type "' +
            Obj.GetStr('type', '') + '"');
    if not Obj.Has('properties') then
      Fail_(Name + ': schema declares no "properties"');
  finally
    Obj.Free;
  end;
end;

procedure CheckRegistry(R: TToolRegistry; const Label_: string);
var
  Defs: TToolDefinitionArray;
  Names: TStringArray;
  T: TTool;
  I: Integer;
begin
  Names := R.Names;
  if Length(Names) = 0 then
  begin
    Fail_(Label_ + ': registered nothing');
    Exit;
  end;
  for I := 0 to High(Names) do
    if R.Find(Names[I], T) then
      CheckSchema(Label_ + '/' + T.Name, T.Schema);

  (* And again through ToProviderDefs, which is the surface the
     providers actually read. Checking only TTool.Schema would miss a
     registry that rewrote it on the way out. *)
  Defs := R.ToProviderDefs;
  for I := 0 to High(Defs) do
    CheckSchema(Label_ + '/' + Defs[I].Name + ' (provider def)', Defs[I].Schema);
end;

var
  R: TToolRegistry;
begin
  { The desktop/project/agent tools: the ones this test was written for. }
  R := TToolRegistry.Create;
  try
    RegisterDesktopTool(R);
    RegisterProjectTools(R);
    RegisterAgentTools(R);
    CheckRegistry(R, 'desktop');
  finally
    R.Free;
  end;

  { The built-in surface every install ships with. }
  R := TToolRegistry.Create;
  try
    RegisterFSTools(R, True);
    RegisterShellTool(R);
    RegisterExecuteCodeTool(R);
    RegisterMemoryTools(R);
    RegisterKBTools(R);
    CheckRegistry(R, 'builtin');
  finally
    R.Free;
  end;

  { The opt-in tools, which get less exercise and so are likelier to
    carry an unnoticed typo. }
  R := TToolRegistry.Create;
  try
    RegisterVaultTools(R);
    CheckRegistry(R, 'vault');
  finally
    R.Free;
  end;

  { The hashline variant registers a different edit tool. }
  R := TToolRegistry.Create;
  try
    RegisterFSTools(R, False);
    CheckRegistry(R, 'builtin (no hashline)');
  finally
    R.Free;
  end;

  if Failures = 0 then
    WriteLn('tool_schema_tests: OK')
  else
  begin
    WriteLn('tool_schema_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
