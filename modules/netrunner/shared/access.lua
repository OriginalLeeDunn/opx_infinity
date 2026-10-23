--- Config reads, the boot validator, and every number a run is decided on.
-- @author dop42
--
-- PURE, like `modules/hauling/shared/access.lua`: not one host call. Every
-- function takes what it needs as arguments -- the config table, a clock, a
-- roll -- so the server can call it in a handler and a test can drive it to
-- every branch without a world.
--
-- `Build` turns the operator's config into the shapes the two halves read and
-- answers what it refused. A BAD NETWORK IS REFUSED ALONE: one typo in Kang
-- Tao's ICE must not close the Arasaka waterfront. A network whose every
-- access point is three exact zeros is not refused but DISABLED until somebody
-- surveys it, and named so (see `config/fuel.lua` for why the blanks are
-- zeros and not plausible numbers).

local M = OPX.Modules.Get('netrunner')

M.Access = {}
local Access = M.Access

local finiteNumber = OPX.Math.Finite
local coordinate = OPX.Spots.Coordinate

local KEY_PATTERN = '^[%w_%-]+$'
local MAX_KEY = 48
Access.MAX_KEY = MAX_KEY

local KINDS = { access_point = true, door = true, camera = true, terminal = true }
local EFFECTS = { door = true, cameras = true, shard = true, ice_pick = true, wipe = true }

local function key(value)
	return type(value) == 'string' and #value >= 1 and #value <= MAX_KEY and value:match(KEY_PATTERN) ~= nil
end

local function text(value, maximum)
	if type(value) ~= 'string' or value == '' or #value > (maximum or 96) then return nil end
	return value
end

-- A number in [low, high], or nil.
local function bounded(value, low, high)
	value = finiteNumber(value)
	if value == nil or value < low or value > high then return nil end
	return value
end
Access.Bounded = bounded

local function integer(value, low, high)
	value = bounded(value, low, high)
	if value == nil or value % 1 ~= 0 then return nil end
	return math.floor(value)
end

local function clamp(value, low, high)
	if value < low then return low end
	if value > high then return high end
	return value
end
Access.Clamp = clamp

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

local function presetsOf(raw, problems)
	local out = {}
	local block = type(raw) == 'table' and type(raw.PRESETS) == 'table' and raw.PRESETS or {}
	for name, preset in pairs(block) do
		local duration = type(preset) == 'table' and integer(preset.DURATION_MS, 250, 60000) or nil
		local chance = type(preset) == 'table' and bounded(preset.CHANCE, 0, 1) or nil
		if not key(name) or duration == nil or chance == nil then
			problems[#problems + 1] = ('BREACH.PRESETS.%s: DURATION_MS 250..60000 and CHANCE 0..1'):format(tostring(name))
		else
			out[name] = { durationMs = duration, chance = chance }
		end
	end
	return out
end

local function breachOf(raw, problems)
	raw = type(raw) == 'table' and raw or {}
	local presets = presetsOf(raw, problems)
	local default = {}
	for _, name in ipairs(type(raw.DEFAULT_STEPS) == 'table' and raw.DEFAULT_STEPS or {}) do
		if presets[name] ~= nil then default[#default + 1] = name end
	end
	if #default == 0 and presets.medium ~= nil then default[1] = 'medium' end
	local minimum = bounded(raw.MIN_CHANCE, 0, 1) or 0.05
	local maximum = bounded(raw.MAX_CHANCE, 0, 1) or 0.97
	if maximum < minimum then maximum = minimum end
	local animation = type(raw.ANIMATION) == 'string' and raw.ANIMATION:match('^[%w_]+$') and raw.ANIMATION or nil
	return {
		presets = presets,
		default = default,
		tierBonus = bounded(raw.TIER_BONUS, 0, 1) or 0.08,
		tierSpeed = bounded(raw.TIER_SPEED, 0, 0.9) or 0.1,
		minChance = minimum,
		maxChance = maximum,
		failTrace = bounded(raw.FAIL_TRACE, 0, 1) or 0.2,
		animation = animation,
	}
end

local function decksOf(raw, problems)
	local out = {}
	for name, deck in pairs(type(raw) == 'table' and raw or {}) do
		local where = 'DECKS.' .. tostring(name)
		local tier = type(deck) == 'table' and integer(deck.TIER, 1, 10) or nil
		local ram = type(deck) == 'table' and integer(deck.RAM, 1, 100) or nil
		if not key(name) or tier == nil or ram == nil then
			problems[#problems + 1] = where .. ': an item name, TIER 1..10 and RAM 1..100'
		else
			out[name] = {
				name = name,
				label = text(deck.LABEL) or name,
				description = text(deck.DESCRIPTION, 160),
				tier = tier,
				ram = ram,
				regen = bounded(deck.REGEN, 0, 1000) or 0,
				minGrade = integer(deck.MIN_GRADE, 0, 100) or 0,
				weight = integer(deck.WEIGHT, 0, 100000) or 800,
			}
		end
	end
	return out
end

local function daemonsOf(raw, problems)
	local out = {}
	for name, daemon in pairs(type(raw) == 'table' and raw or {}) do
		local where = 'DAEMONS.' .. tostring(name)
		local effect = type(daemon) == 'table' and daemon.EFFECT or nil
		local ram = type(daemon) == 'table' and integer(daemon.RAM, 0, 100) or nil
		if not key(name) or not EFFECTS[effect] or ram == nil then
			problems[#problems + 1] = where .. ': EFFECT door|cameras|shard|ice_pick|wipe and RAM 0..100'
		else
			out[name] = {
				name = name,
				label = text(daemon.LABEL) or name,
				effect = effect,
				ram = ram,
				trace = bounded(daemon.TRACE, 0, 1) or 0,
				unlockS = integer(daemon.UNLOCK_S, 1, 3600) or 20,
				durationMs = integer(daemon.DURATION_MS, 250, 600000),
				table = key(daemon.TABLE) and daemon.TABLE or nil,
				traceMult = bounded(daemon.TRACE_MULT, 0.05, 1) or 1,
				traceDrop = bounded(daemon.TRACE_DROP, 0, 1) or 0,
				heatDrop = bounded(daemon.HEAT_DROP, 0, 10000) or 0,
			}
			if effect == 'shard' and (out[name].durationMs == nil or out[name].table == nil) then
				problems[#problems + 1] = where .. ': a shard daemon needs DURATION_MS 250..600000 and a TABLE'
				out[name] = nil
			elseif effect == 'cameras' and out[name].durationMs == nil then
				problems[#problems + 1] = where .. ': a camera loop needs DURATION_MS 250..600000'
				out[name] = nil
			end
		end
	end
	return out
end

local function shardsOf(raw, problems)
	local out = {}
	for name, rows in pairs(type(raw) == 'table' and raw or {}) do
		local list, total = {}, 0
		if key(name) and type(rows) == 'table' then
			for index, row in ipairs(rows) do
				local low = type(row) == 'table' and type(row.VALUE) == 'table' and integer(row.VALUE[1], 0, 10000000) or nil
				local high = type(row) == 'table' and type(row.VALUE) == 'table' and integer(row.VALUE[2], 0, 10000000) or nil
				local weight = type(row) == 'table' and bounded(row.WEIGHT, 0, 1000000) or nil
				if not key(type(row) == 'table' and row.KIND or nil) or low == nil or high == nil or high < low
					or weight == nil then
					problems[#problems + 1] = ('SHARDS.%s[%d]: KIND, VALUE = { low, high } and WEIGHT'):format(name, index)
				elseif weight > 0 then
					list[#list + 1] = { kind = row.KIND, label = text(row.LABEL) or row.KIND, low = low, high = high,
						weight = weight }
					total = total + weight
				end
			end
		end
		if #list == 0 then
			problems[#problems + 1] = ('SHARDS.%s: no row can drop'):format(tostring(name))
		else
			out[name] = { rows = list, total = total }
		end
	end
	return out
end

local function brokersOf(raw, problems, placeholders)
	local out = {}
	for index, broker in ipairs(type(raw) == 'table' and raw or {}) do
		local where = ('BROKERS[%d]'):format(index)
		if type(broker) ~= 'table' then
			problems[#problems + 1] = where .. ': must be a table'
		elseif Access.IsPlaceholder(broker) then
			placeholders[#placeholders + 1] = 'broker ' .. tostring(broker.KEY or index)
		else
			local x, y, z = pointOf(broker)
			local radius = bounded(broker.RADIUS, 0.5, 10)
			local buy = {}
			for kind, factor in pairs(type(broker.BUY) == 'table' and broker.BUY or {}) do
				local value = bounded(factor, 0, 100)
				if type(kind) == 'string' and value ~= nil then buy[kind] = value end
			end
			if x == nil or radius == nil or not key(broker.KEY) or next(buy) == nil then
				problems[#problems + 1] = where .. ': KEY, X, Y, Z, RADIUS 0.5..10 and a BUY table'
			else
				out[#out + 1] = {
					key = broker.KEY, label = text(broker.LABEL) or broker.KEY,
					x = x, y = y, z = z, radius = radius, bucket = integer(broker.BUCKET, 0, 2147483647) or 0,
					buy = buy, hotPenalty = bounded(broker.HOT_PENALTY, 0, 1) or 0.5,
					hotS = integer(broker.HOT_S, 0, 604800) or 1800,
					currency = type(broker.CURRENCY) == 'string' and broker.CURRENCY or 'EDDIES',
				}
			end
		end
	end
	return out
end

local function netwatchOf(raw)
	raw = type(raw) == 'table' and raw or {}
	return {
		enabled = raw.ENABLED ~= false,
		metadata = key(raw.METADATA) and raw.METADATA or 'netwatch_heat',
		perBlackwall = bounded(raw.HEAT_PER_BLACKWALL, 0, 100000) or 25,
		onTrace = bounded(raw.HEAT_ON_TRACE, 0, 100000) or 10,
		flagAt = bounded(raw.FLAG_AT, 1, 100000) or 100,
		lockoutS = (bounded(raw.LOCKOUT_H, 0, 8760) or 24) * 3600,
		decayPerH = bounded(raw.DECAY_PER_H, 0, 100000) or 2,
	}
end

-- ── one network ─────────────────────────────────────────────────────────────

local function stepsOf(raw, breach)
	if raw == nil then return breach.default, nil end
	if type(raw) ~= 'table' or #raw == 0 or #raw > 8 then return nil, 'STEPS must list 1 to 8 presets' end
	local out = {}
	for index, name in ipairs(raw) do
		if breach.presets[name] == nil then return nil, ('STEPS[%d] %s is not a BREACH preset'):format(index, tostring(name)) end
		out[index] = name
	end
	return out, nil
end

-- One network, normalised, or nil and the reason. `disabled` true when its
-- access points are all unsurveyed.
local function networkOf(name, raw, context)
	if not key(name) then return nil, 'the key must be letters, digits, _ or -' end
	if type(raw) ~= 'table' then return nil, 'must be a table' end
	local label = text(raw.LABEL)
	if label == nil then return nil, 'LABEL is required' end
	local ice = type(raw.ICE) == 'table' and raw.ICE or nil
	if ice == nil then return nil, 'ICE is required' end
	local tier = integer(ice.TIER, 1, 10)
	local traceMs = integer(ice.TRACE_MS, 5000, 3600000)
	if tier == nil or traceMs == nil then return nil, 'ICE needs TIER 1..10 and TRACE_MS 5000..3600000' end
	local onTrace = type(ice.ON_TRACE) == 'table' and ice.ON_TRACE or {}
	local alertJobs = {}
	for _, job in ipairs(type(onTrace.JOBS) == 'table' and onTrace.JOBS or { 'ncpd' }) do
		if key(job) then alertJobs[#alertJobs + 1] = job end
	end
	if raw.JOBS ~= nil then
		local wrong = OPX.JobGate.Problems(raw.JOBS, name)
		if #wrong > 0 then return nil, wrong[1] end
	end
	if raw.GANGS ~= nil then
		local wrong = OPX.JobGate.GangProblems(raw.GANGS, name)
		if #wrong > 0 then return nil, wrong[1] end
		local definitions = OPX.Config.MODULES.character and OPX.Config.MODULES.character.GANGS or {}
		for gang, minimum in pairs(raw.GANGS) do
			local definition = definitions[gang]
			if type(definition) ~= 'table' or type(definition.grades) ~= 'table'
				or integer(minimum, 0, 100) == nil or definition.grades[minimum] == nil then
				return nil, 'GANGS names an unknown gang or grade: ' .. tostring(gang)
			end
		end
	end
	local nodes, accessPoints, surveyed = {}, {}, 0
	if type(raw.NODES) ~= 'table' then return nil, 'NODES is required' end
	local count = 0
	for nodeName, node in pairs(raw.NODES) do
		count = count + 1
		local where = 'NODES.' .. tostring(nodeName)
		if not key(nodeName) or type(node) ~= 'table' or not KINDS[node.KIND] then
			return nil, where .. ': KIND access_point|door|camera|terminal'
		end
		local entry = { key = nodeName, kind = node.KIND, label = text(node.LABEL) or nodeName, daemons = {} }
		for index, daemon in ipairs(type(node.DAEMONS) == 'table' and node.DAEMONS or {}) do
			local known = context.daemons[daemon]
			if known == nil then return nil, ('%s: DAEMONS[%d] %s is not a daemon'):format(where, index, tostring(daemon)) end
			if node.KIND == 'door' and known.effect ~= 'door' then
				return nil, where .. ': a door node only runs door daemons'
			end
			if known.effect == 'door' and node.KIND ~= 'door' then
				return nil, where .. ': a door daemon belongs on a door node'
			end
			entry.daemons[#entry.daemons + 1] = daemon
		end
		if node.TABLE ~= nil then
			if context.shards[node.TABLE] == nil then return nil, where .. ': TABLE is not a SHARDS table' end
			entry.table = node.TABLE
		end
		entry.cooldownMs = (integer(node.COOLDOWN_S, 0, 604800) or 0) * 1000
		if node.KIND == 'door' then
			if text(node.DOOR, 64) == nil then return nil, where .. ': DOOR names a doorlock door' end
			entry.door = node.DOOR
		else
			if Access.IsPlaceholder(node) then
				entry.placeholder = true
			else
				local x, y, z = pointOf(node)
				if x == nil then return nil, where .. ': X, Y and Z are required' end
				entry.x, entry.y, entry.z = x, y, z
			end
		end
		if node.KIND == 'access_point' then
			local radius = bounded(node.RADIUS, 0.5, 10)
			if radius == nil then return nil, where .. ': RADIUS 0.5..10' end
			local steps, why = stepsOf(node.STEPS, context.breach)
			if steps == nil or #steps == 0 then return nil, where .. ': ' .. (why or 'no BREACH preset to run') end
			entry.radius, entry.steps = radius, steps
			if not entry.placeholder then
				surveyed = surveyed + 1
				accessPoints[#accessPoints + 1] = nodeName
			end
		end
		-- A shard daemon must find a table on this node or its own.
		for _, daemon in ipairs(entry.daemons) do
			local known = context.daemons[daemon]
			if known.effect == 'shard' and context.shards[entry.table or known.table] == nil then
				return nil, ('%s: %s needs a SHARDS table that exists'):format(where, daemon)
			end
		end
		nodes[nodeName] = entry
	end
	if count == 0 then return nil, 'NODES is empty' end
	if count > context.maxNodes then return nil, ('more than %d NODES'):format(context.maxNodes) end
	table.sort(accessPoints)
	local network = {
		key = name, label = label,
		bucket = integer(raw.BUCKET, 0, 2147483647) or 0,
		minGrade = integer(raw.MIN_GRADE, 0, 100) or 0,
		jobs = raw.JOBS, gangs = raw.GANGS,
		blackwall = raw.BLACKWALL == true,
		cooldownMs = (integer(raw.COOLDOWN_S, 0, 604800) or 1800) * 1000,
		ice = {
			name = text(ice.NAME) or 'ICE', tier = tier, traceMs = traceMs,
			alertAt = bounded(ice.ALERT_AT, 0, 1) or 0.7,
			failAlert = ice.FAIL_ALERT ~= false,
			alertJobs = alertJobs,
			revealId = onTrace.REVEAL_ID == true,
			lethal = ice.LETHAL == true,
		},
		nodes = nodes,
		accessPoints = accessPoints,
	}
	if surveyed == 0 then return network, nil, true end
	return network, nil, false
end

--- The blocks a network is checked against: the breach presets, the daemons
--- and the loot tables. Its own call so a client can build it in one resume
--- and each network in the next.
-- @author dop42
-- @param settings table
-- @param problems table|nil collector
-- @param yield function|nil called between two blocks: a client passes its
--   `Wait(0)`, because the three in one resume overran its budget
-- @return table
function Access.Context(settings, problems, yield)
	problems = problems or {}
	yield = yield or function() end
	local context = { maxNodes = integer(settings.MAX_NODES, 1, 200) or 24 }
	context.breach = breachOf(settings.BREACH, problems)
	yield()
	context.daemons = daemonsOf(settings.DAEMONS, problems)
	yield()
	context.shards = shardsOf(settings.SHARDS, problems)
	return context
end

--- One network against a context: the network, or nil and why; and whether
--- it is disabled for want of a surveyed access point.
-- @author dop42
-- @param name string
-- @param raw table
-- @param context table Access.Context()
-- @return table|nil
-- @return string|nil
-- @return boolean|nil
function Access.Network(name, raw, context)
	return networkOf(name, raw, context)
end

--- Builds every shape the two halves read out of the config, and what it
--- refused or disabled.
-- @author dop42
-- @param settings table the module's config block
-- @return table { networks, decks, daemons, shards, brokers, breach, netwatch, problems, placeholders }
function Access.Build(settings)
	settings = type(settings) == 'table' and settings or {}
	local problems, placeholders = {}, {}
	local context = Access.Context(settings, problems)
	local breach = context.breach
	local networks = {}
	local names = {}
	for name in pairs(type(settings.NETWORKS) == 'table' and settings.NETWORKS or {}) do names[#names + 1] = tostring(name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local network, why, disabled = networkOf(name, settings.NETWORKS[name], context)
		if network == nil then
			problems[#problems + 1] = ('NETWORKS.%s: %s'):format(name, why)
		elseif disabled then
			placeholders[#placeholders + 1] = name
		else
			networks[name] = network
		end
	end
	local shard = type(settings.SHARD_ITEM) == 'table' and settings.SHARD_ITEM or {}
	return {
		networks = networks,
		decks = decksOf(settings.DECKS, problems),
		daemons = context.daemons,
		shards = context.shards,
		brokers = brokersOf(settings.BROKERS, problems, placeholders),
		breach = breach,
		netwatch = netwatchOf(settings.NETWATCH),
		shardItem = {
			name = key(shard.NAME) and shard.NAME or 'data_shard',
			label = text(shard.LABEL) or 'Data shard',
			description = text(shard.DESCRIPTION, 160),
			weight = integer(shard.WEIGHT, 0, 100000) or 20,
		},
		job = key(settings.JOB) and settings.JOB or 'netrunner',
		onDuty = settings.ON_DUTY == true,
		freelance = settings.ALLOW_FREELANCE ~= false,
		tickMs = integer(settings.TICK_MS, 250, 10000) or 1000,
		requestMs = integer(settings.REQUEST_MS, 100, 10000) or 800,
		problems = problems,
		placeholders = placeholders,
	}
end

--- The problems alone: what the boot logs.
-- @author dop42
-- @param settings table
-- @return string[]
function Access.Problems(settings)
	return Access.Build(settings).problems
end

-- ── the numbers a run is decided on ─────────────────────────────────────────

--- The steps one breach runs, each `{ durationMs, chance }`, for a deck tier
--- against an ICE tier.
-- @author dop42
-- @param names string[] preset names
-- @param breach table Build().breach
-- @param iceTier integer
-- @param deckTier integer
-- @return table[]
function Access.Steps(names, breach, iceTier, deckTier)
	local edge = (deckTier or 1) - (iceTier or 1)
	local out = {}
	for index, name in ipairs(names) do
		local preset = breach.presets[name]
		if preset ~= nil then
			local chance = clamp(preset.chance + edge * breach.tierBonus, breach.minChance, breach.maxChance)
			local speed = clamp(1 - edge * breach.tierSpeed, 0.4, 2.5)
			out[index] = { name = name, durationMs = math.floor(clamp(preset.durationMs * speed, 250, 60000)),
				chance = chance }
		end
	end
	return out
end

--- A deck's RAM now, from what its metadata held at `ramAt` and its regen.
--- A timestamp in the future (a clock that moved back) reads as a full deck.
-- @author dop42
-- @param metadata table|nil { ram, ramAt }
-- @param deck table Build().decks[name]
-- @param nowS number wall-clock seconds
-- @return number
function Access.RamNow(metadata, deck, nowS)
	local max = deck.ram
	if type(metadata) ~= 'table' then return max end
	local ram = finiteNumber(metadata.ram)
	local at = finiteNumber(metadata.ramAt)
	if ram == nil or at == nil or at > nowS then return max end
	ram = ram + (nowS - at) / 60 * deck.regen
	return clamp(ram, 0, max)
end

--- What a trace becomes after `ms` of a connected run.
-- @author dop42
-- @param trace number 0..1
-- @param ms number
-- @param traceMs integer the ICE's TRACE_MS
-- @param mult number|nil the ICE pick's factor
-- @return number
function Access.TraceAfter(trace, ms, traceMs, mult)
	return clamp(trace + ms / traceMs * (mult or 1), 0, 1)
end

--- One loot row out of a table, by weight, and its value, from two rolls 0..1.
-- @author dop42
-- @param shards table Build().shards[name]
-- @param pick number 0..1
-- @param spread number 0..1
-- @return table { kind, label, value }
function Access.Loot(shards, pick, spread)
	local target = clamp(pick, 0, 0.999999) * shards.total
	local row = shards.rows[#shards.rows]
	for _, candidate in ipairs(shards.rows) do
		if target < candidate.weight then row = candidate; break end
		target = target - candidate.weight
	end
	local value = row.low + math.floor(clamp(spread, 0, 0.999999) * (row.high - row.low + 1))
	return { kind = row.kind, label = row.label, value = math.min(value, row.high) }
end

--- What a broker pays for one shard, in whole eddies, or nil when it does not
--- buy that kind.
-- @author dop42
-- @param metadata table the shard's { kind, value, at }
-- @param broker table Build().brokers[i]
-- @param nowS number wall-clock seconds
-- @return integer|nil price
-- @return boolean hot
function Access.Price(metadata, broker, nowS)
	if type(metadata) ~= 'table' then return nil, false end
	local value = finiteNumber(metadata.value)
	if value == nil or value <= 0 then return nil, false end
	local factor = broker.buy[metadata.kind]
	if factor == nil then factor = broker.buy.DEFAULT end
	if factor == nil or factor <= 0 then return nil, false end
	local at = finiteNumber(metadata.at)
	local hot = metadata.hot == true and (at == nil or nowS - at < broker.hotS)
	local price = value * factor * (hot and broker.hotPenalty or 1)
	return math.max(0, math.floor(price + 1e-9)), hot
end

--- A NetWatch heat record decayed to now: `{ value, at, lock }`.
-- @author dop42
-- @param record table|nil
-- @param netwatch table Build().netwatch
-- @param nowS number
-- @return table
function Access.Heat(record, netwatch, nowS)
	record = type(record) == 'table' and record or {}
	local value = math.max(0, finiteNumber(record.value) or 0)
	local at = finiteNumber(record.at) or nowS
	if at < nowS then value = math.max(0, value - (nowS - at) / 3600 * netwatch.decayPerH) end
	local lock = finiteNumber(record.lock) or 0
	return { value = value, at = nowS, lock = lock > nowS and lock or 0 }
end

--- Adds (or takes away) heat and flags at FLAG_AT. Answers the new record and
--- whether this change flagged the runner.
-- @author dop42
-- @param record table Access.Heat()
-- @param amount number
-- @param netwatch table
-- @param nowS number
-- @return table
-- @return boolean flagged
function Access.AddHeat(record, amount, netwatch, nowS)
	local out = { value = math.max(0, record.value + amount), at = nowS, lock = record.lock }
	if amount > 0 and out.value >= netwatch.flagAt and (out.lock or 0) <= nowS then
		out.lock = nowS + netwatch.lockoutS
		out.value = 0
		return out, true
	end
	return out, false
end

--- The job requirement a network gates on, for `OPX.JobGate.Evaluate`, or nil
--- when it is open to a freelancer.
-- @author dop42
-- @param network table
-- @param built table Build()
-- @return table|nil
function Access.Requirement(network, built)
	if type(network.jobs) == 'table' and next(network.jobs) ~= nil then
		return { jobs = network.jobs, onDuty = built.onDuty }
	end
	if network.minGrade > 0 or not built.freelance then
		return { jobs = { [built.job] = network.minGrade }, onDuty = built.onDuty }
	end
	return nil
end
