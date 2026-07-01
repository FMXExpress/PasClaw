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
  PasClaw.Utils,            { canonical TStringArray (Delphi side) }
  PasClaw.Tools.Types,
  PasClaw.Providers.Types;

type
  {$IFNDEF FPC}
  { Delphi's RTL doesn't declare TStringArray (FPC's SysUtils does). Alias the
    one canonical definition in PasClaw.Utils so every unit's TStringArray is
    the SAME type identity -- otherwise dcc64 rejects cross-unit array passes
    (E2010/E2250). }
  TStringArray = PasClaw.Utils.TStringArray;
  {$ENDIF}

  TToolRegistry = class
  private
    FTools: TToolList;
    { Set of tool names whose IsDeferred=True has been overridden by a
      tool_search reveal. Names are looked up case-sensitively (matches
      Find) and only consulted when filtering ToProviderDefs. Stored
      separately from FTools so a re-register from the MCP bridge's
      live-connect pass can replace the TTool record without us losing
      track of which names the model has already pulled. }
    FRevealed: TStringArray;
    { Background MCP loaders (PasClaw.MCP.Bridge) call Register after
      ConnectMCPServers has already returned; gateway worker threads
      may be reading the same array via Find / ToProviderDefs at the
      same time. One CS guards every method's data-access phase.
      RunTool releases the lock before invoking the handler so a slow
      tool (HTTP MCP call, shell-out) can't block parallel reads. }
    FLock:  TCriticalSection;
    function IsRevealedLocked(const Name: string): Boolean;
    procedure RegisterImpl(const T: TTool);
  public
    constructor Create;
    destructor  Destroy; override;
    { Register a tool. Defensively zeroes T.IsDeferred so legacy
      stack-built records (RegisterFSTools, RegisterShellTool, every
      TPasClawTool subclass) that never touched the new field don't
      get accidentally hidden from ToProviderDefs by stack garbage.
      The MCP bridge -- the only legitimate IsDeferred=True source --
      routes through RegisterDeferred instead, which preserves the
      explicit value. This mirrors the existing HandlerObj defensive
      clear: same risk shape, same fix shape. }
    procedure Register(const T: TTool);
    { Register a hidden back-compat alias (old tool name -> same handler).
      Dispatches normally via Find / RunTool but is skipped by
      ToProviderDefs, so the model only ever sees the new canonical name. }
    procedure RegisterHidden(const T: TTool);
    { Register a tool with an explicit IsDeferred override. Used by
      PasClaw.MCP.Bridge when Cfg.MCPProgressiveDisclosure is on so
      newly-registered MCP tools are stripped from ToProviderDefs
      until tool_search reveals them. Callers must NOT also set
      T.IsDeferred -- the Deferred parameter is authoritative. }
    procedure RegisterDeferred(const T: TTool; Deferred: Boolean);
    function  Find(const Name: string; out T: TTool): Boolean;
    function  Names: TStringArray;
    function  Count: Integer;
    function  ToProviderDefs: TToolDefinitionArray;
    function  RunTool(const Name, ArgsJSON: string; out ErrMsg: string): string;
    { Progressive-disclosure surface (PasClaw.MCP.Disclosure / tool_search).

      DeferredNames returns the registered tool names whose IsDeferred is
      still True (haven't been revealed yet) -- the source list a discovery
      tool uses to populate its name-only index.

      DeferredFind returns the full TTool for a deferred name so tool_search
      can hand the schema back to the model.

      Reveal moves the name into the revealed set so the NEXT ToProviderDefs
      call includes it -- the model can then invoke the tool through the
      normal tool-call path. Idempotent; calling on an undeclared name is
      a silent no-op so a model that calls tool_search with stale names
      can't wedge the registry. }
    function  DeferredNames: TStringArray;
    function  DeferredFind(const Name: string; out T: TTool): Boolean;
    procedure Reveal(const Name: string);
    { True once any deferred tool has been revealed (FRevealed non-empty).
      Lets tool_search distinguish "deferred set empty because all MCP tools
      are revealed + active" from "empty because none ever loaded". }
    function  AnyRevealed: Boolean;
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

procedure TToolRegistry.RegisterImpl(const T: TTool);
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

procedure TToolRegistry.Register(const T: TTool);
var
  Modified: TTool;
begin
  Modified := T;
  { Same risk shape as the HandlerObj defensive clear in RegisterImpl:
    legacy callers (RegisterFSTools, RegisterShellTool, every
    TPasClawTool subclass) build T: TTool on the stack and never
    touched the new IsDeferred field. Stack garbage there would let
    ToProviderDefs silently drop a core tool from the provider's
    tools array even when MCP progressive disclosure is off. Force
    False here; MCP -- the only legitimate IsDeferred=True path --
    goes through RegisterDeferred instead. }
  Modified.IsDeferred := False;
  { Same defensive clear for the Hidden alias flag -- legacy stack-built
    records never set it, so garbage there could silently drop a core tool
    from ToProviderDefs. Aliases go through RegisterHidden instead. }
  Modified.Hidden := False;
  RegisterImpl(Modified);
end;

procedure TToolRegistry.RegisterHidden(const T: TTool);
{ Register a back-compat alias: dispatches via Find / RunTool but is hidden
  from ToProviderDefs so the model only sees the new canonical name. }
var
  Modified: TTool;
begin
  Modified := T;
  Modified.IsDeferred := False;
  Modified.Hidden     := True;
  RegisterImpl(Modified);
end;

procedure TToolRegistry.RegisterDeferred(const T: TTool; Deferred: Boolean);
var
  Modified: TTool;
begin
  Modified := T;
  Modified.IsDeferred := Deferred;
  RegisterImpl(Modified);
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

function TToolRegistry.AnyRevealed: Boolean;
begin
  FLock.Acquire;
  try
    Result := Length(FRevealed) > 0;
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.IsRevealedLocked(const Name: string): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(FRevealed) do
    if FRevealed[i] = Name then Exit(True);
  Result := False;
end;

function TToolRegistry.ToProviderDefs: TToolDefinitionArray;
var
  i, k: Integer;
begin
  FLock.Acquire;
  try
    SetLength(Result, Length(FTools));
    k := 0;
    for i := 0 to High(FTools) do
    begin
      { Progressive-disclosure filter: skip tools the bridge marked
        deferred unless tool_search has since revealed the name. This
        keeps the provider's per-request `tools` array small (and the
        token bill low) while leaving the dispatcher unchanged. }
      if FTools[i].IsDeferred and (not IsRevealedLocked(FTools[i].Name)) then
        Continue;
      { Hidden back-compat aliases dispatch but never reach the model's
        tool list -- only the new canonical name is advertised. }
      if FTools[i].Hidden then
        Continue;
      Result[k].Name        := FTools[i].Name;
      Result[k].Description := FTools[i].Description;
      Result[k].Schema      := FTools[i].Schema;
      Inc(k);
    end;
    SetLength(Result, k);
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.DeferredNames: TStringArray;
var
  i, k: Integer;
begin
  FLock.Acquire;
  try
    SetLength(Result, Length(FTools));
    k := 0;
    for i := 0 to High(FTools) do
      if FTools[i].IsDeferred and (not IsRevealedLocked(FTools[i].Name)) then
      begin
        Result[k] := FTools[i].Name;
        Inc(k);
      end;
    SetLength(Result, k);
  finally
    FLock.Release;
  end;
end;

function TToolRegistry.DeferredFind(const Name: string; out T: TTool): Boolean;
var
  i: Integer;
begin
  FLock.Acquire;
  try
    for i := 0 to High(FTools) do
      if (FTools[i].Name = Name) and FTools[i].IsDeferred then
      begin
        T := FTools[i];
        Exit(True);
      end;
    Result := False;
  finally
    FLock.Release;
  end;
end;

procedure TToolRegistry.Reveal(const Name: string);
var
  i: Integer;
begin
  if Name = '' then Exit;
  FLock.Acquire;
  try
    { Silently no-op when the name doesn't match a deferred entry --
      protects against a model that calls tool_search with stale names
      from a previous session. Also dedupe so a re-reveal doesn't grow
      FRevealed unbounded across a long session. }
    for i := 0 to High(FTools) do
      if (FTools[i].Name = Name) and FTools[i].IsDeferred then
      begin
        if not IsRevealedLocked(Name) then
        begin
          SetLength(FRevealed, Length(FRevealed) + 1);
          FRevealed[High(FRevealed)] := Name;
        end;
        Exit;
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
