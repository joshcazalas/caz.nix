"""Compatibility checks against HA 2026.8.3 and aiohomekit 4.0.0.

Run with the pinned HA dependencies installed; never contacts a real lock.
"""

import asyncio
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import AsyncMock, MagicMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "home-assistant"))

from aiohomekit.controller.ble.pairing import BlePairing
from aiohomekit.model import Accessories, Accessory
from aiohomekit.pdu import OpCode
from homeassistant.core import HomeAssistant
from homeassistant.exceptions import Unauthorized

from custom_components import schlage_local as integration
from custom_components.schlage_local import protocol as p
from custom_components.schlage_local.transport import Transport


class TransportTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.pairing = MagicMock(spec=BlePairing)
        self.pairing._operation_lock = asyncio.Lock()
        self.pairing._shutdown = False
        self.pairing._restore_pending = True
        self.pairing._populate_accessories_and_characteristics = AsyncMock()
        self.pairing._async_restore_subscriptions = AsyncMock()
        self.pairing.accessories = Accessories()
        self.pairing.accessories.add_accessory(Accessory.create_from_dict({
            "aid": 1, "services": [{"iid": 16384, "type": p.SERVICE, "characteristics": [
                {"iid": 16387, "type": p.SUPPORTED, "format": "data", "perms": ["pr"]},
                {"iid": 16388, "type": p.CONTROL, "format": "data", "perms": ["pr", "pw"]},
            ]}]}))
        self.transport = Transport(SimpleNamespace(pairing=self.pairing))

    async def test_response_requested_and_decoded_under_existing_operation_lock(self):
        async def exchange(opcode, char, payload):
            self.assertTrue(self.pairing._operation_lock.locked())
            self.assertEqual(opcode, OpCode.CHAR_WRITE)
            self.assertEqual(char.iid, 16388)
            self.assertEqual(p.singletons(p.decode(payload)), {9: b"\x01", 1: b"\x01\x01\x01"})
            return p.encode([(1, b"\x01\x01\x01")])
        self.pairing._async_request = AsyncMock(side_effect=exchange)
        self.assertEqual(await self.transport.command(p.request(p.Operation.LIST)), b"\x01\x01\x01")
        self.pairing._async_restore_subscriptions.assert_awaited_once()
        self.assertFalse(self.pairing._operation_lock.locked())

    async def test_mutation_timeout_never_retries_and_restores_subscription(self):
        self.pairing._async_request = AsyncMock(side_effect=TimeoutError())
        with self.assertRaises(TimeoutError):
            await self.transport.command(p.request(p.Operation.ADD, pin="1234"))
        self.pairing._async_request.assert_awaited_once()
        self.pairing._async_restore_subscriptions.assert_awaited_once()
        self.assertFalse(self.pairing._operation_lock.locked())

    async def test_capability_read_does_not_write(self):
        self.pairing._async_request = AsyncMock(return_value=p.encode([(1, b"capabilities")]))
        self.assertEqual(await self.transport.capabilities(), b"capabilities")
        args = self.pairing._async_request.call_args.args
        self.assertEqual(args[0], OpCode.CHAR_READ)
        self.assertEqual(args[1].iid, 16387)

    async def test_unknown_dependency_version_blocks_commands(self):
        with patch("custom_components.schlage_local.transport.version", return_value="5.0.0"):
            with self.assertRaisesRegex(p.ProtocolError, "needs review"):
                Transport(SimpleNamespace(pairing=self.pairing))


class AutoLockTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        await TransportTests.asyncSetUp(self)
        self.pairing.accessories = Accessories()
        self.pairing.accessories.add_accessory(Accessory.create_from_dict({
            "aid": 1, "services": [{"iid": 10, "type": "44", "characteristics": [
                {"iid": 11, "type": "1A", "format": "uint32", "unit": "seconds",
                 "minValue": 0, "maxValue": 300, "perms": ["pr", "pw"]},
            ]}]}))
        self.value = 0
        self.writes = 0
        self.ignore = False
        self.lose = False

        async def exchange(opcode, char, payload=None):
            self.assertTrue(self.pairing._operation_lock.locked())
            self.assertEqual(char.type, "0000001A-0000-1000-8000-0026BB765291")
            if opcode == OpCode.CHAR_READ:
                return p.encode([(1, self.value.to_bytes(4, "little"))])
            self.assertEqual(opcode, OpCode.CHAR_WRITE)
            self.writes += 1
            fields = p.singletons(p.decode(payload))
            self.assertEqual(set(fields), {1})
            self.assertEqual(len(fields[1]), 4)
            if not self.ignore:
                self.value = int.from_bytes(fields[1], "little")
            if self.lose:
                raise TimeoutError("untrusted transport details")
            return b""
        self.pairing._async_request = AsyncMock(side_effect=exchange)

    async def test_read_does_not_change_setting(self):
        result = await self.transport.auto_lock()
        self.assertEqual(result["seconds"], 0)
        self.assertEqual(result["maximum"], 300)
        self.assertEqual(self.writes, 0)

    async def test_set_verify_disable_and_idempotence(self):
        self.assertEqual((await self.transport.auto_lock(300, 0))["seconds"], 300)
        self.assertEqual(self.writes, 1)
        await self.transport.auto_lock(300, 300)
        self.assertEqual(self.writes, 1)
        self.assertEqual((await self.transport.auto_lock(0, 300))["seconds"], 0)
        self.assertEqual(self.writes, 2)

    async def test_reject_out_of_range_boolean_and_stale_requests(self):
        for seconds, expected in [(301, 0), (-1, 0), (True, 0), (300, True), (300, 60)]:
            with self.subTest(seconds=seconds, expected=expected), self.assertRaises(p.ProtocolError):
                await self.transport.auto_lock(seconds, expected)
        self.assertEqual(self.writes, 0)

    async def test_failed_verification_and_lost_ack_do_not_retry(self):
        self.ignore = True
        with self.assertRaisesRegex(p.ProtocolError, "could not be verified"):
            await self.transport.auto_lock(300, 0)
        self.assertEqual(self.writes, 1)
        self.ignore = False
        self.lose = True
        with self.assertRaisesRegex(p.ProtocolError, "may have reached"):
            await self.transport.auto_lock(300, 0)
        self.assertEqual(self.writes, 2)
        self.assertEqual(self.value, 300)

    async def test_requires_declared_format_and_permissions(self):
        char = self.pairing.accessories.aid(1).characteristics.iid(11)
        char.perms = ["pr"]
        with self.assertRaises(p.ProtocolError):
            await self.transport.auto_lock(300, 0)
        char.format = "uint8"
        with self.assertRaises(p.ProtocolError):
            await self.transport.auto_lock()
        self.assertEqual(self.writes, 0)



class HATests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.hass = HomeAssistant(self.directory.name)
        self.hass.http = SimpleNamespace(async_register_static_paths=AsyncMock())

    async def asyncTearDown(self):
        with patch("homeassistant.core.shutdown_run_callback_threadsafe"):
            await asyncio.wait_for(self.hass.async_stop(force=True), 3)
        self.directory.cleanup()

    async def test_setup_registers_admin_panel_and_can_reload(self):
        self.assertTrue(await integration.async_setup(self.hass, {}))
        with patch.object(integration.panel_custom, "async_register_panel", new_callable=AsyncMock) as register:
            await asyncio.wait_for(integration.async_setup_entry(self.hass, SimpleNamespace()), 5)
            self.assertTrue(register.call_args.kwargs["require_admin"])
            self.assertIn("schlage_local/command", self.hass.data["websocket_api"])
            with patch.object(integration.frontend, "async_remove_panel"):
                await integration.async_unload_entry(self.hass, SimpleNamespace())
            await asyncio.wait_for(integration.async_setup_entry(self.hass, SimpleNamespace()), 5)
            self.hass.http.async_register_static_paths.assert_awaited_once()

    async def test_non_admin_cannot_read_or_modify_codes(self):
        connection = SimpleNamespace(user=SimpleNamespace(is_admin=False))
        for action in ("list", "add", "remove", "reveal", "logs", "inspect_codes", "settings", "set_auto_lock"):
            with self.subTest(action=action), self.assertRaises(Unauthorized):
                integration.websocket_command(self.hass, connection, {"id": 1, "type": "schlage_local/command", "action": action})

    async def test_errors_never_expose_transport_payload(self):
        self.hass.data[integration.DOMAIN] = SimpleNamespace(execute=AsyncMock(side_effect=ValueError("PIN:123456")))
        connection = SimpleNamespace(user=SimpleNamespace(is_admin=True), send_error=MagicMock(), send_result=MagicMock())
        integration.websocket_command(self.hass, connection, {"id": 1, "type": "schlage_local/command", "action": "list", "lock_id": "test"})
        await self.hass.async_block_till_done(wait_background_tasks=True)
        connection.send_error.assert_called_once()
        self.assertNotIn("123456", str(connection.send_error.call_args))
        connection.send_result.assert_not_called()


if __name__ == "__main__":
    unittest.main()
