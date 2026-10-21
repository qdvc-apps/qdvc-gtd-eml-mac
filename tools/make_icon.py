#!/usr/bin/env python3
"""Generate the app icon: Resources/AppIcon.svg (vector master) and
Resources/AppIcon.icns (every macOS size, rendered natively from the vector).

The design is the back of a white envelope that fills the whole tile, its
top flap folded down to the middle with a mint band along the flap's edge,
and sealed there with a glossy green check mark (an email that has been
dealt with). Like QDVC Progress for macOS, the subject is the tile itself
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

# The seal: a green sphere with a white check mark.
FACE_LIGHT, FACE_MID, FACE_DARK = "#B8F0C8", "#34C26A", "#1E8C4A"
FEATURES = "#FFFFFF"

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
BAND_WIDTH = 42
SEAL_RADIUS = 118
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


def _seal(cx, cy, r):
    """A glossy green seal with a white check mark, in a white ring."""
    check = (f"M{cx - r * 0.42:.1f},{cy + r * 0.02:.1f} L{cx - r * 0.12:.1f},{cy + r * 0.32:.1f} "
             f"L{cx + r * 0.46:.1f},{cy - r * 0.30:.1f}")
    return [
        f'<g filter="url(#sealshadow)"><circle cx="{cx}" cy="{cy}" r="{r + 12}" fill="#FFFFFF"/></g>',
        f'<circle cx="{cx}" cy="{cy}" r="{r}" fill="url(#face)"/>',
        f'<path d="{check}" fill="none" stroke="{FEATURES}" stroke-width="{r * 0.2:.1f}" '
        'stroke-linecap="round" stroke-linejoin="round"/>',
        # specular highlight
        f'<ellipse cx="{cx - r * 0.30:.1f}" cy="{cy - r * 0.55:.1f}" rx="{r * 0.38:.1f}" '
        f'ry="{r * 0.18:.1f}" fill="#FFFFFF" opacity="0.45"/>',
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
        '<radialGradient id="face" cx="0.38" cy="0.30" r="0.8">'
        f'<stop offset="0" stop-color="{FACE_LIGHT}"/><stop offset="0.55" stop-color="{FACE_MID}"/>'
        f'<stop offset="1" stop-color="{FACE_DARK}"/></radialGradient>',
        f'<clipPath id="clip"><path d="{TILE}"/></clipPath>',
        f'<clipPath id="flapclip"><path d="{flap}"/></clipPath>',
        # Apple template shadow: black, 28 px blur radius, 12 px down, 50 %.
        '<filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">'
        f'<feGaussianBlur in="SourceAlpha" stdDeviation="{sigma}"/><feOffset dy="{SHADOW_OFFSET_Y}"/>'
        f'<feComponentTransfer><feFuncA type="linear" slope="{SHADOW_OPACITY}"/></feComponentTransfer>'
        '<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter>',
        _tinted_shadow("flapshadow", 18, 18, 0.42),
        _tinted_shadow("foldshadow", 10, -6, 0.12),
        _tinted_shadow("sealshadow", 12, 12, 0.45),
    ]
    parts = [
        f'<g filter="url(#shadow)"><path d="{TILE}" fill="#FFFFFF"/></g>',
        '<g clip-path="url(#clip)">',
        *envelope,
        *_seal(cx, tip - 6, SEAL_RADIUS),
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
