--- Guided practice entry, camera, physical input and authoritative playback.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model, B, I, R, C, G, Match, TableMenu = M.Model, M.Playback, M.Input, M.Render, M.Camera, M.Guide, M.Match, M.TableMenu
local spec, buffer, input, positions, target, prompts, jobs, lastPacket, subscribed, lastMouse, lastWheel, lastAim, waiting, owned, held, reported, lastControls
local autoAim, following, shotSeen, hudVisible, member, memberSlot, watching
local openTable, reopenTable
local function request(action, extra, snapshot)
	extra = extra or {}
	extra.epoch = snapshot and snapshot.epoch or buffer.epoch
	extra.revision = snapshot and snapshot.revision or buffer.state and buffer.state.revision
	TriggerServerEvent(M.Event.REQUEST, action, extra)
end
local function hideHud()
	if hudVisible then OPX.UI.Send('overlay', 'pool:hide', {}); hudVisible = false end
end
local function releaseView(keepHud) C.Clear(); G.Clear(); if not keepHud then hideHud() end end
local function controls(view, on)
	local names = { 'allowAim', 'allowShoot' }
	if view then
		names[#names+1], names[#names+2] = 'freezeRotation', 'freezePosition'
		names[#names+1], names[#names+2] = 'allowJump', 'allowDodge'
		names[#names+1], names[#names+2] = 'allowInteraction', 'allowWeapons'
	end
	local signature = on and (view and 'view' or 'walk') or 'free'
	if held == signature and (not on or OPX.Now()-lastControls < 250) then return true end
	if not OPX.Controls.Set('pool', names, on) then return false end
	held, lastControls = signature, OPX.Now()
	if target then target.SetTargetingEnabled('pool', not member) end
	return true
end
local function clear(leave)
	if leave and subscribed then request('leave') end
	owned, subscribed, waiting, positions, member, memberSlot, reopenTable = false, false, nil, nil, false, nil, false
	autoAim, following, shotSeen, watching = false, false, false, false
	input, buffer, lastMouse, lastWheel = I.New(), B.New(), nil, nil
	releaseView(); TableMenu.Close(); M.Audio.Clear()
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
		M.Audio.Queue(packet, buffer)
		local nextOwned = buffer.state.owner == Open77.players.localId()
		if oldEpoch ~= buffer.epoch or (wasOwned and not nextOwned) then
			input, waiting, following, shotSeen = I.New(), nil, false, false
			releaseView()
		end
		owned = nextOwned
		memberSlot = buffer.state.game and Match.Slot(buffer.state.game, Open77.players.localId()) or (owned and 1 or nil)
		member = memberSlot ~= nil
		if owned and (not wasOwned or oldEpoch ~= buffer.epoch) then autoAim, watching = true, false end
		if not owned then
			autoAim, following, shotSeen = false, false, false
			if not member then watching = false end
			if not watching then releaseView(member) end
		end
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
	if member and ((owned and (input.aiming or following)) or watching) and not captured then
		local ok, why = C.Update(spec, positions, owned and input.angle or state.angle, following or input.overview or watching, input.height, OPX.Now())
		if not ok then cameraFailure(why); return end
		if not input.aiming or state.phase ~= 'ready' then G.Clear() end
	else releaseView(member and not captured) end
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
		overview = Open77.input.isDown('mouse3'), menu = Open77.input.isDown('E'), precise = Open77.input.isDown('SHIFT') }
	if member and (distance() > (owned and 3.5 or 6) or not available() or now-lastPacket > 1500) then clear(true); return end
	if reopenTable and not captured and buffer.state and buffer.state.game and buffer.state.game.status == 'idle' then
		reopenTable = false;openTable();return
	end
	if member and not captured and buttons.leave then clear(true); return end
	if member and not captured and buttons.menu and not input.previous.menu then
		input.previous = buttons; openTable(); return
	end
	if member and not owned and not captured and buttons.rack and not input.previous.rack then
		input.previous = buttons; request('reset'); return
	end
	if member and not owned and not captured and buttons.overview and not input.previous.overview then watching = not watching end
	if member and not captured and ((owned and (input.aiming or following)) or watching) then
		local ok, why = C.Check()
		if not ok then cameraFailure(why); return end
	end
	-- Do not resume an interrupted charge or a held click after closing a menu.
	if captured then autoAim, following, shotSeen, watching = false, false, false, false end
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
		if event.kind == 'shoot' then R.Strike(spec, positions, event.angle, event.power) end
		if event.kind ~= 'aim' then request(event.kind, event) end
	end
	if not controls(not captured and (input.aiming or following or watching), owned or watching) then
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
openTable = function()
	if not buffer.state or not available() or distance() > 3.5 then return end
	input.aiming, input.chargedAt, input.power = false, nil, 0
	autoAim, following, shotSeen, watching = false, false, false, false
	releaseView(); controls(false, owned)
	local snapshot = { epoch = buffer.epoch, revision = buffer.state.revision, owner = buffer.state.owner,
		phase = buffer.state.phase, game = buffer.state.game }
	TableMenu.Open(snapshot, spec, function(action, extra, stamp)
		if action == 'resume' then autoAim = owned;return end
		if action == 'leave' then clear(true);return end
		if action == 'finish' then reopenTable = true end
		request(action, extra, stamp)
	end)
end
local function status(game)
	if not game then return locale('pool.practice') end
	if game.resetBy > 0 then return locale(game.resetBy == memberSlot and 'pool.resetPending' or 'pool.resetIncoming') end
	if game.status == 'waiting' then return locale('pool.waiting') end
	if game.status == 'finished' then
		if game.reason == 'simulation' then return locale('pool.simulation') end
		if game.winner == 0 then return locale('pool.challengeLost') end
		return locale(game.winner == memberSlot and 'pool.won' or 'pool.lost')
	end
	if game.mode == 'duel' then return locale(owned and 'pool.yourTurn' or 'pool.theirTurn') end
	if game.mode == 'challenge' then return locale('pool.shotsLeft', { shots = math.max(0, game.limit-game.shots) }) end
	return locale('pool.practiceInfo')
end
local function strip()
	if not member or Open77.input.isCaptured() then
		if prompts then prompts.HideAll('pool') end
		hideHud(); return
	end
	local game = buffer.state and buffer.state.game
	local ready = owned and buffer.state and buffer.state.phase == 'ready' and not waiting
	if prompts then prompts.Show('pool', 'practice', { title = spec.label, rows = {
		{ keys = 'RMB', label = locale(ready and 'pool.aim' or 'pool.waitTurn') },
		{ keys = 'LMB', label = locale('pool.charge'), dim = not ready or not input.aiming },
		{ keys = 'SHIFT', label = locale('pool.precise') },
		{ keys = 'MMB', label = locale('pool.overview') },
		{ keys = 'R', label = locale(game and game.mode == 'duel' and 'pool.resetKey' or 'pool.rack') },
		{ keys = 'E', label = locale('pool.tableMenu') }, { keys = 'BACKSPACE', label = locale('pool.leave') },
	} }) end
	hudVisible = true
	local playing = game == nil or game.status == 'playing'
	OPX.UI.Send('overlay', 'pool:frame', { title = spec.label, power = input.power,
		charging = input.chargedAt ~= nil, canShoot = ready and input.aiming,
		phase = following and 'rolling' or ready and input.aiming and 'aim' or 'waiting',
		powerLabel = locale('pool.powerLabel'), modeLabel = locale('pool.' .. (game and game.mode or 'practice')),
		status = status(game), score = game and game.scores or { 0, 0 }, selfSlot = memberSlot,
		firstLabel = locale(memberSlot == 1 and 'pool.you' or 'pool.opponent'), secondLabel = locale(memberSlot == 2 and 'pool.you' or 'pool.opponent'),
		turn = game and game.turn or 0, raceLabel = locale('pool.raceTo', { target = game and game.target or 5 }),
		soloStats = locale('pool.points', { score = game and game.scores[1] or 0, shots = game and game.shots or 0 }),
		duel = game and game.mode == 'duel' or false, target = game and game.target or 5,
		hint = locale(following and 'pool.rolling' or not playing and 'pool.manageHint' or not owned and 'pool.waitTurn' or input.chargedAt and 'pool.release' or 'pool.charge'),
		view = locale(input.overview and 'pool.tableView' or 'pool.cueView') })
end
local function frame() press(); draw(); if subscribed and spec then M.Audio.Frame(spec, OPX.Now()) end end
M.Client = { Receive = receive, Watch = watch, Draw = draw, Input = press, Frame = frame, Strip = strip, Guide = guide, OpenTable = openTable }
function M.Init()
	spec, buffer, input, positions = nil, B.New(), I.New(), nil
	jobs, lastPacket, subscribed, lastMouse, lastWheel, lastAim, waiting, owned, held, reported, lastControls = {}, 0, false, nil, nil, 0, nil, false, 'free', false, 0
	autoAim, following, shotSeen, hudVisible, member, memberSlot, watching = false, false, false, false, false, nil, false
	reopenTable = false
end
function M.Start()
	R.Reset(); G.Reset()
	spec = Model.Table()
	if not spec then return end
	target, prompts = OPX.Api.Get('target'), OPX.Api.Get('prompts')
	if target then target.RegisterSpheres('pool', { { x = spec.x, y = spec.y, z = spec.z, radius = 2 } }, {
		id = 'practice', label = locale('pool.tableMenu'), icon = 'interact', distance = 3,
		canInteract = function() return not R.Failed() and buffer.state ~= nil and OPX.Now()-lastPacket < 1000 end,
		onSelect = function() if not R.Failed() then openTable() end end,
	}) end
	RegisterNetEvent(M.Event.STATE, receive)
	RegisterNetEvent(M.Event.NOTICE, function(code)
		if code == 'changed' then reopenTable = false end
		if type(code) == 'string' and M.Catalogs.en['pool.' .. code] then
			OPX.Toast.Locale('pool.' .. code, nil, (code == 'busy' or code == 'rolling' or code == 'simulation' or code == 'changed') and 'error' or 'info')
		end
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
