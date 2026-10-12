--- Drives every declared module through resolve, init, api, start and stop.
-- @author dop42
--
--   declare -> resolve -> init -> api -> start -> running -> stop
--
-- `init` builds state and may not yield or reach another module. `api` publishes
-- contracts, and nothing may read one before this phase ends. `start` runs on a
-- coroutine and may hit the database. `stop` runs in reverse dependency order.

local PHASES = { 'Init', 'Api', 'Start' }

local resolved
local ran = false

--- Reports a module out of the running set, keeping the first reason.
local function halt(module, state, reason)
	if module.State == 'failed' then return end
	module.State = state
	module.Reason = reason
end

--- Depth-first walk producing dependency order, with the cycle reported by name.
-- A cycle found at boot is an error someone can read; the same cycle found at
-- runtime is a module reading a half-built neighbour.
local function visit(module, seen, out, trail)
	if seen[module.Id] == 'done' then return end
	if seen[module.Id] == 'open' then
		local cycle = {}
		for index = 1, #trail do cycle[index] = trail[index] end
		cycle[#cycle + 1] = module.Id
		error(('module dependency cycle: %s'):format(table.concat(cycle, ' -> ')), 0)
	end

	seen[module.Id] = 'open'
	trail[#trail + 1] = module.Id

	-- Two plain loops rather than one over `{ Requires, Optional }`: that pair was
	-- a fresh table per module visited, which is most of what this walk cost.
	local requires, optional = module.Requires, module.Optional
	for index = 1, #requires do
		local other = OPX.Modules.Record(requires[index])
		if other then visit(other, seen, out, trail) end
	end
	for index = 1, #optional do
		local other = OPX.Modules.Record(optional[index])
		if other then visit(other, seen, out, trail) end
	end

	trail[#trail] = nil
	seen[module.Id] = 'done'
	out[#out + 1] = module
end

--- Drops every module whose requirements are no longer runnable, until the
--- answer stops changing: dropping one module can drop its dependants.
---
--- CALLED AFTER EVERY PHASE AND NOT ONLY AT RESOLVE, which is the difference
--- between an invariant of the BOOT GRAPH and an invariant of the RUN. `Resolve`
--- is memoised, so this used to run exactly once, against states nothing had
--- touched yet. A non-fatal module failing in `Init` -- `crafting` is
--- `fatal = false`, and `gunsmith` requires it -- left every dependant still
--- `declared`, so they went on to `Api` and `Start` and ran a whole session
--- against a contract that was never published. `OPX.Api.Get` answers nil for it
--- and the dependant discovers that wherever it happens to look.
---
--- @param list table[] the resolved modules, in dependency order
--- @return string[] the ids dropped by this pass
local function settle(list)
	local dropped = {}
	local settling = true
	while settling do
		settling = false
		for _, module in ipairs(list) do
			if module.State == 'declared' then
				for _, id in ipairs(module.Requires) do
					local other = OPX.Modules.Record(id)
					if other == nil then
						halt(module, 'unavailable', ('requires %q, which is not installed'):format(id))
						dropped[#dropped + 1] = module.Id
						settling = true
						break
					elseif other.State ~= 'declared' and other.State ~= 'started' then
						halt(module, 'unavailable', ('requires %q, which is %s'):format(id, other.State))
						dropped[#dropped + 1] = module.Id
						settling = true
						break
					end
				end
			end
		end
	end
	return dropped
end

--- Orders every declared module and marks the ones that cannot run.
-- @author dop42
-- @return table[] the modules to run, in dependency order
function OPX.Modules.Resolve()
	if resolved then return resolved end

	-- THE WALK IS SLICED. It grows with every module the resource ships, and in
	-- one piece it was the dearest resume of the whole client boot once the job
	-- modules landed (4,615 instructions against the 4,500 the boot is held to).
	-- A root's walk always finishes before a yield, so `seen` and `trail` never
	-- straddle one; between two roots the order so far is complete.
	local out, seen, trail = {}, {}, {}
	local all = OPX.Modules.All()
	local canWait = type(Wait) == 'function'
	for index = 1, #all do
		visit(all[index], seen, out, trail)
		if canWait and index % 24 == 0 then
			pcall(Wait, 0)
			if resolved then return resolved end
		end
	end

	-- A FRESH RESUME FOR THE REST, when the stack may yield. The walk above and
	-- the rebind, the `enabled` pass and the settle below come to ~5,700 VM
	-- instructions over sixty-odd modules, and on the client they ran in the
	-- boot thread's first resume behind the surface build -- the budget meter's
	-- 10,800 against ~10,000, the one resume the whole client half hangs on.
	-- Under pcall for the reason `runPhase` gives; and a caller that finished the
	-- order while this one was parked has already answered it.
	if type(Wait) == 'function' then
		pcall(Wait, 0)
		if resolved then return resolved end
	end

	-- Every script has run and no phase has, which is the one moment a module may be
	-- told what its config says -- `config/vehicles.lua` and its two siblings are
	-- `server_script`s and had not run when their modules declared themselves. See
	-- `OPX.Modules.Rebind`.
	OPX.Modules.Rebind()

	-- THE `enabled` FLAG, ANSWERED WHERE IT CAN BE. `Declare` reads it too and can
	-- only answer for a module whose config is a `shared_script`: the platform runs
	-- every shared script before any server script, so a config that is one of the
	-- three `server_script` ones has not run when its module declares itself, and a
	-- module switched off there was switched off for nobody. Every script has run by
	-- the time this is called, and no phase has.
	for _, module in ipairs(out) do
		if module.State == 'declared' and OPX.Modules.Settings(module.Id).enabled == false then
			halt(module, 'disabled', 'disabled in config')
		end
	end

	settle(out)

	resolved = out
	return out
end

--- Runs one phase over the runnable modules, in order.
--
-- `Start` YIELDS BETWEEN MODULES, and that is not politeness to the frame rate.
--
-- The host bounds a task by a PER-FRAME instruction budget and stops it dead when
-- it is passed; a `Wait(0)` moves to the next frame and the budget starts again.
-- Every module's `Start` used to run in one frame, so the whole client boot spent
-- ONE budget between them: each module made the next one likelier to trip, and the
-- one that actually tripped depended on how much the frame had already spent.
--
-- That is exactly what was seen. The inventory reported, intermittently:
--
--   client module: inventory failed
--     start failed: modules/target/shared/model.lua:334: script execution budget exceeded
--
-- It is not the inventory's fault and it was never reliably the inventory: it
-- registers its world rows in `Start`, late in dependency order, so it was simply
-- often the module holding the parcel. And because `Start` raising marks a module
-- `failed`, the rest of its `Start` never ran -- which is why the symptom was "no
-- inventory AND no keybinds", with no error anywhere a player could see.
--
-- `Init` WAS NOT given the same treatment: it is documented never to yield, it
-- builds state rather than touching the world, and a yield there would let an
-- event reach a module whose state is half built. That reasoning is kept below,
-- with what finally outweighed it.
--
-- `Api` WAS NOT EITHER, AND THAT DECISION IS NOW REVERSED. It is left standing
-- here because the objection to yielding was a real one and is worth keeping:
-- `Api` is where contracts are published, so a yield in the middle of it is a
-- frame in which some modules have published and some have not, and an event
-- arriving in that frame gets nil from `OPX.Api.Get` for a contract that exists.
-- The second half of the argument was that the budget could not be the problem,
-- because an `Api` body is a handful of `Provide` calls and no world reads.
--
-- THAT HALF WAS WRONG, and the thirtieth module proved it. A handful of calls
-- is nothing; a handful of calls TIMES THIRTY, out of one budget, is not, and
-- adding `modules/blips` on 2026-09-21 pushed the total over. Deployed 18:29;
-- by 18:45 the journal carried, from the owner's own client:
--
--   client module: needs failed / api failed:
--   modules/needs/client/main.lua:809: Open77 script execution budget exceeded
--
-- Line 809 is `OPX.Api.Provide('needs', 1, {...})`. `needs` did nothing wrong
-- and neither did `blips`: the budget was a shared pot and the module holding
-- the parcel went without, exactly as the inventory did in `Start` above, and
-- with the same tell -- "it was never reliably the inventory". The owner saw it
-- as "je vois plus les status", because the chip strip `needs` publishes was
-- never published.
--
-- AND THE OBJECTION IS ANSWERED BY WHAT IT WAS WEIGHED AGAINST. Not yielding
-- does not avoid a frame where a contract is missing -- it buys a run where a
-- contract is missing FOREVER, because the phase dies partway and the modules
-- after the cut never publish at all. A one-frame window during boot, in a boot
-- where `Start` already spreads itself over frames, is strictly the smaller of
-- the two. It also stops being a lottery: without this, every module added from
-- now on re-rolls which existing module dies.
--
-- `Init` yields for the same reason. The objection there -- an event reaching a
-- module whose state is half built -- is weighed against the same alternative,
-- a module whose state is never built at all.
-- @return string|nil the id of a fatal module that failed
local function runPhase(phase)
	local fatal
	-- EVERY PHASE, NOT JUST `Start` -- see the head of this function for what
	-- changed and what it was weighed against. Guarded on the native rather than
	-- on the phase: a build without `Wait` must still boot, just in one frame, as
	-- every build did before.
	local yielding = type(Wait) == 'function'
	for _, module in ipairs(OPX.Modules.Resolve()) do
		-- A PER-MODULE REQUIREMENT RE-CHECK USED TO STAND HERE, AND IT COST THE
		-- CLIENT HALF ITS FORM. The idea was sound -- `Resolve` hands back a
		-- dependency before its dependant, so a module that failed in `Init` is
		-- followed IN THE SAME PHASE by the modules that require it, which run,
		-- register their handlers, and are only marked `unavailable` afterwards.
		--
		-- The cost was not. `Init` and `Api` did not yield then, so each of them
		-- ran in ONE resume and shared ONE instruction budget -- which is the
		-- whole argument for yielding between modules, and why every phase does
		-- it now. A loop over every module's `Requires` before every step, across
		-- thirty modules, was paid out of that single budget, and this file says
		-- what happens then: "each module made the next one likelier to trip,
		-- and the one that actually tripped depended on how much the frame had
		-- already spent". Deployed 2026-09-21 13:41; by 13:50 the journal
		-- carried `client module: form failed / api failed: Open77 script
		-- execution budget exceeded`, three times, from three different players,
		-- and never once in the twenty-four hours before it. `form` draws the
		-- name entry, so a player joining with an unnamed character was never
		-- asked for a name and sat under the loading cover at `Character`.
		--
		-- `settle` after each phase is what this goes back to. It is a phase
		-- late, and it is free.
		if module.State == 'declared' then
			-- Phases live on the namespace; everything else the loop reads is on
			-- the record. The two were one table once, and a module field named
			-- after a lifecycle field overwrote it, silently.
			local step = module.Module[phase]
			if type(step) == 'function' then
				-- `Provide` reads this to name the owner of a contract; the
				-- phases never interleave, so a single field is enough.
				OPX.Api.Owner = module.Id
				local ok, failure = pcall(step)
				OPX.Api.Owner = nil
				if not ok then
					halt(module, 'failed', ('%s failed: %s'):format(phase:lower(), tostring(failure)))
					Open77.log.error(('[%s] %s'):format(module.Id, module.Reason))
					-- WHAT IT PUBLISHED GOES WITH IT. `Provide` is called from
					-- inside `Api`, and `Api` may raise after publishing: the
					-- contract used to stay for the life of the resource, naming
					-- an implementation whose constructor never finished.
					for _, name in ipairs(OPX.Api.Withdraw(module.Id)) do
						Open77.log.error(('[%s] contract %q is withdrawn with it')
							:format(module.Id, name))
					end
					if module.Fatal then fatal = module.Id end
				end
				-- AFTER the module, not before: a fresh budget is worth nothing to
				-- the module that has already spent it, and this way the last one
				-- in the list is the only frame that pays for two.
				--
				-- UNDER pcall, because the real condition is not "does `Wait`
				-- exist" but "may this stack yield at all". `Run` is documented
				-- to be called from a thread and both boot files do -- but a
				-- caller that does not (the test host calls it straight) would
				-- otherwise raise `attempt to yield from outside a coroutine` and
				-- take the whole boot down for the sake of a budget reset. A yield
				-- that cannot happen just means the frame is shared, which is what
				-- every build did until now.
				if yielding then pcall(Wait, 0) end
			end
		end
	end
	return fatal
end

--- Runs init, api and start. Call from a thread: `Start` may yield.
--- `between` runs after every contract is published and before any module starts,
--- which is where the server applies the schema: modules contribute their tables
--- during `Init`, and `Start` is the first phase allowed to read the database.
-- @author dop42
-- @param between? function
-- @return boolean ok
-- @return string|nil the id of the fatal module that failed
function OPX.Modules.Run(between)
	-- Idempotent. The host can raise a resource-start event more than once, and
	-- running the phases twice publishes every contract twice -- which `Provide`
	-- correctly refuses, failing every module that owns one.
	-- AND IT SAYS SO. Answering `true` to a second call was a lie that read as a
	-- successful boot: `core/client/boot.lua` went on to start the loop over an
	-- empty job list and print a report in which every line said `stopped`, and
	-- a player connected through a stop/start of this VM had nothing rebuilt and
	-- nothing logged. `ran` is not reset -- nothing here unregisters a handler,
	-- so a second run would double every one of them -- the answer is simply
	-- honest about which of the two things happened.
	if ran then
		Open77.log.error('[modules] Run() was called twice; this VM cannot be started in place')
		return false, 'already ran'
	end
	ran = true

	for _, phase in ipairs(PHASES) do
		if phase == 'Start' and between then
			local ok, failure = pcall(between)
			if not ok then return false, tostring(failure) end
		end
		local fatal = runPhase(phase)
		if fatal then return false, fatal end

		-- RE-SETTLED AFTER THE PHASE, because a phase can drop a module the graph
		-- said was runnable. A non-fatal module that raises in `Init` is marked
		-- `failed` here and nowhere else -- `Resolve` is memoised and had already
		-- run -- so its dependants used to carry on through `Api` and `Start` with
		-- a contract nobody published. They are dropped now, with the reason
		-- naming the module that actually failed.
		for _, id in ipairs(settle(OPX.Modules.Resolve())) do
			local module = OPX.Modules.Record(id)
			Open77.log.error(('[%s] %s'):format(id, module and module.Reason or 'dropped'))
		end
	end

	for _, module in ipairs(OPX.Modules.Resolve()) do
		if module.State == 'declared' then module.State = 'started' end
	end

	-- A fatal module that never failed but never ran is still fatal.
	for _, module in ipairs(OPX.Modules.Resolve()) do
		if module.Fatal and module.State ~= 'started' then
			return false, module.Id
		end
	end

	return true
end

--- Stops every started module, newest dependency first.
---
--- `yielding` GIVES EACH `Stop` A FRESH BUDGET, for the reason `runPhase` gives
--- each `Start` one. The client stop path ran every module's `Stop` in ONE
--- resume, so thirty of them shared one instruction budget -- the lottery the
--- head of `runPhase` describes, where the module holding the parcel when the
--- pot runs out is cut off and everything after it never runs. On the client
--- that includes `OPX.UI.Teardown`, which comes after this, so a player could be
--- left with a cursor and no controls. `core/client/boot.lua` now gives the focus
--- back BEFORE this is called, so the overrun no longer costs that; yielding
--- here is what keeps it from costing the modules after the cut their `Stop`.
---
--- Under `pcall`, like the yields in `runPhase`: a caller that is not on a
--- thread just shares one frame, as every stop did before. The server passes
--- nothing -- it has no per-resume budget to reset.
-- @author dop42
-- @param yielding boolean|nil yield between modules when the stack can
function OPX.Modules.Stop(yielding)
	local canYield = yielding == true and type(Wait) == 'function'
	local running = OPX.Modules.Resolve()
	for index = #running, 1, -1 do
		local module = running[index]
		-- `failed` IS STOPPED TOO. A module that raised halfway through its
		-- `Start` had already registered its scheduler jobs, its event handlers
		-- and its hooks -- this file's own example is `inventory` hitting the
		-- instruction budget, with "the rest of its `Start`" never run. It was
		-- marked `failed`, never `started`, so this loop skipped it and its jobs
		-- went on running against half-built state for the life of the resource,
		-- and its hooks went on voting. A `Stop` already has to tolerate a
		-- partial start, because that is exactly the state it is called in.
		if module.State == 'started' or module.State == 'failed' then
			-- BEFORE the `Stop`, now that a stop can yield: a second stop arriving
			-- while this one is parked between two modules must not call the same
			-- `Stop` twice.
			module.State = 'stopped'
			if type(module.Module.Stop) == 'function' then
				local ok, failure = pcall(module.Module.Stop)
				if not ok then
					Open77.log.error(('[%s] stop failed: %s'):format(module.Id, tostring(failure)))
				end
				if canYield then pcall(Wait, 0) end
			end
			-- MARKED STOPPED WHETHER OR NOT IT HAD A `Stop`, and this write was
			-- INSIDE the `type(...) == 'function'` guard. A module with no `Stop`
			-- -- most of them -- stayed `started` for ever, so `Report` said
			-- running after the resource had gone and a second `Stop` would call
			-- every `Stop` again. `core/client/boot.lua` runs this from
			-- `onClientResourceStop`, where the VM can outlive the resource and
			-- that state is all anything has left to read. (Written above, before
			-- the call, so a yielded stop cannot be re-entered.)
		end
	end
end

--- One line per module: id, state and reason. What the diagnostic command prints.
-- @author dop42
-- @return string[]
function OPX.Modules.Report()
	local lines = {}
	for _, module in ipairs(OPX.Modules.Resolve()) do
		lines[#lines + 1] = ('%-14s %-12s %s')
			:format(module.Id, module.State, module.Reason or '')
	end
	return lines
end

--- Whether the module order has already been worked out. `OPX.Modules.Declare`
--- reads this to refuse a declaration that arrives too late to be run: the
--- order is memoised, so a module declared afterwards sits at `declared` for
--- ever, in no phase, in no report, with the reason written nowhere.
-- @author dop42
-- @return boolean
function OPX.Modules.Resolved()
	return resolved ~= nil
end
