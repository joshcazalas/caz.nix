"""Protocol and mutation-safety tests; no HA install or lock required."""

import asyncio
import importlib
import json
import logging
from pathlib import Path
import sys
from types import ModuleType, SimpleNamespace
import unittest

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "home-assistant/custom_components/schlage_local"
namespace = ModuleType("schlage_under_test")
namespace.__path__ = [str(PACKAGE)]
sys.modules[namespace.__name__] = namespace
p = importlib.import_module("schlage_under_test.protocol")
m = importlib.import_module("schlage_under_test.manager")
privacy = importlib.import_module("schlage_under_test.privacy")

CAPS = bytes.fromhex("01010102010403010804026400")


def reply(operation, codes, *, omit_status=False):
    fields = [(1, bytes([operation]))]
    for identifier, pin, flags in codes:
        entry = [(1, identifier), (4, b"\x00")]
        if omit_status:
            entry.pop()
        if pin is not None:
            entry.insert(1, (2, pin.encode()))
        if flags is not None:
            entry.insert(2 if pin is not None else 1, (3, flags.to_bytes(4, "little")))
        if len(fields) > 1:
            fields.append((0, b""))
        fields.append((3, p.encode(entry)))
    return p.encode(fields)


class CodecTests(unittest.TestCase):
    def test_actual_supported_configuration(self):
        self.assertEqual(p.Capabilities.parse(CAPS), p.Capabilities(4, 8, 100))

    def test_known_wire_requests(self):
        self.assertEqual(p.request(p.Operation.LIST).hex(), "010101")
        self.assertEqual(p.request(p.Operation.ADD, pin="1234").hex(), "0101030206020431323334")
        self.assertEqual(p.request(p.Operation.REMOVE, identifier=b"\x02").hex(), "0101050203010102")
        self.assertEqual(p.request(p.Operation.READ, identifiers=[b"\x00", b"\x01"]).hex(),
                         "010102020301010000000203010101")

    def test_observed_list_shape_contains_only_four_byte_identifier(self):
        # Actual field layout; synthetic opaque identifier, no private values.
        wire = bytes.fromhex("01010103060104aabbccdd")
        codes = p.response(wire, p.Operation.LIST)
        self.assertEqual(codes[0].identifier, bytes.fromhex("aabbccdd"))
        self.assertIsNone(codes[0].pin)
        self.assertIsNone(codes[0].status)
        self.assertIsNone(codes[0].flags)

    def test_observed_read_shape_preserves_all_four_flag_bytes(self):
        # Observed field sizes; synthetic ID, PIN, and flags only.
        wire = reply(2, [(bytes.fromhex("aabbccdd"), "01234", 0x80402010)])
        self.assertEqual(len(wire), 27)
        code = p.response(wire, p.Operation.READ)[0]
        self.assertEqual(code.flags, 0x80402010)
        self.assertEqual(code.pin, "01234")
        self.assertEqual(code.status, 0)
        self.assertNotIn("01234", repr(code))

    def test_single_byte_flags_supported_and_other_sizes_rejected(self):
        for flags in (b"\x80", b"", b"\x00" * 2, b"\x00" * 3, b"\x00" * 5):
            entry = [(1, b"id"), (2, b"01234"), (3, flags), (4, b"\x00")]
            wire = p.encode([(1, b"\x02"), (3, p.encode(entry))])
            with self.subTest(length=len(flags)):
                if len(flags) == 1:
                    self.assertEqual(p.response(wire, p.Operation.READ)[0].flags, 128)
                else:
                    with self.assertRaises(p.ProtocolError):
                        p.response(wire, p.Operation.READ)

    def test_read_requires_pin_but_not_optional_status_or_flags(self):
        code = p.response(reply(2, [(b"\x01", "1234", None)], omit_status=True), p.Operation.READ)[0]
        self.assertEqual(code.pin, "1234")
        with self.assertRaises(p.ProtocolError):
            p.response(reply(2, [(b"\x01", None, None)], omit_status=True), p.Operation.READ)

    def test_bulk_and_opaque_identifiers(self):
        wire = reply(1, [(b"\x00", "1234", 0), (b"\x01\x00\xff", "56789", 8)])
        codes = p.response(wire, p.Operation.LIST)
        self.assertEqual(codes[1].identifier, b"\x01\x00\xff")
        self.assertEqual(codes[1].flags, 8)
        self.assertNotIn("56789", repr(codes))

    def test_empty_list_requires_operation(self):
        self.assertEqual(p.response(bytes.fromhex("010101"), p.Operation.LIST), [])
        with self.assertRaises(p.ProtocolError):
            p.response(b"", p.Operation.LIST)

    def test_fragmentation(self):
        value = bytes(range(256)) * 3
        self.assertEqual(p.decode(p.encode([(3, value)])), [(3, value)])
        fields = [(3, b"a" * 255), (0, b""), (3, b"b")]
        self.assertEqual(p.decode(p.encode(fields)), fields)

    def test_malformed_response_does_not_leak_pin(self):
        bad = reply(1, [(b"\x01", "secret-pin", 0)])
        with self.assertRaises(p.ProtocolError) as caught:
            p.response(bad, p.Operation.LIST)
        self.assertNotIn("secret-pin", str(caught.exception))
        for wire in (b"\x01", b"\x01\x03\x01", b"\x01\x01\x03"):
            with self.subTest(wire=wire), self.assertRaises(p.ProtocolError):
                p.response(wire, p.Operation.LIST)

    def test_duplicates_and_incomplete_record_rejected(self):
        for wire in (
            reply(1, [(b"\x01", "1234", 0), (b"\x01", "5678", 0)]),
            p.encode([(1, b"\x01"), (3, p.encode([(2, b"1234")]))]),
        ):
            with self.assertRaises(p.ProtocolError):
                p.response(wire, p.Operation.LIST)

    def test_complete_record_can_omit_status_without_inventing_success(self):
        for op in p.Operation:
            with self.subTest(operation=op):
                wire = reply(op, [(b"\x02", "001234", 0)], omit_status=True)
                code = p.response(wire, op)[0]
                self.assertEqual(code.identifier, b"\x02")
                self.assertEqual(code.pin, "001234")
                self.assertIsNone(code.status)

    def test_explicit_failure_or_malformed_status_still_rejected(self):
        for status in (b"\x04", b"", b"\x00\x00"):
            entry = [(1, b"\x02"), (2, b"001234"), (3, b"\x00"), (4, status)]
            with self.subTest(length=len(status)), self.assertRaises(p.ProtocolError):
                p.response(p.encode([(1, b"\x01"), (3, p.encode(entry))]), p.Operation.LIST)

    def test_response_diagnostic_contains_only_structure(self):
        wire = reply(1, [(b"opaque-id", "001234", 0)], omit_status=True)
        summary = p.response_structure(wire)
        self.assertEqual(summary["fields"][1]["fields"], [
            {"type": 1, "length": 9}, {"type": 2, "length": 6}, {"type": 3, "length": 4},
        ])
        for value in ("001234", "opaque-id", b"001234".hex(), b"opaque-id".hex()):
            self.assertNotIn(value, json.dumps(summary))

    def test_pin_validation_preserves_leading_zeroes(self):
        caps = p.Capabilities.parse(CAPS)
        caps.validate_pin("001234")
        for pin in ("١٢٣٤", "１２３４", "123", "123456789", "12 34", "12\n34"):
            with self.subTest(pin=pin), self.assertRaises(p.ProtocolError):
                caps.validate_pin(pin)

    def test_logging_redacts_pin_in_both_directions(self):
        filt = privacy.SensitiveTrafficFilter()
        for msg in ("Received {'type': 'schlage_local/command', 'pin': '001234'}",
                    'Sending {"result":{"schlage_local":true,"pin":"001234"}}'):
            record = logging.LogRecord("homeassistant.components.websocket_api.http.connection", 10, "", 0, msg, (), None)
            self.assertTrue(filt.filter(record))
            self.assertNotIn("001234", record.getMessage())
        record = logging.LogRecord("aiohomekit.protocol.tlv", 10, "", 0, "PIN 001234", (), None)
        self.assertFalse(filt.filter(record))


class MemoryStore:
    data = None

    async def async_load(self):
        return self.data

    async def async_save(self, data):
        self.data = json.loads(json.dumps(data))


class FakeTransport:
    def __init__(self):
        self.codes = [(b"\x00\xff", "001234", 0)]
        self.commands = []
        self.lose_ack = False
        self.ignore_write = False
        self.omit_status = False
        self.identifiers_only = False
        self.wrong_read_id = False
        self.read_without_pin = False
        self.empty_ack = False
        self.running = 0
        self.peak = 0

    async def capabilities(self):
        return CAPS

    async def command(self, payload):
        self.running += 1
        self.peak = max(self.peak, self.running)
        await asyncio.sleep(0)
        self.running -= 1
        fields = p.decode(payload)
        op = p.singletons([(tag, value) for tag, value in fields if tag == 1])[1][0]
        self.commands.append(op)
        if op == 1:
            if self.identifiers_only:
                return reply(op, [(identifier, None, None) for identifier, _, _ in self.codes], omit_status=True)
            return reply(op, self.codes, omit_status=self.omit_status)
        if op == 2:
            ids = [p.singletons(p.decode(value))[1] for tag, value in fields if tag == 2]
            codes = [code for code in self.codes if code[0] in ids]
            if self.wrong_read_id:
                codes = [(b"wrong-id", code[1], code[2]) for code in codes]
            if self.read_without_pin:
                codes = [(code[0], None, code[2]) for code in codes]
            return reply(op, codes, omit_status=self.omit_status)
        entry = p.singletons(p.decode(p.singletons(fields)[2]))
        if op == 3:
            changed = (b"\x02\x00", entry[2].decode(), 0)
            if not self.ignore_write:
                self.codes.append(changed)
        else:
            changed = next(c for c in self.codes if c[0] == entry[1])
            if not self.ignore_write:
                self.codes.remove(changed)
        if self.lose_ack:
            raise TimeoutError("transport message containing private data")
        if self.empty_ack:
            return reply(op, [])
        if self.identifiers_only:
            return reply(op, [(changed[0], None, None)], omit_status=True)
        return reply(op, [changed], omit_status=self.omit_status)

    async def auto_lock(self, seconds=None, expected=None):
        if not hasattr(self, "timeout"):
            self.timeout = 0
        if seconds is not None:
            if self.timeout != expected:
                raise p.ProtocolError("Setting changed.")
            self.timeout = seconds
        return {"seconds": self.timeout, "minimum": 0, "maximum": 300}

    async def inspect_logs(self):
        return {"bytes": 0, "fields": [], "tlv": True, "notifications": False}


class ManagerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.transport = FakeTransport()
        self.store = MemoryStore()
        model = SimpleNamespace(type="00000021-0000-1000-8000-0026BB765291", value="be499WB2")
        accessory = SimpleNamespace(services=[SimpleNamespace(characteristics=[model])])
        connection = SimpleNamespace(
            pairing=SimpleNamespace(accessories=SimpleNamespace(aid=lambda aid: accessory)),
            config_entry=SimpleNamespace(entry_id="test-lock", title="Example lock"))
        self.manager = m.Manager(lambda: [connection], self.store, lambda connection: self.transport)
        await self.manager.load()
        self.snapshot = await self.manager.execute("list", "test-lock")

    async def test_auto_lock_is_separate_from_keypad_code_reads(self):
        before = list(self.transport.commands)
        self.assertEqual((await self.manager.execute("settings", "test-lock"))["auto_lock"]["seconds"], 0)
        result = await self.manager.execute("set_auto_lock", "test-lock", seconds=300, expected=0)
        self.assertEqual(result["auto_lock"]["seconds"], 300)
        self.assertEqual(self.transport.commands, before)
        self.assertEqual(self.store.data["locks"]["test-lock"]["events"][0]["action"], "auto_lock_changed")
        for kwargs in ({}, {"seconds": True, "expected": 300}, {"seconds": 0}):
            with self.assertRaises(p.ProtocolError):
                await self.manager.execute("set_auto_lock", "test-lock", **kwargs)

    async def test_snapshot_and_storage_do_not_contain_pins(self):
        self.assertNotIn("001234", json.dumps(self.snapshot))
        self.assertNotIn("001234", json.dumps(self.store.data))
        self.assertIsNone(self.snapshot["codes"][0]["last_used"])
        self.assertEqual(self.snapshot["usage_history"], "unverified")

    async def test_add_and_remove_verified_by_reads(self):
        result = await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
        self.assertEqual(self.transport.commands[-3:], [1, 3, 1])
        code = next(c for c in result["codes"] if c["name"] == "Guest")
        self.assertNotIn("987654", json.dumps(self.store.data))
        result = await self.manager.execute("remove", "test-lock", revision=result["revision"], code_id=code["id"])
        self.assertEqual(self.transport.commands[-3:], [1, 5, 1])
        self.assertEqual(len(result["codes"]), 1)

    async def test_status_omission_still_requires_verified_change(self):
        self.transport.omit_status = True
        result = await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
        self.assertEqual(len(result["codes"]), 2)
        self.assertEqual(self.transport.commands[-3:], [1, 3, 1])
        self.transport.ignore_write = True
        with self.assertRaisesRegex(p.ProtocolError, "could not be verified"):
            await self.manager.execute("remove", "test-lock", revision=result["revision"], code_id="00ff")

    async def test_inspection_does_not_need_parser_or_issue_mutations(self):
        self.transport.omit_status = True
        result = await self.manager.execute("inspect_codes", "test-lock")
        self.assertTrue(result["structure"]["fields"])
        self.assertEqual(self.transport.commands, [1, 1, 2])
        self.assertNotIn("001234", json.dumps(result))

    async def test_identifier_only_listing_fetches_details_before_and_after_add(self):
        self.transport.identifiers_only = True
        self.transport.omit_status = True
        result = await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
        self.assertEqual(self.transport.commands[-5:], [1, 2, 3, 1, 2])
        self.assertEqual(len(result["codes"]), 2)
        self.assertTrue(all(code["can_reveal"] for code in result["codes"]))
        self.assertNotIn("987654", json.dumps(result))

    async def test_identifier_only_remove_verifies_remaining_codes(self):
        self.transport.identifiers_only = True
        result = await self.manager.execute("remove", "test-lock", revision=self.snapshot["revision"], code_id="00ff")
        self.assertEqual(self.transport.commands[-4:], [1, 2, 5, 1])
        self.assertEqual(result["codes"], [])

    async def test_incomplete_ack_requires_exact_read_back_not_a_retry(self):
        self.transport.identifiers_only = True
        self.transport.empty_ack = True
        result = await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
        self.assertEqual(len(result["codes"]), 2)
        self.assertEqual(self.transport.commands.count(3), 1)
        self.transport.ignore_write = True
        with self.assertRaisesRegex(p.ProtocolError, "could not be verified"):
            await self.manager.execute("remove", "test-lock", revision=result["revision"], code_id="00ff")
        self.assertEqual(self.transport.commands.count(5), 1)

    async def test_read_mismatch_or_missing_pin_blocks_mutation(self):
        self.transport.identifiers_only = True
        for attribute in ("wrong_read_id", "read_without_pin"):
            setattr(self.transport, attribute, True)
            with self.subTest(attribute=attribute), self.assertRaises(p.ProtocolError):
                await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
            setattr(self.transport, attribute, False)
        self.assertNotIn(3, self.transport.commands)

    async def test_many_identifiers_are_read_in_bounded_batches(self):
        self.transport.identifiers_only = True
        self.transport.codes = [(i.to_bytes(4, "little"), f"{i + 1000:04}", 0) for i in range(41)]
        result = await self.manager.execute("list", "test-lock")
        self.assertEqual(len(result["codes"]), 41)
        self.assertEqual(self.transport.commands[-4:], [1, 2, 2, 2])

    async def test_identifier_reuse_blocks_stale_delete(self):
        self.transport.codes[0] = (b"\x00\xff", "999999", 0)
        with self.assertRaisesRegex(p.ProtocolError, "changed"):
            await self.manager.execute("remove", "test-lock", revision=self.snapshot["revision"], code_id="00ff")
        self.assertNotIn(5, self.transport.commands)

    async def test_high_flag_bits_changing_block_stale_delete(self):
        identifier, pin, _ = self.transport.codes[0]
        self.transport.codes[0] = (identifier, pin, 0x80000000)
        with self.assertRaisesRegex(p.ProtocolError, "changed"):
            await self.manager.execute("remove", "test-lock", revision=self.snapshot["revision"], code_id="00ff")
        self.assertNotIn(5, self.transport.commands)

    async def test_lost_ack_never_retries_write(self):
        self.transport.lose_ack = True
        with self.assertRaisesRegex(p.ProtocolError, "may have reached"):
            await self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name="Guest", pin="987654")
        self.assertEqual(self.transport.commands.count(3), 1)
        self.assertEqual(self.store.data["locks"]["test-lock"]["events"][0]["action"], "add_unverified")
        self.assertNotIn("987654", json.dumps(self.store.data))

    async def test_success_ack_is_not_enough(self):
        self.transport.ignore_write = True
        with self.assertRaisesRegex(p.ProtocolError, "could not be verified"):
            await self.manager.execute("remove", "test-lock", revision=self.snapshot["revision"], code_id="00ff")
        self.assertEqual(len(self.transport.codes), 1)

    async def test_concurrent_changes_are_serialized(self):
        outcomes = await asyncio.gather(*[
            self.manager.execute("add", "test-lock", revision=self.snapshot["revision"], name=name, pin=pin)
            for name, pin in (("One", "111111"), ("Two", "222222"))
        ], return_exceptions=True)
        self.assertEqual(sum(isinstance(x, p.ProtocolError) for x in outcomes), 1)
        self.assertEqual(self.transport.commands.count(3), 1)
        self.assertEqual(self.transport.peak, 1)

    async def test_names_survive_restart_and_old_revision_does_not(self):
        await self.manager.execute("rename", "test-lock", revision=self.snapshot["revision"], code_id="00ff", name="Example user")
        restarted = m.Manager(self.manager.connections, self.store, lambda _: self.transport)
        await restarted.load()
        result = await restarted.execute("list", "test-lock")
        self.assertEqual(result["codes"][0]["name"], "Example user")
        self.assertNotEqual(result["revision"], self.snapshot["revision"])

    async def test_reveal_only_explicitly_and_no_persistent_pin(self):
        result = await self.manager.execute("reveal", "test-lock", revision=self.snapshot["revision"], code_id="00ff")
        self.assertEqual(result["pin"], "001234")
        self.assertNotIn("001234", json.dumps(self.store.data))


if __name__ == "__main__":
    unittest.main()
