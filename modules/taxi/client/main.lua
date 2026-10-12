--- Client half: the board, the alerts and their pins, the waypoint and the meter.
-- @author dop42
--
-- NOTHING HERE DECIDES. `/cab` asks the server for the board, the board's rows
-- send a wish back, and every answer arrives already judged. The meter on the
-- screen is the number the server measured, pushed on the server's clock; this
-- half never measures a metre of its own.
--
-- THE CLIENT BUDGET. Nothing here runs on a tick and nothing loops over a
-- config: every surface opens on an event, and the pins are one native call each.

local M = OPX.Modules.Get('taxi')
local Model = M.Model
local Event = M.Event

local OWNER = 'taxi'
local MENU_BOARD = 'taxi.board'

local settings
-- callId -> blip id, for the calls this driver was alerted to.
local blips = {}
local menuHandle

local function config()
	if settings == nil then settings = Model.Settings(M.Settings) end
	return settings
end

-- ── surfaces ─────────────────────────────────────────────────────────────────

local function toast(kind, message, id, title)
	OPX.Toast.Show({
		id = id or 'opx.taxi.answer', kind = kind, title = title or locale('taxi.title'),
		message = message, icon = 'vehicle', durationMs = 5000,
	})
end

local function openMenu(id, title, items, on)
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		toast('error', locale('taxi.error.no_menu'))
		return false
	end
	local opened = menu.Open({
		owner = OWNER, id = id, steal = true, focus = 'cursor', title = title, items = items,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) == 'table' then on(data) end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('taxi', ('the %s menu was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

local function money(amount, moneyType)
	return OPX.Locale.Money(math.tointeger(amount) or 0, moneyType)
end

local function km(metres) return ('%.1f'):format((tonumber(metres) or 0) / 1000) end

local function callLabel(call)
	local parts = { call.short and ('[%s]'):format(call.short) or locale('taxi.board.call') }
	if call.distance then parts[#parts + 1] = ('%d m'):format(call.distance) end
	return table.concat(parts, ' · ')
end

local function setWaypoint(at)
	if type(at) ~= 'table' or type(Open77.blips) ~= 'table' or type(Open77.blips.setWaypoint) ~= 'function' then
		return
	end
	pcall(Open77.blips.setWaypoint, { x = at.x, y = at.y, z = at.z })
end

-- ── the board ────────────────────────────────────────────────────────────────

local function onBoardView(payload)
	if type(payload) ~= 'table' then return end
	local calls = type(payload.calls) == 'table' and payload.calls or {}
	local items = {}
	local ride = type(payload.ride) == 'table' and payload.ride or nil
	if ride ~= nil then
		local what = ride.phase == M.Phase.RIDING and locale('taxi.board.ride.riding', { km = km(ride.metres) })
			or locale('taxi.board.ride.' .. tostring(ride.kind))
		items[#items + 1] = { id = 'ride', icon = 'star', disabled = true,
			label = locale('taxi.board.ride', { what = what }), value = ride.label }
		if ride.phase == M.Phase.RIDING then
			items[#items + 1] = { id = 'stop', icon = 'ban', label = locale('taxi.board.stop'),
				data = { verb = 'stop' }, close = true }
		else
			items[#items + 1] = { id = 'drop', icon = 'minus', label = locale('taxi.board.drop'),
				data = { verb = 'drop' }, close = true }
		end
	else
		if payload.driving then
			items[#items + 1] = { id = 'hail', icon = 'person', label = locale('taxi.board.hail'),
				data = { verb = 'hail' }, close = true }
		end
		for _, call in ipairs(calls) do
			items[#items + 1] = {
				id = 'call.' .. call.id, label = callLabel(call), icon = 'location',
				value = locale('taxi.board.age', { minutes = math.floor((call.ageS or 0) / 60) }),
				items = {
					{ id = 'take.' .. call.id, label = locale('taxi.board.take'), icon = 'plus',
						data = { verb = 'take', id = call.id }, close = true },
					{ id = 'route.' .. call.id, label = locale('taxi.board.route'), icon = 'map',
						data = { verb = 'route', call = call }, close = true },
				},
			}
		end
		if #calls == 0 then
			items[#items + 1] = { id = 'empty', label = locale('taxi.board.empty'), icon = 'info', disabled = true }
		end
		for _, row in ipairs(type(payload.street) == 'table' and payload.street or {}) do
			items[#items + 1] = { id = 'street.' .. tostring(row.company), icon = 'flag',
				label = locale('taxi.board.street', { company = row.short or row.company }),
				description = not row.available and locale('taxi.board.streetBusy') or nil,
				disabled = not row.available, data = { verb = 'street', company = row.company }, close = true }
		end
	end
	openMenu(MENU_BOARD, locale('taxi.board.title'), items, function(data)
		if data.verb == 'take' then
			TriggerServerEvent(Event.TAKE, { callId = data.id })
		elseif data.verb == 'route' and type(data.call) == 'table' and data.call.x then
			setWaypoint(data.call)
		elseif data.verb == 'street' then
			TriggerServerEvent(Event.STREET, { company = data.company })
		elseif data.verb == 'hail' then
			TriggerServerEvent(Event.HAIL, {})
		elseif data.verb == 'drop' then
			TriggerServerEvent(Event.DROP, {})
		elseif data.verb == 'stop' then
			TriggerServerEvent(Event.STOP, {})
		end
	end)
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
	toast('warning', locale('taxi.alert.body', { call = callLabel(call) }), 'opx.taxi.alert.' .. call.id,
		locale('taxi.alert.title'))
	local native = Open77.blips
	if blips[call.id] == nil and call.x and type(native) == 'table' and type(native.create) == 'function' then
		local co = call.company and config().companies[call.company] or nil
		local options = {
			position = { x = call.x, y = call.y, z = call.z },
			sprite = config().blipSprite,
			title = callLabel(call), description = locale('taxi.alert.title'),
			active = true, visibleThroughWalls = config().blipWalls,
		}
		-- The icon and tint where the client has the native SVG adapter (its
		-- test: `setColor` exists); the sprite alone everywhere else.
		local color = co and co.blipColor or config().blipColor
		if type(native.setColor) == 'function' then
			if config().blipIcon then options.icon = { asset = config().blipIcon, size = config().blipSize } end
			if color then options.color = color end
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

-- ── the meter ────────────────────────────────────────────────────────────────

local function onMeter(payload)
	if type(payload) ~= 'table' then return end
	local fare = money(payload.fare, payload.moneyType)
	local ended = payload.state == 'ended'
	toast(ended and 'success' or 'info', locale(ended and 'taxi.meter.ended' or 'taxi.meter.running',
		{ company = tostring(payload.company or ''), km = km(payload.metres), fare = fare }),
		'opx.taxi.meter', locale('taxi.meter.title'))
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	local key = (ok and 'taxi.answer.' or 'taxi.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'taxi.answer.done' or 'taxi.error.unavailable' end
	toast(ok and 'success' or OPX.Result.Kind(payload.code, 'error'), locale(key, {
		amount = tostring(payload.amount or ''), km = tostring(payload.km or ''),
		company = tostring(payload.company or ''), pickup = tostring(payload.pickup or ''),
	}))
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Resets the state.
-- @author dop42
function M.Init()
	settings, blips, menuHandle = nil, {}, nil
end

--- Wires the answers.
-- @author dop42
function M.Start()
	RegisterNetEvent(Event.BOARD_VIEW, onBoardView)
	RegisterNetEvent(Event.ALERT, onAlert)
	RegisterNetEvent(Event.CLOSED, onClosed)
	RegisterNetEvent(Event.WAYPOINT, setWaypoint)
	RegisterNetEvent(Event.METER, onMeter)
	RegisterNetEvent(Event.ANSWER, onAnswer)
end

--- Hands the menu and the pins back.
-- @author dop42
function M.Stop()
	for id in pairs(blips) do dropBlip(id) end
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end
