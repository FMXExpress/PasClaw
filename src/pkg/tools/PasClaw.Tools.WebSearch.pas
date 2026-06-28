(*
  PasClaw.Tools.WebSearch - registers the web_search tool.

  The tool dispatches to the configured provider via
  PasClaw.Search.Factory. Schema:
    {
      "query": "<string, required>",
      "k":     <integer, optional, default cfg.WebSearch.MaxResults>
    }
  Returns up to k hits as:
    1. <title>
       <url>
       <snippet>

    2. ...
  with hits separated by blank lines so the model can scan them
  quickly. Empty result list returns "(no hits for <query>)" so the
  model doesn't mistake silence for "tool broke".

  No provider configured falls through to DuckDuckGo (zero-config
  fallback). API-key-required providers surface a clear "set
  $PASCLAW_<KIND>_API_KEY" error so the user knows what's missing.
*)
unit PasClaw.Tools.WebSearch;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterWebSearchTool(R: TToolRegistry);

implementation

uses
  Classes,
  PasClaw.JSON,
  PasClaw.Config,
  PasClaw.Logger,
  PasClaw.Search.Types,
  PasClaw.Search.Factory;

function ParseStringArg(const ArgsJSON, Field: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      V := Obj.GetStr(Field, '');
      Result := V <> '';
    finally
      Obj.Free;
    end;
  except
    Result := False;
  end;
end;

function ParseIntArg(const ArgsJSON, Field: string; Default: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default;
  if Trim(ArgsJSON) = '' then Exit;
  try
    Obj := TJsonObject.Parse(ArgsJSON);
    if Obj = nil then Exit;
    try
      if Obj.Has(Field) then Result := Obj.GetInt(Field, Default);
    finally
      Obj.Free;
    end;
  except
    Result := Default;
  end;
end;

function Tool_WebSearch(const ArgsJSON: string; out ErrMsg: string): string;
const
  HardCap = 25;
var
  Query, Err: string;
  K, i, Default: Integer;
  Cfg: TConfig;
  Provider: ISearchProvider;
  Hits: TSearchResultArray;
  Lines: TStringList;
begin
  ErrMsg := '';
  Result := '';

  if not ParseStringArg(ArgsJSON, 'query', Query) then
  begin
    ErrMsg := 'missing required argument: query';
    Exit;
  end;

  Cfg := LoadEffectiveConfig;
  try
    Default := Cfg.WebSearch.MaxResults;
    if Default <= 0 then Default := 5;
    K := ParseIntArg(ArgsJSON, 'k', Default);
    if K < 1       then K := 1;
    if K > HardCap then K := HardCap;

    Provider := NewSearchProvider(Cfg, Err);
    if Provider = nil then
    begin
      ErrMsg := Err;
      Exit;
    end;

    if not Provider.Search(Query, K, Hits, Err) then
    begin
      ErrMsg := Err;
      Exit;
    end;
  finally
    Cfg.Free;
  end;

  if Length(Hits) = 0 then
    Exit(Format('(no hits for %s via %s)',
                [Query, Provider.Name]));

  Lines := TStringList.Create;
  try
    Lines.Add(Format('%d hit(s) for %s via %s:',
                     [Length(Hits), Query, Provider.Name]));
    Lines.Add('');
    for i := 0 to High(Hits) do
    begin
      Lines.Add(Format('%d. %s', [i + 1, Hits[i].Title]));
      Lines.Add('   ' + Hits[i].URL);
      if Hits[i].Snippet <> '' then
        Lines.Add('   ' + Hits[i].Snippet);
      if i < High(Hits) then Lines.Add('');
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;

  LogDebug('web_search via=%s q=%s hits=%d',
           [Provider.Name, Query, Length(Hits)]);
end;

procedure RegisterWebSearchTool(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;
  T.Name        := 'web_search';
  T.Description :=
    'Search the web. Dispatches to the configured provider (DuckDuckGo ' +
    'when no api key is set; Brave or Tavily when $PASCLAW_BRAVE_API_KEY ' +
    'or $PASCLAW_TAVILY_API_KEY is set and config.json picks one). ' +
    'Returns up to k results as title + URL + snippet.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"Free-text search query."},' +
    '"k":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 5)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_WebSearch;
  T.IsCore      := True;
  T.Category    := tcReadOnly;  { HTTP GETs only, no shared state }
  R.Register(T);
end;

end.
