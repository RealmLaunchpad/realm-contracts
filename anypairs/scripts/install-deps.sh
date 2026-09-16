#!/usr/bin/env bash
# Materialise lib/ at the exact commits pinned in dependencies.lock.
#
# Idempotent: re-running fetches nothing if every checkout already matches. Works whether or not this tree is itself a
# git repository, which is the reason it exists rather than `git submodule update --init` alone (see the note at the
# bottom). Run from the repository root:
#
#     bash scripts/install-deps.sh
#
# Then `forge build` and `forge test` work against exactly the tree every reported result was measured on.
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p lib

# name|url|ref  — ref is always an exact commit hash (see dependencies.lock).
DEPS=(
  "v4-core|https://github.com/Uniswap/v4-core|d153b048868a60c2403a3ef5b2301bb247884d46"
  "openzeppelin-contracts|https://github.com/OpenZeppelin/openzeppelin-contracts|cab19933c33c2ad1d4c7a84864a3601dddfd16f3"
  "uniswap-hooks|https://github.com/OpenZeppelin/uniswap-hooks|2ae32be4906d300fc49b4384842ef6bc3e902d73"
  "forge-std|https://github.com/foundry-rs/forge-std|bf647bd6046f2f7da30d0c2bf435e5c76a780c1b"
)

for entry in "${DEPS[@]}"; do
  IFS='|' read -r name url ref <<<"$entry"
  dir="lib/$name"

  if [ -d "$dir/.git" ]; then
    have="$(git -C "$dir" rev-parse HEAD)"
    want="$(git -C "$dir" rev-parse "$ref^{commit}" 2>/dev/null || echo "")"
    if [ -n "$want" ] && [ "$have" = "$want" ]; then
      echo "ok       $name  $have"
      continue
    fi
    echo "updating $name -> $ref"
    git -C "$dir" fetch --quiet origin "$ref" 2>/dev/null || git -C "$dir" fetch --quiet --tags origin
  else
    if [ -e "$dir" ]; then
      echo "ERROR: $dir exists but is not a git checkout." >&2
      echo "       Move it aside and re-run; this script will not overwrite an unpinned copy." >&2
      exit 1
    fi
    echo "cloning  $name"
    git clone --quiet "$url" "$dir"
  fi

  git -C "$dir" checkout --quiet --detach "$ref"
  echo "pinned   $name  $(git -C "$dir" rev-parse HEAD)"
done

cat <<'EOF'

All dependencies pinned. Verify with:
    forge build
    forge test --threads 1

Expected at the audit-round-12 tree: 79 suites, 459 tests, 0 failed.
If the build fails with "Variable ... is too deep in the stack", a dependency has drifted from the pinned commit --
check `git -C lib/<name> rev-parse HEAD` against dependencies.lock before changing any source.
EOF

# ── WHY NOT GIT SUBMODULES ALONE ──
# `.gitmodules` records a URL and a branch; it does NOT record the commit. A submodule's pinned commit lives in the
# superproject's tree object, so it only pins once this repository is itself a git repository AND the submodule commit
# has been committed. This tree is currently not a git repository at all, so a .gitmodules file alone would pin
# nothing. A .gitmodules is provided for the day it is initialised, but THIS script is the mechanism that actually
# pins today, and it keeps working afterwards.
