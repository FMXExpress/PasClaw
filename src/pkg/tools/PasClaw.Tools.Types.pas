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

       Do NOT set this field at a registration site: it is derived from
       ToolIsSerialOnly by TToolRegistry.RegisterImpl, which ignores
       whatever the incoming record held. The first version of this change
       did let sites assign it, defended by polarity -- garbage-True only
       costs a batch slot, where the inverse field would have made
       uninitialised memory a data race. That reasoning was wrong in the
       way that matters: ~34 sites build TTool as a bare stack record and
       never touch this field, so "merely" losing batching would have been
       random and silent, in the exact machinery the field exists to
       enable. Safe is not the same as correct (Codex, PR #538). *)
    SerialOnly:  Boolean;
  end;

  TToolList = array of TTool;

{ The authoritative set of tools that must never share a parallel batch.

  This is a LIST rather than a per-registration flag because the flag it
  feeds is read by the batcher, and ~34 registration sites build TTool as a
  bare stack record and assign fields one at a time -- exactly the shape
  that left HandlerObj holding stack garbage until RegisterImpl started
  clearing it defensively. An uninitialised Boolean is a bug whichever way
  it points: a parallel-safe tool that randomly reads True would silently
  lose the batching this exists to enable. So TToolRegistry.RegisterImpl
  derives SerialOnly from here and ignores whatever the caller's record
  happened to contain, which cannot be corrupted by an unassigned field.

  A tool belongs here when it writes shared state despite being tcReadOnly
  -- a category it carries so it can pass the plan-mode gate and the
  read-only MCP server, neither of which cares about concurrency. }
function ToolIsSerialOnly(const Name: string): Boolean;

implementation

function ToolIsSerialOnly(const Name: string): Boolean;
begin
  { memory_search -- Tool_MemorySearch calls IMemoryIndex.SyncDir before
      searching, which reindexes changed files and drops rows for deleted
      ones: writes and commits against .index.db. Two searches in one batch
      (two different queries is an ordinary ask) are two writers on that
      file, and the loser gets a locking error instead of results.
    plan_write   -- writes workspace/PLAN.md. PasClaw.Tools.PlanWrite
      documents choosing tcReadOnly precisely to pass the pmPlan gate.
    todo_write   -- rewrites the checklist file wholesale; two concurrent
      whole-file replacements of one path is the same hazard. }
  Result := SameText(Name, 'memory_search')
         or SameText(Name, 'plan_write')
         or SameText(Name, 'todo_write');
end;

end.
