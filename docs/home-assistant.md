# Home Assistant

Home Assistant runs as the upstream-supported Home Assistant Container rather
than the deprecated native Python/Core installation. The image is pinned by
version and linux/amd64 digest in `modules/nixos/home-assistant.nix`; updates
therefore arrive as reviewed releases instead of changing themselves at
runtime.

The container uses host networking because device discovery depends on LAN
broadcast and multicast traffic. It does not publish a Docker port: the NixOS
firewall accepts TCP 8123 only from private IPv4 sources. Do not forward 8123
on the router.

## First start

The first activation downloads the pinned image and may take several minutes.
Once the release health gate succeeds, open this from a LAN device:

```text
http://homeserver:8123
```

Create the owner account, confirm the home location, time zone, and unit
system, and review every automatically discovered integration before accepting
it. The owner password belongs in a password manager; it is mutable application
state and must not be added to this repository or sops secrets.

Home Assistant stores its configuration, UI-managed integrations,
automations, credentials, history database, and local backups under:

```text
/var/lib/homelab/home-assistant
```

The directory is root-only because `.storage` contains credentials. Edit files
there only for recovery or a deliberately reviewed configuration change; use
the Home Assistant UI for normal setup.

## Operations

```bash
systemctl status docker-homeassistant.service --no-pager
sudo docker logs --tail 100 homeassistant
sudo systemctl restart docker-homeassistant.service
sudo docker exec homeassistant \
  python -m homeassistant --script check_config --config /config
sudo caz-server-health --wait 30 --stabilize 60
```

The container receives a 60-second stop grace period so Home Assistant can
close SQLite cleanly. The release health gate requires both its systemd unit
and HTTP endpoint to remain healthy.

Before every automatic release, the updater stops Home Assistant and includes
its complete state directory in the retained application-state archive. The
service starts again as soon as the archive is complete. This protects rollback
material for releases, but the archives are on the same NVMe and are not a
substitute for an off-machine backup. After onboarding, configure Home
Assistant's automatic encrypted backup feature with an off-host destination
and save its emergency kit separately.

The backup/deployment transaction is serialized with Docker image pruning, so
the pinned Home Assistant image remains available while its container is
stopped. Before changing the pinned Home Assistant version, review that
version's release notes and create an application-native encrypted backup.
NixOS rollback does not reverse a persistent-data migration; document and test
the exact state-archive restore procedure before the first version bump.

## Container boundary

Home Assistant Container supports integrations, dashboards, automations, and
backups, but it does not include Home Assistant OS apps. MQTT, Zigbee2MQTT,
Z-Wave JS, ESPHome, or similar companion services should be added as separately
pinned NixOS containers when they become necessary.

The container is intentionally not privileged. Bluetooth or a future USB radio
will receive only the specific D-Bus socket, device node, and group access it
needs after the hardware is selected. This keeps initial thermostat and LAN
integrations from gaining unrelated host-device access.

For temporary remote administration, forward the private listener over SSH:

```bash
ssh -L 8123:127.0.0.1:8123 joshcaz@ssh.joshcaz.com
```

Then browse `http://127.0.0.1:8123`. A future always-on mobile setup should use
a reviewed VPN or Home Assistant Cloud design rather than a raw router port
forward.

## Primary references

- Home Assistant Container on Linux:
  <https://www.home-assistant.io/installation/linux/>
- Home Assistant Container operations:
  <https://www.home-assistant.io/common-tasks/container/>
- Home Assistant backups:
  <https://www.home-assistant.io/common-tasks/general/#backups>
