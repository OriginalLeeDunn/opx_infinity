--- Boots the runtime off-platform and checks that the module lifecycle holds.
-- @author dop42
--
--   lua tests/run.lua        from the resource root
--
-- The registry is the one genuinely new piece of machinery in this resource.
-- Everything else is code that already worked somewhere else, so this is where
-- the tests are.

local Host = dofile('tests/host.lua')

local failures, checks = 0, 0

local function check(label, ok, detail)
	checks = checks + 1
	if ok then
		print(('  ok   %s'):format(label))
	else
		failures = failures + 1
		print(('  FAIL %s%s'):format(label, detail and ('  -- ' .. tostring(detail)) or ''))
	end
end

local function section(name) print(('\n== %s'):format(name)) end

--- Pumps until `ready()` answers true, or `rounds` are spent.
-- The client scheduler runs at most four jobs per pass and rotates between
-- them, so "one scan later" is not a fixed number of rounds -- a test that
-- hard-codes one is asserting how many other modules happened to register a job
-- on the same loop, which changes every time a module is added. This answers
-- whether it settled, so the assertion after it keeps its teeth.
-- @param control table the booted environment's control handle
-- @param ready function
-- @param rounds integer|nil
-- @return boolean
local function settle(control, ready, rounds)
	for _ = 1, rounds or 40 do
		if ready() then return true end
		control.Pump(1)
	end
	return ready()
end

--- Loads every manifest script for one side into a fresh environment.
-- @return table env
-- @return table control
-- @return string|nil the file that failed, and why
local function boot(side, database, prelude, loaded)
	local env, control = Host.Environment(side, database)
	if prelude then prelude(env) end

	for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do
		local chunk, why = loadfile(file, 't', env)
		if not chunk then return env, control, ('%s: %s'):format(file, why) end
		local ok, failure = pcall(chunk)
		if not ok then return env, control, ('%s: %s'):format(file, failure) end
		-- After each file, before any module starts: where a test swaps a
		-- shipped config for its fixture.
		if loaded then loaded(env, file) end
		-- The budget meter, when asked for, counts each scheduler job by name.
		if file == 'core/client/scheduler.lua' then Host.MeterJobs(env.OPX.Scheduler) end
	end

	-- The host always raises this for a starting resource, and the client half
	-- does all its wiring from it. A helper that skipped it would be testing a
	-- state the platform never produces.
	if side == 'client' then control.Fire('onClientResourceStart', 'opx_infinity') end

	-- ENOUGH FRAMES FOR A BOOT THAT SPREADS ITSELF OVER THEM. This was 60, which
	-- covered a boot where only `Start` yielded between modules -- thirty modules,
	-- thirty frames, and room to spare. Every phase yields now, so a full boot is
	-- three times that, and 60 left the server half part-way through it: the
	-- symptom was `attempt to index a nil value (local 'flying')` on a test
	-- reading `control.commands['noclip']`, a command registered by a module the
	-- boot had not reached. A harness that stops pumping before the resource has
	-- finished starting is testing a state the platform never ships.
	control.Pump(240)

	-- A surface refuses everything until its page has reported ready, so a test
	-- that skipped this would be testing the window before the UI exists.
	control.ReadyPages()
	return env, control
end

-- ── what one client resume costs ────────────────────────────────────────────
-- THE CLIENT KILLS A RESUME THAT OVERRUNS ITS INSTRUCTION BUDGET (~10,000 VM
-- instructions), silently and mid-operation, and desktop Lua has no such
-- budget -- so no check on a RESULT can see the defect, only a count of the
-- work. These two count the way `OPX_BUDGET_METER` in `tests/host.lua` does,
-- with the stub's own work left out (its page send walks and encodes a payload
-- in Lua, where the platform does both natively), so a check can hold a call
-- site to a figure on every run rather than only when somebody reads the meter.
local HOST_SOURCE = 'tests/host.lua'
local COST_STEP = 1

--- A count hook charging `COST_STEP` to `into.spent` for every tick that did not
--- land in the stub.
local function costHook(into)
	return function()
		local info = debug.getinfo(2, 'S')
		if info ~= nil and info.short_src == HOST_SOURCE then return end
		into.spent = into.spent + COST_STEP
	end
end

--- What one synchronous call costs, in VM instructions.
-- @param fn function
-- @return integer
local function callCost(fn, ...)
	local counter = { spent = 0 }
	debug.sethook(costHook(counter), '', COST_STEP)
	fn(...)
	debug.sethook()
	return counter.spent
end

--- The dearest single resume of every client thread made while `start` runs and
--- `rounds` frames are pumped after it. Each `Wait` closes one resume and opens
--- the next, which is exactly where the platform's budget starts over.
-- @param env table
-- @param control table
-- @param start function
-- @param rounds integer|nil
-- @return integer the dearest resume, in VM instructions
-- @return integer how many resumes were counted
local function resumeCost(env, control, start, rounds)
	local worst, resumes = 0, 0
	local realCreate, realWait = env.CreateThread, env.Wait
	local counters = setmetatable({}, { __mode = 'k' })
	-- A thread still alive when this returns keeps the wrappers below; it stops
	-- being counted rather than charging its later resumes to a closed count.
	local live = true
	local function settleResume()
		local counter = counters[coroutine.running()]
		if counter == nil then return end
		debug.sethook()
		resumes = resumes + 1
		if counter.spent > worst then worst = counter.spent end
		counter.spent = 0
	end
	local function openResume()
		local counter = counters[coroutine.running()]
		if counter ~= nil and live then debug.sethook(costHook(counter), '', COST_STEP) end
	end
	env.CreateThread = function(fn)
		return realCreate(function()
			counters[coroutine.running()] = { spent = 0 }
			openResume()
			fn()
			settleResume()
		end)
	end
	env.Wait = function(...)
		settleResume()
		realWait(...)
		openResume()
	end
	start()
	control.Pump(rounds or 40)
	live = false
	env.CreateThread, env.Wait = realCreate, realWait
	return worst, resumes
end

section('underworld: fence offers retain exact one and five item quantities')
local env, control, why = boot('client', nil)
assert(why == nil, why)
local m=env.OPX.Modules.Get('underworld')
for _,held in ipairs({1,5,7}) do
 control.netEvents[m.Event.VIEW]({kind='dealer',label='Fence',dealer='test',buys={{index=1,item='water',held=held,price=10}}})
 local payload
 for _,page in ipairs(control.pages) do
  for _,sent in ipairs(page.sent) do
   if sent.channel=='opx:menu:open' then payload=sent.payload end
  end
 end
 assert(payload,'menu open payload missing')
 check('a fence row with '..held..' held items is enabled',payload.rows[1].off~=true)
 -- Choose the row through the actual view handler to inspect its submenu.
 local page=control.pages[#control.pages]
 local handler=page.handlers['opx:menu:choose']
 assert(handler,'menu choose callback missing')
 handler({handle=payload.handle,index=1})
 local state=env.OPX.Api.Get('menu').State().value
 check('the sell quantities are distinct and include the full stack '..held,state.depth==2 and state.total==(held==1 and 1 or held==5 and 2 or 3))
end
assert(failures==0,tostring(failures)..' checks failed')
