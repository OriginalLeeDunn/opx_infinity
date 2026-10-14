--- The client mirror of the server's character state, and the requests back.
-- @author dop42
--
-- The mirror is updated FIRST and the local event raised after it, so that a
-- handler reading the contract sees the change it was just told about.
--
-- Nothing here is authoritative. A modified client can rewrite every value below;
-- the server re-derives anything that matters.

local M = OPX.Modules.Get('character')

-- Degrees the yaw must move before a new report is sent.
local HEADING_EPSILON = 2.0

--- The server's PlayerData, mirrored. Empty until a character loads.
M.PlayerData = {}

--- True between loaded and unloaded.
M.IsLoggedIn = false

--- Announces this client, which is the whole of what it asks for.
-- The server answers with the character this account is LOCKED on -- loading it,
-- or making one when the lock names none. There is nothing to choose here and no
-- roster to hold: a character is changed with a command, and a command that
-- changes it ends the session.
-- @author dop42
function M.Announce()
	TriggerServerEvent(M.Event.ANNOUNCE)
end

--- Sends the name a player typed for the character they are loaded on.
-- Checked here as a courtesy to whatever asked for it; the server checks it
-- again and accepts it once, because a modified client skips this one.
-- @author dop42
-- @param firstName string
-- @param lastName string
-- @return boolean, string|nil
function M.SetName(firstName, lastName)
	local first = M.ValidateName(firstName)
	if not first.ok then return false, (M.NameRefusal(first)) end
	local last = M.ValidateName(lastName)
	if not last.ok then return false, (M.NameRefusal(last)) end

	TriggerServerEvent(M.Event.NAME, { firstName = first.value, lastName = last.value })
	return true
end

--- Whether the loaded character has been named yet.
-- A character is a row before it is anybody: it is created with no name at all,
-- and whatever asks for one asks this first.
-- @author dop42
-- @return boolean
function M.IsNamed()
	local charInfo = M.PlayerData.charInfo
	return type(charInfo) == 'table' and type(charInfo.firstName) == 'string'
		and charInfo.firstName ~= ''
end

--- The mirrored PlayerData, an empty table before login.
-- @author dop42
-- @return table
function M.GetPlayerData()
	return M.PlayerData
end

--- The live character's citizen id, or nil.
-- @author dop42
-- @return string|nil
function M.GetCitizenId()
	return M.PlayerData.citizenId
end

--- The live character's primary job, or nil.
-- @author dop42
-- @return table|nil
function M.GetJobData()
	return M.PlayerData.job
end

--- The live character's primary gang, or nil.
-- @author dop42
-- @return table|nil
function M.GetGangData()
	return M.PlayerData.gang
end

--- Whether the live character holds a job as primary.
-- @author dop42
-- @param name string
-- @param onDutyOnly boolean|nil
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.HasJob(name, onDutyOnly, minGrade)
	local job = M.PlayerData.job
	if not job or job.name ~= name then return false end
	if onDutyOnly and job.onDuty ~= true then return false end
	if minGrade ~= nil then
		local level = job.grade and job.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- Whether the live character holds a gang as primary.
-- @author dop42
-- @param name string
-- @param minGrade integer|nil Lowest grade level accepted.
-- @return boolean
function M.HasGang(name, minGrade)
	local gang = M.PlayerData.gang
	if not gang or gang.name ~= name then return false end
	if minGrade ~= nil then
		local level = gang.grade and gang.grade.level
		if type(level) ~= 'number' or level < minGrade then return false end
	end
	return true
end

--- The primary job's grade level, or -1 when the job is not held.
-- @author dop42
-- @param name string|nil
-- @return integer
function M.GetJobGrade(name)
	local job = M.PlayerData.job
	if not job or (name and job.name ~= name) then return -1 end
	return job.grade and job.grade.level or -1
end

--- The live character's balance of one money type.
-- @author dop42
-- @param moneyType string
-- @return integer
function M.GetMoney(moneyType)
	local money = M.PlayerData.money
	if not money then return 0 end
	return money[moneyType] or 0
end

--- One metadata value, or the whole metadata table.
-- @author dop42
-- @param key string|nil
-- @return any
function M.GetMetadata(key)
	local metadata = M.PlayerData.metadata
	if not metadata then return nil end
	if key == nil then return metadata end
	return metadata[key]
end

--- The local player's position as an x, y, z table.
-- @author dop42
-- @return table|nil
function M.GetPosition()
	local x, y, z = Open77.character.position()
	if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
	return { x = x, y = y, z = z }
end

--- Mirrors what the server sends, then raises the local event for it.
local function registerEvents()
	RegisterNetEvent(M.Event.LOADED, function(playerData)
		if type(playerData) ~= 'table' then return end
		M.PlayerData = playerData
		M.IsLoggedIn = true

		Open77.log.info(('[character] loaded %s (%s %s)'):format(
			tostring(playerData.citizenId),
			tostring(playerData.charInfo and playerData.charInfo.firstName),
			tostring(playerData.charInfo and playerData.charInfo.lastName)))
		TriggerEvent(M.Event.ON_LOADED, playerData)
	end)

	RegisterNetEvent(M.Event.UNLOADED, function()
		M.PlayerData = {}
		M.IsLoggedIn = false
		TriggerEvent(M.Event.ON_UNLOADED)
	end)

	RegisterNetEvent(M.Event.DATA, function(playerData)
		if type(playerData) ~= 'table' then return end
		M.PlayerData = playerData
		TriggerEvent(M.Event.ON_CHANGED, playerData)
	end)

	RegisterNetEvent(M.Event.MONEY, function(moneyType, amount, action, balance)
		if M.PlayerData.money then M.PlayerData.money[moneyType] = balance end
		TriggerEvent(M.Event.ON_MONEY, moneyType, amount, action, balance)
	end)

	RegisterNetEvent(M.Event.JOB, function(job)
		M.PlayerData.job = job
		TriggerEvent(M.Event.ON_JOB, job)
	end)

	RegisterNetEvent(M.Event.GANG, function(gang)
		M.PlayerData.gang = gang
		TriggerEvent(M.Event.ON_GANG, gang)
	end)

	-- The world coming up is the second reason to announce: the first announce
	-- goes out before the rest of the client is running and usually arrives
	-- nowhere.
	AddEventHandler(OPX.Host.WORLD_READY, function()
		M.Announce()
	end)
end

--- Reports the local heading while a character is loaded.
-- Registered with the scheduler rather than spawned as a thread: exceeding the
-- per-resume instruction budget unwinds out of a coroutine body, and a
-- `while true` loop that hits it is never resumed again, silently.
local function headingReporter()
	local lastSent

	OPX.Scheduler.Every('character.heading',
		M.Number(M.Settings.HEADING_REPORT_MS, 5000), function()
			if not M.IsLoggedIn then
				lastSent = nil
				return
			end
			-- CHECKED BY NAME, the way every other client file in this resource
			-- reads a `character` method. Unguarded, a client without `yaw`
			-- raised here every pass: the scheduler's own pcall catches it, so
			-- the cost is not a crash but a job suspended for the session and
			-- two lines in the player's journal -- a heading that silently
			-- stopped being reported, with the reason only on their PC.
			local character = Open77.character
			if type(character) ~= 'table' or type(character.yaw) ~= 'function' then return end
			local read, yaw = pcall(character.yaw)
			if not read or not OPX.Math.IsFinite(yaw) then return end
			if lastSent == nil or math.abs(yaw - lastSent) >= HEADING_EPSILON then
				lastSent = yaw
				TriggerServerEvent(M.Event.HEADING, { heading = yaw })
			end
		end)
end

--- Nothing to build before the contract: the mirror is empty by definition.
function M.Init()
end

--- Publishes the client half of the contract, the mirror and the requests.
function M.Api()
	OPX.Api.Provide('character', 1, {
		GetPlayerData = M.GetPlayerData,
		GetCitizenId = M.GetCitizenId,
		IsLoggedIn = function() return M.IsLoggedIn end,
		IsNamed = M.IsNamed,

		GetJobData = M.GetJobData,
		GetGangData = M.GetGangData,
		GetJobGrade = M.GetJobGrade,
		HasJob = M.HasJob,
		HasGang = M.HasGang,

		GetMoney = M.GetMoney,
		GetMetadata = M.GetMetadata,
		GetPosition = M.GetPosition,

		SetName = M.SetName,

		-- EVERYBODY ELSE: nothing. Never a name to a stranger -- the owner's
		-- decision -- so the server no longer replicates anybody's name, citizen
		-- id, job or gang, and these three answer empty for every player. They
		-- stay on the contract so a caller written against it keeps running. See
		-- `client/state.lua`.
		GetPlayerState = M.PlayerState.Of,
		GetPlayerName = M.PlayerState.NameOf,
		GetPlayerIdentity = M.PlayerState.IdentityOf,
	})
end

--- Registers the handlers, announces, and starts the heading reporter.
function M.Start()
	registerEvents()
	headingReporter()
	M.PlayerState.Start()
	M.Announce()
end

--- Retires the bag subscription. The mirror of the local character needs no
--- winding down: it dies with the VM.
function M.Stop()
	M.PlayerState.Stop()
end
