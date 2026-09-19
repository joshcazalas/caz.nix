# Portfolio website

The website module serves the static build from `joshcazalas/website` through
Caddy. It does not clone or build the website on the server. The updater runs
TypeScript directly on Node 24; Node is not involved in serving requests.

The homeserver configuration uses **signed release mode** with automatic updates
and public HTTPS at `joshcazalas.com`, enabled for end-to-end verification. A
separate HTTP listener on port 8088 binds to loopback and
`settings.server.lanAddress`. The existing network policy permits ordinary LAN
clients, denies restricted clients unless explicitly allowed, and excludes
WireGuard and container interfaces from that listener.

## Prepare DNS

The homeserver's Cloudflare DDNS configuration manages the `joshcazalas.com`
apex alongside the existing `joshcaz.com` hostnames. The token needs
`Zone` / `DNS` / `Edit` for both zones; see [Dynamic DNS](remote-access.md#dynamic-dns).
Create an A record named `@` in the `joshcazalas.com` zone pointing to the home's
public IPv4 address. The updater preserves that record's existing proxy setting
and keeps its origin address current.

After deploying the configuration, check `cloudflare-ddns.service` and its
journal to confirm the apex is managed. DNS updates continue if public website
serving is later disabled.

For public serving, forward TCP ports 80 and 443 to the homeserver. Caddy handles
certificates and HTTP-to-HTTPS redirects; see its
[HTTPS requirements](https://caddyserver.com/docs/automatic-https#overview).
If the record is proxied, use Cloudflare's
[Full (strict) SSL/TLS mode](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
once Caddy has obtained the origin certificate.

## Verify the public deployment

After merging and deploying the server release, fetch the first signed website
release immediately instead of waiting for the hourly timer:

```bash
sudo systemctl start caz-website-updater.service
journalctl -u caz-website-updater.service -n 100 --no-pager
sudo -u caz-website caz-website-updater --config /etc/website-updater.json status
curl -fsS http://127.0.0.1:8088/release.json
```

The updater verifies the release signatures and inventories before activation.
It also checks the page, release identity, and every deployed file over the
local HTTP listener. Compare the reported commit with the website release.

From a device outside the home network, open `https://joshcazalas.com`, press
Play, and visit each project outpost. Check the same release identity at
`https://joshcazalas.com/release.json`. If HTTPS is unavailable, inspect
`journalctl -u caddy.service` and confirm the router forwards both ports to the
homeserver.

To return to LAN-only serving after verification, set
`homelab.website.public.enable = false` in a follow-up PR and deploy it. Keep
release mode and automatic updates enabled; the LAN listener will continue to
serve verified releases, and DDNS will keep the apex current.

## Import a private preview

For an unsigned local preview, first configure `mode = "preview"`,
`automaticUpdates = false`, and `public.enable = false`.

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
mode.

## Signed releases

The website workflow publishes immutable GitHub releases with seven payload
files and two Sigstore verification bundles. The homeserver currently uses:

```nix
homelab.website = {
  enable = true;
  mode = "release";
  automaticUpdates = true;
  public.enable = true;
};
```

Release and preview modes use different state directories. Switching modes does
not carry an unsigned preview into the public site. Until the first signed
release is installed, both release-mode listeners return 404.

Website releases deploy independently of NixOS releases. After merging a
website PR, wait for its Release workflow to publish successfully, then let the
hourly timer fetch it or start `caz-website-updater.service` manually. With no
`pinnedTag`, the updater selects the latest published stable release. Updating
the site's build dependencies does not require changing `caz.nix` as long as
the release format remains compatible with the updater.

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
