#!/usr/bin/env python3
"""Draws Dubplate's application icon and writes both asset catalogs.

The mark is the thing the product is named after: a dubplate — the one-off acetate
a record is cut to before anyone else can hear it. A pale disc on the application's
own near-black ground, with the lathe grooves that tell an acetate apart from a
pressing, a plain unprinted centre, and the spindle hole. No note, no waveform, no
gradient mesh; nothing that could be any of forty other music applications.

Everything is drawn procedurally, so no part of the icon is anyone else's artwork.
Each size is rendered at four times its edge and box-filtered down, because the
grooves are one pixel wide at 512 and alias into moiré without it.

    python3 Tools/make_app_icon.py
"""

from __future__ import annotations

import json
import math
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

GROUND = (0x0B, 0x0B, 0x0C)
DISC = (0xF4, 0xF3, 0xF1)
GROOVE = (0xD6, 0xD3, 0xCE)
LABEL = (0xFB, 0xFA, 0xF8)
SUPERSAMPLE = 4

# The disc, its unprinted centre and its spindle hole, as fractions of the edge.
DISC_RADIUS = 0.395
LABEL_RADIUS = 0.135
HOLE_RADIUS = 0.026
GROOVE_INNER = 0.150
GROOVE_PITCH = 0.0125

# macOS icons sit on a rounded plate inset from the canvas; iOS is full bleed and
# the system applies its own mask.
MAC_INSET = 0.085
MAC_CORNER = 0.185


def write_png(path: str, width: int, height: int, rows) -> int:
    """Writes an 8-bit RGBA PNG. `rows` yields one list of (r, g, b, a) per row."""
    raw = bytearray()
    for row in rows:
        raw.append(0)  # filter type: none
        for red, green, blue, alpha in row:
            raw += bytes((red, green, blue, alpha))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return (
            struct.pack(">I", len(payload))
            + kind
            + payload
            + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)
        )

    data = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(data)
    return len(data)


def rounded_rect_contains(x: float, y: float, inset: float, corner: float) -> bool:
    """Whether a point in the unit square is inside the inset rounded plate."""
    low, high = inset, 1.0 - inset
    if x < low or x > high or y < low or y > high:
        return False
    nearest_x = min(max(x, low + corner), high - corner)
    nearest_y = min(max(y, low + corner), high - corner)
    return math.hypot(x - nearest_x, y - nearest_y) <= corner


# A Mac icon sits on an inset plate, so the disc is drawn smaller to keep ground
# visible around it. At full size the rounded corners would clip it on four sides,
# which reads as a mistake rather than as a crop.
MAC_DISC_SCALE = 0.80


def sample(x: float, y: float, platform: str):
    """Colour of one point of the unit square, as (r, g, b, a)."""
    scale = 1.0
    if platform == "mac":
        if not rounded_rect_contains(x, y, MAC_INSET, MAC_CORNER):
            return (0, 0, 0, 0)
        scale = MAC_DISC_SCALE

    distance = math.hypot(x - 0.5, y - 0.5)
    if distance > DISC_RADIUS * scale:
        return (GROUND[0], GROUND[1], GROUND[2], 255)
    if distance <= HOLE_RADIUS * scale:
        return (GROUND[0], GROUND[1], GROUND[2], 255)
    if distance <= LABEL_RADIUS * scale:
        return (LABEL[0], LABEL[1], LABEL[2], 255)

    inner = GROOVE_INNER * scale
    if distance >= inner:
        # One groove per pitch, the darker line taking the outer part of it.
        phase = ((distance - inner) % (GROOVE_PITCH * scale)) / (GROOVE_PITCH * scale)
        if phase > 0.58:
            return (GROOVE[0], GROOVE[1], GROOVE[2], 255)
    return (DISC[0], DISC[1], DISC[2], 255)


def render(edge: int, platform: str):
    """One icon, supersampled and box-filtered."""
    steps = SUPERSAMPLE
    span = 1.0 / (edge * steps)
    for row_index in range(edge):
        row = []
        for column_index in range(edge):
            red = green = blue = alpha = 0
            for sub_y in range(steps):
                y = (row_index * steps + sub_y + 0.5) * span
                for sub_x in range(steps):
                    x = (column_index * steps + sub_x + 0.5) * span
                    pixel = sample(x, y, platform)
                    red += pixel[0] * pixel[3]
                    green += pixel[1] * pixel[3]
                    blue += pixel[2] * pixel[3]
                    alpha += pixel[3]
            count = steps * steps
            if alpha == 0:
                row.append((0, 0, 0, 0))
            else:
                row.append((red // alpha, green // alpha, blue // alpha, alpha // count))
        yield row


IOS_CATALOG = os.path.join(ROOT, "Apps", "DubplateiOS", "Resources", "Assets.xcassets")
MAC_CATALOG = os.path.join(ROOT, "Apps", "DubplateMac", "Resources", "Assets.xcassets")

MAC_SIZES = [
    ("16x16", "1x", 16), ("16x16", "2x", 32),
    ("32x32", "1x", 32), ("32x32", "2x", 64),
    ("128x128", "1x", 128), ("128x128", "2x", 256),
    ("256x256", "1x", 256), ("256x256", "2x", 512),
    ("512x512", "1x", 512), ("512x512", "2x", 1024),
]


def write_json(path: str, payload) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def catalog_root(path: str) -> None:
    write_json(
        os.path.join(path, "Contents.json"),
        {"info": {"author": "xcode", "version": 1}},
    )


def colorset(path: str, name: str, light: str, dark: str, comment: str) -> None:
    def components(hex_value: str):
        return {
            "color": {
                "color-space": "srgb",
                "components": {
                    "alpha": "1.000",
                    "blue": f"0x{hex_value[4:6]}",
                    "green": f"0x{hex_value[2:4]}",
                    "red": f"0x{hex_value[0:2]}",
                },
            },
            "idiom": "universal",
        }

    dark_entry = components(dark)
    dark_entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    write_json(
        os.path.join(path, f"{name}.colorset", "Contents.json"),
        {
            "colors": [components(light), dark_entry],
            "info": {"author": "xcode", "version": 1},
            "properties": {"localizable": True},
            "comment": comment,
        },
    )


def main() -> int:
    written = 0

    # iOS: one 1024 square, full bleed.
    ios_icon = os.path.join(IOS_CATALOG, "AppIcon.appiconset")
    write_png(os.path.join(ios_icon, "icon-1024.png"), 1024, 1024, render(1024, "ios"))
    written += 1
    write_json(
        os.path.join(ios_icon, "Contents.json"),
        {
            "images": [{"filename": "icon-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        },
    )
    catalog_root(IOS_CATALOG)
    colorset(
        IOS_CATALOG, "LaunchBackground", "F7F6F4", "0B0B0C",
        "The application's ground. The launch screen is this colour so the first "
        "frame of a near-black application is not a white flash.",
    )
    colorset(
        IOS_CATALOG, "AccentColor", "121212", "F4F3F1",
        "DubplateColor.accent, so system controls match the one accent.",
    )

    # macOS: the full ladder, on a rounded plate.
    mac_icon = os.path.join(MAC_CATALOG, "AppIcon.appiconset")
    images = []
    for size_name, scale, edge in MAC_SIZES:
        filename = f"icon-{edge}.png"
        target = os.path.join(mac_icon, filename)
        if not os.path.exists(target):
            write_png(target, edge, edge, render(edge, "mac"))
            written += 1
        images.append({"filename": filename, "idiom": "mac", "scale": scale, "size": size_name})
    write_json(
        os.path.join(mac_icon, "Contents.json"),
        {"images": images, "info": {"author": "xcode", "version": 1}},
    )
    catalog_root(MAC_CATALOG)
    colorset(
        MAC_CATALOG, "AccentColor", "121212", "F4F3F1",
        "DubplateColor.accent, so system controls match the one accent.",
    )

    print(f"wrote {written} icon image(s) and two asset catalogs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
