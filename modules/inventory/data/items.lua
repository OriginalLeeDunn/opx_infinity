--- The item catalogue: one definition per stored item name.
-- @author dop42
--
-- Data, and nothing else: `shared/catalog.lua` normalises every row once at load
-- and a malformed row becomes a boot warning rather than an error in the middle
-- of a request. MODEL is optional and draws a pile made for that item, and it is
-- a CURATED `Open77.props` alias. NOT a depot path: the API accepts a raw
-- `.mesh`, but the renderer matches a prebuilt host per alias, so the mesh draws
-- as a marker AND suppresses the crate fallback -- an id came back, so nothing
-- looks wrong anywhere. `shared/catalog.lua` refuses one at load.
--
-- EVERY DROPPABLE ITEM NAMES ONE, and it is the NEAREST thing the platform hosts,
-- not the item's own geometry: the alias table is compiled into the client and a
-- resource cannot add to it (see the note in data/weapons.lua). The food, drink and
-- medical aliases are named after the game's own decoration families -- packaged
-- drinks, soda cans, synthetic snacks, medical containers, all hand-sized when
-- measured with WolvenKit in the 2.31 archives -- so those read as what they are.
-- The rest are stand-ins and say so: no alias is a phone, a card, a shard or a key
-- fob, so the phone and the electronics draw the small screen terminal, scrap the
-- scrap heap, and the three tiny valuables the loot crate. `eddies` cannot be
-- dropped and names none. `tests/run.lua` checks every MODEL against the generated
-- `tests/prop-aliases.lua`.

local M = OPX.Modules.Get('inventory')

M.Data = M.Data or {}

M.Data.ITEMS = {
	water = {
		WEIGHT = 500, CATEGORY = 'drink', MODEL = 'food.drink_packaged',
		USE = { STATUS = { thirst = 35 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	nicola = {
		WEIGHT = 330, CATEGORY = 'drink', MODEL = 'food.soda_can',
		USE = { STATUS = { thirst = 25 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	coffee = {
		WEIGHT = 300, CATEGORY = 'drink', MODEL = 'food.drink_packaged',
		USE = { STATUS = { thirst = 15 }, ANIMATION = { NAME = 'drink', DURATION_MS = 3000 } },
	},
	-- Open77 ships no eating profile: food plays the drink profile's first hand-to-mouth clip.
	burrito = {
		WEIGHT = 350, CATEGORY = 'food', MODEL = 'food.street_food',
		USE = { STATUS = { hunger = 35 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},
	chips = {
		WEIGHT = 150, CATEGORY = 'food', MODEL = 'food.snack',
		USE = { STATUS = { hunger = 12 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},
	kibble = {
		WEIGHT = 250, CATEGORY = 'food', MODEL = 'food.snack',
		USE = { STATUS = { hunger = 20 }, ANIMATION = { NAME = 'drink', VARIANT = 1, DURATION_MS = 3000 } },
	},

	bandage = { WEIGHT = 60, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },
	bounce_back = { WEIGHT = 120, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },
	maxdoc = { WEIGHT = 200, CATEGORY = 'medical', MODEL = 'medical.container', USE = { CONSUME = 1 } },

	scrap_metal = { WEIGHT = 400, CATEGORY = 'material', MODEL = 'garbage.industrial_trash' },
	electronics = { WEIGHT = 150, CATEGORY = 'material', MODEL = 'electronics.monitor.device' },
	lockpick = { WEIGHT = 50, CATEGORY = 'tool', MODEL = 'container.toolbox' },

	-- A loaded hauling crate: `config/hauling.lua` ITEM. Ten kilos, so a trunk
	-- (80 kg) takes eight and a bike's a third of that.
	hauling_crate = { WEIGHT = 10000, CATEGORY = 'material', MODEL = 'crate.small' },

	phone = { WEIGHT = 180, STACK = false, MODEL = 'electronics.monitor.device' },
	id_card = { WEIGHT = 10, STACK = false, MODEL = 'crate.valuable' },
	shard = { WEIGHT = 20, MODEL = 'crate.valuable' },

	-- THE KEY TO ONE PRECISE VEHICLE. What it opens is in its metadata, never in
	-- its name: `{ plate = '<PLATE>', label = '<model> · <PLATE>' }`, written by
	-- `modules/vehiclekeys` and nothing else, so two keys are two stacks and the
	-- screen draws each one under its own label.
	--
	-- STACK = false because two keys to two cars must never merge, and two keys
	-- to ONE car are still two things somebody can hand to two people. USE with
	-- CONSUME = 0 because pressing a key fob does not use it up: the handler the
	-- keys module registers locks or unlocks the vehicle and gives the key back.
	-- CLOSE = false so the toast that says what happened is read over the bag.
	vehicle_key = {
		WEIGHT = 20, CATEGORY = 'tool', STACK = false, MODEL = 'crate.valuable',
		USE = { CONSUME = 0, CLOSE = false },
	},

	-- THE KEY TO ONE PRECISE DOOR, the same idea as `vehicle_key`: what it opens
	-- is its metadata, `{ door = '<door key>', label = '<door name>' }`, written
	-- by `modules/doorlock` (`/opx.doorlock.key`) and nothing else. A door that
	-- lists `{ NAME = 'door_key', BOUND = true }` opens for a key carrying its
	-- own key and for no other. No USE: a key turns a door from the eye or the
	-- interaction key at the door, and the bag has nothing to add to that.
	door_key = { WEIGHT = 20, CATEGORY = 'tool', STACK = false, MODEL = 'crate.valuable' },

	-- MONEY YOU CAN HAND OVER. One unit is one eddie, and the stack is a BEARER
	-- NOTE drawn against the EDDIES balance: `/withdraw` debits the balance and
	-- puts the units here, using the stack destroys it and credits the balance
	-- back. See `CURRENCY` in config/inventory.lua for why it is a note and not
	-- the money itself.
	--
	-- Three fields here are load-bearing and none of them is a taste decision.
	--
	-- WEIGHT = 0, because weight is the one limit that can refuse HALF a move.
	-- `Containers.Move` splits a stack across slots, and a bag that fills up
	-- mid-transfer would leave a give or a deposit partly done with money on
	-- both sides of it. Slots still bound what anyone can carry, and a slot
	-- either takes the stack or does not. It is also the honest reading: an
	-- eddie is a number on a chip and a million of them weigh what one does.
	--
	-- USE with CONSUME = 0, because the CONSUME the catalogue performs happens
	-- AFTER the handler has returned, and a consume that failed there would
	-- have credited the balance and left the notes in the bag -- money minted,
	-- once per failure. `server/currency.lua` takes the units out ITSELF, before
	-- it credits anything, so the only failure left destroys nothing and mints
	-- nothing. The entry exists at all because it is what makes the screen draw
	-- a Use row for the stack.
	--
	-- DROP = false, because a pile on the ground is MEMORY ONLY: it is swept
	-- after DROPS.LIFETIME_MINUTES and nothing about it survives a restart. Any
	-- other item dropped and lost is an item; this one is somebody's wages,
	-- deleted with no line anywhere saying so. An operator who wants cash that
	-- can be robbed off the floor deletes this one word and accepts that.
	eddies = {
		WEIGHT = 0, CATEGORY = 'money', DROP = false,
		USE = { CONSUME = 0, CLOSE = false },
	},
}
