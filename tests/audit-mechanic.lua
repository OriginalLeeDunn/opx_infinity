--- Mechanic role, recipient and completion reservation regressions.
-- @author dop42

local function load(path, env)
	assert(loadfile(path, 't', setmetatable(env, { __index = _G })))()
end
local M = { OWNER = 'mechanic', Mode = { KIT = 'kit', SHOP = 'shop' }, CallKind = {},
	IMPOUNDED = 2, Event = setmetatable({}, { __index = function(_, key) return key end }) }
local raw = { SHOPS = { workshop = { JOBS = { mechanic = 0 }, STASH = { X = 1, Y = 1, Z = 1 },
	LOT = { X = 1, Y = 1, Z = 1 } } }, IMPOUND = { ENABLED = true } }
local player = { PlayerData = { citizenId = 'worker', userId = 'account', job = { name = 'mechanic' } } }
local opened, callback, removed = 0, nil, 0
local tasks, sent = {}, {}
local snapshot = { id = 'vehicle', x = 1, y = 1, z = 1, bucket = 0, health = 0.5 }
local character = { GetPlayer = function() return player end }
local inventory = { OpenStash = function() opened = opened + 1; return { ok = true } end,
	GetItemCount = function() return { ok = true, value = 1 } end,
	RemoveItem = function() removed = removed + 1; coroutine.yield(); return { ok = true } end }
local vehicles = { SetState = function() return { ok = true } end,
	List = function() coroutine.yield(); return { ok = true, value = { { state = 2, plate = 'TEST', record = 'Car' } } } end }
local progress = { Start = function(_, _, _, fn) callback = fn; return { ok = true, value = { id = 1 } } end }
local OPX = { Modules = { Get = function() return M end }, Config = { MODULES = { mechanic = raw }, SHARED = {} },
	Math = { Finite = tonumber }, Spots = { Coordinate = tonumber, ServerReach = function(value) return value end },
	Result = { Ok = function(value) return { ok = true, value = value } end,
		Err = function(code) return { ok = false, error = code } end },
	Api = { Get = function(name)
		if name == 'character' then return character end
		if name == 'inventory' then return inventory end
		if name == 'vehicles' then return vehicles end
		if name == 'progress' then return progress end
	end }, Now = function() return 0 end, Life = { Down = function() return false end },
	Audit = { Log = function() end }, Publish = function() end, Vehicle = { DisplayName = tostring } }
local env = { OPX = OPX,
	Open77 = { players = { position = function() return { x = 1, y = 1, z = 1 } end },
		vehicles = { all = function() return { snapshot } end, get = function() return snapshot end,
			setHealth = function() return true end, repair = function() return true end },
		log = { error = function() end } },
	TriggerClientEvent = function(name, _, value) sent[#sent + 1] = { name, value } end,
	CreateThread = function(fn) tasks[#tasks + 1] = coroutine.create(fn) end,
	locale = function(key) return key end }
load('lib/shared/jobgate.lua', env)
load('modules/mechanic/shared/model.lua', env)
load('modules/mechanic/server/dispatch.lua', env)
load('modules/mechanic/server/main.lua', env)
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'valid mechanic could not open its parts room')
raw.SHOPS.workshop.JOBS = nil
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'missing job config opened the parts room to everybody')
M.Server.OnImpound(7, {})
assert(sent[#sent][2].code == 'not_authorised', 'missing impound jobs allowed towing')
raw.SHOPS.workshop.JOBS = { mechanic = true }
M.Init()
M.Server.OnStash(7, { shop = 'workshop' })
assert(opened == 1, 'invalid minimum grade became grade zero')
raw.SHOPS.workshop.JOBS = { mechanic = 0 }
M.Init()
local before = #sent
local task = coroutine.create(function() M.Server.OnLot(7, { shop = 'workshop' }) end)
assert(coroutine.resume(task))
player = { PlayerData = { citizenId = 'replacement', userId = 'other', job = { name = 'mechanic' } } }
assert(coroutine.resume(task))
assert(#sent == before, 'impound listing reached a replacement character')
M.Server.OnRepair(7, { mode = 'kit' })
assert(callback, 'kit repair did not start')
callback(7, { completed = true })
local commit = tasks[#tasks]
assert(coroutine.resume(commit))
assert(removed == 1 and coroutine.status(commit) == 'suspended')
M.Server.OnRepair(7, { mode = 'kit' })
assert(sent[#sent][2].code == 'busy', 'worker reservation was released while the commit yielded')
assert(coroutine.resume(commit))
print('mechanic audit regressions passed')
