(*
  PasClaw.Search.Brave - Brave Search API adapter.

  Endpoint: GET https://api.search.brave.com/res/v1/web/search
            ?q=<query>&count=<n>
  Auth:     X-Subscription-Token: <api-key>
  Response: { "web": { "results": [
              { "title": "...", "url": "...",
                "description": "..." }, ... ] } }

  Brave returns rich metadata (favicon, age, type) we don't need --
  pick title / url / description and move on.

  Docs: https://api-dashboard.search.brave.com/app/documentation/web-search/get-started
*)
unit PasClaw.Search.Brave;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes,
  PasClaw.Search.Types;

function NewBraveProvider(const APIKey: string): ISearchProvider;

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Providers.HTTP;

type
  TBraveProvider = class(TInterfacedObject, ISearchProvider)
  private
    FAPIKey: string;
  public
    constructor Create(const APIKey: string);
    function Name: string;
    function Search(const Query: string; Count: Integer;
                    out Hits: TSearchResultArray; out ErrMsg: string): Boolean;
  end;

function UrlEncode(const S: string): string;
var
  i: Integer;
  C: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if ((C >= 'A') and (C <= 'Z')) or
       ((C >= 'a') and (C <= 'z')) or
       ((C >= '0') and (C <= '9')) or
       (C = '-') or (C = '_') or (C = '.') or (C = '~') then
      Result := Result + C
    else
      Result := Result + '%' + IntToHex(Byte(C), 2);
  end;
end;

constructor TBraveProvider.Create(const APIKey: string);
begin
  inherited Create;
  FAPIKey := APIKey;
end;

function TBraveProvider.Name: string;
begin
  Result := 'brave';
end;

function TBraveProvider.Search(const Query: string; Count: Integer;
                                out Hits: TSearchResultArray;
                                out ErrMsg: string): Boolean;
var
  URL: string;
  Headers: array of THeaderPair;
  Resp: THTTPResult;
  Root, Web, Item: TJsonObject;
  Results: TJsonArray;
  i, Cap: Integer;
begin
  SetLength(Hits, 0);
  ErrMsg := '';
  Result := False;

  if FAPIKey = '' then
  begin
    ErrMsg := 'brave: missing API key (set $PASCLAW_BRAVE_API_KEY)';
    Exit;
  end;

  URL := 'https://api.search.brave.com/res/v1/web/search?q=' +
         UrlEncode(Query) + '&count=' + IntToStr(Count);
  SetLength(Headers, 2);
  Headers[0] := MakeHeader('X-Subscription-Token', FAPIKey);
  Headers[1] := MakeHeader('Accept-Encoding',      'identity');

  Resp := GetJSONURL(URL, Headers, 20);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    ErrMsg := Format('brave: status=%d body=%s',
                     [Resp.StatusCode, Copy(Resp.Body, 1, 200)]);
    Exit;
  end;

  try
    Root := TJsonObject.Parse(Resp.Body);
  except
    on E: Exception do
    begin
      ErrMsg := 'brave: bad JSON: ' + E.Message;
      Exit;
    end;
  end;
  if Root = nil then begin ErrMsg := 'brave: empty JSON'; Exit; end;

  try
    Web := Root.ChildObject('web');
    if Web = nil then
    begin
      LogWarn('brave: response has no "web" block (body=%s)',
              [Copy(Resp.Body, 1, 200)]);
      Result := True;   { empty hits, not an error }
      Exit;
    end;
    try
      Results := Web.ChildArray('results');
      if Results = nil then
      begin
        Result := True;
        Exit;
      end;
      try
        Cap := Results.Count;
        if Cap > Count then Cap := Count;
        SetLength(Hits, Cap);
        for i := 0 to Cap - 1 do
        begin
          Item := Results.ItemObject(i);
          if Item = nil then Continue;
          try
            Hits[i].Title   := Item.GetStr('title',       '');
            Hits[i].URL     := Item.GetStr('url',         '');
            Hits[i].Snippet := Item.GetStr('description', '');
          finally
            Item.Free;
          end;
        end;
      finally
        Results.Free;
      end;
    finally
      Web.Free;
    end;
  finally
    Root.Free;
  end;

  Result := True;
end;

function NewBraveProvider(const APIKey: string): ISearchProvider;
begin
  Result := TBraveProvider.Create(APIKey);
end;

end.
