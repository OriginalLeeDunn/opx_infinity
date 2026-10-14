--- The store of prompt groups, the key names, the strip that is drawn from them,
--- and the four operations a caller reaches it with.
-- @author dop42
--
-- THE PAGE DECIDES NOTHING. `prompts:frame` is the whole strip, already ordered,
-- already cut to the row budget and with every cap already named: a cap says
-- what the player's own binding says, and the page has no keyboard layout with
-- which to turn a mapping id into a key.
--
-- A group is validated WHOLE OR NOT AT ALL. One malformed row refuses the group
-- and the refusal names the first thing wrong, because half a strip is worse
-- than no strip: a caller reading "press E" that silently lost its second row
-- has no way to find out.
--
-- HIDING NEVER EMPTIES. The keyboard being taken, the HUD being off and the
-- player being down all take the strip off screen without touching the store,
-- and it comes back exactly as it was.
--
-- Everything is change-gated: a caller may push the same reading every frame and
-- the surface pays nothing for it.

local M = OPX.Modules.Get('prompts')

local Result = OPX.Result
local SERVER_PREFIX = M.SERVER_PREFIX

-- Page channels. `OPX.UI.Send` prefixes the surface id, so the page sees these
-- as `opx:prompts:<verb>`.
local CHANNEL_CONFIG = 'prompts:config'
local CHANNEL_FRAME = 'prompts:frame'
local CHANNEL_HIDE = 'prompts:hide'
local CHANNEL_READY = 'prompts:ready'

-- The downed module's public bus.
local EVENT_DOWNED_CHANGED = OPX.Event(OPX.Channel.LOCAL, 'downed', 'changed')

-- Byte ceilings on everything drawn. Short on purpose: a label is a few words
-- beside a key, not a sentence, and the strip never wraps.
local MAX_TITLE = 32
local MAX_LABEL = 48
local MAX_VALUE = 24
local MAX_KEY = 16
local MAX_ROW_ID = 32

-- A group id, an owner name and a key mapping id, at the ceiling the platform
-- puts on a mapping id.
local MAX_ID = 64
local MAX_OWNER = 64
local MAX_ACTION = 64

-- Most rows one group holds, most caps one row holds, most groups one owner
-- holds, and most groups held at once.
local MAX_ROWS_PER_GROUP = 8
local MAX_KEYS = 6
local MAX_GROUPS_PER_OWNER = 8
local MAX_GROUPS = 32

-- The page's own row ceiling. The configured budget is clamped to it, so a
-- generous config cannot hand the page more than it will draw.
local PAGE_MAX_ROWS = 24

local MIN_PRIORITY = -100
local MAX_PRIORITY = 100

-- The four corners the strip may be anchored to.
local ANCHORS = {
	['bottom-right'] = true,
	['bottom-left'] = true,
	['top-right'] = true,
	['top-left'] = true,
}

-- Arrow keys drawn as glyphs in every language.
local GLYPHS = { UP = '↑', DOWN = '↓', LEFT = '←', RIGHT = '→' }

-- The validated configuration. Nothing below reads `M.Settings` directly.
local settings = {}

-- Held groups, keyed by owner and id. The two halves are separated by a NUL and
-- not by a colon, because either half may contain one.
local groups = {}

-- BUMPED BY EVERY CHANGE TO WHAT `build()` READS: a group stored, patched or
-- removed, and the caps forgotten on a rebind. `pass()` redraws every 150ms
-- inside the scheduler's shared resume, and `build()` sorted every group and
-- concatenated a signature for every row on each of those passes -- up to 32
-- groups, thousands of instructions, to arrive at the signature it already had.
-- The frame is now rebuilt only when the revision moved. Caps cannot go stale
-- behind it: see `CAP_UNNAMEABLE` below.
local revision = 0
local built = { revision = -1 }

-- What each owner that has ever posted a group turned out to be: a module of
-- this runtime, a resource of this host, or neither. Settled once, on the first
-- group, because it is what the sweep below is allowed to act on.
local ownerKinds = {}

-- Bumped by every new group, so that at equal priority the most recent draws
-- nearest the anchored edge.
local sequence = 0

-- Signature of what the page last received, nil when that is unknown.
local drawnSignature = nil

-- Owners with a group in the frame the page last received.
local drawnOwners = {}

-- Why the strip is off screen, if it is. None of the three removes a group.
local captured = false
local hudOff = false
local down = false

-- Whether the page has reported ready.
local ready = false

-- When the next owner sweep is due, on the monotonic clock.
local nextSweepMs = 0

--- Whether a value is a bounded name of word characters.
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Whether display text is bounded and free of control characters.
-- Refused rather than cleaned: text that carries a control character is text the
-- caller did not mean to send, and quietly stripping it hides the bug.
local function validText(value, maximum, allowEmpty)
	return type(value) == 'string' and #value <= maximum
		and (allowEmpty or #value > 0) and value:find('%c') == nil
end

--- The store key of one owner's group id.
local function groupKey(owner, id)
	return owner .. '\0' .. id
end

-- ── settings ─────────────────────────────────────────────────────────────────

--- A valid setting, or its default with a warning. An absent value takes the
--- default in silence; a wrong one is worth a line.
local function setting(name, ok, value, default)
	if value == nil then return default end
	if ok then return value end
	Open77.log.warn(('[prompts] config: %s is invalid (%s); using %s')
		:format(name, tostring(value), tostring(default)))
	return default
end

--- Whether a value is a finite number inside a closed range.
local function within(value, low, high)
	return OPX.Math.IsFinite(value) and value >= low and value <= high
end

--- Reads the operator configuration into the one table the rest of the file uses.
local function readSettings()
	local config = M.Settings
	settings = {
		anchor = setting('ANCHOR', ANCHORS[config.ANCHOR] == true, config.ANCHOR, 'bottom-right'),
		offset = math.floor(setting('OFFSET', within(config.OFFSET, 0, 540), config.OFFSET, 0)),
		maxWidth = math.floor(setting('MAX_WIDTH', within(config.MAX_WIDTH, 200, 960),
			config.MAX_WIDTH, 420)),
		maxRows = math.floor(setting('MAX_ROWS', within(config.MAX_ROWS, 1, PAGE_MAX_ROWS),
			config.MAX_ROWS, 10)),
		hideWhenCaptured = setting('HIDE_WHEN_CAPTURED',
			type(config.HIDE_WHEN_CAPTURED) == 'boolean', config.HIDE_WHEN_CAPTURED, true),
		followHud = setting('FOLLOW_HUD', type(config.FOLLOW_HUD) == 'boolean',
			config.FOLLOW_HUD, true),
		tickMs = math.floor(setting('TICK_MS', within(config.TICK_MS, 50, 1000),
			config.TICK_MS, 150)),
		sweepMs = math.floor(setting('OWNER_SWEEP_MS', within(config.OWNER_SWEEP_MS, 250, 10000),
			config.OWNER_SWEEP_MS, 1000)),
	}
end

-- ── naming a key ─────────────────────────────────────────────────────────────

--- A key's glyph, its catalogue word, or its upper-cased spelling.
local function keyLabel(token)
	local upper = token:upper()
	local glyph = GLYPHS[upper]
	if glyph ~= nil then return glyph end
	local entry = 'prompts.key.' .. upper
	if OPX.Locale.Exists(entry) then return locale(entry) end
	return upper
end

-- The answer a cap resolved to last time, remembered ON THE CAP. `false` stands
-- for "nothing can name this one", which a nil could not: nil is also "not
-- resolved yet", and an unnameable cap is the case that would otherwise be
-- re-read every pass forever.
--
-- WHY IT IS REMEMBERED AT ALL. `build()` runs on EVERY pass -- `pass()` calls
-- `draw()` unconditionally and `draw()` builds BEFORE its signature gate at the
-- bottom of this section -- so this resolved once per cap per row per group,
-- 6.7 times a second, for the whole session. `OPX.Lib.Input.KeyFor` is a HOST
-- READ: at ten rows of up to `MAX_KEYS` caps that is up to sixty host reads a
-- pass, spent computing a signature that compares equal and is thrown away.
-- This is the correction `hud.vitals` documents at
-- `modules/hud/client/main.lua:1054-1060` -- "the DRAW is the part that was
-- recomputing an unchanged answer" -- and it was never applied here.
--
-- ON THE CAP, AND NOT IN A TABLE BESIDE IT, because the client sandbox has no
-- `setmetatable` (`core/shared/registry.lua:121`): a cache keyed by cap tables
-- could not be weak, and caps are rebuilt on every `show` and `update`, so it
-- would grow for the life of the session. Stored on the cap it lives and dies
-- with the group, and `rowSpec` -- the only other reader of a cap -- names the
-- three fields it wants rather than walking them.
--
-- IT CANNOT GO STALE. A cap resolves from its own `literal`/`action`, frozen
-- when the group was validated, and the binding the host holds for that action,
-- which cannot move without `open77:keybinds:changed`. That event already has a
-- handler here, and the handler forgets these first.
local CAP_UNNAMEABLE = false

--- One stored cap's text, or nil when nothing can name it.
-- Resolved WHEN THE STRIP IS FIRST DRAWN and not when the group was posted, so a
-- rebind reaches the strip without a call from the caller -- see `CAP_UNNAMEABLE`.
local function capText(cap)
	local known = cap.text
	if known ~= nil then return known or nil end

	local text
	if cap.literal ~= nil then
		text = keyLabel(cap.literal)
	else
		local key = OPX.Lib.Input.KeyFor(cap.action) or cap.fallback
		if key ~= nil then text = keyLabel(key) end
	end
	cap.text = text or CAP_UNNAMEABLE
	return text
end

-- ── validating a group ───────────────────────────────────────────────────────

--- Appends the caps one `keys` entry stands for, or refuses it.
-- A literal is split on spaces, so `'W A S D'` is four caps; a table carrying
-- `action` is ONE entry and never a list.
local function addKeys(value, caps)
	if type(value) == 'string' then
		local any = false
		for token in value:gmatch('%S+') do
			if #caps >= MAX_KEYS then return nil, 'prompts.tooManyKeys' end
			if #token > MAX_KEY or token:find('%c') then return nil, 'prompts.invalidKey' end
			caps[#caps + 1] = { literal = token }
			any = true
		end
		if not any then return nil, 'prompts.invalidKey' end
		return true
	end

	if type(value) ~= 'table' or not validName(value.action, MAX_ACTION) then
		return nil, 'prompts.invalidKey'
	end
	local fallback = value.fallback
	if fallback ~= nil and (type(fallback) ~= 'string' or #fallback == 0
		or #fallback > MAX_KEY or fallback:find('[%s%c]')) then
		return nil, 'prompts.invalidFallback'
	end
	if #caps >= MAX_KEYS then return nil, 'prompts.tooManyKeys' end
	caps[#caps + 1] = { action = value.action, fallback = fallback }
	return true
end

--- Whether a value is absent or a boolean.
local function optionalBoolean(value)
	return value == nil or type(value) == 'boolean'
end

--- Validates one row into the shape the store keeps.
local function normalizeRow(row, seen)
	if type(row) ~= 'table' then return nil, 'prompts.invalidRow' end

	local id = row.id
	if id ~= nil then
		if not validName(id, MAX_ROW_ID) then return nil, 'prompts.invalidRowId' end
		if seen[id] then return nil, 'prompts.duplicateRowId' end
		seen[id] = true
	end

	if not validText(row.label, MAX_LABEL, false) then return nil, 'prompts.invalidLabel' end

	local value = row.value
	if OPX.Math.IsFinite(value) then value = tostring(value) end
	if value ~= nil and not validText(value, MAX_VALUE, true) then
		return nil, 'prompts.invalidValue'
	end
	if value == '' then value = nil end

	if not optionalBoolean(row.hold) then return nil, 'prompts.invalidHold' end
	if not optionalBoolean(row.combo) then return nil, 'prompts.invalidCombo' end
	if not optionalBoolean(row.dim) then return nil, 'prompts.invalidDim' end

	local keys = row.keys
	if keys == nil then return nil, 'prompts.keysRequired' end
	local caps = {}
	if type(keys) == 'table' and keys.action == nil then
		if #keys == 0 then return nil, 'prompts.keysRequired' end
		for index = 1, #keys do
			local ok, reason = addKeys(keys[index], caps)
			if not ok then return nil, reason end
		end
	else
		local ok, reason = addKeys(keys, caps)
		if not ok then return nil, reason end
	end

	return {
		id = id,
		label = row.label,
		value = value,
		hold = row.hold == true,
		combo = row.combo == true,
		dim = row.dim == true,
		keys = caps,
	}
end

--- Validates a spec into a stored group, whole or not at all.
local function normalize(owner, id, spec)
	if not validName(id, MAX_ID) then return nil, 'prompts.invalidId' end
	if type(spec) ~= 'table' then return nil, 'prompts.invalidSpec' end

	local title = spec.title
	if title == false or title == '' then title = nil end
	if title ~= nil and not validText(title, MAX_TITLE, false) then
		return nil, 'prompts.invalidTitle'
	end

	local priority = spec.priority
	if priority == nil then priority = 0 end
	if not OPX.Math.IsFinite(priority) or priority % 1 ~= 0
		or priority < MIN_PRIORITY or priority > MAX_PRIORITY then
		return nil, 'prompts.invalidPriority'
	end

	local rows = spec.rows
	if type(rows) ~= 'table' or #rows == 0 then return nil, 'prompts.rowsRequired' end
	if #rows > MAX_ROWS_PER_GROUP then return nil, 'prompts.tooManyRows' end

	local seen, normalized = {}, {}
	for index = 1, #rows do
		local row, reason = normalizeRow(rows[index], seen)
		if row == nil then return nil, reason end
		normalized[index] = row
	end

	return {
		owner = owner,
		id = id,
		title = title,
		priority = math.floor(priority),
		rows = normalized,
	}
end

--- Rewrites a stored row the way a caller would have written it, for patching.
local function rowSpec(row)
	local keys = {}
	for index, cap in ipairs(row.keys) do
		if cap.literal ~= nil then
			keys[index] = cap.literal
		else
			keys[index] = { action = cap.action, fallback = cap.fallback }
		end
	end
	return { id = row.id, label = row.label, value = row.value, hold = row.hold,
		combo = row.combo, dim = row.dim, keys = keys }
end

--- Merges a patch over a held group and revalidates it, so a bad field answers
--- the code a fresh group would.
local function patched(group, patch)
	if type(patch) ~= 'table' then return nil, 'prompts.invalidPatch' end

	local spec = { title = group.title, priority = group.priority, rows = {} }
	if patch.title ~= nil then spec.title = patch.title end
	if patch.priority ~= nil then spec.priority = patch.priority end
	if patch.rows ~= nil then
		spec.rows = patch.rows
	else
		for index, row in ipairs(group.rows) do spec.rows[index] = rowSpec(row) end
	end

	if patch.values ~= nil then
		if type(patch.values) ~= 'table' then return nil, 'prompts.invalidValues' end
		if patch.rows ~= nil then return nil, 'prompts.rowsAndValues' end
		for rowId, value in pairs(patch.values) do
			local found = false
			for _, row in ipairs(spec.rows) do
				if row.id == rowId then
					found = true
					row.value = value ~= false and value or nil
				end
			end
			if not found then return nil, 'prompts.rowNotFound' end
		end
	end

	local merged, reason = normalize(group.owner, group.id, spec)
	if merged == nil then return nil, reason end
	-- The group keeps its place among groups of the same priority.
	merged.sequence = group.sequence
	return merged
end

-- ── the store ────────────────────────────────────────────────────────────────

--- The sorted ids of one owner's groups.
local function idsOf(owner)
	local ids = {}
	for _, group in pairs(groups) do
		if group.owner == owner then ids[#ids + 1] = group.id end
	end
	table.sort(ids)
	return ids
end

--- The groups held across every owner.
local function count()
	local total = OPX.Table.Count(groups)
	return total
end

--- Removes every group of one owner and answers how many.
-- The keys are collected before any is removed: removing an entry while `pairs`
-- walks the same table is undefined.
local function removeOwner(owner)
	local keys = {}
	for key, group in pairs(groups) do
		if group.owner == owner then keys[#keys + 1] = key end
	end
	for index = 1, #keys do groups[keys[index]] = nil end
	if #keys > 0 then revision = revision + 1 end
	return #keys
end

--- Forgets every cap's resolved text, so the next draw reads the host again.
-- Bounded by what is held: caps that belong to no live group are unreachable
-- from here and were already gone. See `CAP_UNNAMEABLE` for why this is the
-- invalidation rather than a cache with a lifetime of its own.
local function forgetCaps()
	revision = revision + 1
	for _, group in pairs(groups) do
		for _, row in ipairs(group.rows) do
			for _, cap in ipairs(row.keys) do cap.text = nil end
		end
	end
end

--- Every group, highest priority then most recent first.
-- A total order and not a partial one: on equal keys `pairs` would reshuffle the
-- strip between two frames, and the urgent group would lose its rows to the
-- trivial one at random.
local function ordered()
	local list = {}
	for _, group in pairs(groups) do list[#list + 1] = group end
	table.sort(list, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		if a.sequence ~= b.sequence then return a.sequence > b.sequence end
		return a.owner .. '\1' .. a.id < b.owner .. '\1' .. b.id
	end)
	return list
end

-- ── drawing ──────────────────────────────────────────────────────────────────

--- Builds the frame the page draws: ordered, cut and resolved. Answers it with
--- its signature and the owners it carries.
local function build()
	local budget = math.min(settings.maxRows, PAGE_MAX_ROWS)
	local frame, marks, owners = {}, {}, {}

	for _, group in ipairs(ordered()) do
		if budget <= 0 or #frame >= MAX_GROUPS then break end
		local rows = {}
		for index, row in ipairs(group.rows) do
			if budget <= 0 then break end
			local caps, complete = {}, true
			for capIndex, cap in ipairs(row.keys) do
				local text = capText(cap)
				if text == nil then
					complete = false
					break
				end
				caps[capIndex] = text
			end
			-- A prompt with no key to name says nothing, so the row is held but
			-- left out rather than drawn without its cap.
			if complete then
				budget = budget - 1
				rows[#rows + 1] = {
					key = row.id or ('#' .. index),
					caps = caps,
					combo = row.combo,
					label = row.label,
					value = row.value or '',
					hold = row.hold,
					dim = row.dim,
				}
				marks[#marks + 1] = table.concat({ rows[#rows].key, table.concat(caps, '\3'),
					tostring(row.combo), row.label, rows[#rows].value, tostring(row.hold),
					tostring(row.dim) }, '\2')
			end
		end
		-- An empty group is a frame, a title and no information.
		if #rows > 0 then
			local key = group.owner .. '/' .. group.id
			frame[#frame + 1] = { key = key, title = group.title or '', rows = rows }
			marks[#marks + 1] = key .. '\2' .. (group.title or '')
			owners[group.owner] = true
		end
	end

	return frame, table.concat(marks, '\1'), owners
end

--- Sends the frame, or the hide, when either changed.
-- A send that did not land forgets the signature: the page is still drawing an
-- older frame, and the next pass has to try again.
local function draw(force)
	if not ready then return end
	if built.revision ~= revision then
		built.frame, built.signature, built.owners = build()
		built.revision = revision
	end
	local frame, signature, owners = built.frame, built.signature, built.owners
	local up = #frame > 0 and not captured and not hudOff and not down
	if not up then signature = '' end
	if not force and signature == drawnSignature then return end

	local sent
	if up then
		sent = OPX.UI.Send('overlay', CHANNEL_FRAME, { groups = frame })
	else
		sent = OPX.UI.Send('overlay', CHANNEL_HIDE, {})
	end
	drawnSignature = sent and signature or nil
	drawnOwners = (sent and up) and owners or {}
end

--- Pushes the layout and the hold tag. `hold` travels as a catalogue key: the
--- page owns no English, and even that word is the player's language.
local function drawConfig()
	OPX.UI.Send('overlay', CHANNEL_CONFIG, {
		anchor = settings.anchor,
		offset = settings.offset,
		maxWidth = settings.maxWidth,
		hold = 'prompts.hold',
	})
end

-- ── the owners that go away ──────────────────────────────────────────────────

--- Settles once what an owner is, on its first group.
-- The sweep may only drop an owner it can positively watch. A name that is
-- neither a module of this runtime nor a resource of this host -- a bare label,
-- and every `@server:` owner, since a client cannot see a server module stop --
-- is recorded as such and never swept: nothing here can tell us it went away,
-- and guessing would take a live group off the screen for good.
local function noteOwner(owner)
	if ownerKinds[owner] ~= nil then return end
	if OPX.Modules.Record(owner) ~= nil then
		ownerKinds[owner] = 'module'
		return
	end
	local read, state = pcall(GetResourceState, owner)
	if read and (state == 'running' or state == 'starting') then
		ownerKinds[owner] = 'resource'
		return
	end
	ownerKinds[owner] = 'label'
end

--- Whether an owner is still there to be holding a group.
local function ownerAlive(owner)
	local kind = ownerKinds[owner]
	if kind == 'module' then
		local record = OPX.Modules.Record(owner)
		-- `declared` counts as alive: a module posting a group from its own
		-- `Start` is not marked started until every module has run, and would
		-- lose the group to the first sweep.
		return record ~= nil and (record.State == 'started' or record.State == 'declared')
	end
	if kind == 'resource' then
		local read, state = pcall(GetResourceState, owner)
		return read and (state == 'running' or state == 'starting')
	end
	return true
end

--- Drops the groups of owners that stopped.
local function sweepOwners()
	local gone = {}
	for _, group in pairs(groups) do
		if not gone[group.owner] and not ownerAlive(group.owner) then
			gone[group.owner] = true
		end
	end
	local removed = 0
	for owner in pairs(gone) do removed = removed + removeOwner(owner) end
	if removed > 0 then draw() end
end

-- ── the operations ───────────────────────────────────────────────────────────

--- Puts a group up, or replaces the owner's group with that id where it stands.
-- @author dop42
-- @param owner string the caller's own name, for grouping and expiry
-- @param id string
-- @param spec table title, priority and rows
-- @return Result
local function show(owner, id, spec)
	if not validName(owner, MAX_OWNER) then return Result.Err('prompts.invalidOwner') end
	local group, reason = normalize(owner, id, spec)
	if group == nil then return Result.Err(reason) end

	noteOwner(owner)

	local held = groups[groupKey(owner, id)]
	if held == nil then
		-- Both ceilings apply to a NEW id only: a context redrawing itself under
		-- the id it already holds must never be refused for being too many.
		if #idsOf(owner) >= MAX_GROUPS_PER_OWNER then
			return Result.Err('prompts.ownerLimit')
		end
		if count() >= MAX_GROUPS then return Result.Err('prompts.limit') end
		sequence = sequence + 1
		group.sequence = sequence
	else
		group.sequence = held.sequence
	end

	groups[groupKey(owner, id)] = group
	revision = revision + 1
	draw()
	return Result.Ok({ id = id, replaced = held ~= nil, rows = #group.rows })
end

--- Changes one of the owner's groups in place. Absent fields keep what the group
--- has; a patch that changes nothing on screen sends nothing.
-- @author dop42
-- @param owner string
-- @param id string
-- @param patch table title, priority, rows or values
-- @return Result
local function update(owner, id, patch)
	if not validName(owner, MAX_OWNER) then return Result.Err('prompts.invalidOwner') end
	if not validName(id, MAX_ID) then return Result.Err('prompts.invalidId') end

	local held = groups[groupKey(owner, id)]
	if held == nil then return Result.Err('prompts.notFound') end
	local merged, reason = patched(held, patch)
	if merged == nil then return Result.Err(reason) end

	groups[groupKey(owner, id)] = merged
	revision = revision + 1
	draw()
	return Result.Ok({ id = id })
end

--- Takes one of the owner's groups down. An id the owner does not hold is not an
--- error: it answers that nothing was up.
-- @author dop42
-- @param owner string
-- @param id string
-- @return Result
local function hide(owner, id)
	if not validName(owner, MAX_OWNER) then return Result.Err('prompts.invalidOwner') end
	if not validName(id, MAX_ID) then return Result.Err('prompts.invalidId') end

	local key = groupKey(owner, id)
	local removed = groups[key] ~= nil
	groups[key] = nil
	if removed then
		revision = revision + 1
		draw()
	end
	return Result.Ok({ removed = removed })
end

--- Takes every one of the owner's groups down.
-- @author dop42
-- @param owner string
-- @return Result
local function hideAll(owner)
	if not validName(owner, MAX_OWNER) then return Result.Err('prompts.invalidOwner') end
	local removed = removeOwner(owner)
	if removed > 0 then draw() end
	return Result.Ok({ removed = removed })
end

--- The owner's held group ids, and whether any of them is on screen.
-- `visible` is read from what was DRAWN and not from the store: a group cut by
-- the row budget, or one whose caps could not be named, is held and not shown.
-- @author dop42
-- @param owner string
-- @return Result
local function list(owner)
	if not validName(owner, MAX_OWNER) then return Result.Err('prompts.invalidOwner') end
	local ids = idsOf(owner)
	return Result.Ok({ prompts = ids, count = #ids, visible = drawnOwners[owner] == true })
end

-- ── stepping aside ───────────────────────────────────────────────────────────

--- Whether the player turned the HUD off. Only a contract that answers `visible
--- = false` hides the strip: a HUD that did not answer has hidden nothing.
local function hudToggledOff()
	if not settings.followHud then return false end
	local hud = OPX.Api.Get('hud')
	if hud == nil then return false end
	local answer = hud.IsVisible()
	return answer.ok and answer.value.visible == false
end

--- Whether another surface holds the keyboard.
local function keyboardTaken()
	if not settings.hideWhenCaptured then return false end
	return OPX.Lib.Input.IsCaptured()
end

--- Takes the strip down while the player is down, or back up. No group moves.
local function setDown(value)
	local wanted = value == true
	if down == wanted then return end
	down = wanted
	draw()
end

--- One pass: reads the two step-aside conditions, sweeps owners when due, and
--- redraws. A pass over an empty store answers at once.
local function pass()
	if next(groups) == nil then
		captured = false
		if drawnSignature ~= '' then draw() end
		return
	end

	captured = keyboardTaken()
	hudOff = hudToggledOff()

	local atMs = OPX.Now()
	if atMs >= nextSweepMs then
		nextSweepMs = atMs + settings.sweepMs
		sweepOwners()
	end

	draw()
end

-- ── the server's four events ─────────────────────────────────────────────────

--- The owner name a server envelope is stored under, or nil.
-- Taken at its word: a client cannot know which server module sent an event. The
-- prefix is what keeps the two worlds apart.
local function serverOwner(name)
	if not validName(name, MAX_OWNER - #SERVER_PREFIX) then return nil end
	return SERVER_PREFIX .. name
end

--- Runs one server-sent operation. A malformed envelope is dropped: there is no
--- channel back, so a refusal has nowhere to go.
local function fromServer(envelope, run)
	if type(envelope) ~= 'table' then return end
	local owner = serverOwner(envelope.owner)
	if owner == nil then return end
	run(owner, envelope)
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Reads the configuration and builds the empty store. Never yields.
-- @author dop42
function M.Init()
	readSettings()
	groups = {}
	revision = revision + 1
	ownerKinds = {}
	sequence = 0
	drawnSignature = nil
	drawnOwners = {}
	captured, hudOff, down = false, false, false
	ready = false
	nextSweepMs = 0
end

--- Publishes the five operations.
-- @author dop42
function M.Api()
	OPX.Api.Provide('prompts', 1, {
		Show = show,
		Update = update,
		Hide = hide,
		HideAll = hideAll,
		List = list,
	})
end

--- Wires the page, the server's four events, the rebind signal and the pass.
-- @author dop42
function M.Start()
	local downHeard = 0

	OPX.UI.On('overlay', CHANNEL_READY, function()
		ready = true
		drawConfig()
		-- The page's DOM is new, so the held signature describes a frame that no
		-- longer exists anywhere.
		draw(true)
	end)

	RegisterNetEvent(M.Event.SHOW, function(envelope)
		fromServer(envelope, function(owner, value) show(owner, value.id, value.spec) end)
	end)
	RegisterNetEvent(M.Event.UPDATE, function(envelope)
		fromServer(envelope, function(owner, value) update(owner, value.id, value.patch) end)
	end)
	RegisterNetEvent(M.Event.HIDE, function(envelope)
		fromServer(envelope, function(owner, value) hide(owner, value.id) end)
	end)
	RegisterNetEvent(M.Event.HIDE_ALL, function(name)
		-- The whole payload is the owner name; this one is not a table.
		local owner = serverOwner(name)
		if owner ~= nil then hideAll(owner) end
	end)

	-- The resolved caps go FIRST: a redraw that read the cache would put the old
	-- key back on the strip and then gate the next pass on its signature, so the
	-- rebind would never appear.
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function()
		forgetCaps()
		draw()
	end)

	AddEventHandler(EVENT_DOWNED_CHANGED, function(payload)
		if type(payload) ~= 'table' then return end
		downHeard = downHeard + 1
		setDown(payload.down == true)
	end)

	local downed = OPX.Api.Get('downed')
	if downed ~= nil then
		local heard = downHeard
		local answer = downed.IsDown()
		-- A state event that landed while the contract was being read is newer
		-- than the answer, and wins.
		if answer.ok and downHeard == heard then setDown(answer.value.down == true) end
	end

	OPX.Scheduler.Every('prompts.pass', settings.tickMs, pass)
end

--- Drops every group and takes the strip off screen.
-- @author dop42
function M.Stop()
	groups = {}
	revision = revision + 1
	ownerKinds = {}
	drawnSignature = nil
	drawnOwners = {}
	if ready then OPX.UI.Send('overlay', CHANNEL_HIDE, {}) end
	ready = false
end
