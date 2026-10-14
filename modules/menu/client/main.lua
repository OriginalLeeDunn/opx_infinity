--- The one open menu: its validated tree, the cursor, and the surface it draws on.
-- @author dop42

local M = OPX.Modules.Get('menu')

local Result = OPX.Result
local Text = OPX.Text

local SURFACE = 'interactive'
local OWNER = 'menu'

-- Rows across the whole tree, submenus and separators counted. Every bound in
-- this block exists because the host discards an event carrying more than 1024
-- value nodes and says nothing: a menu that quietly stopped answering is far
-- worse to debug than one that refused to open.
local MAX_NODES = 400
local MAX_ROWS = 200
local MAX_DEPTH = 8
-- A row's and a menu's `data` are held to `OPX.Modal.DATA_NODES` and `DATA_DEPTH`.

local MAX_LABEL = 96
local MAX_VALUE = 48
local MAX_DESCRIPTION = 160
local MAX_STATUS = 120
local MAX_SUFFIX = 8

local MAX_NAME = 64

-- How often the status line and the owner sweep are looked at. Neither is
-- frame work: the page reads the keyboard now, so there is no input tick left
-- to hang them off.
local UPKEEP_MS = 250

-- The keys the page forwards.
local KEYS = { up = true, down = true, left = true, right = true, enter = true, back = true }

-- The same six, in the vocabulary `Open77.input.isDown` speaks, for the modes
-- where the page does NOT hold the keyboard and therefore never sees them.
-- Names are the documented set: the four arrows are UP/DOWN/LEFT/RIGHT, and
-- ENTER and BACKSPACE are spelled out.
local POLLED = {
	{ 'UP', 'up' },
	{ 'DOWN', 'down' },
	{ 'LEFT', 'left' },
	{ 'RIGHT', 'right' },
	{ 'ENTER', 'enter' },
	{ 'BACKSPACE', 'back' },
}

-- The repeat machine, at the numbers `opx77_menu/client/input.lua` used. A poll
-- finer than the repeat interval is what keeps a held arrow even.
local POLL_MS = 25
local REPEAT_FIRST_MS = 260

-- How many passes after the poll starts a press must be RELEASED before it
-- counts. `primeHeld` reads what is down at the start, but a menu reopened by a
-- form's Enter starts in the very tick the form gave the keyboard back, and the
-- game does not see a key the page was holding until a pass later. Read then,
-- that same press was a fresh edge and fired on the row the reopened menu put
-- the cursor on. Counted in passes and not milliseconds because the hand-off is
-- a pass late however long a pass takes; four is about 100ms at 25ms a pass.
local REOPEN_GRACE_PASSES = 4
local REPEAT_NEXT_MS = 55

-- What this module's focus owners are given. The page names an owner and never
-- says what it wants: asking for the cursor is not the page's decision.
-- `focus:set` is a broadcast every view module listens to, and each answers for
-- its own owners only -- a module must not acquire, or release, focus on behalf
-- of a view it does not own.
-- Rewritten on every open from the opening menu's `focus` mode, which is why it
-- is not a constant: what a `full` menu is granted and what a `cursor` menu is
-- granted are different pairs, and the page asking is the same ask either way.
local FOCUS = {
	menu = { keyboard = true, cursor = true },
}

-- The one open menu, or nil.
local record

-- The last `open` this module announced, so the event is raised on a CHANGE and
-- not on every open. A menu replacing another is still a menu being open, and a
-- listener that stood aside would see the HUD flicker between the two.
local announcedOpen = false

-- Tells anything that has to stand aside whether a menu is up. Cheap enough to
-- call from both ends of every path rather than making each one decide.
local function announce()
	local isOpen = record ~= nil
	if isOpen == announcedOpen then return end
	announcedOpen = isOpen
	TriggerEvent(M.Event.STATE, { open = isOpen })
end

-- Handle the next opened menu receives. Unique for the life of the session.
local nextHandle = 0

-- True while `menu:open` has not reached the page. The interactive surface is
-- built on first use and a send made before it reports ready is dropped, not
-- queued, so the open is re-sent from the upkeep job until it lands.
local pendingOpen = false

-- Whether the page channels have been wired. Wiring them builds the surface,
-- so it is deferred to the first Open: a player who never opens a menu should
-- not pay for a CEF page.
local wired = false

-- ── text and names ──────────────────────────────────────────────────────────

-- Whether a value is a number that is neither NaN nor infinite. The one shared
-- predicate, aliased rather than wrapped: a one-line wrapper is a second name
-- for the same answer and the only thing it can ever do is drift.
local finite = OPX.Math.IsFinite

local find = string.find

--- `Text.Clean` with the common case answered in place.
-- Every row of a spec is cleaned field by field inside the caller's resume --
-- label, description, value, the toggle words -- and most of those fields are
-- absent or are short plain text already. Those come back as they are without
-- a copy through `gsub`: no control character and no more bytes than the limit
-- in characters means nothing to replace and nothing to cut. Anything else goes
-- through `Text.Clean` exactly as before.
local function clean(value, maximum)
	if value == nil then return nil end
	if type(value) == 'string' and #value <= maximum and not find(value, '%c') then return value end
	return Text.Clean(value, maximum)
end

-- The id check and the payload bound are `OPX.Modal`'s, shared with `form` and
-- `panel`, and aliased here rather than wrapped. `dataFault` validates a
-- caller's opaque table whole (`OPX.Modal.DATA_NODES`, `DATA_DEPTH`), answering
-- a refusal code or nil.
local validName = OPX.Modal.ValidName
local dataFault = OPX.Modal.DataFault

--- Whether a value is text the status line accepts. A table would sanitise to
--- nil and silently clear the line, so it is refused rather than accepted.
local function validStatus(value)
	return value == nil or type(value) == 'string' or type(value) == 'number'
end

-- ── the spec ────────────────────────────────────────────────────────────────

--- Validates a slider and settles its range, step and starting value.
-- A suffix past its length is cut, not refused.
local function normalizeSlider(slider)
	local settled, reason = OPX.Modal.SliderRange(slider)
	if settled == nil then return nil, reason end
	settled.suffix = clean(slider.suffix, MAX_SUFFIX) or ''
	return settled
end

--- Validates a choice list and settles which entry starts current.
local function normalizeChoices(item)
	if type(item.choices) ~= 'table' then return nil, 'invalid_choices' end
	local labels = {}
	for index = 1, #item.choices do
		local label = clean(item.choices[index], MAX_VALUE)
		if label == nil then return nil, 'invalid_choice' end
		labels[index] = label
	end
	if #labels == 0 then return nil, 'empty_choices' end
	local selected = finite(item.selected) and math.floor(item.selected) or 1
	-- Advisory, like every cursor: an out-of-range selection falls back rather
	-- than refusing a menu over a stale index.
	if selected < 1 or selected > #labels then selected = 1 end
	return { labels = labels, selected = selected }
end

-- Recurses, so it is declared before the row normaliser reaches for it.
local normalizeItems

-- ── rows that did not change ───────────────────────────────────────────────
--
-- A CALLER THAT HANDS THE SAME ROW BACK IS NOT CHECKED AGAIN. An update was a
-- full re-check of the spec, about 238 instructions a row, and a screen that
-- redraws keeps most of its rows as they were. A plain row (no `items`, no
-- `confirm`, no table nested deeper than one level) that passed is remembered
-- by identity with a shallow copy of every field and of every table it holds
-- (`data`, `choices`, `slider`). Handed back with every field the same, it
-- answers the entry it built for under half the cost. Anything else -- a field
-- changed, added or removed, an id that came from a position that moved, a row
-- the player adjusted since, a row used twice in one spec -- is checked from
-- scratch. Only a row that passed is remembered, so every refusal is the one
-- it always was, in the same order.
--
-- The memory is the live menu's own (`record.memo`): the rows of the spec it
-- was built from, replaced by each update that lands and dropped with the menu
-- -- the client sandbox has no weak tables, and this keeps nothing a closed
-- menu held. A row is copied the second spec it appears in, not the first, so
-- a caller that builds every row afresh pays a table write a row and no copy.

-- An empty memory, for a pass with no menu behind it.
local FORGOTTEN = {}

--- A fresh check budget, reading what `memo` remembered.
local function budgetOf(memo)
	return { nodes = 0, used = {}, memo = memo or FORGOTTEN, keep = {} }
end

-- A shallow copy of a table of plain values, and its size; nil for a table
-- that nests another.
local function flatCopy(value)
	local copy, count = {}, 0
	for key, nested in pairs(value) do
		if type(nested) == 'table' or type(key) == 'table' then return nil end
		copy[key] = nested
		count = count + 1
	end
	return copy, count
end

-- Whether a table still holds exactly the plain values copied.
local function sameAs(value, copy, size)
	if type(value) ~= 'table' then return false end
	local count = 0
	for key, nested in pairs(value) do
		if copy[key] ~= nested then return false end
		count = count + 1
	end
	return count == size
end

-- What to remember of a row that passed, or false for a row not worth it.
local function remember(item, index, entry)
	if item.items ~= nil or (item.confirm ~= nil and item.confirm ~= false) then return false end
	local fields, size, nested = {}, 0, nil
	for key, value in pairs(item) do
		if type(key) == 'table' then return false end
		if type(value) == 'table' then
			local copy, count = flatCopy(value)
			if copy == nil then return false end
			nested = nested or {}
			nested[#nested + 1] = { key = key, copy = copy, size = count }
		end
		fields[key] = value
		size = size + 1
	end
	return { entry = entry, index = index, fields = fields, size = size, nested = nested }
end

-- The entry a row built last time, when nothing it was built from changed.
local function recalled(item, memo, index, used)
	local entry = memo.entry
	if entry.touched or used[entry] then return nil end
	if item.id == nil and memo.index ~= index then return nil end
	if not sameAs(item, memo.fields, memo.size) then return nil end
	local nested = memo.nested
	if nested ~= nil then
		for slot = 1, #nested do
			local was = nested[slot]
			if not sameAs(item[was.key], was.copy, was.size) then return nil end
		end
	end
	used[entry] = true
	return entry
end

-- ── checking a spec in steps ────────────────────────────────────────────────
--
-- A SPEC IS CHECKED ROW BY ROW, about 240 instructions a row, inside the resume
-- that hands it over -- a twenty-row staff page was 6,000 to 9,000 on top of
-- whatever the caller had already spent. A caller running on a thread of its
-- own may say so with `yield = true` on the spec, and the rows are then checked
-- `PACE_ROWS` at a time with a frame between. Everything else is unchanged:
-- the same checks, the same refusals, the whole spec or nothing, and a caller
-- that does not say so -- or that says so from somewhere it cannot yield --
-- gets exactly the path it always had.
--
-- What a frame can change is checked again before anything is installed: the
-- surface, the down state and who holds the menu for an open; the handle for an
-- update. A caller is answered as though it had arrived after the change.
local PACE_ROWS = 6

-- Set while a paced check runs, nil otherwise: called once per row.
local pacing = nil

-- Checks a spec's rows, paced when the caller asked and can yield. Answers the
-- rows, the node count and whether it yielded, or nil and the refusal.
local function checkRows(spec, memo)
	local paced = spec.yield == true and type(Wait) == 'function' and coroutine.isyieldable()
	local budget = budgetOf(memo)
	if not paced then
		local items, reason = normalizeItems(spec.items, 1, budget)
		if items == nil then return nil, reason end
		return { items = items, nodes = budget.nodes, yielded = false, memo = budget.keep }
	end
	local count, yielded = 0, false
	pacing = function()
		count = count + 1
		if count % PACE_ROWS == 0 then
			yielded = true
			Wait(0)
		end
	end
	local ran, items, reason = pcall(normalizeItems, spec.items, 1, budget)
	pacing = nil
	if not ran then error(items, 0) end
	if items == nil then return nil, reason end
	return { items = items, nodes = budget.nodes, yielded = yielded, memo = budget.keep }
end

--- Normalises one row and derives its kind from its shape.
-- The tests run in a fixed order and the first match wins, so a row carrying
-- both `toggle` and `choices` is a toggle and the choice list is dropped.
local function normalizeItem(item, index, depth, budget)
	if type(item) ~= 'table' then return nil, 'item_must_be_a_table' end

	budget.nodes = budget.nodes + 1
	if budget.nodes > MAX_NODES then return nil, 'menu_too_large' end

	local id = item.id
	if id == nil then
		id = 'item_' .. tostring(index)
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_item_id'
	end

	-- A separator returns before anything else is read: a description, a data
	-- table or a disabled flag on one is dropped rather than refused.
	if item.separator == true then
		return { id = id, kind = 'separator', label = clean(item.label, MAX_LABEL) or '' }
	end

	-- `confirm` ON A ROW THAT DOES SOMETHING: the row becomes a two-row level
	-- whose FIRST row keeps things as they are (so Enter pressed without looking
	-- does nothing) and whose second does what the row said, under the same id
	-- and data, so the caller hears exactly the select it always heard. Callers
	-- used to build this by hand, or not at all. `confirm = true` takes the
	-- words from the catalogue; a table may name `title`, `yes` and `no`.
	if item.confirm ~= nil and item.confirm ~= false and item.items == nil then
		local ask = type(item.confirm) == 'table' and item.confirm or {}
		local named = clean(item.label or item.text, MAX_LABEL)
		if named == nil or named == '' then return nil, 'invalid_item_label' end
		local yes = {}
		for field, value in pairs(item) do yes[field] = value end
		yes.confirm = nil
		yes.label = clean(ask.yes, MAX_LABEL) or locale('menu.confirm.yes', { label = named })
		yes.icon = 'warning'
		item = {
			id = id, label = named, icon = item.icon, description = item.description,
			disabled = item.disabled, value = item.value,
			title = clean(ask.title, MAX_LABEL) or locale('menu.confirm.title', { label = named }),
			items = {
				{ id = tostring(id) .. '_keep', icon = 'back', back = true,
					label = clean(ask.no, MAX_LABEL) or locale('menu.confirm.no') },
				yes,
			},
		}
	end

	local label = clean(item.label or item.text, MAX_LABEL)
	if label == nil or label == '' then return nil, 'invalid_item_label' end

	-- Cleaned once and kept: the row below used to clean it a second time.
	local description = clean(item.description, MAX_DESCRIPTION)
	if item.description ~= nil and description == nil then
		return nil, 'invalid_item_description'
	end
	local fault = dataFault(item.data, 'invalid_item_data', 'item_data_too_large')
	if fault then return nil, fault end

	-- The glyph replaced the row's ordinal. A number told the player which row
	-- they were on, which the cursor already says; an icon says what the row IS,
	-- which nothing else on the strip does. Refused rather than dropped when it
	-- is not in the set: a caller who misspelt `vehcile` wants to hear about it
	-- now, not to wonder later why one row in ten has no picture.
	local icon = item.icon
	if icon ~= nil then
		if type(icon) ~= 'string' or not M.ICONS[icon] then return nil, 'invalid_item_icon' end
	end

	-- A ROW THAT LEADS SOMEWHERE WITHOUT CARRYING THE LEVEL BEHIND IT.
	--
	-- `arrow` used to be derived from one thing only -- whether the row had an
	-- `items` list under it -- which was right for a small static tree and wrong
	-- for everything that actually uses this contract. The staff menu and the
	-- emote picker both hold their own stack and open ONE FLAT SCREEN at a time,
	-- because the whole tree in one spec goes past the host's 1024-value bound.
	-- So every one of their navigation rows was an `action` and drew exactly like
	-- the rows that fire a command: the player could not tell "this opens a list"
	-- from "this does something", which is the one thing the affordance column
	-- exists to say.
	--
	-- `submenu = true` is that row saying it. It changes NOTHING else -- the row
	-- still reports `select` and its owner still decides what that meant -- and a
	-- row with real `items` under it does not need it, because the arrow is
	-- derived there anyway.
	local entry = {
		id = id,
		label = label,
		icon = icon,
		description = description,
		data = item.data,
		disabled = item.disabled == true,
		close = item.close == true or nil,
		act = type(item.act) == 'function' and item.act or nil,
		leads = item.submenu == true or nil,
	}

	if item.items ~= nil then
		if depth >= MAX_DEPTH then return nil, 'menu_too_deep' end
		local children, reason = normalizeItems(item.items, depth + 1, budget)
		if children == nil then return nil, reason end
		entry.kind = 'submenu'
		entry.items = children
		entry.title = clean(item.title, MAX_LABEL) or label
		entry.value = clean(item.value, MAX_VALUE)
		entry.cursor = item.cursor
		return entry
	end

	-- The TYPE of `toggle` is what makes a toggle, never its truthiness: a
	-- toggle that starts false is the common case.
	if type(item.toggle) == 'boolean' then
		entry.kind = 'toggle'
		entry.on = item.toggle
		entry.labels = {
			on = clean(item.onLabel, MAX_VALUE),
			off = clean(item.offLabel, MAX_VALUE),
		}
		return entry
	end

	if item.choices ~= nil then
		local choices, reason = normalizeChoices(item)
		if choices == nil then return nil, reason end
		entry.kind = 'choices'
		entry.choices = choices.labels
		entry.selected = choices.selected
		return entry
	end

	if item.slider ~= nil then
		local slider, reason = normalizeSlider(item.slider)
		if slider == nil then return nil, reason end
		entry.kind = 'slider'
		entry.slider = slider
		return entry
	end

	if item.back == true then
		entry.kind = 'back'
		return entry
	end

	-- A close row is `close` with no callback of its own. A row carrying both
	-- stays an action that also closes, which is why the test looks at `act`.
	if item.close == true and entry.act == nil then
		entry.kind = 'close'
		return entry
	end

	entry.kind = 'action'
	entry.value = clean(item.value, MAX_VALUE)
	return entry
end

--- Normalises one level, refusing it whole on the first fault.
normalizeItems = function(items, depth, budget)
	if type(items) ~= 'table' then return nil, 'items_must_be_a_table' end
	local total = #items
	-- Counted before any row is normalised, so a caller handing over a thousand
	-- rows is told at once rather than after nine hundred of them were built.
	if total > MAX_ROWS then return nil, 'too_many_items' end

	local list = {}
	local used, remembered, keep = budget.used, budget.memo, budget.keep
	for index = 1, total do
		if pacing ~= nil then pacing() end
		local item = items[index]
		-- `false` is a row seen once and not yet worth a copy.
		local memo = remembered[item]
		local entry = memo and recalled(item, memo, index, used) or nil
		if entry ~= nil then
			-- Counted as a row checked afresh would be, and refused the same way.
			budget.nodes = budget.nodes + 1
			if budget.nodes > MAX_NODES then return nil, 'menu_too_large' end
			keep[item] = memo
		else
			local reason
			entry, reason = normalizeItem(item, index, depth, budget)
			if entry == nil then return nil, reason end
			if memo == nil then
				if keep[item] == nil then keep[item] = false end
			else
				used[entry] = true
				keep[item] = remember(item, index, entry)
			end
		end
		list[index] = entry
	end
	if #list == 0 then return nil, 'empty_menu' end

	local substantial = false
	for index = 1, #list do
		if list[index].kind ~= 'separator' then substantial = true break end
	end
	-- A level of nothing but disabled rows is a real menu; a level of nothing
	-- but separators leaves the cursor nowhere to stand.
	if not substantial then return nil, 'only_separators' end
	return list
end

-- ── the navigation stack ────────────────────────────────────────────────────

--- Whether the cursor may rest on a row.
local function selectable(entry)
	return entry ~= nil and entry.kind ~= 'separator' and not entry.disabled
end

--- The row a named cursor resolves to, or the first selectable one.
local function cursorIndex(items, wanted)
	if type(wanted) == 'string' then
		for index = 1, #items do
			if items[index].id == wanted and selectable(items[index]) then return index end
		end
	elseif finite(wanted) and wanted % 1 == 0 then
		local index = math.floor(wanted)
		if selectable(items[index]) then return index end
	end
	for index = 1, #items do
		if selectable(items[index]) then return index end
	end
	return 1
end

--- One screen of the navigation stack.
local function screen(items, title, id, cursor)
	return { items = items, title = title, id = id, index = cursorIndex(items, cursor) }
end

--- The screen on top of the stack.
local function top(owned)
	return owned.stack[#owned.stack]
end

--- The row under the cursor.
local function current(owned)
	local screenAt = top(owned)
	return screenAt.items[screenAt.index]
end

--- Moves the cursor to the next selectable row, wrapping around.
local function move(owned, delta)
	local screenAt = top(owned)
	local total = #screenAt.items
	local index = screenAt.index
	for _ = 1, total do
		index = ((index - 1 + delta) % total) + 1
		if selectable(screenAt.items[index]) then
			if index == screenAt.index then return false end
			screenAt.index = index
			return true
		end
	end
	return false
end

--- Puts the cursor back on a selectable row after a rebuild disabled its own.
local function settle(owned)
	local screenAt = top(owned)
	if selectable(screenAt.items[screenAt.index]) then return end
	for index = 1, #screenAt.items do
		if selectable(screenAt.items[index]) then screenAt.index = index return end
	end
end

--- Whether LEFT and RIGHT change this row's value rather than navigate.
local function holdsValue(entry)
	local kind = entry.kind
	return kind == 'toggle' or kind == 'choices' or kind == 'slider'
end

--- Steps a toggle, a choice list or a slider, answering whether it moved.
local function adjust(entry, delta)
	if entry.disabled then return false end
	-- Rebuilt from the spec on the next update, as before, not answered as it stands.
	entry.touched = true
	local kind = entry.kind
	if kind == 'toggle' then
		entry.on = not entry.on
		return true
	elseif kind == 'choices' then
		local total = #entry.choices
		if total <= 1 then return false end
		entry.selected = ((entry.selected - 1 + delta) % total) + 1
		return true
	elseif kind == 'slider' then
		return OPX.Modal.StepSlider(entry.slider, delta)
	end
	return false
end

--- The right-hand text drawn for a row.
local function shownValue(entry)
	local kind = entry.kind
	if kind == 'toggle' then
		if entry.on then return entry.labels.on end
		return entry.labels.off
	elseif kind == 'choices' then
		return entry.choices[entry.selected]
	elseif kind == 'slider' then
		local slider = entry.slider
		local number = slider.value
		local shown = number % 1 == 0 and tostring(math.floor(number))
			or string.format('%.2f', number)
		return shown .. slider.suffix
	end
	return entry.value
end

--- A row's machine-readable value, for the payload the caller reads.
local function rawValue(entry)
	local kind = entry.kind
	if kind == 'toggle' then return entry.on end
	if kind == 'choices' then return entry.choices[entry.selected] end
	if kind == 'slider' then return entry.slider.value end
	return entry.value
end

-- ── geometry ───────────────────────────────────────────────────────────────

--- The anchors a caller may name, and the bounds each block is held to.
-- A menu down an edge is a strip and a menu in the middle is a panel, and only the
-- caller knows which one it needs: a dealer's stock list is read at a glance from
-- across the shop floor, while a two-row confirm wants none of that room. The
-- module's own settings are the default, so a caller that names nothing gets
-- exactly what it got before this block existed.
local ANCHORS = { ['top-left'] = true, ['top-right'] = true, left = true, right = true, center = true }
local WIDTH_BOUNDS = { 240, 1200 }
local HEIGHT_BOUNDS = { 20, 100 }
local ROW_BOUNDS = { 3, 24 }
-- A HEIGHT IN PIXELS, which is the one geometry a caller may leave unsaid -- and the
-- one that is not a cap. Height usually follows the list, so `maxHeight` is enough for
-- every menu that is a strip of rows. A caller that names this one gets a panel whose
-- height is its own rather than its rows', which is what makes a SQUARE panel possible:
-- at a width wide enough to read a price list, a four-row level would otherwise draw a
-- bar. Clamped like the rest, and absent by default, so a caller that names nothing
-- back there with the module's own shape rather than being padded to a square.
local PANEL_BOUNDS = { 120, 1200 }

--- A whole number inside its bounds, or the fallback when there is no number.
-- Clamped rather than refused: a menu that opens at the wrong size is better than
-- a menu that does not open, and the caller is in the client's own runtime.
-- A NIL fallback is a geometry the caller may leave unsaid at all (`height`), and a
-- caller that left it unsaid is handed nil rather than a default: the page has to see
-- the key ABSENT to draw a strip its rows make.
local function held(value, bounds, fallback)
	local number = finite(value) and math.floor(value) or nil
	if number == nil then number = fallback end
	if number == nil then return nil end
	if number < bounds[1] then return bounds[1] end
	if number > bounds[2] then return bounds[2] end
	return number
end

--- The size and anchor this open draws at: the caller's, else the configured one.
local function geometry(spec)
	local settings = M.Settings
	local anchor = spec.anchor
	if type(anchor) ~= 'string' or not ANCHORS[anchor] then
		anchor = type(settings.ANCHOR) == 'string' and ANCHORS[settings.ANCHOR] and settings.ANCHOR or 'top-left'
	end
	return {
		anchor = anchor,
		width = held(spec.width, WIDTH_BOUNDS, held(settings.WIDTH, WIDTH_BOUNDS, 340)),
		maxHeight = held(spec.maxHeight, HEIGHT_BOUNDS, held(settings.MAX_HEIGHT_VH, HEIGHT_BOUNDS, 56)),
		height = held(spec.height, PANEL_BOUNDS, nil),
		rows = held(spec.rows, ROW_BOUNDS, held(settings.VISIBLE_ROWS, ROW_BOUNDS, 9)),
	}
end

-- ── building and rebuilding ─────────────────────────────────────────────────

--- Builds a menu record from a caller's spec, or refuses it whole.
local function build(owner, spec, checked, memo)
	if type(spec.on) ~= 'function' then return nil, 'callback_required' end

	local id = spec.id
	if id == nil then
		id = owner
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_menu_id'
	end

	local title = Text.Clean(spec.title, MAX_LABEL)
	if title == nil or title == '' then title = owner:upper() end

	if not validStatus(spec.status) then return nil, 'invalid_status' end

	local fault = dataFault(spec.data, 'invalid_menu_data', 'menu_data_too_large')
	if fault then return nil, fault end

	-- HOW THE MENU TAKES INPUT. It used to be one answer for every menu -- the
	-- page took the keyboard -- and taking the keyboard is taking the movement
	-- keys, so every menu froze the player where they stood whether or not it
	-- had any reason to. `cursor` is the mode for a menu that is meant to sit
	-- open while the player walks; see `M.FOCUS_MODES`.
	local focus = spec.focus
	-- THE DEFAULT IS `none`: the menu takes NOTHING, and the player keeps both the
	-- keyboard and the mouse.
	--
	-- It was `full` and the player could not move. It was then `cursor` on the
	-- strength of the platform's own native card, which says in as many words that
	-- `setFocus(false, true)` "takes only the mouse" so a page can have the pointer
	-- "without depriving the game of the movement keys". On this build that is not
	-- what happens -- taking the cursor alone still froze the player, and the third
	-- argument that would have kept game input alive needs `webui.keep_input`, a
	-- permission the build's own catalogue does not contain. Documented, and not
	-- there. So the mouse is given up rather than the walking.
	--
	-- Nothing is lost that the surface needs: Lua reads the six keys itself (see
	-- `pollKeys`), Escape arrives on `open77:pauseKey`, and a menu is navigated the
	-- way it always was. `cursor` and `full` remain for a caller that wants them --
	-- a menu that genuinely owns the player is now a choice somebody makes, rather
	-- than what happens by not thinking about it.
	if focus == nil or focus == true then
		focus = 'none'
	elseif focus == false then
		focus = 'none'
	end
	if type(focus) ~= 'string' or M.FOCUS_MODES[focus] == nil then
		return nil, 'invalid_focus'
	end

	-- WHETHER THE PLAYER MAY DISMISS IT. Default true, because a menu the player
	-- cannot close is a menu that can trap them, and every menu before this one
	-- could be escaped. False belongs to a menu whose owner is driving something
	-- the player must answer -- and the owner is then the only thing that can
	-- close it, so a `false` here is a promise to call `Close`.
	if spec.closable ~= nil and type(spec.closable) ~= 'boolean' then
		return nil, 'invalid_closable'
	end

	-- WHERE IT DRAWS AND HOW MUCH OF IT. Settled once, at open: an update rebuilds
	-- the rows of the menu that is up and is not the moment to move it.
	local where = geometry(spec)

	local items, nodes, kept
	if checked ~= nil then
		items, nodes, kept = checked.items, checked.nodes, checked.memo
	else
		local budget = budgetOf(memo)
		local reason
		items, reason = normalizeItems(spec.items, 1, budget)
		if items == nil then return nil, reason end
		nodes, kept = budget.nodes, budget.keep
	end

	return {
		owner = owner,
		id = id,
		title = title,
		anchor = where.anchor,
		width = where.width,
		maxHeight = where.maxHeight,
		height = where.height,
		rows = where.rows,
		on = spec.on,
		data = spec.data,
		focus = focus,
		closable = spec.closable ~= false,
		closeOnSelect = spec.closeOnSelect == true,
		reportFocus = spec.reportFocus == true,
		items = items,
		nodes = nodes,
		memo = kept,
		stack = { screen(items, title, nil, spec.cursor) },
	}
end

--- Re-walks the navigation stack onto a rebuilt tree, by id.
-- An update must not throw the player back to the root: a submenu they are
-- standing in stays open while a row with the same id and kind is still there,
-- and the walk stops at the first level where it is not.
local function rewalk(owned, items, title)
	local root = math.min(owned.stack[1].index, #items)
	local stack = { screen(items, title, nil, root) }
	local level = items
	for depth = 2, #owned.stack do
		local previous = owned.stack[depth]
		local found
		for index = 1, #level do
			local entry = level[index]
			if entry.id == previous.id and entry.kind == 'submenu' then found = entry break end
		end
		if found == nil then break end
		stack[#stack + 1] = screen(found.items, found.title, found.id, previous.index)
		level = found.items
	end
	return stack
end

--- Patches a live menu from a spec, keeping the player's position.
-- `items` is all-or-nothing: the whole tree is rebuilt, or the whole call is
-- refused and the live menu is untouched.
local function rebuild(owned, spec, checked)
	if not validStatus(spec.status) then return false, 'invalid_status' end
	if spec.on ~= nil and type(spec.on) ~= 'function' then return false, 'callback_required' end

	local items, nodes, kept
	if checked ~= nil then
		items, nodes, kept = checked.items, checked.nodes, checked.memo
	elseif spec.items ~= nil then
		local budget = budgetOf(owned.memo)
		local built, reason = normalizeItems(spec.items, 1, budget)
		if built == nil then return false, reason end
		items, nodes, kept = built, budget.nodes, budget.keep
	end

	local title
	if spec.title ~= nil then
		title = Text.Clean(spec.title, MAX_LABEL)
		if title == nil or title == '' then title = owned.owner:upper() end
	end

	local fault = dataFault(spec.data, 'invalid_menu_data', 'menu_data_too_large')
	if fault then return false, fault end

	if items ~= nil then
		owned.items = items
		owned.nodes = nodes
		owned.memo = kept
	end
	if title ~= nil then owned.title = title end
	if spec.on ~= nil then owned.on = spec.on end
	if spec.data ~= nil then owned.data = spec.data end
	if spec.closeOnSelect ~= nil then owned.closeOnSelect = spec.closeOnSelect == true end
	if spec.reportFocus ~= nil then owned.reportFocus = spec.reportFocus == true end

	owned.stack = rewalk(owned, owned.items, owned.title)

	-- WHERE THE CURSOR LANDS, for a caller that replaced the SCREEN rather than
	-- redrew it. `rewalk` keeps the player's position, which is exactly right for a
	-- redraw of the screen they are standing on and meaningless for one that has
	-- just taken its place: the row at that position is a different row, and a
	-- caller that put a whole level up deserves the same landing an `Open` would
	-- have given it. Absent, nothing moves -- every existing caller is unchanged.
	if spec.cursor ~= nil then
		local screenAt = owned.stack[#owned.stack]
		screenAt.index = cursorIndex(screenAt.items, spec.cursor)
	end
	return true
end

-- ── the frame ───────────────────────────────────────────────────────────────

--- The first row drawn, keeping the cursor near the middle of the window.
local function windowFirst(index, total, rows)
	if total <= rows then return 1 end
	local first = index - (rows // 2)
	if first < 1 then first = 1 end
	if first > total - rows + 1 then first = total - rows + 1 end
	return first
end

--- The breadcrumb, built from the titles on the stack.
local function trail(owned)
	local parts = {}
	for depth = 1, #owned.stack do parts[depth] = owned.stack[depth].title or '' end
	return table.concat(parts, ' / ')
end

--- How many rows the page draws at once: the menu's own, else the configured one.
local function visibleRows(owned)
	local rows = owned and owned.rows or M.Settings.VISIBLE_ROWS
	if finite(rows) and rows >= 1 then return math.floor(rows) end
	return 9
end

--- The window of rows the page draws, and everything around it.
local function frame(owned)
	local screenAt = top(owned)
	local rows = visibleRows(owned)
	local total = #screenAt.items
	local first = windowFirst(screenAt.index, total, rows)
	local window = {}
	for index = first, math.min(first + rows - 1, total) do
		local entry = screenAt.items[index]
		local kind = entry.kind
		local toggle = kind == 'toggle'
		window[index - first + 1] = {
			label = entry.label,
			icon = entry.icon,
			value = shownValue(entry),
			check = toggle or nil,
			ticked = (toggle and entry.on) or nil,
			arrow = (kind == 'submenu' or entry.leads == true) or nil,
			spin = holdsValue(entry) or nil,
			rule = kind == 'separator' or nil,
			off = entry.disabled or nil,
			on = (index == screenAt.index) or nil,
		}
	end

	return {
		handle = owned.handle,
		title = screenAt.title,
		trail = #owned.stack > 1 and trail(owned) or nil,
		rows = window,
		first = first,
		total = total,
		hint = current(owned).description,
	}
end

-- ── the surface ─────────────────────────────────────────────────────────────

--- Sends the open payload: the configuration and the first frame in one, which
--- is what the page's open handler reads.
local function sendOpen()
	local payload = frame(record)
	-- The record's own geometry, not the settings again: the settings are only what
	-- a caller that named nothing was given.
	payload.anchor = record.anchor
	payload.width = record.width
	payload.maxHeight = record.maxHeight
	-- Absent when the caller named none, so the page draws the panel its rows make.
	payload.height = record.height
	-- The page decides whether to ASK for focus, because only the page can see
	-- the keystrokes it would be asking for. Lua decides what asking is worth:
	-- `FOCUS.menu` below is what an ask is actually granted.
	payload.focus = record.focus
	payload.closable = record.closable
	return OPX.UI.Send(SURFACE, 'menu:open', payload)
end

--- Draws whatever is open. While the open has not landed it is re-sent instead
--- of a frame: a frame for a menu the page has never heard of is dropped.
local function draw()
	if record == nil then return end
	if pendingOpen then
		pendingOpen = not sendOpen()
		return
	end
	OPX.UI.Send(SURFACE, 'menu:frame', frame(record))
end

-- ── the answers a caller gets ───────────────────────────────────────────────

--- Builds the one payload shape every menu action carries.
local function payloadOf(owned, entry, action)
	local screenAt = top(owned)
	local payload = {
		menu = owned.id,
		handle = owned.handle,
		owner = owned.owner,
		action = action,
		itemId = entry and entry.id or nil,
		label = entry and entry.label or nil,
		index = screenAt.index,
		depth = #owned.stack,
		data = entry and entry.data or nil,
		menuData = owned.data,
	}
	-- Assigned by presence, never folded through an `and`/`or`: a false toggle
	-- is a legitimate value and nil means no row was involved.
	if entry ~= nil then payload.value = rawValue(entry) end
	return payload
end

--- Hands one payload to the caller and to the local bus.
-- The callback runs under pcall because it may open, update or close a menu --
-- including this one -- and a raise inside it must not take the page handler
-- down with it.
local function dispatch(owned, entry, action, reason)
	local payload = payloadOf(owned, entry, action)
	payload.reason = reason

	if entry ~= nil and entry.act ~= nil then
		local ran, failure = pcall(entry.act, payload)
		if not ran then
			Open77.log.error(('[menu] %s row %s raised: %s')
				:format(owned.owner, tostring(entry.id), tostring(failure)))
		end
	end

	local ran, failure = pcall(owned.on, payload)
	if not ran then
		Open77.log.error(('[menu] %s callback raised on %s: %s')
			:format(owned.owner, action, tostring(failure)))
	end
	TriggerEvent(M.Event.ACTION, payload)
end

--- Raises focus for the row under the cursor, for a menu that asked for it.
local function reportFocus(repeated)
	if record == nil or not record.reportFocus then return end
	local payload = payloadOf(record, current(record), 'focus')
	-- The browser repeats a held arrow far faster than the old 55 ms machine
	-- did, so a caller that has to follow the cursor can cheapen a repeat.
	payload.repeated = repeated == true or nil
	local owned = record
	local ran, failure = pcall(owned.on, payload)
	if not ran then
		Open77.log.error(('[menu] %s callback raised on focus: %s')
			:format(owned.owner, tostring(failure)))
	end
	TriggerEvent(M.Event.ACTION, payload)
end

-- ── opening, closing and patching ───────────────────────────────────────────

local wire
local setPolling

--- Raises a caller's status as a TOAST instead of a line under the list.
--
-- THE STATUS LINE IS GONE FROM THE STRIP. It was a second, weaker notification
-- channel: toggling nametags wrote "nametags on" into the menu's footer, where it
-- is only visible to a player already looking at the menu, and then expired on a
-- timer nobody was watching. The runtime already has one channel for "that
-- worked" and "that failed", and it is the toast.
--
-- `SetStatus` is NOT removed, because removing it would mean editing every caller
-- to say the same thing a different way -- `modules/admin/client/menu.lua` alone
-- calls it on every command it runs. It is rerouted instead, so a caller writes
-- the same line and the player actually sees it.
--
-- One id per menu, so a player running the same command twice sees one answer
-- replaced rather than a pile of them.
local function writeStatus(owned, text, bad)
	local clean = text ~= nil and Text.Clean(text, MAX_STATUS) or nil
	if clean == nil or clean == '' then return end
	-- THE ANSWER IS CHECKED, because it can be refused. `OPX.Toast.Show` answers
	-- nil for a surface that is not up, and this used to discard that: the notice
	-- went nowhere and said so to nobody. Six other modules already fall back to
	-- the client journal on this exact path; these three did not, and the toast's
	-- own docstring claimed they did.
	local raised = OPX.Toast.Show({
		id = 'menu:' .. tostring(owned.id),
		kind = bad == true and 'error' or 'success',
		message = clean,
	})
	if raised == nil then Open77.log.info('[menu] ' .. clean) end
end

--- Closes the open menu and tells its owner why.
local function closeNow(handle, reason)
	if record == nil then return false, 'no_menu_open' end
	if handle ~= nil and handle ~= record.handle then return false, 'stale_handle' end

	local closing = record
	record = nil
	pendingOpen = false
	setPolling(false)
	OPX.UI.Send(SURFACE, 'menu:close', { handle = closing.handle })
	-- Released here rather than waited for: the page announces the release on
	-- `focus:set` too, but a page that is gone never will, and a focus held
	-- across a close is a player who cannot move.
	OPX.UI.ReleaseFocus(OWNER)
	-- NOT WHEN ANOTHER MENU IS TAKING THIS ONE'S PLACE. `Open` closes the
	-- standing menu before it installs its own, so a bare `announce()` here
	-- raised `false` and then `true` for what is, to anybody standing aside,
	-- one continuous menu -- and the HUD would come back for a frame in the
	-- middle of it. Caught by the check that asserts a replacement says nothing,
	-- which failed with `1 -> 3` the first time it ran.
	--
	-- The two reasons are `Open`'s own words for exactly that case, and no other
	-- caller uses them.
	if reason ~= 'reopened' and reason ~= 'superseded' then announce() end
	-- The menu is already gone when this is raised, so a close handler may open
	-- another one.
	dispatch(closing, nil, 'close', reason)
	return true
end

-- THE DOWN STATE, THE OWNER SWEEP, ESCAPE AND THE UPKEEP PASS are `OPX.Modal`'s,
-- one implementation for `menu`, `form` and `panel`. What is the menu's own is
-- how it closes, what Escape does and what a pass re-sends.
--
-- Escape is swallowed by the plugin before any surface sees it; when it arrives
-- on the pause key rather than on `menu:dismiss`, the reason is the pause menu.
-- It is also the ONLY route Escape has in `cursor` mode: the page never sees a
-- keystroke it does not hold the keyboard for, so `bridge/focus.ts` never runs
-- and `menu:dismiss` never arrives. A menu its owner declared unclosable is left
-- alone for the same reason the page withholds its Escape handler -- otherwise
-- `closable = false` would hold against one key and not the other. An
-- unclosable menu on top still takes the press, and does nothing with it, so
-- what is under it stays too.
local life = OPX.Modal.New({
	name = 'menu',
	current = function() return record end,
	close = function(reason) closeNow(record.handle, reason) end,
	settings = function() return M.Settings end,
	pauseKey = M.Host.PAUSE_KEY,
	pause = function(owned)
		if owned.closable then closeNow(owned.handle, 'pause') end
	end,
	job = 'menu:upkeep',
	everyMs = UPKEEP_MS,
	-- The open is re-sent until the page reports ready: a surface built on first
	-- use is not ready when the first menu opens on it.
	upkeep = function()
		if pendingOpen then draw() end
	end,
})

--- Opens a menu, replacing the caller's own or, with `steal`, another's.
-- @author dop42
-- @param spec table
-- @return Result
local function Open(spec)
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local owner = spec.owner
	-- There is no invoking resource inside one runtime, so a caller names
	-- itself. Two anonymous callers would look like one owner and replace each
	-- other's menus in silence instead of refusing with menu_busy.
	if not validName(owner, MAX_NAME) then return Result.Err('invalid_owner') end

	-- Nothing to draw on, and there never will be at this start.
	if OPX.UI.Interactive() == nil then return Result.Err('no_surface') end

	if life.Blocked(owner) then return Result.Err('player_down') end
	if record ~= nil and record.owner ~= owner and spec.steal ~= true then
		return Result.Err('menu_busy')
	end

	-- A caller on its own thread may have the rows checked in steps (see
	-- `checkRows`); whatever a frame changed is checked again before this goes on.
	-- What the menu up now remembers of its rows (see `remember`): a reopen that
	-- hands the same rows back is not checked again either.
	local memo = record and record.memo or nil
	local checked
	if spec.yield == true then
		local rowsReason
		checked, rowsReason = checkRows(spec, memo)
		if checked == nil then return Result.Err(rowsReason) end
		if checked.yielded then
			if OPX.UI.Interactive() == nil then return Result.Err('no_surface') end
			if life.Blocked(owner) then return Result.Err('player_down') end
			if record ~= nil and record.owner ~= owner and spec.steal ~= true then
				return Result.Err('menu_busy')
			end
		end
	end

	-- Built before the live menu is taken down, so a refused spec costs the
	-- player nothing.
	local built, reason = build(owner, spec, checked, memo)
	if built == nil then return Result.Err(reason) end

	-- What a close callback opens in turn is closed too (see `Supersede`).
	if record ~= nil then life.Supersede(record.owner == owner and 'reopened' or 'superseded') end

	nextHandle = nextHandle + 1
	built.handle = nextHandle
	built.openedAtMs = OPX.Now()
	record = built
	announce()
	-- Set BEFORE the page is told to open: the page announces `focus:set` during
	-- its own open handler, and `onFocus` reads this to answer it.
	FOCUS.menu = M.FOCUS_MODES[built.focus]
	-- A menu the page does not hold the keyboard for is one Lua reads the keys
	-- of, so the arrows still work while the player walks.
	setPolling(built.focus ~= 'full')
	settle(record)
	if spec.status ~= nil then writeStatus(record, spec.status, spec.statusBad) end

	wire()
	pendingOpen = true
	draw()
	return Result.Ok({ handle = record.handle, id = record.id, nodes = record.nodes })
end

--- Closes a menu the caller holds the handle of.
-- The handle is the capability: a caller answering about a menu that has
-- already gone would otherwise kill the view that replaced it.
-- @author dop42
-- @param handle integer
-- @param reason string|nil
-- @return Result
local function Close(handle, reason)
	if handle == nil then return Result.Err('handle_required') end
	local clean = Text.Clean(reason, 32)
	local closed, failure = closeNow(handle, (clean ~= nil and clean ~= '') and clean or 'caller')
	if not closed then return Result.Err(failure) end
	return Result.Ok(true)
end

--- Rebuilds the open menu from a fresh spec, keeping the player where they are.
-- @author dop42
-- @param handle integer|table the handle, or the spec for the open menu
-- @param spec table|nil
-- @return Result
local function Update(handle, spec)
	if spec == nil and type(handle) == 'table' then handle, spec = nil, handle end
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end
	if record == nil then return Result.Err('no_menu_open') end
	if handle ~= nil and handle ~= record.handle then return Result.Err('stale_handle') end

	-- Paced like `Open`, and the menu it was asked about must still be the one
	-- up afterwards: a frame can close it, or put another in its place.
	local checked
	if spec.yield == true and spec.items ~= nil then
		local owned = record
		local rowsReason
		checked, rowsReason = checkRows(spec, owned.memo)
		if checked == nil then return Result.Err(rowsReason) end
		if checked.yielded then
			if record == nil then return Result.Err('no_menu_open') end
			if record ~= owned then return Result.Err('stale_handle') end
		end
	end

	local ok, reason = rebuild(record, spec, checked)
	if not ok then return Result.Err(reason) end
	settle(record)
	if spec.status ~= nil then writeStatus(record, spec.status, spec.statusBad) end
	draw()
	return Result.Ok(true)
end

--- Raises the caller's line as a toast (see `writeStatus`); a nil or empty text says nothing.
-- @author dop42
-- @param handle integer
-- @param text string|number|nil
-- @param bad boolean|nil True raises it as a failure.
-- @return Result
local function SetStatus(handle, text, bad)
	if record == nil then return Result.Err('no_menu_open') end
	if handle ~= nil and handle ~= record.handle then return Result.Err('stale_handle') end
	if not validStatus(text) then return Result.Err('invalid_status') end
	-- A toast, not a line in the frame: there is nothing to redraw.
	writeStatus(record, text, bad)
	return Result.Ok(true)
end

--- What is on screen: the menu, the screen, and the row under the cursor.
-- @author dop42
-- @return Result
local function State()
	if record == nil then return Result.Ok({ open = false }) end
	local screenAt = top(record)
	local entry = current(record)
	return Result.Ok({
		open = true,
		handle = record.handle,
		owner = record.owner,
		menu = record.id,
		title = screenAt.title,
		depth = #record.stack,
		index = screenAt.index,
		total = #screenAt.items,
		itemId = entry.id,
		label = entry.label,
		value = rawValue(entry),
	})
end

--- The keys that drive the menu, for a caller printing its own hint.
-- The page reads them now, so they are the browser's own names and are not
-- rebindable; `backend` is `none` when there is no surface to read them on.
-- @author dop42
-- @return Result
local function Keys()
	if OPX.UI.Interactive() == nil then
		return Result.Ok({ backend = 'none', keys = {}, labels = {} })
	end
	return Result.Ok({
		backend = 'page',
		keys = {
			UP = 'ARROW UP', DOWN = 'ARROW DOWN',
			LEFT = 'ARROW LEFT', RIGHT = 'ARROW RIGHT',
			SELECT = 'ENTER', BACK = 'BACKSPACE',
		},
		labels = {
			UP = locale('menu.key.choose'), DOWN = locale('menu.key.choose'),
			LEFT = locale('menu.key.change'), RIGHT = locale('menu.key.change'),
			SELECT = locale('menu.key.select'), BACK = locale('menu.key.back'),
		},
	})
end

-- ── what the player did ─────────────────────────────────────────────────────

--- ENTER on the row under the cursor. Answers whether the frame changed.
local function activate()
	local entry = current(record)
	if entry.disabled or entry.kind == 'separator' then return false end
	local kind = entry.kind

	if kind == 'submenu' then
		record.stack[#record.stack + 1] =
			screen(entry.items, entry.title, entry.id, entry.cursor)
		settle(record)
		-- Raised after the push, so depth and index already describe the child.
		dispatch(record, entry, 'open')
		return true
	end

	if kind == 'back' then
		if #record.stack > 1 then
			record.stack[#record.stack] = nil
			dispatch(record, entry, 'back')
			return true
		end
		-- Nothing left to pop: at the root a back row closes the menu.
		closeNow(record.handle, 'back')
		return false
	end

	if kind == 'close' then
		closeNow(record.handle, 'item')
		return false
	end

	if holdsValue(entry) then
		if adjust(entry, 1) then
			dispatch(record, entry, 'change')
			return true
		end
		return false
	end

	local closeAfter = entry.close or record.closeOnSelect
	local handle = record.handle
	dispatch(record, entry, 'select')
	-- The handler may have closed this menu, or opened another over it.
	if record == nil or record.handle ~= handle then return false end
	if closeAfter then
		closeNow(handle, 'select')
		return false
	end
	return true
end

--- The open menu when a page payload names it, or nil for a stale one.
local fromPage = life.FromPage

--- One key the page forwarded.
local function onKey(payload)
	if fromPage(payload) == nil then return end
	local key = payload.key
	if type(key) ~= 'string' or not KEYS[key] then return end
	local repeated = payload['repeat'] == true

	local dirty = false
	local handle = record.handle

	if key == 'down' or key == 'up' then
		if move(record, key == 'down' and 1 or -1) then
			dirty = true
			reportFocus(repeated)
		end
	elseif key == 'right' then
		local entry = current(record)
		if adjust(entry, 1) then
			dispatch(record, entry, 'change')
			dirty = true
		elseif entry.kind == 'submenu' and not entry.disabled then
			dirty = activate()
		end
	elseif key == 'left' then
		local entry = current(record)
		if holdsValue(entry) then
			if adjust(entry, -1) then
				dispatch(record, entry, 'change')
				dirty = true
			end
		elseif #record.stack > 1 then
			record.stack[#record.stack] = nil
			-- No itemId: this is how a handler tells the key from the BACK row.
			dispatch(record, nil, 'back')
			dirty = true
		end
	elseif key == 'enter' then
		-- A held ENTER must not fire the same row twice. The old resource ran
		-- its own 260 ms/55 ms machine and did repeat it; the browser repeats
		-- far faster, and a repeated select is a player who bought ten.
		if repeated then return end
		dirty = activate()
	elseif key == 'back' then
		if repeated then return end
		if #record.stack > 1 then
			record.stack[#record.stack] = nil
			dispatch(record, nil, 'back')
			dirty = true
		else
			closeNow(record.handle, 'back')
			return
		end
	end

	-- Every branch above can close this menu, or open another under a handler.
	if dirty and record ~= nil and record.handle == handle then draw() end
end

--- A row the player pointed at, by its absolute index in the level.
local function onChoose(payload)
	if fromPage(payload) == nil then return end
	local index = Text.Integer(payload.index)
	if index == nil then return end

	local screenAt = top(record)
	-- Re-resolved here, never trusted: the drawn window may be a frame behind.
	if not selectable(screenAt.items[index]) then return end

	local handle = record.handle
	local moved = false
	if screenAt.index ~= index then
		screenAt.index = index
		moved = true
		-- The originals raised focus for UP and DOWN only, because they had no
		-- pointer. A caller following the cursor would be on the wrong row.
		reportFocus(false)
		if record == nil or record.handle ~= handle then return end
	end
	-- Drawn for the move as well as for the landing: pointing at a row that
	-- turns out not to change anything still moved the cursor.
	local changed = activate()
	if (moved or changed) and record ~= nil and record.handle == handle then draw() end
end

--- Escape. The page keeps focus until this answers with a close: the close
--- reason belongs to Lua and the page never decides it.
---
--- INSIDE A SUBMENU, ESCAPE IS BACK. It used to close the whole menu from any
--- depth, while Backspace and Left went up one level: so a player three levels
--- into a shop who pressed the key every other screen uses to back out lost
--- the shop. One rule now -- Escape goes back, and closes at the top -- which is
--- what the BACK key already did.
local function onDismiss(payload)
	if fromPage(payload) == nil then return end
	if #record.stack > 1 then
		local handle = record.handle
		record.stack[#record.stack] = nil
		dispatch(record, nil, 'back')
		if record ~= nil and record.handle == handle then draw() end
		return
	end
	closeNow(record.handle, 'dismissed')
end

-- Answers the surface-wide focus broadcast for this module's own owners: see
-- `OPX.Modal.FocusResponder`. `FOCUS.menu` is read at every broadcast, so the
-- answer is what the menu up now was granted.
local onFocus = OPX.Modal.FocusResponder(FOCUS)

-- ── the keyboard Lua reads itself ───────────────────────────────────────────
--
-- THE POINT OF THIS BLOCK. Taking the keyboard is taking the movement keys, so a
-- menu whose page holds focus is a menu the player cannot walk away from. The
-- `cursor` mode hands the page the MOUSE only and leaves the game its keys --
-- which fixes walking and breaks navigating, because the arrows then never reach
-- the page at all.
--
-- So Lua reads them. This is not new ground: it is what `opx77_menu` did before
-- this surface could be focused, down to the 260/55 ms repeat, and the whole of
-- that machine is the twenty lines below. `onKey` is shared with the page, so
-- both routes land in exactly one decision.

-- Key name to when it may next fire, for keys currently held.
local heldUntil = {}

-- The scheduler handle of the poll, nil when nothing is polling.
local pollJob

-- Passes since the poll last started, for `REOPEN_GRACE_PASSES`.
local passes = 0

--- Whether this open menu leaves the keyboard to the game.
local function pagePolls()
	return record ~= nil and record.focus == 'full'
end

-- HANDS ONE POLLED KEY TO A RESUME OF ITS OWN.
--
-- The poll is a scheduler job, and the scheduler runs up to four due jobs in
-- one resume of the client's ONLY loop -- whose overrun retires that loop for
-- the session, silently, with the HUD, the prompts, the target eye and these
-- very keys inside it. A key used to be handled inline here: Enter reached
-- `activate`, then the owner's row callback, which routinely builds and opens
-- its next screen -- tens of thousands of instructions for a long list, on a
-- budget shared with three other jobs. Now the poll only notices the edge and
-- the key is played on a one-shot thread, a frame later, where an overrun can
-- cost that one press and nothing else. The handle rides along, so a key whose
-- menu was replaced in the meantime is dropped by `onKey` like any stale one.
local function playKey(payload)
	if type(CreateThread) ~= 'function' then return onKey(payload) end
	CreateThread(function() onKey(payload) end)
end

--- One pass over the six keys: edge, then repeat.
local function pollKeys()
	if record == nil or pagePolls() then return end

	local atMs = OPX.Now()
	passes = passes + 1
	for index = 1, #POLLED do
		local name, key = POLLED[index][1], POLLED[index][2]
		-- A plain boolean, on purpose: a Result per key per 25 ms pass is garbage
		-- for nothing. `IsDown` answers false for the missing namespace, the raise
		-- and the `(nil, reason)` a key name it does not poll comes back with --
		-- the third of which this loop only got right by accident, reading nil as
		-- "not down" without ever knowing the key was unpollable.
		local downNow = OPX.Lib.Input.IsDown(name)

		if downNow ~= true then
			heldUntil[name] = nil
		else
			local due = heldUntil[name]
			if due == nil and passes <= REOPEN_GRACE_PASSES then
				-- A press that was already down when the menu came back, seen late.
				-- An arrow is armed as held and repeats on schedule; Enter and
				-- Backspace act rather than move, so they wait for the release.
				heldUntil[name] = (key == 'enter' or key == 'back') and math.huge
					or atMs + REPEAT_FIRST_MS
			elseif due == nil then
				-- The rising edge. Fires and arms the long first repeat. One key per
				-- pass: the next one is read against the frame this one leaves.
				heldUntil[name] = atMs + REPEAT_FIRST_MS
				return playKey({ handle = record.handle, key = key })
			elseif atMs >= due then
				heldUntil[name] = atMs + REPEAT_NEXT_MS
				return playKey({ handle = record.handle, key = key, ['repeat'] = true })
			end
		end
	end
end

--- Starts or stops the poll for the menu that is open now.
-- Registered on open and cancelled on close rather than left running: a 25 ms
-- job that answers nothing is still a 25 ms job.
--- Marks every key that is ALREADY down as held, so starting the poll can never
--- read an unbroken press as a fresh one.
--
-- THIS IS NOT DEFENSIVE, IT IS THE CORRECTNESS OF THE EDGE. Choosing a submenu row
-- REOPENS the menu -- `Open` closes the live one first -- and that close stops the
-- poll while the player's finger is still on Enter. Starting again from an empty
-- table read the same unbroken press as a new rising edge one pass later, and fired
-- it at whatever row the submenu had just put the cursor on: one press of Enter,
-- and the player also chose the first row of the level they had only just opened.
-- `onKey` cannot catch that either -- a fresh edge carries no repeat flag, and its
-- guard is on repeats.
--
-- A key must be RELEASED before it fires again, across a reopen or not.
local function primeHeld()
	local atMs = OPX.Now()
	heldUntil = {}
	for index = 1, #POLLED do
		local name = POLLED[index][1]
		-- Armed as though it had just been pressed: it does not fire now, and a
		-- held ARROW still repeats on schedule, which is what holding one is for.
		if OPX.Lib.Input.IsDown(name) then heldUntil[name] = atMs + REPEAT_FIRST_MS end
	end
end

setPolling = function(wanted)
	if wanted and pollJob == nil then
		primeHeld()
		passes = 0
		pollJob = OPX.Scheduler.Every('menu:keys', POLL_MS, pollKeys)
	elseif not wanted and pollJob ~= nil then
		OPX.Scheduler.Cancel(pollJob)
		pollJob = nil
		heldUntil = {}
	end
end

--- Wires the page channels once, on the first open.
wire = function()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'menu:key', onKey)
	OPX.UI.On(SURFACE, 'menu:choose', onChoose)
	OPX.UI.On(SURFACE, 'menu:dismiss', onDismiss)
	OPX.UI.On(SURFACE, 'focus:set', onFocus)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Builds the held state.
-- @author dop42
function M.Init()
	record = nil
	announcedOpen = false
	nextHandle = 0
	pendingOpen = false
	wired = false
	life.Reset()
end

--- Publishes the menu contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('menu', 1, {
		Open = Open,
		Close = Close,
		Update = Update,
		SetStatus = SetStatus,
		State = State,
		Keys = Keys,
	})
end

--- Wires the down state, the pause key and the upkeep pass.
-- @author dop42
function M.Start()
	life.Start()
end

--- Closes whatever is open and hands the keyboard back.
-- @author dop42
function M.Stop()
	if record ~= nil then closeNow(record.handle, 'stopped') end
	-- A close with no handle blanks whatever the page still holds, which is the
	-- one case where this module cannot know what that is.
	OPX.UI.Send(SURFACE, 'menu:close', {})
	OPX.UI.ReleaseFocus(OWNER)
end
