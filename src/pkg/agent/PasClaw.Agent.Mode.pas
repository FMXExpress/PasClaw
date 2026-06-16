(*
  PasClaw.Agent.Mode - Plan / Build mode toggle.

  Two operator-facing modes, modelled on opencode's plan-vs-build agents:

    pmBuild  (default) -- full tool access; tcMutating tools dispatch as
                          usual. This is the historical behaviour.

    pmPlan              -- read-only. Tools categorised as tcMutating
                          (PasClaw.Tools.Types.TToolCategory: fs_write,
                          fs_edit_hashline, shell_exec, execute_code,
                          send_message, skills_manage, ...) are REFUSED
                          at dispatch time with a clear "switch to build
                          mode to run X" message. Read-only tools
                          (fs_read, fs_list, fs_grep, memory_search,
                          web_search, web_fetch, skills_list,
                          skills_view, ...) dispatch normally.

  The enum's first value is pmBuild on purpose: TToolLoopConfig is a
  zero-initialised record, so callers that don't bother setting Mode
  land on the historical full-access behaviour. Plan mode is strictly
  opt-in.

  Mode plumbing per surface (PR #290):

    pasclaw agent --mode plan|build       process-global
    pasclaw tui                           Tab key cycles when chat
                                          focused; status bar shows
                                          [mode: plan|build]
    /v1/chat/completions, /v1/chat,       per-request: optional `mode`
    /v1/responses                         field in the JSON body, default
                                          "build"

  Each request that enters RunToolLoop sets Cfg.Mode; the dispatch path
  consults it. There is NO process-global Mode getter for the gateway
  path on purpose -- two concurrent /v1/chat requests can run in
  different modes.

  System prompt: PasClaw.Agent.Prompt.BuildSystemPrompt adds a "PLAN
  MODE" block when Cfg.Mode = pmPlan, instructing the model not to
  attempt mutating tools (which would refuse anyway). This is belt and
  braces; the dispatch gate is the authority.

  Subagent propagation: when a parent agent in pmPlan spawns via the
  `spawn` tool, the child inherits pmPlan. Plan mode is therefore
  contagious downward.
*)
unit PasClaw.Agent.Mode;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TPasClawMode = (pmBuild, pmPlan);

function ModeName(M: TPasClawMode): string;
function ParseMode(const S: string; out M: TPasClawMode): Boolean;
function CycleMode(M: TPasClawMode): TPasClawMode;

(* Parse the "mode" field out of a chat-request JSON body. Default
   pmBuild when absent / blank / unparseable -- the gateway treats
   "no mode field" as the historical full-access behaviour so existing
   OpenAI-compatible clients that don't know about plan mode keep
   working unchanged. *)
function ParseModeFromBody(const Body: string): TPasClawMode;

(* Human-readable refusal a tool dispatcher returns when a mutating
   tool fires under pmPlan. Caller can prefix with whatever framing
   suits its surface; the message itself names the tool + how to
   switch. *)
function PlanModeRefusal(const ToolName: string): string;

implementation

uses
  PasClaw.JSON;

function ModeName(M: TPasClawMode): string;
begin
  case M of
    pmBuild: Result := 'build';
    pmPlan:  Result := 'plan';
  else
    Result := 'build';
  end;
end;

function ParseMode(const S: string; out M: TPasClawMode): Boolean;
var
  L: string;
begin
  L := LowerCase(Trim(S));
  if (L = '') or (L = 'build') or (L = 'b') then
  begin
    M := pmBuild; Result := True;
  end
  else if (L = 'plan') or (L = 'p') or (L = 'read-only') or (L = 'readonly') then
  begin
    M := pmPlan; Result := True;
  end
  else
  begin
    M := pmBuild; Result := False;
  end;
end;

function CycleMode(M: TPasClawMode): TPasClawMode;
begin
  case M of
    pmBuild: Result := pmPlan;
    pmPlan:  Result := pmBuild;
  else
    Result := pmBuild;
  end;
end;

function ParseModeFromBody(const Body: string): TPasClawMode;
var
  O: TJsonObject;
  M: TPasClawMode;
begin
  Result := pmBuild;
  if Trim(Body) = '' then Exit;
  try
    O := TJsonObject.Parse(Body);
  except
    { Malformed JSON -- treat as absent mode and let the existing
      body-parse error path (in the gateway handler) surface the real
      problem. We don't want a bad-JSON exception leaking out of a
      best-effort field lookup. }
    Exit;
  end;
  if O = nil then Exit;
  try
    if ParseMode(O.GetStr('mode', ''), M) then Result := M;
  finally
    O.Free;
  end;
end;

function PlanModeRefusal(const ToolName: string): string;
begin
  Result := 'refused: tool "' + ToolName + '" needs build mode (this tool ' +
            'writes files or executes commands). Switch to build mode and ' +
            'retry: TUI Tab key | CLI --mode build | web UI mode toggle.';
end;

end.
