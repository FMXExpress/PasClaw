# ---------------------------------------------------------------------------
# The runtime: PasClaw's workflow engine (src/pkg/workflow/PasClaw.Workflow.pas)
# re-implemented step for step -- the same templates, selectors, order, await
# polling, loop and outputs -- so this script gives what a run in PasClaw gives.
# ---------------------------------------------------------------------------
import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request


class StepError(Exception):
    pass


def pas_trim(s):
    """Pascal's Trim: drop characters <= ' ' at both ends."""
    i, j = 0, len(s)
    while i < j and s[i] <= " ":
        i += 1
    while j > i and s[j - 1] <= " ":
        j -= 1
    return s[i:j]


def json_escape(s):
    """PasClaw.JSON.JsonEscape: what a substituted value becomes."""
    out = []
    for c in s:
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\b":
            out.append("\\b")
        elif c == "\t":
            out.append("\\t")
        elif c == "\n":
            out.append("\\n")
        elif c == "\f":
            out.append("\\f")
        elif c == "\r":
            out.append("\\r")
        elif ord(c) < 32:
            out.append("\\u%04X" % ord(c))
        else:
            out.append(c)
    return "".join(out)


def fp_float(v):
    m, e = ("%.16E" % v).split("E")
    return "%sE%s%03d" % (m, e[0], int(e[1:]))


def fp_json(v):
    """fpjson's AsJSON -- an object or array a selector lands on, as text."""
    if isinstance(v, dict):
        if not v:
            return "{}"
        return "{ " + ", ".join('"%s" : %s' % (json_escape(k), fp_json(x)) for k, x in v.items()) + " }"
    if isinstance(v, list):
        return "[" + ", ".join(fp_json(x) for x in v) + "]"
    if isinstance(v, str):
        return '"' + json_escape(v) + '"'
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    return fp_float(v)


def item_text(v):
    """fpjson's AsString for an array item (None: no string form)."""
    if isinstance(v, bool):
        return "True" if v else "False"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return fp_float(v)
    if isinstance(v, str):
        return v
    return None


def scan_placeholders(s):
    out, i, n = [], 0, len(s)
    while i < n - 1:
        if s[i] == "{" and s[i + 1] == "{":
            i += 2
            start = i
            while i < n - 1 and not (s[i] == "}" and s[i + 1] == "}"):
                i += 1
            if i < n - 1 and s[i] == "}" and s[i + 1] == "}":
                out.append(pas_trim(s[start:i]))
                i += 2
        else:
            i += 1
    return out


def split_selector(sel):
    out, tok, i, n = [], "", 0, len(sel)
    while i < n:
        c = sel[i]
        if c == ".":
            if tok:
                out.append(tok)
                tok = ""
            i += 1
        elif c == "[":
            if tok:
                out.append(tok)
                tok = ""
            i += 1
            num = ""
            while i < n and sel[i] != "]":
                num += sel[i]
                i += 1
            if i < n and sel[i] == "]":
                i += 1
            out.append("#" + pas_trim(num))
        else:
            tok += c
            i += 1
    if tok:
        out.append(tok)
    return out


def _parse(text, kind):
    try:
        v = json.loads(text)
    except (ValueError, TypeError):
        return None
    return v if isinstance(v, kind) else None


def eval_selector(text, selector):
    """A dotted/[i] path into a JSON text; None when it does not resolve."""
    steps = split_selector(selector)
    if not steps:
        return None
    cur = text
    if steps[0] == "structuredContent":
        o = _parse(cur, dict)
        if o is not None and "structuredContent" not in o:
            steps = steps[1:]
        if not steps:
            return None
    for st in steps:
        if st.startswith("#"):
            try:
                idx = int(st[1:])
            except ValueError:
                return None
            arr = _parse(cur, list)
            if idx < 0 or arr is None or idx >= len(arr):
                return None
            item = arr[idx]
            if isinstance(item, (dict, list)):
                cur = fp_json(item)
            else:
                cur = item_text(item)
                if cur is None:
                    return None
        else:
            obj = _parse(cur, dict)
            if obj is None or st not in obj:
                return None
            item = obj[st]
            if isinstance(item, (dict, list)):
                cur = fp_json(item)
            elif isinstance(item, str):
                cur = item
            else:
                return None
    return cur


def find_result(results, node_id):
    for r in results:
        if r["node"] == node_id:
            return r
    return None


def resolve(template, inputs, results, self_json=""):
    """Substitute every {{...}} in an args JSON text, as the engine does."""
    resolved = template
    for inner in scan_placeholders(template):
        if "." not in inner:
            raise StepError('bad template "{{%s}}"' % inner)
        kind, rest = inner.split(".", 1)
        if kind == "inputs":
            if rest not in inputs:
                raise StepError('missing input "%s" for {{%s}}' % (rest, inner))
            v = inputs[rest]
            val = v if isinstance(v, str) else ""
        elif kind == "self":
            val = eval_selector(self_json, rest)
            if val is None:
                raise StepError("{{%s}}: selector \"%s\" did not resolve in this node's result" % (inner, rest))
        elif kind == "nodes":
            node_id, _, sel = rest.partition(".")
            r = find_result(results, node_id)
            if r is None:
                raise StepError('{{%s}} references node "%s" that has not run' % (inner, node_id))
            if not sel:
                val = r["text"]
            else:
                val = eval_selector(r["json"], sel)
                if val is None:
                    raise StepError('{{%s}}: selector "%s" did not resolve in node "%s" output' % (inner, sel, node_id))
        else:
            raise StepError('unknown template kind "%s" in {{%s}}' % (kind, inner))
        resolved = resolved.replace("{{" + inner + "}}", json_escape(val))
    return resolved


def resolve_one(template, inputs, results):
    """A single template (an output's value, the loop's until) to its value."""
    wrapped = '{"v":"' + json_escape(template) + '"}'
    resolved = resolve(wrapped, inputs, results)
    o = _parse(resolved, dict)
    v = o.get("v") if o is not None else None
    return v if isinstance(v, str) else ""


def topo_order(spec):
    nodes = spec["nodes"]
    ids = [n["id"] for n in nodes]
    n = len(nodes)
    dep = [[False] * n for _ in range(n)]
    for e in spec["edges"]:
        if e["from"] not in ids:
            raise StepError('edge from unknown node "%s"' % e["from"])
        if e["to"] not in ids:
            raise StepError('edge to unknown node "%s"' % e["to"])
        dep[ids.index(e["to"])][ids.index(e["from"])] = True
    for i, node in enumerate(nodes):
        for inner in scan_placeholders(node["args"]):
            if inner.startswith("nodes."):
                ref = inner[6:].split(".", 1)[0]
                if ref not in ids:
                    raise StepError('node "%s" references unknown node "%s"' % (node["id"], ref))
                if ids.index(ref) == i:
                    raise StepError('node "%s" references itself' % node["id"])
                dep[i][ids.index(ref)] = True
    indeg = [sum(1 for j in range(n) if dep[i][j]) for i in range(n)]
    done, order = [False] * n, []
    while len(order) < n:
        ready = [i for i in range(n) if not done[i] and indeg[i] == 0]
        if not ready:
            raise StepError("workflow has a cycle")
        j = ready[0]
        done[j] = True
        order.append(ids[j])
        for i in range(n):
            if not done[i] and dep[i][j]:
                indeg[i] -= 1
    return order


def unwrap_result(raw, text):
    t = pas_trim(text)
    if t.startswith("{") and _parse(t, dict) is not None:
        return t
    return raw


def text_wrap(s):
    return '{"text":"' + json_escape(s) + '"}'


def plan_node(node):
    tool = node["tool"]
    aw = node.get("await")
    t = pas_trim(tool).lower()
    eff = "replicate__create_predictions" if t == "replicate" else tool
    if t in ("replicate", "replicate__create_predictions") and not aw:
        aw = {"tool": "replicate__get_predictions", "args": '{"prediction_id":"{{self.id}}"}',
              "status_selector": "status", "output_selector": "output[0]",
              "interval_ms": 2000, "timeout_ms": 300000,
              "success": ["succeeded"], "failure": ["failed", "canceled", "aborted"]}
    return eff, aw


# --------------------------------------------------------------- HTTP
def http_json(method, url, body, headers, timeout=300):
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Accept", "application/json")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as e:
        raise StepError("%s %s: %s" % (method, url, e))


def _str_arg(obj, key):
    v = obj.get(key) if isinstance(obj, dict) else None
    return v if isinstance(v, str) else ""


# --------------------------------------------------------------- llm
def llm_call(args_json):
    a = _parse(args_json, dict)
    if a is None:
        raise StepError("llm node: bad args JSON")
    prov = pas_trim(_str_arg(a, "provider")) or DEFAULT_PROVIDER
    model = pas_trim(_str_arg(a, "model"))
    prompt, system = _str_arg(a, "prompt"), _str_arg(a, "system")
    if prompt == "":
        raise StepError('llm node: "prompt" is required')
    p = PROVIDERS.get(prov, {})
    base = (os.environ.get("LLM_BASE_URL") or p.get("base_url") or "https://api.openai.com").rstrip("/")
    url = base + ("/chat/completions" if base.endswith("/v1") else "/v1/chat/completions")
    model = os.environ.get("LLM_MODEL") or model or p.get("model") or DEFAULT_MODEL
    key = os.environ.get(p.get("key_env", "") or "LLM_API_KEY") or os.environ.get("LLM_API_KEY") \
        or os.environ.get("OPENAI_API_KEY", "")
    msgs = ([{"role": "system", "content": system}] if system else []) + [{"role": "user", "content": prompt}]
    headers = {"Authorization": "Bearer " + key} if key else {}
    status, body = http_json("POST", url, {"model": model, "messages": msgs}, headers)
    if status >= 400:
        raise StepError('llm node: provider "%s" returned status %d' % (prov, status))
    j = _parse(body, dict) or {}
    msg = ((j.get("choices") or [{}])[0] or {}).get("message") or {}
    content = msg.get("content") or ""
    if isinstance(content, list):
        content = "".join(c.get("text", "") for c in content if isinstance(c, dict))
    return content, text_wrap(content)


# --------------------------------------------------------------- replicate
# A `replicate` step runs over Replicate's HTTP API: the create here, then the
# step's await plan -- PasClaw's own (plan_node) or the one written on the step
# -- polls, its replicate__get_predictions answered by the HTTP API as well.
def _replicate_api():
    token = os.environ.get("REPLICATE_API_TOKEN", "")
    if not token:
        raise StepError("replicate step: set REPLICATE_API_TOKEN")
    base = os.environ.get("REPLICATE_API_BASE", "https://api.replicate.com").rstrip("/")
    return base, {"Authorization": "Bearer " + token}


def replicate_create(args_json):
    """A `replicate` step's create: the prediction, as JSON text."""
    base, headers = _replicate_api()
    a = _parse(args_json, dict) or {}
    inp = a.get("input") if isinstance(a.get("input"), dict) else {}
    model, version = _str_arg(a, "model"), _str_arg(a, "version")
    if not version and ":" in model:
        model, version = model.split(":", 1)
    if version:
        url, body = base + "/v1/predictions", {"version": version, "input": inp}
    elif model:
        url, body = base + "/v1/models/" + model + "/predictions", {"input": inp}
    else:
        raise StepError('replicate step: "model" or "version" is required')
    status, text = http_json("POST", url, body, headers)
    if status >= 400:
        raise StepError("replicate: create returned %d: %s" % (status, text[:300]))
    return text


def replicate_get(args_json):
    """replicate__get_predictions over the HTTP API: the prediction, as JSON text."""
    base, headers = _replicate_api()
    pid = _str_arg(_parse(args_json, dict) or {}, "prediction_id")
    if not pid:
        raise StepError('replicate__get_predictions: "prediction_id" is required')
    status, text = http_json("GET", base + "/v1/predictions/" + pid, None, headers)
    if status >= 400:
        raise StepError("replicate: poll returned %d: %s" % (status, text[:300]))
    return text, text


# --------------------------------------------------------------- MCP
class _MCPPool:
    """One session per server, kept open for the run (stdio or HTTP)."""

    def __init__(self):
        import asyncio
        import threading
        self.asyncio = asyncio
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        self.queues, self.tasks = {}, []

    def call(self, server, tool, args):
        return self.asyncio.run_coroutine_threadsafe(self._call(server, tool, args), self.loop).result()

    async def _call(self, server, tool, args):
        if server not in self.queues:
            ready = self.loop.create_future()
            q = self.asyncio.Queue()
            self.queues[server] = q
            self.tasks.append(self.loop.create_task(self._serve(server, q, ready)))
            await ready
        fut = self.loop.create_future()
        await self.queues[server].put((tool, args, fut))
        return await fut

    async def _serve(self, server, q, ready):
        from contextlib import asynccontextmanager
        from mcp import ClientSession
        cfg = MCP_SERVERS[server]

        @asynccontextmanager
        async def transport():
            if cfg.get("url"):
                headers = {}
                if os.environ.get(cfg.get("auth_env", "")):
                    headers["Authorization"] = os.environ[cfg["auth_env"]]
                try:
                    from mcp.client.streamable_http import streamable_http_client, create_mcp_http_client
                    async with create_mcp_http_client(headers=headers) as client:
                        async with streamable_http_client(cfg["url"], http_client=client) as s:
                            yield s[0], s[1]
                except ImportError:
                    from mcp.client.streamable_http import streamablehttp_client
                    async with streamablehttp_client(cfg["url"], headers=headers) as s:
                        yield s[0], s[1]
            else:
                from mcp import StdioServerParameters
                from mcp.client.stdio import stdio_client
                params = StdioServerParameters(command=cfg["command"], args=list(cfg.get("args", [])),
                                               env=dict(os.environ))
                async with stdio_client(params) as s:
                    yield s[0], s[1]

        try:
            async with transport() as (read, write):
                async with ClientSession(read, write) as session:
                    await session.initialize()
                    ready.set_result(None)
                    while True:
                        item = await q.get()
                        if item is None:
                            break
                        tool, args, fut = item
                        try:
                            fut.set_result(await session.call_tool(tool, args))
                        except Exception as e:  # noqa: BLE001 -- surfaced at the step
                            fut.set_exception(e)
        except Exception as e:  # noqa: BLE001
            if not ready.done():
                ready.set_exception(e)

    def close(self):
        async def stop():
            for q in self.queues.values():
                await q.put(None)
            for t in self.tasks:
                try:
                    await self.asyncio.wait_for(t, 10)
                except Exception:  # noqa: BLE001
                    pass
        try:
            self.asyncio.run_coroutine_threadsafe(stop(), self.loop).result(15)
        except Exception:  # noqa: BLE001
            pass


_POOL = []


def mcp_call(tool, args_json):
    server = next((s for s in MCP_SERVERS if tool.startswith(s + "__") and len(tool) > len(s) + 2), None)
    if server is None:
        raise StepError('no MCP tool named "%s" (no server prefix or bare-name match)' % tool)
    try:
        import mcp  # noqa: F401 -- only MCP steps need the package
    except ImportError:
        raise StepError('MCP step "%s" needs the mcp package: pip install mcp' % tool)
    if not _POOL:
        _POOL.append(_MCPPool())
    args = _parse(args_json, dict)
    try:
        r = _POOL[0].call(server, tool[len(server) + 2:], args if args is not None else {})
    except Exception as e:  # noqa: BLE001
        raise StepError("mcp[%s] %s: %s" % (server, type(e).__name__, e))
    raw = r.model_dump(mode="json", by_alias=True, exclude_none=True) if hasattr(r, "model_dump") else dict(r)
    text = "\n".join(c.get("text", "") for c in raw.get("content", []) if c.get("type") == "text")
    if text == "" and raw.get("isError"):
        raise StepError("tool reported error (no text content)")
    return text, json.dumps(raw)


# --------------------------------------------------------------- built-in tools
def builtin_call(tool, args_json):
    a = _parse(args_json, dict) or {}
    if tool == "read_file":
        with open(_str_arg(a, "path"), encoding="utf-8", errors="replace") as f:
            return f.read()
    if tool == "write_file":
        path, content = _str_arg(a, "path"), _str_arg(a, "content")
        if os.path.dirname(path):
            os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(content)
        return "wrote %d bytes to %s" % (len(content.encode("utf-8")), path)
    if tool == "shell_exec":
        # PasClaw's shell_exec: "cwd" resolves against the directory relative paths
        # do (here the current one), and one that does not exist is reported as
        # exit code 1 -- never a silent run in another directory.
        cwd = pas_trim(_str_arg(a, "cwd"))
        if cwd:
            cwd = os.path.abspath(cwd)
            if not os.path.isdir(cwd):
                return "shell_exec: cwd does not exist: %s\n[exit code 1]" % cwd
        r = subprocess.run(_str_arg(a, "command"), shell=True, capture_output=True, text=True, cwd=cwd or None)
        out = r.stdout + r.stderr
        if r.returncode != 0:
            out += "\n[exit code %d]" % r.returncode
        return out
    raise StepError('tool "%s" is not supported in the exported script' % tool)


def call_tool(tool, args_json):
    if tool in ("llm", "provider"):
        return llm_call(args_json)
    if "__" in tool:
        return mcp_call(tool, args_json)
    try:
        text = builtin_call(tool, args_json)
    except OSError as e:
        raise StepError("%s: %s" % (tool, e))
    return text, text_wrap(text)


# --------------------------------------------------------------- the run
def poll_until_done(aw, create_json, inputs, results, replicate=False):
    if not pas_trim(aw.get("tool", "")):
        raise StepError("await: no poll tool")
    elapsed = polls = 0
    interval, timeout = int(aw.get("interval_ms", 2000)), int(aw.get("timeout_ms", 300000))
    while True:
        args = resolve(aw.get("args", "{}"), inputs, results, create_json)
        try:
            if replicate and aw["tool"] == "replicate__get_predictions":
                ptext, pjson = replicate_get(args)
            else:
                ptext, pjson = call_tool(aw["tool"], args)
        except StepError as e:
            raise StepError("await: poll call failed: %s" % e)
        pjson = unwrap_result(pjson, ptext)
        status = eval_selector(pjson, aw.get("status_selector", "status"))
        if status is None:
            raise StepError('await: status selector "%s" did not resolve in poll result' % aw.get("status_selector"))
        if status in aw.get("success", ["succeeded"]):
            return ptext, pjson
        if status in aw.get("failure", ["failed", "canceled"]):
            raise StepError('await: terminal failure status "%s"' % status)
        polls += 1
        if interval > 0:
            elapsed += interval
        if timeout > 0 and elapsed >= timeout:
            raise StepError('await: timed out after %d ms (last status "%s")' % (elapsed, status))
        if polls >= 100000:
            raise StepError("await: exceeded max polls")
        if interval > 0:
            time.sleep(interval / 1000.0)


def run_workflow(spec, inputs):
    results = []
    try:
        order = topo_order(spec)
    except StepError as e:
        return False, results, str(e)
    nodes = {n["id"]: n for n in spec["nodes"]}
    for nid in order:
        node = nodes[nid]
        try:
            args = resolve(node["args"], inputs, results)
        except StepError as e:
            return False, results, 'node "%s": %s' % (nid, e)
        eff, aw = plan_node(node)
        sugar = pas_trim(node["tool"]).lower() == "replicate"
        r = {"node": nid, "tool": node["tool"], "ok": True, "text": "", "json": "", "error": ""}
        try:
            if sugar:
                text = js = replicate_create(args)
            else:
                text, js = call_tool(eff, args)
            r["text"], r["json"] = text, unwrap_result(js, text)
            if aw:
                r["text"], r["json"] = poll_until_done(aw, r["json"], inputs, results, sugar)
                if aw.get("output_selector"):
                    v = eval_selector(r["json"], aw["output_selector"])
                    if v is not None:
                        r["text"] = v
        except StepError as e:
            r["ok"], r["error"] = False, str(e)
        print("  %s %s (%s)" % ("ok  " if r["ok"] else "FAIL", nid, node["tool"]), file=sys.stderr)
        results.append(r)
        if not r["ok"]:
            return False, results, 'node "%s" (%s) failed: %s' % (nid, node["tool"], r["error"])
    return True, results, ""


def resolve_outputs(spec, inputs, results):
    out, errs = {}, []
    for o in spec["outputs"]:
        if not pas_trim(o["name"]):
            continue
        try:
            out[o["name"]] = resolve_one(o["value"], inputs, results)
        except StepError as e:
            out[o["name"]] = ""
            errs.append("%s: %s" % (o["name"], e))
    return out, errs


def run_repeated(spec, inputs):
    loop = spec.get("loop")
    if not loop:
        return run_workflow(spec, inputs)
    max_it = min(max(int(loop.get("max", 1)), 1), 100)
    cur = dict(inputs)
    for it in range(1, max_it + 1):
        ok, results, err = run_workflow(spec, cur)
        if not ok:
            return ok, results, err
        out, _ = resolve_outputs(spec, cur, results)
        until = loop.get("until", "")
        if until:
            try:
                v = resolve_one(until, cur, results)
            except StepError:
                v = ""
            if pas_trim(v).lower() in ("true", "yes", "done", "1", "stop", "complete"):
                return ok, results, err
        if it == max_it:
            return ok, results, err
        for fb in loop.get("feedback", []):
            if fb.get("input") and fb.get("output") in out:
                cur[fb["input"]] = out[fb["output"]]
    return False, [], "loop did not run"


def write_outputs(spec, outputs, base):
    stamp = time.strftime("%Y%m%dT%H%M%S")
    os.makedirs(base, exist_ok=True)
    run_dir, n = os.path.join(base, stamp), 1
    while True:
        try:
            os.mkdir(run_dir)
            break
        except FileExistsError:
            n += 1
            run_dir = os.path.join(base, "%s-%d" % (stamp, n))
    with open(os.path.join(run_dir, "output.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(outputs, ensure_ascii=False) + "\n")
    for name, val in outputs.items():
        if not isinstance(val, str) or val == "":
            continue
        ext = ".md" if val.startswith("# ") or "\n#" in val else ".txt"
        safe = "".join(c if c.isascii() and (c.isalnum() or c in "-_") else "_" for c in name) or "output"
        with open(os.path.join(run_dir, safe + ext), "w", encoding="utf-8") as f:
            f.write(val + "\n")
    return run_dir


def main(argv=None):
    spec = WORKFLOW
    lines = ["inputs:"] + ["  %s: %s%s" % (i["name"], i["type"], " (required)" if i["required"] else "")
                           for i in spec["inputs"]] if spec["inputs"] else ["(no inputs)"]
    ap = argparse.ArgumentParser(
        description="%s -- %s" % (spec["name"], spec["description"] or "a PasClaw workflow"),
        epilog="\n".join(lines), formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", action="append", default=[], metavar="NAME=VALUE",
                    help="a workflow input (repeatable)")
    ap.add_argument("--json", action="store_true", help="print the outputs as JSON")
    ap.add_argument("--out-dir", default=None,
                    help="where a run's declared outputs are written (default: %s)"
                         % (spec["output_dir"] or "workflows/" + spec["id"]))
    ap.add_argument("--no-files", action="store_true", help="do not write the outputs to files")
    a = ap.parse_args(argv)
    inputs = {}
    for kv in a.input:
        if "=" not in kv:
            ap.error("--input wants NAME=VALUE, got %r" % kv)
        k, v = kv.split("=", 1)
        inputs[k] = v
    missing = [i["name"] for i in spec["inputs"] if i["required"] and i["name"] not in inputs]
    if missing:
        ap.error("missing required input(s): " + ", ".join(missing))
    try:
        ok, results, err = run_repeated(spec, inputs)
    finally:
        if _POOL:
            _POOL[0].close()
    if not ok:
        print("error: " + err, file=sys.stderr)
        return 1
    if spec["outputs"]:
        output, errs = resolve_outputs(spec, inputs, results)
        for e in errs:
            print("output error: " + e, file=sys.stderr)
        if not a.no_files:
            d = write_outputs(spec, output, a.out_dir or spec["output_dir"] or "workflows/" + spec["id"])
            print("outputs written to " + d, file=sys.stderr)
    else:
        last = next((r["text"] for r in reversed(results) if r["text"]), "")
        output = {"output": last}
    if a.json:
        print(json.dumps(output, ensure_ascii=False))
    elif len(output) == 1:
        print(next(iter(output.values())))
    else:
        for k, v in output.items():
            print("%s: %s" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
