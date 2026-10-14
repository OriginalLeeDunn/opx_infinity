--- The landing call: a voice on the aircraft's loudspeaker while it comes down.
-- @author XEROX710
--
-- "Warning. Clear the area. MaxTac landing." -- or "... Trauma Team landing."
-- -- said over and over from where the hull is, on top of the airframe's own
-- sounds, until it is down (`CALLOUTS` in config/avdoor.lua).
--
-- WHO STARTS AND ENDS A CALL. Two callers, one call per hull:
--   * a player-flown AV: the pilot's client reports the descent, the
--     touchdown, a take-off or a landing called off (`abort`), and
--     `M.Called` in server/main.lua checks the asker is seated in that hull
--     before it reaches `Start` or `Stop` here;
--   * the MaxTac insertion (`modules/ncpd`), through the avdoor contract
--     (`Callout` and `Hush`): from its approach until it is down at the drop.
--
-- WHAT A CALL IS. One server-owned network sound (`Open77.audio.play3D`,
-- permission `audio.network`), looped over the clip's exact length so a player
-- who streams in mid-landing hears it at the right point, heard by every player
-- in the hull's bucket within `MAX_METRES`. The platform has no vehicle
-- attachment for package audio, so `Tend` moves it with the hull every
-- `FOLLOW_MS` -- or, for a hull the caller flies itself (the insertion poses
-- its airframe every tick), the caller moves it (`Follow`) with the very pose
-- it just published. A call is ENDED with a short fade at the touchdown (`Stop`,
-- `FADE_MS`), and KILLED at once when there is nothing left to say it from: the
-- hull is gone, `MAX_SECONDS` passed, or the module stops.
--
-- THE VOICE STOPS WHEN THE AV IS DOWN. It used to finish the sentence it was
-- saying, which is up to a whole clip (4.5 s) after the touchdown. The bot lab,
-- 2026-10-07: "i heard the voice but ... it doesnt stop when av lands". So it
-- fades out over FADE_MS from the moment the hull is down, wherever the
-- sentence is.
--
-- IN EACH PLAYER'S OWN LANGUAGE (`TRANSPORT = 'local'`, the default). One
-- network sound is one language for the whole bucket. The bot lab, 2026-10-07:
-- "give the voice locales with french german spanish etc". So the server keeps
-- the call -- who is calling, from where, since when, ended or not -- and TELLS
-- every player in the hull's bucket within MAX_METRES (`M.Event.CALL`), and
-- anybody who comes near on a later pass with the point the loop has reached;
-- each game plays the line itself in its own voice-over language
-- (`client/callout.lua`) from where it draws the hull. Ending a call tells the
-- same games to fade it out, or to cut it. `TRANSPORT = 'network'` is the
-- server-owned network sound described above, unchanged.

local M = OPX.Modules.Get('avdoor')

M.Callout = {}
local Callout = M.Callout

-- How many hulls may call at once. A handle is one of the resource's sixteen,
-- shared with every other package sound it plays.
local MAX_LIVE = 6

-- Live calls, by hull id as text: `{ id, kind, handle, asset, seconds, volume,
-- startedAt, untilMs, fadeFrom, finishAt, bucket, at, why, owned }`. `owned` is a
-- call whose caller moves it (`Follow`) rather than `Tend`. `fadeFrom` and
-- `finishAt` are set while a call that has been ended fades out.
local live = {}

-- Reasons already said once, so a host with no audio is one line, not one per landing.
local told = {}

local function settings()
	local block = type(M.Settings) == 'table' and M.Settings.CALLOUTS or nil
	return type(block) == 'table' and block or nil
end

--- Whether calls are played by each game in its own language (`TRANSPORT`).
local function playedLocally(block)
	return type(block) == 'table' and block.TRANSPORT ~= 'network'
end

--- How often the games near a local call are looked at again, in ms.
local function tellMs(block)
	return math.floor(M.Number(block and block.TELL_MS, 250, 10000, 1000))
end

--- The package audio namespace, read per call: a host without it is a host
--- whose aircraft land in silence, and says so once.
local function audio()
	local api = type(Open77) == 'table' and Open77.audio or nil
	if type(api) ~= 'table' or type(api.play3D) ~= 'function' then return nil end
	return api
end

local function sayOnce(key, line)
	if told[key] then return end
	told[key] = true
	Open77.log.warn(line)
end

--- Where a hull is and its bucket, as the host reads it, or nil when it is gone.
-- @param id any the id as the host knows it
-- @return table|nil `{ x, y, z }`
-- @return number bucket
-- @return string|nil record
local function hullAt(id)
	local api = type(Open77) == 'table' and Open77.vehicles or nil
	if type(api) ~= 'table' or type(api.get) ~= 'function' or id == nil then return nil, 0 end
	local read, snapshot = pcall(api.get, id)
	if (not read or type(snapshot) ~= 'table') and tonumber(id) ~= nil then
		read, snapshot = pcall(api.get, tonumber(id))
	end
	if not read or type(snapshot) ~= 'table' then return nil, 0 end
	local at = type(snapshot.position) == 'table' and snapshot.position or snapshot
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil or x ~= x or y ~= y or z ~= z then return nil, 0 end
	return { x = x, y = y, z = z }, tonumber(snapshot.bucket) or 0, snapshot.record
end

--- How long an ended call fades out, in milliseconds: `FADE_MS`, 0 to 2000.
local function fadeMs(block)
	local fade = tonumber(block and block.FADE_MS)
	if fade == nil or fade ~= fade then return 400 end
	return math.floor(math.max(0, math.min(2000, fade)))
end

--- Sets a call's volume on the host. Answers whether the host took it.
local function setVolume(api, call, volume)
	if api == nil or type(api.setVolume) ~= 'function' then return false end
	local ran, ok = pcall(api.setVolume, call.handle, math.max(0.0, math.min(1.0, volume)))
	return ran and ok ~= nil and ok ~= false
end

--- The options every call is played with, from config with the platform's bounds.
local function options(block, kind, bucket)
	local near = M.Number(block.MIN_METRES, 0.5, 900.0, 30.0)
	local far = M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0)
	if far <= near then far = math.min(1000.0, near + 1.0) end
	return {
		network = true,
		bucket = bucket,
		loop = true,
		-- REQUIRED FOR A NETWORK LOOP, and it must be the clip's real length:
		-- the server keeps the timeline, and a late joiner is started at
		-- `elapsed % duration`.
		duration = M.Number(kind.SECONDS, 0.1, 600.0, 4.0),
		volume = M.Number(block.VOLUME, 0.0, 1.0, 1.0),
		minDistance = near,
		maxDistance = far,
	}
end

-- ── the local transport: the games are told, and play it themselves ──────────

--- What one game is sent to play a call, the loop's point included.
local function callPayload(call, block)
	local near = M.Number(block.MIN_METRES, 0.5, 900.0, 30.0)
	local far = M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0)
	if far <= near then far = math.min(1000.0, near + 1.0) end
	return {
		id = call.key, kind = call.kind, on = true,
		at = { x = call.at.x, y = call.at.y, z = call.at.z },
		elapsedMs = math.max(0, OPX.Now() - call.startedAt),
		volume = call.volume, near = near, far = far,
	}
end

local function sendCall(playerId, payload)
	return pcall(TriggerClientEvent, M.Event.CALL, playerId, payload)
end

--- Tells the games in a local call's bucket within MAX_METRES that have not
--- been told yet; with `refresh`, the ones already told hear where it is now.
-- @return integer how many were sent anything
local function tellCall(call, block, refresh)
	local players = type(Open77) == 'table' and Open77.players or nil
	if type(players) ~= 'table' or type(players.all) ~= 'function' or type(players.position) ~= 'function' then
		return 0
	end
	local far = M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0)
	local listed, list = pcall(players.all)
	local sent, payload = 0, nil
	for _, playerId in ipairs(listed and type(list) == 'table' and list or {}) do
		local id = tonumber(playerId)
		if id ~= nil and (refresh or not call.told[id]) then
			local read, where = pcall(players.position, id)
			local x = read and type(where) == 'table' and tonumber(where.x) or nil
			local y = read and type(where) == 'table' and tonumber(where.y) or nil
			if x ~= nil and y ~= nil and (tonumber(where.bucket) or 0) == call.bucket then
				local dx, dy = x - call.at.x, y - call.at.y
				-- A game already told is told again even out of range: it keeps a
				-- sound whose fading out with distance is the platform's.
				if call.told[id] or dx * dx + dy * dy <= far * far then
					payload = payload or callPayload(call, block)
					if sendCall(id, payload) then
						call.told[id] = true
						sent = sent + 1
					end
				end
			end
		end
	end
	return sent
end

--- Tells every game a local call was sent to that it is over.
local function endCall(call, fadeMs)
	if call.ended then return 0 end
	call.ended = true
	local count = 0
	for playerId in pairs(call.told) do
		if sendCall(playerId, { id = call.key, on = false, fadeMs = fadeMs }) then count = count + 1 end
	end
	return count
end

--- Releases a call's sound at once and forgets it.
-- @param key string
-- @param why string for the journal
function Callout.Kill(key, why)
	local call = live[tostring(key)]
	if call == nil then return false end
	live[tostring(key)] = nil
	if call.localCall then
		endCall(call, 0)
		Open77.log.info(('[avdoor] landing call of %s (%s) ended: %s, after %.1fs')
			:format(tostring(call.id), call.kind, tostring(why), (OPX.Now() - call.startedAt) / 1000.0))
		return true
	end
	local api = audio()
	if api ~= nil and type(api.destroy) == 'function' then
		local ran, ok, reason = pcall(api.destroy, call.handle)
		if not ran or ok == false or ok == nil then
			Open77.log.warn(('[avdoor] the landing call of %s could not be released: %s')
				:format(tostring(call.id), tostring(ran and reason or ok)))
		end
	end
	Open77.log.info(('[avdoor] landing call of %s (%s) ended: %s, after %.1fs')
		:format(tostring(call.id), call.kind, tostring(why), (OPX.Now() - call.startedAt) / 1000.0))
	return true
end

--- Starts the landing call on a hull, or keeps the one it already has going.
-- @param id any the hull, as the host knows it
-- @param kind string|nil a `CALLOUTS.KINDS` name; nil for the one its record makes
-- @param why string|nil for the journal
-- @param from table|nil `{ x, y, z, bucket }`: where a hull the CALLER flies is
--   right now. Given, the caller moves the call (`Follow`); absent, `Tend` does.
-- @return boolean|nil true when the hull is calling
-- @return string|nil why not, or 'already'
function Callout.Start(id, kind, why, from)
	local block = settings()
	if block == nil then return nil, 'callouts_off' end
	if id == nil then return nil, 'no_hull' end
	local key = tostring(id)
	local now = OPX.Now()
	local cap = math.floor(M.Number(block.MAX_SECONDS, 5, 3600, 90) * 1000)

	-- A DESCENT ON A HULL ALREADY CALLING is the same landing: the call goes on,
	-- a fade it had begun is taken back at full volume, and its clock is the new
	-- report's.
	local call = live[key]
	if call ~= nil then
		if call.localCall then
			-- A fade the games began is taken back by telling them again.
			if call.finishAt ~= nil then
				call.fadeFrom, call.finishAt, call.ended = nil, nil, false
				tellCall(call, block, true)
			end
		elseif call.fadeFrom ~= nil then
			setVolume(audio(), call, call.volume)
		end
		call.fadeFrom, call.finishAt = nil, nil
		call.untilMs = now + cap
		return true, 'already'
	end

	local at, bucket, record = hullAt(id)
	local owned = type(from) == 'table' and tonumber(from.x) ~= nil and tonumber(from.y) ~= nil
		and tonumber(from.z) ~= nil
	if owned then
		at = { x = tonumber(from.x), y = tonumber(from.y), z = tonumber(from.z) }
		bucket = tonumber(from.bucket) or bucket or 0
	end
	if at == nil then return nil, 'no_hull' end
	local kinds = type(block.KINDS) == 'table' and block.KINDS or {}
	local spec
	if kind ~= nil then
		spec = kinds[kind]
	else
		kind, spec = M.CalloutKind(record, block)
	end
	if type(spec) ~= 'table' or type(spec.ASSET) ~= 'string' or spec.ASSET == '' then
		return nil, 'no_call_for_this_hull'
	end

	local count = 0
	for _ in pairs(live) do count = count + 1 end
	if count >= MAX_LIVE then
		sayOnce('full', ('[avdoor] %d landing calls are already up: %s lands without one')
			:format(count, key))
		return nil, 'too_many_calls'
	end

	if playedLocally(block) then
		local call = {
			id = id, key = M.DecimalId(id) or key, kind = kind, localCall = true, told = {},
			seconds = M.Number(spec.SECONDS, 0.1, 600.0, 4.0),
			volume = M.Number(block.VOLUME, 0.0, 1.0, 1.0),
			startedAt = now, untilMs = now + cap, fadeFrom = nil, finishAt = nil,
			bucket = bucket, at = at, why = why, owned = owned, toldAt = now,
		}
		live[key] = call
		local told = tellCall(call, block, false)
		Open77.log.info(('[avdoor] landing call of %s (%s) on the loudspeaker%s: %d game(s) within %.0f m in bucket %d '
			.. 'play it in their own language'):format(key, kind, why and (' for ' .. tostring(why)) or '', told,
			M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0), bucket))
		return true
	end

	local api = audio()
	if api == nil then
		sayOnce('audio', '[avdoor] no Open77.audio on this host: aircraft land without their landing call')
		return nil, 'audio_unavailable'
	end
	local ran, handle, reason = pcall(api.play3D, spec.ASSET, at, options(block, spec, bucket))
	if not ran or handle == nil or handle == false then
		local said = tostring(ran and reason or handle)
		sayOnce('refused:' .. said, ('[avdoor] the landing call of %s was refused: %s'):format(key, said))
		return nil, said
	end

	live[key] = {
		id = id, kind = kind, handle = handle, asset = spec.ASSET,
		seconds = M.Number(spec.SECONDS, 0.1, 600.0, 4.0),
		volume = M.Number(block.VOLUME, 0.0, 1.0, 1.0),
		startedAt = now, untilMs = now + cap, fadeFrom = nil, finishAt = nil,
		bucket = bucket, at = at, why = why, owned = owned,
	}
	Open77.log.info(('[avdoor] landing call of %s (%s) on the loudspeaker%s: %s, heard to %.0f m in bucket %d')
		:format(key, kind, why and (' for ' .. tostring(why)) or '', spec.ASSET,
			M.Number(block.MAX_METRES, 1.0, 1000.0, 300.0), bucket))
	return true
end

--- Ends a hull's call now: it fades out over `FADE_MS` and is released.
-- @param id any
-- @param why string|nil for the journal
-- @return boolean whether a call was ending
function Callout.Stop(id, why)
	local key = id ~= nil and tostring(id) or nil
	local call = key ~= nil and live[key] or nil
	if call == nil then return false end
	if call.finishAt ~= nil then return true end
	local now = OPX.Now()
	local fade = fadeMs(settings())
	call.why = why or call.why
	Open77.log.info(('[avdoor] landing call of %s (%s): %s, fading out over %.1fs')
		:format(tostring(call.id), call.kind, tostring(why), fade / 1000.0))
	if fade <= 0 then
		Callout.Kill(key, call.why)
		return true
	end
	call.fadeFrom, call.finishAt = now, now + fade
	if call.localCall then endCall(call, fade) end
	return true
end

--- Moves a call to where its caller just put the hull (a call started with a
--- position, `Start`'s `from`). Nothing moves for under a quarter of a metre.
-- @param id any
-- @param at table `{ x, y, z }`
-- @return boolean whether the sound was moved
function Callout.Follow(id, at)
	local call = id ~= nil and live[tostring(id)] or nil
	if call == nil or type(at) ~= 'table' then return false end
	local x, y, z = tonumber(at.x), tonumber(at.y), tonumber(at.z)
	if x == nil or y == nil or z == nil then return false end
	local dx, dy, dz = x - call.at.x, y - call.at.y, z - call.at.z
	if dx * dx + dy * dy + dz * dz <= 0.0625 then return false end
	-- A local call is moved by each game, on the hull it draws; the server
	-- keeps the point for the games it tells next.
	if call.localCall then
		call.at = { x = x, y = y, z = z }
		return true
	end
	local api = audio()
	if api == nil or type(api.setPosition) ~= 'function' then return false end
	local point = { x = x, y = y, z = z }
	local ran, ok = pcall(api.setPosition, call.handle, point)
	if not ran or ok == nil or ok == false then return false end
	call.at = point
	return true
end

--- Whether a hull is calling now.
function Callout.IsLive(id)
	return id ~= nil and live[tostring(id)] ~= nil
end

--- One pass: every call follows its hull, and a call that finished, ran out or
--- lost its hull is released.
function Callout.Tend()
	local now = OPX.Now()
	local api = audio()
	for key, call in pairs(live) do
		if call.finishAt ~= nil and now >= call.finishAt then
			Callout.Kill(key, call.why or 'down')
		elseif call.finishAt ~= nil then
			-- The fade: the volume falls to nothing over what is left of FADE_MS.
			-- A local call's games fade it themselves.
			if not call.localCall then
				local span = math.max(1, call.finishAt - (call.fadeFrom or now))
				setVolume(api, call, call.volume * (call.finishAt - now) / span)
			end
		elseif now >= call.untilMs then
			Callout.Kill(key, 'no touchdown in MAX_SECONDS')
		elseif call.localCall then
			local block = settings()
			if not call.owned then
				local at = hullAt(call.id)
				if at == nil then
					Callout.Kill(key, 'the hull is gone')
				else
					call.at = at
				end
			end
			if live[key] ~= nil and block ~= nil and now - (call.toldAt or 0) >= tellMs(block) then
				-- Newcomers near the hull, and where it is now for the games
				-- that do not draw it.
				call.toldAt = now
				tellCall(call, block, true)
			end
		elseif not call.owned then
			local at = hullAt(call.id)
			if at == nil then
				Callout.Kill(key, 'the hull is gone')
			elseif api ~= nil and type(api.setPosition) == 'function' then
				local dx, dy, dz = at.x - call.at.x, at.y - call.at.y, at.z - call.at.z
				if dx * dx + dy * dy + dz * dz > 0.0625 then
					local ran, ok, reason = pcall(api.setPosition, call.handle, at)
					if ran and ok ~= nil and ok ~= false then
						call.at = at
					else
						sayOnce('move:' .. key, ('[avdoor] the landing call of %s could not follow its hull: %s')
							:format(key, tostring(ran and reason or ok)))
					end
				end
			end
		end
	end
end

--- A player who left is nobody to tell anything.
function Callout.Forget(playerId)
	for _, call in pairs(live) do
		if call.told ~= nil then call.told[playerId] = nil end
	end
end

--- Releases every call at once: the module is stopping.
function Callout.KillAll(why)
	local keys = {}
	for key in pairs(live) do keys[#keys + 1] = key end
	for _, key in ipairs(keys) do Callout.Kill(key, why) end
end

--- Forgets everything, without touching the host: a restart starts clean.
function Callout.Reset()
	live, told = {}, {}
end
