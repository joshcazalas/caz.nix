#!/usr/bin/env python3
"""Private configuration and lifecycle for the isolated device network.

No appliance-specific protocol, discovery, inventory, or credentials belong here.
systemd supervises each daemon/proxy independently; this program never backgrounds
processes, changes the host firewall, or creates an uplink to the namespace.
"""

import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys

NAMESPACE = "devices"
RUNTIME = Path("/run/caz-device-network")
NAME = re.compile(r"[a-z][a-z0-9-]{0,31}\Z")
INTERFACE = re.compile(r"[a-zA-Z0-9_-]{1,15}\Z")
RFC1918 = tuple(map(ipaddress.ip_network, ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")))


class ConfigurationError(ValueError):
    """A diagnostic consisting only of developer-authored, non-secret text."""


def require(condition, message):
    if not condition:
        raise ConfigurationError(message)


def keys(value, required, optional=()):
    require(isinstance(value, dict), "Expected a configuration object")
    require(set(required) <= value.keys(), "Missing required configuration fields")
    require(value.keys() <= set(required) | set(optional), "Unknown configuration fields")


def private_address(value, loopback=False):
    address = ipaddress.IPv4Address(value)
    require(any(address in network for network in RFC1918) or (loopback and address.is_loopback),
            "Endpoints must use literal private IPv4 addresses")
    return address


def port(value):
    require(type(value) is int and 1 <= value <= 65535, "Invalid TCP port")
    return value


def validate(config):
    keys(config, ("interface", "address", "dhcp"), ("wifi", "dns", "tcp"))
    require(isinstance(config["interface"], str) and INTERFACE.fullmatch(config["interface"]),
            "Invalid dedicated interface")
    require(config["interface"] != "lo", "Loopback cannot be a dedicated interface")
    address = ipaddress.IPv4Interface(config["address"])
    private_address(str(address.ip))
    require(16 <= address.network.prefixlen <= 29, "Use an IPv4 subnet between /16 and /29")
    require(address.ip not in (address.network.network_address, address.network.broadcast_address),
            "Invalid gateway address")
    keys(config["dhcp"], ("start", "end"))
    start, end = (ipaddress.IPv4Address(config["dhcp"][key]) for key in ("start", "end"))
    require(address.network.network_address < start <= end < address.network.broadcast_address,
            "DHCP pool must be inside the device subnet")
    require(not start <= address.ip <= end, "DHCP pool includes the gateway")
    wifi = config.get("wifi")
    if wifi is not None:
        keys(wifi, ("ssid", "passphraseFile", "channel", "countryCode"))
        require(isinstance(wifi["ssid"], str) and 1 <= len(wifi["ssid"].encode()) <= 32,
                "SSID must contain 1 to 32 UTF-8 bytes")
        require("\x00" not in wifi["ssid"], "SSID contains a null byte")
        require(type(wifi["channel"]) is int and 1 <= wifi["channel"] <= 11,
                "Use a compatible 2.4 GHz channel (1 to 11)")
        require(re.fullmatch(r"[A-Z]{2}", wifi["countryCode"]) is not None,
                "Use a two-letter regulatory country code")
        path = wifi["passphraseFile"]
        require(isinstance(path, str) and path.startswith("/") and "\n" not in path
                and "\x00" not in path and not path.startswith("/nix/store/"),
                "Wi-Fi passphrase must reside in a private runtime file")
    dns = config.get("dns", {})
    require(isinstance(dns, dict), "DNS must be a mapping")
    for name, value in dns.items():
        require(len(name) <= 253 and all(re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
                                        for label in name.split(".")), "Invalid local DNS suffix")
        require(ipaddress.IPv4Address(value) in address.network, "DNS answers must stay on the device subnet")
    tcp = config.get("tcp", {})
    require(isinstance(tcp, dict), "TCP grants must be a mapping")
    used = set()
    for name, grant in tcp.items():
        require(NAME.fullmatch(name) is not None, "Invalid TCP grant name")
        keys(grant, ("direction", "listenPort", "targetAddress", "targetPort"))
        require(grant["direction"] in ("toHost", "toNetwork"), "Invalid TCP grant direction")
        endpoint = (grant["direction"], port(grant["listenPort"]))
        require(endpoint not in used, "Duplicate TCP listener")
        used.add(endpoint)
        port(grant["targetPort"])
        target = private_address(grant["targetAddress"], loopback=True)
        if grant["direction"] == "toNetwork":
            require(target in address.network and target not in (
                address.ip, address.network.network_address, address.network.broadcast_address),
                "Host access must target one device address")
        else:
            require(target not in address.network, "Host endpoint overlaps the isolated subnet")
            require(grant["listenPort"] != 53, "DNS is reserved for the local resolver")
    return config


def read_private(path):
    # Avoid following a final symlink; runtime configuration is a root-owned file,
    # not an imported Nix path or a user-writable pointer.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600,
                "Private configuration files must be regular root-owned mode 0600 files")
        require(info.st_size <= 65536, "Configuration file is too large")
        return stream.read()


def load(path):
    return validate(json.loads(read_private(path)))


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None)


def ns(*args, capture=False):
    return run("ip", "netns", "exec", NAMESPACE, *args, capture=capture)


def write(path, content):
    path.write_text(content)
    path.chmod(0o600)


def prepare(config):
    RUNTIME.mkdir(mode=0o700, exist_ok=True)
    info = RUNTIME.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700,
            "Unsafe network runtime directory")
    require(not (RUNTIME / "owned").exists(), "Previous namespace ownership must be cleaned up first")
    iface = config["interface"]
    address = ipaddress.IPv4Interface(config["address"])
    dns = [f"interface={iface}", "bind-interfaces", f"listen-address={address.ip}",
           "no-resolv", "no-poll", "no-hosts", "local=/#/", "local-ttl=60",
           "dhcp-authoritative", "leasefile-ro", "pid-file=", "log-facility=-",
           "user=nobody", "group=nogroup",
           f"dhcp-range={config['dhcp']['start']},{config['dhcp']['end']},{address.network.netmask},12h",
           f"dhcp-option=option:router,{address.ip}", f"dhcp-option=option:dns-server,{address.ip}"]
    dns += [f"address=/{name}/{target}" for name, target in config.get("dns", {}).items()]
    write(RUNTIME / "dnsmasq.conf", "\n".join(dns) + "\n")
    wifi = config.get("wifi")
    if wifi:
        password = read_private(wifi["passphraseFile"]).removesuffix("\n")
        require(8 <= len(password) <= 63 and all(32 <= ord(c) <= 126 for c in password),
                "Wi-Fi passphrase must contain 8 to 63 printable ASCII characters")
        # Hex encoding the SSID avoids interpreting user text as hostapd syntax.
        write(RUNTIME / "hostapd.conf", "\n".join([
            f"interface={iface}", "driver=nl80211", f"ssid2={wifi['ssid'].encode().hex()}",
            f"country_code={wifi['countryCode']}", "ieee80211d=1", "hw_mode=g",
            f"channel={wifi['channel']}", "ieee80211n=1", "wmm_enabled=1", "auth_algs=1",
            "wpa=2", f"wpa_passphrase={password}", "wpa_key_mgmt=WPA-PSK",
            "rsn_pairwise=CCMP", "ap_isolate=1", f"ctrl_interface={RUNTIME}/hostapd",
        ]) + "\n")
    else:
        (RUNTIME / "hostapd.conf").unlink(missing_ok=True)
    write(RUNTIME / "config.json", json.dumps(config))
    run("dnsmasq", "--test", f"--conf-file={RUNTIME}/dnsmasq.conf")


def up(config):
    iface = config["interface"]
    require(not Path(f"/run/netns/{NAMESPACE}").exists(), "Device namespace already exists; refusing to take ownership")
    link = json.loads(run("ip", "-j", "address", "show", "dev", iface, capture=True).stdout)[0]
    require("UP" not in link["flags"] and not link["addr_info"],
            "Dedicated interface must be down and unconfigured; refusing to take an active interface")
    require(not run("ip", "-4", "route", "show", "dev", iface, capture=True).stdout.strip(),
            "Dedicated interface has routes")
    if config.get("wifi"):
        phy = (Path("/sys/class/net") / iface / "phy80211").resolve(strict=True).name
        siblings = [p.name for p in Path("/sys/class/net").iterdir()
                    if (p / "phy80211").exists() and (p / "phy80211").resolve().name == phy]
        require(siblings == [iface], "The Wi-Fi radio has other interfaces; refusing to move a shared radio")
    run("ip", "netns", "add", NAMESPACE)
    # Ownership marker prevents ExecStopPost from deleting a namespace we did not create.
    write(RUNTIME / "owned", "1")
    if config.get("wifi"):
        run("iw", "phy", phy, "set", "netns", "name", NAMESPACE)
    else:
        run("ip", "link", "set", iface, "netns", NAMESPACE)
    ns("sysctl", "-qw", "net.ipv4.ip_forward=0", "net.ipv6.conf.all.disable_ipv6=1",
       "net.ipv6.conf.default.disable_ipv6=1")
    # Filter before bringing up the dedicated interface. There is also no route
    # out: host firewall reloads and Docker's forwarding rules cannot change that.
    ns("iptables", "-w", "-P", "INPUT", "DROP")
    ns("iptables", "-w", "-P", "FORWARD", "DROP")
    ns("iptables", "-w", "-A", "INPUT", "-i", "lo", "-j", "ACCEPT")
    ns("iptables", "-w", "-A", "INPUT", "-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT")
    ns("iptables", "-w", "-A", "INPUT", "-i", iface, "-p", "udp", "--sport", "68", "--dport", "67", "-j", "ACCEPT")
    address = ipaddress.IPv4Interface(config["address"])
    for protocol, number in [("udp", 53), ("tcp", 53)] + [
        ("tcp", grant["listenPort"]) for grant in config.get("tcp", {}).values() if grant["direction"] == "toHost"
    ]:
        ns("iptables", "-w", "-A", "INPUT", "-i", iface, "-s", str(address.network),
           "-d", str(address.ip), "-p", protocol, "--dport", str(number), "-j", "ACCEPT")
    run("ip", "-n", NAMESPACE, "link", "set", "lo", "up")
    run("ip", "-n", NAMESPACE, "address", "add", config["address"], "dev", iface)
    run("ip", "-n", NAMESPACE, "link", "set", iface, "up")
    check_isolation(config)


def down():
    if not (RUNTIME / "owned").exists():
        return
    config = load(RUNTIME / "config.json")
    iface = config["interface"]
    if Path(f"/run/netns/{NAMESPACE}").exists():
        # Dependents have BindsTo/After and stop first. Refuse to strand a live
        # daemon or kill unrelated administrative sessions in the namespace.
        require(not run("ip", "netns", "pids", NAMESPACE, capture=True).stdout.strip(),
                "Namespace still has processes; stop its dependents before retrying cleanup")
        links = json.loads(run("ip", "-n", NAMESPACE, "-j", "link", capture=True).stdout)
        if any(link["ifname"] == iface for link in links):
            run("ip", "-n", NAMESPACE, "link", "set", iface, "down")
            run("ip", "-n", NAMESPACE, "address", "flush", "dev", iface)
            if config.get("wifi"):
                ns("iw", "dev", iface, "set", "type", "managed")
                # Moving by interface wiphy avoids relying on unstable phy indexes.
                info = ns("iw", "dev", iface, "info", capture=True).stdout
                phy = re.search(r"\bwiphy (\d+)", info).group(1)
                ns("iw", "phy", f"phy{phy}", "set", "netns", "1")
            else:
                run("ip", "-n", NAMESPACE, "link", "set", iface, "netns", "1")
        run("ip", "netns", "delete", NAMESPACE)
    (RUNTIME / "owned").unlink(missing_ok=True)


def proxy(config, side, name):
    require(name in config.get("tcp", {}), "No such TCP grant")
    grant = config["tcp"][name]
    target_side = "host" if grant["direction"] == "toHost" else "network"
    socket = f"{RUNTIME}/{name}.sock"
    if side == target_side:
        listener = f"UNIX-LISTEN:{socket},fork,unlink-early,mode=0600,max-children=64"
        destination = f"TCP4:{grant['targetAddress']}:{grant['targetPort']},connect-timeout=5"
    else:
        bind = "127.0.0.1" if side == "host" else str(ipaddress.IPv4Interface(config["address"]).ip)
        listener = f"TCP4-LISTEN:{grant['listenPort']},bind={bind},reuseaddr,fork,max-children=64"
        destination = f"UNIX-CONNECT:{socket}"
    os.execlp("socat", "socat", listener, destination)


def generate(config, destination):
    directory = Path(destination) / "device-network.target.wants"
    directory.mkdir(parents=True, exist_ok=True)
    instances = [f"device-network-{side}@{name}.service"
                 for name in config.get("tcp", {}) for side in ("host", "network")]
    if config.get("wifi"):
        instances.append("device-network-wifi.service")
    for name in instances:
        template = name.split("@", 1)[0] + "@.service" if "@" in name else name
        (directory / name).symlink_to(f"/etc/systemd/system/{template}")


def check_isolation(config):
    links = json.loads(run("ip", "-n", NAMESPACE, "-j", "link", capture=True).stdout)
    require({link["ifname"] for link in links} == {"lo", config["interface"]}, "Unexpected namespace interface")
    routes = json.loads(run("ip", "-n", NAMESPACE, "-j", "-4", "route", "show", "table", "all", capture=True).stdout)
    subnet = ipaddress.IPv4Interface(config["address"]).network
    require(all(route.get("dev") in ("lo", config["interface"]) and not route.get("gateway")
                and route.get("dst") != "default" and (
                    ipaddress.ip_network(route["dst"], strict=False).subnet_of(subnet)
                    or ipaddress.ip_network(route["dst"], strict=False).subnet_of(ipaddress.ip_network("127.0.0.0/8"))
                ) for route in routes), "Unexpected route outside the isolated network")
    require(ns("sysctl", "-n", "net.ipv4.ip_forward", capture=True).stdout.strip() == "0", "Forwarding is enabled")
    ipv6 = json.loads(run("ip", "-n", NAMESPACE, "-j", "-6", "address", capture=True).stdout)
    require(all(not link["addr_info"] for link in ipv6), "Unexpected IPv6 address")
    rules = ns("iptables", "-w", "-S", capture=True).stdout
    require("-P INPUT DROP" in rules and "-P FORWARD DROP" in rules, "Namespace firewall is not enforcing default deny")


def health(config):
    require(config == load(RUNTIME / "config.json"), "Private configuration has unapplied changes")
    check_isolation(config)
    units = ["device-network.service", "device-network-dns.service"]
    if config.get("wifi"):
        units.append("device-network-wifi.service")
        # hostapd and the deployment supervisor each have PrivateTmp enabled.
        # Put the client's reply socket in their shared, root-only runtime dir.
        status = ns("hostapd_cli", "-p", str(RUNTIME / "hostapd"), "-s", str(RUNTIME),
                    "-i", config["interface"], "status", capture=True).stdout
        require("state=ENABLED" in status.splitlines(), "Access point is not ready")
    units += [f"device-network-{side}@{name}.service"
              for name in config.get("tcp", {}) for side in ("host", "network")]
    for unit in units:
        run("systemctl", "is-active", "--quiet", unit)
    print("Device network: isolated; configured services active")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="/var/lib/homelab/device-network/network.json")
    parser.add_argument("command", choices=("validate", "prepare", "up", "down", "proxy-host", "proxy-network", "generate", "health"))
    parser.add_argument("argument", nargs="?")
    parser.add_argument("generator_paths", nargs="*")
    args = parser.parse_args()
    if args.command == "down":
        down()
        return
    config = load(args.config)
    if args.command == "validate":
        print("Device network configuration is valid")
    elif args.command == "prepare":
        prepare(config)
    elif args.command == "up":
        up(config)
    elif args.command.startswith("proxy-"):
        proxy(config, args.command.removeprefix("proxy-"), args.argument)
    elif args.command == "generate":
        require(args.argument is not None, "Generator output directory is required")
        generate(config, args.argument)
    elif args.command == "health":
        health(config)


if __name__ == "__main__":
    try:
        main()
    except ConfigurationError as error:
        print(f"Device network: {error}", file=sys.stderr)
        sys.exit(1)
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError):
        # Config/daemon diagnostics can contain SSIDs, credentials and targets.
        # Do not repeat input, subprocess arguments, or a JSON parse excerpt.
        print("Device network operation failed; check private configuration, interface ownership, and service status.", file=sys.stderr)
        sys.exit(1)
