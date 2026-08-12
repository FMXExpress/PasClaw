#!/usr/bin/env python3
"""Structural lint for the Delphi-only studio sources.

FPC cannot compile studio/ -- it needs FMX units that do not exist outside
RAD Studio -- so nothing in CI checks this code and every structural mistake
reaches a dcc64 build. This is not a compiler and does not pretend to be one:
it is a targeted check for the declaration-shape and comment errors that have
actually broken the Delphi build, all of which are visible from the token
stream without resolving a single identifier.

Checks
  1. brace-comment termination: braces do not nest, so a { } comment whose
     body still contains a '{' already ended at the example's own '}',
     leaving prose to be parsed as code.  (E2003 'buries'/'escapes',
     E2070 'where', E2038 '}')
  2. const/var section shape: an initialiser '=' on a bare name inside a var
     section, or a ':' declaration inside a const section -- the signature of
     a var block inserted into the middle of a const block.
     (E2029 ',' or ':' expected but '=' found)
(A begin/end balance check was tried and dropped: 'end' also closes records,
cases, classes and try-blocks, so the count is meaningless without a real
parser and produced only false positives.)

Exit code is the number of findings, so it drops into make/CI directly.
"""
import re
import sys

STR, BRACE, PAREN, SLASH, CODE = "str", "brace", "paren", "slash", "code"


def scan(src):
    """Yield (line, kind, text) for comments, and (line, CODE, text) per code line."""
    i, n, line = 0, len(src), 1
    code = {}                      # line -> code-only text
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            i += 1
            continue
        if c == "'":                                   # string literal
            i += 1
            while i < n and src[i] != "'":
                if src[i] == "\n":
                    line += 1
                i += 1
            i += 1
            continue
        if c == "(" and i + 1 < n and src[i + 1] == "*":
            start, j, body = line, i + 2, []
            while j + 1 < n and not (src[j] == "*" and src[j + 1] == ")"):
                if src[j] == "\n":
                    line += 1
                body.append(src[j])
                j += 1
            yield (start, PAREN, "".join(body))
            i = j + 2
            continue
        if c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            continue
        if c == "{":
            start, j, body = line, i + 1, []
            while j < n and src[j] != "}":
                if src[j] == "\n":
                    line += 1
                body.append(src[j])
                j += 1
            yield (start, BRACE, "".join(body))
            i = j + 1
            continue
        code.setdefault(line, []).append(c)
        i += 1
    for ln in sorted(code):
        yield (ln, CODE, "".join(code[ln]))


def main(path):
    src = open(path, encoding="utf-8", errors="replace").read()
    findings = []
    section = None          # 'const' | 'var' | None
    in_type = False

    for ln, kind, text in scan(src):
        if kind == BRACE:
            body = text.strip()
            # a compiler directive is not a comment
            if body.startswith("$"):
                continue
            # Braces do NOT nest in Delphi, so `body` above is the comment's
            # REAL extent: it stopped at the first '}'. Any '{' still inside
            # it therefore means the author wrote a brace pair in prose and
            # the comment already ended early, spilling the remainder into
            # the compiler as code. The old rule only recognised QUOTED JSON
            # ('{"', '":', '{{'), so a bare `{ok, tool, result}` sailed
            # through and broke the build (E2070 'where' / E2038 '}').
            # Checking for '{' at all is the general form of the same rule.
            if "{" in body:
                findings.append(
                    (ln, "brace-comment contains '{': it ended at the "
                         "example's own '}' and the rest parses as code "
                         "-- use a paren-star comment"))
            continue

        if kind == PAREN:
            # NB: read `text`, not `body` -- `body` is bound only in the
            # BRACE branch above, so using it here silently tests the
            # PREVIOUS brace comment and the rule never fires.
            paren_body = text.strip()
            # Paren-star comments do not nest either, so the same reasoning
            # applies: the body stopped at the first close, and an opener
            # still inside it means the comment already ended there. This is
            # not hypothetical -- the comment ADDED to explain the brace rule
            # named both delimiters literally and broke the build itself
            # (E2070 'form' / E2052 unterminated string). Describe the
            # delimiters in words inside a comment of the same kind.
            if "(*" in paren_body:
                findings.append(
                    (ln, "paren-star comment contains an inner '(*': it "
                         "ended at the first close and the rest parses as "
                         "code -- name the delimiters in words"))
            continue

        line = text.strip()
        low = line.lower()
        if not line:
            continue

        # track declaration sections at column 0 only (unit level)
        if re.match(r"^(const|var|type|implementation|interface)\b", low) and not text.startswith(" "):
            word = low.split()[0].rstrip(";")
            section = word if word in ("const", "var") else None
            in_type = word == "type"
            continue
        if re.match(r"^(function|procedure|constructor|destructor|begin)\b", low):
            section = None
            in_type = False

        # section-shape checks apply to indented member lines only
        if section and text.startswith("  ") and not in_type:
            member = re.match(r"^\s*([A-Za-z_]\w*)\s*(:|=)", text)
            if member:
                name, op = member.group(1), member.group(2)
                if section == "var" and op == "=" and ":" not in text.split("=")[0]:
                    findings.append(
                        (ln, f"'{name} = ...' inside a VAR section -- a const "
                             f"orphaned by a var block splitting the const block"))
                if section == "const" and op == ":" and "=" not in text:
                    findings.append(
                        (ln, f"'{name}: ...' inside a CONST section -- a var "
                             f"declaration in the wrong block"))

    for ln, msg in findings:
        where = f"{path}({ln})" if ln else path
        print(f"{where}: {msg}")
    print(f"{len(findings)} finding(s) in {path}")
    return len(findings)


if __name__ == "__main__":
    args = sys.argv[1:] or ["studio/MasterDetail.pas"]
    sys.exit(sum(main(a) for a in args))
