--- Client half: the eye rows at access points and brokers, the run's menu, the
--- trace readout and the NCPD alert.
-- @author dop42
--
-- NONE OF IT DECIDES. An access point's row asks to jack in, the menu sends
-- which daemon on which node, a broker's row asks to sell; the server measures
-- the reach, rolls the breach, holds the RAM and the trace, and sends back the
-- session it wants drawn (`STATE`). The menu is rebuilt from that payload and
-- nothing else, so a row a client invents is a request the server refuses.
--
-- THE CLIENT BUDGET. The rows are registered on a thread of their own, ONE
-- ROW A RESUME (`modules/fuel/client/main.lua` measured why), and the
-- network list is built one network a resume through the same `Access.Build`
-- the server runs.

local M = OPX.Modules.Get('netrunner')
local Access = M.Access

local OWNER = 'netrunner'
local MENU_ID = 'netrunner.run'
local HUD_ID = 'opx.netrunner.hud'

-- { network, node, label, x, y, z, radius } and { key, label, x, y, z, radius }.
local accessPoints, brokers = {}, {}
local state = nil
local menuHandle = nil
local menuPending, menuWorking = nil, false
local menuGeneration, stopped = 0, false

local function title()
	return locale('netrunner.title')
end

-- ── the run's menu ──────────────────────────────────────────────────────────

local function closeMenu()
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end

--- Opens the run's menu from the last state the server sent.
-- @author dop42
-- @return boolean
local function buildRun(state, generation)
	if state == nil or state.phase ~= 'connected' then return false end
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		OPX.Toast.Locale('netrunner.error.no_menu', nil, 'error')
		return false
	end
	local items = {}
	local ram = math.tointeger(state.ram) or 0
	local daemons = type(state.daemons) == 'table' and state.daemons or {}
	for index = 1, math.min(#daemons, 40) do
		local row = daemons[index]
		if type(row) == 'table' and type(row.node) == 'string' and type(row.daemon) == 'string' then
			local cost = math.tointeger(row.ram) or 0
			items[#items + 1] = {
				id = ('d%d'):format(index),
				label = OPX.Text.Clean(('%s - %s'):format(tostring(row.label), tostring(row.nodeLabel)), 90) or row.daemon,
				icon = row.effect == 'door' and 'door' or row.effect == 'cameras' and 'eye'
					or row.effect == 'shard' and 'folder' or row.effect == 'wipe' and 'trash' or 'bolt',
				value = locale('netrunner.menu.ram', { ram = cost }),
				disabled = cost > ram or state.busy == true,
				data = { verb = 'daemon', node = row.node, daemon = row.daemon },
				close = true,
			}
		end
		if index % 4 == 0 then
			Wait(0)
			if stopped or generation ~= menuGeneration then return false end
		end
	end
	items[#items + 1] = { id = 'out', label = locale('netrunner.menu.jackOut'), icon = 'back',
		data = { verb = 'out' }, close = true }
	Wait(0)
	if stopped or generation ~= menuGeneration then return false end
	closeMenu()
	local opened = menu.Open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = OPX.Text.Clean(tostring(state.label or title()), 60) or title(),
		items = items, yield = true,
		on = function(payload)
			local data = type(payload) == 'table' and payload.data or nil
			if type(data) ~= 'table' then return end
			if data.verb == 'daemon' then
				TriggerServerEvent(M.Event.DAEMON, { node = data.node, daemon = data.daemon })
			elseif data.verb == 'out' then
				TriggerServerEvent(M.Event.JACK_OUT, {})
			end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('netrunner', ('the run menu was refused: %s')
			:format(tostring(type(opened) == 'table' and opened.error or opened)))
		return false
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	if stopped or generation ~= menuGeneration then
		closeMenu()
		return false
	end
	return true
end

-- One worker serializes paced menu builds; replies received during a build
-- replace its pending snapshot instead of opening competing menu instances.
function M.OpenRun()
	if stopped or state == nil or state.phase ~= 'connected' then return false end
	menuGeneration = menuGeneration + 1
	menuPending = state
	if menuWorking then return true end
	menuWorking = true
	CreateThread(function()
		while menuPending ~= nil and not stopped do
			local pending, generation = menuPending, menuGeneration
			menuPending = nil
			Wait(0)
			if not stopped and generation == menuGeneration then
				local ok, why = pcall(buildRun, pending, generation)
				if not ok then OPX.Note('netrunner', 'the run menu could not be drawn: ' .. tostring(why)) end
			end
		end
		menuWorking = false
	end)
	return true
end

-- ── what the server says ────────────────────────────────────────────────────

local function onState(payload)
	if type(payload) ~= 'table' then return end
	if payload.phase == 'offline' then
		menuGeneration = menuGeneration + 1
		menuPending = nil
		state = nil
		closeMenu()
		OPX.Toast.Dismiss(HUD_ID)
		return
	end
	state = payload
	local trace = math.tointeger(payload.trace) or 0
	local message
	if payload.phase == 'breach' then
		message = locale('netrunner.hud.breach', { ice = tostring(payload.ice or ''), trace = trace })
	else
		message = locale('netrunner.hud.connected', { ram = math.tointeger(payload.ram) or 0,
			max = math.tointeger(payload.ramMax) or 0, trace = trace })
	end
	OPX.Toast.Show({ id = HUD_ID, kind = trace >= 70 and 'warning' or 'info', title = title(),
		message = message, icon = 'server', durationMs = 3000 })
	if payload.open == true then M.OpenRun() end
end

local function onAlert(payload)
	if type(payload) ~= 'table' then return end
	local label = OPX.Text.Clean(tostring(payload.label or ''), 64) or ''
	local runner = type(payload.runner) == 'string' and OPX.Text.Clean(payload.runner, 64) or nil
	local key = payload.level == 'traced' and 'netrunner.alert.traced' or 'netrunner.alert.suspicious'
	if runner ~= nil and runner ~= '' then key = key .. 'Named' end
	OPX.Toast.Show({ kind = 'warning', title = locale('netrunner.alert.title'),
		message = locale(key, { network = label, runner = runner or '' }), icon = 'warning', durationMs = 10000 })
	local x, y, z = OPX.Math.Finite(payload.x), OPX.Math.Finite(payload.y), OPX.Math.Finite(payload.z)
	local blips = Open77.blips
	if x ~= nil and y ~= nil and z ~= nil and type(blips) == 'table' and type(blips.setWaypoint) == 'function' then
		pcall(blips.setWaypoint, { x = x, y = y, z = z })
	end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterSpheres) ~= 'function' then
		OPX.Note('netrunner', 'no target contract: no access point or broker rows on the eye')
		return
	end
	for index, point in ipairs(accessPoints) do
		local placed = target.RegisterSpheres(OWNER, { { x = point.x, y = point.y, z = point.z, radius = point.radius } }, {
			id = ('netrunner.ap.%d'):format(index),
			label = locale('netrunner.row.jackIn', { network = point.label }),
			icon = 'server',
			distance = point.radius,
			order = 30,
			onSelect = function()
				-- Jacked in already: the row reopens the run's menu.
				if state ~= nil then
					if state.phase == 'connected' then return M.OpenRun() end
					return false
				end
				TriggerServerEvent(M.Event.JACK_IN, { network = point.network, node = point.node })
				return true
			end,
		})
		if type(placed) ~= 'table' or not placed.ok then
			OPX.Note('netrunner', ('an access point row was refused: %s')
				:format(tostring(type(placed) == 'table' and placed.error or placed)))
			return
		end
		Wait(0)
	end
	for index, broker in ipairs(brokers) do
		local placed = target.RegisterSpheres(OWNER, { { x = broker.x, y = broker.y, z = broker.z, radius = broker.radius } }, {
			id = ('netrunner.broker.%d'):format(index),
			label = locale('netrunner.row.sell', { broker = broker.label }),
			icon = 'money',
			distance = broker.radius,
			order = 31,
			onSelect = function()
				TriggerServerEvent(M.Event.SELL, { broker = broker.key })
				return true
			end,
		})
		if type(placed) ~= 'table' or not placed.ok then return end
		Wait(0)
	end
end

-- Builds the rows out of the shared config, one network a resume.
local function build()
	local declared = type(M.Settings.NETWORKS) == 'table' and M.Settings.NETWORKS or {}
	local keys = {}
	for key in pairs(declared) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	local context = Access.Context(M.Settings, nil, function() Wait(0) end)
	Wait(0)
	local points = {}
	for _, key in ipairs(keys) do
		local network, _, disabled = Access.Network(key, declared[key], context)
		if network ~= nil and not disabled then
			for _, nodeKey in ipairs(network.accessPoints) do
				local node = network.nodes[nodeKey]
				points[#points + 1] = { network = key, node = nodeKey, label = network.label,
					x = node.x, y = node.y, z = node.z, radius = node.radius }
			end
		end
		Wait(0)
	end
	accessPoints = points
	brokers = Access.Build({ BROKERS = M.Settings.BROKERS }).brokers
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	accessPoints, brokers, state, menuHandle = {}, {}, nil, nil
	menuPending, menuWorking, stopped = nil, false, false
	menuGeneration = menuGeneration + 1
end

--- Publishes the client half: the run as last sent, and the menu.
-- @author dop42
function M.Api()
	OPX.Api.Provide('netrunner', 1, {
		--- The run as the server last described it, or nil.
		State = function() return state end,
		OpenRun = M.OpenRun,
	})
end

--- Listens to the server and puts the rows on the eye, on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.ALERT, onAlert)
	CreateThread(function()
		build()
		Wait(0)
		registerRows()
	end)
end

--- Hands the menu and the readout back.
-- @author dop42
function M.Stop()
	stopped = true
	menuGeneration = menuGeneration + 1
	menuPending = nil
	closeMenu()
	pcall(OPX.Toast.Dismiss, HUD_ID)
	state = nil
end
