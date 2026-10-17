--- Config reads, the boot validator, and every rule a licence or a record is decided on.
-- @author dop42
--
-- PURE, like `modules/hauling/shared/access.lua`: not one host call. Every
-- function takes what it needs as arguments -- the config table, the wall
-- clock, the rows -- so the server calls it in a handler and the suite drives
-- it to every branch without a world.
--
-- `Read` turns the operator's config into the shapes the two halves read and
-- answers what it refused. A BAD ENTRY IS REFUSED ALONE: a typo in one licence
-- must not close City Hall. A desk at three exact zeros is not refused but
-- DISABLED until somebody surveys it, and named so.

local M = OPX.Modules.Get('justice')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 48
local DAY_S = 86400
Access.MAX_KEY = MAX_KEY
Access.DAY_S = DAY_S

local function key(value)
	return type(value) == 'string' and #value >= 1 and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
end
Access.Key = key

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' or #value > (maximum or 96) then return nil end
	return value
end

local function integer(value, low, high)
	value = finiteNumber(value)
	if value == nil or value % 1 ~= 0 or value < low or value > high then return nil end
	return math.tointeger(value)
end
Access.Integer = integer

--- Whether a point is the unfilled blank: all three axes exactly zero.
-- @author dop42
-- @param point table|nil
-- @return boolean
function Access.IsPlaceholder(point)
	if type(point) ~= 'table' then return false end
	return coordinate(point.X) == 0.0 and coordinate(point.Y) == 0.0 and coordinate(point.Z) == 0.0
end

-- ── the roles ───────────────────────────────────────────────────────────────

local function roleOf(raw, where, problems)
	if type(raw) ~= 'table' or type(raw.JOBS) ~= 'table' or next(raw.JOBS) == nil then
		-- A role with no job would be PUBLIC through the job gate: closed instead.
		problems[#problems + 1] = where .. ': a JOBS block is required; the role is closed'
		return nil
	end
	local before = #problems
	OPX.JobGate.Problems(raw.JOBS, where, problems)
	if #problems > before then return nil end
	return { jobs = raw.JOBS, onDuty = raw.ON_DUTY == true }
end

-- ── the blocks ──────────────────────────────────────────────────────────────

local function desksOf(raw, problems, placeholders)
	local desks, list = {}, {}
	for name, desk in pairs(type(raw) == 'table' and raw or {}) do
		local where = 'CITY_HALLS.' .. tostring(name)
		local point = type(desk) == 'table' and desk.DESK or nil
		if not key(name) or type(point) ~= 'table' then
			problems[#problems + 1] = where .. ': a key and a DESK = { X, Y, Z }'
		elseif Access.IsPlaceholder(point) then
			placeholders[#placeholders + 1] = name
		else
			local x, y, z = coordinate(point.X), coordinate(point.Y), coordinate(point.Z)
			if x == nil or y == nil or z == nil then
				problems[#problems + 1] = where .. '.DESK: X, Y and Z must be finite numbers'
			else
				local entry = {
					key = name, label = text(desk.LABEL) or name, x = x, y = y, z = z,
					radius = finiteNumber(desk.RADIUS) ~= nil and math.max(0.5, math.min(10, desk.RADIUS)) or 2.0,
					bucket = integer(desk.BUCKET, 0, 2147483647) or 0,
				}
				desks[name] = entry
				list[#list + 1] = entry
			end
		end
	end
	table.sort(list, function(a, b) return a.key < b.key end)
	table.sort(placeholders)
	return desks, list
end

local function licencesOf(raw, problems)
	local out, list = {}, {}
	for kind, row in pairs(type(raw) == 'table' and raw or {}) do
		local fee = type(row) == 'table' and integer(row.FEE, 0, 100000000) or nil
		local days = type(row) == 'table' and integer(row.DAYS == nil and 0 or row.DAYS, 0, 3650) or nil
		if not key(kind) or fee == nil or days == nil then
			problems[#problems + 1] = ('LICENCES.%s: a key, FEE 0.. and DAYS 0..3650'):format(tostring(kind))
		else
			local entry = { kind = kind, label = text(row.LABEL) or kind, fee = fee, days = days,
				clean = row.CLEAN == true, order = finiteNumber(row.ORDER) or 100 }
			out[kind] = entry
			list[#list + 1] = entry
		end
	end
	table.sort(list, function(a, b)
		if a.order ~= b.order then return a.order < b.order end
		return a.kind < b.kind
	end)
	return out, list
end

local function crimesOf(raw, problems)
	local out, list = {}, {}
	for code, row in pairs(type(raw) == 'table' and raw or {}) do
		local fine = type(row) == 'table' and integer(row.FINE or 0, 0, 100000000) or nil
		local jail = type(row) == 'table' and integer(row.JAIL or 0, 0, 100000) or nil
		if not key(code) or fine == nil or jail == nil then
			problems[#problems + 1] = ('CRIMES.%s: a key, FINE 0.. and JAIL 0.. (minutes)'):format(tostring(code))
		else
			local entry = { code = code, label = text(row.LABEL) or code, fine = fine, jail = jail,
				felony = row.FELONY == true }
			out[code] = entry
			list[#list + 1] = entry
		end
	end
	table.sort(list, function(a, b) return a.code < b.code end)
	return out, list
end

local function accountOf(raw, problems)
	if raw == false or raw == nil then return nil end
	if type(raw) ~= 'table' or (raw.KIND ~= 'job' and raw.KIND ~= 'gang') or not key(raw.KEY) then
		problems[#problems + 1] = "CITY_ACCOUNT: { KIND = 'job'|'gang', KEY = <name> } or false; the money is burned"
		return nil
	end
	return { kind = raw.KIND, key = raw.KEY }
end

--- Reads the whole config into the shapes both halves use.
-- @author dop42
-- @param cfg table OPX.Config.MODULES.justice
-- @return table S, with `problems` and `placeholders`
function Access.Read(cfg)
	cfg = type(cfg) == 'table' and cfg or {}
	local problems, placeholders = {}, {}
	local S = { problems = problems, placeholders = placeholders }
	S.police = roleOf(cfg.POLICE, 'POLICE', problems)
	S.lawyer = roleOf(cfg.LAWYER, 'LAWYER', problems)
	S.judge = roleOf(cfg.JUDGE, 'JUDGE', problems)
	S.membership = cfg.MEMBERSHIP == 'any' and 'any' or 'primary'
	S.account = accountOf(cfg.CITY_ACCOUNT, problems)
	S.money = (cfg.MONEY == 'EDDIES') and 'EDDIES' or 'BANK'
	S.desks, S.deskList = desksOf(cfg.CITY_HALLS, problems, placeholders)
	S.licences, S.licenceList = licencesOf(cfg.LICENCES, problems)
	S.crimes, S.crimeList = crimesOf(cfg.CRIMES, problems)
	S.cleanDays = integer(cfg.CLEAN_DAYS, 0, 3650) or 30
	local card = type(cfg.CARD_ITEM) == 'table' and cfg.CARD_ITEM or {}
	S.card = nil
	if card.NAME ~= false and card.NAME ~= nil then
		if key(card.NAME) then
			S.card = { name = card.NAME, label = text(card.LABEL) or 'Licence card',
				weight = integer(card.WEIGHT, 0, 100000) or 10, description = text(card.DESCRIPTION, 160) }
		else
			problems[#problems + 1] = 'CARD_ITEM.NAME: an item name, or false for no card'
		end
	end
	S.recordRows = integer(cfg.RECORD_ROWS, 1, 30) or 30
	S.maxFine = integer(cfg.MAX_FINE, 0, 100000000) or 1000000
	S.maxJail = integer(cfg.MAX_JAIL, 0, 100000) or 600
	S.maxBail = integer(cfg.MAX_BAIL, 0, 100000000) or 1000000
	S.lawyerReach = finiteNumber(cfg.LAWYER_REACH) ~= nil and math.max(1, math.min(20, cfg.LAWYER_REACH)) or 3.0
	S.consentMs = integer(cfg.CONSENT_MS, 5000, 300000) or 30000
	S.maxClients = integer(cfg.MAX_CLIENTS, 1, 30) or 30
	S.maxCases = integer(cfg.MAX_CASES, 1, 30) or 30
	return S
end

--- The validator's lines for a config, the boot log's input.
-- @author dop42
-- @param cfg table
-- @return string[]
function Access.Problems(cfg)
	return Access.Read(cfg).problems
end

-- ── licences ────────────────────────────────────────────────────────────────

--- When a licence bought now runs out: 0 for one that never does.
-- @author dop42
-- @param licence table a row of S.licences
-- @param nowS number unix seconds
-- @return integer
function Access.Expiry(licence, nowS)
	if licence.days == 0 then return 0 end
	return math.floor(nowS) + licence.days * DAY_S
end

--- The state of one held licence: 'valid', 'expired' or 'none'.
-- @author dop42
-- @param held table|nil the metadata line { issued, expires, serial, by }
-- @param nowS number
-- @return string
function Access.State(held, nowS)
	if type(held) ~= 'table' then return 'none' end
	local expires = finiteNumber(held.expires) or 0
	if expires ~= 0 and expires <= nowS then return 'expired' end
	return 'valid'
end

--- The licences metadata as a clean table, whatever was stored.
-- @author dop42
-- @param raw any
-- @return table kind -> { issued, expires, serial, by }
function Access.Held(raw)
	local out = {}
	if type(raw) ~= 'table' then return out end
	for kind, line in pairs(raw) do
		if key(kind) and type(line) == 'table' then
			out[kind] = { issued = finiteNumber(line.issued) or 0, expires = finiteNumber(line.expires) or 0,
				serial = type(line.serial) == 'string' and line.serial or nil,
				by = type(line.by) == 'string' and line.by or nil }
		end
	end
	return out
end

--- Whether a record lets its citizen buy a CLEAN licence.
-- @author dop42
-- @param rows table[] record rows { kind, felony, expunged, active, at }
-- @param nowS number
-- @param cleanDays integer
-- @return boolean
-- @return string|nil 'warrant_active' | 'record_felony'
function Access.Clean(rows, nowS, cleanDays)
	if type(rows) ~= 'table' then return false, 'unavailable' end
	local since = nowS - (cleanDays or 0) * DAY_S
	local felony = false
	for _, row in ipairs(type(rows) == 'table' and rows or {}) do
		if not row.expunged then
			if row.kind == M.Kind.WARRANT and row.active then return false, 'warrant_active' end
			if row.felony and (finiteNumber(row.at) or 0) >= since then felony = true end
		end
	end
	if felony then return false, 'record_felony' end
	return true, nil
end

-- ── the record ──────────────────────────────────────────────────────────────

local SOURCES = { police = true, court = true, staff = true, other = true }

--- Cleans one entry a caller asked to write, or answers why not.
-- Used by the contract (the police write through it) and by the court.
-- @author dop42
-- @param S table
-- @param raw table { code, label?, kind?, fine?, jail?, officer?, officerName?, notes?, source?, paid?, felony? }
-- @return table|nil the entry
-- @return string|nil why
function Access.Entry(S, raw)
	if type(raw) ~= 'table' then return nil, 'invalid' end
	local kind = raw.kind == nil and M.Kind.OFFENCE or raw.kind
	if kind ~= M.Kind.OFFENCE and kind ~= M.Kind.VERDICT and kind ~= M.Kind.WARRANT then
		return nil, 'bad_kind'
	end
	local code = raw.code
	if kind == M.Kind.WARRANT and code == nil then code = 'warrant' end
	if not key(code) then return nil, 'bad_code' end
	local crime = S.crimes[code]
	local fine = raw.fine == nil and 0 or integer(raw.fine, 0, S.maxFine)
	local jail = raw.jail == nil and 0 or integer(raw.jail, 0, S.maxJail)
	local bail = raw.bail == nil and 0 or integer(raw.bail, 0, S.maxBail)
	if fine == nil or jail == nil or bail == nil then return nil, 'bad_amount' end
	local officer = raw.officer
	if officer ~= nil and (type(officer) ~= 'string' or #officer > 16) then return nil, 'bad_officer' end
	local source = SOURCES[raw.source] and raw.source or 'other'
	local felony = raw.felony
	if felony == nil then felony = crime ~= nil and crime.felony or false end
	return {
		kind = kind, code = code,
		label = OPX.Text.Clean(raw.label, 96) or (crime and crime.label) or code,
		fine = fine, jail = jail, bail = bail,
		officer = officer, officerName = OPX.Text.Clean(raw.officerName, 64),
		notes = OPX.Text.Clean(raw.notes, 255),
		source = source, felony = felony == true,
		paid = raw.paid == true or fine == 0,
		active = kind == M.Kind.WARRANT,
	}, nil
end

--- What a record row may show a viewer: everything but the internals.
-- @author dop42
-- @param row table a stored row
-- @return table
function Access.View(row)
	return {
		id = row.id, kind = row.kind, code = row.code, label = row.label, fine = row.fine, jail = row.jail,
		bail = row.bail, officerName = row.officerName, notes = row.notes, source = row.source,
		felony = row.felony, paid = row.paid, active = row.active, expunged = row.expunged,
		expunge = row.expunge, at = row.at,
	}
end

--- A money amount a form sent, as an integer in 0..maximum, or nil.
-- @author dop42
function Access.Amount(value, maximum)
	if type(value) == 'string' then
		if #value > 12 or not value:match('^%d+$') then return nil end
		value = tonumber(value)
	end
	return integer(value, 0, maximum)
end
