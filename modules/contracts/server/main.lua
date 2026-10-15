--- Server half: the gigs, the escrow, the objectives, the settlement and the cred.
-- @author dop42
--
-- EVERY DECISION IS HERE. A client asks for the board, a post, an accept, a
-- delivery; the server re-reads the character, the job, the position, the bag
-- and the gig, decides, writes, and answers with a locale key.
--
-- THE MONEY PATTERN, one rule for every eddie that moves:
--
--   reserve the operation in the ledger (`contracts:<id>:<phase>`, a primary
--   key, so a replay finds the first receipt and moves nothing)
--   -> move the money
--   -> commit the operation (or cancel it, and nothing moved)
--
-- and a terminal outcome is written as `settling` BEFORE any payment, so a
-- restart halfway through a settlement settles again rather than forgetting
-- who was owed. Payments go through `character.AddMoneyOffline`, which pays a
-- character whether anybody is playing it or not: a merc who logged off after
-- the delivery is still paid.
--
-- WHERE THE RACE IS WON. Two mercs accept the same gig in the same tick. The
-- server VM is single-threaded and coroutines only interleave at a yield, so
-- `lock` -- a read and a write of one table slot with nothing between them --
-- is atomic; whoever comes second is refused `taken` before any database call.
-- The UPDATE in `move` names the state and revision it read, so a second
-- process (or a bug that forgot the lock) still cannot take a gig twice.
--
-- THE MERC IS FROZEN AT ACCEPT. Their citizen id is read before the first
-- yield and written into the gig; everything after pays, fines and credits
-- THAT character, whatever the connection does meanwhile.

local M = OPX.Modules.Get('contracts')
local Access, State, Phase = M.Access, M.State, M.Phase
local Result = OPX.Result

-- Open gigs by id. A final one leaves this table.
local contracts = {}
-- Gig ids with an action in flight: the in-memory claim.
local claims = {}
-- Objective types by name.
local types = {}
-- The NPCs this module stands up, by id as a decimal string.
local npcs = {}
-- reach_zone: gig id -> the ms the merc entered the zone.
local holding = {}
-- One posting at a time per poster citizen id.
local posting = {}
-- Per-player request windows.
local windows = {}
-- District fixer -> the ms it last posted.
local fixerClock = {}
-- Settling gig id -> the ms of the last retry.
local retried = {}
-- Gigs generated since boot, the district fixers' seed.
local sequence = 0
local loaded = false
local sweepJob, fixerJob = nil, nil
local generating = false

local REQUESTS, WINDOW_MS = 8, 2000
local RETRY_MS = 30000
local OWNER = 'contracts'

local function safe(value) return OPX.Audit.Safe(tostring(value), 96) end

-- ── the world and the people ────────────────────────────────────────────────

--- Wall-clock seconds. Unix time from the host; process seconds where the host
--- has none (the test harness), which keeps every deadline relative and sound.
local function wall()
	local time = Open77 and Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local ok, now = pcall(time.unix)
		if ok and type(now) == 'number' and now == now then return math.floor(now) end
	end
	return OPX.Now() // 1000
end

local function characterApi() return OPX.Api.Get('character') end
local function inventoryApi() return OPX.Api.Get('inventory') end

--- The loaded character data at a connection, or nil.
local function dataOf(player)
	local api = characterApi()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local ok, loaded = pcall(api.GetPlayer, player)
	if not ok or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return loaded.PlayerData
end

local function citizenOf(player)
	local data = dataOf(player)
	return data and data.citizenId or nil
end

--- The connection playing a citizen id right now, or nil.
local function sourceOf(citizenId)
	if citizenId == nil then return nil end
	local api = characterApi()
	if api == nil or type(api.GetPlayerByCitizenId) ~= 'function' then return nil end
	local ok, loaded = pcall(api.GetPlayerByCitizenId, citizenId)
	if not ok or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	return tonumber(loaded.PlayerData.source)
end

local function nameOf(data)
	local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo or {}
	local name = OPX.String.Trim(('%s %s'):format(info.firstName or '', info.lastName or ''))
	return name ~= '' and name or tostring(data and data.citizenId or '?')
end

--- Whether a character passes a POSTERS / TAKERS block. Server roster read, so
--- the snapshot age is zero by construction.
local function passes(data, block)
	if type(data) ~= 'table' then return false, 'no_character' end
	local now = OPX.Now()
	return OPX.JobGate.Evaluate({ jobs = block.JOBS, onDuty = block.ON_DUTY },
		{ job = data.job, jobs = data.jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = Access.MEMBERSHIP })
end

--- The grade a character holds in the first job of a block they hold.
local function gradeIn(data, block)
	local jobs = type(block.JOBS) == 'table' and block.JOBS or {}
	local job = type(data) == 'table' and data.job or nil
	if type(job) == 'table' and jobs[job.name] ~= nil then
		return type(job.grade) == 'table' and math.tointeger(tonumber(job.grade.level)) or 0
	end
	return 0
end

--- The position and bucket of a connection, or nil.
local function standing(player)
	player = math.tointeger(tonumber(player))
	if player == nil or player < 1 then return nil end
	if type(Open77.players) ~= 'table' or type(Open77.players.position) ~= 'function' then
		return nil
	end
	local ok, at = pcall(Open77.players.position, player)
	if not ok or type(at) ~= 'table' then return nil end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(tonumber(at.bucket)) or 0 }
end

local function within(at, place, reach)
	if at == nil or place == nil or at.bucket ~= (place.bucket or 0) then return false end
	local dx, dy, dz = at.x - place.x, at.y - place.y, at.z - place.z
	local limit = place.radius + (reach or 0)
	return dx * dx + dy * dy + dz * dz <= limit * limit
end

--- The street cred of a citizen: from memory when they are loaded, else nil
--- (cred is only ever needed for somebody standing at the board).
local function credOf(player)
	local api = characterApi()
	if api == nil or type(api.GetMetadata) ~= 'function' then return Access.CredRecord(nil) end
	local ok, value = pcall(api.GetMetadata, player, Access.CRED_KEY)
	return Access.CredRecord(ok and value or nil)
end

-- ── telling people ──────────────────────────────────────────────────────────

local function tell(player, key, params, kind)
	if player == nil or player < 1 then return end
	OPX.NotifyLocale(player, key, params, kind or 'info')
end

local function tellCitizen(citizenId, key, params, kind)
	tell(sourceOf(citizenId), key, params, kind)
end

local function refuse(player, code)
	local key = 'contracts.refused.' .. tostring(code)
	if not OPX.Locale.Exists(key) then key = 'contracts.refused.generic' end
	tell(player, key, nil, 'error')
end

local function money(amount) return OPX.Locale.Money(amount, Access.CURRENCY) end

local function allowed(player)
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= WINDOW_MS then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= REQUESTS then return false end
	window.count = window.count + 1
	return true
end

-- ── objective types ─────────────────────────────────────────────────────────

--- What a gig's objective is called on a board, and in which district.
local function describe(kind, objective)
	local handlers = types[kind]
	if handlers == nil or type(handlers.describe) ~= 'function' then return nil, nil end
	local ok, label, district = pcall(handlers.describe, objective or {})
	if not ok then return nil, nil end
	return label, district
end

--- Where a merc should go, or nil.
local function waypointOf(contract)
	local handlers = types[contract.type]
	if handlers == nil or type(handlers.waypoint) ~= 'function' then return nil end
	local ok, point = pcall(handlers.waypoint, contract.objective or {})
	if not ok or type(point) ~= 'table' then return nil end
	return point
end

--- Validates an objective through its type, or refuses.
local function objectiveOf(kind, objective)
	local handlers = types[kind]
	if handlers == nil then return nil, 'bad_type' end
	if handlers.config and not Access.TypeEnabled(kind) then return nil, 'type_disabled' end
	if type(handlers.validate) ~= 'function' then return type(objective) == 'table' and objective or {} end
	local ok, normalized, why = pcall(handlers.validate, type(objective) == 'table' and objective or {})
	if not ok then return nil, 'bad_objective' end
	return normalized, why
end

-- ── storage, the ledger and the state machine ───────────────────────────────

local function lock(id)
	if claims[id] then return false end
	claims[id] = true
	return true
end

local function unlock(id) claims[id] = nil end

--- Runs `body` holding a gig's claim, and ALWAYS lets it go: a raise inside a
--- settlement must not leave the gig claimed for the life of the process.
-- @return boolean, string|nil
local function withClaim(id, body)
	if not lock(id) then return false, 'busy' end
	local ran, ok, why = pcall(body)
	unlock(id)
	if not ran then
		Open77.log.error(('[contracts] gig %s raised: %s'):format(tostring(id), safe(ok)))
		return false, 'generic'
	end
	return ok, why
end

--- Claims a gig NOW, in this resume, and runs `body` on a thread of its own,
--- letting the claim go however the body ends. What the sweep uses: the claim
--- must be taken before the next pass looks, the work may yield.
-- @return boolean whether the claim was taken
local function detached(id, body)
	if not lock(id) then return false end
	CreateThread(function()
		local ran, failure = pcall(body)
		unlock(id)
		if not ran then
			Open77.log.error(('[contracts] gig %s raised: %s'):format(tostring(id), safe(failure)))
		end
	end)
	return true
end

--- Moves a gig to a new state, in the database first and in memory second.
-- @return boolean
-- @return string|nil conflict | storage | bad_edge
local function move(contract, to, changes, actorCid, data)
	if not Access.Allowed(contract.state, to) then return false, 'bad_edge' end
	local nextRecord = {}
	for key, value in pairs(contract) do nextRecord[key] = value end
	for key, value in pairs(changes or {}) do
		if value == false then nextRecord[key] = nil else nextRecord[key] = value end
	end
	nextRecord.state = to
	nextRecord.rev = contract.rev + 1
	local from = contract.state
	local moved = M.Storage.Move(nextRecord, from, contract.rev)
	if not moved.ok then
		Open77.log.error(('[contracts] gig %d: %s -> %s was not written: %s'):format(contract.id,
			from, to, safe(moved.detail or moved.error)))
		return false, 'storage'
	end
	if moved.value ~= true then
		Open77.log.warn(('[contracts] gig %d: %s -> %s lost a race (rev %d)'):format(contract.id,
			from, to, contract.rev))
		return false, 'conflict'
	end
	for key in pairs(contract) do contract[key] = nil end
	for key, value in pairs(nextRecord) do contract[key] = value end
	if Access.IsOpen(to) then contracts[contract.id] = contract else contracts[contract.id] = nil end
	local wrote = M.Storage.History(contract.id, actorCid, from, to, data)
	if not wrote.ok then
		Open77.log.warn(('[contracts] gig %d: history not written: %s'):format(contract.id,
			safe(wrote.detail or wrote.error)))
	end
	return true
end

--- Runs one money operation exactly once.
-- `run()` answers `ok, why`. An amount of zero is done without a row.
-- @return boolean
-- @return string|nil
local function operate(contract, phase, citizenId, amount, run)
	amount = math.tointeger(amount) or 0
	if amount <= 0 then return true end
	local op = { id = ('contracts:%d:%s'):format(contract.id, phase), contractId = contract.id,
		phase = phase, citizenId = citizenId, amount = amount }
	local reserved = M.Storage.Reserve(op)
	if not reserved.ok then return false, 'storage' end
	if not reserved.value.fresh then
		if reserved.value.state == 'committed' then return true end
		if reserved.value.state ~= 'cancelled' then return false, 'in_flight' end
		-- A cancelled attempt moved nothing: take it again.
		local rearmed = M.Storage.Rearm(op.id)
		if not rearmed.ok or rearmed.value ~= true then return false, 'in_flight' end
	end
	local called, ok, why = pcall(run)
	if not called then ok, why = false, ok end
	local settled = M.Storage.Settle(op.id, ok and 'committed' or 'cancelled')
	if not settled.ok then
		Open77.log.error(('[contracts] %s moved=%s but the ledger was not updated: %s')
			:format(op.id, tostring(ok), safe(settled.detail or settled.error)))
	end
	OPX.Audit.Log({
		event = 'contracts.' .. phase,
		severity = ok and 'info' or 'warn',
		message = ('%s %d %s'):format(op.id, amount, Access.CURRENCY),
		citizenId = citizenId,
		data = { contract = contract.id, phase = phase, amount = amount, ok = ok == true,
			error = not ok and safe(why) or nil },
	})
	return ok == true, why
end

--- Pays a character, online or not.
local function pay(citizenId, amount, reason)
	local api = characterApi()
	if api == nil or type(api.AddMoneyOffline) ~= 'function' then return false, 'no_character' end
	local answer = api.AddMoneyOffline(citizenId, Access.CURRENCY, amount, reason)
	if type(answer) == 'table' and answer.ok == true then return true end
	return false, type(answer) == 'table' and answer.error or 'not_paid'
end

--- Writes a merc's cred after an ending. Best effort, offline-safe.
local function credit(citizenId, outcome)
	local api = characterApi()
	if citizenId == nil or api == nil or type(api.ReadMetadata) ~= 'function'
		or type(api.WriteMetadata) ~= 'function' then
		return
	end
	local read = api.ReadMetadata(citizenId)
	if type(read) ~= 'table' or read.ok ~= true then return end
	local metadata = type(read.value) == 'table' and read.value.metadata or {}
	local after = Access.CredAfter(metadata[Access.CRED_KEY], outcome)
	local wrote = api.WriteMetadata(citizenId, Access.CRED_KEY, after)
	if type(wrote) ~= 'table' or wrote.ok ~= true then
		Open77.log.warn(('[contracts] cred of %s not written: %s'):format(safe(citizenId),
			safe(type(wrote) == 'table' and wrote.error or wrote)))
		return
	end
	local player = sourceOf(citizenId)
	if player ~= nil then
		local _, label = Access.Tier(after.cred)
		tell(player, 'contracts.cred', { cred = after.cred, tier = label },
			(Access.CRED_GAIN[outcome] or 0) >= 0 and 'success' or 'warning')
	end
end

-- What the public bus is told: never the objective, never a position.
local function busPayload(contract)
	return { id = contract.id, type = contract.type, posterKind = contract.posterKind,
		posterCid = contract.posterCid, mercCid = contract.mercCid, reward = contract.reward,
		cutPct = contract.cutPct, funded = contract.funded, state = contract.state,
		outcome = contract.outcome }
end

-- ── the merc's screen ───────────────────────────────────────────────────────

--- The gig a citizen is working, or nil.
local function workingFor(citizenId)
	if citizenId == nil then return nil end
	for _, contract in pairs(contracts) do
		if contract.mercCid == citizenId and Access.IsWorking(contract.state) then return contract end
	end
	return nil
end

--- Tells a merc what they are working on, with the waypoint, or that they
--- are working on nothing.
local function sendActive(player)
	if player == nil or player < 1 then return end
	local contract = workingFor(citizenOf(player))
	if contract == nil then
		TriggerClientEvent(M.Event.ACTIVE, player, false)
		return
	end
	local point = waypointOf(contract)
	TriggerClientEvent(M.Event.ACTIVE, player, {
		id = contract.id, type = contract.type, title = contract.title, state = contract.state,
		waypoint = point and { x = point.x, y = point.y, z = point.z } or nil,
		target = point and point.label or nil,
	})
end

-- ── settlement ──────────────────────────────────────────────────────────────

local ENDINGS = {
	paid = M.Event.ON_PAID, failed = M.Event.ON_FAILED, expired = M.Event.ON_EXPIRED,
	cancelled = M.Event.ON_CANCELLED,
}

--- Makes every payment a settling gig owes, then closes it. Safe to run again:
--- every payment is a ledger operation and a done one is not repeated.
-- @return boolean whether the gig is closed
local function finish(contract)
	local outcome = contract.outcome
	local id = contract.id
	local reason = ('contracts:%d:%s'):format(id, tostring(outcome))
	local ok = true

	if outcome == State.PAID then
		local merc, cut = Access.Split(contract.reward, contract.cutPct)
		local phase = contract.funded == M.Funded.MINT and Phase.MINT or Phase.COMMIT
		ok = operate(contract, phase, contract.mercCid, merc, function()
			return pay(contract.mercCid, merc, reason)
		end) and ok
		-- THE CUT GOES BACK TO A PLAYER FIXER, who fronted the escrow; an NPC
		-- fixer's cut, and an external poster's with nobody to receive it, is
		-- destroyed: a sink, not a transfer.
		if contract.posterKind ~= M.Poster.NPC and contract.posterCid ~= nil then
			ok = operate(contract, Phase.CUT, contract.posterCid, cut, function()
				return pay(contract.posterCid, cut, reason .. ':cut')
			end) and ok
		end
	else
		if contract.funded == M.Funded.PLAYER and contract.payerCid ~= nil then
			ok = operate(contract, Phase.REFUND, contract.payerCid, contract.reward, function()
				return pay(contract.payerCid, contract.reward, reason .. ':refund')
			end) and ok
		end
		local failedMerc = outcome == State.FAILED and contract.mercCid ~= nil
		local fine = failedMerc and Access.Penalty(contract.reward) or 0
		if fine > 0 then
			-- From an ONLINE merc who can pay it; nobody is put in debt by a gig. A
			-- merc who cannot is recorded as fined zero and the op is closed.
			ok = operate(contract, Phase.PENALTY, contract.mercCid, fine, function()
				local player = sourceOf(contract.mercCid)
				local api = characterApi()
				if player == nil or api == nil then return true end
				local taken = api.RemoveMoney(player, Access.CURRENCY, fine, reason .. ':fine')
				if not taken then return true end
				tell(player, 'contracts.fined', { amount = money(fine) }, 'warning')
				if contract.funded == M.Funded.PLAYER and contract.payerCid ~= nil then
					return pay(contract.payerCid, fine, reason .. ':fine')
				end
				return true
			end) and ok
		end
		-- The package goes back to nobody: a failed delivery's parcel is gone.
		local handlers = types[contract.type]
		if contract.mercCid ~= nil and handlers ~= nil and type(handlers.stop) == 'function' then
			pcall(handlers.stop, contract)
		end
	end

	if not ok then
		retried[id] = OPX.Now()
		Open77.log.warn(('[contracts] gig %d is still settling (%s); it will be retried')
			:format(id, tostring(outcome)))
		return false
	end
	local closed = move(contract, outcome, nil, nil, nil)
	if not closed then return false end
	retried[id], holding[id] = nil, nil

	local merc, cut = Access.Split(contract.reward, contract.cutPct)
	if outcome == State.PAID then
		tellCitizen(contract.mercCid, 'contracts.paid', { title = contract.title, amount = money(merc) },
			'success')
		if contract.posterKind == M.Poster.PLAYER then
			tellCitizen(contract.posterCid, 'contracts.cut', { title = contract.title,
				amount = money(cut) }, 'success')
		end
		pcall(credit, contract.mercCid, 'done')
	else
		if contract.funded == M.Funded.PLAYER then
			tellCitizen(contract.payerCid, 'contracts.refunded', { title = contract.title,
				amount = money(contract.reward) }, 'info')
		end
		if contract.mercCid ~= nil then
			tellCitizen(contract.mercCid, 'contracts.ended.' .. outcome, { title = contract.title },
				'warning')
			if outcome == State.FAILED then
				local abandoned = type(contract.proof) == 'table' and contract.proof.reason == 'abandoned'
				pcall(credit, contract.mercCid, abandoned and 'abandoned' or 'failed')
			end
		end
	end
	local merc_ = sourceOf(contract.mercCid)
	if merc_ ~= nil then sendActive(merc_) end
	OPX.Publish(ENDINGS[outcome], nil, busPayload(contract))
	return true
end

--- Ends a gig with an outcome: written as settling, then finished.
-- The caller holds the lock.
-- @return boolean
-- @return string|nil
local function settle(contract, outcome, changes, actorCid)
	if contract.state ~= State.SETTLING then
		local fields = { outcome = outcome }
		for key, value in pairs(changes or {}) do fields[key] = value end
		local moved, why = move(contract, State.SETTLING, fields, actorCid, { outcome = outcome })
		if not moved then return false, why end
	end
	finish(contract)
	return true
end

--- Records the proof the server saw, and pays at once when the gig is auto.
local function prove(contract, proof, actorCid)
	local changes = { proof = proof }
	if contract.validate == 'manual' then changes.deadlineAt = wall() + Access.VALIDATE_TTL_S end
	local moved, why = move(contract, State.PROOF, changes, actorCid, proof)
	if not moved then return false, why end
	if contract.validate == 'auto' then return settle(contract, State.PAID, nil, actorCid) end
	tellCitizen(contract.mercCid, 'contracts.awaiting', { title = contract.title }, 'info')
	if contract.posterKind == M.Poster.PLAYER then
		tellCitizen(contract.posterCid, 'contracts.review', { id = contract.id,
			title = contract.title }, 'info')
	end
	local player = sourceOf(contract.mercCid)
	if player ~= nil then sendActive(player) end
	return true
end

-- ── posting ─────────────────────────────────────────────────────────────────

--- The open gigs of one poster (by citizen id, or by NPC fixer name).
local function openBy(citizenId, name)
	local count = 0
	for _, contract in pairs(contracts) do
		if Access.IsOpen(contract.state) and ((citizenId ~= nil and contract.posterCid == citizenId)
			or (citizenId == nil and name ~= nil and contract.posterKind == M.Poster.NPC
				and contract.posterName == name)) then
			count = count + 1
		end
	end
	return count
end

--- Files a validated spec, takes the escrow, and puts it on the board.
-- `who` = { posterKind, posterCid?, posterName, payerCid?, funded, player? }.
-- @return boolean
-- @return integer|string the gig id, or the refusal
local function create(spec, who)
	local _, district = describe(spec.type, spec.objective)
	local record = {
		state = State.LOCKING, rev = 0, type = spec.type, district = district,
		title = spec.title, brief = spec.brief, posterKind = who.posterKind,
		posterCid = who.posterCid, posterName = who.posterName, payerCid = who.payerCid,
		reward = spec.reward, cutPct = spec.cutPct, funded = who.funded, minCred = spec.minCred,
		validate = spec.validate, objective = spec.objective, deadlineAt = wall() + spec.deadlineS,
	}
	local inserted = M.Storage.Insert(record)
	if not inserted.ok then
		Open77.log.error('[contracts] a gig was not filed: ' .. safe(inserted.detail or inserted.error))
		return false, 'storage'
	end
	record.id = inserted.value

	if who.funded == M.Funded.PLAYER then
		local api = characterApi()
		local total = spec.reward + Access.POST_FEE
		local escrowed, why = operate(record, Phase.RESERVE, who.payerCid, total, function()
			-- THE SAME CHARACTER, checked after every yield above: a connection
			-- that switched character meanwhile is not the payer any more.
			if citizenOf(who.player) ~= who.payerCid then return false, 'character_changed' end
			return api.RemoveMoney(who.player, Access.CURRENCY, total,
				('contracts:%d:escrow'):format(record.id))
		end)
		if not escrowed then
			M.Storage.Forget(record.id)
			if why == 'money.insufficient' then return false, 'not_enough_money' end
			return false, 'escrow_failed'
		end
		-- The fee is bookkeeping: taken with the escrow above, destroyed here.
		operate(record, Phase.FEE, who.payerCid, Access.POST_FEE, function() return true end)
	end

	local moved, why = move(record, State.POSTED, nil, who.posterCid, { reward = spec.reward })
	if not moved then
		-- The row stays `locking`; the boot reconcile refunds a taken escrow.
		return false, why
	end
	Open77.log.info(('[contracts] gig %d posted by %s: %s, %d %s'):format(record.id,
		safe(who.posterName), record.type, record.reward, Access.CURRENCY))
	OPX.Publish(M.Event.ON_POSTED, who.player, busPayload(record))

	-- "Incoming call from a fixer": every merc online who could take it hears.
	local api = characterApi()
	if api ~= nil and type(api.GetPlayers) == 'function' then
		for _, loaded in ipairs(api.GetPlayers()) do
			local data = loaded.PlayerData
			if data ~= nil and data.citizenId ~= record.posterCid and passes(data, Access.TAKERS)
				and credOf(data.source).cred >= record.minCred then
				tell(data.source, 'contracts.incoming', { fixer = record.posterName or '?',
					title = record.title, amount = money((Access.Split(record.reward, record.cutPct))) },
					'info')
			end
		end
	end
	return true, record.id
end

--- The form a player sent, into a spec, and posted.
local function postFromPlayer(player, form)
	if not loaded then return false, 'unavailable' end
	local data = dataOf(player)
	if data == nil then return false, 'no_character' end
	local gated, why = passes(data, Access.POSTERS)
	if not gated then return false, why end
	if type(form) ~= 'table' then return false, 'bad_spec' end
	local citizenId = data.citizenId
	if posting[citizenId] then return false, 'busy' end
	if openBy(citizenId) >= Access.MAX_OPEN_PER_POSTER then return false, 'too_many_open' end

	local objective = {}
	local target = type(form.target) == 'string' and form.target or ''
	local kind, key = target:match('^([dz]):([%w_%-]+)$')
	if kind == 'd' then objective.dropoff = key elseif kind == 'z' then objective.zone = key end
	local low, high = Access.CutBounds(gradeIn(data, Access.POSTERS))
	local spec, refused = Access.NormalizeSpec({
		type = form.type, title = form.title, brief = form.brief,
		reward = tonumber(form.reward), cutPct = tonumber(form.cut),
		deadlineS = tonumber(form.deadline), minCred = Access.TierMin(tonumber(form.tier)) or 0,
		objective = objective,
	}, { cutLow = low, cutHigh = high, objective = objectiveOf })
	if spec == nil then return false, refused end

	local api = characterApi()
	local held = api.GetMoney(player, Access.CURRENCY)
	if (tonumber(held) or 0) < spec.reward + Access.POST_FEE then return false, 'not_enough_money' end

	-- ONE POST IN FLIGHT PER POSTER, and released however `create` ends: two
	-- forms sent in the same breath would both pass the open-gig cap above.
	posting[citizenId] = true
	local called, ok, value = pcall(create, spec, { posterKind = M.Poster.PLAYER,
		posterCid = citizenId, posterName = nameOf(data), payerCid = citizenId,
		funded = M.Funded.PLAYER, player = player })
	posting[citizenId] = nil
	if not called then
		Open77.log.error('[contracts] a post raised: ' .. safe(ok))
		return false, 'generic'
	end
	if ok then
		tell(player, 'contracts.posted', { id = value, title = spec.title,
			amount = money(spec.reward + Access.POST_FEE) }, 'success')
	end
	return ok, value
end

-- ── the merc's actions ──────────────────────────────────────────────────────

local function accept(player, id)
	local contract = contracts[id]
	if contract == nil or contract.state ~= State.POSTED then return false, 'not_available' end
	local data = dataOf(player)
	if data == nil then return false, 'no_character' end
	local gated, why = passes(data, Access.TAKERS)
	if not gated then return false, why end
	-- FROZEN HERE, before any yield.
	local citizenId = data.citizenId
	if contract.posterCid == citizenId then return false, 'own_gig' end
	if credOf(player).cred < contract.minCred then return false, 'cred_too_low' end
	local working = 0
	for _, other in pairs(contracts) do
		if other.mercCid == citizenId and Access.IsWorking(other.state) then working = working + 1 end
	end
	if working >= Access.MAX_ACTIVE_PER_MERC then return false, 'already_working' end
	if contract.deadlineAt <= wall() then return false, 'not_available' end
	-- A gig somebody else is in the middle of taking is, to this merc, taken.
	if claims[id] then return false, 'taken' end

	local ok, refused = withClaim(id, function()
		local handlers = types[contract.type]
		if handlers ~= nil and type(handlers.canStart) == 'function' then
			local can, why2 = handlers.canStart(contract, player)
			if not can then return false, why2 or 'cannot_start' end
		end
		local boardDeadline = contract.deadlineAt
		local moved, why2 = move(contract, State.ACCEPTED, { mercCid = citizenId,
			deadlineAt = wall() + Access.ACCEPT_TTL_S }, citizenId)
		if not moved then return false, why2 == 'conflict' and 'taken' or why2 end
		if handlers ~= nil and type(handlers.start) == 'function' then
			local called, started, why3 = pcall(handlers.start, contract, player)
			if not called or not started then
				move(contract, State.POSTED, { mercCid = false, deadlineAt = boardDeadline }, citizenId,
					{ reason = 'start_failed' })
				return false, called and (why3 or 'cannot_start') or 'cannot_start'
			end
		end
		move(contract, State.IN_PROGRESS, nil, citizenId)
		return true
	end)
	if not ok then return false, refused end
	Open77.log.info(('[contracts] gig %d taken by %s'):format(id, safe(citizenId)))
	OPX.Publish(M.Event.ON_ACCEPTED, player, busPayload(contract))
	tell(player, 'contracts.accepted', { title = contract.title,
		minutes = math.max(1, Access.ACCEPT_TTL_S // 60) }, 'success')
	if contract.posterKind == M.Poster.PLAYER then
		tellCitizen(contract.posterCid, 'contracts.taken', { title = contract.title,
			merc = nameOf(data) }, 'info')
	end
	sendActive(player)
	return true
end

local function abandon(player, id)
	local contract = contracts[id]
	local citizenId = citizenOf(player)
	if contract == nil or citizenId == nil or contract.mercCid ~= citizenId
		or (contract.state ~= State.ACCEPTED and contract.state ~= State.IN_PROGRESS) then
		return false, 'not_yours'
	end
	return withClaim(id, function()
		return settle(contract, State.FAILED, { proof = { reason = 'abandoned', at = wall() } },
			citizenId)
	end)
end

local function cancel(player, id)
	local contract = contracts[id]
	local citizenId = citizenOf(player)
	if contract == nil or citizenId == nil or contract.posterCid ~= citizenId then
		return false, 'not_yours'
	end
	if contract.state ~= State.POSTED then return false, 'already_taken' end
	return withClaim(id, function() return settle(contract, State.CANCELLED, nil, citizenId) end)
end

--- A delivery at a drop-off, through its NPC or standing on it.
local function deliver(player, npcKey)
	local citizenId = citizenOf(player)
	local contract = workingFor(citizenId)
	if contract == nil or contract.type ~= 'deliver_item' or contract.state ~= State.IN_PROGRESS then
		return false, 'no_delivery'
	end
	local dropoff = Access.Dropoff(contract.objective.dropoff)
	if dropoff == nil then return false, 'no_delivery' end
	if npcKey ~= nil then
		local npc = npcs[npcKey]
		if npc == nil or npc.kind ~= 'dropoff' or npc.key ~= dropoff.key then
			return false, 'wrong_dropoff'
		end
	end
	if not within(standing(player), dropoff, Access.DELIVER_REACH) then return false, 'too_far' end
	return withClaim(contract.id, function()
		-- THE PARCEL COMES OUT FIRST, and the proof is written only for one that
		-- did: the item is the evidence, and a second press finds none.
		local inventory = inventoryApi()
		local taken = inventory ~= nil and inventory.RemoveWhere(player, Access.ITEM,
			{ contract = contract.id }) or nil
		if type(taken) ~= 'table' or taken.ok ~= true or (tonumber(taken.value) or 0) < 1 then
			return false, 'no_package'
		end
		local at = standing(player)
		tell(player, 'contracts.delivered', { place = dropoff.label }, 'success')
		return prove(contract, { kind = 'delivered', at = wall(), dropoff = dropoff.key,
			x = at and at.x, y = at and at.y, z = at and at.z }, citizenId)
	end)
end

local function report(player, id)
	local contract = contracts[id]
	local citizenId = citizenOf(player)
	if contract == nil or contract.mercCid ~= citizenId or contract.state ~= State.IN_PROGRESS then
		return false, 'not_yours'
	end
	if contract.type ~= 'manual' then return false, 'not_manual' end
	return withClaim(id, function()
		return prove(contract, { kind = 'reported', at = wall() }, citizenId)
	end)
end

--- Whether a character may rule on a manual gig: its poster, or a poster of
--- VALIDATE_GRADE or more.
local function mayValidate(data, contract)
	if data == nil then return false end
	if contract.posterCid ~= nil and contract.posterCid == data.citizenId then return true end
	return passes(data, Access.POSTERS) and gradeIn(data, Access.POSTERS) >= Access.VALIDATE_GRADE
end

local function rule(player, id, verdict)
	local contract = contracts[id]
	if contract == nil or contract.state ~= State.PROOF or contract.validate ~= 'manual' then
		return false, 'nothing_to_validate'
	end
	local data = dataOf(player)
	if not mayValidate(data, contract) then return false, 'not_allowed' end
	if contract.mercCid == data.citizenId then return false, 'own_gig' end
	return withClaim(id, function()
		if verdict then return settle(contract, State.PAID, nil, data.citizenId) end
		return settle(contract, State.FAILED, { proof = { reason = 'rejected', at = wall() } },
			data.citizenId)
	end)
end

--- Settles a gig from outside: staff, or another module's `Resolve`.
local function resolve(id, outcome, actor)
	local contract = contracts[id]
	if contract == nil then return false, 'not_found' end
	if outcome ~= State.PAID and outcome ~= State.FAILED then return false, 'bad_outcome' end
	if contract.state ~= State.PROOF and contract.state ~= State.DISPUTED
		and contract.state ~= State.IN_PROGRESS then
		return false, 'not_resolvable'
	end
	if outcome == State.PAID and contract.mercCid == nil then return false, 'no_merc' end
	local ok, why = withClaim(id, function()
		return settle(contract, outcome, outcome == State.FAILED and
			{ proof = { reason = 'resolved', by = actor, at = wall() } } or nil, nil)
	end)
	OPX.Audit.Log({ event = 'contracts.resolve', message = ('gig %d -> %s'):format(id, outcome),
		data = { contract = id, outcome = outcome, by = actor } })
	return ok, why
end

-- ── the board ───────────────────────────────────────────────────────────────

local function sortedIds()
	local ids = {}
	for id in pairs(contracts) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function publicOf(contract) return Access.Public(contract, describe) end

--- The board as one player may see it.
local function boardFor(player)
	local data = dataOf(player)
	if data == nil then return nil end
	local citizenId = data.citizenId
	local cred = credOf(player)
	local isTaker = passes(data, Access.TAKERS)
	local isPoster = passes(data, Access.POSTERS)
	local tier, label = Access.Tier(cred.cred)
	local nextTier = Access.TIERS[tier + 1]
	local board = {
		cred = cred.cred, done = cred.done, failed = cred.failed, tier = label,
		nextCred = nextTier and nextTier.min or nil, isTaker = isTaker == true,
		isPoster = isPoster == true, currency = Access.CURRENCY,
		rows = {}, posted = {}, review = {}, mine = nil,
	}
	local viewer = { citizenId = citizenId, cred = cred.cred }
	for _, id in ipairs(sortedIds()) do
		local contract = contracts[id]
		if isTaker and #board.rows < Access.BOARD_LIMIT and Access.Visible(contract, viewer) then
			board.rows[#board.rows + 1] = publicOf(contract)
		end
		if contract.posterCid == citizenId and #board.posted < 6 then
			board.posted[#board.posted + 1] = publicOf(contract)
		end
		if contract.state == State.PROOF and contract.validate == 'manual'
			and contract.mercCid ~= citizenId and #board.review < 6
			and mayValidate(data, contract) then
			board.review[#board.review + 1] = publicOf(contract)
		end
		if contract.mercCid == citizenId and Access.IsWorking(contract.state) then
			local row = publicOf(contract)
			local point = waypointOf(contract)
			row.target = point and point.label or row.target
			row.secondsLeft = math.max(0, contract.deadlineAt - wall())
			board.mine = row
		end
	end
	return board
end

local function sendBoard(player)
	local board = boardFor(player)
	if board == nil then return refuse(player, 'no_character') end
	if not board.isTaker and not board.isPoster then return refuse(player, 'job_required') end
	TriggerClientEvent(M.Event.SHOW_BOARD, player, board)
end

--- The form's choices for one poster.
local function sendForm(player)
	local data = dataOf(player)
	if data == nil then return refuse(player, 'no_character') end
	local gated, why = passes(data, Access.POSTERS)
	if not gated then return refuse(player, why) end
	local enabled = {}
	for _, name in ipairs({ 'deliver_item', 'reach_zone', 'manual' }) do
		if types[name] ~= nil and Access.TypeEnabled(name) then enabled[#enabled + 1] = name end
	end
	local targets = {}
	if Access.TypeEnabled('manual') then targets[#targets + 1] = { value = '', kind = 'none' } end
	for _, key in ipairs(Access.Keys('DROPOFFS')) do
		local row = Access.Dropoff(key)
		if row ~= nil then targets[#targets + 1] = { value = 'd:' .. key, label = row.label,
			district = row.district, kind = 'dropoff' } end
	end
	for _, key in ipairs(Access.Keys('ZONES')) do
		local row = Access.Zone(key)
		if row ~= nil then targets[#targets + 1] = { value = 'z:' .. key, label = row.label,
			district = row.district, kind = 'zone' } end
	end
	local low, high = Access.CutBounds(gradeIn(data, Access.POSTERS))
	local tiers = {}
	for index, tier in ipairs(Access.TIERS) do tiers[index] = { label = tier.label, min = tier.min } end
	local default = math.tointeger(OPX.Tune.Get('CONTRACT_FIXER_CUT')) or Access.CUT_DEFAULT
	TriggerClientEvent(M.Event.SHOW_FORM, player, {
		types = enabled, targets = targets, tiers = tiers,
		cut = { low = low, high = high, step = Access.CUT_STEP,
			default = math.min(high, math.max(low, default)) },
		deadlines = Access.DEADLINE_CHOICES, deadline = Access.DEADLINE_DEFAULT,
		reward = { min = Access.REWARD_MIN, max = Access.REWARD_MAX }, fee = Access.POST_FEE,
		titleMax = Access.TITLE_MAX, briefMax = Access.BRIEF_MAX, currency = Access.CURRENCY,
	})
end

-- ── the shipped objective types ─────────────────────────────────────────────

local function dropoffPoint(objective)
	local row = Access.Dropoff(objective.dropoff)
	return row and { x = row.x, y = row.y, z = row.z, label = row.label } or nil
end

local function zonePoint(objective)
	local row = Access.Zone(objective.zone)
	return row and { x = row.x, y = row.y, z = row.z, label = row.label } or nil
end

-- Whether the parcel item is in the catalogue this process.
local itemReady = false

--- Registers the parcel item, once per process, the first time a delivery
--- needs it. At runtime, so no other config has to name it; LAZILY, so a
--- server whose fixers never post a delivery adds nothing to the catalogue
--- every joining client is sent.
local function ensureItem()
	if itemReady then return true end
	local inventory = inventoryApi()
	if inventory == nil or type(inventory.RegisterItem) ~= 'function' then return false end
	local row = Access.TYPES.deliver_item or {}
	local registered = inventory.RegisterItem(Access.ITEM, {
		label = tostring(row.ITEM_LABEL or 'Parcel'),
		description = row.ITEM_DESCRIPTION and tostring(row.ITEM_DESCRIPTION) or nil,
		weight = math.tointeger(tonumber(row.ITEM_WEIGHT)) or 1000,
		stack = false, drop = false,
	}, OWNER)
	if type(registered) ~= 'table' or registered.ok ~= true then
		Open77.log.error(('[contracts] the delivery item %s was refused: %s'):format(Access.ITEM,
			safe(type(registered) == 'table' and registered.error or registered)))
		return false
	end
	itemReady = true
	return true
end

types.deliver_item = {
	config = true,
	validate = function(objective)
		if Access.Dropoff(objective.dropoff) == nil then return nil, 'bad_target' end
		return { dropoff = objective.dropoff }
	end,
	describe = function(objective)
		local row = Access.Dropoff(objective.dropoff)
		if row == nil then return nil, nil end
		return row.label, row.district
	end,
	waypoint = dropoffPoint,
	canStart = function(_, player)
		local inventory = inventoryApi()
		if inventory == nil or not ensureItem() then return false, 'no_inventory' end
		local room = inventory.CanCarry(player, Access.ITEM, 1)
		if type(room) == 'table' and room.ok == true and room.value == false then
			return false, 'no_room'
		end
		return true
	end,
	start = function(contract, player)
		local inventory = inventoryApi()
		if inventory == nil then return false, 'no_inventory' end
		local added = inventory.AddItem(player, Access.ITEM, 1, { contract = contract.id,
			label = contract.title })
		if type(added) ~= 'table' or added.ok ~= true then return false, 'no_room' end
		return true
	end,
	stop = function(contract)
		local inventory = inventoryApi()
		if inventory == nil or contract.mercCid == nil then return end
		inventory.RemoveWhere(contract.mercCid, Access.ITEM, { contract = contract.id })
	end,
}

types.reach_zone = {
	config = true,
	validate = function(objective)
		if Access.Zone(objective.zone) == nil then return nil, 'bad_target' end
		return { zone = objective.zone }
	end,
	describe = function(objective)
		local row = Access.Zone(objective.zone)
		if row == nil then return nil, nil end
		return row.label, row.district
	end,
	waypoint = zonePoint,
	-- Asked by the sweep, every pass, for every gig of this type in progress.
	tick = function(contract, nowMs)
		local player = sourceOf(contract.mercCid)
		local zone = Access.Zone(contract.objective.zone)
		if player == nil or zone == nil then holding[contract.id] = nil return end
		if not within(standing(player), zone, 0) then
			if holding[contract.id] ~= nil then tell(player, 'contracts.zone.left', nil, 'warning') end
			holding[contract.id] = nil
			return
		end
		local since = holding[contract.id]
		if since == nil then
			holding[contract.id] = nowMs
			tell(player, 'contracts.zone.hold', { seconds = math.ceil(Access.HOLD_MS / 1000),
				place = zone.label }, 'info')
			return
		end
		if nowMs - since < Access.HOLD_MS then return end
		holding[contract.id] = nil
		detached(contract.id, function()
			prove(contract, { kind = 'held', at = wall(), zone = zone.key }, contract.mercCid)
		end)
	end,
}

types.manual = {
	config = true,
	validate = function(objective)
		if objective.dropoff ~= nil then
			if Access.Dropoff(objective.dropoff) == nil then return nil, 'bad_target' end
			return { dropoff = objective.dropoff }
		end
		if objective.zone ~= nil then
			if Access.Zone(objective.zone) == nil then return nil, 'bad_target' end
			return { zone = objective.zone }
		end
		return {}
	end,
	describe = function(objective)
		local row = objective.dropoff and Access.Dropoff(objective.dropoff)
			or objective.zone and Access.Zone(objective.zone) or nil
		if row == nil then return nil, nil end
		return row.label, row.district
	end,
	waypoint = function(objective)
		if objective.dropoff then return dropoffPoint(objective) end
		if objective.zone then return zonePoint(objective) end
		return nil
	end,
}

-- ── the district fixers ─────────────────────────────────────────────────────

local function playerFixerOnDuty()
	local api = characterApi()
	if api == nil or type(api.GetPlayers) ~= 'function' then return false end
	local jobs = type(Access.POSTERS.JOBS) == 'table' and Access.POSTERS.JOBS or {}
	for _, loaded in ipairs(api.GetPlayers()) do
		local job = loaded.PlayerData and loaded.PlayerData.job
		if type(job) == 'table' and jobs[job.name] ~= nil and job.onDuty == true then return true end
	end
	return false
end

--- One pass over the district fixers: each may post one gig from its templates.
local function generate()
	if not loaded or generating then return end
	generating = true
	local ok, failure = pcall(function()
		local nowMs = OPX.Now()
		local cap = OPX.Tune.Number('CONTRACT_MINT_PER_HOUR', Access.MINT_PER_HOUR)
		local busyFixers = nil
		for _, key in ipairs(Access.Keys('FIXERS')) do
			local fixer = Access.Fixer(key)
			if fixer ~= nil and fixer.when ~= 'never' and #fixer.templates > 0
				and openBy(nil, fixer.name) < fixer.maxOpen
				and (fixerClock[key] == nil or nowMs - fixerClock[key] >= fixer.everyS * 1000) then
				if fixer.when == 'no_player_fixer' and busyFixers == nil then
					busyFixers = playerFixerOnDuty()
				end
				if not (fixer.when == 'no_player_fixer' and busyFixers) then
					sequence = sequence + 1
					local template = fixer.templates[Access.Pick(sequence, #fixer.templates)]
					local kind = type(template) == 'table' and (template.TYPE or 'deliver_item') or nil
					local read = kind == 'reach_zone' and Access.Zone or Access.Dropoff
					local usable = {}
					for _, target in ipairs(type(template) == 'table'
						and type(template.TARGETS) == 'table' and template.TARGETS or {}) do
						if read(target) ~= nil then usable[#usable + 1] = target end
					end
					fixerClock[key] = nowMs
					if #usable > 0 and Access.TypeEnabled(kind) then
						local target = usable[Access.Pick(sequence * 7 + 3, #usable)]
						local reward = Access.RewardIn(template.REWARD, sequence)
						local committed = 0
						for _, contract in pairs(contracts) do
							if contract.funded == M.Funded.MINT then committed = committed + contract.reward end
						end
						local minted = M.Storage.MintedLastHour()
						if minted.ok and minted.value + committed + reward <= cap then
							local spec = Access.NormalizeSpec({
								type = kind, title = template.TITLE, brief = template.BRIEF,
								reward = reward, cutPct = fixer.cutPct, deadlineS = fixer.deadlineS,
								minCred = math.tointeger(tonumber(template.MIN_CRED)) or 0,
								objective = kind == 'reach_zone' and { zone = target } or { dropoff = target },
							}, { cutLow = fixer.cutPct, cutHigh = fixer.cutPct, objective = objectiveOf })
							if spec ~= nil then
								create(spec, { posterKind = M.Poster.NPC, posterName = fixer.name,
									funded = M.Funded.MINT })
							end
						end
					end
				end
			end
		end
	end)
	generating = false
	if not ok then Open77.log.error('[contracts] the district fixers raised: ' .. safe(failure)) end
end

-- ── the NPCs ────────────────────────────────────────────────────────────────

local function npcList()
	local list = {}
	for key, npc in pairs(npcs) do
		list[#list + 1] = { npc = key, kind = npc.kind, key = npc.key, label = npc.label }
	end
	table.sort(list, function(a, b) return a.npc < b.npc end)
	return list
end

local function spawnNpcs()
	local api = Open77.npcs
	if type(api) ~= 'table' or type(api.create) ~= 'function' then
		Open77.log.warn('[contracts] the NPC API is unavailable; no fixer or drop-off NPC will stand')
		return
	end
	local immortal = type(api.damage) == 'table' and api.damage.immortal or nil
	local ai = type(api.ai) == 'table' and api.ai.tasks or nil
	local function place(kind, key, label, at)
		local called, id, why = pcall(api.create, {
			record = at.record, position = { x = at.x, y = at.y, z = at.z }, yaw = at.yaw,
			bucket = at.bucket or 0, aiMode = ai, damagePolicy = immortal,
			behavior = { combatEnabled = false, voiceEnabled = false },
			despawnWhenUnobserved = false,
		})
		if called and id ~= nil then
			local name = math.type(id) == 'integer' and ('%d'):format(id) or tostring(id)
			npcs[name] = { id = id, kind = kind, key = key, label = label }
		else
			Open77.log.error(('[contracts] no NPC for %s %s (%s): %s'):format(kind, key,
				safe(at.record), safe(called and why or id)))
		end
	end
	for _, key in ipairs(Access.Keys('FIXERS')) do
		local fixer = Access.Fixer(key)
		if fixer ~= nil and fixer.npc ~= nil then place('fixer', key, fixer.name, fixer.npc) end
	end
	for _, key in ipairs(Access.Keys('DROPOFFS')) do
		local row = Access.Dropoff(key)
		if row ~= nil and row.npc ~= nil then
			place('dropoff', key, row.label, { record = row.npc.record, yaw = row.npc.yaw,
				x = row.x, y = row.y, z = row.z, bucket = row.bucket })
		end
	end
	if next(npcs) ~= nil then TriggerClientEvent(M.Event.NPCS, -1, npcList()) end
end

local function removeNpcs()
	if type(Open77.npcs) == 'table' and type(Open77.npcs.remove) == 'function' then
		for _, npc in pairs(npcs) do pcall(Open77.npcs.remove, npc.id) end
	end
	npcs = {}
end

-- ── boot and the sweep ──────────────────────────────────────────────────────

--- Loads every open gig and finishes what a dead process left half done.
local function reconcile()
	local pending = M.Storage.Pending()
	if pending.ok then
		for _, op in ipairs(pending.value) do
			-- A RESERVED OPERATION IS AN UNKNOWN: the money may or may not have
			-- moved. It is never guessed at -- not repaid, not retried -- but
			-- marked `orphaned` and put in front of staff with every number.
			M.Storage.Settle(op.id, 'orphaned')
			OPX.Audit.Log({ event = 'contracts.orphaned', severity = 'error',
				message = ('%s: %d %s for %s may or may not have moved; check by hand')
					:format(op.id, op.amount, Access.CURRENCY, tostring(op.citizenId)),
				citizenId = op.citizenId, data = op })
			Open77.log.error(('[contracts] ledger %s was left mid-payment (%d for %s); marked ' ..
				'orphaned for staff'):format(op.id, op.amount, safe(op.citizenId)))
		end
	end

	local read = M.Storage.LoadOpen()
	if not read.ok then
		Open77.log.error('[contracts] the open gigs could not be read: ' ..
			safe(read.detail or read.error))
		return false
	end
	for _, record in ipairs(read.value) do
		contracts[record.id] = record
		-- A parcel already in a bag needs its catalogue entry back.
		if record.type == 'deliver_item' and record.mercCid ~= nil then ensureItem() end
	end
	for _, record in ipairs(read.value) do
		if record.state == State.LOCKING then
			local taken = M.Storage.Committed(('contracts:%d:%s'):format(record.id, Phase.RESERVE))
			if taken.ok and taken.value == true then
				-- The escrow was taken and the gig never reached the board.
				settle(record, State.CANCELLED, nil, nil)
			else
				M.Storage.Forget(record.id)
				contracts[record.id] = nil
			end
		elseif record.state == State.ACCEPTED then
			-- Taken, but the objective never started: back on the board.
			move(record, State.POSTED, { mercCid = false }, nil, { reason = 'restart' })
		elseif record.state == State.SETTLING then
			finish(record)
		end
	end
	return true
end

--- One pass over every open gig.
local function sweep()
	if not loaded then return end
	local now, nowMs = wall(), OPX.Now()
	for _, id in ipairs(sortedIds()) do
		local contract = contracts[id]
		if contract ~= nil and not claims[id] then
			local state = contract.state
			local late = contract.deadlineAt <= now
			if state == State.POSTED and late then
				detached(id, function() settle(contract, State.EXPIRED, nil, nil) end)
			elseif (state == State.ACCEPTED or state == State.IN_PROGRESS) and late then
				detached(id, function()
					settle(contract, State.FAILED, { proof = { reason = 'timeout', at = now } }, nil)
				end)
			elseif state == State.PROOF and contract.validate == 'manual' and late then
				detached(id, function()
					if Access.MANUAL_TIMEOUT == 'pay' then
						settle(contract, State.PAID, nil, nil)
					elseif move(contract, State.DISPUTED, nil, nil, { reason = 'validate_timeout' }) then
						Open77.log.warn(('[contracts] gig %d is DISPUTED: nobody validated it in time; ' ..
							'/%s %d paid|failed'):format(id, tostring(Access.COMMANDS.RESOLVE), id))
						tellCitizen(contract.mercCid, 'contracts.disputed', { title = contract.title },
							'warning')
					end
				end)
			elseif state == State.SETTLING and nowMs - (retried[id] or 0) >= RETRY_MS then
				retried[id] = nowMs
				detached(id, function() finish(contract) end)
			elseif state == State.IN_PROGRESS then
				local handlers = types[contract.type]
				if handlers ~= nil and type(handlers.tick) == 'function' then
					local ok, failure = pcall(handlers.tick, contract, nowMs)
					if not ok then
						Open77.log.warn(('[contracts] %s tick raised: %s'):format(contract.type, safe(failure)))
					end
				end
			end
		end
	end
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Posts a gig from another module. Coroutine only (it writes).
-- spec { type, title, brief?, reward, funded = 'player'|'external', payer? (a
-- connection, for 'player'), poster? (a name), cutPct?, minCred?, deadlineS?,
-- objective, validate? }
local function apiPost(spec)
	if not loaded then return Result.Err('unavailable') end
	if type(spec) ~= 'table' then return Result.Err('bad_spec') end
	local normalized, why = Access.NormalizeSpec(spec, { cutLow = 0, cutHigh = 100,
		objective = objectiveOf })
	if normalized == nil then return Result.Err(why) end
	local who = { posterKind = M.Poster.EXT, posterName = Access.Text(spec.poster, 64) or 'ext',
		funded = M.Funded.EXTERNAL }
	if spec.funded == 'player' then
		local player = math.tointeger(tonumber(spec.payer))
		local data = player and dataOf(player) or nil
		if data == nil then return Result.Err('no_character') end
		who.funded, who.player, who.payerCid, who.posterCid = M.Funded.PLAYER, player,
			data.citizenId, data.citizenId
	end
	local ok, value = create(normalized, who)
	if not ok then return Result.Err(value) end
	return Result.Ok(value)
end

local function apiGet(id)
	local contract = contracts[math.tointeger(tonumber(id)) or -1]
	if contract == nil then return nil end
	local row = publicOf(contract)
	row.mercCid, row.posterCid, row.deadlineAt = contract.mercCid, contract.posterCid,
		contract.deadlineAt
	return row
end

local function apiList(filter)
	filter = type(filter) == 'table' and filter or {}
	local out = {}
	for _, id in ipairs(sortedIds()) do
		local contract = contracts[id]
		if (filter.state == nil or contract.state == filter.state)
			and (filter.type == nil or contract.type == filter.type)
			and (filter.mercCid == nil or contract.mercCid == filter.mercCid)
			and (filter.posterCid == nil or contract.posterCid == filter.posterCid) then
			out[#out + 1] = apiGet(id)
		end
	end
	return out
end

--- A proof another module measured (its own objective type, or `validate = 'ext'`).
local function apiReportProof(id, proof)
	id = math.tointeger(tonumber(id)) or -1
	local contract = contracts[id]
	if contract == nil or contract.state ~= State.IN_PROGRESS then return Result.Err('not_in_progress') end
	local ok, why = withClaim(id, function()
		return prove(contract, type(proof) == 'table' and proof or { kind = 'ext' }, nil)
	end)
	if not ok then return Result.Err(why) end
	return Result.Ok(contract.state)
end

local function apiRegister(name, handlers)
	if type(name) ~= 'string' or not name:match('^[%w_]+$') or #name > 32 then
		return Result.Err('bad_name')
	end
	if type(handlers) ~= 'table' then return Result.Err('bad_handlers') end
	if types[name] ~= nil and types[name].config then return Result.Err('type_taken') end
	types[name] = {
		validate = handlers.validate, describe = handlers.describe, waypoint = handlers.waypoint,
		canStart = handlers.canStart, start = handlers.start, stop = handlers.stop,
		tick = handlers.tick,
	}
	return Result.Ok(name)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Declares the tables and the tunables. Never yields.
-- @author dop42
function M.Init()
	contracts, claims, npcs, holding, posting, windows, fixerClock, retried = {}, {}, {}, {}, {},
		{}, {}, {}
	OPX.Schema.Add(M.Storage.SCHEMA)
	OPX.Tune.Declare{
		CONTRACT_FIXER_CUT = { value = Access.CUT_DEFAULT, type = 'integer', min = 0, max = 100,
			unit = '%', apply = 'live', label = 'Default fixer cut', group = 'Contracts', order = 1,
			description = 'The cut preselected on the posting form, inside each grade\'s bounds.' },
		CONTRACT_MINT_PER_HOUR = { value = Access.MINT_PER_HOUR, type = 'integer', min = 0,
			max = 10000000, apply = 'live', label = 'District fixers: new money per hour',
			group = 'Contracts', order = 2,
			description = 'The most the NPC fixers may pay out in new money in one hour.' },
		CONTRACT_SWEEP_MS = { value = Access.SWEEP_MS, type = 'integer', min = 250, max = 60000,
			unit = 'ms', apply = 'live', label = 'Gig sweep interval', group = 'Contracts', order = 3,
			description = 'How often deadlines, zones and unfinished settlements are looked at.' },
	}
end

--- Publishes the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('contracts', 1, {
		Post = apiPost,
		Cancel = function(id)
			id = math.tointeger(tonumber(id)) or -1
			local contract = contracts[id]
			if contract == nil or contract.state ~= State.POSTED then return Result.Err('not_posted') end
			local ok, why = withClaim(id, function() return settle(contract, State.CANCELLED, nil, nil) end)
			return ok and Result.Ok(id) or Result.Err(why)
		end,
		Get = apiGet,
		List = apiList,
		ReportProof = apiReportProof,
		Resolve = function(id, outcome)
			local ok, why = resolve(math.tointeger(tonumber(id)) or -1, outcome, 'api')
			return ok and Result.Ok(id) or Result.Err(why)
		end,
		RegisterObjectiveType = apiRegister,
		Cred = function(player) return credOf(player) end,
	})
end

-- The ACT verbs, each a function of (player, id).
local VERBS = {
	accept = accept,
	abandon = abandon,
	cancel = cancel,
	report = report,
	validate = function(player, id) return rule(player, id, true) end,
	reject = function(player, id) return rule(player, id, false) end,
	deliver = function(player) return deliver(player, nil) end,
	waypoint = function(player) sendActive(player) return true end,
}

--- Wires the requests, the commands, the NPCs and the sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Access.Problems()) do Open77.log.warn('[contracts] config: ' .. line) end

	RegisterNetEvent(M.Event.HELLO, function()
		local player = tonumber(source) or 0
		if player <= 0 or not allowed(player) then return end
		TriggerClientEvent(M.Event.NPCS, player, npcList())
		sendActive(player)
	end)

	RegisterNetEvent(M.Event.BOARD, function()
		local player = tonumber(source) or 0
		if player <= 0 or not allowed(player) then return end
		sendBoard(player)
	end)

	RegisterNetEvent(M.Event.FORM, function()
		local player = tonumber(source) or 0
		if player <= 0 or not allowed(player) then return end
		sendForm(player)
	end)

	RegisterNetEvent(M.Event.POST, function(form)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not allowed(player) then return refuse(player, 'too_fast') end
		if type(form) ~= 'table' then return refuse(player, 'bad_spec') end
		-- Plain fields only, copied: nothing a client nests reaches a validator.
		local copy = {}
		for _, key in ipairs({ 'type', 'target', 'title', 'brief', 'reward', 'cut', 'deadline', 'tier' }) do
			local value = form[key]
			if type(value) == 'string' or type(value) == 'number' then copy[key] = value end
		end
		CreateThread(function()
			local ok, why = postFromPlayer(player, copy)
			if not ok then refuse(player, why) end
		end)
	end)

	RegisterNetEvent(M.Event.ACT, function(payload)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not allowed(player) then return refuse(player, 'too_fast') end
		if type(payload) ~= 'table' then return end
		local verb = VERBS[payload.verb]
		local id = math.tointeger(tonumber(payload.id)) or -1
		if verb == nil then return refuse(player, 'bad_request') end
		CreateThread(function()
			local ok, why = verb(player, id)
			if not ok then refuse(player, why) end
		end)
	end)

	RegisterNetEvent(M.Event.DELIVER, function(payload)
		local player = tonumber(source) or 0
		if player <= 0 then return end
		if not allowed(player) then return refuse(player, 'too_fast') end
		local key = type(payload) == 'table' and payload.npc or nil
		if type(key) ~= 'string' or #key > 24 or not key:match('^%d+$') then
			return refuse(player, 'wrong_dropoff')
		end
		CreateThread(function()
			local ok, why = deliver(player, key)
			if not ok then refuse(player, why) end
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function()
		local player = tonumber(source) or 0
		windows[player] = nil
	end)

	local commands = Access.COMMANDS
	if type(commands.BOARD) == 'string' and commands.BOARD ~= '' then
		OPX.Command.Register(commands.BOARD, { help = 'contracts.help.board', cooldownMs = 500 },
			function(player)
				if player <= 0 then return end
				sendBoard(player)
			end)
	end
	if type(commands.POST) == 'string' and commands.POST ~= '' then
		OPX.Command.Register(commands.POST, { help = 'contracts.help.post', cooldownMs = 500 },
			function(player)
				if player <= 0 then return end
				sendForm(player)
			end)
	end
	if type(commands.RESOLVE) == 'string' and commands.RESOLVE ~= '' then
		OPX.Command.Register(commands.RESOLVE, { restricted = true, help = 'contracts.help.resolve',
			params = { { name = 'id', help = locale('contracts.help.id') },
				{ name = 'paid|failed', help = locale('contracts.help.outcome') } } },
			function(player, args, raw)
				local id = math.tointeger(tonumber(args[1])) or -1
				local outcome = args[2]
				CreateThread(function()
					local ok, why = resolve(id, outcome, ('staff:%s'):format(tostring(player)))
					OPX.CommandNotice(player, raw, ok and 'success' or 'error',
						locale(ok and 'contracts.staff.resolved' or 'contracts.staff.refused',
							{ id = id, code = tostring(why) }))
				end)
			end)
	end

	CreateThread(function()
		if OPX.BootError then
			Open77.log.error('[contracts] no database: the gig board is closed (' ..
				safe(OPX.BootError) .. ')')
		else
			loaded = reconcile()
			local count = 0
			for _ in pairs(contracts) do count = count + 1 end
			Open77.log.info(('[contracts] ready: %d open gig(s)'):format(count))
		end
		local placed, why = pcall(spawnNpcs)
		if not placed then Open77.log.error('[contracts] placing the NPCs raised: ' .. safe(why)) end
	end)

	sweepJob = OPX.Scheduler.Every('contracts:sweep', function()
		return OPX.Tune.Number('CONTRACT_SWEEP_MS', Access.SWEEP_MS)
	end, sweep)
	fixerJob = OPX.Scheduler.Every('contracts:fixers', 15000, function()
		CreateThread(generate)
	end)
end

--- Stops the passes and takes the NPCs down. Gigs stay in the database.
-- @author dop42
function M.Stop()
	if sweepJob ~= nil then OPX.Scheduler.Cancel(sweepJob) sweepJob = nil end
	if fixerJob ~= nil then OPX.Scheduler.Cancel(fixerJob) fixerJob = nil end
	removeNpcs()
end

-- For the tests and for staff tooling inside this VM.
M.Server = {
	Contracts = function() return contracts end,
	Sweep = sweep,
	Generate = generate,
	Post = postFromPlayer,
	Accept = accept,
	Abandon = abandon,
	Cancel = cancel,
	Deliver = deliver,
	Report = report,
	Rule = rule,
	Resolve = resolve,
	Board = boardFor,
	Reconcile = reconcile,
	Npcs = function() return npcs end,
	IsLoaded = function() return loaded end,
}
