--- The bag, the fixed stashes, vehicle storage and the piles on the ground.
-- @author dop42
--
-- The server is the only authority on what a container holds. Every request is
-- revalidated here -- slot, stack, weight, reach, readiness gate, life -- and the
-- screen only ever predicts: it draws a move, and the next push corrects it.
--
-- Three ideas run through the module and are worth having before reading it.
--
-- 1. A CONTAINER IS (KIND, OWNER). The bag of a character is `character` plus its
--    citizen id; an owned vehicle's trunk is `trunk` plus its PLATE, never a
--    runtime vehicle id, which belongs to one spawn and is recycled. A unique key
--    on the pair is what settles two simultaneous creators.
-- 2. A MEMORY-ONLY CONTAINER CARRIES A NEGATIVE ID. Piles and the storage of a
--    vehicle nobody owns are never written, and their ids come from a counter
--    that only ever goes down. A positive id is a row; a negative id is not.
-- 3. THE PAGE SENDS INTENTS. It reports a drag from one slot to another. Whether
--    that is legal, and what the bag then weighs, is decided here.
--
-- WHAT THIS RUNTIME DELETED. The two halves of this system used to live in two
-- resources, and a container was written by staging it across several export
-- calls under a transaction token, because one network argument caps at 48 KiB.
-- In one Lua state that is a function call: `server/storage.lua` writes a
-- container in one transaction and there is no protocol left to get wrong.

local M = OPX.Modules.Declare{
	id = 'inventory',
	side = 'both',
	fatal = false,
	-- Every bag is keyed on a citizen id, and only the character module knows
	-- which character a connection has loaded.
	requires = { 'character' },
	-- `vehicles` proves who owns a plate, `target` draws the pile and vehicle
	-- rows, `downed` says the screen must not be up, `panel` is not used yet and
	-- is declared so that ordering is settled before it is. Each is asked for
	-- with `OPX.Api.Get` and each answer of nil costs one feature, never a fault.
	optional = { 'vehicles', 'target', 'downed', 'panel' },
}

-- The three prefixes are disjoint by construction (see core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` on a
-- NET name would re-enter the handler registered for the wire.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL
local INTERNAL = OPX.Channel.INTERNAL

M.Event = {
	-- Server to client.
	OWN = OPX.Event(NET, 'inventory', 'own'),
	CONTAINER = OPX.Event(NET, 'inventory', 'container'),
	SECONDARY = OPX.Event(NET, 'inventory', 'secondary'),
	NEARBY = OPX.Event(NET, 'inventory', 'nearby'),
	OPEN = OPX.Event(NET, 'inventory', 'open'),
	RESET = OPX.Event(NET, 'inventory', 'reset'),
	USED = OPX.Event(NET, 'inventory', 'used'),
	ARMED = OPX.Event(NET, 'inventory', 'armed'),
	DROPS = OPX.Event(NET, 'inventory', 'drops'),
	DROP = OPX.Event(NET, 'inventory', 'drop'),
	-- The routing bucket the player is in: the client has no read of its own,
	-- and it filters the pile list by it.
	BUCKET = OPX.Event(NET, 'inventory', 'bucket'),
	ANSWER = OPX.Event(NET, 'inventory', 'answer'),
	-- Items another resource registered while the server runs, a few at a time:
	-- `{ { name, owner, definition }, ... }`. See `Catalog.Register`.
	CATALOG = OPX.Event(NET, 'inventory', 'catalog'),
	-- Somebody in reach is handing this player something, and asks first:
	-- `(token, { item, count, side, distance, expiresInMs })`. No name: never a
	-- name to a stranger. `GIVE_WITHDRAWN (token)` takes it down again.
	GIVE_OFFER = OPX.Event(NET, 'inventory', 'giveOffer'),
	GIVE_WITHDRAWN = OPX.Event(NET, 'inventory', 'giveWithdrawn'),

	-- Client to server. Every payload is attacker-controlled; only `source` is not.
	REQUEST = OPX.Event(NET, 'inventory', 'request'),
	HELLO = OPX.Event(NET, 'inventory', 'hello'),
	-- The receiver's answer to a `GIVE_OFFER`: `(token, accepted)`.
	GIVE_ANSWER = OPX.Event(NET, 'inventory', 'giveAnswer'),

	-- The client's own bus, raised after the mirror is updated so a handler
	-- reading it sees the change. Public: a bare AddEventHandler.
	ON_CHANGED = OPX.Event(LOCAL, 'inventory', 'changed'),
	-- Server only, public: what a bag gained and lost, by item name,
	-- `(source, { citizenId, changes = { { name, delta, count } } })`.
	ON_ITEMS = OPX.Event(LOCAL, 'inventory', 'items'),
	ON_USED = OPX.Event(LOCAL, 'inventory', 'used'),
	ON_ARMED = OPX.Event(LOCAL, 'inventory', 'armed'),
	ON_OPENED = OPX.Event(LOCAL, 'inventory', 'opened'),
	ON_CLOSED = OPX.Event(LOCAL, 'inventory', 'closed'),

	-- A character arriving and leaving, which is what opens and closes a bag.
	-- Built here with `OPX.Event` rather than read off the character module's
	-- namespace, which is the thing a contract exists to prevent.
	--
	-- The two halves listen on DIFFERENT CHANNELS, and they are not
	-- interchangeable. The server raises these on the internal bus, between
	-- modules inside one VM; the client raises its own on the local bus, which is
	-- public and which anything may listen to with a bare `AddEventHandler`.
	-- Listening to the wrong one is a handler nothing ever raises.
	IN_CHARACTER_LOADED = OPX.Event(INTERNAL, 'character', 'loaded'),
	IN_CHARACTER_UNLOADED = OPX.Event(INTERNAL, 'character', 'unloaded'),
	IN_CHARACTER_DELETED = OPX.Event(INTERNAL, 'character', 'deleted'),
	ON_CHARACTER_LOADED = OPX.Event(LOCAL, 'character', 'loaded'),
	ON_CHARACTER_UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`, whose channel is core's: without it a client waiting on
-- one of several requests cannot tell which `error.tooFast` is its own.
M.Operation = {
	OPEN = 'inventoryOpen',
	MOVE = 'inventoryMove',
	USE = 'inventoryUse',
	GIVE = 'inventoryGive',
	DROP = 'inventoryDrop',
	TAKE = 'inventoryTake',
	STASH = 'inventoryStash',
	VEHICLE = 'inventoryVehicle',
}

--- The container kinds this module gives meaning to.
-- The tables store any kind at all; only these five mean something here, and
-- `citizen` and `plate` below are the two that must point at something that
-- exists before a row may be created.
M.KIND = {
	CHARACTER = 'character',
	STASH = 'stash',
	TRUNK = 'trunk',
	GLOVEBOX = 'glovebox',
	DROP = 'drop',
}

--- Which column a kind's owner is linked through, for the kinds that have one.
-- A bag names a living character and a vehicle container names an owned plate.
-- A stash and a pile are linked to nothing and may be created freely.
M.LINKED = {
	[M.KIND.CHARACTER] = 'citizen',
	[M.KIND.TRUNK] = 'plate',
	[M.KIND.GLOVEBOX] = 'plate',
}

--- The tunables this module contributes to the operator panel.
-- Declared once, from the server's `Init`; read through `OPX.Tune.Number` at the
-- moment of use and never captured into a file-scope local, which would freeze a
-- live value for the life of the resource.
M.TUNABLES = {
	INVENTORY_SAVE_DELAY_MS = {
		value = 2000,
		type = 'integer', min = 0, max = 600000, step = 500, unit = 'ms', apply = 'live',
		label = 'Container write delay', group = 'Inventory', order = 1,
		description =
			'How long a container stays quiet before it is written back. This is what ' ..
			'bounds how much of an inventory a crash can lose. Zero writes on every ' ..
			'change, which is correct and expensive: a player sorting a full bag writes ' ..
			'forty rows per drag.',
	},

	INVENTORY_RATE_REQUESTS = {
		value = 20,
		type = 'integer', min = 1, max = 1000, step = 1, apply = 'live',
		label = 'Screen requests per window', group = 'Inventory', order = 2,
		description =
			'How many requests one player may send inside the rate window. Every refused ' ..
			'request is still answered, so lowering this makes a fast player wait rather ' ..
			'than leaving their screen stuck on a move that never comes back.',
	},

	INVENTORY_DROP_LIFETIME_MIN = {
		value = 30,
		type = 'integer', min = 1, max = 10080, step = 5, unit = 'min', apply = 'live',
		label = 'Pile lifetime', group = 'Inventory', order = 3,
		description =
			'Minutes an untouched pile survives before it is swept away with everything ' ..
			'in it. Piles are never written to the database, so this is also how long ' ..
			'anything left on the ground can outlive a restart: not at all.',
	},

	INVENTORY_USE_COOLDOWN_MS = {
		value = 750,
		type = 'integer', min = 0, max = 60000, step = 50, unit = 'ms', apply = 'live',
		label = 'Use cooldown', group = 'Inventory', order = 4,
		description =
			'Least time between two uses by one player. It is a fairness limit and not a ' ..
			'security boundary: every use is revalidated whether or not it was waited for.',
	},
}
