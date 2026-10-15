--- Justice: licences, criminal records, counsel and the court.
-- @author dop42
--
-- "In Night City the law is whatever the Council can afford to enforce." The
-- city still keeps books: a LICENCE bought at City Hall (a line in the
-- character's metadata and a card in the bag), a CRIMINAL RECORD the NCPD and
-- the courts write to (SQL, one row per entry), LAWYERS who represent a client
-- who consented, and JUDGES who rule on expungements, sign warrants, set bail
-- and hear a case.
--
-- TWO JOBS, BOTH IN config/character.lua: `lawyer` (0 Associate, 1 Partner)
-- and `judge` (0 Judge, 1 Chief Judge). The police are the `police` module's
-- (NCPD, MaxTac) and talk to this one only through the `justice` contract --
-- this module never needs them.
--
-- THE POSITIONS ARE 0,0,0 AND THAT IS ON PURPOSE. A City Hall desk at the
-- origin is DISABLED and named at boot ("not surveyed yet"). Stand at the desk,
-- run `/opx.justice.capture <key>`, paste the line. `/opx.justice.desks` lists
-- what is open, disabled and refused.
--
-- EVERYTHING IS DATA. Another desk is another key under CITY_HALLS; another
-- licence is another key under LICENCES; another crime is another key under
-- CRIMES. The validator (`modules/justice/shared/access.lua`, `Problems`) names
-- every entry it refuses at boot, and a refused entry is simply not there.

OPX.Config.MODULES.justice = {
	enabled = true,

	-- ── who ────────────────────────────────────────────────────────────────
	--
	-- Each role is a JOBS block (`job = minimum grade`) beside ON_DUTY, decided
	-- by lib/shared/jobgate.lua like every other gate in this resource.
	-- POLICE read any record (and, through the contract, write to it).
	POLICE = { JOBS = { ncpd = 0, maxtac = 0 }, ON_DUTY = true },
	-- LAWYERS represent a consenting client, read that client's record and ask
	-- a judge to expunge an entry of it.
	LAWYER = { JOBS = { lawyer = 0 }, ON_DUTY = false },
	-- JUDGES read any record, rule on expungements, sign warrants, set bail,
	-- hear cases and revoke licences.
	JUDGE = { JOBS = { judge = 0 }, ON_DUTY = false },
	-- primary: the WORKED job counts; any: every membership counts for the
	-- grade (never for ON_DUTY). Same words as config/ripperdoc.lua.
	MEMBERSHIP = 'primary',

	-- ── where the city's money goes ────────────────────────────────────────
	--
	-- Licence fees, bail and court fines are paid to an `accounts` treasury
	-- (owned by the `business` module) when that contract is present. The
	-- accounts contract knows `job` and `gang` treasuries; the courts' own job
	-- account stands for the Night City Council here. Point it anywhere else
	-- (`{ KIND = 'job', KEY = 'ncpd' }`), or set it to false to burn the money
	-- (logged). Without the accounts contract the money is burned, said once.
	CITY_ACCOUNT = { KIND = 'job', KEY = 'judge' },
	-- What the citizen pays with at the desk: 'BANK' or 'EDDIES'.
	MONEY = 'BANK',

	-- ── City Hall ──────────────────────────────────────────────────────────
	--
	-- Each desk is an ALT sphere where a citizen buys a licence, reads their
	-- own record, pays bail and dismisses their lawyer. RADIUS is the sphere
	-- and the server's reach; BUCKET the routing bucket (0 = the open world).
	CITY_HALLS = {
		nc_city_hall = {
			LABEL = 'Night City City Hall',
			DESK = { X = 0.0, Y = 0.0, Z = 0.0 },
			RADIUS = 2.0,
			BUCKET = 0,
		},
		watson_council_annex = {
			LABEL = 'Night City Council - Watson annex',
			DESK = { X = 0.0, Y = 0.0, Z = 0.0 },
			RADIUS = 2.0,
			BUCKET = 0,
		},
	},

	-- ── licences ───────────────────────────────────────────────────────────
	--
	-- FEE in the desk's MONEY; DAYS of validity (0 = for life); CLEAN = true
	-- refuses the licence to a citizen with an active warrant or with a felony
	-- on their record (not expunged) newer than CLEAN_DAYS. ORDER sorts the
	-- desk menu. The key is what is written on the character and on the card:
	-- add keys freely, NEVER rename one.
	LICENCES = {
		driving = { LABEL = 'Driving licence', FEE = 350, DAYS = 30, CLEAN = false, ORDER = 1 },
		weapons = { LABEL = 'Firearms permit', FEE = 2500, DAYS = 14, CLEAN = true, ORDER = 2 },
		business = { LABEL = 'Business licence', FEE = 5000, DAYS = 30, CLEAN = false, ORDER = 3 },
		netrunning = { LABEL = 'NetWatch netrunning permit', FEE = 4000, DAYS = 14, CLEAN = true, ORDER = 4 },
	},
	CLEAN_DAYS = 30,
	-- The card in the bag: one registered item, never stacked, each one
	-- carrying its kind, holder, serial and expiry in its metadata.
	CARD_ITEM = {
		NAME = 'licence_card', LABEL = 'Licence card', WEIGHT = 10,
		DESCRIPTION = 'A Night City Council licence chip. Scannable by any NCPD officer.',
	},

	-- ── the record ─────────────────────────────────────────────────────────
	--
	-- The crime codes the court picks from (the police module keeps its own
	-- list and may send any code: an unknown code is stored with its own
	-- label). FINE and JAIL (minutes) are the court's suggested sentence;
	-- FELONY marks the entries CLEAN licences look at.
	CRIMES = {
		nc_101_assault = { LABEL = 'Assault', FINE = 1500, JAIL = 10, FELONY = false },
		nc_102_assault_deadly = { LABEL = 'Assault with a deadly weapon', FINE = 5000, JAIL = 30, FELONY = true },
		nc_201_theft = { LABEL = 'Theft', FINE = 1000, JAIL = 5, FELONY = false },
		nc_202_grand_theft_auto = { LABEL = 'Grand theft auto', FINE = 4000, JAIL = 20, FELONY = true },
		nc_301_unlicensed_weapon = { LABEL = 'Carrying an unlicensed weapon', FINE = 2500, JAIL = 10, FELONY = false },
		nc_302_illegal_netrunning = { LABEL = 'Unlicensed netrunning', FINE = 3000, JAIL = 15, FELONY = false },
		nc_401_cyberpsychosis = { LABEL = 'Cyberpsychotic episode', FINE = 0, JAIL = 60, FELONY = true },
		nc_501_murder = { LABEL = 'Murder', FINE = 20000, JAIL = 120, FELONY = true },
		nc_601_reckless_driving = { LABEL = 'Reckless driving', FINE = 500, JAIL = 0, FELONY = false },
		nc_701_contempt = { LABEL = 'Contempt of court', FINE = 1000, JAIL = 5, FELONY = false },
	},
	-- The most rows a record read sends (newest first). At most 30: a client
	-- menu validates its whole list in one resume, and the platform kills a
	-- resume past ~10,000 instructions (forty rows cost more than that).
	RECORD_ROWS = 30,
	-- Bounds a judge's form is held to.
	MAX_FINE = 1000000,
	MAX_JAIL = 600,
	MAX_BAIL = 1000000,

	-- ── counsel and court ──────────────────────────────────────────────────

	-- Metres between a lawyer and the citizen they offer to represent.
	LAWYER_REACH = 3.0,
	-- How long the citizen has to accept, in ms.
	CONSENT_MS = 30000,
	-- The most clients one lawyer's file lists (at most 30, same reason).
	MAX_CLIENTS = 30,
	-- The most open cases the court's docket lists (at most 30).
	MAX_CASES = 30,
}
