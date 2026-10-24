--- Recovery rejects replay, stale proximity and replacement characters.
-- @author dop42
local M = { ITEM = 'electronic_waste', PREFIX = 'salvage:', Event = { COLLECT = 'collect', NOTICE = 'notice' } }
local time, epoch, cid, session, grants, callback = 0, 1000, 'citizen-a', 'session-a', 0, nil
local store, tasks, notices, benches = {}, {}, {}, {}
local snap = { fresh = true, bucket = 0, position = { x = 10, y = 20, z = 30 } }
local inventory = {
	RegisterItem = function() return { ok = true } end,
	CanCarry = function() return { ok = true, value = true } end,
	AddItem = function(owner) assert(owner == 'citizen-a'); grants = grants + 1; return { ok = true } end,
}
local services = {
	character = { GetPlayer = function() return cid and { PlayerData = { citizenId = cid } } end },
	inventory = inventory,
	progress = { Start = function(_, _, _, fn) callback = fn; return { ok = true } end },
	crafting = { RegisterBench = function(key, definition) benches[key] = definition; return { ok = true } end,
		UnregisterBenches = function() end },
}
local OPX = {
	Modules = { Get = function() return M end },
	Config = { MODULES = { salvage = { REACH = 2.5, DURATION_MS = 8000, COOLDOWN_SECONDS = 300,
		SITES = { test = { pickup = { x = 10, y = 20, z = 30, bucket = 0 }, bench = { x = 40, y = 50, z = 60, bucket = 0 } } } } } },
	Spots = { Coordinate = tonumber, Integer = math.tointeger }, Math = { Finite = tonumber },
	Api = { Get = function(key) return services[key] end }, Life = { Down = function() return false end },
	Sessions = { [7] = session }, Now = function() return time end, Cooling = function() return false end,
}
local env = setmetatable({ OPX = OPX, locale = function(key) return key end,
	CreateThread = function(fn) tasks[#tasks + 1] = fn end,
	RegisterNetEvent = function() end,
	TriggerClientEvent = function(_, _, code) notices[#notices + 1] = code end,
	Open77 = { players = { get = function() return snap end }, time = { unix = function() return epoch end },
		log = { error = error, warn = function() end }, kvp = {
			get = function(key, fallback) if store[key] == nil then return fallback end; return store[key] end,
			setIfAbsent = function(key, value) if store[key] == nil then store[key] = value; return true end; return false end,
			compareAndSet = function(key, before, after) if store[key] ~= before then return false end; store[key] = after; return true end,
		} },
}, { __index = _G })
assert(loadfile('modules/salvage/shared/model.lua', 't', env))()
assert(loadfile('modules/salvage/server/main.lua', 't', env))()
M.Init(); M.Start()
assert(#benches['salvage:test'].recipes == 2, 'public bench has no recipes')
M.Server.Collect(7, 'test'); assert(callback)
local first = callback
first(7, { completed = true })
assert(#tasks == 0, 'client finished collection before server deadline')
M.Server.Collect(7, 'test'); time = 8000
first = callback
first(7, { completed = true }); first(7, { completed = true })
assert(#tasks == 1, 'duplicate progress callback enqueued duplicate grants')
tasks[1](); assert(grants == 1 and store['salvage.stock.test'] == 1300)
callback = nil; M.Server.Collect(7, 'test')
assert(callback == nil and notices[#notices] == 'busy', 'depleted stock was collectible')
M.Init(); M.Start(); M.Server.Collect(7, 'test')
assert(callback == nil, 'restart reset persistent depletion')
epoch, time = 1400, 20000
M.Server.Collect(7, 'test'); assert(callback)
time, cid = 28000, 'citizen-b'
callback(7, { completed = true }); assert(#tasks == 1 and grants == 1, 'replacement character received collection')
cid = 'citizen-a'; callback = nil; snap.fresh = false
M.Server.Collect(7, 'test'); assert(callback == nil, 'stale position admitted recovery')
snap.fresh = true; snap.bucket = 2
M.Server.Collect(7, 'test'); assert(callback == nil, 'wrong bucket admitted recovery')
snap.bucket = 0; snap.position.x = 100
M.Server.Collect(7, 'test'); assert(callback == nil, 'remote recovery admitted')
snap.position.x = 10
M.Server.Collect(7, 'test'); time = 36000
callback(7, { completed = true }); assert(#tasks == 2)
store['salvage.stock.test'] = 1900
tasks[2](); assert(grants == 1, 'lost persistent compare-and-set still granted stock')
print('salvage audit passed')

-- Boot the actual manifest and register against the actual inventory/crafting
-- contracts: a stub accepting an invalid recipe shape would miss a dead feature.
local Host = dofile('tests/host.lua')
local real, control = Host.Environment('server')
for _, path in ipairs(Host.LoadOrder('open77.lua', 'server')) do
	assert(loadfile(path, 't', real))()
end
dofile('tests/money-store.lua').Install(real)
control.Pump(240)
assert(real.OPX.Modules.IsRunning('salvage'), 'salvage failed manifest boot')
local catalog = real.OPX.Api.Get('inventory').GetItem('electronic_waste')
assert(catalog ~= nil, 'recovery item was not registered')
local crafting = real.OPX.Modules.Get('crafting')
assert(crafting.Recipes, 'real recipe validator unavailable')
local registered = real.OPX.Api.Get('crafting').Benches()
local public
for _, bench in ipairs(registered.value) do if bench.key == 'salvage:mechanic_recovery' then public = bench end end
assert(public and public.recipes == 2 and public.anchored, 'real recycling workbench was not registered')
local definition = benches['salvage:test']
for _, recipe in ipairs(definition.recipes) do
	local accepted, why = crafting.Recipes.Recipe(recipe.KEY, recipe)
	assert(accepted, why)
end
assert(control.kvp['salvage.stock.mechanic_recovery'] == 0, 'real boot did not initialise persistent stock')
assert(real.Open77.kvp.compareAndSet('typed-test', nil, 1))
assert(not real.Open77.kvp.compareAndSet('typed-test', 1.0, 2), 'host CAS ignored numeric type')
print('salvage manifest integration passed')

-- Real progress, inventory and crafting contracts, with only the SQL boundary
-- replaced by a deterministic shelf. SQL persistence itself has separate tests.
local sourceId, durable = 901, real.OPX.CitizenId.Generate()
control.Admit(sourceId, 'salvage-account')
local character = real.OPX.Modules.Get('character')
local player = character.CreatePlayer({ source = sourceId, userId = 'salvage-account', citizenId = durable,
	charInfo = { firstName = 'Test', lastName = 'Salvage' }, money = { EDDIES = 0, BANK = 0 } }, false)
character.RegisterPlayer(player)
local invmodule = real.OPX.Modules.Get('inventory')
local bag = invmodule.Containers.Transient(invmodule.KIND.CHARACTER, durable, 10, 10000)
bag.transient = nil
invmodule.Players.Attach(sourceId)
control.Stand(sourceId, -2456.16, -909.03, 9.26)
real.OPX.Modules.Get('salvage').Server.Collect(sourceId, 'mechanic_recovery')
local bar = real.OPX.Api.Get('progress').State(sourceId)
assert(bar.ok and bar.value, 'real recovery did not start server progress')
control.Advance(8000)
real.source = sourceId
control.netEvents['opx:net:progress:report'](bar.value.id, 'finished')
control.Pump(8)
local inv = real.OPX.Api.Get('inventory')
assert(inv.GetItemCount(sourceId, 'electronic_waste').value == 1, 'real recovery did not put waste in inventory')
control.Stand(sourceId, -2043.13, -602.83, 2.84)
local row
crafting.Storage.Shelf = function() return real.OPX.Result.Ok({ cooking = row and 1 or 0, tail = 0 }) end
local boundary = character.Storage.UnitMoney
boundary.OnGuard = function(guard)
	if guard.error == 'queue_full' then return not row end
	if guard.error == 'no_such_order' then return row and row.remaining <= 0 end
	return true
end
boundary.OnCommit = function(op, effects)
	for _, effect in ipairs(effects or {}) do
		if effect.query:find('INSERT INTO opx77_crafting_orders', 1, true) then
			local values = effect.values
			row = { id = 1, citizenId = values[1], bench = values[2], recipe = values[3], remaining = 30, token = values[5] }
		elseif effect.query:find('DELETE FROM opx77_crafting_orders', 1, true) then row = nil end
	end
end
crafting.Storage.Placed = function(owner, token) return real.OPX.Result.Ok(row and row.citizenId == owner and row.token == token and row.id or nil) end
crafting.Storage.Find = function(owner, id)
	return real.OPX.Result.Ok(row and row.citizenId == owner and row.id == id and row or nil)
end
local result
real.CreateThread(function() result = real.OPX.Api.Get('crafting').Order(sourceId, 'salvage:mechanic_recovery', 'circuits') end)
control.Pump(8)
assert(result and result.ok, 'real crafting rejected recycling: ' .. tostring(result and result.error))
assert(inv.GetItemCount(sourceId, 'electronic_waste').value == 0, 'recycling did not consume waste')
assert(real.OPX.Api.Get('crafting').Collect(sourceId, 1).error == 'not_ready', 'recycling paid before deadline')
row.remaining = 0
real.CreateThread(function() result = real.OPX.Api.Get('crafting').Collect(sourceId, 1) end)
control.Pump(8)
assert(result and result.ok, 'real crafting could not collect recycled circuits')
assert(inv.GetItemCount(sourceId, 'electronics').value == 1, 'recycling did not feed existing electronics item')
assert(not real.OPX.Api.Get('crafting').Collect(sourceId, 1).ok, 'same recycling order collected twice')
print('salvage real inventory/progress/crafting pipeline passed')

OPX.Config.MODULES.salvage.SITES = 'broken'
assert(#M.Model.Sites() == 0, 'malformed sites raised or admitted a source')
OPX.Config.MODULES.salvage = false
assert(#M.Model.Sites() == 0, 'malformed settings raised or admitted a source')

local client, clientControl = Host.Environment('client')
for _, path in ipairs(Host.LoadOrder('open77.lua', 'client')) do
	assert(loadfile(path, 't', client))()
end
clientControl.Fire('onClientResourceStart', 'opx_infinity')
clientControl.Pump(240)
assert(client.OPX.Modules.IsRunning('salvage'), 'client recovery module did not boot')
local clientSalvage = client.OPX.Modules.Get('salvage')
clientSalvage.Stop()
local thread = coroutine.create(clientSalvage.Start)
local cost, peak = 0, 0
debug.sethook(thread, function() cost = cost + 1 end, '', 1)
while coroutine.status(thread) ~= 'dead' do
	cost = 0
	local ok, why = coroutine.resume(thread)
	assert(ok, why)
	peak = math.max(peak, cost)
end
debug.sethook(thread)
assert(peak < 5000, 'client recovery registration exceeded resume budget: ' .. peak)
print('salvage client registration worst resume: ' .. peak .. ' instructions')
