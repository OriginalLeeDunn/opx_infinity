--- The tanks: the bag field, the burn loop, the engine cut and the stand-down.
-- @author dop42
--
-- OX'S `client/init.lua` `startDrivingVehicle`, MOVED TO THE SERVER. ox runs a
-- loop on the driver's machine that reads GTA's fuel level once a second and
-- tells the server every fifteenth time; a driver who never told it never
-- burned. This loop runs once per TICK_MS over every canonical vehicle, reads
-- what the HOST says about each one -- the engine bit, the replicated speed,
-- the position, the health -- burns it through `shared/model.lua`, and writes
-- the bag. Nothing a client sends reaches it.
--
-- THE BAG IS THE TANK. `fuel`, in litres, on `Open77.state.entity('vehicle',
-- id)`: the platform's own field (`open77_fuel`), read by every gauge, every
-- other resource and the vehicles module when it puts a car away. This file
-- reads it back every tick rather than trusting a copy, so a write from
-- anywhere else -- a staff command, an export, another resource -- is simply
-- the new level. A tick's burn is far below a thousandth of a litre at idle, so
-- the exact level is carried here between ticks and only a rounded one is
-- written: a bag write that changes nothing is a delta to every viewer for
-- nothing.
--
-- AT ZERO THE ENGINE IS CUT, with `Open77.vehicles.setEngine(id, false)` -- the
-- server-authored bit the host holds against the owner's next report for ten
-- seconds -- and cut again on every tick it is found running until somebody
-- refuels: `open77_fuel`'s behaviour, and the nearest this platform has to
-- GTA's car that will not start on an empty tank. The first empty is announced
-- once on the public bus.
--
-- STANDING DOWN. When `open77_fuel` runs and STAND_DOWN is on, that resource
-- burns and cuts; this one stops doing both, and every write goes through its
-- `set` export so its own model agrees with the bag. Asked every STAND_DOWN_MS,
-- because a resource can be started after this one.

local M = OPX.Modules.Get('fuel')
local Model = M.Model

M.Tanks = {}
local Tanks = M.Tanks

local finiteNumber = OPX.Math.Finite

-- How often the host is asked whether `open77_fuel` is running.
local STAND_DOWN_MS = 10000

-- Decimals the bag carries. A thousandth of a litre is a millilitre: below what
-- any gauge draws, above the float noise of a second's idle.
local SCALE = 1000

-- vehicle id (as text) -> { litres, written }: the exact level this file last
-- burned to and the rounded value it wrote. A bag that still holds `written`
-- was not touched by anybody else, so `litres` is the level.
local exact = {}
-- vehicle id (as text) -> { x, y, z, atMs }: where it was last tick.
local seen = {}
-- vehicle id (as text) -> true once the empty has been announced.
local announced = {}
-- vehicle id (as text) -> the capacity written to its bag.
local capacities = {}
-- vehicle id (as text) -> true while a refuel or a can holds the tank.
local held = {}
-- record -> usage, for the class table is a walk.
local usages = {}

local settings, standing, standingCheckedAt, foreignCapacity = nil, false, nil, nil
local lastTickAt = nil

--- The settings, normalised once per boot.
-- @author dop42
-- @return table
function Tanks.Settings()
	if settings == nil then settings = Model.Settings(M.Settings) end
	return settings
end

-- ── standing down ───────────────────────────────────────────────────────────

local RUNNING = { started = true, running = true, starting = true }

--- Whether `open77_fuel` is up and this module is standing down for it.
-- @author dop42
-- @return boolean
function Tanks.StandingDown()
	local now = OPX.Now()
	if standingCheckedAt ~= nil and now - standingCheckedAt < STAND_DOWN_MS then return standing end
	standingCheckedAt = now
	local was = standing
	standing = false
	if M.Settings.STAND_DOWN ~= false and type(GetResourceState) == 'function' then
		local read, state = pcall(GetResourceState, M.OPEN77_FUEL)
		standing = read and RUNNING[tostring(state)] == true
	end
	foreignCapacity = nil
	if standing then
		local read, value = pcall(function() return exports[M.OPEN77_FUEL]:capacity() end)
		foreignCapacity = read and finiteNumber(value) or nil
		if foreignCapacity ~= nil and (foreignCapacity <= 0 or foreignCapacity > 10000) then
			foreignCapacity = nil
		end
	end
	if standing ~= was then
		Open77.log.info(standing
			and ('[fuel] %s is running: it burns the tanks now, and every refuel writes through it')
				:format(M.OPEN77_FUEL)
			or ('[fuel] %s is not running: this module burns the tanks'):format(M.OPEN77_FUEL))
		-- A different capacity is a different percentage on every gauge.
		capacities = {}
	end
	return standing
end

--- Forgets the stand-down answer, so the next question asks the host again.
-- @author dop42
function Tanks.Recheck() standingCheckedAt = nil end

--- Litres in a full tank: `open77_fuel`'s while standing down for it.
-- @author dop42
-- @return number
function Tanks.Capacity()
	if Tanks.StandingDown() and foreignCapacity ~= nil then return foreignCapacity end
	return Tanks.Settings().capacity
end

-- ── one vehicle ─────────────────────────────────────────────────────────────

-- The bag of one vehicle, or nil on a host without bags.
local function bagOf(vehicleId)
	local state = Open77.state
	if type(state) ~= 'table' or type(state.entity) ~= 'function' then return nil end
	local read, bag = pcall(state.entity, 'vehicle', vehicleId)
	if not read or bag == nil then return nil end
	return bag
end

local function rounded(litres)
	return math.floor(litres * SCALE + 0.5) / SCALE
end

--- A canonical vehicle's snapshot, or nil.
-- @author dop42
-- @param vehicleId any
-- @return table|nil
function Tanks.Snapshot(vehicleId)
	local api = Open77.vehicles
	if vehicleId == nil or type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return snapshot
end

--- A snapshot's position as numbers, from `x/y/z` or `position`.
-- @author dop42
-- @param snapshot table
-- @return number|nil x, y, z
function Tanks.Position(snapshot)
	local x, y, z = finiteNumber(snapshot.x), finiteNumber(snapshot.y), finiteNumber(snapshot.z)
	if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
		x, y, z = finiteNumber(snapshot.position.x), finiteNumber(snapshot.position.y), finiteNumber(snapshot.position.z)
	end
	if x == nil or y == nil or z == nil then return nil end
	return x, y, z
end

--- Whether a snapshot's engine bit is set.
-- @author dop42
-- @param snapshot table
-- @return boolean
function Tanks.EngineOn(snapshot)
	local flags = math.tointeger(finiteNumber(snapshot.flags))
	if flags ~= nil then return flags & 1 ~= 0 end
	return snapshot.engineOn == true
end

--- How hard a vehicle drinks: ox's `classUsage`, from its record. 0 means it
--- takes no fuel at all (ox's `DoesVehicleUseFuel`).
-- @author dop42
-- @param snapshot table|nil
-- @return number
function Tanks.Usage(snapshot)
	local record = type(snapshot) == 'table' and snapshot.record or nil
	if type(record) ~= 'string' then return Tanks.Settings().defaultUsage end
	local usage = usages[record]
	if usage == nil then
		usage = Model.Usage(Tanks.Settings(), record)
		usages[record] = usage
	end
	return usage
end

--- The litres in one vehicle's tank, or nil when nobody has filled it yet.
-- @author dop42
-- @param vehicleId any
-- @return number|nil
function Tanks.Read(vehicleId)
	local bag = bagOf(vehicleId)
	if bag == nil then return nil end
	local read, value = pcall(function() return bag[M.KEY] end)
	if not read then return nil end
	value = finiteNumber(value)
	if value == nil then return nil end
	local carried = exact[tostring(vehicleId)]
	if carried ~= nil and carried.written == value then return carried.litres end
	return math.max(0, value)
end

-- Publishes one change on the public bus.
local function announce(vehicleId, litres, previous, reason, source)
	if reason == nil then return end
	local capacity = Tanks.Capacity()
	OPX.Publish(M.Event.ON_CHANGED, source, {
		vehicleId = vehicleId,
		-- The engine id as TEXT too: it carries a generation and can pass 2^53.
		vehicleKey = tostring(vehicleId),
		litres = rounded(litres),
		previous = previous ~= nil and rounded(previous) or nil,
		percent = rounded(Model.Percent(litres, capacity)),
		capacity = capacity,
		reason = reason,
	})
end

--- Writes one tank, clamped into it. With a reason the change is announced on
--- `opx:on:fuel:changed`; the burn passes none.
-- @author dop42
-- @param vehicleId any
-- @param litres number
-- @param reason string|nil
-- @param source integer|nil the player it is about, for the bus
-- @return boolean written
-- @return string|nil why not
function Tanks.Write(vehicleId, litres, reason, source)
	litres = finiteNumber(litres)
	if litres == nil then return false, 'bad_amount' end
	local capacity = Tanks.Capacity()
	litres = math.max(0, math.min(capacity, litres))
	local key = tostring(vehicleId)
	local previous = Tanks.Read(vehicleId)
	local value = rounded(litres)

	local written, why = false, nil
	if Tanks.StandingDown() then
		-- Through `open77_fuel`, so its model and the bag agree; the bag itself
		-- when the export is missing, which is the field it would write anyway.
		local read, answer = pcall(function() return exports[M.OPEN77_FUEL]:set(vehicleId, value) end)
		written = read and answer ~= nil and answer ~= false
	end
	if not written then
		local bag = bagOf(vehicleId)
		if bag == nil then return false, 'no_bag' end
		local read, ok, reason2 = pcall(bag.set, bag, M.KEY, value)
		if not read then return false, tostring(ok) end
		if ok == false then return false, tostring(reason2) end
		written = true
	end
	exact[key] = { litres = litres, written = value }
	if litres > 0 then announced[key] = nil end
	if capacities[key] ~= capacity then
		local bag = bagOf(vehicleId)
		if bag ~= nil and pcall(bag.set, bag, M.CAPACITY_KEY, capacity) then capacities[key] = capacity end
	end
	announce(vehicleId, litres, previous, reason, source)
	return written, why
end

--- Puts a tank nobody has filled at INITIAL_PERCENT, and answers its level.
-- @author dop42
-- @param vehicleId any
-- @return number|nil
function Tanks.Ensure(vehicleId)
	local litres = Tanks.Read(vehicleId)
	if litres ~= nil then return litres end
	if Tanks.StandingDown() then return nil end
	litres = Model.Litres(Tanks.Settings().initialPercent, Tanks.Capacity())
	if Tanks.Write(vehicleId, litres) then return litres end
	return nil
end

--- Holds a tank against the burn while a refuel or a can pours into it.
-- @author dop42
-- @param vehicleId any
-- @param on boolean
function Tanks.Hold(vehicleId, on)
	held[tostring(vehicleId)] = on == true or nil
end

--- Whether a tank is held by a pour.
-- @author dop42
-- @param vehicleId any
-- @return boolean
function Tanks.Held(vehicleId) return held[tostring(vehicleId)] == true end

--- Forgets a vehicle the host removed. Its bag went with it.
-- @author dop42
-- @param vehicleId any
function Tanks.Forget(vehicleId)
	local key = tostring(vehicleId)
	exact[key], seen[key], announced[key], capacities[key], held[key] = nil, nil, nil, nil, nil
end

-- ── the burn ────────────────────────────────────────────────────────────────

-- Cuts a running engine on an empty tank.
local function cut(vehicleId)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.setEngine) ~= 'function' then return false end
	local read, ok = pcall(api.setEngine, vehicleId, false)
	return read and ok == true
end

--- Burns one vehicle for one tick. Answers the litres burned.
-- @author dop42
-- @param snapshot table
-- @param dtMs number
-- @param now number
-- @return number
function Tanks.BurnOne(snapshot, dtMs, now)
	local vehicleId = snapshot.id
	if vehicleId == nil then return 0 end
	local key = tostring(vehicleId)
	local x, y, z = Tanks.Position(snapshot)
	local last = seen[key]
	seen[key] = x ~= nil and { x = x, y = y, z = z, atMs = now } or nil

	local usage = Tanks.Usage(snapshot)
	-- ox's `DoesVehicleUseFuel` false: never burned, never cut, never filled.
	if usage <= 0 then return 0 end
	if held[key] then return 0 end

	local litres = Tanks.Ensure(vehicleId)
	if litres == nil then return 0 end

	local engineOn = Tanks.EngineOn(snapshot)
	if litres <= 0 then
		if engineOn then cut(vehicleId) end
		if not announced[key] then
			announced[key] = true
			announce(vehicleId, 0, nil, 'empty', snapshot.driverPlayerId)
		end
		return 0
	end

	local moved
	if last ~= nil and x ~= nil then
		local dx, dy, dz = x - last.x, y - last.y, z - last.z
		moved = math.sqrt(dx * dx + dy * dy + dz * dz)
	end
	local burned = Model.Burn(Tanks.Settings(), {
		dtMs = dtMs, engineOn = engineOn, speed = snapshot.speed, moved = moved,
		usage = usage, health = snapshot.health,
	})
	if burned <= 0 then return 0 end
	local left = math.max(0, litres - burned)
	local value = rounded(left)
	local carried = exact[key]
	if carried ~= nil and carried.written == value then
		-- The rounded level did not move: keep the exact one and write nothing.
		carried.litres = left
	else
		Tanks.Write(vehicleId, left)
	end
	if left <= 0 then
		if engineOn then cut(vehicleId) end
		announced[key] = true
		announce(vehicleId, 0, litres, 'empty', snapshot.driverPlayerId)
	end
	return litres - left
end

--- One pass over every canonical vehicle. Each one under pcall, because one
--- raise would end the burn for the whole city, silently.
-- @author dop42
function Tanks.Tick()
	local now = OPX.Now()
	local dt = lastTickAt ~= nil and now - lastTickAt or Tanks.Settings().tickMs
	lastTickAt = now
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.all) ~= 'function' then return end
	local read, list = pcall(api.all)
	if not read or type(list) ~= 'table' then return end
	local down = Tanks.StandingDown()
	for index = 1, #list do
		local snapshot = list[index]
		if type(snapshot) == 'table' then
			local ok, failure
			if down then
				-- `open77_fuel` burns; this pass only keeps the capacity on the
				-- bag, so a gauge reads a percentage of ITS tank.
				ok, failure = pcall(function()
					local key = tostring(snapshot.id)
					if snapshot.id ~= nil and capacities[key] ~= Tanks.Capacity() then
						local bag = bagOf(snapshot.id)
						if bag ~= nil and pcall(bag.set, bag, M.CAPACITY_KEY, Tanks.Capacity()) then
							capacities[key] = Tanks.Capacity()
						end
					end
				end)
			else
				ok, failure = pcall(Tanks.BurnOne, snapshot, dt, now)
			end
			if not ok then
				Open77.log.error(('[fuel] burning %s: %s'):format(tostring(snapshot.id), tostring(failure)))
			end
		end
	end
end

--- Resets every table. Never yields.
-- @author dop42
function Tanks.Init()
	exact, seen, announced, capacities, held, usages = {}, {}, {}, {}, {}, {}
	settings, standing, standingCheckedAt, foreignCapacity, lastTickAt = nil, false, nil, nil, nil
end
