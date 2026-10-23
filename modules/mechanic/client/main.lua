--- Client half: the eye rows, the board, the alerts, the lot menu and the answers.
-- @author dop42
--
-- NOTHING HERE DECIDES. The eye asks to repair, patch or tow the car under it,
-- a sphere asks for the parts room or the impound desk, the command asks for the
-- board, and every answer comes back from the server already judged. The only
-- thing this half knows on its own is whether to bother drawing a mechanic's
-- rows, read off the character's own job -- a hint for the eye, never a gate.
--
-- THE CLIENT BUDGET. Rows go on the eye on a thread with a yield between two
-- registrations (`modules/fuel/client/main.lua` measured why), and nothing here
-- runs on a tick: every surface opens on an event.

local M = OPX.Modules.Get('mechanic')
local Model = M.Model
local Event = M.Event

local OWNER = M.OWNER
local MENU_BOARD, MENU_LOT = 'mechanic.board', 'mechanic.lot'
local MENU_DIAGNOSTIC = 'mechanic.diagnostic'

local settings
-- callId -> blip id, for the calls this mechanic was alerted to.
local blips = {}
local menuHandle
local boardPending, boardWorking = nil, false
local boardGeneration, stopped = 0, false

local function config()
	if settings == nil then settings = Model.Settings(M.Settings) end
	return settings
end

-- ── who am I ─────────────────────────────────────────────────────────────────

local function jobData()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return nil end
	local read, job = pcall(api.GetJobData)
	if not read or type(job) ~= 'table' or type(job.name) ~= 'string' then return nil end
	return job
end

-- Whether the local character holds a job some shop lists. A hint only.
local function isMechanic()
	local job = jobData()
	if job == nil then return false end
	for _, key in ipairs(config().shopOrder) do
		local shop = config().shops[key]
		if type(shop.jobs) == 'table' and shop.jobs[job.name] ~= nil
			and (not shop.onDuty or job.onDuty == true) then
			return true
		end
	end
	return false
end

-- Whether the local character holds a job the tow lists. A hint only.
local function mayTow()
	local job = jobData()
	local jobs = config().impound.jobs
	return config().impound.enabled and job ~= nil and type(jobs) == 'table' and jobs[job.name] ~= nil
		and (not config().impound.onDuty or job.onDuty == true)
end

local function holdsKit()
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return false end
	local read, count = pcall(inventory.GetItemCount, config().kitItem.name)
	return read and (tonumber(count) or 0) > 0
end

local function seat()
	local vehicles = Open77.vehicles
	if type(vehicles) ~= 'table' or type(vehicles.getPlayerSeat) ~= 'function' then return nil end
	local read, taken = pcall(vehicles.getPlayerSeat)
	return read and type(taken) == 'table' and taken.vehicleId or nil
end

-- ── surfaces ─────────────────────────────────────────────────────────────────

local function toast(kind, message)
	OPX.Toast.Show({
		id = 'opx.mechanic.answer', kind = kind, title = locale('mechanic.title'),
		message = message, icon = 'tool', durationMs = 4500,
	})
end

local function openMenu(id, title, items, on, paced)
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		toast('error', locale('mechanic.error.no_menu'))
		return false
	end
	local opened = menu.Open({
		owner = OWNER, id = id, steal = true, focus = 'cursor', title = title, items = items,
		yield = paced == true,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) == 'table' then on(data) end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('mechanic', ('the %s menu was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	if stopped then
		if menuHandle ~= nil then pcall(menu.Close, menuHandle, 'owner_stopped') end
		menuHandle = nil
		return false
	end
	return true
end

local function money(amount, moneyType)
	return OPX.Locale.Money(math.tointeger(amount) or 0, moneyType)
end

-- ── the board ────────────────────────────────────────────────────────────────

local function callLabel(call)
	local parts = { locale('mechanic.kind.' .. tostring(call.kind)) }
	if call.distance then parts[#parts + 1] = ('%d m'):format(call.distance) end
	return table.concat(parts, ' · ')
end

local function buildBoard(payload, generation)
	local calls = type(payload) == 'table' and type(payload.calls) == 'table' and payload.calls or {}
	local items = {}
	for index, call in ipairs(calls) do
		local actions = {}
		if call.mine then
			actions[#actions + 1] = { id = 'route.' .. call.id, label = locale('mechanic.board.route'),
				icon = 'map', data = { verb = 'route', call = call }, close = true }
			actions[#actions + 1] = { id = 'close.' .. call.id, label = locale('mechanic.board.close'),
				icon = 'flag', data = { verb = 'close', id = call.id }, close = true }
			actions[#actions + 1] = { id = 'drop.' .. call.id, label = locale('mechanic.board.drop'),
				icon = 'minus', data = { verb = 'drop', id = call.id }, close = true }
		else
			actions[#actions + 1] = { id = 'take.' .. call.id, label = locale('mechanic.board.take'),
				icon = 'plus', data = { verb = 'take', id = call.id }, close = true,
				disabled = (call.responders or 0) >= (call.limit or 1) }
		end
		items[#items + 1] = {
			id = 'call.' .. call.id, label = callLabel(call), icon = call.mine and 'star' or 'vehicle',
			value = ('%d/%d · %s'):format(call.responders or 0, call.limit or 1,
				locale('mechanic.board.age', { minutes = math.floor((call.ageS or 0) / 60) })),
			description = type(call.note) == 'string' and call.note or nil,
			items = actions,
		}
		if index % 4 == 0 then
			Wait(0)
			if stopped or generation ~= boardGeneration then return end
		end
	end
	if #calls == 0 then
		items[#items + 1] = { id = 'empty', label = locale('mechanic.board.empty'), icon = 'info', disabled = true }
	end
	Wait(0)
	if stopped or generation ~= boardGeneration then return end
	openMenu(MENU_BOARD, locale('mechanic.board.title'), items, function(data)
		if data.verb == 'take' then
			TriggerServerEvent(Event.TAKE, { callId = data.id })
		elseif data.verb == 'drop' then
			TriggerServerEvent(Event.DROP, { callId = data.id })
		elseif data.verb == 'close' then
			TriggerServerEvent(Event.CLOSE, { callId = data.id })
		elseif data.verb == 'route' and type(data.call) == 'table' and data.call.x then
			pcall(Open77.blips.setWaypoint, { x = data.call.x, y = data.call.y, z = data.call.z })
		end
	end, true)
end

-- Full snapshots coalesce while one is being built. One worker preserves menu
-- ownership across the yields inside Open; overlapping replies never race two
-- builders against the same dispatch menu.
local function queueView(payload, builder)
	if stopped or type(payload) ~= 'table' then return end
	boardGeneration = boardGeneration + 1
	boardPending = { payload = payload, build = builder }
	if boardWorking then return end
	boardWorking = true
	CreateThread(function()
		while boardPending ~= nil and not stopped do
			local pending, generation = boardPending, boardGeneration
			boardPending = nil
			Wait(0)
			if not stopped and generation == boardGeneration then
				local ok, why = pcall(pending.build, pending.payload, generation)
				if not ok then OPX.Note('mechanic', 'the board could not be drawn: ' .. tostring(why)) end
			end
		end
		boardWorking = false
	end)
end



-- Fixed-size report: every value is a server reading, never a local health estimate.
local function buildDiagnostic(payload, generation)
	local items = {}
	local function value(field, label, percent)
		local number = math.tointeger(payload[field])
		items[#items + 1] = { id = field, label = locale('mechanic.diagnostic.' .. label),
			value = number ~= nil and (tostring(number) .. (percent and '%' or ''))
				or locale('mechanic.diagnostic.unknown'), disabled = true }
	end
	value('health', 'health', true)
	value('missing', 'missing', true)
	value('tires', 'tires')
	value('glass', 'glass')
	Wait(0)
	if stopped or generation ~= boardGeneration then return end
	value('lights', 'lights')
	value('detached', 'detached')
	value('doors', 'doors')
	value('windows', 'windows')
	local quote = type(payload.quote) == 'table' and payload.quote or {}
	items[#items + 1] = { id = 'quote', label = locale('mechanic.diagnostic.quote'),
		value = money(quote.fee or 0, payload.moneyType), disabled = true,
		description = locale('mechanic.diagnostic.parts', { count = math.tointeger(quote.parts) or 0,
			seconds = math.ceil((tonumber(quote.durationMs) or 0) / 1000) }) }
	items[#items + 1] = { id = 'bay', label = locale(payload.inBay == true
		and 'mechanic.diagnostic.in_bay' or 'mechanic.diagnostic.workshop'), disabled = true }
	Wait(0)
	if stopped or generation ~= boardGeneration then return end
	openMenu(MENU_DIAGNOSTIC, locale('mechanic.diagnostic.title'), items, function() end, true)
end

-- ── alerts and the map ───────────────────────────────────────────────────────

local function dropBlip(id)
	local blip = blips[id]
	blips[id] = nil
	if blip ~= nil and type(Open77.blips) == 'table' and type(Open77.blips.remove) == 'function' then
		pcall(Open77.blips.remove, blip)
	end
end

local function onAlert(call)
	if type(call) ~= 'table' or math.tointeger(call.id) == nil then return end
	OPX.Toast.Show({
		id = 'opx.mechanic.alert.' .. call.id, kind = 'warning', title = locale('mechanic.alert.title'),
		message = locale('mechanic.alert.body', { call = callLabel(call),
			note = type(call.note) == 'string' and call.note or '' }),
		icon = 'tool', durationMs = config().alertMs,
	})
	local native = Open77.blips
	if blips[call.id] == nil and call.x and type(native) == 'table' and type(native.create) == 'function' then
		local options = {
			position = { x = call.x, y = call.y, z = call.z },
			sprite = config().blipSprite,
			title = callLabel(call), description = locale('mechanic.alert.title'),
			active = true, visibleThroughWalls = config().blipWalls,
		}
		-- The icon and tint where the client has the native SVG adapter (its
		-- test: `setColor` exists); the sprite alone everywhere else, and again
		-- if this client refuses the icon. The medical pins' rule.
		if type(native.setColor) == 'function' then
			if config().blipIcon then options.icon = { asset = config().blipIcon, size = config().blipSize } end
			if config().blipColor then options.color = config().blipColor end
		end
		local read, id = pcall(native.create, options)
		if (not read or type(id) ~= 'string' or id == '') and (options.icon or options.color) then
			options.icon, options.color = nil, nil
			read, id = pcall(native.create, options)
		end
		if read and type(id) == 'string' and id ~= '' then blips[call.id] = id end
	end
end

local function onClosed(payload)
	local id = type(payload) == 'table' and math.tointeger(payload.id) or nil
	if id ~= nil then dropBlip(id) end
end

local function onWaypoint(at)
	if type(at) ~= 'table' or type(Open77.blips) ~= 'table' then return end
	pcall(Open77.blips.setWaypoint, { x = at.x, y = at.y, z = at.z })
end

-- ── the impound lot ──────────────────────────────────────────────────────────

local function buildLot(payload, generation)
	if type(payload) ~= 'table' or type(payload.vehicles) ~= 'table' then return end
	local items = {}
	for index, row in ipairs(payload.vehicles) do
		items[#items + 1] = {
			id = 'plate.' .. tostring(row.plate),
			label = ('%s · %s'):format(tostring(row.name or '?'), tostring(row.plate)),
			icon = 'vehicle',
			value = money(payload.fee, payload.moneyType),
			description = locale('mechanic.lot.release'),
			data = { plate = row.plate }, close = true,
		}
		if index % 4 == 0 then
			Wait(0)
			if stopped or generation ~= boardGeneration then return end
		end
	end
	Wait(0)
	if stopped or generation ~= boardGeneration then return end
	openMenu(MENU_LOT, locale('mechanic.lot.title', { shop = tostring(payload.label or '') }), items, function(data)
		TriggerServerEvent(Event.RELEASE, { shop = payload.shop, plate = data.plate })
	end, true)
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	-- A bar already says the work started.
	if ok and payload.code == 'started' then return end
	local code = payload.code
	if ok and code == 'repaired' and type(payload.billed) == 'string' then code = 'repaired_' .. payload.billed end
	local key = (ok and 'mechanic.answer.' or 'mechanic.error.') .. code
	if not OPX.Locale.Exists(key) then key = ok and 'mechanic.answer.done' or 'mechanic.error.unavailable' end
	toast(ok and 'success' or OPX.Result.Kind(payload.code, 'error'), locale(key, {
		fee = money(payload.fee or 0, payload.moneyType),
		earned = money(payload.earned or 0, payload.moneyType),
		plate = tostring(payload.plate or ''),
		count = math.tointeger(payload.count) or 0,
		percent = math.tointeger(payload.percent) or 0,
	}))
end

-- ── the eye ──────────────────────────────────────────────────────────────────

-- The vehicle the eye landed on, as the decimal string the wire carries.
local function vehicleOf(context)
	local hit = type(context) == 'table' and context.target or nil
	local id = type(hit) == 'table' and math.tointeger(hit.vehicleId) or nil
	if id == nil or id < 1 then return nil end
	return ('%d'):format(id)
end

local function rowFailed(what, placed)
	if type(placed) ~= 'table' or not placed.ok then
		OPX.Note('mechanic', ('the %s rows were refused: %s'):format(what,
			tostring(type(placed) == 'table' and placed.error or placed)))
		return true
	end
	return false
end

local function vehicleRow(id, label, icon, order, shown, mode)
	return {
		id = id, label = locale(label), icon = icon, order = order, distance = config().reach,
		canInteract = function(context) return vehicleOf(context) ~= nil and seat() == nil and shown() end,
		onSelect = function(context)
			local vehicleId = vehicleOf(context)
			if vehicleId == nil then return false end
			if mode == 'diagnose' then
				TriggerServerEvent(Event.DIAGNOSE, { vehicleId = vehicleId })
			elseif mode == 'hood_open' or mode == 'hood_close' then
				TriggerServerEvent(Event.HOOD, { vehicleId = vehicleId, opened = mode == 'hood_open' })
			elseif mode == 'impound' then
				TriggerServerEvent(Event.IMPOUND, { vehicleId = vehicleId })
			else
				TriggerServerEvent(Event.REPAIR, { vehicleId = vehicleId, mode = mode })
			end
			return true
		end,
	}
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('mechanic', 'no target contract: no repair, tow, stash or lot rows on the eye; the commands still work')
		return
	end
	local rows = {
		vehicleRow('mechanic.diagnose', 'mechanic.row.diagnose', 'tool', 23, function()
			local job = jobData()
			return job ~= nil and job.onDuty == true and isMechanic()
		end, 'diagnose'),
		vehicleRow('mechanic.repair', 'mechanic.row.repair', 'tool', 24, isMechanic, M.Mode.SHOP),
		vehicleRow('mechanic.impound', 'mechanic.row.impound', 'lock', 26, mayTow, 'impound'),
	}
	if config().kit.enabled then
		rows[#rows + 1] = vehicleRow('mechanic.kit', 'mechanic.row.kit', 'box', 25, holdsKit, M.Mode.KIT)
	end
	-- Each target registration validates and copies its row. Keep each in its
	-- own resume; a diagnostic is a fourth row, not a larger single batch.
	for _, row in ipairs(rows) do
		Wait(0)
		if stopped then return end
		rowFailed('vehicle', target.RegisterVehicles(OWNER, { row }))
	end
	for _, action in ipairs({
		{ mode = 'open', label = 'mechanic.row.hood_open' },
		{ mode = 'close', label = 'mechanic.row.hood_close' },
	}) do
		Wait(0)
		if stopped then return end
		local row = vehicleRow('mechanic.hood.' .. action.mode, action.label,
			'tool', 27, function()
				local job = jobData()
				return job ~= nil and job.onDuty == true and isMechanic()
			end, 'hood_' .. action.mode)
		Wait(0)
		if stopped then return end
		rowFailed('hood', target.RegisterVehicles(OWNER, { row }))
	end
	-- One sphere a row: a shop has one stash and one lot, and a handful of shops
	-- is a handful of rows, each its own resume.
	for _, key in ipairs(config().shopOrder) do
		local shop = config().shops[key]
		if shop.stash ~= nil then
			Wait(0)
			rowFailed(key .. ' stash', target.RegisterSpheres(OWNER,
				{ { x = shop.stash.x, y = shop.stash.y, z = shop.stash.z, radius = shop.stash.radius } }, {
				id = 'mechanic.stash.' .. key, label = locale('mechanic.row.stash'), icon = 'box', order = 25,
				distance = shop.stash.radius,
				canInteract = function() return isMechanic() end,
				onSelect = function()
					TriggerServerEvent(Event.STASH, { shop = key })
					return true
				end,
			}))
		end
		if shop.lot ~= nil then
			Wait(0)
			rowFailed(key .. ' lot', target.RegisterSpheres(OWNER,
				{ { x = shop.lot.x, y = shop.lot.y, z = shop.lot.z, radius = shop.lot.radius } }, {
				id = 'mechanic.lot.' .. key, label = locale('mechanic.row.lot'), icon = 'vehicle', order = 25,
				distance = shop.lot.radius,
				onSelect = function()
					TriggerServerEvent(Event.LOT, { shop = key })
					return true
				end,
			}))
		end
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Resets the state.
-- @author dop42
function M.Init()
	settings, blips, menuHandle = nil, {}, nil
	boardPending, boardWorking, stopped = nil, false, false
	boardGeneration = boardGeneration + 1
end

--- Wires the answers and the rows.
-- @author dop42
function M.Start()
	RegisterNetEvent(Event.DIAGNOSTIC_VIEW, function(payload) queueView(payload, buildDiagnostic) end)
	RegisterNetEvent(Event.BOARD_VIEW, function(payload) queueView(payload, buildBoard) end)
	RegisterNetEvent(Event.ALERT, onAlert)
	RegisterNetEvent(Event.CLOSED, onClosed)
	RegisterNetEvent(Event.WAYPOINT, onWaypoint)
	RegisterNetEvent(Event.LOT_VIEW, function(payload) queueView(payload, buildLot) end)
	RegisterNetEvent(Event.ANSWER, onAnswer)
	CreateThread(function()
		config()
		Wait(0)
		registerRows()
	end)
end

--- Hands the menu and the pins back.
-- @author dop42
function M.Stop()
	stopped = true
	boardGeneration = boardGeneration + 1
	boardPending = nil
	for id in pairs(blips) do dropBlip(id) end
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end
