# Platform requests

Limitations of the Open77 platform that OPX works around and cannot fix itself.
Each section is the ask to send to the Open77 team, what OPX does meanwhile, and
what to change here once it lands. Update the **Status** line when the platform
answers.

---

## 1. Prop aliases for weapons and small items

From #108. **Status:** not yet requested.

**Limitation.** Every droppable item names a curated `Open77.props` alias for its
ground pile (#68). The alias table is compiled into the client plugin
(`kModelAliases` in `client/src/api/Props.cpp`); `Open77.props.catalog()` on the
server returns `{}`. There is **no alias for a gun, a blade, a bat, a phone, a card,
a shard or a key fob**, and a resource cannot add one: no native, manifest field or
`preload_mod` package registers an alias (a mod can ship meshes nothing points at).

**Evidence.** Test server op77.121 mirrors 222 aliases (`open77_admin`
`shared/config.lua`, `props.models`); the devkit (op77.78) documents 185. A raw
`.mesh` passed to `Open77.props.create` draws a marker. See the header of
`modules/inventory/data/weapons.lua` and `tools/generate-prop-aliases.mjs`.

**Meanwhile.** Those items drop as the closest generic case (`military.case.large`
for a long gun, `crate.ammo_box` for rounds, ...). Server log on a bad alias:
`[inventory] the pile prop <alias> could not be created: <why>` (an unknown alias answers `unknown_alias`).

**Ask.** One alias per weapon family (pistol, revolver, SMG, rifle, shotgun,
sniper, blade, blunt) and for phone, card, shard and key fob, **or** a way for a
resource to register an alias to a shipped mesh.

**When it lands.**

- [ ] Regenerate `tests/prop-aliases.lua` with `node tools/generate-prop-aliases.mjs <config.lua>`.
- [ ] Point weapons and the listed items at their own alias; update the header of `modules/inventory/data/weapons.lua`.
- [ ] Suite green; drop of each item checked in game.

---

## 2. Native loading-state API

From #109. **Status:** not yet requested. Blocks [IN_GAME_CHECKLIST.md §3](IN_GAME_CHECKLIST.md#3-loading-cover-during-in-play-loads).

**Limitation.** `modules/loading` needs to know when the game's own loading screen is
up (teleports, lifts, respawns). The platform has `Open77.screen.loadingState` /
`isLoading` (client, permission `screen.read`), but they are newer than the devkit's
op77.78 catalogue: the devkit cannot confirm the natives or the permission name.

**Evidence.** `open77_api` / `open77_permissions` on the devkit (op77.78) return
neither; `open77.lua` declares `screen.read` with a comment saying it is not in the
catalogue.

**Meanwhile.** The module feature-detects the reader on every pass. On a client
without it, it logs once and does nothing:
`[loading] this client has no Open77.screen.loadingState; the views keep their own visibility during loads`.

**Ask.**

- Ship `screen.loadingState` (with `kind` and progress) in a published client build.
- Add it and the `screen.read` permission to the devkit catalogue.
- Document the `kind` values a teleport, a lift ride and a respawn report.

**When it lands.**

- [ ] Devkit returns the natives and the permission for the target build; update the comment in `open77.lua`.
- [ ] Run IN_GAME_CHECKLIST §3.

---

## 3. `Open77.players.setModel` / `resetModel` in a server build

From #110. **Status:** not yet requested.

**Limitation.** The staff model commands `/opx.admin.self.model <model|off>` and
`/opx.admin.player.model <id> <model>` rely on `Open77.players.setModel` /
`resetModel`, which are in **no published server build**.

**Evidence.** `open77_validate` reports the call as "in no published server build".
`modules/admin/server/models.lua` looks the natives up before every call.

**Meanwhile.** Both commands answer `models_unavailable`, the admin menu greys their
rows, and the server logs once at boot:
`[admin] this build has no players.setModel native: opx.admin.self.model and opx.admin.player.model refuse with models_unavailable and the menu greys their rows. Every other command is unaffected.`

**Ask.** Publish `players.setModel` / `resetModel` and their permission in a server
build, **or** confirm they will not ship.

**When it lands.**

- [ ] If published: test both commands in game on staff and on a target (immunity respected), declare the permission in `open77.lua`, remove the validator note from the contributor docs.
- [ ] If they will not ship: remove the two commands, `models.lua` and the menu rows, and update the docs.

---

## 4. `open77_doors` without `open77_elevators`

From #111. **Status:** not yet requested.

**Limitation.** `doorlock` has two backends (`BACKEND` in `config/doorlock.lua`).
`networked` uses the platform's `open77_doors`, whose own authority refuses a locked
door to everybody. `local` has the server broadcast the state per routing bucket and
each client lock its own streamed doors: a modified client can open its own copy of
a door. The test server runs `local`, because `open77_doors` depends on
`open77_elevators`, which would take the cabins away from OPX's job-gated
`elevators` module.

**Evidence.** Server boot line `[doorlock] ready: <n> door(s), <n> refused, backend local`.
Forcing `BACKEND = 'networked'` without the service logs
`[doorlock] BACKEND = 'networked' but open77_doors is not running: every lock falls back to the local backend. Add open77_doors to resources.load.`

**Meanwhile.** `BACKEND = 'auto'` uses `open77_doors` when it runs and `local`
otherwise. Locks are enforced client-side on `local`.

**Ask.** Make `open77_doors` usable without `open77_elevators`: an optional
dependency, or a switch so `open77_elevators` does not adopt cabins another resource
manages.

**When it lands.**

- [ ] Test server runs `BACKEND = 'networked'` with OPX's `elevators` still owning the cabins; boot line shows `backend networked, <n> adopted`.
- [ ] A client forcing a locked door is refused (checked in game); IN_GAME_CHECKLIST §1 holdOpen on `networked` ticked.
- [ ] Docs say which backend is recommended.
