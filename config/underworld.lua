--- Underworld: dirty money, the black market, drug labs, drugs, store robberies,
--- laundering and street deals.
-- @author dop42
--
-- NIGHT CITY RUNS ON TWO CURRENCIES. Clean eddies sit in a bank and a balance;
-- DIRTY eddies are a stack of untraceable cred-chips in a bag (`DIRTY.ITEM`),
-- and nothing in this resource turns one into the other except a front that
-- launders it (LAUNDERING) at a loss and on a clock. A robbery and a fence pay
-- dirty; a black-market dealer takes dirty at face value and clean only at a
-- premium; a front washes dirty into BANK. That one rule is what makes a crime
-- a crime here: the money it makes is visibly money that came from somewhere.
--
-- EVERY TABLE IS A LIST OF ENTRIES, several of each shipped, and every entry
-- is keyed by its `ID` (what the database rows and the commands name -- never
-- rename one that has been played). A POSITION OF 0, 0, 0 IS "NOT SURVEYED
-- YET": the entry is disabled at boot and named once in the journal, the rule
-- `config/hauling.lua` follows. Stand where the thing belongs and run
-- `/opx.underworld.capture <kind> <id>` to print the line to paste.
--
-- WHO MAY: `GANGS = { tygerclaws = 0 }` (name -> minimum grade, from
-- `config/character.lua` GANGS) and `JOBS = { fixer = 1 }` on any entry. Either
-- list lets a character in; an entry with neither is open to anyone. The
-- decision is `OPX.JobGate.EvaluateGroups` (`lib/shared/jobgate.lua`), the same
-- one a door or a lift asks.
--
-- POLICE: nothing here drives the game's own wanted level (NPC cops are local
-- to each client on this platform, so a vanilla star would be a different
-- story on every screen). An alarm reaches the players on duty in POLICE.JOBS,
-- or a `police` module's `Report` when one exists.

OPX.Config.MODULES.underworld = {
	enabled = true,

	-- ── who, and how often ────────────────────────────────────────────────

	-- `primary`: only the gang/job the character runs with counts. `any`: every
	-- membership counts for the grade. The same two words as config/gunsmith.lua.
	MEMBERSHIP = 'primary',
	-- Past this age a server-side snapshot of a character's groups is not
	-- trusted (it is read fresh on every request, so this only guards a clock).
	JOB_MAX_AGE_MS = 60000,

	-- Metres from a counter, a front, a lab or a dealer a request is accepted
	-- from, measured by the server. An entry may name its own REACH.
	REACH = 2.5,

	-- Every request a client sends goes through one window per player: at most
	-- REQUESTS in WINDOW_MS, the rest answered `too_fast`.
	RATE_LIMIT = { WINDOW_MS = 10000, REQUESTS = 8 },

	-- The jobs that count as police for MIN_POLICE and that hear an alarm.
	POLICE = {
		JOBS = { ncpd = 0, maxtac = 0 },
		-- Only those clocked in count and hear.
		ON_DUTY = true,
		-- How long an alarm's pin stays on an officer's map, in seconds.
		BLIP_SECONDS = 90,
	},

	-- What an alarm does when an entry names no ALERT of its own.
	--   CHANCE          0..1, whether there is an alarm at all
	--   DELAY_MS        { min, max }: how long after the act it goes off
	--   WITNESS_CHANCE  0..1, whether the report carries a position at all
	--   BLUR_RADIUS     metres: the reported position is somewhere this close
	ALERT = { CHANCE = 0.5, DELAY_MS = { 5000, 20000 }, WITNESS_CHANCE = 0.6, BLUR_RADIUS = 80 },

	-- ── dirty money ───────────────────────────────────────────────────────

	DIRTY = {
		-- The item a dirty eddie is. Registered by this module (ITEMS below).
		ITEM = 'dirty_eddies',
		-- 'item': crime pays in dirty eddies, washed only at a front. 'clean':
		-- crime pays straight into CLEAN_TYPE (a lighter server, no laundering).
		MODE = 'item',
		-- The balance 'clean' mode pays into, and the one a dealer's clean price
		-- is charged to. From config/shared.lua MONEY.TYPES.
		CLEAN_TYPE = 'EDDIES',
	},

	-- THE MINT CEILING, per citizen and per source, over a rolling WINDOW_MINUTES:
	-- the most dirty eddies one character can make from that kind of crime in the
	-- window, whatever they do. What a scripted loop or a duplicated register can
	-- make is bounded by this and not by a guess about how fast anyone plays.
	-- A payout that would cross it is cut to what is left.
	MINT_CAPS = {
		WINDOW_MINUTES = 60,
		robbery = 20000,
		-- What black-market dealers pay out for goods sold to them.
		fence = 15000,
		-- Selling drugs on a corner to NPCs (P2: not built yet; the cap is read).
		corner = 15000,
	},

	-- ── the items ─────────────────────────────────────────────────────────
	-- Registered in the inventory catalogue at start (`RegisterItem`), so a
	-- server needs no edit to config/inventory.lua. Fields are the inventory's
	-- runtime ones: label, description, weight (grams), stack, drop, category and
	-- model (a props alias for the pile). An item config/inventory.lua already carries is left alone.
	ITEMS = {
		dirty_eddies = { label = 'Dirty eddies', weight = 0, stack = true, drop = true,
			category = 'contraband', model = 'crate.valuable',
			description = 'Untraceable cred-chips. No bank in Night City will take them without asking.' },
		glitter = { label = 'Glitter', weight = 10, stack = true, drop = true, category = 'contraband',
			model = 'medical.container', description = 'Cheap stim dust. Everything sparkles, then nothing does.' },
		synthcoke = { label = 'Synthcoke', weight = 10, stack = true, drop = true, category = 'contraband',
			model = 'medical.container', description = 'Lab-grown coke. Sharp, fast, and hard on the heart.' },
		black_lace = { label = 'Black Lace', weight = 20, stack = true, drop = true, category = 'contraband',
			model = 'medical.container',
			description = 'Combat drug. Pain goes away, so does judgement. Cyberpsychosis in a vial.' },
		chem_precursor = { label = 'Chem precursor', weight = 200, stack = true, drop = true,
			category = 'contraband', model = 'container.bucket',
			description = 'Industrial solvent, diverted from a Biotechnica truck.' },
		lace_precursor = { label = 'Endorphin base', weight = 150, stack = true, drop = true,
			category = 'contraband', model = 'medical.container',
			description = 'Synthetic endorphin stock. Black Lace starts here.' },
		stolen_goods = { label = 'Stolen goods', weight = 500, stack = true, drop = true,
			category = 'contraband', model = 'crate.cardboard',
			description = 'Electronics with the serials filed off. A fence will know what to do.' },
	},

	-- ── drugs ─────────────────────────────────────────────────────────────
	-- What using each one does, on the server.
	--   EFFECT    a screen effect family of `Open77.effects.screen` (drunk,
	--             drugged, health); '' for none
	--   STRENGTH  0..1, picks the effect's tier
	--   SECONDS   how long the screen effect lasts
	--   ARMOR     armour added for the high (capped at ARMOR_CAP), 0 for none
	--   DOSE      what it adds to the addiction counter
	DRUGS = {
		glitter = { EFFECT = 'drugged', STRENGTH = 0.3, SECONDS = 90, ARMOR = 0, DOSE = 1 },
		synthcoke = { EFFECT = 'drugged', STRENGTH = 0.6, SECONDS = 120, ARMOR = 15, DOSE = 2 },
		black_lace = { EFFECT = 'drugged', STRENGTH = 1.0, SECONDS = 60, ARMOR = 40, DOSE = 4 },
	},

	-- The addiction counter, kept in the character's metadata under
	-- METADATA_KEY. It falls by DECAY_PER_HOUR; past WARN_AT the player is told;
	-- at OVERDOSE_AT the body gives out (the downed module takes it from there,
	-- and a trauma team can still bring them back). ARMOR_CAP bounds the armour
	-- any high can stack to.
	ADDICTION = { METADATA_KEY = 'underworld_addiction', DECAY_PER_HOUR = 2, WARN_AT = 8,
		OVERDOSE_AT = 14, ARMOR_CAP = 60, USE_COOLDOWN_MS = 5000 },

	-- ── the black market ──────────────────────────────────────────────────
	BLACKMARKET = {
		-- A dealer takes clean eddies too, at this multiple of the dirty price.
		CLEAN_PREMIUM = 1.4,
		-- How long a deal takes, and the gesture under it (an
		-- `modules/animations` name; '' plays none).
		DEAL_MS = 3000,
		ANIMATION = 'give',

		-- Each dealer: an NPC (`RECORD`, a TweakDB Character.* record) standing
		-- at one of SPOTS, moving to the next every ROTATE_MINUTES, present only
		-- between HOURS = { open, close } on the game clock (wraps midnight; nil
		-- = always). STOCK is what they sell -- PRICE in dirty eddies, QTY on
		-- hand, RESTOCK_MINUTES to put one back, DIRTY_ONLY to refuse clean money.
		-- BUYS is what they fence, PRICE paid in dirty eddies. PRICE_MOD scales
		-- every price of this dealer (a district's mark-up).
		DEALERS = {
			{
				ID = 'kabuki_fence', LABEL = 'Kabuki market fence',
				RECORD = 'Character.kabuki_vendor_ma', BUCKET = 0,
				SPOTS = { { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 }, { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 } },
				ROTATE_MINUTES = 30, HOURS = { 20, 5 }, PRICE_MOD = 1.0,
				STOCK = {
					{ ITEM = 'chem_precursor', PRICE = 120, QTY = 20, RESTOCK_MINUTES = 10 },
					{ ITEM = 'lace_precursor', PRICE = 300, QTY = 6, RESTOCK_MINUTES = 30, DIRTY_ONLY = true },
				},
				BUYS = {
					{ ITEM = 'stolen_goods', PRICE = 180 },
					{ ITEM = 'glitter', PRICE = 60 },
				},
			},
			{
				ID = 'jigjig_pusher', LABEL = 'Jig-Jig Street pusher',
				RECORD = 'Character.jpn_tyger_claws_gang_01_ranged1_pistol_ma', BUCKET = 0,
				GANGS = { tygerclaws = 0 },
				SPOTS = { { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 } },
				ROTATE_MINUTES = 0, HOURS = { 18, 6 }, PRICE_MOD = 1.2,
				STOCK = {
					{ ITEM = 'glitter', PRICE = 80, QTY = 30, RESTOCK_MINUTES = 5 },
					{ ITEM = 'synthcoke', PRICE = 220, QTY = 12, RESTOCK_MINUTES = 15 },
				},
				BUYS = {
					{ ITEM = 'synthcoke', PRICE = 140 },
				},
			},
			{
				ID = 'totentanz_broker', LABEL = 'Totentanz chem broker',
				RECORD = 'Character.maelstrom_gang_01_ranged2_ma', BUCKET = 0,
				GANGS = { maelstrom = 1 },
				SPOTS = { { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 } },
				ROTATE_MINUTES = 0, PRICE_MOD = 1.0,
				STOCK = {
					{ ITEM = 'black_lace', PRICE = 650, QTY = 4, RESTOCK_MINUTES = 45, DIRTY_ONLY = true },
					{ ITEM = 'lace_precursor', PRICE = 260, QTY = 10, RESTOCK_MINUTES = 20 },
				},
				BUYS = {
					{ ITEM = 'black_lace', PRICE = 420 },
					{ ITEM = 'stolen_goods', PRICE = 150 },
				},
			},
		},
	},

	-- ── drug labs ─────────────────────────────────────────────────────────
	-- Each lab is a `crafting` bench (`underworld:<ID>`): queue an order, come
	-- back when it is cooked. HEAT rises by PER_CYCLE with every order and falls
	-- by DECAY_PER_MINUTE; each order rolls an alarm at ALERT.CHANCE scaled by
	-- heat/100 once heat is past FLOOR. RECIPES are crafting recipes.
	LABS = {
		{
			ID = 'totentanz_cookroom', LABEL = 'Totentanz back room', BUCKET = 0,
			X = 0.0, Y = 0.0, Z = 0.0, GANGS = { maelstrom = 0 }, QUEUE = 3,
			HEAT = { PER_CYCLE = 15, DECAY_PER_MINUTE = 1, FLOOR = 30 },
			ALERT = { CHANCE = 0.6, DELAY_MS = { 10000, 40000 }, WITNESS_CHANCE = 0.5, BLUR_RADIUS = 120 },
			RECIPES = {
				{ KEY = 'black_lace', LABEL = 'Cook Black Lace', ICON = 'bolt',
					INPUTS = { lace_precursor = 2, chem_precursor = 1 }, OUTPUT = 'black_lace', COUNT = 3,
					SECONDS = 600 },
			},
		},
		{
			ID = 'kabuki_kitchen', LABEL = 'Kabuki noodle-bar kitchen', BUCKET = 0,
			X = 0.0, Y = 0.0, Z = 0.0, GANGS = { tygerclaws = 0 }, QUEUE = 4,
			HEAT = { PER_CYCLE = 10, DECAY_PER_MINUTE = 1, FLOOR = 40 },
			RECIPES = {
				{ KEY = 'synthcoke', LABEL = 'Cook synthcoke', ICON = 'bolt',
					INPUTS = { chem_precursor = 2 }, OUTPUT = 'synthcoke', COUNT = 5, SECONDS = 420 },
				{ KEY = 'glitter', LABEL = 'Cut glitter', ICON = 'bolt',
					INPUTS = { chem_precursor = 1 }, OUTPUT = 'glitter', COUNT = 8, SECONDS = 240 },
			},
		},
		{
			ID = 'pacifica_garage', LABEL = 'Pacifica garage lab', BUCKET = 0,
			X = 0.0, Y = 0.0, Z = 0.0, QUEUE = 2,
			HEAT = { PER_CYCLE = 25, DECAY_PER_MINUTE = 2, FLOOR = 20 },
			RECIPES = {
				{ KEY = 'glitter', LABEL = 'Cut glitter', ICON = 'bolt',
					INPUTS = { chem_precursor = 1 }, OUTPUT = 'glitter', COUNT = 6, SECONDS = 300 },
			},
		},
	},

	-- ── store robberies ───────────────────────────────────────────────────
	ROBBERIES = {
		-- The gesture under the bar ('' for none).
		ANIMATION = 'examine',
		-- Each store: the register at X, Y, Z (what the eye points at), an
		-- optional CLERK NPC behind it, REWARD = { MIN, MAX } dirty eddies,
		-- DURATION_MS of the bar, MIN_POLICE on duty for the store to be worth
		-- it, REQUIRE_WEAPON drawn. The till is REGISTER = { MAX charges, one
		-- back every REGROW_MINUTES } -- kept in the database, so a restart does
		-- not refill it; an empty till answers `register_empty`.
		-- PLAYER_COOLDOWN_MIN is per character, across every store.
		STORES = {
			{
				ID = 'kabuki_247', LABEL = '24/7, Kabuki', BUCKET = 0, X = 0.0, Y = 0.0, Z = 0.0,
				CLERK = { RECORD = 'Character.generic_shopkeeper_ma', X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				REWARD = { MIN = 800, MAX = 2200 }, DURATION_MS = 30000, MIN_POLICE = 2,
				REGISTER = { MAX = 2, REGROW_MINUTES = 45 }, PLAYER_COOLDOWN_MIN = 20, REQUIRE_WEAPON = true,
				ALERT = { CHANCE = 0.85, DELAY_MS = { 5000, 20000 }, WITNESS_CHANCE = 0.8, BLUR_RADIUS = 40 },
			},
			{
				ID = 'watson_pharmacy', LABEL = 'Pharmacy, Little China', BUCKET = 0, X = 0.0, Y = 0.0, Z = 0.0,
				REWARD = { MIN = 1200, MAX = 3000 }, DURATION_MS = 40000, MIN_POLICE = 3,
				REGISTER = { MAX = 1, REGROW_MINUTES = 60 }, PLAYER_COOLDOWN_MIN = 20, REQUIRE_WEAPON = true,
				ALERT = { CHANCE = 0.9, DELAY_MS = { 3000, 12000 }, WITNESS_CHANCE = 0.9, BLUR_RADIUS = 30 },
			},
			{
				ID = 'heywood_liquor', LABEL = 'Liquor store, Heywood', BUCKET = 0, X = 0.0, Y = 0.0, Z = 0.0,
				CLERK = { RECORD = 'Character.generic_shopkeeper_ma', X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				REWARD = { MIN = 600, MAX = 1600 }, DURATION_MS = 25000, MIN_POLICE = 1,
				REGISTER = { MAX = 3, REGROW_MINUTES = 30 }, PLAYER_COOLDOWN_MIN = 15, REQUIRE_WEAPON = true,
			},
			{
				ID = 'badlands_gas', LABEL = 'Sunset Motel gas station', BUCKET = 0, X = 0.0, Y = 0.0, Z = 0.0,
				REWARD = { MIN = 400, MAX = 1200 }, DURATION_MS = 20000, MIN_POLICE = 0,
				REGISTER = { MAX = 3, REGROW_MINUTES = 30 }, PLAYER_COOLDOWN_MIN = 10, REQUIRE_WEAPON = false,
				ALERT = { CHANCE = 0.4, DELAY_MS = { 20000, 60000 }, WITNESS_CHANCE = 0.3, BLUR_RADIUS = 200 },
			},
		},
	},

	-- ── laundering ────────────────────────────────────────────────────────
	LAUNDERING = {
		-- How long handing a stack over takes, and the gesture under it.
		DEPOSIT_MS = 4000,
		ANIMATION = 'phone',
		-- The amounts the counter offers.
		AMOUNTS = { 500, 1000, 2500, 5000 },
		-- Each front: RATE_PCT of what goes in comes out clean (0.7 = 30% cut),
		-- at most PER_TX_MAX per deposit and DAILY_CAP per character per day
		-- (counted in the database), ready MINUTES_PER_BATCH after the deposit,
		-- paid into PAYOUT. GANGS / JOBS gate it like everything else.
		FRONTS = {
			{
				ID = 'coyote_cojo', LABEL = 'El Coyote Cojo, back office', BUCKET = 0,
				X = 0.0, Y = 0.0, Z = 0.0, GANGS = { valentinos = 0 },
				RATE_PCT = 0.75, PER_TX_MAX = 5000, DAILY_CAP = 25000, MINUTES_PER_BATCH = 10, PAYOUT = 'BANK',
			},
			{
				ID = 'lizzies_bar', LABEL = "Lizzie's Bar, the till", BUCKET = 0,
				X = 0.0, Y = 0.0, Z = 0.0, GANGS = { moxes = 0 },
				RATE_PCT = 0.7, PER_TX_MAX = 4000, DAILY_CAP = 20000, MINUTES_PER_BATCH = 15, PAYOUT = 'BANK',
			},
			{
				ID = 'afterlife_fixer', LABEL = 'Afterlife booth', BUCKET = 0,
				X = 0.0, Y = 0.0, Z = 0.0, JOBS = { fixer = 0 }, GANGS = { tygerclaws = 2, valentinos = 2 },
				RATE_PCT = 0.8, PER_TX_MAX = 10000, DAILY_CAP = 50000, MINUTES_PER_BATCH = 30, PAYOUT = 'BANK',
			},
			{
				ID = 'wash_n_go', LABEL = "Wash'n'Go laundromat, Arroyo", BUCKET = 0,
				X = 0.0, Y = 0.0, Z = 0.0,
				RATE_PCT = 0.6, PER_TX_MAX = 2000, DAILY_CAP = 10000, MINUTES_PER_BATCH = 20, PAYOUT = 'BANK',
			},
		},
	},

	-- ── street deals, player to player ────────────────────────────────────
	-- A dealer offers a drug to the player in front of them (ALT on the
	-- player); the buyer accepts through the platform's own two-player
	-- invitation; when the hand-over completes, the server swaps the goods for
	-- the price. ITEMS lists what may be sold this way with a price range per
	-- unit; PRICES and COUNTS are the presets the menu offers. CURRENCY: 'dirty'
	-- (the buyer pays dirty eddies) or 'clean' (DIRTY.CLEAN_TYPE).
	STREET = {
		ENABLED = true,
		CURRENCY = 'dirty',
		ITEMS = {
			glitter = { MIN = 20, MAX = 400 },
			synthcoke = { MIN = 60, MAX = 900 },
			black_lace = { MIN = 150, MAX = 2500 },
		},
		PRICES = { 50, 100, 250, 500, 1000 },
		COUNTS = { 1, 3, 5 },
		DURATION_MS = 4000,
		INVITE_TIMEOUT_MS = 15000,
		START_DISTANCE = 2.5,
		ALERT = { CHANCE = 0.1, DELAY_MS = { 15000, 45000 }, WITNESS_CHANCE = 0.4, BLUR_RADIUS = 150 },
	},
}
