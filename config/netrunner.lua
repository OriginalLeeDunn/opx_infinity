--- Netrunner: decks, daemons, networks and their nodes, loot, brokers, NetWatch.
-- @author dop42
--
-- SEVERAL NETWORKS IN ONE FILE, EACH ON ITS OWN. A network is a corp's subnet
-- with its ICE, its cooldown and its NODES: the access points a runner jacks in
-- at, the doors it can open (doorlock names), the cameras it can loop and the
-- terminals it can mine. A network the validator refuses is refused ALONE,
-- with a line at boot naming it; the others keep running.
--
-- POSITIONS 0, 0, 0 ARE "NOT SURVEYED YET". A network whose every access point
-- is three exact zeros is DISABLED -- no eye row, no jack-in -- and named at
-- boot. Stand where the junction box is and run
-- `/opx.netrunner.capture <network> <node> [access_point|terminal|camera]`,
-- which prints the node line to paste here. `/opx.netrunner.networks` lists
-- what is open, disabled and refused.
--
-- TUNING IS BY HAND AND BY TABLE. Every number a breach, a daemon, a sale or a
-- trace reads is below; nothing is hard-coded in the module but the shapes.

OPX.Config.MODULES.netrunner = {
	enabled = true,

	-- ── who ────────────────────────────────────────────────────────────────

	-- The job the deck grades and the network MIN_GRADE read (config/character
	-- JOBS: Script Kiddie 0 / Netrunner 1 / Blackwall Diver 2).
	JOB = 'netrunner',
	-- Whether the netrunner job must be on duty to jack in where a network
	-- needs a grade.
	ON_DUTY = false,
	-- A freelancer -- no netrunner job at all -- may jack into a network whose
	-- MIN_GRADE is 0 and that names no JOBS of its own, with a deck whose
	-- MIN_GRADE is 0. false makes every network a netrunner-only one.
	ALLOW_FREELANCE = true,

	-- ── the decks (inventory items, never stacked) ─────────────────────────
	--
	-- TIER against the network's ICE TIER sets the breach odds; RAM is what a
	-- full deck holds; REGEN the RAM it gets back per minute, in or out of a
	-- run (computed from a timestamp on the item, never ticked); MIN_GRADE the
	-- netrunner grade needed to run it. The current RAM lives on the item's
	-- metadata, so a drained deck is still drained after a restart.
	DECKS = {
		cyberdeck_militech_paraline = {
			LABEL = 'Militech Paraline', DESCRIPTION = 'Entry-level Militech cyberdeck. Reliable, loud, cheap.',
			TIER = 1, RAM = 4, REGEN = 6, MIN_GRADE = 0, WEIGHT = 800,
		},
		cyberdeck_tetratronic_rippler = {
			LABEL = 'Tetratronic Rippler Mk.2', DESCRIPTION = 'A street favourite: more buffer, faster recovery.',
			TIER = 2, RAM = 6, REGEN = 8, MIN_GRADE = 0, WEIGHT = 800,
		},
		cyberdeck_netwatch_netdriver = {
			LABEL = 'NetWatch Netdriver Mk.5', DESCRIPTION = 'Lifted from a NetWatch agent. Do not ask how.',
			TIER = 3, RAM = 8, REGEN = 10, MIN_GRADE = 1, WEIGHT = 700,
		},
		cyberdeck_raven_microcyber = {
			LABEL = 'Raven Microcyber Mk.6', DESCRIPTION = 'Built to go past the Blackwall and come back.',
			TIER = 4, RAM = 10, REGEN = 12, MIN_GRADE = 2, WEIGHT = 600,
		},
	},

	-- The item a mined shard becomes. Registered by this module, never stacked:
	-- each one carries its own network, kind, value and heat.
	SHARD_ITEM = { NAME = 'data_shard', LABEL = 'Data shard', WEIGHT = 20,
		DESCRIPTION = 'Encrypted data pulled from a corporate subnet.' },

	-- ── the breach ─────────────────────────────────────────────────────────
	--
	-- A node's STEPS name these presets, one bar each, rolled by the server.
	-- CHANCE moves by TIER_BONUS per tier the deck has over the ICE (or loses
	-- per tier it lacks), clamped to MIN_CHANCE..MAX_CHANCE; DURATION_MS moves
	-- by TIER_SPEED the same way. A failed step adds FAIL_TRACE (0..1) and is
	-- tried again: the ICE notices you long before it throws you out.
	BREACH = {
		PRESETS = {
			easy = { DURATION_MS = 2500, CHANCE = 0.92 },
			medium = { DURATION_MS = 3500, CHANCE = 0.78 },
			hard = { DURATION_MS = 4500, CHANCE = 0.62 },
			extreme = { DURATION_MS = 6000, CHANCE = 0.45 },
		},
		DEFAULT_STEPS = { 'medium' },
		TIER_BONUS = 0.08,
		TIER_SPEED = 0.10,
		MIN_CHANCE = 0.05,
		MAX_CHANCE = 0.97,
		FAIL_TRACE = 0.20,
		-- The progress module's animation name ('' plays none).
		ANIMATION = 'tablet2',
	},

	-- ── the daemons ────────────────────────────────────────────────────────
	--
	-- What a connected runner can run, by name. A node lists the ones it
	-- offers. EFFECT is one of door, cameras, shard, ice_pick, wipe. TRACE is
	-- what running it adds to the trace (0..1); RAM is what it costs.
	DAEMONS = {
		door_unlock = { LABEL = 'Unlock door', EFFECT = 'door', RAM = 3, TRACE = 0.05, UNLOCK_S = 20 },
		camera_loop = { LABEL = 'Loop cameras', EFFECT = 'cameras', RAM = 2, TRACE = 0.04, DURATION_MS = 90000 },
		datamine = { LABEL = 'Datamine', EFFECT = 'shard', RAM = 4, TRACE = 0.08, DURATION_MS = 8000,
			TABLE = 'corpo_low' },
		datamine_deep = { LABEL = 'Datamine: Virus', EFFECT = 'shard', RAM = 6, TRACE = 0.14,
			DURATION_MS = 12000, TABLE = 'corpo_high' },
		-- Slows the trace for the rest of the run: TRACE_MULT on its rate, once.
		ice_pick = { LABEL = 'ICE Pick', EFFECT = 'ice_pick', RAM = 3, TRACE = 0.02, TRACE_MULT = 0.6 },
		-- Pulls the trace back by TRACE_DROP and NetWatch heat by HEAT_DROP.
		wipe_logs = { LABEL = 'Wipe logs', EFFECT = 'wipe', RAM = 2, TRACE = 0.0, TRACE_DROP = 0.15,
			HEAT_DROP = 5 },
	},

	-- ── loot ───────────────────────────────────────────────────────────────
	--
	-- What a datamine pulls: one row by WEIGHT, its value a whole number of
	-- eddies between VALUE[1] and VALUE[2]. KIND is what a broker prices.
	SHARDS = {
		corpo_low = {
			{ KIND = 'payroll', LABEL = 'Payroll dump', VALUE = { 200, 450 }, WEIGHT = 60 },
			{ KIND = 'personal', LABEL = 'Employee braindance logs', VALUE = { 150, 350 }, WEIGHT = 30 },
			{ KIND = 'corp', LABEL = 'Internal memo cache', VALUE = { 500, 900 }, WEIGHT = 10 },
		},
		corpo_high = {
			{ KIND = 'corp', LABEL = 'R&D prototype schematics', VALUE = { 900, 1600 }, WEIGHT = 55 },
			{ KIND = 'corp', LABEL = 'Board-level comms', VALUE = { 1400, 2400 }, WEIGHT = 35 },
			{ KIND = 'personal', LABEL = 'Exec blackmail file', VALUE = { 1800, 3000 }, WEIGHT = 10 },
		},
		blackwall = {
			{ KIND = 'blackwall', LABEL = 'Rogue AI fragment', VALUE = { 3000, 6000 }, WEIGHT = 70 },
			{ KIND = 'blackwall', LABEL = 'Old Net archive', VALUE = { 5000, 9000 }, WEIGHT = 30 },
		},
	},

	-- ── the networks ───────────────────────────────────────────────────────
	--
	--   key = {
	--     LABEL, BUCKET = 0,
	--     MIN_GRADE = 0,            -- netrunner grade needed to jack in
	--     GANGS = { voodooboys = 0 }, -- additional faction gate; never replaces deck/job skill
	--     JOBS = { ... },           -- optional: replaces the job gate entirely
	--     BLACKWALL = false,        -- feeds NetWatch heat on every connect
	--     COOLDOWN_S = 1800,        -- locked down this long after a trace
	--     ICE = { NAME, TIER, TRACE_MS, ALERT_AT, FAIL_ALERT,
	--             ON_TRACE = { JOBS = { 'ncpd' }, REVEAL_ID = false } },
	--     NODES = {
	--       name = { KIND = 'access_point', X, Y, Z, RADIUS, STEPS = { ... }, DAEMONS = { ... } },
	--       name = { KIND = 'door', DOOR = '<doorlock name>', DAEMONS = { 'door_unlock' } },
	--       name = { KIND = 'camera', X, Y, Z, DAEMONS = { 'camera_loop' } },
	--       name = { KIND = 'terminal', X, Y, Z, DAEMONS = { 'datamine' }, TABLE?, COOLDOWN_S },
	--     },
	--   }
	--
	-- A door, camera or terminal node is reached THROUGH the network from any
	-- of its access points: being in the subnet is the point. ICE.TRACE_MS is
	-- how long a connected run takes to reach 100% trace with nothing else
	-- happening; ALERT_AT (0..1) is when the ON_TRACE jobs get an early warning.
	NETWORKS = {
		-- Arasaka's Watson waterfront logistics subnet: Script Kiddie territory.
		arasaka_waterfront = {
			LABEL = 'Arasaka Waterfront logistics',
			BUCKET = 0,
			MIN_GRADE = 0,
			BLACKWALL = false,
			COOLDOWN_S = 1800,
			ICE = {
				NAME = 'Arasaka Hellhound', TIER = 1, TRACE_MS = 180000, ALERT_AT = 0.7, FAIL_ALERT = true,
				ON_TRACE = { JOBS = { 'ncpd' }, REVEAL_ID = false },
			},
			NODES = {
				ap_loading_dock = {
					KIND = 'access_point', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
					STEPS = { 'easy', 'medium' },
					DAEMONS = { 'datamine', 'camera_loop', 'ice_pick', 'wipe_logs' },
				},
				door_warehouse = { KIND = 'door', DOOR = 'arasaka_waterfront_warehouse', DAEMONS = { 'door_unlock' } },
				cam_yard = { KIND = 'camera', X = 0.0, Y = 0.0, Z = 0.0, DAEMONS = { 'camera_loop' } },
				term_shipping = {
					KIND = 'terminal', X = 0.0, Y = 0.0, Z = 0.0, DAEMONS = { 'datamine' },
					TABLE = 'corpo_low', COOLDOWN_S = 900,
				},
			},
		},

		-- Kang Tao's Heywood plaza: a Netrunner's job, two access points.
		kangtao_plaza = {
			LABEL = 'Kang Tao Corporate Plaza',
			BUCKET = 0,
			MIN_GRADE = 1,
			BLACKWALL = false,
			COOLDOWN_S = 3600,
			ICE = {
				NAME = 'Kang Tao Tianlong', TIER = 2, TRACE_MS = 120000, ALERT_AT = 0.6, FAIL_ALERT = true,
				ON_TRACE = { JOBS = { 'ncpd' }, REVEAL_ID = false },
			},
			NODES = {
				ap_garage = {
					KIND = 'access_point', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
					STEPS = { 'medium', 'hard' },
					DAEMONS = { 'camera_loop', 'ice_pick', 'wipe_logs' },
				},
				ap_lobby = {
					KIND = 'access_point', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5,
					STEPS = { 'medium', 'hard', 'hard' },
					DAEMONS = { 'datamine_deep', 'camera_loop', 'ice_pick', 'wipe_logs' },
				},
				door_server_room = { KIND = 'door', DOOR = 'kangtao_server_room', DAEMONS = { 'door_unlock' } },
				term_exec = {
					KIND = 'terminal', X = 0.0, Y = 0.0, Z = 0.0, DAEMONS = { 'datamine_deep' },
					TABLE = 'corpo_high', COOLDOWN_S = 3600,
				},
			},
		},

		-- The Voodoo Boys' relay under the Grand Imperial Mall, Pacifica: past
		-- the Blackwall. Blackwall Divers only, and NetWatch is listening.
		voodoo_blackwall_relay = {
			GANGS = { voodooboys = 0 },
			LABEL = 'Pacifica Old Net relay',
			BUCKET = 0,
			MIN_GRADE = 2,
			BLACKWALL = true,
			COOLDOWN_S = 7200,
			ICE = {
				NAME = 'Blackwall', TIER = 4, TRACE_MS = 90000, ALERT_AT = 0.5, FAIL_ALERT = true,
				ON_TRACE = { JOBS = { 'ncpd', 'maxtac' }, REVEAL_ID = true },
			},
			NODES = {
				ap_relay = {
					KIND = 'access_point', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
					STEPS = { 'hard', 'extreme', 'extreme' },
					DAEMONS = { 'datamine', 'ice_pick', 'wipe_logs' },
					TABLE = 'blackwall',
				},
			},
		},
	},

	-- ── brokers ────────────────────────────────────────────────────────────
	--
	-- Where shards are sold, ALT on the sphere. BUY is the multiplier per shard
	-- KIND over the shard's value (a kind not listed uses DEFAULT; 0 or absent
	-- DEFAULT refuses it). A shard is HOT for HOT_S seconds after it was mined
	-- and sells at HOT_PENALTY of its price then.
	BROKERS = {
		{
			KEY = 'kabuki_fence', LABEL = 'Kabuki market netbroker',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0,
			BUY = { DEFAULT = 1.0, payroll = 1.0, personal = 0.8, corp = 1.1, blackwall = 0 },
			HOT_PENALTY = 0.5, HOT_S = 1800, CURRENCY = 'EDDIES',
		},
		{
			KEY = 'afterlife_broker', LABEL = 'Afterlife data broker',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0,
			BUY = { DEFAULT = 1.0, corp = 1.25, blackwall = 2.5 },
			HOT_PENALTY = 0.7, HOT_S = 1800, CURRENCY = 'EDDIES',
		},
	},

	-- ── NetWatch ───────────────────────────────────────────────────────────
	--
	-- A character's heat, on their metadata under METADATA. Every connect to a
	-- BLACKWALL network adds HEAT_PER_BLACKWALL, every trace HEAT_ON_TRACE; it
	-- cools by DECAY_PER_H an hour. At FLAG_AT NetWatch flags the runner: no
	-- jack-in anywhere for LOCKOUT_H hours.
	NETWATCH = {
		ENABLED = true,
		METADATA = 'netwatch_heat',
		HEAT_PER_BLACKWALL = 25,
		HEAT_ON_TRACE = 10,
		FLAG_AT = 100,
		LOCKOUT_H = 24,
		DECAY_PER_H = 2,
	},

	-- ── the session ────────────────────────────────────────────────────────

	-- How often the server raises every trace and checks every runner.
	TICK_MS = 1000,
	-- Floor between two requests from one player, in milliseconds.
	REQUEST_MS = 800,
	-- Most nodes one network may hold (each access point is an eye row).
	MAX_NODES = 24,
}
