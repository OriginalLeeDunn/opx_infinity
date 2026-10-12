--- Server half: the bills, the prompt, the settlement and the tab.
-- @author dop42
--
-- EVERY DECISION IS HERE. A client asks to bill somebody, answers a prompt,
-- pays a bill on its tab or withdraws one it raised; the server re-reads the
-- character (job, grade, duty from the roster, never from the payload), the
-- position (the host's), the bill itself, decides, writes, and answers with a
-- locale key.
--
-- THE MONEY PATTERN, one rule for every eddie that moves:
--
--   the bill is written `settling` (compare-and-swap on state + revision)
--   -> each movement reserves `invoices:<id>:<phase>` in the ledger (a primary
--      key: a replay finds the first receipt and moves nothing)
--   -> the money moves -> the operation is committed (or cancelled: nothing moved)
--   -> the bill is written `paid`
--
-- The charge comes first and alone decides: refused (not enough eddies), the
-- bill goes back to the tab and nothing else happens. Taken, the cut and the
-- company share follow; a payout that fails leaves the bill `settling` and the
-- sweep tries it again with the same operation ids, so it can be late but never
-- double. A row a crash left `reserved` is marked `orphaned` at boot and audited
-- for staff: a charge nobody can vouch for makes the bill `disputed` (no payout
-- from money that may never have been taken); a payout nobody can vouch for is
-- not made again.
--
-- WHERE THE RACE IS WON. The VM is single-threaded and coroutines interleave
-- only at a yield, so `claims[id]` (read and written with nothing between) is
-- atomic: a second PAY on the same bill in the same tick is refused before any
-- database call. One prompt per customer at a time (`asking[citizenId]`) is
-- reserved the same way before the INSERT yields.
--
-- PEOPLE ARE FROZEN AT ISSUE. The issuer's and the customer's citizen ids are
-- read before the first yield and written on the bill; the cut is paid to THAT
-- issuer (`AddMoneyOffline`: logged off is still paid) and only THAT customer,
-- online, can pay.

local M = OPX.Modules.Get('invoices')
local Model, State, Phase, Event = M.Model, M.State, M.Phase, M.Event
local Result = OPX.Result

local settings
-- Open bills by id (asked, unpaid, settling). A final one leaves this table.
local invoices = {}
-- Bill ids with an action in flight.
local claims = {}
-- Customer citizen id -> the id of the bill they are being asked about (or
-- `true` while it is being filed).
local asking = {}
-- Issuer citizen id -> the ms of their last bill.
local lastIssue = {}
-- Per-player request windows.
local windows = {}
-- Settling bill id -> the ms of the last retry.
local retried = {}
local loaded = false
local sweepJob = nil

local REQUESTS, WINDOW_MS = 8, 2000
local RETRY_MS = 30000
local SWEEP_MS = 1000

local function config()
	if settings == nil then settings = Model.Settings(OPX.Config.MODULES.invoices) end
	return settings
end

local function safe(value) return OPX.Audit.Safe(tostring(value), 96) end

-- ── the world and the people ────────────────────────────────────────────────

--- Wall-clock seconds; process seconds where the host has none (the tests).
local function wall()
	local time = Open77 and Open77.time
	if type(time) == 'table' and type(time.unix) == 'function' then
		local ok, now = pcall(time.unix)
		if ok and type(now) == 'number' and now == now then return math.floor(now) end
	end
	return OPX.Now() // 1000
end

local function characterApi() return OPX.Api.Get('character') end

local function playerId(value)
	local id = math.tointeger(tonumber(value))
	if id == nil or id < 1 or id > 0x7fffffff then return nil end
	return id
end

--- The loaded character data at a connection, or nil.
local function dataOf(player)
	local api = characterApi()
	if player == nil or api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local ok, value = pcall(api.GetPlayer, player)
	if not ok or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value.PlayerData
end

local function citizenOf(player)
	local data = dataOf(player)
	return data and type(data.citizenId) == 'string' and data.citizenId or nil
end

--- The connection playing a citizen id right now, or nil.
local function sourceOf(citizenId)
	if citizenId == nil then return nil end
	local api = characterApi()
	if api == nil or type(api.GetPlayerByCitizenId) ~= 'function' then return nil end
	local ok, value = pcall(api.GetPlayerByCitizenId, citizenId)
	if not ok or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return playerId(value.PlayerData.source)
end

local function nameOf(data)
	local info = type(data) == 'table' and type(data.charInfo) == 'table' and data.charInfo or {}
	local name = OPX.String.Trim(('%s %s'):format(tostring(info.firstName or ''), tostring(info.lastName or '')))
	name = OPX.Text.Clean(name, 64) or ''
	return name ~= '' and name or tostring(data and data.citizenId or '?')
end

local function positionOf(player)
	if playerId(player) == nil or type(Open77.players) ~= 'table'
		or type(Open77.players.position) ~= 'function' then
		return nil
	end
	local ok, at = pcall(Open77.players.position, player)
	if not ok or type(at) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(at.bucket) or 0) }
end

local function within(a, b, reach)
	if a == nil or b == nil or a.bucket ~= b.bucket then return false end
	local limit = reach + (OPX.Math.Finite(OPX.Config.SHARED.REACH_SLACK) or 1.0)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz <= limit * limit
end

-- ── telling people ──────────────────────────────────────────────────────────

local function money(amount, moneyType) return OPX.Locale.Money(amount, moneyType or config().moneyType) end

local function tell(player, key, params, kind)
	if playerId(player) == nil then return end
	OPX.NotifyLocale(player, key, params, kind or 'info')
end

local function tellCitizen(citizenId, key, params, kind) tell(sourceOf(citizenId), key, params, kind) end

local function refuse(player, code)
	local key = 'invoices.refused.' .. tostring(code)
	if not OPX.Locale.Exists(key) then key = 'invoices.refused.generic' end
	tell(player, key, nil, 'error')
end

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

--- What the bus carries: ids, amounts and the account, never a live record.
local function busPayload(inv)
	return {
		id = inv.id, amount = inv.amount, source = inv.source,
		account = inv.account and { kind = inv.account.kind, key = inv.account.key } or nil,
		issuerCid = inv.issuerCid, targetCid = inv.targetCid,
	}
end

local function publish(event, inv)
	OPX.Publish(event, sourceOf(inv.targetCid), busPayload(inv))
end

local function audit(inv, event, severity, message, data)
	OPX.Audit.Log({
		event = 'invoices.' .. event, severity = severity or 'info',
		message = ('invoice %d %s'):format(inv.id, message or ''),
		citizenId = inv.targetCid,
		data = data or { invoice = inv.id, amount = inv.amount, issuer = inv.issuerCid,
			source = inv.source },
	})
end

-- ── the state machine ───────────────────────────────────────────────────────

local function closePrompt(inv)
	if asking[inv.targetCid] == inv.id then asking[inv.targetCid] = nil end
	local target = sourceOf(inv.targetCid)
	if target ~= nil then TriggerClientEvent(Event.ASK_CLOSED, target, { id = inv.id }) end
end

--- Moves a bill to a new state through the compare-and-swap.
-- @return boolean, string|nil
local function move(inv, to, patch)
	local from, rev = inv.state, inv.rev
	local nextRecord = {}
	for key, value in pairs(inv) do nextRecord[key] = value end
	for key, value in pairs(patch or {}) do nextRecord[key] = value end
	nextRecord.state, nextRecord.rev = to, rev + 1
	local moved = M.Storage.Move(nextRecord, from, rev)
	if not moved.ok then
		Open77.log.warn(('[invoices] invoice %d not moved %s -> %s: %s'):format(inv.id, from, to,
			safe(moved.detail or moved.error)))
		return false, 'storage'
	end
	if moved.value ~= true then return false, 'stale' end
	for key, value in pairs(patch or {}) do inv[key] = value end
	inv.state, inv.rev = to, rev + 1
	if from == State.ASKED then closePrompt(inv) end
	if not Model.IsOpen(to) then
		invoices[inv.id] = nil
		retried[inv.id] = nil
	end
	return true
end

--- Runs `fn` with the bill claimed; a second caller is refused `busy`.
local function withClaim(id, fn)
	if claims[id] then return false, 'busy' end
	claims[id] = true
	local ran, ok, why = pcall(fn)
	claims[id] = nil
	if not ran then
		Open77.log.error(('[invoices] invoice %s raised: %s'):format(tostring(id), safe(ok)))
		return false, 'error'
	end
	return ok, why
end

--- Runs one money operation under its ledger row. `run()` answers `ok, why`.
local function operate(inv, phase, citizenId, amount, run)
	amount = math.tointeger(amount) or 0
	if amount <= 0 then return true end
	local op = { id = ('invoices:%d:%s'):format(inv.id, phase), invoiceId = inv.id, phase = phase,
		citizenId = citizenId, amount = amount }
	local reserved = M.Storage.Reserve(op)
	if not reserved.ok then return false, 'storage' end
	if not reserved.value.fresh then
		local state = reserved.value.state
		if state == 'committed' then return true end
		if state == 'orphaned' then return false, 'orphaned' end
		if state ~= 'cancelled' then return false, 'in_flight' end
		local rearmed = M.Storage.Rearm(op.id)
		if not rearmed.ok or rearmed.value ~= true then return false, 'in_flight' end
	end
	local called, ok, why = pcall(run)
	if not called then ok, why = false, ok end
	local settled = M.Storage.Settle(op.id, ok and 'committed' or 'cancelled')
	if not settled.ok then
		Open77.log.error(('[invoices] %s moved=%s but the ledger was not updated: %s')
			:format(op.id, tostring(ok), safe(settled.detail or settled.error)))
	end
	OPX.Audit.Log({
		event = 'invoices.' .. phase,
		severity = ok and 'info' or 'warn',
		message = ('%s %d'):format(op.id, amount),
		citizenId = citizenId,
		data = { invoice = inv.id, phase = phase, amount = amount, ok = ok == true,
			error = not ok and safe(why) or nil },
	})
	return ok == true, why
end

--- Pays a character, online or not.
local function payCitizen(citizenId, amount, reason)
	local api = characterApi()
	if api == nil or type(api.AddMoneyOffline) ~= 'function' then return false, 'no_character' end
	local answer = api.AddMoneyOffline(citizenId, config().moneyType, amount, reason)
	if type(answer) == 'table' and answer.ok == true then return true end
	return false, type(answer) == 'table' and answer.error or 'not_paid'
end

--- The company share: into the account when `accounts` runs and takes it,
--- else to the issuer. Inside ONE ledger row whichever way it went, so a
--- replay can never pay both.
local function payRest(inv, amount, opId)
	local accounts = inv.account and OPX.Api.Get('accounts') or nil
	if accounts ~= nil and type(accounts.Deposit) == 'function' then
		local called, answer = pcall(accounts.Deposit, inv.account.kind, inv.account.key, amount,
			('invoice:%d'):format(inv.id), opId)
		if called and type(answer) == 'table' and answer.ok == true then
			inv.restTo = 'account'
			return true
		end
		OPX.Audit.Log({ event = 'invoices.depositFallback', severity = 'warn',
			message = ('invoice %d: %s/%s refused the deposit, the issuer is paid instead')
				:format(inv.id, inv.account.kind, inv.account.key),
			data = { invoice = inv.id, error = safe(called and type(answer) == 'table' and answer.error or answer) } })
	end
	inv.restTo = 'issuer'
	return payCitizen(inv.issuerCid, amount, ('invoice:%d'):format(inv.id))
end

--- Everything after a committed charge: the cut, the rest, `paid`.
local function finish(inv)
	local cut, rest = Model.Split(inv.amount, inv.cutPct, inv.account ~= nil)
	local okCut, why = operate(inv, Phase.CUT, inv.issuerCid, cut, function()
		return payCitizen(inv.issuerCid, cut, ('invoice:%d:cut'):format(inv.id))
	end)
	if not okCut and why ~= 'orphaned' then return false, 'payout_pending' end
	local restOp = ('invoices:%d:%s'):format(inv.id, Phase.REST)
	local okRest
	okRest, why = operate(inv, Phase.REST, inv.account == nil and inv.issuerCid or nil, rest, function()
		return payRest(inv, rest, restOp)
	end)
	if not okRest and why ~= 'orphaned' then return false, 'payout_pending' end
	local moved
	moved, why = move(inv, State.PAID, { paidWith = inv.paidWith })
	if not moved then return false, why end
	audit(inv, 'paid', 'info', ('paid %d (cut %d, rest to %s)'):format(inv.amount, cut,
		tostring(inv.restTo or 'nobody')))
	publish(Event.ON_PAID, inv)
	-- What the employee pockets: the cut, plus the rest when no company took it.
	local earned = cut + ((inv.restTo == 'issuer' or inv.account == nil) and rest or 0)
	tellCitizen(inv.issuerCid, 'invoices.issuer.paid', { amount = money(inv.amount), name = inv.targetName,
		cut = money(earned) }, 'success')
	return true
end

--- Charges the customer at `player` for a bill on hold (asked or unpaid).
-- Claim held by the caller.
local function charge(inv, player)
	local from = inv.state
	if from ~= State.ASKED and from ~= State.UNPAID then return false, 'no_such_bill' end
	local moved, why = move(inv, State.SETTLING)
	if not moved then return false, why end
	local cfg = config()
	local used
	local ok
	ok, why = operate(inv, Phase.CHARGE, inv.targetCid, inv.amount, function()
		if citizenOf(player) ~= inv.targetCid then return false, 'character_changed' end
		local api = characterApi()
		local reason = ('invoice:%d'):format(inv.id)
		local took, code = api.RemoveMoney(player, cfg.moneyType, inv.amount, reason)
		if took then used = cfg.moneyType return true end
		if code == 'money.insufficient' and cfg.fallbackType ~= nil then
			took, code = api.RemoveMoney(player, cfg.fallbackType, inv.amount, reason)
			if took then used = cfg.fallbackType return true end
		end
		return false, code
	end)
	if not ok then
		if why == 'orphaned' then
			move(inv, State.DISPUTED)
			audit(inv, 'disputed', 'error', 'the charge cannot be vouched for')
			return false, 'disputed'
		end
		-- Nothing moved: back on the tab, with its lapse kept or started.
		local expires = inv.expiresAt
		if from == State.ASKED then expires = cfg.unpaidTtlS > 0 and wall() + cfg.unpaidTtlS or 0 end
		move(inv, State.UNPAID, { expiresAt = expires })
		if why == 'money.insufficient' then return false, 'not_enough_money' end
		return false, 'charge_failed'
	end
	inv.paidWith = used
	-- The customer HAS paid from here on, whatever the payouts do: a payout that
	-- fails is the sweep's to finish, never the customer's to pay again.
	tellCitizen(inv.targetCid, 'invoices.target.paid', { amount = money(inv.amount, used),
		company = inv.company or inv.issuerName }, 'success')
	local finished, failure = finish(inv)
	if not finished and failure == 'payout_pending' then return true end
	return finished, failure
end

--- Picks a `settling` bill up again: after a restart, or a payout that failed.
-- Claim held by the caller.
local function resume(inv)
	if inv.state ~= State.SETTLING then return false, 'no_such_bill' end
	local read = M.Storage.OpState(('invoices:%d:%s'):format(inv.id, Phase.CHARGE))
	if not read.ok then return false, 'storage' end
	if read.value == 'committed' then return finish(inv) end
	if read.value == 'orphaned' or read.value == 'reserved' then
		move(inv, State.DISPUTED)
		audit(inv, 'disputed', 'error', 'the charge cannot be vouched for')
		return false, 'disputed'
	end
	return move(inv, State.UNPAID)
end

--- Ends a bill on hold without money: expired, refused or cancelled.
local function close(inv, to, event, issuerKey, targetKey)
	local moved, why = move(inv, to)
	if not moved then return false, why end
	audit(inv, to, 'info', to)
	publish(event, inv)
	local params = { amount = money(inv.amount), name = inv.targetName,
		company = inv.company or inv.issuerName, id = inv.id }
	if issuerKey then tellCitizen(inv.issuerCid, issuerKey, params, 'warning') end
	if targetKey then tellCitizen(inv.targetCid, targetKey, params, 'info') end
	return true
end

local function unpaidCount(citizenId)
	local count = 0
	for _, inv in pairs(invoices) do
		if inv.targetCid == citizenId and inv.state == State.UNPAID then count = count + 1 end
	end
	return count
end

-- ── issuing ─────────────────────────────────────────────────────────────────

local function askView(inv)
	return { id = inv.id, company = inv.company, issuer = inv.issuerName, amount = inv.amount,
		reason = inv.reason, moneyType = config().moneyType, fallbackType = config().fallbackType,
		ttlS = config().answerTtlS }
end

--- Files a bill and asks the customer. Yields (the INSERT): call on a thread.
-- `spec` is already a plain copy: { issuer, target, amount, reason, account?,
-- cutPct?, source?, company?, ceiling? }.
-- @return Result { id }
local function issue(spec)
	local cfg = config()
	local issuer, target = playerId(spec.issuer), playerId(spec.target)
	if issuer == nil or target == nil then return Result.Err('bad_player') end
	if issuer == target then return Result.Err('self') end
	local idata, tdata = dataOf(issuer), dataOf(target)
	if idata == nil then return Result.Err('no_character') end
	if tdata == nil then return Result.Err('no_target') end
	local icid, tcid = idata.citizenId, tdata.citizenId
	if type(icid) ~= 'string' or type(tcid) ~= 'string' then return Result.Err('no_character') end
	if icid == tcid then return Result.Err('self') end
	local amount, why = Model.Amount(spec.amount, math.min(cfg.maxAmount, spec.ceiling or cfg.maxAmount))
	if amount == nil then return Result.Err(why) end
	local reason = Model.Reason(spec.reason, cfg.reasonMax)
	if reason == nil then return Result.Err('bad_reason') end
	local account = nil
	if spec.account ~= nil then
		account = Model.Account(spec.account)
		if account == nil then return Result.Err('bad_account') end
	end
	local cut = Model.Cut(spec.cutPct, cfg.defaultCut)
	if cut == nil then return Result.Err('bad_cut') end
	local source = 'invoice'
	if spec.source ~= nil then
		source = Model.Source(spec.source)
		if source == nil then return Result.Err('bad_source') end
	end
	if not loaded then return Result.Err('unavailable') end
	if asking[tcid] ~= nil then return Result.Err('target_busy') end
	if cfg.maxUnpaid > 0 and unpaidCount(tcid) >= cfg.maxUnpaid then return Result.Err('too_many_unpaid') end

	asking[tcid] = true
	local record = {
		state = State.ASKED, rev = 0, issuerCid = icid, issuerName = nameOf(idata), targetCid = tcid,
		targetName = nameOf(tdata),
		company = type(spec.company) == 'string' and OPX.Text.Clean(spec.company, 64) or nil,
		amount = amount, reason = reason, account = account, cutPct = account and cut or 0,
		source = source, issuedAt = wall(), expiresAt = 0,
	}
	local inserted = M.Storage.Insert(record)
	if not inserted.ok then
		asking[tcid] = nil
		Open77.log.warn('[invoices] a bill was not filed: ' .. safe(inserted.detail or inserted.error))
		return Result.Err('storage')
	end
	record.id = inserted.value
	invoices[record.id] = record
	asking[tcid] = record.id
	record.askDeadlineMs = OPX.Now() + cfg.answerTtlS * 1000
	-- The customer may have left during the INSERT: then nobody can answer.
	if citizenOf(target) ~= tcid then
		withClaim(record.id, function() return move(record, State.EXPIRED) end)
		return Result.Err('no_target')
	end
	TriggerClientEvent(Event.ASK, target, askView(record))
	audit(record, 'issued', 'info', ('issued %d by %s to %s'):format(amount, icid, tcid),
		{ invoice = record.id, amount = amount, issuer = icid, source = source,
			account = account and (account.kind .. ':' .. account.key) or nil })
	OPX.Publish(Event.ON_ISSUED, target, busPayload(record))
	return Result.Ok({ id = record.id })
end

--- A bill raised from the eye or `/opx.bill`: the job decides the rest.
local function playerIssue(player, rawTarget, rawAmount, rawReason)
	local cfg = config()
	local data = dataOf(player)
	if data == nil then return false, 'no_character' end
	local entry, why = Model.Biller(cfg, data.job, data.jobs, OPX.Now())
	if entry == nil then return false, why end
	local target = playerId(rawTarget)
	if target == nil or target == player then return false, target == player and 'self' or 'no_target' end
	if dataOf(target) == nil then return false, 'no_target' end
	if not within(positionOf(player), positionOf(target), cfg.reach) then return false, 'too_far' end
	local cid = data.citizenId
	local now = OPX.Now()
	if lastIssue[cid] ~= nil and now - lastIssue[cid] < cfg.cooldownMs then return false, 'too_fast' end
	local issued = issue({ issuer = player, target = target, amount = rawAmount, reason = rawReason,
		account = entry.account, cutPct = entry.cutPct, source = entry.source, company = entry.label,
		ceiling = entry.maxAmount })
	if not issued.ok then return false, issued.error end
	lastIssue[cid] = OPX.Now()
	tell(player, 'invoices.issuer.sent', { amount = money(invoices[issued.value.id]
		and invoices[issued.value.id].amount or 0), name = nameOf(dataOf(target)) }, 'success')
	return true
end

-- ── answering, paying, withdrawing ──────────────────────────────────────────

local function ownBill(player, id, states)
	local inv = invoices[id]
	if inv == nil or not states[inv.state] then return nil end
	if citizenOf(player) ~= inv.targetCid then return nil end
	return inv
end

local ASKED_ONLY = { [State.ASKED] = true }
local PAYABLE = { [State.ASKED] = true, [State.UNPAID] = true }

--- The customer's answer to a prompt.
local function respond(player, id, choice)
	local inv = ownBill(player, id, ASKED_ONLY)
	if inv == nil then return false, 'no_such_bill' end
	if choice == 'refuse' then
		return withClaim(id, function()
			return close(inv, State.REFUSED, Event.ON_REFUSED, 'invoices.issuer.refused', 'invoices.target.refused')
		end)
	elseif choice == 'later' then
		local cfg = config()
		if cfg.maxUnpaid <= 0 or unpaidCount(inv.targetCid) >= cfg.maxUnpaid then return false, 'too_many_unpaid' end
		return withClaim(id, function()
			local moved, why = move(inv, State.UNPAID,
				{ expiresAt = cfg.unpaidTtlS > 0 and wall() + cfg.unpaidTtlS or 0 })
			if not moved then return false, why end
			audit(inv, 'unpaid', 'info', 'put on the tab')
			tell(player, 'invoices.target.filed', { amount = money(inv.amount) })
			tellCitizen(inv.issuerCid, 'invoices.issuer.filed', { amount = money(inv.amount), name = inv.targetName })
			return true
		end)
	elseif choice == 'pay' then
		return withClaim(id, function()
			local ok, why = charge(inv, player)
			if not ok and why == 'not_enough_money' and inv.state == State.UNPAID then
				tellCitizen(inv.issuerCid, 'invoices.issuer.filed', { amount = money(inv.amount), name = inv.targetName })
			end
			return ok, why
		end)
	end
	return false, 'bad_request'
end

--- Pays a bill on the tab (or a prompt still open, from the list).
local function payBill(player, id)
	local inv = ownBill(player, id, PAYABLE)
	if inv == nil then return false, 'no_such_bill' end
	return withClaim(id, function() return charge(inv, player) end)
end

--- Withdraws a bill on hold. `byCid` nil is the contract / staff.
local function cancel(id, byCid)
	local inv = invoices[id]
	if inv == nil or not PAYABLE[inv.state] then return false, 'no_such_bill' end
	if byCid ~= nil and inv.issuerCid ~= byCid then return false, 'not_yours' end
	return withClaim(id, function()
		return close(inv, State.CANCELLED, Event.ON_CANCELLED, nil, 'invoices.target.cancelled')
	end)
end

local function expire(inv)
	return withClaim(inv.id, function()
		return close(inv, State.EXPIRED, Event.ON_EXPIRED, 'invoices.issuer.expired', 'invoices.target.expired')
	end)
end

-- ── reading ─────────────────────────────────────────────────────────────────

local function row(inv)
	return { id = inv.id, state = inv.state, amount = inv.amount, reason = inv.reason,
		company = inv.company, issuer = inv.issuerName, target = inv.targetName, source = inv.source,
		account = inv.account and { kind = inv.account.kind, key = inv.account.key } or nil,
		expiresAt = inv.expiresAt }
end

local function byId(a, b) return a.id < b.id end

--- The bills a citizen owes (asked or unpaid), oldest first.
local function owedBy(citizenId)
	local out = {}
	for _, inv in pairs(invoices) do
		if inv.targetCid == citizenId and PAYABLE[inv.state] then out[#out + 1] = row(inv) end
	end
	table.sort(out, byId)
	return out
end

local function issuedBy(citizenId)
	local out = {}
	for _, inv in pairs(invoices) do
		if inv.issuerCid == citizenId and PAYABLE[inv.state] then out[#out + 1] = row(inv) end
	end
	table.sort(out, byId)
	return out
end

local function sendList(player)
	local cid = citizenOf(player)
	if cid == nil then return refuse(player, 'no_character') end
	TriggerClientEvent(Event.SHOW_LIST, player, { owed = owedBy(cid), issued = issuedBy(cid),
		moneyType = config().moneyType })
end

-- ── the sweep and the boot ──────────────────────────────────────────────────

local function sweep()
	local now, seconds = OPX.Now(), wall()
	for id, inv in pairs(invoices) do
		if not claims[id] then
			if inv.state == State.ASKED and inv.askDeadlineMs ~= nil and now >= inv.askDeadlineMs then
				inv.askDeadlineMs = nil
				CreateThread(function() expire(inv) end)
			elseif inv.state == State.UNPAID and inv.expiresAt > 0 and seconds >= inv.expiresAt then
				inv.expiresAt = 0
				CreateThread(function() expire(inv) end)
			elseif inv.state == State.SETTLING and now - (retried[id] or -RETRY_MS) >= RETRY_MS then
				retried[id] = now
				CreateThread(function() withClaim(id, function() return resume(inv) end) end)
			end
		end
	end
end

--- Loads the open bills, marks what a dead process left half-done, and
--- finishes or ends every bill a restart interrupted.
local function reconcile()
	local pending = M.Storage.Pending()
	if pending.ok then
		for _, op in ipairs(pending.value) do
			M.Storage.Settle(op.id, 'orphaned')
			OPX.Audit.Log({ event = 'invoices.orphaned', severity = 'error',
				message = ('%s %d left reserved by a crash: check it by hand'):format(op.id, op.amount),
				citizenId = op.citizenId, data = { invoice = op.invoiceId, phase = op.phase, amount = op.amount } })
		end
	end
	local open = M.Storage.LoadOpen()
	if not open.ok then
		Open77.log.error('[invoices] the open bills could not be read: ' .. safe(open.detail or open.error))
		return false
	end
	for _, record in ipairs(open.value) do invoices[record.id] = record end
	for _, record in ipairs(open.value) do
		if record.state == State.ASKED then
			-- The prompt died with the process: nobody can answer it now.
			withClaim(record.id, function() return close(record, State.EXPIRED, Event.ON_EXPIRED) end)
		elseif record.state == State.SETTLING then
			withClaim(record.id, function() return resume(record) end)
		end
	end
	return true
end

-- ── the contract ────────────────────────────────────────────────────────────

local SPEC_FIELDS = { 'issuer', 'target', 'amount', 'reason', 'cutPct', 'source', 'company' }

--- `Issue{ issuer, target, amount, reason, account?, cutPct?, source? }`.
-- Yields: call it on a thread. No reach check and no job gate -- the calling
-- module decided who may bill; the bounds, the consent and the money are this
-- module's.
-- @author dop42
-- @param spec table
-- @return Result { id }
local function apiIssue(spec)
	if type(spec) ~= 'table' then return Result.Err('bad_spec') end
	local copy = {}
	for _, key in ipairs(SPEC_FIELDS) do
		local value = spec[key]
		if type(value) == 'string' or type(value) == 'number' then copy[key] = value end
	end
	if spec.account ~= nil then copy.account = Model.Account(spec.account) or false end
	if copy.account == false then return Result.Err('bad_account') end
	return issue(copy)
end

--- What a player owes: `Result{ rows }`, oldest first.
-- @author dop42
local function apiPending(player)
	local cid = citizenOf(playerId(player))
	if cid == nil then return Result.Err('no_character') end
	return Result.Ok({ rows = owedBy(cid) })
end

--- One open bill, or nil.
-- @author dop42
local function apiGet(id)
	local inv = invoices[math.tointeger(tonumber(id)) or -1]
	return Result.Ok(inv and row(inv) or nil)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Declares the tables. Never yields.
-- @author dop42
function M.Init()
	settings = nil
	invoices, claims, asking, lastIssue, windows, retried = {}, {}, {}, {}, {}, {}
	loaded = false
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('invoices', 1, {
		Issue = apiIssue,
		Pending = apiPending,
		Get = apiGet,
		Cancel = function(id)
			id = math.tointeger(tonumber(id)) or -1
			local ok, why = cancel(id, nil)
			return ok and Result.Ok({ id = id }) or Result.Err(why or 'error')
		end,
	})
end

local CHOICES = { pay = true, later = true, refuse = true }

--- Wires the requests, the commands and the sweep.
-- @author dop42
function M.Start()
	local characterConfig = OPX.Config.MODULES.character
	for _, line in ipairs(Model.Problems(OPX.Config.MODULES.invoices,
		type(characterConfig) == 'table' and characterConfig.JOBS or nil)) do
		Open77.log.warn('[invoices] config: ' .. line)
	end
	if OPX.Api.Get('accounts') == nil then
		Open77.log.info('[invoices] no accounts contract: every bill is paid in full to the employee who raised it')
	end

	local function wire(name, handler)
		RegisterNetEvent(name, function(payload)
			local player = playerId(source)
			if player == nil then return end
			if not allowed(player) then return refuse(player, 'too_fast') end
			if type(payload) ~= 'table' then return end
			CreateThread(function()
				local ok, why = handler(player, payload)
				if not ok and why ~= nil then refuse(player, why) end
			end)
		end)
	end

	wire(Event.ISSUE, function(player, payload)
		local amount, reason = payload.amount, payload.reason
		if type(amount) ~= 'number' and type(amount) ~= 'string' then return false, 'bad_amount' end
		if type(reason) ~= 'string' then return false, 'bad_reason' end
		return playerIssue(player, payload.target, amount, reason)
	end)
	-- One door for everything done to a bill that exists, by verb.
	local VERBS = {
		respond = function(player, id, payload)
			if not CHOICES[payload.choice] then return false, 'bad_request' end
			return respond(player, id, payload.choice)
		end,
		pay = function(player, id) return payBill(player, id) end,
		cancel = function(player, id)
			local cid = citizenOf(player)
			if cid == nil then return false, 'no_such_bill' end
			local ok, why = cancel(id, cid)
			if ok then tell(player, 'invoices.issuer.cancelled', { id = id }, 'success') end
			return ok, why
		end,
	}
	wire(Event.ACT, function(player, payload)
		if payload.verb == 'list' then
			sendList(player)
			return true
		end
		local verb = type(payload.verb) == 'string' and VERBS[payload.verb] or nil
		if verb == nil then return false, 'bad_request' end
		local id = math.tointeger(tonumber(payload.id))
		if id == nil then return false, 'no_such_bill' end
		return verb(player, id, payload)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function()
		local player = playerId(source)
		if player ~= nil then windows[player] = nil end
	end)

	local cfg = config()
	if cfg.commands.bill ~= nil then
		OPX.Command.Register(cfg.commands.bill, { help = 'invoices.help.bill', cooldownMs = 1000,
			params = { { name = 'id', help = locale('invoices.help.id') },
				{ name = 'amount', help = locale('invoices.help.amount') },
				{ name = 'reason', help = locale('invoices.help.reason') } } },
			function(player, args)
				player = playerId(player)
				if player == nil then return end
				local target, amount, reason = args[1], args[2], OPX.Text.Rest(args, 3)
				CreateThread(function()
					local ok, why = playerIssue(player, target, amount, reason)
					if not ok then refuse(player, why) end
				end)
			end)
	end
	if cfg.commands.bills ~= nil then
		OPX.Command.Register(cfg.commands.bills, { help = 'invoices.help.bills', cooldownMs = 500 },
			function(player)
				player = playerId(player)
				if player == nil then return end
				sendList(player)
			end)
	end

	CreateThread(function()
		if OPX.BootError then
			Open77.log.error('[invoices] no database: billing is closed (' .. safe(OPX.BootError) .. ')')
			return
		end
		loaded = reconcile()
		local count = 0
		for _ in pairs(invoices) do count = count + 1 end
		Open77.log.info(('[invoices] ready: %d open bill(s)'):format(count))
	end)

	sweepJob = OPX.Scheduler.Every('invoices:sweep', SWEEP_MS, sweep)
end

--- Stops the sweep. Bills stay in the database; an open prompt expires at
--- the next boot.
-- @author dop42
function M.Stop()
	if sweepJob ~= nil then OPX.Scheduler.Cancel(sweepJob) sweepJob = nil end
end

-- For the tests and for staff tooling inside this VM.
M.Server = {
	Invoices = function() return invoices end,
	Issue = issue,
	PlayerIssue = playerIssue,
	Respond = respond,
	Pay = payBill,
	Cancel = cancel,
	Sweep = sweep,
	Reconcile = reconcile,
	Owed = owedBy,
	IsLoaded = function() return loaded end,
	Reset = function() invoices, claims, asking, lastIssue, retried = {}, {}, {}, {}, {} end,
}
