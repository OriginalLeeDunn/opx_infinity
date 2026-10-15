--- Config reads, the rank rules, the input validators and the boot validator.
-- @author dop42
--
-- PURE: not one host call in this file. Everything here is arithmetic over the
-- config tables (this module's and the character module's grade tables) and
-- over plain records, which is what makes the rank rule, the caps and the
-- validators testable off-platform, and what lets the server call `Problems`
-- at boot before there is a world. Both halves load it: the client draws the
-- offices and filters the eye rows with the same reads the server re-runs.
--
-- A value `Problems` refuses reads as its SAFEST floor: a bad cap is "no
-- recruiting", a bad grade is "no such grade", a bad office is no office.

local M = OPX.Modules.Get('business')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}
Access.Config = Config

local coordinate = OPX.Spots.Coordinate

-- A whole number, or nil. NOT `OPX.Spots.Integer`, which is bounded by the
-- world box and would read a treasury ceiling of ten million as nothing.
local function integer(value)
	local number = tonumber(value)
	if number == nil or not OPX.Math.IsFinite(number) then return nil end
	return math.tointeger(number)
end
local finiteNumber = OPX.Math.Finite

local function tableOr(value) return type(value) == 'table' and value or {} end
local function int(value, floor) return math.max(floor or 0, integer(value) or 0) end

-- ── the operator numbers, read once ─────────────────────────────────────────

Access.POCKET = type(Config.POCKET) == 'string' and Config.POCKET or 'EDDIES'
Access.COMMANDS = tableOr(Config.COMMANDS)
Access.MEMBERSHIP = Config.MEMBERSHIP == 'any' and 'any' or 'primary'
Access.REQUIRE_OFFICE = Config.REQUIRE_OFFICE == true
Access.OFFICE_RADIUS = math.max(0.5, finiteNumber(Config.OFFICE_RADIUS) or 1.5)
Access.RANK_RULE = Config.RANK_RULE == 'equal' and 'equal' or 'below'

local hire = tableOr(Config.HIRE)
Access.HIRE_RADIUS = math.max(1.0, finiteNumber(hire.RADIUS) or 6.0)
Access.HIRE_TTL_S = math.max(10, int(hire.TTL_S, 0))
Access.HIRE_PRIMARY = hire.PRIMARY ~= false

local accounts = tableOr(Config.ACCOUNTS)
Access.MAX_AMOUNT = int(accounts.MAX_AMOUNT, 1)
Access.HISTORY_MAX = math.min(200, int(accounts.HISTORY_MAX, 1))
Access.HISTORY_SHOWN = math.min(Access.HISTORY_MAX, int(accounts.HISTORY_SHOWN, 0))

Access.ROSTER_SHOWN = math.min(30, int(Config.ROSTER_SHOWN, 1))

local rate = tableOr(Config.RATE)
Access.RATE_REQUESTS = int(rate.REQUESTS, 1)
Access.RATE_WINDOW_MS = int(rate.WINDOW_MS, 100)

Access.DEFAULTS = tableOr(Config.DEFAULTS)

--- The longest reason and operation id the treasury stores, in bytes. Both are
--- the column widths in `server/storage.lua`.
Access.REASON_MAX = 96
Access.OPID_MAX = 80

-- ── the groups: the character module's grade tables ─────────────────────────

--- The JOBS or GANGS table of `config/character.lua`, or an empty table.
-- @author dop42
-- @param kind string 'job' | 'gang'
-- @return table
function Access.Groups(kind)
	local character = tableOr(OPX.Config.MODULES and OPX.Config.MODULES.character)
	if kind == M.Kind.JOB then return tableOr(character.JOBS) end
	if kind == M.Kind.GANG then return tableOr(character.GANGS) end
	return {}
end

--- Whether a kind and key name a group this server defines.
-- @author dop42
-- @param kind any
-- @param key any
-- @return boolean
function Access.ValidGroup(kind, key)
	if type(key) ~= 'string' or #key == 0 or #key > 48 then return false end
	if kind ~= M.Kind.JOB and kind ~= M.Kind.GANG then return false end
	return type(Access.Groups(kind)[key]) == 'table'
end

--- One group's definition, or nil.
local function groupOf(kind, key)
	if not Access.ValidGroup(kind, key) then return nil end
	return Access.Groups(kind)[key]
end

--- The display label of a group: its own `label`, else its key.
-- @author dop42
-- @param kind string
-- @param key string
-- @return string
function Access.Label(kind, key)
	local group = groupOf(kind, key)
	return group and type(group.label) == 'string' and group.label or tostring(key)
end

--- One grade of a group, or nil.
-- @author dop42
-- @param kind string
-- @param key string
-- @param level any
-- @return table|nil
function Access.Grade(kind, key, level)
	local group = groupOf(kind, key)
	level = math.tointeger(tonumber(level))
	if group == nil or level == nil or type(group.grades) ~= 'table' then return nil end
	local grade = group.grades[level]
	return type(grade) == 'table' and grade or nil
end

--- The grades of a group as a list ordered by level: `{ level, name, isBoss,
--- bankAuth }`. Keyed from 0 in the config, and a 0-keyed table does not cross a
--- marshaller as a list -- hence the copy.
-- @author dop42
-- @param kind string
-- @param key string
-- @return table[]
function Access.GradeList(kind, key)
	local group = groupOf(kind, key)
	local out = {}
	if group == nil then return out end
	for level, grade in pairs(tableOr(group.grades)) do
		if math.type(level) == 'integer' and type(grade) == 'table' then
			out[#out + 1] = { level = level, name = tostring(grade.name or level),
				isBoss = grade.isBoss == true, bankAuth = grade.bankAuth == true }
		end
	end
	table.sort(out, function(a, b) return a.level < b.level end)
	return out
end

-- ── the per-group rules ─────────────────────────────────────────────────────

local OFFICES = { job = {}, gang = {} }
local placeholders = {}
local unknown = {}

--- Builds the surveyed offices of one config block, naming the blanks.
local function readOffices(kind, block)
	for key, rules in pairs(tableOr(block)) do
		if type(key) ~= 'string' then goto next end
		if not Access.ValidGroup(kind, key) then
			unknown[#unknown + 1] = ('%sS.%s'):format(kind:upper(), tostring(key))
		end
		do
			local list = {}
			for index, office in ipairs(tableOr(tableOr(rules).OFFICES)) do
				local x, y, z = coordinate(office.X), coordinate(office.Y), coordinate(office.Z)
				local label = type(office.LABEL) == 'string' and office.LABEL or ('#' .. index)
				if x == nil or y == nil or z == nil then
					placeholders[#placeholders + 1] = ('%sS.%s office %d (%s): bad coordinates')
						:format(kind:upper(), key, index, label)
				elseif x == 0 and y == 0 and z == 0 then
					placeholders[#placeholders + 1] = ('%sS.%s office %d "%s" is the PLACEHOLDER 0,0,0 ' ..
						'-- disabled until surveyed'):format(kind:upper(), key, index, label)
				else
					list[#list + 1] = { index = index, label = label, x = x, y = y, z = z,
						radius = math.max(0.5, finiteNumber(office.RADIUS) or Access.OFFICE_RADIUS),
						bucket = int(office.BUCKET, 0) }
				end
			end
			OFFICES[kind][key] = list
		end
		::next::
	end
end
readOffices(M.Kind.JOB, Config.JOBS)
readOffices(M.Kind.GANG, Config.GANGS)

--- The surveyed offices of a group (never a placeholder).
-- @author dop42
-- @param kind string
-- @param key string
-- @return table[]
function Access.Offices(kind, key)
	return tableOr(OFFICES[kind])[key] or {}
end

--- Every surveyed office, as a list of `{ kind, key, office }`.
-- @author dop42
-- @return table[]
function Access.AllOffices()
	local out = {}
	for _, kind in ipairs({ M.Kind.JOB, M.Kind.GANG }) do
		local keys = {}
		for key in pairs(OFFICES[kind]) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do
			for _, office in ipairs(OFFICES[kind][key]) do
				out[#out + 1] = { kind = kind, key = key, office = office }
			end
		end
	end
	return out
end

--- One group's rules, the DEFAULTS filled in.
-- @author dop42
-- @param kind string
-- @param key string
-- @return table { maxEmployees, hireGrade, hirers, duty }
function Access.Rules(kind, key)
	local block = kind == M.Kind.JOB and tableOr(Config.JOBS) or tableOr(Config.GANGS)
	local own = tableOr(block[key])
	local defaults = Access.DEFAULTS
	local function pick(name)
		if own[name] ~= nil then return own[name] end
		return defaults[name]
	end
	local hirers = pick('HIRERS')
	return {
		maxEmployees = int(pick('MAX_EMPLOYEES'), 0),
		hireGrade = int(pick('HIRE_GRADE'), 0),
		hirers = hirers ~= nil and integer(hirers) or nil,
		duty = kind == M.Kind.JOB and pick('DUTY') ~= false,
	}
end

-- ── who may do what ─────────────────────────────────────────────────────────

--- The grade a character snapshot holds in a group, or nil. `primary` reads
--- only the job / gang they are working; `any` every grade they hold.
-- @author dop42
-- @param data table PlayerData (or the same shape)
-- @param kind string
-- @param key string
-- @return integer|nil
function Access.Standing(data, kind, key)
	if type(data) ~= 'table' then return nil end
	local primary = kind == M.Kind.JOB and data.job or data.gang
	if type(primary) == 'table' and primary.name == key then
		local grade = type(primary.grade) == 'table' and primary.grade.level or primary.grade
		return math.tointeger(tonumber(grade)) or 0
	end
	if Access.MEMBERSHIP ~= 'any' then return nil end
	local held = kind == M.Kind.JOB and data.jobs or data.gangs
	if type(held) ~= 'table' or held[key] == nil then return nil end
	return math.tointeger(tonumber(held[key])) or 0
end

--- Whether a grade of a group is a boss grade.
-- @author dop42
function Access.IsBoss(kind, key, level)
	local grade = Access.Grade(kind, key, level)
	return grade ~= nil and grade.isBoss == true
end

--- Whether a grade of a group may move the treasury.
-- @author dop42
function Access.BankAuth(kind, key, level)
	local grade = Access.Grade(kind, key, level)
	return grade ~= nil and grade.bankAuth == true
end

--- Whether a grade of a group may recruit: a boss, or at least HIRERS.
-- @author dop42
function Access.MayHire(kind, key, level)
	level = math.tointeger(tonumber(level))
	if level == nil or Access.Grade(kind, key, level) == nil then return false end
	if Access.IsBoss(kind, key, level) then return true end
	local hirers = Access.Rules(kind, key).hirers
	return hirers ~= nil and level >= hirers
end

--- Whether a grade opens the terminal at all: boss, recruiter or bankAuth.
-- @author dop42
function Access.MayOpen(kind, key, level)
	return Access.IsBoss(kind, key, level) or Access.BankAuth(kind, key, level)
		or Access.MayHire(kind, key, level)
end

--- Whether somebody at `boss` may act on somebody at `target` (fire, promote,
--- demote, clock). Under `below` strictly below; under `equal` up to equal.
-- @author dop42
-- @param boss integer
-- @param target integer
-- @return boolean
function Access.MayManage(boss, target)
	boss, target = math.tointeger(boss), math.tointeger(target)
	if boss == nil or target == nil then return false end
	if Access.RANK_RULE == 'equal' then return target <= boss end
	return target < boss
end

--- Whether somebody at `boss` may hand out grade `level`.
-- @author dop42
function Access.MayGrant(boss, level)
	return Access.MayManage(boss, level)
end

--- The grade one step up (+1) or down (-1) from a level, or nil at the edge.
-- @author dop42
-- @param kind string
-- @param key string
-- @param level integer
-- @param step integer 1 | -1
-- @return integer|nil
function Access.Step(kind, key, level, step)
	level = math.tointeger(tonumber(level))
	if level == nil or (step ~= 1 and step ~= -1) then return nil end
	local next = level + step
	if next < 0 or Access.Grade(kind, key, next) == nil then return nil end
	return next
end

--- Every group a snapshot may open the terminal for, as `{ kind, key, level }`.
-- Jobs first, then gangs, each in name order.
-- @author dop42
-- @param data table PlayerData
-- @return table[]
function Access.Desks(data)
	local out = {}
	if type(data) ~= 'table' then return out end
	for _, kind in ipairs({ M.Kind.JOB, M.Kind.GANG }) do
		local candidates = {}
		local primary = kind == M.Kind.JOB and data.job or data.gang
		if type(primary) == 'table' and type(primary.name) == 'string' then
			candidates[primary.name] = true
		end
		if Access.MEMBERSHIP == 'any' then
			for key in pairs(tableOr(kind == M.Kind.JOB and data.jobs or data.gangs)) do
				if type(key) == 'string' then candidates[key] = true end
			end
		end
		local keys = {}
		for key in pairs(candidates) do keys[#keys + 1] = key end
		table.sort(keys)
		for _, key in ipairs(keys) do
			local level = Access.Standing(data, kind, key)
			if level ~= nil and Access.MayOpen(kind, key, level) then
				out[#out + 1] = { kind = kind, key = key, level = level }
			end
		end
	end
	return out
end

--- Whether a position stands inside one of a group's offices.
-- @author dop42
-- @param kind string
-- @param key string
-- @param at table|nil { x, y, z, bucket? }
-- @param index integer|nil one office only, or any
-- @return boolean
function Access.AtOffice(kind, key, at, index)
	if type(at) ~= 'table' then return false end
	for _, office in ipairs(Access.Offices(kind, key)) do
		if index == nil or office.index == index then
			local dx, dy, dz = at.x - office.x, at.y - office.y, at.z - office.z
			local reach = office.radius + 1.0
			if (at.bucket or 0) == office.bucket and dx * dx + dy * dy + dz * dz <= reach * reach then
				return true
			end
		end
	end
	return false
end

-- ── what crosses a trust boundary ───────────────────────────────────────────

--- A movement amount: a whole number in 1..MAX_AMOUNT, or nil. Text from a form
--- is accepted ("1500"), anything else -- a float, a negative, a NaN -- is not.
-- @author dop42
-- @param value any
-- @return integer|nil
function Access.Amount(value)
	if type(value) == 'string' then
		if #value > 12 or not value:match('^%s*%d+%s*$') then return nil end
		value = tonumber(value)
	end
	local amount = math.tointeger(value)
	if amount == nil or amount < 1 or amount > Access.MAX_AMOUNT then return nil end
	return amount
end

--- An operation id: printable ASCII from a small set, at most OPID_MAX bytes.
-- @author dop42
-- @param value any
-- @return string|nil
function Access.OpId(value)
	if type(value) ~= 'string' or #value == 0 or #value > Access.OPID_MAX then return nil end
	if not value:match('^[%w_:%.%-]+$') then return nil end
	return value
end

--- A reason as the ledger stores it: control characters gone, cut to fit.
-- @author dop42
-- @param value any
-- @return string
function Access.Reason(value)
	local text = OPX.Text.Clean(type(value) == 'string' and value or '', Access.REASON_MAX)
	text = OPX.Text.Bytes(text, Access.REASON_MAX)
	return text ~= '' and text or 'unspecified'
end

--- A citizen id a client sent, or nil. The SHAPE only; who it is, the server
--- reads from the roster.
-- @author dop42
-- @param value any
-- @return string|nil
function Access.CitizenId(value)
	if type(value) ~= 'string' or #value == 0 or #value > 32 then return nil end
	if not value:match('^[%w%-]+$') then return nil end
	return value
end

-- ── the boot validator ──────────────────────────────────────────────────────

--- Every problem in the config, one line each. Placeholders are named too: a
--- disabled office is a line the owner has to read.
-- @author dop42
-- @return string[]
function Access.Problems()
	local lines = {}
	for _, line in ipairs(placeholders) do lines[#lines + 1] = line end
	for _, name in ipairs(unknown) do
		lines[#lines + 1] = ('%s names no group in config/character.lua -- its rules are ignored')
			:format(name)
	end
	if Access.MAX_AMOUNT < 1 then lines[#lines + 1] = 'ACCOUNTS.MAX_AMOUNT is below 1' end
	for _, kind in ipairs({ M.Kind.JOB, M.Kind.GANG }) do
		for key in pairs(Access.Groups(kind)) do
			local rules = Access.Rules(kind, key)
			if Access.Grade(kind, key, rules.hireGrade) == nil then
				lines[#lines + 1] = ('%s %s: HIRE_GRADE %d is not a grade of it -- recruiting refused')
					:format(kind, tostring(key), rules.hireGrade)
			end
		end
	end
	table.sort(lines)
	return lines
end
