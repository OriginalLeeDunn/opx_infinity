--- Economic regressions for nullable SQL values and asynchronous ownership.
-- @author dop42
--
-- Exercises the real storage and shop implementations with explicit suspension
-- effects: the connection changes citizen while a read or failed save returns.

local function result(value) return { ok = true, value = value } end
local function logger() end
local function sandbox(extra) return setmetatable(extra, { __index = _G }) end

-- Every SQL value must survive Lua array construction and the host marshaller.
do
	local transactions, notes = 0, 0
	local M = {}
	local function complete(query, values)
		local count = 0
		for _ in query:gmatch('%?') do count = count + 1 end
		assert(#values == count, 'statement lost a nullable positional parameter')
		for index = 1, count do assert(values[index] ~= nil, 'nil hole in statement values') end
	end
	local OPX = { Modules = { Get = function() return M end }, Storage = {
		Transaction = function(statements)
			for _, statement in ipairs(statements) do complete(statement.query, statement.values) end
			transactions = transactions + 1
			return result(true)
		end,
		Execute = function(sql, params)
			for name in sql:gmatch('@([%w_]+)') do assert(params[name] ~= nil, 'missing named nullable value') end
			if params.delta == 0 then assert(params.after == '0', 'zero balance must not compare numerically equal to the empty SQL sentinel') end
			notes = notes + 1
			return result(true)
		end,
	} }
	assert(loadfile('modules/business/server/storage.lua', 't', sandbox({ OPX = OPX })))()
	local op = { id = 'test', attempt = 'attempt-one', kind = 'job', group = 'ncpd', amount = 10, reason = 'test',
		out = 'test:out', into = 'test:in', from = { kind = 'job', group = 'ncpd' },
		to = { kind = 'job', group = 'trauma' } }
	assert(M.Storage.Credit(op).ok)
	assert(M.Storage.Debit(op).ok)
	assert(M.Storage.Move(op).ok)
	assert(M.Storage.Note(op).ok)
	op.amount, op.balance = 0, 0
	assert(M.Storage.Note(op).ok)
	assert(transactions == 3 and notes == 2)
end

-- The original payer receives an undo; delayed outfit data reaches nobody else.
do
	local citizen, charged, refunds, grants = 'original', 0, {}, 0
	local handlers, sent, wardrobe, readEffect = {}, {}, nil, nil
	local M = { Settings = { CHARGE = true, CURRENCY = 'EDDIES', SHOPS = {
		shop = { X = 10, Y = 0, Z = 0 } }, LOOKS = {
		uniform = { WEAR = { OuterChest = 'Items.Test' }, COST = 40 } } },
		Event = {}, SLOTS = { 'OuterChest' }, Prices = function() return {} end,
		Bill = function() return 40 end, IsSlot = function(slot) return slot == 'OuterChest' end,
		CleanCode = function(code) return code end }
	for _, name in ipairs({ 'OPEN', 'WEAR', 'SAVE', 'LIST', 'LOAD', 'DELETE', 'SHARE', 'REDEEM',
		'LOOKS', 'PUT_ON', 'SAVED', 'CODE' }) do M.Event[name] = name end
	local character = {
		GetPlayer = function() return { PlayerData = { citizenId = citizen } } end,
		RemoveMoney = function() charged = charged + 40; return true end,
		AddMoney = function() error('refund followed a connection instead of its payer') end,
		AddMoneyOffline = function(cid, _, amount) refunds[#refunds + 1] = { cid, amount }; return result(true) end,
	}
	local appearance = {
		OpenWardrobe = function(_, options) wardrobe = options; return true end,
		AllowClothingSave = function(_, _, options) grants = grants + 1; wardrobe = options; return true end,
		GetClothing = function() return result({ equipment = { OuterChest = 'Items.Test' } }) end,
		PricedRoom = function() return 'shops:shop' end,
	}
	local OPX = { Modules = { Get = function() return M end }, Api = { Get = function(name)
		return name == 'character' and character or appearance end },
		Schema = { Add = logger }, Spots = { ServerReach = function(radius) return radius end },
		Life = { Down = function() return false end }, NotifyLocale = logger,
		String = { Trim = function(s) return s end }, Text = { Bytes = function(s) return s end },
		Table = { Count = function(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end },
		Event = function() return 'deleted' end, Channel = { INTERNAL = 'internal' }, Cooling = function() return false end,
		Storage = { Decode = function(value) return value end }, Locale = { Money = tostring } }
	local env = sandbox({ OPX = OPX, locale = function(key) return key end,
		Open77 = { players = { position = function() return { x = 10, y = 0, z = 0, bucket = 0 } end },
			log = { error = logger, warn = logger, info = logger } },
		RegisterNetEvent = function(name, fn) handlers[name] = fn end, AddEventHandler = logger,
		TriggerClientEvent = function(name) sent[#sent + 1] = name end, CreateThread = function(fn) fn() end,
		json = { encode = function(value) return value end } })
	assert(loadfile('modules/shops/server/main.lua', 't', env))()
	M.Storage = { SCHEMA = {} }
	local record = { outfit_id = 1, name = 'old outfit', look = { equipment = { OuterChest = 'Items.Test' } }, share_code = 'CODE' }
	for _, name in ipairs({ 'List', 'Count', 'Save', 'Own', 'Delete', 'SetCode', 'ByCode' }) do
		M.Storage[name] = function()
			if readEffect then readEffect() end
			return result(name == 'List' and { record } or (name == 'Count' and 0 or record))
		end
	end
	M.Init(); M.Start(); env.source = 1
	handlers.OPEN('shop')
	local ok, _, quote = wardrobe.charge(1, { 'OuterChest' })
	assert(ok and charged == 0 and type(quote) == 'table' and quote.amount == 40 and quote.moneyType == 'EDDIES')
	assert(#refunds == 0, 'a price quote moved money before the outfit transaction')
	citizen = 'original'
	handlers.WEAR({ shop = 'shop', look = 'uniform' })
	ok, _, quote = wardrobe.bill(1)
	assert(ok and type(quote) == 'table' and quote.amount == 40 and charged == 0)
	assert(#refunds == 0, 'uniform quote created a compensating payment')
	for _, event in ipairs({ 'LOAD', 'LIST', 'SHARE', 'REDEEM', 'SAVE' }) do
		citizen = 'original'; sent = {}; local before = grants
		readEffect = function() citizen = 'replacement' end
		handlers[event]({ id = 1, shop = 'shop', code = 'CODE', name = 'test' })
		assert(#sent == 0 and grants == before, 'delayed ' .. event .. ' leaked an outfit or a clothing grant')
	end
end
print('economy SQL and shop ownership regression checks passed')

-- The manifest-backed checks retain real contracts and the host's scheduler.
local Host = dofile('tests/host.lua')
local function boot()
	local env, control = Host.Environment('server')
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do
		assert(loadfile(file, 't', env))()
	end
	control.Pump(240)
	return env, control
end

do
	local env, control = boot()
	local OPX, source = env.OPX, 901
	local inventory = OPX.Modules.Get('inventory')
	local holder = 'original'
	local character = { GetPlayer = function() return { PlayerData = { citizenId = holder } } end }
	inventory.Contracts.character = character
	local bag = inventory.Containers.Transient(inventory.KIND.CHARACTER, holder, 10, 10000)
	inventory.Players.Attach(source)
	assert(inventory.Players.Bag(source) == bag)
	holder = 'replacement'
	assert(inventory.Players.Bag(source) == nil, 'cached bag survived a replacement citizen')
	holder = 'original'
	local load = inventory.Containers.Load
	inventory.Containers.Load = function(...)
		local found = load(...)
		holder = 'replacement'
		return found
	end
	assert(inventory.Players.Bag(source) == nil, 'bag identity was not rechecked after its load')
	inventory.Containers.Load = load
end

do
	local env, control = boot()
	local OPX = env.OPX
	local inventory = OPX.Modules.Get('inventory')
	local holder = { [901] = 'giver', [902] = 'receiver' }
	inventory.Contracts.character = { GetPlayer = function(source)
		return { PlayerData = { citizenId = holder[source] } }
	end }
	for _, source in ipairs({ 901, 902 }) do
		control.Admit(source, 'account-' .. source)
		OPX.EnsureSession(source)
		control.Stand(source, 1, 1, 1)
		inventory.Containers.Transient(inventory.KIND.CHARACTER, holder[source], 10, 10000)
		inventory.Players.Attach(source)
	end
	local bag = inventory.Players.Bag(901)
	inventory.Containers.Add(bag, 'bandage', 1)
	assert(inventory.Actions.Give(901, 902, 1, 1))
	inventory.Actions.Forget(902)
	control.Advance(3100)
	local ok, why = inventory.Actions.Give(901, 902, 1, 1)
	assert(ok, 'receiver-only logout left an incoming offer held: ' .. tostring(why))
end

do
	local env = boot()
	local OPX = env.OPX
	local crafting = OPX.Modules.Get('crafting')
	local api = OPX.Api.Get('crafting')
	assert(api.RegisterBench('audit:queue', { owner = 'audit', queue = 3,
		recipes = { { KEY = 'rounds', OUTPUT = 'ammo_handgun', SECONDS = 60, INPUTS = { scrap_metal = 1 } } } }).ok)
	local tail, items, waits, fail = 0, 5, true, false
	crafting.Contracts.character = {
		GetPlayer = function() return { PlayerData = { citizenId = 'queue-owner' } } end,
		GetMoney = function() return {} end,
	}
	crafting.Contracts.inventory = {
		GetItemCount = function() return OPX.Result.Ok(items) end,
		RemoveItem = function() items = items - 1; return OPX.Result.Ok(true) end,
		AddItem = function() items = items + 1; return OPX.Result.Ok(true) end,
	}
	crafting.Storage.Shelf = function()
		if fail then error('shelf unavailable') end
		if waits then coroutine.yield() end
		return OPX.Result.Ok({ cooking = 0, tail = tail })
	end
	local placed = {}
	crafting.Contracts.inventory.AtomicTrade = function(cid, _, delta, changes, _, _, participant)
		assert(delta == 0 and changes[1].name == 'scrap_metal' and changes[1].count == -1)
		local op = { id = 'queue-' .. tostring(items), attempt = 'attempt', citizenId = cid }
		local effects, guard = participant(op)(op)
		assert(guard and guard.values[3] == 3 and effects[1].query:find('MAX(ready_at)', 1, true))
		tail, items = tail + effects[1].values[4], items - 1
		placed[op.id] = tail
		return OPX.Result.Ok({})
	end
	crafting.Storage.Placed = function(_, token) return OPX.Result.Ok(placed[token]) end
	local first
	local thread = coroutine.create(function() first = api.Order(1, 'audit:queue', 'rounds') end)
	assert(coroutine.resume(thread))
	local raced = api.Order(1, 'audit:queue', 'rounds')
	assert(not raced.ok and raced.error == 'too_fast' and items == 5, 'concurrent order reused a stale queue tail')
	assert(coroutine.resume(thread))
	assert(first.ok and tail == 60 and items == 4)
	waits = false
	local nextOrder = api.Order(1, 'audit:queue', 'rounds')
	assert(nextOrder.ok and tail == 120, 'the next order did not queue after the committed tail')
	fail = true
	assert(not api.Order(1, 'audit:queue', 'rounds').ok)
	fail = false
	assert(api.Order(1, 'audit:queue', 'rounds').ok, 'a raised order leaked its queue lock')
end
print('economy cached-bag, receiver logout and crafting queue regression checks passed')

-- Recruiting rereads authority after its roster query, and serializes capacity.
do
	local env, control = boot()
	local OPX = env.OPX
	local business = OPX.Modules.Get('business')
	local A = business.Access
	local people = {
		[901] = { source = 901, citizenId = 'boss', boss = true, job = { name = 'test', grade = 3 } },
		[902] = { source = 902, citizenId = 'recruit-a' },
		[903] = { source = 903, citizenId = 'recruit-b' },
	}
	for source in pairs(people) do control.Stand(source, 1, 1, 1) end
	local rosterEffect, hired = nil, 0
	local character = {
		GetPlayer = function(source) return people[source] and { PlayerData = people[source] } end,
		GetPlayerByCitizenId = function() return nil end,
		GetGroupMembers = function()
			if rosterEffect then rosterEffect() end
			return OPX.Result.Ok({})
		end,
		SetJob = function() hired = hired + 1; return OPX.Result.Ok(true) end,
		AddPlayerToJob = function() hired = hired + 1; return OPX.Result.Ok(true) end,
	}
	local originalGet = OPX.Api.Get
	OPX.Api.Get = function(name) return name == 'character' and character or originalGet(name) end
	A.ValidGroup = function() return true end
	A.Standing = function(data) return data.boss and 3 or nil end
	A.MayOpen = function() return true end
	A.MayHire = function() return true end
	A.IsBoss = function(_, _, level) return level == 3 end
	A.Grade = function() return { name = 'test' } end
	A.MayGrant = function() return true end
	A.Rules = function() return { maxEmployees = 1, hireGrade = 0 } end
	A.Label = function() return 'test' end
	A.REQUIRE_OFFICE = false
	rosterEffect = function() people[901].boss = false end
	local ok = business.Server.Hire(901, 'job', 'test', 902)
	assert(not ok and next(business.Server.Offers()) == nil, 'demoted boss issued a hire after roster yielded')
	people[901].boss = true
	rosterEffect = nil
	assert(business.Server.Hire(901, 'job', 'test', 902))
	assert(business.Server.Hire(901, 'job', 'test', 903))
	local ids = {}
	for id, offer in pairs(business.Server.Offers()) do ids[offer.target] = id end
	rosterEffect = function() coroutine.yield() end
	local first
	local thread = coroutine.create(function() first = business.Server.Answer(902, ids[902], true) end)
	assert(coroutine.resume(thread))
	local accepted, code = business.Server.Answer(903, ids[903], true)
	assert(not accepted and code == 'busy' and hired == 0, 'two recruits shared a headcount reservation')
	rosterEffect = nil
	assert(coroutine.resume(thread))
	assert(first and hired == 1)
end

-- A boot locked while its container loads must not accept a mutation.
do
	local env = boot()
	local inventory = env.OPX.Modules.Get('inventory')
	local locked = false
	inventory.World.TrunkLocked = function() return locked end
	inventory.World.VehicleContainer = function()
		locked = true
		return inventory.Containers.Transient(inventory.KIND.TRUNK, 'audit-trunk', 10, 10000)
	end
	local answer = inventory.AddToTrunk(99, 'bandage', 1)
	assert(not answer.ok and answer.error == 'locked', 'trunk lock changed during load but mutation proceeded')
end
print('economy recruiting authority, capacity and trunk-load regressions passed')

do
	local env = boot()
	local inventory = env.OPX.Modules.Get('inventory')
	local owner, viewed = 'original', false
	inventory.Players.MayAct = function() return true end
	inventory.Players.Bag = function() return { owner = owner } end
	inventory.World.Stash = function()
		owner = 'replacement'
		return { id = 'audit-stash' }
	end
	inventory.Containers.View = function() viewed = true end
	local answer = inventory.OpenStash(901, 'audit-stash')
	assert(not answer.ok and answer.error == 'not_loaded' and not viewed,
		'stash loaded for a former citizen was opened for their replacement')
end
print('economy stash load ownership regression passed')

-- Key ownership reads may suspend: the lock still requires the same person nearby.
do
	local env, control = boot()
	local OPX = env.OPX
	local keys = OPX.Modules.Get('vehiclekeys')
	local owner, effect, writes = 'original', nil, 0
	local character = { GetPlayer = function() return { PlayerData = { citizenId = owner } } end }
	local inventory = {
		CountWhere = function() if effect then effect() end; return OPX.Result.Ok(1) end,
		RegisterUsable = function() return true end,
	}
	local vehicles = { PlateOf = function() return 'AUDIT', 'original' end }
	local originalGet = OPX.Api.Get
	OPX.Api.Get = function(name)
		if name == 'character' then return character end
		if name == 'inventory' then return inventory end
		if name == 'vehicles' then return vehicles end
		return originalGet(name)
	end
	env.Open77.vehicles.get = function() return { record = 'Vehicle.Test', x = 1, y = 1, z = 1, bucket = 0 } end
	env.Open77.vehicles.getPlayerSeat = function() return nil end
	env.Open77.vehicles.isLocked = function() return false end
	env.Open77.vehicles.setLocked = function() writes = writes + 1; return true end
	keys.Start()
	control.Stand(901, 1, 1, 1)
	effect = function() control.Stand(901, 100, 1, 1) end
	local answer = keys.Toggle(901, 99)
	assert(not answer.ok and answer.error == 'vehiclekeys.tooFar' and writes == 0)
	control.Stand(901, 1, 1, 1)
	effect = function() owner = 'replacement' end
	answer = keys.Toggle(901, 99)
	assert(not answer.ok and answer.error == 'vehiclekeys.noKey' and writes == 0)
end
print('economy vehicle-key delayed ownership/reach regressions passed')
