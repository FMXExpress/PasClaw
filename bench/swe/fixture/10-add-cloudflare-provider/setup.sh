#!/usr/bin/env bash
# Stage a snapshot of PasClaw at origin/main into the workspace, then
# pre-build the binary so the agent can iterate quickly without paying
# the full clean-build cost on its first attempt.
#
# The agent sees a clean tree (no .git, no build/ untracked).
set -euo pipefail

REPO=/home/user/PasClaw

# git archive gives us a clean snapshot -- no .git, no build artifacts,
# matches the public main branch state exactly.
(
  cd "$REPO"
  git archive --format=tar origin/main
) | tar -x -C "$WORKSPACE"

# git archive doesn't include vendor/Indy (it's a git submodule). Copy it
# from the host repo so the build doesn't have to clone Indy from the net.
if [ -d "$REPO/vendor/Indy" ]; then
  mkdir -p "$WORKSPACE/vendor"
  cp -r "$REPO/vendor/Indy" "$WORKSPACE/vendor/"
fi

# Pre-build so the agent's first `make` is incremental (the full build is
# ~10s and would distort wall-clock comparisons across cells). This is the
# state any developer would inherit from a checkout that built once.
(
  cd "$WORKSPACE"
  make >/dev/null 2>&1 || true
)

echo "setup complete -- $(find $WORKSPACE -name '*.pas' | wc -l) .pas files, build/pasclaw=$([ -f $WORKSPACE/build/pasclaw ] && echo yes || echo no)"
