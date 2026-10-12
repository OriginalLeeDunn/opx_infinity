--- Config reads, the rules of a bill, and the boot validator, for both halves.
-- @author dop42
--
-- PURE: not one host call in this file. The split, the bounds, who may bill and
-- the shape of a company account are arithmetic over the config table and plain
-- records, which is what makes them testable off-platform and lets the server
-- name a bad config at boot before there is a world.
--
-- A VALUE `Problems` REFUSES READS AS ITS SAFEST FLOOR: a job with no ceiling
-- bills nothing, an unknown money type falls back to the default. A bad config
-- is a line at boot, never a raise inside a network handler.

local M = OPX.Modules.Get('invoices')

M.Model = {}
local Model = M.Model

local NAME_PATTERN = '^[%w_%-]+$'
local ACCOUNT_KINDS = { job = true, gang = true }

local function tableOr(value) return type(value) == 'table' and value or {} end

-- A whole number at or above `floor`, or nil.
local function whole(value, floor)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	if number % 1 ~= 0 then return nil end
	number = math.tointeger(number)
	if number == nil or number < (floor or 0) then return nil end
	return number
end

local function moneyTypes()
	local shared = OPX.Config and OPX.Config.SHARED
	return tableOr(shared and shared.MONEY and shared.MONEY.TYPES)
end

local function isMoneyType(value)
	return type(value) == 'string' and moneyTypes()[value] ~= nil
end

local function defaultMoney()
	local shared = OPX.Config and OPX.Config.SHARED
	local default = shared and shared.MONEY and shared.MONEY.DEFAULT
	return type(default) == 'string' and default or 'EDDIES'
end

--- The config, normalised: every number bounded, every job entry checked.
-- @author dop42
-- @param raw table|nil `OPX.Config.MODULES.invoices`
-- @return table settings
function Model.Settings(raw)
	raw = tableOr(raw)
	local s = {}
	s.moneyType = isMoneyType(raw.MONEY_TYPE) and raw.MONEY_TYPE or defaultMoney()
	s.fallbackType = isMoneyType(raw.FALLBACK_TYPE) and raw.FALLBACK_TYPE ~= s.moneyType
		and raw.FALLBACK_TYPE or nil
	s.defaultCut = math.min(100, whole(raw.DEFAULT_CUT_PCT, 0) or 0)
	s.maxAmount = whole(raw.MAX_AMOUNT, 0) or 0
	s.reasonMax = math.max(8, math.min(128, whole(raw.REASON_MAX, 1) or 64))
	local reach = tonumber(raw.REACH)
	s.reach = (reach ~= nil and reach == reach and reach > 0 and reach <= 50) and reach or 5.0
	s.answerTtlS = math.max(5, math.min(600, whole(raw.ANSWER_TTL_S, 1) or 45))
	s.unpaidTtlS = whole(raw.UNPAID_TTL_S, 0) or 0
	s.maxUnpaid = math.min(100, whole(raw.MAX_UNPAID, 0) or 0)
	s.cooldownMs = math.min(600000, whole(raw.ISSUE_COOLDOWN_MS, 0) or 0)
	local commands = tableOr(raw.COMMANDS)
	s.commands = {
		bill = type(commands.BILL) == 'string' and commands.BILL ~= '' and commands.BILL or nil,
		bills = type(commands.BILLS) == 'string' and commands.BILLS ~= '' and commands.BILLS or nil,
	}
	s.jobs = {}
	for name, entry in pairs(tableOr(raw.JOBS)) do
		if type(name) == 'string' and name:match(NAME_PATTERN) and type(entry) == 'table' then
			local ceiling = math.min(s.maxAmount, whole(entry.MAX_AMOUNT, 0) or 0)
			s.jobs[name] = {
				name = name,
				label = type(entry.LABEL) == 'string' and entry.LABEL ~= '' and entry.LABEL or name,
				minGrade = whole(entry.MIN_GRADE, 0) or 0,
				onDuty = entry.ON_DUTY ~= false,
				maxAmount = ceiling,
				cutPct = math.min(100, whole(entry.CUT_PCT, 0) or s.defaultCut),
				account = entry.ACCOUNT == true and { kind = 'job', key = name } or nil,
				source = type(entry.SOURCE) == 'string' and entry.SOURCE:match(NAME_PATTERN)
					and entry.SOURCE or name,
			}
		end
	end
	return s
end

--- Every line the operator should read at boot about this config.
-- @author dop42
-- @param raw table|nil
-- @param jobs table|nil the configured jobs (`config/character.lua` JOBS), to
--   name a billing entry for a job that does not exist
-- @return string[]
function Model.Problems(raw, jobs)
	raw = tableOr(raw)
	local out = {}
	local function say(line) out[#out + 1] = line end
	if not isMoneyType(raw.MONEY_TYPE) then
		say(('MONEY_TYPE %s is not a money type; bills use %s'):format(tostring(raw.MONEY_TYPE),
			defaultMoney()))
	end
	if raw.FALLBACK_TYPE ~= nil and raw.FALLBACK_TYPE ~= false and not isMoneyType(raw.FALLBACK_TYPE) then
		say(('FALLBACK_TYPE %s is not a money type; no fallback'):format(tostring(raw.FALLBACK_TYPE)))
	end
	if (whole(raw.MAX_AMOUNT, 1) or 0) == 0 then say('MAX_AMOUNT is not a positive whole number: no bill can be raised') end
	local cut = whole(raw.DEFAULT_CUT_PCT, 0)
	if cut == nil or cut > 100 then say('DEFAULT_CUT_PCT is not 0..100; 0 is used') end
	if whole(raw.MAX_UNPAID, 1) == nil then say('MAX_UNPAID is 0: an unpaid bill cannot be filed, only paid at once') end
	for name, entry in pairs(tableOr(raw.JOBS)) do
		local label = tostring(name)
		if type(name) ~= 'string' or not name:match(NAME_PATTERN) or type(entry) ~= 'table' then
			say(('JOBS.%s is not a job entry, ignored'):format(label))
		else
			if type(jobs) == 'table' and jobs[name] == nil then
				say(('JOBS.%s names no job of config/character.lua: nobody can bill as it'):format(label))
			end
			if (whole(entry.MAX_AMOUNT, 1) or 0) == 0 then
				say(('JOBS.%s has no MAX_AMOUNT: it cannot bill'):format(label))
			elseif (whole(entry.MAX_AMOUNT, 1) or 0) > (whole(raw.MAX_AMOUNT, 0) or 0) then
				say(('JOBS.%s MAX_AMOUNT is above MAX_AMOUNT; the global ceiling holds'):format(label))
			end
			local own = whole(entry.CUT_PCT, 0)
			if entry.CUT_PCT ~= nil and (own == nil or own > 100) then
				say(('JOBS.%s CUT_PCT is not 0..100'):format(label))
			end
		end
	end
	table.sort(out)
	return out
end

--- Whether a state still has a future (memory keeps these, the rest leave).
-- @author dop42
-- @param state string
-- @return boolean
function Model.IsOpen(state)
	return state == M.State.ASKED or state == M.State.UNPAID or state == M.State.SETTLING
end

--- An amount a bill may ask, or nil and the refusal.
-- @author dop42
-- @param value any
-- @param ceiling integer
-- @return integer|nil
-- @return string|nil bad_amount | over_limit
function Model.Amount(value, ceiling)
	local amount = whole(value, 1)
	if amount == nil then return nil, 'bad_amount' end
	if amount > (ceiling or 0) then return nil, 'over_limit' end
	return amount
end

--- A reason as it is stored and shown: cleaned, cut, never empty.
-- @author dop42
-- @param value any
-- @param maximum integer
-- @return string|nil
function Model.Reason(value, maximum)
	if type(value) ~= 'string' then return nil end
	local clean = OPX.Text.Clean(value, maximum)
	clean = clean and OPX.String.Trim(clean) or nil
	if clean == nil or clean == '' then return nil end
	return clean
end

--- A company account as the contract takes it, or nil.
-- @author dop42
-- @param value any `{ kind = 'job'|'gang', key }`
-- @return table|nil `{ kind, key }`, a fresh copy
function Model.Account(value)
	if type(value) ~= 'table' then return nil end
	local kind, key = value.kind, value.key
	if not ACCOUNT_KINDS[kind] or type(key) ~= 'string' or #key > 48 or not key:match(NAME_PATTERN) then
		return nil
	end
	return { kind = kind, key = key }
end

--- A cut percentage, or the default.
-- @author dop42
-- @param value any
-- @param default integer
-- @return integer|nil nil when a value was given and is not 0..100
function Model.Cut(value, default)
	if value == nil then return default end
	local cut = whole(value, 0)
	if cut == nil or cut > 100 then return nil end
	return cut
end

--- A billing service word (`source` on the bus).
-- @author dop42
-- @param value any
-- @return string|nil
function Model.Source(value)
	if type(value) ~= 'string' or #value > 32 or not value:match('^[%w_%-:%.]+$') then return nil end
	return value
end

--- How a bill splits: the employee's cut and the rest. Without a company
--- account there is no split: the rest IS the employee's and the cut is zero.
-- @author dop42
-- @param amount integer
-- @param cutPct integer 0..100
-- @param hasAccount boolean
-- @return integer cut
-- @return integer rest
function Model.Split(amount, cutPct, hasAccount)
	amount = math.tointeger(amount) or 0
	if not hasAccount then return 0, amount end
	local cut = (amount * math.max(0, math.min(100, math.tointeger(cutPct) or 0))) // 100
	return cut, amount - cut
end

--- Which billing entry a character's PRIMARY job gives them, or nil and why.
-- @author dop42
-- @param settings table `Model.Settings`
-- @param job table|nil PlayerData.job `{ name, onDuty, grade = { level } }`
-- @param jobs table|nil PlayerData.jobs `{ name = level }`; built from `job` when nil
-- @param nowMs number
-- @return table|nil the job entry
-- @return string|nil not_allowed | grade_too_low | off_duty
function Model.Biller(settings, job, jobs, nowMs)
	if type(job) ~= 'table' or type(job.name) ~= 'string' then return nil, 'not_allowed' end
	local entry = settings.jobs[job.name]
	if entry == nil or entry.maxAmount <= 0 then return nil, 'not_allowed' end
	if type(jobs) ~= 'table' then
		local level = type(job.grade) == 'table' and math.tointeger(tonumber(job.grade.level)) or 0
		jobs = { [job.name] = level or 0 }
	end
	-- The grade and the duty are the one gate's, on the PRIMARY job: a corpo
	-- moonlighting as a bartender bills as whatever they are clocked in as.
	local now = tonumber(nowMs) or 0
	local passed, why = OPX.JobGate.Evaluate({ jobs = { [entry.name] = entry.minGrade },
		onDuty = entry.onDuty }, { job = job, jobs = jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = 'primary' })
	if not passed then
		return nil, (why == 'grade_too_low' or why == 'off_duty') and why or 'not_allowed'
	end
	return entry
end
