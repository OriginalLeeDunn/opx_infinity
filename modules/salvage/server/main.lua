--- Server collection reservation and persistent, globally depleted stock.
-- @author dop42
-- A callback claims its reservation before yielding. Grants target the captured
-- citizen id, never a recycled connection slot. Crafting handles input escrow,
-- durable timers and retryable output collection for the recycling stage.
local M = OPX.Modules.Get('salvage')
local sites, pending, character, inventory, progress, crafting, stopped
local function citizen(player)
	local loaded = character.GetPlayer(player)
	return loaded and loaded.PlayerData and loaded.PlayerData.citizenId
end
local function near(player, at)
	if OPX.Life.Down(player) then return false end
	local snap = Open77.players.get(player)
	if type(snap) ~= 'table' or snap.fresh ~= true or snap.bucket ~= at.bucket then return false end
	local pos = snap.position
	if type(pos) ~= 'table' then return false end
	local x, y, z = OPX.Math.Finite(pos.x), OPX.Math.Finite(pos.y), OPX.Math.Finite(pos.z)
	if not x or not y or not z then return false end
	local reach = M.Model.Limits().reach
	return (x-at.x)^2 + (y-at.y)^2 + (z-at.z)^2 <= reach^2
end
local function notice(player, code)
	TriggerClientEvent(M.Event.NOTICE, player, code)
end
local function collect(player, key)
	local site = type(key) == 'string' and sites[key]
	if stopped or not site or not near(player, site.pickup) then return notice(player, 'refused') end
	local cid = citizen(player)
	if not cid then return notice(player, 'refused') end
	local kvkey = 'salvage.stock.' .. key
	local prior = Open77.kvp.get(kvkey, 0)
	if pending[key] or type(prior) ~= 'number' or prior > Open77.time.unix() then return notice(player, 'busy') end
	local ticket = { citizenId = cid, session = OPX.Sessions[player], started = OPX.Now() }
	pending[key] = ticket
	local started = progress.Start(player, 'salvage', {
		label = locale('salvage.progress'), durationMs = M.Model.Limits().duration,
		cancelable = true, animation = { name = 'scavenge' },
	}, function(_, result)
		if pending[key] ~= ticket or ticket.completing then return end
		-- Mark consumed before starting a yielding inventory operation.
		if not result.completed or stopped or citizen(player) ~= cid or OPX.Sessions[player] ~= ticket.session
			or OPX.Now() - ticket.started < M.Model.Limits().duration or not near(player, site.pickup) then
			pending[key] = nil
			return
		end
		ticket.completing = true
		CreateThread(function()
			local ran, failure = pcall(function()
				local capacity = inventory.CanCarry(cid, M.ITEM, 1)
				if stopped or citizen(player) ~= cid
					or OPX.Sessions[player] ~= ticket.session or not near(player, site.pickup) then return end
				if not capacity.ok or capacity.value ~= true then return notice(player, 'refused') end
				local now = Open77.time.unix()
				-- The atomic persisted claim precedes the grant. Never undo it after
				-- an ambiguous delivery, otherwise a crash could duplicate stock.
				if Open77.kvp.compareAndSet(kvkey, prior, now + M.Model.Limits().cooldown) ~= true then
					return notice(player, 'busy')
				end
				local added = inventory.AddItem(cid, M.ITEM, 1)
				if citizen(player) == cid and OPX.Sessions[player] == ticket.session then notice(player, added.ok and 'done' or 'refused') end
			end)
			if pending[key] == ticket then pending[key] = nil end
			if not ran then Open77.log.error('[salvage] collection failed: ' .. tostring(failure)) end
		end)
	end)
	if not started.ok and pending[key] == ticket then pending[key] = nil; notice(player, 'refused') end
end
M.Server = { Collect = collect }
function M.Init()
	sites, pending, stopped = {}, {}, false
end
function M.Start()
	character, inventory = OPX.Api.Get('character'), OPX.Api.Get('inventory')
	progress, crafting = OPX.Api.Get('progress'), OPX.Api.Get('crafting')
	if type(Open77.kvp) ~= 'table' or type(Open77.kvp.get) ~= 'function'
		or type(Open77.kvp.setIfAbsent) ~= 'function' or type(Open77.kvp.compareAndSet) ~= 'function'
		or type(Open77.time) ~= 'table' or type(Open77.time.unix) ~= 'function' then
		Open77.log.warn('[salvage] persistent stock API unavailable; collection disabled')
		return
	end
	local registered = inventory.RegisterItem(M.ITEM, { label = locale('salvage.item'), weight = 800,
		stack = true, drop = true, category = 'material', model = 'electronics.monitor.device' }, 'salvage', 1)
	if not registered.ok then Open77.log.error('[salvage] item registration refused'); return end
	for _, site in ipairs(M.Model.Sites()) do
		-- Materialise the initial typed value so compareAndSet never compares a
		-- missing key against the default returned by get.
		Open77.kvp.setIfAbsent('salvage.stock.' .. site.key, 0)
		local bench = crafting.RegisterBench(M.PREFIX .. site.key, {
			owner = 'salvage', label = locale('salvage.bench'), position = site.bench,
			reach = M.Model.Limits().reach, queue = 1,
			recipes = {
				{ KEY = 'circuits', LABEL = locale('salvage.electronics'), OUTPUT = 'electronics', COUNT = 1, SECONDS = 30, INPUTS = { [M.ITEM] = 1 } },
				{ KEY = 'metal', LABEL = locale('salvage.scrap'), OUTPUT = 'scrap_metal', COUNT = 2, SECONDS = 30, INPUTS = { [M.ITEM] = 1 } },
			},
		})
		if bench.ok then sites[site.key] = site else Open77.log.error('[salvage] recycling bench refused: ' .. site.key) end
	end
	if next(sites) == nil then Open77.log.warn('[salvage] no usable sites; check config/salvage.lua') end
	RegisterNetEvent(M.Event.COLLECT, function(key)
		local player = math.tointeger(tonumber(source))
		if not player or player < 1 or OPX.Cooling(player, 'salvage.collect', 1000) then return end
		collect(player, key)
	end)
end
function M.Stop()
	stopped = true
	pending = {}
	if crafting then crafting.UnregisterBenches('salvage') end
end
