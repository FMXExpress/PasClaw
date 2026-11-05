(*
  PasClaw.Tools.Notes -- what failure mining (`pasclaw learn`, the nightly
  maintenance pass) needs to know about tool results, kept beside the
  tools rather than inside the miner.

  Two tables:

  - MisuseNotes: the notes a tool adds to a result when the call worked
    but was the wrong call -- what was done wrong, and what to do
    instead. The tool builds its note from the constants here and
    PasClaw.Learn recognises it from the same row, so there is no second
    copy of the wording to drift. A new note is a new row.

  - QuotingTools: the tools whose result is text they read, fetched or
    keep -- a file, a search hit, a board's checks, a subagent's answer --
    rather than the outcome of something they ran. Only such a result's
    own status line can be its failure; the rest is quoted, and mining it
    would count one board check in every agent that read it, or SCARS.md
    in every session that searched it. learn_tests registers the tools
    and fails on a read-only one that is in neither this table nor its
    list of tools whose result is their own outcome.

  No dependencies, so the memory package can read it without pulling in
  the tools.
*)
unit PasClaw.Tools.Notes;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

const
  { grep_files' whole result when nothing matched; the notes follow it on
    the same line. }
  NoMatches = '(no matches)';

  { A regex-shaped pattern given to a literal-substring search. }
  GrepRegexNoteHead = ' -- note: grep_files matches a LITERAL substring';
  GrepRegexNote = GrepRegexNoteHead +
    ', not a regex. Search one plain term (e.g. "to_csv"), or run it once ' +
    'per alternative.';

  { A definition hunted by guessing its keyword. The name searched for
    and '".' follow. }
  GrepDefinitionNoteHead = ' -- to find where a name is defined';
  GrepDefinitionNote = GrepDefinitionNoteHead +
    ', whatever its keyword or owner: code_outline symbol="';

type
  TMisuseNote = record
    Starts:    string;   { a result line that begins with this is the note }
    Signature: string;   { what its occurrences cluster under }
  end;

const
  MisuseNotes: array[0..1] of TMisuseNote = (
    (Starts:    NoMatches + GrepRegexNoteHead;
     Signature: 'grep_files regex: a literal-substring search was given a regex'),
    (Starts:    NoMatches + GrepDefinitionNoteHead;
     Signature: 'grep_files definition hunt: a keyword guess, where code_outline symbol= finds it'));

const
  QuotingTools: array[0..28] of string = (
    { files and code }
    'read_file', 'grep_files', 'find_files', 'list_dir', 'code_outline',
    'worktree_list',
    { memory, knowledge, sessions, the web }
    'memory_search', 'memory_fetch', 'kb_search', 'kb_get', 'vault_search',
    'vault_get', 'session_read', 'session_search', 'web_fetch', 'web_search',
    'tool_output_get',
    { tools and skills }
    'tool_search', 'code_catalog', 'skills_view', 'skills_list',
    { boards and plans: tasks, rules and their checks' output }
    'task', 'rule', 'project', 'desktop', 'todo_write',
    { another agent's answer }
    'agent', 'spawn_wait', 'spawn_status');

implementation

end.
