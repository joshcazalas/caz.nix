# Local device network

`homelab.deviceNetwork` provides a shared place for devices that must use local
services without reaching the internet. It is independent of Home Assistant,
MQTT, and any particular vendor or appliance. Enable it in the host configuration
and provision its private runtime configuration before deploying that release.

## Network boundary

A dedicated Wi-Fi radio (or dedicated wired interface) belongs to the `devices`
network namespace. That namespace contains only the dedicated interface and
loopback. It has no uplink, veth connection, default route, NAT, or IPv6. IPv4
forwarding is disabled and the namespace firewall defaults to dropping input and
forwarded packets. The host's LAN, WireGuard, AdGuard, Docker and firewall rules
continue operating in the host namespace.

The access point uses WPA2/AES and station isolation. DHCP advertises a local
gateway and resolver for clients that require them, but that gateway cannot
route packets outside the subnet. DNS answers explicitly configured local
suffixes; it never forwards other queries. Hardcoded external DNS servers, DoH
and direct-IP connections have no route out either.

Each TCP grant is a pair of systemd-supervised byte-stream proxies joined by a
root-only Unix socket. The peer chooses neither the destination nor the port:

- `toHost`: devices reach a selected port on their gateway, which connects to
  exactly one private IPv4 address and port in the host network namespace.
- `toNetwork`: a host application reaches a loopback-only listener, which
  connects to exactly one device address and port. Nothing is published to the
  LAN or a VPN by that grant.

TLS passes through unchanged. The destination must enforce its own authentication
and authorization. Do not grant access to an unrestricted HTTP proxy, recursive
DNS service, management socket or other service that can relay arbitrary traffic.
The endpoint is part of the trust boundary even though it is local.

This initial module supports TCP integrations and local DNS. It deliberately
does not reflect mDNS/SSDP, route arbitrary traffic, or implement UDP grants.
Configure integrations with explicit endpoints. Future protocol support belongs
in this shared module with corresponding isolation tests. A wired switch must
provide its own client isolation; a shared Ethernet segment does not isolate
devices from each other. Wi-Fi isolation also depends on driver/AP support.

## Private configuration

The default path is `/var/lib/homelab/device-network/network.json`, owned by root,
mode `0600`, inside a root-owned `0700` directory. The Wi-Fi passphrase is a
separate root-owned `0600` file. These files are runtime inputs, not Nix imports,
so their contents never enter the public repository or the Nix store.

The following values are **synthetic documentation examples**, not deployment
settings. Omit `wifi` for a dedicated wired interface; omit `tcp` or `dns` when
no grants or aliases are needed.

```json
{
  "interface": "wlan-test",
  "address": "192.168.70.1/24",
  "dhcp": { "start": "192.168.70.20", "end": "192.168.70.50" },
  "wifi": {
    "ssid": "Example isolated devices",
    "passphraseFile": "/var/lib/homelab/device-network/wifi-passphrase",
    "channel": 6,
    "countryCode": "US"
  },
  "dns": { "service.test": "192.168.70.1" },
  "tcp": {
    "events": {
      "direction": "toHost",
      "listenPort": 8883,
      "targetAddress": "127.0.0.1",
      "targetPort": 1883
    },
    "control": {
      "direction": "toNetwork",
      "listenPort": 19080,
      "targetAddress": "192.168.70.10",
      "targetPort": 80
    }
  }
}
```

Use an unused RFC 1918 subnet, and a radio that no other network manager owns.
Never use the server's LAN uplink. Startup refuses an interface that is up,
already addressed, routed, or shares its Wi-Fi radio with another interface.
For stable `toNetwork` targets, configure static device addresses outside the
DHCP pool. The initial implementation does not maintain a device inventory or
DHCP reservations. DNS suffix answers must point into the isolated subnet.

Private configuration resides on the root filesystem. The systemd generator
must be able to read it at boot and on daemon reload, before optional data
mounts. Missing or invalid configuration fails the deployment health gate;
it does not fall back to ordinary LAN networking.

## Operations and releases

Nix owns the module, executable, service templates and tests. The private JSON
owns the selected hardware, Wi-Fi identity and endpoint grants. Individual
integration services own their application configuration, authentication,
certificates and state independently; the network does not build or deploy them.

`homelab.localIntegrations` optionally manages those applications using the
existing Docker runtime. Its root-owned `0600`
`/var/lib/homelab/local-integrations/compose.yaml` stays private, as do mounted
configuration, credentials, state and patched builds. JSON is also accepted in
this file because it is a YAML subset. The shared module accepts only internal
IPv4 bridge networks, immutable image digests/IDs, explicit non-root users,
read-only container roots, dropped capabilities and local-only DNS. It rejects
published ports, host namespaces, privileged containers and hardware grants.
Bind mounts must remain under that private integration directory. Use
`security_opt: ["no-new-privileges:true"]` and `dns: ["127.0.0.1"]` for each
service; aliases on the internal Docker network still resolve locally.

Set fixed private container addresses in the private Compose IPAM configuration
when they are grant targets. Home Assistant's host network can reach those
addresses directly, including an authenticated MQTT broker; Docker publishes no
ports to the LAN. The application bridge itself has no internet route, so a
vendor adapter does not silently regain cloud access from the server side.

`local-integrations.service` runs Compose in the foreground and supervises the
whole application group. It never builds images or pulls during startup. For
recovery after Docker pruning, provision approved image archives in
`images/IMAGE_SHA256_HEX.tar` beneath the private integration directory. The
loader verifies that the requested immutable image exists after loading. These
archives are installation artifacts, separate from mutable application data.
The health gate checks all configured containers, their available health checks,
and the actual network attachments, including unexpected extra networks.

```bash
sudo caz-local-integrations validate
sudo systemctl restart local-integrations.service
sudo caz-local-integrations health
```

For a configuration change, validate first, then stop the target before reload
so removed grants stop as well as new grants starting:

```bash
sudo caz-device-network validate
sudo systemctl stop device-network.target device-network.service
sudo systemctl daemon-reload
sudo systemctl start device-network.target
sudo caz-device-network health
sudo caz-server-health --wait 30 --stabilize 60
```

Changing the passphrase or network identity can require re-enrolling clients.
Preserve existing values when migrating a successful enrollment. Do not remove
the application's certificate authority or replace it with a newly generated
one during migration.

`device-network.service` owns namespace setup and cleanup. `device-network-dns`
provides DHCP/DNS, `device-network-wifi` provides the optional access point, and
`device-network-host@NAME` / `device-network-network@NAME` implement each grant.
They start at boot and stop before their namespace disappears. Stopping the
target returns the dedicated interface to the host, down and without addresses.
Unexpected namespace processes prevent cleanup rather than being killed.

The release health gate checks the isolation invariants, access-point readiness
and all declared service instances. The normal monitoring rules already report
failed systemd services. Application-specific health checks must separately test
the granted service's behavior; an active TCP proxy does not prove its backend
is healthy. Keep protocol captures and detailed logs private.

The integration test uses synthetic devices on virtual Ethernet links. It tests
both allowed directions, local DNS, blocked LAN/internet access, host firewall
independence, namespace restart and reboot. Physical Wi-Fi association and radio
coverage still require a deployment check.

References: [Linux network namespaces](https://man7.org/linux/man-pages/man7/network_namespaces.7.html),
[systemd namespace execution](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html),
[systemd generators](https://www.freedesktop.org/software/systemd/man/latest/systemd.generator.html).
