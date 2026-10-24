--- Atomic per-hand weapon observations for the shared HUD.
-- @author dop42
--
-- One snapshot may be in flight. State rows are private until completion; a
-- failed or timed-out read clears the display instead of mixing two snapshots.
-- This is presentation only: the server owns inventory ammunition accounting.
local M = OPX.Modules.Get('inventory')
local request, rows, deadline, job = nil, {}, 0, nil
local showing = false
local function publish(value)
	if #value == 0 and not showing then return end
	showing = #value > 0
	OPX.UI.Send('overlay', 'hud:weapons', { hands = value })
end
local function watch()
	if job then return end
	job = OPX.Scheduler.Every('inventory:weapon-hud', 500, function()
		if request then
			if OPX.Now() > deadline then request, rows = nil, {}; publish({}) end
			return
		end
		if not M.Screen.Held() then
			publish({})
			if job then OPX.Scheduler.Cancel(job); job = nil end
			return
		end
		local api = Open77.weapons
		if type(api) ~= 'table' or type(api.snapshot) ~= 'function' then return end
		local id = api.snapshot()
		if id then request, rows, deadline = tostring(id), {}, OPX.Now() + 12000 end
	end)
end
local start, stop = M.Start, M.Stop
function M.Start()
	start()
	AddEventHandler('open77:weapons:state', function(id, slot, _record, tweakDbId, active, drawn, _locked,
		_ammoRecord, ammoId, _total, reserve, magazine, capacity, reloading)
		if tostring(id) ~= request then return end
		slot = tonumber(slot)
		if not slot or slot < 1 or slot > 6 or active ~= 'true' or drawn ~= 'true' or tweakDbId == '' then return end
		local mag, cap = tonumber(magazine), tonumber(capacity)
		if not mag or not cap or mag < 0 or cap < 1 then return end
		rows[slot] = { hand = slot <= 3 and 'right' or 'left', magazine = mag, capacity = cap,
			reserve = math.max(0, tonumber(reserve) or 0), ammoId = ammoId, reloading = reloading == 'true' }
	end)
	AddEventHandler('open77:weapons:completed', function(id, operation, accepted)
		if tostring(id) ~= request or operation ~= 'snapshot' then return end
		request = nil
		local complete = {}
		if accepted == 'true' then
			for slot = 1, 6 do if rows[slot] then complete[#complete + 1] = rows[slot] end end
		end
		rows = {}
		publish(complete)
	end)
	AddEventHandler(M.Event.ON_ARMED, function(held)
		if held then watch() end
	end)
	if M.Screen.Held() then watch() end
end
function M.Stop()
	if job then OPX.Scheduler.Cancel(job); job = nil end
	request, rows = nil, {}
	publish({})
	stop()
end
