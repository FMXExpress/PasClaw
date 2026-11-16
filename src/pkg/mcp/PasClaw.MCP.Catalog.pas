(*
  PasClaw.MCP.Catalog - hand-curated catalogue of public remote MCP
  servers, so `pasclaw mcp install <name>` can wire one up without
  the user having to look up the URL + auth-header shape themselves.

  Why this exists (vs. always letting the user `pasclaw mcp add`):

    1. Discovery -- the model can't read the operator's mind, but it
       can read this catalogue. `pasclaw mcp install replicate` is
       a one-liner that pulls in the right URL and the right
       Authorization header from the right env-var.

    2. Auth shape -- every provider has decided on a slightly
       different Bearer-token layout, and getting it wrong (forgot
       the "Bearer " prefix, used POST instead of GET, etc.) is
       the #1 way installs end up "broken-on-arrival". The
       catalogue encodes the right shape once per provider.

    3. Not preloaded by default -- picoclaw seeds nothing. PasClaw
       follows the same rule: no MCP server contacts a remote
       endpoint unless the operator explicitly opted in via
       `pasclaw mcp install <name>`. Entries below are inert until
       installed.

  Adding a new provider: append a TMCPCatalogEntry record to the
  KnownMCPServers constant. The first user-visible test is
  `pasclaw mcp catalog` showing it; the second is
  `pasclaw mcp install <name>` writing a normal mcp_servers entry.
  Nothing else in the codebase needs changing -- the install path
  uses the same TConfig.MCPServers array every other MCP entry
  uses, so list / remove / test / show all just work.
*)
unit PasClaw.MCP.Catalog;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

type
  TMCPCatalogEntry = record
    Name:          string; { kebab-case identifier; what the user types }
    { Transport: '' / 'http' (default) -- the URL field carries the
      remote endpoint. 'stdio' -- the Cmd + CmdArgs fields carry an
      executable to spawn. Catalog entries from pasclaw.dev are the
      common source of stdio rows; the bundled KnownMCPServers list
      stays HTTP-only. }
    Transport:     string;
    URL:           string; { remote MCP endpoint (http:// or https://);
                             empty for stdio entries }
    Cmd:           string; { stdio: executable name (e.g. "npx",
                             "uvx", "docker"). Empty for HTTP. }
    CmdArgs:       string; { stdio: command-line args joined with
                             spaces ("-y @modelcontextprotocol/server-github").
                             Empty for HTTP. }
    EnvVar:        string; { env var holding the bearer token (HTTP)
                             or the first REQUIRED env var the
                             stdio binary expects (e.g. GITHUB_TOKEN
                             for the github stdio server). Empty
                             when no auth is needed. }
    AuthFmt:       string; { Authorization-header value template, e.g. "Bearer %s".
                             Empty when no auth. Catalog install reads
                             GetEnvironmentVariable(EnvVar) and substitutes
                             it into AuthFmt to produce the literal header
                             the HTTP MCP client stores in the args slot.
                             Unused for stdio (the binary reads the env
                             var itself from the spawning shell). }
    RequiresOAuth: Boolean;{ True when the remote uses OAuth 2.1 (MCP
                             Authorization spec -- discovery + PKCE + dynamic
                             client registration). `mcp install` writes the
                             entry with no header and prints a hint to run
                             `pasclaw mcp auth <name>`; the HTTP client
                             reads the resulting access token from the
                             on-disk token store. Replicate is the v1 case.
                             Always False for stdio entries. }
    Desc:          string; { one-liner shown by `pasclaw mcp catalog` }
    Docs:          string; { url for the user to learn more }
    { True when EnvVar / AuthFmt / RequiresOAuth describe the actual
      auth posture of the server. False when the entry came from the
      hub LIST endpoint, which doesn't carry envSchema -- so a blank
      EnvVar on a hub-summary row means "we don't know yet", NOT
      "no auth needed". The bundled KnownMCPServers list and the
      strict ProjectHubEntryToCatalog (which hits the per-slug detail
      endpoint) both set this True; ProjectHubSummaryToCatalog leaves
      it False. `pasclaw mcp catalog` reads it to render the auth
      column truthfully -- a hub-summary row shows "(see detail)"
      rather than the misleading "(no auth)" the operator used to
      get when browsing a hub-fetched catalog. }
    AuthKnown:     Boolean;
  end;
  TMCPCatalogEntryArray = array of TMCPCatalogEntry;

{ True when Entry.Transport names a stdio binary. Anything else --
  empty, 'http', 'sse', 'streamable-http', 'stream' -- is treated as
  a remote HTTP MCP server (TMCPHttpClient speaks Streamable HTTP and
  accepts both JSON and SSE response bodies, so 'sse' rows from the
  hub route through the same code path). }
function CatalogEntryIsStdio(const Entry: TMCPCatalogEntry): Boolean;

function KnownMCPServers: TMCPCatalogEntryArray;
function FindCatalogEntry(const Name: string;
                           out Entry: TMCPCatalogEntry): Boolean;

(* Render the literal Authorization header value for an entry,
   reading the env var at the moment of install. Returns '' if the
   entry has no auth, or if the env var is set to empty. The third
   out parameter EnvWasSet distinguishes "auth not required" (env
   = '', EnvWasSet = True) from "auth required but env var
   missing" (env = '', EnvWasSet = False) so the install command
   can warn appropriately. *)
function ResolveAuthHeader(const Entry: TMCPCatalogEntry;
                            out HeaderValue: string;
                            out EnvWasSet: Boolean): Boolean;

(* Format the literal Authorization header for an entry given a
   token the caller has already obtained (e.g. interactively from
   `pasclaw onboard`). Sibling to ResolveAuthHeader, which sources
   the token from the env var -- this one takes it as an argument
   so the onboarding flow can prompt the user and persist the
   resulting header into config.json without requiring the env var
   to be set. Empty Token returns '' (caller installs with no
   auth, same as pasclaw mcp install when the env var is missing). *)
function FormatAuthHeaderFromToken(const Entry: TMCPCatalogEntry;
                                    const Token: string): string;

implementation

uses
  SysUtils;

function CatalogEntryIsStdio(const Entry: TMCPCatalogEntry): Boolean;
begin
  Result := SameText(Entry.Transport, 'stdio');
end;

function KnownMCPServers: TMCPCatalogEntryArray;
var
  i: Integer;
begin
  SetLength(Result, 6);

  { Replicate's MCP server is OAuth-only -- it advertises RFC 9728
    protected-resource metadata and rejects raw REPLICATE_API_TOKEN
    with "invalid_token". `mcp install replicate` writes a no-header
    entry and prompts the user to run `mcp auth replicate`, which
    runs the OAuth 2.1 + PKCE flow via PasClaw.MCP.OAuth. }
  Result[0].Name          := 'replicate';
  Result[0].URL           := 'https://mcp.replicate.com/mcp';
  Result[0].EnvVar        := '';
  Result[0].AuthFmt       := '';
  Result[0].RequiresOAuth := True;
  Result[0].Desc          := 'Run AI models (text/image/video/audio) on Replicate -- 5000+ models. ' +
                             'OAuth-only -- run `pasclaw mcp auth replicate` after install.';
  Result[0].Docs          := 'https://replicate.com/docs/reference/mcp';

  Result[1].Name    := 'digitalocean-apps';
  Result[1].URL     := 'https://apps.mcp.digitalocean.com/mcp';
  Result[1].EnvVar  := 'DIGITALOCEAN_TOKEN';
  Result[1].AuthFmt := 'Bearer %s';
  Result[1].Desc    := 'Manage DigitalOcean App Platform deployments.';
  Result[1].Docs    := 'https://docs.digitalocean.com/reference/mcp/configure-mcp/';

  Result[2].Name    := 'digitalocean-databases';
  Result[2].URL     := 'https://databases.mcp.digitalocean.com/mcp';
  Result[2].EnvVar  := 'DIGITALOCEAN_TOKEN';
  Result[2].AuthFmt := 'Bearer %s';
  Result[2].Desc    := 'Manage DigitalOcean Managed Databases.';
  Result[2].Docs    := 'https://docs.digitalocean.com/reference/mcp/configure-mcp/';

  Result[3].Name    := 'runpod-docs';
  Result[3].URL     := 'https://docs.runpod.io/mcp';
  Result[3].EnvVar  := '';
  Result[3].AuthFmt := '';
  Result[3].Desc    := 'Search RunPod documentation. No auth required.';
  Result[3].Docs    := 'https://docs.runpod.io/get-started/mcp-servers';

  Result[4].Name          := 'parallel-search';
  Result[4].Transport     := 'http';
  Result[4].URL           := 'https://search.parallel.ai/mcp';
  Result[4].EnvVar        := '';
  Result[4].AuthFmt       := '';
  Result[4].RequiresOAuth := False;
  Result[4].Desc          := 'Search the web and fetch URLs. User-provided search objectives, search queries, ' +
                             'and requested URLs are sent to Parallel. No auth required.';
  Result[4].Docs          := 'https://docs.parallel.ai/integrations/mcp/search-mcp';

  Result[5].Name    := 'huggingface';
  Result[5].URL     := 'https://huggingface.co/mcp';
  Result[5].EnvVar  := 'HF_TOKEN';
  Result[5].AuthFmt := 'Bearer %s';
  Result[5].Desc    := 'Search Hugging Face models, datasets, papers, Spaces.';
  Result[5].Docs    := 'https://huggingface.co/docs/hub/en/agents-mcp';

  { Every bundled row carries fully-known auth metadata -- they're
    hand-curated above with EnvVar / AuthFmt / RequiresOAuth set
    deliberately. Mark them so `pasclaw mcp catalog` can render the
    auth column truthfully (and distinguish from hub-fetched summary
    rows where the same blank EnvVar means "we don't know yet"). }
  for i := 0 to High(Result) do Result[i].AuthKnown := True;
end;

function FindCatalogEntry(const Name: string;
                           out Entry: TMCPCatalogEntry): Boolean;
var
  Entries: TMCPCatalogEntryArray;
  i: Integer;
begin
  Result := False;
  Entries := KnownMCPServers;
  for i := 0 to High(Entries) do
    if SameText(Entries[i].Name, Name) then
    begin
      Entry := Entries[i];
      Exit(True);
    end;
end;

function ResolveAuthHeader(const Entry: TMCPCatalogEntry;
                            out HeaderValue: string;
                            out EnvWasSet: Boolean): Boolean;
var
  Tok: string;
begin
  Result := False;
  HeaderValue := '';
  EnvWasSet := False;

  if (Entry.EnvVar = '') or (Entry.AuthFmt = '') then
  begin
    { No auth required. Both out vars stay empty / False; True
      return tells the caller "we resolved the header to empty
      intentionally". }
    EnvWasSet := True;
    Result := True;
    Exit;
  end;

  Tok := GetEnvironmentVariable(Entry.EnvVar);
  EnvWasSet := Tok <> '';
  if not EnvWasSet then Exit;

  HeaderValue := Format(Entry.AuthFmt, [Tok]);
  Result := True;
end;

function FormatAuthHeaderFromToken(const Entry: TMCPCatalogEntry;
                                    const Token: string): string;
begin
  if (Entry.AuthFmt = '') or (Token = '') then
    Result := ''
  else
    Result := Format(Entry.AuthFmt, [Token]);
end;

end.
