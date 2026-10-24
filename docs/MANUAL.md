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

The October 2026 capability review queried all 101 Devkit namespaces for
`2.31.21+op77.147`: 1,753 client/server catalogue entries, including aliases and
the same function on both sides; 158 are marked unavailable by the catalogue.
Catalogue presence alone is not runtime availability. In particular the cards
for `remoteCamera`, `media` and `consumables` are currently marked unpublished.
The devblog nevertheless describes shipped camera-driven surfaces and shared
screens: this is a catalogue/announcement discrepancy, not proof that the engine
cannot render screens. Resolve exact API/build support before integrating it. Ordinary
`camera` views, server-owned NPCs and tasks, vehicle AI, props, animations,
cyberware and player-to-player hacking provide the available building blocks.
`hacking.start` does not hack arbitrary world devices. Client raycasts and
nearby-world observations cannot alone authorise inventory or money rewards.
Check the deployed build and test navigation, streaming and authored assets in
game before enabling new mission content.

For future Night City activities, prioritise sealed shard delivery, maintenance
of registered relays, salvage of corporate components, and contact extractions.
Use inventory/progress/contracts for proof and payout rather than client-reported
completion. NPC tasks and vehicle AI can support escorts and convoys, subject to
an explicit per-module entity cap. Keep faction rank (permissions), street cred,
corporate reputation and any future fixer trust separate. Existing gang HR and
treasuries already live in business; extend their contracts instead of creating
a second membership registry. Survey the existing underworld labs, fences,
fronts and robbery sites before adding another set of unplaced activities.

### Current job interaction review (op77.147 catalogue)

Prefer actions that represent what the worker actually does. The first implemented
pass uses the existing synchronized animation contract and its installed catalogue:

| Activity | Current implementation | Next useful improvement / prerequisite |
| --- | --- | --- |
| Mechanic | `mechanic` workshop pose, `repair` roadside pose; canonical diagnosis; explicit replicated hood controls in a bay | Check tool placement and hood support on each vehicle body in game |
| Netrunner | `tablet2` during breach and daemon work, `phone` fallback; server-authorized node effects | Place real access points before adding terminal-specific anchored poses |
| Courier | `give` at the validated delivery point, tagged inventory proof | Survey contacts before attaching a two-player handover to the route |
| Relay technician | `repair` while replacing a module, server-timed consumption and reward | Survey actual terminal height before introducing welding or keyboard workspots |
| Bartender / street food | Existing consented serving and stash recipes; food uses `takeout` with `drink` fallback | Place counters; measure cooking/shaker profiles against that surface rather than kneeling at a bar |
| Medical / Trauma | Existing consented heal/carry, bed placement and held medical tools | Validate bed anchors and injector grips; preserve patient consent and current health checks |
| Ripperdoc | Existing operations, native cyberware requests and durable receipts | Survey operating stations and validate patient presentation before adding a surgical sequence |
| Hauling / Nomad | Existing synchronized crate poses and prop ownership; jump restriction during carry | Verify pickup/putdown offsets, then introduce bounded convoy NPCs on surveyed routes |
| Gunsmith | Existing gated crafting benches and material escrow | Survey bench heights before adding anchored assembly; crafting orders can continue while the player leaves |
| Taxi | Existing server-metered trips and billing | Add surveyed passenger routes only after NPC boarding/navigation validation |
| Fuel | Existing server-timed pouring and billing | Measure jerrycan/nozzle attachment and hose reach; no guessed pump animation |
| NCPD / MaxTac | Existing cuff/escort and vehicle interactions | Validate paired arrest placement and vehicle seats; never replace consent rules with a cosmetic pose |
| Corpo / Fixer | Existing assignments, reputation and bounded job/gang gig gates | Survey contacts, terminals and VIP routes; do not create a second reward ledger |
| Media | Existing reporting/publishing module | Reconcile unpublished MCP camera/media cards with the deployed build before adding camera-driven screens |

A progress gesture may now specify `{ name = 'repair', fallback = 'examine' }`.
The client asks `animations.Get` against its offered catalogue before starting a
preferred pose; a missing/disabled preferred profile uses the fallback with no
inherited variant number. A refusal leaves the timed action usable. Only the
progress owner stops the gesture, on completion or cancellation. The server
validates both profile identifiers (1..32 word characters) before forwarding.
Inventory definitions accept the same `use.animation.fallback` field, or
`USE.ANIMATION.FALLBACK` in static item data. Food and bar recipes choose the
documented `takeout` meal profile rather than pretending the drink pose is the
only hand-to-mouth animation. Presentation still needs an in-game body/asset check.

Authored walking/running styles are a separate opportunity: Open77's locomotion
guide requires matching client/server op77.145+ plus a resource-authored graph
and compiled native assets; expanded collections require Stable 147 / protocol
1.48. The existing `WALK_PACES` only requests speed leases. It cannot install a
limp or a corporate swagger by adding a style name. Build and visually validate
a locomotion package before assigning medical or faction-specific movement.

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
charge, ownership row and any seller/company payout obligations share one SQL transaction. A
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

### Down, wounded, and dead

`modules/downed` + `config/downed.lua`. `MODE = 'death'` ships: a lethal hit kills and the
down screen opens on the dead body. With `MODE = 'wounded'` (off by default) the server's
damage arbiter (`Open77.combat.onDamage`) holds a hit that would kill a player with a
character loaded at `WOUNDED.HEALTH`: the player goes down **alive** -- frozen where they
fell, regeneration off, the `WOUNDED.POSE` workspot -- and every hit they deal is refused.
They **flatline** (the dead stage, the screen as before) on a finishing blow
`WOUNDED.FINISH` allows (players yes, NPCs and the world no, by default), when
`BLEED_OUT_S` runs out, or from any death that went round the arbiter. A revive of a
wounded body is a heal past the floor; GIVE UP teleports and patches instead of
respawning the living, behind a fade (`FADE`).

Contract `downed` (server): `IsDown(id)` and `List()` carry `stage` (`wounded` / `dead`),
`Revive(id, caller, why, { health?, graceMs? })`, `SetCarried(id, caller, carried)` lifts
the hold on a wounded body for a carry. Bus: `opx:on:downed:changed` also fires when a
downed player asks for help (`waiting = true`).

### Medical services

`modules/medical` + `config/medical.lua`. A **service** is a config entry (`trauma`,
`ripperdoc` ship): its job gate, `DISPATCH`, `SUBSCRIPTION` tiers and desks, `TREATMENTS`
(`revive` / `heal`, items from the medic's bag, `FEE`, `PAY`, `ANIMATION`, `PROP`),
`CARRY`, `BEDS` and `BILLING`. A downed player who asks for help -- or a subscriber whose
tier has `AUTO_ALERT` the moment they go down -- becomes a call on the board of every
service that answers them; members on duty get a toast and a map pin, take a call from
the board (**F6**) and get a waypoint. ALT on a player opens what the medic may do: revive
(a server-timed bar), heal (the platform's two-player `heal`, after the patient agrees;
on a `BEDS` entry the patient is laid down instead), carry (the platform's `carry`, also
on a wounded patient). The patient is billed, unpaid bills become debt settled at the
desk, and a subscribers-only service treating a stranger charges
`OFF_CONTRACT_MULTIPLIER`. `server/dispatch.lua` is the board on its own, no host call
in it. Contract `medical` (server): `Subscription(id, service)`, `Calls(service?)`,
`Services()`; bus `opx:on:medical:call`, `treated`, `subscribed`.

### Public recovery and recycling

`modules/salvage` + `config/salvage.lua` is open to any loaded character. ALT on
a collection point starts an eight-second server-timed recovery; one
`electronic_waste` item is available per site every five minutes, shared by all
players. The typed KVP compare-and-set reserves depletion before delivery and
persists it across reconnects and restarts. A crash or failed grant after that
reservation can lose one collection; it cannot grant the same stock twice.
The module refuses collection when persistent KVP support is unavailable.

At the sorting bench, ALT opens the existing crafting menu: one discarded
electronic unit becomes either one `electronics` or two `scrap_metal` after
30 seconds. Orders and input consumption use crafting's existing persistence;
no cash reward is created. The first pickup and bench reuse the surveyed mechanic
pickup and sale coordinates from `config/hauling.lua`. Their placement and
interactions still need an in-game check. Additional `SITES` require finite,
nonzero `pickup` and `bench` coordinates with an explicit bucket.

Settings: `DURATION_MS` (1000..60000), `COOLDOWN_SECONDS` (60..86400), `REACH`
(greater than zero, at most five metres), up to sixteen `SITES`. Client request:
`opx:net:salvage:collect(siteKey)`; answers use `opx:net:salvage:notice` with
`done`, `busy` or `refused`. Depends on character, inventory, progress and crafting.

### Service careers: couriers and relay technicians

`modules/citywork` + `config/citywork.lua`. `/citywork` or ALT at the service
desk opens enrolment, freelance orders and professional orders. Enrolment adds
only grade zero in `courier` or `technician`, preserves any existing grade, and
activates the trade as primary. Clock in through workplace: the courier duty point
is at dispatch; the technician duty point is at the workshop. `SELF_ENROL=false`
leaves recruitment to the existing business/staff tools. Each trade has three
grades; promotions and treasury rights remain subject to the existing HR rules.

The desk issues a sealed, tagged module. A courier takes its shard to the assigned
point and completes a four-second handover. A technician delivers and fits a
replacement module with a twelve-second service action. These are registered
resource service points, not arbitrary vanilla devices being repaired or hacked.
Both require a fresh server position in the correct bucket, at least thirty
seconds of travel, the original character/session and the module for that exact
order. A cancelled action retains the module. Completion consumes the module and
submits proof to contracts; the existing durable ledger handles payout/recovery.

Freelance completion pays 160 eddies for delivery or 180 for service. The on-duty
primary trade instead pays 220 + 20 per courier grade or 250 + 25 per technician
grade. Grade-zero/one/two salaries are 65/100/150 for couriers and 75/120/170 for
technicians under the existing duty-gated paycheck policy. Salaries do not
replace completion rewards. No automatic promotion grants boss permissions.

Dispatch and the three destinations reuse surveyed hauling points; check their
presentation in game before release. The configurable routes must be at least
100 metres from dispatch, finite and nonzero. Up to twelve routes and six open
service orders are allowed. `PAY`, `MIN_TRAVEL_S`, `HANDOVER_MS`, `SERVICE_MS`,
`REACH` and `COMMAND` control the loop. Orders share contracts' persistent global
mint budget; a worker cannot reserve multiple simultaneous orders. `/gigs` also
shows their public-type orders, without opening ordinary merc-only gigs to everyone.

Client request `opx:net:citywork:request` takes `{ action = view|start|complete|enrol,
job = courier|technician, professional? }`; reward, route, grade and duration
never come from the payload. `opx:net:citywork:view` returns the requesting
character's current order or desk choices. Target points and `/citywork` remain
available after reconnect; the custom objective tick rebuilds the route index.

### Underworld

`modules/underworld` + `config/underworld.lua`. Dirty money is the `dirty_eddies` item
(never a balance); every valued action goes through `server/op.lua`: check inputs,
run the server-timed progress, re-check and commit inputs, outputs and owned rows
in one durable transaction. Cancelling before that commit takes nothing. Mint caps
and laundering limits are checked under SQL locks with their ledger writes
(`/opx.underworld.ledger <cid>`). Black-market dealers rotate
between spots, sell for dirty or (dearer) clean money and fence stolen goods; stores
hold regrowing register charges, need a weapon in hand and police on duty, and raise
an alarm (`police.Report` when that contract exists, else on-duty NCPD and MaxTac);
fronts launder by batch under a daily cap; gang-gated crafting labs heat up; drugs
use, addict and overdose; a street deal is the platform's two-player `give`. Gang gates
use `OPX.JobGate.EvaluateGroups`. Survey every entry with `/opx.underworld.capture`.

### Inventory: paired weapons (op77.152+)

Equip a right-hand weapon with the ordinary inventory Use action. On a second
weapon, choose **Equip / holster left hand**. Ammunition items offer the same
left-hand action to choose which weapon to replenish. `WEAPONS.DUAL_WIELD`
controls availability; `WEAPONS.SLOT` remains 1–3 and the left partner uses
`SLOT + 3`. The native game decides pair compatibility. Choosing an equipped
weapon while paired holsters both weapons; finish holstering before selecting
a replacement. Single-weapon use and hotbar bindings keep their existing behavior.

Every item retains its own serial and owned ammunition. Before creating a pair,
OPX saves shots fired by the primary weapon. Pair initialization waits for native
completion at every dependent step and replaces native creation ammo with owned
rounds. Shared ammunition totals are reconciled once across the two items, never
credited to both; a client observation cannot increase ownership. A transfer
waits for a complete pair readback and secondary-then-primary removal. Native
initialization failure clears the pair. The HUD displays both magazines, reload
state and a shared reserve only once, replacing completed snapshots atomically.

Both client and server need Open77 **2.50.0+op77.152** and the matching bundled
`open77_weapons` resource (an older bundle may still advertise version 0.1.0).
New refusals: `dual_wield_unavailable`, `primary_required`,
`weapon_in_other_hand`. The native `dual_wield_pair_unavailable` refusal
uses `weapon_pair_unavailable`, explaining that another pair is needed; other
failures use `weapon_refused`. The failed step and native reason are logged
server-side. Error toasts include a localized suggestion to contact an
administrator if the refusal seems mistaken. Older builds retain single-weapon support.
Open77 documents inconsistent native reload allocation when the shared reserve
is too low; OPX does not infer ownership grants from magazine increases.

Upstream contracts: [dual wielding](https://open2077.net/docs/dual-wielding) and
[cyberarm styles](https://open2077.net/docs/cyberware-customization).

### Ripperdoc

`ripperdoc` (`modules/ripperdoc`, `config/ripperdoc.lua`) puts chrome in and takes it
out at **clinics**. Reviving and healing are `medical`'s, not this module's. A clinic is
chairs, a parts stash (`inventory` stash) and a wholesale terminal; several clinics and
every chrome live in the one config, and anything at `0,0,0` is disabled and named at
boot (`/opx.ripperdoc.clinics` lists the state).

The loop, all server-side: the doc (job `ripperdoc`, on duty where the clinic says so)
ALTs a patient sitting in a chair -> **chart** (humanity, capacity, installed chrome, what
can go in: new parts from the stash, the doc's bag, the patient's own bag) -> **propose**
-> the patient gets a **consent form** (price, humanity, risk) -> **escrow** (money, then
the part) and a receipt row in `opx77_ripperdoc_operations` -> a server-timed **bar** on
the doc -> the **dice** (`TIERS[*].FAIL x GRADE_MOD x clinic RISK`, black parts, worn
parts, over capacity; weighted `OUTCOMES`) -> apply and **settle** (refund, `DOC_SHARE` to
the doc, the rest to `TILL`).

Gorilla Arms (`arms`/`gorilla_arms`) and Reinforced Tendons (`legs`/`double_jump`) are
**native**: `Open77.cyberware.install/remove` with `{ expectedRevision, operationId }`,
completed on `onCyberwareOperationCompleted` matched by ticket. The platform needs the
player bound to a character; `open77_appearance` binds when it runs, otherwise
`server/identity.lua` binds the citizen id on load. Without native cyberware the chrome is
roleplay metadata (`NATIVE.FALLBACK_RP`). The body is two character metadata keys,
`humanity` and `cyberware`. A crash is resumed from the receipts at boot: `reserved` is
given back, `submitted` is replayed with the same operation id when the patient loads in.

Contract `ripperdoc` (server): `Body(citizenId)`, `Clinics()`, `Chrome()`,
`Operation(player)`; bus event `opx:on:ripperdoc:operated`.

Cyberarm appearance is a free, owner-only service at a surveyed clinic chair.
Use the target row **Customize my cyberarms**, or `/opx.ripperdoc.style`, with
native Gorilla Arms installed. Choose an installed model and enter two six-digit
sRGB hex colors. The server checks the character, clinic, bucket, installed arms,
record syntax and RGB bounds, then projects the selection only to its owner.
The character's `cyberarmStyle` metadata is written after native acceptance.
Failed application, an expired acknowledgement or a character switch keeps the
previous saved selection. Removing arm implants releases the cosmetic override;
the saved selection remains available for a later installation.

`STYLES.ENABLED` disables new customization requests. `STYLES.RECORDS` is an
optional `record = true` allowlist; empty means any installed cosmetic identifier
with valid syntax. The local native catalogue and setter validate installed
models; this free service never treats catalogue membership as implant ownership
or authorizes an ability or purchase. Saved RGB is restored after character load
and native body reset, with bounded retries for body readiness. An unavailable
saved model is retained and reported rather than substituted.

Requires Cyberpunk 2077 2.5 and Open77 **2.50.0+op77.152** or later. The devkit
catalogue currently available during implementation is op77.148 and cannot verify
these newer functions; availability is checked at runtime against the documented
op77.152 API. Model replacement waits for holstered cyberarms. RGB colors are
local to the owner: this release has no remote-player RGB projection API.
Native appearance, streaming and reconnect behavior still require live testing.

### Netrunner

`modules/netrunner` + `config/netrunner.lua`. A runner ALTs an **access point** of a
network with a **cyberdeck** (`cyberdeck_*`, never stacked) in the bag and starts a
**breach**: one server `progress` bar per step of the node's `STEPS`, rolled by the
server (`M.Roll`), odds and speed moved by deck TIER against ICE TIER. A failed step
adds `BREACH.FAIL_TRACE` and runs again. Connected, the run's menu offers the
**daemons** of the access point and of every door, camera and terminal node of the
network: `door_unlock` (doorlock contract `GetFromName` + `SetState(id, 0, 'netrunner:<cid>')`,
relocked after `UNLOCK_S` if still open), `camera_loop`, `datamine` (a bar, then a
`data_shard` with `{ network, kind, value, hot, at, serial }`), `ice_pick`, `wipe_logs`.
RAM lives on the deck's metadata (`ram`, `ramAt`, regen computed from the wall clock),
is reserved before a bar and refunded on cancel. The server raises the trace every
`TICK_MS` toward 100% in `ICE.TRACE_MS`; `ALERT_AT` warns the `ON_TRACE.JOBS`, 100%
throws the runner out, locks the network for `COOLDOWN_S`, sends an `ALERT` (toast +
waypoint) to on-duty members and adds NetWatch heat (`netwatch_heat` metadata; a
Blackwall connect adds more; `FLAG_AT` locks the runner out for `LOCKOUT_H`).
**Brokers** buy every shard in the bag: value x `BUY[kind]` x `HOT_PENALTY` while hot.

A network may declare `GANGS = { voodooboys = 0 }`. This is an additional faction
requirement: the runner must still satisfy its job/skill requirement and carry a
suitable cyberdeck. Unknown gangs and grades disable the network. The Pacifica
Blackwall relay declares this gate. Membership is checked again during a session,
so leaving the gang revokes access without waiting for a reconnect.

Contract `netrunner` v1 (server): `CamerasBlind(network)`, `Objectives()`,
`ValidateShard(player, slot, want)`, `Verify(contract, proof)`, `Session`, `Heat`,
`Networks`, `JackOut`. Bus: `opx:on:netrunner:objective|traced|cameras|door`.
Staff: `/opx.netrunner.capture <network> <node> [kind]`, `/opx.netrunner.networks`.
Every position ships as `0,0,0` and its network stays disabled until surveyed.

### Police

`modules/police` + `config/police.lua`. A **service** is a config entry (`ncpd`,
`maxtac`, `arasaka_sec` ship): its job gate, `CAPABILITIES` (`cuff`, `escort`, `frisk`,
`fine`, `jail`, `impound`, each with a minimum grade -- a verb not listed is not held),
`DISPATCH.RECEIVES` (crime codes from `CRIMES`, `'*'` for all), `ACCOUNT`, and for
corpo security `ENCLAVES` (no authority outside a surveyed sphere). `STATIONS` hold
the building (jail only inside), `DESK` (pay fines), `EVIDENCE` (stash
`police_evidence_<station>`), `CELLS` and `RELEASE`.

Calls: `/911 <text>` (any player, cooldown), alarms through the contract, and a 10-00
when an on-duty member goes down; members get a toast and an SVG pin, the board is
**F5** (F6 is medical's), take -> waypoint. ALT on a player: cuff (item `handcuffs`,
registered at boot; a wounded suspect at once, a standing one after a 3 s server bar
he can walk out of), uncuff, escort (`playerInteractions` `escort`, no consent;
`downed.SetCarried` around a wounded suspect), frisk (bag listed, a stack confiscated
into the nearest locker), fine (form; paid from `BANK`, the rest becomes `debt` on the
record, `OFFICER_CUT_PERCENT` of what was paid to the officer, the rest to `accounts`
when it exists), jail (form; inside a station, a cell, a leash, released at
`RELEASE`). ALT on a car: impound (`vehicles.SetState(plate, 'impounded', GARAGE)`, or
the wreck removed). Cuffs, sentence and debt live in character metadata `police` and are
re-applied on load; a cuffed player's hits are refused by a `combat.onDamage` arbiter
and his client holds `allowWeapons/Shoot/Aim/Dodge/Jump/Interaction` false, re-applied
every second.

Contract `police` v1 (server): `Report{ crime, label?, position?, radius?,
description?, source?, priority?, dedupe? }` -> Result (underworld's alarms),
`Alert{ kind, jobs, label, coords, level, runner }` -> boolean (netrunner's trace;
false when no service holds those jobs), `OnDutyCount()` -> number, `IsCuffed(id)`,
`IsJailed(id)` -> bool, seconds, `Calls(service?)`, `Services()`. Bus
`opx:on:police:call|cuffed|fined|jailed`. Staff: `/opx.police.capture <kind> <name>`
(no args lists the stations' state), `/opx.police.release <id>`,
`/opx.police.unimpound <plate>`.

### Bar

`modules/bar` + `config/bar.lua`: bartenders, bars and food stalls. A **venue** is a
counter, a back-room stash (`inventory` stash) and an optional supplier point, worked by
its `JOBS` and/or `GANGS` (`bartender` by default; Totentanz also lets Maelstrom in and
banks into the `maelstrom` gang treasury). Five lore venues ship -- the Afterlife,
Lizzie's Bar, El Coyote Cojo, Totentanz, a Jig-Jig Street noodle stall -- all at
`0,0,0`, disabled and named at boot until their COUNTER and STASH are surveyed
(`/opx.bar.venues` lists the state).

The loop, all server-side: staff buy **stock** at the supplier into the stash (paid
from the venue `accounts` treasury when that contract exists, else from the buyer's
BANK; payment and stock commit together, with no charge if the stash is full) -> **mix** at the
counter: a recipe of the venue `MENU` is checked against the stash, a server-timed
`progress` bar runs, everything is re-checked, the ingredients leave the stash and the
drink lands in the bartender's bag (on the stash shelf if the bag is full); a cancel
uses nothing -> **serve**: ALT on a customer, pick a drink they carry from the venue's
`PRICES`, the platform's two-player `give` with consent; on completion the drink moves
and the customer receives an accepted, unpaid tab through `invoices` (`source = 'bar'`, `cutPct =
STAFF_CUT_PCT`, the venue `ACCOUNT`) or, without it, charged directly with the
bartender's cut paid out and the house share deposited to `accounts` (all to the
bartender without it). The consented handover commits the item and either the unpaid
invoice or the complete direct-payment split in one transaction. Mixing likewise
commits stash ingredients and the finished drink together. Job, session and distance
checks run again after inventory save fences. An uncertain database reply keeps the
operation pending; it never triggers a refund or a second billing route. The items (the Afterlife's cocktails named after legends,
Broseph ale, noodles, the stock) are registered at boot; a drink's `THIRST`/`HUNGER`
become its `use.status`, moved by `needs` when it is used, and its `ALCOHOL` raises a
server-side drunk level played with `Open77.effects.screen('drunk')` on the drinker.

Contract `bar` v1 (server): `Venues()`, `Items()`, `DrunkLevel(player)`. Bus:
`opx:on:bar:mixed|bought|served`.

### Pool

`modules/pool` + `config/pool.lua` offers three original modes using one white
cue ball and two yellow object balls. Cooked models, recorded audio and cleanup
patches live in the separate `opx_pool_assets` resource. Table actions use menu-wide
`closeOnSelect`, so selecting a mode dispatches its command before releasing
focus. Confirmation submenus dispatch only their confirmed selection. The modes
have no wagers,
XP or money rewards, spin, numbered-ball families or persisted match records.

`TABLE.enabled` ships false. Survey a real, unobstructed table before enabling it:
`x/y/z` are the **ball centres above the cloth**, not the floor; `halfLength` and
`halfWidth` describe the playable rectangle in metres. `yaw` rotates the local
long axis from world +X, counterclockwise in degrees. `bucket` must match the
players' routing bucket. Ten named measurements supplied with nc_pool are available as `PRESETS`, with
credit to Darkpickle for the placement data. Their documented floor-to-ball
offset of 0.843 m is already applied to `z`. Choose one with
`TABLE = { enabled = true, preset = 'el_coyote_cojo' }`; the Coyote ball centre is
`(-1247.944, -995.978, 13.263)`, yaw `99.85`. The configuration activates one table at
a time. These inherited measurements require visual verification on the current
game build; they are not newly surveyed. To use a custom table, omit `preset` and
put the geometry directly in `TABLE`. The asset resource supplies the recorded
ArchiveXL cleanup patches. The Coyote file is named `0_opx_pool_hosts.archive.xl`
beside the matching archive, so ArchiveXL can discover it when the depot mounts
archives individually. The sector indices and type/count guards are preserved.
A sector/node-count mismatch leaves vanilla decorations
in place; inspect the client ArchiveXL log. The gameplay module never deletes
another resource's props or world nodes.

The eye opens **Table and game modes**. Choose **Free practice** (unlimited
shots, automatic rerack after both yellows are pocketed), **Solo challenge**
(clear both within `SOLO_SHOTS`, default 10), or create a **Two-player duel**.
A second nearby player chooses **Join the duel**; this starts the game. A solo
challenge ends on a clear or the shot limit; scratching while pocketing the last
yellow loses the challenge. Scores count pockets, with a one-point scratch penalty
floored at zero. Duel target is `DUEL_TARGET` (default 5): a pocket retains the
turn, a miss or scratch passes it, and the two yellows rerack when cleared.
Only the server's physical outcomes change these scores and turns.

The current shooter automatically gets a camera behind the white ball. Mouse
movement aims; **Shift** gives fine control. Hold/release left-click to charge/fire.
**Middle mouse** toggles the overhead view; V remains available to inventory.
The wheel adjusts cue-view height. The overhead default is now **1.65 m** above
ball centres (`OVERVIEW_HEIGHT`, range 1.2–2.4), with a wider lens to keep the
cloth framed. A small lateral cue-camera offset keeps the shaft visible. The
queue sits behind the white ball, retracts with charge and follows through for
220 ms after release. All rendered balls/queue explicitly request `collision =
false`, `physics = "none"`, `visible = true`; ball contacts remain server simulation.

**R** resets even during aim, cancelling charge first. In a duel it proposes a
new game; the other participant must accept with **R** or the table menu. The
current scores/balls remain until consent, shots are paused during the vote,
and the request expires after 15 seconds. **E** opens table options, including
resume, rematch/reset, declining a request, finishing and leaving. A reset waits
until the balls stop. **Backspace** leaves at any time. Leaving, dying, changing
character/session, changing bucket or moving more than 6 m away forfeits an active
duel; the shooter must stay within 3.5 m. Unfilled lobbies expire after two minutes,
finished results free the table after 30 seconds. Spectators cannot change a game.
Participants can use middle mouse to watch the overhead view during the other turn.

The overlay shows the mode, scores, active player, remaining solo shots and a
smooth power gauge, and takes no focus. Right-click cancels/resumes aim; while
cancelled the player can walk around. Capturing a menu cancels an active charge without
firing and requires an explicit resume afterwards. A newly accepted mode or turn
waits for the menu to release native focus before its first automatic aim; the
brief capture during closing does not discard that pending entry. Table menu rows
use the shared OPX glyph vocabulary for modes, reset, resume and leaving. The scoped camera and control
leases release on loss of the seat, leaving, character unload and stop. The
scripted camera explicitly requests **thirdPersonBody = true**, verified against
the signed op77.152 client; if the native returns a body/options availability
refusal, it retries once without that optional field and logs the legacy fallback.
Destroying only the owned camera restores the native presentation. Actual local
head/hair rendering and framing still require a live client check.

The straight aiming guide stops at the first ball or cushion and shows a contact
ring, without predicting rebounds. `AIM_GUIDE = false` hides it. `SENSITIVITY`
defaults to `0.0018`, `CHARGE_SECONDS` to `1.8`. Real CC0 cue, ball and pocket
recordings are delivered as PCM WAV by the asset resource; rails reuse the ball
clip at lower gain. `AUDIO_VOLUME` (0–1, default 0.65) sets loudness, zero mutes.
Server contacts carry bounded IDs/times; client audio follows the same 100 ms
playback delay, deduplicates repeated snapshots and skips past sounds on join.
Up to four sounds dispatch per frame through the asset resource's caller-checked
client exports; that resource owns at most eight spatial voices. See its NOTICE
and audio/sources.json for original recordings, CC0 links, exact hashes and edits.

The camera needs `camera.script`; the bounded aiming guide uses `world.debug`.
Its camera/prop work runs per frame; guide geometry is capped at 20 lines and
refreshed every 100 ms with a 200 ms native expiry. The power overlay consumes no
pointer or keyboard and expires stale readings after 500 ms. These are client
presentation features, not new permissions to decide shots or outcomes.

The server owns all ball coordinates, collisions, pockets and scratch recovery.
Its fixed 120 Hz solver advances to swept ball/rail/pocket contacts, with a bounded
contact count and dissipative collisions/friction. Six timestamped samples are
sent every 50 ms to valid nearby watchers. Clients keep at most 40 samples and
interpolate 100 ms behind the stream; they never extrapolate or decide outcomes.
Creation, joining, shots and resets bind to the viewed epoch/revision. Reset votes
and scores remain tied to the two original character/session tickets. Shot and
rack requests carry the current epoch and ready revision. Old, duplicate,
out-of-range, cross-bucket, dead, stale-transform or recycled-session requests
cannot take a shot. These modes have no economic effects or persisted game state.

The native baseline checked is Devkit `2.50.0+op77.148`; the test VPS uses
`2.50.0+op77.152`. Install
[`opx_pool_assets`](https://github.com/opx77-framework/opx_pool_assets) before Infinity.
Use asset resource version `0.2.0` or later. Its client script publishes the recorded
audio service and makes the resource available in the signed client set to satisfy
Infinity's dependency. The service alone declares `audio.play`; Infinity does not
request audio-network authority.
A server-only asset resource is omitted from that set and causes client activation
to fail even when the archive download succeeds.
World-decoration cleanup additionally requires the
[Open77 ArchiveXL port for Cyberpunk 2.5](https://github.com/Open2077/archive-xl),
currently published as `1.27.5-open77.6`. The stable signed catalogue checked on
2026-10-24 (generation 82) has no standalone `archivexl` entry. Requesting that
nonexistent indexed ID prevents the launcher from resolving the world. The
configuration example therefore does not request it. A hosted executable package
must pass the platform review for its exact hash before secured distribution;
publishing source or a GitHub release does not establish that verdict.
Do not load a DLL-preloading resource on a secured server. Cooked host assets and
ArchiveXL cleanup are separate: the archive can be delivered without the loader,
but cleanup must not be considered working until the compatible loader is mounted
and checked in game. The framework
manifest declares the asset-resource dependency. Keep the server's existing
required-mod trust/review policy; do not silently enable unsecured mode to install
a loader. Restart the server, fully quit Cyberpunk, and reconnect through the
launcher: cooked archives cannot mount during a running game session.

The asset package deliberately reserves three native aliases globally:
`recreation.tent` (white), `recreation.sleeping_bag` (yellow), and
`recreation.gym_equipment` (horizontal cue). Other resources must not use them for
their original objects. Six normal/attached hosts are repacked from the supplied
Darkpickle templates; the source pack's 44 unrelated food/medical/military and
other overrides, and its unused standalone ball-template archive, are excluded.
The current platform has no published custom-alias registration API, so this
reservation is an explicit integration constraint rather than a new native pool
catalogue. Do not load `nc_pool` or its old preload alongside this pack.

Verify the actual ball shape/scale and cue alignment in game. `MODELS.stickYaw`
and `stickOffset` calibrate the cue. The local transform API supplies position and
yaw, not full 3D rolling or cue tilt/spin. Local-prop creation/render failures and
marker fallbacks are diagnosed; fresh native objects get a bounded three-second
streaming grace before a repeated transform refusal stops practice. Diagnostics
preserve the native reason; player messages stay friendly. A permanent failure
removes visuals, releases the seat/controls, and stops retries until restart.

Live qualification: two real clients on the same table, fast glancing impacts,
rail/pocket transitions, mouse feel at different frame rates, jitter, spectator
entry and reconnect, UI cancellation, character/bucket changes and stop cleanup.
Unit/render doubles and instruction measurements do not prove the meshes render
correctly in Cyberpunk.

#### Shared player-control ownership

`OPX.Controls.Set(owner, names, held)` gives modules leases over the native
resource-wide restriction bits. Target, police, hauling and pool use this boundary.
Releasing one owner preserves every other owner's restrictions; failed partial
acquisitions roll back. Native restrictions are re-applied on upkeep where required
because the engine may clear them on death or a body transition. Never call
`resetControls` to close an individual module's interaction.

### Taxi

`modules/taxi` + `config/taxi.lua`. A **company** is a config entry (`delamain` ships on
job `cabbie`; `nccab`, an indie example, ships disabled until its job exists): job gate,
`DISPATCH`, `FARE` (`BASE`, `PER_KM`, `MIN`, `MAX`, a `NIGHT` surge read off the weather
clock), `DRIVER_CUT_PCT`, `ACCOUNT`, optional `VEHICLES` allow-list and `NPC_FARES`.
Anybody types **`/taxi`** (`/taxi <company>`, `/taxi cancel`, `/taxi stop`): the call goes
on the board of every on-duty driver (toast + map pin); a driver opens it with **`/cab`**,
takes the call (waypoint; the customer is told the car record and an ETA in the
company's voice -- the Delamain AI or a human dispatcher). The **meter is the server's**:
it starts when the customer sits in the vehicle whose driver's seat the driver holds
(`Open77.vehicles.getPlayerSeat`), adds one clamped segment of the driver's position per
`SCAN_MS` (`MAX_SPEED`), and stops after `EXIT_SAMPLES` samples with the customer out. The
fare is billed through `invoices` when it runs (company share to `accounts`), else taken
with `RemoveMoney` and split (`accounts.Deposit` or all to the driver). A driver may also
start the meter for whoever already sits in the cab (**hail**), or, with the board empty,
take a **street fare**: drive to a pickup, then to a destination; paid by the company on
the straight distance, minted, capped per driver per rolling hour, refused when the trip
log is faster or shorter than the road. `server/dispatch.lua` is the board on its own
(the medical board's pattern, copied). Contract `taxi` v1 (server): `Calls(company?)`,
`Ride(player)`, `Companies()`; bus `opx:on:taxi:call`, `opx:on:taxi:ride`.

### Justice

`modules/justice` + `config/justice.lua`. Jobs `lawyer` (Associate, Partner) and
`judge` (Judge, Chief Judge). At a **City Hall desk** (ALT sphere, `CITY_HALLS`) a
citizen buys a **licence** of `LICENCES` (driving, weapons, business, netrunning):
the `FEE` leaves the purse first, then the line `{ issued, expires, serial, by }` is
written in the character metadata `licences`, then a `licence_card` (never stacked,
not droppable) carrying `{ kind, holder, serial, expires }` goes in the bag. A
`CLEAN` licence is refused under an active warrant or a felony newer than
`CLEAN_DAYS`. The desk also shows the citizen's own record, takes the **bail** a
judge set on their warrant and dismisses their lawyer. Fees, bail and court fines go
to `CITY_ACCOUNT` through `accounts.Deposit` (burned, logged, without it).

The **criminal record** is `opx77_justice_records` (kind offence|verdict|warrant,
code, fine, jail, bail, officer, paid, active, expunged). Police (`POLICE` gate) and
judges read anyone's (ALT on a player, or the bench's lookup); a lawyer reads only a
**client's**: a lawyer ALTs a player, the player consents, `opx77_justice_counsel`
holds the row. From the client file a lawyer asks to **expunge** an entry; a judge
approves or denies it from the **bench** (self ALT row "Legal office"), signs
**warrants** with bail, raises or lifts bail, revokes licences, opens a **case**
(`opx77_justice_cases`) and closes it with a **verdict**: guilty writes a verdict
entry and bills the fine through `invoices.Issue` (`source = 'justice'`, no cut,
toward the city account; paid on `opx:on:invoices:paid`), else straight from a
present defendant's bank, else unpaid on the record; jail minutes are asked of
`police.Jail(player, { minutes, reason, by, source })` when that function exists.
The conviction entry and case closure commit in one database transaction; an
insert failure leaves the case open so the judge can retry.

Contract `justice` v1 (server; the database calls yield): `AddRecord(citizenId,
{ code, label?, kind?, fine?, jail?, bail?, officer?, officerName?, notes?, source?,
paid?, felony? })`, `GetRecord(citizenId, { expunged? })`, `HasWarrant(citizenId)`,
`HasLicence(citizenId, kind)` -> `boolean, state`, `Licences`, `IssueLicence`,
`RevokeLicence(citizenId, kind, reason?, by?)`, `Crimes()`. Bus:
`opx:on:justice:record|licence`. Staff: `/opx.justice.desks`, `/opx.justice.capture <key>`.

### Workplace: duty, uniforms, service vehicles

`modules/workplace` + `config/workplace.lua`. A **station** belongs to one job and holds
up to three ALT spheres: **DUTY** (clock in / out through character `SetJobDuty`; a job
held as a secondary membership is made primary first when `SWITCH_PRIMARY`; a
`defaultDuty` job has no clock and the validator refuses one), **WARDROBE** (the job's
`OUTFITS`, per `MIN_GRADE`: a uniform is a set of equipment slots written through
`appearance.SaveClothing`, which re-dresses the puppet; the civilian record is kept on
the `workplace_civvies` metadata BEFORE the uniform is written and put back by "Back to
civilian", by going off duty (`RESTORE_OFF_DUTY`), by losing the job, or at the next
login of a character no longer in that job) and **GARAGE** (the job's `FLEET`, per
`MIN_GRADE`, narrowed per station by `VEHICLES`: `Open77.vehicles.create` on the `PAD`
with `ttlMs`, no row, a key through `vehiclekeys.GiveFor`; one per player; handed back
at the pad within `RETURN_RADIUS`, and taken back with every key revoked on off duty,
job change, logout, disconnect, or when the host removes it). Every job decision goes
through `OPX.JobGate`. Sirens and lights are the police module's.

Contract `workplace` v1 (server): `OnDuty(player)` -> `(bool, job)`, `Fleet(job)`,
`Out(player)`, `Recall(player, reason)`, `InUniform(player)`. Bus:
`opx:on:workplace:duty|uniform|fleet`. Staff: `/opx.workplace.capture <station>
<duty|wardrobe|garage|pad>` (the pad line carries the heading), `/opx.workplace.stations`.
Every point ships as `0,0,0` and stays disabled until surveyed.

### Corpo

`modules/corpo` + `config/corpo.lua`. Several corps in one file (Arasaka and Militech
enabled; Kang Tao, Biotechnica, Petrochem shipped `ENABLED = false` as examples). An
employee (primary job = the corp's `JOB`, clocked in if `ON_DUTY`) ALTs one of the corp's
**OFFICES** and reads the **assignments board**, generated by the server from the
`ASSIGNMENTS` templates (`deliver` a tagged `corpo_briefcase`/`corpo_datashard` to another
office, a drop or a **rival's** drop; `retrieve` = a server bar at a TERMINAL, then
deliver the shard; `sweep` = stay `HOLD_MS` on a FLOOR, timed by the server tick; `escort`
= a server NPC VIP that follows the employee to a DESTINATION, `Open77.npcs.get` read by
the server). The board never shows where an assignment ends. Completion is proven by the
item's assignment id **and** serial at the right place. The corp pays: `accounts.Withdraw`
(`job`, corp key, op id `corpo:<id>:<serial>:pay`) when the contract runs, else new money
under `MINT.PER_HOUR` (tunable `CORPO_MINT_PER_HOUR`). **Standing** per corp lives in the
`corpo` metadata (`MIN_STANDING` unlocks templates); `QUARTER.TARGET` done in a quarter
pays `QUARTER.BONUS` once. **Espionage**: a rival corp's employee ALTs a courier carrying a
`STEALABLE` item (server bar `STEAL_MS`), the shard changes bags, the victim fails, the
thief hands it in at one of their own offices. **Security**: `ENCLAVES` (same job gate as
the elevators' floors) warn a trespasser and alert on-shift security (grade >=
`SECURITY_GRADE`); "Detain trespasser" (bar) hands the suspect to `police.Handoff` /
`police.Report{ crime = 'trespass', source = 'corpo' }` when present, else alerts on-duty
`POLICE_JOBS`, and walks them to `EJECT` (`SECURITY.EJECT`). A grade >= `PUBLISH_GRADE`
may **outsource** an offer to the fixer board (`contracts.Post`, `funded = 'external'`, paid
by the corp up front, refunded on `opx:on:contracts:failed|expired|cancelled`).

Contract `corpo` v1 (server): `Standing(player, corp)`, `Active(player)`, `Corps()`,
`CanEnter(player, corp, enclave)`, `Trespassing(player)`, `AddStanding(player, corp, delta)`.
Bus: `opx:on:corpo:completed|failed|stolen|detained|trespass`.
Staff: `/opx.corpo.capture <corp> <list> <key>`, `/opx.corpo.status`. Every place ships as
`0,0,0` and is skipped until surveyed. Assignments live in memory (a restart ends them).

### Radio

`modules/radio` + `config/radio.lua`. A **channel** is a config entry (NCPD dispatch,
NCPD command, MaxTac, Trauma, the shared `interagency` band for the three, ripperdoc,
Delamain, Arasaka, Militech; gang frequencies ship `ENABLED = false`) gated by
`JOBS` / `GANGS` through `OPX.JobGate.EvaluateGroups` (primary job, `ON_DUTY`), backed
by one resource-owned `Open77.voice` channel in mode `radio` with a band-pass and hiss.
`AUTO` channels are joined when the character qualifies and every channel is left when
they stop (`opx:on:character:job` / `gang` / `loaded`, `opx:on:inventory:items` for the
`radio` handset, registered at boot, `REQUIRE_ITEM`), plus a sweep. `/opx.radio` or
using the handset opens the menu: power, join / leave, select, mute (per channel,
server-side `canListen`). **A member is a listener until the talk key (CAPSLOCK,
rebindable) is held**: the server lifts `canSpeak` on the selected channel for as long
as it is held (`MAX_TALK_MS` cap, never while downed), so a holocall's `all` route or
the platform's own voice key never reach a radio channel. Contract `radio` (server):
`Join(player, channel)`, `Leave(player, channel)`, `Channels(player)`; bus
`opx:on:radio:changed`. `/opx.radio.channels` (staff) lists them.

### Business: treasuries and the HR terminal

`modules/business` + `config/business.lua`. **Who is a boss is the grade table** in
`config/character.lua`: `isBoss = true` opens the HR terminal (`/opx.boss`, or the ALT
row at an office of `JOBS.<job>.OFFICES` / `GANGS.<gang>.OFFICES`, all `0,0,0` =
disabled and named at boot), `bankAuth = true` also moves money between the boss's
`POCKET` (cash) and the company account. The terminal lists the roster online and
offline (`GetGroupMembers`), recruits a nearby player (an offer they sign or decline,
`HIRE.RADIUS`, `HIRE.TTL_S`), fires, promotes, demotes and clocks inside the grade
table under `RANK_RULE` (`below`: only people strictly below the boss, never up to their
grade), and caps head count at `MAX_EMPLOYEES`. Every change goes through the character
contract (`SetJob`/`SetGang` on a primary group, `AddPlayerTo*` on a secondary one,
`RemovePlayerFrom*`, `SetJobDuty`), so `job:beforeSet` vetoes and the offline ledger hold.

Contract `accounts` v1: `Balance`, `Deposit`, `Withdraw` (`insufficient_funds`),
`Transfer`, `History`, each with an optional `opId` -- the ledger
(`opx77_company_ledger`, `op_id` UNIQUE, written in the same transaction as the balance)
makes the same opId one movement, answered with its first receipt; a debit is an
`INSERT ... SELECT ... WHERE balance >= amount`, so it cannot overdraw. The balance table
is the dealership's `opx77_company_accounts`, taken over as it is; the dealership still
banks its sales itself and files them with `Note` (history + bus). Bus
`opx:on:accounts:changed` and `opx:on:business:staff`. Contract `business` v1:
`IsBoss(player, job, kind?)`, `Employees(job, kind?)`. Staff: `/opx.accounts <job|gang>
<name> [deposit|withdraw <amount>]`.

### Mechanic

`modules/mechanic` + `config/mechanic.lua`, job `mechanic` (Grease Monkey / Mechanic /
Shop Owner). Several **shops** (Autofixer Arroyo, Dakota's garage Rocky Ridge, Kabuki
body shop), each with `BAYS`, a parts `STASH` and an impound `LOT`, all shipped at
`0,0,0` (disabled, named at boot). **Workshop repair**: ALT on a vehicle standing in a
bay, mechanic on duty; the damage in percent (worse of lost health and crushed body
cells) sets the fee, the parts (`mech_parts`, stash first then bag) and the bar length;
at the end the server re-checks, takes the parts, charges the customer (the owner if
near, else the nearest player) and calls `Open77.vehicles.repair(id, 'full')` +
`setHealth(1.0)` -- refused with `not_ours` (everything given back) for a car another
resource spawned. With `invoices` the customer gets an invoice instead; the shop share
goes to `accounts` (`job`, `ACCOUNT`) or, without it, to the mechanic. **Roadside kit**
(`mech_repairkit`): anybody, anywhere, health up to `KIT.HEALTH` + `KIT.SCOPES`.
**Calls**: `/mechanic [note]` and `/tow [note]` alert every mechanic on duty (toast +
pin), `/mechboard` lists, takes (waypoint), drops and closes. **Tow**: `IMPOUND.JOBS`
(mechanic 1+, ncpd, maxtac) impound a registered, empty vehicle through
`vehicles.SetState(plate, 'impounded')`; the owner pays `RELEASE_FEE` at a shop's lot to
get it back (`SetState 'stored'`, fee to the shop account). Contract `mechanic` v1
(server): `Call`, `Calls`, `Shops`; bus `opx:on:mechanic:call|repaired|impounded|released`.

**Roadside diagnosis**: an on-duty mechanic ALTs a vehicle to read its canonical
health pool, body damage, tyres, glass, lights, detached panels and openings.
The report includes the workshop quote (parts, fee and duration) without charging
or repairing. `opx:net:mechanic:diagnose { vehicleId }` is checked for job, grade,
distance, bucket and request cooldown; `opx:net:mechanic:diagnosticView` returns
only the report and quote, never owner identity. Cyberpunk has one vehicle health
pool; the report does not invent a separate engine health system. Detached panels
alone count as repairable damage even if the health pool is full.

**Workshop hood**: ALT offers explicit open/close actions. Request
`opx:net:mechanic:hood { vehicleId, opened = boolean }` requires a matching job
and grade, active duty, the worker on foot, the same bucket, a nearby vehicle
inside one of that worker's configured workshop bays, no occupants and no active
work reservation. It calls server `Open77.vehicles.setDoorOpen(id, 5, opened)`
(`world.vehicles`, available since op77.45); the client cannot choose a door or
replace a mask. The native replicates the opening. Failure leaves the car alone
and reports `unavailable` or `not_ours`; success reports `hood_opened` or
`hood_closed`. Vehicles without a visible hood still need a model-specific live check.

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
clip has finished. Every other server toast now reaches the same overlay too --
`OPX.Notify` raises it on the runtime's own channel -- but as a sentence and a kind,
with no stinger: holding a message back is the announcement's alone. The chat line still
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

The order is: the message is not drawn while the opening clip plays, it appears when
that clip ends, it goes when its lifetime ends, and only then does the closing clip
start -- with a refused playback still drawing the message.

### Contracts: the gig board

`modules/contracts`, configured in `config/contracts.lua`. A **fixer** (`/postgig`)
posts a gig and its reward plus `POST_FEE` leave their cash at once, **into escrow**; a
**merc** (`/gigs`, or ALT on a district fixer NPC) takes it, first come first served.
The server alone records the proof — a parcel handed over at a drop-off, a zone held
for `HOLD_MS`, or a fixer's sign-off for a `manual` gig — and the settlement pays the
merc the reward minus the fixer's cut (handed back to the fixer), moves street cred
(character metadata `contracts`), and refunds the escrow on cancel, expiry or failure.

`POSTERS` and `TAKERS` accept optional `GANGS = { gangName = minimumGrade }`
alongside `JOBS`. Either an authorised job or an authorised gang may pass;
`ON_DUTY` applies to jobs only. The highest authorised group grade determines
grade-based commission and validation rights. Existing job-only settings retain
their behaviour.

Every eddie moves through one rule: a ledger row keyed `contracts:<id>:<phase>`
(`opx77_contract_ledger`) is reserved, the money moves, the row is committed. A replay
finds the durable wallet receipt and moves nothing. Versioned reservations can be
resumed with their original operation ids; legacy reservations without durable
proof are quarantined for staff rather than automatically repeated or refunded. A gig that ends is written
`settling` first, so a restart finishes paying it. Payouts use `AddMoneyOffline`: a
merc who logged off is still paid.

District fixers (`FIXERS`) stand as NPCs, open the board on ALT and — when no player
fixer is on duty — post gigs from `TEMPLATES` paid in new money, capped by
`MINT_PER_HOUR`; their cut is destroyed. A manual gig nobody signs off within
`VALIDATE_TTL_S` is paid or goes `disputed` (`MANUAL_TIMEOUT`); staff settle it with
`/opx.contracts.resolve <id> paid|failed`.

Other modules post and measure through `OPX.Api.Get('contracts')`: `Post(spec)`,
`Cancel`, `Get`, `List`, `ReportProof(id, proof)`, `Resolve(id, outcome)`,
`RegisterObjectiveType(name, { validate, describe?, waypoint?, canStart?, start?,
stop?, tick?, public? })`, `Accept(player, id)` and `UnregisterObjectiveType(name)`.
Only explicitly public types bypass the ordinary `TAKERS` gate; `canStart` still
filters listing, notifications and acceptance and must be free of side effects.
Custom types do not become player-postable through the existing form.
`Post{ funded = 'mint', ... }` shares the fixers' persistent hourly budget and
in-flight commitment reservation. `mint_cap` means exhausted budget and
`mint_busy` means another publication is awaiting storage. Other funding modes
retain their behaviour. An objective type in use or being posted cannot be
unregistered (`type_in_use`); built-in types cannot be removed (`type_taken`).
The bus is `opx:on:contracts:posted`, `accepted`, `paid`,
`failed`, `expired`, `cancelled` — ids, type, citizen ids and reward, never a position.
Every drop-off, zone and fixer ships at `0,0,0` and is disabled, by name, until surveyed.

### Media: N54 News, WNS and the screamsheet

`modules/media` + `config/media.lua`. Job `reporter` (Stringer 0 / Reporter 1 / Anchor 2 /
Editor-in-chief 3, boss and bank). Which **newsroom** a reporter works for is character
metadata `press = { network }` (default `DEFAULT_NETWORK`), set by an Editor-in-chief of that
newsroom with `/pressnet <id> <network>` or by staff with `/opx.media.assign`. Several
newsrooms live in one config (`n54`, `wns`, `screamsheet` ship), each with a `TAG`, an
`ACCOUNT` (`accounts` treasury) and `DESKS`.

**Breaking news** (`/breaking`, form, or `/breaking headline | text`; Anchor and up, on
duty): the server sends `{ label, tag, headline, text, durationMs }` to every connected
player on `opx:net:media:broadcast`, and each client draws it exactly like the staff
announcement above -- `OPX.Toast.Show` on the runtime's overlay, one fixed id, the two
stingers of the RECEIVING client's `BROADCAST.STINGER` -- plus a chat line on core's answer
channel. Held to a per-newsroom cooldown, a global cooldown and an hourly count; audited;
`/news` reads the feed back.

**Field work**: `press_camera` used from the bag starts a server-timed bar; the camera must
still be in its slot and the reporter within `MAX_DRIFT` when it ends. The `press_photo`
item carries the server's reads (`x, y, z, bucket, at, by, crowd`). A real picture is taken
only when `PHOTO.UPLOAD_URL` is set: `Open77.players.requestScreenshot` (permission
`players.screenshot`) has the client POST its own game view there -- the platform never
carries the bytes over the game transport, so without an external URL a photo is the
record of a shot. `/story` files a `press_story` (headline, body, words). An editor **desk**
(ALT) buys pieces of the seller's own byline. The exact inventory slots, wallet credit,
optional newsroom treasury debit and sale history commit together. Without `accounts`,
new money stays under `SALES.MINT_PER_HOUR`. Hourly caps and repeated-scene history
persist across restarts; a locked newsroom row serializes concurrent sales before
checking caps and the quoted scene revision. An uncertain reply remains pending.
Freshness, old news (`REPEAT_*`) and a per-seller hourly cap shape the price. Stringers sell to any desk,
staff only to their own newsroom.

**Tips line**: `/tip <text>`, anybody, anonymous to the reporters on duty (the caller is in
the audit journal only); `/tips` reads the last ones. **Kit**: `/presskit` gives an on-duty
reporter their own `press_pass` and a `press_camera`; a pass used from the bag shows
everybody within `PASS.SHOW_RADIUS` the bearer, newsroom and whether the accreditation
still holds (`valid`, `revoked`, `unverified`). Client-to-server is ONE door,
`opx:net:media:request` with `verb = breaking|story|sell`. Contract `media` (server):
`NetworkOf(player)`, `Networks()`, `Feed()`; bus `opx:on:media:broadcast|sold|photo|tip`.
Staff: `/opx.media.desks`, `/opx.media.capture <network> <desk>`. Every desk ships at
`0,0,0` and is disabled, by name, until surveyed.

### Invoices: bills with consent

`modules/invoices` + `config/invoices.lua`. An employee whose PRIMARY job is in `JOBS`
(grade, duty through `OPX.JobGate`) bills a player within `REACH`: ALT on them (**Send a
bill**, then amount and reason) or `/opx.bill <id> <amount> <reason>`. The customer is
prompted (**Pay now** / **Put it on my tab** / **Refuse**, `ANSWER_TTL_S` then expired).
Paying takes `MONEY_TYPE` (BANK), `FALLBACK_TYPE` (cash) when the bank is short; the
employee is paid the job's `CUT_PCT` and the rest goes to the job's company account
through `accounts.Deposit(..., opId)` -- or to the employee when `ACCOUNT = false`, when
`accounts` does not run (said once at boot) or when it refuses the deposit (audited).
A bill accepted but not covered stays on the tab (`/opx.bills`, `opx77_invoices`,
survives restarts, lapses after `UNPAID_TTL_S`, at most `MAX_UNPAID`); the employee
withdraws an unpaid bill from the same list.

Prompts, tabs and notifications identify people by their current connection id,
or an anonymous citizen label when offline. Stored character names are never sent
as an introduction through billing.

Money moves like contracts: the bill is written `settling` first, each movement is a row
`invoices:<id>:charge|cut|rest` in `opx77_invoice_ledger` (reserved, moved, committed),
then `paid`. A restart finishes a `settling` bill from its receipts; a charge a crash left
`reserved` is `orphaned` and the bill `disputed` for staff, never guessed at.
If a treasury credit raises or returns `accounts.unknown`, its outcome is ambiguous:
the payout stays pending and retries the same operation id. It does not also pay
that share to the employee.

Contract `invoices` v1 (server): `Issue{ issuer, target, amount, reason, account?, cutPct?,
source? }` -> `Result{ id }` (yields; no reach or job check -- the caller decided),
`Pending(player)` -> `Result{ rows }`, `Get(id)`, `Cancel(id)`. Bus
`opx:on:invoices:issued`, `paid`, `refused`, `expired`, `cancelled` as `(source, { id,
amount, account, source, issuerCid, targetCid })`. NCPD ships without an entry on purpose:
a citation is a fine, not a service.

---

## Economic persistence

Wallet writes (`AddMoney`, `RemoveMoney`, `SetMoney`, `AddMoneyOffline`) are durable
before success is returned. Character autosaves do not rewrite money. Money types
retain the configured negative-balance rules and the JavaScript safe-integer limit.
All external writes must use the awaited export form below, including online cash.

`opx77_money_ledger` records each operation id, character, currency, amount and
resulting balance. Participant writes use both that id and a fresh attempt nonce.
The internal `inventory.AtomicTrade` and `AtomicPeerTrade` contracts couple wallets
with staged bags, trunks or peer inventories. Currency-note conversions, company
desk transfers, crafting orders/collection, shard sales, hauling sales, corporate
item hand-ins, underworld trades, paid clothing, bar stock/mixing/serving, media
sales and fuel-can purchases/refills use this boundary. Bar company splits and
accepted service invoices participate in the same transaction as the handover. Crafting
computes each deadline from the locked SQL queue tail.

A lost database reply returns `money.pending`. The runtime keeps affected wallets
and containers locked, reconciles the same operation id and publishes its result
once. Never interpret this refusal as permission to refund or retry under a new
id. `money.opIdConflict` means the id already belongs to a different movement.
Internal operation ids are server-generated; clients cannot choose them.

Vehicle purchases persist the debit, vehicle ownership and seller/company payout
obligations together. A delayed payout retains its original recipient and currency;
it is retried by its receipt id. A purchased car remains available through its garage
when the immediate handover cannot finish. Invoice and contract phases also retain
stable payment ids across restarts. A company payout with an uncertain result is
never redirected to a character as a fallback.

Migration is additive. Existing invoice/contract phase rows and laundering batches
remain version zero; historical escrow without durable proof is preserved for
manual reconciliation. Do not promote these records to version one or delete money
receipts to force a retry. Back up the database and configuration before upgrading.
Old laundering batches must be reviewed by an administrator rather than collected
automatically under the new payment rules.

Built-in shop billing returns price quotes to appearance. The outfit and the
combined charge commit together; no charge is made when a fitting room is cancelled.
Legacy custom charge callbacks remain callable, but new integrations should return
`true, nil, { moneyType, amount, publish? }`, with `publish` used only for optional
post-commit notices. Quotes in one save must use the same currency.

`CONSUMPTION.REQUIRE_OPEN_STATION` in `config/fuel.lua` defaults to `true`. OPX pauses
its own fuel consumption until at least one station has surveyed, enabled points.
This does not change point placement or another resource's fuel loop.

The Lua audits use explicit storage doubles; `tests/economy-sql.py` additionally
executes the actual storage builders against an isolated MariaDB server. CI tests
rollback boundaries, lost replies/replay, concurrent credits, both sides of peer
trades, migrations, crafting queues, clothing and ownership/payout obligations.
Native world effects and two-client acceptance still require an in-game check.

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
| `GetInvoices(src)` (what a loaded player owes) | read |
| `IssueInvoice(issuer, target, amount, reason, { account?, cutPct? }?)`, `CancelInvoice(id)` (only the caller's own bills) | write |

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
(an impound); `opx:on:crafting:ordered` / `collected`; `opx:on:progress:finished`;
`opx:on:invoices:issued` / `paid` / `refused` / `expired` / `cancelled` (a bill an
`IssueInvoice` raised carries `source = 'ext:<caller>'`).
`IssueInvoice` and `CancelInvoice` require a resource name of at most 28 bytes;
longer names return `export.badArgument`. The full name must fit the 32-byte
invoice source so two resources cannot share a truncated ownership prefix.
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

Interaction candidate collection, including stale-owner cleanup and group sorting,
is paced before the target predicate slicer runs. Closing the eye invalidates the
in-flight collection. `tests/audit-target-budget.lua` exercises the full 128-row
registry and checks both ordering and cancellation; the main suite measures the
page callback and its worker resumes. Appearance warnings about missing looks
require an actually nearby player, so joining an empty server is not reported as
failed replication.

Target action and folder labels stay on one line with an ellipsis when space runs
out; their icons and checkbox/count stay aligned in the same heading. Optional
descriptions wrap below that heading.

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

## Image CDN

Inventory, hotbar and garment pictures and their upload scripts live in the
separate [`opx_images`](https://github.com/opx77-framework/opx_images) repository.
All pictures are under its `images/` directory, with garments in
`images/clothing/`. No inventory or garment pictures are bundled in the framework.

1. Clone `opx_images` and install Python 3.10+.
2. From **that repository**, run `bash upload-images.sh` on Linux or
   `upload-images.bat` on Windows. Enter the Fivemanage key when prompted.
   The uploader recursively scans every file under `images/`, uploads new or
   changed content and reuses unchanged uploads. It never saves the key.
3. Set the same account's key in the framework's **server-only**
   `config/images.lua` (`API_KEY`). It is never loaded by a client.
4. Enable Open77's outbound HTTP bridge in `server.jsonc`, preserving any hosts
   already required by your other resources:

   ```jsonc
   "http": {
     "enabled": true,
     "allowedHosts": ["api.fivemanage.com"],
     "timeoutSeconds": 10,
     "maxResponseBytes": 1048576
   }
   ```

5. Restart OPX. Catalogue entries remain file names (`IMAGE = 'water.png'`),
   with no manual URL edits and no framework rebuild.

Both components need a key: `opx_images` uploads, and `opx_infinity` reads the
account catalogue. Players receive only a cached public name-to-URL map. The
server reads all Fivemanage API pages at startup and every five minutes, publishes
only complete snapshots, and keeps the previous catalogue if a refresh fails.
Unchanged snapshots are not resent. No API call is made when opening inventory or
displaying an item. UI delivery uses eight-row packets with a yield between them;
the complete snapshot replaces the visible map atomically.

The uploader records relative names, checksums and upload timestamps in file
metadata. The newest upload wins for duplicate names, independently of API order.
A reverted file is uploaded again if its older content is no longer the active
version. Old CDN files are never automatically deleted. Storage and bandwidth
follow your Fivemanage plan. Keep only image files under `images/`; all its
subdirectories are included, and files above 16 MiB are refused.

Fivemanage setup is required to display these pictures. Without it, or when an
individual picture fails, OPX uses its existing text monograms. There is no local
image mode. Actual account uploads and in-game rendering still need validation
with your own key. Credits are retained in
[`docs/image-attribution.md`](image-attribution.md) and the asset repository.

## Deploying

Over SSH to the test server, then restart, then read the journal back — in the same
change, not later. A green suite says nothing about the running server.

```bash
git archive --format=tar HEAD open77.lua config core lib locales modules web \
  | gzip | ssh root@<host> 'cd /opt/open77-server/resources/opx_infinity && tar xzf - \
  && chown -R open77:open77 . && systemctl restart open77.service'
```

Archive from the **commit**, not the working tree, so what is deployed is what is
recorded. When upgrading the base game, review `simulation.expectedGameBuild`
in the preserved host configuration as well: Cyberpunk 2077 2.5 uses `25000`;
leaving `23100` rejects verified 2.5 clients even with an updated server binary. `opx_lib` must be installed and listed in the server's `resources.load`
before `opx_infinity`, or the platform refuses to start this resource.

Never `DROP DATABASE` — the grants live with it and the server authenticates as a
non-root user. Empty tables instead, and `mysqldump` first.

