--- Queued service requests and wardrobe writes keep their original character.
local function load(path, env) assert(loadfile(path, 't', setmetatable(env, { __index = _G })))() end
local function setup(name)
	local handlers, threads = {}, {}
	local identity = { user = 'first', cid = 'FIRST', session = {} }
	local M = { Settings = {}, Event = {}, Command = {}, Point = { DUTY = 'duty' }, Access = {} }
	local character = {
		GetPlayer = function() return { PlayerData = { citizenId = identity.cid } } end,
	}
	local contracts = { character = character, inventory = {} }
	local env = {
		OPX = { Modules = { Get = function() return M end },
			Api = { Get = function(key) return contracts[key] end },
			UserIdOf = function() return identity.user end, Sessions = { [7] = identity.session },
			Host = { PLAYER_DISCONNECTED = 'disconnect', VEHICLE_REMOVED = 'removed' },
			Channel = { LOCAL = 'local' }, Event = function() return 'used' end,
			Config = { MODULES = {} }, Command = { Register = function() end },
			Locale = { Exists = function() return true end }, NotifyLocale = function() end,
			Cooling = function() return false end, Audit = { Log = function() end }, Publish = function() end,
		},
		Open77 = { log = { info = function() end, warn = function() end } },
		RegisterNetEvent = function(event, fn) handlers[event] = fn end,
		AddEventHandler = function(event, fn) handlers[event] = fn end,
		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		source = 7, locale = function(key) return key end,
	}
	local events = name == 'bar' and { 'COUNTER', 'MIX', 'STASH', 'SUPPLY', 'BUY', 'SERVE_MENU', 'SERVE' }
		or { 'DUTY', 'ASK', 'WEAR', 'CIVVIES', 'SPAWN', 'RETURN' }
	for _, event in ipairs(events) do M.Event[event] = event end
	M.Event.IN_LOADED, M.Event.IN_UNLOADED, M.Event.ON_JOB = 'loaded', 'unloaded', 'job'
	M.Model = { ID_MAX = 48, Read = function() return { problems = {}, placeholders = {},
		venueList = {}, itemList = {}, recipeList = {} } end }
	M.Access.Build = function() return { problems = {}, placeholders = {},
		stations = { station = { key = 'station', bucket = 0, points = { wardrobe = {} } } },
		wardrobe = { metadata = 'uniform' } } end
	M.Access.Key = function() return true end
	M.Access.Reaches = function() return true end
	load('modules/' .. name .. '/server/main.lua', env)
	M.Init()
	return M, env, identity, character, contracts, handlers, threads
end

for _, name in ipairs({ 'bar', 'workplace' }) do
	local M, env, id, _, _, handlers, threads = setup(name)
	local executed = 0
	local key = name == 'bar' and 'COUNTER' or 'SPAWN'
	M[name == 'bar' and 'Counter' or 'Spawn'] = function() executed = executed + 1 end
	M.Start()
	local function request(change)
		id.user, id.cid = 'first', 'FIRST'
		env.OPX.Sessions[7] = id.session
		local before = executed
		handlers[key](name == 'bar' and 'venue' or {})
		change()
		assert(coroutine.resume(threads[#threads]))
		return executed - before
	end
	assert(request(function() end) == 1, name .. ': valid request dropped')
	assert(request(function() id.user = 'other' end) == 0, name .. ': request crossed accounts')
	assert(request(function() env.OPX.Sessions[7] = {} end) == 0, name .. ': request crossed sessions')
	assert(request(function() id.cid = 'SECOND' end) == 0, name .. ': request crossed characters')
end

local M, env, id, character, contracts = setup('workplace')
local cleared
character.GetMetadata = function() return { job = 'job', clothing = {} } end
character.SetMetadata = function(target) cleared = target; return true end
contracts.appearance = { GetClothing = function() end, SaveClothing = function(target)
	assert(target == 'FIRST', 'wardrobe save used a recyclable slot')
	coroutine.yield()
	return { ok = true }
end }
env.OPX.Math = { Finite = function(value) return value end }
env.Open77.players = { position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end }
local task = coroutine.create(function() M.Civvies(7, { station = 'station' }) end)
assert(coroutine.resume(task))
assert(coroutine.status(task) == 'suspended')
id.cid = 'SECOND'
assert(coroutine.resume(task))
assert(cleared == 'FIRST', 'wardrobe completion cleared the replacement character metadata')

local workplace, _, changed, jobCharacter, jobContracts, jobHandlers, jobThreads = setup('workplace')
local restored = 0
jobCharacter.GetMetadata = function() return { job = 'old_job', clothing = {} } end
jobCharacter.SetMetadata = function() return true end
jobContracts.appearance = { GetClothing = function() end, SaveClothing = function()
	restored = restored + 1
	return { ok = true }
end }
workplace.Start()
jobHandlers.job(7, { job = { name = 'different' } })
assert(#jobThreads == 1, 'job change did not enqueue its restoration')
changed.cid = 'REPLACEMENT'
assert(coroutine.resume(jobThreads[1]))
assert(restored == 0, 'old job change restored the replacement character uniform')

local bar, barEnv, _, barCharacter, barContracts = setup('bar')
local customerCid = 'CUSTOMER'
local bartenderData, customerData = { citizenId = 'BARTENDER' }, { citizenId = 'CUSTOMER' }
barCharacter.GetPlayer = function(player)
	customerData.citizenId = customerCid
	return { PlayerData = player == 7 and bartenderData or customerData }
end
local charged, given, removed
barContracts.inventory.GetItemCount = function() return { ok = true, value = 1 } end
barContracts.inventory.AtomicPeerTrade = function(seller, buyer, _, _, _, _, _, options)
	assert(seller == 'BARTENDER' and buyer == 'CUSTOMER', 'trade lost its pinned characters')
	coroutine.yield() -- a save fence yields before participant validation
	local build, why = options.participant({})
	if not build then return { ok = false, error = why } end
	removed, charged, given = seller, buyer, buyer
	return { ok = true }
end
barEnv.OPX.EnsureSession = function(player) return barEnv.OPX.Sessions[player] end
barEnv.OPX.Now = function() return 0 end
barEnv.OPX.Math = { Finite = function(value) return value end }
barEnv.OPX.Spots = { ServerReach = function(value) return value end }
barEnv.OPX.Sessions[8] = {}
barEnv.TriggerClientEvent = function() end
barEnv.Open77.players = { position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end }
barEnv.Open77.playerInteractions = { request = function() return { id = 'sale' } end }
bar.Allowed = function() return true end
bar.Model.Split = function(price) return price, 0 end
local venue = { id = 'venue', label = 'venue', counter = { x = 0, y = 0, z = 0 },
	bucket = 0, prices = { drink = 10 } }
bar.S.venues = { venue = venue }
bar.S.venueList = { venue }
bar.S.items = { drink = { label = 'drink' } }
bar.S.serveRadius, bar.S.serveReach = 5, 5
bar.S.serve = { breakDistance = 5 }
bar.S.reach = 5
bar.S.billing, bar.S.money = 'direct', 'BANK'
bar.Start()
assert(bar.Serve(7, 8, 'drink'))
local sale = coroutine.create(function() local ok, why = bar.Complete('sale'); assert(not ok and why == 'left', tostring(why)) end)
assert(coroutine.resume(sale))
customerCid = 'REPLACEMENT'
assert(coroutine.resume(sale))
assert(removed == nil and charged == nil and given == nil,
	'sale moved drinks or money through a recycled player slot')
print('audit-work-services: PASS')
