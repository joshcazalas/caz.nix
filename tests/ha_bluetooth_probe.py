"""Exercise Bluetooth access from the HA container fixture, without a radio."""

import ctypes
import errno
import json
import os
from pathlib import Path
import socket
import struct
import subprocess


enabled = os.environ["EXPECT_BLUETOOTH"] == "1"
status = dict(line.split(":", 1) for line in Path("/proc/self/status").read_text().splitlines())
capabilities = int(status["CapEff"].strip(), 16)
net_admin = 1 << 12
net_raw = 1 << 13
assert bool(capabilities & net_admin) == enabled

if enabled:
    assert capabilities & net_raw
    # This must work from inside the container on its first start: it tests
    # BlueZ availability, the socket mount, bus policy and startup ordering.
    subprocess.run(
        ["/bin/dbus-send", "--system", "--print-reply", "--reply-timeout=5000",
         "--dest=org.bluez", "/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"],
        env={**os.environ, "DBUS_SYSTEM_BUS_ADDRESS": "unix:path=/run/dbus/system_bus_socket"},
        check=True,
        timeout=10,
    )
    # Read the kernel management API version; no real controller is required.
    with socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI) as management:
        management.settimeout(5)
        # Python 3.13's HCI bind wrapper cannot select a channel. Pass the
        # Linux sockaddr_hci directly: family, HCI_DEV_NONE, CONTROL channel.
        address = ctypes.create_string_buffer(struct.pack("=HHH", socket.AF_BLUETOOTH, 0xFFFF, 3))
        bind = ctypes.CDLL(None, use_errno=True).bind
        bind.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
        bind.restype = ctypes.c_int
        if bind(management.fileno(), address, 6) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error))
        management.sendall(struct.pack("<HHH", 1, 0xFFFF, 0))
        reply = management.recv(1024)
        event, index, length = struct.unpack_from("<HHH", reply)
        opcode, result = struct.unpack_from("<HB", reply, 6)
        assert (event, index, opcode, result) == (1, 0xFFFF, 1, 0), reply.hex()
        assert length == len(reply) - 6
    try:
        Path("/run/dbus/probe-must-not-write").touch()
    except PermissionError:
        pass
    except OSError as error:
        assert error.errno == errno.EROFS, error
    else:
        raise AssertionError("Host D-Bus directory is writable from the container")
else:
    assert not Path("/run/dbus/system_bus_socket").exists()

Path("/config/bluetooth-probe.json").write_text(json.dumps({"enabled": enabled}))
os.execv("/bin/sleep", ["sleep", "infinity"])
