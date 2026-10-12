--- Taxi: Delamain cabs, indie cabs, the meter and the street fares.
-- @author dop42
--
-- A CAB IS A CALL, A SEAT AND A METER. Somebody types `/taxi`; the call lands
-- on the board of every on-duty driver of every company that answers it; the
-- first driver to take it gets a waypoint, the customer gets the car and an
-- ETA. When the customer sits in the driver's car the server starts the meter,
-- and from then on it is the server that measures: the driver's position,
-- sampled on the server's clock, every segment clamped to what a car can do.
-- When the customer gets out the meter stops, and the fare is billed.
--
-- THE SERVER MEASURES, NEVER THE CLIENT. The seat comes from the host's seat
-- ledger (`Open77.vehicles.getPlayerSeat`, `world.vehicles`), the distance from
-- the host's positions, the hour from the weather module's clock. A client can
-- ask for the board, take a call, ask for a street fare and stop a meter it is
-- in -- nothing it says moves a number.
--
-- WHAT IT OWNS: the board (`server/dispatch.lua`, a copy of the medical board's
-- pattern with one driver per call -- not an import of medical's internals),
-- the rides and their meter (`server/main.lua`), the fare arithmetic and the
-- validator (`shared/model.lua`, pure).
--
-- WHAT IT BORROWS, ALL SOFT: `invoices` bills the customer (the customer gets
-- an accept prompt); without it the fare is taken straight from the customer
-- with character RemoveMoney. `accounts` takes the company's share; without it
-- the driver keeps the whole fare. `weather` gives the night surge; without it
-- there is none. Each absence is said once at boot.

local M = OPX.Modules.Declare{
	id = 'taxi',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'menu' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	BOARD = OPX.Event(NET, 'taxi', 'board'),            -- list the open calls
	TAKE = OPX.Event(NET, 'taxi', 'take'),              -- { callId }
	DROP = OPX.Event(NET, 'taxi', 'drop'),              -- drop the ride I hold (not running)
	STREET = OPX.Event(NET, 'taxi', 'street'),          -- { company } take a street fare
	HAIL = OPX.Event(NET, 'taxi', 'hail'),              -- start the meter for whoever sits in my cab
	STOP = OPX.Event(NET, 'taxi', 'stop'),              -- stop the meter of the ride I am in

	-- Server to client.
	ALERT = OPX.Event(NET, 'taxi', 'alert'),            -- a call this driver may take
	CLOSED = OPX.Event(NET, 'taxi', 'closed'),          -- { id } gone from the board
	BOARD_VIEW = OPX.Event(NET, 'taxi', 'boardView'),
	WAYPOINT = OPX.Event(NET, 'taxi', 'waypoint'),      -- { x, y, z }
	METER = OPX.Event(NET, 'taxi', 'meter'),            -- { company, metres, fare, moneyType, state }
	ANSWER = OPX.Event(NET, 'taxi', 'answer'),          -- { ok, code, ... }

	-- The public server bus, `(source, payload)`. Raised by the server only.
	ON_CALL = OPX.Event(LOCAL, 'taxi', 'call'),         -- opened / taken / closed
	ON_RIDE = OPX.Event(LOCAL, 'taxi', 'ride'),         -- started / ended (with the fare)
}

--- What a ride is.
M.Kind = { CALL = 'call', HAIL = 'hail', STREET = 'street' }

--- Where a ride is in its life.
M.Phase = {
	ENROUTE = 'enroute',   -- the driver is on the way to the customer / the pickup
	RIDING = 'riding',     -- the meter runs
}
