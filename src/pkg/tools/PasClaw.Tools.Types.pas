{
  PasClaw.Tools.Types - shared types for the tools registry.
  Mirrors the Tool interface in pkg/tools/registry.go.
}
unit PasClaw.Tools.Types;

{$IFDEF FPC}{$MODE DELPHI}{$ENDIF}
{$H+}

interface

uses
  SysUtils, Classes;

type
  { Handler signature: receives a raw JSON argument blob and returns a string
    that becomes the tool_result content. The handler may set Err to a non-empty
    string to signal a recoverable error to the model. }
  TToolHandler = function(const ArgsJSON: string; out ErrMsg: string): string;

  { Method-pointer variant for class-based tools (TPasClawTool descendants).
    The registry prefers HandlerObj over Handler when both are set, so a
    class instance can dispatch through its own Self.Run without going via
    a top-level function pointer. }
  TToolHandlerObj = function(const ArgsJSON: string; out ErrMsg: string): string of object;

  { Tool category -- drives parallel dispatch in PasClaw.Tools.ToolLoop.

    tcMutating: the tool can mutate shared state (filesystem writes,
                shell subprocesses, MCP-stdio handshakes that share a
                single stdin pipe, memory writes). MUST run serially --
                a batch containing one mutating call has size 1, never
                gets parallelized with siblings.

    tcReadOnly: the tool only reads. Filesystem reads, HTTP GETs,
                grep / search / list. Multiple read-only calls from a
                single model turn can fan out concurrently.

    tcMutating is the first (= zero-init) value on purpose: a freshly-
    allocated TTool record on the stack with the Category field left
    untouched defaults to "treat as mutating", which is the safe choice
    when a tool author forgets to set it. Built-in tools and TPasClawTool
    subclasses explicitly opt into tcReadOnly. }
  TToolCategory = (tcMutating, tcReadOnly);

  TTool = record
    Name:        string;
    Description: string;
    Schema:      string;   { JSON schema (parameters) }
    Handler:     TToolHandler;
    HandlerObj:  TToolHandlerObj;
    IsCore:      Boolean;
    Category:    TToolCategory;
    { IsDeferred -- progressive-disclosure marker. When True the registry
      skips the tool from ToProviderDefs (the provider's `tools` array
      gets the schema STRIPPED), but RunTool / Find still dispatch
      normally. The model sees the name in a system-prompt "deferred
      tools" pointer and uses tool_search to load the schema, which
      flips the per-name flag in the registry's revealed set; the next
      ToProviderDefs call then includes the tool. Mirrors Claude Code's
      ToolSearch pattern. Default False -- all built-in / skill / non-
      MCP tools surface immediately. }
    IsDeferred:  Boolean;
    { Hidden -- a back-compat alias. When True the tool is a rename shim:
      Find / RunTool dispatch to it normally so old tool names keep working
      for existing configs and mid-session calls, but ToProviderDefs skips
      it so the model only ever sees the new canonical name in its tool
      list. Unlike IsDeferred, a Hidden tool is never surfaced by
      tool_search / DeferredNames -- it is permanently invisible to the
      model. Default False. }
    Hidden:      Boolean;
    (* SerialOnly -- "never share a parallel batch", independent of Category.

       Category was carrying two unrelated meanings at once. ToolLoop reads
       it as "safe to run concurrently" when it coalesces a round's calls
       into one parallel batch; the plan-mode gate and the read-only MCP
       server read it as "does not really mutate, so allow it". Those
       disagree for any tool that writes but is deliberately labelled
       tcReadOnly to pass the gate -- PasClaw.Tools.PlanWrite documents
       exactly that trade, and memory_search inherits it by accident
       because Tool_MemorySearch calls IMemoryIndex.SyncDir, which
       reindexes files and deletes rows in .index.db. Two of those in one
       batch are two writers on one SQLite file (Codex, PR #537).

       Splitting the meanings rather than re-categorising is what keeps
       both users correct: Category still answers "may it run in plan
       mode / be exposed read-only", SerialOnly answers "may it run beside
       something else".

       Polarity is deliberate. TTool records are built on the stack and
       this codebase does NOT FillChar them (managed strings), so a site
       that assigns fields one by one leaves a new Boolean holding
       whatever was on the stack. With SerialOnly, garbage-True costs a
       batch slot -- a tool runs alone that could have run beside others.
       The inverse field (ParallelSafe) would have garbage-True mean
       "batch this writer concurrently", turning uninitialised memory into
       a data race. The safe failure had to be the default one. *)
    SerialOnly:  Boolean;
  end;

  TToolList = array of TTool;

implementation

end.
