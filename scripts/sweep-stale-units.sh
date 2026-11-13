#!/bin/sh
# sweep-stale-units.sh <unit-output-dir> <source-dir>...
#
# Deletes the compiled units (.ppu/.o) whose source changed since the last
# make run started, so FPC rebuilds them.
#
# FPC decides a unit is up to date by comparing the source's time with what
# its .ppu recorded, to the second. A source written in the same second its
# unit was compiled -- an edit straight after a build, a `git checkout`, a
# tool that edits and rebuilds in one go -- looks unchanged, and the build
# links the old code without a word. `find -newer` compares to the
# nanosecond (GNU and BSD find alike), so a marker touched before every
# compile catches what FPC's check misses.
#
# The Makefile runs this once per invocation, before any recipe: every
# source changed after the previous run's scan began is newer than the
# marker, and its unit goes. Deleting a unit FPC would have rebuilt anyway
# costs nothing; keeping one it would not have is the bug.
#
# The next marker is stamped BEFORE the scan and published after it. A
# source edited while find is walking -- after it has looked at that file --
# is then newer than the new marker and the next run sweeps it; stamped
# after the scan, the marker would be newer than that edit for good, and the
# stale unit kept forever (Codex, PR #636). It has this process's id in its
# name so two makes at once never publish each other's half-done marker; the
# later publish may move the marker back, which only sweeps more.
# Include files are not mapped to their units (src has one, vendored).

out=$1
shift
[ -n "$out" ] || exit 0
mkdir -p "$out" 2>/dev/null || exit 0
mark="$out/.sweep-mark"
next="$out/.sweep-mark.$$"
touch "$next" 2>/dev/null || exit 0

if [ -f "$mark" ]; then
  find "$@" -type f \( -name '*.pas' -o -name '*.pp' \) -newer "$mark" 2>/dev/null |
  while IFS= read -r src; do
    base=$(basename "$src")
    base=${base%.*}
    lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    for name in "$base" "$lower"; do
      rm -f "$out/$name.ppu" "$out/$name.o" "$out/$name.rsj" "$out/$name.rst"
    done
  done
fi
mv -f "$next" "$mark"
