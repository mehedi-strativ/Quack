#!/usr/bin/env python3
"""
Builds Resources/AppIcon.icns from Resources/AppIcon-source.png.

This is the portable twin of Scripts/make-icon.sh — same output, but pure
Python, so it runs on a machine without `sips`/`iconutil` (e.g. a Linux CI box
or a container). On a Mac either script is fine; make-icon.sh is the shorter
one to remember.

The member list mirrors exactly what `iconutil -c icns` emits, including the
detail that 16pt/32pt @1x go in as raw packbits-RLE ARGB rather than PNG:

    ic11  32   16pt@2x   PNG        ic04  16   16pt@1x   ARGB
    ic12  64   32pt@2x   PNG        ic05  32   32pt@1x   ARGB
    ic07 128  128pt@1x   PNG
    ic13 256  128pt@2x   PNG        ic08 256  256pt@1x   PNG
    ic14 512  256pt@2x   PNG        ic09 512  512pt@1x   PNG
    ic10 1024 512pt@2x   PNG
"""

import io
import os
import struct
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Resources", "AppIcon-source.png")
OUT = os.path.join(ROOT, "Resources", "AppIcon.icns")

PNG_MEMBERS = [
    ("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
    ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024),
]
ARGB_MEMBERS = [("ic04", 16), ("ic05", 32)]


def packbits(data: bytes) -> bytes:
    """ICNS run-length encoding (the it32/ARGB variant of PackBits).

    0x00..0x7F  -> (n + 1) literal bytes follow      (1..128)
    0x80..0xFF  -> (n - 125) copies of the next byte (3..130)
    """
    out, i, n = bytearray(), 0, len(data)
    while i < n:
        run = 1
        while i + run < n and run < 130 and data[i + run] == data[i]:
            run += 1
        if run >= 3:
            out += bytes([run + 125, data[i]])
            i += run
        else:
            start = i
            while i < n and i - start < 128:
                # stop the literal as soon as a 3-run begins
                if i + 2 < n and data[i] == data[i + 1] == data[i + 2]:
                    break
                i += 1
            chunk = data[start:i]
            out += bytes([len(chunk) - 1]) + chunk
    return bytes(out)


def argb_member(img: Image.Image) -> bytes:
    """'ARGB' magic + the four channel planes, each packbits-compressed."""
    a, r, g, b = img.split()[3], *img.split()[:3]
    return b"ARGB" + b"".join(packbits(ch.tobytes()) for ch in (a, r, g, b))


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def main():
    src = Image.open(SRC).convert("RGBA")
    if src.size != (1024, 1024):
        raise SystemExit(f"{SRC} must be 1024x1024, got {src.size}")

    cache = {}
    def at(px):
        if px not in cache:
            cache[px] = src if px == 1024 else src.resize((px, px), Image.LANCZOS)
        return cache[px]

    members = []
    for typ, px in PNG_MEMBERS:
        members.append((typ, png_bytes(at(px))))
    for typ, px in ARGB_MEMBERS:
        members.append((typ, argb_member(at(px))))

    # Emit in the same order iconutil does (small->large, ARGB interleaved),
    # purely so a byte-diff against an iconutil build stays readable.
    order = ["ic12", "ic07", "ic13", "ic08", "ic04", "ic14", "ic09", "ic05", "ic10", "ic11"]
    members.sort(key=lambda m: order.index(m[0]))

    body = b"".join(struct.pack(">4sI", t.encode(), len(d) + 8) + d for t, d in members)
    with open(OUT, "wb") as f:
        f.write(struct.pack(">4sI", b"icns", len(body) + 8) + body)

    print(f"✓ Built {OUT} ({len(body) + 8:,} bytes, {len(members)} members)")


if __name__ == "__main__":
    main()
