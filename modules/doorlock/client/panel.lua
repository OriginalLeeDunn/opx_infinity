--- The staff panel: ox_doorlock's web UI, as a Vue view of its own.
-- @author dop42
--
-- OX'S PANEL, SCREEN FOR SCREEN. ox opens a NUI page on `/doorlock`: a table of
-- every door (id, name, zone) with a search box, pages of eight and a menu per
-- row (settings, copy settings, teleport, delete), a + that starts a new door,
-- and a settings form with tabs -- General (name, passcode, autolock, interact
-- distance, door rate and six switches: locked, double, automatic, lockpick,
-- hide UI, hold open), Characters, Groups, Items (name, metadata, remove on
-- use), Lockpick (a difficulty per row) and Sound. Its "Confirm door" on a new
-- door hides the page and asks for the door itself in the world: aim, click,
-- and a second click for a double door. `ui/src/modules/doorlock` draws all of
-- it on the design system; this file is its Lua half.
--
-- THE PAGE SENDS INTENTS, AND NOTHING HERE DECIDES. Every write the page asks
-- for leaves as a net event the server gates on its own ACL entry
-- (`command.opx.doorlock.save`, `.remove`, `.lock`, `.key`), re-validates field
-- by field, floors per player and audits. Teleport is the staff module's own
-- `opx.admin.player.tp`, checked and audited there. A button this player's ACL
-- would refuse is drawn greyed, never hidden, so a missing grant reads as one.
--
-- THE CHANNEL CONTRACT (`opx:doorlock:*`, every payload carrying the handle of
-- the panel it belongs to; a payload for another handle is dropped):
--
--   Lua -> page   open     { handle, access, sounds, difficulties, defaults,
--                            mode, view = 'list'|'edit'|'create', edit?, draft? }
--                 rows     { handle, rows, offset, total, done }
--                 detail   { handle, door }
--                 patch    { handle, id, state }
--                 picked   { handle, doors?, coords?, cancelled? }
--                 result   { handle, verb, ok, code, id? }
--                 visible  { handle, visible }
--                 close    { handle }
--   page -> Lua   list, detail { id }, save { id?, door }, delete { id },
--                 teleport { id }, state { id, state }, key { id },
--                 pick { double, id? }, dismiss
--
-- "PICK IN WORLD" is ox's targeting step on Open77's own crosshair read: the
-- page hides (it stays mounted and keeps the draft), the strip says which key
-- confirms and which cancels, `Open77.doors.aimed()` names the door under the
-- crosshair, the doorlock key (E) takes it -- twice for a double door -- and
-- Escape gives up. The page comes back with what was taken.
--
-- THE CLIENT BUDGET. The list a page draws is built on a thread of its own and
-- every loop over doors calls `breathe()`, which yields every few rows there and
-- nowhere else -- the lesson `modules/admin/client/menu.lua` paid for. Every
-- page callback only records what it was asked and returns.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access
local Runtime = M.Runtime

M.Panel = {}
local Panel = M.Panel

local SURFACE = 'interactive'
local OWNER = 'doorlock'
local PICK_GROUP = 'pick'

-- Rows per `rows` send: seven value nodes each, well inside the host's 1,024.
Panel.ROWS_PER_SEND = 40

-- Rows built between two yields.
local BREATHE_EVERY = 25

-- How long a pick waits for a door before it gives up, and how often it reads
-- the crosshair.
local PICK_TIMEOUT_MS = 120000
local PICK_EVERY_MS = 150

-- What the page is asked to do with focus while it is up.
local FOCUS = { keyboard = true, cursor = true }

-- The open panel, or nil: { handle, access, mode, pendingOpen, shown }.
local record = nil
local nextHandle = 0

-- The staff list the server sent: summary rows by position, the chunks still
-- arriving, and the build thread's generation.
local summary, incoming, buildGeneration = {}, {}, 0

-- The pick in progress: { need, taken = { {native, coords} }, id, job, at, aimed }.
local pick = nil

-- Whether the page channels are wired.
local wired = false

-- ── the budget ──────────────────────────────────────────────────────────────

local breaths, onBuildThread = 0, false

--- Yields every few rows, on the build thread only.
local function breathe()
	breaths = breaths + 1
	if breaths % BREATHE_EVERY ~= 0 then return end
	if onBuildThread and type(Wait) == 'function' then Wait(0) end
end

-- ── sending ─────────────────────────────────────────────────────────────────

local function send(channel, payload)
	if record == nil then return false end
	payload.handle = record.handle
	local sent = OPX.UI.Send(SURFACE, 'doorlock:' .. channel, payload)
	return sent == true
end

local function toast(ok, key, params)
	OPX.Toast.Show({ id = 'opx.doorlock.staff', kind = ok and 'success' or 'error',
		title = locale('doorlock.staff.title'), message = locale(key, params), icon = 'lock',
		durationMs = 4000 })
end

local function finite(value)
	return OPX.Math.Finite(value)
end

-- ── the list ────────────────────────────────────────────────────────────────

--- One page row from a summary row: what ox's table shows, plus the distance
--- ox reads off `door.distance` -- measured here, from the player.
-- @author dop42
-- @param row table the server's summary
-- @param x number|nil the player's position
-- @param y number|nil
-- @param z number|nil
-- @param here integer the bucket this client is in
-- @return table
function Panel.Row(row, x, y, z, here)
	local distance = -1
	if x ~= nil and row.bucket == here then
		distance = math.floor(math.sqrt(Access.DistanceSquared(row, x, y, z)) * 10 + 0.5) / 10
	end
	return { id = row.id, name = row.name, state = row.state, distance = distance,
		double = row.double == true, seeded = row.seeded == true }
end

--- Builds every page row and sends them in parts. Yields on its own thread.
local function build(generation)
	local x, y, z = Runtime.Position()
	local here = Runtime.Report().bucket
	local rows = {}
	for index = 1, #summary do
		breathe()
		rows[index] = Panel.Row(summary[index], x, y, z, here)
	end
	local total = #rows
	local offset = 0
	repeat
		if record == nil or generation ~= buildGeneration then return end
		local part = {}
		for index = offset + 1, math.min(offset + Panel.ROWS_PER_SEND, total) do
			breathe()
			part[#part + 1] = rows[index]
		end
		send('rows', { rows = part, offset = offset, total = total, done = offset + #part >= total })
		offset = offset + #part
		if offset < total and type(Wait) == 'function' and onBuildThread then Wait(0) end
	until offset >= total
end

--- Starts a build of the page rows, replacing any still running.
local function rebuild()
	buildGeneration = buildGeneration + 1
	local generation = buildGeneration
	local function run()
		onBuildThread = true
		local ok, failure = pcall(build, generation)
		onBuildThread = false
		if not ok then Open77.log.error('[doorlock] panel rows: ' .. tostring(failure)) end
	end
	if type(CreateThread) == 'function' then CreateThread(run) else run() end
end

local function ask(id)
	TriggerServerEvent(M.Event.STAFF_ASK, { id = id })
end

-- ── opening and closing ─────────────────────────────────────────────────────

--- Sends the open, or keeps it pending until the surface takes it.
local function flushOpen()
	if record == nil or not record.pendingOpen then return end
	local list, defaults = Access.Sounds()
	local pickSettings = Access.Lockpick()
	local opened = send('open', {
		access = record.access, mode = record.mode, view = record.view, edit = record.edit,
		draft = record.draft, sounds = list, difficulties = Access.Difficulties(),
		defaults = {
			maxDistance = Access.UseRadius(), maxReach = Access.MaxReach(),
			autolockMax = Access.MAX_AUTOLOCK, nameMax = Access.MAX_NAME,
			passcodeMax = Access.MAX_PASSCODE, steps = pickSettings.default,
			stepsMax = Access.MAX_STEPS, lockSound = defaults.lock or '', unlockSound = defaults.unlock or '',
			groupsMax = Access.MAX_GROUPS, itemsMax = Access.MAX_ITEMS, charactersMax = Access.MAX_CHARACTERS,
		},
	})
	if opened then
		record.pendingOpen = false
		record.shown = true
		OPX.UI.AcquireFocus(OWNER, FOCUS)
	end
end

local wire

--- Opens the panel.
-- @author dop42
-- @param access table what the server says this player may do
-- @param options table|nil { view, edit = id, draft = table }
-- @return boolean
function Panel.Open(access, options)
	options = type(options) == 'table' and options or {}
	if OPX.UI.Interactive() == nil then
		toast(false, 'doorlock.staff.noSurface')
		return false
	end
	wire()
	if pick ~= nil then Panel.CancelPick(true) end
	nextHandle = nextHandle + 1
	record = {
		handle = nextHandle,
		openedAtMs = OPX.Now(),
		access = type(access) == 'table' and access or {},
		mode = Runtime.Report().mode,
		view = options.view or 'list',
		edit = Access.Id(options.edit),
		draft = options.draft,
		pendingOpen = true,
		shown = false,
	}
	summary, incoming = {}, {}
	flushOpen()
	ask(nil)
	if record.edit ~= nil then ask(record.edit) end
	return true
end

--- Hides the page without forgetting it (the pick step), or shows it again.
local function setVisible(visible)
	if record == nil then return end
	record.shown = visible
	send('visible', { visible = visible })
	if visible then OPX.UI.AcquireFocus(OWNER, FOCUS) else OPX.UI.ReleaseFocus(OWNER) end
end

--- Closes the panel and hands the cursor back.
-- @author dop42
function Panel.Close()
	if pick ~= nil then Panel.CancelPick(true) end
	if record ~= nil then send('close', {}) end
	record = nil
	buildGeneration = buildGeneration + 1
	OPX.UI.ReleaseFocus(OWNER)
end

--- Whether the panel is open, and on which handle.
-- @author dop42
-- @return table
function Panel.Report()
	return { open = record ~= nil, handle = record and record.handle or nil,
		shown = record ~= nil and record.shown or false, picking = pick ~= nil,
		taken = pick and #pick.taken or 0, rows = #summary }
end

--- The eye's "Manage door": the door's settings when it is managed, ox's new
--- door form with that leaf already taken when it is not.
-- @author dop42
-- @param native table the live snapshot `Open77.doors.state` gave
-- @return boolean
function Panel.Manage(native)
	local access = Runtime.Staff()
	if access == nil or type(native) ~= 'table' then return false end
	local managed = Runtime.IdOf(native.id)
	if managed ~= nil then return Panel.Open(access, { view = 'edit', edit = managed }) end
	local id = Access.DoorId(native.id)
	local at = type(native.position) == 'table' and native.position or native
	local x, y, z = finite(at.x), finite(at.y), finite(at.z)
	if id == nil or x == nil or y == nil or z == nil then return false end
	local coords = { x = x, y = y, z = z }
	return Panel.Open(access, { view = 'create',
		draft = { doors = { { native = id, coords = coords } }, coords = coords } })
end

--- A door's state changed while the panel is up: one row to repaint.
-- @author dop42
-- @param id integer
-- @param state integer
function Panel.StateChanged(id, state)
	if record == nil then return end
	for _, row in ipairs(summary) do
		if row.id == id then row.state = state end
	end
	send('patch', { id = id, state = state })
end

-- ── picking a door in the world ─────────────────────────────────────────────

local function keyId()
	local key = type(M.Settings.KEY) == 'table' and M.Settings.KEY.ID or nil
	return type(key) == 'string' and key or 'opx.doorlock.use'
end

local function hideStrip()
	local api = OPX.Api.Get('prompts')
	if api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, PICK_GROUP) end
end

local function drawStrip()
	if pick == nil then return end
	local api = OPX.Api.Get('prompts')
	if api == nil or type(api.Show) ~= 'function' then return end
	local label = pick.aimed and locale('doorlock.pick.take', { n = #pick.taken + 1, of = pick.need,
		door = pick.aimed:sub(-6) }) or locale('doorlock.pick.aim', { n = #pick.taken + 1, of = pick.need })
	pcall(api.Show, OWNER, PICK_GROUP, { rows = {
		{ keys = { action = keyId() }, label = label, dim = pick.aimed == nil },
		{ keys = 'ESC', label = locale('doorlock.pick.cancel') },
	} })
end

-- The door under the crosshair, or nil.
local function aimed()
	local native = Open77.doors
	if type(native) ~= 'table' or type(native.aimed) ~= 'function' then return nil end
	local read, door = pcall(native.aimed)
	if not read or type(door) ~= 'table' or Access.DoorId(door.id) == nil then return nil end
	return door
end

local function endPick(payload)
	if pick ~= nil and pick.job ~= nil then OPX.Scheduler.Cancel(pick.job) end
	pick = nil
	hideStrip()
	Runtime.Redraw()
	if record ~= nil then
		send('picked', payload)
		setVisible(true)
	end
end

--- Whether the pick step holds the key.
-- @author dop42
-- @return boolean
function Panel.Picking() return pick ~= nil end

--- Gives the pick up.
-- @author dop42
-- @param silent boolean|nil true when the panel itself is going away
function Panel.CancelPick(silent)
	if pick == nil then return end
	if silent then
		if pick.job ~= nil then OPX.Scheduler.Cancel(pick.job) end
		pick = nil
		hideStrip()
		return
	end
	endPick({ cancelled = true })
end

--- Takes the door under the crosshair: ox's left click in `createDoor`.
-- @author dop42
-- @return boolean whether a leaf was taken
function Panel.Confirm()
	if pick == nil then return false end
	local door = aimed()
	if door == nil then
		toast(false, 'doorlock.staff.noDoor')
		return false
	end
	if door.lift then
		toast(false, 'doorlock.error.lift_door')
		return false
	end
	local native = Access.DoorId(door.id)
	-- ox's `entityIsNotDoor`: a leaf another door already manages is not taken.
	local holder = Runtime.IdOf(native)
	if holder ~= nil and holder ~= pick.id then
		toast(false, 'doorlock.error.door_taken', { detail = '#' .. holder })
		return false
	end
	if pick.taken[1] ~= nil and pick.taken[1].native == native then
		toast(false, 'doorlock.error.duplicate_door_id')
		return false
	end
	local at = type(door.position) == 'table' and door.position or nil
	local x, y, z = at and finite(at.x), at and finite(at.y), at and finite(at.z)
	if x == nil or y == nil or z == nil then
		x, y, z = Runtime.Position()
		if x == nil or z == nil then
			toast(false, 'doorlock.error.no_position')
			return false
		end
	end
	pick.taken[#pick.taken + 1] = { native = native, coords = { x = x, y = y, z = z } }
	if #pick.taken < pick.need then
		pick.aimed = nil
		drawStrip()
		return true
	end
	local coords = pick.taken[1].coords
	if pick.need == 2 then
		local a, b = pick.taken[1].coords, pick.taken[2].coords
		coords = { x = (a.x + b.x) / 2, y = (a.y + b.y) / 2, z = (a.z + b.z) / 2 }
	end
	endPick({ doors = pick.taken, coords = coords })
	return true
end

--- Starts the pick step.
local function startPick(double, id)
	if record == nil then return end
	pick = { need = double and 2 or 1, taken = {}, id = id, at = OPX.Now(), aimed = nil }
	-- The door row the player may be standing at says E turns that door; for the
	-- length of the pick E takes a door instead, so the row comes down and the
	-- runtime does not post it again until the pick ends.
	local api = OPX.Api.Get('prompts')
	if api ~= nil and type(api.Hide) == 'function' then pcall(api.Hide, OWNER, 'door') end
	Runtime.Redraw()
	setVisible(false)
	drawStrip()
	pick.job = OPX.Scheduler.Every('doorlock:pick', PICK_EVERY_MS, function()
		if pick == nil then return end
		if OPX.Now() - pick.at > PICK_TIMEOUT_MS then return endPick({ cancelled = true }) end
		local door = aimed()
		local native = door and Access.DoorId(door.id) or nil
		if native ~= pick.aimed then
			pick.aimed = native
			drawStrip()
		end
	end)
end

-- ── the page's intents ──────────────────────────────────────────────────────

-- Whether a payload is for the open panel.
local function mine(payload)
	return record ~= nil and type(payload) == 'table' and payload.handle == record.handle
end

-- A row of the list by id.
local function summaryOf(id)
	for _, row in ipairs(summary) do
		if row.id == id then return row end
	end
	return nil
end

local function execute(tokens)
	local clean = {}
	for _, token in ipairs(tokens) do clean[#clean + 1] = tostring(token) end
	return TriggerServerEvent('open77:command:execute', table.unpack(clean)) ~= false
end

local function onList(payload)
	if not mine(payload) then return end
	ask(nil)
end

local function onDetail(payload)
	if not mine(payload) then return end
	local id = Access.Id(payload.id)
	if id ~= nil then ask(id) end
end

local function onSave(payload)
	if not mine(payload) or type(payload.door) ~= 'table' then return end
	if record.access.save ~= true then
		return send('result', { verb = 'save', ok = false, code = 'not_permitted' })
	end
	local id = payload.id ~= nil and Access.Id(payload.id) or nil
	TriggerServerEvent(M.Event.STAFF_SAVE, { id = id, door = payload.door })
end

local function onDelete(payload)
	if not mine(payload) then return end
	local id = Access.Id(payload.id)
	if id ~= nil then TriggerServerEvent(M.Event.STAFF_REMOVE, { id = id }) end
end

local function onState(payload)
	if not mine(payload) then return end
	local id = Access.Id(payload.id)
	if id == nil then return end
	TriggerServerEvent(M.Event.STAFF_STATE, { id = id,
		state = (payload.state == 0 or payload.state == 1) and payload.state or nil })
end

local function onKey(payload)
	if not mine(payload) then return end
	local id = Access.Id(payload.id)
	if id ~= nil then TriggerServerEvent(M.Event.STAFF_KEY, { id = id }) end
end

local function onTeleport(payload)
	if not mine(payload) then return end
	local row = summaryOf(Access.Id(payload.id) or 0)
	if row == nil then return end
	-- ox closes its page and teleports: so does this.
	Panel.Close()
	execute({ M.TELEPORT, 'me', ('%.2f'):format(row.x), ('%.2f'):format(row.y), ('%.2f'):format(row.z + 0.5) })
end

local function onPick(payload)
	if not mine(payload) or pick ~= nil then return end
	startPick(payload.double == true, Access.Id(payload.id))
end

local function onDismiss(payload)
	if payload ~= nil and payload.handle ~= nil and not mine(payload) then return end
	Panel.Close()
end

-- The surface-wide focus broadcast, read the way `modules/panel` reads it: an
-- announced top that is not ours releases ours, and ours re-acquires.
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	local held = (payload.focus == true and payload.owner == OWNER)
	if held then OPX.UI.AcquireFocus(OWNER, FOCUS) else OPX.UI.ReleaseFocus(OWNER) end
end

wire = function()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'doorlock:list', onList)
	OPX.UI.On(SURFACE, 'doorlock:detail', onDetail)
	OPX.UI.On(SURFACE, 'doorlock:save', onSave)
	OPX.UI.On(SURFACE, 'doorlock:delete', onDelete)
	OPX.UI.On(SURFACE, 'doorlock:state', onState)
	OPX.UI.On(SURFACE, 'doorlock:key', onKey)
	OPX.UI.On(SURFACE, 'doorlock:teleport', onTeleport)
	OPX.UI.On(SURFACE, 'doorlock:pick', onPick)
	OPX.UI.On(SURFACE, 'doorlock:dismiss', onDismiss)
	OPX.UI.On(SURFACE, 'focus:set', onFocus)
end

-- ── the server's answers ────────────────────────────────────────────────────

local function onStaffOpen(payload)
	if type(payload) ~= 'table' then return end
	local access = type(payload.access) == 'table' and payload.access or {}
	-- ox's `/doorlock closest`: straight to the closest door's settings.
	local closest = payload.closest == true and Runtime.Closest() or nil
	if closest ~= nil then
		Panel.Open(access, { view = 'edit', edit = closest.id })
	else
		Panel.Open(access, { view = 'list' })
	end
end

local function onStaffList(payload)
	if record == nil or type(payload) ~= 'table' then return end
	if payload.detail ~= nil then
		if type(payload.detail) == 'table' then
			send('detail', { door = payload.detail })
		else
			send('result', { verb = 'detail', ok = false, code = 'unknown_door', id = Access.Id(payload.id) })
		end
		return
	end
	if type(payload.rows) ~= 'table' then return end
	if payload.offset == 0 then incoming = {} end
	for _, row in ipairs(payload.rows) do
		-- Cheap on purpose, like the runtime's `adopt`: the row is the server's own
		-- `Access.Summary`, and twenty of them share one event's budget.
		local id = type(row) == 'table' and math.tointeger(row.id) or nil
		local x, y, z = id and finite(row.x), id and finite(row.y), id and finite(row.z)
		local name = id and row.name
		if type(name) ~= 'string' or name == '' or #name > Access.MAX_NAME then name = id and ('#' .. id) end
		if id ~= nil and id > 0 and x ~= nil and y ~= nil and z ~= nil then
			incoming[#incoming + 1] = { id = id, name = name,
				state = row.state == 0 and 0 or 1, bucket = math.tointeger(row.bucket) or 0,
				x = x, y = y, z = z, double = row.double == true, seeded = row.seeded == true }
		end
	end
	if payload.done ~= true then return end
	summary, incoming = incoming, {}
	if type(payload.mode) == 'string' then record.mode = payload.mode end
	rebuild()
end

local function onStaffDone(payload)
	if type(payload) ~= 'table' then return end
	local ok = payload.ok == true
	local code = tostring(payload.code or (ok and 'done' or 'invalid'))
	if record ~= nil then
		send('result', { verb = payload.verb, ok = ok, code = code, id = Access.Id(payload.id),
			detail = type(payload.detail) == 'string' and payload.detail or nil })
	end
	local name = type(payload.name) == 'string' and payload.name or ''
	if ok then
		local key = ({ save = payload.created and 'doorlock.staff.created' or 'doorlock.staff.saved',
			remove = 'doorlock.staff.removed', key = 'doorlock.staff.key_given' })[payload.verb]
		if payload.verb == 'state' then key = 'doorlock.answer.' .. code end
		toast(true, key or 'doorlock.answer.done', { door = name ~= '' and name or ('#' .. tostring(payload.id)) })
		if record ~= nil and payload.verb ~= 'key' and payload.verb ~= 'state' then ask(nil) end
	else
		local key = 'doorlock.error.' .. code
		if not OPX.Locale.Exists(key) then key = 'doorlock.error.invalid' end
		toast(false, key, { door = name, detail = type(payload.detail) == 'string' and payload.detail or '' })
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears the panel state.
-- @author dop42
function Panel.Init()
	record, nextHandle, pick, wired = nil, 0, nil, false
	summary, incoming, buildGeneration = {}, {}, 0
end

--- Wires the server's answers, the pause key and the pending-open retry.
-- @author dop42
function Panel.Start()
	RegisterNetEvent(M.Event.STAFF_OPEN, onStaffOpen)
	RegisterNetEvent(M.Event.STAFF_LIST, onStaffList)
	RegisterNetEvent(M.Event.STAFF_DONE, onStaffDone)
	-- Escape is swallowed by the plugin before the page sees it, and arrives
	-- here instead: it cancels a pick first, and closes the panel otherwise.
	--
	-- Only as the top layer (`OPX.Spots.Key.Layer`): a pick in the world is the
	-- newest thing the player started, so it outranks the panel it came from.
	local layer = OPX.Spots.Key.Layer('doorlock', function()
		if pick ~= nil then return pick.at end
		return record ~= nil and record.shown and record.openedAtMs or nil
	end)
	AddEventHandler('open77:pauseKey', function()
		if not OPX.Spots.Key.TopLayer(layer) then return end
		if pick ~= nil then return Panel.CancelPick() end
		if record ~= nil and record.shown then Panel.Close() end
	end)
	-- The open is re-sent until the surface takes it: a surface built on first
	-- use is not ready when the first panel opens on it.
	OPX.Scheduler.Every('doorlock:panel', 500, function()
		if record ~= nil and record.pendingOpen then flushOpen() end
	end)
end

--- Takes the panel down.
-- @author dop42
function Panel.Stop()
	Panel.Close()
end
