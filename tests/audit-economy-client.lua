--- Client economic surfaces must release focus and retire pending builds.
-- @author dop42
local function sandbox(extra) return setmetatable(extra, { __index = _G }) end
local function noop() end

do
	local handlers, threads, closed, opened = {}, {}, {}, 0
	local M = { Event = {}, Settings = {}, Model = {
		Settings = function() return { moneyType = 'BANK', reach = 3, reasonMax = 80 } end,
		Biller = function() return { label = 'test', maxAmount = 1000, cutPct = 0 } end,
	} }
	for _, name in ipairs({ 'ASK', 'ASK_CLOSED', 'SHOW_LIST', 'ISSUE', 'ACT' }) do M.Event[name] = name end
	local menu = { Open = function() opened = opened + 1; return { ok = true, value = { handle = opened } } end,
		Close = function(handle) closed[handle] = true end }
	local OPX = { Modules = { Get = function() return M end }, Result = {}, Math = {},
		Api = { Get = function(name) return name == 'menu' and menu or nil end },
		Locale = { Money = tostring }, Toast = { Locale = noop }, Note = noop }
	local env = sandbox({ OPX = OPX, locale = function(key) return key end,
		RegisterNetEvent = function(name, fn) handlers[name] = fn end,
		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		Wait = coroutine.yield, TriggerServerEvent = noop })
	assert(loadfile('modules/invoices/client/main.lua', 't', env))()
	M.Start()
	handlers.ASK({ id = 1, amount = 10 })
	assert(opened == 1)
	M.Stop()
	assert(closed[1], 'invoice prompt retained its menu/focus after stopping')
	handlers.SHOW_LIST({ owed = {} })
	local thread = threads[#threads]
	assert(coroutine.resume(thread))
	M.Stop()
	assert(coroutine.resume(thread))
	assert(opened == 1, 'pending invoice list reopened its surface after stopping')
end

do
	local callbacks, held = {}, false
	local M = { Access = {
		Sounds = function() return {}, {} end, Lockpick = function() return {} end,
		Difficulties = function() return {} end, UseRadius = function() return 2 end,
		MaxReach = function() return 4 end, Id = function(value) return value end,
	}, Runtime = { Report = function() return {} end }, Event = {}, Settings = {} }
	local OPX = { Modules = { Get = function() return M end }, Now = function() return 0 end,
		UI = { Interactive = function() return true end, Send = function() return true end,
			On = function(_, name, fn) callbacks[name] = fn end,
			AcquireFocus = function() held = true end, ReleaseFocus = function() held = false end },
		Toast = { Show = noop } }
	local env = sandbox({ OPX = OPX, locale = function(key) return key end, TriggerServerEvent = noop })
	assert(loadfile('modules/doorlock/client/panel.lua', 't', env))()
	M.Panel.Init()
	assert(M.Panel.Open({}) and held)
	M.Panel.Close()
	callbacks['focus:set']({ owner = 'doorlock', focus = true })
	assert(not held, 'late focus event recaptured the keyboard for a closed doorlock panel')
end
print('client economic surface lifecycle: 5 checks passed')

do
	local Host = dofile('tests/host.lua')
	local env, control = Host.Environment('client')
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
		assert(loadfile(file, 't', env))()
	end
	control.Fire('onClientResourceStart', 'opx_infinity')
	control.Pump(240)
	local M = env.OPX.Modules.Get('hauling')
	local sync = assert(control.netEvents[M.Event.SNAPSHOT])
	local gone = assert(control.netEvents[M.Event.GONE])
	local change = assert(control.netEvents[M.Event.CRATE])
	for chunk = 1, 32 do
		local rows = {}
		for index = 1, 64 do
			local id = tostring((chunk - 1) * 64 + index)
			rows[index] = { id = id, x = 1, y = 1, z = 1, where = 'ground' }
		end
		sync({ first = chunk == 1, crates = rows })
	end
	gone('1')
	change({ id = '2', x = 9, y = 1, z = 1, where = 'ground' })
	local spent = 0
	debug.sethook(function() spent = spent + 100 end, '', 100)
	sync({ done = true, crates = {} })
	debug.sethook()
	assert(spent < 2000, 'last hauling snapshot chunk walked the whole accumulated crate list')
	local crates
	for index = 1, 20 do
		local name, value = debug.getupvalue(sync, index)
		if name == nil then break end
		if name == 'crates' then crates = value; break end
	end
	assert(crates and crates['1'] == nil, 'removed hauling crate resurrected when its snapshot finished')
	assert(crates['2'].x == 9, 'crate update was replaced by the older snapshot')
end
print('hauling client snapshot: bounded commit and concurrent changes passed')

do
	local Host = dofile('tests/host.lua')
	local env, control = Host.Environment('client')
	for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do assert(loadfile(file, 't', env))() end
	control.Fire('onClientResourceStart', 'opx_infinity'); control.Pump(240)
	local progress = env.OPX.Api.Get('progress')
	for _, duration in ipairs({ 0/0, math.huge, -math.huge }) do
		local answer = progress.Start('audit', { label = 'audit', durationMs = duration })
		assert(not answer.ok and answer.error == 'invalid_duration' and not progress.State().value.open,
			'non-finite progress duration left a permanent bar/input lock')
	end
	assert(progress.Start('audit', { label = 'audit', durationMs = '1000' }).ok)
	assert(progress.Stop('audit').ok)
end
print('progress finite duration checks passed')

do
	local callbacks, handlers, held = {}, {}, false
	local M = { Event = { OFFER = 'offer', CLOSE = 'close' }, Settings = {},
		Catalogs = { en = {}, fr = {} }, Catalogue = function() return {} end }
	local OPX = { Modules = { Get = function() return M end, IsRunning = function() return false end },
		Channel = { LOCAL = 'local' }, Event = function() return 'entry' end, Now = function() return 0 end,
		UI = { Interactive = function() return true end, Send = function() return true end,
			On = function(_, name, fn) callbacks[name] = fn end,
			AcquireFocus = function() held = true end, ReleaseFocus = function() held = false end },
		Scheduler = { Every = noop }, Locale = { Exists = function() return false end } }
	local env = sandbox({ OPX = OPX, locale = function(key) return key end, TriggerServerEvent = noop,
		TriggerEvent = noop, AddEventHandler = noop, RegisterNetEvent = function(name, fn) handlers[name] = fn end })
	assert(loadfile('modules/spawn/client/main.lua', 't', env))()
	M.Init(); M.Start()
	handlers.offer({})
	callbacks['focus:set']({ owner = 'spawn', focus = true })
	assert(held)
	handlers.close({})
	callbacks['focus:set']({ owner = 'spawn', focus = true })
	assert(not held, 'late spawn focus event recaptured the keyboard after its offer closed')
end
print('spawn late-focus regression passed')
