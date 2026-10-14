--- Brings the client half up: modules, then the one loop.
-- @author dop42

local RESOURCE = GetCurrentResourceName()

-- Set by the stop handler below and read by the boot thread, which yields
-- several times before it is done. `Modules.Run` gives up the thread between
-- every module's `Start`, so a stop landing inside that window used to run
-- `Scheduler.Stop()` against a loop that the boot thread then STARTED again on
-- its next resume -- a loop with no resource left under it, which is the shape
-- `Scheduler.Stop`'s own docstring says it exists to prevent ("the VM can
-- outlive the resource"). The generation barrier retires the old loop; nothing
-- stopped a new one being made after the stop.
local stopping = false

AddEventHandler(OPX.Host.CLIENT_RESOURCE_START, function(name)
	if name ~= RESOURCE then return end
	stopping = false

	CreateThread(function()
		-- BEFORE the modules, not after. A module's `Start` may well draw on the
		-- surface, and anything sent before it exists is dropped for want of one.
		--
		-- UNDER PCALL, AND THEY WERE NOT. `Modules.Run` below has always been
		-- guarded; these two were bare, on the one thread that brings the client
		-- half up. A raise here -- a missing `OPX.Config.CLIENT` read, the
		-- instruction budget -- unwinds out of the coroutine without a crash,
		-- without a repeat and without a log line, which is exactly the failure
		-- mode `core/client/scheduler.lua` opens by describing. `Modules.Run`
		-- and `Scheduler.Start` then never ran at all: the whole client half
		-- dead, and silent about it.
		local built, why = pcall(function()
			OPX.UI.Surface()
			OPX.Toast.Attach()
		end)
		if not built then
			Open77.log.error(('[boot] the surface could not be built: %s'):format(tostring(why)))
			Open77.log.error('  the modules are still started; nothing will be drawn.')
			OPX.Note('boot', ('the client surface raised during boot: %s'):format(tostring(why)))
		end

		-- A RESUME OF ITS OWN FOR THE SURFACE. Building the page and then
		-- resolving every module's graph in the same resume came to the whole
		-- 10 000-instruction hook interval once main's `loading` module joined
		-- this branch's: the boot's first resume is the one that dies first.
		if type(Wait) == 'function' then Wait(0) end

		local started, fatal = OPX.Modules.Run()
		if not started then
			Open77.log.error(('client module failed: %s'):format(tostring(fatal)))
		end

		-- After the modules, so a module registering work in `Start` is picked up
		-- on the first pass rather than a tick later -- but not at all if the
		-- resource stopped while `Run` was yielding between them.
		if stopping then
			Open77.log.info('[boot] stopped while starting; the loop is not being started')
			return
		end
		OPX.Scheduler.Start()

		for _, line in ipairs(OPX.Modules.Report()) do
			Open77.log.info('[module] ' .. line)
		end
	end)
end)

AddEventHandler(OPX.Host.CLIENT_RESOURCE_STOP, function(name)
	if name ~= RESOURCE then return end
	stopping = true
	-- THE FOCUS GOES BACK FIRST. It used to go back only inside `Teardown`, at
	-- the end, so a budget overrun anywhere in the module stops below left the
	-- player holding a cursor and no controls, with no way out short of dying.
	-- Under pcall: nothing here may stop the rest of the stop path running.
	pcall(OPX.UI.ReleaseAllFocus)
	OPX.Scheduler.Stop()
	-- `true`: each module's `Stop` gets a fresh budget where the stack can yield.
	-- See `OPX.Modules.Stop`.
	OPX.Modules.Stop(true)
	-- AFTER the modules, and it was missing entirely. `OPX.UI.Teardown` says in
	-- its own docstring that this is the stop path, and nothing called it: the
	-- CEF page outlived the resource that built it. After `Modules.Stop` because
	-- a module stopping may still want to tell its page it is going.
	OPX.UI.Teardown()
end)
