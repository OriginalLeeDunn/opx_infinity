--- Server half: the doors, who may turn them, and the staff writes.
-- @author dop42
--
-- OX'S `server/main.lua`, ON THIS SERVER. ox keeps `doors` by integer id, turns
-- one with `setDoorState(id, state, lockpick)` after `isAuthorised`, arms the
-- autolock with a timeout, edits through `editDoorlock` and answers `getDoor`,
-- `getDoorFromName`, `editDoor`, `createDoor` and `removeDoor` to other
-- resources. Every one of those is here under the same meaning; what changed is
-- what this platform asks of a server:
--
-- THIS FILE IS THE GATE. A client names a door id and the state it wants --
-- and, for a coded door, the code it was given -- and every other fact is read
-- here: the door out of this VM's own list, the position and bucket from the
-- host, the job, gang and grade from the character contract, the bag from the
-- inventory contract. In this order, cheapest first, so a client hammering the
-- event pays nothing:
--
--   1. the per-player request floor        (a clock)
--   2. the door exists                     (a lookup)
--   3. same bucket, within reach           (the host's position; ox trusts the client)
--   4. not downed                          (the downed contract, when present)
--   5. may turn it                         (`Access.Evaluate`, ox's isAuthorised)
--   6. the veto hook                       (ox's doorAuthorization hook)
--   7. the code, for a coded door          (compared here, never sent out)
--
-- Then the lock moves through the backend, the bucket is told, the autolock is
-- armed, and the change is audited and published on `opx:on:doorlock:changed`.
--
-- A LOCKPICK IS TIMED HERE. ox's skill check is a client minigame whose result
-- the server believes; here the client draws one `progress` bar per step of the
-- door's `lockpickDifficulty`, the server starts the clock when it says go, a
-- "done" that arrives before the steps could have run is refused and audited,
-- and every step's roll is the server's.
--
-- STAFF WRITES are the panel's net events, each gated on its own
-- `command.opx.doorlock.*` entry and floored per player, and four restricted
-- commands. Every one is audited with who did it.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access
local Store = M.Storage
local Backend = M.Backend
local Command = M.Command
local Result = OPX.Result

-- Door id to door, and the live state of each: { state, relockAt, by }.
local doors, states = {}, {}

-- `bucket|0xID` to the id of the door it belongs to, and an origin
-- ('config:<key>', 'legacy:<key>') to its id, so a caller still naming a door by
-- the key the first version gave it finds the same door.
local byNative, byOrigin = {}, {}

-- The bucket each player was last sent, and their lockpick in progress.
local sentBucket, picking = {}, {}

-- Rows the database answered that were refused, for the list command.
local refusedRows = {}

-- Whether the module is running, and whether the saved doors have been read.
local running, loaded = false, false

-- Doors per sync event. A door is about twenty value nodes on the wire and the
-- host drops an event past 1024 of them without a word; and the client files
-- each door of a chunk inside that one event's instruction budget, so a chunk
-- is kept well short of both.
local CHUNK = 12

-- Summary rows per staff list event: ten value nodes each, and few enough that
-- the client handler reading them stays far inside its per-resume budget.
local STAFF_CHUNK = 20

-- Metres a staff member may be from a door they capture or re-pick.
local STAFF_REACH = 60.0

-- Milliseconds a pick's "done" may arrive early, for the wire.
local PICK_EARLY_MS = 400
-- And how long after the steps should have ended it is still believed.
local PICK_LATE_MS = 20000

-- Metres around a door ox plays its sound for (ox: `door.distance < 20`).
M.SOUND_RANGE = 20.0

-- The roll, a field so a test can load the dice. Answers 0..1.
M.Roll = math.random

local function settings() return M.Settings end

-- ── reading the world ───────────────────────────────────────────────────────

--- Whether the ACL grants this player an entry. False when unreadable.
local function allowed(player, entry)
	local read, granted = pcall(function() return Open77.acl.isAllowed(player, entry) end)
	return read and granted == true
end

--- Whether the ACL grants this player a command's entry.
local function permitted(player, name)
	return allowed(player, 'command.' .. name)
end

--- A connection's position and bucket, or nil.
local function pointOf(player)
	local read, position = pcall(Open77.players.position, player)
	if not read or type(position) ~= 'table' then return nil end
	local x, y, z = OPX.Math.Finite(position.x), OPX.Math.Finite(position.y),
		OPX.Math.Finite(position.z)
	if x == nil or y == nil or z == nil then return nil end
	return { x = x, y = y, z = z, bucket = math.tointeger(position.bucket) or 0 }
end

--- Every connected player id.
local function players()
	local read, ids = pcall(Open77.players.all)
	if not read or type(ids) ~= 'table' then return {} end
	local out = {}
	for index = 1, #ids do
		local id = tonumber(ids[index])
		if id ~= nil then out[#out + 1] = id end
	end
	return out
end

--- The job fields of a loaded character, stamped now, or nil.
local function snapshotOf(player)
	local api = OPX.Api.Get('character')
	if api == nil or type(api.GetPlayer) ~= 'function' then return nil end
	local read, loadedPlayer = pcall(api.GetPlayer, player)
	if not read or type(loadedPlayer) ~= 'table' or type(loadedPlayer.PlayerData) ~= 'table' then
		return nil
	end
	local data = loadedPlayer.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		citizenId = data.citizenId,
		atMs = OPX.Now(),
	}
end

-- One inventory call answering a count, or 0 on anything but a clean answer.
local function counted(fn, ...)
	if type(fn) ~= 'function' then return 0 end
	local read, answer = pcall(fn, ...)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return 0 end
	return tonumber(answer.value) or 0
end

--- How many of one item row a bag holds: ox_inventory's `Search(..., name,
--- metadata)`, where a metadata string matches the item's metadata TYPE. Yields
--- on an offline bag.
-- A key the first version cut carries `door = <old key>` instead, and a door
-- carried over from it names that key as its metadata, so the second question
-- is what keeps every key already in a bag opening its door.
local function countItem(player, item)
	local api = OPX.Api.Get('inventory')
	if api == nil then return 0 end
	if item.metadata == nil then return counted(api.GetItemCount, player, item.name) end
	local held = counted(api.CountWhere, player, item.name, { type = item.metadata })
	if held > 0 then return held end
	return counted(api.CountWhere, player, item.name, { door = item.metadata })
end

--- Spends one of an item row, the matching one for a metadata row. Yields.
local function spendItem(player, item)
	local api = OPX.Api.Get('inventory')
	if api == nil then return false end
	local function spent(fn, ...)
		if type(fn) ~= 'function' then return false end
		local read, answer = pcall(fn, ...)
		return read and type(answer) == 'table' and answer.ok == true
	end
	if item.metadata == nil then return spent(api.RemoveItem, player, item.name, 1) end
	return spent(api.RemoveWhere, player, item.name, { type = item.metadata })
		or spent(api.RemoveWhere, player, item.name, { door = item.metadata })
end

--- The first lockpick item this bag holds, or nil (ox's `DoesPlayerHaveItem(
--- player, Config.LockpickItems)`). Yields on a load.
local function lockpickHeld(player)
	local api = OPX.Api.Get('inventory')
	if api == nil then return nil end
	for _, name in ipairs(Access.Lockpick().items) do
		if counted(api.GetItemCount, player, name) > 0 then return name end
	end
	return nil
end

--- Everything `Access.Evaluate` needs about one player.
local function subjectOf(player, door)
	return {
		-- A PLAIN RIGHT, NOT A `command.` GRANT, and off unless the config turns it
		-- on. Under `command.` the admin role's `command.*` carried it, so every
		-- admin walked through every door without being asked for its code, which
		-- is the owner's report: an admin is asked like anybody else.
		staff = settings().STAFF_BYPASS == true and allowed(player, Command.BYPASS),
		acl = door.id ~= nil and allowed(player, 'doorlock.' .. tostring(door.id)),
		snapshot = snapshotOf(player),
		items = function(item) return countItem(player, item) end,
	}
end

--- Whether this player is bleeding out. An absent contract is not down.
local function isDown(player)
	local api = OPX.Api.Get('downed')
	if api == nil or type(api.IsDown) ~= 'function' then return false end
	local read, answer = pcall(api.IsDown, player)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

--- Why a player cannot reach a door from where the host says they stand, or nil.
local function outOfReach(player, door)
	local at = pointOf(player)
	if at == nil then return 'no_position' end
	if at.bucket ~= door.bucket then return 'wrong_bucket' end
	local reach = door.maxDistance + Access.Slack()
	if Access.DistanceSquared(door, at.x, at.y, at.z) > reach * reach then return 'too_far' end
	return nil
end

--- Who a staff member or a caller is, for the row and the audit line.
local function whoIs(player)
	if type(player) == 'string' then return player end
	local name = type(GetPlayerName) == 'function' and GetPlayerName(player) or nil
	return ('%d:%s'):format(player, OPX.Text.Clean(name, 40) or '?')
end

-- ── the list ────────────────────────────────────────────────────────────────

--- The id of the door already holding one of these leaves, or nil.
local function holderOf(door, except)
	for _, id in ipairs(door.ids) do
		local holder = byNative[door.bucket .. '|' .. id]
		if holder ~= nil and holder ~= except then return holder end
	end
	return nil
end

--- Files a door in the list and the indexes. A new door starts in its own state.
local function install(door)
	local previous = doors[door.id]
	if previous ~= nil then
		for _, id in ipairs(previous.ids) do byNative[previous.bucket .. '|' .. id] = nil end
	end
	doors[door.id] = door
	for _, id in ipairs(door.ids) do byNative[door.bucket .. '|' .. id] = door.id end
	if door.origin ~= nil then byOrigin[door.origin] = door.id end
	if states[door.id] == nil then states[door.id] = { state = door.state } end
end

--- Takes a door out of the list and the indexes.
local function uninstall(door)
	for _, id in ipairs(door.ids) do byNative[door.bucket .. '|' .. id] = nil end
	if door.origin ~= nil then byOrigin[door.origin] = nil end
	doors[door.id], states[door.id] = nil, nil
end

--- A door by ox's id, or by the key a seeded or migrated door was filed under.
local function find(ref)
	local id = Access.Id(ref)
	if id ~= nil then return doors[id] end
	if type(ref) == 'string' and #ref <= 48 then
		local seeded = byOrigin['config:' .. ref] or byOrigin['legacy:' .. ref]
		return seeded and doors[seeded] or nil
	end
	return nil
end

--- The doors of one bucket, ready for the wire, sorted by id.
local function wireFor(bucket)
	local list = {}
	for id, door in pairs(doors) do
		if door.bucket == bucket then list[#list + 1] = Access.Wire(door, states[id].state) end
	end
	table.sort(list, function(left, right) return left.id < right.id end)
	return list
end

--- What this player may do as staff, for the eye and the panel.
local function staffFlags(player)
	if not permitted(player, Command.OPEN) then return nil end
	return {
		save = permitted(player, Command.SAVE),
		remove = permitted(player, Command.REMOVE),
		lock = permitted(player, Command.LOCK),
		key = permitted(player, Command.KEY),
		bypass = settings().STAFF_BYPASS == true and allowed(player, Command.BYPASS),
		teleport = permitted(player, M.TELEPORT),
	}
end

--- Sends one player every door of their bucket, in chunks.
local function sync(player)
	local at = pointOf(player)
	if at == nil then return end
	local list = wireFor(at.bucket)
	local staff = staffFlags(player)
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + CHUNK, #list) do chunk[#chunk + 1] = list[index] end
		TriggerClientEvent(M.Event.SYNC, player, {
			bucket = at.bucket, mode = Backend.Mode(), offset = offset,
			done = offset + #chunk >= #list, doors = chunk, staff = staff,
		})
		offset = offset + #chunk
	until offset >= #list
	sentBucket[player] = at.bucket
end

--- Re-sends the list to everyone standing in one of these buckets.
local function syncBuckets(buckets)
	for _, player in ipairs(players()) do
		local at = pointOf(player)
		if at ~= nil and buckets[at.bucket] then
			local sent, failure = pcall(sync, player)
			if not sent then Open77.log.warn('[doorlock] sync failed: ' .. tostring(failure)) end
		end
	end
end

--- Tells everyone in a door's bucket its new state (ox's `setState` to -1).
--
-- THE DOOR'S STATE AND NOTHING ABOUT WHO MOVED IT. This carried `by`, the server
-- id of the player who locked or unlocked it, to every client in the bucket --
-- the whole city -- and no client read it. Who opened a door is something you
-- learn by watching the door; the journal keeps it for staff.
local function pushState(door)
	local state = states[door.id]
	for _, player in ipairs(players()) do
		local at = pointOf(player)
		if at ~= nil and at.bucket == door.bucket then
			TriggerClientEvent(M.Event.STATE, player, { id = door.id, state = state.state })
		end
	end
end

--- Answers one player about one request.
local function answer(player, ok, code, door, extra)
	local payload = { ok = ok == true, code = code, id = door and door.id or nil,
		name = door and door.name or nil }
	for field, value in pairs(extra or {}) do payload[field] = value end
	TriggerClientEvent(M.Event.ANSWER, player, payload)
end

--- Moves a door's state: ox's `setDoorState` once it has decided. The backend,
--- the bucket, the autolock and the record of it. Yields on the networked backend.
-- @param door table
-- @param state integer 1 locked, 0 unlocked
-- @param by string|integer what turned it: a player id, 'autolock', 'staff:<id>', 'ext:<resource>'
-- @param player integer|nil the player it was, for the bus and the audit line
-- @param item table|nil the item that opened it, for the bus (ox's `usedItem`)
local function setState(door, state, by, player, item)
	local live = states[door.id]
	live.state = state == 1 and 1 or 0
	live.by = by
	live.relockAt = nil
	-- ox: `if door.autolock and state == 0 then SetTimeout(autolock * 1000, ...)`.
	-- On the scheduler's clock rather than a timer per unlock: a door turned
	-- five times in its autolock window must lock once, at the last window's end.
	if live.state == 0 and door.autolock > 0 then
		live.relockAt = OPX.Now() + door.autolock * 1000
	end
	pushState(door)
	Backend.Apply(door, live.state == 1)
	OPX.Publish(M.Event.ON_CHANGED, player, { id = door.id, door = door.id, name = door.name,
		state = live.state, locked = live.state == 1, by = tostring(by), item = item and item.name or nil })
	OPX.Audit.Log({
		event = 'doorlock.' .. (live.state == 1 and 'lock' or 'unlock'),
		message = ('%d %s by %s'):format(door.id, door.name, tostring(by)),
		source = player,
		data = { door = door.id, by = tostring(by) },
	})
end

-- ── a player at a door ──────────────────────────────────────────────────────

--- Whether a module of this resource vetoes the decision (ox's hook).
local function vetoed(player, door, lockpick, how)
	return not OPX.Hooks.Trigger(M.HOOK, { source = player, id = door.id, name = door.name,
		lockpick = lockpick == true, authorised = how })
end

-- The floor between two door requests from one player, read where it is used:
-- a turn and a pick share one window, so they share one number.
local function requestFloorMs()
	return math.floor(OPX.Math.Finite(settings().REQUEST_MS) or 600)
end

--- Turns a door for a player, or answers why not: ox's `ox_doorlock:setState`
--- net event. Yields.
-- @param player integer
-- @param payload table { id, state?, code? }
local function toggle(player, payload)
	if OPX.Cooling(player, 'doorlock.request', requestFloorMs()) then
		return answer(player, false, 'too_fast')
	end
	local door = doors[Access.Id(payload.id) or 0]
	if door == nil then return answer(player, false, 'unknown_door') end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end
	if isDown(player) then return answer(player, false, 'player_down', door) end

	local live = states[door.id]
	local wanted = live.state == 1 and 0 or 1
	if payload.state == 0 or payload.state == 1 then wanted = payload.state end

	local ok, how, item, needsCode = Access.Evaluate(door, subjectOf(player, door), OPX.Now())
	if not ok then return answer(player, false, how, door, { state = wanted }) end
	if vetoed(player, door, false, how) then return answer(player, false, 'not_allowed', door) end

	-- ox asks for the code with `lib.callback.await('ox_doorlock:inputPassCode')`
	-- inside the same request. A server here cannot wait on a client mid-event,
	-- so it answers "the code" and the client sends the request again with it.
	if needsCode then
		if type(payload.code) ~= 'string' or payload.code == '' then
			return answer(player, false, 'passcode_required', door, { state = wanted })
		end
		-- A guess costs three seconds, so a code is not walked from a script.
		if OPX.Cooling(player, 'doorlock.code', 3000) then
			return answer(player, false, 'too_fast', door)
		end
		if payload.code ~= door.passcode then
			OPX.Audit.Security('doorlock.passcode', tostring(door.id), { door = door.id }, player)
			return answer(player, false, 'wrong_passcode', door)
		end
	end

	if wanted == live.state then
		return answer(player, true, wanted == 1 and 'already_locked' or 'already_unlocked', door,
			{ state = live.state })
	end

	if item ~= nil and item.remove and not spendItem(player, item) then
		return answer(player, false, 'no_key', door)
	end

	setState(door, wanted, player, player, item)
	answer(player, true, wanted == 1 and 'locked' or 'unlocked', door, { state = wanted, how = how })
end

--- The steps one pick of this door runs, each `{ durationMs, chance }`.
local function stepsOf(door)
	local pick = Access.Lockpick()
	local list = door.lockpickDifficulty or pick.default
	local out = {}
	for index, step in ipairs(list) do out[index] = Access.StepCost(step, pick.levels) end
	return out
end

--- Starts a pick, if this player may try one here (ox's `pickLock` up to the
--- skill check). Yields.
local function pickStart(player, payload)
	-- REQUEST_MS, not a 600 of its own: the pick spends the turn's window, and an
	-- operator who changed the floor changed it for one of the two.
	if OPX.Cooling(player, 'doorlock.request', requestFloorMs()) then
		return answer(player, false, 'too_fast')
	end
	local door = doors[Access.Id(payload and payload.id) or 0]
	if door == nil then return answer(player, false, 'unknown_door') end
	if not door.lockpick then return answer(player, false, 'not_pickable', door) end
	local pick = Access.Lockpick()
	if states[door.id].state == 0 and not pick.canPickUnlocked then
		return answer(player, false, 'already_unlocked', door)
	end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end
	if isDown(player) then return answer(player, false, 'player_down', door) end
	if lockpickHeld(player) == nil then return answer(player, false, 'no_lockpick', door) end
	if vetoed(player, door, true, 'lockpick') then return answer(player, false, 'not_allowed', door) end

	local steps = stepsOf(door)
	local total, durations = 0, {}
	for index, step in ipairs(steps) do
		total = total + step.durationMs
		durations[index] = step.durationMs
	end
	picking[player] = { id = door.id, at = OPX.Now(), totalMs = total, steps = steps }
	TriggerClientEvent(M.Event.PICK_GO, player, { id = door.id, name = door.name, steps = durations })
end

--- Settles a pick the client says has run. Yields.
local function pickEnd(player, payload)
	local entry = picking[player]
	picking[player] = nil
	if entry == nil or type(payload) ~= 'table' or Access.Id(payload.id) ~= entry.id then return end
	if payload.finished ~= true then return end
	local door = doors[entry.id]
	if door == nil then return answer(player, false, 'unknown_door') end

	local elapsed = OPX.Now() - entry.at
	if elapsed < entry.totalMs - PICK_EARLY_MS then
		OPX.Audit.Security('doorlock.pickEarly', ('%d after %dms of %dms')
			:format(door.id, elapsed, entry.totalMs), { door = door.id }, player)
		return answer(player, false, 'pick_failed', door)
	end
	if elapsed > entry.totalMs + PICK_LATE_MS then return answer(player, false, 'pick_failed', door) end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end

	-- THE PICK IS STILL IN HAND, AND SO IS THE PLAYER, at the moment it turns.
	-- Both were asked only when the steps started, so one lockpick passed from
	-- bag to bag let a whole crew start on it -- and the break roll, finding no
	-- pick left to take, took nothing, so it never wore out. A player knocked
	-- down mid-pick finished it from the floor the same way.
	if isDown(player) then return answer(player, false, 'player_down', door) end
	local held = lockpickHeld(player)
	if held == nil then return answer(player, false, 'no_lockpick', door) end

	local pick = Access.Lockpick()
	local live = states[door.id]
	if live.state == 0 and not pick.canPickUnlocked then
		return answer(player, true, 'already_unlocked', door, { state = 0 })
	end

	-- ox's `lib.skillCheck(difficulty)`: every step must land.
	local success = true
	for _, step in ipairs(entry.steps) do
		if M.Roll() >= step.chance then
			success = false
			break
		end
	end
	-- ox: `math.random(1, success and 100 or 5) == 1` breaks the pick, success or not.
	local broke = M.Roll() < (success and pick.breakSuccess or pick.breakFail)
	if broke then
		local api = OPX.Api.Get('inventory')
		if api ~= nil and type(api.RemoveItem) == 'function' then pcall(api.RemoveItem, player, held, 1) end
	end

	if success then
		local wanted = live.state == 1 and 0 or 1
		setState(door, wanted, 'lockpick:' .. tostring(player), player)
		-- A PICK THAT OPENED THE LOCK AND BROKE says both. It said "You picked
		-- the lock" while the pick left the bag without a word; only a failed
		-- pick that broke was ever told so.
		local code = wanted == 1 and 'locked' or (broke and 'picked_broke' or 'picked')
		return answer(player, true, code, door,
			{ state = wanted, how = 'lockpick', broke = broke or nil })
	end
	return answer(player, false, broke and 'pick_broke' or 'pick_failed', door)
end

-- ── writing a door ──────────────────────────────────────────────────────────

--- A group name the character module does not define, or nil.
local function unknownGroup(door)
	local character = OPX.Config.MODULES.character
	if type(character) ~= 'table' then return nil end
	local jobs = type(character.JOBS) == 'table' and character.JOBS or {}
	local gangs = type(character.GANGS) == 'table' and character.GANGS or {}
	for name, grade in pairs(door.groups) do
		local defined = jobs[name] or gangs[name]
		if defined == nil then return name end
		if type(defined) == 'table' and type(defined.grades) == 'table' and defined.grades[grade] == nil then
			return ('%s:%d'):format(name, grade)
		end
	end
	return nil
end

--- An item name the inventory catalogue does not know, or nil.
local function unknownItem(door)
	local api = OPX.Api.Get('inventory')
	if api == nil or type(api.GetItem) ~= 'function' then return nil end
	for _, item in ipairs(door.items) do
		local read, known = pcall(api.GetItem, item.name)
		if read and known == nil then return item.name end
	end
	return nil
end

local function shallow(source)
	local out = {}
	for field, value in pairs(source or {}) do out[field] = value end
	return out
end

-- ── one definition write at a time ──────────────────────────────────────────
-- THE WRITES BELOW READ `doors`, YIELD ON THE DATABASE, AND THEN WRITE `doors`
-- from what they read. Two of them overlapping is two staff members on the same
-- panel, or the panel and a contract caller, and it went wrong three ways: a door
-- saved while another member deleted it was installed again after the delete
-- (live in the world, gone from the table, back to nothing at the next boot);
-- two doors edited onto the same native leaf both passed `holderOf` before either
-- write landed, and the table then held two doors claiming one leaf; and two
-- edits of one door released the leaves of a version that was no longer the one
-- held, so a native door stayed adopted by nobody's definition. Door edits are
-- rare and short, so they are simply taken in turn: a write waits for the one in
-- flight, then reads `doors` afresh.
local WRITE_WAIT_MS = 5000
local WRITE_POLL_MS = 50
-- A write holding the turn longer than this can only be a coroutine the host
-- dropped mid-yield; honouring it for ever would refuse every edit until a restart.
local WRITE_STALE_MS = 30000
local writingSince = nil

--- Runs `fn` with no other definition write in flight. Yields.
-- @return boolean, string, any what `fn` answered, or false, 'busy'
local function exclusively(fn, ...)
	local deadline = OPX.Now() + WRITE_WAIT_MS
	while writingSince ~= nil and OPX.Now() - writingSince < WRITE_STALE_MS do
		if OPX.Now() >= deadline then return false, 'busy' end
		Wait(WRITE_POLL_MS)
	end
	writingSince = OPX.Now()
	local outcome = table.pack(pcall(fn, ...))
	writingSince = nil
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

--- Creates or rewrites a door: the one write path behind the panel's save,
--- ox's `editDoorlock`, and the `createDoor` / `editDoor` exports. Yields.
-- @param id integer|nil nil creates
-- @param raw table ox's shape, already merged for an edit
-- @param by string|integer who writes it
-- @param player integer|nil a staff member, whose position a new or moved door is checked against
-- @return boolean ok
-- @return string code
-- @return any detail, or the id
local function writeDoor(id, raw, by, player)
	if not loaded then return false, 'not_loaded' end
	local existing = nil
	if id ~= nil then
		existing = doors[id]
		if existing == nil then return false, 'unknown_door' end
	elseif OPX.Table.Count(doors) >= Access.MAX_DOORS then
		return false, 'too_many_doors'
	end

	local door, why = Access.Normalize(id, raw, existing and existing.origin or nil)
	if door == nil then return false, why end
	local group = unknownGroup(door)
	if group ~= nil then return false, 'unknown_group', group end
	local item = unknownItem(door)
	if item ~= nil then return false, 'unknown_item', item end
	local holder = holderOf(door, id)
	if holder ~= nil then return false, 'door_taken', ('%d %s'):format(holder, doors[holder].name) end

	-- A door that is new, or that moved, is checked against where the staff
	-- member stands: a capture is made at the door, and a typo is not.
	if player ~= nil then
		local moved = existing == nil or existing.bucket ~= door.bucket
			or existing.ids[1] ~= door.ids[1] or existing.ids[2] ~= door.ids[2]
			or Access.DistanceSquared(existing, door.coords.x, door.coords.y, door.coords.z) > 1
		if moved then
			local at = pointOf(player)
			if at == nil then return false, 'no_position' end
			if at.bucket ~= door.bucket then return false, 'wrong_bucket' end
			if Access.DistanceSquared(door, at.x, at.y, at.z) > STAFF_REACH * STAFF_REACH then
				return false, 'too_far'
			end
		end
	end

	local stored = Access.Encode(door, true)
	if existing == nil then
		local inserted = Store.Insert(door.name, stored, whoIs(by))
		local newId = inserted.ok and Access.Id(inserted.value) or nil
		if newId == nil then
			Open77.log.error(('[doorlock] %s could not be created: %s'):format(door.name,
				tostring(inserted.detail or inserted.value)))
			return false, 'save_failed'
		end
		door.id = newId
		-- Another write may have taken a leaf while the insert yielded.
		holder = holderOf(door, newId)
		if holder ~= nil then
			Store.Delete(newId, false, whoIs(by))
			return false, 'door_taken', ('%d %s'):format(holder, doors[holder].name)
		end
	else
		local saved = Store.Update(id, door.name, stored, whoIs(by))
		if not saved.ok then
			Open77.log.error(('[doorlock] door %d could not be saved: %s'):format(id, tostring(saved.detail)))
			return false, 'save_failed'
		end
		-- The native doors this door no longer names go back to the service.
		local kept = {}
		for _, native in ipairs(door.ids) do kept[door.bucket .. '|' .. native] = true end
		local dropped = { id = existing.id, bucket = existing.bucket, ids = {} }
		for _, native in ipairs(existing.ids) do
			if not kept[existing.bucket .. '|' .. native] then dropped.ids[#dropped.ids + 1] = native end
		end
		if #dropped.ids > 0 then Backend.Release(dropped) end
	end

	install(door)
	-- ox: an edit sets the door to the state the form carries.
	states[door.id] = { state = door.state }
	if door.state == 0 and door.autolock > 0 then states[door.id].relockAt = OPX.Now() + door.autolock * 1000 end
	Backend.Adopt(door, door.state == 1)
	syncBuckets({ [door.bucket] = true, [existing and existing.bucket or door.bucket] = true })

	OPX.Audit.Log({ event = existing and 'doorlock.edit' or 'doorlock.create',
		message = ('%d %s by %s'):format(door.id, door.name, whoIs(by)),
		source = type(player) == 'number' and player or nil,
		data = { door = door.id, ids = door.ids, bucket = door.bucket } })
	return true, existing and 'saved' or 'created', door.id
end

--- Deletes a door: ox's `removeDoor`. Yields.
-- @return boolean ok
-- @return string code
local function removeDoorNow(id, by, player)
	local door = doors[id or 0]
	if door == nil then return false, 'unknown_door' end
	local gone = Store.Delete(door.id, door.origin ~= nil, whoIs(by))
	if not gone.ok then
		Open77.log.error(('[doorlock] door %d could not be deleted: %s'):format(door.id, tostring(gone.detail)))
		return false, 'save_failed'
	end
	uninstall(door)
	Backend.Release(door)
	syncBuckets({ [door.bucket] = true })
	OPX.Audit.Log({ event = 'doorlock.remove', message = ('%d %s by %s'):format(door.id, door.name, whoIs(by)),
		source = type(player) == 'number' and player or nil, data = { door = door.id } })
	return true, 'removed'
end

local function removeDoor(id, by, player) return exclusively(removeDoorNow, id, by, player) end

--- ox's `editDoor(id, data)`: the fields given replace the door's, a type that
--- does not match the one held is refused, and `''` clears a field.
local function editDoorNow(id, data, by)
	local door = doors[Access.Id(id) or 0]
	if door == nil then return false, 'unknown_door' end
	if type(data) ~= 'table' then return false, 'bad_door' end
	local merged = Access.Encode(door, true)
	for field, value in pairs(data) do
		if field ~= 'id' then
			local current = merged[field]
			if current ~= nil and value ~= '' and type(current) ~= type(value) then
				-- One code, the field in the detail: `bad_<field>` was a code per
				-- field a caller might send, and no catalogue can name them all.
				return false, 'bad_field', tostring(field)
			end
			if value == '' then merged[field] = nil else merged[field] = value end
		end
	end
	-- A new single leaf replaces a double door, and the reverse.
	if data.native ~= nil and data.native ~= '' then merged.doors = nil end
	if data.doors ~= nil and data.doors ~= '' then merged.native = nil end
	return writeDoor(door.id, merged, by, nil)
end

local function editDoor(id, data, by) return exclusively(editDoorNow, id, data, by) end

-- ── staff ───────────────────────────────────────────────────────────────────

local function staffDone(player, verb, ok, code, extra)
	local payload = { verb = verb, ok = ok == true, code = code }
	for field, value in pairs(extra or {}) do payload[field] = value end
	TriggerClientEvent(M.Event.STAFF_DONE, player, payload)
end

--- Sends one staff member the whole list, or one door's detail.
local function staffList(player, id)
	if id ~= nil then
		local door = doors[Access.Id(id) or 0]
		if door == nil then
			return TriggerClientEvent(M.Event.STAFF_LIST, player, { detail = false, id = id })
		end
		-- The code travels to staff who may edit the door, so the panel can show
		-- it (the owner asked to read the pin there). Anybody else gets only
		-- `hasPasscode`.
		local detail = Access.Encode(door, permitted(player, Command.SAVE))
		detail.id, detail.live, detail.seeded = door.id, states[door.id].state, door.origin
		return TriggerClientEvent(M.Event.STAFF_LIST, player, { detail = detail, id = door.id })
	end
	local rows = {}
	for doorId, door in pairs(doors) do rows[#rows + 1] = Access.Summary(door, states[doorId].state) end
	table.sort(rows, function(left, right) return left.id < right.id end)
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + STAFF_CHUNK, #rows) do chunk[#chunk + 1] = rows[index] end
		TriggerClientEvent(M.Event.STAFF_LIST, player, { rows = chunk, offset = offset, total = #rows,
			done = offset + #chunk >= #rows, mode = Backend.Mode() })
		offset = offset + #chunk
	until offset >= #rows
end

--- The panel's save. Yields.
-- @param payload table { id?, door }
local function staffSave(player, payload)
	if type(payload) ~= 'table' or type(payload.door) ~= 'table' then
		return staffDone(player, 'save', false, 'bad_door')
	end
	local id = nil
	if payload.id ~= nil then
		id = Access.Id(payload.id)
		if id == nil or doors[id] == nil then return staffDone(player, 'save', false, 'unknown_door') end
	end
	local raw = shallow(payload.door)
	raw.id = nil
	local ok, code, detail = exclusively(function()
		-- Asked again in turn: the door may have been removed while this waited.
		if id ~= nil and doors[id] == nil then return false, 'unknown_door' end
		-- The code is never sent to a panel, so a save that names none keeps the
		-- one the door has; `''` (or false) is how the panel clears it.
		if raw.passcode == nil and id ~= nil then raw.passcode = doors[id].passcode end
		return writeDoor(id, raw, player, player)
	end)
	if not ok then return staffDone(player, 'save', false, code, { detail = detail }) end
	staffDone(player, 'save', true, code, { id = detail, created = id == nil })
end

--- Prints every door, or one door as JSON (ox's stored shape, no code).
local function staffReport(player, ref)
	if ref ~= nil then
		local door = find(ref)
		if door == nil then return OPX.CommandResult(player, false, 'no door ' .. tostring(ref)) end
		local plain = Access.Encode(door, false)
		plain.id = door.id
		return OPX.CommandResult(player, true, json.encode(plain))
	end
	local ids = {}
	for id in pairs(doors) do ids[#ids + 1] = id end
	table.sort(ids)
	local lines = {}
	local refusals = Backend.Refusals()
	for _, id in ipairs(ids) do
		local door = doors[id]
		lines[#lines + 1] = ('#%d %q %s bucket=%d pos=%.1f,%.1f,%.1f %s%s%s'):format(id, door.name,
			table.concat(door.ids, '+'), door.bucket, door.coords.x, door.coords.y, door.coords.z,
			states[id].state == 1 and 'locked' or 'unlocked',
			door.origin and (' ' .. door.origin) or '',
			refusals[id] and (' REFUSED: ' .. refusals[id]) or '')
	end
	for _, row in ipairs(refusedRows) do lines[#lines + 1] = 'row refused: ' .. row end
	lines[#lines + 1] = ('%d door(s), backend %s'):format(#ids, Backend.Mode())
	OPX.CommandResult(player, true, table.concat(lines, '\n'))
end

--- Turns a door from anywhere, for staff. Yields.
local function staffState(player, ref, wanted)
	local door = find(ref)
	if door == nil then return false, 'unknown_door' end
	if wanted ~= 0 and wanted ~= 1 then wanted = states[door.id].state == 1 and 0 or 1 end
	setState(door, wanted, 'staff:' .. tostring(player), player > 0 and player or nil)
	return true, wanted == 1 and 'locked' or 'unlocked', door
end

--- Cuts a key for a door: its first item that carries metadata, given with
--- `{ type = <metadata>, label = <door name> }`. Yields.
local function staffKey(player, ref, target)
	local door = find(ref)
	if door == nil then return false, 'unknown_door' end
	local item = nil
	for _, entry in ipairs(door.items) do
		if entry.metadata ~= nil then
			item = entry
			break
		end
	end
	if item == nil then return false, 'no_key_item', door end
	local api = OPX.Api.Get('inventory')
	if api == nil or type(api.AddItem) ~= 'function' then return false, 'no_inventory', door end
	local read, given = pcall(api.AddItem, target, item.name, 1,
		{ type = item.metadata, label = OPX.Text.Clean(door.name, 48) })
	if not read or type(given) ~= 'table' or given.ok ~= true then return false, 'key_refused', door end
	OPX.Audit.Log({ event = 'doorlock.key', message = ('%d to %d by %d'):format(door.id, target, player),
		source = player > 0 and player or nil, data = { door = door.id, target = target, item = item.name } })
	return true, 'key_given', door
end

--- Registers the staff commands. Each is restricted: the host checks
--- `command.<name>` before the handler runs.
local function registerCommands()
	-- ox's `/doorlock [closest]`.
	OPX.Command.Register(Command.OPEN, { restricted = true, help = 'doorlock.help.open',
		params = { { name = 'closest', optional = true, help = locale('doorlock.help.closest') } } },
		function(source, args)
			if source <= 0 then return staffReport(source) end
			TriggerClientEvent(M.Event.STAFF_OPEN, source, { access = staffFlags(source) or {},
				mode = Backend.Mode(), closest = args[1] ~= nil })
		end)

	OPX.Command.Register(Command.LIST, { restricted = true, help = 'doorlock.help.list',
		params = { { name = 'door', optional = true, help = locale('doorlock.help.door') } } },
		function(source, args) staffReport(source, args[1]) end)

	OPX.Command.Register(Command.REMOVE, { restricted = true, help = 'doorlock.help.remove',
		cooldownMs = 500, params = { { name = 'door', help = locale('doorlock.help.door') } } },
		function(source, args, raw)
			CreateThread(function()
				local door = find(args[1])
				local ok, code = removeDoor(door and door.id, source, source)
				OPX.CommandNotice(source, raw, ok and 'success' or 'error', ok
					and locale('doorlock.staff.removed', { door = door.name })
					or locale('doorlock.error.' .. code), false, 'trash')
			end)
		end)

	OPX.Command.Register(Command.LOCK, { restricted = true, help = 'doorlock.help.lock',
		cooldownMs = 300, params = { { name = 'door', help = locale('doorlock.help.door') },
			{ name = 'on|off', optional = true, help = locale('doorlock.help.state') } } },
		function(source, args, raw)
			local switch, wanted = OPX.Text.Switch(args[2]), nil
			if switch ~= nil then wanted = switch and 1 or 0 end
			CreateThread(function()
				local ok, code, door = staffState(source, args[1], wanted)
				OPX.CommandNotice(source, raw, ok and 'success' or 'error', ok
					and locale('doorlock.answer.' .. code, { door = door.name })
					or locale('doorlock.error.' .. code), false, 'lock')
			end)
		end)

	OPX.Command.Register(Command.KEY, { restricted = true, help = 'doorlock.help.key',
		cooldownMs = 500, params = { { name = 'door', help = locale('doorlock.help.door') },
			{ name = 'player', optional = true, help = locale('doorlock.help.player') } } },
		function(source, args, raw)
			local target = tonumber(args[2]) or source
			if target == nil or target <= 0 then
				return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.no_player'))
			end
			CreateThread(function()
				local ok, code, door = staffKey(source, args[1], target)
				OPX.CommandNotice(source, raw, ok and 'success' or 'error',
					locale((ok and 'doorlock.staff.' or 'doorlock.error.') .. code,
						{ door = door and door.name or '' }), false, 'key')
			end)
		end)
end

-- ── loading ─────────────────────────────────────────────────────────────────

--- Inserts every config door and every row of the first version's table that
--- is not in yet, once each. Yields.
local function seed()
	local seeds, problems = Access.ConfigSeeds()
	for _, line in ipairs(problems) do Open77.log.warn('[doorlock] config: ' .. line) end
	local added = 0
	for key, door in pairs(seeds) do
		local inserted = Store.Seed('config:' .. key, door.name, Access.Encode(door, true))
		if inserted.ok and (tonumber(inserted.value) or 0) > 0 then added = added + 1 end
	end

	-- THE FIRST VERSION'S DOORS, carried over rather than lost. Each row lands
	-- under `legacy:<key>`, so this runs on every boot and inserts each once; a
	-- row whose key a config door also used was shadowed by that config door in
	-- the first version and is shadowed here too.
	local migrated, refused = 0, 0
	local has = Store.HasLegacy()
	if has.ok and (tonumber(has.value) or 0) > 0 then
		local rows = Store.FetchLegacy()
		for _, row in ipairs(rows.ok and type(rows.value) == 'table' and rows.value or {}) do
			local key = type(row.door_key) == 'string' and row.door_key or nil
			if key ~= nil and seeds[key] == nil then
				local plain = OPX.Storage.Decode(row.data, nil)
				local door, why = Access.Normalize(nil, Access.FromLegacy(key, plain, row.bucket), 'legacy:' .. key)
				if door == nil then
					refused = refused + 1
					Open77.log.warn(('[doorlock] %s row %s not carried over: %s')
						:format(Store.LEGACY, key, tostring(why)))
				else
					local inserted = Store.Seed('legacy:' .. key, door.name, Access.Encode(door, true))
					if inserted.ok and (tonumber(inserted.value) or 0) > 0 then migrated = migrated + 1 end
				end
			end
		end
	end
	if added > 0 or migrated > 0 or refused > 0 then
		Open77.log.info(('[doorlock] %d config door(s) seeded, %d door(s) carried over from %s, %d refused')
			:format(added, migrated, Store.LEGACY, refused))
	end
end

--- Reads every saved door into the list. Yields.
local function load()
	local rows = Store.FetchAll()
	if not rows.ok then
		Open77.log.error('[doorlock] saved doors could not be read: ' .. tostring(rows.detail))
		return
	end
	for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
		local plain = OPX.Storage.Decode(row.data, nil)
		local origin = type(row.origin) == 'string' and row.origin or nil
		local door, why = nil, 'bad_json'
		if plain ~= nil then door, why = Access.Normalize(row.id, plain, origin) end
		if door ~= nil then
			local holder = holderOf(door, door.id)
			if holder ~= nil then door, why = nil, ('native door already managed by #%d'):format(holder) end
		end
		if door == nil then
			refusedRows[#refusedRows + 1] = ('#%s: %s'):format(tostring(row.id), why)
			Open77.log.warn(('[doorlock] saved door #%s refused: %s'):format(tostring(row.id), why))
		else
			install(door)
		end
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears the state and contributes the table. Never yields.
-- @author dop42
function M.Init()
	doors, states, byNative, byOrigin = {}, {}, {}, {}
	writingSince = nil
	sentBucket, picking, refusedRows = {}, {}, {}
	loaded = false
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- The contract answer for one door, ox's `getDoor`.
local function public(door)
	if door == nil then return Result.Err('doorlock.unknownDoor') end
	return Result.Ok(Access.Public(door, states[door.id].state))
end

--- A write's three answers as a contract Result.
-- The code is answered under `doorlock.error.`, the family the panel already
-- writes a sentence for every write refusal in: as `doorlock.<code>` it was a
-- name a calling resource could show and no catalogue had ever written.
local function written(ok, code, detail)
	if not ok then return Result.Err('doorlock.error.' .. tostring(code), detail) end
	return Result.Ok(detail)
end

--- Publishes the server half of the doorlock contract: ox's exports, by name.
-- @author dop42
function M.Api()
	OPX.Api.Provide('doorlock', 1, {
		--- ox's `getDoor(id)`. A seeded or migrated door also answers to its old key.
		Get = function(ref) return public(find(ref)) end,
		--- ox's `getDoorFromName(name)`: the lowest id of that name.
		GetFromName = function(name)
			if type(name) ~= 'string' then return Result.Err('doorlock.unknownDoor') end
			local best = nil
			for id, door in pairs(doors) do
				if door.name == name and (best == nil or id < best.id) then best = door end
			end
			return public(best)
		end,
		--- ox's `getAllDoors()`, by id.
		All = function()
			local ids, out = {}, {}
			for id in pairs(doors) do ids[#ids + 1] = id end
			table.sort(ids)
			for index, id in ipairs(ids) do out[index] = Access.Public(doors[id], states[id].state) end
			return Result.Ok(out)
		end,
		--- ox's `setDoorState(id, state)` with no source: the caller decided, and
		--- the door's own rules are not consulted. Yields on the networked backend.
		SetState = function(ref, state, by)
			local door = find(ref)
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			if state == true then state = 1 elseif state == false then state = 0 end
			if state ~= 0 and state ~= 1 then return Result.Err('doorlock.badState') end
			setState(door, state, by or 'contract', nil)
			return Result.Ok(state)
		end,
		--- The first version's boolean spelling of the same.
		SetLocked = function(ref, locked, by)
			local door = find(ref)
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			if type(locked) ~= 'boolean' then return Result.Err('doorlock.badState') end
			setState(door, locked and 1 or 0, by or 'contract', nil)
			return Result.Ok(locked)
		end,
		--- ox's `createDoor(data)`, answering the new id. Yields.
		Create = function(data, by)
			if type(data) ~= 'table' then return Result.Err('doorlock.error.bad_door') end
			return written(exclusively(writeDoor, nil, shallow(data), by or 'contract', nil))
		end,
		--- ox's `editDoor(id, data)`. Yields.
		Edit = function(ref, data, by)
			local door = find(ref)
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			return written(editDoor(door.id, data, by or 'contract'))
		end,
		--- ox's `removeDoor(id)`. Yields.
		Remove = function(ref, by)
			local door = find(ref)
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			return written(removeDoor(door.id, by or 'contract', nil))
		end,
		--- Whether a player may turn a door, ignoring where they stand and the
		--- code. Yields.
		IsAuthorised = function(player, ref)
			local door = find(ref)
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			local ok, how, _, needsCode = Access.Evaluate(door, subjectOf(player, door), OPX.Now())
			return Result.Ok({ allowed = ok, how = how, passcode = needsCode })
		end,
		Mode = function() return Backend.Mode() end,
	})
end

--- A staff net event's common gate: a connection, the grant, the floor.
local function staffGate(verb, entry, floorMs)
	return function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return nil end
		if not permitted(player, entry) then
			OPX.Audit.Security('doorlock.staffDenied', verb, nil, player)
			staffDone(player, verb, false, 'not_permitted')
			return nil
		end
		if OPX.Cooling(player, 'doorlock.staff.' .. verb, floorMs) then
			staffDone(player, verb, false, 'too_fast')
			return nil
		end
		return player, type(payload) == 'table' and payload or {}
	end
end

--- Seeds, reads and adopts the saved doors, and wires the doors in.
-- @author dop42
function M.Start()
	running = true
	local mode = Backend.Decide()
	registerCommands()

	RegisterNetEvent(M.Event.ASK, function()
		local player = tonumber(source)
		if player == nil or player <= 0 or OPX.Cooling(player, 'doorlock.ask', 1000) then return end
		sync(player)
	end)

	RegisterNetEvent(M.Event.SET_STATE, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 or type(payload) ~= 'table' then return end
		CreateThread(function() toggle(player, payload) end)
	end)

	RegisterNetEvent(M.Event.PICK, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 or type(payload) ~= 'table' then return end
		CreateThread(function() pickStart(player, payload) end)
	end)

	RegisterNetEvent(M.Event.PICKED, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		CreateThread(function() pickEnd(player, payload) end)
	end)

	RegisterNetEvent(M.Event.STAFF_ASK, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		if not permitted(player, Command.OPEN) then
			OPX.Audit.Security('doorlock.staffDenied', 'list', nil, player)
			return
		end
		local id = type(payload) == 'table' and Access.Id(payload.id) or nil
		-- Floored per question: the panel asks for the list and for one door in
		-- the same breath, and one must not swallow the other. Per KIND of
		-- question, not per door: the key was built from the id the client sent,
		-- so every door number asked for left one more key in this player's
		-- cooldowns for the rest of the session -- up to `MAX_ID` of them.
		if OPX.Cooling(player, 'doorlock.staffAsk:' .. (id ~= nil and 'door' or 'list'), 250) then
			return
		end
		staffList(player, id)
	end)

	local saveGate = staffGate('save', Command.SAVE, 1000)
	RegisterNetEvent(M.Event.STAFF_SAVE, function(payload)
		local player, body = saveGate(payload)
		if player == nil then return end
		CreateThread(function() staffSave(player, body) end)
	end)

	local removeGate = staffGate('remove', Command.REMOVE, 500)
	RegisterNetEvent(M.Event.STAFF_REMOVE, function(payload)
		local player, body = removeGate(payload)
		if player == nil then return end
		CreateThread(function()
			local ok, code = removeDoor(Access.Id(body.id), player, player)
			staffDone(player, 'remove', ok, code, { id = Access.Id(body.id) })
		end)
	end)

	local stateGate = staffGate('state', Command.LOCK, 300)
	RegisterNetEvent(M.Event.STAFF_STATE, function(payload)
		local player, body = stateGate(payload)
		if player == nil then return end
		CreateThread(function()
			local wanted = (body.state == 0 or body.state == 1) and body.state or nil
			local ok, code, door = staffState(player, Access.Id(body.id), wanted)
			staffDone(player, 'state', ok, code, { id = door and door.id, name = door and door.name })
		end)
	end)

	local keyGate = staffGate('key', Command.KEY, 500)
	RegisterNetEvent(M.Event.STAFF_KEY, function(payload)
		local player, body = keyGate(payload)
		if player == nil then return end
		CreateThread(function()
			local ok, code, door = staffKey(player, Access.Id(body.id), player)
			staffDone(player, 'key', ok, code, { id = door and door.id, name = door and door.name })
		end)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(raw)
		local player = tonumber(raw) or -1
		sentBucket[player], picking[player] = nil, nil
	end)

	-- A player who moves between buckets has to be given that bucket's doors,
	-- and there is no host event for a bucket change, so this is a poll.
	OPX.Scheduler.Every('doorlock:buckets', 2000, function()
		for _, player in ipairs(players()) do
			local at = pointOf(player)
			if at ~= nil and sentBucket[player] ~= nil and sentBucket[player] ~= at.bucket then
				sync(player)
			end
		end
	end)

	-- The autolock: a door unlocked with `autolock` set locks itself again.
	OPX.Scheduler.Every('doorlock:autolock', 500, function()
		-- Collected first: a relock yields on the networked backend, and a save
		-- landing in that yield rebuilds the table this would be walking.
		local now, due = OPX.Now(), {}
		for id, live in pairs(states) do
			if live.relockAt ~= nil and now >= live.relockAt then due[#due + 1] = id end
		end
		for _, id in ipairs(due) do
			local live = states[id]
			if doors[id] ~= nil and live ~= nil and live.relockAt ~= nil and live.state == 0 then
				setState(doors[id], 1, 'autolock', nil)
			elseif live ~= nil then
				live.relockAt = nil
			end
		end
	end)

	CreateThread(function()
		seed()
		load()
		loaded = true
		local adopted = 0
		for id, door in pairs(doors) do
			if Backend.Adopt(door, states[id].state == 1) then adopted = adopted + 1 end
		end
		local buckets = { [0] = true }
		for _, door in pairs(doors) do buckets[door.bucket] = true end
		syncBuckets(buckets)
		Open77.log.info(('[doorlock] ready: %d door(s), %d refused, backend %s%s')
			:format(OPX.Table.Count(doors), #refusedRows, mode,
				mode == 'networked' and (', %d adopted'):format(adopted) or ''))
	end)

	-- The service forgets its owners when it restarts; take them back.
	if mode == 'networked' then
		OPX.Scheduler.Every('doorlock:adopt', 30000, function()
			if not running or not loaded then return end
			Backend.Sweep(doors, function(id) return states[id] ~= nil and states[id].state == 1 end)
		end)
	end
end

--- Forgets the players. The platform releases every door this resource
--- registered when it stops, and each client resets its own.
-- @author dop42
function M.Stop()
	running = false
	sentBucket, picking = {}, {}
end
