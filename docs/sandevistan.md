# The Sandevistan: the Militech Apogee, Adam Smasher's look and his ghost trail

This is the full record of the Sandevistan work on `feature/rp-framework`. It covers what a
player gets, how it is built, how the ghost trail finally came to work, every build on the way
and what each one taught, how to deploy and test it, and what is still open.

**Status (28 September 2026, on a staging server, opx_sandy_view 1.4.8):**

| Part | State |
|---|---|
| Apogee on the ripperdoc tray, bought in the chair, engaged on a key | working |
| 20 s cooldown after every boost | working |
| The owner's world slows to 0.15 while V does not (the base game's own asymmetry) | working |
| The base game's Sandevistan screen (camera curve `Sandevistan`, keyboard `SlowMotion`) | working |
| Adam Smasher's look on the body (blinks, trails, loops, gold eyes, red plate) | working |
| **Ghost trail: afterimages of the player's own model, owner's third-person view** | **working since 1.4.7, confirmed in game** |
| **Ghost trail as every other player sees a boosted player**, with or without ArchiveXL on their game | **working (1.4.8), confirmed in game by two players**: the parts ship in the archive's own copy of V's body files (the second player's game had no ArchiveXL, so 1.4.7 gave them no parts at all) |
| **Players within 30 m of a boost slow to 0.15**, the owner's body at full speed on their screen | **working (1.4.8), confirmed in game by two players**: each nearby client's own time-scale claim; every slow, release and each slowed client's engine clock is journalled on the server |
| The real `Items.AdvancedSandevistanApogee` in the Operating System slot | works on a character the base game allows it on (the second player's: "fitted in the Operating System slot"); refused on a level-1 character (see Known issues) |
| **opx_sandy_view 1.4.9**: twelve-layer ghost trail (48 parts, 0.045 s apart, shown from 0.2 m), boosts of up to 40 s, `develop(10)` maxing the base game's development on the admin's machine | **in game 2026-09-28: the twelve afterimages show -- with no arms or hands** (fixed in 1.4.10) |
| **opx_sandy_view 1.4.10**: the afterimages' arms and hands (the arm meshes' material listed where they read it); the MaxTac AV drawn in its visible livery (`OpxMaxTacAv.reds`) | built and checked off-line (archive read back, REDscript compiled, suite green); **not yet tested in game** |
| **opx_sandy_view 1.4.11**: the Sandevistan user really faster (one more `MaxSpeed` multiplier, x1.5, while the boost holds); the base game's missions playable (`OpxQuests.reds`, see [`missions.md`](missions.md)) | deployed to staging 2026-09-28; the client log says `missions restored in this session (outermost wrapper: ...)`; **in game on a female V: the afterimages have no legs** (fixed in 1.4.12) |
| **opx_sandy_view 1.4.12**: the legs of a female V's afterimages (every body part shows every chunk; section 5, 1.4.12) | deployed to staging 2026-09-28 |
| **opx_sandy_view 1.4.13**: Phantom Liberty opened on a world that never started it -- a female V's (`OpxQuests.reds`, see [`missions.md`](missions.md)); the archive is 1.4.12's, byte for byte | built and checked off-line (REDscript compiled, 38 of 38 wrappers still outermost, suite green); **not yet tested in game** |
| **opx_sandy_view 1.4.14** (this tree): the fullscreen map's steps in the client log (`OpxQuests.reds`, see [`missions.md`](missions.md)) -- opening the map hard-crashed the game (2026-09-29) and the log did not say which step it died in; nothing on the map changes; the archive is 1.4.12's, byte for byte | built and checked off-line (REDscript compiled, 43 of 43 wrappers still outermost, suite green); **not yet tested in game** |
| **Boosts that grow with the owner's level** (this tree): the Apogee's 9 s at level 1 up to 40 s at the skill tree's level cap, the 20 s cooldown from the end of THAT boost, the reflex grant held back until then (section 2.4) | built and checked off-line (suite green); **not yet tested in game** |

---

## 1. What a player gets

- **The piece.** The ripperdoc sells the Militech Apogee (`apogee_sandevistan`) like any other
  chrome. Fitted in the chair, it is the platform's reflex overdrive (`open77_reflex`): the
  owner's body moves, swings and reloads faster.
- **The key.** One action engages every Sandevistan: "Overdrive: engage the reflex boost",
  default `POWER_KEYS.reflex` (`x`). A player rebinds it in **Pause › Settings › Key bindings** or
  with **`/opx.sandy.key <key>`** (`/opx.sandy.key` says the current key, `reset` restores the
  default). The "is live" message always names the key the player really has bound.
- **The time.** For the boost the owner's world runs at 0.15 while their own body does not slow.
  NPCs, traffic, physics, particles and sound slow; V does not. Everybody within 30 m of the owner
  (including anyone who walks in mid-boost) runs at 0.15 too, so they move in slow motion on the
  owner's screen. Everybody gets real time back when the boost ends or when they leave the radius.
- **The screen.** The base game's own: the camera's time-dilation curve `Sandevistan`, the
  muffled sound the engine makes in a slowed world, the keyboard's `SlowMotion` lighting, and the
  base game's `time_dilation_sandevistan_enter/exit` sounds.
- **The look (Adam Smasher's own Sandevistan).** As it engages, his teleport blink goes off at the
  body's feet and his dash sound plays on the body. For the whole boost his afterimage trails run
  from the hands, feet, chest and head, his aberration trails sit on the hips and chest, his loops
  on the hips, the eyes glow gold on everybody else's view, and the nameplate reads
  `Name // SANDEVISTAN` in red. His end blink goes off where the body stands when it ends.
- **The ghost trail.** While the owner runs, twelve afterimages of **their own model** (their own
  body, arms and head in Smasher's dark armour look; four up to 1.4.8) trail behind them along the
  path they really ran over the last half second. The owner sees them on their own third-person
  model; every player near enough to have the owner streamed sees them on the owner. On a machine
  the boost slows, the owner's body keeps full speed, so everybody near a Sandevistan sees its
  owner fast in a slowed world, as the owner sees themselves.
- **How long.** The boost grows with its owner: the grade's own at level 1 (the Apogee's 9 s),
  up to 40 s for a tier-5 grade at the skill tree's level cap (30 s for tier 1), linear between
  (section 2.4).
- **The cooldown.** Every Sandevistan the ripperdoc sells comes back 20 s after its boost ends --
  the whole boost, however long the owner's level made it.
- **The chair.** A power bought in the chair works as soon as the patient stands up: no relog.

---

## 2. How it is built

Three layers, each doing only what it has to.

### 2.1 The platform (Open77)

- `open77_reflex` owns the overdrive itself: the speed buff, the key action `reflex_overdrive`,
  the charge and the cooldown. It changes no clock.
- The ghost trail needs **no loader** from 1.4.8: its parts ride in the archive's own copy of V's
  body files (section 3.1). Up to 1.4.7 it was an ArchiveXL patch, which needed the platform's
  `archivexl` loader resource in `resources.load` **and** ArchiveXL on every player's game; the
  second player of the first two-player test had none (RED4ext loaded one plugin, Open77) and got
  no trail at all. The `archivexl` resource may stay in the load list for anything else.

### 2.2 opx_infinity: the ripperdoc module (Lua)

| File | What it does |
|---|---|
| `config/ripperdoc.lua` | `POWER_KEYS`, the `SANDEVISTAN` block (look, time, screen, cooldown, real item, view resource, recovery), the `/opx.sandy.key` and `/opx.sandy.test` command names |
| `modules/ripperdoc/module.lua` | the events `KIT`, `REPROJECT`, `SANDY`, `KEYBIND`, `SANDYREPORT`; the Sandevistan cooldown applied to every reflex grade when the tray is built (`M.Ripper.SandyCooldown`) |
| `modules/ripperdoc/server/sandevistan.lua` (new) | the server half: on every `open77_reflex` phase for a player whose armed overdrive has a look, one `SANDY` event to every client (whose body, which phase, which look, how long is left); the positioned dash sound; slowing the players around the owner; the level-scaled boost and the grant held through its cooldown (section 2.4); recovering a power a client lost; `/opx.sandy.test`; the journal of what each client reports back |
| `modules/ripperdoc/client/sandevistan.lua` (new) | the client half: draws the look on every boosted body (the owner's own included) with client-owned handles so a cut-short boost can always be stopped; the owner's clock and the players slowed around them; the screen stand-in when the view resource is absent; the key and `/opx.sandy.key`; the chair's reprojection token and the lost-power watch; the real-item request; one journal line per change |
| `modules/ripperdoc/server/chrome.lua`, `server/main.lua`, `client/main.lua` | the Apogee on its own power definition (heavy tier, reflex key, `presentation = 'none'` so the platform's blue glow is off), the kit sent to the patient's machine, the powers projected again after the chair, the two commands |
| `modules/ripperdoc/locales.lua` | the key and test strings (EN/FR) |
| `core/shared/main.lua` | `OPX.Now()` always returns whole milliseconds: the host's `GetGameTimer` returns a fraction, and a `%d` format of it killed the record reader and the stand-up reprojection token, which left a fitted Sandevistan dead until the next session |
| `open77.lua` | loads the two new scripts; client permissions `world.timescale`, `vfx.screen` (`world.dilation` is not declared: no published build has the `Open77.dilation` lease) |

### 2.3 opx_sandy_view: a resource of its own (`extras/opx_sandy_view`, version 1.4.14)

Everything the Lua layer cannot do lives here, and it ships to every player as a preload
(`dist/opx_sandy_view.zip`). Keeping it out of opx_infinity means a server that refuses it loses
this one layer, never the ripperdoc.

| File | What it does |
|---|---|
| `open77.lua` | the manifest, with the full build history in its header |
| `client/main.lua` | exports `engage(scale, ms, easeMs)`, `release(easeMs)`, `wear(code)`, `develop(code)`, `info()` that opx_infinity calls on the owner's machine; holds the owner's clock as a platform time-scale claim, reason `open77:opx_sandy_view`, for at most 45 s (a 40 s boost and its ease; 20 s up to 1.4.8) |
| `server/main.lua` | logs at start that the view and the ghost trail ship with this world (no loader needed) |
| `src/r6/scripts/opx_infinity/OpxSandevistanView.reds` | the REDscript (below) |
| `src/r6/scripts/opx_infinity/OpxMaxTacAv.reds` | the MaxTac AV's visible livery (1.4.10, below) |
| `src/r6/scripts/opx_infinity/OpxQuests.reds` | the base game's missions, playable in a session (1.4.11, [`missions.md`](missions.md)) |
| `src/archive/pc/mod/opx_sandy_ghost.archive` | V's two body files with the ghost trail's parts, and its meshes, material and effect, built from the base game's own files (1.4.0-1.4.7 also shipped an ArchiveXL `.xl`) |
| `tools/ghost/build.py`, `merge.py`, `pack.py`, `README.md` | how the archive is built and verified |

**What the REDscript does:**

1. **The screen and the exemption.** Seeing the view's clock claim, it sets the camera curve
   `Sandevistan` from the player state machine, exempts V from the world's dilation every frame
   (`SetIgnoreTimeDilationOnLocalPlayerZero(true)`, exactly what the base game's
   `SandevistanEvents.OnEnter` does), plays the keyboard's `SlowMotion`, and hands everything back
   when the boost ends. A real-time watch on the owner does the same, because the stamina state
   machine's update does not run every frame in a session.
2. **The third-person model.** In third person Open77 draws the owner as a separate NPC body (the
   "self view", `Character.Open77ProxyMale/FemaleMirror`). The world's dilation would slow it like
   any NPC, so for the boost the REDscript exempts it too, and lights Smasher's gold eyes on it
   while the camera is really behind it. Each mirror body gets its own watch; nothing is shared
   between NPC bodies (1.3.0 shared one list and crashed).
3. **The ghost trail** (section 3).
4. **The owner at full speed on every machine the boost slows**: every other player's copy of the
   boosted body gets the model's own exemption for the boost (section 3.3).
5. **The real item** (section 6).
6. **The base game's development, maxed** (1.4.9, section 6.1): for an admin's "max all levels".
7. **The user, really faster** (1.4.11). The world slowing and V exempt make V fast on the
   owner's own screen only; to everyone watching, a boosted player ran at the platform's
   overdrive speed (`MaxSpeed` x1.25 or x1.55), barely faster than anyone. While the boost holds,
   the owner's watch puts one more multiplier on V's own `MaxSpeed`
   (`OpxSandevistanSpeedBoost`, x1.5, through the base game's stats system), checked every step
   and taken off the moment the boost ends: `opx_sandy_view owner: speed x1.50 on -- MaxSpeed ...`
   / `... speed back to normal -- MaxSpeed ...`.
8. **The journal.** Every change is one line in the Open77 client log, prefixed
   `Open77 pristine player bootstrap trace: opx_sandy_view ...`, so a test is read back from the
   player's own log.

**The MaxTac AV's visible livery (1.4.10, `OpxMaxTacAv.reds`).** Every TweakDB record of the
MaxTac AV (`Vehicle.max_tac_av`, `max_tac_av1`-`3`, `max_tac_av_2nd_wave1`-`3`, read out of the
game's own `tweakdb_ep1.bin`) names the appearance `zetatech_surveyor__basic_maxtac_camo_01`, as
does the default of their template (`base\dependencies\vehicles\special\
av_zetatech_surveyor_basic_01_ep1.ent`). It draws the body, doors, engines, launchers and cabin
with the mesh appearance `maxtac_cloak` -- the optical camo the base game only lifts through its
prevention AI (`TurnOffPsychoSquadAvCammo` starts `cloak_off`). A vehicle created without an
appearance comes out in its record's, so the AV came out invisible for everyone but for its
stickers, one door and its thrusters. Since 1.4.11, opx_infinity creates the division's AV in
the visible livery itself (the job fleet row and `MAXTAC.AV.APPEARANCE`), which the platform
applies on every client since its 2026-09-14 build; the script stays as the second line, for a
MaxTac hull created without one. The script wraps `VehicleObject.OnGameAttached`: in a
multiplayer session, a vehicle whose record names the cloaked livery gets the same template's
visible MaxTac livery, `zetatech_surveyor__basic_ep1_maxtac_01`, scheduled on it, and a watch
reads it back every half second for ten seconds (scheduling it again, at most twice more, if the
cloak comes back) and writes `opx_sandy_view maxtac av: <entity> drawn in the visible livery ...`
once. The record stays `Vehicle.max_tac_av`, the one the platform flies as an AV.

A change to the REDscript or the archive changes the required-mod digest: the server restarts and
every player boots the game once more through the launcher. The preload is executable content, so
the server must run with `requiredMods.unsecured = true`.

### 2.4 How long a boost runs: the owner's level, and the cooldown that holds the grant

The owner asked for it: "longer usage time ... at max level 30-40 seconds".

- **The length.** `SANDEVISTAN.LEVEL_SECONDS = { 30, 40 }`. At level 1 a boost is its grade's own
  `durationMs` (6 to 9 s on this tray; the Apogee's 9 s). At the skill tree's level cap it is 30 s
  for a tier-1 grade up to 40 s for tier 5, `30 + 10 x (tier - 1) / 4` (the Apogee, tier 5: 40 s).
  Between, it is linear in `(level - 1) / (cap - 1)`: level 10 of 20 gives the Apogee
  `9 + 31 x 9/19` = 23.7 s. The level is the skill tree's (`OPX.Api.Get('skills').Level(citizenId)`
  -> `level, cap`); a tree that cannot say is level 1.
- **What runs that long, and what does not.** `open77_reflex` caps its overdrive -- the speed --
  at 15 s on its own client, and its definitions are shared by grade (8 per resource), so they
  never change with a level. What the ripperdoc draws is its own: at the `active` phase
  (`server/sandevistan.lua`, `run`) the look, the owner's slowed world (the view's claim, up to
  45 s since 1.4.9), the players slowed around them, the ghost trail and the screen run for the
  platform's remaining time plus what the level adds. When the platform's `completed` arrives
  first, the boost goes on to its own deadline; a platform `cancelled` (a vehicle, a staff
  cancel) still ends it, and so does the owner's death. A Sandevistan with no `LOOK` is the
  platform's to draw and keeps the platform's boost -- only the Apogee has a look out of the box;
  map another piece to one in `SANDEVISTAN.LOOK` to lengthen it too.
- **The cooldown holds the grant.** `COOLDOWN_MS` (20 s) must run from the end of the ripperdoc's
  boost, but the platform starts its own when ITS overdrive ends. So from the platform's
  `completed` the player's reflex grant is HELD BACK (`M.Chrome.HoldBack`: revoked on the
  platform, and re-armed by nothing -- not `M.Chrome.Ensure`, not a re-projection, not
  `M.Sandy.Recover`, not an arrival, not the tick) until the boost is over and 20 s have passed;
  then it is armed again the ordinary way. The player's machine is told the power is held, not
  gone (`held` in the kit): its real item stays in the Operating System slot and its lost-power
  watch asks for nothing. A disconnect clears the hold with the session. An activation that
  still lands inside the boost or the cooldown (a press on its way as the grant was revoked, a
  second charge) is journalled and never drawn. At level 1 nothing is held: the boost is the
  platform's, and so is its cooldown.
- **The journal.** `player N: Sandevistan (smasher, reflex_heavy) for 40250 ms ...; level 20 of
  20 adds 31000 ms to the platform's own`, `player N: the platform's overdrive completed and the
  Sandevistan runs on for 31000 ms more (level 20 of 20) -- the apogee_sandevistan grant is HELD
  until that ends and its 20000 ms cooldown has passed`, `player N: the Sandevistan is over
  (completed); its apogee_sandevistan grant comes back after the 20000 ms cooldown`, `player N: the
  Sandevistan's cooldown is over -- its apogee_sandevistan grant is back`; on the owner's machine
  `the overdrive on this body ended; the Sandevistan runs on for ... ms (the character's level)`
  and `Sandevistan: apogee_sandevistan is held back until the boost is over and its cooldown has
  passed`.
- **What the skill tree shows.** `OPX.Api.Get('ripperdoc').ChromeLevel(level, cap)` answers the
  shortest and longest Sandevistan boost the ripperdoc runs at that level, at level 1 and at the
  cap (`activeSeconds`, `activeBaseSeconds`, `activeMaxSeconds`, `{lo, hi}` in seconds), beside
  how long chrome lasts (`docs/commands.md`, "Durability").
- **Every client cap follows.** `CAP_MS` is 45000 on both halves (a 44 s boost at most,
  `M.Ripper.SANDY_MAX_SECONDS`, and its 250 ms margin); the owner's dilation lease, where a build
  has one, is authorised for the whole boost (it was capped at 30 s); the owner's clock
  (opx_sandy_view `engage`, 45 s), the slowed players' time-scale claims, the layers (restarted
  trails, loops of up to 600 s), the plate, the stand-in screen (up to 600 s) and the owner's end
  all follow the boost's own `remainingMs`. `/opx.sandy.test` runs up to 44 s.

---

## 3. The ghost trail (1.4.9): how it works

Adam Smasher's trail, more aggressive with way more clones: 1.4.9 draws **twelve** afterimages,
0.045 s apart (the farthest where the body was 0.54 s before), each shown from 0.2 m behind the
body. 1.4.6-1.4.8 drew four, 0.08 s apart (the farthest at 0.32 s), shown from 0.35 m. Everything
else about how a layer is drawn is the same.

### 3.1 The parts

The archive carries the player body file itself,
`base\characters\common\player_base_bodies\appearances\t0_000_base__full.app`, and its censored
cut: the base game's own (2.31), every field kept, with **twelve layers** of four parts each (48
parts; four layers up to 1.4.8) added to every one of its 36 appearances, all switched off:

- `opx_sandy_ghost1_body`, `opx_sandy_ghost1_arm_l`, `opx_sandy_ghost1_arm_r`, `opx_sandy_ghost1_head`
- ... up to `opx_sandy_ghost12_*`

Layers 5 to 12 are exact copies of the first four's components (the same meshes, material, flags,
bindings, chunk masks and appearance) with their own names and ids; the layer count is one number,
`LAYERS = 12`, in `tools/ghost/build.py` and `merge.py`, and `OpxSandyTrailLayers()` in the
REDscript. Each appearance also gets the effect spawner `opx_sandy_ghost_fx` (the trigger
`opx_sandy_ghost_on`). The game loads a file of `archive/pc/mod` in place of the base game's by
its depot path, with no plugin at all, so every player whose launcher laid the package has the
parts. Up to 1.4.7 the same parts (sixteen then) were an
ArchiveXL patch of these two files, and a game without ArchiveXL never got them (the second
player's log: "0 of 16 parts (none), its effect spawner MISSING"). The `.xl` is gone, so a game that
does run ArchiveXL does not add them twice.

Each part is an `entGarmentSkinnedMeshComponent` (V's own body component class) on V's own
meshes, copied from the base game with one appearance added (`opx_sandy_ghost`, using
`opx_sandy_ghost.mi`: the base game's `sandevistan_multilayer.mt` with Smasher's armour layer
set). The body mesh is V's third-person body (torso, legs, feet), the arms are V's arms and
hands, and the head is V's base head with its 244 face-rig bones re-rigged onto `Head`. The
meshes' render buffers are the base game's own, byte for byte. So every afterimage is the
player's own silhouette in Smasher's look.

### 3.2 Placing them, every frame

For each lit body the REDscript keeps a short history of where the body stood (world position and
turn, frame by frame: as far back as the farthest afterimage and a quarter second more, about
0.8 s). Every frame:

- layer *k* (1 to 12) is placed where the body was *k* × 0.045 s ago (the farthest 0.54 s),
  interpolated between the two frames around that moment, **relative to where the body is now**,
  with the parts' own placement (`SetLocalPosition` / `SetLocalOrientation`), in this frame's
  pose. At a sprint that is about 0.4 m between afterimages, over about 5 m;
- a layer shows once it is more than 0.2 m from the body and hides again under 0.1 m (1.4.6-1.4.8:
  0.35 / 0.25 m), so a body standing still has none;
- a layer never stands within 0.9 m of the camera (the third-person camera trails the body within
  the reach of the farther afterimages, and a body inside the lens would fill the screen);
- a shown layer is **un-hidden every frame** (`TemporaryHide(false)`): Open77 hides every skinned
  mesh of a body while it dresses it or parks it and only lifts what it hid itself, so parts
  switched on later can still carry that hide. A hidden layer is moved back onto the body and
  hidden.

The per-frame driver is a 5 ms real-time timer of the delay system (`OpxSandyTrailTicker`, not
slowed by the world's dilation) that reschedules itself while any body is lit. The watch that lit
the body also places the afterimages every tenth of a second, in case the ticker stops. A jump of
more than 4 m in one frame (a teleport) starts the history again.

### 3.3 Who lights it

- **The owner's third-person model**: the model's own watch lights it while the boost runs, the
  model stands on V and the camera is behind it. Never in first person.
- **Other players' copy of a boosted player**: opx_infinity's look holds the trigger
  `opx_sandy_ghost_on` (in `LOOKS.smasher.LOOP`) on that body for the whole boost, on every
  machine the owner is streamed to. The body's own callback answers it with a watch that lights
  the afterimages as soon as the body has its parts, keeps them placed, and ends with the trigger.
  A body seated in a vehicle carries no ghost (Open77 hides remote AV occupants).
- **The owner at full speed there.** A machine within the boost's radius runs slowed (section 4),
  and on it the boosted body is just another body of the world. So the same watch gives it the
  exemption the owner's own model gets (an individual dilation of 1.0 that ignores the global one)
  for the boost, and takes it off when the trigger stops or the body leaves.

### 3.4 What the log says

1.4.9's lines (N, S and the distances are what the game measures; 1.4.8's confirmed test read
`16 of 16`, `4 afterimages, 0.08 s apart`, `placed 70 times in 3.02 s, 4 of 4 showing` and
`the farthest 1.71 m behind; the engine has the farthest shown 1.70 m from the body`):

```
opx_sandy_view ghost: this game gives player bodies the ghost trail's parts -- the third-person model has 48 of 48 (opx_sandy_ghost.archive's copy of V's body)
opx_sandy_view ghost: the owner's third-person model lit -- 48 of 48 parts (entGarmentSkinnedMeshComponent), 48 switched on, its effect spawner there; 12 afterimages, 0.045 s apart, shown from 0.20 m, placed every frame
opx_sandy_view afterimages: the owner's third-person model -- placed N times in 3.0 s, S of 12 showing
opx_sandy_view afterimages: the owner's third-person model -- S of 12 shown, the farthest X m behind; the engine has the farthest shown Y m from the body (asked X m)
```

and on another player's machine:

```
opx_sandy_view ghost: a boosted player's body lit -- 48 of 48 parts (entGarmentSkinnedMeshComponent), 48 switched on, its effect spawner there; ...
opx_sandy_view ghost: the boosted player's body keeps full speed on this machine (exempt from its dilation: true); this machine is slowed by it, world 0.15
```

The first line is said once, as the third-person model attaches. `0 of 48` there says this game
does not load the archive's copy of V's body (not installed, or another archive's copy of
`t0_000_base__full.app` comes first) and gives no trail on that machine; `only 16 of 48` says it
loads an older archive (1.4.6-1.4.8's), whose four layers are the only ones that can show. The
"placed N times" line says how often the afterimages are really moved (about 16 to 23 times a
second in 1.4.7's and 1.4.8's confirmed tests); "the engine has the farthest shown" is that part
read back from the engine (`GetLocalToWorld`).

### 3.5 Boosts of up to 40 s (1.4.9)

The ripperdoc runs a Sandevistan for up to 40 s (level-scaled, section 2.4), 45 s with its ease. The view
covers it end to end: the owner's clock claim is capped at 45 s (`MAX_MS` in
`client/main.lua`; 20 s up to 1.4.8, which would have handed the owner's world back halfway
through a 40 s boost), and the REDscript's own 30 s windows now last 60 s
(`OpxSandevistanBoostCeiling`): the watch that draws a boosted player's ghost on every other
machine gave up after 30 s ("the boost outlived its ceiling": trail off, full speed off), and the
individual dilation that keeps the owner's third-person model and every other player's copy of
the owner at full speed lapsed after 30 s (set again within a tenth of a second). Nothing else in
the REDscript is timed: the owner's watch, the camera curve (asked once per boost) and the owner's
trail hold for as long as the claim does, and the gold eyes are started once per lighting and
stopped only when the boost ends or the camera goes to first person -- how long the eyes' effect
itself runs is its template's, which only a 40 s boost in game can show.

---

## 4. The world around a boost: the players nearby slow

A slowdown is a per-client simulation rate: no machine can slow another. So "the world around a
Sandevistan slows" is every player close enough running their own clock at the look's rate:

- **Who.** On the boost's `active` phase, and again every half second, the server
  (`server/sandevistan.lua`, `slowAround`) finds every player in the owner's bucket, alive, within
  `TIME.RADIUS` (30 m), and tells each of them (`SANDY`, phase `slow`) to run at
  `TIME.NEARBY_SCALE` (0.15, the same rate as the owner's world) for what is left of the boost. A
  player who walks in mid-boost is slowed for the rest of it; one who walks out past 1.25 x the
  radius, dies or leaves is handed real time back (`release`), and everybody still slowed is
  released when the boost ends.
- **How.** Each slowed client (`client/sandevistan.lua`, `reslow`) holds its own time-scale claim,
  `Open77.world.setTimeScale` (reason `open77:opx_infinity`, permission `world.timescale`): the
  world AND that player's own body slow, with the look's 250 ms ease. The owner's own claim is the
  view's (`open77:opx_sandy_view`), the one reason the REDscript exempts V from, so the base game's
  asymmetry stays the owner's alone. Two overlapping boosts: the slowest wins, for as long as the
  longest lasts. A player in their own boost is not slowed by somebody else's until it ends.
- **The owner at full speed.** On each slowed machine the boosted body gets the owner's model's
  exemption (section 3.3), so the owner is seen fast in a slowed world.
- **The journal.** The server writes every slow and every release with the distance
  (`player 3: Sandevistan slows player 2 (12.4 m away) to 0.15 for 9250 ms`,
  `... no longer slows player 2 (41.0 m away, past 37.5 m)`, `... (the boost completed)`); a boost
  that slows nobody names the nearest player (`0 player(s) slowed nearby (within 30 m; nearest:
  player 2 at 41.3 m)`). Each slowed client writes `Sandevistan: player 3's boost slows this
  machine -- world 0.15 for 9250 ms, this client's time scale (the world and this body)`, reads the
  engine's clock back once the ease has landed (`Sandevistan clock on this machine, slowed by
  player 3: world at 0.15, engine dilation active; claims: opx_infinity 0.15 (holding)`) and tells
  the server, which journals it (`player 2's client: slowed by player 3's Sandevistan -- held by
  timescale; clock world at 0.15 ...`, or `REFUSED: <why>` when every door refused). So a test is
  read back from the server's journal alone (`logs.cmd`).

---

## 5. How we got here: every build and what it taught

The ghost trail took nine builds. Each one was deployed to staging and tested in game, and the
next one was decided from the players' own client logs and screenshots.

| Build | What it tried | What happened / what it taught |
|---|---|---|
| 1.2.x | The base game's screen and clock: the owner's clock claimed by the view, V exempt, camera curve `Sandevistan` | Working. |
| 1.3.0 / 1.3.1 | The third-person model exempt from the world's dilation, with Smasher's effects on it | 1.3.0 kept one shared list written from the engine's parallel attach callbacks and crashed a few seconds in; 1.3.1 gives every mirror body its own watch. |
| 1.4.0 | Ghost trail from twenty parts of **Smasher's own body** on the player; first attempt at the real item | Never shipped: the afterimages should be the player's own silhouette. |
| 1.4.1 | The player's **own** body, arms and head on Smasher's shader, as plain skinned components with Smasher's masked material; his looping effect started the same frame | Parts found and switched on; nothing drawn. The real item was asked for by an id made from the record, which the inventory never holds. |
| 1.4.2 | Parts as V's own **garment** components, unmasked material, the archive's own non-looping effects started after the parts; the real item looked up by record | Still nothing drawn. |
| 1.4.3 | Test build with probes and every part **un-hidden every step** | The parts drew. Open77's self view parks the model with `TemporaryHide(true)` and lifts only what it hid, so parts switched on later stayed hidden. |
| 1.4.4 | Calibration: five shader strengths, one per boost, smallest first; un-hide only for 0.6 s; probes and the NPC screen-space echoes removed from the owner's model | The player saw nothing on the one boost tested (the smallest strength). The theory behind calibrating (an exempt body reads too fast) was wrong: the base game exempts V the same way, and ESDE runs Smasher's full (1.5, 1) on V. |
| 1.4.5 | Smasher's full strength (1.5, 1), the effect held at its peak from first frame to last (the earlier curve fell to zero at its last point, which read as seconds ends the trail after one second), started three times, parts un-hidden every step for 2 s then every second, other players' copies un-hidden too | The log proves every step ran; still no trail. **The shader's own copies do not show on these bodies.** The shader approach was dropped. |
| 1.4.6 | **The script draws the afterimages itself**: four layers of the parts, placed every frame at the body's past positions | The per-frame driver (a next-frame callback) ran twice in half a second and stopped (`2 frames in 0.58 s`); no afterimage was ever placed. |
| 1.4.7 | The driver is a 5 ms real-time timer, and the lighting watch places them too every tenth of a second | **Working on the owner's view, confirmed in game.** Placed ~16 to 23 times a second, 4 of 4 showing while sprinting. The first two-player test then showed the second player got no trail at all, on anybody: their log said "0 of 16 parts (none), its effect spawner MISSING", and their RED4ext loaded one plugin (Open77): **no ArchiveXL on their game**, so the patch that gave player bodies the parts never ran there. |
| **1.4.8** | **No loader:** the archive carries V's two body files themselves, the base game's own with the parts appended to every appearance (`tools/ghost/merge.py`), and no `.xl`. Every other player's copy of a boosted body is exempt from that machine's slowdown for the boost; the model says once how many parts its game gives player bodies; the farthest afterimage is read back from the engine. On the ripperdoc side, every slow and release is journalled on the server with the distance, and each slowed client reports its engine clock | See the status table at the top. |
| **1.4.9** | **Adam Smasher's trail, more aggressive with way more clones:** twelve layers (48 parts, the new ones exact copies of the first four's), 0.045 s apart (the farthest 0.54 s), shown from 0.2 m (hidden under 0.1 m), the readiness line expecting all 48. **Boosts of up to 40 s:** the owner's claim capped at 45 s (was 20 s), the REDscript's 30 s windows (the other machines' ghost watch, the full-speed exemption) lifted to 60 s. **`develop(10)`:** the same clock message maxes the base game's own development on the admin's machine (section 6.1) | In game (2026-09-28): the twelve afterimages show, **with no arms or hands**. V's arm meshes keep their materials as `preloadLocalMaterialInstances` and read an external one from `preloadExternalMaterials`; the build had listed the ghost's in `externalMaterials`, which only the body and head read. |
| **1.4.10** | **The arms and hands:** the four arm meshes list the ghost's material in `preloadExternalMaterials` (nothing else in the archive changed, byte for byte). **The MaxTac AV visible:** `OpxMaxTacAv.reds` (section 2.3) | Not yet tested in game. |
| **1.4.11** | **The user really faster:** x1.5 on V's `MaxSpeed` for the boost (section 2.3). **The base game's missions:** `OpxQuests.reds` ([`missions.md`](missions.md)) | In game (2026-09-28, a female V): the arms show; **the afterimages have no legs**. Her body component in V's body files hides the body mesh's chunks 5-7 (knees, calves, feet), which the base game draws from a part of their own (`l0_000_pwa_base__cs_flat`, by footwear); every afterimage's body part copied that mask and had no such part. |
| **1.4.12** | **The legs:** every afterimage's body part shows every chunk, as a male V's always did; the body mesh's own chunks 5-7 are those same legs (only the two body files change, and in them only those masks) | Deployed to staging 2026-09-28. |
| **1.4.13** | **Phantom Liberty on a female V's world:** `OpxQuests.reds` sets `ep1_active` and `ep1_side_content` to 1 where they read 0 ([`missions.md`](missions.md)); the archive is unchanged | Not yet tested in game. |
| **1.4.14** | **The map, step by step in the client log:** `OpxQuests.reds` writes each step the fullscreen map takes (`opening`, `tooltips hidden 1`, `tooltips hidden 2`, `opened`, `reading the zoom levels`, `scene attaching`, `scene attached`, each quest marker, `closed`), because opening the map hard-crashed the game and the log stopped at `map:composition=ready`; nothing on the map changes ([`missions.md`](missions.md)); the archive is unchanged | Not yet tested in game. |
| **1.4.15** | **Opening the map no longer crashes the game:** the crash probe's access violation (a read at `0x38` in the game's native `IMappin.GetScriptData`) is the marker the fullscreen map makes for the player's own arrow, a runtime marker with no data behind it. `OpxQuests.reds`' marker gate now judges the init data first, the class next, the `opx_quests_off` switch after, and reads a marker's data last ([`missions.md`](missions.md)); the archive is unchanged | Built and checked off-line; **not yet tested in game.** |

Lessons worth keeping:

- Read the client log first: `opx_sandy_view ...` lines say exactly which link ran. Three "no
  trail" reports were settled by the logs alone (one test ran an old build because the server had
  not been redeployed; one showed the driver had stopped; one showed the second player's game had
  no parts, and their `red4ext-*.log` showed why: no ArchiveXL).
- Test with a second player early, and read BOTH players' logs: the owner's view working says
  nothing about another machine's game.
- Do not make a visual feature depend on a plugin the package does not ship itself. A loader
  declared by the server is still up to each player's launcher and game.
- On a body Open77 dresses or parks, anything switched on later must be un-hidden, and kept
  un-hidden.
- `DelayCallbackNextFrame` chains and the stamina state machine's update do not run every frame in
  a session. Timed delay callbacks (not slowed by dilation) do.
- The effect in the archive (`opx_sandy_ghost_x150`, Smasher's peak held) stays in the package and
  is played by nothing.

---

## 6. The real item: the Apogee in the Operating System slot

`SANDEVISTAN.WEAR = { apogee_sandevistan = 1 }` asks the view's REDscript to fit the base game's
`Items.AdvancedSandevistanApogee` in the Operating System slot, so the inventory, the paperdoll
and every stat read of the slot see it. The only door a Lua resource has to the REDscript is the
clock: the view's `wear(code)` export holds a half-second time-scale claim whose value the
REDscript decodes (`0.999 - code / 10000`). It is sent when the kit changes, again 4 s and 12 s
later, whenever the overdrive projection comes back, never over a boost.

The REDscript finds the item in the inventory by its record, gives it once if there is none, fits
that very item with the base game's own `EquipmentSystem`, reads the slot back, retries up to five
times per request, and takes off (and out of the inventory) only what it fitted. While it is
fitted, the base game's own Sandevistan activation is off (`SandevistanDecisions.EnterCondition`),
so the key and the slowdown stay the ripperdoc's.

**Current result:** the item is given, but the base game refuses to fit it:
`... is NOT fitted after 5 tries (the base game refused it: equippable false, item level 0, V's level 1)`.
See Known issues.

### 6.1 The base game's development, maxed (1.4.9)

An admin's "max all levels" on the server also has to max the BASE GAME's own development on the
admin's machine, and the clock is still the only door: the view's `develop(code)` export holds the
same half-second message claim with a code the real item never uses (0-9 are its; **10** = max
everything), refuses any other code (`invalid_code`) and never goes over a live boost
(`boosting`), answering `ok, why` like `wear`. On code 10 the owner's watch in the REDscript
(`OpxSandevistanDevelop`), with the base game's own `PlayerDevelopmentData` and the game's own
maxima:

1. sets the five attributes (Body, Reflexes, Technical Ability, Intelligence, Cool) to their
   record's cap (`BaseStats.<attribute>` `Max()`, 20) with `SetAttribute` -- first, since a skill
   tied to an attribute is capped by it and a perk's tier asks for attribute points;
2. sets Level, Street Cred and the five skills (Solo, Shinobi, Engineer, Netrunner, Headhunter) to
   their `GetProficiencyAbsoluteMaxLevel` (60, 50, 60) with `SetLevel(..., isDebug = true)`, so
   the level-ups hand out no points of their own;
3. sets the Espionage proficiency to its maximum with `SetLevel(..., isDebug = false)`, which is
   how the base game's own relic terminals give relic points (one per level);
4. adds perk points (`AddDevelopmentPoints(..., Primary)`) until the unspent ones pay for every
   level of every perk of the five attribute trees not bought yet (`NewPerks.<attribute>AttributeData`).

Nothing already at its maximum is touched. It runs once per request, is remembered for the session
(quest fact `opx_sandy_develop`) and runs again a second after a new body attaches (five tries while
the body has no development data yet). One line says what changed, before -> after:
`opx_sandy_view development: maxed on this machine (asked for) -- body 3 -> 20, ..., level 1 -> 60, ..., relic points ... , perk points ...`
(or `nothing changed, already at every maximum`).

---

## 7. Configuration reference (`config/ripperdoc.lua`)

| Key | Meaning |
|---|---|
| `COMMANDS.key` / `COMMANDS.test` | `opx.sandy.key` (every player), `opx.sandy.test [1-44 s]` (staff: it slows everybody near the caller) |
| `POWER_KEYS` | default key per power class: `reflex = 'x'` (every Sandevistan), `dash = 'z'`, `ability = 'l'`. A player's own rebind always wins |
| `SANDEVISTAN.enabled` | the whole feature |
| `SANDEVISTAN.LOOK` | which piece wears which look: `{ apogee_sandevistan = 'smasher' }`. A piece not named keeps the platform's own picture |
| `SANDEVISTAN.LOOKS.smasher.BLINK` | Smasher's teleport start/end effects at the feet, left in the world 15 s |
| `...LAYERS` | effects bound to body slots for the boost: `slots` (first one the body has), `every` (restart), `once`, `who` (`self`/`others`), `self` (`fpp`/`tps` on the owner's own body), `body` (left off the owner's own body where the view resource ships) |
| `...START` / `START_SECONDS` | effects the body authors, played by name as it engages (others' view) |
| `...LOOP` | effects held by name for the boost on others' view: `eye_glow_gold` and the ghost trigger `opx_sandy_ghost_on` |
| `...TIME` | `SELF_SCALE` 0.15 (owner's world), `SELF_FALLBACK_SCALE` 0.5 (whole view, when neither the lease nor the view can exempt the body; 1 turns it off), `NEARBY_SCALE` 0.15 within `RADIUS` 30 m, `EASE_MS` 250 |
| `...SCREEN` | stand-in screen when the view resource is not running: `drugged` alias at 0.5, `damage.emp` at start |
| `...SOUND` / `SELF_SOUND` | Smasher's dash sound on the body; the base game's enter/exit sounds for the owner |
| `...PLATE` | ` // SANDEVISTAN` in `#FF2D55` |
| `SANDEVISTAN.MAPPING` | the platform's action: `open77_reflex` / `reflex_overdrive` |
| `SANDEVISTAN.COOLDOWN_MS` | 20000: every reflex grade's `cooldownMs` and `chargeRegenMs`, clamped 1 to 120 s; `nil` keeps each grade's own. Runs from the end of the ripperdoc's boost, however long the level made it (section 2.4) |
| `SANDEVISTAN.LEVEL_SECONDS` | `{ 30, 40 }`: a tier-1 and a tier-5 grade's boost at the skill tree's level cap, in seconds (each at most 44); the grade's own `durationMs` at level 1, linear between; `nil` keeps the grade's own at every level (section 2.4) |
| `SANDEVISTAN.WEAR` | `{ apogee_sandevistan = 1 }`: the real item code the REDscript knows |
| `SANDEVISTAN.VIEW` | `{ RESOURCE = 'opx_sandy_view' }`; `false` turns the view off |
| `SANDEVISTAN.RECOVER.AFTER_MS` | 15000: a power the client lost is projected again at most this often, never inside its own cooldown |

---

## 8. Building the ghost archive

`extras/opx_sandy_view/tools/ghost/README.md` has the full procedure. In short: extract the listed
base-game files as raw CR2W, serialize them to JSON with WolvenKit, run `build.py` (writes the
patch, the eight meshes, the material and the effect as WolvenKit JSON, deterministically), run
`merge.py` (appends the patch's parts to every appearance of V's two body files, and checks that
each merged file minus the parts IS the base game's, handles resolved), deserialize with
WolvenKit, then `pack.py` packs the archive with every segment stored and every CRC recomputed
(each mesh's buffers checked against the base game's own). The 1.4.8 archive (twelve files: the
two body files, eight meshes, the material, the effect) was read back with WolvenKit and compared
file by file: all equal; the two body files' depot-path hashes are the ones the installed
`basegame_4_appearance.archive` holds. The 1.4.9 archive (`LAYERS = 12`: 48 parts and the spawner
in every appearance; 5,853,184 bytes, the same twelve files and path hashes) was checked the same
way, and more: each body file minus the parts is the base game's, layers 1-4 and the spawner are
1.4.8's (the spawner now naming all 48 parts), layers 5-12 are exact copies of layer 1's parts but
for their names and fresh ids, and the meshes, material and effect are 1.4.8's byte for byte
(`tools/ghost/README.md`, "Checked for 1.4.9"). The 1.4.10 archive (md5 `7ce92a40...`, the same
size, files and path hashes) differs from 1.4.9's in the four arm meshes only, and in them only in
where the ghost's material is listed: WolvenKit reads them back equal to 1.4.9's but for
`externalMaterials` (now empty) and `preloadExternalMaterials` (now the ghost's material), and
equal to what `build.py` wrote (`tools/ghost/README.md`, "Checked for 1.4.10"). The 1.4.12 archive
(md5 `a4a27a2f...`, 5,849,088 bytes, the same files and path hashes) differs from 1.4.10's in the
two body files only, and in them only in the female appearances' ghost body parts' `chunkMask`
(`0xFFFFFFFFFFFFFF1F` -> all chunks, 432 values per file); WolvenKit reads them back equal to what
`merge.py` wrote (`tools/ghost/README.md`, "Checked for 1.4.12"). The archive contains no other
mod's files.

---

## 9. Deploying to staging

- Build the view package from the repo (`extras/opx_sandy_view`: `open77.lua`, `client/`,
  `server/`, `src/r6/`, `tools/`, and `dist/opx_sandy_view.zip` holding the `.reds` and the
  `.archive`; from 1.4.8 no `.xl`).
- The staging deploy helper (kept outside the repo, under the gitignored `.open77-scratch/`)
  uploads opx_infinity and opx_sandy_view, keeps a backup of each, installs them, sets
  `requiredMods.unsecured = true`, restarts the server and rolls back if it does not come up. It
  still keeps `archivexl` in `resources.load`; the ghost trail no longer needs it.
- After a deploy every player relaunches through the launcher (the required-mod digest changed).
- A test only counts if the client log shows the new version's lines (for 1.4.8: `this game gives
  player bodies the ghost trail's parts`; for 1.4.9: `... the third-person model has 48 of 48` and
  `12 afterimages, 0.045 s apart`; for 1.4.10, once a MaxTac AV is out:
  `opx_sandy_view maxtac av: ... drawn in the visible livery zetatech_surveyor__basic_ep1_maxtac_01`).
  One round of testing was lost to a server still serving the previous build. The server's own
  log (`logs.cmd`, read-only) shows the `[ripperdoc]` slows,
  releases and each client's reports.

---

## 10. Testing

**Automated.** `tests/run.lua` (run with the `opx_lib` resource beside the repo:
`lua tests/run.lua`) carries the Sandevistan checks: the Apogee's own definition and key, the kit
and its announcement, the chair and the reprojection token, the look on every client and on the
owner by the right slot names, the time around the owner (walk in, walk out, nobody slowed by
their own boost), the server's journal of every slow and release and each slowed client's
report, the slowed machine's own journal and clock read-back, the lost-power recovery and its
cooldown guard, the commands, the cooldown on the tray, the journal lines, and the view
resource's REDscript and archive (read as source and as an RDAR archive: the 48 parts of the
twelve layers and their spacing and thresholds, the history reaching the farthest layer, the
ticker, the placement, the un-hide, the camera clearance, the booster's exemption on a slowed
machine and the 60 s windows past a 45 s boost, the parts line and the read-back, the twelve
shipped files including V's two body files with every part in every one of their 36 appearances,
no `.xl`, every segment stored), and the view's client (the 45 s claim cap, the real item's
codes, `develop(10)`: carried, every other code refused, never over a boost) and the REDscript's
development maximum; and the level-scaled boost (section 2.4): the length at levels 1, 10 and 20
and the tier mapping, a boost surviving the platform's `completed` and ending at its own deadline,
the grant held from that moment -- `Ensure`, a re-projection, `Recover`, an arrival and the tick
all refusing to re-arm it early -- and given back when the boost is over and the cooldown has
passed, a platform `cancelled` and the owner's death still ending it, a disconnect clearing the
hold, an activation inside the boost or the cooldown journalled and never drawn, level 1
unchanged, the 45 s ceiling on both halves (the owner's lease authorised for a 40 s boost), and a
held power not asked for again by the player's machine. The whole suite passes (the count moves with every change; `lua tests/run.lua` prints it).

**In game.**

1. `/opx.sandy.test [seconds]` (staff) runs the whole presentation on yourself without the
   overdrive: clock, screen, look.
2. With the Apogee fitted: third person, camera at V's side, press the key, sprint. Twelve dark
   afterimages of your model follow you along your path (four up to 1.4.8); none when you stand
   still. Hold a boost past 30 s: the trail and the full speed must hold on the other player's
   screen until the boost ends.
3. Read `red4ext/logs/open77-*.log`: the `[ripperdoc] Sandevistan ...` lines (server said, the
   overdrive engaged, the clock, the look's layers) and the `opx_sandy_view ...` lines (owner,
   model, ghost, afterimages).
4. **Two players**, within 10 m, both in third person: one boosts and runs. The other sees the
   afterimages behind them and their own world in slow motion, with the booster at full speed.
   Swap. Then `logs.cmd`: the server's journal must show `Sandevistan slows player N (… m away)`
   and `player N's client: slowed by player M's Sandevistan -- held by timescale; clock world at
   0.15 …` for each, and each player's own log `this game gives player bodies the ghost trail's
   parts -- … 48 of 48` and `a boosted player's body lit -- 48 of 48 parts` (16 of 16 up to 1.4.8).
5. **Development (1.4.9)**: the admin's "max all levels" on the server; the admin's own log must
   show `opx_sandy_view development: maxed on this machine (asked for) -- ...`, and the character
   screen the base game's maxima. Respawn: the line comes again with `(again on a new body ...)`.
6. **Arms and hands (1.4.10)**: boost and sprint in third person; every afterimage has its arms
   and hands.
7. **The MaxTac AV (1.4.10)**: bring the AV out at the MaxTac hangar (or have a MaxTac insertion
   fly in): the whole airframe -- body, doors, engines, cabin -- shows under its MaxTac markings
   on every player's screen, and each player's log has
   `opx_sandy_view maxtac av: ... drawn in the visible livery ...`.

---

## 11. Known issues and next steps

- **The real item is refused on a level-1 character.** The base game answers `equippable false`
  for `Items.AdvancedSandevistanApogee` with item level 0 against V's level 1. On the second
  player's character the same code fitted it on the first try ("fitted in the Operating System
  slot"), so it is the character, not the code: most likely a level or attribute requirement.
  Next: read the item's requirement records and either meet them or fit it past them.
- **Other players' view of the ghost trail and the slowdown around a boost** were fixed in 1.4.8
  and confirmed in game by two players on 28 September: on the observer's machine the log read
  `player 2's boost slows this machine -- world 0.15`, the engine's clock `world at 0.15 ...
  claims: opx_infinity 0.15 (holding)`, `a boosted player's body lit -- 16 of 16 parts`,
  `placed 77 times in 3.01 s, 4 of 4 showing`, and the engine's read-back of the farthest
  afterimage within a few centimetres of where it was asked (`1.72 m ... (asked 1.74 m)`).
- **Update rate.** The afterimages are moved about 16 to 23 times a second, not every frame. If
  they look steppy at high speed, the ticker is the thing to tighten.
- **Skin can flash dark.** Where V's skin shows, a hidden layer sits on the body, and a layer just
  leaving the body overlaps it. ESDE has the same behaviour. From 1.4.9 a layer shows from 0.2 m
  and twelve layers sit on the body when hidden, so this may show more; to be judged in game.
- **1.4.10 is built, not yet tested in game**: the afterimages' arms and hands, and the MaxTac
  AV's visible livery (and whether anything in a session puts the cloaked one back: the watch
  schedules the visible one again, at most twice, in its first ten seconds).
- **1.4.9 in game**: the twelve afterimages show (without arms up to 1.4.10); still to judge: the
  cost of placing 48 parts every frame, the 40 s boosts end to end, and the development maxed on
  the admin's machine (whether Open77's own progression -- the server grants it from its own
  records -- leaves the base game's maxima in place for the session).
- **Level-scaled boosts are built, not yet tested in game**: a 40 s boost end to end past the
  platform's `completed`, the grant held and given back (a revoke and a fresh grant: the power is
  projected anew on the player's machine after every lengthened boost), and the time left on the
  tray. Only a Sandevistan with a `LOOK` lengthens (the Apogee out of the box): the others keep the
  platform's own boost, which no level changes. After the platform's overdrive completes, the
  owner's body is no longer boosted by the platform (the speed is its); the slowed world and the
  exemption the view gives V carry the rest. A vehicle or a workspot entered after that point does
  not end the ripperdoc's part (the platform's releases are for its own overdrive); a death does.
- **Screen-space echo layers.** The `smasher` look still plays Smasher's particle trails and the
  NPC Sandevistan's aberration trails (`ch_npc_sandevistan_trail_left/_right`: the chromatic
  smear and the blurred afterimage) on the boosted body, for everybody. Since 1.4.4 the owner's
  third-person model no longer plays the echoes its own template authors
  (`fx_sandevistan_left/_right`, `fx_sandevistan_versus_loop`); only its gold eyes are lit. If any
  of the look's layers fight the ghost trail visually, each is one line in
  `SANDEVISTAN.LOOKS.smasher.LAYERS`.
