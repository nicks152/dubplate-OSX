#!/usr/bin/env python3
"""Generates placeholder cover art for the sample releases.

Procedural, so nothing in the repository is anyone else's artwork. Each cover is a
plain two-tone field with a soft diagonal, derived from the release title — the same
scheme the application draws when a record has no cover yet, at a size a real cover
would be (2000 px) so the low-resolution warning and the artwork pipeline both get
exercised on something realistic.

    python3 Tools/make_placeholder_art.py
"""

from __future__ import annotations

import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Fixtures", "Artwork")

COVERS = [
    ("NO SIGNAL", 2000),
    ("BLUE ROOM", 2000),
    ("Midnight", 2000),
    # Deliberately small, to exercise the resolution warning.
    ("Low Resolution Test", 480),
]


def title_hash(title: str) -> int:
    value = 5381
    for byte in title.encode("utf-8"):
        value = (value * 33 + byte) & 0xFFFFFFFFFFFFFFFF
    return value


def write_png(path: str, width: int, height: int, pixels) -> int:
    """Writes an 8-bit RGB PNG. `pixels` yields (r, g, b) per pixel, row-major."""
    raw = bytearray()
    iterator = iter(pixels)
    for _ in range(height):
        raw.append(0)  # filter type: none
        for _ in range(width):
            red, green, blue = next(iterator)
            raw += bytes((red, green, blue))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)
    return len(data)


def cover(title: str, size: int):
    seed = title_hash(title)
    base = (seed % 26) + 14
    top = base + 22
    angle = ((seed >> 8) % 60) / 100 + 0.25
    grain = (seed >> 16) % 7

    for y in range(size):
        for x in range(size):
            progress = (x / size) * angle + (y / size) * (1 - angle)
            value = top + (base - top) * progress
            # A little structured texture so the field is not a flat gradient.
            value += math.sin((x + y) / (size / 9)) * 1.6
            value += ((x * 7 + y * 13 + grain) % 5) * 0.35
            level = max(0, min(255, int(value)))
            yield (level, level, int(level * 0.98))


def main() -> int:
    total = 0
    for title, size in COVERS:
        filename = title.lower().replace(" ", "-") + f"-{size}.png"
        written = write_png(os.path.join(FIXTURES, filename), size, size, cover(title, size))
        total += written
        print(f"{filename:34} {size}×{size}  {written / 1024:7.0f} KB")
    print(f"\n{total / 1024 / 1024:.1f} MB written to {os.path.relpath(FIXTURES, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
