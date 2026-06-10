program mcp_hub_projection_tests;
(*
  Covers PasClaw.MCP.Hub.ProjectHubEntryToCatalog -- the function that
  maps one pasclaw.dev hub registry record onto a TMCPCatalogEntry the
  install command can persist.

  Before this PR, the projector rejected every transport != 'http' with
  "v1 is HTTP-only". The user reported `pasclaw mcp catalog` showed
  "10 hub entry/entries skipped" with only the bundled 5 visible --
  9 of those skipped were actually `sse`-tagged HTTP endpoints
  TMCPHttpClient already speaks (Streamable HTTP accepts both
  application/json and text/event-stream response bodies), and 1 was
  a stdio binary.

  Contracts pinned here:

    - Plain HTTP entries project as before (URL, EnvVar, AuthFmt
      defaulted to "Bearer %s" when an env var is present).
    - SSE-tagged entries project as HTTP for routing purposes
      (Entry.URL populated) but preserve Transport='sse' verbatim
      so the catalog display can flag it.
    - 'streamable-http' / 'stream' variants project identically to
      plain HTTP for the routing case.
    - stdio entries project with Transport='stdio', Cmd holding the
      executable, CmdArgs holding the joined argv tail.
    - Truly unknown transports (e.g. 'websocket') still reject with
      a clear "transport X not supported" ErrMsg.
    - Missing slug, missing endpointUrl, missing command all reject
      with specific ErrMsg.
    - JoinHubArgs preserves argv order, ignores empties, joins
      with single spaces -- matches the by-hand `pasclaw mcp add`
      Args convention so TStdioProcess.SplitArgs round-trips.
    - CatalogEntryIsStdio predicate is True only for the literal
      'stdio' transport (case-insensitive); empty/http/sse all
      return False.
*)

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}{$CODEPAGE UTF8}{$ENDIF}

uses
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  PasClaw.JSON,
  PasClaw.MCP.Catalog,
  PasClaw.MCP.Hub;

procedure Fail_(const Msg: string);
begin
  WriteLn('FAIL: ' + Msg);
  Halt(1);
end;

procedure AssertTrue(Cond: Boolean; const Msg: string);
begin
  if not Cond then Fail_(Msg);
end;

procedure AssertFalse(Cond: Boolean; const Msg: string);
begin
  if Cond then Fail_(Msg);
end;

procedure AssertEqStr(const Got, Want, Msg: string);
begin
  if Got <> Want then
    Fail_(Msg + ' (got "' + Copy(Got, 1, 200) + '", want "' +
          Copy(Want, 1, 200) + '")');
end;

procedure AssertContains(const Haystack, Needle, Msg: string);
begin
  if Pos(Needle, Haystack) <= 0 then
    Fail_(Msg + ' (needle "' + Needle + '" missing from "' +
          Copy(Haystack, 1, 200) + '")');
end;

function ProjectFromJSON(const JSON: string;
                         out Entry: TMCPCatalogEntry;
                         out ErrMsg: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  Obj := TJsonObject.Parse(JSON);
  if Obj = nil then begin ErrMsg := 'bad test JSON'; Exit; end;
  try
    Result := ProjectHubEntryToCatalog(Obj, Entry, ErrMsg);
  finally
    Obj.Free;
  end;
end;

function ProjectSummaryFromJSON(const JSON: string;
                                 out Entry: TMCPCatalogEntry;
                                 out ErrMsg: string): Boolean;
var
  Obj: TJsonObject;
begin
  Result := False;
  Obj := TJsonObject.Parse(JSON);
  if Obj = nil then begin ErrMsg := 'bad test JSON'; Exit; end;
  try
    Result := ProjectHubSummaryToCatalog(Obj, Entry, ErrMsg);
  finally
    Obj.Free;
  end;
end;

procedure TestHttpEntryProjects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectFromJSON(
    '{"slug":"do-apps","transport":"http","endpointUrl":"https://apps.mcp.do.com/mcp",' +
    '"summary":"DigitalOcean apps","envSchema":[{"name":"DIGITALOCEAN_TOKEN","required":true}]}',
    Entry, Err), 'plain http entry projects');
  AssertEqStr(Entry.Name,      'do-apps',                'slug -> Name');
  AssertEqStr(Entry.Transport, 'http',                   'transport preserved');
  AssertEqStr(Entry.URL,       'https://apps.mcp.do.com/mcp', 'endpointUrl -> URL');
  AssertEqStr(Entry.EnvVar,    'DIGITALOCEAN_TOKEN',     'envSchema -> EnvVar');
  AssertEqStr(Entry.AuthFmt,   'Bearer %s',              'sane AuthFmt default');
  AssertFalse(CatalogEntryIsStdio(Entry),                'http entry is not stdio');
end;

procedure TestSseEntryProjectsAsHttpCompatible;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectFromJSON(
    '{"slug":"hf-sse","transport":"sse","endpointUrl":"https://hf.example/mcp/sse",' +
    '"summary":"HF over SSE","envSchema":[{"name":"HF_TOKEN","required":true}]}',
    Entry, Err), 'sse entry now accepted');
  AssertEqStr(Entry.Transport, 'sse', 'sse transport preserved for display');
  AssertEqStr(Entry.URL, 'https://hf.example/mcp/sse', 'sse URL populated');
  AssertEqStr(Entry.AuthFmt, 'Bearer %s', 'sse entry gets HTTP-style AuthFmt');
  AssertFalse(CatalogEntryIsStdio(Entry), 'sse entry is not stdio');
end;

procedure TestStreamableHttpProjects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectFromJSON(
    '{"slug":"streamable","transport":"streamable-http",' +
    '"endpointUrl":"https://x.example/mcp"}', Entry, Err),
    'streamable-http transport accepted');
  AssertEqStr(Entry.Transport, 'streamable-http', 'literal transport preserved');
  AssertEqStr(Entry.URL,       'https://x.example/mcp', 'URL projected');
end;

procedure TestStdioEntryProjects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectFromJSON(
    '{"slug":"github","transport":"stdio","command":"npx",' +
    '"args":["-y","@modelcontextprotocol/server-github"],' +
    '"summary":"GitHub MCP","envSchema":[{"name":"GITHUB_TOKEN","required":true}]}',
    Entry, Err), 'stdio entry now accepted');
  AssertEqStr(Entry.Transport, 'stdio', 'stdio transport recorded');
  AssertEqStr(Entry.Cmd, 'npx', 'command -> Cmd');
  AssertEqStr(Entry.CmdArgs, '-y @modelcontextprotocol/server-github',
              'args[] joined into CmdArgs');
  AssertEqStr(Entry.EnvVar, 'GITHUB_TOKEN', 'envSchema -> EnvVar for stdio too');
  AssertEqStr(Entry.URL, '', 'stdio entry has no URL');
  AssertTrue(CatalogEntryIsStdio(Entry), 'CatalogEntryIsStdio True for stdio');
end;

procedure TestStdioArgsWithWhitespaceRoundTripSafely;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  { Defensive: a hub arg that carries embedded whitespace must
    quote-wrap so the SplitArgs round-trip on the consuming side
    rebuilds the original argv. Without quoting, "--prompt say hello"
    would re-split into three slots and the spawned MCP server
    would see a broken flag. }
  AssertTrue(ProjectFromJSON(
    '{"slug":"x","transport":"stdio","command":"runner",' +
    '"args":["--mode","verbose","--prompt","say hello"]}', Entry, Err),
    'stdio with whitespace arg projects');
  AssertEqStr(Entry.CmdArgs,
              '--mode verbose --prompt "say hello"',
              'whitespace arg is quote-wrapped');
end;

procedure TestStdioEntryWithNoArgs;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectFromJSON(
    '{"slug":"raw-binary","transport":"stdio","command":"my-mcp-server"}',
    Entry, Err), 'stdio entry without args[] still projects');
  AssertEqStr(Entry.Cmd,     'my-mcp-server', 'command projected');
  AssertEqStr(Entry.CmdArgs, '',              'empty args ok');
end;

procedure TestStdioMissingCommandRejects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertFalse(ProjectFromJSON(
    '{"slug":"x","transport":"stdio","args":["foo"]}', Entry, Err),
    'stdio without command rejected');
  AssertContains(Err, 'missing command', 'clear error message');
end;

procedure TestHttpMissingEndpointRejects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertFalse(ProjectFromJSON('{"slug":"x","transport":"http"}', Entry, Err),
              'http without endpointUrl rejected');
  AssertContains(Err, 'missing endpointUrl', 'clear error message');
end;

procedure TestMissingSlugRejects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertFalse(ProjectFromJSON(
    '{"transport":"http","endpointUrl":"https://x"}', Entry, Err),
    'slug-less entry rejected');
  AssertContains(Err, 'missing slug', 'clear error message');
end;

procedure TestUnknownTransportRejects;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertFalse(ProjectFromJSON(
    '{"slug":"x","transport":"websocket"}', Entry, Err),
    'unknown transport still skipped');
  AssertContains(Err, 'websocket',   'transport name surfaced in error');
  AssertContains(Err, 'not supported', 'clear "not supported" message');
end;

procedure TestDefaultTransportIsHttp;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  { Hub entries without an explicit transport field default to HTTP. }
  AssertTrue(ProjectFromJSON(
    '{"slug":"x","endpointUrl":"https://y"}', Entry, Err),
    'missing transport defaults to http');
  AssertEqStr(Entry.Transport, 'http', 'default transport is http');
end;

procedure TestListSummaryProjectsHttpEntry;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  { Real /mcp?limit=N response shape -- just the four summary fields
    per result. The previous projector required endpointUrl and
    silently rejected EVERY hub entry from the list endpoint,
    because endpointUrl only appears in the per-slug detail. }
  AssertTrue(ProjectSummaryFromJSON(
    '{"slug":"replicate","displayName":"Replicate",' +
    '"summary":"Run open-source AI models","transport":"http"}',
    Entry, Err), 'list-summary http entry projects');
  AssertEqStr(Entry.Name,      'replicate',                'slug -> Name');
  AssertEqStr(Entry.Transport, 'http',                     'transport tagged');
  AssertEqStr(Entry.Desc,      'Run open-source AI models', 'summary -> Desc');
  AssertEqStr(Entry.URL,       '',
              'summary projector does not invent URL');
end;

procedure TestListSummaryProjectsStdioEntry;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectSummaryFromJSON(
    '{"slug":"github-mcp","summary":"GitHub MCP","transport":"stdio"}',
    Entry, Err), 'list-summary stdio entry projects');
  AssertEqStr(Entry.Transport, 'stdio',     'stdio transport tagged');
  AssertEqStr(Entry.Cmd,       '',
              'summary projector does not invent command');
  AssertEqStr(Entry.CmdArgs,   '',
              'summary projector does not invent args');
end;

procedure TestListSummaryProjectsSseEntry;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectSummaryFromJSON(
    '{"slug":"replicate-sse","summary":"SSE Replicate","transport":"sse"}',
    Entry, Err), 'list-summary sse entry projects');
  AssertEqStr(Entry.Transport, 'sse', 'sse transport preserved for display');
end;

procedure TestListSummaryDefaultsTransportToHttp;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertTrue(ProjectSummaryFromJSON(
    '{"slug":"x","summary":"y"}', Entry, Err),
    'list summary without transport defaults to http');
  AssertEqStr(Entry.Transport, 'http', 'default transport is http');
end;

procedure TestListSummaryRejectsMissingSlug;
var
  Entry: TMCPCatalogEntry;
  Err: string;
begin
  AssertFalse(ProjectSummaryFromJSON(
    '{"summary":"no slug"}', Entry, Err),
    'list-summary without slug rejected');
  AssertContains(Err, 'missing slug', 'clear error');
end;

procedure TestCatalogEntryIsStdioPredicate;
var
  E: TMCPCatalogEntry;
begin
  E := Default(TMCPCatalogEntry);
  AssertFalse(CatalogEntryIsStdio(E), 'empty transport is not stdio');
  E.Transport := 'http';
  AssertFalse(CatalogEntryIsStdio(E), 'http is not stdio');
  E.Transport := 'sse';
  AssertFalse(CatalogEntryIsStdio(E), 'sse is not stdio');
  E.Transport := 'stdio';
  AssertTrue(CatalogEntryIsStdio(E), 'literal stdio detected');
  E.Transport := 'STDIO';
  AssertTrue(CatalogEntryIsStdio(E), 'STDIO case-insensitive');
end;

begin
  TestHttpEntryProjects;             WriteLn('  ok: http entry projects');
  TestSseEntryProjectsAsHttpCompatible; WriteLn('  ok: sse entry projects (now accepted)');
  TestStreamableHttpProjects;        WriteLn('  ok: streamable-http projects');
  TestStdioEntryProjects;            WriteLn('  ok: stdio entry projects (now accepted)');
  TestStdioArgsWithWhitespaceRoundTripSafely;
                                     WriteLn('  ok: whitespace arg quoted for SplitArgs round-trip');
  TestStdioEntryWithNoArgs;          WriteLn('  ok: stdio with no args[] is ok');
  TestStdioMissingCommandRejects;    WriteLn('  ok: stdio without command rejected');
  TestHttpMissingEndpointRejects;    WriteLn('  ok: http without endpointUrl rejected');
  TestMissingSlugRejects;            WriteLn('  ok: missing slug rejected');
  TestUnknownTransportRejects;       WriteLn('  ok: unknown transport still skipped');
  TestDefaultTransportIsHttp;        WriteLn('  ok: missing transport -> http');
  TestListSummaryProjectsHttpEntry;     WriteLn('  ok: list-summary http projects');
  TestListSummaryProjectsStdioEntry;    WriteLn('  ok: list-summary stdio projects');
  TestListSummaryProjectsSseEntry;      WriteLn('  ok: list-summary sse projects');
  TestListSummaryDefaultsTransportToHttp; WriteLn('  ok: list-summary defaults transport=http');
  TestListSummaryRejectsMissingSlug;    WriteLn('  ok: list-summary rejects missing slug');
  TestCatalogEntryIsStdioPredicate;     WriteLn('  ok: CatalogEntryIsStdio predicate');
  WriteLn('PASS');
end.
