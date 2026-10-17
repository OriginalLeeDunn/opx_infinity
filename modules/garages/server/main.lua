--- Server half: the garages, what may come out of each, and where it comes out.
-- @author XEROX710
--
-- Everything the client believes is re-derived here before a vehicle exists: an
-- ask is a hint, and the mask is these checks. The distance is measured across
-- the ground against the DECLARED position, exactly as the client measures it,
-- and the bucket must agree -- a marker drawn for another routing bucket is not
-- one a player can use.
--
-- This module creates no vehicle of its own: it hands the plate to the
-- `vehicles` contract, which re-proves the ownership from the character roster
-- before it moves anything. Two owners of the same question would be one too
-- many, and the plate is the one this half does not own.
--
-- A GARAGE IS A KEY AND THE KEY IS IN SEVERAL PLACES. What a player walks up to
-- is a POINT -- a menu point or a door -- and every point knows which garage it
-- belongs to and which of that garage's locations it is at. A vehicle is filed
-- under the GARAGE, never under a point, which is what makes storing at one
-- location and fetching at another one garage rather than two.
--
-- WHERE A VEHICLE COMES OUT IS DECIDED HERE AND NOWHERE ELSE. The location's
-- EXITS are tried in the order the operator wrote them and the first one with
-- nothing parked on it wins. When all of them are taken the request is REFUSED
-- and the player told so: the owner chose that over the two alternatives, which
-- are queueing the player behind a car nobody may move and creating a vehicle
-- inside the one already there.
--
-- THE PLACEMENT COMMANDS ARE GONE. `/opx.garages.add` and `.remove` wrote into
-- `opx77_garages`, so the shape of the world lived in a table nobody had a copy
-- of. A garage is written in `config/garages.lua` now. What did NOT go is the
-- READ of that table: see "the legacy adoption" below, which is the whole of the
-- migration and the reason removing the commands loses nothing.
--
-- Every value off the wire goes through `safe` before it reaches a format
-- string: a newline would forge a whole log line.

local M = OPX.Modules.Get('garages')
local Access = M.Access

local Result = OPX.Result
local Store = M.Storage

-- The garages an operator wrote in config, and the ones adopted out of the
-- legacy table at boot.
local configGarages = {}
local adopted = {}

-- Config overlaid by the adoption, and the flat point table every read below
-- uses. Both are rebuilt together and never separately: a point whose garage is
-- not in `garages` is a marker that opens a list of nothing.
local garages = {}
local spots = {}

-- Per-player rate-limit windows for requests that are not rate-limited by
-- `OPX.Cooling`.
local windows = {}

-- The contracts, resolved in `Start`. Nil means nothing can be proved and every
-- request is refused -- except `keys`, the vehicle keys contract, whose absence
-- only means a car comes out without a key being cut.
local vehicles, character, keys

-- Whether the sweep is running. Set in `Start`.
local running = false

-- Whether the missing occupancy read was already said: without
-- `Open77.vehicles.all` no exit can be told apart from a free one, and every
-- bring-out takes the first exit. That is the old behaviour and it is not worth
-- refusing over, but it is worth an operator being able to find it.
local reportedOccupancy = false

-- EXITS PROMISED TO A BRING-OUT STILL ON ITS WAY, exit -> the clock time the
-- promise lapses. `freeExit` reads the world, and the spawn after it yields on
-- the database before the car exists: two players at one garage pressing the
-- key in the same moment both read bay one free and both cars were created on
-- it, one inside the other. A bay is held from the choice until the car stands
-- on it (it is then in the world, which is what `freeExit` reads) or the spawn
-- is refused. Weak keys: a rebuilt garage table lets the old exits go.
local promised = setmetatable({}, { __mode = 'k' })
-- Long enough for a spawn's database round trip, short enough that a thread the
-- host dropped mid-yield costs one bay for a moment, not for the session.
local PROMISE_MS = 10000

-- Longest wire value a log line carries, in characters.
local MAX_LOGGED = 64

-- How long a rate-limit window lives past a player's last request.
local WINDOW_GC_MS = 60000

local coordinate, integer = Access.Coordinate, Access.Integer

-- Cleans and caps a wire value before it reaches a log line.
local function safe(value)
	return OPX.Text.Clean(value, MAX_LOGGED, '...') or ''
end

-- Counts one event in a player's window, refusing at the limit rather than
-- counting on through the rest of it.
local function within(player, limit, spanMs)
	if limit <= 0 or spanMs <= 0 then return true end
	local at = OPX.Now()
	local window = windows[player]
	if window == nil or at - window.started >= spanMs then
		window = { started = at, count = 0 }
		windows[player] = window
	end
	if window.count >= limit then return false end
	window.count = window.count + 1
	return true
end

--- Answers the character this connection has loaded, or nil.
-- The only ownership oracle there is: a citizen id in a payload is a claim.
local function characterOf(source)
	if character == nil then return nil end
	local player = character.GetPlayer(source)
	return player and player.PlayerData or nil
end

--- Reads a connection's ground position and bucket, or nil.
local function pointOf(source)
	local position = Open77.players.position(source)
	if type(position) ~= 'table' then return nil end
	local x, y = coordinate(position.x), coordinate(position.y)
	if x == nil or y == nil then return nil end
	local bucket = integer(position.bucket)
	return { x = x, y = y, bucket = bucket or 0 }
end

--- Rebuilds the merged garages and the flat point table under them.
-- Called once at load and once when the legacy adoption has finished.
local function rebuild()
	garages, spots = {}, {}
	for key, built in pairs(configGarages) do garages[key] = built end
	for key, built in pairs(adopted) do
		-- CONFIG WINS, and this is the one precedence the rework reverses. A
		-- captured row used to overlay the config file, because the command was
		-- the authority and the file was the backup. There is no command now:
		-- the file IS the garage, and a stale row of the same name silently
		-- moving it would be a garage an operator cannot move by editing the one
		-- place they are told to edit.
		if garages[key] == nil then garages[key] = built end
	end
	for _, built in pairs(garages) do
		for _, point in ipairs(Access.PointsOf(built)) do spots[point.key] = point end
	end
end

--- The location a point belongs to, or nil.
local function locationOf(point)
	if type(point) ~= 'table' then return nil end
	local built = garages[point.garage]
	if built == nil then return nil end
	return built.locations[point.location]
end

--- The points of one bucket, ready for the wire.
local function payloadFor(bucket)
	local list = Access.InBucket(spots, bucket)
	local out = {}
	for index = 1, #list do out[index] = Access.Serialise(list[index]) end
	return out
end

--- Sends one player the points of their own bucket.
local function sync(player)
	if type(player) ~= 'number' then return end
	local at = pointOf(player)
	if at == nil then return end
	TriggerClientEvent(M.Event.SYNC, player, { spots = payloadFor(at.bucket) })
end

--- Sends every connected player their own list. Guarded: the adoption must not
--- fail because one connection could not be read.
local function syncAll()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return end
	for index = 1, #ids do
		local sent, failure = pcall(sync, tonumber(ids[index]))
		if not sent then
			Open77.log.warn('[garages] sync failed: ' .. tostring(failure))
		end
	end
end

--- Whether a stored row may come out of a garage.
-- The kind is the only thing decided here, and it is the whole rule: a ground
-- garage takes a ground vehicle and a pad takes an AV. Whether a row may come
-- out at all is the vehicles contract's question, not this module's.
local function eligible(row, built)
	if type(row) ~= 'table' or type(row.plate) ~= 'string' then return false end
	local av = Access.IsAv(row.record)
	if built.kind == M.KIND.AVPAD then return av end
	return not av
end

--- Picks what comes out: a named plate when one was named, otherwise the
--- player's own vehicle stored at THIS garage, and failing that any eligible one.
-- Ties are broken by plate because the order the rows arrive in is ANOTHER
-- MODULE'S. `vehicles.List` answers them `ORDER BY created_at`, which is not
-- part of that contract and not this module's to lean on: a stored vehicle
-- landing on a second row with the same timestamp, or that query gaining an
-- index, would change which of two equally eligible cars the same press hands
-- over. The plate is the row's own and never ties.
--
-- THE RANK IS THE GARAGE'S KEY AND NOT A POINT'S, which is the difference the
-- rework turns on: a car put away at the Watson door of `garage1` ranks first at
-- the Japantown menu of `garage1`, because both of them ARE `garage1`.
local function choose(rows, built, wanted)
	local ranked = {}
	for index = 1, #rows do
		local row = rows[index]
		if eligible(row, built) then
			ranked[#ranked + 1] = {
				row = row,
				rank = (row.garage == built.key) and 0 or 1,
			}
		end
	end
	table.sort(ranked, function(left, right)
		if left.rank ~= right.rank then return left.rank < right.rank end
		return left.row.plate < right.row.plate
	end)

	if type(wanted) ~= 'string' or wanted == '' then
		return ranked[1] and ranked[1].row or nil
	end
	for index = 1, #ranked do
		if ranked[index].row.plate == wanted then return ranked[index].row end
	end
	return nil, 'vehicle.notFound'
end

--- The first exit of a location with nothing parked on it, or nil.
-- @author XEROX710
--
-- IN THE ORDER THE OPERATOR WROTE THEM, which is the contract `config/garages.lua`
-- states: the first exit is the one the bay is meant to use and the rest are the
-- fallbacks, in preference order. Answering nil is a REFUSAL and never a licence
-- to use the last one anyway.
--
-- Measured flat, against the DECLARED exit position, and only against vehicles
-- in the location's own routing bucket -- a car in another instance is not
-- standing in this bay. `skipId` is the vehicle being fetched: a car left
-- standing on the only exit of its own garage would otherwise be a car that can
-- never be recalled, which is the one occupancy that must not count.
--
-- A HOST THAT CANNOT LIST VEHICLES ANSWERS THE FIRST EXIT. There is then nothing
-- to measure and every exit reads as free, which is exactly what this module did
-- before there were exits at all; it is said once rather than refused, because a
-- garage that stops working on an older host is worse than one that occasionally
-- drops a car on another.
-- @param place table a location
-- @param skipId any the engine id of the vehicle being fetched, or nil
-- @return table|nil the exit
-- @return integer|nil which one it was, so the log can say
local function freeExit(place, skipId)
	local parked = {}
	local api = Open77.vehicles
	if type(api) == 'table' and type(api.all) == 'function' then
		local read, listed = pcall(api.all, place.bucket)
		if read and type(listed) == 'table' then
			for index = 1, #listed do
				local car = listed[index]
				local at = type(car) == 'table' and (type(car.position) == 'table' and car.position
					or car) or nil
				local x = at ~= nil and coordinate(at.x) or nil
				local y = at ~= nil and coordinate(at.y) or nil
				local id = type(car) == 'table' and car.id or nil
				if x ~= nil and y ~= nil and
					(skipId == nil or id == nil or tostring(id) ~= tostring(skipId)) then
					parked[#parked + 1] = { x = x, y = y }
				end
			end
		end
	elseif not reportedOccupancy then
		reportedOccupancy = true
		Open77.log.warn('[garages] this host cannot list vehicles, so no exit can be told from ' ..
			'an occupied one: every bring-out takes the first exit written')
	end

	for slot = 1, #place.exits do
		local exit = place.exits[slot]
		local free = true
		for index = 1, #parked do
			local dx, dy = parked[index].x - exit.x, parked[index].y - exit.y
			if dx * dx + dy * dy <= Access.EXIT_CLEARANCE_SQ then
				free = false
				break
			end
		end
		local held = promised[exit]
		if free and held ~= nil and OPX.Now() < held then free = false end
		if free then return exit, slot end
	end
	return nil, nil
end

--- The point a request names, resolved against where the connection is standing.
-- THE ONE RESOLVER. The point underfoot, the routing bucket and the reach are
-- the same three questions whether the key is about to open a list, take a
-- vehicle out or put one away, and a second copy for the second job would be a
-- second answer to them.
--
-- A NAME MAY BE A POINT OR A GARAGE. `/opx.garages.bring garage1` is what an
-- operator types, and `garage1` is a garage with several points; the nearest
-- point OF THAT GARAGE is what they mean. A point key -- which only ever comes
-- off the wire -- is matched exactly.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point or garage name; the nearest point when omitted
-- @return spot|nil
-- @return Result|nil the refusal, when there is one
local function resolve(source, key)
	local at = pointOf(source)
	if at == nil then return nil, Result.Err('garages.noPosition') end

	local point = nil
	if key == nil or key == '' then
		-- IN THE CONNECTION'S OWN BUCKET. Over every bucket, an instanced copy of
		-- a garage standing on the same spot that sorted first by key won the
		-- search and was then refused as `wrongBucket`, to a player standing on a
		-- garage in their own.
		point = Access.Nearest(Access.InBucket(spots, at.bucket), at.x, at.y,
			OPX.Spots.ServerReachSq(Access.USE_RADIUS))
	else
		point = Access.Spot(spots, key)
		if point == nil and garages[key] ~= nil then
			-- The garage's points in this bucket when it has any there, and all
			-- of them otherwise -- so a garage that is only elsewhere still
			-- answers `wrongBucket` below rather than `noSuchSpot`.
			local mine, here = {}, {}
			for _, candidate in ipairs(Access.PointsOf(garages[key])) do
				mine[candidate.key] = candidate
				if candidate.bucket == at.bucket then here[candidate.key] = candidate end
			end
			if next(here) ~= nil then mine = here end

			-- UNBOUNDED, and that is the difference between two refusals an
			-- operator reads. Asking for the nearest point WITHIN REACH answers
			-- nil for somebody standing across the street from the garage they
			-- named, and nil here means `noSuchSpot` -- "there is no garage
			-- here", about a garage that plainly exists. The reach is applied
			-- below, once, where its refusal says it was the distance.
			point = Access.Nearest(mine, at.x, at.y, math.huge)
		end
	end
	if point == nil then return nil, Result.Err('garages.noSuchSpot') end
	if point.bucket ~= at.bucket then return nil, Result.Err('garages.wrongBucket') end

	local flat = Access.FlatDistanceSquared(point, at.x, at.y)
	-- WITH THE SERVER'S SLACK: the row was drawn from where the client stood,
	-- and this measures where the player was last observed (`REACH_SLACK`).
	if flat == nil or flat > OPX.Spots.ServerReachSq(Access.USE_RADIUS) then
		return nil, Result.Err('garages.tooFar', point.key)
	end
	return point, nil
end

--- Every vehicle the connection may bring out of the garage a point belongs to.
-- @author XEROX710
--
-- THE GARAGE'S WHOLE LIST, and that is the feature: a player standing at one
-- location sees what they left at every other one. `here` says which rows were
-- filed at this garage, so the list can show the rest as what they are -- a car
-- that is somewhere else and will be fetched to here.
-- @param source Source
-- @param key string|nil the point name; the nearest one when omitted
-- @return Result
function M.List(source, key)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end
	local point, refusal = resolve(source, key)
	if point == nil then return refusal end
	local built = garages[point.garage]
	if built == nil then return Result.Err('garages.noSuchSpot') end

	local owned = vehicles.List(data.citizenId)
	if not owned.ok then return owned end
	local rows = type(owned.value) == 'table' and owned.value or {}

	local listed = {}
	for index = 1, #rows do
		local row = rows[index]
		if eligible(row, built) then
			listed[#listed + 1] = {
				plate = row.plate,
				record = row.record,
				-- The model as a player calls it, so the list is not bare plates.
				name = OPX.Vehicle.DisplayName(row.record),
				here = row.garage == built.key,
			}
		end
	end
	table.sort(listed, function(left, right)
		if left.here ~= right.here then return left.here end
		return left.plate < right.plate
	end)

	return Result.Ok({
		spot = point.key,
		garage = built.key,
		label = built.label,
		kind = built.kind,
		vehicles = listed,
	})
end

--- Brings one of the connection's own vehicles out at a free exit of the
--- location it is standing at.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point or garage name; the nearest point when omitted
-- @param wanted string|nil a plate the caller claims
-- @return Result
function M.Bring(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end
	local point, refusal = resolve(source, key)
	if point == nil then return refusal end
	local built = garages[point.garage]
	local place = locationOf(point)
	if built == nil or place == nil then return Result.Err('garages.noSuchSpot') end

	local owned = vehicles.List(data.citizenId)
	if not owned.ok then return owned end
	local current = characterOf(source)
	if current == nil or current.citizenId ~= data.citizenId then
		return Result.Err('garages.noCharacter')
	end
	local checked, stale = resolve(source, point.key)
	if checked == nil then return stale end
	local rows = type(owned.value) == 'table' and owned.value or {}
	local pick, why = choose(rows, built, wanted)
	if pick == nil then return Result.Err(why or 'garages.nothingHere', built.key) end

	-- THE VEHICLE BEING FETCHED DOES NOT BLOCK ITS OWN BAY. It is read through
	-- the contract that owns it rather than guessed at: a plate that is not out
	-- has no id, and an id that is not out cannot be standing on anything.
	--
	-- `LiveId` AND NOT `Get`, deliberately. `Get` answers the same fact among
	-- several others and reaches the database to do it, which YIELDS -- one more
	-- round trip on the hottest path here, for something already in that module's
	-- memory. A contract too old to have it costs the exemption and nothing else:
	-- the car then blocks its own bay, which is the behaviour a single-exit
	-- garage had before there were exits.
	local outNow = type(vehicles.LiveId) == 'function' and vehicles.LiveId(pick.plate) or nil

	local exit, slot = freeExit(place, outNow)
	if exit == nil then
		-- REFUSED AND SAID, which is the owner's own choice: "if no exit point is
		-- free, refuse and notify the player". The alternatives were a queue
		-- behind a car nobody may move and a vehicle created inside one.
		Open77.log.info(('[garages] %s: every exit of %s location %d is occupied; %s stays in')
			:format(tostring(data.citizenId), safe(built.key), place.index, safe(pick.plate)))
		return Result.Err('garages.noFreeExit', built.label)
	end

	promised[exit] = OPX.Now() + PROMISE_MS

	-- The exit itself, never the player's side: that is the whole point of a
	-- marker. An AV is lifted clear of the pad it materialises on.
	local z = exit.z
	if Access.IsAv(pick.record) then z = z + Access.AvLift() end

	-- Flat, the shape the vehicles contract reads a named place in: a nested
	-- position would be read as no place at all and the car would land beside the
	-- player, a car's width off the marker.
	local spawned = vehicles.Spawn(source, pick.plate, {
		x = exit.x, y = exit.y, z = z,
		yaw = exit.heading,
		bucket = exit.bucket,
	})
	-- Either way the promise is kept or void now: a car on the bay is read off
	-- the world from here on, and a refused spawn left it empty.
	promised[exit] = nil
	if not spawned.ok then return spawned end

	-- THE OWNER LEAVES WITH A KEY, and with ONE. `Ensure` cuts a key only when
	-- the bag holds none to this plate, so ten take-outs are one key and not a
	-- key press; a key that was handed on is replaced the next time the car
	-- comes out, which is what a lost key costs. A bag with no room is said and
	-- is not a reason to put the car back: the car is out, and the owner can
	-- make room and take it out again.
	--
	-- ON A THREAD OF ITS OWN, AFTER THE CAR. Reading the bag can reach the
	-- database and yield, and the marker's answer -- "brought out", "moved here"
	-- -- is what the player is waiting on; a key is a side effect of that and not
	-- a condition of it, so it does not get to hold the answer up. Only a full
	-- bag is said: every other refusal is the server's, and a toast about it
	-- would be noise the player can do nothing with.
	if keys ~= nil then
		local plate, record = pick.plate, pick.record
		CreateThread(function()
			local cut = keys.Ensure(data.citizenId, plate, record)
			if type(cut) == 'table' and cut.ok ~= true then
				local current = characterOf(source)
				if cut.error == 'vehiclekeys.noRoom' and current ~= nil
					and current.citizenId == data.citizenId then
					OPX.NotifyLocale(source, cut.error, { label = tostring(cut.detail or plate) }, 'error')
				end
				Open77.log.warn(('[garages] %s came out for %s with no key cut: %s')
					:format(safe(plate), tostring(data.citizenId), tostring(cut.error)))
			end
		end)
	end

	return Result.Ok({
		spot = point.key,
		garage = built.key,
		label = built.label,
		exit = slot,
		plate = pick.plate,
		name = OPX.Vehicle.DisplayName(pick.record),
		id = spawned.value and spawned.value.id or nil,
		-- Forwarded, not decided here: whether the vehicle had to be moved is
		-- the vehicles contract's answer, and this half only repeats it.
		recalled = spawned.value and spawned.value.recalled or nil,
	})
end

--- Whether anybody but `source` sits in a vehicle, read from the host's own
--- snapshot. A vehicle that cannot be read has nobody aboard we know of.
local function othersAboard(vehicleId, source)
	local api = Open77.vehicles
	if vehicleId == nil or type(api) ~= 'table' or type(api.get) ~= 'function' then return false end
	local read, snapshot = pcall(api.get, vehicleId)
	if not read or type(snapshot) ~= 'table' or type(snapshot.occupants) ~= 'table' then
		return false
	end
	for _, occupant in ipairs(snapshot.occupants) do
		local id = type(occupant) == 'table' and (occupant.playerId or occupant.player) or occupant
		if tonumber(id) ~= tonumber(source) then return true end
	end
	return false
end

--- Whether the host has this connection in any vehicle seat at all.
local function seatedAnywhere(source)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then return false end
	local read, assignment = pcall(players.getVehicleSeat, source)
	return read and type(assignment) == 'table' and assignment.vehicleId ~= nil
end

--- The marker's one door: PUT AWAY when the connection is sitting in its own
--- vehicle, and BRING OUT otherwise.
-- ONE DECISION, MADE HERE. The player presses one key on one marker, and which
-- of the two things that key does is not something the client may claim: it is
-- read from the seat the host reports and the plate this module's own table
-- holds, both through the vehicles contract. A client that said "I am in my car"
-- would be a client deciding what gets stored.
--
-- Putting away is filed UNDER THE GARAGE and never under the point, which is the
-- whole of the rework: a car taken in at one door comes out at every location of
-- that garage, and `choose` ranks it first at all of them.
-- @author XEROX710
-- @param source Source
-- @param key string|nil the point name; the nearest one when omitted
-- @param wanted string|nil a plate the caller claims, for the bring-out half
-- @return Result
function M.Use(source, key, wanted)
	if vehicles == nil then return Result.Err('garages.noVehicles') end

	local data = characterOf(source)
	if data == nil or type(data.citizenId) ~= 'string' then
		return Result.Err('garages.noCharacter')
	end

	-- Read without trusting it: a contract too old to answer is "on foot", which
	-- is the bring-out half -- the behaviour every marker had before this.
	local seated = type(vehicles.Occupied) == 'function' and vehicles.Occupied(source) or nil
	if seated ~= nil and seated.ok and seated.value ~= nil then
		local point, refusal = resolve(source, key)
		if point == nil then return refusal end
		local built = garages[point.garage]
		if built == nil then return Result.Err('garages.noSuchSpot') end
		-- NOBODY ELSE IS IN IT. Putting a car away removes it from the world, and
		-- the removal ejects whoever is riding along -- a passenger dropped on
		-- the tarmac because the driver pressed a key. `vehicles.Spawn` and
		-- `SetState` already refuse an occupied car for the same reason.
		if othersAboard(seated.value.id, source) then
			return Result.Err('garages.passengers', built.label)
		end
		-- The model is read before the car goes, for the sentence that says so.
		local row = type(vehicles.Get) == 'function' and vehicles.Get(seated.value.plate) or nil
		local record = type(row) == 'table' and row.ok and type(row.value) == 'table'
			and row.value.record or nil
		local current = characterOf(source)
		if current == nil or current.citizenId ~= data.citizenId then
			return Result.Err('garages.noCharacter')
		end
		local checked, stale = resolve(source, point.key)
		if checked == nil then return stale end
		if othersAboard(seated.value.id, source) then
			return Result.Err('garages.passengers', built.label)
		end
		local function canRemove()
			local current = characterOf(source)
			if current == nil or current.citizenId ~= data.citizenId then
				return false, 'garages.noCharacter'
			end
			local at, stale = resolve(source, point.key)
			if at == nil then return false, stale.error end
			local occupied = vehicles.Occupied(source)
			if occupied == nil or not occupied.ok or occupied.value == nil
				or tostring(occupied.value.id) ~= tostring(seated.value.id) then
				return false, 'garages.notYours'
			end
			if othersAboard(seated.value.id, source) then
				return false, 'garages.passengers'
			end
			return true
		end
		local put = vehicles.Store(seated.value.plate, built.key, canRemove)
		if not put.ok then return put end
		return Result.Ok({
			spot = point.key,
			garage = built.key,
			label = built.label,
			plate = seated.value.plate,
			name = OPX.Vehicle.DisplayName(record),
			stored = true,
		})
	end

	-- SEATED IN A CAR THAT IS NOT THEIRS. `Occupied` answers nothing for a
	-- friend's car, a staff spawn or a ride, and this fell through to the
	-- bring-out half: the row said "Put your vehicle away", the key brought one
	-- of the player's own cars out beside them instead (or answered that every
	-- exit was blocked, by the car they were sitting in). The host's seat is
	-- read here only to tell those two apart; what may be stored is still
	-- decided by `Occupied` alone.
	if seated ~= nil and seated.ok and seatedAnywhere(source) then
		return Result.Err('garages.notYours')
	end

	return M.Bring(source, key, wanted)
end

-- ── the doors ───────────────────────────────────────────────────────────────

--- What a sentence calls a vehicle: `Model · PLATE`, or the plate alone.
local function vehicleLabel(value)
	local plate = tostring(value.plate or '')
	if type(value.name) == 'string' and value.name ~= '' then
		return locale('garages.vehicleLabel', { name = value.name, plate = plate })
	end
	return plate
end

--- One request off the wire. Rate-limited, then answered either way.
--- The key an answer names back to the client: one this server knows, or nil.
---
--- THE CLIENT'S OWN ARGUMENT WAS ECHOED, whatever it was: a 48 KiB string came
--- back as 48 KiB on every refusal, rate-limited ones included. The client
--- matches an answer to the marker it pressed, and only a key naming a spot or
--- a garage can be that.
local function echoOf(key)
	if type(key) ~= 'string' then return nil end
	if Access.Spot(spots, key) ~= nil or garages[key] ~= nil then return key end
	return nil
end

local function onRequested(key, plate)
	local src = tonumber(source)
	if src == nil then return end
	if key ~= nil and type(key) ~= 'string' then key = nil end
	if plate ~= nil and type(plate) ~= 'string' then plate = nil end

	-- THE DECLARED COOLDOWN, WHICH WAS DECLARED AND NOT ENFORCED. `COOLDOWN_MS`
	-- is written in `config/garages.lua`, read into `Access.COOLDOWN_MS` and
	-- validated at boot -- and then nothing anywhere applied it. Only the
	-- six-per-ten-seconds window ran, so six bring-outs could land in one tick.
	--
	-- That is not merely untidy. `Store.FetchOne` YIELDS before the already-out
	-- guard in `modules/vehicles/server/main.lua`, so two `M.Bring` threads for
	-- the same plate both pass it and both reach `vehicles.create` -- two cars
	-- from one row. The race lives in `vehicles` and wants fixing there; this is
	-- the caller that can drive it, and the floor its own config already asked
	-- for is what stops it being driven.
	if Access.COOLDOWN_MS > 0 and OPX.Cooling(src, 'garages.bring', Access.COOLDOWN_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, echoOf(key), false, 'garages.rateLimited')
		return
	end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		TriggerClientEvent(M.Event.ANSWER, src, echoOf(key), false, 'garages.rateLimited')
		return
	end

	CreateThread(function()
		-- From the floor nothing comes out and nothing goes in: the down screen
		-- is drawn by the client, and a client on it still sends the key.
		if OPX.Life.Down(src) then
			TriggerClientEvent(M.Event.ANSWER, src, echoOf(key), false, 'error.incapacitated')
			return
		end
		local used = M.Use(src, key, plate)
		if not used.ok then
			-- ONE DOOR, AND IT CARRIES THE GARAGE'S NAME. This sent the refusal, a
			-- toast of the same code AND this answer, which the client toasts too:
			-- three toasts for one refusal, and the refusal's copy read `Every exit
			-- at {garage} is blocked` because a refusal carries no params. The
			-- answer is the one the client was already reading; it now carries
			-- the detail the sentence names.
			TriggerClientEvent(M.Event.ANSWER, src, echoOf(key), false, used.error, nil, nil,
				safe(used.detail))
			Open77.log.info(('[garages] player %d refused %s: %s'):format(src, safe(key),
				tostring(used.error)))
			return
		end
		-- The action travels with the answer and into the line, because the three
		-- outcomes read the same from the outside and do not mean the same thing:
		-- a car that came from the roster, one that had to be moved to this
		-- marker first, and one the player just handed over.
		local value = used.value
		local action = value.stored and 'stored' or (value.recalled and 'recalled' or 'brought')
		-- NAMED AS THE LIST NAMES IT, model and plate, and a recall says it was
		-- recalled: it said "Brought out XX" for a car that had been moved from
		-- across the map, which is the phrasing behind the six-presses report.
		local vehicle = vehicleLabel(value)
		if value.stored then
			OPX.NotifyLocale(src, 'garages.storedAway', { vehicle = vehicle }, 'success')
		elseif value.recalled then
			OPX.NotifyLocale(src, 'garages.recalled', { vehicle = vehicle }, 'success')
		else
			OPX.NotifyLocale(src, 'garages.broughtOut', { vehicle = vehicle }, 'success')
		end
		TriggerClientEvent(M.Event.ANSWER, src, echoOf(key), true, nil, value.plate, action)
		Open77.log.info(('[garages] player %d %s %s at %s%s'):format(src,
			action == 'stored' and 'put away' or (action == 'recalled' and 'moved' or 'brought out'),
			safe(value.plate), safe(value.garage),
			value.exit ~= nil and (' exit ' .. tostring(value.exit)) or ''))
	end)
end

--- One list off the wire, for the menu point the player is standing on.
-- Counted against the same window a bring-out is: a client asking for a roster
-- in a loop is a client reading the database in a loop.
local function onListed(key)
	local src = tonumber(source)
	if src == nil then return end
	if key ~= nil and type(key) ~= 'string' then key = nil end
	if not within(src, Access.REQUESTS_PER_WINDOW, Access.REQUEST_WINDOW_MS) then
		return OPX.Refuse(src, 'error.tooFast', M.Operation.LIST)
	end

	CreateThread(function()
		local listed = M.List(src, key)
		if not listed.ok then
			-- Only the list answer, which the client toasts: the refusal beside it
			-- put the same sentence up twice.
			TriggerClientEvent(M.Event.VEHICLES, src, { spot = echoOf(key), error = listed.error })
			return
		end
		TriggerClientEvent(M.Event.VEHICLES, src, listed.value)
	end)
end

-- ── the commands ────────────────────────────────────────────────────────────

--- Registers one command from the config, or nothing when it is unnamed.
local function register(name, opts, handler)
	if type(name) ~= 'string' or name == '' then return end
	OPX.Command.Register(name, opts, handler)
end

-- Prints every garage: its kind, each location's points, and whether the garage
-- came from config or was adopted out of the legacy table.
local function report(source)
	local lines = {}
	local keys, adoptedCount = {}, 0
	for key in pairs(garages) do keys[#keys + 1] = key end
	table.sort(keys)
	for index = 1, #keys do
		local built = garages[keys[index]]
		local legacy = adopted[built.key] ~= nil and configGarages[built.key] == nil
		if legacy then adoptedCount = adoptedCount + 1 end
		lines[#lines + 1] = ('%s %s %s %d location(s) %s'):format(
			built.key, built.kind, built.label, #built.locations,
			legacy and 'legacy' or 'config')
		for _, place in ipairs(built.locations) do
			lines[#lines + 1] = ('  %d menu=%.2f,%.2f,%.2f in=%.2f,%.2f,%.2f yaw=%.1f ' ..
				'exits=%d bucket=%d'):format(place.index,
				place.menu.x, place.menu.y, place.menu.z,
				place.entry.x, place.entry.y, place.entry.z, place.entry.heading,
				#place.exits, place.bucket)
		end
	end
	lines[#lines + 1] = ('%d garage(s): %d from config, %d adopted'):format(#keys,
		#keys - adoptedCount, adoptedCount)
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- Registers the two commands that are left.
-- `add` and `remove` are gone: they wrote a place every player uses into a table
-- only one host had. See the header.
local function registerCommands()
	local names = type(M.Settings.COMMANDS) == 'table' and M.Settings.COMMANDS or {}

	register(names.list, { restricted = true, help = 'garages.help.list' }, function(source)
		report(source)
	end)

	register(names.bring, {
		restricted = true,
		help = 'garages.help.bring',
		params = {
			{ name = 'key', optional = true, help = locale('garages.help.bringKey') },
			{ name = 'plate', optional = true, help = locale('garages.help.bringPlate') },
		},
	}, function(source, args)
		local key = type(args[1]) == 'string' and args[1] or nil
		local plate = type(args[2]) == 'string' and args[2] or nil
		CreateThread(function()
			local brought = M.Bring(source, key, plate)
			if not brought.ok then
				OPX.NotifyLocale(source, brought.error, { garage = safe(brought.detail) }, 'error')
				return OPX.CommandResult(source, false, tostring(brought.error))
			end
			OPX.NotifyLocale(source, brought.value.recalled and 'garages.recalled' or 'garages.broughtOut',
				{ vehicle = vehicleLabel(brought.value) }, 'success')
			OPX.CommandResult(source, true, ('%s out at %s'):format(brought.value.plate,
				brought.value.label))
		end)
	end)
end

-- ── the legacy adoption ─────────────────────────────────────────────────────

--- Turns one row of `opx77_garages` into a garage of one location.
-- @author XEROX710
--
-- THIS IS THE WHOLE MIGRATION, and it is written as code rather than as a SQL
-- script for one reason: a spot in that table is a spot NOBODY HAS A COPY OF.
-- The commands that wrote it are gone, so without this every marker an operator
-- ever placed in game disappears the moment this version starts -- silently,
-- because an empty `GARAGES` block is a valid config.
--
-- A legacy spot was ONE POINT that did everything: you stood on it, pressed the
-- key, and the car appeared where you were standing. So it adopts as one
-- location whose menu, door and only exit are that same point, which is exactly
-- what it did before. The key is kept, which is what makes it seamless: a
-- vehicle's `garage` column already holds it, so not one row is rewritten.
--
-- It is READ-ONLY. Nothing writes to `opx77_garages` any more and nothing drops
-- it: an operator who has not yet checked their spots in can roll back to the
-- previous version and still have them.
local function adopt(row)
	local key = row.spot_key
	local block = {
		KIND = row.kind,
		LABEL = row.label,
		LOCATIONS = { {
			BUCKET = row.bucket,
			MENU = { X = row.x, Y = row.y, Z = row.z },
			ENTRY = { X = row.x, Y = row.y, Z = row.z, HEADING = row.heading },
			EXITS = { { X = row.x, Y = row.y, Z = row.z, HEADING = row.heading } },
		} },
	}
	local problems = {}
	local built = select(1, Access.CoerceGarages({ [key] = block }, problems))
	return built[key], problems[1]
end

--- The block an operator pastes into `config/garages.lua` to keep a garage.
-- Written at every start for every adopted garage, for the reason the old
-- capture line was written once into one player's chat box and then lost.
local function configLines(built)
	local lines = { ('[garages] config line: %s = { LABEL = %q, KIND = %q, LOCATIONS = {')
		:format(built.key, built.label, built.kind) }
	for _, place in ipairs(built.locations) do
		lines[#lines + 1] = ('[garages] config line:   { BUCKET = %d,'):format(place.bucket)
		lines[#lines + 1] = ('[garages] config line:     MENU = { X = %.2f, Y = %.2f, Z = %.2f },')
			:format(place.menu.x, place.menu.y, place.menu.z)
		lines[#lines + 1] = ('[garages] config line:     ENTRY = { X = %.2f, Y = %.2f, Z = %.2f, ' ..
			'HEADING = %.1f },'):format(place.entry.x, place.entry.y, place.entry.z,
			place.entry.heading)
		lines[#lines + 1] = '[garages] config line:     EXITS = {'
		for _, exit in ipairs(place.exits) do
			lines[#lines + 1] = ('[garages] config line:       { X = %.2f, Y = %.2f, Z = %.2f, ' ..
				'HEADING = %.1f },'):format(exit.x, exit.y, exit.z, exit.heading)
		end
		lines[#lines + 1] = '[garages] config line:     } },'
	end
	lines[#lines + 1] = '[garages] config line: } },'
	return lines
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state from config and contributes this module's table. Never yields.
-- @author XEROX710
function M.Init()
	configGarages = Access.GARAGES
	adopted = {}
	rebuild()
	windows = {}
	running = false
	reportedOccupancy = false
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the garages contract.
-- @author XEROX710
function M.Api()
	OPX.Api.Provide('garages', 1, {
		Bring = M.Bring,
		Use = M.Use,
		List = M.List,
		-- The DRAWN POINTS, by point key. What a marker is, and nothing about
		-- what a vehicle is filed under.
		Spots = function() return spots end,
		-- THE GARAGES, by the key a vehicle's `garage` column holds. The
		-- dealership names one of these as a delivery destination, and naming a
		-- point there would file a car under a marker rather than under a
		-- garage -- which is a car that comes out of exactly one door of one
		-- location and nowhere else.
		Garages = function() return garages end,
		State = function()
			local listed = {}
			for key, built in pairs(garages) do
				listed[key] = { kind = built.kind, label = built.label,
					locations = #built.locations,
					adopted = adopted[key] ~= nil and configGarages[key] == nil }
			end
			return Result.Ok({ garages = listed })
		end,
	})
end

--- Resolves the contracts, adopts the legacy rows and wires the doors.
-- @author XEROX710
function M.Start()
	character = OPX.Api.Get('character')
	vehicles = OPX.Api.Get('vehicles')
	keys = OPX.Api.Get('vehiclekeys')
	if character == nil then
		Open77.log.warn('[garages] no character contract: nothing can be proved owned, so ' ..
			'every request is refused')
	end
	if vehicles == nil then
		Open77.log.error('[garages] no vehicles contract: no marker can bring anything out')
	end

	for _, line in ipairs(Access.Problems()) do
		Open77.log.warn('[garages] config: ' .. line)
	end

	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		-- A FLOOR, as every other door here has one: each ask is a character
		-- read, a bucket filter, a sort and a payload, and a client polls every
		-- POLL_MS (15 s). Faster than once a second is not a client polling.
		if OPX.Cooling(player, 'garages.ask', 1000) then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.REQUEST, onRequested)
	RegisterNetEvent(M.Event.LIST, onListed)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		local player = tonumber(playerId)
		if player ~= nil then windows[player] = nil end
	end)

	running = true
	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[garages] the legacy spots could not be read: ' ..
				tostring(rows.detail))
			return
		end
		local loaded = type(rows.value) == 'table' and rows.value or {}
		local accepted, refused, shadowed = 0, 0, 0
		for index = 1, #loaded do
			-- ONE RESUME PER ROW. Every adoption coerces a whole garage and every
			-- config line below formats a dozen strings, and a loop that did all
			-- of both in the resume that read the database would run out of
			-- instruction budget partway down -- the coroutine unwinding with no
			-- error, no log and no refusal, leaving the garages it got to and
			-- silently dropping the rest. That failure has cost this codebase
			-- four outages; `modules/admin/client/target.lua` `register()` is the
			-- worked example and says so at length. A frame per row costs nothing
			-- at boot.
			Wait(0)
			local built, why = adopt(loaded[index])
			if built == nil then
				refused = refused + 1
				Open77.log.warn('[garages] a legacy spot was refused: ' .. tostring(why))
			else
				accepted = accepted + 1
				adopted[built.key] = built
			end
		end
		rebuild()
		for key in pairs(adopted) do
			if configGarages[key] ~= nil then shadowed = shadowed + 1 end
		end
		-- A player who connected while the database was being read asked too
		-- early and was told nothing; they ask again on their own cadence.
		syncAll()
		Open77.log.info(('[garages] ready: %d from config, %d adopted from the legacy table, ' ..
			'%d refused, %d shadowed by a garage of the same name in config'):format(
			OPX.Table.Count(configGarages), accepted - shadowed, refused, shadowed))

		-- EVERY ADOPTED GARAGE, AS THE CONFIG BLOCK THAT WOULD RECREATE IT.
		--
		-- The line the old `add` command handed the operator was handed to one
		-- player, once, in a chat box, and is a line nobody has. The whole set is
		-- written at every start instead, so emptying the table, restoring an
		-- older dump or moving to another host costs a scroll of the journal
		-- rather than every garage on the server. THIS IS THE OTHER HALF OF THE
		-- MIGRATION: the adoption keeps the server running, and these lines are
		-- how an operator stops needing it.
		local keys = {}
		for key in pairs(adopted) do
			if configGarages[key] == nil then keys[#keys + 1] = key end
		end
		table.sort(keys)
		for index = 1, #keys do
			Wait(0)
			for _, line in ipairs(configLines(adopted[keys[index]])) do
				Open77.log.info(line)
			end
		end
		if #keys > 0 then
			Open77.log.warn(('[garages] %d garage(s) exist only in opx77_garages. The commands ' ..
				'that made them are gone: paste the config line(s) above into ' ..
				'config/garages.lua, or they are one dropped database away from lost')
				:format(#keys))
		end
	end)

	-- A sweep for the rate-limit windows, so a long session does not accumulate
	-- one per player that ever asked.
	CreateThread(function()
		while running do
			Wait(WINDOW_GC_MS)
			local at = OPX.Now()
			for player, window in pairs(windows) do
				if at - (window.started or at) > WINDOW_GC_MS then windows[player] = nil end
			end
		end
	end)
end

--- Stops the sweep. The garages are config, so there is nothing to write.
-- @author XEROX710
function M.Stop()
	running = false
	windows = {}
end
