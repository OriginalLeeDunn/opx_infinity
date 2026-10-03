--- Door locks: world doors locked and unlocked by job, gang, grade, key or code.
-- @author dop42
--
-- ox_doorlock's model on Open77's doors. What a door IS -- a name, one or two
-- native doors, a default state, groups with a minimum grade, key items,
-- characters, a passcode, an autolock, a lockpick difficulty, a reach and
-- whether its prompt is drawn -- is ox's, field for field. What a door DOES is
-- the platform's: the native door keeps its own animation, sound and collision,
-- and this module only ever moves its lock. See `config/doorlock.lua` for the
-- operator's half.
--
-- THE SERVER IS THE AUTHORITY, and the shape of the module follows from it. A
-- client sends a door KEY and the state it wants; the server reads the
-- position, the bucket, the character and the bag itself, and only then turns
-- the lock through a backend (`server/backend.lua`):
--
--   networked  the platform's `open77_doors`: the door is registered to this
--              resource and its lock is the platform's own server state, which
--              refuses a locked door to everybody.
--   local      no platform service: the server broadcasts the state and every
--              client in the bucket applies it to its streamed doors, refusing
--              vanilla interaction on a locked one.
--
-- STAFF WRITE THROUGH THE ACL. The panel (`client/staff.lua`) draws on the menu
-- and form contracts; every write it makes is either a restricted command or a
-- net event the server gates on the same `command.opx.doorlock.*` entry, and
-- each one is audited.
--
-- Every other module is optional: without `character` only staff and key
-- items open a gated door (a group check closes on every doubt), without
-- `inventory` no key or pick works, without `target`, `prompts`, `menu`,
-- `form` or `progress` one surface is missing and the rest works.

local M = OPX.Modules.Declare{
	id = 'doorlock',
	side = 'both',
	fatal = false,
	optional = { 'character', 'inventory', 'target', 'prompts', 'menu', 'form', 'progress',
		'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` comes from the connection, never the payload,
	-- and every payload is re-checked: a key and a wanted state, nothing more.
	ASK = OPX.Event(NET, 'doorlock', 'ask'),
	TOGGLE = OPX.Event(NET, 'doorlock', 'toggle'),
	PICK = OPX.Event(NET, 'doorlock', 'pick'),
	PICKED = OPX.Event(NET, 'doorlock', 'picked'),
	-- Staff, each gated on `command.opx.doorlock[.<verb>]` by the server.
	STAFF_ASK = OPX.Event(NET, 'doorlock', 'staffAsk'),
	STAFF_SAVE = OPX.Event(NET, 'doorlock', 'staffSave'),

	-- Server to client.
	SYNC = OPX.Event(NET, 'doorlock', 'sync'),
	STATE = OPX.Event(NET, 'doorlock', 'state'),
	ANSWER = OPX.Event(NET, 'doorlock', 'answer'),
	PICK_GO = OPX.Event(NET, 'doorlock', 'pickGo'),
	STAFF_OPEN = OPX.Event(NET, 'doorlock', 'staffOpen'),
	STAFF_LIST = OPX.Event(NET, 'doorlock', 'staffList'),
	STAFF_SAVED = OPX.Event(NET, 'doorlock', 'staffSaved'),

	-- The public server bus: a door changed state. `(source, { door, locked, by })`.
	ON_CHANGED = OPX.Event(LOCAL, 'doorlock', 'changed'),
}

--- The platform's door service.
M.NETWORKED = 'open77_doors'

--- The ACL entries, spelt once. A command's host gate is `command.<name>`, and
--- the two net events a staff panel sends are gated on the same spellings.
M.Command = {
	OPEN = 'opx.doorlock',
	LIST = 'opx.doorlock.list',
	REMOVE = 'opx.doorlock.remove',
	LOCK = 'opx.doorlock.lock',
	KEY = 'opx.doorlock.key',
	SAVE = 'opx.doorlock.save',
	BYPASS = 'opx.doorlock.bypass',
}
