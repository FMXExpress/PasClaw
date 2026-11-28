#!/usr/bin/env python3
"""Fixtures for check-pascal-shape.py: what each rule must flag, and what
it must leave alone. A checker that cries wolf gets switched off, so the
"leave alone" half matters as much as the other.

Usage: test-check-pascal-shape.py   (exit 0 when every case holds)
"""
import os
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECKER = os.path.join(HERE, 'check-pascal-shape.py')

# name -> (source, the lines that must be flagged and no others)
CASES = {
    # Rule 4: FPC-only routines outside an {$IFDEF FPC} branch.
    'guards.pas': ('''unit guards;
interface
implementation
procedure A;
begin
  {$IFDEF FPC}
  X := LocalTimeToUniversal(Now);
  {$ELSE}
  X := GetTickCount64;
  {$ENDIF}
  {$IFDEF FPC}Y := GetTickCount64;{$ELSE}Y := 0;{$ENDIF}
  {$IFNDEF FPC}
  Z := UniversalTimeToLocal(Now);
  {$ENDIF}
  {$IFDEF MSWINDOWS}
  W := LocalTimeToUniversal(Now);
  {$ENDIF}
  { LocalTimeToUniversal in a comment is fine }
  S := 'GetTickCount64 in a string is fine';
  {$IFDEF FPC}{$IFDEF UNIX}
  V := GetTickCount64;
  {$ENDIF}{$ENDIF}
  Q := LocalTimeToUniversal(Now);
end;
end.
''', {9, 13, 16, 23}),
    # Rule 4: FPC-only integer types, any case, outside a guard.
    'types.pas': ('''unit types;
interface
implementation
procedure A;
var
  {$IFDEF FPC} I: SizeInt; {$ENDIF}
  J: SizeInt;
  K: sizeuint;
  { a SizeInt in a comment is fine }
  L: NativeInt;
begin
  {$IFNDEF FPC} P := PtrInt(nil); {$ENDIF}
end;
end.
''', {7, 8, 12}),
    # Rule 4 also runs on a file the other rules skip (onnxruntime.pas):
    # its declarations shape is not checked, its guards are.
    'localvector/onnxruntime.pas': ('''unit onnxruntime;
interface
implementation
procedure A;
var _out: Pointer; num_keys: Int64; i: SizeInt;
begin
end;
{$ifdef fpc}
procedure B; var z: SizeInt; begin end;
{$endif}
procedure C.D; begin end;
end.
''', {5}),
    # Rule 4, one line holding a call and a mention (Codex P2 on #649):
    # only the call counts, and only once.
    'mixed.pas': ('''unit mixed;
interface
implementation
procedure A;
begin
  WriteLn('LocalTimeToUniversal needs an FPC guard'); {$IFDEF FPC} X := LocalTimeToUniversal(Now); {$ENDIF}
  {$IFDEF FPC} Y := GetTickCount64; {$ENDIF} // GetTickCount64 in a trailing comment
  { GetTickCount64 in a brace comment } {$IFDEF FPC} Z := GetTickCount64; {$ENDIF}
  W := 'GetTickCount64'; V := GetTickCount64;
end;
end.
''', {9}),
    # Rule 4: a directive quoted in a string or inside a (* *) comment does
    # not guard anything; a string inside a real guard does not end it.
    'quoted.pas': ('''unit quoted;
interface
implementation
procedure A;
begin
  S := '{$IFDEF FPC}'; X := GetTickCount64; S := '{$ENDIF}';
  (* {$IFDEF FPC} *) Y := GetTickCount64; (* {$ENDIF} *)
  {$IFDEF FPC} S := 'it''s {$ENDIF} here'; Z := GetTickCount64; {$ENDIF}
end;
end.
''', {6, 7}),
    # Rule 3: Copy into a bare `array of` from another declaration (E2008).
    'copies.pas': ('''unit copies;
interface
type
  TR = record
    Lat: array of Int64;
  end;
  TNamed = array of Integer;
implementation
procedure A(const R: TR);
var
  L: array of Int64;
  T: TArray<Int64>;
  N, M: TNamed;
begin
  L := Copy(R.Lat);
  T := Copy(T);
  N := Copy(M);
  L := Copy(L);
end;
end.
''', {15}),
}


def main():
    failures = 0
    with tempfile.TemporaryDirectory() as d:
        paths = {}
        for name, (src, _) in CASES.items():
            paths[name] = os.path.join(d, name)
            os.makedirs(os.path.dirname(paths[name]), exist_ok=True)
            with open(paths[name], 'w') as f:
                f.write(src)
        out = subprocess.run([sys.executable, CHECKER] + list(paths.values()),
                             capture_output=True, text=True).stdout
        got = {name: set() for name in CASES}
        for line in out.splitlines():
            m = re.match(r'(.*?):(\d+): ', line)
            if m:
                got[os.path.relpath(m.group(1), d)].add(int(m.group(2)))
        for name, (_, want) in CASES.items():
            if got[name] != want:
                print(f'FAIL: {name}: flagged lines {sorted(got[name])}, want {sorted(want)}')
                failures += 1
        # One report per occurrence, not one per occurrence per line.
        if sum(1 for l in out.splitlines() if os.path.basename(l.split(':')[0]) == 'mixed.pas') != 1:
            print('FAIL: mixed.pas: the call on line 9 should be reported exactly once')
            failures += 1
    if failures:
        return 1
    print('check-pascal-shape fixtures: OK')
    return 0


if __name__ == '__main__':
    sys.exit(main())
