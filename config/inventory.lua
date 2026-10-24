--- The bag, the containers in the world, the keys and who may run the commands.
-- @author dop42
--
-- Shared: both halves read this. The client needs the keys, the tabs and the
-- reach it draws prompts at; the server needs everything, and re-derives every
-- limit the client thinks it knows.
--
-- Nothing here is trusted as written. `modules/inventory/shared/common.lua`
-- reads it once at load and resolves every value a calculation or a lookup is
-- made on, so a mistyped entry is a warning in the boot log and a fallback,
-- never an error raised in the middle of a request.

OPX.Config.MODULES.inventory = {
	enabled = true,

	-- A new character's bag. An existing bag keeps the size it was created with:
	-- the size only ever reaches the database through the row that creates it.
	BAG = { SLOTS = 40, MAX_WEIGHT = 30000 },

	-- Grams per unit for a stored item the catalogue no longer carries. A stack
	-- of something that has been removed from data/ still weighs something, or a
	-- deleted item would be a free way to carry anything.
	DEFAULT_ITEM_WEIGHT = 100,

	-- Most units one slot holds of a stackable item, and the ceiling on one
	-- stack's encoded metadata.
	MAX_STACK = 1000000,
	MAX_METADATA_BYTES = 1024,

	-- Metres, measured server-side and only server-side.
	REACH = {
		-- To a stash, a pile, or another player.
		DISTANCE = 3.0,
		-- From a vehicle's centre to its trunk, which is not its centre.
		VEHICLE = 4.5,
	},

	-- Bag slots a key uses straight, without opening the screen.
	-- PEEK_MS is how long the peek key holds the hotbar row on screen. The row
	-- exists because the hotbar keys work with the bag SHUT, which is the point
	-- of them and also the problem: nothing says what they are bound to until
	-- you open the bag, by which time you did not need the key.
	HOTBAR = { ENABLED = true, SLOTS = 5, PEEK_MS = 4000 },

	-- Defaults a player rebinds in the pause menu. `false` registers no mapping
	-- at all, which is how an operator turns a key off.
	KEYS = {
		OPEN = 'I',
		HOTBAR = { '4', '5', '6', '7', '8' },
		-- Shows the hotbar row for PEEK_MS and nothing else: it uses nothing,
		-- takes no focus and cannot be clicked. `false` turns it off.
		--
		-- NOT `TAB`, AND THAT IS THE WHOLE REASON THIS COMMENT EXISTS. It was,
		-- and the key did nothing in game. The path was traced end to end on
		-- 2026-09-21 and every step of it is sound: `TAB` is in the platform's
		-- own bindable vocabulary, `keyName` accepts it, `Options.KEY_PEEK`
		-- carries it, the mapping is registered, and the peek's own refusals --
		-- which relay to the server journal through `OPX.Note` -- were never
		-- written once. The press never reached Lua at all.
		--
		-- Which the key guide explains: a binding "never fires while another
		-- WebUI owns keyboard focus", and `TAB` is Cyberpunk's own quick menu.
		-- The game takes the keyboard on that press, so the binding is
		-- suppressed. The same guide says it in one line: "choose keys that do
		-- not clash with an in-world action."
		--
		-- `Y` is the replacement and it is a judgement call, not a measurement:
		-- it is free on a default Cyberpunk layout as far as I can tell, and a
		-- player who disagrees rebinds it in Pause -> Settings -> KEY BINDINGS,
		-- where the choice follows them to every server.
		PEEK = 'Y',
	},

	-- Least time between two uses by one player, and how long a use handler has
	-- to answer before the use is refused.
	USE_COOLDOWN_MS = 750,
	USE_HANDLER_MS = 5000,

	-- Screen requests one player may send per window. A refused request is still
	-- answered, so the page settles what it is waiting on instead of hanging
	-- until its own timeout.
	RATE_LIMIT = { WINDOW_MS = 1000, REQUESTS = 20 },

	-- Deferred writes. A container is written DELAY_MS after its last change,
	-- BATCH containers to a transaction, looked for every SWEEP_MS.
	SAVE = { DELAY_MS = 2000, SWEEP_MS = 1000, BATCH = 16 },

	-- Piles on the ground. They are memory-only containers: nothing about a pile
	-- survives a restart, which is why LIFETIME_MINUTES is short.
	DROPS = {
		ENABLED = true,
		SLOTS = 25,
		LIFETIME_MINUTES = 30,
		MAX = 200,
		MAX_PER_CHARACTER = 10,
		COOLDOWN_MS = 1000,
		-- A drop this close to an existing pile joins it instead of making one.
		DISTANCE = 1.5,
		-- A curated Open77.props alias, drawn for a pile whose item has no MODEL.
		MODEL = 'crate.small',
		-- Metres within which a pile registers a target sphere.
		PROMPT_RADIUS = 20.0,
	},

	-- Vehicle storage. SLOTS at 0 gives that vehicle no storage at all.
	TRUNK = { SLOTS = 30, MAX_WEIGHT = 80000 },
	GLOVEBOX = { SLOTS = 10, MAX_WEIGHT = 10000 },

	-- WHO MAY OPEN A BOOT THAT BELONGS TO SOMEBODY. `true` is the owner and
	-- nobody else; `false` is anyone who can stand next to it.
	--
	-- This is a server decision and not a rule of the runtime, which is why it is
	-- here. It defaults to the closed answer because the open one is a surprise:
	-- until now the only checks were 4.5 metres and "not sitting in it", so a
	-- stranger could empty a parked, owned car. There is no lock in the vehicles
	-- module to consult and no lockpicking to reward, so the choice is binary
	-- today -- a server that wants theft should turn this off deliberately rather
	-- than inherit it.
	--
	-- A vehicle nobody owns is unaffected: its storage is transient and open to
	-- whoever reaches it. The GLOVEBOX is unaffected too, and that is deliberate:
	-- it opens only while SEATED, so a passenger in a friend's car has already
	-- been let in.
	TRUNK_OWNER_ONLY = true,

	-- A record carrying one of these fragments is a two-wheeler: no glovebox,
	-- and a trunk divided by TRUNK_DIVISOR.
	BIKES = { PATTERNS = { 'sportbike', '_bike_' }, TRUNK_DIVISOR = 3 },

	-- Fixed stashes. NAME is the storage key and must never be reused for
	-- somewhere else: it is what the row is keyed on.
	STASHES = {},

	-- Weapons drawn from the bag. SLOT is the game weapon slot an inventory
	-- weapon occupies; REMOVE_UNBACKED takes off any weapon no bag item backs.
	WEAPONS = {
		ENABLED = true,
		SLOT = 1,
		-- Open77 op77.152+: the left hand uses SLOT + 3.
		DUAL_WIELD = true,
		REMOVE_UNBACKED = true,
		SCAN_MS = 5000,
		AMMO_SYNC_MS = 2000,
	},

	-- Players the screen offers to hand something to, and how often that list is
	-- refreshed while the screen is open.
	NEARBY = { MAX = 4, SCAN_MS = 1000 },

	-- Category tabs over the grid, in order. REST takes every category no other
	-- tab names, so nothing can be carried and be unreachable.
	TABS = {
		{ KEY = 'all' },
		{ KEY = 'weapons', CATEGORIES = { 'weapon', 'ammo' } },
		{ KEY = 'food', CATEGORIES = { 'food', 'drink' } },
		{ KEY = 'medical', CATEGORIES = { 'medical' } },
		{ KEY = 'materials', CATEGORIES = { 'material', 'tool' } },
		{ KEY = 'misc', REST = true },
	},

	-- EDDIES AS A THING YOU CAN HAND OVER, and the one piece of configuration
	-- here that can mint money if it is wrong.
	--
	-- THE BALANCE STAYS THE SINGLE AUTHORITY and the item is a BEARER NOTE drawn
	-- against it: withdrawing debits MONEY_TYPE and puts that many units of ITEM
	-- in the bag, and using the stack destroys it and credits the balance back.
	-- Nothing SPENDS the item -- a shop, a dealership and a garage all read the
	-- balance and none of them reads a bag -- so a note sitting in a bag, a boot
	-- or a stash is money that is out of circulation until somebody deposits it,
	-- and is never spendable twice. That is the whole reason the item is not
	-- itself the money: the alternative makes every existing reader of the
	-- balance wrong on the day a player leaves their wages in a car.
	--
	-- ITEM must be a real row in data/items.lua and MONEY_TYPE a real key of
	-- `OPX.Config.SHARED.MONEY.TYPES`. Either one wrong turns the bridge OFF
	-- with a boot warning rather than half-wiring it: a withdraw that debits
	-- into an item nothing can deposit is money destroyed on the first use.
	--
	-- MAX_WITHDRAW bounds ONE withdraw and not what anybody may hold, so that a
	-- fat-fingered amount is a refusal rather than a bag full of notes.
	CURRENCY = {
		ENABLED = true,
		ITEM = 'eddies',
		MONEY_TYPE = 'EDDIES',
		MAX_WITHDRAW = 1000000,
	},

	-- Largest count one staff command accepts.
	MAX_COMMAND_COUNT = 10000,

	-- WHAT A MEDICAL ITEM HEALS, as a percentage of the player's maximum health,
	-- applied at once on the server through the platform's health natives. An item
	-- named here is refused at full health and while down (none of these revives),
	-- and is consumed only when the heal landed. An item not named here heals
	-- nothing; its own USE block still decides whether it can be used at all.
	HEALING = {
		bandage = 15,
		bounce_back = 40,
		maxdoc = 75,
	},
}
