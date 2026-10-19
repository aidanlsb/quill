#!/usr/bin/env python3
"""Draw Quill's app icon and pack a full AppIcon.icns.

The drawing is the source of truth: a warm-slate squircle and a cream pen nib.
`python3 Scripts/make-icon.py` rewrites Resources/AppIcon.icns and AppIcon.svg.
`--check` fails when those files drift. `--preview PATH` also writes a PNG.
"""

from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ICNS_PATH = ROOT / "Resources" / "AppIcon.icns"
SVG_PATH = ROOT / "Resources" / "AppIcon.svg"

# 16, 32, 128, 256, 512 and the @2x pixel sizes (32, 64, 256, 512, 1024).
ICON_TYPES = (
    ("icp4", 16),
    ("ic11", 32),
    ("icp5", 32),
    ("icp6", 64),
    ("ic12", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1024),
)

BASE = (33, 49, 59)
LIT = (74, 104, 120)
NIB = (246, 242, 234)
NIB_EDGE = (232, 224, 210)


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))  # type: ignore[return-value]


def qbezier(a: tuple[float, float], b: tuple[float, float], c: tuple[float, float], steps: int) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        points.append((
            u * u * a[0] + 2 * u * t * b[0] + t * t * c[0],
            u * u * a[1] + 2 * u * t * b[1] + t * t * c[1],
        ))
    return points


def nib_outline() -> list[tuple[float, float]]:
    """Front-view pen nib: wide heel, shoulders, and a sharp writing tip."""
    tip = (0.50, 0.86)
    right_belly = (0.64, 0.60)
    right_shoulder = (0.74, 0.38)
    top_right = (0.62, 0.24)
    top_left = (0.38, 0.24)
    left_shoulder = (0.26, 0.38)
    left_belly = (0.36, 0.60)
    return (
        qbezier(tip, (0.56, 0.76), right_belly, 16)[:-1]
        + qbezier(right_belly, (0.72, 0.50), right_shoulder, 14)[:-1]
        + qbezier(right_shoulder, (0.78, 0.26), top_right, 12)[:-1]
        + qbezier(top_right, (0.50, 0.20), top_left, 12)[:-1]
        + qbezier(top_left, (0.22, 0.26), left_shoulder, 12)[:-1]
        + qbezier(left_shoulder, (0.28, 0.50), left_belly, 14)[:-1]
        + qbezier(left_belly, (0.44, 0.76), tip, 16)[:-1]
    )


def slit_outline() -> list[tuple[float, float]]:
    # Wide enough that the slit still reads at 32px.
    return [(0.458, 0.40), (0.542, 0.40), (0.512, 0.845), (0.488, 0.845)]


def circle_outline(cx: float, cy: float, radius: float, steps: int = 28) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for i in range(steps):
        theta = 6.283185307179586 * i / steps
        points.append((cx + radius * math_cos(theta), cy + radius * math_sin(theta)))
    return points


def math_cos(theta: float) -> float:
    # Local wrappers keep the rasterizer free of a global import cycle in tests.
    import math
    return math.cos(theta)


def math_sin(theta: float) -> float:
    import math
    return math.sin(theta)


def math_pow(value: float, exp: float) -> float:
    import math
    return math.pow(value, exp)


HOLE = (0.50, 0.37, 0.048)


def edges(polygon: list[tuple[float, float]]) -> list[tuple[float, float, float, float]]:
    closed = polygon + [polygon[0]]
    return [
        (closed[i][0], closed[i][1], closed[i + 1][0], closed[i + 1][1])
        for i in range(len(polygon))
    ]


def scanline_spans(polygon: list[tuple[float, float]], y: float) -> list[tuple[float, float]]:
    hits: list[float] = []
    for x0, y0, x1, y1 in edges(polygon):
        if y0 == y1:
            continue
        if (y0 <= y < y1) or (y1 <= y < y0):
            t = (y - y0) / (y1 - y0)
            hits.append(x0 + t * (x1 - x0))
    hits.sort()
    return [(hits[i], hits[i + 1]) for i in range(0, len(hits) - 1, 2)]


def span_coverage(px: int, spans: list[tuple[float, float]]) -> float:
    overlap = 0.0
    right = px + 1
    for start, end in spans:
        overlap += max(0.0, min(right, end) - max(float(px), start))
    return min(1.0, overlap)


def render(size: int) -> bytes:
    """RGBA bytes, top row first. Edge coverage is the overlap of each pixel."""
    import math

    nib = nib_outline()
    slit = slit_outline()
    hole = circle_outline(*HOLE)
    buf = bytearray(size * size * 4)
    half = (size - 1) / 2.0
    radius = size * 0.5
    for py in range(size):
        y_center = py + 0.5
        ny = (y_center - half) / radius
        if abs(ny) >= 1:
            continue
        half_w = math_pow(1 - math_pow(abs(ny), 5), 0.2) * radius
        left = half - half_w
        right = half + half_w
        y_unit = y_center / size
        nib_spans = [(a * size, b * size) for a, b in scanline_spans(nib, y_unit)]
        cut_spans = [(a * size, b * size) for a, b in scanline_spans(slit, y_unit) + scanline_spans(hole, y_unit)]
        x0 = max(0, int(math.floor(left)))
        x1 = min(size - 1, int(math.ceil(right)))
        light_y = y_center / max(1, size - 1)
        row = py * size
        for px in range(x0, x1 + 1):
            overlap = min(px + 1, right) - max(px, left)
            if overlap <= 0:
                continue
            cover = min(1.0, overlap)
            ink = max(0.0, span_coverage(px, nib_spans) - span_coverage(px, cut_spans))
            light = max(0.0, 1.0 - ((px + 0.5) / max(1, size - 1) * 0.55 + light_y * 0.9))
            color = mix(BASE, LIT, light * 0.62)
            tip = min(1.0, max(0.0, (light_y - 0.45) / 0.4))
            ink_color = mix(NIB, NIB_EDGE, tip * 0.55)
            out_r = color[0] * (1 - ink) + ink_color[0] * ink
            out_g = color[1] * (1 - ink) + ink_color[1] * ink
            out_b = color[2] * (1 - ink) + ink_color[2] * ink
            i = (row + px) * 4
            buf[i] = int(round(out_r))
            buf[i + 1] = int(round(out_g))
            buf[i + 2] = int(round(out_b))
            buf[i + 3] = int(round(cover * 255))
    return bytes(buf)


def png(size: int, rgba: bytes) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

    raw = bytearray()
    stride = size * 4
    for y in range(size):
        raw.append(0)
        raw.extend(rgba[y * stride : (y + 1) * stride])
    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")


def icns(images: list[tuple[str, bytes]]) -> bytes:
    body = bytearray()
    for ostype, data in images:
        body.extend(ostype.encode("ascii"))
        body.extend(struct.pack(">I", len(data) + 8))
        body.extend(data)
    return b"icns" + struct.pack(">I", len(body) + 8) + bytes(body)


def svg() -> str:
    def path(points: list[tuple[float, float]]) -> str:
        coords = " ".join(f"{x * 1024:.1f},{y * 1024:.1f}" for x, y in points)
        return f"M {coords} Z"

    squircle: list[tuple[float, float]] = []
    steps = 180
    for i in range(steps):
        theta = 6.283185307179586 * i / steps
        # Superellipse angle is not uniform; sample x = cos^(2/5), y = sin^(2/5).
        import math
        c = math.cos(theta)
        s = math.sin(theta)
        x = math.copysign(abs(c) ** 0.4, c)
        y = math.copysign(abs(s) ** 0.4, s)
        squircle.append((0.5 + x * 0.5, 0.5 + y * 0.5))
    hole = circle_outline(*HOLE, steps=32)
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <path fill="#21313B" d="{path(squircle)}"/>
  <path fill="#F6F2EA" fill-rule="evenodd" d="{path(nib_outline())} {path(slit_outline())} {path(hole)}"/>
</svg>
"""


def build() -> tuple[bytes, str, bytes]:
    cache: dict[int, bytes] = {}
    images: list[tuple[str, bytes]] = []
    for ostype, size in ICON_TYPES:
        if size not in cache:
            cache[size] = png(size, render(size))
        images.append((ostype, cache[size]))
    preview = cache[1024]
    return icns(images), svg(), preview


def main() -> int:
    check = "--check" in sys.argv
    preview_path: Path | None = None
    if "--preview" in sys.argv:
        index = sys.argv.index("--preview")
        if index + 1 >= len(sys.argv):
            print("make-icon: --preview needs a path", file=sys.stderr)
            return 2
        preview_path = Path(sys.argv[index + 1])
    icon, vector, preview = build()
    if check:
        errors: list[str] = []
        if not ICNS_PATH.is_file() or ICNS_PATH.read_bytes() != icon:
            errors.append(f"{ICNS_PATH} is missing or out of date; run python3 Scripts/make-icon.py")
        if not SVG_PATH.is_file() or SVG_PATH.read_text() != vector:
            errors.append(f"{SVG_PATH} is missing or out of date; run python3 Scripts/make-icon.py")
        if icon[:4] != b"icns":
            errors.append("generated icon is not an icns")
        for ostype, _size in ICON_TYPES:
            if ostype.encode("ascii") not in icon:
                errors.append(f"generated icon is missing {ostype}")
        if errors:
            for error in errors:
                print(f"make-icon: {error}", file=sys.stderr)
            return 1
        print("make-icon: AppIcon.icns and AppIcon.svg match")
    else:
        ICNS_PATH.parent.mkdir(parents=True, exist_ok=True)
        ICNS_PATH.write_bytes(icon)
        SVG_PATH.write_text(vector)
        print(f"make-icon: wrote {ICNS_PATH} ({len(icon)} bytes)")
        print(f"make-icon: wrote {SVG_PATH}")
    if preview_path is not None:
        preview_path.parent.mkdir(parents=True, exist_ok=True)
        preview_path.write_bytes(preview)
        print(f"make-icon: wrote {preview_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
