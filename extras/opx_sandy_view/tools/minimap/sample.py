"""Draws the atlas's four parts AS THE GAME SAMPLES AND BLENDS THEM, from the
archive's own texture: v = 0 at the last row of the texture data, and the
texture premultiplied (out = tex.rgb + dst * (1 - tex.a), see README). A disc, a
ring with ticks, a soft glow and an upright N, each on the plain background,
mean the game will draw them so; 1.4.18's texture, stored top-down, drew a dome,
a corner of glow and a mirrored N, and 1.4.18-1.4.20's, white where it was
transparent, drew every part as a white square. `composite.py` draws the whole
minimap the same way.

usage: sample.py opx_minimap.archive out.png
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np
import texture2ddecoder
from PIL import Image

import atlas
from rdar import Archive

BACKGROUND = np.array([40, 0, 60]) / 255.0


def game_sample(data_rgba, uv, out_w, out_h):
    height, width = data_rgba.shape[:2]
    ys = (np.arange(out_h) + 0.5) / out_h
    xs = (np.arange(out_w) + 0.5) / out_w
    v = uv['Top'] + ys * (uv['Bottom'] - uv['Top'])
    u = uv['Left'] + xs * (uv['Right'] - uv['Left'])
    rows = np.clip(((1.0 - v) * height).astype(int), 0, height - 1)
    cols = np.clip((u * width).astype(int), 0, width - 1)
    return data_rgba[rows][:, cols]


def main(archive_path, out_path):
    a = Archive(archive_path)
    xbm = a.read('opx\\ui\\minimap\\opx_minimap.xbm')
    b_off = struct.unpack_from('<I', xbm, 40 + 12 * 5)[0]
    fl, idx, off, disk, mem, crc = struct.unpack_from('<IIIIII', xbm, b_off)
    tex = xbm[off:off + disk]
    bgra = np.frombuffer(texture2ddecoder.decode_bc3(tex, atlas.W, atlas.H), np.uint8).reshape(atlas.H, atlas.W, 4)
    rgba = bgra[..., [2, 1, 0, 3]].astype(np.float64) / 255.0
    sizes = (('disc', 192), ('ring', 192), ('glow', 192), ('north', 64))
    width = sum(s for _, s in sizes) + 12 * (len(sizes) + 1)
    out = np.zeros((216, width, 3)) + BACKGROUND
    x = 12
    for name, size in sizes:
        uv, _ = atlas.uv(name)
        tile = game_sample(rgba, uv, size, size)
        region = out[12:12 + size, x:x + size]
        region[...] = np.clip(tile[..., :3] + region * (1.0 - tile[..., 3:4]), 0.0, 1.0)
        x += size + 12
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), 'RGB').save(out_path)
    print('wrote', out_path)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
