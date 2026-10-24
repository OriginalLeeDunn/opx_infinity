--- Stock, served drinks and consented invoices share durable wallet receipts.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server', Host.Database({ scalar = function() return 1 end,
	query = function() return {} end, single = function() return nil end, insert = function() return 1 end,
	update = function() return 1 end, transaction = function() return true end }))
local interaction = 0
env.Open77.playerInteractions = { request = function(actor, target)
	interaction = interaction + 1
	return { id = 'bar-audit-' .. interaction, actor = tostring(actor), target = tostring(target) }
end, cancel = function() return true end }
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do
	assert(loadfile(file, 't', env))()
	if file == 'config/bar.lua' then
		for _, venue in ipairs(env.OPX.Config.MODULES.bar.VENUES) do
			if venue.ID == 'afterlife' then
				venue.COUNTER = { X = 100, Y = 1, Z = 1 }
				venue.STASH.X, venue.STASH.Y, venue.STASH.Z = 101, 1, 1
				venue.SUPPLY.X, venue.SUPPLY.Y, venue.SUPPLY.Z = 102, 1, 1
			end
		end
	end
end
dofile('tests/money-store.lua').Install(env)
control.Pump(240)
local OPX = env.OPX
local character, inventory, bar, invoices = OPX.Modules.Get('character'), OPX.Modules.Get('inventory'), OPX.Modules.Get('bar'), OPX.Modules.Get('invoices')
local function person(source, job)
	local cid, account = OPX.CitizenId.Generate(), 'bar-audit-' .. source
	control.Admit(source, account); control.Stand(source, 101, 1, 1)
	local player = character.CreatePlayer({ source = source, userId = account, citizenId = cid,
		charInfo = { firstName = 'Test', lastName = 'Bar' }, money = { BANK = 1000, EDDIES = 0 } }, false)
	character.RegisterPlayer(player)
	player.PlayerData.job = { name = job, onDuty = true, grade = { name = 'Staff', level = 1 } }
	player.PlayerData.jobs = { [job] = 1 }
	local bag = inventory.Containers.Transient(inventory.KIND.CHARACTER, cid, 30, 100000)
	bag.transient = nil; inventory.Players.Attach(source)
	return player, bag
end
local staff, staffBag = person(85, 'bartender')
local customer, customerBag = person(86, 'unemployed')
local stash = inventory.Containers.Transient(inventory.KIND.STASH, 'bar_afterlife', 50, 1000000)
stash.transient = nil
inventory.EconomicStash = function(name) assert(name == 'bar_afterlife'); return OPX.Result.Ok(stash) end
local company, bills, nextBill, lost, notices = 500, {}, 0, true, 0
local store, actualChange = character.Storage, character.Storage.MoneyChange
store.UnitMoney.OnGuard = function(guard)
	if guard.query:find('opx77_company_accounts', 1, true) then
		local limit = guard.values[#guard.values]
		if guard.query:find('COALESCE((SELECT balance FROM opx77_company_accounts', 1, true) then return company <= limit end
		return company >= limit
	end
	return true
end
store.UnitMoney.OnCommit = function(op, statements)
	for _, statement in ipairs(statements or {}) do
		if statement.query:find('INSERT INTO opx77_company_ledger', 1, true) then company = company + statement.values[4] end
		if statement.query:find('INSERT INTO opx77_invoices ', 1, true) then
			local v = statement.values
			nextBill = nextBill + 1
			bills[op.id] = { id = nextBill, state = v[1], rev = 0, issuerCid = v[2], issuerName = v[3],
				targetCid = v[4], targetName = v[5], amount = v[7], reason = v[8],
				account = { kind = v[9], key = v[10] }, cutPct = v[11], source = v[12], issuedAt = v[13], expiresAt = v[14] }
		end
	end
end
invoices.Storage.ByIssue = function(id) return OPX.Result.Ok(bills[id]) end
store.MoneyChange = function(...)
	local answer = actualChange(...)
	if answer.ok and lost then lost = false; error('lost commerce commit reply') end
	return answer
end
env.AddEventHandler(bar.Event.ON_BOUGHT, function() notices = notices + 1 end)
bar.S.funds = 'account'
local row = bar.S.venues.afterlife.supply.catalog[1]
local bought, code = bar.Buy(85, 'afterlife', row.index)
assert(not bought and code == 'payment_pending')
assert(company == 500 - row.price and inventory.Containers.CountIn(stash, row.item) == 0 and stash.economicLock)
control.Pump(40)
assert(inventory.Containers.CountIn(stash, row.item) == row.count and not stash.economicLock)
assert(company == 500 - row.price and notices == 1 and staff.PlayerData.money.BANK == 1000)
store.MoneyChange = actualChange
bar.S.billing = 'direct'
assert(inventory.Containers.Add(staffBag, 'johnny_silverhand', 1))
local total = staff.PlayerData.money.BANK + customer.PlayerData.money.BANK + company
control.Advance(1000)
assert(bar.Serve(85, 86, 'johnny_silverhand'))
assert(bar.Complete('bar-audit-' .. interaction))
assert(customer.PlayerData.money.BANK == 750 and staff.PlayerData.money.BANK == 1062)
assert(staff.PlayerData.money.BANK + customer.PlayerData.money.BANK + company == total)
assert(inventory.Containers.CountIn(staffBag, 'johnny_silverhand') == 0 and inventory.Containers.CountIn(customerBag, 'johnny_silverhand') == 1)
-- A full company ledger cannot redirect its share to the staff member.
company = 9007199254740991
assert(inventory.Containers.Add(staffBag, 'johnny_silverhand', 1))
control.Advance(1000)
assert(bar.Serve(85, 86, 'johnny_silverhand'))
assert(not bar.Complete('bar-audit-' .. interaction))
assert(customer.PlayerData.money.BANK == 750 and staff.PlayerData.money.BANK == 1062 and inventory.Containers.CountIn(staffBag, 'johnny_silverhand') == 1)
-- Invoice mode persists an unpaid obligation with the delivered drink. The
-- native handover already carried the customer's consent to its stated price.
company, bar.S.billing, lost = 500, 'invoice', true
store.MoneyChange = function(...)
	local answer = actualChange(...)
	if answer.ok and lost then lost = false; error('lost invoiced handover reply') end
	return answer
end
control.Advance(1000)
assert(bar.Serve(85, 86, 'johnny_silverhand'))
local completed, pending = bar.Complete('bar-audit-' .. interaction)
assert(not completed and pending == 'payment_pending' and nextBill == 1)
assert(inventory.Containers.CountIn(staffBag, 'johnny_silverhand') == 1 and customer.PlayerData.money.BANK == 750)
control.Pump(40)
assert(nextBill == 1 and inventory.Containers.CountIn(staffBag, 'johnny_silverhand') == 0)
assert(inventory.Containers.CountIn(customerBag, 'johnny_silverhand') == 2)
assert(customer.PlayerData.money.BANK == 750 and staff.PlayerData.money.BANK == 1062)
assert(OPX.Api.Get('invoices').Get(1).value.state == 'unpaid')
store.MoneyChange = actualChange
-- Authority can change during a stash load. Recheck it under the trade guards.
local oldStash, oldJob, oldJobs = inventory.EconomicStash, staff.PlayerData.job, staff.PlayerData.jobs
local beforeCompany, beforeStock = company, inventory.Containers.CountIn(stash, row.item)
inventory.EconomicStash = function(name)
	staff.PlayerData.job = { name = 'unemployed', onDuty = false, grade = { level = 0 } }
	staff.PlayerData.jobs = {}
	return oldStash(name)
end
control.Advance(1000)
local allowed, why = bar.Buy(85, 'afterlife', row.index)
assert(not allowed and why == 'job_required')
assert(company == beforeCompany and inventory.Containers.CountIn(stash, row.item) == beforeStock)
assert(not staffBag.economicLock and not stash.economicLock)
inventory.EconomicStash, staff.PlayerData.job, staff.PlayerData.jobs = oldStash, oldJob, oldJobs
-- The same check protects a mix whose progress was authorised earlier.
local recipe = bar.S.recipes.rogue
for _, input in ipairs(recipe.inputs) do assert(inventory.Containers.Add(stash, input.item, input.count)) end
control.Advance(1000)
assert(bar.Mix(85, 'afterlife', 'rogue'))
local progress = OPX.Modules.Get('progress')
local state = OPX.Api.Get('progress').State(85).value
assert(state and state.id)
inventory.EconomicStash = function(name)
	staff.PlayerData.job = { name = 'unemployed', onDuty = false, grade = { level = 0 } }
	staff.PlayerData.jobs = {}
	return oldStash(name)
end
local inputBefore = inventory.Containers.CountIn(stash, recipe.inputs[1].item)
local outputBefore = inventory.Containers.CountIn(staffBag, recipe.item)
control.Advance(recipe.ms)
env.source = 85
control.netEvents[progress.Event.REPORT](state.id, 'finished')
env.source = nil
control.Pump(20)
assert(inventory.Containers.CountIn(stash, recipe.inputs[1].item) == inputBefore)
assert(inventory.Containers.CountIn(staffBag, recipe.item) == outputBefore)
inventory.EconomicStash, staff.PlayerData.job, staff.PlayerData.jobs = oldStash, oldJob, oldJobs
print('bar economy: atomic company stock, split sale, overflow refusal and durable invoiced handover passed')
