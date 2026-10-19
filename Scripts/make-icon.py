#!/usr/bin/env python3
"""Draw Quill's app icon and pack a full AppIcon.icns.

The drawing is the source of truth: a warm-slate squircle and a cream pen nib.
The squircle follows the macOS icon grid — an 824px body centered on the
1024px canvas, with a transparent margin and a soft drop shadow.
`python3 Scripts/make-icon.py` rewrites Resources/AppIcon.icns and AppIcon.svg.
`--check` fails when those files drift. `--preview PATH` also writes a PNG.
"""

from __future__ import annotations

import math
import struct
import sys
import zlib
from array import array
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

# Apple's macOS grid: 824px squircle centered in the 1024px canvas.
BODY = 824.0 / 1024.0
SHADOW_DY = 16.0 / 1024.0
SHADOW_RADIUS = 18.0 / 1024.0
SHADOW_PASSES = 3
SHADOW_OPACITY = 0.38

BASE = (33, 49, 59)
LIT = (74, 104, 120)
NIB = (246, 242, 234)
NIB_EDGE = (232, 224, 210)

# Nib geometry in body space (0–1 across the 824px squircle, y downward).
# Flat heel, circular shoulder fillets, then one cubic down to a single point.
# The fillet ends on a vertical tangent and the cubic starts on that same
# tangent, so the shoulder has no lump. The slit stops short of the point.
TOP_Y = 0.200
HALF_W = 0.278
CORNER_R = 0.108
TIP_Y = 0.858
SLIT_END_Y = 0.748
HOLE_Y = 0.355
HOLE_R = 0.056
SLIT_HALF = 0.046


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))  # type: ignore[return-value]


def _cubic(p0, p1, p2, p3, steps: int, include_end: bool) -> list[tuple[float, float]]:
    count = steps + (1 if include_end else 0)
    points: list[tuple[float, float]] = []
    for i in range(count):
        t = i / steps
        u = 1 - t
        points.append((
            u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        ))
    return points


def _blade(side: float) -> tuple[tuple[float, float], tuple[float, float], tuple[float, float], tuple[float, float]]:
    """Cubic from the shoulder fillet to the tip. `side` is +1 on the right."""
    shoulder = (0.5 + side * HALF_W, TOP_Y + CORNER_R)
    tip = (0.5, TIP_Y)
    dist = math.hypot(tip[0] - shoulder[0], tip[1] - shoulder[1])
    # Vertical at the shoulder, then 22° off vertical at the point.
    p1 = (shoulder[0], shoulder[1] + dist * 0.40)
    arrive = (side * -math.sin(math.radians(22)), math.cos(math.radians(22)))
    handle = dist * 0.34
    p2 = (tip[0] - arrive[0] * handle, tip[1] - arrive[1] * handle)
    return shoulder, p1, p2, tip


def nib_outline() -> list[tuple[float, float]]:
    """Broad flat heel, round shoulders, one writing point."""
    right = _blade(1.0)
    # Tip -> right shoulder, so the polygon starts on the single point.
    points = _cubic(right[3], right[2], right[1], right[0], 280, include_end=False)
    cy = TOP_Y + CORNER_R
    rx = 0.5 + HALF_W - CORNER_R
    steps = 72
    for i in range(1, steps + 1):
        theta = 0 - (math.pi / 2) * i / steps
        points.append((rx + CORNER_R * math.cos(theta), cy + CORNER_R * math.sin(theta)))
    lx = 0.5 - (HALF_W - CORNER_R)
    for i in range(1, steps + 1):
        theta = -math.pi / 2 - (math.pi / 2) * i / steps
        points.append((lx + CORNER_R * math.cos(theta), cy + CORNER_R * math.sin(theta)))
    left = _blade(-1.0)
    points.extend(_cubic(left[0], left[1], left[2], left[3], 280, include_end=False))
    return points


def slit_outline() -> list[tuple[float, float]]:
    """Circular breather hole with a slit that ends in one point above the tip."""
    cx = 0.5
    cy = HOLE_Y
    r = HOLE_R
    right_a = math.acos(SLIT_HALF / r)
    left_a = math.acos(-SLIT_HALF / r)
    points = [(cx, SLIT_END_Y), (cx + r * math.cos(right_a), cy + r * math.sin(right_a))]
    end = left_a - 2 * math.pi
    steps = 100
    for i in range(1, steps):
        t = right_a + (end - right_a) * i / steps
        points.append((cx + r * math.cos(t), cy + r * math.sin(t)))
    points.append((cx + r * math.cos(left_a), cy + r * math.sin(left_a)))
    return points


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


def to_pixels(polygon: list[tuple[float, float]], origin: float, scale: float) -> list[tuple[float, float]]:
    return [(origin + x * scale, origin + y * scale) for x, y in polygon]


def box_blur(src: array, size: int, radius: int) -> array:
    """Separable box blur. Samples outside the canvas count as transparent."""
    window = radius * 2 + 1
    tmp = array("f", [0.0]) * (size * size)
    prefix = [0.0] * (size + 1)
    for y in range(size):
        row = y * size
        acc = 0.0
        for x in range(size):
            acc += src[row + x]
            prefix[x + 1] = acc
        for x in range(size):
            left = max(0, x - radius)
            right = min(size, x + radius + 1)
            tmp[row + x] = (prefix[right] - prefix[left]) / window
    dst = array("f", [0.0]) * (size * size)
    for x in range(size):
        acc = 0.0
        for y in range(size):
            acc += tmp[y * size + x]
            prefix[y + 1] = acc
        for y in range(size):
            top = max(0, y - radius)
            bottom = min(size, y + radius + 1)
            dst[y * size + x] = (prefix[bottom] - prefix[top]) / window
    return dst


def blur_alpha(src: array, size: int, radius: int) -> array:
    if radius < 1:
        return src
    current = src
    for _ in range(SHADOW_PASSES):
        current = box_blur(current, size, radius)
    return current


def render(size: int) -> bytes:
    """RGBA bytes, top row first. The margin outside the squircle stays clear."""
    scale = size * BODY
    origin = (size - scale) / 2.0
    center = size / 2.0
    radius = scale / 2.0
    nib = to_pixels(nib_outline(), origin, scale)
    slit = to_pixels(slit_outline(), origin, scale)
    icon = bytearray(size * size * 4)
    mask = array("f", [0.0]) * (size * size)
    for py in range(size):
        y = py + 0.5
        ny = (y - center) / radius
        nib_spans = scanline_spans(nib, y)
        cut_spans = scanline_spans(slit, y)
        row = py * size
        if abs(ny) < 1:
            half_w = math.pow(1 - math.pow(abs(ny), 5), 0.2) * radius
            left = center - half_w
            right = center + half_w
            x0 = max(0, int(math.floor(left)))
            x1 = min(size - 1, int(math.ceil(right)))
            light_y = (y - origin) / scale
            for px in range(x0, x1 + 1):
                overlap = min(px + 1, right) - max(px, left)
                if overlap <= 0:
                    continue
                cover = min(1.0, overlap)
                ink = max(0.0, span_coverage(px, nib_spans) - span_coverage(px, cut_spans))
                light = max(0.0, 1.0 - ((px + 0.5 - origin) / scale * 0.55 + light_y * 0.9))
                color = mix(BASE, LIT, light * 0.62)
                tip = min(1.0, max(0.0, (light_y - 0.45) / 0.4))
                ink_color = mix(NIB, NIB_EDGE, tip * 0.55)
                i = (row + px) * 4
                icon[i] = int(round(color[0] * (1 - ink) + ink_color[0] * ink))
                icon[i + 1] = int(round(color[1] * (1 - ink) + ink_color[1] * ink))
                icon[i + 2] = int(round(color[2] * (1 - ink) + ink_color[2] * ink))
                icon[i + 3] = int(round(cover * 255))
                mask[row + px] = cover
        elif not nib_spans and not cut_spans:
            continue
    blurred = blur_alpha(mask, size, int(round(size * SHADOW_RADIUS)))
    dy = int(round(size * SHADOW_DY))
    buf = bytearray(size * size * 4)
    for py in range(size):
        src_y = py - dy
        row = py * size
        for px in range(size):
            shadow = 0.0
            if 0 <= src_y < size:
                shadow = blurred[src_y * size + px] * SHADOW_OPACITY
            i = (row + px) * 4
            icon_a = icon[i + 3] / 255.0
            out_a = icon_a + shadow * (1.0 - icon_a)
            if out_a <= 0:
                continue
            buf[i] = int(round(icon[i] * icon_a / out_a))
            buf[i + 1] = int(round(icon[i + 1] * icon_a / out_a))
            buf[i + 2] = int(round(icon[i + 2] * icon_a / out_a))
            buf[i + 3] = int(round(out_a * 255))
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
        coords = " ".join(f"{100 + x * 824:.1f},{100 + y * 824:.1f}" for x, y in points)
        return f"M {coords} Z"

    squircle: list[tuple[float, float]] = []
    steps = 180
    for i in range(steps):
        theta = 6.283185307179586 * i / steps
        c = math.cos(theta)
        s = math.sin(theta)
        x = math.copysign(abs(c) ** 0.4, c)
        y = math.copysign(abs(s) ** 0.4, s)
        squircle.append((0.5 + x * 0.5, 0.5 + y * 0.5))
    return f"""<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <defs>
    <filter id="dock-shadow" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB">
      <feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#000000" flood-opacity="0.30"/>
    </filter>
  </defs>
  <path filter="url(#dock-shadow)" fill="#21313B" d="{path(squircle)}"/>
  <path fill="#F6F2EA" fill-rule="evenodd" d="{path(nib_outline())} {path(slit_outline())}"/>
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
