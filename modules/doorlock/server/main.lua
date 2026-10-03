--- Server half: the doors, who may turn them, and the staff writes.
-- @author dop42
--
-- THIS FILE IS THE GATE. A client names a door KEY and the state it wants --
-- and, for a coded door, the code it was given -- and every other fact is read
-- here: the door out of this VM's own list, the position and bucket from the
-- host, the job, gang and grade from the character contract, the bag from the
-- inventory contract. In this order, cheapest first, so a client hammering the
-- event pays nothing:
--
--   1. the per-player request floor        (a clock)
--   2. the door exists                     (a lookup)
--   3. same bucket, within reach           (the host's position)
--   4. not downed                          (the downed contract, when present)
--   5. may turn it                         (`Access.Evaluate`)
--   6. the code, for a coded door          (compared here, never sent out)
--
-- Then the lock moves through the backend, the bucket is told, the autolock is
-- armed, and the change is audited and published on `opx:on:doorlock:changed`.
--
-- A LOCKPICK IS TIMED HERE. The client draws the bar; the server starts the
-- clock when it says go, and a "done" that arrives before the clock ran is
-- refused and audited -- a client that skips the bar has skipped the bar and
-- picked nothing. The roll is the server's too.
--
-- STAFF WRITES are the panel's save (`STAFF_SAVE`, gated on
-- `command.opx.doorlock.save`) and four restricted commands. Every one is
-- audited with who did it.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access
local Store = M.Storage
local Backend = M.Backend
local Command = M.Command
local Result = OPX.Result

-- Doors read from config, doors read from the database, and the merge of the
-- two that everything else reads.
local configDoors, dbDoors, doors = {}, {}, {}

-- `bucket|0xID` to the key of the door it belongs to.
local byNative = {}

-- The live state of each door, by key: { locked, relockAt, by }.
local states = {}

-- The bucket each player was last sent, and their lockpick in progress.
local sentBucket, picking = {}, {}

-- Rows the database answered that were refused, for the list command.
local refusedRows = {}

-- Whether the module is running, for the jobs.
local running = false

-- Doors per sync event. A door is about twenty value nodes on the wire and the
-- host drops an event past 1024 of them without a word.
local CHUNK = 20

-- Summary rows per staff list event.
local STAFF_CHUNK = 30

-- Metres a staff member may be from a door they capture or re-pair.
local STAFF_REACH = 60.0

-- Milliseconds a pick's "done" may arrive early, for the wire.
local PICK_EARLY_MS = 400
-- And how long after the bar should have ended it is still believed.
local PICK_LATE_MS = 20000

-- The roll, a field so a test can load the dice. Answers 0..1.
M.Roll = math.random

local function settings() return M.Settings end

-- ── reading the world ───────────────────────────────────────────────────────

--- Whether the ACL grants this player a command's entry. False when unreadable.
local function permitted(player, name)
	local read, allowed = pcall(function()
		return Open77.acl.isAllowed(player, 'command.' .. name)
	end)
	return read and allowed == true
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
	local read, loaded = pcall(api.GetPlayer, player)
	if not read or type(loaded) ~= 'table' or type(loaded.PlayerData) ~= 'table' then return nil end
	local data = loaded.PlayerData
	return {
		job = type(data.job) == 'table' and data.job or nil,
		jobs = type(data.jobs) == 'table' and data.jobs or nil,
		gang = type(data.gang) == 'table' and data.gang or nil,
		gangs = type(data.gangs) == 'table' and data.gangs or nil,
		citizenId = data.citizenId,
		atMs = OPX.Now(),
	}
end

--- How many units of one key item a bag holds. Yields on an offline bag.
local function countKey(player, door, item)
	local api = OPX.Api.Get('inventory')
	if api == nil then return 0 end
	local read, answer
	if item.bound then
		if type(api.CountWhere) ~= 'function' then return 0 end
		read, answer = pcall(api.CountWhere, player, item.name, { door = door.key })
	else
		if type(api.GetItemCount) ~= 'function' then return 0 end
		read, answer = pcall(api.GetItemCount, player, item.name)
	end
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return 0 end
	return tonumber(answer.value) or 0
end

--- Everything `Access.Evaluate` needs about one player.
local function subjectOf(player, door)
	return {
		staff = settings().STAFF_BYPASS ~= false and permitted(player, Command.BYPASS),
		snapshot = snapshotOf(player),
		items = function(item) return countKey(player, door, item) end,
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

-- ── the list ────────────────────────────────────────────────────────────────

--- Rebuilds the merged list and the native index. Keeps every live state whose
--- door survived; a new door starts in its default state.
local function rebuild()
	local merged, index = {}, {}
	local function claim(door)
		for _, id in ipairs(door.ids) do
			local slot = door.bucket .. '|' .. id
			if index[slot] ~= nil and index[slot] ~= door.key then return index[slot] end
		end
		for _, id in ipairs(door.ids) do index[door.bucket .. '|' .. id] = door.key end
		merged[door.key] = door
		return nil
	end
	for _, door in pairs(configDoors) do claim(door) end
	for key, door in pairs(dbDoors) do
		if configDoors[key] ~= nil then
			Open77.log.warn(('[doorlock] database door %s is shadowed by the config door of that key')
				:format(key))
		else
			local holder = claim(door)
			if holder ~= nil then
				Open77.log.warn(('[doorlock] database door %s names a native door %s already manages')
					:format(key, holder))
			end
		end
	end
	doors, byNative = merged, index
	for key in pairs(states) do
		if doors[key] == nil then states[key] = nil end
	end
	for key, door in pairs(doors) do
		if states[key] == nil then states[key] = { locked = door.locked } end
	end
end

--- The doors of one bucket, ready for the wire, sorted by key.
local function wireFor(bucket)
	local list = {}
	for key, door in pairs(doors) do
		if door.bucket == bucket then list[#list + 1] = Access.Wire(door, states[key].locked) end
	end
	table.sort(list, function(left, right) return left.key < right.key end)
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
		bypass = permitted(player, Command.BYPASS),
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

--- Tells everyone in a door's bucket its new state.
local function pushState(door)
	local state = states[door.key]
	for _, player in ipairs(players()) do
		local at = pointOf(player)
		if at ~= nil and at.bucket == door.bucket then
			TriggerClientEvent(M.Event.STATE, player, { key = door.key, locked = state.locked })
		end
	end
end

--- Answers one player about one request.
local function answer(player, ok, code, door, extra)
	local payload = { ok = ok == true, code = code, key = door and door.key or nil,
		name = door and door.name or nil }
	for field, value in pairs(extra or {}) do payload[field] = value end
	TriggerClientEvent(M.Event.ANSWER, player, payload)
end

--- Moves a door's lock: the state, the backend, the bucket, the autolock and the
--- record of it. Yields on the networked backend.
-- @param door table
-- @param locked boolean
-- @param by string what turned it: a player id, 'autolock', 'staff', an export
-- @param player integer|nil the player it was, for the bus and the audit line
local function setLocked(door, locked, by, player)
	local state = states[door.key]
	state.locked = locked == true
	state.by = by
	state.relockAt = nil
	if not state.locked and door.autolock > 0 then
		state.relockAt = OPX.Now() + door.autolock * 1000
	end
	pushState(door)
	Backend.Apply(door, state.locked)
	OPX.Publish(M.Event.ON_CHANGED, player, { door = door.key, locked = state.locked, by = tostring(by) })
	OPX.Audit.Log({
		event = 'doorlock.' .. (state.locked and 'lock' or 'unlock'),
		message = ('%s by %s'):format(door.key, tostring(by)),
		source = player,
		data = { door = door.key, by = tostring(by) },
	})
end

-- ── a player at a door ──────────────────────────────────────────────────────

--- Whether a door has any rule a player can meet without staff rights.
local function hasRules(door)
	return #door.groups > 0 or #door.items > 0 or #door.characters > 0
end

--- Turns a door for a player, or answers why not. Yields.
-- @param player integer
-- @param payload table { key, locked?, code? }
local function toggle(player, payload)
	local requestMs = math.floor(OPX.Math.Finite(settings().REQUEST_MS) or 600)
	if OPX.Cooling(player, 'doorlock.request', requestMs) then
		return answer(player, false, 'too_fast')
	end
	local door = doors[Access.Key(payload.key) or '']
	if door == nil then return answer(player, false, 'unknown_door') end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end
	if isDown(player) then return answer(player, false, 'player_down', door) end

	local state = states[door.key]
	local wanted = not state.locked
	if type(payload.locked) == 'boolean' then wanted = payload.locked end

	local allowed, how, item = Access.Evaluate(door, subjectOf(player, door), OPX.Now())
	-- A coded door with no other rule is ox's "passcode only" door: the code is
	-- the whole of the access.
	local codeOnly = door.passcode ~= nil and not hasRules(door)
	if not allowed and not codeOnly then return answer(player, false, how, door) end

	if door.passcode ~= nil and how ~= 'staff' then
		if type(payload.code) ~= 'string' or payload.code == '' then
			return answer(player, false, 'passcode_required', door, { locked = wanted })
		end
		-- A guess costs three seconds, so a code is not walked from a script.
		if OPX.Cooling(player, 'doorlock.code', 3000) then
			return answer(player, false, 'too_fast', door)
		end
		if payload.code ~= door.passcode then
			OPX.Audit.Security('doorlock.passcode', door.key, { door = door.key }, player)
			return answer(player, false, 'wrong_passcode', door)
		end
		how = how == 'item' and how or 'passcode'
	end

	if wanted == state.locked then
		return answer(player, true, wanted and 'already_locked' or 'already_unlocked', door,
			{ locked = state.locked })
	end

	if item ~= nil and item.remove then
		local api = OPX.Api.Get('inventory')
		local read, removed = false, nil
		if api ~= nil and type(api.RemoveItem) == 'function' then
			read, removed = pcall(api.RemoveItem, player, item.name, 1)
		end
		if not read or type(removed) ~= 'table' or removed.ok ~= true then
			return answer(player, false, 'no_key', door)
		end
	end

	setLocked(door, wanted, player, player)
	answer(player, true, wanted and 'locked' or 'unlocked', door, { locked = wanted, how = how })
end

--- Starts a pick, if this player may try one here. Yields.
local function pickStart(player, payload)
	if OPX.Cooling(player, 'doorlock.request', 600) then return answer(player, false, 'too_fast') end
	local door = doors[Access.Key(payload and payload.key) or '']
	if door == nil then return answer(player, false, 'unknown_door') end
	if not door.lockpick then return answer(player, false, 'not_pickable', door) end
	local pick = Access.Lockpick()
	if not states[door.key].locked and not pick.canPickUnlocked then
		return answer(player, false, 'already_unlocked', door)
	end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end
	if isDown(player) then return answer(player, false, 'player_down', door) end
	local api = OPX.Api.Get('inventory')
	local held = 0
	if api ~= nil and type(api.GetItemCount) == 'function' then
		local read, counted = pcall(api.GetItemCount, player, pick.item)
		if read and type(counted) == 'table' and counted.ok == true then
			held = tonumber(counted.value) or 0
		end
	end
	if held < 1 then return answer(player, false, 'no_lockpick', door) end

	local level = pick.difficulty[door.difficulty] or pick.difficulty[pick.default]
	picking[player] = { key = door.key, at = OPX.Now(), durationMs = level.durationMs,
		chance = level.chance }
	TriggerClientEvent(M.Event.PICK_GO, player, { key = door.key, name = door.name,
		durationMs = level.durationMs })
end

--- Settles a pick the client says has run. Yields.
local function pickEnd(player, payload)
	local entry = picking[player]
	picking[player] = nil
	if entry == nil or type(payload) ~= 'table' or payload.key ~= entry.key then return end
	if payload.finished ~= true then return end
	local door = doors[entry.key]
	if door == nil then return answer(player, false, 'unknown_door') end

	local elapsed = OPX.Now() - entry.at
	if elapsed < entry.durationMs - PICK_EARLY_MS then
		OPX.Audit.Security('doorlock.pickEarly', ('%s after %dms of %dms')
			:format(door.key, elapsed, entry.durationMs), { door = door.key }, player)
		return answer(player, false, 'pick_failed', door)
	end
	if elapsed > entry.durationMs + PICK_LATE_MS then return answer(player, false, 'pick_failed', door) end
	local far = outOfReach(player, door)
	if far ~= nil then return answer(player, false, far, door) end

	local pick = Access.Lockpick()
	local state = states[door.key]
	if not state.locked and not pick.canPickUnlocked then
		return answer(player, true, 'already_unlocked', door, { locked = false })
	end

	if M.Roll() < entry.chance then
		setLocked(door, not state.locked, 'lockpick:' .. tostring(player), player)
		return answer(player, true, state.locked and 'locked' or 'picked', door,
			{ locked = state.locked, how = 'lockpick' })
	end

	if M.Roll() < pick.breakChance then
		local api = OPX.Api.Get('inventory')
		if api ~= nil and type(api.RemoveItem) == 'function' then
			pcall(api.RemoveItem, player, pick.item, 1)
		end
		return answer(player, false, 'pick_broke', door)
	end
	return answer(player, false, 'pick_failed', door)
end

-- ── staff ───────────────────────────────────────────────────────────────────

--- The summary row the staff list draws.
local function summaryOf(door)
	return { key = door.key, name = door.name, bucket = door.bucket, x = door.x, y = door.y,
		z = door.z, origin = door.origin, locked = states[door.key].locked, ids = door.ids }
end

--- Sends one staff member the whole list, or one door's detail.
local function staffList(player, key)
	if key ~= nil then
		local door = doors[Access.Key(key) or '']
		if door == nil then
			return TriggerClientEvent(M.Event.STAFF_LIST, player, { detail = false, key = key })
		end
		local detail = Access.Plain(door, false)
		detail.key, detail.origin, detail.live = door.key, door.origin, states[door.key].locked
		return TriggerClientEvent(M.Event.STAFF_LIST, player, { detail = detail, key = door.key })
	end
	local rows = {}
	for _, door in pairs(doors) do rows[#rows + 1] = summaryOf(door) end
	table.sort(rows, function(left, right) return left.key < right.key end)
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + STAFF_CHUNK, #rows) do chunk[#chunk + 1] = rows[index] end
		TriggerClientEvent(M.Event.STAFF_LIST, player, { rows = chunk, offset = offset,
			done = offset + #chunk >= #rows, mode = Backend.Mode() })
		offset = offset + #chunk
	until offset >= #rows
end

--- Whether every group names a job or gang the character module defines.
local function unknownGroup(door)
	local character = OPX.Config.MODULES.character
	if type(character) ~= 'table' then return nil end
	for _, group in ipairs(door.groups) do
		local list = group.kind == 'job' and character.JOBS or character.GANGS
		if type(list) == 'table' then
			local defined = list[group.name]
			if defined == nil then return group.name end
			if type(defined.grades) == 'table' and defined.grades[group.grade] == nil then
				return ('%s:%d'):format(group.name, group.grade)
			end
		end
	end
	return nil
end

--- Whether every key item is in the inventory catalogue.
local function unknownItem(door)
	local api = OPX.Api.Get('inventory')
	if api == nil or type(api.GetItem) ~= 'function' then return nil end
	for _, item in ipairs(door.items) do
		local read, known = pcall(api.GetItem, item.name)
		if read and known == nil then return item.name end
	end
	return nil
end

--- Who a staff member is, for the row and the audit line.
local function whoIs(player)
	local name = type(GetPlayerName) == 'function' and GetPlayerName(player) or nil
	return ('%d:%s'):format(player, OPX.Text.Clean(name, 40) or '?')
end

--- Saves a door from the panel. Yields.
-- @param player integer
-- @param payload table { key?, door }
local function staffSave(player, payload)
	local function refuse(code, detail)
		TriggerClientEvent(M.Event.STAFF_SAVED, player, { ok = false, code = code, detail = detail })
	end
	if type(payload) ~= 'table' or type(payload.door) ~= 'table' then return refuse('bad_door') end

	local existing = nil
	local key = payload.key
	if key ~= nil then
		existing = doors[Access.Key(key) or '']
		if existing == nil then return refuse('unknown_door') end
		if existing.origin == 'config' then return refuse('config_door') end
		key = existing.key
	else
		if OPX.Table.Count(dbDoors) >= Access.MAX_DOORS then return refuse('too_many_doors') end
		key = Access.KeyFrom(payload.door.name, function(candidate)
			return doors[candidate] ~= nil or dbDoors[candidate] ~= nil
		end)
	end

	local plain = {}
	for field, value in pairs(payload.door) do plain[field] = value end
	-- The code is never sent to a panel, so a save that names none keeps the
	-- one the door has; `false` is how a panel clears it.
	if plain.passcode == nil and existing ~= nil then plain.passcode = existing.passcode end

	local door, why = Access.Normalize(key, plain, 'db')
	if door == nil then return refuse(why) end
	local group = unknownGroup(door)
	if group ~= nil then return refuse('unknown_group', group) end
	local item = unknownItem(door)
	if item ~= nil then return refuse('unknown_item', item) end
	for _, id in ipairs(door.ids) do
		local holder = byNative[door.bucket .. '|' .. id]
		if holder ~= nil and holder ~= key then return refuse('door_taken', holder) end
	end

	-- A door that is new, or that moved, is checked against where the staff
	-- member stands: a capture is made at the door, and a typo is not.
	local moved = existing == nil or existing.bucket ~= door.bucket
		or existing.ids[1] ~= door.ids[1] or existing.ids[2] ~= door.ids[2]
		or Access.DistanceSquared(existing, door.x, door.y, door.z) > 1
	if moved then
		local at = pointOf(player)
		if at == nil then return refuse('no_position') end
		if at.bucket ~= door.bucket then return refuse('wrong_bucket') end
		if Access.DistanceSquared(door, at.x, at.y, at.z) > STAFF_REACH * STAFF_REACH then
			return refuse('too_far')
		end
	end

	local saved = Store.Upsert(key, door.name, door.bucket, Access.Plain(door, true), whoIs(player))
	if not saved.ok then
		Open77.log.error(('[doorlock] %s could not be saved: %s'):format(key, tostring(saved.detail)))
		return refuse('save_failed')
	end

	if existing ~= nil then
		-- The native doors this door no longer names go back to the service.
		local kept = {}
		for _, id in ipairs(door.ids) do kept[door.bucket .. '|' .. id] = true end
		local dropped = { key = existing.key, bucket = existing.bucket, ids = {} }
		for _, id in ipairs(existing.ids) do
			if not kept[existing.bucket .. '|' .. id] then dropped.ids[#dropped.ids + 1] = id end
		end
		if #dropped.ids > 0 then Backend.Release(dropped) end
	end
	dbDoors[key] = door
	rebuild()
	if existing == nil then states[key] = { locked = door.locked } end
	Backend.Adopt(door, states[key].locked)
	syncBuckets({ [door.bucket] = true, [existing and existing.bucket or door.bucket] = true })

	OPX.Audit.Log({ event = existing and 'doorlock.edit' or 'doorlock.create',
		message = ('%s by %s'):format(key, whoIs(player)), source = player,
		data = { door = key, ids = door.ids, bucket = door.bucket } })
	TriggerClientEvent(M.Event.STAFF_SAVED, player, { ok = true, key = key, created = existing == nil })
end

--- Deletes a database door. Yields.
local function staffRemove(player, raw, key)
	local door = doors[Access.Key(key) or '']
	if door == nil then
		return OPX.CommandNotice(player, raw, 'error', locale('doorlock.error.unknown_door'))
	end
	if door.origin == 'config' then
		return OPX.CommandNotice(player, raw, 'error', locale('doorlock.error.config_door'))
	end
	local gone = Store.Delete(door.key)
	if not gone.ok then
		Open77.log.error(('[doorlock] %s could not be deleted: %s'):format(door.key, tostring(gone.detail)))
		return OPX.CommandNotice(player, raw, 'error', locale('doorlock.error.save_failed'))
	end
	dbDoors[door.key] = nil
	rebuild()
	Backend.Release(door)
	syncBuckets({ [door.bucket] = true })
	OPX.Audit.Log({ event = 'doorlock.remove', message = ('%s by %s'):format(door.key, whoIs(player)),
		source = player, data = { door = door.key } })
	OPX.CommandNotice(player, raw, 'success', locale('doorlock.staff.removed', { door = door.name }),
		false, 'trash')
end

--- Prints every door, or one door's config block.
local function staffReport(player, key)
	if key ~= nil then
		local door = doors[Access.Key(key) or '']
		if door == nil then return OPX.CommandResult(player, false, 'no door named ' .. tostring(key)) end
		return OPX.CommandResult(player, true, Access.ConfigBlock(door))
	end
	local keys = {}
	for name in pairs(doors) do keys[#keys + 1] = name end
	table.sort(keys)
	local lines = {}
	local refusals = Backend.Refusals()
	for _, name in ipairs(keys) do
		local door = doors[name]
		lines[#lines + 1] = ('%s %q %s bucket=%d pos=%.1f,%.1f,%.1f %s %s%s'):format(name, door.name,
			table.concat(door.ids, '+'), door.bucket, door.x, door.y, door.z, door.origin,
			states[name].locked and 'locked' or 'unlocked',
			refusals[name] and (' REFUSED: ' .. refusals[name]) or '')
	end
	for _, row in ipairs(refusedRows) do lines[#lines + 1] = 'database row refused: ' .. row end
	lines[#lines + 1] = ('%d door(s), backend %s'):format(#keys, Backend.Mode())
	OPX.CommandResult(player, true, table.concat(lines, '\n'))
end

--- Registers the staff commands. Each is restricted: the host checks
--- `command.<name>` before the handler runs.
local function registerCommands()
	OPX.Command.Register(Command.OPEN, { restricted = true, help = 'doorlock.help.open' },
		function(source)
			if source <= 0 then return staffReport(source) end
			TriggerClientEvent(M.Event.STAFF_OPEN, source, { access = staffFlags(source) or {},
				mode = Backend.Mode() })
		end)

	OPX.Command.Register(Command.LIST, { restricted = true, help = 'doorlock.help.list',
		params = { { name = 'door', optional = true, help = locale('doorlock.help.door') } } },
		function(source, args) staffReport(source, args[1]) end)

	OPX.Command.Register(Command.REMOVE, { restricted = true, help = 'doorlock.help.remove',
		cooldownMs = 500, params = { { name = 'door', help = locale('doorlock.help.door') } } },
		function(source, args, raw)
			CreateThread(function() staffRemove(source, raw, args[1]) end)
		end)

	OPX.Command.Register(Command.LOCK, { restricted = true, help = 'doorlock.help.lock',
		cooldownMs = 300, params = { { name = 'door', help = locale('doorlock.help.door') },
			{ name = 'on|off', optional = true, help = locale('doorlock.help.state') } } },
		function(source, args, raw)
			local door = doors[Access.Key(args[1]) or '']
			if door == nil then
				return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.unknown_door'))
			end
			local wanted = OPX.Text.Switch(args[2])
			if wanted == nil then wanted = not states[door.key].locked end
			CreateThread(function()
				setLocked(door, wanted, 'staff:' .. tostring(source), source > 0 and source or nil)
				OPX.CommandNotice(source, raw, 'success', locale(wanted and 'doorlock.answer.locked'
					or 'doorlock.answer.unlocked', { door = door.name }), false, 'lock')
			end)
		end)

	OPX.Command.Register(Command.KEY, { restricted = true, help = 'doorlock.help.key',
		cooldownMs = 500, params = { { name = 'door', help = locale('doorlock.help.door') },
			{ name = 'player', optional = true, help = locale('doorlock.help.player') } } },
		function(source, args, raw)
			local door = doors[Access.Key(args[1]) or '']
			if door == nil then
				return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.unknown_door'))
			end
			local target = tonumber(args[2]) or source
			if target == nil or target <= 0 then
				return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.no_player'))
			end
			local api = OPX.Api.Get('inventory')
			if api == nil or type(api.AddItem) ~= 'function' then
				return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.no_inventory'))
			end
			CreateThread(function()
				local given = api.AddItem(target, Access.KeyItem(), 1,
					{ door = door.key, label = OPX.Text.Clean(door.name, 48) })
				if type(given) ~= 'table' or given.ok ~= true then
					return OPX.CommandNotice(source, raw, 'error', locale('doorlock.error.key_refused'))
				end
				OPX.Audit.Log({ event = 'doorlock.key', message = ('%s to %d by %d')
					:format(door.key, target, source), source = source,
					data = { door = door.key, target = target } })
				OPX.CommandNotice(source, raw, 'success', locale('doorlock.staff.keyGiven',
					{ door = door.name }), false, 'key')
			end)
		end)
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Reads the config doors and contributes the table. Never yields.
-- @author dop42
function M.Init()
	local problems
	configDoors, problems = Access.ConfigDoors()
	for _, line in ipairs(problems) do Open77.log.warn('[doorlock] config: ' .. line) end
	dbDoors, states, sentBucket, picking, refusedRows = {}, {}, {}, {}, {}
	rebuild()
	OPX.Schema.Add(M.Storage.SCHEMA)
end

--- Publishes the server half of the doorlock contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('doorlock', 1, {
		--- One door as a reader sees it, without its rules.
		Get = function(key)
			local door = doors[Access.Key(key) or '']
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			return Result.Ok({ key = door.key, name = door.name, bucket = door.bucket,
				ids = door.ids, locked = states[door.key].locked, origin = door.origin })
		end,
		--- Every door key, sorted.
		List = function()
			local keys = {}
			for key in pairs(doors) do keys[#keys + 1] = key end
			table.sort(keys)
			return Result.Ok(keys)
		end,
		--- Moves a door's lock with no player and no rule: the caller decided.
		--- Yields on the networked backend.
		SetLocked = function(key, locked, by)
			local door = doors[Access.Key(key) or '']
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			if type(locked) ~= 'boolean' then return Result.Err('doorlock.badState') end
			setLocked(door, locked, by or 'contract', nil)
			return Result.Ok(locked)
		end,
		--- Whether a player may turn a door, ignoring where they stand. Yields.
		IsAuthorised = function(player, key)
			local door = doors[Access.Key(key) or '']
			if door == nil then return Result.Err('doorlock.unknownDoor') end
			local allowed, how = Access.Evaluate(door, subjectOf(player, door), OPX.Now())
			return Result.Ok({ allowed = allowed, how = how })
		end,
		Mode = function() return Backend.Mode() end,
	})
end

--- Reads the saved doors, adopts every door and wires the doors in.
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

	RegisterNetEvent(M.Event.TOGGLE, function(payload)
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
		local key = type(payload) == 'table' and payload.key or nil
		-- Floored per question: the panel asks for the list and for one door in
		-- the same breath, and one must not swallow the other.
		if OPX.Cooling(player, 'doorlock.staffAsk:' .. (Access.Key(key) or '*'), 250) then return end
		staffList(player, key)
	end)

	RegisterNetEvent(M.Event.STAFF_SAVE, function(payload)
		local player = tonumber(source)
		if player == nil or player <= 0 then return end
		if not permitted(player, Command.SAVE) then
			OPX.Audit.Security('doorlock.staffDenied', 'save', nil, player)
			return TriggerClientEvent(M.Event.STAFF_SAVED, player, { ok = false, code = 'not_permitted' })
		end
		if OPX.Cooling(player, 'doorlock.staffSave', 1000) then
			return TriggerClientEvent(M.Event.STAFF_SAVED, player, { ok = false, code = 'too_fast' })
		end
		CreateThread(function() staffSave(player, payload) end)
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

	-- The autolock: a door unlocked with AUTOLOCK set locks itself again.
	OPX.Scheduler.Every('doorlock:autolock', 500, function()
		-- Collected first: a relock yields on the networked backend, and a save
		-- landing in that yield rebuilds the table this would be walking.
		local now, due = OPX.Now(), {}
		for key, state in pairs(states) do
			if state.relockAt ~= nil and now >= state.relockAt then due[#due + 1] = key end
		end
		for _, key in ipairs(due) do
			local state = states[key]
			if doors[key] ~= nil and state ~= nil and state.relockAt ~= nil then
				setLocked(doors[key], true, 'autolock', nil)
			end
		end
	end)

	CreateThread(function()
		local rows = Store.FetchAll()
		if not rows.ok then
			Open77.log.error('[doorlock] saved doors could not be read: ' .. tostring(rows.detail))
		else
			for _, row in ipairs(type(rows.value) == 'table' and rows.value or {}) do
				local plain = OPX.Storage.Decode(row.data, nil)
				local door, why = nil, 'bad_json'
				if plain ~= nil then
					plain.bucket = plain.bucket or row.bucket
					door, why = Access.Normalize(row.door_key, plain, 'db')
				end
				if door == nil then
					refusedRows[#refusedRows + 1] = ('%s: %s'):format(tostring(row.door_key), why)
					Open77.log.warn(('[doorlock] saved door %s refused: %s'):format(tostring(row.door_key), why))
				else
					dbDoors[door.key] = door
				end
			end
		end
		rebuild()
		local adopted = 0
		for key, door in pairs(doors) do
			if Backend.Adopt(door, states[key].locked) then adopted = adopted + 1 end
		end
		local buckets = {}
		for _, door in pairs(doors) do buckets[door.bucket] = true end
		buckets[0] = true
		syncBuckets(buckets)
		Open77.log.info(('[doorlock] ready: %d door(s) (%d config, %d saved, %d refused), backend %s%s')
			:format(OPX.Table.Count(doors), OPX.Table.Count(configDoors), OPX.Table.Count(dbDoors),
				#refusedRows, mode, mode == 'networked' and (', %d adopted'):format(adopted) or ''))
	end)

	-- The service forgets its owners when it restarts; take them back.
	if mode == 'networked' then
		OPX.Scheduler.Every('doorlock:adopt', 30000, function()
			if not running then return end
			Backend.Sweep(doors, function(key) return states[key] and states[key].locked end)
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
