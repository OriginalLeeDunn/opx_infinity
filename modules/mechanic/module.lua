--- Mechanics: repairs, roadside kits, the call board, the tow and the impound lot.
-- @author dop42
--
-- A GARAGE IS CONFIG, NOT CODE. `config/mechanic.lua` lists the shops -- an
-- Autofixer in Arroyo, a Badlands yard, a Kabuki body shop -- each with its
-- bays, its back-room stash and its impound lot. A fourth shop is a block of
-- config, never a file.
--
-- WHAT IT OWNS:
--   * the REPAIR -- a mechanic on duty fixes a vehicle standing in a shop's bay,
--     priced by what is broken, paid in parts from the shop's stash or the
--     mechanic's bag, billed to the customer (`invoices` when it runs);
--   * the KIT -- a roadside repair anybody can carry, at reduced effect;
--   * the CALLS -- `/mechanic` and `/tow` put a call on the board of every
--     mechanic on duty (`server/dispatch.lua`, the medical board's shape);
--   * the TOW -- a mechanic or the police impound a registered vehicle;
--   * the LOT -- the owner pays the release fee to get it back.
--
-- WHAT IT DOES NOT OWN: the vehicle. `vehicles` owns the row and is the only
-- door to `impounded` (`SetState`); this module never writes a vehicle row. The
-- engine repair natives (`Open77.vehicles.repair`, `setHealth`) answer only for
-- a vehicle THIS RESOURCE created -- the platform's rule, "only the server
-- resource owning the vehicle can repair it" -- which every owned car is,
-- because `vehicles` lives in this same resource. A car another resource
-- spawned is refused with `not_ours` instead of being half fixed.
--
-- Every other module is SOFT. Without `vehicles` there is no tow and no lot;
-- without `inventory` no parts and no kit; without `progress` no bar and
-- therefore no repair; without `invoices` the customer is charged directly;
-- without `accounts` the shop's share goes to the mechanic.

local M = OPX.Modules.Declare{
	id = 'mechanic',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	-- `target` and `menu` are client-only, so a hard requirement would mark the
	-- server half unavailable; see the same note in `modules/medical/module.lua`.
	optional = { 'vehicles', 'inventory', 'progress', 'target', 'menu' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	REPAIR = OPX.Event(NET, 'mechanic', 'repair'),       -- { vehicleId, mode = 'shop'|'kit' }
	IMPOUND = OPX.Event(NET, 'mechanic', 'impound'),     -- { vehicleId }
	STASH = OPX.Event(NET, 'mechanic', 'stash'),         -- { shop }
	LOT = OPX.Event(NET, 'mechanic', 'lot'),             -- { shop } what do I have impounded
	RELEASE = OPX.Event(NET, 'mechanic', 'release'),     -- { shop, plate }
	BOARD = OPX.Event(NET, 'mechanic', 'board'),         -- list the open calls
	TAKE = OPX.Event(NET, 'mechanic', 'take'),           -- { callId }
	DROP = OPX.Event(NET, 'mechanic', 'drop'),           -- { callId }
	CLOSE = OPX.Event(NET, 'mechanic', 'close'),         -- { callId } the job is done

	-- Server to client.
	ALERT = OPX.Event(NET, 'mechanic', 'alert'),         -- a call opened that this mechanic may take
	CLOSED = OPX.Event(NET, 'mechanic', 'closed'),       -- { id, why } gone from the board
	BOARD_VIEW = OPX.Event(NET, 'mechanic', 'boardView'),
	LOT_VIEW = OPX.Event(NET, 'mechanic', 'lotView'),
	WAYPOINT = OPX.Event(NET, 'mechanic', 'waypoint'),   -- { x, y, z }
	ANSWER = OPX.Event(NET, 'mechanic', 'answer'),       -- { ok, code, ... }

	-- The public server bus, `(source, payload)`. Raised by the server only.
	ON_CALL = OPX.Event(LOCAL, 'mechanic', 'call'),          -- opened / taken / closed
	ON_REPAIRED = OPX.Event(LOCAL, 'mechanic', 'repaired'),  -- a repair landed (and was billed)
	ON_IMPOUNDED = OPX.Event(LOCAL, 'mechanic', 'impounded'),
	ON_RELEASED = OPX.Event(LOCAL, 'mechanic', 'released'),
}

--- The two kinds of repair. A third would need a third branch on the server.
M.Mode = { SHOP = 'shop', KIT = 'kit' }

--- What a caller asked for.
M.CallKind = { REPAIR = 'repair', TOW = 'tow' }

--- The owner name every progress bar, usable and runtime item is registered under.
M.OWNER = 'mechanic'

--- `vehicles`' row state for an impounded car (`modules/vehicles/server/storage.lua`).
M.IMPOUNDED = 2
