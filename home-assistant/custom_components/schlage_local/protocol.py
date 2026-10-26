"""Strict codec for the HomeKit Access Code service (no HA dependency).

Protocol research: https://github.com/rednblkx/homekit-lock-access-code
Identifiers are opaque bytes, not slot numbers. Unknown flags stay unknown.
"""

from dataclasses import dataclass, field
from enum import IntEnum

BASE_UUID = "-0000-1000-8000-0026BB765291"
SERVICE = "00000260" + BASE_UUID
SUPPORTED = "00000261" + BASE_UUID
CONTROL = "00000262" + BASE_UUID
LOGS = "0000001F" + BASE_UUID


class ProtocolError(Exception):
    """A safe-to-display protocol error, never containing a PIN/payload."""


class CommandRejected(ProtocolError):
    """The device explicitly rejected a command, rather than losing its reply."""


class Operation(IntEnum):
    LIST = 1
    READ = 2
    ADD = 3
    REMOVE = 5


def encode(items: list[tuple[int, bytes]]) -> bytes:
    output = bytearray()
    for tag, value in items:
        if not 0 <= tag <= 255:
            raise ProtocolError("Invalid TLV tag.")
        if not value:
            output.extend((tag, 0))
        for offset in range(0, len(value), 255):
            chunk = value[offset : offset + 255]
            output.extend((tag, len(chunk)))
            output.extend(chunk)
    return bytes(output)


def decode(payload: bytes) -> list[tuple[int, bytes]]:
    if len(payload) > 65536:
        raise ProtocolError("Response exceeds the supported size.")
    result: list[tuple[int, bytes]] = []
    offset = previous_length = 0
    while offset < len(payload):
        if len(payload) - offset < 2:
            raise ProtocolError("Truncated TLV header.")
        tag, length = payload[offset : offset + 2]
        offset += 2
        if offset + length > len(payload):
            raise ProtocolError("Truncated TLV value.")
        value = payload[offset : offset + length]
        offset += length
        if result and result[-1][0] == tag and previous_length == 255:
            result[-1] = (tag, result[-1][1] + value)
        else:
            result.append((tag, value))
        previous_length = length
    return result


def singletons(items: list[tuple[int, bytes]]) -> dict[int, bytes]:
    result = {}
    for tag, value in items:
        if tag in (0, 255) and not value:
            continue
        if tag in result:
            raise ProtocolError("Unexpected duplicate TLV field.")
        result[tag] = value
    return result


@dataclass(frozen=True)
class Capabilities:
    minimum: int
    maximum: int
    capacity: int

    @classmethod
    def parse(cls, payload: bytes) -> "Capabilities":
        fields = singletons(decode(payload))
        if fields.get(1, b"\x01") != b"\x01":
            raise ProtocolError("The lock uses an unsupported PIN character set.")
        if any(len(fields.get(tag, b"")) not in (1, 2, 4) for tag in (2, 3, 4)):
            raise ProtocolError("Missing or invalid PIN limits.")
        minimum, maximum, capacity = (
            int.from_bytes(fields[tag], "little") for tag in (2, 3, 4)
        )
        if not 1 <= minimum <= maximum <= 32 or not 1 <= capacity <= 1000:
            raise ProtocolError("Unsupported PIN limits.")
        return cls(minimum, maximum, capacity)

    def validate_pin(self, pin: str) -> None:
        if not pin.isascii() or not pin.isdigit():
            raise ProtocolError("Use digits 0–9 only.")
        if not self.minimum <= len(pin) <= self.maximum:
            raise ProtocolError(
                f"Use {self.minimum}–{self.maximum} digits for this lock."
            )


@dataclass(frozen=True)
class Code:
    identifier: bytes
    pin: str | None = field(repr=False)
    flags: int | None
    # Omission is preserved as unknown; it is not converted into success.
    # LIST data and a mutation's verified postcondition are separate evidence.
    status: int | None = field(default=None, compare=False)


STATUSES = {
    1: "The lock reported an unspecified error.",
    2: "The lock has reached its code capacity.",
    3: "The lock rejected the number of requests.",
    4: "That code already exists.",
    5: "The PIN is too short.",
    6: "The PIN is too long.",
    7: "The PIN contains unsupported characters.",
    8: "The lock rejected the request.",
    9: "The code no longer exists.",
}


def request(operation: Operation, *, pin: str | None = None, identifier: bytes | None = None,
            identifiers: list[bytes] | None = None) -> bytes:
    fields = [(1, bytes([operation]))]
    if operation == Operation.ADD:
        if pin is None or not pin.isascii() or not pin.isdigit():
            raise ProtocolError("A numeric PIN is required.")
        fields.append((2, encode([(2, pin.encode("ascii"))])))
    elif operation == Operation.REMOVE:
        if not identifier or len(identifier) > 64:
            raise ProtocolError("A valid code identifier is required.")
        fields.append((2, encode([(1, identifier)])))
    elif operation == Operation.READ:
        if not identifiers or len(identifiers) > 20 or len(set(identifiers)) != len(identifiers):
            raise ProtocolError("Read between 1 and 20 distinct code identifiers at a time.")
        for index, code_id in enumerate(identifiers):
            if not code_id or len(code_id) > 64:
                raise ProtocolError("A valid code identifier is required.")
            if index:
                fields.append((0, b""))
            fields.append((2, encode([(1, code_id)])))
    return encode(fields)


def response(payload: bytes, operation: Operation) -> list[Code]:
    fields = decode(payload)
    operations = [value for tag, value in fields if tag == 1]
    if operations != [bytes([operation])]:
        raise ProtocolError("The lock returned an unexpected operation response.")
    if any(tag not in (0, 1, 3, 255) for tag, _ in fields):
        raise ProtocolError("The lock returned an unknown response field.")
    result = []
    seen = set()
    for tag, value in fields:
        if tag != 3:
            continue
        entry = singletons(decode(value))
        status = entry.get(4)
        if status is not None and len(status) != 1:
            raise ProtocolError("The lock replied, but the keypad-code status field has an unsupported size.")
        if status is not None and status != b"\x00":
            raise CommandRejected(STATUSES.get(status[0], "The lock returned an unknown error."))
        identifier = entry.get(1)
        if not identifier or len(identifier) > 64 or identifier in seen:
            raise ProtocolError("The lock returned invalid or duplicate code identifiers.")
        seen.add(identifier)
        raw_pin = entry.get(2)
        if raw_pin is not None and (not raw_pin.isdigit() or len(raw_pin) > 32):
            raise ProtocolError("The lock returned an invalid PIN representation.")
        flags = entry.get(3)
        # Research examples use one byte; supported Encode Plus responses
        # also use four. Preserve every bit for state comparison without
        # assigning meanings to the bits or ever writing this field.
        if flags is not None and len(flags) not in (1, 4):
            raise ProtocolError("The lock returned an unsupported code flags size.")
        # Encode Plus LIST returns only a four-byte ID per record. Details
        # come from READ, not LIST. Mutation acknowledgements may likewise
        # contain only the affected ID; the manager always verifies by reading.
        if operation == Operation.READ and (raw_pin is None or not 4 <= len(raw_pin) <= 8):
            raise ProtocolError(
                "The lock listed the code, but its READ response did not include a supported PIN value."
            )
        result.append(Code(identifier, raw_pin.decode("ascii") if raw_pin else None,
                           int.from_bytes(flags, "little") if flags is not None else None,
                           status[0] if status else None))
    if operation in (Operation.ADD, Operation.REMOVE) and len(result) != 1:
        raise ProtocolError("The lock did not acknowledge exactly one code change.")
    return result


def response_structure(payload: bytes) -> dict:
    """Diagnostic shape only: never expose PINs, opaque IDs, or raw bytes."""
    result = {"bytes": len(payload), "fields": []}
    try:
        for tag, value in decode(payload):
            item = {"type": tag, "length": len(value)}
            if tag == 3:
                try:
                    item["fields"] = [
                        {"type": nested_tag, "length": len(nested_value)}
                        for nested_tag, nested_value in decode(value)
                    ]
                except ProtocolError:
                    item["malformed"] = True
            result["fields"].append(item)
    except ProtocolError:
        result["malformed"] = True
    return result
