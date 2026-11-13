#!/bin/sh
# test-sweep-stale-units.sh [fpc]
#
# The case the sweep exists for, with fixed timestamps so it is the same on
# every run: a unit compiled from a source stamped 00:00:00.5, then the
# source rewritten at 00:00:00.9 -- the same second, after the make run
# started (its marker at 00:00:00.2). FPC alone sees the second it recorded
# and keeps the old code; after scripts/sweep-stale-units.sh the edit is
# built. And a source older than the marker keeps its unit.
set -e
FPC=${1:-fpc}
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
mkdir -p "$dir/src" "$dir/lib"
unit() {
  printf 'unit u;\n{$MODE DELPHI}\ninterface\nfunction V: string;\nimplementation\nfunction V: string; begin Result := %s; end;\nend.\n' "'$1'" > "$dir/src/u.pas"
  touch -d "$2" "$dir/src/u.pas"
}
build() {
  "$FPC" -Fu"$dir/src" -FU"$dir/lib" -FE"$dir" "$dir/p.pas" > "$dir/fpc.log" 2>&1 || { cat "$dir/fpc.log"; exit 1; }
  "$dir/p"
}
run_started() {   # a make run starting at $1: the sweep, its marker at $1
  sh "$here/sweep-stale-units.sh" "$dir/lib" "$dir/src"
  touch -d "$1" "$dir/lib/.sweep-mark"
}
printf 'program p;\nuses u;\nbegin WriteLn(V); end.\n' > "$dir/p.pas"

unit one 2020-01-01T00:00:00.5
run_started 2020-01-01T00:00:00.2
[ "$(build)" = one ] || { echo "FAIL: first build"; exit 1; }

# Rewritten in the same second, after the run started: FPC alone keeps the
# old code.
unit two 2020-01-01T00:00:00.9
alone=$(build)
[ "$alone" = one ] || echo "  note: this FPC rebuilt it alone ($alone) -- the sweep is then belt and braces"
[ "$alone" = one ] && echo "  ok: FPC alone keeps the old code after a same-second edit"

# The next run's sweep sees the source is newer than the last run's marker.
sh "$here/sweep-stale-units.sh" "$dir/lib" "$dir/src"
got=$(build)
[ "$got" = two ] || { echo "FAIL: after the sweep the build still says '$got', not 'two'"; exit 1; }
echo "  ok: after the sweep the edit is built"

# A source older than the marker keeps its unit.
sh "$here/sweep-stale-units.sh" "$dir/lib" "$dir/src"
[ -f "$dir/lib/u.ppu" ] || { echo "FAIL: an unchanged unit was deleted"; exit 1; }
echo "  ok: an unchanged unit is kept"
echo PASS
