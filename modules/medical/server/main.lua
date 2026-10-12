--- Server half: the calls, the treatments, the contracts and the bill.
-- @author dop42
--
-- EVERY DECISION IS HERE. The client sends four kinds of wish -- show me the
-- board, I take this call, treat this body with this, sign me up -- and each is
-- judged again from scratch: who the sender is (job, grade, duty, from the
-- character roster, never from the payload), where they stand (the host's
-- position, never theirs), what the patient is (the downed contract and the
-- host's health, never the client's), what is in their bag and what is in the
-- patient's account.
--
-- A TREATMENT IS THE WORLD-INTERACTION SHAPE on this resource's own economy:
-- check before the work (job, reach, patient state, items in the bag, money if
-- the service refuses the unpaid), let the server's clock run the work, check
-- AGAIN when it ends, then commit -- items out of the medic's bag first, the
-- revive or the heal second, the bill third. Anything that ends the work early
-- releases nothing, because nothing was taken yet.

local M = OPX.Modules.Get('medical')

local Model = M.Model
local Dispatch = M.Dispatch
local Event = M.Event
local Kind = M.Kind
local Reason = M.Reason
local Result = OPX.Result

local OWNER = 'medical'

-- Milliseconds a patient has to answer a consent invitation.
local CONSENT_MS = 20000

local settings
-- Treatments under way: by medic, by patient, and by interaction id.
local busy, treating, byInteraction = {}, {}, {}
-- Consent invitations waiting on a patient: inviteId -> job.
local invites, nextInvite = {}, 0
-- player:kind -> last request time.
local lastRequest = {}

local function config()
	if settings == nil then settings = Model.Settings(OPX.Config.MODULES.medical) end
	return settings
end

-- ── reading the world ────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end

local function wallSeconds()
	local time = Open77.time
	if type(time) ~= 'table' or type(time.unix) ~= 'function' then return nil end
	local read, now = pcall(time.unix)
	return read and OPX.Math.Finite(now) or nil
end

local function positionOf(player)
	local read, at = pcall(Open77.players.position, player)
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

-- Squared flat-and-height distance, or nil.
local function gapSq(a, b)
	if a == nil or b == nil then return nil end
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Whether two bodies are within the treatment reach, slack included.
local function within(a, b, reach)
	if a == nil or b == nil or a.bucket ~= b.bucket then return false end
	local slack = OPX.Math.Finite(OPX.Config.SHARED.REACH_SLACK) or 1.0
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

-- Whether one player may act for a service at a grade, by the shared gate.
local function member(player, svc, minGrade)
	local data = loaded(player)
	if data == nil then return false, 'no_character' end
	local now = OPX.Now()
	return OPX.JobGate.Evaluate({ jobs = Model.Jobs(svc, minGrade), onDuty = svc.onDuty },
		{ job = data.job, jobs = data.jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = config().membership })
end

-- The services one player works for, as a set, at their dispatch grade.
local function servicesOf(player)
	local set, any = {}, false
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		if member(player, svc, svc.dispatch.minGrade) then set[key], any = true, true end
	end
	return any and set or nil
end

-- The down state of a patient from the downed contract: down, waiting.
local function downState(player)
	local downed = OPX.Api.Get('downed')
	if downed == nil or type(downed.IsDown) ~= 'function' then return false end
	local read, answer = pcall(downed.IsDown, player)
	if not read or type(answer) ~= 'table' or not answer.ok or type(answer.value) ~= 'table' then
		return false
	end
	return answer.value.down == true, answer.value.waiting == true
end

-- A living body's health and maximum, or nil.
local function healthOf(player)
	local players = Open77.players
	if type(players.getHealth) ~= 'function' then return nil end
	local read, health = pcall(players.getHealth, player)
	if not read or type(health) ~= 'table' then return nil end
	local current, maximum = OPX.Math.Finite(health.health), OPX.Math.Finite(health.maxHealth)
	if current == nil or maximum == nil or maximum <= 0 then return nil end
	return current, maximum
end

-- ── the contract record ─────────────────────────────────────────────────────

-- The character's medical record: { subs = { [svc] = { tier, expiresAt } }, debt = { [svc] = n } }.
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

-- The active tier a player holds with a service, or nil.
local function tierOf(player, svc)
	if not svc.subscription.enabled then return nil end
	local record = recordOf(player)
	local subs = type(record.subs) == 'table' and record.subs or {}
	return Model.ActiveTier(svc, subs[svc.key], wallSeconds())
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

-- What a medic is shown of one call. No name: the server does not hand a
-- stranger's name to anybody (`modules/character/client/state.lua`).
local function viewOf(call, viewer)
	local svc = config().services[call.service]
	local here = positionOf(viewer)
	local gap = here and call.position and gapSq(here, call.position)
	return {
		id = call.id,
		service = call.service,
		short = svc and svc.short or call.service,
		tier = call.tier and svc and svc.subscription.tiers[call.tier]
			and svc.subscription.tiers[call.tier].label or nil,
		priority = call.priority,
		offContract = call.offContract,
		reason = call.reason,
		x = call.position and call.position.x, y = call.position and call.position.y,
		z = call.position and call.position.z,
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
		if player ~= call.patient and member(player, svc, svc.dispatch.minGrade) then
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
	OPX.Publish(Event.ON_CALL, call.patient, { state = 'closed', callId = call.id,
		service = call.service, why = why, citizenId = call.citizenId })
end

-- Opens the calls one patient earns for one reason, and tells everybody concerned.
local function openCalls(patient, citizenId, reason)
	local position = positionOf(patient)
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		local tier = tierOf(patient, svc)
		local opens, offContract = Model.Answers(svc, tier, reason)
		if opens then
			local call, fresh = Dispatch.Open({
				service = key, patient = patient, citizenId = citizenId, reason = reason,
				tier = tier and tier.key or nil, priority = tier and tier.priority or 0,
				offContract = offContract, position = position,
				ttlMs = svc.dispatch.ttlMs, nowMs = OPX.Now(),
			})
			if fresh then
				local told = alert(call)
				OPX.Publish(Event.ON_CALL, patient, { state = 'opened', callId = call.id, service = key,
					reason = reason, tier = call.tier, offContract = offContract, citizenId = citizenId })
				OPX.NotifyLocale(patient, told > 0 and 'medical.patient.called' or 'medical.patient.nobody',
					{ service = svc.label }, told > 0 and 'info' or 'warning')
			end
		end
	end
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
	if call.patient == player then return answer(player, false, 'no_such_call') end
	local taken, why = Dispatch.Take(call.id, player, svc.dispatch.responders, OPX.Now())
	if taken == nil then return answer(player, false, why) end
	local at = positionOf(call.patient) or call.position
	if at ~= nil then TriggerClientEvent(Event.WAYPOINT, player, { x = at.x, y = at.y, z = at.z }) end
	OPX.NotifyLocale(call.patient, 'medical.patient.enRoute', { service = svc.label }, 'success')
	OPX.Publish(Event.ON_CALL, call.patient, { state = 'taken', callId = call.id, service = call.service,
		responder = citizenOf(player), citizenId = call.citizenId })
	audit('medical.take', player, true, ('%s call %d'):format(call.service, call.id))
	answer(player, true, 'taken', { service = svc.short })
end

local function onDrop(player, payload)
	local id = type(payload) == 'table' and payload.callId
	if not Dispatch.Drop(id, player) then return answer(player, false, 'no_such_call') end
	answer(player, true, 'dropped')
end

-- ── treatments ───────────────────────────────────────────────────────────────

-- The nearest other player within reach who is down or hurt, or nil.
local function nearestPatient(medic)
	local here = positionOf(medic)
	if here == nil then return nil end
	local best, bestGap
	for _, player in ipairs(playerIds()) do
		if player ~= medic then
			local there = positionOf(player)
			if within(here, there, config().reach) then
				local down = downState(player)
				local current, maximum = healthOf(player)
				if down or (current ~= nil and current < maximum) then
					local gap = gapSq(here, there)
					if best == nil or gap < bestGap then best, bestGap = player, gap end
				end
			end
		end
	end
	return best
end

-- How many of an item a player carries.
local function carried(player, name)
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return 0 end
	local read, counted = pcall(inventory.GetItemCount, player, name)
	if not read or type(counted) ~= 'table' or not counted.ok then return 0 end
	return math.tointeger(counted.value) or 0
end

local function hasItems(player, treat)
	for _, item in ipairs(treat.items) do
		if carried(player, item.name) < item.count then return false, item.name end
	end
	return true
end

local function takeItems(player, treat)
	local inventory = OPX.Api.Get('inventory')
	if #treat.items == 0 then return true end
	if inventory == nil or type(inventory.RemoveItem) ~= 'function' then return false end
	for _, item in ipairs(treat.items) do
		local read, removed = pcall(inventory.RemoveItem, player, item.name, item.count)
		if not read or type(removed) ~= 'table' or not removed.ok then
			Open77.log.warn(('[medical] %s x%d could not be taken from player %d'):format(item.name,
				item.count, player))
			return false
		end
	end
	return true
end

-- What state the patient is in for one kind of treatment: nil when it applies,
-- else the refusal code.
local function unfit(patient, kind)
	local down = downState(patient)
	if kind == Kind.REVIVE then
		return (not down) and 'not_down' or nil
	end
	-- The engine carries a living body only: a patient who is down is revived first.
	if kind == Kind.CARRY then return down and 'is_down' or nil end
	if down then return 'is_down' end
	local current, maximum = healthOf(patient)
	if current == nil then return 'no_health' end
	if current >= maximum then return 'full_health' end
	return nil
end

-- The footing a service treats a patient on: its tier, and whether the service
-- came outside a contract (a subscribers-only service treating a stranger).
local function footing(patient, svc)
	local tier = tierOf(patient, svc)
	local offContract = tier == nil and svc.dispatch.answers == 'subscribers'
	return tier, offContract
end

local function balanceOf(player, moneyType)
	local api = character()
	if api == nil or type(api.GetMoney) ~= 'function' then return 0 end
	local read, value = pcall(api.GetMoney, player, moneyType)
	return read and (math.tointeger(OPX.Math.Finite(value) or 0) or 0) or 0
end

-- The CARRY block of a service, shaped as a treatment so it rides the same
-- consent, busy and release paths. Nothing is consumed, billed or paid.
local function carryOf(svc)
	if not svc.carry.enabled then return nil end
	return { key = M.CARRY, kind = Kind.CARRY, label = 'medical.treat.carry', minGrade = svc.carry.minGrade,
		durationMs = svc.carry.durationMs, consent = svc.carry.consent, items = {}, fee = 0, pay = 0 }
end

-- Every treatment a medic may give a patient now, as rows for the client.
local function optionsFor(medic, patient)
	local rows = {}
	-- Carrying somebody: the only thing to do with them is put them down.
	local holding = busy[medic]
	if holding ~= nil and holding.treat.kind == Kind.CARRY and holding.interactionId ~= nil then
		rows[1] = { service = holding.svc.key, short = holding.svc.short, treatment = M.PUT_DOWN,
			label = 'medical.treat.putdown', kind = Kind.CARRY, fee = 0, stocked = true }
		return rows
	end
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		for _, name in ipairs(svc.treatmentOrder) do
			local treat = svc.treatments[name]
			if member(medic, svc, treat.minGrade) and unfit(patient, treat.kind) == nil then
				local tier, offContract = footing(patient, svc)
				local stocked = hasItems(medic, treat)
				rows[#rows + 1] = {
					service = key, short = svc.short, treatment = name, label = treat.label,
					kind = treat.kind, fee = Model.Fee(svc, treat, tier, offContract),
					moneyType = svc.billing.moneyType, stocked = stocked,
				}
			end
		end
		local carry = carryOf(svc)
		if carry ~= nil and member(medic, svc, carry.minGrade) and not downState(patient) then
			rows[#rows + 1] = { service = key, short = svc.short, treatment = M.CARRY, label = carry.label,
				kind = Kind.CARRY, fee = 0, stocked = true }
		end
	end
	return rows
end

local function onOptions(player, payload)
	local target = math.tointeger(tonumber(type(payload) == 'table' and payload.target or nil))
	if target == nil or target == player then target = nearestPatient(player) end
	if target == nil then return answer(player, false, 'no_patient') end
	if not within(positionOf(player), positionOf(target), config().reach) then
		return answer(player, false, 'too_far')
	end
	local rows = optionsFor(player, target)
	if #rows == 0 then return answer(player, false, 'no_treatment') end
	TriggerClientEvent(Event.OPTIONS_VIEW, player, { target = target, rows = rows })
end

-- Debts are per service, in the character's medical record.
local function addDebt(patient, svc, amount)
	local record = recordOf(patient)
	record.debt = type(record.debt) == 'table' and record.debt or {}
	record.debt[svc.key] = (math.tointeger(record.debt[svc.key]) or 0) + amount
	return writeRecord(patient, record)
end

-- Bills the patient. Answers what was paid and what was written as debt.
local function bill(job)
	local svc, fee = job.svc, job.fee
	if fee <= 0 then return 0, 0 end
	local api = character()
	local reason = ('medical:%s:%s'):format(svc.key, job.treat.key)
	if api ~= nil and type(api.RemoveMoney) == 'function' then
		local read, ok = pcall(api.RemoveMoney, job.patient, svc.billing.moneyType, fee, reason)
		if read and ok == true then return fee, 0 end
	end
	if svc.billing.onUnpaid == 'free' then return 0, 0 end
	addDebt(job.patient, svc, fee)
	return 0, fee
end

local function payMedic(job)
	local pay = job.treat.pay
	if pay <= 0 then return 0 end
	local api = character()
	if api == nil or type(api.AddMoney) ~= 'function' then return 0 end
	local read, ok = pcall(api.AddMoney, job.medic, job.svc.billing.payMoneyType, pay,
		('medical:%s:%s:pay'):format(job.svc.key, job.treat.key))
	return (read and ok == true) and pay or 0
end

local function release(job)
	if busy[job.medic] == job then busy[job.medic] = nil end
	if treating[job.patient] == job then treating[job.patient] = nil end
	if job.interactionId ~= nil then byInteraction[job.interactionId] = nil end
	-- The bed and the prop are this treatment's, and end with it whatever ended it.
	if job.bedPlayback ~= nil then
		local animations = Open77.animations
		if type(animations) == 'table' and type(animations.stopAt) == 'function' then
			pcall(animations.stopAt, job.bedPlayback)
		end
		job.bedPlayback = nil
	end
	if job.holding then
		local held = Open77.heldItems
		if type(held) == 'table' and type(held.release) == 'function' then pcall(held.release, job.medic) end
		job.holding = nil
	end
end

-- The act itself: a revive through the downed contract, a heal through the host.
local function apply(job)
	if job.treat.kind == Kind.REVIVE then
		local downed = OPX.Api.Get('downed')
		if downed == nil or type(downed.Revive) ~= 'function' then return false, 'revive_failed' end
		local read, revived = pcall(downed.Revive, job.patient, OWNER,
			job.svc.key .. ':' .. job.treat.key, { health = job.treat.health, graceMs = job.treat.graceMs })
		if not read or type(revived) ~= 'table' or not revived.ok then return false, 'revive_failed' end
		return true
	end
	local current, maximum = healthOf(job.patient)
	if current == nil then return false, 'no_health' end
	local wanted = math.min(maximum, current + maximum * job.treat.heal)
	local read, ok = pcall(Open77.players.setHealth, job.patient, wanted)
	if not read or ok ~= true then return false, 'heal_failed' end
	return true
end

-- Ends one treatment. Every way it can end comes through here exactly once.
local function finish(job, completed, ending)
	if job.done then return end
	job.done = true
	release(job)
	-- A carry is not a treatment: however it ended, the patient is on their feet.
	if job.treat.kind == Kind.CARRY then
		return answer(job.medic, true, 'put_down')
	end
	if not completed then
		answer(job.medic, false, 'interrupted')
		return
	end
	-- AGAIN, NOW: the work took seconds, and in those seconds the patient may
	-- have got up, died, been revived by somebody else or walked off, and the
	-- medic may have clocked off or emptied their bag.
	if not member(job.medic, job.svc, job.treat.minGrade) then return answer(job.medic, false, 'not_member') end
	if not within(positionOf(job.medic), positionOf(job.patient), config().reach) then
		return answer(job.medic, false, 'too_far')
	end
	local why = unfit(job.patient, job.treat.kind)
	if why ~= nil then return answer(job.medic, false, why) end
	if not hasItems(job.medic, job.treat) or not takeItems(job.medic, job.treat) then
		return answer(job.medic, false, 'no_items')
	end
	local ok, failure = apply(job)
	if not ok then
		audit('medical.treat', job.medic, false, ('%s/%s: %s'):format(job.svc.key, job.treat.key, failure))
		return answer(job.medic, false, failure)
	end
	local paid, owed = bill(job)
	local earned = payMedic(job)
	if job.treat.kind == Kind.REVIVE then
		for _, call in ipairs(Dispatch.CloseFor(job.patient)) do announceClosed(call, 'treated') end
	end
	audit('medical.treat', job.medic, true, ('%s/%s on %d: paid %d owed %d'):format(job.svc.key,
		job.treat.key, job.patient, paid, owed))
	OPX.Publish(Event.ON_TREATED, job.patient, {
		service = job.svc.key, treatment = job.treat.key, kind = job.treat.kind,
		citizenId = citizenOf(job.patient), medic = citizenOf(job.medic),
		fee = job.fee, paid = paid, owed = owed, earned = earned, offContract = job.offContract,
	})
	answer(job.medic, true, 'treated', { earned = earned, moneyType = job.svc.billing.payMoneyType })
	local money = OPX.Locale.Money(paid > 0 and paid or owed, job.svc.billing.moneyType)
	if owed > 0 then
		OPX.NotifyLocale(job.patient, 'medical.patient.owed', { service = job.svc.label, amount = money }, 'warning')
	elseif paid > 0 then
		OPX.NotifyLocale(job.patient, 'medical.patient.billed', { service = job.svc.label, amount = money }, 'info')
	end
end

-- A progress bar on the medic's screen, judged by the server's clock.
local function startBar(job)
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return false, 'no_bar' end
	local started = progress.Start(job.medic, OWNER, {
		label = locale(job.treat.kind == Kind.REVIVE and 'medical.bar.revive' or 'medical.bar.heal'),
		durationMs = job.treat.durationMs,
		cancelable = true,
		animation = job.treat.animation and { name = job.treat.animation } or nil,
	}, function(_, outcome)
		finish(job, type(outcome) == 'table' and outcome.completed == true,
			type(outcome) == 'table' and outcome.ending or nil)
	end)
	if type(started) ~= 'table' or not started.ok then
		return false, type(started) == 'table' and started.error == 'progress_busy' and 'busy' or 'no_bar'
	end
	job.barId = type(started.value) == 'table' and started.value.id or nil
	return true
end

-- A heal through the platform's two-player coordinator: the medic kneels and
-- examines, the patient sits wounded, both screens see it.
local function startPair(job)
	local native = Open77.playerInteractions
	if type(native) ~= 'table' or type(native.request) ~= 'function' then return nil end
	local read, state, reason = pcall(native.request, job.medic, job.patient, 'heal', {
		durationMs = job.treat.durationMs,
		startDistance = math.min(10, config().reach),
		breakDistance = math.min(20, config().reach + 2),
		-- The consent was taken by this module's own invitation, before this.
		consent = false,
	})
	if not read or type(state) ~= 'table' or type(state.id) ~= 'string' then
		Open77.log.debug('[medical] heal pair refused: ' .. tostring(read and reason or state))
		return false
	end
	job.interactionId = state.id
	byInteraction[state.id] = job
	return true
end

-- The platform's two-player carry: the medic walks, the patient is in their arms.
local function startCarry(job)
	local native = Open77.playerInteractions
	if type(native) ~= 'table' or type(native.request) ~= 'function' then return false, 'carry_refused' end
	local read, state, reason = pcall(native.request, job.medic, job.patient, 'carry', {
		durationMs = job.treat.durationMs,
		startDistance = math.min(10, config().reach),
		breakDistance = math.min(20, config().reach + 4),
		consent = false,
	})
	if not read or type(state) ~= 'table' or type(state.id) ~= 'string' then
		Open77.log.debug('[medical] carry refused: ' .. tostring(read and reason or state))
		return false, 'carry_refused'
	end
	job.interactionId = state.id
	byInteraction[state.id] = job
	return true
end

-- The usable bed of a service the patient stands at, or nil.
local function bedFor(svc, patient)
	local there = positionOf(patient)
	if there == nil then return nil end
	for _, bed in ipairs(svc.beds) do
		if within(there, { x = bed.x, y = bed.y, z = bed.z, bucket = there.bucket }, bed.radius) then
			return bed
		end
	end
	return nil
end

-- Lays the patient on a bed for the length of a heal. Answers whether they lie.
local function layDown(job, bed)
	local animations = Open77.animations
	if type(animations) ~= 'table' or type(animations.playAt) ~= 'function' then return false end
	local read, placed, reason = pcall(animations.playAt, job.patient, bed.pose,
		{ x = bed.x, y = bed.y, z = bed.z }, bed.yaw, { loop = true })
	if not read or type(placed) ~= 'table' or type(placed.playbackId) ~= 'string' then
		Open77.log.debug('[medical] bed refused: ' .. tostring(read and reason or placed))
		return false
	end
	job.bedPlayback = placed.playbackId
	return true
end

-- Puts the treatment's prop in the medic's right hand. A refusal costs the prop.
local function holdProp(job)
	if job.treat.prop == nil then return end
	local held = Open77.heldItems
	if type(held) ~= 'table' or type(held.hold) ~= 'function' then return end
	local read, request, reason = pcall(held.hold, job.medic, job.treat.prop)
	if read and request ~= nil then
		job.holding = true
	else
		Open77.log.debug(('[medical] %s could not be held: %s'):format(job.treat.prop,
			tostring(read and reason or request)))
	end
end

local function begin(job)
	busy[job.medic], treating[job.patient] = job, job
	if job.treat.kind == Kind.CARRY then
		local carrying, why = startCarry(job)
		if not carrying then release(job) end
		return carrying, why
	end
	local ok, why
	if job.treat.kind == Kind.HEAL then
		-- At a bed, the patient lies on it under the bar; anywhere else they sit
		-- wounded through the two-player heal.
		local bed = bedFor(job.svc, job.patient)
		if not (bed ~= nil and layDown(job, bed)) then
			local paired = startPair(job)
			if paired == true then
				holdProp(job)
				return true
			end
			-- No coordinator, or it refused (a vehicle, a reservation): the bar.
		end
	end
	ok, why = startBar(job)
	if not ok then
		release(job)
		return false, why
	end
	holdProp(job)
	return true
end

local function onTreat(player, payload)
	if type(payload) ~= 'table' then return answer(player, false, 'invalid') end
	-- Putting a carried patient down needs no service, no target and no check:
	-- it only ever releases what this medic holds.
	if payload.treatment == M.PUT_DOWN then
		local holding = busy[player]
		if holding == nil or holding.treat.kind ~= Kind.CARRY or holding.interactionId == nil then
			return answer(player, false, 'not_carrying')
		end
		local native = Open77.playerInteractions
		if type(native) == 'table' and type(native.cancel) == 'function' then
			pcall(native.cancel, holding.interactionId, 'put_down')
		end
		return finish(holding, false, 'put_down')
	end
	local svc = config().services[payload.service]
	local treat = svc and (payload.treatment == M.CARRY and carryOf(svc) or svc.treatments[payload.treatment])
	local patient = math.tointeger(tonumber(payload.target))
	if treat == nil or patient == nil or patient == player then return answer(player, false, 'no_treatment') end
	if busy[player] ~= nil then return answer(player, false, 'busy') end
	if treating[patient] ~= nil then return answer(player, false, 'patient_busy') end
	if not member(player, svc, treat.minGrade) then return answer(player, false, 'not_member') end
	if not within(positionOf(player), positionOf(patient), config().reach) then
		return answer(player, false, 'too_far')
	end
	local why = unfit(patient, treat.kind)
	if why ~= nil then return answer(player, false, why) end
	local stocked, missing = hasItems(player, treat)
	if not stocked then return answer(player, false, 'no_items', { item = missing }) end
	local tier, offContract = footing(patient, svc)
	local fee = Model.Fee(svc, treat, tier, offContract)
	if fee > 0 and svc.billing.onUnpaid == 'refuse' and balanceOf(patient, svc.billing.moneyType) < fee then
		return answer(player, false, 'unpaid')
	end
	local job = { medic = player, patient = patient, svc = svc, treat = treat, tier = tier,
		offContract = offContract, fee = fee }

	-- CONSENT: a heal or a carry on a body that can still say no asks first. A
	-- revive never does -- the body cannot answer, and a contract is the consent.
	if (treat.kind == Kind.HEAL or treat.kind == Kind.CARRY) and treat.consent then
		nextInvite = nextInvite % 2147483646 + 1
		job.inviteId, job.expiresMs = nextInvite, OPX.Now() + CONSENT_MS
		invites[nextInvite] = job
		busy[player], treating[patient] = job, job
		TriggerClientEvent(Event.ASK, patient, {
			inviteId = nextInvite, service = svc.label, treatment = treat.label,
			fee = fee, moneyType = svc.billing.moneyType, ttlMs = CONSENT_MS,
		})
		return answer(player, true, 'asked')
	end
	local started, failure = begin(job)
	if not started then return answer(player, false, failure) end
	answer(player, true, treat.kind == Kind.CARRY and 'carrying' or 'started')
end

local function onConsent(player, payload)
	local id = math.tointeger(tonumber(type(payload) == 'table' and payload.inviteId or nil))
	local job = id and invites[id] or nil
	if job == nil or job.patient ~= player then return end
	invites[id] = nil
	release(job)
	if type(payload) ~= 'table' or payload.accepted ~= true then
		return answer(job.medic, false, 'consent_declined')
	end
	local started, failure = begin(job)
	if not started then return answer(job.medic, false, failure) end
	answer(job.medic, true, job.treat.kind == Kind.CARRY and 'carrying' or 'started')
end

-- Reads a coordinator state, a table or the JSON the server events may carry.
local function stateOf(value)
	if type(value) == 'string' and type(json) == 'table' then
		local read, decoded = pcall(json.decode, value)
		value = read and decoded or nil
	end
	return type(value) == 'table' and type(value.id) == 'string' and value or nil
end

local function interactionEnded(value)
	local state = stateOf(value)
	local job = state and byInteraction[state.id] or nil
	if job == nil then return end
	finish(job, state.phase == 'completed' or state.reason == 'completed', state.reason)
end

-- ── subscriptions ────────────────────────────────────────────────────────────

local function deskOf(svc, index)
	index = math.tointeger(tonumber(index))
	for _, desk in ipairs(svc.subscription.desks) do
		if desk.index == index then return desk end
	end
	return nil
end

local function atDesk(player, svc, index)
	local desk = deskOf(svc, index)
	if desk == nil then return nil, 'no_desk' end
	local here = positionOf(player)
	if here == nil then return nil, 'too_far' end
	if not within(here, { x = desk.x, y = desk.y, z = desk.z, bucket = here.bucket }, desk.radius) then
		return nil, 'too_far'
	end
	return desk
end

local function onDesk(player, payload)
	local svc = type(payload) == 'table' and config().services[payload.service] or nil
	if svc == nil or not svc.subscription.enabled then return answer(player, false, 'no_desk') end
	local desk, why = atDesk(player, svc, payload.desk)
	if desk == nil then return answer(player, false, why) end
	local record = recordOf(player)
	local subs = type(record.subs) == 'table' and record.subs or {}
	local now = wallSeconds()
	local active = now and Model.ActiveTier(svc, subs[svc.key], now) or nil
	local tiers = {}
	for _, tier in pairs(svc.subscription.tiers) do
		tiers[#tiers + 1] = { key = tier.key, label = tier.label, price = tier.price,
			days = math.floor(tier.seconds / 86400 * 10 + 0.5) / 10, autoAlert = tier.autoAlert,
			discount = math.floor(tier.discount * 100 + 0.5), priority = tier.priority }
	end
	table.sort(tiers, function(a, b) return a.priority < b.priority end)
	local debt = type(record.debt) == 'table' and math.tointeger(record.debt[svc.key]) or 0
	TriggerClientEvent(Event.DESK_VIEW, player, {
		service = svc.key, label = svc.label, desk = desk.index, moneyType = svc.subscription.moneyType,
		tiers = tiers, debt = debt or 0, debtMoneyType = svc.billing.moneyType,
		current = active and { label = active.label,
			remainingS = math.max(0, math.floor(subs[svc.key].expiresAt - now)) } or nil,
	})
end

local function onSubscribe(player, payload)
	local svc = type(payload) == 'table' and config().services[payload.service] or nil
	if svc == nil or not svc.subscription.enabled then return answer(player, false, 'no_desk') end
	local desk, why = atDesk(player, svc, payload.desk)
	if desk == nil then return answer(player, false, why) end
	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return answer(player, false, 'unavailable') end
	local record = recordOf(player)
	record.subs = type(record.subs) == 'table' and record.subs or {}
	record.debt = type(record.debt) == 'table' and record.debt or {}

	-- The debt first: the desk settles what is owed before it sells anything.
	if payload.payDebt == true then
		local owed = math.tointeger(record.debt[svc.key]) or 0
		if owed <= 0 then return answer(player, false, 'no_debt') end
		local read, ok = pcall(api.RemoveMoney, player, svc.billing.moneyType, owed, 'medical:' .. svc.key .. ':debt')
		if not read or ok ~= true then return answer(player, false, 'cannot_afford') end
		record.debt[svc.key] = nil
		writeRecord(player, record)
		audit('medical.debt', player, true, ('%s settled %d'):format(svc.key, owed))
		return answer(player, true, 'debt_paid', { amount = owed, moneyType = svc.billing.moneyType })
	end

	local tier = svc.subscription.tiers[payload.tier]
	if tier == nil then return answer(player, false, 'no_tier') end
	if (math.tointeger(record.debt[svc.key]) or 0) > 0 then return answer(player, false, 'debt_outstanding') end
	local now = wallSeconds()
	if now == nil then return answer(player, false, 'unavailable') end
	local read, ok = pcall(api.RemoveMoney, player, svc.subscription.moneyType, tier.price,
		('medical:%s:subscribe:%s'):format(svc.key, tier.key))
	if not read or ok ~= true then return answer(player, false, 'cannot_afford') end
	-- The same tier renewed stacks on what is left; another tier starts now.
	local held = record.subs[svc.key]
	local from = now
	if type(held) == 'table' and held.tier == tier.key and (OPX.Math.Finite(held.expiresAt) or 0) > now then
		from = held.expiresAt
	end
	record.subs[svc.key] = { tier = tier.key, expiresAt = math.floor(from + tier.seconds) }
	if not writeRecord(player, record) then
		pcall(api.AddMoney, player, svc.subscription.moneyType, tier.price, 'medical:' .. svc.key .. ':refund')
		return answer(player, false, 'unavailable')
	end
	audit('medical.subscribe', player, true, ('%s %s'):format(svc.key, tier.key))
	OPX.Publish(Event.ON_SUBSCRIBED, player, { service = svc.key, tier = tier.key,
		citizenId = citizenOf(player), expiresAt = record.subs[svc.key].expiresAt, price = tier.price })
	answer(player, true, 'subscribed', { tier = tier.label, service = svc.label })
end

-- ── the downed bus ───────────────────────────────────────────────────────────

local function onDownedChanged(player, payload)
	local id = math.tointeger(tonumber(player))
	if id == nil or type(payload) ~= 'table' then return end
	if payload.down ~= true then
		-- Up, by whatever means, or gone with the state kept: every call on them closes.
		for _, call in ipairs(Dispatch.CloseFor(id)) do announceClosed(call, 'patient_up') end
		return
	end
	CreateThread(function()
		local citizenId = type(payload.citizenId) == 'string' and payload.citizenId or citizenOf(id)
		openCalls(id, citizenId, Reason.BIOMONITOR)
		if payload.waiting == true then openCalls(id, citizenId, Reason.DISTRESS) end
	end)
end

-- ── the sweep ────────────────────────────────────────────────────────────────

local function sweep()
	local now = OPX.Now()
	for _, call in ipairs(Dispatch.Expire(now)) do
		announceClosed(call, 'expired')
		OPX.NotifyLocale(call.patient, 'medical.patient.expired',
			{ service = config().services[call.service] and config().services[call.service].label or '' },
			'warning')
	end
	for _, call in ipairs(Dispatch.List(nil)) do
		if not downState(call.patient) then
			Dispatch.Close(call.id)
			announceClosed(call, 'patient_up')
		end
	end
	for id, job in pairs(invites) do
		if now >= job.expiresMs then
			invites[id] = nil
			release(job)
			answer(job.medic, false, 'consent_expired')
		end
	end
end

local function departed(rawPlayer)
	local player = math.tointeger(tonumber(rawPlayer))
	if player == nil then return end
	Dispatch.Forget(player)
	for _, call in ipairs(Dispatch.CloseFor(player)) do announceClosed(call, 'patient_left') end
	local job = busy[player] or treating[player]
	if job ~= nil then
		local progress = OPX.Api.Get('progress')
		if job.barId ~= nil and progress ~= nil and type(progress.Stop) == 'function' then
			pcall(progress.Stop, job.medic, OWNER, job.barId)
		end
		finish(job, false, 'left')
	end
	local prefix = tostring(player) .. ':'
	for slot in pairs(lastRequest) do
		if slot:sub(1, #prefix) == prefix then lastRequest[slot] = nil end
	end
end

-- ── the contract ─────────────────────────────────────────────────────────────

--- A player's subscription to one service, or nil.
-- @author dop42
-- @param player integer
-- @param service string
-- @return Result { tier, label, expiresAt }|nil
local function subscription(player, service)
	local svc = config().services[service]
	if svc == nil then return Result.Err('no_such_service') end
	local id = math.tointeger(tonumber(player))
	if id == nil then return Result.Err('bad_player') end
	local tier = tierOf(id, svc)
	if tier == nil then return Result.Ok(nil) end
	local record = recordOf(id)
	return Result.Ok({ tier = tier.key, label = tier.label, expiresAt = record.subs[service].expiresAt })
end

--- The open calls, optionally of one service.
-- @author dop42
local function calls(service)
	local rows = {}
	for _, call in ipairs(Dispatch.List(service and { [service] = true } or nil)) do
		rows[#rows + 1] = { id = call.id, service = call.service, patient = call.patient,
			reason = call.reason, tier = call.tier, offContract = call.offContract,
			responders = Dispatch.Count(call) }
	end
	return Result.Ok(rows)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state.
-- @author dop42
function M.Init()
	settings = nil
	busy, treating, byInteraction, invites, nextInvite, lastRequest = {}, {}, {}, {}, 0, {}
	Dispatch.Reset()
end

--- Publishes the server contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('medical', 1, {
		Subscription = subscription,
		Calls = calls,
		Services = function() return Result.Ok(OPX.Table.DeepCopy(config().serviceOrder)) end,
	})
end

--- Wires the requests, the downed bus and the sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Model.Problems(OPX.Config.MODULES.medical)) do
		Open77.log.warn('[medical] config: ' .. line)
	end

	local function wire(name, kind, handler)
		RegisterNetEvent(name, function(payload)
			local player = math.tointeger(tonumber(source))
			if player == nil or player <= 0 then return end
			if cooled(player, kind) then return answer(player, false, 'rate_limited') end
			-- On a thread: the bag and the account are read, and both may yield.
			CreateThread(function() handler(player, payload) end)
		end)
	end
	wire(Event.BOARD, 'board', onBoard)
	wire(Event.TAKE, 'take', onTake)
	wire(Event.DROP, 'drop', onDrop)
	wire(Event.OPTIONS, 'options', onOptions)
	wire(Event.TREAT, 'treat', onTreat)
	wire(Event.CONSENT, 'consent', onConsent)
	wire(Event.DESK, 'desk', onDesk)
	wire(Event.SUBSCRIBE, 'subscribe', onSubscribe)

	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed'), onDownedChanged)
	AddEventHandler('onPlayerInteractionCompleted', interactionEnded)
	AddEventHandler('onPlayerInteractionCancelled', interactionEnded)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	OPX.Scheduler.Every('medical:sweep', config().scanMs, sweep)

	Open77.log.info(('[medical] %d service(s): %s'):format(#config().serviceOrder,
		table.concat(config().serviceOrder, ', ')))
end

--- Every treatment still running ends, not completed.
-- @author dop42
function M.Stop()
	for _, job in pairs(busy) do
		if not job.done then job.done = true end
	end
	busy, treating, byInteraction, invites = {}, {}, {}, {}
end

-- Exposed for the tests: the dispatch arithmetic and the handlers, by name.
M.Server = {
	OnTreat = onTreat, OnTake = onTake, OnBoard = onBoard, OnSubscribe = onSubscribe,
	OnDownedChanged = onDownedChanged, Sweep = sweep, Finish = finish,
}
