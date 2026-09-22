#!/usr/bin/env python3
"""Shape check for the PasClaw Browser's FMX units, which no CI can compile.

One rule, because it is the one that has actually bitten this repository
(desktop/uDesktopMain.pas, line ~5718, found only by a user noticing modern
CSS rendering badly):

    TWebBrowser.WindowsEngine must be assigned BEFORE TWebBrowser.Parent.

Assigning Parent creates the native handle, and the engine is chosen at
handle creation. Set afterwards, the property changes a field nothing reads
again: the control runs on the IE-era engine while the source says Edge.
The compiler cannot see this -- both orders are valid Pascal -- and a
reader will not, because the two lines look interchangeable.

Two findings, both fatal:

  ORDER    both assignments exist for one variable and Parent comes first
  MISSING  a TWebBrowser is created and given a Parent but WindowsEngine is
           never set at all -- which on Windows is the same bug with less
           evidence

Vacuously passes a file with no TWebBrowser. Comments are stripped
conservatively (line // and single-line { } / (* *)) before matching, so a
commented-out assignment does not count.

Usage: check-browser-shape.py browser-desktop/*.pas
"""
import re
import sys

ASSIGN = re.compile(r'\b([A-Za-z_]\w*)\s*\.\s*(WindowsEngine|Parent)\s*:=')
CREATE = re.compile(r'\b([A-Za-z_]\w*)\s*:=\s*TWebBrowser\s*\.\s*Create\s*\(')


def strip_comments(line):
    line = re.sub(r'\(\*.*?\*\)', '', line)
    line = re.sub(r'\{[^}]*\}', '', line)
    return line.split('//', 1)[0]


def check(path):
    problems = []
    engine_line = {}     # var -> first line WindowsEngine assigned
    parent_line = {}     # var -> first line Parent assigned
    created = {}         # var -> line of TWebBrowser.Create

    with open(path, encoding='utf-8', errors='replace') as f:
        for n, raw in enumerate(f, 1):
            line = strip_comments(raw)
            for m in CREATE.finditer(line):
                created.setdefault(m.group(1), n)
            for m in ASSIGN.finditer(line):
                var, prop = m.group(1), m.group(2)
                if prop == 'WindowsEngine':
                    engine_line.setdefault(var, n)
                else:
                    parent_line.setdefault(var, n)

    for var, pl in parent_line.items():
        el = engine_line.get(var)
        if el is None:
            if var in created:
                problems.append(
                    f"{path}:{pl}: MISSING  {var} is a TWebBrowser (created line "
                    f"{created[var]}) given a Parent but never a WindowsEngine -- "
                    f"on Windows that silently selects the legacy IE engine")
        elif el > pl:
            problems.append(
                f"{path}:{el}: ORDER    {var}.WindowsEngine is set on line {el} "
                f"but {var}.Parent on line {pl}; the engine is chosen when Parent "
                f"creates the handle, so this assignment does nothing")
    return problems


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    all_problems = []
    for path in argv[1:]:
        all_problems.extend(check(path))
    for p in all_problems:
        print('  ' + p)
    if all_problems:
        print(f"browser shape: {len(all_problems)} problem(s)")
        return 1
    print(f"browser shape: OK ({len(argv) - 1} file(s))")
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
