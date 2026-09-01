# Verified automatic server deployments

The homeserver polls the public immutable releases from this repository during
a daily maintenance window and deploys a new release without a Git credential:

```text
public immutable release
  -> tokenless provenance and checksum verification
  -> exact commit build and signed store-path comparison
  -> current-generation health gate
  -> application-consistent local backups
  -> live NixOS activation
  -> service health wait and stabilization window
  -> accept release, or restore and health-check the previous generation
```

The scheduled run begins at 04:00 local time with a stable delay of up to two
hours. A missed run is performed after the next boot. The timer does nothing
when the latest release is already accepted.

## Trust and verification model

`caz-deploy-server-release` uses outbound HTTPS only. It does not accept inbound
connections and does not store a GitHub token, deploy key, or signing key.

For the latest release, it:

1. requires a published, non-prerelease, immutable `caz.nix-*` release;
2. requires the tag's commit suffix to match its full target commit;
3. downloads `manifest.json` and `SHA256SUMS` and verifies GitHub's recorded
   upload digests;
4. fetches the manifest's Sigstore bundle from GitHub's anonymous public
   attestation API;
5. verifies both files were produced on `main` by this repository's pinned
   release workflow on GitHub-hosted infrastructure;
6. verifies the manifest checksum and its internal release identity;
7. builds the homeserver from the exact 40-character commit;
8. requires the resulting Nix store path and derivation to equal the signed
   release manifest; and
9. only then begins the local deployment transaction.

The updater deliberately trusts changes merged to protected `main` and the
GitHub-hosted release workflow. Attestations prove origin and integrity; they do
not prove that a change is bug-free. Pull-request review and CI remain the
policy gate.

## Local deployment transaction

Before changing the NixOS profile, the updater requires the currently running
server to be healthy. It creates a normal Minecraft world backup, briefly
pauses the other mutable applications, and archives their state. Home Assistant
is stopped during this short window so its SQLite database is clean in the
archive. Three archives are retained under `/var/backup/caz-release-updater`;
Minecraft retains its separate daily archives under `/var/backup/minecraft`.
Backup and deployment hold the same maintenance lock as aggressive Docker
image pruning, so a stopped container's pinned image cannot disappear before
the service restarts.

After activation it waits up to ten minutes for these checks, then requires
them to remain healthy for another minute:

- SSH and Samba systemd services;
- Jellyfin, AdGuard Home, Home Assistant, Prometheus, Alertmanager, and Grafana
  HTTP responses;
- an actual DNS lookup through the local AdGuard Home resolver;
- the Minecraft container, its RCON console, and public-listener socket.

If activation or a health check fails, the updater restores the previous NixOS
profile, activates it, and runs the same health gate. The failed release is
quarantined locally so the daily timer does not retry it forever. A newer
release can deploy normally; retrying the same release requires an explicit
`--force` after investigation.

Deployment state is stored under `/var/lib/caz-release-updater`. The root-owned
state and systemd journal form the local audit record. Public releases remain
build records and do not reveal which release is actually running.

### Activation is intentionally host-privileged

`switch-to-configuration` runs the selected generation's activation script in
the updater process context. That script manages users and home directories,
updates `/etc` and the bootloader, writes required kernel settings, reloads the
system manager, and may load modules. Rollback performs the same operations for
the previous generation.

The updater therefore must not use systemd's host-isolating `ProtectHome`,
`ProtectSystem`, `ProtectKernelTunables`, `ProtectKernelModules`,
`ProtectControlGroups`, or `ProtectHostname` settings. The release provenance,
signed store-path comparison, and review policy are the security boundary for
the root code being activated. Process-level restrictions that do not change
the activation view remain enabled.

The NixOS module asserts this contract against the effective service
configuration so incompatible settings fail evaluation in CI. The deployer
also checks every host path required for activation before it builds a release,
backs up applications, changes the system profile, or stops services. This
turns a runtime mount or sandbox regression into an early, non-disruptive
failure.

A release that removes one of these restrictions cannot deploy itself through
an updater process that already started under the old restricted unit. The
process keeps that mount namespace until it exits, even after the new unit file
has been built. Bootstrap such a correction once from an unrestricted root
shell with `sudo caz-deploy-server-release`; after that successful switch, the
timer starts future runs under the corrected unit.

### Which generation defines "healthy"

The updater deliberately keeps running from the previous generation while it
supervises its own replacement, so that activation cannot kill the process
responsible for rolling activation back. That means the script, and everything
resolved from its build-time closure, belongs to the system being replaced.

The health gate must not work that way. A release that adds or removes a
service also changes which units and endpoints define health, so the updater
resolves `caz-server-health` through `/run/current-system/sw/bin` at every call
site. That symlink tracks whatever is active: the old generation before
activation, the new one after it, and the restored one after a rollback.

The pre-deployment backup is the opposite case and is intentionally left as the
updater's own copy, because it protects the state that exists *now*.

### A failing check is confirmed before it rolls anything back

Every check is a point-in-time probe, and the DNS one leaves the machine to
reach an upstream resolver, so a sample can miss for reasons the release under
test had no part in. During the stabilization window a failed sample is
therefore re-checked a few seconds later, and only a second consecutive failure
rolls the release back. A service that is genuinely down stays down and fails
the re-check too, so this costs a real failure seconds, not a rollback.

The wait phase needs no such treatment: it already retries until its deadline.

### Removing a service takes two releases

This follows from the above and is easy to trip over.

A release that removes a service is still gated by the health checks built into
the generation that came before it. If that older gate still requires the unit
the new release just removed, the check can never pass and the release rolls
itself back — even though the new system is perfectly healthy.

So retire a service in two steps: keep it running in the release that changes
the health gate, then remove it in the next one. This only applies to removals.
Adding a service is safe in a single release, because the older gate simply
does not know to look for it.

## Run it now

The maintenance window is only the unattended default. An administrator can
accelerate it at any time:

```bash
# Run the same verified deployment transaction directly and watch its output.
sudo caz-deploy-server-release

# Or trigger the systemd service used by the timer.
sudo systemctl start caz-release-updater.service

# Verify and reproduce the latest release without changing the server.
caz-deploy-server-release --check-only

# Run the same service health gate independently.
sudo caz-server-health --wait 30 --stabilize 60

# Create the same consistent backups without deploying a release.
sudo caz-pre-deployment-backup

# Inspect accepted/quarantined state and running versus next-boot generations.
sudo caz-deploy-server-release --status

# Inspect schedule and complete logs.
systemctl list-timers caz-release-updater.timer
systemctl status caz-release-updater.service
journalctl -u caz-release-updater.service
```

Only retry a quarantined or deliberately rolled-back latest release after
understanding the failure:

```bash
sudo caz-deploy-server-release --force
```

## Reboots and remaining boundary

Live service and userspace changes deploy automatically. The new generation is
also installed as the next boot generation. If its kernel, initrd, or kernel
modules differ from the booted system, deployment state records
`rebootRequired: true`, but this version deliberately does not reboot.

This follows the normal NixOS distinction between live switching and automatic
reboot policy. An unattended reboot can fail before the userspace rollback
supervisor exists, so enabling it safely requires boot-attempt counting,
boot-success marking, and a deliberately tested bad-boot recovery path on the
physical server. Until that work is complete, reboot at a convenient time and
use the systemd-boot menu to select an older generation if early boot fails.

Automatic local rollback also cannot reverse an application database migration
that modified persistent data incompatibly. The pre-deployment archives provide
the recovery material, but restoration remains an explicit administrator
operation. Home Assistant state is protected by the pre-deployment archive and
can also create application-native encrypted backups. Add equivalent
application-native handling before enabling Immich.

References: [NixOS automatic upgrades](https://nixos.org/manual/nixos/stable/#sec-upgrading-automatic),
[systemd boot counting](https://uapi-group.org/specifications/specs/boot_loader_specification/#boot-counting).

## First deployment

Automation cannot install itself onto a server that does not have it yet. The
release containing this feature therefore requires one final manual verified
deployment. After that generation is active, the timer and all commands above
are declarative parts of the server and future releases deploy themselves.

The same bootstrap rule applies to a release that repairs the updater's own
execution sandbox: the already-running unit cannot escape restrictions imposed
by the previous generation. After the corrective release is published, deploy
it once by invoking the updater directly from a normal root shell rather than
through systemd:

```bash
sudo caz-deploy-server-release
```

The direct process does not inherit the old unit's mount namespace. Once that
release is active, future timer runs use the corrected declarative unit.

## Public metadata

The release manifest, SBOMs, closure metadata, and deployment mechanism are
public by design. They reveal software versions but contain no credentials,
private addresses, player names, or proof that a particular release is active
on the server. That visibility is useful for review and does not create network
reachability. Secrets must continue to live outside Git, and exposed services
still require independent authentication, patching, and network controls.
