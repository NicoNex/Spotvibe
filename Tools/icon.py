#!/usr/bin/env python3
"""Writes Resources/icon.svg — the Lens Over Grid mark.

A port of the generator on the icon board, kept as code rather than as hand-written
SVG because the tile is a superellipse: every corner is a sampled curve, so the path
is 64 points that no one should be editing by hand.

    python3 Tools/icon.py        # rewrites Resources/icon.svg

The raster pipeline is Tools/make-icns.sh; this only draws the vector.
"""

import math
import pathlib

# The icon grid Apple draws on, and the continuous corner: r = 22.37% of the side,
# superellipse exponent 5. A plain rounded rectangle reads as wrong beside it — the
# curvature has to fall to zero where the corner meets the straight edge.
SIDE, RADIUS, N = 1024, 229, 5


def squircle(x, y, w, h, r, steps=16):
    pts = []
    e = lambda t: math.cos(t) ** (2 / N)
    f = lambda t: math.sin(t) ** (2 / N)
    tl, tr = (x + r, y + r), (x + w - r, y + r)
    br, bl = (x + w - r, y + h - r), (x + r, y + h - r)
    for i in range(steps + 1):
        t = i / steps * math.pi / 2
        pts.append(f"{tl[0] - r * e(t):.1f},{tl[1] - r * f(t):.1f}")
    for i in range(steps + 1):
        t = i / steps * math.pi / 2
        pts.append(f"{tr[0] + r * f(t):.1f},{tr[1] - r * e(t):.1f}")
    for i in range(steps + 1):
        t = i / steps * math.pi / 2
        pts.append(f"{br[0] + r * e(t):.1f},{br[1] + r * f(t):.1f}")
    for i in range(steps + 1):
        t = i / steps * math.pi / 2
        pts.append(f"{bl[0] - r * f(t):.1f},{bl[1] + r * e(t):.1f}")
    return "M" + "L".join(pts) + "Z"


def cell(x, y, s, fill):
    return f'<path d="{squircle(x, y, s, s, s * 0.255, 7)}" fill="{fill}"/>'


TILE = squircle(0, 0, SIDE, SIDE, RADIUS)

# The system palette, in the order the Apps icon runs them.
COLORS = ["#FF6B5A", "#FF9F0A", "#FFD60A",
          "#30D158", "#64D2FF", "#0A84FF",
          "#5E5CE6", "#BF5AF2", "#FF375F"]

CELL, GAP, ORIGIN = 150, 36, 251
LENS_X, LENS_Y, LENS_R = 512, 478, 292

grid = "".join(
    cell(ORIGIN + col * (CELL + GAP), ORIGIN + row * (CELL + GAP), CELL, COLORS[row * 3 + col])
    for row in range(3) for col in range(3)
)

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {SIDE} {SIDE}" width="{SIDE}" height="{SIDE}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#2B3A6E"/><stop offset="1" stop-color="#0D1222"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#fff" stop-opacity=".20"/>
      <stop offset=".40" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="glass" cx=".34" cy=".26" r=".92">
      <stop offset="0" stop-color="#fff" stop-opacity=".40"/>
      <stop offset=".55" stop-color="#fff" stop-opacity=".05"/>
      <stop offset="1" stop-color="#8FB4FF" stop-opacity=".18"/>
    </radialGradient>
    <clipPath id="tile"><path d="{TILE}"/></clipPath>
    <clipPath id="lens"><circle cx="{LENS_X}" cy="{LENS_Y}" r="{LENS_R}"/></clipPath>
  </defs>

  <path d="{TILE}" fill="url(#bg)"/>
  <g clip-path="url(#tile)">
    <!-- the grid as it lies, dimmed: what the lens is looking at -->
    <g opacity=".42">{grid}</g>
    <!-- and the same grid magnified, clipped to the glass -->
    <g clip-path="url(#lens)">
      <g transform="translate({LENS_X},{LENS_Y}) scale(1.52) translate({-LENS_X},{-LENS_Y})">{grid}</g>
      <circle cx="{LENS_X}" cy="{LENS_Y}" r="{LENS_R}" fill="url(#glass)"/>
    </g>
    <!-- rim, inner rim, and the specular arc that puts the light source above -->
    <circle cx="{LENS_X}" cy="{LENS_Y}" r="{LENS_R}" fill="none" stroke="#fff" stroke-opacity=".55" stroke-width="11"/>
    <circle cx="{LENS_X}" cy="{LENS_Y}" r="{LENS_R - 15}" fill="none" stroke="#fff" stroke-opacity=".18" stroke-width="5"/>
    <path d="M330 330 A{LENS_R} {LENS_R} 0 0 1 560 196" fill="none" stroke="#fff" stroke-opacity=".62"
          stroke-width="16" stroke-linecap="round"/>
  </g>
  <path d="{TILE}" fill="url(#sheen)"/>
  <path d="{TILE}" fill="none" stroke="#ffffff" stroke-opacity=".16" stroke-width="3"/>
</svg>
'''

out = pathlib.Path(__file__).resolve().parent.parent / "Resources" / "icon.svg"
out.write_text(SVG)
print(f"wrote {out}")
