--- Client half: the alerts, the board, the eye rows, the desks and the consent.
-- @author dop42
--
-- NOTHING HERE DECIDES. The key asks for the board, the eye asks what may be
-- done to the body under it, a desk asks for its contract sheet, and every one
-- of those answers comes back from the server already judged. The only thing
-- this half knows on its own is whether to bother drawing a medic's rows at
-- all, read off the character's own job -- a hint for the eye, never a gate.
--
-- THE CLIENT BUDGET. Rows are put on the eye on a thread with a yield between
-- two registrations (`modules/fuel/client/main.lua` measured why), and nothing
-- here runs on a tick: every surface opens on an event.

local M = OPX.Modules.Get('medical')
local Model = M.Model
local Event = M.Event

local OWNER = 'medical'
local MENU_BOARD, MENU_OPTIONS, MENU_DESK, MENU_ASK =
	'medical.board', 'medical.options', 'medical.desk', 'medical.ask'

-- Desk spheres per eye row: see `registerRows` in the fuel client.
local SPHERES_PER_ROW = 4

local settings
-- callId -> blip id, for the calls this medic was alerted to.
local blips = {}
local menuHandle

local function config()
	if settings == nil then settings = Model.Settings(M.Settings) end
	return settings
end

-- ── who am I ─────────────────────────────────────────────────────────────────

-- Whether the local character holds a job some service lists. A hint only: the
-- server judges the grade and the duty on every request.
local function isMedic()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return false end
	local read, job = pcall(api.GetJobData)
	if not read or type(job) ~= 'table' or type(job.name) ~= 'string' then return false end
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		if type(svc.jobs) == 'table' and svc.jobs[job.name] ~= nil
			and (not svc.onDuty or job.onDuty == true) then
			return true
		end
	end
	return false
end

-- ── surfaces ─────────────────────────────────────────────────────────────────

local function toast(kind, message, icon)
	OPX.Toast.Show({
		id = 'opx.medical.answer', kind = kind, title = locale('medical.title'),
		message = message, icon = icon or 'heal', durationMs = 4500,
	})
end

local function openMenu(id, title, items, on)
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		toast('error', locale('medical.error.no_menu'))
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
		OPX.Note('medical', ('the %s menu was refused: %s'):format(id,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

local function money(amount, moneyType)
	return OPX.Locale.Money(math.tointeger(amount) or 0, moneyType)
end

-- ── the board ────────────────────────────────────────────────────────────────

local function callLabel(call)
	local parts = { ('[%s]'):format(call.short or '?') }
	if call.tier then parts[#parts + 1] = call.tier:upper() end
	if call.offContract then parts[#parts + 1] = locale('medical.board.offContract') end
	if call.distance then parts[#parts + 1] = ('%d m'):format(call.distance) end
	return table.concat(parts, ' · ')
end

local function onBoardView(payload)
	local calls = type(payload) == 'table' and type(payload.calls) == 'table' and payload.calls or {}
	local items = {
		{ id = 'nearest', label = locale('medical.board.nearest'), icon = 'heal',
			data = { verb = 'nearest' }, close = true },
	}
	for _, call in ipairs(calls) do
		local actions = {}
		if call.mine then
			actions[#actions + 1] = { id = 'route.' .. call.id, label = locale('medical.board.route'),
				icon = 'map', data = { verb = 'route', call = call }, close = true }
			actions[#actions + 1] = { id = 'drop.' .. call.id, label = locale('medical.board.drop'),
				icon = 'minus', data = { verb = 'drop', id = call.id }, close = true }
		else
			actions[#actions + 1] = { id = 'take.' .. call.id, label = locale('medical.board.take'),
				icon = 'plus', data = { verb = 'take', id = call.id }, close = true,
				disabled = (call.responders or 0) >= (call.limit or 1) }
		end
		items[#items + 1] = {
			id = 'call.' .. call.id, label = callLabel(call), icon = call.mine and 'star' or 'warning',
			value = ('%d/%d · %s'):format(call.responders or 0, call.limit or 1,
				locale('medical.board.age', { minutes = math.floor((call.ageS or 0) / 60) })),
			description = locale('medical.reason.' .. tostring(call.reason)),
			items = actions,
		}
	end
	if #calls == 0 then
		items[#items + 1] = { id = 'empty', label = locale('medical.board.empty'), icon = 'info', disabled = true }
	end
	openMenu(MENU_BOARD, locale('medical.board.title'), items, function(data)
		if data.verb == 'take' then
			TriggerServerEvent(Event.TAKE, { callId = data.id })
		elseif data.verb == 'drop' then
			TriggerServerEvent(Event.DROP, { callId = data.id })
		elseif data.verb == 'route' and type(data.call) == 'table' and data.call.x then
			pcall(Open77.blips.setWaypoint, { x = data.call.x, y = data.call.y, z = data.call.z })
		elseif data.verb == 'nearest' then
			TriggerServerEvent(Event.OPTIONS, {})
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
		id = 'opx.medical.alert.' .. call.id, kind = 'warning', title = locale('medical.alert.title'),
		message = locale('medical.alert.body', { call = callLabel(call),
			reason = locale('medical.reason.' .. tostring(call.reason)) }),
		icon = 'heart', durationMs = config().alertMs,
	})
	local native = Open77.blips
	if blips[call.id] == nil and call.x and type(native) == 'table' and type(native.create) == 'function' then
		local svc = config().services[call.service]
		local read, id = pcall(native.create, {
			position = { x = call.x, y = call.y, z = call.z },
			sprite = svc and svc.blipSprite or config().blipSprite,
			title = callLabel(call), description = locale('medical.alert.title'),
			active = true, visibleThroughWalls = config().blipWalls,
		})
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

-- ── treating ─────────────────────────────────────────────────────────────────

local function onOptionsView(payload)
	if type(payload) ~= 'table' or type(payload.rows) ~= 'table' then return end
	local items = {}
	for _, row in ipairs(payload.rows) do
		items[#items + 1] = {
			id = row.service .. '.' .. row.treatment,
			label = ('[%s] %s'):format(row.short, OPX.Locale.Exists(row.label) and locale(row.label) or row.label),
			icon = row.kind == M.Kind.REVIVE and 'heart' or row.kind == M.Kind.CARRY and 'person' or 'heal',
			value = row.fee > 0 and money(row.fee, row.moneyType) or nil,
			description = not row.stocked and locale('medical.options.unstocked') or nil,
			disabled = not row.stocked,
			data = { service = row.service, treatment = row.treatment },
			close = true,
		}
	end
	openMenu(MENU_OPTIONS, locale('medical.options.title'), items, function(data)
		TriggerServerEvent(Event.TREAT, { target = payload.target, service = data.service,
			treatment = data.treatment })
	end)
end

local function onAsk(payload)
	if type(payload) ~= 'table' or math.tointeger(payload.inviteId) == nil then return end
	local treatment = OPX.Locale.Exists(payload.treatment) and locale(payload.treatment) or payload.treatment
	local reply = function(accepted)
		TriggerServerEvent(Event.CONSENT, { inviteId = payload.inviteId, accepted = accepted })
	end
	openMenu(MENU_ASK, locale('medical.ask.title', { service = payload.service }), {
		{ id = 'accept', label = locale('medical.ask.accept', { treatment = treatment }), icon = 'heal',
			value = (payload.fee or 0) > 0 and money(payload.fee, payload.moneyType) or nil,
			data = { accepted = true }, close = true },
		{ id = 'decline', label = locale('medical.ask.decline'), icon = 'ban',
			data = { accepted = false }, close = true },
	}, function(data) reply(data.accepted == true) end)
end

-- ── desks ────────────────────────────────────────────────────────────────────

local function onDeskView(payload)
	if type(payload) ~= 'table' or type(payload.tiers) ~= 'table' then return end
	local items = {}
	if type(payload.current) == 'table' then
		items[#items + 1] = { id = 'current', icon = 'shield', disabled = true,
			label = locale('medical.desk.current', { tier = payload.current.label }),
			value = locale('medical.desk.remaining',
				{ hours = math.floor((payload.current.remainingS or 0) / 3600) }) }
	end
	if (payload.debt or 0) > 0 then
		items[#items + 1] = { id = 'debt', icon = 'warning', label = locale('medical.desk.payDebt'),
			value = money(payload.debt, payload.debtMoneyType), data = { payDebt = true }, close = true }
	end
	for _, tier in ipairs(payload.tiers) do
		local perks = {}
		if tier.autoAlert then perks[#perks + 1] = locale('medical.desk.biomonitor') end
		if (tier.discount or 0) > 0 then perks[#perks + 1] = locale('medical.desk.discount', { pct = tier.discount }) end
		items[#items + 1] = {
			id = 'tier.' .. tier.key, icon = 'star',
			label = locale('medical.desk.tier', { tier = tier.label, days = tier.days }),
			value = money(tier.price, payload.moneyType),
			description = #perks > 0 and table.concat(perks, ' · ') or nil,
			data = { tier = tier.key }, close = true,
		}
	end
	openMenu(MENU_DESK, payload.label, items, function(data)
		TriggerServerEvent(Event.SUBSCRIBE, { service = payload.service, desk = payload.desk,
			tier = data.tier, payDebt = data.payDebt == true })
	end)
end

-- ── answers ──────────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	-- A bar or a pair already says the work started.
	if ok and payload.code == 'started' then return end
	local key = (ok and 'medical.answer.' or 'medical.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = ok and 'medical.answer.done' or 'medical.error.unavailable' end
	toast(ok and 'success' or OPX.Result.Kind(payload.code, 'error'), locale(key, {
		amount = money(payload.earned or payload.amount or 0, payload.moneyType),
		tier = payload.tier or '', service = payload.service or '',
		item = payload.item or '',
	}))
end

-- ── the eye ──────────────────────────────────────────────────────────────────

local function targetOf(context)
	local target = type(context) == 'table' and context.target or nil
	if type(target) ~= 'table' then return nil end
	local id = math.tointeger(tonumber(target.playerId))
	return id and id > 0 and id or nil
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('medical', 'no target contract: no treat or desk rows on the eye; the board key still works')
		return
	end
	local placed = target.RegisterPlayers(OWNER, { {
		id = 'medical.treat', label = locale('medical.row.treat'), icon = 'heal', order = 30,
		distance = config().reach,
		canInteract = function(context) return targetOf(context) ~= nil and isMedic() end,
		onSelect = function(context)
			local id = targetOf(context)
			if id == nil then return false end
			TriggerServerEvent(Event.OPTIONS, { target = id })
			return true
		end,
	} })
	if type(placed) ~= 'table' or not placed.ok then
		OPX.Note('medical', ('the treat row was refused: %s'):format(tostring(type(placed) == 'table'
			and placed.error or placed)))
	end
	for _, key in ipairs(config().serviceOrder) do
		local svc = config().services[key]
		local desks = svc.subscription.desks
		for first = 1, #desks, SPHERES_PER_ROW do
			Wait(0)
			local spheres, deskIndex = {}, desks[first].index
			for index = first, math.min(#desks, first + SPHERES_PER_ROW - 1) do
				local desk = desks[index]
				spheres[#spheres + 1] = { x = desk.x, y = desk.y, z = desk.z, radius = desk.radius }
			end
			local rows = target.RegisterSpheres(OWNER, spheres, {
				id = ('medical.desk.%s.%d'):format(key, first),
				label = locale('medical.row.desk', { service = svc.short }),
				icon = 'shield', order = 25, distance = desks[first].radius,
				onSelect = function(context)
					-- The sphere that was hit is the nearest desk of this row; the
					-- server measures the reach again and names the desk it found.
					local best, bestGap = deskIndex, nil
					local hit = type(context) == 'table' and context.position or nil
					if type(hit) == 'table' then
						for index = first, math.min(#desks, first + SPHERES_PER_ROW - 1) do
							local desk = desks[index]
							local gap = (desk.x - hit.x) ^ 2 + (desk.y - hit.y) ^ 2 + (desk.z - hit.z) ^ 2
							if bestGap == nil or gap < bestGap then best, bestGap = desk.index, gap end
						end
					end
					TriggerServerEvent(Event.DESK, { service = key, desk = best })
					return true
				end,
			})
			if type(rows) ~= 'table' or not rows.ok then
				OPX.Note('medical', ('the %s desk rows were refused: %s'):format(key,
					tostring(type(rows) == 'table' and rows.error or rows)))
			end
		end
	end
end

-- ── the key ──────────────────────────────────────────────────────────────────

local function bindKey()
	local declared = type(M.Settings.DISPATCH_KEY) == 'table' and M.Settings.DISPATCH_KEY or {}
	local key = declared.DEFAULT
	if type(key) ~= 'string' or key == '' then return end
	if type(RegisterKeyMapping) ~= 'function' then
		OPX.Note('medical', 'this host has no RegisterKeyMapping: the dispatch board has no key')
		return
	end
	local id = tostring(declared.ID or 'opx.medical.dispatch')
	local called, ok, err = pcall(RegisterKeyMapping, id, locale(declared.NAME or 'medical.key.dispatch'),
		key, function()
			if OPX.Spots.Captured() then return end
			if not isMedic() then return end
			TriggerServerEvent(Event.BOARD, {})
		end)
	if not called or ok == false then
		OPX.Note('medical', ('%s could not take %q: %s'):format(id, key, tostring(called and err or ok)))
	end
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Resets the state.
-- @author dop42
function M.Init()
	settings, blips, menuHandle = nil, {}, nil
end

--- Wires the answers, the key and the rows.
-- @author dop42
function M.Start()
	RegisterNetEvent(Event.BOARD_VIEW, onBoardView)
	RegisterNetEvent(Event.ALERT, onAlert)
	RegisterNetEvent(Event.CLOSED, onClosed)
	RegisterNetEvent(Event.WAYPOINT, onWaypoint)
	RegisterNetEvent(Event.OPTIONS_VIEW, onOptionsView)
	RegisterNetEvent(Event.ASK, onAsk)
	RegisterNetEvent(Event.DESK_VIEW, onDeskView)
	RegisterNetEvent(Event.ANSWER, onAnswer)
	CreateThread(function()
		config()
		Wait(0)
		bindKey()
		Wait(0)
		registerRows()
	end)
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
