--- Fuel: ox_fuel, ported onto Open77's fuel bag.
-- @author dop42
--
-- A FAITHFUL PORT, AND AN HONEST ONE. What ox_fuel does is here: a tank per
-- vehicle that driving empties, an engine that stops at zero, stations with
-- pumps that fill it for money at a rate, a progress bar that can be cut short
-- and bills what went in, a petrol can bought and refilled at a pump and poured
-- anywhere, blips on the map, and a `fuel` value other resources read. What
-- changed is who decides, and what Night City has:
--
--   * Cyberpunk has NO fuel model. ox drives GTA's own (`SetFuelConsumption
--     State`, `GetVehicleFuelLevel`, the petrol tank's health); there is nothing
--     to drive here, so the server owns a number -- `fuel` on the vehicle's
--     replicated state bag, in litres, the platform's own field and unit
--     (`open77_fuel`) -- and burns it itself.
--   * THE SERVER BURNS IT (`server/tanks.lua`), from the speed the host
--     replicates and the distance the car really moved. ox's client measured
--     its own tank and told the server; a client that said "full" was full.
--   * A REFUEL IS A SERVER SESSION (`server/main.lua`). ox's client counted
--     the litres and the price and sent both in one event the server paid out
--     on. Here the client asks; the server times the bar, moves the gauge,
--     watches the car and the player, and bills what its own clock poured.
--   * ox's pumps are prop MODELS. A Night City pump is part of the map with no
--     entity to aim at, so a pump is a surveyed POSITION, and the eye's row is
--     a sphere around it.
--
-- Every module it talks to is optional. Without `character` nobody can pay and
-- no pump sells; without `inventory` there is no can; without `progress` there
-- is no bar and therefore no refuel (the bar is the session's clock on screen
-- and the cancel key); without `target`, `prompts` or `menu` one door is gone
-- and the rest works. The burn needs nothing but the host.

local M = OPX.Modules.Declare{
	id = 'fuel',
	side = 'both',
	fatal = false,
	optional = { 'character', 'inventory', 'progress', 'target', 'prompts', 'menu', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ method }`: fill the vehicle beside the pump the player stands at.
	REFUEL = OPX.Event(NET, 'fuel', 'refuel'),
	-- `{ method, refill }`: buy a can, or refill the emptiest one in the bag.
	CAN_BUY = OPX.Event(NET, 'fuel', 'canBuy'),
	-- `{ vehicleId }`: pour a can into a vehicle (the eye's row). Using the
	-- item from the bag reaches the same session with no vehicle named.
	CAN_POUR = OPX.Event(NET, 'fuel', 'canPour'),

	-- Server to client: the answer to every request, `{ ok, code, ... }`.
	ANSWER = OPX.Event(NET, 'fuel', 'answer'),

	-- The public server bus: a tank moved for any reason but driving.
	-- `(source|nil, { vehicleId, vehicleKey, litres, previous, percent,
	-- capacity, reason })`, `reason` one of `refuel`, `can`, `staff`, `empty`,
	-- `ext:<resource>`. Driving is not announced: it moves every tank every
	-- second, and the bag already replicates it to whoever watches.
	ON_CHANGED = OPX.Event(LOCAL, 'fuel', 'changed'),
}

--- The bag fields. `fuel` is the PLATFORM's -- `open77_fuel` burns and reads it,
--- in litres -- and must never be renamed; `fuelCapacity` is this module's own
--- addition, so a gauge can draw a percentage without knowing the config.
M.KEY = 'fuel'
M.CAPACITY_KEY = 'fuelCapacity'

--- The platform's sample resource, which this module stands down for.
M.OPEN77_FUEL = 'open77_fuel'

--- The ACL entries, spelt once. A command's host gate is `command.<name>`.
M.Command = {
	SET = 'opx.fuel.set',
	CAPTURE = 'opx.fuel.capture',
	STATIONS = 'opx.fuel.stations',
}

--- The staff module's right to reach any live vehicle by a typed id.
M.ANYWHERE = 'opx.admin.vehicle.anywhere'
