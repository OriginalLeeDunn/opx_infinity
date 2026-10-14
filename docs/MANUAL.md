# opx_infinity: the developer manual

How the framework is built and why, for people changing it. This was the body of the
repository README until October 2026; the README is now the front page, and the
workflow rules (branches, checks, commit messages, conventions) are in
[`CONTRIBUTING.md`](../CONTRIBUTING.md).

The **documentation site** is the reference for operators and creators — every
module's commands, settings, events and codes, and every export:
<https://opx77-framework.github.io/opx77_doc/>. This manual is the design record
behind it: the platform's two runtimes, the shape of a module, and the reasoning
behind each feature's rules. Code comments that say *see the manual, "Door locks"*
point at a section here by its title. Where this file and the code disagree, the code
wins; fix this file in the same change.

Open77 turns Cyberpunk 2077 into a server-driven multiplayer platform. Gameplay is
Lua, split across a **dedicated server** and a **game client**, and the two runtimes
are not the same — the differences below are not style, they are the platform, and
most of the surprises in this codebase come from one of them.

## Contents

- [Two runtimes, and what only one of them has](#two-runtimes-and-what-only-one-of-them-has)
- [Layout](#layout) — a module, the three event channels, the view seam, how a player opens one
- Features: [the garage key](#the-garage-key-out-and-away), [buying a vehicle](#buying-a-vehicle),
  [four rules the server keeps](#four-rules-the-server-keeps-the-owner-2026-10),
  [vehicle keys](#vehicle-keys), [door locks](#door-locks), [fuel](#fuel), [emotes](#emotes),
  [getting dressed](#getting-dressed)
- Staff: [the grants a staff panel needs](#the-grants-a-staff-panel-needs),
  [what a grant does not imply](#what-a-grant-does-not-imply),
  [the spawn list](#the-staff-panels-spawn-list),
  [a broadcast announcement](#a-broadcast-announcement-and-the-two-clips-around-it)
- [For creators](#for-creators) — exports and the public server bus
- [The library](#the-library), [The UI](#the-ui), [Tests](#tests), [Deploying](#deploying)

---

## Two runtimes, and what only one of them has

| | server | client |
|---|---|---|
| `require` | **no** | yes |
| `load` / `loadfile` / `dofile` | no | no |
| `LoadResourceFile` | own resource only | own resource only |
| instruction budget | none (1,024 task quota) | **per-resume, and an overrun kills the coroutine silently** |

The client budget is the single most expensive thing to forget. A loop without a
`Wait` does not crash, does not log and does not repeat — it stops. `modules/target`
is built in slices for exactly this reason; read its header before writing anything
that walks a list every frame.

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

**One press, one owner.** The host fires every mapping bound to a key from one press,
so a key several features share is *contested*: **E** (garages, dealers, stores,
teleports, lifts, doors) and **X** (progress cancel, call decline / hang-up, crate drop,
emote stop). Each says whether it has something to do right now and at which rank —
`KEY_PRIORITY` in `config/client.lua` — and only the highest acts; at equal rank the
nearer spot does (a garage marker beside a managed door: whichever you stand closer
to). On X a cancelable bar beats a ringing call, which beats a carried crate, which
beats an emote, which beats hanging up a call that is merely going on. Nobody with
anything to do means every handler stays silent. A player who rebinds one of them to
another key takes it out of the contest. `OPX.Spots.Key.Owns` is the rule. A door being
lockpicked holds E against any nearer spot, the key strip draws only the row whose press
would act (`OPX.Spots.Key.Shows`, filed once a scan), and the hotbar peek on **Y** stays
silent while a call rings (Y answers it). **Escape** closes the newest open layer only
(menu, form, panel, door panel, chat, call hologram) and leaves the ones under it.
Toasts read their kind off the refusal: too fast and busy warn, too far and not allowed
are errors (`OPX.Result.Kind`).

### The garage key: out, and away

`garages` is a **place**, like a dealer and a store: stand on the marker, press its
key — **E** by default and rebindable — and it does one of two things. On foot it
opens the garage's list, so the player picks which of their own vehicles comes out AT
the spot; **sitting in one of them, the same key puts it away** (sitting in somebody
else's, it says so and does nothing), filed under the spot the player is standing on, which is
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
necessarily the player who asked. A request that names no place — the contract's
nearby-the-player path, which no client can reach — keeps the old answer: moving a car for
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
price. Every company deposit is written to `opx77_company_pending` under its own token
first and settled at once: the settlement pays in only a row that is still owed and
strikes it off in the same transaction, so a retry, a lost answer or the sweep racing
it can never pay it twice. One that does not settle is not a failed sale and is not
forgotten either: the sweep, at boot and every minute, pays it in.
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

### Four rules the server keeps (the owner, 2026-10)

Decided after the hostile-net-events audit (#99), and each one is a door a client
used to hold.

- **Needs are the server's.** `modules/needs` decays hunger and thirst on the
  server's clock (`DECAY_MS`, each need's `DECAY_PER_MINUTE`) while a character is
  loaded, and a need goes up only when an item's `USE.STATUS` is consumed (the
  inventory adds it on the server, after the unit is gone), through
  `/opx.needs.set <player> <need> <value>` (ACL `command.opx.needs.set`), or through
  the creator exports `AddNeeds` / `SetNeeds`. The client asks for the values once
  and draws every `values` it is sent; there is no push, so a value a client makes
  up has nowhere to land. Nothing happens to a body whose need reaches its MIN.
- **Global chat needs a loaded character.** A slot on the character screen is told
  `chat.notLoaded` and its line goes nowhere. Staff (`STAFF_PERMISSION` in
  `config/chat.lua`, `command.opx.admin` out of the box) may still speak, and the
  console speaks through the `chat` contract and is never asked.
- **A share code is worn in a shop's fitting room, at its prices.** The code form is
  in the room; the server checks the player stands at that shop's counter with that
  shop's priced room open, puts the look on in the room, and the save that leaves
  the room is billed slot by slot by the room's own charge -- the shop's `PRICES`,
  exactly as if the pieces came off its racks. Cancel costs nothing and keeps nothing.
- **A give asks the receiver.** Pressing give raises an offer; the receiver is shown
  the item, the count and where the giver stands (*To your left · 1.2 m*, the #91
  wording -- never a name) with Accept / Refuse, for fifteen seconds. The server holds
  the token, and on a yes checks again that both can act, that they are still in
  reach, that the same stack is still in the giver's slot and that the receiver has
  room. One offer out per giver, one in per receiver, three seconds between two
  offers from one giver. Closing the card is a no.

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

`doorlock` is a faithful port of [ox_doorlock](https://github.com/overextended/ox_doorlock)
to Open77's world doors (**"revoir complètement la feature des doorlock : clone le code,
comprends-le, fais le panel de la même logique"**). A door has ox's fields under ox's
names, it is filed under ox's integer **id**, players turn it by ox's rules, and staff
edit it in a panel built like ox's.

**The door, field by field.**

| ox | here | notes |
|---|---|---|
| `name` | `name` | a nameless door is named after its coords, as in ox |
| `model` + `coords` / `doors[2]` | `native` / `doors = { {native, coords}, {native, coords} }` | a native door is named by its opaque id (`0x` + 16 hex digits), not a model; a double door's `coords` default to the middle of its leaves |
| `state` | `state` | 1 locked, 0 unlocked |
| `maxDistance` | `maxDistance` | measured by the server, clamped to `MAX_REACH`, `SLACK` added |
| `autolock` | `autolock` | seconds, on the server's clock |
| `auto` | `auto` | registered as an automatic door on `open77_doors` |
| `lockpick`, `lockpickDifficulty` | same | a sequence of `'easy'` / `'medium'` / `'hard'` or `{ areaSize, speedMultiplier }` |
| `groups` | `groups` | `{ [job or gang] = min grade }`, any one is enough |
| `items` | `items` | `{ name, metadata?, remove? }`; `metadata` matches the item's metadata **type** |
| `characters` | `characters` | citizen ids |
| `passcode` | `passcode` | never sent to a client or a panel |
| `lockSound` / `unlockSound` | same | Wwise events from `SOUNDS.LIST` |
| `hideUi`, `holdOpen` | same | |
| — | `onDuty` | carried over from the first version: a job group only counts on duty |
| `doorRate` | — | **not here**: Open77's door natives have no speed to set |

**Who may turn it** is ox's `isAuthorised`, in ox's order: staff with the plain ACL
right `opx.doorlock.bypass` when `STAFF_BYPASS` is on (ox's `PlayerAceAuthorised`, off
by default, and not carried by `command.*`, so an admin is asked like anybody) or the ACL entry
`doorlock.<id>` (ox's ace `doorlock.<name>`); a listed **character** opens outright;
else the **groups** decide (through `OPX.JobGate`); else, when no group let them in, an
**item** does; and whoever got that far still types the **code** if the door has one —
so a door with only a code opens for whoever knows it. A door with none of these opens
for staff only. A module of this resource can veto a decision on the hook
`doorlock:authorise` (ox's `doorAuthorization` hook; veto only).

**The server decides.** A client sends a door id and the state it wants; the server
reads the player's position and bucket from the host, the job, gang and grade from the
character contract and the bag from the inventory contract, and only then turns the
lock, arms the autolock, tells the bucket, audits it and publishes
`opx:on:doorlock:changed` (ox's `stateChanged`). ox asks for the code with a callback in
the middle of the request; a server here cannot wait on a client mid-event, so it
answers "the code" and the client sends the request again with it — a guess costs
three seconds. A refusal is a toast naming why.

**At the door** (ox's client): the prompts strip shows *Lock / Unlock {door}* on **E**
at the closest managed door in reach (silent anywhere else: E is shared with the
garages, the stores, the lifts and the teleports); `hideUi` hides the row, not the
lock. The target eye carries *Lock / unlock*, *Pick lock* (a pickable door, one of
`LOCKPICK.ITEMS` in the bag) and, for staff, *Manage door*. The door's sound plays for
everyone within 20 m when its state changes. **A lockpick** is ox's skill-check
sequence played as one `progress` bar per step: the server sends the steps, times the
whole sequence (a "done" that arrives early is refused and audited), rolls every step
itself at its `CHANCE`, and breaks the pick 1 in 100 on a success and 1 in 5 on a
failure, as ox does. A client deciding its own skill check is a client that always
succeeds, which is why the ring itself is not ported.

**Two backends** (`BACKEND` in `config/doorlock.lua`), both from the first version:

- **networked** — the platform's `open77_doors`. Each leaf is `register`ed to this
  resource and `configure`d in one atomic patch: its lock and, for `holdOpen`, open with
  its self-closing off (and an automatic door taken off proximity) while unlocked. The
  platform's own authority then refuses a locked door to everybody. A sweep re-adopts a
  door the service forgot after a restart.
- **local** — no platform service. The server broadcasts the state per routing bucket;
  every client puts its streamed managed doors into it with `Open77.doors.setLocked`,
  refuses vanilla interaction on a locked one (`setInteractionAllowed`) and, for
  `holdOpen`, opens it with `setAutomaticClose(false)`. **This is what the test server
  runs today**, because `open77_doors` depends on `open77_elevators`, which would take
  the cabins away from the job-gated `elevators` module. It is the weaker promise — a
  modified client can open its own copy of a door.

**Where a door lives.** Every door is a row of `opx77_doorlocks` (ox's table: id, name,
the door as one JSON column). `DOORS` in `config/doorlock.lua` is ox's `convert/`
folder: each block is inserted once under `config:<key>`, and the panel owns the door
from then on; deleting a seeded door leaves a tombstone so the next boot does not put it
back. **The first version's doors are carried over**, not lost: every row of
`opx77_doorlock` is inserted once under `legacy:<key>` (groups into ox's map, `locked`
into `state`, a BOUND key item into a `metadata` match on the old key — and a key that
version cut, `door = <key>`, keeps opening its door). That table is never written
again; drop it by hand once the doors are checked. A seeded or carried-over door also
answers to its old key in every export and command.

**The staff panel** is a Vue view of its own (`ui/src/modules/doorlock`, on the `modal`
layer), opened by `/opx.doorlock` (ox's `/doorlock`; `/opx.doorlock closest` opens the
closest door's settings), the F9 *World → Door locks* row, or the eye's *Manage door*
(the door's settings when it is managed, a new door with that leaf taken when it is
not). It is ox's web UI on the design system:

- **the table** — id, name, state, distance from the player; search, sortable columns,
  pages; per row *Settings*, *Copy settings*, *Lock / Unlock now*, *Teleport to door*
  (the staff module's `opx.admin.player.tp`) and *Delete door* (with ox's confirm);
  **+** starts a new door.
- **the settings form** — ox's tabs: *General* (name, passcode — never shown, kept when
  left empty, cleared on request —, autolock, interact distance, the switches locked /
  double / automatic / lockpick / hide UI / hold open / on duty, and the door itself
  with **Pick in world**), *Characters*, *Groups* (group + grade rows), *Items* (item,
  metadata type, remove on use), *Lockpick* (one difficulty per row, a custom row taking
  area size and speed multiplier; no row means `LOCKPICK.DEFAULT`), *Sound*; and ox's
  submit bar: *Confirm door*, copy / apply copied settings, *Give me a key*, delete.
- **Pick in world** is ox's targeting step: the panel hides and gives the controls back,
  the strip says *Aim at door 1/2*, **E** takes the door under the crosshair
  (`Open77.doors.aimed`) — twice for a double door, never a leaf another door manages,
  never a lift door — and Escape gives up. *Confirm door* on a door with no leaf yet
  starts the same step and saves when it ends, ox's order.

Every write is a net event the server gates on its own grant, floors per player,
re-validates field by field (a group nobody defined, an item the catalogue does not
know, a leaf another door holds, a new or moved door far from where staff stand are all
refused) and audits:

| ACL entry | what it opens |
|---|---|
| `command.opx.doorlock` | the panel, the list, the eye's *Manage door* row |
| `command.opx.doorlock.save` | create and edit (the panel's Confirm) |
| `command.opx.doorlock.remove` / `.lock` / `.key` | delete, lock / unlock from anywhere, cut a key — in the panel and as commands |
| `command.opx.doorlock.list` | `/opx.doorlock.list [door]` |
| `opx.doorlock.bypass` | turning any door without a key or a code, only when `STAFF_BYPASS` is on (a plain right, not under `command.*`) |
| `command.opx.admin.player.tp` | the panel's *Teleport to door* |

So an operator role needs `command.opx.doorlock` **and** `command.opx.doorlock.*`.
Audit events: `doorlock.create`, `.edit`, `.remove`, `.lock`, `.unlock`, `.key`;
refusals are `doorlock.staffDenied`, `doorlock.passcode` and `doorlock.pickEarly`
security lines. `/opx.doorlock.key <door> [player]` cuts the door's first item that
carries `metadata`, with `{ type = <metadata>, label = <door name> }`.

**The client budget.** Nothing here walks every door in one resume: a sync arrives in
chunks of twelve and is filed as it comes, the closest-door scan measures a slice of
the bucket per pass (ox's `nearbyDoors`), and the panel's rows are built on a thread of
their own that yields every 25 rows. `OPX_BUDGET_METER=1000 lua tests/run.lua` puts
every doorlock call site under 5,000 instructions.

**ox's exports** are the creator exports `GetDoor(id)`, `GetDoorFromName(name)`,
`GetAllDoors()`, `SetDoorState(id, state)`, `CreateDoor(data)`, `EditDoor(id, data)`,
`RemoveDoor(id)` (and the first version's `SetDoorLocked(id, locked)`), with ox's
meaning; see "For creators". None of them ever carries a code.

**Not here, deliberately:** ox's `doorRate` (no native speed), its NUI audio files
(sounds are Wwise events, `SOUNDS.LIST` ships empty), its zone column (Night City has no
district name a script can read) and the platform's force / pay / hack door actions
(not declared: a locked managed door refuses them).

### Fuel

`fuel` is a port of [ox_fuel](https://github.com/overextended/ox_fuel) onto Open77's
fuel bag field (**"clone ox_fuel, comprends-le, comprends comment l'adapter comme on a
fait avec ox_doorlock, puis implémente-le"**). Like the door locks, it keeps ox's
logic and ox's names where they still mean something, puts them on this platform's
natives, and says plainly what does not carry over.

**Cyberpunk has no fuel.** REDengine 2.31 has no fuel level, no consumption rate and
no petrol tank, so FiveM's `GetVehicleFuelLevel` / `SetVehicleFuelLevel` have nothing
to map to (devkit `vehicles#what-cyberpunk-does-not-have`). The tank is a field of the
vehicle's replicated state bag, **`fuel`, in litres**: the field and unit the
platform's own sample `open77_fuel` uses (`state-bags#the-fuel-sample-open77fuel`), so a
resource written for either one reads the other's tank. `fuelCapacity` sits beside it
so a gauge can draw a percentage. ox keeps a percentage in `state.fuel`; every ox-facing
export here (`GetFuel`, `SetFuel`) answers and takes a percentage.

| ox_fuel | here | notes |
|---|---|---|
| `Entity(veh).state.fuel` (0..100) | bag `fuel` (litres) + `fuelCapacity` | the platform's field, shared with `open77_fuel` |
| GTA's own burn, read by the driver's client once a second and pushed with `ox_fuel:setFuel` | the **server** burns every canonical vehicle each `CONSUMPTION.TICK_MS` (`server/tanks.lua`) | from the replicated speed AND the distance the server saw it move, whichever is more |
| `globalFuelConsumptionRate` | `CONSUMPTION.MULTIPLIER` | over `open77_fuel`'s `LITRES_PER_100KM` and `IDLE_LITRES_PER_MINUTE` |
| `classUsage` / `DoesVehicleUseFuel` | `CONSUMPTION.CLASSES` by TweakDB record (`v_sport2_`, `_sportbike`...); `USAGE = 0` takes no fuel | AVs are 0: cutting an engine in the air is a crash |
| GTA's RPM-driven rate | `CONSUMPTION.SPEED_CURVE` on road speed | the server snapshot carries speed, not RPM (client telemetry is not billed) |
| `GetVehiclePetrolTankHealth < 700` leak | `CONSUMPTION.LEAK` below a health share | one health pool in Cyberpunk |
| empty tank: GTA will not start the car | `Open77.vehicles.setEngine(id, false)`, again every tick it is found running | `open77_fuel`'s behaviour; announced once as `reason = 'empty'` |
| `data/stations.lua` (Los Santos) | `STATIONS` in `config/fuel.lua` | Night City places, **placeholders disabled until surveyed** |
| `pumpModels` + ox_target `addModel` | a surveyed position per pump, an eye sphere round it | a Night City pump has no entity to aim at |
| `startfueling` on E, `fuelHelpText` | E (`KEY`, shared-key rules) and the strip row, silent away from a pump | |
| `refillValue` / `refillTick` | `REFILL.LITRES_PER_SECOND` / `REFILL.TICK_MS` | 1.2 L/s: ox's 50 s for an empty tank |
| `priceTick` | `PRICE_PER_LITRE` (a station may name its own `PRICE`) | per litre, rounded up: no free drop |
| cash via ox_inventory, `setPaymentMethod` | the pump asks: cash (`EDDIES`) or bank (`BANK`), `PAYMENT` | charged through the character contract |
| `lib.progressCircle` + `ox_fuel:pay(price, fuel)` | a `progress` bar the **server** starts and times; it bills what its own clock poured | ox believed the client's price and level |
| `lib.cancelProgress` on `price + priceTick >= money` | the server stops the pour when the money, the player or the car moves | |
| `WEAPON_PETROLCAN` (`durability`/`ammo`) | item `petrolcan`, `metadata.durability` = fill 0..100, drawn as the wear bar | Cyberpunk has no can to hold |
| `petrolCan.duration/price/refillPrice` | `CAN.DURATION_MS/PRICE/REFILL_PRICE` | |
| `ox_fuel:updateFuelCan(durability)` | a can pour is the same server session, draining the can it came from | |
| `showBlips` 0/1/2 | the `fuel` category in `config/blips.lua` (`SHOW`, `RANGE`) | no fuel sprite exists in 2.31; `drop_point` |
| `versionCheck`, `ox_target` switch | — | both doors are always on |

**A refuel is a server session.** The client sends what the player chose and how they
pay (`{ method }`), nothing else. The server finds the pump nearest to where the host
says the player stands, the nearest canonical vehicle in `VEHICLE_REACH` of them (on
foot: from a seat it answers ox's *Leave the vehicle*), the room in the tank and what the
chosen account can pay for, then starts a cancelable `progress` bar for those litres.
Every `REFILL.TICK_MS` it moves the gauge and checks the session: the player still at the
pump, the car still where it stood (`MOVE_TOLERANCE`, `STOP_SPEED`), the money still
there. However the bar ends -- run out, cancelled, stopped, a "finished" sent early (the
progress module refuses it), the player gone -- the litres billed are the ones the
server's clock poured: **a cancelled bar is a partial refuel**, as in ox. A charge the
account can no longer cover pours only what it can; a player who disconnects mid-pour
gets nothing and pays nothing.

**The can** is bought or refilled at a pump behind a `CAN.DURATION_MS` bar, charged
after the bar (refunded if the bag refuses it), and poured anywhere: used from the bag
(nearest vehicle in `CAN.REACH`) or from the eye's *Refuel with the fuel can* row on a
vehicle. The pour drains the can in the slot it came from; a can moved out of that slot
mid-pour pours nothing.

**`open77_fuel` running too.** Two burns would empty a tank twice as fast, so with
`STAND_DOWN` on (the default) this module stops burning and cutting while
`open77_fuel` runs, writes every refuel through its `set` export (the bag when the
export is not there) and reads its `capacity()`. Stations, cans, persistence and the
gauge keep working. Asked every ten seconds, so a start or stop of either is noticed.

**Persistence.** An owned car keeps its tank through a garage: `opx77_vehicles` gained
a `fuel` column (FLOAT NULL, added by `OPX.Schema.AddColumns`), written with health and
damage whenever `vehicles` saves or puts a car away (and at stop), and put back on the
bag the moment it comes out, before anything yields. NULL is a car never measured
(bought before the column existed): it comes out at `INITIAL_PERCENT`. The bag is read
as the platform's field, so a server running `open77_fuel` without this module still
keeps its tanks.

**The gauge.** The vehicle dial (`modules/hud`, `HudVehicle.vue`) draws *FUEL* and a
hairline gauge under the speed when the car has a tank, toned at `TONE_WARN` /
`TONE_BAD`; `VEHICLE.FUEL = false` in `config/hud.lua` leaves it off. It reads the bag
through the client contract (`Level`, `Percent`, `Current`), which never writes.

**Stations.** ox's are Los Santos. Night City's (Sunset Motel, Rocky Ridge, Arroyo,
Northside, Wellsprings) ship as **placeholders with no coordinates and are disabled at
boot** with a journal line naming them -- no blip, no row, no key -- until surveyed: stand
on the forecourt and run `/opx.fuel.capture <key> [label]`, then at each pump
`/opx.fuel.capture <key> pump`; each prints the line to paste into `STATIONS`. Nothing is
stored in the database: the file is the city. A station with one unsurveyed pump stays
disabled whole.

| ACL entry | what it opens |
|---|---|
| `command.opx.fuel.set` | `/opx.fuel.set <vehicleId\|near> <0-100>` -- `near` is the seat, else the nearest car in `STAFF_REACH`; a typed id must be in reach unless the operator holds `opx.admin.vehicle.anywhere` |
| `command.opx.fuel.capture` | `/opx.fuel.capture <station> [pump\|label]` |
| `command.opx.fuel.stations` | `/opx.fuel.stations`: open, unsurveyed and refused stations, and who is burning |

So an operator role needs `command.opx.fuel.*`. Audit events: `fuel.refuel`, `fuel.can`,
`fuel.buy`, `fuel.refill`, `fuel.set`, `fuel.capture`.

**The client budget.** The scan measures 32 pumps a pass and keeps the near ones; the
stations are coerced one a resume and the pump spheres registered four to an eye row,
one row a resume. `tests/run.lua` holds a scan over 96 pumps under 3,000 instructions
and the whole boot with them under 4,500 a resume.

**Not here, deliberately:** ox's `setPaymentMethod` / `setMoneyCheck` (a function cannot
cross a resource; the pump offers both accounts), the nozzle prop and the gardener
animation (no such assets; `ANIMATION` takes a progress animation name), RPM-based
consumption (no RPM on the server), and real station coordinates (unsurveyed -- see
above). Needs in-game checking: the engine cut against a driver restarting, the eye
spheres on real pumps, the `drop_point` sprite on the big map.

### Emotes

`animations` offers **every animation the platform has** (**"toutes les animations,
même les shared etc., toutes sans exception"**): **F3** opens the picker, **X** stops,
`/e <name> [variant]` plays, `/e list` lists them, `/e <family>` opens the picker there.

**Alone: the whole RP catalogue, read, not copied.** The server reads
`Open77.animations.list()` once the API is up (104 profiles in twelve families on
op77.123) and offers every profile beside the fifteen rows written in
`shared/catalogue.lua`; a written row wins over the platform's profile of the same id
(it carries a walking pace and a curated variant list). A profile a later build adds is
offered at the next start, labelled with the platform's English until it is given a row
in `locales.lua`. Every one plays through `Open77.animations.play` with the clip of the
variant chosen; a one-shot gesture (`wave`, `shrug`…) plays once, for its measured clip.
The platform's families map onto the picker's — `seated` is **Sitting**, `dance` and
`music` are **Dance and music** (`/e dance` is the emote, not the family), a family this
build has never heard of is **More**. Skipped, and counted in one boot line: a profile in
`DISABLED`, one whose `validation` says it failed, a malformed row.

**With a nearby player: everything the coordinator plays.** Through
`Open77.playerInteractions` (open77_player_interactions, `players.interactions.control`):

| what | how it is asked for | the coordinator |
|---|---|---|
| carry them / be carried | **With a nearby player** › paired moves, `/e with carry`, `/e with carried` | kind `carry`, fixed paired presentation; the carrier walks |
| escort them / be escorted | `/e with escort`, `/e with escorted` | kind `escort`, side by side, walking |
| hand something over | `/e with give` | kind `give` |
| look after them / be looked after | `/e with heal`, `/e with healed` | kind `heal` (examine / wounded) |
| any two profiles | **Any two animations** › yours › theirs (“the same” on top), `/e with <yours> [theirs]` | kind `custom`, `actorAnimation` / `targetAnimation` |
| a named shortcut | `SHARED.PAIRS` rows | kind `custom` |

So every ordered pair of offered profiles is reachable — 104 × 104 on op77.123 — two
screens and a page away, not ten thousand rows. The **nearest** player within
`SHARED.RANGE` (3 m) is invited — the server picks, from positions it observes, and
measures again at the yes — and nothing plays until they accept, from a two-row menu or
`/e accept` / `/e decline`; an unanswered invitation is withdrawn after `INVITE_MS`. The
coordinator is then called with `consent = false`, the case its guide names for consent
already taken. An invitation spends from the same rate window as a play, and the stop key
ends a pair for both.

**What the platform cannot do.** A `custom` pair is stationary: either body walking off
ends it, including a walking layer (`smoke_walk`…) — only `carry` and `escort` move, and
those two take no profile override (`paired_animation_fixed`). The coordinator plays a
profile, not a clip, so a pair has no variant. There is no third body: two players, one
interaction each.

**The budget.** A hundred-odd definitions are taken in on a client thread that yields
by clip count, the offer reaches the client in parts under the 1,024-value decoder, and
the picker builds each screen on its own thread, sixteen emotes to a page, handing it to
the menu with `yield = true`. `tests/run.lua` holds each to 4,000 instructions a resume
and shows the same work done in one go overruns it.

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
`command.opx.doorlock` and `command.opx.doorlock.*` for the door panel,
`command.opx.fuel.*` for the fuel commands, and
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

### What a grant does not imply

Three raw ACL rights sit beside the `command.` ones. They are not commands, so
`command.*` (the server's `admin` role) grants none of them and `*` (`owner`) grants all:

| ACL right | what it does |
|---|---|
| `opx.admin.immune` | shields the player from every harmful staff action — kick, ban, kill, health, armour, freeze, model, bring, send, teleport, observe, wardrobe, holster, stripping their bag or weapons, renaming or deleting the character they play. The operator is answered *protected* (`target_protected`) and the attempt is audited. The console is never stopped, and nobody is stopped acting on themselves. |
| `opx.admin.override` | acts on an immune player anyway |
| `opx.admin.vehicle.anywhere` | the vehicle commands that take a typed id act on any live vehicle; without it the vehicle must carry the operator or sit in their instance within `VEHICLES.REACH` (100 m) — `vehicle_out_of_reach` otherwise |

And three command grants no longer reach past their name:

- **A bag command on a weapon item also needs the weapon command.** `inventory.give` of a
  weapon needs `weapon.give`, of rounds `weapon.giveammo`; `inventory.remove` of a weapon
  needs `weapon.remove`, of rounds `weapon.ammo`; `inventory.clear` checks every weapon and
  round in the bag the same way and clears nothing if one is refused
  (`weapon_not_granted`).
- **`player.observe` is spectating, not flight.** It still lifts the operator over the
  target with noclip and a hidden body, but without `self.noclip` that ends after
  `PLACEMENT.OBSERVE_MS` (two minutes) and the operator is told so.
- **One heavy request in flight per operator.** Every bag, weapon and character command,
  and every list the menu reads, runs on that operator's single worker: a typed command
  that arrives while one runs is answered *busy*, and a menu list waits its turn — the
  server's 1,024-task quota is no longer one operator's to spend.

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
| `RevokeKeys(target, plate)`, `RevokeAllKeys(plate)`, `SetVehicleState(plate, 'stored'\|'impounded', garage?)` | write |
| `GetDoor(id)`, `GetDoorFromName(name)`, `GetAllDoors()` (ox_doorlock's) | read |
| `SetDoorState(id, state)`, `SetDoorLocked(id, locked)`, `CreateDoor(data)`, `EditDoor(id, data)`, `RemoveDoor(id)` (ox_doorlock's) | write |
| `GetFuel(vehicleId)` (ox's `state.fuel`, in percent), `GetFuelState(vehicleId)` (`{ litres, capacity, percent, usesFuel }`) | read |
| `SetFuel(vehicleId, percent)` (ox's `state:set('fuel', ...)`) | write |
| `SetJob` / `SetGang(target, name, grade?)`, `RemoveJob` / `RemoveGang(target, name)`, `SetDuty(src, onDuty)` | write |
| `GetMetadata(target, key?)`, `IsDown(src)` | read |
| `SetMetadata(target, key, value)`, `Revive(src, reason?)` | write |
| `GetPlayers(filter?)`, `GetJobs()`, `GetGangs()` | read |
| `GetItem(name)`, `GetItems()`, `GetInventory(target)`, `CanCarryItem(target, item, count?, meta?)` | read |
| `RegisterItem(name, def)`, `RegisterUsableItem(name, export)`, `UnregisterUsableItem(name)`, `OpenStash(src, name, options?)` | write |
| `GetVehicle(plate)`, `GetOwnedVehicles(target)`, `HasKeys(target, plate)` | read |
| `AddVehicle(target, record, { garage? })`, `GiveKeys(target, plate, model?)` | write |
| `Notify(src, msg, kind?, ms?)`, `StartProgress(src, spec)`, `StopProgress(src, id?)` | write |
| `RegisterCraftingBench(key, def)`, `UnregisterCraftingBench(key)` | write |

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
16 KB a resource per character, else `export.tooLarge`). Persisted with the
character, and visible to that player's own client like the rest of PlayerData, so
it is not a place for secrets. `GetMetadata(src)` with no key answers all of the
caller's keys. A **citizen id** reaches a character nobody is playing: one key of
the row is written (`JSON_SET` / `JSON_REMOVE` on a quoted path) under the offline
ledger the money and group writes hold, the bounds checked against the row as it
stands at the write; it reads the database, so await it.

**The roster and the catalogue**: `GetPlayers({ job?, gang?, onDuty? })` answers
roster rows (`source`, `citizenId`, names, `job`, `gang` -- no money, no metadata);
`GetJobs()` / `GetGangs()` answer the configured groups with their grades as a list
(`{ level, name, payment, isBoss }`). `GetItem` / `GetItems` answer catalogue
entries as a screen reads them, `GetInventory(target)` a whole bag.

**Runtime items**: `RegisterItem('my_burger', { label, description?, weight?,
stack?, drop?, category?, image?, model?, use? = { consume?, close?, status? (at
most 8 needs), animation? } })` adds an item to the catalogue on both halves while the server runs
(`modules/inventory/shared/catalog.lua`, `Catalog.Register`, the one validator both
halves run; clients that join later get the list on their hello). Never a weapon or
ammo, never a name config or another resource holds (`item_taken`), at most
`SERVER.EXPORTS.ITEMS.MAX_PER_CALLER` per caller (`item_cap`), refused whole on the
first bad field (`bad_definition:<field>`). Its owner may register it again, which
replaces it. It is not persisted and not removed when its owner stops (stacks of it
are in bags). `RegisterUsableItem(name, 'UseBurger')` makes the caller's export the
item's use: the inventory holds the slot and calls `UseBurger(source, { name, slot,
count, metadata, label, citizenId })`, which answers `{ ok = true, consume? }` or
`{ ok = false, error }` inside the handler deadline. An item another owner handles
is `export.usableTaken`; the handler goes when the caller stops.

**Stashes, vehicles and keys**: `OpenStash(src, name, options?)` opens a stash
beside the player's bag (ox's `forceOpenInventory`), only a configured stash or one
in the caller's `<resource>.` namespace (`stash_namespace`, `stash_cap`).
`GetVehicle(plate)` and `GetOwnedVehicles(target)` answer `{ plate, citizenId,
record, garage, state = 'stored'|'out'|'impounded', health, spawned }`;
`AddVehicle(target, record, { garage? })` makes a vehicle row through the module
(`PER_CHARACTER` holds); `HasKeys` / `GiveKeys` read and cut a key.

**A bar the server judges**: `StartProgress(src, { label, durationMs, cancelable?,
animation? })` answers the bar's `id`; the client draws it and reports how it ended,
and the server decides by its own clock (`modules/progress/server/main.lua`): a
`finished` sooner than the duration is `rejected` and goes to the security journal,
no report by the duration plus 5 s is `no_answer`, a player leaving is `left`. The
verdict is `opx:on:progress:finished` (`{ id, owner, ending, completed, elapsedMs }`).

**Crafting benches**: `RegisterCraftingBench('counter', { label, position?, reach?,
queue?, recipes, jobs? = { ncpd = 0 }, onDuty? })` registers a bench under
`<caller>:counter` on the crafting module's own rules; the gate is a job list,
because a function cannot cross. A player opens it with the client export
`OpenCraftingBench('counter')`. It goes when the caller stops.

**Needs**: `GetNeeds(src)` answers `{ values, citizenId }`; `AddNeeds(src, { hunger =
10 })` and `SetNeeds(src, patch)` (WRITERS) move them on the server, clamped to
`config/needs.lua`, and the client and `opx:on:needs:changed` are told the move came
from `ext:<caller>`. The server owns every need: the client draws what it is sent.

**Downed**: `IsDown(src)` answers `{ down, waiting, downForMs? }`; `Revive(src,
reason?)` goes through the module's own revive (its `REVIVERS` switch, its gate,
its audit line naming caller and reason) and answers its codes: `not_down`,
`not_incarnated`, `gate_closed`, `caller_denied`.

**Server events** are `(source, payload)` on the host-wide bus (`AddEventHandler`;
`source` is nil for a character who is not online): `opx:on:character:loaded`,
`unloaded`, `money`, `job`, `gang`; `opx:on:inventory:changed`, `used`;
`opx:on:downed:changed`; `opx:on:needs:changed` (`{ citizenId, values, changed,
source }`, `source` naming what moved them: `decay`, `use`, `staff`, `ext:<caller>`);
`opx:on:vehicles:spawned`, `stored`;
`opx:on:dealership:sold`; `opx:on:hauling:sold`; `opx:on:doorlock:changed` (`{ id,
name, state, locked, by, item }`); `opx:on:fuel:changed` (`{ vehicleId, vehicleKey,
litres, previous, percent, capacity, reason }`, `reason` one of `refuel`, `can`, `staff`,
`empty`, `ext:<caller>` -- driving is not announced, the bag already is); `opx:on:character:created` / `deleted`;
`opx:on:inventory:items` (`{ citizenId, changes = { { name, delta, count } } }`,
what a bag gained and lost by item name); `opx:on:vehicles:registered` / `state`
(an impound); `opx:on:crafting:ordered` / `collected`; `opx:on:progress:finished`.
Payloads are closed copies built
for the bus, never live records — PlayerData's free-form `metadata` is not on it.

**Client exports** draw on the local player's screen: `OpenMenu(spec)`,
`UpdateMenu(handle, spec)`, `CloseMenu(handle)`, `OpenForm(spec)`, `CloseForm(handle)`,
`ShowToast(def)`, `DismissToast(id)`, `StartProgress(spec)`, `StopProgress()`,
`PlayAnimation(name, options?, reply?)`, `StopAnimation()`, `OpenPanel(spec)`,
`UpdatePanel` / `AppendPanel` / `ClosePanel(handle, ...)`, `AddTarget(kind, rows,
where?)`, `UpdateTarget(token, patch)`, `RemoveTarget(tokens)`, `ClearTargets()`,
`ShowPrompt(id, spec)`, `UpdatePrompt` / `HidePrompt(id)`, `HideAllPrompts()`,
`OpenCraftingBench(key)`, and the reads `GetPlayerData()`, `GetItemCount(name)`,
`HasItem(name, count?)`, `GetItem(name)`, `IsDown()`, `GetNeeds()`. A function cannot cross a
resource and the client `TriggerEvent` stays in its own VM, so **answers come back
through an export the caller publishes** — one line turns them into events on its
own bus:

```lua
exports('OnOpxEvent', function(event, payload) TriggerEvent(event, payload) end)
AddEventHandler('opx:on:menu:action', function(p) if p.itemId == 'buy' then ... end end)
```

The events are `opx:on:menu:action`, `opx:on:form:answer`, `opx:on:panel:action`,
`opx:on:progress:done` and `opx:on:animations:result`; a call names another export
with `reply`. **Eye rows** are owned under the caller's resource name, and every
callback (`onSelect`, `canInteract`, `checked`) is an export NAME of the caller's --
a `{ resource, export }` naming anybody else is refused; the eye asks them in slices
over export calls, never inside one resume. A caller named like a module of this
runtime is refused the eye and the strip (`export.ownerTaken`). A caller only
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

**Not on the surface yet**: hooks from another resource (a veto has to answer
inside the action, synchronously, and a cross-resource call cannot be bounded
there); an impound or garage screen opened for a player; a job gate on a garage;
an item shop (the `shops` module is the clothing shop) or a gunsmith of a
creator's own beyond a crafting bench. A request/answer helper between a client
and the server is `Lib.Callback` in `opx_lib` over `Open77.net`, not an export.

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

**Read `ui/README.md` first — it is binding.** Every chamfer is drawn by
`ui/src/design-system/shapes.css`, which speaks augmented-ui's vocabulary (the
`data-augmented-ui` attribute, `--aug-*` variables) without the library, and the build
refuses any shape token it doesn't draw. The contract there explains the parts that will
otherwise waste your afternoon (a cut is required before a border renders; a clip shears
an outset box-shadow; shape containers, not cells).

One page, two layers: `overlay` is a HUD and never takes focus, `modal` does.
`open77_pause` owns Escape — never bind it.

**Hard-code no colour.** The server's theme (`config/theme.lua`) reaches a page by
writing CSS custom properties onto `:root` at runtime. A literal `#ff3b47` is a
surface the operator cannot recolour. The join screen (`web/loading.html`) is the one
exception and it is documented in place: it runs before the bundle exists, so it
carries a labelled hand copy of the tokens.

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

