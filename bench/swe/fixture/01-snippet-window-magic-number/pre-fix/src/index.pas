unit Index;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

function BuildSearchSQL: string;
function BuildKBSearchSQL: string;

implementation

function BuildSearchSQL: string;
begin
  Result :=
    'SELECT path, snippet(memory_fts, 1, ''<'', ''>'', ''...'', 24), bm25(memory_fts) ' +
    'FROM memory_fts WHERE memory_fts MATCH :q ' +
    'ORDER BY bm25(memory_fts) LIMIT :k';
end;

function BuildKBSearchSQL: string;
begin
  Result :=
    'SELECT path, chunk_no, snippet(kb_fts, 2, ''<'', ''>'', ''...'', 24), bm25(kb_fts) ' +
    'FROM kb_fts WHERE kb_fts MATCH :q ORDER BY bm25(kb_fts) LIMIT :k';
end;

end.
