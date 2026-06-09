{
  PasClaw.Tools.Registry - register/lookup/dispatch built-in and skill-supplied
  tools. Thread-safety isn't critical for the CLI (single-process), but we keep
  the same API shape as pkg/tools/registry.go so a multi-channel gateway can
  use it later.
}
unit PasClaw.Tools.Registry;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes, SyncObjs,
  PasClaw.Tools.Types,
  PasClaw.Providers.Types;

type
  {$IFNDEF FPC}
  { Delphi's RTL doesn't declare TStringArray (FPC's SysUtils does); declare
    it locally so the cross-compiler signature below resolves. }
  TStringArray = array of string;
  {$ENDIF}

  TToolRegistry = class
  private
    FTools: TToolList;
    { Background MCP loaders (PasClaw.MCP.Bridge) call Register after
      ConnectMCPServers has already returned; gateway worker threads
      may be reading the same array via Find / ToProviderDefs at the
      same time. One CS guards every method's data-access phase.
      RunTool releases the lock before invoking the handler so a slow
      tool (HTTP MCP call, shell-out) can't block parallel reads. }
    FLock:  TCriticalSection;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Register(const T: TTool);
    function  Find(const Name: string; out T: TTool): Boolean;
    function  Names: TStringArray;
    function  Count: Integer;
    function  ToProviderDefs: TToolDefinitionArray;
    function  RunTool(const Name, ArgsJSON: string; out ErrMsg: string): string;
  end;

implementation

constructor TToolRegistry.Create;
begin
  inherited Create;
  SetLength(FTools, 0);
  FLock := TCriticalSection.Create;
end;

destructor TToolRegistry.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TToolRegistry.Register(const T: TTool);
var
  i: Integer;
  Stored: TTool;
begin
  Stored := T;
  { Defensive zero: legacy callers build `T: TTool` on the stack and
    set Handler without ever touching the new HandlerObj field, which
    leaves it pointing at stack garbage. RunTool's
    `if Assigned(T.HandlerObj)` then either misroutes the call or
    crashes. If Handler is set, the caller intended function-pointer
    dispatch -- clear HandlerObj. TPasClawTool installs always set
    Handler := nil first, so this branch doesn't fire for them. }
  if Assigned(Stored.Handler) then
  begin
    TMethod(Stored.HandlerObj).Code := nil;
    TMethod(Stored.HandlerObj).Data := nil;
  end;
  FLock.Acquire;
  try
    for i := 0 to High(FTools) do
      if FTools[i].Name = Stored.Name then
      begin
        FTools[i] := Stored;
        Exit;
      end;
    SetLength(FTools, Length(FTools) + 1);
    FTools[High(FTools)] := Stored;
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.Find(const Name: string; out T: TTool): Boolean;
var
  i: Integer;
begin
  FLock.Acquire;
  try
    for i := 0 to High(FTools) do
      if FTools[i].Name = Name then
      begin
        T := FTools[i];
        Exit(True);
      end;
    Result := False;
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.Names: TStringArray;
var
  i: Integer;
begin
  FLock.Acquire;
  try
    SetLength(Result, Length(FTools));
    for i := 0 to High(FTools) do Result[i] := FTools[i].Name;
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.Count: Integer;
begin
  FLock.Acquire;
  try
    Result := Length(FTools);
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.ToProviderDefs: TToolDefinitionArray;
var
  i: Integer;
begin
  FLock.Acquire;
  try
    SetLength(Result, Length(FTools));
    for i := 0 to High(FTools) do
    begin
      Result[i].Name        := FTools[i].Name;
      Result[i].Description := FTools[i].Description;
      Result[i].Schema      := FTools[i].Schema;
    end;
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.RunTool(const Name, ArgsJSON: string; out ErrMsg: string): string;
var
  T: TTool;
begin
  ErrMsg := '';
  { Snapshot T under the lock, then release it before dispatching.
    Handlers can sit on a network round-trip for tens of seconds (MCP
    HTTP), and holding the registry lock that long would serialise
    every concurrent gateway request through it. }
  if not Find(Name, T) then
  begin
    ErrMsg := 'unknown tool: ' + Name;
    Exit('');
  end;
  if (not Assigned(T.Handler)) and (not Assigned(T.HandlerObj)) then
  begin
    ErrMsg := 'tool "' + Name + '" has no handler';
    Exit('');
  end;
  try
    if Assigned(T.HandlerObj) then
      Result := T.HandlerObj(ArgsJSON, ErrMsg)
    else
      Result := T.Handler(ArgsJSON, ErrMsg);
  except
    on E: Exception do
    begin
      ErrMsg := E.ClassName + ': ' + E.Message;
      Result := '';
    end;
  end;
end;

end.
