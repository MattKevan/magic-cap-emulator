#!/usr/bin/env python3
"""Send a Magic Cap package to the guest over a PCLink serial PTY.

Usage: pclink_send.py --pty /dev/ttysXXX --package foo.pkg [--timeout 180]

The guest must already sit at the Storeroom computer with PCLink open and
listening (the "Cnct" state). This tool performs only the host side of the
transfer: wait for the guest's Cnct request, acknowledge it, push the SPkg
metadata + package stream, exchange Ping/Pong, then send GBye.

Protocol reference: docs/pclink.md.
"""

from __future__ import annotations

import argparse
import os
import select
import struct
import sys
import termios
import time
import zlib
from pathlib import Path

PC_LINK_MAGIC = b"ChMa"
CONNECT_TAG = b"Cnct"
CONNECTED_TAG = b"Cntd"
SEND_PACKAGE_TAG = b"SPkg"
GOODBYE_TAG = b"GBye"
PING_TAG = b"Ping"
PONG_TAG = b"Pong"
ESCAPE_BYTES = frozenset((0x0E, 0x0F, 0x10))


class ProtocolError(ValueError):
    """The peer supplied a malformed PCLink CRC stream."""


def escape_payload(data: bytes) -> bytes:
    """Escape PCLink-reserved payload bytes."""
    result = bytearray()
    for value in data:
        if value in ESCAPE_BYTES:
            result.append(0x10)
        result.append(value)
    return bytes(result)


def unescape_payload(data: bytes) -> bytes:
    """Undo PCLink payload escaping, including pairs split across frames."""
    result = bytearray()
    escaped = False
    for value in data:
        if escaped:
            if value not in ESCAPE_BYTES:
                raise ProtocolError(
                    f"invalid byte 0x{value:02x} after PCLink escape"
                )
            result.append(value)
            escaped = False
        elif value == 0x10:
            escaped = True
        elif value in (0x0E, 0x0F):
            raise ProtocolError(f"unescaped PCLink byte 0x{value:02x}")
        else:
            result.append(value)
    if escaped:
        raise ProtocolError("truncated PCLink escape")
    return bytes(result)


def encode_crc_stream(data: bytes) -> bytes:
    """Encode data as the PCLink escaped, 256-byte, CRC-framed stream."""
    encoded = escape_payload(data)
    result = bytearray()
    for start in range(0, len(encoded), 256):
        frame = encoded[start : start + 256]
        crc = (~zlib.crc32(frame)) & 0xFFFFFFFF
        result.extend(struct.pack(">H", len(frame)))
        result.extend(frame)
        # Length and CRC are part of the lower framing layer and stay raw.
        result.extend(struct.pack(">I", crc))
    return bytes(result)


def decode_crc_stream(wire: bytes) -> bytes:
    """Validate and decode a complete PCLink CRC stream."""
    position = 0
    encoded = bytearray()
    while position < len(wire):
        if len(wire) - position < 2:
            raise ProtocolError("truncated PCLink frame length")
        size = int.from_bytes(wire[position : position + 2], "big")
        position += 2
        if not 1 <= size <= 256:
            raise ProtocolError(f"invalid PCLink frame length {size}")
        end = position + size
        if len(wire) - end < 4:
            raise ProtocolError("truncated PCLink frame")
        frame = wire[position:end]
        expected = int.from_bytes(wire[end : end + 4], "big")
        actual = (~zlib.crc32(frame)) & 0xFFFFFFFF
        if actual != expected:
            raise ProtocolError(
                f"PCLink CRC mismatch: expected {expected:08x}, got {actual:08x}"
            )
        encoded.extend(frame)
        position = end + 4
    return unescape_payload(bytes(encoded))


def encode_packet(tag: bytes, payload: bytes = b"") -> bytes:
    """Encode a four-character PCLink command packet."""
    if len(tag) != 4:
        raise ValueError("PCLink packet tags must contain four bytes")
    return encode_crc_stream(tag + struct.pack(">I", len(payload)) + payload)


def decode_packet(stream: bytes) -> tuple[bytes, bytes]:
    """Decode one PCLink command from an already decoded CRC stream."""
    if len(stream) < 8:
        raise ProtocolError("truncated PCLink packet header")
    size = int.from_bytes(stream[4:8], "big")
    if len(stream) != size + 8:
        raise ProtocolError(
            f"PCLink packet declares {size} payload bytes, "
            f"but contains {len(stream) - 8}"
        )
    return stream[:4], stream[8:]


def package_metadata(path: Path) -> bytes:
    """Build the 0x404-byte SPkg metadata block used by WinPcLink."""
    size = path.stat().st_size
    name_text = path.name
    name = name_text.encode("utf-16-be")
    if len(name) > (0x404 - 32):
        raise ValueError(f"package filename is too long: {name_text}")

    metadata = bytearray(0x404)
    struct.pack_into(">II", metadata, 0, size, size)
    struct.pack_into(">I", metadata, 24, 0x80000000)
    # WinPcLink records the source character count, not the UTF-16 byte count.
    struct.pack_into(">I", metadata, 28, len(name_text))
    metadata[32 : 32 + len(name)] = name
    return bytes(metadata)


def read_available(fd: int) -> bytes:
    result = bytearray()
    while select.select([fd], [], [], 0)[0]:
        try:
            chunk = os.read(fd, 65536)
        except BlockingIOError:
            break
        if not chunk:
            break
        result.extend(chunk)
    return bytes(result)


def drain(fd: int) -> bytes:
    """Read everything currently available on fd (non-blocking)."""
    return read_available(fd)


def write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        if not select.select([], [fd], [], 0.05)[1]:
            continue
        try:
            count = os.write(fd, view)
        except BlockingIOError:
            continue
        view = view[count:]


def configure_raw_pty(fd: int) -> None:
    attrs = termios.tcgetattr(fd)
    attrs[0] = 0
    attrs[1] = 0
    attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
    attrs[3] = 0
    attrs[6][termios.VMIN] = 0
    attrs[6][termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, attrs)


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pty", required=True, help="Serial PTY device path")
    parser.add_argument("--package", required=True, help="Package file to send")
    parser.add_argument(
        "--timeout",
        type=float,
        default=180,
        help="Seconds to wait for Cnct/Pong (default: 180)",
    )
    return parser.parse_args(argv)


def fail(message: str) -> int:
    print(f"pclink_send: error: {message}", file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)

    package = Path(args.package)
    try:
        metadata = package_metadata(package)
    except FileNotFoundError:
        return fail(f"package not found: {args.package}")
    except OSError as caught:
        return fail(f"cannot read package {args.package}: {caught}")
    except ValueError as caught:
        return fail(str(caught))
    try:
        package_stream = encode_crc_stream(package.read_bytes() + b"\0\0\0\0")
    except OSError as caught:
        return fail(f"cannot read package {args.package}: {caught}")

    try:
        fd = os.open(
            args.pty, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK
        )
    except OSError as caught:
        return fail(f"cannot open pty {args.pty}: {caught}")
    try:
        try:
            configure_raw_pty(fd)
        except (termios.error, OSError) as caught:
            return fail(f"cannot configure pty {args.pty}: {caught}")

        device_wire = bytearray()
        deadline = time.monotonic() + args.timeout
        connect_wire_length: int | None = None
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                device_wire.extend(read_available(fd))
            if device_wire.startswith(PC_LINK_MAGIC):
                try:
                    decoded = decode_crc_stream(bytes(device_wire[4:]))
                    tag, _payload = decode_packet(decoded)
                except ProtocolError:
                    pass
                else:
                    if tag == CONNECT_TAG:
                        connect_wire_length = len(device_wire)
                        break
        if connect_wire_length is None:
            return fail(
                f"timed out waiting for Cnct on {args.pty} "
                f"after {args.timeout:g}s"
            )

        # WinPcLink sends this acknowledgement twice; Magic Cap requires both.
        connected = encode_packet(CONNECTED_TAG)
        write_all(fd, connected + connected)

        metadata_wire = encode_packet(SEND_PACKAGE_TAG, metadata)
        write_all(fd, metadata_wire)
        write_all(fd, package_stream)

        ping_wire = encode_packet(PING_TAG)
        pong_wire = encode_packet(PONG_TAG)
        goodbye_wire = encode_packet(GOODBYE_TAG)
        write_all(fd, ping_wire)

        deadline = time.monotonic() + args.timeout
        pong_seen = False
        while time.monotonic() < deadline:
            if select.select([fd], [], [], 0.05)[0]:
                device_wire.extend(read_available(fd))
                trailing = bytes(device_wire[connect_wire_length:])
                if pong_wire in trailing:
                    pong_seen = True
                    break
        if not pong_seen:
            return fail(
                f"timed out waiting for Pong on {args.pty} "
                f"after {args.timeout:g}s"
            )

        write_all(fd, goodbye_wire)
    except OSError as caught:
        return fail(str(caught))
    finally:
        try:
            drain(fd)
        except OSError:
            pass
        os.close(fd)

    print("INSTALL OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
