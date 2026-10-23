--- Contracts: the fixer's gig board, the mercs who take the work, and the street cred.
-- @author dop42
--
-- NIGHT CITY RUNS ON GIGS. A client walks into a bar with a problem and a stack
-- of eddies, a fixer turns it into a job, a merc does the job, and the fixer
-- takes a cut for the introduction. Pay is held by the fixer from the moment the
-- gig is posted -- "the eddies are on the table" -- and lands in the merc's
-- account only when the server has seen the work done. A merc who flakes loses
-- face (street cred) and the money goes back to whoever put it up.
--
-- WHO IS WHO is the character module's jobs: `fixer` posts, `merc` takes. Both
-- ship in `config/character.lua`; the grades below are those jobs' grades.
--
-- ============================================================================
-- EVERY POSITION IN THIS FILE IS A PLACEHOLDER AND THE MODULE REFUSES TO USE ONE
-- ============================================================================
--
-- A drop-off, a zone or a district fixer whose X, Y and Z are all exactly zero
-- is an unfilled blank: it is DISABLED at boot with a line naming it, it is never
-- offered on the post form and no NPC stands there. Stand on the spot in game,
-- read your own position off the developer console and paste it in. Several
-- entries per table are expected -- add as many drop-offs, zones and fixers as
-- the city needs; the keys are yours.
--
-- NPC RECORDS. The lore fixers (Regina Jones, Wakako Okada, Padre, Dakota
-- Smith, Mr. Hands, El Capitan, Dino Dinovic, Rogue) have no `Character.*`
-- record this build documents, so every NPC below stands as a generic vendor
-- body under the fixer's NAME. Swap RECORD for a record you have checked in game
-- with `Open77.data.npc` and the body follows; nothing else changes.

OPX.Config.MODULES.contracts = {
	enabled = true,

	-- The pocket every escrow, payout and fee moves through. `EDDIES` is cash,
	-- `BANK` the account; the pair is in `config/shared.lua`.
	CURRENCY = 'EDDIES',

	-- The chat commands. `/gigs` opens the board (everyone with a merc or fixer
	-- job sees their part of it), `/postgig` opens the posting form for a fixer.
	-- The staff command settles a disputed gig: `/opx.contracts.resolve <id>
	-- paid|failed`, gated by the host ACL like every `opx.*` staff command.
	COMMANDS = {
		BOARD = 'gigs',
		POST = 'postgig',
		RESOLVE = 'opx.contracts.resolve',
	},

	-- Who may POST a gig: a job -> minimum grade table, the same shape as every
	-- JOBS block in this resource (`lib/shared/jobgate.lua`). Add `ncpd = 2` to let
	-- a lieutenant post bounties through the same board, say.
	POSTERS = { JOBS = { fixer = 0 }, ON_DUTY = false },

	-- POSTERS / TAKERS may also name GANGS = { valentinos = 1 }. Either
	-- the job or the gang grants access; ON_DUTY applies only to jobs. Gang
	-- ranks also govern the posting cut and VALIDATE_GRADE when authorised.
	-- Who may TAKE a gig. A poster can never take their own gig.
	TAKERS = { JOBS = { merc = 0 }, ON_DUTY = false },

	-- `primary`: only the job the character is working counts. `any`: any job
	-- they hold a grade in counts (never for ON_DUTY).
	MEMBERSHIP = 'primary',

	-- Fixer grade from which a fixer may validate ANY manual gig, not only their
	-- own -- the broker who signs off on the work while the fixer is away.
	VALIDATE_GRADE = 1,

	-- THE FIXER'S CUT, in percent of the reward, taken at payout and handed back
	-- to the poster: the client paid the full reward, the merc is paid the reward
	-- minus the cut, the fixer keeps the cut. The poster picks it on the form
	-- between MIN and the lower of MAX and their grade's BY_GRADE ceiling, in
	-- steps of STEP. DEFAULT is preselected. Also the CONTRACT_FIXER_CUT tunable,
	-- which moves DEFAULT live from the staff panel.
	FIXER_CUT = {
		DEFAULT = 15,
		MIN = 10,
		MAX = 30,
		STEP = 5,
		-- grade -> highest cut that grade may ask. A Runner is cheap, a Fixer is
		-- worth what they charge. A grade absent here may ask up to MAX.
		BY_GRADE = { [0] = 15, [1] = 20, [2] = 30 },
	},

	-- A flat fee to put a gig on the board, taken with the escrow and DESTROYED
	-- (a money sink: the netrunner who keeps the board's ICE up wants paying). Not
	-- refunded on cancel. Zero for none.
	POST_FEE = 50,

	-- What a merc who abandons or fails a gig is fined, in percent of the
	-- reward, paid to whoever funded the gig on top of their refund. Taken only
	-- from a merc who is online and can pay it; nobody is put in debt by a gig.
	-- Zero for none.
	FAIL_PENALTY_PCT = 10,

	-- Bounds on a reward, in CURRENCY.
	REWARD = { MIN = 100, MAX = 50000 },

	-- How long a gig stays on the board, in seconds. The form offers CHOICES;
	-- DEFAULT is preselected; nothing past MAX is ever accepted.
	DEADLINE_S = {
		DEFAULT = 3600,
		CHOICES = { 1800, 3600, 7200, 21600, 86400 },
		MAX = 86400,
	},

	-- Seconds a merc has to finish once they took the gig. Past it the gig
	-- FAILS, the merc loses cred and the funder is refunded.
	ACCEPT_TTL_S = 1800,

	-- Seconds a manual gig waits for a fixer's verdict once the merc reported it
	-- done. Past it, MANUAL_TIMEOUT decides: 'pay' pays the merc as if validated,
	-- 'dispute' freezes the gig (escrow held) until staff resolve it.
	VALIDATE_TTL_S = 3600,
	MANUAL_TIMEOUT = 'dispute',

	-- Caps. A fixer with five open gigs posts no sixth; a merc works one at a
	-- time, like V.
	MAX_OPEN_PER_POSTER = 5,
	MAX_ACTIVE_PER_MERC = 1,

	-- Most open gigs one board shows, at most 30: the menu draws 200 rows in all,
	-- and a merc's own posts and the sign-off list (six each) share them.
	BOARD_LIMIT = 20,

	-- Lengths of what a poster types, in characters.
	TEXT = { TITLE_MAX = 64, BRIEF_MAX = 160 },

	-- STREET CRED. Stored on the character (metadata key KEY) as
	-- `{ cred, done, failed }`. A gig may ask a minimum tier; a merc below it
	-- never sees it. GAIN is what each ending does to the merc's cred; it never
	-- falls below zero. Tiers are listed from the lowest; LABEL is the
	-- operator's own word and is shown as written.
	CRED = {
		KEY = 'contracts',
		TIERS = {
			{ MIN = 0, LABEL = 'Nobody' },
			{ MIN = 50, LABEL = 'Street Kid' },
			{ MIN = 200, LABEL = 'Solo' },
			{ MIN = 600, LABEL = 'Edgerunner' },
			{ MIN = 1500, LABEL = 'Legend of the Afterlife' },
		},
		GAIN = { done = 10, failed = -5, abandoned = -8 },
	},

	-- How often the server looks at every running gig (zones held, deadlines
	-- passed), in milliseconds. Also the CONTRACT_SWEEP_MS tunable.
	SWEEP_MS = 1000,

	-- THE OBJECTIVES, each switchable. Another module may add its own through
	-- the contract (`RegisterObjectiveType`); these three ship.
	TYPES = {
		-- "Get this package to X." The merc is handed a sealed package item at
		-- accept, tagged with the gig; it is taken back at the drop-off (ALT on the
		-- drop-off's NPC, or the board's Deliver row standing there), within REACH
		-- of the drop-off plus its RADIUS. The item is registered at runtime.
		deliver_item = {
			ENABLED = true,
			REACH = 3.0,
			ITEM = 'contract_package',
			ITEM_LABEL = 'Sealed package',
			ITEM_DESCRIPTION = 'Sealed by a fixer. Do not open it. Do not ask.',
			ITEM_WEIGHT = 1500,
		},
		-- "Be at X and stay there." The merc must stand inside the zone for
		-- HOLD_MS without leaving it; leaving starts the clock again.
		reach_zone = {
			ENABLED = true,
			HOLD_MS = 10000,
		},
		-- "The fixer will tell you." Anything the server cannot measure: the merc
		-- reports it done, a fixer validates or rejects.
		manual = {
			ENABLED = true,
		},
	},

	-- WHERE PACKAGES GO. Key -> { LABEL, DISTRICT, X, Y, Z, RADIUS, BUCKET?,
	-- NPC? = { RECORD, YAW } }. The NPC is optional: without one the board's
	-- Deliver row still works standing on the spot. 0,0,0 = disabled.
	DROPOFFS = {
		watson_kabuki_market = {
			LABEL = 'Kabuki market stall', DISTRICT = 'Watson',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
			NPC = { RECORD = 'Character.VendorMale', YAW = 0.0 },
		},
		watson_northside_docks = {
			LABEL = 'Northside docks, container 7', DISTRICT = 'Watson',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
			NPC = { RECORD = 'Character.VendorMale', YAW = 0.0 },
		},
		westbrook_jig_jig = {
			LABEL = 'Jig-Jig Street back door', DISTRICT = 'Westbrook',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
			NPC = { RECORD = 'Character.VendorFemale', YAW = 0.0 },
		},
		heywood_wellsprings = {
			LABEL = 'Wellsprings garage', DISTRICT = 'Heywood',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
			NPC = { RECORD = 'Character.VendorMale', YAW = 0.0 },
		},
		pacifica_grand_imperial = {
			LABEL = 'Grand Imperial Mall loading bay', DISTRICT = 'Pacifica',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.5,
		},
		badlands_sunset_motel = {
			LABEL = 'Sunset Motel, room 102', DISTRICT = 'Badlands',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0,
			NPC = { RECORD = 'Character.VendorFemale', YAW = 0.0 },
		},
	},

	-- WHERE A MERC MUST STAND. Key -> { LABEL, DISTRICT, X, Y, Z, RADIUS,
	-- BUCKET? }. RADIUS in metres, measured flat by the server. 0,0,0 = disabled.
	ZONES = {
		watson_megabuilding_h10 = {
			LABEL = 'Megabuilding H10 lobby', DISTRICT = 'Watson',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 15.0,
		},
		city_center_corpo_plaza = {
			LABEL = 'Corpo Plaza', DISTRICT = 'City Center',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 20.0,
		},
		santo_domingo_arroyo = {
			LABEL = 'Arroyo scrapyard', DISTRICT = 'Santo Domingo',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 20.0,
		},
		badlands_rocky_ridge = {
			LABEL = 'Rocky Ridge overlook', DISTRICT = 'Badlands',
			X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 25.0,
		},
	},

	-- THE DISTRICT FIXERS: an NPC who stands in a bar, opens the board on ALT and
	-- -- when the city is short of real fixers -- posts gigs of their own from
	-- TEMPLATES. Their rewards are MINTED (new money, capped by MINT_PER_HOUR) and
	-- their cut is destroyed. Key -> {
	--   NAME, DISTRICT, X, Y, Z, YAW, RECORD, BUCKET?,
	--   GENERATE = {
	--     WHEN      'no_player_fixer' (only when no player fixer is on duty),
	--               'always' or 'never'
	--     MAX_OPEN  open gigs of this fixer's own at once
	--     EVERY_S   seconds between two new gigs
	--     CUT_PCT   the cut taken (and destroyed) at payout
	--     DEADLINE_S how long one stays on the board
	--   },
	--   TEMPLATES = { { TYPE = 'deliver_item'|'reach_zone', TITLE, BRIEF,
	--     TARGETS = { dropoff or zone keys }, REWARD = { MIN, MAX }, MIN_CRED? } },
	-- }
	-- 0,0,0 = no NPC; the fixer still posts if GENERATE says so.
	FIXERS = {
		regina = {
			NAME = 'Regina Jones', DISTRICT = 'Watson',
			X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0,
			RECORD = 'Character.VendorFemale',
			GENERATE = { WHEN = 'no_player_fixer', MAX_OPEN = 3, EVERY_S = 600,
				CUT_PCT = 20, DEADLINE_S = 3600 },
			TEMPLATES = {
				{ TYPE = 'deliver_item', TITLE = 'Medical supplies for Kabuki',
					BRIEF = 'A clinic in Kabuki is out of everything. Take the crate, no detours.',
					TARGETS = { 'watson_kabuki_market' }, REWARD = { MIN = 400, MAX = 900 } },
				{ TYPE = 'deliver_item', TITLE = 'Dead drop at the docks',
					BRIEF = 'Leave it in container 7. Somebody will pick it up. Not your business who.',
					TARGETS = { 'watson_northside_docks' }, REWARD = { MIN = 600, MAX = 1200 },
					MIN_CRED = 50 },
				{ TYPE = 'reach_zone', TITLE = 'Eyes on H10',
					BRIEF = 'Stand in the H10 lobby and look like you belong. Ten seconds, choom.',
					TARGETS = { 'watson_megabuilding_h10' }, REWARD = { MIN = 250, MAX = 500 } },
			},
		},
		wakako = {
			NAME = 'Wakako Okada', DISTRICT = 'Westbrook',
			X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0,
			RECORD = 'Character.VendorFemale',
			GENERATE = { WHEN = 'no_player_fixer', MAX_OPEN = 2, EVERY_S = 900,
				CUT_PCT = 25, DEADLINE_S = 3600 },
			TEMPLATES = {
				{ TYPE = 'deliver_item', TITLE = 'A gift for the Tyger Claws',
					BRIEF = 'Jig-Jig Street, back door. Bow when you hand it over.',
					TARGETS = { 'westbrook_jig_jig' }, REWARD = { MIN = 800, MAX = 1600 },
					MIN_CRED = 200 },
			},
		},
		padre = {
			NAME = 'Padre', DISTRICT = 'Heywood',
			X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0,
			RECORD = 'Character.VendorMale',
			GENERATE = { WHEN = 'never', MAX_OPEN = 2, EVERY_S = 900,
				CUT_PCT = 20, DEADLINE_S = 3600 },
			TEMPLATES = {
				{ TYPE = 'deliver_item', TITLE = 'Parts for the Wellsprings garage',
					BRIEF = 'Familia helps familia. Take it to the garage.',
					TARGETS = { 'heywood_wellsprings' }, REWARD = { MIN = 300, MAX = 700 } },
			},
		},
	},

	-- The most new money the district fixers may put up in one hour, all of
	-- them together. A gig that would pass it is not posted. Also the
	-- CONTRACT_MINT_PER_HOUR tunable.
	MINT_PER_HOUR = 20000,
}
