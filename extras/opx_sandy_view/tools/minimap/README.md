# tools/minimap -- the round minimap (opx_sandy_view 1.4.18; drawn right from 1.4.19; N badge in the data from 1.4.20; texture premultiplied from 1.4.21)

`archive/pc/mod/opx_minimap.archive` in the preload is built here from the base
game's own files. Nothing in it draws a map: the map inside the circle is the
game's own minimap (streets, pins, GPS line, the player's arrow), moving and
turning with the player exactly as before. What changes is its frame and where
it sits.

## What the archive carries

| depot path | what it is |
|---|---|
| `base\gameplay\gui\widgets\minimap\minimap.inkwidget` | the game's minimap, edited (below) |
| `base\gameplay\gui\prototype_hud.inkhud` | the game's HUD layout, the `minimap` entry moved |
| `opx\ui\minimap\opx_minimap.inkatlas` | four parts: `disc`, `ring`, `glow`, `north` |
| `opx\ui\minimap\opx_minimap.xbm` | their texture, 1024x768 BC3 (`atlas.py` draws it, `bc3enc.py` encodes it) |

The edits (`build.py`, `edit_minimap` / `edit_hud`; each one asserts it found
exactly the widget it meant, in BOTH copies of the tree the inkwidget carries):

* **the shape** -- the map's mask and its dark backing are the atlas's `disc`,
  so streets, the GPS line and in-view pins are clipped to a circle;
* **the bezel** -- the game's unused `bar` image is the `ring`, in the opx HUD
  red, the size of the minimap and centred on it;
* **combat / autodrive** -- the two border highlights are the `glow` inside the
  rim, pulsed by the game's own animations as before;
* **zone notice** (SAFE / HOSTILE / ...) -- its frame is the ring in the zone's
  colour, its label inside the circle near the bottom;
* **edge pins** -- the clamp square is 360 across, so a clamped pin sits on the
  bezel, not outside the circle;
* **the district name** -- shown, centred above the circle (the game writes it
  on every change of location and kept it hidden);
* the square's holder glyphs and header line are switched off (its corner
  fluff is the N badge, below);
* every image drawn from the atlas has nine-slice scaling off: the parts carry
  no slices (from 1.4.21; the backing, the highlights and the zone frame had
  kept the game's nine-slice flag);
* **the HUD entry** -- out of the top-right slot it shared with the wanted bar
  and the quest list, anchored to the screen's bottom-right corner, 64 x 72 HUD
  units (3840x2160 grid) from the edge.

No widget is added, removed or reordered: the minimap's animations address
widgets by their index path, so the tree's shape must stay the game's.

Four things the game needs that 1.4.18 did not do (it drew a square, pink map
with the parts of the atlas upside down in it; 1.4.19 and 1.4.20 a white square
over the map):

* **the texture is premultiplied** (from 1.4.21): every pixel stores colour x
  alpha, black where it is transparent, as the game's own UI textures do
  (`atlas_minimap_1080p.xbm`: black in every transparent pixel, colour/alpha
  1.007 at the edges). The game blends a UI image as
  `tex.rgb * tint * opacity + dst * (1 - tex.a * opacity)`; 1.4.18-1.4.20
  stored white where alpha was 0, so each 450-unit frame image ADDED its tint
  over its whole square -- the red bezel (0.92) and the cyan zone ring (0.9)
  together made the opaque white square seen in game, and 1.4.18's pink map
  with darker domes was the same sum. `atlas.compose` premultiplies;
  `verify.py` checks the decoded texture is premultiplied and composites the
  frame as the game blends it (`composite.py`): nothing in the square's
  corners, a dark map inside the circle;
* **the texture is stored bottom-up.** The game samples an atlas with v = 0 at
  the LAST row of the texture data -- its own `atlas_minimap_1080p.xbm` is stored
  so (its `minimap_mask` part, UV v 0.004-0.883, is data rows 30-255 of 256). The
  part UVs stay in top-down image terms (`atlas.uv`); `build.make_xbm` reverses
  the rows before encoding, and `verify.py` checks the decoded data flipped back
  is the atlas and, as stored, is not;
* **the library declares the atlas** in `externalDependenciesForInternalItems`
  (Soft, like the game's own atlas entry), so it is loaded before the items --
  the mask among them -- are built;
* **the archive lists each file's dependencies**: its CR2W hard imports (flags
  0), hashed and sorted, as the game's archives do (the minimap's 15, the HUD
  layout's 71; `pack.hard_imports`).

The north badge is an image of the library too, from 1.4.20: the square's old
corner `fluff` -- MiniMapContainer's first child, so drawn on top (in this
library the first child draws on top), and targeted by no animation in
minimap_animations.inkanim -- retextured to the atlas's `north` part, 46 units,
centred, hidden. `src/r6/scripts/opx_infinity/OpxMinimap.reds` only MOVES it
onto the bezel where north is (the map's rotation + 90 degrees) 30 times a
second and shows it, and touches no texture. (1.4.20 blamed the white square on
1.4.19's script re-setting the frame's atlas; it was the texture, above.)

## Rebuilding

Needs WolvenKit.CLI 9.0.1 (`wk`), Python 3 with numpy, Pillow and
texture2ddecoder, and WolvenKit's `libkraken.so` for `kark.py` (path in
`OPX_KRAKEN`, default `/opt/wk/pkg/tools/net10.0/any/libkraken.so`).

1. Extract the four base-game files from the game's `archive/pc/content` and
   serialize each to JSON (`wk convert serialize`), named
   `minimap.inkwidget.json`, `prototype_hud.inkhud.json`,
   `atlas_minimap.inkatlas.json` and `atlas_minimap_1080p.xbm.json`, in one
   folder (`json/`). The last two are only templates for the new atlas.
2. `python3 build.py json/ out_json/` -- writes the four edited JSON files under
   their depot paths.
3. `wk convert deserialize out_json/<path>.json -o out/<folder>` for each (make
   the output folder first).
4. `python3 pack.py out/ opx_minimap.archive` -- RDAR v12, every segment
   stored, buffers inline as the game's own entries are.
5. `python3 verify.py opx_minimap.archive /tmp/check` -- reads it back with an
   independent reader: exactly the four paths, the texture decoding to the
   atlas pixel for pixel and premultiplied, the frame composited as the game
   blends it, the widget tree saying what `build.py` meant.
6. `python3 composite.py preview.png "1.4.21=opx_minimap.archive"` -- the
   minimap as the game blends it (a stand-in street grid for the map);
   `sample.py` draws the four parts the same way.

From the 2.31 game files, with WolvenKit.CLI 9.0.1, the archive is
933,888 bytes, md5 `b296e829d237eb07427c729f5cdea11a` (1.4.21, built twice,
byte for byte the same; 1.4.20's was `90856f15f79e163e7057cafc2a304b3c`).

Then copy it to `src/archive/pc/mod/` and into `dist/opx_sandy_view.zip` at
`archive/pc/mod/opx_minimap.archive`, bump the resource's version, restart the
server; every player boots the game again through the launcher once.

## Turning it off

* the N badge only: quest fact `opx_minimap_off` = 1;
* the whole round minimap: remove `archive/pc/mod/opx_minimap.archive` and
  `r6/scripts/opx_infinity/OpxMinimap.reds` from the zip (the game's square
  minimap comes back at the top right), restart, players rejoin;
* the minimap at all: opx_infinity's `config/hud.lua` `VANILLA.minimap = false`.
