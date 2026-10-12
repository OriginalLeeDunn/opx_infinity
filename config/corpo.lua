--- Corpo: corporate assignments, standing, enclave security and espionage.
-- @author dop42
--
-- NIGHT CITY IS OWNED, AND THE OWNERS HIRE. A corp employee walks into one of
-- their corp's OFFICES and reads the ASSIGNMENTS BOARD: courier runs with a
-- locked briefcase, data shards carried to a dead drop or a rival's handshake
-- point, data pulled off a terminal, a floor swept, a VIP walked to a car. The
-- server generates the board per corp from the ASSIGNMENTS templates below,
-- proves every completion itself (the tagged item in the bag at the place, the
-- time held inside a zone, the VIP NPC standing at the destination), and the
-- CORP pays: out of its treasury through the `accounts` contract when that
-- module runs, else in new money under MINT.PER_HOUR. Every assignment done
-- moves the employee's STANDING with that corp, which unlocks the better work,
-- and QUARTER.TARGET done in one quarter pays a bonus once: the board is a
-- quarterly target with a face on it.
--
-- CORPORATE LOYALTY CUTS BOTH WAYS. A rival corp's employee can LIFT a stealable
-- shard off an employee carrying one (ESPIONAGE) and sell it to their own corp
-- at one of its offices; the victim's assignment fails and their standing pays
-- for it. Corp SECURITY (grade >= SECURITY_GRADE) watches the ENCLAVES and may
-- DETAIN a trespasser: the suspect is handed to the police module when it runs,
-- else to the NCPD officers on duty, and walked out to EJECT.
--
-- SEVERAL CORPS IN ONE FILE. Arasaka and Militech ship enabled; Kang Tao,
-- Biotechnica and Petrochem ship DISABLED as examples (their jobs are not in
-- config/character.lua yet -- add the job there, then ENABLED = true here).
--
-- POSITIONS 0, 0, 0 ARE "NOT SURVEYED YET": that place is skipped and named at
-- boot. Stand on the spot and run `/opx.corpo.capture <corp> <list> <key>`
-- (list one of offices, drops, terminals, floors, pickups, destinations,
-- enclaves), which prints the line to paste. `/opx.corpo.status` lists what is
-- open, skipped and refused. A bad entry is refused ALONE.
--
-- Elevator floors already gate by job (config/elevators.lua, same job gate):
-- an enclave here is the GROUND around a tower -- the plaza, the garage, the
-- lobby -- where a trespasser can be seen and detained.

OPX.Config.MODULES.corpo = {
	enabled = true,

	-- The money type every corp pays in.
	CURRENCY = 'EDDIES',

	-- Pay multiplier by grade in the corp job (a grade not listed uses 1.0).
	PAY_BY_GRADE = { [0] = 1.0, [1] = 1.15, [2] = 1.3, [3] = 1.5 },

	-- ── the board ──────────────────────────────────────────────────────────
	BOARD = {
		-- Offers on each corp's board at once.
		SIZE = 6,
		-- The board is redrawn this often (an offer taken is not replaced before).
		REFRESH_S = 900,
		-- Assignments one employee may hold at once.
		MAX_ACTIVE = 1,
	},

	-- ── standing ───────────────────────────────────────────────────────────
	--
	-- Per character and per corp, on the character's metadata under METADATA.
	-- An assignment's STANDING is gained on success, its LOSS lost on failure
	-- (ABANDON_LOSS when the employee walks away from it). MIN and MAX bound it.
	STANDING = {
		METADATA = 'corpo',
		MIN = -100,
		MAX = 1000,
		ABANDON_LOSS = 3,
	},

	-- Quarterly target: QUARTER.TARGET assignments done in one quarter
	-- (DAYS long, counted from the Unix epoch) pays BONUS once, from the corp.
	QUARTER = { DAYS = 91, TARGET = 12, BONUS = 2500 },

	-- New money a corp may mint in one hour (all corps together) when no
	-- `accounts` contract runs. A live tunable: CORPO_MINT_PER_HOUR.
	MINT = { PER_HOUR = 30000 },

	-- ── the items (registered by this module at boot, never stacked) ───────
	ITEMS = {
		briefcase = { NAME = 'corpo_briefcase', LABEL = 'Corporate briefcase', WEIGHT = 1500,
			DESCRIPTION = 'Biometric-locked. Do not open, do not lose, do not ask.' },
		datashard = { NAME = 'corpo_datashard', LABEL = 'Corporate datashard', WEIGHT = 20,
			DESCRIPTION = 'Encrypted corporate data with a chain of custody.' },
	},

	-- ── the assignment templates ───────────────────────────────────────────
	--
	--   name = {
	--     KIND = 'deliver' | 'retrieve' | 'sweep' | 'escort',
	--     LABEL, BRIEF,
	--     ITEM = 'briefcase' | 'datashard'   -- deliver; retrieve always yields a datashard
	--     TO = 'office' | 'drop' | 'rival_drop'  -- deliver and retrieve: where it ends
	--     MIN_GRADE, MIN_STANDING,           -- who sees it
	--     PAY = { low, high }, STANDING, LOSS, DEADLINE_S,
	--     HOLD_MS (sweep), DURATION_MS (retrieve: the terminal bar),
	--     REACH (escort: metres from the destination the VIP must stand),
	--     STEALABLE = true                   -- a rival may lift the item
	--     WEIGHT                             -- how often the generator picks it
	--     CORPS = { 'arasaka' }              -- optional: only these corps offer it
	--   }
	ASSIGNMENTS = {
		courier_briefcase = {
			KIND = 'deliver', LABEL = 'Courier run', BRIEF = 'Carry a sealed briefcase to another office.',
			ITEM = 'briefcase', TO = 'office', MIN_GRADE = 0, MIN_STANDING = 0,
			PAY = { 250, 450 }, STANDING = 4, LOSS = 6, DEADLINE_S = 1200, WEIGHT = 30,
		},
		shard_dead_drop = {
			KIND = 'deliver', LABEL = 'Dead drop', BRIEF = 'Leave a datashard at a dead drop. Nobody saw you.',
			ITEM = 'datashard', TO = 'drop', MIN_GRADE = 0, MIN_STANDING = 10,
			PAY = { 400, 700 }, STANDING = 6, LOSS = 8, DEADLINE_S = 1500, STEALABLE = true, WEIGHT = 25,
		},
		rival_handshake = {
			KIND = 'deliver', LABEL = 'Handshake', BRIEF = 'Hand a datashard over at a rival corp\'s drop. Officially, this never happened.',
			ITEM = 'datashard', TO = 'rival_drop', MIN_GRADE = 1, MIN_STANDING = 40,
			PAY = { 800, 1300 }, STANDING = 10, LOSS = 15, DEADLINE_S = 1800, STEALABLE = true, WEIGHT = 15,
		},
		data_retrieval = {
			KIND = 'retrieve', LABEL = 'Data retrieval', BRIEF = 'Pull the files off a terminal and bring the shard back to an office.',
			TO = 'office', MIN_GRADE = 0, MIN_STANDING = 0, DURATION_MS = 10000,
			PAY = { 350, 600 }, STANDING = 5, LOSS = 7, DEADLINE_S = 1500, STEALABLE = true, WEIGHT = 25,
		},
		floor_sweep = {
			KIND = 'sweep', LABEL = 'Floor sweep', BRIEF = 'Walk the floor and stay on it until the sweep is logged.',
			MIN_GRADE = 1, MIN_STANDING = 20, HOLD_MS = 60000,
			PAY = { 300, 500 }, STANDING = 5, LOSS = 5, DEADLINE_S = 1200, WEIGHT = 20,
		},
		vip_escort = {
			KIND = 'escort', LABEL = 'VIP escort', BRIEF = 'Meet an executive and walk them to their destination. Alive.',
			MIN_GRADE = 2, MIN_STANDING = 80, REACH = 6.0,
			PAY = { 1200, 2000 }, STANDING = 15, LOSS = 25, DEADLINE_S = 1800, WEIGHT = 10,
		},
	},

	-- ── espionage ──────────────────────────────────────────────────────────
	--
	-- A rival corp's employee lifts a STEALABLE item off an employee carrying
	-- it: a server bar of STEAL_MS within REACH. RIVALS_ONLY: only a corp the
	-- thief's corp lists in RIVALS may be robbed. The thief hands the shard in
	-- at any office of their own corp for PAY and STANDING; the victim fails
	-- their assignment. COOLDOWN_S between two attempts by one thief.
	ESPIONAGE = {
		ENABLED = true,
		STEAL_MS = 6000,
		REACH = 2.0,
		RIVALS_ONLY = true,
		PAY = { 500, 900 },
		STANDING = 12,
		COOLDOWN_S = 300,
	},

	-- ── enclave security ───────────────────────────────────────────────────
	SECURITY = {
		-- How often the server looks at who stands in which enclave.
		TICK_MS = 2000,
		-- The detain bar and its reach.
		DETAIN_MS = 4000,
		REACH = 2.5,
		-- Security is told about one trespasser at most this often.
		ALERT_COOLDOWN_S = 60,
		-- Standing a detainer earns per trespasser handed over.
		STANDING = 3,
		-- Without a police module, the on-duty members of these jobs hear it.
		POLICE_JOBS = { 'ncpd' },
		-- When the suspect is walked out to the enclave's EJECT point:
		-- 'always', 'no_police' (only when no police module took them), 'never'.
		EJECT = 'no_police',
	},

	-- ── the corps ──────────────────────────────────────────────────────────
	--
	--   key = {
	--     ENABLED, LABEL, JOB (config/character.lua),
	--     ACCOUNT = { KIND = 'job', KEY = '<job>' },   -- the treasury the accounts contract holds
	--     RIVALS = { ... }, ON_DUTY,                   -- must the employee be clocked in
	--     SECURITY_GRADE,                              -- grade that may detain
	--     PUBLISH_GRADE,                               -- grade that may outsource to the fixer board
	--     PAY_MULT,
	--     OFFICES = { key = { LABEL, X, Y, Z, RADIUS, BUCKET } },  -- the board, deliveries, hand-ins
	--     DROPS, TERMINALS, FLOORS, PICKUPS, DESTINATIONS = { same shape },
	--     VIP_RECORDS = { 'Character.*', ... },
	--     ENCLAVES = { key = { LABEL, X, Y, Z, RADIUS, BUCKET, JOBS = { arasaka = 0 }, ON_DUTY,
	--                          EJECT = { X, Y, Z } } },
	--   }
	CORPS = {
		arasaka = {
			ENABLED = true,
			LABEL = 'Arasaka',
			JOB = 'arasaka',
			ACCOUNT = { KIND = 'job', KEY = 'arasaka' },
			RIVALS = { 'militech', 'kang_tao' },
			ON_DUTY = false,
			SECURITY_GRADE = 1,
			PUBLISH_GRADE = 3,
			PAY_MULT = 1.0,
			OFFICES = {
				tower_lobby = { LABEL = 'Arasaka Tower, Corporate Plaza lobby', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				waterfront = { LABEL = 'Arasaka Waterfront, Kabuki docks office', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				konpeki = { LABEL = 'Konpeki Plaza, Arasaka concierge desk', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
			DROPS = {
				japantown_alley = { LABEL = 'Japantown, Jig-Jig Street back alley', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				charter_hill = { LABEL = 'Charter Hill, Arasaka Estate service gate', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
			TERMINALS = {
				waterfront_logistics = { LABEL = 'Arasaka Waterfront logistics terminal', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, BUCKET = 0 },
				konpeki_security = { LABEL = 'Konpeki Plaza security server', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, BUCKET = 0 },
			},
			FLOORS = {
				tower_analytics = { LABEL = 'Arasaka Tower, Analytics floor', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 15.0, BUCKET = 0 },
				konpeki_42 = { LABEL = 'Konpeki Plaza, 42nd floor', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 12.0, BUCKET = 0 },
			},
			PICKUPS = {
				konpeki_vip = { LABEL = 'Konpeki Plaza VIP entrance', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.5, BUCKET = 0 },
			},
			DESTINATIONS = {
				tower_plaza = { LABEL = 'Arasaka Tower, executive drop-off', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 3.0, BUCKET = 0 },
				embers = { LABEL = 'Embers, North Oak', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 3.0, BUCKET = 0 },
			},
			VIP_RECORDS = { 'Character.VendorMale', 'Character.VendorFemale' },
			ENCLAVES = {
				tower_plaza = {
					LABEL = 'Arasaka Tower plaza', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 40.0, BUCKET = 0,
					JOBS = { arasaka = 0, ncpd = 0 }, ON_DUTY = false,
					EJECT = { X = 0.0, Y = 0.0, Z = 0.0 },
				},
				waterfront_yard = {
					LABEL = 'Arasaka Waterfront yard', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 35.0, BUCKET = 0,
					JOBS = { arasaka = 0 },
					EJECT = { X = 0.0, Y = 0.0, Z = 0.0 },
				},
			},
		},

		militech = {
			ENABLED = true,
			LABEL = 'Militech',
			JOB = 'militech',
			ACCOUNT = { KIND = 'job', KEY = 'militech' },
			RIVALS = { 'arasaka', 'kang_tao' },
			ON_DUTY = false,
			SECURITY_GRADE = 1,
			PUBLISH_GRADE = 3,
			PAY_MULT = 1.0,
			OFFICES = {
				plaza_offices = { LABEL = 'Militech offices, Corporate Plaza', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				santo_domingo = { LABEL = 'Militech depot, Arroyo, Santo Domingo', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				rocky_ridge = { LABEL = 'Militech datacenter, Rocky Ridge', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
			DROPS = {
				pacifica_mall = { LABEL = 'Pacifica, Grand Imperial Mall loading bay', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
				kabuki_market = { LABEL = 'Kabuki, night market back stall', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
			TERMINALS = {
				rocky_ridge_core = { LABEL = 'Rocky Ridge datacenter core', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, BUCKET = 0 },
				arroyo_inventory = { LABEL = 'Arroyo depot inventory terminal', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, BUCKET = 0 },
			},
			FLOORS = {
				arroyo_warehouse = { LABEL = 'Arroyo depot, warehouse floor', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 20.0, BUCKET = 0 },
			},
			PICKUPS = {
				plaza_garage = { LABEL = 'Corporate Plaza, Militech garage', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.5, BUCKET = 0 },
			},
			DESTINATIONS = {
				ncx_terminal = { LABEL = 'Night City Airport, private terminal', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 3.0, BUCKET = 0 },
			},
			VIP_RECORDS = { 'Character.VendorMale' },
			ENCLAVES = {
				arroyo_depot = {
					LABEL = 'Militech depot, Arroyo', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 40.0, BUCKET = 0,
					JOBS = { militech = 0 },
					EJECT = { X = 0.0, Y = 0.0, Z = 0.0 },
				},
			},
		},

		-- Examples, disabled: add the job in config/character.lua first.
		kang_tao = {
			ENABLED = false,
			LABEL = 'Kang Tao',
			JOB = 'kang_tao',
			ACCOUNT = { KIND = 'job', KEY = 'kang_tao' },
			RIVALS = { 'arasaka', 'militech' },
			SECURITY_GRADE = 1,
			OFFICES = {
				heywood_plaza = { LABEL = 'Kang Tao offices, Heywood', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
		},
		biotechnica = {
			ENABLED = false,
			LABEL = 'Biotechnica',
			JOB = 'biotechnica',
			ACCOUNT = { KIND = 'job', KEY = 'biotechnica' },
			RIVALS = { 'petrochem' },
			SECURITY_GRADE = 1,
			OFFICES = {
				biotechnica_flats = { LABEL = 'Biotechnica Flats field office, Badlands', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
		},
		petrochem = {
			ENABLED = false,
			LABEL = 'Petrochem',
			JOB = 'petrochem',
			ACCOUNT = { KIND = 'job', KEY = 'petrochem' },
			RIVALS = { 'biotechnica' },
			SECURITY_GRADE = 1,
			OFFICES = {
				petrochem_dam = { LABEL = 'Petrochem dam control office, Badlands', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0 },
			},
		},
	},

	-- ── outsourcing to the fixer board ─────────────────────────────────────
	--
	-- A grade >= PUBLISH_GRADE may push an offer off the corp board onto the
	-- fixer board (the `contracts` module), paid by the corp up front: plausible
	-- deniability, at MARKUP of the offer's pay. TARGETS are what the gig asks
	-- of the merc, in the contracts module's own vocabulary (a DROPOFFS key for
	-- deliver_item, a ZONES key for reach_zone, config/contracts.lua). A gig
	-- that fails, expires or is cancelled gives the corp its money back.
	PUBLISH = {
		ENABLED = true,
		MARKUP = 1.25,
		DEADLINE_S = 3600,
		TARGETS = {
			{ TYPE = 'deliver_item', TARGET = 'watson_kabuki_market' },
			{ TYPE = 'reach_zone', TARGET = 'watson_megabuilding_h10' },
		},
	},

	-- ── the clock ──────────────────────────────────────────────────────────
	-- How often deadlines, sweeps and escorts are checked.
	TICK_MS = 1000,
	-- Floor between two requests from one player.
	REQUEST_MS = 700,
}
