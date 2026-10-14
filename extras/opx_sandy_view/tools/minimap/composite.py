"""Composites the round minimap THE WAY THE GAME BLENDS IT, from an archive's own
texture, so a frame that would draw wrong in game draws wrong here first.

The game's UI images are premultiplied: every pixel lands as
    out = tex.rgb * tint * opacity + dst * (1 - tex.a * opacity)
(the game's own atlas_minimap_1080p.xbm stores black in every transparent pixel
and colour ~= alpha at every edge). A texture that stores colour where alpha is
0 therefore ADDS that colour over its whole quad -- 1.4.20's atlas stored white
there, and its 450-unit bezel (red, 0.92) and zone ring (cyan, 0.9) added up to
the white square seen in game.

Layers, bottom to top, as MiniMapContainer draws them (childOrder Backward: the
LAST child is drawn first): the backing disc, the map (clipped by the mask
disc's alpha), the bezel ring, the player arrow, the zone ring, the N badge.
The map is a stand-in (a street grid), the scene behind a dark gradient.

usage: composite.py out.png label=archive [label=archive ...]
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np
import texture2ddecoder
from PIL import Image, ImageDraw, ImageFont

import atlas
from rdar import Archive

S = 450            # the minimap's size in its own units, drawn 1:1 here
PAD = 70           # scene around it
RED = np.array([1.0, 59 / 255, 71 / 255])
ZONE = np.array([0.37, 0.96, 1.0])      # SecurityArea.FillColor, safe zone
BACKING = np.array([0.05, 0.05, 0.09])  # Fullscreen_PrimaryBackgroundDarkest


def texture(archive_path):
    a = Archive(archive_path)
    xbm = a.read('opx\\ui\\minimap\\opx_minimap.xbm')
    b_off = struct.unpack_from('<I', xbm, 40 + 12 * 5)[0]
    fl, idx, off, disk, mem, crc = struct.unpack_from('<IIIIII', xbm, b_off)
    tex = xbm[off:off + disk]
    bgra = np.frombuffer(texture2ddecoder.decode_bc3(tex, atlas.W, atlas.H), np.uint8).reshape(atlas.H, atlas.W, 4)
    return bgra[..., [2, 1, 0, 3]].astype(np.float64) / 255.0


def part(rgba, name, size):
    """The part as the game samples it: v = 0 at the texture's last row (bilinear)."""
    uv, _ = atlas.uv(name)
    h, w = rgba.shape[:2]
    ys = (np.arange(size) + 0.5) / size
    xs = (np.arange(size) + 0.5) / size
    v = uv['Top'] + ys * (uv['Bottom'] - uv['Top'])
    u = uv['Left'] + xs * (uv['Right'] - uv['Left'])
    fy = (1.0 - v) * h - 0.5
    fx = u * w - 0.5
    y0 = np.clip(np.floor(fy).astype(int), 0, h - 1)
    x0 = np.clip(np.floor(fx).astype(int), 0, w - 1)
    y1 = np.clip(y0 + 1, 0, h - 1)
    x1 = np.clip(x0 + 1, 0, w - 1)
    ty = np.clip(fy - np.floor(fy), 0, 1)[:, None, None]
    tx = np.clip(fx - np.floor(fx), 0, 1)[None, :, None]
    top = rgba[y0][:, x0] * (1 - tx) + rgba[y0][:, x1] * tx
    bot = rgba[y1][:, x0] * (1 - tx) + rgba[y1][:, x1] * tx
    return top * (1 - ty) + bot * ty


def blend(dst, src, x, y, tint, opacity):
    """Premultiplied, as the game: out = src.rgb*tint*op + dst*(1 - src.a*op)."""
    h, w = src.shape[:2]
    region = dst[y:y + h, x:x + w]
    a = src[..., 3:4] * opacity
    region[...] = np.clip(src[..., :3] * tint * opacity + region * (1.0 - a), 0.0, 1.0)


def stand_in_map(size):
    """Premultiplied RGBA: the city as thin light streets and building outlines."""
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    rng = np.random.default_rng(7)
    for i in range(-2, 12):
        x = i * 48 + 10
        d.line([(x, 0), (x + 60, size)], fill=(205, 210, 220, 230), width=3)
        y = i * 52 + 5
        d.line([(0, y), (size, y - 40)], fill=(205, 210, 220, 230), width=3)
    for _ in range(40):
        bx, by = rng.integers(0, size, 2)
        bw, bh = rng.integers(18, 46, 2)
        d.rectangle([bx, by, bx + bw, by + bh], outline=(150, 160, 175, 200), width=1)
    m = np.asarray(im, np.float64) / 255.0
    m[..., :3] *= m[..., 3:4]
    return m


def arrow(size=26):
    im = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(im).polygon([(size / 2, 2), (size - 4, size - 3), (size / 2, size - 9), (4, size - 3)], fill=(40, 255, 190, 255))
    m = np.asarray(im, np.float64) / 255.0
    m[..., :3] *= m[..., 3:4]
    return m


def scene_behind():
    W = S + 2 * PAD
    yy, xx = np.mgrid[0:W, 0:W] / W
    return np.stack([0.10 + 0.05 * xx, 0.08 + 0.03 * yy, 0.11 + 0.02 * xx], -1)


def render(archive_path, north_deg=58.0, raw=False):
    rgba = texture(archive_path)
    scene = scene_behind()
    o = PAD
    blend(scene, part(rgba, 'disc', S), o, o, BACKING, 0.75)
    masked = stand_in_map(S) * part(rgba, 'disc', S)[..., 3:4]   # the mask: the disc's alpha
    blend(scene, masked, o, o, np.ones(3), 1.0)
    blend(scene, part(rgba, 'ring', S), o, o, RED, 0.92)
    ar = arrow()
    blend(scene, ar, o + S // 2 - 13, o + S // 2 - 13, np.ones(3), 1.0)
    blend(scene, part(rgba, 'ring', S), o, o, ZONE, 0.9)
    t = np.deg2rad(north_deg)
    nx = int(round(o + S / 2 + 214 * np.sin(t) - 23))
    ny = int(round(o + S / 2 - 214 * np.cos(t) - 23))
    blend(scene, part(rgba, 'north', 46), nx, ny, np.ones(3), 1.0)
    if raw:
        return scene
    return Image.fromarray((scene * 255 + 0.5).astype(np.uint8), 'RGB')


def frame_check(archive_path):
    """What verify.py asserts of the composited frame. Returns (corner_leak,
    inside_level): the largest change the frame makes to the scene in the
    square's four corners (outside the circle -- 0 when the frame is round), and
    the mean level inside the circle away from the streets (dark: the backing)."""
    drawn = render(archive_path, raw=True)
    behind = scene_behind()
    o = PAD
    leak = 0.0
    for cy, cx in ((o + 30, o + 30), (o + 30, o + S - 30), (o + S - 30, o + 30), (o + S - 30, o + S - 30)):
        leak = max(leak, float(np.abs(drawn[cy - 12:cy + 12, cx - 12:cx + 12] - behind[cy - 12:cy + 12, cx - 12:cx + 12]).max()))
    c = o + S // 2
    inside = drawn[c - 120:c + 120, c - 120:c + 120]
    level = float(np.median(inside))
    return leak, level


def main(out_path, pairs):
    tiles = [(label, render(path)) for label, path in pairs]
    W = S + 2 * PAD
    sheet = Image.new('RGB', (len(tiles) * (W + 16) + 16, W + 56), (24, 24, 28))
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf', 22)
    except OSError:
        font = ImageFont.load_default()
    for i, (label, im) in enumerate(tiles):
        x = 16 + i * (W + 16)
        d.text((x, 12), label, fill=(235, 235, 240), font=font)
        sheet.paste(im, (x, 44))
    sheet.save(out_path)
    print('wrote', out_path)


if __name__ == '__main__':
    main(sys.argv[1], [a.split('=', 1) for a in sys.argv[2:]])
