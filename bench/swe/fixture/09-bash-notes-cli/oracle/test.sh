#!/usr/bin/env bash
# Oracle for fixture 09-bash-notes-cli.
# Runs the agent's own test suite first (must pass), then an independent
# scripted scenario covering every subcommand. Captures stats on stderr.

set -u

if [ ! -x ./notes ]; then
  if [ -f ./notes ]; then
    echo "FAIL: ./notes exists but is not executable"
  else
    echo "FAIL: ./notes script missing at workspace root"
  fi
  exit 1
fi

# ----- (a) agent's own tests -----
if [ ! -x tests/test_notes.sh ]; then
  if [ -f tests/test_notes.sh ]; then
    echo "FAIL: tests/test_notes.sh exists but is not executable"
  else
    echo "FAIL: tests/test_notes.sh missing"
  fi
  exit 1
fi

if ! bash tests/test_notes.sh >/tmp/agent_test.out 2>&1; then
  echo "FAIL: agent's own tests/test_notes.sh did not pass"
  echo "--- last 20 lines of agent test output ---"
  tail -20 /tmp/agent_test.out
  exit 1
fi
echo "STATS agent_tests_passed=yes" >&2

# ----- (b) independent scripted scenario -----
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
export NOTES_DIR="$SANDBOX/.notes"

# help must mention every subcommand
help_out=$(./notes help 2>&1) || { echo "FAIL: ./notes help exit non-zero"; exit 1; }
for cmd in add list show rm search; do
  if ! echo "$help_out" | grep -qE "\b$cmd\b"; then
    echo "FAIL: ./notes help does not document subcommand '$cmd'"
    exit 1
  fi
done

# add 2 notes
id1=$(printf 'hello world\n' | ./notes add "first note") || { echo "FAIL: notes add first failed"; exit 1; }
id2=$(printf 'foo bar baz\n' | ./notes add "second SHOUT") || { echo "FAIL: notes add second failed"; exit 1; }
if ! [[ "$id1" =~ ^[0-9]+$ ]] || ! [[ "$id2" =~ ^[0-9]+$ ]]; then
  echo "FAIL: add did not print a numeric id (got '$id1', '$id2')"
  exit 1
fi
if [ "$id1" = "$id2" ]; then
  echo "FAIL: add returned the same id twice ($id1)"
  exit 1
fi

# list
list_out=$(./notes list 2>&1)
list_lines=$(printf '%s\n' "$list_out" | grep -cE '.')
if [ "$list_lines" != "2" ]; then
  echo "FAIL: list returned $list_lines line(s), expected 2"
  echo "got:"; echo "$list_out"
  exit 1
fi
if ! echo "$list_out" | grep -q "first note"; then
  echo "FAIL: list output missing 'first note'"
  exit 1
fi

# show
body=$(./notes show "$id1")
if ! echo "$body" | grep -q "hello world"; then
  echo "FAIL: show $id1 did not contain 'hello world'"
  echo "got: $body"
  exit 1
fi

# search (case-insensitive)
search_out=$(./notes search "FOO BAR")
if ! echo "$search_out" | grep -qE "^$id2\$"; then
  echo "FAIL: search 'FOO BAR' did not return id $id2"
  echo "got: $search_out"
  exit 1
fi

# search title (case-insensitive)
search_out2=$(./notes search "shout")
if ! echo "$search_out2" | grep -qE "^$id2\$"; then
  echo "FAIL: search 'shout' (title match, case-insensitive) did not return id $id2"
  echo "got: $search_out2"
  exit 1
fi

# rm
./notes rm "$id1" || { echo "FAIL: rm $id1 exit non-zero"; exit 1; }
after_rm=$(./notes list)
after_lines=$(printf '%s\n' "$after_rm" | grep -cE '.')
if [ "$after_lines" != "1" ]; then
  echo "FAIL: after rm, list returned $after_lines line(s), expected 1"
  echo "got:"; echo "$after_rm"
  exit 1
fi

# rm of missing id must fail
if ./notes rm 99999 >/dev/null 2>&1; then
  echo "FAIL: rm of missing id 99999 should exit non-zero but didn't"
  exit 1
fi

# show of missing id must fail
if ./notes show 99999 >/dev/null 2>&1; then
  echo "FAIL: show of missing id 99999 should exit non-zero but didn't"
  exit 1
fi

echo "STATS scripted_scenario=passed" >&2
echo "PASS"
exit 0
