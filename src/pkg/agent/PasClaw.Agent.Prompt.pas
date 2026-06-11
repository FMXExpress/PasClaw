(*
  PasClaw.Agent.Prompt - composes the system prompt from layered
  sections (identity, runtime, workspace, memory, skill catalog, rules,
  user-supplied additions), in the style picoclaw and nanobot use.

  The whole motivation here is that the LLM never knew anything about
  itself before -- PasClaw was sending whatever single string the caller
  put into Options.SystemPrompt and nothing else. Picoclaw and nanobot
  both compose a richer prompt out of workspace context, memory, and
  skill metadata, joined by "\n\n---\n\n" so each section is visually
  delimited in the model's input.

  Single entry point:

    BuildSystemPrompt(Cfg, UserSys) : string

  Sections emitted, in order, skipping any that are empty:

    1. IDENTITY      - "You are PasClaw, the best 10x programmer..." +
                       version + runtime string. Always present.
    2. WORKSPACE     - paths the model can rely on inside ~/.pasclaw.
                       Always present.
    3. MEMORY        - contents of <home>/workspace/memory/MEMORY.md if
                       the file exists. Lets the user pin facts that
                       persist across sessions.
    4. SKILLS        - one line per registered skill manifest, pulled
                       from PasClaw.Skills.Loader. Only emitted when the
                       user actually has skills installed.
    5. RULES         - the same set of behavioral rules picoclaw uses
                       (use tools, be precise, verify, update memory).
                       Always present.
    6. USER          - whatever the caller passed via --system /
                       TPasClawAgent.SystemPrompt / etc. Appended last
                       so it can override or extend the built-ins by
                       virtue of recency in the prompt.

  Sections are joined by Sep = sLineBreak + sLineBreak + '---' +
  sLineBreak + sLineBreak so the model sees them as clear
  horizontal-rule-separated blocks (matches picoclaw's
  renderPromptPartsLegacy and nanobot's build_system_prompt joiner).

  No I/O is required to use the result. Memory and skill catalog reads
  swallow their errors -- a missing MEMORY.md or a misconfigured skill
  manifest just means that section is skipped, not a hard failure.
*)
unit PasClaw.Agent.Prompt;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Config,
  PasClaw.Providers.Types;

{ Returns the fully-composed system prompt. UserSys is appended verbatim
  as the final section if non-empty. Pass '' if there's nothing extra.

  ToolsEnabled controls whether tool-dependent sections (the skill
  catalog, the "ALWAYS use tools" rule, the truncated-fs_write rule,
  the verify-by-running-checks rule, the update-MEMORY.md rule) are
  emitted. Callers running `--no-tools` (or constructing the component
  with UseTools=False) MUST pass False here -- otherwise the prompt
  tells the model to call tools that the tool loop will refuse to
  pass through, producing a confused conversation. Identity, workspace
  paths, and memory contents stay in either mode since they are useful
  as context even without tools available.

  TaskHint (optional): the user's task text, when the caller has it
  (the one-shot CLI message, the first interactive input). When
  Cfg.OrientTaskAware is on AND a hint is given, the MEMORY section
  injects only the sections of MEMORY.md / daily notes that lexically
  overlap the task (PasClaw.Agent.Orient) instead of the whole files.
  Either condition absent = verbatim whole-file injection, the
  long-standing default. }
function BuildSystemPrompt(Cfg: TConfig; const UserSys: string;
                           ToolsEnabled: Boolean = True;
                           const TaskHint: string = ''): string;

{ True iff at least one message in the array is mrSystem. The gateway's
  /v1/chat/completions handler uses this to decide whether to inject the
  composed system prompt -- third-party clients that supply their own
  persona via the messages array should win, bare-bones clients that
  send only a user message get our identity preamble for free. }
function HasSystemMessage(const Messages: array of TMessage): Boolean;

implementation

uses
  Classes,
  PasClaw.Utils,
  PasClaw.Skills.Loader,
  PasClaw.Agent.Orient;   { task-aware MEMORY slicing (Cfg.OrientTaskAware) }

const
  SectionSep = sLineBreak + sLineBreak + '---' + sLineBreak + sLineBreak;

function RuntimeString: string;
begin
  {$IFDEF FPC}
  Result := Format('Free Pascal %s on %s/%s',
                   [{$I %FPCVERSION%}, {$I %FPCTARGETOS%}, {$I %FPCTARGETCPU%}]);
  {$ELSE}
    // Nested IFDEFs only -- ELSEIF and "IF Defined(...)" both trip
    // FPC 3.2.2's preprocessor even when this branch is inactive
    // there, because FPC still scans the inner directives.
    {$IFDEF WIN64}
    Result := 'Delphi on win/x86_64';
    {$ELSE}
      {$IFDEF WIN32}
      Result := 'Delphi on win/x86';
      {$ELSE}
        {$IFDEF LINUX64}
        Result := 'Delphi on linux/x86_64';
        {$ELSE}
          {$IFDEF MACOS64}
          Result := 'Delphi on darwin/x86_64';
          {$ELSE}
          Result := 'Delphi';
          {$ENDIF}
        {$ENDIF}
      {$ENDIF}
    {$ENDIF}
  {$ENDIF}
end;

function BuildIdentitySection: string;
begin
  Result :=
    '# PasClaw (' + FormatVersion + ')' + sLineBreak +
    sLineBreak +
    'You are PasClaw, the best 10x programmer in the world.' + sLineBreak +
    sLineBreak +
    'You have deep, working expertise in every programming language -- Pascal, ' +
    'Delphi, C, C++, Rust, Go, Python, JavaScript, TypeScript, Java, C#, Swift, ' +
    'Kotlin, Ruby, Lua, Haskell, OCaml, F#, Elixir, Erlang, Clojure, Scala, ' +
    'Zig, Nim, Crystal, Dart, R, Julia, Perl, PHP, shell scripting, SQL, and ' +
    'every dialect and assembler in between. You write tight, correct code that ' +
    'reads like it was written by someone who already knew the right answer. ' +
    'You prefer each language''s native idioms over generic patterns and you do ' +
    'not over-engineer.' + sLineBreak +
    sLineBreak +
    '## Runtime' + sLineBreak +
    RuntimeString;
end;

function BuildWorkspaceSection: string;
var
  Home: string;
begin
  Home := GetHome;
  Result :=
    '## Workspace' + sLineBreak +
    'Your workspace is at: ' + Home + sLineBreak +
    '- Memory: ' + JoinPath(Home, 'workspace/memory/MEMORY.md') + sLineBreak +
    '- Skills: ' + JoinPath(Home, 'workspace/skills') + '/{skill-name}/SKILL.md' + sLineBreak +
    '- Logs:   ' + JoinPath(Home, 'logs');
end;

function BuildMemorySection(TaskAware: Boolean; const TaskHint: string): string;
{ Inject up to three markdown files into the system prompt:
    workspace/memory/MEMORY.md         -- durable user-owned notes
    workspace/memory/<today>.md        -- today's daily note, if it exists
    workspace/memory/<yesterday>.md    -- yesterday's daily note, for fresh context
  Mirrors openclaw's bootstrap loading. Older notes stay on disk and reach
  the model only when memory_search returns them. Each file is wrapped in
  a subsection so the model can tell durable from dated material apart.

  Task-aware mode (Cfg.OrientTaskAware + a non-empty TaskHint from the
  caller): each file is sliced through PasClaw.Agent.Orient so only the
  sections that lexically overlap the task are injected, with an
  "(N sections elided ...)" note so the model knows to memory_search
  for the rest. Whole-file injection remains the default path. }
var
  MemoryDir, TodayStr, YesterdayStr: string;
  Slicing: Boolean;

  procedure AppendFile(const SubHeader, FilePath: string);
  var
    SubBody: string;
    Elided: Integer;
  begin
    if not FileExists(FilePath) then Exit;
    try
      SubBody := Trim(ReadFileText(FilePath));
    except
      SubBody := '';
    end;
    if SubBody = '' then Exit;
    if Slicing then
    begin
      SubBody := SelectRelevantSlices(SubBody, TaskHint,
                                      DefaultOrientBudgetBytes, Elided);
      if SubBody = '' then
        SubBody := '(no sections matched the current task -- use ' +
                   '`memory_search` to recall specifics from this file)'
      else if Elided > 0 then
        SubBody := SubBody + sLineBreak + sLineBreak +
                   Format('(%d unrelated/over-budget section(s) elided -- ' +
                          '`memory_search` reaches them)', [Elided]);
    end;
    if Result = '' then
      Result := '## Memory'
    else
      Result := Result + sLineBreak + sLineBreak;
    Result := Result + sLineBreak + sLineBreak +
              '### ' + SubHeader + sLineBreak + sLineBreak + SubBody;
  end;

begin
  Result := '';
  Slicing := TaskAware and (Trim(TaskHint) <> '');
  MemoryDir := JoinPath(GetHome, 'workspace/memory');

  AppendFile('MEMORY.md (durable)', JoinPath(MemoryDir, 'MEMORY.md'));

  TodayStr     := FormatDateTime('yyyy-mm-dd', Now);
  YesterdayStr := FormatDateTime('yyyy-mm-dd', Now - 1);
  AppendFile('Today (' + TodayStr + ')',         JoinPath(MemoryDir, TodayStr + '.md'));
  AppendFile('Yesterday (' + YesterdayStr + ')', JoinPath(MemoryDir, YesterdayStr + '.md'));
end;

function BuildSkillsSection: string;
var
  Skills: TSkillSpecArray;
  i: Integer;
  Lines: TStringList;
  Desc, K: string;
  HasCallable, HasKnowledge: Boolean;
begin
  Result := '';
  try
    Skills := LoadSkillManifests(GetHome);
  except
    Exit;
  end;
  if Length(Skills) = 0 then Exit;

  HasCallable  := False;
  HasKnowledge := False;
  for i := 0 to High(Skills) do
  begin
    K := LowerCase(Trim(Skills[i].Kind));
    if (K = 'shell') or (K = 'prompt') then HasCallable := True
    else HasKnowledge := True;
  end;

  Lines := TStringList.Create;
  try
    Lines.Add('## Skills');
    Lines.Add('');
    if HasCallable and HasKnowledge then
      Lines.Add('Skills extend your capabilities. Callable skills register as `skill_<name>` tools you invoke directly; knowledge-only skills are markdown bodies -- read each one''s SKILL.md with `fs_read` when the matching task comes up.')
    else if HasCallable then
      Lines.Add('The following skills register as `skill_<name>` tools you can call directly.')
    else
      Lines.Add('Knowledge-only skills are markdown bodies. Read each SKILL.md with `fs_read` for the procedural context the model needs.');
    Lines.Add('');
    for i := 0 to High(Skills) do
    begin
      Desc := Trim(Skills[i].Description);
      K    := LowerCase(Trim(Skills[i].Kind));
      if (K = 'shell') or (K = 'prompt') then
      begin
        { Callable skill -- advertise as `skill_<name>`, which is the
          actual registered tool identifier in PasClaw.Skills.Loader. }
        if Desc = '' then
          Lines.Add('- `skill_' + Skills[i].Name + '` (callable)')
        else
          Lines.Add('- `skill_' + Skills[i].Name + '` -- ' + Desc + ' (callable)');
      end
      else
      begin
        { Knowledge-only skill -- surface the SKILL.md path so the model
          can fs_read it on demand. Picoclaw and nanobot do the same: the
          system prompt lists the catalog, the body loads lazily. }
        if Desc = '' then
          Lines.Add('- **' + Skills[i].Name + '**: read `' + Skills[i].Source + '`')
        else
          Lines.Add('- **' + Skills[i].Name + '** -- ' + Desc + '. Read `' + Skills[i].Source + '` for the full instructions.');
      end;
    end;
    Result := Lines.Text;
    { Strip trailing newline TStringList.Text adds, so the SectionSep
      below doesn't end up with an extra blank line. }
    { CharInSet (vs the `in` shorthand) -- under Delphi 12 dcc64 the
      string is UnicodeString so Result[i] is WideChar; `in [#10,#13]`
      coerces it back to AnsiChar and emits W1050. CharInSet keeps
      the WideChar without the truncation warning; FPC's SysUtils
      ships the same helper so no per-compiler gate is needed. }
    while (Result <> '') and CharInSet(Result[Length(Result)], [#10, #13]) do
      SetLength(Result, Length(Result) - 1);
  finally
    Lines.Free;
  end;
end;

function BuildRulesSection(ToolsEnabled: Boolean): string;
var
  MemPath: string;
begin
  if not ToolsEnabled then
  begin
    { No-tools mode: the model cannot call fs_write, fs_edit_hashline,
      skills, or anything else. Rules 1, 3, 4, and 5 all assume tool
      access -- emitting them would tell the model to do things the
      tool loop is configured to refuse. Keep the precision rule
      because it is purely advisory and language-agnostic. }
    Result :=
      '## Rules' + sLineBreak +
      sLineBreak +
      '1. **Be precise** -- match the language''s native idioms, name things ' +
      'clearly, do not introduce abstractions the task does not actually need. ' +
      'Three similar lines is fine; a premature framework is not.' + sLineBreak +
      sLineBreak +
      '2. **No tools in this session** -- the user invoked you in text-only ' +
      'mode. Do not claim to read files, run commands, or modify state. ' +
      'Answer from what is in this conversation.';
    Exit;
  end;

  MemPath := JoinPath(GetHome, 'workspace/memory/MEMORY.md');
  Result :=
    '## Rules' + sLineBreak +
    sLineBreak +
    '1. **ALWAYS use tools** when an action is needed -- call the appropriate ' +
    'tool, do not just say you''ll do it or pretend the work was done. The ' +
    'user will check.' + sLineBreak +
    sLineBreak +
    '2. **Be precise** -- match the language''s native idioms, name things ' +
    'clearly, do not introduce abstractions the task does not actually need. ' +
    'Three similar lines is fine; a premature framework is not.' + sLineBreak +
    sLineBreak +
    '3. **Verify changes** -- after editing code, re-read what you wrote or ' +
    'run a targeted check (build, test, search). Do not assume the edit ' +
    'landed correctly because the tool returned success.' + sLineBreak +
    sLineBreak +
    '4. **Truncated tool calls** -- if a `fs_write` call comes back with a ' +
    '"missing required argument: content" error, your previous response was ' +
    'truncated mid-tool_call (you hit max_tokens). Re-emit with the full ' +
    'content, or switch to `fs_edit_hashline` for incremental edits on ' +
    'large files.' + sLineBreak +
    sLineBreak +
    '5. **Memory** -- when the user mentions something worth keeping across ' +
    'sessions (preferences, project facts, conventions), update ' +
    MemPath + ' for durable notes the user owns, or append a dated ' +
    'entry to ' + JoinPath(GetHome, 'workspace/memory') +
    '/{today}.md (e.g. ' + FormatDateTime('yyyy-mm-dd', Now) +
    '.md) for episodic context. Use `memory_search` before answering ' +
    'questions about prior conversations or project facts you might ' +
    'have written down on an earlier turn.' + sLineBreak +
    sLineBreak +
    '6. **Think in code, not in transcripts** -- when a question needs ' +
    'numbers, summaries, or filtered results across many files, prefer ' +
    'writing a short shell or Python script that computes the answer and ' +
    'prints only the result, rather than reading dozens of files into ' +
    'context. Example: "how many `procedure` definitions are in src/?" ' +
    'is one `grep -c ''^procedure'' src/**/*.pas` + a sum, not a tour ' +
    'of every .pas file. The script''s stdout becomes your evidence; ' +
    'the raw file bodies do not need to enter the conversation.';
end;

function AppendSection(const Acc, Section: string): string;
begin
  if Trim(Section) = '' then Exit(Acc);
  if Acc = '' then Exit(Section);
  Result := Acc + SectionSep + Section;
end;

function BuildSystemPrompt(Cfg: TConfig; const UserSys: string;
                           ToolsEnabled: Boolean;
                           const TaskHint: string): string;
begin
  Result := '';
  Result := AppendSection(Result, BuildIdentitySection);
  Result := AppendSection(Result, BuildWorkspaceSection);
  Result := AppendSection(Result,
              BuildMemorySection((Cfg <> nil) and Cfg.OrientTaskAware, TaskHint));
  { Skills are only callable when the tool registry was actually built.
    --no-tools (and component UseTools=False) bypass RegisterSkills, so
    advertising the catalog would be a lie. }
  if ToolsEnabled then
    Result := AppendSection(Result, BuildSkillsSection);
  Result := AppendSection(Result, BuildRulesSection(ToolsEnabled));
  if Trim(UserSys) <> '' then
    Result := AppendSection(Result, Trim(UserSys));
end;

function HasSystemMessage(const Messages: array of TMessage): Boolean;
var
  i: Integer;
begin
  for i := 0 to High(Messages) do
    if Messages[i].Role = mrSystem then
      Exit(True);
  Result := False;
end;

end.
