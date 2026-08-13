# CI, dependency updates, and releases

This repository uses a review-gated update pipeline:

```text
weekly dependency PR -> CI builds real outputs -> human review and merge
                     -> dated release -> SBOMs, provenance, checksums
```

Nothing in GitHub Actions has credentials or network access to the homeserver.
The server independently polls releases, verifies and reproduces them, creates
local backups, activates them during its maintenance window, and rolls back an
unhealthy live generation. It does not reboot automatically. See
[`server-updates.md`](server-updates.md).

## Continuous integration

Every pull request and manual dispatch runs one `Validate` job. It:

1. enforces Nix formatting;
2. runs Deadnix, Statix, ShellCheck, and Actionlint;
3. scans every reachable Git commit with Gitleaks and redacts any match;
4. builds both the NixOS homeserver closure and WSL Home Manager activation.

Each bootstrapped checkout also uses the tracked `.githooks/pre-commit` hook to
scan staged changes with the same pinned Gitleaks package. This is the fast
local guardrail; CI's full-history scan remains the authoritative backstop.

GitHub Actions are pinned to full commit hashes. Dependabot updates those pins
in a dedicated weekly PR. Jobs use the runner-local Nix store but deliberately
do not export it through a persistent Actions cache: complete builds take only
about four minutes, while cache finalization proved capable of wedging an
otherwise successful job until its timeout.

The complete server closure exceeds the standard private runner's 14 GB disk.
Before installing Nix, CI conservatively reserves the runner's otherwise-unused
`/mnt` space as a compressed `/nix` volume. It does not purge preinstalled
runner tools, and Nix build temporaries are kept on that larger volume as well.

Run the same checks locally with:

```bash
nix develop --command ./scripts/check.sh
nix develop --command ./scripts/secret-scan.sh
nix flake check --print-build-logs
```

## Dependency updates

Dependabot groups all `flake.lock` inputs into one weekly PR and groups Actions
updates into a separate PR. Nix updates currently activate only after this
repository becomes public; GitHub Actions updates work while it is private.

The update PR is deliberately not auto-merged. A green build proves that Nix
can evaluate and build the declared closures, but it cannot prove that a major
service migration is operationally safe. Read release notes for stateful
services before merging.

Release-branch changes such as NixOS `26.05` to `26.11` remain explicit,
roughly semiannual maintenance. Dependabot updates lock revisions, not branch
names embedded in `flake.nix`.

## Release identity and contents

Every push to `main` creates one release named:

```text
caz.nix-YYYY.MM.DD-g<12-character-commit>
```

The UTC date is pleasant to scan, and the commit suffix makes the tag unique
and traceable if several changes land on one day. A release contains:

- a manifest linking the commit to exact store paths and derivations;
- the evaluated flake metadata and the exact lock file;
- full closure metadata for the server and WSL profile;
- server SBOMs in CycloneDX and SPDX JSON, plus a readable CSV inventory;
- Nix-derived SLSA provenance for the server closure;
- SHA-256 checksums and downloadable release notes.

The publisher verifies `SHA256SUMS` before creating the draft release. Every
listed file, including `RELEASE_NOTES.md`, is uploaded and covered by GitHub's
keyless artifact attestation.

Nix store paths are content-addressed, immutable build identities. The release
records them but does not upload the entire server closure. GitHub also provides
the source snapshot for the tagged commit.

On a public repository, GitHub's artifact attestation action additionally signs
the release artifacts with keyless OIDC-backed provenance. That step is skipped
while the repository is private because it is not included in GitHub Free for
private repositories.

## Repository settings after publication

After the sanitized history becomes `main` and the repository becomes public:

1. require the `CI / Validate` check before merging to `main`;
2. require pull requests and block force pushes to `main`;
3. enable GitHub secret scanning and push protection;
4. enable immutable releases before the first public release;
5. enable private vulnerability reporting;
6. verify that the weekly Nix Dependabot job is active.

The history rewrite needed before publication is the one intentional exception
to blocking force pushes. Enable the protection only after that rewrite lands.
