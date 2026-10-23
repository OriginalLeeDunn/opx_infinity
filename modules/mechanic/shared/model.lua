--- The mechanic config, read once into a closed shape, and the arithmetic over it.
-- @author dop42
--
-- PURE. Not one host call in this file: everything is arithmetic over the
-- config table and over a vehicle's damage as the server read it, which is what
-- lets the tests drive every price off-platform and lets both halves read the
-- same shops without either trusting the other's copy.
--
-- A VALUE THE VALIDATOR REFUSES READS AS ITS SAFEST FLOOR, never as the most
-- permissive reading: a bay at the placeholder 0,0,0 is skipped, a fee that is
-- not a number is the default, a CUT_PCT outside 0..100 is clamped. `Problems`
-- says each of those once at boot.

local M = OPX.Modules.Get('mechanic')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

-- The scopes `Open77.vehicles.repair` takes (its card, op77.45).
Model.SCOPES = { glass = true, body = true, lights = true, tires = true, visual = true,
	mechanical = true, full = true }

local NO_CUSTOMER = { free = true, refuse = true }

local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.min(high, math.max(low, number))
end
Model.Bounded = bounded

local function whole(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.floor(math.min(high, math.max(low, number)))
end

local function text(value, fallback)
	return type(value) == 'string' and value ~= '' and value or fallback
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

-- An item name as the catalogue spells one, or nil.
local function itemName(value)
	return type(value) == 'string' and value:match('^[%l%d_]+$') and #value <= 48 and value or nil
end

-- An emote name, or nil for none.
local function animation(value)
	return type(value) == 'string' and value:match('^[%w_]+$') and value or nil
end

--- Whether a point is the unfilled blank a config ships with: all three axes
--- exactly zero. See `modules/hauling/shared/access.lua` for why exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Model.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- One surveyed point with a radius, or nil for a placeholder or a broken row.
local function point(row, index, low, high, fallback)
	if type(row) ~= 'table' or Model.IsPlaceholder(row) then return nil end
	local x, y, z = coordinate(row.X), coordinate(row.Y), coordinate(row.Z)
	if x == nil or y == nil or z == nil then return nil end
	return { index = index, label = text(row.LABEL, ''), x = x, y = y, z = z,
		radius = bounded(row.RADIUS, low, high, fallback) }
end

local function shop(key, raw)
	if type(raw) ~= 'table' then return nil end
	local bays = {}
	for index, row in ipairs(type(raw.BAYS) == 'table' and raw.BAYS or {}) do
		bays[#bays + 1] = point(row, index, 1, 30, 6)
	end
	local stash = point(raw.STASH, 1, 0.5, 10, 1.5)
	if stash ~= nil then
		stash.slots = whole(raw.STASH.SLOTS, 1, 200, 30)
		stash.maxWeight = whole(raw.STASH.MAX_WEIGHT, 1000, 10000000, 150000)
	end
	local garage = raw.RELEASE_GARAGE
	return {
		key = key,
		label = text(raw.LABEL, key),
		jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
		onDuty = raw.ON_DUTY == true,
		account = type(raw.ACCOUNT) == 'string' and raw.ACCOUNT:match('^[%w_]+$') and raw.ACCOUNT or nil,
		bays = bays,
		stash = stash,
		-- The storage key of the shop's stash. Never reuse one for somewhere else.
		stashKey = 'mechanic_' .. key,
		lot = point(raw.LOT, 1, 0.5, 10, 1.5),
		releaseFee = whole(raw.RELEASE_FEE, 0, 100000000, 0),
		releaseMoneyType = moneyType(raw.RELEASE_MONEY_TYPE, 'BANK'),
		releaseGarage = type(garage) == 'string' and garage:match('^[%w_%-%.:]+$') and #garage <= 48
			and garage or nil,
	}
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

-- A command name, or the fallback.
local function command(value, fallback)
	return type(value) == 'string' and value:match('^[%l%d_%.]+$') and #value <= 32 and value or fallback
end

--- The whole config, normalised: globals and every usable shop.
-- @author dop42
-- @param raw table|nil OPX.Config.MODULES.mechanic
-- @return table
function Model.Settings(raw)
	raw = type(raw) == 'table' and raw or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local dispatch = type(raw.DISPATCH) == 'table' and raw.DISPATCH or {}
	local items = type(raw.ITEMS) == 'table' and raw.ITEMS or {}
	local parts = type(items.PARTS) == 'table' and items.PARTS or {}
	local kitItem = type(items.KIT) == 'table' and items.KIT or {}
	local repair = type(raw.REPAIR) == 'table' and raw.REPAIR or {}
	local kit = type(raw.KIT) == 'table' and raw.KIT or {}
	local billing = type(raw.BILLING) == 'table' and raw.BILLING or {}
	local impound = type(raw.IMPOUND) == 'table' and raw.IMPOUND or {}
	local commands = type(raw.COMMANDS) == 'table' and raw.COMMANDS or {}

	local scopes = {}
	for _, scope in ipairs(type(kit.SCOPES) == 'table' and kit.SCOPES or {}) do
		if Model.SCOPES[scope] and scope ~= 'full' then scopes[#scopes + 1] = scope end
	end
	local towRecords = {}
	for _, record in ipairs(type(impound.TOW_RECORDS) == 'table' and impound.TOW_RECORDS or {}) do
		if type(record) == 'string' and record:match('^Vehicle%.[%w_]+$') then towRecords[record] = true end
	end

	local settings = {
		membership = raw.MEMBERSHIP == 'any' and 'any' or 'primary',
		requestMs = whole(raw.REQUEST_MS, 0, 60000, 750),
		scanMs = whole(raw.SCAN_MS, 250, 60000, 2000),
		reach = bounded(raw.REACH, 1, 20, 4.0),
		customerReach = bounded(raw.CUSTOMER_REACH, 1, 50, 12.0),
		alertMs = whole(raw.ALERT_MS, 1000, 60000, 8000),
		commands = {
			call = command(commands.CALL, 'mechanic'),
			tow = command(commands.TOW, 'tow'),
			board = command(commands.BOARD, 'mechboard'),
		},
		blipSprite = text(blip.SPRITE, 'objective'),
		blipIcon = Model.Icon(blip.ICON),
		blipSize = whole(blip.SIZE, 16, 128, 48),
		blipColor = Model.Color(blip.COLOR),
		blipWalls = blip.WALLS ~= false,
		dispatch = {
			enabled = dispatch.ENABLED ~= false,
			minGrade = whole(dispatch.MIN_GRADE, 0, 100, 0),
			responders = whole(dispatch.RESPONDERS, 1, 16, 1),
			ttlMs = whole(dispatch.CALL_TTL_S, 10, 86400, 600) * 1000,
			noteMax = whole(dispatch.NOTE_MAX, 0, 200, 80),
		},
		parts = {
			name = itemName(parts.NAME) or 'mech_parts',
			label = text(parts.LABEL, 'Vehicle parts'),
			description = text(parts.DESCRIPTION, ''),
			weight = whole(parts.WEIGHT, 0, 100000, 1500),
		},
		kitItem = {
			name = itemName(kitItem.NAME) or 'mech_repairkit',
			label = text(kitItem.LABEL, 'Roadside repair kit'),
			description = text(kitItem.DESCRIPTION, ''),
			weight = whole(kitItem.WEIGHT, 0, 100000, 2500),
		},
		repair = {
			minGrade = whole(repair.MIN_GRADE, 0, 100, 0),
			baseFee = whole(repair.BASE_FEE, 0, 10000000, 250),
			perPercent = bounded(repair.PER_PERCENT, 0, 100000, 12),
			percentPerPart = bounded(repair.PERCENT_PER_PART, 1, 100, 25),
			minParts = whole(repair.MIN_PARTS, 0, 100, 1),
			baseMs = whole(repair.BASE_MS, 250, 600000, 8000),
			perPercentMs = whole(repair.PER_PERCENT_MS, 0, 60000, 150),
			animation = animation(repair.ANIMATION),
		},
		kit = {
			enabled = kit.ENABLED ~= false,
			durationMs = whole(kit.DURATION_MS, 250, 600000, 12000),
			health = bounded(kit.HEALTH, 0.05, 1, 0.45),
			mechanicHealth = bounded(kit.MECHANIC_HEALTH, 0.05, 1, bounded(kit.HEALTH, 0.05, 1, 0.45)),
			scopes = scopes,
			animation = animation(kit.ANIMATION),
		},
		billing = {
			moneyType = moneyType(billing.MONEY_TYPE, 'BANK'),
			cutPct = whole(billing.CUT_PCT, 0, 100, 30),
			noCustomer = NO_CUSTOMER[billing.NO_CUSTOMER] and billing.NO_CUSTOMER or 'free',
		},
		impound = {
			enabled = impound.ENABLED ~= false,
			jobs = type(impound.JOBS) == 'table' and impound.JOBS or nil,
			onDuty = impound.ON_DUTY == true,
			durationMs = whole(impound.DURATION_MS, 250, 600000, 15000),
			animation = animation(impound.ANIMATION),
			towRecords = towRecords,
			towReach = bounded(impound.TOW_REACH, 1, 100, 15),
			pay = whole(impound.PAY, 0, 10000000, 0),
			payMoneyType = moneyType(impound.PAY_MONEY_TYPE, 'BANK'),
		},
		shops = {},
		shopOrder = {},
	}
	for key, row in pairs(type(raw.SHOPS) == 'table' and raw.SHOPS or {}) do
		local read = type(key) == 'string' and key:match('^[%w_]+$') and shop(key, row) or nil
		if read ~= nil then
			settings.shops[key] = read
			settings.shopOrder[#settings.shopOrder + 1] = key
		end
	end
	table.sort(settings.shopOrder)
	return settings
end

--- The JOBS block a gate checks for one action: the shop's own jobs, each floor
--- raised to `minGrade` when the action asks for more than the shop does.
-- @author dop42
-- @param jobs table|nil
-- @param minGrade integer|nil
-- @return table|nil
function Model.Jobs(jobs, minGrade)
	if type(jobs) ~= 'table' then return nil end
	local floor = math.tointeger(minGrade) or 0
	local out = {}
	for name, grade in pairs(jobs) do
		local own = finiteNumber(grade)
		out[name] = own ~= nil and math.max(own, floor) or false
	end
	return out
end

--- How broken a vehicle is, in whole percent 0..100: the worse of its lost
--- health and its average crushed body cell, with a floor of 5 when only glass,
--- lights, tyres or detached panels are broken (a flat costs something to fix).
-- @author dop42
-- @param health number|nil the normalised pool 0..1
-- @param damage table|nil `Open77.vehicles.getDamage` { body = {30 x 0..1}, glass, lights, tires, detachedParts }
-- @return integer
function Model.Missing(health, damage)
	local lost = 0
	local pool = finiteNumber(health)
	if pool ~= nil then lost = 1 - math.min(1, math.max(0, pool)) end
	local crushed, masks = 0, false
	if type(damage) == 'table' then
		local body = type(damage.body) == 'table' and damage.body or {}
		local sum, cells = 0, 0
		for index = 1, 30 do
			local cell = finiteNumber(body[index])
			if cell ~= nil then
				sum, cells = sum + math.min(1, math.max(0, cell)), cells + 1
			end
		end
		if cells > 0 then crushed = sum / cells end
		for _, field in ipairs({ 'glass', 'lights', 'tires', 'detachedParts' }) do
			local mask = math.tointeger(finiteNumber(damage[field]))
			if mask ~= nil and mask ~= 0 then masks = true end
		end
	end
	local percent = math.floor(math.max(lost, crushed) * 100 + 0.5)
	if percent < 5 and masks then percent = 5 end
	return math.min(100, math.max(0, percent))
end

--- A bounded readout of canonical damage and openings, without vehicle ownership.
function Model.Diagnostic(health, damage, snapshot)
	local function bits(value, width)
		local mask = math.tointeger(finiteNumber(value))
		if mask == nil then return nil end
		local count = 0
		for bit = 0, width - 1 do
			if mask & (1 << bit) ~= 0 then count = count + 1 end
		end
		return count
	end
	damage = type(damage) == 'table' and damage or {}
	snapshot = type(snapshot) == 'table' and snapshot or {}
	local pool = finiteNumber(health)
	return {
		health = pool ~= nil and math.floor(math.min(1, math.max(0, pool)) * 100 + 0.5) or nil,
		missing = Model.Missing(health, damage),
		tires = bits(damage.tires, 4), glass = bits(damage.glass, 32),
		lights = bits(damage.lights, 32), detached = bits(damage.detachedParts, 32),
		doors = bits(snapshot.doors, 6), windows = bits(snapshot.windows, 4),
	}
end

--- What a workshop repair of `missing` percent costs: fee, parts and length.
-- @author dop42
-- @param settings table normalised
-- @param missing integer 0..100
-- @param maxMs integer|nil the longest bar the progress module allows
-- @return table { fee, parts, durationMs }
function Model.Quote(settings, missing, maxMs)
	local repair = settings.repair
	local pct = math.max(0, math.min(100, math.tointeger(missing) or 0))
	local parts = math.max(repair.minParts, math.ceil(pct / repair.percentPerPart))
	local duration = repair.baseMs + repair.perPercentMs * pct
	local cap = math.tointeger(maxMs)
	if cap ~= nil and cap > 0 and duration > cap then duration = cap end
	return {
		fee = math.floor(repair.baseFee + repair.perPercent * pct + 0.5),
		parts = parts,
		durationMs = math.max(250, math.floor(duration)),
	}
end

--- How a paid bill is split: the mechanic's cut and the shop's share.
-- @author dop42
-- @param amount integer
-- @param cutPct integer 0..100
-- @return integer cut, integer share
function Model.Split(amount, cutPct)
	local total = math.max(0, math.tointeger(amount) or 0)
	local cut = math.floor(total * math.max(0, math.min(100, cutPct or 0)) / 100)
	return cut, total - cut
end

--- The health a roadside kit leaves a vehicle at: never lower than it was.
-- @author dop42
-- @param settings table
-- @param current number|nil
-- @param mechanic boolean whether the worker is a mechanic on duty
-- @return number
function Model.KitHealth(settings, current, mechanic)
	local target = mechanic and settings.kit.mechanicHealth or settings.kit.health
	local now = finiteNumber(current) or 0
	return math.max(math.min(1, math.max(0, now)), target)
end

--- A caller's note, trimmed to the configured length, or nil.
-- @author dop42
function Model.Note(settings, value)
	if type(value) ~= 'string' or settings.dispatch.noteMax <= 0 then return nil end
	local clean = OPX.Text.Clean(value, settings.dispatch.noteMax)
	return clean ~= nil and clean ~= '' and clean or nil
end

--- Every complaint the configuration earns, one line each, naming the entry.
-- @author dop42
-- @param raw table|nil
-- @return string[]
function Model.Problems(raw)
	local lines = {}
	raw = type(raw) == 'table' and raw or {}
	if raw.MEMBERSHIP ~= nil and raw.MEMBERSHIP ~= 'primary' and raw.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = "MEMBERSHIP must be 'primary' or 'any'"
	end
	local billing = type(raw.BILLING) == 'table' and raw.BILLING or {}
	if billing.NO_CUSTOMER ~= nil and not NO_CUSTOMER[billing.NO_CUSTOMER] then
		lines[#lines + 1] = "BILLING.NO_CUSTOMER must be 'free' or 'refuse'"
	end
	local cut = billing.CUT_PCT
	if cut ~= nil and (finiteNumber(cut) == nil or cut < 0 or cut > 100) then
		lines[#lines + 1] = 'BILLING.CUT_PCT must be a percentage 0..100'
	end
	local kit = type(raw.KIT) == 'table' and raw.KIT or {}
	for _, scope in ipairs(type(kit.SCOPES) == 'table' and kit.SCOPES or {}) do
		if not Model.SCOPES[scope] or scope == 'full' then
			lines[#lines + 1] = ('KIT.SCOPES: %s is not a repair scope (glass, body, lights, tires, ' ..
				'visual, mechanical); a kit never does a full repair'):format(tostring(scope))
		end
	end
	local items = type(raw.ITEMS) == 'table' and raw.ITEMS or {}
	for _, which in ipairs({ 'PARTS', 'KIT' }) do
		local row = items[which]
		if row ~= nil and (type(row) ~= 'table' or itemName(row.NAME) == nil) then
			lines[#lines + 1] = ('ITEMS.%s.NAME must be lower-case letters, digits and underscores'):format(which)
		end
	end
	local impound = type(raw.IMPOUND) == 'table' and raw.IMPOUND or {}
	if impound.ENABLED ~= false then
		if type(impound.JOBS) ~= 'table' or next(impound.JOBS) == nil then
			lines[#lines + 1] = 'IMPOUND has no JOBS: nobody can tow'
		else
			OPX.JobGate.Problems(impound.JOBS, 'IMPOUND', lines)
		end
		for _, record in ipairs(type(impound.TOW_RECORDS) == 'table' and impound.TOW_RECORDS or {}) do
			if type(record) ~= 'string' or not record:match('^Vehicle%.[%w_]+$') then
				lines[#lines + 1] = ('IMPOUND.TOW_RECORDS: %s is not a Vehicle.* record'):format(tostring(record))
			end
		end
	end
	if type(raw.SHOPS) ~= 'table' or next(raw.SHOPS) == nil then
		lines[#lines + 1] = 'SHOPS is empty: nobody can work as a mechanic'
		table.sort(lines)
		return lines
	end
	for key, row in pairs(raw.SHOPS) do
		local name = tostring(key)
		if type(key) ~= 'string' or not key:match('^[%w_]+$') then
			lines[#lines + 1] = name .. ': a shop key is letters, digits and underscores'
		elseif type(row) ~= 'table' then
			lines[#lines + 1] = name .. ': every SHOPS entry must be a table'
		else
			if type(row.JOBS) ~= 'table' or next(row.JOBS) == nil then
				lines[#lines + 1] = name .. ': no JOBS, so nobody can work at this shop'
			else
				OPX.JobGate.Problems(row.JOBS, name, lines)
			end
			local blanks, total = 0, 0
			for _, bay in ipairs(type(row.BAYS) == 'table' and row.BAYS or {}) do
				total = total + 1
				if Model.IsPlaceholder(bay) then blanks = blanks + 1 end
			end
			if total == 0 then
				lines[#lines + 1] = name .. ': no BAYS, so no workshop repair here'
			elseif blanks > 0 then
				lines[#lines + 1] = ('%s: %d of %d BAYS ARE STILL THE PLACEHOLDER 0,0,0 -- they are ' ..
					'disabled. Stand on each spot in game and paste your position in'):format(name, blanks, total)
			end
			for _, which in ipairs({ 'STASH', 'LOT' }) do
				if type(row[which]) == 'table' and Model.IsPlaceholder(row[which]) then
					lines[#lines + 1] = ('%s: %s IS STILL THE PLACEHOLDER 0,0,0 -- it is disabled')
						:format(name, which)
				end
			end
			if row.RELEASE_FEE ~= nil and finiteNumber(row.RELEASE_FEE) == nil then
				lines[#lines + 1] = name .. ': RELEASE_FEE must be a number'
			end
		end
	end
	table.sort(lines)
	return lines
end

--- Only the lines that are a MISTAKE, not a spot still to survey: what the boot
--- warns about. The placeholders are said once, at info.
-- @author dop42
-- @param lines string[]
-- @return string[] mistakes, string[] unsurveyed
function Model.Partition(lines)
	local mistakes, unsurveyed = {}, {}
	for _, line in ipairs(lines) do
		if line:find('PLACEHOLDER', 1, true) then
			unsurveyed[#unsurveyed + 1] = line
		else
			mistakes[#mistakes + 1] = line
		end
	end
	return mistakes, unsurveyed
end
