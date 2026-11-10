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

## Multi-factor authentication

The release explicitly loads the TOTP authenticator module through
`homeassistant.auth_mfa_modules` in `configuration.yaml`. This declares which
method is available; it does not enroll users or require unenrolled accounts
to use MFA. TOTP is also Home Assistant's default when this setting is omitted.

Each user must open **Profile > Security > Multi-factor authentication
modules**, enable **Authenticator app**, scan its QR code with their
authenticator, and confirm a generated code. Enrollment and its secret stay
in Home Assistant's private runtime storage, outside Git and the Nix store.
Existing API tokens do not acquire an extra MFA challenge; review and revoke
unneeded tokens separately.

See [Home Assistant's MFA documentation](https://www.home-assistant.io/docs/authentication/multi-factor-auth/).

## Declarative configuration boundary

The release mounts `home-assistant/configuration.yaml` and
`home-assistant/packages/` read-only beneath `/config`. The entry point keeps
`default_config:` and loads the package directory while continuing to include
the writable `automations.yaml`, `scripts.yaml`, and `scenes.yaml` files used by
Home Assistant's UI editors.

This division is intentional:

- Git and Nix own reviewed helpers, templates, scripts, and automations.
- `/config/.storage` owns HomeKit pairing keys, integration setup, entity and
  device registries, authentication, and other mutable runtime state.
- The Home Assistant database, backups, and UI-authored YAML stay writable
  under the existing state directory.

Never add pairing codes, credentials, `.storage`, or a copy of the live state
directory to this repository. The previous mutable `configuration.yaml` is not
deleted; the read-only mount hides it while this release is active, so a NixOS
rollback restores the previous configuration boundary.

## Private household inputs

The reusable HVAC package takes its thermostat selections and daytime/nighttime
setpoints from `!secret` references. Provision `package-secrets.yaml` under
`homelab.homeAssistant.privateConfigDir` (by default
`/var/lib/homelab/home-assistant-private`). It must contain JSON, which is also
valid YAML, with these keys:

- `hvac_thermostats`: a nonempty list of distinct climate entity IDs.
- `hvac_day_temperature`: the daytime cooling setpoint in Fahrenheit.
- `hvac_night_temperature`: the nighttime cooling setpoint in Fahrenheit.

Both setpoints must be between 62 and 85. This directory is root-owned `0700`,
and its files are root-owned `0600`. The file is mounted read-only at
`/config/packages/secrets.yaml`; HA excludes that filename from package discovery.
It never enters the Nix store. Administrators can still see resolved values in
HA's configuration and traces, so those diagnostics remain private too.

When serial passthrough is enabled, `hardware.json` in that directory contains
one `serial_device` key selecting a stable serial by-id character device.
The hardware mapping is not mounted into HA. Startup refuses missing, insecure,
or malformed inputs and unavailable hardware before creating the container.
The pre-deployment backup includes both HA state and this private directory.

Before deploying this configuration over the legacy HVAC package, run the
reviewed `scripts/migrate-ha-private.py` with `scripts/prepare-ha-private.py`
beside it, as root on the server. It reads the running package and current
container device mapping, validates consistent setpoints, and creates the
private files without restarting HA. It refuses conflicting existing files.
Keep the private files when rolling back; the older release simply ignores them.
Do not merge/deploy the migration-dependent release before provisioning them.

The migration preserves automation IDs, script names, helper state and selected
entities. Existing UI-created automations continue to use their normal writable
files. Later household changes belong in the private input file and an HA
restart, not a public commit. Do not commit live inputs, old package snapshots,
serial numbers, or household examples in migration tests or PR descriptions.

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

The container is intentionally not privileged. A serial device can be passed
through individually using `homelab.homeAssistant.serialDevice.enable`. Its
permanent `/dev/serial/by-id/` path is selected in private `hardware.json`,
not in the host's Nix configuration. Startup validates the mapping and creates
`/run/caz-home-assistant/serial`; the container sees `/dev/ttyZigbee` with
read/write access. No device-creation permission or directory-wide grant is used.
Local Bluetooth has a separate opt-in with broader permissions, described below.

For temporary remote administration, forward the private listener over SSH:

```bash
ssh -L 8123:127.0.0.1:8123 joshcaz@ssh.joshcaz.com
```

Then browse `http://127.0.0.1:8123`. A future always-on mobile setup should use
a reviewed VPN or Home Assistant Cloud design rather than a raw router port
forward.

## Bluetooth setup

The homeserver enables `homelab.homeAssistant.bluetooth.enable` to use its
onboard adapter alongside the ESPHome proxy. The proxy extends coverage to
devices beyond the server's radio range; enabling the local adapter preserves
the existing proxy integration and pairing state.

The option enables host BlueZ, powers the controller at boot, mounts
`/run/dbus:/run/dbus:ro`, and adds `NET_ADMIN` and `NET_RAW` to Home Assistant.
These are the [upstream Container requirements](https://www.home-assistant.io/integrations/bluetooth/#additional-details-for-container)
for scanning and automatic adapter recovery. HA starts after BlueZ and D-Bus,
but a Bluetooth service failure does not stop HA's other integrations.

This is a security tradeoff. Because HA already uses host networking,
`NET_ADMIN` also permits changes to host interfaces, routes and firewall rules.
The read-only D-Bus mount prevents filesystem writes through that mount; it
does **not** make bus method calls read-only or restrict them to BlueZ. A
compromised HA integration gains these permissions too. The container remains
unprivileged and retains `no-new-privileges`, but those settings do not remove
the explicitly granted access. The option defaults off for other hosts.

Deploy through the normal [server release process](server-updates.md), which
recreates the container with the new permissions. After deployment, inspect:

```bash
systemctl status bluetooth.service docker-homeassistant.service --no-pager
bluetoothctl show
sudo docker inspect --format '{{json .HostConfig.CapAdd}}' homeassistant
sudo docker inspect --format '{{json .Mounts}}' homeassistant
sudo docker logs --since 5m homeassistant
```

The controller should be powered, the D-Bus mount should be read-only, and
the Bluetooth management permission errors should disappear. In **Settings >
Devices & services > Bluetooth**, confirm that the local adapter is enabled
and advertisements appear from nearby devices. Confirm that the ESPHome proxy
still supplies its remote devices. Do not enable discoverable mode merely to
scan for BLE devices. Radio range and real device connections require this
post-deployment hardware check; the VM test covers host/container access.

## Zigbee setup

The host can detect a USB dongle even when Docker has not passed its serial
device into Home Assistant. An empty `HostConfig.Devices` array means the
coordinator cannot be opened by this container. Deploy the USB configuration
through the normal [server release process](server-updates.md) before pairing;
restarting the old container alone does not apply a repository change.

After the release containing the change is published, an administrator can
apply it on the server with `sudo caz-deploy-server-release`. Verify:

```bash
ls -l /dev/serial/by-id/
sudo docker inspect --format '{{json .HostConfig.Devices}}' homeassistant
sudo docker exec homeassistant ls -l /dev/ttyZigbee
```

Keep the dongle connected: Docker needs the configured device to exist when
starting the container. If it is unplugged and reconnected, restart
`docker-homeassistant.service` to refresh the device mapping. A replacement
dongle has a different serial number; update the private `hardware.json` mapping.

Use a shielded USB extension cable, preferably from a USB 2.0 port, to keep
the coordinator away from the server chassis, USB 3 devices, and Wi-Fi gear.
Only one application can own the coordinator; this installation uses ZHA.

### Coordinator

In **Settings > Devices & services > Add integration**, select **Zigbee Home
Automation**. There is no need to wait for automatic discovery to reappear.
For manual setup, use:

- Serial device: `/dev/ttyZigbee` (the path inside the container).
- Radio type: **EZSP / Silicon Labs EmberZNet** for the ZBDongle-E.
- Stock firmware settings: **115200 baud**, **software flow control**.
  Custom firmware may require different serial settings.

For a first installation with no existing paired Zigbee network, create a new
network. If a network already exists, preserve or restore it instead of erasing
it. Pairing data and network keys remain in Home Assistant's writable state.

If setup still fails, watch `sudo docker logs --since 5m -f homeassistant`
while submitting the setup form, then stop following with Ctrl-C. Home
Assistant also exposes logs under **Settings > System > Logs**. A previous
filtered log command returning no output does not prove that setup succeeded.

### Plug, bulbs, and button

Start a fresh **Add device** scan from the ZHA integration for each device.
Pair a mains-powered Zigbee router before end devices that need its range.
If pairing fails at the intended location, pair closer to the coordinator,
then move the router and verify connectivity before adding more devices.

- **3RSP02028BZ plug:** hold the side button for more than 10 seconds until
  the LED flashes red to reset it into pairing mode. Keep the plug connected
  to mains power so its Zigbee router stays available.
- **3RCB01057Z / ZL1 bulbs:** pair one at a time at their intended locations.
  To reset an unpaired bulb, power it off and on five times, finishing on.
  A white/color sequence followed by steady warm white indicates the
  three-minute pairing window. Leave wall switches on after pairing; use
  Home Assistant or the button to turn the light output off.
- **3RSB022Z button:** remove the battery insulation tab. If it does not
  flash blue, hold the reset button beneath the rear cover until it flashes
  rapidly (roughly 3–5 seconds depending on revision). Use standard Zigbee
  mode, shown by blue flashes. Alternating red/blue is Echo mode; five reset
  button presses within five seconds switches modes on versions with this
  feature. The battery-powered button does not extend the mesh.

Once the bulbs and button are paired, create a Light Group helper containing
the desired bulbs under **Settings > Devices & services > Helpers**. In
**Settings > Automations & scenes**, create device-triggered automations for
the button's single press, double press, and hold, targeting that light group.
For example: single press toggles the group, double press turns it on at full
brightness, and hold turns it off. Use the actual device and entity IDs shown
after pairing; those IDs are not known before onboarding. If press triggers
are missing, check the button's pairing mode and inspect `zha_event` in
Developer Tools before writing an event-based automation.

Walls and floors affect Zigbee range. If devices cannot join, try an
intermediate router location or another powered Zigbee router.

## Bundled custom integrations

Each directory in `home-assistant/custom_components` is mounted read-only at
its corresponding `/config/custom_components` path. Other custom integrations
and HA-managed state remain writable. Shipping a component does not enable it;
config entries and device selection stay in HA runtime state. Update bundled
code through the normal release process, including rollback.

HA LightFX and Scene Presets are installed from tagged upstream source inputs
in `flake.nix`, with immutable commits and content hashes in `flake.lock`.
Dependabot checks these tags for updates. The package reads each version from
the upstream manifest; the integration check verifies it matches the selected
tag, so version bumps do not need duplicate edits to packaging or tests.
Their Python code, bundled frontend, and upstream preset assets are mounted
read-only. Review release compatibility with the HA Container version, then
run `nix build .#checks.x86_64-linux.ha-integrations` and normal release checks.
HACS is not needed for these two installations.

The HA Container tag and digest live in `containers/home-assistant/Dockerfile`.
Nix reads that image reference directly and Dependabot updates the same file.
See [dependency updates](ci-and-releases.md#dependency-updates) for coverage
and the remaining manual maintenance items.

The declarative boundary is **software installation only**. Enable integrations
and configure devices, names, areas, layouts, dashboards, profiles, and
automations through Home Assistant. Those household details stay in its private
runtime storage; never copy live configuration, diagnostics, or maps into Git,
test fixtures, or PR descriptions. Installing these packages does not create
config entries, select lights, or apply a preset.

LightFX's configuration remains in HA's writable `.storage`. Scene Presets
expects optional custom presets and assets in its own `userdata` subdirectory,
so that subdirectory is a separate writable bind mount backed by
`${dataDir}/custom_components/scene_presets/userdata`. The host directory is
root-owned `0700`, stays outside the Nix store, and is included in the existing
HA state backup. The package contains only an empty mount point there.

For an existing manual installation, deployment overlays the pinned code while
preserving the existing private userdata path and integration config entries.
It does not delete the underlying manual code; a NixOS rollback reveals it
again. On a fresh installation, removing these mounts removes the installed
code but leaves HA's private config entries intact. Review upstream state-format
changes before upgrades: rolling back code does not roll back mutable state.

Upstream usage and release notes:

- [HA LightFX](https://github.com/rusty4444/ha-lightfx)
- [Scene Presets](https://github.com/Hypfer/hass-scene_presets)

See [local access-code management](home-assistant-local-codes.md) for the
optional HomeKit component, supported versions, behavior and validation.

## Primary references

- Home Assistant Container on Linux:
  <https://www.home-assistant.io/installation/linux/>
- Home Assistant Container operations:
  <https://www.home-assistant.io/common-tasks/container/>
- Home Assistant backups:
  <https://www.home-assistant.io/common-tasks/general/#backups>
- Home Assistant configuration packages:
  <https://www.home-assistant.io/docs/configuration/packages/>
- Home Assistant ZHA setup, USB mapping, and mesh troubleshooting:
  <https://www.home-assistant.io/integrations/zha/>
- SONOFF ZBDongle-E setup:
  <https://dongle.sonoff.tech/guide/zbdongle-e/connecting_to_home_assistant_via_zha/>
- THIRDREALITY device manuals (Gen2 plug, ZL1 bulb, and Smart Button):
  <https://www.thirdreality.com/pages/manuals-setup-help>
  <https://3reality.com/wp-content/uploads/2024/09/Smart-Button_UM_20240829.28.pdf>
  <https://3reality.com/wp-content/uploads/2024/03/Smart-Button.pdf>
