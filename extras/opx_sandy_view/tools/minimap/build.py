"""Builds opx_minimap: the round, bottom-right minimap, from the game's own files.

Inputs (WolvenKit 9.0.1 JSON of the base game's 2.31 files, `wk convert serialize`):
  base/gameplay/gui/widgets/minimap/minimap.inkwidget
  base/gameplay/gui/prototype_hud.inkhud
  base/gameplay/gui/widgets/minimap/atlas_minimap.inkatlas      (template)
  base/gameplay/gui/widgets/minimap/atlas_minimap_1080p.xbm     (template)

Outputs (JSON, then `wk convert deserialize`):
  opx/ui/minimap/opx_minimap.xbm        the atlas texture (atlas.py, bc3enc.py)
  opx/ui/minimap/opx_minimap.inkatlas   its four parts
  base/gameplay/gui/widgets/minimap/minimap.inkwidget   (edited, see EDITS)
  base/gameplay/gui/prototype_hud.inkhud                 (the minimap entry moved)

Every edit is applied to BOTH copies of the widget tree an inkwidget carries
(`package`, the editor's CR2W, and `packageData`, the cooked RedPackage), and
each one asserts that it found exactly the widget it meant: a change that finds
nothing, or two of something, stops the build.
"""
import base64
import copy
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import atlas
import bc3enc

ATLAS_PATH = 'opx\\ui\\minimap\\opx_minimap.inkatlas'
XBM_PATH = 'opx\\ui\\minimap\\opx_minimap.xbm'
# The opx HUD's red (--op-red), and its text red (--op-red-text).
RED = (1.0, 59 / 255, 71 / 255)
RED_TEXT = (232 / 255, 100 / 255, 109 / 255)

# Where the minimap sits now: the screen's bottom-right corner, in the HUD's
# 3840x2160 units, clear of the edge by the same distance the opx HUD keeps.
HUD_MARGIN_RIGHT = 64.0
HUD_MARGIN_BOTTOM = 72.0


def cname(value):
    return {'$type': 'CName', '$storage': 'string', '$value': value}


def depot(value, flags='Default'):
    return {'DepotPath': {'$type': 'ResourcePath', '$storage': 'string', '$value': value}, 'Flags': flags}


def vec2(x, y):
    return {'$type': 'Vector2', 'X': x, 'Y': y}


def margin(left=0, top=0, right=0, bottom=0):
    return {'$type': 'inkMargin', 'bottom': bottom, 'left': left, 'right': right, 'top': top}


def hdr(r, g, b, a=1.0):
    return {'$type': 'HDRColor', 'Alpha': a, 'Blue': b, 'Green': g, 'Red': r}


# ---------------------------------------------------------------- the tree --

class Tree:
    """One copy of the widget tree: handle ids resolved, widgets by name."""

    def __init__(self, root, label):
        self.label = label
        self.by_id = {}
        self.widgets = []
        self._walk(root)

    def _walk(self, o):
        if isinstance(o, dict):
            if 'HandleId' in o and isinstance(o.get('Data'), dict):
                self.by_id[o['HandleId']] = o['Data']
            t = o.get('$type')
            if isinstance(t, str) and t.startswith('ink') and t.endswith('Widget') and isinstance(o.get('name'), dict):
                self.widgets.append(o)
            for v in o.values():
                self._walk(v)
        elif isinstance(o, list):
            for v in o:
                self._walk(v)

    def parent_name(self, w):
        ref = w.get('parentWidget') or {}
        pid = ref.get('HandleRefId') or ref.get('HandleId')
        parent = self.by_id.get(pid)
        return parent['name']['$value'] if parent else None

    def one(self, name, typ=None, parent=None):
        hits = [w for w in self.widgets if w['name']['$value'] == name
                and (typ is None or w['$type'] == typ)
                and (parent is None or self.parent_name(w) == parent)]
        if len(hits) != 1:
            raise SystemExit('%s: %d widgets named %s (%s, parent %s)' % (self.label, len(hits), name, typ, parent))
        return hits[0]


def drop_binding(w, prop):
    pm = w.get('propertyManager')
    data = pm.get('Data') if isinstance(pm, dict) else None
    if not data:
        raise SystemExit('%s has no inline property manager' % w['name']['$value'])
    before = len(data['bindings'])
    data['bindings'] = [b for b in data['bindings'] if b['propertyName']['$value'] != prop]
    if len(data['bindings']) != before - 1:
        raise SystemExit('%s: binding %s not found exactly once' % (w['name']['$value'], prop))


def retexture(w, part):
    w['textureAtlas'] = depot(ATLAS_PATH)
    w['texturePart'] = cname(part)
    # Our parts carry no nine-slice rects (the atlas's `slices` are empty and the
    # widgets' own margins are 0): the plain stretch, as the bezel and the badge
    # already draw, instead of a nine-slice with nothing to slice.
    if 'useNineSliceScale' in w:
        w['useNineSliceScale'] = 0


# What changes in minimap.inkwidget, widget by widget. The ORDER and the NUMBER
# of children never change anywhere: the minimap's animations address widgets by
# their index path (`[3, 5]` is MiniMapContainer's sixth child), so a widget
# added or removed would retarget every animation after it.
def edit_minimap(t):
    # The square's decorations, gone: the holder glyphs over its top-right
    # corner and the header line.
    t.one('holder', 'inkVerticalPanelWidget', 'Root')['visible'] = 0
    t.one('MiniMapHeader', 'inkHorizontalPanelWidget', 'Root')['visible'] = 0

    # THE NORTH BADGE IS THE SQUARE'S CORNER FLUFF, REUSED. It is MiniMapContainer's
    # first child -- in this library the first child draws on top -- no animation
    # of minimap_animations.inkanim targets it (index path [3, 0] appears in none),
    # and it is an image defined HERE, so its atlas and part resolve the way every
    # data-defined image's do. 1.4.18/1.4.19 made the badge in REDscript
    # (SetAtlasResource + SetTexturePart before the atlas had loaded): it drew as
    # a white square. Hidden until OpxMinimap.reds places it on the bezel.
    badge = t.one('fluff', 'inkImageWidget', 'MiniMapContainer')
    retexture(badge, 'north')
    drop_binding(badge, 'tintColor')
    drop_binding(badge, 'textureAtlas')
    badge['tintColor'] = hdr(1.0, 1.0, 1.0)
    badge['opacity'] = 1.0
    badge['fitToContent'] = 0
    badge['size'] = vec2(46.0, 46.0)
    badge['layout']['anchor'] = 'Centered'
    badge['layout']['anchorPoint'] = vec2(0.5, 0.5)
    badge['layout']['HAlign'] = 'Center'
    badge['layout']['VAlign'] = 'Center'
    badge['layout']['margin'] = margin()
    badge['renderTransform']['translation'] = vec2(0.0, -214.0)
    badge['visible'] = 0

    # THE MAP'S SHAPE. The mask is the atlas's disc: everything the map draws
    # (streets, GPS line, pins inside the view) is clipped to the circle.
    retexture(t.one('mask', 'inkMaskWidget', 'maskedContainer'), 'disc')

    # Its dark backing, round too (the style binding that picks the game's
    # minimap atlas is removed, or it would put the square back).
    bg = t.one('bgColorFiller', 'inkImageWidget', 'MiniMapContainer')
    retexture(bg, 'disc')
    drop_binding(bg, 'textureAtlas')
    bg['layout']['margin'] = margin()

    # THE BEZEL: the unused `bar` image (hidden in the game, animated by
    # nothing), now the ring, the size of the minimap and centred on it, in
    # the opx HUD's red.
    bar = t.one('bar', 'inkImageWidget', 'MiniMapContainer')
    retexture(bar, 'ring')
    drop_binding(bar, 'textureAtlas')
    drop_binding(bar, 'tintColor')
    bar['visible'] = 1
    bar['fitToContent'] = 0
    bar['size'] = vec2(450.0, 450.0)
    bar['opacity'] = 0.92
    bar['tintColor'] = hdr(*RED)
    bar['layout']['anchor'] = 'Centered'
    bar['layout']['anchorPoint'] = vec2(0.5, 0.5)
    bar['layout']['HAlign'] = 'Center'
    bar['layout']['VAlign'] = 'Center'
    bar['layout']['margin'] = margin()

    # Combat (red) and autodrive (blue): a glow inside the rim, pulsed by the
    # game's own animations exactly as the square's soft fill was.
    for name in ('combatBorderHighlight', 'autoDriveBorderHighlight'):
        w = t.one(name, 'inkImageWidget', 'MiniMapContainer')
        retexture(w, 'glow')
        drop_binding(w, 'textureAtlas')

    # The zone notice (SAFE / HOSTILE / RESTRICTED / COMBAT): its frame is the
    # ring, in the zone's colour, over the whole circle; its label sits inside
    # the circle near the bottom. The game fades both in and out as before.
    zone = t.one('zoneVignette', 'inkCanvasWidget', 'MiniMapContainer')
    zone['layout']['anchor'] = 'Fill'
    zone['layout']['margin'] = margin()
    border = t.one('border', 'inkImageWidget', 'zoneVignette')
    retexture(border, 'ring')
    drop_binding(border, 'textureAtlas')
    border['opacity'] = 0.9
    border['layout']['anchor'] = 'Fill'
    border['layout']['anchorPoint'] = vec2(0.5, 0.5)
    border['layout']['margin'] = margin()
    pill = t.one('player_zone_alert_center', 'inkFlexWidget', 'zoneVignette')
    pill['layout']['margin'] = margin(left=90.0, right=90.0, bottom=74.0)

    # Pins pushed to the edge (an objective out of view) are clamped to a
    # square; 360 across keeps that square's corners on the bezel instead of
    # floating outside the circle (390, the game's, put them 50 units out).
    clamp = t.one('clampedMappinContainer', 'inkCanvasWidget', 'unmaskedContainer')
    clamp['size'] = vec2(360.0, 360.0)
    clamp['layout']['margin'] = margin()

    # THE DISTRICT, above the circle and centred: the game writes it here on
    # every change of location and kept it hidden.
    loc = t.one('location', 'inkCanvasWidget', 'Root')
    loc['layout']['anchor'] = 'TopCenter'
    loc['layout']['anchorPoint'] = vec2(0.5, 1.0)
    loc['layout']['margin'] = margin(top=-14.0)
    loc['size'] = vec2(440.0, 40.0)
    text = t.one('locationText', 'inkTextWidget', 'location')
    text['visible'] = 1
    text['layout']['anchor'] = 'Fill'
    text['layout']['anchorPoint'] = vec2(0.5, 0.5)
    text['layout']['margin'] = margin()
    text['justification'] = 'Center'
    text['textHorizontalAlignment'] = 'Center'
    text['textVerticalAlignment'] = 'Center'
    text['fontSize'] = 30
    text['text'] = ''
    drop_binding(text, 'tintColor')
    text['tintColor'] = hdr(*RED_TEXT)


def edit_hud(root):
    hits = [e for e in root['entries'] if e['hudEntryName']['$value'] == 'minimap']
    if len(hits) != 1:
        raise SystemExit('prototype_hud: %d minimap entries' % len(hits))
    e = hits[0]
    # Out of the top-right slot (shared with the wanted bar and the quest list)
    # and onto the HUD itself, anchored to the bottom-right corner.
    e['attachToSlot'] = 0
    e['anchorPlace'] = 'BottomRight'
    e['anchorPoint'] = vec2(1.0, 1.0)
    e['margins'] = margin(right=HUD_MARGIN_RIGHT, bottom=HUD_MARGIN_BOTTOM)
    e['slotParams']['slotID'] = cname('None')
    e['slotParams']['useSlotLayout'] = 1
    lo = e['slotParams']['layoutOverride']
    lo['anchor'] = 'BottomRight'
    lo['anchorPoint'] = vec2(1.0, 1.0)
    lo['HAlign'] = 'Right'
    lo['VAlign'] = 'Bottom'
    lo['margin'] = margin(right=HUD_MARGIN_RIGHT, bottom=HUD_MARGIN_BOTTOM)


# ------------------------------------------------------------ the textures --

def make_xbm(template):
    j = copy.deepcopy(template)
    rgba = atlas.compose()
    # STORED BOTTOM-UP. The game samples an atlas with v = 0 at the LAST row of the
    # texture data: the game's own atlas_minimap_1080p.xbm, decoded as stored,
    # has its `minimap_mask` part (UV v 0.004-0.883) at rows 30-255 of 256 and
    # its N glyphs upside down. 1.4.18 stored ours top-down, and in game every
    # part came out of the other half of the texture, upside down: a square map,
    # a dome where the disc should be, the rim glow in a corner and a mirrored
    # N by the arrow. The UVs stay in top-down image terms (atlas.uv); the rows go
    # in reversed.
    data = bc3enc.encode(np.ascontiguousarray(rgba[::-1]))
    w, h = atlas.W, atlas.H
    root = j['Data']['RootChunk']
    assert root['$type'] == 'CBitmapTexture'
    assert root['setup']['compression'] == 'TCM_DXTAlpha' and root['setup']['group'] == 'TEXG_Generic_UI'
    root['width'] = w
    root['height'] = h
    blob = root['renderTextureResource']['renderResourceBlobPC']['Data']
    hdr_ = blob['header']
    hdr_['sizeInfo']['width'] = w
    hdr_['sizeInfo']['height'] = h
    assert len(hdr_['mipMapInfo']) == 1
    hdr_['mipMapInfo'][0]['layout']['rowPitch'] = (w // 4) * 16
    hdr_['mipMapInfo'][0]['layout']['slicePitch'] = len(data)
    hdr_['mipMapInfo'][0]['placement']['offset'] = 0
    hdr_['mipMapInfo'][0]['placement']['size'] = len(data)
    hdr_['textureInfo']['sliceSize'] = len(data)
    hdr_['textureInfo']['textureDataSize'] = len(data)
    blob['textureData']['Bytes'] = base64.b64encode(data).decode('ascii')
    j['Data']['BuildVersion'] = len(data)
    return j, rgba, data


def make_inkatlas(template):
    j = copy.deepcopy(template)
    root = j['Data']['RootChunk']
    slots = root['slots']['Elements']
    assert len(slots) == 3
    parts = []
    for name in ('disc', 'ring', 'glow', 'north'):
        uv, (x0, y0, x1, y1) = atlas.uv(name)
        # Pixel rect left at zero, as in every part of the game's own atlas: the
        # game reads the UV rect.
        parts.append({
            '$type': 'inkTextureAtlasMapper',
            'clippingRectInPixels': {'$type': 'Rect', 'bottom': 0, 'left': 0, 'right': 0, 'top': 0},
            'clippingRectInUVCoords': dict({'$type': 'RectF'}, **uv),
            'partName': cname(name),
        })
    # One texture for every resolution slot: the parts are resolution-free and
    # the texture is drawn at most at 1:1 on a 4K screen.
    for slot in slots:
        slot['texture'] = depot(XBM_PATH, 'Soft')
        slot['parts'] = copy.deepcopy(parts)
        slot['slices'] = []
    return j


def main(src, out):
    def load(rel):
        return json.load(open(os.path.join(src, rel)))

    def save(rel, obj):
        path = os.path.join(out, rel.replace('\\', '/') + '.json')
        os.makedirs(os.path.dirname(path), exist_ok=True)
        json.dump(obj, open(path, 'w'), indent=1)
        return path

    xbm, rgba, data = make_xbm(load('atlas_minimap_1080p.xbm.json'))
    save(XBM_PATH, xbm)
    save(ATLAS_PATH, make_inkatlas(load('atlas_minimap.inkatlas.json')))

    mm = load('minimap.inkwidget.json')
    library = mm['Data']['RootChunk']
    # THE ATLAS IS DECLARED, OR IT IS NEVER THERE. A widget library lists every
    # resource its items draw from in `externalDependenciesForInternalItems`, and
    # the game loads that list before it spawns an item; a reference inside an
    # item to anything not on it resolves to nothing. 1.4.18's first build left
    # ours off: in game the mask clipped nothing (a square map), the backing and
    # the bezel drew as flat tinted squares, and only the N -- loaded by path from
    # REDscript -- had its texture. Same flag as the game's own atlas entry.
    deps = library['externalDependenciesForInternalItems']
    assert not any(d['DepotPath']['$value'] == ATLAS_PATH for d in deps)
    assert any(d['DepotPath']['$value'].endswith('atlas_minimap.inkatlas') and d['Flags'] == 'Soft' for d in deps)
    deps.append(depot(ATLAS_PATH, 'Soft'))
    item = library['libraryItems'][0]
    assert item['name']['$value'] == 'Root'
    for label, root in (('packageData', item['packageData']['Data']), ('package', item['package']['Data'])):
        edit_minimap(Tree(root, label))
    save('base\\gameplay\\gui\\widgets\\minimap\\minimap.inkwidget', mm)

    hud = load('prototype_hud.inkhud.json')
    edit_hud(hud['Data']['RootChunk'])
    save('base\\gameplay\\gui\\prototype_hud.inkhud', hud)
    print('json written to', out, '| texture', atlas.W, 'x', atlas.H, 'bc3', len(data), 'bytes')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
