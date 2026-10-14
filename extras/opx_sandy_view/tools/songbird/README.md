# tools/songbird -- Phantom Liberty's story, kept shut (opx_sandy_view 1.4.17)

`opx_songbird.archive` is the game's own `ep1\quest\ep1.questphase` with one
string changed: top-level node [14], which the expansion's main story waits on
(`[14] -> [16] -> [22] -> [9] ep1_main_quests`, whose q301 rings Songbird and
plays her holocall), reads `opx_songbird_on >= 1` instead of `ep1_active >= 1`.
Nothing sets `opx_songbird_on`, so in a session the story never starts and no
scene of hers plays. Every other reader of `ep1_active` -- the open world, the
minor quests, the additional game elements, the bug fixing phase -- is another
node, so Dogtown's people, its gate, its gigs and street stories stay open
(1.4.13). Set the quest fact `opx_songbird_on` to 1 to let the story start as
the base game has it.

## Rebuild

On the machine with the game's ep1 archives (the archive reader and the Kraken
compressor are the ones `cyn_q305` uses: `~/rdar.py`, `~/kark.py`,
`~/ooz/libooz.so`):

```
python3 patch.py "<game>/archive/pc/ep1/ep1_2_gamedata.archive" out/
```

It reads the game's file, checks that node [9] loads `ep1_main_quests` and that
node [14] waits on `ep1_active >= 1` in a chunk nothing else shares, changes the
one string, writes the file back and re-reads it: every other chunk must be
byte-for-byte what it was. Then it packs `out/opx_songbird.archive` (one file,
under the depot path's own hash, so it replaces the game's) and reads it back.

Built 2026-10-01 from the game's 2.31 files:

| | bytes | sha256 |
|---|---|---|
| game's `ep1.questphase` | 302867 | `f8049a61235f36685b50d60da0e78b3de7640bc6f324e14b77d7601fdf0e9c57` |
| patched | 302872 | `326f78480d2e5278945efaaa42b2c61b5329b6494905c667847a6271c4d52924` |
| `opx_songbird.archive` | 40960 | `b450edc437ac14d611fdee4f439b33304a86f8d4bacaa71c534841ecb397b657` |

A second, independent reader (the quest-graph dumper used for q305) agrees: of
the 1391 lines of the graph, exactly one differs -- node [14]'s fact.

## Where it goes

Until committed, this folder and `src/archive/pc/mod/opx_songbird.archive` live
in `Claude outputs/opx_sandy_view-1.4.17/`. Move them to
`extras/opx_sandy_view/tools/songbird/` and
`extras/opx_sandy_view/src/archive/pc/mod/` when committing; `tests/run.lua`
looks in both places.
