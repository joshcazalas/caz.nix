"""Small, version-gated adapter to the existing HA HomeKit BLE session.

The public put_characteristics API discards control-point responses. Use the
same internal request machinery as aiohomekit's list_pairings, with the HAP
Return Response parameter. Never create a second controller or copy its keys.
"""

import asyncio
from importlib.metadata import version

from aiohomekit.controller.ble.pairing import BlePairing
from aiohomekit.pdu import OpCode

from .protocol import CONTROL, LOGS, SERVICE, SUPPORTED, ProtocolError, decode, encode, singletons


class Transport:
    def __init__(self, connection):
        self.connection = connection
        self.pairing = connection.pairing
        if version("aiohomekit") != "4.0.0":
            raise ProtocolError("This extension needs review for the installed aiohomekit version.")
        if not isinstance(self.pairing, BlePairing):
            raise ProtocolError("This extension currently supports HomeKit over Bluetooth only.")

    def _characteristic(self, characteristic_type):
        accessory = self.pairing.accessories.aid(1)
        matches = [
            char for service in accessory.services
            for char in service.characteristics
            if char.type.upper() == characteristic_type
            and (characteristic_type == LOGS or service.type.upper() == SERVICE)
        ]
        if len(matches) != 1:
            raise ProtocolError("The lock does not expose the expected characteristic.")
        return matches[0]

    async def _exchange(self, characteristic_type, payload=None):
        pairing = self.pairing
        # No automatic retries for writes: a lost acknowledgement is ambiguous.
        # Both HA's operation lock and its encrypted BLE request lock are reused.
        async with asyncio.timeout(45), pairing._operation_lock:
            if pairing._shutdown:
                raise ProtocolError("The HomeKit connection is unloading; try again shortly.")
            try:
                await pairing._populate_accessories_and_characteristics()
                char = self._characteristic(characteristic_type)
                if payload is None:
                    if "pr" not in char.perms:
                        raise ProtocolError("This characteristic is not readable.")
                    raw = await pairing._async_request(OpCode.CHAR_READ, char)
                else:
                    if characteristic_type != CONTROL or "pw" not in char.perms or "tw" in char.perms:
                        raise ProtocolError("Unsupported access-code write permissions.")
                    raw = await pairing._async_request(
                        OpCode.CHAR_WRITE, char,
                        encode([(9, b"\x01"), (1, payload)]),
                    )
                outer = singletons(decode(raw))
                if 1 not in outer:
                    raise ProtocolError("The lock returned no control-point value.")
                # Use raw bytes: this lock advertises 'data', not base64 TLV8.
                return outer[1]
            finally:
                if not pairing._shutdown and pairing._restore_pending:
                    await pairing._async_restore_subscriptions()

    async def capabilities(self):
        return await self._exchange(SUPPORTED)

    async def command(self, payload):
        return await self._exchange(CONTROL, payload)

    async def auto_lock(self, seconds=None, expected=None):
        """Read or compare-and-set only the standard auto-secure timeout.

        HAP type 1A, UInt32 seconds, belongs to Lock Management (44).
        No arbitrary characteristic access, pairing changes, or bolt command.
        """
        pairing = self.pairing
        async with asyncio.timeout(45), pairing._operation_lock:
            if pairing._shutdown:
                raise ProtocolError("The HomeKit connection is unloading; try again shortly.")
            try:
                await pairing._populate_accessories_and_characteristics()
                matches = [char for service in pairing.accessories.aid(1).services
                           if service.type.upper() == "00000044-0000-1000-8000-0026BB765291"
                           for char in service.characteristics
                           if char.type.upper() == "0000001A-0000-1000-8000-0026BB765291"]
                if len(matches) != 1:
                    raise ProtocolError("This lock does not expose a supported built-in auto-lock setting.")
                char = matches[0]
                if char.format != "uint32" or char.unit != "seconds" or "pr" not in char.perms:
                    raise ProtocolError("The auto-lock setting has an unsupported format.")
                minimum, maximum = char.minValue, char.maxValue
                if type(minimum) is not int or type(maximum) is not int or not 0 <= minimum <= maximum <= 86400:
                    raise ProtocolError("The lock did not provide supported auto-lock limits.")

                async def read():
                    outer = singletons(decode(await pairing._async_request(OpCode.CHAR_READ, char)))
                    raw = outer.get(1, b"")
                    if len(raw) != 4:
                        raise ProtocolError("The lock returned an invalid auto-lock timeout.")
                    value = int.from_bytes(raw, "little")
                    if not minimum <= value <= maximum:
                        raise ProtocolError("The lock returned an out-of-range auto-lock timeout.")
                    return value

                current = await read()
                if seconds is not None:
                    if type(seconds) is not int or not minimum <= seconds <= maximum:
                        raise ProtocolError("Choose an auto-lock timeout within the lock's limits.")
                    if char.minStep and (seconds - minimum) % char.minStep:
                        raise ProtocolError("Choose a supported auto-lock interval.")
                    if char.valid_values and seconds not in char.valid_values:
                        raise ProtocolError("Choose a supported auto-lock interval.")
                    if type(expected) is not int or current != expected:
                        raise ProtocolError("Auto-lock changed. Read the setting again before saving.")
                    if "pw" not in char.perms or "tw" in char.perms:
                        raise ProtocolError("This auto-lock setting cannot be changed by this extension.")
                    if current != seconds:
                        try:
                            await pairing._async_request(
                                OpCode.CHAR_WRITE, char, encode([(1, seconds.to_bytes(4, "little"))])
                            )
                            current = await read()
                            if current != seconds:
                                raise ProtocolError("Auto-lock read-back did not match the requested timeout.")
                        except Exception:
                            raise ProtocolError(
                                "The auto-lock change could not be verified. It may have reached the lock. "
                                "Read the setting again before trying another change."
                            ) from None
                return {"seconds": current, "minimum": minimum, "maximum": maximum,
                        "step": char.minStep or 1, "valid_values": char.valid_values,
                        "writable": "pw" in char.perms and "tw" not in char.perms}
            finally:
                if not pairing._shutdown and pairing._restore_pending:
                    await pairing._async_restore_subscriptions()

    async def inspect_logs(self):
        payload = await self._exchange(LOGS)
        # Only structural information leaves the backend. Unknown log payloads
        # could themselves contain credentials, so do not publish their bytes.
        try:
            fields = [{"type": tag, "length": len(value)} for tag, value in decode(payload)]
            valid_tlv = True
        except ProtocolError:
            fields, valid_tlv = [], False
        return {"bytes": len(payload), "tlv": valid_tlv, "fields": fields,
                "notifications": "ev" in self._characteristic(LOGS).perms}
