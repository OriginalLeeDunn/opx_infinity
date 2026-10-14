--- Door locks: ox_doorlock, ported to Open77's world doors.
-- @author dop42
--
-- A FAITHFUL PORT. What a door IS -- `name`, `coords`, one native door or two
-- (`doors`), `state` 1/0, `maxDistance`, `autolock`, `auto`, `lockpick` and its
-- `lockpickDifficulty` sequence, `groups` (name -> grade), `items` (`name`,
-- `metadata`, `remove`), `characters`, `passcode`, `lockSound` / `unlockSound`,
-- `hideUi`, `holdOpen` -- is ox's, under ox's own names, and a door is filed
-- under ox's integer id. What a player may do at it is ox's `isAuthorised`, in
-- ox's order (`shared/access.lua`). What staff do is ox's panel: a list of every
-- door with search and pages, and a settings form with ox's tabs -- a Vue view of
-- its own (`ui/src/modules/doorlock`), driven by `client/panel.lua`.
--
-- WHAT A DOOR DOES IS THE PLATFORM'S. The native door keeps its own animation,
-- sound and collision; this module moves its lock (and, for `holdOpen`, keeps it
-- open while unlocked) through one of two backends (`server/backend.lua`):
--
--   networked  the platform's `open77_doors`: the door is registered to this
--              resource and its lock is the platform's own server state, which
--              refuses a locked door to everybody.
--   local      no platform service: the server broadcasts the state and every
--              client in the bucket applies it to its streamed doors, refusing
--              vanilla interaction on a locked one.
--
-- THE SERVER IS THE AUTHORITY. A client sends a door id and the state it wants;
-- the server reads the position, the bucket, the character and the bag itself.
-- Every staff write is a net event or a restricted command gated on its own
-- `command.opx.doorlock.*` entry, floored per player, and audited.
--
-- Every other module is optional: without `character` only staff, key items
-- and codes open a gated door (a group check closes on every doubt), without
-- `inventory` no key or pick works, without `target`, `prompts`, `form` or
-- `progress` one surface is missing and the rest works.

local M = OPX.Modules.Declare{
	id = 'doorlock',
	side = 'both',
	fatal = false,
	optional = { 'character', 'inventory', 'target', 'prompts', 'form', 'progress', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` comes from the connection, never the payload,
	-- and every payload is re-checked: an id and a wanted state, nothing more.
	ASK = OPX.Event(NET, 'doorlock', 'ask'),
	-- ox's `ox_doorlock:setState`: `{ id, state, code? }`.
	SET_STATE = OPX.Event(NET, 'doorlock', 'setState'),
	PICK = OPX.Event(NET, 'doorlock', 'pick'),
	PICKED = OPX.Event(NET, 'doorlock', 'picked'),
	-- Staff, each gated on its own `command.opx.doorlock[.<verb>]` by the server.
	STAFF_ASK = OPX.Event(NET, 'doorlock', 'staffAsk'),
	-- ox's `ox_doorlock:editDoorlock`, split by verb so each has its own grant.
	STAFF_SAVE = OPX.Event(NET, 'doorlock', 'staffSave'),
	STAFF_REMOVE = OPX.Event(NET, 'doorlock', 'staffRemove'),
	STAFF_STATE = OPX.Event(NET, 'doorlock', 'staffState'),
	STAFF_KEY = OPX.Event(NET, 'doorlock', 'staffKey'),

	-- Server to client.
	SYNC = OPX.Event(NET, 'doorlock', 'sync'),
	STATE = OPX.Event(NET, 'doorlock', 'state'),
	ANSWER = OPX.Event(NET, 'doorlock', 'answer'),
	PICK_GO = OPX.Event(NET, 'doorlock', 'pickGo'),
	STAFF_OPEN = OPX.Event(NET, 'doorlock', 'staffOpen'),
	STAFF_LIST = OPX.Event(NET, 'doorlock', 'staffList'),
	STAFF_DONE = OPX.Event(NET, 'doorlock', 'staffDone'),

	-- The public server bus, ox's `ox_doorlock:stateChanged`:
	-- `(source, { id, door = id, name, state, locked, by })`.
	ON_CHANGED = OPX.Event(LOCAL, 'doorlock', 'changed'),
}

--- The platform's door service.
M.NETWORKED = 'open77_doors'

--- The ACL entries, spelt once. A command's host gate is `command.<name>`, and
--- the staff net events are gated on the same spellings.
M.Command = {
	OPEN = 'opx.doorlock',
	LIST = 'opx.doorlock.list',
	SAVE = 'opx.doorlock.save',
	REMOVE = 'opx.doorlock.remove',
	LOCK = 'opx.doorlock.lock',
	KEY = 'opx.doorlock.key',
	BYPASS = 'opx.doorlock.bypass',
}

--- The staff module's teleport, which the panel borrows rather than copies: it
--- is ACL-checked and audited there, and a body move is not this module's job.
M.TELEPORT = 'opx.admin.player.tp'

--- The veto hook a module of this resource can hang on a door decision (ox's
--- `registerHook('doorAuthorization')`). `{ source, id, name, lockpick,
--- authorised }`; an explicit false refuses.
M.HOOK = 'doorlock:authorise'
