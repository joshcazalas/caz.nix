"""Read bounded, owner-only text inputs for the homeserver's private services."""

import io
import os
import stat


MAX_BYTES = 65536


class PrivateFileError(ValueError):
    """A validation message safe to log without exposing private paths or text."""


def read_private(path, owner=0, *, dir_fd=None):
    def opener(name, flags):
        return os.open(name, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY, dir_fd=dir_fd)

    with open(path, "rb", opener=opener) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != owner or stat.S_IMODE(info.st_mode) != 0o600:
            raise PrivateFileError("Private input must be a regular mode 0600 file owned by the expected user.")
        if info.st_size > MAX_BYTES:
            raise PrivateFileError("Private input exceeds 64 KiB.")
        # The file can grow between fstat and read. Enforce the ceiling in bytes.
        data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise PrivateFileError("Private input exceeds 64 KiB.")

    # Match a normal text-mode read, including universal newlines.
    with io.TextIOWrapper(io.BytesIO(data)) as text:
        return text.read()
