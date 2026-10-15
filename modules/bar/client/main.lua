--- Bar, client side: the eye rows, the menus the server fills, the map pins.
-- @author dop42
--
-- THIS HALF DECIDES NOTHING. It draws a sphere on each surveyed counter, stash
-- and supplier, a "serve" row on other players for staff, and the menus the
-- server's VIEW answers fill. Every price, stock count and refusal comes from
-- the server; the venue list is read from the shared config only to place the
-- spheres and pins and to grey out rows for people who are not staff.
--
-- THE BUILD IS LIGHT AND CHUNKED: one venue per resume (`Wait(0)` between),
-- never the server's full `Model.Read`. The client kills a resume past ~10,000
-- instructions.

local M = OPX.Modules.Get('bar')
local Model = M.Model

local OWNER = M.OWNER
local MENU_ID = 'bar.menu'

-- { id, label, jobs, gangs, x, y, z } per surveyed spot kind.
local counters, stashes, supplies = {}, {}, {}
-- venue id -> { jobs, gangs }
local staff = {}
local pins = {}
local menuHandle = nil

local function cfg() return type(M.Settings) == 'table' and M.Settings or {} end

local function radius()
	local value = OPX.Math.Finite(cfg().REACH)
	return value ~= nil and value > 0 and value or 2.5
end

local function money(amount) return OPX.Locale.Money(math.tointeger(amount) or 0) end

-- ── the menu contract ───────────────────────────────────────────────────────

local function closeMenu()
	local api = OPX.Api.Get('menu')
	if menuHandle ~= nil and api ~= nil and type(api.Close) == 'function' then pcall(api.Close, menuHandle, 'caller') end
	menuHandle = nil
end

local function open(spec)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api.Open) ~= 'function' then
		OPX.Toast.Locale('bar.error.no_menu', nil, 'error')
		return nil
	end
	closeMenu()
	local opened = api.Open(spec)
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('bar', ('the %s menu was refused: %s'):format(tostring(spec.id),
			tostring(type(opened) == 'table' and opened.error or opened)))
		return nil
	end
	menuHandle = type(opened.value) == 'table' and opened.value.handle or nil
	return menuHandle
end

local function selected(handler)
	return function(payload)
		if type(payload) ~= 'table' or payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
		handler(payload.data)
	end
end

-- ── the answers ─────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local success = payload.ok == true
	local key = (success and 'bar.answer.' or 'bar.error.') .. payload.code
	if not OPX.Locale.Exists(key) then key = success and 'bar.answer.done' or 'bar.error.unavailable' end
	local raw = type(payload.params) == 'table' and payload.params or {}
	local params = {
		item = type(raw.item) == 'string' and raw.item or '',
		venue = type(raw.venue) == 'string' and raw.venue or '',
		count = math.tointeger(raw.count) or 1,
		price = money(raw.price),
	}
	OPX.Toast.Show({
		id = 'opx.bar.answer',
		kind = success and 'success' or OPX.Result.Kind(payload.code, 'error'),
		title = locale('bar.title'),
		message = locale(key, params),
		icon = 'money',
		durationMs = 5000,
	})
end

-- ── the screens ─────────────────────────────────────────────────────────────

local function counterMenu(view)
	local items = {}
	for index, row in ipairs(type(view.rows) == 'table' and view.rows or {}) do
		if index > 30 then break end
		local parts = {}
		for _, input in ipairs(type(row.inputs) == 'table' and row.inputs or {}) do
			parts[#parts + 1] = locale('bar.menu.input', { label = tostring(input.label),
				have = math.tointeger(input.have) or 0, need = math.tointeger(input.need) or 0 })
		end
		items[#items + 1] = {
			id = 'mix.' .. index, icon = 'plus', label = tostring(row.label),
			value = row.price ~= nil and money(row.price) or nil,
			description = locale('bar.menu.makes', { count = math.tointeger(row.count) or 1,
				ms = math.floor((math.tointeger(row.ms) or 0) / 1000) }) .. ' - ' .. table.concat(parts, ', '),
			disabled = row.ready ~= true,
			data = { recipe = row.key },
		}
	end
	if #items == 0 then items[1] = { id = 'none', label = locale('bar.menu.empty'), disabled = true } end
	local venue = view.venue
	open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor', closeOnSelect = true,
		title = locale('bar.menu.counter', { venue = tostring(view.label) }), items = items,
		on = selected(function(data)
			if type(data.recipe) == 'string' then TriggerServerEvent(M.Event.MIX, venue, data.recipe) end
		end),
	})
end

local function supplyMenu(view)
	local items = {
		{ id = 'funds', icon = 'money', disabled = true,
			label = locale(view.funds == 'account' and 'bar.menu.fundsAccount' or 'bar.menu.fundsPersonal') },
	}
	for index, row in ipairs(type(view.rows) == 'table' and view.rows or {}) do
		if index > 30 then break end
		items[#items + 1] = {
			id = 'buy.' .. index, icon = 'box', label = tostring(row.label), value = money(row.price),
			description = locale('bar.menu.supplyRow', { count = math.tointeger(row.count) or 1,
				stock = math.tointeger(row.stock) or 0 }),
			data = { index = math.tointeger(row.index) },
		}
	end
	local venue = view.venue
	open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor', closeOnSelect = true,
		title = locale('bar.menu.supply', { venue = tostring(view.label) }), items = items,
		on = selected(function(data)
			if math.type(data.index) == 'integer' then TriggerServerEvent(M.Event.BUY, venue, data.index) end
		end),
	})
end

local function serveMenu(view)
	local target = math.tointeger(view.target)
	if target == nil then return end
	local items = {}
	for index, row in ipairs(type(view.rows) == 'table' and view.rows or {}) do
		if index > 30 then break end
		items[#items + 1] = {
			id = 'serve.' .. index, icon = 'money', label = tostring(row.label), value = money(row.price),
			description = locale('bar.menu.held', { held = math.tointeger(row.held) or 0 }),
			data = { item = row.item },
		}
	end
	open({
		owner = OWNER, id = MENU_ID, steal = true, focus = 'cursor', closeOnSelect = true,
		title = locale('bar.menu.serve', { venue = tostring(view.label) }), items = items,
		on = selected(function(data)
			if type(data.item) == 'string' then TriggerServerEvent(M.Event.SERVE, target, data.item) end
		end),
	})
end

local function onView(view)
	if type(view) ~= 'table' or type(view.venue) ~= 'string' then return end
	if view.kind == 'counter' then return counterMenu(view) end
	if view.kind == 'supply' then return supplyMenu(view) end
	if view.kind == 'serve' then return serveMenu(view) end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

--- Whether the local character holds one of a venue's jobs or gangs. A hint
--- for the eye only: the server decides.
local function worksAt(entry)
	if entry == nil then return false end
	local api = OPX.Api.Get('character')
	if api == nil then return false end
	if entry.jobs ~= nil and type(api.GetJobData) == 'function' then
		local read, job = pcall(api.GetJobData)
		if read and type(job) == 'table' and entry.jobs[job.name] then return true end
	end
	if entry.gangs ~= nil and type(api.GetGangData) == 'function' then
		local read, gang = pcall(api.GetGangData)
		if read and type(gang) == 'table' and entry.gangs[gang.name] then return true end
	end
	return false
end

local function worksAnywhere()
	for _, entry in pairs(staff) do
		if worksAt(entry) then return true end
	end
	return false
end

local function nearestOf(list, context)
	local at = type(context) == 'table' and context.position or nil
	if type(at) ~= 'table' or not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y) and OPX.Math.IsFinite(at.z)) then
		return list[1]
	end
	local best, gap = nil, math.huge
	for _, spot in ipairs(list) do
		local dx, dy, dz = at.x - spot.x, at.y - spot.y, at.z - spot.z
		local away = dx * dx + dy * dy + dz * dz
		if away < gap then best, gap = spot, away end
	end
	return best
end

local function customerOf(context)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(target.playerId) or nil
	return id ~= nil and id > 0 and id or nil
end

local function sphereRows(target, list, id, label, icon, order, event)
	if #list == 0 then return end
	local r = radius()
	local spheres = {}
	for _, spot in ipairs(list) do spheres[#spheres + 1] = { x = spot.x, y = spot.y, z = spot.z, radius = r } end
	local rows = target.RegisterSpheres(OWNER, spheres, {
		id = id, label = locale(label), icon = icon, distance = r, order = order,
		canInteract = function(context) return worksAt(staff[(nearestOf(list, context) or {}).id]) end,
		onSelect = function(context)
			local spot = nearestOf(list, context)
			if spot ~= nil then TriggerServerEvent(event, spot.id) end
		end,
	})
	if type(rows) ~= 'table' or not rows.ok then
		OPX.Note('bar', ('the %s rows were refused: %s'):format(id, tostring(type(rows) == 'table' and rows.error)))
	end
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('bar', 'no target contract: the bars are there and unreachable')
		return
	end
	if next(staff) ~= nil then
		local placed = target.RegisterPlayers(OWNER, { {
			id = 'bar.serve', label = locale('bar.row.serve'), icon = 'money', order = 45,
			distance = OPX.Math.Finite(cfg().SERVE_REACH) or 3.0,
			canInteract = function(context) return customerOf(context) ~= nil and worksAnywhere() end,
			onSelect = function(context)
				local customer = customerOf(context)
				if customer == nil then return false end
				TriggerServerEvent(M.Event.SERVE_MENU, customer)
				return true
			end,
		} })
		if type(placed) ~= 'table' or not placed.ok then
			OPX.Note('bar', ('the serve row was refused: %s'):format(tostring(type(placed) == 'table' and placed.error)))
		end
	end
	Wait(0)
	sphereRows(target, counters, 'bar.counter', 'bar.row.counter', 'plus', 22, M.Event.COUNTER)
	Wait(0)
	sphereRows(target, stashes, 'bar.stash', 'bar.row.stash', 'box', 23, M.Event.STASH)
	Wait(0)
	sphereRows(target, supplies, 'bar.supply', 'bar.row.supply', 'money', 24, M.Event.SUPPLY)
end

-- ── the map ─────────────────────────────────────────────────────────────────

local function pin(spot, blip)
	local native = Open77.blips
	if type(native) ~= 'table' or type(native.create) ~= 'function' or type(blip) ~= 'table' then return end
	local options = { position = { x = spot.x, y = spot.y, z = spot.z }, sprite = blip.SPRITE or 'bar',
		title = spot.label, active = true }
	-- The SVG icon and tint only where the client has the native adapter (its
	-- test: `setColor` exists); the sprite alone everywhere else, and again if
	-- this client refuses the icon. The medical module's rule.
	if type(native.setColor) == 'function' then
		if type(blip.ICON) == 'string' and blip.ICON:match('^[%w_%-]+$') then
			options.icon = { asset = 'web/blips/' .. blip.ICON .. '.svg', size = math.tointeger(blip.SIZE) or 48 }
		end
		if type(blip.COLOR) == 'string' then options.color = blip.COLOR end
	end
	local read, id = pcall(native.create, options)
	if (not read or type(id) ~= 'string' or id == '') and (options.icon or options.color) then
		options.icon, options.color = nil, nil
		read, id = pcall(native.create, options)
	end
	if read and type(id) == 'string' and id ~= '' then pins[#pins + 1] = id end
end

-- ── the build ───────────────────────────────────────────────────────────────

local function surveyed(raw)
	return type(raw) == 'table' and not Model.Placeholder(raw) and OPX.Math.IsFinite(raw.X)
		and OPX.Math.IsFinite(raw.Y) and OPX.Math.IsFinite(raw.Z)
end

--- Walks the venues one per resume, keeping the surveyed spots.
local function build()
	counters, stashes, supplies, staff = {}, {}, {}, {}
	for index, raw in ipairs(type(cfg().VENUES) == 'table' and cfg().VENUES or {}) do
		if index > 64 then break end
		local id = type(raw) == 'table' and type(raw.ID) == 'string' and raw.ID or nil
		-- A venue opens with its counter AND its stash; the supplier is extra.
		if id ~= nil and surveyed(raw.COUNTER) and surveyed(raw.STASH) then
			local label = type(raw.LABEL) == 'string' and raw.LABEL or id
			staff[id] = { id = id, jobs = type(raw.JOBS) == 'table' and raw.JOBS or nil,
				gangs = type(raw.GANGS) == 'table' and raw.GANGS or nil }
			local function spot(at) return { id = id, label = label, x = at.X, y = at.Y, z = at.Z } end
			counters[#counters + 1] = spot(raw.COUNTER)
			stashes[#stashes + 1] = spot(raw.STASH)
			if surveyed(raw.SUPPLY) then supplies[#supplies + 1] = spot(raw.SUPPLY) end
			if raw.BLIP ~= false then pin(counters[#counters], raw.BLIP) end
		end
		Wait(0)
	end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	counters, stashes, supplies, staff, pins, menuHandle = {}, {}, {}, {}, {}, nil
end

--- Wires the answers, then builds and registers on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.VIEW, onView)
	CreateThread(function()
		build()
		Wait(0)
		registerRows()
	end)
end

--- Closes the menu, takes the rows and the pins back.
-- @author dop42
function M.Stop()
	closeMenu()
	local target = OPX.Api.Get('target')
	if target ~= nil and type(target.Clear) == 'function' then pcall(target.Clear, OWNER) end
	local native = Open77.blips
	for _, id in ipairs(pins) do
		if type(native) == 'table' and type(native.remove) == 'function' then pcall(native.remove, id) end
	end
	pins = {}
end
