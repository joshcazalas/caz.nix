#!/usr/bin/env python3
"""Prepare a private proxy project and one TCP-grant proposal; do not apply it."""
import argparse
import base64
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import tempfile


def read_private(path, owner=0):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != owner
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_size > 65536):
            raise ValueError('Expected an owner-only regular file.')
        return stream.read()


def proposal(network, occupied, used_ports):
    address = ipaddress.IPv4Interface(network['address'])
    first, last = (ipaddress.IPv4Address(network['dhcp'][k]) for k in ('start', 'end'))
    unavailable = {address.ip, *(ipaddress.IPv4Address(v) for v in occupied)}
    unavailable.update(ipaddress.IPv4Address(g['targetAddress']) for g in network.get('tcp', {}).values())
    candidate = next((ipaddress.IPv4Address(i) for i in range(int(address.network.broadcast_address)-1,
                    int(address.network.network_address), -1)
                    if not first <= ipaddress.IPv4Address(i) <= last and ipaddress.IPv4Address(i) not in unavailable), None)
    if candidate is None:
        raise ValueError('No unused static address outside the DHCP pool.')
    excluded = set(used_ports) | {g['listenPort'] for g in network.get('tcp', {}).values()}
    port = next((p for p in range(19100, 19200) if p not in excluded), None)
    if port is None:
        raise ValueError('No available loopback grant port.')
    return {'direction': 'toNetwork', 'listenPort': port, 'targetAddress': str(candidate), 'targetPort': 6053}


def private_write(path, value):
    text = value if isinstance(value, str) else json.dumps(value, indent=2)+'\n'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as stream: stream.write(text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-file', required=True, type=Path)
    parser.add_argument('--template', required=True, type=Path)
    parser.add_argument('--network-file', type=Path, default=Path('/var/lib/homelab/device-network/network.json'))
    parser.add_argument('--project-dir', type=Path, default=Path('/var/lib/homelab/esphome-private/bluetooth-proxy'))
    args = parser.parse_args()
    if os.geteuid() != 0: parser.error('Run with sudo on the server.')
    os.umask(0o077)
    try:
        uid, gid = int(os.environ.get('SUDO_UID', '0')), int(os.environ.get('SUDO_GID', '0'))
        device = json.loads(read_private(args.device_file, uid))
        if set(device) != {'name', 'host', 'entry_id'} or not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,62}', device['name']):
            raise ValueError('Invalid device metadata.')
        old_address = ipaddress.IPv4Address(device['host'])
        if not old_address.is_private or old_address.is_loopback: raise ValueError('Expected an existing private LAN endpoint.')
        original = read_private(args.network_file)
        network = json.loads(original)
        wifi = network['wifi']
        password = read_private(Path(wifi['passphraseFile'])).removesuffix('\n')
        if not 8 <= len(password) <= 63: raise ValueError('Unsupported access-point passphrase.')
        neighbors = subprocess.run(['ip', 'netns', 'exec', 'devices', 'ip', '-j', 'neigh', 'show'],
                                   capture_output=True, text=True, timeout=10, check=True)
        occupied = [n['dst'] for n in json.loads(neighbors.stdout) if ':' not in n['dst']]
        used_ports = []
        for port in range(19100, 19200):
            with socket.socket() as probe:
                try: probe.bind(('127.0.0.1', port))
                except OSError: used_ports.append(port)
        grant = proposal(network, occupied, used_ports)
        if 'bluetooth-proxy' in network.get('tcp', {}): raise ValueError('A proxy grant already exists; preserve its configuration.')
        gateway = ipaddress.IPv4Interface(network['address'])
        values = {'node_name': device['name'], 'wifi_ssid': wifi['ssid'], 'wifi_password': password,
                  'static_ip': grant['targetAddress'], 'gateway': str(gateway.ip), 'subnet': str(gateway.netmask),
                  'api_encryption_key': base64.b64encode(secrets.token_bytes(32)).decode(),
                  'ota_password': secrets.token_hex(24)}
        plan = {'network_sha256': hashlib.sha256(original.encode()).hexdigest(),
                'grant_name': 'bluetooth-proxy', 'grant': grant, 'previous_endpoint': device,
                'esphome_version': '2026.10.0',
                'status': 'proposal_only; verify address availability and Wi-Fi coverage before applying'}
        parent = args.project_dir.parent
        parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != 0 or stat.S_IMODE(info.st_mode) != 0o700:
            raise ValueError('Project parent must be root-only.')
        args.project_dir.mkdir(mode=0o700)  # Never overwrite an existing key/project.
        private_write(args.project_dir/'secrets.yaml', values)
        private_write(args.project_dir/'plan.json', plan)
        private_write(args.project_dir/'bluetooth-proxy.yaml', args.template.read_text())
        # A private working copy allows the invoking administrator to compile
        # without running downloaded build tools as root. It contains secrets.
        export = Path(tempfile.mkdtemp(prefix='caz-proxy-build-', dir='/tmp'))
        for name in ('secrets.yaml', 'plan.json', 'bluetooth-proxy.yaml'):
            shutil.copyfile(args.project_dir/name, export/name)
            (export/name).chmod(0o600)
            os.chown(export/name, uid, gid)
        os.chown(export, uid, gid)
        print('Private firmware project prepared. No grant, Wi-Fi, firmware, or HA entry was changed.')
        print('Private build directory:', export)
        print('Contains Wi-Fi and API credentials. Do not paste or publish its files.')
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('Proxy preparation stopped. No running configuration changed. Check private inputs and preserve any existing project.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__': raise SystemExit(main())
