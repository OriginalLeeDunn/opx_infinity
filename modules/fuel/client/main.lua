--- Client half: the pumps, the key, the eye rows, the menu and the gauge read.
-- @author dop42
--
-- OX'S `client/stations.lua`, `client/target.lua` AND THE ASKING HALF OF
-- `client/fuel.lua`, ON THIS CLIENT. ox walks its stations with `lib.points`,
-- draws `Press E to fuel` within 3 m of a pump, and on E either fuels the last
-- vehicle (within 3 m) or sells a petrol can; ox_target puts the same two
-- choices on the pump models and a third on every vehicle for a held can. All
-- of that is here, and NONE OF IT DECIDES: the key, the strip row and the eye
-- rows open a menu, the menu sends what the player chose and how they pay, and
-- the server measures the pump, the car, the tank and the money itself.
--
-- THE GAUGE IS A READ. The tank is `fuel` on the vehicle's replicated state
-- bag; `Level` and `Percent` read it and nothing here ever writes it -- a client
-- cannot (`requires_server_arbitration`), which is the point.
--
-- THE CLIENT BUDGET. The scan measures a SLICE of the pumps per pass and keeps
-- the near ones (doorlock's sweep); the nearest-pump question walks only those.
-- One position read, one seat read, and one vehicle read only when a pump is in
-- reach.

local M = OPX.Modules.Get('fuel')
local Model = M.Model

M.Runtime = {}
local Runtime = M.Runtime

local OWNER = 'fuel'
local GROUP = 'pump'
local MENU_ID = 'fuel.pump'

-- Pumps measured per scan pass, and how near a pump must be to stay in `near`.
local SWEEP_SLICE = 32
local NEAR_RADIUS = 30.0

-- Pump spheres per eye row: see `registerRows`.
local SPHERES_PER_ROW = 4

local settings = nil
-- key -> station (open ones only), and every pump flattened: { station, x, y, z }.
local stations, pumps = {}, {}
-- Pump index -> pump, for the ones within NEAR_RADIUS; and the sweep cursor.
local near, cursor = {}, 0
-- The pump the player stands at, and its distance; the row drawn for it.
local nearest, nearestDistance, shown = nil, nil, nil
local keyRegistered, scanJob, reportedStrip = false, nil, false
local menuHandle = nil

local function config()
	if settings == nil then settings = Model.Settings(M.Settings) end
	return settings
end

local function keySettings()
	local declared = type(M.Settings.KEY) == 'table' and M.Settings.KEY or nil
	return declared or { ID = 'opx.fuel.use', NAME = 'fuel.key.use', DEFAULT = 'E' }
end

-- ── reading the world ───────────────────────────────────────────────────────

local function position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil end
	if type(z) ~= 'number' or z ~= z then z = 0.0 end
	return x, y, z
end

--- The vehicle the local player sits in, or nil.
-- @author dop42
-- @return any|nil vehicle id
function Runtime.Seat()
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return nil end
	local read, seat = pcall(vehicles.getPlayerSeat)
	if not read or type(seat) ~= 'table' then return nil end
	return seat.vehicleId
end

--- Whether a vehicle stands within the pump's reach of the player. A hint for
--- which rows to draw; the server picks the car itself.
local function vehicleNear()
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.closest) ~= 'function' then return true end
	local read, found = pcall(vehicles.closest, config().vehicleReach)
	if not read then return true end
	return type(found) == 'table'
end

--- Whether the local bag holds a can, as the inventory last told this client.
local function holdsCan()
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return false end
	local read, count = pcall(inventory.GetItemCount, config().can.item)
	return read and (tonumber(count) or 0) > 0
end

-- ── the tank, read ──────────────────────────────────────────────────────────

--- The litres in a vehicle's tank and its capacity, from its bag, or nil.
-- @author dop42
-- @param vehicleId any
-- @return number|nil litres
-- @return number capacity
function Runtime.Level(vehicleId)
	local capacity = config().capacity
	local state = Open77.state
	if vehicleId == nil or type(state) ~= 'table' or type(state.entity) ~= 'function' then
		return nil, capacity
	end
	local read, litres, size = pcall(function()
		local bag = state.entity('vehicle', vehicleId)
		return bag[M.KEY], bag[M.CAPACITY_KEY]
	end)
	if not read then return nil, capacity end
	size = OPX.Math.Finite(size)
	if size ~= nil and size > 0 then capacity = size end
	return OPX.Math.Finite(litres), capacity
end

--- ox's `state.fuel`: a vehicle's tank in percent, or nil when nobody filled it.
-- @author dop42
-- @param vehicleId any
-- @return number|nil
function Runtime.Percent(vehicleId)
	local litres, capacity = Runtime.Level(vehicleId)
	if litres == nil then return nil end
	return Model.Percent(litres, capacity)
end

-- ── the stations ────────────────────────────────────────────────────────────

--- The open stations as the blips module reads them: key -> { label, x, y, z }.
-- @author dop42
-- @return table
function Runtime.Stations()
	local out = {}
	for key, station in pairs(stations) do
		out[key] = { key = key, label = station.label, x = station.x, y = station.y, z = station.z }
	end
	return out
end

-- Measures the next slice of pumps and keeps the near ones.
local function sweep(x, y, z)
	local count = #pumps
	if count == 0 then return end
	local limit = NEAR_RADIUS * NEAR_RADIUS
	for _ = 1, math.min(SWEEP_SLICE, count) do
		cursor = cursor % count + 1
		local pump = pumps[cursor]
		local dx, dy, dz = x - pump.x, y - pump.y, z - pump.z
		near[cursor] = dx * dx + dy * dy + dz * dz <= limit and pump or nil
	end
end

-- The nearest pump within reach, and its distance.
local function findNearest()
	local x, y, z = position()
	if x == nil then return nil end
	local reach = config().useRadius
	local best, bestDistance = nil, reach * reach
	for _, pump in pairs(near) do
		local dx, dy, dz = x - pump.x, y - pump.y, z - pump.z
		local distance = dx * dx + dy * dy + dz * dz
		if distance <= bestDistance then best, bestDistance = pump, distance end
	end
	return best, best ~= nil and math.sqrt(bestDistance) or nil
end

-- ── the menu ────────────────────────────────────────────────────────────────

-- The two ways to pay, as menu rows under one action.
local function payRows(verb, extra)
	local rows = {}
	local accepted = type(M.Settings.PAYMENT) == 'table' and M.Settings.PAYMENT or { 'EDDIES', 'BANK' }
	for index = 1, #accepted do
		local method = accepted[index]
		local data = { verb = verb, method = method }
		for key, value in pairs(extra or {}) do data[key] = value end
		rows[#rows + 1] = { id = verb .. '.' .. method, label = locale('fuel.method.' .. method),
			icon = 'money', data = data, close = true }
	end
	return rows
end

--- Opens the pump's menu: refuel the vehicle beside it, buy a can, refill one
--- -- each with cash or bank, ox's two payment methods made a choice.
-- @author dop42
-- @return boolean whether a menu opened
function Runtime.OpenPump()
	local pump = nearest or findNearest()
	if pump == nil then return false end
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		OPX.Toast.Locale('fuel.error.no_menu', nil, 'error')
		return false
	end
	local can = config().can
	local items = {
		{ id = 'refuel', label = locale('fuel.menu.refuel'), icon = 'vehicle',
			value = locale('fuel.menu.perLitre', { price = OPX.Locale.Money(pump.station.price) }),
			items = payRows('refuel') },
	}
	if can.enabled then
		items[#items + 1] = { id = 'can.buy', label = locale('fuel.menu.canBuy'), icon = 'box',
			value = OPX.Locale.Money(can.price), items = payRows('can', { refill = false }) }
		if holdsCan() then
			items[#items + 1] = { id = 'can.refill', label = locale('fuel.menu.canRefill'), icon = 'box',
				value = OPX.Locale.Money(can.refillPrice), items = payRows('can', { refill = true }) }
		end
	end
	local opened = menu.Open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = pump.station.label,
		items = items,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) ~= 'table' then return end
			if data.verb == 'refuel' then
				TriggerServerEvent(M.Event.REFUEL, { method = data.method })
			elseif data.verb == 'can' then
				TriggerServerEvent(M.Event.CAN_BUY, { method = data.method, refill = data.refill == true })
			end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('fuel', ('the pump menu was refused: %s')
			:format(tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

--- What the key does: the pump menu at a pump, nothing anywhere else -- E is
--- shared with every spot module and the doors.
-- @author dop42
-- @return boolean
function Runtime.Use()
	if Runtime.Seat() ~= nil then return false end
	if findNearest() == nil then return false end
	return Runtime.OpenPump()
end

-- ── the strip ───────────────────────────────────────────────────────────────

-- ox's `DisplayHelpTextThisFrame`: one row at a pump, saying what E will do.
local function syncPrompt()
	local wins = OPX.Spots.Key.Shows(keySettings().ID)
	local text = nil
	if keyRegistered and nearest ~= nil and wins and not OPX.Spots.Captured() then
		if Runtime.Seat() ~= nil then
			text = locale('fuel.prompt.leave')
		elseif vehicleNear() then
			text = locale('fuel.prompt.pump', { price = OPX.Locale.Money(nearest.station.price) })
		elseif config().can.enabled then
			text = locale('fuel.prompt.can')
		end
	end
	if text == shown then return end
	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		shown = nil
		return
	end
	local ran, answer
	if text ~= nil then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID }, label = text,
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	shown = text
	if (not ran or type(answer) ~= 'table' or answer.ok ~= true) and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[fuel] the strip row was refused: ' ..
			tostring(ran and type(answer) == 'table' and answer.error or answer))
	end
end

-- One pass: the near pumps, the nearest, its row.
local function scan()
	local x, y, z = position()
	if x ~= nil then sweep(x, y, z) end
	nearest, nearestDistance = findNearest()
	syncPrompt()
end

--- One scan pass, as the scheduler runs it: for a test that counts its cost.
-- @author dop42
Runtime.Scan = scan

-- ── the eye ─────────────────────────────────────────────────────────────────

-- The vehicle the eye landed on, as the decimal string the wire carries: an id
-- carries a generation and can pass 2^53, where a JSON number stops being exact.
local function vehicleOf(context)
	local hit = type(context) == 'table' and context.target or nil
	local id = type(hit) == 'table' and math.tointeger(hit.vehicleId) or nil
	if id == nil or id < 1 then return nil end
	return id
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('fuel', 'no target contract: no pump or can rows on the eye; the key still works')
		return
	end
	-- ox_target's `addModel(pumpModels)`: a Night City pump is part of the map
	-- with no entity to aim at, so the row is a sphere round its position. FOUR
	-- SPHERES A ROW, one row a resume: a registration costs the eye some three
	-- thousand instructions before it looks at a sphere, and 32 in one measured
	-- 14,800 on the budget meter; four keep a row near 4,000. Every pump gets
	-- one, however many stations there are.
	local radius = config().useRadius
	for first = 1, #pumps, SPHERES_PER_ROW do
		local spheres = {}
		for index = first, math.min(#pumps, first + SPHERES_PER_ROW - 1) do
			local pump = pumps[index]
			spheres[#spheres + 1] = { x = pump.x, y = pump.y, z = pump.z, radius = radius }
		end
		local placed = target.RegisterSpheres(OWNER, spheres, {
			id = ('fuel.pump.%d'):format((first - 1) // SPHERES_PER_ROW + 1),
			label = locale('fuel.row.pump'),
			icon = 'vehicle',
			distance = radius,
			order = 20,
			canInteract = function() return Runtime.Seat() == nil end,
			onSelect = function() return Runtime.OpenPump() end,
		})
		if type(placed) ~= 'table' or not placed.ok then
			OPX.Note('fuel', ('the pump rows were refused: %s')
				:format(tostring(type(placed) == 'table' and placed.error or placed)))
			break
		end
		Wait(0)
	end
	if not config().can.enabled then return end
	-- ox_target's `addGlobalVehicle` for a held can.
	local rows = target.RegisterVehicles(OWNER, { {
		id = 'fuel.can',
		label = locale('fuel.row.can'),
		icon = 'box',
		distance = config().can.reach,
		order = 23,
		canInteract = function(context)
			return vehicleOf(context) ~= nil and Runtime.Seat() == nil and holdsCan()
		end,
		onSelect = function(context)
			local id = vehicleOf(context)
			if id == nil then return false end
			TriggerServerEvent(M.Event.CAN_POUR, { vehicleId = ('%d'):format(id) })
			return true
		end,
	} })
	if type(rows) ~= 'table' or not rows.ok then
		OPX.Note('fuel', ('the can row was refused: %s')
			:format(tostring(type(rows) == 'table' and rows.error or rows)))
	end
end

-- ── the answers ─────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	local key = (ok and 'fuel.answer.' or 'fuel.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'fuel.answer.done' or 'fuel.error.invalid' end
	local cost = math.tointeger(payload.cost) or 0
	local params = {
		litres = OPX.Math.Finite(payload.litres) or 0,
		percent = math.tointeger(payload.percent) or 0,
		cost = OPX.Locale.Money(cost),
		price = OPX.Locale.Money(OPX.Math.Finite(payload.price) or 0),
		method = type(payload.method) == 'string' and locale('fuel.method.' .. payload.method) or '',
		station = type(payload.station) == 'string' and payload.station or '',
	}
	-- A pour started says nothing: the bar is already saying it.
	if ok and (payload.code == 'refuelling' or payload.code == 'pouring') then return end
	OPX.Toast.Show({
		id = 'opx.fuel.answer',
		kind = ok and 'success' or OPX.Result.Kind(payload.code, 'error'),
		title = locale('fuel.title'),
		message = locale(key, params),
		icon = 'vehicle',
		durationMs = 4000,
	})
end

-- ── the phases ──────────────────────────────────────────────────────────────

-- Builds the station list from the shared config. Its own resume: the config
-- is normalised and every station coerced, which is a thousand-odd instructions
-- the boot's shared resume has no room for.
--
-- ONE STATION A RESUME. A station is up to MAX_PUMPS coordinates, each coerced
-- and checked for the placeholder, and six full stations in one go measured
-- 16,800 instructions on the budget meter -- a resume the platform kills without
-- a word, leaving no pump, no key and no row. So each station is coerced on its
-- own, through the same `Model.Stations` the server runs, and the thread yields
-- between two.
local function build()
	settings = nil
	local normalised = config()
	Wait(0)
	local declared = type(M.Settings.STATIONS) == 'table' and M.Settings.STATIONS or {}
	local keys = {}
	for key in pairs(declared) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local built, flat = {}, {}
	for _, key in ipairs(keys) do
		local one = Model.Stations(normalised, { [key] = declared[key] })
		local station = one[key]
		if station ~= nil then
			built[key] = station
			for index = 1, #station.pumps do
				local pump = station.pumps[index]
				flat[#flat + 1] = { station = station, index = index, x = pump.x, y = pump.y, z = pump.z }
			end
		end
		Wait(0)
	end
	stations, pumps, near, cursor = built, flat, {}, 0
end

--- Resets the state. Never yields; the stations are built in `Start`.
-- @author dop42
function M.Init()
	settings = nil
	stations, pumps, near, cursor = {}, {}, {}, 0
	nearest, nearestDistance, shown = nil, nil, nil
	keyRegistered, scanJob, reportedStrip, menuHandle = false, nil, false, nil
end

--- Publishes the client half: the gauge reads, ox's `state.fuel` on this side.
-- @author dop42
function M.Api()
	OPX.Api.Provide('fuel', 1, {
		Level = Runtime.Level,
		Percent = Runtime.Percent,
		--- The tank of the vehicle the local player sits in, or nil.
		Current = function()
			local id = Runtime.Seat()
			if id == nil then return nil end
			local litres, capacity = Runtime.Level(id)
			if litres == nil then return nil end
			return { vehicleId = id, litres = litres, capacity = capacity,
				percent = Model.Percent(litres, capacity) }
		end,
		Stations = Runtime.Stations,
		OpenPump = Runtime.OpenPump,
	})
end

--- Declares the key, puts the rows on the eye and starts the scan, on a thread
--- of its own that yields between the three.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	CreateThread(function()
		build()
		Wait(0)
		if #pumps > 0 then
			keyRegistered = OPX.Spots.Key.Register({
				tag = 'fuel',
				declared = keySettings(),
				onPress = Runtime.Use,
				wants = function(x)
					local pump, distance = nearest, nearestDistance
					if x ~= nil then pump, distance = findNearest() end
					if pump == nil or Runtime.Seat() ~= nil then return nil end
					return OPX.Spots.Key.Rank('SPOT'), distance
				end,
			})
			scanJob = OPX.Scheduler.Every('fuel:scan',
				math.floor(Model.Bounded(M.Settings.SCAN_MS, 100, 5000, 500)), scan)
		end
		Wait(0)
		registerRows()
	end)
end

--- Cancels the scan and hands the strip and the menu back.
-- @author dop42
function M.Stop()
	if scanJob ~= nil then OPX.Scheduler.Cancel(scanJob) end
	scanJob = nil
	local api = OPX.Api.Get('prompts')
	if shown ~= nil and api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, GROUP) end
	shown = nil
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end
