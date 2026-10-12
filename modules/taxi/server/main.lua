--- Server half: the calls, the rides, the meter and the bill.
-- @author dop42
--
-- EVERY DECISION IS HERE. The client sends six kinds of wish -- show me the
-- board, I take this call, drop it, give me a street fare, start the meter for
-- whoever sits in my cab, stop the meter -- and each is judged again from
-- scratch: who the sender is (job, grade, duty, from the character roster),
-- where they stand and what they sit in (the host's positions and seat
-- ledger), never what the payload says.
--
-- THE METER IS A SWEEP, NOT A REPORT. Every SCAN_MS the server reads the
-- driver's position and both seats. A ride starts when the customer is in a
-- seat of the vehicle whose driver's seat the driver holds; distance is added
-- only while that is still true, one clamped segment per sample
-- (`Model.Step`); it ends when the customer has been out of that vehicle for
-- EXIT_SAMPLES samples in a row. Nothing a client sends adds a metre.
--
-- THE BILL GOES THROUGH `invoices` WHEN IT RUNS (the customer accepts or
-- refuses on their own screen, the company's share lands in `accounts`), and
-- straight through character money when it does not: the fare out of the
-- customer first, the driver's cut and the company's share second.

local M = OPX.Modules.Get('taxi')

local Model = M.Model
local Dispatch = M.Dispatch
local Event = M.Event
local Kind = M.Kind
local Phase = M.Phase
local Result = OPX.Result

local DRIVER_SEAT = 'seat_front_left'

local settings
-- driver -> ride; passenger -> ride (for the rides a player is the customer of).
local rides, riding = {}, {}
-- citizenId -> { { atMs, amount } }: street pay in the last hour.
local streetPaid = {}
-- player:kind -> last request time.
local lastRequest = {}
local nextRide = 0
-- Soft dependencies already said once.
local said = {}

local function config()
	if settings == nil then settings = Model.Settings(OPX.Config.MODULES.taxi) end
	return settings
end

local function note(key, line)
	if said[key] then return end
	said[key] = true
	Open77.log.info('[taxi] ' .. line)
end

-- ── reading the world ────────────────────────────────────────────────────────

local function character() return OPX.Api.Get('character') end

local function positionOf(player)
	local read, at = pcall(Open77.players.position, player)
	if not read or type(at) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(OPX.Math.Finite(at.bucket) or 0) }
end

local function playerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = math.tointeger(tonumber(value))
		if id and id > 0 then ids[#ids + 1] = id end
	end
	return ids
end

-- The seat a player holds, from the host's seat ledger: { vehicleId, seat }, or nil.
local function seatOf(player)
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return nil end
	local read, seat = pcall(vehicles.getPlayerSeat, player)
	if not read or type(seat) ~= 'table' or seat.vehicleId == nil or type(seat.seat) ~= 'string' then
		return nil
	end
	-- Still climbing in or already climbing out is not sitting.
	if seat.entering == true or seat.exiting == true then return nil end
	return { vehicleId = tostring(seat.vehicleId), seat = seat.seat }
end

-- The vehicle a player DRIVES, as an id string, or nil.
local function drivenBy(player)
	local seat = seatOf(player)
	return seat and seat.seat == DRIVER_SEAT and seat.vehicleId or nil
end

-- The record a vehicle is built from, or nil.
local function recordOf(vehicleId)
	local vehicles = Open77.vehicles
	if vehicleId == nil or type(vehicles) ~= 'table' or type(vehicles.get) ~= 'function' then return nil end
	local id = math.tointeger(tonumber(vehicleId)) or vehicleId
	local read, snapshot = pcall(vehicles.get, id)
	if not read or type(snapshot) ~= 'table' then return nil end
	return type(snapshot.record) == 'string' and snapshot.record or nil
end

-- Whether a company accepts a vehicle for a ride.
local function allowedVehicle(co, vehicleId)
	if co.vehicles == nil then return true end
	local record = recordOf(vehicleId)
	return record ~= nil and co.vehicles[record] == true
end

-- The game hour from the weather module, or nil (no surge without a clock).
local function gameHour()
	local weather = OPX.Api.Get('weather')
	if weather == nil or type(weather.Status) ~= 'function' then return nil end
	local read, status = pcall(weather.Status)
	if not read or type(status) ~= 'table' then return nil end
	-- A Result or a plain status table: either shape is read.
	if type(status.value) == 'table' then status = status.value end
	return OPX.Math.Finite(status.hour)
end

local function loaded(player)
	local api = character()
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, value = pcall(api.GetPlayer, player)
	if not read or type(value) ~= 'table' or type(value.PlayerData) ~= 'table' then return nil end
	return value.PlayerData
end

local function citizenOf(player)
	local data = loaded(player)
	return data and type(data.citizenId) == 'string' and data.citizenId or nil
end

-- Whether one player may drive for a company at a grade, by the shared gate.
local function member(player, co, minGrade)
	local data = loaded(player)
	if data == nil then return false end
	local now = OPX.Now()
	return OPX.JobGate.Evaluate({ jobs = Model.Jobs(co, minGrade), onDuty = co.onDuty },
		{ job = data.job, jobs = data.jobs, atMs = now }, now,
		{ maxAgeMs = 0, membership = config().membership }) == true
end

-- The companies one player drives for, as a set, or nil.
local function companiesOf(player)
	local set, any = {}, false
	for _, key in ipairs(config().companyOrder) do
		local co = config().companies[key]
		if member(player, co, co.dispatch.minGrade) then set[key], any = true, true end
	end
	return any and set or nil
end

-- The first company of a set (in config order) that may take a call.
local function companyFor(set, call)
	for _, key in ipairs(config().companyOrder) do
		if set[key] and (call == nil or call.company == nil or call.company == key) then
			return config().companies[key]
		end
	end
	return nil
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function answer(player, ok, code, extra)
	local payload = type(extra) == 'table' and extra or {}
	payload.ok, payload.code = ok == true, code
	TriggerClientEvent(Event.ANSWER, player, payload)
	return ok
end

-- A line in a company's dispatcher voice: `taxi.voice.<voice>.<line>`.
local function voice(player, co, line, params, kind)
	local values = type(params) == 'table' and params or {}
	values.company = values.company or (co and co.label) or ''
	local family = co and co.voice or 'generic'
	OPX.NotifyLocale(player, ('taxi.voice.%s.%s'):format(family, line), values, kind or 'info')
end

local function cooled(player, kind)
	local slot = player .. ':' .. kind
	local now = OPX.Now()
	if lastRequest[slot] ~= nil and now - lastRequest[slot] < config().requestMs then return true end
	lastRequest[slot] = now
	return false
end

local function audit(event, player, ok, message)
	OPX.Audit.Log({ event = event, severity = ok and 'info' or 'warn', source = player, message = message })
end

local function money(amount, moneyType) return OPX.Locale.Money(amount, moneyType) end

-- ── the board ────────────────────────────────────────────────────────────────

-- What a driver is shown of one call. No name: the server does not hand a
-- stranger's name to anybody.
local function viewOf(call, viewer)
	local here = positionOf(viewer)
	local gap = here and call.position and Model.Distance(here, call.position)
	local co = call.company and config().companies[call.company] or nil
	return {
		id = call.id,
		company = call.company,
		short = co and co.short or nil,
		x = call.position and call.position.x, y = call.position and call.position.y,
		z = call.position and call.position.z,
		distance = gap and math.floor(gap) or nil,
		ageS = math.floor((OPX.Now() - call.openedMs) / 1000),
	}
end

local function alert(call)
	local told = 0
	for _, player in ipairs(playerIds()) do
		if player ~= call.passenger then
			local set = companiesOf(player)
			if set ~= nil and Dispatch.Visible(call, set) and rides[player] == nil then
				TriggerClientEvent(Event.ALERT, player, viewOf(call, player))
				told = told + 1
			end
		end
	end
	return told
end

local function announceClosed(call, why)
	for _, player in ipairs(playerIds()) do
		if companiesOf(player) ~= nil then TriggerClientEvent(Event.CLOSED, player, { id = call.id, why = why }) end
	end
	OPX.Publish(Event.ON_CALL, call.passenger, { state = 'closed', callId = call.id, why = why,
		citizenId = call.citizenId })
end

-- The street fares a driver may take now, one row per company.
local function streetRows(set)
	local rows = {}
	for _, key in ipairs(config().companyOrder) do
		local co = config().companies[key]
		if set[key] and co.npc.enabled and #co.npc.pickups > 0 and #co.npc.destinations > 0 then
			local idle = #Dispatch.List({ [key] = true }) == 0
			rows[#rows + 1] = { company = key, short = co.short, available = idle or not co.npc.onlyWhenIdle }
		end
	end
	return rows
end

local function rideView(ride)
	if ride == nil then return nil end
	return { kind = ride.kind, phase = ride.phase, company = ride.co.short,
		metres = math.floor(ride.metres), label = ride.destination and ride.destination.label
			or ride.pickup and ride.pickup.label or nil }
end

local function onBoard(player)
	local set = companiesOf(player)
	if set == nil then return answer(player, false, 'not_member') end
	local rows = {}
	for _, call in ipairs(Dispatch.List(set)) do
		if #rows >= 32 then break end
		rows[#rows + 1] = viewOf(call, player)
	end
	TriggerClientEvent(Event.BOARD_VIEW, player, { calls = rows, ride = rideView(rides[player]),
		street = streetRows(set), driving = drivenBy(player) ~= nil })
end

-- ── calling a cab ────────────────────────────────────────────────────────────

local function ttlFor(companyKey)
	if companyKey ~= nil then return config().companies[companyKey].dispatch.ttlMs end
	local longest = 0
	for _, key in ipairs(config().companyOrder) do
		longest = math.max(longest, config().companies[key].dispatch.ttlMs)
	end
	return longest
end

local function callCab(player, companyKey)
	if #config().companyOrder == 0 then return answer(player, false, 'no_company') end
	if companyKey ~= nil and config().companies[companyKey] == nil then
		return answer(player, false, 'no_such_company')
	end
	if riding[player] ~= nil then return answer(player, false, 'in_ride') end
	if Dispatch.Of(player) ~= nil then return answer(player, false, 'already_called') end
	local position = positionOf(player)
	if position == nil then return answer(player, false, 'unavailable') end
	local call = Dispatch.Open({ company = companyKey, passenger = player, citizenId = citizenOf(player),
		position = position, ttlMs = ttlFor(companyKey), nowMs = OPX.Now() })
	local told = alert(call)
	local co = companyKey and config().companies[companyKey] or config().companies[config().companyOrder[1]]
	OPX.Publish(Event.ON_CALL, player, { state = 'opened', callId = call.id, company = companyKey,
		citizenId = call.citizenId })
	voice(player, co, told > 0 and 'booked' or 'nobody', nil, told > 0 and 'info' or 'warning')
	return true
end

local function cancelCall(player)
	local call = Dispatch.Of(player)
	if call == nil then return answer(player, false, 'no_call') end
	Dispatch.Close(call.id)
	if call.driver ~= nil then
		local ride = rides[call.driver]
		if ride ~= nil and ride.callId == call.id then rides[call.driver] = nil end
		answer(call.driver, false, 'customer_cancelled')
	end
	announceClosed(call, 'cancelled')
	answer(player, true, 'cancelled')
end

-- ── rides ────────────────────────────────────────────────────────────────────

local function newRide(fields)
	nextRide = nextRide % 2147483646 + 1
	fields.id, fields.metres, fields.outSamples = nextRide, 0, 0
	return fields
end

local function dropRide(ride)
	if rides[ride.driver] == ride then rides[ride.driver] = nil end
	if ride.passenger ~= nil and riding[ride.passenger] == ride then riding[ride.passenger] = nil end
end

local function pushMeter(ride, state, fare)
	local co = ride.co
	local payload = { company = co.short, metres = math.floor(ride.metres), state = state,
		fare = fare or (Model.Fare(co, ride.metres, gameHour(), 0)), moneyType = co.fare.moneyType,
		kind = ride.kind }
	TriggerClientEvent(Event.METER, ride.driver, payload)
	if ride.passenger ~= nil then TriggerClientEvent(Event.METER, ride.passenger, payload) end
	ride.pushedMs = OPX.Now()
end

local function sample(ride)
	local at = positionOf(ride.driver)
	if at == nil then return nil end
	at.atMs = OPX.Now()
	return at
end

-- The meter starts: the customer sits in the vehicle the driver drives.
local function startMeter(ride, vehicleId)
	ride.phase, ride.vehicleId, ride.startedMs = Phase.RIDING, vehicleId, OPX.Now()
	ride.last, ride.metres, ride.outSamples = sample(ride), 0, 0
	if ride.passenger ~= nil then
		riding[ride.passenger] = ride
		voice(ride.passenger, ride.co, 'aboard', nil, 'info')
	end
	pushMeter(ride, 'running')
	OPX.Publish(Event.ON_RIDE, ride.passenger or ride.driver, { state = 'started', kind = ride.kind,
		company = ride.co.key, driver = citizenOf(ride.driver),
		citizenId = ride.passenger and citizenOf(ride.passenger) or nil })
end

-- Adds one clamped segment, while the driver still drives the ride's vehicle.
local function advance(ride)
	local at = sample(ride)
	if at == nil then return end
	if drivenBy(ride.driver) == ride.vehicleId then
		ride.metres = ride.metres + Model.Step(ride.last, at, config().maxSpeed)
	end
	ride.last = at
end

-- Bills a metered fare. Answers what was paid, and how.
local function bill(ride, fare)
	local co, driver, passenger = ride.co, ride.driver, ride.passenger
	local reason = ('taxi:%s:ride:%d'):format(co.key, ride.id)
	local accounts = OPX.Api.Get('accounts')
	local hasAccounts = accounts ~= nil and co.account ~= nil

	local invoices = OPX.Api.Get('invoices')
	if invoices ~= nil and type(invoices.Issue) == 'function' then
		local read, issued = pcall(invoices.Issue, {
			issuer = driver, target = passenger, amount = fare, reason = reason,
			account = hasAccounts and { kind = 'job', key = co.account } or nil,
			cutPct = co.driverCut, source = 'taxi',
		})
		if read and type(issued) == 'table' and issued.ok then
			audit('taxi.fare', driver, true, ('%s ride %d: invoiced %d to %d'):format(co.key, ride.id, fare, passenger))
			return 'invoiced'
		end
		Open77.log.warn(('[taxi] invoice refused (%s): charging directly'):format(tostring(read
			and type(issued) == 'table' and issued.error or issued)))
	else
		note('invoices', 'no invoices contract: fares are charged directly through character money')
	end

	local api = character()
	if api == nil or type(api.RemoveMoney) ~= 'function' then return 'unpaid' end
	local read, took = pcall(api.RemoveMoney, passenger, co.fare.moneyType, fare, reason)
	if not read or took ~= true then
		audit('taxi.fare', driver, false, ('%s ride %d: %d could not pay %d'):format(co.key, ride.id, passenger, fare))
		return 'unpaid'
	end
	local driverShare, companyShare = Model.Split(fare, co.driverCut)
	if not hasAccounts then
		if accounts == nil then note('accounts', 'no accounts contract: drivers keep the whole fare') end
		driverShare, companyShare = fare, 0
	elseif companyShare > 0 then
		local ok, deposited = pcall(accounts.Deposit, 'job', co.account, companyShare, reason, reason)
		if not ok or type(deposited) ~= 'table' or not deposited.ok then
			-- The money left the customer; it must land somewhere.
			driverShare, companyShare = fare, 0
		end
	end
	if driverShare > 0 and type(api.AddMoney) == 'function' then
		pcall(api.AddMoney, driver, co.fare.moneyType, driverShare, reason .. ':driver')
	end
	audit('taxi.fare', driver, true, ('%s ride %d: %d paid %d (driver %d, company %d)'):format(co.key,
		ride.id, passenger, fare, driverShare, companyShare))
	return 'paid', driverShare
end

-- Ends a metered ride (call or hail): the fare, the bill, the screens.
local function endRide(ride, why)
	if ride.done then return end
	ride.done = true
	dropRide(ride)
	local co = ride.co
	local fare, surged = Model.Fare(co, ride.metres, gameHour(), config().minRideM)
	pushMeter(ride, 'ended', fare)
	local how, earned = 'free', 0
	if fare > 0 and ride.passenger ~= nil then how, earned = bill(ride, fare) end
	local amount = money(fare, co.fare.moneyType)
	local km = ('%.1f'):format(ride.metres / 1000)
	if how == 'paid' then
		answer(ride.driver, true, 'fare_paid', { amount = money(earned or 0, co.fare.moneyType), km = km })
		voice(ride.passenger, co, surged and 'thanksNight' or 'thanks', { amount = amount, km = km }, 'success')
	elseif how == 'invoiced' then
		answer(ride.driver, true, 'fare_invoiced', { amount = amount, km = km })
		voice(ride.passenger, co, 'invoice', { amount = amount, km = km }, 'info')
	elseif how == 'unpaid' then
		answer(ride.driver, false, 'fare_unpaid', { amount = amount })
		if ride.passenger ~= nil then voice(ride.passenger, co, 'unpaid', { amount = amount }, 'warning') end
	else
		answer(ride.driver, true, 'fare_free', { km = km })
	end
	OPX.Publish(Event.ON_RIDE, ride.passenger or ride.driver, { state = 'ended', kind = ride.kind,
		company = co.key, metres = math.floor(ride.metres), fare = fare, surged = surged, how = how, why = why,
		driver = citizenOf(ride.driver), citizenId = ride.passenger and citizenOf(ride.passenger) or nil })
end

-- A street fare paid by the company: minted, capped per driver per hour.
local function payStreet(ride)
	local co, npc = ride.co, ride.co.npc
	ride.done = true
	dropRide(ride)
	local straight = Model.Distance(ride.pickup, ride.destination) or 0
	local elapsed = OPX.Now() - (ride.startedMs or OPX.Now())
	-- A car cannot be at the drop-off sooner than the straight line allows, nor
	-- have covered much less road than the straight line.
	if ride.metres < straight * 0.8 or elapsed < straight / config().maxSpeed * 1000 then
		audit('taxi.street', ride.driver, false, ('%s: %.0f m metered for %.0f m straight in %d ms'):format(
			co.key, ride.metres, straight, elapsed))
		return answer(ride.driver, false, 'street_suspicious')
	end
	local citizen = citizenOf(ride.driver) or tostring(ride.driver)
	streetPaid[citizen] = streetPaid[citizen] or {}
	local room = Model.CapRemaining(streetPaid[citizen], OPX.Now(), npc.hourlyCap)
	local pay = math.min(Model.StreetPay(npc, straight), room)
	local api = character()
	if pay > 0 and api ~= nil and type(api.AddMoney) == 'function' then
		local read, ok = pcall(api.AddMoney, ride.driver, npc.moneyType, pay, ('taxi:%s:street'):format(co.key))
		if not read or ok ~= true then pay = 0 end
	else
		pay = 0
	end
	if pay > 0 then table.insert(streetPaid[citizen], { atMs = OPX.Now(), amount = pay }) end
	audit('taxi.street', ride.driver, true, ('%s: %s -> %s, %.0f m, paid %d'):format(co.key,
		ride.pickup.label, ride.destination.label, straight, pay))
	OPX.Publish(Event.ON_RIDE, ride.driver, { state = 'ended', kind = Kind.STREET, company = co.key,
		metres = math.floor(ride.metres), fare = pay, how = 'minted', driver = citizen })
	TriggerClientEvent(Event.METER, ride.driver, { company = co.short, metres = math.floor(ride.metres),
		state = 'ended', fare = pay, moneyType = npc.moneyType, kind = Kind.STREET })
	if pay > 0 then
		voice(ride.driver, co, 'streetPaid', { amount = money(pay, npc.moneyType) }, 'success')
	else
		answer(ride.driver, false, 'street_capped')
	end
end

local function abandonStreet(ride, code)
	ride.done = true
	dropRide(ride)
	answer(ride.driver, false, code)
end

-- ── driver requests ──────────────────────────────────────────────────────────

local function waypoint(player, at)
	if at ~= nil then TriggerClientEvent(Event.WAYPOINT, player, { x = at.x, y = at.y, z = at.z }) end
end

local function onTake(player, payload)
	local set = companiesOf(player)
	if set == nil then return answer(player, false, 'not_member') end
	if rides[player] ~= nil then return answer(player, false, 'busy') end
	local call = Dispatch.Get(type(payload) == 'table' and payload.callId)
	if call == nil or call.passenger == player then return answer(player, false, 'no_such_call') end
	local co = companyFor(set, call)
	if co == nil then return answer(player, false, 'wrong_company') end
	local taken, why = Dispatch.Take(call.id, player, co.key)
	if taken == nil then return answer(player, false, why) end
	rides[player] = newRide({ kind = Kind.CALL, phase = Phase.ENROUTE, driver = player,
		passenger = call.passenger, callId = call.id, co = co })
	local at = positionOf(call.passenger) or call.position
	waypoint(player, at)
	-- The customer is told the car and how long: the record the driver sits in
	-- now, and the straight line at the ETA speed.
	local here = positionOf(player)
	local gap = here and at and Model.Distance(here, at) or nil
	local minutes = gap and math.max(1, math.ceil(gap / config().etaSpeed / 60)) or nil
	local record = recordOf(drivenBy(player))
	local vehicle = record and record:gsub('^Vehicle%.', '') or nil
	voice(call.passenger, co, 'enRoute', {
		vehicle = vehicle or locale('taxi.vehicle.unknown'),
		minutes = minutes and tostring(minutes) or '?',
	}, 'success')
	for _, other in ipairs(playerIds()) do
		if other ~= player and companiesOf(other) ~= nil then
			TriggerClientEvent(Event.CLOSED, other, { id = call.id, why = 'taken' })
		end
	end
	OPX.Publish(Event.ON_CALL, call.passenger, { state = 'taken', callId = call.id, company = co.key,
		driver = citizenOf(player), citizenId = call.citizenId })
	audit('taxi.take', player, true, ('%s call %d'):format(co.key, call.id))
	answer(player, true, 'taken', { company = co.short })
end

local function onDrop(player)
	local ride = rides[player]
	if ride == nil then return answer(player, false, 'no_ride') end
	if ride.phase == Phase.RIDING and ride.kind ~= Kind.STREET then
		return answer(player, false, 'meter_running')
	end
	dropRide(ride)
	ride.done = true
	if ride.kind == Kind.CALL then
		local call = Dispatch.Release(ride.callId, player, OPX.Now(), ride.co.dispatch.ttlMs)
		if call ~= nil then
			alert(call)
			voice(call.passenger, ride.co, 'reassigned', nil, 'warning')
		end
	end
	answer(player, true, 'dropped')
end

local function onStreet(player, payload)
	local co = type(payload) == 'table' and config().companies[payload.company] or nil
	if co == nil or not member(player, co, co.dispatch.minGrade) then return answer(player, false, 'not_member') end
	if not co.npc.enabled then return answer(player, false, 'no_street') end
	if rides[player] ~= nil then return answer(player, false, 'busy') end
	if co.npc.onlyWhenIdle and #Dispatch.List({ [co.key] = true }) > 0 then
		return answer(player, false, 'calls_waiting')
	end
	local citizen = citizenOf(player) or tostring(player)
	streetPaid[citizen] = streetPaid[citizen] or {}
	if Model.CapRemaining(streetPaid[citizen], OPX.Now(), co.npc.hourlyCap) <= 0 then
		return answer(player, false, 'street_capped')
	end
	local pickup, destination = Model.PickTrip(co.npc, math.random)
	if pickup == nil then return answer(player, false, 'no_street') end
	rides[player] = newRide({ kind = Kind.STREET, phase = Phase.ENROUTE, driver = player, co = co,
		pickup = pickup, destination = destination, expiresMs = OPX.Now() + co.npc.ttlMs })
	waypoint(player, pickup)
	voice(player, co, 'streetOffer', { pickup = pickup.label, destination = destination.label }, 'info')
	answer(player, true, 'street_taken', { pickup = pickup.label })
end

-- Starts the meter for whoever sits in the driver's cab: a fare hailed on the street.
local function onHail(player)
	local set = companiesOf(player)
	if set == nil then return answer(player, false, 'not_member') end
	if rides[player] ~= nil then return answer(player, false, 'busy') end
	local vehicleId = drivenBy(player)
	if vehicleId == nil then return answer(player, false, 'not_driving') end
	local co = companyFor(set, nil)
	if not allowedVehicle(co, vehicleId) then return answer(player, false, 'wrong_vehicle') end
	local passenger
	for _, other in ipairs(playerIds()) do
		if other ~= player and riding[other] == nil then
			local seat = seatOf(other)
			if seat ~= nil and seat.vehicleId == vehicleId and seat.seat ~= DRIVER_SEAT then
				passenger = other
				break
			end
		end
	end
	if passenger == nil then return answer(player, false, 'no_passenger') end
	-- A customer who had a call open is now in a cab: the call is done.
	local call = Dispatch.Of(passenger)
	if call ~= nil and call.driver == nil then
		Dispatch.Close(call.id)
		announceClosed(call, 'boarded')
	end
	local ride = newRide({ kind = Kind.HAIL, phase = Phase.ENROUTE, driver = player, passenger = passenger, co = co })
	rides[player] = ride
	startMeter(ride, vehicleId)
	answer(player, true, 'meter_started')
end

local function onStop(player)
	local ride = riding[player] or rides[player]
	if ride == nil or ride.phase ~= Phase.RIDING then return answer(player, false, 'no_ride') end
	if ride.kind == Kind.STREET then return abandonStreet(ride, 'street_abandoned') end
	endRide(ride, ride.passenger == player and 'customer' or 'driver')
end

-- ── the sweep ────────────────────────────────────────────────────────────────

local function sweepRide(ride, now)
	local co = ride.co
	if ride.kind == Kind.CALL and ride.phase == Phase.ENROUTE then
		if not member(ride.driver, co, co.dispatch.minGrade) then
			dropRide(ride)
			ride.done = true
			local call = Dispatch.Release(ride.callId, ride.driver, now, co.dispatch.ttlMs)
			if call ~= nil then alert(call) end
			return answer(ride.driver, false, 'off_duty')
		end
		local vehicleId = drivenBy(ride.driver)
		local seat = vehicleId and seatOf(ride.passenger) or nil
		if seat ~= nil and seat.vehicleId == vehicleId and allowedVehicle(co, vehicleId) then
			local call = Dispatch.Close(ride.callId)
			if call ~= nil then announceClosed(call, 'boarded') end
			startMeter(ride, vehicleId)
		end
		return
	end

	if ride.kind == Kind.STREET then
		if now >= ride.expiresMs then return abandonStreet(ride, 'street_expired') end
		local vehicleId = drivenBy(ride.driver)
		if ride.phase == Phase.ENROUTE then
			local at = positionOf(ride.driver)
			if vehicleId ~= nil and at ~= nil and allowedVehicle(co, vehicleId)
				and (Model.Distance(at, ride.pickup) or math.huge) <= co.npc.radius then
				ride.phase, ride.vehicleId, ride.startedMs = Phase.RIDING, vehicleId, now
				ride.last, ride.metres = sample(ride), 0
				waypoint(ride.driver, ride.destination)
				voice(ride.driver, co, 'streetAboard', { destination = ride.destination.label }, 'info')
			end
			return
		end
		if vehicleId ~= ride.vehicleId then
			ride.outSamples = ride.outSamples + 1
			if ride.outSamples >= config().exitSamples then return abandonStreet(ride, 'street_abandoned') end
			return
		end
		ride.outSamples = 0
		advance(ride)
		if (Model.Distance(ride.last, ride.destination) or math.huge) <= co.npc.radius then payStreet(ride) end
		return
	end

	-- A metered ride, call or hail.
	if ride.phase ~= Phase.RIDING then return end
	local seat = seatOf(ride.passenger)
	if seat == nil or seat.vehicleId ~= ride.vehicleId then
		ride.outSamples = ride.outSamples + 1
		if ride.outSamples >= config().exitSamples then return endRide(ride, 'exited') end
		return
	end
	ride.outSamples = 0
	advance(ride)
	if config().meterPushMs > 0 and now - (ride.pushedMs or 0) >= config().meterPushMs then
		pushMeter(ride, 'running')
	end
end

local function sweep()
	local now = OPX.Now()
	for _, call in ipairs(Dispatch.Expire(now)) do
		announceClosed(call, 'expired')
		local co = call.company and config().companies[call.company] or config().companies[config().companyOrder[1]]
		voice(call.passenger, co, 'expired', nil, 'warning')
	end
	local list = {}
	for _, ride in pairs(rides) do list[#list + 1] = ride end
	table.sort(list, function(a, b) return a.id < b.id end)
	for _, ride in ipairs(list) do
		if not ride.done then sweepRide(ride, now) end
	end
end

local function departed(rawPlayer)
	local player = math.tointeger(tonumber(rawPlayer))
	if player == nil then return end
	-- A customer with a call: the call goes, the driver on it is told.
	local call = Dispatch.Of(player)
	if call ~= nil then
		Dispatch.Close(call.id)
		if call.driver ~= nil then
			local ride = rides[call.driver]
			if ride ~= nil and ride.callId == call.id then
				ride.done = true
				dropRide(ride)
			end
			answer(call.driver, false, 'customer_left')
		end
		announceClosed(call, 'left')
	end
	-- A customer in a running ride: the ride ends where they left it.
	if riding[player] ~= nil then endRide(riding[player], 'left') end
	-- A driver: an en-route call goes back on the board, a running meter stops
	-- without a bill (nobody to pay it to), a street fare is dropped.
	local ride = rides[player]
	if ride ~= nil then
		ride.done = true
		dropRide(ride)
		if ride.kind == Kind.CALL and ride.phase == Phase.ENROUTE then
			local back = Dispatch.Release(ride.callId, player, OPX.Now(), ride.co.dispatch.ttlMs)
			if back ~= nil then
				alert(back)
				voice(back.passenger, ride.co, 'reassigned', nil, 'warning')
			end
		elseif ride.passenger ~= nil then
			voice(ride.passenger, ride.co, 'driverLeft', nil, 'warning')
		end
	end
	local prefix = tostring(player) .. ':'
	for slot in pairs(lastRequest) do
		if slot:sub(1, #prefix) == prefix then lastRequest[slot] = nil end
	end
end

-- ── commands ─────────────────────────────────────────────────────────────────

local function onCallCommand(source, args)
	local player = math.tointeger(tonumber(source))
	if player == nil or player <= 0 then return print('[taxi] a cab is called by a player, not the console') end
	local word = type(args) == 'table' and type(args[1]) == 'string' and args[1]:lower() or nil
	CreateThread(function()
		if word == 'cancel' then return cancelCall(player) end
		if word == 'stop' then return onStop(player) end
		callCab(player, word)
	end)
end

local function onBoardCommand(source)
	local player = math.tointeger(tonumber(source))
	if player == nil or player <= 0 then return end
	CreateThread(function() onBoard(player) end)
end

-- ── the contract ─────────────────────────────────────────────────────────────

local function contractCalls(company)
	local rows = {}
	for _, call in ipairs(Dispatch.List(company and { [company] = true } or nil, true)) do
		rows[#rows + 1] = { id = call.id, company = call.company, passenger = call.passenger,
			taken = call.driver ~= nil }
	end
	return Result.Ok(rows)
end

local function contractRide(player)
	local id = math.tointeger(tonumber(player))
	local ride = id and (rides[id] or riding[id]) or nil
	if ride == nil then return Result.Ok(nil) end
	return Result.Ok({ kind = ride.kind, phase = ride.phase, company = ride.co.key, driver = ride.driver,
		passenger = ride.passenger, metres = math.floor(ride.metres) })
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the state.
-- @author dop42
function M.Init()
	settings = nil
	rides, riding, streetPaid, lastRequest, said, nextRide = {}, {}, {}, {}, {}, 0
	Dispatch.Reset()
end

--- Publishes the server contract: `taxi` v1, read-only.
-- @author dop42
function M.Api()
	OPX.Api.Provide('taxi', 1, {
		Calls = contractCalls,
		Ride = contractRide,
		Companies = function() return Result.Ok(OPX.Table.DeepCopy(config().companyOrder)) end,
	})
end

--- Wires the requests, the commands and the sweep.
-- @author dop42
function M.Start()
	for _, line in ipairs(Model.Problems(OPX.Config.MODULES.taxi)) do
		Open77.log.warn('[taxi] config: ' .. line)
	end

	local function wire(name, kind, handler)
		RegisterNetEvent(name, function(payload)
			local player = math.tointeger(tonumber(source))
			if player == nil or player <= 0 then return end
			if cooled(player, kind) then return answer(player, false, 'rate_limited') end
			-- On a thread: the account and the bag may yield.
			CreateThread(function() handler(player, payload) end)
		end)
	end
	wire(Event.BOARD, 'board', onBoard)
	wire(Event.TAKE, 'take', onTake)
	wire(Event.DROP, 'drop', onDrop)
	wire(Event.STREET, 'street', onStreet)
	wire(Event.HAIL, 'hail', onHail)
	wire(Event.STOP, 'stop', onStop)

	local commands = config().commands
	if commands.call then
		OPX.Command.Register(commands.call, { help = 'taxi.help.call', cooldownMs = 2000, params = {
			{ name = 'company|cancel|stop', optional = true, help = locale('taxi.help.callArg') },
		} }, onCallCommand)
	end
	if commands.board then
		OPX.Command.Register(commands.board, { help = 'taxi.help.board', cooldownMs = 750 }, onBoardCommand)
	end

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)
	OPX.Scheduler.Every('taxi:sweep', config().scanMs, sweep)

	if OPX.Api.Get('invoices') == nil then
		note('invoices', 'no invoices contract: fares are charged directly through character money')
	end
	if OPX.Api.Get('accounts') == nil then
		note('accounts', 'no accounts contract: drivers keep the whole fare')
	end
	Open77.log.info(('[taxi] %d compan%s: %s'):format(#config().companyOrder,
		#config().companyOrder == 1 and 'y' or 'ies', table.concat(config().companyOrder, ', ')))
end

--- Every ride stops, unbilled.
-- @author dop42
function M.Stop()
	rides, riding = {}, {}
end

-- Exposed for the tests: the handlers, by name.
M.Server = {
	CallCab = callCab, Cancel = cancelCall, OnBoard = onBoard, OnTake = onTake, OnDrop = onDrop,
	OnStreet = onStreet, OnHail = onHail, OnStop = onStop, Sweep = sweep, Departed = departed,
	Rides = function() return rides, riding end,
}
