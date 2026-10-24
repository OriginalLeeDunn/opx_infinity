--- Authoritative modes, two identity-bound seats, turns, scores and reset consent.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model, P, G = M.Model, M.Physics, M.Match
local spec, balls, tickets, watchers, job, epoch, sequence, revision, ticks, phase, readyAt, aim, character, game
local before, resetUntil, createdAt, finishedAt, rackDue, sounds, soundSequence
local function person(player)
	local p = character and character.GetPlayer(player)
	return p and p.PlayerData and p or nil
end
local function actor(player)
	local p = person(player)
	return p and { player = player, person = p, cid = p.PlayerData.citizenId, session = OPX.Sessions[player] } or nil
end
local function sameIdentity(ticket)
	return ticket and ticket.session and person(ticket.player) == ticket.person
		and ticket.person.PlayerData.citizenId == ticket.cid and OPX.Sessions[ticket.player] == ticket.session
end
local function valid(ticket, reach)
	if not sameIdentity(ticket) or OPX.Life.Down(ticket.player) then return false end
	local snap = Open77.players.get(ticket.player)
	local at = snap and snap.position
	return snap and snap.fresh == true and snap.bucket == spec.bucket and type(at) == 'table'
		and Model.Number(at.x, -20000, 20000) and Model.Number(at.y, -20000, 20000) and Model.Number(at.z, -2000, 5000)
		and (at.x-spec.x)^2+(at.y-spec.y)^2+(at.z-spec.z)^2 <= reach^2
end
local function seat(ticket)
	if not ticket then return nil end
	for index = 1, 2 do
		local held = tickets[index]
		if held and held.player == ticket.player and held.session == ticket.session and held.person == ticket.person and held.cid == ticket.cid then return index end
	end
end
local function notice(player, code) TriggerClientEvent(M.Event.NOTICE, player, code) end
local function notify(code)
	for index = 1, 2 do if sameIdentity(tickets[index]) then notice(tickets[index].player, code) end end
end
local function sound(kind, x, y, strength)
	if kind ~= 'pocket' and strength < 0.12 then return end
	soundSequence = soundSequence+1
	sounds[#sounds+1] = { id = soundSequence, kind = kind, x = x, y = y,
		time = ticks*1000/120, volume = kind == 'pocket' and 0.8 or math.max(0.1, math.min(1, strength/3)) }
	while #sounds > 12 do table.remove(sounds, 1) end
end
local function rack()
	epoch, revision, ticks, readyAt, phase = epoch+1, 1, 0, 0, 'ready'
	balls, aim, before = P.Rack(spec), { visible = false, angle = 0, power = 0 }, nil
	rackDue, sounds, soundSequence = nil, {}, 0
end
local function resetSession()
	game, tickets = G.New('practice', nil, M.Settings), {}
	resetUntil, createdAt, finishedAt = nil, nil, nil
	rack()
end
local function renew()
	local players, mode = game.players, game.mode
	game = G.New(mode, players[1], M.Settings)
	if mode == 'duel' and players[2] then G.Join(game, players[2]) end
	resetUntil, createdAt, finishedAt = nil, OPX.Now(), nil
	rack()
end
local function depart(index)
	if not tickets[index] then return end
	tickets[index] = nil
	if game.mode == 'duel' then
		if game.status ~= 'finished' then G.Forfeit(game, index); resetUntil = nil; revision = revision+1; aim.visible = false; finishedAt = OPX.Now(); notify('opponentLeft') end
		if not tickets[1] and not tickets[2] then resetSession() end
	else resetSession() end
end
local function publish(frames)
	sequence = sequence+1
	local state = { epoch = epoch, sequence = sequence, revision = revision, owner = G.Owner(game),
		phase = phase, readyAt = readyAt, frames = frames, aim = aim, game = game, sounds = sounds }
	for player, ticket in pairs(watchers) do
		if valid(ticket, 18) then TriggerClientEvent(M.Event.STATE, player, state)
		else
			watchers[player] = nil
			if sameIdentity(ticket) then TriggerClientEvent(M.Event.STATE, player, { closed = true }) end
		end
	end
end
local function step()
	if rackDue and OPX.Now() >= rackDue then rack() end
	for index = 1, 2 do if tickets[index] and not valid(tickets[index], 6) then depart(index) end end
	if resetUntil and OPX.Now() >= resetUntil then game.resetBy, resetUntil, revision = 0, nil, revision+1; notify('resetExpired') end
	if game.status == 'waiting' and createdAt and OPX.Now()-createdAt > 120000 then notify('lobbyExpired');resetSession() end
	if game.status == 'finished' and not resetUntil and finishedAt and OPX.Now()-finishedAt > 30000 then resetSession() end
	local frames = {}
	for _ = 1, 6 do
		ticks = ticks+1
		if phase == 'rolling' and not rackDue then
			if not P.Step(balls, spec, Model.STEP, sound) then
				for _, ball in ipairs(balls) do ball.vx, ball.vy = 0, 0 end
				game.status, game.reason, game.winner, game.resetBy = 'finished', 'simulation', 0, 0
				notify('simulation');Open77.log.warn('[pool] contact ceiling/geometry refusal; game stopped safely')
			end
			if not P.Moving(balls) then
				local rerack = before and G.Resolve(game, before, balls) or false
				before = nil
				if game.status == 'finished' then finishedAt = finishedAt or OPX.Now() end
				if rerack then rackDue = OPX.Now()+350
				elseif not P.Respot(balls, spec) then
					game.status, game.reason, game.winner = 'finished', 'simulation', 0;finishedAt = OPX.Now();rack();frames = {}
				else phase, readyAt, revision, aim.visible = 'ready', ticks*1000/120, revision+1, false end
			end
		end
		-- Keep fixed-step physics at 120 Hz; two endpoint samples per 50 ms
		-- update bound client validation/transport cost for all sixteen balls.
		if #frames == 0 or _ == 6 then frames[#frames+1] = P.Frame(balls, ticks*1000/120) end
	end
	while sounds[1] and ticks*1000/120-sounds[1].time > 250 do table.remove(sounds, 1) end
	publish(frames)
end
local actions = { enter = true, create = true, join = true, watch = true, leave = true, rack = true,
	reset = true, acceptReset = true, declineReset = true, finish = true, aim = true, shoot = true }
local function request(player, action, data)
	if not spec or type(action) ~= 'string' or not actions[action] then return false end
	local ticket = actor(player)
	-- A real participant can always leave, independently of menu/aim timers.
	if action == 'leave' then
		local index = seat(ticket)
		if index then depart(index) end
		local held = watchers[player]
		if not held or (ticket and held.person == ticket.person and held.session == ticket.session and held.cid == ticket.cid) then watchers[player] = nil end
		return true
	end
	local channel = action == 'aim' and 'aim' or action == 'watch' and 'watch' or action == 'shoot' and 'shoot' or 'action'
	if OPX.Cooling(player, 'pool.' .. channel, channel == 'aim' and 90 or channel == 'watch' and 900 or 150) then return false end
	if not valid(ticket, action == 'watch' and 16 or 6) then return false end
	if action == 'watch' then watchers[player] = ticket;return true end
	-- Refresh expired identity-bound seats before considering a new session.
	for index = 1, 2 do if tickets[index] and not valid(tickets[index], 6) then depart(index) end end
	if action == 'enter' then
		if game.status ~= 'idle' then notice(player, 'busy');return false end
		if not valid(ticket, 3.5) or phase ~= 'ready' then return false end
		game, tickets[1], watchers[player], createdAt = G.New('practice', player, M.Settings), ticket, ticket, OPX.Now()
		rack();return true
	end
	-- Mode/lobby/reset commands bind to the exact table revision the player saw.
	if type(data) ~= 'table' or data.epoch ~= epoch or data.revision ~= revision then notice(player, 'changed');return false end
	if action == 'create' then
		if game.status ~= 'idle' then notice(player, 'busy');return false end
		if not G.MODES[data.mode] or not valid(ticket, 3.5) or phase ~= 'ready' then return false end
		game, tickets[1], watchers[player], createdAt = G.New(data.mode, player, M.Settings), ticket, ticket, OPX.Now()
		rack();return true
	end
	if action == 'join' then
		if not valid(ticket, 3.5) or not G.Join(game, player) then notice(player, 'busy');return false end
		tickets[2], watchers[player], revision, aim.visible = ticket, ticket, revision+1, false
		notify('duelStarted');return true
	end
	local index = seat(ticket)
	if not index then return false end
	if action == 'finish' then
		if game.mode == 'duel' and game.status ~= 'finished' and game.status ~= 'waiting' then return false end
		notify('sessionEnded');resetSession();return true
	end
	if action == 'rack' or action == 'reset' or action == 'acceptReset' or action == 'declineReset' then
		if phase ~= 'ready' then notice(player, 'rolling');return false end
		if game.mode ~= 'duel' then renew();return true end
		if game.status == 'waiting' then renew();return true end
		if not valid(tickets[1], 6) or not valid(tickets[2], 6) then notice(player, 'opponentLeft');return false end
		if action == 'declineReset' then
			if game.resetBy == 0 then return false end
			game.resetBy, resetUntil, revision = 0, nil, revision+1;notify('resetDeclined');return true
		end
		if game.resetBy ~= 0 and game.resetBy ~= index then renew();notify('resetDone');return true end
		if action == 'acceptReset' then return false end
		if game.resetBy == index then return false end
		game.resetBy, resetUntil, revision, aim.visible = index, OPX.Now()+15000, revision+1, false
		notify('resetRequested');return true
	end
	if phase ~= 'ready' or G.Owner(game) ~= player or not valid(ticket, 3.5) then return false end
	if action == 'aim' then
		if type(data.visible) ~= 'boolean' or not Model.Number(data.angle, -math.pi*2, math.pi*2) or not Model.Number(data.power, 0, 1) then return false end
		aim = { visible = data.visible, angle = data.angle, power = data.power };return true
	end
	if action == 'shoot' and P.Shoot(balls, data.angle, data.power) then
		before = {};for i, ball in ipairs(balls) do before[i] = ball.alive end
		sound('cue', balls[1].x, balls[1].y, 0.6+data.power*2.4)
		phase, aim.visible = 'rolling', false;return true
	end
	return false
end
M.Server = { Request = request, Step = step }
function M.Init()
	spec, balls, tickets, watchers = nil, nil, {}, {}
	epoch, sequence, revision, ticks, phase, readyAt = math.floor(OPX.Now()), 0, 1, 0, 'ready', 0
	aim, game = { visible = false, angle = 0, power = 0 }, G.New('practice', nil, M.Settings)
	before, resetUntil, createdAt, finishedAt, rackDue, sounds, soundSequence = nil, nil, nil, nil, nil, {}, 0
end
function M.Start()
	character, spec = OPX.Api.Get('character'), Model.Table()
	if not spec then return end
	rack()
	RegisterNetEvent(M.Event.REQUEST, function(action, data)
		local player = tonumber(source)
		if player and player > 0 and player%1 == 0 then request(player, action, data) end
	end)
	job = OPX.Scheduler.Every('pool.physics', 50, step)
end
function M.Stop()
	if job then OPX.Scheduler.Cancel(job) end
	job, tickets, watchers, spec = nil, {}, {}, nil
end
