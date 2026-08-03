#!/usr/bin/env python3
"""
Renders Resources/AppIcon-source.png (1024x1024) — the Quack app icon, drawn in
Apple's macOS Tahoe "Liquid Glass" idiom.

Design contract (keep these in sync if you ever add sibling app icons — the
whole family must share one light source, top-left):

  shape      full-bleed continuous-corner squircle (superellipse, n=4), which
             lands at an effective corner radius of ~22% of the width
  ground     single-hue linear gradient at 135deg, water blue: a bright sky
             tint at top-left deepening to a saturated deep blue bottom-right
  highlight  heavily blurred white radial glow near the top edge, ~22% peak
             alpha — the sheet of glass catching the light source
  rim        ~1.5px specular white inner edge along the top arc, fading out by
             mid-height; a matching faint dark rim along the bottom
  glyph      one flat duck silhouette, facing left, no eye and no outline. The
             outline was traced off the rubber-duck reference and low-pass
             smoothed, so it carries the reference's proportions with none of
             its detail
  planes     the glyph is exactly two translucency planes — a semi-opaque body
             that lets the blue read through, and a brighter wing on top, each
             with a specular upper-left edge. That layering is the whole point
             of the Liquid Glass look; pushing the body opacity past ~0.85
             collapses it back into a flat white sticker
  depth      the glyph casts a soft deep-blue shadow (NOT black) offset down
             and to the right, consistent with the top-left light source

Deliberately absent: water, ripples, eye, beak detail, feather detail. Two
shapes and a gradient is the whole icon — anything more stops reading at 32px.

Everything is drawn at 4x and downsampled, so curves and blurs stay clean.

Usage:  python3 Scripts/render-icon.py            # -> Resources/AppIcon-source.png
        QUACK_ICON_OUT=/tmp/x.png python3 Scripts/render-icon.py   # preview
Then:   Scripts/make-icon.sh      (or Scripts/build-icns.py on a non-mac host)
"""

import math
import os
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.environ.get("QUACK_ICON_OUT") or os.path.join(ROOT, "Resources", "AppIcon-source.png")

SIZE = 1024
SS = 4                      # supersample factor
S = SIZE * SS

# ---------------------------------------------------------------- palette ---
GRAD_TL = (128, 214, 255)   # bright sky-water, lit corner
GRAD_BR = (10, 74, 204)     # same hue family, deeper + more saturated
SHADOW_RGB = (5, 38, 110)   # deep blue, never black — matches the ground

CORNER_SPAN = 0.335         # corner box as a fraction of the width
CORNER_EXP = 4.0            # superellipse exponent inside that box

BODY_ALPHA = 0.82           # glass plane opacities, see "planes" above
WING_ALPHA = 0.96           # absolute, not additive — see the composite below
EDGE_ALPHA = 0.95           # specular upper-left edge on each plane

GLYPH_FRAC = 0.62           # glyph's long edge as a fraction of the canvas
GLYPH_CY = 0.495            # optical centre sits a hair above true centre
SHADOW_OFFSET = (10, 18)    # px @1024 — down and right of the top-left light
SHADOW_BLUR = 22            # px @1024
SHADOW_ALPHA = 0.30

# --------------------------------------------------------- duck geometry ---
# Both outlines were traced from the rubber-duck reference, resampled, and
# Gaussian low-pass filtered around the loop — that filtering is what removes
# the reference's small detail while keeping its proportions. They are control
# points for a closed Catmull-Rom spline, NOT a polygon: read them as a coarse
# skeleton, and re-run the trace rather than nudging individual points.
# Design space is 1000 units wide; the duck faces left, tail up on the right.
DUCK = [
    (370,1), (336,5), (302,14), (270,28), (241,46), (214,68), (190,94), (170,122),
    (154,153), (136,183), (107,201), (73,207), (38,210), (6,222), (2,255), (18,286),
    (43,311), (73,328), (106,339), (140,347), (168,366), (179,398), (177,433), (165,465),
    (148,496), (129,525), (112,555), (98,587), (87,620), (80,654), (76,689), (76,724),
    (81,758), (90,792), (104,824), (121,854), (143,881), (168,905), (196,925), (226,943),
    (258,958), (290,970), (323,981), (357,990), (391,997), (425,1002), (460,1006),
    (495,1007), (530,1007), (564,1004), (599,1000), (633,994), (667,986), (700,975),
    (733,963), (764,948), (795,931), (824,912), (851,891), (876,867), (899,841), (919,812),
    (936,782), (951,750), (964,718), (975,685), (984,651), (991,617), (997,583), (1000,548),
    (997,514), (983,482), (957,459), (925,447), (890,448), (858,460), (828,477), (797,493),
    (764,505), (731,514), (696,519), (661,520), (627,518), (592,512), (559,503), (532,483),
    (539,450), (557,420), (576,391), (593,360), (607,329), (618,296), (624,262), (626,227),
    (623,192), (615,158), (602,126), (583,97), (560,70), (534,48), (505,29), (473,15),
    (440,6), (405,1),
]
# The eye, taken from the same reference: a slightly tilted oval. It is punched
# *through* the glass rather than painted on, so the blue ground reads through
# it and the icon stays strictly two-tone. `rot` is clockwise degrees, matching
# the cv2.fitEllipse convention it was measured with.
EYE = dict(cx=276.0, cy=155.0, rx=36.0, ry=55.0, rot=28.0)

WING = [
    (380,572), (354,579), (329,590), (307,607), (290,628), (277,652), (269,678), (266,705),
    (269,732), (277,759), (289,783), (305,805), (324,825), (346,841), (371,854), (397,862),
    (424,868), (451,869), (478,869), (506,866), (533,863), (560,858), (586,852), (613,845),
    (639,837), (665,827), (689,815), (713,801), (734,784), (753,764), (769,742), (779,716),
    (781,689), (771,664), (753,644), (728,633), (701,631), (673,631), (646,630), (619,628),
    (591,625), (565,619), (538,612), (512,604), (486,595), (461,584), (435,576), (408,572),
]


# ---------------------------------------------------------------- helpers ---
def spline(pts, steps=14):
    """Closed uniform Catmull-Rom through `pts`, flattened to a polygon."""
    n, out = len(pts), []
    for i in range(n):
        p0, p1, p2, p3 = (pts[(i - 1) % n], pts[i], pts[(i + 1) % n], pts[(i + 2) % n])
        for s in range(steps):
            t = s / steps
            t2, t3 = t * t, t * t * t
            out.append(tuple(
                0.5 * ((2 * p1[c]) + (-p0[c] + p2[c]) * t
                       + (2 * p0[c] - 5 * p1[c] + 4 * p2[c] - p3[c]) * t2
                       + (-p0[c] + 3 * p1[c] - 3 * p2[c] + p3[c]) * t3)
                for c in (0, 1)
            ))
    return out


def squircle_mask(size, corner=CORNER_SPAN, n=CORNER_EXP, K=600):
    """Full-bleed continuous-corner squircle as an L-mode alpha mask.

    NOT a plain rounded rect, and not a whole-shape superellipse either — the
    first has a curvature jump where the arc meets the edge, the second bows
    the edges into a blob. This is the Apple construction: genuinely straight
    edges, joined by quarter-superellipse corners whose curvature eases to zero
    at the tangent point.
    """
    L = size * corner
    uv = [(abs(math.cos(math.pi / 2 * i / K)) ** (2.0 / n),
           abs(math.sin(math.pi / 2 * i / K)) ** (2.0 / n)) for i in range(K + 1)]
    pts = []
    for u, v in uv:            pts.append((L - L * u,        L - L * v))         # top-left
    for u, v in reversed(uv):  pts.append((size - L + L * u, L - L * v))         # top-right
    for u, v in uv:            pts.append((size - L + L * u, size - L + L * v))  # bottom-right
    for u, v in reversed(uv):  pts.append((L - L * u,        size - L + L * v))  # bottom-left
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m


def linear_gradient(size, c0, c1, angle_deg=135.0):
    """Axis-projected linear gradient, CSS angle convention: 0deg points up,
    90deg points right, so 135deg runs top-left -> bottom-right, i.e. c0 sits
    in the lit corner."""
    a = math.radians(angle_deg)
    dx, dy = math.sin(a), -math.cos(a)
    img = Image.new("RGB", (size, size))
    px = img.load()
    lo = min(0.0, dx) * size + min(0.0, dy) * size
    hi = max(0.0, dx) * size + max(0.0, dy) * size
    span = hi - lo
    for y in range(size):
        py = dy * y
        for x in range(size):
            t = (dx * x + py - lo) / span
            px[x, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return img


def vertical_ramp(w, h, c0, c1):
    img = Image.new("RGB", (1, h))
    px = img.load()
    for y in range(h):
        t = y / max(1, h - 1)
        px[0, y] = tuple(int(c0[i] + (c1[i] - c0[i]) * t) for i in range(3))
    return img.resize((w, h), Image.NEAREST)


def radial_glow(size, cx, cy, rx, ry, peak):
    """Soft white radial falloff, as an L-mode alpha mask."""
    m = Image.new("L", (size, size), 0)
    px = m.load()
    for y in range(size):
        ny = (y - cy) / ry
        ny2 = ny * ny
        for x in range(size):
            nx = (x - cx) / rx
            d2 = nx * nx + ny2
            if d2 < 1.0:
                px[x, y] = int(255 * peak * (1.0 - d2) ** 1.6)
    return m


def erode(mask, amount):
    """Shrink an alpha mask by roughly `amount` pixels."""
    out = mask
    for _ in range(max(1, int(round(amount / 2.0)))):
        out = out.filter(ImageFilter.MinFilter(3))
    return out


def scaled(mask, alpha):
    return mask.point(lambda p: int(p * alpha))


# ----------------------------------------------------------------- render ---
def main():
    px = lambda v: max(1, int(round(v * SS)))       # @1024 units -> supersampled

    # design space -> supersampled canvas, keyed off the duck's own bounds
    xs, ys = [p[0] for p in DUCK], [p[1] for p in DUCK]
    bx, by = min(xs), min(ys)
    k = (GLYPH_FRAC * S) / max(max(xs) - bx, max(ys) - by)
    ox = S / 2.0 - (bx + (max(xs) - bx) / 2.0) * k
    oy = GLYPH_CY * S - (by + (max(ys) - by) / 2.0) * k
    T = lambda p: (ox + p[0] * k, oy + p[1] * k)

    icon = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    shape = squircle_mask(S)

    def tint(rgb, mask):
        icon.paste(Image.new("RGBA", (S, S), tuple(rgb) + (255,)), (0, 0), mask)

    def fill(pts):
        m = Image.new("L", (S, S), 0)
        ImageDraw.Draw(m).polygon([T(p) for p in spline(pts)], fill=255)
        return m

    def oval(spec):
        """A rotated ellipse from a {cx, cy, rx, ry, rot} spec, as a mask."""
        w, h = int((spec["rx"] * 2) * k) + 8, int((spec["ry"] * 2) * k) + 8
        box = Image.new("L", (w, h), 0)
        ImageDraw.Draw(box).ellipse([4, 4, w - 4, h - 4], fill=255)
        box = box.rotate(-spec["rot"], resample=Image.BICUBIC, expand=True)
        m = Image.new("L", (S, S), 0)
        c = T((spec["cx"], spec["cy"]))
        m.paste(box, (int(c[0] - box.width / 2), int(c[1] - box.height / 2)))
        return m

    # 1. the ground. A gradient has no high-frequency detail, so rendering it
    #    small and upscaling is visually identical and ~1000x faster.
    icon.paste(linear_gradient(256, GRAD_TL, GRAD_BR, 135.0).resize((S, S), Image.BICUBIC), (0, 0))

    # 2. the light source: a blurred white glow off the top edge.
    glow = radial_glow(256, 128, 28, 172, 124, 0.22)
    tint((255, 255, 255), glow.resize((S, S), Image.BICUBIC).filter(ImageFilter.GaussianBlur(px(26))))

    # Punch the eye out of the silhouette *before* anything is painted, so the
    # body fill, the shadow and the specular edge all follow the hole — the eye
    # picks up its own lit rim for free, exactly like the outer contour.
    duck = ImageChops.subtract(fill(DUCK), oval(EYE))

    # 3. lift the glyph off the glass — deep blue, never black.
    sh = scaled(duck.filter(ImageFilter.GaussianBlur(px(SHADOW_BLUR))), SHADOW_ALPHA)
    tint(SHADOW_RGB, ImageChops.offset(sh, px(SHADOW_OFFSET[0]), px(SHADOW_OFFSET[1])))

    # 4. plane one: the body. Translucent, so the gradient reads through it.
    tint((255, 255, 255), scaled(duck, BODY_ALPHA))

    #    ...plus a specular edge on its upper-left arc, the lit rim of a pane of
    #    glass. Built as (mask - eroded mask), faded out toward the bottom-right
    #    so only the lit side carries it.
    lit = linear_gradient(256, (255, 255, 255), (0, 0, 0), 135.0).convert("L")
    lit = lit.resize((S, S), Image.BICUBIC).point(lambda v: int((v / 255.0) ** 1.5 * 255 * EDGE_ALPHA))
    tint((255, 255, 255), ImageChops.multiply(ImageChops.subtract(duck, erode(duck, px(5))), lit))

    # 5. plane two: the wing, brighter, clipped to the body.
    #    WING_ALPHA is the absolute whiteness we want, but we're painting over a
    #    body that already carries BODY_ALPHA — so solve for the delta that
    #    lands there rather than just subtracting the two.
    wing = ImageChops.multiply(fill(WING), duck)
    tint((255, 255, 255), scaled(wing, (WING_ALPHA - BODY_ALPHA) / (1.0 - BODY_ALPHA)))
    tint((255, 255, 255), ImageChops.multiply(ImageChops.subtract(wing, erode(wing, px(4))), lit))

    # 6. specular rim on the squircle itself: bright along the top arc, faintly
    #    dark along the bottom. Applied over everything, like real glass.
    rim = ImageChops.subtract(shape, erode(shape, px(3))).filter(ImageFilter.GaussianBlur(px(0.6)))
    top_fade = vertical_ramp(S, S, (255, 255, 255), (0, 0, 0)).convert("L")
    tint((255, 255, 255),
         ImageChops.multiply(rim, top_fade.point(lambda v: int((v / 255.0) ** 2.2 * 255 * 0.85))))
    bot_fade = vertical_ramp(S, S, (0, 0, 0), (255, 255, 255)).convert("L")
    tint((4, 30, 90),
         ImageChops.multiply(rim, bot_fade.point(lambda v: int((v / 255.0) ** 2.6 * 255 * 0.26))))

    # 7. clip everything to the squircle and land at 1024.
    icon.putalpha(ImageChops.multiply(icon.getchannel("A"), shape))
    icon.resize((SIZE, SIZE), Image.LANCZOS).save(OUT)
    print(f"✓ Wrote {OUT} ({SIZE}x{SIZE})")


if __name__ == "__main__":
    main()
