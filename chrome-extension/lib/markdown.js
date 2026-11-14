/* PasClaw for Chrome -- a small, escaping Markdown renderer for assistant
   replies, plus the gateway's tool transcript lines:

     ⏺ read_file(README.md)
       ⎿ 312 lines, 12044 bytes

   which become collapsible tool cards. Everything is HTML-escaped first;
   the only markup produced is the markup written here, and links are
   limited to http(s) and mailto. */

const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));

function safeHref(url) {
  const u = String(url).trim();
  return /^(https?:|mailto:)/i.test(u) ? u : null;
}

function inline(src) {
  /* Pull code spans out first so nothing inside them is formatted. */
  const codes = [];
  let s = src.replace(/`([^`\n]+)`/g, (_, c) => {
    codes.push(c);
    return `\u0000${codes.length - 1}\u0000`;
  });
  s = esc(s);
  s = s.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, text, href) => {
    const h = safeHref(href.replace(/&amp;/g, "&"));
    return h ? `<a href="${esc(h)}" target="_blank" rel="noopener noreferrer">${text}</a>` : m;
  });
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)]+)/g, (m, pre, url) => `${pre}<a href="${url}" target="_blank" rel="noopener noreferrer">${url}</a>`);
  s = s.replace(/\*\*([^*\n]+)\*\*/g, "<strong>$1</strong>");
  s = s.replace(/(^|[^*\w])\*([^*\n]+)\*(?!\w)/g, "$1<em>$2</em>");
  s = s.replace(/~~([^~\n]+)~~/g, "<del>$1</del>");
  return s.replace(/\u0000(\d+)\u0000/g, (_, i) => `<code>${esc(codes[+i])}</code>`);
}

function table(lines) {
  const cells = (l) => l.replace(/^\s*\|/, "").replace(/\|\s*$/, "").split("|").map((c) => c.trim());
  const head = cells(lines[0]);
  const rows = lines.slice(2).map(cells);
  return "<table><thead><tr>" + head.map((c) => `<th>${inline(c)}</th>`).join("") + "</tr></thead><tbody>" +
    rows.map((r) => "<tr>" + r.map((c) => `<td>${inline(c)}</td>`).join("") + "</tr>").join("") + "</tbody></table>";
}

const TOOL_ICON = '<span class="t-ic"><svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M14.7 6.3a4 4 0 0 0-5.4 5.2L4 16.8V20h3.2l5.3-5.3a4 4 0 0 0 5.2-5.4l-2.6 2.6-2.4-.6-.6-2.4z"/></svg></span>';
const CHEVRON = '<svg class="t-chev" viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M9 6l6 6-6 6"/></svg>';
const TOOL_CALL = /^⏺\s?(.*)$/;
const TOOL_RESULT = /^\s*⎿\s?(.*)$/;

export function renderMarkdown(text) {
  const lines = String(text || "").replace(/\r\n?/g, "\n").split("\n");
  const out = [];
  let para = [];
  let list = null; // { tag, items }

  const flushPara = () => {
    if (para.length) out.push("<p>" + para.map(inline).join("<br>") + "</p>");
    para = [];
  };
  const flushList = () => {
    if (list) out.push(`<${list.tag}>` + list.items.map((i) => `<li>${inline(i)}</li>`).join("") + `</${list.tag}>`);
    list = null;
  };
  const flush = () => { flushPara(); flushList(); };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    const fence = line.match(/^\s*(```+|~~~+)\s*([\w+-]*)/);
    if (fence) {
      flush();
      const body = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++]);
      out.push(`<div class="code"><div class="code-head"><span>${esc(fence[2] || "text")}</span>` +
        `<button class="act copy" type="button">Copy</button></div><pre><code>${esc(body.join("\n"))}</code></pre></div>`);
      continue;
    }

    const call = line.match(TOOL_CALL);
    if (call) {
      flush();
      const results = [];
      while (i + 1 < lines.length && TOOL_RESULT.test(lines[i + 1])) {
        results.push(lines[++i].match(TOOL_RESULT)[1]);
        /* continuation lines of a multi-line result are indented */
        while (i + 1 < lines.length && /^\s{3,}\S/.test(lines[i + 1]) && !TOOL_RESULT.test(lines[i + 1])) results.push(lines[++i].trim());
      }
      const m = call[1].match(/^([\w.:\/-]+)\s*\(([\s\S]*)\)\s*$/);
      const name = m ? m[1] : call[1];
      const args = m ? m[2] : "";
      out.push(`<details class="tool"><summary>${TOOL_ICON}<span class="t-name">${esc(name)}</span>` +
        `<span class="t-args">${esc(args)}</span>` +
        (results[0] ? `<span class="t-res">${esc(results[0].slice(0, 80))}</span>` : "") +
        `${CHEVRON}</summary>` +
        (results.length ? `<pre>${esc(results.join("\n"))}</pre>` : "") + "</details>");
      continue;
    }

    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      flush();
      const rows = [line, lines[++i]];
      while (i + 1 < lines.length && /^\s*\|.*\|\s*$/.test(lines[i + 1])) rows.push(lines[++i]);
      out.push(table(rows));
      continue;
    }

    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      flush();
      const n = Math.min(h[1].length + 1, 4);
      out.push(`<h${n}>${inline(h[2])}</h${n}>`);
      continue;
    }

    if (/^\s*([-*_])(\s*\1){2,}\s*$/.test(line)) { flush(); out.push("<hr>"); continue; }

    const q = line.match(/^>\s?(.*)$/);
    if (q) {
      flush();
      const body = [q[1]];
      while (i + 1 < lines.length && /^>/.test(lines[i + 1])) body.push(lines[++i].replace(/^>\s?/, ""));
      out.push(`<blockquote>${body.map(inline).join("<br>")}</blockquote>`);
      continue;
    }

    const li = line.match(/^\s*([-*+]|\d+[.)])\s+(.*)$/);
    if (li) {
      flushPara();
      const tag = /\d/.test(li[1]) ? "ol" : "ul";
      if (!list || list.tag !== tag) { flushList(); list = { tag, items: [] }; }
      list.items.push(li[2]);
      continue;
    }

    if (!line.trim()) { flush(); continue; }
    if (list && /^\s{2,}\S/.test(line)) { list.items[list.items.length - 1] += " " + line.trim(); continue; }
    flushList();
    para.push(line);
  }
  flush();
  return out.join("");
}
