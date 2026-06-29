(*
  PasClaw.Gateway.Server - HTTP gateway built on TIdHTTPServer.
  Hosts a small JSON API:

    GET  /v1/health                -> health + version
    GET  /v1/status                -> provider, model, tools, mcp_servers, ...
    GET  /v1/tools                 -> registered tool descriptors
    POST /v1/chat                  -> body has "message", reply has "content"
    POST /v1/chat/completions      -> OpenAI Chat Completions-compatible
                                      (request: {model, messages, ...},
                                       response: {id, choices[{message}], usage}
                                       -- SSE if stream:true is set)
    POST /v1/responses             -> OpenAI Responses-compatible
                                      (request: {model, input, ...},
                                       response: {id, output[{content}], usage})
    POST /mcp                      -> inbound MCP server: JSON-RPC 2.0
                                      over HTTP. Exposes memory_search /
                                      kb_search / session_search / SCARS
                                      live to external MCP hosts (Claude
                                      Desktop, Cursor, Codex CLI). Read-
                                      only by default; --mcp-allow-write
                                      opts in to mutating tools. Aliased
                                      at POST /v1/mcp/rpc so version-
                                      prefixed deployments stay greppable.
    GET  /v1/models                -> OpenAI-compatible model list
    GET  /v1/version               -> build version

  Mirrors a stripped-down pkg/gateway from picoclaw. The `serve` subcommand
  is a focused wrapper for the OpenAI-compatible surface; `gateway` is the
  full feature set with channels.
*)
unit PasClaw.Gateway.Server;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}
{$IFDEF FPC}
  {$CODEPAGE UTF8}
  {$WARN IMPLICIT_STRING_CAST OFF}
  {$WARN IMPLICIT_STRING_CAST_LOSS OFF}
{$ENDIF}

interface

uses
  SysUtils, Classes, SyncObjs,
  IdHTTPServer, IdContext, IdCustomHTTPServer, IdGlobal, IdSocketHandle,
  PasClaw.Config,
  PasClaw.JSON,            { TJsonObject -- ResolveResponsesToolChoice param }
  PasClaw.Providers.Types,
  PasClaw.Providers.Intf,
  PasClaw.Tools.Registry,
  PasClaw.Tools.ToolLoop,  { TToolLoopConfig/Result -- RunCheckpointedLoop sig }
  PasClaw.Agent.AutoRouter.Apply,  { ApplyAutoRoute -- per-turn cheap routing }
  PasClaw.Session.Store,
  PasClaw.Gateway.RelayQueue, { TRelayQueue -- FRelayQueue field type }
  PasClaw.MCP.Server;

type
  { Method-of-object signature any channel (LINE, WhatsApp, Slack Events
    API, …) can register on the gateway via MountWebhook so the model
    can be reached from a public IM platform without spinning a second
    HTTP server. The handler owns its own response: signature check,
    parse, run the agent loop, write the reply object. }
  TWebhookHandler = procedure(AContext: TIdContext;
                              ARequest: TIdHTTPRequestInfo;
                              AResponse: TIdHTTPResponseInfo) of object;

  { Wraps TIdHTTPServer and dispatches requests to handler methods. Pass a
    provider + tool registry in at construction; ownership stays with the
    caller. Stop() blocks until the listener has fully torn down. }
  TGatewayServer = class
  private
    FHTTP:     TIdHTTPServer;
    FCfg:      TConfig;
    FProvider: ILLMProvider;
    FRegistry: TToolRegistry;
    { When True, each request's tool loop carries FCfg as ActiveConfig so
      config-driven tools (web_search/send_message/memory/kb) honour this
      gateway's in-memory config instead of LoadConfig-ing from disk. Set by
      the TPasClawServer component (code-driven / no-disk embed); left False
      for `pasclaw serve` / `pasclaw gateway`, which keep the disk hot-reload. }
    FToolsHonorInMemoryConfig: Boolean;
    FStarted:  Boolean;
    FStopFlag: TEvent;
    FDebugIO:  Boolean;
    (* Relay queue owned by the gateway. Created in Create, registered
       via SetGlobalRelayQueue so TRelayProvider can find it through
       the factory. Freed in Destroy after clearing the global. *)
    FRelayQueue: TRelayQueue;
    (* Live provider hot-swap. FProvider and FFallbacks are rebuilt from config
       on /v1/config write so a provider/model change applies without a
       restart. FApplyLock guards the swap so a request thread reads a
       consistent (primary, fallbacks) pair via SnapshotProviders. *)
    FApplyLock: TCriticalSection;
    FFallbacks: TLLMProviderArray;
    (* Per-process scoped credential. Random hex generated in Create
       once per `pasclaw serve` / `pasclaw gateway` startup. Gates the
       /v1/relay/* surface independently of Cfg.Gateway.Token so an
       untrusted worker (browser tab running third-party WebLLM
       weights, a phone someone else's PasClaw lent us, ...) can be
       handed a credential that pulls relay jobs without unlocking
       /v1/chat / /v1/config / /v1/skills. The main gateway token
       continues to accept everywhere (back-compat); the relay token
       additionally unlocks just the relay endpoints. Exposed to the
       authenticated webui via GET /v1/relay/worker-token so the
       in-tab sandboxed-iframe worker can authenticate without ever
       seeing the main token. Printed loudly on startup so external
       `pasclaw relay` CLIs can use it explicitly if they want
       scoped credentials. *)
    FRelayToken: string;
    FMaxIter:  Integer;
    FWebhookPaths:    TStringList;
    FWebhookHandlers: array of TWebhookHandler;
    { Lazily-built inbound MCP server core. Created on the first
      POST /mcp; lifetime tracks FRegistry. Nil when the registry
      itself is nil (no tools to expose). The gateway exposes the
      MCP surface at /mcp (and aliased at /v1/mcp/rpc to keep
      version-prefixed deployments grep-friendly) so other
      runtimes can consume PasClaw's memory_search / kb_search /
      session_search live, against the same corpus the local CLI
      sees. See PasClaw.MCP.Server for the core. }
    FMCPInbound:     TMCPServerCore;
    FMCPInboundLock: TCriticalSection;
    FMCPAllowMutating: Boolean;
    FMCPAllowList:     array of string;
    FMCPOnly:          Boolean;
    function  GetOrCreateMCPInbound: TMCPServerCore;
    procedure HandleMCPRequest(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    function DispatchWebhook(AContext: TIdContext;
                             ARequest: TIdHTTPRequestInfo;
                             AResponse: TIdHTTPResponseInfo): Boolean;
    procedure OnCommandGet(AContext: TIdContext;
                           ARequest: TIdHTTPRequestInfo;
                           AResponse: TIdHTTPResponseInfo);
    (* OnCommandOther -- Indy routes non-GET/non-POST verbs here.
       Wired so OPTIONS (CORS preflight from browser relay workers)
       gets a proper 204 + Access-Control headers, ahead of the
       bearer-token gate so the preflight succeeds without auth (per
       the CORS spec -- the actual subsequent request still gets
       auth-gated). Codex P2 review on PR #324. *)
    procedure OnCommandOther(AContext: TIdContext;
                             ARequest: TIdHTTPRequestInfo;
                             AResponse: TIdHTTPResponseInfo);
    (* OnParseAuth -- accept every Authorization scheme so Indy's
       TIdCustomHTTPServer doesn't auto-401 with "Basic realm=..." on
       Bearer (or any non-Basic) tokens before OnCommandGet runs.
       Without this, Indy raises EIdHTTPUnsupportedAuthorisationScheme
       on the FIRST byte of an `Authorization: Bearer <tok>` header,
       which is converted to a 401 in its request-loop exception
       handler -- so PasClaw's CheckGatewayAuth middleware never gets
       a chance to validate. PR #246's bearer flow was silently broken
       end-to-end; the web UI dodged it only because gwFetch suppresses
       the Authorization header until a token is stored, and the
       token-less default config never sent one either. The handler
       just sets VHandled := True; real validation stays in
       OnCommandGet via PasClaw.Gateway.Auth.CheckGatewayAuth. *)
    procedure OnParseAuth(AContext: TIdContext;
                          const AAuthType, AAuthData: string;
                          var VUsername, VPassword: string;
                          var VHandled: Boolean);
    procedure HandleHealth(AResp: TIdHTTPResponseInfo);
    procedure HandleVersion(AResp: TIdHTTPResponseInfo);
    procedure HandleStatus(AResp: TIdHTTPResponseInfo);
    procedure HandleTools(AResp: TIdHTTPResponseInfo);
    procedure HandleMCPList(AResp: TIdHTTPResponseInfo);
    procedure HandleCronList(AResp: TIdHTTPResponseInfo);
    procedure HandleSkillsList(AResp: TIdHTTPResponseInfo);
    { Install a skill (POST /v1/skills with a JSON target field) into
      workspace/skills, and remove one (DELETE /v1/skills/<name>). Changes
      apply on the next restart -- the tool registry is built at startup. }
    procedure HandleSkillInstall(ARequest: TIdHTTPRequestInfo;
                                 AResp: TIdHTTPResponseInfo);
    { Search the public skill catalogs (GET /v1/skills/search?q=...) so the
      web UI can browse-and-install instead of pasting a target. Merges
      pasclaw.dev + ClawHub; each result carries its source so the caller
      installs via the matching hub: / clawhub: prefix. }
    procedure HandleSkillSearch(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    procedure HandleSkillRemove(const Doc: string; AResp: TIdHTTPResponseInfo);
    { Agent-authored skill approval surface (self-improving skills).
      GET  /v1/skills/pending          -- list staged skills + their diffs
      POST /v1/skills/pending/approve  -- commit one (JSON body: id)
      POST /v1/skills/pending/reject   -- discard one (JSON body: id)
      Bearer-gated like every other /v1/* route. Approvals take effect
      on the next restart -- the registry is built at startup. }
    procedure HandleSkillsPending(AResp: TIdHTTPResponseInfo);
    procedure HandleSkillPendingAction(const Approve: Boolean;
                                       ARequest: TIdHTTPRequestInfo;
                                       AResp: TIdHTTPResponseInfo);
    { Knowledge-base browse + ingest for the web UI. GET /v1/kb lists the
      indexed sources and totals; POST /v1/kb/upload writes a document into
      workspace/kb-files and (re)indexes it; GET /v1/kb/search?q= runs the
      same FTS/vector search the kb_search tool uses. }
    { GET /v1/workspace/export -- stream $PASCLAW_HOME/workspace as a zip
      download. Deliberately scoped to workspace/ (NOT the whole home) so
      config.json secrets and oauth tokens at the home root are never
      shipped. }
    procedure HandleWorkspaceExport(AResp: TIdHTTPResponseInfo);
    { POST /v1/workspace/import -- accept a raw application/zip body and
      overlay it onto $PASCLAW_HOME/workspace. Merge semantics: files in
      the archive overwrite their counterparts; existing files the archive
      doesn't mention are left alone. Zip-slip is rejected by
      ExtractZipToDir's entry validation before anything is written. }
    procedure HandleWorkspaceImport(ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo);
    procedure HandleKBList(AResp: TIdHTTPResponseInfo);
    procedure HandleKBUpload(ARequest: TIdHTTPRequestInfo;
                             AResp: TIdHTTPResponseInfo);
    procedure HandleKBSearch(ARequest: TIdHTTPRequestInfo;
                             AResp: TIdHTTPResponseInfo);
    procedure HandleMemoryList(AResp: TIdHTTPResponseInfo);
    { GET /v1/memory/search?q= -- BM25 (or hybrid vector) search over the
      workspace memory markdown, the same index memory_search exposes to
      the model. The .md files are the source of truth; the SQLite index is
      a rebuildable cache, so this just surfaces existing search. }
    procedure HandleMemorySearch(ARequest: TIdHTTPRequestInfo;
                                 AResp: TIdHTTPResponseInfo);
    procedure HandleMemoryRead(const Doc: string;
                                ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    { Distilled-fact store management for the web Memory tab (Phase 5b).
      GET /v1/memory/facts[?all=1] -- list; POST -- manually remember;
      DELETE /v1/memory/facts/<id> -- forget; GET .../export -- Markdown. }
    procedure HandleMemoryFactsList(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    procedure HandleMemoryFactAdd(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    procedure HandleMemoryFactDelete(const IdStr: string;
                                AResp: TIdHTTPResponseInfo);
    procedure HandleMemoryFactsExport(AResp: TIdHTTPResponseInfo);
    procedure HandleConfig(AResp: TIdHTTPResponseInfo);
    { PUT /v1/config -- persist an edited config from the web UI. Secrets
      sent back as the mask placeholder are preserved from the current
      config (client can set keys, never view them). Writes config.json;
      changes apply on the next restart. }
    procedure HandleConfigWrite(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    { Lock-guarded snapshot of the live provider state (rebuilt on config write):
      primary, fallback chain, and default model copied together so a swap can't
      split them across a starting request. }
    procedure SnapshotRuntime(out Prim: ILLMProvider; out FB: TLLMProviderArray;
                              out DefModel: string);
    { Rebuild + swap the live provider/fallbacks from a saved config. Returns
      False (and keeps the current provider) if the new primary won't build. }
    function ApplyProviderConfig(NewCfg: TConfig): Boolean;
    procedure HandleStats(AResp: TIdHTTPResponseInfo);
    { Durable chat sessions, shared with the TUI / `pasclaw session`
      via PasClaw.Session.Store -- web chats land in the same
      $PASCLAW_HOME/workspace/sessions/*.json files and are resumable
      from the terminal. List + create on /v1/sessions; read / replace
      / delete one on /v1/sessions/<id>. }
    procedure HandleSessionsList(AResp: TIdHTTPResponseInfo);
    procedure HandleSessionCreate(ARequest: TIdHTTPRequestInfo;
                                  AResp: TIdHTTPResponseInfo);
    procedure HandleSessionItem(const Doc: string;
                                ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    { Read a request's POST body as a UTF-8 string ('' when none). }
    function  ReadRequestBody(ARequest: TIdHTTPRequestInfo): string;
    { Fill S.Messages + title/model/provider from a messages/title/model
      JSON body and Save. Raises on invalid JSON; caller maps to 400. }
    procedure SaveSessionFromBody(S: TSession; const Body: string);
    { pasclaw.dev Code Vault browse (read-only). Search on /v1/vault?q=,
      read one entry's detail on /v1/vault/<slug>. Proxies the server-side
      PasClaw.Vault.Client so the browser needn't reach pasclaw.dev directly. }
    procedure HandleVaultSearch(ARequest: TIdHTTPRequestInfo;
                                AResp: TIdHTTPResponseInfo);
    procedure HandleVaultGet(const Doc: string; AResp: TIdHTTPResponseInfo);
    procedure HandleFSList(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleFSRead(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleFSDownload(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleFSPeek(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleCheckpointsList(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleCheckpointsUndo(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    procedure HandleCheckpointsRedo(ARequest: TIdHTTPRequestInfo;
                            AResp: TIdHTTPResponseInfo);
    { Read the X-PasClaw-Session header (the active chat) and select this
      thread's per-session checkpoint context. The turn body is then bracketed
      with Acquire/ReleaseCheckpointTurn so same-session requests serialize
      while different sessions overlap. }
    function ReqSessionId(ARequest: TIdHTTPRequestInfo): string;
    procedure ApplyCheckpointSession(const ReqSession: string);
    { ApplyCheckpointSession(reqSession) + BeginTurn + RunToolLoop, serialized
      per session via that context's turn lock when checkpoints are on. }
    function RunCheckpointedLoop(const ReqSession: string;
                            const Cfg: TToolLoopConfig;
                            var Messages: array of TMessage;
                            out Loop: TToolLoopResult): Boolean;
    procedure HandleLogs(AContext: TIdContext;
                          ARequest: TIdHTTPRequestInfo;
                          AResp: TIdHTTPResponseInfo);
    (* Relay endpoints. PasClaw.Gateway.RelayQueue + PasClaw.Providers.Relay
       form the in-process side; these three handlers are the HTTP
       surface workers connect to. SSE for long-polling, JSON POST for
       responses, JSON GET for status. See docs/providers-relay.md. *)
    procedure HandleRelayPoll(AContext: TIdContext;
                               ARequest: TIdHTTPRequestInfo;
                               AResp: TIdHTTPResponseInfo);
    procedure HandleRelayRespond(const ReqId: string;
                                  ARequest: TIdHTTPRequestInfo;
                                  AResp: TIdHTTPResponseInfo);
    procedure HandleRelayStatus(ARequest: TIdHTTPRequestInfo;
                                 AResp: TIdHTTPResponseInfo);
    (* Exposes the per-process relay-scoped token (FRelayToken) to the
       authenticated webui so the in-tab sandboxed worker can poll
       /v1/relay/poll without ever holding the main gateway token.
       Gated by the MAIN token via the normal auth check -- only the
       trusted UI surface can read it. *)
    procedure HandleRelayWorkerToken(ARequest: TIdHTTPRequestInfo;
                                      AResp: TIdHTTPResponseInfo);
    (* Dual-token check helper -- True when the request targets
       /v1/relay/* (except /worker-token) AND the bearer/query
       token matches FRelayToken. The auth gate consults this
       AFTER the main-token check fails, so the main token still
       works everywhere and the relay token adds scoped access. *)
    function RelayTokenAuthorises(const Doc, AuthHeader, QueryToken: string): Boolean;
    (* Cross-origin support for the relay endpoints. Browser workers
       served from a different origin than the gateway (the documented
       case: a local WebLLM page pointing at a remote gateway) get
       blocked by CORS before the gateway's bearer / worker-id checks
       run. EmitRelayCors stamps Access-Control-Allow-Origin (and
       friends) on the response so the browser lets the
       EventSource / fetch through. The bearer token still gates
       access; CORS is purely about whether the browser surfaces the
       response to JS. Codex P2 review on PR #324. *)
    procedure EmitRelayCors(ARequest: TIdHTTPRequestInfo;
                             AResp: TIdHTTPResponseInfo);
    procedure HandleRelayOptionsPreflight(ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
    procedure HandleChat(ARequest: TIdHTTPRequestInfo; AResp: TIdHTTPResponseInfo);
    procedure HandleChatCompletions(AContext: TIdContext;
                                    ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo;
                                    out AWasStreamingRequest: Boolean;
                                    out AResponseStarted: Boolean);
    procedure HandleResponses(AContext: TIdContext;
                              ARequest: TIdHTTPRequestInfo;
                              AResp: TIdHTTPResponseInfo;
                              out AWasStreamingRequest: Boolean;
                              out AResponseStarted: Boolean);
    procedure HandleModels(AResp: TIdHTTPResponseInfo);
    { POST /v1/embeddings -- OpenAI-compatible embeddings computed with
      PasClaw's local ONNX model (no outbound call; vectors never leave the
      host). 503 when the model isn't provisioned. }
    procedure HandleEmbeddings(ARequest: TIdHTTPRequestInfo;
                               AResp: TIdHTTPResponseInfo);
    { GET /v1/providers/catalog -- the static provider catalog (names, default
      base/model, auth requirement) so the web onboarding wizard can offer a
      provider picker without hardcoding the list client-side. No secrets. }
    procedure HandleProvidersCatalog(AResp: TIdHTTPResponseInfo);
    procedure WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
    { TGatewayServer.WriteSSE removed -- never called. The streaming
      response paths build their SSE frames via TSSEStreamer +
      TLogStreamWriter (which has its own WriteSSE on a different
      class). Codex dcc64 H2219 cleanup. }
  public
    constructor Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
    destructor  Destroy; override;
    { When True every request to /v1/chat/completions logs its full body
      and the response body via LogDebug. Off by default; the `serve`
      subcommand flips it on with --debug. }
    property DebugIO: Boolean read FDebugIO write FDebugIO;
    { Opt-in: thread this gateway's in-memory FCfg into each request's tool
      loop so config-driven tools honour it instead of LoadConfig-ing from
      disk. The TPasClawServer component sets this True for a code-driven /
      no-disk embed; bare `serve` leaves it False to keep disk hot-reload. }
    property ToolsHonorInMemoryConfig: Boolean
      read FToolsHonorInMemoryConfig write FToolsHonorInMemoryConfig;
    { Cap on tool-loop iterations for /v1/chat/completions. Defaults to 25
      to match what typical code agents need for read-debug-edit cycles;
      legacy /v1/chat keeps its 8-iteration cap unchanged. }
    property MaxIter: Integer read FMaxIter write FMaxIter;
    { Random per-process token that gates /v1/relay/* in addition to
      the main Cfg.Gateway.Token. Printed at startup so external
      `pasclaw relay` workers can use scoped credentials; surfaced
      to the trusted webui via GET /v1/relay/worker-token so the
      in-tab sandboxed worker can authenticate without seeing the
      main token. Regenerates every Create. }
    property RelayToken: string read FRelayToken;
    { MCP inbound server policy. SetMCPAllowMutating(True) lets the
      inbound /mcp surface expose tcMutating tools (fs_write, shell,
      fs_edit_hashline) too -- off by default. SetMCPAllowList
      restricts exposure to a fixed name list (in addition to the
      mutating gate). Both invalidate any existing core so the next
      request sees the new policy. }
    procedure SetMCPAllowMutating(V: Boolean);
    procedure SetMCPAllowList(const Names: array of string);
    { When True, this gateway responds only to /mcp / /v1/mcp/rpc
      (and the bare GET / health probes); every other route 404s.
      Used when --mcp-port spins up a second listener dedicated to
      the MCP surface so a heavy /v1/responses streaming load
      can't compete with MCP requests for Indy worker threads. }
    procedure SetMCPOnly(V: Boolean);
    procedure Start(const BindAddr: string; Port: Integer);
    procedure Stop;
    procedure WaitForStop;
    { Channel webhook registration. Adds an exact-match POST route at Path
      that runs Handler when a client POSTs to it. Handlers must respond
      with 401 for unauthenticated requests; the dispatcher does not
      authenticate on its behalf. Mount must be called before Start so
      the route is in place when Indy binds. }
    procedure MountWebhook(const Path: string; Handler: TWebhookHandler);
  end;

(* Accumulate one stateless-endpoint turn into its per-endpoint
   stats bucket session (`_gateway_v1_chat` / `_gateway_v1_chat_
   completions` / `_gateway_v1_responses`). Exposed via the
   interface so a regression test can pin the contract -- the
   helper is the only path through which the gateway's
   stateless HTTP traffic reaches /v1/stats. *)
procedure AccumulateGatewayStatsRaw(const Cfg: TConfig;
                                    const BucketId, Title: string;
                                    const ProviderName, Model: string;
                                    const Usage: TUsageInfo;
                                    ToolCallsDispatched: Int64;
                                    TruncatedBytesSaved: Int64);

(* True when Path is a secret-bearing file the operator-facing /v1/fs
   browse must neither list nor serve. config.json holds cleartext
   provider api_keys, the gateway bearer token, mcp env, and the
   web_search key -- GET /v1/config masks all of those, but the raw file
   would leak them. Also hides .env files and TLS private keys that
   commonly sit beside it. Matches the resolved config path exactly
   (honours $PASCLAW_CONFIG) plus a basename denylist. On Unix it follows
   symlinks/hardlinks so an innocuously-named alias to the config cannot
   slip past the lexical compare. Exposed for tests. *)
function IsRestrictedFsPath(const Path: string): Boolean;

(* Resolve a /v1/responses request's tool_choice into the
   TChatOptions.ToolChoice convention: '' when absent/unrecognised (the
   provider default applies), 'auto'/'none'/'required', or a tool NAME to
   force. Accepts the keyword string form and both object forms that name
   a function -- the Responses API's flat top-level "name", and the
   Chat-Completions nested function.name. Exposed for tests. *)
function ResolveResponsesToolChoice(Req: TJsonObject): string;

implementation

uses
  DateUtils,
  {$IFDEF FPC}{$IFDEF UNIX}BaseUnix,{$ENDIF}{$ENDIF}
  IdTCPConnection,
  PasClaw.Logger,
  PasClaw.Utils,
  PasClaw.Crypto.HMAC,        { Base64ToBytes -- decode binary KB uploads }
  PasClaw.Crypto.Random,      { GetRandomBytes -- per-process relay token }
  PasClaw.Skills.Loader,
  PasClaw.Skills.Pending,
  PasClaw.Skills.Zip,       { PackDirToZip -- workspace export download }
  PasClaw.Skills.Install,   { InstallSkillTarget / RemoveSkillFiles / IsSafeSkillName }
  PasClaw.Skills.ClawHub,  { SearchClawHub -- catalog search (clawhub.ai) }
  PasClaw.Skills.PasClawHub, { SearchPasClawHub -- catalog search (pasclaw.dev) }
  PasClaw.KB.Index,        { IKBIndex -- /v1/kb list / upload / search }
  PasClaw.Memory.Index,    { IMemoryIndex / NewMemoryIndex -- /v1/memory/search }
  PasClaw.Memory.Vector,   { NewVectorMemoryIndex -- hybrid memory search }
  { PasClaw.Gateway.RelayQueue is in the interface uses clause -- needed
    there because TGatewayServer's FRelayQueue field references the
    type. Don't re-import here. }
  PasClaw.Tools.Sandbox,
  PasClaw.Checkpoints,          { web UI checkpoints: Init/BeginTurn/Undo/Redo/state }
  PasClaw.Memory.AutoDistill,   { opt-in per-turn fact distillation }
  PasClaw.Memory.Facts,         { fact store for the web Memory tab (Phase 5b) }
  PasClaw.Memory.Distill,       { TFact + NormaliseFact for manual remember }
  PasClaw.Memory.Facts.Embed,   { Phase 4c: semantic fact embedder }
  PasClaw.Providers.Factory,
  PasClaw.Providers.Catalog,   { TProviderSpec for /v1/models discovery }
  PasClaw.Providers.Models,    { DiscoverModels / cache -- /v1/models roster }
  PasClaw.Stream.Reliability,
  PasClaw.Agent.Compact,
  PasClaw.Agent.Prompt,
  PasClaw.Agent.Mode,
  PasClaw.Identity,
  PasClaw.Vault.Client,     { SearchVault / GetVaultEntry -- /v1/vault browse }
  PasClaw.Gateway.ToolView,
  PasClaw.Gateway.WebUI,
  PasClaw.Gateway.Auth,     { CheckGatewayAuth -- bearer-token middleware
                              fired at the top of OnCommandGet. Off when
                              Cfg.Gateway.Token is empty (the default);
                              when set, every non-exempt route requires
                              `Authorization: Bearer <token>` or
                              `?token=<token>` and returns 401 otherwise. }
  PasClaw.Otel;             { http.server.request span wrapping every
                              inbound /v1/* call. Parent context comes
                              from the incoming traceparent header (W3C
                              Trace Context) when present, so an upstream
                              caller's trace stays connected to the agent
                              turn that gets kicked off by this request. }

var
  { Process-wide cache for the /v1/stats response. Walking the
    sessions directory + summing the per-session counters is fine
    for "low hundreds" of sessions, expensive for thousands.
    Five-second TTL keeps the UI's auto-refresh free while still
    surfacing fresh numbers when the operator hits /stats directly
    after a turn. Reset to (0, '') on first call.

    No lock: the gateway's request handling is single-threaded
    through OnCommandGet, so reads and writes here are serialised.
    A future async refactor would need to wrap this in a critical
    section. }
  GStatsCacheUntil:    TDateTime = 0;
  GStatsCacheBody:     string    = '';
  GStatsCacheTtlSecs:  Integer   = 5;

  { Mutex around the per-endpoint stats sessions
    (_gateway_v1_chat / _gateway_v1_chat_completions /
    _gateway_v1_responses). Each gateway request that completes
    reads-modifies-writes its bucket's session file; without this
    a concurrent pair of /v1/chat/completions calls could land
    in the load-accumulate-save race and lose one turn's worth
    of counters. Single lock is fine: the work inside is a
    tiny TSession.Save (one fwrite of a few KB), bucket
    contention is low, and contention across buckets is rare in
    practice (operators tend to use one endpoint at a time). }
  GGatewayStatsLock: TCriticalSection = nil;

const
  { Bucket session ids. These are real session JSON files written
    under $PASCLAW_HOME/workspace/sessions/ -- HandleStats walks
    that directory so they show up in /v1/stats totals without
    any aggregator changes. The leading underscore is intentional
    (IsSafeSessionId allows it) so they sort to the top of the
    sidebar and are visually distinct from operator-named
    sessions. The web UI shows the Title we set on first save
    ("(gateway: /v1/chat/completions)" etc.), so even when an
    operator clicks one in the sidebar the purpose is obvious. }
  GW_BUCKET_V1_CHAT             = '_gateway_v1_chat';
  GW_BUCKET_V1_CHAT_COMPLETIONS = '_gateway_v1_chat_completions';
  GW_BUCKET_V1_RESPONSES        = '_gateway_v1_responses';

procedure AccumulateGatewayStatsRaw(const Cfg: TConfig;
                                    const BucketId, Title: string;
                                    const ProviderName, Model: string;
                                    const Usage: TUsageInfo;
                                    ToolCallsDispatched: Int64;
                                    TruncatedBytesSaved: Int64);
{ Field-shape primitive. The Loop-shape overload below just unpacks
  TToolLoopResult into these fields; passthrough call sites that
  don't have a Loop (the /v1/responses HasFunctionTools branch
  goes straight to FProvider.Chat / ChatStream, no RunToolLoop)
  call this directly with the provider's own usage.

  Codex P2 on PR #204 caught that the Loop-only signature meant
  the Codex/openai-style /v1/responses traffic with client tools
  silently bypassed accumulation, leaving the _gateway_v1_responses
  bucket stuck at zero for that endpoint's main flow. }
var
  S: TSession;
begin
  if not Cfg.StatsCollectionEnabled then Exit;
  if BucketId = '' then Exit;
  GGatewayStatsLock.Enter;
  try
    S := TSession.Create(BucketId);
    try
      if (not S.MetaExists) and (S.Meta.Title = '') then
        S.Meta.Title := Title;
      if Model        <> '' then S.Meta.Model    := Model;
      if ProviderName <> '' then S.Meta.Provider := ProviderName;
      AccumulateTurnStats(S.Meta,
                          Usage.InputTokens,
                          Usage.OutputTokens,
                          Usage.CacheReadTokens,
                          Usage.CacheCreatedTokens,
                          ToolCallsDispatched,
                          TruncatedBytesSaved);
      S.Touch;
      S.Save;
    finally
      S.Free;
    end;
  finally
    GGatewayStatsLock.Leave;
  end;
end;

procedure AccumulateGatewayStats(const Cfg: TConfig;
                                 const BucketId, Title: string;
                                 const ProviderName, Model: string;
                                 const Loop: TToolLoopResult);
{ Per-endpoint stats bucket for stateless gateway requests. The
  gateway's chat / chat-completions / responses endpoints don't
  carry session state across requests (OpenAI-compatible APIs
  are stateless by convention), so we'd otherwise see no entries
  at /v1/stats for those paths. Bucketing by endpoint folds every
  request through that endpoint into one synthetic session whose
  Turns / tokens / tool-calls counters accumulate across calls.

  Trade-off: by_model and by_provider rollups for these bucket
  sessions reflect the MOST RECENT request, not every request --
  Meta.Model and Meta.Provider are scalar. A precise per-model
  breakdown would need either (a) one bucket per (endpoint,
  model) pair, or (b) a richer schema. The user explicitly asked
  for the simpler aggregate-per-endpoint shape; this is that.

  Thread safety: a global TCriticalSection (inside the Raw
  primitive below) serialises the open-accumulate-save sequence.
  Two concurrent calls to the same endpoint would otherwise race
  the file. Bucket granularity is fine for the contention we
  expect (operator driving one tab at a time); per-bucket locks
  could come later if a multi-tenant deploy showed contention. }
begin
  AccumulateGatewayStatsRaw(Cfg, BucketId, Title, ProviderName, Model,
                            Loop.TotalUsage,
                            Loop.ToolCallsDispatched,
                            Loop.TruncatedBytesSaved);
end;

function GenerateRelayWorkerToken: string;
(* Crockford base32, 8 chars in two 4-char groups, hyphen-separated.
   Format detailed at the FRelayToken assignment site below. Picks
   each output char from 32 alphabet entries -- since 256/32 = 8
   exactly, `Bytes[i] and $1F` (low 5 bits) is uniform without
   modulo bias. *)
const
  ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';   { Crockford base32; no I/L/O/U }
var
  B: TBytes;
  i: Integer;
  S: string;
begin
  B := GetRandomBytes(8);
  S := '';
  for i := 0 to High(B) do
    S := S + ALPHABET[(B[i] and $1F) + 1];
  Result := Copy(S, 1, 4) + '-' + Copy(S, 5, 4);
end;

function NormaliseTokenForCompare(const S: string): string;
(* Crockford base32 is case-insensitive on input by convention --
   operators dictating "A8M9-PXRT" over the phone may key it as
   "a8m9-pxrt" or "A8M9PXRT" (no hyphen). Normalise both sides to
   uppercase + stripped hyphens before constant-time compare. *)
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    if S[i] <> '-' then
      Result := Result + UpCase(S[i]);
end;

function CheckpointSessionId(const ReqSession: string): string;
{ Per-chat checkpoint timeline, ALWAYS namespaced by the workspace. Sessions are
  global under $PASCLAW_HOME/workspace/sessions, but checkpoint snapshots store
  absolute paths -- so the same chat id used from two different workspaces must
  NOT share an archive (else undo in workspace B could rewrite A's files). Key =
  FNV-1a of the canonical workspace path + the (sanitised) chat id; a brand-new
  unsaved chat with no id falls back to the per-workspace timeline alone. }
var
  Ws, Clean, WsHash, San: string;
  c: Char;
  H: LongWord;
  i: Integer;
begin
  Ws := CurrentWorkspace;
  if Ws = '' then Ws := GetHome;
  H := 2166136261;
  for i := 1 to Length(Ws) do
  begin
    H := H xor Ord(Ws[i]);
    H := H * 16777619;
  end;
  WsHash := LowerCase(IntToHex(H, 8));

  Clean := Trim(ReqSession);
  if Clean = '' then
    Exit('_gateway_' + WsHash);   { per-workspace fallback }

  { Sanitise the chat id to a filesystem-safe dir name (ids are tame, but never
    trust a header). }
  San := '';
  for i := 1 to Length(Clean) do
  begin
    c := Clean[i];
    if ((c >= 'A') and (c <= 'Z')) or ((c >= 'a') and (c <= 'z')) or
       ((c >= '0') and (c <= '9')) or (c = '-') or (c = '_') or (c = '.') then
      San := San + c
    else
      San := San + '_';
  end;
  Result := 'sess_' + WsHash + '_' + Copy(San, 1, 64);
end;

constructor TGatewayServer.Create(Cfg: TConfig; Provider: ILLMProvider; Registry: TToolRegistry);
var
  CC: TCheckpointConfig;
begin
  inherited Create;
  FCfg      := Cfg;
  FProvider := Provider;
  FRegistry := Registry;
  FMaxIter  := 25;
  { Wire the per-turn checkpoint system into the gateway (it was CLI/TUI-only).
    Init with the per-workspace fallback session; each request re-scopes to its
    chat's session id (X-PasClaw-Session) via ApplyCheckpointSession, then
    serializes its turn on that session's own turn lock. Different sessions run
    concurrently. No-op when disabled. }
  CC.Enabled   := FCfg.CheckpointsEnabled;
  CC.SessionId := CheckpointSessionId('');
  CC.Root      := JoinPath(GetHome, 'workspace/checkpoints');
  CC.KeepLast  := FCfg.CheckpointsKeepLast;
  InitCheckpoints(CC);
  { Phase 4c: best-effort load the local embedder so distilled-fact dedup
    and memory_search run semantically. No-op when distill is off or the
    ONNX artifacts aren't provisioned (keeps the keyword/exact tiers). }
  if FCfg.MemoryDistillEnabled then
    EnableFactEmbeddings(GetHome);
  FStopFlag := TEvent.Create(nil, True, False, '');
  FWebhookPaths := TStringList.Create;
  FWebhookPaths.CaseSensitive := False;
  SetLength(FWebhookHandlers, 0);
  FHTTP := TIdHTTPServer.Create(nil);
  FHTTP.OnCommandGet := OnCommandGet;
  FHTTP.OnCommandOther := OnCommandOther;
  FHTTP.OnParseAuthentication := OnParseAuth;
  FHTTP.KeepAlive    := True;
  FHTTP.ServerSoftware := 'PasClaw/' + FormatVersion;
  FMCPInbound       := nil;
  FMCPInboundLock   := TCriticalSection.Create;
  FMCPAllowMutating := False;
  SetLength(FMCPAllowList, 0);

  { Relay queue. Always created -- the catalog `relay` provider gets
    a working queue whether or not the operator wired any relay
    workers. When no workers ever connect, TRelayProvider.Chat()
    times out cleanly (5 min default) and the fallback walker kicks
    in. The global-accessor pattern is what connects this queue to
    TRelayProvider instances built by PasClaw.Providers.Factory --
    the factory can't take the queue through NewProviderFromConfig's
    signature because it doesn't know about the gateway. }
  FRelayQueue := TRelayQueue.Create;
  SetGlobalRelayQueue(FRelayQueue);

  { Live provider hot-swap state. Cache the fallback chain now (relay queue is
    registered above, so a relay fallback resolves) -- rebuilt on config write. }
  FApplyLock := TCriticalSection.Create;
  FFallbacks := ResolveFallbacks(FCfg);

  { Generate a fresh per-process relay-scoped token. Format is
    phone-typable: two 4-char groups separated by a hyphen
    (e.g. A8M9-PXRT) drawn from Crockford base32
    -- 0123456789ABCDEFGHJKMNPQRSTVWXYZ, 32 chars omitting the
    confusable I/L/O/U. 8 chars * 5 bits/char = 40 bits of entropy
    (~1 trillion combos). At a sustained 10k req/s brute-force --
    well above what any HTTP gateway will tolerate without rate
    limiting or operator notice -- exhausting the space takes 3.5
    years. Combined with the relay-only scope of the token (a
    compromised one can only pull jobs and POST responses, not
    impersonate against /v1/chat or /v1/config or /v1/skills), 40
    bits is the right trade for phone-typability.

    EOSRandomFailure from /dev/urandom / CryptGenRandom is fatal --
    without an unguessable token the scoping is pointless. Let it
    bubble up to the caller; serve/gateway both abort cleanly on
    Create exceptions. }
  FRelayToken := GenerateRelayWorkerToken;
end;

destructor TGatewayServer.Destroy;
begin
  Stop;
  FHTTP.Free;
  FStopFlag.Free;
  FWebhookPaths.Free;
  if FMCPInbound <> nil then FMCPInbound.Free;
  FMCPInboundLock.Free;
  { Clear the global before freeing the queue so a TRelayProvider
    that's racing Destroy can't dereference a freed pointer. }
  SetGlobalRelayQueue(nil);
  FRelayQueue.Free;
  FApplyLock.Free;
  inherited Destroy;
end;

procedure TGatewayServer.SnapshotRuntime(out Prim: ILLMProvider;
  out FB: TLLMProviderArray; out DefModel: string);
{ Copy the primary provider, fallback chain, AND default model together under
  the lock so a concurrent ApplyProviderConfig swap can't tear them apart -- a
  request must not end up sending the new model to the old provider (or vice
  versa) if a live /v1/config save lands mid-setup. The returned interfaces are
  refcounted, so an in-flight request that grabbed them keeps running on that
  provider even after a swap; the switch only affects requests that start
  afterwards. Nothing in flight is interrupted. }
begin
  FApplyLock.Acquire;
  try
    Prim     := FProvider;
    FB       := Copy(FFallbacks);
    DefModel := FCfg.DefaultModel;
  finally
    FApplyLock.Release;
  end;
end;

function TGatewayServer.ApplyProviderConfig(NewCfg: TConfig): Boolean;
{ Rebuild the primary + fallback chain from a freshly-saved config and swap them
  in, so a provider/model change over /v1/config takes effect without a restart.
  The relay queue global is registered in Create, so a relay primary rebuilds
  fine. Everything is built OUTSIDE the lock; only the pointer swap is guarded. }
var
  NewProv: ILLMProvider;
  NewFB: TLLMProviderArray;
  Err: string;
begin
  Result := False;
  if not NewDefaultProvider(NewCfg, NewProv, Err) then
  begin
    LogWarn('gateway: live provider rebuild failed (%s) -- keeping current; restart to apply',
            [Err]);
    Exit;
  end;
  NewFB := ResolveFallbacks(NewCfg);
  FApplyLock.Acquire;
  try
    FProvider  := NewProv;
    FFallbacks := NewFB;
    { Keep the in-memory display/model fields in step so /v1/status and the
      legacy /v1/chat model reflect the switch immediately. }
    FCfg.DefaultProvider := NewCfg.DefaultProvider;
    FCfg.DefaultModel    := NewCfg.DefaultModel;
  finally
    FApplyLock.Release;
  end;
  LogInfo('gateway: provider switched live to %s / %s',
          [NewCfg.DefaultProvider, NewCfg.DefaultModel]);
  Result := True;
end;

procedure TGatewayServer.SetMCPAllowMutating(V: Boolean);
{ Opt-in: when True, the inbound MCP server exposes mutating tools
  (fs_write / shell / fs_edit_hashline) too. Off by default because
  letting a foreign MCP host call fs_write on the operator's box is
  exactly the bad outcome the sandbox layer exists to prevent.

  Call BEFORE Start: the operator-facing wiring in Cmd.Serve /
  Cmd.Gateway does exactly this, so the policy is locked in before
  any /mcp request can race the setter. We invalidate any
  pre-built core for completeness, but freeing it while a request
  thread holds a pointer to it would be a use-after-free -- callers
  that change the policy at runtime must serialise externally. }
begin
  FMCPInboundLock.Acquire;
  try
    FMCPAllowMutating := V;
    if FMCPInbound <> nil then
    begin
      FMCPInbound.Free;
      FMCPInbound := nil;
    end;
  finally
    FMCPInboundLock.Release;
  end;
end;

procedure TGatewayServer.SetMCPAllowList(const Names: array of string);
var
  i: Integer;
begin
  FMCPInboundLock.Acquire;
  try
    SetLength(FMCPAllowList, Length(Names));
    for i := 0 to High(Names) do FMCPAllowList[i] := Names[i];
    if FMCPInbound <> nil then
    begin
      FMCPInbound.Free;
      FMCPInbound := nil;
    end;
  finally
    FMCPInboundLock.Release;
  end;
end;

procedure TGatewayServer.SetMCPOnly(V: Boolean);
begin
  FMCPOnly := V;
end;

function TGatewayServer.GetOrCreateMCPInbound: TMCPServerCore;
begin
  FMCPInboundLock.Acquire;
  try
    if (FMCPInbound = nil) and (FRegistry <> nil) then
    begin
      FMCPInbound := TMCPServerCore.Create(FRegistry, FMCPAllowMutating,
                                            FormatVersion);
      if Length(FMCPAllowList) > 0 then
        FMCPInbound.SetAllowList(FMCPAllowList);
    end;
    Result := FMCPInbound;
  finally
    FMCPInboundLock.Release;
  end;
end;

procedure TGatewayServer.MountWebhook(const Path: string; Handler: TWebhookHandler);
var
  Idx: Integer;
begin
  Idx := FWebhookPaths.IndexOf(Path);
  if Idx >= 0 then
  begin
    FWebhookHandlers[Idx] := Handler;
    Exit;
  end;
  FWebhookPaths.Add(Path);
  SetLength(FWebhookHandlers, FWebhookPaths.Count);
  FWebhookHandlers[FWebhookPaths.Count - 1] := Handler;
  LogInfo('gateway: mounted webhook %s', [Path]);
end;

function TGatewayServer.DispatchWebhook(AContext: TIdContext;
                                         ARequest: TIdHTTPRequestInfo;
                                         AResponse: TIdHTTPResponseInfo): Boolean;
var
  Idx: Integer;
  Handler: TWebhookHandler;
begin
  { Dispatch on path only. Handlers self-check the verb because some
    channels (WhatsApp Cloud) bind both GET -- subscription
    verification with hub.challenge echo -- and POST -- event delivery
    -- to the same URL. Handlers MUST emit 405 for verbs they don't
    accept so the dispatcher doesn't silently 404 a legitimate
    request. LINE's HandleWebhook does that; so does WhatsApp's. }
  Result := False;
  Idx := FWebhookPaths.IndexOf(ARequest.Document);
  if Idx < 0 then Exit;
  Handler := FWebhookHandlers[Idx];
  if not Assigned(Handler) then Exit;
  Handler(AContext, ARequest, AResponse);
  Result := True;
end;

procedure TGatewayServer.Start(const BindAddr: string; Port: Integer);
var
  Binding: TIdSocketHandle;
begin
  if FStarted then Exit;
  FHTTP.Bindings.Clear;
  Binding := FHTTP.Bindings.Add;
  Binding.IP   := BindAddr;
  Binding.Port := Port;
  FHTTP.Active := True;
  FStarted := True;
  LogInfo('gateway: listening on http://%s:%d', [BindAddr, Port]);
  (* Auth-state summary at startup. Only the primary listener prints
     it; the optional MCP companion listener shares the same FCfg, so
     a second copy would be noise. The MISCONFIGURED branch in
     particular is the typo trap that motivates the line -- operators
     misspelling PASCLAW_GATEWAY_TOKEN as PASCAL_GATEWAY_TOKEN end up
     with the literal "${PASCLAW_GATEWAY_TOKEN}" template stuck in
     Cfg.Gateway.Token, and the gateway will reject every client
     bearer until the env var is renamed. *)
  if not FMCPOnly then
    LogInfo('%s', [DescribeGatewayAuthState(FCfg)]);
end;

procedure TGatewayServer.Stop;
begin
  if not FStarted then Exit;
  try
    FHTTP.Active := False;
  except
    on E: Exception do LogWarn('gateway: stop error: %s', [E.Message]);
  end;
  FStarted := False;
  FStopFlag.SetEvent;
  LogInfo('gateway: stopped');
end;

procedure TGatewayServer.WaitForStop;
begin
  FStopFlag.WaitFor(INFINITE);
end;

procedure WriteBodyStream(AResp: TIdHTTPResponseInfo; const Body: string);
var
  Strm: TMemoryStream;
  Bytes: TBytes;
  Tagged: string;
begin
  { Indy's ContentText writer on FPC + UTF-8 doesn't always flush a body
    correctly. ContentStream is the reliable path: encode the string to bytes
    ourselves, hand Indy a TMemoryStream sized in bytes, and let it stream.

    The TagUTF8 call is defence-in-depth: PasClaw.Providers.HTTP already
    tags response bodies at the boundary, but anywhere a CP_0 string slips
    through (an unimported source literal, a third-party path we add later)
    TEncoding.UTF8.GetBytes would double-encode it via the system codepage.
    Tagging here keeps the wire bytes honest regardless of upstream tag. }
  Tagged := Body;
  TagUTF8(Tagged);
  Bytes := TEncoding.UTF8.GetBytes(Tagged);
  Strm := TMemoryStream.Create;
  if Length(Bytes) > 0 then
    Strm.WriteBuffer(Bytes[0], Length(Bytes));
  Strm.Position := 0;
  AResp.ContentStream     := Strm;
  AResp.FreeContentStream := True;
  AResp.ContentLength     := Strm.Size;
end;

procedure TGatewayServer.WriteJSON(AResp: TIdHTTPResponseInfo; Code: Integer; const Body: string);
begin
  AResp.ResponseNo  := Code;
  AResp.ContentType := 'application/json; charset=utf-8';
  AResp.CharSet     := 'utf-8';
  WriteBodyStream(AResp, Body);
end;

procedure TGatewayServer.HandleMCPRequest(ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
{ Inbound MCP server entry. Reads one JSON-RPC request from the POST
  body, dispatches via TMCPServerCore, writes the response (or 204
  for notifications). One-shot per request; no SSE / streaming -- the
  MCP Streamable HTTP spec allows a plain JSON response, and that's
  enough for the read-corpus surface we expose. Server-pushed
  notifications (the optional GET /mcp side of the transport) is a
  follow-up. }
var
  Body: string;
  Bytes: TBytes;
  Core: TMCPServerCore;
  RespLine: string;
begin
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;
  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400,
      '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"empty body"}}');
    Exit;
  end;
  if FDebugIO then
    LogDebug('mcp <- %s', [Copy(Body, 1, 200)]);

  Core := GetOrCreateMCPInbound;
  if Core = nil then
  begin
    WriteJSON(AResp, 503,
      '{"jsonrpc":"2.0","id":null,"error":{"code":-32603,"message":"no tool registry"}}');
    Exit;
  end;

  { The MCP core dispatches tools/call straight through FRegistry.RunTool --
    it does NOT go through the agent loop's DispatchOneToolCall, so publish
    the active config on this request thread here too, otherwise an external
    /mcp caller's config-driven tools (memory_search/kb_search/web_search)
    would LoadConfig from disk even for a no-disk embed. Thread-scoped +
    cleared in finally, same contract as DispatchOneToolCall. }
  if FToolsHonorInMemoryConfig then SetActiveConfig(FCfg);
  try
    RespLine := Core.HandleRequest(Body);
  finally
    if FToolsHonorInMemoryConfig then SetActiveConfig(nil);
  end;
  if RespLine = '' then
  begin
    { Notification path -- spec says no body. 204 No Content. }
    AResp.ResponseNo  := 204;
    AResp.ContentText := '';
    Exit;
  end;
  if FDebugIO then
    LogDebug('mcp -> %s', [Copy(RespLine, 1, 200)]);
  WriteJSON(AResp, 200, RespLine);
end;

{ TGatewayServer.WriteSSE removed -- dead method, see class
  declaration. dcc64 H2219 cleanup. }

procedure TGatewayServer.OnParseAuth(AContext: TIdContext;
                                     const AAuthType, AAuthData: string;
                                     var VUsername, VPassword: string;
                                     var VHandled: Boolean);
begin
  (* Accept ALL schemes -- Bearer, plus anything an operator's
     middleware might prepend later. Indy's default DoParseAuthentication
     handles Basic itself before this fires; everything else falls
     through to us. Setting VHandled := True keeps Indy from raising
     EIdHTTPUnsupportedAuthorisationScheme (which it would auto-convert
     to a 401 in the request-loop exception handler at
     IdCustomHTTPServer.pas:1476, before OnCommandGet runs). PasClaw's
     real bearer check lives in OnCommandGet via CheckGatewayAuth, so
     leaving VUsername / VPassword empty is fine -- the AuthHeader is
     still on ARequest.RawHeaders and CheckGatewayAuth pulls it from
     there directly. PR #255 follow-up to fix PR #246's silent break.

     AContext is not used here, but the parameter is part of Indy's
     TIdHTTPParseAuthenticationEvent signature; we keep it named for
     readability and reference it once to silence the "unused" hint. *)
  if AContext = nil then ;       { silence unused-param hint }
  if AAuthType = '' then ;       { likewise }
  if AAuthData = '' then ;
  VUsername := '';
  VPassword := '';
  VHandled  := True;
end;

procedure TGatewayServer.OnCommandGet(AContext: TIdContext;
                                     ARequest: TIdHTTPRequestInfo;
                                     AResponse: TIdHTTPResponseInfo);
var
  Doc: string;
  IsChatCompletionsStream: Boolean;
  ResponseStarted: Boolean;
  HttpSpan: TOtelSpan;
  ParentTP: string;
begin
  Doc := ARequest.Document;
  IsChatCompletionsStream := False;
  ResponseStarted := False;
  LogDebug('gateway: %s %s', [ARequest.Command, Doc]);

  { Tier-4 instrumentation: wrap the whole inbound request in an
    http.server span. ParentTP is the incoming W3C Trace Context
    header (typically set by an OTel-instrumented client upstream);
    when absent we start a new trace right here. Each Indy worker
    thread runs OnCommandGet on its own thread, and Otel's
    threadvar current-span stack scopes child agent.turn /
    chat / execute_tool spans to this request without cross-thread
    bleed. }
  ParentTP := ARequest.RawHeaders.Values['traceparent'];
  HttpSpan := StartSpan('HTTP ' + ARequest.Command + ' ' + Doc,
                        oskServer, ParentTP);
  try
    SetAttrStr(HttpSpan, 'http.request.method', ARequest.Command);
    SetAttrStr(HttpSpan, 'url.path',            Doc);
    SetAttrStr(HttpSpan, 'http.route',          Doc);

  { Bearer-token gate. No-op when Cfg.Gateway.Token is empty
    (the default -- preserves the unauthenticated shape every
    pre-token deployment relied on). When the token IS set,
    every non-exempt route requires `Authorization: Bearer
    <token>` OR `?token=<token>` and gets a 401 otherwise.
    Exempt routes: /, /v1/health, /v1/version, /webhooks/* --
    rationale in PasClaw.Gateway.Auth's unit comment. The check
    fires BEFORE the FMCPOnly early-exit below so the --mcp-port
    isolation listener honours the same token.

    Dual-token rule for /v1/relay/*: in addition to the main token,
    the per-process FRelayToken also unlocks the relay surface.
    That lets the trusted webui hand a SCOPED credential to the
    sandboxed in-tab WebLLM worker (and to external `pasclaw
    relay` CLIs that prefer least-privilege) without unlocking
    /v1/chat / /v1/config / /v1/skills. If the relay token leaks
    to a compromised worker, the worst they can do is pull jobs
    and POST responses -- they can't impersonate the operator
    against the rest of the API. }
  if (not CheckGatewayAuth(GetEffectiveGatewayToken(FCfg),
                            ARequest.Command, Doc,
                            ARequest.RawHeaders.Values['Authorization'],
                            ARequest.Params.Values['token']))
     and not RelayTokenAuthorises(Doc,
                                   ARequest.RawHeaders.Values['Authorization'],
                                   ARequest.Params.Values['token']) then
  begin
    SetAttrInt(HttpSpan, 'http.response.status_code', 401);
    SetStatus(HttpSpan, oscError, 'unauthorized');
    { WWW-Authenticate names the scheme + realm so a stock
      OpenAI client sees a recognisable challenge rather than a
      bare 401. realm is informational only -- no realm-specific
      auth scheme behind it. WriteJSON below sets ResponseNo. }
    AResponse.CustomHeaders.AddValue('WWW-Authenticate', 'Bearer realm="pasclaw"');
    WriteJSON(AResponse, 401,
              '{"error":"unauthorized","message":"missing or invalid bearer token"}');
    Exit;
  end;

  { MCP-only listener: when this gateway was spun up as the
    --mcp-port companion, the only routes it honours are the
    inbound MCP endpoints plus a minimal health probe. Everything
    else 404s -- the operator wired the second listener for
    isolation, and silently fanning out /v1/chat traffic to it
    would defeat the purpose. }
  if FMCPOnly then
  begin
    if (ARequest.Command = 'POST') and
       ((Doc = '/mcp') or (Doc = '/v1/mcp/rpc')) then
      HandleMCPRequest(ARequest, AResponse)
    else if (ARequest.Command = 'GET') and (Doc = '/v1/health') then
      HandleHealth(AResponse)
    else
      WriteJSON(AResponse, 404, '{"error":"mcp-only listener; route not found"}');
    Exit;
  end;

  try
    if      (ARequest.Command = 'GET')  and (Doc = '/v1/health')  then HandleHealth(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/version') then HandleVersion(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/status')  then HandleStatus(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/tools')   then HandleTools(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/chat')    then HandleChat(ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/chat/completions') then
      HandleChatCompletions(AContext, ARequest, AResponse, IsChatCompletionsStream, ResponseStarted)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/responses') then
      HandleResponses(AContext, ARequest, AResponse, IsChatCompletionsStream, ResponseStarted)
    else if (ARequest.Command = 'POST') and ((Doc = '/mcp') or (Doc = '/v1/mcp/rpc')) then
      HandleMCPRequest(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/models')  then HandleModels(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/embeddings') then HandleEmbeddings(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/providers/catalog') then HandleProvidersCatalog(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/mcp')     then HandleMCPList(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/cron')    then HandleCronList(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/skills/search') then HandleSkillSearch(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/skills/pending') then HandleSkillsPending(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/skills/pending/approve') then HandleSkillPendingAction(True, ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/skills/pending/reject')  then HandleSkillPendingAction(False, ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/skills')  then HandleSkillsList(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/skills')  then HandleSkillInstall(ARequest, AResponse)
    else if (ARequest.Command = 'DELETE') and (Copy(Doc, 1, 11) = '/v1/skills/') then HandleSkillRemove(Doc, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/kb/search') then HandleKBSearch(ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/kb/upload') then HandleKBUpload(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/workspace/export') then HandleWorkspaceExport(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/workspace/import') then HandleWorkspaceImport(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/kb')       then HandleKBList(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/memory/search') then HandleMemorySearch(ARequest, AResponse)
    { Distilled-fact routes -- BEFORE the generic /v1/memory/ GET prefix so
      "facts" isn't mistaken for a markdown filename. }
    else if (ARequest.Command = 'GET')    and (Doc = '/v1/memory/facts/export') then HandleMemoryFactsExport(AResponse)
    else if (ARequest.Command = 'GET')    and (Doc = '/v1/memory/facts') then HandleMemoryFactsList(ARequest, AResponse)
    else if (ARequest.Command = 'POST')   and (Doc = '/v1/memory/facts') then HandleMemoryFactAdd(ARequest, AResponse)
    else if (ARequest.Command = 'DELETE') and (Copy(Doc, 1, 17) = '/v1/memory/facts/') then
      HandleMemoryFactDelete(Copy(Doc, 18, MaxInt), AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/memory')  then HandleMemoryList(AResponse)
    else if (ARequest.Command = 'GET')  and (Copy(Doc, 1, 11) = '/v1/memory/') then
      HandleMemoryRead(Doc, ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/config')  then HandleConfig(AResponse)
    else if (ARequest.Command = 'PUT')  and (Doc = '/v1/config')  then HandleConfigWrite(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/stats')   then HandleStats(AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/sessions') then HandleSessionsList(AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/sessions') then HandleSessionCreate(ARequest, AResponse)
    else if (Copy(Doc, 1, 13) = '/v1/sessions/') then HandleSessionItem(Doc, ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/vault') then HandleVaultSearch(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Copy(Doc, 1, 10) = '/v1/vault/') then HandleVaultGet(Doc, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/fs')      then HandleFSList(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/fs/read') then HandleFSRead(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/fs/download') then HandleFSDownload(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/fs/peek') then HandleFSPeek(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/checkpoints')      then HandleCheckpointsList(ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/checkpoints/undo') then HandleCheckpointsUndo(ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Doc = '/v1/checkpoints/redo') then HandleCheckpointsRedo(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/logs')    then HandleLogs(AContext, ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/relay/poll') then
      HandleRelayPoll(AContext, ARequest, AResponse)
    else if (ARequest.Command = 'POST') and (Copy(Doc, 1, 18) = '/v1/relay/respond/') then
      HandleRelayRespond(Copy(Doc, 19, MaxInt), ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/relay/status') then
      HandleRelayStatus(ARequest, AResponse)
    else if (ARequest.Command = 'GET')  and (Doc = '/v1/relay/worker-token') then
      HandleRelayWorkerToken(ARequest, AResponse)
    else if Doc = '/' then
    begin
      AResponse.ResponseNo  := 200;
      AResponse.ContentType := 'text/html; charset=utf-8';
      AResponse.CharSet     := 'utf-8';
      { Hand Indy a raw byte stream loaded from the embedded resource -- no
        string encoding involved. }
      AResponse.ContentStream     := WebUIStream;
      AResponse.FreeContentStream := True;
      AResponse.ContentLength     := AResponse.ContentStream.Size;
    end
    else if Doc = '/v1' then
      WriteJSON(AResponse, 200,
        '{"name":"pasclaw","routes":["/v1/health","/v1/version","/v1/status","/v1/tools","/v1/chat","/v1/chat/completions","/v1/responses","/v1/models","/v1/embeddings"]}')
    else if not DispatchWebhook(AContext, ARequest, AResponse) then
      WriteJSON(AResponse, 404, '{"error":"not found","path":"' + Doc + '"}');
  except
    on E: Exception do
    begin
      LogError('gateway: handler crashed: %s', [E.Message]);
      SetStatus(HttpSpan, oscError, E.ClassName + ': ' + E.Message);
      if IsChatCompletionsStream and (ResponseStarted or AResponse.HeaderHasBeenWritten) then
      begin
        LogWarn('gateway: streaming response already started; closing connection');
        if (AContext <> nil) and (AContext.Connection <> nil) then
        begin
          try
            AContext.Connection.Disconnect;
          except
            on EDisconnect: Exception do
              LogWarn('gateway: failed to close streaming connection: %s', [EDisconnect.Message]);
          end;
        end;
      end
      else if not AResponse.HeaderHasBeenWritten then
        WriteJSON(AResponse, 500, '{"error":"internal","message":"' + E.Message + '"}')
      else if (AContext <> nil) and (AContext.Connection <> nil) then
        AContext.Connection.Disconnect;
    end;
  end;
  finally
    SetAttrInt(HttpSpan, 'http.response.status_code', AResponse.ResponseNo);
    if (AResponse.ResponseNo >= 200) and (AResponse.ResponseNo < 400) then
      SetStatus(HttpSpan, oscOk, '')
    else if HttpSpan <> nil then
      SetStatus(HttpSpan, oscError,
                'HTTP ' + IntToStr(AResponse.ResponseNo));
    FinishSpan(HttpSpan);
  end;
end;

procedure TGatewayServer.OnCommandOther(AContext: TIdContext;
                                        ARequest: TIdHTTPRequestInfo;
                                        AResponse: TIdHTTPResponseInfo);
(* Non-GET/non-POST verbs land here. Indy's TIdHTTPServer routes
   GET/POST/HEAD through OnCommandGet and everything else (PUT,
   DELETE, OPTIONS, PATCH, ...) through OnCommandOther. When this
   handler was unassigned (the historical state), Indy fell back to
   firing OnCommandGet for those verbs too -- which is how the
   existing PUT /v1/config, DELETE /v1/skills/*, and the
   /v1/sessions/* PUT/DELETE handlers in the OnCommandGet dispatch
   block ever ran.

   Wiring this handler for the OPTIONS preflight case (Codex P2 on
   PR #324) broke that fallback -- PUT and DELETE traffic started
   getting a 405 instead of reaching their handlers, killing
   settings save / session delete / skill remove from the web UI.
   Codex P1 review on PR #327.

   Fix: handle OPTIONS preflights for /v1/relay/* here (they MUST
   NOT carry credentials per the CORS spec, so they go BEFORE the
   bearer-token gate) and delegate everything else to OnCommandGet
   so the existing dispatch block runs. The catch-all 404 inside
   OnCommandGet's dispatch handles truly-unknown verb+path pairs. *)
var
  Doc: string;
begin
  Doc := ARequest.Document;
  if (ARequest.Command = 'OPTIONS') and
     (Pos('/v1/relay/', Doc) = 1) then
  begin
    HandleRelayOptionsPreflight(ARequest, AResponse);
    Exit;
  end;
  OnCommandGet(AContext, ARequest, AResponse);
end;

procedure TGatewayServer.HandleHealth(AResp: TIdHTTPResponseInfo);
begin
  WriteJSON(AResp, 200, '{"status":"ok","version":"' + FormatVersion + '"}');
end;

procedure TGatewayServer.HandleVersion(AResp: TIdHTTPResponseInfo);
begin
  WriteJSON(AResp, 200, '{"version":"' + FormatVersion + '","build":"' + FormatBuildInfo + '"}');
end;

procedure TGatewayServer.HandleStatus(AResp: TIdHTTPResponseInfo);
var
  J: TJsonObject;
begin
  J := TJsonObject.Create;
  try
    J.PutStr('default_provider', FCfg.DefaultProvider);
    J.PutStr('default_model',    FCfg.DefaultModel);
    J.PutInt('providers',        Length(FCfg.Providers));
    J.PutInt('mcp_servers',      Length(FCfg.MCPServers));
    J.PutInt('crons',            Length(FCfg.Crons));
    J.PutInt('skills',           Length(FCfg.Skills));
    if FRegistry <> nil then J.PutInt('tools', FRegistry.Count)
    else                     J.PutInt('tools', 0);
    WriteJSON(AResp, 200, J.ToJSON);
  finally
    J.Free;
  end;
end;

procedure TGatewayServer.HandleTools(AResp: TIdHTTPResponseInfo);
var
  Root, ToolObj: TJsonObject;
  Arr: TJsonArray;
  Defs: TToolDefinitionArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    if FRegistry <> nil then
    begin
      Defs := FRegistry.ToProviderDefs;
      for i := 0 to High(Defs) do
      begin
        ToolObj := TJsonObject.Create;
        ToolObj.PutStr('name',        Defs[i].Name);
        ToolObj.PutStr('description', Defs[i].Description);
        ToolObj.PutStr('schema',      Defs[i].Schema);
        Arr.AddObject(ToolObj);
      end;
    end;
    Root.PutArray('tools', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleMCPList(AResp: TIdHTTPResponseInfo);
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(FCfg.MCPServers) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr ('name',    FCfg.MCPServers[i].Name);
      Item.PutStr ('cmd',     FCfg.MCPServers[i].Cmd);
      Item.PutStr ('args',    FCfg.MCPServers[i].Args);
      Item.PutBool('enabled', FCfg.MCPServers[i].Enabled);
      Arr.AddObject(Item);
    end;
    Root.PutArray('servers', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleCronList(AResp: TIdHTTPResponseInfo);
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(FCfg.Crons) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr ('id',             FCfg.Crons[i].Id);
      Item.PutStr ('spec',           FCfg.Crons[i].Spec);
      Item.PutStr ('skill',          FCfg.Crons[i].Skill);
      Item.PutStr ('args',           FCfg.Crons[i].Args);
      Item.PutBool('enabled',        FCfg.Crons[i].Enabled);
      Item.PutStr ('channel_kind',   FCfg.Crons[i].ChannelKind);
      Item.PutStr ('channel_target', FCfg.Crons[i].ChannelTarget);
      Arr.AddObject(Item);
    end;
    Root.PutArray('entries', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

function SkillRemovableId(const Spec: TSkillSpec): string;
{ The on-disk basename DELETE /v1/skills/<id> targets. It is NOT the
  frontmatter name: GitHub installs land under their repo/subpath segment,
  which can differ from the SKILL.md `name:`. RemoveSkillFiles deletes
  workspace/skills/<id>/ (SKILL.md skills) or <id>.json (legacy skills),
  so derive <id> from the directory segment, or the file stem for .json. }
begin
  if HasSuffix(LowerCase(Spec.Source), '.json') then
    Result := ChangeFileExt(ExtractFileName(Spec.Source), '')
  else
    Result := ExtractFileName(ExcludeTrailingPathDelimiter(Spec.Dir));
end;

procedure TGatewayServer.HandleSkillsList(AResp: TIdHTTPResponseInfo);
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  Skills: TSkillSpecArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Skills := LoadSkillManifests(GetHome);
    for i := 0 to High(Skills) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('name',        Skills[i].Name);
      Item.PutStr('id',          SkillRemovableId(Skills[i]));
      Item.PutStr('description', Skills[i].Description);
      Item.PutStr('kind',        Skills[i].Kind);
      Item.PutStr('path',        Skills[i].Source);
      Item.PutStr('dir',         Skills[i].Dir);
      Arr.AddObject(Item);
    end;
    Root.PutArray('skills', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleSkillsPending(AResp: TIdHTTPResponseInfo);
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  Pend: TPendingSkillArray;
  i: Integer;
  Content, Err: string;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Pend := ListPending(GetHome);
    for i := 0 to High(Pend) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr('id',      Pend[i].Id);
      Item.PutStr('action',  Pend[i].Action);
      Item.PutStr('name',    Pend[i].Name);
      Item.PutStr('created', Pend[i].Created);
      { Inline the proposed SKILL.md so the web UI can show a preview
        without a second round-trip. }
      if ReadPending(GetHome, Pend[i].Id, Content, Err) then
        Item.PutStr('content', Content)
      else
        Item.PutStr('content', '');
      Arr.AddObject(Item);
    end;
    Root.PutArray('pending', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleSkillPendingAction(const Approve: Boolean;
                                                  ARequest: TIdHTTPRequestInfo;
                                                  AResp: TIdHTTPResponseInfo);
var
  Body, Id, Err: string;
  O: TJsonObject;
  Ok: Boolean;
begin
  Body := ReadRequestBody(ARequest);
  Id := '';
  if Body <> '' then
  begin
    O := TJsonObject.Parse(Body);
    if O <> nil then
    try
      Id := Trim(O.GetStr('id', ''));
    finally
      O.Free;
    end;
  end;
  if Id = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing id"}');
    Exit;
  end;
  if Approve then Ok := ApprovePending(GetHome, Id, FCfg, Err)
  else            Ok := RejectPending(GetHome, Id, Err);
  if Ok then
    WriteJSON(AResp, 200, '{"status":"ok","id":"' + JsonEscape(Id) + '"}')
  else
    WriteJSON(AResp, 400, '{"error":"' + JsonEscape(Err) + '"}');
end;

procedure TGatewayServer.HandleSkillInstall(ARequest: TIdHTTPRequestInfo;
                                            AResp: TIdHTTPResponseInfo);
var
  Body, Target, Name, Err, DestRoot: string;
  Req, Root: TJsonObject;
begin
  Body := ReadRequestBody(ARequest);
  Target := '';
  if Trim(Body) <> '' then
  begin
    Req := TJsonObject.Parse(Body);
    if Req <> nil then
    try
      Target := Trim(Req.GetStr('target', ''));
    finally
      Req.Free;
    end;
  end;
  if Target = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing field: target"}');
    Exit;
  end;
  DestRoot := JoinPath(GetHome, 'workspace/skills');
  if not InstallSkillTarget(Target, DestRoot, Name, Err) then
  begin
    WriteJSON(AResp, 502, '{"error":"' + JsonEscape(Err) + '"}');
    Exit;
  end;
  LogInfo('gateway: installed skill %s via /v1/skills', [Name]);
  Root := TJsonObject.Create;
  try
    Root.PutStr('installed', Name);
    Root.PutStr('note', 'installed -- restart pasclaw to load it into the tool registry');
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleSkillSearch(ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
var
  Query, ErrP, ErrC: string;
  Limit, i: Integer;
  PRes: TPasClawHubResultArray;
  CRes: TClawHubResultArray;
  OkP, OkC: Boolean;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  Seen: TStringList;

  procedure AddResult(const Slug, Display, Summary, Version, Source: string;
                      Score: Double);
  begin
    { Dedupe across the two registries; pasclaw.dev is added first so it
      wins, matching the bare-slug install precedence. Enforce the total
      Limit on the MERGED set -- forwarding Limit to each backend and
      concatenating would otherwise return up to 2x Limit. pasclaw.dev
      fills the budget first, ClawHub takes whatever slots remain. }
    if (Slug = '') or (Arr.Count >= Limit) or (Seen.IndexOf(LowerCase(Slug)) >= 0) then Exit;
    Seen.Add(LowerCase(Slug));
    Item := TJsonObject.Create;
    Item.PutStr  ('slug',         Slug);
    Item.PutStr  ('display_name', Display);
    Item.PutStr  ('summary',      Summary);
    Item.PutStr  ('version',      Version);
    Item.PutFloat('score',        Score);
    Item.PutStr  ('source',       Source);  { 'hub' (pasclaw.dev) | 'clawhub' }
    Arr.AddObject(Item);
  end;

begin
  Query := Trim(ARequest.Params.Values['q']);
  if Query = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing query parameter: q"}');
    Exit;
  end;
  Limit := StrToIntDef(ARequest.Params.Values['limit'], 20);
  if Limit <= 0 then Limit := 20;
  if Limit > 50 then Limit := 50;

  { Search both registries the install path knows (pasclaw.dev first, then
    ClawHub). Each runs its own HTTP with its own timeout; one failing
    doesn't sink the other -- only a total miss is an error. }
  OkP := SearchPasClawHub(Query, Limit, PRes, ErrP);
  OkC := SearchClawHub   (Query, Limit, CRes, ErrC);

  if (not OkP) and (not OkC) then
  begin
    WriteJSON(AResp, 502, '{"error":"' +
      JsonEscape('skill catalog search failed: ' + ErrP + ' / ' + ErrC) + '"}');
    Exit;
  end;

  Seen := TStringList.Create;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    if OkP then
      for i := 0 to High(PRes) do
        AddResult(PRes[i].Slug, PRes[i].DisplayName, PRes[i].Summary,
                  PRes[i].Version, 'hub', PRes[i].Score);
    if OkC then
      for i := 0 to High(CRes) do
        AddResult(CRes[i].Slug, CRes[i].DisplayName, CRes[i].Summary,
                  CRes[i].Version, 'clawhub', CRes[i].Score);
    Root.PutArray('results', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
    Seen.Free;
  end;
end;

{ A safe leaf filename for an uploaded KB document: no path separators,
  no '..', a small allow-list of characters. The handler also runs the
  value through ExtractFileName first, so this is belt-and-suspenders
  against traversal out of workspace/kb-files. }
function IsSafeKBName(const Name: string): Boolean;
var
  i: Integer;
begin
  Result := False;
  if (Name = '') or (Length(Name) > 200) then Exit;
  if (Name = '.') or (Name = '..') or (Pos('..', Name) > 0) then Exit;
  for i := 1 to Length(Name) do
    if not CharInSet(Name[i], ['A'..'Z','a'..'z','0'..'9','.','-','_',' ','(',')']) then Exit;
  Result := True;
end;

procedure TGatewayServer.HandleWorkspaceExport(AResp: TIdHTTPResponseInfo);
{ Pack workspace/ into a zip and stream it as a download. Scoped to
  workspace/ (not the whole home) so config.json / oauth tokens never
  ship. The temp zip is written at the home ROOT (outside workspace) so
  PackDirToZip doesn't try to include the file it's still writing. }
const
  ExcludeFromZip: array[0..3] of string =
    ('.git', '.DS_Store', 'Thumbs.db', 'kb.db-journal');
var
  WsDir, ZipPath, Err: string;
  Strm: TMemoryStream;
  FS: TFileStream;
begin
  WsDir := JoinPath(GetHome, 'workspace');
  if not DirectoryExists(WsDir) then
  begin
    WriteJSON(AResp, 404, '{"error":"no workspace directory yet"}');
    Exit;
  end;
  ZipPath := JoinPath(GetHome,
    'workspace-export-' + FormatDateTime('yyyymmdd-hhnnss', Now) + '.zip');
  { Store entries under a top-level "workspace/" dir so the zip matches
    `pasclaw build`'s whole-home layout -- a web-exported workspace.zip
    then drops straight into `pasclaw build --workspace-in`. }
  if not PackDirToZip(WsDir, ZipPath, ExcludeFromZip, Err, 'workspace') then
  begin
    WriteJSON(AResp, 500, '{"error":"' + JsonEscape('export failed: ' + Err) + '"}');
    Exit;
  end;
  Strm := TMemoryStream.Create;
  try
    try
      FS := TFileStream.Create(ZipPath, fmOpenRead or fmShareDenyWrite);
      try
        if FS.Size > 0 then Strm.CopyFrom(FS, FS.Size);
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        DeleteFile(ZipPath);
        Strm.Free;
        WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
        Exit;
      end;
    end;
  finally
    DeleteFile(ZipPath);   { bytes are in memory now; drop the temp file }
  end;
  Strm.Position := 0;
  AResp.ResponseNo  := 200;
  AResp.ContentType := 'application/zip';
  AResp.CustomHeaders.AddValue('Content-Disposition', 'attachment; filename="workspace.zip"');
  AResp.ContentStream     := Strm;
  AResp.FreeContentStream := True;
  AResp.ContentLength     := Strm.Size;
  LogInfo('gateway: workspace export -> %d bytes', [Strm.Size]);
end;

{ Recursive delete of a directory tree. Used to clean the import staging
  area; portable across FPC/Delphi (no fileutil / IOUtils dependency). }
procedure WsDeleteTree(const Dir: string);
var
  SR: TSearchRec;
  P: string;
begin
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*',
               faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      P := IncludeTrailingPathDelimiter(Dir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then WsDeleteTree(P)
      else SysUtils.DeleteFile(P);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

{ Recursive merge-copy SrcDir -> DstDir. Files overwrite their
  counterparts; existing files DstDir has that SrcDir lacks are kept
  (overlay semantics). Returns False with Err set on the first failure. }
function WsMergeTree(const SrcDir, DstDir: string; out Err: string): Boolean;
var
  SR: TSearchRec;
  S, D: string;
  FSrc, FDst: TFileStream;
begin
  Result := False; Err := '';
  if not ForceDirectories(DstDir) then
  begin Err := 'cannot create ' + DstDir; Exit; end;
  if FindFirst(IncludeTrailingPathDelimiter(SrcDir) + '*',
               faAnyFile or faDirectory, SR) = 0 then
  try
    repeat
      if (SR.Name = '.') or (SR.Name = '..') then Continue;
      S := IncludeTrailingPathDelimiter(SrcDir) + SR.Name;
      D := IncludeTrailingPathDelimiter(DstDir) + SR.Name;
      if (SR.Attr and faDirectory) <> 0 then
      begin
        if not WsMergeTree(S, D, Err) then Exit;
      end
      else
      try
        FSrc := TFileStream.Create(S, fmOpenRead or fmShareDenyWrite);
        try
          FDst := TFileStream.Create(D, fmCreate);
          try
            if FSrc.Size > 0 then FDst.CopyFrom(FSrc, FSrc.Size);
          finally FDst.Free; end;
        finally FSrc.Free; end;
      except
        on E: Exception do begin Err := 'copy ' + SR.Name + ': ' + E.Message; Exit; end;
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
  Result := True;
end;

procedure TGatewayServer.HandleWorkspaceImport(ARequest: TIdHTTPRequestInfo;
                                               AResp: TIdHTTPResponseInfo);
{ Accept a raw application/zip body and overlay its workspace/ contents
  onto $PASCLAW_HOME/workspace.

  The canonical zip carries a top-level "workspace/" dir (what our export
  emits and what `pasclaw build` packs), so we can't just unzip into
  workspace/ -- that would nest workspace/workspace/. Instead we extract
  to a staging dir at the home root, then merge ONLY staging/workspace ->
  home/workspace. Two payoffs:
    * A full `pasclaw build` zip (which also has sessions/, config.json,
      etc. at the root) imports cleanly -- we take only its workspace/,
      so a stray config.json in the upload can NEVER overwrite the running
      server's secrets.
    * A "bare" zip (files at the root, no workspace/ dir) still works: we
      fall back to merging the whole staging tree.
  ExtractZipToDir zip-slip-validates every entry before writing, and the
  staging dir is deleted regardless of outcome. }
const
  ImportZipCap = Int64(512) * 1024 * 1024;   { 512 MB -- generous; body is buffered }
var
  WsDir, StageDir, SrcWs, ZipPath, Stamp, Err: string;
  FS: TFileStream;
  Size: Int64;
begin
  if ARequest.PostStream = nil then
  begin
    WriteJSON(AResp, 400, '{"error":"missing zip body"}');
    Exit;
  end;
  Size := ARequest.PostStream.Size;
  if Size = 0 then
  begin
    WriteJSON(AResp, 400, '{"error":"empty zip body"}');
    Exit;
  end;
  if Size > ImportZipCap then
  begin
    WriteJSON(AResp, 413, '{"error":"workspace zip too large (max 512 MB)"}');
    Exit;
  end;

  Stamp    := FormatDateTime('yyyymmdd-hhnnss', Now);
  WsDir    := JoinPath(GetHome, 'workspace');
  ZipPath  := JoinPath(GetHome, 'workspace-import-' + Stamp + '.zip');
  StageDir := JoinPath(GetHome, 'workspace-import-stage-' + Stamp);
  try
    try
      FS := TFileStream.Create(ZipPath, fmCreate);
      try
        ARequest.PostStream.Position := 0;
        FS.CopyFrom(ARequest.PostStream, Size);
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        WriteJSON(AResp, 500, '{"error":"' + JsonEscape('save upload: ' + E.Message) + '"}');
        Exit;
      end;
    end;

    if not ExtractZipToDir(ZipPath, StageDir, Err) then
    begin
      WriteJSON(AResp, 400, '{"error":"' + JsonEscape('import failed: ' + Err) + '"}');
      Exit;
    end;

    { Prefer staging/workspace (canonical / build layout); fall back to the
      whole staging tree for a bare zip with files at the root. }
    SrcWs := JoinPath(StageDir, 'workspace');
    if not DirectoryExists(SrcWs) then SrcWs := StageDir;

    if not WsMergeTree(SrcWs, WsDir, Err) then
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape('import failed: ' + Err) + '"}');
      Exit;
    end;
  finally
    SysUtils.DeleteFile(ZipPath);
    WsDeleteTree(StageDir);
  end;

  LogInfo('gateway: workspace import <- %d bytes', [Size]);
  WriteJSON(AResp, 200,
    '{"imported":true,"bytes":' + IntToStr(Size) +
    ',"note":"workspace updated; restart serve/gateway to pick up new skills/config"}');
end;

procedure TGatewayServer.HandleKBList(AResp: TIdHTTPResponseInfo);
var
  Idx: IKBIndex;
  Sources: TKBSourceArray;
  St: TKBStats;
  Root, Stats, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Stats := TJsonObject.Create;
    Idx := NewKBIndex;
    if Idx.Open(DefaultKBDbPath) then
    begin
      Sources := Idx.GetSources;
      for i := 0 to High(Sources) do
      begin
        Item := TJsonObject.Create;
        Item.PutStr('root',     Sources[i].Root);
        Item.PutInt('files',    Sources[i].Files);
        Item.PutInt('chunks',   Sources[i].Chunks);
        Item.PutInt('added_at', Sources[i].AddedAt);
        Arr.AddObject(Item);
      end;
      St := Idx.Stats;
      Stats.PutInt ('sources',      St.Sources);
      Stats.PutInt ('files',        St.Files);
      Stats.PutInt ('chunks',       St.Chunks);
      Stats.PutBool('vector_ready', St.VectorReady);
      Idx := nil;
    end
    else
    begin
      { No index yet -- report an empty corpus so the tab can render its
        "upload your first document" state instead of erroring. }
      Stats.PutInt ('sources', 0); Stats.PutInt('files', 0);
      Stats.PutInt ('chunks',  0); Stats.PutBool('vector_ready', False);
    end;
    Root.PutObject('stats',   Stats);
    Root.PutArray ('sources', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleKBSearch(ARequest: TIdHTTPRequestInfo;
                                        AResp: TIdHTTPResponseInfo);
var
  Query: string;
  K, i: Integer;
  Idx: IKBIndex;
  Hits: TKBHitArray;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
begin
  Query := Trim(ARequest.Params.Values['q']);
  if Query = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing query parameter: q"}');
    Exit;
  end;
  K := StrToIntDef(ARequest.Params.Values['k'], 8);
  if K <= 0 then K := 8;
  if K > 25 then K := 25;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    WriteJSON(AResp, 503,
      '{"error":"knowledge base unavailable (nothing indexed yet, or libsqlite3 missing)"}');
    Exit;
  end;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Hits := Idx.Search(Query, K);
    for i := 0 to High(Hits) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr  ('path',    Hits[i].Path);
      Item.PutInt  ('chunk',   Hits[i].ChunkNo);
      Item.PutStr  ('snippet', Hits[i].Snippet);
      Item.PutFloat('score',   Hits[i].Score);
      Arr.AddObject(Item);
    end;
    Root.PutArray('hits', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
    Idx := nil;
  end;
end;

procedure TGatewayServer.HandleKBUpload(ARequest: TIdHTTPRequestInfo;
                                        AResp: TIdHTTPResponseInfo);
var
  Body, Name, Content, ContentB64, Err, Dir, FilePath: string;
  Req, Root: TJsonObject;
  Idx: IKBIndex;
  Sources: TKBSourceArray;
  i, Files, Chunks: Integer;
  HaveSource, Overwrote, BinaryUpload: Boolean;
  PrevDt, NewDt: TDateTime;
  Bin: TBytes;
  FS: TFileStream;
begin
  Body := ReadRequestBody(ARequest);
  Name := ''; Content := ''; ContentB64 := '';
  if Trim(Body) <> '' then
  begin
    Req := TJsonObject.Parse(Body);
    if Req <> nil then
    try
      Name       := Trim(Req.GetStr('name', ''));
      Content    := Req.GetStr('content', '');
      ContentB64 := Req.GetStr('content_b64', '');
    finally
      Req.Free;
    end;
  end;
  Name := ExtractFileName(Name);   { strip any client-sent path components }
  if (Name = '') or (not IsSafeKBName(Name)) then
  begin
    WriteJSON(AResp, 400, '{"error":"invalid or missing field: name"}');
    Exit;
  end;
  if not KBExtSupported(Name) then
  begin
    WriteJSON(AResp, 415,
      '{"error":"unsupported file type -- the KB indexes text formats (.md, .txt, .pas, source code, ...) and PDFs"}');
    Exit;
  end;
  BinaryUpload := ContentB64 <> '';
  if (not BinaryUpload) and (Content = '') then
  begin
    WriteJSON(AResp, 400, '{"error":"empty content"}');
    Exit;
  end;

  Dir := JoinPath(GetHome, 'workspace/kb-files');
  if not ForceDirectories(Dir) then
  begin
    WriteJSON(AResp, 500, '{"error":"could not create workspace/kb-files"}');
    Exit;
  end;
  FilePath := JoinPath(Dir, Name);
  { Capture the existing mtime before overwriting so we can guarantee the
    new file's mtime advances past it (see the bump below). }
  Overwrote := FileExists(FilePath);
  PrevDt := 0;
  if Overwrote then FileAge(FilePath, PrevDt);
  try
    if BinaryUpload then
    begin
      Bin := Base64ToBytes(ContentB64);
      if Length(Bin) = 0 then
      begin
        WriteJSON(AResp, 400, '{"error":"content_b64 decoded to empty"}');
        Exit;
      end;
      FS := TFileStream.Create(FilePath, fmCreate);
      try
        FS.WriteBuffer(Bin[0], Length(Bin));
      finally
        FS.Free;
      end;
    end
    else
      WriteFileText(FilePath, Content);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  { Codex P2 on PR #284: IKBIndex.Sync only reindexes when the stored mtime
    is strictly < the file's mtime, and filesystem mtime has 1-2s
    granularity. Re-uploading the same filename within that window would
    leave an identical mtime and Sync would skip it, serving stale chunks.
    Force the new mtime strictly past the previously-indexed value so the
    incremental gate always fires on a replace. }
  if Overwrote then
  begin
    NewDt := Now;
    if NewDt < PrevDt then NewDt := PrevDt;
    NewDt := IncSecond(NewDt, 2);   { DOS file dates resolve to 2s }
    FileSetDate(FilePath, DateTimeToFileDate(NewDt));
  end;

  Idx := NewKBIndex;
  if not Idx.Open(DefaultKBDbPath) then
  begin
    WriteJSON(AResp, 503,
      '{"error":"knowledge base unavailable (libsqlite3 missing or path unwritable)"}');
    Exit;
  end;
  Files := 0; Chunks := 0;
  try
    { Register workspace/kb-files as a source once; later uploads just drop
      a file in and re-sync (Sync is mtime-incremental, so it only indexes
      the new/changed file). }
    HaveSource := False;
    Sources := Idx.GetSources;
    for i := 0 to High(Sources) do
      if SameFileName(ExpandFileName(Sources[i].Root), ExpandFileName(Dir)) then
      begin
        HaveSource := True;
        Break;
      end;
    if not HaveSource then
      Idx.AddSource(Dir, Err);   { Sync indexes regardless of Err }
    Idx.Sync(Files, Chunks);
  finally
    Idx := nil;
  end;

  LogInfo('gateway: KB upload %s -- indexed %d file(s), %d chunk(s)', [Name, Files, Chunks]);
  Root := TJsonObject.Create;
  try
    Root.PutStr('uploaded',       Name);
    Root.PutInt('indexed_files',  Files);
    Root.PutInt('indexed_chunks', Chunks);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleSkillRemove(const Doc: string;
                                           AResp: TIdHTTPResponseInfo);
var
  Name, DestRoot: string;
begin
  Name := Copy(Doc, Length('/v1/skills/') + 1, MaxInt);
  if not IsSafeSkillName(Name) then
  begin
    WriteJSON(AResp, 400, '{"error":"unsafe skill name"}');
    Exit;
  end;
  DestRoot := JoinPath(GetHome, 'workspace/skills');
  if RemoveSkillFiles(DestRoot, Name) then
  begin
    LogInfo('gateway: removed skill %s via /v1/skills', [Name]);
    WriteJSON(AResp, 200,
      '{"removed":true,"note":"removed -- restart pasclaw to drop it from the tool registry"}');
  end
  else
    WriteJSON(AResp, 404, '{"error":"not found"}');
end;

procedure TGatewayServer.HandleMemoryList(AResp: TIdHTTPResponseInfo);
var
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  Dir: string;
  SR: TSearchRec;
begin
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    Dir := JoinPath(GetHome, 'workspace/memory');
    if DirectoryExists(Dir) then
    begin
      if FindFirst(JoinPath(Dir, '*.md'), faAnyFile, SR) = 0 then
      try
        repeat
          if (SR.Attr and faDirectory) <> 0 then Continue;
          Item := TJsonObject.Create;
          Item.PutStr('name', SR.Name);
          Item.PutInt('size', SR.Size);
          Arr.AddObject(Item);
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    Root.PutArray('files', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleMemorySearch(ARequest: TIdHTTPRequestInfo;
                                            AResp: TIdHTTPResponseInfo);
const
  DefaultK = 8;
  MaxK     = 25;
var
  Query, Dir, DbBase: string;
  K, i: Integer;
  Idx: IMemoryIndex;
  Hits: TMemoryHitArray;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
begin
  Query := Trim(ARequest.Params.Values['q']);
  if Query = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing query parameter: q"}');
    Exit;
  end;
  K := StrToIntDef(ARequest.Params.Values['k'], DefaultK);
  if K < 1   then K := DefaultK;
  if K > MaxK then K := MaxK;

  Dir := JoinPath(GetHome, 'workspace/memory');
  if not DirectoryExists(Dir) then
  begin
    WriteJSON(AResp, 200, '{"hits":[]}');   { no memory written yet }
    Exit;
  end;
  DbBase := JoinPath(Dir, '.index.db');

  { Mirror Tool_MemorySearch's backend selection: hybrid FTS+vector when
    the operator opted in, else the FTS5-only index. Separate DB files so
    flipping vector_search_enabled doesn't cross-talk schemas. }
  Idx := nil;
  if FCfg.VectorSearchEnabled then
  begin
    Idx := NewVectorMemoryIndex;
    if not Idx.Open(DbBase + '.vec') then Idx := nil;
  end;
  if Idx = nil then
  begin
    Idx := NewMemoryIndex;
    if not Idx.Open(DbBase) then
    begin
      Idx := nil;
      WriteJSON(AResp, 503,
        '{"error":"memory index unavailable (libsqlite3 missing or unreadable)"}');
      Exit;
    end;
  end;
  try
    Idx.SyncDir(Dir);
    Hits := Idx.Search(Query, K);
  finally
    Idx := nil;   { IInterface release closes the DB }
  end;

  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(Hits) do
    begin
      Item := TJsonObject.Create;
      Item.PutStr  ('path',    Hits[i].Path);
      Item.PutStr  ('snippet', Hits[i].Snippet);
      Item.PutFloat('score',   Hits[i].Score);
      Arr.AddObject(Item);
    end;
    Root.PutArray('hits', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleMemoryRead(const Doc: string;
                                            ARequest: TIdHTTPRequestInfo;
                                            AResp: TIdHTTPResponseInfo);
var
  Name, Path, Body: string;
  Root: TJsonObject;
begin
  Name := Copy(Doc, Length('/v1/memory/') + 1, MaxInt);
  { Refuse any path-traversal -- only bare filenames inside the
    memory directory are addressable through this endpoint. }
  if (Name = '') or (Pos('..', Name) > 0) or (Pos('/', Name) > 0) or
     (Pos('\', Name) > 0) then
  begin
    WriteJSON(AResp, 400, '{"error":"bad name"}');
    Exit;
  end;
  Path := JoinPath(JoinPath(GetHome, 'workspace/memory'), Name);
  if not FileExists(Path) then
  begin
    WriteJSON(AResp, 404, '{"error":"not found"}');
    Exit;
  end;
  try
    Body := ReadFileText(Path);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  Root := TJsonObject.Create;
  try
    Root.PutStr('name',    Name);
    Root.PutStr('content', Body);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleMemoryFactsList(ARequest: TIdHTTPRequestInfo;
                                               AResp: TIdHTTPResponseInfo);
{ GET /v1/memory/facts[?all=1] -- the distilled fact store as JSON. }
var
  Store: IFactStore;
  Facts: TStoredFactArray;
  Root, FO: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
  All: Boolean;
  Today: string;
begin
  All := ARequest.Params.Values['all'] = '1';
  Store := NewFactStore;
  { Open creates the DB when merely absent, so a False return is a real
    failure (corrupt/unreadable). Surface it rather than returning an empty
    list that looks like "all facts vanished". Mirrors add/delete. }
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    WriteJSON(AResp, 503, '{"error":"fact store unavailable"}');
    Exit;
  end;
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    if All then Facts := Store.AllFacts else Facts := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;
  Root := TJsonObject.Create;
  try
    Root.PutBool('enabled', FCfg.MemoryDistillEnabled);
    Arr := TJsonArray.Create;
    for i := 0 to High(Facts) do
    begin
      FO := TJsonObject.Create;
      FO.PutInt ('id',         Facts[i].Id);
      FO.PutStr ('text',       Facts[i].Text);
      FO.PutStr ('kind',       Facts[i].Kind);
      FO.PutStr ('scope',      Facts[i].Scope);
      FO.PutStr ('event_date', Facts[i].EventDate);
      FO.PutStr ('expires',    Facts[i].Expires);
      FO.PutBool('superseded', Facts[i].Superseded);
      Arr.AddObject(FO);
    end;
    Root.PutArray('facts', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleMemoryFactAdd(ARequest: TIdHTTPRequestInfo;
                                             AResp: TIdHTTPResponseInfo);
{ POST /v1/memory/facts with a text/kind/scope/expires JSON body -- manual remember. }
var
  Store: IFactStore;
  Obj: TJsonObject;
  F: TFact;
  Id: Int64;
begin
  Obj := nil;
  try
    Obj := TJsonObject.Parse(ReadRequestBody(ARequest));
  except
    Obj := nil;
  end;
  if Obj = nil then
  begin
    WriteJSON(AResp, 400, '{"error":"bad json"}');
    Exit;
  end;
  try
    F.Text          := Trim(Obj.GetStr('text', ''));
    F.Kind          := Obj.GetStr('kind', 'static');
    F.Scope         := Obj.GetStr('scope', 'user');
    F.Confidence    := 1.0;
    F.EventDate     := Obj.GetStr('event_date', '');
    F.Expires       := Obj.GetStr('expires', '');
    F.SourceSession := 'manual-web';
  finally
    Obj.Free;
  end;
  if F.Text = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"text required"}');
    Exit;
  end;
  NormaliseFact(F);
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    WriteJSON(AResp, 500, '{"error":"fact store unavailable"}');
    Exit;
  end;
  try
    Id := Store.Add(F, DateTimeToUnix(Now, False));
  finally
    Store.Close;
  end;
  WriteJSON(AResp, 200, '{"ok":true,"id":' + IntToStr(Id) + '}');
end;

procedure TGatewayServer.HandleMemoryFactDelete(const IdStr: string;
                                                AResp: TIdHTTPResponseInfo);
{ DELETE /v1/memory/facts/<id> -- forget. }
var
  Store: IFactStore;
  Id: Int64;
  Ok: Boolean;
begin
  if not TryStrToInt64(IdStr, Id) then
  begin
    WriteJSON(AResp, 400, '{"error":"bad id"}');
    Exit;
  end;
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    WriteJSON(AResp, 500, '{"error":"fact store unavailable"}');
    Exit;
  end;
  try
    Ok := Store.Delete(Id);
  finally
    Store.Close;
  end;
  if Ok then WriteJSON(AResp, 200, '{"ok":true}')
  else WriteJSON(AResp, 404, '{"error":"no such fact"}');
end;

procedure TGatewayServer.HandleMemoryFactsExport(AResp: TIdHTTPResponseInfo);
{ GET /v1/memory/facts/export -- the store as downloadable Markdown. }
var
  Store: IFactStore;
  Facts: TStoredFactArray;
  Today: string;
begin
  Store := NewFactStore;
  if not Store.Open(DefaultFactsDbPath(GetHome)) then
  begin
    WriteJSON(AResp, 503, '{"error":"fact store unavailable"}');
    Exit;
  end;
  try
    Today := FormatDateTime('yyyy"-"mm"-"dd', Now);
    Facts := Store.ActiveFacts(Today);
  finally
    Store.Close;
  end;
  AResp.ResponseNo := 200;
  AResp.ContentType := 'text/markdown; charset=utf-8';
  AResp.CharSet := 'utf-8';
  AResp.ContentDisposition := 'attachment; filename="memory-facts.md"';
  { WriteBodyStream, not ContentText: Indy's FPC ContentText writer can
    corrupt/drop UTF-8 bodies, and facts are UTF-8 from the UI/API. }
  WriteBodyStream(AResp, FactsToMarkdown(Facts, Today));
end;

procedure TGatewayServer.HandleConfig(AResp: TIdHTTPResponseInfo);
var
  Body: string;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  { Mask secret-bearing fields. PR #88 Codex P1 caught that the
    original implementation only masked providers[].api_key and
    left mcp_servers[].env exposed -- which typically contains
    OPENAI_API_KEY=, GITHUB_TOKEN=, etc. for stdio MCP servers.
    Mask any non-empty secret field with "•••" so the UI can show
    "set vs unset" without leaking the value. }
  Body := FCfg.ToJSON;
  Root := TJsonObject.Parse(Body);
  if Root = nil then
  begin
    WriteJSON(AResp, 500, '{"error":"could not reparse config"}');
    Exit;
  end;
  try
    Arr := Root.ChildArray('providers');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          if Item.GetStr('api_key', '') <> '' then
            Item.PutStr('api_key', MaskedSecretPlaceholder);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    Arr := Root.ChildArray('mcp_servers');
    if Arr <> nil then
    try
      for i := 0 to Arr.Count - 1 do
      begin
        Item := Arr.ItemObject(i);
        if Item = nil then Continue;
        try
          { env strings are typically KEY=value pairs separated by
            newlines or semicolons -- anything from "OPENAI_API_KEY=sk-…"
            to bearer tokens. Mask the whole string when non-empty;
            the UI just needs "is configured" signal, not the literal. }
          if Item.GetStr('env', '') <> '' then
            Item.PutStr('env', MaskedSecretPlaceholder);
        finally
          Item.Free;
        end;
      end;
    finally
      Arr.Free;
    end;

    { gateway.token is the inbound bearer for /v1/* routes. An
      authenticated /v1/config caller would otherwise see the
      shared secret in cleartext -- defeating the read-only-status
      contract this endpoint advertises. Codex P2 on PR #246. }
    Item := Root.ChildObject('gateway');
    if Item <> nil then
    try
      if Item.GetStr('token', '') <> '' then
        Item.PutStr('token', MaskedSecretPlaceholder);
    finally
      Item.Free;
    end;

    { web_search.api_key is a secret too (Brave/Tavily/Perplexity keys);
      it was previously emitted in cleartext. Mask it like the others. }
    Item := Root.ChildObject('web_search');
    if Item <> nil then
    try
      if Item.GetStr('api_key', '') <> '' then
        Item.PutStr('api_key', MaskedSecretPlaceholder);
    finally
      Item.Free;
    end;

    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleConfigWrite(ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
var
  Body, Merged, BaseJSON, Path: string;
  Tmp, Cur: TConfig;
  Applied: Boolean;
begin
  Applied := False;
  Body := ReadRequestBody(ARequest);
  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"empty body"}');
    Exit;
  end;
  { Merge masked secrets against the CURRENT on-disk config, not the
    startup snapshot FCfg. FCfg is never refreshed after a save (config
    changes apply on restart), so using it here would restore stale
    secrets: a second save -- after an earlier save then Reload -- would
    revert any key set in the meantime back to its boot-time value. Read
    config.json directly (resolving env-var markers the same way
    LoadConfig does) without LoadConfig's process-global side effects.
    Fall back to FCfg when the file is missing/unreadable. }
  BaseJSON := FCfg.ToJSON;
  Path := GetConfigPath;
  if FileExists(Path) then
  begin
    Cur := TConfig.Create;
    try
      try
        Cur.FromJSON(ExpandEnvVarsInJSON(ReadFileText(Path)));
        BaseJSON := Cur.ToJSON;
      except
        on E: Exception do { keep the FCfg fallback } ;
      end;
    finally
      Cur.Free;
    end;
  end;
  { Restore masked secrets from the base config so a client that never
    saw the real api_key / env / token values can't blank them by sending
    the mask back. Raises EArgumentException on unparseable JSON. }
  try
    Merged := RestoreMaskedConfigSecrets(Body, BaseJSON);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 400, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  { Validate by round-tripping through TConfig before touching disk, so a
    malformed edit is rejected rather than persisted. }
  Tmp := TConfig.Create;
  try
    try
      Tmp.FromJSON(Merged);
    except
      on E: Exception do
      begin
        WriteJSON(AResp, 400, '{"error":"invalid config: ' + JsonEscape(E.Message) + '"}');
        Exit;
      end;
    end;
    try
      SaveConfig(Tmp);
    except
      on E: Exception do
      begin
        WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
        Exit;
      end;
    end;
    { Hot-swap the primary provider + fallback chain from the just-saved config
      so a provider/model change takes effect without a restart. Built from Tmp
      before it's freed. Other settings (sandbox, mcp, crons) still need a
      restart. }
    Applied := ApplyProviderConfig(Tmp);
  finally
    Tmp.Free;
  end;
  if Applied then
  begin
    LogInfo('gateway: config.json updated via /v1/config (provider applied live)');
    WriteJSON(AResp, 200,
      '{"saved":true,"applied":true,"note":"saved -- provider/model applied live; other settings take effect on restart"}');
  end
  else
  begin
    LogInfo('gateway: config.json updated via /v1/config (restart to apply)');
    WriteJSON(AResp, 200,
      '{"saved":true,"applied":false,"note":"saved to config.json -- restart pasclaw for changes to take effect"}');
  end;
end;

procedure TGatewayServer.HandleStats(AResp: TIdHTTPResponseInfo);
{ Aggregate per-session stats across every session under
  workspace/sessions/ plus a few rollups (by provider, by model)
  that are useful server-wide. Cheap to compute on a personal
  gateway; the 5-second cache hides the cost when the web UI
  auto-refreshes.

  When Cfg.StatsCollectionEnabled is False the rollups will all
  read zero (the per-session counters were never incremented), so
  the response is still valid JSON -- the web UI shows zeros with
  a "stats collection is off" hint instead of breaking. }
var
  Sessions: TSessionMetaArray;
  i: Integer;
  TotalIn, TotalOut, CacheRead, CacheWrite, Turns, ToolCalls, BytesSaved: Int64;
  ByProvider, ByModel: TStringList;
  Idx: Integer;
  Key: string;
  Cur: Int64;
  Root, ProviderObj, ModelObj: TJsonObject;
  ProviderArr, ModelArr: TJsonArray;

  procedure BumpMap(M: TStringList; const K: string; Delta: Int64);
  var
    J: Integer;
    Existing: Int64;
  begin
    if K = '' then Exit;
    J := M.IndexOf(K);
    if J < 0 then M.AddObject(K, TObject(NativeInt(Delta)))
    else
    begin
      Existing := Int64(NativeInt(M.Objects[J]));
      M.Objects[J] := TObject(NativeInt(Existing + Delta));
    end;
  end;

begin
  if Now < GStatsCacheUntil then
  begin
    WriteJSON(AResp, 200, GStatsCacheBody);
    Exit;
  end;

  { IncludeBuckets: the gateway's per-endpoint stats buckets
    (_gateway_v1_*) are hidden from the TUI / `pasclaw session
    list` by default. The aggregator MUST see them or the
    Stats tab loses the entire gateway-API traffic line. }
  Sessions := ListSessions(True);
  TotalIn := 0; TotalOut := 0; CacheRead := 0; CacheWrite := 0;
  Turns := 0; ToolCalls := 0; BytesSaved := 0;
  ByProvider := TStringList.Create;
  ByModel    := TStringList.Create;
  try
    for i := 0 to High(Sessions) do
    begin
      Inc(TotalIn,    Sessions[i].Stats.InputTokens);
      Inc(TotalOut,   Sessions[i].Stats.OutputTokens);
      Inc(CacheRead,  Sessions[i].Stats.CacheReadTokens);
      Inc(CacheWrite, Sessions[i].Stats.CacheCreatedTokens);
      Inc(Turns,      Sessions[i].Stats.Turns);
      Inc(ToolCalls,  Sessions[i].Stats.ToolCalls);
      Inc(BytesSaved, Sessions[i].Stats.TruncationBytesSaved);
      { Bucket "tokens spent" -- in + out -- by provider + model so
        the operator can see which provider is eating the budget. }
      Cur := Sessions[i].Stats.InputTokens + Sessions[i].Stats.OutputTokens;
      BumpMap(ByProvider, Sessions[i].Provider, Cur);
      BumpMap(ByModel,    Sessions[i].Model,    Cur);
    end;

    Root := TJsonObject.Create;
    try
      Root.PutBool('stats_collection_enabled', FCfg.StatsCollectionEnabled);
      Root.PutInt ('sessions',                 Length(Sessions));
      Root.PutInt ('input_tokens',             TotalIn);
      Root.PutInt ('output_tokens',            TotalOut);
      Root.PutInt ('cache_read_tokens',        CacheRead);
      Root.PutInt ('cache_created_tokens',     CacheWrite);
      Root.PutInt ('turns',                    Turns);
      Root.PutInt ('tool_calls',               ToolCalls);
      Root.PutInt ('truncation_bytes_saved',   BytesSaved);

      ProviderArr := TJsonArray.Create;
      try
        for Idx := 0 to ByProvider.Count - 1 do
        begin
          ProviderObj := TJsonObject.Create;
          try
            Key := ByProvider[Idx];
            Cur := Int64(NativeInt(ByProvider.Objects[Idx]));
            ProviderObj.PutStr('provider', Key);
            ProviderObj.PutInt('tokens',   Cur);
            ProviderArr.AddObject(ProviderObj);
          except
            ProviderObj.Free; raise;
          end;
        end;
        Root.PutArray('by_provider', ProviderArr);
      except
        ProviderArr.Free; raise;
      end;

      ModelArr := TJsonArray.Create;
      try
        for Idx := 0 to ByModel.Count - 1 do
        begin
          ModelObj := TJsonObject.Create;
          try
            Key := ByModel[Idx];
            Cur := Int64(NativeInt(ByModel.Objects[Idx]));
            ModelObj.PutStr('model',  Key);
            ModelObj.PutInt('tokens', Cur);
            ModelArr.AddObject(ModelObj);
          except
            ModelObj.Free; raise;
          end;
        end;
        Root.PutArray('by_model', ModelArr);
      except
        ModelArr.Free; raise;
      end;

      GStatsCacheBody  := Root.ToJSON;
      GStatsCacheUntil := IncSecond(Now, GStatsCacheTtlSecs);
      WriteJSON(AResp, 200, GStatsCacheBody);
    finally
      Root.Free;
    end;
  finally
    ByProvider.Free;
    ByModel.Free;
  end;
end;

function TGatewayServer.ReadRequestBody(ARequest: TIdHTTPRequestInfo): string;
var
  Bytes: TBytes;
begin
  Result := '';
  if ARequest.PostStream = nil then Exit;
  ARequest.PostStream.Position := 0;
  SetLength(Bytes, ARequest.PostStream.Size);
  if ARequest.PostStream.Size > 0 then
  begin
    ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
    { Bodies are JSON, UTF-8 by convention -- decode once here so the
      Delphi and FPC builds see the same string. }
    Result := TEncoding.UTF8.GetString(Bytes);
  end;
end;

function SessionMetaJSON(const Meta: TSessionMeta): TJsonObject;
{ Compact metadata view for the session list + lifecycle responses --
  enough for the web UI sidebar without shipping the whole transcript. }
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',         Meta.Id);
  Result.PutStr('title',      Meta.Title);
  Result.PutInt('created_at', Meta.CreatedAt);
  Result.PutInt('updated_at', Meta.UpdatedAt);
  Result.PutStr('model',      Meta.Model);
  Result.PutStr('provider',   Meta.Provider);
end;

procedure TGatewayServer.SaveSessionFromBody(S: TSession; const Body: string);
var
  Title, Model: string;
begin
  { ChatBodyToMessages owns the JSON parse (and raises EArgumentException
    on bad input, which the callers map to 400); it lives in the store
    unit so it's unit-testable without binding an HTTP listener. }
  S.Messages := ChatBodyToMessages(Body, Title, Model);

  if Title <> '' then S.Meta.Title := Title;
  S.AutoTitle;                          { derive from first user turn if still blank }
  if Model <> '' then S.Meta.Model := Model
  else if S.Meta.Model = '' then S.Meta.Model := FCfg.DefaultModel;
  if (S.Meta.Provider = '') and (FProvider <> nil) then
    S.Meta.Provider := FProvider.GetName;
  { A PUT to an id that wasn't on disk yet (new web chat) loads as a
    Default meta with CreatedAt=0 -- stamp it so listing sorts sanely. }
  if S.Meta.CreatedAt = 0 then S.Meta.CreatedAt := DateTimeToUnix(Now, False);
  S.Touch;
  S.Save;
end;

procedure TGatewayServer.HandleSessionsList(AResp: TIdHTTPResponseInfo);
var
  Metas: TSessionMetaArray;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  { Exclude the synthetic _gateway_* stat buckets -- those aren't real
    conversations and would clutter the sidebar (same rule the TUI uses). }
  Metas := ListSessions(False);
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
    for i := 0 to High(Metas) do
    begin
      Item := SessionMetaJSON(Metas[i]);   { AddObject takes ownership (var param) }
      Arr.AddObject(Item);
    end;
    Root.PutArray('sessions', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleSessionCreate(ARequest: TIdHTTPRequestInfo;
                                             AResp: TIdHTTPResponseInfo);
var
  S: TSession;
  Root: TJsonObject;
begin
  S := TSession.Create('');     { mint a fresh, safe id }
  try
    try
      SaveSessionFromBody(S, ReadRequestBody(ARequest));
    except
      on E: EArgumentException do
      begin
        WriteJSON(AResp, 400, '{"error":"' + JsonEscape(E.Message) + '"}');
        Exit;
      end;
    end;
    Root := SessionMetaJSON(S.Meta);
    try
      WriteJSON(AResp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TGatewayServer.HandleSessionItem(const Doc: string;
                                           ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
var
  Id: string;
  S: TSession;
  Root, MsgObj: TJsonObject;
  Arr: TJsonArray;
  i: Integer;
begin
  Id := Copy(Doc, Length('/v1/sessions/') + 1, MaxInt);
  if not IsSafeSessionId(Id) then
  begin
    WriteJSON(AResp, 400, '{"error":"bad session id"}');
    Exit;
  end;

  if ARequest.Command = 'DELETE' then
  begin
    if DeleteSession(Id) then
      WriteJSON(AResp, 200, '{"deleted":true}')
    else
      WriteJSON(AResp, 404, '{"error":"not found"}');
    Exit;
  end;

  if ARequest.Command = 'PUT' then
  begin
    S := TSession.Create(Id);     { loads if present; new handle otherwise }
    try
      { Refuse to overwrite a rich agent transcript (tool/system turns or
        assistant tool_calls) from the web UI's flattened view -- doing so
        would strip the structure terminal resume needs. The web UI forks
        to a new session on 409. New/plain sessions fall through. }
      if S.MetaExists and SessionHasRichTurns(S.Messages) then
      begin
        WriteJSON(AResp, 409,
          '{"error":"session has tool/system turns; not overwriting from web UI"}');
        Exit;
      end;
      try
        SaveSessionFromBody(S, ReadRequestBody(ARequest));
      except
        on E: EArgumentException do
        begin
          WriteJSON(AResp, 400, '{"error":"' + JsonEscape(E.Message) + '"}');
          Exit;
        end;
      end;
      Root := SessionMetaJSON(S.Meta);
      try
        WriteJSON(AResp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      S.Free;
    end;
    Exit;
  end;

  { GET -- return metadata + the full message transcript. }
  S := TSession.Create(Id);
  try
    if not S.MetaExists then
    begin
      WriteJSON(AResp, 404, '{"error":"not found"}');
      Exit;
    end;
    Root := SessionMetaJSON(S.Meta);
    try
      Arr := TJsonArray.Create;
      for i := 0 to High(S.Messages) do
      begin
        MsgObj := TJsonObject.Create;
        MsgObj.PutStr('role',    MsgRoleToString(S.Messages[i].Role));
        MsgObj.PutStr('content', S.Messages[i].Content);
        Arr.AddObject(MsgObj);
      end;
      Root.PutArray('messages', Arr);
      WriteJSON(AResp, 200, Root.ToJSON);
    finally
      Root.Free;
    end;
  finally
    S.Free;
  end;
end;

procedure TGatewayServer.HandleVaultSearch(ARequest: TIdHTTPRequestInfo;
                                           AResp: TIdHTTPResponseInfo);
var
  Query, Err: string;
  Limit, i: Integer;
  Results: TVaultResultArray;
  Root, Item: TJsonObject;
  Arr: TJsonArray;
begin
  Query := Trim(ARequest.Params.Values['q']);
  if Query = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing query: ?q="}');
    Exit;
  end;
  Limit := StrToIntDef(ARequest.Params.Values['limit'], 20);
  if Limit < 1 then Limit := 1;
  if Limit > 50 then Limit := 50;
  if not SearchVault(Query, Limit, Results, Err) then
  begin
    WriteJSON(AResp, 502, '{"error":"' + JsonEscape(Err) + '"}');
    Exit;
  end;
  Root := TJsonObject.Create;
  try
    Arr := TJsonArray.Create;
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
    Root.PutArray('results', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleVaultGet(const Doc: string;
                                        AResp: TIdHTTPResponseInfo);
var
  Slug, Err: string;
  Detail: TVaultDetail;
  Root: TJsonObject;
begin
  Slug := Copy(Doc, Length('/v1/vault/') + 1, MaxInt);
  { Slugs are flat identifiers -- refuse any path-y input. }
  if (Slug = '') or (Pos('/', Slug) > 0) or (Pos('\', Slug) > 0) or
     (Pos('..', Slug) > 0) then
  begin
    WriteJSON(AResp, 400, '{"error":"bad slug"}');
    Exit;
  end;
  if not GetVaultEntry(Slug, Detail, Err) then
  begin
    if Err = 'not found' then WriteJSON(AResp, 404, '{"error":"not found"}')
    else WriteJSON(AResp, 502, '{"error":"' + JsonEscape(Err) + '"}');
    Exit;
  end;
  Root := TJsonObject.Create;
  try
    Root.PutStr ('slug',                Detail.Slug);
    Root.PutStr ('displayName',         Detail.DisplayName);
    Root.PutStr ('summary',             Detail.Summary);
    Root.PutStr ('descriptionMarkdown', Detail.DescriptionMarkdown);
    Root.PutStr ('category',            Detail.Category);
    Root.PutStr ('tags',                Detail.Tags);
    Root.PutStr ('repoUrl',             Detail.RepoURL);
    Root.PutStr ('homepageUrl',         Detail.HomepageURL);
    Root.PutStr ('license',             Detail.License);
    Root.PutStr ('delphiVersions',      Detail.DelphiVersions);
    Root.PutStr ('packageManager',      Detail.PackageManager);
    Root.PutStr ('installSnippet',      Detail.InstallSnippet);
    Root.PutStr ('latestVersion',       Detail.LatestVersion);
    Root.PutInt ('viewCount',           Detail.ViewCount);
    Root.PutBool('blocked',             Detail.Blocked);
    Root.PutBool('suspicious',          Detail.Suspicious);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

{$IFDEF FPC}{$IFDEF UNIX}
function CRealPath(path: PAnsiChar; resolved_path: PAnsiChar): PAnsiChar; cdecl;
  external 'c' name 'realpath';

(* Canonical, symlink-resolved absolute path, or '' if it cannot be
   resolved (e.g. the path does not exist). ExpandFileName only
   normalises `.`/`..` lexically -- it does NOT follow symlinks, so a
   browseable alias whose target is the config file slips past a purely
   lexical compare. realpath(3) collapses every link in the chain. *)
function CanonicalPath(const P: string): string;
var
  Buf: array[0..4095] of AnsiChar;  { PATH_MAX on Linux }
begin
  if CRealPath(PAnsiChar(AnsiString(P)), @Buf[0]) <> nil then
    Result := string(PAnsiChar(@Buf[0]))
  else
    Result := '';
end;

{ True when A and B name the same underlying file. FpStat follows
  symlinks, so this also catches a hardlink to the config file (which
  realpath cannot, since a hardlink has its own canonical name). }
function SameInode(const A, B: string): Boolean;
var
  SA, SB: Stat;
begin
  Result := (FpStat(AnsiString(A), SA) = 0) and (FpStat(AnsiString(B), SB) = 0)
            and (SA.st_dev = SB.st_dev) and (SA.st_ino = SB.st_ino);
end;
{$ENDIF}{$ENDIF}

function IsRestrictedFsPath(const Path: string): Boolean;
var
  Full, CfgFull, Base: string;
  {$IFDEF FPC}{$IFDEF UNIX}CP: string;{$ENDIF}{$ENDIF}
begin
  Result := False;
  if Path = '' then Exit;
  try Full := ExpandFileName(Path); except Full := Path; end;
  { Exact match against the resolved config file, so an operator who moved
    it via $PASCLAW_CONFIG (a non-"config.json" name) is still covered. }
  try CfgFull := ExpandFileName(GetConfigPath); except CfgFull := GetConfigPath; end;
  {$IFDEF FPC}{$IFDEF UNIX}
  { PR #280 Codex P1: an innocuously-named symlink (notes.txt ->
    $PASCLAW_CONFIG) or a hardlink would pass the lexical + basename
    checks below, and HandleFSRead's TFileStream follows it to serve the
    cleartext config. Catch the link by inode, and run the checks below
    against the symlink-resolved target rather than the lexical name. }
  if SameInode(Path, GetConfigPath) then Exit(True);
  CP := CanonicalPath(Path);
  if CP <> '' then Full := CP;
  CP := CanonicalPath(GetConfigPath);
  if CP <> '' then CfgFull := CP;
  {$ENDIF}{$ENDIF}
  if (CfgFull <> '') and SameFileName(Full, CfgFull) then Exit(True);
  { Basename denylist for the conventional secret files. }
  Base := LowerCase(ExtractFileName(Full));
  if Base = 'config.json' then Exit(True);
  if (Base = '.env') or HasPrefix(Base, '.env.') then Exit(True);
  if HasSuffix(Base, '.pem') or HasSuffix(Base, '.key') then Exit(True);
end;

procedure TGatewayServer.HandleFSList(ARequest: TIdHTTPRequestInfo;
                                       AResp: TIdHTTPResponseInfo);
var
  Path, Dir, Reason: string;
  WsRoot, CwdRoot: string;
  Root: TJsonObject;
  Arr: TJsonArray;
  Item: TJsonObject;
  SR: TSearchRec;
begin
  { Ensure the agent workspace exists so the Files tab can default to (and
    offer a switch to) it even on a fresh web-only / Docker boot where no
    agent has run yet to create it. Best-effort; a failure just means the
    workspace button won't appear. }
  WsRoot := JoinPath(GetHome, 'workspace');
  ForceDirectories(WsRoot);
  Path := ARequest.Params.Values['path'];
  if Path = '' then
  begin
    (* Default landing directory for a no-param `GET /v1/fs`.

       When the sandbox is on, default to its configured workspace
       so the operator's first request returns useful contents
       (the listing of /v1/fs/workspace) instead of an immediate
       403 on $PASCLAW_HOME root. When the sandbox is off (or no
       workspace is configured), keep the historical $PASCLAW_HOME
       fallback so single-user CLI / desktop deployments still
       browse the config tree from the home root.

       Side-stepping the 403 silently is the right call here --
       /v1/fs is operator-facing, not the model's tool surface
       (that's tools/fs_read), and an empty-path "give me
       something" request really does want the directory the
       sandbox WILL allow rather than one it's guaranteed to
       refuse.

       Prefer the PasClaw workspace ($PASCLAW_HOME/workspace -- where
       memory, skills and generated files live) over CurrentWorkspace.
       The sandbox "workspace" defaults to the process launch directory
       (GetCurrentDir) when none is configured, so an operator browsing
       Files in the web UI was landing on wherever the binary booted
       instead of the agent's workspace.

       Adopt it only when it exists AND the policy permits reading it:
         - Default config (restrict_to_workspace=false): CanReadPath
           short-circuits to True, so the browser lands on the workspace
           -- the common Docker/web-only boot the user reported.
         - restrict_to_workspace=true with no configured workspace
           (GWorkspace defaulted to cwd): the agent workspace is OUTSIDE
           the sandbox, so the probe fails and we fall back to
           CurrentWorkspace. That is correct, not a regression -- a
           listing of $PASCLAW_HOME/workspace would be refused by the
           CanReadPath gate below anyway, so the allowed cwd is the only
           directory that won't 403. Operators who want the workspace
           browsable under restriction set sandbox.workspace explicitly. *)
    Path := WsRoot;
    if not (DirectoryExists(Path) and CanReadPathHTTP(Path, Reason)) then
      Path := CurrentWorkspace;
    if Path = '' then Path := GetHome;
  end;
  { Route through the same sandbox CanReadPath check that fs_read
    uses. PR #88 Codex P1: the original "reject `..`" check let
    absolute paths like /etc/passwd through even when
    sandbox.restrict_to_workspace was on. CanReadPath honours
    workspace bounds, allow_read_paths globs, and
    allow_read_outside_workspace. }
  if not CanReadPathHTTP(Path, Reason) then
  begin
    WriteJSON(AResp, 403, '{"error":"' + JsonEscape(Reason) + '"}');
    Exit;
  end;
  Dir := Path;
  if not DirectoryExists(Dir) then
  begin
    WriteJSON(AResp, 404, '{"error":"not a directory"}');
    Exit;
  end;
  Root := TJsonObject.Create;
  try
    Root.PutStr('path', Dir);
    { Expose the two browseable roots so the Files tab can offer quick-switch
      buttons: the PasClaw workspace ($PASCLAW_HOME/workspace) and the launch
      directory (the sandbox cwd). Each is emitted only when it exists and the
      read policy permits it, so the UI never shows a button that 403s. They
      can be equal (the UI dedupes). }
    if DirectoryExists(WsRoot) and CanReadPathHTTP(WsRoot, Reason) then
      Root.PutStr('workspace_root', WsRoot)
    else
      Root.PutStr('workspace_root', '');
    CwdRoot := CurrentWorkspace;
    if (CwdRoot <> '') and DirectoryExists(CwdRoot)
       and CanReadPathHTTP(CwdRoot, Reason) then
      Root.PutStr('cwd_root', CwdRoot)
    else
      Root.PutStr('cwd_root', '');
    Arr := TJsonArray.Create;
    if FindFirst(JoinPath(Dir, '*'), faAnyFile, SR) = 0 then
    try
      repeat
        if (SR.Name = '.') or (SR.Name = '..') then Continue;
        { Hide secret-bearing files (config.json, .env, TLS keys) from the
          operator browse so cleartext api_keys / tokens never surface. }
        if IsRestrictedFsPath(JoinPath(Dir, SR.Name)) then Continue;
        Item := TJsonObject.Create;
        Item.PutStr ('name', SR.Name);
        Item.PutInt ('size', SR.Size);
        Item.PutBool('dir',  (SR.Attr and faDirectory) <> 0);
        Arr.AddObject(Item);
      until FindNext(SR) <> 0;
    finally
      FindClose(SR);
    end;
    Root.PutArray('entries', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

function FSBytesLookText(const Bytes: TBytes; Count: Int64;
                         TruncatedAtCap: Boolean): Boolean;
{ True iff the first Count bytes are WELL-FORMED UTF-8 with no NUL -- i.e. safe
  to hand to the text decoder. Binary content returns False so HandleFSRead
  flags it ("binary":true) and the web UI shows the hex viewer instead. This
  matters on the Delphi build: TEncoding.UTF8.GetString on malformed bytes
  raises a codepage error ("No mapping for the Unicode character ...") that
  surfaced as a 500.

  Enforces Unicode Table 3-7 (not just the byte-count shape), so overlong forms
  (C0/C1, E0 80..9F, F0 80..8F), UTF-16 surrogates (ED A0..BF), and out-of-range
  leads (F4 90.., F5..FF) are all rejected. An incomplete trailing sequence is
  tolerated ONLY when the read was cut at the 256 KB cap (TruncatedAtCap) -- the
  rest of that codepoint lives just past the cap; a file that genuinely ends
  mid-sequence is malformed and treated as binary. }
var
  i: Int64;
  b, b1: Byte;
  need, lo, hi, k: Integer;
begin
  i := 0;
  while i < Count do
  begin
    b := Bytes[i];
    if b = 0 then Exit(False);
    if b <= $7F then begin Inc(i); Continue; end;
    if b <  $C2 then Exit(False);                                 { 80..BF lone cont; C0/C1 overlong }
    if      b <= $DF then begin need := 1; lo := $80; hi := $BF; end
    else if b =  $E0 then begin need := 2; lo := $A0; hi := $BF; end  { reject overlong E0 80..9F }
    else if b <= $EC then begin need := 2; lo := $80; hi := $BF; end
    else if b =  $ED then begin need := 2; lo := $80; hi := $9F; end  { reject surrogates ED A0..BF }
    else if b <= $EF then begin need := 2; lo := $80; hi := $BF; end
    else if b =  $F0 then begin need := 3; lo := $90; hi := $BF; end  { reject overlong F0 80..8F }
    else if b <= $F3 then begin need := 3; lo := $80; hi := $BF; end
    else if b =  $F4 then begin need := 3; lo := $80; hi := $8F; end  { reject > U+10FFFF }
    else Exit(False);                                             { F5..FF }
    if i + need >= Count then
    begin
      { Sequence runs off the end of what we read. Fine only if we trimmed at
        the cap (the rest is in the file); otherwise the file is malformed. }
      if TruncatedAtCap then Exit(True) else Exit(False);
    end;
    b1 := Bytes[i + 1];
    if (b1 < lo) or (b1 > hi) then Exit(False);
    for k := 2 to need do
      if (Bytes[i + k] and $C0) <> $80 then Exit(False);
    Inc(i, need + 1);
  end;
  Result := True;
end;

procedure TGatewayServer.HandleFSRead(ARequest: TIdHTTPRequestInfo;
                                       AResp: TIdHTTPResponseInfo);
const
  MAX_BYTES = 256 * 1024;   { 256 KB display cap }
var
  Path, Body, Reason: string;
  Root: TJsonObject;
  Strm: TFileStream;
  Truncated, IsBinary: Boolean;
  ToRead, FullSize: Int64;
  Bytes: TBytes;
begin
  Path := ARequest.Params.Values['path'];
  if Path = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"bad path"}');
    Exit;
  end;
  { Same sandbox gate as HandleFSList -- fs_read's policy applies
    here too. PR #88 Codex P1 caught the original "reject `..`"
    check that let /etc/passwd through. }
  if not CanReadPathHTTP(Path, Reason) then
  begin
    WriteJSON(AResp, 403, '{"error":"' + JsonEscape(Reason) + '"}');
    Exit;
  end;
  { Refuse secret-bearing files even when the sandbox would allow them --
    same denylist HandleFSList hides from the browse. Without this an
    operator could read config.json's cleartext keys via a direct path. }
  if IsRestrictedFsPath(Path) then
  begin
    WriteJSON(AResp, 403, '{"error":"access to this file is restricted"}');
    Exit;
  end;
  if not FileExists(Path) then
  begin
    WriteJSON(AResp, 404, '{"error":"not found"}');
    Exit;
  end;
  Truncated := False;
  IsBinary  := False;
  FullSize  := 0;
  Body      := '';
  try
    Strm := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
    try
      FullSize := Strm.Size;
      ToRead := FullSize;
      if ToRead > MAX_BYTES then begin ToRead := MAX_BYTES; Truncated := True; end;
      SetLength(Bytes, ToRead);
      if ToRead > 0 then Strm.ReadBuffer(Bytes[0], ToRead);
      { Binary content (NUL / invalid UTF-8) is NOT decoded -- doing so 500s on
        Delphi. Flag it so the web UI opens the hex viewer (it pages raw bytes
        via /v1/fs/peek). }
      if (ToRead > 0) and not FSBytesLookText(Bytes, ToRead, Truncated) then
        IsBinary := True
      else
      begin
        {$IFDEF FPC}
        if ToRead = 0 then Body := ''
        else SetString(Body, PAnsiChar(@Bytes[0]), ToRead);
        {$ELSE}
        Body := TEncoding.UTF8.GetString(Bytes);
        {$ENDIF}
      end;
    finally
      Strm.Free;
    end;
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  Root := TJsonObject.Create;
  try
    Root.PutStr ('path', Path);
    if IsBinary then
    begin
      Root.PutBool('binary', True);
      Root.PutInt ('size',   FullSize);
    end
    else
    begin
      Root.PutStr ('content',   Body);
      Root.PutBool('truncated', Truncated);
    end;
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleFSDownload(ARequest: TIdHTTPRequestInfo;
                                          AResp: TIdHTTPResponseInfo);
{ Stream a file's RAW bytes as an attachment so the browser can save binaries
  (e.g. a built .exe) that /v1/fs/read can't carry -- read returns UTF-8 text
  in JSON and caps at 256 KB. Same sandbox + restricted-file gates as read; no
  size cap, no decoding. Streams straight from the file (FreeContentStream lets
  Indy own + close the stream) so a large file isn't buffered into memory. }
var
  Path, Reason, FName: string;
  Strm: TFileStream;
begin
  Path := ARequest.Params.Values['path'];
  if Path = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"bad path"}');
    Exit;
  end;
  if not CanReadPathHTTP(Path, Reason) then
  begin
    WriteJSON(AResp, 403, '{"error":"' + JsonEscape(Reason) + '"}');
    Exit;
  end;
  if IsRestrictedFsPath(Path) then
  begin
    WriteJSON(AResp, 403, '{"error":"access to this file is restricted"}');
    Exit;
  end;
  if not FileExists(Path) then
  begin
    WriteJSON(AResp, 404, '{"error":"not found"}');
    Exit;
  end;
  try
    Strm := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  { Strip any quotes/CR/LF from the suggested filename so they can't break out
    of the Content-Disposition header. }
  FName := ExtractFileName(Path);
  FName := StringReplace(FName, '"', '', [rfReplaceAll]);
  FName := StringReplace(FName, #13, '', [rfReplaceAll]);
  FName := StringReplace(FName, #10, '', [rfReplaceAll]);
  if FName = '' then FName := 'download';
  Strm.Position := 0;
  AResp.ResponseNo  := 200;
  AResp.ContentType := 'application/octet-stream';
  AResp.CustomHeaders.AddValue('Content-Disposition',
    'attachment; filename="' + FName + '"');
  AResp.ContentStream     := Strm;
  AResp.FreeContentStream := True;
  AResp.ContentLength     := Strm.Size;
end;

procedure TGatewayServer.HandleFSPeek(ARequest: TIdHTTPRequestInfo;
                                      AResp: TIdHTTPResponseInfo);
{ Stream a bounded WINDOW [offset, offset+len) of a file's raw bytes, plus an
  X-File-Total header with the full size, so the web UI's hex viewer can page
  through a huge file without ever downloading the whole thing (important when
  the operator is driving a REMOTE gateway). Same sandbox + restricted gates as
  read/download; the window is capped at 64 KB. }
const
  MAX_WIN = 64 * 1024;
var
  Path, Reason: string;
  Strm: TFileStream;
  Mem: TMemoryStream;
  Offset, Len, Total: Int64;
begin
  Path := ARequest.Params.Values['path'];
  if Path = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"bad path"}');
    Exit;
  end;
  if not CanReadPathHTTP(Path, Reason) then
  begin
    WriteJSON(AResp, 403, '{"error":"' + JsonEscape(Reason) + '"}');
    Exit;
  end;
  if IsRestrictedFsPath(Path) then
  begin
    WriteJSON(AResp, 403, '{"error":"access to this file is restricted"}');
    Exit;
  end;
  if not FileExists(Path) then
  begin
    WriteJSON(AResp, 404, '{"error":"not found"}');
    Exit;
  end;
  Offset := StrToInt64Def(ARequest.Params.Values['offset'], 0);
  Len    := StrToInt64Def(ARequest.Params.Values['len'], 4096);
  if Len < 0 then Len := 0;
  if Len > MAX_WIN then Len := MAX_WIN;
  try
    Strm := TFileStream.Create(Path, fmOpenRead or fmShareDenyWrite);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 500, '{"error":"' + JsonEscape(E.Message) + '"}');
      Exit;
    end;
  end;
  Mem := TMemoryStream.Create;
  try
    Total := Strm.Size;
    if Offset < 0 then Offset := 0;
    if Offset > Total then Offset := Total;
    if Offset + Len > Total then Len := Total - Offset;
    Strm.Position := Offset;
    if Len > 0 then Mem.CopyFrom(Strm, Len);
  finally
    Strm.Free;
  end;
  Mem.Position := 0;
  AResp.ResponseNo  := 200;
  AResp.ContentType := 'application/octet-stream';
  AResp.CustomHeaders.AddValue('X-File-Total',  IntToStr(Total));
  AResp.CustomHeaders.AddValue('X-File-Offset', IntToStr(Offset));
  AResp.ContentStream     := Mem;
  AResp.FreeContentStream := True;
  AResp.ContentLength     := Mem.Size;
end;

function TGatewayServer.ReqSessionId(ARequest: TIdHTTPRequestInfo): string;
begin
  Result := Trim(ARequest.RawHeaders.Values['X-PasClaw-Session']);
end;

procedure TGatewayServer.ApplyCheckpointSession(const ReqSession: string);
{ Select this thread's per-session checkpoint context (the calling Indy worker
  thread). Cheap: first touch of a session creates + loads it, later touches
  just re-point the thread. Does NOT acquire the turn lock -- the caller
  brackets the actual work with Acquire/ReleaseCheckpointTurn. }
var
  CC: TCheckpointConfig;
begin
  CC.Enabled   := FCfg.CheckpointsEnabled;
  CC.SessionId := CheckpointSessionId(ReqSession);
  CC.Root      := JoinPath(GetHome, 'workspace/checkpoints');
  CC.KeepLast  := FCfg.CheckpointsKeepLast;
  InitCheckpoints(CC);
end;

function TGatewayServer.RunCheckpointedLoop(const ReqSession: string;
  const Cfg: TToolLoopConfig; var Messages: array of TMessage;
  out Loop: TToolLoopResult): Boolean;
{ Indy serves on worker threads, so two requests can run turns at once. Select
  this thread's session context, then serialize the BeginTurn+loop on THAT
  session's turn lock: same session can't tear its own turn, different sessions
  (other chats / other users) overlap freely -- their LLM round-trips no longer
  block each other. Branch on the static config, not the thread's current
  context, since a fresh worker thread has none selected yet. }
var
  LocalCfg: TToolLoopConfig;
  RoutedNm: string;
begin
  { Task-difficulty auto-router (opt-in via FCfg.AutoRouter). Applied here so
    EVERY gateway/serve chat path -- the four RunCheckpointedLoop call sites
    (chat, chat/completions streaming + non-streaming, responses) -- routes
    identically. Cfg is const; copy it so the swap (provider/model + primary
    prepended to fallbacks) is local to this turn. No-op unless enabled. }
  LocalCfg := Cfg;
  ApplyAutoRoute(LocalCfg, FCfg, Messages, RoutedNm);

  if FCfg.CheckpointsEnabled then
  begin
    ApplyCheckpointSession(ReqSession);
    AcquireCheckpointTurn;
    try
      BeginTurn;
      Result := RunToolLoop(LocalCfg, Messages, Loop);
    finally
      ReleaseCheckpointTurn;
    end;
  end
  else
    Result := RunToolLoop(LocalCfg, Messages, Loop);

  { Opt-in distilled memory: on a successful turn, fire a background pass
    that extracts durable facts from the latest exchange and stores them.
    Best-effort and non-blocking -- never affects the response.
    Use Cfg.Provider/Cfg.Model -- the SNAPSHOT this turn actually ran on --
    not FProvider, which a concurrent /v1/config hot-swap may have already
    repointed at a different backend. }
  if Result and FCfg.MemoryDistillEnabled then
    ScheduleDistill(LocalCfg.Provider, LocalCfg.Model, GetHome, ReqSession,
      BuildRecentTranscript(Loop.FinalMessages, Loop.Content, DefaultRecentMsgs));
end;

procedure TGatewayServer.HandleCheckpointsList(ARequest: TIdHTTPRequestInfo;
                                               AResp: TIdHTTPResponseInfo);
{ GET /v1/checkpoints -- per-chat backend/current/can_redo + per-turn files.
  Scoped to X-PasClaw-Session, under that session's turn lock so it sees a
  consistent state. }
var
  Body: string;
begin
  ApplyCheckpointSession(ReqSessionId(ARequest));
  AcquireCheckpointTurn;
  try
    Body := CheckpointsStateJSON;
  finally
    ReleaseCheckpointTurn;
  end;
  WriteJSON(AResp, 200, Body);
end;

function CheckpointResultJSON(Ok: Boolean; const Restored: TRestoredFileArray;
  const Err: string; out Status: Integer): string;
var
  Root: TJsonObject;
  Arr: TJsonArray;
  FileObj: TJsonObject;
  i: Integer;
begin
  if not Ok then
  begin
    Status := 400;
    Exit('{"ok":false,"error":"' + JsonEscape(Err) + '"}');
  end;
  Status := 200;
  Root := TJsonObject.Create;
  try
    Root.PutBool('ok', True);
    Root.PutInt ('restored', Length(Restored));
    Arr := TJsonArray.Create;
    for i := 0 to High(Restored) do
    begin
      FileObj := TJsonObject.Create;
      FileObj.PutStr('path', Restored[i].Path);
      Arr.AddObject(FileObj);
    end;
    Root.PutArray('files', Arr);
    Result := Root.ToJSON;
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleCheckpointsUndo(ARequest: TIdHTTPRequestInfo;
                                               AResp: TIdHTTPResponseInfo);
{ POST /v1/checkpoints/undo?n=N -- roll this chat's workspace back N turns. }
var
  N, Status: Integer;
  Restored: TRestoredFileArray;
  Err, Body: string;
  Ok: Boolean;
begin
  N := StrToIntDef(ARequest.Params.Values['n'], 1);
  if N < 1 then N := 1;
  ApplyCheckpointSession(ReqSessionId(ARequest));
  AcquireCheckpointTurn;
  try
    Ok := UndoTurns(N, Restored, Err);
  finally
    ReleaseCheckpointTurn;
  end;
  Body := CheckpointResultJSON(Ok, Restored, Err, Status);
  WriteJSON(AResp, Status, Body);
end;

procedure TGatewayServer.HandleCheckpointsRedo(ARequest: TIdHTTPRequestInfo;
                                               AResp: TIdHTTPResponseInfo);
{ POST /v1/checkpoints/redo?n=N -- re-apply N undone turns (zpaq backend only). }
var
  N, Status: Integer;
  Restored: TRestoredFileArray;
  Err, Body: string;
  Ok: Boolean;
begin
  N := StrToIntDef(ARequest.Params.Values['n'], 1);
  if N < 1 then N := 1;
  ApplyCheckpointSession(ReqSessionId(ARequest));
  AcquireCheckpointTurn;
  try
    Ok := RedoTurns(N, Restored, Err);
  finally
    ReleaseCheckpointTurn;
  end;
  Body := CheckpointResultJSON(Ok, Restored, Err, Status);
  WriteJSON(AResp, Status, Body);
end;

type
  TLogStreamWriter = class
    Conn: TIdTCPConnection;
    procedure WriteSSE(const Payload: string);
    procedure OnLog(const Tag, Msg: string);
  end;

procedure TLogStreamWriter.WriteSSE(const Payload: string);
(* HTTP/1.1 chunked-transfer chunk: <hex-length>\r\n<bytes>\r\n
   Indy doesn't auto-frame when we set ContentLength := -1; if we
   write raw text it bypasses chunking and the client sees a
   Content-Length-bounded response that gets cut at the first byte
   chunk. Match the manual framing TSSEStreamer in this same file
   does for /v1/chat/completions.

   Frame holds the bytes as TIdBytes (NOT TBytes) -- Delphi's
   dcc64 enforces the distinction at the Write() call site and
   refuses TBytes there, while FPC accepts either. Build TIdBytes
   from the start; the copy loop converts the TEncoding output
   one byte at a time, the same idiom TSSEStreamer.WriteSocketBytes
   already uses. Codex flagged the Delphi build error on PR #89. *)
var
  PayloadBytes, HeaderBytes: TBytes;
  Frame: TIdBytes;
  HeaderStr: string;
  i, Offset: Integer;
begin
  if (Conn = nil) or (not Conn.Connected) then Exit;
  PayloadBytes := TEncoding.UTF8.GetBytes(Payload);
  if Length(PayloadBytes) = 0 then Exit;
  HeaderStr := IntToHex(Length(PayloadBytes), 1) + #13#10;
  HeaderBytes := TEncoding.ASCII.GetBytes(HeaderStr);
  SetLength(Frame, Length(HeaderBytes) + Length(PayloadBytes) + 2);
  Offset := 0;
  for i := 0 to High(HeaderBytes)  do begin Frame[Offset] := HeaderBytes[i];  Inc(Offset); end;
  for i := 0 to High(PayloadBytes) do begin Frame[Offset] := PayloadBytes[i]; Inc(Offset); end;
  Frame[Offset]     := 13;
  Frame[Offset + 1] := 10;
  try
    Conn.IOHandler.Write(Frame);
    { Drain Indy's nested WriteBuffer stack so the bytes leave the
      socket now, not when Indy decides the buffer is full. Same
      idiom TSSEStreamer.WriteSocketBytes uses. }
    while Conn.IOHandler.WriteBufferingActive do
      Conn.IOHandler.WriteBufferClose;
  except
    { Connection dropped -- the unsubscribe in HandleLogs's finally
      will tear us down on its next iteration. }
  end;
end;

procedure TLogStreamWriter.OnLog(const Tag, Msg: string);
begin
  WriteSSE('data: ' + JsonEscape('[' + Tag + '] ' + Msg) + #10#10);
end;

(* Forward declaration -- implementation lives next to TSSEStreamer
   for thematic grouping. See the long-form comment at the
   implementation site for why this exists. *)
function EmitSSEResponseHeaders(AContext: TIdContext;
                                AResp: TIdHTTPResponseInfo): Boolean; forward;

procedure TGatewayServer.HandleLogs(AContext: TIdContext;
                                     ARequest: TIdHTTPRequestInfo;
                                     AResp: TIdHTTPResponseInfo);
var
  Writer: TLogStreamWriter;
  Token: Integer;
  Snapshot: TStringList;
  i: Integer;
  TabPos: Integer;
  Tag, Body, Line: string;
  TerminatorTmp: TBytes;
  TerminatorIdBytes: TIdBytes;
begin
  { SSE stream -- emit the recent buffer up front, then subscribe
    for live tail. The handler doesn't return until the client
    disconnects (or we throw); on either path the listener gets
    unsubscribed.

    Headers go through EmitSSEResponseHeaders (shared with
    /v1/chat/completions and /v1/responses) so Indy's
    WriteHeader-emits-CL-and-TE-together bug doesn't poison this
    feed for strict L7 proxies either. }
  if not EmitSSEResponseHeaders(AContext, AResp) then Exit;

  Writer := TLogStreamWriter.Create;
  Writer.Conn := AContext.Connection;

  Snapshot := LogBufferSnapshot;
  try
    for i := 0 to Snapshot.Count - 1 do
    begin
      Line := Snapshot[i];
      TabPos := Pos(#9, Line);
      if TabPos > 0 then
      begin
        Tag  := Copy(Line, 1, TabPos - 1);
        Body := Copy(Line, TabPos + 1, MaxInt);
      end
      else
      begin
        Tag  := 'info';
        Body := Line;
      end;
      Writer.OnLog(Tag, Body);
    end;
  finally
    Snapshot.Free;
  end;

  Token := SubscribeLog(Writer.OnLog);
  try
    { Park here until the client disconnects. WaitFor on the stop
      event lets a server-side shutdown wake us cleanly too. }
    while AContext.Connection.Connected do
    begin
      if FStopFlag.WaitFor(1000) = wrSignaled then Break;
    end;
  finally
    UnsubscribeLog(Token);
    { Best-effort terminator chunk so the client sees a clean
      end-of-stream. Same TBytes→TIdBytes conversion as the header
      write above -- Delphi dcc64 enforces the type match. }
    try
      TerminatorTmp := TEncoding.ASCII.GetBytes('0'#13#10#13#10);
      SetLength(TerminatorIdBytes, Length(TerminatorTmp));
      for i := 0 to High(TerminatorTmp) do TerminatorIdBytes[i] := TerminatorTmp[i];
      AContext.Connection.IOHandler.Write(TerminatorIdBytes);
    except
    end;
    Writer.Free;
  end;
end;

(* ============================================================
   Relay endpoints. See docs/providers-relay.md for the full wire
   protocol. The queue + provider live in PasClaw.Gateway.RelayQueue
   + PasClaw.Providers.Relay; these handlers just translate between
   HTTP and the queue's Pascal API.
   ============================================================ *)

type
  (* Per-worker SSE writer. Mirrors TLogStreamWriter's pattern: a
     Conn + a WriteSSE that builds chunked-transfer frames manually
     because Indy doesn't auto-frame when ContentLength = -1. *)
  TRelayStreamWriter = class
    Conn: TIdTCPConnection;
    function WriteSSEFrame(const Payload: string): Boolean;
  end;

function TRelayStreamWriter.WriteSSEFrame(const Payload: string): Boolean;
var
  PayloadBytes, HeaderBytes: TBytes;
  Frame: TIdBytes;
  HeaderStr: string;
  i, Offset: Integer;
begin
  Result := False;
  if (Conn = nil) or (not Conn.Connected) then Exit;
  PayloadBytes := TEncoding.UTF8.GetBytes(Payload);
  if Length(PayloadBytes) = 0 then Exit(True);
  HeaderStr := IntToHex(Length(PayloadBytes), 1) + #13#10;
  HeaderBytes := TEncoding.ASCII.GetBytes(HeaderStr);
  SetLength(Frame, Length(HeaderBytes) + Length(PayloadBytes) + 2);
  Offset := 0;
  for i := 0 to High(HeaderBytes)  do begin Frame[Offset] := HeaderBytes[i];  Inc(Offset); end;
  for i := 0 to High(PayloadBytes) do begin Frame[Offset] := PayloadBytes[i]; Inc(Offset); end;
  Frame[Offset]     := 13;
  Frame[Offset + 1] := 10;
  try
    Conn.IOHandler.Write(Frame);
    while Conn.IOHandler.WriteBufferingActive do
      Conn.IOHandler.WriteBufferClose;
    Result := True;
  except
    { Client dropped -- caller's loop will notice on next iteration. }
  end;
end;

procedure TGatewayServer.EmitRelayCors(ARequest: TIdHTTPRequestInfo;
                                        AResp: TIdHTTPResponseInfo);
(* Stamp the response with permissive CORS headers so a cross-origin
   browser worker page can talk to the relay endpoints. Authorization
   still gates access -- this only tells the browser "let JS see the
   response."

   Why permissive (Access-Control-Allow-Origin set to wildcard)?
     The relay endpoints are guarded by a bearer token (or the
     ?token= query fallback). Anyone reaching them already had to
     present credentials. Echoing the Origin (vs hard-allowlisting)
     would require the operator to configure a CORS allowlist, which
     buys nothing security-wise because the token IS the gate.
     Browsers also refuse `Authorization` over a credentials=include
     request with `*` -- but we DON'T use credentials=include
     (cookies aren't involved); the token rides as a header or query
     param, which `*` permits cleanly.

   Reflecting Access-Control-Request-Headers lets browsers ask for
   any auth header they want without us having to enumerate them
   ahead of time. *)
var
  ReqHdrs: string;
begin
  AResp.CustomHeaders.AddValue('Access-Control-Allow-Origin',  '*');
  AResp.CustomHeaders.AddValue('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  ReqHdrs := Trim(ARequest.RawHeaders.Values['Access-Control-Request-Headers']);
  if ReqHdrs = '' then
    ReqHdrs := 'Authorization, Content-Type, X-Relay-Worker-Id, X-Relay-Capabilities';
  AResp.CustomHeaders.AddValue('Access-Control-Allow-Headers', ReqHdrs);
  { 10-minute preflight cache. Browser-relay workers reconnect often
    (page reloads, EventSource retries) -- caching the preflight
    saves a round-trip per reconnect without making policy changes
    take an unreasonably long time to roll out. }
  AResp.CustomHeaders.AddValue('Access-Control-Max-Age',       '600');
end;

function TGatewayServer.RelayTokenAuthorises(const Doc, AuthHeader, QueryToken: string): Boolean;
(* Dual-token rule for /v1/relay/*: in addition to the main
   gateway token (checked above by CheckGatewayAuth), the
   per-process FRelayToken also unlocks just the relay endpoints.
   Returns True when:
     - the path is under /v1/relay/, AND
     - the presented credential (Authorization: Bearer X OR
       ?token=X) matches FRelayToken case-insensitively with
       hyphens stripped (operators dictating the token over the
       phone often paraphrase the format).

   /v1/relay/worker-token is intentionally NOT covered by this
   helper -- that endpoint exposes FRelayToken to the trusted
   webui and must be gated by the MAIN token only. *)
var
  Presented: string;
begin
  Result := False;
  if Pos('/v1/relay/', Doc) <> 1 then Exit;
  if Doc = '/v1/relay/worker-token' then Exit;

  Presented := ExtractBearerToken(AuthHeader);
  if Presented = '' then Presented := QueryToken;
  if Presented = '' then Exit;

  Result := NormaliseTokenForCompare(Presented) =
            NormaliseTokenForCompare(FRelayToken);
end;

procedure TGatewayServer.HandleRelayWorkerToken(ARequest: TIdHTTPRequestInfo;
                                                 AResp: TIdHTTPResponseInfo);
(* GET /v1/relay/worker-token -- returns the per-process FRelayToken
   as JSON so the trusted webui can pass it to its sandboxed
   in-tab WebLLM worker. Gated by the MAIN token via the
   normal OnCommandGet auth check (RelayTokenAuthorises
   deliberately excludes this path), so an attacker who only has
   the relay token CANNOT escalate to read it. CORS-stamped so the
   webui can fetch from a cross-origin context if the operator
   hosts it that way. *)
var
  Root: TJsonObject;
begin
  EmitRelayCors(ARequest, AResp);
  Root := TJsonObject.Create;
  try
    Root.PutStr('token', FRelayToken);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleRelayOptionsPreflight(ARequest: TIdHTTPRequestInfo;
                                                      AResp: TIdHTTPResponseInfo);
(* Standalone OPTIONS handler -- no auth gate. Per the CORS spec,
   preflights MUST NOT carry credentials (the actual request that
   follows does). The browser uses the preflight to learn what's
   allowed; our 204 + Allow-* headers is the answer. *)
begin
  EmitRelayCors(ARequest, AResp);
  AResp.ResponseNo := 204;
  AResp.ContentLength := 0;
  AResp.ContentText   := '';
end;

procedure TGatewayServer.HandleRelayPoll(AContext: TIdContext;
                                          ARequest: TIdHTTPRequestInfo;
                                          AResp: TIdHTTPResponseInfo);
(* GET /v1/relay/poll
   Long-poll SSE stream. The worker advertises its id + capabilities via
   request headers on connect, the queue registers it, and as pending
   requests arrive matching the worker's capabilities they're emitted
   as `data:` SSE events.

   Auth: bearer-token gate fires in OnCommandGet before we land here.
*)
const
  PollIntervalMs = 1000;   { wake every second to recheck for work + connection liveness }
var
  Q: TRelayQueue;
  Writer: TRelayStreamWriter;
  WorkerId, CapHeader: string;
  Caps: TStringArray;
  CapsList: TStringList;
  Req: TRelayRequest;
  i: Integer;
  TerminatorTmp: TBytes;
  TerminatorIdBytes: TIdBytes;
  Payload: string;
begin
  Q := GetGlobalRelayQueue;
  if Q = nil then
  begin
    WriteJSON(AResp, 503,
              '{"error":"relay disabled","message":"no relay queue initialised; ' +
              'configure a relay provider in config.json"}');
    Exit;
  end;

  { Browser workers served from a foreign origin need CORS to receive
    SSE events at all. Stamp the headers before kicking off the SSE
    stream -- once EmitSSEResponseHeaders flushes the response line,
    they can't be added. }
  EmitRelayCors(ARequest, AResp);

  { Worker identity. Header is canonical; ?worker_id= falls back for
    browser EventSource workers -- the WHATWG EventSource constructor
    has no headers option, so browser code can't set
    X-Relay-Worker-Id. Same fallback pattern the bearer token has for
    /v1/* routes (Authorization header OR ?token=). Codex P2 review
    on PR #324. }
  WorkerId := Trim(ARequest.RawHeaders.Values['X-Relay-Worker-Id']);
  if WorkerId = '' then
    WorkerId := Trim(ARequest.Params.Values['worker_id']);
  if WorkerId = '' then
  begin
    WriteJSON(AResp, 400,
              '{"error":"missing header","message":"X-Relay-Worker-Id is required ' +
              '(or ?worker_id= query param for browser EventSource workers)"}');
    Exit;
  end;

  { Parse capabilities header (comma-separated). Empty / missing =
    wildcard worker (CanServe always returns True). Same browser-
    EventSource fallback as worker id above -- ?caps=a,b,c. }
  CapHeader := Trim(ARequest.RawHeaders.Values['X-Relay-Capabilities']);
  if CapHeader = '' then
    CapHeader := Trim(ARequest.Params.Values['caps']);
  SetLength(Caps, 0);
  if CapHeader <> '' then
  begin
    CapsList := TStringList.Create;
    try
      CapsList.Delimiter     := ',';
      CapsList.StrictDelimiter := True;
      CapsList.DelimitedText := CapHeader;
      SetLength(Caps, CapsList.Count);
      for i := 0 to CapsList.Count - 1 do
        Caps[i] := Trim(CapsList[i]);
    finally
      CapsList.Free;
    end;
  end;

  Q.RegisterWorker(WorkerId, Caps);
  try
    if not EmitSSEResponseHeaders(AContext, AResp) then Exit;

    Writer := TRelayStreamWriter.Create;
    Writer.Conn := AContext.Connection;
    try
      { Poll loop. DequeueForWorker blocks up to PollIntervalMs
        waiting for work; we wake periodically to check connection
        liveness + the server-wide stop flag. }
      while AContext.Connection.Connected do
      begin
        if FStopFlag.WaitFor(0) = wrSignaled then Break;
        Req := Q.DequeueForWorker(WorkerId, PollIntervalMs);
        if Req <> nil then
        begin
          Payload := 'data: ' + Req.BodyJSON + #10#10;
          if not Writer.WriteSSEFrame(Payload) then
          begin
            { Write failed mid-stream -- worker dropped between
              dequeue and write. Requeue so another worker can
              pick it up. UnregisterWorker in the finally block
              will sweep any remaining inflight requests we
              haven't accounted for. }
            Break;
          end;
        end;
      end;
    finally
      try
        TerminatorTmp := TEncoding.ASCII.GetBytes('0'#13#10#13#10);
        SetLength(TerminatorIdBytes, Length(TerminatorTmp));
        for i := 0 to High(TerminatorTmp) do TerminatorIdBytes[i] := TerminatorTmp[i];
        AContext.Connection.IOHandler.Write(TerminatorIdBytes);
      except
      end;
      Writer.Free;
    end;
  finally
    { Worker disconnected (closed tab, crashed, network drop) or we
      exited via FStopFlag. UnregisterWorker requeues any requests
      this worker was holding so they don't get stuck. }
    Q.UnregisterWorker(WorkerId);
  end;
end;

procedure TGatewayServer.HandleRelayRespond(const ReqId: string;
                                             ARequest: TIdHTTPRequestInfo;
                                             AResp: TIdHTTPResponseInfo);
(* POST /v1/relay/respond/<request_id>
   Body:
     { "content": "...",
       "finish_reason": "stop",
       "usage": { "prompt_tokens": 47, "completion_tokens": 8 } }

   Matches the in-flight request by id; signals the waiting
   TRelayProvider.Chat() caller via Done.SetEvent. Late / duplicate
   POSTs (worker submitted twice, another worker beat them) are a
   silent no-op inside Q.Respond.
*)
var
  Q: TRelayQueue;
  Body: string;
  Bytes: TBytes;
  Req, Usage, TCObj, FObj: TJsonObject;
  TCArr: TJsonArray;
  Resp: TRelayResponse;
  TC: TToolCall;
  i: Integer;
begin
  { Browser workers POSTing this response from a foreign origin need
    the response surfaced through CORS or fetch() rejects. Stamp the
    headers up front -- the WriteJSON branches below all preserve
    custom headers. }
  EmitRelayCors(ARequest, AResp);

  Q := GetGlobalRelayQueue;
  if Q = nil then
  begin
    WriteJSON(AResp, 503,
              '{"error":"relay disabled","message":"no relay queue initialised"}');
    Exit;
  end;

  if Trim(ReqId) = '' then
  begin
    WriteJSON(AResp, 400,
              '{"error":"missing id","message":"path must be /v1/relay/respond/<id>"}');
    Exit;
  end;

  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"empty body"}');
    Exit;
  end;

  FillChar(Resp, SizeOf(Resp), 0);
  Req := TJsonObject.Parse(Body);
  if Req = nil then
  begin
    WriteJSON(AResp, 400, '{"error":"invalid JSON"}');
    Exit;
  end;
  try
    Resp.Content      := Req.GetStr('content',       '');
    Resp.FinishReason := Req.GetStr('finish_reason', '');
    Resp.ErrMsg       := Req.GetStr('error',         '');
    Usage := Req.ChildObject('usage');
    if Usage <> nil then
    begin
      Resp.UsageInput  := Integer(Usage.GetInt('prompt_tokens',     0));
      Resp.UsageOutput := Integer(Usage.GetInt('completion_tokens', 0));
    end;
    { Codex P2 on PR #318: structured tool calls. Same OpenAI shape
      every other provider uses -- id / type / function.name /
      function.arguments. Workers that emit text-only replies get
      tool_calls absent and the agent gets text-only chat through the
      relay (same as V1). Workers using mlc-llm / WebLLM / llama.cpp
      grammar mode emit a proper tool_calls array which we forward
      verbatim through TRelayResponse.ToolCalls -> TLLMResponse.
      ToolCalls -> RunToolLoop's dispatch. }
    TCArr := Req.ChildArray('tool_calls');
    if TCArr <> nil then
      for i := 0 to TCArr.Count - 1 do
      begin
        TCObj := TCArr.ItemObject(i);
        if TCObj = nil then Continue;
        FillChar(TC, SizeOf(TC), 0);
        TC.Id   := TCObj.GetStr('id', '');
        TC.Kind := TCObj.GetStr('type', 'function');
        FObj := TCObj.ChildObject('function');
        if FObj <> nil then
        begin
          TC.Func.Name      := FObj.GetStr('name', '');
          TC.Func.Arguments := FObj.GetStr('arguments', '{}');
        end;
        { Round-trip the Gemini-3 thoughtSignature (or any future
          opaque per-tool-call provider blob). EncodeToolCalls on the
          worker side emits it as `provider_signature`; here we read
          it back into TC.ProviderSignature so TRelayProvider.
          DecodeResponse can copy it forward into TLLMResponse and the
          gateway-side agent loop threads it back into the next
          turn's BuildRelayRequestBody envelope. Without this, the
          worker's local Gemini 3 provider 400s on turn 2 with
          "Function call is missing a thought_signature." }
        TC.ProviderSignature := TCObj.GetStr('provider_signature', '');
        SetLength(Resp.ToolCalls, Length(Resp.ToolCalls) + 1);
        Resp.ToolCalls[High(Resp.ToolCalls)] := TC;
      end;
  finally
    Req.Free;
  end;

  Q.Respond(ReqId, Resp);
  WriteJSON(AResp, 200, '{"ok":true}');
end;

procedure TGatewayServer.HandleRelayStatus(ARequest: TIdHTTPRequestInfo;
                                            AResp: TIdHTTPResponseInfo);
(* GET /v1/relay/status -- queue depth, connected workers, per-worker
   caps + last-seen. Used by the TUI panel and `pasclaw status` and
   the webui's relay-tab mini-dashboard. *)
var
  Q: TRelayQueue;
  S: TRelayQueueStatus;
  Workers: TRelayWorkerArray;
  Root, WObj: TJsonObject;
  Arr: TJsonArray;
  CapsArr: TJsonArray;
  i, j: Integer;
begin
  EmitRelayCors(ARequest, AResp);
  Q := GetGlobalRelayQueue;
  if Q = nil then
  begin
    WriteJSON(AResp, 503,
              '{"error":"relay disabled","message":"no relay queue initialised"}');
    Exit;
  end;

  S := Q.GetStatus;
  Workers := Q.GetConnectedWorkers;

  Root := TJsonObject.Create;
  try
    Root.PutInt('pending_requests',  S.PendingRequests);
    Root.PutInt('inflight_requests', S.InflightRequests);
    Root.PutInt('connected_workers', S.ConnectedWorkers);
    Root.PutInt('total_enqueued',    S.TotalEnqueued);
    Root.PutInt('total_completed',   S.TotalCompleted);
    Root.PutInt('total_failed',      S.TotalFailed);

    Arr := TJsonArray.Create;
    for i := 0 to High(Workers) do
    begin
      WObj := TJsonObject.Create;
      WObj.PutStr('id', Workers[i].Id);
      CapsArr := TJsonArray.Create;
      for j := 0 to High(Workers[i].Capabilities) do
        CapsArr.AddStr(Workers[i].Capabilities[j]);
      WObj.PutArray('caps', CapsArr);
      WObj.PutInt('requests_seen', Workers[i].RequestsSeen);
      WObj.PutStr('last_seen', FormatDateTime('yyyy-mm-dd"T"hh:nn:ss',
                                                Workers[i].LastSeen));
      Arr.AddObject(WObj);
    end;
    Root.PutArray('workers', Arr);

    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

procedure TGatewayServer.HandleChat(ARequest: TIdHTTPRequestInfo;
                                    AResp: TIdHTTPResponseInfo);
var
  Body, Prompt: string;
  Bytes: TBytes;
  Req, RespJ: TJsonObject;
  Msgs: TMessageArray;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  Prim: ILLMProvider;
  FB: TLLMProviderArray;
  DefModel: string;
begin
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      { Bodies are JSON, by convention UTF-8. Decoding here means the
        Delphi build sees the same string the FPC build does. }
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"empty body"}');
    Exit;
  end;

  Prompt := '';
  Req := TJsonObject.Parse(Body);
  if Req <> nil then
  try
    Prompt := Req.GetStr('message', '');
  finally
    Req.Free;
  end;

  if Prompt = '' then
  begin
    WriteJSON(AResp, 400, '{"error":"missing field: message"}');
    Exit;
  end;

  { Snapshot provider + fallbacks + default model together (one lock) so a live
    /v1/config swap can't pair the new model with the old provider. }
  SnapshotRuntime(Prim, FB, DefModel);
  LoopCfg.Provider := Prim;
  if LoopCfg.Provider = nil then
  begin
    WriteJSON(AResp, 503, '{"error":"no provider configured"}');
    Exit;
  end;

  SetLength(Msgs, 1);
  Msgs[0] := MakeMessage(mrUser, Prompt);

  LoopCfg.Registry      := FRegistry;
  if FToolsHonorInMemoryConfig then LoopCfg.ActiveConfig := FCfg;
  LoopCfg.Model         := DefModel;
  LoopCfg.MaxIterations := 8;
  LoopCfg.Parallel := True;
  { PR #290: per-request Plan/Build. Defaults to pmBuild when the body
    omits "mode", so OpenAI-compatible clients that don't know about
    plan keep working unchanged. }
  LoopCfg.Mode          := ParseModeFromBody(Body);
  LoopCfg.Fallbacks     := FB;
  LoopCfg.Options       := DefaultChatOptions;
  ApplyPromptCacheConfig(LoopCfg.Options, FCfg.PromptCache);
  LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '',
                                  LoopCfg.Registry <> nil, '', LoopCfg.Mode);
  { Identity stamping. When Cfg.Gateway.Token is set, the request
    reaching this point already passed CheckGatewayAuth's bearer
    check (or hit an exempt route), so we stamp 'gateway:authed' so
    `allow_senders: ["gateway:authed"]` is a meaningful allowlist
    entry. When the token is empty (unauthenticated mode), keep the
    legacy 'gateway:anon' so existing allowlists / hook gates don't
    silently change shape. }
  if GetEffectiveGatewayToken(FCfg) <> '' then
    LoopCfg.Identity := MakeIdentity('gateway', 'authed')
  else
    LoopCfg.Identity := MakeIdentity('gateway', 'anon');
  LoopCfg.OnText        := nil;
  LoopCfg.OnToolCall    := nil;
  LoopCfg.OnToolResult  := nil;
  LoopCfg.CompactEnabled := True;
  LoopCfg.CompactOpts    := DefaultCompactOptions;
  LoopCfg.ToolOutputCap := FCfg.ToolOutputCap;
  LoopCfg.StreamReliability := FCfg.StreamReliability;

  if not RunCheckpointedLoop(ReqSessionId(ARequest), LoopCfg, Msgs, Loop) then
  begin
    WriteJSON(AResp, 502, '{"error":"loop failed"}');
    Exit;
  end;
  AccumulateGatewayStats(FCfg, GW_BUCKET_V1_CHAT,
                         '(gateway: /v1/chat)',
                         LoopCfg.Provider.GetName, LoopCfg.Model, Loop);

  RespJ := TJsonObject.Create;
  try
    RespJ.PutStr('content',       Loop.Content);
    RespJ.PutInt('iterations',    Loop.Iterations);
    RespJ.PutInt('input_tokens',  Loop.LastResp.Usage.InputTokens);
    RespJ.PutInt('output_tokens', Loop.LastResp.Usage.OutputTokens);
    WriteJSON(AResp, 200, RespJ.ToJSON);
  finally
    RespJ.Free;
  end;
end;

function GenChatCompletionId: string;
{ Mirror OpenAI's "chatcmpl-<random>" id convention. The exact value is
  opaque to clients -- what matters is that it's unique per call. We seed
  from Random + a millisecond timestamp; sufficient for log correlation. }
const
  Alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
var
  i: Integer;
begin
  Result := 'chatcmpl-';
  for i := 1 to 24 do
    Result := Result + Alphabet[1 + Random(Length(Alphabet))];
end;

function BuildOpenAICompletion(const Id, Model, Content: string;
                                Usage: TUsageInfo;
                                const FinishReason: string): TJsonObject;
{ Construct an OpenAI Chat Completions response object -- the non-streaming
  shape that the OpenAI SDK / LangChain / autogen / etc. all parse. }
var
  Choice, Msg, UsageObj: TJsonObject;
  ChoicesArr: TJsonArray;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',      Id);
  Result.PutStr('object',  'chat.completion');
  Result.PutInt('created', DateTimeToUnix(Now, False));
  Result.PutStr('model',   Model);

  Msg := TJsonObject.Create;
  Msg.PutStr('role',    'assistant');
  Msg.PutStr('content', Content);

  Choice := TJsonObject.Create;
  Choice.PutInt('index', 0);
  Choice.PutObject('message', Msg);
  Choice.PutStr('finish_reason', FinishReason);

  ChoicesArr := TJsonArray.Create;
  ChoicesArr.AddObject(Choice);
  Result.PutArray('choices', ChoicesArr);

  UsageObj := TJsonObject.Create;
  UsageObj.PutInt('prompt_tokens',     Usage.InputTokens);
  UsageObj.PutInt('completion_tokens', Usage.OutputTokens);
  UsageObj.PutInt('total_tokens',      Usage.InputTokens + Usage.OutputTokens);
  Result.PutObject('usage', UsageObj);
end;

function BuildOpenAIChunk(const Id, Model, DeltaContent: string;
                           const FinishReason: string): string;
{ Construct one "data: ..." line for the SSE stream. Empty
  FinishReason omits the field; the terminating chunk passes 'stop'. }
var
  Root, Choice, Delta: TJsonObject;
  ChoicesArr: TJsonArray;
begin
  Root := TJsonObject.Create;
  try
    Root.PutStr('id',      Id);
    Root.PutStr('object',  'chat.completion.chunk');
    Root.PutInt('created', DateTimeToUnix(Now, False));
    Root.PutStr('model',   Model);

    Delta := TJsonObject.Create;
    if DeltaContent <> '' then
      Delta.PutStr('content', DeltaContent);

    Choice := TJsonObject.Create;
    Choice.PutInt('index', 0);
    Choice.PutObject('delta', Delta);
    if FinishReason <> '' then Choice.PutStr('finish_reason', FinishReason);

    ChoicesArr := TJsonArray.Create;
    ChoicesArr.AddObject(Choice);
    Root.PutArray('choices', ChoicesArr);

    Result := 'data: ' + Root.ToJSON + #10#10;
  finally
    Root.Free;
  end;
end;

type
  (* Helper that streams SSE chunks directly to the TCP connection
     while the tool loop is still running. Indy's TIdHTTPResponseInfo
     normally buffers the entire body into a ContentStream and flushes
     at the end of the handler -- that's fine for /v1/chat (one
     response per call) but with /v1/chat/completions stream:true and
     a long tool loop the client sees no bytes for many seconds. We
     issue WriteHeader once up front so the headers go on the wire,
     then write per-iteration chunks through the IOHandler so the
     client renders tool progress in real time. CloseConnection=True
     terminates the response when the handler returns; no
     Content-Length is needed. *)
  TSSEStreamer = class
  private
    FContext: TIdContext;
    FId, FModel: string;
    FDebugIO: Boolean;
    FClosed: Boolean;
    procedure WriteSocketBytes(const Data: TBytes);
  public
    constructor Create(AContext: TIdContext; const Id, Model: string;
                       DebugIO: Boolean);
    { Emits Data as a single HTTP/1.1 chunked-encoding chunk. Use this
      for SSE event payloads -- every WriteChunk / WriteComment goes
      through here. }
    procedure WriteRaw(const Data: string);
    procedure WriteChunk(const DeltaContent, FinishReason: string);
    procedure WriteComment(const Note: string);
    procedure WriteError(const Msg: string);
    procedure NoteToolCall(const Name, ArgsJSON: string);
    procedure NoteToolResult(const Name, ResultText, Err: string);
    procedure Finalize(const Content, FinishReason: string);
    { Writes the zero-length terminator chunk that ends a chunked
      transfer-encoding response. Called by Finalize. }
    procedure CloseStream;
    property Closed: Boolean read FClosed;
  end;

function EmitSSEResponseHeaders(AContext: TIdContext;
                                AResp: TIdHTTPResponseInfo): Boolean;
(* Write the SSE response status line + headers raw via the underlying
   socket, bypassing Indy's TIdHTTPResponseInfo.WriteHeader entirely.

   Why this exists: Indy's WriteHeader emits both `Content-Length: 0`
   AND `Transfer-Encoding: chunked` for streaming responses (the
   ContentLength := -1 "suppress auto Content-Length" workaround
   doesn't actually suppress -- it leaves CL=0 in place because
   Indy treats negative values as "fall through to ContentText length"
   which is empty). That combination is a HTTP/1.1 protocol violation
   per RFC 7230 §3.3.3 -- strict L7 proxies (DigitalOcean App
   Platform's Envoy frontend, AWS ALB in strict mode, Cloudflare
   Workers) reject it with `upstream_reset_before_response_started
   {protocol_error}` and never forward the response body. Loose
   proxies (nginx default, local curl) tolerate it, which is why
   the bug only shows up on managed platforms.

   Indy ALSO rewrites our `text/event-stream` ContentType back to
   `text/html; charset=utf-8` under conditions that are hard to
   override from outside the unit (around the Content-Length /
   Transfer-Encoding interaction). Bypassing WriteHeader fixes
   that too -- the literal bytes in HeaderStr are what reach the
   wire verbatim.

   This is the same workaround HandleLogs has been using since the
   `/v1/logs` SSE feed shipped; centralising it into a helper means
   the same fix applies to /v1/chat/completions and /v1/responses
   without duplicating the byte-twiddle.

   Returns True on success; on a write exception, logs at warn and
   returns False so the caller can Exit without trying to emit
   body chunks against a half-dead connection. *)
var
  HeaderStr, CustomHeadersStr: string;
  HeaderTmp: TBytes;
  HeaderIdBytes: TIdBytes;
  i: Integer;
begin
  Result := False;
  { Include any AResp.CustomHeaders the caller added BEFORE invoking
    us (e.g. EmitRelayCors on /v1/relay/poll). Bypassing
    WriteHeader means Indy never emits them on its own, so they have
    to be appended here for cross-origin browser workers to see CORS
    headers on the SSE response. }
  CustomHeadersStr := '';
  for i := 0 to AResp.CustomHeaders.Count - 1 do
    CustomHeadersStr := CustomHeadersStr + AResp.CustomHeaders[i] + #13#10;
  HeaderStr :=
    'HTTP/1.1 200 OK'#13#10 +
    'Content-Type: text/event-stream; charset=utf-8'#13#10 +
    'Cache-Control: no-cache, no-transform'#13#10 +
    'Connection: keep-alive'#13#10 +
    'X-Accel-Buffering: no'#13#10 +
    'Transfer-Encoding: chunked'#13#10 +
    'Server: PasClaw/' + FormatVersion + #13#10 +
    CustomHeadersStr +
    #13#10;
  try
    SetLength(HeaderTmp, Length(HeaderStr));
    HeaderTmp := TEncoding.ASCII.GetBytes(HeaderStr);
    SetLength(HeaderIdBytes, Length(HeaderTmp));
    for i := 0 to High(HeaderTmp) do HeaderIdBytes[i] := HeaderTmp[i];
    AContext.Connection.IOHandler.Write(HeaderIdBytes);
    while AContext.Connection.IOHandler.WriteBufferingActive do
      AContext.Connection.IOHandler.WriteBufferClose;
  except
    on E: Exception do
    begin
      LogWarn('sse: failed to emit headers: %s', [E.Message]);
      Exit;
    end;
  end;
  (* Tell Indy not to emit its own headers when the request handler
     returns. AResp.HeaderHasBeenWritten is the public flag for "I've
     written my own status + headers, stay out of it." Clearing
     ContentText / ContentLength keeps Indy from queuing a body
     after our chunked stream finishes (the terminator chunk goes
     out via TSSEStreamer.CloseStream). *)
  AResp.HeaderHasBeenWritten := True;
  AResp.ContentText  := '';
  AResp.ContentLength := 0;
  AResp.ResponseNo   := 200;
  Result := True;
end;

constructor TSSEStreamer.Create(AContext: TIdContext; const Id, Model: string;
                                DebugIO: Boolean);
begin
  inherited Create;
  FContext := AContext;
  FId      := Id;
  FModel   := Model;
  FDebugIO := DebugIO;
  FClosed  := False;
end;

procedure TSSEStreamer.WriteSocketBytes(const Data: TBytes);
var
  Bytes: TIdBytes;
  i: Integer;
begin
  if Length(Data) = 0 then Exit;
  if (FContext = nil) or (FContext.Connection = nil) or
     (not FContext.Connection.Connected) then
  begin
    if FDebugIO then
      LogDebug('sse: connection already closed before write of %d bytes', [Length(Data)]);
    Exit;
  end;
  SetLength(Bytes, Length(Data));
  for i := 0 to High(Data) do Bytes[i] := Data[i];
  try
    FContext.Connection.IOHandler.Write(Bytes);
    (* TIdHTTPServer's request handler runs inside WriteBufferOpen so
       it can compute Content-Length. We don't want that -- every byte
       has to land on the wire as soon as we emit it. Loop
       WriteBufferClose until WriteBufferingActive is False to drain
       the nested server + WriteHeader buffer stack. After the first
       chunk drains it the loop becomes a no-op. *)
    while FContext.Connection.IOHandler.WriteBufferingActive do
      FContext.Connection.IOHandler.WriteBufferClose;
  except
    on E: Exception do
      if FDebugIO then LogDebug('sse: write failed: %s', [E.Message]);
  end;
end;

procedure TSSEStreamer.WriteRaw(const Data: string);
const
  CRLF: array[0..1] of Byte = (13, 10);
var
  Payload, Header, Frame: TBytes;
  HeaderStr, Tagged: string;
  i, Offset: Integer;
begin
  { Same FPC retag the body writer does -- without it, a CP_0-tagged
    Data string (e.g. literal SSE control text like 'data: [DONE]'
    or fragments built across mixed-codepage concatenations) goes
    through TEncoding.UTF8.GetBytes assuming system codepage and
    double-encodes any non-ASCII byte. The chunked SSE path bypasses
    WriteBodyStream entirely, so it needs its own retag. }
  Tagged := Data;
  TagUTF8(Tagged);
  Payload := TEncoding.UTF8.GetBytes(Tagged);
  if Length(Payload) = 0 then Exit;
  (* HTTP/1.1 chunked-transfer chunk: `<hex-length>\r\n<bytes>\r\n`.
     The response header (set by HandleChatCompletions) carries
     `Transfer-Encoding: chunked`; the terminator chunk (`0\r\n\r\n`)
     is written by CloseStream when Finalize runs. Framing each SSE
     event as its own chunk is what lets the client parse partial
     responses as they arrive instead of treating the absent
     Content-Length as a zero-byte body and closing immediately. *)
  HeaderStr := IntToHex(Length(Payload), 1) + #13#10;
  Header := TEncoding.UTF8.GetBytes(HeaderStr);
  SetLength(Frame, Length(Header) + Length(Payload) + 2);
  Offset := 0;
  for i := 0 to High(Header)  do begin Frame[Offset] := Header[i];  Inc(Offset); end;
  for i := 0 to High(Payload) do begin Frame[Offset] := Payload[i]; Inc(Offset); end;
  Frame[Offset]     := CRLF[0];
  Frame[Offset + 1] := CRLF[1];
  WriteSocketBytes(Frame);
end;

procedure TSSEStreamer.CloseStream;
var
  Terminator: TBytes;
begin
  if FClosed then Exit;
  FClosed := True;
  Terminator := TEncoding.UTF8.GetBytes('0'#13#10#13#10);
  WriteSocketBytes(Terminator);
end;

procedure TSSEStreamer.WriteChunk(const DeltaContent, FinishReason: string);
begin
  WriteRaw(BuildOpenAIChunk(FId, FModel, DeltaContent, FinishReason));
end;

procedure TSSEStreamer.WriteComment(const Note: string);
var
  Clean: string;
begin
  (* Lines starting with `:` are SSE comments per the spec -- every
     compliant client (openai-python, anthropic-sdk, langchain,
     autogen) skips them silently.

     IMPORTANT: callers pass arbitrary content here (tool argsJSON,
     tool result text). If the body contains a newline followed by
     `data: ...` or another SSE field, a naive `: ' + Note + #10#10`
     would let that line be parsed as a real event, terminating or
     corrupting the stream. Strip CR and prefix EVERY line of the
     body with `: ` so the whole thing stays inside the comment, then
     append the empty-line terminator. *)
  Clean := StringReplace(Note, #13, '', [rfReplaceAll]);
  Clean := StringReplace(Clean, #10, #10': ', [rfReplaceAll]);
  WriteRaw(': ' + Clean + #10#10);
end;

procedure TSSEStreamer.WriteError(const Msg: string);
var
  Root, Err: TJsonObject;
begin
  (* Stream-mode error after headers are already on the wire. We can't
     change the status, but we can send an OpenAI-style error frame
     followed by [DONE] so clients that recognize streaming errors
     surface them properly instead of treating an assistant turn that
     says "tool loop failed" as a normal completion. *)
  Root := TJsonObject.Create;
  try
    Err := TJsonObject.Create;
    Err.PutStr('message', Msg);
    Err.PutStr('type',    'server_error');
    Root.PutObject('error', Err);
    WriteRaw('data: ' + Root.ToJSON + #10#10);
  finally
    Root.Free;
  end;
  WriteRaw('data: [DONE]'#10#10);
  CloseStream;
end;

procedure TSSEStreamer.NoteToolCall(const Name, ArgsJSON: string);
var
  Preview: string;
begin
  (* One visible delta carrying a Claude-Code-style summary (tool name +
     its key argument) so the client renders real progress, not just a
     bare name. The visible delta is the bit that turns the long silence
     into a heartbeat the user can see in their chat UI; the full args
     still go to the debug log and the SSE comment below for any consumer
     that wants to log structured tool activity. Standard OpenAI clients
     drop the comment, which is exactly why the summary has to be visible. *)
  Preview := ArgsJSON;
  if Length(Preview) > 200 then Preview := Copy(Preview, 1, 200) + '...';
  if FDebugIO then
    LogDebug('chat/completions tool_call: name=%s args=%s', [Name, ArgsJSON]);
  WriteChunk(#10 + FormatToolCallLine(Name, ArgsJSON) + #10, '');
  WriteComment('tool_call name=' + Name + ' args=' + Preview);
  { Structured side-channel for the web UI's expandable card: full args as
    one-line JSON in a comment OpenAI clients ignore. }
  WriteComment('pasclaw-tool ' + FormatToolDetailJSON('call', Name, ArgsJSON, '', ''));
end;

procedure TSSEStreamer.NoteToolResult(const Name, ResultText, Err: string);
var
  Status, Preview: string;
begin
  if Err <> '' then Status := 'err: ' + Err
  else if Length(ResultText) < 80 then Status := ResultText
  else Status := IntToStr(Length(ResultText)) + ' bytes';
  if FDebugIO then
  begin
    Preview := ResultText;
    if Length(Preview) > 4000 then Preview := Copy(Preview, 1, 4000) + '...';
    LogDebug('chat/completions tool_result: name=%s err=%s result=%s',
             [Name, Err, Preview]);
  end;
  (* Visible delta summarizing the outcome (line/byte counts with a first-line
     peek, a short echo, or the error) on its own indented line under the call
     -- previously this went only to the dropped SSE comment, so the client saw
     the call but never its result. *)
  WriteChunk(FormatToolResultLine(Name, ResultText, Err) + #10, '');
  WriteComment('tool_result name=' + Name + ' ' + Status);
  { Structured side-channel: full result (or error) for the web UI card. }
  WriteComment('pasclaw-tool ' + FormatToolDetailJSON('result', Name, '', ResultText, Err));
end;

procedure TSSEStreamer.Finalize(const Content, FinishReason: string);
begin
  WriteChunk(Content, '');
  WriteChunk('', FinishReason);
  WriteRaw('data: [DONE]'#10#10);
  CloseStream;
end;

type
  { Per-request collector that hooks LoopCfg.OnToolCall/OnToolResult on the
    non-streaming chat-completions path. RunToolLoop runs tools server-side
    and the buffered Chat Completions response shape has no standard slot
    for "tools that already ran" -- so we collect ToolView's friendly per-
    tool lines here (the same ones the streaming path emits as visible
    deltas via TSSEStreamer.NoteToolCall/NoteToolResult) and the handler
    prepends them above the model's content. Both delivery modes now show
    the same activity transcript. }
  TToolActivityCollector = class
  public
    Lines: TStringList;
    constructor Create;
    destructor Destroy; override;
    procedure OnToolCall(const Name, ArgsJSON: string);
    procedure OnToolResult(const Name, ResultText, Err: string);
    function Transcript: string;
  end;

constructor TToolActivityCollector.Create;
begin
  inherited Create;
  Lines := TStringList.Create;
end;

destructor TToolActivityCollector.Destroy;
begin
  Lines.Free;
  inherited Destroy;
end;

procedure TToolActivityCollector.OnToolCall(const Name, ArgsJSON: string);
begin
  Lines.Add(FormatToolCallLine(Name, ArgsJSON));
end;

procedure TToolActivityCollector.OnToolResult(const Name, ResultText, Err: string);
begin
  Lines.Add(FormatToolResultLine(Name, ResultText, Err));
end;

function TToolActivityCollector.Transcript: string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to Lines.Count - 1 do
  begin
    if i > 0 then Result := Result + #10;
    Result := Result + Lines[i];
  end;
end;

function PrependToolActivity(Collector: TToolActivityCollector;
                              const Content: string): string;
{ Stick the tool transcript above the model's content with a blank-line
  separator, mirroring how the streaming path renders activity as deltas
  before the final assistant text. Empty transcript or empty collector
  means Content unchanged. }
var
  T: string;
begin
  if (Collector = nil) or (Collector.Lines.Count = 0) then
  begin
    Result := Content;
    Exit;
  end;
  T := Collector.Transcript;
  if Trim(Content) = '' then
    Result := T
  else
    Result := T + #10#10 + Content;
end;

procedure TGatewayServer.HandleChatCompletions(AContext: TIdContext;
                                                ARequest: TIdHTTPRequestInfo;
                                                AResp: TIdHTTPResponseInfo;
                                                out AWasStreamingRequest: Boolean;
                                                out AResponseStarted: Boolean);
(* OpenAI Chat Completions API. Accepts the standard request shape
   (model, messages array of role/content objects, optional temperature,
   max_tokens, stream, tools) and routes through the existing tool loop.

   When stream:true is set we flush response headers immediately, then
   write SSE chunks to the connection as the tool loop progresses --
   one visible delta per tool call so the client renders activity in
   real time, plus structured SSE comments any consumer can log. After
   the loop completes we write the final content delta, a finish-reason
   chunk, and the [DONE] terminator. The non-streaming path is
   unchanged: build the full chat.completion JSON and reply once. *)
var
  Body, ReqModel, FinishReason, CompId: string;
  Bytes: TBytes;
  Req, MsgObj: TJsonObject;
  MsgArr: TJsonArray;
  Msgs: TMessageArray;
  i: Integer;
  WantsStream: Boolean;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  RawTemp: Double;
  ReplyObj: TJsonObject;
  Streamer: TSSEStreamer;
  StreamStarted, StreamClosed: Boolean;
  ActivityCollector: TToolActivityCollector;
  Prim: ILLMProvider;
  FB: TLLMProviderArray;
  SnapModel: string;
  function SanitizeStreamError(const S: string): string;
  begin
    Result := StringReplace(S, #13, ' ', [rfReplaceAll]);
    Result := StringReplace(Result, #10, ' ', [rfReplaceAll]);
    Result := Trim(Result);
    if Result = '' then Result := 'unknown failure';
  end;
begin
  Streamer := nil;
  StreamStarted := False;
  StreamClosed := False;
  AWasStreamingRequest := False;
  ActivityCollector := nil;
  AResponseStarted := False;
  Body := '';
  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if FDebugIO then
    LogDebug('chat/completions <- %d bytes from %s: %s',
             [Length(Bytes), ARequest.RemoteIP, Body]);

  if Trim(Body) = '' then
  begin
    if FDebugIO then LogDebug('chat/completions -> 400 (empty body)');
    WriteJSON(AResp, 400,
      '{"error":{"message":"empty request body","type":"invalid_request_error"}}');
    Exit;
  end;

  Req := TJsonObject.Parse(Body);
  if Req = nil then
  begin
    if FDebugIO then LogDebug('chat/completions -> 400 (invalid JSON)');
    WriteJSON(AResp, 400,
      '{"error":{"message":"invalid JSON","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    ReqModel    := Req.GetStr('model', FCfg.DefaultModel);
    WantsStream := Req.GetBool('stream', False);
    AWasStreamingRequest := WantsStream;
    if FDebugIO then
      LogDebug('chat/completions: model=%s stream=%s temperature=%g max_tokens=%d',
               [ReqModel, BoolToStr(WantsStream, True),
                Req.GetFloat('temperature', 0),
                Req.GetInt('max_tokens', 0)]);

    { Walk messages[] -> TMessageArray. We accept the OpenAI shape but
      pass the raw content string through; multimodal/image parts get
      flattened by treating content as plain text only. }
    MsgArr := Req.ChildArray('messages');
    if (MsgArr = nil) or (MsgArr.Count = 0) then
    begin
      if FDebugIO then LogDebug('chat/completions -> 400 (no messages[])');
      WriteJSON(AResp, 400,
        '{"error":{"message":"missing or empty messages[]","type":"invalid_request_error"}}');
      if MsgArr <> nil then MsgArr.Free;
      Exit;
    end;
    try
      SetLength(Msgs, MsgArr.Count);
      for i := 0 to MsgArr.Count - 1 do
      begin
        MsgObj := MsgArr.ItemObject(i);
        if MsgObj = nil then Continue;
        try
          Msgs[i] := MakeMessage(MsgRoleFromString(MsgObj.GetStr('role', 'user')),
                                  MsgObj.GetStr('content', ''));
        finally
          MsgObj.Free;
        end;
      end;
    finally
      MsgArr.Free;
    end;

    { Provider + fallbacks snapshotted together (model is the request's
      ReqModel, resolved at parse). }
    SnapshotRuntime(Prim, FB, SnapModel);
    LoopCfg.Provider := Prim;
    if LoopCfg.Provider = nil then
    begin
      if FDebugIO then LogDebug('chat/completions -> 503 (no provider configured)');
      WriteJSON(AResp, 503,
        '{"error":{"message":"no provider configured","type":"server_error"}}');
      Exit;
    end;

    LoopCfg.Registry      := FRegistry;
    if FToolsHonorInMemoryConfig then LoopCfg.ActiveConfig := FCfg;
    LoopCfg.Model         := ReqModel;
    LoopCfg.MaxIterations := FMaxIter;
    LoopCfg.Parallel := True;
    LoopCfg.Mode          := ParseModeFromBody(Body);  { PR #290 }
    LoopCfg.Fallbacks     := FB;
    LoopCfg.Options       := DefaultChatOptions;
    ApplyPromptCacheConfig(LoopCfg.Options, FCfg.PromptCache);
    if GetEffectiveGatewayToken(FCfg) <> '' then
      LoopCfg.Identity := MakeIdentity('gateway', 'authed')
    else
      LoopCfg.Identity := MakeIdentity('gateway', 'anon');
    { Inject the composed PasClaw system prompt -- but only if the client
      didn't already supply one of their own. Third-party tooling calling
      /v1/chat/completions with its own persona/system message should win;
      bare-bones clients that send only a user message get our identity
      preamble for free. }
    if not HasSystemMessage(Msgs) then
      LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '',
                                      LoopCfg.Registry <> nil, '', LoopCfg.Mode);
    { Temperature: forward only when the client explicitly sent the field
      (Req.Has), so an absent field keeps the provider/library default
      rather than pinning 0. An explicit 0 IS honoured -- it's a valid
      deterministic setting (the web UI's params sidebar exposes it).
      Negatives are ignored as malformed. }
    if Req.Has('temperature') then
    begin
      RawTemp := Req.GetFloat('temperature', 0);
      if RawTemp >= 0 then LoopCfg.Options.Temperature := RawTemp;
    end;
    if Req.Has('max_tokens') then
      LoopCfg.Options.MaxTokens := Req.GetInt('max_tokens', LoopCfg.Options.MaxTokens);
    LoopCfg.OnText        := nil;
    LoopCfg.OnToolCall    := nil;
    LoopCfg.OnToolResult  := nil;
    LoopCfg.CompactEnabled := True;
    LoopCfg.CompactOpts    := DefaultCompactOptions;
    LoopCfg.ToolOutputCap := FCfg.ToolOutputCap;
    LoopCfg.StreamReliability := FCfg.StreamReliability;

    { Tool-call repair: synthesize stub tool_result messages for any
      assistant tool_call.Id in the incoming history that lacks a
      paired mrTool. Strict OpenAI-compat backends (DeepSeek,
      MiniMax-class) reject the request with HTTP 400 when these
      orphans reach them. The repair runs once at the gateway
      boundary before the tool loop -- subsequent loop-managed
      tool_call/tool_result pairs are appended in lock-step so
      cannot orphan. }
    if FCfg.StreamReliability.ToolCallRepairEnabled then
      RepairOrphanedToolCalls(Msgs);

    CompId := GenChatCompletionId;

    if WantsStream then
    begin
      { Dedicated guard for all streamed execution once headers are emitted.
        After this point we must never fall back to WriteJSON. }
      try
      { Stream path: flush SSE headers up front and hook the tool loop
        so chunks reach the client as each tool call happens. The loop
        itself still runs synchronously in this thread; the difference
        is the response body now drains incrementally instead of all
        at once at the end. }
      (* Emit SSE headers raw via the socket. AResp.WriteHeader is
         poisonous here -- it emits Content-Length: 0 alongside
         Transfer-Encoding: chunked, which is a RFC 7230 §3.3.3
         protocol violation that DigitalOcean App Platform's Envoy
         proxy (and other strict L7 proxies) reset with
         `upstream_reset_before_response_started{protocol_error}`
         before forwarding any body bytes. See EmitSSEResponseHeaders'
         long-form comment for the full story. *)
      if not EmitSSEResponseHeaders(AContext, AResp) then Exit;
      StreamStarted    := True;
      AResponseStarted := True;
      if FDebugIO then
        LogDebug('sse: headers flushed, connection still up=%s',
                 [BoolToStr(AContext.Connection.Connected, True)]);
      Streamer := TSSEStreamer.Create(AContext, CompId, ReqModel, FDebugIO);
      LoopCfg.OnToolCall   := Streamer.NoteToolCall;
      LoopCfg.OnToolResult := Streamer.NoteToolResult;
      Streamer.WriteComment('connected');
      if not RunCheckpointedLoop(ReqSessionId(ARequest), LoopCfg, Msgs, Loop) then
      begin
        if FDebugIO then LogDebug('chat/completions -> 502 (tool loop failed)');
        Streamer.WriteError('tool loop failed');
        StreamClosed := Streamer.Closed;
        Exit;
      end;
      AccumulateGatewayStats(FCfg, GW_BUCKET_V1_CHAT_COMPLETIONS,
                             '(gateway: /v1/chat/completions)',
                             LoopCfg.Provider.GetName, ReqModel, Loop);
      if Loop.LastResp.FinishReason <> '' then
        FinishReason := Loop.LastResp.FinishReason
      else
        FinishReason := 'stop';

      if Length(Loop.LastResp.ToolCalls) > 0 then
      begin
        Loop.Content := Trim(Loop.Content);
        if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
        Loop.Content := Loop.Content + FormatMaxIterNotice(Loop, FMaxIter,
          '`--max-iter` on `pasclaw serve` or `max_iterations` in config', True);
        FinishReason := 'length';
        LogWarn('chat/completions: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
                [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
      end
      else if Trim(Loop.Content) = '' then
      begin
        Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                                [FinishReason]);
        LogWarn('chat/completions: empty content with finish=%s iterations=%d',
                [FinishReason, Loop.Iterations]);
      end;

      if FDebugIO then
        LogDebug('chat/completions: tool loop done iterations=%d in=%d out=%d finish=%s content=%s',
                 [Loop.Iterations, Loop.LastResp.Usage.InputTokens,
                  Loop.LastResp.Usage.OutputTokens, FinishReason, Loop.Content]);
      if FDebugIO then LogDebug('chat/completions -> 200 SSE (final)');
      Streamer.Finalize(Loop.Content, FinishReason);
      StreamClosed := Streamer.Closed;
      except
        on E: Exception do
        begin
          if StreamStarted and (not StreamClosed) and
             (Streamer <> nil) and (not Streamer.Closed) then
          begin
            try
              Streamer.WriteError('internal error: ' + SanitizeStreamError(E.Message));
              { Previously assigned StreamClosed := Streamer.Closed here;
                dropped -- `raise;` below unwinds the stack so the value
                is never read. dcc64 H2077 cleanup. }
            except
              if (AContext <> nil) and (AContext.Connection <> nil) then
                AContext.Connection.Disconnect;
            end;
          end
          else if (AContext <> nil) and (AContext.Connection <> nil) then
            AContext.Connection.Disconnect;
          raise;
        end;
      end;
      Exit;
    end;

    { The non-streaming path collects ToolView-formatted activity lines via
      OnToolCall/OnToolResult and prepends them above the model's content
      below -- so frontends that buffer the whole JSON reply see the same
      transcript the streaming path emits as visible deltas through
      TSSEStreamer. }
    ActivityCollector := TToolActivityCollector.Create;
    LoopCfg.OnToolCall   := ActivityCollector.OnToolCall;
    LoopCfg.OnToolResult := ActivityCollector.OnToolResult;

    if not RunCheckpointedLoop(ReqSessionId(ARequest), LoopCfg, Msgs, Loop) then
    begin
      if FDebugIO then LogDebug('chat/completions -> 502 (tool loop failed)');
      WriteJSON(AResp, 502,
        '{"error":{"message":"tool loop failed","type":"server_error"}}');
      Exit;
    end;
    AccumulateGatewayStats(FCfg, GW_BUCKET_V1_CHAT_COMPLETIONS,
                           '(gateway: /v1/chat/completions)',
                           LoopCfg.Provider.GetName, ReqModel, Loop);

    if Loop.LastResp.FinishReason <> '' then
      FinishReason := Loop.LastResp.FinishReason
    else
      FinishReason := 'stop';

    { Tag cap-exhausted turns regardless of whether the model produced
      pre-tool narration. The discriminator is the presence of pending
      tool calls in the last response: RunToolLoop only exits via the
      cap when the last turn had ToolCalls (otherwise it early-returns
      cleanly). Iterations >= FMaxIter alone is ambiguous since a clean
      completion on the very last allowed turn also reports that count.

      When the cap is hit:
        - empty Content -> the cap note is the whole message
        - non-empty Content (model said "Let me check..." then called a
          tool) -> keep the partial text and append the cap note. Set
          finish_reason=length so clients don't treat a truncated tool
          loop as a completed answer. }
    if Length(Loop.LastResp.ToolCalls) > 0 then
    begin
      Loop.Content := Trim(Loop.Content);
      if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
      Loop.Content := Loop.Content + FormatMaxIterNotice(Loop, FMaxIter,
        '`--max-iter` on `pasclaw serve` or `max_iterations` in config', True);
      FinishReason := 'length';
      LogWarn('chat/completions: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
              [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
    end
    else if Trim(Loop.Content) = '' then
    begin
      { Loop exited normally with no pending tool calls but the model
        produced no text. Some streaming clients can't represent that. }
      Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                              [FinishReason]);
      LogWarn('chat/completions: empty content with finish=%s iterations=%d',
              [FinishReason, Loop.Iterations]);
    end;

    if FDebugIO then
      LogDebug('chat/completions: tool loop done iterations=%d in=%d out=%d finish=%s content=%s',
               [Loop.Iterations, Loop.LastResp.Usage.InputTokens,
                Loop.LastResp.Usage.OutputTokens, FinishReason, Loop.Content]);

    Loop.Content := PrependToolActivity(ActivityCollector, Loop.Content);

    ReplyObj := BuildOpenAICompletion(CompId, ReqModel, Loop.Content,
                                       Loop.LastResp.Usage, FinishReason);
    try
      if FDebugIO then LogDebug('chat/completions -> 200 JSON: %s', [ReplyObj.ToJSON]);
      WriteJSON(AResp, 200, ReplyObj.ToJSON);
    finally
      ReplyObj.Free;
    end;
  finally
    Req.Free;
    if Streamer <> nil then Streamer.Free;
    if ActivityCollector <> nil then ActivityCollector.Free;
  end;
end;


function GenResponseId: string;
{ Opaque Responses API id. Keep it distinct from chatcmpl-* so logs can
  distinguish which OpenAI-compatible surface handled the request. }
const
  Alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
var
  i: Integer;
begin
  Result := 'resp_';
  for i := 1 to 24 do
    Result := Result + Alphabet[1 + Random(Length(Alphabet))];
end;

{ ============= provider-signature cache (Gemini 3 thoughtSignature) =============

  PR #154 added a `provider_signature` extension field on /v1/responses
  function_call output items so PasClaw could round-trip Gemini 3+'s
  thoughtSignature across turns. That works for a PasClaw-aware client.
  Codex CLI (and any stock OpenAI-Responses client) JSON-validates input
  items and drops unknown fields -- so the signature is gone by the next
  turn, and Gemini 3 returns:

      400 Function call is missing a thought_signature in functionCall parts.

  Belt-and-suspenders: also keep a process-wide call_id -> signature map.
  Whenever PasClaw emits a function_call output item with a non-empty
  signature, remember it. When an incoming function_call input item lacks
  one but echoes a call_id we recognise, restore it before the request
  goes back to the provider.

  Bounded to PROVIDER_SIGNATURE_CACHE_MAX entries (default 1024) -- a
  long-lived /v1/responses session has maybe dozens of tool calls; 1024
  covers ~50 active conversations comfortably. Eviction is FIFO via
  TStringList ordering; we delete the oldest when capacity hits.
  Per-process, in-memory only -- restart drops the cache (consistent
  with the rest of /v1/responses, which has no durable session). }
const
  PROVIDER_SIGNATURE_CACHE_MAX = 1024;

var
  GProviderSignatureCacheLock: TCriticalSection;
  GProviderSignatureCache:     TStringList;

procedure RememberProviderSignature(const CallId, Signature: string);
var
  Idx: Integer;
begin
  if (CallId = '') or (Signature = '') then Exit;
  GProviderSignatureCacheLock.Enter;
  try
    { Codex P1 on PR #194: when the call_id is already present we
      MUST overwrite, not skip. Gemini synthesises ids like
      `gemini_call_<name>_<index>` when the original assistant
      turn didn't carry one (PasClaw.Providers.Gemini), so two
      conversations that both call the same tool first end up
      with identical call_ids. Early-exiting would keep the
      FIRST conversation's signature forever and serve it back
      to the SECOND conversation -- the next turn there replays
      a stale thought_signature and Gemini rejects it.

      Delete-then-Add (vs. updating in place via Values[]) is
      deliberate: it ALSO refreshes the FIFO eviction position,
      so a tool call that just got reused isn't the next to be
      evicted when the cap is reached. }
    Idx := GProviderSignatureCache.IndexOfName(CallId);
    if Idx >= 0 then GProviderSignatureCache.Delete(Idx);
    if GProviderSignatureCache.Count >= PROVIDER_SIGNATURE_CACHE_MAX then
      GProviderSignatureCache.Delete(0);    { FIFO eviction }
    GProviderSignatureCache.Add(CallId + '=' + Signature);
  finally
    GProviderSignatureCacheLock.Leave;
  end;
end;

function LookupProviderSignature(const CallId: string): string;
var
  Idx: Integer;
begin
  Result := '';
  if CallId = '' then Exit;
  GProviderSignatureCacheLock.Enter;
  try
    Idx := GProviderSignatureCache.IndexOfName(CallId);
    if Idx >= 0 then
      Result := GProviderSignatureCache.ValueFromIndex[Idx];
  finally
    GProviderSignatureCacheLock.Leave;
  end;
end;

function FunctionCallItemJSON(const ItemId, CallId, Name, ArgsJSON, Status,
                              Signature: string): string;
{ One ResponseOutputItem of type function_call, serialized to a JSON
  string so the SSE event helpers can paste it verbatim into their
  payloads. The Responses API schema uses two ids:

    id      - opaque item id, "fc_<random>". Identifies the item
              within the response.
    call_id - "call_<random>". The handle the client uses to match
              its function_call_output back to this call on the
              next turn.

  Many implementations use the same value for both; we use distinct
  prefixes so logs can tell them apart. status is "completed" once
  the arguments are fully serialized.

  The arguments field is a *string* (raw JSON), not a JSON object.
  That matches OpenAI's schema and means a model that emits args
  with escaped quotes round-trips correctly.

  Signature: provider-specific opaque blob the gateway must echo
  back on the next turn (Gemini 3+'s thoughtSignature). Emitted as a
  custom "provider_signature" extension; the OpenAI Responses spec
  permits unknown fields, and PasClaw's own Codex client knows to
  echo this back on the function_call_output input item. Empty
  string -> field omitted so stock /v1/responses traffic stays clean.
  Codex P1 on PR #154. }
var
  Obj: TJsonObject;
begin
  Obj := TJsonObject.Create;
  try
    Obj.PutStr('id',        ItemId);
    Obj.PutStr('type',      'function_call');
    Obj.PutStr('status',    Status);
    Obj.PutStr('call_id',   CallId);
    Obj.PutStr('name',      Name);
    Obj.PutStr('arguments', ArgsJSON);
    if Signature <> '' then
    begin
      Obj.PutStr('provider_signature', Signature);
      { Belt-and-suspenders: stock OpenAI-Responses clients (Codex
        CLI, etc.) JSON-validate input items and drop unknown
        fields, so the signature gets lost by the next turn and
        Gemini 3 rejects with "missing thought_signature".
        Cache (call_id -> signature) here so the input-parser path
        can restore it from server memory even when the client
        didn't echo it back. }
      RememberProviderSignature(CallId, Signature);
    end;
    Result := Obj.ToJSON;
  finally
    Obj.Free;
  end;
end;

function ResolveResponsesToolChoice(Req: TJsonObject): string;
var
  ToolKind: string;
  TCObj, FnObj: TJsonObject;
begin
  Result := '';
  if (Req = nil) or not Req.Has('tool_choice') then Exit;
  { Keyword string form: "auto" / "none" / "required". GetStr returns ''
    when tool_choice is an object, so this falls through to the object
    parse below for the force-a-function shapes. }
  ToolKind := LowerCase(Trim(Req.GetStr('tool_choice', '')));
  if (ToolKind = 'auto') or (ToolKind = 'none') or (ToolKind = 'required') then
    Exit(ToolKind);
  TCObj := Req.ChildObject('tool_choice');
  if TCObj = nil then Exit;
  try
    { Responses API: flat top-level name. Then fall back to the
      Chat-Completions nested function.name. }
    Result := Trim(TCObj.GetStr('name', ''));
    if Result = '' then
    begin
      FnObj := TCObj.ChildObject('function');
      if FnObj <> nil then
      try
        Result := Trim(FnObj.GetStr('name', ''));
      finally
        FnObj.Free;
      end;
    end;
  finally
    TCObj.Free;
  end;
end;

function BuildResponsesObject(const Id, Model, Status, Content: string;
                               const ToolCalls: array of TToolCall;
                               const ToolsRawJSON: string;
                               Usage: TUsageInfo): TJsonObject;
{ OpenAI Responses-compatible response object.

  Required Pydantic fields (parallel_tool_calls, tool_choice, tools,
  output) are emitted with safe defaults; missing any of them makes
  openai-python raise ValidationError on the parser, manifesting as
  a "client chokes on the response" symptom (PR #61).

  ToolCalls (Phase 2 -- PR #63) appends function_call items to
  output[] for each model tool call. Each item carries an opaque
  fc_<...> id, the model's call_id (used by the client to match its
  function_call_output on the next turn), the tool name, and the
  arguments as a *string* (raw JSON, not a parsed object -- that
  matches the Responses schema and lets escaped quotes round-trip).

  ToolsRawJSON, when non-empty, is the JSON-array string the caller
  parsed out of request.tools and we echo back in the `tools` field
  so the SDK validator sees the tools the model used. Empty string
  falls back to "[]". }
var
  OutputArr, ContentArr, AnnotationsArr: TJsonArray;
  ToolsArr: TJsonArray;
  MsgObj, TextObj, UsageObj, TextCfgObj, FormatObj: TJsonObject;
  i: Integer;
  ItemId, CallId: string;
begin
  Result := TJsonObject.Create;
  Result.PutStr('id',         Id);
  Result.PutStr('object',     'response');
  Result.PutInt('created_at', DateTimeToUnix(Now, False));
  Result.PutStr('model',      Model);
  Result.PutStr('status',     Status);

  { Required by openai-python SDK Pydantic validation. }
  Result.PutBool('parallel_tool_calls', False);
  Result.PutStr ('tool_choice',         'auto');
  if ToolsRawJSON <> '' then
    Result.PutRaw('tools', ToolsRawJSON)
  else
  begin
    ToolsArr := TJsonArray.Create;
    Result.PutArray('tools', ToolsArr);
  end;

  { Optional but emitted as explicit null/empty so older or future
    stricter SDK versions don't trip on absent keys. }
  Result.PutRaw('error',              'null');
  Result.PutRaw('incomplete_details', 'null');
  Result.PutRaw('instructions',       'null');
  Result.PutRaw('metadata',           'null');
  Result.PutRaw('temperature',        'null');
  Result.PutRaw('top_p',              'null');
  Result.PutRaw('max_output_tokens',  'null');
  Result.PutRaw('previous_response_id','null');
  Result.PutRaw('reasoning',          'null');
  Result.PutRaw('service_tier',       'null');
  Result.PutRaw('truncation',         'null');
  Result.PutRaw('user',               'null');

  TextCfgObj := TJsonObject.Create;
  FormatObj  := TJsonObject.Create;
  FormatObj.PutStr('type', 'text');
  TextCfgObj.PutObject('format', FormatObj);
  Result.PutObject('text', TextCfgObj);

  OutputArr := TJsonArray.Create;
  if Content <> '' then
  begin
    MsgObj := TJsonObject.Create;
    MsgObj.PutStr('id',     'msg_' + Copy(Id, 6, MaxInt));
    MsgObj.PutStr('type',   'message');
    MsgObj.PutStr('status', Status);
    MsgObj.PutStr('role',   'assistant');

    TextObj := TJsonObject.Create;
    TextObj.PutStr('type', 'output_text');
    TextObj.PutStr('text', Content);
    AnnotationsArr := TJsonArray.Create;
    TextObj.PutArray('annotations', AnnotationsArr);

    ContentArr := TJsonArray.Create;
    ContentArr.AddObject(TextObj);
    MsgObj.PutArray('content', ContentArr);
    OutputArr.AddObject(MsgObj);
  end;
  for i := 0 to High(ToolCalls) do
  begin
    if ToolCalls[i].Func.Name = '' then Continue;
    ItemId := 'fc_' + Copy(Id, 6, MaxInt) + '_' + IntToStr(i);
    if Trim(ToolCalls[i].Id) <> '' then
      CallId := ToolCalls[i].Id
    else
      CallId := 'call_' + Copy(Id, 6, MaxInt) + '_' + IntToStr(i);
    OutputArr.AddRaw(FunctionCallItemJSON(ItemId, CallId,
                                           ToolCalls[i].Func.Name,
                                           ToolCalls[i].Func.Arguments,
                                           'completed',
                                           ToolCalls[i].ProviderSignature));
  end;
  Result.PutArray('output', OutputArr);

  UsageObj := TJsonObject.Create;
  UsageObj.PutInt('input_tokens',  Usage.InputTokens);
  UsageObj.PutInt('output_tokens', Usage.OutputTokens);
  UsageObj.PutInt('total_tokens',  Usage.InputTokens + Usage.OutputTokens);
  Result.PutObject('usage', UsageObj);
end;

function EmitResponsesEvent(Streamer: TSSEStreamer;
                            const EventType, Payload: string): Boolean;
{ Writes one Responses-API SSE event to the wire:

    event: <event_type>\n
    data: <json>\n
    \n

  Returns False if the streamer's underlying connection is already
  closed -- callers can short-circuit further emission when the
  client disconnected mid-stream. }
var
  Frame: string;
begin
  Result := False;
  if (Streamer = nil) or Streamer.Closed then Exit;
  Frame := 'event: ' + EventType + #10 +
           'data: '  + Payload    + #10 + #10;
  Streamer.WriteRaw(Frame);
  Result := True;
end;

{ Module-level Responses streaming event helpers. All take a Seq
  parameter (per openai-python validators, sequence_number is
  required on every event and must increase monotonically); the
  Output_index parameter on item-scoped events tracks which item
  the event belongs to. Text events also carry an empty logprobs:
  []. Both EmitResponsesStream (whole-text-as-one-delta) and
  StreamResponsesViaProvider (true partial streaming via
  ChatStream) build their events from the same helpers. }

function ResCreatedEvt(Seq: Integer; const ResponseJSON: string): string;
begin
  Result := Format(
    '{"type":"response.created","sequence_number":%d,"response":%s}',
    [Seq, ResponseJSON]);
end;

function ResInProgressEvt(Seq: Integer; const ResponseJSON: string): string;
begin
  Result := Format(
    '{"type":"response.in_progress","sequence_number":%d,"response":%s}',
    [Seq, ResponseJSON]);
end;

function ResCompletedEvt(Seq: Integer; const ResponseJSON: string): string;
begin
  Result := Format(
    '{"type":"response.completed","sequence_number":%d,"response":%s}',
    [Seq, ResponseJSON]);
end;

function ResFailedEvt(Seq: Integer; const ResponseJSON: string): string;
{ Terminal SSE event for the failure path. Streaming clients (the
  OpenAI Python SDK, Codex CLI) treat response.completed as success
  even if the response object's status is "failed", so they need a
  distinct event to surface provider exceptions raised after the
  headers were already sent. }
begin
  Result := Format(
    '{"type":"response.failed","sequence_number":%d,"response":%s}',
    [Seq, ResponseJSON]);
end;

function ResItemAddedEvt(Seq, OutputIdx: Integer;
                         const ItemInProgressJSON: string): string;
begin
  Result := Format(
    '{"type":"response.output_item.added","sequence_number":%d,' +
    '"output_index":%d,"item":%s}',
    [Seq, OutputIdx, ItemInProgressJSON]);
end;

function ResContentPartAddedEvt(Seq, OutputIdx: Integer;
                                const ItemId, PartJSON_: string): string;
begin
  Result := Format(
    '{"type":"response.content_part.added","sequence_number":%d,' +
    '"item_id":%s,"output_index":%d,"content_index":0,"part":%s}',
    [Seq, '"' + JsonEscape(ItemId) + '"', OutputIdx, PartJSON_]);
end;

function ResTextDeltaEvt(Seq, OutputIdx: Integer;
                         const ItemId, Delta: string): string;
begin
  Result := Format(
    '{"type":"response.output_text.delta","sequence_number":%d,' +
    '"item_id":%s,"output_index":%d,"content_index":0,' +
    '"delta":%s,"logprobs":[]}',
    [Seq,
     '"' + JsonEscape(ItemId) + '"',
     OutputIdx,
     '"' + JsonEscape(Delta) + '"']);
end;

function ResTextDoneEvt(Seq, OutputIdx: Integer;
                        const ItemId, Text: string): string;
begin
  Result := Format(
    '{"type":"response.output_text.done","sequence_number":%d,' +
    '"item_id":%s,"output_index":%d,"content_index":0,' +
    '"text":%s,"logprobs":[]}',
    [Seq,
     '"' + JsonEscape(ItemId) + '"',
     OutputIdx,
     '"' + JsonEscape(Text) + '"']);
end;

function ResContentPartDoneEvt(Seq, OutputIdx: Integer;
                                const ItemId, PartJSON_: string): string;
begin
  Result := Format(
    '{"type":"response.content_part.done","sequence_number":%d,' +
    '"item_id":%s,"output_index":%d,"content_index":0,"part":%s}',
    [Seq, '"' + JsonEscape(ItemId) + '"', OutputIdx, PartJSON_]);
end;

function ResItemDoneEvt(Seq, OutputIdx: Integer;
                        const ItemFinalJSON: string): string;
begin
  Result := Format(
    '{"type":"response.output_item.done","sequence_number":%d,' +
    '"output_index":%d,"item":%s}',
    [Seq, OutputIdx, ItemFinalJSON]);
end;

function ResFunctionCallArgsDeltaEvt(Seq, OutputIdx: Integer;
                                      const ItemId, Delta: string): string;
begin
  Result := Format(
    '{"type":"response.function_call_arguments.delta",' +
    '"sequence_number":%d,"item_id":%s,"output_index":%d,"delta":%s}',
    [Seq,
     '"' + JsonEscape(ItemId) + '"',
     OutputIdx,
     '"' + JsonEscape(Delta) + '"']);
end;

function ResFunctionCallArgsDoneEvt(Seq, OutputIdx: Integer;
                                     const ItemId, ArgsStr: string): string;
begin
  Result := Format(
    '{"type":"response.function_call_arguments.done",' +
    '"sequence_number":%d,"item_id":%s,"output_index":%d,"arguments":%s}',
    [Seq,
     '"' + JsonEscape(ItemId) + '"',
     OutputIdx,
     '"' + JsonEscape(ArgsStr) + '"']);
end;

procedure EmitResponsesStream(AContext: TIdContext;
                              AResp: TIdHTTPResponseInfo;
                              var AResponseStarted: Boolean;
                              const RespId, Model, Content: string;
                              const ToolCalls: array of TToolCall;
                              const ToolsRawJSON: string;
                              Usage: TUsageInfo;
                              DebugIO: Boolean);
(* Streaming for /v1/responses. Emits the Responses-API SSE event
   sequence so streaming clients (Codex CLI, openai-python streaming
   call, etc.) receive a parseable event stream.

   Event order (omitting text events when Content is empty, and
   adding one function_call sub-sequence per tool call):

     response.created                            { in_progress, empty output }
     response.in_progress
     [ message sub-sequence -- only if Content <> '' ]
       response.output_item.added                { message item }
       response.content_part.added               { output_text part }
       response.output_text.delta                { full text, one delta }
       response.output_text.done
       response.content_part.done
       response.output_item.done                 { message item completed }
     [ for each tool call -- Phase 2 tool passthrough ]
       response.output_item.added                { function_call item, args="" }
       response.function_call_arguments.delta    { full args, one delta }
       response.function_call_arguments.done
       response.output_item.done                 { function_call item completed }
     response.completed                          { full output, usage }

   output_index increases per item; message (when present) is 0
   and function_calls follow. Each function_call gets a unique
   fc_<...> item id; call_id is the model's TToolCall.Id which
   the client uses to match its function_call_output back on the
   next turn.

   Single-delta caveat from Phase A still applies: text and args
   come out as one chunk each because the tool loop / single-shot
   provider call here is synchronous. Real partial streaming will
   land in a follow-up that hooks the provider's OnChunk
   callback. *)
var
  Streamer: TSSEStreamer;
  CreatedObj, CompletedObj, ItemObj, PartObj, MsgItemObj: TJsonObject;
  CreatedJSON, CompletedJSON: string;
  ItemJSON, EmptyItemJSON, PartJSON, EmptyPartJSON: string;
  MsgItemId: string;
  EmptyUsage: TUsageInfo;
  ContentArr: TJsonArray;
  Seq, MsgOutputIdx, NextOutputIdx, TcIdx: Integer;
  FcItemId, FcCallId, FcArgs, FcEmptyJSON, FcCompletedJSON: string;
  NoToolCalls: array of TToolCall;

  { Every Responses streaming event the openai-python validators
    accept carries a monotonically-increasing `sequence_number`.
    Text events additionally require empty `logprobs: []` when no
    logprob data is available. Omitting either makes the SDK raise
    ValidationError on the first event that lands. Helpers take
    Seq as the first arg so the caller bumps a single local
    counter on every emit. }

begin
  MsgItemId := 'msg_' + Copy(RespId, 6, MaxInt);

  EmptyUsage.InputTokens  := 0;
  EmptyUsage.OutputTokens := 0;

  { Streaming-friendly response.created carries the in_progress
    shape with empty output / empty tool_calls / zero usage. The
    completed object below carries the real output array and the
    request's echoed tools. }
  SetLength(NoToolCalls, 0);
  CreatedObj := BuildResponsesObject(RespId, Model, 'in_progress', '',
                                      NoToolCalls, ToolsRawJSON, EmptyUsage);
  try
    CreatedJSON := CreatedObj.ToJSON;
  finally
    CreatedObj.Free;
  end;

  { Message-item shapes for the (optional) message sub-sequence.
    Empty vs. completed differ only by content array contents and
    status. ContentPart events use the same item_id. }
  MsgItemObj := TJsonObject.Create;
  MsgItemObj.PutStr('id',     MsgItemId);
  MsgItemObj.PutStr('type',   'message');
  MsgItemObj.PutStr('status', 'in_progress');
  MsgItemObj.PutStr('role',   'assistant');
  ContentArr := TJsonArray.Create;
  MsgItemObj.PutArray('content', ContentArr);
  try
    EmptyItemJSON := MsgItemObj.ToJSON;
  finally
    MsgItemObj.Free;
  end;

  PartObj := TJsonObject.Create;
  PartObj.PutStr('type', 'output_text');
  PartObj.PutStr('text', '');
  ContentArr := TJsonArray.Create;
  PartObj.PutArray('annotations', ContentArr);
  try
    EmptyPartJSON := PartObj.ToJSON;
  finally
    PartObj.Free;
  end;

  PartObj := TJsonObject.Create;
  PartObj.PutStr('type', 'output_text');
  PartObj.PutStr('text', Content);
  ContentArr := TJsonArray.Create;
  PartObj.PutArray('annotations', ContentArr);
  try
    PartJSON := PartObj.ToJSON;
  finally
    PartObj.Free;
  end;

  ItemObj := TJsonObject.Create;
  ItemObj.PutStr('id',     MsgItemId);
  ItemObj.PutStr('type',   'message');
  ItemObj.PutStr('status', 'completed');
  ItemObj.PutStr('role',   'assistant');
  ContentArr := TJsonArray.Create;
  ContentArr.AddRaw(PartJSON);
  ItemObj.PutArray('content', ContentArr);
  try
    ItemJSON := ItemObj.ToJSON;
  finally
    ItemObj.Free;
  end;

  CompletedObj := BuildResponsesObject(RespId, Model, 'completed', Content,
                                        ToolCalls, ToolsRawJSON, Usage);
  try
    CompletedJSON := CompletedObj.ToJSON;
  finally
    CompletedObj.Free;
  end;

  { Headers: same shape as the chat-completions SSE setup. }
  (* Same RFC-7230-compliant raw header emit as HandleChatCompletions
     -- AResp.WriteHeader emits Content-Length: 0 alongside chunked
     transfer encoding, which strict L7 proxies reject. *)
  if not EmitSSEResponseHeaders(AContext, AResp) then Exit;
  AResponseStarted := True;

  Streamer := TSSEStreamer.Create(AContext, RespId, Model, DebugIO);
  try
    if DebugIO then LogDebug('responses sse: %d bytes content, %d tool call(s), item_id=%s',
                              [Length(Content), Length(ToolCalls), MsgItemId]);
    Seq := 0;
    NextOutputIdx := 0;

    EmitResponsesEvent(Streamer, 'response.created',
      ResCreatedEvt(Seq, CreatedJSON)); Inc(Seq);
    EmitResponsesEvent(Streamer, 'response.in_progress',
      ResInProgressEvt(Seq, CreatedJSON)); Inc(Seq);

    if Content <> '' then
    begin
      MsgOutputIdx := NextOutputIdx; Inc(NextOutputIdx);
      EmitResponsesEvent(Streamer, 'response.output_item.added',
        ResItemAddedEvt(Seq, MsgOutputIdx, EmptyItemJSON)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.content_part.added',
        ResContentPartAddedEvt(Seq, MsgOutputIdx, MsgItemId, EmptyPartJSON)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.output_text.delta',
        ResTextDeltaEvt(Seq, MsgOutputIdx, MsgItemId, Content)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.output_text.done',
        ResTextDoneEvt(Seq, MsgOutputIdx, MsgItemId, Content)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.content_part.done',
        ResContentPartDoneEvt(Seq, MsgOutputIdx, MsgItemId, PartJSON)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.output_item.done',
        ResItemDoneEvt(Seq, MsgOutputIdx, ItemJSON)); Inc(Seq);
    end;

    for TcIdx := 0 to High(ToolCalls) do
    begin
      if ToolCalls[TcIdx].Func.Name = '' then Continue;
      FcItemId := 'fc_' + Copy(RespId, 6, MaxInt) + '_' + IntToStr(TcIdx);
      if Trim(ToolCalls[TcIdx].Id) <> '' then
        FcCallId := ToolCalls[TcIdx].Id
      else
        FcCallId := 'call_' + Copy(RespId, 6, MaxInt) + '_' + IntToStr(TcIdx);
      FcArgs := ToolCalls[TcIdx].Func.Arguments;
      if FcArgs = '' then FcArgs := '{}';

      FcEmptyJSON     := FunctionCallItemJSON(FcItemId, FcCallId,
                                              ToolCalls[TcIdx].Func.Name,
                                              '', 'in_progress',
                                              ToolCalls[TcIdx].ProviderSignature);
      FcCompletedJSON := FunctionCallItemJSON(FcItemId, FcCallId,
                                              ToolCalls[TcIdx].Func.Name,
                                              FcArgs, 'completed',
                                              ToolCalls[TcIdx].ProviderSignature);

      EmitResponsesEvent(Streamer, 'response.output_item.added',
        ResItemAddedEvt(Seq, NextOutputIdx, FcEmptyJSON)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.function_call_arguments.delta',
        ResFunctionCallArgsDeltaEvt(Seq, NextOutputIdx, FcItemId, FcArgs)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.function_call_arguments.done',
        ResFunctionCallArgsDoneEvt(Seq, NextOutputIdx, FcItemId, FcArgs)); Inc(Seq);
      EmitResponsesEvent(Streamer, 'response.output_item.done',
        ResItemDoneEvt(Seq, NextOutputIdx, FcCompletedJSON)); Inc(Seq);
      Inc(NextOutputIdx);
    end;

    EmitResponsesEvent(Streamer, 'response.completed',
      ResCompletedEvt(Seq, CompletedJSON));
    Streamer.CloseStream;
  finally
    Streamer.Free;
  end;
end;

type
  { State carried between the streaming-loop body and the OnChunk
    callback that the provider invokes on every text fragment. The
    provider's TStreamCallback is `procedure(...) of object`, so we
    need a class to bind the state. One instance per request. }
  TResponsesStreamState = class
  public
    Streamer:        TSSEStreamer;
    MsgItemId:       string;
    Seq:             Integer;
    MsgOutputIdx:    Integer;
    NextOutputIdx:   Integer;
    TextStarted:     Boolean;
    TextAccumulated: string;
    EmptyItemJSON:   string;
    EmptyPartJSON:   string;
    DebugIO:         Boolean;
    procedure OnChunk(const C: TStreamChunk);
  end;

procedure TResponsesStreamState.OnChunk(const C: TStreamChunk);
{ Provider-side OnChunk. Each 'text' chunk is one or more characters
  the model just produced; emit a response.output_text.delta for it.
  The first text chunk also has to open the message sub-sequence
  (output_item.added + content_part.added) because we don't know
  in advance whether the response will have any text at all -- some
  function-call-only turns produce zero text. Tool-call deltas
  are not emitted here; the provider returns the final TToolCall
  list in its TLLMResponse and the calling function handles those
  in the function_call sub-sequence after ChatStream returns. }
var
  Frame: string;
begin
  if (Streamer = nil) or Streamer.Closed then Exit;
  if C.Kind <> 'text' then Exit;
  if C.Text = '' then Exit;

  if not TextStarted then
  begin
    TextStarted := True;
    MsgOutputIdx := NextOutputIdx;
    Inc(NextOutputIdx);

    Frame := ResItemAddedEvt(Seq, MsgOutputIdx, EmptyItemJSON);
    EmitResponsesEvent(Streamer, 'response.output_item.added', Frame);
    Inc(Seq);

    Frame := ResContentPartAddedEvt(Seq, MsgOutputIdx, MsgItemId, EmptyPartJSON);
    EmitResponsesEvent(Streamer, 'response.content_part.added', Frame);
    Inc(Seq);
  end;

  TextAccumulated := TextAccumulated + C.Text;
  Frame := ResTextDeltaEvt(Seq, MsgOutputIdx, MsgItemId, C.Text);
  EmitResponsesEvent(Streamer, 'response.output_text.delta', Frame);
  Inc(Seq);
end;

procedure StreamResponsesViaProvider(AContext: TIdContext;
                                      AResp: TIdHTTPResponseInfo;
                                      var AResponseStarted: Boolean;
                                      Provider: ILLMProvider;
                                      const RespId, Model: string;
                                      const Msgs: array of TMessage;
                                      const ToolDefs: array of TToolDefinition;
                                      const Opts: TChatOptions;
                                      const ToolsRawJSON: string;
                                      DebugIO: Boolean;
                                      const Reliability: TStreamReliabilityConfig;
                                      out OutUsage: TUsageInfo;
                                      out OutToolCallCount: Integer);
(* Real partial-streaming variant of EmitResponsesStream for the
   passthrough path. Calls Provider.ChatStream so text deltas reach
   the client as the model produces them, then emits the
   function_call sub-sequence for any tool calls the response
   carried.

   The non-passthrough (RunToolLoop) path stays on the
   single-delta EmitResponsesStream -- RunToolLoop is synchronous
   so its text is only available as a whole at the end, and there
   is no incremental data to forward.

   OutUsage / OutToolCallCount surface the totals back to the
   caller so it can hand them to AccumulateGatewayStatsRaw for the
   /v1/stats bucket -- Codex P2 on PR #204. Both are initialised
   to zero up front, so callers always get safe defaults even on
   the ChatStream error path. *)
var
  CreatedObj, CompletedObj, MsgItemObj, PartObj, FinalItemObj,
  ErrObj: TJsonObject;
  ContentArr: TJsonArray;
  State: TResponsesStreamState;
  CreatedJSON, CompletedJSON, FinalPartJSON, FinalItemJSON,
  StreamErr: string;
  EmptyUsage: TUsageInfo;
  NoToolCalls: array of TToolCall;
  Resp: TLLMResponse;
  i: Integer;
  FcItemId, FcCallId, FcArgs, FcEmptyJSON, FcCompletedJSON: string;
  FakeChunk: TStreamChunk;
  Failed: Boolean;
begin
  EmptyUsage.InputTokens  := 0;
  EmptyUsage.OutputTokens := 0;
  SetLength(NoToolCalls, 0);

  CreatedObj := BuildResponsesObject(RespId, Model, 'in_progress', '',
                                      NoToolCalls, ToolsRawJSON, EmptyUsage);
  try
    CreatedJSON := CreatedObj.ToJSON;
  finally
    CreatedObj.Free;
  end;

  { Initialise the out-params to safe zero defaults so callers can
    always rely on them, even on the ChatStream-raised error path
    where Resp.Usage may be left unset before the catch handler
    runs. AccumulateGatewayStatsRaw against zero is a no-op other
    than bumping Turns, which is acceptable for a failed call. }
  OutUsage         := Default(TUsageInfo);
  OutToolCallCount := 0;

  { Item / part JSON for the lazy message-sub-sequence open. The
    OnChunk callback uses these when the first text chunk arrives. }
  State := TResponsesStreamState.Create;
  try
    State.MsgItemId       := 'msg_' + Copy(RespId, 6, MaxInt);
    State.DebugIO         := DebugIO;
    State.TextStarted     := False;
    State.TextAccumulated := '';
    State.Seq             := 0;
    State.NextOutputIdx   := 0;

    MsgItemObj := TJsonObject.Create;
    MsgItemObj.PutStr('id',     State.MsgItemId);
    MsgItemObj.PutStr('type',   'message');
    MsgItemObj.PutStr('status', 'in_progress');
    MsgItemObj.PutStr('role',   'assistant');
    ContentArr := TJsonArray.Create;
    MsgItemObj.PutArray('content', ContentArr);
    try
      State.EmptyItemJSON := MsgItemObj.ToJSON;
    finally
      MsgItemObj.Free;
    end;

    PartObj := TJsonObject.Create;
    PartObj.PutStr('type', 'output_text');
    PartObj.PutStr('text', '');
    ContentArr := TJsonArray.Create;
    PartObj.PutArray('annotations', ContentArr);
    try
      State.EmptyPartJSON := PartObj.ToJSON;
    finally
      PartObj.Free;
    end;

    (* Same RFC-7230-compliant raw header emit as HandleChatCompletions
       -- AResp.WriteHeader emits Content-Length: 0 alongside chunked
       transfer encoding, which strict L7 proxies reject. *)
    if not EmitSSEResponseHeaders(AContext, AResp) then Exit;
    AResponseStarted := True;

    State.Streamer := TSSEStreamer.Create(AContext, RespId, Model, DebugIO);
    try
      EmitResponsesEvent(State.Streamer, 'response.created',
        ResCreatedEvt(State.Seq, CreatedJSON)); Inc(State.Seq);
      EmitResponsesEvent(State.Streamer, 'response.in_progress',
        ResInProgressEvt(State.Seq, CreatedJSON)); Inc(State.Seq);

      StreamErr := '';
      Failed    := False;
      try
        { ChatStreamWithReliability wraps Provider.ChatStream with an
          idle-timeout watcher (returns synthetic empty response with
          FinishReason='timeout' if no chunks arrive within the
          configured window) and empty-turn retry (only when the
          stream emitted zero chunks AND landed on the empty shape).
          With both knobs zero the wrapper degrades to a direct
          Provider.ChatStream call. }
        Resp := ChatStreamWithReliability(Provider, Msgs, ToolDefs,
                                           Model, Opts, State.OnChunk,
                                           Reliability);
      except
        on E: Exception do
        begin
          LogWarn('responses: ChatStream raised: %s', [E.Message]);
          Resp.Content      := '';
          SetLength(Resp.ToolCalls, 0);
          Resp.FinishReason := 'error';
          Resp.Usage.InputTokens  := 0;
          Resp.Usage.OutputTokens := 0;
          StreamErr := 'provider ChatStream raised: ' + E.Message;
          Failed    := True;
        end;
      end;
      if (not Failed) and (Resp.FinishReason = 'error') then
      begin
        Failed := True;
        if StreamErr = '' then
        begin
          if Resp.Content <> '' then
            StreamErr := Resp.Content
          else
            StreamErr := 'provider returned finish_reason=error';
        end;
      end;
      { Idle-timeout from the reliability wrapper surfaces as
        FinishReason='timeout'. Map to the response.failed code
        path so the client gets a clean 502-style error instead of
        a half-streamed response that silently never finishes. }
      if (not Failed) and (Resp.FinishReason = 'timeout') then
      begin
        Failed := True;
        if StreamErr = '' then
          StreamErr := 'upstream stream idle-timeout';
      end;

      { Surface the totals to the caller's out-params. Whether the
        call succeeded or failed, the catch-handler above leaves
        Resp populated with sensible zeros, so an error-path
        accumulate is a near-no-op (just bumps Turns). Done here
        rather than only on the success path so the bucket sees
        the existence of the call even if it failed. }
      OutUsage         := Resp.Usage;
      OutToolCallCount := Length(Resp.ToolCalls);

      { Providers that don't actually stream (e.g., the
        OpenAI-compat ChatStream that just delegates to Chat) will
        return the full text via Resp.Content with no OnChunk
        invocations. Feed it through OnChunk so the event sequence
        is the same shape regardless of provider streaming
        support. Skip on the failure path -- Resp.Content carries the
        provider error string, not a real assistant turn, so it
        belongs in the response.failed error.message instead of being
        streamed back as fake text deltas. }
      if (not Failed) and (not State.TextStarted) and (Resp.Content <> '') then
      begin
        FakeChunk.Kind := 'text';
        FakeChunk.Text := Resp.Content;
        State.OnChunk(FakeChunk);
      end;

      if State.TextStarted then
      begin
        FinalPartJSON :=
          Format('{"type":"output_text","text":%s,"annotations":[]}',
                 ['"' + JsonEscape(State.TextAccumulated) + '"']);
        EmitResponsesEvent(State.Streamer, 'response.output_text.done',
          ResTextDoneEvt(State.Seq, State.MsgOutputIdx, State.MsgItemId,
                          State.TextAccumulated)); Inc(State.Seq);
        EmitResponsesEvent(State.Streamer, 'response.content_part.done',
          ResContentPartDoneEvt(State.Seq, State.MsgOutputIdx, State.MsgItemId,
                                 FinalPartJSON)); Inc(State.Seq);

        FinalItemObj := TJsonObject.Create;
        FinalItemObj.PutStr('id',     State.MsgItemId);
        FinalItemObj.PutStr('type',   'message');
        FinalItemObj.PutStr('status', 'completed');
        FinalItemObj.PutStr('role',   'assistant');
        ContentArr := TJsonArray.Create;
        ContentArr.AddRaw(FinalPartJSON);
        FinalItemObj.PutArray('content', ContentArr);
        try
          FinalItemJSON := FinalItemObj.ToJSON;
        finally
          FinalItemObj.Free;
        end;
        EmitResponsesEvent(State.Streamer, 'response.output_item.done',
          ResItemDoneEvt(State.Seq, State.MsgOutputIdx, FinalItemJSON)); Inc(State.Seq);
      end;

      for i := 0 to High(Resp.ToolCalls) do
      begin
        if Resp.ToolCalls[i].Func.Name = '' then Continue;
        FcItemId := 'fc_' + Copy(RespId, 6, MaxInt) + '_' + IntToStr(i);
        if Trim(Resp.ToolCalls[i].Id) <> '' then
          FcCallId := Resp.ToolCalls[i].Id
        else
          FcCallId := 'call_' + Copy(RespId, 6, MaxInt) + '_' + IntToStr(i);
        FcArgs := Resp.ToolCalls[i].Func.Arguments;
        if FcArgs = '' then FcArgs := '{}';

        FcEmptyJSON     := FunctionCallItemJSON(FcItemId, FcCallId,
                                                Resp.ToolCalls[i].Func.Name,
                                                '', 'in_progress',
                                                Resp.ToolCalls[i].ProviderSignature);
        FcCompletedJSON := FunctionCallItemJSON(FcItemId, FcCallId,
                                                Resp.ToolCalls[i].Func.Name,
                                                FcArgs, 'completed',
                                                Resp.ToolCalls[i].ProviderSignature);

        EmitResponsesEvent(State.Streamer, 'response.output_item.added',
          ResItemAddedEvt(State.Seq, State.NextOutputIdx, FcEmptyJSON)); Inc(State.Seq);
        EmitResponsesEvent(State.Streamer, 'response.function_call_arguments.delta',
          ResFunctionCallArgsDeltaEvt(State.Seq, State.NextOutputIdx, FcItemId, FcArgs)); Inc(State.Seq);
        EmitResponsesEvent(State.Streamer, 'response.function_call_arguments.done',
          ResFunctionCallArgsDoneEvt(State.Seq, State.NextOutputIdx, FcItemId, FcArgs)); Inc(State.Seq);
        EmitResponsesEvent(State.Streamer, 'response.output_item.done',
          ResItemDoneEvt(State.Seq, State.NextOutputIdx, FcCompletedJSON)); Inc(State.Seq);
        Inc(State.NextOutputIdx);
      end;

      if Failed then
      begin
        CompletedObj := BuildResponsesObject(RespId, Model, 'failed',
                                              State.TextAccumulated,
                                              Resp.ToolCalls, ToolsRawJSON,
                                              Resp.Usage);
        try
          ErrObj := TJsonObject.Create;
          ErrObj.PutStr('code',    'server_error');
          ErrObj.PutStr('message', StreamErr);
          CompletedObj.PutObject('error', ErrObj);
          CompletedJSON := CompletedObj.ToJSON;
        finally
          CompletedObj.Free;
        end;
        EmitResponsesEvent(State.Streamer, 'response.failed',
          ResFailedEvt(State.Seq, CompletedJSON));
      end
      else
      begin
        CompletedObj := BuildResponsesObject(RespId, Model, 'completed',
                                              State.TextAccumulated,
                                              Resp.ToolCalls, ToolsRawJSON,
                                              Resp.Usage);
        try
          CompletedJSON := CompletedObj.ToJSON;
        finally
          CompletedObj.Free;
        end;
        EmitResponsesEvent(State.Streamer, 'response.completed',
          ResCompletedEvt(State.Seq, CompletedJSON));
      end;
      State.Streamer.CloseStream;
    finally
      State.Streamer.Free;
    end;
  finally
    State.Free;
  end;
end;

procedure TGatewayServer.HandleResponses(AContext: TIdContext;
                                          ARequest: TIdHTTPRequestInfo;
                                          AResp: TIdHTTPResponseInfo;
                                          out AWasStreamingRequest: Boolean;
                                          out AResponseStarted: Boolean);
(* OpenAI Responses API compatibility. Accepts the request shape used by
   modern OpenAI clients and KAI: model, input (string or array of
   role/content messages), stream, temperature, and max_output_tokens. The
   request is translated into the same TMessageArray/TToolLoopConfig path as
   /v1/chat/completions. Responses streaming has a different event protocol,
   so this endpoint deliberately returns an OpenAI-shaped unsupported-streaming
   error instead of pretending chat-completion chunks are Responses events. *)
var
  Body, ReqModel, InputText, FinishReason, RespId, ItemType: string;
  Bytes: TBytes;
  Req, InputObj, ReplyObj, ErrObj, ToolObj: TJsonObject;
  InputArr, ToolsArrIn: TJsonArray;
  Msgs: TMessageArray;
  i, MsgCount, j: Integer;
  WantsStream, HasFunctionTools: Boolean;
  Loop: TToolLoopResult;
  LoopCfg: TToolLoopConfig;
  RawTemp: Double;
  ToolDefs: TToolDefinitionArray;
  ToolsRawJSON: string;
  PassthroughResp: TLLMResponse;
  PassthroughOpts: TChatOptions;
  OutContent: string;
  OutToolCalls: array of TToolCall;
  OutUsage: TUsageInfo;
  StreamToolCallCount: Integer;   { populated by StreamResponsesViaProvider
                                    out-param; we don't carry the streamed
                                    ToolCalls array out (deltas already
                                    shipped to client), just the count for
                                    the bucket-stats accumulation. }
  ParamsObj: TJsonObject;
  ParamsRaw, ToolKind, ToolDisplayName: string;
  EmptyToolCalls: array of TToolCall;
  FcCallIdVal, FcSignatureVal: string;
  Prim: ILLMProvider;   { live-provider snapshot for this request (hot-swap safe) }
  FB: TLLMProviderArray;
  SnapModel: string;

  procedure AppendMessage(Role: TMsgRole; const Content: string);
  begin
    if Trim(Content) = '' then Exit;
    SetLength(Msgs, MsgCount + 1);
    Msgs[MsgCount] := MakeMessage(Role, Content);
    Inc(MsgCount);
  end;

  procedure AppendAssistantToolCall(const CallId, Name, ArgumentsJSON,
                                    Signature: string);
  { Codex (and any Responses-API client doing multi-turn tool use)
    sends previous-turn function_call items as separate input items
    with no parent message. The Chat-Completions-style providers we
    use expect each assistant turn to carry an embedded tool_calls
    array. When the client emits parallel calls in one turn (multiple
    consecutive function_call items before any function_call_output),
    coalesce them into a single assistant message so the request
    body keeps the original turn boundaries: Anthropic in particular
    rejects request shapes where a tool_use block appears in a turn
    whose preceding turn already produced tool_use blocks without
    intervening tool_result blocks. Matching with the corresponding
    function_call_output is still by call_id regardless of grouping.

    Signature: the provider_signature extension we emit when shipping
    function_call items downstream. Codex (or any PasClaw-aware
    client) echoes it back on the input function_call item so this
    side can stuff it back onto the TToolCall -- required for Gemini
    3+ thoughtSignature round-trips through /v1/responses. Codex P1
    on PR #154. }
  var
    Tc: TToolCall;
    Last: Integer;
  begin
    Tc.Id   := CallId;
    Tc.Kind := 'function';
    Tc.Func.Name      := Name;
    Tc.Func.Arguments := ArgumentsJSON;
    Tc.ProviderSignature := Signature;

    if (MsgCount > 0)
       and (Msgs[MsgCount - 1].Role = mrAssistant)
       and (Msgs[MsgCount - 1].Content = '')
       and (Length(Msgs[MsgCount - 1].ToolCalls) > 0) then
    begin
      Last := Length(Msgs[MsgCount - 1].ToolCalls);
      SetLength(Msgs[MsgCount - 1].ToolCalls, Last + 1);
      Msgs[MsgCount - 1].ToolCalls[Last] := Tc;
      Exit;
    end;

    SetLength(Msgs, MsgCount + 1);
    Msgs[MsgCount].Role       := mrAssistant;
    Msgs[MsgCount].Content    := '';
    Msgs[MsgCount].Name       := '';
    Msgs[MsgCount].ToolCallId := '';
    SetLength(Msgs[MsgCount].ToolCalls, 1);
    Msgs[MsgCount].ToolCalls[0] := Tc;
    Inc(MsgCount);
  end;

  procedure AppendToolResult(const CallId, Output: string);
  { function_call_output input items become mrTool messages with
    ToolCallId matching the call_id. The Chat-Completions / Anthropic
    request builders both key tool_result blocks by this id. }
  begin
    SetLength(Msgs, MsgCount + 1);
    Msgs[MsgCount].Role       := mrTool;
    Msgs[MsgCount].Content    := Output;
    Msgs[MsgCount].Name       := '';
    Msgs[MsgCount].ToolCallId := CallId;
    SetLength(Msgs[MsgCount].ToolCalls, 0);
    Inc(MsgCount);
  end;

  function FlattenTextArray(Arr: TJsonArray): string;
  var
    PartObj: TJsonObject;
    NestedArr: TJsonArray;
    PartText, NestedText: string;
    j: Integer;
  begin
    Result := '';
    if Arr = nil then Exit;
    for j := 0 to Arr.Count - 1 do
    begin
      PartText := Arr.ItemStr(j, '');
      if PartText = '' then
      begin
        PartObj := Arr.ItemObject(j);
        if PartObj <> nil then
        try
          PartText := PartObj.GetStr('text', '');
          if PartText = '' then PartText := PartObj.GetStr('input_text', '');
          if PartText = '' then PartText := PartObj.GetStr('output_text', '');
          if PartText = '' then
          begin
            NestedArr := PartObj.ChildArray('content');
            if NestedArr <> nil then
            try
              NestedText := FlattenTextArray(NestedArr);
              PartText := NestedText;
            finally
              NestedArr.Free;
            end;
          end;
        finally
          PartObj.Free;
        end;
      end;
      if Trim(PartText) <> '' then
      begin
        if Result <> '' then Result := Result + sLineBreak;
        Result := Result + PartText;
      end;
    end;
  end;

  function ExtractMessageContent(Obj: TJsonObject): string;
  var
    ContentArr: TJsonArray;
  begin
    Result := '';
    if Obj = nil then Exit;
    ContentArr := Obj.ChildArray('content');
    if ContentArr <> nil then
    try
      Result := FlattenTextArray(ContentArr);
    finally
      ContentArr.Free;
    end
    else
    begin
      Result := Obj.GetStr('content', '');
      if Result = '' then Result := Obj.GetStr('text', '');
      if Result = '' then Result := Obj.GetStr('input_text', '');
    end;
  end;

begin
  AWasStreamingRequest := False;
  AResponseStarted := False;
  Body := '';
  SetLength(Msgs, 0);
  MsgCount := 0;

  if ARequest.PostStream <> nil then
  begin
    ARequest.PostStream.Position := 0;
    SetLength(Bytes, ARequest.PostStream.Size);
    if ARequest.PostStream.Size > 0 then
    begin
      ARequest.PostStream.ReadBuffer(Bytes[0], ARequest.PostStream.Size);
      Body := TEncoding.UTF8.GetString(Bytes);
    end;
  end;

  if FDebugIO then
    LogDebug('responses <- %d bytes from %s: %s',
             [Length(Bytes), ARequest.RemoteIP, Body]);

  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400,
      '{"error":{"message":"empty request body","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    Req := TJsonObject.Parse(Body);
  except
    on E: Exception do
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"invalid JSON","type":"invalid_request_error"}}');
      Exit;
    end;
  end;

  if Req = nil then
  begin
    WriteJSON(AResp, 400,
      '{"error":{"message":"invalid JSON object","type":"invalid_request_error"}}');
    Exit;
  end;

  try
    ReqModel    := Req.GetStr('model', FCfg.DefaultModel);
    WantsStream := Req.GetBool('stream', False);
    AWasStreamingRequest := WantsStream;

    { Streaming flag is honored further down. Header-write happens
      after RunToolLoop completes so a failed loop can still emit a
      proper 502 JSON response (no SSE headers committed yet). }

    InputArr := Req.ChildArray('input');
    if InputArr <> nil then
    try
      for i := 0 to InputArr.Count - 1 do
      begin
        InputObj := InputArr.ItemObject(i);
        if InputObj <> nil then
        try
          ItemType := LowerCase(Trim(InputObj.GetStr('type', 'message')));
          if (ItemType = '') or (ItemType = 'message') then
          begin
            InputText := ExtractMessageContent(InputObj);
            AppendMessage(MsgRoleFromString(InputObj.GetStr('role', 'user')), InputText);
          end
          else if ItemType = 'function_call' then
          begin
            { Previous-turn tool call coming back in the input stream.
              Synthesize an assistant message carrying the matching
              TToolCall -- see AppendAssistantToolCall comment.

              Signature resolution order:
                1. provider_signature field on the input item (the
                   PasClaw-aware client path -- Codex with the PR #154
                   extension echoed it back).
                2. Server-side cache by call_id (the stock-client path
                   -- Codex CLI etc. strip unknown fields, so we
                   restore from memory).
              Either path yields a non-empty signature when the original
              tool call carried one, so Gemini 3's "missing
              thought_signature" 400 stops triggering when an
              OpenAI-Responses client doesn't preserve our extension. }
            FcCallIdVal    := InputObj.GetStr('call_id', InputObj.GetStr('id', ''));
            FcSignatureVal := InputObj.GetStr('provider_signature', '');
            if FcSignatureVal = '' then
              FcSignatureVal := LookupProviderSignature(FcCallIdVal);
            AppendAssistantToolCall(
              FcCallIdVal,
              InputObj.GetStr('name',      ''),
              InputObj.GetStr('arguments', '{}'),
              FcSignatureVal);
          end
          else if ItemType = 'function_call_output' then
          begin
            { Tool result from the client. The model needs this to
              continue the multi-turn conversation. }
            AppendToolResult(
              InputObj.GetStr('call_id', ''),
              InputObj.GetStr('output',  ''));
          end
          else
          begin
            { Unknown item type (reasoning, image, computer_call, …)
              -- log at debug and skip. Phase 2 covers function_call /
              function_call_output; the rest are future scope. }
            LogDebug('responses: skipping unsupported input item type "%s"',
                     [ItemType]);
          end;
        finally
          InputObj.Free;
        end
        else
          AppendMessage(mrUser, InputArr.ItemStr(i, ''));
      end;
    finally
      InputArr.Free;
    end
    else
      AppendMessage(mrUser, Req.GetStr('input', ''));

    if MsgCount = 0 then
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"missing or empty input","type":"invalid_request_error","param":"input"}}');
      Exit;
    end;

    { Tools passthrough -- parse the request's tools[] array. Function-
      type entries become TToolDefinition for the provider. The
      verbatim array is captured in ToolsRawJSON so the response.tools
      field can echo it (the SDK uses that for validation /
      display). Custom-type tools (Codex's grammar-constrained
      apply_patch) are NOT forwarded to the provider -- Anthropic /
      OpenAI Chat-Completions don't natively support Lark-grammar
      output constraints -- but they still appear in ToolsRawJSON so
      the SDK doesn't trip on the echo. The model just won't
      attempt to call them; Codex's UX for grammar tools degrades
      to "model writes apply_patch text directly" in that case. }
    SetLength(ToolDefs, 0);
    ToolsRawJSON := '';
    HasFunctionTools := False;
    ToolsArrIn := Req.ChildArray('tools');
    if ToolsArrIn <> nil then
    try
      ToolsRawJSON := ToolsArrIn.ToJSON;
      for i := 0 to ToolsArrIn.Count - 1 do
      begin
        ToolObj := ToolsArrIn.ItemObject(i);
        if ToolObj = nil then Continue;
        try
          ToolKind := LowerCase(Trim(ToolObj.GetStr('type', 'function')));
          if ToolKind <> 'function' then
          begin
            { Name is optional on some Responses-API tool shapes -- OpenAI's
              built-in `web_search` / `web_search_preview` carry only a
              `type` field, so the previous '?' default looked like garbage
              in the debug log. Surface the type explicitly when the name's
              absent; that's the only useful identifier we have. }
            ToolDisplayName := ToolObj.GetStr('name', '');
            if ToolDisplayName = '' then
              LogDebug('responses: skipping non-function tool type=%s',
                       [ToolKind])
            else
              LogDebug('responses: skipping non-function tool "%s" type=%s',
                       [ToolDisplayName, ToolKind]);
            Continue;
          end;
          j := Length(ToolDefs);
          SetLength(ToolDefs, j + 1);
          ToolDefs[j].Name        := ToolObj.GetStr('name',        '');
          ToolDefs[j].Description := ToolObj.GetStr('description', '');
          { parameters field is a JSON Schema object. Round-trip it
            via the child accessor so the embedded shape stays
            intact and the provider's request builder pastes it in
            verbatim. Default to a permissive empty object. }
          ParamsObj := ToolObj.ChildObject('parameters');
          if ParamsObj <> nil then
          try
            ParamsRaw := ParamsObj.ToJSON;
          finally
            ParamsObj.Free;
          end
          else
            ParamsRaw := '{"type":"object"}';
          ToolDefs[j].Schema := ParamsRaw;
          { The schema is required even for "no arguments" tools;
            Anthropic in particular rejects tool defs that omit it. }
          if ToolDefs[j].Name <> '' then HasFunctionTools := True;
        finally
          ToolObj.Free;
        end;
      end;
    finally
      ToolsArrIn.Free;
    end;
    SnapshotRuntime(Prim, FB, SnapModel);
    if Prim = nil then
    begin
      WriteJSON(AResp, 503,
        '{"error":{"message":"no provider configured","type":"server_error"}}');
      Exit;
    end;

    RespId := GenResponseId;
    SetLength(EmptyToolCalls, 0);

    if HasFunctionTools then
    begin
      { Passthrough path. The client (Codex, openai-python tool use)
        defined its own tools and expects to execute them itself, so
        we DON'T run PasClaw's internal tool loop -- that would have
        the model's tool calls vanish into our server-side handlers
        instead of reaching the client. One Chat() round-trip, hand
        back text and any tool_calls verbatim.

        Tool-call repair fires here too: the client may have aborted
        a parallel tool mid-flight, leaving an assistant turn whose
        tool_call.Id has no matched tool_result in the follow-up.
        Strict OpenAI-compat backends 400 in that shape; the
        synthesized stub keeps the request valid. }
      if FCfg.StreamReliability.ToolCallRepairEnabled then
        RepairOrphanedToolCalls(Msgs);
      PassthroughOpts := DefaultChatOptions;
      ApplyPromptCacheConfig(PassthroughOpts, FCfg.PromptCache);
      { Skip BuildSystemPrompt -- Codex sends its own developer
        message + AGENTS.md; injecting a PasClaw identity preamble
        on top of that confuses the model. }
      RawTemp := Req.GetFloat('temperature', 0);
      if RawTemp > 0 then PassthroughOpts.Temperature := RawTemp;
      if Req.Has('max_output_tokens') then
        PassthroughOpts.MaxTokens := Req.GetInt('max_output_tokens', PassthroughOpts.MaxTokens)
      else if Req.Has('max_tokens') then
        PassthroughOpts.MaxTokens := Req.GetInt('max_tokens', PassthroughOpts.MaxTokens);

      (* tool_choice forwarding. ResolveResponsesToolChoice handles the
         keyword string forms ("auto"/"none"/"required") AND the two
         force-a-function object shapes (Responses flat top-level name;
         Chat-Completions nested function.name), returning the forced tool
         NAME by convention. Each provider then emits its own native shape.
         '' means absent or unrecognised -> drop and let the provider
         default (typically "auto" with tools present) apply. *)
      if Req.Has('tool_choice') then
      begin
        PassthroughOpts.ToolChoice := ResolveResponsesToolChoice(Req);
        if PassthroughOpts.ToolChoice = '' then
          LogDebug('responses: dropping unrecognised tool_choice ' +
                   '(want auto/none/required, type=function with a name, ' +
                   'or the nested function.name form)', []);
      end;

      LogDebug('responses: passthrough %d msg(s), %d tool def(s), tool_choice=%s -> %s',
               [MsgCount, Length(ToolDefs), PassthroughOpts.ToolChoice, ReqModel]);

      { Streaming passthrough takes its own path: StreamResponsesViaProvider
        calls ChatStream and emits text deltas as the model produces them.
        The non-streaming passthrough (just below) calls Chat() so we have
        the full response object before serializing it as JSON. }
      if WantsStream then
      begin
        StreamResponsesViaProvider(AContext, AResp, AResponseStarted,
                                    Prim, RespId, ReqModel, Msgs, ToolDefs,
                                    PassthroughOpts, ToolsRawJSON, FDebugIO,
                                    FCfg.StreamReliability,
                                    OutUsage, StreamToolCallCount);
        { Stats accumulation for the streaming passthrough path.
          Mirrors the non-streaming branch below: count tokens
          from the provider's reported usage and the model's
          emitted tool calls (executed client-side, not by us).
          Codex P2 on PR #204. }
        AccumulateGatewayStatsRaw(FCfg, GW_BUCKET_V1_RESPONSES,
                                  '(gateway: /v1/responses)',
                                  Prim.GetName, ReqModel,
                                  OutUsage,
                                  StreamToolCallCount,
                                  0);
        Exit;
      end;

      try
        { Empty-turn retry on the passthrough path -- same
          semantics as the tool-loop site, just delivered through
          ChatWithEmptyRetry. The passthrough has no fallback
          chain, so retries against the primary provider are the
          only recovery before the response goes back to the
          client. }
        PassthroughResp := ChatWithEmptyRetry(Prim, Msgs, ToolDefs,
                                               ReqModel, PassthroughOpts,
                                               FCfg.StreamReliability);
      except
        on E: Exception do
        begin
          LogWarn('responses: passthrough Chat() failed: %s', [E.Message]);
          ReplyObj := BuildResponsesObject(RespId, ReqModel, 'failed', '',
                                            EmptyToolCalls, ToolsRawJSON,
                                            PassthroughResp.Usage);
          try
            ErrObj := TJsonObject.Create;
            ErrObj.PutStr('code',    'server_error');
            ErrObj.PutStr('message', 'provider Chat() raised: ' + E.Message);
            ReplyObj.PutObject('error', ErrObj);
            WriteJSON(AResp, 502, ReplyObj.ToJSON);
          finally
            ReplyObj.Free;
          end;
          Exit;
        end;
      end;

      OutContent := PassthroughResp.Content;
      SetLength(OutToolCalls, Length(PassthroughResp.ToolCalls));
      for i := 0 to High(PassthroughResp.ToolCalls) do
        OutToolCalls[i] := PassthroughResp.ToolCalls[i];
      OutUsage := PassthroughResp.Usage;

      { Stats accumulation for the non-streaming passthrough path.
        Codex P2 on PR #204: the legacy-path accumulator below
        only fires when RunToolLoop runs -- successful
        client-tools traffic (Codex CLI / openai-python with
        tool use) never reaches it. Count tokens here from
        PassthroughResp directly, and report the model's emitted
        tool-call count even though we didn't dispatch them
        server-side (the client did). }
      AccumulateGatewayStatsRaw(FCfg, GW_BUCKET_V1_RESPONSES,
                                '(gateway: /v1/responses)',
                                Prim.GetName, ReqModel,
                                OutUsage,
                                Length(OutToolCalls),
                                0);

      { When the model emits only tool calls (no text) the client
        still expects a parseable response; the function_call
        output items carry the agentic signal. Don't synthesize
        placeholder text in that case. }
    end
    else
    begin
      { Legacy path -- no client-supplied tools, so we run the
        internal tool loop and surface its text. This keeps the
        non-Codex flows (curl /v1/responses with just an input
        string) working as before. }
      LoopCfg.Provider      := Prim;
      LoopCfg.Registry      := FRegistry;
      if FToolsHonorInMemoryConfig then LoopCfg.ActiveConfig := FCfg;
      LoopCfg.Model         := ReqModel;
      LoopCfg.MaxIterations := FMaxIter;
      LoopCfg.Parallel := True;
      LoopCfg.Mode          := ParseModeFromBody(Body);  { PR #290 }
      LoopCfg.Fallbacks     := FB;
      LoopCfg.Options       := DefaultChatOptions;
      ApplyPromptCacheConfig(LoopCfg.Options, FCfg.PromptCache);
      if GetEffectiveGatewayToken(FCfg) <> '' then
        LoopCfg.Identity := MakeIdentity('gateway', 'authed')
      else
        LoopCfg.Identity := MakeIdentity('gateway', 'anon');
      if not HasSystemMessage(Msgs) then
        LoopCfg.Options.SystemPrompt := BuildSystemPrompt(FCfg, '',
                                        LoopCfg.Registry <> nil, '', LoopCfg.Mode);
      RawTemp := Req.GetFloat('temperature', 0);
      if RawTemp > 0 then LoopCfg.Options.Temperature := RawTemp;
      if Req.Has('max_output_tokens') then
        LoopCfg.Options.MaxTokens := Req.GetInt('max_output_tokens', LoopCfg.Options.MaxTokens)
      else if Req.Has('max_tokens') then
        LoopCfg.Options.MaxTokens := Req.GetInt('max_tokens', LoopCfg.Options.MaxTokens);
      LoopCfg.OnText        := nil;
      LoopCfg.OnToolCall    := nil;
      LoopCfg.OnToolResult  := nil;
      LoopCfg.ToolOutputCap := FCfg.ToolOutputCap;
      LoopCfg.StreamReliability := FCfg.StreamReliability;

      if FCfg.StreamReliability.ToolCallRepairEnabled then
        RepairOrphanedToolCalls(Msgs);

      if not RunCheckpointedLoop(ReqSessionId(ARequest), LoopCfg, Msgs, Loop) then
      begin
        ReplyObj := BuildResponsesObject(RespId, ReqModel, 'failed', '',
                                          EmptyToolCalls, ToolsRawJSON,
                                          Loop.LastResp.Usage);
        try
          ErrObj := TJsonObject.Create;
          ErrObj.PutStr('code',    'server_error');
          ErrObj.PutStr('message', 'tool loop failed');
          ReplyObj.PutObject('error', ErrObj);
          WriteJSON(AResp, 502, ReplyObj.ToJSON);
        finally
          ReplyObj.Free;
        end;
        Exit;
      end;
      AccumulateGatewayStats(FCfg, GW_BUCKET_V1_RESPONSES,
                             '(gateway: /v1/responses)',
                             Prim.GetName, ReqModel, Loop);

      if Loop.LastResp.FinishReason <> '' then
        FinishReason := Loop.LastResp.FinishReason
      else
        FinishReason := 'stop';

      if Length(Loop.LastResp.ToolCalls) > 0 then
      begin
        Loop.Content := Trim(Loop.Content);
        if Loop.Content <> '' then Loop.Content := Loop.Content + #10#10;
        Loop.Content := Loop.Content + FormatMaxIterNotice(Loop, FMaxIter,
          '`--max-iter` on `pasclaw serve` or `max_iterations` in config', True);
        FinishReason := 'length';
        LogWarn('responses: tool loop hit MaxIterations=%d (%d pending tool call(s), %d content chars)',
                [FMaxIter, Length(Loop.LastResp.ToolCalls), Length(Loop.Content)]);
      end
      else if Trim(Loop.Content) = '' then
      begin
        Loop.Content := Format('(no content returned by the model; finish_reason=%s)',
                                [FinishReason]);
        LogWarn('responses: empty content with finish=%s iterations=%d',
                [FinishReason, Loop.Iterations]);
      end;

      OutContent := Loop.Content;
      SetLength(OutToolCalls, 0);   { internal loop consumed any tool calls }
      OutUsage   := Loop.LastResp.Usage;
    end;

    if WantsStream then
      EmitResponsesStream(AContext, AResp, AResponseStarted,
                          RespId, ReqModel, OutContent,
                          OutToolCalls, ToolsRawJSON,
                          OutUsage, FDebugIO)
    else
    begin
      ReplyObj := BuildResponsesObject(RespId, ReqModel, 'completed', OutContent,
                                        OutToolCalls, ToolsRawJSON, OutUsage);
      try
        if FDebugIO then LogDebug('responses -> 200 JSON: %s', [ReplyObj.ToJSON]);
        WriteJSON(AResp, 200, ReplyObj.ToJSON);
      finally
        ReplyObj.Free;
      end;
    end;
  finally
    Req.Free;
  end;
end;

procedure TGatewayServer.HandleEmbeddings(ARequest: TIdHTTPRequestInfo;
                                          AResp: TIdHTTPResponseInfo);
{ OpenAI-compatible embeddings over PasClaw's local ONNX model. Accepts the
  standard body fields input (string or array of strings), optional model,
  and optional encoding_format, and returns the usual object:list / data /
  model / usage shape. encoding_format "float" (default) emits a JSON number
  array; "base64" emits base64 of the float32 little-endian bytes (what the
  OpenAI Python SDK asks for). No outbound call -- vectors are computed
  on-host and never leave. }
var
  Body, EncFmt, ReqModel, ModelId, OneInput, VecJson, NumStr: string;
  Req, Root, Item, Usage: TJsonObject;
  InArr, DataArr: TJsonArray;
  Inputs: array of string;
  Vec: TArray<Single>;
  Dim, i, j, ApproxTokens: Integer;
  AsBase64: Boolean;
  Bytes: TBytes;
begin
  Body := ReadRequestBody(ARequest);
  if Trim(Body) = '' then
  begin
    WriteJSON(AResp, 400,
      '{"error":{"message":"empty body","type":"invalid_request_error"}}');
    Exit;
  end;

  Req := nil;
  try
    try
      Req := TJsonObject.Parse(Body);
    except
      on E: Exception do
      begin
        WriteJSON(AResp, 400,
          '{"error":{"message":"invalid JSON","type":"invalid_request_error"}}');
        Exit;
      end;
    end;

    { input: a single string OR an array of strings. }
    SetLength(Inputs, 0);
    InArr := Req.ChildArray('input');
    if InArr <> nil then
    begin
      for i := 0 to InArr.Count - 1 do
      begin
        OneInput := InArr.ItemStr(i, '');
        if OneInput <> '' then
        begin
          SetLength(Inputs, Length(Inputs) + 1);
          Inputs[High(Inputs)] := OneInput;
        end;
      end;
    end
    else
    begin
      OneInput := Req.GetStr('input', '');
      if OneInput <> '' then
      begin
        SetLength(Inputs, 1);
        Inputs[0] := OneInput;
      end;
    end;

    if Length(Inputs) = 0 then
    begin
      WriteJSON(AResp, 400,
        '{"error":{"message":"input is required (a string or array of strings)",' +
        '"type":"invalid_request_error"}}');
      Exit;
    end;

    if not LocalEmbedAvailable(GetHome) then
    begin
      WriteJSON(AResp, 503,
        '{"error":{"message":"local embeddings not provisioned -- run ' +
        '`pasclaw memory provision` to download the ONNX model",' +
        '"type":"server_error"}}');
      Exit;
    end;

    LocalEmbedModelInfo(GetHome, ModelId, Dim);
    EncFmt   := Req.GetStr('encoding_format', 'float');
    AsBase64 := SameText(EncFmt, 'base64');
    ReqModel := Req.GetStr('model', '');

    ApproxTokens := 0;
    DataArr := TJsonArray.Create;
    try
      for i := 0 to High(Inputs) do
      begin
        if not LocalEmbed(GetHome, Inputs[i], Vec) then
        begin
          WriteJSON(AResp, 500,
            '{"error":{"message":"embedding failed","type":"server_error"}}');
          Exit;
        end;
        Item := TJsonObject.Create;
        Item.PutStr('object', 'embedding');
        Item.PutInt('index', i);
        if AsBase64 then
        begin
          SetLength(Bytes, Length(Vec) * SizeOf(Single));
          if Length(Vec) > 0 then Move(Vec[0], Bytes[0], Length(Bytes));
          Item.PutStr('embedding', BytesToBase64(Bytes));
        end
        else
        begin
          VecJson := '[';
          for j := 0 to High(Vec) do
          begin
            if j > 0 then VecJson := VecJson + ',';
            { Str() always emits a '.' decimal regardless of host locale, on
              both FPC and Delphi -- no TFormatSettings needed (dcc64 didn't
              resolve DefaultFormatSettings here, and FPC 3.2.2 has no
              parameterless TFormatSettings.Create). 7 decimals comfortably
              covers a unit-normalised float32 component. }
            Str(Vec[j]:0:7, NumStr);
            VecJson := VecJson + Trim(NumStr);
          end;
          VecJson := VecJson + ']';
          Item.PutRaw('embedding', VecJson);
        end;
        DataArr.AddObject(Item);   { takes ownership; Item := nil }
        { Rough token estimate -- the endpoint doesn't expose the tokenizer's
          count and most clients ignore embedding usage. }
        Inc(ApproxTokens, (Length(Inputs[i]) + 3) div 4);
      end;

      Root := TJsonObject.Create;
      try
        Root.PutStr('object', 'list');
        Root.PutArray('data', DataArr);   { takes ownership; DataArr := nil }
        if ReqModel <> '' then
          Root.PutStr('model', ReqModel)   { echo the requested model id }
        else
          Root.PutStr('model', 'pasclaw-local-' + ModelId);
        Usage := TJsonObject.Create;
        Usage.PutInt('prompt_tokens', ApproxTokens);
        Usage.PutInt('total_tokens',  ApproxTokens);
        Root.PutObject('usage', Usage);
        WriteJSON(AResp, 200, Root.ToJSON);
      finally
        Root.Free;
      end;
    finally
      DataArr.Free;   { nil after PutArray's ownership transfer -- safe }
    end;
  finally
    Req.Free;
  end;
end;

procedure TGatewayServer.HandleModels(AResp: TIdHTTPResponseInfo);
{ OpenAI-compatible model list. Enumerates the default provider's full
  catalog via PasClaw.Providers.Models so the web UI's picker shows every
  model the operator can choose, not just the configured default. The
  on-disk cache ($PASCLAW_HOME/cache/models/<provider>.json) is preferred
  so a warm gateway answers instantly; a cold cache triggers one live
  fetch (shared with `pasclaw model refresh`) that is then persisted.
  Discovery never raises -- when it is unavailable (offline, no key,
  placeholder provider) the response still carries the configured default,
  preserving the historical one-model contract. }
var
  Root, Item: TJsonObject;
  DataArr: TJsonArray;
  DefModel, ProvName, Base, Key, Err: string;
  Spec: TProviderSpec;
  Disc: TModelDiscoveryResult;
  Seen: TStringList;
  i, j: Integer;
  RelayWorkers: TRelayWorkerArray;
  IsRelay: Boolean;

  procedure AddModel(const Id, OwnedBy: string; Created: Int64);
  begin
    if (Id = '') or (Seen.IndexOf(Id) >= 0) then Exit;
    Seen.Add(Id);
    Item := TJsonObject.Create;
    Item.PutStr('id',     Id);
    Item.PutStr('object', 'model');
    if Created > 0 then Item.PutInt('created', Created)
    else                Item.PutInt('created', DateTimeToUnix(Now, False));
    Item.PutStr('owned_by', OwnedBy);
    DataArr.AddObject(Item);
  end;

begin
  DefModel := FCfg.DefaultModel;
  ProvName := FCfg.DefaultProvider;
  IsRelay  := False;
  for i := 0 to High(FCfg.Providers) do
    if SameText(FCfg.Providers[i].Name, ProvName) and
       SameText(FCfg.Providers[i].Kind, 'relay') then
    begin
      IsRelay := True;
      Break;
    end;

  Seen := TStringList.Create;
  Root := TJsonObject.Create;
  try
    Root.PutStr('object', 'list');
    DataArr := TJsonArray.Create;

    (* Relay provider has no /v1/models endpoint to discover from --
       the queue's "available models" are whatever the currently-
       connected workers advertise via X-Relay-Capabilities. Enumerate
       them so the webui's model picker shows the worker's actual
       model id (e.g. Qwen2.5-Coder-7B-Instruct-q4f16_1-MLC) rather
       than the literal "pasclaw" fallback that surfaced before. A
       worker with empty capabilities (the wildcard case) contributes
       nothing here, so the fallback below kicks in. *)
    if IsRelay and (FRelayQueue <> nil) then
    begin
      RelayWorkers := FRelayQueue.GetConnectedWorkers;
      for i := 0 to High(RelayWorkers) do
        for j := 0 to High(RelayWorkers[i].Capabilities) do
          AddModel(RelayWorkers[i].Capabilities[j], 'relay-worker', 0);
    end
    else if (ProvName <> '') and
       ResolveProviderSpecForName(FCfg, ProvName, Spec, Base, Key, Err) then
    begin
      { Cache first (instant, no network on every page load); fall back to
        a single live fetch and persist it for next time. }
      if not LoadCachedModels(ProvName, Disc) then
      begin
        Disc := DiscoverModels(Spec, Base, Key);
        if Disc.Ok and (Length(Disc.Models) > 0) then
          SaveCachedModels(ProvName, Disc);
      end;
      if Disc.Ok then
        for i := 0 to High(Disc.Models) do
          AddModel(Disc.Models[i].Id, ProvName, Disc.Models[i].CreatedAt);
    end;

    { Always surface the configured default so the contract holds even when
      discovery yields nothing. Dedup keeps it from doubling a catalog row.
      "pasclaw" fallback when relay is the default AND no worker is
      connected AND the operator didn't pin a model -- still better than
      an empty list. }
    if DefModel = '' then DefModel := 'pasclaw';
    AddModel(DefModel, 'pasclaw', 0);

    Root.PutArray('data', DataArr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
    Seen.Free;
  end;
end;

procedure TGatewayServer.HandleProvidersCatalog(AResp: TIdHTTPResponseInfo);
{ The static provider catalog as JSON for the web onboarding wizard. No
  secrets -- just kind/display name, default base+model, and whether the
  provider needs an API key (so the wizard knows to show the key field) and
  whether the operator must supply a base (templated/empty base, e.g.
  Cloudflare AI Gateway or a local Ollama/vLLM URL). Placeholder-family
  kinds are marked so the UI can grey them out. }
var
  Root, Item: TJsonObject;
  Arr: TJsonArray;
  Specs: TProviderSpecArray;
  i: Integer;
  AuthStr: string;
  NeedsBase: Boolean;

  function AuthKindStr(K: TAuthSchemeKind): string;
  begin
    case K of
      asNone:   Result := 'none';
      asHeader: Result := 'header';
    else        Result := 'bearer';
    end;
  end;

begin
  Specs := AllProviderSpecs;
  Root := TJsonObject.Create;
  try
    Root.PutStr('object', 'list');
    Arr := TJsonArray.Create;
    for i := 0 to High(Specs) do
    begin
      AuthStr := AuthKindStr(Specs[i].Auth.Kind);
      { The operator must fill in a base when the catalog default is empty
        (local servers) or carries account/gateway-id placeholders in
        braces (e.g. Cloudflare AI Gateway). Relay is exempt: it has no
        outbound URL -- external workers connect inbound to the in-process
        queue -- so an empty base is intentional, not a missing field. }
      NeedsBase := (Specs[i].Family <> pfRelay) and
                   ((Trim(Specs[i].DefaultBase) = '') or
                    (Pos('{', Specs[i].DefaultBase) > 0));
      Item := TJsonObject.Create;
      Item.PutStr ('kind',          Specs[i].Kind);
      Item.PutStr ('display_name',  Specs[i].DisplayName);
      Item.PutStr ('default_base',  Specs[i].DefaultBase);
      Item.PutStr ('default_model', Specs[i].DefaultModel);
      Item.PutStr ('auth',          AuthStr);
      Item.PutBool('needs_key',     Specs[i].Auth.Kind <> asNone);
      Item.PutBool('needs_base',    NeedsBase);
      { Relay's model is a wildcard -- the worker advertises it -- so the
        wizard must not force one. Every other kind needs a model id. }
      Item.PutBool('needs_model',   Specs[i].Family <> pfRelay);
      Item.PutBool('placeholder',   Specs[i].Family = pfPlaceholder);
      Item.PutStr ('notes',         Specs[i].Notes);
      Arr.AddObject(Item);
    end;
    Root.PutArray('data', Arr);
    WriteJSON(AResp, 200, Root.ToJSON);
  finally
    Root.Free;
  end;
end;

initialization
  GProviderSignatureCacheLock := TCriticalSection.Create;
  GProviderSignatureCache     := TStringList.Create;
  GGatewayStatsLock           := TCriticalSection.Create;
  { Unsorted on purpose: insertion order doubles as FIFO so the
    eviction in RememberProviderSignature (Delete(0)) actually drops
    the OLDEST entry. A sorted+dupIgnore TStringList would order by
    call_id alphabetically and Delete(0) would evict whichever
    conversation happened to draw the lowest call_id, breaking
    active turns unpredictably. IndexOfName scans linearly but
    PROVIDER_SIGNATURE_CACHE_MAX is small (1024) and we only hit
    this on tool-call boundaries -- O(n) lookups are sub-millisecond
    and rare. }

finalization
  GProviderSignatureCache.Free;
  GProviderSignatureCacheLock.Free;
  GGatewayStatsLock.Free;

end.
