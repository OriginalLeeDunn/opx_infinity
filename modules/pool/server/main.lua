--- Exclusive practice seat; spectators share authoritative sampled trajectories.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Model, P = M.Model, M.Physics
local spec, balls, owner, watchers, job, epoch, sequence, revision, ticks, phase, readyAt, aim, character
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
local function notice(player, code) TriggerClientEvent(M.Event.NOTICE, player, code) end
local function packet(frames)
	return { epoch = epoch, sequence = sequence, revision = revision, owner = owner and owner.player or 0,
		phase = phase, readyAt = readyAt, frames = frames, aim = aim }
end
local function publish(frames)
	sequence = sequence + 1
	local state = packet(frames)
	for player, ticket in pairs(watchers) do
		if valid(ticket, 18) then TriggerClientEvent(M.Event.STATE, player, state)
		else
			watchers[player] = nil
			if sameIdentity(ticket) then TriggerClientEvent(M.Event.STATE, player, { closed = true }) end
		end
	end
end
local function rack()
	epoch, revision, ticks, readyAt, phase = epoch + 1, 1, 0, 0, 'ready'
	balls, aim = P.Rack(spec), { visible = false, angle = 0, power = 0 }
end
local function step()
	if owner and not valid(owner, 3.5) then owner, aim.visible = nil, false end
	local frames = {}
	for _ = 1, 6 do
		ticks = ticks + 1
		if phase == 'rolling' then
			if not P.Step(balls, spec, Model.STEP) then
				for _, ball in ipairs(balls) do ball.vx, ball.vy = 0, 0 end
				if owner then notice(owner.player, 'simulation') end
				Open77.log.warn('[pool] contact ceiling/geometry refusal; practice stopped safely')
			end
			if not P.Moving(balls) then
				if not P.Respot(balls, spec) then rack(); frames = {} else phase, readyAt, revision = 'ready', ticks*1000/120, revision+1 end
			end
		end
		frames[#frames+1] = P.Frame(balls, ticks*1000/120)
	end
	publish(frames)
end
local function request(player, action, data)
	if not spec or (action ~= 'enter' and action ~= 'watch' and action ~= 'leave' and action ~= 'rack' and action ~= 'aim' and action ~= 'shoot') then return false end
	local ticket = actor(player)
	-- Leaving is always cheap and must never be swallowed by an aim/rack timer.
	if action == 'leave' then
		watchers[player] = nil
		if owner and owner.player == player and ticket and owner.session == ticket.session and owner.cid == ticket.cid then owner, aim.visible = nil, false end
		return true
	end
	local channel = action == 'aim' and 'aim' or action == 'watch' and 'watch' or action == 'shoot' and 'shoot' or 'action'
	if OPX.Cooling(player, 'pool.' .. channel, channel == 'aim' and 90 or channel == 'watch' and 900 or 150) then return false end
	if not valid(ticket, action == 'watch' and 16 or 3.5) then return false end
	if action == 'watch' then watchers[player] = ticket; return true end
	if action == 'enter' then
		if owner and not valid(owner, 3.5) then owner = nil end
		if owner and owner.player ~= player then notice(player, 'busy'); return false end
		if phase ~= 'ready' then notice(player, 'rolling'); return false end
		owner, watchers[player] = ticket, ticket
		return true
	end
	if not owner or owner.player ~= player or owner.cid ~= ticket.cid or owner.session ~= ticket.session
		or phase ~= 'ready' or type(data) ~= 'table' or data.epoch ~= epoch or data.revision ~= revision then return false end
	if action == 'rack' then rack(); return true end
	if action == 'aim' then
		if type(data.visible) ~= 'boolean' or not Model.Number(data.angle, -math.pi*2, math.pi*2)
			or not Model.Number(data.power, 0, 1) then return false end
		aim = { visible = data.visible, angle = data.angle, power = data.power }
		return true
	end
	if action == 'shoot' and P.Shoot(balls, data.angle, data.power) then
		phase, aim.visible = 'rolling', false
		return true
	end
	return false
end
M.Server = { Request = request, Step = step }
function M.Init()
	spec, balls, owner, watchers = nil, nil, nil, {}
	epoch, sequence, revision, ticks, phase, readyAt = math.floor(OPX.Now()), 0, 1, 0, 'ready', 0
	aim = { visible = false, angle = 0, power = 0 }
end
function M.Start()
	character, spec = OPX.Api.Get('character'), Model.Table()
	if not spec then return end
	rack()
	RegisterNetEvent(M.Event.REQUEST, function(action, data)
		local player = tonumber(source)
		if player and player > 0 and player % 1 == 0 then request(player, action, data) end
	end)
	job = OPX.Scheduler.Every('pool.physics', 50, step)
end
function M.Stop()
	if job then OPX.Scheduler.Cancel(job) end
	job, owner, watchers, spec = nil, nil, {}, nil
end
