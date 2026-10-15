--- How long a downed player waits, where they wake, and who may stand them up.
-- @author dop42

OPX.Config.MODULES.downed = {
	enabled = true,

	-- HOW A PLAYER GOES DOWN.
	--   'wounded'  a lethal hit is held at the edge by the server's damage
	--              arbiter: the player goes down ALIVE at WOUNDED.HEALTH, held on
	--              the ground, and can be revived, carried, cuffed -- or finished.
	--              They flatline (really die) on a finishing blow WOUNDED.FINISH
	--              allows, when the bleed-out runs out, or from anything that went
	--              round the arbiter; from there it is the 'death' screen.
	--   'death'    the body dies and the screen opens on the dead body: a lethal
	--              hit is death, straight away, with no stage in between.
	--
	-- SHIPS 'death' -- THE OWNER'S CALL (2026-10-13): "quand tu meurs c'est
	-- directement dead". 'wounded' stays in the code, switched off, for a server
	-- that wants finishing blows and carrying the wounded.
	MODE = 'death',

	WOUNDED = {
		-- Health points a held hit leaves, and what a wounded body is kept at.
		HEALTH = 1,
		-- Seconds wounded before the body flatlines on its own. 0: never.
		BLEED_OUT_S = 300,
		-- Hold the body where it fell (`Open77.players.setFrozen`).
		FREEZE = true,
		-- The RP pose a wounded body plays on the ground ('' for none). 'wounded'
		-- is the seated, breathing-hard workspot; 'arrested' lies face down.
		POSE = 'wounded',
		-- Who may land a finishing blow on a wounded body. A hit from anybody
		-- else is refused outright. OTHERS is NPCs, the world and explosions.
		FINISH = { PLAYERS = true, OTHERS = false },
	},

	-- Seconds down before GIVE UP unlocks, and how long it is held so that a
	-- stray click respawns nobody. The server enforces both.
	GIVE_UP_AFTER_S = 120,
	GIVE_UP_HOLD_MS = 1500,

	-- How a player who gave up wakes, in the bucket they fell in: a fraction of
	-- full health, and the spawn protection that follows.
	RESPAWN = {
		HEALTH = 0.5,
		GRACE_MS = 5000,
	},

	-- The fade to black around a give up: out before the body moves, in once it
	-- stands at the medical center HOLD_MS later. Durations in milliseconds.
	FADE = { ENABLED = true, MS = 600, HOLD_MS = 1500 },

	-- Respawn points, the nearest to the fall winning. Replace the starter row
	-- with your own medical centers.
	HOSPITALS = {
		{ LABEL = 'Watson medical center', X = -667.14, Y = -382.61, Z = 9.16, HEADING = 0.0 },
	},

	-- What a revive through the contract leaves the player with.
	REVIVE = {
		HEALTH = 0.35,
		GRACE_MS = 3000,
	},

	-- THE TRAUMA TEAM: WHO HEARS A DISTRESS SIGNAL, AND WHO ANSWERS IT.
	--
	-- THE AUDIT OF 2026-09-30 FOUND THE JOB HAD NO GAMEPLAY. A paramedic could
	-- sign up and clock in, and then nothing: WAIT FOR HELP stored a flag and
	-- told the downed player "Help has been called" while nobody was called, and
	-- the only thing that could stand a body up was a staff command. This block is
	-- the other half of that button.
	--
	--   * THE PAGE. Pressing WAIT FOR HELP pages every connected player whose
	--     primary job is in `JOBS` and who is ON DUTY: a loud toast with the
	--     patient's name and where they fell (rounded to `PAGE.ROUND_METRES`), and
	--     a pin on their map for `PAGE.PIN_SECONDS` that comes down the moment the
	--     patient is up. A medic who clocks in while somebody is still waiting is
	--     paged too. The down screen says how many were paged -- or that nobody is
	--     on duty -- instead of a promise nobody keeps.
	--   * THE TREATMENT. An on-duty medic within `TREAT.REACH_METRES` of a downed
	--     body sees a row and presses `KEY` (or types `/opx.treat`): the SERVER
	--     checks the job, the duty, that the medic is up and the patient is down,
	--     the distance to the body and the cooldown, and starts a
	--     `TREAT.SECONDS` bar on the medic's screen; the patient is told a medic is
	--     working on them. When the bar runs out the server checks everything again
	--     -- a medic who walked off or went down, or a patient who is already up,
	--     is no treatment -- and revives the patient where they lie at
	--     `REVIVE.HEALTH`.
	--   * THE PAY. `REWARD.AMOUNT` into the medic's `REWARD.ACCOUNT` per revive, at
	--     most once per `REWARD.PER_PATIENT_MS` for the same patient's character,
	--     so two friends taking turns on the floor are not a money machine. `0`
	--     pays nothing; the job's salary is paid either way.
	--
	-- `enabled = false` (or `TRAUMA = false`) is the old screen: nobody is paged,
	-- nobody but staff revives, and the down screen says nobody is coming.
	TRAUMA = {
		enabled = true,
		JOBS = { 'trauma' },
		KEY = { ID = 'opx.downed.treat', NAME = 'medic.key.treat', DEFAULT = 'E' },
		PAGE = {
			ROUND_METRES = 5.0,
			PIN_SECONDS = 300,
			PIN_SPRITE = 'objective',
			TOAST_MS = 12000,
		},
		TREAT = {
			REACH_METRES = 4.0,
			SECONDS = 6,
			COOLDOWN_MS = 3000,
		},
		REWARD = {
			AMOUNT = 150,
			ACCOUNT = 'BANK',
			PER_PATIENT_MS = 600000,
		},

		-- THE TRAUMA TEAM'S OWN AV. The bot lab, 2026-10-07: "the whole trauma
		-- team av isnt landing when somebody is down and reviving them". A
		-- distress signal now also brings the city's Trauma Team: an AV with its
		-- landing call ("Warning. Clear the area. Trauma Team landing.", see
		-- CALLOUTS in config/avdoor.lua) lands LAND_OFFSET_METRES from the body.
		-- A MEDIC runs to the patient with the GUARDS beside them, treats for
		-- TREAT_SECONDS and revives them where they lie (REVIVE above). Then the
		-- team boards and the AV leaves.
		--
		--   * PLAYERS FIRST. A patient nobody was paged for gets the team after
		--     DELAY_SECONDS. One an on-duty medic was paged for is left to that
		--     medic for MEDIC_HEAD_START_SECONDS (`false`: never). A patient a
		--     medic is treating is never taken.
		--   * ONE AV PER SCENE. A patient down within SCENE_METRES of an AV still
		--     coming or on the ground joins its list, and the medic goes from body
		--     to body. At most MAX_RUNS AVs fly at once. HOLD_SECONDS bounds the
		--     time on the ground.
		--   * The revive is timed by the server: the run to the body (RUN_SPEED
		--     metres a second, 12 s at most) plus TREAT_SECONDS. A walk a client
		--     never shows costs the patient no revive.
		--
		-- The AV is flown like the MaxTac insertion: frozen and posed by the
		-- server, APPROACH_METRES out at APPROACH_ALTITUDE, in over
		-- CRUISE_SECONDS to HOVER_ALTITUDE, down over DESCENT_SECONDS to
		-- LAND_ALTITUDE over the ground, then up over CLIMB_SECONDS and out
		-- EXIT_METRES over EXIT_SECONDS. MEDIC and GUARDS are `Character.*`
		-- records (the prologue's Trauma Team); they are passive, silent and
		-- invulnerable. `TEAM = false` or `enabled = false` keeps the pages and
		-- flies nothing.
		--
		-- THE AIRFRAME IS ONE THE GAMES CAN DRAW. The bot lab, 2026-10-07: "i hear
		-- tramua team but i dont see av". `Vehicle.av_trauma` names an entity
		-- template that is in none of the game's archives (2.31, base and
		-- Phantom Liberty), so every game registered its spawn and never drew it.
		-- `AV.RECORDS` are Trauma Team airframes whose templates are there
		-- (basegame_4_gamedata.archive), in the order they are tried: the games
		-- near the landing spot are asked whether they draw the hull, and one that
		-- registered it and did not draw it in WATCH_SECONDS sends the AV on in the
		-- next record, where it is. WATCH_METRES is how near "near" is.
		TEAM = {
			enabled = true,
			DELAY_SECONDS = 8,
			MEDIC_HEAD_START_SECONDS = 45,
			SCENE_METRES = 60.0,
			MAX_RUNS = 2,
			MEDIC = 'Character.q001_tt_medic',
			GUARDS = { 'Character.q001_tt_soldier' },
			RUN_SPEED = 4.5,
			TREAT_SECONDS = 6,
			BOARD_SECONDS = 3,
			HOLD_SECONDS = 90,
			AV = {
				-- The prologue's Trauma Team AV first; then two of the city's.
				-- Not `Vehicle.av_trauma` or `Vehicle.sq024_trauma_team_av`: no
				-- template in the game's archives, nothing a game can draw.
				RECORDS = { 'Vehicle.q001_trauma_av', 'Vehicle.sq021_av_trauma', 'Vehicle.mws_pac_06_trauma_av' },
				WATCH_SECONDS = 12,
				WATCH_METRES = 400.0,
				APPROACH_METRES = 260.0,
				APPROACH_ALTITUDE = 80.0,
				HOVER_ALTITUDE = 22.0,
				LAND_ALTITUDE = 1.5,
				LAND_OFFSET_METRES = 10.0,
				CRUISE_SECONDS = 6,
				DESCENT_SECONDS = 4,
				CLIMB_SECONDS = 4,
				EXIT_SECONDS = 6,
				EXIT_METRES = 320.0,
				TICK_MS = 100,
				-- The engine on while the team is on the street. Off by default:
				-- the AV sits down and spools up again to leave.
				ENGINE_ON_GROUND = false,
			},
		},
	},

	-- Callers allowed to revive, and callers allowed to set the screen aside
	-- while their own surface is up. A caller now gives its own name, so both are
	-- switches rather than boundaries.
	REVIVERS = '*',
	-- Keys are MODULE ids, the name a caller passes to the downed contract's
	-- `Suspend`. `admin` is the only caller: the staff menu sets the screen aside
	-- so a downed staff member can still use it. (`opx77_admin`, the resource
	-- `admin` replaced, was listed here too; another resource cannot reach this
	-- runtime's contracts at all, so that entry could never match a caller.)
	SUSPENDERS = { admin = true },

	-- Stock HUD components hidden while down.
	--
	-- ALL THIRTEEN, WHICH IS NOT WHAT `config/hud.lua` DOES, and the difference
	-- is the point. That list is a steady state and leaves the crosshair, the
	-- scanner and the phone to the game, because a player who is up needs to aim
	-- and scan. This is a player bleeding out: they cannot aim, cannot scan, and
	-- are not taking a call. Every stock component is chrome over a screen that
	-- has one thing to say.
	--
	-- Seven of these were named and six were absent, which read as a decision and
	-- was a gap. `Open77.hud.components()` is the authority on the set; a name
	-- this build does not know is refused per component and costs nothing.
	VANILLA_HUD = {
		'minimap', 'compass', 'clock', 'health', 'stamina', 'weapon', 'speedometer',
		'questTracker', 'phone', 'scanner', 'vanillaNotifications', 'crosshair', 'hubMenu',
	},
}
