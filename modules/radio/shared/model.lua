--- The config reader, the boot validator, and who belongs on which channel.
-- @author dop42
--
-- PURE, like `modules/hauling/shared/access.lua`: not one host call. The
-- server feeds it a character snapshot, a clock and the player's own choices,
-- and it answers which channels they may be on, which they SHOULD be on, and
-- which one their key talks into. A test drives every branch without a world.
--
-- A BAD CHANNEL IS REFUSED ALONE, with a line at boot naming it: a typo in the
-- Militech entry must not take NCPD dispatch off the air.

local M = OPX.Modules.Get('radio')

M.Model = {}
local Model = M.Model

local finiteNumber = OPX.Math.Finite

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 32
Model.MAX_KEY = MAX_KEY
local MAX_LABEL = 64
local MAX_SHORT = 16
-- The platform routes a frame into four channels at most (docs voice#integrated-voice-chat).
local JOIN_CEILING = 4

-- The effect fields the platform takes, with their documented ranges.
local EFFECT_RANGES = {
	gain = { 0.0, 4.0 },
	highPassHz = { 0.0, 20000.0 },
	lowPassHz = { 20.0, 24000.0 },
	distortion = { 0.0, 1.0 },
	radioNoise = { 0.0, 1.0 },
	spatialBlend = { 0.0, 1.0 },
	reverbWet = { 0.0, 1.0 },
	reverbRoomSize = { 0.0, 1.0 },
	reverbDecay = { 0.1, 10.0 },
	reverbDamping = { 0.0, 1.0 },
	reverbPreDelayMs = { 0.0, 250.0 },
}

local function key(value)
	return type(value) == 'string' and #value >= 1 and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
end
Model.Key = key

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' or #value > maximum or value:find('%c') then return nil end
	return value
end

local function integer(value, low, high, fallback)
	value = finiteNumber(value)
	if value == nil or value % 1 ~= 0 or value < low or value > high then return fallback end
	return math.floor(value)
end

local function nonEmpty(value)
	return type(value) == 'table' and next(value) ~= nil
end

--- Reads the effect block, dropping (and naming) any field out of range.
local function readEffect(raw, problems)
	local effect = {}
	if raw == nil then return effect end
	if type(raw) ~= 'table' then
		problems[#problems + 1] = 'EFFECT must be a table of effect fields'
		return effect
	end
	for field, value in pairs(raw) do
		local range = EFFECT_RANGES[field]
		local number = finiteNumber(value)
		if range == nil then
			problems[#problems + 1] = ('EFFECT.%s is not an effect the platform knows'):format(tostring(field))
		elseif number == nil or number < range[1] or number > range[2] then
			problems[#problems + 1] = ('EFFECT.%s must be %s..%s'):format(field, range[1], range[2])
		else
			effect[field] = number
		end
	end
	if effect.highPassHz ~= nil and effect.lowPassHz ~= nil and effect.highPassHz >= effect.lowPassHz then
		problems[#problems + 1] = 'EFFECT.highPassHz must be below EFFECT.lowPassHz: both dropped'
		effect.highPassHz, effect.lowPassHz = nil, nil
	end
	return effect
end

--- Reads one channel entry: the channel, or nil and the reason.
local function readChannel(name, raw)
	local where = 'CHANNELS.' .. tostring(name)
	if not key(name) then return nil, where .. ': the key must be letters, digits, _ or - (32 at most)' end
	if type(raw) ~= 'table' then return nil, where .. ': must be a table' end
	local label = text(raw.LABEL, MAX_LABEL)
	if label == nil then return nil, ('%s: LABEL must be text of 1..%d characters'):format(where, MAX_LABEL) end
	local short = raw.SHORT == nil and name:upper():sub(1, MAX_SHORT) or text(raw.SHORT, MAX_SHORT)
	if short == nil then return nil, ('%s: SHORT must be text of 1..%d characters'):format(where, MAX_SHORT) end

	local lines = OPX.JobGate.Problems(raw.JOBS, where)
	OPX.JobGate.GangProblems(raw.GANGS, where, lines)
	if #lines > 0 then return nil, table.concat(lines, '; ') end
	-- A SERVICE RADIO WITH NO GATE IS A PARTY LINE FOR THE WHOLE CITY, and the
	-- job gate reads an empty block as public. Refused rather than opened.
	if not nonEmpty(raw.JOBS) and not nonEmpty(raw.GANGS) then
		return nil, where .. ': needs JOBS or GANGS (a channel open to everybody is refused)'
	end
	for _, flag in ipairs({ 'ON_DUTY', 'AUTO', 'ENABLED' }) do
		if raw[flag] ~= nil and type(raw[flag]) ~= 'boolean' then
			return nil, ('%s: %s must be true or false'):format(where, flag)
		end
	end

	return {
		key = name,
		label = label,
		short = short,
		jobs = nonEmpty(raw.JOBS) and OPX.Table.DeepCopy(raw.JOBS) or nil,
		gangs = nonEmpty(raw.GANGS) and OPX.Table.DeepCopy(raw.GANGS) or nil,
		onDuty = raw.ON_DUTY == true,
		auto = raw.AUTO == true,
		order = integer(raw.ORDER, -100000, 100000, 1000),
	}, nil, raw.ENABLED == false
end

--- Turns the operator's config into what both halves read.
-- @author dop42
-- @param settings table OPX.Config.MODULES.radio
-- @return table { channels, order, disabled, problems, item, requireItem,
--   talkKey, intent, maxTalkMs, maxJoined, requestMs, talkMs, sweepMs,
--   effect, blockWhenDown }
function Model.Build(settings)
	settings = type(settings) == 'table' and settings or {}
	local problems, disabled = {}, {}
	local built = { channels = {}, order = {}, disabled = disabled, problems = problems }

	local declared = settings.CHANNELS
	if declared ~= nil and type(declared) ~= 'table' then
		problems[#problems + 1] = 'CHANNELS must be a table of key -> channel'
		declared = {}
	end
	for name, raw in pairs(declared or {}) do
		local channel, why, off = readChannel(name, raw)
		if channel == nil then
			problems[#problems + 1] = why
		elseif off then
			disabled[#disabled + 1] = name
		else
			built.channels[name] = channel
			built.order[#built.order + 1] = name
		end
	end
	table.sort(built.order, function(a, b)
		local ca, cb = built.channels[a], built.channels[b]
		if ca.order ~= cb.order then return ca.order < cb.order end
		return a < b
	end)
	table.sort(disabled)

	-- The handset.
	built.requireItem = settings.REQUIRE_ITEM ~= false
	local item = settings.ITEM
	if type(item) == 'table' and key(item.NAME) then
		built.item = {
			name = item.NAME,
			label = text(item.LABEL, MAX_LABEL) or 'Radio',
			description = text(item.DESCRIPTION, 160),
			weight = integer(item.WEIGHT, 0, 100000, 350),
			model = text(item.MODEL, 64),
		}
	else
		built.item = nil
		if built.requireItem then
			problems[#problems + 1] = 'ITEM.NAME is missing or malformed: REQUIRE_ITEM is ignored'
			built.requireItem = false
		end
	end

	-- Talking.
	local talk = settings.TALK_KEY
	if talk == false then
		built.talkKey = false
	elseif type(talk) == 'table' and text(talk.ID, 64) and text(talk.NAME, 96) and text(talk.DEFAULT, 16) then
		built.talkKey = { id = talk.ID, name = talk.NAME, default = talk.DEFAULT }
	else
		problems[#problems + 1] = 'TALK_KEY must be false or { ID, NAME, DEFAULT }: the default is used'
		built.talkKey = { id = 'opx.radio.talk', name = 'radio.key.talk', default = 'CAPSLOCK' }
	end
	local intent = settings.TALK_INTENT
	if intent ~= nil and intent ~= 'all' and intent ~= 'channels' then
		problems[#problems + 1] = 'TALK_INTENT must be all or channels: all is used'
		intent = nil
	end
	built.intent = intent or 'all'
	built.maxTalkMs = integer(settings.MAX_TALK_MS, 1000, 600000, 60000)
	built.blockWhenDown = settings.BLOCK_WHEN_DOWN ~= false

	local joined = integer(settings.MAX_JOINED, 1, 64, JOIN_CEILING)
	if joined > JOIN_CEILING then
		problems[#problems + 1] = ('MAX_JOINED above %d is held to %d'):format(JOIN_CEILING, JOIN_CEILING)
		joined = JOIN_CEILING
	end
	built.maxJoined = joined
	built.requestMs = integer(settings.REQUEST_MS, 0, 60000, 300)
	built.talkMs = integer(settings.TALK_MS, 0, 10000, 200)
	built.sweepMs = integer(settings.SWEEP_MS, 1000, 600000, 15000)
	built.effect = readEffect(settings.EFFECT, problems)
	return built
end

--- The JobGate requirement of one channel.
-- @author dop42
-- @param channel table a built channel
-- @return table { jobs, gangs, onDuty }
function Model.Requirement(channel)
	return { jobs = channel.jobs, gangs = channel.gangs, onDuty = channel.onDuty }
end

--- The channels a character snapshot may be on, in menu order.
-- @author dop42
-- @param built table Model.Build's answer
-- @param snapshot table|nil { job, jobs, gang, gangs, atMs }
-- @param nowMs number
-- @return string[] keys
-- @return table key -> true
function Model.Allowed(built, snapshot, nowMs)
	local list, set = {}, {}
	if type(snapshot) ~= 'table' then return list, set end
	for _, name in ipairs(built.order) do
		-- PRIMARY ONLY: a side membership in NCPD does not put a fixer on its
		-- dispatch. The radio follows the job the character is working.
		local passed = OPX.JobGate.EvaluateGroups(Model.Requirement(built.channels[name]), snapshot, nowMs,
			{ maxAgeMs = 5000, membership = 'primary' })
		if passed then
			list[#list + 1] = name
			set[name] = true
		end
	end
	return list, set
end

--- The channels a player should be on now, and whether they hear each.
-- @author dop42
--
-- `prefs` is the player's own say: `power` (false is off the air entirely),
-- `handset` (whether the bag holds one, or none is needed), `off` (AUTO
-- channels they left by hand), `extra` (other channels they joined by hand),
-- `muted` (channels they stay on without hearing). The first MAX_JOINED in
-- menu order win; the selected channel first, so a full radio never drops the
-- one its key talks into.
-- @param built table
-- @param allowed string[] Model.Allowed's list
-- @param prefs table
-- @return table[] { key, listen }
function Model.Desired(built, allowed, prefs)
	local out = {}
	if prefs.power == false or prefs.handset == false then return out end
	local off, extra, muted = prefs.off or {}, prefs.extra or {}, prefs.muted or {}
	local wanted = {}
	for _, name in ipairs(allowed) do
		local channel = built.channels[name]
		if channel ~= nil and ((channel.auto and not off[name]) or extra[name]) then
			wanted[#wanted + 1] = name
		end
	end
	-- The selected channel keeps its seat.
	local active = prefs.active
	if active ~= nil then
		for index, name in ipairs(wanted) do
			if name == active then
				table.remove(wanted, index)
				table.insert(wanted, 1, name)
				break
			end
		end
	end
	for index = 1, math.min(#wanted, built.maxJoined) do
		out[#out + 1] = { key = wanted[index], listen = not muted[wanted[index]] }
	end
	-- Back into menu order, so the list a player sees does not reshuffle.
	local rank = {}
	for index, name in ipairs(allowed) do rank[name] = index end
	table.sort(out, function(a, b) return (rank[a.key] or 0) < (rank[b.key] or 0) end)
	return out
end

--- The channel the talk key keys: the one asked for when it is joined, else
--- the first joined one, else nil.
-- @author dop42
-- @param desired table[] Model.Desired's answer
-- @param wanted string|nil
-- @return string|nil
function Model.Active(desired, wanted)
	for _, row in ipairs(desired) do
		if row.key == wanted then return wanted end
	end
	return desired[1] and desired[1].key or nil
end

--- The rows the client's menu draws: every channel the player may be on.
-- @author dop42
-- @param built table
-- @param allowed string[]
-- @param joined table key -> { listen }
-- @param active string|nil
-- @return table[]
function Model.Rows(built, allowed, joined, active)
	local rows = {}
	for _, name in ipairs(allowed) do
		local channel = built.channels[name]
		local member = joined[name]
		rows[#rows + 1] = {
			key = name,
			label = channel.label,
			short = channel.short,
			auto = channel.auto,
			joined = member ~= nil,
			muted = member ~= nil and member.listen == false,
			active = name == active,
		}
	end
	return rows
end
