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
  "dhcp": {
    "start": "192.168.70.20",
    "end": "192.168.70.50",
    "reservations": { "02:00:00:00:00:10": "192.168.70.10" }
  },
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
      "sourceAddresses": ["192.168.70.10"],
      "listenPort": 8883,
      "targetAddress": "127.0.0.1",
      "targetPort": 1883
    },
    "control": {
      "direction": "toNetwork",
      "listenAddress": "127.0.0.2",
      "listenPort": 443,
      "targetAddress": "192.168.70.10",
      "targetPort": 443
    }
  }
}
```

Use an unused RFC 1918 subnet, and a radio that no other network manager owns.
Never use the server's LAN uplink. Startup refuses an interface that is up,
already addressed, routed, or shares its Wi-Fi radio with another interface.
For stable `toNetwork` targets, use private DHCP reservations or static device
addresses outside the dynamic DHCP pool. Reservations map unique unicast MAC
addresses to unique device addresses; gateway, network and broadcast addresses
are rejected. DNS suffix answers must point into the isolated subnet.

`toNetwork.listenAddress` defaults to `127.0.0.1` and accepts only IPv4 loopback
addresses. Separate addresses such as `127.0.0.2:443` and `127.0.0.3:443` let
integrations use the same fixed protocol port for different devices. Configure
the application with its assigned loopback endpoint. These listeners are
accessible to other processes sharing the host network namespace, including
host-networked containers; they do not identify or authorize a particular app.

`toHost.sourceAddresses` restricts an incoming grant to a nonempty list of exact
device IPv4 addresses. Omission retains access from the whole isolated subnet
for compatibility with existing configurations. Prefer explicit addresses for
new grants. IP and MAC restrictions are not authentication: a compromised
station may spoof them. An MQTT broker must still authenticate clients and
restrict their topics with ACLs. A device does not need access to an application's
management API merely because the application controls it.

Private configuration resides on the root filesystem. The systemd generator
must be able to read it at boot and on daemon reload, before optional data
mounts. Missing or invalid configuration fails the deployment health gate;
it does not fall back to ordinary LAN networking.

## Operations and releases

Nix owns the module, executable, service templates and tests. The private JSON
owns the selected hardware, Wi-Fi identity and endpoint grants. Individual
integration services own their application configuration, authentication,
certificates and state independently; the network does not build or deploy them.

Keep SSIDs, client addresses, hardware identifiers, appliance profiles and room
assignments in those private runtime files. Public Nix should describe reusable
mechanisms and use synthetic test fixtures. The private JSON remains a
declarative input without making the household inventory public or copying it
into the world-readable Nix store. Back it up privately before applying changes.

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

Startup waits up to 30 seconds for udev to initialize the exact interface named
in the private configuration before inspecting or moving it. The ownership
checks still reject an active, addressed, routed or shared interface. Missing
hardware fails without creating a namespace. There is no ongoing dependency on
the host's interface device unit: moving the interface into its namespace
deliberately removes it from the host network view.

If setup failed at boot and the hardware is now available, recover the complete
target after reviewing the failure:

```bash
sudo systemctl start device-network.target
sudo caz-device-network health
sudo caz-server-health --wait 30 --stabilize 60
```

Starting only `device-network.service` creates the namespace but does not start
DNS, Wi-Fi and proxy members whose earlier jobs failed on that dependency.
`systemctl --failed` can therefore omit the unavailable members: they are
inactive rather than failed. Start the target to bring them up together.

The release health gate checks the isolation invariants, access-point readiness,
the complete namespace iptables rules, and all declared service instances. It
also checks TCP listener addresses and ports against each proxy's main process,
requires root-owned mode `0600` bridge sockets, and rejects unexpected active
proxy instances. The normal monitoring rules already report
failed systemd services. Application-specific health checks must separately test
the granted service's behavior; an active TCP proxy does not prove its backend
is healthy. Keep protocol captures and detailed logs private.

The integration test uses synthetic devices on virtual Ethernet links. It tests
both allowed directions, source restrictions, fixed-port loopback endpoints,
DHCP reservations, local DNS, blocked LAN/internet access, firewall drift, host
firewall independence, delayed and missing interfaces, recovery, namespace
restart and reboot. Physical Wi-Fi association and radio coverage still require
a deployment check.

Before enrolling appliances, associate two test clients with the actual access
point. Confirm each receives its intended lease and can reach only its granted
services. Run a temporary TCP listener on each client, allow its port in that
client's firewall, and verify it works locally before checking that neither
client can connect to the other. Also test peer ICMP; a failed ping alone does
not prove station isolation. Check that both clients fail to reach LAN services,
public IPs and external DNS servers, while allowed application traffic works.
Repeat after an access-point restart and server reboot. Keep client identifiers
and results private. The virtual Ethernet test cannot establish whether a real
Wi-Fi driver enforces station isolation.

The host and the services behind grants remain trusted. Review application
capabilities separately: a host-networked application with network administration
privileges can change networking regardless of these device-side restrictions.
Remove privileges only after identifying and replacing the functionality that
requires them, such as local Bluetooth management.

References: [Linux network namespaces](https://man7.org/linux/man-pages/man7/network_namespaces.7.html),
[systemd namespace execution](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html),
[systemd generators](https://www.freedesktop.org/software/systemd/man/latest/systemd.generator.html).
