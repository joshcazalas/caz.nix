# CI, dependency updates, and releases

This repository uses a review-gated update pipeline:

```text
dependency PR -> CI builds real outputs -> human review and merge
              -> dated release -> SBOMs, provenance, checksums
```

Nothing in GitHub Actions has credentials or network access to the homeserver.
The server independently polls releases, verifies and reproduces them, creates
local backups, activates them during its maintenance window, and rolls back an
unhealthy live generation. It does not reboot automatically. See
[`server-updates.md`](server-updates.md).

## Continuous integration

Every pull request first classifies its changed paths, then runs independent
validation jobs in parallel:

- **Evaluate, lint, and scan** enforces Nix formatting, runs Deadnix, Statix,
  ShellCheck, and Actionlint, scans every reachable Git commit with Gitleaks,
  and evaluates every flake output with `nix flake check --no-build`.
- **Build homeserver** realises the NixOS closure and is the only PR job that
  restores the pinned Auxide cache.
- **Build WSL home** realises the Home Manager activation and every `wsl-*`
  assertion without paying Auxide-cache overhead.
- **Integration** runs only affected checks across up to three parallel runners:
  device networking, gateways/network policy, and services/storage. Each runner
  builds just the checks selected for its shard, and a failure in one shard does
  not cancel the others.
- **Validate Windows configuration** parses and resolves the declarative
  Windows profiles when their inputs changed.
- **Validate ESPHome** installs the pinned build tool and validates the template
  when ESPHome inputs, its preparation script, or its validator changed.

`scripts/ci_checks.py` owns both path selection and flake check ownership;
`scripts/classify-ci-changes.sh` and `scripts/build-ci-check-group.sh` expose its
CLI. CI fails if a new check has not been classified or an integration shard
references a removed check. Every integration check belongs to exactly one
shard, so splitting the builds cannot silently turn a declared check into
evaluation-only coverage. Classifier regression tests run in the lint job.

`scripts/classify-ci-changes.sh` maps known source paths to the components they
can affect, including the test source files themselves. For example, HA's
preparation script selects homeserver checks and the Bluetooth VM test; the
HA private-input unit test selects the homeserver group that actually owns it.
Shared flake inputs/settings and CI policy changes fan out to every component,
manual dispatches run everything, and any unfamiliar path fails safe by
selecting every component. Multiple changed paths select the union of their
checks; deleted files and both sides of renames are included.
Documentation and operational-only changes still run linting, scanning, and
flake evaluation but avoid unrelated closure builds. A skipped component is
acceptable only when the classifier explicitly selected `false` for it.

VM container fixtures handle SIGTERM so shutdown and restart tests do not wait
for Docker to force-kill them. Production container shutdown grace periods and
the integration tests' deliberate failure-timeout assertions are unchanged.

The final `Validate` job passes only when classification and linting succeeded
and every component job either succeeded or was deliberately skipped. It
carries the exact name `main` requires as a status check, so component jobs may
change without weakening the merge gate.

Each bootstrapped checkout also uses the tracked `.githooks/pre-commit` hook to
scan staged changes with the same pinned Gitleaks package. This is the fast
local guardrail; CI's full-history scan remains the authoritative backstop.

GitHub Actions are pinned to full commit hashes. Dependabot updates those pins
in a dedicated weekly PR. The homeserver and release jobs use GitHub's
repository-local Actions cache to retain the Nix output for the exact Auxide
commit recorded in `flake.lock`. The WSL and integration jobs do not consume
Auxide and therefore do not pay its restore cost. The cache key includes the
evaluated package derivation, installed Nix version, runner OS, and
architecture. Transitive input updates and package overrides therefore rotate
the cache even if Auxide's source commit does not. Ordinary configuration
changes still reuse Auxide without weakening the lock file's immutable build
identity. A local composite action owns this policy so CI and release restore
the same cache on their respective build runners without duplicating its
implementation.

Pull requests may restore the default branch's cache but do not write caches:
their isolated entries cannot be promoted to `main` and would only consume the
free 10 GB repository allowance. A manual `main` CI run or the first release
after an Auxide update builds and seeds the new entry. Before saving, the cache
action garbage-collects the store to at most 2 GiB while an explicit GC root
retains Auxide's roughly 812 MiB runtime closure. The full server closure is not
retained. Consequently an Auxide update still compiles once in its PR and once
on `main`, but the much more common PR or release that leaves Auxide unchanged
restores the already-tested package.

This bounded whole-store cache replaces the earlier per-path Magic Nix Cache
experiment, whose post-job finalization once wedged until the job timeout. If
cache restore or save time erases the build-time improvement, remove the cache
rather than increasing GitHub's free storage limit.

The complete server closure exceeds the standard private runner's 14 GB disk.
Before installing Nix, each component build conservatively reserves the
runner's otherwise-unused `/mnt` space as a compressed `/nix` volume. It does
not purge preinstalled runner tools, and Nix build temporaries are kept on that
larger volume as well. The lint job reserves nothing, because it only realises
the small development shell and evaluates the remaining outputs without
building them.

Run the same checks locally with:

```bash
nix develop --command ./scripts/check.sh
nix develop --command ./scripts/secret-scan.sh
nix flake check --no-build
./scripts/build-ci-check-group.sh validate
./scripts/build-ci-check-group.sh homeserver
./scripts/build-ci-check-group.sh wsl
./scripts/build-ci-check-group.sh integration
nix flake check --print-build-logs
```

## Dependency updates

Dependabot checks root flake inputs every weekday at 09:17 America/Chicago.
Auxide gets its own `auxide` group/PR; the two upstream HA integrations share
`ha-integrations`, and other inputs stay in `flake-inputs`. The three-PR limit
allows each group an open update. All groups share the weekday schedule.
Actions updates remain in their separate weekly Monday PR, including the local
cache action; website npm dependencies also have a weekly Monday check.
The website package uses Nixpkgs `importNpmLock`, consuming integrity hashes
from the Dependabot-managed npm lockfile without a separate `npmDepsHash`.

Auxide updates follow the source commit consumed by `flake.lock`, independently
of the upstream GitHub release or container publication. With the current
branch-based input, its PR should change only the lockfile's Auxide node and any
necessary transitive nodes; review the diff for unrelated root-input changes.
The ordinary PR CI and human-review path applies to all Nix groups.

HA LightFX and Scene Presets are non-flake source inputs pinned to release
tags. Dependabot can update the tag in `flake.nix` and regenerate `flake.lock`;
Nix retains immutable commit and content-hash verification. Keep the original
input URL on a version tag: a bare commit in that URL is intentionally skipped
by Dependabot. Package versions and checks derive from the source manifest and
lockfile instead of maintaining independent version literals.

Home Assistant and Minecraft container image references are single-FROM
Dockerfiles under `containers/`. Dependabot's Docker ecosystem checks them each
weekday at 09:32 America/Chicago, with separate image PRs and a two-PR limit.
Nix reads those exact references for `oci-containers`; no additional image is
built and no Compose runtime is introduced. Changes to the manifests trigger
the homeserver CI group. See [`../containers/README.md`](../containers/README.md).

Minecraft's game release and Paper build follow the latest Paper package
metadata in the existing `nixpkgs-unstable` input. Nixpkgs updates therefore
advance both through the normal reviewed lockfile PR, without a separate
updater or Minecraft-only PR. This follows Nixpkgs publication cadence, not
every upstream Paper release immediately. Review the
[resolved versions and migration guidance](minecraft.md) before deployment;
an explicit `homelab.minecraft.version` override can hold a game release.

ESPHome's build tool is pinned in `esphome/requirements.txt`, checked by the
pip ecosystem each weekday at 10:32 America/Chicago. The private-project
preparation script copies that pin for actual builds. CI installs the pinned
tool and validates the generic template with synthetic inputs. Device
configuration and compiled firmware stay outside Git and the Nix store;
merging a tool update does not rebuild or flash deployed devices.

The update PR is deliberately not auto-merged. A green build proves that Nix
can evaluate and build the declared closures, but it cannot prove that a major
service migration is operationally safe. Read release notes for stateful
services before merging.

Dependabot also supports updating versioned branch refs such as NixOS `26.05`
to `26.11`. Review NixOS and Home Manager transitions together. This and tagged
input updates shipped in [upstream PR #14710](https://github.com/dependabot/dependabot-core/pull/14710);
the ecosystem documentation may still describe the older lockfile-only limit.

This is version-update coverage, not a vulnerability scan of every installed
package. It also does not cover every dependency:

- Factorio mod pins remain manual. Explicit Minecraft version/build overrides
  also require manual maintenance until removed.
- BlueMap and hTreecapitator use the Minecraft container's built-in Modrinth
  updater for stable releases compatible with the configured game version.
  Updates arrive on startup, outside Dependabot and PR review, without a
  minimum release-age delay. Nix rollback alone does not restore old plugins;
  see [BlueMap's update and rollback notes](bluemap.md#upgrading).
- The locally maintained HA integration is repository code, not an upstream
  package to bump. ESPHome device firmware still requires a rebuild and flash.
- Windows applications use their own update mechanisms, outside Dependabot.

Direct Nix fetch-expression updates are tracked in [#16297](https://github.com/dependabot/dependabot-core/issues/16297),
and arbitrary inline pins in [#16226](https://github.com/dependabot/dependabot-core/issues/16226).
Neither has a public delivery date as of November 2026.

## Release identity and contents

Authorized pushes to `main` trigger releases named:

```text
caz.nix-YYYY.MM.DD-g<12-character-commit>
```

Pushes that change only `docs/**`, README files, or `SECURITY.md` do not trigger
a release. A push that also changes other files still triggers one. Manual
dispatch remains available when a release is wanted without a code change.

The release job runs only on `main` when the initiating GitHub account ID is
`73436834` (`joshcazalas`) and the current triggering account matches the
original actor. This also gates manual dispatches and reruns; an unauthorized
run skips the entire job before checkout, builds, attestation, or publication.
Dependabot PRs remain eligible when the maintainer merges them. Dependabot
itself is not authorized to publish. Any future automated merge process needs
an explicit review of its triggering identity.

The gate uses GitHub's authenticated event identity, not commit author or
committer metadata. It is defense in depth: it does not protect against a
compromised maintainer account, unsafe changes the maintainer approves, or an
authorized change that removes the gate from this workflow.

Only one release runs at a time, with at most one pending run. A newer run
replaces the pending run without interrupting the active release. If A is
releasing while B and then C merge, C replaces B in the queue; C's `main`
commit includes B's changes, so they are still included in C's release.

The release job evaluates the flake with `nix flake check --no-build`, then the
artifact script builds the actual homeserver and WSL outputs needed for closure
metadata and SBOMs. Tests, including NixOS VM integration tests, run in PR CI
and are not repeated during release. Linting and the full-history secret scan
also remain in PR CI.

Branch protection requires `Validate` but deliberately does not require a PR
branch to be up to date before merging. The sole maintainer accepts that the
final merged combination may not have run the integration tests; release-time
evaluation and the actual configuration builds still validate the resulting
`main` commit before publication.

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

1. require the `CI / Validate` check before merging to `main`, with
   administrators included;
2. require pull requests and block force pushes to `main`;
3. enable GitHub secret scanning and push protection;
4. enable immutable releases before the first public release;
5. enable private vulnerability reporting;
6. verify that the weekday Nix and weekly Actions Dependabot jobs are active.

The history rewrite needed before publication is the one intentional exception
to blocking force pushes. Enable the protection only after that rewrite lands.
