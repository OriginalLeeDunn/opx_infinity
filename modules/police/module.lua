--- Police: the NCPD, MaxTac, corpo security, and whoever else a config names.
-- @author dop42
--
-- ONE MODULE, SEVERAL SERVICES. `config/police.lua` says which forces exist
-- and what each may do; this module is the machinery they share. A service is
-- a config entry and never a code path: Militech security is a block of config,
-- not a file.
--
-- THE CODE KNOWS CAPABILITIES. Cuff, escort, frisk, fine, jail, impound: each
-- is one verb the server judges, gated per service by a minimum grade. A
-- service that does not list a verb does not have it, which is how corpo
-- security cuffs a trespasser and then has to hand them to the NCPD.
--
-- WHAT IT OWNS:
--   * the CALLS -- a 911, an alarm the underworld raises, an ICE trace the
--     netrunner module raises, an officer down -- on the board of every service
--     whose DISPATCH.RECEIVES lists the crime (`server/dispatch.lua`);
--   * the RECORD -- cuffs, a jail sentence and unpaid fines, in the character's
--     metadata, so a reconnect is still cuffed and still in a cell;
--   * the ACTS on a suspect, each checked before, timed by the server where it
--     takes time, and checked again when it lands.
--
-- WHAT IT DOES NOT OWN: being down (`downed` -- a wounded suspect is alive and
-- may be cuffed, searched and escorted; `SetCarried` lifts its hold for the
-- walk), a bag (`inventory`), a car (`vehicles`). All of those are soft: a
-- server without them loses the verbs that need them, and says so once.
--
-- THE CONTRACT OTHERS ALREADY CALL. `underworld` hands its alarms to
-- `police.Report{ crime, label, position?, radius, source }` and reads
-- `police.OnDutyCount()` as a plain number; `netrunner` hands its ICE trace
-- to `police.Alert{ kind, jobs, label, coords, level, runner }` and treats
-- anything but false / `{ ok = false }` as delivered. Both shapes are kept
-- exactly; see `M.Api` in the server half.

local M = OPX.Modules.Declare{
	id = 'police',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	-- Client-only modules (`target`, `menu`, `form`) cannot be hard requirements
	-- of a `both` module: see the note in `modules/hauling/module.lua`.
	optional = { 'target', 'menu', 'form', 'progress', 'inventory', 'downed', 'medical', 'vehicles',
		'vehiclekeys', 'contracts', 'underworld', 'netrunner' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	BOARD = OPX.Event(NET, 'police', 'board'),           -- list the open calls
	TAKE = OPX.Event(NET, 'police', 'take'),             -- { callId }
	DROP = OPX.Event(NET, 'police', 'drop'),             -- { callId }
	OPTIONS = OPX.Event(NET, 'police', 'options'),       -- { target } what may I do to this player
	ACT = OPX.Event(NET, 'police', 'act'),               -- { target, action }
	FINE = OPX.Event(NET, 'police', 'fine'),             -- { target, code, amount, reason }
	JAIL = OPX.Event(NET, 'police', 'jail'),             -- { target, code, minutes, reason }
	CONFISCATE = OPX.Event(NET, 'police', 'confiscate'), -- { target, slot }
	IMPOUND = OPX.Event(NET, 'police', 'impound'),       -- { vehicleId }
	DESK = OPX.Event(NET, 'police', 'desk'),             -- { station } pay my fines
	EVIDENCE = OPX.Event(NET, 'police', 'evidence'),     -- { station } open the locker

	-- Server to client.
	ALERT = OPX.Event(NET, 'police', 'alert'),           -- a call opened that this officer may take
	CLOSED = OPX.Event(NET, 'police', 'closed'),         -- { id } gone from the board
	BOARD_VIEW = OPX.Event(NET, 'police', 'boardView'),
	OPTIONS_VIEW = OPX.Event(NET, 'police', 'optionsView'),
	FRISK_VIEW = OPX.Event(NET, 'police', 'friskView'),  -- the suspect's bag
	FINE_VIEW = OPX.Event(NET, 'police', 'fineView'),    -- the fine form's choices
	JAIL_VIEW = OPX.Event(NET, 'police', 'jailView'),    -- the sentence form's choices
	DESK_VIEW = OPX.Event(NET, 'police', 'deskView'),    -- what I owe
	WAYPOINT = OPX.Event(NET, 'police', 'waypoint'),     -- { x, y, z }
	RESTRAINED = OPX.Event(NET, 'police', 'restrained'), -- { cuffed } on the suspect's own client
	ANSWER = OPX.Event(NET, 'police', 'answer'),         -- { ok, code, ... }

	-- The public server bus, `(source, payload)`. Raised by the server only.
	ON_CALL = OPX.Event(LOCAL, 'police', 'call'),        -- opened / taken / closed
	ON_CUFFED = OPX.Event(LOCAL, 'police', 'cuffed'),    -- { citizenId, cuffed, by }
	ON_FINED = OPX.Event(LOCAL, 'police', 'fined'),      -- { citizenId, code, amount, paid, owed }
	ON_JAILED = OPX.Event(LOCAL, 'police', 'jailed'),    -- { citizenId, minutes, station } / released
}

--- The verbs. A fifth would need a fifth branch on the server, so the set is
--- closed here; `scan`, `redzone_request` and `redzone_authority` are P2.
M.Capability = {
	CUFF = 'cuff', ESCORT = 'escort', FRISK = 'frisk', FINE = 'fine', JAIL = 'jail', IMPOUND = 'impound',
}

--- The actions the client may send on ACT. Each maps to the capability that
--- gates it; uncuff is the cuff verb undone.
M.Action = {
	cuff = 'cuff', uncuff = 'cuff', escort = 'escort', frisk = 'frisk', fine = 'fine', jail = 'jail',
}
