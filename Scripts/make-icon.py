#!/usr/bin/env python3
"""Draw Quill's app icon and pack a full AppIcon.icns.

The drawing is the source of truth: a near-black squircle and a solid white
feather quill. The squircle follows the macOS icon grid — an 824px body
centered on the 1024px canvas, with a transparent margin and a soft drop
shadow. `python3 Scripts/make-icon.py` rewrites Resources/AppIcon.icns and
AppIcon.svg. `--check` fails when those files drift. `--preview PATH` also
writes a PNG.
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

# Near-black squircle. Top is #1C1C1E, bottom is #0A0A0B.
TOP_COLOR = (28, 28, 30)
BOTTOM_COLOR = (10, 10, 11)
FEATHER = (255, 255, 255)

# Feather geometry in body space (0–1 across the 824px squircle, y downward).
# The vane runs from a fine tip at the lower left to a rounded crown at the
# upper right. Width grows toward the crown. Notches are smooth bites in the
# lower-right edge. The shaft is a thin cut that drifts toward the inner edge.
TIP = (0.24, 0.760)
CAP = (0.710, 0.305)
CAP_RISE = 0.108
RIGHT_W = 0.198
LEFT_W = 0.108
# Scallops on the lower-right edge: center along the vane, half-width, depth.
NOTCHES = (
    (0.44, 0.070, 0.036),
    (0.60, 0.068, 0.044),
    (0.75, 0.058, 0.032),
)
SHAFT_FROM = 0.36
SHAFT_TO = 0.74
SHAFT_HALF = 0.015


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))  # type: ignore[return-value]


def _frame() -> tuple[float, tuple[float, float], tuple[float, float]]:
    """Axis length, unit direction tip→crown, and the lower-right normal."""
    dx = CAP[0] - TIP[0]
    dy = CAP[1] - TIP[1]
    length = math.hypot(dx, dy)
    direction = (dx / length, dy / length)
    normal = (-direction[1], direction[0])
    return length, direction, normal


def _grow(s: float) -> float:
    """0 at the tip, 1 at the shoulder, with a flat tangent at the shoulder."""
    return 0.55 * s + 1.9 * s * s - 1.45 * s * s * s


def _edge(s: float, side: float, length: float, direction: tuple[float, float], normal: tuple[float, float]) -> tuple[float, float]:
    grow = _grow(s)
    width = RIGHT_W * grow if side > 0 else LEFT_W * grow
    return (
        TIP[0] + direction[0] * length * s + normal[0] * side * width,
        TIP[1] + direction[1] * length * s + normal[1] * side * width,
    )


def _scallop(
    s0: float,
    s1: float,
    depth: float,
    length: float,
    direction: tuple[float, float],
    normal: tuple[float, float],
) -> list[tuple[float, float]]:
    """Circular bite opening through the lower-right edge."""
    p0 = _edge(s0, 1.0, length, direction, normal)
    p3 = _edge(s1, 1.0, length, direction, normal)
    chord = (p3[0] - p0[0], p3[1] - p0[1])
    span = math.hypot(*chord)
    if span < 1e-4 or depth < 1e-4:
        return []
    half = span * 0.5
    radius = (half * half + depth * depth) / (2 * depth)
    center = (
        (p0[0] + p3[0]) * 0.5 + normal[0] * (radius - depth),
        (p0[1] + p3[1]) * 0.5 + normal[1] * (radius - depth),
    )
    a0 = math.atan2(p0[1] - center[1], p0[0] - center[0])
    a1 = math.atan2(p3[1] - center[1], p3[0] - center[0])
    sweep = (a1 - a0) % (2 * math.pi)
    if sweep > math.pi:
        sweep -= 2 * math.pi
    steps = 36
    return [
        (
            center[0] + radius * math.cos(a0 + sweep * i / steps),
            center[1] + radius * math.sin(a0 + sweep * i / steps),
        )
        for i in range(1, steps)
    ]


def feather_outline() -> list[tuple[float, float]]:
    """Leaf-shaped vane: one point at the lower left, round crown at the upper right."""
    length, direction, normal = _frame()
    bites = tuple(sorted(NOTCHES))
    points: list[tuple[float, float]] = []
    steps = 480
    cursor = 0.0
    for center, half, depth in bites:
        s0 = center - half
        s1 = center + half
        i0 = int(round(cursor * steps))
        i1 = int(round(s0 * steps))
        points.extend(_edge(i / steps, 1.0, length, direction, normal) for i in range(i0, i1))
        points.append(_edge(s0, 1.0, length, direction, normal))
        points.extend(_scallop(s0, s1, depth, length, direction, normal))
        points.append(_edge(s1, 1.0, length, direction, normal))
        cursor = s1
    i0 = int(round(cursor * steps)) + 1
    points.extend(_edge(i / steps, 1.0, length, direction, normal) for i in range(i0, steps))
    right = _edge(1.0, 1.0, length, direction, normal)
    left = _edge(1.0, -1.0, length, direction, normal)
    mid = ((right[0] + left[0]) * 0.5, (right[1] + left[1]) * 0.5)
    half_cap = ((right[0] - left[0]) * 0.5, (right[1] - left[1]) * 0.5)
    rise = (direction[0] * CAP_RISE, direction[1] * CAP_RISE)
    cap_steps = 100
    for i in range(cap_steps + 1):
        phi = math.pi * i / cap_steps
        points.append((
            mid[0] + half_cap[0] * math.cos(phi) + rise[0] * math.sin(phi),
            mid[1] + half_cap[1] * math.cos(phi) + rise[1] * math.sin(phi),
        ))
    points.extend(_edge(i / steps, -1.0, length, direction, normal) for i in range(steps, 0, -1))
    return points


def shaft_outline() -> list[tuple[float, float]]:
    """Thin negative-space shaft from near the tip toward the upper-left inner edge."""
    length, direction, normal = _frame()
    steps = 140
    forward: list[tuple[float, float]] = []
    back: list[tuple[float, float]] = []
    for i in range(steps + 1):
        t = i / steps
        s = SHAFT_FROM + (SHAFT_TO - SHAFT_FROM) * t
        taper = math.sin(math.pi * t) ** 0.7
        half = SHAFT_HALF * max(0.0, taper)
        lateral = -(0.012 + 0.048 * t)
        cx = TIP[0] + direction[0] * length * s + normal[0] * lateral
        cy = TIP[1] + direction[1] * length * s + normal[1] * lateral
        forward.append((cx + normal[0] * half, cy + normal[1] * half))
        back.append((cx - normal[0] * half, cy - normal[1] * half))
    return forward + list(reversed(back))


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
    nib = to_pixels(feather_outline(), origin, scale)
    slit = to_pixels(shaft_outline(), origin, scale)
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
                color = mix(TOP_COLOR, BOTTOM_COLOR, min(1.0, max(0.0, light_y)))
                sheen = max(0.0, 1.0 - light_y * 1.35)
                across = (px + 0.5 - center) / radius
                sheen *= max(0.0, 1.0 - across * across * 0.55)
                color = mix(color, (255, 255, 255), sheen * 0.04)
                ink_color = FEATHER
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
    <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#1C1C1E"/>
      <stop offset="1" stop-color="#0A0A0B"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="100" x2="0" y2="480" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.04"/>
      <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <filter id="dock-shadow" x="-20%" y="-20%" width="140%" height="140%" color-interpolation-filters="sRGB">
      <feDropShadow dx="0" dy="16" stdDeviation="18" flood-color="#000000" flood-opacity="0.30"/>
    </filter>
    <clipPath id="squircle-clip">
      <path d="{path(squircle)}"/>
    </clipPath>
  </defs>
  <path filter="url(#dock-shadow)" fill="url(#bg)" d="{path(squircle)}"/>
  <path clip-path="url(#squircle-clip)" fill="url(#sheen)" d="{path(squircle)}"/>
  <path fill="#FFFFFF" fill-rule="evenodd" d="{path(feather_outline())} {path(shaft_outline())}"/>
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
