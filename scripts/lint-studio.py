#!/usr/bin/env python3
"""Structural lint for the Delphi-only studio sources.

FPC cannot compile studio/ -- it needs FMX units that do not exist outside
RAD Studio -- so nothing in CI checks this code and every structural mistake
reaches a dcc64 build. This is not a compiler and does not pretend to be one:
it is a targeted check for the declaration-shape and comment errors that have
actually broken the Delphi build, all of which are visible from the token
stream without resolving a single identifier.

Checks
  1. early comment termination: neither comment form nests, so a comment
     that quotes its own delimiters ends at the inner close and the rest of
     the prose is parsed as code. Detected by the WRECKAGE -- a closing '}'
     or '*)' reaching code, which is the compiler's own E2038 -- and not by
     an opener inside a comment body, which is valid prose and flagging it
     blocks legitimate comments.  (E2003 'buries'/'escapes', E2070 'where',
     E2070 'form', E2038)
  1b. unterminated string: a quote still open at end of line cannot be valid
     Pascal. It is worth its own report, and it is also how the escaped
     prose above usually presents -- a contraction's apostrophe opens a
     "string" that swallows the intended terminator, hiding it from 1.
     (E2052 unterminated string)
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
            # Pascal string literals CANNOT span lines, so a quote still open
            # at the newline is itself the error (E2052) -- and it is the
            # other half of the early-comment wreckage: prose spilled out of
            # a comment usually carries a contraction, whose apostrophe opens
            # a "string" that swallows the intended terminator before the
            # stray-close check can ever see it. Stopping at the newline both
            # reports that and resyncs the scan onto the next line.
            start = line
            i += 1
            while i < n and src[i] != "'" and src[i] != "\n":
                i += 1
            if i >= n or src[i] == "\n":
                yield (start, STR, "unterminated")
                continue           # leave the newline for the branch above
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
        # Comments themselves prove nothing. An opener sitting inside a
        # comment body is NOT evidence of a problem: same-style comments do
        # not nest, so `(* mentions (* an opener *)` and `{ mentions { one }`
        # are both perfectly valid -- the single close terminates the
        # comment and the inner opener is ordinary prose. Earlier revisions
        # of this rule flagged exactly those and would have blocked valid
        # Studio comments (Codex P2 on PR #520).
        #
        # What IS evidence is the wreckage: when a comment ends before its
        # author meant it to, the trailing prose becomes code AND the
        # intended terminator arrives with nothing to close. So look for a
        # closing delimiter reaching CODE. The scanner consumes well-formed
        # comments whole and skips string literals, and valid Pascal has no
        # bare '}' or '*)' outside them -- which is precisely what dcc64
        # reports as E2038 "Illegal character in input file".
        if kind in (BRACE, PAREN):
            continue

        # The other half of the wreckage. A quote left open at end of line
        # cannot be valid Pascal, and when prose escapes a comment its
        # contraction ("doesn't") opens exactly this -- swallowing the
        # intended terminator so the stray-close check below never sees it
        # (Codex P2 on PR #521).
        if kind == STR:
            findings.append(
                (ln, "string literal not closed before end of line -- often "
                     "prose that escaped a comment that ended early"))
            continue

        line = text.strip()
        low = line.lower()
        if not line:
            continue

        stray = "}" if "}" in line else ("*)" if "*)" in line else "")
        if stray:
            findings.append(
                (ln, "stray '%s' in code: an earlier comment ended before it "
                     "was meant to and its remainder is being parsed as code"
                     % stray))

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
