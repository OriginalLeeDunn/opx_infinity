--- Server half of the Trauma Team: the page a distress signal sends, the body a
--- medic stands over, the treatment, and the pay.
-- @author XEROX710
--
-- WHY THIS EXISTS. The audit of 2026-09-30 found the Trauma Team job had no
-- gameplay: a paramedic could sign up and clock in, WAIT FOR HELP stored a flag
-- and told the downed player "Help has been called", nobody was called, and only
-- a staff command could stand a body up. This file is the other half of that
-- button (`TRAUMA` in `config/downed.lua`).
--
-- EVERY STEP IS THE SERVER'S. The page goes to the players whose PRIMARY job is
-- in `JOBS` and who are ON DUTY, read from the character module's own record --
-- never from a client. A treatment is asked for by a medic's client and judged
-- here: the job, the duty, that the medic is up and the patient is down, the
-- distance between the medic's body and the patient's (the patient's from the
-- life state or the record: a body dead for more than two seconds has no
-- position read of its own), the bucket and the cooldown. The bar on the
-- medic's screen is presentation; the clock is this file's, and a `DONE` that
-- arrives before the treatment could have finished is refused. Everything is
-- checked again at the end, because a medic who walked off or went down, or a
-- patient somebody else already stood up, is not a treatment.
--
-- THE PAY IS BOUNDED. One reward per revive, and at most one per
-- `REWARD.PER_PATIENT_MS` for the same patient's CHARACTER -- a patient who goes
-- straight back down is revived for free -- so two friends taking turns on the
-- floor are not a money machine.

local M = OPX.Modules.Get('downed')

M.Trauma = {}
local T = M.Trauma
local Event = M.TraumaEvent

-- The medics each patient's signal reached, by patient: `{ [medicId] = true }`.
local paged = {}

-- Treatments running, by patient: `{ medic, since, needMs, citizenId, name }`.
local treating = {}

-- The patient each medic is treating, by medic.
local busy = {}

-- When each medic's last treatment ended, by medic.
local lastTreat = {}

-- When a medic was last paid for each patient's character, by citizen id.
local rewarded = {}

-- The downed body each medic was last told is within reach, as text (`''` for
-- none), so the row is sent only when it changes.
local near = {}


-- Whether the events and the command are wired: a host handler cannot be taken
-- back, and a second registration after a restart would run every step twice.
local wired = false

local function internal() return M.Internal end

local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

--- A player id off the wire: a whole number from 1 up, or nil.
local function playerOf(value)
	local id = tonumber(value)
	if id == nil or id < 1 or id > 2147483647 or id % 1 ~= 0 then return nil end
	return math.floor(id)
end

--- The character a connection has loaded, or nil.
local function dataOf(playerId)
	local character = internal().Character()
	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	local read, player = pcall(character.GetPlayer, playerId)
	if not read or type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
	local data = player.PlayerData
	if type(data.citizenId) ~= 'string' or data.citizenId == '' then return nil end
	return data
end

--- Whether a character is an on-duty medic by the config's `JOBS`.
local function isMedicData(data, cfg)
	local job = type(data) == 'table' and data.job or nil
	return type(job) == 'table' and job.onDuty == true and type(job.name) == 'string'
		and cfg.jobs[job.name] == true
end

--- The name a medic or a patient is shown as: the character's, else the player's.
local function nameFor(playerId, data)
	data = data or dataOf(playerId)
	local name = type(data) == 'table' and tostring(data.name or '') or ''
	if name ~= '' then return (name:gsub('%c', ' ')):sub(1, 48) end
	return internal().Name(playerId) or ('#' .. tostring(playerId))
end

--- Where a patient's body lies, and its bucket. The life state is the platform's
--- canonical read of a dead body; the record is what it said when they fell.
-- @return table|nil `{ x, y, z }`
-- @return number|nil bucket
local function bodyOf(patientId, record)
	local life = internal().Life(patientId)
	local at = type(life) == 'table' and type(life.position) == 'table' and life.position or nil
	local x, y, z = at and finite(at.x), at and finite(at.y), at and finite(at.z)
	local bucket = type(life) == 'table' and tonumber(life.bucket) or nil
	if x == nil or y == nil or z == nil then
		at = type(record) == 'table' and record.position or nil
		x, y, z = at and finite(at.x), at and finite(at.y), at and finite(at.z)
	end
	if bucket == nil and type(record) == 'table' then bucket = tonumber(record.bucket) end
	if x == nil or y == nil or z == nil then return nil, bucket end
	return { x = x, y = y, z = z }, bucket
end

local function apart(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- A number rounded to `step` metres, and never `-0`.
local function rounded(value, step)
	if step > 0 then value = math.floor(value / step + 0.5) * step end
	value = math.floor(value + 0.5)
	if value == 0 then value = 0 end
	return value
end

--- One line on a downed player's screen.
local function notice(patientId, key, args)
	pcall(TriggerClientEvent, Event.NOTICE, patientId, { key = key, args = args })
end

--- Tells a medic what came of a treatment.
local function answer(medicId, ok, code, extra)
	local payload = { ok = ok == true, code = code }
	for field, value in pairs(extra or {}) do payload[field] = value end
	pcall(TriggerClientEvent, Event.ANSWER, medicId, payload)
end

--- Why nobody was paged, for the journal: an empty roster or medics clocked off.
local function nobodyNote(cfg)
	local clockedOff, connected = 0, 0
	for _, playerId in ipairs(internal().PlayerIds()) do
		connected = connected + 1
		local data = dataOf(playerId)
		local job = data and data.job or nil
		if type(job) == 'table' and job.onDuty ~= true and cfg.jobs[job.name] == true then
			clockedOff = clockedOff + 1
		end
	end
	if clockedOff > 0 then
		return (' (%d medic(s) connected but CLOCKED OFF: they hear nothing until /opx.duty)'):format(clockedOff)
	end
	return (' (%d connected, none of them an on-duty medic)'):format(connected)
end

--- Pages every on-duty medic not yet paged for this patient.
--
-- Called once when the distress signal goes out and again by every pass while
-- the patient waits, so a medic who clocks in after the signal is paged too.
-- The patient is never paged about themselves.
-- @param patientId number
-- @param record table the downed record
-- @return integer how many medics this signal has reached, in all
function T.Page(patientId, record)
	local cfg = M.TraumaSettings()
	if cfg.off or type(record) ~= 'table' then return 0 end
	local sent = paged[patientId]
	local first = sent == nil
	if sent == nil then
		sent = {}
		paged[patientId] = sent
	end
	local body = bodyOf(patientId, record)
	if body == nil then
		-- Said once, not once a pass: the pass calls this every second while the
		-- patient waits, and a body with no place stays one.
		if first then
			Open77.log.info(('[downed] trauma: the signal of %d went out with no place to give: nobody paged')
				:format(patientId))
		end
		local total = 0
		for _ in pairs(sent) do total = total + 1 end
		return total
	end
	local payload = {
		patient = patientId,
		name = nameFor(patientId),
		x = rounded(body.x, cfg.round),
		y = rounded(body.y, cfg.round),
		z = rounded(body.z, 0),
		seconds = cfg.pinSeconds,
		sprite = cfg.sprite,
	}
	local fresh = 0
	for _, playerId in ipairs(internal().PlayerIds()) do
		if playerId ~= patientId and sent[playerId] == nil and isMedicData(dataOf(playerId), cfg) then
			sent[playerId] = true
			fresh = fresh + 1
			pcall(TriggerClientEvent, Event.PAGE, playerId, payload)
		end
	end
	local total = 0
	for _ in pairs(sent) do total = total + 1 end
	if first or fresh > 0 then
		Open77.log.info(('[downed] trauma: %s (%d) sent a distress signal at %.0f, %.0f -- %d medic(s) paged%s%s')
			:format(payload.name, patientId, payload.x, payload.y, fresh,
				first and '' or (' (late, ' .. total .. ' in all)'),
				(first and total == 0) and nobodyNote(cfg) or ''))
	end
	return total
end

--- The medic's side of one treatment ending, whatever ended it.
local function endTreatment(patientId, job)
	treating[patientId] = nil
	if busy[job.medic] == patientId then busy[job.medic] = nil end
	lastTreat[job.medic] = OPX.Now()
end

--- Cancels a running treatment by name: the medic's bar comes down with the
--- reason, and a patient still down is told nobody is working on them.
local function cancel(patientId, why)
	local job = treating[patientId]
	if job == nil then return false end
	endTreatment(patientId, job)
	answer(job.medic, false, why, { name = job.name })
	if internal().Record(patientId) ~= nil then notice(patientId, 'medic.notice.stopped') end
	Open77.log.info(('[downed] trauma: %d stopped treating %d: %s'):format(job.medic, patientId, why))
	return true
end

--- Starts a medic treating a patient, after every check.
-- @param medicId number
-- @param patientRaw any the patient the medic's row named
-- @return boolean
-- @return string|nil the refusal code
function T.Treat(medicId, patientRaw)
	local cfg = M.TraumaSettings()
	if cfg.off then return false, 'off' end
	medicId = playerOf(medicId)
	local patientId = playerOf(patientRaw)
	if medicId == nil or patientId == nil then return false, 'no_patient' end
	if medicId == patientId then return false, 'self' end
	local data = dataOf(medicId)
	if not isMedicData(data, cfg) then return false, 'not_medic' end
	if internal().Record(medicId) ~= nil or internal().IsDead(medicId) then return false, 'down' end
	if busy[medicId] ~= nil then return false, 'busy' end
	local now = OPX.Now()
	if lastTreat[medicId] ~= nil and now - lastTreat[medicId] < cfg.cooldownMs then return false, 'cooldown' end

	local record = internal().Record(patientId)
	if record == nil or not internal().IsDead(patientId) then return false, 'not_down' end
	if treating[patientId] ~= nil then return false, 'taken' end

	local here = internal().Position(medicId)
	local body, bucket = bodyOf(patientId, record)
	if here == nil or body == nil then return false, 'no_position' end
	if bucket ~= nil and tonumber(here.bucket) ~= nil and tonumber(here.bucket) ~= bucket then
		return false, 'too_far'
	end
	if apart(here, body) > cfg.reach then return false, 'too_far' end

	local job = { medic = medicId, since = now, needMs = cfg.treatMs, citizenId = record.citizenId,
		name = nameFor(patientId) }
	treating[patientId] = job
	busy[medicId] = patientId
	pcall(TriggerClientEvent, Event.RUN, medicId, { patient = patientId, name = job.name, durationMs = cfg.treatMs })
	notice(patientId, 'medic.notice.treating', { name = nameFor(medicId, data) })
	Open77.log.info(('[downed] trauma: %s (%d) is treating %s (%d), %.1f m from the body, %d ms')
		:format(nameFor(medicId, data), medicId, job.name, patientId, apart(here, body), cfg.treatMs))
	return true
end

--- The medic's bar ran out: the treatment is judged again and the patient
--- revived where they lie.
-- @param medicId number
-- @return boolean
-- @return string|nil the refusal code
function T.Done(medicId)
	local cfg = M.TraumaSettings()
	medicId = playerOf(medicId)
	local patientId = medicId ~= nil and busy[medicId] or nil
	local job = patientId ~= nil and treating[patientId] or nil
	if job == nil or job.medic ~= medicId then
		if medicId ~= nil then busy[medicId] = nil end
		return false, 'nothing_running'
	end
	local now = OPX.Now()
	-- THE CLOCK IS THIS FILE'S. The bar is drawn on the medic's machine, so a
	-- report that the treatment is over is believed only once it could be; a
	-- quarter of a second of slack covers the network, not a shortened bar.
	if now - job.since < job.needMs - 250 then
		cancel(patientId, 'too_soon')
		return false, 'too_soon'
	end

	-- EVERYTHING AGAIN, at the end.
	local data = dataOf(medicId)
	local why = nil
	if cfg.off then
		why = 'off'
	elseif not isMedicData(data, cfg) then
		why = 'not_medic'
	elseif internal().Record(medicId) ~= nil or internal().IsDead(medicId) then
		why = 'down'
	else
		local record = internal().Record(patientId)
		if record == nil or not internal().IsDead(patientId) then
			why = 'not_down'
		else
			local here = internal().Position(medicId)
			local body, bucket = bodyOf(patientId, record)
			if here == nil or body == nil then
				why = 'no_position'
			elseif bucket ~= nil and tonumber(here.bucket) ~= nil and tonumber(here.bucket) ~= bucket then
				-- The same bucket check `Treat` makes: a medic who changed
				-- instance mid-bar is not standing over this body any more.
				why = 'too_far'
			elseif apart(here, body) > cfg.reach * 1.5 then
				why = 'too_far'
			end
		end
	end
	if why ~= nil then
		cancel(patientId, why)
		return false, why
	end

	-- Off the books BEFORE the revive: standing the patient up closes their
	-- record, and closing it asks this file to stop any treatment of them.
	endTreatment(patientId, job)
	local revived, reason = internal().Revive(patientId, 'trauma:' .. tostring(medicId))
	if not revived then
		answer(medicId, false, 'revive_refused', { name = job.name })
		notice(patientId, 'medic.notice.stopped')
		Open77.log.warn(('[downed] trauma: %d finished treating %d and the revive was refused: %s')
			:format(medicId, patientId, tostring(reason)))
		return false, 'revive_refused'
	end

	local reward = 0
	-- NO CHARACTER, NO PAY: the per-patient bound is keyed by the citizen id, so
	-- a record without one would have no bound at all and pay on every revive.
	if cfg.amount > 0 and type(job.citizenId) == 'string' and job.citizenId ~= '' then
		local last = rewarded[job.citizenId]
		if last == nil or now - last >= cfg.perPatientMs then
			local character = internal().Character()
			local paid, refusal = false, 'no_character_contract'
			if character ~= nil and type(character.AddMoney) == 'function' then
				local ran, ok, why2 = pcall(character.AddMoney, medicId, cfg.account, cfg.amount,
					'trauma:revive:' .. tostring(job.citizenId))
				paid, refusal = ran and ok == true, ran and why2 or ok
			end
			if paid then
				reward = cfg.amount
				if type(job.citizenId) == 'string' then rewarded[job.citizenId] = now end
			else
				Open77.log.warn(('[downed] trauma: %d revived %d and could not be paid: %s')
					:format(medicId, patientId, tostring(refusal)))
			end
		end
	end
	answer(medicId, true, nil, { name = job.name, reward = reward, account = cfg.account })
	Open77.log.info(('[downed] trauma: %s (%d) revived %s (%d)%s')
		:format(nameFor(medicId, data), medicId, job.name, patientId,
			reward > 0 and (', paid %d into %s'):format(reward, cfg.account) or ', unpaid (the same patient was paid for recently, or no reward is set)'))
	return true
end

--- The medic's bar was cut short.
-- @param medicId number
-- @param why any the bar's own ending
-- @return boolean
function T.Abort(medicId, why)
	medicId = playerOf(medicId)
	local patientId = medicId ~= nil and busy[medicId] or nil
	if patientId == nil then return false end
	local reason = type(why) == 'string' and why:match('^[%w_]+$') and why:sub(1, 24) or 'cancelled'
	return cancel(patientId, reason)
end

--- A patient is up (revived, gave up, left): every medic's pin comes down and
--- any treatment of them stops.
-- @param patientId number
-- @param why string
function T.Stood(patientId, why)
	local sent = paged[patientId]
	paged[patientId] = nil
	for medicId in pairs(sent or {}) do
		pcall(TriggerClientEvent, Event.UNPAGE, medicId, patientId)
	end
	if treating[patientId] ~= nil then cancel(patientId, 'patient_up') end
	-- The Trauma Team's own AV (`server/team.lua`) takes them off its list.
	if M.Team ~= nil and type(M.Team.Stood) == 'function' then pcall(M.Team.Stood, patientId) end
end

--- Whether a player medic is treating this patient right now: the team's AV
--- never takes a patient from a medic.
-- @param patientId number
-- @return boolean
function T.Treating(patientId)
	return treating[patientId] ~= nil
end

--- A connection left: whatever it was to this file.
-- @param playerId number
function T.Departed(playerId)
	playerId = tonumber(playerId)
	if playerId == nil then return end
	local patientId = busy[playerId]
	if patientId ~= nil then cancel(patientId, 'medic_gone') end
	T.Stood(playerId, 'left')
	for _, sent in pairs(paged) do sent[playerId] = nil end
	lastTreat[playerId], near[playerId] = nil, nil
end

--- The nearest downed body within a medic's reach, in their bucket, or nil.
local function nearestFor(medicId, cfg)
	local here = internal().Position(medicId)
	if here == nil then return nil end
	local best, bestMetres = nil, math.huge
	for patientId, record in pairs(internal().Records()) do
		if patientId ~= medicId then
			local body, bucket = bodyOf(patientId, record)
			if body ~= nil and (bucket == nil or tonumber(here.bucket) == nil or tonumber(here.bucket) == bucket) then
				local metres = apart(here, body)
				if metres <= cfg.reach and metres < bestMetres then best, bestMetres = patientId, metres end
			end
		end
	end
	return best
end

--- One pass, from the downed scan: late pages, the rows, and the treatments
--- whose medic walked off, went down or left.
function T.Tick()
	local cfg = M.TraumaSettings()
	if cfg.off then return end
	local records = internal().Records()

	for patientId, record in pairs(records) do
		if record.waiting then
			local total = T.Page(patientId, record)
			if total ~= record.paged then
				record.paged = total
				internal().Push(patientId)
			end
		end
	end

	local present = {}
	for _, playerId in ipairs(internal().PlayerIds()) do
		present[playerId] = true
		local wanted = ''
		if records[playerId] == nil and isMedicData(dataOf(playerId), cfg) and busy[playerId] == nil then
			local patientId = nearestFor(playerId, cfg)
			if patientId ~= nil then wanted = tostring(patientId) end
		end
		if (near[playerId] or '') ~= wanted then
			near[playerId] = wanted
			local patientId = tonumber(wanted)
			pcall(TriggerClientEvent, Event.NEAR, playerId, patientId ~= nil
				and { patient = patientId, name = nameFor(patientId) } or {})
		end
	end
	for playerId in pairs(near) do
		if not present[playerId] then near[playerId] = nil end
	end

	for patientId, job in pairs(treating) do
		local why = nil
		if records[patientId] == nil then
			why = 'patient_up'
		elseif not present[job.medic] or not isMedicData(dataOf(job.medic), cfg) then
			why = 'medic_gone'
		elseif records[job.medic] ~= nil then
			why = 'down'
		else
			local here = internal().Position(job.medic)
			local body = bodyOf(patientId, records[patientId])
			if here ~= nil and body ~= nil and apart(here, body) > cfg.reach * 1.5 then why = 'too_far' end
		end
		if why ~= nil then cancel(patientId, why) end
	end
end

--- Forgets everything. Shared by `Init`.
function T.Reset()
	paged, treating, busy, lastTreat, rewarded, near = {}, {}, {}, {}, {}, {}
end

--- What this half holds, for the suite and the console.
function T.Status()
	local running, pages = 0, 0
	for _ in pairs(treating) do running = running + 1 end
	for _ in pairs(paged) do pages = pages + 1 end
	return { treating = running, pages = pages }
end

--- Wires the medic's three doors and the command.
function T.Start()
	if wired then return end
	wired = true

	RegisterNetEvent(Event.TREAT, function(payload)
		local medicId = tonumber(source)
		if medicId == nil or medicId <= 0 then return end
		if OPX.Cooling(medicId, 'downed.treat', 750) then return end
		local ok, code = T.Treat(medicId, type(payload) == 'table' and payload.patient or nil)
		if not ok then answer(medicId, false, code) end
	end)

	RegisterNetEvent(Event.DONE, function()
		local medicId = tonumber(source)
		if medicId == nil or medicId <= 0 then return end
		if OPX.Cooling(medicId, 'downed.treatDone', 250) then return end
		T.Done(medicId)
	end)

	RegisterNetEvent(Event.ABORT, function(why)
		local medicId = tonumber(source)
		if medicId == nil or medicId <= 0 then return end
		T.Abort(medicId, why)
	end)

	-- THE CONSOLE DOOR, for a medic whose row did not come up: the nearest
	-- downed body within reach, judged exactly as the row's press is.
	if type(OPX.Command) == 'table' and type(OPX.Command.Register) == 'function' then
		local registered, failure = pcall(OPX.Command.Register, 'opx.treat', {
			restricted = false,
			help = 'medic.help.treat',
			cooldownMs = 1000,
		}, function(caller)
			local medicId = tonumber(caller)
			if medicId == nil or medicId <= 0 then return end
			local cfg = M.TraumaSettings()
			local patientId = nil
			if cfg.off then
				return OPX.NotifyLocale(medicId, M.TraumaRefusalKey('off'), nil, 'error')
			end
			patientId = nearestFor(medicId, cfg)
			if patientId == nil then
				return OPX.NotifyLocale(medicId, M.TraumaRefusalKey('no_patient'), nil, 'error')
			end
			local ok, code = T.Treat(medicId, patientId)
			if not ok then answer(medicId, false, code) end
		end)
		if not registered then
			Open77.log.warn('[downed] /opx.treat not registered: ' .. tostring(failure))
		end
	end

	local cfg = M.TraumaSettings()
	local jobs = {}
	for name in pairs(cfg.jobs) do jobs[#jobs + 1] = name end
	table.sort(jobs)
	Open77.log.info(cfg.off and '[downed] trauma: OFF -- a distress signal pages nobody'
		or ('[downed] trauma: a distress signal pages on-duty %s; treatment within %.1f m, %d ms, %d %s per revive')
			:format(table.concat(jobs, '/'), cfg.reach, cfg.treatMs, cfg.amount, cfg.account))
end
