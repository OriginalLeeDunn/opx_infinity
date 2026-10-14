--- Door locks: which world doors are managed, and who may lock or unlock them.
-- @author dop42
--
-- THE OWNER: "revoir complètement la feature des doorlock : clone le code,
-- comprends-le, fais le panel de la même logique". The model is ox_doorlock's,
-- field for field, under ox's own names: a door has a `name`, one native door or
-- two (`doors`, a double door), `coords`, a `state` (1 locked, 0 unlocked), a
-- `maxDistance`, an `autolock` delay, `auto` (an automatic door), `lockpick` and
-- its `lockpickDifficulty` sequence, the `groups` that turn it (a job or a gang
-- name to a minimum grade), the `items` that turn it (`name`, `metadata`,
-- `remove`), the `characters` that turn it, a `passcode`, `lockSound` /
-- `unlockSound`, `hideUi` and `holdOpen`. What a field means is what it means in
-- ox; where Night City cannot do the same thing docs/MANUAL.md says so ("Door locks").
--
-- A DOOR IS IDENTIFIED BY A NUMBER, as in ox: the row id of `opx77_doorlocks`,
-- given when the door is created and never reused. `/opx.doorlock.list` prints
-- every id. A native door is named by its own opaque id (`0x` and sixteen hex
-- digits) -- the staff panel's "Pick in world" reads it from the crosshair.
--
-- WHERE A DOOR LIVES. Every door is a row in `opx77_doorlocks`, and the staff
-- panel (`/opx.doorlock`) creates, edits and deletes them. `DOORS` below is ox's
-- `convert/` folder: each block is INSERTED ONCE, under its key, the first boot
-- that sees it, and from then on the row is the door -- edit it in the panel,
-- not here. Deleting a seeded door in the panel keeps a tombstone so the next
-- boot does not put it back. The doors saved by the first version of this
-- module (`opx77_doorlock`, no s) are carried over the same way on every boot,
-- once each; that table is never written to again and can be dropped by hand.
--
-- THE SERVER DECIDES. A client sends "turn door 12" and nothing else; the server
-- reads the player's own position and routing bucket from the host, the job,
-- gang and grade from the character module, the bag from the inventory module,
-- and only then moves the lock -- ox's `isAuthorised`, in ox's order:
--
--   1. staff with the right `opx.doorlock.bypass` when STAFF_BYPASS is on (ox's PlayerAceAuthorised),
--      or the ACL entry `doorlock.<id>` (ox's ace `doorlock.<name>`)
--   2. a listed character                 -- opens without the code
--   3. the groups, any one at its grade   -- then the code, if the door has one
--   4. else the items, any one held       -- then the code
--   5. a door with only a code opens for whoever knows it
--
-- A door with none of these opens for staff only, as in ox.
--
-- Who may WRITE a door is the ACL:
--
--   command.opx.doorlock          open the panel, list doors
--   command.opx.doorlock.save     create and edit (the panel's Save)
--   command.opx.doorlock.remove   delete
--   command.opx.doorlock.lock     lock / unlock from anywhere
--   command.opx.doorlock.key      cut a key for a door
--   opx.doorlock.bypass           turn any door without a key or a code (STAFF_BYPASS)

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
	-- names no `maxDistance` of its own (ox's form default is 2). Measured by
	-- the server from the door's coords, with SLACK added for the latency
	-- between the press and the read. A door's own reach is clamped to MAX_REACH.
	USE_RADIUS = 2.0,
	MAX_REACH = 8.0,
	SLACK = 1.0,

	-- How often the client looks for the nearest managed door (strip row, key)
	-- and, on the 'local' backend, puts streamed doors back into their state.
	SCAN_MS = 500,
	-- How far around the player streamed doors are read on the 'local' backend.
	SCAN_RADIUS = 40.0,

	-- Floor between two door requests from one player, in milliseconds (ox's
	-- client floor is 500).
	REQUEST_MS = 600,

	-- 'primary' reads the worked job (and the primary gang) only; 'any' counts
	-- every membership for the grade, which is ox's `HasGroup`.
	MEMBERSHIP = 'any',

	-- Off by default: staff are asked for a key or a code like any player. When
	-- true, a player holding the plain ACL right `opx.doorlock.bypass` (NOT a
	-- `command.` grant, so the admin role's `command.*` does not carry it) turns
	-- any door without one (ox's Config.PlayerAceAuthorised).
	STAFF_BYPASS = false,

	-- Toast the player who turned a door (ox's Config.Notify). A refusal is
	-- always said; this is the "Unlocked door" after a success.
	NOTIFY = true,

	-- The key that turns the door the player is standing at (ox's E). ID is what
	-- a rebind is stored under and never changes; DEFAULT = false declares no
	-- key, and the target eye's row is then the only way to turn a door. E is
	-- shared with the garages, the stores, the lifts and the teleports: away
	-- from a managed door the key does nothing and says nothing. It is also the
	-- key that confirms a door in the panel's "Pick in world" step.
	KEY = { ID = 'opx.doorlock.use', NAME = 'doorlock.key.use', DEFAULT = 'E' },

	-- The item `/opx.doorlock.key` cuts when a door's items name none of their
	-- own: a key is the door's FIRST item that carries `metadata`, given with
	-- `{ type = <metadata>, label = <door name> }` -- ox_inventory's metadata
	-- type, which is what an item row's `metadata` matches.
	KEY_ITEM = 'door_key',

	LOCKPICK = {
		-- The items that work as a lockpick (ox's Config.LockpickItems). One of
		-- them in the bag is needed to try, and a break takes one.
		ITEMS = { 'lockpick' },
		-- Whether a pick may also LOCK an unlocked door (ox's CanPickUnlockedDoors).
		CAN_PICK_UNLOCKED = false,
		-- The sequence a door with no `lockpickDifficulty` of its own asks for
		-- (ox's Config.LockDifficulty). Each step is a name below or a custom
		-- `{ areaSize = <degrees>, speedMultiplier = <n> }`, as ox's skill check.
		DEFAULT = { 'easy', 'easy', 'medium' },
		-- What a named step is. ox's skill check is a ring the client stops in a
		-- zone; a client deciding its own success is a client that always
		-- succeeds, so here each step is a `progress` bar the SERVER times and a
		-- roll the SERVER makes at CHANCE. All steps must pass. A custom step is
		-- read the same way: CHANCE = areaSize / 60 / speedMultiplier (clamped
		-- 0.05..0.95), DURATION_MS = 2500 / speedMultiplier.
		DIFFICULTY = {
			easy = { DURATION_MS = 2000, CHANCE = 0.85 },
			medium = { DURATION_MS = 2500, CHANCE = 0.6 },
			hard = { DURATION_MS = 3000, CHANCE = 0.4 },
		},
		-- Chance the pick breaks, 0..1: ox's 1 in 100 on a success and 1 in 5 on
		-- a failure.
		BREAK_CHANCE = { SUCCESS = 0.01, FAIL = 0.2 },
	},

	-- The sounds the panel offers for `lockSound` / `unlockSound` (ox lists the
	-- files of its sound folder). Each is a Wwise event played through
	-- `Open77.sfx.play` for every player within 20 m when the door turns; ''
	-- in DEFAULT plays nothing for a door that names none.
	SOUNDS = {
		LIST = {},
		DEFAULT = { LOCK = '', UNLOCK = '' },
	},

	-- Doors inserted once into the table, ox's `convert/` files. Each field is
	-- ox's, upper-cased like every config file here:
	--
	-- ncpd_front = {
	--     NAME = 'NCPD front desk',
	--     DOORS = { '0xFC85EAE29622BAC2' },          -- two ids for a double door
	--     COORDS = { x = -1234.5, y = 456.7, z = 12.0 }, BUCKET = 0,
	--     STATE = 1,                                 -- 1 locked, 0 unlocked
	--     GROUPS = { ncpd = 0 },                     -- name -> minimum grade
	--     ITEMS = { { NAME = 'door_key', METADATA = 'ncpd_front' } },
	--     CHARACTERS = { 'ABC12345' },
	--     PASSCODE = '1234', AUTOLOCK = 10, MAX_DISTANCE = 2.0,
	--     LOCKPICK = true, LOCKPICK_DIFFICULTY = { 'easy', 'hard' },
	--     AUTO = false, HIDE_UI = false, HOLD_OPEN = false, ON_DUTY = false,
	--     LOCK_SOUND = '', UNLOCK_SOUND = '',
	-- },
	--
	-- Nothing ships here: a door is captured in game, and a coordinate nobody
	-- surveyed is a door that matches nothing.
	DOORS = {},
}
