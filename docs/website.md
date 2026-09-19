# Portfolio website

The website module serves the static build from `joshcazalas/website` through
Caddy. It does not clone or build the website on the server. The updater runs
TypeScript directly on Node 24; Node is not involved in serving requests.

The homeserver configuration enables a **LAN-only preview** on port 8088. Public
HTTPS and automatic updates are disabled. Caddy binds this listener to loopback
and `settings.server.lanAddress`. The existing network policy permits ordinary
LAN clients, denies restricted clients unless explicitly allowed, and excludes
WireGuard and container interfaces. No new globally open port is added.

## Prepare DNS

The homeserver's Cloudflare DDNS configuration manages the `joshcazalas.com`
apex alongside the existing `joshcaz.com` hostnames. The token needs
`Zone` / `DNS` / `Edit` for both zones; see [Dynamic DNS](remote-access.md#dynamic-dns).
Create an A record named `@` in the `joshcazalas.com` zone pointing to the home's
public IPv4 address. The updater preserves that record's existing proxy setting
and keeps its origin address current.

After deploying the configuration, check `cloudflare-ddns.service` and its
journal to confirm the apex is managed. DNS preparation does not enable public
serving or open ports. Keep `homelab.website.public.enable = false` until the
signed release is running and you are ready to expose the site. At launch,
forward TCP ports 80 and 443 to Caddy and enable public serving separately.

## Import a private preview

After deploying the NixOS configuration through the normal server release
process, download a website release candidate from a successful main-branch
Release run on your workstation. Use a run built with release manifest schema 2. Confirm the
full source SHA against the run's commit, then copy the seven candidate files to
a temporary directory on the server readable by `caz-website`.

```bash
# Workstation: choose the run and candidate artifact by inspecting Actions.
gh run download RUN_ID --repo joshcazalas/website \
  --name CANDIDATE_ARTIFACT_NAME --dir candidate
# Copy candidate/ to the server using your normal SSH access.
```

On the server, replace the directory and SHA below with the reviewed values:

```bash
sudo -u caz-website caz-website-updater --config /etc/website-updater.json \
  preview /path/to/candidate --commit FULL_40_CHARACTER_SHA
sudo -u caz-website caz-website-updater --config /etc/website-updater.json status
```

Open `http://SERVER_LAN_ADDRESS:8088/`. Remove the temporary input directory after
acceptance; the updater has its own copy. Before the first import the listener
returns 404. Preview imports check identities, inventories, checksums, archive
paths, and HTTP responses, but **do not establish GitHub signing provenance**.
They are explicit operator-approved local imports and cannot be used in release
mode. Keep the repository private until its owner explicitly approves publication.

## Signed releases

After public-repository and release-publication approval, the website workflow
publishes immutable GitHub releases with seven payload files and two Sigstore
verification bundles. Enable the following in a reviewed configuration change:

```nix
homelab.website = {
  enable = true;
  mode = "release";
  automaticUpdates = true;
  # Enable separately when DNS and public serving are ready:
  # public.enable = true;
  # public.domain = "joshcazalas.com";
};
```

Release and preview modes use different state directories. Switching modes does
not carry an unsigned preview into the public site. Import a signed release and
check it through the LAN listener before enabling public HTTPS.

The hourly timer downloads from the public repository without a GitHub token.
It requires a published, stable, immutable release and resolves its tag to the
full source commit. Before extraction, it verifies every payload against the
attached provenance bundle with GitHub CLI: the exact repository, `release.yml`,
`refs/heads/main`, source and signer commit, GitHub OIDC issuer, and GitHub-hosted
runner. A separate CycloneDX attestation binds the runtime SBOM to the archive.
Verification bundles avoid authenticated attestation API downloads; GitHub and
Sigstore trust metadata still require network access. See the
[GitHub CLI verifier](https://cli.github.com/manual/gh_attestation_verify).

The manifest binds every deployed file to its digest and size. The extractor
rejects links, traversal, duplicate or unexpected members, and oversized output.
After staging, the updater atomically replaces the `current` symlink, then checks
the root page, release identity, and every deployed asset through Caddy. Failed
health checks restore and recheck the previous release, and quarantine the failed
tag. A journal recovers interrupted activations on the next deployment operation.
Download, integrity, and signature failures leave the accepted release untouched.

## Operations and rollback

```bash
# Release mode only: fetch and verify the latest release now.
sudo systemctl start caz-website-updater.service
journalctl -u caz-website-updater.service

# Both modes: inspect or restore the previous accepted version.
sudo -u caz-website caz-website-updater --config /etc/website-updater.json status
sudo -u caz-website caz-website-updater --config /etc/website-updater.json rollback

# Rollback holds automatic updates until explicitly resumed.
sudo -u caz-website caz-website-updater --config /etc/website-updater.json resume

# After diagnosing a failed activation, allow that exact tag to be tried again.
sudo -u caz-website caz-website-updater --config /etc/website-updater.json \
  retry website-YYYY.MM.DD-gCOMMITPREFIX
```

`retry` removes quarantine; it does not deploy. Run the update service or import
the preview again afterward. A rollback's hold is durable across restarts. A
release pin does not override a hold. To intentionally select an older signed
release, configure `homelab.website.pinnedTag` with its exact tag and resume if
needed; otherwise automatic downgrades are refused.

State lives under `/var/lib/caz-website-preview` or `/var/lib/caz-website-release`,
owned by `caz-website`. Caddy has read access through that group. Metadata,
journals, input archives, and signature bundles are outside the served tree.
Operations share a kernel lock, and concurrent invocations exit with status 75.
The timer runs unprivileged with filesystem and resource restrictions.

Scripts, sprites, and lazy audio use `/releases/FULL_COMMIT/` URLs. Old tabs keep
loading their own assets after a deployment or rollback. By default, cleanup
retains at least three accepted releases, current and previous releases, and all
releases installed within 30 days. A tab older than this retention window may
need a refresh. Configure `retain` and `minimumAgeDays` to change that tradeoff.
The root page is served with `Cache-Control: no-store`; versioned assets have an
immutable cache policy.

## Validation

`nix build .#website-updater` checks TypeScript, archive rejection, activation,
rollback, crash recovery, retention, signature policy, and the installed CLI.
`nix build .#checks.x86_64-linux.network-policy` runs Caddy and the updater in
NixOS VMs, verifies imports and rollback over HTTP, requests an old release's
audio after an update, and checks trusted/restricted LAN access. Fixtures contain
only synthetic files. Actual GitHub signing is exercised by the first explicitly
enabled public release; local tests do not claim to replace that check.
