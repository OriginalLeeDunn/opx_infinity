--- Vehicle commands: spawn, deliver, repair, flag, seat, remove and clean up.
-- @author dop42
--
-- Only vehicles this module created have a row in `spawned`, and only those count
-- against a cap or are cleaned up. One created by anything else -- a player's own
-- car through the `vehicles` module, a mission vehicle -- answers `not_ours` on a
-- removal, because the host refuses to remove what another resource made.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Catalog = M.Catalog
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local inform = Server.Inform
local count = Server.Count

M.Vehicles = {}
local Vehicles = M.Vehicles

-- Vehicles this module spawned, by id, with the player whose cap they count
-- against. Rebuilt empty at every start: the host removes what this resource
-- created when it stops, so a carried table would name vehicles that are gone.
local spawned = {}

-- Repair scopes the host accepts.
local SCOPES = { glass = true, body = true, lights = true, tires = true, visual = true,
	mechanical = true, full = true }

-- Seats an operator is put in, first free one wins.
local SEATS = { 'driver', 'frontPassenger', 'rearLeft', 'rearRight' }

-- Whether this host exposes the server vehicle bindings at all.
local function available()
	return type(Open77.vehicles) == 'table' and type(Open77.vehicles.create) == 'function'
end

-- The host's live snapshot of one vehicle, or nil.
local function snapshotOf(vehicleId)
	local read, snapshot = pcall(Open77.vehicles.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return snapshot
end

-- The player ids aboard a snapshot, as numbers.
local function occupantsOf(snapshot)
	local list = {}
	for _, occupant in ipairs(type(snapshot.occupants) == 'table' and snapshot.occupants or {}) do
		local playerId = tonumber(type(occupant) == 'table' and occupant.playerId or occupant)
		if playerId then list[#list + 1] = playerId end
	end
	return list
end

-- Forgets rows whose vehicle the host no longer knows.
local function prune()
	for vehicleId in pairs(spawned) do
		if snapshotOf(vehicleId) == nil then spawned[vehicleId] = nil end
	end
end

-- How many spawned vehicles count against one player's cap.
local function ownedBy(owner)
	local total = 0
	for _, entry in pairs(spawned) do
		if entry.owner == owner then total = total + 1 end
	end
	return total
end

--- Lets a departing player's spawns count against nobody.
-- THE CAP IS KEYED BY PLAYER ID, AND A PLAYER ID IS A SLOT the host hands to the
-- next connection: a staff car left standing when its operator logged off kept
-- counting against whoever was given that id next, who was refused a spawn
-- (`vehicle_cap`) for a car they had never seen, and whose `remove mine` removed
-- it. The car stays where it is -- somebody may be driving it -- and `cleanup`
-- still finds it.
-- @param player integer
function Vehicles.Forget(player)
	for _, entry in pairs(spawned) do
		if entry.owner == player then entry.owner = false end
	end
end

-- The vehicle the operator sits in, else the nearest in range in their bucket.
local function nearest(source)
	if source <= 0 then return nil, 'console_has_no_player' end
	local origin = Server.PositionOf(source)
	if origin == nil then return nil, 'no_position' end
	local read, all = pcall(Open77.vehicles.all)
	if not read or type(all) ~= 'table' then return nil, 'no_vehicle' end
	local radius = OPX.Tune.Number('ADMIN_VEHICLE_NEAR_RADIUS', 1)
	local best, bestDistance
	for _, snapshot in ipairs(all) do
		-- Kept exactly as the host spelled it: these are 64-bit and would not
		-- survive a round trip through a double.
		local id = snapshot.id
		if id ~= nil then
			for _, occupant in ipairs(occupantsOf(snapshot)) do
				if occupant == source then return id, nil end
			end
			local x, y, z = Text.Finite(snapshot.x), Text.Finite(snapshot.y), Text.Finite(snapshot.z)
			-- Same bucket only: a vehicle three metres away in another bucket is
			-- not one the operator can see.
			if x and y and z and (Text.Integer(snapshot.bucket) or 0) == origin.bucket then
				local distance = math.sqrt(OPX.Math.DistanceSquared({ x = x, y = y, z = z }, origin))
				if distance <= radius and (bestDistance == nil or distance < bestDistance) then
					best, bestDistance = id, distance
				end
			end
		end
	end
	if best == nil then return nil, 'no_vehicle' end
	return best, nil
end

-- A typed vehicle id in whichever shape the host answers to, or nil.
-- The host's ids are opaque and may be 64-bit, so they are never put through
-- `tonumber` on the way out of a snapshot; a TYPED one is a string either way,
-- and both spellings are tried rather than guessed at.
local function resolveId(token)
	local number = Text.Integer(token)
	if number ~= nil and number > 0 and snapshotOf(number) ~= nil then return number end
	if type(token) == 'string' and #token > 0 and #token <= 32 and not token:find('%s')
		and snapshotOf(token) ~= nil then
		return token
	end
	return nil
end

-- Resolves `near` or a vehicle id, or answers the refusal.
local function vehicleOf(source, raw, token)
	if type(token) == 'string' and token:lower() == 'near' then
		local vehicleId, code = nearest(source)
		if vehicleId == nil then refuse(source, raw, code) end
		return vehicleId
	end
	local vehicleId = resolveId(token)
	if vehicleId == nil then
		refuse(source, raw, 'no_vehicle')
		return nil
	end
	-- A TYPED ID IS ANY LIVE VEHICLE ON THE SERVER, and was taken as one: an
	-- operator could repair, flag, enter or cut a key to a player's car three
	-- districts away in another instance, which `near` never allowed. Without
	-- `M.VEHICLE_ANYWHERE` a typed vehicle must carry the operator, or sit in
	-- their instance within VEHICLES.REACH. The console is the server and holds it.
	if Server.Holds(source, M.VEHICLE_ANYWHERE) ~= true then
		local snapshot = snapshotOf(vehicleId) or {}
		for _, occupant in ipairs(occupantsOf(snapshot)) do
			if occupant == source then return vehicleId end
		end
		local origin = Server.PositionOf(source)
		local x, y, z = Text.Finite(snapshot.x), Text.Finite(snapshot.y), Text.Finite(snapshot.z)
		local reach = M.Bounded('VEHICLES.REACH', M.Section('VEHICLES').REACH, 1, 10000, 100)
		local within = origin ~= nil and x ~= nil and y ~= nil and z ~= nil
			and (Text.Integer(snapshot.bucket) or 0) == origin.bucket
			and OPX.Math.DistanceSquared({ x = x, y = y, z = z }, origin) <= reach * reach
		if not within then
			refuse(source, raw, 'vehicle_out_of_reach')
			Server.Audit(source, 'admin.vehicle.reach', false, nil, tostring(vehicleId))
			return nil
		end
	end
	return vehicleId
end

-- Spawns one catalogue row beside a player, within their cap.
local function spawnFor(source, raw, owner, entry, event)
	if not Server.Admitted(source, raw, owner, event) then return end
	prune()
	local cap = math.floor(OPX.Tune.Number('ADMIN_VEHICLE_PER_OWNER', 1))
	if ownedBy(owner) >= cap then
		return refuse(source, raw, 'vehicle_cap', { cap = cap, id = owner })
	end
	local position = Server.PositionOf(owner)
	if position == nil then return refuse(source, raw, 'no_position') end

	local settings = M.Section('VEHICLES')
	local offset = settings.SPAWN_OFFSET or {}
	-- AN AV IS LIFTED, and only an AV: its record's pivot is the chassis centre,
	-- so the ground offset that puts a car's wheels on the road leaves an AV
	-- half-buried in it. `entry.av` is the catalogue's own answer, derived from the
	-- record (see `Catalog.isAir`), so this is the same rule by which the row is
	-- in the Air class and not a second list that could disagree with it.
	--
	-- `OPX.Vehicle.AvLift` AND NOT `Server.Setting`, which was the third copy of
	-- this number and the one with no bound: the garage and the dealer both clamp
	-- AV_LIFT to 0..10 and fall back to 1.2, and this read a plain numeric default,
	-- so an operator who typed 500 in `config/admin.lua` dropped an AV from 500
	-- metres here and got a quiet 1.2 from the other two. All three ship 1.2, which
	-- is why it never showed.
	local lift = entry.av and OPX.Vehicle.AvLift(settings.AV_LIFT) or 0.0
	local vehicleId, reason = Open77.vehicles.create({
		record = entry.record,
		position = {
			x = position.x + Server.Setting(offset.X, 3.0),
			y = position.y + Server.Setting(offset.Y, 0.0),
			z = position.z + Server.Setting(offset.Z, 0.25) + lift,
		},
		yaw = 0.0,
		bucket = position.bucket,
	})
	if vehicleId == nil then
		audit(source, event, false, owner, ('%s refused: %s'):format(entry.record, tostring(reason)))
		return refuse(source, raw, 'refused', { reason = tostring(reason) })
	end
	spawned[vehicleId] = { owner = owner }
	audit(source, event, true, owner, ('%s %s'):format(tostring(vehicleId), entry.record))
	inform(source, owner, 'admin.toast.vehicle', { label = entry.label })

	-- THE KEY COMES WITH THE CAR, to whoever the car was left beside: the operator
	-- for a spawn, the player for a give. A staff vehicle has no plate, so the keys
	-- module mints one that lives exactly as long as this vehicle does. A key that
	-- could not be cut is logged and costs nothing else -- the car is out, and
	-- `opx.admin.vehicle.key` cuts another.
	--
	-- ON A THREAD: the bag write can yield, and this runs inside the pcall that
	-- guards every command handler, which a yield does not cross.
	local keys = Server.Contract('vehiclekeys')
	if keys ~= nil then
		CreateThread(function()
			local cut = keys.GiveFor(owner, vehicleId, entry.label)
			if type(cut) ~= 'table' or not cut.ok then
				Open77.log.warn(('[admin] %s was spawned for %d with no key: %s'):format(
					tostring(vehicleId), owner, tostring(type(cut) == 'table' and cut.error or cut)))
			end
		end)
	end
	answer(source, raw, true, 'admin.done.spawned',
		{ vehicle = tostring(vehicleId), label = entry.label, id = owner })
end

-- Removes one empty vehicle, refusing when somebody is aboard.
local function removeOne(vehicleId)
	local snapshot = snapshotOf(vehicleId)
	if snapshot == nil then
		spawned[vehicleId] = nil
		return false, 'no_vehicle'
	end
	if #occupantsOf(snapshot) > 0 then return false, 'occupied' end
	local read, removed = pcall(Open77.vehicles.remove, vehicleId)
	if not read or removed ~= true then return false, 'not_ours' end
	spawned[vehicleId] = nil
	return true
end

-- The bit values of a vehicle snapshot's `flags` field, as the devkit documents
-- them for 2.31.13+op77.75.
--
-- `Open77.vehicles.flags` is read BOTH WAYS on purpose, because the devkit
-- disagrees with itself about which it is: the card says "a public constant
-- table", is marked `constant: true`, and every example indexes it directly
-- (`Open77.vehicles.flags.locked`), while `open77-server.d.lua` declares it
-- `function Open77.vehicles.flags()` returning that table. Calling a table or
-- indexing a function both fail silently here -- the result just is not a table,
-- the flag is never found, and `vehicle.flag` answers `unknown_flag` for every
-- flag. So: call it if it is callable, take it if it is a table, and fall back
-- to the constants below if the host has neither.
--
-- The four flags this module offers (locked, engineOn, lightsOn, invulnerable)
-- resolve by any of the three routes. `frozen` (bit 11) and `paintApplied` are
-- documented elsewhere and deliberately absent: nothing here offers them.
local BITS = {
	engineOn = 1, locked = 2, destroyed = 4, exploded = 8, invulnerable = 16,
	immortal = 32, lightsOn = 64, highBeams = 128, sirenOn = 256,
}

-- The host's mask table, or the constants above.
local function masks()
	local accessor = Open77.vehicles.flags
	if type(accessor) == 'function' then
		local read, answer = pcall(accessor)
		if read and type(answer) == 'table' then return answer end
	elseif type(accessor) == 'table' then
		return accessor
	end
	return BITS
end

-- A configured flag's mask and its exact name, or nil.
local function maskOf(name)
	if type(name) ~= 'string' then return nil end
	local bits = masks()
	for _, flag in ipairs(M.Section('VEHICLES').FLAGS or {}) do
		if flag:lower() == name:lower() then
			local mask = Text.Integer(bits[flag])
			if mask then return mask, flag end
		end
	end
	return nil
end

--- How many spawned vehicles still exist, for the status readout.
-- @author dop42
-- @return integer
function Vehicles.SpawnedCount()
	prune()
	local total = OPX.Table.Count(spawned)
	return total
end

--- Registers every vehicle command.
-- @author dop42
function Vehicles.Register()
	Server.Command(Command.VEHICLE_SPAWN, {
		help = 'admin.help.spawn', params = { { name = 'vehicle', help = 'admin.help.vehicleName' } },
		inGame = true,
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local entry = Catalog.Vehicle(args[1])
			if entry == nil then return refuse(source, raw, 'unknown_vehicle') end
			spawnFor(source, raw, source, entry, 'admin.vehicle.spawn')
		end,
	})

	Server.Command(Command.VEHICLE_GIVE, {
		help = 'admin.help.giveVehicle',
		params = { { name = 'playerId|me', help = 'admin.help.playerOrMe' },
			{ name = 'vehicle', help = 'admin.help.vehicleName' } },
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			local entry = Catalog.Vehicle(args[2])
			if entry == nil then return refuse(source, raw, 'unknown_vehicle') end
			spawnFor(source, raw, playerId, entry, 'admin.vehicle.give')
		end,
	})

	Server.Command(Command.VEHICLE_REMOVE, {
		help = 'admin.help.removeVehicle',
		params = { { name = 'vehicleId|near|mine', help = 'admin.help.removeTarget', optional = true } },
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local token = type(args[1]) == 'string' and args[1]:lower() or 'near'
			if token == 'mine' then
				if source <= 0 then return refuse(source, raw, 'console_has_no_player') end
				local removed, kept = 0, 0
				for vehicleId, entry in pairs(spawned) do
					if entry.owner == source then
						local ok, code = removeOne(vehicleId)
						if ok then removed = removed + 1 elseif code ~= 'no_vehicle' then kept = kept + 1 end
					end
				end
				audit(source, 'admin.vehicle.remove', true, nil,
					('mine: %d removed, %d kept'):format(removed, kept))
				-- Nothing left to remove is a success, not a refusal.
				return answer(source, raw, removed > 0 or kept == 0, 'admin.done.removedMany',
					{ removed = removed, kept = kept })
			end

			local vehicleId = vehicleOf(source, raw, token)
			if vehicleId == nil then return end
			local removed, code = removeOne(vehicleId)
			audit(source, 'admin.vehicle.remove', removed, nil,
				('%s %s'):format(tostring(vehicleId), code or ''))
			if not removed then return refuse(source, raw, code, { vehicle = tostring(vehicleId) }) end
			answer(source, raw, true, 'admin.done.removed', { vehicle = tostring(vehicleId) })
		end,
	})

	Server.Command(Command.VEHICLE_CLEANUP, {
		help = 'admin.help.cleanup',
		handler = function(source, _, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local removed, kept = 0, 0
			for vehicleId in pairs(spawned) do
				local ok, code = removeOne(vehicleId)
				if ok then removed = removed + 1 elseif code ~= 'no_vehicle' then kept = kept + 1 end
			end
			audit(source, 'admin.vehicle.cleanup', true, nil,
				('%d removed, %d kept'):format(removed, kept))
			answer(source, raw, true, 'admin.done.removedMany', { removed = removed, kept = kept })
		end,
	})

	Server.Command(Command.VEHICLE_REPAIR, {
		help = 'admin.help.repair',
		params = { { name = 'vehicleId|near', help = 'admin.help.repairTarget', optional = true },
			{ name = 'scope', help = 'admin.help.repairScope', optional = true } },
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local scope = type(args[2]) == 'string' and args[2]:lower() or 'full'
			if not SCOPES[scope] then return refuse(source, raw, 'bad_scope') end
			local vehicleId = vehicleOf(source, raw, args[1] or 'near')
			if vehicleId == nil then return end
			local snapshot = snapshotOf(vehicleId)
			-- A mechanical or full repair with somebody aboard can throw them out
			-- of the seat, so only the cosmetic scopes are allowed.
			local safe = M.Section('VEHICLES').OCCUPIED_REPAIRS or {}
			if snapshot and #occupantsOf(snapshot) > 0 and safe[scope] ~= true then
				return refuse(source, raw, 'unsafe_repair', { scope = scope })
			end
			local ok, reason = Open77.vehicles.repair(vehicleId, scope)
			audit(source, 'admin.vehicle.repair', ok == true, nil,
				('%s %s %s'):format(tostring(vehicleId), scope, ok and '' or tostring(reason)))
			if not ok then return refuse(source, raw, 'refused', { reason = tostring(reason) }) end
			answer(source, raw, true, 'admin.done.repaired',
				{ vehicle = tostring(vehicleId), scope = scope })
		end,
	})

	Server.Command(Command.VEHICLE_ENTER, {
		help = 'admin.help.enter',
		params = { { name = 'vehicleId|near', help = 'admin.help.vehicleTarget' } },
		inGame = true,
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local vehicleId = vehicleOf(source, raw, args[1] or 'near')
			if vehicleId == nil then return end
			if not Server.Admitted(source, raw, source, 'admin.vehicle.enter') then return end
			local seated, reason
			for _, seat in ipairs(SEATS) do
				local read, ok, failure = pcall(Open77.vehicles.warpPlayerIntoVehicle, source, vehicleId,
					seat, { moveBucket = true })
				seated = read and ok == true
				if seated then break end
				if read then
					reason = failure
				else
					-- Logged, and answered as a word: the raise text is a file and a line.
					Open77.log.error(('[admin] warpPlayerIntoVehicle raised: %s'):format(tostring(ok)))
					reason = 'raised'
				end
			end
			audit(source, 'admin.vehicle.enter', seated, nil,
				('%s %s'):format(tostring(vehicleId), seated and '' or tostring(reason)))
			if not seated then return refuse(source, raw, 'refused', { reason = tostring(reason) }) end
			answer(source, raw, true, 'admin.done.entered', { vehicle = tostring(vehicleId) })
		end,
	})

	-- THE OWNER: "avant le menu ou alt on peut se donner la clé du véhicule
	-- précis". One command, and both surfaces end in it: the eye row sends the id
	-- of the vehicle it landed on, the menu row sends `near`. Either way the
	-- vehicle is resolved HERE -- a typed id must name a live vehicle, `near` is
	-- the seat and then the nearest in the operator's own bucket -- and its plate
	-- is the keys module's answer about that vehicle. There is no plate argument
	-- to forge, because there is no plate argument.
	Server.Command(Command.VEHICLE_KEY, {
		help = 'admin.help.vehicleKey',
		params = { { name = 'vehicleId|near', help = 'admin.help.vehicleTarget', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			local keys = Server.Contract('vehiclekeys')
			if keys == nil then return refuse(source, raw, 'keys_unavailable') end
			local vehicleId = vehicleOf(source, raw, args[1] or 'near')
			if vehicleId == nil then return end
			-- On a thread, for the reason `spawnFor` gives: the bag write yields.
			Server.Heavy(source, raw, function()
				local cut = keys.GiveFor(source, vehicleId)
				local ok = type(cut) == 'table' and cut.ok == true
				-- The value is read defensively: on this bare thread a raise is no
				-- answer and no audit line, after the key has been cut.
				local value = ok and type(cut.value) == 'table' and cut.value or {}
				audit(source, 'admin.vehicle.key', ok, nil, ('%s %s'):format(tostring(vehicleId),
					ok and tostring(value.plate) or tostring(type(cut) == 'table' and cut.error or cut)))
				if not ok then
					-- `noRoom` carries the key's label as its detail; the bare id is
					-- only the fallback for a refusal that names none.
					local refused = type(cut) == 'table' and cut or {}
					refuse(source, raw, 'refused',
						{ reason = locale(refused.error or 'vehiclekeys.unavailable',
							{ label = tostring(refused.detail or vehicleId) }) })
					return
				end
				answer(source, raw, true, 'admin.done.key',
					{ vehicle = tostring(vehicleId), label = tostring(value.label or vehicleId) })
			end)
		end,
	})

	Server.Command(Command.VEHICLE_FLAG, {
		help = 'admin.help.flag',
		params = { { name = 'vehicleId|near', help = 'admin.help.vehicleTarget' },
			{ name = 'flag', help = 'admin.help.flagName' },
			{ name = 'on|off', help = 'admin.help.toggle', optional = true } },
		handler = function(source, args, raw)
			if not available() then return refuse(source, raw, 'vehicles_unavailable') end
			if count(args) < 2 then return answer(source, raw, false, 'admin.usage.flag') end
			local mask, flag = maskOf(args[2])
			if mask == nil then
				return refuse(source, raw, 'unknown_flag',
					{ flags = table.concat(M.Section('VEHICLES').FLAGS or {}, ', ') })
			end
			local wanted, invalid = Text.Switch(args[3])
			if invalid then return refuse(source, raw, 'bad_switch') end
			local vehicleId = vehicleOf(source, raw, args[1])
			if vehicleId == nil then return end
			local snapshot = snapshotOf(vehicleId)
			if snapshot == nil then return refuse(source, raw, 'no_vehicle') end
			local bits = Text.Integer(snapshot.flags) or 0
			if wanted == nil then wanted = (bits & mask) == 0 end
			local nextBits = wanted and (bits | mask) or (bits & ~mask)
			local ok, reason = Open77.vehicles.update(vehicleId, { flags = nextBits })
			audit(source, 'admin.vehicle.flag', ok == true, nil,
				('%s %s=%s %s'):format(tostring(vehicleId), flag, wanted and 'on' or 'off',
					ok and '' or tostring(reason)))
			if not ok then return refuse(source, raw, 'refused', { reason = tostring(reason) }) end
			answer(source, raw, true, wanted and 'admin.done.flagOn' or 'admin.done.flagOff',
				{ vehicle = tostring(vehicleId), flag = flag })
		end,
	})

	if not available() then
		Open77.log.warn('[admin] Open77.vehicles is unavailable on this host: every vehicle ' ..
			'command refuses')
	end
end
