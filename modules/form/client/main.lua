--- The one open form: its validated fields, the accepted buffers, and the frame.
-- @author dop42

local M = OPX.Modules.Get('form')

local Result = OPX.Result
local Text = OPX.Text

local SURFACE = 'interactive'
local OWNER = 'form'

-- Eight fields is the point where a form stops being a question and becomes a
-- list, and a list is what the menu draws.
local MAX_FIELDS = 8
local MAX_OPTIONS = 64

-- A caller's opaque table rides in the answer, and the host discards an event
-- carrying more than 1024 value nodes without a word: it is held to
-- `OPX.Modal.DATA_NODES` and `DATA_DEPTH`.

local MAX_LABEL = 96
local MAX_OPTION_LABEL = 48
local MAX_OPTION_VALUE = 96
local MAX_PLACEHOLDER = 64
local MAX_DESCRIPTION = 160
local MAX_SUFFIX = 8
local MAX_STATUS = 120
local MAX_NAME = 64

-- Text answer length when the caller names none, and the hardest it may ask
-- for: the whole answer rides in one payload, so the ceiling is a payload
-- bound rather than a taste.
local DEFAULT_TEXT = 96
local MAX_TEXT = 512

local MAX_PATTERN = 64
local MAX_CAPTURES = 32

-- Named classes a text field may accept. A caller cannot pass a class of its
-- own: a malformed one raises inside string.match, and a slow one would run
-- against every keystroke.
local CHARSETS = {
	alnum = '^[%w]+$',
	alpha = '^[%a]+$',
	digits = '^[%d]+$',
	hex = '^[%x]+$',
	name = "^[%w %-_%.']+$",
}

-- The five keys the page forwards. Everything else belongs to the focused input.
local KEYS = { up = true, down = true, left = true, right = true, enter = true }

local UPKEEP_MS = 250

-- What this module's focus owners are given. The page names an owner and never
-- says what it wants: asking for the cursor is not the page's decision.
-- `focus:set` is a broadcast every view module listens to, and each answers for
-- its own owners only -- a module must not acquire, or release, focus on behalf
-- of a view it does not own.
local FOCUS = {
	form = { keyboard = true, cursor = false },
}

-- The one open form, or nil.
local record

local nextHandle = 0

-- True while `form:open` has not reached the page. The interactive surface is
-- built on first use and a send made before it reports ready is dropped, not
-- queued, so the open is re-sent from the upkeep job until it lands.
local pendingOpen = false

-- Wiring the channels builds the surface, so it waits for the first open.
local wired = false

-- ── text, names and the caller's data ───────────────────────────────────────

-- Whether a value is a number that is neither NaN nor infinite. The one shared
-- predicate, aliased rather than wrapped: a one-line wrapper is a second name
-- for the same answer and the only thing it can ever do is drift.
local finite = OPX.Math.IsFinite

-- The id check and the payload bound are `OPX.Modal`'s, shared with `menu` and
-- `panel`, and aliased here rather than wrapped.
local validName = OPX.Modal.ValidName
local dataFault = OPX.Modal.DataFault

--- Display text with control characters blanked, REFUSED past a character
--- count rather than cut. Nothing a caller sends comes back shorter than it
--- was sent: half of a caller's label is not something to guess about.
local function exact(value, maximum)
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end
	value = value:gsub('%c', ' ')
	if #value <= maximum then return value end
	if Text.Span(value, maximum) >= #value then return value end
	return nil
end

-- ── patterns ────────────────────────────────────────────────────────────────

--- The index after a pattern set, or nil when it is never closed.
local function classEnd(pattern, index, size)
	if pattern:sub(index, index) == '^' then index = index + 1 end
	repeat
		if index > size then return nil end
		local character = pattern:sub(index, index)
		index = index + 1
		if character == '%' and index <= size then index = index + 1 end
	until pattern:sub(index, index) == ']'
	return index + 1
end

--- Whether a Lua pattern would never raise a malformed-pattern error.
-- Checked by structure rather than by trying it: a pattern that raises inside
-- string.match takes its caller down, and a caller's typo must not be able to.
local function wellFormed(pattern)
	local size = #pattern
	local index = pattern:sub(1, 1) == '^' and 2 or 1
	local level, open, closed = 0, {}, {}
	while index <= size do
		local character = pattern:sub(index, index)
		if character == '(' then
			level = level + 1
			if level > MAX_CAPTURES then return false end
			if pattern:sub(index + 1, index + 1) == ')' then
				closed[level] = true
				index = index + 2
			else
				open[#open + 1] = level
				index = index + 1
			end
		elseif character == ')' then
			if #open == 0 then return false end
			closed[open[#open]] = true
			open[#open] = nil
			index = index + 1
		elseif character == '%' then
			local class = pattern:sub(index + 1, index + 1)
			if class == '' then return false end
			if class == 'b' then
				if index + 3 > size then return false end
				index = index + 4
			elseif class == 'f' then
				if pattern:sub(index + 2, index + 2) ~= '[' then return false end
				index = classEnd(pattern, index + 3, size)
				if index == nil then return false end
			elseif class:find('%d') then
				if not closed[tonumber(class)] then return false end
				index = index + 2
			else
				index = index + 2
			end
		elseif character == '[' then
			index = classEnd(pattern, index + 1, size)
			if index == nil then return false end
		else
			index = index + 1
		end
	end
	return #open == 0
end

--- Anchors a caller's pattern at both ends, so it matches the WHOLE answer.
local function anchored(pattern)
	if pattern:sub(1, 1) ~= '^' then pattern = '^' .. pattern end
	local escapes = pattern:match('(%%*)%$$')
	if escapes == nil or #escapes % 2 == 1 then pattern = pattern .. '$' end
	return pattern
end

--- Whether text sits inside the field's character class.
local function withinCharset(entry, text)
	if entry.charset == nil or text == '' then return true end
	return text:match(entry.charset) ~= nil
end

--- Whether the whole text matches the field's pattern.
-- An empty field passes: emptiness is what `required` answers.
local function matchesPattern(entry, text)
	if entry.pattern == nil or text == '' then return true end
	local ok, matched = pcall(string.match, text, entry.pattern)
	if ok then return matched ~= nil end
	if not entry.patternFailed then
		entry.patternFailed = true
		Open77.log.warn(('[form] the pattern of field %s failed: %s')
			:format(entry.id, tostring(matched)))
	end
	return false
end

-- ── the fields ──────────────────────────────────────────────────────────────

--- Validates a slider and fills its defaults, clamping the starting value.
-- The range is `OPX.Modal`'s; a suffix past its length is refused, not cut.
local function normalizeSlider(slider)
	local settled, reason = OPX.Modal.SliderRange(slider)
	if settled == nil then return nil, reason end
	local suffix = ''
	if slider.suffix ~= nil then
		suffix = exact(slider.suffix, MAX_SUFFIX)
		if suffix == nil then return nil, 'invalid_slider_suffix' end
	end
	settled.suffix = suffix
	return settled
end

--- The value an option answers with, kept exactly as the caller wrote it.
local function optionValue(option, label)
	local value = option.value
	if value == nil then return label end
	if type(value) == 'number' then
		return finite(value) and value or nil
	end
	if type(value) == 'string' and exact(value, MAX_OPTION_VALUE) ~= nil then return value end
	return nil
end

--- Validates a choice field's options and its starting selection.
local function normalizeOptions(field)
	local raw = field.options
	if type(raw) ~= 'table' then return nil, 'invalid_options' end
	local total = #raw
	if total == 0 then return nil, 'empty_options' end
	if total > MAX_OPTIONS then return nil, 'too_many_options' end

	local options = {}
	for index = 1, total do
		local option = raw[index]
		if type(option) == 'string' or type(option) == 'number' then
			option = { label = option }
		end
		if type(option) ~= 'table' then return nil, 'invalid_option' end
		local label = exact(option.label, MAX_OPTION_LABEL)
		if label == nil or label == '' then return nil, 'invalid_option' end
		local value = optionValue(option, label)
		if value == nil then return nil, 'invalid_option_value' end
		options[index] = { label = label, value = value }
	end

	local selected = 1
	if field.selected ~= nil then
		if not finite(field.selected) or field.selected % 1 ~= 0 then
			return nil, 'invalid_selected'
		end
		selected = math.floor(field.selected)
		if selected < 1 or selected > total then return nil, 'invalid_selected' end
	end
	return { options = options, selected = selected }
end

--- Validates what a text field carries beyond the fields every kind shares.
local function normalizeTyped(field)
	local maxLength = DEFAULT_TEXT
	if field.maxLength ~= nil then
		if not finite(field.maxLength) or field.maxLength % 1 ~= 0 then
			return nil, 'invalid_max_length'
		end
		maxLength = math.floor(field.maxLength)
		if maxLength < 1 or maxLength > MAX_TEXT then return nil, 'invalid_max_length' end
	end

	local placeholder
	if field.placeholder ~= nil then
		placeholder = exact(field.placeholder, MAX_PLACEHOLDER)
		if placeholder == nil then return nil, 'invalid_placeholder' end
	end

	local charset
	if field.charset ~= nil then
		if type(field.charset) ~= 'string' then return nil, 'invalid_charset' end
		charset = CHARSETS[field.charset]
		if charset == nil then return nil, 'unknown_charset' end
	end

	local pattern
	if field.pattern ~= nil then
		local given = field.pattern
		if type(given) ~= 'string' or #given == 0 or #given > MAX_PATTERN then
			return nil, 'invalid_pattern'
		end
		if not wellFormed(given) then return nil, 'invalid_pattern' end
		pattern = anchored(given)
	end

	local text = ''
	if field.value ~= nil then
		text = exact(field.value, maxLength)
		if text == nil then return nil, 'invalid_value' end
	end

	return {
		text = text,
		placeholder = placeholder,
		maxLength = maxLength,
		pattern = pattern,
		charset = charset,
		required = field.required == true or nil,
	}
end

--- Validates one field, deriving its kind from its shape.
-- `options` makes a choice, `slider` makes a slider, and anything else is a
-- typed line. The checks run in that order, so a field carrying both is a
-- choice and the slider is dropped without a word.
local function normalizeField(field, index)
	if type(field) ~= 'table' then return nil, 'field_must_be_a_table' end

	local id = field.id
	if id == nil then
		id = 'field_' .. tostring(index)
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_field_id'
	end

	local label = exact(field.label, MAX_LABEL)
	if label == nil or label == '' then return nil, 'invalid_field_label' end

	local description
	if field.description ~= nil then
		description = exact(field.description, MAX_DESCRIPTION)
		if description == nil then return nil, 'invalid_field_description' end
	end

	-- `ack` is the last keystroke this field has been RULED ON, and it rides back
	-- on every frame. Without it a frame is anonymous: the page cannot tell the
	-- answer to the character under the caret from the answer to the one before
	-- it, and putting the older buffer back erases what the player just typed.
	local entry = { id = id, label = label, description = description, ack = 0 }

	if field.options ~= nil then
		local choice, reason = normalizeOptions(field)
		if choice == nil then return nil, reason end
		entry.kind = 'choice'
		entry.options = choice.options
		entry.selected = choice.selected
		return entry
	end

	if field.slider ~= nil then
		local slider, reason = normalizeSlider(field.slider)
		if slider == nil then return nil, reason end
		entry.kind = 'slider'
		entry.slider = slider
		return entry
	end

	local typed, reason = normalizeTyped(field)
	if typed == nil then return nil, reason end
	entry.kind = 'text'
	entry.text = typed.text
	entry.placeholder = typed.placeholder
	entry.maxLength = typed.maxLength
	entry.pattern = typed.pattern
	entry.charset = typed.charset
	entry.required = typed.required
	-- A starting value its own field would refuse is a caller's bug, not a
	-- player's, and it is caught here rather than on the first keystroke.
	if not withinCharset(entry, entry.text) then return nil, 'invalid_value' end
	if not matchesPattern(entry, entry.text) then return nil, 'invalid_value' end
	return entry
end

--- Validates every field of a spec, refusing duplicate ids.
local function normalizeFields(fields)
	if type(fields) ~= 'table' then return nil, 'fields_must_be_a_table' end
	local total = #fields
	if total == 0 then return nil, 'empty_form' end
	if total > MAX_FIELDS then return nil, 'too_many_fields' end

	local list, seen = {}, {}
	for index = 1, total do
		local entry, reason = normalizeField(fields[index], index)
		if entry == nil then return nil, reason end
		-- The answer is keyed by id, so a duplicate would lose one field.
		if seen[entry.id] then return nil, 'duplicate_field_id' end
		seen[entry.id] = true
		list[index] = entry
	end
	return list
end

-- ── the form ────────────────────────────────────────────────────────────────

--- Whether a value is text the status line accepts.
local function validStatus(value)
	return value == nil or exact(value, MAX_STATUS) ~= nil
end

--- The field a named cursor resolves to, falling back to the first.
local function cursorIndex(fields, wanted)
	if type(wanted) == 'string' then
		for index = 1, #fields do
			if fields[index].id == wanted then return index end
		end
	elseif finite(wanted) and wanted % 1 == 0 then
		local index = math.floor(wanted)
		if fields[index] ~= nil then return index end
	end
	return 1
end

--- Builds a form record from a spec, whole or not at all.
local function build(owner, spec)
	if type(spec.on) ~= 'function' then return nil, 'callback_required' end

	local id = spec.id
	if id == nil then
		id = owner
	elseif not validName(id, MAX_NAME) then
		return nil, 'invalid_form_id'
	end

	local title = exact(spec.title, MAX_LABEL)
	if title == nil or title == '' then title = owner:upper() end

	local description
	if spec.description ~= nil then
		description = exact(spec.description, MAX_DESCRIPTION)
		if description == nil then return nil, 'invalid_description' end
	end

	if not validStatus(spec.status) then return nil, 'invalid_status' end

	local fault = dataFault(spec.data, 'invalid_form_data', 'form_data_too_large')
	if fault then return nil, fault end

	local fields, reason = normalizeFields(spec.fields)
	if fields == nil then return nil, reason end

	return {
		owner = owner,
		id = id,
		title = title,
		description = description,
		on = spec.on,
		data = spec.data,
		fields = fields,
		index = cursorIndex(fields, spec.cursor),
	}
end

--- The focused field.
local function entryOf(owned)
	return owned.fields[owned.index]
end

--- Moves the focus between fields, wrapping at both ends.
local function move(owned, delta)
	local total = #owned.fields
	if total <= 1 then return false end
	owned.index = ((owned.index - 1 + delta) % total) + 1
	return true
end

--- Cycles a choice or steps a slider, answering whether it moved.
local function adjust(entry, delta)
	local kind = entry.kind
	if kind == 'choice' then
		local total = #entry.options
		if total <= 1 then return false end
		entry.selected = ((entry.selected - 1 + delta) % total) + 1
		return true
	elseif kind == 'slider' then
		return OPX.Modal.StepSlider(entry.slider, delta)
	end
	return false
end

--- Accepts or refuses a candidate buffer the page reported.
-- Answers the refusal key and its parameters, or nil when the text was kept.
local function edit(entry, text)
	if entry.kind ~= 'text' then return 'form.refuse.character' end
	if type(text) ~= 'string' then return 'form.refuse.character' end
	local clean = text:gsub('%c', '')
	-- MEASURED NATIVELY WHERE IT CAN BE. This runs on every keystroke, inside
	-- the page callback's resume, and `Text.Span` walks the buffer a byte at a
	-- time in Lua -- up to four bytes a character of the limit, about 18,000
	-- instructions at a 512-character field of accented text. A buffer no longer
	-- in bytes than the limit is within it in characters, and `utf8.len` counts
	-- the rest in C; only a buffer that is not valid UTF-8 falls back to the walk.
	if #clean > entry.maxLength then
		local count = utf8 and utf8.len(clean) or nil
		if count ~= nil then
			if count > entry.maxLength then return 'form.refuse.tooLong', { max = entry.maxLength } end
		elseif Text.Span(clean, entry.maxLength) < #clean then
			return 'form.refuse.tooLong', { max = entry.maxLength }
		end
	end
	if not withinCharset(entry, clean) then return 'form.refuse.character' end
	entry.text = clean
	return nil
end

--- The first field that refuses to be submitted.
local function check(owned)
	for index = 1, #owned.fields do
		local entry = owned.fields[index]
		if entry.kind == 'text' then
			if entry.required and entry.text == '' then
				return index, 'form.refuse.required'
			end
			if not matchesPattern(entry, entry.text) then
				return index, 'form.refuse.format'
			end
		end
	end
	return nil
end

--- The machine-readable value one field answers with.
local function rawValue(entry)
	local kind = entry.kind
	if kind == 'choice' then return entry.options[entry.selected].value end
	if kind == 'slider' then return entry.slider.value end
	return entry.text
end

--- The rendered value of one field, for the page.
local function shownValue(entry)
	local kind = entry.kind
	if kind == 'choice' then return entry.options[entry.selected].label end
	if kind == 'slider' then
		local slider = entry.slider
		local number = slider.value
		local shown = number % 1 == 0 and tostring(math.floor(number))
			or string.format('%.2f', number)
		return shown .. slider.suffix
	end
	return entry.text
end

--- Every field's answer, keyed by field id.
local function answers(owned)
	local values = {}
	for index = 1, #owned.fields do
		local entry = owned.fields[index]
		values[entry.id] = rawValue(entry)
	end
	return values
end

-- ── the frame ───────────────────────────────────────────────────────────────

--- The key caps drawn under the fields, for the focused field's kind.
local function keyCaps(owned)
	local caps = {}
	if #owned.fields > 1 then
		caps[#caps + 1] = { key = 'UP DOWN', label = locale('form.key.field') }
	end
	if entryOf(owned).kind == 'text' then
		caps[#caps + 1] = { key = 'A-Z', label = locale('form.key.edit') }
	else
		caps[#caps + 1] = { key = 'LEFT RIGHT', label = locale('form.key.change') }
	end
	caps[#caps + 1] = { key = 'ENTER', label = locale('form.key.confirm') }
	caps[#caps + 1] = { key = 'ESC', label = locale('form.key.cancel') }
	return caps
end

--- Everything the page needs to draw one frame.
local function frame(owned)
	local rows = {}
	for index = 1, #owned.fields do
		local entry = owned.fields[index]
		local kind = entry.kind
		local row = {
			id = entry.id,
			kind = kind,
			label = entry.label,
			-- LEFT and RIGHT belong to the caret unless the frame says a row
			-- spins. This one flag is what lets a typed line and an
			-- arrow-stepped list share the surface.
			spin = (kind ~= 'text') or nil,
			on = (index == owned.index) or nil,
		}
		if kind == 'text' then
			row.text = entry.text
			row.placeholder = entry.placeholder
			-- The field's own bound, which the page counts the buffer against.
			row.max = entry.maxLength
			-- Elided while nothing has been typed, like `spin` and `on`: a form
			-- nobody has touched carries no acknowledgement and the page reads
			-- the absence as zero.
			row.ack = entry.ack > 0 and entry.ack or nil
		else
			row.value = shownValue(entry)
		end
		if kind == 'slider' then
			row.min = entry.slider.min
			row.max = entry.slider.max
			-- The number itself, not a ratio: a value re-derived from a rounded
			-- fill would not step evenly.
			row.number = entry.slider.value
		end
		rows[index] = row
	end

	local focused = entryOf(owned)
	return {
		handle = owned.handle,
		title = owned.title,
		note = owned.description,
		rows = rows,
		hint = focused.description,
		keys = keyCaps(owned),
		status = owned.status and owned.status.text or nil,
		statusBad = (owned.status ~= nil and owned.status.bad) or nil,
	}
end

--- Sends the open payload: the configuration and the first frame in one, which
--- is what the page's open handler reads.
local function sendOpen()
	local payload = frame(record)
	payload.anchor = M.Settings.ANCHOR
	payload.width = M.Settings.WIDTH
	payload.dim = M.Settings.DIM ~= false
	return OPX.UI.Send(SURFACE, 'form:open', payload)
end

--- Draws whatever is open. While the open has not landed it is re-sent instead
--- of a frame: a frame for a form the page has never heard of is dropped.
local function draw()
	if record == nil then return end
	if pendingOpen then
		pendingOpen = not sendOpen()
		return
	end
	OPX.UI.Send(SURFACE, 'form:frame', frame(record))
end

-- ── the answer ──────────────────────────────────────────────────────────────

local wire

--- Stores or clears the status line without drawing. Answers whether it moved.
local function writeStatus(owned, text, bad)
	local clean = text ~= nil and exact(text, MAX_STATUS) or nil
	if clean == nil or clean == '' then
		if owned.status == nil then return false end
		owned.status = nil
	else
		owned.status = { text = clean, bad = bad == true, atMs = OPX.Now() }
	end
	return true
end

--- Shows one of this module's own refusals, in the player's language.
-- Drawn whether or not the line itself moved. A refusal is also the ONLY answer
-- the page will get to the keystroke it refused, and the page is sitting on a
-- character that nothing but this frame takes back.
local function notice(key, params)
	if record == nil then return end
	writeStatus(record, locale(key, params), true)
	draw()
end

--- Answers the open form once and takes it down.
-- `values` is set on a submit and on nothing else, so a handler can branch on
-- the action alone and never read a half-answer.
local function finish(action, reason)
	local answered = record
	record = nil
	pendingOpen = false
	OPX.UI.Send(SURFACE, 'form:close', { handle = answered.handle })
	-- Released here rather than waited for: the page announces the release on
	-- `focus:set` too, but a page that is gone never will, and a focus held
	-- across a close is a player who cannot move.
	OPX.UI.ReleaseFocus(OWNER)

	local payload = {
		form = answered.id,
		handle = answered.handle,
		owner = answered.owner,
		action = action,
		reason = reason,
		data = answered.data,
		values = action == 'submit' and answers(answered) or nil,
	}
	-- The form is already gone when this is raised, so a handler may open
	-- another one.
	local ran, failure = pcall(answered.on, payload)
	if not ran then
		Open77.log.error(('[form] %s callback raised on %s: %s')
			:format(answered.owner, action, tostring(failure)))
	end
	TriggerEvent(M.Event.ANSWER, payload)
end

-- ── the contract ────────────────────────────────────────────────────────────

--- Clears the status line once it has been up long enough.
local function expireStatus(atMs)
	if record == nil or record.status == nil then return end
	local life = finite(M.Settings.STATUS_MS) and M.Settings.STATUS_MS or 6000
	if atMs - record.status.atMs < life then return end
	record.status = nil
	draw()
end

-- THE DOWN STATE, THE OWNER SWEEP, ESCAPE AND THE UPKEEP PASS are `OPX.Modal`'s,
-- one implementation for `menu`, `form` and `panel`. Every way a form leaves
-- answers it as a cancel. Escape on the pause key rather than on `form:dismiss`
-- is the pause menu.
local life = OPX.Modal.New({
	name = 'form',
	current = function() return record end,
	close = function(reason) finish('cancel', reason) end,
	settings = function() return M.Settings end,
	pauseKey = M.Host.PAUSE_KEY,
	pause = function() finish('cancel', 'pause') end,
	job = 'form:upkeep',
	everyMs = UPKEEP_MS,
	-- The open is re-sent until the page reports ready: a surface built on first
	-- use is not ready when the first form opens on it.
	upkeep = function()
		if pendingOpen then draw() end
		expireStatus(OPX.Now())
	end,
})

--- Asks the player for one or more values, refusing the spec whole if any
--- field is malformed.
-- @author dop42
-- @param spec table
-- @return Result
local function Open(spec)
	if type(spec) ~= 'table' then return Result.Err('spec_must_be_a_table') end

	local owner = spec.owner
	-- There is no invoking resource inside one runtime, so a caller names
	-- itself. Two anonymous callers would look like one owner and cancel each
	-- other's forms in silence instead of refusing with form_busy.
	if not validName(owner, MAX_NAME) then return Result.Err('invalid_owner') end

	-- Nothing to ask on, and there never will be at this start.
	if OPX.UI.Interactive() == nil then return Result.Err('no_surface') end

	if life.Blocked(owner) then return Result.Err('player_down') end
	-- There is no steal: a form holds a half-typed answer, and taking one over
	-- loses it.
	if record ~= nil and record.owner ~= owner then return Result.Err('form_busy') end

	-- Built before the live form is taken down, so a refused spec costs the
	-- player nothing.
	local built, reason = build(owner, spec)
	if built == nil then return Result.Err(reason) end

	-- What a cancel callback opens in turn is closed too (see `Supersede`).
	life.Supersede('reopened')

	nextHandle = nextHandle + 1
	built.handle = nextHandle
	built.openedAtMs = OPX.Now()
	record = built
	if spec.status ~= nil then writeStatus(record, spec.status, spec.statusBad) end

	wire()
	pendingOpen = true
	draw()
	return Result.Ok({ handle = record.handle, id = record.id, fields = #record.fields })
end

--- Takes a form the caller holds the handle of back down. It still answers,
--- exactly once, as a cancel.
-- The handle is the capability: a caller answering about a form that has
-- already gone would otherwise cancel the one that replaced it.
-- @author dop42
-- @param handle integer
-- @return Result
local function Close(handle)
	if handle == nil then return Result.Err('handle_required') end
	if record == nil then return Result.Err('no_form_open') end
	if handle ~= record.handle then return Result.Err('stale_handle') end
	finish('cancel', 'caller')
	return Result.Ok(true)
end

--- Writes the transient line under the fields, or clears it with a nil text.
-- The same line carries this module's own refusals, so a caller's line may be
-- replaced by one of those while the player types.
-- @author dop42
-- @param handle integer
-- @param text string|number|nil
-- @param bad boolean|nil True draws the line as a failure.
-- @return Result
local function SetStatus(handle, text, bad)
	if record == nil then return Result.Err('no_form_open') end
	if handle ~= nil and handle ~= record.handle then return Result.Err('stale_handle') end
	if not validStatus(text) then return Result.Err('invalid_status') end
	if writeStatus(record, text, bad) then draw() end
	return Result.Ok(true)
end

--- Where the player is in the open form.
-- It never reports what has been typed, not even to the owner: the answer is
-- the callback, and there is no second way to read it.
-- @author dop42
-- @return Result
local function State()
	if record == nil then return Result.Ok({ open = false }) end
	return Result.Ok({
		open = true,
		handle = record.handle,
		owner = record.owner,
		form = record.id,
		title = record.title,
		index = record.index,
		total = #record.fields,
		fieldId = entryOf(record).id,
	})
end

-- ── what the player did ─────────────────────────────────────────────────────

--- The open form when a page payload names it, or nil for a stale one.
local fromPage = life.FromPage

--- The field of the open form a page payload names, or nil for one it does not.
local function fieldOf(owned, id)
	for index = 1, #owned.fields do
		if owned.fields[index].id == id then return owned.fields[index] end
	end
	return nil
end

--- A candidate buffer the page reported for one field.
-- The page is answered with a frame in EVERY case that names a real field --
-- accepted, refused, or aimed at a field this form does not have focused --
-- and the frame carries the sequence of the keystroke it is answering.
--
-- The sequence is the whole of the fix for a line that went empty under the
-- first character. The page reports a candidate and goes on showing it, because
-- erasing it and waiting for Lua is a field that blinks back to its placeholder
-- on every keystroke. What it may not do is show a candidate Lua has already
-- ruled on, and a bare frame does not say which keystroke it answers: a frame
-- built before the report lands carries the buffer from BEFORE the character
-- and puts the field back to empty. With the sequence the page can tell the two
-- apart -- an older frame leaves the line alone, the answering frame replaces
-- it, and a refusal is an answering frame, so a refused character still goes.
--
-- A silent drop is what this cannot do. An edit that raced a focus change used
-- to be discarded with no frame at all, which left a character in a field Lua
-- never accepted and no answer that would ever take it out again.
local function onEdit(payload)
	if fromPage(payload) == nil then return end
	local field = fieldOf(record, payload.id)
	-- A payload naming no field of this form is not a race, it is a page talking
	-- about something else, and answering it would teach it that it was heard.
	if field == nil then return end

	local seq = finite(payload.seq) and math.floor(payload.seq) or nil
	-- Never backwards: two edits can cross on the wire, and the older one
	-- arriving second must not un-answer the newer one.
	if seq ~= nil and seq > field.ack then field.ack = seq end

	local entry = entryOf(record)
	-- The focused field only. The page blurs every other input, so an edit for
	-- one of them is a keystroke that raced a focus change: it is refused, and
	-- refused visibly, by the frame that goes back with the accepted buffer.
	if entry.id ~= payload.id then
		draw()
		return
	end

	local refusal, params = edit(entry, payload.text)
	if refusal ~= nil then
		notice(refusal, params)
		return
	end
	draw()
end

--- One key the page forwarded.
local function onKey(payload)
	if fromPage(payload) == nil then return end
	local key = payload.key
	if type(key) ~= 'string' or not KEYS[key] then return end

	if key == 'enter' then
		-- A held ENTER must not submit twice.
		if payload['repeat'] == true then return end
		local index, refusal = check(record)
		if index == nil then
			finish('submit')
			return
		end
		-- The focus moves to the field that refused, so the line under the
		-- fields is about something the player can see.
		record.index = index
		notice(refusal)
		return
	end

	local moved
	if key == 'up' then
		moved = move(record, -1)
	elseif key == 'down' then
		moved = move(record, 1)
	else
		moved = adjust(entryOf(record), key == 'left' and -1 or 1)
	end
	if moved then draw() end
end

--- An arrow the player clicked on a choice field.
local function onStep(payload)
	if fromPage(payload) == nil then return end
	local direction = payload.direction
	if direction ~= 1 and direction ~= -1 then return end
	for index = 1, #record.fields do
		local entry = record.fields[index]
		if entry.id == payload.id then
			-- Pointing at a field's arrow focuses it: the caret has to follow,
			-- or the next keystroke lands somewhere else.
			record.index = index
			adjust(entry, direction)
			draw()
			return
		end
	end
end

--- A field the player pointed at.
local function onFocusField(payload)
	if fromPage(payload) == nil then return end
	for index = 1, #record.fields do
		if record.fields[index].id == payload.id then
			if record.index ~= index then
				record.index = index
				draw()
			end
			return
		end
	end
end

--- Escape. The page keeps focus until this answers with a close: the reason
--- belongs to Lua and the page never decides it.
local function onDismiss(payload)
	if fromPage(payload) == nil then return end
	finish('cancel', 'dismissed')
end

-- Answers the surface-wide focus broadcast for this module's own owners: see
-- `OPX.Modal.FocusResponder`.
local onFocus = OPX.Modal.FocusResponder(FOCUS)

--- Wires the page channels once, on the first open.
wire = function()
	if wired then return end
	wired = true
	OPX.UI.On(SURFACE, 'form:edit', onEdit)
	OPX.UI.On(SURFACE, 'form:key', onKey)
	OPX.UI.On(SURFACE, 'form:step', onStep)
	OPX.UI.On(SURFACE, 'form:focus', onFocusField)
	OPX.UI.On(SURFACE, 'form:dismiss', onDismiss)
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

--- Publishes the form contract.
-- @author dop42
function M.Api()
	OPX.Api.Provide('form', 1, {
		Open = Open,
		Close = Close,
		SetStatus = SetStatus,
		State = State,
	})
end

--- Wires the down state, the pause key and the upkeep pass.
-- @author dop42
function M.Start()
	life.Start()
end

--- Answers the open form and hands the keyboard back.
-- @author dop42
function M.Stop()
	if record ~= nil then finish('cancel', 'stopped') end
	-- A close with no handle blanks whatever the page still holds, which is the
	-- one case where this module cannot know what that is.
	OPX.UI.Send(SURFACE, 'form:close', {})
	OPX.UI.ReleaseFocus(OWNER)
end
