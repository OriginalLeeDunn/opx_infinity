--- The staff tool: keys, rates, placement, tags, vehicles and the linked commands.
-- @author dop42
--
-- No secret and no grant lives here. This file is a shared script that every
-- client downloads, and the ACL is the host's: the access map the menu is sent
-- only greys out what the host would refuse anyway.
--
-- LINKS names OTHER modules' command names, so that a renamed command is
-- followed here rather than in code, and `false` removes the row that drives it.
-- They are command names and not contract calls on purpose: a command is
-- resolved against `command.<name>` by the host before its handler runs, and a
-- contract call from a client would be no permission check at all.
--
-- The numbers marked "tunable" below are the DEFAULTS of a panel entry. They are
-- declared from the module's `Init` and read at the moment of use, so an operator
-- moves them while people are playing; everything else here is read at start.

OPX.Config.MODULES.admin = {
	enabled = true,

	-- Default keys players rebind in the pause menu; false registers none.
	--
	-- THERE IS NO DEV KEY ANY MORE. `DEV = 'F10'` stood here and opened the staff
	-- menu on a screen called Dev -- the screen a server was set up from. The
	-- owner deleted that screen on 2026-09-21 ("il y a pas de config live c'est
	-- tous par les fichier config donc degage moi ce menu est pass moi tous dans
	-- les config"), so the key had nothing left to land on and went with it. F10
	-- is free again. What that screen PLACED is a line in `config/dealership.lua`
	-- now; what it READ is a command an operator types.
	--
	-- TO CAPTURE A POSITION FOR ONE OF THOSE CONFIG FILES: stand where you want
	-- it, FACE THE WAY IT SHOULD FACE, and run `/opx.admin.self.pos` -- Self ->
	-- Position on this menu, or the row on the target eye. It copies
	-- `{ NAME = ..., X = ..., Y = ..., Z = ..., HEADING = ... }` to the operating
	-- system clipboard, with the facing you are actually standing at, ready to
	-- paste. That is the whole capture path, and every config file that wants a
	-- coordinate names it.
	KEYS = {
		MENU = 'F9',
		SPEED_UP = 'PAGEUP',
		SPEED_DOWN = 'PAGEDOWN',
	},

	-- Per-operator floors between two runs of one command, in milliseconds.
	-- Tunable: ADMIN_RATE_ACTION_MS, ADMIN_RATE_READ_MS, ADMIN_RATE_REFRESH_MS.
	RATE = {
		ACTION_MS = 400,
		READ_MS = 1000,
		REFRESH_MS = 750,
	},

	-- Actions `opx.admin.read.audit` looks back over. Tunable: ADMIN_AUDIT_ENTRIES.
	AUDIT_ENTRIES = 200,

	-- How long a target's staff action toast stays up. Tunable: ADMIN_TOAST_MS.
	TOAST_MS = 6000,

	-- How a moved player lands. A placement is a kill and a respawn, never a
	-- transform write, so it always costs a death and always gives health back.
	-- Tunable: ADMIN_PLACEMENT_GRACE_MS.
	PLACEMENT = {
		HEALTH = 1.0,
		GRACE_MS = 5000,
		BESIDE = { X = 1.5, Y = 0.0, Z = 0.0 },
		OBSERVE_HEIGHT = 2.0,

		-- How long an observe keeps its noclip -- and the hidden body that comes
		-- with it -- for an operator NOT granted `opx.admin.self.noclip`. One who
		-- is granted it keeps flying until they turn it off.
		OBSERVE_MS = 120000,
	},

	-- Noclip speed and its on-screen controls. Client-side: the tunables panel is
	-- the server's, so these are read at start.
	NOCLIP = {
		SPEED = 40.0,
		MIN_SPEED = 1.0,
		MAX_SPEED = 500.0,
		STEP = 0.15,
		-- Never below RATE.ACTION_MS plus 100: a quieter send would be refused.
		SEND_AFTER_MS = 500,
		PROMPTS = true,

		-- The pop: what is played where the operator is standing when noclip goes
		-- on, and again when it goes off. This is this engine's stand-in for the
		-- particle `txadmin` plays on the ped both ways -- the FiveM asset cannot
		-- be loaded here, so the name comes out of the engine's own catalogue
		-- (`Open77.vfx.catalog()`, 51 aliases).
		--
		-- A depot path is accepted too; nothing else is. A name the catalogue does
		-- not carry is answered `nil, invalid_argument` and draws nothing.
		--
		-- `fire.large` is the default for one reason: of the aliases tried from
		-- Lua on 2.31 it is the one with an actual frame captured
		-- (`docs/research/vfx-sfx-runtime.md`, "Full template and world-effect
		-- live probes", 2026-09-05 -- a tall flame and a refractive plume).
		-- `electric.emp` and `electric.arc` were tried in the same probe and
		-- produced no identifiable visual, `neon.holo_zone` renders only at its
		-- authored yaw, and nothing else in the catalogue is recorded as seen at
		-- all -- so a prettier-looking dematerialise here would be a guess that
		-- probably draws nothing. Change this line to taste; it is one line.
		--
		-- EMPTY ON PURPOSE. It was `fire.large` and the owner asked for it gone
		-- on 2026-09-21: a tall flame at the operator's feet every time noclip
		-- goes on or off reads as something being on fire, which is not what a
		-- staff member toggling a camera wants to announce to the street. The
		-- alias is left written above so putting it back is one word.
		EFFECT = '',
		-- Seconds the effect lives, 0..600 (the engine's own ceiling). 0 hands the
		-- rest of its life to the effect itself.
		EFFECT_SECONDS = 1.5,
		-- A Wwise event name, or '' for silence. Left empty because a wrong name
		-- is answered with a handle and discarded in silence rather than refused,
		-- so an invented event is indistinguishable from no sound -- and no event
		-- name is confirmed for this build.
		SOUND = '',

		-- Whether the body is despawned while the operator is flying. What it
		-- means: the same native the Invisible switch uses, hidden from every
		-- other player, and given back the moment noclip ends -- or when the
		-- Invisible switch is turned back on, whichever comes last.
		HIDE_BODY = true,
	},

	-- Metres the staff rows on the target eye reach, 1..12.
	TARGET = {
		DISTANCE = 10.0,
	},

	-- Wearing an NPC body. The allowlist is `modules/admin/data/peds.lua`, whose
	-- 250 rows are the `Character.*` records the official catalogue marks as
	-- ordinary human rigs; nothing outside it is accepted, by name or by record.
	--
	-- This needs `Open77.players.setModel`, which arrived after
	-- 2.31.13+op77.76. On an older server both commands refuse with
	-- `models_unavailable` and the menu greys their rows.
	MODELS = {
		-- Whether a death gives the player their own body back. False keeps the
		-- ped on through a respawn, which is what a long-running disguise wants
		-- and what a quick gag does not.
		RESET_ON_DEATH = true,
		-- Milliseconds a ped lasts before the platform takes it off by itself.
		-- Zero lasts until somebody takes it off; the ceiling is one day.
		DURATION_MS = 0,
	},

	-- Damage between players when the server starts; staff switch it live.
	COMBAT = {
		PVP = true,
	},

	-- Name tags staff see above nearby players. Client-side.
	-- Tunable: ADMIN_TAGS_REFRESH_MS, which is the server's list interval.
	TAGS = {
		DISTANCE = 25.0,
		FADE_START = 0.55,
		HEAD_LIFT = 0.35,
		HEAD_OFFSET_Z = 2.05,
		UPDATE_MS = 250,
		REFRESH_MS = 2000,
		MAX = 32,
		OWN = false,
		HIDE_IN_FIRST_PERSON = false,

		-- What a tag says, left to right: the id square, the character's name,
		-- the account playing them, the character's public id. The name is not a
		-- switch -- a tag with no name on it is not a tag -- and it falls back to
		-- the account for a slot that has loaded nobody, in which case USERNAME
		-- draws nothing rather than the same word twice.
		TECHNICAL = true,
		USERNAME = true,
		CITIZEN = true,
		BADGE = true,
		COLORS = {
			TEXT = '#F2F6F8',
			ACCENT = '#FCEE0A',
			STAFF = '#22D8E2',
			BACKGROUND = '#0A1220',
		},
	},

	-- How an announcement reaches every player. Tunable: ADMIN_ANNOUNCE_MS.
	ANNOUNCE = {
		DURATION_MS = 12000,
		CHAT = true,
		MAX_CHARACTERS = 240,

		-- Least time between two announcements, from any operator; the console is
		-- exempt. 0 turns the floor off.
		COOLDOWN_MS = 10000,

		-- THE TWO STINGERS THAT WRAP THE MESSAGE, by BARE FILE NAME.
		--
		-- They are files in this resource -- `ui/public/audio/` here, `web/audio/`
		-- once built -- and the page resolves a name against ITS OWN origin, which
		-- is why a name may hold no slash and no `..`: the client that honours one
		-- is a machine this server does not own, and a config able to point it at
		-- another origin would be a config able to make every client fetch from
		-- somewhere else.
		--
		-- `OPEN` plays BEFORE the message appears and holds it back while it runs;
		-- `CLOSE` plays once the message has gone. Either may be `''`, which is how
		-- a server turns one off without turning the announcement off.
		--
		-- A NAME THAT DOES NOT FIT THE RULE IS DROPPED, with a log line, and the
		-- announcement still arrives. A typo in a presentation setting must never
		-- cost a player the sentence an operator sent them.
		STINGER = {
			OPEN = 'announce-open.mp3',
			CLOSE = 'announce-close.mp3',

			-- 0..1. An announcement is not a gunfight, and this is the number an
			-- operator turns down when it is louder than the city.
			VOLUME = 0.8,
		},
	},

	-- Durations the ban form offers; a typed ban takes any duration.
	BAN_DURATIONS = { '1h', '1d', '7d', '30d', 'perm' },

	-- Vehicle spawning, the near search and repairs.
	-- Tunable: ADMIN_VEHICLE_PER_OWNER, ADMIN_VEHICLE_NEAR_RADIUS.
	VEHICLES = {
		SPAWN_OFFSET = { X = 3.0, Y = 0.0, Z = 0.25 },

		-- WHICH RECORDS ARE AVs IS NOT AN ADMIN SETTING. It is one list,
		-- `AV_MATCHES` in `config/shared.lua`, read by one helper. This key was
		-- the third copy and the one whose code differed: emptying it alone
		-- reclassified every AV as ground in the staff catalogue while the garage
		-- and the dealer went on calling the same records air. The answer still
		-- decides two things here and nothing else -- the lift below, and which
		-- rows the spawn menu's Air class holds.

		-- Metres a spawned AV is lifted above the spawn offset. An AV record's
		-- pivot is the chassis centre, so one created at ground level starts
		-- half-buried -- the same reason the dealership lifts one 1.2 m.
		AV_LIFT = 1.2,

		PER_OWNER = 8,
		NEAR_RADIUS = 30.0,

		-- Metres a TYPED vehicle id may be from the operator, in their own
		-- instance, for an operator not holding the raw ACL right
		-- `opx.admin.vehicle.anywhere`. A vehicle carrying the operator always
		-- qualifies.
		REACH = 100.0,
		OCCUPIED_REPAIRS = { glass = true, body = true, lights = true, tires = true, visual = true },
		FLAGS = { 'locked', 'engineOn', 'lightsOn', 'invulnerable' },
	},

	-- Largest count an item or ammunition give or removal accepts.
	-- Tunable: ADMIN_INVENTORY_MAX_COUNT.
	INVENTORY = {
		MAX_COUNT = 10000,
		-- The inventory contract does not say what ammunition a weapon loads, so
		-- ammunition is named by its own item and this is the count a give uses
		-- when none is typed. See the module header.
		DEFAULT_AMMO = 60,
	},

	-- Doors. The official `open77_doors` owns every door while it runs and this
	-- module stands down; these bound what it does when that resource is absent.
	DOORS = {
		-- Doors one routing bucket may hold a staff state for.
		MAX_PER_BUCKET = 256,
		-- Milliseconds between two looks at which bucket each player is in.
		SWEEP_MS = 2000,
		-- Milliseconds between two looks at the doors streamed around a client.
		SCAN_MS = 1000,
		-- Metres around a client doors are looked for, within the native's 100.
		SCAN_RADIUS = 80,
	},

	-- Other modules' command names the menu and the eye drive; false removes the
	-- row. A renamed command is followed here.
	LINKS = {
		PLAYERS = 'opx.players',
		WHERE = 'opx.where',
		JOB = 'opx.job',
		GANG = 'opx.gang',
		MONEY = 'opx.money',
		SAVE = 'opx.save',
		INVENTORY_OPEN = 'opx.inventory.open',
		INVENTORY_HOLDERS = 'opx.inventory.holders',
		WEATHER_SET = 'opx.weather.set',
		WEATHER_NEXT = 'opx.weather.next',
		WEATHER_FREEZE = 'opx.weather.freeze',
		TIME = 'opx.time',
		TIME_FREEZE = 'opx.time.freeze',
		-- The levels, for testing or for fun: Myself and each player's page run
		-- `max` -- the skill tree at its cap AND the base game's own levels maxed
		-- on that player's machine (`config/skills.lua` DEVELOP) -- and `reset`.
		SKILLS_LEVEL = 'opx.skills.level',
		-- The ripperdoc's override on the operator's own body: `full` puts a
		-- fresh life on every piece of chrome fitted (Myself only).
		CHROME = 'opx.clinic.chrome',
		-- The door panel: `modules/doorlock`, opened by its own restricted command.
		DOORLOCK = 'opx.doorlock',
	},

	-- Weather names the sky screen offers. They are the NAME column of
	-- OPX.Config.MODULES.weather.WEATHER.
	WEATHER_PRESETS = { 'sunny', 'lightclouds', 'cloudy', 'rain', 'heavyclouds', 'fog',
		'pollution', 'sandstorm' },

	TIMES = { '06:00', '09:00', '12:00', '17:30', '20:30', '23:00', '03:00' },

	-- Saved destinations. `opx.admin.self.pos` copies a row in this shape.
	LOCATIONS = {
		{ NAME = 'watson', LABEL = 'Watson, west', X = -667.14, Y = -382.61, Z = 9.16, HEADING = 0.0 },
		{ NAME = 'heights', LABEL = 'Northwest heights', X = -1441.0, Y = 1269.0, Z = 123.0,
			HEADING = 180.0 },
		{ NAME = 'coast', LABEL = 'Southwest coast', X = -1716.38, Y = -2421.28, Z = 62.59,
			HEADING = 0.0 },
		{ NAME = 'stoop', LABEL = 'Watson, King Stoop forecourt', X = -410.22, Y = 722.73, Z = 115.0,
			HEADING = 147.0 },
		{ NAME = 'northside', LABEL = 'Watson, north promenade', X = -469.47, Y = 930.99, Z = 56.45,
			HEADING = -68.0 },
		{ NAME = 'junction', LABEL = 'Watson, lower junction', X = -644.91, Y = 1019.37, Z = 36.56,
			HEADING = 75.5 },
		{ NAME = 'underpass', LABEL = 'Watson, lower underpass', X = -701.49, Y = 1033.97, Z = 35.71,
			HEADING = -104.5 },
		{ NAME = 'dealer', LABEL = 'Westbrook, vehicle dealership', X = -1442.2, Y = 127.4, Z = 18.0,
			HEADING = 0.0 },
		{ NAME = 'racegrid', LABEL = 'Westbrook, race grid', X = -1450.2, Y = 119.9, Z = 14.8,
			HEADING = 200.0 },
		{ NAME = 'lab', LABEL = 'East, laboratory', X = 1669.75, Y = -739.12, Z = 49.86,
			HEADING = 0.0 },
		{ NAME = 'arena', LABEL = 'Badlands, arena', X = 381.36, Y = -2401.79, Z = 181.99,
			HEADING = 0.0 },
	},
}
