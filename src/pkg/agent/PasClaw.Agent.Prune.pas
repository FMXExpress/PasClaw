(*
  PasClaw.Agent.Prune - LLM-guided context pruning (deletion-based
  compaction).

  Compaction REWRITES: it summarises the older half and throws the
  originals away, so everything that survives is the summariser's prose
  and every detail it declined to mention is gone. Pruning DELETES: a
  strong model reads what the history contains, says which parts do not
  matter, and everything it does not name survives BYTE FOR BYTE. The
  file paths, the error text, the exact tool arguments -- still the
  originals, not a paraphrase of them.

  The two are complements, not rivals, and this unit runs FIRST:

    prune  (lossless for survivors)  -- drop the junk
    compact (lossy for everything)   -- only if still too big

  A session is usually large because of a handful of enormous tool
  results, not because the conversation is long. Pruning those often
  brings the history back under the compaction threshold, and the turn
  keeps its real transcript instead of a summary of one.

  ---- the model returns a PLAN, never a transcript ----

  The pruner is asked for decisions, not for edited text:

    {"decisions":[{"id":3,"action":"drop"},
                  {"id":7,"action":"marker",
                   "text":"[test output omitted -- 412 passed, 0 failed]"}]}

  and this unit applies them. A model handed the transcript to rewrite
  would eventually "helpfully" fix a file path, drop a tool_call_id, or
  reword an error -- silently corrupting the record it was asked to
  preserve. Deciding is a judgement; editing is a mechanism, and the
  mechanism stays here.

  ---- what cannot be pruned, enforced in code ----

  The prompt asks nicely. These are guaranteed regardless of what comes
  back, because a prompt is not a contract:

    Leading system messages          never offered, never touched.
    The recent window                ProtectTailTokens' worth of newest
                                     messages is never a candidate --
                                     the current task lives there.
    Tool-call groups                 an assistant turn carrying
                                     tool_calls and the tool results
                                     answering it are ONE candidate,
                                     decided together. Dropping half a
                                     group is an orphaned tool_use, a
                                     400 from Anthropic and OpenAI both.
    Anything not named               omitted id = KEEP. A truncated,
                                     garbled or empty reply therefore
                                     prunes nothing, rather than
                                     deleting everything it failed to
                                     mention.

  ---- what it costs, and why it is not free ----

  Candidates are offered as a HEAD+TAIL PREVIEW, not in full. Sending
  the whole session to judge the whole session reproduces the problem
  being solved -- the pruner call would grow with the history and
  eventually overflow the same window. A preview is enough to tell a
  build log from a decision, which is the judgement actually being
  asked for.

  It still costs a call to a strong model, so this is OFF by default and
  gated three ways: an explicit enable, a token threshold, and a minimum
  number of iterations between passes. Nothing here runs on a small
  session, and nothing here runs every turn.

  ---- the deterministic half already exists ----

  Cheap structural trimming is ToolOutputCap's job (see
  PasClaw.Tools.OutputCache): oversize tool results are truncated at
  dispatch, before they ever enter the history. That is the pass that
  should run always. This unit is the judgement pass for what survives
  it -- the superseded exploration, the duplicate read, the log that is
  small enough to keep and useless to keep.
*)
unit PasClaw.Agent.Prune;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf;

type
  (* Fired with the FULL history, once a pass has candidates and is
     about to delete some of them -- the caller's chance to keep a copy
     of what is being removed. Same shape and same reason as
     compaction's OnBefore: this unit knows about messages, not about
     where a session lives, and the archive belongs to whoever owns the
     file. Not fired when the pass turns out to prune nothing. *)
  TPruneBeforeCallback = procedure(const Messages: array of TMessage) of object;

  TPruneOptions = record
    { Off unless an operator says otherwise: this spends a call to a
      strong model, which is not a cost to impose by default. }
    Enabled:            Boolean;
    { Below this estimate the history is not worth a pruner call. }
    ThresholdTokens:    Integer;
    { Newest messages worth this many tokens are never candidates. }
    ProtectTailTokens:  Integer;
    { A candidate group smaller than this is not worth a decision. }
    MinCandidateTokens: Integer;
    { Head and tail characters shown per candidate. }
    PreviewChars:       Integer;
    { The pruner's model. Empty means the caller's. }
    Model:              string;
    { Archive hook -- see TPruneBeforeCallback. }
    OnBefore:           TPruneBeforeCallback;
  end;

  { What a pass did, for the caller's log line. }
  TPruneResult = record
    Considered:   Integer;   { candidate groups offered }
    Dropped:      Integer;   { messages removed outright }
    Marked:       Integer;   { messages replaced with a marker }
    TokensBefore: Integer;
    TokensAfter:  Integer;
  end;

function DefaultPruneOptions: TPruneOptions;

{ True iff the history plus system prompt estimates above Threshold.
  Same cheap heuristic and same disable-on-zero rule as NeedsCompact. }
function NeedsPrune(const Messages: array of TMessage;
                    const SystemPrompt: string;
                    Threshold: Integer): Boolean;

(* Ask Provider which parts of Messages do not matter, and delete them.

   Returns the pruned history, or Messages verbatim when anything at
   all goes wrong -- no provider, no candidates, a failed call, an
   unparseable plan, a plan that names nothing. Info reports what
   happened either way.

   Model overrides Opts.Model when Opts.Model is empty; the caller
   passes its own model as the fallback. *)
function PruneMessages(Provider: ILLMProvider; const Model: string;
                       const Messages: array of TMessage;
                       const Opts: TPruneOptions;
                       out Info: TPruneResult): TMessageArray;

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Tokenizer,
  PasClaw.Logger;

type
  { One prunable unit. A plain message is a group of one; an assistant
    turn with tool_calls owns every tool result that answers it. }
  TPruneGroup = record
    First, Last: Integer;   { inclusive indices into the body }
    Tokens:      Integer;
    Role:        string;    { for the prompt: what kind of thing this is }
    Names:       string;    { tool names in the group, when any }
    Preview:     string;
    Candidate:   Boolean;
  end;
  TPruneGroups = array of TPruneGroup;

function DefaultPruneOptions: TPruneOptions;
begin
  Result.Enabled            := False;
  Result.ThresholdTokens    := 60000;
  Result.ProtectTailTokens  := 20000;
  Result.MinCandidateTokens := 400;
  Result.PreviewChars       := 400;
  Result.Model              := '';
  Result.OnBefore           := nil;
end;

function NeedsPrune(const Messages: array of TMessage;
                    const SystemPrompt: string;
                    Threshold: Integer): Boolean;
var
  i, Total: Integer;
begin
  Result := False;
  if Threshold <= 0 then Exit;
  Total := EstimateTokens(SystemPrompt);
  if Total >= Threshold then Exit(True);
  for i := 0 to High(Messages) do
  begin
    Total := Total + EstimateTokens(Messages[i].Content) + 4;
    if Total >= Threshold then Exit(True);
  end;
end;

function TotalTokens(const Messages: array of TMessage): Integer;
var
  i: Integer;
begin
  Result := 0;
  for i := 0 to High(Messages) do
    Result := Result + EstimateTokens(Messages[i].Content) + 4;
end;

function ReturnVerbatim(const Messages: array of TMessage): TMessageArray;
var
  i: Integer;
begin
  SetLength(Result, Length(Messages));
  for i := 0 to High(Messages) do Result[i] := Messages[i];
end;

{ Head + tail of S, with the middle replaced by a count. Enough to tell
  a build log from a decision without shipping the log. }
function Preview(const S: string; Chars: Integer): string;
begin
  if Chars < 40 then Chars := 40;
  if Length(S) <= Chars * 2 then Exit(S);
  Result := Copy(S, 1, Chars) +
            sLineBreak + '... [' +
            IntToStr(Length(S) - Chars * 2) + ' characters omitted] ...' +
            sLineBreak +
            Copy(S, Length(S) - Chars + 1, Chars);
end;

function RoleName(R: TMsgRole): string;
begin
  case R of
    mrSystem:    Result := 'system';
    mrUser:      Result := 'user';
    mrAssistant: Result := 'assistant';
    mrTool:      Result := 'tool result';
  else           Result := 'message';
  end;
end;

(* Cut the history into prunable groups.

   LeadCount leading system messages are excluded outright. So is the
   newest ProtectTailTokens' worth: walked from the end, so the cut
   lands on whole groups rather than inside one. *)
function BuildGroups(const Body: array of TMessage;
                     const Opts: TPruneOptions): TPruneGroups;
var
  i, k, c, N, Tail, G: Integer;
  Names: string;
begin
  SetLength(Result, 0);
  i := 0;
  while i <= High(Body) do
  begin
    N := Length(Result);
    SetLength(Result, N + 1);
    Result[N].First := i;
    Result[N].Last  := i;
    Result[N].Role  := RoleName(Body[i].Role);
    Result[N].Names := '';
    { An assistant turn with tool_calls owns the tool results that
      follow it -- they are one decision or the group is broken. }
    if (Body[i].Role = mrAssistant) and (Length(Body[i].ToolCalls) > 0) then
    begin
      Names := '';
      for k := 0 to High(Body[i].ToolCalls) do
      begin
        if Names <> '' then Names := Names + ', ';
        Names := Names + Body[i].ToolCalls[k].Func.Name;
      end;
      Result[N].Names := Names;
      Result[N].Role  := 'assistant tool call';
      while (Result[N].Last + 1 <= High(Body)) and
            (Body[Result[N].Last + 1].Role = mrTool) do
        Inc(Result[N].Last);
    end;
    i := Result[N].Last + 1;
  end;

  (* Sizes and previews.

     The ARGUMENTS count and are shown, not just Content. An assistant
     tool-call turn usually has little or no text of its own -- the
     information is in write_file({"path":"...","content":...}) or
     shell_exec({"command":"..."}), and the result answering it is
     often just "ok". Judging that group on Content alone, the pruner
     sees a near-empty turn followed by a success and calls it
     disposable, deleting the only record of which file was changed and
     with what -- which the end-of-turn working-state scan cannot
     recover either, because it reads the same messages. Bounded like
     every other preview, so a 200 KB write does not arrive whole. *)
  for G := 0 to High(Result) do
  begin
    Result[G].Tokens := 0;
    Result[G].Preview := '';
    for k := Result[G].First to Result[G].Last do
    begin
      Result[G].Tokens := Result[G].Tokens + EstimateTokens(Body[k].Content) + 4;
      if Result[G].Preview <> '' then
        Result[G].Preview := Result[G].Preview + sLineBreak;
      Result[G].Preview := Result[G].Preview +
        Preview(Trim(Body[k].Content), Opts.PreviewChars);
      for c := 0 to High(Body[k].ToolCalls) do
      begin
        Result[G].Tokens := Result[G].Tokens +
          EstimateTokens(Body[k].ToolCalls[c].Func.Arguments);
        Result[G].Preview := Result[G].Preview + sLineBreak +
          Body[k].ToolCalls[c].Func.Name + '(' +
          Preview(Trim(Body[k].ToolCalls[c].Func.Arguments),
                  Opts.PreviewChars) + ')';
      end;
    end;
    Result[G].Candidate := Result[G].Tokens >= Opts.MinCandidateTokens;
  end;

  (* The protected window, walked newest-first.

     Marked BEFORE the budget is tested, which is the whole subtlety:
     testing first meant a single group larger than ProtectTailTokens
     -- a pasted 25k-token request against a 20k window -- broke the
     loop on its first pass and left the window EMPTY, so the current
     task became a pruning candidate. The tail budget is a floor for
     how much to protect, never a licence to protect nothing; the
     newest group is always protected, however big it is. *)
  Tail := 0;
  for G := High(Result) downto 0 do
  begin
    Result[G].Candidate := False;
    Tail := Tail + Result[G].Tokens;
    if Tail >= Opts.ProtectTailTokens then Break;
  end;
end;

function BuildPrunePrompt(const Groups: TPruneGroups): string;
var
  G: Integer;
  Lines: string;
begin
  Lines := '';
  for G := 0 to High(Groups) do
  begin
    if not Groups[G].Candidate then Continue;
    Lines := Lines + '--- id ' + IntToStr(G) +
             ' | ' + Groups[G].Role;
    if Groups[G].Names <> '' then Lines := Lines + ' | ' + Groups[G].Names;
    Lines := Lines + ' | ~' + IntToStr(Groups[G].Tokens) + ' tokens ---' +
             sLineBreak + Groups[G].Preview + sLineBreak + sLineBreak;
  end;
  Result :=
    'You are pruning an AI agent''s conversation so it fits its context ' +
    'window. Below are numbered excerpts from the MIDDLE of that ' +
    'conversation, each shown as its head and tail. Decide which ones ' +
    'the agent no longer needs.' + sLineBreak + sLineBreak +
    'DELETE (action "drop") things whose content no longer carries ' +
    'information: bulk command output, build and test logs, HTML or ' +
    'JSON dumps, directory listings, a file read that a later edit has ' +
    'superseded, an exploratory branch that was abandoned, repeated ' +
    'restatements.' + sLineBreak +
    'SHORTEN (action "marker", with a one-line "text") when the OUTCOME ' +
    'matters but the volume does not -- a test run reduces to ' +
    '"[tests: 412 passed, 0 failed]", a long build to "[build ok]". ' +
    'Write what the agent would need to remember.' + sLineBreak +
    'KEEP (say nothing at all) anything carrying decisions, ' +
    'constraints, identifiers, file paths, error messages, unresolved ' +
    'questions, or the user''s own words. When unsure, KEEP.' +
    sLineBreak + sLineBreak +
    'Answer with JSON only, no prose, no code fence:' + sLineBreak +
    '{"decisions":[{"id":0,"action":"drop"},' +
    '{"id":3,"action":"marker","text":"[tests: 412 passed]"}]}' +
    sLineBreak +
    'Ids you omit are KEPT. Omitting everything is a valid answer.' +
    sLineBreak + sLineBreak +
    '--- excerpts ---' + sLineBreak + sLineBreak + Lines;
end;

{ The model's JSON, however it chose to wrap it. A fenced block or a
  sentence in front is common enough to be worth surviving; anything
  else parses to nothing, which prunes nothing. }
function ExtractJSONObject(const S: string): string;
var
  P, Depth, i: Integer;
  InStr, Esc: Boolean;
begin
  Result := '';
  P := Pos('{', S);
  if P = 0 then Exit;
  Depth := 0; InStr := False; Esc := False;
  for i := P to Length(S) do
  begin
    if InStr then
    begin
      if Esc then Esc := False
      else if S[i] = '\' then Esc := True
      else if S[i] = '"' then InStr := False;
      Continue;
    end;
    if S[i] = '"' then InStr := True
    else if S[i] = '{' then Inc(Depth)
    else if S[i] = '}' then
    begin
      Dec(Depth);
      if Depth = 0 then Exit(Copy(S, P, i - P + 1));
    end;
  end;
end;

function PruneMessages(Provider: ILLMProvider; const Model: string;
                       const Messages: array of TMessage;
                       const Opts: TPruneOptions;
                       out Info: TPruneResult): TMessageArray;
var
  LeadCount, i, k, G, Id, Cands, OutIdx: Integer;
  Body: TMessageArray;
  Groups: TPruneGroups;
  Actions: array of string;      { per group: '', 'drop', 'marker' }
  Markers: array of string;
  Keep: array of Boolean;        { per body index }
  OneCall: array of TMessage;
  EmptyTools: array of TToolDefinition;
  CallOptions: TChatOptions;
  Resp: TLLMResponse;
  UseModel, Raw, Act: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
begin
  Info := Default(TPruneResult);
  Info.TokensBefore := TotalTokens(Messages);
  Info.TokensAfter  := Info.TokensBefore;

  if Provider = nil then Exit(ReturnVerbatim(Messages));

  { Leading system messages are the agent's identity and policy. They
    are not offered, so they cannot be pruned by accident. }
  LeadCount := 0;
  while (LeadCount < Length(Messages)) and
        (Messages[LeadCount].Role = mrSystem) do
    Inc(LeadCount);
  SetLength(Body, Length(Messages) - LeadCount);
  for i := 0 to High(Body) do Body[i] := Messages[LeadCount + i];
  if Length(Body) = 0 then Exit(ReturnVerbatim(Messages));

  Groups := BuildGroups(Body, Opts);
  Cands := 0;
  for G := 0 to High(Groups) do
    if Groups[G].Candidate then Inc(Cands);
  Info.Considered := Cands;
  if Cands = 0 then
  begin
    LogDebug('prune: nothing outside the protected tail is big enough ' +
             'to be worth a decision', []);
    Exit(ReturnVerbatim(Messages));
  end;

  UseModel := Opts.Model;
  if UseModel = '' then UseModel := Model;

  SetLength(OneCall, 1);
  OneCall[0] := MakeMessage(mrUser, BuildPrunePrompt(Groups));
  CallOptions := DefaultChatOptions;
  { A plan is short. The cap is generous enough for one decision per
    candidate and no more. }
  CallOptions.MaxTokens := 1024 + Cands * 64;
  SetLength(EmptyTools, 0);
  try
    Resp := Provider.Chat(OneCall, EmptyTools, UseModel, CallOptions);
  except
    on E: Exception do
    begin
      LogWarn('prune: pruner call raised %s: %s -- keeping everything',
              [E.ClassName, E.Message]);
      Exit(ReturnVerbatim(Messages));
    end;
  end;

  Raw := ExtractJSONObject(Resp.Content);
  if Trim(Raw) = '' then
  begin
    LogWarn('prune: pruner returned no JSON -- keeping everything', []);
    Exit(ReturnVerbatim(Messages));
  end;

  SetLength(Actions, Length(Groups));
  SetLength(Markers, Length(Groups));
  Root := TJsonObject.Parse(Raw);
  if Root = nil then
  begin
    LogWarn('prune: pruner JSON did not parse -- keeping everything', []);
    Exit(ReturnVerbatim(Messages));
  end;
  try
    Arr := Root.ChildArray('decisions');
    if Arr = nil then
    begin
      LogWarn('prune: pruner JSON had no decisions array -- keeping ' +
              'everything', []);
      Exit(ReturnVerbatim(Messages));
    end;
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        Id := Integer(Item.GetInt('id', -1));
        { An id outside the offered set is a hallucination, not an
          instruction. Protected and non-candidate groups are refused
          here too, so naming one has no effect. }
        if (Id < 0) or (Id > High(Groups)) then Continue;
        if not Groups[Id].Candidate then Continue;
        Act := LowerCase(Trim(Item.GetStr('action', '')));
        if Act = 'drop' then Actions[Id] := 'drop'
        else if Act = 'marker' then
        begin
          Markers[Id] := Trim(Item.GetStr('text', ''));
          if Markers[Id] = '' then
            Markers[Id] := '[omitted]';
          Actions[Id] := 'marker';
        end;
        { Any other action is not one we offered -- keep. }
      end;
    finally
      Arr.Free;
    end;
  finally
    Root.Free;
  end;

  { Apply. Whole groups, so a tool result can never lose its call. }
  SetLength(Keep, Length(Body));
  for i := 0 to High(Keep) do Keep[i] := True;
  for G := 0 to High(Groups) do
  begin
    if Actions[G] = 'drop' then
    begin
      for k := Groups[G].First to Groups[G].Last do
      begin
        Keep[k] := False;
        Inc(Info.Dropped);
      end;
    end
    else if Actions[G] = 'marker' then
    begin
      for k := Groups[G].First to Groups[G].Last do
      begin
        { The assistant's own turn keeps its text and its tool_calls --
          replacing those would break the pairing the group exists to
          protect. The bulk is in the results, and that is what the
          marker stands in for. }
        if (Body[k].Role = mrAssistant) and (Length(Body[k].ToolCalls) > 0) then
          Continue;
        if EstimateTokens(Body[k].Content) + 4 < Opts.MinCandidateTokens then
          Continue;
        Body[k].Content := Markers[G];
        Inc(Info.Marked);
      end;
    end;
  end;

  if (Info.Dropped = 0) and (Info.Marked = 0) then
  begin
    LogDebug('prune: %d candidate(s) offered, none pruned', [Cands]);
    Exit(ReturnVerbatim(Messages));
  end;

  { Something IS about to be deleted -- last chance to keep a copy.
    Fired here rather than before the pruner call so a pass that
    decides to prune nothing costs no archive, and wrapped because a
    failed archive must not fail the turn. }
  if Assigned(Opts.OnBefore) then
  try
    Opts.OnBefore(Messages);
  except
    on E: Exception do
      LogWarn('prune: OnBefore raised %s: %s -- continuing',
              [E.ClassName, E.Message]);
  end;

  SetLength(Result, Length(Messages));
  OutIdx := 0;
  for i := 0 to LeadCount - 1 do
  begin
    Result[OutIdx] := Messages[i];
    Inc(OutIdx);
  end;
  for i := 0 to High(Body) do
    if Keep[i] then
    begin
      Result[OutIdx] := Body[i];
      Inc(OutIdx);
    end;
  SetLength(Result, OutIdx);

  (* A prune that empties the history is not a prune, it is a wipe.

     The protected tail already makes this unreachable -- the newest
     group is never a candidate -- but "unreachable" is a property of
     today's cut logic, and this is the one failure the caller could
     not recover from: an empty Messages array is not a conversation
     the next turn can continue. Cheap to assert, so assert it. *)
  if Length(Result) = 0 then
  begin
    LogWarn('prune: plan would have emptied the history -- refused, ' +
            'keeping everything', []);
    Exit(ReturnVerbatim(Messages));
  end;

  Info.TokensAfter := TotalTokens(Result);
  LogInfo('prune: %d candidate(s) -> %d msg(s) dropped, %d marked; ' +
          '~%d -> ~%d tokens',
          [Cands, Info.Dropped, Info.Marked,
           Info.TokensBefore, Info.TokensAfter]);
end;

end.
