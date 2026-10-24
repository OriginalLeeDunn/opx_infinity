--- Cyberarm model and RGB selection through the existing form surface.
-- @author dop42
--
-- Only the local player's native customization is ever touched. RGB replication
-- to remote puppets is unavailable in op77.152. Restoration retries readiness
-- failures and retains an unavailable saved identifier instead of replacing it.

local M = OPX.Modules.Get('ripperdoc')
local wanted, attempts, job = nil, 0, nil
local generation = 0
local needRestore = false
local menuHandle, formHandle = nil, nil
local function word(key) return locale('ripperdoc.style.' .. key) end
local function api()
	local a = Open77.cyberware
	if type(a) == 'table' and type(a.customizationCatalog) == 'function'
		and type(a.setCustomization) == 'function' and type(a.resetCustomization) == 'function' then return a end
end
local function errorToast() OPX.Toast.Locale('ripperdoc.style.unavailable', nil, 'error') end
local function hex(color)
	return type(color) == 'table' and ('%02X%02X%02X'):format(color.r or 0, color.g or 0, color.b or 0) or 'FFFFFF'
end
local function rgb(value)
	if type(value) ~= 'string' or not value:match('^%x%x%x%x%x%x$') then return nil end
	return { r = tonumber(value:sub(1, 2), 16), g = tonumber(value:sub(3, 4), 16), b = tonumber(value:sub(5, 6), 16) }
end
local function editStyle(row, stamp)
	local form, a = OPX.Api.Get('form'), api()
	if not form or not a then errorToast(); return end
	local saved = type(a.getCustomization) == 'function' and a.getCustomization() or nil
	local opened = form.Open({ owner = 'ripperdoc', id = 'ripperdoc.style', title = word('title'), description = word('scope'),
		fields = {
			{ id = 'primary', label = word('primary'), required = true, maxLength = 6,
				value = hex(saved and saved.primary or (row.colors or {})[(row.defaultPrimary or 0) + 1]), placeholder = 'FFFFFF' },
			{ id = 'secondary', label = word('secondary'), required = true, maxLength = 6,
				value = hex(saved and saved.secondary or (row.colors or {})[(row.defaultSecondary or 0) + 1]), placeholder = 'FFFFFF' },
		},
		on = function(answer)
			if answer.action ~= 'submit' or stamp ~= generation then return end
			local values = answer.values or {}
			local primary, secondary = rgb(values.primary), rgb(values.secondary)
			if not primary or not secondary then
				OPX.Toast.Locale('ripperdoc.style.invalid', nil, 'error'); return
			end
			TriggerServerEvent(M.Event.STYLE, { schemaVersion = 1, enabled = true,
				record = row.record, primary = primary, secondary = secondary })
		end,
	})
	if not opened or not opened.ok then errorToast()
	else formHandle = opened.value.handle end
end
local function show(payload)
	local a, menu = api(), OPX.Api.Get('menu')
	if not a or not menu then errorToast(); return end
	local catalog, reason = a.customizationCatalog()
	if not catalog then errorToast(); OPX.Note('ripperdoc', tostring(reason)); return end
	local stamp, items, records = generation, {}, {}
	for index, row in ipairs(catalog) do
		if row.type == payload.family and (next(payload.records or {}) == nil or payload.records[row.record] == true) then
			records[#records + 1] = row
			items[#items + 1] = { id = 'style.' .. #records, label = OPX.Text.Clean(row.record, 80),
				data = { index = #records } }
		end
		if index % 4 == 0 then Wait(0); if stamp ~= generation then return end end
	end
	if #items == 0 then errorToast(); return end
	local opened = menu.Open({ owner = 'ripperdoc.styles', id = 'ripperdoc.styles', title = word('model'),
		items = items, yield = true, closeOnSelect = true,
		on = function(answer)
			if answer.action ~= 'select' or stamp ~= generation then return end
			local row = type(answer.data) == 'table' and records[answer.data.index] or nil
			if row then editStyle(row, stamp) end
		end,
	})
	if not opened or not opened.ok then errorToast()
	else menuHandle = opened.value.handle end
end
local function clear()
	local menu, form = OPX.Api.Get('menu'), OPX.Api.Get('form')
	if menuHandle and menu then menu.Close(menuHandle, 'character_changed') end
	if formHandle and form then form.Close(formHandle, 'character_changed') end
	menuHandle, formHandle = nil, nil
	generation = generation + 1
	wanted, attempts, needRestore = nil, 0, false
	local a = api()
	if a then a.resetCustomization() end
end
local start, stop = M.Start, M.Stop
function M.Start()
	start()
	RegisterNetEvent(M.Event.STYLE_DATA, function(payload)
		if type(payload) == 'table' then CreateThread(function() show(payload) end) end
	end)
	RegisterNetEvent(M.Event.STYLE_APPLY, function(token, style)
		wanted = nil
		local a = api()
		local ok, reason
		if a then ok, reason = a.setCustomization(style) end
		TriggerServerEvent(M.Event.STYLE_RESULT, token, ok == true)
		if ok ~= true then errorToast(); OPX.Note('ripperdoc', tostring(reason)) end
	end)
	RegisterNetEvent(M.Event.STYLE_RESTORE, function(style)
		wanted, attempts = type(style) == 'table' and style or false, 0
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'loaded'), function()
		clear()
		needRestore = true
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), clear)
	AddEventHandler('open77:playerReset:complete', function() needRestore = true end)
	RegisterCommand('opx.ripperdoc.style', function() TriggerServerEvent(M.Event.STYLE) end, false)
	job = OPX.Scheduler.Every('ripperdoc:style', 1000, function()
		if needRestore then needRestore = false; TriggerServerEvent(M.Event.STYLE, 'restore') end
		if wanted == nil then return end
		local a = api()
		if not a then wanted = nil; return end
		local ok, reason
		if wanted == false then ok, reason = a.resetCustomization() else ok, reason = a.setCustomization(wanted) end
		attempts = attempts + 1
		if ok == true then wanted = nil
		elseif reason ~= 'body_not_ready' and reason ~= 'appearance_editor_open' or attempts >= 30 then
			wanted = nil; errorToast(); OPX.Note('ripperdoc', tostring(reason))
		end
	end)
	CreateThread(function()
		local target = OPX.Api.Get('target')
		if not target then return end
		local stamp = generation
		for key, clinic in pairs(type(M.Settings.CLINICS) == 'table' and M.Settings.CLINICS or {}) do
			local spheres = {}
			for index, chair in ipairs(type(clinic.CHAIRS) == 'table' and clinic.CHAIRS or {}) do
				if not M.Model.Placeholder(chair) and OPX.Math.IsFinite(chair.X)
					and OPX.Math.IsFinite(chair.Y) and OPX.Math.IsFinite(chair.Z) then
					spheres[#spheres + 1] = { x = chair.X, y = chair.Y, z = chair.Z, radius = chair.RADIUS or 1.5 }
				end
				if index % 4 == 0 then Wait(0); if stamp ~= generation then return end end
			end
			if #spheres > 0 then
				target.RegisterSpheres('ripperdoc.styles', spheres, { id = 'ripperdoc.style.' .. tostring(key),
					label = word('row'), icon = 'bolt', distance = 2.0,
					onSelect = function() TriggerServerEvent(M.Event.STYLE) end })
			end
			Wait(0)
			if stamp ~= generation then return end
		end
	end)
	TriggerServerEvent(M.Event.STYLE, 'restore')
end
function M.Stop()
	if job then OPX.Scheduler.Cancel(job); job = nil end
	clear()
	local target = OPX.Api.Get('target')
	if target then target.Clear('ripperdoc.styles') end
	stop()
end
