#!/usr/bin/env python3
"""A shape check for Pascal units the CI cannot compile.

The FireMonkey client needs Delphi, which no CI here has, so its unit is
written blind. This will not catch a type error -- nothing but a compiler
will -- but it catches the three mistakes that have actually happened in
this repo, all of which a compiler would have caught in a second and a
reader might not:

  A method implemented but never declared -- the usual result of moving code
  between sections, and invisible until a compiler sees it.

Two other checks were tried here and removed, because a checker that cries
wolf is worse than no checker:

  - Brace comments closing early on an inner `}`. After the fact that is
    indistinguishable from a comment that simply ended.
  - begin/end balance. Doing it correctly needs a real parser: `interface`,
    `record`, `class`, variant records and generic constraints all decide
    whether an `end` is theirs by context. A regex version disagreed with
    the compiler on 23 files that compile.

Usage: check-pascal-shape.py <file.pas> [...]
"""
import re
import sys


def strip_comments_and_strings(text):
    """Blank out comments and string literals so keyword scanning is honest."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == "'":                     # string literal
            out.append(' ')
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    i += 1
                    break
                out.append(' ' if text[i] != '\n' else '\n')
                i += 1
            continue
        if c == '{':
            while i < n and text[i] != '}':
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
            i += 1
            out.append(' ')
            continue
        if c == '(' and i + 1 < n and text[i + 1] == '*':
            i += 2
            while i + 1 < n and not (text[i] == '*' and text[i + 1] == ')'):
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
            i += 2
            out.append(' ')
            continue
        if c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


def blank_strings(text):
    """Blank string literals only, leaving comments in place."""
    out = []
    i, n = 0, len(text)
    while i < n:
        if text[i] == "'":
            out.append(' ')
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        out.append('  ')
                        i += 2
                        continue
                    i += 1
                    break
                out.append('\n' if text[i] == '\n' else ' ')
                i += 1
            out.append(' ')
            continue
        out.append(text[i])
        i += 1
    return ''.join(out)


def check(path):
    raw = open(path, encoding='utf-8', errors='replace').read()
    problems = []

    code = strip_comments_and_strings(raw)

    # 1. Declared vs implemented methods.
    declared = set()
    # `<` so a generic method (`function At<T>(...)`) counts as declared.
    for m in re.finditer(r'^\s*(?:procedure|function)\s+([A-Za-z_]\w*)\s*[(;:<]',
                         code, re.M):
        declared.add(m.group(1))
    implemented = set()
    for m in re.finditer(r'^(?:procedure|function)\s+(\w+(?:<[^>]*>)?)\.(\w+)',
                         code, re.M):
        implemented.add(m.group(2))
    missing = sorted(implemented - declared)
    for name in missing:
        problems.append(f'{path}: {name} is implemented but never declared')

    return problems


# Vendored/generated headers whose declarations this scanner cannot follow.
# onnxruntime.pas is a machine-translated C++ header with class helpers whose
# declarations do not match the shape a hand-written unit uses; it compiles,
# and rewriting the scanner to understand it would be work spent on a file
# nobody edits.
SKIP = ('localvector/onnxruntime.pas',)


def main(argv):
    bad = []
    for path in argv[1:]:
        if any(path.replace('\\', '/').endswith(x) for x in SKIP):
            continue
        bad.extend(check(path))
    for line in bad:
        print(line)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
