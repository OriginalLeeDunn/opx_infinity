--- The job gate: does this character snapshot satisfy a job requirement.
-- @author dop42
--
-- THE RULE IS THAT A `JOBS` BLOCK MEANS ONE THING. Wherever a surface in this
-- resource is gated by `JOBS = { name = minimumGrade }` beside an `ON_DUTY`
-- flag, it is decided here and not in the module: the staleness bound, the
-- primary-job-versus-any-membership distinction, the public-stays-open rule and
-- a refusal that names the CLOSEST near-miss are one decision, and a module that
-- keeps its own copy of five branches is how two surfaces end up disagreeing
-- about who may pass. `modules/elevators/shared/access.lua` wrote it first and it
-- moved here the moment a second module wanted it; it has since been rewritten
-- by hand twice more by modules that merged in parallel, each time losing a
-- branch, which is the argument restated rather than a reason to stop making it.
-- `core/shared/glyphs.lua` is the same story told about icons: three copies, 47
-- names, 45 and 14, and no test looking.
--
-- WHAT IS NOT THIS. `modules/shops` gates on a job too and does NOT come through
-- here: it asks `character.HasJob` per job name, which is the character module's
-- own in-memory read of its own roster. That is a different question -- a
-- boolean about a live player, with no snapshot, no age and no refusal code --
-- and asking the owner of the data is a legitimate answer to it. What would not
-- be legitimate is a third way of spelling the same five branches.
--
-- WHAT A SNAPSHOT IS. The job fields of a loaded character, plus the millisecond
-- it was read at:
--
--   { job  = { name = 'ncpd', grade = { level = 2 }, onDuty = true },
--     jobs = { ncpd = 2, fixer = 0 },   -- every membership, grade only
--     atMs = 1723... }
--
-- The server stamps `atMs` at the moment it reads its own roster, so its age
-- test always passes; a CLIENT holds a replicated copy that can be minutes old,
-- and that is the whole reason the bound exists. Both halves call this function
-- so the panel a client draws and the answer a server gives are the same
-- decision made twice, rather than two decisions that happen to agree.
--
-- IT IS PURE, and deliberately so: no clock of its own, no config read, no
-- module namespace. `nowMs` and the policy are arguments because the caller's
-- module owns both, and because a pure function is one a test can drive to
-- every branch without a world.

OPX.JobGate = {}

-- Failure ranking, so a refusal names the closest near-miss rather than the
-- first one `pairs` happens to meet. Somebody who holds the job at the right
-- grade but is off duty must be told THAT, and not `job_required` because a
-- second, irrelevant job was visited first.
local RANK = { off_duty = 3, grade_too_low = 2, job_required = 1 }

-- Read when the caller passes no policy at all, so a missing table is a gate
-- that still closes rather than an index of nil.
local NO_POLICY = {}

-- Coerces to a finite number, or nil. `OPX.Math.Finite` and not
-- `OPX.Text.Finite`, which also caps at 2^53: a yaw, a price and a millisecond
-- clock are all measured with this and must not be bounded like a coordinate.
-- It was written out by hand here, and identically in ten other files, under
-- that same correct reasoning -- which is an argument for one helper and never
-- was one for eleven copies.
local finiteNumber = OPX.Math.Finite

-- The grade of a job this character holds, or nil for one they do not.
--
-- `membership = 'any'` counts a membership for the GRADE and never for
-- ON_DUTY: the memberships table carries grades, not a clock, so a row in it
-- can never answer "is this person working right now". Under the default,
-- `primary`, only the worked job counts at all.
local function heldGrade(snapshot, name, membership)
	local job = snapshot.job
	if type(job) == 'table' and job.name == name then
		-- A job with no grade table at all reads as grade 0 rather than as no
		-- job: the character holds it, and a minimum of 0 is the common case an
		-- operator writes for "anybody on the payroll".
		return type(job.grade) == 'table' and finiteNumber(job.grade.level) or 0
	end
	if membership ~= 'any' then return nil end
	if type(snapshot.jobs) ~= 'table' then return nil end
	return finiteNumber(snapshot.jobs[name])
end

--- Decides whether a character snapshot satisfies one job requirement.
-- @author dop42
--
-- A requirement with no JOBS is PUBLIC and stays open with no snapshot at all:
-- a broken character read must not lock a lobby, a door or a walkway. That is
-- the single most load-bearing line in this file -- it is what keeps a database
-- hiccup from turning every ungated surface on the server into a wall.
--
-- A gated requirement closes on every doubt: no snapshot, a snapshot older than
-- `maxAgeMs`, a clock that cannot be read, a snapshot with no job table, and a
-- minimum grade that is not a number. The asymmetry is the point. Refusing a
-- public floor costs a player nothing they had; granting a gated one costs the
-- operator the gate.
--
-- THE CALLERS MUST AGREE ON THE FAIL DIRECTION TOO. A `{ jobs = nil }` reaches
-- here as PUBLIC, which is correct for an armoury or a floor that genuinely has
-- no JOBS block and catastrophic for one that could not be read at all. Every
-- adapter therefore answers closed for a subject that is not a table, BEFORE it
-- builds a requirement -- see the three `Access.Evaluate` functions.
--
-- @param requirement table|nil { jobs = { name = minimumGrade }, onDuty = boolean }
-- @param snapshot table|nil { job, jobs, atMs }
-- @param nowMs number
-- @param policy table|nil { maxAgeMs = number, membership = 'primary'|'any' }
-- @return boolean
-- @return string|nil one of no_character, job_stale, job_required,
--   grade_too_low, off_duty
function OPX.JobGate.Evaluate(requirement, snapshot, nowMs, policy)
	local required = type(requirement) == 'table' and requirement.jobs or nil
	if type(required) ~= 'table' or next(required) == nil then return true, nil end

	policy = type(policy) == 'table' and policy or NO_POLICY
	local maxAgeMs = finiteNumber(policy.maxAgeMs) or 0

	local atMs = type(snapshot) == 'table' and finiteNumber(snapshot.atMs) or nil
	if atMs == nil then return false, 'no_character' end

	-- A CLOCK THAT CANNOT BE READ IS A STALE READ, and not a raise. The elevators
	-- original subtracted the two raw, so a `nowMs` that arrived as a string --
	-- from a host whose timer answered oddly, or from a caller that forgot the
	-- argument -- took down whatever network handler was asking. Refusing a gated
	-- surface is the safe direction and it is the one branch of this function
	-- that changed in the move.
	-- TESTED IN BOTH DIRECTIONS. `at - atMs > maxAgeMs` is a one-sided test: a
	-- snapshot stamped in the FUTURE gives a negative age and passes every
	-- maximum there is. This file says a gated requirement "closes on every
	-- doubt", and a timestamp that has not happened yet is not a doubt this
	-- should be resolving in the caller's favour. Every adapter today builds its
	-- snapshot from the server roster with `atMs = OPX.Now()`, so this is the
	-- trap being closed rather than a hole being plugged -- and it is exactly
	-- the sort of thing that stops being true the day one of them takes a
	-- snapshot a client sent.
	local at = finiteNumber(nowMs)
	local stamped = finiteNumber(atMs)
	if at == nil or stamped == nil or stamped > at or at - stamped > maxAgeMs then
		return false, 'job_stale'
	end
	if type(snapshot.job) ~= 'table' then return false, 'no_character' end

	local worst, worstRank = 'job_required', RANK.job_required
	for name, minimum in pairs(required) do
		local held = heldGrade(snapshot, name, policy.membership)
		if held ~= nil then
			-- A MALFORMED MINIMUM CLOSES THE GATE; it used to OPEN it. This read
			-- was `finiteNumber(minimum) or 0`, so `JOBS = { ncpd = true }` -- a
			-- config typo, an operator writing `= "2"` badly, a row that came
			-- through a serialiser -- became a floor of 0 and every member of the
			-- job walked through. It was the one coercion in this file whose
			-- fallback REMOVED a guard, under a docstring saying "a gated
			-- requirement closes on every doubt".
			--
			-- It is not repaired to a number either: `modules/gunsmith` carries a
			-- malformed minimum through untouched on purpose, so the typo is named
			-- by `Problems` instead of being hidden behind a gate that works.
			-- Treating it as unsatisfiable is what makes that decision hold.
			local floor = finiteNumber(minimum)
			if floor == nil then
				if RANK.grade_too_low > worstRank then
					worst, worstRank = 'grade_too_low', RANK.grade_too_low
				end
			elseif held < floor then
				if RANK.grade_too_low > worstRank then
					worst, worstRank = 'grade_too_low', RANK.grade_too_low
				end
			elseif requirement.onDuty == true and
				not (snapshot.job.name == name and snapshot.job.onDuty == true) then
				if RANK.off_duty > worstRank then worst, worstRank = 'off_duty', RANK.off_duty end
			else
				return true, nil
			end
		end
	end
	return false, worst
end

--- Lists what is wrong with one JOBS block, in the caller's own words.
-- @author dop42
--
-- The messages are the elevators module's, kept to the letter so its diagnostic
-- reads exactly as it did. Job NAMES are not checked and cannot be: they live in
-- the character module's config, and every caller of this runs at load with
-- nothing waited on.
-- @param jobs any the JOBS block as an operator wrote it
-- @param where string what to name in the message, e.g. 'ncpd_watson floor #3'
-- @param lines table|nil collector, appended to and returned
-- @return string[]
function OPX.JobGate.Problems(jobs, where, lines)
	lines = lines or {}
	if jobs == nil then return lines end
	if type(jobs) ~= 'table' then
		lines[#lines + 1] = where .. ': JOBS must be a table of name -> minimum grade'
		return lines
	end
	for name, minimum in pairs(jobs) do
		if type(name) ~= 'string' or finiteNumber(minimum) == nil then
			lines[#lines + 1] = where ..
				': JOBS entries are job name -> minimum grade level, e.g. { ncpd = 0 }'
		end
	end
	return lines
end

-- ── gangs, beside jobs ───────────────────────────────────────────────────────
--
-- A GANG IS A JOB WITH NO DUTY CLOCK, and that is the whole of the extension.
-- `modules/doorlock` was the first to need a gang gate and got there by
-- reshaping the snapshot -- the gang the character runs with read as `job`,
-- every gang membership as `jobs` -- and handing it to `Evaluate` above. That is
-- the right idea and it is now spelt once, here, so a lab, a front and a dealer
-- (`modules/underworld`) ask the same five branches a door does instead of a
-- sixth copy of them. `Evaluate` itself is untouched: every caller of it before
-- this block reads exactly what it read.
--
-- Gang refusals carry their own words -- `gang_required`, `gang_grade_too_low`
-- -- because "you need the job" said to somebody turned away from a Tyger Claws
-- kitchen is a sentence about the wrong thing. Staleness and a missing
-- character are the same failure whichever list was asked, and keep their names.

-- The gang spelling of a job refusal, and the rank both share.
local GANG_WORD = { job_required = 'gang_required', grade_too_low = 'gang_grade_too_low' }
local GROUP_RANK = { job_stale = 0, no_character = 0, job_required = 1, gang_required = 1,
	grade_too_low = 2, gang_grade_too_low = 2, off_duty = 3 }

--- Decides a requirement that names jobs, gangs, or both: either list lets in.
-- @author dop42
--
-- PUBLIC WHEN IT NAMES NEITHER, for the reason `Evaluate` gives. With both, a
-- character passes on either one -- a front open to "the Valentinos, or a fixer"
-- -- and the refusal is the closest near-miss across the two.
-- @param requirement table|nil { jobs = { name = grade }, gangs = { name = grade }, onDuty }
--   `onDuty` applies to the jobs only: a gang has no shift
-- @param snapshot table|nil { job, jobs, gang, gangs, atMs }
-- @param nowMs number
-- @param policy table|nil as `Evaluate`
-- @return boolean
-- @return string|nil `Evaluate`'s codes, plus gang_required and gang_grade_too_low
function OPX.JobGate.EvaluateGroups(requirement, snapshot, nowMs, policy)
	requirement = type(requirement) == 'table' and requirement or NO_POLICY
	local jobs, gangs = requirement.jobs, requirement.gangs
	local hasJobs = type(jobs) == 'table' and next(jobs) ~= nil
	local hasGangs = type(gangs) == 'table' and next(gangs) ~= nil
	if not hasJobs and not hasGangs then return true, nil end

	local held = type(snapshot) == 'table' and snapshot or nil
	local worst = nil
	if hasJobs then
		local passed, why = OPX.JobGate.Evaluate({ jobs = jobs, onDuty = requirement.onDuty },
			held and { job = held.job, jobs = held.jobs, atMs = held.atMs } or nil, nowMs, policy)
		if passed then return true, nil end
		worst = why
	end
	if hasGangs then
		local gang = nil
		if held then
			gang = { job = type(held.gang) == 'table' and held.gang or { name = '' },
				jobs = held.gangs, atMs = held.atMs }
		end
		local passed, why = OPX.JobGate.Evaluate({ jobs = gangs }, gang, nowMs, policy)
		if passed then return true, nil end
		why = GANG_WORD[why] or why
		if worst == nil or (GROUP_RANK[why] or 0) > (GROUP_RANK[worst] or 0) then worst = why end
	end
	return false, worst
end

--- Lists what is wrong with one GANGS block: the same rule as a JOBS block.
-- @author dop42
-- @param gangs any
-- @param where string
-- @param lines table|nil
-- @return string[]
function OPX.JobGate.GangProblems(gangs, where, lines)
	lines = lines or {}
	if gangs == nil then return lines end
	if type(gangs) ~= 'table' then
		lines[#lines + 1] = where .. ': GANGS must be a table of name -> minimum grade'
		return lines
	end
	for name, minimum in pairs(gangs) do
		if type(name) ~= 'string' or finiteNumber(minimum) == nil then
			lines[#lines + 1] = where ..
				': GANGS entries are gang name -> minimum grade level, e.g. { tygerclaws = 0 }'
		end
	end
	return lines
end
