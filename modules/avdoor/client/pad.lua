--- Client half of the landing pad: the red ring under an AV the server flies,
--- drawn here for the records the client does not pad itself.
-- @author XEROX710
--
-- WHAT IS DRAWN, AND WHY IT LOOKS LIKE THIS. The Open77 client draws its own
-- landing pad under any hull of a record it flies as an AV (`ApplyLandingLaser`
-- and `ApplyAvDownwash`, client/src/api/Vehicles.cpp; `SetAvHover` for the
-- voice): twelve vertical `laser.mine` beams on a 3.5 m ring on the terrain
-- under the hull, a thirteenth orbiting inside it at 0.85 of the ring at 2.2
-- radians a second, and OPEN77 in a 4x5 dot matrix across the middle, laid out
-- along the world's axes -- shown when the hull is within 6 m of the ground and
-- coming down faster than 0.4 m/s or resting within 2.2 m, kept while it stays
-- within 6 m, and taken away after ten looks in a row out of that band. With it
-- the prologue's AV dust (`q001_av_dust_loop`) on the ground under the hull and
-- the Trauma AV's own engine voice (`v_av_trauma_big_engine_start`). The bot
-- lab, 2026-10-07: "make sure the trauma team av has the red warning laser
-- underneath like maxtac av does". The Trauma Team's airframes are not records
-- the client flies as AVs, so this file draws the same pad, with the same
-- numbers (`PADS` in config/avdoor.lua), under the hulls the server names
-- (`M.Event.PAD`).
--
-- CENTRED ON THE HULL, NOT ON ITS PIVOT. The client's own pad is drawn round
-- the entity's origin. This one is drawn round the centre of the hull's loaded
-- mesh (`Open77.world.entityGeometry` bounds), which is where a player's eye
-- puts the middle of the aircraft; the ground is measured under that centre
-- with a static ray (`Open77.world.groundZ`), so a hull is never padded on a
-- roof above it or over water. The bot lab, 2026-10-07: "make sure there both
-- center with av". For a hull the client pads itself the distance between the
-- two centres is written to the log once per record, so a pad drawn off the
-- aircraft can be named rather than guessed at.
--
-- SQUARE TO THE AIRCRAFT. The sign runs along the world's axes, as the
-- client's does, and the AVs the server flies set down square to those axes
-- (`modules/ncpd/server/av.lua` and `modules/downed/server/team.lua`), so the
-- ring and its sign sit square under both airframes rather than across them.

local M = OPX.Modules.Get('avdoor')

M.Pad = {}
local Pad = M.Pad

local TAU = math.pi * 2.0

-- The OPEN77 sign: six 4x5 glyphs, the most significant bit of each row the
-- leftmost dot, one empty column between glyphs -- 29 columns, 60 lit dots.
local FONT = {
	{ 0x6, 0x9, 0x9, 0x9, 0x6 }, -- O
	{ 0xE, 0x9, 0x9, 0xE, 0x8 }, -- P
	{ 0xF, 0x8, 0x8, 0xF, 0x8 }, -- E
	{ 0x9, 0xD, 0xB, 0x9, 0x9 }, -- N
	{ 0xF, 0x1, 0x2, 0x4, 0x4 }, -- 7
	{ 0xF, 0x1, 0x2, 0x4, 0x4 }, -- 7
}
local GLYPH_COLS, GLYPH_ROWS = 4, 5
local GRID_COLS = #FONT * GLYPH_COLS + (#FONT - 1)
-- The sign is 1.55 ring radii wide; the marker orbits at 0.85 of the ring,
-- between the sign and the ring; it turns at 2.2 radians a second.
local SIGN_SPAN = 1.55
local MARKER_SCALE = 0.85
local SPIN_RATE = 2.2
-- Looks in a row out of the band before the pad is taken away: a probe that
-- flips for one frame never takes it down.
local RETIRE_LOOKS = 10
-- How often the dust is moved, and the ground under the centre measured.
local DUST_MS = 100
local GROUND_MS = 500
-- The beam asset the client's own pad is made of.
local BEAM = 'laser.mine'
local IDENTITY = { x = 0.0, y = 0.0, z = 0.0, w = 1.0 }

-- Hulls this client was told to pad, by id as text.
local pads = {}
-- The scheduler job, while the module runs.
local job = nil
-- Things said once: a refused effect, a record measured.
local said = {}

local function sayOnce(key, line)
	if said[key] then return end
	said[key] = true
	Open77.log.info(line)
end

local function finite(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number == math.huge or number == -math.huge then return nil end
	return number
end

--- A point `{ x, y, z }` from a table with x/y/z or [1]/[2]/[3], or nil.
local function pointFrom(value)
	if type(value) ~= 'table' then return nil end
	local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

--- The PADS block, each number inside a band; nil when it is off.
-- @return table|nil
function Pad.Settings()
	local declared = nil
	if type(M.Settings) == 'table' then declared = M.Settings.PADS end
	if declared == false then return nil end
	local block = type(declared) == 'table' and declared or {}
	local voice = nil
	if block.VOICE ~= false then
		local spec = type(block.VOICE) == 'table' and block.VOICE or {}
		local start = type(spec.START) == 'string' and spec.START ~= '' and spec.START
			or 'v_av_trauma_big_engine_start'
		local stop = type(spec.STOP) == 'string' and spec.STOP ~= '' and spec.STOP or nil
		if spec.STOP == nil and type(block.VOICE) ~= 'table' then stop = 'v_av_trauma_big_engine_stop' end
		voice = { start = start, stop = stop }
	end
	local dust = nil
	if block.DUST ~= false then
		dust = type(block.DUST) == 'string' and block.DUST ~= '' and block.DUST
			or 'base\\fx\\quest\\q001\\00c_rescuing_girl\\q001_av_dust_loop.effect'
	end
	return {
		radius = M.Number(block.RADIUS_METRES, 1.0, 20.0, 3.5),
		beams = math.floor(M.Number(block.BEAMS, 4, 32, 12)),
		sign = block.SIGN ~= false,
		show = M.Number(block.SHOW_METRES, 1.0, 50.0, 6.0),
		rest = M.Number(block.REST_METRES, 0.0, 20.0, 2.2),
		descend = M.Number(block.DESCEND_SPEED, 0.0, 20.0, 0.4),
		dust = dust,
		dustMetres = M.Number(block.DUST_METRES, 1.0, 50.0, 11.0),
		voice = voice,
	}
end

--- One streamed hull's client snapshot, or nil. The host reads an id as an
--- integer or as its decimal string; the other spelling is tried as well.
local function snapshotOf(id)
	local api = Open77.vehicles
	if type(api) ~= 'table' or type(api.get) ~= 'function' or id == nil then return nil end
	local read, snapshot = pcall(api.get, id)
	if read and type(snapshot) == 'table' then return snapshot end
	local number = tonumber(id)
	if number ~= nil and number ~= id then
		read, snapshot = pcall(api.get, number)
		if read and type(snapshot) == 'table' then return snapshot end
	end
	return nil
end

--- What this client draws of a hull: `{ position, forward, centre, size }`,
--- the centre being the middle of the loaded mesh when the engine has one, and
--- nil when the hull is not drawn here at all.
-- @param id any
-- @param snapshot table|nil
-- @return table|nil
local function frameOf(id, snapshot)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.entityGeometry) ~= 'function' then return nil end
	local refs = { { kind = 'vehicle', id = id } }
	local number = tonumber(id)
	if number ~= nil and number ~= id then refs[#refs + 1] = { kind = 'vehicle', id = number } end
	if snapshot ~= nil and snapshot.entity ~= nil then refs[#refs + 1] = snapshot.entity end
	for _, ref in ipairs(refs) do
		local read, answer = pcall(world.entityGeometry, ref)
		if read and type(answer) == 'table' and answer.attached ~= false then
			local position = pointFrom(answer.position)
			if position ~= nil then
				local frame = { position = position, centre = { x = position.x, y = position.y }, size = nil }
				local forward = pointFrom(answer.forward)
				if forward ~= nil and (forward.x ~= 0 or forward.y ~= 0) then frame.forward = forward end
				local bounds = type(answer.bounds) == 'table' and answer.bounds or nil
				local low = bounds and pointFrom(bounds.min) or nil
				local high = bounds and pointFrom(bounds.max) or nil
				if low ~= nil and high ~= nil and high.x > low.x and high.y > low.y then
					frame.centre = { x = (low.x + high.x) * 0.5, y = (low.y + high.y) * 0.5 }
					frame.size = { x = high.x - low.x, y = high.y - low.y, z = high.z - low.z }
				end
				return frame
			end
		end
	end
	return nil
end

--- The height of the static ground under a point, or nil.
local function groundBelow(x, y, fromZ)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.groundZ) ~= 'function' then return nil end
	local read, z = pcall(world.groundZ, x, y, fromZ)
	if not read then return nil end
	return finite(z)
end

--- Puts one beam at a point: the handle it had, moved, or a new one.
-- @return string|nil the handle
local function beam(handle, point)
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.play) ~= 'function' then
		sayOnce('novfx', '[avdoor] no Open77.vfx on this client: no landing pad is drawn here')
		return nil
	end
	if handle ~= nil and type(vfx.update) == 'function' then
		local read, ok = pcall(vfx.update, handle, { position = point, orientation = IDENTITY })
		if read and ok ~= nil and ok ~= false then return handle end
		pcall(vfx.stop, handle)
	end
	local read, created, why = pcall(vfx.play, BEAM, { position = point, orientation = IDENTITY })
	if read and created ~= nil and created ~= false then return created end
	sayOnce('beam:' .. tostring(read and why or created),
		('[avdoor] a landing pad beam was refused: %s'):format(tostring(read and why or created)))
	return nil
end

local function stop(handle)
	local vfx = Open77.vfx
	if handle ~= nil and type(vfx) == 'table' and type(vfx.stop) == 'function' then pcall(vfx.stop, handle) end
end

--- The lit dots of the sign, as offsets from its centre for a ring radius.
local function signOffsets(radius)
	local dot = radius * SIGN_SPAN / GRID_COLS
	local out = {}
	for glyph, rows in ipairs(FONT) do
		for row = 1, GLYPH_ROWS do
			for col = 1, GLYPH_COLS do
				if (rows[row] & (0x8 >> (col - 1))) ~= 0 then
					local gcol = (glyph - 1) * (GLYPH_COLS + 1) + (col - 1)
					out[#out + 1] = {
						x = (gcol - (GRID_COLS - 1) * 0.5) * dot,
						y = ((GLYPH_ROWS - 1) * 0.5 - (row - 1)) * dot,
					}
				end
			end
		end
	end
	return out
end

--- Takes a pad's beams off the ground.
local function retire(pad, why)
	for index, handle in pairs(pad.ring) do stop(handle); pad.ring[index] = nil end
	for index, handle in pairs(pad.sign) do stop(handle); pad.sign[index] = nil end
	stop(pad.marker)
	pad.marker = nil
	if pad.up then
		Open77.log.info(('[avdoor] landing pad under %s off (%s)'):format(pad.key, tostring(why)))
	end
	pad.up, pad.laid, pad.retire, pad.spinAt = false, nil, 0, nil
end

local function dustOff(pad)
	stop(pad.dust)
	pad.dust = nil
end

--- The engine's voice, while the hull's engine runs and the hull is drawn here.
local function voice(pad, snapshot, cfg)
	if cfg.voice == nil then return end
	local sfx = Open77.sfx
	if type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then return end
	local entity = snapshot ~= nil and snapshot.streamed ~= false and snapshot.entity or nil
	local running = entity ~= nil and snapshot.engineOn == true
	if running and pad.voice == nil then
		local read, handle, why = pcall(sfx.play, cfg.voice.start, { entity = entity })
		if read and handle ~= nil and handle ~= false then
			pad.voice = handle
			sayOnce('voice:' .. pad.key, ('[avdoor] %s on %s: playing'):format(cfg.voice.start, pad.key))
		else
			sayOnce('voicefail:' .. pad.key, ('[avdoor] %s on %s was refused: %s')
				:format(cfg.voice.start, pad.key, tostring(read and why or handle)))
			pad.voice = false
		end
	elseif not running and pad.voice ~= nil then
		if pad.voice ~= false and type(sfx.stop) == 'function' then pcall(sfx.stop, pad.voice) end
		if pad.voice ~= false and entity ~= nil and cfg.voice.stop ~= nil then
			pcall(sfx.play, cfg.voice.stop, { entity = entity, duration = 4 })
		end
		pad.voice = nil
	end
end

local function voiceOff(pad, cfg)
	local sfx = Open77.sfx
	if pad.voice ~= nil and pad.voice ~= false and type(sfx) == 'table' and type(sfx.stop) == 'function' then
		pcall(sfx.stop, pad.voice)
		local snapshot = snapshotOf(pad.id)
		if cfg ~= nil and cfg.voice ~= nil and cfg.voice.stop ~= nil and snapshot ~= nil
			and snapshot.entity ~= nil and type(sfx.play) == 'function' then
			pcall(sfx.play, cfg.voice.stop, { entity = snapshot.entity, duration = 4 })
		end
	end
	pad.voice = nil
end

--- Lays the ring and the sign round a centre on the ground, moving them only
--- when the centre or the ground moved, and turns the marker.
local function lay(pad, cx, cy, ground, now, cfg)
	local moved = pad.laid == nil or math.abs(pad.laid.x - cx) > 0.05 or math.abs(pad.laid.y - cy) > 0.05
		or math.abs(pad.laid.z - ground) > 0.05
	if moved then
		for index = 1, cfg.beams do
			local theta = (index - 1) * TAU / cfg.beams
			pad.ring[index] = beam(pad.ring[index], {
				x = cx + cfg.radius * math.cos(theta), y = cy + cfg.radius * math.sin(theta), z = ground })
		end
		if cfg.sign then
			pad.offsets = pad.offsets or signOffsets(cfg.radius)
			for index, offset in ipairs(pad.offsets) do
				pad.sign[index] = beam(pad.sign[index], { x = cx + offset.x, y = cy + offset.y, z = ground })
			end
		end
		pad.laid = { x = cx, y = cy, z = ground }
	end
	if pad.spinAt ~= nil then
		pad.spin = (pad.spin + SPIN_RATE * math.max(0.0, (now - pad.spinAt) / 1000.0)) % TAU
	end
	pad.spinAt = now
	local orbit = cfg.radius * MARKER_SCALE
	pad.marker = beam(pad.marker, {
		x = cx + orbit * math.cos(pad.spin), y = cy + orbit * math.sin(pad.spin), z = ground })
	if not pad.up then
		pad.up = true
		local count = 0
		for _ in pairs(pad.ring) do count = count + 1 end
		for _ in pairs(pad.sign) do count = count + 1 end
		Open77.log.info(('[avdoor] landing pad under %s (%s) on: %d beam(s), ring %.1f m round %.1f, %.1f, '
			.. 'ground %.1f'):format(pad.key, tostring(pad.record), count + (pad.marker and 1 or 0), cfg.radius,
			cx, cy, ground))
	end
end

--- The dust under the hull, within `DUST_METRES` of the ground, turned with it.
local function dust(pad, frame, cx, cy, drop, now, cfg)
	if cfg.dust == nil then return end
	local within = drop > 0 and drop <= cfg.dustMetres + (pad.dust ~= nil and 3.0 or 0.0)
	if not within then return dustOff(pad) end
	if pad.dust ~= nil and now - (pad.dustAt or 0) < DUST_MS then return end
	pad.dustAt = now
	local yaw = 0.0
	if frame.forward ~= nil then yaw = math.atan(-frame.forward.x, frame.forward.y) end
	local orientation = { x = 0.0, y = 0.0, z = math.sin(yaw * 0.5), w = math.cos(yaw * 0.5) }
	local point = { x = cx, y = cy, z = pad.ground + 0.08 }
	local vfx = Open77.vfx
	if type(vfx) ~= 'table' or type(vfx.play) ~= 'function' then return end
	if pad.dust ~= nil and type(vfx.update) == 'function' then
		local read, ok = pcall(vfx.update, pad.dust, { position = point, orientation = orientation })
		if read and ok ~= nil and ok ~= false then return end
		dustOff(pad)
	end
	local read, handle, why = pcall(vfx.play, cfg.dust, { position = point, orientation = orientation })
	if read and handle ~= nil and handle ~= false then
		pad.dust = handle
	else
		sayOnce('dust:' .. tostring(read and why or handle),
			('[avdoor] the AV dust was refused: %s'):format(tostring(read and why or handle)))
		-- Not asked again for this hull: a refused asset is refused every time.
		pad.dust, pad.dustAt = nil, now + 3600000
	end
end

--- Writes down, once per record, how far a hull's mesh centre is from its
--- origin -- the point the client's own pad is drawn round.
local function measure(pad, frame)
	if pad.measured or frame == nil or frame.size == nil then return end
	pad.measured = true
	local dx, dy = frame.centre.x - frame.position.x, frame.centre.y - frame.position.y
	sayOnce('measure:' .. tostring(pad.record),
		('[avdoor] %s: mesh %.1f x %.1f x %.1f m, its centre %.2f m from the origin the client%s pad is drawn round')
			:format(tostring(pad.record), frame.size.x, frame.size.y, frame.size.z, math.sqrt(dx * dx + dy * dy),
				pad.platform and '\'s own' or ' would have'))
end

--- One look at one hull this client was told to pad.
local function look(pad, now, cfg)
	local snapshot = snapshotOf(pad.id)
	local frame = frameOf(pad.id, snapshot)
	measure(pad, frame)
	if pad.platform then return end
	voice(pad, snapshot, cfg)
	if frame == nil then
		if pad.up then retire(pad, 'not drawn here') end
		dustOff(pad)
		pad.lastZ, pad.lastAt = nil, nil
		return
	end
	local cx, cy, z = frame.centre.x, frame.centre.y, frame.position.z
	if pad.ground == nil or now - (pad.groundAt or 0) >= GROUND_MS
		or math.abs((pad.groundX or cx) - cx) > 0.5 or math.abs((pad.groundY or cy) - cy) > 0.5 then
		pad.ground = groundBelow(cx, cy, z + 1.0)
		pad.groundAt, pad.groundX, pad.groundY = now, cx, cy
	end
	local drop = pad.ground ~= nil and z - pad.ground or -1.0
	local vz = 0.0
	if pad.lastZ ~= nil and pad.lastAt ~= nil and now > pad.lastAt then
		vz = (z - pad.lastZ) / ((now - pad.lastAt) / 1000.0)
		if math.abs(vz) > 60.0 then vz = 0.0 end
	end
	pad.lastZ, pad.lastAt = z, now
	local show = drop > 0 and drop <= cfg.show and (vz < -cfg.descend or drop <= cfg.rest)
	local stay = pad.up and drop > 0 and drop <= cfg.show
	if show or stay then
		pad.retire = 0
		lay(pad, cx, cy, pad.ground, now, cfg)
	elseif pad.up then
		pad.retire = pad.retire + 1
		if pad.retire >= RETIRE_LOOKS then
			retire(pad, ('%.1f m over the ground, %.1f m/s'):format(drop, vz))
		end
	end
	dust(pad, frame, cx, cy, drop, now, cfg)
end

--- One pass over every hull this client was told to pad.
function Pad.Step()
	if next(pads) == nil then return end
	local cfg = Pad.Settings()
	if cfg == nil then return end
	local now = OPX.Now()
	for key, pad in pairs(pads) do
		local ran, failure = pcall(look, pad, now, cfg)
		if not ran then
			sayOnce('look:' .. key, ('[avdoor] the landing pad under %s failed: %s'):format(key, tostring(failure)))
		end
	end
end

--- Forgets one hull's pad, taking down everything drawn for it.
-- @param key string
-- @param why string
function Pad.Drop(key, why)
	local pad = pads[key]
	if pad == nil then return false end
	pads[key] = nil
	retire(pad, why)
	dustOff(pad)
	voiceOff(pad, Pad.Settings())
	return true
end

--- The server's word about one hull (`M.Event.PAD`).
-- @param payload table `{ id, on, record, platform }`
function Pad.Told(payload)
	if type(payload) ~= 'table' or payload.id == nil then return end
	local key = M.DecimalId(payload.id) or tostring(payload.id)
	if payload.on ~= true then
		Pad.Drop(key, 'the server took it away')
		return
	end
	if pads[key] ~= nil then return end
	local id = payload.id
	if type(id) == 'string' and id:match('^%d+$') and #id < 16 then id = tonumber(id) end
	pads[key] = {
		id = id, key = key, record = payload.record, platform = payload.platform == true,
		ring = {}, sign = {}, marker = nil, up = false, laid = nil, retire = 0,
		spin = 0.0, spinAt = nil, voice = nil, dust = nil, measured = false,
	}
end

--- What this client is padding, for the suite and the console.
function Pad.Status()
	local out = {}
	for key, pad in pairs(pads) do
		local beams = 0
		for _ in pairs(pad.ring) do beams = beams + 1 end
		for _ in pairs(pad.sign) do beams = beams + 1 end
		if pad.marker ~= nil then beams = beams + 1 end
		out[#out + 1] = { id = key, record = pad.record, platform = pad.platform, up = pad.up, beams = beams,
			dust = pad.dust ~= nil, voice = pad.voice ~= nil and pad.voice ~= false,
			centre = pad.laid and { x = pad.laid.x, y = pad.laid.y, z = pad.laid.z } or nil }
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function Pad.Start()
	RegisterNetEvent(M.Event.PAD, function(payload)
		local ran, failure = pcall(Pad.Told, payload)
		if not ran then Open77.log.warn('[avdoor] a landing pad could not be read: ' .. tostring(failure)) end
	end)
	-- A hull taken out of the world takes its pad with it, whatever the server
	-- gets round to saying.
	AddEventHandler('open77:vehicleRemoved', function(id)
		if id == nil then return end
		Pad.Drop(M.DecimalId(id) or tostring(id), 'the hull was removed')
	end)
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	-- Thirty looks a second, the client's own pad's cadence: the marker turns
	-- smoothly and the band is judged as often as the hull moves.
	job = OPX.Scheduler.Every('avdoor:pad', 33, function()
		local ran, failure = pcall(Pad.Step)
		if not ran then Open77.log.warn('[avdoor] the landing pad pass failed: ' .. tostring(failure)) end
	end)
end

function Pad.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	local keys = {}
	for key in pairs(pads) do keys[#keys + 1] = key end
	for _, key in ipairs(keys) do Pad.Drop(key, 'the module stopped') end
end

function Pad.Reset()
	pads, said, job = {}, {}, nil
end
