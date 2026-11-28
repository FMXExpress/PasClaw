#!/usr/bin/env python3
"""A shape check for Pascal units the CI cannot compile.

The FireMonkey client needs Delphi, which no CI here has, so its unit is
written blind. This will not catch a type error -- nothing but a compiler
will -- but it catches the three mistakes that have actually happened in
this repo, all of which a compiler would have caught in a second and a
reader might not:

  A method implemented but never declared -- the usual result of moving code
  between sections, and invisible until a compiler sees it.

  A statement stranded at the top level of the implementation section --
  what is left behind when a routine header is deleted or a block is moved
  and its `end;` is not. Inside a {$IFNDEF FPC} block (and this repo has a
  large one in PasClaw.TUI.pas) FPC never parses it, so `make test` is
  green and only dcc64 ever sees the error. That has shipped to main
  before. The rule is narrow on purpose: after a line that is exactly
  `end;` in column 0 -- the close of a routine -- the next line of code
  must start a new declaration in column 0, not an indented statement.

  A dynamic array copied into a variable of another array type: FPC
  accepts `A := Copy(B)` whenever the element types match; dcc64 needs A and
  B to be the SAME declared type, and every `array of T` written out in a
  declaration is a type of its own (E2008 Incompatible types). It shipped
  twice in one week -- a record field and a local, both `array of Int64`;
  a class field and a local, both `array of TDynamicToolsFn`. The rule is
  narrow: the target of `:= Copy(<other>)` is declared in this file as a
  bare `array of ...` (its nearest declaration above the line), and the
  source is a different variable. Declare a named type, or TArray<T>,
  for both.

  An FPC-only routine or type outside an {$IFDEF FPC} branch: FPC's RTL has
  LocalTimeToUniversal, UniversalTimeToLocal and GetTickCount64, and the
  integer types SizeInt, SizeUInt, PtrInt, PtrUInt, ValSInt and ValUInt;
  dcc64's does not (E2003 Undeclared identifier). SizeInt reached dcc64 in
  onnxruntime.pas, put there for the 32-bit FPC builds; NativeInt is in
  both. LocalTimeToUniversal reached
  dcc64 twice (the run file, the decision-model bench record) and
  GetTickCount64 once (the relay). Use PasClaw.Utils' NowIsoUtc /
  IsoUtcInMinutes, or guard the call with {$IFDEF FPC} ... {$ELSE}
  TTimeZone.Local.ToUniversalTime ... {$ENDIF}. Test programs under
  src/tests/ are built by FPC only and are not checked. Only the {$...}
  directive form is read; the tree has no (*$...*) directives.

The cases each rule must flag, and must leave alone, are in
test-check-pascal-shape.py, which `make lint-pascal-shape` runs first.

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


def char_kinds(text):
    """One character per character of text: 'c' code, 's' string, 'B' the
    brace opening a { } comment and 'b' the rest of it, 'p' a (* *)
    comment, 'l' a // comment; newlines stay newlines. Same length and line
    structure as text, so a match in the raw text can be asked what it is
    -- strip_comments_and_strings shortens the text and cannot."""
    out = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '\n':
            out.append('\n'); i += 1
        elif c == "'":
            out.append('s'); i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        out.append('ss'); i += 2
                        continue
                    out.append('s'); i += 1
                    break
                out.append('\n' if text[i] == '\n' else 's'); i += 1
        elif c == '{':
            out.append('B'); i += 1
            while i < n and text[i] != '}':
                out.append('\n' if text[i] == '\n' else 'b'); i += 1
            if i < n:
                out.append('b'); i += 1
        elif c == '(' and i + 1 < n and text[i + 1] == '*':
            out.append('pp'); i += 2
            while i < n and not (text[i] == '*' and i + 1 < n and text[i + 1] == ')'):
                out.append('\n' if text[i] == '\n' else 'p'); i += 1
            if i < n:
                out.append('pp'[:min(2, n - i)]); i += 2
        elif c == '/' and i + 1 < n and text[i + 1] == '/':
            while i < n and text[i] != '\n':
                out.append('l'); i += 1
        else:
            out.append('c'); i += 1
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


def check(path, guards_only=False):
    raw = open(path, encoding='utf-8', errors='replace').read()
    problems = []

    code = strip_comments_and_strings(raw)

    # Rules 1-3 read a unit's declarations; a file on SKIP is one they cannot
    # follow, and gets rule 4 alone (guards_only).
    if not guards_only:
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

        # 2. A statement stranded at the top level of the implementation
        #    section. Comments and directives are already blanked by
        #    strip_comments_and_strings, so they neither trip the rule nor
        #    hide a line that should.
        lines = code.split('\n')
        start = None
        for i, line in enumerate(lines):
            if re.match(r'^implementation\b', line, re.I):
                start = i + 1
                break
        # No implementation section: a program's main block legitimately has
        # statements at the top level, so the rule does not apply there.
        after_end = 0
        for i in range(len(lines) if start is None else start, len(lines)):
            line = lines[i].rstrip()
            if not line.strip():
                continue
            if after_end and (line[0] in ' \t'):
                problems.append(
                    f'{path}:{i + 1}: statement stranded at the top level '
                    f'(indented code after a column-0 "end;") -- '
                    f'{line.strip()[:60]}')
            after_end = line == 'end;'

        # 3. `A := Copy(B)` with A declared as a bare `array of T`. Declarations
        #    are read from the comment-free text: `Name[, Name]: array of T;` on
        #    its own line (a local, a field). Parameters are open arrays, not
        #    this, and sit inside parentheses on a routine line, so they never
        #    match the line-anchored pattern.
        decls = []   # (line index, name, is_bare_array)
        for i, line in enumerate(lines):
            m = re.match(r'^\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)\s*:\s*(.+?);\s*$', line)
            if not m or re.match(r'^\s*(procedure|function|property|const|var|out)\b', line, re.I):
                continue
            bare = bool(re.match(r'array\s+of\b', m.group(2).strip(), re.I))
            for name in re.split(r'\s*,\s*', m.group(1)):
                decls.append((i, name.lower(), bare))
        for i, line in enumerate(lines):
            m = re.search(r'\b([A-Za-z_]\w*)\s*:=\s*Copy\(\s*([A-Za-z_][\w.^]*)\s*\)', line)
            if not m:
                continue
            target, source = m.group(1).lower(), m.group(2).lower()
            if source.split('.')[-1] == target:
                continue
            above = [d for d in decls if d[1] == target and d[0] < i]
            if above and above[-1][2]:
                problems.append(
                    f'{path}:{i + 1}: {m.group(1)} is a bare `array of`, so dcc64 will not '
                    f'take Copy({m.group(2)}) of another declaration (E2008) -- declare '
                    f'both with one named type or TArray<T>')

    # 4. FPC-only RTL routines and types outside an {$IFDEF FPC} branch. Walked on
    #    the raw text with char_kinds alongside it, position for position:
    #    a hit counts only where the name is code (not in a comment or a
    #    string -- one line can hold both, Codex P2 on #649), and a
    #    directive only where its brace opens a comment (not quoted in a
    #    string or inside another comment). Each frame of the stack is
    #    'fpc' (FPC compiles this), 'dcc' (only dcc64 does) or 'any' (a
    #    condition this check does not read).
    if '/src/tests/' not in '/' + path.replace('\\', '/'):
        kinds = char_kinds(raw)
        raw_lines, kind_lines = raw.split('\n'), kinds.split('\n')
        stack = []
        directive = re.compile(r'\{\$(IFDEF|IFNDEF|IF|ELSEIF|ELSE|ENDIF|IFEND)\b([^}]*)\}', re.I)
        for i, rline in enumerate(raw_lines):
            kline = kind_lines[i] if i < len(kind_lines) else ''
            events = [(m.start(), 'd', m) for m in directive.finditer(rline)
                      if m.start() < len(kline) and kline[m.start()] == 'B'] + \
                     [(m.start(), 'h', m) for m in FPC_ONLY.finditer(rline)
                      if m.start() < len(kline) and kline[m.start()] == 'c']
            for _, kind, m in sorted(events, key=lambda e: e[0]):
                if kind == 'd':
                    word, arg = m.group(1).upper(), m.group(2).strip().upper()
                    if word == 'IFDEF':
                        stack.append('fpc' if arg == 'FPC' else 'any')
                    elif word == 'IFNDEF':
                        stack.append('dcc' if arg == 'FPC' else 'any')
                    elif word == 'IF':
                        stack.append('any')
                    elif word in ('ELSE', 'ELSEIF') and stack:
                        stack[-1] = {'fpc': 'dcc', 'dcc': 'fpc'}.get(stack[-1], 'any')
                    elif word in ('ENDIF', 'IFEND') and stack:
                        stack.pop()
                elif 'fpc' not in stack:
                    problems.append(
                        f'{path}:{i + 1}: {m.group(0)} is FPC-only (dcc64 E2003) -- use '
                        f'{FPC_ONLY_INSTEAD[m.group(0).lower()]}, or put it in an {{$IFDEF FPC}} branch')

    return problems


# Pascal is case-insensitive, and so is the match. What to write instead:
FPC_ONLY_INSTEAD = {
    'localtimetouniversal': 'NowIsoUtc / IsoUtcInMinutes',
    'universaltimetolocal': 'NowIsoUtc / IsoUtcInMinutes',
    'gettickcount64': 'DateUtils.MilliSecondsBetween',
    'sizeint': 'NativeInt', 'ptrint': 'NativeInt', 'valsint': 'NativeInt',
    'sizeuint': 'NativeUInt', 'ptruint': 'NativeUInt', 'valuint': 'NativeUInt',
}
FPC_ONLY = re.compile(r'\b(' + '|'.join(FPC_ONLY_INSTEAD) + r')\b', re.I)


# Vendored/generated headers whose declarations this scanner cannot follow.
# onnxruntime.pas is a machine-translated C++ header with class helpers whose
# declarations do not match the shape a hand-written unit uses; it compiles,
# and rewriting the scanner to understand it would be work spent on a file
# nobody edits. Rules 1-3 skip it; rule 4 does not -- dcc64 compiles it, and
# a SizeInt put in it for the 32-bit FPC builds reached dcc64 (E2003)
# because the whole file was skipped.
SKIP = ('localvector/onnxruntime.pas',)


def main(argv):
    bad = []
    for path in argv[1:]:
        skipped = any(path.replace('\\', '/').endswith(x) for x in SKIP)
        bad.extend(check(path, guards_only=skipped))
    for line in bad:
        print(line)
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
