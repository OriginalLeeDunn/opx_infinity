--- Where containers are in the world, and whether a player is near enough.
-- @author dop42
--
-- EVERY POSITION HERE IS THE SERVER'S OWN. `World.Position` reads
-- `Open77.players.position`; nothing a client says about where it is standing is
-- ever believed. Before the world is ready there is no position at all, and
-- everything that needs one refuses.

local M = OPX.Modules.Get('inventory')

local Common = M.Common
local Options = M.Options
local Containers = M.Containers
local Players = M.Players
local KIND = M.KIND

M.World = {}
local World = M.World

-- The weight cap of a pile: above any real container, so a pile never refuses
-- something on weight. What bounds a pile is its slot count and its lifetime.
local UNBOUNDED = 4000000000

-- Metres in front of the player a new pile falls, so it does not land inside them.
local DROP_AHEAD = 0.8

-- Piles one part of the pile list carries. A pile is about ten values with its
-- keys, the client's JSON decoder refuses an event past 1,024 values, and
-- DROPS.MAX goes to 2,048.
local DROPS_PART = 64

--- A player's server-side position and routing bucket, or nil.
-- @author dop42
-- @param source Source
-- @return table|nil
function World.Position(source)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.position) ~= 'function' then return nil end
	local read, position = pcall(players.position, source)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = tonumber(position.x), tonumber(position.y), tonumber(position.z)
	if not (OPX.Math.IsFinite(x) and OPX.Math.IsFinite(y) and OPX.Math.IsFinite(z)) then
		return nil
	end
	return { x = x, y = y, z = z, bucket = Common.Integer(position.bucket, 0, 2147483647) or 0 }
end

--- Straight-line distance between two positions, in metres.
-- Not the squared form `OPX.Math.DistanceSquared` answers: these distances are
-- reported to a player and compared against configured metres, and none of them
-- is on a per-frame path.
-- @author dop42
-- @param a table
-- @param b table
-- @return number
function World.Distance(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local distance = World.Distance

--- The point a short way in front of a position along a yaw in degrees.
-- The yaw is the one thing the client is asked for here, and all it can do is
-- turn the pile around the player: the position itself is the server's.
-- @author dop42
-- @param position table
-- @param yaw any degrees, 0 facing +Y and turning towards -X
-- @return table
function World.Ahead(position, yaw)
	yaw = tonumber(yaw)
	if not OPX.Math.IsFinite(yaw) then return position end
	local radians = math.rad(yaw)
	return {
		x = position.x - math.sin(radians) * DROP_AHEAD,
		y = position.y + math.cos(radians) * DROP_AHEAD,
		z = position.z,
		bucket = position.bucket,
	}
end

--- Whether a position is within reach of an anchor, in the same routing bucket.
-- The one test for "same bucket, close enough": everything that asks the question
-- asks it here, so there is one answer to change.
-- @author dop42
-- @param position table|nil
-- @param anchor table|nil
-- @return boolean
function World.InReach(position, anchor)
	return position ~= nil and anchor ~= nil and position.bucket == anchor.bucket and
		distance(position, anchor) <= Options.REACH
end

--- The vehicle a player is seated in, or nil.
-- @author dop42
-- @param source Source
-- @return integer|nil
function World.Seat(source)
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return nil end
	local read, seat = pcall(vehicles.getPlayerSeat, source)
	if not read or type(seat) ~= 'table' then return nil end
	return seat.vehicleId
end

--- A vehicle's snapshot, or nil once it is gone.
-- @author dop42
-- @param vehicleId integer
-- @return table|nil
function World.Vehicle(vehicleId)
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.get) ~= 'function' then return nil end
	local read, snapshot = pcall(vehicles.get, vehicleId)
	if not read or type(snapshot) ~= 'table' then return nil end
	return snapshot
end

--- Whether a vehicle is locked, which shuts its trunk to everybody.
-- THE SERVER'S OWN RECORD, and nothing a client says: `Open77.vehicles.isLocked`
-- reads the canonical entry-lock bit the host keeps and replicates (devkit card
-- `server:Open77.vehicles.isLocked`, since op77.45, no permission checked in the
-- handler). The keys module moves that bit with `setLocked`; staff move it with
-- `opx.admin.vehicle.flag <id> locked`. Either way this is the one read.
--
-- A lock is a lock on the whole car. A player who could not open the door but
-- could still reach into the boot has been handed the car's contents by a
-- different route, so a locked vehicle refuses its trunk, and a trunk already
-- open when the lock goes on falls out of reach and is closed by the next reach
-- sweep. The GLOVEBOX is not asked: it opens only from a seat, and somebody
-- sitting inside was let in.
--
-- OPEN when the host cannot answer -- a build without the native, or an unknown
-- vehicle, which answers nil -- because refusing every trunk on the server over
-- a read that is not there would be the same outage as a lock nobody can undo.
-- @author dop42
-- @param vehicleId any the host's id for the vehicle
-- @return boolean
function World.TrunkLocked(vehicleId)
	local vehicles = Open77.vehicles
	if vehicleId == nil or type(vehicles) ~= 'table' or type(vehicles.isLocked) ~= 'function' then
		return false
	end
	local read, locked = pcall(vehicles.isLocked, vehicleId)
	return read and locked == true
end

--- Whether a player may act on a container right now.
-- A bag belongs to its owner and has no distance. A glovebox is the one of the
-- seat the player is in, whatever they name. A trunk is measured from the centre
-- of the vehicle, from outside it. Everything else is a distance to its anchor.
-- A stash opened with no anchor stays in reach: whoever opened it answered for
-- the reach itself.
-- @author dop42
-- @param source Source
-- @param container table
-- @return boolean
function World.WithinReach(source, container)
	if container.kind == KIND.CHARACTER then
		return Players.Citizen(source) == container.owner
	end

	if container.kind == KIND.GLOVEBOX then
		return container.vehicleId ~= nil and World.Seat(source) == container.vehicleId
	end

	local position = World.Position(source)
	if not position then return false end

	if container.kind == KIND.TRUNK then
		local snapshot = container.vehicleId and World.Vehicle(container.vehicleId)
		if not snapshot then return false end
		if World.Seat(source) == container.vehicleId then return false end
		-- Locked is out of reach, so a boot open when the lock went on is closed
		-- by the reach sweep and every move against it is refused meanwhile.
		if World.TrunkLocked(container.vehicleId) then return false end
		local centre = { x = tonumber(snapshot.x) or 0, y = tonumber(snapshot.y) or 0,
			z = tonumber(snapshot.z) or 0 }
		return (Common.Integer(snapshot.bucket, 0, 2147483647) or 0) == position.bucket and
			distance(position, centre) <= Options.REACH_VEHICLE
	end

	-- `anywhere` and NOT "a stash with no anchor". The two say the same thing
	-- today and stop saying it the moment somebody builds a stash container by
	-- another route or clears an anchor: the first is a decision `World.Stash`
	-- recorded, the second is a conclusion drawn from a field that is missing,
	-- and the conclusion drawn wrongly is a shared container in reach of the
	-- whole server.
	local anchor = container.anchor
	if not anchor then return container.kind == KIND.STASH and container.anywhere == true end
	return World.InReach(position, anchor)
end

-- ── piles on the ground ──────────────────────────────────────────────────────

-- Every pile, keyed by its container id, and when each player last made one.
local drops = {}
local lastDrop = {}

local dropSequence = 0

-- Pile prop models whose creation has already failed once, so it is said once.
local propWarned = {}

-- Stashes already reported as anchorless. One line per stash and not per open:
-- a stash is reopened every time somebody walks up to it.
local warnedAnywhere = {}

--- Shapes a pile as a client is sent it.
local function wireOf(drop)
	return { id = drop.id, x = drop.x, y = drop.y, z = drop.z, bucket = drop.bucket }
end

--- Every pile, in the shape a client is sent.
-- @author dop42
-- @return table[]
function World.DropList()
	local list = {}
	for _, drop in pairs(drops) do list[#list + 1] = wireOf(drop) end
	return list
end

--- Sends one player every pile, in parts; none at all when piles are off.
-- Every bucket's piles go to every client, and the client's prompt loop does not
-- read its bucket because it has no way to. A pile of another bucket in the same
-- place gets a prompt the server then refuses to open. Filtering at send time was
-- the obvious fix and is wrong: a player changes bucket with no hello -- character
-- selection, an instance -- and would never receive the piles of the bucket they
-- arrive in.
-- @author dop42
-- @param source Source
function World.SendDrops(source)
	local list = Options.DROPS and World.DropList() or {}
	local at = World.Position(source)
	local first = 1
	repeat
		local last = math.min(#list, first + DROPS_PART - 1)
		local part = {}
		for index = first, last do part[#part + 1] = list[index] end
		-- The first part also says which bucket the player is in, so the
		-- client can draw only that bucket's piles (see `World.SendBucket`).
		TriggerClientEvent(M.Event.DROPS, source,
			{ first = first == 1, done = last >= #list, drops = part,
				bucket = first == 1 and at and at.bucket or nil })
		first = last + 1
	until first > #list
end

--- Tells one player which routing bucket they are in now.
-- THE CLIENT HAS NO READ OF ITS OWN BUCKET, which is why every bucket's piles
-- are sent to everybody and why filtering at send time is wrong: a player
-- changes bucket with no hello. So the bucket is said instead, from the server's
-- own position read, whenever the host reports a move, and the client filters.
-- @author dop42
-- @param source Source
function World.SendBucket(source)
	local at = World.Position(source)
	if at == nil then return end
	TriggerClientEvent(M.Event.BUCKET, source, at.bucket)
end

--- The pile record of a container id, or nil.
-- @author dop42
-- @param id integer
-- @return table|nil
function World.Drop(id)
	return drops[id]
end

--- The nearest pile within a radius, in the same bucket.
-- Two radii use this: the join distance a drop looks for, and the reach that
-- opens one.
-- @author dop42
-- @param position table
-- @param radius number
-- @return table|nil
function World.NearestDrop(position, radius)
	local best, bestDistance = nil, radius
	for id, drop in pairs(drops) do
		if drop.bucket == position.bucket then
			local gap = distance(position, drop)
			if gap <= bestDistance then best, bestDistance = id, gap end
		end
	end
	return best and Containers.Get(best) or nil
end

--- Whether a player may make a new pile: the cooldown, the server cap and the
--- per-character cap.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return boolean
-- @return string|nil why not: `too_fast` for the cooldown, `drop_limit` for a cap
function World.MayCreateDrop(source, citizenId)
	if OPX.Now() - (lastDrop[source] or -math.huge) < Options.DROP_COOLDOWN_MS then
		return false, 'too_fast'
	end
	local total, own = 0, 0
	for _, drop in pairs(drops) do
		total = total + 1
		if drop.citizenId == citizenId then own = own + 1 end
	end
	if total < Options.DROP_MAX and own < Options.DROP_MAX_PER_CHARACTER then return true end
	return false, 'drop_limit'
end

--- How long a pile lives, in milliseconds. Read at the moment of use.
local function lifetimeMs()
	return OPX.Tune.Number('INVENTORY_DROP_LIFETIME_MIN', 1) * 60000
end

--- Creates a pile's prop, logging a given model's first failure only.
local function createProp(model, position)
	local props = Open77.props
	if type(props) ~= 'table' or type(props.create) ~= 'function' then return nil end
	local read, id, reason = pcall(props.create, {
		model = model,
		position = { x = position.x, y = position.y, z = position.z },
		yaw = math.random() * 360.0,
		bucket = position.bucket,
		-- A safety net and nothing more: the sweep removes a pile first. Capped at
		-- a week, because a prop with no upper bound outlives the thing it draws.
		ttlMs = math.min(lifetimeMs() + 120000, 604800000),
	})
	if read and id then return id end
	if not propWarned[model] then
		propWarned[model] = true
		Open77.log.warn(('[inventory] the pile prop %s could not be created: %s')
			:format(model, tostring(read and reason or id)))
	end
	return nil
end

--- Makes an empty memory-only pile and its prop where a player stands.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @param position table
-- @param name string|nil the item the pile is made for; its MODEL draws it
-- @return table
function World.CreateDrop(source, citizenId, position, name)
	lastDrop[source] = OPX.Now()
	dropSequence = dropSequence + 1
	local owner = ('%s:%d'):format(citizenId, dropSequence)
	local container = Containers.Transient(KIND.DROP, owner, Options.DROP_SLOTS, UNBOUNDED)
	container.anchor = { x = position.x, y = position.y, z = position.z, bucket = position.bucket }
	container.touchedAt = OPX.Now()

	local item = M.Catalog.Get(name)
	local wanted = item and item.model or nil
	local propId = wanted and createProp(wanted, position) or nil
	local fellBack = propId == nil
	if fellBack then propId = createProp(Options.DROP_MODEL, position) end

	-- SAID OUT LOUD, because the failure this diagnoses is silent by
	-- construction. A pile draws the wrong thing for three different reasons --
	-- the item has no MODEL, the alias was refused, or the alias was accepted
	-- and the client still drew a marker -- and from the game all three look
	-- identical: a crate. The first two are distinguishable here and nowhere
	-- else. The third is not, and the line says which model to go and check.
	Open77.log.debug(('[inventory] drop %s: wanted %s, drew %s%s')
		:format(tostring(name), tostring(wanted or 'nothing'),
			tostring(fellBack and Options.DROP_MODEL or wanted),
			propId == nil and ' (no prop at all)' or ''))

	drops[container.id] = {
		id = container.id,
		propId = propId,
		x = position.x,
		y = position.y,
		z = position.z,
		bucket = position.bucket,
		citizenId = citizenId,
	}
	TriggerClientEvent(M.Event.DROP, -1, 'add', wireOf(drops[container.id]))
	return container
end

--- Removes a pile: its prop, its container and every client's marker for it.
-- @author dop42
-- @param id integer
function World.RemoveDrop(id)
	local drop = drops[id]
	if not drop then return end
	drops[id] = nil
	if drop.propId and type(Open77.props) == 'table' and type(Open77.props.remove) == 'function' then
		-- THE TYPE GUARD PROTECTS AGAINST A RAISE, NOT AGAINST A REFUSAL.
		-- `Open77.props.remove` answers `true`, or `false` and a reason --
		-- `not_found`, `permission_denied:world.props`, `world_unavailable` --
		-- and the bare `pcall` discarded all three. The row above has already
		-- gone from `drops`, so nothing can ever come back to this prop: what
		-- stays in the world is a visible pile that cannot be picked up, for
		-- everyone in the area, until the resource is restarted. It cannot be
		-- retried from here, so it is named where an operator will find it.
		local called, removed, why = pcall(Open77.props.remove, drop.propId)
		if not called or removed ~= true then
			Open77.log.error(('[inventory] pile %s left a prop in the world (%s); it is ' ..
				'visible and cannot be picked up'):format(tostring(id),
				tostring(called and why or removed)))
		end
	end
	-- `Discard` and not `Unload`: a pile is never written, and this is reached from
	-- a guarded sweep that must not yield.
	Containers.Discard(id)
	TriggerClientEvent(M.Event.DROP, -1, 'remove', id)
end

--- Removes a pile once a change has emptied it.
-- @author dop42
-- @param container table
function World.CheckEmptyDrop(container)
	if container.kind ~= KIND.DROP then return end
	if next(container.items) ~= nil then return end
	if drops[container.id] then World.RemoveDrop(container.id) end
end

--- Removes every pile untouched for the configured lifetime, contents included.
-- @author dop42
function World.SweepDrops()
	local now = OPX.Now()
	local lifetime = lifetimeMs()
	local expired = {}
	for id in pairs(drops) do
		local container = Containers.Get(id)
		if not container or now - (container.touchedAt or 0) >= lifetime then
			expired[#expired + 1] = id
		end
	end
	for index = 1, #expired do World.RemoveDrop(expired[index]) end
end

--- Forgets a departed player's pile cooldown.
-- @author dop42
-- @param source Source
function World.Forget(source)
	lastDrop[source] = nil
end

-- ── stashes and vehicle storage ──────────────────────────────────────────────

--- Loads a stash's container with its anchor and its title.
-- @author dop42
-- @param name string
-- @param size table slots and maxWeight
-- @param anchor table|nil
-- @param title string|nil
-- @return table|nil
-- @return string|nil
function World.Stash(name, size, anchor, title)
	local container, reason = Containers.Load(KIND.STASH, name, size.slots, size.maxWeight)
	if not container then return nil, reason end
	if anchor then container.anchor = anchor end
	if title then container.title = title end
	-- ON THE IDLE SWEEP LIKE ANY OTHER, once nobody has it open. It used to be
	-- taken off it for good here, so every stash a player ever opened -- a
	-- housing resource's one per character, say -- stayed in memory for the
	-- life of the process. `Containers.SweepExternal` never unloads one that is
	-- open, and counts the idle time from the last pass that saw it open.
	container.external = true
	container.externalAt = OPX.Now()

	-- SAID HERE RATHER THAN INFERRED IN `WithinReach`. A stash with no anchor is
	-- in reach from anywhere, for as long as the server runs, for anybody who is
	-- handed its id -- which is the right answer for a caller that has already
	-- decided who may open it, and a shared portable container for a caller that
	-- simply forgot the position. Recording the decision where it is MADE means
	-- the reach test reads a flag somebody set instead of drawing a conclusion
	-- from a missing field, and a container that later loses its anchor does not
	-- silently become global.
	container.anywhere = container.anchor == nil
	if container.anywhere and not warnedAnywhere[name] then
		warnedAnywhere[name] = true
		Open77.log.warn(('[inventory] stash %s was opened with no position: it is in reach ' ..
			'from anywhere for the rest of the session, for anybody its id reaches')
			:format(tostring(name)))
	end
	return container, nil
end

--- Whether a vehicle record matches a two-wheeler pattern.
local function isBike(record)
	if type(record) ~= 'string' then return false end
	local lowered = record:lower()
	for index = 1, #Options.BIKE_PATTERNS do
		if lowered:find(Options.BIKE_PATTERNS[index], 1, true) then return true end
	end
	return false
end

--- The size of a vehicle's trunk or glovebox, or nil when it has none.
-- @author dop42
-- @param snapshot table
-- @param kind string
-- @return table|nil
function World.VehicleCapacity(snapshot, kind)
	local bike = isBike(snapshot.record)
	if kind == KIND.GLOVEBOX then
		if bike or Options.GLOVEBOX.slots <= 0 then return nil end
		return Options.GLOVEBOX
	end
	if Options.TRUNK.slots <= 0 then return nil end
	if bike then
		return {
			slots = math.max(1, math.ceil(Options.TRUNK.slots / Options.BIKE_TRUNK_DIVISOR)),
			maxWeight = math.ceil(Options.TRUNK.maxWeight / Options.BIKE_TRUNK_DIVISOR),
		}
	end
	return Options.TRUNK
end

--- Loads a vehicle's trunk or glovebox, stored by PLATE when the vehicle is owned.
-- The plate is the identity of an owned vehicle; a runtime id belongs to one spawn
-- and is recycled. A vehicle nobody owns gets storage that lives exactly as long
-- as it does, keyed on the runtime id, and is never written.
--
-- The `vehicles` contract answers from a table it holds in memory, so a missing
-- answer means "not owned" and not "not asked". When the contract is absent
-- nothing in this runtime owns a vehicle at all, so every vehicle gets memory-only
-- storage -- which is safe precisely because no row exists to be lost.
-- @author dop42
-- @param vehicleId integer
-- @param kind string
-- @return table|nil
-- @return string|nil
function World.VehicleContainer(vehicleId, kind)
	local snapshot = World.Vehicle(vehicleId)
	if not snapshot then return nil, 'no_vehicle' end
	local capacity = World.VehicleCapacity(snapshot, kind)
	if not capacity then return nil, 'no_storage' end

	local vehicles = M.Contracts.vehicles
	-- `PlateOf` answers the plate AND the citizen it belongs to. The owner was
	-- dropped here, which is why nothing downstream could tell whose boot this
	-- is; `Actions.OpenVehicle` needs it.
	local rawPlate, rawOwner = nil, nil
	if vehicles then rawPlate, rawOwner = vehicles.PlateOf(vehicleId) end
	local plate = rawPlate and Common.Word(rawPlate, 12) or nil
	local owner = rawOwner and Common.Word(rawOwner, 64) or nil

	local container, reason
	if plate then
		container, reason = Containers.Load(kind, plate, capacity.slots, capacity.maxWeight)
	else
		local owner = 'vehicle:' .. tostring(vehicleId)
		-- A recycled runtime id: storage whose record no longer matches the vehicle
		-- at that id belonged to one that is gone, and is thrown away.
		local existing = Containers.Find(kind, owner)
		if existing and existing.record ~= snapshot.record then Containers.Discard(existing.id) end
		container = Containers.Transient(kind, owner, capacity.slots, capacity.maxWeight)
		container.record = snapshot.record
	end
	if not container then return nil, reason end
	container.vehicleId = vehicleId
	-- Whose boot this is, or nil for a vehicle nobody owns. Re-stated on every
	-- open rather than kept from the first: a plate can change hands.
	container.ownerCitizenId = owner
	-- The load yielded; the vehicle may have gone while it did.
	if not World.Vehicle(vehicleId) then return nil, 'no_vehicle' end
	return container, nil
end

--- Writes and forgets storage whose vehicle no longer exists.
-- @author dop42
function World.SweepVehicles()
	local gone = {}
	for id, container in pairs(Containers.All()) do
		if container.vehicleId and not World.Vehicle(container.vehicleId) then
			gone[#gone + 1] = id
		end
	end
	for index = 1, #gone do Containers.Unload(gone[index]) end
end

--- Closes every container a player can no longer reach.
-- Yields, because an offline bag a staff search closes is written on the way out;
-- a staff search is never closed by reach.
-- @author dop42
function World.SweepReach()
	local viewers = Containers.Viewers()
	for index = 1, #viewers do
		local view = viewers[index]
		local container = Containers.Get(view.id)
		if not container or (not view.staff and not World.WithinReach(view.source, container)) then
			Containers.CloseSecondary(view.source, true)
			-- A LOCK IS SAID. Walking off or getting in closes a trunk the player
			-- can see they left; the owner locking the car shut it under their
			-- hands, and a panel that just vanished read as a bug. Once: the view
			-- is gone, so the next sweep does not find it again.
			if container and container.kind == KIND.TRUNK and container.vehicleId
				and World.TrunkLocked(container.vehicleId) then
				OPX.Refuse(view.source, 'inventory.error.locked', M.Operation.VEHICLE)
			end
		end
	end
end
