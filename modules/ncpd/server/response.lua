--- The response: what the city puts on the street for a wanted player.
-- @author XEROX710
--
-- THE LEDGER DECIDES THE STAGE; THIS FILE PUTS SOMETHING AT IT. It never scores
-- anything, never reads a crime and never decides who is wanted -- it takes a
-- stage, reads the config's own response rows for it, and stands the configured
-- records in the world around the player the ledger named.
--
-- WHY THE MODULE SPAWNS ANYTHING AT ALL. The engine already wires a response to
-- each heat stage (`OnHeatChanged` spawns that stage's units), and the platform
-- deliberately suppresses it for the session because vanilla prevention would
-- otherwise police every player in the world from one player's stars. The units
-- here are the platform's OWN entities -- `Open77.vehicles.create` and
-- `Open77.npcs.create` -- which are server-authoritative, carry network identity
-- and are therefore kept, exactly like the pursuit mode's own roadblocks. That
-- is what makes a wanted player's response real today without changing the
-- session's population policy, which is an operator decision and not this
-- module's to make.
--
-- THE AV IS NOT SPAWNED HERE, AND CANNOT BE. `PreventionSpawnSystem.RequestAVSpawn`
-- is a scripted method that runs inside a client's own script frame, so the AV is
-- REQUESTED by the wanted player's own client (see `client/main.lua`) and the
-- frame's own fly-in, propulsion note and red warning lines arrive with it. What
-- this file does at the MaxTac stage is mark the crossing so the client asks.
--
-- TROOPERS ARE BOTS BY DEFAULT, AND THE CONFIG SAYS SO. `MAXTAC.FILL` decides
-- whether an empty seat becomes an engine trooper; this file counts the players
-- who hold the division's right or job and fills the rest of `SQUAD.SEATS` with
-- the engine's own trooper records, so an empty division never means an empty
-- street. Seating a PLAYER as a trooper needs a duty/teleport half the platform
-- does not have yet, and pretending otherwise here would be a squad that never
-- arrives.
--
-- EVERY SPAWN IS NAMED IN THE LOG, INCLUDING THE FAILURES. A refused record is a
-- street with nobody on it, and `%s_api_unavailable:%s` is the shape that says
-- which permission or which host contract is missing rather than leaving the
-- reader to infer it from an empty scene.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

local Response = {}
M.Response = Response

--- What this module has standing in the world, per character.
-- @field stage number the stage these units answer
-- @field wanted number the stage the ledger asked for (above `stage` while a
--   cyberpsycho waits for a MaxTac squad)
-- @field vehicles table[] ids returned by the host
-- @field npcs table[] ids returned by the host
-- @field queued boolean MaxTac was committed elsewhere: NCPD holds them
-- @field trimmed table `{ units, vehicles }` the ceiling held back
local deployed = {}

-- ── the ceiling ──────────────────────────────────────────────────────────────
--
-- THE STREET HAS ROOM FOR SO MANY, FOR EVERYBODY AT ONCE. The owner,
-- 2026-10-07: "theres a stacking bug spawning in reapedetly maxtac agents more
-- and more its slowing my game down almost crashing". The lab's server log had
-- 35 responses standing at once -- 265 officers and troopers, 126 cars -- because
-- every wanted character was stood a whole response of their own and nothing
-- ever counted them together. `LIMITS` in config/ncpd.lua is that count: NCPD
-- officers and cars across every response, and how many MaxTac squads are out.

--- A whole number from config inside a band, or the fallback.
local function whole(value, low, high, fallback)
	local read = tonumber(value)
	if read == nil or read ~= read or read < low or read > high then return fallback end
	return math.floor(read)
end

--- The street's ceiling. A missing or malformed block is the defaults;
--- `LIMITS = false` is no ceiling at all (the old shape).
-- @return table|nil `{ units, vehicles, squads }`, nil when there is none
local function limits()
	-- Read in two steps: `a and false or nil` is nil, and `false` is the switch.
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.LIMITS end
	if declared == false then return nil end
	local block = type(declared) == 'table' and declared or {}
	return {
		units = whole(block.UNITS, 0, 1000, 24),
		vehicles = whole(block.VEHICLES, 0, 500, 10),
		squads = whole(block.MAXTAC_SQUADS, 0, 32, 1),
	}
end
Response.Limits = limits

--- What every response but one has standing: NCPD officers and cars, and the
--- MaxTac squads (a squad is counted whole, never against NCPD's room).
-- @param except string|nil the citizen whose own response is not counted
-- @return table `{ units, vehicles, squads }`
local function standing(except)
	local used = { units = 0, vehicles = 0, squads = 0 }
	for citizenId, held in pairs(deployed) do
		if citizenId ~= except then
			if held.division == M.DIVISION.MAXTAC then
				used.squads = used.squads + 1
			else
				used.units = used.units + #(held.npcs or {})
				used.vehicles = used.vehicles + #(held.vehicles or {})
			end
		end
	end
	return used
end

--- The stage that holds a cyberpsycho while every MaxTac squad is out: the
--- highest stage below theirs that NCPD answers, or nil when the ladder has none.
-- @param stage number
-- @return number|nil
local function holdStage(stage)
	for below = stage - 1, 1, -1 do
		local row = Law.Stage(below)
		if row ~= nil and row.Division ~= nil and row.Division ~= M.DIVISION.MAXTAC then
			return below
		end
	end
	return nil
end

--- A host call that cannot take the module down with it.
-- The pursuit mode's own idiom, and the reason is the same: a record the host
-- refuses answers `nil, reason`, while a call on a host that does not have the
-- contract at all raises. Both have to be a named refusal here.
-- @param namespace string `vehicles` or `npcs`
-- @param name string
-- @return any id, or nil
-- @return string|nil the refusal
local function safeCall(namespace, name, ...)
	local api = Open77 and Open77[namespace]
	if type(api) ~= 'table' or type(api[name]) ~= 'function' then
		return nil, ('%s_api_unavailable:%s'):format(namespace, name)
	end
	local ok, result, reason = pcall(api[name], ...)
	if not ok then return nil, tostring(result) end
	if result == nil then return nil, reason or 'rejected' end
	return result, reason
end

--- Where one player is, and the bucket they are in.
-- @param playerId number
-- @return table|nil `{ x, y, z, bucket }`
local function where(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = tonumber(position.bucket) or 0 }
end

--- A point `radius` metres from `centre`, on one of `count` evenly spaced bearings.
-- The first bearing is always +X, so a two-unit response stands either side of
-- the player rather than both on the same side.
-- @param centre table `{ x, y, z }`
-- @param index number 1-based
-- @param count number
-- @param radius number
-- @return table a position
local function bearing(centre, index, count, radius)
	local radians = (index - 1) / math.max(1, count) * math.pi * 2.0
	return {
		x = centre.x + math.cos(radians) * radius,
		y = centre.y + math.sin(radians) * radius,
		z = centre.z,
	}
end

--- The heading from one point to another, in the game's degrees: 0 faces +Y
--- and it grows counter-clockwise, so +X is 270 (`docs/camera.md`). This used
--- to answer the math angle (`atan(dy, dx)`, 0 = +X), 90 degrees off: every
--- officer stood side-on to the person they came for, every car parked across
--- the way it was meant to face, and the roadblock showed its nose instead of
--- its flank.
-- @param from table
-- @param to table
-- @return number
local function facing(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(-dx, dy)) % 360.0
end

--- The host's own vehicle flag mask.
-- @param spec table `{ siren = boolean, locked = boolean, immortal = boolean }`
-- @return integer|nil nil when the host's flag table is unavailable
local function vehicleFlags(spec)
	local flags = Open77 and Open77.vehicles and Open77.vehicles.flags
	if type(flags) ~= 'table' then return nil end
	local mask = flags.lightsOn or 0
	if spec.siren ~= false then mask = mask | (flags.sirenOn or 0) end
	if spec.locked == true then mask = mask | (flags.locked or 0) end
	if spec.immortal == true then mask = mask | (flags.immortal or 0) end
	return mask
end

--- Stands one configured vehicle at a position.
-- @return string|nil id
-- @return string|nil refusal
local function carry(record, at, yaw, bucket, spec)
	local definition = {
		record = record,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = yaw,
		bucket = bucket,
		health = 1.0,
		flags = vehicleFlags(spec),
	}
	return safeCall('vehicles', 'create', definition)
end

--- Tells one spawned officer who its enemies are, and who they are not.
--
-- WHY THIS IS NOT OPTIONAL. A body that carries no attitude row at all keeps
-- whatever the engine's own relationship table says about it, and two puppets a
-- script spawned are not necessarily on the same side of it: in game the squad
-- stood in the street and shot EACH OTHER while the wanted player walked away --
-- the exact symptom a response with no opinion produces. Two rows fix it, and
-- the first is the one that matters:
--
--   * `default` covers every target the officer has no row for. Neutral, so the
--     squad does not fire on each other, on bystanders, or on traffic. Neutral
--     rather than friendly on purpose: friendly would make a squad that will not
--     shoot back at all.
--   * `players[<the charged player>]` is the one hostile row, and it is the only
--     player this response was raised for. Hostility is per NPC and per target --
--     the only shape the engine can express per incarnation -- so a second
--     player standing beside the first is not a target simply for being there.
--
-- The refusal is returned, never swallowed: an officer created without these
-- rows is a body that will stand in the street and do nothing, which is the
-- failure this function exists to remove, and one line in the node's log is the
-- difference between that and a mystery.
-- @param id string the created NPC
-- @param playerId number|nil the charged player, when the caller knows it
-- @return boolean set
-- @return string|nil why not
local function opinionate(id, playerId, group)
	local npcs = Open77 and Open77.npcs
	if npcs == nil or type(npcs.setAttitude) ~= 'function' then
		return false, 'npc_attitude_unavailable'
	end

	-- Every row is attempted even when an earlier one fails, because they are
	-- three independent facts about one body -- who it ignores, who it is
	-- sworn against, and which side it belongs to -- and a body missing one of
	-- them is still better than one missing all three. The FIRST failure is
	-- what the caller reports, so a broken `setGroup` cannot hide a broken
	-- `setAttitude` behind it.
	local why = nil

	local ok, refusal = npcs.setAttitude(id, 'neutral')
	if ok ~= true then why = tostring(refusal or 'npc_attitude_refused') end

	if playerId ~= nil then
		local aimed, aimedWhy = npcs.setAttitude(id, 'hostile', { towards = playerId })
		if aimed ~= true and why == nil then why = tostring(aimedWhy or 'npc_attitude_refused') end
	end

	-- THE SQUAD IS ONE SIDE, and this is what makes it so. A body with no group
	-- is resolved by the base game's own faction rules, and two of the records
	-- this module stands -- the `Character.prevention_maxtac_*` ground pair and
	-- the `Character.maxtac_av_*` family the aircraft carries -- are hostile to
	-- each other in those rules. That is the fratricide: the client's own combat
	-- funnel counted it (`npcVersusNpc`, `crossfireHits`) and in game the squad
	-- shoots itself. Two NPCs sharing a non-empty group are allies
	-- (`wiki/npcs.md`), so the whole element is sworn in to ONE group per
	-- division: the ground units, the roadblock and the troops that step out of
	-- the AV all end up in the same one, and the divisions do not need a row
	-- between them because every officer already carries a `neutral` default.
	if group ~= nil and type(npcs.setGroup) == 'function' then
		local sworn, groupWhy = npcs.setGroup(id, group)
		if sworn ~= true and why == nil then
			why = ('group:%s'):format(tostring(groupWhy or 'npc_group_refused'))
		end
	end

	return why == nil, why
end

--- The one group every officer of a division stands in.
-- Per DIVISION and not per response on purpose: two officers of the same kind,
-- raised for two different wanted players in the same street, are colleagues.
-- @param division string|nil
-- @return string
local function divisionGroup(division)
	return ('opx-ncpd-%s'):format(tostring(division or M.DIVISION.NCPD))
end

--- Stands one configured character at a position, facing the player.
-- @return string|nil id
-- @return string|nil refusal
local function officer(record, at, yaw, bucket, held, target, group)
	local npcs = Open77 and Open77.npcs
	local ai = npcs and npcs.ai
	local damage = npcs and npcs.damage
	local id, reason = safeCall('npcs', 'create', {
		record = record,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = yaw,
		bucket = bucket,
		-- Mortal on purpose: a wanted player is allowed to fight their way out,
		-- and an immortal response is a wall rather than a chase.
		damagePolicy = damage and damage.mortal or nil,
		-- The 100-point scale a relayed hit is priced on (`server/hits.lua`),
		-- said outright: the platform projects a body's health as a fraction of
		-- its maximum, and a hit priced on one scale against a pool on another
		-- is a body that dies in one shot or in fifty.
		health = 100,
		maxHealth = 100,
		aiMode = ai and ai.native or nil,
		despawnWhenUnobserved = false,
		persistent = false,
	})
	if id == nil then return nil, reason end

	-- The opinion goes on the body that was just created, so a squad is never
	-- standing there with no idea whose side it is on. The officer is KEPT when
	-- this fails -- it exists in the world either way -- and the reason is
	-- reported beside the spawn refusals rather than logged here, so the caller
	-- that owns the bookkeeping is still the only thing that writes it.
	local opinionated, why = opinionate(id, target, group)
	if not opinionated and type(held) == 'table' then
		held.refused[#held.refused + 1] = ('attitude:%s:%s'):format(record, tostring(why))
	end
	return id
end

--- The roster a stage's officers are drawn from.
-- MaxTac answers with its own ground records; every NCPD stage with the config's
-- police roster.
-- @param division string|nil
-- @return table[] records
local function rosterFor(division)
	local ncpd = M.Settings.NCPD
	local officers = type(ncpd) == 'table' and ncpd.OFFICERS or {}
	if division == M.DIVISION.MAXTAC then
		local maxtac = Law.Maxtac
		if maxtac ~= nil and type(maxtac.Ground) == 'table' and #maxtac.Ground > 0 then
			return maxtac.Ground
		end
	end
	if type(officers) ~= 'table' then return {} end
	return officers
end

--- Takes everything this character's response put down.
-- @param citizenId string
-- @return integer how many units were removed
local function dismantle(citizenId)
	-- The insertion goes down first, and before the early return: an aircraft
	-- still holding a bucket its own response no longer owns cannot be posed
	-- again by anybody, so a cleared stage would leave it hanging over the
	-- street for as long as the session lasted.
	local av = M.Av
	if av ~= nil and type(av.Retract) == 'function' then
		av.Retract(citizenId, 'the response was taken down')
	end

	local held = deployed[citizenId]
	if held == nil then return 0 end
	deployed[citizenId] = nil

	local removed = 0
	for _, id in ipairs(held.vehicles or {}) do
		if safeCall('vehicles', 'remove', id) then removed = removed + 1 end
	end
	for _, id in ipairs(held.npcs or {}) do
		if safeCall('npcs', 'remove', id) then removed = removed + 1 end
	end
	return removed
end

--- Removes everything a character's response owns. Safe to call for anybody.
-- @param citizenId string
-- @return integer how many units were removed
function Response.Release(citizenId)
	return dismantle(citizenId)
end

--- Whether the engine may spawn police in one bucket, and the write that says so.
--
-- WHY THE SERVER HAS TO ASK AT ALL. The three switches that decide whether a heat
-- stage produces anything -- `SetSystemLock`, `SetBlockOnFootSpawn`,
-- `SetBlockVehicleSpawn` -- are driven by the CLIENT from the SERVER'S per-bucket
-- ambient policy: `blockPolice = suppressVanilla && !police`
-- (`client/src/world/VehicleSpawnPolicy.cpp`). Every Open77 client starts from an
-- EMPTY policy -- no crowd, no traffic, no police -- so on a node that never names
-- this bit the engine has been told to spawn nothing: the ladder sets a stage, the
-- stars come up, the street stays empty, and the MaxTac AV request is refused at
-- the client before it is ever sent (`police_disallowed`).
--
-- Crowd and traffic are read back and written UNCHANGED, so this moves the police
-- axis and nothing else: an empty street stays empty. It is idempotent, and the
-- line is printed once per bucket, when the write actually happens.
-- @param bucket number
-- @return boolean allowed
-- @return string|nil why not
local function allowPolice(bucket)
	local world = Open77 and Open77.world
	if world == nil or type(world.setPopulation) ~= 'function'
		or type(world.getPopulation) ~= 'function' then
		return false, 'population_api_unavailable'
	end

	local policy, readWhy = world.getPopulation(bucket)
	if type(policy) ~= 'table' then
		return false, tostring(readWhy or 'population_unreadable')
	end
	if policy.police == true then return true end

	local crowd = tonumber(policy.crowd) or 0.0
	local traffic = tonumber(policy.traffic) or 0.0
	local ok, writeWhy = world.setPopulation(bucket, {
		crowd = crowd, traffic = traffic, police = true })
	if ok ~= true then return false, tostring(writeWhy or 'population_refused') end

	Open77.log.info(('[ncpd] bucket %d allows police: crowd %.2f and traffic %.2f unchanged, ' ..
		'the engine may answer a heat stage'):format(bucket, crowd, traffic))
	return true
end

--- Names the bucket's ambient policy as one that allows police.
--
-- Exported because a node wants this true BEFORE anybody is charged: the client
-- refuses to raise its own heat while its policy has not heard the bit yet, so a
-- stage applied in that window is a star with no unit behind it. `M.Start` calls
-- it for the default world bucket; `Response.Apply` calls it for whatever bucket
-- the charged player is actually in, which is the only place that is knowable.
-- @param bucket number
-- @return boolean allowed
-- @return string|nil why not
function Response.AllowPolice(bucket)
	return allowPolice(tonumber(bucket) or 0)
end

--- Stands the response for one stage up, and takes the previous stage down.
--
-- The previous stage is always removed first, including when the new stage is 0:
-- a player who has been cleared has nothing standing, and a player who climbed
-- must not keep the cars of three stages at once.
--
-- Under the ceiling (`LIMITS`): NCPD stands what the other responses leave of
-- its officers and cars, and a cyberpsycho past `MAXTAC_SQUADS` is held by NCPD's
-- top stage. Both are topped up by `Response.Refill` when room comes free.
-- @param citizenId string
-- @param playerId number
-- @param stage number the engine's heat stage to answer
-- @return table a `Result`: `{ ok, value = { stage, wanted, vehicles, npcs, refused, av,
--   queued, trimmed } }`
function Response.Apply(citizenId, playerId, stage)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end

	local freed = dismantle(citizenId)
	if stage == nil or stage == 0 then
		return OPX.Result.Ok({ stage = 0, vehicles = 0, npcs = 0, freed = freed, av = false })
	end

	local row = Law.Stage(stage)
	if row == nil or row.Response == nil then
		return OPX.Result.Err('ncpd.unknownStage', tostring(stage))
	end

	local at = where(playerId)
	if at == nil then
		return OPX.Result.Err('ncpd.noPosition', tostring(playerId))
	end

	-- ONE MAXTAC SQUAD PER CYBERPSYCHO, AND ONLY SO MANY SQUADS. A psycho past
	-- `LIMITS.MAXTAC_SQUADS` is still at MaxTac's stage -- the stars, the alarm
	-- and the call-out are the ledger's and unchanged -- but the bodies standing
	-- for them are NCPD's top stage until a squad is free (`Response.Refill`).
	local wanted = stage
	local ceiling = limits()
	local used = standing(citizenId)
	local queued = false
	if ceiling ~= nil and row.Division == M.DIVISION.MAXTAC and used.squads >= ceiling.squads then
		queued = true
		local hold = holdStage(stage)
		stage = hold or 0
		row = hold ~= nil and Law.Stage(hold) or { Division = M.DIVISION.NCPD, Response = { UNITS = 0, VEHICLES = {} } }
	end

	local division = row.Division
	local response = row.Response
	local held = { stage = stage, wanted = wanted, division = division, vehicles = {}, npcs = {},
		refused = {}, playerId = playerId, since = OPX.Now(), queued = queued,
		trimmed = { units = 0, vehicles = 0 }, granted = { units = 0, vehicles = 0 } }
	deployed[citizenId] = held

	-- NCPD'S ROOM: what every other response leaves of `LIMITS.UNITS` and
	-- `LIMITS.VEHICLES`. The cars are granted in proportion to the officers, so a
	-- street with room for two officers is not given four empty cars.
	local unitsWanted = math.max(0, math.floor(tonumber(response.UNITS) or 0))
	local carsWanted = #(type(response.VEHICLES) == 'table' and response.VEHICLES or {})
	do
		local ncpdBlock = M.Settings.NCPD
		local spec = type(ncpdBlock) == 'table' and ncpdBlock.ROADBLOCK or nil
		if response.ROADBLOCK == true and type(spec) == 'table' and carsWanted > 0 then
			carsWanted = carsWanted + math.max(1, math.floor(tonumber(spec.CARS) or 2))
			unitsWanted = unitsWanted + math.max(0, math.floor(tonumber(spec.OFFICERS) or 0))
		end
	end
	local room = nil
	if ceiling ~= nil and division ~= M.DIVISION.MAXTAC then
		local unitsGranted = math.min(unitsWanted, math.max(0, ceiling.units - used.units))
		local carsGranted = math.min(carsWanted, math.max(0, ceiling.vehicles - used.vehicles))
		if unitsGranted < unitsWanted then
			carsGranted = math.min(carsGranted, unitsGranted > 0
				and math.ceil(carsWanted * unitsGranted / math.max(1, unitsWanted)) or 0)
		end
		room = { units = unitsGranted, vehicles = carsGranted }
		held.granted = { units = unitsGranted, vehicles = carsGranted }
	end

	--- Whether one more of a kind fits under the ceiling; a miss is counted.
	-- @param kind string `units` or `vehicles`
	-- @return boolean
	local function fits(kind)
		if room == nil then return true end
		if room[kind] <= 0 then
			held.trimmed[kind] = held.trimmed[kind] + 1
			return false
		end
		room[kind] = room[kind] - 1
		return true
	end

	-- Before a single unit: the bucket has to allow police, or every spawn below
	-- this line is being asked of an engine that has been told to spawn nothing.
	-- See `allowPolice`; a refusal is reported, not swallowed, because a stage
	-- with no response is the one outcome an operator cannot see the cause of.
	local allowed, allowedWhy = allowPolice(at.bucket)
	if not allowed then
		held.refused[#held.refused + 1] = ('police:%s'):format(tostring(allowedWhy))
	end

	-- How many officers this stage tried to stand. A stage whose officers were
	-- all refused is not a response with fewer officers -- it is cars parked in
	-- the street, which in game reads as a squad that arrived and stopped. The
	-- count is what lets the guard at the end tell those two apart.
	local attempted = 0

	-- ── the cars ────────────────────────────────────────────────────────────
	local vehicles = type(response.VEHICLES) == 'table' and response.VEHICLES or {}
	for index = 1, #vehicles do
		if fits('vehicles') then
			local at2 = bearing(at, index, #vehicles, 14.0)
			local id, reason = carry(vehicles[index], at2, facing(at2, at), at.bucket, { siren = true })
			if id == nil then
				held.refused[#held.refused + 1] = ('%s:%s'):format(vehicles[index], tostring(reason))
			else
				held.vehicles[#held.vehicles + 1] = id
			end
		end
	end

	-- ── the officers ────────────────────────────────────────────────────────
	local roster = rosterFor(division)
	local units = tonumber(response.UNITS) or 0
	for index = 1, units do
		local record = roster[((index - 1) % math.max(1, #roster)) + 1]
		if record == nil then break end
		if fits('units') then
			local at2 = bearing(at, index, units, 8.0)
			attempted = attempted + 1
			local id, reason = officer(record, at2, facing(at2, at), at.bucket, held, playerId,
				divisionGroup(division))
			if id == nil then
				held.refused[#held.refused + 1] = ('%s:%s'):format(record, tostring(reason))
			else
				held.npcs[#held.npcs + 1] = id
			end
		end
	end

	-- ── the roadblock, at the stages that declare one ────────────────────────
	local ncpd = M.Settings.NCPD
	local blockSpec = type(ncpd) == 'table' and ncpd.ROADBLOCK or nil
	if response.ROADBLOCK == true and type(blockSpec) == 'table' and #vehicles > 0 then
		local ahead = tonumber(blockSpec.AHEAD_METERS) or 12.0
		local spacing = tonumber(blockSpec.SPACING_METERS) or 4.0
		local centre = { x = at.x, y = at.y + ahead, z = at.z }
		local cars = math.max(1, math.floor(tonumber(blockSpec.CARS) or 2))
		for index = 1, cars do
			if fits('vehicles') then
				local slot = index - (cars + 1) / 2
				local at2 = { x = centre.x + slot * spacing, y = centre.y, z = centre.z }
				-- Across the player's path rather than along it: the blockade
				-- presents its flank, which is what makes it a wall.
				local id, reason = carry(vehicles[1], at2, (facing(at, at2) + 90.0) % 360.0, at.bucket,
					{ siren = true, locked = true, immortal = true })
				if id == nil then
					held.refused[#held.refused + 1] = ('roadblock:%s:%s'):format(vehicles[1], tostring(reason))
				else
					held.vehicles[#held.vehicles + 1] = id
				end
			end
		end
		local blockOfficers = math.max(0, math.floor(tonumber(blockSpec.OFFICERS) or 0))
		for index = 1, blockOfficers do
			local record = roster[((index - 1) % math.max(1, #roster)) + 1]
			if record == nil then break end
			if fits('units') then
				local at2 = bearing(centre, index, blockOfficers, 4.0)
				attempted = attempted + 1
				-- Behind the cars, facing the person the block is for.
				local id, reason = officer(record, at2, facing(at2, at), at.bucket, held, playerId,
					divisionGroup(division))
				if id == nil then
					held.refused[#held.refused + 1] = ('roadblock:%s:%s'):format(record, tostring(reason))
				else
					held.npcs[#held.npcs + 1] = id
				end
			end
		end
	end

	-- ── MaxTac: the squad, and the AV it arrives in ─────────────────────────
	--
	-- THE SQUAD ARRIVES FROM THE AIRCRAFT, NOT ON THE STREET. The engine's own
	-- route (`prevention.av` -> `RequestAVSpawn`) answers `ticket 0` on the live
	-- node, so nothing was ever flown and the troopers stood on a 40 m ring
	-- around the player -- which is exactly "they just spawn on the ground". The
	-- aircraft is therefore an Open77 vehicle the server flies (`server/av.lua`),
	-- and the troopers are placed at the point it drops to, inside the ring it
	-- occupies, at the moment it is there. When no airframe can be flown the
	-- ground ring is still stood up and the reason is NAMED: a division that
	-- answers with nothing is worse than one that answers on foot.
	local av = false
	local maxtac = Law.Maxtac
	if division == M.DIVISION.MAXTAC and maxtac ~= nil then
		av = true

		-- The ground car, unless the squad is already arriving by air.
		if type(maxtac.Vehicle) == 'string' and maxtac.Vehicle ~= '' then
			local at2 = bearing(at, 1, 2, 18.0)
			local id, reason = carry(maxtac.Vehicle, at2, facing(at2, at), at.bucket, { siren = true })
			if id == nil then
				held.refused[#held.refused + 1] = ('%s:%s'):format(maxtac.Vehicle, tostring(reason))
			else
				held.vehicles[#held.vehicles + 1] = id
			end
		end

		-- The squad. Seats come from the config; the engine's own trooper
		-- records fill every one of them when `FILL` is `bots`.
		local seats = type(maxtac.Squad) == 'table' and tonumber(maxtac.Squad.SEATS) or nil
		seats = math.max(0, math.floor(seats or #maxtac.Troopers))
		local radius = type(maxtac.Squad) == 'table' and tonumber(maxtac.Squad.INSERTION_RADIUS) or 40.0
		local filling = maxtac.Fill ~= 'players'
		local placeable = math.min(seats, #maxtac.Troopers)

		--- Stands one trooper, and records what happened either way.
		-- A local rather than a loop because the air insertion stands its squad
		-- from a callback, seconds after this function has returned.
		-- @param at2 table where the body is to stand
		-- @param index number which trooper of the config's list
		-- @param where table|nil where to CREATE it, when that is not `at2`: a
		--   body that boards is created at the hull, so it is never seen on the
		--   street before it is inside
		-- @return string|nil the id
		local function stand(at2, index, where)
			local record = maxtac.Troopers[index]
			if record == nil then return nil end
			attempted = attempted + 1
			local id, reason = officer(record, where or at2, facing(at2, at), at.bucket, held,
				playerId, divisionGroup(division))
			if id == nil then
				held.refused[#held.refused + 1] = ('%s:%s'):format(record, tostring(reason))
			else
				held.npcs[#held.npcs + 1] = id
			end
			return id
		end

		--- Puts one body down where it was going to stand all along.
		-- The fallback for a seat the host refused, and for a body created at
		-- the hull: without it a refused mount is a trooper falling in mid-air
		-- beside the aircraft rather than a squad on the ground.
		local function land(id, at2)
			local npcs = Open77 and Open77.npcs
			if type(npcs) ~= 'table' or type(npcs.setTransform) ~= 'function' then return end
			pcall(npcs.setTransform, id, {
				position = { x = at2.x, y = at2.y, z = at2.z },
				yaw = facing(at2, at),
			})
		end

		-- The seats a squad rides in, as the NPC task wants them: the FiveM
		-- NUMBERS, not the canonical `seat_*` names. `npcs.tasks.enterVehicle`
		-- parses its own short alias list and refuses `seat_front_right`
		-- outright, while every read the platform makes reports the canonical
		-- spelling -- so the translation lives here, once, and the config keeps
		-- the canonical names it can be checked against.
		local RIDE_SEAT = { seat_front_left = -1, seat_front_right = 0, seat_back_left = 1,
			seat_back_right = 2 }
		-- THE AIRCRAFT'S OWN SEATS, NOT THE CREW DOOR'S. The two lists are not the
		-- same and must not be: `BOARDING.SEATS` is the order a PLAYER crew fills,
		-- with the pilot's seat deliberately left out because a pilot reaches for
		-- it, while a squad of four bots has no such courtesy to keep and four
		-- seats to fill. Seating the squad from the crew list left the last
		-- trooper on the street beside an empty front-left seat.
		local rideSeats = {}
		for _, seat in ipairs(M.Law.Seats) do
			local number = RIDE_SEAT[seat]
			if number ~= nil then rideSeats[#rideSeats + 1] = number end
		end

		-- The bodies of this response, by the config's own order, and which of
		-- them took a seat. Both are filled from the aircraft's callbacks, which
		-- run seconds after this function has returned.
		local troopers, seated = {}, {}

		--- Puts the squad aboard, as the descent begins.
		--
		-- WHY THIS MOMENT. `npcs.tasks.enterVehicle` is executed by the client
		-- that replicates the body, and that client can only mount into a
		-- vehicle it has already STREAMED -- `NpcReplication.cpp`'s own refusal
		-- is `vehicle_not_streamed`. The bottom of the approach is the first
		-- point at which the hull is inside a watching player's interest, so it
		-- is the first point a seat can be asked for at all.
		-- @param avId string the airframe's id
		-- @param drop table the point it will drop the squad at
		-- @return number how many bodies are inside it
		local function takeSeats(avId, drop)
			local npcs = Open77 and Open77.npcs
			local tasks = npcs and npcs.tasks
			local contract = Open77 and Open77.vehicles or nil
			local hull = contract ~= nil and type(contract.get) == 'function'
				and contract.get(avId) or nil
			local where = type(hull) == 'table' and hull or drop
			-- Where each body would stand: on the STREET under the drop
			-- (`drop.ground`, measured by the games when they could), never on
			-- a ring in the air at the hull's height.
			local street = { x = drop.x, y = drop.y, z = tonumber(drop.ground) or drop.z }
			local aboard = 0
			for index = 1, math.min(placeable, #rideSeats) do
				local at2 = bearing(street, index, placeable, 3.5)
				local id = stand(at2, index, where)
				troopers[index] = id
				if id ~= nil then
					local mounted, why = nil, 'npcs.tasks.enterVehicle is unavailable'
					if type(tasks) == 'table' and type(tasks.enterVehicle) == 'function' then
						local ran, taskId, reason = pcall(tasks.enterVehicle, id, avId,
							rideSeats[index], { warp = true })
						mounted = ran and taskId
						if mounted == nil then
							why = ran and tostring(reason or 'refused') or tostring(taskId)
						end
					end
					if mounted ~= nil then
						seated[index] = true
						aboard = aboard + 1
					else
						held.refused[#held.refused + 1] = ('mount:%d:%s'):format(index, tostring(why))
						land(id, at2)
					end
				end
			end
			if aboard > 0 then
				Open77.log.info(('[ncpd] %d trooper(s) are aboard the MaxTac AV for %s')
					:format(aboard, tostring(citizenId)))
			end
			return aboard
		end

		--- Steps the squad out at the bottom of the descent.
		-- Every mounted body is told to leave its seat, which is what makes them
		-- step out of the aircraft's own doors instead of standing where a script
		-- put them; a body that never got a seat is placed on the ring, exactly as
		-- it was before there was an aircraft to ride in.
		-- @param avId string
		-- @param drop table
		local function stepOut(avId, drop)
			local npcs = Open77 and Open77.npcs
			local tasks = npcs and npcs.tasks
			local street = { x = drop.x, y = drop.y, z = tonumber(drop.ground) or drop.z }
			for index = 1, placeable do
				if seated[index] == true then
					if type(tasks) == 'table' and type(tasks.exitVehicle) == 'function' then
						local ran = pcall(tasks.exitVehicle, troopers[index], { vehicleId = avId })
						if not ran then
							held.refused[#held.refused + 1] = ('dismount:%d'):format(index)
						end
					end
				elseif troopers[index] == nil then
					troopers[index] = stand(bearing(street, index, placeable, 3.5), index)
				end
			end
		end

		-- The insertion. A malformed plan is named here rather than flown: an
		-- aircraft that dives into the street is worse than a squad on foot.
		local flown = false
		local insertion = maxtac.AvInsertion
		local contract = M.Av
		if not filling or placeable == 0 then
			-- Player-filled division: nothing to fly in for.
		elseif insertion == nil then
			held.refused[#held.refused + 1] = 'av:no_insertion_plan'
		elseif contract == nil or type(contract.Insert) ~= 'function' then
			held.refused[#held.refused + 1] = 'av:av_controller_unavailable'
		else
			local avId, reason = contract.Insert({
				citizenId = citizenId,
				target = { x = at.x, y = at.y, z = at.z },
				bucket = at.bucket,
				record = maxtac.AvRecord,
				appearance = maxtac.AvAppearance,
				plan = insertion,
				oneAtATime = maxtac.AvOneAtATime,
				-- The squad rides in and steps out. `onMount` is the descent's
				-- beginning -- the first moment the hull is inside a watching
				-- player's interest, which is the only time a client can put a body
				-- in a seat -- and `onDeploy` is the bottom of it, where they leave
				-- through the aircraft's own doors and stand inside its footprint
				-- in the config's order: a seat no player took is a bot at the
				-- point the AV just was.
				onMount = function(drop, run)
					takeSeats(run.avId, drop)
				end,
				onDeploy = function(drop, run)
					stepOut(run.avId, drop)
				end,
				-- The crew door, announced by the controller on the phase that owns
				-- it. `nil` is the door shutting, which is a thing the people who
				-- were told where it is have to hear: a row that outlives the window
				-- is a key that answers `not_boarding` forever.
				onDoor = function(state)
					if type(M.DoorCall) == 'function' then M.DoorCall(state) end
				end,
			})
			if avId == nil then
				held.refused[#held.refused + 1] = ('av:%s'):format(tostring(reason))
			else
				flown = true
				held.avId = avId
			end
		end

		-- On foot only when nothing is flying.
		if filling and placeable > 0 and not flown then
			for index = 1, placeable do
				stand(bearing(at, index, placeable, radius), index)
			end
		end

		held.seats = seats
		held.filled = filling and placeable or 0
		held.flown = flown
	end

	-- ── a unit is the car AND the officers in it ────────────────────────────
	--
	-- The last refusal shape this can stand down is the empty one: every officer
	-- the stage asked for was refused, so what is left on the street is metal
	-- nobody is in. Taking those cars back down makes a missing permission read
	-- as nothing standing plus a named refusal rather than as a squad that
	-- arrived, parked and stopped -- the difference between a bug an operator
	-- can see and a scene that just looks broken in game.
	if attempted > 0 and #held.npcs == 0 and #held.vehicles > 0 and held.flown ~= true then
		local parked = #held.vehicles
		for _, id in ipairs(held.vehicles) do
			if safeCall('vehicles', 'remove', id) then freed = freed + 1 end
		end
		held.vehicles = {}
		held.refused[#held.refused + 1] =
			('ncpd.noOfficers:%d_car(s):%d_officer(s)_refused'):format(parked, attempted)
	end

	return OPX.Result.Ok({
		stage = stage,
		wanted = wanted,
		division = division,
		vehicles = #held.vehicles,
		npcs = #held.npcs,
		freed = freed,
		av = av,
		refused = held.refused,
		seats = held.seats,
		filled = held.filled,
		-- MaxTac was committed elsewhere: NCPD's `stage` holds them.
		queued = queued,
		-- What the ceiling held back, `{ units, vehicles }`.
		trimmed = { units = held.trimmed.units, vehicles = held.trimmed.vehicles },
	})
end

--- Stands up what the ceiling held back, once there is room for it.
--
-- Highest stage first, then whoever waited longest. A held cyberpsycho is re-stood
-- the moment a MaxTac squad is free; an NCPD response the ceiling trimmed is
-- re-stood when the room the others leave it has GROWN past what it was granted,
-- which is never twice for the same room, so this cannot churn a street.
-- @return table[] `{ citizenId, playerId, stage, queued, applied }` per response re-stood
function Response.Refill()
	local ceiling = limits()
	if ceiling == nil then return {} end
	local waiting = {}
	for citizenId, held in pairs(deployed) do
		if held.queued == true or held.trimmed.units > 0 or held.trimmed.vehicles > 0 then
			waiting[#waiting + 1] = { citizenId = citizenId, held = held }
		end
	end
	table.sort(waiting, function(a, b)
		if a.held.wanted ~= b.held.wanted then return a.held.wanted > b.held.wanted end
		if a.held.since ~= b.held.since then return a.held.since < b.held.since end
		return a.citizenId < b.citizenId
	end)
	local done = {}
	for _, item in ipairs(waiting) do
		local held = deployed[item.citizenId]
		if held == item.held then
			local used = standing(item.citizenId)
			local more = false
			if held.queued == true and used.squads < ceiling.squads then
				more = true
			elseif held.trimmed.units > 0 or held.trimmed.vehicles > 0 then
				-- A held psycho is first in line for NCPD's room as well: the
				-- list is sorted by the stage they are wanted at.
				more = (held.trimmed.units > 0 and ceiling.units - used.units > held.granted.units)
					or (held.trimmed.vehicles > 0 and ceiling.vehicles - used.vehicles > held.granted.vehicles)
			end
			if more then
				local applied = Response.Apply(item.citizenId, held.playerId, held.wanted)
				done[#done + 1] = {
					citizenId = item.citizenId,
					playerId = held.playerId,
					stage = held.wanted,
					queued = held.queued == true,
					applied = applied,
				}
			end
		end
	end
	return done
end

--- The whole street: every response's officers, cars and squads, beside the
--- ceiling they stand under.
-- @return table `{ units, vehicles, squads, responses, queued, limits }`
function Response.Street()
	local used = standing(nil)
	local responses, queued = 0, 0
	for _, held in pairs(deployed) do
		responses = responses + 1
		if held.queued == true then queued = queued + 1 end
	end
	used.responses = responses
	used.queued = queued
	used.limits = limits()
	return used
end

--- What one character's response has standing, without touching the world.
-- @param citizenId string
-- @return table `{ stage, division, vehicles, npcs }`, zeroes when nothing is up
function Response.Status(citizenId)
	local held = deployed[citizenId]
	if held == nil then
		return { stage = 0, wanted = 0, division = nil, vehicles = 0, npcs = 0, queued = false }
	end
	return {
		stage = held.stage,
		wanted = held.wanted or held.stage,
		division = held.division,
		vehicles = #(held.vehicles or {}),
		npcs = #(held.npcs or {}),
		queued = held.queued == true,
	}
end

--- Whether an NPC is one of the units this module put on the street: an
--- officer or a trooper of any character's response. The kill handler asks it,
--- because a body the city sent is `POLICE_LAW` and not a pedestrian.
-- @param npcId any as the host spells it
-- @return boolean
function Response.OwnsNpc(npcId)
	local wanted = tostring(npcId)
	for _, held in pairs(deployed) do
		for _, id in ipairs(held.npcs or {}) do
			if tostring(id) == wanted then return true end
		end
	end
	return false
end

--- The id of one of this module's units exactly as `Open77.npcs.create` handed it
--- back, or nil for a body that is not one. The hit relay (`server/hits.lua`)
--- names a body to the host by THIS value and never by the client's spelling of
--- it: a 64-bit id is not something to round-trip through a text field twice.
-- @param npcId any as the host or a client spells it
-- @return any|nil
function Response.IdOf(npcId)
	local wanted = tostring(npcId)
	for _, held in pairs(deployed) do
		for _, id in ipairs(held.npcs or {}) do
			if tostring(id) == wanted then return id end
		end
	end
	return nil
end

--- How many characters have a response standing.
-- @return integer
function Response.Count()
	local total = 0
	for _ in pairs(deployed) do total = total + 1 end
	return total
end

--- Takes every response down. The module's `Stop` uses it: a restart must not
--- leave a stage's cars standing with nothing left to remove them.
-- @return integer how many units were removed
function Response.ReleaseAll()
	local removed = 0
	for citizenId in pairs(deployed) do
		removed = removed + dismantle(citizenId)
	end
	return removed
end
