--- Server authority over being down, and its two ways out: give up and revive.
-- @author dop42

local M = OPX.Modules.Get('downed')

local Result = OPX.Result

-- Server to client: the screen state, and why a request was refused.
local EVENT_STATE = OPX.Event(OPX.Channel.NET, 'downed', 'state')
local EVENT_REFUSED = OPX.Event(OPX.Channel.NET, 'downed', 'refused')

-- Client to server: ask for the state again, the distress signal, the give up.
local EVENT_READY = OPX.Event(OPX.Channel.NET, 'downed', 'ready')
local EVENT_WAIT = OPX.Event(OPX.Channel.NET, 'downed', 'wait')
local EVENT_GIVE_UP = OPX.Event(OPX.Channel.NET, 'downed', 'giveup')

-- The public server bus: every other resource hears a player go down and get
-- up, `(playerId, { citizenId, down, waiting|reason })`. The client half raises
-- the same name on its own VM for its own listeners; the two never meet.
local EVENT_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Life state rescan period; catches deaths that happened while this module was
-- stopped, and revives done by anything at all.
local SCAN_MS = 1000

-- Floor between two requests of one kind from one player, in milliseconds.
local REQUEST_MS = 1000

-- Floor between two identity reads for one living player, in milliseconds.
local IDENTITY_MS = 3000

-- Milliseconds down before a give up is accepted, settled in `Init`.
local giveUpMs = 120000

-- How long a loaded character's body may stay unplaced before a death on it is
-- counted, and before a stored down row is put back on it anyway. See `placed`.
local DEATH_GRACE_MS = 30000
local RESTORE_GRACE_MS = 600000

-- Downed players by id: sinceMs, waiting, waitingSinceMs, position and citizenId.
local down = {}

-- Stored down rows waiting for the kill that restores them, by player id.
local restoring = {}

-- Per living player: the citizen whose stored row was checked, and when the
-- identity was last read.
local checked = {}

-- When each player last made each kind of request, by player:kind slot.
local lastRequest = {}

-- Per loaded player whose body the character module has not placed yet: the
-- citizen, and when this module first saw it unplaced.
local unplaced = {}

-- The character contract, looked up in `Start`.
local character

-- Answers a value as a finite number, or nil. Named for what it RETURNS: four
-- other files use a local called `finite` for the predicate, and one name for
-- both is an `if finite(x) then` that is true for nil.
local finiteNumber = OPX.Math.Finite

-- Bounds a value to low..high, using the fallback when it is not finite.
local function clamp(value, low, high, fallback)
	return OPX.Math.Clamp(finiteNumber(value) or fallback, low, high)
end

-- One audit line, info when the thing happened and warn when it did not.
-- `OPX.Audit` collapses identical entries for one player inside a ten second
-- window and reports the count on the next line; this module used to write every
-- one of them.
local function audit(event, playerId, ok, detail)
	OPX.Audit.Log({
		event = event,
		severity = ok and 'info' or 'warn',
		source = playerId,
		message = detail,
	})
end

-- The life phase without the underscore the client spells and the server does not.
local function phaseOf(life)
	return type(life) == 'table' and (tostring(life.phase or ''):gsub('_', '')) or ''
end

-- Reads one player's life state from the host, or nil.
local function lifeOf(playerId)
	local read, life = pcall(Open77.players.getLifeState, playerId)
	if not read or type(life) ~= 'table' then return nil end
	return life
end

-- Whether a player is dead, resolved from the host enum.
local function isDead(playerId)
	local read, dead = pcall(Open77.players.isDead, playerId)
	return read and dead == true
end

-- A player's name, stripped of control characters, mended and cut to 32 characters. Not
-- `OPX.Audit.Safe`: this name is also listed to a caller, and it is cut without
-- an ellipsis.
local function nameOf(playerId)
	local read, name = pcall(Open77.players.name, playerId)
	if not read or type(name) ~= 'string' then return nil end
	return OPX.Text.Clean(name, 32)
end

-- A player's finite position and bucket, or nil.
local function positionOf(playerId)
	local read, position = pcall(Open77.players.position, playerId)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = finiteNumber(position.x), finiteNumber(position.y), finiteNumber(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.floor(finiteNumber(position.bucket) or 0) }
end

-- The ids of every connected player.
local function playerIds()
	local read, players = pcall(Open77.players.all)
	local ids = {}
	for _, value in ipairs(read and type(players) == 'table' and players or {}) do
		local id = tonumber(value)
		if id and id > 0 then ids[#ids + 1] = id end
	end
	return ids
end

-- Requires a life state and an open readiness gate: touching a body that has
-- neither crashes it.
local function admit(playerId)
	if lifeOf(playerId) == nil then return false, 'not_incarnated' end
	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then
		return false, 'gate_unreadable'
	end
	local read, open = pcall(ready.isReady, playerId)
	if not read then return false, 'gate_unreadable' end
	if open ~= true then return false, 'gate_closed' end
	return true
end

-- Sends one player their screen state. Every field is relative, so the two
-- clocks never have to agree.
local function pushState(playerId)
	local record = down[playerId]
	if record == nil then
		TriggerClientEvent(EVENT_STATE, playerId, { down = false })
		return
	end
	local atMs = OPX.Now()
	TriggerClientEvent(EVENT_STATE, playerId, {
		down = true,
		waiting = record.waiting,
		downForMs = atMs - record.sinceMs,
		giveUpInMs = math.max(0, record.sinceMs + giveUpMs - atMs),
		waitingForMs = record.waitingSinceMs and (atMs - record.waitingSinceMs) or nil,
	})
end

-- Opens a record for a player who died, resuming a restored row, and stores it.
local function goDown(playerId, life, citizenId)
	if down[playerId] ~= nil then return end
	local position = type(life) == 'table' and type(life.position) == 'table' and life.position
		or positionOf(playerId)
	local resumed = restoring[playerId]
	restoring[playerId] = nil
	if resumed and resumed.citizenId ~= citizenId then resumed = nil end

	local record = {
		sinceMs = OPX.Now() - (resumed and resumed.downForMs or 0),
		waiting = resumed ~= nil and resumed.waiting == true,
		position = position,
		citizenId = citizenId,
	}
	if record.waiting then record.waitingSinceMs = record.sinceMs end
	down[playerId] = record

	audit('downed.down', playerId, true,
		(nameOf(playerId) or '?') .. (resumed and ' (restored)' or ''))
	pushState(playerId)
	OPX.Publish(EVENT_CHANGED, playerId, {
		citizenId = citizenId,
		down = true,
		waiting = record.waiting,
		restored = resumed ~= nil,
	})
	M.Storage.Write(citizenId, OPX.Now() - record.sinceMs, record.waiting)
end

-- Closes a player's record, audits why, pushes it, and clears the stored row
-- unless it is kept for a character leaving the world still down.
local function getUp(playerId, why, keep)
	local record = down[playerId]
	if record == nil then return end
	down[playerId] = nil
	audit('downed.up', playerId, true, why)
	pushState(playerId)
	OPX.Publish(EVENT_CHANGED, playerId, {
		citizenId = record.citizenId,
		down = false,
		reason = why ~= nil and OPX.Audit.Safe(why, 64) or nil,
		-- A character leaving the world still down is not a player getting up;
		-- `kept` says the row was kept and the state comes back with them.
		kept = keep == true,
	})
	if keep then
		M.Storage.Write(record.citizenId, OPX.Now() - record.sinceMs, record.waiting)
	else
		M.Storage.Clear(record.citizenId)
	end
end

-- True and the citizen id once a character is loaded, false before and after,
-- nil when it cannot be told. The join body and the roster body belong to
-- nobody, and a record opened on one would never close.
local function inWorld(playerId)
	local ready = Open77.ready
	if type(ready) ~= 'table' or type(ready.isReady) ~= 'function' then return nil end
	local read, open = pcall(ready.isReady, playerId)
	if not read then return nil end
	if open ~= true then return false end

	if character == nil or type(character.GetPlayer) ~= 'function' then return nil end
	-- Nil is a session without a character -- the selection screen, or one just
	-- put down -- and not a failure to read.
	local loaded = character.GetPlayer(playerId)
	local data = loaded and loaded.PlayerData
	if type(data) ~= 'table' then return false end
	return true, type(data.citizenId) == 'string' and data.citizenId or nil
end

-- Whether the character module has put this character's body where its row says.
--
-- A JOIN IS A KILL AND A RESPAWN, and neither is a death or a revive. The
-- character module places a joining body once the gate opens (`PlaceCharacter`,
-- and later still when the spawn menu is up), and until then the body is the
-- platform's join body. A stored down row put back on it was a kill the
-- placement then respawned: the scan read the body alive again, closed the
-- record as `alive` and CLEARED THE ROW -- a character that disconnected down
-- came back standing, which is a free revive for anybody who quits while
-- bleeding out. A death read on the unplaced body opened a fresh record over the
-- stored one, writing it back as zero seconds down and not waiting.
--
-- `MaySample` is the character module's own word for "placed": false from the
-- load, true once `PlaceCharacter` has put the body down. A contract that does
-- not carry it is taken as placed, which is the behaviour before this existed.
-- BOUNDED, because a placement that failed leaves it false for the session, and
-- a player whose deaths nobody counts is a player nothing ever revives.
local function placed(playerId, citizenId, graceMs)
	if character == nil or type(character.GetPlayer) ~= 'function' then return true end
	local loaded = character.GetPlayer(playerId)
	if type(loaded) ~= 'table' or loaded.MaySample ~= false then
		unplaced[playerId] = nil
		return true
	end
	local atMs = OPX.Now()
	local seen = unplaced[playerId]
	if seen == nil or seen.citizenId ~= citizenId then
		seen = { citizenId = citizenId, sinceMs = atMs }
		unplaced[playerId] = seen
	end
	return atMs - seen.sinceMs >= graceMs
end

-- Puts a character stored down back down once, by a kill `goDown` then resumes.
local function restore(playerId, citizenId)
	local row = M.Storage.Read(citizenId)
	if row == nil then return end
	-- ASKED AGAIN AFTER THE READ, WHICH YIELDS. The character that owned this
	-- slot may have logged out, or the player left and the id went to somebody
	-- else, while the row was on its way: killing the slot then put one
	-- character's stored death on another's body, and the `restoring` mark left
	-- behind silenced the down-row check for whoever held the slot next.
	local still, current = inWorld(playerId)
	if still ~= true or current ~= citizenId then return end
	restoring[playerId] = { citizenId = citizenId, downForMs = row.downForMs, waiting = row.waiting }

	local ok, reason = Open77.players.kill(playerId, { cause = 'script', weapon = 'opx:downed:restore' })
	if not ok then
		restoring[playerId] = nil
		audit('downed.restore', playerId, false, citizenId .. ': ' .. tostring(reason))
		return
	end
	audit('downed.restore', playerId, true, citizenId)
end

-- Opens a record only for a dead player with a character loaded, and closes one
-- as soon as the body is alive again or the character has left.
local function observe(playerId)
	if down[playerId] ~= nil then
		if not isDead(playerId) then return getUp(playerId, 'alive') end
		if inWorld(playerId) == false then getUp(playerId, 'no character loaded', true) end
		return
	end

	local life = lifeOf(playerId)
	if phaseOf(life) == 'dead' then
		local loaded, citizenId = inWorld(playerId)
		if loaded == true and placed(playerId, citizenId, DEATH_GRACE_MS) then
			goDown(playerId, life, citizenId)
		end
		return
	end

	if life == nil or restoring[playerId] ~= nil or not M.Storage.Ready() then return end
	local seen = checked[playerId]
	local atMs = OPX.Now()
	if seen and atMs - seen.atMs < IDENTITY_MS then return end
	local loaded, citizenId = inWorld(playerId)
	if loaded == nil then return end
	if loaded == false or citizenId == nil then
		checked[playerId] = { atMs = atMs }
		return
	end
	-- Not before the body is placed, and not ticked off either: the restore is
	-- still owed to this character, so it is asked again on a later pass.
	if not placed(playerId, citizenId, RESTORE_GRACE_MS) then
		checked[playerId] = { atMs = atMs, citizenId = seen and seen.citizenId or nil }
		return
	end
	local already = seen and seen.citizenId == citizenId
	checked[playerId] = { atMs = atMs, citizenId = citizenId }
	if not already then restore(playerId, citizenId) end
end

-- The usable HOSPITALS row nearest an origin, or the first one when there is no
-- origin to measure from.
local function nearestHospital(origin)
	local rows = M.Settings.HOSPITALS
	local best, bestDistance
	for _, row in ipairs(type(rows) == 'table' and rows or {}) do
		local x, y, z = finiteNumber(row.X), finiteNumber(row.Y), finiteNumber(row.Z)
		if x and y and z then
			local distance = 0
			if origin and finiteNumber(origin.x) and finiteNumber(origin.y) then
				local dx, dy = x - origin.x, y - origin.y
				distance = dx * dx + dy * dy
			end
			if best == nil or distance < bestDistance then
				best = { x = x, y = y, z = z, heading = finiteNumber(row.HEADING) or 0.0, label = row.LABEL }
				bestDistance = distance
			end
		end
	end
	return best
end

-- Revives a downed player where the body lies: the one path every revive takes.
-- `options` may carry the caller's own `health` share and `graceMs`, bounded the
-- same way as REVIVE; what it leaves out comes from REVIVE.
local function reviveNow(playerId, why, options)
	if not isDead(playerId) then return false, 'not_down' end
	local admitted, code = admit(playerId)
	if not admitted then return false, code end

	local revive = type(M.Settings.REVIVE) == 'table' and M.Settings.REVIVE or {}
	options = type(options) == 'table' and options or {}
	local ok, reason = Open77.players.revive(playerId, {
		health = clamp(options.health or revive.HEALTH, 0.01, 1.0, 0.35),
		graceMs = math.floor(clamp(options.graceMs or revive.GRACE_MS, 0, 60000, 3000)),
	})
	if not ok then
		audit('downed.revive', playerId, false, why .. ': ' .. tostring(reason))
		return false, tostring(reason or 'refused')
	end
	audit('downed.revive', playerId, true, why)
	getUp(playerId, 'revived by ' .. why)
	return true
end

-- Tells one player why their request was refused.
local function refuse(playerId, code)
	TriggerClientEvent(EVENT_REFUSED, playerId, code)
end

-- True when a request comes within REQUEST_MS of the last of its kind.
local function cooled(playerId, kind)
	local slot = playerId .. ':' .. kind
	local atMs = OPX.Now()
	if lastRequest[slot] ~= nil and atMs - lastRequest[slot] < REQUEST_MS then return true end
	lastRequest[slot] = atMs
	return false
end

-- Observes and pushes the caller's state, on its start or a world entry.
local function onReady()
	local playerId = tonumber(source) or 0
	if playerId <= 0 or cooled(playerId, 'ready') then return end
	CreateThread(function()
		observe(playerId)
		pushState(playerId)
	end)
end

-- Marks a downed caller as waiting for help and pushes it.
local function onWait()
	local playerId = tonumber(source) or 0
	if playerId <= 0 or cooled(playerId, 'wait') then return end
	local record = down[playerId]
	if record == nil then return pushState(playerId) end
	if not record.waiting then
		record.waiting = true
		record.waitingSinceMs = OPX.Now()
		audit('downed.wait', playerId, true, nameOf(playerId))
		-- THE DISTRESS SIGNAL IS PUBLIC. It used to stop at this record, so a
		-- player asking for help reached nobody: `medical` hears it here and turns
		-- it into a call on the board of every service that answers them.
		OPX.Publish(EVENT_CHANGED, playerId, {
			citizenId = record.citizenId,
			down = true,
			waiting = true,
		})
	end
	pushState(playerId)
end

-- Respawns the caller at the nearest hospital. Every rule is checked here and
-- never on the view: the delay, that the player is still down, and the gate.
local function onGiveUp()
	local playerId = tonumber(source) or 0
	if playerId <= 0 or cooled(playerId, 'giveUp') then return end
	local record = down[playerId]
	if record == nil or not isDead(playerId) then return pushState(playerId) end
	if OPX.Now() - record.sinceMs < giveUpMs then
		refuse(playerId, 'too_soon')
		return pushState(playerId)
	end
	local admitted, code = admit(playerId)
	if not admitted then return refuse(playerId, code) end

	local here = positionOf(playerId) or record.position
	local point = nearestHospital(here or record.position)
	if point == nil then
		Open77.log.error('give up refused: HOSPITALS has no usable row')
		return refuse(playerId, 'no_hospital')
	end

	local respawn = type(M.Settings.RESPAWN) == 'table' and M.Settings.RESPAWN or {}
	local ok, reason = Open77.players.respawn(playerId, {
		position = { x = point.x, y = point.y, z = point.z },
		heading = point.heading,
		-- In the bucket they fell in: waking somebody into the shared world out
		-- of an instance puts a body where nobody expects one.
		bucket = here and here.bucket or 0,
		health = clamp(respawn.HEALTH, 0.01, 1.0, 0.5),
		graceMs = math.floor(clamp(respawn.GRACE_MS, 0, 60000, 5000)),
	})
	if not ok then
		audit('downed.giveUp', playerId, false, tostring(reason))
		return refuse(playerId, 'respawn_refused')
	end
	audit('downed.giveUp', playerId, true, tostring(point.label or ''))
	getUp(playerId, 'gave up')
end

-- Stores a departing player's down record for their character, then forgets
-- everything held for that player.
local function departed(rawPlayerId)
	local playerId = tonumber(rawPlayerId) or 0
	local record = down[playerId]
	down[playerId], checked[playerId], restoring[playerId] = nil, nil, nil
	unplaced[playerId] = nil

	local prefix = tostring(playerId) .. ':'
	for slot in pairs(lastRequest) do
		if slot:sub(1, #prefix) == prefix then lastRequest[slot] = nil end
	end

	if record == nil then return end
	local downForMs = OPX.Now() - record.sinceMs
	audit('downed.up', playerId, true, 'disconnected down, kept for ' .. tostring(record.citizenId))
	M.Storage.Write(record.citizenId, downForMs, record.waiting)
	OPX.Audit.Forget(playerId, record.citizenId)
end

-- Answers a value as a whole positive player id, or nil.
local function playerOf(value)
	local id = tonumber(value)
	if id == nil or id < 1 or id > 2147483647 or id % 1 ~= 0 then return nil end
	return math.floor(id)
end

-- Answers a caller's own name, which it gives: one runtime has no invoking
-- resource to read it from.
local function callerOf(value)
	if type(value) ~= 'string' or value == '' or #value > 64 or not value:match('^[%w_%-%.]+$') then
		return nil
	end
	return value
end

-- Whether REVIVERS lets a caller revive. The name is the caller's own, so this
-- is a configuration switch and no longer a boundary.
local function mayRevive(name)
	local revivers = M.Settings.REVIVERS
	if revivers == '*' then return true end
	return type(revivers) == 'table' and revivers[name] == true
end

--- Stands a downed player back up where they lie, at REVIVE.HEALTH.
-- @author dop42
-- @param playerId integer
-- @param caller string the name the caller is audited under
-- @param why string|nil a short reason, audited after the caller's name
-- @param options table|nil { health = 0.01..1, graceMs = 0..60000 }, a medical
--   service's own share; REVIVE fills what it leaves out
-- @return Result
local function revive(playerId, caller, why, options)
	local by = callerOf(caller)
	if by == nil then return Result.Err('invalid_caller') end
	if not mayRevive(by) then
		OPX.Audit.Security('downed.revive.denied', by .. ' called Revive')
		return Result.Err('caller_denied')
	end
	local target = playerOf(playerId)
	if target == nil then return Result.Err('bad_player') end
	local said = by
	if type(why) == 'string' and why ~= '' then
		said = by .. ': ' .. (OPX.Text.Clean(why, 64, '...') or '-')
	end
	local ok, reason = reviveNow(target, said, options)
	if not ok then return Result.Err(reason) end
	return Result.Ok(true)
end

--- Whether one player is down, and whether they asked for help.
-- @author dop42
-- @param playerId integer
-- @return Result
local function isDown(playerId)
	local target = playerOf(playerId)
	if target == nil then return Result.Err('bad_player') end
	local record = down[target]
	if record == nil then return Result.Ok({ down = false, waiting = false }) end
	return Result.Ok({
		down = true,
		waiting = record.waiting,
		downForMs = OPX.Now() - record.sinceMs,
	})
end

--- Every downed player, those waiting for help first, then the longest down.
-- @author dop42
--
-- What a dispatch screen lists.
-- @return Result
local function list()
	local atMs = OPX.Now()
	local rows = {}
	for playerId, record in pairs(down) do
		local position = positionOf(playerId) or record.position
		rows[#rows + 1] = {
			id = playerId,
			name = nameOf(playerId),
			waiting = record.waiting,
			downForMs = atMs - record.sinceMs,
			position = position and { x = position.x, y = position.y, z = position.z,
				bucket = position.bucket } or nil,
		}
	end
	table.sort(rows, function(a, b)
		if a.waiting ~= b.waiting then return a.waiting end
		return a.downForMs > b.downForMs
	end)
	return Result.Ok({ players = rows })
end

-- Names every key present in one catalogue and missing from the other.
local function checkLocales()
	local catalogs = M.Catalogs or {}
	local english, french = catalogs.en or {}, catalogs.fr or {}
	for key in pairs(english) do
		if french[key] == nil then Open77.log.warn('the fr catalogue is missing ' .. key) end
	end
	for key in pairs(french) do
		if english[key] == nil then Open77.log.warn('the en catalogue is missing ' .. key) end
	end
end

--- Builds the state and contributes the table.
-- @author dop42
function M.Init()
	down, restoring, checked, lastRequest, unplaced = {}, {}, {}, {}, {}
	giveUpMs = math.floor(clamp(M.Settings.GIVE_UP_AFTER_S, 0, 3600, 120) * 1000)
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes who is down and the one way to stand them up.
-- @author dop42
function M.Api()
	OPX.Api.Provide('downed', 1, {
		IsDown = isDown,
		Revive = revive,
		List = list,
	})
end

--- Wires the events and starts the life scan.
-- @author dop42
function M.Start()
	character = OPX.Api.Get('character')
	if character == nil then
		Open77.log.warn('no character contract: nobody will be seen going down')
	end

	-- A DELETED CHARACTER TAKES ITS DOWN ROW WITH IT. This table carries no
	-- foreign key -- the header in `storage.lua` says why -- and one would not
	-- have helped anyway, because a character delete is a soft one and no cascade
	-- fires for an UPDATE. `Clear` is the write this module already had; it queues
	-- behind whatever else is in flight, which is right: nothing is waiting on it.
	AddEventHandler(OPX.Event(OPX.Channel.INTERNAL, 'character', 'deleted'),
		function(_, citizenId)
			if type(citizenId) ~= 'string' or citizenId == '' then return end
			M.Storage.Clear(citizenId)
		end)

	RegisterNetEvent(EVENT_READY, onReady)
	RegisterNetEvent(EVENT_WAIT, onWait)
	RegisterNetEvent(EVENT_GIVE_UP, onGiveUp)
	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, departed)

	-- The fast path. On a thread, because reading the identity may yield.
	AddEventHandler('onPlayerLifeStateChanged', function(playerId)
		local id = tonumber(playerId)
		if id == nil or id <= 0 then return end
		CreateThread(function() observe(id) end)
	end)

	local function scan()
		for _, playerId in ipairs(playerIds()) do observe(playerId) end
		for playerId in pairs(down) do
			if nameOf(playerId) == nil then getUp(playerId, 'gone', true) end
		end
	end

	-- The first scan runs here rather than a second from now: a reload with
	-- players already dead has to see them, and the scheduler's first pass is
	-- always one interval away.
	local seen, failure = pcall(scan)
	if not seen then Open77.log.error('life scan failed: ' .. tostring(failure)) end

	OPX.Scheduler.Every('downed:scan', SCAN_MS, scan)

	checkLocales()

	if nearestHospital(nil) == nil then
		Open77.log.warn('HOSPITALS has no usable row: nobody will be able to give up')
	end
	Open77.log.info(('downed: give up unlocks after %ds'):format(math.floor(giveUpMs / 1000)))
end
