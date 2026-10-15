<h1 align="center">OPX//77 · opx_infinity</h1>

<p align="center">
  <strong>A serious-roleplay framework for <a href="https://open2077.net">Open77</a>, the Cyberpunk 2077 multiplayer platform: one resource, one WebUI, server-authoritative.</strong>
</p>

<p align="center">
  <a href="https://github.com/opx77-framework/opx_infinity/actions/workflows/check.yml"><img alt="check" src="https://github.com/opx77-framework/opx_infinity/actions/workflows/check.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/opx77-framework/opx_infinity"></a>
  <img alt="Version 0.2.0" src="https://img.shields.io/badge/version-0.2.0-informational">
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-orange">
  <a href="https://opx77-framework.github.io/opx77_doc/"><img alt="Documentation" src="https://img.shields.io/badge/docs-opx77__doc-c5003c"></a>
  <a href="https://discord.gg/xpSuYgEYsU"><img alt="Discord" src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://opx77-framework.github.io/opx77_doc/docs/getting-started/install">Install</a> ·
  <a href="https://opx77-framework.github.io/opx77_doc/">Documentation</a> ·
  <a href="https://opx77-framework.github.io/opx77_doc/docs/creators">For creators</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="https://discord.gg/xpSuYgEYsU">Discord</a>
</p>

---

> [!WARNING]
> **Alpha.** OPX//77 runs on a test server and changes quickly. APIs, config keys and
> features may change without notice; it is not production-ready yet.

## What it is

`opx_infinity` is the whole OPX//77 framework in **a single Open77 resource**: a core
runtime, 36 gameplay modules, one Vue WebUI page and one test suite. It replaced
twenty-one `opx77_*` resources in September 2026. Modules talk to each other through
in-process contracts; other resources reach it through a curated set of exports and
public server events.

It is built around three rules:

- **The server decides.** Every request from a client is re-validated on the server
  before money, items, doors or vehicles move.
- **The client stays inside its budget.** Open77 silently kills a client coroutine that
  runs too long, so every hot path is measured by the test suite.
- **Never a name to a stranger.** A character's name is learnt in roleplay; no plate,
  chat line, menu or payload reveals it.

## Features

- **Characters and economy**: accounts and characters, cash and bank, jobs and gangs
  with grades and duty, company accounts, paychecks, needs (hunger, thirst, stamina,
  street cred) decayed on the server.
- **Join flow**: a join screen, the game's character creator, a name, spawn
  locations, appearance and a fitting room.
- **Inventory**: bag, hotbar, stashes, trunks and gloveboxes, ground piles with real
  props, weapons drawn from the bag, eddies as a bearer item, gives the receiver accepts.
- **Vehicles**: an owned-vehicle registry, keys as inventory items with a real host
  lock, garages with entries and exits, dealerships with showrooms and
  player-to-player sales paid into a company account, and **fuel** (an ox_fuel port:
  tanks the server burns on the platform's `fuel` bag field, pumps paid in cash or
  bank, jerry cans, a gauge on the vehicle dial).
- **Places and world**: clothing stores, teleports, job-gated elevators, map blips,
  server-owned time and weather, and **door locks** (a faithful ox_doorlock port with
  its own staff panel).
- **Jobs and crafting**: crafting benches, gunsmith armouries, a hauling delivery job.
- **Interaction**: target eye, key prompts with one owner per key, progress bars,
  emotes (every platform animation, solo and duo), holocalls and contacts, chat.
- **Interface**: one Vue page with hand-drawn chamfered shapes (HUD, menus, forms, panels, toasts), recoloured
  live from the server's theme, in **English and French**.
- **Staff**: an F9 staff panel and eye rows, ACL-scoped commands, staff immunity,
  audit lines for every privileged action.
- **For creators**: server and client exports with a uniform `{ ok, value | error }`
  answer, public `opx:on:*` server events, runtime items, usable items, crafting benches.

Every module, with its commands, settings, events and refusal codes, is documented on
the [docs site](https://opx77-framework.github.io/opx77_doc/docs/opx_infinity).

## Quick start

You need an **Open77 dedicated server**, a **MySQL** database, and both repositories:
[`opx_lib`](https://github.com/opx77-framework/opx_lib) (the client library) and this
one. The full guide is [Install](https://opx77-framework.github.io/opx77_doc/docs/getting-started/install).

1. **Copy the two resources** into the server's resource root. The folder name must
   equal the resource name. The server only needs
   `open77.lua config core lib locales modules web` from this repository.

   ```text
   resources/
     opx_lib/
     opx_infinity/
   ```

2. **Load them in order**: `opx_lib` before `opx_infinity` (it is a declared
   dependency; the platform will not start `opx_infinity` without it).

   ```jsonc
   // server.jsonc
   "resources": {
     "load": [
       // ... the platform's own resources ...
       "opx_lib",
       "opx_infinity"
     ]
   }
   ```

3. **Connect the database.** Tables are created at first boot; there is nothing to import.

   ```jsonc
   // server.jsonc
   "database": { "enabled": true, "connectionString": "Server=...;Database=...;User ID=...;Password=..." }
   ```

4. **Grant staff rights** in the ACL file named by `accessControl.file` (usually
   `acl.jsonc`). A command namespace needs **both** its opener and its `.*` actions:

   ```text
   command.opx.admin          command.opx.admin.*
   command.opx.garages.*      command.opx.dealership.*     command.opx.clothing.*
   command.opx.doorlock       command.opx.doorlock.*
   command.opx.fuel.*
   command.opx.weather.*      command.opx.time             command.opx.time.*
   ```

5. **Restart and read the journal.** A healthy boot ends with one line per module and
   `opx_infinity 0.2.0 up`. `/opx.modules` and `/opx.version` print the same report in
   game. If something is off, see [Troubleshooting](https://opx77-framework.github.io/opx77_doc/docs/getting-started/troubleshooting).

Server toasts (`OPX.Notify`, `OPX.NotifyLocale`) are drawn by this resource's own
overlay, in the configured theme. The platform's `open77_notifications` package is not
needed for them.

## Configuration

Every setting lives in [`config/`](config): one file per module (`config/<module>.lua`)
plus the runtime-wide `shared.lua`, `server.lua` and `client.lua`. Edit, then restart
the resource. Player-facing text is in each module's `locales.lua` and in
[`locales/`](locales).

See [Configure](https://opx77-framework.github.io/opx77_doc/docs/getting-started/configure)
and the **Configuration** table on each module's page.

## Documentation

| | |
|---|---|
| **[Documentation site](https://opx77-framework.github.io/opx77_doc/)** | Install, configure, every module, every export and event, guides. |
| [`docs/MANUAL.md`](docs/MANUAL.md) | The developer manual: the two runtimes, how a module is built, and the reasoning behind each feature's rules. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Branches, checks before pushing, commit messages, house style. |
| [`ui/README.md`](ui/README.md) | The WebUI design system. Binding for any change under `ui/`. |

## Development

Requirements: **Lua 5.4** (desktop), **Node.js** and npm, and an `opx_lib` checkout.

```bash
# the test suite boots the real manifest on a stub platform (tests/host.lua)
OPX_LIB_PATH=../opx_lib lua tests/run.lua

# syntax check (open77.lua is the manifest DSL, not Lua)
luac -p $(find . -name '*.lua' -not -name 'open77.lua' -not -path './node_modules/*')

# the WebUI: sources in ui/, the shipped bundle is web/index.html (commit it)
npm ci && npm run typecheck && npm run build

# the client budget meter: lists every client call site whose worst resume
# costs more than the figure (the client kills a resume at about 10,000)
OPX_BUDGET_METER=5000 OPX_LIB_PATH=../opx_lib lua tests/run.lua
```

CI ([`check.yml`](.github/workflows/check.yml)) runs the syntax check, the suite against
the real `opx_lib`, the sandbox-globals check (`tools/check-sandbox-globals.py`), and
checks that every Lua file is listed in the manifest and that SQL stays in storage.

## Contributing

Contributions are welcome: bug reports with journal lines, in-game verification of
[`needs-in-game-test`](https://github.com/opx77-framework/opx_infinity/issues?q=is%3Aopen+label%3Aneeds-in-game-test)
issues, translations, documentation and code. Read [`CONTRIBUTING.md`](CONTRIBUTING.md)
first; nothing is pushed to `main` directly. Everyone taking part follows the
[Code of Conduct](https://github.com/opx77-framework/.github/blob/main/CODE_OF_CONDUCT.md).

Questions belong on [Discord](https://discord.gg/xpSuYgEYsU) rather than in issues.

## Security

Please **do not** report vulnerabilities in public issues. Use a
[private security advisory](https://github.com/opx77-framework/opx_infinity/security/advisories/new);
see the [security policy](https://github.com/opx77-framework/.github/blob/main/SECURITY.md).

## License

[MIT](LICENSE). Copyright © 2026 Luís MOUTA.

## Credits

- Built by **dop42** and the OPX//77 contributors.
- Door locks follow [ox_doorlock](https://github.com/overextended/ox_doorlock) by Overextended;
  the documentation is modelled on the [overextended docs](https://github.com/overextended/overextended.github.io).
- Shape geometry derived from [augmented-ui](https://github.com/propjockey/augmented-ui) (BSD-2, notice in `ui/src/design-system/shapes.css`); fonts Rajdhani,
  Saira and IBM Plex Mono via [Fontsource](https://fontsource.org).
- Wardrobe garment pictures: see [`web/images/clothing/ATTRIBUTION.md`](web/images/clothing/ATTRIBUTION.md).
- Runs on [Open77](https://open2077.net).

Support the project on [Tipeee](https://fr.tipeee.com/dop42/).

<sub>OPX//77 is an independent community project and is not affiliated with or endorsed by CD PROJEKT RED.</sub>

---

# Developer guide

What follows is the working manual of the roleplay framework branch: how the code is laid out, the two runtimes, the creator API, the library, the UI, the tests and the deploy.

## Working here

### Branches

**Nothing is pushed to `main` directly.** Branch, push the branch, open a pull
request. `main` is what the test server is expected to be able to run.

```
feat/<thing>     a new capability
fix/<thing>      a defect
audit/<thing>    a sweep across the codebase
```

### Before you push

```bash
lua tests/run.lua                                   # must be green
luac -p $(find . -name '*.lua' -not -name 'open77.lua')
npm run typecheck && npm run build                  # only if ui/ changed
```

`open77.lua` is the manifest DSL, not Lua — `auto_start true` does not parse, so it
is excluded from the syntax check. Every Lua file must be listed in the manifest of
the resource it belongs to or CI fails: a file nobody listed never loads, and nothing
else tells you. That is the root `open77.lua`, or, for a file inside a folder with an
`open77.lua` of its own (`extras/opx_sandy_view`), that folder's.

#### `open77_validate`: what it gets wrong here

The devkit validator (checked against 2.31.13+op77.78) reports errors on `main` that
are not runtime problems. Read past these; treat anything else it says as real.

- **`loadscreen`, `web_ui_page`, `web_ui_auto_create` "unknown directive".** Its
  manifest schema is incomplete. `web_ui_page` is in the server-resources guide's own
  example and the `Open77.webui.default` card; `loadscreen` is what
  `Open77.session.loadScreen` (since op77.11) reports; `web_ui_auto_create false` is
  the convention every opx77 resource uses to create its surface itself. All three
  run in production.
- **`require` in `lib/client/lib.lua` "is nil in the sandbox".** That rule is the
  *server* sandbox. The file is a `client_script`, and the client has `require`
  (the `require` card and the lua-modules guide; `@dependency` since client
  op77.67). See the table below.
- **`players.damage.apply` / `players.damage.read` "required but not declared".**
  The cards for `setArmor`, `setHealth`, `setMaxHealth`, `setGodMode` and
  `getHealth` list the damage.* names only as an older spelling the runtime still
  accepts; the catalogued names, `players.stats.apply` and `players.stats.read`, are
  declared. Do not add the old spellings. The suite's "permissions the code needs"
  section checks every gated call against the manifest, with either spelling.
- **`Open77.players.setModel` "is in no published server build"**: true, and
  handled. `modules/admin/server/models.lua` looks the natives up before every call,
  the two model commands answer `models_unavailable`, and the server logs one line.

`npm run build` writes `web/index.html`, which **is** the shipped bundle. The sources
under `ui/` never leave the repository.

### Commit messages

Say what changed and **why it was wrong before**. A reader six months out needs the
argument, not the diff — they can read the diff. If a change fixes something that was
failing silently, say what the symptom looked like from the game, because that is what
somebody will search for.

---

## Two runtimes, and what only one of them has

| | server | client |
|---|---|---|
| `require` | **no** | yes |
| `load` / `loadfile` / `dofile` | no | no |
| `LoadResourceFile` | own resource only | own resource only |
| instruction budget | none (1,024 task quota) | **per RESUME: a 10 000-instruction hook inside a ~300 us slice** |

The client budget is the single most expensive thing to forget. A loop without a
`Wait` does not crash and does not repeat — it stops, and the only trace is one
`Open77 script execution budget exceeded` line naming whatever instruction
happened to be the 10 000th. `modules/target` is built in slices for exactly this
reason; read its header before writing anything that walks a list every frame.

The unit is the RESUME, not the frame: the host arms a count hook every 10 000 VM
instructions and raises at the first hook after the save point, and the slice it
measures against is `frameBudget / resources running` floored at 300 us — 214 us
before the floor, with ~28 resources on a client. So the workable rule is one
line: **a resume may run at most one hook interval, and loops yield between
them.** The lifecycle follows it for you — see below.

The server having no `require` is why `lib/shared/` exists and will keep existing.
See **The library** below.

---

## Layout

```
open77.lua              the manifest. Load order is this file, top to bottom
config/                 operator settings, one file per module
core/                   the runtime: registry, lifecycle, channels, schedulers
lib/shared/             helpers on BOTH runtimes, installed as OPX.*
lib/server/             storage and audit
lib/client/             the opx_lib bridge and the WebUI surface
modules/<id>/           one gameplay concern
  module.lua            the contract: Declare, events, page channels
  shared/  server/  client/
  data/                 catalogues
  locales.lua           EN and FR, and they must stay in step
ui/src/                 the Vue application
  design-system/        tokens, shapes, surface, fonts
  modules/<id>/         one view per module
web/                    the BUILT bundle, and the join screen
tests/                  host.lua (a stub platform) and run.lua
```

### A module

```lua
local M = OPX.Modules.Declare{ id = 'thing', side = 'both', fatal = false }
```

Four optional phases, run in dependency order across every module: `Init`, `Api`,
`Start`, `Stop`. `M.Settings` is `OPX.Config.MODULES[id]`, **captured at Declare
time** — if your config is a `server_script` rather than a `shared_script` it may not
have run yet, so read `OPX.Config.MODULES[id]` in `Init` instead. That exact trap
cost a release.

**A PHASE BODY MUST NOT YIELD, AND THE LIFECYCLE YIELDS BETWEEN MODULES IN EVERY
PHASE.** `Wait` inside any of the four is a bug; the resume boundary belongs to the
loop, which puts one after each module so no phase has to think about the budget
above. Yielding inside a body would leave that module half built for a frame, which
is the thing this arrangement exists to avoid — the boundary is only ever between
two modules, never inside one. The failure this prevents is not a slow boot: the
boot's first frame used to hold every `Init`, every `Api` and the first `Start`,
and when it overran, the coroutine died, every module after it was never started,
and a live client sat on "Preparing character" for ever with one error line naming
a table lookup.

Modules talk through **contracts**, never by reaching into each other:

```lua
OPX.Api.Provide('thing', 1, { DoIt = ... })
local thing = OPX.Api.Get('thing')          -- nil when it is not running
```

Use `requires` for a hard dependency and `OPX.Api.Get` for a soft one. Two modules
that require each other are refused as a cycle.

### Three event channels

| prefix | reaches | for |
|---|---|---|
| `opx:net:` | across the wire | client ↔ server |
| `opx:on:` | this VM, public | another module listening |
| `opx:in:` | this VM, private | one module's own halves |

`OPX.Event(channel, module, name)` builds the name. **The server is authoritative:**
anything arriving on `opx:net:` is a request from a machine the player owns, and is
re-validated before it is believed.

### The view seam

A module owns state and rules; it does **not** draw. It publishes on one event and
takes everything back through one function:

```lua
TriggerEvent(M.Event.ON_VIEW, { kind = 'panel', ... })   -- out
function M.FromView(action, payload) ... end             -- in
```

A separate file — `client/view.lua` — is the only thing that knows the other end is
a CEF page. `modules/chat/client/view.lua` is the reference. Before writing a new Vue
page, check whether `menu` or `panel` already draws what you need; the wardrobe's
whole fitting room is drawn by `panel` through such a bridge.

### How a player opens one

A bridge that nothing calls draws nothing, so every surface needs a door a player can
actually reach. The appearance module's is `/opx.appearance`, which toggles the
appearance panel; it is unrestricted because it acts on the caller alone. There is no
key for it and no command for the fitting room: `WARDROBE.OFFER_POLICY` ships `first`,
which hands the room to a character the game's own creator has just built, and after
that the room is reached at a **clothing store** (see *Getting dressed*) or opened for
a player by staff with `opx.admin.player.wardrobe`. A free command onto a room whose
changes `modules/shops` prices would make the price optional, which is why
`opx.appearance.wardrobe` was removed.

The places — garages, dealers, stores, teleports and **lifts** — all use the same
door: a rebindable key (**E** out of the box, one mapping per module) and a row on the
key strip while the player stands at one. A configured elevator is adopted LOCKED,
which refuses the game's own in-cabin button on purpose; its key (`KEY` in
`config/elevators.lua`) opens the job-gated floor list instead, and the server
re-checks the floor before the cabin moves.

### The garage key: out, and away

`garages` is a **place**, like a dealer and a store: stand on the marker, press its
key — **E** by default and rebindable — and it does one of two things. On foot it
brings one of the character's own vehicles out AT the spot; **sitting in one of them,
the same key puts it away**, filed under the spot the player is standing on, which is
what makes it come out there next time. Which of the two is decided on the SERVER, from
the seat the host reports and the plate the `vehicles` contract holds: a client that
said "I am in my car" would be a client deciding what gets stored. The client's half of
the decision is only which of the two texts the row shows.

**A vehicle that is already out is MOVED to the marker, not answered.** It used to be
answered with the id it already had — `Ok`, "Brought out XX", and an empty spot in
front of the player, because the car was parked on the other side of the map, which is
what a player found and reported by pressing the key six times in one session. The
`vehicles` contract recalls it instead: put away first, which writes its condition
back, then created again on the marker and facing the marker's own heading. It refuses
with `vehicle.occupied` when somebody is sitting in it, because the occupant is not
necessarily the player who asked. A request that names no place — the module's own
spawn event, and the nearby-the-player path — keeps the old answer: moving a car for
"somewhere near me" would be a surprise rather than a service.

A **garage is a key, and a key may be in several places.** Each of its locations has
three kinds of point: a **menu** point, where the list of everything filed under that
key opens — whichever location it was stored at; one **entry** point, the door a vehicle
is taken in at; and an ordered list of **exits**, tried in the order written, where it
comes out. The first exit with nothing parked within `EXIT_CLEARANCE` of it wins, and
when every one of them is taken the request is **refused and the player told so**,
rather than queued behind a car nobody may move or created inside it. The vehicle being
fetched never blocks its own bay: a car left standing on the only exit of its own garage
would otherwise be a car that can never be recalled.

Garages are written in `config/garages.lua` under `GARAGES`, and nowhere else.
`/opx.garages.add` and `/opx.garages.remove` **are gone**: they wrote a place every
player uses into `opx77_garages`, so the shape of the world lived in a table nobody had
a copy of. Nothing was lost with them — the server still READS that table at boot,
adopts every row in it that the config file does not name (as one location whose menu,
door and only exit are that one captured point, which is exactly what a spot used to
do), and prints each one as the block to paste into the config. `/opx.garages.list` and
`/opx.garages.bring <key> [plate]` remain, ACL-gated under `command.opx.garages.*`.

### Buying a vehicle

`dealership` sells what `vehicles` owns. A **dealer is a place**, like a garage spot:
stand on its marker, press its key — **E**, the garages key, rebindable — and the list is
the `menu` module's, drawn one screen at a time. The first screen is the stock of that
dealer's category, grouped by class and priced with the currency table the server
owns; the second is the garage the bought vehicle is filed under, read from the
`garages` contract rather than kept as a copy. With no garages module the second
screen still offers one row — the vehicles module's own default — so a dealership on a
server without garages is a working dealership with one fewer choice.

The two categories are the garages ones, and they decide what may be sold where: a
`garage` dealer sells ground vehicles, an `avpad` dealer sells AVs, and a row whose
record disagrees with the dealer's kind is refused rather than redirected. The rules
are re-derived on the server — the distance across the ground, the routing bucket,
whether THAT dealer sells THAT row, and whether the money is really there — and the
charge goes first, because the vehicles contract can refund and cannot uncreate. A
registration that is refused after payment is refunded in full and the failure is
logged with what was bought; a hand-over that is refused is *not* a failed sale: the
vehicle is owned and filed, and only the convenience of driving it away is reported.

A dealer also has a **showroom floor** and a **zone**. An operator dresses the floor
with **preview points**, written in `PREVIEW.POINTS` in `config/dealership.lua`: each
one stands a model of the stock list at a position and a facing the file names,
**locked** — an unlocked showroom car is a free car with an audience — and persistent,
because a showroom car is furniture. To capture a point, stand where the car goes,
face the way it should face, and run `/opx.admin.self.pos`, which copies the position
**and your facing** to your clipboard; paste the numbers into a row. A showroom placed
before 2026-09-21 lives in `opx77_dealership_previews` and is adopted at every boot,
which also prints each one as the config line that recreates it.

Inside a dealer's `ZONE_RADIUS` the target eye grows a **"sell a vehicle"** row on every
other player, so a salesperson sells face to face. Pressing it charges nobody: an
**offer** is recorded and **the buyer's own client confirms it**, which is deliberate —
money that leaves an account because somebody else clicked something is a support ticket
whatever the salesperson meant by it. An offer carries its own name, so an answer to one
that has been replaced buys nothing, and it expires on the server's clock with both
sides told. The buyer's yes leads to the same garage screen a counter sale has, so the
car is filed under the garage the BUYER picks (or the vehicles module's default when
they have none). On a yes the price is charged to the buyer, paid into the **company
bank** of the seller's job (or gang, when they have no job) in `opx77_company_accounts`,
and `SELLER_CUT_PERCENT` of it is paid to the seller as commission — rounded down, with
the remainder to the company, because the other way round mints currency on every odd
price. A company deposit that fails is not a failed sale and is not forgotten either:
it is written to `opx77_company_pending` and a sweep, at boot and every minute, pays it
in and strikes it off in one transaction, so a retry can never pay it twice.
Either way the sale is raised as `opx:on:dealership:sold` — `kind = 'counter'` or
`'offer'`, with the `garage` the buyer chose — and an offer sale whose company share
went to that ledger says so with `pending = true`.

Dealers are written in `config/dealership.lua` under `SPOTS`. `/opx.dealership.add` and
`/opx.dealership.remove` **are gone**, for the reason and with the same migration the
garages section describes: the legacy table is still read at boot, every row the config
does not name is adopted, and each is printed as the line that checks it in.
`/opx.dealership.list` names every dealer, its origin and every showroom car standing on
it; `/opx.dealership.stock` lists what is for sale and which kind sells it; and
`/opx.dealership.buy <key> [garage]` buys from chat, which is what a player uses on a
client whose list could not open. `list` is ACL-gated and the two that act on the caller
alone are not.

### Vehicle keys

A key is an inventory item, `vehicle_key`, and **which vehicle it opens is its
metadata**: `{ plate, label }`, written by `modules/vehiclekeys` and never by a client.
Keys do not stack, and the bag and the hotbar draw each one under its own label —
*Villefort Cortes · 12ABC345* — so two keys read as two cars. Inventory metadata was
already stored, merged and moved whole; the contract gained `CountWhere(target, name,
match)`, which counts units whose metadata carries the fields named (a key to a plate,
whatever its label says), and the screen now prefers a stack's own `metadata.label`
over the catalogue's name.

**The plate is the identity.** An owned vehicle is keyed by its real plate. A vehicle
`vehicles` never registered — a staff spawn, a showroom car — has no plate, so the
first key cut for it mints one, `TMP-` and six characters. A real plate is letters and
digits only, so a minted one can never equal it; it is held in memory and forgotten
when the host removes the vehicle, and a key to it then opens nothing.

**Who gets one.** The buyer, when a dealership sale completes (hand-over or not). The
owner, when a garage brings the car out **and their bag holds no key to that plate** —
ten take-outs are one key, and a key given away is replaced on the next one. Whoever a
staff spawn was left beside (`opx.admin.vehicle.spawn`, `.give`). A full bag is said to
the player and is never a reason to refuse the sale or the take-out.

**Staff cut a key to a precise vehicle** with `opx.admin.vehicle.key <vehicleId|near>`,
into their own bag: the eye row *Give me the key* on a vehicle sends the id it landed on,
and the menu's vehicle screen sends `near` (the seat, else the nearest in the
operator's bucket). The server resolves the vehicle and its plate itself; there is no
plate argument. It is under `command.opx.admin.vehicle.*`, so an operator role already
holds it.

**What a key does is the host's lock.** `Open77.vehicles.setLocked` moves the durable,
replicated entry lock the engine enforces (a locked car offers no way in). The row
*Lock / unlock* on a vehicle, or using the key from the bag, turns it — for somebody
holding a key to that plate, within 6 m or seated in it, both measured by the server.
**A locked vehicle's trunk is shut**: `World.TrunkLocked` refuses the open with
`inventory.error.locked` and closes one already open on the next reach sweep. The
glovebox is not asked; it opens only from a seat. Nothing gates the engine yet.

### Door locks

`doorlock` is ox_doorlock's model on Open77's own world doors: **"les portes fermées /
ouvrables par des jobs, grades etc."**, configured from a staff panel. A door has a
name, **one or two native doors** (a double door is two leaves turned together), a
default state, the **groups** that turn it (a job or a gang, each with a minimum
grade; any one is enough), the **key items** that turn it, the **characters** that turn
it, an optional **code**, an **autolock** delay, whether it can be **picked** and how
hard, how close a player has to stand, and whether its prompt is drawn. A door with no
rule at all opens for staff only, as in ox.

**A door is named by its native id** (`0x` and sixteen hex digits), never by a model or
a coordinate. The native door keeps its own animation, sound and collision: this module
only ever moves its LOCK, and it does so through one of two backends (`BACKEND` in
`config/doorlock.lua`):

- **networked** — the platform's `open77_doors`. Each managed door is `register`ed to
  this resource and locked with its `setLocked` export, so the lock is the platform's
  server state and refuses every player's open request. A sweep re-adopts a door the
  service forgot after a restart.
- **local** — no platform service. The server holds the state and broadcasts it per
  routing bucket; every client puts its streamed managed doors into it with
  `Open77.doors.setLocked` and refuses vanilla interaction on a locked one
  (`setInteractionAllowed`). **This is what the test server runs today**, because
  `open77_doors` depends on `open77_elevators`, which would take the cabins away from
  the job-gated `elevators` module. It is the weaker promise — a modified client can
  open its own copy of a door — and `auto` moves to the networked backend by itself the
  day `open77_doors` is in `resources.load`.

**The server decides.** A client sends a door key and the state it wants; the server
reads the player's position and bucket from the host (the door's own reach plus
`SLACK`), the job, gang and grade through `OPX.JobGate`, the bag through the inventory
contract, and only then turns the lock, arms the autolock on its own clock and tells the
bucket. A refusal is a toast naming why (grade too low, off duty, no key, wrong code,
too far). **E is shared**: away from a managed door the key sends nothing and says
nothing. The target eye carries *Lock / unlock* (with the state as its checkbox) and
*Pick the lock* (a locked, pickable door, a `lockpick` in the bag). A pick is a
`progress` bar on the client and a clock and a roll on the server: a "done" that arrives
before the bar could have run is refused and audited, and a failed roll breaks the pick
at `LOCKPICK.BREAK_CHANCE`.

**Key items.** `{ NAME = 'keycard', REMOVE = true }` opens for anybody carrying one and
spends it; `{ NAME = 'door_key', BOUND = true }` opens only for a `door_key` whose
metadata names THIS door — `/opx.doorlock.key <door> [player]` cuts one — and is never
spent.

**Two places a door comes from.** `DOORS` in `config/doorlock.lua` are read-only
defaults; everything staff create in game lives in `opx77_doorlock` (one row per door,
the door itself one JSON column, like ox). The panel can turn a config door and
teleport to it, never edit or delete it. `/opx.doorlock.list <door>` prints any door as
the config block that checks it in.

**The staff panel** opens from **World → Door locks** in the staff menu, from
`/opx.doorlock`, or from the eye's *Manage door* row on any door. *The door in front of
me* (crosshair, else the closest within 3 m) opens a managed door's editor or a new
draft for an unmanaged one; *Doors* lists every door, paged and searchable. The editor
is a DRAFT — toggles, sliders and lists change this client's copy until **Save** — and
holds the name, locked by default, *Lock now*, jobs and gangs with a grade, key items,
characters, the code (never sent back to a panel; an edit that does not name it keeps
it), on-duty only, autolock, pickable and difficulty, reach, hide the prompt, the
second leaf (picked from the native doors within 4 m), *Teleport to the door* (the staff
module's `opx.admin.player.tp`), *Give me a key* and *Delete*.

| ACL entry | what it opens |
|---|---|
| `command.opx.doorlock` | the panel, the list, the eye's *Manage door* row |
| `command.opx.doorlock.save` | the panel's Save (a net event the server gates on this entry) |
| `command.opx.doorlock.remove` / `.lock` / `.key` / `.list` | the commands of those names |
| `command.opx.doorlock.bypass` | turning any door without a key or a code |

So an operator role needs `command.opx.doorlock` **and** `command.opx.doorlock.*`.
Every save, delete, staff lock and key is audited (`doorlock.create`, `.edit`,
`.remove`, `.lock`, `.unlock`, `.key`), and every change of state is published as
`opx:on:doorlock:changed`.

**Not here, deliberately:** ox's `doorRate` (the native door animates at its own speed)
and its NUI sounds (`SOUNDS.LOCK` / `.UNLOCK`, or a door's own, are Wwise events played
through `Open77.sfx.play` for the player who turned it, and ship empty). The platform's
own force / pay / hack door actions are not declared: a locked managed door refuses
them.

### Getting dressed

`clothing` is a **place**, like a garage spot and a dealer: stand on the marker, press
its key — **E** again, and again a separate mapping — and the **fitting room** opens.
No clothing is reimplemented here. `appearance` already streams this body's whole
catalogue into a room a player may browse, try pieces on and keep
(`Open77.equipment.records`, unrestricted, every slot, batched onto its own thread),
and it owns the puppet, the save and the rules about who is offered the room at all. A
store that drew its own list would be a second catalogue with its own idea of what a
body may wear, so it has none: this module owns the place and the door, and the room
behind the door stays the appearance module's.

That is also why a store carries **no kind and no heading**, and why `/opx.clothing.add`
asks the client for **nothing at all**. The garages and the dealership ask their own
client back for a facing, because a chat line has none and a vehicle needs one; a store
has no facing, so the position — read from the connection running the command, never
off the wire — is the whole of what a capture needs. There is no capture round-trip in
this module, no deadline waiting for its answer and no "did not answer" warning,
because there is nothing to ask.

It ships with **no stores**, and it is the one of the three that still captures its own:
`/opx.clothing.add [key] [label]` captures one where the operator is standing, names a
key back when it is given none, and prints the line to check into `config/clothing.lua`
so the store survives a database reset. `/opx.clothing.remove <key>` deletes a captured
one and refuses a configured one, and `/opx.clothing.list` names every store, its
position, its bucket and its origin. All three are ACL-gated, and they are the only
commands this module has.

**What a player is told when the door will not open.** The room refuses for reasons
that are about the player and not the store — `player_down`, `no_character`,
`appearance_busy` — and those reach the key as the room's own words rather than a
generic failure. On a server running the platform's own `open77_appearance` package the
contract is simply absent, and the key says that out loud instead of doing nothing: the
markers draw and the row posts either way, so silence would be the one answer nobody
could read.

### A job, a rank, and the desk that moves it

`jobs` is a **place**, like a garage spot, a dealer and a store: stand on the marker,
press its key — **E**, its own mapping again — and a menu opens. There are two kinds of
board and they are not the same thing. A **sign-up board** is one employment office: it
lists **every** job `config/jobs.lua` offers (nine ship) with your own standing against
each — the grade you hold, how far the next rank is, or what the terms are missing — and
any of them may be taken there. A character holds any number of jobs and **works one**:
a job taken while another is worked is held beside it, and its row at the office offers
**Work this job** (switch to it) and **Hand in your notice** (leave that job). A **desk** is one division's, is shown only to the holder of that
job's boss grade — and to whoever captured it, so an operator can see where they put it,
which is a placement aid and not a promotion: every desk action re-derives that grade on
the server and the roster is attached only for its holder — and is where a roster is
managed: hired, promoted, demoted, dismissed.

**A marker nobody can see is indistinguishable from a marker that was never placed**, so
this module says which it is. The capture answer names the audience — *shown to every
player within 150 m* for a sign-up board, *a desk is shown to the holder of ncpd grade 3,
which you hold* for a boss, and for a capturer below that grade the plain sentence that
they will see the marker and the roster will refuse them — and the client logs one line per
change of what it holds and draws (`5 board(s) held, 1 marker(s) drawn; nearest 3.4 m`),
which is what separates *the server never sent it* from *it is three kilometres away*.
Both exist because a live server showed the failure they describe: an operator captured two
desks, read `saved`, and saw nothing at all.

**This module owns the terms of employment, not the employment.** Who holds what, at
which grade, on duty or not, and what each grade is called and pays is
`config/character.lua`'s `JOBS`; the character module stores it, replicates it and gates
elevators, armouries and teleports with it. What the catalogue has no field for is
**where** a job is joined, **who** may join it and **how long** the next rank takes, and
that is all `config/jobs.lua` decides. The two tables must agree and are not allowed to
drift: every job named here must exist there, and every `LADDER` level must be a grade
that job really has. A ladder naming a grade nobody defined would promote somebody into a
rank with no name; both faults are named at boot by `Access.Problems` rather than
discovered by a player.

**A rank is granted by a person, and worked time is what they read.** A holder who is
*on duty* in a job with a ladder banks `POINTS_PER_TICK` every `TICK_MS` — the shipped
rate is a point a minute — and a level's number is the time that rank is expected to take,
so `[1] = 90` is ninety minutes. Duty is the character module's own field and not a second
one, so a job with `defaultDuty = true` banks while a player plays and a police officer
banks while clocked in. The bank never moves a rank by itself: the owner removed the
automatic promotion, so only the job's boss (the desk, `/opx.jobs.promote`) or an operator
(`/opx.job`) promotes anybody.

A promotion goes through the **character contract**, in one function, so a rank gained at
a desk is the same rank `/opx.job` grants: it arrives on the same client event, pays and
`isBoss` the same, and every gate that already reads a job reads it. A character's
primary job carries a *copy* of its grade, so the primary is written through `SetJob`
(which rebuilds that copy) and every other membership through `AddPlayerToJob` (which
must not touch it) — a promotion that moved only the membership row would leave a captain
paid as a cadet and refused by every gate that reads `job.isBoss`.

It ships with **one office and three desks**, standing on an **arrival point** — the
Northside promenade entry of `config/spawn.lua`, which is where a player who picks it
lands — because a feature nobody can find is a feature nobody has, and because a marker is
drawn only within `MAX_DISTANCE`: the office stood at the platform's old default spawn,
kilometres from every spawn this server offers, and read in game as *the job marker isn't
appearing*. The desks are spaced 7 m off the office and not less, because `USE_RADIUS` is
4 and two boards closer than that are two boards whose presses cannot be told apart. `/opx.jobs.add [signup|boss] [key]
<job>` captures one where the operator is standing, facing the way the board
should point — a chat line has no facing of its own, so the client is asked — and prints
the line to check into `config/jobs.lua` so it survives a database reset;
`/opx.jobs.remove <key>` deletes a captured one and refuses a configured one, and
`/opx.jobs.list` names every board, its kind, its job, its position, its bucket and its
origin. The rest are `/opx.jobs.join <job>`, `/opx.jobs.leave <job>`, `/opx.jobs.roster
<job>`, `/opx.jobs.rank <job> [citizenId]`, and the boss's own
`/opx.jobs.hire <job> <playerId>` and `/opx.jobs.promote|demote|fire <job> <citizenId>`,
which are the same doors the menu uses for a client whose list could not open. The placement
commands are ACL-gated under `command.opx.jobs.*` — they write a place every player
uses — and the boss actions are **not** in that list: a desk is granted by a grade and not
by an operator's ACL file, and the server checks that grade itself every time.

Hiring is a **scene**: the candidate must be standing within `HIRE_RADIUS` of the desk,
re-derived on the server from the connection it is acting on rather than trusted from the
boss's client, because hiring somebody across the map is not something anybody can see.
(The typed `/opx.jobs.hire` measures from the boss instead: it names a connection that
must be online and within `HIRE_COMMAND_RADIUS` of the boss, and is how the boss of a job
with no desk hires at all.) Either way a hire is an **offer**: the owner decided nobody is
hired without consent, so the candidate answers Accept or Refuse on their own screen within
`HIRE_OFFER_TIMEOUT_MS` (60 s), the server holds the offer under a token of its own and
refuses any answer that names another, and both sides are told the outcome.
The bank is this module's own and is the one thing it stores: it starts at nothing when
somebody joins, is deleted when they are dismissed so a rehire starts at the bottom
rather than walking back in at the rank they left, and is written back on a cadence and
after every change of rank.

### The wanted level is a crime score, not a fact

`ncpd` owns what a crime is worth, who is charged, and which division answers.
The engine's own wanted level is **an accumulated crime score**, not a value one
can set: `PreventionSystem` keeps the score, raises `EPreventionHeatStage`
(`Heat_0 .. Heat_5`) when it reaches the current stage's capacity, and zeroes it
as it crosses. The `wanted_level` quest fact is written *from* that stage and read
only by a debug overlay — setting the fact moves the bar and nothing else. So the
module drives the ladder rather than the fact, and the sirens, the radio, the
roadblocks, the wanted bar and every response unit stay the game's own.

`config/ncpd.lua` is the law book and needs no code to change: `LAWS` are
`{ id, label, score, ceiling }`, where `ceiling` is the stage at or above which an
offence stops counting; `LADDER` is keyed by the engine's own **heat number**, so
`[0]` is `Heat_0` — not wanted, whose capacity is the score that makes a player
wanted — and each row carries the score that leaves it plus the response the
engine already wires to it; `DISTRICTS` scales a score by district; `DECAY` is how
it falls again. `MAXTAC` is the separate division that arrives at `Heat_5`: the
Zetatech Surveyor and its variants, the troopers, the Merrimac and the ground pair,
the tag the engine gives a MaxTac NPC spawned outside its own system, and the rule
that troopers are **players who opted in, bots for every seat left empty** — so an
empty division is never an empty street.

Every value is validated when the resource loads and a value that cannot be used is
a **named warning, not a raise**: a law with a bad score costs that law and is
called out at boot, where an operator looks. The suite pins the arithmetic, the
vocabulary and eight negative controls; the boot line reads
`[ncpd] ready: 11 law(s), 5 heat stage(s): ncpd 1-4, maxtac 5`.

### The crew door: the aircraft is handed over, not shared

A MaxTac worker **on duty in the division** walks up to the AV while it holds at the
street and presses `MAXTAC.BOARDING.KEY.DEFAULT` — F out of the box. The row on the
strip, the seat and every refusal are decided one step at a time:

* **The window is the aircraft's, not the client's.** `server/av.lua` holds the hull
  still for `BOARDING.SECONDS` after the squad steps out and announces the door to the
  on-duty division; the client draws its row from the hull's position and
  `REACH_METRES` and nothing else, and a row that outlived the window is not possible
  because the same controller withdraws it. `/opx.ncpd.board [seat]` is the console
  door to the same decision — two doors, one implementation.
* **The mount is the platform's.** `Open77.vehicles.warpPlayerIntoVehicle(player,
  hull, seat, { moveBucket = false, exitLocked = true })` reserves the seat, publishes
  the forced entry and keeps the order until the client confirms the native mount.
  Proximity and the vehicle's own lock are bypassed by that call on purpose: the reach
  rule is ours and is measured from the position the **server** reads.
* **The hull is handed over the moment somebody is in it.** A player seated in an AV
  is its pilot as far as `VehicleReplication` is concerned — the claim test is
  `IsAvRecord(record)` and a seat occupied, at any seat — so the controller stops
  posing it, clears its freeze and lets the crew fly. Two hands on one airframe at
  10 Hz is a fight, not a ride.
* **Nobody is dropped.** The exit lock comes off when the hull is standing at street
  level (`REST_SPEED`, `REST_HEIGHT`, `REST_SECONDS`), when the insertion is
  retracted, or when the module stops. A crewing aircraft is never removed from the
  world: it is removed when the last of the crew has stepped out of it.

Every refusal is a code (`too_far`, `no_seat`, `notOnDuty` …) mapped once in
`M.BoardRefusal` to the sentence a player reads, so the officer who pressed the key
and the one who typed the command are told the same thing.

**What is not here, deliberately.** The red warning lines under a MaxTac AV belong to
the engine's own spawn setup, and an unoccupied server-flown airframe cannot command
them. The `prevention.av` seam answers `ticket 0` on the live node — the call lands
and the engine schedules nothing — so the insertion above is what actually flies the
squad in, and the squad is what steps out of it.

**The seam this rests on.** Raising a stage is a platform seam: `PreventionSystem`'s
287 methods are all scripted, so the client enqueues a command and its REDscript loop
runs it inside the script frame it owns, on the local player only. `open77-base`
carries `prevention.heat:<0-5>` and `prevention.av` today, each refused when the
player named is not the client running it, and the client reads the effect back with
`prevention.state`. `prevention.lock`, `prevention.blockfoot` and
`prevention.blockvehicle` are on the same queue. The engine's own AV route spawns
nothing, which is why the aircraft is an Open77 vehicle the server flies. The
reasoning, every record involved and the build order are in `docs/ncpd-maxtac.md`.

### The base game's missions

Side jobs picked up from NPCs are playable: the phone rings for a quest's call (answer
with a press of T), a quest's own items can be taken, the scanner works, and the
tracker, the markers and the quest toasts show. The preload's `OpxQuests.reds`
(opx_sandy_view 1.4.11) gives those back from the platform's multiplayer policy. On this
side, the weather clock stands back for 20 minutes when a mission moves the hour itself,
`config/hud.lua` leaves the tracker and the toasts to the game. A weapon a mission hands
over outside the bag IS taken off: the anti-cheat sweep (`REMOVE_UNBACKED = true`) stays on
by the owner's decision, so a step that needs such a weapon stalls. What each piece does, how
to read it in the client log, the switches and what stays the platform's are in
`docs/missions.md`.

### The grants a staff panel needs

**Opening the panel and using it are two different permissions, and the difference is
one dot.** The host decides a line's permission from the word actually typed —
`command.<word>` — so the opener is `command.opx.admin` and every action behind it is
`command.opx.admin.<action>`. The module registers 56 restricted commands: the opener,
and 55 actions under it (`opx.admin.self.noclip`, `opx.admin.player.goto`,
`opx.admin.vehicle.spawn`, `opx.admin.weapon.holster`, …). The matcher keeps the dot
and only a rule ENDING in `.*` is a prefix, so a role holding `command.opx.admin`
alone opens the menu and is then refused by every row inside it — the operator watches
a panel they cannot use, and no log line says why, because a refused command is not an
error the resource ever sees.

**A role for an operator therefore needs both spellings, and the same shape repeats
wherever a module owns a namespace:** `command.opx.admin` *and* `command.opx.admin.*`
to open the panel and use it, `command.opx.garages.*`, `command.opx.dealership.*` and
`command.opx.clothing.*` for the garage, dealer and wardrobe commands,
`command.opx.doorlock` and `command.opx.doorlock.*` for the door panel, and
`command.opx.weather.*`,
`command.opx.time` and `command.opx.time.*` for the world controls.

Only the `admin` and `owner` roles the server supplies avoid the question — they are
`command.*` and `*` — which is also why granting a human `admin` on a server that
loads a diagnostic resource hands them `command.client.exec` with it. The file is the server's
`acl.jsonc`, named by `accessControl.file`; `acl.jsonc` is not in this repository, so
the list above is the thing to copy into it.

**The eye is stricter than the panel about all of this, and it is the surface the
question usually arrives from.** The staff menu DRAWS a row it cannot run and greys it
with *Refusé*, so a missing grant reads as a missing permission. The target eye has no
greyed state — a row it cannot run is a row it does not register — so the same missing
grant reads as a missing feature. That is how `command.opx.weather.*` and
`command.opx.time` were first reported: an operator interacted with the sky, found
Noclip and PvP there and nothing else, and wrote in that the weather controls did not
exist. They existed; the role did not hold the weather module's commands, and the two
rows that were there are the two whose commands are `admin`'s own. The eye's rows that
end in another module's command are the weather presets, the weather roll and the clock
on the sky, and *Open their bag* on a player. **The eye now names the grants it dropped
rows for** in the line it already writes to the server journal per registration —
`[admin] target rows, player 3: 25 staff rows on the eye; 12 hidden, this ACL does not
grant: opx.inventory.open opx.weather.set opx.weather.next opx.time` — and each name in
it is a `command.<name>` to add here.

### The staff panel's spawn list

The staff menu's spawn screen is one folder per class, and **Air is the first of them**:
the six `Vehicle.av_*` records a staff member looks for by name. Which class a record
is in is not written down twice — a row's category is DERIVED from its record by
`VEHICLES.AV_PREFIXES`, the same rule the garages module and the dealership use, so a
record is in the air category for every part of the server or for none of it, and a
row cannot disagree with itself. A spawned AV is lifted clear of the ground by
`VEHICLES.AV_LIFT`, because an AV record's pivot is its chassis centre and the offset
that puts a car's wheels on the road leaves one half-buried; a car is not.

The list itself is `data/vehicles.lua`, indexed in parts because of its size — the
Air class is why there are five parts now — and a row that is malformed (a name or
record declared twice, a class that is not a class) is a boot warning rather than a
spawn that refuses in front of a player.

**A screen change UPDATES the open menu rather than replacing it.** The menu contract
owns both, and they are not the same thing: an update rebuilds the open menu from a
fresh spec and costs one frame, while an open closes the live menu first — a new
handle, a blank surface for the round trip, the configuration re-sent, and the page's
arrival walk re-run for a screen that did not arrive, it replaced one. The handle is
also the capability every intent from the page names, so a click landing inside that
window was dropped and the press had to be repeated. So `draw` updates in place
whenever its own menu is up, and passes a cursor only when the SCREEN changed: a
redraw keeps the player's position, a screen that replaced another gets the landing an
open would have given it.

**The staff panel asks for a taller window than the menu module's default.** The staff
tree is full of ten- and twenty-row screens and the module's own window is nine rows,
which drew a tenth row only after the operator scrolled. The panel therefore names
`rows = 12` and `maxHeight = 72` at open, in `modules/admin/client/menu.lua`'s `draw`,
and nothing else in the pack is affected.

### A broadcast announcement, and the two clips around it

The staff panel's **Announce** row sends a sentence to every player, and it is wrapped
by two stingers: one that plays **before the message appears** and one that plays **once
it has gone**. They are `ANNOUNCE.STINGER.OPEN` and `.CLOSE` in `config/admin.lua`,
next to the volume, and they ship in this resource — `ui/public/audio/` in the repo,
`web/audio/` in the pack.

**The announcement is drawn on this runtime's own overlay**, not by the platform's
`open77_notifications` package, and that move is what makes the stingers possible at
all: only the page that owns a toast's clock can hold a message back until the first
clip has finished. `OPX.Notify` hands the sentence to a surface this runtime does not
draw, so it could be told when to appear and never when to wait. The chat line still
goes out on core's own result channel, exactly as before.

**Nothing about the presentation crosses the wire.** The server sends the sentence and
its lifetime; each RECEIVING client reads its own config for the clips. A client with
no clips still gets the message, a client that turned one off by naming `''` gets the
message and one clip, and neither can make an announcement fail to arrive. The
delivery is the same best-effort fan-out the command always had — one client that
cannot be reached does not stop the rest — and the operator is told how many received
it.

**A clip name is a BARE FILE NAME, and that is a boundary rather than tidiness.** The
page resolves a name under its own `audio/` and nothing else is reachable from it, so a
name able to climb out (`../`, a slash, a scheme, a drive) would be a name able to make
every client in the city fetch from wherever a served config pointed. `core/client/
notify.lua` is the one place that decides what a toast may carry and it DROPS a name
that does not fit — the clip, never the message — because a typo in a presentation
setting must not cost a player the sentence an operator sent them. The page repeats the
test, because a page does not trust the wire.

**No stinger is ever load-bearing.** The clip helper answers on `ended`, on a decode
error, on a refused playback and on a deadline, and every one of those answers draws
the message; a page whose message never appeared because a file was missing would be a
worse fault than a silent stinger. The deadline is what stops a longer or a stalling
clip from holding an announcement hostage.

The two clips that ship are MP3, which is worth stating because this runtime's other
media path is `.webm` (VP9 + Opus) — an MP4 never plays in this CEF at all. MP3 is in
the free codec set this build carries, and it is **checked against the deployed
binary** rather than assumed: `Open77.WebHost.exe --open77-self-test-probe=<out>
--open77-self-test-url=<page>` loads a page in the shipping CEF and reports the PCM it
received, and the run that chose this format reported `packets 335, frames 343040,
peak 0.66` with no user gesture anywhere — so the clips play, and they play without a
click.

The order itself is proven in a browser rather than argued: `ui/harness/
notify-stinger.html` mounts the real page on a fake bridge and a stubbed decoder and
asserts the sequence — the message is not in the document while the opening clip plays,
it appears when that clip ends, it goes when its lifetime ends, and only then does the
closing clip start, with a refused playback still drawing the message.

---

## For creators

A **separate** Open77 resource reaches `opx_infinity` through two doors: exports
(`core/server/exports.lua`, `core/client/exports.lua`, last on each side) and the
public server bus (`opx:on:*`, raised through `OPX.Publish` in
`core/server/publish.lua`). Nothing else is public; `OPX.Api` stays inside this VM.

**Every export answers one table**, `{ ok = true, value = ... }` or
`{ ok = false, error = <code> }`, and never raises. The caller is the name the host
reports (`GetInvokingResource`), never an argument.

```lua
-- server, from another resource: a write goes through the promise form, because
-- a write (and any offline read) may reach the database and the sync proxy fails
-- a callee that yields with `export_yielded`
local pending = Open77.exports.call('opx_infinity', 'AddMoney', playerId, 'EDDIES', 250, 'tip')
local answer = pending and pending:await()
if answer and answer.ok then print('balance', answer.value) end

-- a read of a loaded player answers from memory, so the sync form is fine
local data = exports.opx_infinity:GetPlayerData(playerId)
```

| Server export | Scope |
|---|---|
| `GetVersion()`, `GetPlayerData(src)`, `GetPlayerByCitizenId(cid)`, `IsStaff(src)` | read |
| `GetMoney(src, type?)`, `HasJob(src, name, onDuty?, minGrade?)`, `HasGang(src, name, minGrade?)`, `GetJob(src)`, `GetGang(src)` | read |
| `HasItem(target, item, count?, meta?)`, `CountItem(target, item, meta?)`, `CountInStash(stash, item, meta?)` | read |
| `AddMoney` / `RemoveMoney(src, type, amount, reason?)`, `AddMoneyOffline(cid, type, amount, reason?)` | write |
| `AddItem` / `RemoveItem(target, item, count?, meta?)`, `AddToStash` / `RemoveFromStash(stash, item, count?, meta?)` | write |
| `SendChat(src, msg)`, `BroadcastChat(msg, { bucket?, radius?, origin? })` | write |
| `RevokeKeys(target, plate)`, `RevokeAllKeys(plate)`, `SetVehicleState(plate, 'stored'
| `GetDoor(key)` | read |
| `SetDoorLocked(key, locked)` | write |\|'impounded', garage?)` | write |
| `SetJob` / `SetGang(target, name, grade?)`, `RemoveJob` / `RemoveGang(target, name)`, `SetDuty(src, onDuty)` | write |
| `GetMetadata(src, key?)`, `IsDown(src)` | read |
| `SetMetadata(src, key, value)`, `Revive(src, reason?)` | write |

`target` is a connected player id or a citizen id (an offline bag). **Who may call
is the operator's**: `SERVER.EXPORTS.READ` (`'*'` out of the box) and
`SERVER.EXPORTS.WRITERS` (**empty** out of the box) in `config/server.lua`. A refused
writer is answered `export.callerDenied`, audited, and the journal prints the exact
line that admits it. Every write leaves `event=export.<Name>` naming the caller, and
money reasons are written `ext:<resource>:<reason>` in the money ledger too.

**Jobs and gangs** go through the same functions the staff commands use: the
`job:beforeSet` / `gang:beforeSet` hooks can veto (`job.vetoed`), and a change that
lands raises `opx:on:character:job` / `gang`. Unknown names answer `job.notFound` /
`job.gradeNotFound`, a removal of something not held `job.notMember` /
`gang.notMember`. A citizen id changes a character nobody is playing, holding the
offline ledger so a login racing it cannot save the old job back over it. `SetJob`,
`SetGang`, `RemoveJob` and `RemoveGang` always write a row: **await them** (a sync
call answers `export.mustAwait`). `SetDuty` is for a loaded character only and
answers `job.noDuty` for a job that is on duty by definition.

**Metadata** is the caller's own corner: `SetMetadata(src, 'rep', 3)` from `my_shop`
is stored as `ext.my_shop.rep` and can never reach opx's keys or another
resource's. A key is one segment (`[A-Za-z0-9_-]`, ≤ 48); a value is plain data
(booleans, finite numbers, text, tables of those; `nil` deletes) or
`export.badValue`, and `SERVER.EXPORTS.METADATA` bounds it (4 KB a value, 32 keys,
16 KB a resource per character, else `export.tooLarge`). Loaded characters only;
persisted with the character, and visible to that player's own client like the rest
of PlayerData, so it is not a place for secrets. `GetMetadata(src)` with no key
answers all of the caller's keys.

**Downed**: `IsDown(src)` answers `{ down, waiting, downForMs? }`; `Revive(src,
reason?)` goes through the module's own revive (its `REVIVERS` switch, its gate,
its audit line naming caller and reason) and answers its codes: `not_down`,
`not_incarnated`, `gate_closed`, `caller_denied`.

**Server events** are `(source, payload)` on the host-wide bus (`AddEventHandler`;
`source` is nil for a character who is not online): `opx:on:character:loaded`,
`unloaded`, `money`, `job`, `gang`; `opx:on:inventory:changed`, `used`;
`opx:on:downed:changed`; `opx:on:vehicles:spawned`, `stored`;
`opx:on:dealership:sold`; `opx:on:hauling:sold`; `opx:on:doorlock:changed` (`{ door,
locked, by }`). Payloads are closed copies built
for the bus, never live records — PlayerData's free-form `metadata` is not on it.

**Client exports** draw on the local player's screen: `OpenMenu(spec)`,
`UpdateMenu(handle, spec)`, `CloseMenu(handle)`, `OpenForm(spec)`, `CloseForm(handle)`,
`ShowToast(def)`, `DismissToast(id)`, `StartProgress(spec)`, `StopProgress()`,
`PlayAnimation(name, options?, reply?)`, `StopAnimation()`. A function cannot cross a
resource and the client `TriggerEvent` stays in its own VM, so **answers come back
through an export the caller publishes** — one line turns them into events on its
own bus:

```lua
exports('OnOpxEvent', function(event, payload) TriggerEvent(event, payload) end)
AddEventHandler('opx:on:menu:action', function(p) if p.itemId == 'buy' then ... end end)
```

The events are `opx:on:menu:action`, `opx:on:form:answer`, `opx:on:progress:done` and
`opx:on:animations:result`; a call names another export with `reply`. A caller only
closes what it opened, never takes over another owner's screen, and its screens go
down when it stops. `CLIENT.EXPORTS.CALLERS` in `config/client.lua` narrows who may
draw (`'*'` by default).

**Hearing opx on the client**: `Subscribe(event, reply?)` / `Unsubscribe(event)`
deliver the public client events through the same reply export, as
`OnOpxEvent(event, payload)`: `opx:on:character:loaded`, `unloaded`, `changed`,
`money` (`{ moneyType, amount, action, balance }`), `job`, `gang`;
`opx:on:downed:changed`; `opx:on:inventory:changed`, `used`, `opened`, `closed`;
`opx:on:needs:changed`; `opx:on:progress:state`. Anything else is
`export.notSubscribable`. A character is handed without its `metadata`, and a
caller that stops is unsubscribed.

```lua
exports('OnOpxEvent', function(event, payload) TriggerEvent(event, payload) end)
exports.opx_infinity:Subscribe('opx:on:character:money')
AddEventHandler('opx:on:character:money', function(p) print(p.balance) end)
```

**Not on the surface yet**: a server-started progress bar with an outcome (the
module can start one on a client through `opx:net:progress:start`, but the result
never comes back to the server, and a client-reported result would be the
client's word); metadata of a character nobody is playing (it would need its own
offline row write under the ledger).

Inside the resource the same work gained hooks a module can veto through:
`job:beforeSet` and `gang:beforeSet` (answer `job.vetoed` / `gang.vetoed`) and
`money:beforeAddOffline`.

---

## The library

**`opx_lib` is a separate resource**, declared as a dependency, and reached as
`OPX.Lib` (see `lib/client/lib.lua`). It is **client-only**, and that is not a
choice: the dedicated-server sandbox has no `require`, no `load` and no `loadfile`,
and `LoadResourceFile` refuses a cross-resource read. There is no mechanism by which
a server VM could load a library at all.

So:

- **client code** may use `OPX.Lib.Input`, `.Rpc`, `.World`, `.Zone`, `.Notify`, …
- **server and shared code** use `OPX.Result`, `OPX.Math`, `OPX.Text`, … from
  `lib/shared/`, which is installed into `OPX` by `shared_script`.

New client capability belongs in `opx_lib` by default. `lib/client/` is effectively
closed.

A permission is checked against the **calling** resource's manifest, so `opx_lib`
declares none and could not usefully declare any; `OPX.Lib.Manifest()` prints the
line a consumer needs.

---

## The UI

**Read `ui/README.md` first — it is binding.** augmented-ui is the foundation, not a
decoration, and the contract there explains the parts that will otherwise waste your
afternoon (a cut is required before a border renders; a clip shears an outset
box-shadow; augment containers, not cells).

One page, two layers: `overlay` is a HUD and never takes focus, `modal` does.
`open77_pause` owns Escape — never bind it.

**Pictures ship in `ui/public/images/` and are the game's own.** The build copies
them to `web/images/`, and a page reads them relative to itself (the surface has no
network). The ripperdoc's are one per base-game icon, cut out of the installed
game's own 2.31 item-icon atlases at the rectangle the icon's `UIIcon` record names.
`modules/ripperdoc/shared/cyberware.lua` `ICONS` says which icon each piece uses, and
`PictureOf` the file it ships as: `images/cyberware/<8 hex>.webp`, the FNV-1a of the
icon's name. To cut one again, flip the decoded atlas texture vertically first: the
game stores it bottom row first, and read top-down every rectangle misses its icon.

The ripperdoc screen's own art comes out of the game the same way, and from one
script: `tools/ripperdoc-art.py` cuts the hologram bodies of the base game's
paperdoll (`woman_body` / `man_body`, one picture per body system) and the meters'
backgrounds into `ui/public/images/ripperdoc/`, and the white shapes the screen is
drawn with (tile, tooltip, label, button and tab frames, and the capacity, armor and
eddies icons) into `ui/src/modules/ripperdoc/art/`, where the build inlines them.
Its docstring lists the game files it reads and how to convert them.

**Keep every shipped path short.** A client installs a server's resources 200
characters deep (`<game>\red4ext\plugins\Open77\cache\server-resources\sets\<digest>\
resources\opx_infinity\` on a Steam install in Program Files), and Windows stops at
259: a file whose path in this repository is longer than 59 characters is one the
client cannot see, and it refuses the whole resource (`invalid_web_file:...`, then
back to the server browser). The tests hold every file under `web/`, `core/`,
`modules/`, `lib/`, `config/` and `locales/` to 47.

**Hard-code no colour.** The server's theme (`config/theme.lua`) reaches a page by
writing CSS custom properties onto `:root` at runtime. A literal `#ff3b47` is a
surface the operator cannot recolour. There are two exceptions, both documented in
`ui/README.md`: the join screen (`web/loading.html`) runs before the bundle exists, so
it carries a labelled hand copy of the tokens; and the ripperdoc screen is drawn in the
base game's own colours, read from its inkstyles, because it is the game's screen.

---

## Tests

`tests/run.lua` boots the real manifest against a stub platform in `tests/host.lua`
and asserts behaviour, not implementation. It runs in desktop Lua 5.4 with no game
and no database.

It also enforces things a reviewer would otherwise have to remember: that nothing
shipped reaches a global the sandbox removes, that nothing the **server** loads
reaches a client-only global such as `require`, that no module hangs its internals
off `OPX`, and that the manifest and the tree agree.

Some checks read the **source** rather than call the code. That is deliberate and
used sparingly — for a rule whose two halves are file-local and unreachable from the
harness. When you write one, make it fail on purpose once before you trust it.

---

## Deploying

Over SSH to the test server, then restart, then read the journal back — in the same
change, not later. A green suite says nothing about the running server.

```bash
git archive --format=tar HEAD open77.lua config core lib locales modules web \
  | gzip | ssh root@<host> 'cd /opt/open77-server/resources/opx_infinity && tar xzf - \
  && chown -R open77:open77 . && systemctl restart open77.service'
```

Archive from the **commit**, not the working tree, so what is deployed is what is
recorded. `opx_lib` must be installed and listed in the server's `resources.load`
before `opx_infinity`, or the platform refuses to start this resource.

Never `DROP DATABASE` — the grants live with it and the server authenticates as a
non-root user. Empty tables instead, and `mysqldump` first.

---

## Conventions

Comments carry the **argument**, not a restatement of the code. `-- @author dop42`
on a file header and on a public function. Tabs in Lua, two spaces elsewhere; see
`.editorconfig`.

Prefer a refusal with a named, branchable code over a silent fallback, and prefer
answering a value over raising. Most of this codebase answers `Result` — `{ ok,
value }` or `{ ok, error, detail }` — because a function that legitimately answers
`nil` cannot use Lua's `value, reason` convention without ambiguity.

Never guess a native. Open77's API is not in anybody's training data: look it up with
the devkit MCP, and if it does not return it for the build you target, it does not
exist. The devkit lags the live server, so a miss is "unverified", not "absent" —
say which.
