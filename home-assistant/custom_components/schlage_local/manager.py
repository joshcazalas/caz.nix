"""Code management with verified writes and PIN-free persistent metadata."""

import asyncio
import hashlib
import hmac
import json
import secrets
from dataclasses import asdict
from datetime import datetime, timezone

from .protocol import Capabilities, CommandRejected, Operation, ProtocolError, request, response, response_structure


def now():
    return datetime.now(timezone.utc).isoformat()


class Manager:
    def __init__(self, connections, store, transport_factory=None):
        if transport_factory is None:
            from .transport import Transport

            transport_factory = Transport
        self.connections = connections
        self.store = store
        self.transport_factory = transport_factory
        self.metadata = {"locks": {}}
        self.locks = {}
        self.revision_key = secrets.token_bytes(32)

    async def load(self):
        self.metadata = await self.store.async_load() or {"locks": {}}

    def discover(self):
        devices = []
        for connection in self.connections():
            try:
                accessory = connection.pairing.accessories.aid(1)
                chars = {c.type.upper(): c.value for s in accessory.services for c in s.characteristics}
                model = str(chars.get("00000021-0000-1000-8000-0026BB765291", ""))
                if not model.lower().startswith("be499"):
                    continue
                self.transport_factory(connection)
            except (ProtocolError, AttributeError, KeyError):
                continue
            devices.append({"id": connection.config_entry.entry_id,
                            "name": connection.config_entry.title, "model": model})
        return devices

    def _transport(self, lock_id):
        for connection in self.connections():
            if connection.config_entry.entry_id == lock_id:
                if lock_id not in {item["id"] for item in self.discover()}:
                    raise ProtocolError("This lock or HomeKit transport is not supported.")
                return self.transport_factory(connection)
        raise ProtocolError("The paired lock is not loaded. Check HomeKit Device in HA.")

    def _data(self, lock_id):
        return self.metadata["locks"].setdefault(lock_id, {"names": {}, "events": []})

    def _revision(self, codes):
        # A short PIN must not be exposed as a guessable hash. This token uses
        # an ephemeral server-only HMAC key and changes after every HA restart.
        payload = json.dumps(sorted((c.identifier.hex(), c.pin, c.flags) for c in codes)).encode()
        return hmac.new(self.revision_key, payload, hashlib.sha256).hexdigest()

    async def _read(self, transport):
        capabilities = Capabilities.parse(await transport.capabilities())
        codes = response(await transport.command(request(Operation.LIST)), Operation.LIST)
        if len(codes) > capabilities.capacity:
            raise ProtocolError("The code count exceeds the lock's reported capacity.")
        missing = [code.identifier for code in codes if code.pin is None]
        details = {}
        for offset in range(0, len(missing), 20):
            batch = missing[offset : offset + 20]
            read_codes = response(
                await transport.command(request(Operation.READ, identifiers=batch)), Operation.READ
            )
            if {code.identifier for code in read_codes} != set(batch):
                raise ProtocolError("The lock returned details for different code IDs. Refresh the list.")
            details.update((code.identifier, code) for code in read_codes)
        codes = [details.get(code.identifier, code) for code in codes]
        for code in codes:
            if code.pin is not None:
                capabilities.validate_pin(code.pin)
        return capabilities, codes

    async def _save_event(self, lock_id, action, identifier, name):
        data = self._data(lock_id)
        data["events"].insert(0, {"time": now(), "action": action,
                                  "code_id": identifier, "name": name})
        del data["events"][200:]
        await self.store.async_save(self.metadata)

    def _snapshot(self, lock_id, capabilities, codes):
        data = self._data(lock_id)
        return {
            "schlage_local": True,  # Marks responses for websocket log redaction.
            "lock_id": lock_id,
            "capabilities": asdict(capabilities),
            "revision": self._revision(codes),
            "read_at": now(),
            "codes": [{"id": code.identifier.hex(),
                       "name": data["names"].get(code.identifier.hex(), ""),
                       "flags": code.flags, "can_reveal": code.pin is not None,
                       "last_used": None} for code in codes],
            "usage_history": "unverified",
            "events": data["events"],
        }

    async def execute(self, action, lock_id, *, revision=None, code_id=None, name=None, pin=None, seconds=None, expected=None):
        async with self.locks.setdefault(lock_id, asyncio.Lock()):
            transport = self._transport(lock_id)
            if action in ("settings", "set_auto_lock"):
                if action == "set_auto_lock" and (type(seconds) is not int or type(expected) is not int):
                    raise ProtocolError("Read auto-lock first, then choose a timeout in seconds.")
                setting = await transport.auto_lock(seconds if action == "set_auto_lock" else None, expected)
                if action == "set_auto_lock":
                    await self._save_event(lock_id, "auto_lock_changed", None,
                                           "Off" if setting["seconds"] == 0 else f'{setting["seconds"]} seconds')
                return {"schlage_local": True, "auto_lock": setting}
            if action == "logs":
                return {"schlage_local": True, "logs": await transport.inspect_logs()}
            if action == "inspect_codes":
                payload = await transport.command(request(Operation.LIST))
                result = {"schlage_local": True, "structure": response_structure(payload)}
                listed = response(payload, Operation.LIST)
                # Inspect only the first record; no values leave this method.
                if listed:
                    read_payload = await transport.command(request(Operation.READ, identifiers=[listed[0].identifier]))
                    result["read_structure"] = response_structure(read_payload)
                    try:
                        response(read_payload, Operation.READ)
                    except ProtocolError as err:
                        result["read_decode_error"] = str(err)
                return result
            capabilities, codes = await self._read(transport)
            data = self._data(lock_id)
            identifiers = {code.identifier.hex(): code for code in codes}
            if action == "list":
                # Forget labels for deleted codes, but retain the management log.
                data["names"] = {key: value for key, value in data["names"].items() if key in identifiers}
                await self.store.async_save(self.metadata)
                return self._snapshot(lock_id, capabilities, codes)
            if not isinstance(revision, str) or not hmac.compare_digest(revision, self._revision(codes)):
                raise ProtocolError("The lock's code list changed. Refresh and try again.")
            if action in ("remove", "rename", "reveal") and code_id not in identifiers:
                raise ProtocolError("That code is no longer on the lock. Refresh the list.")
            if action in ("add", "rename"):
                if not isinstance(name, str) or not name.strip() or len(name.strip()) > 64:
                    raise ProtocolError("Enter a name between 1 and 64 characters.")
                name = name.strip()
            if action == "reveal":
                return {"schlage_local": True, "pin": identifiers[code_id].pin}
            if action == "rename":
                data["names"][code_id] = name
                await self._save_event(lock_id, "renamed", code_id, name)
                return self._snapshot(lock_id, capabilities, codes)
            if action not in ("add", "remove"):
                raise ProtocolError("Unsupported code action.")
            if action == "add":
                if not isinstance(pin, str):
                    raise ProtocolError("Enter a PIN.")
                capabilities.validate_pin(pin)
                if len(codes) >= capabilities.capacity:
                    raise ProtocolError("The lock has reached its code capacity.")
                if any(code.pin == pin for code in codes):
                    raise ProtocolError("That code already exists.")
                operation = Operation.ADD
                payload = request(operation, pin=pin)
            else:
                operation = Operation.REMOVE
                payload = request(operation, identifier=identifiers[code_id].identifier)
                name = data["names"].get(code_id, "")
            try:
                raw_acknowledgement = await transport.command(payload)
                try:
                    acknowledged = response(raw_acknowledgement, operation)[0]
                except CommandRejected:
                    raise
                except ProtocolError:
                    # A malformed/incomplete acknowledgement is not success.
                    # Only the exact read-back postcondition below can prove it.
                    acknowledged = None
                if action == "remove" and acknowledged and acknowledged.identifier != identifiers[code_id].identifier:
                    raise ProtocolError("The lock acknowledged a different code.")
                if action == "add" and acknowledged and acknowledged.pin is not None and acknowledged.pin != pin:
                    raise ProtocolError("The lock acknowledged a different PIN.")
                capabilities, updated = await self._read(transport)
                updated_ids = {code.identifier.hex(): code for code in updated}
                if action == "add":
                    new_codes = [code for key, code in updated_ids.items() if key not in identifiers and code.pin == pin]
                    if len(new_codes) != 1:
                        raise ProtocolError("The added code could not be verified.")
                    code_id = new_codes[0].identifier.hex()
                    if acknowledged and code_id != acknowledged.identifier.hex():
                        raise ProtocolError("The acknowledged code ID does not match the read-back result.")
                    # Confirm that adding one code did not replace other codes.
                    if len(updated_ids) != len(identifiers) + 1 or any(updated_ids.get(key) != value for key, value in identifiers.items()):
                        raise ProtocolError("Other codes changed during the operation.")
                    data["names"][code_id] = name
                else:
                    if len(updated_ids) != len(identifiers) - 1 or code_id in updated_ids or any(updated_ids.get(key) != value for key, value in identifiers.items() if key != code_id):
                        raise ProtocolError("The removed code could not be verified.")
                    data["names"].pop(code_id, None)
            except Exception as err:
                # A device rejection and a lost acknowledgement are both followed
                # by a fresh read before the next attempt. Never repeat a write.
                await self._save_event(lock_id, f"{action}_unverified", code_id, name)
                raise ProtocolError(
                    "The change could not be verified. It may have reached the lock. "
                    "Refresh the list and test at the keypad before trying again."
                    + (f" Response detail: {err}" if isinstance(err, ProtocolError) else "")
                ) from None
            await self._save_event(lock_id, "added" if action == "add" else "removed", code_id, name)
            return self._snapshot(lock_id, capabilities, updated)
