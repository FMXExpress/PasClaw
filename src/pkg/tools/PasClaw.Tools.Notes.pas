(*
  PasClaw.Tools.Notes -- the notes a tool adds to a result when the call
  worked but was the wrong call: what was done wrong, and what to do
  instead.

  One table, two readers. The tool that writes a note builds it from the
  constants here, and PasClaw.Learn recognises it from the same table,
  so `pasclaw learn` and the nightly maintenance pass count a misuse
  without a second copy of the wording to drift from the first. A new
  note is a new row: the text a result line starts with, and the
  signature its occurrences cluster under.

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

implementation

end.
