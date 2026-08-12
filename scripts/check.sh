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
mapfile -d '' shell_files < <(find bootstrap scripts -type f -name '*.sh' -print0)
shellcheck "${shell_files[@]}"

echo "==> Linting GitHub Actions workflows"
actionlint
