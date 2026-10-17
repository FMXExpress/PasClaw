(*
  PasClaw.Browser.Hooks - the two hooks that make the agent page-aware and
  keep it from changing a page the user did not agree to.

  TPageContextHook   BeforeTurn: append "[page: <title> -- <url>]" (and the
                     selection, when there is one) to the user's message,
                     so "what is this page about?" costs no tool call.
                     Appended INTO the message content rather than as a
                     separate message, which is the shape PasClaw already
                     uses for the per-turn date stamp, and which every
                     provider accepts without a mid-history system role.

  TConfirmMutationHook
                     BeforeToolCall: for the four tools that change the
                     page, ask the host application before running. A
                     refusal cancels the call and hands the model a
                     synthetic result saying so, which is the approval-gate
                     pattern PasClaw.Agent.Hooks documents. "Allow for this
                     site" is remembered per host for the session.

  Both are plain TPasClawHook subclasses over IBrowserBridge, so they run
  under FPC against a fake bridge and a scripted answer function.
*)
unit PasClaw.Browser.Hooks;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  Classes,
  PasClaw.Agent.Hooks,
  PasClaw.Providers.Types,
  PasClaw.Browser.Bridge;

const
  { Marker the context hook looks for so it never stamps a message twice
    -- BeforeTurn runs once per model round, and a turn with tool calls
    has several. }
  PageContextMarker = '[page: ';

  { Selection quoted into the context line. Short: the line is a hint,
    browser_page is the read. }
  ContextSelectionCap = 300;

  { The selection read is a UI round-trip on every turn; keep it snappy
    and treat a miss as "no selection". }
  ContextSelectionTimeoutMs = 2000;

type
  TPageContextHook = class(TPasClawHook)
  private
    FBridge: IBrowserBridge;
    FIncludeSelection: Boolean;
  public
    constructor Create(ABridge: IBrowserBridge; AIncludeSelection: Boolean = True);
    procedure BeforeTurn(var ContinueTurn: Boolean;
                         var Messages: TMessageArray); override;
  end;

  TConfirmAnswer = (caDeny, caAllowOnce, caAllowHost);

  { The host application decides. It runs on the agent's background thread
    and must marshal to the UI itself if it shows a dialog. }
  TConfirmFn = function(const ToolName, ArgsJSON, Host: string): TConfirmAnswer of object;

  TConfirmMutationHook = class(TPasClawHook)
  private
    FBridge:  IBrowserBridge;
    FAsk:     TConfirmFn;
    FAllowed: TStringList;   { hosts the user said "always" for }
  public
    constructor Create(ABridge: IBrowserBridge; AAsk: TConfirmFn);
    destructor Destroy; override;
    procedure BeforeToolCall(const ToolCall: TToolCall;
                             var Cancel: Boolean;
                             var SyntheticResult: string); override;
    { For a UI that wants to show or reset the remembered hosts. }
    function  IsHostAllowed(const Host: string): Boolean;
    procedure AllowHost(const Host: string);
    procedure ForgetHosts;
  end;

{ The host part of a URL, lower-cased, without port: 'https://Ex.com:8/x'
  -> 'ex.com'. '' when there is no scheme://host. Pure; exposed for tests. }
function HostOf(const URL: string): string;

{ The context line the hook appends, built from parts. Pure; exposed so a
  test can pin the exact shape the model sees. }
function BuildPageContextLine(const Title, URL, Selection: string): string;

implementation

uses
  SysUtils,
  PasClaw.Browser.Tools;   { IsMutatingBrowserTool }

{ ---------------------------------------------------------------- pure }

function HostOf(const URL: string): string;
var
  p, q: Integer;
begin
  Result := '';
  p := Pos('://', URL);
  if p = 0 then Exit;
  Result := Copy(URL, p + 3, MaxInt);
  q := Pos('/', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  q := Pos('?', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  q := Pos('#', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  q := Pos('@', Result);           { userinfo, if anyone still writes it }
  if q > 0 then Result := Copy(Result, q + 1, MaxInt);
  q := Pos(':', Result);
  if q > 0 then Result := Copy(Result, 1, q - 1);
  Result := LowerCase(Trim(Result));
end;

function BuildPageContextLine(const Title, URL, Selection: string): string;
var
  Sel: string;
begin
  Result := PageContextMarker + Trim(Title);
  if Trim(URL) <> '' then
    Result := Result + ' -- ' + Trim(URL);
  Result := Result + ']';
  Sel := Trim(Selection);
  if Sel <> '' then
  begin
    if Length(Sel) > ContextSelectionCap then
      Sel := Copy(Sel, 1, ContextSelectionCap) + '...';
    Result := Result + sLineBreak + '[selection: ' + Sel + ']';
  end;
end;

{ ---------------------------------------------------------------- context }

constructor TPageContextHook.Create(ABridge: IBrowserBridge; AIncludeSelection: Boolean);
begin
  inherited Create;
  FBridge := ABridge;
  FIncludeSelection := AIncludeSelection;
end;

procedure TPageContextHook.BeforeTurn(var ContinueTurn: Boolean;
                                      var Messages: TMessageArray);
const
  JsSelection = '(function(){try{return JSON.stringify(String(window.getSelection()));}catch(e){return JSON.stringify("");}})()';
var
  i: Integer;
  Sel, Err: string;
begin
  if FBridge = nil then Exit;
  { The last user message is the one this turn answers. }
  for i := High(Messages) downto 0 do
    if Messages[i].Role = mrUser then
    begin
      if Pos(PageContextMarker, Messages[i].Content) > 0 then Exit;  { already stamped }
      Sel := '';
      if FIncludeSelection then
        if FBridge.Eval(JsSelection, ContextSelectionTimeoutMs, Sel, Err) then
          Sel := UnwrapJsString(Sel)
        else
          Sel := '';
      Messages[i].Content := Messages[i].Content + sLineBreak + sLineBreak +
        BuildPageContextLine(FBridge.CurrentTitle, FBridge.CurrentURL, Sel);
      Exit;
    end;
end;

{ ---------------------------------------------------------------- confirm }

constructor TConfirmMutationHook.Create(ABridge: IBrowserBridge; AAsk: TConfirmFn);
begin
  inherited Create;
  FBridge  := ABridge;
  FAsk     := AAsk;
  FAllowed := TStringList.Create;
  FAllowed.Sorted := True;
  FAllowed.Duplicates := dupIgnore;
  FAllowed.CaseSensitive := False;
end;

destructor TConfirmMutationHook.Destroy;
begin
  FAllowed.Free;
  inherited;
end;

function TConfirmMutationHook.IsHostAllowed(const Host: string): Boolean;
begin
  Result := (Host <> '') and (FAllowed.IndexOf(Host) >= 0);
end;

procedure TConfirmMutationHook.AllowHost(const Host: string);
begin
  if Host <> '' then FAllowed.Add(Host);
end;

procedure TConfirmMutationHook.ForgetHosts;
begin
  FAllowed.Clear;
end;

procedure TConfirmMutationHook.BeforeToolCall(const ToolCall: TToolCall;
                                              var Cancel: Boolean;
                                              var SyntheticResult: string);
var
  Host: string;
begin
  if not IsMutatingBrowserTool(ToolCall.Func.Name) then Exit;
  Host := '';
  if FBridge <> nil then Host := HostOf(FBridge.CurrentURL);
  if IsHostAllowed(Host) then Exit;

  { No asker wired means no way to consent: refuse rather than assume. A
    gate that defaults open is not a gate. }
  if not Assigned(FAsk) then
  begin
    Cancel := True;
    SyntheticResult := 'declined: no confirmation handler is configured, so ' +
                       'page-changing tools are disabled';
    Exit;
  end;

  case FAsk(ToolCall.Func.Name, ToolCall.Func.Arguments, Host) of
    caAllowOnce: ;
    caAllowHost: AllowHost(Host);
  else
    Cancel := True;
    SyntheticResult := 'The user declined ' + ToolCall.Func.Name +
                       ' on this page. Do not retry it; ask what they would like instead.';
  end;
end;

end.
