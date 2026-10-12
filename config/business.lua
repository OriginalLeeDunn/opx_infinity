--- Business: the company / gang treasuries and the boss's HR terminal.
-- @author dop42
--
-- WHO IS A BOSS IS NOT DECIDED HERE. It is the grade table in
-- `config/character.lua`: a grade with `isBoss = true` opens the HR terminal for
-- its job or gang, a grade with `bankAuth = true` may also move money between
-- its own cash and the company account. This file only says HOW MUCH a boss may
-- do and WHERE: how many people a company may employ, which grade a new hire
-- starts at, who besides the bosses may recruit, and where the office terminals
-- stand.
--
-- A job or gang that is NOT named under JOBS / GANGS below still works with the
-- DEFAULTS: its bosses get the terminal through `/opx.boss`, with no office.
--
-- ============================================================================
-- EVERY OFFICE POSITION IN THIS FILE IS A PLACEHOLDER AND THE MODULE REFUSES IT
-- ============================================================================
--
-- An office whose X, Y and Z are all exactly zero is an unfilled blank: it is
-- DISABLED at boot with a line naming it, and no eye row stands there. Stand on
-- the spot in game, read your position with `/opx.here` and paste it in. The
-- LABEL is the Night City place the owner has to survey. Several offices per
-- job or gang are expected.

OPX.Config.MODULES.business = {
	enabled = true,

	-- The pocket a bankAuth boss deposits FROM and withdraws INTO. `EDDIES` is
	-- cash, `BANK` the account; the pair is in `config/shared.lua`.
	POCKET = 'EDDIES',

	-- The chat commands. `/opx.boss` opens the terminal for every group the
	-- player is a boss of (a corpo boss in a gang gets both). The staff command
	-- reads and adjusts a treasury: `/opx.accounts job ncpd`, `/opx.accounts
	-- gang maelstrom deposit 5000`, gated by the host ACL like every staff
	-- command. An empty string removes a command.
	COMMANDS = {
		BOSS = 'opx.boss',
		ACCOUNTS = 'opx.accounts',
	},

	-- `primary`: only the job / gang the character is working counts (a Captain
	-- of the NCPD who switched to their side gig as a bartender is a bartender
	-- until they switch back). `any`: every grade they hold counts.
	MEMBERSHIP = 'primary',

	-- true: the terminal opens only standing at one of the group's offices, and
	-- `/opx.boss` refuses elsewhere. false: anywhere, and the offices are a
	-- convenience. A group without one surveyed office is always "anywhere",
	-- so a server that has not surveyed yet is never locked out.
	REQUIRE_OFFICE = false,

	-- Reach of an office terminal's eye sphere, in metres, when the entry names
	-- no RADIUS.
	OFFICE_RADIUS = 1.5,

	-- WHO MAY BE MANAGED. `below`: a boss hires, fires, promotes and demotes only
	-- people strictly below their own grade, and grants at most the grade just
	-- below their own. `equal`: up to and including their own grade (two
	-- co-owners can then fire each other -- usually not what an owner wants).
	RANK_RULE = 'below',

	-- Recruiting a nearby player: the target is sent a contract offer they
	-- accept or refuse; it lapses after TTL_S. RADIUS is how close (metres) they
	-- must stand when offered AND when they accept. PRIMARY true makes the job
	-- the hire's primary one (they start working there at once, through the
	-- character module's SetJob and its hooks); false only adds the membership.
	HIRE = {
		RADIUS = 6.0,
		TTL_S = 60,
		PRIMARY = true,
	},

	-- The treasury: the largest single movement, how many history lines the
	-- terminal shows and the most a contract caller may ask for.
	ACCOUNTS = {
		MAX_AMOUNT = 10000000,
		HISTORY_SHOWN = 10,
		HISTORY_MAX = 50,
	},

	-- How many employees the terminal lists (each one is a sub-screen of rows,
	-- and a menu holds 200 rows). The full roster still counts for MAX_EMPLOYEES.
	ROSTER_SHOWN = 25,

	-- Per-player request window: REQUESTS requests per WINDOW_MS, beyond that a
	-- request is refused "too fast".
	RATE = { REQUESTS = 6, WINDOW_MS = 2000 },

	-- What a job or gang not named below gets.
	--   MAX_EMPLOYEES  0 = no cap
	--   HIRE_GRADE     the grade a recruit starts at
	--   HIRERS         lowest grade that may recruit (nil: the isBoss grades only)
	--   DUTY           whether bosses may clock an employee in / out
	DEFAULTS = {
		MAX_EMPLOYEES = 40,
		HIRE_GRADE = 0,
		HIRERS = nil,
		DUTY = true,
	},

	-- Per job: any DEFAULTS key, plus OFFICES (the HR terminals). LABEL is the
	-- lore place to survey.
	JOBS = {
		ncpd = {
			MAX_EMPLOYEES = 60,
			OFFICES = {
				{ LABEL = 'NCPD precinct, Little China (Watson) - captain\'s office', X = 0.0, Y = 0.0, Z = 0.0 },
				{ LABEL = 'NCPD precinct, Vista del Rey (Heywood) - duty sergeant desk', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		maxtac = {
			MAX_EMPLOYEES = 12,
			OFFICES = {
				{ LABEL = 'MaxTac staging floor, City Center', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		trauma = {
			MAX_EMPLOYEES = 30,
			OFFICES = {
				{ LABEL = 'Trauma Team International, Night City HQ (Corpo Plaza)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		arasaka = {
			MAX_EMPLOYEES = 30,
			OFFICES = {
				{ LABEL = 'Arasaka Tower, Human Resources (City Center)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		militech = {
			MAX_EMPLOYEES = 30,
			OFFICES = {
				{ LABEL = 'Militech offices, Corporate Plaza', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		fixer = {
			MAX_EMPLOYEES = 15,
			HIRERS = 1,
			OFFICES = {
				{ LABEL = 'Afterlife back room, Little China (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		merc = {
			MAX_EMPLOYEES = 0,
			OFFICES = {
				{ LABEL = 'Afterlife bar, Little China (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		ripperdoc = {
			MAX_EMPLOYEES = 10,
			OFFICES = {
				{ LABEL = 'Viktor\'s clinic back office, Little China (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		netrunner = {
			MAX_EMPLOYEES = 10,
			OFFICES = {
				{ LABEL = 'Netrunner den, Kabuki (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		cabbie = {
			MAX_EMPLOYEES = 25,
			DUTY = false,
			OFFICES = {
				{ LABEL = 'Delamain HQ, Corporate Plaza', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
		bartender = {
			MAX_EMPLOYEES = 12,
			OFFICES = {
				{ LABEL = 'Lizzie\'s Bar office, Kabuki (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
				{ LABEL = 'Afterlife bar office, Little China (Watson)', X = 0.0, Y = 0.0, Z = 0.0 },
			},
		},
	},

	-- Per gang, the same keys. A gang boss manages members through the
	-- character module's SetGang / RemoveGang. DUTY means nothing to a gang.
	GANGS = {
		maelstrom = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = 'Totentanz, Northside (Watson)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		valentinos = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = 'El Coyote Cojo, Heywood', X = 0.0, Y = 0.0, Z = 0.0 } } },
		tygerclaws = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = 'Clouds back office, Japantown (Westbrook)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		sixthstreet = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = '6th Street compound, Arroyo (Santo Domingo)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		voodooboys = { MAX_EMPLOYEES = 20, OFFICES = {
			{ LABEL = 'Grand Imperial Mall church, Pacifica', X = 0.0, Y = 0.0, Z = 0.0 } } },
		animals = { MAX_EMPLOYEES = 25, OFFICES = {
			{ LABEL = 'Animals gym, Pacifica', X = 0.0, Y = 0.0, Z = 0.0 } } },
		scavengers = { MAX_EMPLOYEES = 25, OFFICES = {
			{ LABEL = 'Scav den, Kabuki (Watson)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		moxes = { MAX_EMPLOYEES = 20, OFFICES = {
			{ LABEL = 'Lizzie\'s Bar, Kabuki (Watson)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		wraiths = { MAX_EMPLOYEES = 25, OFFICES = {
			{ LABEL = 'Wraith camp, Rocky Ridge (Badlands)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		barghest = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = 'Barghest HQ, Dogtown (Pacifica)', X = 0.0, Y = 0.0, Z = 0.0 } } },
		aldecaldos = { MAX_EMPLOYEES = 30, OFFICES = {
			{ LABEL = 'Aldecaldo camp, Badlands', X = 0.0, Y = 0.0, Z = 0.0 } } },
	},
}
