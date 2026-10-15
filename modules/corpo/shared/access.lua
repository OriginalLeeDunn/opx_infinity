--- Config reads, the boot validator, the board generator and every number an
--- assignment is paid on.
-- @author dop42
--
-- PURE, like `modules/hauling/shared/access.lua` and the netrunner's: not one
-- host call. The config, a clock and a roll come in as arguments, so the server
-- calls it in a handler and a test drives every branch without a world.
--
-- A BAD CORP IS REFUSED ALONE, AND A BAD PLACE ALONE INSIDE IT: one typo in
-- Militech's depot must not close the Arasaka board. A place at three exact
-- zeros is not refused but SKIPPED until somebody surveys it, and named so (see
-- `config/fuel.lua` for why the blanks are zeros and not plausible numbers). A
-- corp with ENABLED = false is named once and left out.

local M = OPX.Modules.Get('corpo')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 48
Access.MAX_KEY = MAX_KEY

local KINDS = { deliver = true, retrieve = true, sweep = true, escort = true }
local ITEMS = { briefcase = true, datashard = true }
local DESTINATIONS = { office = true, drop = true, rival_drop = true }
local EJECTS = { always = true, no_police = true, never = true }

-- The order the lists are read in, so every problem line comes out the same.
local LIST_ORDER = { 'offices', 'drops', 'terminals', 'floors', 'pickups', 'destinations', 'enclaves' }
Access.LIST_ORDER = LIST_ORDER

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
Access.Integer = integer

local function clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end
Access.Clamp = clamp

local function sortedKeys(raw)
	local keys = {}
	for name in pairs(type(raw) == 'table' and raw or {}) do keys[#keys + 1] = tostring(name) end
	table.sort(keys)
	return keys
end

--- Whether a point is the unfilled blank: all three axes exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Access.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

local function pointOf(raw)
	local x, y, z = coordinate(raw.X), coordinate(raw.Y), coordinate(raw.Z)
	if x == nil or y == nil or z == nil then return nil end
	return x, y, z
end

-- ── the global blocks ───────────────────────────────────────────────────────

local function rangeOf(raw)
	if type(raw) ~= 'table' then return nil end
	local low, high = integer(raw[1], 0, 10000000), integer(raw[2], 0, 10000000)
	if low == nil or high == nil or high < low then return nil end
	return { low, high }
end

local function templatesOf(raw, problems)
	local out = {}
	for _, name in ipairs(sortedKeys(raw)) do
		local row = raw[name]
		local where = 'ASSIGNMENTS.' .. name
		local why = nil
		if not key(name) or type(row) ~= 'table' then
			why = 'must be a table under a plain key'
		elseif not KINDS[row.KIND] then
			why = 'KIND deliver|retrieve|sweep|escort'
		elseif rangeOf(row.PAY) == nil then
			why = 'PAY = { low, high } in whole eddies'
		elseif row.KIND == 'deliver' and not ITEMS[row.ITEM] then
			why = 'a delivery names ITEM briefcase|datashard'
		elseif (row.KIND == 'deliver' or row.KIND == 'retrieve') and not DESTINATIONS[row.TO] then
			why = 'TO office|drop|rival_drop'
		elseif row.KIND == 'sweep' and integer(row.HOLD_MS, 5000, 3600000) == nil then
			why = 'a sweep needs HOLD_MS 5000..3600000'
		elseif row.KIND == 'retrieve' and integer(row.DURATION_MS, 1000, 60000) == nil then
			why = 'a retrieval needs DURATION_MS 1000..60000'
		elseif row.KIND == 'escort' and bounded(row.REACH, 1, 50) == nil then
			why = 'an escort needs REACH 1..50'
		end
		if why ~= nil then
			problems[#problems + 1] = where .. ': ' .. why
		else
			local corps = nil
			if type(row.CORPS) == 'table' then
				corps = {}
				for _, corp in ipairs(row.CORPS) do
					if key(corp) then corps[corp] = true end
				end
			end
			out[name] = {
				name = name, kind = row.KIND,
				label = text(row.LABEL, 64) or name, brief = text(row.BRIEF, 200),
				item = row.KIND == 'retrieve' and 'datashard' or row.ITEM,
				to = row.TO,
				minGrade = integer(row.MIN_GRADE, 0, 100) or 0,
				minStanding = integer(row.MIN_STANDING, -100000, 100000) or 0,
				pay = rangeOf(row.PAY),
				standing = integer(row.STANDING, 0, 10000) or 0,
				loss = integer(row.LOSS, 0, 10000) or 0,
				deadlineS = integer(row.DEADLINE_S, 60, 86400) or 1200,
				holdMs = integer(row.HOLD_MS, 5000, 3600000),
				durationMs = integer(row.DURATION_MS, 1000, 60000),
				reach = bounded(row.REACH, 1, 50),
				stealable = row.STEALABLE == true and (row.KIND == 'deliver' or row.KIND == 'retrieve'),
				weight = bounded(row.WEIGHT, 0, 1000000) or 10,
				corps = corps,
			}
		end
	end
	return out
end

local function itemsOf(raw)
	raw = type(raw) == 'table' and raw or {}
	local function one(row, name, label)
		row = type(row) == 'table' and row or {}
		return {
			name = key(row.NAME) and row.NAME or name,
			label = text(row.LABEL) or label,
			description = text(row.DESCRIPTION, 160),
			weight = integer(row.WEIGHT, 0, 100000) or 100,
		}
	end
	return {
		briefcase = one(raw.briefcase, 'corpo_briefcase', 'Corporate briefcase'),
		datashard = one(raw.datashard, 'corpo_datashard', 'Corporate datashard'),
	}
end

-- ── one corp ────────────────────────────────────────────────────────────────

-- One place of one list, or nil and why; `skip` true for a blank.
local function placeOf(corpKey, list, name, raw)
	if not key(name) or type(raw) ~= 'table' then return nil, 'must be a table under a plain key' end
	if Access.IsPlaceholder(raw) then return nil, nil, true end
	local x, y, z = pointOf(raw)
	if x == nil then return nil, 'X, Y and Z are required' end
	local wide = list == 'floors' or list == 'enclaves'
	local radius = bounded(raw.RADIUS, wide and 1 or 0.5, wide and 500 or 20)
	if radius == nil then return nil, wide and 'RADIUS 1..500' or 'RADIUS 0.5..20' end
	local place = {
		corp = corpKey, list = list, key = name, label = text(raw.LABEL) or name,
		x = x, y = y, z = z, radius = radius, bucket = integer(raw.BUCKET, 0, 2147483647) or 0,
	}
	if list == 'enclaves' then
		if raw.JOBS ~= nil then
			local wrong = OPX.JobGate.Problems(raw.JOBS, name)
			if #wrong > 0 then return nil, wrong[1] end
			place.jobs = raw.JOBS
		end
		place.onDuty = raw.ON_DUTY == true
		local eject = type(raw.EJECT) == 'table' and raw.EJECT or nil
		if eject ~= nil and not Access.IsPlaceholder(eject) then
			local ex, ey, ez = pointOf(eject)
			if ex ~= nil then place.eject = { x = ex, y = ey, z = ez } end
		end
	end
	return place
end

local function corpOf(name, raw, problems, placeholders)
	if not key(name) then return nil, 'the key must be letters, digits, _ or -' end
	if type(raw) ~= 'table' then return nil, 'must be a table' end
	if not key(raw.JOB) then return nil, 'JOB names a job from config/character.lua' end
	local account = type(raw.ACCOUNT) == 'table' and raw.ACCOUNT or {}
	local corp = {
		key = name, label = text(raw.LABEL, 48) or name, job = raw.JOB,
		account = { kind = key(account.KIND) and account.KIND or 'job', key = key(account.KEY) and account.KEY or raw.JOB },
		rivals = {}, onDuty = raw.ON_DUTY == true,
		securityGrade = integer(raw.SECURITY_GRADE, 0, 100) or 1,
		publishGrade = integer(raw.PUBLISH_GRADE, 0, 100) or 3,
		payMult = bounded(raw.PAY_MULT, 0, 10) or 1,
		records = {}, lists = {},
	}
	for _, rival in ipairs(type(raw.RIVALS) == 'table' and raw.RIVALS or {}) do
		if key(rival) and rival ~= name then corp.rivals[rival] = true end
	end
	for _, record in ipairs(type(raw.VIP_RECORDS) == 'table' and raw.VIP_RECORDS or {}) do
		if type(record) == 'string' and record:match('^Character%.[%w_%.]+$') and #record <= 96 then
			corp.records[#corp.records + 1] = record
		end
	end
	for _, list in ipairs(LIST_ORDER) do
		local out = {}
		local block = raw[M.Lists[list]]
		for _, placeKey in ipairs(sortedKeys(block)) do
			local place, why, skip = placeOf(name, list, placeKey, block[placeKey])
			if skip then
				placeholders[#placeholders + 1] = ('%s.%s.%s'):format(name, list, placeKey)
			elseif place == nil then
				problems[#problems + 1] = ('CORPS.%s.%s.%s: %s'):format(name, M.Lists[list], placeKey, why)
			else
				out[#out + 1] = place
			end
		end
		corp.lists[list] = out
	end
	return corp
end

--- Builds every shape the two halves read out of the config, and what it
--- refused, skipped or disabled.
-- @author dop42
-- @param settings table the module's config block
-- @return table
function Access.Build(settings)
	settings = type(settings) == 'table' and settings or {}
	local problems, placeholders, disabled = {}, {}, {}
	local corps, order = {}, {}
	local declared = type(settings.CORPS) == 'table' and settings.CORPS or {}
	for _, name in ipairs(sortedKeys(declared)) do
		local raw = declared[name]
		if type(raw) == 'table' and raw.ENABLED == false then
			disabled[#disabled + 1] = name
		else
			local corp, why = corpOf(name, raw, problems, placeholders)
			if corp == nil then
				problems[#problems + 1] = ('CORPS.%s: %s'):format(name, why)
			else
				corps[name] = corp
				order[#order + 1] = name
			end
		end
	end
	local payByGrade = {}
	for grade, factor in pairs(type(settings.PAY_BY_GRADE) == 'table' and settings.PAY_BY_GRADE or {}) do
		local g, f = integer(grade, 0, 100), bounded(factor, 0, 10)
		if g ~= nil and f ~= nil then payByGrade[g] = f end
	end
	local board = type(settings.BOARD) == 'table' and settings.BOARD or {}
	local standing = type(settings.STANDING) == 'table' and settings.STANDING or {}
	local quarter = type(settings.QUARTER) == 'table' and settings.QUARTER or {}
	local spy = type(settings.ESPIONAGE) == 'table' and settings.ESPIONAGE or {}
	local security = type(settings.SECURITY) == 'table' and settings.SECURITY or {}
	local publish = type(settings.PUBLISH) == 'table' and settings.PUBLISH or {}
	local mint = type(settings.MINT) == 'table' and settings.MINT or {}
	local targets = {}
	for index, target in ipairs(type(publish.TARGETS) == 'table' and publish.TARGETS or {}) do
		if type(target) == 'table' and key(target.TYPE) and key(target.TARGET) then
			targets[#targets + 1] = { type = target.TYPE, target = target.TARGET }
		else
			problems[#problems + 1] = ('PUBLISH.TARGETS[%d]: TYPE and TARGET'):format(index)
		end
	end
	local policeJobs = {}
	for _, job in ipairs(type(security.POLICE_JOBS) == 'table' and security.POLICE_JOBS or { 'ncpd' }) do
		if key(job) then policeJobs[#policeJobs + 1] = job end
	end
	local minStanding = integer(standing.MIN, -100000, 0) or -100
	local built = {
		corps = corps, order = order,
		templates = templatesOf(settings.ASSIGNMENTS, problems),
		items = itemsOf(settings.ITEMS),
		currency = key(settings.CURRENCY) and settings.CURRENCY or 'EDDIES',
		payByGrade = payByGrade,
		board = {
			size = integer(board.SIZE, 1, 30) or 6,
			refreshMs = (integer(board.REFRESH_S, 30, 86400) or 900) * 1000,
			maxActive = integer(board.MAX_ACTIVE, 1, 5) or 1,
		},
		standing = {
			metadata = key(standing.METADATA) and standing.METADATA or 'corpo',
			min = minStanding,
			max = math.max(minStanding, integer(standing.MAX, 0, 1000000) or 1000),
			abandonLoss = integer(standing.ABANDON_LOSS, 0, 10000) or 3,
		},
		quarter = {
			days = integer(quarter.DAYS, 1, 366) or 91,
			target = integer(quarter.TARGET, 0, 10000) or 0,
			bonus = integer(quarter.BONUS, 0, 10000000) or 0,
		},
		mintPerHour = integer(mint.PER_HOUR, 0, 100000000) or 30000,
		espionage = {
			enabled = spy.ENABLED ~= false,
			stealMs = integer(spy.STEAL_MS, 1000, 60000) or 6000,
			reach = bounded(spy.REACH, 0.5, 10) or 2.0,
			rivalsOnly = spy.RIVALS_ONLY ~= false,
			pay = rangeOf(spy.PAY) or { 500, 900 },
			standing = integer(spy.STANDING, 0, 10000) or 12,
			cooldownMs = (integer(spy.COOLDOWN_S, 0, 86400) or 300) * 1000,
		},
		security = {
			tickMs = integer(security.TICK_MS, 500, 60000) or 2000,
			detainMs = integer(security.DETAIN_MS, 1000, 60000) or 4000,
			reach = bounded(security.REACH, 0.5, 10) or 2.5,
			alertCooldownMs = (integer(security.ALERT_COOLDOWN_S, 0, 3600) or 60) * 1000,
			standing = integer(security.STANDING, 0, 10000) or 3,
			policeJobs = policeJobs,
			eject = EJECTS[security.EJECT] and security.EJECT or 'no_police',
		},
		publish = {
			enabled = publish.ENABLED ~= false and #targets > 0,
			markup = bounded(publish.MARKUP, 0.1, 10) or 1.25,
			deadlineS = integer(publish.DEADLINE_S, 60, 86400) or 3600,
			targets = targets,
		},
		tickMs = integer(settings.TICK_MS, 250, 10000) or 1000,
		requestMs = integer(settings.REQUEST_MS, 100, 10000) or 700,
		problems = problems,
		placeholders = placeholders,
		disabled = disabled,
	}
	for _, template in pairs(built.templates) do
		if template.corps ~= nil then
			for corp in pairs(template.corps) do
				if corps[corp] == nil and declared[corp] == nil then
					problems[#problems + 1] = ('ASSIGNMENTS.%s: CORPS names %s, which is no corp'):format(template.name, corp)
				end
			end
		end
	end
	for _, name in ipairs(order) do
		for rival in pairs(corps[name].rivals) do
			if declared[rival] == nil then
				problems[#problems + 1] = ('CORPS.%s: RIVALS names %s, which is no corp'):format(name, rival)
			end
		end
	end
	return built
end

--- The problems alone: what the boot logs.
-- @author dop42
-- @param settings table
-- @return string[]
function Access.Problems(settings)
	return Access.Build(settings).problems
end

--- One place of a corp by list and key, or nil.
-- @author dop42
-- @param built table
-- @param corp string
-- @param list string
-- @param name string
-- @return table|nil
function Access.Place(built, corp, list, name)
	local entry = type(corp) == 'string' and built.corps[corp] or nil
	local places = entry and type(list) == 'string' and entry.lists[list] or nil
	if places == nil or type(name) ~= 'string' then return nil end
	for _, place in ipairs(places) do
		if place.key == name then return place end
	end
	return nil
end

-- ── the board ───────────────────────────────────────────────────────────────

--- Every drop of every enabled rival of a corp.
local function rivalDrops(corp, built)
	local out = {}
	for _, name in ipairs(built.order) do
		if corp.rivals[name] then
			for _, place in ipairs(built.corps[name].lists.drops) do out[#out + 1] = place end
		end
	end
	return out
end

--- The places an assignment may end at, for a template and a corp.
-- @author dop42
-- @param template table
-- @param corp table
-- @param built table
-- @return table[]
function Access.Ends(template, corp, built)
	if template.kind == 'escort' then return corp.lists.destinations end
	if template.kind == 'sweep' then return {} end
	if template.to == 'office' then return corp.lists.offices end
	if template.to == 'drop' then return corp.lists.drops end
	return rivalDrops(corp, built)
end

--- Whether a corp can run a template at all with the places it has surveyed.
-- @author dop42
-- @param template table
-- @param corp table
-- @param built table
-- @return boolean
function Access.Runnable(template, corp, built)
	if template.corps ~= nil and not template.corps[corp.key] then return false end
	local lists = corp.lists
	if #lists.offices == 0 then return false end
	if template.kind == 'sweep' then return #lists.floors > 0 end
	if template.kind == 'escort' then
		return #lists.pickups > 0 and #lists.destinations > 0 and #corp.records > 0
	end
	if template.kind == 'retrieve' and #lists.terminals == 0 then return false end
	local ends = Access.Ends(template, corp, built)
	-- A courier run to "another office" needs two offices.
	if template.kind == 'deliver' and template.to == 'office' then return #ends >= 2 end
	return #ends > 0
end

--- A whole number between low and high from a roll 0..1.
-- @author dop42
function Access.Between(low, high, roll)
	return low + math.floor(clamp(roll, 0, 0.999999) * (high - low + 1))
end

local function pick(list, roll)
	if #list == 0 then return nil end
	return list[Access.Between(1, #list, roll)]
end
Access.Pick = pick

--- Draws a corp's board: `count` offers out of the templates it can run, each
--- with its pay and its start (terminal, floor or pickup) rolled. Where it ends
--- is decided when it is taken (`Access.Destination`): a board never shows it.
-- @author dop42
-- @param corp table Build().corps[key]
-- @param built table
-- @param count integer
-- @param roll function () -> 0..1
-- @param serial integer the first offer number
-- @return table[] offers
function Access.Generate(corp, built, count, roll, serial)
	local pool, total = {}, 0
	local names = {}
	for name in pairs(built.templates) do names[#names + 1] = name end
	table.sort(names)
	for _, name in ipairs(names) do
		local template = built.templates[name]
		if template.weight > 0 and Access.Runnable(template, corp, built) then
			pool[#pool + 1] = template
			total = total + template.weight
		end
	end
	local offers = {}
	if #pool == 0 then return offers end
	for index = 1, count do
		local target = clamp(roll(), 0, 0.999999) * total
		local template = pool[#pool]
		for _, candidate in ipairs(pool) do
			if target < candidate.weight then template = candidate; break end
			target = target - candidate.weight
		end
		local from = nil
		if template.kind == 'retrieve' then from = pick(corp.lists.terminals, roll())
		elseif template.kind == 'sweep' then from = pick(corp.lists.floors, roll())
		elseif template.kind == 'escort' then from = pick(corp.lists.pickups, roll()) end
		local pay = Access.Between(template.pay[1], template.pay[2], roll())
		offers[#offers + 1] = {
			id = ('%s-%d'):format(corp.key, (serial or 0) + index),
			corp = corp.key, template = template.name, kind = template.kind,
			label = template.label, brief = template.brief,
			minGrade = template.minGrade, minStanding = template.minStanding,
			pay = math.floor(pay * corp.payMult + 0.5), standing = template.standing, loss = template.loss,
			deadlineS = template.deadlineS, item = template.item, stealable = template.stealable,
			holdMs = template.holdMs, durationMs = template.durationMs, reach = template.reach,
			from = from,
			record = template.kind == 'escort' and pick(corp.records, roll()) or nil,
		}
	end
	return offers
end

--- Where a taken offer ends: another office than the one it was taken at for
--- a courier run, a drop, a rival's drop or a destination. nil for a sweep.
-- @author dop42
-- @param offer table
-- @param corp table
-- @param built table
-- @param atOffice string|nil the office it was taken at
-- @param roll number 0..1
-- @return table|nil place
function Access.Destination(offer, corp, built, atOffice, roll)
	local template = built.templates[offer.template]
	if template == nil or template.kind == 'sweep' then return nil end
	local ends = Access.Ends(template, corp, built)
	if template.kind == 'deliver' and template.to == 'office' then
		local others = {}
		for _, place in ipairs(ends) do
			if place.key ~= atOffice then others[#others + 1] = place end
		end
		ends = others
	end
	return pick(ends, roll)
end

--- Whether a grade and a standing may take an offer, and if not why.
-- @author dop42
-- @param offer table
-- @param grade number
-- @param standing number
-- @return boolean
-- @return string|nil grade_too_low | standing_too_low
function Access.Eligible(offer, grade, standing)
	if (grade or -1) < offer.minGrade then return false, 'grade_too_low' end
	if (standing or 0) < offer.minStanding then return false, 'standing_too_low' end
	return true, nil
end

--- What an offer pays an employee of a grade, in whole eddies.
-- @author dop42
-- @param pay integer the offer's pay
-- @param grade number
-- @param built table
-- @return integer
function Access.Pay(pay, grade, built)
	local factor = built.payByGrade[math.tointeger(grade) or 0] or 1
	return math.max(0, math.floor(pay * factor + 0.5))
end

-- ── standing and the quarter ────────────────────────────────────────────────

--- The quarter a wall-clock second falls in.
-- @author dop42
-- @param nowS number
-- @param days integer
-- @return integer
function Access.Quarter(nowS, days)
	return math.floor((finiteNumber(nowS) or 0) / (days * 86400))
end

--- One corp's record out of a character's `corpo` metadata, normalised and
--- rolled over to the quarter: `{ s, done, failed, q, qDone, qPaid }`. A copy.
-- @author dop42
-- @param metadata table|nil the whole `corpo` metadata
-- @param corp string
-- @param quarter integer
-- @return table
function Access.Record(metadata, corp, quarter)
	local raw = type(metadata) == 'table' and type(metadata[corp]) == 'table' and metadata[corp] or {}
	local record = {
		s = math.floor(finiteNumber(raw.s) or 0),
		done = math.max(0, math.floor(finiteNumber(raw.done) or 0)),
		failed = math.max(0, math.floor(finiteNumber(raw.failed) or 0)),
		q = math.floor(finiteNumber(raw.q) or quarter),
		qDone = math.max(0, math.floor(finiteNumber(raw.qDone) or 0)),
		qPaid = raw.qPaid == true,
	}
	if record.q ~= quarter then record.q, record.qDone, record.qPaid = quarter, 0, false end
	return record
end

--- Moves a record's standing by `delta`, inside MIN..MAX. Answers the record.
-- @author dop42
-- @param record table Access.Record()
-- @param delta number
-- @param built table
-- @return table
function Access.Move(record, delta, built)
	record.s = math.floor(clamp(record.s + delta, built.standing.min, built.standing.max))
	return record
end

--- A success counted: standing, totals, and whether this one met the quarterly
--- target for the first time (the bonus is owed).
-- @author dop42
-- @param record table
-- @param gain number
-- @param built table
-- @return table record
-- @return boolean bonus owed
function Access.Succeed(record, gain, built)
	Access.Move(record, gain, built)
	record.done = record.done + 1
	record.qDone = record.qDone + 1
	local owed = built.quarter.target > 0 and built.quarter.bonus > 0 and not record.qPaid
		and record.qDone >= built.quarter.target
	return record, owed
end

--- A failure counted.
-- @author dop42
function Access.Fail(record, loss, built)
	Access.Move(record, -loss, built)
	record.failed = record.failed + 1
	return record
end

-- ── the mint ────────────────────────────────────────────────────────────────

--- Whether `amount` more may be minted in the hour `hour`, against a window
--- `{ hour, spent }` and a cap. Answers the window it would leave (a copy).
-- @author dop42
-- @param window table|nil
-- @param hour integer
-- @param cap integer
-- @param amount integer (negative gives back)
-- @return boolean
-- @return table window
function Access.Mint(window, hour, cap, amount)
	local spent = (type(window) == 'table' and window.hour == hour) and (window.spent or 0) or 0
	if amount > 0 and spent + amount > cap then return false, { hour = hour, spent = spent } end
	return true, { hour = hour, spent = math.max(0, spent + amount) }
end

-- ── the enclaves ────────────────────────────────────────────────────────────

--- Whether a point `{ x, y, z, bucket }` stands inside a place.
-- @author dop42
-- @param at table
-- @param place table
-- @param slack number|nil metres added to the radius
-- @return boolean
function Access.Inside(at, place, slack)
	if type(at) ~= 'table' or at.bucket ~= place.bucket then return false end
	local dx, dy, dz = at.x - place.x, at.y - place.y, at.z - place.z
	local reach = place.radius + (slack or 0)
	return dx * dx + dy * dy + dz * dz <= reach * reach
end

--- The job requirement an enclave gates on: its JOBS, or the corp's job at 0.
-- @author dop42
-- @param enclave table
-- @param corp table
-- @return table
function Access.EnclaveRequirement(enclave, corp)
	local jobs = type(enclave.jobs) == 'table' and next(enclave.jobs) ~= nil and enclave.jobs or { [corp.job] = 0 }
	return { jobs = jobs, onDuty = enclave.onDuty }
end

--- Whether a thief's corp may rob a victim's corp.
-- @author dop42
-- @param thief table corp
-- @param victim table corp
-- @param built table
-- @return boolean
function Access.MayRob(thief, victim, built)
	if thief == nil or victim == nil or thief.key == victim.key then return false end
	if built.espionage.rivalsOnly then return thief.rivals[victim.key] == true end
	return true
end

--- One corp alone, for a client that builds one corp a resume. nil for a
--- disabled or refused corp.
-- @author dop42
-- @param name string
-- @param raw table
-- @return table|nil
function Access.Corp(name, raw)
	if type(raw) ~= 'table' or raw.ENABLED == false then return nil end
	return (corpOf(name, raw, {}, {}))
end
