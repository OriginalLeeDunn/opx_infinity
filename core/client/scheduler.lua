--- The client's only loop. Modules register work here instead of spawning threads.
-- @author dop42
--
-- Twenty-one resources used to get twenty-one budgets. One runtime gets one, and
-- the platform's is unforgiving: exceeding the per-resume instruction budget
-- raises `Open77 script execution budget exceeded`, which unwinds straight out of
-- the coroutine body. A `while true do ... Wait(n) end` loop that hits it is never
-- resumed again -- it does not crash the resource, it does not repeat, and it logs
-- nothing. A loop that quietly stopped is almost always this.
--
-- So there is one loop, and it is defensive:
--   * at most MAX_PER_TICK jobs run in a single resume, rotating so none starves
--   * a job is wrapped in pcall, and one that raises repeatedly is suspended
--   * registration staggers first runs, so N jobs on the same interval do not all
--     land on the same tick for the rest of the session

OPX.Scheduler = OPX.Scheduler or {}

local jobs = {}
local byHandle = {}
local cursor = 0
local nextHandle = 0
local dead = 0
local registered = 0
local running = false

-- Bumped by every `Start`, and each loop holds the value it was started with. It
-- is what lets a `Stop` retire a thread that is asleep inside `Wait` -- see
-- `Start`.
local generation = 0

-- How many DUE jobs one resume may run.
--
-- A CONSTANT HERE IS A THROUGHPUT LIMIT, and that much was true: a saturated
-- pass comes straight back with `return 0`, so four per resume is four per
-- frame however many are registered, and 44 are. At 30 fps with a menu open the
-- cap binds on 893 passes out of 899.
--
-- AND IT STAYS AT FOUR ANYWAY. Raising it to ten was the wrong half of the
-- problem,
-- and it was raised on a simulation of THROUGHPUT while the thing the cap
-- protects is the per-resume instruction BUDGET -- which nothing off-platform
-- can measure, and whose failure mode is written at the top of this file: the
-- loop is retired for the session, silently, taking the health bar, the
-- prompts, every marker, the menu keys and the eye with it, with no line in any
-- log. Ten of these jobs in one resume is `admin.tags` walking 32 bodies,
-- `prompts.pass` sorting 32 groups, four independent distance sweeps and
-- `admin.doors` deriving up to 256 doors, all on one budget.
--
-- The throughput complaint was real. The fix for it is eleven lines below, in
-- how `nextAt` is rebased, and it costs nothing.
local MAX_PER_TICK = 4

local MAX_FAILURES = 3
local IDLE_MS = 100

--- Registers repeating work. Returns a handle for `Cancel`.
---
--- THE HANDLE IS NOT A POSITION. A cancelled job is dropped from the list at the
--- next pass -- a menu that registers its key poll on open and cancels it on
--- close would otherwise leave one dead entry per open, for the session -- and
--- an index would name a different job after the first drop.
-- @author dop42
-- @param name string owner and purpose, for the log line if it fails
-- @param intervalMs integer milliseconds; NOT a function, unlike the server
-- @param step function
-- @return integer handle
function OPX.Scheduler.Every(name, intervalMs, step)
	if type(name) ~= 'string' or type(step) ~= 'function' then
		error('Every(name, intervalMs, step)', 2)
	end
	-- A BAD INTERVAL IS REFUSED, not rounded down to zero. This read used to be
	-- `math.max(0, math.floor(tonumber(intervalMs) or 0))`, which turned every
	-- mistake -- a nil, a string, a function -- into an interval of 0, and an
	-- interval of 0 on this scheduler means the job runs on every single pass.
	-- On a client with a per-resume instruction budget that is the worst thing a
	-- typo can do: the resource does not crash, it quietly eats the budget until
	-- something unrelated is cut off mid-coroutine with no log line.
	--
	-- A FUNCTION IS THE CASE WORTH NAMING. The SERVER'S `Every` takes
	-- `integer|function` and re-reads a function every pass, which is how a job
	-- follows a live tunable; the two functions share a name and a signature on
	-- paper. This one cannot do it and should not pretend to -- `OPX.Tune` is
	-- server-only, so there is no live number on the client to follow -- so a
	-- function is refused here rather than silently becoming frame-rate.
	--
	-- Zero itself stays legal: a caller that means "every pass" may say so.
	-- Non-finite values never become due and can poison the nearest deadline.
	local interval = tonumber(intervalMs)
	if type(intervalMs) == 'function' or interval == nil or interval ~= interval
		or interval == math.huge or interval < 0 then
		error(('Every(%q, intervalMs, step): intervalMs must be a finite non-negative number of '
			.. 'milliseconds, got %s'):format(name, type(intervalMs)), 2)
	end
	interval = math.floor(interval)

	nextHandle = nextHandle + 1
	registered = registered + 1

	local job = {
		handle = nextHandle,
		name = name,
		interval = interval,
		-- Staggered so that ten jobs sharing an interval spread across it rather
		-- than colliding on one resume forever. Off the count of everything ever
		-- registered, not of what is live: two jobs landing on the same offset
		-- because one in between was cancelled is the collision this avoids.
		nextAt = OPX.Now() + (interval > 0 and (registered * 17) % interval or 0),
		step = step,
		failures = 0,
	}

	jobs[#jobs + 1] = job
	byHandle[nextHandle] = job
	return nextHandle
end

--- Stops a registered job. Safe for a handle that is already cancelled.
-- @author dop42
-- @param handle integer
function OPX.Scheduler.Cancel(handle)
	local job = byHandle[handle]
	if job == nil or job.step == nil then return end
	job.step = nil
	byHandle[handle] = nil
	dead = dead + 1
end

--- Drops cancelled jobs. Run at the top of a pass rather than inside `Cancel`,
--- which may itself be called from a job this loop is walking.
local function compact()
	if dead == 0 then return end
	local live = {}
	-- THE CURSOR MOVES WITH THE LIST INSTEAD OF BEING RESET, and it was set to 0.
	-- `tick` promises to resume "where the last pass left off so a long list
	-- cannot starve its tail", and a reset sent the next pass back to the head:
	-- with more than MAX_PER_TICK jobs registered and anything cancelling on a
	-- cycle -- a menu registering its key poll on open and cancelling it on close
	-- does exactly that -- the tail of the list was never reached at all. The new
	-- position is the count of survivors at or before the old one, so the pass
	-- carries on from the same place in the same order.
	local resumeAt = 0
	for index = 1, #jobs do
		local job = jobs[index]
		if job.step then
			live[#live + 1] = job
			if index <= cursor then resumeAt = #live end
		end
	end
	jobs = live
	cursor = resumeAt
	dead = 0
end

--- Runs one job, suspending it after MAX_FAILURES consecutive raises.
local function runJob(job, atMs)
	local ok, failure = pcall(job.step)
	if ok then
		job.failures = 0
	else
		job.failures = job.failures + 1
		if job.failures == 1 or job.failures == MAX_FAILURES then
			Open77.log.error(('[scheduler] %s: %s'):format(job.name, tostring(failure)))
		end
		if job.failures >= MAX_FAILURES then
			-- Suspended rather than left to raise every tick: a job that is
			-- broken now is broken next tick, and the log is not the place to
			-- discover that thirty times a second.
			Open77.log.error(('[scheduler] %s suspended after %d failures')
				:format(job.name, job.failures))
			OPX.Scheduler.Cancel(job.handle)
			return
		end
	end
	-- REBASED ON ITS OWN DEADLINE, NOT ON THE PASS. `atMs` is the start of the
	-- resume and every job run in it shares that one value, so the moment two
	-- jobs of the same interval ran together they were locked in phase for the
	-- rest of the session -- and `Every` above goes to the trouble of staggering
	-- first runs precisely so that does not happen. The stagger was being undone
	-- by the first collision, and each collision dragged more of a family onto
	-- one resume, which is what made the cap bind on nearly every pass.
	--
	-- Keeping the phase is what buys back the throughput, without giving one
	-- resume more work to do.
	job.nextAt = job.nextAt + job.interval
	-- A job that fell badly behind -- a stall, a long frame -- must not then run
	-- a burst of catch-up passes to walk its missed deadlines forward one by one.
	-- It gives up the missed ones and takes the next slot from now.
	if job.nextAt <= atMs then job.nextAt = atMs + job.interval end
end

--- One pass: runs up to MAX_PER_TICK due jobs, resuming where the last pass left
--- off so a long list cannot starve its tail.
-- @return integer milliseconds to wait before the next pass is worth making
local function tick()
	compact()

	local atMs = OPX.Now()
	local count = #jobs
	if count == 0 then return IDLE_MS end

	local perTick = MAX_PER_TICK
	local ran, examined = 0, 0
	while examined < count and ran < perTick do
		cursor = cursor % count + 1
		examined = examined + 1
		local job = jobs[cursor]
		-- A STEP MAY EMPTY THIS LIST UNDER THE LOOP. `Stop()` replaces `jobs`
		-- with a fresh table, and `count` was fixed before the first step ran, so
		-- the next turn indexed past the end and raised `attempt to index a nil
		-- value (local 'job')` -- caught by the `pcall` around the pass, so it
		-- cost one log line that reads like a bug in the scheduler itself,
		-- written at the moment the resource is stopping.
		if job == nil then break end
		if job.step and atMs >= job.nextAt then
			runJob(job, atMs)
			ran = ran + 1
		end
	end

	-- WHAT THE LOOP SLEEPS IS THE NEAREST DEADLINE, not a constant. A flat
	-- hundred is longer than most intervals registered here: the vitals stream
	-- asks for 33ms and was served every ~116ms whenever the pass before it
	-- happened to find nothing else due, so the health bar ran at a third of the
	-- rate its own config names. The cap stays as the idle floor, and a pass that
	-- hit MAX_PER_TICK with more still due comes straight back.
	if ran >= perTick then return 0 end

	-- `#jobs` AGAIN, NOT `count`. A step is allowed to register work -- the
	-- target module registers its 25 ms resolve from the hover path, which is
	-- itself a job -- and a job appended during this pass sits past the bound
	-- taken before the steps ran. The sweep then never saw it and the pass slept
	-- the idle floor, so the first run of a job asked for in 25 ms landed up to
	-- 100 ms later.
	local soonest
	for index = 1, #jobs do
		local job = jobs[index]
		if job and job.step and (soonest == nil or job.nextAt < soonest) then
			soonest = job.nextAt
		end
	end
	if soonest == nil then return IDLE_MS end

	local waitMs = soonest - atMs
	if waitMs < 0 then waitMs = 0 end
	if waitMs > IDLE_MS then waitMs = IDLE_MS end
	return waitMs
end

--- Starts the loop. Called once by the client boot; further calls are ignored.
-- @author dop42
function OPX.Scheduler.Start()
	if running then return end
	running = true

	-- THE LOOP IS FENCED TO ITS OWN GENERATION. `running` alone is not enough:
	-- `Stop` sets it false but the thread is asleep inside `Wait`, and a `Start`
	-- before it next wakes finds `running` true again -- so it carries on, beside
	-- the new one, and two loops walk one list. On the client that is the one
	-- thing this file exists to avoid: both halves spend the same per-resume
	-- budget and every job runs twice as often as its own config says.
	generation = generation + 1
	local mine = generation

	CreateThread(function()
		while running and generation == mine do
			-- The pcall is around the pass, not only around each job: OPX.Now
			-- is a host read too, and a raise from it would end the loop for the
			-- whole session.
			local ok, waitMs = pcall(tick)
			if not ok then
				Open77.log.error(('[scheduler] pass failed: %s'):format(tostring(waitMs)))
				waitMs = IDLE_MS
			end
			Wait(waitMs)
		end
	end)
end

--- Stops the loop at the next tick and drops every registered job.
-- @author dop42
--
-- THE JOB LIST GOES TOO, which is what the server half has always done and this
-- half did not -- an asymmetry between two functions that share a name, a
-- signature and a docstring, with nothing written down about it. `Stop` is called
-- from `core/client/boot.lua` on `onClientResourceStop`, where the VM can outlive
-- the resource: a job left in the list is a closure over state that is being torn
-- down, waiting for anything that resumes the loop.
function OPX.Scheduler.Stop()
	running = false
	jobs = {}
	byHandle = {}
	cursor = 0
	dead = 0
end

--- One line per job: name, interval and state. For the diagnostic command.
-- @author dop42
-- @return string[]
function OPX.Scheduler.Report()
	local lines = {}
	for index = 1, #jobs do
		local job = jobs[index]
		lines[#lines + 1] = ('%-28s %6dms %s')
			:format(job.name, job.interval, job.step and 'running' or 'stopped')
	end
	return lines
end
