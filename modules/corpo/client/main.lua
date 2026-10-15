--- Client half: the eye rows at offices, drops, terminals and pickups, the
--- board's menu, the assignment readout, and the steal / detain rows on players.
-- @author dop42
--
-- NONE OF IT DECIDES. A row names an office, a drop or a player; the server
-- measures the reach, reads the job, checks the item and answers with what it
-- wants drawn (`SHOW_BOARD`, `ACTIVE`, `ROLE`). Every `canInteract` here is a
-- courtesy -- it hides a row the server would refuse -- never a gate.
--
-- THE CLIENT BUDGET. The places are built one corp a resume through the same
-- `Access.Corp` the server runs, and the rows are registered one place a
-- resume (`modules/fuel/client/main.lua` measured why).

local M = OPX.Modules.Get('corpo')
local Access = M.Access

local OWNER = 'corpo'
local MENU_ID = 'corpo.board'
local HUD_ID = 'opx.corpo.hud'

-- { corp, corpLabel, list, key, label, x, y, z, radius }
local places = {}
-- What the server last said: the assignment, the role, the board.
local active, role, board = nil, nil, nil
local menuHandle = nil

-- ── the waypoint ────────────────────────────────────────────────────────────

local function setWaypoint(point)
	local blips = Open77.blips
	if type(blips) ~= 'table' or type(blips.setWaypoint) ~= 'function' or type(point) ~= 'table' then return end
	local x, y, z = OPX.Math.Finite(point.x), OPX.Math.Finite(point.y), OPX.Math.Finite(point.z)
	if x ~= nil and y ~= nil and z ~= nil then pcall(blips.setWaypoint, { x = x, y = y, z = z }) end
end

local function clearWaypoint()
	local blips = Open77.blips
	if type(blips) == 'table' and type(blips.clearWaypoint) == 'function' then pcall(blips.clearWaypoint) end
end

-- ── the board's menu ────────────────────────────────────────────────────────

local function closeMenu()
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end

local function text(value, maximum)
	return OPX.Text.Clean(tostring(value or ''), maximum or 80) or ''
end

--- Opens the board the server last sent; `outsource` picks an offer to push to
--- the fixer board instead of taking it.
-- @author dop42
-- @param outsource boolean|nil
-- @return boolean
function M.OpenBoard(outsource)
	if type(board) ~= 'table' then return false end
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then return false end
	local items = {}
	local quarter = type(board.quarter) == 'table' and board.quarter or {}
	items[#items + 1] = { id = 'standing', icon = 'star', disabled = true,
		label = locale('corpo.menu.standing', { standing = math.tointeger(board.standing) or 0,
			done = math.tointeger(quarter.done) or 0, target = math.tointeger(quarter.target) or 0 }) }
	local rows = type(board.rows) == 'table' and board.rows or {}
	for index = 1, math.min(#rows, 30) do
		local row = rows[index]
		if type(row) == 'table' and type(row.id) == 'string' then
			local locked = type(row.locked) == 'string' and row.locked or nil
			local value = locale('corpo.menu.offer', { pay = OPX.Locale.Money(math.tointeger(row.pay) or 0),
				standing = math.tointeger(row.standing) or 0, minutes = math.tointeger(row.minutes) or 0 })
			if locked ~= nil and not outsource then
				value = locale('corpo.menu.locked.' .. locked, { grade = math.tointeger(row.minGrade) or 0,
					standing = math.tointeger(row.minStanding) or 0 })
			end
			items[#items + 1] = {
				id = ('o%d'):format(index),
				label = text(row.label, 60),
				description = text(row.start and ('%s - %s'):format(tostring(row.brief or ''), row.start) or row.brief, 160),
				icon = row.kind == 'escort' and 'person' or row.kind == 'sweep' and 'eye'
					or row.kind == 'retrieve' and 'server' or 'box',
				value = value,
				disabled = not outsource and (locked ~= nil or board.busy == true),
				data = { verb = outsource and 'outsource' or 'accept', offer = row.id },
				close = true,
			}
		end
	end
	if #rows == 0 then
		items[#items + 1] = { id = 'empty', icon = 'info', disabled = true, label = locale('corpo.menu.empty') }
	end
	if not outsource and board.canPublish == true and #rows > 0 then
		items[#items + 1] = { id = 'publish', icon = 'folder', label = locale('corpo.menu.outsource'),
			data = { verb = 'publishMode' } }
	end
	if not outsource and board.busy == true then
		items[#items + 1] = { id = 'abandon', icon = 'trash', label = locale('corpo.menu.abandon'),
			data = { verb = 'abandon' }, close = true }
	end
	closeMenu()
	local opened = menu.Open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = outsource and locale('corpo.menu.outsourceTitle')
			or locale('corpo.menu.title', { corp = text(board.label, 30), office = text(board.officeLabel, 50) }),
		items = items,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) ~= 'table' then return end
			if data.verb == 'accept' then
				TriggerServerEvent(M.Event.ACCEPT, { corp = board.corp, office = board.office, offer = data.offer })
			elseif data.verb == 'outsource' then
				TriggerServerEvent(M.Event.ACT, { verb = 'outsource', corp = board.corp, office = board.office,
					offer = data.offer })
			elseif data.verb == 'abandon' then
				TriggerServerEvent(M.Event.ACT, { verb = 'abandon' })
			elseif data.verb == 'publishMode' then
				CreateThread(function() M.OpenBoard(true) end)
			end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('corpo', ('the board was refused: %s'):format(tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return true
end

-- ── what the server says ────────────────────────────────────────────────────

local function onBoard(payload)
	if type(payload) ~= 'table' then return end
	board = payload
	M.OpenBoard(false)
end

local function onActive(payload)
	if type(payload) ~= 'table' then
		if active ~= nil then clearWaypoint() end
		active = nil
		pcall(OPX.Toast.Dismiss, HUD_ID)
		return
	end
	local target = type(payload.target) == 'table' and payload.target or nil
	local moved = active == nil or type(active.target) ~= 'table' or target == nil
		or active.target.key ~= target.key or active.stage ~= payload.stage
	active = payload
	if target ~= nil and moved then setWaypoint(target) end
	local stage = ({ ['goto'] = 'goto', carry = 'carry', sweep = 'sweep', escort = 'escort' })[payload.stage] or 'goto'
	OPX.Toast.Show({ id = HUD_ID, kind = 'info', title = locale('corpo.title'), icon = 'folder', durationMs = 6000,
		message = locale('corpo.hud.' .. stage, { label = text(payload.label, 60),
			target = text(target and target.label, 60), seconds = math.tointeger(payload.holdS) or 0 }) })
end

local function onRole(payload)
	role = type(payload) == 'table' and type(payload.corp) == 'string' and payload or nil
end

local function onAlert(payload)
	if type(payload) ~= 'table' then return end
	local key = payload.kind == 'detained' and 'corpo.alert.detained' or 'corpo.alert.trespass'
	OPX.Toast.Show({ kind = 'warning', title = locale('corpo.alert.title'), icon = 'shield', durationMs = 10000,
		message = locale(key, { corp = text(payload.corp, 30), label = text(payload.label, 60) }) })
	setWaypoint(payload)
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function targets(place, stage, kind)
	if active == nil or type(active.target) ~= 'table' then return false end
	if stage ~= nil and active.stage ~= stage then return false end
	if kind ~= nil and active.kind ~= kind then return false end
	local target = active.target
	return target.corp == place.corp and target.list == place.list and target.key == place.key
end

local function playerOf(context)
	local subject = type(context) == 'table' and context.target or nil
	local id = type(subject) == 'table' and math.tointeger(tonumber(subject.playerId)) or nil
	return id and id > 0 and id or nil
end

local function refused(placed, what)
	if type(placed) == 'table' and placed.ok then return false end
	OPX.Note('corpo', ('the %s row was refused: %s'):format(what, tostring(type(placed) == 'table' and placed.error or placed)))
	return true
end

local function rowsFor(target, index, place)
	local sphere = { { x = place.x, y = place.y, z = place.z, radius = place.radius } }
	local base = ('corpo.%s.%d'):format(place.list, index)
	if place.list == 'offices' then
		local placed = target.RegisterSpheres(OWNER, sphere, {
			id = base .. '.board', label = locale('corpo.row.board', { corp = place.corpLabel }), icon = 'folder',
			distance = place.radius, order = 30,
			canInteract = function() return role ~= nil and role.corp == place.corp end,
			onSelect = function()
				TriggerServerEvent(M.Event.BOARD, { corp = place.corp, office = place.key })
				return true
			end,
		})
		if refused(placed, 'board') then return false end
		Wait(0)
		placed = target.RegisterSpheres(OWNER, sphere, {
			id = base .. '.deliver', label = locale('corpo.row.deliver', { place = place.label }), icon = 'box',
			distance = place.radius, order = 31,
			canInteract = function()
				return targets(place, 'carry') or (role ~= nil and role.corp == place.corp)
			end,
			onSelect = function()
				TriggerServerEvent(M.Event.DELIVER, { corp = place.corp, list = place.list, place = place.key })
				return true
			end,
		})
		return not refused(placed, 'deliver')
	end
	local spec = { id = base, distance = place.radius, order = 31 }
	if place.list == 'drops' then
		spec.label, spec.icon = locale('corpo.row.deliver', { place = place.label }), 'box'
		spec.canInteract = function() return targets(place, 'carry') end
		spec.onSelect = function()
			TriggerServerEvent(M.Event.DELIVER, { corp = place.corp, list = place.list, place = place.key })
			return true
		end
	elseif place.list == 'terminals' then
		spec.label, spec.icon = locale('corpo.row.retrieve'), 'server'
		spec.canInteract = function() return targets(place, 'goto', 'retrieve') end
		spec.onSelect = function() TriggerServerEvent(M.Event.RETRIEVE, {}) return true end
	else
		spec.label, spec.icon = locale('corpo.row.meet'), 'person'
		spec.canInteract = function() return targets(place, 'goto', 'escort') end
		spec.onSelect = function() TriggerServerEvent(M.Event.MEET, {}) return true end
	end
	return not refused(target.RegisterSpheres(OWNER, sphere, spec), place.list)
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterSpheres) ~= 'function' then
		OPX.Note('corpo', 'no target contract: no office, drop or player rows on the eye')
		return
	end
	if type(target.RegisterPlayers) == 'function' then
		refused(target.RegisterPlayers(OWNER, {
			{
				id = 'corpo.steal', label = locale('corpo.row.steal'), icon = 'hidden', order = 40, distance = 2.0,
				canInteract = function(context) return role ~= nil and playerOf(context) ~= nil end,
				onSelect = function(context)
					local id = playerOf(context)
					if id == nil then return false end
					TriggerServerEvent(M.Event.STEAL, { target = id })
					return true
				end,
			},
			{
				id = 'corpo.detain', label = locale('corpo.row.detain'), icon = 'shield', order = 41, distance = 2.5,
				canInteract = function(context) return role ~= nil and role.security == true and playerOf(context) ~= nil end,
				onSelect = function(context)
					local id = playerOf(context)
					if id == nil then return false end
					TriggerServerEvent(M.Event.DETAIN, { target = id })
					return true
				end,
			},
		}), 'player')
	end
	for index, place in ipairs(places) do
		Wait(0)
		if not rowsFor(target, index, place) then return end
	end
end

-- Builds the places out of the shared config, one corp a resume.
local function build()
	local declared = type(M.Settings.CORPS) == 'table' and M.Settings.CORPS or {}
	local keys = {}
	for key in pairs(declared) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local out = {}
	for _, key in ipairs(keys) do
		local corp = Access.Corp(key, declared[key])
		Wait(0)
		if corp ~= nil then
			for _, list in ipairs({ 'offices', 'drops', 'terminals', 'pickups' }) do
				for _, place in ipairs(corp.lists[list]) do
					out[#out + 1] = { corp = key, corpLabel = corp.label, list = list, key = place.key,
						label = place.label, x = place.x, y = place.y, z = place.z, radius = place.radius }
				end
			end
		end
	end
	places = out
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	places, active, role, board, menuHandle = {}, nil, nil, nil, nil
end

--- Publishes the client half: the assignment and role as last sent.
-- @author dop42
function M.Api()
	OPX.Api.Provide('corpo', 1, {
		--- The assignment as the server last described it, or nil.
		Active = function() return active end,
		--- `{ corp, grade, security }` as the server last said, or nil.
		Role = function() return role end,
	})
end

--- Listens to the server, says hello, and puts the rows on the eye.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.SHOW_BOARD, onBoard)
	RegisterNetEvent(M.Event.ACTIVE, onActive)
	RegisterNetEvent(M.Event.ROLE, onRole)
	RegisterNetEvent(M.Event.ALERT, onAlert)
	CreateThread(function()
		build()
		Wait(0)
		TriggerServerEvent(M.Event.HELLO, {})
		registerRows()
	end)
end

--- Hands the menu and the readout back.
-- @author dop42
function M.Stop()
	closeMenu()
	pcall(OPX.Toast.Dismiss, HUD_ID)
	active, role, board = nil, nil, nil
end
