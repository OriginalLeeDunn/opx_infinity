--- Medical services: who answers a body on the ground, what they may do to it,
--- and what it costs.
-- @author dop42
--
-- SEVERAL SERVICES, ONE FILE. Night City does not have one ambulance: it has
-- Trauma Team International, who come in an AV for a client and for nobody
-- else, and it has a ripperdoc down the street who will patch anybody with the
-- eddies. Each is one entry under SERVICES, keyed by a name of your choosing,
-- and every rule below is per service. Add a third (a Scav clinic, a corpo
-- in-house medic, a Militech field unit) by copying a block and changing JOBS.
--
-- Shared, like the garages and fuel configs: the client reads the desks it
-- draws, the treatment labels and the key here; the server re-derives every
-- bound and decides everything. Nothing in this file is believed from a client.
--
-- A SERVICE IS GATED LIKE A LIFT. `JOBS = { trauma = 0 }` and `ON_DUTY = true`
-- mean exactly what they mean on `elevators`, `teleports` and `hauling`
-- (`lib/shared/jobgate.lua`): any listed job at or above its grade is enough,
-- and ON_DUTY asks that it be held on duty.
--
-- MONEY TYPES are the names in `config/shared.lua` MONEY.TYPES ('EDDIES' cash,
-- 'BANK'). Durations are milliseconds unless the key says _S (seconds) or
-- DAYS. Health shares are fractions of the pool, 0..1.

OPX.Config.MODULES.medical = {
	enabled = true,

	-- 'primary': only the character's primary job counts; 'any': a secondary
	-- job held in `jobs` counts too. The same switch `hauling` reads.
	MEMBERSHIP = 'primary',

	-- Milliseconds between two requests of one kind from one player.
	REQUEST_MS = 750,

	-- Milliseconds between two sweeps of the open calls: expiry, patients who
	-- got up some other way, responders who left.
	SCAN_MS = 2000,

	-- Metres between a medic and the body they work on, measured by the server
	-- (plus `REACH_SLACK` from `config/shared.lua`), and the eye row's reach.
	REACH = 3.0,

	-- The dispatch board: a key every member of a medical service may press to
	-- list the open calls, take one, or drop the one they hold. `false` as
	-- DEFAULT switches the key off.
	DISPATCH_KEY = { ID = 'opx.medical.dispatch', NAME = 'medical.key.dispatch', DEFAULT = 'F6' },

	-- What a call looks like on a responder's map. SPRITE is a blips alias (see
	-- `config/blips.lua` for the vocabulary); a service may carry its own.
	BLIP = { SPRITE = 'objective', WALLS = true },

	-- The toast a new call raises on a responder's screen, in milliseconds.
	ALERT_MS = 8000,

	-- The wall-clock key a subscription is written under in character metadata.
	-- Change it only on a fresh database: rows written under the old key are
	-- then nobody's.
	METADATA_KEY = 'medical',

	SERVICES = {
		-- ── Trauma Team International ──────────────────────────────────────
		-- A contract, not a charity. A subscriber's biomonitor calls TTI the
		-- moment they flatline; anyone else has to beg, and pays triple.
		trauma = {
			LABEL = 'Trauma Team International',
			SHORT = 'TTI',
			JOBS = { trauma = 0 },
			ON_DUTY = true,
			BLIP = { SPRITE = 'objective' },

			DISPATCH = {
				ENABLED = true,
				-- 'subscribers': a call is opened only for a client (or, with
				-- OFF_CONTRACT, for anyone who asks for help and pays the premium).
				-- 'anyone': every player who asks for help is a call.
				ANSWERS = 'subscribers',
				OFF_CONTRACT = true,
				-- Grade a member needs to see and take calls.
				MIN_GRADE = 0,
				-- Responders one call can hold at once: a TTI team is more than one.
				RESPONDERS = 2,
				-- Seconds an untaken call stays on the board.
				CALL_TTL_S = 600,
			},

			SUBSCRIPTION = {
				ENABLED = true,
				MONEY_TYPE = 'BANK',
				-- PRIORITY sorts the board (higher first). AUTO_ALERT is the
				-- biomonitor: the call opens on the flatline, without the patient
				-- asking. DISCOUNT is the share of every treatment fee waived.
				TIERS = {
					silver = { LABEL = 'Silver', PRICE = 2500, DAYS = 7, PRIORITY = 1,
						AUTO_ALERT = false, DISCOUNT = 0.25 },
					gold = { LABEL = 'Gold', PRICE = 7500, DAYS = 7, PRIORITY = 2,
						AUTO_ALERT = true, DISCOUNT = 0.5 },
					platinum = { LABEL = 'Platinum', PRICE = 20000, DAYS = 7, PRIORITY = 3,
						AUTO_ALERT = true, DISCOUNT = 1.0 },
				},
				-- Where a contract is signed: ALT on the desk. A desk left at the
				-- placeholder 0,0,0 is disabled and named at boot; stand on the spot
				-- in game and paste your position in.
				DESKS = {
					{ LABEL = 'TTI - Watson', X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 1.5 },
				},
			},

			-- KIND 'revive' works on a body that is down and stands it up with
			-- HEALTH of the pool, under a progress bar while the medic plays
			-- ANIMATION (an emote name from `config/animations.lua`; 'examine' is
			-- the kneel-and-look-closer workspot, '' for none).
			--
			-- KIND 'heal' works on a LIVING body below full and adds HEAL of the
			-- pool. It runs through the platform's two-player coordinator
			-- (`Open77.playerInteractions`, kind `heal`): the medic kneels and
			-- examines, the patient sits wounded, both see it. CONSENT = true sends
			-- the patient an invitation they accept or decline -- nobody gets
			-- patched against their will -- and false skips it (a patient in your
			-- clinic chair has already said yes). Without the coordinator on the
			-- server, a heal falls back to the same progress bar a revive uses.
			--
			-- ITEMS are consumed from the MEDIC's bag once the act completes,
			-- name -> count. FEE is billed to the patient, PAY is what the medic is
			-- paid on top of their salary.
			--
			-- PROP is an `Items.*` record the medic holds in the right hand while the
			-- work runs (`Open77.heldItems.hold`), '' for none. It ships off: no
			-- medkit record is confirmed against this build's catalogue yet, and a
			-- wrong one only costs a line in the journal. It shares the right hand
			-- with weapons, so a drawn gun is put away for it.
			TREATMENTS = {
				revive = { KIND = 'revive', LABEL = 'medical.treat.revive', MIN_GRADE = 0,
					DURATION_MS = 10000, ITEMS = { maxdoc = 1 }, HEALTH = 0.6, GRACE_MS = 5000,
					FEE = 3000, PAY = 600, ANIMATION = 'examine', PROP = '' },
				heal = { KIND = 'heal', LABEL = 'medical.treat.heal', MIN_GRADE = 0,
					DURATION_MS = 6000, ITEMS = { bounce_back = 1 }, HEAL = 0.5, CONSENT = true,
					FEE = 800, PAY = 150, ANIMATION = 'examine', PROP = '' },
			},


			-- Carrying a patient to the AV or the clinic: the platform's two-player
			-- `carry` (the medic walks, the patient is in their arms). The engine
			-- refuses a dead body, so it is offered on a patient who is UP --
			-- revived, or hurt and walking -- never on one who is down. CONSENT asks
			-- the patient first, as a heal does.
			CARRY = { ENABLED = true, DURATION_S = 180, CONSENT = true, MIN_GRADE = 0 },

			-- Treatment beds. A patient standing within RADIUS of one when a heal
			-- starts is laid on it (`Open77.animations.playAt`, POSE 'lie') for the
			-- length of the bar instead of sitting wounded on the floor. Placeholders
			-- at 0,0,0 are disabled; stand at the bed and paste your position and
			-- the yaw the body should face.
			BEDS = {
				{ LABEL = 'TTI - trauma bay', X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0, RADIUS = 1.5, POSE = 'lie' },
			},

			BILLING = {
				ENABLED = true,
				MONEY_TYPE = 'BANK',
				-- What a non-subscriber pays on top of FEE when TTI comes anyway.
				OFF_CONTRACT_MULTIPLIER = 3.0,
				-- When the patient cannot pay: 'debt' treats and writes what is
				-- owed to their metadata, 'refuse' refuses before the bar starts,
				-- 'free' treats and forgets it.
				ON_UNPAID = 'debt',
				PAY_MONEY_TYPE = 'BANK',
			},
		},

		-- ── The street ripperdoc ───────────────────────────────────────────
		-- No contract and no AV: anybody bleeding who asks for help shows up on
		-- the board, and the doc patches them for cash at street prices.
		ripperdoc = {
			LABEL = 'Ripperdoc',
			SHORT = 'DOC',
			JOBS = { ripperdoc = 0 },
			ON_DUTY = true,

			DISPATCH = {
				ENABLED = true,
				ANSWERS = 'anyone',
				OFF_CONTRACT = false,
				MIN_GRADE = 0,
				RESPONDERS = 1,
				CALL_TTL_S = 600,
			},

			SUBSCRIPTION = { ENABLED = false },

			TREATMENTS = {
				-- An apprentice can bandage; standing a body back up takes a doc.
				revive = { KIND = 'revive', LABEL = 'medical.treat.revive', MIN_GRADE = 1,
					DURATION_MS = 15000, ITEMS = { maxdoc = 1 }, HEALTH = 0.35, GRACE_MS = 3000,
					FEE = 1200, PAY = 300, ANIMATION = 'examine', PROP = '' },
				bandage = { KIND = 'heal', LABEL = 'medical.treat.bandage', MIN_GRADE = 0,
					DURATION_MS = 4000, ITEMS = { bandage = 1 }, HEAL = 0.2, CONSENT = true,
					FEE = 150, PAY = 40, ANIMATION = 'examine', PROP = '' },
			},


			CARRY = { ENABLED = true, DURATION_S = 120, CONSENT = true, MIN_GRADE = 0 },
			BEDS = {
				{ LABEL = 'Back-alley table', X = 0.0, Y = 0.0, Z = 0.0, YAW = 0.0, RADIUS = 1.5, POSE = 'lie' },
			},

			BILLING = {
				ENABLED = true,
				MONEY_TYPE = 'EDDIES',
				OFF_CONTRACT_MULTIPLIER = 1.0,
				ON_UNPAID = 'debt',
				PAY_MONEY_TYPE = 'EDDIES',
			},
		},
	},
}
