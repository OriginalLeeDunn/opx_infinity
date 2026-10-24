--- Guided practice entry, camera, physical input and authoritative playback.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model, B, I, R, C, G = M.Model, M.Playback, M.Input, M.Render, M.Camera, M.Guide
local spec, buffer, input, positions, target, prompts, jobs, lastPacket, subscribed, lastMouse, lastWheel, lastAim, waiting, owned, held, reported, lastControls
local autoAim, following, shotSeen, hudVisible
local function request(action, extra)
	extra = extra or {}
	extra.epoch = buffer.epoch
	extra.revision = buffer.state and buffer.state.revision
	TriggerServerEvent(M.Event.REQUEST, action, extra)
end
local function hideHud()
	if hudVisible then OPX.UI.Send('overlay', 'pool:hide', {}); hudVisible = false end
end
local function releaseView() C.Clear(); G.Clear(); hideHud() end
local function controls(view, on)
	local names = { 'allowAim', 'allowShoot' }
	if view then
		names[#names+1], names[#names+2] = 'freezeRotation', 'freezePosition'
		names[#names+1], names[#names+2] = 'allowJump', 'allowDodge'
		names[#names+1] = 'allowInteraction'
	end
	local signature = on and (view and 'view' or 'walk') or 'free'
	if held == signature and (not on or OPX.Now()-lastControls < 250) then return true end
	if not OPX.Controls.Set('pool', names, on) then return false end
	held, lastControls = signature, OPX.Now()
	if target then target.SetTargetingEnabled('pool', not on) end
	return true
end
local function clear(leave)
	if leave and subscribed then request('leave') end
	owned, subscribed, waiting, positions = false, false, nil, nil
	autoAim, following, shotSeen = false, false, false
	input, buffer, lastMouse, lastWheel = I.New(), B.New(), nil, nil
	releaseView()
	controls(false, false)
	if target then target.SetTargetingEnabled('pool', true) end
	if prompts then prompts.HideAll('pool') end
	R.Clear()
end
local function distance()
	local x, y, z = Open77.character.position()
	if not Model.Number(x, -20000, 20000) or not Model.Number(y, -20000, 20000) or not Model.Number(z, -2000, 5000) then return math.huge end
	return math.sqrt((x-spec.x)^2+(y-spec.y)^2+(z-spec.z)^2), x, y
end
local function available()
	local character = OPX.Api.Get('character')
	local data = character and character.GetPlayerData()
	local downed = OPX.Api.Get('downed')
	local down = downed and downed.IsDown()
	return data and data.citizenId and not (down and down.ok and down.value and down.value.down)
end
local function receive(packet)
	if not spec or not subscribed then return end
	if type(packet) == 'table' and packet.closed == true then clear(true); return end
	local oldEpoch, wasOwned = buffer.epoch, owned
	if B.Push(buffer, packet, OPX.Now()) then
		lastPacket = OPX.Now()
		local nextOwned = buffer.state.owner == Open77.players.localId()
		if oldEpoch ~= buffer.epoch or (wasOwned and not nextOwned) then
			input, waiting, following, shotSeen = I.New(), nil, false, false
			releaseView()
		end
		owned = nextOwned
		if owned and (not wasOwned or oldEpoch ~= buffer.epoch) then autoAim = true end
		if not owned then autoAim, following, shotSeen = false, false, false; releaseView() end
		if following and buffer.state.phase == 'rolling' then shotSeen = true end
		if waiting and (buffer.state.phase == 'rolling' or waiting.revision ~= buffer.state.revision
			or OPX.Now()-waiting.at > 1500) then waiting = nil end
	end
end
local function watch()
	if not spec then return end
	local near = distance() <= 16 and available() and not R.Failed()
	if not near then if subscribed then clear(true) end; return end
	if subscribed and OPX.Now()-lastPacket > 2000 then clear(true) end
	if not subscribed then subscribed, lastPacket = true, OPX.Now() end
	request('watch')
	if not R.Check() then clear(true) end
end
local function cameraFailure(why)
	OPX.Note('pool', 'camera refused: ' .. tostring(why))
	OPX.Toast.Locale('pool.camera', nil, 'error')
	clear(true)
end
local function draw()
	if not subscribed or not buffer.state then return end
	positions = B.Sample(buffer, OPX.Now())
	if not positions then return end
	local state = buffer.state
	local aiming = owned and input.aiming or not owned and state.aiming
	local angle, power = owned and input.angle or state.angle, owned and input.power or state.power
	if not R.Draw(spec, positions, aiming and state.phase == 'ready', angle, power) then clear(true); return end
	local captured = Open77.input.isCaptured() ~= false
	if owned and (input.aiming or following) and not captured then
		local ok, why = C.Update(spec, positions, input.angle, following or input.overview, input.height, OPX.Now())
		if not ok then cameraFailure(why); return end
		if not input.aiming or state.phase ~= 'ready' then G.Clear() end
	else releaseView() end
end
local function axis(name, old)
	local value = Model.Number(Open77.input.axis(name), -1e15, 1e15)
	return value and old and math.max(-5000, math.min(5000, value-old)) or 0, value
end
local function press()
	if not spec then return end
	local now = OPX.Now()
	local delta, wheel
	delta, lastMouse = axis('mouseDeltaX', lastMouse)
	wheel, lastWheel = axis('mouseWheel', lastWheel)
	local captured = Open77.input.isCaptured() ~= false or lastMouse == nil
	local can = owned and buffer.state and buffer.state.phase == 'ready' and not waiting
		and buffer.cursor >= buffer.state.readyAt and distance() <= 3.5 and available() and not R.Failed()
	local buttons = { right = Open77.input.isDown('mouse2'), left = Open77.input.isDown('mouse1'),
		cancel = Open77.input.isDown('ESC'), leave = Open77.input.isDown('BACKSPACE'), rack = Open77.input.isDown('R'),
		overview = Open77.input.isDown('V'), precise = Open77.input.isDown('SHIFT') }
	if owned and (distance() > 3.5 or not available() or now-lastPacket > 1500) then clear(true); return end
	if owned and not captured and (input.aiming or following) then
		local ok, why = C.Check()
		if not ok then cameraFailure(why); return end
	end
	-- Do not resume an interrupted charge or a held click after closing a menu.
	if captured then autoAim, following, shotSeen = false, false, false end
	if following and can and (shotSeen or not waiting) then
		following, shotSeen, autoAim = false, false, true
	end
	if autoAim and can and positions and not captured then
		input.aiming, autoAim, input.previous = true, false, buttons
		if not input.aligned then
			local _, x, y = distance()
			local px, py = Model.Local(spec, x, y)
			input.angle, input.aligned = math.atan(positions[1][2]-py, positions[1][1]-px), true
		end
	end
	local was = input.aiming
	local cfg = M.Settings
	local event = I.Step(input, now/1000, buttons, can, captured, delta,
		Model.Number(cfg.SENSITIVITY, 0.0001, 0.02) or 0.0018, Model.Number(cfg.CHARGE_SECONDS, 0.5, 5) or 1.8)
	if not was and input.aiming and positions and not input.aligned then
		local _, x, y = distance()
		local px, py = Model.Local(spec, x, y)
		input.angle, input.aligned = math.atan(positions[1][2]-py, positions[1][1]-px), true
	end
	if input.aiming then input.height = math.max(0.25, math.min(1.2, input.height+wheel*0.08)) end
	if owned and not captured and buttons.leave then clear(true); return end
	if event then
		if event.kind == 'leave' then clear(true); return end
		if event.kind == 'shoot' or event.kind == 'rack' then
			waiting = { revision = buffer.state.revision, at = now }
			if event.kind == 'shoot' then following, shotSeen = true, false end
		end
		if event.kind ~= 'aim' then request(event.kind, event) end
	end
	if not controls(not captured and (input.aiming or following), owned) then
		if not reported then reported = true; OPX.Note('pool', 'input control lease refused'); OPX.Toast.Locale('pool.models', nil, 'error') end
		clear(true); return
	end
	if subscribed and owned and now-lastAim >= 100 then
		lastAim = now
		request('aim', { visible = input.aiming, angle = input.angle, power = input.power })
	end
end
local function guide()
	if owned and input.aiming and positions and positions[1][3] and buffer.state and buffer.state.phase == 'ready'
		and Open77.input.isCaptured() == false and M.Settings.AIM_GUIDE ~= false then
		G.Draw(spec, positions, input.angle, OPX.Now())
	else G.Clear() end
end
local function strip()
	if not owned or Open77.input.isCaptured() then
		if prompts then prompts.HideAll('pool') end
		hideHud(); return
	end
	local ready = buffer.state and buffer.state.phase == 'ready' and not waiting
	if prompts then prompts.Show('pool', 'practice', { title = spec.label, rows = {
		{ keys = 'RMB', label = locale(ready and 'pool.aim' or 'pool.rolling') },
		{ keys = 'LMB', label = locale('pool.charge') },
		{ keys = 'SHIFT', label = locale('pool.precise') },
		{ keys = 'V', label = locale('pool.overview') },
		{ keys = 'R', label = locale('pool.rack') }, { keys = 'BACKSPACE', label = locale('pool.leave') },
	} }) end
	if input.aiming or following then
		hudVisible = true
		OPX.UI.Send('overlay', 'pool:frame', { title = spec.label, power = input.power,
			charging = input.chargedAt ~= nil,
			phase = following and 'rolling' or 'aim', powerLabel = locale('pool.powerLabel'),
			hint = locale(following and 'pool.rolling' or input.chargedAt and 'pool.release' or 'pool.charge'),
			view = locale(input.overview and 'pool.tableView' or 'pool.cueView') })
	else hideHud() end
end
local function frame() press(); draw() end
M.Client = { Receive = receive, Watch = watch, Draw = draw, Input = press, Frame = frame, Strip = strip, Guide = guide }
function M.Init()
	spec, buffer, input, positions = nil, B.New(), I.New(), nil
	jobs, lastPacket, subscribed, lastMouse, lastWheel, lastAim, waiting, owned, held, reported, lastControls = {}, 0, false, nil, nil, 0, nil, false, 'free', false, 0
	autoAim, following, shotSeen, hudVisible = false, false, false, false
end
function M.Start()
	R.Reset(); G.Reset()
	spec = Model.Table()
	if not spec then return end
	target, prompts = OPX.Api.Get('target'), OPX.Api.Get('prompts')
	if target then target.RegisterSpheres('pool', { { x = spec.x, y = spec.y, z = spec.z, radius = 2 } }, {
		id = 'practice', label = locale('pool.enter'), icon = 'interact', distance = 3,
		canInteract = function() return not R.Failed() and buffer.state ~= nil and OPX.Now()-lastPacket < 1000 end,
		onSelect = function() if not R.Failed() then subscribed, lastPacket = true, OPX.Now(); request('enter') end end,
	}) end
	RegisterNetEvent(M.Event.STATE, receive)
	RegisterNetEvent(M.Event.NOTICE, function(code)
		if code == 'busy' or code == 'rolling' or code == 'simulation' then OPX.Toast.Locale('pool.' .. code, nil, 'error') end
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), function() clear(true) end)
	jobs[1] = OPX.Scheduler.Every('pool.watch', 1000, watch)
	jobs[2] = OPX.Scheduler.Every('pool.frame', 0, frame)
	jobs[3] = OPX.Scheduler.Every('pool.strip', 50, strip)
	jobs[4] = OPX.Scheduler.Every('pool.guide', 100, guide)
end
function M.Stop()
	for _, job in ipairs(jobs or {}) do OPX.Scheduler.Cancel(job) end
	clear(true)
	if target then target.Clear('pool') end
	spec = nil
end
