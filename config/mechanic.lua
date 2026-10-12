--- Mechanics: the garages that fix cars, the tow that takes them, the lot that
--- gives them back.
-- @author dop42
--
-- SEVERAL SHOPS, ONE FILE. Night City has no single body shop: an Autofixer
-- franchise in Arroyo, a Badlands garage that asks no questions, a Kabuki bay
-- under the monorail. Each is one entry under SHOPS, keyed by a name of your
-- choosing, with its own bays, back-room stash and impound lot. Add a fourth by
-- copying a block.
--
-- Shared, like the fuel and medical configs: the client reads the spheres it
-- draws and the command names here; the server re-derives every bound and
-- decides everything. Nothing in this file is believed from a client.
--
-- A SHOP IS GATED LIKE A LIFT. `JOBS = { mechanic = 0 }` and `ON_DUTY = true`
-- mean what they mean on `elevators`, `hauling` and `medical`
-- (`lib/shared/jobgate.lua`): any listed job at or above its grade is enough,
-- and ON_DUTY asks that it be held on duty.
--
-- POSITIONS SHIP AT 0,0,0, WHICH MEANS DISABLED. Every bay, stash and lot below
-- is named at boot until somebody stands on the spot in game and pastes the
-- position in. A shop with no surveyed bay still takes calls and tows; it just
-- cannot do a workshop repair.
--
-- MONEY TYPES are the names in `config/shared.lua` MONEY.TYPES ('EDDIES' cash,
-- 'BANK'). Durations are milliseconds unless the key says _S (seconds).

OPX.Config.MODULES.mechanic = {
	enabled = true,

	-- 'primary': only the character's primary job counts; 'any': a secondary
	-- job held in `jobs` counts too. The switch `medical` and `hauling` read.
	MEMBERSHIP = 'primary',

	-- Milliseconds between two requests of one kind from one player.
	REQUEST_MS = 750,

	-- Milliseconds between two sweeps of the open calls: expiry, callers who
	-- left, responders who left.
	SCAN_MS = 2000,

	-- Metres between a player and the vehicle they work on, measured by the
	-- server (plus `REACH_SLACK` from `config/shared.lua`), and the eye row's reach.
	REACH = 4.0,

	-- Metres around the mechanic the server looks for somebody to bill: the
	-- vehicle's owner first, then the nearest other player.
	CUSTOMER_REACH = 12.0,

	-- The chat commands. CALL and TOW are anybody's: they put a call on the
	-- board of every mechanic on duty. BOARD is a mechanic's: list, take, drop.
	-- No key is bound on purpose (F6 is medical's, F9 staff's); a player may
	-- bind the command themselves.
	COMMANDS = { CALL = 'mechanic', TOW = 'tow', BOARD = 'mechboard' },

	-- What a call looks like on a mechanic's map. SPRITE is a blips alias and
	-- stays the fallback; ICON is an .svg in `web/blips/` and COLOR its tint,
	-- drawn where the client has the native SVG adapter (see `medical`).
	BLIP = { SPRITE = 'objective', WALLS = true, ICON = 'mechanic', SIZE = 48, COLOR = '#F7C948' },

	-- The toast a new call raises on a mechanic's screen, in milliseconds.
	ALERT_MS = 8000,

	DISPATCH = {
		ENABLED = true,
		-- Grade a member needs to see and take calls.
		MIN_GRADE = 0,
		-- Mechanics one call can hold at once.
		RESPONDERS = 1,
		-- Seconds an untaken call stays on the board.
		CALL_TTL_S = 600,
		-- Longest note a caller may add, in characters.
		NOTE_MAX = 80,
	},

	-- The two items this module registers at boot (runtime items, never the
	-- static catalogue). PARTS are what a workshop repair burns, from the shop's
	-- stash first and the mechanic's bag second. KIT is the roadside repair
	-- anybody can carry: used from the bag or from the eye on a vehicle.
	ITEMS = {
		PARTS = { NAME = 'mech_parts', LABEL = 'Vehicle parts',
			DESCRIPTION = 'Panels, belts and filters a garage burns through.', WEIGHT = 1500 },
		KIT = { NAME = 'mech_repairkit', LABEL = 'Roadside repair kit',
			DESCRIPTION = 'Patches a car well enough to reach a garage.', WEIGHT = 2500 },
	},

	-- THE WORKSHOP REPAIR: a mechanic on duty, the vehicle inside one of a
	-- shop's BAYS. Restores the whole vehicle (`Open77.vehicles.repair` 'full'
	-- and health 1.0). What it costs follows what is broken: MISSING is the
	-- damage in percent (the worse of lost health and the average crushed body
	-- cell), and
	--   fee      = BASE_FEE + PER_PERCENT x MISSING
	--   parts    = max(MIN_PARTS, ceil(MISSING / PERCENT_PER_PART))
	--   duration = BASE_MS + PER_PERCENT_MS x MISSING   (capped by progress MAX_MS)
	REPAIR = {
		MIN_GRADE = 0,
		BASE_FEE = 250,
		PER_PERCENT = 12,
		PERCENT_PER_PART = 25,
		MIN_PARTS = 1,
		BASE_MS = 8000,
		PER_PERCENT_MS = 150,
		-- An emote from `config/animations.lua` played under the bar, '' for none.
		ANIMATION = 'examine',
	},

	-- THE ROADSIDE KIT: anybody holding one, anywhere. Lifts health to HEALTH
	-- (never lowers it) and repairs the SCOPES named (any of glass, body,
	-- lights, tires, visual, mechanical). A mechanic on duty gets
	-- MECHANIC_HEALTH instead: they know where to hit it.
	KIT = {
		ENABLED = true,
		DURATION_MS = 12000,
		HEALTH = 0.45,
		MECHANIC_HEALTH = 0.7,
		SCOPES = { 'tires' },
		ANIMATION = 'examine',
	},

	-- THE BILL for a workshop repair. Through the `invoices` contract when it
	-- runs (the customer accepts or refuses on their own screen); otherwise the
	-- server charges the customer directly before the repair lands. CUT_PCT of
	-- what is paid goes to the mechanic, the rest to the shop's account
	-- (`accounts` contract) -- or all of it to the mechanic when no accounts
	-- module runs. NO_CUSTOMER: 'free' repairs with nobody to bill (the parts
	-- are still burnt), 'refuse' refuses before the bar.
	BILLING = {
		MONEY_TYPE = 'BANK',
		CUT_PCT = 30,
		NO_CUSTOMER = 'free',
	},

	-- THE TOW. Who may impound a registered vehicle off the street: a mechanic
	-- of the grade below, or the police. It is put away through the vehicles
	-- contract (`SetState` 'impounded') and stays refused at every garage until
	-- its owner pays the release fee at a shop's LOT. TOW_RECORDS, when not
	-- empty, asks for one of those vehicle records within TOW_REACH metres of
	-- the car -- a tow truck on scene. PAY is what the operator earns per tow,
	-- out of thin air; it ships at 0 so nobody farms their own alts' cars.
	IMPOUND = {
		ENABLED = true,
		JOBS = { mechanic = 1, ncpd = 0, maxtac = 0 },
		ON_DUTY = true,
		DURATION_MS = 15000,
		ANIMATION = 'examine',
		TOW_RECORDS = {},
		TOW_REACH = 15.0,
		PAY = 0,
		PAY_MONEY_TYPE = 'BANK',
	},

	SHOPS = {
		-- ── Autofixer, Arroyo ───────────────────────────────────────────────
		-- The franchise: clean bays, posted prices, an impound lot round the back.
		autofixer_arroyo = {
			LABEL = 'Autofixer - Arroyo',
			JOBS = { mechanic = 0 },
			ON_DUTY = true,
			-- The `accounts` key the shop's share is deposited to (kind 'job').
			ACCOUNT = 'mechanic',
			-- A vehicle inside one of these spheres can get a workshop repair.
			BAYS = {
				{ LABEL = 'Autofixer Arroyo - bay 1', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 6.0 },
			},
			-- The back-room stash the parts are taken from first.
			STASH = { LABEL = 'Autofixer Arroyo - parts room', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5,
				SLOTS = 40, MAX_WEIGHT = 200000 },
			-- Where an owner pays to get an impounded car back.
			LOT = { LABEL = 'Autofixer Arroyo - impound desk', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			RELEASE_FEE = 1500,
			RELEASE_MONEY_TYPE = 'BANK',
			-- The garage key a released car is filed under (`config/garages.lua`),
			-- or nil to send it back to the garage it was registered to.
			RELEASE_GARAGE = nil,
		},

		-- ── Dakota's garage, Rocky Ridge ────────────────────────────────────
		-- Badlands work: nomad rigs, cash prices, and the lot is a fenced yard.
		dakota_rocky_ridge = {
			LABEL = "Dakota's garage - Rocky Ridge",
			JOBS = { mechanic = 0 },
			ON_DUTY = true,
			ACCOUNT = 'mechanic',
			BAYS = {
				{ LABEL = 'Rocky Ridge - yard bay', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 8.0 },
			},
			STASH = { LABEL = 'Rocky Ridge - parts shed', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5,
				SLOTS = 30, MAX_WEIGHT = 150000 },
			LOT = { LABEL = 'Rocky Ridge - impound yard', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			RELEASE_FEE = 1000,
			RELEASE_MONEY_TYPE = 'BANK',
			RELEASE_GARAGE = nil,
		},

		-- ── Kabuki body shop, Watson ────────────────────────────────────────
		-- Under the monorail, two lifts and a tow hook.
		kabuki_watson = {
			LABEL = 'Kabuki body shop - Watson',
			JOBS = { mechanic = 0 },
			ON_DUTY = true,
			ACCOUNT = 'mechanic',
			BAYS = {
				{ LABEL = 'Kabuki - lift 1', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 5.0 },
				{ LABEL = 'Kabuki - lift 2', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 5.0 },
			},
			STASH = { LABEL = 'Kabuki - parts cage', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5,
				SLOTS = 30, MAX_WEIGHT = 150000 },
			LOT = { LABEL = 'Kabuki - impound counter', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			RELEASE_FEE = 1200,
			RELEASE_MONEY_TYPE = 'BANK',
			RELEASE_GARAGE = nil,
		},
	},
}
