--- Ripperdoc: the clinics, the chrome they put in, what it costs a body and a soul.
-- @author dop42
--
-- "Chrome's not just metal, choom. It's a choice." A RIPPERDOC is a job
-- (`ripperdoc` in `config/character.lua`, grades 0 Apprentice, 1 Ripperdoc, 2
-- Chrome Surgeon) worked at a CLINIC: chairs a patient sits in, a parts stash,
-- a wholesale terminal that fills the stash. The doc ALTs the patient, reads
-- the chart, picks a part; the PATIENT is asked to consent and pays; the bar
-- runs; the dice roll; the chrome goes in -- natively for the slots the
-- platform drives (Gorilla Arms, Reinforced Tendons), as roleplay metadata for
-- the rest.
--
-- NOT THE MEDIC. Reviving and healing is the `medical` module's, which also
-- calls one of its services `ripperdoc`; this file is about chrome only.
--
-- THE POSITIONS ARE 0,0,0 AND THAT IS ON PURPOSE. A clinic, a chair, a stash or
-- a supply terminal at the origin is DISABLED and named at boot ("not surveyed
-- yet"); nothing half-works. Stand where the chair is, run `opx.here`, paste
-- the numbers. `/opx.ripperdoc.clinics` lists what is open and what is not.
--
-- EVERYTHING IS DATA. Add a key under CLINICS and there is another clinic;
-- add a key under CHROME and every clinic that ALLOWs it can stock it. The
-- validator (`modules/ripperdoc/shared/model.lua`, `Problems`) names every
-- entry it refuses at boot, and a refused entry is simply not there.

OPX.Config.MODULES.ripperdoc = {
	enabled = true,

	-- Free cosmetic service for the owner's installed Gorilla Arms at a clinic.
	-- An empty RECORDS table accepts installed catalogue identifiers; populate
	-- it with record=true entries to restrict the models available on this server.
	STYLES = { ENABLED = true, RECORDS = {} },

	-- ── the doc ────────────────────────────────────────────────────────────

	-- primary: the WORKED job counts; any: every membership counts for the grade
	-- (never for ON_DUTY). Same words, same meaning as config/gunsmith.lua.
	MEMBERSHIP = 'primary',
	JOB_MAX_AGE_MS = 60000,

	-- Metres between the doc and the patient, measured on the server.
	DOC_REACH = 3.0,
	-- Metres the eye registers the stash and supply spheres within.
	PROMPT_RADIUS = 2.0,

	-- Grade -> failure multiplier. An apprentice slips, a chrome surgeon doesn't.
	GRADE_MOD = { [0] = 1.5, [1] = 1.0, [2] = 0.6 },

	-- ── the money ──────────────────────────────────────────────────────────

	-- What the patient pays with: 'BANK' or 'EDDIES'. A clinic may override.
	MONEY = 'BANK',
	-- Percent of what the patient finally pays that goes to the doc who cut.
	DOC_SHARE = 60,
	-- Where the rest goes until an `accounts` contract exists: 'doc' (all of it
	-- to the doc) or 'void' (out of the economy, logged).
	TILL = 'void',

	-- ── the operation ──────────────────────────────────────────────────────

	-- How long the patient has to accept, in ms.
	CONSENT_MS = 30000,
	-- Default bar lengths, in ms. A chrome entry may set its own. Capped by
	-- config/progress.lua MAX_MS (60 s by default).
	INSTALL_MS = 30000,
	REMOVE_MS = 20000,
	-- The gesture the doc plays under the bar (an `animations` profile name, ''
	-- for none). 'examine' is in the shipped catalogue.
	ANIMATION = 'examine',
	-- Labour multiplier for a removal (no part is sold).
	REMOVE_LABOUR_MULT = 0.6,
	-- Failure multiplier for a removal: pulling chrome out is easier.
	REMOVE_RISK_MULT = 0.5,
	-- Hard cap on any failure chance, 0..1.
	MAX_RISK = 0.6,
	-- A part below WORN_BELOW condition adds WORN_RISK to the chance.
	WORN_BELOW = 50,
	WORN_RISK = 0.10,
	-- Black-market parts (origin 'black') multiply the chance.
	BLACK_MULT = 1.5,
	-- Condition a removed part loses, and whether it drops a tier (0 = never).
	REMOVAL_WEAR = 10,
	REMOVAL_TIER_LOSS = 0,

	-- When the dice say no, WHICH no, by weight. Every field is per outcome:
	--   APPLY       true: the operation still goes through (chrome in / out)
	--   PART        'keep' | 'damaged' (loses CONDITION_LOSS) | 'lost'
	--   REFUND_PCT  percent of the bill handed back to the patient
	--   HEALTH_PCT  nil, or the patient is left at this percent of max health
	OUTCOMES = {
		botched = { WEIGHT = 1, APPLY = false, PART = 'lost', REFUND_PCT = 0 },
		rejected = { WEIGHT = 3, APPLY = false, PART = 'damaged', CONDITION_LOSS = 25, REFUND_PCT = 50 },
		trauma = { WEIGHT = 1, APPLY = true, PART = 'keep', REFUND_PCT = 0, HEALTH_PCT = 25 },
	},

	-- ── the body ───────────────────────────────────────────────────────────

	HUMANITY = {
		-- Where a character with no `humanity` metadata starts.
		START = 100,
		-- An install that would leave the patient below this is refused.
		REFUSE_BELOW = 0,
		-- Percent of an implant's humanity cost a removal gives back.
		REFUND_PCT = 50,
		-- Extra humanity per tier above 1.
		PER_TIER = 1,
	},

	-- The body's cyberware capacity, CHROME[*].CAPACITY summed.
	MAX_CAPACITY = 40,
	-- Past MAX_CAPACITY: 'refuse', or 'risk' (allowed, + OVER_CAPACITY_RISK).
	OVER_CAPACITY = 'refuse',
	OVER_CAPACITY_RISK = 0.25,

	-- P2 (cyberpsychosis episodes, neuroblockers, therapy). Read by nothing yet:
	-- here so the shape is settled. Humanity at or below BELOW is that stage.
	PSYCHO = {
		{ KEY = 'edgerunner', BELOW = 40 },
		{ KEY = 'unstable', BELOW = 20 },
		{ KEY = 'cyberpsycho', BELOW = 5 },
	},

	-- ── the native link ────────────────────────────────────────────────────

	NATIVE = {
		-- Bind the player's character to the cyberware store on load, ONLY when
		-- `open77_appearance` is not running (it binds itself, and a binding is
		-- exclusive per resource).
		BIND = true,
		-- A native chrome the platform cannot take right now (no API, a refused
		-- definition, a record not loaded) is installed as roleplay metadata
		-- instead of refused. Logged and audited either way.
		FALLBACK_RP = true,
		-- Most ms a native install/removal is waited on before both players are
		-- told it is pending; the receipt stays and is resumed on next load.
		TIMEOUT_MS = 30000,
	},

	-- ── the tiers ──────────────────────────────────────────────────────────

	-- MULT: price multiplier. FAIL: base failure chance (0..1). GRADE: least doc
	-- grade allowed to put this tier in.
	TIERS = {
		[1] = { LABEL = 'Tier 1', MULT = 1.0, FAIL = 0.02, GRADE = 0 },
		[2] = { LABEL = 'Tier 2', MULT = 1.8, FAIL = 0.04, GRADE = 0 },
		[3] = { LABEL = 'Tier 3', MULT = 3.0, FAIL = 0.07, GRADE = 1 },
		[4] = { LABEL = 'Tier 4', MULT = 5.0, FAIL = 0.10, GRADE = 1 },
		[5] = { LABEL = 'Tier 5', MULT = 8.0, FAIL = 0.15, GRADE = 2 },
	},

	-- ── the chrome ─────────────────────────────────────────────────────────

	-- KIND 'native': the platform installs it (open77_cyberware). SLOT/PROFILE
	--   pairs allowed in P1: arms/gorilla_arms, legs/double_jump. NATIVE.ID is a
	--   durable definition id: never rename it once installed. GRADES[tier] are
	--   the platform's grade fields (damage 0..300, knockback 0..6, cooldown
	--   100..600000 ms, charge 100..10000 ms); only listed tiers can be installed.
	-- KIND 'rp': character metadata only. SLOT is free text; one chrome per slot.
	-- ITEM: the inventory item registered at boot (never stacks). ILLEGAL: only a
	-- clinic with LICENSED = false will touch it.
	CHROME = {
		gorilla_arms = {
			LABEL = 'Gorilla Arms', KIND = 'native', SLOT = 'arms', ITEM = 'chrome_gorilla_arms',
			PRICE = 4000, HUMANITY = 12, CAPACITY = 14, WEIGHT = 4000,
			DESCRIPTION = 'Synthetic muscle and a titanium frame. Doors are optional.',
			NATIVE = {
				ID = 'opx.ripperdoc.gorilla_arms', VERSION = 1, PROFILE = 'gorilla_arms',
				GRADES = {
					[1] = { normalDamage = 20, chargedDamage = 45, knockbackMeters = 2, cooldownMs = 700, chargeMs = 800 },
					[2] = { normalDamage = 30, chargedDamage = 65, knockbackMeters = 3, cooldownMs = 650, chargeMs = 750 },
					[3] = { normalDamage = 45, chargedDamage = 90, knockbackMeters = 4, cooldownMs = 600, chargeMs = 700 },
				},
			},
		},
		reinforced_tendons = {
			LABEL = 'Reinforced Tendons', KIND = 'native', SLOT = 'legs', ITEM = 'chrome_reinforced_tendons',
			PRICE = 3000, HUMANITY = 8, CAPACITY = 8, WEIGHT = 2000,
			DESCRIPTION = 'Hydraulic tendons for a second jump in mid-air.',
			NATIVE = {
				ID = 'opx.ripperdoc.reinforced_tendons', VERSION = 1, PROFILE = 'double_jump',
				GRADES = {
					[1] = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 900, chargeMs = 650,
						jumpStaminaCost = 20, maxAirborneMs = 8000, maxFallSpeed = 20 },
					[2] = { normalDamage = 0, chargedDamage = 0, knockbackMeters = 0, cooldownMs = 600, chargeMs = 650,
						jumpStaminaCost = 10, maxAirborneMs = 10000, maxFallSpeed = 30 },
				},
			},
		},
		kiroshi_optics = {
			LABEL = 'Kiroshi Optics', KIND = 'rp', SLOT = 'eyes', ITEM = 'chrome_kiroshi_optics',
			PRICE = 1500, HUMANITY = 4, CAPACITY = 4, WEIGHT = 200, TIERS = { 1, 2, 3 },
			DESCRIPTION = 'Kiroshi "Clairvoyant" ocular implants. Scan, zoom, see.',
		},
		subdermal_armor = {
			LABEL = 'Subdermal Armor', KIND = 'rp', SLOT = 'skin', ITEM = 'chrome_subdermal_armor',
			PRICE = 2500, HUMANITY = 6, CAPACITY = 6, WEIGHT = 1500, TIERS = { 1, 2, 3, 4 },
			DESCRIPTION = 'Polymer plating grown under the skin.',
		},
		mantis_blades = {
			LABEL = 'Mantis Blades', KIND = 'rp', SLOT = 'arms', ITEM = 'chrome_mantis_blades', ILLEGAL = true,
			PRICE = 6000, HUMANITY = 15, CAPACITY = 16, WEIGHT = 3500, TIERS = { 1, 2, 3 },
			DESCRIPTION = 'Arm blades. Licensed clinics will not even look at them.',
		},
	},

	-- ── the clinics ────────────────────────────────────────────────────────
	--
	-- JOBS: job -> least grade. ON_DUTY: the job must be the worked one, on duty.
	-- LICENSED: false accepts ILLEGAL chrome and black-market parts.
	-- RISK: failure multiplier for this place. MARKUP: price multiplier.
	-- LABOUR: flat fee per operation. STOCK_GRADE: least grade to open the stash.
	-- ALLOW: chrome keys this clinic works on (absent: all of them).
	-- CHAIRS: where a patient sits; YAW/POSE are kept for the P2 pose.
	-- CHEST: the parts stash. NAME is a storage key: never rename or reuse it.
	-- SUPPLY: a job-only wholesale terminal; the doc pays COST, the part lands in
	-- the stash brand new (condition 100). GRADE: least grade to buy that row.
	CLINICS = {
		vik_clinic = {
			LABEL = "Viktor's Clinic", LICENSED = true, RISK = 1.0, MARKUP = 1.0, LABOUR = 300,
			JOBS = { ripperdoc = 0 }, ON_DUTY = true, BUCKET = 0, STOCK_GRADE = 1,
			ALLOW = { 'gorilla_arms', 'reinforced_tendons', 'kiroshi_optics', 'subdermal_armor' },
			SERVICES = { install = true, remove = true },
			CHAIRS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, YAW = 0.0, POSE = 'chair' },
			},
			CHEST = { NAME = 'ripperdoc_vik_clinic', LABEL = "VIK'S PARTS", SLOTS = 80, MAX_WEIGHT = 200000,
				X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = {
				X = 0.0, Y = 0.0, Z = 0.0,
				CATALOG = {
					{ CHROME = 'gorilla_arms', TIER = 1, COST = 1500, GRADE = 1 },
					{ CHROME = 'gorilla_arms', TIER = 2, COST = 2800, GRADE = 1 },
					{ CHROME = 'gorilla_arms', TIER = 3, COST = 5200, GRADE = 2 },
					{ CHROME = 'reinforced_tendons', TIER = 1, COST = 1100, GRADE = 1 },
					{ CHROME = 'reinforced_tendons', TIER = 2, COST = 2100, GRADE = 1 },
					{ CHROME = 'kiroshi_optics', TIER = 1, COST = 500, GRADE = 0 },
					{ CHROME = 'kiroshi_optics', TIER = 2, COST = 950, GRADE = 1 },
					{ CHROME = 'subdermal_armor', TIER = 1, COST = 900, GRADE = 1 },
				},
			},
		},

		kabuki_backalley = {
			LABEL = 'Kabuki Back Alley', LICENSED = false, RISK = 1.6, MARKUP = 0.8, LABOUR = 150,
			JOBS = { ripperdoc = 0 }, ON_DUTY = false, BUCKET = 0, STOCK_GRADE = 0, MONEY = 'EDDIES',
			SERVICES = { install = true, remove = true },
			CHAIRS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, YAW = 0.0, POSE = 'lie' },
			},
			CHEST = { NAME = 'ripperdoc_kabuki_backalley', LABEL = 'BACK ALLEY CRATE', SLOTS = 50,
				MAX_WEIGHT = 120000, X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = {
				X = 0.0, Y = 0.0, Z = 0.0,
				CATALOG = {
					{ CHROME = 'mantis_blades', TIER = 1, COST = 2500, ORIGIN = 'black' },
					{ CHROME = 'mantis_blades', TIER = 2, COST = 4500, ORIGIN = 'black', GRADE = 1 },
					{ CHROME = 'gorilla_arms', TIER = 1, COST = 1000, ORIGIN = 'black' },
					{ CHROME = 'kiroshi_optics', TIER = 1, COST = 300, ORIGIN = 'black' },
				},
			},
		},

		instant_implants_jig = {
			LABEL = 'Instant Implants (Jig-Jig St.)', LICENSED = true, RISK = 1.2, MARKUP = 1.3, LABOUR = 200,
			JOBS = { ripperdoc = 0 }, ON_DUTY = true, BUCKET = 0, STOCK_GRADE = 0,
			ALLOW = { 'kiroshi_optics', 'subdermal_armor' },
			SERVICES = { install = true, remove = false },
			CHAIRS = {
				{ X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, YAW = 0.0, POSE = 'chair' },
				{ X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5, YAW = 0.0, POSE = 'chair' },
			},
			CHEST = { NAME = 'ripperdoc_instant_implants_jig', LABEL = 'INSTANT IMPLANTS STOCK', SLOTS = 40,
				MAX_WEIGHT = 80000, X = 0.0, Y = 0.0, Z = 0.0 },
			SUPPLY = {
				X = 0.0, Y = 0.0, Z = 0.0,
				CATALOG = {
					{ CHROME = 'kiroshi_optics', TIER = 1, COST = 550 },
					{ CHROME = 'subdermal_armor', TIER = 1, COST = 1000 },
				},
			},
		},
	},
}
