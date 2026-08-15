program prune_tests;
(*
  Pins PasClaw.Agent.Prune: LLM-guided deletion of context that no
  longer matters.

  Pruning deletes from the MIDDLE of a live history, which makes it far
  less forgiving than compaction -- compaction's mistakes cost detail,
  pruning's mistakes cost a 400 from the provider or the loss of the
  thing the turn was about. So the properties worth breaking the build
  over are the guarantees the model is NOT trusted to honour:

    1. Omitted = kept. A truncated, empty, garbled or hallucinating
       reply must prune nothing. The prompt asks for decisions; the
       default has to be inaction.
    2. Tool groups are atomic. Dropping an assistant turn's tool_calls
       without its tool results (or the reverse) is an orphaned
       tool_use -- Anthropic and OpenAI both 400 on it.
    3. Leading system messages and the recent window are never
       candidates, whatever the plan says about them.
    4. A marker keeps the MESSAGE -- and its tool_call_id -- and
       replaces only its content, so the pairing survives.
    5. Survivors are verbatim. That is the whole reason to prune
       instead of summarise, and a byte-for-byte assertion is the only
       way to keep it true.
*)
{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

uses
  SysUtils,
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Agent.Prune,
  PasClaw.Session.Store,
  PasClaw.Utils,
  PasClaw.Config;

var Failures: Integer = 0;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Inc(Failures);
end;

procedure ExpectTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure ExpectEq(Got, Want: Integer; const Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' -- got ' + IntToStr(Got) + ', want ' + IntToStr(Want));
end;

type
  { Answers every call with a canned plan, and remembers what it saw. }
  TStubProvider = class(TInterfacedObject, ILLMProvider)
  public
    Reply:      string;
    RaiseIt:    Boolean;
    Calls:      Integer;
    LastPrompt: string;
    function Chat(const Messages: array of TMessage;
                  const Tools:    array of TToolDefinition;
                  const Model:    string;
                  const Options:  TChatOptions): TLLMResponse;
    function GetDefaultModel: string;
    function GetName: string;
    function SupportsThinking: Boolean;
    function SupportsNativeSearch: Boolean;
    function SupportsStreaming: Boolean;
    function ChatStream(const Messages: array of TMessage;
                        const Tools:    array of TToolDefinition;
                        const Model:    string;
                        const Options:  TChatOptions;
                        OnChunk: TStreamCallback): TLLMResponse;
  end;

var
  LastModel: string;
  { Counts OnBefore firings, so "fired only when something is actually
    deleted" is assertable rather than assumed. }
  BeforeCalls: Integer = 0;

type
  TArchiveSpy = class
    procedure OnBefore(const Messages: array of TMessage);
  end;

procedure TArchiveSpy.OnBefore(const Messages: array of TMessage);
begin
  Inc(BeforeCalls);
end;

function TStubProvider.Chat(const Messages: array of TMessage;
                            const Tools: array of TToolDefinition;
                            const Model: string;
                            const Options: TChatOptions): TLLMResponse;
begin
  Inc(Calls);
  LastModel := Model;
  if Length(Messages) > 0 then LastPrompt := Messages[0].Content
  else LastPrompt := '';
  if RaiseIt then raise Exception.Create('stub says no');
  Result := Default(TLLMResponse);
  Result.Content := Reply;
  Result.StatusCode := 200;
end;

function TStubProvider.GetDefaultModel: string; begin Result := 'stub-1'; end;
function TStubProvider.GetName: string;         begin Result := 'stub';   end;
function TStubProvider.SupportsThinking: Boolean;     begin Result := False; end;
function TStubProvider.SupportsNativeSearch: Boolean; begin Result := False; end;
function TStubProvider.SupportsStreaming: Boolean;    begin Result := False; end;

function TStubProvider.ChatStream(const Messages: array of TMessage;
                                  const Tools: array of TToolDefinition;
                                  const Model: string;
                                  const Options: TChatOptions;
                                  OnChunk: TStreamCallback): TLLMResponse;
begin
  Result := Chat(Messages, Tools, Model, Options);
end;

{ Big enough to be a candidate: ~Chars/4 tokens. }
function Fat(Role: TMsgRole; const Tag: string; Chars: Integer): TMessage;
begin
  Result := MakeMessage(Role, Tag + ' ' + StringOfChar('x', Chars));
end;

{ An assistant turn carrying one tool_call, plus its result. }
function CallTurn(const Id, Name: string): TMessage;
begin
  Result := MakeMessage(mrAssistant, 'calling ' + Name);
  SetLength(Result.ToolCalls, 1);
  Result.ToolCalls[0].Id := Id;
  Result.ToolCalls[0].Kind := 'function';
  Result.ToolCalls[0].Func.Name := Name;
  Result.ToolCalls[0].Func.Arguments := '{}';
end;

function ResultTurn(const Id: string; Chars: Integer): TMessage;
begin
  Result := Fat(mrTool, 'OUTPUT', Chars);
  Result.ToolCallId := Id;
end;

function CountRole(const A: TMessageArray; R: TMsgRole): Integer;
var i: Integer;
begin
  Result := 0;
  for i := 0 to High(A) do if A[i].Role = R then Inc(Result);
end;

{ Every tool result has the assistant tool_call it answers, somewhere
  earlier. The invariant a bad prune breaks, and a 400 when it does. }
function NoOrphanedResults(const A: TMessageArray): Boolean;
var
  i, j, k: Integer;
  Found: Boolean;
begin
  Result := True;
  for i := 0 to High(A) do
  begin
    if A[i].Role <> mrTool then Continue;
    if A[i].ToolCallId = '' then Continue;
    Found := False;
    for j := 0 to i - 1 do
      for k := 0 to High(A[j].ToolCalls) do
        if A[j].ToolCalls[k].Id = A[i].ToolCallId then Found := True;
    if not Found then Exit(False);
  end;
end;

var
  Stub:     TStubProvider;
  Provider: ILLMProvider;
  Opts:     TPruneOptions;
  Info:     TPruneResult;
  Msgs, Out_: TMessageArray;
  Cfg:      TConfig;
  Def:      TPruneOptions;
  i:        Integer;
  Big:      string;
  Spy:      TArchiveSpy;
  SessDir, SessId: string;
  Metas:    TSessionMetaArray;
  Ghost:    Boolean;
  Sess:     TSession;

(* A history with something worth pruning: the original task, two tool
   groups with fat results, then the recent turn. Group ids as the
   pruner sees them -- 0 the task, 1 the first tool group, 2 the second,
   3 the recent turn. Rebuilt before each case so one case's deletions
   cannot quietly become the next case's premise. *)
procedure BuildHistory;
begin
  SetLength(Msgs, 6);
  Msgs[0] := Fat(mrUser, 'ORIGINAL-TASK', 800);
  Msgs[1] := CallTurn('call-1', 'shell_exec');
  Msgs[2] := ResultTurn('call-1', 4000);
  Msgs[3] := CallTurn('call-2', 'fs_read');
  Msgs[4] := ResultTurn('call-2', 4000);
  Msgs[5] := Fat(mrUser, 'RECENT', 800);
end;

begin
  { ---------------------------------------------------- the trigger -- }
  SetLength(Msgs, 2);
  Msgs[0] := Fat(mrUser, 'A', 40);
  Msgs[1] := Fat(mrAssistant, 'B', 40);
  ExpectTrue(not NeedsPrune(Msgs, '', 100000), 'a small history is left alone');
  ExpectTrue(NeedsPrune(Msgs, '', 10), 'a large one trips the threshold');
  ExpectTrue(NeedsPrune(Msgs, StringOfChar('s', 8000), 1000),
             'the system prompt counts, as it does for compaction');
  ExpectTrue(not NeedsPrune(Msgs, StringOfChar('s', 8000), 0),
             'threshold 0 disables pruning entirely');

  Stub := TStubProvider.Create;
  Provider := Stub;
  Opts := DefaultPruneOptions;
  Opts.ProtectTailTokens  := 1;      { protect almost nothing, so the }
  Opts.MinCandidateTokens := 100;    { assertions are about the plan  }

  { ------------------------------------------- omitted means KEPT -- }
  BuildHistory;
  Stub.Reply := '{"decisions":[]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'an empty plan prunes nothing');
  ExpectEq(Info.Dropped, 0, 'and drops nothing');

  BuildHistory;
  Stub.Reply := 'I had a look and decided not to answer in JSON.';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'prose instead of a plan prunes nothing');

  BuildHistory;
  Stub.Reply := '{"decisions":[{"id":1,"action":"dr';   { truncated }
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'a truncated plan prunes nothing');

  BuildHistory;
  Stub.Reply := '{"decisions":[{"id":99,"action":"drop"},' +
                '{"id":-3,"action":"drop"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'ids that were never offered are ignored');

  BuildHistory;
  Stub.RaiseIt := True;
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'a pruner that raises prunes nothing');
  Stub.RaiseIt := False;

  Out_ := PruneMessages(nil, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'no provider prunes nothing');

  { ------------------------------------------ tool groups are atomic }
  BuildHistory;
  Stub.Reply := '{"decisions":[{"id":1,"action":"drop"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 4,
           'dropping a tool group takes the call AND its result');
  ExpectTrue(NoOrphanedResults(Out_),
             'no tool result is left without the call it answers');
  ExpectEq(CountRole(Out_, mrTool), 1, 'the other group is untouched');

  { ------------------------------------ the fenced-JSON reply, too -- }
  BuildHistory;
  Stub.Reply := 'Sure, here you go:' + sLineBreak + '```json' + sLineBreak +
                '{"decisions":[{"id":1,"action":"drop"}]}' + sLineBreak +
                '```';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 4, 'a plan wrapped in prose and a fence still applies');

  { ------------------------------------------------ markers ---------- }
  BuildHistory;
  Stub.Reply := '{"decisions":[{"id":1,"action":"marker",' +
                '"text":"[shell: ok]"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'a marker keeps every message');
  ExpectTrue(NoOrphanedResults(Out_), 'and every pairing');
  ExpectTrue(Out_[2].Content = '[shell: ok]',
             'the fat result is replaced by the marker');
  ExpectTrue(Out_[2].ToolCallId = 'call-1',
             'and keeps its tool_call_id -- the pairing is the point');
  ExpectTrue(Pos('calling shell_exec', Out_[1].Content) > 0,
             'the assistant turn keeps its own text');
  ExpectTrue(Length(Out_[1].ToolCalls) = 1,
             'and its tool_calls, which a marker must never eat');

  { ------------------------------------- survivors are VERBATIM ------ }
  BuildHistory;
  Big := Msgs[0].Content;
  Stub.Reply := '{"decisions":[{"id":1,"action":"drop"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectTrue(Out_[0].Content = Big,
             'a surviving message is byte-for-byte what it was -- the ' +
             'whole reason to prune rather than summarise');

  { --------------------------- system messages are never candidates -- }
  BuildHistory;
  SetLength(Msgs, 7);
  for i := 6 downto 1 do Msgs[i] := Msgs[i - 1];
  Msgs[0] := Fat(mrSystem, 'POLICY-NEVER-DELETE', 2000);
  Stub.Reply := '{"decisions":[{"id":0,"action":"drop"},' +
                '{"id":1,"action":"drop"},{"id":2,"action":"drop"},' +
                '{"id":3,"action":"drop"},{"id":4,"action":"drop"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectTrue(Out_[0].Role = mrSystem, 'the system message survives...');
  ExpectTrue(Pos('POLICY-NEVER-DELETE', Out_[0].Content) > 0,
             '...intact, however enthusiastically the plan asked');
  ExpectTrue(NoOrphanedResults(Out_),
             'and a delete-everything plan still leaves no orphans');
  ExpectTrue(Pos('POLICY-NEVER-DELETE', Stub.LastPrompt) = 0,
             'the pruner is never even shown it');

  { -------------------------------- the recent window is protected -- }
  BuildHistory;
  Opts.ProtectTailTokens := 100000;   { everything is recent }
  Stub.Calls := 0;
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectEq(Length(Out_), 6, 'nothing outside the recent window, nothing pruned');
  ExpectEq(Stub.Calls, 0,
           'and no pruner call is spent finding that out');
  Opts.ProtectTailTokens := 1;

  { ------------------------- the pruner sees previews, not the log --- }
  BuildHistory;
  Opts.PreviewChars := 60;
  Stub.Reply := '{"decisions":[]}';
  PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectTrue(Length(Stub.LastPrompt) < 6000,
             'the prompt is previews, not the transcript -- otherwise ' +
             'the pruner call grows with the history it exists to shrink');
  ExpectTrue(Pos('characters omitted', Stub.LastPrompt) > 0,
             'and says where it elided');
  Opts.PreviewChars := 400;

  { ------------------------------ the model, and the config defaults - }
  BuildHistory;
  Opts.Model := 'the-plan-model';
  Stub.Reply := '{"decisions":[]}';
  PruneMessages(Provider, 'caller-model', Msgs, Opts, Info);
  ExpectTrue(LastModel = 'the-plan-model',
             'Opts.Model wins -- pruning runs on the plan model');
  Opts.Model := '';
  PruneMessages(Provider, 'caller-model', Msgs, Opts, Info);
  ExpectTrue(LastModel = 'caller-model',
             'and falls back to the caller''s when unset');

  (* -------- one oversized newest group cannot empty the window ------

     The tail budget says how much recent history to protect, and a
     single group bigger than the whole budget used to satisfy it by
     protecting NOTHING -- so a pasted 25k-token request against a 20k
     window made the current task itself a pruning candidate. The
     newest group is protected whatever it weighs. *)
  SetLength(Msgs, 3);
  Msgs[0] := Fat(mrUser, 'OLD-TASK', 4000);
  Msgs[1] := Fat(mrAssistant, 'OLD-REPLY', 4000);
  Msgs[2] := Fat(mrUser, 'CURRENT-TASK-PASTED-HUGE', 40000);
  Opts.ProtectTailTokens := 2000;    { far smaller than that last turn }
  Stub.Reply := '{"decisions":[{"id":0,"action":"drop"},' +
                '{"id":1,"action":"drop"},{"id":2,"action":"drop"}]}';
  Out_ := PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectTrue(Pos('CURRENT-TASK-PASTED-HUGE', Out_[High(Out_)].Content) > 0,
             'the newest turn survives even when it alone is bigger than ' +
             'the whole protected-tail budget');
  ExpectTrue(Pos('CURRENT-TASK-PASTED-HUGE', Stub.LastPrompt) = 0,
             'and is never offered to the pruner in the first place');
  Opts.ProtectTailTokens := 1;

  (* ---------- tool-call ARGUMENTS reach the deciding model ---------

     An assistant tool-call turn carries its information in the
     arguments, not in Content: write_file({"path":...}) then a
     one-word success. Judged on Content alone the group reads as
     empty-then-ok, and deleting it destroys the only record of what
     was changed. *)
  SetLength(Msgs, 4);
  Msgs[0] := Fat(mrUser, 'TASK', 800);
  Msgs[1] := MakeMessage(mrAssistant, '');        { no text of its own }
  SetLength(Msgs[1].ToolCalls, 1);
  Msgs[1].ToolCalls[0].Id := 'w1';
  Msgs[1].ToolCalls[0].Kind := 'function';
  Msgs[1].ToolCalls[0].Func.Name := 'write_file';
  Msgs[1].ToolCalls[0].Func.Arguments :=
    '{"path":"src/important.pas","content":"' + StringOfChar('c', 2000) + '"}';
  Msgs[2] := MakeMessage(mrTool, 'ok');
  Msgs[2].ToolCallId := 'w1';
  Msgs[3] := Fat(mrUser, 'RECENT', 800);
  Stub.Reply := '{"decisions":[]}';
  PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
  ExpectTrue(Pos('src/important.pas', Stub.LastPrompt) > 0,
             'the pruner is shown WHICH file the call wrote -- the group''s ' +
             'only real content lives in its arguments');
  ExpectTrue(Pos('write_file(', Stub.LastPrompt) > 0,
             'attributed to the call that carried it');
  ExpectTrue(Length(Stub.LastPrompt) < 4000,
             'and the argument blob is still bounded, not pasted whole');

  { ------------------------ the archive hook fires only on a deletion - }
  Spy := TArchiveSpy.Create;
  try
    Opts.OnBefore := Spy.OnBefore;

    BuildHistory;
    BeforeCalls := 0;
    Stub.Reply := '{"decisions":[]}';
    PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
    ExpectEq(BeforeCalls, 0,
             'a pass that prunes nothing archives nothing -- the copy is ' +
             'the price of a deletion, not of a decision');

    BuildHistory;
    BeforeCalls := 0;
    Stub.Reply := 'not json at all';
    PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
    ExpectEq(BeforeCalls, 0, 'nor does a failed pass');

    BuildHistory;
    BeforeCalls := 0;
    Stub.Reply := '{"decisions":[{"id":1,"action":"drop"}]}';
    PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
    ExpectEq(BeforeCalls, 1,
             'a pass that deletes fires it exactly once, before deleting');

    BuildHistory;
    BeforeCalls := 0;
    Stub.Reply := '{"decisions":[{"id":1,"action":"marker","text":"[ok]"}]}';
    PruneMessages(Provider, 'stub-1', Msgs, Opts, Info);
    ExpectEq(BeforeCalls, 1,
             'and a marker counts as a deletion -- the original text is ' +
             'just as gone');
  finally
    Opts.OnBefore := nil;
    Spy.Free;
  end;

  (* ---------------- the archive itself, on a real sessions dir ------

     ArchiveSessionOnce is the CLI's OnBefore. What matters is that it
     is ONCE: a copy taken on the second prune is already missing what
     the first one removed, which would be a worse lie than no copy at
     all. *)
  { The Makefile hands this binary a fresh PASCLAW_HOME, so SessionsDir
    resolves under a tempdir and the operator's own sessions are never
    in reach. }
  SessDir := SessionsDir;
  ForceDirectories(SessDir);

  SessId := 'prune-archive-test';
  WriteFileText(JoinPath(SessDir, SessId + '.json'),
                '{"meta":{"id":"' + SessId + '"},' +
                '"messages":[{"role":"user","content":"ORIGINAL"}]}');

  ExpectTrue(not HasSessionArchive(SessId), 'no archive before the first prune');
  ExpectTrue(ArchiveSessionOnce(SessId), 'the first prune archives');
  ExpectTrue(HasSessionArchive(SessId), 'and the archive is there');
  ExpectTrue(Pos('ORIGINAL', ReadFileText(SessionArchivePath(SessId))) > 0,
             'holding the transcript as it was');

  { The live file moves on, as a pruning session does. }
  WriteFileText(JoinPath(SessDir, SessId + '.json'),
                '{"meta":{"id":"' + SessId + '"},"messages":[]}');
  ExpectTrue(not ArchiveSessionOnce(SessId),
             'the second prune does NOT archive again');
  ExpectTrue(Pos('ORIGINAL', ReadFileText(SessionArchivePath(SessId))) > 0,
             'so the archive still holds the ORIGINAL, not the ' +
             'already-pruned version -- the whole point of once');

  ExpectTrue(SessionArchivePath('../etc/passwd') = '',
             'an unsafe id has no archive path, as it has no session path');
  ExpectTrue(not ArchiveSessionOnce('../etc/passwd'),
             'and cannot be archived');

  { An archive must not read as a session of its own. }
  Metas := ListSessions;
  Ghost := False;
  for i := 0 to High(Metas) do
    if Pos('.orig', Metas[i].Id) > 0 then Ghost := True;
  ExpectTrue(not Ghost,
             'the archive is not listed as a session -- "<id>.orig" is a ' +
             'legal session id, so without the filter every pruned ' +
             'session would show up twice');

  (* And hiding it from the LIST is not enough on its own.

     Load / Save / Delete all resolve through SessionPath, and resume
     takes an id the operator typed rather than one the list offered --
     so `pasclaw resume <id>.orig` opened the archive as an ordinary
     session and wrote turns into a file nothing else reads. Refusing
     the id at SessionPath is what makes the archive read-only to
     everything except the export that exists to read it. *)
  ExpectTrue(IsSessionArchiveId(SessId + '.orig'),
             'an .orig id is recognised as an archive');
  ExpectTrue(not IsSessionArchiveId(SessId),
             'and an ordinary id is not');
  ExpectTrue(SessionPath(SessId + '.orig') = '',
             'an archive id has NO session path -- resume, show and ' +
             'delete all resolve through it and must all refuse');
  ExpectTrue(SessionPath(SessId) <> '',
             'while the session it belongs to still resolves');
  ExpectTrue(SessionArchivePath(SessId) <> '',
             'and archiving still works, since it does not go through ' +
             'SessionPath');
  Sess := TSession.Create(SessId + '.orig');
  try
    ExpectTrue(not Sess.MetaExists,
               'opening an archive as a session finds nothing to open');
  finally
    Sess.Free;
  end;

  Cfg := TConfig.Create;
  Def := DefaultPruneOptions;
  ExpectTrue(not Cfg.Prune.Enabled,
             'pruning is OFF by default -- it spends a strong-model call');
  ExpectTrue(not Def.Enabled, 'and the code default agrees');
  ExpectEq(Cfg.Prune.ThresholdTokens,    Def.ThresholdTokens,
           'config threshold default = code default');
  ExpectEq(Cfg.Prune.ProtectTailTokens,  Def.ProtectTailTokens,
           'config protected-tail default = code default');
  ExpectEq(Cfg.Prune.MinCandidateTokens, Def.MinCandidateTokens,
           'config candidate-floor default = code default');
  ExpectEq(Cfg.Prune.PreviewChars,       Def.PreviewChars,
           'config preview default = code default');
  ExpectTrue(Cfg.Prune.MinIterations >= 1,
             'and the not-every-turn gate is at least one iteration');
  Cfg.Free;

  if Failures = 0 then
    WriteLn('prune_tests: OK')
  else
  begin
    WriteLn('prune_tests: ', Failures, ' failure(s)');
    Halt(1);
  end;
end.
