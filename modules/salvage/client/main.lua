--- The eye opens public recovery and the existing durable crafting menu.
-- @author dop42
local M = OPX.Modules.Get('salvage')
local target
function M.Init() target = nil end
function M.Start()
	target = OPX.Api.Get('target')
	local crafting = OPX.Api.Get('crafting')
	if not target or not crafting then return end
	for _, site in ipairs(M.Model.Sites()) do
		local key = site.key
		target.RegisterSpheres('salvage', { { x = site.pickup.x, y = site.pickup.y, z = site.pickup.z, radius = M.Model.Limits().reach } }, {
			id = 'collect_' .. key, label = locale('salvage.collect'), icon = 'tool', distance = M.Model.Limits().reach,
			onSelect = function() TriggerServerEvent(M.Event.COLLECT, key) end,
		})
		Wait(0)
		target.RegisterSpheres('salvage', { { x = site.bench.x, y = site.bench.y, z = site.bench.z, radius = M.Model.Limits().reach } }, {
			id = 'bench_' .. key, label = locale('salvage.bench'), icon = 'tool', distance = M.Model.Limits().reach,
			onSelect = function() crafting.Open(M.PREFIX .. key) end,
		})
		Wait(0)
	end
	RegisterNetEvent(M.Event.NOTICE, function(code)
		if code ~= 'done' and code ~= 'busy' and code ~= 'refused' then return end
		OPX.Toast.Locale('salvage.' .. code, nil, code == 'done' and 'success' or 'error')
	end)
end
function M.Stop()
	if target then target.Clear('salvage') end
end
