--- The police config, read once into a closed shape, the arithmetic over it,
--- and the boot validator.
-- @author dop42
--
-- PURE. Not one host call in this file: everything is arithmetic over the
-- config table, which is what lets the tests drive every rule off-platform and
-- lets both halves read the same services without either trusting the other's.
--
-- A VALUE THE VALIDATOR REFUSES READS AS ITS SAFEST FLOOR, never the most
-- permissive reading: a capability with no usable grade is not held, a fine
-- with no usable ceiling is 0, a cell at the placeholder 0,0,0 is skipped.
-- `Problems` says each of those once at boot, so a bad config is a line in the
-- journal rather than a refusal nobody can explain three hours later.

local M = OPX.Modules.Get('police')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local CAPABILITIES = {}
for _, name in pairs(M.Capability) do CAPABILITIES[name] = true end

-- Clamps a value into low..high, or answers the fallback when it is not finite.
local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.min(high, math.max(low, number))
end

-- A whole number in low..high, or the fallback.
local function whole(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.floor(math.min(high, math.max(low, number)))
end

local function text(value, fallback)
	return type(value) == 'string' and value ~= '' and value or fallback
end

local function word(value)
	return type(value) == 'string' and value:match('^[%w_]+$') and #value <= 48 and value or nil
end

-- A money type the shared config names, or the fallback.
local function moneyType(value, fallback)
	local types = OPX.Config.SHARED and OPX.Config.SHARED.MONEY and OPX.Config.SHARED.MONEY.TYPES
	if type(value) == 'string' and type(types) == 'table' then
		for _, known in pairs(types) do
			if known == value then return value end
		end
	end
	return fallback
end

--- Whether a point is the unfilled blank a config ships with: all three axes
--- exactly zero. See `modules/hauling/shared/access.lua` for why exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Access.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- One surveyed point { x, y, z, yaw, radius }, or nil when blank or broken.
local function point(raw, radiusLow, radiusHigh, radiusFallback)
	if type(raw) ~= 'table' or Access.IsPlaceholder(raw) then return nil end
	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, yaw = bounded(raw.YAW, -360, 360, 0),
		radius = bounded(raw.RADIUS, radiusLow or 0.5, radiusHigh or 10, radiusFallback or 1.5),
		label = text(raw.LABEL, '') }
end

--- An icon name as the declared asset path in `web/blips/`, or nil.
-- @author dop42
function Access.Icon(value)
	if type(value) ~= 'string' or value == '' then return nil end
	local file = value:find('%.svg$') and value or (value .. '.svg')
	if not file:find('/', 1, true) then file = 'web/blips/' .. file end
	return file:match('^[%w_%-/]+%.svg$') and file or nil
end

--- A '#RRGGBB' or '#RRGGBBAA' colour, or nil.
-- @author dop42
function Access.Color(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^#%x%x%x%x%x%x$') or value:match('^#%x%x%x%x%x%x%x%x$') then return value end
	return nil
end

local function crimes(raw)
	local out, order = {}, {}
	for code, row in pairs(type(raw) == 'table' and raw or {}) do
		if word(code) and type(row) == 'table' then
			local fine = whole(row.FINE, 0, 100000000, 0)
			out[code] = {
				code = code,
				label = text(row.LABEL, code),
				fine = fine,
				fineMax = whole(row.FINE_MAX, 0, 100000000, fine),
				jailMin = whole(row.JAIL_MIN, 0, 100000, 0),
				priority = whole(row.PRIORITY, 0, 100, 0),
			}
			order[#order + 1] = code
		end
	end
	table.sort(order)
	return out, order
end

local function service(key, raw, globals)
	if type(raw) ~= 'table' then return nil end
	local dispatch = type(raw.DISPATCH) == 'table' and raw.DISPATCH or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local capabilities = {}
	for name, grade in pairs(type(raw.CAPABILITIES) == 'table' and raw.CAPABILITIES or {}) do
		local floor = whole(grade, 0, 100, nil)
		if CAPABILITIES[name] and floor ~= nil then capabilities[name] = floor end
	end
	local receives, all = {}, false
	for _, code in ipairs(type(dispatch.RECEIVES) == 'table' and dispatch.RECEIVES or {}) do
		if code == '*' then all = true elseif word(code) then receives[code] = true end
	end
	local enclaves, enclaveRows = {}, 0
	for _, row in ipairs(type(raw.ENCLAVES) == 'table' and raw.ENCLAVES or {}) do
		enclaveRows = enclaveRows + 1
		local spot = point(row, 1, 5000, 100)
		if spot ~= nil then enclaves[#enclaves + 1] = spot end
	end
	return {
		key = key,
		label = text(raw.LABEL, key),
		short = text(raw.SHORT, key:upper()),
		jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
		onDuty = raw.ON_DUTY == true,
		account = word(raw.ACCOUNT),
		capabilities = capabilities,
		-- A service with ENCLAVES rows acts only inside a surveyed one; with none
		-- surveyed it acts nowhere. A service with no ENCLAVES key acts anywhere.
		zoned = enclaveRows > 0,
		enclaves = enclaves,
		blipSprite = text(blip.SPRITE, globals.blipSprite),
		blipIcon = Access.Icon(blip.ICON) or globals.blipIcon,
		blipSize = whole(blip.SIZE, 16, 128, globals.blipSize),
		blipColor = Access.Color(blip.COLOR) or globals.blipColor,
		dispatch = {
			enabled = dispatch.ENABLED ~= false,
			minGrade = whole(dispatch.MIN_GRADE, 0, 100, 0),
			responders = whole(dispatch.RESPONDERS, 1, 16, 2),
			ttlMs = whole(dispatch.CALL_TTL_S, 10, 86400, 900) * 1000,
			all = all,
			receives = receives,
		},
	}
end

local function station(key, raw, services)
	if type(raw) ~= 'table' then return nil end
	local allowed = {}
	for _, name in ipairs(type(raw.SERVICES) == 'table' and raw.SERVICES or {}) do
		if services[name] ~= nil then allowed[name] = true end
	end
	local cells = {}
	for index, row in ipairs(type(raw.CELLS) == 'table' and raw.CELLS or {}) do
		local spot = point(row)
		if spot ~= nil then
			spot.index = index
			cells[#cells + 1] = spot
		end
	end
	local evidence = point(raw.EVIDENCE)
	if evidence ~= nil then
		evidence.slots = whole(raw.EVIDENCE.SLOTS, 1, 200, 100)
		evidence.maxWeight = whole(raw.EVIDENCE.MAX_WEIGHT, 0, 4000000000, 500000)
	end
	return {
		key = key,
		label = text(raw.LABEL, key),
		services = allowed,
		center = point(raw, 2, 500, 40),
		desk = point(raw.DESK),
		evidence = evidence,
		-- The stash name confiscated items go into: one per station, never reused.
		stash = ('police_evidence_%s'):format(key),
		cells = cells,
		release = point(raw.RELEASE),
	}
end

--- The whole config, normalised: globals, crimes, services and stations.
--- `pause`, when given, is called between the pieces: the client passes a
--- yield, because the whole build is more than one resume may cost there.
-- @author dop42
-- @param raw table|nil OPX.Config.MODULES.police
-- @param pause function|nil
-- @return table
function Access.Settings(raw, pause)
	pause = type(pause) == 'function' and pause or function() end
	raw = type(raw) == 'table' and raw or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local emergency = type(raw.EMERGENCY) == 'table' and raw.EMERGENCY or {}
	local down = type(raw.OFFICER_DOWN) == 'table' and raw.OFFICER_DOWN or {}
	local cuffs = type(raw.CUFFS) == 'table' and raw.CUFFS or {}
	local escort = type(raw.ESCORT) == 'table' and raw.ESCORT or {}
	local fines = type(raw.FINES) == 'table' and raw.FINES or {}
	local jail = type(raw.JAIL) == 'table' and raw.JAIL or {}
	local impound = type(raw.IMPOUND) == 'table' and raw.IMPOUND or {}
	local crimeTable, crimeOrder = crimes(raw.CRIMES)
	pause()
	local settings = {
		membership = raw.MEMBERSHIP == 'any' and 'any' or 'primary',
		requestMs = whole(raw.REQUEST_MS, 0, 60000, 750),
		scanMs = whole(raw.SCAN_MS, 250, 60000, 2000),
		reach = bounded(raw.REACH, 0.5, 20, 2.5),
		alertMs = whole(raw.ALERT_MS, 1000, 60000, 8000),
		metadataKey = text(raw.METADATA_KEY, 'police'),
		blipSprite = text(blip.SPRITE, 'objective'),
		blipIcon = Access.Icon(blip.ICON),
		blipSize = whole(blip.SIZE, 16, 128, 48),
		blipColor = Access.Color(blip.COLOR),
		blipWalls = blip.WALLS ~= false,
		emergency = {
			enabled = emergency.ENABLED ~= false,
			command = word(emergency.COMMAND) or '911',
			crime = word(emergency.CRIME) or 'emergency',
			cooldownMs = whole(emergency.COOLDOWN_S, 0, 3600, 60) * 1000,
			maxText = whole(emergency.MAX_TEXT, 16, 512, 160),
		},
		officerDown = { enabled = down.ENABLED ~= false, crime = word(down.CRIME) or 'officer_down' },
		cuffs = {
			item = word(cuffs.ITEM),
			label = text(cuffs.LABEL, 'Handcuffs'),
			description = text(cuffs.DESCRIPTION, nil),
			weight = whole(cuffs.WEIGHT, 0, 100000, 300),
			model = type(cuffs.MODEL) == 'string' and cuffs.MODEL:match('^[%w_%.]+$') and cuffs.MODEL or 'crate.small',
			consume = cuffs.CONSUME == true,
			durationMs = whole(cuffs.DURATION_MS, 250, 60000, 3000),
			breakReach = bounded(cuffs.BREAK_REACH, 0.5, 10, 2.0),
		},
		escort = {
			durationMs = whole(escort.DURATION_S, 5, 600, 300) * 1000,
			startDistance = bounded(escort.START_DISTANCE, 0.25, 10, 2.5),
			breakDistance = bounded(escort.BREAK_DISTANCE, 0.25, 20, 5.0),
		},
		fines = {
			moneyType = moneyType(fines.MONEY_TYPE, 'BANK'),
			max = whole(fines.MAX, 0, 100000000, 0),
			cutPercent = bounded(fines.OFFICER_CUT_PERCENT, 0, 100, 0),
			cutMoneyType = moneyType(fines.CUT_MONEY_TYPE, 'BANK'),
		},
		jail = {
			maxMinutes = whole(jail.MAX_MINUTES, 1, 100000, 120),
			leash = bounded(jail.LEASH, 1, 100, 6.0),
			offlineServes = jail.OFFLINE_SERVES ~= false,
		},
		impound = {
			durationMs = whole(impound.DURATION_MS, 250, 120000, 8000),
			reach = bounded(impound.REACH, 1, 30, 6.0),
			garage = type(impound.GARAGE) == 'string' and impound.GARAGE:match('^[%w_%-%.:]+$')
				and #impound.GARAGE <= 48 and impound.GARAGE or nil,
			removeUnowned = impound.REMOVE_UNOWNED == true,
		},
		crimes = crimeTable,
		crimeOrder = crimeOrder,
		services = {},
		serviceOrder = {},
		stations = {},
		stationOrder = {},
	}
	if settings.escort.breakDistance < settings.escort.startDistance then
		settings.escort.breakDistance = settings.escort.startDistance
	end
	for key, row in pairs(type(raw.SERVICES) == 'table' and raw.SERVICES or {}) do
		local read = word(key) and service(key, row, settings) or nil
		if read ~= nil then
			settings.services[key] = read
			settings.serviceOrder[#settings.serviceOrder + 1] = key
		end
		pause()
	end
	table.sort(settings.serviceOrder)
	for key, row in pairs(type(raw.STATIONS) == 'table' and raw.STATIONS or {}) do
		local read = word(key) and station(key, row, settings.services) or nil
		if read ~= nil then
			settings.stations[key] = read
			settings.stationOrder[#settings.stationOrder + 1] = key
		end
		pause()
	end
	table.sort(settings.stationOrder)
	return settings
end

--- The JOBS block a gate checks for one action: the service's own jobs, each
--- floor raised to `minGrade` when the action asks for more than the service does.
-- @author dop42
-- @param svc table a normalised service
-- @param minGrade integer|nil
-- @return table|nil
function Access.Jobs(svc, minGrade)
	if type(svc) ~= 'table' or type(svc.jobs) ~= 'table' then return nil end
	local floor = math.tointeger(minGrade) or 0
	local out = {}
	for name, grade in pairs(svc.jobs) do
		out[name] = math.max(finiteNumber(grade) or 0, floor)
	end
	return out
end

--- Whether a position lies where a service has authority. A service with no
--- ENCLAVES acts anywhere; a zoned one only inside a surveyed sphere.
-- @author dop42
-- @param svc table
-- @param at table|nil { x, y, z }
-- @return boolean
function Access.InJurisdiction(svc, at)
	if type(svc) ~= 'table' then return false end
	if not svc.zoned then return true end
	if type(at) ~= 'table' then return false end
	for _, zone in ipairs(svc.enclaves) do
		local dx, dy, dz = at.x - zone.x, at.y - zone.y, at.z - zone.z
		if dx * dx + dy * dy + dz * dz <= zone.radius * zone.radius then return true end
	end
	return false
end

--- Whether a service is alerted to one crime code.
-- @author dop42
function Access.Receives(svc, crime)
	if type(svc) ~= 'table' or not svc.dispatch.enabled then return false end
	return svc.dispatch.all or svc.dispatch.receives[crime] == true
end

--- Whether a service names one of the given job names among its JOBS.
-- @author dop42
-- @param svc table
-- @param jobs table list of job names
-- @return boolean
function Access.HasAnyJob(svc, jobs)
	if type(svc) ~= 'table' or type(svc.jobs) ~= 'table' or type(jobs) ~= 'table' then return false end
	for _, name in ipairs(jobs) do
		if type(name) == 'string' and svc.jobs[name] ~= nil then return true end
	end
	return false
end

--- The most one fine for one crime may be, in whole units: the crime's
--- FINE_MAX, capped by FINES.MAX. 0 for a code that carries no fine.
-- @author dop42
-- @param settings table
-- @param code string
-- @return integer
function Access.FineCeiling(settings, code)
	local crime = type(settings) == 'table' and settings.crimes[code] or nil
	if crime == nil then return 0 end
	local ceiling = math.max(crime.fine, crime.fineMax)
	if settings.fines.max > 0 then ceiling = math.min(ceiling, settings.fines.max) end
	return ceiling
end

--- How a fine of `amount` against a balance of `balance` splits: what is paid
--- now, what is owed, and the officer's cut of what was paid.
-- @author dop42
-- @param amount integer
-- @param balance integer
-- @param cutPercent number 0..100
-- @return integer paid
-- @return integer owed
-- @return integer cut
function Access.SplitFine(amount, balance, cutPercent)
	amount = math.max(0, math.floor(finiteNumber(amount) or 0))
	balance = math.max(0, math.floor(finiteNumber(balance) or 0))
	local paid = math.min(amount, balance)
	local cut = math.floor(paid * math.max(0, math.min(100, finiteNumber(cutPercent) or 0)) / 100)
	return paid, amount - paid, cut
end

--- A sentence's length in whole minutes, bounded by JAIL.MAX_MINUTES; nil for
--- anything that is not a positive number.
-- @author dop42
function Access.Minutes(settings, value)
	local minutes = whole(value, 0, 100000, nil)
	if minutes == nil or minutes < 1 then return nil end
	return math.min(minutes, settings.jail.maxMinutes)
end

--- The seconds left on a stored sentence: 0 when served.
--- Two shapes, one per JAIL.OFFLINE_SERVES. On the wall clock a sentence is
--- `{ untilS }` and logging off serves it; on time served it is
--- `{ totalS, servedS }`, and only seconds spent online in the cell count.
-- @author dop42
-- @param record table|nil
-- @param nowS number
-- @return integer
function Access.Remaining(record, nowS)
	if type(record) ~= 'table' then return 0 end
	local total = finiteNumber(record.totalS)
	if record.untilS == nil and total ~= nil then
		return math.max(0, math.floor(total - (finiteNumber(record.servedS) or 0)))
	end
	local untilS, now = finiteNumber(record.untilS), finiteNumber(nowS)
	if untilS == nil or now == nil then return 0 end
	return math.max(0, math.floor(untilS - now))
end

--- The station a position is inside, among those a service may use, or nil.
-- @author dop42
-- @param settings table
-- @param svcKey string
-- @param at table|nil { x, y, z }
-- @return table|nil
function Access.StationAt(settings, svcKey, at)
	if type(at) ~= 'table' then return nil end
	for _, key in ipairs(settings.stationOrder) do
		local row = settings.stations[key]
		local center = row.center
		if center ~= nil and row.services[svcKey] and #row.cells > 0 then
			local dx, dy, dz = at.x - center.x, at.y - center.y, at.z - center.z
			if dx * dx + dy * dy + dz * dz <= center.radius * center.radius then return row end
		end
	end
	return nil
end

-- A list of points, counted: (blank, total).
local function blanks(rows)
	local blank, total = 0, 0
	for _, row in ipairs(type(rows) == 'table' and rows or {}) do
		total = total + 1
		if Access.IsPlaceholder(row) then blank = blank + 1 end
	end
	return blank, total
end

--- Every complaint the configuration earns, one line each, naming the entry.
-- @author dop42
-- @param raw table|nil
-- @return string[]
function Access.Problems(raw)
	local lines = {}
	raw = type(raw) == 'table' and raw or {}
	if type(raw.SERVICES) ~= 'table' or next(raw.SERVICES) == nil then
		lines[#lines + 1] = 'SERVICES is empty: nobody answers a crime'
		return lines
	end
	if raw.MEMBERSHIP ~= nil and raw.MEMBERSHIP ~= 'primary' and raw.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = "MEMBERSHIP must be 'primary' or 'any'"
	end
	local crimeCodes = type(raw.CRIMES) == 'table' and raw.CRIMES or {}
	for code, row in pairs(crimeCodes) do
		if not word(code) or type(row) ~= 'table' then
			lines[#lines + 1] = ('CRIMES %s: a code is letters, digits and underscores, and its row a table')
				:format(tostring(code))
		elseif row.FINE ~= nil and finiteNumber(row.FINE) == nil then
			lines[#lines + 1] = ('CRIMES %s: FINE must be a number'):format(code)
		end
	end
	local emergency = type(raw.EMERGENCY) == 'table' and raw.EMERGENCY or {}
	if emergency.ENABLED ~= false and emergency.CRIME ~= nil and crimeCodes[emergency.CRIME] == nil then
		lines[#lines + 1] = ('EMERGENCY.CRIME %s is not in CRIMES'):format(tostring(emergency.CRIME))
	end
	local down = type(raw.OFFICER_DOWN) == 'table' and raw.OFFICER_DOWN or {}
	if down.ENABLED ~= false and down.CRIME ~= nil and crimeCodes[down.CRIME] == nil then
		lines[#lines + 1] = ('OFFICER_DOWN.CRIME %s is not in CRIMES'):format(tostring(down.CRIME))
	end
	local cuffs = type(raw.CUFFS) == 'table' and raw.CUFFS or {}
	if not word(cuffs.ITEM) then
		lines[#lines + 1] = 'CUFFS.ITEM must be an item name: nobody can cuff'
	end
	for key, row in pairs(raw.SERVICES) do
		local name = tostring(key)
		if not word(key) then
			lines[#lines + 1] = name .. ': a service key is letters, digits and underscores'
		elseif type(row) ~= 'table' then
			lines[#lines + 1] = name .. ': every SERVICES entry must be a table'
		else
			if type(row.JOBS) ~= 'table' or next(row.JOBS) == nil then
				lines[#lines + 1] = name .. ': no JOBS, so nobody can work for this service'
			else
				OPX.JobGate.Problems(row.JOBS, name, lines)
			end
			local held = 0
			for cap, grade in pairs(type(row.CAPABILITIES) == 'table' and row.CAPABILITIES or {}) do
				if not CAPABILITIES[cap] then
					lines[#lines + 1] = ('%s: CAPABILITIES.%s is not a verb this module knows'):format(name,
						tostring(cap))
				elseif finiteNumber(grade) == nil then
					lines[#lines + 1] = ('%s: CAPABILITIES.%s must be a grade number'):format(name, cap)
				else
					held = held + 1
				end
			end
			if held == 0 then
				lines[#lines + 1] = name .. ': no CAPABILITIES, so its members can take calls and do nothing'
			end
			local dispatch = type(row.DISPATCH) == 'table' and row.DISPATCH or {}
			for _, code in ipairs(type(dispatch.RECEIVES) == 'table' and dispatch.RECEIVES or {}) do
				if code ~= '*' and crimeCodes[code] == nil then
					lines[#lines + 1] = ('%s: DISPATCH.RECEIVES names %s, which is not in CRIMES'):format(name,
						tostring(code))
				end
			end
			if row.ENCLAVES ~= nil then
				local blank, total = blanks(row.ENCLAVES)
				if total == 0 or blank == total then
					lines[#lines + 1] = ('%s: no ENCLAVES surveyed -- a zoned service acts NOWHERE until one ' ..
						'is. Stand in the enclave and run /opx.police.capture enclave %s'):format(name, name)
				elseif blank > 0 then
					lines[#lines + 1] = ('%s: %d of %d ENCLAVES ARE STILL THE PLACEHOLDER 0,0,0 -- they are ' ..
						'disabled'):format(name, blank, total)
				end
			end
		end
	end
	for key, row in pairs(type(raw.STATIONS) == 'table' and raw.STATIONS or {}) do
		local name = 'station ' .. tostring(key)
		if not word(key) or type(row) ~= 'table' then
			lines[#lines + 1] = name .. ': a station key is a word and its row a table'
		else
			for _, svc in ipairs(type(row.SERVICES) == 'table' and row.SERVICES or {}) do
				if type(raw.SERVICES[svc]) ~= 'table' then
					lines[#lines + 1] = ('%s: SERVICES names %s, which is not a service'):format(name, tostring(svc))
				end
			end
			if Access.IsPlaceholder(row) then
				lines[#lines + 1] = name .. ': IS STILL THE PLACEHOLDER 0,0,0 -- nobody can be jailed there. ' ..
					'Stand in the building and run /opx.police.capture station ' .. tostring(key)
			end
			for _, part in ipairs({ 'DESK', 'EVIDENCE', 'RELEASE' }) do
				if type(row[part]) ~= 'table' or Access.IsPlaceholder(row[part]) then
					lines[#lines + 1] = ('%s: %s IS STILL THE PLACEHOLDER 0,0,0 -- it is disabled'):format(name, part)
				end
			end
			local blank, total = blanks(row.CELLS)
			if total == 0 then
				lines[#lines + 1] = name .. ': no CELLS, so nobody can be jailed there'
			elseif blank > 0 then
				lines[#lines + 1] = ('%s: %d of %d CELLS ARE STILL THE PLACEHOLDER 0,0,0 -- they are ' ..
					'disabled'):format(name, blank, total)
			end
		end
	end
	table.sort(lines)
	return lines
end
