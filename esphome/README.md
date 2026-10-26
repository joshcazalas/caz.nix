# Private Bluetooth proxy project

`bluetooth-proxy.yaml` is a generic ESP32 template, validated with ESPHome
2026.10.0. Build it outside the repository and Nix store. Node names, network
settings, Wi-Fi credentials, API keys, firmware binaries and build directories
are private runtime material; firmware binaries contain credentials too.

`scripts/prepare-esphome-proxy.py` prepares a root-only project and an
administrator-owned build copy. It reads the existing private device-network
configuration and accepts a private JSON file containing the existing proxy's
`name`, `host` and `entry_id`. It proposes a static address outside the DHCP pool
and one loopback-only `toNetwork` grant to native API port 6053. It does not
apply the grant, flash a device or change Home Assistant. Preserve and privately
back up the generated project before upgrading firmware. With Home Assistant
enabled, release backups include the default `esphome-private` directory under
the homelab data root. A custom project location requires separate backup
coverage. Build copies under `/tmp` are temporary and are not backed up.

The proposed address still requires availability verification: an absent ARP
neighbor is not proof that an address is unused. Verify Wi-Fi coverage and plan
USB recovery before flashing. Recheck the saved network hash and preserve all
existing grants when applying a proposal. Reconfigure the existing ESPHome
integration with the loopback endpoint and new encryption key to retain device
identity. Bluetooth accessory pairing remains in Home Assistant.

The template uses encrypted native API access and password-protected native
OTA. It disables mDNS and does not configure a fallback access point, web
server or cloud firmware updater. Routine HA access needs only the API grant;
firmware maintenance requires USB or a separately controlled maintenance path.
