--- Server half: the stations, a refuel as a server session, the can, staff.
-- @author dop42
--
-- OX'S `server.lua` AND THE HALF OF ITS CLIENT THAT DECIDED THINGS. ox's client
-- counted a refuel -- `fuelAmount += refillValue`, `price += priceTick` every
-- tick -- and sent the total in `ox_fuel:pay(price, fuel, netid)`, which the
-- server paid out on after one `type(price) == 'number'`. A client that sent
-- `pay(0, 100, netid)` had a full tank for nothing, and `ox_fuel:setFuel` took
-- any level from the driver's seat. Here a client sends WHAT it wants and HOW
-- it pays, and every number is the server's:
--
--   1. the per-player floor, the player standing (not down, loaded, on foot)
--   2. the pump: the nearest surveyed pump to where the HOST says they stand
--   3. the vehicle: the nearest canonical vehicle within reach of them
--   4. the room in the tank and what the chosen account can pay for
--   5. a `progress` bar the server starts and times (the cancel key is ox's
--      `canCancel`), and a session ticking every REFILL.TICK_MS that moves the
--      gauge and stops the pour when the car moves, the player walks off or
--      the money is no longer there -- ox's `lib.cancelProgress()` on
--      `price + priceTick >= moneyAmount`
--   6. at the end, however it ended, the litres the SERVER'S clock poured are
--      billed and written: a cancelled bar is a partial refuel, as in ox
--
-- THE CAN is the same session with the can's fill instead of a pump and an
-- account (ox's `ox_fuel:updateFuelCan`, whose `durability` the client chose).
-- Buying and refilling one is a bar at a pump and a charge after it (ox's
-- `getPetrolCan` and `ox_fuel:fuelCan`).

local M = OPX.Modules.Get('fuel')
local Model = M.Model
local Tanks = M.Tanks
local Command = M.Command
local Result = OPX.Result

-- The owner name every progress bar is started under.
local OWNER = 'fuel'

-- key -> station, and why the rest were not loaded.
local stations, problems, placeholders = {}, {}, {}

-- player -> the session they are in: a pour (`pump`, `can`) or a purchase
-- (`buy`, `refill`). One at a time, as ox's `state.isFueling`.
local sessions = {}
-- vehicle id (as text) -> the player pouring into it.
local pouring = {}

local sessionJob = nil

local function settings() return Tanks.Settings() end

-- ── reading the world ───────────────────────────────────────────────────────

--- A connection's position and bucket, or nil.
local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y), OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

--- Whether a player is sitting in a vehicle, as the host's seat ledger says.
local function seated(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.getVehicleSeat) ~= 'function' then return false end
	local read, assignment = pcall(players.getVehicleSeat, player)
	return read and type(assignment) == 'table' and assignment.vehicleId ~= nil
end

local function distance(a, x, y, z)
	local dx, dy, dz = a.x - x, a.y - y, a.z - z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--- The nearest canonical vehicle to a point within a radius in one bucket that
--- takes fuel, or nil. A walk over `Open77.vehicles.all`: the server has no
--- instruction budget, and `nearby` would be a second idea of "near".
local function nearestVehicle(at, radius, wanted)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.all) ~= 'function' then return nil end
	local read, list = pcall(api.all)
	if not read or type(list) ~= 'table' then return nil end
	local best, bestDistance
	for index = 1, #list do
		local snapshot = list[index]
		if type(snapshot) == 'table' and snapshot.id ~= nil
			and (math.tointeger(OPX.Math.Finite(snapshot.bucket)) or 0) == at.bucket
			and (wanted == nil or tostring(snapshot.id) == wanted) then
			local x, y, z = Tanks.Position(snapshot)
			if x ~= nil then
				local away = distance(at, x, y, z)
				if away <= radius and (bestDistance == nil or away < bestDistance) then
					best, bestDistance = snapshot, away
				end
			end
		end
	end
	return best
end

-- ── the contracts ───────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end
local function inventory() return OPX.Api.Get('inventory') end

--- Whether a connection has a character loaded.
local function loaded(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return false end
	local read, value = pcall(api.GetPlayer, player)
	return read and type(value) == 'table'
end

--- One balance of a loaded character, or 0.
local function balance(player, method)
	local api = character()
	if api == nil or type(api.GetMoney) ~= 'function' then return 0 end
	local read, value = pcall(api.GetMoney, player, method)
	return read and math.tointeger(OPX.Math.Finite(value) or 0) or 0
end

--- Charges a loaded character. Answers whether the money moved.
local function charge(player, method, amount, reason)
	if amount <= 0 then return true end
	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return false end
	local read, ok = pcall(api.RemoveMoney, player, method, amount, reason)
	return read and ok == true
end

--- Gives money back after a sale that could not be handed over.
local function refund(player, method, amount, reason)
	if amount <= 0 then return true end
	local api = character()
	if api == nil or type(api.AddMoney) ~= 'function' then return false end
	local read, ok = pcall(api.AddMoney, player, method, amount, reason)
	return read and ok == true
end

--- Whether a method is one this server takes at a pump.
local function methodOf(value)
	if type(value) ~= 'string' then return nil end
	local accepted = type(M.Settings.PAYMENT) == 'table' and M.Settings.PAYMENT or { 'EDDIES', 'BANK' }
	for index = 1, #accepted do
		if accepted[index] == value then return value end
	end
	return nil
end

-- ── answers ─────────────────────────────────────────────────────────────────

--- Sends one answer to the player who asked. Never to anybody else.
local function answer(player, ok, code, extra)
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(M.Event.ANSWER, player, payload)
	return ok
end

-- ── a pour ──────────────────────────────────────────────────────────────────

local finish

--- Starts a pour into one vehicle, from a pump or a can. Answers the code.
local function startPour(player, session)
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return 'no_bar' end
	local key = tostring(session.vehicleId)
	if pouring[key] ~= nil then return 'busy' end

	local duration = math.ceil(session.maxLitres / session.rate * 1000)
	local limit = math.tointeger(OPX.Config.MODULES.progress and OPX.Config.MODULES.progress.MAX_MS) or 60000
	if duration > limit then
		duration = limit
		session.maxLitres = session.rate * duration / 1000
	end
	if duration < 250 then duration = 250 end
	session.durationMs = duration

	local animation = type(M.Settings.ANIMATION) == 'string' and M.Settings.ANIMATION ~= ''
		and { name = M.Settings.ANIMATION } or nil
	local started = progress.Start(player, OWNER, {
		label = locale(session.kind == 'can' and 'fuel.bar.can' or 'fuel.bar.pump'),
		durationMs = duration,
		cancelable = true,
		animation = animation,
	}, function(who, outcome) finish(who, outcome) end)
	if type(started) ~= 'table' or not started.ok then
		return type(started) == 'table' and started.error == 'progress_busy' and 'busy' or 'no_bar'
	end
	session.barId = started.value.id
	session.startedAt = OPX.Now()
	sessions[player] = session
	pouring[key] = player
	Tanks.Hold(session.vehicleId, true)
	return nil
end

--- The litres a session has poured by the server's clock.
local function pouredBy(session, now)
	local elapsed = math.max(0, math.min(session.durationMs, now - session.startedAt))
	return math.min(session.maxLitres, session.rate * elapsed / 1000)
end

--- Why a running pour must stop now, or nil.
local function interrupted(player, session, poured)
	local config = settings()
	if OPX.Life.Down(player) then return 'player_down' end
	if seated(player) then return 'leave_vehicle' end
	local at = pointOf(player)
	if at == nil then return 'no_position' end
	local snapshot = Tanks.Snapshot(session.vehicleId)
	if snapshot == nil then return 'vehicle_gone' end
	local x, y, z = Tanks.Position(snapshot)
	if x == nil then return 'vehicle_gone' end
	if distance(session.origin, x, y, z) > config.moveTolerance
		or math.abs(OPX.Math.Finite(snapshot.speed) or 0) > config.stopSpeed then
		return 'vehicle_moved'
	end
	if session.kind == 'pump' then
		if distance(session.pump, at.x, at.y, at.z) > OPX.Spots.ServerReach(config.useRadius) then
			return 'moved_away'
		end
		-- ox cancels when the next tick would cost more than the cash in hand.
		if Model.Cost(poured, session.price) > balance(player, session.method) then
			return 'not_enough_money'
		end
	elseif distance(at, x, y, z) > OPX.Spots.ServerReach(config.can.reach) then
		return 'moved_away'
	end
	return nil
end

--- One step of every pour: the gauge moves, and a pour that must stop stops.
local function stepAll()
	local now = OPX.Now()
	local players = {}
	for player, session in pairs(sessions) do
		if session.vehicleId ~= nil then players[#players + 1] = player end
	end
	for index = 1, #players do
		local player = players[index]
		local session = sessions[player]
		if session ~= nil then
			local ok, failure = pcall(function()
				local poured = pouredBy(session, now)
				local why = interrupted(player, session, poured)
				if why ~= nil then
					session.stopped = why
					local progress = OPX.Api.Get('progress')
					if progress ~= nil and type(progress.Stop) == 'function' then
						progress.Stop(player, OWNER, session.barId)
					end
					-- A bar the progress module no longer had settles nothing;
					-- the session must not outlive it.
					if sessions[player] == session then finish(player, { id = session.barId, ending = 'stopped' }) end
					return
				end
				Tanks.Write(session.vehicleId, session.startLitres + poured)
			end)
			if not ok then
				Open77.log.error(('[fuel] the pour of player %d raised: %s'):format(player, tostring(failure)))
				sessions[player] = nil
				if session.vehicleId ~= nil then
					pouring[tostring(session.vehicleId)] = nil
					Tanks.Hold(session.vehicleId, false)
				end
			end
		end
	end
end

--- Bills a pump pour: what the clock poured, cut to what the account can pay.
local function billPump(player, session, poured)
	local cost = Model.Cost(poured, session.price)
	local reason = 'fuel:' .. session.station
	if charge(player, session.method, cost, reason) then return poured, cost end
	-- The balance moved under the pour: bill what is there, pour only that.
	local held = balance(player, session.method)
	if session.price > 0 then
		poured = math.min(poured, math.floor(held / session.price * 1000) / 1000)
		cost = Model.Cost(poured, session.price)
		if cost <= held and charge(player, session.method, cost, reason) then return poured, cost end
	end
	return 0, 0
end

--- Takes a can pour's litres out of the can it came from. Answers the litres
--- that really left it: none when the can is no longer in its slot.
local function drainCan(player, session, poured)
	local api = inventory()
	if api == nil or type(api.GetSlot) ~= 'function' or type(api.SetMetadata) ~= 'function' then return 0 end
	local read, stack = pcall(api.GetSlot, player, session.slot)
	stack = read and type(stack) == 'table' and stack.ok and stack.value or nil
	if type(stack) ~= 'table' or stack.name ~= settings().can.item then return 0 end
	local metadata = type(stack.metadata) == 'table' and stack.metadata or {}
	local capacity = settings().can.capacity
	local inside = Model.Litres(OPX.Math.Finite(metadata.durability) or 0, capacity)
	poured = math.min(poured, inside)
	local left = math.max(0, math.floor((inside - poured) / capacity * 100 + 1e-6))
	metadata.durability, metadata.ammo = left, left
	local set = api.SetMetadata(player, session.slot, metadata)
	if type(set) ~= 'table' or not set.ok then return 0 end
	return poured
end

--- Ends a session, however it ended: called by the progress module with its
--- verdict, or by the step when the bar was already gone.
finish = function(player, outcome)
	local session = sessions[player]
	if session == nil or type(outcome) ~= 'table' or outcome.id ~= session.barId then return end
	sessions[player] = nil
	local now = OPX.Now()

	if session.vehicleId == nil then return M.Purchased(player, session, outcome) end

	pouring[tostring(session.vehicleId)] = nil
	Tanks.Hold(session.vehicleId, false)
	-- `finished` was judged against the progress module's clock; everything else
	-- is billed by this one, and a stop the step asked for says why.
	local poured = outcome.completed == true and session.maxLitres or pouredBy(session, now)
	if outcome.ending == 'left' then poured = 0 end
	local cost = 0
	if poured > 0 and session.kind == 'pump' then
		poured, cost = billPump(player, session, poured)
	elseif poured > 0 then
		poured = drainCan(player, session, poured)
	end

	local level = session.startLitres + poured
	-- Written whatever went in -- the gauge moved during the pour and must land
	-- on what was billed -- and announced only when something did.
	if Tanks.Snapshot(session.vehicleId) ~= nil then
		Tanks.Write(session.vehicleId, level,
			poured > 0 and (session.kind == 'can' and 'can' or 'refuel') or nil, player)
	end
	OPX.Audit.Log({
		event = session.kind == 'can' and 'fuel.can' or 'fuel.refuel',
		message = ('player %d poured %.2f L into %s for %d (%s)'):format(player, poured,
			tostring(session.vehicleId), cost, tostring(session.stopped or outcome.ending)),
		data = { litres = poured, cost = cost, method = session.method, station = session.station,
			vehicle = tostring(session.vehicleId), ending = outcome.ending },
		source = player,
	})
	if outcome.ending == 'left' then return end
	if poured <= 0 then
		return answer(player, false, session.stopped or 'cancelled')
	end
	answer(player, true, session.kind == 'can' and 'poured' or 'refuelled', {
		litres = math.floor(poured * 10 + 0.5) / 10,
		cost = cost,
		method = session.method,
		percent = math.floor(Model.Percent(level, Tanks.Capacity()) + 0.5),
		stopped = session.stopped,
	})
end

-- ── asking at a pump ────────────────────────────────────────────────────────

--- Everything a request at a pump has to pass first. Answers the station and
--- pump and the player's point, or nil and the code.
local function atPump(player)
	if OPX.Life.Down(player) then return nil, 'player_down' end
	if not loaded(player) then return nil, 'no_character' end
	if sessions[player] ~= nil then return nil, 'busy' end
	local at = pointOf(player)
	if at == nil then return nil, 'no_position' end
	local config = settings()
	local station, pump = Model.NearestPump(stations, at.x, at.y, at.z, at.bucket,
		OPX.Spots.ServerReach(config.useRadius))
	if station == nil then return nil, 'no_pump' end
	if seated(player) then return nil, 'leave_vehicle' end
	return { station = station, pump = station.pumps[pump], at = at }
end

local function requestFloor()
	return math.floor(Model.Bounded(M.Settings.REQUEST_MS, 100, 10000, 800))
end

--- ox's `startFueling(vehicle, isPump)`, on the server. Answers the code it said.
-- @author dop42
-- @param player integer
-- @param payload table { method }
-- @return boolean ok
-- @return string code
function M.Refuel(player, payload)
	if OPX.Cooling(player, 'fuel.request', requestFloor()) then
		return answer(player, false, 'too_fast'), 'too_fast'
	end
	local method = methodOf(type(payload) == 'table' and payload.method or nil)
	if method == nil then return answer(player, false, 'bad_method'), 'bad_method' end
	local place, why = atPump(player)
	if place == nil then return answer(player, false, why), why end
	local config = settings()

	local snapshot = nearestVehicle(place.at, OPX.Spots.ServerReach(config.vehicleReach))
	if snapshot == nil then return answer(player, false, 'vehicle_far'), 'vehicle_far' end
	if Tanks.Usage(snapshot) <= 0 then return answer(player, false, 'no_tank'), 'no_tank' end
	if pouring[tostring(snapshot.id)] ~= nil then return answer(player, false, 'busy'), 'busy' end

	local capacity = Tanks.Capacity()
	local litres = Tanks.Ensure(snapshot.id) or Tanks.Read(snapshot.id) or 0
	local room = capacity - litres
	-- ox's `100 - fuelAmount < refillValue`: less than one tick of room is full.
	if room < config.refillRate * config.refillTickMs / 1000 then
		return answer(player, false, 'tank_full'), 'tank_full'
	end
	local price = place.station.price
	local held = balance(player, method)
	local most = room
	if price > 0 then
		if held < Model.Cost(math.min(room, config.refillRate * config.refillTickMs / 1000), price) then
			return answer(player, false, 'not_enough_money', { price = price }), 'not_enough_money'
		end
		most = math.min(room, held / price)
	end

	local x, y, z = Tanks.Position(snapshot)
	local code = startPour(player, {
		kind = 'pump', vehicleId = snapshot.id, station = place.station.key,
		pump = place.pump, price = price, method = method,
		startLitres = litres, maxLitres = most, rate = config.refillRate,
		origin = { x = x, y = y, z = z },
	})
	if code ~= nil then return answer(player, false, code), code end
	answer(player, true, 'refuelling', { station = place.station.label, price = price, method = method })
	return true, 'refuelling'
end

--- The cans in a bag: { slot, durability }, emptiest first.
local function cansOf(player)
	local api = inventory()
	if api == nil or type(api.GetInventory) ~= 'function' then return {} end
	local read, bag = pcall(api.GetInventory, player)
	bag = read and type(bag) == 'table' and bag.ok and bag.value or nil
	local items = type(bag) == 'table' and type(bag.items) == 'table' and bag.items or {}
	local item, cans = settings().can.item, {}
	for index = 1, #items do
		local entry = items[index]
		if type(entry) == 'table' and entry.name == item then
			local metadata = type(entry.metadata) == 'table' and entry.metadata or {}
			cans[#cans + 1] = { slot = entry.slot,
				durability = math.max(0, math.min(100, OPX.Math.Finite(metadata.durability) or 0)),
				metadata = metadata }
		end
	end
	table.sort(cans, function(left, right)
		if left.durability ~= right.durability then return left.durability < right.durability end
		return (left.slot or 0) < (right.slot or 0)
	end)
	return cans
end

--- ox's `getPetrolCan(coords, refuel)` and `ox_fuel:fuelCan`: a bar at a pump,
--- then a can bought or the emptiest one refilled. Answers the code.
-- @author dop42
-- @param player integer
-- @param payload table { method, refill }
-- @return boolean ok
-- @return string code
function M.CanBuy(player, payload)
	if OPX.Cooling(player, 'fuel.request', requestFloor()) then
		return answer(player, false, 'too_fast'), 'too_fast'
	end
	local config = settings()
	if not config.can.enabled then return answer(player, false, 'no_can_sold'), 'no_can_sold' end
	local method = methodOf(type(payload) == 'table' and payload.method or nil)
	if method == nil then return answer(player, false, 'bad_method'), 'bad_method' end
	local place, why = atPump(player)
	if place == nil then return answer(player, false, why), why end
	local api = inventory()
	if api == nil then return answer(player, false, 'no_inventory'), 'no_inventory' end

	local refill = type(payload) == 'table' and payload.refill == true
	local price, slot = config.can.price, nil
	if refill then
		local cans = cansOf(player)
		if #cans == 0 then return answer(player, false, 'no_can'), 'no_can' end
		if cans[1].durability >= 100 then return answer(player, false, 'can_full'), 'can_full' end
		price, slot = config.can.refillPrice, cans[1].slot
	else
		local read, room = pcall(api.CanCarry, player, config.can.item, 1, { durability = 100, ammo = 100 })
		if not read or type(room) ~= 'table' or not room.ok or room.value ~= true then
			return answer(player, false, 'cannot_carry'), 'cannot_carry'
		end
	end
	if balance(player, method) < price then
		return answer(player, false, 'not_enough_money', { price = price }), 'not_enough_money'
	end

	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then return answer(player, false, 'no_bar'), 'no_bar' end
	local session = { kind = refill and 'refill' or 'buy', method = method, price = price, slot = slot,
		station = place.station.key, pump = place.pump }
	local started = progress.Start(player, OWNER, {
		label = locale(refill and 'fuel.bar.refill' or 'fuel.bar.buy'),
		durationMs = config.can.durationMs,
		cancelable = true,
	}, function(who, outcome) finish(who, outcome) end)
	if type(started) ~= 'table' or not started.ok then return answer(player, false, 'busy'), 'busy' end
	session.barId, session.startedAt = started.value.id, OPX.Now()
	sessions[player] = session
	return true, session.kind
end

--- The end of a can bought or refilled: charged first, handed over after, and
--- refunded when the hand-over is refused. Nothing for a bar cut short.
-- @author dop42
-- @param player integer
-- @param session table
-- @param outcome table
function M.Purchased(player, session, outcome)
	if outcome.completed ~= true then
		if outcome.ending ~= 'left' then answer(player, false, 'cancelled') end
		return
	end
	local api = inventory()
	local config = settings()
	local reason = 'fuel:can'
	if api == nil then return answer(player, false, 'no_inventory') end
	-- Still at a pump: the bar held them, but a bar is the client's.
	local at = pointOf(player)
	if at == nil or distance(session.pump, at.x, at.y, at.z) > OPX.Spots.ServerReach(config.useRadius) then
		return answer(player, false, 'moved_away')
	end
	if not charge(player, session.method, session.price, reason) then
		return answer(player, false, 'not_enough_money', { price = session.price })
	end
	local handed
	if session.kind == 'refill' then
		local read, stack = pcall(api.GetSlot, player, session.slot)
		stack = read and type(stack) == 'table' and stack.ok and stack.value or nil
		if type(stack) == 'table' and stack.name == config.can.item then
			local metadata = type(stack.metadata) == 'table' and stack.metadata or {}
			metadata.durability, metadata.ammo = 100, 100
			local set = api.SetMetadata(player, session.slot, metadata)
			handed = type(set) == 'table' and set.ok == true
		end
	else
		local added = api.AddItem(player, config.can.item, 1, { durability = 100, ammo = 100 })
		handed = type(added) == 'table' and added.ok == true
	end
	if not handed then
		refund(player, session.method, session.price, reason .. ':refund')
		return answer(player, false, session.kind == 'refill' and 'no_can' or 'cannot_carry')
	end
	OPX.Audit.Log({ event = 'fuel.' .. session.kind, message = ('player %d, %d'):format(player, session.price),
		data = { price = session.price, method = session.method, station = session.station }, source = player })
	answer(player, true, session.kind == 'refill' and 'can_refilled' or 'can_bought',
		{ cost = session.price, method = session.method })
end

--- ox's can-into-a-vehicle `startFueling(vehicle, false)`. `vehicleId` is the
--- eye's hint and is re-measured; nil pours into the nearest vehicle in reach.
--- `slot` is the can a bag use named; nil takes the fullest can in the bag.
-- @author dop42
-- @param player integer
-- @param vehicleId any
-- @param slot integer|nil
-- @return boolean ok
-- @return string code
function M.CanPour(player, vehicleId, slot)
	if OPX.Cooling(player, 'fuel.request', requestFloor()) then
		return answer(player, false, 'too_fast'), 'too_fast'
	end
	local config = settings()
	if not config.can.enabled then return answer(player, false, 'no_can'), 'no_can' end
	if OPX.Life.Down(player) then return answer(player, false, 'player_down'), 'player_down' end
	if not loaded(player) then return answer(player, false, 'no_character'), 'no_character' end
	if sessions[player] ~= nil then return answer(player, false, 'busy'), 'busy' end
	if seated(player) then return answer(player, false, 'leave_vehicle'), 'leave_vehicle' end
	local at = pointOf(player)
	if at == nil then return answer(player, false, 'no_position'), 'no_position' end

	-- The can: the slot a bag use named, or the fullest one held.
	local cans, can = cansOf(player), nil
	for index = #cans, 1, -1 do
		if slot == nil or cans[index].slot == slot then can = cans[index]; break end
	end
	if can == nil then return answer(player, false, 'petrolcan_not_equipped'), 'petrolcan_not_equipped' end
	local inside = Model.Litres(can.durability, config.can.capacity)
	local tick = config.can.rate * config.refillTickMs / 1000
	if inside < tick then return answer(player, false, 'petrolcan_not_enough_fuel'), 'petrolcan_not_enough_fuel' end

	local wanted = vehicleId ~= nil and tostring(vehicleId) or nil
	if wanted ~= nil and (#wanted > 32 or wanted:find('%s')) then
		return answer(player, false, 'vehicle_far'), 'vehicle_far'
	end
	local snapshot = nearestVehicle(at, OPX.Spots.ServerReach(config.can.reach), wanted)
	if snapshot == nil then return answer(player, false, 'vehicle_far'), 'vehicle_far' end
	if Tanks.Usage(snapshot) <= 0 then return answer(player, false, 'no_tank'), 'no_tank' end
	if pouring[tostring(snapshot.id)] ~= nil then return answer(player, false, 'busy'), 'busy' end
	local litres = Tanks.Ensure(snapshot.id) or Tanks.Read(snapshot.id) or 0
	local room = Tanks.Capacity() - litres
	if room < tick then return answer(player, false, 'tank_full'), 'tank_full' end

	local x, y, z = Tanks.Position(snapshot)
	local code = startPour(player, {
		kind = 'can', vehicleId = snapshot.id, slot = can.slot,
		startLitres = litres, maxLitres = math.min(room, inside), rate = config.can.rate,
		origin = { x = x, y = y, z = z },
	})
	if code ~= nil then return answer(player, false, code), code end
	answer(player, true, 'pouring')
	return true, 'pouring'
end

--- A can used from the bag: poured into the nearest vehicle in reach.
local function onCanUsed(source, info)
	local slot = type(info) == 'table' and math.tointeger(info.slot) or nil
	M.CanPour(source, nil, slot)
	-- A use that consumed nothing: the can is drained by the pour, not the use.
	return { ok = true, consume = 0 }
end

-- ── the contract ────────────────────────────────────────────────────────────

--- A vehicle id as the host spells it, from a number or its text, or nil.
-- @author dop42
-- @param value any
-- @return any|nil
function M.VehicleOf(value)
	if math.type(value) == 'integer' then return Tanks.Snapshot(value) ~= nil and value or nil end
	if type(value) ~= 'string' or #value < 1 or #value > 32 or value:find('%s') then return nil end
	if value:match('^%d+$') then
		local number = math.tointeger(tonumber(value))
		if number ~= nil and number > 0 and Tanks.Snapshot(number) ~= nil then return number end
	end
	if Tanks.Snapshot(value) ~= nil then return value end
	return nil
end

--- One vehicle's tank: { litres, capacity, percent, usesFuel }.
-- @author dop42
-- @param vehicleId any
-- @return Result
function M.Get(vehicleId)
	local id = M.VehicleOf(vehicleId)
	if id == nil then return Result.Err('fuel.noVehicle') end
	local capacity = Tanks.Capacity()
	local litres = Tanks.Read(id)
	return Result.Ok({
		litres = litres ~= nil and math.floor(litres * 1000 + 0.5) / 1000 or nil,
		capacity = capacity,
		percent = litres ~= nil and Model.Percent(litres, capacity) or nil,
		usesFuel = Tanks.Usage(Tanks.Snapshot(id)) > 0,
	})
end

--- ox's `Entity(vehicle).state:set('fuel', percent)`: sets a tank in percent.
-- @author dop42
-- @param vehicleId any
-- @param percent number 0..100
-- @param reason string who, for the bus: `staff`, `ext:<resource>`
-- @param source integer|nil
-- @return Result { litres, percent }
function M.Set(vehicleId, percent, reason, source)
	local id = M.VehicleOf(vehicleId)
	if id == nil then return Result.Err('fuel.noVehicle') end
	percent = OPX.Math.Finite(percent)
	if percent == nil or percent < 0 or percent > 100 then return Result.Err('fuel.badAmount') end
	if pouring[tostring(id)] ~= nil then return Result.Err('fuel.busy') end
	local litres = Model.Litres(percent, Tanks.Capacity())
	local written, why = Tanks.Write(id, litres, reason or 'staff', source)
	if not written then return Result.Err('fuel.refused', why) end
	return Result.Ok({ litres = litres, percent = percent })
end

-- ── staff ───────────────────────────────────────────────────────────────────

--- The vehicle a staff command means: `near` (the seat, else the nearest in
--- reach in the operator's bucket) or a typed id within reach, unless the
--- operator holds the staff module's right to reach any.
local function staffVehicle(source, token)
	local config = settings()
	if type(token) == 'string' and token:lower() == 'near' then
		if source <= 0 then return nil, 'no_vehicle' end
		local players = Open77.players
		if type(players) == 'table' and type(players.getVehicleSeat) == 'function' then
			local read, assignment = pcall(players.getVehicleSeat, source)
			if read and type(assignment) == 'table' and assignment.vehicleId ~= nil
				and Tanks.Snapshot(assignment.vehicleId) ~= nil then
				return assignment.vehicleId
			end
		end
		local at = pointOf(source)
		if at == nil then return nil, 'no_position' end
		local snapshot = nearestVehicle(at, config.staffReach)
		if snapshot == nil then return nil, 'no_vehicle' end
		return snapshot.id
	end
	local id = M.VehicleOf(token)
	if id == nil then return nil, 'no_vehicle' end
	if source > 0 then
		local read, anywhere = pcall(function() return Open77.acl.isAllowed(source, M.ANYWHERE) end)
		if not (read and anywhere == true) then
			local at = pointOf(source)
			local snapshot = Tanks.Snapshot(id)
			local x, y, z
			if snapshot ~= nil then x, y, z = Tanks.Position(snapshot) end
			if at == nil or x == nil
				or (math.tointeger(OPX.Math.Finite(snapshot.bucket)) or 0) ~= at.bucket
				or distance(at, x, y, z) > config.staffReach then
				return nil, 'out_of_reach'
			end
		end
	end
	return id
end

--- What `/opx.fuel.stations` prints.
local function report(source)
	local lines, keys = {}, {}
	for key in pairs(stations) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local station = stations[key]
		lines[#lines + 1] = ('%s %s pos=%.2f,%.2f,%.2f bucket=%d pumps=%d price=%s/L'):format(key,
			station.label, station.x, station.y, station.z, station.bucket, #station.pumps,
			tostring(station.price))
	end
	for _, key in ipairs(placeholders) do lines[#lines + 1] = key .. ' DISABLED: not surveyed yet' end
	for _, line in ipairs(problems) do lines[#lines + 1] = 'REFUSED: ' .. line end
	lines[#lines + 1] = ('%d station(s) open, %d unsurveyed, %d refused; burning: %s'):format(#keys,
		#placeholders, #problems, Tanks.StandingDown() and M.OPEN77_FUEL or 'this module')
	OPX.CommandResult(source, true, table.concat(lines, '\n'))
end

--- What `/opx.fuel.capture` prints: the line to paste into `config/fuel.lua`.
local function capture(source, args)
	if source <= 0 then return OPX.CommandResult(source, false, 'the console stands nowhere') end
	local key = type(args[1]) == 'string' and args[1] or ''
	if #key == 0 or #key > Model.MAX_KEY or not key:match('^[%w_%-]+$') then
		return OPX.CommandResult(source, false,
			('usage: capture <station> [pump] [label] -- a key is 1 to %d letters, digits, _ or -')
				:format(Model.MAX_KEY))
	end
	local at = pointOf(source)
	if at == nil then return OPX.CommandResult(source, false, 'your position could not be read') end
	local pump = type(args[2]) == 'string' and args[2]:lower() == 'pump'
	local line
	if pump then
		line = ('%s.PUMPS += { X = %.2f, Y = %.2f, Z = %.2f },'):format(key, at.x, at.y, at.z)
	else
		local words = {}
		for index = 2, #args do words[#words + 1] = tostring(args[index]) end
		local label = OPX.Text.Clean(table.concat(words, ' '), 64)
		if label == nil or label == '' then label = key end
		line = ('%s = { LABEL = %q, X = %.2f, Y = %.2f, Z = %.2f, BUCKET = %d, PUMPS = { } },')
			:format(key, label, at.x, at.y, at.z, at.bucket)
	end
	Open77.log.info(('[fuel] capture by %d: %s'):format(source, line))
	OPX.Audit.Log({ event = 'fuel.capture', message = line, source = source })
	OPX.CommandResult(source, true, ('paste into STATIONS in config/fuel.lua, then restart:\n  %s')
		:format(line))
end

local function registerCommands()
	-- `/opx.fuel.set <vehicle|near> <0-100>`: ox has none; every ox server writes
	-- `Entity(veh).state.fuel` from its own admin script.
	OPX.Command.Register(Command.SET, { restricted = true, help = 'fuel.help.set', cooldownMs = 300,
		params = {
			{ name = 'vehicle', help = locale('fuel.help.vehicle') },
			{ name = 'percent', help = locale('fuel.help.percent') },
		} },
		function(source, args, raw)
			local percent = OPX.Math.Finite(tonumber(args[2]))
			if percent == nil or percent < 0 or percent > 100 then
				return OPX.CommandNotice(source, raw, 'error', locale('fuel.error.bad_amount'))
			end
			local id, why = staffVehicle(source, args[1] or 'near')
			if id == nil then
				return OPX.CommandNotice(source, raw, 'error', locale('fuel.error.' .. why))
			end
			local set = M.Set(id, percent, 'staff', source > 0 and source or nil)
			if not set.ok then
				return OPX.CommandNotice(source, raw, 'error', locale('fuel.error.refused'))
			end
			OPX.Audit.Log({ event = 'fuel.set', message = ('%s -> %s%%'):format(tostring(id), tostring(percent)),
				data = { vehicle = tostring(id), percent = percent }, source = source > 0 and source or nil })
			OPX.CommandNotice(source, raw, 'success',
				locale('fuel.staff.set', { percent = math.floor(percent + 0.5) }), false, 'vehicle')
		end)

	OPX.Command.Register(Command.CAPTURE, { restricted = true, help = 'fuel.help.capture',
		params = {
			{ name = 'station', help = locale('fuel.help.station') },
			{ name = 'pump|label', optional = true, help = locale('fuel.help.pump') },
		} },
		function(source, args) capture(source, args) end)

	OPX.Command.Register(Command.STATIONS, { restricted = true, help = 'fuel.help.stations' },
		function(source) report(source) end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Builds the state. Never yields.
-- @author dop42
function M.Init()
	Tanks.Init()
	sessions, pouring = {}, {}
	stations, problems, placeholders = Model.Stations(Tanks.Settings(), M.Settings.STATIONS)
end

--- Publishes the server half of the fuel contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('fuel', 1, {
		--- ox's `state.fuel`, read: one vehicle's tank.
		Get = M.Get,
		--- ox's `state:set('fuel', ...)`, in percent.
		Set = M.Set,
		--- Litres, for a caller that thinks in `open77_fuel`'s unit.
		SetLitres = function(vehicleId, litres, reason, source)
			local id = M.VehicleOf(vehicleId)
			if id == nil then return Result.Err('fuel.noVehicle') end
			litres = OPX.Math.Finite(litres)
			if litres == nil or litres < 0 then return Result.Err('fuel.badAmount') end
			if pouring[tostring(id)] ~= nil then return Result.Err('fuel.busy') end
			local written, why = Tanks.Write(id, litres, reason or 'staff', source)
			if not written then return Result.Err('fuel.refused', why) end
			return Result.Ok({ litres = math.min(litres, Tanks.Capacity()) })
		end,
		--- The tank a stored car comes out with (`modules/vehicles`), written and
		--- not announced: it did not change, it was put back. Answers true.
		Restore = function(vehicleId, litres)
			litres = OPX.Math.Finite(litres)
			if vehicleId == nil or litres == nil or litres < 0 then return false end
			return Tanks.Write(vehicleId, litres) == true
		end,
		Capacity = Tanks.Capacity,
		StandingDown = Tanks.StandingDown,
		--- Every open station, as the config built it.
		Stations = function() return stations end,
		--- The session a player is in, or nil.
		Session = function(player)
			local session = sessions[player]
			if session == nil then return nil end
			return { kind = session.kind, vehicleId = session.vehicleId, station = session.station,
				method = session.method }
		end,
		Refuel = M.Refuel,
		CanBuy = M.CanBuy,
		CanPour = M.CanPour,
	})
end

--- Wires the doors, the can and the two loops. On a coroutine.
-- @author dop42
function M.Start()
	for _, line in ipairs(problems) do Open77.log.warn('[fuel] config: ' .. line) end
	if #placeholders > 0 then
		Open77.log.info(('[fuel] %d station(s) disabled until surveyed (/opx.fuel.capture): %s')
			:format(#placeholders, table.concat(placeholders, ', ')))
	end
	if next(stations) == nil then
		Open77.log.warn('[fuel] no station is open: every tank still burns, and only a can or staff fills one')
	end

	local api = inventory()
	if api ~= nil and settings().can.enabled and type(api.RegisterUsable) == 'function' then
		local registered, why = api.RegisterUsable(settings().can.item, onCanUsed, 'fuel')
		if not registered then
			Open77.log.warn(('[fuel] the can could not be made usable: %s'):format(tostring(why)))
		end
	end

	RegisterNetEvent(M.Event.REFUEL, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.Refuel(player, payload)
	end)
	RegisterNetEvent(M.Event.CAN_BUY, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		M.CanBuy(player, payload)
	end)
	RegisterNetEvent(M.Event.CAN_POUR, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		local hint = type(payload) == 'table' and payload.vehicleId or nil
		if hint ~= nil and type(hint) ~= 'string' and math.type(hint) ~= 'integer' then hint = nil end
		M.CanPour(player, hint)
	end)
	AddEventHandler(OPX.Host.VEHICLE_REMOVED, function(id) Tanks.Forget(id) end)

	registerCommands()

	OPX.Scheduler.Every('fuel:burn', Tanks.Settings().tickMs, Tanks.Tick)
	sessionJob = OPX.Scheduler.Every('fuel:pour', Tanks.Settings().refillTickMs, stepAll)
end

--- Ends every session. A pump pour is billed for what the clock poured -- the
--- character contract moves money in memory, so this needs no yield; a can pour
--- goes back to the level it started at, because draining the can is a bag
--- write a stopping resource cannot promise to finish.
-- @author dop42
function M.Stop()
	if sessionJob ~= nil and OPX.Scheduler.Cancel ~= nil then pcall(OPX.Scheduler.Cancel, sessionJob) end
	sessionJob = nil
	local players = {}
	for player in pairs(sessions) do players[#players + 1] = player end
	for _, player in ipairs(players) do
		local session = sessions[player]
		if session ~= nil and session.kind == 'pump' then
			local ok, failure = pcall(finish, player, { id = session.barId, ending = 'interrupted' })
			if not ok then Open77.log.warn('[fuel] a pour could not be billed at stop: ' .. tostring(failure)) end
		elseif session ~= nil and session.kind == 'can' then
			pcall(Tanks.Write, session.vehicleId, session.startLitres)
		end
		if session ~= nil and session.vehicleId ~= nil then Tanks.Hold(session.vehicleId, false) end
		sessions[player] = nil
	end
	pouring = {}
	local api = inventory()
	if api ~= nil and type(api.UnregisterUsable) == 'function' then
		pcall(api.UnregisterUsable, settings().can.item, 'fuel')
	end
end
