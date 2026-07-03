program subagent_model_arg_tests;
(*
  Covers the per-call `model` override on the spawn tool (TSpawnTool.Run):
    - an explicit `model` arg wins and is handed to the child loop's provider;
    - with no arg, the subagent spec's configured Model is used;
    - with neither, the parent's DefaultModel is used;
    - the schema advertises a `model` property and the description mentions it.

  A recording provider captures the Model string RunToolLoop hands to Chat,
  which is exactly ChildCfg.Model -- i.e. the resolved precedence.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry,
  PasClaw.Providers.Intf,
  PasClaw.Providers.Types,
  PasClaw.Agent.Subagent;

var
  GLastModel: string;   { model captured by the recording provider's Chat }

type
  { Records the Model handed to Chat so the test can assert the resolved
    precedence. Returns a terminal turn (text, no tool calls, 2xx) so the
    child loop finishes in one iteration. }
  TRecordingProvider = class(TInterfacedObject, ILLMProvider)
  public
    function Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                  const Model: string; const Options: TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
                        const Model: string; const Options: TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

function TRecordingProvider.Chat(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions): TLLMResponse;
begin
  GLastModel := Model;
  Result := Default(TLLMResponse);
  Result.Content := 'done';
  Result.FinishReason := 'stop';
  Result.StatusCode := 200;
end;
function TRecordingProvider.GetDefaultModel: string; begin Result := 'provider-default'; end;
function TRecordingProvider.GetName: string; begin Result := 'recording'; end;
function TRecordingProvider.SupportsThinking: Boolean; begin Result := False; end;
function TRecordingProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TRecordingProvider.SupportsStreaming: Boolean; begin Result := False; end;
function TRecordingProvider.ChatStream(const Messages: array of TMessage; const Tools: array of TToolDefinition;
  const Model: string; const Options: TChatOptions; OnChunk: TStreamCallback): TLLMResponse;
begin GLastModel := Model; Result := Default(TLLMResponse); Result.StatusCode := 200; end;

procedure Fail_(const Msg: string); begin WriteLn('FAIL: ' + Msg); Halt(1); end;
procedure AssertTrue(Cond: Boolean; const Msg: string); begin if not Cond then Fail_(Msg); end;
procedure AssertEqS(const Got, Want, Msg: string);
begin if Got <> Want then Fail_(Msg + ' (got "' + Got + '", want "' + Want + '")'); end;

function NoopHandler(const ArgsJSON: string; out ErrMsg: string): string;
begin ErrMsg := ''; Result := 'ok'; end;

procedure AddPlain(Reg: TToolRegistry; const Name: string);
var T: TTool;
begin
  FillChar(T, SizeOf(T), 0);
  T.Name := Name; T.Description := Name; T.Schema := '{}';
  T.Handler := NoopHandler; T.Category := tcReadOnly;
  Reg.Register(T);
end;

{ Build a spawn tool whose parent provider records the model, and whose single
  spec has the given configured Model. DefaultModel is the parent fallback. }
function MakeSpawn(const SpecModel, DefaultModel: string;
                   out Parent: TToolRegistry): TSpawnTool;
var
  Ctx: TSubagentContext;
  Specs: TSubagentSpecArray;
begin
  Parent := TToolRegistry.Create;
  AddPlain(Parent, 'fs_read');   { child inherits a tool via '*' }

  Ctx := Default(TSubagentContext);
  Ctx.Provider := TRecordingProvider.Create;
  Ctx.ParentRegistry := Parent;
  Ctx.DefaultModel := DefaultModel;

  SetLength(Specs, 1);
  Specs[0].Name  := 'general-purpose';
  Specs[0].Tools := ['*'];
  Specs[0].Model := SpecModel;

  Result := TSpawnTool.Create(Ctx, Specs);
end;

procedure TestExplicitArgWins;
var Tool: TSpawnTool; Parent: TToolRegistry; Err: string;
begin
  Tool := MakeSpawn('spec-model', 'parent-default', Parent);
  try
    GLastModel := '<unset>';
    Tool.Run('{"agent":"general-purpose","prompt":"hi","model":"arg-model"}', Err);
    AssertEqS(Err, '', 'spawn with model arg should not error');
    AssertEqS(GLastModel, 'arg-model', 'explicit model arg wins over spec + parent');
  finally
    Tool.Free; Parent.Free;
  end;
  WriteLn('  ok: explicit model arg is handed to the child loop');
end;

procedure TestSpecModelWhenNoArg;
var Tool: TSpawnTool; Parent: TToolRegistry; Err: string;
begin
  Tool := MakeSpawn('spec-model', 'parent-default', Parent);
  try
    GLastModel := '<unset>';
    Tool.Run('{"agent":"general-purpose","prompt":"hi"}', Err);
    AssertEqS(Err, '', 'spawn without model arg should not error');
    AssertEqS(GLastModel, 'spec-model', 'spec model used when no arg given');
  finally
    Tool.Free; Parent.Free;
  end;
  WriteLn('  ok: spec model is used when no per-call model arg');
end;

procedure TestParentDefaultWhenNeither;
var Tool: TSpawnTool; Parent: TToolRegistry; Err: string;
begin
  Tool := MakeSpawn('', 'parent-default', Parent);
  try
    GLastModel := '<unset>';
    Tool.Run('{"agent":"general-purpose","prompt":"hi"}', Err);
    AssertEqS(Err, '', 'spawn should not error');
    AssertEqS(GLastModel, 'parent-default', 'parent default used when arg and spec both empty');
  finally
    Tool.Free; Parent.Free;
  end;
  WriteLn('  ok: parent DefaultModel is the final fallback');
end;

procedure TestBlankArgFallsThroughToSpec;
var Tool: TSpawnTool; Parent: TToolRegistry; Err: string;
begin
  { A whitespace-only arg must be treated as absent (Trim), not sent verbatim. }
  Tool := MakeSpawn('spec-model', 'parent-default', Parent);
  try
    GLastModel := '<unset>';
    Tool.Run('{"agent":"general-purpose","prompt":"hi","model":"   "}', Err);
    AssertEqS(Err, '', 'spawn should not error');
    AssertEqS(GLastModel, 'spec-model', 'blank model arg is ignored, spec used');
  finally
    Tool.Free; Parent.Free;
  end;
  WriteLn('  ok: whitespace-only model arg is treated as absent');
end;

procedure TestSchemaAndDescriptionAdvertiseModel;
var Tool: TSpawnTool; Parent: TToolRegistry;
begin
  Tool := MakeSpawn('spec-model', 'parent-default', Parent);
  try
    AssertTrue(Pos('"model"', Tool.Schema) > 0, 'schema exposes a model property');
    AssertTrue(Pos('model', LowerCase(Tool.Description)) > 0,
               'description mentions the model override');
  finally
    Tool.Free; Parent.Free;
  end;
  WriteLn('  ok: schema + description advertise the optional model arg');
end;

begin
  TestExplicitArgWins;
  TestSpecModelWhenNoArg;
  TestParentDefaultWhenNeither;
  TestBlankArgFallsThroughToSpec;
  TestSchemaAndDescriptionAdvertiseModel;
  WriteLn('subagent_model_arg_tests: OK');
end.
