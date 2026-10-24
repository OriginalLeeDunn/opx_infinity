--- Practice entry, bounded local playback and physical mouse input.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model, B, I, R = M.Model, M.Playback, M.Input, M.Render
local spec, buffer, input, positions, target, prompts, jobs, lastPacket, subscribed, lastMouse, lastAim, waiting, owned, held, reported, lastControls
local function request(action, extra)
	extra = extra or {}
	extra.epoch = buffer.epoch
	extra.revision = buffer.state and buffer.state.revision
	TriggerServerEvent(M.Event.REQUEST, action, extra)
end
local function controls(aiming, on)
	local names = { 'allowAim', 'allowShoot' }
	if aiming then names[#names+1] = 'freezeRotation' end
	local signature = on and (aiming and 'aim' or 'walk') or 'free'
	if held == signature and (not on or OPX.Now()-lastControls < 250) then return true end
	if not OPX.Controls.Set('pool', names, on) then return false end
	held, lastControls = signature, OPX.Now()
	if target then target.SetTargetingEnabled('pool', not on) end
	return true
end
local function clear(leave)
	if leave and subscribed then request('leave') end
	owned, subscribed, waiting, positions = false, false, nil, nil
	input, buffer, lastMouse = I.New(), B.New(), nil
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
	local oldEpoch = buffer.epoch
	if B.Push(buffer, packet, OPX.Now()) then
		lastPacket = OPX.Now()
		if oldEpoch ~= buffer.epoch then input, waiting = I.New(), nil end
		local nextOwned = buffer.state.owner == Open77.players.localId()
		if owned and not nextOwned then input, waiting = I.New(), nil end
		owned = nextOwned
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
local function draw()
	if not subscribed or not buffer.state then return end
	positions = B.Sample(buffer, OPX.Now())
	if not positions then return end
	local state = buffer.state
	local aiming = owned and input.aiming or not owned and state.aiming
	local angle, power = owned and input.angle or state.angle, owned and input.power or state.power
	if not R.Draw(spec, positions, aiming and state.phase == 'ready', angle, power) then clear(true) end
end
local function press()
	if not spec then return end
	local now = OPX.Now()
	local mouse = Open77.input.axis('mouseDeltaX')
	local delta = Model.Number(mouse, -1e15, 1e15) and lastMouse and math.max(-5000, math.min(5000, mouse-lastMouse)) or 0
	lastMouse = Model.Number(mouse, -1e15, 1e15)
	local captured = Open77.input.isCaptured() ~= false or lastMouse == nil
	local can = owned and buffer.state and buffer.state.phase == 'ready' and not waiting
		and buffer.cursor >= buffer.state.readyAt and distance() <= 3.5 and available() and not R.Failed()
	local buttons = { right = Open77.input.isDown('mouse2'), left = Open77.input.isDown('mouse1'),
		cancel = Open77.input.isDown('ESC'), leave = Open77.input.isDown('BACKSPACE'), rack = Open77.input.isDown('R') }
	local was = input.aiming
	local cfg = M.Settings
	local event = I.Step(input, now/1000, buttons, can, captured, delta,
		Model.Number(cfg.SENSITIVITY, 0.0001, 0.02) or 0.0025, Model.Number(cfg.CHARGE_SECONDS, 0.5, 5) or 2.4)
	if not was and input.aiming and positions then
		local _, x, y = distance()
		local px, py = Model.Local(spec, x, y)
		input.angle = math.atan(positions[1][2]-py, positions[1][1]-px)
	end
	if owned and (distance() > 3.5 or not available() or now-lastPacket > 1500) then clear(true); return end
	if not controls(input.aiming, owned) then
		if not reported then reported = true; OPX.Note('pool', 'input control lease refused'); OPX.Toast.Locale('pool.models', nil, 'error') end
		clear(true); return
	end
	-- Leave works while rolling too; it does not imply an accepted new shot.
	if owned and not captured and buttons.leave and not can then clear(true); return end
	if event then
		if event.kind == 'leave' then clear(true); return end
		if event.kind == 'shoot' or event.kind == 'rack' then waiting = { revision = buffer.state.revision, at = now } end
		if event.kind ~= 'aim' then request(event.kind, event) end
	end
	if subscribed and owned and now-lastAim >= 100 then
		lastAim = now
		request('aim', { visible = input.aiming, angle = input.angle, power = input.power })
	end
end
local function strip()
	if not owned or not prompts or Open77.input.isCaptured() then if prompts then prompts.HideAll('pool') end; return end
	local ready = buffer.state and buffer.state.phase == 'ready' and not waiting
	prompts.Show('pool', 'practice', { title = spec.label, rows = {
		{ keys = 'RMB', label = locale(ready and 'pool.aim' or 'pool.rolling') },
		{ keys = 'LMB', label = locale('pool.charge'), value = locale('pool.power', { power = math.floor(input.power*100) }) },
		{ keys = 'R', label = locale('pool.rack') }, { keys = 'BACKSPACE', label = locale('pool.leave') },
	} })
end
local function frame() press(); draw() end
M.Client = { Receive = receive, Watch = watch, Draw = draw, Input = press, Frame = frame }
function M.Init()
	spec, buffer, input, positions = nil, B.New(), I.New(), nil
	jobs, lastPacket, subscribed, lastMouse, lastAim, waiting, owned, held, reported, lastControls = {}, 0, false, nil, 0, nil, false, 'free', false, 0
end
function M.Start()
	R.Reset()
	spec = Model.Table()
	if not spec then return end
	target, prompts = OPX.Api.Get('target'), OPX.Api.Get('prompts')
	if target then target.RegisterSpheres('pool', { { x = spec.x, y = spec.y, z = spec.z, radius = 2 } }, {
		id = 'practice', label = locale('pool.enter'), icon = 'interact', distance = 3,
		canInteract = function() return not R.Failed() end,
		onSelect = function() if not R.Failed() then subscribed, lastPacket = true, OPX.Now(); request('enter') end end,
	}) end
	RegisterNetEvent(M.Event.STATE, receive)
	RegisterNetEvent(M.Event.NOTICE, function(code)
		if code == 'busy' or code == 'rolling' or code == 'simulation' then OPX.Toast.Locale('pool.' .. code, nil, 'error') end
	end)
	AddEventHandler(OPX.Event(OPX.Channel.LOCAL, 'character', 'unloaded'), function() clear(true) end)
	jobs[1] = OPX.Scheduler.Every('pool.watch', 1000, watch)
	jobs[2] = OPX.Scheduler.Every('pool.frame', 0, frame)
	jobs[3] = OPX.Scheduler.Every('pool.strip', 100, strip)
end
function M.Stop()
	for _, job in ipairs(jobs or {}) do OPX.Scheduler.Cancel(job) end
	clear(true)
	if target then target.Clear('pool') end
	spec = nil
end
