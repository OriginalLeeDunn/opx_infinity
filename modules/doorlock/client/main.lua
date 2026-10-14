--- Client half: the doors of this bucket, the key, the eye rows and the local lock.
-- @author dop42
--
-- OX'S `client/main.lua` AND `client/utils.lua`, ON THIS CLIENT. ox keeps the
-- doors it was sent, finds the closest one in reach, draws its prompt, turns it
-- on E, asks for a code, picks a lock behind a skill check and plays the door's
-- sound for everyone near it. All of that is here; what changed is who decides.
--
-- EVERYTHING HERE ASKS. The key, the strip row and the eye rows send a door id
-- and the state the player wants; the server decides and answers, and the
-- answer is what is said. The list of doors comes from the server, filtered to
-- this player's bucket, and carries where each door is and what state it is in
-- -- never who may turn it, because that is the server's to know.
--
-- ON THE LOCAL BACKEND THIS FILE IS THE LOCK. Without `open77_doors` a door's
-- state is client-side, so every client puts the streamed managed doors around
-- it into the state the server broadcast: `Open77.doors.setLocked` with the
-- quest-authority flag, `setInteractionAllowed(false)` on a locked one so the
-- game's own interaction cannot open it either, and -- ox's `holdOpen` -- an
-- unlocked hold-open door opened with its self-closing turned off. The scan
-- re-applies a lock the game lifted. On the networked backend the platform
-- projects all of it and this file only draws.
--
-- E IS SHARED, so the key is SILENT away from a managed door -- the garages,
-- the stores, the lifts and the teleports all answer to it too, and each says
-- nothing where it has nothing to do (see `modules/elevators/client/door.lua`).
-- The one exception is the staff panel's "Pick in world" step, which borrows
-- the key to confirm the door under the crosshair (`M.Panel.Picking`).
--
-- THE CLIENT BUDGET. The scan runs on the scheduler, reads one position and,
-- on the local backend, one `near` list; every walk is over a bounded list.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access

M.Runtime = {}
local Runtime = M.Runtime

local OWNER = 'doorlock'
local GROUP = 'door'

-- Metres around a door its sound is played for (ox: `door.distance < 20`).
local SOUND_RANGE = 20.0

-- What the progress module raises when a bar ends.
local PROGRESS_DONE = OPX.Event(OPX.Channel.LOCAL, 'progress', 'done')

-- Door id to the wire record, the chunks still arriving, and native id to door id.
local doors, incoming, byNative = {}, {}, {}

-- THE SWEEP, ox's `nearbyDoors`. ox walks every door every 500 ms and keeps the
-- ones within 20 m for its per-frame loop; a walk over every door of a bucket in
-- one scheduler pass is exactly what the client budget forbids (a bucket may
-- hold 512). So the doors are an array (`order`), the scan measures a SLICE of
-- it per pass, and the ones within `NEAR_RADIUS` are kept in `near` -- the only
-- set the closest-door question ever walks.
local order, near, cursor = {}, {}, 0
local SWEEP_SLICE = 48
local NEAR_RADIUS = 30.0

-- The bucket and backend the server last named, and this player's staff flags.
local bucket, mode, staff = 0, 'local', nil

-- The door the player stands at (ox's ClosestDoor), the row drawn for it, and
-- whether the key mapping answered.
local nearest, shown, keyRegistered = nil, nil, false
-- The distance to `nearest` the last scan measured, for the key's claim.
local nearestDistance = nil

-- Native ids this client put into a state, to the state it put them in.
local applied = {}

-- The pick in progress: { id, steps, at } while its bars run (ox's PickingLock).
local picking = nil

-- The coded request waiting on a form: { id, state }.
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

--- The player's own position, or nil.
-- @author dop42
-- @return number|nil x
-- @return number|nil y
-- @return number|nil z
function Runtime.Position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then return nil end
	if type(z) ~= 'number' or z ~= z then z = nil end
	return x, y, z
end
local position = Runtime.Position

-- The door natives, or nil on a client without them.
local function natives()
	local native = Open77.doors
	if type(native) ~= 'table' or type(native.near) ~= 'function' then return nil end
	return native
end

--- Says one answer as a toast.
-- @author dop42
-- @param ok boolean
-- @param code string
-- @param name string|nil the door's name
function Runtime.Say(ok, code, name)
	local key = (ok and 'doorlock.answer.' or 'doorlock.error.') .. tostring(code)
	if not OPX.Locale.Exists(key) then key = ok and 'doorlock.answer.done' or 'doorlock.error.invalid' end
	local raised = OPX.Toast.Show({
		id = 'opx.doorlock.answer',
		kind = ok and 'success' or OPX.Result.Kind(code, 'error'),
		title = locale('doorlock.title'),
		message = locale(key, { door = name or '' }),
		icon = 'lock',
		durationMs = 4000,
	})
	if raised == nil then Open77.log.info(('[doorlock] %s: %s'):format(tostring(code), tostring(name))) end
end
local say = Runtime.Say

-- Plays a door's sound, or the configured default, when the player is near it.
local function sound(door, state)
	local _, defaults = Access.Sounds()
	local event = state == 1 and (door.lockSound or defaults.lock) or (door.unlockSound or defaults.unlock)
	local sfx = Open77.sfx
	if type(event) ~= 'string' or event == '' or type(sfx) ~= 'table' or type(sfx.play) ~= 'function' then
		return
	end
	local x, y, z = position()
	if x == nil or Access.DistanceSquared(door, x, y, z) > SOUND_RANGE * SOUND_RANGE then return end
	pcall(sfx.play, event, {})
end

-- ── the local lock ──────────────────────────────────────────────────────────

-- Puts one streamed native door into a state. Answers whether it took.
local function applyNative(native, id, door)
	local locked = door.state == 1
	local set = pcall(native.setLocked, id, locked, true)
	if type(native.setInteractionAllowed) == 'function' then
		pcall(native.setInteractionAllowed, id, not locked)
	end
	-- ox's `DoorSystemSetHoldOpen(hash, state == 0)`: open and staying open while
	-- unlocked, closing itself again once locked.
	if door.holdOpen then
		if type(native.setAutomaticClose) == 'function' then pcall(native.setAutomaticClose, id, locked) end
		if not locked and type(native.setOpen) == 'function' then pcall(native.setOpen, id, true, true) end
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
		local doorId = id and byNative[id] or nil
		local door = doorId and doors[doorId] or nil
		if door ~= nil and not entry.lift then
			local locked = door.state == 1
			if applied[id] ~= door.state or entry.locked ~= locked then
				if applyNative(native, entry.id, door) then applied[id] = door.state end
			end
		end
	end
end

-- ── the door the player stands at ───────────────────────────────────────────

-- Measures the next slice of doors and keeps the ones near the player.
local function sweep(x, y, z)
	local count = #order
	if count == 0 then return end
	local limit = NEAR_RADIUS * NEAR_RADIUS
	for _ = 1, math.min(SWEEP_SLICE, count) do
		cursor = cursor % count + 1
		local door = order[cursor]
		if Access.DistanceSquared(door, x, y, z) <= limit then near[door.id] = door else near[door.id] = nil end
	end
end

-- The nearest managed door within its own reach, or nil (ox's ClosestDoor).
local function findNearest()
	local x, y, z = position()
	if x == nil then return nil end
	local best, bestDistance = nil, math.huge
	for _, door in pairs(near) do
		local reach = door.reach or Access.UseRadius()
		local distance = Access.DistanceSquared(door, x, y, z)
		if distance <= reach * reach and distance < bestDistance then
			best, bestDistance = door, distance
		end
	end
	return best, best ~= nil and math.sqrt(bestDistance) or nil
end

-- Brings the strip in line with the door the player stands at: ox's
-- DrawTextUI, on the prompts strip. A door with `hideUi` draws nothing and
-- still answers the key -- ox hides the sprite, not the lock.
local function syncPrompt()
	if M.Panel ~= nil and M.Panel.Picking() then return end
	local door = nil
	-- The claim on the shared key is filed every scan, row or no row.
	local wins = OPX.Spots.Key.Shows(keySettings().ID)
	if keyRegistered and nearest ~= nil and not nearest.hideUi and not captured() and wins then
		door = nearest
	end
	local signature = door and (door.id .. ':' .. door.state) or nil
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
			label = locale(door.state == 1 and 'doorlock.prompt.unlock' or 'doorlock.prompt.lock',
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

--- Forgets the row drawn, so the next scan draws it again.
-- @author dop42
function Runtime.Redraw() shown = nil end

-- One pass: the nearest door, its row, and the local lock.
local function scan()
	local x, y, z = position()
	if x ~= nil then sweep(x, y, z) end
	nearest, nearestDistance = findNearest()
	syncPrompt()
	enforce()
end

--- One scan pass, as the scheduler runs it: for a test that counts its cost.
-- @author dop42
Runtime.Scan = scan

-- ── asking ──────────────────────────────────────────────────────────────────

--- Asks the server to turn one door (ox's `useClosestDoor`).
-- @author dop42
-- @param id integer
-- @param code string|nil a passcode the player typed
-- @return boolean whether the request left
function Runtime.Toggle(id, code)
	local door = doors[id]
	if door == nil then return false end
	local sent = TriggerServerEvent(M.Event.SET_STATE, { id = door.id, state = door.state == 1 and 0 or 1,
		code = code })
	return sent ~= false
end

--- Asks the server to start a pick on one door (ox's `pickLock`).
-- @author dop42
-- @param id integer
-- @return boolean
function Runtime.Pick(id)
	if doors[id] == nil or picking ~= nil then return false end
	local sent = TriggerServerEvent(M.Event.PICK, { id = id })
	return sent ~= false
end

--- What the key does: confirm the panel's pick, turn the door the player
--- stands at, or nothing at all.
-- @author dop42
-- @param origin string|nil
-- @return boolean whether something happened
function Runtime.Use(origin)
	if M.Panel ~= nil and M.Panel.Picking() then return M.Panel.Confirm() end
	-- Mid-pick, E is the pick's: it neither turns this door nor any other.
	if picking ~= nil then return false end
	local door = findNearest()
	-- NOT A WORD AWAY FROM A DOOR. E belongs to six modules, and every one of
	-- them is silent where it has nothing to do.
	if door == nil then return false end
	return Runtime.Toggle(door.id)
end

-- Asks for the code of a coded door, then sends the request again with it
-- (ox's `ox_doorlock:inputPassCode` dialog).
local function askCode(payload)
	local form = OPX.Api.Get('form')
	if form == nil or type(form.Open) ~= 'function' then return say(false, 'passcode_required', payload.name) end
	awaitingCode = { id = payload.id }
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
				Runtime.Toggle(waiting.id, values.code)
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

--- The managed door the eye landed on, or nil (ox's `getDoorFromEntity`).
-- @author dop42
-- @param context table
-- @return table|nil
function Runtime.Targeted(context)
	local native = Runtime.Native(context)
	local id = native and Access.DoorId(native.id) or nil
	local doorId = id and byNative[id] or nil
	return doorId and doors[doorId] or nil
end

-- Whether the local bag holds one of the lockpick items, as the inventory last
-- told this client (ox_target's `items = Config.LockpickItems, anyItem = true`).
local function holdsLockpick()
	local inventory = OPX.Api.Get('inventory')
	if inventory == nil or type(inventory.GetItemCount) ~= 'function' then return false end
	for _, name in ipairs(Access.Lockpick().items) do
		local read, count = pcall(inventory.GetItemCount, name)
		if read and (tonumber(count) or 0) > 0 then return true end
	end
	return false
end

local function registerRows()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterDoors) ~= 'function' then
		OPX.Note('doorlock', 'no target contract: no door rows on the eye; the key still works')
		return
	end
	local registered = target.RegisterDoors(OWNER, {
		-- TWO ROWS THAT SAY WHICH WAY, not one `Lock / unlock` with a tick box.
		-- The key strip already said `Lock {door}` or `Unlock {door}` from the
		-- door's state, while the eye made the player decode a check mark; the
		-- eye now shows the one row that applies. Both send the same flip, which
		-- the server re-checks against the state it holds.
		{
			id = 'doorlock.lock',
			label = locale('doorlock.row.lock'),
			icon = 'lock',
			distance = Access.MaxReach(),
			canInteract = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and door.state ~= 1
			end,
			onSelect = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and Runtime.Toggle(door.id)
			end,
			order = 10,
		},
		{
			id = 'doorlock.unlock',
			label = locale('doorlock.row.unlock'),
			icon = 'lock',
			distance = Access.MaxReach(),
			canInteract = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and door.state == 1
			end,
			onSelect = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and Runtime.Toggle(door.id)
			end,
			order = 10,
		},
		{
			-- ox's `pickDoorlock` global object option.
			id = 'doorlock.pick',
			label = locale('doorlock.row.pick'),
			icon = 'tool',
			distance = Access.MaxReach(),
			canInteract = function(context)
				if picking ~= nil then return false end
				local door = Runtime.Targeted(context)
				return door ~= nil and door.lockpick == true
					and (door.state == 1 or Access.Lockpick().canPickUnlocked) and holdsLockpick()
			end,
			onSelect = function(context)
				local door = Runtime.Targeted(context)
				return door ~= nil and Runtime.Pick(door.id)
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
				if native == nil or M.Panel == nil then return false end
				return M.Panel.Manage(native)
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

-- A finite number, or nil; held as a local because `adopt` runs twenty times
-- per event.
local real = OPX.Math.Finite

-- Takes one wire record, or nil when it is not one.
--
-- CHEAP ON PURPOSE. The record is the server's own `Access.Wire`, already
-- normalised, and this runs for every door of every chunk inside one net
-- event's budget; so a canonical native id is recognised by its shape and only
-- an odd one goes through `Access.DoorId`, and the name is bounded rather than
-- re-cleaned.
local function adopt(record)
	if type(record) ~= 'table' or type(record.ids) ~= 'table' then return nil end
	local id = math.tointeger(record.id)
	if id == nil or id < 1 then return nil end
	local x, y, z = real(record.x), real(record.y), real(record.z)
	if x == nil or y == nil or z == nil then return nil end
	local ids = {}
	for index = 1, math.min(#record.ids, 2) do
		local leaf = record.ids[index]
		if type(leaf) ~= 'string' or #leaf ~= 18 or leaf:find('[^%dA-F]', 3) or leaf:sub(1, 2) ~= '0x' then
			leaf = Access.DoorId(leaf)
		end
		if leaf ~= nil then ids[#ids + 1] = leaf end
	end
	if #ids == 0 then return nil end
	local name = record.name
	if type(name) ~= 'string' or name == '' or #name > Access.MAX_NAME then name = '#' .. id end
	return {
		id = id, name = name, ids = ids,
		coords = { x = x, y = y, z = z }, state = record.state == 0 and 0 or 1,
		reach = real(record.reach) or 2.0,
		hideUi = record.hideUi == true, holdOpen = record.holdOpen == true,
		lockpick = record.lockpick == true, passcode = record.passcode == true,
		lockSound = type(record.lockSound) == 'string' and record.lockSound or nil,
		unlockSound = type(record.unlockSound) == 'string' and record.unlockSound or nil,
	}
end

-- The list being received, built a chunk at a time so that no one net event
-- walks more than the twenty doors it carried: { doors, index, order, near }.
local function fresh()
	return { doors = {}, index = {}, order = {}, near = {} }
end

-- Swaps a received list in, giving back every native door no longer managed.
-- Constant work apart from the release, which walks only the leaves this
-- client itself put into a state -- the streamed doors around it.
local function install(list)
	local native = natives()
	for leaf in pairs(applied) do
		if list.index[leaf] == nil and native ~= nil then releaseNative(native, leaf) end
	end
	doors, byNative, order, near, cursor = list.doors, list.index, list.order, list.near, 0
	nearest, nearestDistance = findNearest()
	shown = nil
end

local function onSync(payload)
	if type(payload) ~= 'table' or type(payload.doors) ~= 'table' then return end
	if payload.offset == 0 or incoming.doors == nil then incoming = fresh() end
	local x, y, z = position()
	local limit = NEAR_RADIUS * NEAR_RADIUS
	for index = 1, math.min(#payload.doors, 24) do
		local door = adopt(payload.doors[index])
		if door ~= nil and incoming.doors[door.id] == nil then
			incoming.doors[door.id] = door
			incoming.order[#incoming.order + 1] = door
			for _, leaf in ipairs(door.ids) do incoming.index[leaf] = door.id end
			if x ~= nil and Access.DistanceSquared(door, x, y, z) <= limit then incoming.near[door.id] = door end
		end
	end
	if payload.done ~= true then return end
	bucket = math.tointeger(payload.bucket) or 0
	local wasMode = mode
	mode = payload.mode == 'networked' and 'networked' or 'local'
	staff = type(payload.staff) == 'table' and payload.staff or nil
	local list = incoming
	incoming = fresh()
	if wasMode == 'local' and mode == 'networked' then
		local native = natives()
		for leaf in pairs(applied) do if native then releaseNative(native, leaf) end end
	end
	install(list)
end

local function onState(payload)
	if type(payload) ~= 'table' or (payload.state ~= 0 and payload.state ~= 1) then return end
	local door = doors[Access.Id(payload.id) or 0]
	if door == nil then return end
	local changed = door.state ~= payload.state
	door.state = payload.state
	-- Applied at once rather than on the next scan, so a door that was just
	-- unlocked opens on the next interaction rather than half a second later.
	local native = natives()
	if mode == 'local' and native ~= nil then
		for _, id in ipairs(door.ids) do
			if applyNative(native, id, door) then applied[id] = door.state end
		end
	end
	-- ox plays the door's sound for everyone within 20 m when its state lands.
	if changed then sound(door, door.state) end
	shown = nil
	if M.Panel ~= nil then M.Panel.StateChanged(door.id, door.state) end
end

local function onAnswer(payload)
	if type(payload) ~= 'table' then return end
	local door = doors[Access.Id(payload.id) or 0]
	if payload.code == 'passcode_required' then return askCode(payload) end
	if payload.ok and (payload.state == 0 or payload.state == 1) and door ~= nil then
		door.state = payload.state
		shown = nil
	end
	-- ox's Config.Notify: the success toast is optional, a refusal never is.
	if payload.ok and settings().NOTIFY == false and (payload.code == 'locked' or payload.code == 'unlocked') then
		return
	end
	say(payload.ok == true, payload.code, payload.name or (door and door.name))
end

-- Runs the next bar of a pick, or tells the server the pick has run.
local function nextStep()
	if picking == nil then return end
	picking.at = picking.at + 1
	if picking.at > #picking.steps then
		local id = picking.id
		picking = nil
		TriggerServerEvent(M.Event.PICKED, { id = id, finished = true })
		return
	end
	local progress = OPX.Api.Get('progress')
	local started = progress and progress.Start(OWNER, {
		label = locale('doorlock.progress.pick', { step = picking.at, steps = #picking.steps }),
		durationMs = picking.steps[picking.at],
		cancelable = true,
	}) or nil
	if type(started) ~= 'table' or not started.ok then
		local id = picking.id
		picking = nil
		TriggerServerEvent(M.Event.PICKED, { id = id, finished = false })
		say(false, 'pick_failed', doors[id] and doors[id].name)
	end
end

local function onPickGo(payload)
	if type(payload) ~= 'table' or doors[Access.Id(payload.id) or 0] == nil or type(payload.steps) ~= 'table' then
		return
	end
	local steps = {}
	for index = 1, math.min(#payload.steps, Access.MAX_STEPS) do
		local duration = math.floor(OPX.Math.Finite(payload.steps[index]) or 0)
		if duration > 0 then steps[#steps + 1] = math.min(duration, 30000) end
	end
	local progress = OPX.Api.Get('progress')
	if #steps == 0 or progress == nil or type(progress.Start) ~= 'function' then
		-- No bar to draw: tell the server the attempt ended without one.
		TriggerServerEvent(M.Event.PICKED, { id = Access.Id(payload.id), finished = false })
		return say(false, 'pick_failed', payload.name)
	end
	picking = { id = Access.Id(payload.id), steps = steps, at = 0 }
	nextStep()
end

local function onProgressDone(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or picking == nil then return end
	if payload.finished ~= true then
		local id = picking.id
		picking = nil
		TriggerServerEvent(M.Event.PICKED, { id = id, finished = false })
		return
	end
	nextStep()
end

-- ── reading it back ─────────────────────────────────────────────────────────

--- What this client holds, for a diagnostic or a test.
-- @author dop42
-- @return table
function Runtime.Report()
	local count = 0
	for _ in pairs(doors) do count = count + 1 end
	return { doors = count, bucket = bucket, mode = mode, nearest = nearest and nearest.id or nil,
		shown = shown, staff = staff, picking = picking and picking.id or nil, applied = applied,
		key = keyRegistered and keySettings().ID or nil }
end

--- One door this client knows, or nil.
-- @author dop42
-- @param id integer
-- @return table|nil
function Runtime.Door(id) return doors[id] end

--- Every door this client knows, by id.
-- @author dop42
-- @return table
function Runtime.Doors() return doors end

--- The door the player stands at, or nil (ox's `getClosestDoor`).
-- @author dop42
-- @return table|nil
function Runtime.Closest() return findNearest() end

--- This client's staff flags, or nil for a player who is not staff.
-- @author dop42
-- @return table|nil
function Runtime.Staff() return staff end

--- The managed door id of a native door id, or nil (ox's `getDoorIdFromEntity`).
-- @author dop42
-- @param id string
-- @return integer|nil
function Runtime.IdOf(id)
	id = Access.DoorId(id)
	return id and byNative[id] or nil
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears the client state.
-- @author dop42
function Runtime.Init()
	doors, incoming, byNative, applied = {}, {}, {}, {}
	order, near, cursor = {}, {}, 0
	bucket, mode, staff = 0, 'local', nil
	nearest, shown, keyRegistered, picking, awaitingCode = nil, nil, false, nil, nil
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

	-- The key, the silent press and the contest on E, the way every spot module
	-- declares it: see `OPX.Spots.Key.Register`. This was the sixth copy of that
	-- registration, and the one that would have stayed out of the contest.
	keyRegistered = OPX.Spots.Key.Register({
		tag = 'doorlock',
		declared = keySettings(),
		onPress = Runtime.Use,
		-- The panel's "Pick in world" step first: the player is aiming a door
		-- for the panel, and E confirms it whatever else is near. Then the door
		-- the player stands at, at the rank of every other spot.
		wants = function(x)
			if M.Panel ~= nil and M.Panel.Picking() then return OPX.Spots.Key.Rank('PICK') end
			-- A lockpick under way: the door being worked on holds E, however near
			-- a garage or a lift stands. The press itself does nothing (`Use`).
			if picking ~= nil then return OPX.Spots.Key.Rank('PICK') end
			-- A press measures now; a row's claim (no position) reads the scan's.
			local door, distance = nearest, nearestDistance
			if x ~= nil then door, distance = findNearest() end
			if door == nil then return nil end
			return OPX.Spots.Key.Rank('SPOT'), distance
		end,
	})

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
	if picking ~= nil then
		local progress = OPX.Api.Get('progress')
		if progress ~= nil and type(progress.Stop) == 'function' then pcall(progress.Stop, OWNER) end
		picking = nil
	end
end
