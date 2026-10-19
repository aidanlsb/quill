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

# Feather in local units, then rotated 45° and fit to the squircle.
# 0 is the quill point, 1 is the crown. The bare shaft is the first quarter.
KAPPA = 0.5522847498307936
VANE_START = 0.25
VANE_LEN = 1.0 - VANE_START
VANE_WIDTH = VANE_LEN / 3.2
HALF_W = VANE_WIDTH / 2.0
WIDE_X = VANE_START + 0.60 * VANE_LEN
# (fraction along the vane, mouth width, depth, how far the point leans toward the crown)
RIGHT_NOTCHES = (
    (0.35, 0.040, 0.062, 0.018),
    (0.60, 0.038, 0.070, 0.020),
    (0.80, 0.032, 0.050, 0.016),
)
LEFT_NOTCH = (0.88, 0.022, 0.030, 0.010)
MARK_HEIGHT = 0.62
SHAFT_HALF = 0.013


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))  # type: ignore[return-value]


def _cubic(
    p0: tuple[float, float],
    p1: tuple[float, float],
    p2: tuple[float, float],
    p3: tuple[float, float],
    steps: int,
) -> list[tuple[float, float]]:
    points: list[tuple[float, float]] = []
    for i in range(steps + 1):
        t = i / steps
        u = 1.0 - t
        points.append((
            u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
            u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
        ))
    return points


def _at_x(samples: list[tuple[float, float]], x: float) -> tuple[float, float]:
    if x <= samples[0][0]:
        return samples[0]
    if x >= samples[-1][0]:
        return samples[-1]
    for i in range(len(samples) - 1):
        x0, y0 = samples[i]
        x1, y1 = samples[i + 1]
        if x0 <= x <= x1 and x1 != x0:
            t = (x - x0) / (x1 - x0)
            return (x, y0 + (y1 - y0) * t)
    return samples[-1]


def _side_samples(sign: float) -> list[tuple[float, float]]:
    """Smooth vane edge from the base to the crown. `sign` is +1 on the lower right."""
    span_base = WIDE_X - VANE_START
    span_crown = 1.0 - WIDE_X
    lower = _cubic(
        (VANE_START, 0.0),
        (VANE_START, sign * KAPPA * HALF_W),
        (WIDE_X - KAPPA * span_base, sign * HALF_W),
        (WIDE_X, sign * HALF_W),
        48,
    )
    upper = _cubic(
        (WIDE_X, sign * HALF_W),
        (WIDE_X + KAPPA * span_crown, sign * HALF_W),
        (1.0, sign * KAPPA * HALF_W),
        (1.0, 0.0),
        40,
    )
    return lower[:-1] + upper


def _cut_wedges(
    samples: list[tuple[float, float]],
    notches: tuple[tuple[float, float, float, float], ...],
    sign: float,
) -> list[tuple[float, float]]:
    """Replace a short stretch of edge with a sharp wedge aimed toward the crown."""
    out: list[tuple[float, float]] = []
    index = 0
    for frac, opening, depth, lean in notches:
        center = VANE_START + frac * VANE_LEN
        x_lo = center - opening * 0.55
        x_hi = center + opening * 0.20
        while index < len(samples) and samples[index][0] < x_lo:
            out.append(samples[index])
            index += 1
        lip_lo = _at_x(samples, x_lo)
        lip_hi = _at_x(samples, x_hi)
        edge_y = _at_x(samples, center + lean)[1]
        room = abs(edge_y) * 0.72
        apex_y = edge_y - sign * min(depth, room)
        apex = (center + lean, apex_y)
        out.append(lip_lo)
        out.append(apex)
        out.append(lip_hi)
        while index < len(samples) and samples[index][0] <= x_hi:
            index += 1
    out.extend(samples[index:])
    return out


def _rotate(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    """Map local +x to up-right and local +y to down-right."""
    c = math.cos(math.radians(45))
    s = math.sin(math.radians(45))
    return [(x * c + y * s, -x * s + y * c) for x, y in points]


def _fit(shapes: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    """Scale the whole mark to MARK_HEIGHT and center its bounding box."""
    xs = [p[0] for shape in shapes for p in shape]
    ys = [p[1] for shape in shapes for p in shape]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    scale = MARK_HEIGHT / (max_y - min_y)
    cx = (min_x + max_x) * 0.5
    cy = (min_y + max_y) * 0.5
    fitted = []
    for shape in shapes:
        fitted.append([((x - cx) * scale + 0.5, (y - cy) * scale + 0.5) for x, y in shape])
    return fitted


def _mark() -> tuple[list[tuple[float, float]], list[tuple[float, float]], list[tuple[float, float]]]:
    right = _cut_wedges(_side_samples(1.0), RIGHT_NOTCHES, 1.0)
    left = _cut_wedges(_side_samples(-1.0), (LEFT_NOTCH,), -1.0)
    # Base -> lower-right edge -> crown -> upper-left edge -> base.
    vane = right + list(reversed(left[1:-1]))
    end = VANE_START + 0.045
    quill = _cubic((0.0, 0.0), (end * 0.42, SHAFT_HALF * 0.04), (end * 0.78, SHAFT_HALF * 0.82), (end, SHAFT_HALF), 28)
    quill += _cubic((end, -SHAFT_HALF), (end * 0.78, -SHAFT_HALF * 0.82), (end * 0.42, -SHAFT_HALF * 0.04), (0.0, 0.0), 28)[:-1]
    rachis = _rachis()
    placed = _fit([_rotate(vane), _rotate(quill), _rotate(rachis)])
    return placed[0], placed[1], placed[2]


def _rachis() -> list[tuple[float, float]]:
    """Thin curved slot from the shaft entry toward the crown, biased up-left."""
    x0 = VANE_START + 0.055
    x1 = 0.90
    steps = 56
    forward: list[tuple[float, float]] = []
    back: list[tuple[float, float]] = []
    for i in range(steps + 1):
        t = i / steps
        x = x0 + (x1 - x0) * t
        bow = math.sin(math.pi * t)
        offset = -(0.006 + 0.020 * t + 0.010 * bow)
        width = 0.0068 * (1.0 - t) ** 0.45
        forward.append((x, offset + width))
        back.append((x, offset - width))
    return forward + list(reversed(back))


def vane_outline() -> list[tuple[float, float]]:
    return _mark()[0]


def quill_outline() -> list[tuple[float, float]]:
    return _mark()[1]


def rachis_outline() -> list[tuple[float, float]]:
    return _mark()[2]


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
    vane = to_pixels(vane_outline(), origin, scale)
    quill = to_pixels(quill_outline(), origin, scale)
    rachis = to_pixels(rachis_outline(), origin, scale)
    icon = bytearray(size * size * 4)
    mask = array("f", [0.0]) * (size * size)
    for py in range(size):
        y = py + 0.5
        ny = (y - center) / radius
        vane_spans = scanline_spans(vane, y)
        quill_spans = scanline_spans(quill, y)
        rachis_spans = scanline_spans(rachis, y)
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
                white = max(span_coverage(px, vane_spans), span_coverage(px, quill_spans))
                ink = max(0.0, white - span_coverage(px, rachis_spans))
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
        elif not vane_spans and not quill_spans and not rachis_spans:
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
  <path fill="#FFFFFF" d="{path(quill_outline())}"/>
  <path fill="#FFFFFF" fill-rule="evenodd" d="{path(vane_outline())} {path(rachis_outline())}"/>
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
