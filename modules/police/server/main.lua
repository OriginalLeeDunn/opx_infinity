--- Server half: the calls, the cuffs, the escort, the search, the fine, the
--- cell and the pound.
-- @author dop42
--
-- EVERY DECISION IS HERE. A client sends wishes -- show me the board, I take
-- this call, cuff that player, fine them this much -- and each is judged again
-- from scratch: who the sender is (job, grade, duty from the character roster,
-- never the payload), where both bodies stand (the host's positions), what
-- state the suspect is in (the record in their metadata, the downed contract),
-- what is in whose bag and whose account.
--
-- AN ACT THAT TAKES TIME is checked before, timed by the server's own bar, and
-- checked AGAIN when the bar ends: the suspect may have run, the officer may
-- have clocked off. Nothing is taken until that second check passes.
--
-- THE RECORD SURVIVES A RECONNECT. Cuffs, a sentence and unpaid fines live in
-- the character's metadata under METADATA_KEY. A cuffed player who logs off is
-- cuffed when they come back; a jailed one is put back in the cell by the same
-- leash that catches a walk-out, on the next sweep.

local M = OPX.Modules.Get('police')

local Access = M.Access
local Dispatch = M.Dispatch
local Event = M.Event
local Capability = M.Capability
local Result = OPX.Result

local OWNER = 'police'

-- A frisk view stays good for this long: confiscating from it after that asks
-- for a fresh search.
local FRISK_TTL_MS = 120000
-- A jailed player put back in the cell is not put back again for this long:
-- the teleport needs time to settle.
local LEASH_GRACE_MS = 4000
-- Seconds of time served between two writes, when only time online counts.
local SERVED_WRITE_S = 30

local settings
-- Online cache of the record: who is cuffed, who is jailed (player -> sentence).
local cuffed, jailed = {}, {}
-- Bars under way: by officer. An escort: by officer, by suspect, by interaction id.
local busy, escorts, escortOf, byInteraction = {}, {}, {}, {}
-- officer -> { target, atMs } of the last search shown.
local frisks = {}
-- player:kind -> last request time; player -> last 911 time.
local lastRequest, lastEmergency = {}, {}
-- player -> last leash teleport, and the last served-time write.
local leashedAt, servedWrite = {}, {}
local lastSweepMs
local arbiter

local function config()
	if settings == nil then settings = Access.Settings(OPX.Config.MODULES.police) end
	return settings
end

-- ── reading the world ────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

local function wallSeconds()
	local time = Open77.time
	if type(time) ~= 'table' or type(time.unix) ~= 'function' then return nil end
	local read, now = pcall(time.unix)
	return read and OPX.Math.Finite(now) or nil
end

local function positionOf(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, at = pcall(players.position, player)
	if not read or type(at) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(at.bucket) or 0) }
end

local function playerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = math.tointeger(tonumber(value))
		if id and id > 0 then ids[#ids + 1] = id end
	end
	return ids
end

local function gapSq(a, b)
	if a == nil or b == nil then return nil end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Whether two points are within a reach, the shared slack included.
local function within(a, b, reach)
	if a == nil or b == nil then return false end
	if a.bucket ~= nil and b.bucket ~= nil and a.bucket ~= b.bucket then return false end
	local slack = OPX.Math.Finite(OPX.Config.SHARED and OPX.Config.SHARED.REACH_SLACK) or 1.0
	local limit = reach + slack
	local gap = gapSq(a, b)
	return gap ~= nil and gap <= limit * limit
end

local function loaded(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value.PlayerData
end

local function citizenOf(player)
	local data = loaded(player)
	return data and type(data.citizenId) == 'string' and data.citizenId or nil
end

-- Whether one player works for a service at a grade, by the shared gate.
local function member(player, svc, minGrade)
	local data = loaded(player)
	if data == nil then return false end
	local now = OPX.Now()
	return OPX.JobGate.Evaluate({ jobs = Access.Jobs(svc, minGrade), onDuty = svc.onDuty },
		{ job = data.job, jobs = data.jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = config().membership }) == true
end

-- The services one player answers calls for, as a set, or nil.
local function servicesOf(player)
	local set, any = {}, false
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		if member(player, svc, svc.dispatch.minGrade) then set[key], any = true, true end
	end
	return any and set or nil
end

-- The first service through which a player holds one capability where they
-- stand, or nil and why: not_member (no service gives it) or
-- out_of_jurisdiction (one does, but not here).
local function capable(player, cap)
	local outside = false
	local here
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		local grade = svc.capabilities[cap]
		if grade ~= nil and member(player, svc, grade) then
			if svc.zoned then here = here or positionOf(player) end
			if Access.InJurisdiction(svc, here) then return svc end
			outside = true
		end
	end
	return nil, outside and 'out_of_jurisdiction' or 'not_member'
end

-- The down state from the downed contract: down, stage ('wounded' | 'dead').
local function downState(player)
	local downed = OPX.Api.Get('downed')
	if downed == nil or type(downed.IsDown) ~= 'function' then return false, nil end
	local read, answer = pcall(downed.IsDown, player)
	if not read or type(answer) ~= 'table' or not answer.ok or type(answer.value) ~= 'table' then
		return false, nil
	end
	return answer.value.down == true, answer.value.stage
end

local function carried(player, name)
	local api = inventory()
	if api == nil or type(api.GetItemCount) ~= 'function' or name == nil then return 0 end
	local read, counted = pcall(api.GetItemCount, player, name)
	if not read or type(counted) ~= 'table' or not counted.ok then return 0 end
	return math.tointeger(counted.value) or 0
end

local function balanceOf(player, moneyType)
	local api = character()
	if api == nil or type(api.GetMoney) ~= 'function' then return 0 end
	local read, value = pcall(api.GetMoney, player, moneyType)
	return read and (math.tointeger(math.floor(OPX.Math.Finite(value) or 0)) or 0) or 0
end

-- ── the record ───────────────────────────────────────────────────────────────

-- The character's police record: { cuffed = {...}, jail = {...}, debt = n }.
local function recordOf(player)
	local api = character()
	if api == nil or type(api.GetMetadata) ~= 'function' then return {} end
	local read, value = pcall(api.GetMetadata, player, config().metadataKey)
	if not read or type(value) ~= 'table' then return {} end
	return OPX.Table.DeepCopy(value)
end

local function writeRecord(player, record)
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return false end
	local read, ok = pcall(api.SetMetadata, player, config().metadataKey, record)
	return read and ok == true
end

local function debtOf(record)
	return math.max(0, math.tointeger(math.floor(OPX.Math.Finite(record.debt) or 0)) or 0)
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function answer(player, ok, code, extra)
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(Event.ANSWER, player, payload)
	return ok
end

local function cooled(player, kind)
	local slot = player .. ':' .. kind
	local now = OPX.Now()
	if lastRequest[slot] ~= nil and now - lastRequest[slot] < config().requestMs then return true end
	lastRequest[slot] = now
	return false
end

local function audit(event, player, ok, message)
	OPX.Audit.Log({ event = event, severity = ok and 'info' or 'warn', source = player, message = message })
end

-- ── the board ────────────────────────────────────────────────────────────────

local function crimeOf(code)
	return config().crimes[code]
end

-- What an officer is shown of one call. Never a caller's name: the server does
-- not hand a stranger's name to anybody.
local function viewOf(call, viewer)
	local svc = config().services[call.service]
	local here = positionOf(viewer)
	local gap = here and call.position and gapSq(here, call.position)
	return {
		id = call.id,
		service = call.service,
		short = svc and svc.short or call.service,
		crime = call.crime,
		label = call.label,
		description = call.description,
		priority = call.priority,
		source = call.source,
		x = call.position and call.position.x, y = call.position and call.position.y,
		z = call.position and call.position.z,
		radius = call.radius,
		distance = gap and math.floor(math.sqrt(gap)) or nil,
		ageS = math.floor((OPX.Now() - call.openedMs) / 1000),
		responders = Dispatch.Count(call),
		limit = svc and svc.dispatch.responders or 1,
		mine = call.responders[viewer] ~= nil,
	}
end

-- Sends one call to every member of its service who may take it. Answers how many.
local function alert(call)
	local svc = config().services[call.service]
	local told = 0
	for _, player in ipairs(playerIds()) do
		if player ~= call.caller and member(player, svc, svc.dispatch.minGrade) then
			TriggerClientEvent(Event.ALERT, player, viewOf(call, player))
			told = told + 1
		end
	end
	return told
end

local function announceClosed(call, why)
	local svc = config().services[call.service]
	for _, player in ipairs(playerIds()) do
		if svc and member(player, svc, svc.dispatch.minGrade) then
			TriggerClientEvent(Event.CLOSED, player, { id = call.id, why = why })
		end
	end
	OPX.Publish(Event.ON_CALL, call.caller, { state = 'closed', callId = call.id, service = call.service,
		crime = call.crime, why = why })
end

-- Opens a call on every service `accepts` says yes to. Answers how many
-- services got one and how many officers were told.
local function openCalls(spec, accepts)
	local services, told = 0, 0
	local crime = crimeOf(spec.crime)
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		if svc.dispatch.enabled and accepts(svc) then
			local call, fresh, evicted = Dispatch.Open({
				service = key, crime = spec.crime,
				label = spec.label or (crime and crime.label) or spec.crime,
				description = spec.description, position = spec.position, radius = spec.radius,
				priority = math.max(crime and crime.priority or 0, spec.priority or 0),
				source = spec.source, caller = spec.caller, dedupe = spec.dedupe,
				ttlMs = svc.dispatch.ttlMs, nowMs = OPX.Now(),
			})
			if evicted ~= nil then announceClosed(evicted, 'board_full') end
			services = services + 1
			-- A fresh call alerts; so does one that got worse (an ICE trace that
			-- went from a warning to a trace), which the officers must hear again.
			if not fresh and spec.realert then
				told = told + alert(call)
			elseif fresh then
				told = told + alert(call)
				OPX.Publish(Event.ON_CALL, spec.caller, { state = 'opened', callId = call.id, service = key,
					crime = call.crime, source = call.source })
			end
		end
	end
	return services, told
end

-- A position a contract caller handed in, or nil.
local function pointOf(value)
	if type(value) ~= 'table' then return nil end
	local x, y, z = OPX.Spots.Coordinate(value.x), OPX.Spots.Coordinate(value.y), OPX.Spots.Coordinate(value.z)
	if x == nil or y == nil then return nil end
	return { x = x, y = y, z = z or 0.0 }
end

local function cleanText(value, limit)
	if type(value) ~= 'string' then return nil end
	local cleaned = OPX.Text.Clean(value, limit or 160)
	return cleaned ~= '' and cleaned or nil
end

local function onBoard(player)
	local services = servicesOf(player)
	if services == nil then return answer(player, false, 'not_member') end
	local rows = {}
	for _, call in ipairs(Dispatch.List(services)) do
		if #rows >= 32 then break end
		rows[#rows + 1] = viewOf(call, player)
	end
	TriggerClientEvent(Event.BOARD_VIEW, player, { calls = rows })
end

local function onTake(player, payload)
	local call = Dispatch.Get(type(payload) == 'table' and payload.callId)
	if call == nil then return answer(player, false, 'no_such_call') end
	local svc = config().services[call.service]
	if svc == nil or not member(player, svc, svc.dispatch.minGrade) then
		return answer(player, false, 'not_member')
	end
	if call.caller == player then return answer(player, false, 'no_such_call') end
	local taken, why = Dispatch.Take(call.id, player, svc.dispatch.responders, OPX.Now())
	if taken == nil then return answer(player, false, why) end
	local at = call.position
	if at ~= nil then TriggerClientEvent(Event.WAYPOINT, player, { x = at.x, y = at.y, z = at.z }) end
	if call.caller ~= nil and citizenOf(call.caller) ~= nil then
		OPX.NotifyLocale(call.caller, 'police.caller.enRoute', { service = svc.short }, 'success')
	end
	OPX.Publish(Event.ON_CALL, call.caller, { state = 'taken', callId = call.id, service = call.service,
		crime = call.crime, responder = citizenOf(player) })
	audit('police.take', player, true, ('%s call %d (%s)'):format(call.service, call.id, tostring(call.crime)))
	answer(player, true, at ~= nil and 'taken' or 'taken_blind')
end

local function onDrop(player, payload)
	local id = type(payload) == 'table' and payload.callId
	if not Dispatch.Drop(id, player) then return answer(player, false, 'no_such_call') end
	answer(player, true, 'dropped')
end

-- ── the contract's two doors ─────────────────────────────────────────────────

--- A crime reported by another module (the underworld's alarms) or by a
--- creator: `{ crime, label?, position?, radius?, description?, source?,
--- priority?, dedupe? }`. Never raises; answers a Result.
-- @author dop42
local function report(spec)
	if type(spec) ~= 'table' then return Result.Err('bad_argument') end
	local crime = type(spec.crime) == 'string' and spec.crime:match('^[%w_]+$') and #spec.crime <= 48
		and spec.crime or nil
	if crime == nil then return Result.Err('bad_crime') end
	local label = cleanText(spec.label, 64)
	local position = pointOf(spec.position)
	local source = type(spec.source) == 'string' and spec.source:match('^[%w_%-%.]+$') and #spec.source <= 32
		and spec.source or 'report'
	local dedupe = cleanText(spec.dedupe, 64) or (position == nil and label ~= nil
		and ('%s:%s:%s'):format(source, crime, label) or nil)
	local services, told = openCalls({
		crime = crime, label = label, description = cleanText(spec.description, 160),
		position = position, radius = OPX.Math.Finite(spec.radius),
		priority = math.tointeger(math.floor(OPX.Math.Finite(spec.priority) or 0)),
		source = source, dedupe = dedupe,
	}, function(svc) return Access.Receives(svc, crime) end)
	return Result.Ok({ services = services, told = told })
end

--- The ICE trace of `modules/netrunner`: `{ kind, jobs, label, coords, level,
--- runner }`. Answers false when no service here is one of `jobs`, so the
--- caller falls back to telling those jobs itself.
-- @author dop42
local function alertJobs(spec)
	if type(spec) ~= 'table' then return false end
	local jobs = type(spec.jobs) == 'table' and spec.jobs or {}
	local kind = type(spec.kind) == 'string' and spec.kind:match('^[%w_]+$') and spec.kind or 'netrunner'
	local crime = crimeOf(kind) and kind or 'netrunner'
	local level = type(spec.level) == 'string' and spec.level:match('^[%w_]+$') and spec.level or nil
	local label = cleanText(spec.label, 64)
	local runner = cleanText(spec.runner, 64)
	local description = level and ('%s%s'):format(level, runner and (' -- ' .. runner) or '') or runner
	local services = openCalls({
		crime = crime, label = label and ('%s: %s'):format((crimeOf(crime) or {}).label or crime, label) or nil,
		description = description, position = pointOf(spec.coords), source = kind,
		priority = level == 'traced' and 1 or 0, realert = level == 'traced',
		dedupe = ('%s:%s'):format(kind, label or '?'),
	}, function(svc)
		if #jobs > 0 then return Access.HasAnyJob(svc, jobs) end
		return Access.Receives(svc, crime)
	end)
	return services > 0
end

--- How many police are on duty and able to answer a crime anywhere: members
--- of every service that is not confined to an enclave. A plain number, the
--- shape `modules/underworld` reads.
-- @author dop42
local function onDutyCount()
	local count = 0
	for _, player in ipairs(playerIds()) do
		for _, key in ipairs(config().serviceOrder) do
			local svc = config().services[key]
			if not svc.zoned and member(player, svc, svc.dispatch.minGrade) then
				count = count + 1
				break
			end
		end
	end
	return count
end

-- ── 911 and 10-00 ────────────────────────────────────────────────────────────

local function emergency(player, args)
	local cfg = config().emergency
	if player == nil or player <= 0 or not cfg.enabled then return end
	if citizenOf(player) == nil then return end
	local now = OPX.Now()
	if lastEmergency[player] ~= nil and now - lastEmergency[player] < cfg.cooldownMs then
		return OPX.NotifyLocale(player, 'police.caller.tooSoon', nil, 'warning')
	end
	local text = cleanText(table.concat(type(args) == 'table' and args or {}, ' '), cfg.maxText)
	if text == nil then return OPX.NotifyLocale(player, 'police.caller.usage', { command = cfg.command }, 'error') end
	lastEmergency[player] = now
	local services, told = openCalls({
		crime = cfg.crime, description = text, position = positionOf(player), source = '911',
		caller = player, dedupe = '911:' .. player,
	}, function(svc) return Access.Receives(svc, cfg.crime) end)
	audit('police.911', player, true, text)
	OPX.NotifyLocale(player, told > 0 and 'police.caller.received' or 'police.caller.nobody', nil,
		told > 0 and 'info' or 'warning')
	return services
end

local function onDownedChanged(player, payload)
	local id = math.tointeger(tonumber(player))
	if id == nil or type(payload) ~= 'table' then return end
	local dedupe = 'down:' .. id
	if payload.down ~= true then
		for _, call in ipairs(Dispatch.CloseKey(dedupe)) do announceClosed(call, 'officer_up') end
		return
	end
	local cfg = config().officerDown
	if not cfg.enabled then return end
	CreateThread(function()
		local mine = servicesOf(id)
		if mine == nil then return end
		local shorts = {}
		for _, key in ipairs(config().serviceOrder) do
			if mine[key] then shorts[#shorts + 1] = config().services[key].short end
		end
		openCalls({ crime = cfg.crime, description = table.concat(shorts, '/'), position = positionOf(id),
			source = 'officer_down', caller = id, dedupe = dedupe, priority = 10 },
			function(svc) return Access.Receives(svc, cfg.crime) end)
	end)
end

-- ── cuffs ────────────────────────────────────────────────────────────────────

local function restrain(player, on)
	TriggerClientEvent(Event.RESTRAINED, player, { cuffed = on == true })
end

local function release(job)
	if busy[job.officer] == job then busy[job.officer] = nil end
end

local function endEscort(job, why)
	if job == nil or job.done then return end
	job.done = true
	if escorts[job.officer] == job then escorts[job.officer] = nil end
	if escortOf[job.suspect] == job then escortOf[job.suspect] = nil end
	if job.interactionId ~= nil then
		byInteraction[job.interactionId] = nil
		if why ~= 'interaction' then
			local native = Open77.playerInteractions
			if type(native) == 'table' and type(native.cancel) == 'function' then
				pcall(native.cancel, job.interactionId, why or 'released')
			end
		end
	end
	if job.wounded then
		local downed = OPX.Api.Get('downed')
		if downed ~= nil and type(downed.SetCarried) == 'function' then
			pcall(downed.SetCarried, job.suspect, OWNER, false)
		end
	end
end

local function commitCuff(officer, suspect, svc)
	local cfg = config().cuffs
	if cfg.consume then
		local api = inventory()
		local read, removed = false, nil
		if api ~= nil and type(api.RemoveItem) == 'function' then
			read, removed = pcall(api.RemoveItem, officer, cfg.item, 1)
		end
		if not read or type(removed) ~= 'table' or not removed.ok then return answer(officer, false, 'no_cuffs') end
	end
	local record = recordOf(suspect)
	record.cuffed = { by = citizenOf(officer), service = svc.key, at = wallSeconds() }
	if not writeRecord(suspect, record) then return answer(officer, false, 'unavailable') end
	cuffed[suspect] = true
	restrain(suspect, true)
	OPX.NotifyLocale(suspect, 'police.suspect.cuffed', { service = svc.short }, 'warning')
	audit('police.cuff', officer, true, ('%s cuffed player %d'):format(svc.key, suspect))
	OPX.Publish(Event.ON_CUFFED, suspect, { citizenId = citizenOf(suspect), cuffed = true,
		by = citizenOf(officer), service = svc.key })
	answer(officer, true, 'cuffed')
end

local function finishCuff(job, completed)
	if job.done then return end
	job.done = true
	release(job)
	if not completed then return answer(job.officer, false, 'interrupted') end
	-- AGAIN, NOW: the suspect had DURATION_MS to walk away.
	local svc = capable(job.officer, Capability.CUFF)
	if svc == nil then return answer(job.officer, false, 'not_member') end
	if cuffed[job.suspect] then return answer(job.officer, false, 'already_cuffed') end
	if not within(positionOf(job.officer), positionOf(job.suspect), config().cuffs.breakReach) then
		OPX.NotifyLocale(job.suspect, 'police.suspect.slipped', nil, 'success')
		return answer(job.officer, false, 'got_away')
	end
	local down, stage = downState(job.suspect)
	if down and stage ~= 'wounded' then return answer(job.officer, false, 'is_dead') end
	if carried(job.officer, config().cuffs.item) < 1 then return answer(job.officer, false, 'no_cuffs') end
	commitCuff(job.officer, job.suspect, svc)
end

local function cuff(officer, suspect, svc)
	if busy[officer] ~= nil then return answer(officer, false, 'busy') end
	if cuffed[suspect] then return answer(officer, false, 'already_cuffed') end
	local down, stage = downState(suspect)
	if down and stage ~= 'wounded' then return answer(officer, false, 'is_dead') end
	if carried(officer, config().cuffs.item) < 1 then
		return answer(officer, false, 'no_cuffs', { item = config().cuffs.item })
	end
	-- A wounded body on the ground does not fight the cuffs.
	if down then return commitCuff(officer, suspect, svc) end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return answer(officer, false, 'no_bar') end
	local job = { kind = 'cuff', officer = officer, suspect = suspect, svc = svc }
	busy[officer] = job
	local started = progress.Start(officer, OWNER, {
		label = locale('police.bar.cuff'), durationMs = config().cuffs.durationMs, cancelable = true,
	}, function(_, outcome)
		finishCuff(job, type(outcome) == 'table' and outcome.completed == true)
	end)
	if type(started) ~= 'table' or not started.ok then
		release(job)
		return answer(officer, false, type(started) == 'table' and started.error == 'progress_busy' and 'busy' or 'no_bar')
	end
	job.barId = type(started.value) == 'table' and started.value.id or nil
	OPX.NotifyLocale(suspect, 'police.suspect.cuffing', { service = svc.short }, 'warning')
	answer(officer, true, 'started')
end

local function uncuff(officer, suspect, svc)
	if not cuffed[suspect] then return answer(officer, false, 'not_cuffed') end
	endEscort(escortOf[suspect], 'uncuffed')
	local record = recordOf(suspect)
	record.cuffed = nil
	writeRecord(suspect, record)
	cuffed[suspect] = nil
	restrain(suspect, false)
	if config().cuffs.consume then
		local api = inventory()
		if api ~= nil and type(api.AddItem) == 'function' then pcall(api.AddItem, officer, config().cuffs.item, 1) end
	end
	OPX.NotifyLocale(suspect, 'police.suspect.uncuffed', nil, 'info')
	audit('police.uncuff', officer, true, ('%s uncuffed player %d'):format(svc.key, suspect))
	OPX.Publish(Event.ON_CUFFED, suspect, { citizenId = citizenOf(suspect), cuffed = false,
		by = citizenOf(officer), service = svc.key })
	answer(officer, true, 'uncuffed')
end

-- ── escort ───────────────────────────────────────────────────────────────────

local function escort(officer, suspect, svc)
	local held = escorts[officer]
	if held ~= nil then
		endEscort(held, 'released')
		return answer(officer, true, 'escort_ended')
	end
	if not cuffed[suspect] then return answer(officer, false, 'not_cuffed') end
	if escortOf[suspect] ~= nil then return answer(officer, false, 'suspect_busy') end
	if busy[officer] ~= nil then return answer(officer, false, 'busy') end
	local native = Open77.playerInteractions
	if type(native) ~= 'table' or type(native.request) ~= 'function' then
		return answer(officer, false, 'escort_refused')
	end
	local down, stage = downState(suspect)
	if down and stage ~= 'wounded' then return answer(officer, false, 'is_dead') end
	local job = { officer = officer, suspect = suspect, svc = svc, wounded = down }
	-- A wounded body is held on the ground by `downed`; the hold is lifted for the walk.
	if job.wounded then
		local downed = OPX.Api.Get('downed')
		if downed ~= nil and type(downed.SetCarried) == 'function' then
			pcall(downed.SetCarried, suspect, OWNER, true)
		end
	end
	local cfg = config().escort
	local read, state, reason = pcall(native.request, officer, suspect, 'escort', {
		durationMs = cfg.durationMs, startDistance = cfg.startDistance, breakDistance = cfg.breakDistance,
		consent = false,
	})
	if not read or type(state) ~= 'table' or type(state.id) ~= 'string' then
		Open77.log.debug('[police] escort refused: ' .. tostring(read and reason or state))
		job.interactionId = nil
		endEscort(job, 'refused')
		return answer(officer, false, 'escort_refused')
	end
	job.interactionId = state.id
	escorts[officer], escortOf[suspect], byInteraction[state.id] = job, job, job
	audit('police.escort', officer, true, ('%s escorts player %d'):format(svc.key, suspect))
	answer(officer, true, 'escorting')
end

-- Reads a coordinator state: a table, or the JSON the server events may carry.
local function stateOf(value)
	if type(value) == 'string' and type(json) == 'table' then
		local read, decoded = pcall(json.decode, value)
		value = read and decoded or nil
	end
	return type(value) == 'table' and type(value.id) == 'string' and value or nil
end

-- Only this module's own interactions: `medical`, `animations` and
-- `underworld` listen on the same two events.
local function interactionEnded(value)
	local state = stateOf(value)
	local job = state and byInteraction[state.id] or nil
	if job == nil then return end
	endEscort(job, 'interaction')
	answer(job.officer, true, 'escort_ended')
end

-- ── search and evidence ──────────────────────────────────────────────────────

local function searchable(suspect)
	if cuffed[suspect] then return true end
	local down, stage = downState(suspect)
	return down and stage == 'wounded'
end

local function labelOf(name)
	local api = inventory()
	if api ~= nil and type(api.GetItem) == 'function' then
		local read, item = pcall(api.GetItem, name)
		if read and type(item) == 'table' then
			local view = item.ok ~= nil and item.value or item
			if type(view) == 'table' and type(view.label) == 'string' then return view.label end
		end
	end
	return name
end

local function frisk(officer, suspect, svc)
	if not searchable(suspect) then return answer(officer, false, 'not_restrained') end
	local api = inventory()
	if api == nil or type(api.GetInventory) ~= 'function' then return answer(officer, false, 'unavailable') end
	local read, bag = pcall(api.GetInventory, suspect)
	if not read or type(bag) ~= 'table' or not bag.ok or type(bag.value) ~= 'table' then
		return answer(officer, false, 'unavailable')
	end
	local rows = {}
	for _, entry in ipairs(type(bag.value.items) == 'table' and bag.value.items or {}) do
		if #rows >= 64 then break end
		local slot = math.tointeger(entry.slot)
		if slot ~= nil and type(entry.name) == 'string' then
			rows[#rows + 1] = { slot = slot, name = entry.name, label = labelOf(entry.name),
				count = math.tointeger(entry.count) or 1 }
		end
	end
	table.sort(rows, function(a, b) return a.slot < b.slot end)
	frisks[officer] = { target = suspect, atMs = OPX.Now() }
	TriggerClientEvent(Event.FRISK_VIEW, officer, { target = suspect, items = rows })
	OPX.NotifyLocale(suspect, 'police.suspect.frisked', { service = svc.short }, 'warning')
	audit('police.frisk', officer, true, ('%s searched player %d'):format(svc.key, suspect))
end

-- The evidence station for a service: the nearest station it may use that has
-- a locker, or nil.
local function evidenceStation(svc, at)
	local best, bestGap
	for _, key in ipairs(config().stationOrder) do
		local row = config().stations[key]
		if row.services[svc.key] and row.evidence ~= nil then
			local gap = at and gapSq(at, row.evidence) or 0
			if best == nil or gap < bestGap then best, bestGap = row, gap end
		end
	end
	return best
end

local function onConfiscate(officer, payload)
	if type(payload) ~= 'table' then return answer(officer, false, 'invalid') end
	local suspect = math.tointeger(tonumber(payload.target))
	local slot = math.tointeger(tonumber(payload.slot))
	local seen = frisks[officer]
	if suspect == nil or slot == nil or slot < 1 or seen == nil or seen.target ~= suspect
		or OPX.Now() - seen.atMs > FRISK_TTL_MS then
		return answer(officer, false, 'search_first')
	end
	local svc, why = capable(officer, Capability.FRISK)
	if svc == nil then return answer(officer, false, why) end
	if not within(positionOf(officer), positionOf(suspect), config().reach) then
		return answer(officer, false, 'too_far')
	end
	if not searchable(suspect) then return answer(officer, false, 'not_restrained') end
	local station = evidenceStation(svc, positionOf(officer))
	if station == nil then return answer(officer, false, 'no_locker') end
	local api = inventory()
	if api == nil or type(api.GetSlot) ~= 'function' or type(api.RemoveFromSlot) ~= 'function'
		or type(api.AddToStash) ~= 'function' then
		return answer(officer, false, 'unavailable')
	end
	local read, held = pcall(api.GetSlot, suspect, slot)
	local entry = read and type(held) == 'table' and held.ok and held.value or nil
	if type(entry) ~= 'table' or type(entry.name) ~= 'string' then return answer(officer, false, 'no_item') end
	local count = math.tointeger(entry.count) or 1
	-- OUT OF THE BAG FIRST, INTO THE LOCKER SECOND: a failure in between hands
	-- it back, so nothing is ever in two places.
	local took, removed = pcall(api.RemoveFromSlot, suspect, slot, count)
	if not took or type(removed) ~= 'table' or not removed.ok then return answer(officer, false, 'no_item') end
	local put, stored = pcall(api.AddToStash, station.stash, entry.name, count, entry.metadata)
	if not put or type(stored) ~= 'table' or not stored.ok then
		pcall(api.AddItem, suspect, entry.name, count, entry.metadata)
		return answer(officer, false, 'locker_full')
	end
	audit('police.confiscate', officer, true, ('%dx %s from player %d into %s'):format(count, entry.name,
		suspect, station.stash))
	answer(officer, true, 'confiscated', { item = labelOf(entry.name), count = count, station = station.label })
	frisk(officer, suspect, svc)
end

local function onEvidence(player, payload)
	local station = type(payload) == 'table' and config().stations[payload.station] or nil
	if station == nil or station.evidence == nil then return answer(player, false, 'no_locker') end
	local svc
	for key in pairs(station.services) do
		local candidate = config().services[key]
		local grade = candidate.capabilities[Capability.FRISK]
		if grade ~= nil and member(player, candidate, grade) then svc = candidate break end
	end
	if svc == nil then return answer(player, false, 'not_member') end
	local here = positionOf(player)
	if not within(here, station.evidence, station.evidence.radius) then return answer(player, false, 'too_far') end
	local api = inventory()
	if api == nil or type(api.OpenStash) ~= 'function' then return answer(player, false, 'unavailable') end
	local read, opened = pcall(api.OpenStash, player, station.stash, {
		slots = station.evidence.slots, maxWeight = station.evidence.maxWeight,
		label = locale('police.evidence.title', { station = station.label }),
		position = { x = station.evidence.x, y = station.evidence.y, z = station.evidence.z },
	})
	if not read or type(opened) ~= 'table' or not opened.ok then
		return answer(player, false, 'unavailable')
	end
	audit('police.evidence', player, true, station.stash)
end

-- ── fines ────────────────────────────────────────────────────────────────────

local function fineChoices()
	local rows = {}
	for _, code in ipairs(config().crimeOrder) do
		local ceiling = Access.FineCeiling(config(), code)
		if ceiling > 0 then
			local crime = crimeOf(code)
			rows[#rows + 1] = { code = code, label = crime.label, fine = math.min(crime.fine, ceiling), max = ceiling }
		end
	end
	return rows
end

local function showFine(officer, suspect)
	local rows = fineChoices()
	if #rows == 0 then return answer(officer, false, 'no_crimes') end
	TriggerClientEvent(Event.FINE_VIEW, officer, { target = suspect, crimes = rows,
		moneyType = config().fines.moneyType })
end

-- What is left of a payment after the officer's cut: into the service's job
-- account when the `accounts` contract runs, else out of the economy.
local function deposit(svc, amount, reason, opId)
	if amount <= 0 or svc == nil or svc.account == nil then return false end
	local accounts = OPX.Api.Get('accounts')
	if accounts == nil or type(accounts.Deposit) ~= 'function' then return false end
	local read, done = pcall(accounts.Deposit, 'job', svc.account, amount, reason, opId)
	return read and type(done) == 'table' and done.ok == true
end

local function onFine(officer, payload)
	if type(payload) ~= 'table' then return answer(officer, false, 'invalid') end
	local suspect = math.tointeger(tonumber(payload.target))
	if suspect == nil or suspect == officer then return answer(officer, false, 'no_suspect') end
	local svc, why = capable(officer, Capability.FINE)
	if svc == nil then return answer(officer, false, why) end
	local code = type(payload.code) == 'string' and payload.code or nil
	local ceiling = code and Access.FineCeiling(config(), code) or 0
	if ceiling <= 0 then return answer(officer, false, 'bad_crime') end
	local amount = math.tointeger(tonumber(payload.amount))
	if amount == nil or amount < 1 then return answer(officer, false, 'bad_amount') end
	if amount > ceiling then return answer(officer, false, 'over_ceiling', { amount = ceiling }) end
	if citizenOf(suspect) == nil then return answer(officer, false, 'no_suspect') end
	if not within(positionOf(officer), positionOf(suspect), config().reach) then
		return answer(officer, false, 'too_far')
	end
	local reason = cleanText(payload.reason, 120)
	local fines = config().fines
	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return answer(officer, false, 'unavailable') end
	local paid, owed, cut = Access.SplitFine(amount, balanceOf(suspect, fines.moneyType), fines.cutPercent)
	local tag = ('police:fine:%s:%s'):format(svc.key, code)
	if paid > 0 then
		local read, ok = pcall(api.RemoveMoney, suspect, fines.moneyType, paid, tag)
		if not read or ok ~= true then paid, owed, cut = 0, amount, 0 end
	end
	if owed > 0 then
		local record = recordOf(suspect)
		record.debt = debtOf(record) + owed
		writeRecord(suspect, record)
	end
	if cut > 0 and type(api.AddMoney) == 'function' then
		local read, ok = pcall(api.AddMoney, officer, fines.cutMoneyType, cut, tag .. ':cut')
		if not read or ok ~= true then cut = 0 end
	end
	deposit(svc, paid - cut, tag, nil)
	local suspectCid, officerCid = citizenOf(suspect), citizenOf(officer)
	OPX.Audit.Log({ event = 'police.fine', source = officer, message = ('%s fined %s %d for %s: paid %d owed %d cut %d')
		:format(svc.key, tostring(suspectCid), amount, code, paid, owed, cut),
		data = { reason = reason, service = svc.key, code = code } })
	OPX.Publish(Event.ON_FINED, suspect, { citizenId = suspectCid, officer = officerCid, service = svc.key,
		code = code, amount = amount, paid = paid, owed = owed })
	local money = OPX.Locale.Money(amount, fines.moneyType)
	OPX.NotifyLocale(suspect, owed > 0 and 'police.suspect.finedDebt' or 'police.suspect.fined',
		{ service = svc.short, amount = money, crime = crimeOf(code).label,
			owed = OPX.Locale.Money(owed, fines.moneyType) }, owed > 0 and 'warning' or 'info')
	answer(officer, true, 'fined', { amount = amount, paid = paid, owed = owed, cut = cut,
		moneyType = fines.moneyType })
end

local function onDesk(player, payload)
	local station = type(payload) == 'table' and config().stations[payload.station] or nil
	if station == nil or station.desk == nil then return answer(player, false, 'no_desk') end
	if not within(positionOf(player), station.desk, station.desk.radius) then
		return answer(player, false, 'too_far')
	end
	local record = recordOf(player)
	local owed = debtOf(record)
	local moneyType = config().fines.moneyType
	if payload.pay ~= true then
		return TriggerClientEvent(Event.DESK_VIEW, player, { station = station.key, label = station.label,
			debt = owed, moneyType = moneyType })
	end
	if owed <= 0 then return answer(player, false, 'no_debt') end
	local paying = math.min(owed, balanceOf(player, moneyType))
	if paying <= 0 then return answer(player, false, 'cannot_afford') end
	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return answer(player, false, 'unavailable') end
	local read, ok = pcall(api.RemoveMoney, player, moneyType, paying, 'police:debt:' .. station.key)
	if not read or ok ~= true then return answer(player, false, 'cannot_afford') end
	record.debt = owed - paying > 0 and owed - paying or nil
	writeRecord(player, record)
	local svcKey = next(station.services)
	deposit(svcKey and config().services[svcKey] or nil, paying, 'police:debt:' .. station.key, nil)
	audit('police.debt', player, true, ('settled %d of %d at %s'):format(paying, owed, station.key))
	answer(player, true, record.debt and 'debt_part' or 'debt_paid', { amount = paying,
		owed = record.debt or 0, moneyType = moneyType })
end

-- ── jail ─────────────────────────────────────────────────────────────────────

local function cellOf(sentence)
	local station = type(sentence) == 'table' and config().stations[sentence.station] or nil
	if station == nil then return nil, nil end
	for _, cell in ipairs(station.cells) do
		if cell.index == sentence.cell then return cell, station end
	end
	return station.cells[1], station
end

local function teleport(player, at)
	local players = Open77.players
	if at == nil or type(players) ~= 'table' or type(players.teleport) ~= 'function' then return false end
	local read, pending, reason = pcall(players.teleport, player, { x = at.x, y = at.y, z = at.z },
		{ heading = at.yaw, dismount = true })
	if not read or pending == nil then
		Open77.log.debug(('[police] teleport of %d refused: %s'):format(player, tostring(read and reason or pending)))
		return false
	end
	return true
end

-- The cell of a station holding the fewest prisoners now.
local function freeCell(station)
	local held = {}
	for _, sentence in pairs(jailed) do
		if sentence.station == station.key then held[sentence.cell] = (held[sentence.cell] or 0) + 1 end
	end
	local best
	for _, cell in ipairs(station.cells) do
		if best == nil or (held[cell.index] or 0) < (held[best.index] or 0) then best = cell end
	end
	return best
end

local function showJail(officer, suspect, svc)
	if not cuffed[suspect] then return answer(officer, false, 'not_cuffed') end
	local station = Access.StationAt(config(), svc.key, positionOf(officer))
	if station == nil then return answer(officer, false, 'not_at_station') end
	local rows = {}
	for _, code in ipairs(config().crimeOrder) do
		local crime = crimeOf(code)
		rows[#rows + 1] = { code = code, label = crime.label, minutes = crime.jailMin }
	end
	TriggerClientEvent(Event.JAIL_VIEW, officer, { target = suspect, station = station.label, crimes = rows,
		max = config().jail.maxMinutes })
end

local function onJail(officer, payload)
	if type(payload) ~= 'table' then return answer(officer, false, 'invalid') end
	local suspect = math.tointeger(tonumber(payload.target))
	if suspect == nil or suspect == officer then return answer(officer, false, 'no_suspect') end
	local svc, why = capable(officer, Capability.JAIL)
	if svc == nil then return answer(officer, false, why) end
	local code = type(payload.code) == 'string' and crimeOf(payload.code) and payload.code or nil
	if code == nil then return answer(officer, false, 'bad_crime') end
	local minutes = Access.Minutes(config(), payload.minutes)
	if minutes == nil then return answer(officer, false, 'bad_minutes') end
	if not cuffed[suspect] then return answer(officer, false, 'not_cuffed') end
	if not within(positionOf(officer), positionOf(suspect), config().reach) then
		return answer(officer, false, 'too_far')
	end
	local station = Access.StationAt(config(), svc.key, positionOf(officer))
	if station == nil then return answer(officer, false, 'not_at_station') end
	local now = wallSeconds()
	if now == nil then return answer(officer, false, 'unavailable') end
	local cell = freeCell(station)
	endEscort(escortOf[suspect], 'jailed')
	local sentence = { station = station.key, cell = cell.index, code = code, by = citizenOf(officer),
		reason = cleanText(payload.reason, 120), at = math.floor(now) }
	if config().jail.offlineServes then
		sentence.untilS = math.floor(now + minutes * 60)
	else
		sentence.totalS, sentence.servedS = minutes * 60, 0
	end
	local record = recordOf(suspect)
	record.cuffed, record.jail = nil, sentence
	if not writeRecord(suspect, record) then return answer(officer, false, 'unavailable') end
	cuffed[suspect] = nil
	restrain(suspect, false)
	jailed[suspect] = sentence
	leashedAt[suspect] = OPX.Now()
	teleport(suspect, cell)
	OPX.NotifyLocale(suspect, 'police.jail.sentenced', { minutes = minutes, station = station.label,
		crime = crimeOf(code).label }, 'warning')
	OPX.Audit.Log({ event = 'police.jail', source = officer, message = ('%s jailed %s for %d min (%s) at %s')
		:format(svc.key, tostring(citizenOf(suspect)), minutes, code, station.key) })
	OPX.Publish(Event.ON_JAILED, suspect, { citizenId = citizenOf(suspect), officer = citizenOf(officer),
		minutes = minutes, station = station.key, code = code, released = false })
	answer(officer, true, 'jailed', { minutes = minutes })
end

-- Ends a sentence: the record cleared, the body walked out the front door.
local function freeFromJail(player, why)
	local sentence = jailed[player]
	jailed[player], leashedAt[player], servedWrite[player] = nil, nil, nil
	local record = recordOf(player)
	local stationKey = sentence and sentence.station or (type(record.jail) == 'table' and record.jail.station)
	record.jail = nil
	writeRecord(player, record)
	local station = stationKey and config().stations[stationKey] or nil
	if station ~= nil and station.release ~= nil then teleport(player, station.release) end
	OPX.NotifyLocale(player, 'police.jail.released', nil, 'success')
	OPX.Publish(Event.ON_JAILED, player, { citizenId = citizenOf(player), released = true, why = why,
		station = stationKey })
end

-- ── impound ──────────────────────────────────────────────────────────────────

local function vehiclePosition(id)
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.get) ~= 'function' then return nil end
	local read, car = pcall(vehicles.get, id)
	if not read or type(car) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(car.x), OPX.Math.Finite(car.y), OPX.Math.Finite(car.z)
	if x == nil and type(car.position) == 'table' then
		x, y, z = OPX.Math.Finite(car.position.x), OPX.Math.Finite(car.position.y), OPX.Math.Finite(car.position.z)
	end
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

local function finishImpound(job, completed)
	if job.done then return end
	job.done = true
	release(job)
	if not completed then return answer(job.officer, false, 'interrupted') end
	local svc = capable(job.officer, Capability.IMPOUND)
	if svc == nil then return answer(job.officer, false, 'not_member') end
	local here, there = positionOf(job.officer), vehiclePosition(job.vehicleId)
	if here == nil or there == nil or not within(here, there, config().impound.reach) then
		return answer(job.officer, false, 'vehicle_far')
	end
	local vehicles = OPX.Api.Get('vehicles')
	local plate = nil
	if vehicles ~= nil and type(vehicles.PlateOf) == 'function' then
		local read, found = pcall(vehicles.PlateOf, job.vehicleId)
		plate = read and type(found) == 'string' and found or nil
	end
	if plate ~= nil then
		local read, done = pcall(vehicles.SetState, plate, 'impounded', config().impound.garage)
		if not read or type(done) ~= 'table' or not done.ok then
			return answer(job.officer, false, read and type(done) == 'table' and done.error == 'vehicle.occupied'
				and 'vehicle_occupied' or 'impound_failed')
		end
		audit('police.impound', job.officer, true, ('%s impounded %s'):format(svc.key, plate))
		return answer(job.officer, true, 'impounded', { plate = plate })
	end
	if not config().impound.removeUnowned then return answer(job.officer, false, 'not_registered') end
	local native = Open77.vehicles
	local read, removed = false, nil
	if type(native) == 'table' and type(native.remove) == 'function' then
		read, removed = pcall(native.remove, job.vehicleId)
	end
	if not read or removed == false or removed == nil then return answer(job.officer, false, 'impound_failed') end
	audit('police.impound', job.officer, true, ('%s towed unowned vehicle %s'):format(svc.key,
		tostring(job.vehicleId)))
	answer(job.officer, true, 'towed')
end

local function onImpound(officer, payload)
	local id = math.tointeger(tonumber(type(payload) == 'table' and payload.vehicleId or nil))
	if id == nil or id < 1 then return answer(officer, false, 'vehicle_far') end
	local svc, why = capable(officer, Capability.IMPOUND)
	if svc == nil then return answer(officer, false, why) end
	if busy[officer] ~= nil then return answer(officer, false, 'busy') end
	local here, there = positionOf(officer), vehiclePosition(id)
	if here == nil or there == nil or not within(here, there, config().impound.reach) then
		return answer(officer, false, 'vehicle_far')
	end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return answer(officer, false, 'no_bar') end
	local job = { kind = 'impound', officer = officer, vehicleId = id }
	busy[officer] = job
	local started = progress.Start(officer, OWNER, {
		label = locale('police.bar.impound'), durationMs = config().impound.durationMs, cancelable = true,
	}, function(_, outcome)
		finishImpound(job, type(outcome) == 'table' and outcome.completed == true)
	end)
	if type(started) ~= 'table' or not started.ok then
		release(job)
		return answer(officer, false, 'no_bar')
	end
	job.barId = type(started.value) == 'table' and started.value.id or nil
	answer(officer, true, 'started')
end

-- ── what may I do to this player ─────────────────────────────────────────────

-- Each action, the capability it needs, and whether the suspect's state allows it.
local ACTIONS = { 'cuff', 'uncuff', 'escort', 'frisk', 'fine', 'jail' }

local function allowed(action, officer, suspect)
	local isCuffed = cuffed[suspect] == true
	if action == 'cuff' then return not isCuffed end
	if action == 'uncuff' then return isCuffed end
	if action == 'escort' then return isCuffed or (escorts[officer] ~= nil and escorts[officer].suspect == suspect) end
	if action == 'frisk' then return searchable(suspect) end
	if action == 'jail' then return isCuffed end
	return true
end

local function onOptions(officer, payload)
	local suspect = math.tointeger(tonumber(type(payload) == 'table' and payload.target or nil))
	if suspect == nil or suspect == officer or citizenOf(suspect) == nil then
		return answer(officer, false, 'no_suspect')
	end
	if not within(positionOf(officer), positionOf(suspect), config().reach) then
		return answer(officer, false, 'too_far')
	end
	local rows, refusal = {}, nil
	for _, action in ipairs(ACTIONS) do
		local svc, why = capable(officer, M.Action[action])
		if svc ~= nil then
			if allowed(action, officer, suspect) then
				local label = action
				if action == 'escort' and escorts[officer] ~= nil then label = 'release' end
				rows[#rows + 1] = { action = action, label = 'police.action.' .. label, short = svc.short }
			end
		elseif why == 'out_of_jurisdiction' then
			refusal = why
		end
	end
	if #rows == 0 then return answer(officer, false, refusal or 'nothing_to_do') end
	TriggerClientEvent(Event.OPTIONS_VIEW, officer, { target = suspect, rows = rows })
end

local function onAct(officer, payload)
	if type(payload) ~= 'table' then return answer(officer, false, 'invalid') end
	local action = type(payload.action) == 'string' and M.Action[payload.action] and payload.action or nil
	local suspect = math.tointeger(tonumber(payload.target))
	if action == nil or suspect == nil or suspect == officer then return answer(officer, false, 'invalid') end
	local svc, why = capable(officer, M.Action[action])
	if svc == nil then return answer(officer, false, why) end
	-- Releasing the suspect you walk needs no other check: it only ever ends what you hold.
	if action == 'escort' and escorts[officer] ~= nil then return escort(officer, suspect, svc) end
	if citizenOf(suspect) == nil then return answer(officer, false, 'no_suspect') end
	if not within(positionOf(officer), positionOf(suspect), config().reach) then
		return answer(officer, false, 'too_far')
	end
	if action == 'cuff' then return cuff(officer, suspect, svc) end
	if action == 'uncuff' then return uncuff(officer, suspect, svc) end
	if action == 'escort' then return escort(officer, suspect, svc) end
	if action == 'frisk' then return frisk(officer, suspect, svc) end
	if action == 'fine' then return showFine(officer, suspect) end
	if action == 'jail' then return showJail(officer, suspect, svc) end
end

-- ── the damage arbiter ───────────────────────────────────────────────────────

-- A cuffed player deals no damage. Runs on the server tick in the damage path:
-- one table read, nothing else. Several arbiters coexist; the first false wins.
local function arbitrate(event)
	if type(event) ~= 'table' then return nil end
	local attacker = math.tointeger(tonumber(event.attacker))
	if attacker ~= nil and cuffed[attacker] and attacker ~= math.tointeger(tonumber(event.victim)) then
		return false
	end
	return nil
end

-- ── loading, leaving and the sweep ───────────────────────────────────────────

local function onLoaded(rawPlayer)
	local player = math.tointeger(tonumber(rawPlayer))
	if player == nil then return end
	local record = recordOf(player)
	if type(record.cuffed) == 'table' then
		cuffed[player] = true
		restrain(player, true)
	end
	if type(record.jail) == 'table' then
		jailed[player] = record.jail
		-- Put back by the leash on the next sweep, once the spawn has placed them.
		leashedAt[player] = OPX.Now()
	end
end

local function forget(player)
	cuffed[player], jailed[player], frisks[player], lastEmergency[player] = nil, nil, nil, nil
	leashedAt[player], servedWrite[player] = nil, nil
	local prefix = tostring(player) .. ':'
	for slot in pairs(lastRequest) do
		if slot:sub(1, #prefix) == prefix then lastRequest[slot] = nil end
	end
end

local function departed(rawPlayer)
	local player = math.tointeger(tonumber(rawPlayer))
	if player == nil then return end
	Dispatch.Forget(player)
	for _, call in ipairs(Dispatch.CloseKey('down:' .. player)) do announceClosed(call, 'officer_left') end
	endEscort(escorts[player], 'left')
	endEscort(escortOf[player], 'left')
	local job = busy[player]
	if job ~= nil then
		local progress = OPX.Api.Get('progress')
		if job.barId ~= nil and progress ~= nil and type(progress.Stop) == 'function' then
			pcall(progress.Stop, job.officer, OWNER, job.barId)
		end
		job.done = true
		busy[player] = nil
	end
	forget(player)
end

local function sweep()
	local now = OPX.Now()
	local elapsedS = lastSweepMs and math.max(0, (now - lastSweepMs) / 1000) or 0
	lastSweepMs = now
	for _, call in ipairs(Dispatch.Expire(now)) do announceClosed(call, 'expired') end
	local wall = wallSeconds()
	for player, sentence in pairs(jailed) do
		if sentence.untilS == nil and sentence.totalS ~= nil then
			sentence.servedS = (OPX.Math.Finite(sentence.servedS) or 0) + elapsedS
			if now - (servedWrite[player] or 0) >= SERVED_WRITE_S * 1000 then
				servedWrite[player] = now
				local record = recordOf(player)
				if type(record.jail) == 'table' then
					record.jail.servedS = math.floor(sentence.servedS)
					writeRecord(player, record)
				end
			end
		end
		if Access.Remaining(sentence, wall) <= 0 then
			freeFromJail(player, 'served')
		elseif now - (leashedAt[player] or 0) >= LEASH_GRACE_MS then
			local cell = cellOf(sentence)
			local here = positionOf(player)
			if cell ~= nil and here ~= nil and not within(here, { x = cell.x, y = cell.y, z = cell.z,
				bucket = here.bucket }, config().jail.leash) then
				leashedAt[player] = now
				teleport(player, cell)
				OPX.NotifyLocale(player, 'police.jail.leash', nil, 'warning')
			end
		end
	end
end

-- ── staff ────────────────────────────────────────────────────────────────────

local CAPTURE_KINDS = { station = true, desk = true, evidence = true, cell = true, release = true, enclave = true }

local function capture(source, args)
	if source == nil or source <= 0 then return OPX.CommandResult(source, false, 'stand in the world to capture') end
	local kind, name = args[1], args[2]
	if not CAPTURE_KINDS[kind] or type(name) ~= 'string' or not name:match('^[%w_]+$') then
		local lines = { 'usage: opx.police.capture <station|desk|evidence|cell|release|enclave> <station|service>' }
		for _, key in ipairs(config().stationOrder) do
			local row = config().stations[key]
			lines[#lines + 1] = ('  station %s: building %s, desk %s, evidence %s, %d cell(s), release %s'):format(key,
				row.center and 'ok' or 'OFF', row.desk and 'ok' or 'OFF', row.evidence and 'ok' or 'OFF', #row.cells,
				row.release and 'ok' or 'OFF')
		end
		return OPX.CommandResult(source, false, table.concat(lines, '\n'))
	end
	local at = positionOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local yaw = 0.0
	local players = Open77.players
	if type(players) == 'table' and type(players.get) == 'function' then
		local read, snapshot = pcall(players.get, source)
		yaw = read and type(snapshot) == 'table' and OPX.Math.Finite(snapshot.heading) or 0.0
	end
	local xyz = ('X = %.2f, Y = %.2f, Z = %.2f'):format(at.x, at.y, at.z)
	local line
	if kind == 'station' then
		line = ('STATIONS.%s: %s, RADIUS = 40.0,'):format(name, xyz)
	elseif kind == 'desk' or kind == 'evidence' then
		line = ('STATIONS.%s.%s = { %s, RADIUS = 1.5 },'):format(name, kind:upper(), xyz)
	elseif kind == 'cell' then
		line = ('STATIONS.%s.CELLS: { %s, YAW = %.1f },'):format(name, xyz, yaw)
	elseif kind == 'release' then
		line = ('STATIONS.%s.RELEASE = { %s, YAW = %.1f },'):format(name, xyz, yaw)
	else
		line = ('SERVICES.%s.ENCLAVES: { LABEL = \'...\', %s, RADIUS = 120.0 },'):format(name, xyz)
	end
	OPX.Audit.Log({ event = 'police.capture', message = line, source = source })
	OPX.CommandResult(source, true, 'paste into config/police.lua, then restart:\n  ' .. line)
end

local function staffRelease(source, args)
	local player = math.tointeger(tonumber(args[1]))
	if player == nil or citizenOf(player) == nil then
		return OPX.CommandResult(source, false, 'usage: opx.police.release <player id>')
	end
	endEscort(escortOf[player], 'staff')
	local wasCuffed, wasJailed = cuffed[player] == true, jailed[player] ~= nil
	if wasJailed then freeFromJail(player, 'staff') end
	local record = recordOf(player)
	if record.cuffed ~= nil or record.jail ~= nil then
		record.cuffed, record.jail = nil, nil
		writeRecord(player, record)
	end
	cuffed[player] = nil
	restrain(player, false)
	OPX.Audit.Log({ event = 'police.staffRelease', severity = 'warn', source = source,
		message = ('player %d released (cuffed %s, jailed %s)'):format(player, tostring(wasCuffed), tostring(wasJailed)) })
	OPX.CommandResult(source, true, ('player %d is free'):format(player))
end

local function unimpound(source, args)
	local plate = type(args[1]) == 'string' and args[1]:upper() or nil
	local vehicles = OPX.Api.Get('vehicles')
	if plate == nil or vehicles == nil or type(vehicles.SetState) ~= 'function' then
		return OPX.CommandResult(source, false, 'usage: opx.police.unimpound <plate>')
	end
	CreateThread(function()
		local read, done = pcall(vehicles.SetState, plate, 'stored', nil)
		local ok = read and type(done) == 'table' and done.ok == true
		OPX.Audit.Log({ event = 'police.unimpound', severity = ok and 'info' or 'warn', source = source,
			message = plate })
		OPX.CommandResult(source, ok, ok and (plate .. ' is back in its garage')
			or ('%s could not be released: %s'):format(plate, tostring(read and type(done) == 'table' and done.error or done)))
	end)
end

local function registerCommands()
	OPX.Command.Register('opx.police.capture', { restricted = true, help = 'police.help.capture',
		params = { { name = 'kind', help = locale('police.help.kind') },
			{ name = 'name', help = locale('police.help.name') } } },
		function(source, args) capture(source, args) end)
	OPX.Command.Register('opx.police.release', { restricted = true, help = 'police.help.release',
		params = { { name = 'id', help = locale('police.help.id') } } },
		function(source, args) staffRelease(source, args) end)
	OPX.Command.Register('opx.police.unimpound', { restricted = true, help = 'police.help.unimpound',
		params = { { name = 'plate', help = locale('police.help.plate') } } },
		function(source, args) unimpound(source, args) end)
	local cfg = config().emergency
	if cfg.enabled then
		OPX.Command.Register(cfg.command, { help = 'police.help.emergency', cooldownMs = 1000,
			params = { { name = 'text', help = locale('police.help.text') } } },
			function(source, args)
				local player = math.tointeger(tonumber(source))
				if player == nil or player <= 0 then return end
				CreateThread(function() emergency(player, args) end)
			end)
	end
end

-- ── the cuffs item ───────────────────────────────────────────────────────────

local function registerItems()
	local cfg = config().cuffs
	local api = inventory()
	if cfg.item == nil then return end
	if api == nil or type(api.RegisterItem) ~= 'function' then
		Open77.log.warn('[police] no inventory contract: nobody can carry cuffs, so nobody can cuff')
		return
	end
	if type(api.GetItem) == 'function' then
		local read, known = pcall(api.GetItem, cfg.item)
		if read and known ~= nil and not (type(known) == 'table' and known.ok == true and known.value == nil) then
			return
		end
	end
	local read, done = pcall(api.RegisterItem, cfg.item, { label = cfg.label, description = cfg.description,
		weight = cfg.weight, stack = true, model = cfg.model }, OWNER)
	if not read or type(done) ~= 'table' or done.ok ~= true then
		Open77.log.warn(('[police] the item %s could not be registered: %s'):format(cfg.item,
			tostring(read and type(done) == 'table' and done.error or done)))
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state.
-- @author dop42
function M.Init()
	settings = nil
	cuffed, jailed, busy, escorts, escortOf, byInteraction = {}, {}, {}, {}, {}, {}
	frisks, lastRequest, lastEmergency, leashedAt, servedWrite = {}, {}, {}, {}, {}
	lastSweepMs, arbiter = nil, nil
	Dispatch.Reset()
end

--- Publishes the server contract, in the shapes `underworld` and `netrunner`
--- already call.
-- @author dop42
function M.Api()
	OPX.Api.Provide('police', 1, {
		Report = function(spec)
			local read, outcome = pcall(report, spec)
			if not read then
				Open77.log.warn('[police] Report raised: ' .. tostring(outcome))
				return Result.Err('failed')
			end
			return outcome
		end,
		Alert = function(spec)
			local read, outcome = pcall(alertJobs, spec)
			return read and outcome == true
		end,
		OnDutyCount = function()
			local read, count = pcall(onDutyCount)
			return read and count or 0
		end,
		IsCuffed = function(player) return cuffed[math.tointeger(tonumber(player)) or -1] == true end,
		IsJailed = function(player)
			local sentence = jailed[math.tointeger(tonumber(player)) or -1]
			return sentence ~= nil, sentence and Access.Remaining(sentence, wallSeconds()) or 0
		end,
		Calls = function(service)
			local rows = {}
			for _, call in ipairs(Dispatch.List(type(service) == 'string' and { [service] = true } or nil)) do
				rows[#rows + 1] = { id = call.id, service = call.service, crime = call.crime, label = call.label,
					priority = call.priority, source = call.source, responders = Dispatch.Count(call) }
			end
			return Result.Ok(rows)
		end,
		Services = function() return Result.Ok(OPX.Table.DeepCopy(config().serviceOrder)) end,
	})
end

--- Wires the requests, the buses, the arbiter, the commands and the sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Access.Problems(OPX.Config.MODULES.police)) do
		Open77.log.warn('[police] config: ' .. line)
	end

	local function wire(name, kind, handler)
		RegisterNetEvent(name, function(payload)
			local player = math.tointeger(tonumber(source))
			if player == nil or player <= 0 then return end
			if cooled(player, kind) then return answer(player, false, 'rate_limited') end
			-- On a thread: the bag, the account and the vehicle rows may yield.
			CreateThread(function() handler(player, payload) end)
		end)
	end
	wire(Event.BOARD, 'board', onBoard)
	wire(Event.TAKE, 'take', onTake)
	wire(Event.DROP, 'drop', onDrop)
	wire(Event.OPTIONS, 'options', onOptions)
	wire(Event.ACT, 'act', onAct)
	wire(Event.FINE, 'fine', onFine)
	wire(Event.JAIL, 'jail', onJail)
	wire(Event.CONFISCATE, 'confiscate', onConfiscate)
	wire(Event.IMPOUND, 'impound', onImpound)
	wire(Event.DESK, 'desk', onDesk)
	wire(Event.EVIDENCE, 'evidence', onEvidence)

	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), onDownedChanged)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'loaded'), onLoaded)
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'unloaded'), departed)
	AddEventHandler('onPlayerInteractionCompleted', interactionEnded)
	AddEventHandler('onPlayerInteractionCancelled', interactionEnded)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	local combat = Open77.combat
	if type(combat) == 'table' and type(combat.onDamage) == 'function' then
		local read, installed = pcall(combat.onDamage, arbitrate)
		arbiter = read and installed or nil
	end
	if arbiter == nil then
		Open77.log.warn('[police] no damage arbiter: a cuffed player\'s hits are blocked on their client only')
	end

	registerItems()
	registerCommands()

	-- A reload with characters already loaded: read their records now.
	for _, player in ipairs(playerIds()) do
		if citizenOf(player) ~= nil then onLoaded(player) end
	end

	OPX.Scheduler.Every('police:sweep', config().scanMs, sweep)

	Open77.log.info(('[police] %d service(s): %s; %d station(s)'):format(#config().serviceOrder,
		table.concat(config().serviceOrder, ', '), #config().stationOrder))
end

--- Ends every escort and bar this module holds, and takes the arbiter down.
-- @author dop42
function M.Stop()
	for _, job in pairs(escorts) do endEscort(job, 'stopping') end
	for _, job in pairs(busy) do job.done = true end
	local combat = Open77.combat
	if arbiter ~= nil and type(combat) == 'table' and type(combat.offDamage) == 'function' then
		pcall(combat.offDamage, arbiter)
	end
	arbiter = nil
	busy, escorts, escortOf, byInteraction = {}, {}, {}, {}
end

-- Exposed for the tests: the handlers and the arithmetic, by name.
M.Server = {
	OnBoard = onBoard, OnTake = onTake, OnOptions = onOptions, OnAct = onAct, OnFine = onFine, OnJail = onJail,
	OnConfiscate = onConfiscate, OnDesk = onDesk, OnImpound = onImpound, OnDownedChanged = onDownedChanged,
	OnLoaded = onLoaded, Emergency = emergency, Report = report, Alert = alertJobs, Sweep = sweep,
	Arbitrate = arbitrate, InteractionEnded = interactionEnded, Departed = departed,
	FinishCuff = finishCuff,
}
