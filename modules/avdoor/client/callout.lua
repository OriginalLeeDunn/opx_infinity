--- Client half of the landing call: the line, in this game's own language,
--- played from where this game draws the hull.
-- @author XEROX710
--
-- WHY THE GAME PLAYS IT. One network sound is one language for a whole bucket.
-- The bot lab, 2026-10-07: "give the voice locales with french german spanish
-- etc". So the server only says which hull is calling (`M.Event.CALL`,
-- `server/callout.lua`) and this file plays the kind's line in the language
-- this game's voice-over is set to (`Open77.session.locale`): `VOICES` in
-- config/avdoor.lua `CALLOUTS`, the English `ASSET` for a language with no line
-- -- and for a game set to English voices whatever its text language is.
--
-- FROM THE HULL. The sound is moved every FOLLOW_MS to where this game draws
-- the hull (`Open77.world.entityGeometry`), and to where the server last said
-- it was while the hull is not drawn here. A player who comes near mid-landing
-- is told by the server with the point the loop has reached, and starts there.
--
-- ENDED BY THE SERVER, FADED HERE. The server says when the AV is down: the
-- line fades out over the `fadeMs` it names and is released; `fadeMs = 0` cuts
-- it. A hull taken out of the world takes its line with it at once.

local M = OPX.Modules.Get('avdoor')

M.Call = {}
local Call = M.Call

-- How often a playing line is moved with its hull and faded.
local FOLLOW_MS = 100

-- Lines playing, by hull id as text: `{ id, kind, handle, asset, lang, at,
-- volume, fadeFrom, finishAt }`.
local calls = {}
local job = nil
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

local function pointFrom(value)
	if type(value) ~= 'table' then return nil end
	local x, y, z = finite(value.x or value[1]), finite(value.y or value[2]), finite(value.z or value[3])
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z }
end

local function block()
	local declared = type(M.Settings) == 'table' and M.Settings.CALLOUTS or nil
	return type(declared) == 'table' and declared or nil
end

--- The file a kind's line is played from on this game, its length and its
--- language (`OPX.Locale.ForVoice`): English voices are English whatever the
--- text language is.
-- @param kind string
-- @return string|nil asset
-- @return number seconds
-- @return string language
function Call.Line(kind)
	local cfg = block()
	local spec = cfg ~= nil and type(cfg.KINDS) == 'table' and cfg.KINDS[kind] or nil
	if type(spec) ~= 'table' or type(spec.ASSET) ~= 'string' then return nil, 0, 'en' end
	local voice, lang = OPX.Locale.ForVoice(spec.VOICES, nil)
	if type(voice) == 'table' and type(voice.ASSET) == 'string' and voice.ASSET ~= '' then
		return voice.ASSET, M.Number(voice.SECONDS, 0.1, 600.0, 4.0), lang
	end
	return spec.ASSET, M.Number(spec.SECONDS, 0.1, 600.0, 4.0), 'en'
end

--- Where this game draws a hull, or nil when it does not.
local function hullAt(id)
	local world = Open77.world
	if type(world) ~= 'table' or type(world.entityGeometry) ~= 'function' then return nil end
	local refs = { { kind = 'vehicle', id = id } }
	local number = tonumber(id)
	if number ~= nil and number ~= id then refs[#refs + 1] = { kind = 'vehicle', id = number } end
	for _, ref in ipairs(refs) do
		local read, answer = pcall(world.entityGeometry, ref)
		if read and type(answer) == 'table' and answer.attached ~= false then
			local at = pointFrom(answer.position)
			if at ~= nil then return at end
		end
	end
	return nil
end

local function release(call)
	local audio = Open77.audio
	if call.handle ~= nil and type(audio) == 'table' and type(audio.destroy) == 'function' then
		pcall(audio.destroy, call.handle)
	end
	call.handle = nil
end

--- Starts one call on this game.
local function start(key, payload)
	local audio = Open77.audio
	if type(audio) ~= 'table' or type(audio.play3D) ~= 'function' then
		sayOnce('noaudio', '[avdoor] no Open77.audio on this client: the landing call is not heard here')
		return
	end
	local cfg = block()
	if cfg == nil then return end
	local asset, seconds, lang = Call.Line(payload.kind)
	if asset == nil then
		sayOnce('kind:' .. tostring(payload.kind), ('[avdoor] no landing call of kind %s on this client')
			:format(tostring(payload.kind)))
		return
	end
	local at = hullAt(payload.id) or pointFrom(payload.at)
	if at == nil then return end
	local volume = M.Number(payload.volume, 0.0, 1.0, M.Number(cfg.VOLUME, 0.0, 1.0, 1.0))
	local near = M.Number(payload.near, 0.5, 900.0, 30.0)
	local far = M.Number(payload.far, 1.0, 1000.0, 300.0)
	local offset = ((finite(payload.elapsedMs) or 0) / 1000.0) % seconds
	local function play(file)
		return pcall(audio.play3D, file, at, { loop = true, volume = volume, minDistance = near,
			maxDistance = far, offset = offset })
	end
	local ran, handle, why = play(asset)
	if (not ran or handle == nil or handle == false) and lang ~= 'en' then
		-- A line this game could not play is heard in English rather than not at all.
		local english = cfg.KINDS[payload.kind].ASSET
		sayOnce('voice:' .. asset, ('[avdoor] the %s landing call in %s was refused (%s): English instead')
			:format(tostring(payload.kind), lang, tostring(ran and why or handle)))
		asset, lang = english, 'en'
		ran, handle, why = play(asset)
	end
	if not ran or handle == nil or handle == false then
		sayOnce('refused:' .. tostring(ran and why or handle), ('[avdoor] the landing call was refused here: %s')
			:format(tostring(ran and why or handle)))
		return
	end
	calls[key] = { id = payload.id, kind = payload.kind, handle = handle, asset = asset, lang = lang, at = at,
		volume = volume, fadeFrom = nil, finishAt = nil }
	sayOnce(('heard:%s:%s'):format(tostring(payload.kind), lang), ('[avdoor] the %s landing call plays here in %s (%s)')
		:format(tostring(payload.kind), lang, asset))
end

--- The server's word about one call (`M.Event.CALL`).
-- @param payload table `{ id, kind, on, at, elapsedMs, volume, near, far, fadeMs }`
function Call.Told(payload)
	if type(payload) ~= 'table' or payload.id == nil then return end
	local key = M.DecimalId(payload.id) or tostring(payload.id)
	local call = calls[key]
	if payload.on == true then
		if call == nil then return start(key, payload) end
		-- The same call again: where the server has it now, and a fade the
		-- server took back.
		call.at = pointFrom(payload.at) or call.at
		if call.finishAt ~= nil then
			call.fadeFrom, call.finishAt = nil, nil
			local audio = Open77.audio
			if type(audio) == 'table' and type(audio.setVolume) == 'function' then
				pcall(audio.setVolume, call.handle, call.volume)
			end
		end
		return
	end
	if call == nil then return end
	local fade = math.floor(M.Number(payload.fadeMs, 0, 5000, 0))
	if fade <= 0 then
		release(call)
		calls[key] = nil
		return
	end
	if call.finishAt == nil then
		local now = OPX.Now()
		call.fadeFrom, call.finishAt = now, now + fade
	end
end

--- One pass: every line follows its hull, fades and is released when done.
function Call.Step()
	if next(calls) == nil then return end
	local audio = Open77.audio
	if type(audio) ~= 'table' then return end
	local now = OPX.Now()
	local done = {}
	for key, call in pairs(calls) do
		if call.finishAt ~= nil and now >= call.finishAt then
			done[#done + 1] = key
		else
			if call.finishAt ~= nil and type(audio.setVolume) == 'function' then
				local span = math.max(1, call.finishAt - (call.fadeFrom or now))
				pcall(audio.setVolume, call.handle, call.volume * (call.finishAt - now) / span)
			end
			local at = hullAt(call.id) or call.at
			if call.placed == nil or math.abs(at.x - call.placed.x) + math.abs(at.y - call.placed.y)
				+ math.abs(at.z - call.placed.z) > 0.25 then
				if type(audio.setPosition) == 'function' then pcall(audio.setPosition, call.handle, at) end
				call.placed = at
			end
		end
	end
	for _, key in ipairs(done) do
		release(calls[key])
		calls[key] = nil
	end
end

--- What this client is playing, for the suite and the console.
function Call.Status()
	local out = {}
	for key, call in pairs(calls) do
		out[#out + 1] = { id = key, kind = call.kind, lang = call.lang, asset = call.asset,
			fading = call.finishAt ~= nil }
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

function Call.Start()
	RegisterNetEvent(M.Event.CALL, function(payload)
		local ran, failure = pcall(Call.Told, payload)
		if not ran then Open77.log.warn('[avdoor] a landing call could not be read: ' .. tostring(failure)) end
	end)
	AddEventHandler('open77:vehicleRemoved', function(id)
		if id == nil then return end
		local key = M.DecimalId(id) or tostring(id)
		local call = calls[key]
		if call ~= nil then
			release(call)
			calls[key] = nil
		end
	end)
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = OPX.Scheduler.Every('avdoor:call', FOLLOW_MS, function()
		local ran, failure = pcall(Call.Step)
		if not ran then Open77.log.warn('[avdoor] the landing call pass failed: ' .. tostring(failure)) end
	end)
end

function Call.Stop()
	if job ~= nil then OPX.Scheduler.Cancel(job) end
	job = nil
	for key, call in pairs(calls) do
		release(call)
		calls[key] = nil
	end
end
