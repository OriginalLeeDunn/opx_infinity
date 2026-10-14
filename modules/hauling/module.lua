--- Hauling: server-owned crates, contested by everyone who can see them.
-- @author dop42
--
-- Crates stand at surveyed points. Every player in the site's bucket sees THE
-- SAME crates, because the server owns them: it creates them, it decides who got
-- one, and it puts them back when a carry ends badly. A player claims a crate,
-- carries it, loads it into a vehicle (where it becomes a trunk item), drives it
-- to a drop-off and sells it to the NPC there. A scheduler refills the points. The ALT
-- target eye on a crate is the entire entry to the job.
--
-- A PROP AND NOT A LOOT DROP, and the reason is one sentence: a loot drop cannot
-- be attached to anything. `Open77.loot.*` would have given a free vanilla prompt
-- and a pickup that is atomic by contract -- both real advantages, and both worth
-- less than "load it into the car", which is the brief. So `world.props`, which
-- this resource already declares at `open77.lua:479`, and
-- `players.animations.control` for the carry pose, and `world.npcs` for the
-- sellers standing on the drop-offs.
--
-- WHERE THE RACE IS WON AND LOST. Two players ALT the same crate in the same
-- tick. The server Lua runtime is single-threaded and coroutines interleave only
-- at a yield, so a read-then-write with nothing yielding between them is atomic
-- -- but that is an invariant of the RUNTIME, not of the code, and it is invisible
-- at the call site. One inserted `Wait`, one `:await()`, one `Open77.database`
-- call, one `Open77.world.groundZ` (which round-trips to a client), and two
-- players hold the same crate with nothing in the log to say so.
--
-- So the claim is one function, alone in `server/claim.lua`, whose body is Lua
-- table arithmetic and nothing else, with the rule written above it. Everything
-- expensive -- positions, reach, buckets, the revision read -- happens before it
-- or after it and never inside. It is backed by the platform's own
-- compare-and-swap: the prop's `revision` is read before the claim and handed to
-- `Open77.props.attach` as `expectedRevision`, so a binding that raced ours is
-- refused before any mutation happens.
--
-- CLAIMS EXPIRE, which neither shipped example does. Both release a claim only
-- on disconnect, so a player who claims and never finishes freezes a crate for
-- everybody for the life of the process -- and on a four-point site that is a
-- quarter of the job gone to somebody who alt-tabbed. The refill pass reaps.
--
-- `character` is required: a delivery that cannot be paid is not a job.
--
-- `target` IS THE ENTIRE ENTRY -- there is no command and no key -- and it is
-- still listed as OPTIONAL rather than required, which looks wrong and is not.
-- `modules/target` declares `side = 'client'`, so on the dedicated server it
-- rests in state `absent`; a hard `requires` on it would therefore mark THIS
-- module `unavailable` on the server, and the server half is where the crates
-- live. Optional gets the ordering -- the eye is registered before this module
-- starts -- without condemning the half that does not need it. The client half
-- says so once and stops when the contract is missing, which is the honest
-- failure: no rows, and a line saying why.
--
-- `progress`, `inventory` and `animations` are optional for ordinary reasons:
-- without the first the bars are invisible and the server still holds the clock,
-- without the second nothing asks whether a player has room, and without the
-- third nobody mimes carrying anything. `vehicles` and `vehiclekeys` are what
-- prove a truck at a drop-off is the seller's own or keyed to them; without
-- both, the inventory's TRUNK_OWNER_ONLY rule is the only gate on a sale.

local M = OPX.Modules.Declare{
	id = 'hauling',
	side = 'both',
	-- A server with no hauling job is a server missing a job. Nothing else in
	-- this runtime reads from it.
	fatal = false,
	requires = { 'character' },
	optional = { 'target', 'progress', 'inventory', 'animations', 'vehicles', 'vehiclekeys' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (`core/shared/channels.lua`):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection
	-- and never from the payload.
	HELLO = OPX.Event(NET, 'hauling', 'hello'),
	BEGIN = OPX.Event(NET, 'hauling', 'begin'),
	FINISH = OPX.Event(NET, 'hauling', 'finish'),
	ABORT = OPX.Event(NET, 'hauling', 'abort'),
	-- The carrier puts the crate down where they stand. Payload: their yaw.
	DROP = OPX.Event(NET, 'hauling', 'drop'),

	-- Server to client.
	SNAPSHOT = OPX.Event(NET, 'hauling', 'snapshot'),
	CRATE = OPX.Event(NET, 'hauling', 'crate'),
	GONE = OPX.Event(NET, 'hauling', 'gone'),
	RUN = OPX.Event(NET, 'hauling', 'run'),
	ANSWER = OPX.Event(NET, 'hauling', 'answer'),
	-- The seller NPCs: a list of `{ npc, site, dropoff }`, npc a decimal string.
	SELLERS = OPX.Event(NET, 'hauling', 'sellers'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'hauling', 'decision'),

	-- The public SERVER bus, for other resources: a delivery was sold and paid.
	-- Raised by the server only, `(player, { ... })`; see
	-- `core/server/publish.lua` and docs/MANUAL.md "For creators".
	ON_SOLD = OPX.Event(LOCAL, 'hauling', 'sold'),
}

--- The three things a player can be part-way through, and the one thing they can
--- be holding. Named here rather than spelled at each site, because the server
--- indexes the clock by the step and a typo would read as "no bar is running".
--- How long the platform's `carry_pickup` clip runs: its one clip,
--- `enter_bodycarry_sync_upperbody`, is 1333 ms in `open77_animations`' catalogue.
--- The server starts the carry loop after it; the client offers X only after it,
--- so the lift is never cut off half way.
M.LIFT_MS = 1333

M.Step = {
	PICKUP = 'pickup',
	LOAD = 'load',
	DELIVER = 'deliver',
}

--- Where a crate is. A closed set: the refill pass, the reap pass and the target
--- row all branch on it, and a fourth value invented at a call site would be
--- invisible to all three.
M.Where = {
	-- On its point, unclaimed. The only state the eye offers a pickup on.
	GROUND = 'ground',
	-- Reserved by a claim, bar running, still physically on its point.
	CLAIMED = 'claimed',
	-- Attached to a player.
	CARRIED = 'carried',
	-- There is no fourth: a loaded crate is no longer a crate. It leaves the world
	-- and becomes an item in the vehicle's trunk (`config/hauling.lua` ITEM).
}

--- The host raises this when a prop this module owns loses or changes a binding.
-- The AUTHORITATIVE "the carry ended": the platform detaches automatically on
-- death, disconnect, parent removal and bucket change, and none of those four
-- reaches this module any other way. Payload is `(id, current, previous, reason,
-- revision)`; `current` nil means the prop is loose.
M.PROP_ATTACHMENT_CHANGED = 'onPropAttachmentChanged'

--- The host raises this when a prop is dropped from the registry.
M.PROP_REMOVED = 'onPropRemoved'

--- The host raises this when a player gets into a vehicle.
-- ENTERING A VEHICLE IS NOT IN THE PLATFORM'S AUTOMATIC DETACH LIST -- death,
-- disconnect, parent removal and bucket change are, and a seat is none of them.
-- So a carrier who simply gets in the car keeps the crate stuck to their chest
-- inside the cabin, and the load action -- which is the intended route into the
-- vehicle, and the thing that puts the crate in the bed where everyone can see
-- it -- is bypassed. The server half forbids it explicitly.
M.PLAYER_ENTERED_VEHICLE = 'onPlayerEnteredVehicle'
