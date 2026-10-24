--- Server half: the breach, the session, the daemons, the trace, the brokers.
-- @author dop42
--
-- THIS FILE IS THE NETWORK. A client names an access point, a daemon or a
-- broker, and every other fact is read here: the network and its nodes out of
-- the config this VM built, the position and bucket from the host, the job and
-- grade from the character contract, the deck and its RAM from the inventory
-- contract. A jack-in passes, cheapest first:
--
--   1. the per-player request floor           (a clock)
--   2. the network and the access point exist  (a lookup)
--   3. loaded, not down, not already jacked in
--   4. same bucket, within the access point's RADIUS (the host's position)
--   5. NetWatch has not flagged the runner, the network is not locked down
--   6. the job gate (the network's MIN_GRADE or JOBS, or freelance)
--   7. a deck in the bag the runner's grade may run
--
-- THE BREACH is the doorlock lockpick's shape on the server's own bars: one
-- `progress` bar per step of the access point's STEPS, timed and judged by the
-- progress module, and a roll here at the end of each. A failed roll raises
-- the trace and the step runs again; a trace of 100% is a trace.
--
-- THE SESSION lives in `sessions[player]` and nowhere else. A 1 Hz job raises
-- every trace by the ICE's TRACE_MS, ends a run whose runner walked off,
-- went down or left, warns NCPD at ALERT_AT, and traces at 100%.
--
-- RAM IS RESERVED BEFORE AND REFUNDED ON CANCEL: a daemon's RAM leaves the
-- deck's metadata before its effect (or its bar) starts, and goes back when
-- the bar is cut short or the effect is refused. Value is created last: the
-- shard is added after the bar, the money after the shard left the bag.

local M = OPX.Modules.Get('netrunner')
local Access = M.Access
local Command = M.Command
local Effect = M.Effect
local Result = OPX.Result

local OWNER = 'netrunner'

-- What `Access.Build` made of the config.
local built = nil
-- player -> session; network -> ms it is locked down until; network -> ms its
-- cameras are blind until; `network|node` -> ms a terminal is dry until.
local sessions, lockdowns, blind, dry = {}, {}, {}, {}
-- Doors to lock again: { id, at }.
local relocks = {}
local tickJob = nil

--- The roll, a field so a test can load the dice. Answers 0..1.
M.Roll = math.random

-- ── reading the world ───────────────────────────────────────────────────────

local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function distance(a, x, y, z)
	local dx, dy, dz = a.x - x, a.y - y, a.z - z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- Wall-clock seconds: what a deck's RAM, a shard's heat and NetWatch's
--- lockout are stamped with, because each outlives the process.
local function wallS()
	local time = Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local read, value = pcall(time.unix)
		value = read and OPX.Math.Finite(value) or nil
		if value ~= nil then return value end
	end
	return OPX.Now() / 1000
end

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

local function playerOf(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value
end

--- The job fields of a loaded character, stamped now, for `OPX.JobGate`.
local function snapshotOf(loaded)
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		atMs = OPX.Now(),
	}
end

--- The runner's grade in the netrunner job, or nil when they do not hold it.
local function gradeOf(loaded)
	local data = loaded.PlayerData
	local job = data.job
	if type(job) == 'table' and job.name == built.job then
		return type(job.grade) == 'table' and OPX.Math.Finite(job.grade.level) or 0
	end
	return type(data.jobs) == 'table' and OPX.Math.Finite(data.jobs[built.job]) or nil
end

-- One inventory call answering a value, or nil.
local function valueOf(fn, ...)
	if type(fn) ~= 'function' then return nil end
	local read, answer = pcall(fn, ...)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value
end

local function itemsOf(player)
	local api = inventory()
	local bag = api and valueOf(api.GetInventory, player) or nil
	return type(bag) == 'table' and type(bag.items) == 'table' and bag.items or {}
end

-- ── answers ─────────────────────────────────────────────────────────────────

--- Tells one player how a request went, as a toast from the catalogue.
local function answer(player, ok, code, params)
	local key = (ok and 'netrunner.answer.' or 'netrunner.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'netrunner.answer.done' or 'netrunner.error.invalid' end
	pcall(OPX.NotifyLocale, player, key, params, ok and 'success' or 'error')
	return ok, code
end

-- ── the deck ────────────────────────────────────────────────────────────────

--- The best deck in a bag this runner may run: `{ slot, deck, metadata }`, or
--- nil and why (no_deck, deck_grade).
local function deckOf(player, loaded)
	local grade = gradeOf(loaded)
	local best, lockedOut = nil, false
	local items = itemsOf(player)
	for index = 1, #items do
		local item = items[index]
		local deck = type(item) == 'table' and built.decks[item.name] or nil
		if deck ~= nil then
			if deck.minGrade > 0 and (grade == nil or grade < deck.minGrade) then
				lockedOut = true
			elseif best == nil or deck.tier > best.deck.tier then
				best = { slot = item.slot, deck = deck,
					metadata = type(item.metadata) == 'table' and item.metadata or {} }
			end
		end
	end
	if best == nil then return nil, lockedOut and 'deck_grade' or 'no_deck' end
	return best
end

--- Reads the deck a session holds back out of its slot: still there, still
--- the same deck. Answers the metadata, or nil.
local function heldDeck(player, session)
	local api = inventory()
	local stack = api and valueOf(api.GetSlot, session.citizenId, session.slot) or nil
	if type(stack) ~= 'table' or stack.name ~= session.deck.name then return nil end
	local metadata = type(stack.metadata) == 'table' and stack.metadata or {}
	if session.serial ~= nil and metadata.serial ~= nil and metadata.serial ~= session.serial then return nil end
	return metadata
end

--- Writes a deck's RAM onto its metadata. Answers whether it was written.
local function writeRam(player, session, metadata, ram)
	local api = inventory()
	if api == nil or type(api.SetMetadata) ~= 'function' then return false end
	metadata.ram = math.floor(ram * 100 + 0.5) / 100
	metadata.ramAt = wallS()
	metadata.tier, metadata.ramMax = session.deck.tier, session.deck.ram
	metadata.serial = metadata.serial or session.serial
	local read, set = pcall(api.SetMetadata, session.citizenId, session.slot, metadata)
	return read and type(set) == 'table' and set.ok == true
end

--- The deck's RAM now, or nil when the deck left its slot.
local function ramOf(player, session)
	local metadata = heldDeck(player, session)
	if metadata == nil then return nil end
	return Access.RamNow(metadata, session.deck, wallS()), metadata
end

--- Takes RAM off the deck (negative gives it back). Answers whether it moved.
local function spendRam(player, session, amount)
	local ram, metadata = ramOf(player, session)
	if ram == nil then return false, 'deck_gone' end
	if amount > 0 and ram + 1e-9 < amount then return false, 'no_ram' end
	if amount == 0 then return true end
	if not writeRam(player, session, metadata, math.min(session.deck.ram, ram - amount)) then
		return false, 'deck_gone'
	end
	return true
end

-- ── NetWatch ────────────────────────────────────────────────────────────────

local function heatOf(player)
	local api = character()
	local raw = nil
	if api ~= nil and type(api.GetMetadata) == 'function' then
		local read, value = pcall(api.GetMetadata, player, built.netwatch.metadata)
		if read then raw = value end
	end
	return Access.Heat(raw, built.netwatch, wallS())
end

--- Moves a runner's heat. Answers the new record.
local function addHeat(player, amount)
	if not built.netwatch.enabled or amount == 0 then return heatOf(player) end
	local now = wallS()
	local record, flagged = Access.AddHeat(heatOf(player), amount, built.netwatch, now)
	local api = character()
	if api ~= nil and type(api.SetMetadata) == 'function' then
		pcall(api.SetMetadata, player, built.netwatch.metadata,
			{ value = math.floor(record.value * 100 + 0.5) / 100, at = math.floor(now), lock = math.floor(record.lock or 0) })
	end
	if flagged then
		OPX.Audit.Security('netrunner.netwatchFlag', ('player %d flagged by NetWatch'):format(player),
			{ lockS = built.netwatch.lockoutS }, player)
		answer(player, false, 'netwatch_flagged', { hours = math.ceil(built.netwatch.lockoutS / 3600) })
	end
	return record
end

-- ── the state a runner sees ─────────────────────────────────────────────────

--- The daemons a connected runner may run: the access point's own, then every
--- other node of the network's.
local function daemonsFor(session)
	local network = built.networks[session.network]
	local out = {}
	local function add(node)
		for _, name in ipairs(node.daemons) do
			local daemon = built.daemons[name]
			out[#out + 1] = { node = node.key, nodeLabel = node.label, daemon = name, label = daemon.label,
				ram = daemon.ram, effect = daemon.effect }
		end
	end
	add(network.nodes[session.node])
	local keys = {}
	for key in pairs(network.nodes) do
		if key ~= session.node and network.nodes[key].kind ~= M.Kind.ACCESS_POINT then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do add(network.nodes[key]) end
	return out
end

--- Sends one runner their session. `open` asks the client to show the menu.
local function sendState(player, open)
	local session = sessions[player]
	if session == nil then
		TriggerClientEvent(M.Event.STATE, player, { phase = 'offline' })
		return
	end
	local network = built.networks[session.network]
	local ram = session.phase == 'connected' and ramOf(player, session) or nil
	TriggerClientEvent(M.Event.STATE, player, {
		phase = session.phase,
		network = session.network,
		label = network.label,
		ice = network.ice.name,
		trace = math.floor(session.trace * 100),
		ram = ram ~= nil and math.floor(ram) or nil,
		ramMax = session.deck.ram,
		busy = session.busy ~= nil or nil,
		daemons = session.phase == 'connected' and daemonsFor(session) or nil,
		open = open == true or nil,
	})
end

-- ── the alarm ───────────────────────────────────────────────────────────────

--- Tells whoever ON_TRACE names about a run: a dispatch or police contract
--- when one is running, else every on-duty member of those jobs directly.
local function alarm(player, session, level)
	local network = built.networks[session.network]
	local node = network.nodes[session.node]
	local runner = nil
	if network.ice.revealId and level == 'traced' then
		local loaded = playerOf(player)
		local info = loaded and loaded.PlayerData.charInfo or nil
		if type(info) == 'table' then
			runner = OPX.Text.Clean(('%s %s'):format(tostring(info.firstName or ''), tostring(info.lastName or '')), 64)
		end
	end
	local payload = { network = network.key, label = network.label, level = level,
		x = node.x, y = node.y, z = node.z, runner = runner }
	for _, name in ipairs({ 'dispatch', 'police' }) do
		local api = OPX.Api.Get(name)
		if api ~= nil and type(api.Alert) == 'function' then
			local read, sent = pcall(api.Alert, { kind = 'netrunner', jobs = network.ice.alertJobs,
				label = network.label, coords = { x = node.x, y = node.y, z = node.z }, level = level, runner = runner })
			if read and sent ~= false and not (type(sent) == 'table' and sent.ok == false) then return end
		end
	end
	local api = character()
	if api == nil or type(api.GetPlayersByJob) ~= 'function' then return end
	for _, job in ipairs(network.ice.alertJobs) do
		local read, list = pcall(api.GetPlayersByJob, job, true)
		if read and type(list) == 'table' then
			for index = 1, #list do
				local other = list[index].PlayerData and list[index].PlayerData.source
				if other ~= nil and other ~= player then TriggerClientEvent(M.Event.ALERT, other, payload) end
			end
		end
	end
end

-- ── ending a session ────────────────────────────────────────────────────────

local function progressApi()
	local api = OPX.Api.Get('progress')
	if api == nil or type(api.Start) ~= 'function' then return nil end
	return api
end

--- Ends a run, however it ended. A daemon bar under way gives its RAM back.
-- @param player integer
-- @param code string|nil what to tell the runner; nil says nothing
local function endSession(player, code)
	local session = sessions[player]
	if session == nil then return end
	sessions[player] = nil
	local loaded = playerOf(player)
	local owner = loaded ~= nil and loaded.PlayerData.citizenId == session.citizenId
	if session.busy ~= nil and owner then
		pcall(spendRam, player, session, -session.busy.ram)
	end
	if session.barId ~= nil then
		local api = progressApi()
		if api ~= nil and type(api.Stop) == 'function' then pcall(api.Stop, player, OWNER, session.barId) end
	end
	OPX.Audit.Log({ event = 'netrunner.out', message = ('player %d left %s (%s)'):format(player, session.network,
		tostring(code or 'gone')), data = { network = session.network, code = code,
		trace = math.floor(session.trace * 100) }, source = player })
	if code ~= nil and owner then
		sendState(player, false)
		answer(player, code == 'disconnected', code)
	end
end

--- A trace at 100%: thrown out, the network locked down, NCPD told, heat.
local function traced(player, session)
	local network = built.networks[session.network]
	lockdowns[session.network] = OPX.Now() + network.cooldownMs
	alarm(player, session, 'traced')
	endSession(player, 'traced')
	addHeat(player, built.netwatch.onTrace)
	local node = network.nodes[session.node]
	OPX.Audit.Security('netrunner.traced', ('player %d traced on %s'):format(player, network.key),
		{ network = network.key, node = session.node }, player)
	OPX.Publish(M.Event.ON_TRACED, player, { network = network.key, label = network.label,
		x = node.x, y = node.y, z = node.z })
end

--- Moves a session's trace, warns at ALERT_AT and traces at 100%. Answers
--- whether the run survived it.
local function raiseTrace(player, session, amount)
	local network = built.networks[session.network]
	session.trace = Access.Clamp(session.trace + amount, 0, 1)
	if session.trace >= 1 then
		traced(player, session)
		return false
	end
	if not session.alerted and network.ice.failAlert and session.trace >= network.ice.alertAt then
		session.alerted = true
		alarm(player, session, 'suspicious')
		answer(player, false, 'ice_alert', { ice = network.ice.name })
	end
	return true
end

--- Faction access is additional to the network's trade requirement and the deck.
local function networkAccess(network, loaded)
	local now, snapshot = OPX.Now(), snapshotOf(loaded)
	local requirement = Access.Requirement(network, built)
	if requirement ~= nil then
		local ok, why = OPX.JobGate.Evaluate(requirement, snapshot, now,
			{ maxAgeMs = 5000, membership = 'any' })
		if not ok then return false, why or 'job_required' end
	end
	return OPX.JobGate.EvaluateGroups({ gangs = network.gangs }, snapshot, now,
		{ maxAgeMs = 5000, membership = 'any' })
end

--- Why a run must stop now, or nil.
local function interrupted(player, session)
	local loaded = playerOf(player)
	if loaded == nil or loaded.PlayerData.citizenId ~= session.citizenId then return 'no_character' end
	if OPX.Life.Down(player) then return 'player_down' end
	local at = pointOf(player)
	if at == nil then return 'no_position' end
	local network = built.networks[session.network]
	local allowed, refusal = networkAccess(network, loaded)
	if not allowed then return refusal end
	local node = network.nodes[session.node]
	if at.bucket ~= network.bucket or distance(at, node.x, node.y, node.z) > OPX.Spots.ServerReach(node.radius) then
		return 'link_lost'
	end
	return nil
end

-- ── the breach ──────────────────────────────────────────────────────────────

local onStep

local function runStep(player, session)
	local api = progressApi()
	if api == nil then return false end
	local step = session.steps[session.step]
	local started = api.Start(player, OWNER, {
		label = locale('netrunner.bar.breach', { step = session.step, total = #session.steps }),
		durationMs = step.durationMs,
		cancelable = true,
		animation = built.breach.animation and { name = built.breach.animation, fallback = 'phone' } or nil,
	}, function(who, outcome) onStep(who, outcome) end)
	if type(started) ~= 'table' or not started.ok then return false end
	session.barId = started.value.id
	return true
end

--- The breach succeeded: connected.
local function connect(player, session)
	local network = built.networks[session.network]
	session.phase, session.barId, session.tickAt = 'connected', nil, OPX.Now()
	if network.blackwall then addHeat(player, built.netwatch.perBlackwall) end
	OPX.Audit.Log({ event = 'netrunner.connected', message = ('player %d in %s'):format(player, network.key),
		data = { network = network.key, node = session.node, deck = session.deck.name }, source = player })
	answer(player, true, 'connected', { network = network.label })
	sendState(player, true)
end

--- One breach bar's verdict.
onStep = function(player, outcome)
	local session = sessions[player]
	if session == nil or session.phase ~= 'breach' or type(outcome) ~= 'table' or outcome.id ~= session.barId then
		return
	end
	session.barId = nil
	if outcome.completed ~= true then
		if outcome.ending == 'left' then return endSession(player, nil) end
		return endSession(player, 'breach_cancelled')
	end
	local why = interrupted(player, session)
	if why ~= nil then return endSession(player, why) end
	if heldDeck(player, session) == nil then return endSession(player, 'deck_gone') end

	local step = session.steps[session.step]
	if M.Roll() < step.chance then
		session.step = session.step + 1
		if session.step > #session.steps then return connect(player, session) end
	else
		answer(player, false, 'breach_step_failed', { trace = math.floor((session.trace + built.breach.failTrace) * 100) })
		if not raiseTrace(player, session, built.breach.failTrace) then return end
	end
	if not runStep(player, session) then return endSession(player, 'no_bar') end
	sendState(player, false)
end

--- Jacks a runner in at an access point and starts the breach. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { network, node }
-- @return boolean ok
-- @return string code
function M.JackIn(player, payload)
	if OPX.Cooling(player, 'netrunner.request', built.requestMs) then return answer(player, false, 'too_fast') end
	if type(payload) ~= 'table' then return answer(player, false, 'invalid') end
	local network = type(payload.network) == 'string' and built.networks[payload.network] or nil
	if network == nil then return answer(player, false, 'unknown_network') end
	local node = type(payload.node) == 'string' and network.nodes[payload.node] or nil
	if node == nil or node.kind ~= M.Kind.ACCESS_POINT or node.placeholder then
		return answer(player, false, 'not_access_point')
	end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	if sessions[player] ~= nil then return answer(player, false, 'busy') end
	local at = pointOf(player)
	if at == nil then return answer(player, false, 'no_position') end
	if at.bucket ~= network.bucket or distance(at, node.x, node.y, node.z) > OPX.Spots.ServerReach(node.radius) then
		return answer(player, false, 'too_far')
	end
	if built.netwatch.enabled then
		local heat = heatOf(player)
		if heat.lock > 0 then
			return answer(player, false, 'netwatch_lockout', { hours = math.ceil((heat.lock - wallS()) / 3600) })
		end
	end
	local now = OPX.Now()
	if (lockdowns[network.key] or 0) > now then
		return answer(player, false, 'network_locked',
			{ minutes = math.ceil((lockdowns[network.key] - now) / 60000) })
	end
	local allowed, refusal = networkAccess(network, loaded)
	if not allowed then return answer(player, false, refusal) end
	if progressApi() == nil then return answer(player, false, 'no_bar') end
	local held, why = deckOf(player, loaded)
	if held == nil then return answer(player, false, why) end

	local session = {
		citizenId = loaded.PlayerData.citizenId,
		network = network.key, node = node.key, phase = 'breach',
		slot = held.slot, deck = held.deck,
		serial = held.metadata.serial or ('%s-%d-%d'):format(held.deck.name:sub(-6), math.floor(wallS()), player),
		steps = Access.Steps(node.steps, built.breach, network.ice.tier, held.deck.tier), step = 1,
		trace = 0, traceMul = 1, startedAt = now,
	}
	-- A deck nobody jacked in with before gets its serial and a full buffer.
	if held.metadata.serial == nil then
		writeRam(player, session, held.metadata, Access.RamNow(held.metadata, held.deck, wallS()))
	end
	sessions[player] = session
	if not runStep(player, session) then
		sessions[player] = nil
		return answer(player, false, 'busy')
	end
	OPX.Audit.Log({ event = 'netrunner.breach', message = ('player %d breaching %s'):format(player, network.key),
		data = { network = network.key, node = node.key, deck = held.deck.name }, source = player })
	sendState(player, false)
	return true, 'breaching'
end

--- Jacks a runner out. Answers whether they were in.
-- @author dop42
-- @param player integer
-- @return boolean
function M.JackOut(player)
	if sessions[player] == nil then return false end
	endSession(player, 'disconnected')
	return true
end

-- ── the daemons ─────────────────────────────────────────────────────────────

local function doorlockApi()
	local api = OPX.Api.Get('doorlock')
	if api == nil or type(api.GetFromName) ~= 'function' or type(api.SetState) ~= 'function' then return nil end
	return api
end

local onMined

--- Runs one daemon on one node of the network a runner is in. Yields on the
--- doorlock's networked backend. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { daemon, node }
-- @return boolean ok
-- @return string code
function M.Daemon(player, payload)
	if OPX.Cooling(player, 'netrunner.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local session = sessions[player]
	if session == nil or session.phase ~= 'connected' then return answer(player, false, 'not_connected') end
	if session.busy ~= nil then return answer(player, false, 'busy') end
	if type(payload) ~= 'table' or type(payload.node) ~= 'string' or type(payload.daemon) ~= 'string' then
		return answer(player, false, 'invalid')
	end
	local network = built.networks[session.network]
	local node = network.nodes[payload.node]
	local daemon = built.daemons[payload.daemon]
	local offered = false
	if node ~= nil and daemon ~= nil and (node.kind ~= M.Kind.ACCESS_POINT or node.key == session.node) then
		for _, name in ipairs(node.daemons) do
			if name == daemon.name then offered = true end
		end
	end
	if not offered then return answer(player, false, 'unknown_daemon') end
	local why = interrupted(player, session)
	if why ~= nil then
		endSession(player, why)
		return false, why
	end
	local now = OPX.Now()

	-- Everything that can refuse, before a byte of RAM moves.
	local door = nil
	if daemon.effect == Effect.DOOR then
		local api = doorlockApi()
		if api == nil then return answer(player, false, 'no_doorlock') end
		local read, found = pcall(api.GetFromName, node.door)
		door = read and type(found) == 'table' and found.ok and found.value or nil
		if type(door) ~= 'table' then
			Open77.log.warn(('[netrunner] %s.%s names doorlock door %q, which does not exist')
				:format(network.key, node.key, tostring(node.door)))
			return answer(player, false, 'unknown_door')
		end
		if door.state == 0 then return answer(player, false, 'door_open') end
	elseif daemon.effect == Effect.SHARD then
		if progressApi() == nil then return answer(player, false, 'no_bar') end
		if (dry[network.key .. '|' .. node.key] or 0) > now then
			return answer(player, false, 'node_dry',
				{ minutes = math.ceil((dry[network.key .. '|' .. node.key] - now) / 60000) })
		end
		local api = inventory()
		local room = api and valueOf(api.CanCarry, player, built.shardItem.name, 1, { kind = 'corp', value = 1 })
		if room ~= true then return answer(player, false, 'cannot_carry') end
	elseif daemon.effect == Effect.ICE_PICK and session.picked then
		return answer(player, false, 'already_picked')
	end

	local spent, refusal = spendRam(player, session, daemon.ram)
	if not spent then
		if refusal == 'deck_gone' then endSession(player, 'deck_gone') end
		return answer(player, false, refusal)
	end
	if daemon.effect == Effect.SHARD then
		local api = progressApi()
		local started = api.Start(player, OWNER, {
			label = locale('netrunner.bar.datamine', { node = node.label }),
			durationMs = daemon.durationMs, cancelable = true,
			animation = built.breach.animation and { name = built.breach.animation, fallback = 'phone' } or nil,
		}, function(who, outcome) onMined(who, outcome) end)
		if type(started) ~= 'table' or not started.ok then
			spendRam(player, session, -daemon.ram)
			return answer(player, false, 'busy')
		end
		session.busy = { daemon = daemon.name, node = node.key, ram = daemon.ram }
		session.barId = started.value.id
		if not raiseTrace(player, session, daemon.trace) then return false, 'traced' end
		sendState(player, false)
		return true, 'mining'
	end

	local code, params = 'done', nil
	if daemon.effect == Effect.DOOR then
		local api = doorlockApi()
		local loaded = playerOf(player)
		local by = 'netrunner:' .. tostring(loaded and loaded.PlayerData.citizenId or player)
		local read, set = pcall(api.SetState, door.id, 0, by)
		if not read or type(set) ~= 'table' or set.ok ~= true then
			spendRam(player, session, -daemon.ram)
			return answer(player, false, 'door_refused')
		end
		relocks[#relocks + 1] = { id = door.id, at = now + daemon.unlockS * 1000 }
		OPX.Publish(M.Event.ON_DOOR, player, { network = network.key, door = door.id, unlockS = daemon.unlockS })
		code, params = 'door_opened', { door = node.label, seconds = daemon.unlockS }
	elseif daemon.effect == Effect.CAMERAS then
		local untilMs = math.max(blind[network.key] or 0, now + daemon.durationMs)
		blind[network.key] = untilMs
		OPX.Publish(M.Event.ON_CAMERAS, player, { network = network.key, untilMs = untilMs })
		code, params = 'cameras_looped', { seconds = math.floor(daemon.durationMs / 1000) }
	elseif daemon.effect == Effect.ICE_PICK then
		session.picked = true
		session.traceMul = session.traceMul * daemon.traceMult
		code = 'ice_picked'
	elseif daemon.effect == Effect.WIPE then
		session.trace = math.max(0, session.trace - daemon.traceDrop)
		if daemon.heatDrop > 0 and built.netwatch.enabled then addHeat(player, -daemon.heatDrop) end
		code = 'logs_wiped'
	end
	OPX.Audit.Log({ event = 'netrunner.daemon', message = ('player %d ran %s on %s.%s'):format(player, daemon.name,
		network.key, node.key), data = { network = network.key, node = node.key, daemon = daemon.name }, source = player })
	if not raiseTrace(player, session, daemon.trace) then return false, 'traced' end
	answer(player, true, code, params)
	sendState(player, true)
	return true, code
end

--- A datamine bar's verdict: a shard, or the RAM back.
onMined = function(player, outcome)
	local session = sessions[player]
	if session == nil or session.busy == nil or type(outcome) ~= 'table' or outcome.id ~= session.barId then return end
	local busy = session.busy
	session.busy, session.barId = nil, nil
	if outcome.completed ~= true then
		local loaded = playerOf(player)
		if loaded ~= nil and loaded.PlayerData.citizenId == session.citizenId then
			spendRam(player, session, -busy.ram)
		end
		if outcome.ending == 'left' then return endSession(player, nil) end
		answer(player, false, 'mine_cancelled')
		return sendState(player, true)
	end
	local why = interrupted(player, session)
	if why ~= nil then
		local loaded = playerOf(player)
		if loaded ~= nil and loaded.PlayerData.citizenId == session.citizenId then
			spendRam(player, session, -busy.ram)
		end
		return endSession(player, why)
	end
	local network = built.networks[session.network]
	local node = network.nodes[busy.node]
	local daemon = built.daemons[busy.daemon]
	-- Another runner may have completed a bar on this shared node while this
	-- one was mining. The cooldown is enforced again before producing loot.
	if (dry[network.key .. '|' .. node.key] or 0) > OPX.Now() then
		spendRam(player, session, -busy.ram)
		answer(player, false, 'node_dry',
			{ minutes = math.ceil((dry[network.key .. '|' .. node.key] - OPX.Now()) / 60000) })
		return sendState(player, true)
	end
	local table_ = built.shards[node.table or daemon.table]
	local loot = Access.Loot(table_, M.Roll(), M.Roll())
	local loaded = playerOf(player)
	local now = wallS()
	local serial = ('%s-%d-%d'):format(network.key:sub(1, 8), math.floor(now), math.floor(M.Roll() * 1000000))
	local metadata = {
		network = network.key, node = node.key, origin = network.label, tier = network.ice.tier,
		kind = loot.kind, label = loot.label, value = loot.value, hot = true, at = math.floor(now),
		serial = serial, blackwall = network.blackwall or nil,
		description = ('%s - %s'):format(network.label, loot.label),
	}
	local api = inventory()
	local dryKey = network.key .. '|' .. node.key
	local previousDry, reservedDry = dry[dryKey], nil
	if node.cooldownMs > 0 then
		reservedDry = OPX.Now() + node.cooldownMs
		dry[dryKey] = reservedDry
	end
	local added = api and api.AddItem and select(2, pcall(api.AddItem, session.citizenId, built.shardItem.name, 1, metadata))
	if type(added) ~= 'table' or added.ok ~= true then
		if reservedDry ~= nil and dry[dryKey] == reservedDry then dry[dryKey] = previousDry end
		spendRam(player, session, -busy.ram)
		answer(player, false, 'cannot_carry')
		return sendState(player, true)
	end
	OPX.Audit.Log({ event = 'netrunner.shard', message = ('player %d mined %s (%d) on %s.%s'):format(player,
		loot.kind, loot.value, network.key, node.key), data = { network = network.key, node = node.key,
		kind = loot.kind, value = loot.value, serial = serial }, source = player })
	OPX.Publish(M.Event.ON_OBJECTIVE, player, { cid = loaded and loaded.PlayerData.citizenId or nil,
		network = network.key, node = node.key, objective = 'datamine', shardSerial = serial,
		kind = loot.kind, value = loot.value })
	answer(player, true, 'shard_mined', { label = loot.label, value = OPX.Locale.Money(loot.value) })
	sendState(player, true)
end

-- ── the brokers ─────────────────────────────────────────────────────────────

local function brokerOf(key)
	for _, broker in ipairs(built.brokers) do
		if broker.key == key then return broker end
	end
	return nil
end

--- Sells eligible shards and credits their price in the same durable trade.
-- @author dop42
-- @param player integer
-- @param payload table { broker }
-- @return boolean ok
-- @return string code
function M.Sell(player, payload)
	if OPX.Cooling(player, 'netrunner.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local broker = type(payload) == 'table' and type(payload.broker) == 'string' and brokerOf(payload.broker) or nil
	if broker == nil then return answer(player, false, 'unknown_broker') end
	local loaded = playerOf(player)
	if loaded == nil then return answer(player, false, 'no_character') end
	local citizenId = loaded.PlayerData.citizenId
	if OPX.Life.Down(player) then return answer(player, false, 'player_down') end
	local at = pointOf(player)
	if at == nil then return answer(player, false, 'no_position') end
	if at.bucket ~= broker.bucket or distance(at, broker.x, broker.y, broker.z) > OPX.Spots.ServerReach(broker.radius) then
		return answer(player, false, 'too_far')
	end
	local api = inventory()
	if api == nil or type(api.AtomicTrade) ~= 'function' then return answer(player, false, 'no_inventory') end
	local now = wallS()
	local total, sold, refused, hot, changes = 0, {}, 0, 0, {}
	local items = itemsOf(citizenId)
	for index = 1, #items do
		local item = items[index]
		if type(item) == 'table' and item.name == built.shardItem.name then
			local price, isHot = Access.Price(item.metadata, broker, now)
			if price == nil then
				refused = refused + 1
			else
				total = total + price
				sold[#sold + 1] = item.metadata
				changes[#changes + 1] = { name = item.name, count = -1, slot = item.slot, metadata = item.metadata }
				if isHot then hot = hot + 1 end
			end
		end
	end
	if #sold == 0 then return answer(player, false, refused > 0 and 'broker_refuses' or 'nothing_to_sell') end
	local read, paid = pcall(api.AtomicTrade, citizenId, broker.currency, total, changes, 'netrunner:sell:' .. broker.key, nil, function()
		local live, here = playerOf(player), pointOf(player)
		if not live or live.PlayerData.citizenId ~= citizenId or OPX.Life.Down(player) then return nil, 'no_character' end
		if not here or here.bucket ~= broker.bucket or distance(here, broker.x, broker.y, broker.z) > OPX.Spots.ServerReach(broker.radius) then
			return nil, 'too_far'
		end
		return function() return {} end
	end)
	if not read or type(paid) ~= 'table' or not paid.ok then
		return answer(player, false, type(paid) == 'table' and paid.error == 'money.pending' and 'money.pending' or 'sale_failed')
	end
	OPX.Audit.Log({ event = 'netrunner.sell', message = ('player %d sold %d shard(s) for %d at %s'):format(player,
		#sold, total, broker.key), data = { broker = broker.key, count = #sold, total = total, hot = hot },
		source = player })
	return answer(player, true, hot > 0 and 'sold_hot' or 'sold',
		{ count = #sold, total = OPX.Locale.Money(total), hot = hot })
end

-- ── the clock ───────────────────────────────────────────────────────────────

--- One tick: every trace rises, every run is checked, every door due relocks.
-- @author dop42
function M.Tick()
	local now = OPX.Now()
	local players = {}
	for player in pairs(sessions) do players[#players + 1] = player end
	for _, player in ipairs(players) do
		local session = sessions[player]
		if session ~= nil then
			local ran, failure = pcall(function()
				local why = interrupted(player, session)
				if why ~= nil then return endSession(player, why) end
				if session.phase == 'connected' then
					local network = built.networks[session.network]
					local before = session.trace
					local after = Access.TraceAfter(before, now - (session.tickAt or now), network.ice.traceMs,
						session.traceMul)
					session.tickAt = now
					if raiseTrace(player, session, after - before) then sendState(player, false) end
				end
			end)
			if not ran then
				Open77.log.error(('[netrunner] the run of player %d raised: %s'):format(player, tostring(failure)))
				sessions[player] = nil
			end
		end
	end
	if #relocks > 0 then
		local api = doorlockApi()
		local keep = {}
		for _, relock in ipairs(relocks) do
			if relock.at > now then
				keep[#keep + 1] = relock
			elseif api ~= nil then
				-- Only a door still open: somebody who locked it by hand since
				-- did not ask for it to be turned again.
				local read, found = pcall(api.Get, relock.id)
				if read and type(found) == 'table' and found.ok and type(found.value) == 'table'
					and found.value.state == 0 then
					pcall(api.SetState, relock.id, 1, 'netrunner:relock')
				end
			end
		end
		relocks = keep
	end
	for network, untilMs in pairs(blind) do
		if untilMs <= now then blind[network] = nil end
	end
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Whether a network's cameras are looped now, and until when.
-- @author dop42
-- @param network string
-- @return boolean
-- @return integer|nil untilMs
function M.CamerasBlind(network)
	local untilMs = type(network) == 'string' and blind[network] or nil
	if untilMs == nil or untilMs <= OPX.Now() then return false, nil end
	return true, untilMs
end

--- Checks a shard in a slot of a player's bag against what a contract wants:
--- `{ network?, kind?, minValue?, serial? }`. Answers the shard's metadata.
-- @author dop42
-- @param player integer
-- @param slot integer
-- @param want table|nil
-- @return Result
function M.ValidateShard(player, slot, want)
	local api = inventory()
	if api == nil then return Result.Err('netrunner.error.no_inventory') end
	local stack = valueOf(api.GetSlot, player, math.tointeger(slot))
	if type(stack) ~= 'table' or stack.name ~= built.shardItem.name or type(stack.metadata) ~= 'table' then
		return Result.Err('netrunner.error.no_shard')
	end
	local metadata = stack.metadata
	want = type(want) == 'table' and want or {}
	if (want.network ~= nil and metadata.network ~= want.network)
		or (want.kind ~= nil and metadata.kind ~= want.kind)
		or (want.serial ~= nil and metadata.serial ~= want.serial)
		or (OPX.Math.Finite(want.minValue) ~= nil and (OPX.Math.Finite(metadata.value) or 0) < want.minValue) then
		return Result.Err('netrunner.error.wrong_shard')
	end
	return Result.Ok(OPX.Table.DeepCopy(metadata))
end

--- Every objective a contract may ask for: one row per shard daemon per node.
-- @author dop42
-- @return table[] { network, node, daemon, objective }
function M.Objectives()
	local out = {}
	for key, network in pairs(built.networks) do
		for nodeKey, node in pairs(network.nodes) do
			for _, name in ipairs(node.daemons) do
				if built.daemons[name].effect == Effect.SHARD then
					out[#out + 1] = { network = key, node = nodeKey, daemon = name, objective = 'datamine',
						label = network.label }
				end
			end
		end
	end
	table.sort(out, function(a, b) return a.network .. a.node .. a.daemon < b.network .. b.node .. b.daemon end)
	return out
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines, keys = {}, {}
	for key in pairs(built.networks) do keys[#keys + 1] = key end
	table.sort(keys)
	local now = OPX.Now()
	for _, key in ipairs(keys) do
		local network = built.networks[key]
		lines[#lines + 1] = ('%s %s ICE=%s T%d aps=%d%s%s'):format(key, network.label, network.ice.name,
			network.ice.tier, #network.accessPoints,
			(lockdowns[key] or 0) > now and ' LOCKED' or '', M.CamerasBlind(key) and ' BLIND' or '')
	end
	for _, key in ipairs(built.placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet' end
	for _, line in ipairs(built.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	local running = 0
	for _ in pairs(sessions) do running = running + 1 end
	lines[#lines + 1] = ('%d network(s) open, %d run(s) live'):format(#keys, running)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local network, node = args[1], args[2]
	local kind = args[3] or 'access_point'
	if type(network) ~= 'string' or not network:match('^[%w_%-]+$') or type(node) ~= 'string'
		or not node:match('^[%w_%-]+$') or #network > Access.MAX_KEY or #node > Access.MAX_KEY
		or not (kind == 'access_point' or kind == 'terminal' or kind == 'camera') then
		return OPX.CommandResult(source, false, 'usage: capture <network> <node> [access_point|terminal|camera]')
	end
	local at = pointOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local line = ('NETWORKS.%s.NODES.%s = { KIND = %q, X = %.2f, Y = %.2f, Z = %.2f%s },  -- bucket %d')
		:format(network, node, kind, at.x, at.y, at.z, kind == 'access_point' and ', RADIUS = 2.0' or '', at.bucket)
	Open77.log.info(('[netrunner] capture by %d: %s'):format(source, line))
	OPX.Audit.Log({ event = 'netrunner.capture', message = line, source = source })
	OPX.CommandResult(source, true, ('paste into config/netrunner.lua, then restart:\n  %s'):format(line))
end

local function registerCommands()
	OPX.Command.Register(Command.CAPTURE, { restricted = true, help = 'netrunner.help.capture',
		params = {
			{ name = 'network', help = locale('netrunner.help.network') },
			{ name = 'node', help = locale('netrunner.help.node') },
			{ name = 'kind', optional = true, help = locale('netrunner.help.kind') },
		} },
		function(source, args) capture(source, args) end)
	OPX.Command.Register(Command.NETWORKS, { restricted = true, help = 'netrunner.help.networks' },
		function(source) report(source) end)
end

-- ── items ───────────────────────────────────────────────────────────────────

--- A deck used from the bag: says what is in its buffer.
local function onDeckUsed(source, info)
	local slot = type(info) == 'table' and math.tointeger(info.slot) or nil
	local api = inventory()
	local stack = api and slot and valueOf(api.GetSlot, source, slot) or nil
	local deck = type(stack) == 'table' and built.decks[stack.name] or nil
	if deck ~= nil then
		local ram = Access.RamNow(stack.metadata, deck, wallS())
		answer(source, true, 'deck_status', { label = deck.label, ram = math.floor(ram), max = deck.ram, tier = deck.tier })
	end
	return { ok = true, consume = 0 }
end

local function registerItems()
	local api = inventory()
	if api == nil or type(api.RegisterItem) ~= 'function' then
		Open77.log.warn('[netrunner] no inventory contract: no deck and no shard item')
		return
	end
	local function register(name, definition)
		-- In the static catalogue already (`modules/inventory/data/items.lua`):
		-- nothing to register, only the use to wire.
		if type(api.GetItem) == 'function' then
			local read, known = pcall(api.GetItem, name)
			if read and known ~= nil then return true end
		end
		local read, done = pcall(api.RegisterItem, name, definition, OWNER)
		if not read or type(done) ~= 'table' or done.ok ~= true then
			Open77.log.warn(('[netrunner] the item %s could not be registered: %s'):format(name,
				tostring(read and type(done) == 'table' and done.error or done)))
			return false
		end
		return true
	end
	local shard = built.shardItem
	register(shard.name, { label = shard.label, description = shard.description, weight = shard.weight, stack = false,
		model = 'crate.valuable' })
	for name, deck in pairs(built.decks) do
		if register(name, { label = deck.label, description = deck.description, weight = deck.weight, stack = false,
			model = 'electronics.monitor.device', use = { consume = 0, close = false } }) and type(api.RegisterUsable) == 'function' then
			pcall(api.RegisterUsable, name, onDeckUsed, OWNER)
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the networks out of the config. Never yields.
-- @author dop42
function M.Init()
	built = Access.Build(M.Settings)
	M.Built = built
	sessions, lockdowns, blind, dry, relocks = {}, {}, {}, {}, {}
end

--- Publishes the server half of the netrunner contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('netrunner', 1, {
		--- Whether a network's cameras are looped now: `(bool, untilMs)`.
		CamerasBlind = M.CamerasBlind,
		--- The shard objectives a contracts board may offer.
		Objectives = M.Objectives,
		--- Checks a shard in a slot against a contract's want.
		ValidateShard = M.ValidateShard,
		--- `Verify(contract, proof)`: a contract `{ network?, kind?, minValue? }`
		--- against a proof `{ player, slot }`.
		Verify = function(contract, proof)
			if type(proof) ~= 'table' then return Result.Err('netrunner.error.no_shard') end
			return M.ValidateShard(proof.player, proof.slot, contract)
		end,
		--- The run a player is in, or nil.
		Session = function(player)
			local session = sessions[player]
			if session == nil then return nil end
			return { network = session.network, node = session.node, phase = session.phase,
				trace = session.trace, deck = session.deck.name }
		end,
		--- A runner's NetWatch heat: `{ value, lock }` (wall-clock seconds).
		Heat = function(player) return heatOf(player) end,
		--- Every open network: key -> { label, tier, blackwall }.
		Networks = function()
			local out = {}
			for key, network in pairs(built.networks) do
				out[key] = { label = network.label, tier = network.ice.tier, blackwall = network.blackwall }
			end
			return out
		end,
		JackOut = M.JackOut,
	})
end

--- Wires the doors in, registers the items and starts the clock.
-- @author dop42
function M.Start()
	for _, line in ipairs(built.problems) do Open77.log.warn('[netrunner] config: ' .. line) end
	if #built.placeholders > 0 then
		Open77.log.info(('[netrunner] disabled until surveyed (/opx.netrunner.capture): %s')
			:format(table.concat(built.placeholders, ', ')))
	end
	registerItems()

	RegisterNetEvent(M.Event.JACK_IN, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.JackIn(player, payload)
	end)
	RegisterNetEvent(M.Event.DAEMON, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- Its own thread: the doorlock's networked backend yields.
		CreateThread(function() M.Daemon(player, payload) end)
	end)
	RegisterNetEvent(M.Event.JACK_OUT, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.JackOut(player)
	end)
	RegisterNetEvent(M.Event.SELL, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		CreateThread(function() M.Sell(player, payload) end)
	end)
	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil or player <= 0 or OPX.Cooling(player, 'netrunner.ask', 1000) then return end
		if sessions[player] ~= nil then sendState(player, true) end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then endSession(player, nil) end
	end)

	registerCommands()
	tickJob = OPX.Scheduler.Every('netrunner:tick', built.tickMs, M.Tick)
end

--- Ends every run and gives back the RAM of any bar under way.
-- @author dop42
function M.Stop()
	if tickJob ~= nil and OPX.Scheduler.Cancel ~= nil then pcall(OPX.Scheduler.Cancel, tickJob) end
	tickJob = nil
	local players = {}
	for player in pairs(sessions) do players[#players + 1] = player end
	for _, player in ipairs(players) do pcall(endSession, player, nil) end
	local api = inventory()
	if api ~= nil and type(api.UnregisterUsable) == 'function' then
		for name in pairs(built.decks) do pcall(api.UnregisterUsable, name, OWNER) end
	end
end
