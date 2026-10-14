--- Job and gang memberships, for characters online or offline.
-- @author dop42
--
-- Jobs and gangs are multi-membership: a character holds a grade in any number of
-- them and one of each is primary. Every function here yields when the character
-- is not in the world, so every one of them is coroutine only.
--
-- The definitions come from the module's own configuration. They are definitions
-- and not settings: the key is stored on the character's row, so entries are
-- added freely and never renamed.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

M.Groups = {}

--- Answers a job definition by name, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.Groups.GetJob(name)
	return M.Settings.JOBS[name]
end

--- Answers a gang definition by name, or nil.
-- @author dop42
-- @param name string
-- @return table|nil
function M.Groups.GetGang(name)
	return M.Settings.GANGS[name]
end

--- Every job or gang this server defines, as a list a caller can carry: each
--- with its grades as a list ordered by level. A COPY.
-- Grades are keyed from 0 in the config, and a table keyed from 0 does not cross
-- a marshaller as a list; each grade carries its `level` instead.
-- @author dop42
-- @param groupType GroupType job or gang
-- @return table[]|nil nil for any other group type
function M.Groups.List(groupType)
	local defined = groupType == 'job' and M.Settings.JOBS
		or groupType == 'gang' and M.Settings.GANGS or nil
	if defined == nil then return nil end
	local out = {}
	for name, definition in pairs(defined) do
		local grades = {}
		for level, grade in pairs(type(definition.grades) == 'table' and definition.grades or {}) do
			if math.type(level) == 'integer' and type(grade) == 'table' then
				grades[#grades + 1] = { level = level, name = grade.name,
					payment = grade.payment, isBoss = grade.isBoss == true }
			end
		end
		table.sort(grades, function(a, b) return a.level < b.level end)
		out[#out + 1] = { name = name, label = definition.label, type = definition.type,
			defaultDuty = definition.defaultDuty == true, grades = grades }
	end
	table.sort(out, function(a, b) return a.name < b.name end)
	return out
end

--- Resolves a job and grade into the PlayerData.job shape.
-- A Result rather than nil, so a caller can tell "no such job" from "no such
-- grade in that job".
-- @author dop42
-- @param name string
-- @param grade integer|string|nil
-- @return Result
function M.Groups.ResolveJob(name, grade)
	local job = M.Settings.JOBS[name]
	if not job then return Result.Err('job.notFound', tostring(name)) end

	grade = tonumber(grade) or 0
	local rank = job.grades[grade]
	if not rank then return Result.Err('job.gradeNotFound', ('%s:%s'):format(name, grade)) end

	return Result.Ok({
		name = name,
		label = job.label,
		type = job.type,
		payment = rank.payment or 0,
		onDuty = job.defaultDuty == true,
		isBoss = rank.isBoss == true,
		bankAuth = rank.bankAuth == true,
		grade = { name = rank.name, level = grade },
	})
end

--- Resolves a gang and grade into the PlayerData.gang shape.
-- @author dop42
-- @param name string
-- @param grade integer|string|nil
-- @return Result
function M.Groups.ResolveGang(name, grade)
	local gang = M.Settings.GANGS[name]
	if not gang then return Result.Err('gang.notFound', tostring(name)) end

	grade = tonumber(grade) or 0
	local rank = gang.grades[grade]
	if not rank then return Result.Err('gang.gradeNotFound', ('%s:%s'):format(name, grade)) end

	return Result.Ok({
		name = name,
		label = gang.label,
		isBoss = rank.isBoss == true,
		bankAuth = rank.bankAuth == true,
		grade = { name = rank.name, level = grade },
	})
end

--- Answers the highest grade a contiguous grade table defines.
-- So that a caller can clamp instead of failing.
-- @author dop42
-- @param grades table
-- @return integer
function M.Groups.TopGrade(grades)
	local top = 0
	while grades[top + 1] do top = top + 1 end
	return top
end

--- Runs a change against the live Player, or a temporary offline one.
-- The Player is RE-RESOLVED after every wait: a login can arrive in the middle of
-- a change, and the change is then re-applied against the live player instead of
-- being written over the top of it.
--
-- AN OFFLINE CHANGE HOLDS THE OFFLINE LEDGER (`M.Ledger`, player.lua) for the
-- whole of its read, its hooks and its writes. It is a read-modify-write of the
-- job or gang column and of the membership rows, and a login that read the row
-- before the write landed would otherwise put the old job back with its first
-- save -- the window `AddMoneyOffline` and a staff rename already close the
-- same way. The row is settled and the roster asked again with nothing
-- yielding in between, exactly as there: a character who came online
-- meanwhile is changed in memory instead.
-- @param identifier Player|Source|CitizenId
-- @param column string|nil job or gang; nil touches memberships only.
-- @param apply fun(player: Player, offline: boolean): Result
-- @return Result
local offlineChange

--- Runs a change against a Player in the roster, and keeps it if they left
--- while it ran.
--
-- A CHANGE TO A LIVE PLAYER YIELDS -- its hooks may, and the membership row is
-- written before the memory moves -- and a logout in that window has already
-- unregistered the Player and saved it as it stood: the old job or gang
-- column, under a membership row this change already wrote or deleted. Nobody
-- saves that Player again, so a firing would come back at the next login as
-- the very job it removed, with no membership row behind it. So a Player who
-- is no longer the one registered under its connection once the change is done
-- has its column written here, under the offline ledger, after the logout's
-- own save has landed -- and a character who is already back is changed in
-- memory again, as `offlineChange` does.
local function onLive(player, column, apply)
	local outcome = apply(player, false)
	if player.Offline or column == nil then return outcome end
	if type(outcome) ~= 'table' or outcome.ok ~= true then return outcome end
	local data = player.PlayerData
	if data.source ~= nil and M.Players[data.source] == player then return outcome end

	local citizenId = data.citizenId
	if not M.Ledger.Settle(citizenId) then
		return Result.Err('error.unavailable', 'the character row is being written')
	end
	local back = M.ResolvePlayer(citizenId)
	if back and back ~= player then
		Open77.log.debug(('[groups] %s left and came back mid-change; re-applying against the ' ..
			'live player'):format(citizenId))
		return apply(back, false)
	end

	M.Ledger.Enter(citizenId)
	local ran, saved = pcall(M.Storage.SavePrimary, citizenId, column, data[column])
	M.Ledger.Leave(citizenId)
	if not ran then error(saved, 0) end
	if not saved.ok then return saved end
	return outcome
end

local function withCharacter(identifier, column, apply)
	local player = M.ResolvePlayer(identifier)
	if player then return onLive(player, column, apply) end

	if type(identifier) ~= 'string' then
		return Result.Err('error.notLoggedIn', tostring(identifier))
	end
	local parsed = OPX.CitizenId.Parse(identifier)
	if not parsed.ok then return Result.Err('character.notFound', identifier) end
	identifier = parsed.value

	if not M.Ledger.Settle(identifier) then
		return Result.Err('error.unavailable', 'the character row is being written')
	end
	player = M.ResolvePlayer(identifier)
	if player then return onLive(player, column, apply) end

	-- Left on every path, a raise included: a hold nobody gives back refuses
	-- that character's logins until the stale guard notices.
	M.Ledger.Enter(identifier)
	local ran, outcome = pcall(offlineChange, identifier, column, apply)
	M.Ledger.Leave(identifier)
	if not ran then error(outcome, 0) end
	return outcome
end

--- The offline half of `withCharacter`, run while the ledger holds the row.
offlineChange = function(identifier, column, apply)
	local fetched = M.Storage.FetchOne(identifier)
	if not fetched.ok then return fetched end

	local groups = M.Storage.FetchGroups(identifier)
	if not groups.ok then return groups end

	local player = M.ResolvePlayer(identifier)
	if player then return apply(player, false) end

	local offline = M.CreatePlayer(fetched.value, true)
	offline.PlayerData.jobs = groups.value.jobs
	offline.PlayerData.gangs = groups.value.gangs

	local outcome = apply(offline, true)
	if not outcome.ok then return outcome end

	player = M.ResolvePlayer(identifier)
	if player then
		Open77.log.debug(('[groups] %s came online mid-change; re-applying against the live ' ..
			'player'):format(identifier))
		return apply(player, false)
	end

	-- An operation that only touches membership rows writes no column at all.
	if not column then return outcome end

	local saved = M.Storage.SavePrimary(identifier, column, offline.PlayerData[column])
	if not saved.ok then return saved end
	return outcome
end

--- Writes a membership row, then records it on PlayerData.
-- The row goes first; announcing is the caller's, and no caller may skip it,
-- because the announcement is what reaches the autosave through `Revision`.
local function joinGroup(player, groupType, name, grade)
	local citizenId = player.PlayerData.citizenId
	local written = M.Storage.UpsertGroup(citizenId, groupType, name, grade)
	if not written.ok then return written end

	local bucket = groupType == 'job' and player.PlayerData.jobs or player.PlayerData.gangs
	bucket[name] = grade
	return Result.Ok(true)
end

--- Deletes a membership row, then drops it from PlayerData.
local function leaveGroup(player, groupType, name)
	local citizenId = player.PlayerData.citizenId
	local removed = M.Storage.RemoveGroup(citizenId, groupType, name)
	if not removed.ok then return removed end

	local bucket = groupType == 'job' and player.PlayerData.jobs or player.PlayerData.gangs
	bucket[name] = nil
	return Result.Ok(true)
end

--- Tells the other modules, and every other resource, where a character's
--- primary job or gang now stands.
--
-- ONE FUNCTION PER GROUP TYPE, and every change goes through it -- a set, a
-- duty change and a removal alike. A removal used to say nothing at all on the
-- internal bus: a module keeping a roster of who is on duty in a job learned
-- about a hire and a promotion and never about a firing, so the fired employee
-- stayed on its list until they logged out.
-- @param player Player
-- @param groupType string job or gang
-- @param removed string|nil the membership that was just dropped
local function announceGroup(player, groupType, removed)
	local data = player.PlayerData
	local current = groupType == 'job' and data.job or data.gang
	TriggerEvent(groupType == 'job' and M.Event.IN_JOB or M.Event.IN_GANG, data.source, current)
	OPX.Publish(groupType == 'job' and M.Event.ON_JOB or M.Event.ON_GANG, data.source, {
		citizenId = data.citizenId,
		[groupType] = OPX.Table.DeepCopy(current),
		-- EVERY MEMBERSHIP AS IT STANDS NOW, so a listener deciding what a
		-- character may keep (an AV a job issued them) reads it here, offline
		-- changes included, instead of re-reading a row it cannot reach.
		[groupType == 'job' and 'jobs' or 'gangs'] = OPX.Table.DeepCopy(
			groupType == 'job' and data.jobs or data.gangs),
		removed = removed,
		offline = player.Offline == true,
	})
end

--- Asks the hooks whether a primary job or gang may change, before anything is
--- written.
--
-- `job:beforeSet` and `gang:beforeSet`, beside the three money hooks and with
-- their shape: an explicit `false` from any hook refuses the change with
-- `job.vetoed` / `gang.vetoed`, and nothing at all is written. The payload names
-- the character -- `player`, which is an offline Player for a character nobody
-- is playing, so `offline` says which -- and what it would become. A whitelist
-- of who may hold a job, or a cooldown between promotions, is a hook rather
-- than a fork of this file.
-- @param player Player
-- @param groupType string job or gang
-- @param resolved table the ResolveJob/ResolveGang shape it would become
-- @return boolean
local function allowedToSet(player, groupType, resolved)
	return OPX.Hooks.Trigger(groupType .. ':beforeSet', {
		player = player,
		citizenId = player.PlayerData.citizenId,
		offline = player.Offline == true,
		name = resolved.name,
		grade = resolved.grade.level,
		previous = groupType == 'job' and player.PlayerData.job or player.PlayerData.gang,
	})
end

--- Makes a job at a grade the primary one, joining it if need be.
-- Duty comes from the job's own `defaultDuty` rather than being carried over --
-- when the JOB changes. A new grade in the job already being worked keeps the
-- shift it happened in (see below).
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.SetJob(identifier, name, grade)
	return withCharacter(identifier, 'job', function(player)
		local resolved = M.Groups.ResolveJob(name, grade)
		if not resolved.ok then return resolved end
		if not allowedToSet(player, 'job', resolved.value) then
			return Result.Err('job.vetoed', name)
		end

		local joined = joinGroup(player, 'job', name, resolved.value.grade.level)
		if not joined.ok then return joined end

		-- A PROMOTION IS NOT A NEW SHIFT. A job that changes starts off the
		-- clock, which is what `defaultDuty` is for; a grade that changes inside
		-- the job being worked is the same shift, and it used to clock its holder
		-- out: an officer promoted on patrol -- by a Captain at the desk, or by
		-- their own time served -- lost the radio, the patrol car, the call-outs
		-- and the seniority clock to the promotion, until they noticed and typed
		-- `/opx.duty` again. Only ON is carried: somebody off the clock stays off.
		-- READ AFTER THE WRITE, which waits on the database: a `/opx.duty` typed
		-- while the row was being written is the shift that stands.
		local current = player.PlayerData.job
		if type(current) == 'table' and current.name == name and current.onDuty == true then
			resolved.value.onDuty = true
		end

		player.PlayerData.job = resolved.value
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.JOB, player.PlayerData.source, resolved.value)
		end
		announceGroup(player, 'job')

		OPX.Audit.Player(player, 'job.set', ('%s grade %d'):format(name, resolved.value.grade.level))
		return Result.Ok(resolved.value)
	end)
end

--- Clocks a character in or out of their primary job.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param onDuty boolean
-- @return Result
function M.Groups.SetJobDuty(identifier, onDuty)
	return withCharacter(identifier, 'job', function(player)
		local job = player.PlayerData.job
		local definition = M.Groups.GetJob(job.name)
		if not definition then return Result.Err('job.notFound', job.name) end
		-- A job that is on duty by definition has no shift to clock into.
		if definition.defaultDuty then
			return Result.Err('job.noDuty', job.name)
		end

		job.onDuty = onDuty == true
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.JOB, player.PlayerData.source, job)
			OPX.NotifyLocale(player.PlayerData.source, job.onDuty and 'job.onDuty' or 'job.offDuty')
		end
		announceGroup(player, 'job')
		return Result.Ok(job.onDuty)
	end)
end

--- Adds a job membership without changing the primary job.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.AddPlayerToJob(identifier, name, grade)
	return withCharacter(identifier, nil, function(player)
		local resolved = M.Groups.ResolveJob(name, grade)
		if not resolved.ok then return resolved end
		local joined = joinGroup(player, 'job', name, resolved.value.grade.level)
		if not joined.ok then return joined end
		player.Functions.UpdatePlayerData()
		-- ANNOUNCED LIKE EVERY OTHER CHANGE: a membership moved here (a desk
		-- demotion in a job held beside the worked one, offline or not) is a
		-- change a listener has to hear -- what the job let them keep follows it.
		announceGroup(player, 'job')
		return joined
	end)
end

--- The job a character falls back to working when the one they work is taken
--- away: another job they still hold, or the default job when they hold none.
--
-- ANOTHER JOB STILL HELD COMES BEFORE THE DEFAULT. A character holds any number
-- of jobs and works one, and taking away the one they worked used to drop them
-- to the default whatever else they held: a MaxTac operator -- an NCPD Detective
-- by definition -- dismissed from the division was left Unemployed with the badge
-- still on the books, and no patrol car, no radio and a freelancer's pay until
-- somebody moved them by hand. The job held at the highest grade is worked
-- instead, ties broken by name so the answer never depends on table order; like
-- any change of job it starts off the clock (`ResolveJob` reads `defaultDuty`).
-- @param player Player
-- @return Result the PlayerData.job shape
local function fallbackJob(player)
	local default = M.Settings.PLAYER.DEFAULT_JOB
	local best, bestGrade = nil, -1
	for held, grade in pairs(type(player.PlayerData.jobs) == 'table' and player.PlayerData.jobs or {}) do
		local level = tonumber(grade)
		if type(held) == 'string' and held ~= default and level ~= nil
			and M.Groups.GetJob(held) ~= nil
			and (level > bestGrade or (best ~= nil and level == bestGrade and held < best)) then
			best, bestGrade = held, level
		end
	end
	if best ~= nil then
		local resolved = M.Groups.ResolveJob(best, bestGrade)
		if resolved.ok then return resolved end
	end
	return M.Groups.ResolveJob(default, 0)
end

--- Removes a job membership, falling back to another job still held, or to the
--- default job.
-- The fallback matters: a fired employee would otherwise keep drawing the salary.
-- The announcement happens even for a job that was not primary, because
-- `leaveGroup` has changed `PlayerData.jobs`.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.RemovePlayerFromJob(identifier, name)
	return withCharacter(identifier, 'job', function(player)
		-- Nothing to leave is answered, not announced as a removal nobody made.
		if player.PlayerData.jobs[name] == nil and player.PlayerData.job.name ~= name then
			return Result.Err('job.notMember', tostring(name))
		end
		local left = leaveGroup(player, 'job', name)
		if not left.ok then return left end

		local announced = false
		if player.PlayerData.job.name == name then
			local fallback = fallbackJob(player)
			if fallback.ok then
				player.PlayerData.job = fallback.value
				player.Functions.UpdatePlayerData()
				announced = true
				if not player.Offline then
					TriggerClientEvent(M.Event.JOB, player.PlayerData.source, fallback.value)
				end
			end
		end

		if not announced then player.Functions.UpdatePlayerData() end
		announceGroup(player, 'job', name)

		OPX.Audit.Player(player, 'job.removed', name)
		return Result.Ok(true)
	end)
end

--- Makes one of a character's existing jobs the primary one.
-- Refuses a job the character is not a member of rather than joining it.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.SetPlayerPrimaryJob(identifier, name)
	return withCharacter(identifier, 'job', function(player)
		local grade = player.PlayerData.jobs[name]
		if grade == nil then return Result.Err('job.notMember', name) end
		return M.Groups.SetJob(player, name, grade)
	end)
end

--- Makes a gang at a grade the primary one, joining it if need be.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.SetGang(identifier, name, grade)
	return withCharacter(identifier, 'gang', function(player)
		local resolved = M.Groups.ResolveGang(name, grade)
		if not resolved.ok then return resolved end
		if not allowedToSet(player, 'gang', resolved.value) then
			return Result.Err('gang.vetoed', name)
		end

		local joined = joinGroup(player, 'gang', name, resolved.value.grade.level)
		if not joined.ok then return joined end

		player.PlayerData.gang = resolved.value
		player.Functions.UpdatePlayerData()

		if not player.Offline then
			TriggerClientEvent(M.Event.GANG, player.PlayerData.source, resolved.value)
		end
		announceGroup(player, 'gang')

		OPX.Audit.Player(player, 'gang.set',
			('%s grade %d'):format(name, resolved.value.grade.level))
		return Result.Ok(resolved.value)
	end)
end

--- Adds a gang membership without changing the primary gang.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param grade integer
-- @return Result
function M.Groups.AddPlayerToGang(identifier, name, grade)
	return withCharacter(identifier, nil, function(player)
		local resolved = M.Groups.ResolveGang(name, grade)
		if not resolved.ok then return resolved end
		local joined = joinGroup(player, 'gang', name, resolved.value.grade.level)
		if not joined.ok then return joined end
		player.Functions.UpdatePlayerData()
		return joined
	end)
end

--- Removes a gang membership, falling back to the default gang.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.RemovePlayerFromGang(identifier, name)
	return withCharacter(identifier, 'gang', function(player)
		-- Nothing to leave is answered, not announced as a removal nobody made.
		if player.PlayerData.gangs[name] == nil and player.PlayerData.gang.name ~= name then
			return Result.Err('gang.notMember', tostring(name))
		end
		local left = leaveGroup(player, 'gang', name)
		if not left.ok then return left end

		local announced = false
		if player.PlayerData.gang.name == name then
			local fallback = M.Groups.ResolveGang(M.Settings.PLAYER.DEFAULT_GANG, 0)
			if fallback.ok then
				player.PlayerData.gang = fallback.value
				player.Functions.UpdatePlayerData()
				announced = true
				if not player.Offline then
					TriggerClientEvent(M.Event.GANG, player.PlayerData.source, fallback.value)
				end
			end
		end

		if not announced then player.Functions.UpdatePlayerData() end
		announceGroup(player, 'gang', name)

		OPX.Audit.Player(player, 'gang.removed', name)
		return Result.Ok(true)
	end)
end

--- Makes one of a character's existing gangs the primary one.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @return Result
function M.Groups.SetPlayerPrimaryGang(identifier, name)
	return withCharacter(identifier, 'gang', function(player)
		local grade = player.PlayerData.gangs[name]
		if grade == nil then return Result.Err('gang.notMember', name) end
		return M.Groups.SetGang(player, name, grade)
	end)
end

--- Answers everyone in a job or gang, online or not. Coroutine only: it reads
--- the database.
-- @author dop42
-- @param groupType GroupType
-- @param name string
-- @return Result
function M.Groups.GetGroupMembers(groupType, name)
	if groupType ~= 'job' and groupType ~= 'gang' then
		return Result.Err('error.badRequest', tostring(groupType))
	end
	return M.Storage.MembersOf(groupType, name)
end

--- Whether a loaded character holds a job as their primary one.
-- Memory only; never yields.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param onDutyOnly boolean|nil
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.Groups.HasJob(identifier, name, onDutyOnly, minGrade)
	local player = M.ResolvePlayer(identifier)
	local job = player and player.PlayerData.job
	if not job or job.name ~= name then return false end
	if onDutyOnly and job.onDuty ~= true then return false end
	if minGrade ~= nil then
		local level = job.grade and job.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Whether a loaded character holds a gang as their primary one.
-- @author dop42
-- @param identifier Player|Source|CitizenId
-- @param name string
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.Groups.HasGang(identifier, name, minGrade)
	local player = M.ResolvePlayer(identifier)
	local gang = player and player.PlayerData.gang
	if not gang or gang.name ~= name then return false end
	if minGrade ~= nil then
		local level = gang.grade and gang.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Lists loaded characters whose primary job is the one named.
-- Memory only; never yields.
-- @author dop42
-- @param name string
-- @param onDutyOnly boolean|nil
-- @return Player[]
function M.Groups.GetPlayersByJob(name, onDutyOnly)
	local out, n = {}, 0
	local players = M.GetPlayers()
	for i = 1, #players do
		local job = players[i].PlayerData.job
		if job.name == name and (not onDutyOnly or job.onDuty) then
			n = n + 1
			out[n] = players[i]
		end
	end
	return out
end

--- Lists loaded characters whose primary gang is the one named.
-- @author dop42
-- @param name string
-- @return Player[]
function M.Groups.GetPlayersByGang(name)
	local out, n = {}, 0
	local players = M.GetPlayers()
	for i = 1, #players do
		if players[i].PlayerData.gang.name == name then
			n = n + 1
			out[n] = players[i]
		end
	end
	return out
end
