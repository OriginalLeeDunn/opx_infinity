--- The fuel model and the station list: pure, and the same on both halves.
-- @author dop42
--
-- `open77_fuel` keeps its numbers in one pure file with a suite of its own "so
-- the numbers a server owner tunes are the numbers that are tested", and this
-- is that file for this port. No clock, no host call, no module namespace:
-- every function takes what it needs and answers a value, so every branch of
-- the burn and every refusal of a station is reachable from a test with no
-- world at all.
--
-- THE BURN, IN ONE SENTENCE: while the engine runs, a tick costs the litres of
-- the distance covered (ox's `globalFuelConsumptionRate` x `open77_fuel`'s
-- litres per hundred kilometres x the class's usage x the speed curve), or the
-- idle rate when the car stands still, plus a leak below a health threshold.
-- An engine that is off burns nothing, which is ox's `SetFuelConsumptionRate
-- Multiplier(0.0)` on a stopped engine.
--
-- THE DISTANCE IS THE LARGER OF TWO MEASURES, and that is the anti-cheat. The
-- speed is what the physics owner reports and the server validates; the moved
-- distance is the server's own difference between two positions. A client
-- that reports a standing car while it drives is billed for the road it
-- covered; a jump longer than MAX_SPEED_KPH allows is a teleport -- a garage
-- recall, a staff move -- and is not billed at all, only the reported speed is.

local M = OPX.Modules.Get('fuel')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite

-- Kilometres per hour in a metre per second.
local KPH = 3.6

-- Bounds every number below is clamped to, so an operator's typo is a slower
-- or a faster tank and never a NaN in a bag every client reads.
local MAX_CAPACITY = 1000.0
local MAX_RATE = 1000.0

--- A finite number clamped to a range, or the fallback.
local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil or number < low or number > high then return fallback end
	return number
end
Model.Bounded = bounded

--- The settings this file reads, every one of them bounded.
-- @author dop42
-- @param raw table|nil the module's config block
-- @return table
function Model.Settings(raw)
	raw = type(raw) == 'table' and raw or {}
	local consumption = type(raw.CONSUMPTION) == 'table' and raw.CONSUMPTION or {}
	local leak = type(consumption.LEAK) == 'table' and consumption.LEAK or {}
	local refill = type(raw.REFILL) == 'table' and raw.REFILL or {}
	local can = type(raw.CAN) == 'table' and raw.CAN or {}
	return {
		capacity = bounded(raw.CAPACITY, 1.0, MAX_CAPACITY, 60.0),
		initialPercent = bounded(raw.INITIAL_PERCENT, 0, 100, 100),
		tickMs = math.floor(bounded(consumption.TICK_MS, 100, 60000, 1000)),
		per100km = bounded(consumption.LITRES_PER_100KM, 0, MAX_RATE, 9.0),
		idlePerMinute = bounded(consumption.IDLE_LITRES_PER_MINUTE, 0, MAX_RATE, 0.05),
		multiplier = bounded(consumption.MULTIPLIER, 0, 1000, 1.0),
		maxSpeedKph = bounded(consumption.MAX_SPEED_KPH, 10, 2000, 350),
		curve = Model.Curve(consumption.SPEED_CURVE),
		classes = Model.Classes(consumption.CLASSES),
		defaultUsage = bounded(consumption.DEFAULT_USAGE, 0, 100, 1.0),
		leakBelow = bounded(leak.BELOW_HEALTH, 0, 1, 0),
		leakPerMinute = bounded(leak.LITRES_PER_MINUTE, 0, MAX_RATE, 0),
		price = bounded(raw.PRICE_PER_LITRE, 0, 1000000, 4),
		refillRate = bounded(refill.LITRES_PER_SECOND, 0.01, MAX_RATE, 1.2),
		refillTickMs = math.floor(bounded(refill.TICK_MS, 100, 5000, 500)),
		useRadius = bounded(raw.USE_RADIUS, 0.5, 20, 2.5),
		vehicleReach = bounded(raw.VEHICLE_REACH, 0.5, 30, 4.0),
		moveTolerance = bounded(raw.MOVE_TOLERANCE, 0.1, 20, 1.0),
		stopSpeed = bounded(raw.STOP_SPEED, 0.05, 20, 0.5),
		maxPumps = math.floor(bounded(raw.MAX_PUMPS, 1, 32, 16)),
		staffReach = bounded(raw.STAFF_REACH, 1, 10000, 100),
		can = {
			enabled = can.ENABLED ~= false,
			item = type(can.ITEM) == 'string' and can.ITEM ~= '' and can.ITEM or 'petrolcan',
			capacity = bounded(can.CAPACITY, 0.1, MAX_CAPACITY, 10.0),
			durationMs = math.floor(bounded(can.DURATION_MS, 250, 60000, 5000)),
			price = math.floor(bounded(can.PRICE, 0, 1000000, 100)),
			refillPrice = math.floor(bounded(can.REFILL_PRICE, 0, 1000000, 60)),
			rate = bounded(can.LITRES_PER_SECOND, 0.01, MAX_RATE, 0.8),
			reach = bounded(can.REACH, 0.5, 30, 3.0),
		},
	}
end

-- ── the curve and the classes ───────────────────────────────────────────────

--- The speed curve as sorted { kph, factor } pairs; flat 1.0 when unusable.
-- @author dop42
-- @param raw any
-- @return table[]
function Model.Curve(raw)
	local points = {}
	if type(raw) == 'table' then
		for index = 1, math.min(#raw, 32) do
			local pair = raw[index]
			local kph = type(pair) == 'table' and bounded(pair[1], 0, 2000, nil) or nil
			local factor = type(pair) == 'table' and bounded(pair[2], 0, 100, nil) or nil
			if kph ~= nil and factor ~= nil then points[#points + 1] = { kph, factor } end
		end
	end
	table.sort(points, function(left, right) return left[1] < right[1] end)
	if #points == 0 then points[1] = { 0, 1.0 } end
	return points
end

--- The curve's factor at a speed: straight lines between the points, flat past
--- both ends.
-- @author dop42
-- @param curve table[] what `Curve` answered
-- @param kph number
-- @return number
function Model.Factor(curve, kph)
	local first = curve[1]
	if kph <= first[1] then return first[2] end
	for index = 2, #curve do
		local low, high = curve[index - 1], curve[index]
		if kph <= high[1] then
			local span = high[1] - low[1]
			if span <= 0 then return high[2] end
			return low[2] + (high[2] - low[2]) * (kph - low[1]) / span
		end
	end
	return curve[#curve][2]
end

--- The class table as { match, usage } rows, lower-cased, in the order written.
-- @author dop42
-- @param raw any
-- @return table[]
function Model.Classes(raw)
	local rows = {}
	if type(raw) ~= 'table' then return rows end
	for index = 1, math.min(#raw, 64) do
		local row = raw[index]
		local match = type(row) == 'table' and type(row.MATCH) == 'string' and row.MATCH:lower() or nil
		local usage = type(row) == 'table' and bounded(row.USAGE, 0, 100, nil) or nil
		if match ~= nil and match ~= '' and usage ~= nil then rows[#rows + 1] = { match, usage } end
	end
	return rows
end

--- ox's `classUsage` for one TweakDB record: how hard this vehicle drinks. 0 is
--- ox's `DoesVehicleUseFuel` answering false.
-- @author dop42
-- @param settings table what `Settings` answered
-- @param record any
-- @return number
function Model.Usage(settings, record)
	if type(record) ~= 'string' or record == '' then return settings.defaultUsage end
	local lowered = record:lower()
	for index = 1, #settings.classes do
		local row = settings.classes[index]
		if lowered:find(row[1], 1, true) then return row[2] end
	end
	return settings.defaultUsage
end

-- ── the burn ────────────────────────────────────────────────────────────────

--- The litres one tick costs.
-- @author dop42
-- @param settings table what `Settings` answered
-- @param tick table
--   dtMs     number   the time since the last tick
--   engineOn boolean  the engine bit the host replicates
--   speed    number|nil m/s, as the physics owner reports it
--   moved    number|nil metres between the last two positions the server read
--   usage    number   `Usage` for the record
--   health   number|nil 0..1
-- @return number litres, never negative
-- @return number the distance billed, in metres
function Model.Burn(settings, tick)
	local dt = finiteNumber(tick.dtMs)
	if dt == nil or dt <= 0 or tick.engineOn ~= true then return 0, 0 end
	-- A tick that came very late is billed as one long tick at most: a server
	-- that stalled for a minute must not empty every tank in the city at once.
	if dt > settings.tickMs * 5 then dt = settings.tickMs * 5 end
	local usage = finiteNumber(tick.usage) or settings.defaultUsage
	if usage <= 0 then return 0, 0 end

	local seconds = dt / 1000
	local maxSpeed = settings.maxSpeedKph / KPH
	local speed = finiteNumber(tick.speed)
	speed = speed ~= nil and math.min(math.abs(speed), maxSpeed) or 0
	local distance = speed * seconds
	local moved = finiteNumber(tick.moved)
	-- The server's own measure, believed up to what MAX_SPEED_KPH allows over
	-- the tick; past that it is a teleport and only the reported speed counts.
	if moved ~= nil and moved > distance and moved <= maxSpeed * seconds then distance = moved end

	local litres
	if distance < 0.05 then
		litres = settings.idlePerMinute * seconds / 60
	else
		local kph = distance / seconds * KPH
		litres = distance / 100000 * settings.per100km * Model.Factor(settings.curve, kph)
	end
	litres = litres * usage * settings.multiplier

	local health = finiteNumber(tick.health)
	if health ~= nil and health < settings.leakBelow and settings.leakPerMinute > 0 then
		litres = litres + settings.leakPerMinute * seconds / 60
	end
	return litres, distance
end

--- A tank in litres as ox's percentage, 0..100.
-- @author dop42
-- @param litres number
-- @param capacity number
-- @return number
function Model.Percent(litres, capacity)
	if type(litres) ~= 'number' or type(capacity) ~= 'number' or capacity <= 0 then return 0 end
	local percent = litres / capacity * 100
	if percent ~= percent then return 0 end
	return math.max(0, math.min(100, percent))
end

--- ox's percentage as litres in a tank.
-- @author dop42
-- @param percent number
-- @param capacity number
-- @return number
function Model.Litres(percent, capacity)
	return math.max(0, math.min(capacity, capacity * percent / 100))
end

--- What a number of litres costs, in whole eddies, rounded UP: a pump never
--- pours a free drop.
-- @author dop42
-- @param litres number
-- @param price number per litre
-- @return integer
function Model.Cost(litres, price)
	if litres <= 0 or price <= 0 then return 0 end
	return math.ceil(litres * price - 1e-9)
end

-- ── the stations ────────────────────────────────────────────────────────────

-- A coordinate triple, or nil; and whether it is the all-zero placeholder.
local function point(raw)
	if type(raw) ~= 'table' then return nil, false end
	local x, y, z = OPX.Spots.Coordinate(raw.X), OPX.Spots.Coordinate(raw.Y), OPX.Spots.Coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil, false end
	if x == 0 and y == 0 and z == 0 then return nil, true end
	return { x = x, y = y, z = z }, false
end

-- A station key: what a command types and a log line names.
local KEY_PATTERN = '^[%w_%-]+$'
Model.MAX_KEY = 48

--- Every usable station, and every refusal and placeholder in words.
-- @author dop42
--
-- A STATION WITH A PLACEHOLDER IS DISABLED WHOLE, not trimmed to its good
-- pumps: a forecourt half surveyed is a forecourt whose blip is in the wrong
-- place or whose busiest pump is missing, and the operator should hear about it
-- before a player does.
-- @param settings table what `Settings` answered
-- @param raw any the STATIONS block
-- @return table key -> { key, label, x, y, z, bucket, price, pumps = { {x,y,z} } }
-- @return string[] problems: a station refused for its shape
-- @return string[] placeholders: a station disabled because it is unsurveyed
function Model.Stations(settings, raw)
	local stations, problems, placeholders = {}, {}, {}
	if type(raw) ~= 'table' then
		problems[1] = 'STATIONS must be a table of key -> station'
		return stations, problems, placeholders
	end
	for key, row in pairs(raw) do
		local name = tostring(key)
		if type(key) ~= 'string' or #key > Model.MAX_KEY or not key:match(KEY_PATTERN) then
			problems[#problems + 1] = ('STATIONS.%s: a key is 1 to %d letters, digits, _ or -')
				:format(name, Model.MAX_KEY)
		elseif type(row) ~= 'table' then
			problems[#problems + 1] = ('STATIONS.%s must be a table'):format(name)
		else
			local centre, blank = point(row)
			local bucket = row.BUCKET == nil and 0 or OPX.Spots.Integer(row.BUCKET)
			local pumps, unsurveyed, broken = {}, blank, centre == nil and not blank
			local list = type(row.PUMPS) == 'table' and row.PUMPS or {}
			for index = 1, #list do
				local pump, zero = point(list[index])
				if zero then unsurveyed = true
				elseif pump == nil then broken = true
				else pumps[#pumps + 1] = pump end
			end
			if unsurveyed then
				placeholders[#placeholders + 1] = name
			elseif broken then
				problems[#problems + 1] = ('STATIONS.%s: X, Y and Z of the station and of every pump ' ..
					'must be finite numbers'):format(name)
			elseif #pumps == 0 then
				problems[#problems + 1] = ('STATIONS.%s has no PUMPS'):format(name)
			elseif #pumps > settings.maxPumps then
				problems[#problems + 1] = ('STATIONS.%s has %d pumps, over MAX_PUMPS %d')
					:format(name, #pumps, settings.maxPumps)
			elseif bucket == nil or bucket < 0 then
				problems[#problems + 1] = ('STATIONS.%s: BUCKET must be a whole number, 0 or more')
					:format(name)
			elseif row.LABEL ~= nil and type(row.LABEL) ~= 'string' then
				problems[#problems + 1] = ('STATIONS.%s: LABEL must be a string'):format(name)
			else
				stations[key] = {
					key = key,
					label = (type(row.LABEL) == 'string' and row.LABEL ~= '') and row.LABEL or key,
					x = centre.x, y = centre.y, z = centre.z,
					bucket = bucket,
					price = bounded(row.PRICE, 0, 1000000, settings.price),
					pumps = pumps,
				}
			end
		end
	end
	table.sort(problems)
	table.sort(placeholders)
	return stations, problems, placeholders
end

--- The pump nearest a point within a radius, in one bucket: the station, the
--- pump's index and the distance. Measured in three dimensions, because a pump
--- one storey under a car park is not the pump a player is standing at.
-- @author dop42
-- @param stations table what `Stations` answered
-- @param x number
-- @param y number
-- @param z number
-- @param bucket integer
-- @param radius number metres
-- @return table|nil station
-- @return integer|nil pump index
-- @return number|nil distance
function Model.NearestPump(stations, x, y, z, bucket, radius)
	if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
	local limit = radius * radius
	local best, bestIndex, bestDistance
	for _, station in pairs(stations) do
		if station.bucket == bucket then
			for index = 1, #station.pumps do
				local pump = station.pumps[index]
				local dx, dy, dz = x - pump.x, y - pump.y, z - pump.z
				local distance = dx * dx + dy * dy + dz * dz
				if distance <= limit and (bestDistance == nil or distance < bestDistance
					or (distance == bestDistance and station.key < best.key)) then
					best, bestIndex, bestDistance = station, index, distance
				end
			end
		end
	end
	if best == nil then return nil end
	return best, bestIndex, math.sqrt(bestDistance)
end
