--- The Trauma Team's own AV: flown to a distress signal, down beside the body,
--- a medic who stands the patient up, and away again.
-- @author XEROX710
--
-- WHY THIS EXISTS. The bot lab, 2026-10-07: "trauma team and the trauma team agent
-- troopers and the whole trauma team av isnt landing when somebody is down and
-- reviving them". A distress signal paged the on-duty medics (`server/trauma.lua`)
-- and nothing else came. With nobody on duty, nobody came at all. This file is the
-- Trauma Team the city sends: an AV with the team's own landing call, a medic who
-- runs to the body and a guard beside them, the revive, and the flight out.
--
-- PLAYERS FIRST. A patient an on-duty medic was paged for is left to that medic
-- for `MEDIC_HEAD_START_SECONDS`. A patient nobody was paged for gets the team
-- after `DELAY_SECONDS`. A patient a medic is already treating is never taken
-- from them.
--
-- ONE AV PER SCENE. A second patient down within `SCENE_METRES` of an AV that is
-- still coming or still on the ground is added to that AV's list, and the medic
-- goes from body to body. At most `MAX_RUNS` AVs fly at once.
--
-- THE SERVER KEEPS THE CLOCK. The AV is an Open77 vehicle, frozen and posed with
-- `setTransform`, like the MaxTac insertion (`modules/ncpd/server/av.lua`). The
-- team are Open77 NPCs given `moveTo` tasks. Their walk is what players see, but
-- the revive comes from this file's timer: the time to run to the body plus
-- `TREAT_SECONDS`. A body no client has streamed in, or a task the host refuses,
-- costs the patient no revive. Every phase is timed against `OPX.Now()`, not by
-- counting ticks, so a busy scheduler stretches nothing.
--
-- THE REVIVE IS THE MODULE'S ONE PATH (`M.Internal.Revive`), the same one a
-- player medic's revive takes. Nothing here pays anybody.
--
-- AN AIRFRAME THE GAMES CAN DRAW. The bot lab, 2026-10-07: "i hear tramua team
-- but i dont see av". The first record this flew, `Vehicle.av_trauma`, names an
-- entity template that is in none of the game's archives (its resource hash is
-- missing from all 584,344 files of `content` and `ep1`), so every client
-- registered its spawn and never finished it: the landing call on a hull nobody
-- could see. `AV.RECORDS` is now a list of trauma airframes whose templates
-- exist, and the games near the landing spot are ASKED (`TEAM_WATCH`): one that
-- has registered the hull and not drawn it in `WATCH_SECONDS` says so
-- (`TEAM_SEEN`), the hull in the air is swapped for the next record where it
-- is, and the next run flies the next record too. One that draws it marks the
-- record as drawn, and nobody is asked about it again.
--
-- ON THE GROUND THE GAMES MEASURED, NOSE FIRST, ON ITS PAD. The bot lab,
-- 2026-10-07: "the trauma team av is landing outside on the water while the
-- trauma soldiers or visually walking on air", and "make sure the trauma team
-- av has the red warning laser underneath like maxtac av does ... not showing
-- in a diff angle". Before it comes in, the AV waits out and high while the
-- games are asked for flat, open ground at the body's level near it (avdoor
-- `LandingSite`); it comes down there, and the team steps out onto that ground.
-- It flies nose first (`headingTo`: the game's yaw, 0 facing +Y -- the math
-- angle it used to be given flew it side-on) and sets down square to the
-- landing pad every game near it draws under it (avdoor `Pad`): the red ring the
-- client draws under an AV it flies itself, which a Trauma Team airframe is not.

local M = OPX.Modules.Get('downed')

M.Team = {}
local Team = M.Team

local PHASE = {
	APPROACH = 'approach',
	DESCEND = 'descend',
	GROUND = 'ground',
	CLIMB = 'climb',
	EXIT = 'exit',
}

-- Runs in the air or on the ground, by run number.
local runs = {}
local nextRun = 0

-- Which run each patient is on, by patient id.
local assigned = {}

-- The scheduler job, while the module runs.
local job = nil

-- Reasons already said once.
local told = {}

-- What each airframe record did on the players' games while this server runs:
-- `drawn` once a game drew it, `undrawn` once a game registered it and never did
-- (or the host refused to create it).
local seen = {}

-- Whether the answer from the games is wired (once: `Team.Start` runs again on
-- a module restart, and a second handler would answer twice).
local wired = false

local function internal() return M.Internal end

local function sayOnce(key, line)
	if told[key] then return end
	told[key] = true
	Open77.log.warn(line)
end

local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

local function lerp(a, b, t) return a + (b - a) * t end

--- Ease-in-out, so a leg starts and ends at rest.
local function smooth(t) return t * t * (3.0 - 2.0 * t) end

--- The math angle from one point to another (0 = +X, counter-clockwise): the
--- one `pointAt` lays a point out along. NOT a heading -- see `headingTo`.
local function bearingTo(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(dy, dx))
end

--- The game's heading from one point to another: degrees about Z, 0 facing +Y
--- and growing counter-clockwise, so +X is 270 -- the yaw `create`,
--- `setTransform` and an NPC's `yaw` read (`docs/camera.md`). The AV and the
--- team used to be given `bearingTo`, 90 degrees off it: the AV flew in side-on
--- and the team stepped out facing past the patient. The bot lab, 2026-10-07:
--- "not showing in a diff angle".
local function headingTo(from, to)
	local dx, dy = to.x - from.x, to.y - from.y
	if dx == 0.0 and dy == 0.0 then return 0.0 end
	return math.deg(math.atan(-dx, dy)) % 360.0
end

--- A heading squared to the nearest of the four axes: the AV sets down square
--- to the landing pad under it, whose sign runs along the world's axes (see
--- `modules/avdoor/client/pad.lua`, and the client's own `ApplyLandingLaser`).
local function square(heading)
	return (math.floor(heading / 90.0 + 0.5) * 90.0) % 360.0
end

--- A heading `t` of the way from one to another, the short way round.
local function turn(from, to, t)
	if t >= 1.0 then return to % 360.0 end
	local delta = ((to - from + 540.0) % 360.0) - 180.0
	return (from + delta * t) % 360.0
end

local function apart(a, b)
	local dx, dy, dz = a.x - b.x, a.y - b.y, (a.z or 0.0) - (b.z or 0.0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function flat(a, b)
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

local function pointAt(origin, bearing, distance, z)
	local radians = math.rad(bearing)
	return { x = origin.x + math.cos(radians) * distance, y = origin.y + math.sin(radians) * distance,
		z = z or origin.z }
end

--- Where a patient's body lies, and its bucket: the life state first, the
--- record second.
local function bodyOf(patientId, record)
	local life = internal().Life(patientId)
	local at = type(life) == 'table' and type(life.position) == 'table' and life.position or nil
	local x, y, z = at and finite(at.x), at and finite(at.y), at and finite(at.z)
	local bucket = type(life) == 'table' and tonumber(life.bucket) or nil
	if x == nil or y == nil or z == nil then
		at = type(record) == 'table' and record.position or nil
		x, y, z = at and finite(at.x), at and finite(at.y), at and finite(at.z)
	end
	if bucket == nil and type(record) == 'table' then bucket = tonumber(record.bucket) end
	if x == nil or y == nil or z == nil then return nil, bucket or 0 end
	return { x = x, y = y, z = z }, bucket or 0
end

local function nameFor(patientId)
	return internal().Name(patientId) or ('#' .. tostring(patientId))
end

local function notice(patientId, key, args)
	pcall(TriggerClientEvent, M.TraumaEvent.NOTICE, patientId, { key = key, args = args })
end

local function vehicles() return type(Open77) == 'table' and Open77.vehicles or nil end
local function npcs() return type(Open77) == 'table' and Open77.npcs or nil end

--- A deterministic approach bearing per patient, so two AVs to two bodies do
--- not fly in on the same line.
local function bearingFor(patientId)
	return ((tonumber(patientId) or 0) * 137) % 360 + 0.0
end

--- One run's geometry. The AV lands on the ground the games measured near the
--- body (`site`, from the avdoor contract's `LandingSite`), or -- with no site --
--- `LAND_OFFSET_METRES` from the body on the side it comes in from, at the body's
--- height. Never on the patient. `start` is kept when given: an AV already
--- waiting out there flies in from where it is.
local function geometry(body, cfg, bearing, site, start)
	local ground = site ~= nil and site.z or body.z
	local land = site ~= nil and { x = site.x, y = site.y, z = site.z + cfg.landAltitude }
		or pointAt(body, bearing, cfg.landOffset, body.z + cfg.landAltitude)
	local from = start ~= nil and { x = start.x, y = start.y, z = start.z }
		or pointAt(land, bearing, cfg.approachMetres, body.z + cfg.approachAltitude)
	-- Out the other side: on along the line it came in on, climbing.
	local leave = pointAt(land, bearingTo(from, land), cfg.exitMetres, ground + cfg.approachAltitude)
	local g = {
		body = { x = body.x, y = body.y, z = body.z },
		start = from,
		hover = { x = land.x, y = land.y, z = ground + cfg.hoverAltitude },
		land = land,
		leave = leave,
		ground = ground,
		measured = site ~= nil,
	}
	-- The headings: nose first down the approach, square to the axes on the
	-- ground, nose first again on the way out.
	g.inbound = headingTo(g.start, g.hover)
	g.landed = square(headingTo(g.land, g.body))
	g.outbound = headingTo(g.hover, g.leave)
	return g
end

--- The pose for a phase at `u` in [0, 1]. The heading turns only while the hull
--- is hanging over the spot: on the way down to the square one it sets down on,
--- on the way up to the way out. It never snaps.
local function pose(run, phase, u)
	local g = run.geometry
	local eased = smooth(u)
	if phase == PHASE.APPROACH then
		return { x = lerp(g.start.x, g.hover.x, eased), y = lerp(g.start.y, g.hover.y, eased),
			z = lerp(g.start.z, g.hover.z, eased), yaw = g.inbound }
	elseif phase == PHASE.DESCEND then
		return { x = g.hover.x, y = g.hover.y, z = lerp(g.hover.z, g.land.z, eased),
			yaw = turn(g.inbound, g.landed, eased) }
	elseif phase == PHASE.GROUND then
		return { x = g.land.x, y = g.land.y, z = g.land.z, yaw = g.landed }
	elseif phase == PHASE.CLIMB then
		return { x = g.land.x, y = g.land.y, z = lerp(g.land.z, g.hover.z, eased),
			yaw = turn(g.landed, g.outbound, eased) }
	end
	return { x = lerp(g.hover.x, g.leave.x, eased), y = lerp(g.hover.y, g.leave.y, eased),
		z = lerp(g.hover.z, g.leave.z, eased), yaw = g.outbound }
end

local function phaseLength(run, phase)
	local cfg = run.cfg
	if phase == PHASE.APPROACH then return cfg.cruiseMs end
	if phase == PHASE.DESCEND then return cfg.descentMs end
	if phase == PHASE.CLIMB then return cfg.climbMs end
	if phase == PHASE.EXIT then return cfg.exitMs end
	return 0
end

--- The landing call on the hull's loudspeaker (`modules/avdoor`), from `from`
--- (the start of the approach when nil).
local function landingCall(run, on, why, from)
	local door = OPX.Api.Get('avdoor')
	if door == nil then return end
	local call = on and door.Callout or door.Hush
	if type(call) ~= 'function' then return end
	local ran, ok, reason
	if on then
		local start = from or run.geometry.start
		ran, ok, reason = pcall(call, run.avId, 'trauma', why,
			{ x = start.x, y = start.y, z = start.z, bucket = run.bucket })
	else
		ran, ok = pcall(call, run.avId, why)
	end
	run.calling = on and ran and ok == true or false
	if on and ran and ok ~= true then
		Open77.log.info(('[downed] trauma team: the AV flies in without its landing call: %s')
			:format(tostring(reason)))
	end
end

--- The landing pad under the hull (`modules/avdoor`, `PADS`): the red ring the
--- client draws under an AV it flies itself, which a Trauma Team airframe is
--- not. `on` asks for it, off takes it away.
local function pad(run, on, why)
	local door = OPX.Api.Get('avdoor')
	if door == nil or run.avId == nil then return end
	if on and type(door.Pad) == 'function' then
		pcall(door.Pad, run.avId, { record = run.record, bucket = run.bucket, why = why })
	elseif not on and type(door.Unpad) == 'function' then
		pcall(door.Unpad, run.avId, why)
	end
end

--- Takes one NPC out of the world, quietly.
local function removeNpc(id)
	local api = npcs()
	if id == nil or api == nil or type(api.remove) ~= 'function' then return end
	pcall(api.remove, id)
end

--- Sends one NPC somewhere on foot, when the host has the verb.
local function runTo(id, at, speed)
	local api = npcs()
	local tasks = api and api.tasks or nil
	if id == nil or type(tasks) ~= 'table' or type(tasks.moveTo) ~= 'function' then return false end
	local ran, task = pcall(tasks.moveTo, id, { x = at.x, y = at.y, z = at.z },
		{ speed = speed or 'run', acceptanceRadius = 1.2, timeoutMs = 20000 })
	return ran and task ~= nil
end

--- Turns one NPC to face a point, when the host has the verb.
local function faceTo(id, at)
	local api = npcs()
	local tasks = api and api.tasks or nil
	if id == nil or type(tasks) ~= 'table' or type(tasks.face) ~= 'function' then return end
	pcall(tasks.face, id, { x = at.x, y = at.y, z = at.z })
end

--- Puts one team member on the street: passive, silent and invulnerable. A
--- refused record is said once and costs the patient nothing.
local function agent(run, recordName, at, facing)
	local api = npcs()
	if api == nil or type(api.create) ~= 'function' then
		sayOnce('npcs', '[downed] trauma team: no Open77.npcs on this host: the AV lands with nobody aboard')
		return nil
	end
	local ai, damage = api.ai or {}, api.damage or {}
	local ran, id, reason = pcall(api.create, {
		record = recordName,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = facing,
		bucket = run.bucket,
		aiMode = ai.tasks,
		damagePolicy = damage.invulnerable,
		behavior = { combatEnabled = false, voiceEnabled = false },
		despawnWhenUnobserved = false,
		persistent = false,
	})
	if not ran or id == nil then
		sayOnce('agent:' .. tostring(recordName), ('[downed] trauma team: %s was refused: %s')
			:format(tostring(recordName), tostring(ran and reason or id)))
		return nil
	end
	return id
end

--- The team steps out of the AV: the medic on the patient's side, the guards
--- round the door.
local function deploy(run)
	local cfg, g = run.cfg, run.geometry
	local towards = bearingTo(g.land, g.body)
	local door = pointAt(g.land, towards, 2.5, g.ground)
	run.medic = agent(run, cfg.medic, door, headingTo(door, g.body))
	run.guards = {}
	for index, recordName in ipairs(cfg.guards) do
		local side = pointAt(g.land, towards + (index % 2 == 1 and 70.0 or -70.0), 3.0, g.ground)
		run.guards[#run.guards + 1] = agent(run, recordName, side, headingTo(side, g.body))
	end
	run.medicAt = { x = door.x, y = door.y, z = door.z }
end

--- The team climbs back in: what the host shows of the walk is the host's, and
--- the bodies are taken out of the world when the AV lifts.
local function disband(run)
	removeNpc(run.medic)
	for _, id in ipairs(run.guards or {}) do removeNpc(id) end
	run.medic, run.guards = nil, {}
end

--- Ends a run: the call, the team and the hull.
local function finish(run, why)
	if runs[run.id] == nil then return end
	runs[run.id] = nil
	landingCall(run, false, why)
	pad(run, false, why)
	if run.survey ~= nil and run.survey.state == 'pending' then run.survey.state = 'abandoned' end
	disband(run)
	for _, patientId in ipairs(run.queue) do
		if assigned[patientId] == run.id then assigned[patientId] = nil end
	end
	local contract = vehicles()
	if contract ~= nil and type(contract.remove) == 'function' and run.avId ~= nil then
		local ran, removed, reason = pcall(contract.remove, run.avId)
		if not ran or removed ~= true then
			Open77.log.warn(('[downed] trauma team: the AV %s could not be removed: %s')
				:format(tostring(run.avId), tostring(ran and reason or removed)))
		end
	end
	Open77.log.info(('[downed] trauma team: AV %s gone (%s) after %.0fs, %d revived')
		:format(tostring(run.avId), tostring(why), (OPX.Now() - run.startedAt) / 1000.0, run.revived))
end

--- Takes a patient off a run's list.
local function unassign(run, patientId)
	for index = #run.queue, 1, -1 do
		if run.queue[index] == patientId then table.remove(run.queue, index) end
	end
	if assigned[patientId] == run.id then assigned[patientId] = nil end
	if run.current ~= nil and run.current.patient == patientId then run.current = nil end
end

--- Whether a patient is still the team's to treat: down, and nobody's patient.
local function treatable(patientId)
	local record = internal().Record(patientId)
	if record == nil or not internal().IsDead(patientId) then return false end
	if M.Trauma ~= nil and type(M.Trauma.Treating) == 'function' and M.Trauma.Treating(patientId) then
		return false
	end
	return true
end

--- The next patient on the list the medic can go to, or nil.
local function nextPatient(run)
	while #run.queue > 0 do
		local patientId = run.queue[1]
		if treatable(patientId) then return patientId end
		table.remove(run.queue, 1)
		if assigned[patientId] == run.id then assigned[patientId] = nil end
	end
	return nil
end

--- Moves a run into a phase.
local function enter(run, phase, now)
	run.phase, run.phaseSince = phase, now
	if phase == PHASE.GROUND then
		-- Down beside the patient: the voice stops and the team steps out.
		landingCall(run, false, 'down beside the patient')
		run.groundSince = now
		deploy(run)
		Open77.log.info(('[downed] trauma team: AV %s is down, %d patient(s) to treat')
			:format(tostring(run.avId), #run.queue))
	elseif phase == PHASE.CLIMB then
		disband(run)
	end
	-- The engine is off on the ground (`ENGINE_ON_GROUND`), and on again to leave.
	if not run.cfg.engineOnGround and (phase == PHASE.GROUND or phase == PHASE.CLIMB) then
		local contract = vehicles()
		if contract ~= nil and type(contract.setEngine) == 'function' then
			pcall(contract.setEngine, run.avId, phase == PHASE.CLIMB)
		end
	end
end

--- The ground phase: the medic goes from body to body, then everyone boards.
local function treat(run, now)
	local cfg = run.cfg
	if run.boardingSince ~= nil then
		if now - run.boardingSince >= cfg.boardMs then enter(run, PHASE.CLIMB, now) end
		return
	end
	if now - run.groundSince >= cfg.holdMs then
		Open77.log.warn(('[downed] trauma team: AV %s held the ground for %ds and leaves %d patient(s)')
			:format(tostring(run.avId), math.floor(cfg.holdMs / 1000), #run.queue))
		for index = #run.queue, 1, -1 do unassign(run, run.queue[index]) end
	end

	local current = run.current
	if current ~= nil and not treatable(current.patient) then
		-- Up by other means (a player medic, a gave up, a disconnect): next.
		unassign(run, current.patient)
		current = nil
	end
	if current == nil then
		local patientId = nextPatient(run)
		if patientId == nil then
			-- Nobody left: back aboard.
			run.boardingSince = now
			runTo(run.medic, run.geometry.land, 'walk')
			for _, id in ipairs(run.guards) do runTo(id, run.geometry.land, 'walk') end
			return
		end
		local body = bodyOf(patientId, internal().Record(patientId))
		if body == nil then
			unassign(run, patientId)
			return
		end
		local from = run.medicAt or run.geometry.land
		local travelMs = math.floor(math.min(12.0, math.max(1.0, flat(from, body) / cfg.runSpeed)) * 1000)
		run.current = { patient = patientId, body = body, doneAt = now + travelMs + cfg.treatMs }
		local side = pointAt(body, bearingTo(body, from), 0.9, body.z)
		runTo(run.medic, side, 'run')
		faceTo(run.medic, body)
		for index, id in ipairs(run.guards) do
			runTo(id, pointAt(body, bearingTo(body, from) + (index % 2 == 1 and 90.0 or -90.0), 3.0, body.z), 'run')
		end
		run.medicAt = side
		notice(patientId, 'medic.notice.teamTreating')
		Open77.log.info(('[downed] trauma team: the medic of AV %s goes to %s (%d), %.0f m, %.1fs')
			:format(tostring(run.avId), nameFor(patientId), patientId, flat(from, body),
				(run.current.doneAt - now) / 1000.0))
		return
	end

	if now >= current.doneAt then
		unassign(run, current.patient)
		local revived, reason = internal().Revive(current.patient, 'trauma:team')
		if revived then
			run.revived = run.revived + 1
			Open77.log.info(('[downed] trauma team: AV %s revived %s (%d)')
				:format(tostring(run.avId), nameFor(current.patient), current.patient))
		else
			Open77.log.warn(('[downed] trauma team: the revive of %d was refused: %s')
				:format(current.patient, tostring(reason)))
		end
		run.current = nil
	end
end

--- One step of one run.
local function step(run, now)
	local contract = vehicles()
	if contract == nil or type(contract.get) ~= 'function' then return finish(run, 'no vehicle contract') end
	local ran, hull = pcall(contract.get, run.avId)
	if not ran or hull == nil then return finish(run, 'the AV was taken away') end

	-- STILL MEASURING THE GROUND: the AV waits where it was created, out and
	-- high, until the games have answered or the survey's time is up.
	if run.survey ~= nil and run.survey.state == 'pending' then
		if now < run.survey.deadline then
			run.phaseSince = now
			return
		end
		run.survey.state = 'late'
		Open77.log.warn(('[downed] trauma team: AV %s flies in without measured ground: the survey took '
			.. 'longer than %.1fs'):format(tostring(run.avId), (run.survey.deadline - run.survey.since) / 1000.0))
		run.phaseSince = now
	end

	local phase = run.phase
	if phase == PHASE.GROUND then
		treat(run, now)
		phase = run.phase
		-- NOT RE-POSED ON THE GROUND. The frozen bit pins the last canonical
		-- transform. The MaxTac insertion re-poses its street hold ten times a
		-- second, and the bot lab's client logs show that AV drifting away from
		-- its server pose during the hold (`vobserver-drift-repair`, task #140).
		if phase == PHASE.GROUND then return end
	end

	local length = phaseLength(run, phase)
	local u = length > 0 and math.min(1.0, (now - run.phaseSince) / length) or 1.0
	local at = pose(run, phase, u)
	pcall(contract.setTransform, run.avId, at)
	if run.calling then
		local door = OPX.Api.Get('avdoor')
		if door ~= nil and type(door.Follow) == 'function' then pcall(door.Follow, run.avId, at) end
	end
	if u < 1.0 then return end
	if phase == PHASE.APPROACH then
		enter(run, PHASE.DESCEND, now)
	elseif phase == PHASE.DESCEND then
		enter(run, PHASE.GROUND, now)
	elseif phase == PHASE.CLIMB then
		enter(run, PHASE.EXIT, now)
	elseif phase == PHASE.EXIT then
		finish(run, 'away')
	end
end

--- The record the next hull is flown in: the first of `records` after `after`
--- (from the top when nil) that no game failed to draw. From the top, when
--- every one has failed, the first is flown anyway and that is said once.
-- @return string|nil
local function pickRecord(cfg, after)
	local list = type(cfg.records) == 'table' and #cfg.records > 0 and cfg.records or { cfg.record }
	local from = 1
	if after ~= nil then
		for index, name in ipairs(list) do
			if name == after then from = index + 1 end
		end
	end
	for index = from, #list do
		if seen[list[index]] ~= 'undrawn' then return list[index] end
	end
	if after ~= nil then return nil end
	sayOnce('undrawn', ('[downed] trauma team: no game drew any of %s; flying %s anyway')
		:format(table.concat(list, ', '), tostring(list[1])))
	return list[1]
end

--- Creates one hull where a run is, pinned for the server's poses. Answers the
--- id, or nil and why not.
local function hull(run, recordName, at, yaw, engineOn)
	local contract = vehicles()
	local masks = type(contract.flags) == 'table' and contract.flags or {}
	local createFlags = (engineOn and (masks.engineOn or 0) or 0) + (masks.lightsOn or 0)
	local ran, avId, reason = pcall(contract.create, {
		record = recordName,
		position = { x = at.x, y = at.y, z = at.z },
		yaw = yaw,
		bucket = run.bucket,
		flags = createFlags > 0 and createFlags or nil,
	})
	if not ran or avId == nil then return nil, tostring(ran and reason or avId) end
	-- Frozen so no client's own simulation argues with the server's pose.
	if type(contract.setFrozen) == 'function' then pcall(contract.setFrozen, avId, true) end
	if type(contract.setEngine) == 'function' then pcall(contract.setEngine, avId, engineOn == true) end
	if type(contract.setLights) == 'function' then pcall(contract.setLights, avId, 'high') end
	-- Locked: this AV carries the team and nobody else. A crew door
	-- (`modules/avdoor`) does not open on a locked hull.
	if type(contract.setLocked) == 'function' then pcall(contract.setLocked, avId, true) end
	return avId
end

--- Asks every game near where a run comes down whether it draws the hull, while
--- the run's record is not yet known to be drawn. Answers how many were asked.
local function watch(run)
	if seen[run.record] == 'drawn' then return 0 end
	local players = type(Open77) == 'table' and Open77.players or nil
	if type(players) ~= 'table' or type(players.all) ~= 'function' or type(players.position) ~= 'function' then
		return 0
	end
	local listed, list = pcall(players.all)
	local land, asked = run.geometry.land, 0
	for _, playerId in ipairs(listed and type(list) == 'table' and list or {}) do
		local id = tonumber(playerId)
		local read, at = pcall(players.position, id)
		if id ~= nil and read and type(at) == 'table' and finite(at.x) and finite(at.y)
			and (tonumber(at.bucket) or 0) == run.bucket and flat(at, land) <= run.cfg.watchMetres then
			pcall(TriggerClientEvent, M.TraumaEvent.TEAM_WATCH, id,
				{ id = tostring(run.avId), record = run.record, ms = run.cfg.watchMs })
			asked = asked + 1
		end
	end
	return asked
end

--- Puts a run in another airframe where it is: the next record in the list,
--- created at the run's pose this instant, the old hull removed, the landing
--- call moved over, the nearby games asked again.
-- @return boolean
local function swap(run, recordName, why)
	local contract = vehicles()
	if contract == nil or type(contract.create) ~= 'function' then return false end
	while recordName ~= nil do
		local now = OPX.Now()
		local length = phaseLength(run, run.phase)
		local u = length > 0 and math.min(1.0, (now - run.phaseSince) / length) or 1.0
		local at = pose(run, run.phase, u)
		local engineOn = run.cfg.engineOnGround or run.phase ~= PHASE.GROUND
		local avId, refused = hull(run, recordName, at, at.yaw, engineOn)
		if avId ~= nil then
			local old, oldRecord, calling = run.avId, run.record, run.calling
			if calling then landingCall(run, false, 'the airframe was swapped') end
			pad(run, false, 'the airframe was swapped')
			if type(contract.remove) == 'function' then pcall(contract.remove, old) end
			run.avId, run.record = avId, recordName
			if calling then landingCall(run, true, 'the Trauma Team, in another airframe', at) end
			pad(run, true, 'the Trauma Team, in another airframe')
			Open77.log.warn(('[downed] trauma team: AV %s (%s) %s: it flies on as AV %s (%s), %s')
				:format(tostring(old), tostring(oldRecord), why, tostring(avId), recordName, run.phase))
			watch(run)
			return true
		end
		seen[recordName] = 'undrawn'
		Open77.log.warn(('[downed] trauma team: the AV %s was refused: %s'):format(recordName, refused))
		recordName = pickRecord(run.cfg, recordName)
	end
	return false
end

--- A game near a run says whether it draws the hull (`TEAM_SEEN`).
-- One game that drew a record marks it drawn for good; one that registered the
-- hull and never drew it marks it undrawn -- unless another game already drew it,
-- because then the record is fine and that game is only slow -- and the run is
-- flown on in the next record.
-- @param playerId number
-- @param payload table `{ id, state, ms }`
function Team.Seen(playerId, payload)
	if type(payload) ~= 'table' then return end
	local state = payload.state
	if state ~= 'streamed' and state ~= 'stuck' then return end
	local key = tostring(payload.id)
	local run = nil
	for _, candidate in pairs(runs) do
		if tostring(candidate.avId) == key then run = candidate end
	end
	-- An answer about a hull that is gone, swapped, or never was ours.
	if run == nil then return end
	local name = run.record
	if state == 'streamed' then
		if seen[name] ~= 'drawn' then
			seen[name] = 'drawn'
			Open77.log.info(('[downed] trauma team: player %s\'s game draws the AV (%s)')
				:format(tostring(playerId), name))
		end
		return
	end
	if seen[name] == 'drawn' then return end
	seen[name] = 'undrawn'
	local nextRecord = pickRecord(run.cfg, name)
	local why = ('was registered by player %s\'s game and not drawn in %.0fs')
		:format(tostring(playerId), (tonumber(payload.ms) or 0) / 1000.0)
	if nextRecord == nil or not swap(run, nextRecord, why) then
		Open77.log.warn(('[downed] trauma team: AV %s (%s) %s, and no other record is left to fly it in')
			:format(key, name, why))
	end
end

--- Asks the games where the AV may come down near the body (avdoor
--- `LandingSite`): flat, open ground at the body's level. The AV waits out and
--- high until they answer (`step`); a host that cannot be asked flies the old
--- place at once. The answer is taken only while it is still this run's.
local function survey(run, body, bearing)
	local door = OPX.Api.Get('avdoor')
	if door == nil or type(door.LandingSite) ~= 'function' or type(door.CanSurvey) ~= 'function' then return end
	if type(CreateThread) ~= 'function' then return end
	local asked, can = pcall(door.CanSurvey)
	if not asked or can ~= true then return end
	local budget = 4000
	if type(door.SurveyBudgetMs) == 'function' then
		local read, ms = pcall(door.SurveyBudgetMs)
		if read and tonumber(ms) ~= nil then budget = tonumber(ms) end
	end
	local since = OPX.Now()
	local state = { state = 'pending', since = since, deadline = since + budget + 1500 }
	run.survey = state
	local cfg = run.cfg
	CreateThread(function()
		local ran, site, why = pcall(door.LandingSite, body, { bearing = bearing, near = cfg.landOffset })
		if state.state ~= 'pending' or runs[run.id] ~= run then return end
		state.state = 'done'
		if ran and type(site) == 'table' then
			run.geometry = geometry(body, cfg, bearing, site, run.geometry.start)
			Open77.log.info(('[downed] trauma team: AV %s comes down on measured ground %.0f m from the body '
				.. '(%.1f m %s it, %d probe(s), %.1fs)'):format(tostring(run.avId), site.distance or 0,
				math.abs(site.z - body.z), site.z >= body.z and 'above' or 'below', site.probes or 0,
				(OPX.Now() - since) / 1000.0))
		else
			Open77.log.warn(('[downed] trauma team: AV %s comes down at the old place, %.0f m from the body '
				.. 'at its height: %s'):format(tostring(run.avId), cfg.landOffset, tostring(ran and why or site)))
		end
	end)
end

--- Flies an AV to a patient. Answers the run, or nil and why not.
local function launch(patientId, body, bucket, cfg, now)
	local contract = vehicles()
	if contract == nil or type(contract.create) ~= 'function' or type(contract.setTransform) ~= 'function' then
		sayOnce('vehicles', '[downed] trauma team: no Open77.vehicles on this host: no AV is flown')
		return nil, 'vehicles_unavailable'
	end
	local bearing = bearingFor(patientId)
	local g = geometry(body, cfg, bearing)
	nextRun = nextRun + 1
	local run = {
		id = nextRun, avId = nil, bucket = bucket, cfg = cfg, geometry = g,
		phase = PHASE.APPROACH, phaseSince = now, startedAt = now,
		queue = { patientId }, current = nil, guards = {}, revived = 0, calling = false,
	}
	-- The first record no game failed to draw, and the next when the host refuses one.
	local recordName, avId, why = pickRecord(cfg, nil), nil, nil
	while recordName ~= nil and avId == nil do
		avId, why = hull(run, recordName, g.start, g.inbound, true)
		if avId == nil then
			seen[recordName] = 'undrawn'
			sayOnce('create:' .. recordName, ('[downed] trauma team: the AV %s was refused: %s')
				:format(recordName, tostring(why)))
			recordName = pickRecord(cfg, recordName)
		end
	end
	if avId == nil then return nil, why end
	run.avId, run.record = avId, recordName

	runs[run.id] = run
	assigned[patientId] = run.id
	landingCall(run, true, ('the Trauma Team for %s'):format(nameFor(patientId)))
	pad(run, true, ('the Trauma Team for %s'):format(nameFor(patientId)))
	survey(run, body, bearing)
	local asked = watch(run)
	Open77.log.info(('[downed] trauma team: AV %s (%s) inbound for %s (%d) from %.0f m out, %.0fs to the ground%s')
		:format(tostring(avId), recordName, nameFor(patientId), patientId, cfg.approachMetres,
			(cfg.cruiseMs + cfg.descentMs) / 1000.0,
			asked > 0 and (', %d game(s) asked whether they draw it'):format(asked) or ''))
	return run
end

--- An AV still coming, or still on the ground, near enough to take this patient.
local function sceneFor(body, bucket, cfg)
	for _, run in pairs(runs) do
		if run.bucket == bucket and run.boardingSince == nil
			and (run.phase == PHASE.APPROACH or run.phase == PHASE.DESCEND or run.phase == PHASE.GROUND)
			and flat(run.geometry.body, body) <= cfg.sceneMetres then
			return run
		end
	end
	return nil
end

--- Whether a waiting patient's turn for the team has come.
local function due(patientId, record, cfg, now)
	local since = tonumber(record.waitingSinceMs) or tonumber(record.sinceMs)
	if since == nil then return false end
	local paged = tonumber(record.paged) or 0
	if paged > 0 then
		if cfg.headStartMs == false then return false end
		return now - since >= math.max(cfg.delayMs, cfg.headStartMs)
	end
	return now - since >= cfg.delayMs
end

--- One pass: patients whose turn has come are flown to, and every run moves.
function Team.Pass()
	local cfg = M.TeamSettings()
	local now = OPX.Now()
	if not cfg.off then
		local count = 0
		for _ in pairs(runs) do count = count + 1 end
		for patientId, record in pairs(internal().Records()) do
			if record.waiting and assigned[patientId] == nil and due(patientId, record, cfg, now)
				and treatable(patientId) then
				local body, bucket = bodyOf(patientId, record)
				if body ~= nil then
					local run = sceneFor(body, bucket, cfg)
					if run ~= nil then
						run.queue[#run.queue + 1] = patientId
						assigned[patientId] = run.id
						notice(patientId, 'medic.notice.teamInbound')
						Open77.log.info(('[downed] trauma team: %s (%d) joins AV %s, %d on its list')
							:format(nameFor(patientId), patientId, tostring(run.avId), #run.queue))
					elseif count < cfg.maxRuns then
						if launch(patientId, body, bucket, cfg, now) ~= nil then
							count = count + 1
							notice(patientId, 'medic.notice.teamInbound')
						end
					end
				end
			end
		end
	end
	local list = {}
	for _, run in pairs(runs) do list[#list + 1] = run end
	table.sort(list, function(a, b) return a.id < b.id end)
	for _, run in ipairs(list) do
		local ran, failure = pcall(step, run, now)
		if not ran then
			Open77.log.error(('[downed] trauma team: AV %s failed a step: %s'):format(tostring(run.avId), tostring(failure)))
			finish(run, 'a step failed')
		end
	end
end

--- A patient is up, or gone: off whatever list they were on.
function Team.Stood(patientId)
	local id = assigned[patientId]
	local run = id ~= nil and runs[id] or nil
	if run ~= nil then unassign(run, patientId) else assigned[patientId] = nil end
end

--- What the team is doing, for the suite and the console.
function Team.Status()
	local out = {}
	for _, run in pairs(runs) do
		out[#out + 1] = { avId = run.avId, record = run.record, phase = run.phase, queue = #run.queue,
			revived = run.revived, medic = run.medic, guards = #run.guards,
			current = run.current and run.current.patient or nil,
			measured = run.geometry.measured == true, ground = run.geometry.ground,
			survey = run.survey ~= nil and run.survey.state or nil }
	end
	table.sort(out, function(a, b) return tostring(a.avId) < tostring(b.avId) end)
	return out
end

--- Takes every AV and every team member out of the world.
function Team.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local list = {}
	for _, run in pairs(runs) do list[#list + 1] = run end
	for _, run in ipairs(list) do finish(run, 'the module stopped') end
end

--- What the games said about each airframe record, for the suite and the console.
-- @return table `{ [record] = 'drawn'|'undrawn' }`
function Team.Airframes()
	local out = {}
	for name, state in pairs(seen) do out[name] = state end
	return out
end

--- Forgets everything, without touching the host.
function Team.Reset()
	runs, assigned, told, nextRun, job, seen = {}, {}, {}, 0, nil, {}
end

--- Starts the team's pass.
function Team.Start()
	local cfg = M.TeamSettings()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = OPX.Scheduler.Every('downed:team', cfg.tickMs, function()
		local ran, failure = pcall(Team.Pass)
		if not ran then Open77.log.error('[downed] trauma team: the pass failed: ' .. tostring(failure)) end
	end)
	-- The games' answer about the airframe: no payload is trusted beyond the
	-- hull it names and one of two words, and the sender is the connection.
	if not wired then
		wired = true
		RegisterNetEvent(M.TraumaEvent.TEAM_SEEN, function(payload)
			local playerId = tonumber(source)
			if playerId == nil or playerId <= 0 then return end
			if OPX.Cooling(playerId, 'downed.teamSeen', 250) then return end
			local ran, failure = pcall(Team.Seen, playerId, payload)
			if not ran then
				Open77.log.error('[downed] trauma team: an answer about the AV could not be read: ' .. tostring(failure))
			end
		end)
	end
	if cfg.off then
		Open77.log.info('[downed] trauma team: OFF -- no AV answers a distress signal')
	else
		Open77.log.info(('[downed] trauma team: %s answers a distress signal after %ds (%s when a medic was paged), '
			.. 'medic %s, up to %d AV(s)%s'):format(cfg.record, math.floor(cfg.delayMs / 1000),
			cfg.headStartMs == false and 'never' or (math.floor(cfg.headStartMs / 1000) .. 's'),
			cfg.medic, cfg.maxRuns,
			#cfg.records > 1 and (' (then %s, if a game cannot draw it)'):format(
				table.concat(cfg.records, ', ', 2)) or ''))
	end
end
