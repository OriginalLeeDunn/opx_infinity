--- The medical config, read once into a closed shape, and the arithmetic over it.
-- @author dop42
--
-- PURE. Not one host call in this file: everything is arithmetic over the config
-- table, which is what lets the tests drive every rule off-platform and lets both
-- halves read the same services without either trusting the other's copy.
--
-- A VALUE THE VALIDATOR REFUSES READS AS ITS SAFEST FLOOR, never as the most
-- permissive reading: a treatment with no usable DURATION_MS is dropped, a FEE
-- that is not a whole number is 0, a desk at the placeholder 0,0,0 is skipped.
-- `Problems` says each of those once at boot, so a bad config is a line in the
-- journal rather than a refusal nobody can explain three hours later.

local M = OPX.Modules.Get('medical')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local ANSWERS = { subscribers = true, anyone = true }
local UNPAID = { debt = true, refuse = true, free = true }

-- Clamps a value into low..high, or answers the fallback when it is not finite.
local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil then return fallback end
	return math.min(high, math.max(low, number))
end
Model.Bounded = bounded

-- A whole number in low..high, or the fallback.
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

--- Whether a point is the unfilled blank a config ships with: all three axes
--- exactly zero. See `modules/hauling/shared/access.lua` for why exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Model.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- ITEMS as a sorted list of { name, count }, dropping what is not a name -> count.
local function items(value)
	local out = {}
	if type(value) ~= 'table' then return out end
	for name, count in pairs(value) do
		local n = whole(count, 0, 1000, nil)
		if type(name) == 'string' and name ~= '' and n ~= nil and n > 0 then
			out[#out + 1] = { name = name, count = n }
		end
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

local function treatment(key, raw)
	if type(raw) ~= 'table' then return nil end
	local kind = raw.KIND
	if kind ~= M.Kind.REVIVE and kind ~= M.Kind.HEAL then return nil end
	local duration = whole(raw.DURATION_MS, 250, 600000, nil)
	if duration == nil then return nil end
	return {
		key = key,
		kind = kind,
		label = text(raw.LABEL, 'medical.treat.' .. kind),
		minGrade = whole(raw.MIN_GRADE, 0, 100, 0),
		durationMs = duration,
		items = items(raw.ITEMS),
		-- A revive's share of the pool, and a heal's share added to it.
		health = bounded(raw.HEALTH, 0.01, 1.0, 0.35),
		graceMs = whole(raw.GRACE_MS, 0, 60000, 3000),
		heal = bounded(raw.HEAL, 0.01, 1.0, 0.25),
		consent = raw.CONSENT ~= false,
		fee = whole(raw.FEE, 0, 10000000, 0),
		pay = whole(raw.PAY, 0, 10000000, 0),
		animation = type(raw.ANIMATION) == 'string' and raw.ANIMATION:match('^[%w_]+$')
			and raw.ANIMATION or nil,
	}
end

local function tiers(raw)
	local out = {}
	if type(raw) ~= 'table' then return out end
	for key, row in pairs(raw) do
		local price = type(row) == 'table' and whole(row.PRICE, 0, 100000000, nil) or nil
		local days = type(row) == 'table' and bounded(row.DAYS, 0.01, 3650, nil) or nil
		if type(key) == 'string' and price ~= nil and days ~= nil then
			out[key] = {
				key = key,
				label = text(row.LABEL, key),
				price = price,
				seconds = math.floor(days * 86400),
				priority = whole(row.PRIORITY, 0, 100, 0),
				autoAlert = row.AUTO_ALERT == true,
				discount = bounded(row.DISCOUNT, 0, 1, 0),
			}
		end
	end
	return out
end

local function desks(raw)
	local out = {}
	if type(raw) ~= 'table' then return out end
	for index, row in ipairs(raw) do
		if type(row) == 'table' and not Model.IsPlaceholder(row) then
			local x, y, z = coordinate(row.X), coordinate(row.Y), coordinate(row.Z)
			if x and y and z then
				out[#out + 1] = { index = index, label = text(row.LABEL, ''), x = x, y = y, z = z,
					radius = bounded(row.RADIUS, 0.5, 10, 1.5) }
			end
		end
	end
	return out
end

local function service(key, raw, globals)
	if type(raw) ~= 'table' then return nil end
	local dispatch = type(raw.DISPATCH) == 'table' and raw.DISPATCH or {}
	local subscription = type(raw.SUBSCRIPTION) == 'table' and raw.SUBSCRIPTION or {}
	local billing = type(raw.BILLING) == 'table' and raw.BILLING or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}

	local treatments, order = {}, {}
	for name, row in pairs(type(raw.TREATMENTS) == 'table' and raw.TREATMENTS or {}) do
		local read = type(name) == 'string' and treatment(name, row) or nil
		if read ~= nil then
			treatments[name] = read
			order[#order + 1] = name
		end
	end
	table.sort(order)

	local subscriptionOn = subscription.ENABLED == true
	return {
		key = key,
		label = text(raw.LABEL, key),
		short = text(raw.SHORT, key:upper()),
		jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
		onDuty = raw.ON_DUTY == true,
		blipSprite = text(blip.SPRITE, globals.blipSprite),
		dispatch = {
			enabled = dispatch.ENABLED ~= false,
			answers = ANSWERS[dispatch.ANSWERS] and dispatch.ANSWERS or 'anyone',
			offContract = dispatch.OFF_CONTRACT == true,
			minGrade = whole(dispatch.MIN_GRADE, 0, 100, 0),
			responders = whole(dispatch.RESPONDERS, 1, 16, 1),
			ttlMs = whole(dispatch.CALL_TTL_S, 10, 86400, 600) * 1000,
		},
		subscription = {
			enabled = subscriptionOn,
			moneyType = moneyType(subscription.MONEY_TYPE, 'BANK'),
			tiers = subscriptionOn and tiers(subscription.TIERS) or {},
			desks = subscriptionOn and desks(subscription.DESKS) or {},
		},
		treatments = treatments,
		treatmentOrder = order,
		billing = {
			enabled = billing.ENABLED ~= false,
			moneyType = moneyType(billing.MONEY_TYPE, 'BANK'),
			offContractMultiplier = bounded(billing.OFF_CONTRACT_MULTIPLIER, 0, 100, 1),
			onUnpaid = UNPAID[billing.ON_UNPAID] and billing.ON_UNPAID or 'debt',
			payMoneyType = moneyType(billing.PAY_MONEY_TYPE, 'BANK'),
		},
	}
end

--- The whole config, normalised: globals and every usable service.
-- @author dop42
-- @param raw table|nil OPX.Config.MODULES.medical
-- @return table
function Model.Settings(raw)
	raw = type(raw) == 'table' and raw or {}
	local blip = type(raw.BLIP) == 'table' and raw.BLIP or {}
	local settings = {
		membership = raw.MEMBERSHIP == 'any' and 'any' or 'primary',
		requestMs = whole(raw.REQUEST_MS, 0, 60000, 750),
		scanMs = whole(raw.SCAN_MS, 250, 60000, 2000),
		reach = bounded(raw.REACH, 0.5, 20, 3.0),
		alertMs = whole(raw.ALERT_MS, 1000, 60000, 8000),
		metadataKey = text(raw.METADATA_KEY, 'medical'),
		blipSprite = text(blip.SPRITE, 'objective'),
		blipWalls = blip.WALLS ~= false,
		services = {},
		serviceOrder = {},
	}
	for key, row in pairs(type(raw.SERVICES) == 'table' and raw.SERVICES or {}) do
		local read = type(key) == 'string' and key:match('^[%w_]+$') and service(key, row, settings) or nil
		if read ~= nil then
			settings.services[key] = read
			settings.serviceOrder[#settings.serviceOrder + 1] = key
		end
	end
	table.sort(settings.serviceOrder)
	return settings
end

--- The JOBS block a gate checks for one action: the service's own jobs, each
--- floor raised to `minGrade` when the action asks for more than the service does.
-- @author dop42
-- @param svc table a normalised service
-- @param minGrade integer|nil
-- @return table|nil
function Model.Jobs(svc, minGrade)
	if type(svc) ~= 'table' or type(svc.jobs) ~= 'table' then return nil end
	local floor = math.tointeger(minGrade) or 0
	local out = {}
	for name, grade in pairs(svc.jobs) do
		local own = finiteNumber(grade) or 0
		out[name] = math.max(own, floor)
	end
	return out
end

--- The subscription tier a stored record holds right now, or nil.
-- @author dop42
-- @param svc table a normalised service
-- @param record table|nil { tier, expiresAt } from character metadata
-- @param nowS number wall-clock seconds
-- @return table|nil the tier
function Model.ActiveTier(svc, record, nowS)
	if type(svc) ~= 'table' or not svc.subscription.enabled then return nil end
	if type(record) ~= 'table' or type(record.tier) ~= 'string' then return nil end
	local expires = finiteNumber(record.expiresAt)
	if expires == nil or finiteNumber(nowS) == nil or expires <= nowS then return nil end
	return svc.subscription.tiers[record.tier]
end

--- Whether a service opens a call for one patient, and on what footing.
--- `reason` is a M.Reason; `tier` the patient's active tier with this service.
-- @author dop42
-- @param svc table
-- @param tier table|nil
-- @param reason string
-- @return boolean open
-- @return boolean offContract
function Model.Answers(svc, tier, reason)
	if type(svc) ~= 'table' or not svc.dispatch.enabled then return false, false end
	if reason == M.Reason.BIOMONITOR then
		return tier ~= nil and tier.autoAlert == true, false
	end
	if svc.dispatch.answers == 'anyone' then return true, false end
	if tier ~= nil then return true, false end
	if svc.dispatch.offContract then return true, true end
	return false, false
end

--- What one treatment costs one patient, in whole units.
-- @author dop42
-- @param svc table
-- @param treat table a normalised treatment
-- @param tier table|nil the patient's active tier with this service
-- @param offContract boolean whether the service came outside a contract
-- @return integer
function Model.Fee(svc, treat, tier, offContract)
	if type(svc) ~= 'table' or type(treat) ~= 'table' or not svc.billing.enabled then return 0 end
	local fee = treat.fee
	if tier ~= nil then
		fee = fee * (1 - tier.discount)
	elseif offContract then
		fee = fee * svc.billing.offContractMultiplier
	end
	return math.max(0, math.floor(fee + 0.5))
end

--- Every complaint the configuration earns, one line each, naming the entry.
-- @author dop42
-- @param raw table|nil
-- @return string[]
function Model.Problems(raw)
	local lines = {}
	raw = type(raw) == 'table' and raw or {}
	if type(raw.SERVICES) ~= 'table' or next(raw.SERVICES) == nil then
		lines[#lines + 1] = 'SERVICES is empty: nobody answers a body on the ground'
		return lines
	end
	if raw.MEMBERSHIP ~= nil and raw.MEMBERSHIP ~= 'primary' and raw.MEMBERSHIP ~= 'any' then
		lines[#lines + 1] = "MEMBERSHIP must be 'primary' or 'any'"
	end
	for key, row in pairs(raw.SERVICES) do
		local name = tostring(key)
		if type(key) ~= 'string' or not key:match('^[%w_]+$') then
			lines[#lines + 1] = name .. ': a service key is letters, digits and underscores'
		elseif type(row) ~= 'table' then
			lines[#lines + 1] = name .. ': every SERVICES entry must be a table'
		else
			if type(row.JOBS) ~= 'table' or next(row.JOBS) == nil then
				lines[#lines + 1] = name .. ': no JOBS, so nobody can work for this service'
			else
				OPX.JobGate.Problems(row.JOBS, name, lines)
			end
			local dispatch = type(row.DISPATCH) == 'table' and row.DISPATCH or {}
			if dispatch.ANSWERS ~= nil and not ANSWERS[dispatch.ANSWERS] then
				lines[#lines + 1] = name .. ": DISPATCH.ANSWERS must be 'subscribers' or 'anyone'"
			end
			local subscription = type(row.SUBSCRIPTION) == 'table' and row.SUBSCRIPTION or {}
			if dispatch.ANSWERS == 'subscribers' and subscription.ENABLED ~= true
				and dispatch.OFF_CONTRACT ~= true then
				lines[#lines + 1] = name .. ': answers subscribers only, but sells no subscription ' ..
					'and takes no off-contract call: no call will ever open'
			end
			if subscription.ENABLED == true then
				local tierCount = 0
				for tierKey, tier in pairs(type(subscription.TIERS) == 'table' and subscription.TIERS or {}) do
					tierCount = tierCount + 1
					if type(tier) ~= 'table' or finiteNumber(tier.PRICE) == nil or finiteNumber(tier.DAYS) == nil then
						lines[#lines + 1] = ('%s tier %s: PRICE and DAYS must be numbers'):format(name, tostring(tierKey))
					end
				end
				if tierCount == 0 then
					lines[#lines + 1] = name .. ': SUBSCRIPTION is enabled with no TIERS'
				end
				local blanks, total = 0, 0
				for _, desk in ipairs(type(subscription.DESKS) == 'table' and subscription.DESKS or {}) do
					total = total + 1
					if Model.IsPlaceholder(desk) then blanks = blanks + 1 end
				end
				if total == 0 then
					lines[#lines + 1] = name .. ': SUBSCRIPTION is enabled with no DESKS, so nobody can sign'
				elseif blanks > 0 then
					lines[#lines + 1] = ('%s: %d of %d DESKS ARE STILL THE PLACEHOLDER 0,0,0 -- they are ' ..
						'disabled. Stand on each spot in game and paste your position in'):format(name, blanks, total)
				end
			end
			local count = 0
			for treatKey, treat in pairs(type(row.TREATMENTS) == 'table' and row.TREATMENTS or {}) do
				count = count + 1
				if treatment(treatKey, treat) == nil then
					lines[#lines + 1] = ('%s treatment %s: KIND must be revive or heal and DURATION_MS ' ..
						'a number of milliseconds; it is disabled'):format(name, tostring(treatKey))
				end
			end
			if count == 0 then
				lines[#lines + 1] = name .. ': no TREATMENTS, so its members can take calls and do nothing'
			end
			local billing = type(row.BILLING) == 'table' and row.BILLING or {}
			if billing.ON_UNPAID ~= nil and not UNPAID[billing.ON_UNPAID] then
				lines[#lines + 1] = name .. ": BILLING.ON_UNPAID must be 'debt', 'refuse' or 'free'"
			end
		end
	end
	table.sort(lines)
	return lines
end
