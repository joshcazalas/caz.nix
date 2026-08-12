#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"

if ! git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "secret-scan.sh must run inside a Git worktree" >&2
  exit 1
fi

echo "==> Scanning every reachable commit with Gitleaks"
gitleaks git \
  --no-banner \
  --redact=100 \
  --log-opts='--all' \
  "${repo_root}"
