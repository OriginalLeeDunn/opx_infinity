--- The ripperdoc's arithmetic and its config validator. Pure: no host call.
-- @author dop42
--
-- EVERY NUMBER A CLINIC CHARGES OR RISKS IS DECIDED HERE, from the config and
-- from what the caller hands in, so the suite can hold the prices, the dice and
-- the refusals to their figures without booting anything. The server calls the
-- same functions with what it has just re-read; the client calls `Read` only to
-- draw the spheres and the terminal's catalogue, and decides nothing with it.
--
-- `Read` NORMALISES ONCE AND NAMES WHAT IT DROPS. A refused chrome, clinic,
-- chair or catalogue row is not there at all, and its line is in `problems`
-- for the boot log. A position at 0,0,0 is not a problem: it is a placeholder,
-- named in `placeholders`, and the piece it belongs to is disabled until
-- somebody surveys it -- the rule every place module here follows.

local M = OPX.Modules.Get('ripperdoc')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite

--- The slot/profile pairs P1 lets a native chrome name.
Model.NATIVE_PAIRS = { arms = 'gorilla_arms', legs = 'double_jump' }

--- Every grade field the platform takes, with its bounds; `required` ones
--- must be present. `open77_api server:Open77.cyberware.define` and the
--- cyberware guide's "Grade options" are where these come from.
Model.GRADE_FIELDS = {
	normalDamage = { 0, 300, true }, chargedDamage = { 0, 300, true },
	knockbackMeters = { 0, 6, true }, cooldownMs = { 100, 600000, true },
	chargeMs = { 100, 10000, true },
	normalKnockbackMeters = { 0, 6 }, maxChargeMs = { 100, 60000 },
	normalStaminaCost = { 0, 300 }, chargedStaminaCost = { 0, 300 },
	blockDamageMultiplier = { 0, 1 }, blockAngleDegrees = { 0, 180 },
	jumpStaminaCost = { 0, 300 }, maxAirborneMs = { 100, 10000 }, maxFallSpeed = { 0.1, 30 },
}
Model.GRADE_FLAGS = { nonlethal = true, cosmetic = true }
Model.MAX_GRADES = 32
Model.MAX_TIER = 5
Model.ORIGINS = { legit = true, black = true }
Model.MONEY = { BANK = true, EDDIES = true }
Model.PARTS = { keep = true, damaged = true, lost = true }

local function clamp(value, low, high, fallback)
	value = finiteNumber(value)
	if value == nil then return fallback end
	if value < low then return low end
	if value > high then return high end
	return value
end

local function int(value)
	local number = finiteNumber(value)
	if number == nil or number ~= math.floor(number) then return nil end
	return math.tointeger(number)
end

local function word(value, maximum, pattern)
	if type(value) ~= 'string' or #value < 1 or #value > maximum then return nil end
	if not value:match(pattern) then return nil end
	return value
end

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' then return nil end
	return OPX.Text.Clean(value, maximum, '...')
end

local function sortedKeys(map)
	local keys = {}
	if type(map) ~= 'table' then return keys end
	for key in pairs(map) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	return keys
end

--- Whether a declared point is the 0,0,0 placeholder.
-- @author dop42
function Model.Placeholder(point)
	return type(point) == 'table' and finiteNumber(point.X) == 0 and finiteNumber(point.Y) == 0 and finiteNumber(point.Z) == 0
end

local function point(raw)
	if type(raw) ~= 'table' then return nil end
	local x, y, z = OPX.Spots.Coordinate(raw.X), OPX.Spots.Coordinate(raw.Y), OPX.Spots.Coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

-- ── chrome ──────────────────────────────────────────────────────────────────

local function readGrade(raw, where, lines)
	if type(raw) ~= 'table' then
		lines[#lines + 1] = where .. ': a grade is a table of the platform\'s grade fields'
		return nil
	end
	local grade = {}
	for field, value in pairs(raw) do
		local bounds = Model.GRADE_FIELDS[field]
		if bounds ~= nil then
			local number = finiteNumber(value)
			if number == nil or number < bounds[1] or number > bounds[2] then
				lines[#lines + 1] = ('%s: %s must be %s..%s'):format(where, tostring(field), bounds[1], bounds[2])
				return nil
			end
			grade[field] = number
		elseif Model.GRADE_FLAGS[field] then
			if type(value) ~= 'boolean' then
				lines[#lines + 1] = ('%s: %s must be true or false'):format(where, field)
				return nil
			end
			grade[field] = value
		else
			lines[#lines + 1] = ('%s: unknown grade field %s'):format(where, tostring(field))
			return nil
		end
	end
	for field, bounds in pairs(Model.GRADE_FIELDS) do
		if bounds[3] and grade[field] == nil then
			lines[#lines + 1] = ('%s: %s is required'):format(where, field)
			return nil
		end
	end
	if grade.maxChargeMs ~= nil and grade.maxChargeMs < grade.chargeMs then
		lines[#lines + 1] = where .. ': maxChargeMs must be >= chargeMs'
		return nil
	end
	for _, field in ipairs({ 'cooldownMs', 'chargeMs', 'maxChargeMs', 'maxAirborneMs' }) do
		if grade[field] ~= nil then grade[field] = math.tointeger(math.floor(grade[field])) end
	end
	return grade
end

local function readChrome(key, raw, S, lines)
	local where = 'CHROME.' .. key
	if word(key, 48, '^[%w_]+$') == nil then
		lines[#lines + 1] = where .. ': a chrome key is 1..48 letters, digits or _'
		return nil
	end
	if type(raw) ~= 'table' then
		lines[#lines + 1] = where .. ': must be a table'
		return nil
	end
	local chrome = {
		key = key,
		label = text(raw.LABEL, 64) or key,
		description = text(raw.DESCRIPTION, 160),
		kind = raw.KIND,
		slot = word(raw.SLOT, 32, '^[%w_]+$'),
		item = word(raw.ITEM, 64, '^[%w_]+$'),
		price = int(raw.PRICE),
		humanity = finiteNumber(raw.HUMANITY),
		capacity = finiteNumber(raw.CAPACITY),
		weight = int(raw.WEIGHT) or 0,
		-- The pile a dropped part draws: a curated `Open77.props` alias.
		model = word(raw.MODEL, 64, '^[%w_%.]+$') or 'medical.container',
		illegal = raw.ILLEGAL == true,
		installMs = int(raw.INSTALL_MS),
		removeMs = int(raw.REMOVE_MS),
		tiers = {},
		tierList = {},
	}
	if chrome.kind ~= 'native' and chrome.kind ~= 'rp' then
		lines[#lines + 1] = where .. ": KIND must be 'native' or 'rp'"
		return nil
	end
	if chrome.slot == nil then lines[#lines + 1] = where .. ': SLOT is a word'; return nil end
	if chrome.item == nil then lines[#lines + 1] = where .. ': ITEM is an item name'; return nil end
	if chrome.price == nil or chrome.price < 0 then
		lines[#lines + 1] = where .. ': PRICE is a whole amount >= 0'
		return nil
	end
	if chrome.humanity == nil or chrome.humanity < 0 or chrome.humanity > 100 then
		lines[#lines + 1] = where .. ': HUMANITY is 0..100'
		return nil
	end
	if chrome.capacity == nil or chrome.capacity < 0 then
		lines[#lines + 1] = where .. ': CAPACITY is >= 0'
		return nil
	end

	if chrome.kind == 'native' then
		local native = type(raw.NATIVE) == 'table' and raw.NATIVE or nil
		if native == nil then lines[#lines + 1] = where .. ': a native chrome needs NATIVE'; return nil end
		local id = word(native.ID, 96, '^[%w_%.:%-]+$')
		local version = int(native.VERSION)
		if id == nil then lines[#lines + 1] = where .. ': NATIVE.ID is 1..96 of letters, digits, _ . : -'; return nil end
		if version == nil or version < 1 then lines[#lines + 1] = where .. ': NATIVE.VERSION is >= 1'; return nil end
		if Model.NATIVE_PAIRS[chrome.slot] == nil or Model.NATIVE_PAIRS[chrome.slot] ~= native.PROFILE then
			lines[#lines + 1] = where .. ': SLOT/PROFILE must be arms/gorilla_arms or legs/double_jump'
			return nil
		end
		if type(native.GRADES) ~= 'table' then lines[#lines + 1] = where .. ': NATIVE.GRADES is required'; return nil end
		local grades, count = {}, 0
		for tier, gradeRaw in pairs(native.GRADES) do
			local t = int(tier)
			if t == nil or t < 1 or t > Model.MAX_TIER or S.tiers[t] == nil then
				lines[#lines + 1] = ('%s: NATIVE.GRADES[%s] is not a tier in TIERS'):format(where, tostring(tier))
				return nil
			end
			local grade = readGrade(gradeRaw, ('%s.NATIVE.GRADES[%d]'):format(where, t), lines)
			if grade == nil then return nil end
			grades[t] = grade
			count = count + 1
		end
		if count == 0 or count > Model.MAX_GRADES then
			lines[#lines + 1] = where .. ': NATIVE.GRADES holds 1..32 grades'
			return nil
		end
		chrome.native = { id = id, version = version, profile = native.PROFILE, grades = grades }
		for t = 1, Model.MAX_TIER do
			if grades[t] ~= nil then chrome.tiers[t] = true; chrome.tierList[#chrome.tierList + 1] = t end
		end
	else
		local list = type(raw.TIERS) == 'table' and raw.TIERS or { 1 }
		for _, tier in ipairs(list) do
			local t = int(tier)
			if t == nil or S.tiers[t] == nil then
				lines[#lines + 1] = ('%s: TIERS names %s, which is not in TIERS'):format(where, tostring(tier))
				return nil
			end
			if not chrome.tiers[t] then chrome.tiers[t] = true; chrome.tierList[#chrome.tierList + 1] = t end
		end
		table.sort(chrome.tierList)
		if #chrome.tierList == 0 then lines[#lines + 1] = where .. ': TIERS is empty'; return nil end
	end
	return chrome
end

-- ── clinics ─────────────────────────────────────────────────────────────────

local function readClinic(key, raw, S, lines, placeholders)
	local where = 'CLINICS.' .. key
	if word(key, 48, '^[%w_]+$') == nil then
		lines[#lines + 1] = where .. ': a clinic key is 1..48 letters, digits or _'
		return nil
	end
	if type(raw) ~= 'table' then lines[#lines + 1] = where .. ': must be a table'; return nil end
	local clinic = {
		key = key,
		label = text(raw.LABEL, 64) or key,
		licensed = raw.LICENSED ~= false,
		risk = clamp(raw.RISK, 0, 10, 1.0),
		markup = clamp(raw.MARKUP, 0, 10, 1.0),
		labour = int(raw.LABOUR) or 0,
		jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
		onDuty = raw.ON_DUTY == true,
		bucket = int(raw.BUCKET) or 0,
		stockGrade = int(raw.STOCK_GRADE) or 0,
		money = Model.MONEY[raw.MONEY] and raw.MONEY or S.money,
		services = {
			install = type(raw.SERVICES) ~= 'table' or raw.SERVICES.install ~= false,
			remove = type(raw.SERVICES) ~= 'table' or raw.SERVICES.remove ~= false,
		},
		chairs = {},
	}
	if clinic.labour < 0 then lines[#lines + 1] = where .. ': LABOUR is >= 0'; return nil end
	if raw.MONEY ~= nil and not Model.MONEY[raw.MONEY] then
		lines[#lines + 1] = where .. ": MONEY is 'BANK' or 'EDDIES'"
	end
	local before = #lines
	OPX.JobGate.Problems(raw.JOBS, where, lines)
	if #lines > before then return nil end

	if raw.ALLOW ~= nil then
		if type(raw.ALLOW) ~= 'table' then lines[#lines + 1] = where .. ': ALLOW is a list of chrome keys'; return nil end
		clinic.allow = {}
		for _, name in ipairs(raw.ALLOW) do
			if S.chrome[name] == nil then
				lines[#lines + 1] = ('%s: ALLOW names %s, which is not in CHROME'):format(where, tostring(name))
			else
				clinic.allow[name] = true
			end
		end
	end

	local placeholderChairs = 0
	for index, chair in ipairs(type(raw.CHAIRS) == 'table' and raw.CHAIRS or {}) do
		if Model.Placeholder(chair) then
			placeholderChairs = placeholderChairs + 1
		else
			local at = point(chair)
			local radius = clamp(chair.RADIUS, 0.3, 5, 1.5)
			if at == nil then
				lines[#lines + 1] = ('%s.CHAIRS[%d]: X, Y and Z are coordinates'):format(where, index)
			else
				at.radius, at.yaw = radius, finiteNumber(chair.YAW) or 0.0
				at.pose = word(chair.POSE, 32, '^[%w_]+$')
				clinic.chairs[#clinic.chairs + 1] = at
			end
		end
	end
	if #clinic.chairs == 0 then
		if placeholderChairs > 0 then
			placeholders[#placeholders + 1] = key
		else
			lines[#lines + 1] = where .. ': no CHAIRS'
		end
		return nil
	end

	local chest = type(raw.CHEST) == 'table' and raw.CHEST or nil
	if chest ~= nil then
		local name = word(chest.NAME, 48, '^[%w_%-%.]+$')
		if name == nil then
			lines[#lines + 1] = where .. '.CHEST: NAME is 1..48 of letters, digits, _ - .'
		elseif Model.Placeholder(chest) then
			placeholders[#placeholders + 1] = key .. '.CHEST'
		else
			local at = point(chest)
			if at == nil then
				lines[#lines + 1] = where .. '.CHEST: X, Y and Z are coordinates'
			else
				at.name = name
				at.label = text(chest.LABEL, 64) or clinic.label
				at.slots = clamp(int(chest.SLOTS), 1, 500, 50)
				at.maxWeight = clamp(int(chest.MAX_WEIGHT), 1, 100000000, 100000)
				clinic.chest = at
			end
		end
	end

	local supply = type(raw.SUPPLY) == 'table' and raw.SUPPLY or nil
	if supply ~= nil then
		local catalog = {}
		for index, row in ipairs(type(supply.CATALOG) == 'table' and supply.CATALOG or {}) do
			local rowWhere = ('%s.SUPPLY.CATALOG[%d]'):format(where, index)
			local chrome = type(row) == 'table' and S.chrome[row.CHROME] or nil
			local tier = type(row) == 'table' and int(row.TIER) or nil
			local cost = type(row) == 'table' and int(row.COST) or nil
			local origin = type(row) == 'table' and (row.ORIGIN or (clinic.licensed and 'legit' or 'black')) or nil
			if chrome == nil then
				lines[#lines + 1] = rowWhere .. ': CHROME names nothing in CHROME'
			elseif tier == nil or not chrome.tiers[tier] then
				lines[#lines + 1] = rowWhere .. ': TIER is not one this chrome comes in'
			elseif cost == nil or cost < 0 then
				lines[#lines + 1] = rowWhere .. ': COST is a whole amount >= 0'
			elseif not Model.ORIGINS[origin] then
				lines[#lines + 1] = rowWhere .. ": ORIGIN is 'legit' or 'black'"
			elseif not Model.Allows(clinic, chrome, origin) then
				lines[#lines + 1] = rowWhere .. ': this clinic does not work on that chrome or origin'
			else
				catalog[#catalog + 1] = { index = index, chrome = chrome.key, tier = tier, cost = cost,
					grade = int(row.GRADE) or clinic.stockGrade, origin = origin }
			end
		end
		if Model.Placeholder(supply) then
			placeholders[#placeholders + 1] = key .. '.SUPPLY'
		elseif #catalog > 0 then
			local at = point(supply)
			if at == nil then
				lines[#lines + 1] = where .. '.SUPPLY: X, Y and Z are coordinates'
			else
				at.catalog = catalog
				clinic.supply = at
			end
		end
	end
	return clinic
end

-- ── the whole config ────────────────────────────────────────────────────────

local function readOutcomes(raw, lines)
	local list, total = {}, 0
	for _, key in ipairs(sortedKeys(raw)) do
		local row = raw[key]
		local where = 'OUTCOMES.' .. key
		if type(row) ~= 'table' then
			lines[#lines + 1] = where .. ': must be a table'
		else
			local weight = finiteNumber(row.WEIGHT)
			local part = row.PART or 'keep'
			if weight == nil or weight < 0 then
				lines[#lines + 1] = where .. ': WEIGHT is >= 0'
			elseif not Model.PARTS[part] then
				lines[#lines + 1] = where .. ": PART is 'keep', 'damaged' or 'lost'"
			elseif weight > 0 then
				local health = row.HEALTH_PCT ~= nil and clamp(row.HEALTH_PCT, 1, 100, nil) or nil
				list[#list + 1] = { key = key, weight = weight, apply = row.APPLY == true, part = part,
					conditionLoss = clamp(row.CONDITION_LOSS, 0, 100, 0),
					refundPct = clamp(row.REFUND_PCT, 0, 100, 0), healthPct = health }
				total = total + weight
			end
		end
	end
	return list, total
end

--- Reads the whole config into the shape every other function takes.
-- @author dop42
-- @param cfg table `OPX.Config.MODULES.ripperdoc`
-- @return table S, with `problems` and `placeholders` lists
function Model.Read(cfg)
	cfg = type(cfg) == 'table' and cfg or {}
	local lines, placeholders = {}, {}
	local S = {
		problems = lines,
		placeholders = placeholders,
		membership = cfg.MEMBERSHIP == 'any' and 'any' or 'primary',
		jobMaxAgeMs = clamp(cfg.JOB_MAX_AGE_MS, 1000, 3600000, 60000),
		docReach = clamp(cfg.DOC_REACH, 0.5, 10, 3.0),
		promptRadius = clamp(cfg.PROMPT_RADIUS, 0.5, 10, 2.0),
		gradeMod = {},
		money = Model.MONEY[cfg.MONEY] and cfg.MONEY or 'BANK',
		docShare = clamp(cfg.DOC_SHARE, 0, 100, 60),
		till = cfg.TILL == 'doc' and 'doc' or 'void',
		consentMs = math.floor(clamp(cfg.CONSENT_MS, 5000, 300000, 30000)),
		installMs = math.floor(clamp(cfg.INSTALL_MS, 1000, 600000, 30000)),
		removeMs = math.floor(clamp(cfg.REMOVE_MS, 1000, 600000, 20000)),
		animation = word(cfg.ANIMATION, 32, '^[%w_]+$'),
		removeLabourMult = clamp(cfg.REMOVE_LABOUR_MULT, 0, 10, 0.6),
		removeRiskMult = clamp(cfg.REMOVE_RISK_MULT, 0, 10, 0.5),
		maxRisk = clamp(cfg.MAX_RISK, 0, 1, 0.6),
		wornBelow = clamp(cfg.WORN_BELOW, 0, 100, 50),
		wornRisk = clamp(cfg.WORN_RISK, 0, 1, 0.1),
		blackMult = clamp(cfg.BLACK_MULT, 0, 10, 1.5),
		removalWear = clamp(cfg.REMOVAL_WEAR, 0, 100, 10),
		removalTierLoss = math.floor(clamp(cfg.REMOVAL_TIER_LOSS, 0, 4, 0)),
		maxCapacity = clamp(cfg.MAX_CAPACITY, 0, 1000, 40),
		overCapacity = cfg.OVER_CAPACITY == 'risk' and 'risk' or 'refuse',
		overCapacityRisk = clamp(cfg.OVER_CAPACITY_RISK, 0, 1, 0.25),
		tiers = {},
		chrome = {},
		chromeList = {},
		clinics = {},
		clinicList = {},
	}
	if cfg.TILL ~= nil and cfg.TILL ~= 'doc' and cfg.TILL ~= 'void' then
		lines[#lines + 1] = "TILL is 'doc' or 'void'; read as 'void'"
	end
	if cfg.MONEY ~= nil and not Model.MONEY[cfg.MONEY] then
		lines[#lines + 1] = "MONEY is 'BANK' or 'EDDIES'; read as 'BANK'"
	end
	if type(cfg.GRADE_MOD) == 'table' then
		for grade, mult in pairs(cfg.GRADE_MOD) do
			local g, m = int(grade), finiteNumber(mult)
			if g == nil or m == nil or m < 0 then
				lines[#lines + 1] = 'GRADE_MOD is grade -> multiplier >= 0'
			else
				S.gradeMod[g] = m
			end
		end
	end
	local humanity = type(cfg.HUMANITY) == 'table' and cfg.HUMANITY or {}
	S.humanity = {
		start = clamp(humanity.START, 0, 1000, 100),
		refuseBelow = clamp(humanity.REFUSE_BELOW, -1000, 1000, 0),
		refundPct = clamp(humanity.REFUND_PCT, 0, 100, 50),
		perTier = clamp(humanity.PER_TIER, 0, 100, 0),
	}
	local native = type(cfg.NATIVE) == 'table' and cfg.NATIVE or {}
	S.native = {
		bind = native.BIND ~= false,
		fallbackRp = native.FALLBACK_RP ~= false,
		timeoutMs = math.floor(clamp(native.TIMEOUT_MS, 1000, 600000, 30000)),
	}
	S.outcomes, S.outcomeWeight = readOutcomes(type(cfg.OUTCOMES) == 'table' and cfg.OUTCOMES or {}, lines)

	for tier, row in pairs(type(cfg.TIERS) == 'table' and cfg.TIERS or {}) do
		local t = int(tier)
		if t == nil or t < 1 or t > Model.MAX_TIER or type(row) ~= 'table' then
			lines[#lines + 1] = ('TIERS[%s]: a tier is 1..%d with a table'):format(tostring(tier), Model.MAX_TIER)
		else
			S.tiers[t] = { tier = t, label = text(row.LABEL, 32) or ('Tier ' .. t),
				mult = clamp(row.MULT, 0, 100, 1), fail = clamp(row.FAIL, 0, 1, 0),
				grade = int(row.GRADE) or 0 }
		end
	end

	local items = {}
	for _, key in ipairs(sortedKeys(cfg.CHROME)) do
		local chrome = readChrome(key, cfg.CHROME[key], S, lines)
		if chrome ~= nil then
			if items[chrome.item] then
				lines[#lines + 1] = ('CHROME.%s: ITEM %s is already %s\'s'):format(key, chrome.item, items[chrome.item])
			else
				items[chrome.item] = key
				S.chrome[key] = chrome
				S.chromeList[#S.chromeList + 1] = chrome
			end
		end
	end

	local stashes = {}
	for _, key in ipairs(sortedKeys(cfg.CLINICS)) do
		local clinic = readClinic(key, cfg.CLINICS[key], S, lines, placeholders)
		if clinic ~= nil then
			if clinic.chest ~= nil and stashes[clinic.chest.name] then
				lines[#lines + 1] = ('CLINICS.%s.CHEST: NAME %s is already %s\'s'):format(key,
					clinic.chest.name, stashes[clinic.chest.name])
				clinic.chest = nil
			elseif clinic.chest ~= nil then
				stashes[clinic.chest.name] = key
			end
			S.clinics[key] = clinic
			S.clinicList[#S.clinicList + 1] = clinic
		end
	end
	return S
end

--- The validator's lines for a config, the boot log's input.
-- @author dop42
-- @param cfg table
-- @return string[]
function Model.Problems(cfg)
	return Model.Read(cfg).problems
end

-- ── the arithmetic ──────────────────────────────────────────────────────────

--- Whether a clinic works on a chrome, at all and for a part of this origin.
-- @author dop42
function Model.Allows(clinic, chrome, origin)
	if clinic == nil or chrome == nil then return false end
	if clinic.allow ~= nil and not clinic.allow[chrome.key] then return false end
	if clinic.licensed and (chrome.illegal or origin == 'black') then return false end
	return true
end

--- The bill for one operation.
-- @author dop42
-- @param source string 'stash' | 'doc' | 'patient'; a patient's own part is not sold
-- @return integer part, integer labour, integer total
function Model.Price(S, clinic, chrome, tier, action, source)
	local labour = clinic.labour
	local part = 0
	if action == 'remove' then
		labour = labour * S.removeLabourMult
	elseif source ~= 'patient' then
		local row = S.tiers[tier]
		part = chrome.price * (row and row.mult or 1) * clinic.markup
	end
	part, labour = math.floor(part + 0.5), math.floor(labour + 0.5)
	return part, labour, part + labour
end

--- What an implant costs in humanity.
-- @author dop42
function Model.HumanityCost(S, chrome, tier)
	return chrome.humanity + S.humanity.perTier * math.max(0, (tier or 1) - 1)
end

--- The failure chance of one operation, 0..MAX_RISK.
-- @author dop42
-- @param ctx table { clinic, chrome, tier, action, grade, origin, condition, overCapacity }
function Model.Risk(S, ctx)
	local tier = S.tiers[ctx.tier]
	local chance = (tier and tier.fail or 0)
		* (S.gradeMod[ctx.grade or 0] or 1)
		* (ctx.clinic and ctx.clinic.risk or 1)
	if ctx.origin == 'black' then chance = chance * S.blackMult end
	if ctx.action == 'remove' then chance = chance * S.removeRiskMult end
	local condition = finiteNumber(ctx.condition)
	if condition ~= nil and condition < S.wornBelow then chance = chance + S.wornRisk end
	if ctx.overCapacity then chance = chance + S.overCapacityRisk end
	if chance < 0 then chance = 0 end
	if chance > S.maxRisk then chance = S.maxRisk end
	return chance
end

--- Which failure a roll in [0, 1) lands on, by weight; nil when none is set.
-- @author dop42
function Model.PickOutcome(S, roll)
	if S.outcomeWeight <= 0 then return nil end
	local at = (finiteNumber(roll) or 0) * S.outcomeWeight
	local walked = 0
	for _, row in ipairs(S.outcomes) do
		walked = walked + row.weight
		if at < walked then return row end
	end
	return S.outcomes[#S.outcomes]
end

--- How a bill is split once the dice have spoken.
-- @author dop42
-- @return integer refund to the patient, integer to the doc, integer to the till
function Model.Split(S, total, refundPct)
	local refund = math.floor(total * (refundPct or 0) / 100)
	local kept = total - refund
	local doc = S.till == 'doc' and kept or math.floor(kept * S.docShare / 100)
	return refund, doc, kept - doc
end

--- A humanity value as stored, or the start value.
-- @author dop42
function Model.Humanity(S, value)
	local number = finiteNumber(value)
	if number == nil then return S.humanity.start end
	return number
end

--- The installed list as stored, keeping only well-formed entries.
-- @author dop42
function Model.Installed(value)
	local out = {}
	if type(value) ~= 'table' then return out end
	for _, entry in ipairs(value) do
		if type(entry) == 'table' and type(entry.chrome) == 'string' and type(entry.slot) == 'string' then
			out[#out + 1] = entry
		end
	end
	return out
end

--- The capacity an installed list uses, by today's catalogue.
-- @author dop42
function Model.CapacityUsed(S, installed)
	local used = 0
	for _, entry in ipairs(installed) do
		local chrome = S.chrome[entry.chrome]
		used = used + (chrome and chrome.capacity or finiteNumber(entry.capacity) or 0)
	end
	return used
end

--- The index of the installed entry in a slot, or nil.
-- @author dop42
function Model.InSlot(installed, slot)
	for index, entry in ipairs(installed) do
		if entry.slot == slot then return index end
	end
	return nil
end

--- Whether a body can take an implant: answers ok, code, overCapacity.
-- @author dop42
function Model.CheckInstall(S, humanity, installed, chrome, tier)
	if not chrome.tiers[tier] then return false, 'bad_tier' end
	if Model.InSlot(installed, chrome.slot) ~= nil then return false, 'slot_taken' end
	if humanity - Model.HumanityCost(S, chrome, tier) < S.humanity.refuseBelow then
		return false, 'humanity_low'
	end
	local over = Model.CapacityUsed(S, installed) + chrome.capacity > S.maxCapacity
	if over and S.overCapacity == 'refuse' then return false, 'over_capacity' end
	return true, nil, over
end

--- The metadata of a brand new part, which is also how stock is counted.
-- @author dop42
function Model.NewPart(tier, origin)
	return { tier = tier, origin = origin, condition = 100 }
end

--- A part that has been through a body: worn, maybe a tier down, marked used.
-- @author dop42
function Model.Worn(part, wear, tierLoss)
	local out = {}
	for key, value in pairs(part) do out[key] = value end
	out.condition = math.max(0, math.floor((finiteNumber(part.condition) or 100) - (wear or 0)))
	out.tier = math.max(1, (int(part.tier) or 1) - (tierLoss or 0))
	out.used = true
	return out
end

--- The platform definition for a native chrome, as `Open77.cyberware.define`
--- takes it. Grade ids are `tier<N>`.
-- @author dop42
function Model.Definition(chrome)
	local native = chrome.native
	local grades = {}
	for _, tier in ipairs(chrome.tierList) do
		local grade = { id = Model.GradeId(tier) }
		for field, value in pairs(native.grades[tier]) do grade[field] = value end
		grades[#grades + 1] = grade
	end
	return { id = native.id, version = native.version, slot = chrome.slot, profile = native.profile,
		grades = grades }
end

--- The platform grade id of a tier.
-- @author dop42
function Model.GradeId(tier)
	return 'tier' .. tostring(tier)
end

--- The clinic and chair a point sits in, or nil.
-- @author dop42
function Model.ChairAt(S, x, y, z, bucket, slack)
	for _, clinic in ipairs(S.clinicList) do
		if clinic.bucket == (bucket or 0) then
			for index, chair in ipairs(clinic.chairs) do
				local dx, dy, dz = x - chair.x, y - chair.y, z - chair.z
				local reach = chair.radius + (slack or 0)
				if dx * dx + dy * dy + dz * dz <= reach * reach then return clinic, index end
			end
		end
	end
	return nil
end
