--- Taxi: who drives a cab, what a ride costs, and where the street fares wait.
-- @author dop42
--
-- SEVERAL COMPANIES, ONE FILE. Night City's cabs are Delamain's -- the AI that
-- runs a fleet of autonomous Cortes and, on this server, a fleet of people who
-- drive them -- but nothing stops an indie outfit from working the same
-- streets. Each company is one entry under COMPANIES, keyed by a name of your
-- choosing, gated by JOBS exactly like an elevator, a lab or a medical service
-- (`lib/shared/jobgate.lua`). Add a company by copying a block.
--
-- Shared, like the medical config: the client reads the labels it draws; the
-- server re-derives every bound and decides everything -- the fare, the
-- distance, who sat in which seat. Nothing in this file is believed from a
-- client.
--
-- MONEY TYPES are the names in `config/shared.lua` MONEY.TYPES ('EDDIES' cash,
-- 'BANK'). Durations are milliseconds unless the key says _S (seconds).
-- Distances are metres; prices are per kilometre.
--
-- POSITIONS SHIP AT 0,0,0 = DISABLED, the house convention: every street-fare
-- point below carries a lore name so the owner can stand on it in game and
-- paste the position in. The validator names every blank one at boot.

OPX.Config.MODULES.taxi = {
	enabled = true,

	-- 'primary': only the character's primary job counts; 'any': a secondary
	-- job held in `jobs` counts too.
	MEMBERSHIP = 'primary',

	-- Milliseconds between two requests of one kind from one player.
	REQUEST_MS = 750,

	-- Milliseconds between two samples of every running meter. The distance is
	-- the sum of the straight segments between samples, so a shorter period
	-- follows a winding road more closely.
	SCAN_MS = 1000,

	-- The fastest a cab is believed to move, in metres per second. A segment
	-- longer than this times the elapsed time is clamped to it: a teleport, a
	-- desync or a staff warp is never a fare.
	MAX_SPEED = 75,

	-- Metres per second used to promise an ETA to the customer.
	ETA_SPEED = 14,

	-- Consecutive samples with the passenger out of the cab before the meter
	-- stops. One missed sample is a seat transition, not the end of a ride.
	EXIT_SAMPLES = 2,

	-- A ride shorter than this (metres) is free: somebody sat down and got out.
	MIN_RIDE_M = 50,

	-- Every few seconds the meter is pushed to the driver's and passenger's
	-- screens; 0 shows it only at the start and the end.
	METER_PUSH_MS = 10000,

	-- The commands. CALL is for anybody (`/taxi`, `/taxi <company>`, `/taxi
	-- cancel`); BOARD opens the driver's dispatch board. No key binding: F6
	-- (medical) and the other contested keys stay theirs.
	COMMANDS = { CALL = 'taxi', BOARD = 'cab' },

	-- How a call looks on a driver's map. SPRITE is a blips alias and stays the
	-- fallback; ICON is an .svg in `web/blips/` tinted COLOR where the client
	-- has the native SVG adapter.
	BLIP = { SPRITE = 'objective', WALLS = true, ICON = 'taxi', SIZE = 48, COLOR = '#F2C230' },

	-- The toast a new call raises on a driver's screen, in milliseconds.
	ALERT_MS = 8000,

	COMPANIES = {
		-- ── Delamain Corporation ───────────────────────────────────────────
		-- "Welcome to Delamain. How may I be of service?" The AI books the
		-- ride, the driver drives it, the company takes its cut.
		delamain = {
			LABEL = 'Delamain Corporation',
			SHORT = 'DLMN',
			JOBS = { cabbie = 0 },
			ON_DUTY = true,
			-- The locale family of the dispatcher's voice: 'delamain' is the AI,
			-- 'generic' a tired human dispatcher. See `modules/taxi/locales.lua`.
			VOICE = 'delamain',
			BLIP = { COLOR = '#F2C230' },

			DISPATCH = {
				-- Grade a member needs to see and take calls.
				MIN_GRADE = 0,
				-- Seconds a call stays on the board before it lapses untaken.
				CALL_TTL_S = 300,
			},

			FARE = {
				MONEY_TYPE = 'BANK',
				-- The flag fall, then every kilometre the server measured.
				BASE = 40,
				PER_KM = 30,
				-- Never less, never more, whatever the meter says.
				MIN = 60,
				MAX = 4000,
				-- Night surge, read off the weather module's clock (game hours,
				-- FROM inclusive to TO exclusive, wrapping midnight). No weather
				-- module, no surge.
				NIGHT = { FROM = 22, TO = 5, MULTIPLIER = 1.3 },
			},

			-- The driver's share of a fare, in percent. The rest goes to the
			-- company account (`accounts` contract, kind 'job', key ACCOUNT) when
			-- that module runs; without it the driver keeps everything, as an
			-- `invoices` bill would.
			DRIVER_CUT_PCT = 70,
			ACCOUNT = 'cabbie',

			-- Records a driver must be in for a ride to count; empty = any car.
			-- e.g. { 'Vehicle.v_standard2_villefort_cortes_delamain_player' }
			VEHICLES = {},

			-- STREET FARES: when the board is empty, a driver may take an NPC
			-- fare -- drive to a pickup, take the passenger to a destination.
			-- Paid by the company out of thin air (minted), capped per driver per
			-- rolling hour, and on the STRAIGHT distance pickup -> destination,
			-- so a detour earns nothing.
			NPC_FARES = {
				ENABLED = true,
				-- Only offered when no player call is open for this company.
				ONLY_WHEN_IDLE = true,
				BASE = 25,
				PER_KM = 20,
				HOURLY_CAP = 1500,
				MONEY_TYPE = 'BANK',
				-- Metres around a point that count as being there.
				RADIUS = 12.0,
				-- Seconds a street fare may take before the passenger gives up.
				TTL_S = 900,
				-- A destination closer than this to its pickup is never drawn.
				MIN_TRIP_M = 400,
				PICKUPS = {
					{ LABEL = 'Corpo Plaza - Arasaka tower forecourt', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Jig-Jig Street - Japantown', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Lizzie\'s Bar - Little China', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Delamain HQ - Little China', X = 0.0, Y = 0.0, Z = 0.0 },
				},
				DESTINATIONS = {
					{ LABEL = 'Afterlife - Little China', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Embers - Corpo Plaza', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Kabuki Market - Watson', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Rancho Coronado - Santo Domingo', X = 0.0, Y = 0.0, Z = 0.0 },
					{ LABEL = 'Night City Airport - Pacifica road', X = 0.0, Y = 0.0, Z = 0.0 },
				},
			},
		},

		-- ── Night City Cab Co. ─────────────────────────────────────────────
		-- The indie example: a human dispatcher, cheaper fares, no AI. Ships
		-- DISABLED because its job does not exist yet -- add a `nccab` job to
		-- `config/character.lua` (or point JOBS at one you have) and switch it on.
		nccab = {
			ENABLED = false,
			LABEL = 'Night City Cab Co.',
			SHORT = 'NCCC',
			JOBS = { nccab = 0 },
			ON_DUTY = true,
			VOICE = 'generic',
			BLIP = { COLOR = '#3FB6FF' },
			DISPATCH = { MIN_GRADE = 0, CALL_TTL_S = 240 },
			FARE = {
				MONEY_TYPE = 'EDDIES',
				BASE = 25, PER_KM = 22, MIN = 40, MAX = 2500,
				NIGHT = { FROM = 23, TO = 4, MULTIPLIER = 1.15 },
			},
			DRIVER_CUT_PCT = 85,
			ACCOUNT = 'nccab',
			VEHICLES = {},
			NPC_FARES = { ENABLED = false },
		},
	},
}
