--- City service menus stay inside one client resume's instruction budget.
-- @author dop42
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('client')
for _, file in ipairs(Host.LoadOrder('open77.lua', 'client')) do
	local chunk = assert(loadfile(file, 't', env)); assert(pcall(chunk), file)
end
control.Fire('onClientResourceStart', 'opx_infinity'); control.Pump(300); control.ReadyPages()
assert(env.OPX.Modules.IsRunning('citywork'))
local function costHook(counter)
	return function()
		local info = debug.getinfo(2, 'S')
		if info and info.short_src ~= 'tests/host.lua' then counter.spent = counter.spent + 1 end
	end
end
local function resumeCost(start)
	local worst, resumes, live = 0, 0, true
	local realCreate, realWait = env.CreateThread, env.Wait
	local counters = setmetatable({}, { __mode = 'k' })
	local function settle()
		local counter = counters[coroutine.running()]
		if not counter then return end
		debug.sethook(); resumes = resumes + 1; worst = math.max(worst, counter.spent); counter.spent = 0
	end
	local function open()
		local counter = counters[coroutine.running()]
		if counter and live then debug.sethook(costHook(counter), '', 1) end
	end
	env.CreateThread = function(fn)
		return realCreate(function() counters[coroutine.running()] = { spent = 0 }; open(); fn(); settle() end)
	end
	env.Wait = function(...) settle(); realWait(...); open() end
	start(); control.Pump(80); live = false
	env.CreateThread, env.Wait = realCreate, realWait
	assert(resumes > 0, 'the menu handler did not run on the metered client thread')
	return worst
end
local M = env.OPX.Modules.Get('citywork')
local free = resumeCost(function() control.netEvents[M.Event.VIEW]({ canEnrol = true }) end)
local menu = env.OPX.Api.Get('menu')
assert(menu.State().value.open and menu.State().value.owner == 'citywork' and menu.State().value.total == 6,
	'the enrolment menu did not render all bounded choices')
local active = resumeCost(function() control.netEvents[M.Event.VIEW]({ active = {
	id = 42, job = 'technician', route = 'market', pay = 300,
	point = env.OPX.Config.MODULES.citywork.ROUTES.market,
} }) end)
assert(menu.State().value.open and menu.State().value.total == 4, 'the active work menu did not render')
print(('citywork client resumes: desk=%d active=%d instructions'):format(free, active))
assert(free < 10000 and active < 10000, 'a city service menu can be killed mid-resume by the client')

control.netEvents[M.Event.VIEW]({ canEnrol = true })
control.netEvents[M.Event.VIEW]({ active = { id = 43, job = 'courier', route = 'yard', pay = 160,
	point = env.OPX.Config.MODULES.citywork.ROUTES.yard } })
control.Pump(60)
assert(menu.State().value.total == 4, 'an older deferred view replaced the newer active work menu')
M.Stop()
control.Pump(10)
assert(not menu.State().value.open, 'stopping service work left its menu focused')
print('citywork menu ordering and stop lifecycle passed')
