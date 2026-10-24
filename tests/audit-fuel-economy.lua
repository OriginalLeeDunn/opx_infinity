--- Real can purchase/AtomicTrade flow; durable storage is an explicit double.
-- Pump/native fuel changes are outside this SQL transaction and need live tests.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('server')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'server')) do
	assert(loadfile(file, 't', env))()
	if file == 'config/fuel.lua' then
		env.OPX.Config.MODULES.fuel.STATIONS.audit = { LABEL = 'Audit pump', X = 100, Y = 10, Z = 1,
			PUMPS = { { X = 100, Y = 10, Z = 1 } } }
	end
end
dofile('tests/money-store.lua').Install(env)
control.Pump(400)
local OPX = env.OPX
local C, I, F = OPX.Modules.Get('character'), OPX.Modules.Get('inventory'), OPX.Modules.Get('fuel')
F.Stop(); control.Pump(10)
local source, account = 731, 'fuel-economy-account'
control.Admit(source, account); control.Stand(source, 100, 10, 1); OPX.EnsureSession(source)
local player = C.CreatePlayer({ source = source, userId = account, citizenId = OPX.CitizenId.Generate(),
	money = { EDDIES = 500, BANK = 0 } }, false)
C.RegisterPlayer(player)
local bag = I.Containers.Transient(I.KIND.CHARACTER, player.PlayerData.citizenId, 30, 100000)
bag.transient = nil; I.Players.Attach(source)
local function up(fn, key)
	for index = 1, 100 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == key then return value end
	end
	error('missing ' .. key)
end
local sessions = up(F.CanBuy, 'sessions')
local progress, bars = OPX.Api.Get('progress'), 0
local start = progress.Start
progress.Start = function() bars = bars + 1; return OPX.Result.Ok({ id = bars }) end
local function begin(refill)
	control.Advance(1000)
	local ok, code = F.CanBuy(source, { method = 'EDDIES', refill = refill })
	assert(ok, code)
	local session = assert(sessions[source]); sessions[source] = nil
	return session
end
local function count() return I.Containers.CountIn(bag, 'petrolcan') end
local function can()
	for slot, item in pairs(bag.items) do if item.name == 'petrolcan' then return slot, item end end
end
local change, lose = C.Storage.MoneyChange, true
C.Storage.MoneyChange = function(...)
	local result = change(...)
	if result.ok and lose then lose = false; error('lost can transaction acknowledgement') end
	return result
end
local purchased = begin(false)
assert(not F.Purchased(source, purchased, { completed = true }))
assert(purchased.operationId and purchased.purchaseDispatched)
assert(count() == 0 and player.PlayerData.money.EDDIES == 500 and bag.economicLock)
assert(not F.Purchased(source, purchased, { completed = true }), 'duplicate progress callback started a second purchase')
control.Pump(40)
assert(count() == 1 and player.PlayerData.money.EDDIES == 400 and not bag.economicLock)
C.Storage.MoneyChange = change
local slot = can()
assert(I.Containers.SetMetadata(bag, slot, { durability = 25, ammo = 25, serial = 'can-original', note = 'kept' }))
local stale = begin(true)
assert(I.Containers.SetMetadata(bag, slot, { durability = 25, ammo = 25, serial = 'can-replacement', note = 'kept' }))
assert(not F.Purchased(source, stale, { completed = true }))
assert(player.PlayerData.money.EDDIES == 400 and select(2, can()).metadata.durability == 25)
local refill = begin(true)
lose = true
C.Storage.MoneyChange = function(...)
	local result = change(...)
	if result.ok and lose then lose = false; error('lost refill acknowledgement') end
	return result
end
assert(not F.Purchased(source, refill, { completed = true }))
assert(count() == 1 and select(2, can()).metadata.durability == 25 and player.PlayerData.money.EDDIES == 400)
control.Pump(40)
C.Storage.MoneyChange = change
local full = select(2, can()).metadata
assert(count() == 1 and full.durability == 100 and full.ammo == 100 and full.serial == 'can-replacement' and full.note == 'kept')
assert(player.PlayerData.money.EDDIES == 340)
-- Moving away while the inventory save fence yields must not charge or hand over.
local moved = begin(false)
local fence = I.Storage.EconomicFence
I.Storage.EconomicFence = function(...)
	local version, why = fence(...)
	control.Stand(source, 500, 10, 1)
	return version, why
end
assert(not F.Purchased(source, moved, { completed = true }))
assert(player.PlayerData.money.EDDIES == 340 and count() == 1 and not bag.economicLock)
I.Storage.EconomicFence = fence
control.Stand(source, 100, 10, 1)
-- An account/session replacement with the same player object must still refuse.
local swapped = begin(false)
local ownerSession = OPX.Sessions[source]
OPX.Sessions[source] = OPX.Table.DeepCopy(ownerSession)
assert(not F.Purchased(source, swapped, { completed = true }))
assert(player.PlayerData.money.EDDIES == 340 and count() == 1)
OPX.Sessions[source] = ownerSession
-- A character change during the yielding preflight must not start a new bar.
local api = OPX.Api.Get('inventory')
local carry, beforeBars = api.CanCarry, bars
local replacement
api.CanCarry = function(...)
	local result = carry(...)
	C.UnregisterPlayer(player)
	replacement = C.CreatePlayer({ source = source, userId = account, citizenId = OPX.CitizenId.Generate(),
		money = { EDDIES = 1000, BANK = 0 } }, false)
	C.RegisterPlayer(replacement)
	return result
end
control.Advance(1000)
assert(not F.CanBuy(source, { method = 'EDDIES' }))
assert(bars == beforeBars and replacement.PlayerData.money.EDDIES == 1000 and player.PlayerData.money.EDDIES == 340)
api.CanCarry = carry
progress.Start = start
print('fuel economy: atomic buy/refill, lost replies, exact metadata, duplicate callbacks and pinned buyer/session passed')
