--- The ambient world: how many pedestrians, whether there is traffic, whether the
--- game's own police turns up -- per routing bucket, from the server.
-- @author dop42
--
-- `Open77.world.setPopulation(bucket, { crowd, traffic, police })` (permission
-- `world.population`). The server owns it and replicates it to every client in
-- the bucket; a client cannot change it. What 2.31 can actually apply, as the
-- platform says itself (`getPopulation` reports the granularity):
--   * CROWD is a real fraction of the vanilla pedestrian density, 0..1;
--   * TRAFFIC is a SWITCH -- the engine has no vehicle density modifier, so any
--     value above zero is vanilla traffic and zero is none;
--   * POLICE allows or forbids the vanilla prevention (NCPD NPC) spawns.
--
-- WHY IT LIVES BESIDE THE WEATHER: both are the world's ambience, decided once
-- by the server for everybody in a bucket, and the weather module is already
-- the authority that does that for the sky and the clock.
--
-- POLICE SHIPS OFF FOR AN RP SERVER. Vanilla NCPD units are spawned on each
-- client for that client alone -- nobody else sees them -- and a heat stage set
-- by the engine is an arrest no player officer can take part in. The police are
-- players here (`modules/police`). Switch it on in `config/weather.lua` for a
-- server without them.
--
-- A BUCKET NOBODY CONFIGURES IS THE VANILLA WORLD (1, 1, true), so a missing row
-- changes nothing. The selection buckets players stand in before they pick a
-- character are not touched here: `core/server/buckets.lua` empties those.

local M = OPX.Modules.Get('weather')

M.Population = {}
local Population = M.Population

local UINT32_MAX = 4294967295

-- The bucket -> applied policy this VM last set, for the status read.
local applied = {}

local function settings()
	local block = type(M.Settings.POPULATION) == 'table' and M.Settings.POPULATION or {}
	return block
end

--- One configured row, read into the host's shape, or nil and why.
-- @author dop42
-- @param raw table|nil { CROWD = 0..1, TRAFFIC = boolean|0..1, POLICE = boolean }
-- @return table|nil { crowd, traffic, police }
-- @return string|nil
function Population.Read(raw)
	if type(raw) ~= 'table' then return nil, 'not a table' end
	local crowd = raw.CROWD == nil and 1 or tonumber(raw.CROWD)
	if crowd == nil or crowd ~= crowd or crowd < 0 or crowd > 1 then
		return nil, 'CROWD must be a number from 0 to 1'
	end
	local traffic = raw.TRAFFIC
	if traffic == nil then traffic = true end
	if type(traffic) == 'number' then
		if traffic ~= traffic or traffic < 0 or traffic > 1 then return nil, 'TRAFFIC must be true, false or 0..1' end
		traffic = traffic > 0
	elseif type(traffic) ~= 'boolean' then
		return nil, 'TRAFFIC must be true or false'
	end
	local police = raw.POLICE
	if police == nil then police = false end
	if type(police) ~= 'boolean' then return nil, 'POLICE must be true or false' end
	return { crowd = crowd, traffic = traffic and 1 or 0, police = police }
end

--- Sets one bucket's population. Answers true, or false and the host's reason.
-- @author dop42
-- @param bucket integer
-- @param policy table { crowd, traffic, police } as `Read` answers it
-- @return boolean
-- @return string|nil
function Population.Apply(bucket, policy)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.setPopulation) ~= 'function' then
		return false, 'Open77.world.setPopulation is not on this host'
	end
	local called, ok, reason = pcall(world.setPopulation, bucket, policy)
	if not called then return false, tostring(ok) end
	if ok ~= true then return false, tostring(reason or 'refused') end
	applied[bucket] = { crowd = policy.crowd, traffic = policy.traffic, police = policy.police }
	return true
end

--- What the host says a bucket's population is, or nil.
-- @author dop42
function Population.Get(bucket)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.getPopulation) ~= 'function' then return applied[bucket] end
	local called, state = pcall(world.getPopulation, bucket)
	if called and type(state) == 'table' then return state end
	return applied[bucket]
end

-- Applies every configured row, one boot line each.
local function applyConfigured()
	local block = settings()
	if block.ENABLED == false then
		Open77.log.info('[weather] POPULATION is off: every bucket keeps the host\'s own population')
		return
	end
	local rows = type(block.BUCKETS) == 'table' and block.BUCKETS or {}
	for bucket, raw in pairs(rows) do
		local id = math.tointeger(bucket)
		if id == nil or id < 0 or id > UINT32_MAX then
			Open77.log.warn(('[weather] POPULATION.BUCKETS key %s is not a bucket id'):format(tostring(bucket)))
		else
			local policy, why = Population.Read(raw)
			if policy == nil then
				Open77.log.warn(('[weather] POPULATION bucket %d: %s; left as it was'):format(id, why))
			else
				local ok, reason = Population.Apply(id, policy)
				if ok then
					Open77.log.info(('[weather] bucket %d population: crowd %.2f, traffic %s, police %s')
						:format(id, policy.crowd, policy.traffic > 0 and 'on' or 'off',
							policy.police and 'on' or 'off'))
				else
					Open77.log.warn(('[weather] bucket %d population was refused: %s'):format(id, reason))
				end
			end
		end
	end
end

-- `/opx.population [bucket] [crowd] [traffic on|off] [police on|off]`: reads a
-- bucket with one argument, sets it with four. Live, until the next restart puts
-- the configured rows back.
local function command(source, args, raw)
	local bucket = math.tointeger(tonumber(args[1] or '0'))
	if bucket == nil or bucket < 0 or bucket > UINT32_MAX then
		return OPX.CommandNotice(source, raw, 'warning', locale('weather.population.usage'))
	end
	if args[2] == nil then
		local state = Population.Get(bucket)
		if type(state) ~= 'table' then
			return OPX.CommandResult(source, true, locale('weather.population.unset', { bucket = bucket }))
		end
		return OPX.CommandResult(source, true, locale('weather.population.status', {
			bucket = bucket,
			crowd = ('%.2f'):format(tonumber(state.crowd) or 0),
			traffic = (tonumber(state.traffic) or 0) > 0 and 'on' or 'off',
			police = state.police and 'on' or 'off',
		}))
	end
	local function flag(value)
		if value == 'on' or value == 'true' or value == '1' then return true end
		if value == 'off' or value == 'false' or value == '0' then return false end
		return nil
	end
	local policy, why = Population.Read({ CROWD = tonumber(args[2]), TRAFFIC = flag(args[3]),
		POLICE = flag(args[4]) })
	if policy == nil or flag(args[3]) == nil or flag(args[4]) == nil then
		return OPX.CommandNotice(source, raw, 'warning', locale('weather.population.usage'))
	end
	local ok, reason = Population.Apply(bucket, policy)
	OPX.CommandNotice(source, raw, ok and 'success' or 'error', ok
		and locale('weather.population.set', { bucket = bucket, crowd = ('%.2f'):format(policy.crowd),
			traffic = policy.traffic > 0 and 'on' or 'off', police = policy.police and 'on' or 'off' })
		or locale('weather.population.refused', { reason = tostring(why or reason) }))
end

--- Applies the configured rows and registers the staff command.
-- @author dop42
function Population.Start()
	applied = {}
	local ran, failure = pcall(applyConfigured)
	if not ran then Open77.log.warn('[weather] population: ' .. tostring(failure)) end
	local commands = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}
	local entry = type(commands.POPULATION) == 'table' and commands.POPULATION or nil
	if entry == nil or type(entry.NAME) ~= 'string' or entry.NAME == '' then return end
	local registered, why = pcall(OPX.Command.Register, entry.NAME,
		{ restricted = entry.RESTRICTED ~= false, help = 'weather.help.population' }, command)
	if not registered then Open77.log.warn('[weather] ' .. tostring(why)) end
end
