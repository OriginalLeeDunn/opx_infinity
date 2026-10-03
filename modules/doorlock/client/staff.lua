--- The staff panel: capture a door, edit who may turn it, save it.
-- @author dop42
--
-- ox_doorlock's `/doorlock` screen, drawn the way every staff screen here is
-- drawn: the `menu` contract one flat screen at a time, the `form` contract for
-- anything typed. A door is EDITED AS A DRAFT -- every toggle, slider and list
-- change lands in this client's copy, and nothing reaches the server until
-- Save -- because a door half-saved is a door that opens for the wrong people
-- between two rows.
--
-- NOTHING HERE DECIDES. Save is a net event the server gates on
-- `command.opx.doorlock.save` and re-validates field by field; Delete, Lock now
-- and Give me a key are restricted command lines; Teleport is the staff
-- module's own `opx.admin.player.tp`. A row this player's ACL would refuse is
-- greyed with the reason, never hidden, so a missing grant reads as one.
--
-- THE CLIENT BUDGET. A screen is built on the redraw's own thread, and every
-- loop over a list calls `breathe()`, which yields every few rows there and
-- nowhere else -- the lesson `modules/admin/client/menu.lua` paid for.

local M = OPX.Modules.Get('doorlock')
local Access = M.Access
local Runtime = M.Runtime
local Command = M.Command

M.Staff = {}
local Staff = M.Staff

local OWNER = 'doorlock'
local PAGE_ROWS = 15
local SEARCH_FROM = 12
local PAIR_RADIUS = 4.0
local VISIBLE_ROWS = 12
local MAX_HEIGHT_VH = 72

-- The staff module's teleport, which this panel borrows rather than copies.
local TELEPORT = 'opx.admin.player.tp'

-- What the server last said this player may do.
local access = {}

-- The summary list, the chunks still arriving, and whether it has arrived.
local list = { rows = {}, incoming = {}, loaded = false }

-- Door key to the detail the server sent.
local details = {}

-- The door being edited: { key|nil, origin, door = plain, dirty, loaded }.
local draft = nil

-- Screen stack: { screen, arg, cursor, page, filter }.
local stack = {}

-- The open menu's handle, and whether it is down for a form.
local handle, suspended = nil, false

-- The form open over the panel, if any.
local formHandle = nil

-- A status line for the next draw.
local queuedStatus = nil

local SCREENS = {}
local onAction

-- ── the budget ──────────────────────────────────────────────────────────────

local BREATHE_EVERY = 20
local breaths, onDrawThread = 0, false

local function breathe()
	breaths = breaths + 1
	if breaths % BREATHE_EVERY ~= 0 then return end
	if onDrawThread and type(Wait) == 'function' then Wait(0) end
end

-- ── rows ────────────────────────────────────────────────────────────────────

local function row(id, label, data, extra)
	local item = { id = id, label = label, data = data }
	for key, value in pairs(extra or {}) do item[key] = value end
	return item
end

local function section(key)
	return { separator = true, label = key and locale(key) or nil }
end

local function go(id, label, screen, arg, extra)
	local item = row(id, label, { go = screen, arg = arg }, extra)
	item.submenu = true
	return item
end

local function denied(item, allowed)
	if not allowed then item.disabled, item.value = true, locale('doorlock.staff.denied') end
	return item
end

local function empty(key)
	return row('empty', locale(key), nil, { disabled = true, icon = 'info' })
end

local function top() return stack[#stack] end

local function matches(query, ...)
	breathe()
	if query == nil then return true end
	local hay = ''
	for index = 1, select('#', ...) do
		local part = select(index, ...)
		if part ~= nil then hay = hay .. ' ' .. tostring(part):lower() end
	end
	for word in query:lower():gmatch('%S+') do
		if not hay:find(word, 1, true) then return false end
	end
	return true
end

-- Sends a command line as this player, the way the staff menu does.
local function execute(tokens)
	local clean = {}
	for _, token in ipairs(tokens) do clean[#clean + 1] = tostring(token) end
	local sent = TriggerServerEvent('open77:command:execute', table.unpack(clean))
	return sent ~= false
end

local function toast(ok, key, params)
	OPX.Toast.Show({ id = 'opx.doorlock.staff', kind = ok and 'success' or 'error',
		title = locale('doorlock.staff.title'), message = locale(key, params), icon = 'lock',
		durationMs = 4000 })
end

-- ── the draft ───────────────────────────────────────────────────────────────

local function copy(value)
	if type(value) ~= 'table' then return value end
	local out = {}
	for key, child in pairs(value) do out[key] = copy(child) end
	return out
end

--- A draft for a native door nobody manages yet.
local function draftFromNative(native)
	local id = Access.DoorId(native.id)
	local at = type(native.position) == 'table' and native.position or native
	local x, y, z = OPX.Math.Finite(at.x), OPX.Math.Finite(at.y), OPX.Math.Finite(at.z)
	if id == nil or x == nil or y == nil or z == nil then return nil end
	local name = OPX.Text.Clean(native.displayName or native.name, Access.MAX_NAME)
	if name == nil or name == '' or name:match('^0[xX]') then name = locale('doorlock.staff.newName') end
	return {
		key = nil, origin = 'db', dirty = true, loaded = true,
		door = {
			name = name, doors = { id }, x = x, y = y, z = z,
			bucket = Runtime.Report().bucket or 0, locked = true,
			groups = {}, items = {}, characters = {}, autolock = 0, lockpick = false,
			difficulty = Access.Lockpick().default, maxDistance = Access.UseRadius(),
			hideUi = false, onDuty = false,
			automatic = native.doorType == 2 or native.sideOne == 2 or native.sideTwo == 2,
		},
	}
end

--- A draft for a managed door, filled when its detail arrives.
local function draftFor(key)
	local detail = details[key]
	if detail == nil then
		return { key = key, loaded = false, door = nil, dirty = false }
	end
	local door = copy(detail)
	local origin = door.origin
	door.key, door.origin, door.live, door.hasPasscode = nil, nil, nil, nil
	return { key = key, origin = origin, live = detail.live, hasPasscode = detail.hasPasscode,
		loaded = true, door = door, dirty = false }
end

local function editable()
	return draft ~= nil and draft.loaded and draft.origin ~= 'config' and access.save == true
end

-- ── screens ─────────────────────────────────────────────────────────────────

SCREENS.root = function()
	local items = {
		section('doorlock.staff.section.here'),
		row('aimed', locale('doorlock.staff.aimed'), { aimed = true }, { icon = 'eye',
			description = locale('doorlock.staff.aimedHint') }),
		section('doorlock.staff.section.all'),
		go('list', locale('doorlock.staff.list'), 'list', nil,
			{ icon = 'list', value = list.loaded and tostring(#list.rows) or locale('doorlock.staff.loading') }),
		row('refresh', locale('doorlock.staff.refresh'), { refresh = true }, { icon = 'refresh' }),
	}
	return locale('doorlock.staff.title'), items
end

SCREENS.list = function()
	local current = top()
	local query = current.filter
	local matched = {}
	for _, entry in ipairs(list.rows) do
		if matches(query, entry.key, entry.name, entry.origin, table.concat(entry.ids or {}, ' ')) then
			matched[#matched + 1] = entry
		end
	end
	local items = {}
	if #list.rows >= SEARCH_FROM or query ~= nil then
		items[#items + 1] = row('search', query and locale('doorlock.staff.searching', { query = query })
			or locale('doorlock.staff.search'), { search = true }, { icon = 'search' })
		if query ~= nil then
			items[#items + 1] = row('searchClear', locale('doorlock.staff.searchClear'),
				{ clearFilter = true }, { icon = 'back', value = tostring(#matched) })
		end
	end
	local page = current.page or 1
	local pages = math.max(1, math.ceil(#matched / PAGE_ROWS))
	if page > pages then page = pages end
	current.page = page
	for index = (page - 1) * PAGE_ROWS + 1, math.min(#matched, page * PAGE_ROWS) do
		breathe()
		local entry = matched[index]
		local value = locale(entry.locked and 'doorlock.staff.stateLocked' or 'doorlock.staff.stateUnlocked')
		if entry.origin == 'config' then value = value .. ' · ' .. locale('doorlock.staff.config') end
		if entry.bucket ~= 0 then value = value .. (' · b%d'):format(entry.bucket) end
		items[#items + 1] = go('door_' .. entry.key, entry.name, 'door', entry.key,
			{ icon = entry.locked and 'lock' or 'door', value = value, description = entry.key })
	end
	if not list.loaded then
		items[#items + 1] = empty('doorlock.staff.loading')
	elseif #matched == 0 then
		items[#items + 1] = empty(query and 'doorlock.staff.noMatch' or 'doorlock.staff.none')
	end
	if pages > 1 then
		if page > 1 then items[#items + 1] = row('prev', locale('doorlock.staff.prev'), { page = page - 1 },
			{ icon = 'arrow' }) end
		if page < pages then items[#items + 1] = row('next', locale('doorlock.staff.next'),
			{ page = page + 1 }, { icon = 'arrow', value = ('%d/%d'):format(page, pages) }) end
	end
	return locale('doorlock.staff.list'), items
end

-- A one-line summary of a group, an item, a character.
local function groupLabel(group)
	return locale(group.kind == 'job' and 'doorlock.staff.groupJob' or 'doorlock.staff.groupGang',
		{ name = group.name, grade = group.grade })
end

local function itemLabel(item)
	local parts = { item.name }
	if item.bound then parts[#parts + 1] = locale('doorlock.staff.itemBound') end
	if item.remove then parts[#parts + 1] = locale('doorlock.staff.itemSpent') end
	return table.concat(parts, ' · ')
end

SCREENS.door = function()
	if draft == nil or not draft.loaded then
		return locale('doorlock.staff.door'), { empty('doorlock.staff.loading') }
	end
	local door = draft.door
	local edit = editable()
	local function field(item)
		if not edit then item.disabled = true end
		return item
	end
	local title = door.name .. (draft.dirty and ' *' or '')
	local items = {}

	if draft.origin == 'config' then
		items[#items + 1] = empty('doorlock.staff.configHint')
	end
	items[#items + 1] = section('doorlock.staff.section.door')
	items[#items + 1] = field(row('name', locale('doorlock.staff.name'), { form = 'name' },
		{ value = door.name, icon = 'tag' }))
	items[#items + 1] = field(row('locked', locale('doorlock.staff.lockedDefault'), { field = 'locked' },
		{ toggle = door.locked == true }))
	if draft.key ~= nil then
		local live = draft.live == true
		items[#items + 1] = denied(row('lockNow', locale(live and 'doorlock.staff.unlockNow'
			or 'doorlock.staff.lockNow'), { run = { Command.LOCK, draft.key, live and 'off' or 'on' },
			flip = true }, { icon = live and 'door' or 'lock',
			value = locale(live and 'doorlock.staff.stateLocked' or 'doorlock.staff.stateUnlocked') }),
			access.lock == true)
	end

	items[#items + 1] = section('doorlock.staff.section.access')
	items[#items + 1] = go('groups', locale('doorlock.staff.groups'), 'groups', nil,
		{ icon = 'person', value = tostring(#door.groups) })
	items[#items + 1] = go('items', locale('doorlock.staff.items'), 'items', nil,
		{ icon = 'key', value = tostring(#door.items) })
	items[#items + 1] = go('chars', locale('doorlock.staff.characters'), 'chars', nil,
		{ icon = 'star', value = tostring(#door.characters) })
	local coded = door.passcode
	local codeValue
	if coded == false then codeValue = locale('doorlock.staff.none')
	elseif type(coded) == 'string' then codeValue = locale('doorlock.staff.codeNew')
	else codeValue = draft.hasPasscode and locale('doorlock.staff.codeSet') or locale('doorlock.staff.none') end
	items[#items + 1] = field(row('passcode', locale('doorlock.staff.passcode'), { form = 'passcode' },
		{ icon = 'shield', value = codeValue }))
	items[#items + 1] = field(row('onDuty', locale('doorlock.staff.onDuty'), { field = 'onDuty' },
		{ toggle = door.onDuty == true }))

	items[#items + 1] = section('doorlock.staff.section.behaviour')
	items[#items + 1] = field(row('autolock', locale('doorlock.staff.autolock'), { field = 'autolock' },
		{ slider = { min = 0, max = 600, step = 5, value = door.autolock or 0, suffix = 's' } }))
	items[#items + 1] = field(row('lockpick', locale('doorlock.staff.lockpick'), { field = 'lockpick' },
		{ toggle = door.lockpick == true }))
	local levels = Access.Difficulties()
	local selected = 1
	for index, name in ipairs(levels) do if name == door.difficulty then selected = index end end
	local labels = {}
	for index, name in ipairs(levels) do
		local key = 'doorlock.difficulty.' .. name
		labels[index] = OPX.Locale.Exists(key) and locale(key) or name
	end
	items[#items + 1] = field(row('difficulty', locale('doorlock.staff.difficulty'),
		{ field = 'difficulty', levels = levels }, { choices = labels, selected = selected }))
	items[#items + 1] = field(row('reach', locale('doorlock.staff.reach'), { field = 'maxDistance' },
		{ slider = { min = 0.5, max = Access.MaxReach(), step = 0.5, value = door.maxDistance or 2,
			suffix = 'm' } }))
	items[#items + 1] = field(row('hideUi', locale('doorlock.staff.hideUi'), { field = 'hideUi' },
		{ toggle = door.hideUi == true }))
	local pairItem = go('pair', locale('doorlock.staff.pair'), 'pair', nil,
		{ icon = 'door', value = door.doors[2] or locale('doorlock.staff.none'), description = door.doors[1] })
	items[#items + 1] = field(pairItem)

	items[#items + 1] = section('doorlock.staff.section.actions')
	items[#items + 1] = denied(row('save', locale(draft.key and 'doorlock.staff.save'
		or 'doorlock.staff.create'), { save = true }, { icon = 'plus' }), edit)
	items[#items + 1] = row('goto', locale('doorlock.staff.goto'),
		{ run = { TELEPORT, 'me', ('%.2f'):format(door.x), ('%.2f'):format(door.y),
			('%.2f'):format(door.z + 0.5) } }, { icon = 'location' })
	if draft.key ~= nil then
		items[#items + 1] = denied(row('key', locale('doorlock.staff.giveKey'),
			{ run = { Command.KEY, draft.key } }, { icon = 'key' }), access.key == true)
		if draft.origin ~= 'config' then
			items[#items + 1] = denied(go('delete', locale('doorlock.staff.delete'), 'confirm', draft.key,
				{ icon = 'trash' }), access.remove == true)
		end
	end
	return title, items
end

SCREENS.groups = function()
	local door = draft and draft.door
	if door == nil then return locale('doorlock.staff.groups'), { empty('doorlock.staff.loading') } end
	local edit = editable()
	local items = {}
	for index, group in ipairs(door.groups) do
		breathe()
		items[#items + 1] = row('group_' .. index, groupLabel(group), { removeGroup = index },
			{ icon = 'minus', disabled = not edit, description = locale('doorlock.staff.removeHint') })
	end
	if #door.groups == 0 then items[#items + 1] = empty('doorlock.staff.noGroups') end
	items[#items + 1] = section()
	items[#items + 1] = row('addJob', locale('doorlock.staff.addJob'), { form = 'job' },
		{ icon = 'plus', disabled = not edit or #door.groups >= Access.MAX_GROUPS })
	items[#items + 1] = row('addGang', locale('doorlock.staff.addGang'), { form = 'gang' },
		{ icon = 'plus', disabled = not edit or #door.groups >= Access.MAX_GROUPS })
	return locale('doorlock.staff.groups'), items
end

SCREENS.items = function()
	local door = draft and draft.door
	if door == nil then return locale('doorlock.staff.items'), { empty('doorlock.staff.loading') } end
	local edit = editable()
	local items = {}
	for index, item in ipairs(door.items) do
		breathe()
		items[#items + 1] = row('item_' .. index, itemLabel(item), { removeItem = index },
			{ icon = 'minus', disabled = not edit, description = locale('doorlock.staff.removeHint') })
	end
	if #door.items == 0 then items[#items + 1] = empty('doorlock.staff.noItems') end
	local full = #door.items >= Access.MAX_ITEMS
	items[#items + 1] = section()
	items[#items + 1] = row('addBound', locale('doorlock.staff.addBound', { item = Access.KeyItem() }),
		{ addBound = true }, { icon = 'key', disabled = not edit or full })
	items[#items + 1] = row('addItem', locale('doorlock.staff.addItem'), { form = 'item' },
		{ icon = 'plus', disabled = not edit or full })
	return locale('doorlock.staff.items'), items
end

SCREENS.chars = function()
	local door = draft and draft.door
	if door == nil then return locale('doorlock.staff.characters'), { empty('doorlock.staff.loading') } end
	local edit = editable()
	local items = {}
	for index, citizen in ipairs(door.characters) do
		breathe()
		items[#items + 1] = row('char_' .. index, citizen, { removeChar = index },
			{ icon = 'minus', disabled = not edit, description = locale('doorlock.staff.removeHint') })
	end
	if #door.characters == 0 then items[#items + 1] = empty('doorlock.staff.noCharacters') end
	items[#items + 1] = section()
	items[#items + 1] = row('addChar', locale('doorlock.staff.addCharacter'), { form = 'character' },
		{ icon = 'plus', disabled = not edit or #door.characters >= Access.MAX_CHARACTERS })
	return locale('doorlock.staff.characters'), items
end

-- The native doors near the draft that could be its other half.
local function candidates()
	local native = Open77.doors
	if draft == nil or draft.door == nil or type(native) ~= 'table' or type(native.near) ~= 'function' then
		return {}
	end
	local read, found = pcall(native.near, 20)
	if not read or type(found) ~= 'table' then return {} end
	local door, out = draft.door, {}
	for _, entry in ipairs(found) do
		breathe()
		local id = type(entry) == 'table' and Access.DoorId(entry.id) or nil
		local at = id and type(entry.position) == 'table' and entry.position or nil
		if at ~= nil and id ~= door.doors[1] and not entry.lift then
			local owner = Runtime.KeyOf(id)
			local distance = math.sqrt(Access.DistanceSquared(door, at.x, at.y, at.z))
			if distance <= PAIR_RADIUS and (owner == nil or owner == draft.key) then
				out[#out + 1] = { id = id, distance = distance, x = at.x, y = at.y, z = at.z }
			end
		end
	end
	table.sort(out, function(left, right) return left.distance < right.distance end)
	return out
end

SCREENS.pair = function()
	local door = draft and draft.door
	if door == nil then return locale('doorlock.staff.pair'), { empty('doorlock.staff.loading') } end
	local items = {
		row('single', locale('doorlock.staff.single'), { unpair = true },
			{ icon = 'door', toggle = nil, value = door.doors[2] == nil and locale('doorlock.staff.current') or nil }),
	}
	for index, candidate in ipairs(candidates()) do
		items[#items + 1] = row('cand_' .. index, candidate.id, { pairWith = candidate },
			{ icon = 'door', value = ('%.1fm'):format(candidate.distance),
				description = door.doors[2] == candidate.id and locale('doorlock.staff.current') or nil })
	end
	if #items == 1 then items[#items + 1] = empty('doorlock.staff.noCandidates') end
	return locale('doorlock.staff.pair'), items
end

SCREENS.confirm = function(key)
	local name = draft and draft.door and draft.door.name or tostring(key)
	return locale('doorlock.staff.deleteTitle', { door = name }), {
		row('confirmDelete', locale('doorlock.staff.deleteConfirm'), { confirmDelete = key },
			{ icon = 'trash', danger = true }),
	}
end

-- ── drawing ─────────────────────────────────────────────────────────────────

local function drawNow(inPlace)
	local current = top()
	if current == nil or suspended then return end
	local builder = SCREENS[current.screen]
	local contract = OPX.Api.Get('menu')
	if builder == nil or contract == nil then return end
	local title, items = builder(current.arg)
	items[#items + 1] = section()
	if #stack > 1 then
		items[#items + 1] = row('back', locale('doorlock.staff.back'), { back = true }, { icon = 'back' })
	else
		items[#items + 1] = { id = 'close', label = locale('doorlock.staff.close'), close = true, icon = 'door' }
	end
	local status = queuedStatus
	queuedStatus = nil
	local landing = nil
	if not inPlace then landing = current.cursor end
	if handle ~= nil then
		local patched = contract.Update(handle, { title = title, items = items, cursor = landing,
			status = status and status.text or nil, statusBad = status and status.ok == false or nil })
		if type(patched) == 'table' and patched.ok then return end
		handle = nil
	end
	local opened = contract.Open({
		owner = OWNER, id = 'doorlock.' .. current.screen, title = title, items = items,
		cursor = current.cursor, rows = VISIBLE_ROWS, maxHeight = MAX_HEIGHT_VH, on = onAction,
	})
	if type(opened) ~= 'table' or not opened.ok then
		handle = nil
		Open77.log.warn(('[doorlock] panel %s did not open: %s'):format(current.screen,
			tostring(type(opened) == 'table' and opened.error or opened)))
		return
	end
	handle = opened.value.handle
end

-- Queued onto its own thread, one at a time: a redraw run inside a callback
-- shares that callback's budget, and the staff menu lost a screen to exactly that.
local drawQueued, drawQueuedInPlace, drawing = false, true, false

local function draw(inPlace)
	if type(CreateThread) ~= 'function' then return drawNow(inPlace) end
	drawQueuedInPlace = drawQueuedInPlace and inPlace == true
	drawQueued = true
	if drawing then return end
	drawing = true
	CreateThread(function()
		while drawQueued do
			local place = drawQueuedInPlace
			drawQueued, drawQueuedInPlace = false, true
			onDrawThread = true
			local ran, failure = pcall(drawNow, place)
			onDrawThread = false
			if not ran then Open77.log.error('[doorlock] panel draw: ' .. tostring(failure)) end
		end
		drawing = false
	end)
end

local function push(screen, arg)
	local current = top()
	if current ~= nil then current.cursor = current.cursor end
	stack[#stack + 1] = { screen = screen, arg = arg }
	if screen == 'door' and type(arg) == 'string' then
		if draft == nil or draft.key ~= arg then draft = draftFor(arg) end
		TriggerServerEvent(M.Event.STAFF_ASK, { key = arg })
	elseif screen == 'list' then
		TriggerServerEvent(M.Event.STAFF_ASK, {})
	end
	draw(false)
end

local function pop()
	if #stack <= 1 then return Staff.Close() end
	stack[#stack] = nil
	draw(false)
end

local function takeDown()
	local closing = handle
	handle = nil
	local contract = OPX.Api.Get('menu')
	if closing ~= nil and contract ~= nil then pcall(contract.Close, closing, OWNER) end
end

-- ── forms ───────────────────────────────────────────────────────────────────

local function groupOptions(kind)
	local character = OPX.Config.MODULES.character
	local groups = type(character) == 'table' and character[kind == 'job' and 'JOBS' or 'GANGS'] or nil
	if type(groups) ~= 'table' then return nil end
	local options = {}
	for name, group in pairs(groups) do
		options[#options + 1] = { label = ('%s (%s)'):format(tostring(group.label or name), name),
			value = name }
	end
	table.sort(options, function(left, right) return left.label < right.label end)
	if #options > 64 then
		local cut = {}
		for index = 1, 64 do cut[index] = options[index] end
		options = cut
	end
	return options
end

local YES_NO = function()
	return { { label = locale('doorlock.staff.no'), value = 'no' },
		{ label = locale('doorlock.staff.yes'), value = 'yes' } }
end

local FORMS = {
	name = {
		build = function()
			return { title = locale('doorlock.staff.name'), fields = {
				{ id = 'name', label = locale('doorlock.staff.name'), value = draft.door.name,
					maxLength = Access.MAX_NAME, required = true } } }
		end,
		submit = function(values)
			local name = OPX.Text.Clean(values.name, Access.MAX_NAME)
			if name ~= nil and OPX.String.Trim(name) ~= '' then draft.door.name = OPX.String.Trim(name) end
		end,
	},
	passcode = {
		build = function()
			return { title = locale('doorlock.staff.passcode'),
				description = locale('doorlock.staff.passcodeHint'), fields = {
					{ id = 'code', label = locale('doorlock.field.passcode'), maxLength = Access.MAX_PASSCODE } } }
		end,
		submit = function(values)
			local code = type(values.code) == 'string' and values.code or ''
			draft.door.passcode = code ~= '' and code or false
		end,
	},
	job = {
		build = function()
			local options = groupOptions('job')
			if options == nil or #options == 0 then return nil end
			return { title = locale('doorlock.staff.addJob'), fields = {
				{ id = 'group', label = locale('doorlock.staff.job'), options = options },
				{ id = 'grade', label = locale('doorlock.staff.grade'), value = '0', charset = 'digits',
					maxLength = 3, required = true } } }
		end,
		submit = function(values)
			local grade = math.tointeger(tonumber(values.grade)) or 0
			draft.door.groups[#draft.door.groups + 1] = { kind = 'job', name = values.group, grade = grade }
		end,
	},
	gang = {
		build = function()
			local options = groupOptions('gang')
			if options == nil or #options == 0 then return nil end
			return { title = locale('doorlock.staff.addGang'), fields = {
				{ id = 'group', label = locale('doorlock.staff.gang'), options = options },
				{ id = 'grade', label = locale('doorlock.staff.grade'), value = '0', charset = 'digits',
					maxLength = 3, required = true } } }
		end,
		submit = function(values)
			local grade = math.tointeger(tonumber(values.grade)) or 0
			draft.door.groups[#draft.door.groups + 1] = { kind = 'gang', name = values.group, grade = grade }
		end,
	},
	item = {
		build = function()
			return { title = locale('doorlock.staff.addItem'), fields = {
				{ id = 'name', label = locale('doorlock.staff.itemName'), pattern = '^[%w_%-%.]+$',
					maxLength = 48, required = true },
				{ id = 'bound', label = locale('doorlock.staff.itemBoundField'), options = YES_NO() },
				{ id = 'remove', label = locale('doorlock.staff.itemSpentField'), options = YES_NO() } } }
		end,
		submit = function(values)
			local bound = values.bound == 'yes'
			draft.door.items[#draft.door.items + 1] = { name = values.name, bound = bound,
				remove = values.remove == 'yes' and not bound }
		end,
	},
	character = {
		build = function()
			return { title = locale('doorlock.staff.addCharacter'), fields = {
				{ id = 'citizen', label = locale('doorlock.staff.citizenId'), pattern = '^%w+$',
					maxLength = 32, required = true } } }
		end,
		submit = function(values)
			draft.door.characters[#draft.door.characters + 1] = values.citizen
		end,
	},
	search = {
		build = function()
			local current = top()
			return { title = locale('doorlock.staff.search'), fields = {
				{ id = 'query', label = locale('doorlock.staff.query'), maxLength = 48,
					value = current and current.filter or nil } } }
		end,
		submit = function(values)
			local current = top()
			if current == nil then return end
			local query = OPX.String.Trim(type(values.query) == 'string' and values.query or '')
			current.filter = query ~= '' and query or nil
			current.page = 1
		end,
		keepClean = true,
	},
}

local function openForm(kind)
	local form = FORMS[kind]
	local contract = OPX.Api.Get('form')
	if form == nil or contract == nil then
		queuedStatus = { text = locale('doorlock.staff.noForm'), ok = false }
		return draw(true)
	end
	if kind ~= 'search' and (draft == nil or draft.door == nil) then return end
	local spec = form.build()
	if spec == nil then
		queuedStatus = { text = locale('doorlock.staff.noForm'), ok = false }
		return draw(true)
	end
	spec.owner = OWNER
	spec.id = 'doorlock.' .. kind
	spec.on = function(answer)
		formHandle = nil
		suspended = false
		if type(answer) == 'table' and answer.action == 'submit' and type(answer.values) == 'table' then
			form.submit(answer.values)
			if not form.keepClean and draft ~= nil then draft.dirty = true end
		end
		draw(false)
	end
	suspended = true
	takeDown()
	local opened = contract.Open(spec)
	if type(opened) ~= 'table' or not opened.ok then
		suspended = false
		queuedStatus = { text = locale('doorlock.staff.noForm'), ok = false }
		return draw(false)
	end
	formHandle = opened.value.handle
end

-- ── what the operator did ───────────────────────────────────────────────────

local function save()
	if not editable() then return end
	local door = copy(draft.door)
	local sent = TriggerServerEvent(M.Event.STAFF_SAVE, { key = draft.key, door = door })
	if sent == false then toast(false, 'doorlock.error.invalid') end
end

onAction = function(payload)
	if type(payload) ~= 'table' then return end
	if payload.action == 'close' then
		if payload.handle ~= handle then return end
		handle = nil
		if suspended then return end
		if payload.reason == 'back' and #stack > 1 then
			stack[#stack] = nil
			return draw(false)
		end
		stack = {}
		return
	end
	local data = payload.data
	local current = top()
	if type(data) ~= 'table' or current == nil then return end
	current.cursor = payload.itemId

	if payload.action == 'change' then
		if draft == nil or draft.door == nil or not editable() then return draw(true) end
		local value = payload.value
		if data.field == 'difficulty' then
			for index, name in ipairs(data.levels or {}) do
				local key = 'doorlock.difficulty.' .. name
				local label = OPX.Locale.Exists(key) and locale(key) or name
				if label == value then draft.door.difficulty = data.levels[index] end
			end
		elseif data.field == 'autolock' then
			draft.door.autolock = math.floor(OPX.Math.Finite(value) or 0)
		elseif data.field == 'maxDistance' then
			draft.door.maxDistance = OPX.Math.Finite(value) or draft.door.maxDistance
		elseif type(data.field) == 'string' and type(value) == 'boolean' then
			draft.door[data.field] = value
		else
			return
		end
		draft.dirty = true
		return draw(true)
	end

	if payload.action ~= 'select' then return end
	if data.back then return pop() end
	if type(data.go) == 'string' and SCREENS[data.go] then return push(data.go, data.arg) end
	if data.aimed then return Staff.ManageAimed() end
	if data.refresh then
		TriggerServerEvent(M.Event.STAFF_ASK, {})
		return
	end
	if data.search then return openForm('search') end
	if data.clearFilter then
		current.filter, current.page = nil, 1
		return draw(true)
	end
	if type(data.page) == 'number' then
		current.page = data.page
		return draw(true)
	end
	if type(data.form) == 'string' then return openForm(data.form) end
	if data.save then return save() end
	if type(data.run) == 'table' then
		if execute(data.run) and data.flip and draft ~= nil then
			-- Drawn as asked at once; the server's next detail corrects it if the
			-- command was refused.
			draft.live = not draft.live
			draw(true)
		end
		return
	end
	if draft == nil or draft.door == nil then return end
	local door = draft.door
	if data.removeGroup and editable() then
		table.remove(door.groups, data.removeGroup)
	elseif data.removeItem and editable() then
		table.remove(door.items, data.removeItem)
	elseif data.removeChar and editable() then
		table.remove(door.characters, data.removeChar)
	elseif data.addBound and editable() then
		door.items[#door.items + 1] = { name = Access.KeyItem(), bound = true, remove = false }
	elseif data.unpair and editable() then
		door.doors = { door.doors[1] }
	elseif type(data.pairWith) == 'table' and editable() then
		local other = data.pairWith
		door.doors = { door.doors[1], other.id }
		-- The managed position is the middle of the doorway, ox's rule: a player
		-- at either leaf is the same distance from the door.
		door.x, door.y, door.z = (door.x + other.x) / 2, (door.y + other.y) / 2, (door.z + other.z) / 2
		pop()
	elseif data.confirmDelete then
		execute({ Command.REMOVE, data.confirmDelete })
		draft = nil
		stack[#stack] = nil
		stack[#stack] = nil
		TriggerServerEvent(M.Event.STAFF_ASK, {})
		if #stack == 0 then stack = { { screen = 'root' } } end
		return draw(false)
	else
		return
	end
	draft.dirty = true
	draw(true)
end

-- ── the server's answers ────────────────────────────────────────────────────

local function onList(payload)
	if type(payload) ~= 'table' then return end
	if payload.detail ~= nil then
		if payload.detail == false then
			details[tostring(payload.key)] = nil
			return
		end
		local detail = payload.detail
		if type(detail) ~= 'table' or type(detail.key) ~= 'string' then return end
		details[detail.key] = detail
		if draft ~= nil and draft.key == detail.key then
			if not draft.loaded or not draft.dirty then
				draft = draftFor(detail.key)
			else
				draft.live = detail.live
			end
			if handle ~= nil then draw(true) end
		end
		return
	end
	if type(payload.rows) ~= 'table' then return end
	if payload.offset == 0 then list.incoming = {} end
	for _, entry in ipairs(payload.rows) do
		if type(entry) == 'table' and type(entry.key) == 'string' then
			list.incoming[#list.incoming + 1] = entry
		end
	end
	if payload.done ~= true then return end
	list.rows, list.incoming, list.loaded = list.incoming, {}, true
	if handle ~= nil then draw(true) end
end

local function onSaved(payload)
	if type(payload) ~= 'table' then return end
	if not payload.ok then
		local key = 'doorlock.error.' .. tostring(payload.code)
		if not OPX.Locale.Exists(key) then key = 'doorlock.error.invalid' end
		toast(false, key, { door = draft and draft.door and draft.door.name or '',
			detail = tostring(payload.detail or '') })
		return
	end
	toast(true, payload.created and 'doorlock.staff.created' or 'doorlock.staff.saved',
		{ door = draft and draft.door and draft.door.name or payload.key })
	if draft ~= nil then
		draft.key, draft.origin, draft.dirty = payload.key, 'db', false
		if draft.door and type(draft.door.passcode) == 'string' then draft.hasPasscode = true end
		if draft.door and draft.door.passcode == false then draft.hasPasscode = false end
	end
	local current = top()
	if current ~= nil and current.screen == 'door' then current.arg = payload.key end
	TriggerServerEvent(M.Event.STAFF_ASK, {})
	TriggerServerEvent(M.Event.STAFF_ASK, { key = payload.key })
	draw(true)
end

-- ── the doors in ────────────────────────────────────────────────────────────

--- Opens the panel at its root, or at one door.
-- @author dop42
-- @param flags table|nil what the server says this player may do
-- @param landing table|nil { screen, arg } to push over the root
-- @return boolean
function Staff.Open(flags, landing)
	if OPX.Api.Get('menu') == nil then
		toast(false, 'doorlock.staff.noMenu')
		return false
	end
	access = type(flags) == 'table' and flags or access
	stack = { { screen = 'root' } }
	TriggerServerEvent(M.Event.STAFF_ASK, {})
	if landing ~= nil then
		stack[#stack + 1] = { screen = landing.screen, arg = landing.arg }
		if landing.screen == 'door' and type(landing.arg) == 'string' then
			TriggerServerEvent(M.Event.STAFF_ASK, { key = landing.arg })
		end
	end
	draw(false)
	return true
end

--- Opens the panel on one native door: its editor when it is managed, a new
--- draft when it is not.
-- @author dop42
-- @param native table a door snapshot from `Open77.doors`
-- @return boolean
function Staff.Manage(native)
	local flags = Runtime.Staff()
	if flags == nil then return false end
	local id = type(native) == 'table' and Access.DoorId(native.id) or nil
	if id == nil then return false end
	local key = Runtime.KeyOf(id)
	if key ~= nil then
		if draft == nil or draft.key ~= key then draft = draftFor(key) end
		return Staff.Open(flags, { screen = 'door', arg = key })
	end
	draft = draftFromNative(native)
	if draft == nil then return false end
	return Staff.Open(flags, { screen = 'door' })
end

--- The door under the crosshair, or the closest one within three metres.
-- @author dop42
-- @return boolean
function Staff.ManageAimed()
	local native = Open77.doors
	if type(native) ~= 'table' then
		toast(false, 'doorlock.staff.noDoor')
		return false
	end
	local found = nil
	if type(native.aimed) == 'function' then
		local read, door = pcall(native.aimed)
		if read and type(door) == 'table' then found = door end
	end
	if found == nil and type(native.closest) == 'function' then
		local read, door = pcall(native.closest, 3.0)
		if read and type(door) == 'table' then found = door end
	end
	if found ~= nil and type(native.state) == 'function' and found.position == nil then
		local read, live = pcall(native.state, found.id)
		if read and type(live) == 'table' then found = live end
	end
	if found == nil or found.lift then
		toast(false, 'doorlock.staff.noDoor')
		return false
	end
	return Staff.Manage(found)
end

--- Takes the panel and any form down.
-- @author dop42
function Staff.Close()
	stack = {}
	suspended = false
	if formHandle ~= nil then
		local contract = OPX.Api.Get('form')
		if contract ~= nil then pcall(contract.Close, formHandle) end
		formHandle = nil
	end
	takeDown()
end

--- What the panel holds, for a test.
-- @author dop42
-- @return table
function Staff.Report()
	return { open = handle ~= nil, screen = top() and top().screen or nil, draft = draft,
		rows = #list.rows, access = access, depth = #stack }
end

--- Wires the three server answers.
-- @author dop42
function Staff.Start()
	RegisterNetEvent(M.Event.STAFF_OPEN, function(payload)
		if type(payload) ~= 'table' then return end
		if #stack > 0 then return Staff.Close() end
		Staff.Open(payload.access)
	end)
	RegisterNetEvent(M.Event.STAFF_LIST, onList)
	RegisterNetEvent(M.Event.STAFF_SAVED, onSaved)
end

--- Takes everything down.
-- @author dop42
function Staff.Stop()
	Staff.Close()
	draft, details, list = nil, {}, { rows = {}, incoming = {}, loaded = false }
end
