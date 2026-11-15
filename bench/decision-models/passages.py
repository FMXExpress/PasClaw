"""Split PasClaw's user-facing docs into passages for the rerank set.

A passage is a run of paragraphs under one heading, about the size of a
memory or KB chunk (MIN..MAX characters). Its id is
`<doc>#<heading slug>/<n>`, stable as long as that section's text is.

Plan documents and the changelog are left out: they restate the other
pages, so a question would have several right answers.
"""
import glob
import os
import re
import subprocess

MIN, MAX = 250, 1200
SKIP = re.compile(r"(-plan\.md$|^plan\.md$|^changelog\.md$|^studio-|-design\.md$)")


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:48] or "top"


def doc_files(root, ref):
    """(name, text) for docs/*.md -- from the working tree, or, with ref,
    from that commit, so the corpus does not move when the docs do."""
    if not ref:
        for path in sorted(glob.glob(os.path.join(root, "docs", "*.md"))):
            yield os.path.basename(path), open(path, encoding="utf-8").read()
        return
    names = subprocess.run(["git", "-C", root, "ls-tree", "--name-only", ref, "docs/"],
                           capture_output=True, text=True, check=True).stdout.split()
    for n in sorted(names):
        if n.endswith(".md") and n.count("/") == 1:
            text = subprocess.run(["git", "-C", root, "show", "%s:%s" % (ref, n)],
                                  capture_output=True, check=True).stdout.decode("utf-8")
            yield os.path.basename(n), text


def passages(root, ref=None):
    out = []
    for name, text in doc_files(root, ref):
        if SKIP.search(name):
            continue
        rel = "docs/" + name
        heading, paras, in_code = "top", [], False
        lines = text.split("\n")

        def flush():
            buf, n = [], 0
            for p in paras:
                if buf and len("\n\n".join(buf + [p])) > MAX:
                    out.append(("%s#%s/%d" % (rel, slug(heading), n), heading, "\n\n".join(buf)))
                    buf, n = [], n + 1
                buf.append(p)
            if buf and len("\n\n".join(buf)) >= MIN // 2:
                out.append(("%s#%s/%d" % (rel, slug(heading), n), heading, "\n\n".join(buf)))

        cur = []
        for line in lines:
            if line.startswith("```"):
                in_code = not in_code
            if not in_code and re.match(r"^#{1,4} ", line):
                if cur:
                    paras.append("\n".join(cur).strip())
                    cur = []
                flush()
                heading, paras = line.lstrip("#").strip(), []
                continue
            if not in_code and not line.strip():
                if cur:
                    paras.append("\n".join(cur).strip())
                    cur = []
            else:
                cur.append(line)
        if cur:
            paras.append("\n".join(cur).strip())
        flush()
    # one passage per id, short fragments dropped
    seen, res = set(), []
    for pid, h, text in out:
        if pid in seen or len(text) < MIN // 2:
            continue
        seen.add(pid)
        res.append({"id": pid, "heading": h, "text": text})
    return res


if __name__ == "__main__":
    import sys
    ps = passages(sys.argv[1] if len(sys.argv) > 1 else ".")
    print(len(ps), "passages from", len({p["id"].split("#")[0] for p in ps}), "docs")
