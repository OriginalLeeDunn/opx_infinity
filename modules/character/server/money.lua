--- Durable wallet changes and trusted participants sharing their transaction.
-- @author dop42
-- Money is written before success is returned; character autosaves never write
-- it. A stable operation id makes a retry a receipt lookup, not another payment.
-- Unknown database replies retain the writer/participant locks while a recovery
-- coroutine retries the same operation. They are never treated as a refund.
local M = OPX.Modules.Get('character')
local Result = OPX.Result
local MAXIMUM = 9007199254740991
M.Money = { Pending = {}, Active = {} }
local Money = M.Money

local function loaded(player)
	return player and not player.Offline and M.Players[player.PlayerData.source] == player
		and OPX.UserIdOf(player.PlayerData.source) == player.PlayerData.userId
end

local function fail(code, detail) return Result.Err(code, detail) end

local function callNotice(fn, ...)
	if not fn then return end
	local ok = pcall(fn, ...)
	if not ok then Open77.log.error('[character] committed money operation notification failed') end
end

--- Validates, persists and reconciles one wallet change. Coroutine only.
-- prepare(op) may install release/apply/publish callbacks on op and return a
-- participant builder. apply installs an idempotent post-state without yielding;
-- publish is optional and runs after both participant guards have been released.
function Money.Change(target, moneyType, amount, action, reason, opId, prepare, offlineAllowed)
	local player = type(target) == 'table' and target or nil
	local citizenId = player and player.PlayerData.citizenId or target
	if player and player.Offline then return fail('money.offline') end
	if not player and not offlineAllowed then return fail('error.notLoggedIn') end
	if action ~= 'add' and action ~= 'remove' and action ~= 'set' and action ~= 'touch' then return fail('money.badAmount') end
	if not M.IsMoneyType(moneyType) then return fail('money.badType') end
	local value = tonumber(amount)
	if not OPX.Math.IsFinite(value) then return fail('money.badAmount') end
	value = math.tointeger(value) or math.floor(value + 0.5)
	if action ~= 'set' and action ~= 'touch' and (value <= 0 or value > MAXIMUM) then
		OPX.Audit.Security('money.badAmount', 'Invalid money amount',
			{ citizenId = citizenId, moneyType = moneyType }, player and player.PlayerData.source)
		return fail('money.badAmount')
	end
	if action == 'touch' and value ~= 0 then return fail('money.badAmount') end
	if value > MAXIMUM or value < -MAXIMUM then return fail('money.tooLarge') end
	local allowNegative = OPX.Config.SHARED.MONEY.ALLOW_NEGATIVE[moneyType] == true
	if action == 'set' and value < 0 and not allowNegative then return fail('money.negative') end
	if opId ~= nil and (type(opId) ~= 'string' or #opId > 128 or not opId:match('^[%w_:%-%.]+$')) then
		return fail('money.opIdConflict')
	end
	if Money.Pending[citizenId] then return fail('money.pending', Money.Pending[citizenId]) end
	if player and not loaded(player) then return fail('error.notLoggedIn') end
	local op = { id = opId, citizenId = citizenId, moneyType = moneyType, action = action,
		amount = value, reason = type(reason) == 'string' and OPX.Text.Clean(reason, 192) or '',
		allowNegative = allowNegative }

	-- A paid debit must be recognised before checking its now-empty balance or
	-- running hooks that may have changed since the original request.
	if opId then
		local prior = M.Storage.MoneyReceipt(opId)
		if not prior.ok then return fail('error.unavailable') end
		if prior.value then
			if not M.Ledger.Settle(citizenId) then return fail('error.unavailable') end
			if Money.Pending[citizenId] then return fail('money.pending', Money.Pending[citizenId]) end
			Money.Active[citizenId] = true
			M.Ledger.Enter(citizenId)
			local ran, replay = pcall(function()
				local answer = M.Storage.MoneyChange(op)
				if answer.ok then
					local currentPlayer = M.GetPlayerByCitizenId(citizenId)
					if currentPlayer then
						local current = M.Storage.Balance(citizenId, moneyType)
						if current.ok and loaded(currentPlayer) then currentPlayer.PlayerData.money[moneyType] = current.value end
					end
					answer.value.offline = not loaded(currentPlayer)
				end
				return answer
			end)
			M.Ledger.Leave(citizenId)
			Money.Active[citizenId] = nil
			return ran and replay or fail('error.unavailable')
		end
	end

	if player then
		local balance = player.PlayerData.money[moneyType] or 0
		if action == 'remove' and balance - value < 0 and not allowNegative then return fail('money.insufficient') end
		local nextValue = action == 'add' and balance + value or action == 'remove' and balance - value or value
		if nextValue > MAXIMUM or nextValue < -MAXIMUM then return fail('money.tooLarge') end
	end
	local hooks = { add = 'money:beforeAdd', remove = 'money:beforeRemove', set = 'money:beforeSet' }
	local hook = player and hooks[action] or 'money:beforeAddOffline'
	if action ~= 'touch' and not OPX.Hooks.Trigger(hook, { player = player, citizenId = citizenId,
		moneyType = moneyType, amount = value, reason = reason }) then return fail('money.vetoed') end
	if player and not loaded(player) then return fail('error.notLoggedIn') end
	if not M.Ledger.Settle(citizenId) then return fail('error.unavailable') end
	if Money.Pending[citizenId] then return fail('money.pending', Money.Pending[citizenId]) end
	if player and not loaded(player) then return fail('error.notLoggedIn') end
	-- An offline payment whose character logged in during a hook is redirected
	-- through its live Player before taking the row lock.
	if not player then
		local online = M.GetPlayerByCitizenId(citizenId)
		if online then return Money.Change(online, moneyType, value, action, reason, opId, prepare) end
	end
	Money.Active[citizenId] = true
	M.Ledger.Enter(citizenId)
	local released = false
	local function release()
		if released then return end
		released = true
		if op.release then pcall(op.release) end
		M.Ledger.Leave(citizenId)
		Money.Active[citizenId] = nil
		Money.Pending[citizenId] = nil
	end
	local function complete(answer)
		if not answer.ok then release(); return answer end
		if op.resolve and not op.resolve(answer) then error('committed participant receipt is not readable') end
		player = M.GetPlayerByCitizenId(citizenId) or player
		if player then
			if answer.value.replay then
				local current = M.Storage.Balance(citizenId, moneyType)
				if current.ok then player.PlayerData.money[moneyType] = current.value end
			else player.PlayerData.money[moneyType] = answer.value.balance end
		end
		-- apply does not publish/yield. Both in-memory halves are changed before
		-- guards are released or any event listener can start another operation.
		if op.apply and not answer.value.replay then op.apply() end
		release()
		answer.value.offline = not loaded(player)
		if not answer.value.replay then
			callNotice(op.publish)
			if action == 'touch' then
				-- A zero-price item transaction is not a money movement.
			elseif loaded(player) then callNotice(M.AnnounceMoney, player, moneyType, value, action, reason)
			else
				callNotice(OPX.Audit.Log, { event = 'money.' .. action .. 'Offline', message = reason,
					citizenId = citizenId, data = { moneyType = moneyType, amount = value, opId = op.id } })
				callNotice(OPX.Publish, M.Event.ON_MONEY, nil, { citizenId = citizenId, moneyType = moneyType,
					amount = value, action = action, balance = answer.value.balance, offline = true })
			end
		end
		return answer
	end
	local build
	local dispatched, freshOperation = false, true
	local ran, answer = pcall(function()
		if not op.id then
			local id = M.Storage.NewMoneyId()
			if not id.ok then return fail('error.unavailable') end
			op.id = id.value
		end
		-- Resolve a concurrently completed identical operation before staging.
		local prior = M.Storage.MoneyReceipt(op.id)
		if not prior.ok then return fail('error.unavailable') end
		if prior.value then
			freshOperation, dispatched = false, true
			return M.Storage.MoneyChange(op)
		end
		if prepare then
			local why
			build, why = prepare(op)
			if not build then return fail(why or 'error.unavailable') end
		end
		dispatched = true
		return M.Storage.MoneyChange(op, build)
	end)
	if not ran then
		if not dispatched then
			release()
			Open77.log.error('[character] money preparation failed before dispatch')
			return fail('error.unavailable')
		end
		answer = fail('money.pending', op.id)
	end
	if answer.error ~= 'money.pending' then
		local finished, result = pcall(complete, answer)
		if finished then return result end
		-- Never answer a committed movement as a safe-to-refund failure.
		answer = fail('money.pending', op.id)
	end

	Money.Pending[citizenId] = op.id
	Open77.log.error(('[character] money operation %s pending reconciliation; no refund issued'):format(op.id))
	CreateThread(function()
		while Money.Pending[citizenId] == op.id do
			Wait(1000)
			local recovered, retried = pcall(M.Storage.MoneyChange, op, build)
			if recovered and type(retried) == 'table' and retried.ok then
				-- The first attempt may have committed after its reply was lost.
				-- Its staged memory half has still not been applied in this VM.
				local read, balance = pcall(M.Storage.Balance, citizenId, moneyType)
				if read and balance.ok then retried.value.balance = balance.value end
				retried.value.replay = not freshOperation
				local applied = pcall(complete, retried)
				if applied then return end
			end
		end
	end)
	return fail('money.pending', op.id)
end

--- Attaches a second loaded wallet to a buyer's transaction without waiting
--- while holding the first lock. Opposite trades fail busy instead of deadlock.
function Money.AttachCredit(op, other, creditAmount)
	creditAmount = creditAmount or op.amount
	if type(creditAmount) ~= 'number' or not math.tointeger(creditAmount) or creditAmount < 0 or creditAmount > op.amount then
		return nil, 'money.badAmount'
	end
	if type(other) ~= 'table' or not loaded(other) or #op.id > 121 then return nil, 'error.notLoggedIn' end
	local citizenId = other.PlayerData.citizenId
	if citizenId == op.citizenId then return nil, 'money.opIdConflict' end
	if Money.Pending[citizenId] then return nil, 'money.pending' end
	if M.Ledger.Busy(citizenId) then return nil, 'busy' end
	Money.Active[citizenId], Money.Pending[citizenId] = true, op.id
	M.Ledger.Enter(citizenId)
	local oldRelease, oldApply, oldPublish, oldResolve = op.release, op.apply, op.publish, op.resolve
	local peerBalance
	op.release = function()
		if oldRelease then pcall(oldRelease) end
		M.Ledger.Leave(citizenId)
		Money.Active[citizenId], Money.Pending[citizenId] = nil, nil
	end
	op.resolve = function(answer)
		if oldResolve and not oldResolve(answer) then return false end
		local receipt = M.Storage.MoneyReceipt(op.id .. ':credit')
		if not receipt.ok or not receipt.value then return false end
		local row = receipt.value
		if row.citizen_id ~= citizenId or row.money_type ~= op.moneyType or tonumber(row.amount) ~= creditAmount
			or row.action ~= (creditAmount > 0 and 'add' or 'touch') or row.reason ~= 'peer-credit:' .. op.id then return false end
		local balance = M.Storage.Balance(citizenId, op.moneyType)
		if not balance.ok then return false end
		peerBalance = balance.value
		return true
	end
	op.apply = function()
		other.PlayerData.money[op.moneyType] = peerBalance
		if oldApply then oldApply() end
	end
	op.publish = function()
		if oldPublish then oldPublish() end
		if loaded(other) and creditAmount > 0 then M.AnnounceMoney(other, op.moneyType, creditAmount, 'add', op.reason) end
	end
	return function(attempt) return M.Storage.PeerStatements(attempt, citizenId, creditAmount) end
end
