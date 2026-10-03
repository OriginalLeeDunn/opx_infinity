--- Door locks: which world doors are managed, and who may lock or unlock them.
-- @author dop42
--
-- THE OWNER: "il faut faire maintenant un panel admin pour configurer les
-- doors, les portes fermées / ouvrables par des jobs, grades etc." The model is
-- ox_doorlock's, carried over field for field where Night City has the same
-- thing: a door has a name, one or two native doors (a double door is two), a
-- default state, the groups that may turn it (job or gang, each with a minimum
-- grade), the key items that turn it, the characters that turn it, an optional
-- passcode, an autolock delay, whether it may be picked and how hard, how close
-- a player has to stand, and whether the prompt is drawn at all.
--
-- A DOOR IS NAMED BY ITS NATIVE ID, never by a model or a coordinate. Open77
-- gives every world door an opaque 64-bit id, written `0x` and sixteen hex
-- digits (`0xFC85EAE29622BAC2`). Aim at a door with the target eye (ALT) and
-- the staff row "Manage door" captures it; the dev inspector copies it too.
--
-- TWO PLACES A DOOR CAN COME FROM, and they are not equal:
--
--   DOORS below     read-only defaults, in version control, reviewable. The
--                   staff panel can turn them (lock, unlock) and teleport to
--                   them, never edit or delete them -- this file is where they
--                   change.
--   the database    `opx77_doorlock`, written by the staff panel. Every door a
--                   staff member creates in game lives there, and the panel
--                   edits and deletes it. `/opx.doorlock.list` prints each one
--                   with the config block that would check it in here.
--
-- A key used by both is the config door; the database row is ignored and named
-- in the journal. A native door belongs to one managed door at a time.
--
-- THE SERVER DECIDES. A client sends "turn door X" and nothing else; the server
-- reads the player's own position and routing bucket from the host, the job,
-- gang and grade from the character module, the bag from the inventory module,
-- and only then moves the lock. Who may WRITE a door is the ACL:
--
--   command.opx.doorlock          open the staff panel, list doors
--   command.opx.doorlock.*        every staff action: save, remove, lock, key,
--                                 and `bypass` (turn any door without a key)
--
-- GROUPS: `{ JOB = 'ncpd', GRADE = 2 }` or `{ GANG = 'maelstrom', GRADE = 0 }`.
-- Any one group satisfied is enough, like ox. Names are the ones in
-- `config/character.lua`; a grade is the minimum grade LEVEL. ON_DUTY = true
-- on a door asks that a JOB group be the job being worked right now.
--
-- ITEMS: `{ NAME = 'keycard' }` opens for anybody carrying one; `REMOVE = true`
-- spends one per turn. `{ NAME = 'door_key', BOUND = true }` opens only for a
-- key cut for THIS door (`/opx.doorlock.key <door>`): the item's metadata
-- carries `door = <key>`. A bound key is never spent.
--
-- CHARACTERS: citizen ids, for the one flat that opens for one person.

OPX.Config.MODULES.doorlock = {
	enabled = true,

	-- Which door service enforces a lock.
	--   'auto'       the platform's `open77_doors` when it runs, else 'local'
	--   'networked'  `open77_doors` only: the server registers each managed door
	--                with it and the platform's own authority refuses a locked
	--                door to everybody. It must be in the server's load list.
	--   'local'      no platform service: the server holds the state and every
	--                client in the bucket puts its streamed doors into it with
	--                `Open77.doors.setLocked` and refuses vanilla interaction on
	--                a locked one. This is what the test server runs today:
	--                `open77_doors` depends on `open77_elevators`, which would
	--                take the cabins away from the job-gated `elevators` module.
	BACKEND = 'auto',

	-- Metres a player may stand from a door and still turn it, when the door
	-- names no MAX_DISTANCE of its own. Measured by the server, from the door's
	-- own position, with SLACK added for the latency between the press and the
	-- read. MAX_DISTANCE on a door is clamped to MAX_REACH.
	USE_RADIUS = 2.0,
	MAX_REACH = 8.0,
	SLACK = 1.0,

	-- How often the client looks for the nearest managed door (strip row, key)
	-- and, on the 'local' backend, puts streamed doors back into their state.
	SCAN_MS = 500,
	-- How far around the player streamed doors are read on the 'local' backend.
	SCAN_RADIUS = 40.0,

	-- Floor between two door requests from one player, in milliseconds.
	REQUEST_MS = 600,

	-- 'primary' reads the worked job (and the primary gang) only; 'any' counts
	-- every membership for the grade. ON_DUTY always reads the worked job.
	MEMBERSHIP = 'any',

	-- Staff holding `command.opx.doorlock.bypass` turn any door without a key.
	STAFF_BYPASS = true,

	-- The key that turns the door the player is standing at. ID is what a rebind
	-- is stored under and never changes; DEFAULT = false declares no key, and the
	-- target eye's row is then the only way to turn a door. E is shared with the
	-- garages, the stores, the lifts and the teleports: away from a managed door
	-- the key does nothing and says nothing.
	KEY = { ID = 'opx.doorlock.use', NAME = 'doorlock.key.use', DEFAULT = 'E' },

	-- The item a bound key is. `/opx.doorlock.key` cuts one; its metadata is
	-- `{ door = <key>, label = <door name> }`.
	KEY_ITEM = 'door_key',

	LOCKPICK = {
		-- The inventory item that picks a lock. One is needed in the bag.
		ITEM = 'lockpick',
		-- Whether a pick may also LOCK an unlocked door (ox's CanPickUnlockedDoors).
		CAN_PICK_UNLOCKED = false,
		-- Chance a failed attempt breaks the pick, 0..1. A success never breaks it.
		BREAK_CHANCE = 0.35,
		-- Per difficulty: how long the bar runs and the chance it works. The
		-- server times the attempt itself; a client that reports "done" early is
		-- refused.
		DIFFICULTY = {
			easy = { DURATION_MS = 4000, CHANCE = 0.85 },
			medium = { DURATION_MS = 6000, CHANCE = 0.6 },
			hard = { DURATION_MS = 9000, CHANCE = 0.35 },
		},
		DEFAULT_DIFFICULTY = 'medium',
	},

	-- Wwise events the player who turned a door hears, through
	-- `Open77.sfx.play`. '' plays nothing. A door may name its own.
	SOUNDS = { LOCK = '', UNLOCK = '' },

	-- The doors the panel may not edit. See the header for every field; X/Y/Z is
	-- the door's position (the panel captures it), BUCKET its routing bucket.
	-- Nothing ships here: a door is captured in game, and a coordinate nobody
	-- surveyed is a door that matches nothing.
	--
	-- ncpd_front = {
	--     NAME = 'NCPD front desk',
	--     DOORS = { '0xFC85EAE29622BAC2' },          -- two ids for a double door
	--     X = -1234.5, Y = 456.7, Z = 12.0, BUCKET = 0,
	--     LOCKED = true,
	--     GROUPS = { { JOB = 'ncpd', GRADE = 0 } },
	--     ITEMS = { { NAME = 'door_key', BOUND = true } },
	--     AUTOLOCK = 10, LOCKPICK = true, DIFFICULTY = 'hard',
	--     MAX_DISTANCE = 2.0,
	-- },
	DOORS = {},
}
