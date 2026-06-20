#!/usr/bin/env bash
# Setup hook for fixture 11-skill-discovery.
#   - Installs the csv-transform skill into PASCLAW_HOME/workspace/skills/.
#   - Drops data.csv into the agent workspace cwd.
set -euo pipefail

SKILL_DIR="$PASCLAW_HOME/workspace/skills/csv-transform"
mkdir -p "$SKILL_DIR"

cat > "$SKILL_DIR/SKILL.md" <<'SKILL'
---
name: csv-transform
description: Strict CSV transformation rules. The body IS the spec — every rule
  is binding. Output must match exactly to pass.
---

# csv-transform

Input file: `data.csv` at workspace root, no header. Three columns:

  col0: id (string, may be numeric)
  col1: value (integer)
  col2: label (string)

## Rules (apply in order)

1. **Skip** every row whose `col0` equals the literal string `x` (lowercase).
   These rows must NOT appear in the output.

2. For every kept row, produce an output row with these transformations:
   - `col0` — unchanged
   - `col1` — multiplied by 2 (integer math)
   - `col2` — converted to UPPERCASE (ASCII only)

3. Sort the output rows ascending by `col0` interpreted as an integer.

4. Write the result to `result.csv` at workspace root. **No header**. One row
   per line. Comma-separated. No trailing comma, no trailing blank line.

## Example

Input `data.csv`:

```
3,30,beta
1,10,alpha
x,99,SKIP_ME
2,20,gamma
4,40,delta
```

Expected `result.csv`:

```
1,20,ALPHA
2,40,GAMMA
3,60,BETA
4,80,DELTA
```
SKILL

# data.csv is the exact example above
cat > "$WORKSPACE/data.csv" <<'CSV'
3,30,beta
1,10,alpha
x,99,SKIP_ME
2,20,gamma
4,40,delta
CSV

echo "setup complete -- skill installed at $SKILL_DIR, data.csv staged"
