--- Real media/wallet/inventory orchestration, with explicit SQL-effect stores.
-- Real InnoDB locking and rollback are qualified by economy-sql.py separately.
local Host = dofile('tests/host.lua')
local state = { sales = {}, scenes = {}, sequence = 0, company = 10000, companyReceipts = {}, operations = {} }
local function sum(predicate)
	local total = 0
	for _, sale in ipairs(state.sales) do if predicate(sale) then total = total + sale.total end end
	return total
end
local db = Host.Database({
	scalar = function(sql)
		if sql:find('UUID()', 1, true) then state.sequence = state.sequence + 1; return 'media-unit-' .. state.sequence end
		return 0
	end,
	query = function(sql, params)
		if sql:find('opx77_media_scenes', 1, true) then
			local rows = {}
			for _, scene in ipairs(state.scenes) do if scene.desk == params.desk then rows[#rows + 1] = scene end end
			return rows
		end
		return {}
	end,
	single = function(sql, p)
		if sql:find('AS seller', 1, true) then
			local revision = 0
			for index, sale in ipairs(state.sales) do if sale.desk == p.desk then revision = index end end
			return { seller = sum(function(s) return s.cid == p.citizen end),
				minted = sum(function(s) return s.network == p.network and s.funded == 'mint' end), revision = revision }
		end
		if sql:find('opx77_company_ledger', 1, true) then return state.companyReceipts[p.op] end
		if sql:find('opx77_company_accounts', 1, true) then return { balance = state.company } end
		return nil
	end,
	update = function() return 1 end,
	insert = function() return 1 end,
	transaction = function(plan)
		local op
		for _, statement in ipairs(plan) do
			if statement.query:find('INSERT INTO opx77_money_ledger', 1, true) then op = state.operations[statement.values[1]]; break end
		end
		local sale
		for _, stmt in ipairs(plan) do
			local q, v = stmt.query, stmt.values
			if q:find('INSERT INTO opx77_media_sales', 1, true) then
				assert(q:find('attempt_token = ?', 1, true))
				sale = { cid = op.citizenId, network = v[1], desk = v[2], total = v[3], funded = v[4], opId = v[5] }
				state.sales[#state.sales + 1] = sale
			elseif q:find('INSERT INTO opx77_media_scenes', 1, true) then
				assert(q:find('attempt_token = ?', 1, true))
				for index = 1, #v - 2, 4 do
					state.scenes[#state.scenes + 1] = { desk = sale.desk, x = v[index + 1], y = v[index + 2], z = v[index + 3], at = state.now }
				end
			elseif q:find('INSERT INTO opx77_company_ledger', 1, true) then
				state.company = state.company + v[4]
				state.companyReceipts[v[1]] = { kind = v[2], group_key = v[3], delta = v[4], balance_after = state.company }
			end
		end
		return true
	end,
})
db.unitMoneyGuard = function(guard)
	local v, offset = guard.values, 0
	if guard.query:find('opx77_company_accounts', 1, true) then
		if state.company < v[3] then return false end
		offset = 3
	end
	if guard.query:find('opx77_media_sales', 1, true) then
		assert(state.latestPlan and state.latestPlan[1].query:find('INSERT INTO opx77_media_state', 1, true), 'network mutex must precede the wallet guard')
		local cid, sellerLeft, desk, revision = v[offset + 1], v[offset + 2], v[offset + 3], v[offset + 4]
		if sum(function(s) return s.cid == cid end) > sellerLeft then return false end
		local latest = 0; for index, sale in ipairs(state.sales) do if sale.desk == desk then latest = index end end
		if latest ~= revision then return false end
		if v[offset + 5] then
			local network, left = v[offset + 5], v[offset + 6]
			if sum(function(s) return s.network == network and s.funded == 'mint' end) > left then return false end
		end
	end
	return true
end
local env, control = Host.Environment('server', db)
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do
	assert(loadfile(file, 't', env))()
	if file == 'config/media.lua' then
		local desk = env.OPX.Config.MODULES.media.NETWORKS.n54.DESKS[1]
		desk.X, desk.Y, desk.Z = 300, 10, 1
	end
end
dofile('tests/money-store.lua').Install(env, db)
control.Pump(400)
local OPX = env.OPX
local C, I, M = OPX.Modules.Get('character'), OPX.Modules.Get('inventory'), OPX.Modules.Get('media')
local realPlan = C.Storage.MoneyStatements
C.Storage.MoneyStatements = function(op, ...)
	state.operations[op.id] = op
	local result = realPlan(op, ...)
	if result.ok then state.latestPlan = result.value end
	return result
end
local account, source = 'media-account', 741
control.Admit(source, account); control.Stand(source, 300, 10, 1)
local player = C.CreatePlayer({ source = source, userId = account, citizenId = OPX.CitizenId.Generate(),
	money = { EDDIES = 0, BANK = 0 }, job = { name = 'reporter', onDuty = true, grade = { level = 2 } }, jobs = { reporter = 2 } }, false)
C.RegisterPlayer(player)
player.PlayerData.job = { name = 'reporter', onDuty = true, grade = { level = 2 } }
player.PlayerData.jobs = { reporter = 2 }
local cid = player.PlayerData.citizenId
local bag = I.Containers.Transient(I.KIND.CHARACTER, cid, 50, 100000)
bag.transient = nil; I.Players.Attach(source)
local function photo(serial, x)
	local now = env.Open77.time.unix()
	assert(I.Containers.Add(bag, 'press_photo', 1, { by = cid, at = now, serial = serial, crowd = 0, x = x or 300, y = 10, z = 1 }))
end
local function count() return I.Containers.CountIn(bag, 'press_photo') end
local get, accountsEnabled = OPX.Api.Get, false
OPX.Api.Get = function(name, ...)
	if name == 'accounts' and not accountsEnabled then return nil end
	return get(name, ...)
end
local function sell()
	control.Advance(1000)
	state.now = env.Open77.time.unix()
	return M.Sell(source, { network = 'n54', desk = M.Built.networks.n54.desks[1].key })
end
-- Lost mint acknowledgement: the core owns reconciliation; nothing is restored.
photo('first')
local original, lose = C.Storage.MoneyChange, true
C.Storage.MoneyChange = function(...)
	local result = original(...)
	if result.ok and lose then lose = false; error('lost media commit reply') end
	return result
end
local ok, code = sell()
assert(not ok and code == 'sale_pending', code)
assert(#state.sales == 1 and #state.scenes == 1 and count() == 1 and bag.economicLock)
control.Pump(40)
C.Storage.MoneyChange = original
local firstPay = player.PlayerData.money.BANK
assert(firstPay > 0 and count() == 0 and not bag.economicLock)
assert(not sell() and player.PlayerData.money.BANK == firstPay and #state.sales == 1)
-- Durable scene history changes the next quote, even if module memory resets.
photo('second')
assert(sell())
assert(state.sales[2].total < state.sales[1].total and count() == 0)
-- Treasury debit, payment, selected item and cap history use one transaction.
accountsEnabled = true
photo('treasury', 900)
local before, cash = state.company, player.PlayerData.money.BANK
assert(sell())
assert(state.company < before and player.PlayerData.money.BANK - cash == before - state.company)
assert(state.sales[3].funded == 'accounts' and count() == 0)
photo('broke', 1200)
state.company = 0
local paidBefore, salesBefore = player.PlayerData.money.BANK, #state.sales
local refused = sell()
assert(not refused and count() == 1 and #state.sales == salesBefore and player.PlayerData.money.BANK == paidBefore)
-- Exact slot metadata must still match after the inventory quote is read.
state.company = 10000
local inv = OPX.Api.Get('inventory')
local inventoryRead = inv.GetInventory
inv.GetInventory = function(...)
 local result = OPX.Table.DeepCopy(inventoryRead(...))
 for _, item in pairs(bag.items) do if item.name == 'press_photo' then item.metadata.serial = 'replacement-serial' end end
 return result
end
assert(not sell() and count() == 1 and #state.sales == salesBefore and player.PlayerData.money.BANK == paidBefore)
inv.GetInventory = inventoryRead
-- A quote invalidated by another desk sale must fail before any value moves.
local nextId = M.Storage.NewId
M.Storage.NewId = function()
 local result = nextId()
 state.sales[#state.sales + 1] = { cid = 'another-reporter', network = 'n54',
  desk = 'n54/' .. M.Built.networks.n54.desks[1].key, total = 0, funded = 'accounts' }
 return result
end
local companyBefore = state.company
assert(not sell() and count() == 1 and player.PlayerData.money.BANK == paidBefore and state.company == companyBefore)
M.Storage.NewId = nextId
-- Both allowance types come from durable history, not process-local tables.
local sellerCap, mintCap = M.Built.sales.sellerCap, M.Built.sales.mintCap
M.Built.sales.sellerCap = sum(function(s) return s.cid == cid end)
local capped, capCode = sell()
assert(not capped and capCode == 'desk_capped' and count() == 1)
M.Built.sales.sellerCap = sellerCap
accountsEnabled = false
M.Built.sales.mintCap = sum(function(s) return s.network == 'n54' and s.funded == 'mint' end)
local cappedMint, mintCode = sell()
assert(not cappedMint and mintCode == 'desk_capped' and count() == 1)
M.Built.sales.mintCap = mintCap
print('media economy: atomic mint/treasury, lost reply, durable scenes, refusal and byline checks passed')
