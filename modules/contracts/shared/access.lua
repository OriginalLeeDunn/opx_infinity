--- Config reads, the rules of a gig, and the boot validator, for both halves.
-- @author dop42
--
-- PURE: not one host call in this file. Everything here is arithmetic over the
-- config table and over plain records, which is what makes the money split, the
-- cred, the visibility and the spec validation testable off-platform, and what
-- lets the server call `Problems` at boot before there is a world.
--
-- A value `Problems` refuses reads as its SAFEST floor: a zero reward ceiling
-- refuses every post, a zero cap posts nothing. A bad config is a line at boot,
-- never a raise inside a network handler.

local M = OPX.Modules.Get('contracts')

M.Access = {}
local Access = M.Access

local Config = type(M.Settings) == 'table' and M.Settings or {}
Access.Config = Config

local finiteNumber = OPX.Math.Finite
local coordinate, integer = OPX.Spots.Coordinate, OPX.Spots.Integer

local function tableOr(value) return type(value) == 'table' and value or {} end
local function int(value, floor) return math.max(floor or 0, integer(value) or 0) end

-- ── the operator numbers, read once ─────────────────────────────────────────

Access.CURRENCY = type(Config.CURRENCY) == 'string' and Config.CURRENCY or 'EDDIES'
Access.COMMANDS = tableOr(Config.COMMANDS)
Access.POSTERS = tableOr(Config.POSTERS)
Access.TAKERS = tableOr(Config.TAKERS)
Access.MEMBERSHIP = Config.MEMBERSHIP == 'any' and 'any' or 'primary'
Access.VALIDATE_GRADE = int(Config.VALIDATE_GRADE)

local cut = tableOr(Config.FIXER_CUT)
Access.CUT_MIN = math.min(100, int(cut.MIN))
Access.CUT_MAX = math.min(100, math.max(Access.CUT_MIN, int(cut.MAX)))
Access.CUT_DEFAULT = math.min(Access.CUT_MAX, math.max(Access.CUT_MIN, int(cut.DEFAULT)))
Access.CUT_STEP = int(cut.STEP, 1)
Access.CUT_BY_GRADE = tableOr(cut.BY_GRADE)

Access.POST_FEE = int(Config.POST_FEE)
Access.FAIL_PENALTY_PCT = math.min(100, int(Config.FAIL_PENALTY_PCT))

local reward = tableOr(Config.REWARD)
Access.REWARD_MIN = int(reward.MIN, 1)
Access.REWARD_MAX = int(reward.MAX)

local deadline = tableOr(Config.DEADLINE_S)
Access.DEADLINE_MAX = int(deadline.MAX)
Access.DEADLINE_DEFAULT = math.min(Access.DEADLINE_MAX, int(deadline.DEFAULT))
Access.DEADLINE_CHOICES = {}
for _, seconds in ipairs(tableOr(deadline.CHOICES)) do
	local value = integer(seconds)
	if value ~= nil and value > 0 and value <= Access.DEADLINE_MAX then
		Access.DEADLINE_CHOICES[#Access.DEADLINE_CHOICES + 1] = value
	end
end
if #Access.DEADLINE_CHOICES == 0 and Access.DEADLINE_DEFAULT > 0 then
	Access.DEADLINE_CHOICES[1] = Access.DEADLINE_DEFAULT
end

Access.ACCEPT_TTL_S = int(Config.ACCEPT_TTL_S)
Access.VALIDATE_TTL_S = int(Config.VALIDATE_TTL_S)
Access.MANUAL_TIMEOUT = Config.MANUAL_TIMEOUT == 'pay' and 'pay' or 'dispute'
Access.MAX_OPEN_PER_POSTER = int(Config.MAX_OPEN_PER_POSTER)
Access.MAX_ACTIVE_PER_MERC = int(Config.MAX_ACTIVE_PER_MERC)
Access.BOARD_LIMIT = math.min(30, int(Config.BOARD_LIMIT, 1))

local text = tableOr(Config.TEXT)
Access.TITLE_MAX = math.min(96, int(text.TITLE_MAX, 8))
Access.BRIEF_MAX = math.min(160, int(text.BRIEF_MAX, 0))

local cred = tableOr(Config.CRED)
Access.CRED_KEY = type(cred.KEY) == 'string' and cred.KEY:match('^[%w_%-]+$') and cred.KEY
	or 'contracts'
Access.CRED_GAIN = tableOr(cred.GAIN)
-- Sorted from the lowest, whatever order the operator wrote them in.
Access.TIERS = {}
for _, tier in ipairs(tableOr(cred.TIERS)) do
	if type(tier) == 'table' and integer(tier.MIN) ~= nil then
		Access.TIERS[#Access.TIERS + 1] = { min = math.max(0, integer(tier.MIN)),
			label = tostring(tier.LABEL or tier.MIN) }
	end
end
table.sort(Access.TIERS, function(a, b) return a.min < b.min end)
if #Access.TIERS == 0 then Access.TIERS[1] = { min = 0, label = '0' } end

Access.SWEEP_MS = int(Config.SWEEP_MS, 250)
Access.MINT_PER_HOUR = int(Config.MINT_PER_HOUR)
Access.TYPES = tableOr(Config.TYPES)

local deliver = tableOr(Access.TYPES.deliver_item)
Access.ITEM = type(deliver.ITEM) == 'string' and deliver.ITEM ~= '' and deliver.ITEM
	or 'contract_package'
Access.DELIVER_REACH = math.max(0, finiteNumber(deliver.REACH) or 3.0)
Access.HOLD_MS = int(tableOr(Access.TYPES.reach_zone).HOLD_MS)

-- ── places ──────────────────────────────────────────────────────────────────

--- Whether a row is the unfilled 0,0,0 blank this config ships with.
-- ALL THREE AXES EXACTLY ZERO: a surveyed position is never three exact zeros.
-- @author dop42
-- @param row table|nil
-- @return boolean
function Access.IsPlaceholder(row)
	if type(row) ~= 'table' then return false end
	return coordinate(row.X) == 0.0 and coordinate(row.Y) == 0.0 and coordinate(row.Z) == 0.0
end

-- A readable point of a config row, or nil (a placeholder reads as nil).
local function point(row)
	if type(row) ~= 'table' or Access.IsPlaceholder(row) then return nil end
	local x, y, z = coordinate(row.X), coordinate(row.Y), coordinate(row.Z)
	if x == nil or y == nil or z == nil then return nil end
	return x, y, z
end

--- One usable drop-off by key, or nil.
-- @author dop42
-- @param key any
-- @return table|nil { key, label, district, x, y, z, radius, bucket, npc? }
function Access.Dropoff(key)
	local row = tableOr(Config.DROPOFFS)[key]
	local x, y, z = point(row)
	if x == nil then return nil end
	local radius = finiteNumber(row.RADIUS)
	if radius == nil or radius <= 0 then return nil end
	local npc = nil
	if type(row.NPC) == 'table' and type(row.NPC.RECORD) == 'string'
		and row.NPC.RECORD:match('^Character%.[%w_]+$') then
		npc = { record = row.NPC.RECORD, yaw = finiteNumber(row.NPC.YAW) or 0.0 }
	end
	return { key = key, label = tostring(row.LABEL or key), district = row.DISTRICT and
		tostring(row.DISTRICT) or nil, x = x, y = y, z = z, radius = radius,
		bucket = integer(row.BUCKET) or 0, npc = npc }
end

--- One usable zone by key, or nil.
-- @author dop42
-- @param key any
-- @return table|nil { key, label, district, x, y, z, radius, bucket }
function Access.Zone(key)
	local row = tableOr(Config.ZONES)[key]
	local x, y, z = point(row)
	if x == nil then return nil end
	local radius = finiteNumber(row.RADIUS)
	if radius == nil or radius <= 0 then return nil end
	return { key = key, label = tostring(row.LABEL or key), district = row.DISTRICT and
		tostring(row.DISTRICT) or nil, x = x, y = y, z = z, radius = radius,
		bucket = integer(row.BUCKET) or 0 }
end

--- One district fixer by key, or nil. A fixer at 0,0,0 has no NPC (`npc` nil)
--- but may still post when GENERATE says so.
-- @author dop42
-- @param key any
-- @return table|nil
function Access.Fixer(key)
	local row = tableOr(Config.FIXERS)[key]
	if type(row) ~= 'table' then return nil end
	local generate = tableOr(row.GENERATE)
	local when = generate.WHEN
	if when ~= 'always' and when ~= 'never' then when = 'no_player_fixer' end
	local x, y, z = point(row)
	local npc = nil
	if x ~= nil and type(row.RECORD) == 'string' and row.RECORD:match('^Character%.[%w_]+$') then
		npc = { record = row.RECORD, yaw = finiteNumber(row.YAW) or 0.0, x = x, y = y, z = z,
			bucket = integer(row.BUCKET) or 0 }
	end
	return {
		key = key, name = tostring(row.NAME or key), district = row.DISTRICT and
			tostring(row.DISTRICT) or nil,
		npc = npc,
		when = when,
		maxOpen = int(generate.MAX_OPEN),
		everyS = int(generate.EVERY_S, 1),
		cutPct = math.min(100, int(generate.CUT_PCT)),
		deadlineS = math.min(math.max(1, Access.DEADLINE_MAX), int(generate.DEADLINE_S, 60)),
		templates = tableOr(row.TEMPLATES),
	}
end

--- Every key of a config table, sorted, so menus and passes are stable.
-- @author dop42
-- @param name string DROPOFFS | ZONES | FIXERS
-- @return string[]
function Access.Keys(name)
	local keys = {}
	for key in pairs(tableOr(Config[name])) do keys[#keys + 1] = tostring(key) end
	table.sort(keys)
	return keys
end

--- Whether an objective type is switched on in the config.
-- @author dop42
-- @param name any
-- @return boolean
function Access.TypeEnabled(name)
	local row = Access.TYPES[name]
	return type(row) == 'table' and row.ENABLED ~= false
end

-- ── money ───────────────────────────────────────────────────────────────────

--- The two shares of a reward: what the merc is paid and the fixer's cut.
-- The cut is ROUNDED DOWN, so a rounding never takes a merc's eddie; the two
-- always add up to the reward, so nothing is minted or lost by a split.
-- @author dop42
-- @param reward integer
-- @param cutPct integer 0..100
-- @return integer merc
-- @return integer cut
function Access.Split(reward, cutPct)
	reward = math.max(0, integer(reward) or 0)
	cutPct = math.min(100, math.max(0, integer(cutPct) or 0))
	local share = reward * cutPct // 100
	return reward - share, share
end

--- The fine a merc owes for a failed or abandoned gig.
-- @author dop42
-- @param reward integer
-- @return integer
function Access.Penalty(reward)
	return math.max(0, integer(reward) or 0) * Access.FAIL_PENALTY_PCT // 100
end

--- The cut bounds a poster of one grade may choose from.
-- @author dop42
-- @param grade integer|nil
-- @return integer low
-- @return integer high
function Access.CutBounds(grade)
	local ceiling = integer(Access.CUT_BY_GRADE[integer(grade) or -1])
	local high = Access.CUT_MAX
	if ceiling ~= nil then high = math.max(Access.CUT_MIN, math.min(high, ceiling)) end
	return Access.CUT_MIN, high
end

-- ── street cred ─────────────────────────────────────────────────────────────

--- A cred record as stored, coerced: `{ cred, done, failed }`.
-- @author dop42
-- @param record any
-- @return table
function Access.CredRecord(record)
	record = tableOr(record)
	return {
		cred = math.max(0, integer(record.cred) or 0),
		done = math.max(0, integer(record.done) or 0),
		failed = math.max(0, integer(record.failed) or 0),
	}
end

--- The record after one ending. Never below zero cred.
-- @author dop42
-- @param record any
-- @param outcome string done | failed | abandoned
-- @return table
function Access.CredAfter(record, outcome)
	local out = Access.CredRecord(record)
	local gain = integer(Access.CRED_GAIN[outcome]) or 0
	out.cred = math.max(0, out.cred + gain)
	if outcome == 'done' then out.done = out.done + 1 else out.failed = out.failed + 1 end
	return out
end

--- The tier a cred value reaches: its index and its label.
-- @author dop42
-- @param cred any
-- @return integer index
-- @return string label
function Access.Tier(cred)
	cred = math.max(0, integer(cred) or 0)
	local index = 1
	for at = 1, #Access.TIERS do
		if cred >= Access.TIERS[at].min then index = at end
	end
	return index, Access.TIERS[index].label
end

--- The cred a tier index asks for.
-- @author dop42
-- @param index any
-- @return integer|nil
function Access.TierMin(index)
	local tier = Access.TIERS[integer(index) or 0]
	return tier and tier.min or nil
end

-- ── the gig itself ──────────────────────────────────────────────────────────

local STATE = M.State

-- The edges of the state graph. Anything else is refused by `Allowed`, which the
-- server asks before every write, so a bug elsewhere cannot walk a paid gig back
-- to posted.
local EDGES = {
	[STATE.LOCKING] = { [STATE.POSTED] = true, [STATE.CANCELLED] = true, [STATE.SETTLING] = true },
	[STATE.POSTED] = { [STATE.ACCEPTED] = true, [STATE.SETTLING] = true },
	[STATE.ACCEPTED] = { [STATE.IN_PROGRESS] = true, [STATE.POSTED] = true,
		[STATE.SETTLING] = true },
	[STATE.IN_PROGRESS] = { [STATE.PROOF] = true, [STATE.SETTLING] = true },
	[STATE.PROOF] = { [STATE.SETTLING] = true, [STATE.DISPUTED] = true },
	[STATE.DISPUTED] = { [STATE.SETTLING] = true },
	[STATE.SETTLING] = { [STATE.PAID] = true, [STATE.FAILED] = true, [STATE.EXPIRED] = true,
		[STATE.CANCELLED] = true },
}

--- Whether a gig may go from one state to another.
-- @author dop42
-- @param from string
-- @param to string
-- @return boolean
function Access.Allowed(from, to)
	local edges = EDGES[from]
	return edges ~= nil and edges[to] == true
end

-- The states in which a gig is still somebody's business.
local OPEN = { [STATE.LOCKING] = true, [STATE.POSTED] = true, [STATE.ACCEPTED] = true,
	[STATE.IN_PROGRESS] = true, [STATE.PROOF] = true, [STATE.SETTLING] = true,
	[STATE.DISPUTED] = true }

--- Whether a state is not yet final.
-- @author dop42
-- @param state string
-- @return boolean
function Access.IsOpen(state) return OPEN[state] == true end

-- The states a merc is "working" in, for MAX_ACTIVE_PER_MERC.
local WORKING = { [STATE.ACCEPTED] = true, [STATE.IN_PROGRESS] = true, [STATE.PROOF] = true }

--- Whether a gig in this state counts against its merc.
-- @author dop42
-- @param state string
-- @return boolean
function Access.IsWorking(state) return WORKING[state] == true end

--- Whether a viewer may see a gig on the board.
-- Posted gigs only; never the viewer's own; never one above their tier.
-- @author dop42
-- @param contract table
-- @param viewer table { citizenId, cred }
-- @return boolean
function Access.Visible(contract, viewer)
	if type(contract) ~= 'table' or contract.state ~= STATE.POSTED then return false end
	if type(viewer) ~= 'table' then return false end
	if contract.posterCid ~= nil and contract.posterCid == viewer.citizenId then return false end
	return (integer(viewer.cred) or 0) >= (integer(contract.minCred) or 0)
end

--- Display text from a client: control characters blanked, mended, trimmed,
--- cut. Nil when nothing is left.
-- @author dop42
-- @param value any
-- @param maximum integer
-- @return string|nil
function Access.Text(value, maximum)
	if type(value) ~= 'string' then return nil end
	local clean = OPX.Text.Clean(value, maximum)
	if clean == nil then return nil end
	clean = OPX.String.Trim(clean)
	if clean == '' then return nil end
	return clean
end

--- Validates a posting spec into the record the server stores, or a refusal.
--
-- THE ONE VALIDATOR every door goes through: the form a player sent, a district
-- fixer's template and another module's `Post` all land here, so a gig the
-- board shows was checked by the same rules whoever wrote it.
--
-- `objective` is checked by the type's own validator, handed in by the server
-- (the registry is server state); a validator answers the normalized objective
-- or nil and a code.
-- @author dop42
-- @param spec table { type, title, brief?, reward, cutPct?, deadlineS?, minCred?,
--   objective, validate? }
-- @param context table { cutLow, cutHigh, objective = function(type, objective) }
-- @return table|nil the normalized spec
-- @return string|nil the refusal code
function Access.NormalizeSpec(spec, context)
	if type(spec) ~= 'table' then return nil, 'bad_spec' end
	context = tableOr(context)
	local kind = spec.type
	if type(kind) ~= 'string' then return nil, 'bad_type' end

	local title = Access.Text(spec.title, Access.TITLE_MAX)
	if title == nil then return nil, 'bad_title' end
	local brief = nil
	if spec.brief ~= nil and spec.brief ~= '' then
		brief = Access.Text(spec.brief, Access.BRIEF_MAX)
	end

	local amount = integer(spec.reward)
	if amount == nil or amount < Access.REWARD_MIN or amount > Access.REWARD_MAX then
		return nil, 'bad_reward'
	end

	local low = integer(context.cutLow) or Access.CUT_MIN
	local high = integer(context.cutHigh) or Access.CUT_MAX
	local cutPct = spec.cutPct == nil and math.min(high, math.max(low, Access.CUT_DEFAULT))
		or integer(spec.cutPct)
	if cutPct == nil or cutPct < low or cutPct > high then return nil, 'bad_cut' end

	local seconds = spec.deadlineS == nil and Access.DEADLINE_DEFAULT or integer(spec.deadlineS)
	if seconds == nil or seconds < 60 or seconds > Access.DEADLINE_MAX then
		return nil, 'bad_deadline'
	end

	local minCred = spec.minCred == nil and 0 or integer(spec.minCred)
	if minCred == nil or minCred < 0 then return nil, 'bad_cred' end

	local validate = spec.validate
	if validate == nil then validate = kind == 'manual' and 'manual' or 'auto' end
	if validate ~= 'auto' and validate ~= 'manual' and validate ~= 'ext' then
		return nil, 'bad_validate'
	end

	local objective, why = {}, nil
	if type(context.objective) == 'function' then
		objective, why = context.objective(kind, spec.objective)
		if objective == nil then return nil, why or 'bad_objective' end
	end

	return {
		type = kind, title = title, brief = brief, reward = amount, cutPct = cutPct,
		deadlineS = seconds, minCred = minCred, validate = validate, objective = objective,
	}
end

--- What one gig looks like on a board: no position, ever.
-- The merc learns where to go when they take it, and nobody else learns it at
-- all -- the board is the one place every merc in the city reads.
-- @author dop42
-- @param contract table
-- @param describe function|nil (type, objective) -> label, district
-- @return table
function Access.Public(contract, describe)
	local label, district = nil, nil
	if type(describe) == 'function' then label, district = describe(contract.type,
		contract.objective) end
	local merc = Access.Split(contract.reward, contract.cutPct)
	return {
		id = contract.id, type = contract.type, title = contract.title, brief = contract.brief,
		reward = contract.reward, pay = merc, cutPct = contract.cutPct,
		minCred = contract.minCred, state = contract.state,
		-- A player's RP name is not public merely because they posted a gig.
		poster = contract.posterKind == M.Poster.PLAYER and contract.posterCid or contract.posterName,
		target = label, district = district, validate = contract.validate,
	}
end

--- A deterministic pick from a list, by seed. Same seed, same pick: a district
--- fixer's gig is reproducible from its sequence number.
-- @author dop42
-- @param seed integer
-- @param count integer
-- @return integer 1..count
function Access.Pick(seed, count)
	count = math.max(1, integer(count) or 1)
	seed = math.abs(integer(seed) or 0)
	return (seed * 2654435761) % 4294967296 % count + 1
end

--- A reward inside a template's band, by seed.
-- @author dop42
-- @param band table|nil { MIN, MAX }
-- @param seed integer
-- @return integer
function Access.RewardIn(band, seed)
	band = tableOr(band)
	local low = math.max(Access.REWARD_MIN, integer(band.MIN) or Access.REWARD_MIN)
	local high = math.min(Access.REWARD_MAX, math.max(low, integer(band.MAX) or low))
	return low + Access.Pick(seed * 31 + 7, high - low + 1) - 1
end

-- ── boot validation ─────────────────────────────────────────────────────────

--- Every complaint the configuration earns, as log lines. Names the entry.
-- @author dop42
-- @return string[]
function Access.Problems()
	local lines = {}
	OPX.JobGate.Problems(Access.POSTERS.JOBS, 'POSTERS', lines)
	OPX.JobGate.Problems(Access.TAKERS.JOBS, 'TAKERS', lines)
	OPX.JobGate.GangProblems(Access.POSTERS.GANGS, 'POSTERS', lines)
	OPX.JobGate.GangProblems(Access.TAKERS.GANGS, 'TAKERS', lines)
	if (type(Access.POSTERS.JOBS) ~= 'table' or next(Access.POSTERS.JOBS) == nil)
		and (type(Access.POSTERS.GANGS) ~= 'table' or next(Access.POSTERS.GANGS) == nil) then
		lines[#lines + 1] = 'POSTERS.JOBS and POSTERS.GANGS are empty: ANYBODY may post a gig'
	end
	if Access.REWARD_MAX < Access.REWARD_MIN then
		lines[#lines + 1] = 'REWARD.MAX is below REWARD.MIN: every post is refused'
	end
	if Access.DEADLINE_MAX < 60 then
		lines[#lines + 1] = 'DEADLINE_S.MAX must be at least 60 seconds: every post is refused'
	end
	if integer(tableOr(Config.FIXER_CUT).MAX) ~= nil and integer(Config.FIXER_CUT.MAX) > 100 then
		lines[#lines + 1] = 'FIXER_CUT.MAX above 100 is read as 100'
	end
	if Config.MANUAL_TIMEOUT ~= 'pay' and Config.MANUAL_TIMEOUT ~= 'dispute' then
		lines[#lines + 1] = "MANUAL_TIMEOUT must be 'pay' or 'dispute'; reading it as 'dispute'"
	end
	if Access.MAX_ACTIVE_PER_MERC < 1 then
		lines[#lines + 1] = 'MAX_ACTIVE_PER_MERC is zero: no merc can take a gig'
	end
	if Access.ACCEPT_TTL_S < 60 then
		lines[#lines + 1] = 'ACCEPT_TTL_S under 60 seconds: a merc fails before reaching the door'
	end

	local function places(name, read)
		local blanks = {}
		for _, key in ipairs(Access.Keys(name)) do
			local row = Config[name][key]
			if Access.IsPlaceholder(row) then
				blanks[#blanks + 1] = key
			elseif read(key) == nil then
				lines[#lines + 1] = ('%s %s: X, Y, Z must be finite and RADIUS above zero')
					:format(name, key)
			end
		end
		if #blanks > 0 then
			lines[#lines + 1] = ('%s: %d entr%s STILL THE PLACEHOLDER 0,0,0 AND DISABLED -- %s. ' ..
				'Stand on each spot in game and paste your position in'):format(name, #blanks,
				#blanks == 1 and 'y IS' or 'ies ARE', table.concat(blanks, ', '))
		end
	end
	places('DROPOFFS', Access.Dropoff)
	places('ZONES', Access.Zone)

	for _, key in ipairs(Access.Keys('FIXERS')) do
		local fixer = Access.Fixer(key)
		if fixer == nil then
			lines[#lines + 1] = ('FIXERS %s must be a table'):format(key)
		else
			if fixer.npc == nil then
				lines[#lines + 1] = ('FIXERS %s: no NPC stands (placeholder 0,0,0 or no ' ..
					'Character.* RECORD); survey the spot to put one there'):format(key)
			end
			for index, template in ipairs(fixer.templates) do
				local kind = type(template) == 'table' and (template.TYPE or 'deliver_item') or nil
				local read = kind == 'reach_zone' and Access.Zone or Access.Dropoff
				local usable = 0
				for _, target in ipairs(type(template) == 'table' and tableOr(template.TARGETS) or {}) do
					if read(target) ~= nil then usable = usable + 1 end
				end
				if kind ~= 'deliver_item' and kind ~= 'reach_zone' then
					lines[#lines + 1] = ('FIXERS %s template #%d: TYPE must be deliver_item or ' ..
						'reach_zone'):format(key, index)
				elseif usable == 0 then
					lines[#lines + 1] = ('FIXERS %s template #%d: no usable TARGETS yet, so it is ' ..
						'never posted'):format(key, index)
				end
			end
		end
	end
	return lines
end
