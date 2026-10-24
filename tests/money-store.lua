--- An explicit durable-store double for framework unit tests without MariaDB.
-- @author dop42
-- It is installed only by tests. Production always uses the SQL ledger. Actual
-- SQL, rollback, receipt replay and crash durability have separate InnoDB tests.
local Fixture = {}
function Fixture.Install(env, database)
	local M = env.OPX.Modules.Get('character')
	if database == nil then
		env.OPX.Modules.Get('inventory').Storage.SaveAtomic = function() return env.OPX.Result.Ok(true) end
	end
	local Result = env.OPX.Result
	local balances, receipts, sequence = {}, {}, 0
	local state = database and database.unitMoneyState
	local function wallet(citizenId)
		if balances[citizenId] then return balances[citizenId] end
		for _, player in pairs(M.Players) do
			if player.PlayerData.citizenId == citizenId then
				balances[citizenId] = env.OPX.Table.DeepCopy(player.PlayerData.money)
				return balances[citizenId]
			end
		end
		if state then
			if state.missing then return nil end
			balances[citizenId] = { EDDIES = state.balance, BANK = state.balance }
			return balances[citizenId]
		end
		local fetched = M.Storage.FetchOne(citizenId)
		if fetched.ok and fetched.value then
			balances[citizenId] = env.OPX.Table.DeepCopy(fetched.value.money or {})
			return balances[citizenId]
		end
	end
	M.Storage.NewMoneyId = function()
		sequence = sequence + 1
		return Result.Ok('unit-money-' .. sequence)
	end
	M.Storage.MoneyReceipt = function(id) return Result.Ok(receipts[id]) end
	M.Storage.Balance = function(citizenId, moneyType)
		local data = wallet(citizenId)
		return data and Result.Ok(data[moneyType] or 0) or Result.Err('character.notFound')
	end
	M.Storage.MoneyChange = function(op, build)
		if not op.id then op.id = M.Storage.NewMoneyId().value end
		local receipt = receipts[op.id]
		if receipt then
			if receipt.citizen_id ~= op.citizenId or receipt.money_type ~= op.moneyType
				or receipt.action ~= op.action or receipt.amount ~= op.amount or receipt.reason ~= op.reason then
				return Result.Err('money.opIdConflict')
			end
			return Result.Ok({ balance = receipt.balance_after, opId = op.id, replay = true })
		end
		local data = wallet(op.citizenId)
		if not data then
			if state then state.offline[#state.offline + 1] = { citizen = op.citizenId } end
			return Result.Err('character.notFound')
		end
		local old = data[op.moneyType] or 0
		local value = op.action == 'add' and old + op.amount
			or op.action == 'remove' and old - op.amount or op.action == 'touch' and old or op.amount
		if value > 9007199254740991 or value < -9007199254740991 then return Result.Err('money.tooLarge') end
		if value < 0 and not op.allowNegative then return Result.Err('money.insufficient') end
		op.attempt = M.Storage.NewMoneyId().value
		local effects, guard = {}, nil
		if build then
			local prepared
			prepared, effects, guard = pcall(build, op)
			if not prepared then return Result.Err('error.unavailable') end
		end
		local peerChanges = {}
		for _, statement in ipairs(effects or {}) do
			if statement.query:find('INSERT INTO opx77_money_ledger', 1, true) then
				local values = statement.values
				local adding = values[4] == 'add'
				local peerId, peerReason = values[adding and 9 or 8], values[adding and 8 or 7]
				local other = wallet(peerId)
				if not other then return Result.Err('character.notFound') end
				local balance = (other[values[3]] or 0) + (adding and values[5] or 0)
				if balance > 9007199254740991 then return Result.Err('money.tooLarge') end
				peerChanges[#peerChanges + 1] = { data = other, moneyType = values[3], balance = balance,
					id = values[1], citizenId = peerId, reason = peerReason, amount = values[5], action = values[4] }
			end
		end

		local planned = M.Storage.MoneyStatements(op, effects, guard)
		if not planned.ok then return planned end
		if guard and database and database.unitMoneyGuard and not database.unitMoneyGuard(guard) then
			return Result.Err(guard.error)
		end
		local boundary = M.Storage.UnitMoney
		if guard and boundary and boundary.OnGuard and not boundary.OnGuard(guard, op) then return Result.Err(guard.error) end

		if state or (build and database and database.unitMoneyGuard) then
			local written = env.OPX.Storage.Transaction(planned.value)
			if not written.ok then return written end
		end
		local online = false
		for _, player in pairs(M.Players) do
			if player.PlayerData.citizenId == op.citizenId then online = true; break end
		end
		if state and not online then
			state.balance = value
			state.offline[#state.offline + 1] = { citizen = op.citizenId,
				path = '$.' .. op.moneyType, amount = op.amount, opId = op.id }
		end
		if boundary and boundary.OnCommit then
			local committed = boundary.OnCommit(op, effects)
			if type(committed) == 'table' and not committed.ok then return committed end
		end
		for _, peer in ipairs(peerChanges) do
			peer.data[peer.moneyType] = peer.balance
			receipts[peer.id] = { citizen_id = peer.citizenId, money_type = peer.moneyType,
				action = peer.action, amount = peer.amount, balance_after = peer.balance, reason = peer.reason }
		end


		data[op.moneyType] = value
		receipts[op.id] = { citizen_id = op.citizenId, money_type = op.moneyType,
			action = op.action, amount = op.amount, balance_after = value, reason = op.reason }
		return Result.Ok({ balance = value, opId = op.id })
	end
	M.Storage.UnitMoney = { balances = balances, receipts = receipts }
	return M.Storage.UnitMoney
end
--- Arranges both sides of the explicit unit store without publishing events.
function Fixture.Set(env, player, moneyType, value)
	local M = env.OPX.Modules.Get('character')
	player.PlayerData.money[moneyType] = value
	M.Storage.UnitMoney.balances[player.PlayerData.citizenId] = env.OPX.Table.DeepCopy(player.PlayerData.money)
end
return Fixture
