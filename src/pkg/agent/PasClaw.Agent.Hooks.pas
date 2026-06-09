(*
  PasClaw.Agent.Hooks -- typed hook callbacks the embedder registers
  to observe / veto / transform agent events.

  Picoclaw ships a "hooks" subsystem (BeforeTurn, BeforeToolCall,
  AfterToolResult, OnError); nanobot has progress_hook + the
  agent_event bus. Both let an embedder intercept the loop without
  rewriting it. This unit gives PasClaw the same surface.

  Two motivating use cases drove the API:

    1. Approval / safety policy. An embedder building an agent that
       runs in a sensitive context (production data, paying APIs,
       destructive shell commands) needs to gate specific tool
       calls behind a human approval -- or just outright veto. The
       BeforeToolCall hook returns Cancel + SyntheticResult: when
       Cancel is True the tool's actual handler never fires, and
       the SyntheticResult becomes the tool_result the model sees
       ("approval denied: shell_exec rm -rf /").

    2. Steering. Picoclaw lets the host inject extra context
       BETWEEN tool calls inside one turn -- "based on the file you
       just read, also check X". AfterToolResult returns a
       SteeringMessage; whenever non-empty, ToolLoop appends it as
       a fresh mrSystem note to the history before the next LLM
       round. Multiple hooks can each contribute; their messages
       concatenate in registration order.

  Hooks form a list, not a single callback. Embedders subclass
  TPasClawHook and override only the methods they care about (the
  base provides no-op defaults). TPasClawAgent owns the registered
  hook instances and frees them in Destroy.

  Wire from PasClaw.Agent:

      type
        TApprovalHook = class(TPasClawHook)
          procedure BeforeToolCall(const ToolCall: TToolCall;
                                   var Cancel: Boolean;
                                   var SyntheticResult: string); override;
        end;

      Agent.RegisterHook(TApprovalHook.Create);

  Hooks run on the main thread, regardless of whether the underlying
  tool dispatch is parallel -- BeforeToolCall fires before any worker
  spawns, AfterToolResult fires after all workers in a batch have
  joined, in array order. Same ordering guarantees the existing
  OnToolCall / OnToolResult events have.
*)
unit PasClaw.Agent.Hooks;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Identity;

type
  { Stage discriminator for the OnError hook. The agent loop reports
    where it caught the failure so an observer hook can log /
    categorise / fire alerts. }
  TPasClawHookStage = (
    hsBeforeTurn,        { while preparing the next LLM round-trip }
    hsBeforeToolCall,    { while preparing to dispatch a tool      }
    hsDuringToolCall,    { tool's own handler raised               }
    hsAfterToolResult,   { while processing the result             }
    hsProviderCall       { LLM provider Chat raised                }
  );

  { Base hook. All methods are no-ops by default; subclass and
    override only what you need. The agent loop calls each method
    on the main thread, in hook-registration order. }
  TPasClawHook = class
  public
    (* Per-turn sender identity. RunToolLoop writes this on every
       hook in the chain before dispatching any virtual, so override
       implementations can read `Self.Identity` to gate by user
       (an approval hook that lets `slack:U-admin` through but
       prompts for confirmation on everyone else, an audit hook that
       tags log lines with the canonical id, etc.). Empty record =
       no identity propagated (CLI / cron / embedder paths that
       didn't set TToolLoopConfig.Identity). Codex P2 on PR #119. *)
    Identity: TIdentity;
    { Fired once per iteration of the agent loop, BEFORE the LLM
      Chat call. Implementers can inspect or mutate Messages in
      place (the loop hands a `var TMessageArray` so a hook can
      append a system note or rewrite the tail). Set ContinueTurn
      to False to abort the loop gracefully -- the parent's final
      reply will be whatever the loop has accumulated up to this
      point. Default: no-op (ContinueTurn stays True). }
    procedure BeforeTurn(var ContinueTurn: Boolean;
                         var Messages: TMessageArray); virtual;

    { Fired BEFORE each individual tool dispatch. Setting
      Cancel := True skips the actual tool handler -- the loop
      uses SyntheticResult as the tool_result content (and pairs
      it with the original ToolCall.Id so the provider's
      tool_use/tool_result pairing stays intact). Combine with
      simple substring tests on ToolCall.Func.Name and Arguments
      for an approval-gate hook; combine with a UI prompt to
      build human-in-the-loop. Default: no-op (Cancel stays
      False, SyntheticResult stays empty). }
    procedure BeforeToolCall(const ToolCall: TToolCall;
                             var Cancel: Boolean;
                             var SyntheticResult: string); virtual;

    { Fired AFTER each individual tool dispatch (whether the
      handler ran or a BeforeToolCall hook short-circuited it).
      ResultText and ErrMsg are var-params: a hook can rewrite
      either to redact PII, truncate verbose output, or convert
      a soft error into a hard one. SteeringMessage lets the
      hook inject a system-role message into the history before
      the NEXT iteration -- picoclaw's "steering" pattern. Returns
      to '' between hooks so each hook decides independently. The
      loop concatenates all non-empty SteeringMessages from this
      batch into a single mrSystem entry. Default: no-op. }
    procedure AfterToolResult(const ToolCall: TToolCall;
                              var ResultText, ErrMsg: string;
                              var SteeringMessage: string); virtual;

    { Fired on any caught failure. Stage indicates where. Hooks
      see errors AFTER the loop has logged them and decided how
      to surface them to the model -- they're for the embedder's
      side (metrics, alerting), not for changing loop behaviour.
      Default: no-op. }
    procedure OnError(Stage: TPasClawHookStage;
                      const Msg: string); virtual;
  end;

  TPasClawHookArray = array of TPasClawHook;

{ ------------------- batch-dispatch helpers used by RunToolLoop ------------ }

{ Fire BeforeTurn on every hook in order. Returns True when all
  hooks were OK with the turn continuing (the common case);
  returns False when any hook cleared ContinueTurn. Messages are
  passed through unchanged when no hooks are registered. }
function HooksBeforeTurn(const Hooks: TPasClawHookArray;
                          var Messages: TMessageArray): Boolean;

{ Fire BeforeToolCall on every hook in order. The first hook to
  set Cancel := True wins -- subsequent hooks still see the call
  but their Cancel setting is ignored (an early "deny" should not
  be overridden by a later "allow"). SyntheticResult on out is the
  first non-empty value any hook set; later overwrites are
  preserved, so an approval hook can write a one-line denial then
  a logging hook can append a richer message. }
procedure HooksBeforeToolCall(const Hooks: TPasClawHookArray;
                               const ToolCall: TToolCall;
                               out Cancelled: Boolean;
                               out SyntheticResult: string);

{ Fire AfterToolResult on every hook in order. ResultText and
  ErrMsg are passed by ref so each hook's rewrite is visible to
  the next. SteeringMessages from each hook are concatenated with
  '\n\n' separators and returned -- the loop wraps the result in a
  single mrSystem message appended to history. Returns '' when
  no hook contributed a steering note. }
function HooksAfterToolResult(const Hooks: TPasClawHookArray;
                               const ToolCall: TToolCall;
                               var ResultText, ErrMsg: string): string;

{ Fire OnError on every hook in order. Hooks can't suppress the
  error -- the loop has already decided to record it. This is the
  embedder's observation hook for metrics / alerting. }
procedure HooksOnError(const Hooks: TPasClawHookArray;
                        Stage: TPasClawHookStage;
                        const Msg: string);

implementation

{ All defaults are no-ops; subclasses override what they need. }

procedure TPasClawHook.BeforeTurn(var ContinueTurn: Boolean;
                                   var Messages: TMessageArray);
begin
end;

procedure TPasClawHook.BeforeToolCall(const ToolCall: TToolCall;
                                       var Cancel: Boolean;
                                       var SyntheticResult: string);
begin
end;

procedure TPasClawHook.AfterToolResult(const ToolCall: TToolCall;
                                        var ResultText, ErrMsg: string;
                                        var SteeringMessage: string);
begin
end;

procedure TPasClawHook.OnError(Stage: TPasClawHookStage;
                                const Msg: string);
begin
end;

function HooksBeforeTurn(const Hooks: TPasClawHookArray;
                          var Messages: TMessageArray): Boolean;
var
  i: Integer;
  ContinueTurn: Boolean;
begin
  for i := 0 to High(Hooks) do
  begin
    if Hooks[i] = nil then Continue;
    ContinueTurn := True;
    Hooks[i].BeforeTurn(ContinueTurn, Messages);
    if not ContinueTurn then
      Exit(False);
  end;
  Result := True;
end;

procedure HooksBeforeToolCall(const Hooks: TPasClawHookArray;
                               const ToolCall: TToolCall;
                               out Cancelled: Boolean;
                               out SyntheticResult: string);
var
  i: Integer;
  LocalCancel: Boolean;
  LocalResult: string;
begin
  Cancelled := False;
  SyntheticResult := '';
  for i := 0 to High(Hooks) do
  begin
    if Hooks[i] = nil then Continue;
    LocalCancel := Cancelled;       { sticky: once True, stays True }
    LocalResult := SyntheticResult;
    Hooks[i].BeforeToolCall(ToolCall, LocalCancel, LocalResult);
    if LocalCancel then Cancelled := True;
    if LocalResult <> '' then SyntheticResult := LocalResult;
  end;
end;

function HooksAfterToolResult(const Hooks: TPasClawHookArray;
                               const ToolCall: TToolCall;
                               var ResultText, ErrMsg: string): string;
var
  i: Integer;
  Steering: string;
begin
  Result := '';
  for i := 0 to High(Hooks) do
  begin
    if Hooks[i] = nil then Continue;
    Steering := '';
    Hooks[i].AfterToolResult(ToolCall, ResultText, ErrMsg, Steering);
    if Steering <> '' then
    begin
      if Result <> '' then Result := Result + sLineBreak + sLineBreak;
      Result := Result + Steering;
    end;
  end;
end;

procedure HooksOnError(const Hooks: TPasClawHookArray;
                        Stage: TPasClawHookStage;
                        const Msg: string);
var
  i: Integer;
begin
  for i := 0 to High(Hooks) do
  begin
    if Hooks[i] = nil then Continue;
    try
      Hooks[i].OnError(Stage, Msg);
    except
      { Swallow -- a hook crashing during error reporting shouldn't
        replace the real error with the hook's own exception. }
    end;
  end;
end;

end.
