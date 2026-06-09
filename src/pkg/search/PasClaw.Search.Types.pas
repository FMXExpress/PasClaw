(*
  PasClaw.Search.Types - shared types for web-search providers.

  Mirrors picoclaw's SearchProvider interface but Pascal-flavoured:
  every adapter implements ISearchProvider and returns a uniform
  TSearchResultArray. The web_search tool dispatches to the
  configured adapter via PasClaw.Search.Factory, so adding a new
  provider is a single new unit plus a case-branch in the factory.

  Result records are flat -- title + URL + snippet. picoclaw's richer
  shape (favicons, dates, scores) is provider-specific and not worth
  the abstraction tax for what the model actually reads.
*)
unit PasClaw.Search.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TSearchResult = record
    Title:   string;
    URL:     string;
    Snippet: string;
  end;
  TSearchResultArray = array of TSearchResult;

  ISearchProvider = interface
    ['{E3A4D1F0-5B62-4C8E-9F03-7A1B2C5D8E40}']
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

implementation

end.
