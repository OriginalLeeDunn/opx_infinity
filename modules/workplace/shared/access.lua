--- Config reads, the boot validator, and the pure decisions a request needs.
-- @author dop42
--
-- PURE, like `modules/netrunner/shared/access.lua`: not one host call. Every
-- function takes what it needs as arguments -- the config, the jobs table, a
-- worn record -- so the server calls it in a handler, the client builds its
-- rows with it one station a resume, and a test drives it to every branch.
--
-- A BAD STATION IS REFUSED ALONE: a typo at the Kabuki precinct must not close
-- the Trauma Team HQ. A POINT at three exact zeros is not refused but DISABLED
-- until somebody surveys it, and named so; a station with no live point left
-- is disabled as a whole.

local M = OPX.Modules.Get('workplace')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 48
Access.MAX_KEY = MAX_KEY
local MAX_RECORD = 160

local IS_SLOT = {}
for _, slot in ipairs(M.SLOTS) do IS_SLOT[slot] = true end

local function key(value)
	return type(value) == 'string' and #value >= 1 and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
end
Access.Key = key

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' or #value > (maximum or 96) then return nil end
	return value
end

local function bounded(value, low, high)
	value = finiteNumber(value)
	if value == nil or value < low or value > high then return nil end
	return value
end

local function integer(value, low, high)
	value = bounded(value, low, high)
	if value == nil or value % 1 ~= 0 then return nil end
	return math.floor(value)
end

-- A clothing record name, the shape `appearance` accepts.
local function clothingRecord(value)
	return type(value) == 'string' and #value <= MAX_RECORD and value:match('^Items%.[%w_%.%-]+$') ~= nil
end

local function vehicleRecord(value)
	return type(value) == 'string' and #value <= 256 and value:match('^Vehicle%.[%w_%.%-]+$') ~= nil
end

local function colourOf(raw)
	if raw == nil then return nil, true end
	if type(raw) ~= 'table' then return nil, false end
	local r, g, b = integer(raw.r, 0, 255), integer(raw.g, 0, 255), integer(raw.b, 0, 255)
	if r == nil or g == nil or b == nil then return nil, false end
	return { r = r, g = g, b = b }, true
end

--- Whether a point is the unfilled blank: all three axes exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Access.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- ── the per-job blocks ──────────────────────────────────────────────────────

local function slotsOf(raw)
	if raw == nil then return {}, true end
	if type(raw) ~= 'table' then return nil, false end
	local out = {}
	for slot, record in pairs(raw) do
		if not IS_SLOT[slot] or not clothingRecord(record) then return nil, false end
		out[slot] = record
	end
	return out, true
end

local function outfitsOf(raw, jobs, problems, yield)
	local out = {}
	for job, list in pairs(type(raw) == 'table' and raw or {}) do
		yield()
		if type(jobs[job]) ~= 'table' then
			problems[#problems + 1] = ('OUTFITS.%s: no such job in config/character.lua'):format(tostring(job))
		elseif type(list) == 'table' then
			out[job] = {}
			for name, outfit in pairs(list) do
				local where = ('OUTFITS.%s.%s'):format(job, tostring(name))
				local wear, okWear = slotsOf(type(outfit) == 'table' and outfit.WEAR or false)
				local female, okFemale = slotsOf(type(outfit) == 'table' and outfit.FEMALE or nil)
				local male, okMale = slotsOf(type(outfit) == 'table' and outfit.MALE or nil)
				if not key(name) or not okWear or not okFemale or not okMale or next(wear or {}) == nil then
					problems[#problems + 1] = where .. ': WEAR (and FEMALE / MALE) must map ' ..
						'Head|Face|InnerChest|OuterChest|Legs|Feet|Outfit to Items.* records'
				else
					out[job][name] = {
						key = name,
						label = text(outfit.LABEL) or name,
						minGrade = integer(outfit.MIN_GRADE, 0, 100) or 0,
						wear = wear, female = female, male = male,
						keepOthers = outfit.KEEP_OTHERS == true,
					}
				end
			end
		end
	end
	return out
end

local function fleetOf(raw, jobs, problems, yield)
	local out = {}
	for job, list in pairs(type(raw) == 'table' and raw or {}) do
		yield()
		if type(jobs[job]) ~= 'table' then
			problems[#problems + 1] = ('FLEET.%s: no such job in config/character.lua'):format(tostring(job))
		elseif type(list) == 'table' then
			out[job] = {}
			for name, vehicle in pairs(list) do
				local where = ('FLEET.%s.%s'):format(job, tostring(name))
				local primary, okPrimary = colourOf(type(vehicle) == 'table' and vehicle.PRIMARY or nil)
				local secondary, okSecondary = colourOf(type(vehicle) == 'table' and vehicle.SECONDARY or nil)
				if not key(name) or type(vehicle) ~= 'table' or not vehicleRecord(vehicle.RECORD)
					or not okPrimary or not okSecondary then
					problems[#problems + 1] = where .. ': a RECORD = \'Vehicle.*\' and, optionally, ' ..
						'PRIMARY / SECONDARY = { r, g, b } 0..255'
				else
					out[job][name] = {
						key = name,
						label = text(vehicle.LABEL) or name,
						record = vehicle.RECORD,
						minGrade = integer(vehicle.MIN_GRADE, 0, 100) or 0,
						primary = primary, secondary = secondary,
					}
				end
			end
		end
	end
	return out
end

-- ── the context: everything but the stations ────────────────────────────────

--- Reads the global blocks. `jobs` is config/character.lua JOBS.
-- @author dop42
-- @param settings table
-- @param jobs table
-- @param problems table|nil collector
-- @param yield function|nil called between two jobs: a client passes its
--   `Wait(0)` to stay inside the resume budget
-- @return table
function Access.Context(settings, jobs, problems, yield)
	problems = problems or {}
	yield = yield or function() end
	settings = type(settings) == 'table' and settings or {}
	jobs = type(jobs) == 'table' and jobs or {}
	local wardrobe = type(settings.WARDROBE) == 'table' and settings.WARDROBE or {}
	local garage = type(settings.GARAGE) == 'table' and settings.GARAGE or {}
	local metadata = key(wardrobe.METADATA) and wardrobe.METADATA or 'workplace_civvies'
	return {
		jobs = jobs,
		problems = problems,
		requestMs = integer(settings.REQUEST_MS, 100, 60000) or 800,
		switchPrimary = settings.SWITCH_PRIMARY ~= false,
		wardrobe = {
			onDuty = wardrobe.ON_DUTY ~= false,
			restoreOffDuty = wardrobe.RESTORE_OFF_DUTY ~= false,
			metadata = metadata,
		},
		garage = {
			onDuty = garage.ON_DUTY ~= false,
			ttlMs = (integer(garage.TTL_MIN, 1, 24 * 60) or 180) * 60000,
			returnRadius = bounded(garage.RETURN_RADIUS, 1, 100) or 15.0,
			padClear = bounded(garage.PAD_CLEAR, 0, 20) or 3.0,
			maxPerStation = integer(garage.MAX_PER_STATION, 0, 1000) or 0,
		},
		outfits = outfitsOf(settings.OUTFITS, jobs, problems, yield),
		fleet = fleetOf(settings.FLEET, jobs, problems, yield),
	}
end

-- ── one station ─────────────────────────────────────────────────────────────

-- One point: the point, nil when it is not declared, or false and why.
local function pointOf(raw, where, disabled)
	if raw == nil then return nil end
	if type(raw) ~= 'table' then return false, where .. ': must be a table' end
	if Access.IsPlaceholder(raw) then
		disabled[#disabled + 1] = where
		return nil
	end
	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	local radius = raw.RADIUS == nil and 1.5 or bounded(raw.RADIUS, 0.5, 10)
	if x == nil or y == nil or z == nil or radius == nil then
		return false, where .. ': X, Y, Z and RADIUS 0.5..10'
	end
	return { x = x, y = y, z = z, radius = radius, minGrade = integer(raw.MIN_GRADE, 0, 100) or 0 }
end

--- Reads one station. Answers the station, or nil and why it was refused, and
--- the list of its points left unsurveyed (`station.point`).
-- @author dop42
-- @param name string
-- @param raw table
-- @param context table from `Access.Context`
-- @return table|nil station
-- @return string|nil why it was refused
-- @return string[] disabled points
function Access.Station(name, raw, context)
	local disabled = {}
	if not key(name) then return nil, 'the key must be letters, digits, _ or -', disabled end
	if type(raw) ~= 'table' then return nil, 'must be a table', disabled end
	local job = raw.JOB
	if type(job) ~= 'string' or type(context.jobs[job]) ~= 'table' then
		return nil, ('JOB %s is not a job of config/character.lua'):format(tostring(job)), disabled
	end
	local bucket = raw.BUCKET == nil and 0 or integer(raw.BUCKET, 0, 1000000)
	if bucket == nil then return nil, 'BUCKET must be a whole number', disabled end
	local station = {
		key = name, job = job, label = text(raw.LABEL) or name, bucket = bucket, points = {},
		defaultDuty = context.jobs[job].defaultDuty == true,
	}

	local duty, why = pointOf(raw.DUTY, name .. '.duty', disabled)
	if duty == false then return nil, why, disabled end
	if duty ~= nil and station.defaultDuty then
		return nil, ('DUTY: %s is on duty by definition (defaultDuty), it has no clock'):format(job), disabled
	end
	station.points.duty = duty

	local wardrobe
	wardrobe, why = pointOf(raw.WARDROBE, name .. '.wardrobe', disabled)
	if wardrobe == false then return nil, why, disabled end
	if wardrobe ~= nil and next(context.outfits[job] or {}) == nil then
		return nil, ('WARDROBE: OUTFITS.%s holds no outfit'):format(job), disabled
	end
	station.points.wardrobe = wardrobe

	if raw.GARAGE ~= nil then
		local garage
		garage, why = pointOf(raw.GARAGE, name .. '.garage', disabled)
		if garage == false then return nil, why, disabled end
		local pad = type(raw.GARAGE) == 'table' and raw.GARAGE.PAD or nil
		if garage ~= nil then
			if type(pad) ~= 'table' then return nil, 'GARAGE: a PAD = { X, Y, Z, HEADING }', disabled end
			if Access.IsPlaceholder(pad) then
				disabled[#disabled + 1] = name .. '.pad'
				garage = nil
			else
				local x, y, z = coordinate(pad.X), coordinate(pad.Y), coordinate(pad.Z)
				local heading = pad.HEADING == nil and 0 or bounded(pad.HEADING, -360, 360)
				if x == nil or y == nil or z == nil or heading == nil then
					return nil, 'GARAGE.PAD: X, Y, Z and HEADING -360..360', disabled
				end
				garage.pad = { x = x, y = y, z = z, heading = heading }
			end
		end
		if garage ~= nil then
			local fleet = context.fleet[job] or {}
			local list = {}
			if raw.GARAGE.VEHICLES ~= nil then
				if type(raw.GARAGE.VEHICLES) ~= 'table' then
					return nil, 'GARAGE.VEHICLES must be a list of FLEET keys', disabled
				end
				for _, vehicle in ipairs(raw.GARAGE.VEHICLES) do
					if fleet[vehicle] == nil then
						return nil, ('GARAGE.VEHICLES: %s is not in FLEET.%s'):format(tostring(vehicle), job), disabled
					end
					list[#list + 1] = vehicle
				end
			else
				for vehicle in pairs(fleet) do list[#list + 1] = vehicle end
				table.sort(list)
			end
			if #list == 0 then return nil, ('GARAGE: FLEET.%s holds no vehicle'):format(job), disabled end
			garage.vehicles = list
		end
		station.points.garage = garage
	end

	if next(station.points) == nil then return nil, nil, disabled end
	return station, nil, disabled
end

--- Builds every station. Answers what the two halves read and what was refused.
-- @author dop42
-- @param settings table OPX.Config.MODULES.workplace
-- @param jobs table config/character.lua JOBS
-- @return table { stations, outfits, fleet, wardrobe, garage, requestMs, switchPrimary, problems, placeholders }
function Access.Build(settings, jobs)
	local problems, placeholders = {}, {}
	local context = Access.Context(settings, jobs, problems)
	local stations = {}
	local raw = type(settings) == 'table' and type(settings.STATIONS) == 'table' and settings.STATIONS or {}
	local names = {}
	for name in pairs(raw) do names[#names + 1] = tostring(name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local station, why, disabled = Access.Station(name, raw[name], context)
		if why ~= nil then
			problems[#problems + 1] = ('STATIONS.%s: %s'):format(name, why)
		else
			for _, point in ipairs(disabled) do placeholders[#placeholders + 1] = point end
			if station ~= nil then stations[name] = station end
		end
	end
	context.stations = stations
	context.placeholders = placeholders
	return context
end

--- The problems alone: what the boot logs.
-- @author dop42
function Access.Problems(settings, jobs)
	return Access.Build(settings, jobs).problems
end

-- ── decisions ───────────────────────────────────────────────────────────────

--- The outfits of a job a grade may wear, sorted by grade then label.
-- @author dop42
-- @param built table
-- @param job string
-- @param grade number
-- @return table[]
function Access.Outfits(built, job, grade)
	local out = {}
	for _, outfit in pairs(built.outfits[job] or {}) do
		if (grade or -1) >= outfit.minGrade then out[#out + 1] = outfit end
	end
	table.sort(out, function(a, b)
		if a.minGrade ~= b.minGrade then return a.minGrade < b.minGrade end
		return a.key < b.key
	end)
	return out
end

--- The vehicles of a station's garage a grade may take out, in config order.
-- @author dop42
-- @param built table
-- @param station table
-- @param grade number
-- @return table[]
function Access.Vehicles(built, station, grade)
	local out = {}
	local garage = station.points.garage
	if garage == nil then return out end
	local fleet = built.fleet[station.job] or {}
	for _, name in ipairs(garage.vehicles) do
		local vehicle = fleet[name]
		if vehicle ~= nil and (grade or -1) >= vehicle.minGrade then out[#out + 1] = vehicle end
	end
	return out
end

--- Whether a vehicle key is one a station's garage offers.
-- @author dop42
function Access.Offers(station, vehicle)
	local garage = station.points.garage
	if garage == nil then return false end
	for _, name in ipairs(garage.vehicles) do
		if name == vehicle then return true end
	end
	return false
end

--- A clothing record with nothing in it, the shape `appearance` stores.
-- @author dop42
-- @return table
function Access.EmptyClothing()
	return { schemaVersion = 1, equipment = {}, wardrobe = { outfits = {} } }
end

--- The clothing record a uniform makes of a civilian one. The base is never
--- changed: a copy is answered. Underwear and the wardrobe's saved outfits are
--- kept; the active wardrobe outfit is dropped, so it cannot cover the uniform.
-- @author dop42
-- @param base table|false|nil the civilian record (false: nothing stored)
-- @param outfit table a built outfit
-- @param family string|nil 'female' | 'male'
-- @return table
function Access.Uniform(base, outfit, family)
	local record = type(base) == 'table' and OPX.Table.DeepCopy(base) or Access.EmptyClothing()
	record.schemaVersion = 1
	record.equipment = type(record.equipment) == 'table' and record.equipment or {}
	record.wardrobe = type(record.wardrobe) == 'table' and record.wardrobe or { outfits = {} }
	record.wardrobe.active = nil
	if type(record.wardrobe.outfits) ~= 'table' then record.wardrobe.outfits = {} end
	local wear = {}
	for slot, item in pairs(outfit.wear) do wear[slot] = item end
	local override = family == 'female' and outfit.female or family == 'male' and outfit.male or nil
	for slot, item in pairs(override or {}) do wear[slot] = item end
	for _, slot in ipairs(M.SLOTS) do
		if wear[slot] ~= nil then
			record.equipment[slot] = wear[slot]
		elseif not outfit.keepOthers then
			record.equipment[slot] = false
		end
	end
	return record
end

--- Whether a position stands at a point: same bucket, within its reach.
-- @author dop42
-- @param at table|nil { x, y, z, bucket }
-- @param point table { x, y, z, radius }
-- @param bucket integer the station's
-- @param radius number|nil overrides the point's
-- @return boolean
function Access.Reaches(at, point, bucket, radius)
	if type(at) ~= 'table' or point == nil or at.bucket ~= bucket then return false end
	local dx, dy, dz = at.x - point.x, at.y - point.y, at.z - point.z
	return dx * dx + dy * dy + dz * dz <= OPX.Spots.ServerReachSq(radius or point.radius)
end
