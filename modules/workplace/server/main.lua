--- Server half: the duty clock, the uniforms and the service fleet.
-- @author dop42
--
-- THIS FILE DECIDES. A client names a station and, at most, an outfit or a
-- vehicle; every other fact is read here. Each request passes, cheapest first:
--
--   1. the per-player request floor            (a clock)
--   2. the station and its point exist          (a lookup in what Access built)
--   3. a character is loaded and is not down
--   4. same bucket, within the point's RADIUS   (the host's position)
--   5. the job: the station's, primary (duty may switch a secondary one in),
--      the grade the point / outfit / vehicle asks, on duty where configured
--
-- DUTY is the character contract's (`SetJobDuty`, which also tells the player).
--
-- A UNIFORM is written through `appearance.SaveClothing`, the one door clothes
-- go through and the one that re-dresses the puppet on every client. The look
-- the player came in with is written to their character METADATA FIRST and the
-- uniform second; a uniform the appearance service refuses takes the metadata
-- back. The civilian look is never lost: it outlives a logout, and a character
-- that loads in a uniform of a job it no longer holds is put back in it.
--
-- A SERVICE VEHICLE is `Open77.vehicles.create` with a TTL and no row -- the job
-- owns it, not the character, so nothing durable is attached -- and a key cut
-- through `vehiclekeys` (a minted plate). One per player, in `fleet[player]`.
-- It goes back when it is handed in at the pad, and on its own when the player
-- goes off duty, loses the job, switches character or leaves; every key to it
-- is revoked with it. A vehicle the host removed (TTL, destroyed) is forgotten
-- on `onVehicleRemoved`.

local M = OPX.Modules.Get('workplace')
local Access = M.Access
local Command = M.Command
local Point = M.Point
local Result = OPX.Result

-- What `Access.Build` made of the config.
local built = nil
-- player -> { id, station, job, vehicle, label, plate, cid }
local fleet = {}
-- player -> true while a civilian look is being put back (it yields).
local restoring = {}

-- ── reading the world ───────────────────────────────────────────────────────

local function pointOf(player)
	if math.type(player) ~= 'integer' or player < 1 then return nil end
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

local function headingOf(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.get) ~= 'function' then return 0 end
	local read, me = pcall(players.get, player)
	return read and type(me) == 'table' and OPX.Math.Finite(me.heading) or 0
end

local function character() return OPX.Api.Get('character') end

local function dataOf(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value.PlayerData
end

local function jobOf(data)
	return type(data.job) == 'table' and data.job or {}
end

local function gradeOf(job)
	return type(job.grade) == 'table' and OPX.Math.Finite(job.grade.level) or 0
end

--- Whether a character is on duty in its primary job (true for a job that is
--- on duty by definition).
local function onDuty(job)
	local definition = built and built.jobs[job.name] or nil
	if type(definition) == 'table' and definition.defaultDuty == true then return true end
	return job.onDuty == true
end

local function familyOf(data)
	local info = type(data.charInfo) == 'table' and data.charInfo or {}
	return (info.gender == 'female' or info.gender == 'male') and info.gender or nil
end

--- The job decision, through the one gate every JOBS block goes through
--- (`OPX.JobGate`): the station's job at `minGrade`, on duty when `needDuty`.
--- A job on duty by definition (defaultDuty) reads as on duty. Answers ok, or
--- false and one of wrong_job, grade_too_low, off_duty, no_character.
local function judge(data, jobName, minGrade, needDuty, membership)
	local now = OPX.Now()
	local job = type(data.job) == 'table' and data.job or nil
	if job ~= nil and needDuty and job.onDuty ~= true and onDuty(job) then
		job = OPX.Table.DeepCopy(job)
		job.onDuty = true
	end
	local ok, code = OPX.JobGate.Evaluate({ jobs = { [jobName] = minGrade or 0 }, onDuty = needDuty == true },
		{ job = job, jobs = data.jobs, atMs = now }, now, { maxAgeMs = 1000, membership = membership or 'primary' })
	if ok then return true end
	if code == 'job_required' then return false, 'wrong_job' end
	if code == 'grade_too_low' or code == 'off_duty' then return false, code end
	return false, 'no_character'
end

-- ── answers ─────────────────────────────────────────────────────────────────

local function answer(player, ok, code, params)
	local key = (ok and 'workplace.answer.' or 'workplace.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'workplace.answer.done' or 'workplace.error.invalid' end
	pcall(OPX.NotifyLocale, player, key, params, ok and 'success' or 'error')
	return ok, code
end

--- The common gate: floor, station, point, character, life, reach, job.
--- Answers the station, the point, the character data and the primary job, or
--- nil and the refusal's code. `secondaryOk` lets a held secondary job through.
local function gate(player, payload, kind, secondaryOk)
	if OPX.Cooling(player, 'workplace.request', built.requestMs) then return nil, 'too_fast' end
	if type(payload) ~= 'table' or not Access.Key(payload.station) then return nil, 'invalid' end
	local station = built.stations[payload.station]
	if station == nil then return nil, 'unknown_station' end
	local point = station.points[kind]
	if point == nil then return nil, 'no_point' end
	local data = dataOf(player)
	if data == nil then return nil, 'no_character' end
	if OPX.Life.Down(player) then return nil, 'player_down' end
	local at = pointOf(player)
	if at == nil then return nil, 'no_position' end
	if not Access.Reaches(at, point, station.bucket) then return nil, 'too_far' end
	local job = jobOf(data)
	if job.name ~= station.job then
		local held = type(data.jobs) == 'table' and data.jobs[station.job] ~= nil
		if not held then return nil, 'wrong_job' end
		if not secondaryOk then return nil, 'not_primary' end
	end
	return { station = station, point = point, data = data, job = job, at = at }
end

-- ── the duty clock ──────────────────────────────────────────────────────────

--- Clocks a player in or out at a station's duty point. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station }
-- @return boolean ok
-- @return string code
function M.Duty(player, payload)
	local ctx, why = gate(player, payload, Point.DUTY, true)
	if ctx == nil then return answer(player, false, why) end
	local station, data, job = ctx.station, ctx.data, ctx.job
	if station.defaultDuty then return answer(player, false, 'always_on_duty') end
	local api = character()
	if type(api.SetJobDuty) ~= 'function' then return answer(player, false, 'duty_failed') end

	local allowed, refusal = judge(data, station.job, ctx.point.minGrade, false, 'any')
	if not allowed then return answer(player, false, refusal) end

	local wanted = true
	if job.name ~= station.job then
		-- A secondary membership: made primary first, then clocked in.
		if not built.switchPrimary or type(api.SetPlayerPrimaryJob) ~= 'function' then
			return answer(player, false, 'not_primary')
		end
		local read, switched = pcall(api.SetPlayerPrimaryJob, player, station.job)
		if not read or type(switched) ~= 'table' or switched.ok ~= true then
			return answer(player, false, 'duty_failed')
		end
		local definition = built.jobs[station.job]
		answer(player, true, 'switched', { job = type(definition) == 'table' and definition.label or station.job })
	else
		wanted = job.onDuty ~= true
	end
	local read, set = pcall(api.SetJobDuty, player, wanted)
	if not read or type(set) ~= 'table' or set.ok ~= true then return answer(player, false, 'duty_failed') end
	OPX.Audit.Log({ event = 'workplace.duty', message = ('player %d %s %s at %s'):format(player,
		wanted and 'clocked in to' or 'clocked out of', station.job, station.key),
		data = { job = station.job, station = station.key, onDuty = wanted }, source = player })
	OPX.Publish(M.Event.ON_DUTY, player, { job = station.job, station = station.key, onDuty = wanted })
	-- The character contract has told the player already.
	return true, wanted and 'clocked_in' or 'clocked_out'
end

-- ── the wardrobe ────────────────────────────────────────────────────────────

local function appearance()
	local api = OPX.Api.Get('appearance')
	if api == nil or type(api.GetClothing) ~= 'function' or type(api.SaveClothing) ~= 'function' then return nil end
	return api
end

local function civviesOf(player)
	local api = character()
	if api == nil or type(api.GetMetadata) ~= 'function' then return nil end
	local read, value = pcall(api.GetMetadata, player, built.wardrobe.metadata)
	if not read or type(value) ~= 'table' or type(value.job) ~= 'string' then return nil end
	return value
end

local function writeCivvies(player, value)
	local api = character()
	if api == nil or type(api.SetMetadata) ~= 'function' then return false end
	local read, done = pcall(api.SetMetadata, player, built.wardrobe.metadata, value)
	return read and done ~= false
end

local function saveClothing(api, player, record)
	local read, saved = pcall(api.SaveClothing, player, record)
	return read and type(saved) == 'table' and saved.ok == true
end

--- Puts on an outfit of the station's job. The civilian look is kept on the
--- character's metadata before the uniform is written. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station, outfit }
-- @return boolean ok
-- @return string code
function M.Wear(player, payload)
	local ctx, why = gate(player, payload, Point.WARDROBE, false)
	if ctx == nil then return answer(player, false, why) end
	local station = ctx.station
	local outfit = type(payload.outfit) == 'string' and (built.outfits[station.job] or {})[payload.outfit] or nil
	if outfit == nil then return answer(player, false, 'unknown_outfit') end
	local allowed, refusal = judge(ctx.data, station.job, outfit.minGrade, built.wardrobe.onDuty)
	if not allowed then return answer(player, false, refusal) end
	local api = appearance()
	if api == nil then return answer(player, false, 'no_appearance') end
	if restoring[player] then return answer(player, false, 'too_fast') end

	local civvies = civviesOf(player)
	local base
	local fresh = civvies == nil
	if fresh then
		local read, current = pcall(api.GetClothing, player)
		-- nil is "could not be read": nothing is written over a look nobody saw.
		if not read or type(current) ~= 'table' or current.ok ~= true or current.value == nil then
			return answer(player, false, 'clothing_unavailable')
		end
		base = current.value
		civvies = { job = station.job, clothing = base, outfit = outfit.key, at = math.floor(OPX.Now() / 1000) }
	else
		base = civvies.clothing
		civvies.job, civvies.outfit = station.job, outfit.key
	end
	-- Kept first, worn second.
	if not writeCivvies(player, civvies) then return answer(player, false, 'uniform_failed') end
	local record = Access.Uniform(base, outfit, familyOf(ctx.data))
	if not saveClothing(api, player, record) then
		if fresh then writeCivvies(player, nil) end
		return answer(player, false, 'uniform_failed')
	end
	OPX.Audit.Log({ event = 'workplace.uniform', message = ('player %d put on %s.%s at %s'):format(player,
		station.job, outfit.key, station.key), data = { job = station.job, outfit = outfit.key,
		station = station.key }, source = player })
	OPX.Publish(M.Event.ON_UNIFORM, player, { job = station.job, station = station.key, outfit = outfit.key })
	return answer(player, true, 'uniform_on', { outfit = outfit.label })
end

--- Puts the civilian look back. `code` is what to tell the player.
local function restore(player, code, station)
	local civvies = civviesOf(player)
	if civvies == nil then return false, 'not_in_uniform' end
	local api = appearance()
	if api == nil then return false, 'no_appearance' end
	if restoring[player] then return false, 'too_fast' end
	restoring[player] = true
	local record = type(civvies.clothing) == 'table' and civvies.clothing or Access.EmptyClothing()
	local saved = saveClothing(api, player, record)
	restoring[player] = nil
	if not saved then return false, 'civvies_failed' end
	writeCivvies(player, nil)
	OPX.Audit.Log({ event = 'workplace.civvies', message = ('player %d back in civilian clothes (%s)')
		:format(player, code), data = { job = civvies.job, reason = code }, source = player })
	OPX.Publish(M.Event.ON_UNIFORM, player, { job = civvies.job, station = station, outfit = nil })
	if code ~= nil then answer(player, true, code) end
	return true, code
end

--- Back to the look the player came in with, at a wardrobe of any station of
--- the job the uniform belongs to. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station }
-- @return boolean ok
-- @return string code
function M.Civvies(player, payload)
	if OPX.Cooling(player, 'workplace.request', built.requestMs) then return answer(player, false, 'too_fast') end
	local station = type(payload) == 'table' and Access.Key(payload.station) and built.stations[payload.station] or nil
	if station == nil then return answer(player, false, 'unknown_station') end
	local point = station.points.wardrobe
	if point == nil then return answer(player, false, 'no_point') end
	if dataOf(player) == nil then return answer(player, false, 'no_character') end
	if not Access.Reaches(pointOf(player), point, station.bucket) then return answer(player, false, 'too_far') end
	local ok, code = restore(player, 'civvies_on', station.key)
	if not ok then return answer(player, false, code) end
	return true, code
end

-- ── the fleet ───────────────────────────────────────────────────────────────

local function keys() return OPX.Api.Get('vehiclekeys') end

local function vehicleApi()
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.create) ~= 'function' then return nil end
	return api
end

local function snapshotOf(id)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.get) ~= 'function' then return nil end
	local read, snapshot = pcall(api.get, id)
	return read and type(snapshot) == 'table' and snapshot or nil
end

local function positionOf(snapshot)
	local f = OPX.Math.Finite
	local x, y, z = f(snapshot.x), f(snapshot.y), f(snapshot.z)
	if (x == nil or y == nil or z == nil) and type(snapshot.position) == 'table' then
		x, y, z = f(snapshot.position.x), f(snapshot.position.y), f(snapshot.position.z)
	end
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(f(snapshot.bucket)) or 0 }
end

--- Whether anything but `player` sits in a vehicle.
local function occupiedByOther(snapshot, player)
	local occupants = type(snapshot.occupants) == 'table' and snapshot.occupants or {}
	for _, occupant in ipairs(occupants) do
		local id = type(occupant) == 'table' and (occupant.playerId or occupant.player or occupant.id) or occupant
		if math.tointeger(tonumber(id)) ~= player then return true end
	end
	return false
end

--- Whether a vehicle stands within `radius` of a pad.
local function padBlocked(station)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.all) ~= 'function' then return false end
	local read, list = pcall(api.all)
	if not read or type(list) ~= 'table' then return false end
	local pad = station.points.garage.pad
	local reach = built.garage.padClear
	for index = 1, #list do
		local at = type(list[index]) == 'table' and positionOf(list[index]) or nil
		if at ~= nil and at.bucket == station.bucket then
			local dx, dy, dz = at.x - pad.x, at.y - pad.y, at.z - pad.z
			if dx * dx + dy * dy + dz * dz <= reach * reach then return true end
		end
	end
	return false
end

local function outAt(stationKey)
	local count = 0
	for _, entry in pairs(fleet) do
		if entry.station == stationKey then count = count + 1 end
	end
	return count
end

--- Takes a player's service vehicle out of the world and revokes every key to
--- it. `reason` goes on the bus and the audit; `code` is what to tell the
--- player (nil says nothing).
local function despawn(player, reason, code)
	local entry = fleet[player]
	if entry == nil then return false end
	-- Forgotten first, so the host's removal event finds nothing to report.
	fleet[player] = nil
	local api = Open77.vehicles
	if snapshotOf(entry.id) ~= nil and type(api) == 'table' and type(api.remove) == 'function' then
		local read, removed = pcall(api.remove, entry.id)
		if not read or removed ~= true then
			Open77.log.warn(('[workplace] the service vehicle %s of player %d could not be removed: %s')
				:format(tostring(entry.id), player, tostring(removed)))
		end
	end
	local api2 = keys()
	if entry.plate ~= nil and api2 ~= nil and type(api2.RevokeAll) == 'function' then
		pcall(api2.RevokeAll, entry.plate)
	end
	OPX.Audit.Log({ event = 'workplace.fleetIn', message = ('player %d service vehicle %s.%s in (%s)'):format(player,
		entry.job, entry.vehicle, reason), data = { job = entry.job, vehicle = entry.vehicle, station = entry.station,
		reason = reason }, source = player })
	OPX.Publish(M.Event.ON_FLEET, player, { job = entry.job, station = entry.station, vehicle = entry.vehicle,
		id = entry.id, plate = entry.plate, reason = reason })
	if code ~= nil then answer(player, true, code, { vehicle = entry.label }) end
	return true
end

--- Takes a service vehicle out on the station's pad. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station, vehicle }
-- @return boolean ok
-- @return string code
function M.Spawn(player, payload)
	local ctx, why = gate(player, payload, Point.GARAGE, false)
	if ctx == nil then return answer(player, false, why) end
	local station = ctx.station
	local name = payload.vehicle
	if type(name) ~= 'string' or not Access.Offers(station, name) then return answer(player, false, 'unknown_vehicle') end
	local vehicle = built.fleet[station.job][name]
	local allowed, refusal = judge(ctx.data, station.job, vehicle.minGrade, built.garage.onDuty)
	if not allowed then return answer(player, false, refusal) end
	if fleet[player] ~= nil then
		if snapshotOf(fleet[player].id) ~= nil then return answer(player, false, 'already_out') end
		fleet[player] = nil
	end
	if built.garage.maxPerStation > 0 and outAt(station.key) >= built.garage.maxPerStation then
		return answer(player, false, 'station_full')
	end
	if padBlocked(station) then return answer(player, false, 'pad_blocked') end
	local api = vehicleApi()
	if api == nil then return answer(player, false, 'spawn_failed') end
	local pad = station.points.garage.pad
	local read, id, reason = pcall(api.create, {
		record = vehicle.record,
		position = { x = pad.x, y = pad.y, z = pad.z },
		yaw = pad.heading,
		bucket = station.bucket,
		ttlMs = built.garage.ttlMs,
		primaryColor = vehicle.primary,
		secondaryColor = vehicle.secondary,
	})
	if not read or id == nil then
		Open77.log.warn(('[workplace] %s refused at %s: %s'):format(vehicle.record, station.key,
			tostring(read and reason or id)))
		return answer(player, false, 'spawn_failed')
	end
	local entry = { id = id, station = station.key, job = station.job, vehicle = name, label = vehicle.label,
		cid = ctx.data.citizenId }
	fleet[player] = entry

	-- The key: soft. A car with no key still drives; it just cannot be locked.
	local keyed = false
	local api2 = keys()
	if api2 ~= nil and type(api2.GiveFor) == 'function' then
		local cut, given = pcall(api2.GiveFor, player, id, vehicle.label)
		if cut and type(given) == 'table' and given.ok == true and type(given.value) == 'table' then
			entry.plate, keyed = given.value.plate, true
		end
	end
	OPX.Audit.Log({ event = 'workplace.fleetOut', message = ('player %d took %s.%s out at %s'):format(player,
		station.job, name, station.key), data = { job = station.job, vehicle = name, station = station.key,
		id = tostring(id), plate = entry.plate }, source = player })
	OPX.Publish(M.Event.ON_FLEET, player, { job = station.job, station = station.key, vehicle = name, id = id,
		plate = entry.plate, reason = 'spawned' })
	return answer(player, true, keyed and 'spawned' or 'spawned_nokey', { vehicle = vehicle.label })
end

--- Hands a service vehicle back at the garage of any station of its job: the
--- player at the garage point, the vehicle on (near) the pad. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station }
-- @return boolean ok
-- @return string code
function M.Return(player, payload)
	local ctx, why = gate(player, payload, Point.GARAGE, true)
	if ctx == nil then return answer(player, false, why) end
	local station = ctx.station
	local entry = fleet[player]
	if entry == nil then return answer(player, false, 'nothing_out') end
	if entry.job ~= station.job then return answer(player, false, 'wrong_job') end
	local snapshot = snapshotOf(entry.id)
	if snapshot ~= nil then
		local at = positionOf(snapshot)
		if not Access.Reaches(at, station.points.garage.pad, station.bucket, built.garage.returnRadius) then
			return answer(player, false, 'vehicle_far')
		end
		if occupiedByOther(snapshot, player) then return answer(player, false, 'vehicle_occupied') end
	end
	despawn(player, 'returned', 'returned')
	return true, 'returned'
end

-- ── the menus ───────────────────────────────────────────────────────────────

--- Sends a player one point's menu. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { station, kind = 'wardrobe'|'garage' }
-- @return boolean ok
-- @return string code
function M.Ask(player, payload)
	local kind = type(payload) == 'table' and payload.kind or nil
	if kind ~= Point.WARDROBE and kind ~= Point.GARAGE then return answer(player, false, 'invalid') end
	local ctx, why = gate(player, payload, kind, kind == Point.GARAGE and fleet[player] ~= nil)
	if ctx == nil then return answer(player, false, why) end
	local station, job = ctx.station, ctx.job
	local primary = job.name == station.job
	local grade = primary and gradeOf(job) or -1
	local rows = {}
	-- Labels are the operator's words; the client words the rest in its own
	-- language.
	local menu = { station = station.key, kind = kind, label = station.label, rows = rows }
	if kind == Point.WARDROBE then
		local civvies = civviesOf(player)
		for _, outfit in ipairs(Access.Outfits(built, station.job, grade)) do
			rows[#rows + 1] = { key = outfit.key, label = outfit.label,
				worn = civvies ~= nil and civvies.outfit == outfit.key or nil }
		end
		menu.worn = civvies ~= nil or nil
	else
		if primary then
			for _, vehicle in ipairs(Access.Vehicles(built, station, grade)) do
				rows[#rows + 1] = { key = vehicle.key, label = vehicle.label }
			end
		end
		local entry = fleet[player]
		if entry ~= nil and entry.job == station.job then menu.out = entry.label end
	end
	TriggerClientEvent(M.Event.MENU, player, menu)
	return true, 'menu'
end

-- ── what the character module says ──────────────────────────────────────────

--- A job change, a duty change or a removal: hands the vehicle back and the
--- civilian look, where the new job state no longer allows them.
local function onJob(player, payload)
	player = math.tointeger(tonumber(player))
	if player == nil or player < 1 or type(payload) ~= 'table' or payload.offline == true then return end
	local job = type(payload.job) == 'table' and payload.job or {}
	local entry = fleet[player]
	if entry ~= nil then
		if job.name ~= entry.job then
			despawn(player, 'job_changed', 'fleet_off_duty')
		elseif built.garage.onDuty and not onDuty(job) then
			despawn(player, 'off_duty', 'fleet_off_duty')
		end
	end
	local civvies = civviesOf(player)
	if civvies ~= nil and (job.name ~= civvies.job
		or (built.wardrobe.restoreOffDuty and built.wardrobe.onDuty and not onDuty(job))) then
		CreateThread(function() restore(player, 'civvies_off_duty') end)
	end
end

--- A character just loaded: a uniform of a job it no longer holds comes off.
local function onLoaded(player)
	player = math.tointeger(tonumber(player))
	if player == nil or player < 1 then return end
	CreateThread(function()
		-- The appearance module reads the stored clothing on the same load.
		Wait(1500)
		local data = dataOf(player)
		local civvies = data and civviesOf(player) or nil
		if civvies ~= nil and jobOf(data).name ~= civvies.job then restore(player, 'civvies_off_duty') end
	end)
end

local function onVehicleRemoved(id)
	for player, entry in pairs(fleet) do
		if entry.id == id or tostring(entry.id) == tostring(id) then
			fleet[player] = nil
			local api = keys()
			if entry.plate ~= nil and api ~= nil and type(api.RevokeAll) == 'function' then
				pcall(api.RevokeAll, entry.plate)
			end
			OPX.Audit.Log({ event = 'workplace.fleetGone', message = ('player %d service vehicle %s.%s removed by the host')
				:format(player, entry.job, entry.vehicle), data = { job = entry.job, vehicle = entry.vehicle }, source = player })
			OPX.Publish(M.Event.ON_FLEET, player, { job = entry.job, station = entry.station, vehicle = entry.vehicle,
				id = entry.id, plate = entry.plate, reason = 'gone' })
			answer(player, true, 'fleet_gone', { vehicle = entry.label })
			return
		end
	end
end

-- ── staff ───────────────────────────────────────────────────────────────────

local function report(source)
	local lines, keys2 = {}, {}
	for key in pairs(built.stations) do keys2[#keys2 + 1] = key end
	table.sort(keys2)
	for _, key in ipairs(keys2) do
		local station = built.stations[key]
		local points = {}
		for _, kind in ipairs({ Point.DUTY, Point.WARDROBE, Point.GARAGE }) do
			if station.points[kind] ~= nil then points[#points + 1] = kind end
		end
		lines[#lines + 1] = ('%s [%s] %s: %s, %d vehicle(s) out'):format(key, station.job, station.label,
			table.concat(points, '+'), outAt(key))
	end
	for _, point in ipairs(built.placeholders) do lines[#lines + 1] = point .. ' DISABLED: not surveyed yet' end
	for _, line in ipairs(built.problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d station(s) open'):format(#keys2)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local station, kind = args[1], args[2]
	if not Access.Key(station) or not (kind == 'duty' or kind == 'wardrobe' or kind == 'garage' or kind == 'pad') then
		return OPX.CommandResult(source, false, 'usage: capture <station> <duty|wardrobe|garage|pad>')
	end
	local at = pointOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local line
	if kind == 'pad' then
		line = ('STATIONS.%s.GARAGE.PAD = { X = %.2f, Y = %.2f, Z = %.2f, HEADING = %.1f },  -- bucket %d')
			:format(station, at.x, at.y, at.z, headingOf(source), at.bucket)
	else
		line = ('STATIONS.%s.%s = { X = %.2f, Y = %.2f, Z = %.2f, RADIUS = %.1f },  -- bucket %d')
			:format(station, kind:upper(), at.x, at.y, at.z, kind == 'garage' and 2.0 or 1.5, at.bucket)
	end
	Open77.log.info(('[workplace] capture by %d: %s'):format(source, line))
	OPX.Audit.Log({ event = 'workplace.capture', message = line, source = source })
	OPX.CommandResult(source, true, ('paste into config/workplace.lua, then restart:\n  %s'):format(line))
end

local function registerCommands()
	OPX.Command.Register(Command.CAPTURE, { restricted = true, help = 'workplace.help.capture',
		params = {
			{ name = 'station', help = locale('workplace.help.station') },
			{ name = 'point', help = locale('workplace.help.point') },
		} },
		function(source, args) capture(source, args) end)
	OPX.Command.Register(Command.STATIONS, { restricted = true, help = 'workplace.help.stations' },
		function(source) report(source) end)
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Whether a player is on duty in their primary job: `(bool, job)`. A
--- passthrough to the character's own flag, true for a defaultDuty job.
-- @author dop42
-- @param player integer
-- @return boolean
-- @return string|nil job
function M.OnDuty(player)
	local data = dataOf(math.tointeger(tonumber(player)) or -1)
	if data == nil then return false, nil end
	local job = jobOf(data)
	return onDuty(job), job.name
end

--- A job's service fleet: `{ { key, label, record, minGrade } }` sorted by key.
-- @author dop42
-- @param job string
-- @return table[]
function M.Fleet(job)
	local out = {}
	for key, vehicle in pairs(type(job) == 'string' and built.fleet[job] or {}) do
		out[#out + 1] = { key = key, label = vehicle.label, record = vehicle.record, minGrade = vehicle.minGrade }
	end
	table.sort(out, function(a, b) return a.key < b.key end)
	return out
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the stations out of the config. Never yields.
-- @author dop42
function M.Init()
	local characterConfig = OPX.Config.MODULES.character
	built = Access.Build(M.Settings, type(characterConfig) == 'table' and characterConfig.JOBS or {})
	M.Built = built
	fleet, restoring = {}, {}
end

--- Publishes the server half of the workplace contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('workplace', 1, {
		OnDuty = M.OnDuty,
		Fleet = M.Fleet,
		--- The service vehicle a player has out: `{ id, station, job, vehicle, plate }` or nil.
		Out = function(player)
			local entry = fleet[math.tointeger(tonumber(player)) or -1]
			if entry == nil then return nil end
			return { id = entry.id, station = entry.station, job = entry.job, vehicle = entry.vehicle, plate = entry.plate }
		end,
		--- Takes a player's service vehicle back, from anywhere: Result.
		Recall = function(player, reason)
			player = math.tointeger(tonumber(player))
			if player == nil or fleet[player] == nil then return Result.Err('workplace.error.nothing_out') end
			despawn(player, type(reason) == 'string' and reason:sub(1, 32) or 'recalled', 'fleet_off_duty')
			return Result.Ok(true)
		end,
		--- Whether a player wears a uniform, and which: `(bool, job, outfit)`.
		InUniform = function(player)
			local civvies = civviesOf(math.tointeger(tonumber(player)) or -1)
			if civvies == nil then return false end
			return true, civvies.job, civvies.outfit
		end,
	})
end

local function wire(name, fn, threaded)
	RegisterNetEvent(name, function(payload)
		local player = math.tointeger(tonumber(source))
		if player == nil or player <= 0 then return end
		if threaded then
			CreateThread(function() fn(player, payload) end)
		else
			fn(player, payload)
		end
	end)
end

--- Wires the doors, the character bus and the host's vehicle removal.
-- @author dop42
function M.Start()
	for _, line in ipairs(built.problems) do Open77.log.warn('[workplace] config: ' .. line) end
	if #built.placeholders > 0 then
		Open77.log.info(('[workplace] disabled until surveyed (/opx.workplace.capture): %s')
			:format(table.concat(built.placeholders, ', ')))
	end
	if appearance() == nil then Open77.log.warn('[workplace] no appearance contract: the wardrobes are closed') end
	if keys() == nil then Open77.log.info('[workplace] no vehiclekeys contract: service vehicles come out keyless') end

	wire(M.Event.DUTY, M.Duty, true)
	wire(M.Event.ASK, M.Ask, false)
	-- The two wardrobe doors yield on the appearance service's write.
	wire(M.Event.WEAR, M.Wear, true)
	wire(M.Event.CIVVIES, M.Civvies, true)
	wire(M.Event.SPAWN, M.Spawn, true)
	wire(M.Event.RETURN, M.Return, true)

	local characterEvents = OPX.Modules.Get('character').Event
	AddEventHandler(characterEvents.ON_JOB, onJob)
	AddEventHandler(characterEvents.IN_LOADED, onLoaded)
	AddEventHandler(characterEvents.IN_UNLOADED, function(player)
		player = math.tointeger(tonumber(player))
		if player ~= nil then despawn(player, 'logout', nil) end
	end)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = math.tointeger(tonumber(playerId))
		if player ~= nil then
			despawn(player, 'disconnected', nil)
			restoring[player] = nil
		end
	end)
	AddEventHandler(OPX.Host.VEHICLE_REMOVED, onVehicleRemoved)

	registerCommands()
end

--- Takes every service vehicle back.
-- @author dop42
function M.Stop()
	local players = {}
	for player in pairs(fleet) do players[#players + 1] = player end
	for _, player in ipairs(players) do pcall(despawn, player, 'stopped', nil) end
end
