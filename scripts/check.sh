#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(git rev-parse --show-toplevel)"
cd "${repo_root}"

echo "==> Checking Nix formatting"
nix fmt -- --ci .

echo "==> Checking Nix for dead code"
deadnix --fail .

echo "==> Linting Nix"
statix check .

echo "==> Linting shell scripts"
mapfile -d '' shell_files < <(
  find bootstrap scripts -type f -name '*.sh' -print0
  find .githooks -type f -perm -u+x -print0
)
shellcheck "${shell_files[@]}"

echo "==> Testing the WSL-to-Windows launcher"
./scripts/test-windows-launcher.sh

echo "==> Linting GitHub Actions workflows"
# GitHub supports `concurrency.queue`, but actionlint 1.7.12 does not know
# about it yet. Ignore only that specific schema false positive; all other
# workflow diagnostics remain fatal.
actionlint -ignore 'unexpected key "queue" for "concurrency" section'
