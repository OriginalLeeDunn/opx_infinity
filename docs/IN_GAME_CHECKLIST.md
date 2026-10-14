# In-game checklist

Checks the offline suite cannot make: they depend on how a live client and server
answer natives the stub host only imitates. Run them on the test server with two
clients where noted, tick the boxes in a PR that edits this file, and note the
builds used.

**How to report a failure.** Open a `bug` issue with: the section below, the client
and server builds (`2.x.y+op77.N`), the step that failed, what you saw, the matching
client log (`%LOCALAPPDATA%` client log) and server console lines, and a screenshot
when it is visual. One defect per issue.

Builds used for the last full run:

- Server: _not run yet_
- Client: _not run yet_

---

## 1. Door locks: Pick in world, double doors, holdOpen, ACL

From #102 (port of ox_doorlock, #80). Panel: `/opx.doorlock`; ids: `/opx.doorlock.list`;
use key `E` (`opx.doorlock.use`).

**Boot.** Server console must show one of:

```
[doorlock] ready: <n> door(s), <n> refused, backend local
[doorlock] ready: <n> door(s), <n> refused, backend networked, <n> adopted
```

and never `[doorlock] BACKEND = 'networked' but open77_doors is not running ...`
unless that is the configuration under test.

**Pick in world**

- [ ] In `/opx.doorlock`, new door, **Pick in world**: the panel hides and the strip reads *Aim at door 1/1* (*Visez la porte 1/1*).
- [ ] Aiming at a door turns the strip into *Take door 1/1 (…xxxxxx)*; `E` takes it, the panel comes back with the native id filled. Do it on a **single**, a **double** and an **automatic** door.
- [ ] Double door: the strip asks *1/2* then *2/2*; each leaf is a different native id.
- [ ] Aiming at a lift door and pressing `E` refuses with *A lift door belongs to its lift.*
- [ ] Aiming at a leaf another door already manages refuses with *That native door already belongs to ...*
- [ ] *Confirm door* on a door with no leaf starts the same pick step.
- [ ] Escape cancels and restores the panel unchanged.
- Client log to watch: `[doorlock] <code>: <name>` (refusal reasons) and `[doorlock] the strip row was refused: ...` (must not appear).

**Double doors**

- [ ] After saving a double door, its `coords` lie between the two leaves (check with `/opx.admin.self.pos` standing at each leaf).
- [ ] The strip row appears at the midpoint, and `E` turns the door from either leaf within `maxDistance`.

**holdOpen**

- [ ] `BACKEND = 'local'`: a door with *Hold open* stays open while unlocked, closes and locks again when locked (both clients see it).
- [ ] `BACKEND = 'networked'` (needs `open77_doors`, see [PLATFORM_REQUESTS.md §4](PLATFORM_REQUESTS.md#4-open77_doors-without-open77_elevators)): same result; an automatic door does not reopen on proximity while held. Server must show no `[doorlock] door <id>: native <id> did not unlock: ...` line.

**ACL**

- [ ] Give a test role the ACL entry `doorlock.<id>` for one door: that role opens that door and gets *Your role cannot do that.* / a locked answer on every other door.

---

## 2. Animations: duo emotes with a walking profile

From #103 (duo emotes, #87, through `Open77.playerInteractions`). Two clients
standing next to each other. Picker `F3`, stop `X`, commands `/opx.anim`, `/e`,
`/opx.anim.stop`.

**Boot.** Server must show `[animations] ready: ...` and **not**
`[animations] Open77.playerInteractions is unavailable ...`.

- [ ] Player A: `F3` → *With a nearby player* → *Any two animations*, pick a walking profile (e.g. `smoke_walk`) for A and a stationary one for B. B accepts.
- [ ] Same with walking profiles on both sides.
- [ ] Result: the pair either plays stationary or ends for **both** players with a readable notice. Never one body left frozen in a pose.
- [ ] *Carry them* and *Escort them*: both players move together as described (*You carry them and can walk; they follow.*).
- [ ] `X` on either side ends carry / escort / custom for both.
- Server log to watch: `[animations] <kind> pair for <a> and <b> refused: <reason>`; a profile override on carry/escort answers `paired_animation_fixed` (shown as *Emotes with another player are unavailable right now.*).
- [ ] **Decision to record here:** if the coordinator behaves differently from its guide, either hide walking profiles from the duo picker or document what happens.

---

## 3. Loading cover during in-play loads

From #104 (#62). **Blocked** until a client ships `Open77.screen.loadingState`
(see [PLATFORM_REQUESTS.md §2](PLATFORM_REQUESTS.md#2-native-loading-state-api)).

**Client log on join**, one of:

```
[loading] reading the native loading lifecycle through loadingState
[loading] reading the native loading lifecycle through isLoading (no progress, no kind)
[loading] this client has no Open77.screen.loadingState; the views keep their own visibility during loads
```

Must not appear: `[loading] the loading state was refused: permission_denied:screen.read`
(means `screen.read` is missing from `open77.lua`), or repeated
`[loading] the loading state could not be read: <why>`.

- [ ] With the HUD on: a teleport, a lift ride and a respawn each hide the OPX views during the load and bring them back after.
- [ ] Turn the HUD off, repeat: it stays off afterwards (the player's choice survives).
- [ ] The cover draws over (or cleanly under) the native loading screen. Attach a screenshot.
- [ ] Record the `kind` reported for each: teleport `____`, lift `____`, respawn `____`; confirm the module's handling matches.
- [ ] On a client **without** the API: only the "has no Open77.screen.loadingState" line, no change in behaviour.

---

## 4. Inventory: side and distance in the give list

From #105 (#91, #101). Two clients, inventory `I`. Distances are server-measured;
reach is `REACH.DISTANCE = 3.0` m plus slack (`config/inventory.lua`).

- [ ] Player B stands still ~1.5 m in front of A. A turns **right** in place by quarter turns and opens the give list each time: B's row reads *In front of you* → *To your left* → *Behind you* → *To your right*.
- [ ] Same in French: *Devant vous* → *À votre gauche* → *Derrière vous* → *À votre droite*, decimal comma (`1,2 m`).
- [ ] The distance shown matches what the players see (within reach slack).
- [ ] B's offer card (*SOMEBODY HANDS YOU SOMETHING*) shows `<side> · <distance> m` from B's point of view and **never a name**.
- [ ] If left and right are swapped, the fix and a regression test land in the same PR (the yaw convention is the player snapshot heading, same as `World.Ahead`).

---

## 5. Inventory: Bandage, Bounce Back, MaxDoc

From #106 (#96). `HEALING` in `config/inventory.lua`: `bandage` 15 %, `bounce_back` 40 %, `maxdoc` 75 % of max health.

Setup (staff): `/opx.inventory.give <id> bandage 3`, same for `bounce_back`, `maxdoc`;
lower health with `/opx.admin.player.health <id|me> <points>`; `/opx.admin.self.heal` to reset.

- [ ] At low health, each item raises health by its share of max health, read back on the HUD vitals. Note max health: `____`.
- [ ] At full health: *You are already at full health.*, the item stays in the bag.
- [ ] While downed: *Not while you are down.*, the item stays in the bag.
- [ ] Owner: the values feel right against weapon damage on the test server. Confirmed / changed to: `____`.

---

## 6. Shops: fitting room price, billing, share codes

From #107 (#96, #101). Two clothing shops with different prices, e.g. `jinguji`
(defaults) and `thrift_watson` (own `PRICES`). Prices per changed slot in
`config/shops.lua`.

**Boot.** Server shows `[shops] <n> shop(s) and <n> ready-made look(s); charging is ...`.

- [ ] Change rack pieces: the status line *On Save: <total>* equals the *Paid <total> at <shop>.* toast and the balance drop. In both shops.
- [ ] Pick a uniform: added once to *On Save*, charged once by the save that keeps it.
- [ ] Wear a share code (*Wear a shared outfit*): billed slot by slot at **this** shop's prices; *On Save* equals *Paid*.
- [ ] Cancel after trying pieces: nothing charged, previous look restored.
- [ ] With too little money: refused on save with *You cannot afford that: <total> needed.*, previous look kept.
- [ ] A long browse (5+ min) then save: never a bare *Your outfit was not saved.* without a reason the player understands.
- Server log to watch: `[shops] the fitting room at <shop> was refused for player <id>: <why>`.

---

## 7. Fuel: the burn, the engine cut, a pump, the can, the gauge

From the ox_fuel port (`modules/fuel`, `config/fuel.lua`). **Survey a station first**: every
shipped station is a placeholder and is disabled. Stand on a real Night City forecourt,
`/opx.fuel.capture test_station Test`, then at two pumps `/opx.fuel.capture test_station pump`;
paste the printed lines into `STATIONS` and restart. Staff need `command.opx.fuel.*`.

**Boot.** Server shows `[fuel] 5 station(s) disabled until surveyed (/opx.fuel.capture): ...`
before the survey, and no `[fuel] config:` line after it. `/opx.fuel.stations` lists the
surveyed station and `burning: this module` (or `open77_fuel` when that resource runs).

- [ ] Drive a car for a minute: the dial's *FUEL* line drops; idling drops it far slower; engine off, it does not move.
- [ ] `/opx.fuel.set near 1`, drive: at 0 the engine stops; starting it again stops it again within a second or two. Server: no `[fuel] burning ...` error line.
- [ ] An AV shows no *FUEL* line and is never cut.
- [ ] At a pump on foot with the car beside it: the strip reads *Refuel (<price>/L)*; `E` (and the eye's *Use the pump*) opens the menu; *Start fueling › Pay cash* puts up a bar and the gauge rises while it runs.
- [ ] Let it finish: *Fueled to 100% - <cost>*, the cash drop equals the cost. Again with *Pay by bank*: the bank drops, not the cash.
- [ ] Cancel the bar half-way (`X`): a partial fill, billed for what went in.
- [ ] Walk away, or have a second player drive the car off, mid-pour: the pour stops and bills what went in.
- [ ] From the driver's seat: *Leave the vehicle to be able to start fueling*.
- [ ] *Buy a fuel can*: a 5 s bar, then a *Fuel can* in the bag with a full wear bar. Away from any pump, use it beside the car (bag or the eye's *Refuel with the fuel can*): the tank rises, the can's bar empties. *Refill a fuel can* at a pump fills it again.
- [ ] Put an owned car away at a garage with a part-full tank, take it out: same level.
- [ ] Map: the station's pin (`drop_point` sprite) is on the minimap and the fullscreen map.
- [ ] With `open77_fuel` also running: tanks burn at one rate, not two, and a refuel still lands.
- Server log to watch: `[fuel] ...` refusals and `fuel.refuel` / `fuel.can` audit lines.
