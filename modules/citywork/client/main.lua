--- The service desk asks; contracts owns the active gig and map destination.
-- @author dop42
local M = OPX.Modules.Get('citywork')
local built, target, menu, handle
local generation, stopped = 0, true
local function request(action, job, professional)
	TriggerServerEvent(M.Event.REQUEST, { action = action, job = job, professional = professional })
end
local function show(payload)
	if type(payload) ~= 'table' or stopped then return end
	generation = generation + 1
	local current = generation
	CreateThread(function()
		local items = {}
		local active = type(payload.active) == 'table' and payload.active or nil
		if active then
			items[#items + 1] = { id = 'active', icon = 'folder', disabled = true,
				label = locale('citywork.active', { job = locale('citywork.' .. active.job), place = locale('citywork.route.' .. active.route) }),
				description = locale('citywork.pay', { amount = OPX.Locale.Money(active.pay) }) }
			items[#items + 1] = { id = 'navigate', icon = 'location', label = locale('citywork.navigate'), data = { action = 'navigate' }, close = true }
			items[#items + 1] = { id = 'complete', icon = 'tool', label = locale('citywork.complete'), data = { action = 'complete' }, close = true }
			items[#items + 1] = { id = 'abandon', icon = 'trash', label = locale('citywork.abandon'), data = { action = 'abandon' }, close = true, confirm = true }
		else
			for _, job in ipairs({ 'courier', 'technician' }) do
				local name = locale('citywork.' .. job)
				items[#items + 1] = { id = job .. '.free', icon = 'folder', label = locale('citywork.freelance', { job = name }),
					data = { action = 'start', job = job, professional = false }, close = true }
				items[#items + 1] = { id = job .. '.pro', icon = 'tool', label = locale('citywork.professional', { job = name }),
					data = { action = 'start', job = job, professional = true }, close = true }
				if payload.canEnrol then
					items[#items + 1] = { id = job .. '.enrol', icon = 'person', label = locale('citywork.enrol', { job = name }),
						data = { action = 'enrol', job = job }, close = true, confirm = true }
				end
				Wait(0)
			end
		end
		Wait(0)
		if stopped or generation ~= current or not menu then return end
		if handle then menu.Close(handle, 'caller') end
		local opened = menu.Open({ owner = 'citywork', id = 'citywork.desk', title = locale('citywork.title'),
			focus = 'cursor', steal = true, items = items,
			on = function(message)
				local data = type(message) == 'table' and message.data
				if type(data) ~= 'table' then return end
				if data.action == 'navigate' and active and type(active.point) == 'table' then
					local native = Open77.blips
					if type(native) == 'table' and type(native.setWaypoint) == 'function' then
						local ok, placed = pcall(native.setWaypoint, active.point)
						if not ok or not placed then OPX.Toast.Locale('citywork.error.generic', nil, 'error') end
					end
				elseif data.action == 'abandon' and active then
					TriggerServerEvent(OPX.Event(OPX.Channel.NET, 'contracts', 'act'), { verb = 'abandon', id = active.id })
				else request(data.action, data.job, data.professional) end
			end,
		})
		if opened.ok then handle = opened.value.handle else OPX.Toast.Locale('citywork.error.generic', nil, 'error') end
	end)
end
function M.Init()
	built = nil
	generation, stopped, handle = 0, false, nil
end
function M.Start()
	built = M.Model.Build(OPX.Config.MODULES.citywork, function() Wait(0) end)
	Wait(0)
	menu, target = OPX.Api.Get('menu'), OPX.Api.Get('target')
	RegisterNetEvent(M.Event.VIEW, show)
	if not built or not target then return end
	target.RegisterSpheres('citywork', { { x = built.dispatch.x, y = built.dispatch.y, z = built.dispatch.z, radius = built.reach } }, {
		id = 'citywork.desk', label = locale('citywork.open'), icon = 'folder', distance = built.reach,
		onSelect = function() request('view') end,
	})
	Wait(0)
	for _, key in ipairs(built.order) do
		local at = built.routes[key]
		target.RegisterSpheres('citywork', { { x = at.x, y = at.y, z = at.z, radius = built.reach } }, {
			id = 'citywork.service.' .. key, label = locale('citywork.complete'), icon = 'tool', distance = built.reach,
			onSelect = function() request('complete') end,
		})
		Wait(0)
	end
end
function M.Stop()
	stopped = true
	generation = generation + 1
	if target then target.Clear('citywork') end
	if handle and menu then menu.Close(handle, 'caller') end
	handle = nil
end
