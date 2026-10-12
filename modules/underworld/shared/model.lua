--- Every decision the underworld makes that needs no world, no bag and no clock.
-- @author dop42
--
-- PURE, AND KEPT PURE ON PURPOSE (the rule `modules/crafting/shared/recipes.lua`
-- states): the config is read into entries and checked, a payout is rolled, a
-- till regrows, a price is counted, a position is blurred and a gate is asked
-- -- all from the arguments alone, so `tests/run.lua` drives every branch with
-- no server. SHARED because the client draws its spheres from the same entries
-- the server measures against; two readings of one config would drift.
--
-- NO `math.random` ANYWHERE. A payout, an alarm, a witness and a blurred point
-- are drawn from a hash of the operation's id and a salt (`Model.Roll`): the
-- same op always rolls the same, so a replayed or retried commit cannot reroll
-- a better payout, and a test can name the number it expects.

local M = OPX.Modules.Get('underworld')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite

--- Longest entry ID, and what one may be made of: it is a database value.
Model.ID_MAX = 32
Model.ID = '^[%w_]+$'

-- ── numbers ─────────────────────────────────────────────────────────────────

--- A whole number inside a range, or nil.
local function integer(value, low, high)
	local number = finiteNumber(value)
	if number == nil or number % 1 ~= 0 or number < low or number > high then return nil end
	return math.tointeger(number)
end
Model.Integer = integer

--- A number inside a range, or the fallback.
local function bounded(value, low, high, fallback)
	local number = finiteNumber(value)
	if number == nil or number < low or number > high then return fallback end
	return number
end
Model.Bounded = bounded

--- FNV-1a over a string, as a 32-bit unsigned integer.
-- @author dop42
-- @param text string
-- @return integer
function Model.Hash(text)
	local hash = 2166136261
	text = tostring(text)
	for index = 1, #text do
		hash = hash ~ text:byte(index)
		hash = (hash * 16777619) & 0xFFFFFFFF
	end
	return hash
end

--- A whole number in [low, high] drawn from a seed and a salt, never at random.
-- @author dop42
-- @param seed string the op id
-- @param salt string what is being rolled, so one op rolls several things
-- @param low integer
-- @param high integer
-- @return integer
function Model.Roll(seed, salt, low, high)
	low, high = math.floor(low), math.floor(high)
	if high <= low then return low end
	return low + Model.Hash(tostring(seed) .. '\1' .. tostring(salt)) % (high - low + 1)
end

--- Whether a chance in 0..1 comes up, drawn from a seed and a salt.
-- @author dop42
-- @param seed string
-- @param salt string
-- @param chance number
-- @return boolean
function Model.Chance(seed, salt, chance)
	chance = bounded(chance, 0, 1, 0)
	if chance <= 0 then return false end
	if chance >= 1 then return true end
	return Model.Roll(seed, salt, 0, 9999) < math.floor(chance * 10000 + 0.5)
end

--- A point somewhere within `radius` of the real one, on the ground plane.
-- @author dop42
-- @return number x
-- @return number y
function Model.Blur(x, y, radius, seed)
	radius = bounded(radius, 0, 10000, 0)
	if radius <= 0 then return x, y end
	local angle = Model.Roll(seed, 'blur.angle', 0, 3599) / 3600 * 2 * math.pi
	local reach = Model.Roll(seed, 'blur.reach', 0, 1000) / 1000 * radius
	return x + math.cos(angle) * reach, y + math.sin(angle) * reach
end

--- A till's charges after time passed: one back every `regrowMs`, up to `max`.
-- @author dop42
-- @param charges integer what it held at `lastAt`
-- @param max integer
-- @param regrowMs integer
-- @param lastAt number when `charges` was true (any clock, same as `now`)
-- @param now number
-- @return integer charges now
-- @return number the instant the next charge counts from
function Model.Regrow(charges, max, regrowMs, lastAt, now)
	charges = math.max(0, math.min(max, math.floor(finiteNumber(charges) or max)))
	lastAt = finiteNumber(lastAt) or now
	if charges >= max or regrowMs <= 0 then return max, now end
	if now <= lastAt then return charges, lastAt end
	local grown = math.floor((now - lastAt) / regrowMs)
	if grown <= 0 then return charges, lastAt end
	if charges + grown >= max then return max, now end
	return charges + grown, lastAt + grown * regrowMs
end

--- What is left under a rolling cap, pruning what fell out of the window.
-- @author dop42
-- @param list table { { at, amount } } oldest first; pruned in place
-- @param now number
-- @param windowMs number
-- @param cap number|nil nil or <= 0 is no cap
-- @return number left (math.huge with no cap)
function Model.CapLeft(list, now, windowMs, cap)
	local kept, used = {}, 0
	for index = 1, #list do
		local entry = list[index]
		if now - entry.at < windowMs then
			kept[#kept + 1] = entry
			used = used + entry.amount
		end
	end
	for index = #list, 1, -1 do list[index] = nil end
	for index = 1, #kept do list[index] = kept[index] end
	cap = finiteNumber(cap)
	if cap == nil or cap <= 0 then return math.huge end
	return math.max(0, cap - used)
end

--- Whether an hour of the game clock is inside `{ open, close }`, which may
--- wrap midnight. No hours, or no clock to read, is always open.
-- @author dop42
-- @param hour number|nil
-- @param hours table|nil
-- @return boolean
function Model.InHours(hour, hours)
	if type(hours) ~= 'table' or hour == nil then return true end
	local open, close = finiteNumber(hours[1]), finiteNumber(hours[2])
	if open == nil or close == nil or open == close then return true end
	if open < close then return hour >= open and hour < close end
	return hour >= open or hour < close
end

--- An addiction level after time passed.
-- @author dop42
-- @param level number
-- @param lastAt number seconds
-- @param now number seconds
-- @param perHour number
-- @return number
function Model.Decay(level, lastAt, now, perHour)
	level = math.max(0, finiteNumber(level) or 0)
	lastAt = finiteNumber(lastAt) or now
	if now <= lastAt or perHour <= 0 then return level end
	return math.max(0, level - (now - lastAt) / 3600 * perHour)
end

--- What a dealer charges for `count` of a stock line, in the method chosen.
-- @author dop42
-- @param price integer the dirty unit price
-- @param mod number the dealer's PRICE_MOD
-- @param count integer
-- @param clean boolean
-- @param premium number CLEAN_PREMIUM
-- @return integer
function Model.Price(price, mod, count, clean, premium)
	local unit = price * mod
	if clean then unit = unit * premium end
	return math.ceil(unit * count - 1e-9)
end

--- The clean money a batch of dirty eddies washes into.
-- @author dop42
-- @param amount integer
-- @param rate number 0..1
-- @return integer
function Model.Clean(amount, rate)
	return math.floor(amount * rate + 1e-9)
end

-- ── the config ──────────────────────────────────────────────────────────────

local function idOf(value)
	if type(value) ~= 'string' or #value < 1 or #value > Model.ID_MAX or not value:match(Model.ID) then
		return nil
	end
	return value
end

local function labelOf(value, fallback)
	if type(value) ~= 'string' then return fallback end
	local text = OPX.String.Trim(value)
	if text == '' then return fallback end
	return text:sub(1, 64)
end

--- A surveyed point, or nil and whether it is the 0, 0, 0 placeholder.
local function pointOf(row)
	local x, y, z = finiteNumber(row.X), finiteNumber(row.Y), finiteNumber(row.Z)
	if x == nil or y == nil or z == nil then return nil, false end
	if x == 0 and y == 0 and z == 0 then return nil, true end
	return { x = x, y = y, z = z, bucket = integer(row.BUCKET, 0, 2147483647) or 0 }
end
Model.PointOf = pointOf

--- An ALERT block over the defaults.
local function alertOf(raw, defaults)
	raw = type(raw) == 'table' and raw or {}
	defaults = type(defaults) == 'table' and defaults or {}
	local delay = type(raw.DELAY_MS) == 'table' and raw.DELAY_MS or defaults.DELAY_MS or { 5000, 20000 }
	local low = integer(delay[1], 0, 3600000) or 5000
	local high = integer(delay[2], 0, 3600000) or low
	return {
		chance = bounded(raw.CHANCE, 0, 1, bounded(defaults.CHANCE, 0, 1, 0.5)),
		delayMin = math.min(low, high), delayMax = math.max(low, high),
		witness = bounded(raw.WITNESS_CHANCE, 0, 1, bounded(defaults.WITNESS_CHANCE, 0, 1, 0.5)),
		blur = bounded(raw.BLUR_RADIUS, 0, 10000, bounded(defaults.BLUR_RADIUS, 0, 10000, 80)),
	}
end
Model.AlertOf = alertOf

--- The gang and job lists of an entry, checked.
local function groupsOf(row, where, problems)
	OPX.JobGate.Problems(row.JOBS, where, problems)
	OPX.JobGate.GangProblems(row.GANGS, where, problems)
	return type(row.JOBS) == 'table' and row.JOBS or nil, type(row.GANGS) == 'table' and row.GANGS or nil
end

--- Walks one list of entries, handing each well-formed one to `build`.
local function eachEntry(list, kind, out, problems, placeholders, build)
	if list == nil then return end
	if type(list) ~= 'table' then
		problems[#problems + 1] = kind .. ' must be a list of entries'
		return
	end
	for index, row in ipairs(list) do
		local where = ('%s #%d'):format(kind, index)
		if type(row) ~= 'table' then
			problems[#problems + 1] = where .. ': not a table'
		else
			local id = idOf(row.ID)
			if id == nil then
				problems[#problems + 1] = where .. (': ID must be 1 to %d letters, digits or _'):format(Model.ID_MAX)
			elseif out.byId[id] ~= nil then
				problems[#problems + 1] = ('%s: ID %s is used twice'):format(where, id)
			else
				where = kind .. ' ' .. id
				local entry, placeholder = build(row, id, where)
				if placeholder then
					placeholders[#placeholders + 1] = where
				elseif entry ~= nil then
					entry.id, entry.kind = id, kind
					out.byId[id] = entry
					out.list[#out.list + 1] = entry
				end
			end
		end
	end
end

--- Reads the whole config into entries.
-- @author dop42
--
-- An entry with a 0, 0, 0 position is a PLACEHOLDER (named, not loaded); an
-- entry with something wrong is REFUSED (its problem named, not loaded); a
-- problem in a field with a safe default is named and the default used.
-- ONE PART AT A TIME, when asked: `only = { stores = true }` reads that part
-- and leaves the others empty, so a client can spread the read over several
-- resumes (the whole config is ~5,000 instructions, past what one boot resume
-- may spend). The parts: dealers, stores, fronts, labs, drugs, street.
-- @param settings table OPX.Config.MODULES.underworld
-- @param only table|nil the parts to read; nil reads them all
-- @return table { dealers, stores, fronts, labs, drugs, street, dirty, reach }
-- @return string[] problems
-- @return string[] placeholders
function Model.Build(settings, only)
	settings = type(settings) == 'table' and settings or {}
	local function want(part) return only == nil or only[part] == true end
	local problems, placeholders = {}, {}
	local defaults = settings.ALERT
	local reach = bounded(settings.REACH, 0.5, 20, 2.5)
	local function reachOf(row) return bounded(row.REACH, 0.5, 20, reach) end
	local catalogue = type(settings.ITEMS) == 'table' and settings.ITEMS or {}
	local dirty = type(settings.DIRTY) == 'table' and settings.DIRTY or {}

	local out = {
		reach = reach,
		dirty = {
			item = idOf(dirty.ITEM) or 'dirty_eddies',
			mode = dirty.MODE == 'clean' and 'clean' or 'item',
			cleanType = type(dirty.CLEAN_TYPE) == 'string' and dirty.CLEAN_TYPE or 'EDDIES',
		},
		dealers = { byId = {}, list = {} },
		stores = { byId = {}, list = {} },
		fronts = { byId = {}, list = {} },
		labs = { byId = {}, list = {} },
		drugs = {},
	}
	if dirty.MODE ~= nil and dirty.MODE ~= 'item' and dirty.MODE ~= 'clean' then
		problems[#problems + 1] = "DIRTY.MODE must be 'item' or 'clean'; using 'item'"
	end

	local market = type(settings.BLACKMARKET) == 'table' and settings.BLACKMARKET or {}
	eachEntry(want('dealers') and market.DEALERS or nil, 'dealer', out.dealers, problems, placeholders, function(row, id, where)
		local spots, unsurveyed = {}, 0
		for _, spot in ipairs(type(row.SPOTS) == 'table' and row.SPOTS or {}) do
			local point, placeholder = type(spot) == 'table' and pointOf(spot) or nil, false
			if type(spot) == 'table' then point, placeholder = pointOf(spot) end
			if point ~= nil then
				point.bucket = integer(row.BUCKET, 0, 2147483647) or 0
				point.yaw = finiteNumber(spot.YAW) or 0
				spots[#spots + 1] = point
			elseif placeholder then
				unsurveyed = unsurveyed + 1
			else
				problems[#problems + 1] = where .. ': a SPOT needs a finite X, Y and Z'
			end
		end
		if #spots == 0 then
			if unsurveyed > 0 then return nil, true end
			problems[#problems + 1] = where .. ': SPOTS must list at least one position'
			return nil
		end
		if type(row.RECORD) ~= 'string' or not row.RECORD:match('^Character%.[%w_%.]+$') then
			problems[#problems + 1] = where .. ': RECORD must be a Character.* record'
			return nil
		end
		local jobs, gangs = groupsOf(row, where, problems)
		local stock, buys = {}, {}
		for index, line in ipairs(type(row.STOCK) == 'table' and row.STOCK or {}) do
			local item = type(line) == 'table' and idOf(line.ITEM) or nil
			local price = type(line) == 'table' and integer(line.PRICE, 1, 100000000) or nil
			local qty = type(line) == 'table' and integer(line.QTY, 0, 100000) or nil
			if item == nil or price == nil or qty == nil then
				problems[#problems + 1] = ('%s: STOCK #%d needs ITEM, a PRICE above 0 and a QTY'):format(where, index)
			else
				stock[#stock + 1] = { item = item, price = price, qty = qty, max = qty,
					restockMs = math.floor(bounded(line.RESTOCK_MINUTES, 0, 100000, 0) * 60000),
					dirtyOnly = line.DIRTY_ONLY == true, restockAt = nil }
			end
		end
		for index, line in ipairs(type(row.BUYS) == 'table' and row.BUYS or {}) do
			local item = type(line) == 'table' and idOf(line.ITEM) or nil
			local price = type(line) == 'table' and integer(line.PRICE, 1, 100000000) or nil
			if item == nil or price == nil then
				problems[#problems + 1] = ('%s: BUYS #%d needs ITEM and a PRICE above 0'):format(where, index)
			else
				buys[#buys + 1] = { item = item, price = price }
			end
		end
		return {
			label = labelOf(row.LABEL, id), record = row.RECORD, spots = spots,
			bucket = spots[1].bucket, reach = reachOf(row),
			rotateMs = math.floor(bounded(row.ROTATE_MINUTES, 0, 100000, 0) * 60000),
			hours = type(row.HOURS) == 'table' and { finiteNumber(row.HOURS[1]), finiteNumber(row.HOURS[2]) } or nil,
			priceMod = bounded(row.PRICE_MOD, 0.01, 100, 1),
			jobs = jobs, gangs = gangs, stock = stock, buys = buys,
		}
	end)

	local robberies = type(settings.ROBBERIES) == 'table' and settings.ROBBERIES or {}
	eachEntry(want('stores') and robberies.STORES or nil, 'store', out.stores, problems, placeholders, function(row, id, where)
		local point, placeholder = pointOf(row)
		if point == nil then
			if not placeholder then problems[#problems + 1] = where .. ': needs a finite X, Y and Z' end
			return nil, placeholder
		end
		local reward = type(row.REWARD) == 'table' and row.REWARD or {}
		local low, high = integer(reward.MIN, 0, 100000000), integer(reward.MAX, 0, 100000000)
		if low == nil or high == nil or high < low then
			problems[#problems + 1] = where .. ': REWARD needs whole MIN <= MAX'
			return nil
		end
		local register = type(row.REGISTER) == 'table' and row.REGISTER or {}
		local clerk = nil
		if type(row.CLERK) == 'table' and type(row.CLERK.RECORD) == 'string'
			and row.CLERK.RECORD:match('^Character%.[%w_%.]+$') then
			local at = pointOf(row.CLERK)
			if at ~= nil then
				clerk = { record = row.CLERK.RECORD, x = at.x, y = at.y, z = at.z, yaw = finiteNumber(row.CLERK.YAW) or 0 }
			end
		end
		return {
			label = labelOf(row.LABEL, id), x = point.x, y = point.y, z = point.z, bucket = point.bucket,
			reach = reachOf(row), clerk = clerk, rewardMin = low, rewardMax = high,
			durationMs = integer(row.DURATION_MS, 1000, 600000) or 30000,
			minPolice = integer(row.MIN_POLICE, 0, 1000) or 0,
			max = integer(register.MAX, 1, 100) or 1,
			regrowMs = math.floor(bounded(register.REGROW_MINUTES, 0, 100000, 45) * 60000),
			cooldownMs = math.floor(bounded(row.PLAYER_COOLDOWN_MIN, 0, 100000, 20) * 60000),
			requireWeapon = row.REQUIRE_WEAPON ~= false,
			alert = alertOf(row.ALERT, defaults),
		}
	end)

	local laundering = type(settings.LAUNDERING) == 'table' and settings.LAUNDERING or {}
	eachEntry(want('fronts') and laundering.FRONTS or nil, 'front', out.fronts, problems, placeholders, function(row, id, where)
		local point, placeholder = pointOf(row)
		if point == nil then
			if not placeholder then problems[#problems + 1] = where .. ': needs a finite X, Y and Z' end
			return nil, placeholder
		end
		local jobs, gangs = groupsOf(row, where, problems)
		local rate = finiteNumber(row.RATE_PCT)
		if rate == nil or rate <= 0 or rate > 1 then
			problems[#problems + 1] = where .. ': RATE_PCT must be above 0 and at most 1'
			return nil
		end
		return {
			label = labelOf(row.LABEL, id), x = point.x, y = point.y, z = point.z, bucket = point.bucket,
			reach = reachOf(row), jobs = jobs, gangs = gangs, rate = rate,
			perTxMax = integer(row.PER_TX_MAX, 1, 100000000) or 5000,
			dailyCap = integer(row.DAILY_CAP, 0, 1000000000) or 25000,
			batchMs = math.floor(bounded(row.MINUTES_PER_BATCH, 0, 100000, 10) * 60000),
			payout = type(row.PAYOUT) == 'string' and row.PAYOUT or 'BANK',
		}
	end)

	eachEntry(want('labs') and settings.LABS or nil, 'lab', out.labs, problems, placeholders, function(row, id, where)
		local point, placeholder = pointOf(row)
		if point == nil then
			if not placeholder then problems[#problems + 1] = where .. ': needs a finite X, Y and Z' end
			return nil, placeholder
		end
		local jobs, gangs = groupsOf(row, where, problems)
		local heat = type(row.HEAT) == 'table' and row.HEAT or {}
		return {
			label = labelOf(row.LABEL, id), x = point.x, y = point.y, z = point.z, bucket = point.bucket,
			reach = reachOf(row), jobs = jobs, gangs = gangs,
			queue = integer(row.QUEUE, 1, 100) or 2,
			recipes = type(row.RECIPES) == 'table' and row.RECIPES or {},
			perCycle = bounded(heat.PER_CYCLE, 0, 100, 10),
			decayPerMinute = bounded(heat.DECAY_PER_MINUTE, 0, 100, 1),
			floor = bounded(heat.FLOOR, 0, 100, 30),
			alert = alertOf(row.ALERT, defaults),
		}
	end)

	for name, row in pairs(want('drugs') and type(settings.DRUGS) == 'table' and settings.DRUGS or {}) do
		if idOf(name) == nil or type(row) ~= 'table' then
			problems[#problems + 1] = ('DRUGS.%s: a drug is item name -> { EFFECT, ... }'):format(tostring(name))
		else
			out.drugs[name] = {
				effect = type(row.EFFECT) == 'string' and row.EFFECT or '',
				strength = bounded(row.STRENGTH, 0, 1, 0.5),
				seconds = integer(row.SECONDS, 0, 600) or 60,
				armor = bounded(row.ARMOR, 0, 1000, 0),
				dose = bounded(row.DOSE, 0, 1000, 1),
			}
			if catalogue[name] == nil then
				problems[#problems + 1] = ('DRUGS.%s: not in ITEMS; usable only if config/inventory.lua has it')
					:format(name)
			end
		end
	end

	local street = type(settings.STREET) == 'table' and settings.STREET or {}
	local items = {}
	for name, range in pairs(want('street') and type(street.ITEMS) == 'table' and street.ITEMS or {}) do
		local low = type(range) == 'table' and integer(range.MIN, 0, 100000000) or nil
		local high = type(range) == 'table' and integer(range.MAX, 0, 100000000) or nil
		if idOf(name) == nil or low == nil or high == nil or high < low then
			problems[#problems + 1] = ('STREET.ITEMS.%s needs whole MIN <= MAX'):format(tostring(name))
		else
			items[name] = { min = low, max = high }
		end
	end
	local function presets(list, low, high)
		local kept = {}
		for _, value in ipairs(type(list) == 'table' and list or {}) do
			local number = integer(value, low, high)
			if number ~= nil then kept[#kept + 1] = number end
		end
		return kept
	end
	out.street = {
		enabled = street.ENABLED ~= false,
		currency = street.CURRENCY == 'clean' and 'clean' or 'dirty',
		items = items,
		prices = presets(street.PRICES, 1, 100000000),
		counts = presets(street.COUNTS, 1, 1000),
		durationMs = integer(street.DURATION_MS, 500, 600000) or 4000,
		inviteMs = integer(street.INVITE_TIMEOUT_MS, 1000, 60000) or 15000,
		startDistance = bounded(street.START_DISTANCE, 0.25, 10, 2.5),
		alert = alertOf(street.ALERT, defaults),
	}
	out.launderAmounts = presets(laundering.AMOUNTS, 1, 100000000)

	table.sort(problems)
	table.sort(placeholders)
	return out, problems, placeholders
end

--- Whether a character snapshot may use an entry with JOBS and/or GANGS.
-- @author dop42
-- @param entry table a built entry (`jobs`, `gangs`)
-- @param snapshot table|nil { job, jobs, gang, gangs, atMs }
-- @param nowMs number
-- @param settings table the module config (MEMBERSHIP, JOB_MAX_AGE_MS)
-- @return boolean
-- @return string|nil
function Model.Gate(entry, snapshot, nowMs, settings)
	settings = type(settings) == 'table' and settings or {}
	return OPX.JobGate.EvaluateGroups({ jobs = entry.jobs, gangs = entry.gangs }, snapshot, nowMs, {
		maxAgeMs = bounded(settings.JOB_MAX_AGE_MS, 1, 86400000, 60000),
		membership = settings.MEMBERSHIP == 'any' and 'any' or 'primary',
	})
end
