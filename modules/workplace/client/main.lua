--- Client half: the eye rows at duty points, locker rooms and motor pools, and
--- the menus the server sends for them.
-- @author dop42
--
-- NONE OF IT DECIDES. A duty row asks to clock in or out; a locker room or a
-- motor pool row asks for its menu, and the menu is built from the server's
-- answer (`MENU`) and nothing else, so a row a client invents is a request the
-- server refuses. `canInteract` only keeps rows of other jobs off the eye.
--
-- THE CLIENT BUDGET. Stations are built one a resume through the same
-- `Access.Station` the server runs, and the rows registered one a resume
-- (`modules/fuel/client/main.lua` measured why).

local M = OPX.Modules.Get('workplace')
local Access = M.Access
local Point = M.Point

local OWNER = 'workplace'
local MENU_ID = 'workplace.menu'

-- { station, job, label, kind, x, y, z, radius }
local rows = {}
local menuHandle = nil

local function playerData()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayerData) ~= 'function' then return nil end
	local read, data = pcall(api.GetPlayerData)
	return read and type(data) == 'table' and data or nil
end

--- Whether the eye should list a row of a station of `job` to this character:
--- the duty clock for a held job, the rest for the primary one.
local function mine(job, kind)
	local data = playerData()
	if data == nil or type(data.job) ~= 'table' then return false end
	if data.job.name == job then return true end
	if kind == Point.DUTY then return type(data.jobs) == 'table' and data.jobs[job] ~= nil end
	return false
end

-- ── the menu ────────────────────────────────────────────────────────────────

local function closeMenu()
	local menu = OPX.Api.Get('menu')
	if menuHandle ~= nil and menu ~= nil and type(menu.Close) == 'function' then
		pcall(menu.Close, menuHandle, 'caller')
	end
	menuHandle = nil
end

local function onMenu(payload)
	if type(payload) ~= 'table' or not Access.Key(payload.station) then return end
	local menu = OPX.Api.Get('menu')
	if menu == nil or type(menu.Open) ~= 'function' then
		OPX.Toast.Locale('workplace.error.no_menu', nil, 'error')
		return
	end
	local station = payload.station
	local label = OPX.Text.Clean(tostring(payload.label or ''), 60) or ''
	local list = type(payload.rows) == 'table' and payload.rows or {}
	local items = {}
	local wardrobe = payload.kind == Point.WARDROBE
	for index = 1, math.min(#list, 40) do
		local row = list[index]
		if type(row) == 'table' and Access.Key(row.key) then
			items[#items + 1] = {
				id = ('r%d'):format(index),
				label = OPX.Text.Clean(tostring(row.label), 80) or row.key,
				icon = wardrobe and 'person' or 'vehicle',
				value = row.worn == true and locale('workplace.menu.worn') or nil,
				data = { verb = wardrobe and 'wear' or 'spawn', key = row.key },
				close = true,
			}
		end
	end
	if #items == 0 then
		items[1] = { id = 'empty', label = locale('workplace.menu.empty'), icon = 'info', disabled = true }
	end
	if wardrobe and payload.worn == true then
		items[#items + 1] = { id = 'civvies', label = locale('workplace.menu.civvies'), icon = 'back',
			data = { verb = 'civvies' }, close = true }
	end
	if not wardrobe and type(payload.out) == 'string' then
		items[#items + 1] = { id = 'return', icon = 'back', close = true, data = { verb = 'return' },
			label = locale('workplace.menu.return', { vehicle = OPX.Text.Clean(payload.out, 60) or '' }) }
	end
	closeMenu()
	local opened = menu.Open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor',
		title = locale(wardrobe and 'workplace.menu.wardrobe' or 'workplace.menu.garage', { station = label }),
		items = items,
		on = function(answer)
			local data = type(answer) == 'table' and answer.data or nil
			if type(data) ~= 'table' then return end
			if data.verb == 'wear' then
				TriggerServerEvent(M.Event.WEAR, { station = station, outfit = data.key })
			elseif data.verb == 'spawn' then
				TriggerServerEvent(M.Event.SPAWN, { station = station, vehicle = data.key })
			elseif data.verb == 'civvies' then
				TriggerServerEvent(M.Event.CIVVIES, { station = station })
			elseif data.verb == 'return' then
				TriggerServerEvent(M.Event.RETURN, { station = station })
			end
		end,
	})
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('workplace', ('the menu was refused: %s')
			:format(tostring(type(opened) == 'table' and opened.error or opened)))
		return
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local ROW = {
	[Point.DUTY] = { label = 'workplace.row.duty', icon = 'clock', order = 32 },
	[Point.WARDROBE] = { label = 'workplace.row.wardrobe', icon = 'person', order = 33 },
	[Point.GARAGE] = { label = 'workplace.row.garage', icon = 'vehicle', order = 34 },
}

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterSpheres) ~= 'function' then
		OPX.Note('workplace', 'no target contract: no workplace rows on the eye')
		return
	end
	for index, row in ipairs(rows) do
		local shape = ROW[row.kind]
		local placed = target.RegisterSpheres(OWNER, { { x = row.x, y = row.y, z = row.z, radius = row.radius } }, {
			id = ('workplace.%s.%d'):format(row.kind, index),
			label = locale(shape.label, { station = row.label }),
			icon = shape.icon,
			distance = row.radius,
			order = shape.order,
			canInteract = function() return mine(row.job, row.kind) end,
			onSelect = function()
				if row.kind == Point.DUTY then
					TriggerServerEvent(M.Event.DUTY, { station = row.station })
				else
					TriggerServerEvent(M.Event.ASK, { station = row.station, kind = row.kind })
				end
				return true
			end,
		})
		if type(placed) ~= 'table' or not placed.ok then
			OPX.Note('workplace', ('a workplace row was refused: %s')
				:format(tostring(type(placed) == 'table' and placed.error or placed)))
			return
		end
		Wait(0)
	end
end

-- Builds the rows out of the shared config, one station a resume.
local function build()
	local settings = M.Settings
	local declared = type(settings.STATIONS) == 'table' and settings.STATIONS or {}
	local names = {}
	for name in pairs(declared) do
		if type(name) == 'string' then names[#names + 1] = name end
	end
	table.sort(names)
	local characterConfig = OPX.Config.MODULES.character
	local context = Access.Context(settings, type(characterConfig) == 'table' and characterConfig.JOBS or {}, nil,
		function() Wait(0) end)
	Wait(0)
	local out = {}
	for _, name in ipairs(names) do
		local station = Access.Station(name, declared[name], context)
		if station ~= nil then
			for _, kind in ipairs({ Point.DUTY, Point.WARDROBE, Point.GARAGE }) do
				local point = station.points[kind]
				if point ~= nil then
					out[#out + 1] = { station = name, job = station.job, label = station.label, kind = kind,
						x = point.x, y = point.y, z = point.z, radius = point.radius }
				end
			end
		end
		Wait(0)
	end
	rows = out
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	rows, menuHandle = {}, nil
end

--- Listens to the server and puts the rows on the eye, on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.MENU, onMenu)
	CreateThread(function()
		build()
		Wait(0)
		registerRows()
	end)
end

--- Hands the menu back.
-- @author dop42
function M.Stop()
	closeMenu()
end
