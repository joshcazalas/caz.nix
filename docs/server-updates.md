# Verified server updates

The homeserver includes an opt-in updater that automatically discovers and
verifies releases, but stops before activation:

```text
public immutable release
  -> tokenless provenance and checksum verification
  -> exact commit build
  -> store path and derivation comparison
  -> next-boot generation
  -> manual reboot
```

This separates routine supply-chain work from the operational decision to
restart a machine that may be serving storage or stateful applications.

## Trust and verification model

`caz-stage-server-release` uses outbound HTTPS only. It does not accept inbound
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
9. runs `nixos-rebuild boot`, which changes the next boot generation without
   activating it or rebooting.

Accepted GitHub release IDs are recorded in
`/var/lib/caz-release-updater/accepted-release.json`. An older ID is rejected,
which prevents an ordinary release-selection rollback. The root-owned state and
systemd journal form the local deployment record.

The updater deliberately trusts changes merged to protected `main` and the
GitHub-hosted release workflow. Attestations prove origin and integrity; they do
not prove that a change is bug-free. Pull-request review and CI remain the
policy gate.

## Enabling it later

The module is imported but disabled. First install the physical server, deploy
and test a known-good generation manually, and confirm that the corresponding
release has completed successfully. Then change the host configuration to:

```nix
homelab.releaseUpdater.enable = true;
```

After that change itself passes CI, is merged, released, and deployed manually,
the timer checks every day at 04:00 local time with up to two hours of stable
random delay. A missed run is performed after the next boot.

Useful commands on the server:

```bash
# Verify and reproduce the latest build without changing boot state.
caz-stage-server-release --check-only

# Trigger the normal updater immediately.
sudo systemctl start caz-release-updater.service

# Inspect its result and schedule.
systemctl status caz-release-updater.service
systemctl list-timers caz-release-updater.timer
journalctl -u caz-release-updater.service

# Compare the running system with the staged boot generation.
readlink -f /run/current-system
readlink -f /nix/var/nix/profiles/system
```

No automatic reboot or live `switch` occurs in this first version. Reboot only
after reviewing the release and choosing an appropriate maintenance window.
The boot menu retains older NixOS generations for manual rollback.

## Public metadata

The release manifest, SBOMs, closure metadata, and deployment mechanism are
public by design. They reveal software versions but contain no credentials,
private addresses, or proof that a particular release is active on the server.
That visibility is useful for review and does not create network reachability.
Secrets must continue to live outside Git, and exposed services still require
independent authentication, patching, and network controls.
