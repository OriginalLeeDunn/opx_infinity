"""The opx minimap's texture atlas: a round map and its frame, drawn here.

One 1024x768 texture (BC3, sRGB, no mips -- the same setup as the game's own
atlas_minimap.xbm) holding four parts:

  disc   512x512 at (0,0)     a filled circle: the map's mask and its dark backing
  ring   512x512 at (512,0)   the bezel: an 11 px band, a hairline and 36 ticks
  glow   256x256 at (0,512)   a soft inner glow at the rim (combat / autodrive)

All three are drawn at the minimap's full 450 units (mask, backing, bezel and
highlights are all 450 square, centred), so their radii line up: the disc's
edge (r 248 of 256) lies UNDER the bezel's band (241-252), never outside it --
at 254 a sliver of map showed past the bezel -- and the glow lives inside it.
  north   64x64 at (256,512)  the north badge: dark disc, red rim, a white N

Every edge is anti-aliased analytically (coverage of the pixel by the shape).

THE TEXTURE IS PREMULTIPLIED, like every UI texture of the game: each pixel
stores colour x alpha, so a transparent pixel is black. The game blends a UI
image as  out = tex.rgb * tint * opacity + dst * (1 - tex.a * opacity)  -- the
game's own atlas_minimap_1080p.xbm has black in every transparent pixel and
colour ~= alpha (ratio 1.007) at every edge. 1.4.20's atlas stored WHITE where
alpha was 0: each 450-unit image then ADDED its tint over its whole square, and
the red bezel (0.92) plus the cyan zone ring (0.9) made the white square seen
in game. Premultiplied, a bilinear sample at an edge is exact as well.
"""
import io
import numpy as np
from PIL import Image, ImageDraw

W, H = 1024, 768
PARTS = {
    'disc': (0, 0, 512, 512),
    'ring': (512, 0, 1024, 512),
    'glow': (0, 512, 256, 768),
    'north': (256, 512, 320, 576),
}
RED = (255, 59, 71)


def _grid(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(np.float64)
    return x + 0.5, y + 0.5


def _band(r, inner, outer):
    """Coverage of a pixel at radius r by the annulus inner..outer (1 px AA)."""
    return np.clip(np.minimum(r - inner + 0.5, outer - r + 0.5), 0.0, 1.0)


def disc(size=512, radius=248.0):
    x, y = _grid(size, size)
    c = size / 2.0
    r = np.hypot(x - c, y - c)
    a = np.clip(radius - r + 0.5, 0.0, 1.0)
    rgb = np.ones((size, size, 3))
    return rgb, a


def ring(size=512):
    x, y = _grid(size, size)
    c = size / 2.0
    dx, dy = x - c, y - c
    r = np.hypot(dx, dy)
    band = _band(r, 241.0, 252.0)
    hair = _band(r, 231.0, 234.0) * 0.6
    # 36 ticks, every 10 degrees, between the hairline and the band.
    ang = np.arctan2(dx, -dy)  # 0 at the top, clockwise
    step = np.deg2rad(10.0)
    nearest = np.round(ang / step) * step
    # distance from the pixel to the tick's radial line, in pixels
    perp = np.abs(r * np.sin(ang - nearest))
    tick = np.clip(1.0 - perp + 0.5, 0.0, 1.0) * _band(r, 234.0, 240.0) * 0.75
    a = np.maximum(np.maximum(band, hair), tick)
    rgb = np.ones((size, size, 3))
    return rgb, a


def glow(size=256):
    x, y = _grid(size, size)
    c = size / 2.0
    t = np.hypot(x - c, y - c) / (c - 1.0)

    def smooth(e0, e1, v):
        k = np.clip((v - e0) / (e1 - e0), 0.0, 1.0)
        return k * k * (3 - 2 * k)
    # Peaks at the band's inner edge (241/256 ~ 0.94) and is gone under the band.
    a = smooth(0.58, 0.94, t) * (1.0 - smooth(0.94, 0.975, t))
    rgb = np.ones((size, size, 3))
    return rgb, a


def north(size=64):
    ss = 8
    big = Image.new('L', (size * ss, size * ss), 0)
    d = ImageDraw.Draw(big)
    # A geometric N: two uprights and the diagonal, 4.4 px strokes in a 20x24 box.
    cx, cy = size * ss / 2.0, size * ss / 2.0
    w, h, s = 20 * ss, 24 * ss, 4.4 * ss
    left, right, top, bottom = cx - w / 2, cx + w / 2, cy - h / 2, cy + h / 2
    d.rectangle([left, top, left + s, bottom], fill=255)
    d.rectangle([right - s, top, right, bottom], fill=255)
    d.polygon([(left, top), (left + s * 1.15, top), (right, bottom), (right - s * 1.15, bottom)], fill=255)
    glyph = np.asarray(big.resize((size, size), Image.BOX), dtype=np.float64) / 255.0
    x, y = _grid(size, size)
    c = size / 2.0
    r = np.hypot(x - c, y - c)
    fill = np.clip(27.5 - r + 0.5, 0.0, 1.0)
    rim = _band(r, 26.5, 30.5)
    dark = np.array([13, 15, 21]) / 255.0
    red = np.array(RED) / 255.0
    white = np.ones(3)
    # layers: dark disc (0.92), red rim over it, white glyph over both
    a_fill = fill * 0.92
    rgb = np.zeros((size, size, 3)) + red  # what an empty pixel carries: the rim's colour
    a = np.zeros((size, size))
    for colour, cov in ((dark, a_fill), (red, rim), (white, glyph)):
        out_a = cov + a * (1.0 - cov)
        with np.errstate(invalid='ignore', divide='ignore'):
            mix = (colour[None, None, :] * cov[..., None] + rgb * a[..., None] * (1.0 - cov[..., None])) / out_a[..., None]
        rgb = np.where(out_a[..., None] > 0, mix, rgb)
        a = out_a
    return rgb, a


def compose():
    """The atlas, PREMULTIPLIED (see above): rgb = colour x alpha, empty = black."""
    rgba = np.zeros((H, W, 4))
    for name, fn in (('disc', disc), ('ring', ring), ('glow', glow), ('north', north)):
        x0, y0, x1, y1 = PARTS[name]
        rgb, a = fn()
        assert rgb.shape[:2] == (y1 - y0, x1 - x0), name
        rgba[y0:y1, x0:x1, :3] = rgb * a[..., None]
        rgba[y0:y1, x0:x1, 3] = a
    return (np.clip(rgba, 0, 1) * 255.0 + 0.5).astype(np.uint8)


def bc3(rgba):
    """Raw BC3 (DXT5) blocks, top mip only, through Pillow's encoder."""
    im = Image.fromarray(rgba, 'RGBA')
    buf = io.BytesIO()
    im.save(buf, 'DDS', pixel_format='DXT5')
    blob = buf.getvalue()
    assert blob[:4] == b'DDS ' and blob[84:88] == b'DXT5', 'unexpected DDS header'
    data = blob[128:]
    assert len(data) == rgba.shape[0] * rgba.shape[1], (len(data), rgba.shape)
    return data


def uv(name):
    x0, y0, x1, y1 = PARTS[name]
    return {'Left': x0 / W, 'Top': y0 / H, 'Right': x1 / W, 'Bottom': y1 / H}, (x0, y0, x1, y1)
