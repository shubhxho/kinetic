#!/usr/bin/env python3
"""Render the Kinetic app icon at every size macOS asks for.

Written against the standard library only — zlib and struct are enough to emit a
PNG, and pulling in Pillow to draw nine rounded rectangles would be a build
dependency for no gain.

The mark is the same one the app draws in its toolbar: three bars sheared into
motion. Drawn at 4x and box-filtered down, which is cheaper to reason about than
analytic coverage and produces clean edges at 16 pt where it matters most.
"""

import math
import os
import struct
import subprocess
import sys
import zlib

# Vercel-ish: near-black plate, near-white mark, one accent bar.
BACKGROUND = (10, 10, 10)
MARK = (237, 237, 237)
ACCENT = (0, 112, 243)
SUPERSAMPLE = 4


def rounded_rect_coverage(x, y, left, top, right, bottom, radius):
    """1.0 inside the rounded rectangle, 0.0 outside. Sampled, not analytic."""
    if x < left or x > right or y < top or y > bottom:
        return 0.0
    cx = min(max(x, left + radius), right - radius)
    cy = min(max(y, top + radius), bottom - radius)
    dx, dy = x - cx, y - cy
    if dx == 0 and dy == 0:
        return 1.0
    return 1.0 if math.hypot(dx, dy) <= radius else 0.0


def render(size):
    """Returns an RGBA buffer of `size` x `size`, supersampled then averaged."""
    hi = size * SUPERSAMPLE
    plate_inset = hi * 0.085
    plate_radius = hi * 0.225  # matches the macOS squircle closely enough

    # Three bars, each shorter and further right than the one above: the shear
    # that reads as motion.
    bar_height = hi * 0.088
    bar_gap = hi * 0.093
    bar_right = hi - hi * 0.235
    first_top = hi * 0.315
    lefts = [hi * 0.235, hi * 0.315, hi * 0.395]

    buffer = bytearray(hi * hi * 4)
    for py in range(hi):
        y = py + 0.5
        row = py * hi * 4
        for px in range(hi):
            x = px + 0.5
            plate = rounded_rect_coverage(x, y, plate_inset, plate_inset,
                                          hi - plate_inset, hi - plate_inset,
                                          plate_radius)
            if plate == 0.0:
                continue

            r, g, b = BACKGROUND
            for index, left in enumerate(lefts):
                top = first_top + index * (bar_height + bar_gap)
                if rounded_rect_coverage(x, y, left, top, bar_right,
                                         top + bar_height, bar_height / 2) > 0:
                    r, g, b = ACCENT if index == 2 else MARK
                    break

            offset = row + px * 4
            buffer[offset] = r
            buffer[offset + 1] = g
            buffer[offset + 2] = b
            buffer[offset + 3] = 255

    # Box filter down to the requested size.
    out = bytearray(size * size * 4)
    step = SUPERSAMPLE
    samples = step * step
    for y in range(size):
        for x in range(size):
            r = g = b = a = 0
            for sy in range(step):
                base = ((y * step + sy) * hi + x * step) * 4
                for sx in range(step):
                    o = base + sx * 4
                    r += buffer[o]
                    g += buffer[o + 1]
                    b += buffer[o + 2]
                    a += buffer[o + 3]
            o = (y * size + x) * 4
            out[o] = r // samples
            out[o + 1] = g // samples
            out[o + 2] = b // samples
            out[o + 3] = a // samples
    return bytes(out)


def write_png(path, size, rgba):
    def chunk(tag, payload):
        data = tag + payload
        return (struct.pack(">I", len(payload)) + data
                + struct.pack(">I", zlib.crc32(data) & 0xFFFFFFFF))

    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)  # filter type 0: none
        raw.extend(rgba[y * stride:(y + 1) * stride])

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as handle:
        handle.write(png)


def main(destination):
    iconset = destination + ".iconset"
    os.makedirs(iconset, exist_ok=True)

    # The set Apple expects; each logical size at 1x and 2x.
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            write_png(os.path.join(iconset, name), pixels, render(pixels))

    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", destination],
                   check=True)
    subprocess.run(["rm", "-rf", iconset], check=True)
    print(f"wrote {destination}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "Kinetic.icns")
