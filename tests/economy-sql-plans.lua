--- Exports the real storage builders for isolated InnoDB crash integration tests.
-- @author dop42
local Host = dofile('tests/host.lua')
local env = Host.Environment('server')
local character, business, crafting, appearance, vehicles, dealership, inventory = {}, {}, {}, {}, {}, {}, { Common = { Copy = function(value) return value end } }
local underworld, invoices, contracts, media = {}, {}, {}, {}
local modules = { media = media, underworld = underworld, invoices = invoices, contracts = contracts, character = character, inventory = inventory, business = business, crafting = crafting, appearance = appearance, vehicles = vehicles, dealership = dealership }
env.OPX = { Modules = { Get = function(name) return modules[name] end } }
assert(loadfile('lib/shared/result.lua', 't', env))()
assert(loadfile('lib/server/storage.lua', 't', env))()
assert(loadfile('modules/character/server/storage.lua', 't', env))()
assert(loadfile('modules/inventory/server/storage.lua', 't', env))()
assert(loadfile('modules/business/server/storage.lua', 't', env))()
assert(loadfile('modules/crafting/server/storage.lua', 't', env))()
assert(loadfile('modules/appearance/server/storage.lua', 't', env))()
assert(loadfile('modules/vehicles/server/storage.lua', 't', env))()
assert(loadfile('modules/dealership/server/storage.lua', 't', env))()
assert(loadfile('modules/underworld/server/storage.lua', 't', env))()
assert(loadfile('modules/invoices/server/storage.lua', 't', env))()
assert(loadfile('modules/contracts/server/storage.lua', 't', env))()
assert(loadfile('modules/media/server/storage.lua', 't', env))()
local output = { schema = {}, cases = {}, companyCases = {}, concurrent = {}, columns = {}, craftingSequential = {}, mediaConcurrent = {} }
for _, schema in ipairs({ character.Storage.SCHEMA, inventory.Storage.SCHEMA, business.Storage.SCHEMA, crafting.Storage.SCHEMA, appearance.Storage.SCHEMA, vehicles.Storage.SCHEMA, dealership.Storage.SCHEMA, underworld.Storage.SCHEMA, invoices.Storage.SCHEMA, contracts.Storage.SCHEMA, media.Storage.SCHEMA }) do
	for index = 1, #schema do output.schema[#output.schema + 1] = schema[index] end
end
for _, storage in ipairs({ business.Storage, vehicles.Storage, invoices.Storage, contracts.Storage, underworld.Storage }) do
	for _, column in ipairs(storage.COLUMNS or {}) do output.columns[#output.columns + 1] = column end
end
for index = 1, 2 do
	local op = { id = 'craft-tail:' .. index, attempt = 'tail-attempt:' .. index, citizenId = 'ECONTEST',
		moneyType = 'EDDIES', action = 'touch', amount = 0, reason = 'crafting sequence' }
	local effects, guard = crafting.Storage.OrderStatements(op, 'sequential', 'rounds', 60, 3)
	output.craftingSequential[index] = assert(character.Storage.MoneyStatements(op, effects, guard).value)
end
local function make(name, action, amount, notes, balance, beforeNotes)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = action, amount = amount, reason = 'integration' }
	local bag = { id = 1, items = { [1] = { name = 'weapon_test', count = 1, metadata = { ammo = 9 } } } }
	if notes > 0 then bag.items[2] = { name = 'eddies', count = notes } end
	local effects = inventory.Storage.MoneyStatements(bag, op)
	local planned = character.Storage.MoneyStatements(op, effects)
	assert(planned.ok)
	op.attempt = '22222222-2222-2222-2222-222222222222'
	local replay = character.Storage.MoneyStatements(op, inventory.Storage.MoneyStatements(bag, op))
	output.cases[#output.cases + 1] = { name = name, action = action, amount = amount,
		balance = balance, notes = beforeNotes, statements = planned.value, replay = replay.value }
end
make('withdraw', 'remove', 100, 100, 500, 0)
make('deposit', 'add', 100, 0, 500, 100)
make('insufficient', 'remove', 200, 200, 100, 0)
make('overflow', 'add', 1, 0, 9007199254740991, 1)
-- More than one INSERT batch, so a crash between chunks is exercised too.
local op = { id = 'integration:many-stacks', attempt = '11111111-1111-1111-1111-111111111111',
	citizenId = 'ECONTEST', moneyType = 'EDDIES', action = 'remove', amount = 100, reason = 'integration' }
local bag = { id = 1, items = {} }
for slot = 1, 30 do bag.items[slot] = { name = 'material_' .. slot, count = 1, metadata = { value = slot } } end
bag.items[31] = { name = 'eddies', count = 100 }
local plan = character.Storage.MoneyStatements(op, inventory.Storage.MoneyStatements(bag, op))
output.cases[#output.cases + 1] = { name = 'many-stacks', action = 'remove', amount = 100,
	balance = 500, notes = 0, statements = plan.value }
local saleOp = { id = 'integration:multi-sale', attempt = '11111111-1111-1111-1111-111111111111',
	citizenId = 'ECONTEST', moneyType = 'EDDIES', action = 'add', amount = 20, reason = 'integration' }
local function salePlan()
	local effects = inventory.Storage.MoneyStatements({ id = 1, items = {
		[1] = { name = 'weapon_test', count = 1, metadata = { ammo = 9 } }, [2] = { name = 'water', count = 1 } } }, saleOp)
	for _, statement in ipairs(inventory.Storage.MoneyStatements({ id = 2, items = { [1] = { name = 'water', count = 1 } } }, saleOp)) do
		effects[#effects + 1] = statement
	end
	return assert(character.Storage.MoneyStatements(saleOp, effects).value)
end
local saleStatements = salePlan()
saleOp.attempt = '22222222-2222-2222-2222-222222222222'
output.cases[#output.cases + 1] = { name = 'multi-sale', balance = 500, notes = 0, multi = true,
	spent = -20, statements = saleStatements, replay = salePlan() }
local function company(name, deposit, balance, bank, amount, refused)
	local operation = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = deposit and 'remove' or 'add',
		amount = amount, reason = 'integration' }
	local effects, guard = business.Storage.WalletStatements(operation, 'job', 'test', amount, deposit)
	local planned = character.Storage.MoneyStatements(operation, effects, guard)
	assert(planned.ok)
	operation.attempt = '22222222-2222-2222-2222-222222222222'
	local again, nextGuard = business.Storage.WalletStatements(operation, 'job', 'test', amount, deposit)
	output.cases[#output.cases + 1] = { name = name, action = operation.action, amount = amount,
		balance = balance, company = bank, notes = 0, refused = refused or false,
		statements = planned.value, replay = character.Storage.MoneyStatements(operation, again, nextGuard).value }
end
company('company-deposit', true, 500, 40, 100)
company('company-withdraw', false, 500, 400, 100)
company('company-insufficient', false, 500, 40, 100, true)
company('company-overflow', true, 500, 9007199254740991, 1, true)
company('company-wallet-overflow', false, 9007199254740991, 40, 1, true)
local function craftCase(name, collect, full)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = collect and 'touch' or 'remove',
		amount = collect and 0 or 25, reason = 'integration' }
	local staged = { id = 1, items = { [1] = { name = collect and 'weapon_test' or 'scrap_metal', count = 1 },
		[2] = { name = collect and 'ammo_handgun' or 'scrap_metal', count = collect and 30 or 2 } } }
	local function plan()
		local effects = inventory.Storage.MoneyStatements(staged, op)
		local extra, guard
		if collect then extra, guard = crafting.Storage.CollectionStatements(op, 1)
		else extra, guard = crafting.Storage.OrderStatements(op, 'bench', 'rounds', 60, 1) end
		for _, statement in ipairs(extra) do effects[#effects + 1] = statement end
		return assert(character.Storage.MoneyStatements(op, effects, guard).value)
	end
	local statements = plan()
	op.attempt = '22222222-2222-2222-2222-222222222222'
	output.cases[#output.cases + 1] = { name = name, action = op.action, amount = op.amount, balance = 500, notes = 0,
		craft = collect and 'collect' or full and 'full' or 'order', refused = full or false,
		statements = statements, replay = plan(), spent = collect and 0 or full and 0 or 25 }
end
craftCase('craft-order', false, false)
craftCase('craft-full', false, true)
craftCase('craft-collect', true, false)
local function peerCase(name, buyerBalance, sellerBalance, refused)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = 'remove', amount = 100, reason = 'peer trade' }
	local function plan()
		local statements, guard = character.Storage.PeerStatements(op, 'SELLTEST')
		for _, bag in ipairs({ { id = 1, items = { [1] = { name = 'weapon_test', count = 1, metadata = { ammo = 9 } }, [2] = { name = 'water', count = 2 } } },
			{ id = 2, items = { [1] = { name = 'water', count = 1 } } } }) do
			for _, statement in ipairs(inventory.Storage.MoneyStatements(bag, op)) do statements[#statements + 1] = statement end
		end
		return assert(character.Storage.MoneyStatements(op, statements, guard).value)
	end
	local statements = plan()
	op.attempt = '22222222-2222-2222-2222-222222222222'
	output.cases[#output.cases + 1] = { name = name, balance = buyerBalance, peer = sellerBalance, notes = 0,
		refused = refused or false, statements = statements, replay = plan() }
end
peerCase('peer-sale', 500, 40)
peerCase('peer-insufficient', 40, 40, true)
peerCase('peer-overflow', 500, 9007199254740991, true)
local function ownershipCase(name, full)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = 'remove', amount = 100, reason = 'vehicle purchase' }
	local entity = { plate = 'TESTNEW', citizenId = 'ECONTEST', record = 'Vehicle.test', garage = 'test', state = 1, health = 1, metadata = {} }
	local function plan()
		local effects, guard = vehicles.Storage.PurchaseStatements(entity, op, 1)
		for _, statement in ipairs(dealership.Storage.SaleStatements(op, entity,
			{ sellerCitizen = 'SELLTEST', kind = 'job', group = 'test' }, 'EDDIES', 20, 80)) do effects[#effects + 1] = statement end
		return assert(character.Storage.MoneyStatements(op, effects, guard).value)
	end
	local statements = plan()
	op.attempt = '22222222-2222-2222-2222-222222222222'
	output.cases[#output.cases + 1] = { name = name, balance = 500, notes = 0, vehicle = full and 'full' or 'purchase',
		refused = full or false, spent = full and 0 or 100, statements = statements, replay = plan() }
end
ownershipCase('vehicle-purchase', false)
ownershipCase('vehicle-full', true)
local clothingOp = { id = 'integration:clothing', attempt = '11111111-1111-1111-1111-111111111111',
	citizenId = 'ECONTEST', moneyType = 'EDDIES', action = 'remove', amount = 25, reason = 'clothing' }
local encoded = '{"schemaVersion":1,"equipment":{"OuterChest":"Items.Jacket_01"},"wardrobe":{"outfits":{}}}'
local clothingPlan = character.Storage.MoneyStatements(clothingOp, appearance.Storage.ClothingStatements(clothingOp, encoded))
clothingOp.attempt = '22222222-2222-2222-2222-222222222222'
output.cases[#output.cases + 1] = { name = 'clothing', balance = 500, notes = 0, spent = 25, clothing = true,
	statements = clothingPlan.value, replay = character.Storage.MoneyStatements(clothingOp, appearance.Storage.ClothingStatements(clothingOp, encoded)).value }
local function underworldCase(name, kind)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111',
		citizenId = 'ECONTEST', moneyType = 'EDDIES', action = kind == 'collect' and 'add' or 'touch',
		amount = kind == 'collect' and 80 or 0, reason = 'underworld integration' }
	local function plan()
		local effects, guard
		if kind == 'mint' then effects, guard = underworld.Storage.MintStatements(op, 'robbery:test', 'robbery', 100, 100, 3600,
			{ x = 1, y = 2, z = 3 }, { id = 'test', charges = 0, age = 0 })
		elseif kind == 'collect' then effects, guard = underworld.Storage.CollectionStatements(op, 1, 'front', 80, 'EDDIES')
		else effects, guard = underworld.Storage.BatchStatements(op, 'front', 100, 80, 'EDDIES', 60, 100) end
		if kind ~= 'collect' then
			local items = { id = 1, items = { [1] = { name = 'dirty_eddies', count = kind == 'mint' and 100 or 0 } } }
			if kind ~= 'mint' then items.items = {} end
			for _, statement in ipairs(inventory.Storage.MoneyStatements(items, op)) do effects[#effects + 1] = statement end
		end
		return assert(character.Storage.MoneyStatements(op, effects, guard).value)
	end
	local statements = plan()
	op.attempt = '22222222-2222-2222-2222-222222222222'
	output.cases[#output.cases + 1] = { name = name, underworld = kind, balance = 500, notes = 0,
		spent = kind == 'collect' and -80 or 0, statements = statements, replay = plan() }
end
underworldCase('underworld-mint', 'mint')
underworldCase('underworld-batch', 'batch')
underworldCase('underworld-collect', 'collect')
local function commerceCase(name, invoice, overflow)
	local op = { id = 'integration:' .. name, attempt = '11111111-1111-1111-1111-111111111111', citizenId = 'ECONTEST',
		moneyType = 'EDDIES', action = invoice and 'touch' or 'remove', amount = invoice and 0 or 100, reason = 'bar sale' }
	local function plan()
		local effects, guard = character.Storage.PeerStatements(op, 'SELLTEST', invoice and 0 or 25)
		local extra, extraGuard
		if invoice then
			extra, extraGuard = invoices.Storage.ServiceStatements(op, { state = 'unpaid', issuerCid = 'SELLTEST', issuerName = 'Staff',
				targetCid = 'ECONTEST', targetName = 'Customer', amount = 100, reason = 'Consented drink', account = { kind = 'job', key = 'test' },
				cutPct = 25, source = 'bar', issuedAt = 1760000000, expiresAt = 0 }, 3)
		else extra, extraGuard = business.Storage.WalletStatements(op, 'job', 'test', 75, true) end
		for _, statement in ipairs(extra) do effects[#effects + 1] = statement end
		guard = env.OPX.Storage.CombineGuards(guard, extraGuard)
		for _, bag in ipairs({ { id = 1, items = { [1] = { name = 'weapon_test', count = 1, metadata = { ammo = 9 } }, [2] = { name = 'water', count = 1 } } },
			{ id = 2, items = { [1] = { name = 'water', count = 2 } } } }) do
			for _, statement in ipairs(inventory.Storage.MoneyStatements(bag, op)) do effects[#effects + 1] = statement end
		end
		return assert(character.Storage.MoneyStatements(op, effects, guard).value)
	end
	local statements = plan()
	op.attempt = '22222222-2222-2222-2222-222222222222'
	output.cases[#output.cases + 1] = { name = name, balance = 500, notes = 0, peer = 40,
		peerCredit = invoice and 0 or 25, company = overflow and 9007199254740991 or 40, serviceInvoice = invoice,
		refused = overflow or false, statements = statements, replay = plan() }
end
commerceCase('bar-split', false, false)
commerceCase('bar-company-overflow', false, true)
commerceCase('bar-invoice', true, false)
local function mediaPlan(name, citizen, bagId, sale, replay)
	local op = { id = 'integration:' .. name, attempt = replay and '22222222-2222-2222-2222-222222222222' or '11111111-1111-1111-1111-111111111111',
		citizenId = citizen, moneyType = 'EDDIES', action = 'add', amount = sale.total, reason = 'media sale' }
	local effects, guard, before = media.Storage.SaleStatements(op, sale)
	local items = { id = bagId, items = { [1] = { name = 'weapon_test', count = 1, metadata = { ammo = 9 } } } }
	for _, statement in ipairs(inventory.Storage.MoneyStatements(items, op)) do effects[#effects + 1] = statement end
	if sale.funded == 'accounts' then
		local extra, eligibility = business.Storage.WalletStatements(op, 'job', 'test', sale.total, false)
		for _, statement in ipairs(extra) do effects[#effects + 1] = statement end
		guard = env.OPX.Storage.CombineGuards(guard, eligibility)
	end
	return assert(character.Storage.MoneyStatements(op, effects, guard, before).value)
end
local function mediaCase(name, funded, sellerCap, mintCap, stale, company)
	local scenes = {}
	for index = 1, 16 do scenes[index] = { x = index, y = 2, z = 3 } end
	local sale = { network = 'test-network', desk = 'test-network/desk', total = 100, funded = funded, revision = 0,
		sellerCap = sellerCap, mintCap = mintCap, scenes = scenes }
	output.cases[#output.cases + 1] = { name = name, balance = 500, notes = 0, media = true, mediaStale = stale or false,
		company = company or 400, spent = funded == 'mint' and not stale and sellerCap >= 100 and mintCap >= 100 and -100 or 0,
		refused = stale or sellerCap < 100 or (funded == 'mint' and mintCap < 100) or (company and company < 100) or false,
		statements = mediaPlan(name, 'ECONTEST', 1, sale), replay = mediaPlan(name, 'ECONTEST', 1, sale, true) }
end
mediaCase('media-mint', 'mint', 1000, 1000)
mediaCase('media-accounts', 'accounts', 1000, 1000)
mediaCase('media-seller-cap', 'mint', 50, 1000)
mediaCase('media-network-cap', 'mint', 1000, 50)
mediaCase('media-stale-quote', 'mint', 1000, 1000, true)
mediaCase('media-company-insufficient', 'accounts', 1000, 1000, false, 40)
for index, citizen in ipairs({ 'ECONTEST', 'SELLTEST' }) do
	for _, stale in ipairs({ false, true }) do
		local sale = { network = 'test-network', desk = stale and 'shared-desk' or 'desk-' .. index,
			total = 100, funded = 'mint', revision = 0, sellerCap = 1000, mintCap = stale and 1000 or 100,
			scenes = { { x = 1, y = 2, z = 3 } } }
		local key = stale and 'revision' or 'cap'
		output.mediaConcurrent[key] = output.mediaConcurrent[key] or {}
		output.mediaConcurrent[key][index] = mediaPlan('media-concurrent-' .. key .. index, citizen, index, sale)
	end
end
local function accountCase(name, method, source, target, amount)
	local op = { id = 'generic:' .. name, out = 'generic:' .. name .. ':out', into = 'generic:' .. name .. ':in',
		kind = 'job', group = 'test', from = { kind = 'job', group = 'test' },
		to = { kind = 'job', group = 'other' }, amount = amount, reason = 'integration', attempt = 'first-attempt' }
	local statements = business.Storage[method](op)
	op.attempt = 'second-attempt'
	output.companyCases[#output.companyCases + 1] = { name = name, balance = source, target = target,
		amount = amount, statements = statements, replay = business.Storage[method](op) }
end
accountCase('credit', 'CreditStatements', 400, 0, 100)
accountCase('debit', 'DebitStatements', 400, 0, 100)
accountCase('move', 'MoveStatements', 400, 100, 100)
accountCase('debit-insufficient', 'DebitStatements', 40, 0, 100)
accountCase('move-insufficient', 'MoveStatements', 40, 0, 100)
accountCase('credit-overflow', 'CreditStatements', 9007199254740991, 0, 1)
accountCase('move-overflow', 'MoveStatements', 400, 9007199254740991, 1)
for index = 1, 8 do
	local op = { id = 'concurrent:' .. index, attempt = 'attempt-' .. index, citizenId = 'ECONTEST',
		moneyType = 'EDDIES', action = 'add', amount = 1, reason = 'integration concurrent' }
	output.concurrent[index] = assert(character.Storage.MoneyStatements(op).value)
end
io.write(env.json.encode(output))
