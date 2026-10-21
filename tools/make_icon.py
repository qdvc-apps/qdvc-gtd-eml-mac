#!/usr/bin/env python3
"""Generate the app icon: Resources/AppIcon.svg (vector master) and
Resources/AppIcon.icns (every macOS size, rendered natively from the vector).

The design is the back of a white envelope that fills the whole tile, with
a mint band round its edge and along the edge of its top flap, which is
folded down to the middle and closed there with a green wax seal pressed
with a check mark (an email that has been dealt with). Like QDVC Progress for macOS, the subject is the tile itself
rather than an emblem on a background; the mint keeps the family's earlier
"Sage" palette. Soft folds, tinted shadows and a light top sheen give the
depth of the macOS 26 icon style.

Geometry follows Apple's macOS icon template: a 1024x1024 canvas holding an
824x824 tile (100 px transparent margin) with a 185.4 px continuous-curvature
("squircle") corner, plus a soft drop shadow. The corner is the curve UIKit
draws for continuous corners, as reverse-engineered and published by PaintCode
(https://www.paintcodeapp.com/blogpost/code-for-ios-7-rounded-rectangles). It
is not a superellipse; a whole-shape superellipse looks slightly too round.

Usage:

    python3 tools/make_icon.py            # writes Resources/AppIcon.{svg,icns}
    python3 tools/make_icon.py --preview  # also writes build/icon-preview.png

Requires rsvg-convert (macOS: `brew install librsvg`; Debian/Ubuntu:
`apt install librsvg2-bin`). No other dependencies; the .icns is written
directly, so Apple's iconutil is not needed.
"""

import argparse
import math
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Resources"

# ---------------------------------------------------------------------------
# Palette. The envelope is white paper; the mint ("Sage") of the family's
# earlier icon survives as the band along the flap's edge and in the
# shadows the folds cast.

PAPER_TOP, PAPER_BOTTOM = "#FFFFFF", "#F1F5F2"
SIDE_FOLD, BOTTOM_FOLD = "#E2EBE5", "#F3F7F4"
FOLD_LINE = "#C9D8CD"
SHADOW_TINT = "#5E9C70"
BAND_LIGHT, BAND_DEEP = "#86D7A2", "#43AE6C"
EDGE = "#C6CFC8"

# The seal: green sealing wax, with a check mark pressed into it.
WAX_LIGHT, WAX_MID, WAX_DARK = "#6FD796", "#24A257", "#0F6331"
WAX_PRESS_DARK, WAX_PRESS_LIGHT = "#13703A", "#3DBB6C"
FEATURES = "#E4FAEC"
FEATURE_SHADOW = "#0B4523"

# ---------------------------------------------------------------------------
# Apple's template geometry.

TILE_ORIGIN, TILE_SIZE, CORNER_RADIUS = 100, 824, 185.4
SHADOW_BLUR_RADIUS, SHADOW_OFFSET_Y, SHADOW_OPACITY = 28, 12, 0.5

# Continuous-corner segments around the top-right corner, in units of the
# radius: (distance from the right edge, distance from the top edge).
_CORNER = [
    ("L", (1.52866471, 0.0)),
    ("C", (1.08849323, 0.0), (0.86840689, 0.0), (0.66993427, 0.06549600)),
    ("L", (0.63149399, 0.07491100)),
    ("C", (0.37282392, 0.16905899), (0.16906013, 0.37282401), (0.07491176, 0.63149399)),
    ("C", (0.0, 0.86840701), (0.0, 1.08849299), (0.0, 1.52866483)),
]


def continuous_rounded_rect(x, y, w, h, r):
    """SVG path of a rounded rectangle with Apple's continuous corners."""
    r = min(r, min(w, h) / 2 / 1.52866483)
    corners = [
        lambda u, v: (x + w - u * r, y + v * r),        # top-right
        lambda u, v: (x + w - v * r, y + h - u * r),    # bottom-right
        lambda u, v: (x + u * r, y + h - v * r),        # bottom-left
        lambda u, v: (x + v * r, y + u * r),            # top-left
    ]

    def fmt(p):
        return f"{p[0]:.2f},{p[1]:.2f}"

    d = [f"M{fmt((x + 1.52866483 * r, y))}"]
    for corner in corners:
        for seg in _CORNER:
            if seg[0] == "L":
                d.append("L" + fmt(corner(*seg[1])))
            else:
                d.append("C" + " ".join(fmt(corner(*p)) for p in seg[1:]))
    d.append("Z")
    return " ".join(d)


TILE = continuous_rounded_rect(TILE_ORIGIN, TILE_ORIGIN, TILE_SIZE, TILE_SIZE, CORNER_RADIUS)

# The envelope is the tile: its back, with the top flap folded down to a
# point a little below the middle, where the seal sits. FLAP_SHOULDER is how
# far down the tile's sides the flap's edges begin (clear of the corners).
FLAP_TIP_Y = 566
FLAP_SHOULDER_Y = 176
BAND_WIDTH = 38        # the flap's band, and the band round the tile's edge
SEAL_RADIUS = 160      # the wax's mean radius
LOWER_FOLD_Y = 612     # where the side and bottom folds meet, under the seal


def _flap_edge():
    """The flap's lower edge: shoulder to shoulder through a rounded tip."""
    left, right = TILE_ORIGIN, TILE_ORIGIN + TILE_SIZE
    cx = left + TILE_SIZE / 2
    k = 46  # how far either side of the tip the rounding starts
    slope = (FLAP_TIP_Y - FLAP_SHOULDER_Y) / (cx - left)
    return (f"M{left - 40},{FLAP_SHOULDER_Y - 40 * slope:.1f} "
            f"L{cx - k},{FLAP_TIP_Y - k * slope:.1f} "
            f"Q{cx},{FLAP_TIP_Y + k * slope * 0.35:.1f} {cx + k},{FLAP_TIP_Y - k * slope:.1f} "
            f"L{right + 40},{FLAP_SHOULDER_Y - 40 * slope:.1f}")


def _envelope():
    """The back of the envelope, filling the tile. Returns (elements, tip)."""
    left, top = TILE_ORIGIN, TILE_ORIGIN
    right, bottom = left + TILE_SIZE, top + TILE_SIZE
    cx = left + TILE_SIZE / 2
    edge = _flap_edge()
    flap = f"{edge} L{right + 40},{top - 40} L{left - 40},{top - 40} Z"
    parts = [
        f'<rect x="{left}" y="{top}" width="{TILE_SIZE}" height="{TILE_SIZE}" fill="url(#paper)"/>',
        # The side folds, then the bottom fold over them.
        f'<path d="M{left},{top} L{cx},{LOWER_FOLD_Y} L{left},{bottom} Z" fill="{SIDE_FOLD}"/>',
        f'<path d="M{right},{top} L{cx},{LOWER_FOLD_Y} L{right},{bottom} Z" fill="{SIDE_FOLD}"/>',
        f'<path d="M{left - 20},{bottom + 20} L{cx},{LOWER_FOLD_Y + 26} L{right + 20},{bottom + 20} Z" '
        f'fill="url(#bottomfold)" filter="url(#foldshadow)"/>',
        f'<path d="M{left - 20},{bottom + 20} L{cx},{LOWER_FOLD_Y + 26} L{right + 20},{bottom + 20}" '
        f'fill="none" stroke="{FOLD_LINE}" stroke-width="4" stroke-linejoin="round"/>',
        # The top flap, casting a soft shadow on the folds below it.
        f'<path d="{flap}" fill="url(#flap)" filter="url(#flapshadow)"/>',
        # The mint band along the flap's edge (the stroke, clipped to the
        # flap, so only its inner half shows), with a fine white rule.
        f'<g clip-path="url(#flapclip)"><path d="{edge}" fill="none" stroke="url(#band)" '
        f'stroke-width="{BAND_WIDTH * 2}" stroke-linejoin="round"/></g>',
        f'<path d="{edge}" fill="none" stroke="{BAND_DEEP}" stroke-opacity="0.55" stroke-width="3" '
        'stroke-linejoin="round"/>',
    ]
    return parts, flap, (cx, FLAP_TIP_Y)


def _wax_outline(cx, cy, r, points=144):
    """A blob of sealing wax: a circle whose edge ripples where the wax
    spread when the seal was pressed (a smooth closed path)."""
    pts = []
    for i in range(points):
        t = 2 * math.pi * i / points
        k = (1 + 0.026 * math.sin(3 * t + 0.4) + 0.020 * math.sin(5 * t + 2.1)
             + 0.030 * math.sin(9 * t + 0.9) + 0.016 * math.sin(13 * t + 2.5)
             + 0.008 * math.sin(23 * t + 1.2))
        pts.append((cx + r * k * math.cos(t), cy + r * k * math.sin(t)))
    # Catmull-Rom through the points, as cubic Beziers.
    d = [f"M{pts[0][0]:.1f},{pts[0][1]:.1f}"]
    n = len(pts)
    for i in range(n):
        p0, p1, p2, p3 = pts[i - 1], pts[i], pts[(i + 1) % n], pts[(i + 2) % n]
        c1 = (p1[0] + (p2[0] - p0[0]) / 6, p1[1] + (p2[1] - p0[1]) / 6)
        c2 = (p2[0] - (p3[0] - p1[0]) / 6, p2[1] - (p3[1] - p1[1]) / 6)
        d.append(f"C{c1[0]:.1f},{c1[1]:.1f} {c2[0]:.1f},{c2[1]:.1f} {p2[0]:.1f},{p2[1]:.1f}")
    return " ".join(d) + " Z"


def _seal(cx, cy, r):
    """A classic wax seal: a glossy blob of green wax with a round recess
    where the stamp was pressed, and a check mark standing up in relief."""
    inner = r * 0.70
    s = inner * 0.98  # the check mark's scale
    check = (f"M{cx - s * 0.46:.1f},{cy + s * 0.02:.1f} L{cx - s * 0.13:.1f},{cy + s * 0.34:.1f} "
             f"L{cx + s * 0.48:.1f},{cy - s * 0.32:.1f}")
    stroke = f'fill="none" stroke-width="{s * 0.19:.1f}" stroke-linecap="round" stroke-linejoin="round"'
    return [
        f'<g filter="url(#sealshadow)"><path d="{_wax_outline(cx, cy, r)}" fill="url(#wax)"/></g>',
        # A soft rim of thicker wax round the stamp's recess.
        f'<circle cx="{cx}" cy="{cy}" r="{inner + r * 0.09:.1f}" fill="none" stroke="url(#waxrim)" '
        f'stroke-width="{r * 0.07:.1f}"/>',
        # The recess: shaded the other way round from the blob, so it reads
        # as pressed in.
        f'<circle cx="{cx}" cy="{cy}" r="{inner:.1f}" fill="url(#press)"/>',
        f'<circle cx="{cx}" cy="{cy}" r="{inner:.1f}" fill="none" stroke="{WAX_DARK}" stroke-opacity="0.45" '
        f'stroke-width="{r * 0.025:.1f}"/>',
        # The check mark in relief: its shadow, then the raised stroke.
        f'<path d="{check}" stroke="{FEATURE_SHADOW}" stroke-opacity="0.55" {stroke} '
        f'transform="translate({s * 0.035:.1f},{s * 0.05:.1f})"/>',
        f'<path d="{check}" stroke="{FEATURES}" {stroke}/>',
        # Gloss on the wax.
        f'<ellipse cx="{cx - r * 0.42:.1f}" cy="{cy - r * 0.62:.1f}" rx="{r * 0.30:.1f}" '
        f'ry="{r * 0.12:.1f}" fill="#FFFFFF" opacity="0.40" '
        f'transform="rotate(-28 {cx - r * 0.42:.1f} {cy - r * 0.62:.1f})"/>',
    ]


def _tinted_shadow(fid, blur, dy, opacity):
    return (f'<filter id="{fid}" x="-30%" y="-30%" width="160%" height="160%">'
            f'<feGaussianBlur in="SourceAlpha" stdDeviation="{blur}"/><feOffset dx="0" dy="{dy}"/>'
            f'<feFlood flood-color="{SHADOW_TINT}" flood-opacity="{opacity}"/>'
            '<feComposite operator="in" in2="SourceAlpha"/>'
            '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>')


def icon_svg():
    sigma = SHADOW_BLUR_RADIUS / 2
    envelope, flap, (cx, tip) = _envelope()
    defs = [
        f'<linearGradient id="paper" x1="0" y1="0" x2="0.2" y2="1">'
        f'<stop offset="0" stop-color="{PAPER_TOP}"/><stop offset="1" stop-color="{PAPER_BOTTOM}"/></linearGradient>',
        f'<linearGradient id="bottomfold" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="{BOTTOM_FOLD}"/></linearGradient>',
        '<linearGradient id="flap" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="{PAPER_BOTTOM}"/></linearGradient>',
        '<linearGradient id="band" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0.3" stop-color="{BAND_LIGHT}"/><stop offset="1" stop-color="{BAND_DEEP}"/></linearGradient>',
        '<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">'
        '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.30"/>'
        '<stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>',
        '<linearGradient id="edge" x1="0" y1="0" x2="0" y2="1">'
        f'<stop offset="0" stop-color="{EDGE}" stop-opacity="0.45"/>'
        f'<stop offset="1" stop-color="{EDGE}" stop-opacity="0.9"/></linearGradient>',
        '<radialGradient id="wax" cx="0.36" cy="0.30" r="0.80">'
        f'<stop offset="0" stop-color="{WAX_LIGHT}"/><stop offset="0.55" stop-color="{WAX_MID}"/>'
        f'<stop offset="1" stop-color="{WAX_DARK}"/></radialGradient>',
        '<linearGradient id="press" x1="0.15" y1="0.1" x2="0.85" y2="0.9">'
        f'<stop offset="0" stop-color="{WAX_PRESS_DARK}"/><stop offset="1" stop-color="{WAX_PRESS_LIGHT}"/>'
        '</linearGradient>',
        '<linearGradient id="waxrim" x1="0.15" y1="0.1" x2="0.85" y2="0.9">'
        f'<stop offset="0" stop-color="{WAX_LIGHT}" stop-opacity="0.85"/>'
        f'<stop offset="1" stop-color="{WAX_DARK}" stop-opacity="0.7"/></linearGradient>',
        f'<clipPath id="clip"><path d="{TILE}"/></clipPath>',
        f'<clipPath id="flapclip"><path d="{flap}"/></clipPath>',
        # Apple template shadow: black, 28 px blur radius, 12 px down, 50 %.
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="{sigma}"/><feOffset dy="{SHADOW_OFFSET_Y}"/>'
        f'<feComponentTransfer><feFuncA type="linear" slope="{SHADOW_OPACITY}"/></feComponentTransfer>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
        _tinted_shadow("flapshadow", 18, 18, 0.42),
        _tinted_shadow("foldshadow", 10, -6, 0.12),
        _tinted_shadow("sealshadow", 14, 14, 0.50),
    ]
    parts = [
        f'<g filter="url(#shadow)"><path d="{TILE}" fill="#FFFFFF"/></g>',
        '<g clip-path="url(#clip)">',
        *envelope,
        # The band continues round the whole edge of the envelope (the
        # tile's outline, stroked and clipped, so only its inner half shows).
        f'<path d="{TILE}" fill="none" stroke="url(#band)" stroke-width="{BAND_WIDTH * 2}"/>',
        *_seal(cx, tip - 4, SEAL_RADIUS),
        '<rect x="100" y="100" width="824" height="824" fill="url(#sheen)"/>',
        '</g>',
        # A faint edge, so the white tile holds its shape on a white background.
        f'<path d="{TILE}" fill="none" stroke="url(#edge)" stroke-width="3"/>',
    ]
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">'
            f'<defs>{"".join(defs)}</defs>{"".join(parts)}</svg>\n')


# ---------------------------------------------------------------------------
# .icns writing. These are the element types `iconutil` emits for a standard
# .iconset; all of them hold PNG data.

ICNS_ELEMENTS = [
    ("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64),
    ("ic07", 128), ("ic13", 256), ("ic08", 256), ("ic14", 512),
    ("ic09", 512), ("ic10", 1024),
]


def render_png(svg_path, size, out_path):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), str(svg_path), "-o", str(out_path)],
                   check=True)


def write_icns(pngs_by_size, out_path):
    chunks = b""
    for code, size in ICNS_ELEMENTS:
        data = pngs_by_size[size]
        chunks += code.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    out_path.write_bytes(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)


def main():
    parser = argparse.ArgumentParser(description="Generate Resources/AppIcon.svg and AppIcon.icns.")
    parser.add_argument("--preview", action="store_true",
                        help="also write build/icon-preview.png (1024 px)")
    args = parser.parse_args()

    try:
        subprocess.run(["rsvg-convert", "--version"], check=True, capture_output=True)
    except (OSError, subprocess.CalledProcessError):
        sys.exit("error: rsvg-convert not found (macOS: brew install librsvg)")

    RESOURCES.mkdir(exist_ok=True)
    svg_path = RESOURCES / "AppIcon.svg"
    svg_path.write_text(icon_svg())

    with tempfile.TemporaryDirectory() as tmp:
        pngs = {}
        for size in sorted({s for _, s in ICNS_ELEMENTS}):
            png = Path(tmp) / f"icon_{size}.png"
            render_png(svg_path, size, png)
            pngs[size] = png.read_bytes()
        write_icns(pngs, RESOURCES / "AppIcon.icns")

    if args.preview:
        (ROOT / "build").mkdir(exist_ok=True)
        render_png(svg_path, 1024, ROOT / "build" / "icon-preview.png")
    print(f"Wrote {svg_path.relative_to(ROOT)} and Resources/AppIcon.icns")


if __name__ == "__main__":
    main()
