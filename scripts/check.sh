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
  find bootstrap scripts .githooks -type f \( -name '*.sh' -o -perm -u+x \) -print0
)
shellcheck "${shell_files[@]}"

echo "==> Linting GitHub Actions workflows"
# GitHub supports `concurrency.queue`, but actionlint 1.7.12 does not know
# about it yet. Ignore only that specific schema false positive; all other
# workflow diagnostics remain fatal.
actionlint -ignore 'unexpected key "queue" for "concurrency" section'
