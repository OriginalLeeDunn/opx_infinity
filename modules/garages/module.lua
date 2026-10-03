--- Garages and AV pads: a glowing marker you stand on to bring your own vehicle out.
-- @author XEROX710
--
-- The client draws one marker per configured spot in the player's own routing
-- bucket, posts a prompt row while the player stands on one, and sends a
-- request when the key is pressed. The server re-derives everything it can
-- prove -- the spot exists, the player is within USE_RADIUS of the DECLARED
-- position, the bucket agrees, the character is loaded and the vehicle is
-- theirs -- and only then asks the `vehicles` contract to create it, AT the
-- spot and facing the spot's HEADING, never beside the player.
--
-- A GARAGE IS A KEY AND A GARAGE IS IN SEVERAL PLACES. Each of its locations has
-- a MENU point that opens the list of everything filed under that key, ONE ENTRY
-- point that takes a vehicle in, and an ordered list of EXITS a vehicle comes
-- out at -- the first one with nothing parked on it. When every exit is taken
-- the request is REFUSED and the player told so, rather than queued or dropped
-- on top of the car already there.
--
-- THE ONE KEY DOES TWO THINGS, AND ONLY THE SERVER DECIDES WHICH. At a menu
-- point the key opens the list. At an entry point, sitting in one of the
-- character's own vehicles, it puts that vehicle AWAY under the garage's key --
-- so it comes out at ANY location of that garage afterwards, which is the whole
-- of the rework. The seated question is answered by the host's own seat
-- assignment and the plate the `vehicles` contract holds, never by the client;
-- the client only chooses which of the two texts the row names.
--
-- A VEHICLE OF THEIRS THAT IS ALREADY OUT IS MOVED, NOT IGNORED. It used to be
-- answered with the id it already had -- `Ok`, "brought out", and an empty spot
-- in front of the player, because the car was on the other side of the map. The
-- `vehicles` contract recalls it to the named place instead, and refuses when
-- somebody is sitting in it.
--
-- What comes out is what the character already owns: this module spawns no new
-- vehicle and creates no row. A spot with nothing eligible answers a refusal
-- that says so, rather than handing out a car the player does not have.
--
-- THE ONE EXCEPTION IS THE JOB'S OWN FLEET, and it is still no row. Every
-- holder of a job in `config/garages.lua` JOB_VEHICLES finds that job's
-- vehicles at the top of every garage list of the right kind -- at their grade,
-- on duty -- with nothing granted first. They are SIGNED OUT through the
-- `vehicles` contract, never owned: no plate, nothing to sell or hand over,
-- back to the pool at a door, and back on their own when the job, the grade or
-- the shift is gone.
--
-- The marker is the engine's own (`world.markers`), so there is no geometry of
-- our own to keep in step with a screen: the four styles and two shapes are the
-- ones the host accepts, and `config/garages.lua` picks one per kind.
--
-- `character` is required on both halves: on the server it is the only proof
-- of ownership, and on the client it is where the player's own position and
-- facing are read from.
--
-- `vehicles` is OPTIONAL and not required, because it is a server-only module:
-- requiring it took the whole client half down with it -- no marker, no row, no
-- key -- the moment the server half was the only half that existed. The server
-- asks for the contract in `Start` and refuses every request without it, which
-- is the same answer with a line that says why.
--
-- The strip is optional too: without `prompts` the markers still draw and the
-- command still works, and only the key row is missing.

local M = OPX.Modules.Declare{
	id = 'garages',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	-- `menu` is optional and not required: without it the list cannot be drawn
	-- and `/opx.garages.bring` still brings a vehicle out, which is a garage
	-- with one fewer door rather than a broken one.
	-- `vehiclekeys` hands the owner a key on the way out when they hold none.
	optional = { 'vehicles', 'prompts', 'downed', 'menu', 'vehiclekeys' },
}

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` always comes from the authenticated connection.
	ASK = OPX.Event(NET, 'garages', 'ask'),
	REQUEST = OPX.Event(NET, 'garages', 'request'),
	-- The list behind a menu point: every vehicle filed under THAT garage's key,
	-- wherever it was stored. Asked for when the list is opened and never kept on
	-- the client between two opens -- a roster cached across a purchase, another
	-- location's put-away or a sale is a roster that lies.
	LIST = OPX.Event(NET, 'garages', 'list'),
	-- The answer to SETTLE: this client's own copy of the named hull has been
	-- attached long enough to be flown. Only ever moves a seat the server already
	-- owes this connection, for that hull (see `seatPilotSettled`).
	SETTLED = OPX.Event(NET, 'garages', 'settled'),

	-- Server to client: the points this player may see, the list behind one of
	-- them, and one verdict.
	SYNC = OPX.Event(NET, 'garages', 'sync'),
	VEHICLES = OPX.Event(NET, 'garages', 'vehicles'),
	ANSWER = OPX.Event(NET, 'garages', 'answer'),
	-- A pad is about to seat this player in the hull it just created: answer
	-- SETTLED once this client's copy of it has been attached for `attachedMs`.
	SETTLE = OPX.Event(NET, 'garages', 'settle'),

	-- The client's own bus. `decision` carries every verdict, local refusals
	-- included. Public: a bare AddEventHandler reaches it.
	ON_DECISION = OPX.Event(LOCAL, 'garages', 'decision'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`: without it a client waiting on one of several requests
-- cannot tell which `error.tooFast` is its own.
--
-- `CAPTURE` is still not an operation: the AV pad capture (`/opx.avgarages.add`)
-- answers with `OPX.CommandResult` and raises no request a refusal would name,
-- and an operation name nothing raises is a name the next reader wires a
-- refusal up to.
M.Operation = { BRING = 'garageBring', LIST = 'garageList' }

--- The two kinds a GARAGE may declare. A garage holds ground vehicles, a pad
--- holds AV records. It is a fact about the GARAGE and never about one of its
--- points: a garage that took cars in at one location and AVs at another would
--- be a garage whose own list means two things.
M.KIND = { GARAGE = 'garage', AVPAD = 'avpad' }

--- What a drawn point of a garage IS, which is not what the garage holds.
--
--   MENU   opens the list of everything filed under this garage's key, whichever
--          of its locations it was stored at.
--   ENTRY  takes in the vehicle the player is sitting in. One per location.
--
-- An EXIT is deliberately NOT in this set: nothing is drawn at one and no key is
-- pressed on one. It is a place the server creates a vehicle at, and it belongs
-- to the location rather than to the set of things a player walks up to.
M.ROLE = { MENU = 'menu', ENTRY = 'entry' }
