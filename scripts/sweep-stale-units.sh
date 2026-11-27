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

# Delete the compiled units of the sources named on stdin, one per line.
sweep_units() {
  while IFS= read -r src; do
    base=$(basename "$src")
    base=${base%.*}
    lower=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')
    for name in "$base" "$lower"; do
      rm -f "$out/$name.ppu" "$out/$name.o" "$out/$name.rsj" "$out/$name.rst"
    done
  done
}

if [ -f "$mark" ]; then
  # A resource (.res) is linked into the unit that names it in {$R ...}
  # when THAT unit compiles, and FPC does not track the .res at all. The
  # Makefile touches the web UI's unit when it builds webui.res itself, but
  # a webui.res that git brought in (a pull, a merge) arrives with
  # webui.html at the same time, nothing is rebuilt, and the binary shipped
  # the previous web UI. So a changed .res sweeps the units beside it that
  # name it.
  find "$@" -type f \( -name '*.pas' -o -name '*.pp' -o -name '*.res' \) -newer "$mark" 2>/dev/null |
  while IFS= read -r changed; do
    case "$changed" in
      *.res) grep -l -i -F "{\$R $(basename "$changed")}" \
               "$(dirname "$changed")"/*.pas "$(dirname "$changed")"/*.pp 2>/dev/null ;;
      *)     printf '%s\n' "$changed" ;;
    esac
  done | sweep_units
fi

# The version string is compiled in from the PASCLAW_VERSION environment
# variable ({$I %PASCLAW_VERSION%}), which FPC does not track either: after
# a commit, an incremental build kept the previous version, so `pasclaw
# version` named an old commit. When the Makefile passes a version that
# differs from the one the last sweep saw, the units that read it go.
if [ -n "${PASCLAW_VERSION+set}" ]; then
  vfile="$out/.sweep-version"
  if [ ! -f "$vfile" ] || [ "$(cat "$vfile")" != "$PASCLAW_VERSION" ]; then
    grep -rl -F '%PASCLAW_VERSION%' --include='*.pas' --include='*.pp' "$@" 2>/dev/null | sweep_units
    printf '%s' "$PASCLAW_VERSION" > "$vfile"
  fi
fi
mv -f "$next" "$mark"
