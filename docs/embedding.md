# Embedding in your own app

`TPasClawAgent` and `TPasClawServer` (unit `PasClaw.Agent`) are `TComponent`s you can drop on a form or instantiate from code to embed the full agent — provider auth, tools, MCP, skills — inside a standalone Delphi or FPC binary, without shelling out to the CLI.

## Code-driven agent

```pascal
uses PasClaw.Agent, PasClaw.Tools;

var
  Agent: TPasClawAgent;
begin
  Agent := TPasClawAgent.Create('claude-opus-4-7');
  try
    Agent.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
    Agent.RegisterTool(TWebSearchTool.Create);
    Agent.RegisterTool(TWebFetchTool.Create);
    Agent.RegisterTool(TFileSystemTool.Create);
    WriteLn(Agent.Run('Summarize the latest Delphi release notes.'));
  finally
    Agent.Free;
  end;
end;
```

`SetProvider(Kind, APIKey)` builds a `TProviderConfig` in-memory from the catalog entry for `Kind` (`anthropic`, `openai`, `gemini`, `groq`, `ollama`, etc. — see `PasClaw.Providers.Catalog`) plus the API key the caller hands in. The catalog supplies the default base URL and default model; both can be overridden via the three-arg and four-arg `SetProvider` overloads. This lets an embedded binary run without ever touching `~/.pasclaw/config.json` — set the env var, ship the binary, done.

`Run(prompt)` raises `EPasClawRun` on failure. When you'd rather not unwind exceptions:

```pascal
if Agent.Chat('hi', Reply, Err) then
  WriteLn(Reply)
else
  WriteLn('error: ', Err);
```

`RegisterTool` takes ownership of the `TPasClawTool` instance and frees it with the agent.

## Form-designer / property-driven form

Back-compat with the original `Create(nil)` flow — drop the component on a form, set published properties, wire events:

```pascal
PC := TPasClawAgent.Create(nil);
PC.Model       := 'claude-opus-4-7';
PC.SystemPrompt := 'You are a Pascal expert.';
PC.OnText      := MyTextHandler;
if PC.Chat('hi', Reply, Err) then WriteLn(Reply);
```

## Built-in tool classes

| Class | Tools registered |
|---|---|
| `TWebSearchTool` | `web_search` |
| `TWebFetchTool` | `web_fetch` |
| `TFileSystemTool` | `fs_read` + `fs_write` + `fs_grep` + `fs_list` + `fs_edit_hashline` |
| `TShellTool` | `shell_exec` |
| `TMemoryTool` | `memory_search` |

Each is a one-liner `RegisterTool` call. The bundle classes (`TFileSystemTool`) register multiple tools per instance.

## Custom tools

Subclass `TPasClawTool` (unit `PasClaw.Tools.Obj`) and override `Name` / `Description` / `Schema` / `Run` / `Category`:

```pascal
type
  TGreetTool = class(TPasClawTool)
  public
    function Name:        string; override;
    function Description: string; override;
    function Schema:      string; override;
    function Category:    TToolCategory; override;
    function Run(const ArgsJSON: string; out Err: string): string; override;
  end;

function TGreetTool.Name: string;        begin Result := 'greet'; end;
function TGreetTool.Description: string; begin Result := 'Greet someone by name.'; end;
function TGreetTool.Schema: string;
begin
  Result := '{"type":"object",' +
            '"properties":{"name":{"type":"string"}},' +
            '"required":["name"]}';
end;
function TGreetTool.Category: TToolCategory; begin Result := tcReadOnly; end;

function TGreetTool.Run(const ArgsJSON: string; out Err: string): string;
var
  Obj: TJsonObject;
  Name: string;
begin
  Err := '';
  Obj := TJsonObject.Parse(ArgsJSON);
  try
    Name := Obj.GetStr('name', '');
    if Name = '' then begin Err := 'missing name'; Exit(''); end;
    Result := 'hello, ' + Name;
  finally
    Obj.Free;
  end;
end;
```

Register it:

```pascal
Agent.RegisterTool(TGreetTool.Create);
```

The category controls parallel dispatch: `tcReadOnly` tools fan out to worker threads on multi-tool turns; `tcMutating` tools stay serial. Default `tcMutating` if you don't override.

## Hosting the gateway

`TPasClawServer` hosts the full HTTP gateway inside the calling process:

```pascal
uses PasClaw.Agent, PasClaw.Tools;

var
  Server: TPasClawServer;
begin
  Server := TPasClawServer.Create('0.0.0.0', 8088);
  try
    Server.SetProvider('anthropic', GetEnvironmentVariable('ANTHROPIC_API_KEY'));
    Server.RegisterTool(TWebSearchTool.Create);
    Server.Run;  { blocks until Stop is signalled from another thread }
  finally
    Server.Free;
  end;
end;
```

`SetProvider` works the same way as on `TPasClawAgent` — call it before `Start` and the gateway boots with the in-memory provider config.

`Run` does `Start + WaitForStop` in one call and raises `EPasClawRun` if startup fails. Use `Start` / `WaitForStop` / `Stop` separately when you need to do something between binding the socket and entering the wait. SIGINT handling is the embedder's problem — most hosting apps already have their own signal-handling strategy, so the component doesn't install one.

## Hooks

`TPasClawHook` (unit `PasClaw.Agent.Hooks`) is the typed callback surface for observers, transformers, and vetoers of agent events. Four virtuals:

| Virtual | Override to |
|---|---|
| `BeforeTurn(var ContinueTurn, var Messages)` | Set `ContinueTurn := False` to abort cleanly; mutate `Messages` for last-second context injection. |
| `BeforeToolCall(call, var Cancel, var SyntheticResult)` | `Cancel := True` bypasses the real tool handler and uses `SyntheticResult` as the `tool_result` — the approval-gate pattern. |
| `AfterToolResult(call, var ResultText, var ErrMsg, var SteeringMessage)` | Rewrite results inline AND inject a system note before the next LLM round (picoclaw's steering pattern). |
| `OnError(Stage, Msg)` | Observe failures: `hsProviderCall`, `hsToolDispatch`, etc. |

Register:

```pascal
Agent.RegisterHook(THook.Create);
```

Multiple hooks form an ordered chain in registration order. Each hook sees `Self.Identity` (a `TIdentity` record) so it can gate per-sender behaviour:

```pascal
function TBlockNonOpsHook.BeforeTurn(...): Boolean;
begin
  if Self.Identity.Platform <> 'slack' then
    ContinueTurn := False;   // only slack senders may proceed
end;
```

## Sample binaries

```sh
cd samples/component-console
make get-indy   # only needed once, from repo root
make            # builds all three: SampleConsole, SampleSimple, SampleServer
make simple     # just the agent code-form sample
make server     # just the server sample
```

`SampleSimple` is the canonical 30-line embedder; `SampleServer` mirrors the gateway shape; `SampleConsole` shows the `Run` / `Chat` / event-handler interplay.

## Legacy unit name

`PasClaw.Component` is still available as a legacy unit name — it now re-exports everything from `PasClaw.Agent`, so existing code keeps compiling. New code should use `PasClaw.Agent` directly.

## Threading

- The agent loop runs on the calling thread. `Agent.Run` blocks until the turn returns.
- Read-only tools fan out to FPC `TThread` workers when `Cfg.Parallel = True` (component default: `False`).
- The `TPasClawServer` HTTP listener runs Indy's worker thread per connection. Each `/v1/chat/completions` call hits a worker thread; the agent loop runs there until the response is fully written. The OnText / OnToolCall / OnToolResult callbacks fire on the same worker — synchronise to the UI thread yourself (e.g. `Synchronize` / `Queue`).

## See also

- [Tools](./tools.md) for the built-in tool catalog the model sees.
- [Providers](./providers.md) for `SetProvider` overload arguments.
- [Gateway](./gateway.md) for the route table `TPasClawServer` serves.
- [Sessions](./sessions.md) for how the agent persists conversation history.
