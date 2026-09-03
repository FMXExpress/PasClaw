#!/usr/bin/env python3
"""Flag TStrings file I/O that leaves the encoding to the RTL default.

Why this exists. `TStrings.SaveToFile(Path)` and `LoadFromFile(Path)`
without an encoding argument use TEncoding.Default -- the system ANSI
codepage on Windows -- under Delphi. Every non-ASCII character in a
transcript, an exported session, a fetched page, or a SCARS entry then
became '?' on disk, and BOM-less UTF-8 read back as mojibake. FPC writes
and reads the AnsiString bytes untouched, so the FPC test suite cannot
catch this: the code is behaviour-neutral on the only platform CI can
compile. This lint pins the source shape instead, the same way
check-pascal-shape.py pins Delphi-only units the CI cannot build.

The rule: every `.SaveToFile(` / `.LoadFromFile(` call in src/pkg and
src/cmd must either
  - pass an encoding (the argument text contains `TEncoding`), or
  - be replaced by PasClaw.Utils.WriteFileText / ReadFileText (which do
    not match the pattern at all), or
  - carry a `utf8-lint: allow` marker in a comment within the eight lines
    above it, for the cases where the default encoding is the RIGHT one --
    a .bat file cmd.exe reads in the console codepage, say.

Tests are excluded: they build fixtures and read them back on the same
platform, so the encoding cancels out. Third-party vendor trees under
src/pkg/vendor are excluded except where PasClaw already patches them.

Usage: check-utf8-file-io.py <file.pas> [...]   (exit 1 on any finding)
"""
import re
import sys

CALL = re.compile(r'\.(SaveToFile|LoadFromFile)\s*\(')
ALLOW = 'utf8-lint: allow'
LOOKBACK = 8


def argument_text(src, open_paren):
    """Text between the call's parentheses, across lines."""
    depth, i = 0, open_paren
    while i < len(src):
        c = src[i]
        if c == '(':
            depth += 1
        elif c == ')':
            depth -= 1
            if depth == 0:
                return src[open_paren + 1:i]
        i += 1
    return src[open_paren + 1:]


def check(path):
    findings = []
    src = open(path, encoding='utf-8', errors='replace').read()
    lines = src.split('\n')
    for m in CALL.finditer(src):
        line_no = src.count('\n', 0, m.start()) + 1
        args = argument_text(src, m.end() - 1)
        if 'TEncoding' in args:
            continue
        window = '\n'.join(lines[max(0, line_no - 1 - LOOKBACK):line_no])
        if ALLOW in window:
            continue
        findings.append((line_no, m.group(1), lines[line_no - 1].strip()))
    return findings


def main(argv):
    bad = 0
    for path in argv[1:]:
        for line_no, kind, text in check(path):
            bad += 1
            print(f"{path}:{line_no}: {kind} without an encoding -- "
                  f"use WriteFileText/ReadFileText or pass TEncoding.UTF8: {text}")
    if bad:
        print(f"utf8 file io: {bad} finding(s)")
        return 1
    print("utf8 file io: OK")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
