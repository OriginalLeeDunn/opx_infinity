--- Config reads, coercions and floor decisions for both halves.
-- @author dop42
--
-- `POSITIONS` and `ENTITY_HASHES` are built once at load: `Locate` walks every
-- elevator for every native lift of every scan, and a coordinate converted there
-- would be converted again every pass.
--
-- The three radii, JOB_MAX_AGE_MS and SCAN_MS are read once here, and a value
-- `Problems` refuses reads as zero: a bad value becomes a warning at boot rather
-- than a raise inside a network handler, a contract call or a scan.

local M = OPX.Modules.Get('elevators')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}

--- The configured elevators, or an empty table when missing.
-- Read as empty rather than refused, because every read is reachable from the
-- contract.
Access.ELEVATORS = type(Config.ELEVATORS) == 'table' and Config.ELEVATORS or {}
local ELEVATORS = Access.ELEVATORS

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
local finiteNumber = OPX.Math.Finite
Access.FiniteNumber = finiteNumber

-- The world box and the two coercions over it, in `lib/shared/spots.lua`. Only
-- those: an elevator is a SHAFT WITH FLOORS, not a placed spot, and the record
-- below -- an entity, a list of stops, a per-floor gate -- is its own shape.
-- What it does share with every other placed thing is where a coordinate stops
-- being believable, and that is one number for the whole map.
Access.Coordinate = OPX.Spots.Coordinate
Access.Integer = OPX.Spots.Integer
local coordinate, integer = Access.Coordinate, Access.Integer

-- The %d ceiling quoted in this module's own refusal messages.
local BOUND = OPX.Spots.BOUND

-- Elevator key to its declared ENTITY, lower-cased once, and to its validated
-- x and y. Engine identifiers are opaque: compared as lower-cased strings and
-- never through tonumber.
local ENTITY_HASHES, POSITIONS = {}, {}

for key, elevator in pairs(ELEVATORS) do
	if type(elevator) == 'table' then
		if type(elevator.ENTITY) == 'string' then ENTITY_HASHES[key] = elevator.ENTITY:lower() end
		local x, y = coordinate(elevator.X), coordinate(elevator.Y)
		if x ~= nil and y ~= nil then POSITIONS[key] = { x = x, y = y } end
	end
end

local MATCH_RADIUS = finiteNumber(Config.MATCH_RADIUS) or 0
local USE_RADIUS = finiteNumber(Config.USE_RADIUS) or 0
local SCAN_RADIUS = finiteNumber(Config.SCAN_RADIUS) or 0

Access.MATCH_RADIUS_SQ = MATCH_RADIUS * MATCH_RADIUS
Access.USE_RADIUS = USE_RADIUS
Access.USE_RADIUS_SQ = USE_RADIUS * USE_RADIUS
Access.SCAN_RADIUS_SQ = SCAN_RADIUS * SCAN_RADIUS

Access.JOB_MAX_AGE_MS = finiteNumber(Config.JOB_MAX_AGE_MS) or 0
Access.POLL_MS = math.floor(finiteNumber(Config.POLL_MS) or 0)

--- SCAN_MS in whole milliseconds; an invalid value reads as zero.
-- The scheduler is given this and never the raw config value: a string or a
-- negative raises, and zero would scan every frame.
Access.SCAN_MS = math.floor(finiteNumber(Config.SCAN_MS) or 0)

--- Squared horizontal distance to an elevator's declared position.
-- @author dop42
-- @param key string
-- @param x number
-- @param y number
-- @return number|nil
function Access.FlatDistanceSquared(key, x, y)
	local at = POSITIONS[key]
	if at == nil then return nil end
	local dx, dy = x - at.x, y - at.y
	return dx * dx + dy * dy
end

--- Answers one configured elevator by key, or nil.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Elevator(key)
	if type(key) ~= 'string' then return nil end
	local elevator = ELEVATORS[key]
	if type(elevator) ~= 'table' then return nil end
	return elevator
end

--- Answers one configured floor by its native index, or nil.
-- Every entry is checked as a table, because `FLOORS = { 0, 1 }` is a thing an
-- operator writes.
-- @author dop42
-- @param key string
-- @param index integer
-- @return table|nil
function Access.Floor(key, index)
	local elevator = Access.Elevator(key)
	index = finiteNumber(index)
	if elevator == nil or index == nil then return nil end
	local floors = elevator.FLOORS
	if type(floors) ~= 'table' then return nil end
	for position = 1, #floors do
		local floor = floors[position]
		if type(floor) == 'table' and floor.INDEX == index then return floor end
	end
	return nil
end

--- Matches a native lift position to a configured elevator.
-- A declared ENTITY names the elevator, but X and Y must still agree: a sighting
-- with one broken axis is a broken sighting. At equal distance the key decides,
-- so `pairs` order never chooses between two shafts of one lobby.
-- @author dop42
-- @param x any
-- @param y any
-- @param z any
-- @param entity string|nil
-- @return string|nil
-- @return table|nil
function Access.Locate(x, y, z, entity)
	x, y = coordinate(x), coordinate(y)
	if x == nil or y == nil or coordinate(z) == nil then return nil, nil end
	local hash = type(entity) == 'string' and entity:lower() or nil
	local radius = Access.MATCH_RADIUS_SQ
	local bestKey, bestDistance
	for key, at in pairs(POSITIONS) do
		local dx, dy = x - at.x, y - at.y
		local flat = dx * dx + dy * dy
		if flat <= radius then
			local declared = ENTITY_HASHES[key]
			if declared ~= nil and declared == hash then
				return key, ELEVATORS[key]
			end
			if declared == nil and (bestDistance == nil or flat < bestDistance or
				(flat == bestDistance and key < bestKey)) then
				bestKey, bestDistance = key, flat
			end
		end
	end
	if bestKey == nil then return nil, nil end
	return bestKey, ELEVATORS[bestKey]
end

--- Decides whether a character snapshot may select a floor.
-- A public floor stays open with no snapshot at all: a broken character read
-- must not lock a lobby. A gated floor closes past JOB_MAX_AGE_MS. The age is
-- measured with FiniteNumber and never with Coordinate, because a millisecond
-- clock passes BOUND during a session.
--
-- THE RULE ITSELF NOW LIVES IN `lib/shared/jobgate.lua` and this is the adapter
-- that names a FLOOR's fields to it. It was written here first and moved the
-- day `modules/teleports` wanted the same five branches -- the ranking, the
-- staleness bound, the primary-versus-any-membership distinction and the
-- public-stays-open rule -- rather than being copied a second time. Every
-- refusal string is unchanged, which is what the elevators suite asserts.
-- @author dop42
-- @param floor table
-- @param snapshot table|nil
-- @param nowMs integer
-- @return boolean
-- @return string|nil
function Access.Evaluate(floor, snapshot, nowMs)
	-- CLOSED FOR A FLOOR THAT IS NOT A TABLE, and this line was missing. Reading
	-- `floor.JOBS` off a nil RAISED, out of whichever net handler was asking,
	-- while `modules/teleports` answered closed and `modules/gunsmith` answered
	-- OPEN for the same input -- three answers to one question. They agree now,
	-- and they agree on closed.
	if type(floor) ~= 'table' then return false, 'no_such_floor' end
	return OPX.JobGate.Evaluate({ jobs = floor.JOBS, onDuty = floor.ON_DUTY }, snapshot, nowMs,
		{ maxAgeMs = Access.JOB_MAX_AGE_MS, membership = Config.MEMBERSHIP })
end

--- Builds every floor row to draw for a character, in order.
-- A malformed entry is skipped rather than drawn; `Problems` is what reports it.
-- @author dop42
-- @param key string
-- @param snapshot table|nil
-- @param nowMs integer
-- @return table[]
function Access.List(key, snapshot, nowMs)
	local elevator = Access.Elevator(key)
	if elevator == nil then return {} end
	local floors = elevator.FLOORS
	if type(floors) ~= 'table' then return {} end
	local hide = Config.DENIED_FLOORS == 'hidden'
	local rows = {}
	for position = 1, #floors do
		local floor = floors[position]
		if type(floor) == 'table' then
			local ok, failure = Access.Evaluate(floor, snapshot, nowMs)
			if ok or not hide then
				rows[#rows + 1] = {
					index = floor.INDEX,
					label = floor.LABEL,
					ok = ok,
					error = failure,
					reason = (not ok) and floor.REASON or nil,
				}
			end
		end
	end
	return rows
end

-- The coordinate axes, in report order.
local AXES = { 'X', 'Y', 'Z' }

-- Config keys a distance or a timer uses, all of which must be above zero.
local NUMBERS = { 'MATCH_RADIUS', 'USE_RADIUS', 'SCAN_RADIUS', 'SCAN_MS', 'POLL_MS',
	'JOB_MAX_AGE_MS', 'TRAVEL_MS', 'REQUEST_WINDOW_MS', 'REQUESTS_PER_WINDOW' }

--- Lists every configuration error visible without a world, sorted.
-- Job NAMES are not checked: they live in the character module and this runs at
-- load, with nothing waited on. The axes come first, because every distance and
-- every `%.2f` raises on a string; FLOOR_COUNT has its own test, because `%d`
-- raises on a number with no integer form; a hole in FLOORS arrives here as nil
-- and is checked before any read; an invalid INDEX is dropped at once, because
-- `seen[nil]` would raise on the very value being diagnosed.
-- @author dop42
-- @return string[]
function Access.Problems()
	local lines = {}
	if type(Config.ELEVATORS) ~= 'table' then
		lines[#lines + 1] = 'ELEVATORS must be a table of elevator key -> definition'
	end
	for position = 1, #NUMBERS do
		local name = NUMBERS[position]
		local value = finiteNumber(Config[name])
		if value == nil or value <= 0 then
			lines[#lines + 1] = name .. ' must be a finite number above zero'
		end
	end
	-- `Open77.elevators.nearby` takes 1 to 300 metres and nothing else, so a
	-- wider scan found no lift at all and nothing said why.
	local scan = finiteNumber(Config.SCAN_RADIUS)
	if scan ~= nil and (scan < 1 or scan > 300) then
		lines[#lines + 1] = 'SCAN_RADIUS must be between 1 and 300 metres (the host refuses wider)'
	end

	for key, elevator in pairs(ELEVATORS) do
		if type(elevator) ~= 'table' then
			lines[#lines + 1] = tostring(key) .. ': every ELEVATORS entry must be a table'
		else
			for _, axis in ipairs(AXES) do
				if coordinate(elevator[axis]) == nil then
					lines[#lines + 1] = ('%s: %s must be a finite number inside %d'):format(key, axis,
						BOUND)
				end
			end

			local floors = elevator.FLOORS
			if type(floors) ~= 'table' or #floors == 0 then
				lines[#lines + 1] = key .. ': no FLOORS, so its panel would be empty'
			else
				local count = integer(elevator.FLOOR_COUNT)
				if elevator.FLOOR_COUNT ~= nil and (count == nil or count < 1) then
					lines[#lines + 1] = key .. ': FLOOR_COUNT must be a whole number, 1 or more'
					count = nil
				end

				local seen = {}
				for position = 1, #floors do
					local floor = floors[position]
					local where = ('%s floor #%d'):format(key, position)
					if type(floor) ~= 'table' then
						lines[#lines + 1] = where .. ': every FLOORS entry must be a table'
					else
						local index = integer(floor.INDEX)
						if index == nil or index < 0 then
							lines[#lines + 1] = where .. ': INDEX must be a whole number, 0 or more'
							index = nil
						elseif count ~= nil and index >= count then
							lines[#lines + 1] = ('%s: INDEX %d is outside FLOOR_COUNT %d'):format(where,
								index, count)
						elseif seen[index] then
							lines[#lines + 1] = ('%s: INDEX %d is declared twice'):format(where, index)
						end
						if index ~= nil then seen[index] = true end
						if type(floor.LABEL) ~= 'string' or floor.LABEL == '' then
							lines[#lines + 1] = where .. ': no LABEL'
						end
						-- The JOBS block is checked by the shared gate that reads it, so
						-- the two can never drift into accepting different shapes.
						OPX.JobGate.Problems(floor.JOBS, where, lines)
					end
				end
			end
		end
	end
	-- Sorted, because `pairs` order would reshuffle the report between runs.
	table.sort(lines)
	return lines
end
