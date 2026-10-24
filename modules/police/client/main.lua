--- Client half: the alerts, the board, the eye rows, the forms and the cuffs.
-- @author dop42
--
-- NOTHING HERE DECIDES. The key asks for the board, the eye asks what may be
-- done to the player under it, a station desk asks what is owed, and every one
-- of those answers comes back from the server already judged. The one thing
-- this half does on its own is hold a cuffed player's hands: the controls are
-- client-local by nature, so the server sends RESTRAINED and this half applies
-- it -- and re-applies it every second, because a death, a body swap or another
-- module's `resetControls` hands every block back. The server's damage arbiter
-- is the authority; this is the feel of it.
--
-- THE CLIENT BUDGET. Rows go on the eye on a thread with a yield between two
-- registrations (`modules/fuel/client/main.lua` measured why).

local M = OPX.Modules.Get('police')
local Access = M.Access
local Event = M.Event

local OWNER = 'police'
local MENU_BOARD, MENU_OPTIONS, MENU_FRISK, MENU_DESK = 'police.board', 'police.options', 'police.frisk', 'police.desk'
local FORM_FINE, FORM_JAIL = 'police.fine', 'police.jail'

-- What a cuffed player cannot do. Released one by one with `true` and NEVER
-- with `resetControls`, which would hand back every block this resource holds.
local RESTRAINTS = { 'allowWeapons', 'allowShoot', 'allowAim', 'allowDodge', 'allowJump', 'allowInteraction' }
local RESTRAIN_MS = 1000

local settings
-- callId -> blip id, for the calls this officer was alerted to.
local blips = {}
local menuHandle
local restrained, restrainNoted = false, false

local function config()
	if settings == nil then settings = Access.Settings(M.Settings) end
	return settings
end

-- The build spread over resumes: one service or station per resume.
local function build()
	if settings == nil then settings = Access.Settings(M.Settings, function() Wait(0) end) end
	return settings
end

-- ── who am I ─────────────────────────────────────────────────────────────────

-- Whether the local character holds a job some service lists. A hint only: the
-- server judges the grade, the duty and the jurisdiction on every request.
local function isOfficer()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return false end
	local read, job = pcall(api.GetJobData)
	if not read or type(job) ~= 'table' or type(job.name) ~= 'string' then return false end
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		if type(svc.jobs) == 'table' and svc.jobs[job.name] ~= nil and (not svc.onDuty or job.onDuty == true) then
			return true
		end
	end
	return false
end

-- ── surfaces ─────────────────────────────────────────────────────────────────

local function toast(kind, message, icon)
	OPX.Toast.Show({ id = 'opx.police.answer', kind = kind, title = locale('police.title'),
		message = message, icon = icon or 'shield', durationMs = 4500 })
end

local function openMenu(id, title, items, on)
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		toast('error', locale('police.error.no_menu'))
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
		OPX.Note('police', ('the %s menu was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

local function openForm(id, title, description, fields, on)
	local form = OPX.Api.Get('form')
	if form == nil or type(form.Open) ~= 'function' then
		toast('error', locale('police.error.no_menu'))
		return false
	end
	local opened = form.Open({
		owner = OWNER, id = id, title = title, description = description, fields = fields,
		on = function(reply)
			if type(reply) ~= 'table' or reply.action ~= 'submit' then return end
			on(type(reply.values) == 'table' and reply.values or {})
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('police', ('the %s form was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	return true
end

local function money(amount, moneyType)
	return OPX.Locale.Money(math.tointeger(amount) or 0, moneyType)
end

-- ── the board ────────────────────────────────────────────────────────────────

local function callLabel(call)
	local parts = { ('[%s]'):format(call.short or '?'), tostring(call.label or call.crime or '?') }
	if call.distance then parts[#parts + 1] = ('%d m'):format(call.distance) end
	return table.concat(parts, ' · ')
end

local function setWaypoint(at)
	local native = Open77.blips
	if type(at) ~= 'table' or at.x == nil or type(native) ~= 'table' or type(native.setWaypoint) ~= 'function' then
		return
	end
	pcall(native.setWaypoint, { x = at.x, y = at.y, z = at.z })
end

local function onBoardView(payload)
	local calls = type(payload) == 'table' and type(payload.calls) == 'table' and payload.calls or {}
	local items = {}
	for _, call in ipairs(calls) do
		local actions = {}
		if call.mine then
			if call.x then
				actions[#actions + 1] = { id = 'route.' .. call.id, label = locale('police.board.route'),
					icon = 'map', data = { verb = 'route', call = call }, close = true }
			end
			actions[#actions + 1] = { id = 'drop.' .. call.id, label = locale('police.board.drop'),
				icon = 'minus', data = { verb = 'drop', id = call.id }, close = true }
		else
			actions[#actions + 1] = { id = 'take.' .. call.id, label = locale('police.board.take'),
				icon = 'plus', data = { verb = 'take', id = call.id }, close = true,
				disabled = (call.responders or 0) >= (call.limit or 1) }
		end
		items[#items + 1] = {
			id = 'call.' .. call.id, label = callLabel(call),
			icon = call.mine and 'star' or ((call.priority or 0) >= 8 and 'warning' or 'info'),
			value = ('%d/%d · %s'):format(call.responders or 0, call.limit or 1,
				locale('police.board.age', { minutes = math.floor((call.ageS or 0) / 60) })),
			description = call.description or (call.x == nil and locale('police.board.noPosition') or nil),
			items = actions,
		}
	end
	if #calls == 0 then
		items[#items + 1] = { id = 'empty', label = locale('police.board.empty'), icon = 'info', disabled = true }
	end
	openMenu(MENU_BOARD, locale('police.board.title'), items, function(data)
		if data.verb == 'take' then
			TriggerServerEvent(Event.TAKE, { callId = data.id })
		elseif data.verb == 'drop' then
			TriggerServerEvent(Event.DROP, { callId = data.id })
		elseif data.verb == 'route' then
			setWaypoint(data.call)
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
	OPX.Toast.Show({
		id = 'opx.police.alert.' .. call.id, kind = (call.priority or 0) >= 8 and 'error' or 'warning',
		title = locale('police.alert.title'),
		message = locale('police.alert.body', { call = callLabel(call),
			description = call.description or (call.x == nil and locale('police.board.noPosition') or '') }),
		icon = 'shield', durationMs = config().alertMs,
	})
	local native = Open77.blips
	if blips[call.id] == nil and call.x and type(native) == 'table' and type(native.create) == 'function' then
		local svc = config().services[call.service]
		local options = {
			position = { x = call.x, y = call.y, z = call.z or 0.0 },
			sprite = svc and svc.blipSprite or config().blipSprite,
			title = callLabel(call), description = locale('police.alert.title'),
			active = true, visibleThroughWalls = config().blipWalls,
		}
		-- The service's icon and tint where the client has the native SVG adapter
		-- (its test: `setColor` exists); the sprite alone everywhere else, and
		-- again if this client refuses the icon.
		local icon = svc and svc.blipIcon or config().blipIcon
		local color = svc and svc.blipColor or config().blipColor
		if type(native.setColor) == 'function' then
			if icon then options.icon = { asset = icon, size = svc and svc.blipSize or 48 } end
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

-- ── acting on a suspect ──────────────────────────────────────────────────────

local function onOptionsView(payload)
	if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
	local items = {}
	for _, row in ipairs(payload.rows) do
		items[#items + 1] = {
			id = 'act.' .. tostring(row.action),
			label = ('[%s] %s'):format(tostring(row.short), OPX.Locale.Exists(row.label) and locale(row.label)
				or tostring(row.action)),
			icon = row.action == 'fine' and 'money' or row.action == 'frisk' and 'search'
				or row.action == 'jail' and 'lock' or 'person',
			data = { action = row.action }, close = true,
		}
	end
	openMenu(MENU_OPTIONS, locale('police.options.title'), items, function(data)
		TriggerServerEvent(Event.ACT, { target = payload.target, action = data.action })
	end)
end

local function onFriskView(payload)
	if type(payload) ~= 'table' or type(payload.items) ~= 'table' then return end
	local items = {}
	for _, row in ipairs(payload.items) do
		items[#items + 1] = {
			id = 'slot.' .. tostring(row.slot), label = tostring(row.label or row.name), icon = 'box',
			value = 'x' .. tostring(row.count or 1), description = locale('police.frisk.take'),
			data = { slot = row.slot }, close = true,
		}
	end
	if #items == 0 then
		items[1] = { id = 'empty', label = locale('police.frisk.empty'), icon = 'info', disabled = true }
	end
	openMenu(MENU_FRISK, locale('police.frisk.title'), items, function(data)
		TriggerServerEvent(Event.CONFISCATE, { target = payload.target, slot = data.slot })
	end)
end

local function onFineView(payload)
	if type(payload) ~= 'table' or type(payload.crimes) ~= 'table' then return end
	local options, hint = {}, {}
	for _, crime in ipairs(payload.crimes) do
		options[#options + 1] = { label = ('%s (%s)'):format(tostring(crime.label), money(crime.fine, payload.moneyType)),
			value = crime.code }
		hint[#hint + 1] = crime
	end
	openForm(FORM_FINE, locale('police.fine.title'), locale('police.fine.description'), {
		{ id = 'code', label = locale('police.fine.crime'), options = options },
		{ id = 'amount', label = locale('police.fine.amount'), required = true, charset = 'digits', maxLength = 9,
			placeholder = hint[1] and tostring(hint[1].fine) or '' },
		{ id = 'reason', label = locale('police.fine.reason'), maxLength = 120 },
	}, function(values)
		TriggerServerEvent(Event.FINE, { target = payload.target, code = values.code, amount = values.amount,
			reason = values.reason })
	end)
end

local function onJailView(payload)
	if type(payload) ~= 'table' or type(payload.crimes) ~= 'table' then return end
	local options = {}
	for _, crime in ipairs(payload.crimes) do
		options[#options + 1] = { label = (crime.minutes or 0) > 0
			and ('%s (%d min)'):format(tostring(crime.label), crime.minutes) or tostring(crime.label), value = crime.code }
	end
	openForm(FORM_JAIL, locale('police.jail.title', { station = tostring(payload.station or '') }),
		locale('police.jail.description', { max = payload.max or 0 }), {
		{ id = 'code', label = locale('police.fine.crime'), options = options },
		{ id = 'minutes', label = locale('police.jail.minutes'), required = true, charset = 'digits', maxLength = 5 },
		{ id = 'reason', label = locale('police.fine.reason'), maxLength = 120 },
	}, function(values)
		TriggerServerEvent(Event.JAIL, { target = payload.target, code = values.code, minutes = values.minutes,
			reason = values.reason })
	end)
end

local function onDeskView(payload)
	if type(payload) ~= 'table' then return end
	local items = {}
	if (payload.debt or 0) > 0 then
		items[1] = { id = 'pay', icon = 'money', label = locale('police.desk.pay'),
			value = money(payload.debt, payload.moneyType), data = { pay = true }, close = true }
	else
		items[1] = { id = 'clear', icon = 'shield', label = locale('police.desk.clear'), disabled = true }
	end
	openMenu(MENU_DESK, tostring(payload.label or ''), items, function(data)
		if data.pay then TriggerServerEvent(Event.DESK, { station = payload.station, pay = true }) end
	end)
end

-- ── the cuffs, on the suspect's own client ───────────────────────────────────

local function hold(on)
	if not OPX.Controls.Set('police', RESTRAINTS, on) and on and not restrainNoted then
		restrainNoted = true
		OPX.Note('police', 'player-control lease refused while cuffed')
	end
	local target = OPX.Api.Get('target')
	if target ~= nil and type(target.SetTargetingEnabled) == 'function' then
		pcall(target.SetTargetingEnabled, OWNER, not on)
	end
end

local function onRestrained(payload)
	local on = type(payload) == 'table' and payload.cuffed == true
	if on == restrained then
		if on then hold(true) end
		return
	end
	restrained = on
	hold(on)
	toast(on and 'warning' or 'info', locale(on and 'police.self.cuffed' or 'police.self.free'), 'lock')
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	if ok and payload.code == 'started' then return end
	local key = (ok and 'police.answer.' or 'police.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'police.answer.done' or 'police.error.unavailable' end
	toast(ok and 'success' or OPX.Result.Kind(payload.code, 'error'), locale(key, {
		amount = money(payload.amount or 0, payload.moneyType),
		paid = money(payload.paid or 0, payload.moneyType),
		owed = money(payload.owed or 0, payload.moneyType),
		cut = money(payload.cut or 0, payload.moneyType),
		minutes = payload.minutes or 0, item = payload.item or '', count = payload.count or 0,
		station = payload.station or '', plate = payload.plate or '',
	}))
end

-- ── the eye ──────────────────────────────────────────────────────────────────

local function playerOf(context)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(tonumber(target.playerId)) or nil
	return id and id > 0 and id or nil
end

local function vehicleOf(context)
	local hit = type(context) == 'table' and context.target or nil
	local id = type(hit) == 'table' and math.tointeger(hit.vehicleId) or nil
	return id and id > 0 and id or nil
end

local function noted(what, result)
	if type(result) ~= 'table' or not result.ok then
		OPX.Note('police', ('the %s rows were refused: %s'):format(what,
			tostring(type(result) == 'table' and result.error or result)))
	end
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('police', 'no target contract: no police rows on the eye; the board key still works')
		return
	end
	noted('player', target.RegisterPlayers(OWNER, { {
		id = 'police.suspect', label = locale('police.row.suspect'), icon = 'shield', order = 31,
		distance = config().reach,
		canInteract = function(context) return playerOf(context) ~= nil and isOfficer() end,
		onSelect = function(context)
			local id = playerOf(context)
			if id == nil then return false end
			TriggerServerEvent(Event.OPTIONS, { target = id })
			return true
		end,
	} }))
	Wait(0)
	noted('vehicle', target.RegisterVehicles(OWNER, { {
		id = 'police.impound', label = locale('police.row.impound'), icon = 'vehicle', order = 40,
		distance = config().impound.reach,
		canInteract = function(context) return vehicleOf(context) ~= nil and isOfficer() end,
		onSelect = function(context)
			local id = vehicleOf(context)
			if id == nil then return false end
			TriggerServerEvent(Event.IMPOUND, { vehicleId = id })
			return true
		end,
	} }))
	for _, key in ipairs(config().stationOrder) do
		local station = config().stations[key]
		if station.desk ~= nil then
			Wait(0)
			local desk = station.desk
			noted('desk', target.RegisterSpheres(OWNER, { { x = desk.x, y = desk.y, z = desk.z, radius = desk.radius } }, {
				id = 'police.desk.' .. key, label = locale('police.row.desk'), icon = 'money', order = 26,
				distance = desk.radius,
				onSelect = function()
					TriggerServerEvent(Event.DESK, { station = key })
					return true
				end,
			}))
		end
		if station.evidence ~= nil then
			Wait(0)
			local locker = station.evidence
			noted('evidence', target.RegisterSpheres(OWNER, { { x = locker.x, y = locker.y, z = locker.z,
				radius = locker.radius } }, {
				id = 'police.evidence.' .. key, label = locale('police.row.evidence'), icon = 'box', order = 26,
				distance = locker.radius,
				canInteract = function() return isOfficer() end,
				onSelect = function()
					TriggerServerEvent(Event.EVIDENCE, { station = key })
					return true
				end,
			}))
		end
	end
end

-- ── the key ──────────────────────────────────────────────────────────────────

local function bindKey()
	local declared = type(M.Settings.DISPATCH_KEY) == 'table' and M.Settings.DISPATCH_KEY or {}
	local key = declared.DEFAULT
	if type(key) ~= 'string' or key == '' then return end
	if type(RegisterKeyMapping) ~= 'function' then
		OPX.Note('police', 'this host has no RegisterKeyMapping: the dispatch board has no key')
		return
	end
	local id = tostring(declared.ID or 'opx.police.dispatch')
	local called, ok, err = pcall(RegisterKeyMapping, id, locale(declared.NAME or 'police.key.dispatch'), key,
		function()
			if OPX.Spots.Captured() then return end
			if not isOfficer() then return end
			TriggerServerEvent(Event.BOARD, {})
		end)
	if not called or ok == false then
		OPX.Note('police', ('%s could not take %q: %s'):format(id, key, tostring(called and err or ok)))
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Resets the state.
-- @author dop42
function M.Init()
	settings, blips, menuHandle, restrained, restrainNoted = nil, {}, nil, false, false
end

--- Wires the answers, the key, the rows and the restraint watch.
-- @author dop42
function M.Start()
	RegisterNetEvent(Event.BOARD_VIEW, onBoardView)
	RegisterNetEvent(Event.ALERT, onAlert)
	RegisterNetEvent(Event.CLOSED, onClosed)
	RegisterNetEvent(Event.WAYPOINT, setWaypoint)
	RegisterNetEvent(Event.OPTIONS_VIEW, onOptionsView)
	RegisterNetEvent(Event.FRISK_VIEW, onFriskView)
	RegisterNetEvent(Event.FINE_VIEW, onFineView)
	RegisterNetEvent(Event.JAIL_VIEW, onJailView)
	RegisterNetEvent(Event.DESK_VIEW, onDeskView)
	RegisterNetEvent(Event.RESTRAINED, onRestrained)
	RegisterNetEvent(Event.ANSWER, onAnswer)
	-- A death, a new body or another module's reset hands every block back:
	-- while cuffed, the hold is put back every second. Nothing runs uncuffed.
	OPX.Scheduler.Every('police:restraint', RESTRAIN_MS, function()
		if restrained then hold(true) end
	end)
	CreateThread(function()
		build()
		Wait(0)
		bindKey()
		Wait(0)
		registerRows()
	end)
end

--- Hands the menu, the pins and the hands back.
-- @author dop42
function M.Stop()
	for id in pairs(blips) do dropBlip(id) end
	if restrained then
		restrained = false
		hold(false)
	end
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end
