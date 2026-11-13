#!/usr/bin/env node
/* The web pages' markdown renderer must finish on any text.

   renderMarkdown in webui.html and desktop.html looped forever on CRLF
   text: in a JS regex "." stops at "\r" (and U+2028/U+2029), so
   "## Title\r" failed the heading test while still stopping a paragraph,
   the paragraph branch took no line, and the loop never moved -- the
   browser tab froze ("this page is slowing down"). The Delphi build's
   sLineBreak is CRLF, and the Anthropic provider joins a reply's text
   blocks with it, so a reply whose block ended in a heading was enough.

   The function is loaded from the pages themselves and run inside vm with
   a timeout, so a regression fails here instead of hanging the build.
   Checked, for both pages:
     - every line terminator in a heading, a fence and plain text returns;
     - CRLF text renders exactly as its LF equivalent;
     - a line no block test accepts still advances (the progress guard).

   usage: node webui_markdown_test.js [repo-root] */
const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = process.argv[2] || path.resolve(__dirname, "../..");
let failures = 0;
const fail = msg => { console.log("FAIL: " + msg); failures++; };

function grab(js, name) {
  const i = js.indexOf("function " + name + "(");
  if (i < 0) return null;
  let depth = 0;
  for (let k = js.indexOf("{", i); k < js.length; k++) {
    if (js[k] === "{") depth++;
    else if (js[k] === "}" && --depth === 0) return js.slice(i, k + 1);
  }
  return null;
}

function loadRenderer(file) {
  const html = fs.readFileSync(file, "utf8");
  const scripts = [...html.matchAll(/<script(?: [^>]*)?>([\s\S]*?)<\/script>/g)].map(m => m[1]);
  const js = scripts.find(s => s.includes("function renderMarkdown("));
  if (!js) throw new Error("no renderMarkdown in " + file);
  const parts = ["escapeHtml", "renderMarkdown", "codeBlock", "mdCodeBlock"].map(n => grab(js, n)).filter(Boolean);
  const ctx = vm.createContext({});
  vm.runInContext(parts.join("\n"), ctx);
  /* Each call in the sandbox with a deadline: an infinite loop is a
     timeout error here, not a hung test. */
  return src => {
    ctx.__src = src;
    return vm.runInContext("renderMarkdown(__src)", ctx, { timeout: 2000 });
  };
}

const samples = {
  "heading":   "## Title\nbody text\nmore",
  "fence":     "```pascal\nbegin end.\n```\nafter",
  "lists":     "- a\n- b\n\n1. one\n2. two\n\n> quote",
  "mixed":     "intro\n## Section\npara\n```js\nlet x = 1;\n```\n---\n**bold** `code`",
};
const terminators = { "CRLF": "\r\n", "CR": "\r", "U+2028": "\u2028", "U+2029": "\u2029" };

for (const page of ["src/pkg/gateway/webui.html", "src/pkg/gateway/desktop.html"]) {
  const before = failures;
  let render;
  try { render = loadRenderer(path.join(root, page)); }
  catch (e) { fail(page + ": " + e.message); continue; }
  for (const [sname, lf] of Object.entries(samples)) {
    const want = render(lf);
    for (const [tname, t] of Object.entries(terminators)) {
      const text = lf.replace(/\n/g, t);
      let got;
      try { got = render(text); }
      catch (e) { fail(`${page}: ${sname} with ${tname} line ends never finished (${e.message})`); continue; }
      if (got !== want) fail(`${page}: ${sname} with ${tname} renders differently from LF:\n  ${JSON.stringify(got).slice(0, 160)}\n  ${JSON.stringify(want).slice(0, 160)}`);
    }
  }
  /* A heading line whose text the heading test cannot take: the stop tests
     and the block tests disagree on it, and the loop must still move. */
  for (const odd of ["# a\u0085b", "#\u00a0x", "```\u000bjs\ncode\n```"]) {
    try { render(odd); }
    catch (e) { fail(`${page}: ${JSON.stringify(odd)} never finished (${e.message})`); }
  }
  if (failures === before)
    console.log(`  ok: ${page} finishes on every line ending and renders CRLF as LF`);
}

if (failures) { console.log(failures + " failure(s)"); process.exit(1); }
console.log("ok - web UI markdown renderer tests passed");
