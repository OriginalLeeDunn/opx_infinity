--- The clinic, client side: the eye rows, the chart, the consent prompt, the terminal.
-- @author dop42
--
-- THIS HALF DECIDES NOTHING. It draws three kinds of eye row -- a "chart" row
-- on other players for a ripperdoc, a sphere on each clinic stash, a sphere on
-- each wholesale terminal -- and the menus the server's answers fill. Every
-- price, every refusal and every greyed-out row comes from the server's CHART
-- answer; the terminal's catalogue is read from the shared config only to be
-- drawn, and the server re-reads the row it is asked to sell.
--
-- THE BUILD IS LIGHT AND CHUNKED. The client never runs the model's full
-- `Read`: it walks the clinics one per resume (`Wait(0)` between), takes the
-- surveyed stash and terminal positions and the catalogue labels, and nothing
-- else. The client kills a resume past ~10,000 instructions.

local M = OPX.Modules.Get('ripperdoc')
local Model = M.Model

local OWNER = 'ripperdoc'
local CHART_MENU = 'ripperdoc.chart'
local INVITE_MENU = 'ripperdoc.invite'
local SUPPLY_MENU = 'ripperdoc.supply'

local stashes, terminals, jobs = {}, {}, {}
local invite = nil
local menuHandle = nil

local function cfg() return type(M.Settings) == 'table' and M.Settings or {} end

local function radius()
	local value = OPX.Math.Finite(cfg().PROMPT_RADIUS)
	return value ~= nil and value > 0 and value or 2.0
end

local function chromeLabel(key)
	local chrome = type(cfg().CHROME) == 'table' and cfg().CHROME[key] or nil
	return type(chrome) == 'table' and type(chrome.LABEL) == 'string' and chrome.LABEL or tostring(key)
end

local function money(amount) return OPX.Locale.Money(math.tointeger(amount) or 0) end

local function percent(value) return ('%d%%'):format(math.floor((OPX.Math.Finite(value) or 0) * 100 + 0.5)) end

-- ── the menu contract ───────────────────────────────────────────────────────

local function menuApi()
	local api = OPX.Api.Get('menu')
	return api ~= nil and type(api.Open) == 'function' and api or nil
end

local function closeMenu(handle)
	local api = OPX.Api.Get('menu')
	if handle ~= nil and api ~= nil and type(api.Close) == 'function' then pcall(api.Close, handle, 'caller') end
end

local function open(spec)
	local api = menuApi()
	if api == nil then
		OPX.Toast.Locale('ripperdoc.error.no_menu', nil, 'error')
		return nil
	end
	local opened = api.Open(spec)
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('ripperdoc', ('the %s menu was refused: %s'):format(tostring(spec.id),
			tostring(type(opened) == 'table' and opened.error or opened)))
		return nil
	end
	return type(opened.value) == 'table' and opened.value.handle or nil
end

-- ── the answers ─────────────────────────────────────────────────────────────

local function onAnswer(payload)
	if type(payload) ~= 'table' or type(payload.code) ~= 'string' then return end
	local ok = payload.ok == true
	local key = (ok and 'ripperdoc.answer.' or 'ripperdoc.error.') .. payload.code
	if not OPX.Locale.Exists(key) then
		key = (payload.code == 'failed' and 'ripperdoc.error.failed') or (ok and 'ripperdoc.answer.done')
			or 'ripperdoc.error.invalid'
	end
	local params = {
		chrome = type(payload.chrome) == 'string' and payload.chrome or '',
		price = money(payload.price), cost = money(payload.cost), fee = money(payload.fee),
		refund = money(payload.refund), tier = math.tointeger(payload.tier) or 0,
		humanity = math.floor(OPX.Math.Finite(payload.humanity) or 0),
	}
	local message = locale(key, params)
	if type(payload.outcome) == 'string' and payload.outcome:match('^[%w_]+$') then
		local outcomeKey = 'ripperdoc.outcome.' .. payload.outcome
		message = message .. ' ' .. locale(OPX.Locale.Exists(outcomeKey) and outcomeKey or 'ripperdoc.outcome.other')
	end
	OPX.Toast.Show({
		id = 'opx.ripperdoc.answer',
		kind = ok and 'success' or OPX.Result.Kind(payload.code, 'error'),
		title = locale('ripperdoc.title'),
		message = message,
		icon = 'heal',
		durationMs = 5000,
	})
end

-- ── the chart (the doc's menu) ──────────────────────────────────────────────

local function sourceLabel(row)
	return locale('ripperdoc.source.' .. tostring(row.source))
end

local function installRows(chart)
	local rows = {}
	for index, row in ipairs(type(chart.installs) == 'table' and chart.installs or {}) do
		if index > 40 then break end
		local label = ('%s T%d - %s'):format(tostring(row.label), math.tointeger(row.tier) or 1, sourceLabel(row))
		local description = locale('ripperdoc.menu.quote', { humanity = math.floor(OPX.Math.Finite(row.humanity) or 0),
			risk = percent(row.risk), origin = locale('ripperdoc.origin.' .. tostring(row.origin)) })
		if type(row.blocked) == 'string' then
			description = locale(OPX.Locale.Exists('ripperdoc.error.' .. row.blocked) and ('ripperdoc.error.' .. row.blocked)
				or 'ripperdoc.error.invalid')
		end
		rows[#rows + 1] = {
			id = 'install.' .. index, label = label, icon = 'plus', value = money(row.total),
			description = description, disabled = row.blocked ~= nil,
			data = { action = 'install', chrome = row.chrome, tier = row.tier, origin = row.origin,
				source = row.source, slot = row.slot },
		}
	end
	if #rows == 0 then
		rows[1] = { id = 'install.none', label = locale('ripperdoc.menu.noStock'), disabled = true }
	end
	return rows
end

local function removalRows(chart)
	local rows = {}
	for index, row in ipairs(type(chart.removals) == 'table' and chart.removals or {}) do
		local description = locale('ripperdoc.menu.removeQuote', {
			humanity = math.floor(OPX.Math.Finite(row.humanity) or 0), risk = percent(row.risk) })
		if type(row.blocked) == 'string' then description = locale('ripperdoc.error.unknown_chrome') end
		rows[#rows + 1] = {
			id = 'remove.' .. index,
			label = ('%s T%d'):format(tostring(row.label), math.tointeger(row.tier) or 1),
			icon = 'minus', value = money(row.total), description = description,
			disabled = row.blocked ~= nil,
			data = { action = 'remove', serial = row.serial, slot = row.slot },
		}
	end
	if #rows == 0 then
		rows[1] = { id = 'remove.none', label = locale('ripperdoc.menu.nothingInstalled'), disabled = true }
	end
	return rows
end

local function onChart(chart)
	if type(chart) ~= 'table' or math.type(chart.patient) ~= 'integer' then return end
	local patient = chart.patient
	local installed = {}
	for index, row in ipairs(type(chart.installed) == 'table' and chart.installed or {}) do
		installed[#installed + 1] = { id = 'body.' .. index, icon = 'bolt', disabled = true,
			label = ('%s T%d'):format(tostring(row.label), math.tointeger(row.tier) or 1),
			value = tostring(row.slot),
			description = locale('ripperdoc.menu.implant', { serial = tostring(row.serial or '-'),
				condition = math.floor(OPX.Math.Finite(row.condition) or 100) }) }
	end
	if #installed == 0 then
		installed[1] = { id = 'body.none', label = locale('ripperdoc.menu.nothingInstalled'), disabled = true }
	end
	local items = {
		{ id = 'humanity', icon = 'heart', disabled = true, label = locale('ripperdoc.menu.humanity'),
			value = tostring(math.floor(OPX.Math.Finite(chart.humanity) or 0)) },
		{ id = 'capacity', icon = 'gear', disabled = true, label = locale('ripperdoc.menu.capacity'),
			value = ('%s / %s'):format(tostring(math.floor(OPX.Math.Finite(chart.capacity) or 0)),
				tostring(math.floor(OPX.Math.Finite(chart.maxCapacity) or 0))) },
		{ id = 'installed', icon = 'eye', label = locale('ripperdoc.menu.installed'), items = installed },
	}
	local services = type(chart.services) == 'table' and chart.services or {}
	if services.install then
		items[#items + 1] = { id = 'install', icon = 'plus', label = locale('ripperdoc.menu.install'),
			items = installRows(chart) }
	end
	if services.remove then
		items[#items + 1] = { id = 'remove', icon = 'minus', label = locale('ripperdoc.menu.remove'),
			items = removalRows(chart) }
	end
	closeMenu(menuHandle)
	menuHandle = open({
		owner = OWNER, id = CHART_MENU, steal = true, focus = 'cursor', closeOnSelect = true,
		title = type(chart.label) == 'string' and chart.label or locale('ripperdoc.title'),
		items = items,
		on = function(payload)
			if type(payload) ~= 'table' or payload.action ~= 'select' then return end
			local data = type(payload.data) == 'table' and payload.data or nil
			if data == nil or (data.action ~= 'install' and data.action ~= 'remove') then return end
			local request = { patient = patient }
			for key, value in pairs(data) do request[key] = value end
			TriggerServerEvent(M.Event.PROPOSE, request)
		end,
	})
end

-- ── the consent (the patient's prompt) ──────────────────────────────────────

local function reply(accepted)
	if invite == nil then return end
	local id = invite.id
	closeMenu(invite.handle)
	invite = nil
	TriggerServerEvent(M.Event.CONSENT, id, accepted == true)
end

local function onInvite(payload)
	if type(payload) ~= 'table' or type(payload.id) ~= 'string' or #payload.id > 40 then return end
	if invite ~= nil then closeMenu(invite.handle) end
	invite = { id = payload.id }
	local what = locale(payload.action == 'remove' and 'ripperdoc.invite.remove' or 'ripperdoc.invite.install', {
		chrome = tostring(payload.chrome), tier = math.tointeger(payload.tier) or 1,
		clinic = tostring(payload.clinic) })
	local terms = locale('ripperdoc.invite.terms', { price = money(payload.price),
		method = locale('ripperdoc.method.' .. tostring(payload.method)),
		humanity = math.floor(OPX.Math.Finite(payload.humanity) or 0), risk = percent(payload.risk) })
	OPX.Toast.Show({ id = 'opx.ripperdoc.invite', kind = 'info', title = locale('ripperdoc.title'),
		message = what .. ' ' .. terms, icon = 'heal', durationMs = math.tointeger(payload.ms) or 30000 })
	local handle = open({
		owner = OWNER, id = INVITE_MENU, steal = true, focus = 'cursor', closeOnSelect = true, cursor = 'accept',
		title = locale('ripperdoc.invite.title'),
		items = {
			{ id = 'what', label = what, icon = 'heal', disabled = true, description = terms },
			{ id = 'accept', label = locale('ripperdoc.invite.accept'), icon = 'heal',
				data = { accept = true } },
			{ id = 'decline', label = locale('ripperdoc.invite.decline'), icon = 'ban',
				data = { accept = false } },
		},
		on = function(menu)
			if type(menu) ~= 'table' or invite == nil then return end
			if menu.action == 'select' and type(menu.data) == 'table' then reply(menu.data.accept == true) end
		end,
	})
	if invite ~= nil then invite.handle = handle end
end

local function onUninvite(id)
	if invite == nil or invite.id ~= id then return end
	closeMenu(invite.handle)
	invite = nil
	OPX.Toast.Locale('ripperdoc.invite.withdrawn', nil, 'info')
end

-- ── the terminal ────────────────────────────────────────────────────────────

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

local function openSupply(terminal)
	if terminal == nil then return false end
	local rows = {}
	for _, row in ipairs(terminal.catalog) do
		rows[#rows + 1] = {
			id = 'row.' .. row.index, icon = 'box',
			label = ('%s T%d'):format(chromeLabel(row.chrome), row.tier), value = money(row.cost),
			description = locale('ripperdoc.supply.row', { origin = locale('ripperdoc.origin.' .. row.origin),
				grade = row.grade }),
			data = { index = row.index },
		}
	end
	closeMenu(menuHandle)
	menuHandle = open({
		owner = OWNER, id = SUPPLY_MENU, steal = true, focus = 'cursor', closeOnSelect = true,
		title = locale('ripperdoc.supply.title', { clinic = terminal.label }),
		items = rows,
		on = function(payload)
			if type(payload) ~= 'table' or payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
			TriggerServerEvent(M.Event.SUPPLY, terminal.key, payload.data.index)
		end,
	})
	return menuHandle ~= nil
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function worksHere()
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetJobData) ~= 'function' then return false end
	local read, job = pcall(api.GetJobData)
	return read and type(job) == 'table' and jobs[job.name] == true
end

local function patientOf(context)
	local target = type(context) == 'table' and context.target or nil
	local id = type(target) == 'table' and math.tointeger(target.playerId) or nil
	return id ~= nil and id > 0 and id or nil
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil then
		OPX.Note('ripperdoc', 'no target contract: the clinics are there and unreachable')
		return
	end
	local reach = OPX.Math.Finite(cfg().DOC_REACH) or 3.0
	local placed = target.RegisterPlayers(OWNER, { {
		id = 'ripperdoc.chart', label = locale('ripperdoc.row.chart'), icon = 'heal', order = 40,
		distance = reach,
		canInteract = function(context) return patientOf(context) ~= nil and worksHere() end,
		onSelect = function(context)
			local patient = patientOf(context)
			if patient == nil then return false end
			TriggerServerEvent(M.Event.CHART, patient)
			return true
		end,
	} })
	if type(placed) ~= 'table' or not placed.ok then
		OPX.Note('ripperdoc', ('the chart row was refused: %s'):format(tostring(type(placed) == 'table' and placed.error)))
	end
	Wait(0)
	local r = radius()
	if #stashes > 0 then
		local spheres = {}
		for _, spot in ipairs(stashes) do spheres[#spheres + 1] = { x = spot.x, y = spot.y, z = spot.z, radius = r } end
		local rows = target.RegisterSpheres(OWNER, spheres, {
			id = 'ripperdoc.stash', label = locale('ripperdoc.row.stash'), icon = 'box', distance = r, order = 20,
			canInteract = worksHere,
			onSelect = function(context)
				local spot = nearestOf(stashes, context)
				if spot ~= nil then TriggerServerEvent(M.Event.STASH, spot.key) end
			end,
		})
		if type(rows) ~= 'table' or not rows.ok then
			OPX.Note('ripperdoc', ('the stash rows were refused: %s'):format(tostring(type(rows) == 'table' and rows.error)))
		end
		Wait(0)
	end
	if #terminals > 0 then
		local spheres = {}
		for _, spot in ipairs(terminals) do spheres[#spheres + 1] = { x = spot.x, y = spot.y, z = spot.z, radius = r } end
		local rows = target.RegisterSpheres(OWNER, spheres, {
			id = 'ripperdoc.supply', label = locale('ripperdoc.row.supply'), icon = 'money', distance = r, order = 21,
			canInteract = worksHere,
			onSelect = function(context) return openSupply(nearestOf(terminals, context)) end,
		})
		if type(rows) ~= 'table' or not rows.ok then
			OPX.Note('ripperdoc', ('the terminal rows were refused: %s'):format(tostring(type(rows) == 'table' and rows.error)))
		end
	end
end

--- Walks the clinics one per resume, keeping the surveyed stash and terminal spots.
local function build()
	stashes, terminals, jobs = {}, {}, {}
	local clinics = type(cfg().CLINICS) == 'table' and cfg().CLINICS or {}
	local keys = {}
	for key in pairs(clinics) do
		if type(key) == 'string' then keys[#keys + 1] = key end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local raw = clinics[key]
		if type(raw) == 'table' then
			for name in pairs(type(raw.JOBS) == 'table' and raw.JOBS or {}) do
				if type(name) == 'string' then jobs[name] = true end
			end
			local label = type(raw.LABEL) == 'string' and raw.LABEL or key
			local chest = raw.CHEST
			if type(chest) == 'table' and not Model.Placeholder(chest) and OPX.Math.IsFinite(chest.X)
				and OPX.Math.IsFinite(chest.Y) and OPX.Math.IsFinite(chest.Z) then
				stashes[#stashes + 1] = { key = key, label = label, x = chest.X, y = chest.Y, z = chest.Z }
			end
			local supply = raw.SUPPLY
			if type(supply) == 'table' and not Model.Placeholder(supply) and OPX.Math.IsFinite(supply.X)
				and OPX.Math.IsFinite(supply.Y) and OPX.Math.IsFinite(supply.Z) then
				local catalog = {}
				for index, row in ipairs(type(supply.CATALOG) == 'table' and supply.CATALOG or {}) do
					if type(row) == 'table' and type(row.CHROME) == 'string' and index <= 60 then
						catalog[#catalog + 1] = { index = index, chrome = row.CHROME,
							tier = math.tointeger(row.TIER) or 1, cost = math.tointeger(row.COST) or 0,
							grade = math.tointeger(row.GRADE) or math.tointeger(raw.STOCK_GRADE) or 0,
							origin = row.ORIGIN == 'black' and 'black'
								or (row.ORIGIN == nil and raw.LICENSED == false and 'black' or 'legit') }
					end
				end
				if #catalog > 0 then
					terminals[#terminals + 1] = { key = key, label = label, x = supply.X, y = supply.Y, z = supply.Z,
						catalog = catalog }
				end
			end
		end
		Wait(0)
	end
	if next(jobs) == nil then jobs.ripperdoc = true end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	stashes, terminals, jobs, invite, menuHandle = {}, {}, {}, nil, nil
end

--- Wires the answers, then builds and registers on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.CHART_DATA, onChart)
	RegisterNetEvent(M.Event.INVITE, onInvite)
	RegisterNetEvent(M.Event.UNINVITE, onUninvite)
	CreateThread(function()
		build()
		Wait(0)
		registerRows()
	end)
end

--- Closes what is open and takes the rows back.
-- @author dop42
function M.Stop()
	if invite ~= nil then closeMenu(invite.handle) end
	closeMenu(menuHandle)
	invite, menuHandle = nil, nil
	local target = OPX.Api.Get('target')
	if target ~= nil and type(target.Clear) == 'function' then pcall(target.Clear, OWNER) end
end
