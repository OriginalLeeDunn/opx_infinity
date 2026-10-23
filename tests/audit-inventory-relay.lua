--- Weapon redraws preserve spent rounds; inventory refusals keep their reason.
-- @author dop42
-- Exercises real handlers with deferred relay completions, without a game.

local function noop() end
local function integer(value, low, high)
	if type(value) == 'number' and value % 1 == 0 and value >= low and value <= high then return value end
end
local function sandbox(values) return setmetatable(values, { __index = _G }) end

do
	local events, requests, sequence, now = {}, {}, 0, 0
	local citizen, drawn, mayAct = 'original', true, true
	local bag = { id = 1, kind = 'character', owner = 'original', items = {
		[1] = { name = 'pistol', count = 1, metadata = { serial = 'one', ammo = 12 } },
		[2] = { name = 'pistol', count = 1, metadata = { serial = 'two', ammo = 12 } },
	} }
	local function ask(kind, data)
		sequence = sequence + 1
		requests[sequence] = { kind = kind, data = data }
		return sequence
	end
	local M = { Common = { Integer = integer }, Options = { WEAPONS = true, WEAPON_SLOT = 1 },
		KIND = { CHARACTER = 'character' }, Event = { ARMED = 'armed' },
		Containers = { Find = function() return bag end, Publish = noop },
		Players = { Citizen = function() return citizen end, SourceOf = function() return 1 end,
			MayAct = function() return mayAct end },
		Storage = { MarkDirty = noop } }
	local env = sandbox({ OPX = { Modules = { Get = function() return M end },
		Now = function() return now end, NotifyLocale = noop, Api = { Get = function() return nil end } },
		Open77 = { weapons = {
			assign = function() return ask('assign') end,
			remove = function() return ask('remove') end,
			setAmmo = function(_, _, amounts) return ask('load', amounts) end,
			requestSnapshot = function() return ask('snapshot') end,
			get = function() return { fresh = true, drawn = drawn } end,
		}, log = { warn = noop } }, TriggerClientEvent = noop,
		AddEventHandler = function(name, callback) events[name] = callback end })
	assert(loadfile('modules/inventory/server/weapons.lua', 't', env))()
	M.Weapons.Wire()
	local item = { weapon = { ammo = 'ammo', magazine = 12, record = 'gun' } }
	local function complete(id, result, accepted)
		events['open77:weapons:completed'](1, id, 'op', accepted ~= false, nil, result)
	end
	local function arm(slot)
		assert(M.Weapons.Use(1, bag, slot, item))
		complete(sequence, { tweakDbId = 'gun', ammo = { capacity = 12 } })
		complete(sequence)
	end
	arm(1)
	drawn = false
	assert(M.Weapons.Use(1, bag, 1, item))
	local read = sequence
	assert(requests[read].kind == 'snapshot', 'redraw assigned stale ammunition before reading it')
	assert(select(2, M.Weapons.Use(1, bag, 1, item)) == 'holstering')
	assert(M.Weapons.BeforeLeave(bag, bag.items[1]) == 'holstering')
	complete(read, { { slot = 1, tweakDbId = 'gun', ammo = { total = 6 } } })
	assert(bag.items[1].metadata.ammo == 6)
	assert(requests[sequence].kind == 'assign')
	complete(sequence, { tweakDbId = 'gun', ammo = { capacity = 12 } })
	assert(requests[sequence].kind == 'load' and requests[sequence].data.magazine == 6,
		'rounds fired before a game holster were recreated')
	complete(sequence)
	assert(M.Weapons.Use(1, bag, 1, item))
	read = sequence
	complete(read, nil, false)
	assert(sequence == read, 'a refused snapshot assigned stale ammunition')
	assert(M.Weapons.Use(1, bag, 1, item), 'a failed reading prevented retry')
	read = sequence
	complete(read, { { slot = 1, tweakDbId = 'other-gun', ammo = { total = 1 } } })
	assert(sequence == read and bag.items[1].metadata.ammo == 6,
		'a different engine weapon supplied the count for the item')
	assert(M.Weapons.Use(1, bag, 1, item))
	read = sequence
	citizen = 'replacement'
	complete(read, { { slot = 1, tweakDbId = 'gun', ammo = { total = 2 } } })
	assert(sequence == read, 'a redraw followed a replacement character')
	citizen = 'original'
	M.Weapons.Forget(1, false)
	drawn = true
	arm(1)
	local ok, why = M.Weapons.Use(1, bag, 2, item)
	assert(not ok and why == 'holstering' and requests[sequence].kind == 'snapshot',
		'switching weapons overwrote the old engine count before its readback')
	local readBeforeRetry = sequence
	assert(select(2, M.Weapons.Use(1, bag, 2, item)) == 'holstering' and sequence == readBeforeRetry,
		'retrying a different weapon overwrote the shared engine slot during readback')
	complete(sequence, { { slot = 1, tweakDbId = 'gun', ammo = { total = 1 } } })
	assert(bag.items[1].metadata.ammo == 1)
	M.Weapons.Forget(1, false)
	arm(2)
	drawn = false
	assert(M.Weapons.Use(1, bag, 2, item))
	local finalRead = sequence
	mayAct = false
	complete(finalRead, { { slot = 1, tweakDbId = 'gun', ammo = { total = 4 } } })
	assert(sequence == finalRead and M.Weapons.Held(1) == nil,
		'a player who became unable to act was redrawn after the deferred read')
end

do
	local events, replies, notices = {}, {}, {}
	local bag = { id = 1 }
	local M = { Common = { Integer = integer, ErrorKey = function(code) return code end },
		Options = { RATE_WINDOW_MS = 10000, MAX_STACK = 100 }, KIND = {},
		Operation = { MOVE = 'inventoryMove' }, Event = { REQUEST = 'request', ANSWER = 'answer',
			GIVE_ANSWER = 'give', HELLO = 'hello' },
		Containers = { Move = function() return false, 'no_room' end,
			Split = function() return false, 'in_use' end, Sort = function() return false, 'holstering' end },
		Players = { Bag = function() return bag end, MayAct = function() return true end },
		World = {}, Actions = { SweepOffers = noop } }
	local env = sandbox({ OPX = { Modules = { Get = function() return M end },
		Now = function() return 0 end, Tune = { Number = function() return 100 end },
		Refuse = function(_, code, operation) notices[#notices + 1] = { code, operation } end,
		Scheduler = { Every = noop }, Host = { PLAYER_DISCONNECTED = 'left' } },
		RegisterNetEvent = function(name, callback) events[name] = callback end,
		AddEventHandler = noop, CreateThread = function(fn) fn() end,
		TriggerClientEvent = function(name, _, _, ok, code)
			if name == 'answer' then replies[#replies + 1] = { ok, code } end
		end, source = 1 })
	assert(loadfile('modules/inventory/server/requests.lua', 't', env))()
	M.Requests.Wire()
	for index, action in ipairs({ 'move', 'split', 'sort' }) do
		events.request(index, action, { fromSlot = 1, slot = 1, count = 1 })
	end
	for index, code in ipairs({ 'no_room', 'in_use', 'holstering' }) do
		assert(replies[index][1] == false and replies[index][2] == code)
		assert(notices[index][1] == code and notices[index][2] == 'inventoryMove')
	end
	M.Containers.Move = function() return true end
	events.request(4, 'move', { fromSlot = 1 })
	assert(replies[4][1] == true and replies[4][2] == '')
end

print('inventory relay and refusal regressions passed')
