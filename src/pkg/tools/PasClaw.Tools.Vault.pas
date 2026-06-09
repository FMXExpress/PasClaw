(*
  PasClaw.Tools.Vault -- registers the vault_search and vault_get
  tools, which let the agent discover Object Pascal source code
  (samples, components, libraries) in the pasclaw.dev Code Vault.

  Both tools are tcReadOnly (HTTP GETs against the vault registry,
  no shared state). Off by default -- Cmd.Agent.NewBuiltinRegistry
  registers them only when the EnableVault flag is set, which
  Cmd.Agent reads from Cfg.VaultToolsEnabled. The onboarding flow
  asks the user to opt in (default yes); operators who skip the
  prompt can still enable later by flipping the config field or
  re-running `pasclaw onboard`.

  Output shape: both tools return JSON strings (the model handles
  JSON natively). vault_search returns
    [{"slug":"…","displayName":"…","summary":"…",
      "category":"…","tags":"…","repoUrl":"…","version":"…"}]
  vault_get returns the full entry detail including
  descriptionMarkdown so the model can read the description body
  inline without a second hop.
*)
unit PasClaw.Tools.Vault;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils,
  PasClaw.Tools.Types,
  PasClaw.Tools.Registry;

procedure RegisterVaultTools(R: TToolRegistry);

implementation

uses
  PasClaw.JSON,
  PasClaw.Logger,
  PasClaw.Vault.Client;

function ParseStrArg(const ArgsJSON, Key: string; out V: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  V := '';
  if Trim(ArgsJSON) = '' then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then Exit;
  try
    V := Obj.GetStr(Key, '');
    Result := V <> '';
  finally
    Obj.Free;
  end;
end;

function ParseIntArg(const ArgsJSON, Key: string; Default_: Integer): Integer;
var
  Obj: TJsonObject;
begin
  Result := Default_;
  if Trim(ArgsJSON) = '' then Exit;
  Obj := TJsonObject.Parse(ArgsJSON);
  if Obj = nil then Exit;
  try
    Result := Obj.GetInt(Key, Default_);
  finally
    Obj.Free;
  end;
end;

function ResultsToJSON(const Results: TVaultResultArray): string;
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Arr := TJsonArray.Create;
  try
    for i := 0 to High(Results) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('slug',        Results[i].Slug);
      Item.PutStr('displayName', Results[i].DisplayName);
      Item.PutStr('summary',     Results[i].Summary);
      Item.PutStr('category',    Results[i].Category);
      Item.PutStr('tags',        Results[i].Tags);
      Item.PutStr('repoUrl',     Results[i].RepoURL);
      Item.PutStr('version',     Results[i].Version);
      Arr.AddObject(Item);
    end;
    Root := TJsonObject.Create;
    try
      Root.PutArray('results', Arr);
      Result := Root.ToJSON;
    finally
      Root.Free;
    end;
  except
    Arr.Free;
    raise;
  end;
end;

function DetailToJSON(const D: TVaultDetail): string;
var
  Root: TJsonObject;
  ModObj: TJsonObject;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('slug',                D.Slug);
    Root.PutStr('displayName',         D.DisplayName);
    Root.PutStr('summary',             D.Summary);
    Root.PutStr('descriptionMarkdown', D.DescriptionMarkdown);
    Root.PutStr('category',            D.Category);
    Root.PutStr('tags',                D.Tags);
    Root.PutStr('repoUrl',             D.RepoURL);
    Root.PutStr('homepageUrl',         D.HomepageURL);
    Root.PutStr('license',             D.License);
    Root.PutStr('delphiVersions',      D.DelphiVersions);
    Root.PutStr('packageManager',      D.PackageManager);
    Root.PutStr('installSnippet',      D.InstallSnippet);
    Root.PutStr('latestVersion',       D.LatestVersion);
    Root.PutInt('viewCount',           D.ViewCount);
    ModObj := TJsonObject.Create;
    ModObj.PutBool('isMalwareBlocked', D.Blocked);
    ModObj.PutBool('isSuspicious',     D.Suspicious);
    Root.PutObject('moderation', ModObj);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

function Tool_VaultSearch(const ArgsJSON: string; out ErrMsg: string): string;
var
  Query: string;
  Limit: Integer;
  Results: TVaultResultArray;
  Err: string;
begin
  Result := '';
  ErrMsg := '';
  if not ParseStrArg(ArgsJSON, 'query', Query) then
  begin
    ErrMsg := 'missing "query" string argument';
    Exit;
  end;
  Limit := ParseIntArg(ArgsJSON, 'limit', 10);
  if Limit < 1 then Limit := 1;
  if Limit > 25 then Limit := 25;

  if not SearchVault(Query, Limit, Results, Err) then
  begin
    ErrMsg := 'vault search failed: ' + Err;
    LogWarn('vault_search failed: %s', [Err]);
    Exit;
  end;
  if Length(Results) = 0 then
  begin
    Result := '{"results":[],"note":"no matches"}';
    Exit;
  end;
  Result := ResultsToJSON(Results);
  LogInfo('vault_search query=%s hits=%d', [Query, Length(Results)]);
end;

function Tool_VaultGet(const ArgsJSON: string; out ErrMsg: string): string;
var
  Slug: string;
  Detail: TVaultDetail;
  Err: string;
begin
  Result := '';
  ErrMsg := '';
  if not ParseStrArg(ArgsJSON, 'slug', Slug) then
  begin
    ErrMsg := 'missing "slug" string argument';
    Exit;
  end;
  if not GetVaultEntry(Slug, Detail, Err) then
  begin
    ErrMsg := 'vault get failed: ' + Err;
    LogWarn('vault_get failed: %s', [Err]);
    Exit;
  end;
  Result := DetailToJSON(Detail);
  LogInfo('vault_get slug=%s repo=%s', [Slug, Detail.RepoURL]);
end;

procedure RegisterVaultTools(R: TToolRegistry);
var
  T: TTool;
begin
  if R = nil then Exit;

  T.Name        := 'vault_search';
  T.Description :=
    'Search the pasclaw.dev Code Vault for Object Pascal source -- ' +
    'sample programs, reusable components, libraries. Returns up to ' +
    'k entries as a list of {slug, displayName, summary, category, ' +
    'tags, repoUrl, version}. Use vault_get(slug) to read full ' +
    'description + install snippet; use shell_exec("git clone " + ' +
    'repoUrl) to obtain the code.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"query":{"type":"string","description":"Free-text search query."},' +
    '"limit":{"type":"integer","minimum":1,"maximum":25,"description":"Max results (default 10)."}' +
    '},"required":["query"]}';
  T.Handler     := Tool_VaultSearch;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);

  T.Name        := 'vault_get';
  T.Description :=
    'Fetch full detail for a Code Vault entry by slug, including ' +
    'descriptionMarkdown (the entry''s full README-style body), ' +
    'repoUrl, license, delphiVersions, and installSnippet. Pair ' +
    'with vault_search to first discover slugs; the repoUrl is what ' +
    'you pass to git clone.';
  T.Schema      :=
    '{"type":"object",' +
    '"properties":{' +
    '"slug":{"type":"string","description":"Vault entry slug, e.g. ''indy-ssl-helper''."}' +
    '},"required":["slug"]}';
  T.Handler     := Tool_VaultGet;
  T.IsCore      := True;
  T.Category    := tcReadOnly;
  R.Register(T);
end;

end.
