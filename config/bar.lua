--- Bars and food stalls: the venues, what they pour and cook, where the stock
--- comes from, and what a drink does to whoever drinks it.
-- @author dop42
--
-- "Order a drink named after a legend, choom." A VENUE is a place with a
-- counter, a back-room stash and (optionally) a supplier point. Its staff --
-- the `bartender` job of `config/character.lua` (0 Barback, 1 Bartender, 2
-- Owner) or whoever its JOBS / GANGS name -- buy ingredients at the supplier
-- into the venue stash, MIX drinks and dishes at the counter under a bar the
-- server times (the ingredients come out of the stash, the drink goes into the
-- bartender's bag), and SERVE a customer: an ALT row on the player, the
-- platform's two-player `give` with the customer's consent, and the bill --
-- through `invoices` when that module runs, charged straight from the
-- customer's purse otherwise. The house's share goes to the venue's treasury
-- through `accounts` when that module runs, to the bartender otherwise.
--
-- A DRINK FEEDS THE NEEDS through the inventory's own use (`THIRST`, `HUNGER`
-- below become the item's `use.status`, moved by the `needs` contract on the
-- server). An `ALCOHOL` above 0 also adds to a drunk level the server keeps and
-- plays `Open77.effects.screen('drunk')` on that player's screen alone.
--
-- THE POSITIONS ARE 0,0,0 ON PURPOSE. A venue whose COUNTER or STASH is at the
-- origin is DISABLED and named at boot ("not surveyed yet"); a SUPPLY at the
-- origin disables the supplier only. Stand on the spot, run `opx.here`, paste
-- the numbers; `/opx.bar.venues` lists what is open and what is not.
--
-- EVERYTHING IS DATA. Add an entry to VENUES and there is another bar; add a key
-- to ITEMS and RECIPES and every venue whose MENU names it can pour it. The
-- validator (`modules/bar/shared/model.lua`, `Problems`) names every entry it
-- refuses at boot, and a refused entry is simply not there.

OPX.Config.MODULES.bar = {
	enabled = true,

	-- ── who, where, how often ─────────────────────────────────────────────

	-- 'primary': only the worked job / the gang run with counts. 'any': every
	-- membership counts for the grade (never for ON_DUTY). config/gunsmith.lua's words.
	MEMBERSHIP = 'primary',
	JOB_MAX_AGE_MS = 60000,

	-- Metres from a counter, a stash or a supplier a request is accepted from,
	-- measured by the server. The eye's spheres use the same radius.
	REACH = 2.5,
	-- Metres from one of their venue's counters a bartender may serve from (the
	-- room, not the bar top), and between the bartender and the customer.
	SERVE_RADIUS = 20.0,
	SERVE_REACH = 3.0,
	-- Milliseconds between two requests of one kind from one player.
	REQUEST_MS = 700,

	-- ── the money ─────────────────────────────────────────────────────────

	-- What a customer pays with on a direct charge: 'BANK' or 'EDDIES' (from
	-- config/shared.lua MONEY.TYPES). An invoice always charges BANK -- the
	-- invoices module decides that, not this file.
	MONEY = 'BANK',
	-- 'auto': an invoice when the `invoices` contract exists, a direct charge
	-- otherwise. 'direct': always charge at the hand-over. 'invoice': always an
	-- invoice (a direct charge stands in when there is no invoices module).
	BILLING = 'auto',
	-- Percent of a sale that goes to the bartender who served; the rest is the
	-- house's (the venue ACCOUNT through `accounts`, or the bartender as well
	-- when there is no accounts module). Passed to invoices as `cutPct`.
	STAFF_CUT_PCT = 25,
	-- Who pays for stock at a supplier: 'account' (the venue's treasury through
	-- `accounts`, the buyer's BANK when there is no accounts module) or
	-- 'personal' (always the buyer's BANK).
	SUPPLY_FUNDS = 'account',

	-- ── the counter ───────────────────────────────────────────────────────

	-- Default bar length of one mix, in ms (a recipe may set MS). Capped by
	-- config/progress.lua MAX_MS.
	MIX_MS = 5000,
	-- The gesture under the bar (an `animations` profile name; '' for none).
	ANIMATION = 'examine',

	-- ── serving ───────────────────────────────────────────────────────────

	-- The platform's two-player `give`: how long the hand-over plays, how long
	-- the customer has to accept, and how close the two must start.
	SERVE = { DURATION_MS = 3000, INVITE_MS = 15000, START_DISTANCE = 3.0 },

	-- ── drunk ─────────────────────────────────────────────────────────────

	-- Each drink adds its ALCOHOL (units) to a level the server keeps per
	-- player; the level falls by DECAY_PER_MINUTE. The screen effect plays at a
	-- strength of level / FULL_AT (capped at 1) for level * SECONDS_PER_UNIT
	-- seconds (capped at MAX_SECONDS). EFFECT is an `Open77.effects.screen`
	-- family ('drunk'); '' plays none.
	DRUNK = { EFFECT = 'drunk', DECAY_PER_MINUTE = 0.25, FULL_AT = 6, SECONDS_PER_UNIT = 45, MAX_SECONDS = 300 },

	-- ── the items ─────────────────────────────────────────────────────────
	-- Registered in the inventory catalogue at boot (`RegisterItem`), so no edit
	-- to modules/inventory/data/items.lua. KIND: 'drink' and 'food' are usable
	-- (consumed, THIRST / HUNGER moved through `needs`, ALCOHOL makes you
	-- drunk); 'ingredient' is stock and nothing else. WEIGHT in grams; MODEL a
	-- props alias for the pile on the ground.
	ITEMS = {
		-- The Afterlife's cocktails, named after legends.
		johnny_silverhand = { KIND = 'drink', LABEL = 'Johnny Silverhand', WEIGHT = 400, MODEL = 'food.drink_packaged',
			THIRST = 20, ALCOHOL = 2.5,
			DESCRIPTION = 'Tequila old fashioned, a bottle of chilli beer on the side. Wake the fuck up, samurai.' },
		rogue = { KIND = 'drink', LABEL = 'Rogue', WEIGHT = 350, MODEL = 'food.drink_packaged',
			THIRST = 20, ALCOHOL = 2,
			DESCRIPTION = 'Vodka, synth-citrus, ice. Cold, clean and in charge -- like the queen of the Afterlife.' },
		jackie_welles = { KIND = 'drink', LABEL = 'Jackie Welles', WEIGHT = 400, MODEL = 'food.drink_packaged',
			THIRST = 25, ALCOHOL = 2,
			DESCRIPTION = 'Vodka, ginger beer, a squeeze of lime. To Jackie. Vámonos.' },
		morgan_blackhand = { KIND = 'drink', LABEL = 'Morgan Blackhand', WEIGHT = 400, MODEL = 'food.drink_packaged',
			THIRST = 20, ALCOHOL = 2.5,
			DESCRIPTION = 'Whiskey, bitters, smoke. Nobody has seen him in fifty years; the glass is always full.' },
		broseph_ale = { KIND = 'drink', LABEL = 'Broseph ale', WEIGHT = 500, MODEL = 'food.soda_can',
			THIRST = 30, ALCOHOL = 1,
			DESCRIPTION = 'Night City\'s favourite cheap lager. Tastes like a Tuesday.' },
		neon_mox = { KIND = 'drink', LABEL = 'Neon Mox', WEIGHT = 350, MODEL = 'food.drink_packaged',
			THIRST = 20, ALCOHOL = 1.5,
			DESCRIPTION = 'Lizzie\'s house pour: vodka and something pink that glows. The Mox look after their own.' },
		centzon_tequila = { KIND = 'drink', LABEL = 'Centzon Totochtin', WEIGHT = 150, MODEL = 'food.drink_packaged',
			THIRST = 5, ALCOHOL = 1.5,
			DESCRIPTION = 'A shot of Heywood tequila, poured by Mama Welles. Salt, lime, no questions.' },
		chrome_bomb = { KIND = 'drink', LABEL = 'Chrome Bomb', WEIGHT = 300, MODEL = 'food.drink_packaged',
			THIRST = 10, ALCOHOL = 3,
			DESCRIPTION = 'Totentanz special. Synth-ethanol and coolant blue. Maelstrom drink it for breakfast.' },
		noodles = { KIND = 'food', LABEL = 'Jig-Jig noodles', WEIGHT = 450, MODEL = 'food.street_food',
			HUNGER = 45, THIRST = 10,
			DESCRIPTION = 'A steaming bowl of ramen, SCOP chashu and too much chilli oil.' },
		yakitori = { KIND = 'food', LABEL = 'SCOP yakitori', WEIGHT = 200, MODEL = 'food.street_food',
			HUNGER = 25,
			DESCRIPTION = 'Grilled skewers of something that was never a chicken. Still good.' },

		-- Stock, bought at a supplier into a venue stash.
		bar_tequila = { KIND = 'ingredient', LABEL = 'Bottle of tequila', WEIGHT = 900, MODEL = 'food.drink_packaged',
			DESCRIPTION = 'Bar stock. A litre of agave spirit.' },
		bar_vodka = { KIND = 'ingredient', LABEL = 'Bottle of vodka', WEIGHT = 900, MODEL = 'food.drink_packaged',
			DESCRIPTION = 'Bar stock. Synth-grain vodka, triple filtered (they say).' },
		bar_whiskey = { KIND = 'ingredient', LABEL = 'Bottle of whiskey', WEIGHT = 900, MODEL = 'food.drink_packaged',
			DESCRIPTION = 'Bar stock. Real oak, fake age statement.' },
		bar_mixer = { KIND = 'ingredient', LABEL = 'Cocktail mixer', WEIGHT = 500, MODEL = 'food.soda_can',
			DESCRIPTION = 'Bar stock. Synth-citrus, bitters, syrup -- the bartender\'s secret.' },
		bar_malt = { KIND = 'ingredient', LABEL = 'Keg of malt', WEIGHT = 2000, MODEL = 'container.bucket',
			DESCRIPTION = 'Bar stock. Pours a few pints of Broseph or a ginger beer.' },
		bar_chem = { KIND = 'ingredient', LABEL = 'Synth-ethanol', WEIGHT = 700, MODEL = 'medical.container',
			DESCRIPTION = 'Bar stock, technically. Do not drink neat.' },
		noodle_pack = { KIND = 'ingredient', LABEL = 'Noodle pack', WEIGHT = 300, MODEL = 'food.snack',
			DESCRIPTION = 'Stall stock. Fresh-ish wheat noodles.' },
		scop_protein = { KIND = 'ingredient', LABEL = 'SCOP protein', WEIGHT = 400, MODEL = 'food.snack',
			DESCRIPTION = 'Stall stock. Single-cell organic protein, the food of Night City.' },
	},

	-- ── the recipes ───────────────────────────────────────────────────────
	-- Key -> what one mix makes (ITEM x COUNT) out of INPUTS taken from the
	-- venue stash, and the bar length MS (MIX_MS when absent).
	RECIPES = {
		johnny_silverhand = { ITEM = 'johnny_silverhand', COUNT = 1, MS = 6000,
			INPUTS = { { ITEM = 'bar_tequila', COUNT = 1 }, { ITEM = 'bar_malt', COUNT = 1 } } },
		rogue = { ITEM = 'rogue', COUNT = 1, INPUTS = { { ITEM = 'bar_vodka', COUNT = 1 }, { ITEM = 'bar_mixer', COUNT = 1 } } },
		jackie_welles = { ITEM = 'jackie_welles', COUNT = 1,
			INPUTS = { { ITEM = 'bar_vodka', COUNT = 1 }, { ITEM = 'bar_malt', COUNT = 1 } } },
		morgan_blackhand = { ITEM = 'morgan_blackhand', COUNT = 1, MS = 6000,
			INPUTS = { { ITEM = 'bar_whiskey', COUNT = 1 }, { ITEM = 'bar_mixer', COUNT = 1 } } },
		broseph_ale = { ITEM = 'broseph_ale', COUNT = 2, MS = 3000, INPUTS = { { ITEM = 'bar_malt', COUNT = 1 } } },
		neon_mox = { ITEM = 'neon_mox', COUNT = 1, INPUTS = { { ITEM = 'bar_vodka', COUNT = 1 }, { ITEM = 'bar_mixer', COUNT = 2 } } },
		centzon_tequila = { ITEM = 'centzon_tequila', COUNT = 3, MS = 3000, INPUTS = { { ITEM = 'bar_tequila', COUNT = 1 } } },
		chrome_bomb = { ITEM = 'chrome_bomb', COUNT = 1, INPUTS = { { ITEM = 'bar_chem', COUNT = 1 }, { ITEM = 'bar_mixer', COUNT = 1 } } },
		noodles = { ITEM = 'noodles', COUNT = 1, MS = 8000,
			INPUTS = { { ITEM = 'noodle_pack', COUNT = 1 }, { ITEM = 'scop_protein', COUNT = 1 } } },
		yakitori = { ITEM = 'yakitori', COUNT = 2, MS = 6000, INPUTS = { { ITEM = 'scop_protein', COUNT = 1 } } },
	},

	-- ── the venues ────────────────────────────────────────────────────────
	-- Each venue:
	--   ID        what the stash, the commands and the logs name: never rename
	--             one that has been played
	--   LABEL     the Night City place, shown on the menus and the map
	--   JOBS      job -> minimum grade; GANGS gang -> minimum grade. Either list
	--             lets a character work here (OPX.JobGate.EvaluateGroups)
	--   ON_DUTY   true: the job must be clocked in (gangs have no shift)
	--   ACCOUNT   { KIND = 'job'|'gang', KEY = name }: the treasury the house's
	--             share goes to and stock is paid from (default: the first of
	--             JOBS, else the first of GANGS). Venues sharing one job share one
	--             treasury -- give a venue its own job for its own books.
	--   SUPPLY_GRADE  minimum grade to buy stock (default 1)
	--   COUNTER   where the mixing happens
	--   STASH     the back room: NAME (storage key, unique), LABEL, SLOTS,
	--             MAX_WEIGHT, X/Y/Z
	--   SUPPLY    the supplier point and its CATALOG: { ITEM, PRICE, COUNT }
	--             (COUNT units delivered into the stash for PRICE)
	--   MENU      recipe keys this venue mixes, in menu order
	--   PRICES    item -> what a customer pays for one, served
	--   BLIP      { SPRITE, ICON, COLOR, SIZE } a map pin; false for none
	VENUES = {
		{
			ID = 'afterlife', LABEL = 'The Afterlife (Little China, Watson)',
			JOBS = { bartender = 0 }, ON_DUTY = true, SUPPLY_GRADE = 1,
			COUNTER = { X = 0.0, Y = 0.0, Z = 0.0 },
			STASH = { NAME = 'bar_afterlife', LABEL = 'AFTERLIFE BACK ROOM', SLOTS = 60, MAX_WEIGHT = 200000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = { X = 0.0, Y = 0.0, Z = 0.0, CATALOG = {
				{ ITEM = 'bar_tequila', PRICE = 90, COUNT = 1 },
				{ ITEM = 'bar_vodka', PRICE = 80, COUNT = 1 },
				{ ITEM = 'bar_whiskey', PRICE = 110, COUNT = 1 },
				{ ITEM = 'bar_mixer', PRICE = 40, COUNT = 2 },
				{ ITEM = 'bar_malt', PRICE = 60, COUNT = 1 },
			} },
			MENU = { 'johnny_silverhand', 'rogue', 'jackie_welles', 'morgan_blackhand', 'broseph_ale' },
			PRICES = { johnny_silverhand = 250, rogue = 220, jackie_welles = 200, morgan_blackhand = 260, broseph_ale = 60 },
			BLIP = { SPRITE = 'bar', ICON = 'bar', COLOR = '#FF4FA3', SIZE = 48 },
		},
		{
			ID = 'lizzies', LABEL = "Lizzie's Bar (Kabuki, Watson)",
			JOBS = { bartender = 0 }, ON_DUTY = true, SUPPLY_GRADE = 1,
			COUNTER = { X = 0.0, Y = 0.0, Z = 0.0 },
			STASH = { NAME = 'bar_lizzies', LABEL = "LIZZIE'S STOCKROOM", SLOTS = 50, MAX_WEIGHT = 150000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = { X = 0.0, Y = 0.0, Z = 0.0, CATALOG = {
				{ ITEM = 'bar_vodka', PRICE = 80, COUNT = 1 },
				{ ITEM = 'bar_mixer', PRICE = 40, COUNT = 2 },
				{ ITEM = 'bar_malt', PRICE = 60, COUNT = 1 },
			} },
			MENU = { 'neon_mox', 'rogue', 'broseph_ale' },
			PRICES = { neon_mox = 160, rogue = 200, broseph_ale = 55 },
			BLIP = { SPRITE = 'bar', ICON = 'bar', COLOR = '#FF4FA3', SIZE = 48 },
		},
		{
			ID = 'el_coyote', LABEL = 'El Coyote Cojo (Heywood)',
			JOBS = { bartender = 0 }, ON_DUTY = true, SUPPLY_GRADE = 1,
			COUNTER = { X = 0.0, Y = 0.0, Z = 0.0 },
			STASH = { NAME = 'bar_el_coyote', LABEL = 'EL COYOTE CELLAR', SLOTS = 50, MAX_WEIGHT = 150000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = { X = 0.0, Y = 0.0, Z = 0.0, CATALOG = {
				{ ITEM = 'bar_tequila', PRICE = 75, COUNT = 1 },
				{ ITEM = 'bar_vodka', PRICE = 80, COUNT = 1 },
				{ ITEM = 'bar_malt', PRICE = 55, COUNT = 1 },
			} },
			MENU = { 'centzon_tequila', 'jackie_welles', 'broseph_ale' },
			PRICES = { centzon_tequila = 70, jackie_welles = 180, broseph_ale = 50 },
			BLIP = { SPRITE = 'bar', ICON = 'bar', COLOR = '#FF4FA3', SIZE = 48 },
		},
		{
			ID = 'totentanz', LABEL = 'Totentanz (Northside, Watson)',
			JOBS = { bartender = 0 }, GANGS = { maelstrom = 0 }, ON_DUTY = true, SUPPLY_GRADE = 1,
			ACCOUNT = { KIND = 'gang', KEY = 'maelstrom' },
			COUNTER = { X = 0.0, Y = 0.0, Z = 0.0 },
			STASH = { NAME = 'bar_totentanz', LABEL = 'TOTENTANZ CAGE', SLOTS = 50, MAX_WEIGHT = 150000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = { X = 0.0, Y = 0.0, Z = 0.0, CATALOG = {
				{ ITEM = 'bar_chem', PRICE = 70, COUNT = 1 },
				{ ITEM = 'bar_mixer', PRICE = 45, COUNT = 2 },
				{ ITEM = 'bar_malt', PRICE = 60, COUNT = 1 },
			} },
			MENU = { 'chrome_bomb', 'broseph_ale' },
			PRICES = { chrome_bomb = 150, broseph_ale = 60 },
			BLIP = { SPRITE = 'bar', ICON = 'bar', COLOR = '#FF4FA3', SIZE = 48 },
		},
		{
			ID = 'jigjig_noodles', LABEL = 'Jig-Jig Street noodle stall (Japantown, Westbrook)',
			JOBS = { bartender = 0 }, ON_DUTY = true, SUPPLY_GRADE = 0,
			COUNTER = { X = 0.0, Y = 0.0, Z = 0.0 },
			STASH = { NAME = 'bar_jigjig_noodles', LABEL = 'NOODLE STALL COOLER', SLOTS = 30, MAX_WEIGHT = 80000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = { X = 0.0, Y = 0.0, Z = 0.0, CATALOG = {
				{ ITEM = 'noodle_pack', PRICE = 20, COUNT = 2 },
				{ ITEM = 'scop_protein', PRICE = 25, COUNT = 2 },
			} },
			MENU = { 'noodles', 'yakitori' },
			PRICES = { noodles = 45, yakitori = 30 },
			BLIP = { SPRITE = 'food', ICON = 'bar', COLOR = '#FFB000', SIZE = 48 },
		},
	},
}
