#!/usr/bin/env bash
# Oracle for fixture 12-vault-needs-library.
# Currently SKIPS unless a vault endpoint is reachable.

# Quick reachability check
if ! curl -fsS --max-time 5 https://pasclaw.dev/vault >/dev/null 2>&1; then
  echo "SKIP: vault endpoint https://pasclaw.dev/vault not reachable from sandbox"
  exit 0
fi

# Real oracle would compile + run the Pascal validator here. Stubbed.
echo "SKIP: oracle for 12-vault-needs-library not yet implemented; needs"
echo "      either a runnable Pascal validator template or a mock vault server."
exit 0
