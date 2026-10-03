--- Client half: the doors of this bucket, the key, the eye rows and the local lock.
-- @author dop42
--
-- EVERYTHING HERE ASKS. The key, the strip row and the eye rows send a door key
-- and the state the player wants; the server decides and answers, and the
-- answer is what is said. The list of doors comes from the server, filtered to
-- this player's bucket, and carries where each door is and what state it is in
-- -- never who may turn it, because that is the server's to know.
--
-- ON THE LOCAL BACKEND THIS FILE IS THE LOCK. Without `open77_doors` a door's
-- state is client-side, so every client puts the streamed managed doors around
-- it into the state the server broadcast: `Open77.doors.setLocked` with the
-- quest-authority flag, and `setInteractionAllowed(false)` on a locked one so
-- the game's own interaction cannot open it either. The scan re-applies a lock
-- the game lifted. On the networked backend the platform projects the lock and
-- this file only draws.
--
-- E IS SHARED, so the key is SILENT away from a managed door -- the garages,
-- the stores, the lifts and the teleports all answer to it too, and each says
-- nothing where it has nothing to do (see `modules/elevators/client/door.lua`).
--
-- THE CLIENT BUDGET. The scan runs on the scheduler, reads one position and,
-- on the local backend, one `near` list; every walk is over a bounded list.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

local OWNER = 'doorlock'
local GROUP = 'door'

-- What the progress module raises when a bar ends.
local PROGRESS_DONE = OPX.Event(OPX.Channel.LOCAL, 'progress', 'done')

-- Door key to the wire record, the chunks still arriving, and native id to key.
local doors, incoming, byNative = {}, {}, {}

-- The bucket and backend the server last named, and this player's staff flags.
local bucket, mode, staff = 0, 'local', nil

-- The door the player stands at, the row drawn for it, and whether the key
-- mapping answered.
local nearest, shown, keyRegistered = nil, nil, false

-- Native ids this client put into a state, to the state it put them in.
local applied = {}

-- The pick in progress: { key } while a bar runs.
local pickingKey = nil

-- The coded request waiting on a form: { key, locked }.
local awaitingCode = nil
local formHandle = nil

-- Scheduler handle, and whether the strip refusal was logged.
local scanJob, reportedStrip = nil, false

local function settings() return M.Settings end

local function keySettings()
	local declared = type(settings().KEY) == 'table' and settings().KEY or nil
	return declared or { ID = 'opx.doorlock.use', NAME = 'doorlock.key.use', DEFAULT = 'E' }
end

-- Whether another surface holds the keyboard.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

-- The player's own position, or nil.
local function position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil end
	if type(z) ~= 'number' or z ~= z then z = nil end
	return x, y, z
end

-- The door natives, or nil on a client without them.
local function natives()
	local native = Open77.doors
	if type(native) ~= 'table' or type(native.near) ~= 'function' then return nil end
	return native
end

--- Says one answer as a toast.
-- @param ok boolean
-- @param code string
-- @param name string|nil the door's name
local function say(ok, code, name)
	local key = (ok and 'doorlock.answer.' or 'doorlock.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'doorlock.answer.done' or 'doorlock.error.invalid' end
	local raised = OPX.Toast.Show({
		id = 'opx.doorlock.answer',
		kind = ok and 'success' or 'error',
		title = locale('doorlock.title'),
		message = locale(key, { door = name or '' }),
		icon = 'lock',
		durationMs = 4000,
	})
	if raised == nil then Open77.log.info(('[doorlock] %s: %s'):format(tostring(code), tostring(name))) end
end

-- Plays a door's sound, or the configured one, on the local player.
local function sound(door, locked)
	local sounds = type(settings().SOUNDS) == 'table' and settings().SOUNDS or {}
	local event = locked and (door and door.lockSound or sounds.LOCK)
		or (door and door.unlockSound or sounds.UNLOCK)
	local sfx = Open77.sfx
	if type(event) ~= 'string' or event == '' or type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then
		return
	end
	pcall(sfx.play, event, {})
end

-- ── the local lock ──────────────────────────────────────────────────────────

-- Puts one streamed native door into a state. Answers whether it took.
local function applyNative(native, id, locked)
	local set = pcall(native.setLocked, id, locked, true)
	if type(native.setInteractionAllowed) == 'function' then
		pcall(native.setInteractionAllowed, id, not locked)
	end
	return set
end

-- Gives one native door back to the game.
local function releaseNative(native, id)
	if type(native.setInteractionAllowed) == 'function' then
		pcall(native.setInteractionAllowed, id, true)
	end
	if type(native.reset) == 'function' then pcall(native.reset, id) end
	applied[id] = nil
end

-- One pass of the local backend: every managed door streamed around the
-- player is put into the state the server broadcast.
local function enforce()
	if mode ~= 'local' then return end
	local native = natives()
	if native == nil then return end
	local radius = OPX.Math.Finite(settings().SCAN_RADIUS) or 40.0
	if radius < 1 then radius = 1 elseif radius > 100 then radius = 100 end
	local read, list = pcall(native.near, radius)
	if not read or type(list) ~= 'table' then return end
	for index = 1, #list do
		local entry = list[index]
		local id = type(entry) == 'table' and Access.DoorId(entry.id) or nil
		local key = id and byNative[id] or nil
		local door = key and doors[key] or nil
		if door ~= nil and not entry.lift then
			if applied[id] ~= door.locked or entry.locked ~= door.locked then
				if applyNative(native, entry.id, door.locked) then applied[id] = door.locked end
			end
		end
	end
end

-- ── the door the player stands at ───────────────────────────────────────────

-- The nearest managed door within its own reach, or nil.
local function findNearest()
	local x, y, z = position()
	if x == nil then return nil end
	local best, bestDistance = nil, math.huge
	for _, door in pairs(doors) do
		local reach = door.reach or Access.UseRadius()
		local distance = Access.DistanceSquared(door, x, y, z)
		if distance <= reach * reach and distance < bestDistance then
			best, bestDistance = door, distance
		end
	end
	return best
end

-- Brings the strip in line with the door the player stands at.
local function syncPrompt()
	local door = nil
	if keyRegistered and nearest ~= nil and not nearest.hideUi and not captured() then door = nearest end
	local signature = door and (door.key .. (door.locked and ':1' or ':0')) or nil
	if signature == shown then return end
	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' or type(api.Hide) ~= 'function' then
		shown = nil
		return
	end
	local ran, answer
	if door ~= nil then
		ran, answer = pcall(api.Show, OWNER, GROUP, { rows = { {
			keys = { action = keySettings().ID },
			label = locale(door.locked and 'doorlock.prompt.unlock' or 'doorlock.prompt.lock',
				{ door = door.name }),
		} } })
	else
		ran, answer = pcall(api.Hide, OWNER, GROUP)
	end
	shown = signature
	if (not ran or type(answer) ~= 'table' or answer.ok ~= true) and not reportedStrip then
		reportedStrip = true
		Open77.log.warn('[doorlock] the strip row was refused: ' ..
			tostring(ran and type(answer) == 'table' and answer.error or answer))
	end
end

-- One pass: the nearest door, its row, and the local lock.
local function scan()
	nearest = findNearest()
	syncPrompt()
	enforce()
end

-- ── asking ──────────────────────────────────────────────────────────────────

--- Asks the server to turn one door.
-- @author dop42
-- @param key string
-- @param code string|nil a passcode the player typed
-- @return boolean whether the request left
function Runtime.Toggle(key, code)
	local door = doors[key]
	if door == nil then return false end
	local sent = TriggerServerEvent(M.Event.TOGGLE, { key = door.key, locked = not door.locked,
		code = code })
	return sent ~= false
end

--- Asks the server to start a pick on one door.
-- @author dop42
-- @param key string
-- @return boolean
function Runtime.Pick(key)
	if doors[key] == nil or pickingKey ~= nil then return false end
	local sent = TriggerServerEvent(M.Event.PICK, { key = key })
	return sent ~= false
end

--- What the key does: turn the door the player stands at, or nothing at all.
-- @author dop42
-- @param origin string|nil
-- @return boolean whether a request left
function Runtime.Use(origin)
	local door = findNearest()
	-- NOT A WORD AWAY FROM A DOOR. E belongs to five modules, and every one of
	-- them is silent where it has nothing to do.
	-- A door with HIDE_UI draws no row and still answers the key: ox hides the
	-- sprite, not the lock, and a hidden door is one somebody already knows.
	if door == nil then return false end
	return Runtime.Toggle(door.key)
end

-- Asks for the code of a coded door, then sends the request again with it.
local function askCode(payload)
	local form = OPX.Api.Get('form')
	if form == nil or type(form.Open) ~= 'function' then return say(false, 'passcode_required', payload.name) end
	awaitingCode = { key = payload.key }
	local opened = form.Open({
		owner = OWNER,
		id = 'doorlock.passcode',
		title = locale('doorlock.form.passcode'),
		description = payload.name,
		fields = { { id = 'code', label = locale('doorlock.field.passcode'),
			maxLength = Access.MAX_PASSCODE, required = true } },
		on = function(answer)
			formHandle = nil
			local waiting = awaitingCode
			awaitingCode = nil
			if type(answer) ~= 'table' or answer.action ~= 'submit' or waiting == nil then return end
			local values = type(answer.values) == 'table' and answer.values or {}
			if type(values.code) == 'string' and values.code ~= '' then
				Runtime.Toggle(waiting.key, values.code)
			end
		end,
	})
	if type(opened) == 'table' and opened.ok and type(opened.value) == 'table' then
		formHandle = opened.value.handle
	else
		awaitingCode = nil
		say(false, 'passcode_required', payload.name)
	end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

--- The live snapshot of the door the eye landed on, or nil.
-- @author dop42
-- @param context table
-- @return table|nil
function Runtime.Native(context)
	local target = type(context) == 'table' and context.target or nil
	local entity = type(target) == 'table' and target.engineEntity or nil
	local native = Open77.doors
	if type(entity) ~= 'string' or type(native) ~= 'table' or type(native.state) ~= 'function' then
		return nil
	end
	local read, door = pcall(native.state, entity)
	if not read or type(door) ~= 'table' or type(door.id) ~= 'string' then return nil end
	return door
end

--- The managed door the eye landed on, or nil.
-- @author dop42
-- @param context table
-- @return table|nil
function Runtime.Targeted(context)
	local native = Runtime.Native(context)
	local id = native and Access.DoorId(native.id) or nil
	local key = id and byNative[id] or nil
	return key and doors[key] or nil
end

-- Whether the local bag holds an item, as the inventory last told this client.
local function holds(item)
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return false end
	local read, count = pcall(inventory.GetItemCount, item)
	return read and (tonumber(count) or 0) > 0
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterDoors) ~= 'function' then
		OPX.Note('doorlock', 'no target contract: no door rows on the eye; the key still works')
		return
	end
	local registered = target.RegisterDoors(OWNER, {
		{
			id = 'doorlock.toggle',
			label = locale('doorlock.row.toggle'),
			icon = 'lock',
			distance = Access.MaxReach(),
			canInteract = function(context) return Runtime.Targeted(context) ~= nil end,
			checked = function(context)
				local door = Runtime.Targeted(context)
				if door == nil then return nil end
				return door.locked
			end,
			onSelect = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and Runtime.Toggle(door.key)
			end,
			order = 10,
		},
		{
			id = 'doorlock.pick',
			label = locale('doorlock.row.pick'),
			icon = 'tool',
			distance = Access.MaxReach(),
			canInteract = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and door.lockpick == true and door.locked
					and holds(Access.Lockpick().item)
			end,
			onSelect = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and Runtime.Pick(door.key)
			end,
			order = 11,
		},
		{
			id = 'doorlock.manage',
			label = locale('doorlock.row.manage'),
			icon = 'gear',
			distance = 12.0,
			canInteract = function(context)
				if staff == nil then return false end
				local native = Runtime.Native(context)
				return native ~= nil and not native.lift
			end,
			onSelect = function(context)
				local native = Runtime.Native(context)
				if native == nil or M.Staff == nil then return false end
				return M.Staff.Manage(native)
			end,
			order = 12,
		},
	})
	if type(registered) ~= 'table' or not registered.ok then
		OPX.Note('doorlock', ('the door rows were refused: %s')
			:format(tostring(type(registered) == 'table' and registered.error or registered)))
	end
end

-- ── the wire ────────────────────────────────────────────────────────────────

-- Takes one wire record, or nil when it is not one.
local function adopt(record)
	if type(record) ~= 'table' or Access.Key(record.key) == nil or type(record.ids) ~= 'table' then
		return nil
	end
	local x, y, z = OPX.Math.Finite(record.x), OPX.Math.Finite(record.y), OPX.Math.Finite(record.z)
	if x == nil or y == nil or z == nil then return nil end
	local ids = {}
	for index = 1, math.min(#record.ids, 2) do
		local id = Access.DoorId(record.ids[index])
		if id ~= nil then ids[#ids + 1] = id end
	end
	if #ids == 0 then return nil end
	return {
		key = record.key, name = OPX.Text.Clean(record.name, Access.MAX_NAME) or record.key, ids = ids,
		x = x, y = y, z = z, locked = record.locked == true,
		reach = OPX.Math.Finite(record.reach) or Access.UseRadius(),
		hideUi = record.hideUi == true, lockpick = record.lockpick == true,
		passcode = record.passcode == true,
		lockSound = type(record.lockSound) == 'string' and record.lockSound or nil,
		unlockSound = type(record.unlockSound) == 'string' and record.unlockSound or nil,
	}
end

-- Swaps the whole list in, giving back every native door no longer managed.
local function install(list)
	local native = natives()
	local index = {}
	for key, door in pairs(list) do
		for _, id in ipairs(door.ids) do index[id] = key end
	end
	for id in pairs(applied) do
		if index[id] == nil and native ~= nil then releaseNative(native, id) end
	end
	doors, byNative = list, index
	nearest = findNearest()
end

local function onSync(payload)
	if type(payload) ~= 'table' or type(payload.doors) ~= 'table' then return end
	if payload.offset == 0 then incoming = {} end
	for _, record in ipairs(payload.doors) do
		local door = adopt(record)
		if door ~= nil then incoming[door.key] = door end
	end
	if payload.done ~= true then return end
	bucket = math.tointeger(payload.bucket) or 0
	local wasMode = mode
	mode = payload.mode == 'networked' and 'networked' or 'local'
	staff = type(payload.staff) == 'table' and payload.staff or nil
	local list = incoming
	incoming = {}
	if wasMode == 'local' and mode == 'networked' then
		local native = natives()
		for id in pairs(applied) do if native then releaseNative(native, id) end end
	end
	install(list)
end

local function onState(payload)
	if type(payload) ~= 'table' or type(payload.locked) ~= 'boolean' then return end
	local door = doors[payload.key]
	if door == nil then return end
	door.locked = payload.locked
	-- Applied at once rather than on the next scan, so a door that was just
	-- unlocked opens on the next interaction rather than half a second later.
	local native = natives()
	if mode == 'local' and native ~= nil then
		for _, id in ipairs(door.ids) do
			if applyNative(native, id, door.locked) then applied[id] = door.locked end
		end
	end
	shown = nil
end

local function onAnswer(payload)
	if type(payload) ~= 'table' then return end
	local door = payload.key and doors[payload.key] or nil
	if payload.code == 'passcode_required' then return askCode(payload) end
	if payload.ok and type(payload.locked) == 'boolean' then
		if door ~= nil then door.locked = payload.locked end
		if payload.code == 'locked' or payload.code == 'unlocked' or payload.code == 'picked' then
			sound(door, payload.locked)
		end
	end
	say(payload.ok == true, payload.code, payload.name or (door and door.name))
end

local function onPickGo(payload)
	if type(payload) ~= 'table' or doors[payload.key] == nil then return end
	local progress = OPX.Api.Get('progress')
	if progress == nil or type(progress.Start) ~= 'function' then
		-- No bar to draw: tell the server the attempt ended without one.
		TriggerServerEvent(M.Event.PICKED, { key = payload.key, finished = false })
		return say(false, 'pick_failed', payload.name)
	end
	local started = progress.Start(OWNER, {
		label = locale('doorlock.progress.pick'),
		durationMs = math.floor(OPX.Math.Finite(payload.durationMs) or 6000),
		cancelable = true,
	})
	if type(started) ~= 'table' or not started.ok then
		TriggerServerEvent(M.Event.PICKED, { key = payload.key, finished = false })
		return say(false, 'pick_failed', payload.name)
	end
	pickingKey = payload.key
end

local function onProgressDone(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or pickingKey == nil then return end
	local key = pickingKey
	pickingKey = nil
	TriggerServerEvent(M.Event.PICKED, { key = key, finished = payload.finished == true })
end

-- ── reading it back ─────────────────────────────────────────────────────────

--- What this client holds, for a diagnostic or a test.
-- @author dop42
-- @return table
function Runtime.Report()
	local count = 0
	for _ in pairs(doors) do count = count + 1 end
	return { doors = count, bucket = bucket, mode = mode, nearest = nearest and nearest.key or nil,
		shown = shown, staff = staff, picking = pickingKey, applied = applied,
		key = keyRegistered and keySettings().ID or nil }
end

--- One door this client knows, or nil.
-- @author dop42
-- @param key string
-- @return table|nil
function Runtime.Door(key) return doors[key] end

--- Every door this client knows, by key.
-- @author dop42
-- @return table
function Runtime.Doors() return doors end

--- This client's staff flags, or nil for a player who is not staff.
-- @author dop42
-- @return table|nil
function Runtime.Staff() return staff end

--- The managed key of a native door id, or nil.
-- @author dop42
-- @param id string
-- @return string|nil
function Runtime.KeyOf(id)
	id = Access.DoorId(id)
	return id and byNative[id] or nil
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears the client state.
-- @author dop42
function Runtime.Init()
	doors, incoming, byNative, applied = {}, {}, {}, {}
	bucket, mode, staff = 0, 'local', nil
	nearest, shown, keyRegistered, pickingKey, awaitingCode = nil, nil, false, nil, nil
	scanJob, reportedStrip = nil, false
end

--- Declares the key, registers the eye rows and asks for the doors.
-- @author dop42
function Runtime.Start()
	RegisterNetEvent(M.Event.SYNC, onSync)
	RegisterNetEvent(M.Event.STATE, onState)
	RegisterNetEvent(M.Event.ANSWER, onAnswer)
	RegisterNetEvent(M.Event.PICK_GO, onPickGo)
	AddEventHandler(PROGRESS_DONE, onProgressDone)

	local declared = keySettings()
	if declared.DEFAULT ~= false then
		local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
			declared.DEFAULT, function()
				if captured() then return end
				local ran, failure = pcall(Runtime.Use, 'key')
				if not ran then
					Open77.log.error(('[doorlock] key %s: %s'):format(declared.ID, tostring(failure)))
				end
			end)
		local effective = called and (
			(type(ok) == 'string' and ok ~= '' and ok) or
			(ok == true and type(answer) == 'string' and answer ~= '' and answer)) or nil
		if not called or (ok ~= true and not effective) then
			Open77.log.warn(('[doorlock] key mapping %s (%s) not registered: %s')
				:format(declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		else
			keyRegistered = true
		end
	end

	registerRows()

	local every = math.floor(OPX.Math.Finite(settings().SCAN_MS) or 500)
	if every < 100 then every = 100 end
	scanJob = OPX.Scheduler.Every('doorlock:scan', every, scan)
	TriggerServerEvent(M.Event.ASK)
end

--- Cancels the scan, hands the strip back and gives every door back to the game.
-- @author dop42
function Runtime.Shutdown()
	if scanJob ~= nil then OPX.Scheduler.Cancel(scanJob) end
	scanJob = nil
	local api = OPX.Api.Get('prompts')
	if shown ~= nil and api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, GROUP) end
	shown = nil
	local native = natives()
	if native ~= nil then
		for id in pairs(applied) do releaseNative(native, id) end
	end
	applied = {}
	if formHandle ~= nil then
		local form = OPX.Api.Get('form')
		if form ~= nil and type(form.Close) == 'function' then pcall(form.Close, formHandle) end
		formHandle = nil
	end
	if pickingKey ~= nil then
		local progress = OPX.Api.Get('progress')
		if progress ~= nil and type(progress.Stop) == 'function' then pcall(progress.Stop, OWNER) end
		pickingKey = nil
	end
end
