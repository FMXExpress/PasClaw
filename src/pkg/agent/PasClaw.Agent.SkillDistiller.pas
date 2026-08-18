(*
  PasClaw.Agent.SkillDistiller - autonomous skill creation (Hermes-style).

  After a qualifying turn, ask a small LLM call whether the work just
  performed is a reusable procedure worth saving as a skill. If yes, the
  model drafts a SKILL.md which is run through the same guard + staging
  path as the skill_manage tool (PasClaw.Skills.Manage) -- so by default
  it lands in workspace/skills/.pending/ awaiting operator approval, and
  with auto_approve on it lands committed (effective next agent start).

  Triggers (all gated on Cfg.SelfImprovingSkills.Distiller.Enabled):
    - the turn dispatched >= Distiller.MinToolCalls tool calls (proxy for
      "non-trivial workflow"). A one-shot answer that needed no tools is
      never worth distilling.

  De-duplication: before drafting, the existing skill descriptions are
  loaded and the candidate is dropped if it overlaps an existing skill
  too closely (Jaccard token similarity > 0.8) -- so the same workflow
  doesn't accrete near-duplicate skills across sessions.

  Cost: exactly one extra Provider.Chat per qualifying turn, at low
  effort with a small token cap. Point Distiller.Model at a cheap model
  to keep the tax negligible. The call runs AFTER the user-facing reply
  is delivered, so it never adds latency to the response the user sees.

  This unit deliberately does NOT depend on PasClaw.Agent or
  PasClaw.Tools.ToolLoop -- it takes the turn facts as plain parameters,
  so the agent/loop units can call it without a circular import.
*)
unit PasClaw.Agent.SkillDistiller;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Config,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

(* Consider the just-finished turn for distillation. No-op unless the
   distiller is enabled and the turn dispatched enough tool calls.
   UserMessage is the user's request; AssistantReply is the final answer;
   Transcript is a compact human-readable summary of what happened (tool
   names + key results) -- callers pass whatever they cheaply have. *)
procedure MaybeDistillTurn(const Cfg: TConfig;
                           Provider: ILLMProvider;
                           const Model, UserMessage, AssistantReply, Transcript: string;
                           ToolCallsDispatched: Int64);

(* Build a compact, bounded transcript string from a finished turn's
   message history -- "called fs_read(...) -> ...", one line per tool
   step. Callers that have the loop's FinalMessages pass them here so
   the distiller sees what the agent actually did. Capped so a chatty
   turn can't bloat the distiller's own prompt. *)
function DistillTranscriptFromMessages(const Msgs: array of TMessage): string;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Utils,
  PasClaw.Skills.Loader,
  PasClaw.Skills.Manage;

const
  DistillerSystemPrompt =
    'You are a "skill distiller". You are shown a task an AI agent just ' +
    'completed (the user request, the steps it took, and its final answer). ' +
    'Decide whether the procedure is GENERAL and REUSABLE enough that saving ' +
    'it as a skill would help on future, similar tasks. Save a skill ONLY for ' +
    'a non-trivial, repeatable workflow -- NOT for one-off answers, trivia, or ' +
    'anything specific to this exact input.'#10#10 +
    'Respond with STRICT JSON and nothing else:'#10 +
    '{"create": true, "name": "lower_snake_or_kebab", "description": "one line", ' +
    '"body": "# Title\n\nProcedural markdown: when to use, steps, pitfalls."}'#10 +
    'or {"create": false} if not worth saving. The name must be lowercase ' +
    'letters/digits/-/_ only. Keep the body focused and under ~300 words.';

(* Tokenise to a lowercase word set for Jaccard similarity. *)
function TokenSet(const S: string): TStringList;
var
  i: Integer;
  c: Char;
  Cur: string;
begin
  Result := TStringList.Create;
  Result.Sorted := True;
  Result.Duplicates := dupIgnore;
  Cur := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if ((c >= 'a') and (c <= 'z')) or ((c >= 'A') and (c <= 'Z')) or
       ((c >= '0') and (c <= '9')) then
      Cur := Cur + LowerCase(c)
    else
    begin
      if Length(Cur) >= 3 then Result.Add(Cur);
      Cur := '';
    end;
  end;
  if Length(Cur) >= 3 then Result.Add(Cur);
end;

function Jaccard(A, B: TStringList): Double;
var
  i, Inter: Integer;
  UnionN: Integer;
begin
  if (A.Count = 0) or (B.Count = 0) then Exit(0);
  Inter := 0;
  for i := 0 to A.Count - 1 do
    if B.IndexOf(A[i]) >= 0 then Inc(Inter);
  UnionN := A.Count + B.Count - Inter;
  if UnionN = 0 then Exit(0);
  Result := Inter / UnionN;
end;

(* True if Desc is too close to any existing skill's name+description. *)
function IsDuplicate(const HomeDir, Name, Desc: string): Boolean;
var
  Skills: TSkillSpecArray;
  Cand, Ex: TStringList;
  i: Integer;
begin
  Result := False;
  Skills := LoadSkillManifests(HomeDir);
  Cand := TokenSet(Name + ' ' + Desc);
  try
    for i := 0 to High(Skills) do
    begin
      if SameText(Skills[i].Name, Name) then Exit(True);
      Ex := TokenSet(Skills[i].Name + ' ' + Skills[i].Description);
      try
        if Jaccard(Cand, Ex) > 0.8 then Exit(True);
      finally
        Ex.Free;
      end;
    end;
  finally
    Cand.Free;
  end;
end;

(* Pull the first balanced-looking JSON object out of a response that
   might be wrapped in prose or a ```json fence. *)
function ExtractJSONObject(const S: string): string;
var
  First, Last: Integer;
begin
  Result := '';
  First := Pos('{', S);
  if First <= 0 then Exit;
  Last := Length(S);
  while (Last > First) and (S[Last] <> '}') do Dec(Last);
  if Last > First then Result := Copy(S, First, Last - First + 1);
end;

function Clip(const S: string; N: Integer): string;
begin
  if Length(S) <= N then Result := S
  else Result := Copy(S, 1, N) + '...';
end;

function DistillTranscriptFromMessages(const Msgs: array of TMessage): string;
const
  MaxChars = 3000;
var
  i, j: Integer;
  Sb: TStringBuilder;
  Line: string;
begin
  Sb := TStringBuilder.Create;
  try
    for i := 0 to High(Msgs) do
    begin
      if Sb.Length >= MaxChars then Break;
      case Msgs[i].Role of
        mrAssistant:
          begin
            for j := 0 to High(Msgs[i].ToolCalls) do
              Sb.Append('- called ').Append(Msgs[i].ToolCalls[j].Func.Name)
                .Append('(').Append(Clip(Msgs[i].ToolCalls[j].Func.Arguments, 160))
                .Append(')').Append(#10);
            if Trim(Msgs[i].Content) <> '' then
              Sb.Append('- assistant: ').Append(Clip(Trim(Msgs[i].Content), 200)).Append(#10);
          end;
        mrTool:
          begin
            Line := Clip(Trim(Msgs[i].Content), 200);
            if Line <> '' then Sb.Append('  -> ').Append(Line).Append(#10);
          end;
      end;
    end;
    Result := Clip(Sb.ToString, MaxChars);
  finally
    Sb.Free;
  end;
end;

function BuildSkillMD(const Name, Desc, Body: string): string;
begin
  Result := '---'#10 +
            'name: ' + Name + #10 +
            'description: ' + Desc + #10 +
            '---'#10#10 +
            Body;
end;

procedure MaybeDistillTurn(const Cfg: TConfig;
                           Provider: ILLMProvider;
                           const Model, UserMessage, AssistantReply, Transcript: string;
                           ToolCallsDispatched: Int64);
var
  Msgs: array of TMessage;
  Opts: TChatOptions;
  UseModel, UserBlock, Raw, JSON: string;
  Resp: TLLMResponse;
  O: TJsonObject;
  Name, Desc, Body, SkillMD: string;
  OutName, OutPath, OutPend, ErrMsg: string;
begin
  if Provider = nil then Exit;
  if not Cfg.SelfImprovingSkills.Distiller.Enabled then Exit;
  if ToolCallsDispatched < Cfg.SelfImprovingSkills.Distiller.MinToolCalls then Exit;

  UseModel := Cfg.SelfImprovingSkills.Distiller.Model;
  if UseModel = '' then UseModel := Model;

  UserBlock :=
    '## User request'#10 + UserMessage + #10#10 +
    '## What the agent did'#10 + Transcript + #10#10 +
    '## Final answer'#10 + AssistantReply;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, UserBlock);

  Opts := DefaultChatOptions;
  { PRIVACY: never let provider grounding fire for this call. Gemini's
    google_search is ON by default, and grounding works by having the
    model formulate search queries FROM ITS CONTEXT -- which here is the
    user's own content. Sending that to a search engine is the harm; a
    maintenance pass over text we already hold has no business searching
    the web at all. }
  Opts.DisableServerTools := True;
  Opts.SystemPrompt  := DistillerSystemPrompt;
  Opts.MaxTokens     := 1200;
  Opts.Temperature   := 0.2;
  Opts.ThinkingLevel := 'low';
  Opts.ToolChoice    := 'none';
  Opts.Stream        := False;
  Opts.CacheEnabled  := False;

  try
    Resp := Provider.Chat(Msgs, [], UseModel, Opts);
  except
    on E: Exception do
    begin
      LogDebug('skill distiller: provider call failed: %s', [E.Message]);
      Exit;
    end;
  end;

  JSON := ExtractJSONObject(Resp.Content);
  if JSON = '' then
  begin
    LogDebug('skill distiller: no JSON in response -- skipping');
    Exit;
  end;

  O := TJsonObject.Parse(JSON);
  if O = nil then Exit;
  try
    if not O.GetBool('create', False) then
    begin
      LogDebug('skill distiller: model declined (create=false)');
      Exit;
    end;
    Name := Trim(O.GetStr('name', ''));
    Desc := Trim(O.GetStr('description', ''));
    Body := O.GetStr('body', '');
  finally
    O.Free;
  end;

  if (Name = '') or (Body = '') then
  begin
    LogDebug('skill distiller: incomplete draft (name/body empty) -- skipping');
    Exit;
  end;

  if IsDuplicate(GetHome, Name, Desc) then
  begin
    LogInfo('skill distiller: candidate "%s" overlaps an existing skill -- skipping', [Name]);
    Exit;
  end;

  SkillMD := BuildSkillMD(Name, Desc, Body);
  if not CreateSkillFromContent(GetHome, SkillMD,
                                Cfg.SelfImprovingSkills.AutoApprove,
                                Cfg.SelfImprovingSkills.GuardDeny,
                                OutName, OutPath, OutPend, ErrMsg) then
  begin
    LogInfo('skill distiller: draft "%s" rejected: %s', [Name, ErrMsg]);
    Exit;
  end;

  if OutPend <> '' then
    LogInfo('skill distiller: drafted skill "%s" staged as pending %s (approve with: pasclaw skills approve %s)',
            [OutName, OutPend, OutPend])
  else
    LogInfo('skill distiller: drafted + committed skill "%s" at %s (effective next agent start)',
            [OutName, OutPath]);
end;

end.
