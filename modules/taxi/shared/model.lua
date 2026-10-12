--- The taxi config, read once into a closed shape, and the arithmetic over it.
-- @author dop42
--
-- PURE. Not one host call in this file: the fare, the meter step, the street
-- pay and its hourly cap are arithmetic over the config and over numbers the
-- server read from the host. That is what lets the tests drive every rule
-- off-platform and both halves read the same companies.
--
-- A VALUE THE VALIDATOR REFUSES READS AS ITS SAFEST FLOOR: a fare with no usable
-- PER_KM charges 0 per km, a point at the placeholder 0,0,0 is skipped, a
-- company with no JOBS cannot be worked for. `Problems` says each of those once
-- at boot, so a bad config is a line in the journal.

local M = OPX.Modules.Get('taxi')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.min(high, math.max(low, number))
end

local function whole(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.floor(math.min(high, math.max(low, number)))
end

local function text(value, fallback)
	return type(value) == 'string' and value ~= '' and value or fallback
end

local function moneyType(value, fallback)
	local types = OPX.Config.SHARED and OPX.Config.SHARED.MONEY and OPX.Config.SHARED.MONEY.TYPES
	if type(value) == 'string' and type(types) == 'table' then
		for _, known in pairs(types) do
			if known == value then return value end
		end
	end
	return fallback
end

local VOICES = { delamain = true, generic = true }

--- Whether a point is the unfilled blank a config ships with: all three axes
--- exactly zero (see `modules/hauling/shared/access.lua` for why exactly).
-- @author dop42
-- @param point table|nil
-- @return boolean
function Model.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- A list of usable points, placeholders and broken rows skipped.
local function points(raw)
	local out = {}
	if type(raw) ~= 'table' then return out end
	for index, row in ipairs(raw) do
		if type(row) == 'table' and not Model.IsPlaceholder(row) then
			local x, y, z = coordinate(row.X), coordinate(row.Y), coordinate(row.Z)
			if x and y and z then
				out[#out + 1] = { index = index, label = text(row.LABEL, ('#%d'):format(index)), x = x, y = y, z = z }
			end
		end
	end
	return out
end

--- An icon name as the declared asset path in `web/blips/`, or nil.
-- @author dop42
function Model.Icon(value)
	if type(value) ~= 'string' or value == '' then return nil end
	local file = value:find('%.svg$') and value or (value .. '.svg')
	if not file:find('/', 1, true) then file = 'web/blips/' .. file end
	return file:match('^[%w_%-/]+%.svg$') and file or nil
end

--- A '#RRGGBB' or '#RRGGBBAA' colour, or nil.
-- @author dop42
function Model.Color(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^#%x%x%x%x%x%x$') or value:match('^#%x%x%x%x%x%x%x%x$') then return value end
	return nil
end

local function night(raw)
	if type(raw) ~= 'table' then return nil end
	local from, to = whole(raw.FROM, 0, 23, nil), whole(raw.TO, 0, 24, nil)
	local multiplier = bounded(raw.MULTIPLIER, 1, 10, nil)
	if from == nil or to == nil or multiplier == nil or from == to % 24 then return nil end
	return { from = from, to = to % 24, multiplier = multiplier }
end

local function company(key, raw)
	if type(raw) ~= 'table' or raw.ENABLED == false then return nil end
	local dispatch = type(raw.DISPATCH) == 'table' and raw.DISPATCH or {}
	local fare = type(raw.FARE) == 'table' and raw.FARE or {}
	local npc = type(raw.NPC_FARES) == 'table' and raw.NPC_FARES or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local vehicles
	for _, record in ipairs(type(raw.VEHICLES) == 'table' and raw.VEHICLES or {}) do
		if type(record) == 'string' and record ~= '' then
			vehicles = vehicles or {}
			vehicles[record] = true
		end
	end
	local minFare = whole(fare.MIN, 0, 100000000, 0)
	local npcOn = npc.ENABLED == true
	return {
		key = key,
		label = text(raw.LABEL, key),
		short = text(raw.SHORT, key:upper()),
		jobs = type(raw.JOBS) == 'table' and next(raw.JOBS) ~= nil and raw.JOBS or nil,
		onDuty = raw.ON_DUTY ~= false,
		voice = VOICES[raw.VOICE] and raw.VOICE or 'generic',
		blipColor = Model.Color(blip.COLOR),
		dispatch = {
			minGrade = whole(dispatch.MIN_GRADE, 0, 100, 0),
			ttlMs = whole(dispatch.CALL_TTL_S, 30, 86400, 300) * 1000,
		},
		fare = {
			moneyType = moneyType(fare.MONEY_TYPE, 'BANK'),
			base = whole(fare.BASE, 0, 100000000, 0),
			perKm = bounded(fare.PER_KM, 0, 100000000, 0),
			min = minFare,
			max = math.max(minFare, whole(fare.MAX, 0, 100000000, 100000000)),
			night = night(fare.NIGHT),
		},
		driverCut = whole(raw.DRIVER_CUT_PCT, 0, 100, 100),
		account = text(raw.ACCOUNT, nil),
		vehicles = vehicles,
		npc = {
			enabled = npcOn,
			onlyWhenIdle = npc.ONLY_WHEN_IDLE ~= false,
			base = whole(npc.BASE, 0, 100000000, 0),
			perKm = bounded(npc.PER_KM, 0, 100000000, 0),
			hourlyCap = whole(npc.HOURLY_CAP, 0, 100000000, 0),
			moneyType = moneyType(npc.MONEY_TYPE, 'BANK'),
			radius = bounded(npc.RADIUS, 2, 100, 12),
			ttlMs = whole(npc.TTL_S, 60, 7200, 900) * 1000,
			minTripM = bounded(npc.MIN_TRIP_M, 0, 100000, 400),
			pickups = npcOn and points(npc.PICKUPS) or {},
			destinations = npcOn and points(npc.DESTINATIONS) or {},
		},
	}
end

--- The whole config, normalised: globals and every usable company.
-- @author dop42
-- @param raw table|nil OPX.Config.MODULES.taxi
-- @return table
function Model.Settings(raw)
	raw = type(raw) == 'table' and raw or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local commands = type(raw.COMMANDS) == 'table' and raw.COMMANDS or {}
	local function command(value, fallback)
		if value == false then return nil end
		local name = text(value, fallback)
		return name and name:match('^[%w_%.%-]+$') and name or nil
	end
	local settings = {
		membership = raw.MEMBERSHIP == 'any' and 'any' or 'primary',
		requestMs = whole(raw.REQUEST_MS, 0, 60000, 750),
		scanMs = whole(raw.SCAN_MS, 250, 10000, 1000),
		maxSpeed = bounded(raw.MAX_SPEED, 5, 300, 75),
		etaSpeed = bounded(raw.ETA_SPEED, 1, 100, 14),
		exitSamples = whole(raw.EXIT_SAMPLES, 1, 20, 2),
		minRideM = bounded(raw.MIN_RIDE_M, 0, 10000, 50),
		meterPushMs = whole(raw.METER_PUSH_MS, 0, 600000, 10000),
		commands = { call = command(commands.CALL, 'taxi'), board = command(commands.BOARD, 'cab') },
		alertMs = whole(raw.ALERT_MS, 1000, 60000, 8000),
		blipSprite = text(blip.SPRITE, 'objective'),
		blipIcon = Model.Icon(blip.ICON),
		blipSize = whole(blip.SIZE, 16, 128, 48),
		blipColor = Model.Color(blip.COLOR),
		blipWalls = blip.WALLS ~= false,
		companies = {},
		companyOrder = {},
	}
	for key, row in pairs(type(raw.COMPANIES) == 'table' and raw.COMPANIES or {}) do
		local read = type(key) == 'string' and key:match('^[%w_]+$') and company(key, row) or nil
		if read ~= nil and read.jobs ~= nil then
			settings.companies[key] = read
			settings.companyOrder[#settings.companyOrder + 1] = key
		end
	end
	table.sort(settings.companyOrder)
	return settings
end

--- The JOBS block a gate checks: the company's jobs, each floor raised to
--- `minGrade` when the action asks for more.
-- @author dop42
-- @param co table a normalised company
-- @param minGrade integer|nil
-- @return table|nil
function Model.Jobs(co, minGrade)
	if type(co) ~= 'table' or type(co.jobs) ~= 'table' then return nil end
	local floor = math.tointeger(minGrade) or 0
	local out = {}
	for name, grade in pairs(co.jobs) do out[name] = math.max(finiteNumber(grade) or 0, floor) end
	return out
end

--- Whether a game hour falls in a night window (FROM inclusive, TO exclusive,
--- wrapping midnight).
-- @author dop42
-- @param window table|nil { from, to }
-- @param hour number|nil
-- @return boolean
function Model.IsNight(window, hour)
	hour = finiteNumber(hour)
	if type(window) ~= 'table' or hour == nil then return false end
	hour = math.floor(hour) % 24
	if window.from < window.to then return hour >= window.from and hour < window.to end
	return hour >= window.from or hour < window.to
end

--- What a metered ride costs, in whole units: flag fall plus distance, the
--- night surge when the hour is known and in the window, clamped to MIN..MAX.
--- A ride shorter than `minRideM` is free.
-- @author dop42
-- @param co table a normalised company
-- @param metres number measured by the server
-- @param hour number|nil game hour, nil when no clock
-- @param minRideM number|nil
-- @return integer fare
-- @return boolean surged
function Model.Fare(co, metres, hour, minRideM)
	metres = finiteNumber(metres) or 0
	if type(co) ~= 'table' or metres < (finiteNumber(minRideM) or 0) then return 0, false end
	local fare = co.fare.base + co.fare.perKm * metres / 1000
	local surged = Model.IsNight(co.fare.night, hour)
	if surged then fare = fare * co.fare.night.multiplier end
	fare = math.floor(fare + 0.5)
	return math.max(co.fare.min, math.min(co.fare.max, fare)), surged
end

--- A fare split between the driver and the company, both whole, summing to it.
-- @author dop42
-- @param fare integer
-- @param cutPct integer 0..100, the driver's share
-- @return integer driver
-- @return integer company
function Model.Split(fare, cutPct)
	fare = math.max(0, math.floor(finiteNumber(fare) or 0))
	local pct = math.min(100, math.max(0, finiteNumber(cutPct) or 100))
	local driver = math.floor(fare * pct / 100 + 0.5)
	return driver, fare - driver
end

--- One meter step: the straight distance between two samples, clamped to what
--- a car at `maxSpeed` covers in the time between them. A change of routing
--- bucket, a missing sample or time running backwards adds nothing.
-- @author dop42
-- @param from table|nil { x, y, z, bucket, atMs }
-- @param to table|nil { x, y, z, bucket, atMs }
-- @param maxSpeed number metres per second
-- @return number metres
function Model.Step(from, to, maxSpeed)
	if type(from) ~= 'table' or type(to) ~= 'table' then return 0 end
	if (from.bucket or 0) ~= (to.bucket or 0) then return 0 end
	local dt = (finiteNumber(to.atMs) or 0) - (finiteNumber(from.atMs) or 0)
	if dt <= 0 then return 0 end
	local dx, dy, dz = to.x - from.x, to.y - from.y, to.z - from.z
	local gap = math.sqrt(dx * dx + dy * dy + dz * dz)
	if gap ~= gap then return 0 end
	return math.min(gap, (finiteNumber(maxSpeed) or 75) * dt / 1000)
end

--- The straight distance between two points.
-- @author dop42
function Model.Distance(a, b)
	if type(a) ~= 'table' or type(b) ~= 'table' then return nil end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- What a street fare pays before the cap, on the straight pickup -> drop-off.
-- @author dop42
-- @param npc table the company's normalised NPC_FARES
-- @param metres number
-- @return integer
function Model.StreetPay(npc, metres)
	if type(npc) ~= 'table' then return 0 end
	return math.max(0, math.floor(npc.base + npc.perKm * (finiteNumber(metres) or 0) / 1000 + 0.5))
end

--- What is left of a rolling hourly cap, pruning entries older than an hour.
-- @author dop42
-- @param history table list of { atMs, amount }, mutated: old entries removed
-- @param nowMs integer
-- @param cap integer 0 = no street pay at all
-- @return integer remaining
function Model.CapRemaining(history, nowMs, cap)
	local spent, kept = 0, {}
	for _, row in ipairs(type(history) == 'table' and history or {}) do
		if nowMs - row.atMs < 3600000 then
			kept[#kept + 1] = row
			spent = spent + row.amount
		end
	end
	if type(history) == 'table' then
		for index = #history, 1, -1 do history[index] = nil end
		for index, row in ipairs(kept) do history[index] = row end
	end
	return math.max(0, (math.tointeger(cap) or 0) - spent)
end

--- Draws a street trip: a pickup and a destination at least MIN_TRIP_M apart.
-- @author dop42
-- @param npc table
-- @param random fun(n: integer): integer 1..n
-- @return table|nil pickup
-- @return table|nil destination
function Model.PickTrip(npc, random)
	if type(npc) ~= 'table' or #npc.pickups == 0 or #npc.destinations == 0 then return nil, nil end
	local pickup = npc.pickups[random(#npc.pickups)]
	local options = {}
	for _, point in ipairs(npc.destinations) do
		if (Model.Distance(pickup, point) or 0) >= npc.minTripM then options[#options + 1] = point end
	end
	if #options == 0 then return nil, nil end
	return pickup, options[random(#options)]
end

--- Every complaint the configuration earns, one line each, naming the entry.
-- @author dop42
-- @param raw table|nil
-- @return string[]
function Model.Problems(raw)
	local lines = {}
	raw = type(raw) == 'table' and raw or {}
	if type(raw.COMPANIES) ~= 'table' or next(raw.COMPANIES) == nil then
		lines[#lines + 1] = 'COMPANIES is empty: nobody drives a cab'
		return lines
	end
	if raw.MEMBERSHIP ~= nil and raw.MEMBERSHIP ~= 'primary' and raw.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = "MEMBERSHIP must be 'primary' or 'any'"
	end
	local live = 0
	for key, row in pairs(raw.COMPANIES) do
		local name = tostring(key)
		if type(key) ~= 'string' or not key:match('^[%w_]+$') then
			lines[#lines + 1] = name .. ': a company key is letters, digits and underscores'
		elseif type(row) ~= 'table' then
			lines[#lines + 1] = name .. ': every COMPANIES entry must be a table'
		elseif row.ENABLED ~= false then
			live = live + 1
			if type(row.JOBS) ~= 'table' or next(row.JOBS) == nil then
				lines[#lines + 1] = name .. ': no JOBS, so nobody can drive for this company; it is disabled'
			else
				OPX.JobGate.Problems(row.JOBS, name, lines)
			end
			if row.VOICE ~= nil and not VOICES[row.VOICE] then
				lines[#lines + 1] = name .. ": VOICE must be 'delamain' or 'generic'"
			end
			local fare = type(row.FARE) == 'table' and row.FARE or {}
			if finiteNumber(fare.PER_KM) == nil then
				lines[#lines + 1] = name .. ': FARE.PER_KM is not a number: the meter charges nothing per km'
			end
			if fare.NIGHT ~= nil and night(fare.NIGHT) == nil then
				lines[#lines + 1] = name .. ': FARE.NIGHT needs FROM and TO hours (different) and a ' ..
					'MULTIPLIER >= 1; there is no surge'
			end
			local npc = type(row.NPC_FARES) == 'table' and row.NPC_FARES or {}
			if npc.ENABLED == true then
				for _, list in ipairs({ 'PICKUPS', 'DESTINATIONS' }) do
					local blanks, total = 0, 0
					for _, point in ipairs(type(npc[list]) == 'table' and npc[list] or {}) do
						total = total + 1
						if Model.IsPlaceholder(point) then blanks = blanks + 1 end
					end
					if total == 0 then
						lines[#lines + 1] = ('%s: NPC_FARES.%s is empty: no street fare'):format(name, list)
					elseif blanks > 0 then
						lines[#lines + 1] = ('%s: %d of %d NPC_FARES.%s ARE STILL THE PLACEHOLDER 0,0,0 -- ' ..
							'they are disabled. Stand on each spot in game and paste your position in')
							:format(name, blanks, total, list)
					end
				end
				if finiteNumber(npc.HOURLY_CAP) == nil then
					lines[#lines + 1] = name .. ': NPC_FARES.HOURLY_CAP is not a number: street fares pay nothing'
				end
			end
		end
	end
	if live == 0 then lines[#lines + 1] = 'every company is disabled: nobody drives a cab' end
	table.sort(lines)
	return lines
end
