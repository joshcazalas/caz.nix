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

Every pull request and manual dispatch runs two independent jobs in parallel:

- **Lint and scan** enforces Nix formatting, runs Deadnix, Statix, ShellCheck,
  and Actionlint, then scans every reachable Git commit with Gitleaks and
  redacts any match.
- **Build** evaluates every declared flake output and builds both the NixOS
  homeserver closure and the WSL Home Manager activation.

They share no work, so running them apart costs nothing and reports a
formatting or ShellCheck mistake in well under a minute instead of behind a
four-minute closure build.

A third job, `Validate`, passes only when both of those succeeded. It exists to
carry the exact name `main` requires as a status check: the split therefore
needs no branch-protection change, and a lint failure still blocks a merge just
as it did when everything lived in one job.

Each bootstrapped checkout also uses the tracked `.githooks/pre-commit` hook to
scan staged changes with the same pinned Gitleaks package. This is the fast
local guardrail; CI's full-history scan remains the authoritative backstop.

GitHub Actions are pinned to full commit hashes. Dependabot updates those pins
in a dedicated weekly PR. The expensive build and release jobs use GitHub's
repository-local Actions cache to retain the Nix output for the exact Auxide
commit recorded in `flake.lock`. The cache key includes both that commit and
the installed Nix version, so ordinary configuration changes reuse Auxide
without weakening the lock file's immutable build identity. A local composite
action owns this policy so CI and release restore the same cache on their
respective build runners without duplicating its implementation.

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
Before installing Nix, the build job conservatively reserves the runner's
otherwise-unused `/mnt` space as a compressed `/nix` volume. It does not purge
preinstalled runner tools, and Nix build temporaries are kept on that larger
volume as well. The lint job reserves nothing, because it only realises the
small development shell.

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

The release job builds every declared output but deliberately does not repeat
linting or the full-history secret scan. `main` requires the `Validate` check
in strict mode, so a branch must be current with `main` before it can merge and
CI runs against the merge result: the tree that lands is the exact tree that was
already linted and scanned. Administrators are held to that rule and force
pushes are blocked, so no commit reaches `main` around it. **Relaxing strict
mode, admin enforcement, or force-push protection means restoring those steps
in `release.yml`.**

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

1. require the `CI / Validate` check before merging to `main`, in strict mode
   and with administrators included — the release job trusts this instead of
   linting and scanning `main` a second time;
2. require pull requests and block force pushes to `main`;
3. enable GitHub secret scanning and push protection;
4. enable immutable releases before the first public release;
5. enable private vulnerability reporting;
6. verify that the weekly Nix Dependabot job is active.

The history rewrite needed before publication is the one intentional exception
to blocking force pushes. Enable the protection only after that rewrite lands.
