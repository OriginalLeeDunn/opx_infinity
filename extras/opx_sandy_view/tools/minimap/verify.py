"""Reads opx_minimap.archive back with an independent reader (rdar.py) and checks
it file by file: the four depot paths and nothing else, each file's bytes
equal to what was packed, the texture decoding to the atlas pixel for pixel,
and the edited widget tree saying what build.py meant."""
import json, os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import numpy as np
import texture2ddecoder
import atlas, bc3enc
from rdar import Archive, fnv1a64
from inlinepkg import inline_packages, chunks
from cr2w import CR2W

PATHS = [
    'base\\gameplay\\gui\\prototype_hud.inkhud',
    'base\\gameplay\\gui\\widgets\\minimap\\minimap.inkwidget',
    'opx\\ui\\minimap\\opx_minimap.inkatlas',
    'opx\\ui\\minimap\\opx_minimap.xbm',
]


def main(archive_path, extract_to):
    a = Archive(archive_path)
    assert a.version == 12, a.version
    want = {fnv1a64(p.lower()): p for p in PATHS}
    assert set(a.files) == set(want), 'archive holds other files'
    ok = 0
    for h, p in want.items():
        ninl, s0, s1, d0, d1 = a.files[h]
        segs = [a.read_segment(i) for i in range(s0, s1)]
        for i in range(s0, s1):
            off, z, size = a.segs[i]
            assert z == size, 'segment %d is compressed' % i
        data = b''.join(segs)
        assert data[:4] == b'CR2W'
        b_off, b_cnt, _ = struct.unpack_from('<III', data, 40 + 12 * 5)
        assert b_cnt == len(segs) - 1 == ninl, (p, b_cnt, len(segs), ninl)
        for k in range(b_cnt):
            fl, idx, off, disk, mem, crc = struct.unpack_from('<IIIIII', data, b_off + 24 * k)
            assert disk == mem and off + disk <= len(data), (p, k)
        dst = os.path.join(extract_to, p.replace('\\', '/'))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        open(dst, 'wb').write(data)
        print('ok  %-56s %8d bytes, %d buffer(s) inline' % (p, len(data), b_cnt))
        ok += 1

    # The texture, decoded from the archive's own bytes.
    xbm = open(os.path.join(extract_to, 'opx/ui/minimap/opx_minimap.xbm'), 'rb').read()
    b_off = struct.unpack_from('<I', xbm, 40 + 12 * 5)[0]
    fl, idx, off, disk, mem, crc = struct.unpack_from('<IIIIII', xbm, b_off)
    tex = xbm[off:off + disk]
    composed = atlas.compose()
    want_tex = bc3enc.encode(np.ascontiguousarray(composed[::-1]))
    assert tex == want_tex, 'texture bytes differ from the encoder output'
    rgba = np.frombuffer(texture2ddecoder.decode_bc3(tex, atlas.W, atlas.H), np.uint8).reshape(atlas.H, atlas.W, 4)
    # STORED BOTTOM-UP (see build.make_xbm): the data's FIRST rows are the image's
    # last ones. Flipped back, the decoded alpha is the atlas's; as stored, it is not.
    upright = rgba[::-1]
    diff = np.abs(upright[..., 3].astype(int) - composed[..., 3].astype(int))
    stored_as_is = np.abs(rgba[..., 3].astype(int) - composed[..., 3].astype(int))
    assert diff.mean() < 1.0 and np.percentile(diff, 99.9) <= 24, (diff.mean(), np.percentile(diff, 99.9))
    assert stored_as_is.mean() > 20, stored_as_is.mean()
    # The north badge, in the data: image rows 512-576 are data rows 192-255.
    assert rgba[767 - 544, 288, 3] > 200, rgba[767 - 544, 288, 3]
    print('ok  texture: %dx%d BC3, %d bytes, equal to the encoder output, stored bottom-up like the game\'s own; '
          'flipped back it is the atlas (alpha mean error %.2f)' % (atlas.W, atlas.H, len(tex), diff.mean()))

    # PREMULTIPLIED, like the game's own UI textures (atlas_minimap_1080p.xbm: black
    # in every transparent pixel, colour ~= alpha at the edges): no pixel brighter
    # than its alpha. 1.4.20 stored white where alpha was 0, and in game every
    # transparent pixel ADDED its image's tint -- the white square.
    rgb = upright[..., :3].astype(int)
    al = upright[..., 3].astype(int)
    clear = al == 0
    over = rgb.max(-1) - al
    # BC3 keeps 4 colour levels per block against 8 alpha levels, so an edge pixel
    # can come out a little brighter than its alpha: the game's own atlas has 0.29%
    # of its pixels more than 24/255 over; ours may not have more.
    assert clear.sum() > 0.3 * al.size, clear.sum()
    assert rgb[clear].max() <= 16, ('colour in transparent pixels', int(rgb[clear].max()))
    share = float((over > 24).mean())
    assert share <= 0.0029 and over.max() <= 64, (share, int(over.max()))
    print('ok  texture is premultiplied: %d transparent pixels, none brighter than %d/255; %.2f%% of pixels more than 24/255 '
          'over their alpha at the edges (the game\'s own atlas: 0.29%%)' % (int(clear.sum()), int(rgb[clear].max()), 100 * share))

    # The frame as the game blends it (composite.py): nothing in the square's
    # corners, a dark map inside the circle.
    import composite
    leak, level = composite.frame_check(archive_path)
    assert leak < 0.02, ('the frame changes the scene outside the circle', leak)
    assert level < 0.3, ('the inside of the circle is not dark', level)
    print('ok  composited as the game blends it: corners untouched (largest change %.3f), inside the circle dark (median %.2f)' % (leak, level))

    # The widget tree, from the inline package, by our own CR2W reader.
    mm = open(os.path.join(extract_to, 'base/gameplay/gui/widgets/minimap/minimap.inkwidget'), 'rb').read()
    c, pk = inline_packages(mm[:struct.unpack_from('<I', mm, 4 + 20)[0]])
    cc, ch = chunks(pk['Root'])
    cls = [e['cls'] for e in cc.exports]
    def visible(w):
        # CR2W leaves out a property at its default, and `visible` defaults to true.
        v = w.get('visible')
        return v is None or v == 1

    def find(name, typ):
        hits = [x for i, x in enumerate(ch) if cls[i] == typ and x.get('name') == name]
        assert len(hits) == 1, (name, typ, len(hits))
        return hits[0]
    imports = [x[0] for x in cc.imports]
    def ref(v):
        return imports[v[1] - 1] if isinstance(v, tuple) and v[0] == 'ref' and isinstance(v[1], int) else (v[1] if isinstance(v, tuple) else v)
    mask = find('mask', 'inkMaskWidget')
    assert mask.get('texturePart') == 'disc' and 'opx_minimap.inkatlas' in str(mask.get('textureAtlas')), mask.get('textureAtlas')
    bar = find('bar', 'inkImageWidget')
    assert visible(bar) and bar.get('texturePart') == 'ring'
    bg = find('bgColorFiller', 'inkImageWidget')
    assert bg.get('texturePart') == 'disc'
    for n in ('combatBorderHighlight', 'autoDriveBorderHighlight'):
        assert find(n, 'inkImageWidget').get('texturePart') == 'glow'
    assert find('border', 'inkImageWidget').get('texturePart') == 'ring'
    assert not visible(find('holder', 'inkVerticalPanelWidget'))
    assert not visible(find('MiniMapHeader', 'inkHorizontalPanelWidget'))
    badge = find('fluff', 'inkImageWidget')
    assert badge.get('texturePart') == 'north' and 'opx_minimap.inkatlas' in str(badge.get('textureAtlas')), (badge.get('texturePart'), badge.get('textureAtlas'))
    # No nine-slice on our parts (they carry no slices): CR2W leaves the default
    # (false) out.
    for n in ('bgColorFiller', 'combatBorderHighlight', 'autoDriveBorderHighlight', 'border', 'bar', 'fluff'):
        assert find(n, 'inkImageWidget').get('useNineSliceScale') in (None, 0, False), n
    assert visible(find('locationText', 'inkTextWidget'))
    print('ok  widget tree (inline package, %d chunks): mask=disc, backing=disc, bezel=ring, highlights=glow, zone frame=ring, north badge=the fluff image, district shown' % len(ch))

    # THE ATLAS IS LOADED WITH THE LIBRARY: the library's own (main) CR2W imports
    # it, Soft -- the flag of the game's own atlas entry -- through
    # externalDependenciesForInternalItems. Without it the game spawns the items
    # with the reference unresolved (a square, untextured minimap in game).
    main_imports = CR2W(mm[:struct.unpack_from('<I', mm, 4 + 20)[0]]).imports
    ours = [fl for path, cls_, fl in main_imports if path == 'opx\\ui\\minimap\\opx_minimap.inkatlas']
    theirs = [fl for path, cls_, fl in main_imports if path == 'base\\gameplay\\gui\\widgets\\minimap\\atlas_minimap.inkatlas']
    assert ours == [4] and theirs == [4], (ours, theirs)
    print('ok  the library declares opx_minimap.inkatlas (Soft), as it declares the game\'s own atlas')

    # Each file's archive dependencies are its hard imports, as CDPR's archives list them.
    from pack import hard_imports
    counts = {}
    for h, p in want.items():
        ninl, s0, s1, d0, d1 = a.files[h]
        raw = a.read_segment(s0)
        have = list(a.deps[d0:d1])
        expect = sorted({fnv1a64(x.lower()) for x in hard_imports(raw)})
        assert have == expect, (p, len(have), len(expect))
        counts[p.rsplit('\\', 1)[-1]] = len(have)
    assert counts['minimap.inkwidget'] == 15 and counts['prototype_hud.inkhud'] == 71, counts
    print('ok  archive dependencies = each file\'s hard imports: %s' % ', '.join('%s %d' % kv for kv in sorted(counts.items())))
    print('all checks passed (%d files)' % ok)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
