--- Police: the NCPD, MaxTac, corpo security -- who answers a crime, what each
--- of them may do to a suspect, and where a suspect ends up.
-- @author dop42
--
-- SEVERAL SERVICES, ONE FILE. Night City does not have one police force. It has
-- the NCPD -- underfunded, outsourced, paid by the bounty -- and above it MaxTac,
-- the Psycho Squad, who are called when a borged-up cyberpsycho is shredding a
-- street and who do not take prisoners lightly. It has corpo security, which is
-- the law inside an Arasaka or Militech enclave and nothing at all outside it.
-- Each is one entry under SERVICES, keyed by a name of your choosing. Add a
-- fourth (Militech security, a Trauma-style private patrol, the Badlands'
-- county sheriff) by copying a block and changing JOBS.
--
-- THE CODE KNOWS CAPABILITIES, NEVER SERVICES. A capability is a verb --
-- cuff, escort, frisk, fine, jail, impound -- and every service lists the ones
-- it holds with the minimum GRADE that may use each. A verb a service does not
-- list is a verb its members do not have: corpo security cuffs and frisks but
-- does not fine or jail -- it hands the suspect to the NCPD.
--
-- Shared, like the medical config: the client reads the stations it draws on
-- the eye, the crime labels and the key here; the server re-derives every bound
-- and decides everything. Nothing here is believed from a client.
--
-- A SERVICE IS GATED LIKE A LIFT. `JOBS = { ncpd = 0 }` and `ON_DUTY = true`
-- mean exactly what they mean on `elevators`, `medical` and `hauling`
-- (`lib/shared/jobgate.lua`): any listed job at or above its grade is enough,
-- and ON_DUTY asks that it be held on duty.
--
-- Every position ships as the placeholder 0,0,0, which DISABLES the entry and
-- names it at boot. Stand on the spot in game, run
-- `/opx.police.capture <kind> <station>` and paste the line it prints.
--
-- MONEY TYPES are the names in `config/shared.lua` MONEY.TYPES ('EDDIES' cash,
-- 'BANK'). Durations are milliseconds unless the key says _S (seconds) or _MIN.

OPX.Config.MODULES.police = {
	enabled = true,

	-- 'primary': only the character's primary job counts; 'any': a secondary job
	-- held in `jobs` counts too. The same switch `medical` and `hauling` read.
	MEMBERSHIP = 'primary',

	-- Milliseconds between two requests of one kind from one player.
	REQUEST_MS = 750,

	-- Milliseconds between two sweeps: call expiry, jail leashes and releases,
	-- escorts whose suspect walked off.
	SCAN_MS = 2000,

	-- Metres between an officer and the suspect they work on, measured by the
	-- server (plus REACH_SLACK from `config/shared.lua`), and the eye row's reach.
	REACH = 2.5,

	-- The key the record is written under in character metadata: cuffs, jail and
	-- unpaid fines. Change it only on a fresh database.
	METADATA_KEY = 'police',

	-- The dispatch board: a key every member of a police service may press to
	-- list the open calls, take one, or drop the one they hold. F6 is medical's.
	-- `false` as DEFAULT switches the key off.
	DISPATCH_KEY = { ID = 'opx.police.dispatch', NAME = 'police.key.dispatch', DEFAULT = 'F5' },

	-- What a call looks like on an officer's map. SPRITE is a blips alias (see
	-- `config/blips.lua`) and stays the fallback; ICON is an .svg in
	-- `web/blips/` and COLOR its '#RRGGBB' tint, drawn by clients with the native
	-- SVG adapter. A service may carry its own of each.
	BLIP = { SPRITE = 'objective', WALLS = true, ICON = 'police', SIZE = 48, COLOR = '#3B8BFF' },

	-- The toast a new call raises on an officer's screen, in milliseconds.
	ALERT_MS = 8000,

	-- ── 911 ─────────────────────────────────────────────────────────────────
	-- Any player may call the NCPD: `/911 <what is happening>`. The call carries
	-- the caller's position (the NCPD triangulates the holo) and lands on the
	-- board of every service whose DISPATCH.RECEIVES lists CRIME. COOLDOWN_S
	-- stops a prankster flooding the board; MAX_TEXT trims the description.
	EMERGENCY = {
		ENABLED = true,
		COMMAND = '911',
		CRIME = 'emergency',
		COOLDOWN_S = 60,
		MAX_TEXT = 160,
	},

	-- ── 10-00, officer down ─────────────────────────────────────────────────
	-- A police member on duty who goes down opens a priority call on every
	-- service listed here; Trauma Team is alerted by `medical` on its own terms.
	OFFICER_DOWN = { ENABLED = true, CRIME = 'officer_down' },

	-- ── cuffs ───────────────────────────────────────────────────────────────
	-- ITEM is registered at boot by this module (unless the static catalogue
	-- already has it) and must be in the officer's bag. CONSUME = false keeps it
	-- there: a pair of cuffs is reused. A suspect who is WOUNDED on the ground
	-- (`config/downed.lua` MODE 'wounded') is cuffed at once; one on their feet
	-- takes DURATION_MS under a server-timed bar, and walking out of BREAK_REACH
	-- before it ends is getting away. A flatlined body cannot be cuffed.
	CUFFS = {
		ITEM = 'handcuffs',
		LABEL = 'Handcuffs',
		DESCRIPTION = 'Polymer restraints, NCPD issue. Standard for every officer.',
		WEIGHT = 300,
		-- The props alias a dropped pair lies on the ground as.
		MODEL = 'crate.small',
		CONSUME = false,
		DURATION_MS = 3000,
		BREAK_REACH = 2.0,
	},

	-- ── escort ──────────────────────────────────────────────────────────────
	-- The platform's two-player `escort`: the officer walks, the cuffed suspect
	-- walks beside them. The engine caps one at 600 s; ask again to keep going.
	ESCORT = { DURATION_S = 300, START_DISTANCE = 2.5, BREAK_DISTANCE = 5.0 },

	-- ── fines ───────────────────────────────────────────────────────────────
	-- A fine is taken from MONEY_TYPE. What the suspect cannot pay is written as
	-- a debt on their record, settled at a station desk. OFFICER_CUT_PERCENT of
	-- what was PAID goes to the officer (the NCPD runs on bounties); the rest
	-- leaves the economy until an accounts module exists. MAX caps any one fine
	-- whatever the crime says.
	FINES = {
		MONEY_TYPE = 'BANK',
		MAX = 50000,
		OFFICER_CUT_PERCENT = 10,
		CUT_MONEY_TYPE = 'BANK',
	},

	-- ── jail ────────────────────────────────────────────────────────────────
	-- A cuffed suspect is jailed at a station by an officer standing inside it:
	-- they are uncuffed and moved into a cell, and leaving LEASH metres of it
	-- puts them back. OFFLINE_SERVES = true counts the wall clock (logging off
	-- serves time); false freezes the sentence while they are away.
	JAIL = { MAX_MINUTES = 120, LEASH = 6.0, OFFLINE_SERVES = true },

	-- ── impound ─────────────────────────────────────────────────────────────
	-- ALT on a vehicle: a server-timed bar, then an owned car is filed
	-- `impounded` under GARAGE (the owner cannot bring it out until staff run
	-- `/opx.police.unimpound <plate>`). REMOVE_UNOWNED clears a car nobody owns.
	IMPOUND = { DURATION_MS = 8000, REACH = 6.0, GARAGE = 'impound', REMOVE_UNOWNED = true },

	-- ── the penal code ──────────────────────────────────────────────────────
	-- Codes a call or a fine names. FINE is the suggested amount (the officer may
	-- enter less, never more than FINE_MAX or FINES.MAX), JAIL_MIN the suggested
	-- sentence, PRIORITY sorts the board (higher first). The underworld reports
	-- `robbery`, `clerk`, `lab` and `deal`; the netrunner ICE trace `netrunner`.
	CRIMES = {
		emergency = { LABEL = '911 call', PRIORITY = 1 },
		officer_down = { LABEL = '10-00 Officer down', PRIORITY = 10 },
		robbery = { LABEL = 'Armed robbery', FINE = 5000, FINE_MAX = 15000, JAIL_MIN = 20, PRIORITY = 5 },
		clerk = { LABEL = 'Homicide of a clerk', FINE = 20000, FINE_MAX = 50000, JAIL_MIN = 60, PRIORITY = 8 },
		lab = { LABEL = 'Drug manufacture', FINE = 8000, FINE_MAX = 25000, JAIL_MIN = 30, PRIORITY = 4 },
		deal = { LABEL = 'Drug dealing', FINE = 2500, FINE_MAX = 10000, JAIL_MIN = 10, PRIORITY = 3 },
		netrunner = { LABEL = 'Unauthorised netrunning', FINE = 6000, FINE_MAX = 20000, JAIL_MIN = 20, PRIORITY = 4 },
		cyberpsychosis = { LABEL = 'Cyberpsychosis episode', JAIL_MIN = 60, PRIORITY = 9 },
		assault = { LABEL = 'Assault', FINE = 1500, FINE_MAX = 6000, JAIL_MIN = 10, PRIORITY = 3 },
		trespass = { LABEL = 'Corporate trespass', FINE = 1000, FINE_MAX = 5000, JAIL_MIN = 5, PRIORITY = 2 },
		traffic = { LABEL = 'Traffic violation', FINE = 250, FINE_MAX = 2000, PRIORITY = 1 },
		weapons = { LABEL = 'Illegal weapon or chrome', FINE = 3000, FINE_MAX = 12000, JAIL_MIN = 15, PRIORITY = 3 },
	},

	SERVICES = {
		-- ── NCPD ───────────────────────────────────────────────────────────
		-- Night City Police Department. Cadets ride along, officers book, and
		-- only a detective signs a jail sentence.
		ncpd = {
			LABEL = 'Night City Police Department',
			SHORT = 'NCPD',
			JOBS = { ncpd = 0 },
			ON_DUTY = true,
			BLIP = { ICON = 'police', COLOR = '#3B8BFF' },
			-- The job account (the `accounts` contract, when a module provides it)
			-- that receives what is left of a fine after the officer's cut.
			-- Without that contract the rest leaves the economy.
			ACCOUNT = 'ncpd',
			CAPABILITIES = { cuff = 0, escort = 0, frisk = 1, fine = 1, jail = 2, impound = 1 },
			DISPATCH = {
				ENABLED = true,
				MIN_GRADE = 0,
				RESPONDERS = 4,
				CALL_TTL_S = 900,
				-- Crime codes this service is alerted to; '*' is every one.
				RECEIVES = { '*' },
			},
		},

		-- ── MaxTac ─────────────────────────────────────────────────────────
		-- The Psycho Squad. Above the NCPD, alerted to what is worth their AV:
		-- cyberpsychos, a downed officer, a clerk shot dead.
		maxtac = {
			LABEL = 'MaxTac',
			SHORT = 'MAXTAC',
			JOBS = { maxtac = 0 },
			ON_DUTY = true,
			BLIP = { ICON = 'police', COLOR = '#FF3B47' },
			ACCOUNT = 'maxtac',
			CAPABILITIES = { cuff = 0, escort = 0, frisk = 0, fine = 1, jail = 0, impound = 0 },
			DISPATCH = {
				ENABLED = true,
				MIN_GRADE = 0,
				RESPONDERS = 4,
				CALL_TTL_S = 900,
				RECEIVES = { 'cyberpsychosis', 'officer_down', 'clerk', 'netrunner' },
			},
		},

		-- ── Arasaka corporate security ─────────────────────────────────────
		-- The law inside an Arasaka enclave and nothing outside it. Cuffs,
		-- frisks and walks a trespasser out -- to the NCPD, who books them.
		-- ENCLAVES are spheres; a capability is refused outside every one. With
		-- no surveyed enclave the service acts nowhere (named at boot).
		arasaka_sec = {
			LABEL = 'Arasaka Security',
			SHORT = 'ARASAKA',
			JOBS = { arasaka = 1 },
			ON_DUTY = true,
			BLIP = { ICON = 'police', COLOR = '#E8E8E8' },
			CAPABILITIES = { cuff = 0, escort = 0, frisk = 0 },
			ENCLAVES = {
				{ LABEL = 'Arasaka Tower plaza', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 120.0 },
				{ LABEL = 'Arasaka Waterfront', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 150.0 },
			},
			DISPATCH = {
				ENABLED = true,
				MIN_GRADE = 1,
				RESPONDERS = 2,
				CALL_TTL_S = 600,
				RECEIVES = { 'netrunner', 'trespass' },
			},
		},
	},

	-- ── stations ────────────────────────────────────────────────────────────
	-- A station is where the work ends. SERVICES lists who may use it. RADIUS is
	-- the building: an officer must stand inside it to jail somebody. DESK is
	-- where anyone pays their fines (ALT); EVIDENCE is the locker confiscated
	-- items go into, opened by officers who may frisk. CELLS are where a
	-- sentence is served, RELEASE where it ends. Anything left at 0,0,0 is off.
	STATIONS = {
		mission_street = {
			LABEL = 'NCPD Mission Street Precinct',
			SERVICES = { 'ncpd', 'maxtac' },
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 40.0,
			DESK = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			EVIDENCE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, SLOTS = 100, MAX_WEIGHT = 500000 },
			CELLS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
			},
			RELEASE = { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
		},
		heywood = {
			LABEL = 'NCPD Heywood Precinct',
			SERVICES = { 'ncpd' },
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 35.0,
			DESK = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
			EVIDENCE = { X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, SLOTS = 100, MAX_WEIGHT = 500000 },
			CELLS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
			},
			RELEASE = { X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0 },
		},
	},
}
