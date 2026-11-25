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

# An edit made WHILE a sweep runs -- after find has looked at that source,
# before the sweep is over -- must still be swept by the next run. A find
# shim runs the real find, then edits the source, so the race happens on
# every run rather than now and then. A marker stamped after the scan would
# be newer than that edit, and the stale unit would be kept for good.
mkdir -p "$dir/shim"
real_find=$(command -v find)
cat > "$dir/shim/find" <<SHIM
#!/bin/sh
"$real_find" "\$@"
rc=\$?
sleep 0.05
touch "$dir/src/u.pas"
exit \$rc
SHIM
chmod +x "$dir/shim/find"
PATH="$dir/shim:$PATH" sh "$here/sweep-stale-units.sh" "$dir/lib" "$dir/src"
[ -f "$dir/lib/u.ppu" ] || { echo "FAIL: the unit went before its source was edited"; exit 1; }
sh "$here/sweep-stale-units.sh" "$dir/lib" "$dir/src"
[ ! -f "$dir/lib/u.ppu" ] || { echo "FAIL: a source edited during a sweep was never swept: its unit is still there"; exit 1; }
echo "  ok: a source edited during a sweep is swept by the next one"

# A resource that changed (git brought a new webui.res; webui.html came with
# it, so make built nothing) sweeps the unit that {$R}s it, and only that
# one. The compiled units are stand-ins: only which files go matters here.
mkdir -p "$dir/rsrc" "$dir/rlib"
printf 'unit w;\ninterface\nimplementation\n{$R r.res}\nend.\n' > "$dir/rsrc/w.pas"
printf 'unit v;\ninterface\nimplementation\nend.\n' > "$dir/rsrc/v.pas"
touch -d 2020-01-01T00:00:00 "$dir/rsrc/w.pas" "$dir/rsrc/v.pas"
printf 'old' > "$dir/rsrc/r.res"; touch -d 2020-01-01T00:00:00 "$dir/rsrc/r.res"
touch "$dir/rlib/w.ppu" "$dir/rlib/w.o" "$dir/rlib/v.ppu" "$dir/rlib/v.o"
touch -d 2020-01-01T00:00:01 "$dir/rlib/.sweep-mark"
printf 'new' > "$dir/rsrc/r.res"; touch -d 2020-01-01T00:00:02 "$dir/rsrc/r.res"
sh "$here/sweep-stale-units.sh" "$dir/rlib" "$dir/rsrc"
[ ! -f "$dir/rlib/w.ppu" ] && [ ! -f "$dir/rlib/w.o" ] || { echo "FAIL: a changed .res left the unit that includes it compiled"; exit 1; }
[ -f "$dir/rlib/v.ppu" ] || { echo "FAIL: a changed .res swept a unit that does not include it"; exit 1; }
echo "  ok: a changed .res sweeps the unit that includes it, and only that one"

# The version comes from $PASCLAW_VERSION at compile time; FPC alone keeps
# the old one when only the variable changed. A sweep that is passed a new
# version sweeps the unit that reads it; the same version again keeps it.
mkdir -p "$dir/vsrc" "$dir/vlib"
printf 'unit vu;\n{$MODE DELPHI}\ninterface\nfunction V: string;\nimplementation\nfunction V: string; begin Result := {$I %%PASCLAW_VERSION%%}; end;\nend.\n' > "$dir/vsrc/vu.pas"
printf 'program vp;\nuses vu;\nbegin WriteLn(V); end.\n' > "$dir/vp.pas"
vbuild() {
  PASCLAW_VERSION=$1 "$FPC" -Fu"$dir/vsrc" -FU"$dir/vlib" -FE"$dir" "$dir/vp.pas" > "$dir/fpc.log" 2>&1 || { cat "$dir/fpc.log"; exit 1; }
  "$dir/vp"
}
PASCLAW_VERSION=v1 sh "$here/sweep-stale-units.sh" "$dir/vlib" "$dir/vsrc"
[ "$(vbuild v1)" = v1 ] || { echo "FAIL: first version build"; exit 1; }
[ "$(vbuild v2)" = v1 ] && echo "  ok: FPC alone keeps the old version string"
PASCLAW_VERSION=v2 sh "$here/sweep-stale-units.sh" "$dir/vlib" "$dir/vsrc"
got=$(vbuild v2)
[ "$got" = v2 ] || { echo "FAIL: after a sweep with a new version the build still says '$got'"; exit 1; }
PASCLAW_VERSION=v2 sh "$here/sweep-stale-units.sh" "$dir/vlib" "$dir/vsrc"
[ -f "$dir/vlib/vu.ppu" ] || { echo "FAIL: the same version again swept the unit"; exit 1; }
echo "  ok: a new version sweeps the unit that reads it; the same one keeps it"
echo PASS
