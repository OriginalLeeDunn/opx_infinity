--- Server half: the enclaves, the trespassers, the detention and the handoff.
-- @author dop42
--
-- CORP SECURITY ONLY RULES INSIDE ITS WALLS. An ENCLAVE is the ground around a
-- corp's building -- the plaza, the yard -- gated by the same `OPX.JobGate`
-- the elevators ask about their floors (a floor above the lobby is still the
-- elevator's to refuse). A tick reads where every loaded character stands; one
-- inside an enclave they may not stand in is TRESPASSING: told so once, and the
-- corp's security on shift is told where.
--
-- A DETENTION IS A HANDOFF, NOT A SENTENCE. Security (the corp's job at grade
-- SECURITY_GRADE or above, clocked in when the corp asks it) detains a
-- trespasser after a server-timed bar within reach; the suspect goes to the
-- `police` module when it runs (`Handoff` and/or `Report`), else every on-duty
-- member of SECURITY.POLICE_JOBS is alerted. Security never jails or fines --
-- that is NCPD's job -- but may walk the suspect out to the enclave's EJECT.

local M = OPX.Modules.Get('corpo')
local Access = M.Access

local OWNER = 'corpo'

M.Security = {}
local Security = M.Security
local S = M.Server

local built = nil
-- `corp.enclave` -> player -> { warnedAt, alertedAt }
local inside = {}
-- detainer -> { suspect, corp, enclave, barId }
local detentions = {}
-- player -> the last role string sent
local roles = {}
local tickJob = nil

local function enclaveId(enclave) return enclave.corp .. '.' .. enclave.key end

--- Whether a loaded character may stand in an enclave.
local function authorized(loaded, enclave)
	local corp = built.corps[enclave.corp]
	local ok = OPX.JobGate.Evaluate(Access.EnclaveRequirement(enclave, corp), S.SnapshotOf(loaded), OPX.Now(),
		{ maxAgeMs = 5000, membership = 'any' })
	return ok
end

--- Whether a loaded character is corp security, and for which corp.
local function securityOf(loaded)
	local corp, grade, onDuty = S.RoleOf(loaded)
	if corp == nil or grade < corp.securityGrade or (corp.onDuty and not onDuty) then return nil end
	return corp
end

-- ── the role the eye reads ──────────────────────────────────────────────────

--- Tells a client what the eye may offer it; only when it changed, unless forced.
--- The clock only refreshes a client that said hello: nobody is sent a role
--- they never asked for.
function Security.SendRole(player, force)
	if not force and roles[player] == nil then return end
	local loaded = S.PlayerOf(player)
	local corp, grade = nil, nil
	if loaded ~= nil then corp, grade = S.RoleOf(loaded) end
	local security = loaded ~= nil and securityOf(loaded) ~= nil
	local key = corp and ('%s:%d:%s'):format(corp.key, grade, tostring(security)) or 'none'
	if not force and roles[player] == key then return end
	roles[player] = key
	TriggerClientEvent(M.Event.ROLE, player, corp and { corp = corp.key, grade = grade, security = security or nil }
		or false)
end

-- ── the watch ───────────────────────────────────────────────────────────────

local function alertSecurity(corp, enclave, at)
	local api = S.Character()
	if api == nil or type(api.GetPlayers) ~= 'function' then return end
	local read, list = pcall(api.GetPlayers)
	if not read or type(list) ~= 'table' then return end
	local payload = { kind = 'trespass', corp = corp.label, label = enclave.label, x = at.x, y = at.y, z = at.z }
	for index = 1, #list do
		local loaded = list[index]
		local guard = securityOf(loaded)
		if guard ~= nil and guard.key == corp.key then
			TriggerClientEvent(M.Event.ALERT, loaded.PlayerData.source, payload)
		end
	end
end

--- One look at every enclave.
-- @author dop42
function Security.Tick()
	local api = S.Character()
	if api == nil or type(api.GetPlayers) ~= 'function' then return end
	local read, list = pcall(api.GetPlayers)
	if not read or type(list) ~= 'table' then return end
	local now = OPX.Now()
	for index = 1, #list do
		local loaded = list[index]
		local player = loaded.PlayerData and loaded.PlayerData.source
		if player ~= nil then
			local at = S.PointOf(player)
			for _, key in ipairs(built.order) do
				local corp = built.corps[key]
				for _, enclave in ipairs(corp.lists.enclaves) do
					local id = enclaveId(enclave)
					local seen = inside[id]
					if at ~= nil and Access.Inside(at, enclave) and not authorized(loaded, enclave) then
						local state = seen[player]
						if state == nil then
							state = { warnedAt = now }
							seen[player] = state
							S.Answer(player, false, 'trespass_warning', { corp = corp.label, label = enclave.label })
							OPX.Publish(M.Event.ON_TRESPASS, player, { corp = corp.key, enclave = enclave.key })
						end
						if state.alertedAt == nil or now - state.alertedAt >= built.security.alertCooldownMs then
							state.alertedAt = now
							alertSecurity(corp, enclave, at)
						end
					elseif seen[player] ~= nil then
						seen[player] = nil
					end
				end
			end
		end
	end
end

-- ── the detention ───────────────────────────────────────────────────────────

--- The enclave of a corp that a suspect is trespassing in and the detainer
--- stands in too, or nil.
local function sharedEnclave(corp, detainerAt, suspect, suspectAt)
	for _, enclave in ipairs(corp.lists.enclaves) do
		if Access.Inside(suspectAt, enclave) and S.Within(detainerAt, enclave)
			and not authorized(suspect, enclave) then
			return enclave
		end
	end
	return nil
end

local onDetained

--- Detains a trespasser: a bar, then the handoff. Answers the code.
-- @author dop42
-- @param player integer the guard
-- @param payload table { target }
-- @return boolean ok
-- @return string code
function Security.Detain(player, payload)
	if OPX.Cooling(player, 'corpo.request', built.requestMs) then return S.Answer(player, false, 'too_fast') end
	local suspect = type(payload) == 'table' and math.tointeger(payload.target) or nil
	if suspect == nil or suspect <= 0 or suspect == player then return S.Answer(player, false, 'invalid') end
	local guard = S.PlayerOf(player)
	if guard == nil then return S.Answer(player, false, 'no_character') end
	local corp = securityOf(guard)
	if corp == nil then return S.Answer(player, false, 'not_security') end
	if detentions[player] ~= nil then return S.Answer(player, false, 'busy') end
	if OPX.Life.Down(player) then return S.Answer(player, false, 'player_down') end
	local target = S.PlayerOf(suspect)
	if target == nil then return S.Answer(player, false, 'not_trespassing') end
	local a, b = S.PointOf(player), S.PointOf(suspect)
	if a == nil or b == nil then return S.Answer(player, false, 'no_position') end
	local enclave = sharedEnclave(corp, a, target, b)
	if enclave == nil then return S.Answer(player, false, 'not_trespassing') end
	if a.bucket ~= b.bucket or S.Distance(a, b) > OPX.Spots.ServerReach(built.security.reach) then
		return S.Answer(player, false, 'too_far')
	end
	local api = S.Progress()
	if api == nil then return S.Answer(player, false, 'no_bar') end
	local started = api.Start(player, OWNER, { label = locale('corpo.bar.detain'),
		durationMs = built.security.detainMs, cancelable = true },
		function(who, outcome) onDetained(who, outcome) end)
	if type(started) ~= 'table' or not started.ok then return S.Answer(player, false, 'busy') end
	detentions[player] = { suspect = suspect, corp = corp.key, enclave = enclave.key, barId = started.value.id }
	S.Answer(suspect, false, 'being_detained', { corp = corp.label })
	return true, 'detaining'
end

--- Hands a suspect to the police module, or to the officers on duty. Answers
--- whether a police module took them.
local function handoff(suspect, guard, corp, enclave, at)
	local police = OPX.Api.Get('police')
	local took = false
	if police ~= nil then
		if type(police.Handoff) == 'function' then
			local read, answer = pcall(police.Handoff, { suspect = suspect, by = guard, reason = 'trespass',
				corp = corp.key, enclave = enclave.label, position = { x = at.x, y = at.y, z = at.z } })
			took = read and answer ~= false and not (type(answer) == 'table' and answer.ok == false)
		end
		if type(police.Report) == 'function' then
			local read = pcall(police.Report, { crime = 'trespass', label = ('%s - %s'):format(corp.label, enclave.label),
				position = { x = at.x, y = at.y, z = at.z }, suspect = suspect, source = 'corpo' })
			took = took or read
		end
	end
	if took then return true end
	local api = S.Character()
	if api == nil or type(api.GetPlayersByJob) ~= 'function' then return false end
	local payload = { kind = 'detained', corp = corp.label, label = enclave.label, x = at.x, y = at.y, z = at.z }
	for _, job in ipairs(built.security.policeJobs) do
		local read, list = pcall(api.GetPlayersByJob, job, true)
		if read and type(list) == 'table' then
			for index = 1, #list do
				local officer = list[index].PlayerData and list[index].PlayerData.source
				if officer ~= nil and officer ~= suspect then TriggerClientEvent(M.Event.ALERT, officer, payload) end
			end
		end
	end
	return false
end

onDetained = function(player, outcome)
	local detention = detentions[player]
	if detention == nil or type(outcome) ~= 'table' or outcome.id ~= detention.barId then return end
	detentions[player] = nil
	if outcome.completed ~= true then
		if outcome.ending ~= 'left' then S.Answer(player, false, 'detain_cancelled') end
		return
	end
	local guard = S.PlayerOf(player)
	local corp = guard and securityOf(guard) or nil
	local target = S.PlayerOf(detention.suspect)
	local a, b = S.PointOf(player), S.PointOf(detention.suspect)
	if corp == nil or corp.key ~= detention.corp or target == nil or a == nil or b == nil then
		return S.Answer(player, false, 'not_trespassing')
	end
	local enclave = sharedEnclave(corp, a, target, b)
	if enclave == nil then return S.Answer(player, false, 'not_trespassing') end
	if a.bucket ~= b.bucket or S.Distance(a, b) > OPX.Spots.ServerReach(built.security.reach) then
		return S.Answer(player, false, 'too_far')
	end
	local took = handoff(detention.suspect, player, corp, enclave, b)
	local mode = built.security.eject
	local ejected = false
	if enclave.eject ~= nil and (mode == 'always' or (mode == 'no_police' and not took))
		and type(Open77.players.teleport) == 'function' then
		local read, pending = pcall(Open77.players.teleport, detention.suspect, enclave.eject, { dismount = true })
		ejected = read and pending ~= nil
	end
	local record = S.Record(player, corp.key)
	Access.Move(record, built.security.standing, built)
	S.SaveRecord(player, corp.key, record)
	if inside[enclaveId(enclave)] ~= nil then inside[enclaveId(enclave)][detention.suspect] = nil end
	OPX.Audit.Security('corpo.detained', ('player %d detained player %d in %s'):format(player, detention.suspect,
		enclaveId(enclave)), { corp = corp.key, enclave = enclave.key, police = took, ejected = ejected }, player)
	OPX.Publish(M.Event.ON_DETAINED, player, { corp = corp.key, enclave = enclave.key, suspect = detention.suspect,
		by = player, police = took })
	S.Answer(detention.suspect, false, took and 'detained_police' or 'detained', { corp = corp.label })
	S.Answer(player, true, took and 'detained_police' or 'detained', { label = enclave.label, standing = record.s })
end

-- ── reads for the contract ──────────────────────────────────────────────────

--- Whether a player may stand in a corp's enclave: `(bool, why)`.
function Security.CanEnter(player, corpKey, enclaveKey)
	local enclave = Access.Place(built, corpKey, 'enclaves', enclaveKey)
	if enclave == nil then return false, 'unknown_place' end
	local loaded = S.PlayerOf(player)
	if loaded == nil then return false, 'no_character' end
	local corp = built.corps[corpKey]
	return OPX.JobGate.Evaluate(Access.EnclaveRequirement(enclave, corp), S.SnapshotOf(loaded), OPX.Now(),
		{ maxAgeMs = 5000, membership = 'any' })
end

--- The enclave a player was last seen trespassing in, or nil.
function Security.Trespassing(player)
	for id, seen in pairs(inside) do
		if seen[player] ~= nil then
			local corp, enclave = id:match('^([^%.]+)%.(.+)$')
			return { corp = corp, enclave = enclave }
		end
	end
	return nil
end

--- A connection left.
function Security.Left(player)
	detentions[player], roles[player] = nil, nil
	for _, seen in pairs(inside) do seen[player] = nil end
end

-- ── the phases ──────────────────────────────────────────────────────────────

function Security.Init(value)
	built = value
	inside, detentions, roles = {}, {}, {}
	for _, key in ipairs(built.order) do
		for _, enclave in ipairs(built.corps[key].lists.enclaves) do inside[enclaveId(enclave)] = {} end
	end
end

function Security.Start()
	-- A job, a grade or a shift that changed changes what the eye may offer.
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'job'), function(player)
		player = math.tointeger(tonumber(player))
		if player ~= nil then Security.SendRole(player, false) end
	end)
	-- NO ENCLAVE, NO WATCH. The roster read below is not free -- the character
	-- module drops a stale session when it is asked for its players -- so a
	-- server with nothing surveyed does not ask it on a clock at all.
	local any = false
	for _, key in ipairs(built.order) do
		if #built.corps[key].lists.enclaves > 0 then any = true end
	end
	if not any then return end
	tickJob = OPX.Scheduler.Every('corpo:security', built.security.tickMs, function()
		local ran, failure = pcall(Security.Tick)
		if not ran then Open77.log.error('[corpo] the enclave watch raised: ' .. tostring(failure)) end
	end)
end

function Security.Stop()
	if tickJob ~= nil and OPX.Scheduler.Cancel ~= nil then pcall(OPX.Scheduler.Cancel, tickJob) end
	tickJob = nil
end
