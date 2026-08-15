#!/usr/bin/env bash
# Oracle for fixture 15-skill-distillation.
#
# Phase A: all 5 yml files parse cleanly (no double colons).
# Phase B: report (NOT enforce) whether a distilled skill draft was
#          produced under $PASCLAW_HOME/workspace/skills/.pending/ OR
#          a live install at $PASCLAW_HOME/workspace/skills/<name>/.
#
# We deliberately keep Phase B informational so a profile WITHOUT
# the distiller (lean-edit, stock) doesn't auto-fail the bench; the
# bench shows the artifact difference in the report instead.

set -u

# ----- (a) YAML parse for all 5 files -----
for f in src/a.yml src/b.yml src/c.yml src/d.yml src/e.yml; do
  if [ ! -f "$f" ]; then
    echo "FAIL: $f missing"
    exit 1
  fi
done

python3 - <<'PY' || exit 1
import yaml, sys
for f in ["src/a.yml","src/b.yml","src/c.yml","src/d.yml","src/e.yml"]:
    try:
        with open(f) as fh:
            obj = yaml.safe_load(fh)
    except yaml.YAMLError as e:
        print(f"FAIL: {f} did not parse: {e}")
        sys.exit(1)
    if not isinstance(obj, dict):
        print(f"FAIL: {f} top-level is not a mapping")
        sys.exit(1)
print("STATS yaml_files_parsed=5", file=sys.stderr)
PY

# Reject any leftover double colons in case the agent's "fix" was partial.
if grep -q '::' src/*.yml; then
  echo "FAIL: at least one src/*.yml still contains a '::' typo"
  grep -n '::' src/*.yml | head
  exit 1
fi

# ----- (b) distiller artifact survey -----
# $PASCLAW_HOME is exposed by the harness via the env. If not set, peek at the
# parent dir of WORKSPACE (start_cell.sh creates pasclaw-home and workspace
# as sibling dirs under run-<id>/).
if [ -z "${PASCLAW_HOME:-}" ]; then
  PASCLAW_HOME="$(dirname "${WORKSPACE:-$PWD}")/pasclaw-home"
fi

if [ -d "$PASCLAW_HOME/workspace/skills" ]; then
  echo "STATS skills_dir_present=yes" >&2
  pending_count=$(find "$PASCLAW_HOME/workspace/skills/.pending" -name 'SKILL.md' 2>/dev/null | wc -l)
  echo "STATS pending_drafts=$pending_count" >&2
  live=$(find "$PASCLAW_HOME/workspace/skills" -maxdepth 2 -name 'SKILL.md' \
    -not -path '*/.pending/*' 2>/dev/null | wc -l)
  echo "STATS live_skills=$live" >&2

  # If anything got staged, dump the first 8 lines of the body to the stats
  # for inspection. Distiller wrote it, so the bench result captures what
  # the model decided to call the skill.
  if [ "$pending_count" -gt 0 ]; then
    first=$(find "$PASCLAW_HOME/workspace/skills/.pending" -name 'SKILL.md' | head -1)
    echo "STATS first_pending=\"$first\"" >&2
    head -8 "$first" | sed 's/^/STATS first_pending_head: /' >&2
  fi
  if [ "$live" -gt 0 ]; then
    first=$(find "$PASCLAW_HOME/workspace/skills" -maxdepth 2 -name 'SKILL.md' \
      -not -path '*/.pending/*' | head -1)
    echo "STATS first_live=\"$first\"" >&2
    head -8 "$first" | sed 's/^/STATS first_live_head: /' >&2
  fi
else
  echo "STATS skills_dir_present=no" >&2
fi

echo "PASS"
exit 0
