#!/usr/bin/env bash
# Oracle for fixture 14-prior-session.
# answer.txt must contain exactly the lowercase word "cbor".

set -u

if [ ! -f answer.txt ]; then
  echo "FAIL: answer.txt missing"
  exit 1
fi

got=$(tr -d '[:space:]' < answer.txt | tr 'A-Z' 'a-z')
if [ "$got" = "cbor" ]; then
  echo "STATS answer=cbor" >&2
  echo "PASS"
  exit 0
fi

echo "FAIL: answer.txt content was '$got', expected 'cbor'"
exit 1
