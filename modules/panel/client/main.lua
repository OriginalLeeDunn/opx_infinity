--- The one open panel: its parsed view, the items behind it, and the dialog.
-- @author dop42

local M = OPX.Modules.Get('panel')

local Result = OPX.Result
local Text = OPX.Text

local SURFACE = 'interactive'
local OWNER = 'panel'
local CONFIRM_OWNER = 'panel.confirm'

-- Items one append may carry, and items one panel may hold.
--
-- MAX_APPEND IS A CALLER'S BOUND AND NOT THE WIRE'S, AND IT USED TO CLAIM TO BE
-- BOTH. The comment here read "the batch bound is a payload bound: the host
-- discards an event carrying more than 1024 value nodes"; the number under it
-- was never derived from that bound and nothing in this file ever counted a
-- node. A parsed item is eleven nodes -- the table, five keys, five values --
-- so two hundred of them is a payload of 2407 against a ceiling of 1024, and
-- even the fitting room's hundred-item batches came to 1207. The host refused
-- every one of them and `WebUI.Page.send` answered false, which this module
-- never read: the batch was reported to its caller as delivered and the clothes
-- never arrived. See `fits`, `chunkItems` and `push`.
local MAX_APPEND = 200
local MAX_ITEMS = 5000

-- Value nodes the host accepts in one WebUI payload. `modules/menu` counts
-- against the same ceiling for the same reason; the counting rule is its
-- `fitsInPayload`, and the two must not drift.
local MAX_PAYLOAD_NODES = 1024

-- Messages one panel may hold back while its open has not reached the page.
local MAX_QUEUED = 256

local MAX_ID = 64
local MAX_ITEM_ID = 160

local SWEEP_MS = 500

-- What this module's focus owners are given. The page names an owner and never
-- says what it wants: asking for the cursor is not the page's decision.
-- `focus:set` is a broadcast every view module listens to, and each answers for
-- its own owners only -- a module must not acquire, or release, focus on behalf
-- of a view it does not own.
local FOCUS = {
	panel = { keyboard = true, cursor = true },
	[CONFIRM_OWNER] = { keyboard = true, cursor = true },
}

-- Fields an update may carry. Anything outside this set and SPEC_ONLY refuses
-- the whole call: a field written under a name nothing renders is a caller
-- watching its panel do nothing and having no way to find out why.
local PATCHABLE = {
	eyebrow = true, title = true, subtitle = true, intro = true, tabs = true, tab = true,
	search = true, summary = true, actions = true, tools = true, selected = true,
	status = true, busy = true, labels = true, loading = true, clearItems = true,
	sliders = true, groups = true, tiles = true,
}

-- Fields only a spec may carry.
local SPEC_ONLY = {
	id = true, owner = true, on = true, hover = true, dismiss = true,
	columns = true, steal = true,
}

-- The one open panel, or nil.
local record

local nextHandle = 0

-- True while `panel:open` has not reached the page. The interactive surface is
-- built on first use and a send made before it reports ready is dropped, not
-- queued, so the open is re-sent from the sweep job until it lands.
local pendingOpen = false

-- Wiring the channels builds the surface, so it waits for the first open.
local wired = false

-- ── parsing a spec ──────────────────────────────────────────────────────────

--- Whether a value is an identifier: non-empty text without control characters.
-- `OPX.Modal`'s, shared with `menu` and `form`, aliased rather than wrapped.
local validId = OPX.Modal.ValidId

--- Display text with control characters blanked, cut to a character count.
local function clean(value, maximum)
	return Text.Clean(value, maximum)
end

--- Whether a table is a sequence of at most a count of entries.
-- Counted both ways: a map with a hole in it is not a list, and `#` is free to
-- stop at the hole and report a length that hides half the table.
local function isList(value, maximum)
	if type(value) ~= 'table' then return false end
	local count = OPX.Table.Count(value)
	return count <= maximum and count == #value
end

--- Whether a payload fits the host's bound, and the nodes counted getting there.
-- The count is the value itself and both halves of every pair under a table,
-- the way the host counts them: `OPX.Modal.Fits`, the one rule `menu` and
-- `form` hold their data to as well. It stops at the ceiling, so a runaway
-- table costs a bounded walk.
local function fits(payload)
	return OPX.Modal.Fits(payload, MAX_PAYLOAD_NODES)
end

--- What one value costs, counted whole.
local nodeCost = OPX.Modal.Nodes

--- Text that may be absent, answering the text or a refusal code.
local function optionalText(value, maximum, field)
	if value == nil or value == false then return nil end
	local text = clean(value, maximum)
	if text == nil then return nil, 'invalid_' .. field end
	return text
end

--- A list of buttons: id, label, an optional glyph, and the two flags.
--
-- THE GLYPH IS VALIDATED AND NOT PASSED THROUGH, exactly as `menu` does with a
-- row icon, and for the reason `core/shared/glyphs.lua` writes down: a name the
-- page has no path for is a promise Lua cannot keep -- the button validates,
-- reaches the DOM, and draws `interact` or nothing, with nobody told. `OPX.Glyphs`
-- is the one vocabulary and `tests/` holds it against what the page can actually
-- draw, so refusing an unknown name here is refusing it against the page's own
-- set. Refused rather than dropped: a caller who misspelt `arow` wants to hear
-- about it now, not to wonder later why one button in four has no picture.
local function buttons(value, maximum, field)
	if value == nil or value == false then return {} end
	if not isList(value, maximum) then return nil, 'invalid_' .. field end
	local out, seen = {}, {}
	for index = 1, #value do
		local entry = value[index]
		if type(entry) ~= 'table' or not validId(entry.id, MAX_ID) or seen[entry.id] then
			return nil, 'invalid_' .. field
		end
		local label = clean(entry.label, 40)
		if label == nil then return nil, 'invalid_' .. field end
		local icon = entry.icon
		if icon ~= nil then
			if type(icon) ~= 'string' or not OPX.Glyphs[icon] then
				return nil, 'invalid_' .. field
			end
		end
		seen[entry.id] = true
		out[index] = { id = entry.id, label = label, icon = icon,
			primary = entry.primary == true, disabled = entry.disabled == true }
	end
	return out
end

--- The tabs: id, label and whether a mark sits on one.
local function tabs(value)
	if value == nil or value == false then return {} end
	if not isList(value, 12) then return nil, 'invalid_tabs' end
	local out, seen = {}, {}
	for index = 1, #value do
		local entry = value[index]
		if type(entry) ~= 'table' or not validId(entry.id, MAX_ID) or seen[entry.id] then
			return nil, 'invalid_tabs'
		end
		local label = clean(entry.label, 40)
		if label == nil then return nil, 'invalid_tabs' end
		seen[entry.id] = true
		out[index] = { id = entry.id, label = label,
			marked = entry.marked == true, disabled = entry.disabled == true }
	end
	return out
end

-- Positions one slider may offer. It is `MAX_ITEMS` and not a number of its own
-- on purpose: a slider is a list the CALLER kept, so the ceiling on what it may
-- point into is the same ceiling as on a list this module holds.
local MAX_STEPS = MAX_ITEMS

--- Whether a value is a whole count within the slider bound.
local function counted(value)
	return type(value) == 'number' and value >= 0 and value <= MAX_STEPS and value % 1 == 0
end

--- The sliders: one control per named range, each standing somewhere in it.
--
-- A SLIDER IS A COUNT AND NOT A LIST, which is the whole reason this field
-- exists next to `items`. A caller with two thousand rows to offer either sends
-- two thousand rows -- which is `Append`, and which costs a parse, a chunking
-- and a payload per hundred of them -- or it keeps the rows and sends the
-- LENGTH. The page then draws a track from 0 to `count`, reports the index the
-- player put the thumb on, and is told back the one label that belongs under it.
-- Nothing else about the list crosses.
--
-- `index` is 0-based and 0 is a real position: a slider standing on nothing is
-- how a caller offers "none of them" without a second control beside it.
local function sliders(value)
	if value == nil or value == false then return {} end
	if not isList(value, 12) then return nil, 'invalid_sliders' end
	local out, seen = {}, {}
	for index = 1, #value do
		local entry = value[index]
		if type(entry) ~= 'table' or not validId(entry.id, MAX_ID) or seen[entry.id] then
			return nil, 'invalid_sliders'
		end
		local label = clean(entry.label, 40)
		local shown = clean(entry.value or '', 120)
		if label == nil or shown == nil then return nil, 'invalid_sliders' end
		-- A thumb outside its own track is a caller that has lost track of its
		-- list, and drawing it would put the page's idea of the position and the
		-- caller's permanently out of step.
		if not counted(entry.count) or not counted(entry.index) or entry.index > entry.count then
			return nil, 'invalid_sliders'
		end
		seen[entry.id] = true
		out[index] = { id = entry.id, label = label, count = entry.count,
			index = entry.index, value = shown, disabled = entry.disabled == true }
	end
	return out
end

-- How many tiles one window may carry, and it IS derived from the wire rather
-- than chosen. A tile is one string under an array index, so it costs two nodes,
-- and up to six with its optional label and picture: sixty is at most 360
-- against the host's 1024, which leaves the rest of a spec
-- -- twelve tabs, twelve sliders, three rows of buttons, every string -- the
-- room `Open` says it has. It is also the page's bound: a grid the player
-- scrolls is drawn whole, so a caller that answered one scroll with eight
-- hundred boxes would put eight hundred elements on a surface that has to stay
-- at frame rate while a body turns behind it.
local MAX_TILES = 60

--- One window of a category's pieces: which category, where it starts, the names.
--
-- WHY A WINDOW AND NOT A LIST, which is the same argument `sliders` makes one
-- field up and the reason this is a third field rather than `items`. The fitting
-- room's largest category is 677 records and the whole catalogue is about 1968;
-- sending them as `items` is what the slider replaced, and it cost a parse, a
-- chunking and a payload per hundred, with the player reaching one category of
-- seven before the stream died. But a slider is a poor way to CHOOSE a garment:
-- the player is looking for a jacket, not for position 412.
--
-- So the page draws a scrolling grid of boxes and asks for the next window when
-- it reaches the bottom of what it holds. The caller keeps its list exactly as
-- the slider left it; what crosses is the slice the player can actually see,
-- and the index a box carries is `from` plus its offset -- which is the same
-- index a slider thumb would have reported, so a press comes back through
-- `slide` and nothing new decides anything.
--
-- `from` IS 1-BASED AND 0 IS NOT A TILE. Index 0 on a slider means "nothing on
-- this slot", and the page draws that as a box of its own that is always there
-- rather than as the first entry of a window that may have scrolled away.
--
-- `labels` AND `images` ARE OPTIONAL AND PARALLEL TO `entries`: the caption
-- under each box and the picture in it, '' for "none". A picture is a plain file
-- name under the page's `images/clothing/` -- the bounds an inventory item's
-- IMAGE has -- and never a path, so no caller can point a box anywhere else. A
-- list of the wrong length is refused whole: a caption one box out of step is a
-- player choosing the jacket written under the trousers.
local IMAGE_PATTERN, IMAGE_MAX = '^[%w_%-%.]+$', 64

local function parallel(list, count, each)
	if list == nil then return {} end
	if not isList(list, MAX_TILES) or #list ~= count then return nil end
	local out = {}
	for index = 1, count do
		local value = each(list[index])
		if value == nil then return nil end
		out[index] = value
	end
	return out
end

local function tileLabel(value)
	return clean(value, 120)
end

local function tileImage(value)
	if value == '' then return '' end
	if type(value) ~= 'string' or #value > IMAGE_MAX or not value:find(IMAGE_PATTERN) then
		return nil
	end
	return value
end

local function tiles(value)
	if value == nil or value == false then return false end
	if type(value) ~= 'table' then return nil, 'invalid_tiles' end
	if not validId(value.slot, MAX_ID) then return nil, 'invalid_tiles' end
	local from = tonumber(value.from)
	if from == nil or from % 1 ~= 0 or from < 1 or from > MAX_STEPS then
		return nil, 'invalid_tiles'
	end
	local entries = value.entries
	if not isList(entries, MAX_TILES) then return nil, 'invalid_tiles' end
	local out = {}
	for index = 1, #entries do
		-- A RECORD NAME AND NOT A LABEL, and the page needs it whole: it is what
		-- a box is keyed by, and the caption when `labels` gives none, so
		-- trimming it to a display length would break the first use silently.
		local name = clean(entries[index], 120)
		if name == nil then return nil, 'invalid_tiles' end
		out[index] = name
	end
	local labels = parallel(value.labels, #out, tileLabel)
	local images = parallel(value.images, #out, tileImage)
	if labels == nil or images == nil then return nil, 'invalid_tiles' end
	return { slot = value.slot, from = from, entries = out, labels = labels, images = images }
end

--- The summary plate: a label, a value and one optional button.
local function summary(value)
	if value == nil or value == false then return false end
	if type(value) ~= 'table' then return nil, 'invalid_summary' end
	local label, shown = clean(value.label or '', 40), clean(value.value or '', 120)
	if label == nil or shown == nil then return nil, 'invalid_summary' end
	local out = { label = label, value = shown }
	if value.action ~= nil then
		local parsed = buttons({ value.action }, 1, 'summary')
		if parsed == nil then return nil, 'invalid_summary' end
		out.action = parsed[1]
	end
	return out
end

--- The status line: text, or text with its kind, or false for none.
local function status(value)
	if value == nil or value == false then return false end
	if type(value) == 'string' or type(value) == 'number' then
		return { text = clean(value, 160), kind = 'info' }
	end
	if type(value) ~= 'table' then return nil, 'invalid_status' end
	local text = clean(value.text, 160)
	if text == nil then return nil, 'invalid_status' end
	return { text = text, kind = value.kind == 'error' and 'error' or 'info' }
end

--- The chosen item per tab. The empty string keys a panel without tabs.
local function selected(value)
	if value == nil then return {} end
	if type(value) ~= 'table' then return nil, 'invalid_selected' end
	local out, count = {}, 0
	for tab, item in pairs(value) do
		count = count + 1
		if count > 64 or type(tab) ~= 'string' or #tab > MAX_ID then
			return nil, 'invalid_selected'
		end
		if item ~= false and not validId(item, MAX_ITEM_ID) then return nil, 'invalid_selected' end
		out[tab] = item
	end
	return out
end

--- The caller's overrides of the default words, over this module's own.
local function labels(value)
	local out = {
		count = locale('panel.count'),
		empty = locale('panel.empty'),
		loading = locale('panel.loading'),
		search = locale('panel.search'),
		nothing = locale('panel.nothing'),
		confirmYes = locale('panel.confirmYes'),
		confirmNo = locale('panel.confirmNo'),
	}
	if value == nil then return out end
	if type(value) ~= 'table' then return nil, 'invalid_labels' end
	for key in pairs(out) do
		if value[key] ~= nil then
			local text = clean(value[key], 80)
			if text == nil then return nil, 'invalid_labels' end
			out[key] = text
		end
	end
	return out
end

-- The parser of every patchable field, in one table so a spec and a patch read
-- the same value the same way.
local PARSERS = {
	eyebrow = function(value) return optionalText(value, 60, 'eyebrow') end,
	title = function(value) return optionalText(value, 60, 'title') end,
	subtitle = function(value) return optionalText(value, 40, 'subtitle') end,
	intro = function(value) return optionalText(value, 240, 'intro') end,
	tabs = tabs,
	sliders = sliders,
	tiles = tiles,
	tab = function(value)
		if value == nil or value == false then return nil end
		if not validId(value, MAX_ID) then return nil, 'invalid_tab' end
		return value
	end,
	search = function(value)
		if value == false then return false end
		if value == nil or value == true then return '' end
		local text = clean(value, 60)
		if text == nil then return nil, 'invalid_search' end
		return text
	end,
	summary = summary,
	actions = function(value) return buttons(value, 4, 'actions') end,
	tools = function(value) return buttons(value, 8, 'tools') end,
	-- A THIRD ROW OF BUTTONS, AND IT IS NOT A FOURTH KIND OF THING. `actions` is
	-- the commit row -- what finishes with this panel -- and `tools` adjusts the
	-- view the panel is drawn over; neither describes "another part of this same
	-- screen", which is what a category is. The fitting room needed one: saved
	-- outfits, share codes and a shop's ready-made looks are all reachable from
	-- the clothing screen and none of them is a tool or a commit. Same shape as
	-- the other two on purpose -- a caller that can build a `tools` row can build
	-- this one, and the page draws it with the same button.
	groups = function(value) return buttons(value, 8, 'groups') end,
	selected = selected,
	status = status,
	busy = function(value) return value == true end,
	labels = labels,
	loading = function(value) return value == true end,
}

--- Builds the view a spec describes, or refuses it whole.
local function buildView(spec)
	if type(spec) ~= 'table' then return nil, 'spec_must_be_a_table' end
	for key in pairs(spec) do
		if not PATCHABLE[key] and not SPEC_ONLY[key] then return nil, 'unknown_field' end
	end
	if not validId(spec.id, MAX_ID) then return nil, 'invalid_id' end
	if type(spec.on) ~= 'function' then return nil, 'callback_required' end
	if spec.dismiss ~= nil and spec.dismiss ~= 'close' and spec.dismiss ~= 'ask' then
		return nil, 'invalid_dismiss'
	end
	-- `clearItems` asks the page to forget what it was already sent, which a
	-- panel that has not opened yet cannot have.
	if spec.clearItems ~= nil then return nil, 'unknown_field' end

	local columns = spec.columns
	if columns == nil then columns = M.Settings.COLUMNS end

	local view = {
		id = spec.id,
		hover = spec.hover == true,
		dismiss = spec.dismiss or 'close',
		columns = columns == 1 and 1 or 2,
	}
	for key, parse in pairs(PARSERS) do
		local value, reason = parse(spec[key])
		if reason then return nil, reason end
		view[key] = value
	end
	-- A spec that named no search plate gets none; `search = true` is how a
	-- caller asks for one with the default word.
	if spec.search == nil then view.search = false end
	return view
end

--- Parses the fields of an update, or refuses the whole patch.
local function parsePatch(patch)
	if type(patch) ~= 'table' then return nil, 'patch_must_be_a_table' end
	local out = {}
	for key, value in pairs(patch) do
		if not PATCHABLE[key] then return nil, 'unknown_field' end
		if key == 'clearItems' then
			out.clearItems = value == true
		else
			local parsed, reason = PARSERS[key](value)
			if reason then return nil, reason end
			-- Lua cannot carry a present-but-empty value, so `false` is what
			-- clears a field across the bridge.
			if parsed == nil then parsed = false end
			out[key] = parsed
		end
	end
	return out
end

--- Splits a parsed batch into sends the host will accept, one at least.
-- Sized by counting rather than by a constant, because an item is five optional
-- fields: a batch of bare ids fits several times as many as a batch carrying a
-- detail line each, and a constant chosen for one of those is quietly wrong for
-- the other. An empty batch answers one empty chunk, which is how a caller with
-- nothing to add still gets to say `done`.
local function chunkItems(parsed)
	local room = MAX_PAYLOAD_NODES - nodeCost({ handle = 0, items = {}, done = false })
	local chunks, current, used = {}, {}, 0
	for index = 1, #parsed do
		-- Plus the array index the item sits under, which is a node of its own.
		local cost = nodeCost(parsed[index]) + 1
		if #current > 0 and used + cost > room then
			chunks[#chunks + 1] = current
			current, used = {}, 0
		end
		current[#current + 1] = parsed[index]
		used = used + cost
	end
	chunks[#chunks + 1] = current
	return chunks
end

--- Parses a batch of items, or refuses it for any malformed one.
local function parseItems(items)
	if not isList(items, MAX_APPEND) then return nil, 'invalid_items' end
	local out = {}
	for index = 1, #items do
		local entry = items[index]
		if type(entry) ~= 'table' or not validId(entry.id, MAX_ITEM_ID) then
			return nil, 'invalid_item'
		end
		if entry.tab ~= nil and not validId(entry.tab, MAX_ID) then return nil, 'invalid_item' end
		local label = clean(entry.label, 80)
		if label == nil then return nil, 'invalid_item' end
		local detail = entry.detail ~= nil and clean(entry.detail, 120) or nil
		if entry.detail ~= nil and detail == nil then return nil, 'invalid_item' end
		out[index] = { id = entry.id, tab = entry.tab, label = label, detail = detail,
			disabled = entry.disabled == true }
	end
	return out
end

-- ── the surface ─────────────────────────────────────────────────────────────

--- Sends the open payload: the whole view, under this panel's handle.
local function sendOpen()
	local shown = { handle = record.handle }
	for key, value in pairs(record.view) do shown[key] = value end
	return OPX.UI.Send(SURFACE, 'panel:open', shown)
end

--- Re-sends the open while it has not landed, then lets out whatever waited on
--- it. A patch or a batch for a panel the page has never heard of is dropped by
--- the page, so nothing may go out before the open does.
local function flush()
	if record == nil or not pendingOpen then return end
	pendingOpen = not sendOpen()
	if pendingOpen then return end
	local waiting = record.queued
	record.queued = {}
	for index = 1, #waiting do
		OPX.UI.Send(SURFACE, waiting[index].channel, waiting[index].payload)
	end
end

--- Sends one message for the open panel, holding it back until the open lands.
-- Items arrive in batches and a lost batch is a row the player never sees, so a
-- message sent into the gap is queued rather than dropped.
--
-- THE SIZE IS CHECKED BEFORE THE SEND, not after, because after is too late to
-- do anything about: the host refuses an oversized payload whole and
-- `OPX.Surface.Send` still answers that it sent it. Everything this module puts
-- on the wire goes through here, so this is the one place that can be sure.
--
-- A PATCH IS NOT COUNTED, on the argument `Open` makes for the spec: every
-- field of a patch comes out of a parser in `PARSERS` that bounds it, so the
-- largest patch is the largest spec, under five hundred nodes -- a check that
-- cannot fire. It was not free: the walk is ~17 VM instructions a node, 3,600
-- of the 5,600 a fitting-room state cost and ~6,500 of a sixty-box window, in
-- the caller's resume, against a client budget of ~10,000 a resume that
-- unwinds the coroutine silently. `panel:items` is the one payload its parser
-- does not bound, and it is still counted.
-- @param bounded boolean|nil true for a payload built only by `PARSERS`
-- @return boolean
-- @return string|nil the refusal
local function push(channel, payload, bounded)
	if record == nil then return false, 'no_panel_open' end

	local within, nodes = true, 0
	if not bounded then within, nodes = fits(payload) end
	if not within then
		Open77.log.error(('[panel] %s: %s came to %d+ value nodes against a host bound of %d; ' ..
			'not sent'):format(record.owner, channel, nodes, MAX_PAYLOAD_NODES))
		return false, 'payload_too_large'
	end

	flush()
	if not pendingOpen then
		local sent, refused = OPX.UI.Send(SURFACE, channel, payload)
		-- The count above is this module's MODEL of the host's rule. A refusal
		-- that got past it means the model is wrong, and this line is the only
		-- way anybody would find out -- the symptom on the page is a surface that
		-- simply never changes.
		if refused then
			if bounded then
				Open77.log.error(('[panel] %s: the host refused %s, a patch every parser ' ..
					'bounds; MAX_PAYLOAD_NODES is wrong'):format(record.owner, channel))
			else
				Open77.log.error(('[panel] %s: the host refused %s although it counted %d nodes; ' ..
					'MAX_PAYLOAD_NODES is wrong'):format(record.owner, channel, nodes))
			end
			return false, 'payload_refused'
		end
		if not sent then return false, 'page_not_ready' end
		return true
	end

	local waiting = record.queued
	if #waiting >= MAX_QUEUED then
		if not record.queueFull then
			record.queueFull = true
			Open77.log.error(('[panel] %s wrote %d messages before the page was ready')
				:format(record.owner, MAX_QUEUED))
		end
		return false, 'queue_full'
	end
	waiting[#waiting + 1] = { channel = channel, payload = payload }
	return true
end

-- ── the answers a caller gets ───────────────────────────────────────────────

--- Hands one payload to the caller and to the local bus.
-- The callback runs under pcall because it may update, confirm or close this
-- panel, and a raise inside it must not take the page handler down with it.
local function raise(panel, action, fields)
	local payload = fields or {}
	payload.panel = panel.view.id
	payload.handle = panel.handle
	payload.owner = panel.owner
	payload.action = action

	local ran, failure = pcall(panel.on, payload)
	if not ran then
		Open77.log.error(('[panel] %s callback raised on %s: %s')
			:format(panel.owner, action, tostring(failure)))
	end
	TriggerEvent(M.Event.ACTION, payload)
end

--- Takes the dialog down without answering it, and gives its focus back.
-- Its own focus owner sits OVER the panel's, so releasing it hands focus back
-- to the panel rather than dropping it to nothing.
local function clearDialog(panel, withdraw)
	if panel.dialog == nil then return end
	panel.dialog = nil
	if withdraw then push('panel:confirm', { handle = panel.handle, id = false }) end
	OPX.UI.ReleaseFocus(CONFIRM_OWNER)
end

-- ── opening and closing ─────────────────────────────────────────────────────

local wire

--- Takes the open panel down and tells its owner why.
local function closeNow(handle, reason)
	if record == nil then return false, 'no_panel_open' end
	if handle ~= nil and handle ~= record.handle then return false, 'stale_handle' end

	local closing = record
	record = nil
	pendingOpen = false
	OPX.UI.Send(SURFACE, 'panel:close', { handle = closing.handle })
	-- Released here rather than waited for: the page announces the release on
	-- `focus:set` too, but a page that is gone never will, and a focus held
	-- across a close is a player who cannot move.
	OPX.UI.ReleaseFocus(CONFIRM_OWNER)
	OPX.UI.ReleaseFocus(OWNER)
	-- The panel is already gone when this is raised, so a close handler may
	-- open another one.
	raise(closing, 'close', { reason = reason })
	return true
end

-- THE DOWN STATE, THE OWNER SWEEP, ESCAPE AND THE UPKEEP PASS are `OPX.Modal`'s,
-- one implementation for `menu`, `form` and `panel`.
--
-- Escape on the pause key rather than on `panel:dismiss` is the pause menu, AND
-- IT ASKS WHERE ESCAPE WOULD HAVE ASKED. This closed every panel outright,
-- including one whose owner declared `dismiss = 'ask'` -- the editor with
-- unsaved changes -- so the same key that is consulted on the page was not
-- consulted here, and the menu already honours its own `closable` on this
-- path. A dialog up owns Escape, as it does on `panel:dismiss`, and a panel
-- with a dialog up still takes the press when it is on top.
local life = OPX.Modal.New({
	name = 'panel',
	current = function() return record end,
	close = function(reason) closeNow(record.handle, reason) end,
	settings = function() return M.Settings end,
	pauseKey = M.Host.PAUSE_KEY,
	pause = function(panel)
		if panel.dialog ~= nil then return end
		if panel.view.dismiss == 'ask' then
			raise(panel, 'dismiss')
			return
		end
		closeNow(panel.handle, 'pause')
	end,
	job = 'panel:sweep',
	everyMs = SWEEP_MS,
	-- The open is re-sent until the page reports ready: a surface built on first
	-- use is not ready when the first panel opens on it.
	upkeep = function() flush() end,
})

--- Opens a panel, replacing the caller's own or, with `steal`, another's.
-- @author dop42
-- @param spec table
-- @return Result
local function Open(spec)
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local owner = spec.owner
	-- There is no invoking resource inside one runtime, so a caller names
	-- itself. Two anonymous callers would look like one owner and replace each
	-- other's panels in silence instead of refusing with panel_busy.
	if not validId(owner, MAX_ID) then return Result.Err('invalid_owner') end

	-- Nothing to draw on, and there never will be at this start.
	if OPX.UI.Interactive() == nil then return Result.Err('no_surface') end

	if life.Blocked(owner) then return Result.Err('player_down') end
	if record ~= nil and record.owner ~= owner and spec.steal ~= true then
		return Result.Err('panel_busy')
	end

	-- Built before the live panel is taken down, so a refused spec costs the
	-- player nothing.
	local view, reason = buildView(spec)
	if view == nil then return Result.Err(reason) end

	-- THE OPEN IS NOT COUNTED, AND THAT IS AN ARGUMENT RATHER THAN AN OVERSIGHT.
	-- `buildView` bounds every field it accepts -- twelve tabs, twelve sliders,
	-- four actions, eight tools, sixty-four choices, seven labels, and every string
	-- cut to a character count -- which puts the largest spec this module will
	-- build at something under five hundred value nodes. A slider is six fields
	-- and costs thirteen nodes, so the seven a fitting room sends come to under a
	-- hundred, and a `tiles` window is at most three lists of sixty strings, which
	-- is the largest single field a spec can carry and still only 360. A check here
	-- could not fire, and
	-- a refusal nothing can reach is a branch a reader has to disprove. Only
	-- `panel:items` is unbounded by its parser, and that is where the counting
	-- is: see `push` and `chunkItems`.

	-- What a close callback opens in turn is closed too (see `Supersede`).
	if record ~= nil then life.Supersede(record.owner == owner and 'reopened' or 'superseded') end

	nextHandle = nextHandle + 1
	record = {
		handle = nextHandle,
		openedAtMs = OPX.Now(),
		owner = owner,
		on = spec.on,
		view = view,
		-- item id -> the tab it belongs to, so a select can be checked against
		-- what was actually sent rather than against what was clicked.
		items = {},
		-- Held back until the open lands; see push below.
		queued = {},
		count = 0,
		dialog = nil,
	}

	wire()
	pendingOpen = true
	flush()
	return Result.Ok({ handle = record.handle, id = view.id })
end

--- Closes a panel the caller holds the handle of.
-- The handle is the capability: a caller answering about a panel that has
-- already gone would otherwise close the one that replaced it.
-- @author dop42
-- @param handle integer
-- @param reason string|nil
-- @return Result
local function Close(handle, reason)
	if handle == nil then return Result.Err('handle_required') end
	local clean_ = Text.Clean(reason, 32)
	local closed, failure = closeNow(handle, (clean_ ~= nil and clean_ ~= '') and clean_ or 'caller')
	if not closed then return Result.Err(failure) end
	return Result.Ok(true)
end

--- The open panel when a handle names it, or nil and a refusal.
local function held(handle)
	if record == nil then return nil, 'no_panel_open' end
	if handle ~= nil and handle ~= record.handle then return nil, 'stale_handle' end
	return record
end

--- Patches the open panel. Only the fields the patch carries change.
-- @author dop42
-- @param handle integer
-- @param patch table
-- @return Result
local function Update(handle, patch)
	local panel, refused = held(handle)
	if panel == nil then return Result.Err(refused) end
	local parsed, reason = parsePatch(patch)
	if parsed == nil then return Result.Err(reason) end

	if parsed.clearItems then
		panel.items, panel.count = {}, 0
	end
	for key, value in pairs(parsed) do
		if key == 'selected' then
			-- Merged, not replaced: a patch naming one tab's choice must not
			-- forget the others.
			for tab, item in pairs(value) do panel.view.selected[tab] = item end
		elseif key ~= 'clearItems' then
			panel.view[key] = value
		end
	end

	parsed.handle = panel.handle
	local sent, refused = push('panel:update', parsed, true)
	if not sent then return Result.Err(refused or 'page_not_ready') end
	return Result.Ok(true)
end

--- Adds a batch of items to the open panel.
-- @author dop42
-- @param handle integer
-- @param items table
-- @param done boolean|nil The last batch: the panel stops saying it is loading.
-- @return Result
local function Append(handle, items, done)
	local panel, refused = held(handle)
	if panel == nil then return Result.Err(refused) end
	local parsed, reason = parseItems(items)
	if parsed == nil then return Result.Err(reason) end
	if panel.count + #parsed > MAX_ITEMS then return Result.Err('too_many_items') end

	for index = 1, #parsed do
		local item = parsed[index]
		if panel.items[item.id] == nil then panel.count = panel.count + 1 end
		panel.items[item.id] = item.tab or ''
	end
	if done == true then panel.view.loading = false end

	-- ONE APPEND IS AS MANY SENDS AS THE HOST NEEDS, and `done` rides the last.
	-- Refusing an oversized batch back at the caller was the other option and it
	-- is the wrong one: a caller cannot compute this bound without knowing how
	-- this module parses an item, and the fitting room -- which does not, and
	-- should not -- is the whole reason the defect existed.
	local chunks = chunkItems(parsed)
	for index = 1, #chunks do
		local last = index == #chunks
		local sent, refused = push('panel:items',
			{ handle = panel.handle, items = chunks[index], done = last and done == true })
		-- A batch that failed part way has already put rows on the page, and the
		-- caller is told so it can decide; this module cannot un-send them.
		if not sent then return Result.Err(refused or 'page_not_ready') end
	end
	return Result.Ok(true)
end

--- Puts a yes-or-no dialog over the open panel, or withdraws the one that is
--- up when `question` is absent.
-- A question withdrawn is a question that stopped being true, and it must be
-- takeable back: the page answers a dialog nobody is waiting for otherwise.
-- @author dop42
-- @param handle integer
-- @param question table|nil id, title, text, yes, no
-- @return Result
local function Confirm(handle, question)
	local panel, refused = held(handle)
	if panel == nil then return Result.Err(refused) end

	if question == nil or question == false then
		clearDialog(panel, true)
		return Result.Ok(true)
	end
	if type(question) ~= 'table' or not validId(question.id, MAX_ID) then
		return Result.Err('invalid_dialog')
	end

	local shown = {
		handle = panel.handle,
		id = question.id,
		title = clean(question.title or '', 60),
		text = clean(question.text or '', 240),
		yes = clean(question.yes or panel.view.labels.confirmYes, 40),
		no = clean(question.no or panel.view.labels.confirmNo, 40),
	}
	if shown.title == nil or shown.text == nil or shown.yes == nil or shown.no == nil then
		return Result.Err('invalid_dialog')
	end

	panel.dialog = question.id
	local sent, refused = push('panel:confirm', shown)
	if not sent then return Result.Err(refused or 'page_not_ready') end
	return Result.Ok(true)
end

--- Whether a panel is open, whose it is, and how many items it holds.
-- @author dop42
-- @return Result
local function State()
	if record == nil then return Result.Ok({ open = false }) end
	return Result.Ok({
		open = true,
		handle = record.handle,
		owner = record.owner,
		id = record.view.id,
		tab = record.view.tab,
		items = record.count,
		busy = record.view.busy == true,
		dialog = record.dialog,
	})
end

-- ── what the player did ─────────────────────────────────────────────────────

--- The open panel when a page payload names it, or nil for a stale one.
local fromPage = life.FromPage

--- Whether a button id is one this panel currently draws.
local function isButton(panel, id)
	local view = panel.view
	-- THE CATEGORY ROW IS IN THIS LIST, and forgetting it is the whole bug this
	-- shape invites: a button the page draws but this function does not know
	-- about is a button that does nothing at all when it is pressed, silently,
	-- with the panel still up and the caller still waiting to be told.
	for _, list in ipairs({ view.actions, view.tools, view.groups }) do
		for index = 1, #list do
			if list[index].id == id then return list[index] end
		end
	end
	local plate = view.summary
	if type(plate) == 'table' and type(plate.action) == 'table' and plate.action.id == id then
		return plate.action
	end
	return nil
end

--- An item the player clicked.
local function onSelect(payload)
	local panel = fromPage(payload)
	if panel == nil or panel.view.busy then return end
	if not validId(payload.item, MAX_ITEM_ID) then return end
	-- Checked against what was actually sent: the page's list may be a batch
	-- ahead of, or behind, what this panel believes it holds.
	local tab = panel.items[payload.item]
	if tab == nil then return end
	raise(panel, 'select', { item = payload.item, tab = tab ~= '' and tab or nil })
end

--- The pointer resting on an item, for a panel that asked to hear about it.
local function onHover(payload)
	local panel = fromPage(payload)
	if panel == nil or not panel.view.hover then return end
	if not validId(payload.item, MAX_ITEM_ID) then return end
	local tab = panel.items[payload.item]
	if tab == nil then return end
	raise(panel, 'hover', { item = payload.item, tab = tab ~= '' and tab or nil })
end

--- The pointer leaving the grid.
local function onLeave(payload)
	local panel = fromPage(payload)
	if panel == nil or not panel.view.hover then return end
	raise(panel, 'leave')
end

--- A tab the player switched to.
local function onTab(payload)
	local panel = fromPage(payload)
	if panel == nil or not validId(payload.tab, MAX_ID) then return end
	for _, tab in ipairs(panel.view.tabs) do
		if tab.id == payload.tab then
			panel.view.tab = tab.id
			raise(panel, 'tab', { tab = tab.id })
			return
		end
	end
end

--- A slider the player moved, previewing or letting go.
--
-- CHECKED AGAINST THE TRACK THIS MODULE DREW, the same way a click is checked
-- against the items it sent. The caller is handed an index it can trust to be a
-- whole number inside the range it declared, so the one thing it still has to do
-- is turn that index into whatever its own list holds there.
local function onSlide(payload)
	local panel = fromPage(payload)
	if panel == nil or panel.view.busy then return end
	if not validId(payload.id, MAX_ID) then return end
	for _, slider in ipairs(panel.view.sliders) do
		if slider.id == payload.id then
			if slider.disabled then return end
			local at = tonumber(payload.index)
			if at == nil or at % 1 ~= 0 or at < 0 or at > slider.count then return end
			-- The page's own thumb position, held while the player drags, is the
			-- one thing this module does NOT write back into the view: the caller
			-- answers with a `sliders` patch and that patch is the truth.
			raise(panel, 'slide',
				{ id = slider.id, index = at, commit = payload.commit == true })
			return
		end
	end
end

--- The grid asking for the window that follows the one it holds.
--
-- CHECKED AGAINST THE TRACK, exactly as a slide is, because a tile window and a
-- slider thumb point into the same list: the caller declared how long it is, so
-- a request that starts past the end is a page that has lost count and is
-- dropped rather than forwarded. The caller is handed a whole number inside the
-- range it named and nothing else -- how many it answers with is its own bound,
-- not the page's, which is why there is no `count` on this message.
local function onTiles(payload)
	local panel = fromPage(payload)
	if panel == nil then return end
	if not validId(payload.slot, MAX_ID) then return end
	for _, slider in ipairs(panel.view.sliders) do
		if slider.id == payload.slot then
			local from = tonumber(payload.from)
			if from == nil or from % 1 ~= 0 or from < 1 or from > slider.count then return end
			raise(panel, 'tiles', { slot = slider.id, from = from })
			return
		end
	end
end

--- A button the player pressed.
local function onAction(payload)
	local panel = fromPage(payload)
	if panel == nil or panel.view.busy then return end
	if not validId(payload.id, MAX_ID) then return end
	local button = isButton(panel, payload.id)
	-- A button that is gone, or drawn dimmed, is not a button that was pressed.
	if button == nil or button.disabled then return end
	raise(panel, 'action', { id = button.id })
end

--- The dialog's answer.
local function onAnswer(payload)
	local panel = fromPage(payload)
	if panel == nil or panel.dialog == nil then return end
	-- A dialog that was withdrawn and replaced answers under its own id only.
	if payload.id ~= panel.dialog then return end
	clearDialog(panel, false)
	raise(panel, 'confirm', { item = payload.id, value = payload.value == true })
end

--- Escape on the panel itself. The page keeps focus until this answers with a
--- close, so a panel that asked to be consulted stays up until its owner says.
local function onDismiss(payload)
	local panel = fromPage(payload)
	if panel == nil then return end
	if panel.dialog ~= nil then
		-- The dialog owns Escape while it is up; this is a race with its own
		-- answer, and the dialog wins.
		return
	end
	if panel.view.dismiss == 'ask' then
		raise(panel, 'dismiss')
		return
	end
	closeNow(panel.handle, 'dismissed')
end

-- Answers the surface-wide focus broadcast for this module's own owners, the
-- panel and its dialog: see `OPX.Modal.FocusResponder`.
local onFocus = OPX.Modal.FocusResponder(FOCUS)

--- Wires the page channels once, on the first open.
wire = function()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'panel:select', onSelect)
	OPX.UI.On(SURFACE, 'panel:hover', onHover)
	OPX.UI.On(SURFACE, 'panel:leave', onLeave)
	OPX.UI.On(SURFACE, 'panel:tab', onTab)
	OPX.UI.On(SURFACE, 'panel:slide', onSlide)
	OPX.UI.On(SURFACE, 'panel:tiles', onTiles)
	OPX.UI.On(SURFACE, 'panel:action', onAction)
	OPX.UI.On(SURFACE, 'panel:answer', onAnswer)
	OPX.UI.On(SURFACE, 'panel:dismiss', onDismiss)
	OPX.UI.On(SURFACE, 'focus:set', onFocus)
end

-- ── lifecycle ───────────────────────────────────────────────────────────────

--- Builds the held state.
-- @author dop42
function M.Init()
	record = nil
	nextHandle = 0
	pendingOpen = false
	wired = false
	life.Reset()
end

--- Publishes the panel contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('panel', 1, {
		Open = Open,
		Close = Close,
		Update = Update,
		Append = Append,
		Confirm = Confirm,
		State = State,
	})
end

--- Wires the down state, the pause key and the owner sweep.
-- @author dop42
function M.Start()
	life.Start()
end

--- Closes whatever is open and hands the cursor back.
-- @author dop42
function M.Stop()
	if record ~= nil then closeNow(record.handle, 'stopped') end
	-- A close with no handle blanks whatever the page still holds, which is the
	-- one case where this module cannot know what that is.
	OPX.UI.Send(SURFACE, 'panel:close', {})
	OPX.UI.ReleaseFocus(CONFIRM_OWNER)
	OPX.UI.ReleaseFocus(OWNER)
end
