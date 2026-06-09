(*
  PasClaw.Vault.Client -- search + fetch entries in the pasclaw.dev
  Code Vault. Vault entries are GitHub repos (Object Pascal samples,
  reusable components, libraries); the registry is search-and-get
  only -- there's no zip/download step. Use the returned `repoUrl`
  with `git clone` (the `pasclaw vault install` CLI does this) or
  with the agent's `web_fetch` / `shell_exec` tools.

  Endpoints (base: https://pasclaw.dev/api/public/v1):

    GET /vault?q=<query>&limit=<n>
       {"results":[{"slug":"…","displayName":"…","summary":"…",
                    "category":"…","tags":[…],"repoUrl":"…",
                    "latestVersion":"…"}]}

    GET /vault/<slug>
       {"slug":"…", "displayName":"…", "summary":"…",
        "descriptionMarkdown":"…", "category":"…", "tags":[…],
        "repoUrl":"…", "homepageUrl":"…", "license":"…",
        "delphiVersions":[…], "packageManager":"…",
        "installSnippet":"…", "latestVersion":"…",
        "viewCount":42, "moderation":{…}}

  Failure semantics match PasClaw.Skills.PasClawHub: 404 returns
  ErrMsg = 'not found' so callers can distinguish miss from network
  error.
*)
unit PasClaw.Vault.Client;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils;

type
  TVaultResult = record
    Slug:        string;
    DisplayName: string;
    Summary:     string;
    Category:    string;
    Tags:        string;   { comma-joined for compactness -- list rendering only }
    RepoURL:     string;
    Version:     string;
  end;
  TVaultResultArray = array of TVaultResult;

  TVaultDetail = record
    Slug:                string;
    DisplayName:         string;
    Summary:             string;
    DescriptionMarkdown: string;
    Category:            string;
    Tags:                string;
    RepoURL:             string;
    HomepageURL:         string;
    License:             string;
    DelphiVersions:      string;
    PackageManager:      string;
    InstallSnippet:      string;
    LatestVersion:       string;
    ViewCount:           Integer;
    Blocked:             Boolean;
    Suspicious:          Boolean;
  end;

function SearchVault(const Query: string; Limit: Integer;
                     out Results: TVaultResultArray;
                     out ErrMsg: string): Boolean;

function GetVaultEntry(const Slug: string;
                       out Detail: TVaultDetail;
                       out ErrMsg: string): Boolean;

implementation

uses
  PasClaw.Logger,
  PasClaw.JSON,
  PasClaw.Providers.HTTP;

const
  VaultBaseURL       = 'https://pasclaw.dev/api/public/v1';
  ListEndpoint       = '/vault';
  GetEndpoint        = '/vault/';
  RequestTimeoutSec  = 30;

function UrlEncode(const S: string): string;
{ Duplicated from PasClaw.Skills.PasClawHub -- minimal percent-encoder.
  The codebase has accepted this duplication across hub clients; a
  follow-up should extract to a shared util. }
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
      Result := Result + Format('%%%2.2X', [Ord(C)]);
  end;
end;

function IsValidSlug(const S: string): Boolean;
(* Mirrors the pattern the OpenAPI documents: ^[a-z0-9_-]\{1,128\}$ *)
var
  i: Integer;
  C: Char;
begin
  Result := False;
  if (S = '') or (Length(S) > 128) then Exit;
  for i := 1 to Length(S) do
  begin
    C := S[i];
    if not ( ((C >= 'a') and (C <= 'z')) or
             ((C >= '0') and (C <= '9')) or
             (C = '-') or (C = '_') ) then Exit;
  end;
  Result := True;
end;

function DoGetJSON(const URL: string; out Body, ErrMsg: string): Boolean;
var
  Headers: array of THeaderPair;
  Resp: THTTPResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Headers, 0);
  Resp := GetJSONURL(URL, Headers, RequestTimeoutSec);
  if (Resp.StatusCode < 200) or (Resp.StatusCode >= 300) then
  begin
    if Resp.StatusCode = 404 then ErrMsg := 'not found'
    else if Resp.ErrorMsg <> '' then ErrMsg := Format('http %d: %s', [Resp.StatusCode, Resp.ErrorMsg])
    else ErrMsg := Format('http %d', [Resp.StatusCode]);
    Exit;
  end;
  Body := Resp.Body;
  Result := True;
end;

function CommaJoinArray(Arr: TJsonArray): string;
var
  i: Integer;
  S: string;
begin
  Result := '';
  if Arr = nil then Exit;
  for i := 0 to Arr.Count - 1 do
  begin
    S := Arr.ItemStr(i, '');
    if S = '' then Continue;
    if Result <> '' then Result := Result + ', ';
    Result := Result + S;
  end;
end;

function SearchVault(const Query: string; Limit: Integer;
                     out Results: TVaultResultArray;
                     out ErrMsg: string): Boolean;
var
  URL, Body, S: string;
  Root: TJsonObject;
  Arr, TagsArr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
  Res: TVaultResult;
begin
  Result := False;
  ErrMsg := '';
  SetLength(Results, 0);
  if Limit <= 0 then Limit := 25;
  if Limit > 100 then Limit := 100;

  URL := VaultBaseURL + ListEndpoint + '?limit=' + IntToStr(Limit);
  if Trim(Query) <> '' then
    URL := URL + '&q=' + UrlEncode(Query);
  LogDebug('vault: GET %s', [URL]);
  if not DoGetJSON(URL, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed JSON response: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed JSON response';
      Exit;
    end;
    Arr := Root.ChildArray('results');
    if Arr = nil then Exit(True);
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          S := Item.GetStr('slug', '');
          if S = '' then Continue;
          Res.Slug        := S;
          Res.DisplayName := Item.GetStr('displayName', S);
          Res.Summary     := Item.GetStr('summary', '');
          Res.Category    := Item.GetStr('category', '');
          Res.RepoURL     := Item.GetStr('repoUrl', '');
          Res.Version     := Item.GetStr('latestVersion', '');
          TagsArr := Item.ChildArray('tags');
          if TagsArr <> nil then
          try
            Res.Tags := CommaJoinArray(TagsArr);
          finally
            TagsArr.Free;
          end
          else
            Res.Tags := '';
          SetLength(Results, Length(Results) + 1);
          Results[High(Results)] := Res;
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;
    Result := True;
  finally
    Root.Free;
  end;
end;

function GetVaultEntry(const Slug: string;
                       out Detail: TVaultDetail;
                       out ErrMsg: string): Boolean;
var
  URL, Body: string;
  Root, ModObj: TJsonObject;
  TagsArr, DelphiArr: TJsonArray;
begin
  Result := False;
  ErrMsg := '';
  FillChar(Detail, SizeOf(Detail), 0);
  if not IsValidSlug(Slug) then
  begin
    ErrMsg := 'invalid slug: ' + Slug;
    Exit;
  end;

  URL := VaultBaseURL + GetEndpoint + UrlEncode(Slug);
  LogDebug('vault: GET %s', [URL]);
  if not DoGetJSON(URL, Body, ErrMsg) then Exit;

  Root := nil;
  try
    try
      Root := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        ErrMsg := 'malformed JSON response: ' + E.Message;
        Exit;
      end;
    end;
    if Root = nil then
    begin
      ErrMsg := 'malformed JSON response';
      Exit;
    end;
    Detail.Slug                := Root.GetStr('slug', Slug);
    Detail.DisplayName         := Root.GetStr('displayName', '');
    Detail.Summary             := Root.GetStr('summary', '');
    Detail.DescriptionMarkdown := Root.GetStr('descriptionMarkdown', '');
    Detail.Category            := Root.GetStr('category', '');
    Detail.RepoURL             := Root.GetStr('repoUrl', '');
    Detail.HomepageURL         := Root.GetStr('homepageUrl', '');
    Detail.License             := Root.GetStr('license', '');
    Detail.PackageManager      := Root.GetStr('packageManager', '');
    Detail.InstallSnippet      := Root.GetStr('installSnippet', '');
    Detail.LatestVersion       := Root.GetStr('latestVersion', '');
    Detail.ViewCount           := Root.GetInt('viewCount', 0);

    TagsArr := Root.ChildArray('tags');
    if TagsArr <> nil then
    try
      Detail.Tags := CommaJoinArray(TagsArr);
    finally
      TagsArr.Free;
    end;

    DelphiArr := Root.ChildArray('delphiVersions');
    if DelphiArr <> nil then
    try
      Detail.DelphiVersions := CommaJoinArray(DelphiArr);
    finally
      DelphiArr.Free;
    end;

    ModObj := Root.ChildObject('moderation');
    if ModObj <> nil then
    try
      Detail.Blocked    := ModObj.GetBool('isMalwareBlocked', False);
      Detail.Suspicious := ModObj.GetBool('isSuspicious',     False);
    finally
      ModObj.Free;
    end;

    Result := True;
  finally
    Root.Free;
  end;
end;

end.
