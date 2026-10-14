--- Owned vehicles: registering one, bringing it out, putting it away, and
--- keeping its condition across a restart.
-- @author dop42
--
-- The plate is the identity, never the runtime id: a runtime id belongs to one
-- spawn and is recycled, a plate is the row. Ownership is proved against the
-- character the connection has loaded, and never against what the client claims.
--
-- `live` -- plate to runtime id and owner -- is what is out NOW, and it is
-- rebuilt empty on every reload: the host removes the vehicles this resource
-- created when it stops, so a carried table would name vehicles that are gone.
--
-- Only vehicles this module spawned have a row. One created by anything else
-- answers no plate at all, and nothing durable may be attached to it.
--
-- JOB VEHICLES ARE THE ONE KIND THIS MODULE CREATES WITHOUT A ROW. A job's
-- fleet (`config/garages.lua` JOB_VEHICLES) is signed out to a member, never
-- owned: it is held in memory by holder and slot beside `live`, has no plate,
-- and so answers no plate either -- which is what keeps it from ever being
-- stored, sold, handed over or counted as a car of theirs.

local M = OPX.Modules.Declare{
	id = 'vehicles',
	side = 'server',
	fatal = false,
	-- Every row is keyed on the citizen id, and only the character module knows
	-- which character a connection has loaded.
	requires = { 'character' },
}

M.Event = {
	-- Nothing from the client: a car comes out and goes back through `garages`
	-- and staff, which call the contract. See `M.Start` in server/main.lua.

	-- The public server bus, for OTHER resources: a vehicle came out of storage
	-- or went back into it. `(source|nil, { citizenId, plate, ... })`; see
	-- `core/server/publish.lua` and docs/MANUAL.md "For creators".
	ON_SPAWNED = OPX.Event(OPX.Channel.LOCAL, 'vehicles', 'spawned'),
	ON_STORED = OPX.Event(OPX.Channel.LOCAL, 'vehicles', 'stored'),
	-- A vehicle row made for a character (bought, given, a reward), and one moved
	-- to stored or impounded by `SetState` -- the impound door.
	ON_REGISTERED = OPX.Event(OPX.Channel.LOCAL, 'vehicles', 'registered'),
	ON_STATE = OPX.Event(OPX.Channel.LOCAL, 'vehicles', 'state'),
}

