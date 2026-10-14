--- Vehicle keys, the client half: one row on the eye over a vehicle.
-- @author dop42
--
-- The row only ASKS. It names the vehicle the eye landed on and nothing else;
-- the server decides whether this player holds that vehicle's key and stands
-- close enough to turn it. The checkbox reads the lock the host replicates
-- (`Open77.vehicles.isLocked`, `vehicles.read`), never a guess.

local M = OPX.Modules.Get('vehiclekeys')

-- The name the rows are registered under: the module id, which the target
-- registry reads as an owner that is always live.
local OWNER = 'vehiclekeys'

local target, inventory

--- The vehicle the eye landed on, as the decimal string the wire carries.
-- A DECIMAL STRING because a vehicle id carries a generation and can pass 2^53,
-- where a JSON number stops being exact -- `modules/inventory/client/world.lua`
-- sends a trunk's id the same way.
local function vehicleOf(context)
	local hit = type(context) == 'table' and context.target or nil
	local id = type(hit) == 'table' and math.tointeger(hit.vehicleId) or nil
	if id == nil or id < 1 then return nil end
	return id
end

--- Whether the bag this client was last sent holds any key at all.
-- A hint that keeps a row off every car for a player with no keys; which key
-- opens which car is the server's question, because the vehicle's plate is not
-- something this client is told.
local function holdsAKey()
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return false end
	local read, count = pcall(inventory.GetItemCount, M.ITEM)
	return read and (tonumber(count) or 0) > 0
end

--- The replicated lock of the targeted vehicle, or nil when it cannot be read.
local function lockedOf(context)
	local id = vehicleOf(context)
	local host = Open77.vehicles
	if id == nil or type(host) ~= 'table' or type(host.isLocked) ~= 'function' then return nil end
	local read, value = pcall(host.isLocked, id)
	if not read or type(value) ~= 'boolean' then return nil end
	return value
end

--- Asks the server to turn the key.
local function onToggle(context)
	local id = vehicleOf(context)
	if id == nil then return false end
	TriggerServerEvent(M.Event.TOGGLE, { vehicleId = ('%d'):format(id) })
	return true
end

--- Registers the row, once.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	inventory = OPX.Api.Get('inventory')
	if target == nil then
		OPX.Note('vehiclekeys', 'no target contract: no lock row on vehicles; a key still ' ..
			'works when used from the bag')
		return
	end
	-- ONE ROW THAT SAYS WHICH WAY. `Lock / unlock` with a tick box made the
	-- player decode a check mark; the eye now shows `Lock vehicle` or `Unlock
	-- vehicle` from what the host reads, and keeps the two-way row only for a
	-- vehicle whose lock this client cannot read. All three send the same turn
	-- of the key, which the server decides.
	-- Beside the trunk (22): a key is what decides whether the trunk opens.
	local function usable(context) return vehicleOf(context) ~= nil and holdsAKey() end
	local registered = target.RegisterVehicles(OWNER, {
		{
			id = 'vehiclekeys.lock',
			label = locale('vehiclekeys.row.lock'),
			icon = 'key',
			distance = M.REACH,
			canInteract = function(context) return usable(context) and lockedOf(context) == false end,
			onSelect = onToggle,
			order = 21,
		},
		{
			id = 'vehiclekeys.unlock',
			label = locale('vehiclekeys.row.unlock'),
			icon = 'key',
			distance = M.REACH,
			canInteract = function(context) return usable(context) and lockedOf(context) == true end,
			onSelect = onToggle,
			order = 21,
		},
		{
			id = 'vehiclekeys.toggle',
			label = locale('vehiclekeys.row.toggle'),
			icon = 'key',
			distance = M.REACH,
			canInteract = function(context) return usable(context) and lockedOf(context) == nil end,
			onSelect = onToggle,
			order = 21,
		},
	})
	if not registered.ok then
		OPX.Note('vehiclekeys', ('the lock row was refused: %s'):format(tostring(registered.error)))
	end
end
